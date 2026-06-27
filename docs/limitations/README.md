# Known limitations

What this stack can and cannot do today, and how the backend pieces relate.

**Related docs:**

- [Request timeline](../Pokemon/request_timeline.md) — what the NDS actually sent (capture evidence per session)
- [Network explanation](../containers/network_explanation.md) — nginx vs dwc traffic paths
- [pkmn-classic-framework README](../../backend_servers/pkmn-classic-framework/README.md) — upstream feature list
- [GPSP search handoff](../extend_dwc/gpsp_search_handoff.md) — implementation plan for the dwc submodule

---

## Two backend layers

Online play for Gen 4/5 uses two separate server stacks:

```text
NDS
 │
 ├─ WFC / GameSpy layer (UDP/TCP: 27900, 27901, 28910, 29900, 29901, 29920)
 │    NAS, GPCM, GPSP, QR, NAT neg, master browser
 │    → dwc_network_server_emulator (Python, dwc container)
 │
 └─ Pokémon application layer (HTTPS gamestats / sake)
      GTS, Battle Tower teams, Battle Videos, dressup, box uploads, …
      → pkmn-classic-framework (C# / ASP.NET + MySQL) — submodule, not wired in yet
```

| Layer | Repo | Deployed today? |
|-------|------|-----------------|
| WFC / GameSpy | `backend_servers/dwc_network_server_emulator` | Yes (dwc container) |
| Pokémon app logic | `backend_servers/pkmn-classic-framework` | No — reference only until integrated |

