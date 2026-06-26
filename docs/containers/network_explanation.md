# Container networking in this project

This doc explains how traffic reaches the **nginx** and **dwc** containers on a Google Cloud VM.

## The three pieces

```text
  NDS
   |
   |  (1) DNS queries (UDP 53)
   v
 dnsmasq sinkhole on VM          "Where is nas.nintendowifi.net?" -> VM public IP
   |
   |  (2) HTTP/HTTPS (TCP 80 / 443)
   v
 nginx container                 TLS termination + reverse proxy
   |
   |  plain HTTP on pokemon_net
   v
 dwc container                   Nintendo backend emulator (many Python processes)

   |  (3) GameSpy (UDP/TCP on specific ports)
   +----------------------------> dwc container (direct, bypasses nginx)
```

This project uses two main containers:

| Container | Role | Ports published to VM |
|---|---|---|
| `nginx-nds-gateway` | Legacy TLS (NDS/3DS) + reverse proxy | `80`, `443` |
| `dwc` | Backend emulator (NAS, DLC, GameSpy, …) | GameSpy ports only (see below) |

Both join the Docker network **`pokemon_net`**.

---

## Important correction: not “nginx first, then everything direct”

Traffic splits by **protocol and service**, not by time.

```text
                    +------------------+
                    |   NDS / 3DS      |
                    +--------+---------+
                             |
              +--------------+---------------+
              |                              |
     HTTP/HTTPS (80, 443)            GameSpy (UDP/TCP)
     nas, dls1, gamestats, sake      27900, 27901, 28910,
                                     29900, 29901, 29920
              |                              |
              v                              v
     +----------------+             +----------------+
     | nginx container|             |  dwc container |
     |  :443 / :80    |             |  (direct)      |
     +-------+--------+             +----------------+
             |
             |  proxy_pass http://dwc:9000 / 9002 / 9003 / 8000
             v
     +----------------+
     |  dwc container |
     +----------------+
```

- **All Nintendo HTTP traffic** keeps going through nginx for the whole session. The NDS never talks to dwc port 9000 on the VM’s public IP.
- **GameSpy traffic** (including NAT negotiation on **27901/udp**) goes **straight to dwc**. It does not pass through nginx.

Port 443 is **HTTPS (TLS)**, not plain HTTP. Nginx terminates TLS using the NDS constraint certificate, then forwards **plain HTTP** to dwc internally.

---

## End-to-end flow (what the NDS actually does)

### Step 0 — DNS (before any container HTTP)

```text
  NDS  --UDP 53-->  VM (dnsmasq sinkhole)

  "conntest.nintendowifi.net?"  -->  "ask 8.8.8.8"  (real Nintendo; still online)
  "nas.nintendowifi.net?"       -->  VM public IP
  "dls1.nintendowifi.net?"      -->  VM public IP
  ...
```

DNS only tells the NDS **which IP** to connect to. It does not route traffic into containers.

### Step 1 — HTTP/HTTPS path (via nginx)

```text
  NDS
   |
   |  TCP connect to VM_PUBLIC_IP:443
   |  TLS handshake (legacy SSL — why nginx runs in a container)
   |  HTTP request with Host: nas.nintendowifi.net
   v
  VM host :443  ----port publish---->  nginx-nds-gateway :443
                                              |
                                              |  Host header selects upstream
                                              |  proxy_pass http://dwc:9000
                                              v
                                        dwc :9000 (NasServer)
```

Same pattern for other hostnames:

| `Host` header | nginx upstream | dwc port |
|---|---|---|
| `nas.nintendowifi.net`, `naswii.nintendowifi.net` | `dwc:9000` | NAS |
| `dls1.nintendowifi.net` | `dwc:9003` | DLC |
| `gamestats.gs.nintendowifi.net` | `dwc:9002` | Game stats |
| `sake.gs.nintendowifi.net` | `dwc:8000` | Storage |

Port 80 works the same way (plain HTTP, no TLS) — useful for local testing.

**dwc ports 8000–9003 are not published on the VM.** Only nginx needs to reach them, over `pokemon_net`.

### Step 2 — GameSpy path (direct to dwc)

```text
  NDS
   |
   |  UDP/TCP to VM_PUBLIC_IP:27900 (etc.)
   v
  VM host :27900  ----port publish---->  dwc :27900
                                              |
                                              v
                                        GameSpyQRServer
```

Published GameSpy ports (from `containers/dwc_container/docker-compose.yml`):

```text
  27900/udp   QR
  27901/udp   NAT negotiation
  28910/udp   server browser
  29900/tcp   profile
  29901/tcp   player search
  29920/tcp   gamestats
```

