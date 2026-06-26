# nginx reverse proxy (NDS / 3DS TLS gateway)

Custom nginx built with OpenSSL 1.0.2u so NDS and 3DS clients can complete legacy TLS (SSLv3, RC4) using the [NDS constraint](https://flewkey.com/blog/2020-07-12-nds-constraint.html) certificate chain.

Traffic flow:

```text
NDS / 3DS  --HTTPS:443-->  nginx-nds-gateway  --HTTP-->  dwc:9000 / 9002 / 9003 / 8000
GameSpy UDP/TCP           dwc (published directly, not via nginx)
```

Certificates live in `certs/` (copied from `reverse_proxy/nds_constraint/`). Regenerate them with the steps in [reverse_proxy/README.md](../../reverse_proxy/README.md), then:

```bash
cat server.crt NWC.crt > server-chain.crt
cp server-chain.crt server.key certs/
```

## Build and run

Start the dwc backend first (creates the shared `pokemon_net` network):

```bash
docker compose -f containers/dwc_container/docker-compose.yml up --build -d
```

Then build and start nginx:

```bash
docker compose -f containers/nginx_container/docker-compose.yml build --no-cache
docker compose -f containers/nginx_container/docker-compose.yml up -d
```

## Hostname → dwc upstream

| Hostname | dwc port | Service |
|---|---|---|
| `nas.nintendowifi.net`, `naswii.nintendowifi.net`, `conntest.nintendowifi.net` | 9000 | NAS |
| `dls1.nintendowifi.net` | 9003 | DLC |
| `gamestats.gs.nintendowifi.net`, `gamestats2.gs.nintendowifi.net` | 9002 | Game stats HTTP |
| `sake.gs.nintendowifi.net`, `*.sake.gs.nintendowifi.net` | 8000 | Storage |

Both port 443 (TLS termination) and port 80 (plain HTTP) proxy to the same dwc upstreams.

## Local smoke test

With both containers running:

```bash
curl -k --resolve nas.nintendowifi.net:443:127.0.0.1 https://nas.nintendowifi.net/
curl --resolve conntest.nintendowifi.net:80:127.0.0.1 http://conntest.nintendowifi.net/
```

NAS GET should return `ok`. Access logs include `$ssl_protocol` and `$ssl_cipher` for TLS debugging.
