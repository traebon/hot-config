#!/bin/bash
# House of Trae — manual edge failover runbook (Option C, docs/HoT_Edge_Load_Balancing_Scope.md)
#
# Cuts privatenexus.net + erp.dickson-supplies.com's public A records over to the standby edge
# (hot-edge-ch, 82.38.64.63), or reverts them back to the Gateway (151.241.217.91).
#
# DELIBERATELY MANUAL-TRIGGER-ONLY. No automated failover exists (see the scope doc's open
# items) — this exists so a Gateway outage doesn't leave Mr. Byrne with no lever to pull. Only
# run `cutover` once you've confirmed the Gateway is genuinely down (not flapping) — same
# soft/hard/manual-escalation discipline reboot-recovery-watchdog.sh uses elsewhere in this
# project, just human-executed instead of automated.
#
# Deliberately kept on hot-edge-ch itself (and tracked in hot-config, run-from-anywhere), NOT
# only on the Gateway — it has to work precisely when the Gateway can't be reached.
#
# Usage:
#   ./edge-failover.sh status
#   ./edge-failover.sh cutover [--yes]
#   ./edge-failover.sh revert  [--yes]

set -euo pipefail

PDNS_URL="http://10.10.0.1:8081"
PDNS_API_KEY_FILE="${PDNS_API_KEY_FILE:-/opt/stacks/caddy/secrets/pdns_api_key.txt}"
GATEWAY_IP="151.241.217.91"
EDGE_IP="82.38.64.63"

if [ -f "$PDNS_API_KEY_FILE" ]; then
  PDNS_API_KEY="$(cat "$PDNS_API_KEY_FILE")"
else
  echo "ERROR: PowerDNS API key not found at $PDNS_API_KEY_FILE" >&2
  echo "Set PDNS_API_KEY_FILE to point at a file containing it, or PDNS_API_KEY directly." >&2
  PDNS_API_KEY="${PDNS_API_KEY:-}"
  [ -z "$PDNS_API_KEY" ] && exit 1
fi

# record name -> zone name (both must end in a trailing dot, PowerDNS's own convention)
declare -A TARGETS=(
  ["privatenexus.net."]="privatenexus.net."
  ["erp.dickson-supplies.com."]="dickson-supplies.com."
)

patch_record() {
  local name="$1" zone="$2" ip="$3"
  curl -s -X PATCH -H "X-API-Key: $PDNS_API_KEY" -H "Content-Type: application/json" \
    "$PDNS_URL/api/v1/servers/localhost/zones/$zone" \
    -d "{\"rrsets\":[{\"name\":\"$name\",\"type\":\"A\",\"ttl\":300,\"changetype\":\"REPLACE\",\"records\":[{\"content\":\"$ip\",\"disabled\":false}]}]}" \
    -o /dev/null -w "%{http_code}"
}

get_record() {
  local name="$1" zone="$2"
  curl -s -H "X-API-Key: $PDNS_API_KEY" "$PDNS_URL/api/v1/servers/localhost/zones/$zone" \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
for rr in d['rrsets']:
    if rr['name'] == '$name' and rr['type'] == 'A':
        print(rr['records'][0]['content'])
" 2>/dev/null
}

status() {
  echo "Current A records:"
  for name in "${!TARGETS[@]}"; do
    zone="${TARGETS[$name]}"
    ip="$(get_record "$name" "$zone")"
    if [ "$ip" = "$GATEWAY_IP" ]; then loc="Gateway (normal)"
    elif [ "$ip" = "$EDGE_IP" ]; then loc="hot-edge-ch (FAILED OVER)"
    else loc="UNKNOWN ($ip)"; fi
    printf "  %-30s -> %-16s [%s]\n" "$name" "$ip" "$loc"
  done
}

preflight_edge() {
  echo "Checking hot-edge-ch can actually serve both domains right now..."
  for d in privatenexus.net erp.dickson-supplies.com; do
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 --resolve "$d:443:$EDGE_IP" "https://$d/" || echo 000)"
    if [ "$code" != "200" ]; then
      echo "  FAIL: $d returned HTTP $code via hot-edge-ch -- DO NOT cut over, edge isn't healthy right now."
      echo "  (Caddy/CrowdSec on hot-edge-ch, or its wg1/wg2 tunnels to hot-pn/hot-erp-nl, may need attention first.)"
      exit 1
    fi
    echo "  OK: $d -> HTTP 200 via hot-edge-ch"
  done
}

confirm() {
  [ "${1:-}" = "--yes" ] && return 0
  read -rp "Type YES to proceed: " ans
  [ "$ans" = "YES" ]
}

ACTION="${1:-status}"

case "$ACTION" in
  status)
    status
    ;;
  cutover)
    echo "=== EDGE CUTOVER: privatenexus.net + erp.dickson-supplies.com -> hot-edge-ch ($EDGE_IP) ==="
    preflight_edge
    echo
    status
    echo
    confirm "${2:-}" || { echo "Aborted."; exit 1; }
    for name in "${!TARGETS[@]}"; do
      zone="${TARGETS[$name]}"
      code="$(patch_record "$name" "$zone" "$EDGE_IP")"
      echo "  $name -> $EDGE_IP : HTTP $code"
    done
    echo "Done. TTL is 300s -- allow up to 5 min for full propagation."
    echo "Run '$0 revert' once the Gateway is confirmed back and healthy."
    status
    ;;
  revert)
    echo "=== EDGE REVERT: privatenexus.net + erp.dickson-supplies.com -> Gateway ($GATEWAY_IP) ==="
    status
    echo
    confirm "${2:-}" || { echo "Aborted."; exit 1; }
    for name in "${!TARGETS[@]}"; do
      zone="${TARGETS[$name]}"
      code="$(patch_record "$name" "$zone" "$GATEWAY_IP")"
      echo "  $name -> $GATEWAY_IP : HTTP $code"
    done
    echo "Done. TTL is 300s -- allow up to 5 min for full propagation."
    status
    ;;
  *)
    echo "Usage: $0 {status|cutover [--yes]|revert [--yes]}"
    exit 1
    ;;
esac
