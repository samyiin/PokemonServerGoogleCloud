# Pokémon Gen 4 (D/P/Pt/HG/SS) — observed request timeline

Living document of network traffic captured while connecting a real NDS to this server.

**Purpose:** Record what the NDS actually sends, what our stack returns, and where capture stopped — per session, with timestamps and log excerpts. For emulator gaps, upstream survey, and fix plans see [limitations README](../limitations/README.md).

**Sources:** `tcpdump` on VM DNS + GameSpy ports, `docker logs nginx-nds-gateway`, `docker logs dwc` (2026-06-26 captures).

**Server VM public IP during capture:** `34.71.245.57`

**NDS setup:** DNS server = VM public IP (dnsmasq sinkhole on UDP 53).

**Protocol reference (external):** [Pipian — DS Nintendo Wi-Fi Connection](http://www.pipian.net/ierukana/hacking/ds_nwc.html) — detailed GameSpy record types, registration sequence (steps 1–25), GPSP `\search` / `\bsrdone` behaviour.

---

## Traffic paths (two lanes)

| Lane | Protocol | Entry point | Backend |
|------|----------|-------------|---------|
| **HTTP/HTTPS** | TLS (RC4-SHA) or plain HTTP | VM `:443` / `:80` → nginx | dwc `:9000` (NAS), `:8000` (Sake), `:9002` (gamestats), `:9003` (DLC) |
| **GameSpy** | UDP/TCP binary | VM published ports directly | dwc (bypasses nginx) |

GameSpy ports published by dwc:

| Port | Proto | Hostname pattern | dwc service |
|------|-------|------------------|-------------|
| 27900 | UDP | `*.available.gs.nintendowifi.net` | QR / availability |
| 27901 | UDP | `*.natneg*.gs.nintendowifi.net` | NAT negotiation |
| 28910 | UDP | `*.master.gs.nintendowifi.net` | Server browser |
| 29900 | TCP | `gpcm.gs.nintendowifi.net` | GameSpy profile (GPCM) |
| 29901 | TCP | `gpsp.gs.nintendowifi.net` | Player search |
| 29920 | TCP | `*.gamestats.gs.nintendowifi.net` | GameSpy gamestats |

---

## Full connection flow (expected)

```text
Phase 0 — WiFi setup (NDS system menu)
  DNS: conntest.nintendowifi.net          → real Nintendo (NOT sinkholed)
  HTTPS: conntest host connectivity test

Phase 1 — Game online init (enter Wi-Fi Club / GTS / etc.)
  DNS: pokemondpds.available.gs...      → sinkhole → VM IP
  UDP: VM:27900  availability check (GameSpy QR, packet type 0x09)

  DNS: nas.nintendowifi.net               → sinkhole → VM IP
  HTTPS: VM:443  POST /ac (NAS auth)      → nginx → dwc:9000

  DNS: gpcm.gs.nintendowifi.net           → sinkhole → VM IP
  TCP:  VM:29900 GPCM profile login       → dwc directly

Phase 2 — Registration / Wi-Fi Club init (partially observed Session D)
  DNS: pokemondpds.master.gs...       → sinkhole → VM IP
  UDP: VM:27900  QR heartbeat + challenge (same port as availability; dwc GameSpyQRServer)
  UDP: VM:28910  server browser        → dwc (master list) — not yet confirmed in capture
  DNS: gpsp.gs.nintendowifi.net        → sinkhole → VM IP
  TCP: VM:29901  player search (\search\, \otherslist\) → dwc GameSpyPlayerSearchServer

Phase 3 — Feature-specific (NOT YET OBSERVED)
  NAS svcloc, Sake storage, gamestats HTTP, natneg for P2P battles...
```

### Pokémon WFC registration flow (expected — from Pipian)

When the game sets up Nintendo Wi-Fi Connection user info (friend code / first online setup), the client roughly follows:

```text
 1. conntest (real Nintendo)
 2. UDP :27900 AVAILABLE to pokemondpds.available.gs
 3. HTTPS POST /ac to nas (acctcreate or login) → authtoken
 4. TCP :29900 GPCM login → GETPROFILE → UPDATE_PROFILE (lastname) → loop until lastname in PROFILEINFO
 5. GPCM LOGOUT, re-login with same token
 6. UDP :27900 HEARTBEAT to master + TCP :29900 STATUS(1) + challenge exchange
 7. GPCM STATUS(6) → registration complete → user dismisses message
 8. Optional: TCP :29901 GPSP \search\ for buddy lookup by lastname
```

Our Session D logs match steps 1–6 partially; step 8 was observed and **failed** (see below).

---

## Session A — failed NAS auth (2026-06-26 ~17:39 UTC)

**Status:** DNS + TLS reached nginx; dwc upstream crashed on `/ac`.

| # | Time (UTC) | Layer | Request | Result | Evidence |
|---|------------|-------|---------|--------|----------|
| A1 | 17:39:12 | TLS | Client → nginx `:443` SSL handshake | Failed (no shared cipher) | nginx log, client `172.19.0.1` |
| A2 | 17:39:21 | TLS | Retry SSL handshake | Failed (no shared cipher) | nginx log |
| A3 | 17:39:35 | HTTPS | `POST /ac HTTP/1.1` Host: `nas.nintendowifi.net` | **502** — upstream closed | nginx → dwc:9000 |
| A4 | 17:41:40 | HTTPS | `POST /ac` retry | **502** | nginx log |
| A5 | 17:42:02 | HTTPS | `POST /ac` retry | **502** | nginx log |
| A6 | 17:42:09 | HTTPS | `POST /ac` retry | **502** | nginx log |
| A7 | 17:43:10 | HTTPS | `POST /ac` retry | **502** | nginx log |

**Notes:**
- Client IP in nginx logs is `172.19.0.1` (Docker bridge — nginx sees the gateway, not the NDS public IP).
- Error: `upstream prematurely closed connection while reading response header from upstream`.
- Game likely retried `/ac` several times then gave up. No GPCM DNS observed in this session.

---

## Session B — partial success (2026-06-26 ~18:08–18:14 UTC)

**Status:** conntest OK → sinkhole DNS OK → NAS `/ac` **200 OK** → GPCM DNS queried → **stopped** (no GameSpy traffic confirmed yet).

### Phase 0 — WiFi connectivity test (real Nintendo)

Repeated while user navigated menus / retried connection:

| # | Time (UTC) | Layer | Request | DNS answer | Client IP |
|---|------------|-------|---------|------------|-----------|
| B0a | 18:08:42 | DNS | `A? conntest.nintendowifi.net` | Forwarded to 8.8.8.8 → AWS ELB `44.229.101.156`, `35.160.180.49` | 46.210.240.181 |
| B0b | 18:12:18 | DNS | `A? conntest.nintendowifi.net` | Same (real Nintendo) | 46.210.240.181 |
| B0c | 18:12:44 | DNS | `A? conntest.nintendowifi.net` | Same | 46.210.240.181 |
| B0d | 18:13:30 | DNS | `A? conntest.nintendowifi.net` | Same | 46.210.192.50 |
| B0e | 18:14:29 | DNS | `A? conntest.nintendowifi.net` | Same | 46.210.192.55 |

**Protocol:** `conntest.nintendowifi.net` is intentionally **not** in the sinkhole (`update-nds-ip.sh`). dnsmasq forwards to `8.8.8.8`. The NDS then hits real Nintendo servers to verify internet access before talking to game servers.

---

### Phase 1 — Game server availability check

| # | Time (UTC) | Layer | Request | DNS answer | Client IP |
|---|------------|-------|---------|------------|-----------|
| B1 | 18:14:30.730 | DNS | `A? pokemondpds.available.gs.nintendowifi.net` | **`34.71.245.57`** (authoritative `*`) | 46.210.192.55 |

**Expected next (not yet captured in tcpdump):**

```text
NDS → UDP 34.71.245.57:27900
GameSpy QR packet: header fe fd 09 ... (availability request)
Server → fe fd 09 00 00 00 00 (available)
```

Hostname `pokemondpds` = Pokémon Diamond/Pearl/Platinum game ID on GameSpy.

---

### Phase 2 — NAS authentication

| # | Time (UTC) | Layer | Request | DNS answer | Client IP |
|---|------------|-------|---------|------------|-----------|
| B2 | 18:14:34.995 | DNS | `A? nas.nintendowifi.net` | **`34.71.245.57`** (authoritative `*`) | 46.210.240.181 |
| B3 | 18:14:36 | HTTPS | `POST /ac HTTP/1.0` Host: `nas.nintendowifi.net` | **200**, 223 bytes | 46.210.240.181 |

**TLS details (nginx):** SSLv3, cipher RC4-SHA  
**Path:** NDS → VM:443 → nginx → dwc:9000/ac

**NAS `/ac` protocol** (from dwc `nas_server.py` — inferred for this request):

```http
POST /ac HTTP/1.0
Host: nas.nintendowifi.net
Content-Type: application/x-www-form-urlencoded

action=login|acctcreate|svcloc
&userid=...
&... (console-specific fields)
```

**Successful login response shape** (~223 bytes matches):

```text
retry=0&returncd=001&locator=gamespy.com&challenge=XXXXXXXX&token=...&datetime=YYYYMMDDHHMMSS
```

Response headers include `Content-type: text/plain`, `NODE: wifiappe1`.

We have not yet captured the exact POST body (need dwc debug logs).

---

### Phase 3 — GPCM profile (DNS only so far)

| # | Time (UTC) | Layer | Request | DNS answer | Client IP |
|---|------------|-------|---------|------------|-----------|
| B4 | 18:14:37.179 | DNS | `A? gpcm.gs.nintendowifi.net` | **`34.71.245.57`** (authoritative `*`) | 46.210.240.181 |

**Expected next (not yet confirmed):**

```text
NDS → TCP 34.71.245.57:29900
GameSpy Profile binary protocol (login with NAS authtoken)
→ dwc GameSpyProfileServer
```

**Important:** GPCM does **not** appear in nginx logs. It connects directly to dwc port 29900.

---

### Phase 4+ — not yet observed (Session B only)

These hostnames are in the sinkhole but had **not** appeared in Session B captures. See Session D for master/gpsp DNS.

| Hostname | Port | When game uses it |
|----------|------|-------------------|
| `pokemondpds.natneg1/2/3.gs.nintendowifi.net` | UDP 27901 | P2P NAT traversal |
| `pokemondpds.sake.gs.nintendowifi.net` | HTTPS → :8000 | GTS / storage |
| `sake.gs.nintendowifi.net` | HTTPS → :8000 | Shared storage |
| `pokemondpds.gamestats.gs.nintendowifi.net` | TCP 29920 / HTTP :9002 | Stats |
| `dls1.nintendowifi.net` | HTTPS → :9003 | DLC download |

---

## Session C — NAS OK, GameSpy blocked by GCP firewall (2026-06-26 ~18:31 UTC)

**Status:** Identical to Session B at the HTTP/DNS layer. GameSpy still unreachable from outside.

| # | Time (UTC) | Layer | Request | Result |
|---|------------|-------|---------|--------|
| C1 | 18:31:29 | DNS | `conntest.nintendowifi.net` | Real Nintendo (forwarded) |
| C2 | 18:31:31 | DNS | `pokemondpds.available.gs...` | `34.71.245.57` |
| C3 | 18:31:35/37 | DNS | `nas.nintendowifi.net` | `34.71.245.57` |
| C4 | 18:31:39 | HTTPS | `POST /ac` | **200**, 223 bytes |
| C5 | 18:31:39 | DNS | `gpcm.gs.nintendowifi.net` | `34.71.245.57` |

**GameSpy tcpdump** (`udp 27900 or tcp 29900`): **0 packets** while NDS connected.

**Root cause (confirmed later):** GCP VPC firewall allowed UDP GameSpy ports and TCP 443, but **blocked TCP 29900/29901/29920**. Packets never reached `ens4`.

---

## Session D — GameSpy working; stuck after GPSP `\search` (2026-06-26 ~18:39 UTC)

**Status:** First session with end-to-end GameSpy after opening GCP firewall for TCP 29900/29901/29920. NAS + GPCM + QR registration all succeed at the network and application layer. NDS UI appeared stuck (loading / infinite wait); dwc logs show an **unhandled GPSP `\search` command** — likely root cause.

**User action:** Retried online connection after firewall fix (entering online features / Wi-Fi setup — exact in-game screen not recorded).

**Terminals during capture:**
- T20: `docker logs -f nginx-nds-gateway`
- T21: `sudo tcpdump -nni ens4 'udp port 27900 or tcp port 29900'`
- T22: `sudo tcpdump -nni ens4 udp port 53`
- T27: `docker logs -f dwc` (full logs — source of GPCM/GPSP detail below)

### Phase 0 — conntest

| # | Time (UTC) | Layer | Request | Result | Client IP |
|---|------------|-------|---------|--------|-----------|
| D0 | 18:39:32 | DNS | `conntest.nintendowifi.net` | Real Nintendo AWS | 46.210.192.51 |

*(Session C at 18:31 was a repeat of B with 0 GameSpy packets — same DNS/`/ac` pattern, pre-firewall-fix.)*

### Phase 1 — availability + NAS + GPCM

| # | Time (UTC) | Layer | Request | Result | Evidence |
|---|------------|-------|---------|--------|----------|
| D1 | 18:39:33 | DNS | `pokemondpds.available.gs...` | `34.71.245.57` | T22 |
| D2 | 18:39:34 | UDP | NDS → `:27900` availability | **OK** — 17 B in, 7 B out | T21 |
| D3 | 18:39:34 | DNS | `nas.nintendowifi.net` | `34.71.245.57` | T22 |
| D4 | 18:39:36 | HTTPS | `POST /ac HTTP/1.0` | **200**, 223 bytes | T20, T27 |
| D5 | 18:39:36 | DNS | `gpcm.gs.nintendowifi.net` | `34.71.245.57` | T22 |
| D6 | 18:39:36–38 | TCP | GPCM login (`:29900`) | **Success** — see dwc detail below | T21, T27 |

### Phase 1 — GPCM login detail (dwc logs, 18:39:38)

Confirmed from `GameSpyProfileServer`:

```text
SENDING: \lc\2\sesskey\18721975\proof\072a7d91df929920e3bd117c3f494483\
         userid\8758244016294\profileid\1\uniquenick\7uso0c056ADAJ370j0mi\
         lt\U3lnTzhDQnA2UzlhTm53ZA__\id\1\final\
```

| Field | Value | Meaning |
|-------|-------|---------|
| `profileid` | `1` | First GameSpy profile on this server |
| `sesskey` | `18721975` | Session key for this connection |
| `uniquenick` | `7uso0c056ADAJ370j0mi` | GameSpy unique nick (friend-code related) |
| Client IP | `46.210.240.181:35201` | NDS public IP (visible in dwc, not nginx) |

This is a successful `\lc\` (logged in) response — GPCM auth completed.

### Phase 2 — QR registration + STATUS(1)

| # | Time (UTC) | Layer | Request | Result | Evidence |
|---|------------|-------|---------|--------|----------|
| D7 | 18:39:44 | GPCM | `\status\1\` from NDS | Processed | T27 |
| D8 | 18:39:44 | UDP | QR heartbeat → `:27900` | Challenge sent | T27 |
| D9 | 18:39:45 | UDP | QR challenge response | **Client registered** | T27 |
| D10 | 18:39:44 | DNS | `pokemondpds.master.gs...` | `34.71.245.57` | T22 |
| D11 | 18:39:46 | DNS | `gpsp.gs.nintendowifi.net` | `34.71.245.57` | T22 |

**QR registration (dwc `GameSpyQRServer`, 18:39:44–45):**

```text
Received heartbeat ... gamename pokemondpds localip 192.168.133.114 localport 50046 natneg 1
Sent challenge to 46.210.240.181:35198
Received challenge ... MASENzuKaWFliWZ7Es5NMYc56UMA
Sent client registered
GamespyBackendServer: Added pokemondpds servers: 1
```

Note: QR heartbeats use UDP `:27900` (same port as availability). Hostname may be `*.available.gs` or `*.master.gs` in DNS; dwc binds one `GameSpyQRServer` on `:27900`.

### Phase 2 — GPSP player search (**FAIL — emulator gap**)

| # | Time (UTC) | Layer | Request | Result | Evidence |
|---|------------|-------|---------|--------|----------|
| D12 | 18:39:47 | TCP | GPSP `\search\` → `:29901` | **No response** — unknown command | T27 |

**Exact request (dwc log):**

```text
GameSpyPlayerSearchServer] SEARCH RESPONSE:
  \search\\sesskey\18721975\profileid\1\namespaceid\0\
  lastname\6o92ph80rADAJ0ighkm9\gamename\pokemondpds\final\

