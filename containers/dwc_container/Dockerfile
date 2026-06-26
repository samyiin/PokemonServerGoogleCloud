FROM python:2.7-slim

WORKDIR /app

COPY containers/dwc_container/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

COPY backend_servers/dwc_network_server_emulator /app
COPY containers/dwc_container/altwfc.docker.cfg /app/altwfc.cfg
COPY containers/dwc_container/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# HTTP upstreams for nginx
EXPOSE 8000 9000 9001 9002 9003 9009 9998

# GameSpy manager (internal) and client-facing GameSpy ports
EXPOSE 27500 27900/udp 27901/udp 28910/udp 29900 29901 29920

VOLUME ["/var/lib/dwc"]

ENTRYPOINT ["/entrypoint.sh"]
