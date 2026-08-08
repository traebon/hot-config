#!/bin/bash
# House of Trae — one-shot fleet-wide memory/swap check, reporting a single consolidated
# Ntfy notification. Built 2026-08-08 after a run of individual "check X memory too" asks
# ended up as 8 separate systemd-run one-shot units firing at the same time — this replaces
# that pattern with one script covering the whole fleet in one job.
#
# Usage: run directly, or schedule a one-off delayed check via:
#   systemd-run --unit=fleet-memcheck-oneshot --on-calendar="<time>" \
#     --timer-property=Persistent=true /usr/local/bin/fleet-memcheck.sh
set -uo pipefail

NTFY_URL="https://ntfy.house-of-trae.com"
NTFY_TOPIC="hot-alerts"
NTFY_TOKEN_FILE="/etc/apt-daily-update/ntfy_token"

# host -> ssh alias, empty string means "local" (the Gateway itself)
declare -A HOSTS=(
  [gateway]=""
  [hot-bm-nl]="hot-bm-nl"
  [sn-infra]="sn-infra"
  [sn-web]="sn-web"
  [sn-monitor]="sn-monitor"
  [sn-security]="sn-security"
  [hot-pn]="hot-pn"
  [hot-erp-nl]="hot-erp-nl"
)

out="Fleet memory check ($(date -Is)):"

for name in gateway hot-bm-nl sn-infra sn-web sn-monitor sn-security hot-pn hot-erp-nl; do
  alias="${HOSTS[$name]}"
  if [ -z "$alias" ]; then
    line="$(free -h | awk 'NR==2{printf "mem %s/%s used, %s avail",$3,$2,$7} NR==3{printf " | swap %s/%s",$3,$2}')"
  else
    line="$(ssh -o ConnectTimeout=8 -o BatchMode=yes "$alias" \
      "free -h | awk 'NR==2{printf \"mem %s/%s used, %s avail\",\$3,\$2,\$7} NR==3{printf \" | swap %s/%s\",\$3,\$2}'" 2>/dev/null)"
    [ -z "$line" ] && line="unreachable"
  fi
  out="$out
$name: $line"
done

# hot-bm-nl gets an extra ARC line since that's the host with the known ZFS ARC history
arc="$(ssh -o ConnectTimeout=8 -o BatchMode=yes hot-bm-nl \
  "grep -E '^size|^c_max' /proc/spl/kstat/zfs/arcstats" 2>/dev/null)"
[ -n "$arc" ] && out="$out
hot-bm-nl ARC: $(echo "$arc" | tr '\n' ' ')"

[ -f "$NTFY_TOKEN_FILE" ] && curl -fsS -m 15 -u ":$(cat "$NTFY_TOKEN_FILE")" \
  -H "X-Title: Fleet memory check" -H "X-Priority: default" \
  -d "$out" "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1