GameSpyPlayerSearchServer] Found unknown search command, don't know how to handle 'search'.
```

**Expected behaviour (Pipian):** Server should return matching `BUDDY_SEARCH_RECORD` entries (if any) then `\bsrdone\` (buddy search request done). See [GPSP search section](http://www.pipian.net/ierukana/hacking/ds_nwc.html).

**Current dwc code:** `gamespy_player_search_server.py` only implements `otherslist`; `\search` is logged and ignored:

```91:97:backend_servers/dwc_network_server_emulator/gamespy_player_search_server.py
                if data_parsed['__cmd__'] == "otherslist":
                    self.perform_otherslist(data_parsed)
                else:
                    logger.log(logging.DEBUG,
                               "Found unknown search command, don't know"
                               " how to handle '%s'.",
                               data_parsed['__cmd__'])
```

### Phase 2 — ongoing QR session (keep-alive — looks like “infinite loop” in logs)

After D12, NDS maintains an active GameSpy QR session. **This is normal connected behaviour**, not a server crash loop:

```text
Every ~20 s   UDP keep-alive (type 0x08)     GameSpyQRServer
Every ~60 s   UDP heartbeat (type 0x03)      + delete/re-add pokemondpds in server list
              publicport 35198 vs localport 50046 — NAT port rewrite (expected behind home router)
