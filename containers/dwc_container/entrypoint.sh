#!/bin/sh
set -e

cd /app

mkdir -p /var/lib/dwc

for db in gpcm.db storage.db; do
    if [ -e "/var/lib/dwc/$db" ]; then
        rm -f "$db"
        ln -s "/var/lib/dwc/$db" "$db"
    elif [ -e "$db" ]; then
        mv "$db" "/var/lib/dwc/$db"
        ln -s "/var/lib/dwc/$db" "$db"
    fi
done

exec python master_server.py
