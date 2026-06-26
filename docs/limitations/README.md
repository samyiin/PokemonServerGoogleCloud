# Known limitations

What this stack can and cannot do today, and how the backend pieces relate.

**Related docs:**

- [Request timeline](../Pokemon/request_timeline.md) — live NDS capture evidence and current blockers
- [Network explanation](../containers/network_explanation.md) — nginx vs dwc traffic paths
- [pkmn-classic-framework README](../../backend_servers/pkmn-classic-framework/README.md) — upstream feature list

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

As of Session D in the request timeline, a real NDS reaches NAS login, GPCM login, and QR registration, then **hangs** because dwc ignores GPSP `\search` on TCP `:29901`.

| Step | Status |
|------|--------|
| DNS sinkhole | Working |
| NAS `/ac` | Working |
| GPCM login (`:29900`) | Working |
| QR registration (`:29900` UDP) | Working |
| GPSP `\search` (`:29901`) | **Not implemented** in dwc |
| NDS UI advances past setup | **Blocked** |

dwc’s `gamespy_player_search_server.py` only handles `otherslist` (mainly Mario Kart Wii). Pokémon registration sends `\search` with a `lastname` and expects buddy records plus `\bsrdone\`. Upstream dwc forks (barronwaffles, polaris-) have the same gap.

**Fix location:** dwc submodule — add a `perform_search()` handler, not pkmn-classic-framework.

Secondary checks not ruled out: GPCM `UPDATE_PROFILE` / lastname loop, GPCM `STATUS(6)`, UDP `:28910` master browser.

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