```

Example dwc pattern (18:40–18:44):

```text
[GameSpyQRServer] Received keep alive from 46.210.240.181:35198...
[GameSpyQRServer] Received heartbeat ... gamename pokemondpds ...
[GamespyBackendServer] Deleted 1 pokemondpds servers where session = 1291320231
[GamespyBackendServer] Added ... pokemondpds servers: 1
```

**Interpretation:** NDS thinks it is online and keeps the session alive while the UI waits for something that never arrived (GPSP search response, and/or GPCM `STATUS(6)` / registration completion).

### Not captured in Session D tcpdump filter

T21 filter was `udp port 27900 or tcp port 29900` only — missed:

| Port | Proto | Service | Status |
|------|-------|---------|--------|
| 28910 | UDP | Master server browser | Unknown — widen filter next time |
| 29901 | TCP | GPSP player search | **Confirmed in dwc logs** (D12) |

### Noise (not NDS)

| Time | Source | What |
|------|--------|------|
| 18:39:17 | `62.56.175.16` | Mac `nc -zv 34.71.245.57 29900` port test after firewall fix |

---

## Root cause: GCP firewall (Sessions B/C) — **RESOLVED**

| Port | Proto | VM listening | GCP firewall (before fix) | External test (after fix) |
|------|-------|--------------|---------------------------|---------------------------|
| 443 | TCP | ✓ nginx | ✓ open | ✓ |
| 27900–28910 | UDP | ✓ dwc | ✓ open | ✓ |
| **29900** | TCP | ✓ dwc GPCM | **✗ blocked** | ✓ |
| **29901** | TCP | ✓ dwc GPSP | **✗ blocked** | ✓ |
| **29920** | TCP | ✓ dwc gamestats | **✗ blocked** | ✓ |

**Fix applied:** GCP ingress rule on VM network tag `pokemon-server` allowing TCP 29900, 29901, 29920 from `0.0.0.0/0`.

**Verify from outside:**

```bash
nc -z -G 3 -v 34.71.245.57 29900
nc -z -G 3 -v 34.71.245.57 29901
nc -z -G 3 -v 34.71.245.57 29920
```

**VM metadata (Session D):** project `send-email-project-440316`, tags `pokemon-server`, `dnssink`, `http-server`, `https-server`.

---

## Current blocker: GPSP `\search` not implemented (Session D)

| Layer | Status |
|-------|--------|
| DNS sinkhole | ✓ Working |
| NAS `/ac` | ✓ 200 OK |
| GPCM login (`:29900`) | ✓ `\lc\` logged_in |
| QR availability + registration (`:27900`) | ✓ |
| GPSP `\search` (`:29901`) | **✗ dwc ignores command** |
| NDS UI advances | **✗ stuck / loading** |

**Most likely cause:** NDS sent `\search\` with `lastname\6o92ph80rADAJ0ighkm9` at 18:39:47; dwc returned nothing. Game waits indefinitely while QR keep-alives continue.

**Secondary checks for next session** (not ruled out):

| Check | Why |
|-------|-----|
| GPCM `UPDATE_PROFILE` / lastname loop | Pipian steps 12–14 — game loops GETPROFILE until `lastname` appears in PROFILEINFO |
| GPCM `STATUS(6)` after registration | Pipian step 23 — may be required before UI advances |
| UDP `:28910` master browser | DNS queried; traffic not in tcpdump filter |
| NAS `svcloc` POST | Not seen in nginx logs yet — needed for some features |

**Emulator gap analysis** (upstream survey, fork scan, fix plan): [limitations README](../limitations/README.md#gpsp-search-gap--investigation-2026-06-26).

---

## Known dwc emulator gaps (for contributors)

See [limitations README](../limitations/README.md) for full GPSP investigation and implementation plan.

| Component | File | Implemented | Missing for Pokémon Gen 4 |
|-----------|------|-------------|----------------------------|
| NAS | `nas_server.py` | login, acctcreate, svcloc | — (login works) |
| GPCM | `gamespy_profile_server.py` | login, getprofile, updatepro, status | Verify lastname / STATUS(6) completion |
| QR | `gamespy_qr_server.py` | availability (0x09), heartbeat, challenge | — (works in Session D) |
| **GPSP** | `gamespy_player_search_server.py` | `otherslist` only | **`search` + `bsrdone`** |
| Master browser | `gamespy_server_browser_server.py` | partial | Unknown — not tested |
| Sake / GTS | `storage_server.py` | partial | Not reached |
| NAT neg | `gamespy_natneg_server.py` | partial | Not reached (multiplayer) |

**Suggested next code change:** See [limitations README — Implementation plan](../limitations/README.md#implementation-plan-next-agent).

---

## Sinkholed hostnames (reference)

From `dns_sinkhole/scripts/update-nds-ip.sh`:

```text
nintendowifi.net
nas.nintendowifi.net
naswii.nintendowifi.net
dls1.nintendowifi.net
gamestats.gs.nintendowifi.net
gamestats2.gs.nintendowifi.net
sake.gs.nintendowifi.net
secure.sake.gs.nintendowifi.net
pokemondpds.sake.gs.nintendowifi.net
gpcm.gs.nintendowifi.net
gpsp.gs.nintendowifi.net
pokemondpds.available.gs.nintendowifi.net
pokemondpds.master.gs.nintendowifi.net
pokemondpds.natneg1.gs.nintendowifi.net
pokemondpds.natneg2.gs.nintendowifi.net
pokemondpds.natneg3.gs.nintendowifi.net
pokemondpds.gamestats.gs.nintendowifi.net
pokemondpds.gamestats2.gs.nintendowifi.net
```

**Not sinkholed:** `conntest.nintendowifi.net` (forwarded to 8.8.8.8).

---

## Debug commands (run on VM)

### 1. dwc logs around the successful auth window

```bash
# dwc logs contain binary bytes — strip before grepping
docker logs dwc 2>&1 | tr -cd '\11\12\15\40-\176' | grep -iE '18:39|Ac request|Profile|availability|pokemondpds|login'
```

Full follow during next NDS attempt:

```bash
docker logs -f dwc 2>&1 | tr -cd '\11\12\15\40-\176'
```

### 2. GameSpy traffic — live capture (run before connecting NDS)

All GameSpy ports in one capture:

```bash
sudo tcpdump -nni ens4 \
  'udp port 27900 or udp port 27901 or udp port 28910 or tcp port 29900 or tcp port 29901 or tcp port 29920'
