#!/bin/bash
set -e
HOSTNAME="hot-bm-nl.spangled-atlas.ts.net"
cd /root
tailscale cert "$HOSTNAME"
cp "$HOSTNAME.crt" /etc/pve/local/pve-ssl.pem
cp "$HOSTNAME.key" /etc/pve/local/pve-ssl.key
chmod 640 /etc/pve/local/pve-ssl.key
systemctl restart pveproxy