---

## From the VM’s point of view

From outside, everything hits **one public IP** on different ports:

```text
                    Internet / NDS
                          |
                          v
              +-----------------------+
              |  Google Cloud VM      |
              |  public IP            |
              +-----------+-----------+
                          |
        +-----------------+------------------+
        |                                    |
   :80, :443                           :27900, :27901, ...
        |                                    |
        v                                    v
   nginx container                      dwc container
```

Inside the VM (but outside the containers), **Docker** owns port forwarding:

- **`ports: "443:443"`** on nginx → traffic to `VM:443` is forwarded to nginx’s port 443.
- **`ports: "27900:27900/udp"`** on dwc → traffic to `VM:27900` is forwarded to dwc’s port 27900.

On Linux this is implemented with iptables/NAT rules managed by Docker — there is no separate service literally named “ports”; it is Docker’s **port publishing** feature.

---

## Inside a container: `127.0.0.1` vs `0.0.0.0`

Each container has its **own network namespace** — like a tiny separate machine.

```text
  Inside dwc container
  +------------------------------------------+
  |  NasServer listening on 127.0.0.1:9000   |  <-- only accepts from same container
  |  NasServer listening on 0.0.0.0:9000   |  <-- accepts from nginx on pokemon_net
  +------------------------------------------+
```

- **`127.0.0.1` (loopback)** — only processes *inside the same container* can connect.
- **`0.0.0.0`** — listen on all interfaces in that container, including the `pokemon_net` interface.

That is why `altwfc.docker.cfg` sets HTTP services to `0.0.0.0`: nginx is a **different container**, so its packets arrive on dwc’s `pokemon_net` interface, not on loopback.

Exception: **`GameSpyManager` stays on `127.0.0.1:27500`** — it is internal IPC between dwc processes only; nothing outside dwc should connect.

---

## How containers find each other: `pokemon_net`

Containers on the same Docker network can talk as if they were on a private LAN.

```text
  pokemon_net (Docker bridge network)
  +------------------------------------------------+
  |                                                |
  |   nginx-nds-gateway          dwc               |
  |   (gets IP 172.18.0.2)       (172.18.0.3)     |
  |          |                      ^              |
  |          |  http://dwc:9000     |              |
  |          +----------------------+              |
  |                                                |
  |   Docker embedded DNS: "dwc" -> 172.18.0.3    |
  +------------------------------------------------+
```

Your understanding is right in spirit:

- Containers do not hard-code each other’s IPs.
- Both join **`pokemon_net`**.
- Docker provides **DNS by container name**: `dwc` resolves to dwc’s current IP on that network.
- nginx config uses `server dwc:9000;` — Docker routes the packet between containers.

This is **not** the public internet; it is an isolated virtual network on the VM. Only ports explicitly **published** in compose are reachable from outside.

---

## Three concepts that are easy to confuse

| Concept | Meaning | Reaches dwc from internet? |
|---|---|---|
| Process binds **`0.0.0.0:9000`** inside dwc | dwc accepts connections on that port from other containers on `pokemon_net` | No — not by itself |
| **`EXPOSE 9000`** in Dockerfile | Documents the port; allows other containers on the network to connect | No |
| **`ports: "9000:9000"`** in compose | Forwards **VM host :9000** → **container :9000** | Yes |

In this project, dwc **HTTP ports are not published** to the VM. nginx → `dwc:9000` works via `pokemon_net` only. GameSpy ports **are** published because the NDS must reach dwc directly.

---

## Summary checklist

Your notes were mostly correct. Refinements:

| Your understanding | Verdict |
|---|---|
| Two containers: nginx + dwc | Correct |
| NDS hits VM public IP on various ports | Correct |
| Docker forwards published ports into containers | Correct (Docker port publishing / NAT) |
| `127.0.0.1` vs `0.0.0.0` inside containers | Correct |
| `pokemon_net` lets containers talk; Docker acts like DNS | Correct |
| First 443 for SSL/NAT, then everything direct to dwc | **Needs refinement** — HTTP stays on nginx; only GameSpy goes direct to dwc. NAT is **27901/udp** to dwc, not through nginx |
| Port 443 is “HTTP” | Minor fix — it is **HTTPS**; nginx decrypts then proxies plain HTTP to dwc |

See also:

- [containers/nginx_container/README.md](../../containers/nginx_container/README.md) — hostname → upstream table
- [containers/dwc_container/README.md](../../containers/dwc_container/README.md) — dwc ports and config
