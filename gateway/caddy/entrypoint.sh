#!/bin/sh
set -e
export PDNS_API_KEY=$(cat /run/secrets/pdns_api_key)
export CROWDSEC_API_KEY=$(cat /run/secrets/crowdsec_api_key)
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
