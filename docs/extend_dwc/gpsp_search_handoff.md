# GPSP Search Handoff

Implementation handoff for the missing Pokémon Gen 4 GPSP `\search` handling in the `dwc_network_server_emulator` submodule.

## Goal

Unblock real NDS Wi-Fi Club registration by teaching stock dwc to answer Pokémon GPSP `\search` on TCP `29901` instead of logging it as an unknown command and returning nothing.

This is the blocker observed in Session D of `docs/Pokemon/request_timeline.md`.

## Scope

Work only in the `backend_servers/dwc_network_server_emulator` submodule.

Do not implement this in:

- `backend_servers/pkmn-classic-framework`
- nginx config
- `dns_sinkhole`

## Known behaviour

### Observed request from a real NDS

```text
\search\\sesskey\18721975\profileid\1\namespaceid\0\
lastname\6o92ph80rADAJ0ighkm9\gamename\pokemondpds\final\
```

### Current server behaviour

`gamespy_player_search_server.py` only handles `otherslist`:

- Mario Kart Wii `otherslist` works
- Pokémon `search` falls into the unknown-command branch
- the server sends no reply
- the NDS keeps the session alive and waits forever

### Best public protocol evidence

The strongest public source is Pipian's Gen 4 Nintendo WFC writeup:

- http://www.pipian.net/ierukana/hacking/ds_nwc.html

What it supports with reasonable confidence:

1. Gen 4 Pokémon stores `lastname` in GPCM profile data using `UPDATE_PROFILE`.
2. GPSP later searches by `lastname`, not by `profileid`.
3. GPSP should return zero or more buddy-search records.
4. GPSP should then terminate the operation with `\bsrdone\`.

What remains uncertain:

- the exact `BUDDY_SEARCH_RECORD` field layout
- whether the search is global or restricted to the user's buddy list
- whether the empty-result case alone is sufficient for all scenarios, or only for self-registration / no-match startup cases

## Files to inspect and likely modify

### Primary

- `backend_servers/dwc_network_server_emulator/gamespy_player_search_server.py`
- `backend_servers/dwc_network_server_emulator/gamespy/gs_database.py`

### Useful supporting files

- `backend_servers/dwc_network_server_emulator/gamespy/gs_query.py`
- `backend_servers/dwc_network_server_emulator/gamespy_profile_server.py`

## Current local code facts

### `gamespy_player_search_server.py`

- The TCP GPSP listener already exists.
- Dispatch currently branches only on `otherslist`.
- It already uses `gs_query.create_gamespy_message()` to serialize replies.

### `gamespy/gs_database.py`

- The `users` table already stores `lastname`.
- `update_profile()` already persists `firstname` and `lastname`.
- `get_profile_from_profileid()` exists.
- There is **no helper** to query a user by `lastname`.

## Recommended implementation order

### Phase 1: Minimal unblock

Objective: determine whether **any** reply ending in `\bsrdone\` is enough to move the NDS forward.

1. In `gamespy_player_search_server.py`, add a `search` branch:
   - `if data_parsed['__cmd__'] == "search":`
   - call a new `perform_search(data_parsed)`

2. In `gs_database.py`, add a helper such as:
   - `get_profiles_by_lastname(lastname)`
   - return a list of matching rows from `users`

3. In `perform_search()`:
   - parse `sesskey`, `profileid`, `namespaceid`, `lastname`, `gamename`
   - log all parsed values at DEBUG
   - look up matching profile rows by `lastname`

4. First-pass response strategy:
   - if no match is found, send **only** `\bsrdone\final\`
   - if a match is found, either:
     - also send only `\bsrdone\final\` for the first experiment, or
     - send a conservative buddy result record followed by `\bsrdone\final\` if enough structure is known during implementation

5. Verify whether the game progresses past the current hang.

Reason for this phase:

- The highest-confidence missing behaviour is that the server is currently **silent**.
- Before overfitting an uncertain result-record format, confirm whether the registration flow only needs a completion signal.

### Phase 2: Return actual search results

If Phase 1 proves the completion record matters but result data is still required, extend `perform_search()` to send actual buddy-search result records before `\bsrdone`.

Recommended approach:

1. Use the profile row returned by `lastname` lookup.
2. Start from fields already known to exist in the local DB:
   - `profileid`
   - `uniquenick`
   - `firstname`
   - `lastname`
   - `email`
   - `gsbrcd`
   - `gameid`
   - `loc`
   - `lat`
   - `lon`

3. Compare how `gs_query.create_gamespy_message()` serializes list-based replies.
4. Mirror the existing `otherslist` style where possible:
   - accumulate tuples in order
   - serialize once
   - write to `self.transport`

5. Keep response formatting conservative:
   - preserve key order explicitly
   - avoid adding speculative fields unless a capture or documented record layout supports them

### Phase 3: If needed, enforce buddy-list semantics

If the game accepts `bsrdone` but later misbehaves because the returned profile should be constrained to known buddies:

1. Query the existing `buddies` table.
2. Restrict matches to entries related to the requesting `profileid`.
3. Re-test with a known Pal Pad relationship.

Do this only if testing shows that global lastname lookup is insufficient or incorrect.

## Suggested response shapes

### Safest first experiment

Send only:

```text
\bsrdone\\final\
```

Rationale:

- lowest speculation
- directly tests whether the current blocker is "no completion signal"
- easy to log and verify

### Next experiment if a record is required

Send:

1. one or more buddy-search result records
2. a terminating `\bsrdone\`

The exact result-record command name and fields should be taken from protocol notes or captures if the implementing agent can derive them confidently. Do not invent a complex schema unless testing proves it is necessary.

## Logging requirements

The implementing agent should add DEBUG logs for:

- inbound `search` payload
- parsed request fields
- number of DB matches found for `lastname`
- exact outbound GPSP payload

This matters because the next blocker, if any, may be:

- malformed response encoding
- missing result records
- a separate GPCM state transition such as `STATUS(6)`

## Verification checklist

After implementation, rerun the real-client flow and verify:

1. the NDS still completes NAS, GPCM, and QR steps
2. dwc logs show `search` handled instead of unknown-command
3. dwc logs show an outbound GPSP message
4. the game advances past the current loading hang
5. if it still hangs, confirm whether the next wait point is:
   - missing buddy-search result record details
   - GPCM profile update propagation
   - GPCM `STATUS(6)`
   - master server / NAT-neg follow-up

## Success criteria

Minimum success:

- the game no longer stalls immediately after GPSP `search`

Better success:

- the client reaches the next Wi-Fi Club stage, even if later stages still fail

Full success for this task:

- GPSP `search` is handled robustly enough that registration no longer depends on a private server implementation

## Risks and open questions

- `\bsrdone\` may be necessary but not sufficient.
- The result-record schema may be stricter than current public notes suggest.
- Some follow-up behaviour may depend on GPCM buddy status records rather than GPSP alone.
- Gen 4 and Gen 5 should not be treated as identical here; this handoff is for **Gen 4 Pokémon**.

## Non-goals

- integrating `pkmn-classic-framework`
- fixing GTS
- fixing NAT traversal
- implementing Wi-Fi Club P2P battles end-to-end
- generalizing all GameSpy edge cases

## References

- `docs/limitations/README.md`
- `docs/Pokemon/request_timeline.md`
- http://www.pipian.net/ierukana/hacking/ds_nwc.html
- https://wiki.tockdom.com/wiki/GPSP
- https://wiki.tockdom.com/wiki/GPCM
- https://github.com/barronwaffles/dwc_network_server_emulator/issues/478
