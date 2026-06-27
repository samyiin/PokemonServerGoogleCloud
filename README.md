# PokemonServerGoogleCloud

Self-hosted Pokémon Gen 4 (Diamond / Pearl / Platinum / HeartGold / SoulSilver) online server on Google Cloud.

## Architecture

Three components run on one VM:

```text
  NDS
   |
   |  DNS (UDP 53)                    HTTP/HTTPS (80, 443)        GameSpy (UDP/TCP)
   v                                v                            v
 dnsmasq sinkhole              nginx container                 dwc container
 (host)                        (legacy TLS + reverse proxy)    (backend emulator)
                                    |                            ^
                                    +---- pokemon_net (Docker) --+
```

| Component | What it does | Docs |
|---|---|---|
| DNS sinkhole | Hijacks `*.nintendowifi.net` to your VM IP | [dns_sinkhole/README.md](dns_sinkhole/README.md) |
| nginx container | Terminates NDS legacy TLS on `:443`, proxies HTTP to dwc | [containers/nginx_container/README.md](containers/nginx_container/README.md) |
| dwc container | Nintendo WFC / GameSpy backend | [containers/dwc_container/README.md](containers/dwc_container/README.md) |

Network details: [docs/containers/network_explanation.md](docs/containers/network_explanation.md)

---

## Prerequisites

On the Google Cloud VM:

