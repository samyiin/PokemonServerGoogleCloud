#!/bin/bash

CURRENT_IP=$(curl -s ifconfig.me)

if [ -n "$CURRENT_IP" ]; then
    # NAS / login / DLC
    echo "$CURRENT_IP nintendowifi.net" > /etc/dnsmasq-nds.hosts
    echo "$CURRENT_IP nas.nintendowifi.net" >> /etc/dnsmasq-nds.hosts
    echo "$CURRENT_IP naswii.nintendowifi.net" >> /etc/dnsmasq-nds.hosts
    echo "$CURRENT_IP dls1.nintendowifi.net" >> /etc/dnsmasq-nds.hosts

    # Game stats HTTP (nginx -> dwc:9002)
    echo "$CURRENT_IP gamestats.gs.nintendowifi.net" >> /etc/dnsmasq-nds.hosts
    echo "$CURRENT_IP gamestats2.gs.nintendowifi.net" >> /etc/dnsmasq-nds.hosts

    # Sake storage (nginx -> dwc:8000)
    echo "$CURRENT_IP sake.gs.nintendowifi.net" >> /etc/dnsmasq-nds.hosts
    echo "$CURRENT_IP secure.sake.gs.nintendowifi.net" >> /etc/dnsmasq-nds.hosts
    echo "$CURRENT_IP pokemondpds.sake.gs.nintendowifi.net" >> /etc/dnsmasq-nds.hosts

    # GameSpy shared infrastructure (dwc direct)
    echo "$CURRENT_IP gpcm.gs.nintendowifi.net" >> /etc/dnsmasq-nds.hosts
    echo "$CURRENT_IP gpsp.gs.nintendowifi.net" >> /etc/dnsmasq-nds.hosts

    # GameSpy per-game hosts for Pokemon Gen 4 (pokemondpds)
    echo "$CURRENT_IP pokemondpds.available.gs.nintendowifi.net" >> /etc/dnsmasq-nds.hosts
    echo "$CURRENT_IP pokemondpds.master.gs.nintendowifi.net" >> /etc/dnsmasq-nds.hosts
    echo "$CURRENT_IP pokemondpds.natneg1.gs.nintendowifi.net" >> /etc/dnsmasq-nds.hosts
    echo "$CURRENT_IP pokemondpds.natneg2.gs.nintendowifi.net" >> /etc/dnsmasq-nds.hosts
    echo "$CURRENT_IP pokemondpds.natneg3.gs.nintendowifi.net" >> /etc/dnsmasq-nds.hosts
    echo "$CURRENT_IP pokemondpds.gamestats.gs.nintendowifi.net" >> /etc/dnsmasq-nds.hosts
    echo "$CURRENT_IP pokemondpds.gamestats2.gs.nintendowifi.net" >> /etc/dnsmasq-nds.hosts

    # conntest.nintendowifi.net intentionally omitted — forward to 8.8.8.8 via server= in dnsmasq.conf
fi
