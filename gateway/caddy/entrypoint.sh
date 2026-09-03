#!/bin/sh
set -e
PDNS_API_KEY="$(cat /run/secrets/pdns_api_key)" || { echo "failed to read PDNS_API_KEY secret" >&2; exit 1; }
CROWDSEC_API_KEY="$(cat /run/secrets/crowdsec_api_key)" || { echo "failed to read CROWDSEC_API_KEY secret" >&2; exit 1; }
export PDNS_API_KEY CROWDSEC_API_KEY
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