- Ubuntu/Debian (tested workflow)
- External (public) IP — note this down; the NDS uses it as its DNS server
- [Docker](https://docs.docker.com/engine/install/ubuntu/) and Docker Compose plugin installed
- Repo cloned on the VM with submodules initialized (see below)

### Clone the repo (includes dwc backend submodule)

The dwc backend lives in a git submodule at `backend_servers/dwc_network_server_emulator`. Clone with:

```bash
git clone --recurse-submodules git@github.com:samyiin/PokemonServerGoogleCloud.git ~/PokemonServerGoogleCloud
```

If you already cloned without submodules:

```bash
cd ~/PokemonServerGoogleCloud
git submodule update --init --recursive
```

Verify before building containers:

```bash
test -f backend_servers/dwc_network_server_emulator/master_server.py && echo "dwc source OK"
```

**GCP firewall** — allow inbound traffic to the VM for:

| Port | Protocol | Purpose |
|---|---|---|
| 53 | UDP | DNS sinkhole |
| 80 | TCP | HTTP (nginx) |
| 443 | TCP | HTTPS (nginx, NDS login) |
| 27900 | UDP | GameSpy QR |
| 27901 | UDP | NAT negotiation |
| 28910 | UDP | Server browser |
| 29900 | TCP | GameSpy profile |
| 29901 | TCP | Player search |
| 29920 | TCP | GameSpy gamestats |

In GCP: VPC network → Firewall → create rule targeting your VM’s network tag or service account.

**TLS certificates** — nginx needs `server-chain.crt` and `server.key` in `containers/nginx_container/certs/`. Generate on your Mac (OpenSSL 3 is fine) using [reverse_proxy/README.md](reverse_proxy/README.md), then copy into that folder before building nginx. The container runs OpenSSL 1.0.2u for the handshake; cert files themselves are standard PEM.

---

## One-time setup (first deploy on the VM)

Run these once after cloning the repo.

### 1. Install dnsmasq

```bash
sudo apt update && sudo apt install dnsmasq -y
```

Find your VM’s outward-facing network interface (often `ens4` on GCP):

```bash
ip route get 8.8.8.8
# Example output: ... dev ens4 src 10.x.x.x
```

Edit `/etc/dnsmasq.conf`:

```bash
port=5353
interface=ens4          # replace with your interface from above
bind-interfaces
addn-hosts=/etc/dnsmasq-nds.hosts
server=/conntest.nintendowifi.net/8.8.8.8
server=8.8.8.8
```

`conntest` is forwarded to real Nintendo; everything else in the hosts file goes to your VM.

Port 53 is usually taken on GCP, so redirect incoming DNS to dnsmasq on 5353:

```bash
sudo iptables -t nat -A PREROUTING -i ens4 -p udp --dport 53 -j REDIRECT --to-ports 5353
```

Replace `ens4` with your interface. Add the same line to `~/.bashrc` (or a systemd unit) so it survives reboot — see [dns_sinkhole/README.md](dns_sinkhole/README.md).

Install the DNS hijack script (writes `/etc/dnsmasq-nds.hosts` with your current public IP on each start):

```bash
sudo cp dns_sinkhole/scripts/update-nds-ip.sh /usr/local/bin/update-nds-ip.sh
sudo chmod +x /usr/local/bin/update-nds-ip.sh

sudo mkdir -p /etc/systemd/system/dnsmasq.service.d/
echo -e "[Service]\nExecStartPre=+/usr/local/bin/update-nds-ip.sh" | sudo tee /etc/systemd/system/dnsmasq.service.d/override.conf

sudo systemctl daemon-reload
sudo systemctl enable dnsmasq
sudo systemctl restart dnsmasq
```

Verify:

```bash
sudo ss -lntup | grep 5353
dig @127.0.0.1 -p 5353 nas.nintendowifi.net +short   # should return VM public IP
dig @127.0.0.1 -p 5353 conntest.nintendowifi.net +short  # should NOT be your VM IP
```

### 2. Ensure nginx certs are present

```bash
ls containers/nginx_container/certs/server-chain.crt containers/nginx_container/certs/server.key
```

If missing, generate per [reverse_proxy/README.md](reverse_proxy/README.md) and copy the two files into `containers/nginx_container/certs/`.

---

## Start the server (every boot / after changes)

From the repo root on the VM:

### Step 1 — DNS sinkhole
Technically it starts by itself, if not
```bash
sudo systemctl restart dnsmasq
```

If you only added it to `.bashrc` then no need this either:

```bash
sudo iptables -t nat -A PREROUTING -i ens4 -p udp --dport 53 -j REDIRECT --to-ports 5353
```

### Step 2 — dwc backend (creates `pokemon_net`)

```bash
docker compose -f containers/dwc_container/docker-compose.yml up --build -d
docker ps   # expect container "dwc" running
```

### Step 3 — nginx reverse proxy

```bash
# build only once is enough
docker compose -f containers/nginx_container/docker-compose.yml up --build -d
docker ps   # expect "nginx-nds-gateway" and "dwc"
```

**Order matters:** dwc first (creates Docker network `pokemon_net`), then nginx (joins that network).

### Step 4 — Configure the NDS

On the Nintendo DS Wi‑Fi settings, set **Primary DNS** to your VM’s **external public IP**. Leave secondary DNS empty or `8.8.8.8`.

---

## Smoke tests (on the VM)

```bash
# DNS
dig @127.0.0.1 -p 5353 nas.nintendowifi.net +short

# HTTPS via nginx (legacy TLS)
curl -k --resolve nas.nintendowifi.net:443:127.0.0.1 https://nas.nintendowifi.net/
# Expected: ok

# Plain HTTP
curl --resolve nas.nintendowifi.net:80:127.0.0.1 http://nas.nintendowifi.net/

# Containers healthy
docker logs dwc --tail 20
docker logs nginx-nds-gateway --tail 20
```

From your laptop (replace `VM_IP`):

```bash
nc -zu -v -w 2 VM_IP 53
curl -k --resolve nas.nintendowifi.net:443:VM_IP https://nas.nintendowifi.net/
```

---

## Activity monitor (while testing NDS)

Unified live view of GameSpy/DNS port traffic (filtered to your NDS/hotspot IP) plus full dwc and nginx container logs. Output is shown on screen and saved under `test/activity_monitor/runlogs/`.

On the VM, pass your **hotspot public IP** (changes each session — find it on your phone or from `tcpdump` before filtering):

```bash
cd ~/PokemonServerGoogleCloud/test/activity_monitor
./monitor.sh 203.0.113.42
```

Streams:

| Prefix | Source | Filter |
|---|---|---|
| `[ports]` | `tcpdump` on VM NIC | Your `CLIENT_IP` + ports in [test/activity_monitor/ports.txt](test/activity_monitor/ports.txt) |
| `[dwc]` | `docker logs -f dwc` | None |
| `[nginx]` | `docker logs -f nginx-nds-gateway` | None |

Options:

```bash
INTERFACE=ens4 ./monitor.sh 203.0.113.42   # GCP NIC if auto-detect is wrong
SKIP_TCPDUMP=1 ./monitor.sh 203.0.113.42    # container logs only (no sudo)
```

Requires `tcpdump` (`sudo apt install tcpdump`). Ctrl+C stops the monitor; the run log file path is printed at startup.

---

## Stop / restart

```bash
docker compose -f containers/nginx_container/docker-compose.yml down
docker compose -f containers/dwc_container/docker-compose.yml down
sudo systemctl stop dnsmasq
```

Restart in the same order as [Start the server](#start-the-server-every-boot--after-changes): dnsmasq → dwc → nginx.

---

## What the NDS does

After DNS is set to your VM IP:

1. **Connectivity test** — `conntest.nintendowifi.net` → forwarded to real Nintendo (`8.8.8.8`), not your server.
2. **Login / NAS** — `nas.nintendowifi.net` → your VM IP → nginx `:443` (TLS) → dwc `:9000`.
3. **DLC, stats, storage** — other hijacked hostnames → nginx `:443` or `:80` → dwc `:9003` / `:9002` / `:8000`.
4. **Multiplayer (GameSpy)** — NDS connects directly to your VM on `27900`, `27901`, `29900`, etc. → dwc (not via nginx).

---

## Troubleshooting

| Symptom | Check |
|---|---|
| `can't open file 'master_server.py'` / empty `backend_servers/dwc_network_server_emulator` | Run `git submodule update --init --recursive`, then rebuild dwc |
| nginx `host not found in upstream "dwc:9000"` | dwc must be running first; fix dwc source, then `docker compose ... dwc ... up --build -d` |
| NDS can’t connect online | NDS DNS = VM public IP; GCP firewall allows UDP 53 |
| DNS resolves but no HTTPS | `docker ps`; port 443 published on nginx; certs in `certs/` |
| HTTPS works, login fails | `docker logs dwc`; dwc running on `pokemon_net` |
| Multiplayer fails | GCP firewall UDP/TCP GameSpy ports; `docker ps` shows dwc port mappings |
| VM reboot broke DNS | Re-run iptables redirect; `sudo systemctl status dnsmasq` |
| Public IP changed | `sudo /usr/local/bin/update-nds-ip.sh && sudo systemctl restart dnsmasq` |

---

## Local development (Mac)

See [docs/test_on_mackbook/README.md](docs/test_on_mackbook/README.md). On Apple Silicon, dwc compose uses `platform: linux/amd64`.

---

## Further reading

- [dns_sinkhole/README.md](dns_sinkhole/README.md) — dnsmasq details
- [reverse_proxy/README.md](reverse_proxy/README.md) — NDS constraint TLS certificates
- [containers/dwc_container/README.md](containers/dwc_container/README.md) — dwc ports and config
- [containers/nginx_container/README.md](containers/nginx_container/README.md) — nginx hostname → upstream table
- [docs/containers/network_explanation.md](docs/containers/network_explanation.md) — how Docker networking fits together