```

Availability + GPCM only (most relevant for current blocker):

```bash
sudo tcpdump -nni ens4 -X \
  'udp port 27900 or tcp port 29900'
```

DNS + GameSpy together (two terminals, or combine):

```bash
sudo tcpdump -nni ens4 \
  'udp port 53 or udp port 27900 or tcp port 29900'
```

### 3. nginx HTTPS (NAS / Sake / gamestats)

```bash
docker logs -f nginx-nds-gateway 2>&1
```

### 4. Verify dwc is listening on GameSpy ports

```bash
docker ps --format 'table {{.Names}}\t{{.Ports}}' | grep dwc
sudo ss -lntup | grep -E '27900|27901|28910|29900|29901|29920'
```

### 5. GCP firewall sanity check from outside VM

From your Mac (replace with VM IP):

```bash
nc -zv -G 3 34.71.245.57 29900   # GPCM — must succeed
nc -zv -G 3 34.71.245.57 29901   # GPSP
nc -u -z -v -w 2 34.71.245.57 27900
nc -u -z -v -w 2 34.71.245.57 28910  # master browser
```

---

## Current progress summary

| Step | A (~17:39) | B (~18:14) | C (~18:31) | D (~18:39) |
|------|------------|------------|------------|------------|
| conntest DNS → real Nintendo | — | ✓ | ✓ | ✓ |
| pokemondpds.available DNS | — | ✓ | ✓ | ✓ |
| UDP :27900 availability | — | ? | ✗ (GCP TCP*) | ✓ |
| nas DNS → sinkhole | — | ✓ | ✓ | ✓ |
| HTTPS POST /ac | ✗ 502 | ✓ 200 | ✓ 200 | ✓ 200 |
| gpcm.gs DNS | — | ✓ | ✓ | ✓ |
| TCP :29900 GPCM login | — | ✗ (GCP) | ✗ (GCP) | ✓ `\lc\` profileid 1 |
| QR registration (:27900) | — | — | — | ✓ client registered |
| GPCM STATUS(1) | — | — | — | ✓ |
| pokemondpds.master DNS | — | — | — | ✓ |
| gpsp.gs DNS | — | — | — | ✓ |
| TCP :29901 GPSP `\search` | — | — | — | ✗ **unhandled** |
| UDP :28910 master browser | — | — | — | ? (filter) |
| QR keep-alive (:27900) | — | — | — | ✓ ongoing |
| **NDS UI advances** | — | — | — | **✗ stuck** |
| GTS / Sake / multiplayer | — | — | — | — |

\*Session C: UDP GameSpy was open but TCP 29900 blocked — GPCM never connected.

**Session D blocker (confirmed):** GPSP `\search` not implemented in dwc. QR keep-alives are normal, not a failure loop.

**Next capture goal:** Implement or stub GPSP `\search` → `\bsrdone\`; capture full GPCM flow for `updatepro` / `STATUS(6)`; tcpdump all GameSpy ports.

---

## For future contributors

### How to add a new session to this doc

1. Note VM public IP and date (IP may change — run `curl ifconfig.me` on VM).
2. Run tcpdump on **all** GameSpy ports (see debug commands below) before connecting NDS.
3. Run `docker logs -f dwc 2>&1 | tr -cd '\11\12\15\40-\176'` — do not grep raw dwc logs (binary bytes break grep).
4. Record each DNS query, HTTP request, and dwc log line with UTC timestamp.
5. Mark each step ✓ / ✗ / ? in the progress table.
6. If NDS stops progressing, identify the **first missing or error response** — that is the blocker.

### Recommended development order (based on captures so far)

1. **GPSP `\search` handler** — see [limitations README](../limitations/README.md#implementation-plan-next-agent).
2. **Verify GPCM registration completion** — `updatepro` lastname + `STATUS(6)` (`gamespy_profile_server.py`).
3. **Master server browser** — UDP `:28910` when entering Wi-Fi Club rooms.
4. **Sake / GTS** — HTTPS to `sake.gs.nintendowifi.net` via nginx → dwc `:8000`.
5. **NAT negotiation** — UDP `:27901` for P2P battles.

### Related repo docs

- [Limitations](../limitations/README.md) — emulator gaps, upstream/fork survey, GPSP fix plan
- [Network explanation](../containers/network_explanation.md) — two-lane traffic (nginx vs GameSpy direct)
- [README](../../README.md) — GCP firewall port list
- [dns_sinkhole](../../dns_sinkhole/scripts/update-nds-ip.sh) — hostname list

---

## Changelog

| Date | Session | Notes |
|------|---------|-------|
| 2026-06-26 | A | NAS `/ac` 502 — dwc upstream crash on login |
| 2026-06-26 | B | First successful NAS `/ac` 200; GPCM DNS seen; GameSpy blocked at GCP (TCP 29900) |
| 2026-06-26 | C | Repeat of B; tcpdump confirms 0 GameSpy packets on `:27900`/`:29900` |
| 2026-06-26 | D | GCP firewall fixed (TCP 29900/29901/29920); full GPCM login + QR registration; **GPSP `\search` unhandled** — NDS UI stuck; QR keep-alives documented as normal |
| 2026-06-26 | doc | Expanded timeline: Pipian protocol ref, dwc log excerpts, contributor guide |
| 2026-06-26 | doc | Moved GPSP investigation to [limitations README](../limitations/README.md); timeline stays capture-focused |
