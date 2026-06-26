# dwc_network_server_emulator container

Docker image for [dwc_network_server_emulator](../../backend_servers/dwc_network_server_emulator). Apache is **not** included — use nginx as the reverse proxy instead.

## Build and run

From the repo root:

```bash
docker compose -f containers/dwc_container/docker-compose.yml up --build -d
```

Or build manually:

```bash
docker build -f containers/dwc_container/Dockerfile -t dwc .
docker run -d --name dwc --platform linux/amd64 \
  -p 27900:27900/udp -p 27901:27901/udp -p 28910:28910/udp \
  -p 29900:29900 -p 29901:29901 -p 29920:29920 \
  -v dwc_data:/var/lib/dwc \
  --network pokemon_net \
  dwc
```

On Apple Silicon (M1/M2), keep `--platform linux/amd64` — the emulator requires Python 2.7.

## nginx upstream mappings

Point nginx at the `dwc` container on the shared Docker network (`pokemon_net`). These replace the Apache virtual hosts in `backend_servers/dwc_network_server_emulator/tools/apache-hosts/`.

| Hostname | dwc port | Purpose |
|---|---|---|
| `nas.nintendowifi.net`, `naswii.nintendowifi.net`, `conntest.nintendowifi.net` | 9000 | NAS |
| `dls1.nintendowifi.net` | 9003 | DLC download |
| `gamestats.gs.nintendowifi.net`, `gamestats2.gs.nintendowifi.net` | 9002 | Game stats HTTP |
| `sake.gs.nintendowifi.net`, `*.sake.gs.nintendowifi.net` | 8000 | Storage |

Example nginx server block (NAS):

```nginx
server {
    listen 80;
    server_name nas.nintendowifi.net naswii.nintendowifi.net conntest.nintendowifi.net;

    location / {
        proxy_pass http://dwc:9000;
        proxy_set_header Host $host;
    }
}
```

Connect your nginx container to the same network:

```bash
docker network connect pokemon_net <nginx-container>
```

## Ports

| Port | Protocol | Service |
|---|---|---|
| 8000 | TCP | Storage (sake.gs) |
| 9000 | TCP | NAS |
| 9001 | TCP | Internal stats |
| 9002 | TCP | Game stats HTTP |
| 9003 | TCP | DLC (dls1) |
| 9009 | TCP | Admin page |
| 9998 | TCP | Register page |
| 27900 | UDP | GameSpy QR |
| 27901 | UDP | GameSpy NAT negotiation |
| 28910 | UDP | GameSpy server browser |
| 29900 | TCP | GameSpy profile |
| 29901 | TCP | GameSpy player search |
| 29920 | TCP | GameSpy gamestats |

HTTP ports only need to be published to the host if nginx runs outside Docker. GameSpy ports must be published for NDS clients.

## Data persistence

`gpcm.db` and `storage.db` are stored in the `dwc_data` volume at `/var/lib/dwc`.

## Configuration

Container config is `altwfc.docker.cfg`, copied to `/app/altwfc.cfg` at build time. HTTP services bind to `0.0.0.0` so nginx can reach them across the Docker network.