[pkmn-classic-framework](https://github.com/samyiin/pkmn-classic-framework) explicitly defers all GameSpy and direct-console traffic to AltWFC (dwc). It does **not** replace dwc.

---

## Current blocker: WFC registration (dwc)

As of [Session D](../Pokemon/request_timeline.md#session-d--gamespy-working-stuck-after-gpsp-search-2026-06-26-1839-utc) in the request timeline, a real NDS reaches NAS login, GPCM login, and QR registration, then **hangs** because dwc ignores GPSP `\search` on TCP `:29901`.

| Step | Status |
|------|--------|
| DNS sinkhole | Working |
| NAS `/ac` | Working |
| GPCM login (`:29900`) | Working |
| QR registration (`:27900` UDP) | Working |
| GPSP `\search` (`:29901`) | **Not implemented** in dwc |
| NDS UI advances past setup | **Blocked** |

**Fix location:** dwc submodule — add a `perform_search()` handler, not pkmn-classic-framework.

Capture evidence (exact NDS request, dwc log lines, timestamps): [request timeline Session D](../Pokemon/request_timeline.md#phase-2--gpsp-player-search-fail--emulator-gap).

Upstream survey, fork scan, protocol comparison, and implementation plan: **[GPSP `\search` gap — investigation](#gpsp-search-gap--investigation-2026-06-26)** below.

Secondary checks not ruled out (see timeline): GPCM `UPDATE_PROFILE` / lastname loop, GPCM `STATUS(6)`, UDP `:28910` master browser.

---

## GPSP `\search` gap — investigation (2026-06-26)

Investigation against this repo’s dwc submodule, upstream [barronwaffles/dwc_network_server_emulator](https://github.com/barronwaffles/dwc_network_server_emulator), [pkmn-classic-framework](https://github.com/mm201/pkmn-classic-framework), and public community sources. Intended for handoff to an implementation agent.

### Verdict

**GPSP `\search` → `\bsrdone\` is dwc’s responsibility** for this self-hosted stack. Session D confirms the NDS sends `\search` on TCP `:29901`, dwc logs it as an unknown command, and sends **zero bytes back** — consistent with an indefinite UI wait while QR keep-alives continue. **No public dwc fork or branch implements `\search` or `bsrdone`.** The gap exists in upstream since the file was first added (~2014). **pkmn-classic-framework does not implement GameSpy at all** (HTTP gamestats only). Production services that work for Gen 4 Pokémon (Wiimmfi, Kaeru WFC / Poké Classic) likely handle GPSP in **closed-source** infrastructure, not in the open dwc tree.

### Responsibility matrix

| Component | Repo | GPSP TCP `:29901` | Pokémon `\search` + `\bsrdone` | Notes |
|-----------|------|-------------------|----------------------------------|-------|
| **dwc** | `backend_servers/dwc_network_server_emulator` | Listens (`GameSpyPlayerSearchServer`) | **Not implemented** | Only `otherslist` (MKWii). **Fix goes here.** |
| **pkmn-classic** | `backend_servers/pkmn-classic-framework` | Not present | **Out of scope** | README: direct comms handled by AltWFC/dwc |
| **nginx / DNS** | this repo | N/A | N/A | GameSpy bypasses nginx |
| **Wiimmfi** | closed source | Yes (PHP → C/C++) | **Unknown / likely yes** | [Tockdom wiki](https://wiki.tockdom.com/wiki/Wiimmfi_Project): GPSP as PHP script |
| **Kaeru WFC / Poké Classic** | proxy to Wiimmfi | Via upstream WFC | **Not in pkmn-classic code** | DNS `178.62.43.212` |

### What stock dwc implements today

File: `backend_servers/dwc_network_server_emulator/gamespy_player_search_server.py`

| Command | Handler | Used by | Status |
|---------|---------|---------|--------|
| `otherslist` | `perform_otherslist()` | Mario Kart Wii — lookup `opids` → `uniquenick` | Implemented since file creation |
| `search` | *(none)* | Pokémon Gen 4 — lookup by `lastname` | Logged at DEBUG, **no reply** |
| `bsrdone` | *(server sends)* | Pokémon — end of buddy search | **Never sent** |

Dispatch logic (all upstream copies identical):

```python
if data_parsed['__cmd__'] == "otherslist":
    self.perform_otherslist(data_parsed)
else:
    logger.log(logging.DEBUG,
               "Found unknown search command, don't know how to handle '%s'.",
               data_parsed['__cmd__'])
```

`perform_otherslist()` docstring references [Tockdom MKWii GPSP](http://wiki.tockdom.com/wiki/MKWii_Network_Protocol/Server/gpsp.gs.nintendowifi.net) — not Pokémon’s `\search` flow.

**Database gap:** `gamespy/gs_database.py` stores `lastname` on profiles (`update_profile()` accepts `firstname` / `lastname`) but has **no `get_profile_by_lastname()`** (or similar) helper. A search handler will need a new DB query.

### Git history (dwc submodule)

| Finding | Detail |
|---------|--------|
| File introduced | Commit `986627e` (~2014), “Significantly changed the layout of the server” |
| Since introduction | **Only `otherslist`** — never `search` / `bsrdone` |
| Later commits | Refactors only (`94e391a` “Cleaned: gamespy_player_search_server.py”, config module, etc.) |
| This repo’s fork | `samyiin/dwc_network_server_emulator` — **zero diff** vs `barronwaffles/master` on this file (verified 2026-06-26) |

### Public fork / branch survey (2026-06-26)

Method: GitHub API `GET /repos/barronwaffles/dwc_network_server_emulator/forks?per_page=100` (69 forks returned), then fetch `gamespy_player_search_server.py` from each fork’s `master` or `main` branch. Also checked named branches on main repos.

Needles searched in file content: `bsrdone`, `perform_search`, `data_parsed['__cmd__'] == "search"`.

| Scope | Count | `\search` implementation | `bsrdone` |
|-------|-------|--------------------------|-----------|
| barronwaffles / polaris- / samyiin `master` | 3 repos | **0** | **0** |
| All 69 GitHub forks (`master`/`main`) | 69 | **0** | **0** |
| Branches: `profile_timeout`, `py3-wip` | 3 checked | **0** | **0** |

**Conclusion:** There is **no public fork or branch to cherry-pick from**. Implementation must be written in this repo’s dwc submodule (or copied from a private/closed source if obtained from community).

GitHub code search for `bsrdone` + `gamespy_player_search` returned no usable public hits (API requires auth for code search; manual fork scan is exhaustive for the fork list).

### pkmn-classic-framework survey

Repo: `backend_servers/pkmn-classic-framework` (fork of [mm201/pkmn-classic-framework](https://github.com/mm201/pkmn-classic-framework)).

| Search term | Matches in repo |
|-------------|-----------------|
| `bsrdone`, `GPSP`, `29901`, `gamespy_player_search`, `perform_search`, `otherslist` (GameSpy sense) | **None** |
| `search` (HTTP gamestats) | Many — GTS, battle videos, dressup, etc. |

**Architecture (from upstream README):**

```text
Direct communications are handled by AltWFC (dwc) and are outside the scope of this project.
```

pkmn-classic implements **HTTPS gamestats** handlers, e.g. `/pokemondpds/worldexchange/search.asp` in `gts/pokemondpds.ashx.cs` — that is **GTS Pokémon search by species/level**, not GPSP buddy lookup by `lastname` during WFC registration. The `library/Wfc/` namespace holds **data structures** (GtsRecord, TrainerProfile, …), not GameSpy server code.

**Conclusion:** Integrating pkmn-classic later enables GTS / Battle Tower HTTP features; it **does not** fix Session D’s GPSP hang.

### Production ecosystem (why other DNS servers “work”)

| Service | DNS (examples) | WFC layer | Pokémon app layer |
|---------|----------------|-----------|-------------------|
| AltWFC / WFZwei | `172.104.88.237` | Open dwc (same GPSP gap) | Generic dwc storage |
| Wiimmfi | various | **Closed source** (GPSP PHP/C++) | Proxies GTS to mm201 for Gen 4 |
| Poké Classic / Kaeru | `178.62.43.212` | Proxies auth via Wiimmfi | mm201 pkmn-classic HTTP |

Gen 4 players on Poké Classic / Wiimmfi can reach GTS and (with NAT fixes) Wi-Fi Club because **their WFC stack is not stock open dwc**. Self-hosting barronwaffles dwc reproduces Session D unless GPSP `\search` is patched locally.

GitHub [issue #478 — Wi-Fi Club on Pokemon Games](https://github.com/barronwaffles/dwc_network_server_emulator/issues/478) (barronwaffles dwc): maintainer notes pkmn-classic is for Pokémon-specific HTTP features; basic friend trade/battle uses plain WFC/dwc. Reporter: **“Nothing work when using Wi-Fi Club on Pokemon Games with a personal server.”** Stale-closed; no fix merged.

### Protocol reference: Pokémon `\search` vs MKWii `otherslist`

Two different GPSP commands on the same port (`29901`):

| | MKWii `otherslist` | Pokémon `\search` |
|--|-------------------|-------------------|
| **Client sends** | `opids` (profile IDs, pipe-separated) | `lastname` (buddy lookup key) |
| **Server returns** | `\o\` + profileid + `\uniquenick\` pairs, then `\oldone\` | `BUDDY_SEARCH_RECORD` entries (if any), then `\bsrdone\` |
| **dwc status** | Implemented | **Missing** |
| **Doc** | [Tockdom GPSP](https://wiki.tockdom.com/wiki/GPSP) — documents **only** `otherslist` | [Pipian DS NWC](http://www.pipian.net/ierukana/hacking/ds_nwc.html) — registration + Wi-Fi Club `\search` / `\bsrdone` |

**Pipian Wi-Fi Club login sequence** (abbreviated):

```text
1. Client → GPSP :29901  \search\  ... lastname\<buddy_lastname> ... gamename\pokemondpds ...
2. Server → BUDDY_SEARCH_RECORD(s) for matching profiles (if any)
3. Server → \bsrdone\  (buddy search request done)
4. (Further buddy status / GPCM coordination — see Pipian)
```

Pipian also notes a TODO: full semantics of `\search` and `\bsrdone` on GPSP were not fully documented when written.

**Session D observed request** (see [timeline](../Pokemon/request_timeline.md#phase-2--gpsp-player-search-fail--emulator-gap) for full capture context):

```text
\search\\sesskey\18721975\profileid\1\namespaceid\0\
lastname\6o92ph80rADAJ0ighkm9\gamename\pokemondpds\final\
```

The `lastname` value matches the GameSpy profile field set during GPCM `UPDATE_PROFILE` (friend-code related string), not a human-readable name.

### Hang mechanism (Session D)

```text
NAS + GPCM + QR succeed  →  session alive (QR keep-alives ~20s, heartbeats ~60s)
GPSP \search sent        →  dwc logs "unknown command", sends nothing
Game UI                  →  waits for GPSP response (and possibly GPCM STATUS(6))
User perception          →  infinite loading; logs look like a "loop" but are normal keep-alive
```

QR keep-alives after the failed `\search` are **not** a failure mode — they indicate the NDS believes it has an active GameSpy session.

### Registration hang vs P2P (do not conflate)

| Problem | Layer | Ports | Forum discussion |
|---------|-------|-------|------------------|
| **Registration / setup hang** (Session D) | GPSP `\search` no reply | TCP `:29901` | Rare in forums; open dwc gap |
| **Wi-Fi Club friend not visible / battle fails** | NAT traversal + direct P2P | UDP `:27901` natneg, then DS↔DS | Very common |

**Full Wi-Fi Club / P2P path** (not yet reached on this server):

```text
WFC registration complete (GPSP \search → \bsrdone\)
  → GPCM buddy status
  → UDP :28910 master server browser
  → UDP :27901 NAT negotiation
  → direct NDS ↔ NDS UDP (peer battle/trade)
```

Community P2P troubleshooting (Wiimmfi-era) consistently points to **router NAT / DMZ**, not missing GPSP code:

- [Pokemon gen 4 Wi-Fi Club problems](https://forum.wii-homebrew.com/index.php/Thread/58907-Pokemon-gen-4-Wi-Fi-Club-problems/) — Wiimmfi staff (Billy): invisible friends in Club → **NAT blocking P2P**; try **DMZ** for the DS
- [How to use Wiimmfi](https://forum.wii-homebrew.com/index.php/Thread/55264-How-to-use-Wiimmfi/) — error **86420** = failed P2P comm → DMZ
- [Frequent Error 86420](https://forum.wii-homebrew.com/index.php/Thread/60244-Frequent-Error-86420/) — forward **UDP 1024–65535** or DMZ

**This server has not reached P2P** — registration blocks earlier at GPSP.

### Community resources (for implementers)

| Resource | URL / channel | Relevance |
|----------|---------------|-----------|
| Pipian DS NWC protocol | http://www.pipian.net/ierukana/hacking/ds_nwc.html | `\search`, `\bsrdone`, registration steps |
| Tockdom GPSP (MKWii) | https://wiki.tockdom.com/wiki/GPSP | `otherslist` only — useful for response encoding patterns |
| Tockdom GPCM | https://wiki.tockdom.com/wiki/GPCM | Profile, lastname, buddy records |
| AltWFC IRC | `#altwfc` on Rizon | dwc developers / private patches |
| AltWFC Discord | linked from [List of Servers wiki](https://github.com/barronwaffles/dwc_network_server_emulator/wiki/List-of-Servers) | Connection help |
| dwc issue #42 (Pokémon) | https://github.com/barronwaffles/dwc_network_server_emulator/issues/42 | Full Pokémon support deferred to pkmnFoundations / mm201 |
| dwc issue #478 (Wi-Fi Club) | https://github.com/barronwaffles/dwc_network_server_emulator/issues/478 | Personal dwc + Pokémon Club reported broken |
| Project Pokémon forums | https://projectpokemon.org/home/forums/topic/57210-accessing-nintendo-wfc-in-gens-4-5-no-hacks/ | User-facing WFC setup (Wiimmfi / custom DNS) |
| Wii Homebrew forum | https://forum.wii-homebrew.com/ | Wiimmfi, NAT, Gen 4 Club issues |

### Follow-up research: public implementations and game source (2026-06-27)

#### Public replacement servers

Additional follow-up against public replacement-server material reinforces the same conclusion:

- **Wiimmfi almost certainly implements the required GPSP behaviour**, but its production GameSpy stack is **not public source**. Public Wiimmfi docs say GPSP existed first as a **PHP** service and that parts of the wider stack later moved to **C/C++** for performance. That explains why Gen 4 Pokémon works there without providing code we can directly reuse.
- Older public reuploads such as `realgorgan/nintendowfc` still ship the **same `gamespy_player_search_server.py`** as upstream dwc: `otherslist` only, no Pokémon `search`, no `bsrdone`.
- Therefore, there is **still no public Pokémon GPSP implementation to cherry-pick**. Working services exist, but the code path we need is either closed-source or never published.

#### What reverse-engineered Pokémon game source can and cannot answer

Public reverse-engineering projects exist for Gen 4 games, notably:

- [pret/pokediamond](https://github.com/pret/pokediamond)
- [pret/pokeheartgold](https://github.com/pret/pokeheartgold)

These are useful, but they do **not** provide the original Nintendo/GameSpy server source. Two constraints matter:

1. The projects still depend on proprietary Nintendo networking components (`NitroDWC`, `NitroSDK`) for Wi-Fi functionality.
2. The remaining public decomp/disassembly is primarily **client-side** game logic, not the server-side GPSP implementation.

Practical implication:

- The decomp projects can help confirm **when the client sends `search`**, what fields it includes, and what subsequent state transitions it waits for.
- They may help verify whether an **empty result set + `bsrdone`** is enough to advance registration.
- They **cannot** fully recover the original server-side semantics for GPSP buddy search, nor the authoritative `BUDDY_SEARCH_RECORD` field layout, unless more of the Nintendo Wi-Fi middleware is reverse-engineered later.

#### Confidence level

Current confidence is high on the **responsibility** and **minimum required behaviour**, but lower on the **exact result-record schema**:

- **High confidence:** stock dwc must answer Pokémon `\search` on TCP `29901`, and silence is wrong.
- **High confidence:** the server must terminate the operation with `\bsrdone\`.
- **Medium confidence:** returning an **empty result set followed by `\bsrdone\`** is enough to unblock self-registration when no buddy match is required.
- **Lower confidence:** the exact contents and multiplicity rules of `BUDDY_SEARCH_RECORD` without more original captures or private implementation details.

### Implementation plan (next agent)

**Minimal unblock (stub):**

1. In `gamespy_player_search_server.py`, add branch for `data_parsed['__cmd__'] == "search"`.
2. Implement `perform_search()`:
   - Parse `lastname`, `profileid`, `sesskey`, `gamename`, `namespaceid` from request.
   - Query `gs_database` for profile(s) matching `lastname` (new DB method required).
   - If no match: send **empty result set** + `\bsrdone\` (game may still proceed for self-registration / zero buddies).
   - If match: send buddy search record(s) per Pipian field layout, then `\bsrdone\`.
3. Use `gs_query.create_gamespy_message()` like `perform_otherslist()` — compare wire format to Pipian captures if available.

**Verify after stub:**

- Re-run Session D-style connect; NDS UI advances past registration.
- dwc logs show outbound GPSP message after `\search`.
- Re-test GPCM: confirm whether `UPDATE_PROFILE` / `STATUS(6)` also required (secondary blockers in timeline).

**Do not implement in:** pkmn-classic-framework, nginx, dns_sinkhole.

---

## What dwc handles vs pkmn-classic

### dwc (deployed) — infrastructure

- NAS authentication (`nas.nintendowifi.net`)
- GameSpy: profile (GPCM), player search (GPSP), QR, NAT neg, server browser, gamestats TCP
- Generic Sake storage and generic gamestats HTTP stubs
- DLC (`dls1`)

Generic dwc handlers are **not** full Pokémon GTS / Battle Tower implementations.

### pkmn-classic-framework (submodule, not integrated) — game features

From upstream README, implemented on Poké Classic Network:

| Feature | pkmn-classic | dwc alone |
|---------|--------------|-----------|
| GTS (trade, deposit, search) | Full protocol | Partial / generic storage |
| Battle Videos | Yes | No |
| Wi-Fi Battle Tower / Subway | Yes (see below) | No |
| Dressup, box uploads (Pt/HGSS) | Yes | No |
| Musical photos (BW) | Yes | No |
| Trainer Rankings, Wi-Fi Plaza | No | No |
| Game Sync, Rating Battles | No | No |

Integrating pkmn-classic means a separate ASP.NET + MySQL service and nginx routing gamestats/sake Pokémon paths to it instead of dwc’s generic handlers.

---

## Online battles: three different things

Do not confuse these:

### 1. Direct peer battles (Wi-Fi Club rooms, friend battles)

**Not pkmn-classic. Handled by dwc / AltWFC.**

Requires GameSpy master browser (UDP `:28910`), NAT negotiation (UDP `:27901`), then **direct NDS ↔ NDS** traffic. pkmn-classic README: *“Direct communications … are outside the scope of this project.”*

On this server: NAT neg is partial in dwc; P2P path has **not** been reached in captures. Do not expect live human-vs-human battles to work end-to-end yet.

### 2. Wi-Fi Battle Tower / Battle Subway

**pkmn-classic when integrated — not live PvP.**

You download other players’ **saved teams** from the server and fight **AI** using those teams. Server-mediated; no real-time connection to the other player.

### 3. Rating Battles / Competitions (Gen 5)

**Not implemented** in pkmn-classic upstream. Listed under “What doesn’t” in their README.

---

## Other dwc gaps (from captures)

| Component | File | Notes |
|-----------|------|-------|
| GPSP | `gamespy_player_search_server.py` | `search` + `bsrdone` missing — **current registration blocker** |
| GPCM | `gamespy_profile_server.py` | Verify lastname / `STATUS(6)` completion |
| Master browser | `gamespy_server_browser_server.py` | Partial; needed for Wi-Fi Club rooms |
| NAT neg | `gamespy_natneg_server.py` | Partial; needed for P2P battles |
| Sake / GTS | `storage_server.py` | Partial; superseded by pkmn-classic for Pokémon |
| NAS | `nas_server.py` | login works; `svcloc` not seen in captures yet |

---

## Recommended development order

See [Implementation plan (next agent)](#implementation-plan-next-agent) above for GPSP `\search` detail.

1. **GPSP `\search`** in dwc — unblocks WFC registration hang (Session D).
2. **Verify GPCM registration completion** — lastname + `STATUS(6)`.
3. **Integrate pkmn-classic** — GTS, Battle Tower, Battle Videos (new container + MySQL + nginx routes).
4. **Master browser** — UDP `:28910` for Wi-Fi Club.
5. **NAT negotiation** — UDP `:27901` for direct peer battles.

---

## Changelog

| Date | Notes |
|------|-------|
| 2026-06-26 | Initial doc: two-layer stack, GPSP blocker, battle types, dwc vs pkmn-classic scope |
| 2026-06-26 | GPSP `\search` investigation: upstream/fork survey (69 forks, 0 public impl), pkmn-classic scope, Wiimmfi closed-source note, P2P vs registration, implementation plan |
| 2026-06-27 | Follow-up research: Wiimmfi/public replacement-server note, `pret` reverse-engineering scope, confidence level, and handoff doc link |
