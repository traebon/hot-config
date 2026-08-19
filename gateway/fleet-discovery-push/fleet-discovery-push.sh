#!/bin/bash
# House of Trae — Gateway-consolidated push into PN's Discovery pipeline
# (Option B2 of docs/HoT_Automation_Self_Healing_Scope.md Section 6, 2026-08-19).
#
# hot-pn already runs its own local discovery-agent.sh -> POST /api/discovery/ingest
# for itself. This script covers every OTHER fleet host by reusing the Gateway's
# existing SSH reach (the same trust boundary fleet-health-sweep already uses) instead
# of giving each VLAN-internal host a new outbound path of its own (that was Option
# B1, not chosen — see the scope doc).
#
# Two deliberate differences from hot-pn's own agent, both required for correctness
# once more than one host is pushing (found live 2026-08-19 while scoping this):
#   1. suggested_slug/suggested_name are host-qualified ("sn-web-watchtower", not
#      "watchtower") - generic container names (watchtower, node-exporter, promtail)
#      are reused verbatim across most of the fleet; without qualification, approving
#      a 2nd same-named candidate from a different host would 409 on services.slug.
#   2. suggested_runtime is "external", never "docker", for every candidate pushed
#      here. PN's approve handler sets services.container_name = raw_name only when
#      runtime === "docker", on the assumption that means "a container PN's own
#      Docker proxy can reach." That's true for hot-pn's own agent but false for
#      every host this script covers - and hot-pn already runs its own container
#      literally named "watchtower" too, so an unqualified "docker" runtime here
#      would risk PN automation (MCP restart, blast-radius checks) acting on the
#      WRONG physical container. "external" is a real, valid runtime_type that
#      correctly signals "PN can see this, not act on it" - raw_data still carries
#      the real host/image/ports for a human reviewer.
#
# Also required a real backend fix, applied 2026-08-19: discovery_candidates'
# dedup index was (tenant_id, source, raw_name), no host — generic names collide
# across most of the fleet (watchtower alone runs identically-named on 6 of 8
# hosts), so without the host-aware index the 2nd+ host's push silently overwrote
# the 1st's row. See routes/discovery.js's upsertCandidate() comment on hot-pn.
set -uo pipefail

PN_INGEST_URL="https://privatenexus.net/api/discovery/ingest"
PN_TOKEN_FILE="/etc/fleet-discovery-push/pn_agent_token"
NTFY_URL="https://ntfy.house-of-trae.com"
NTFY_TOPIC="hot-alerts"
NTFY_TOKEN_FILE="/etc/apt-daily-update/ntfy_token"
LOG=/var/log/fleet-discovery-push.log
PYSCRIPT="/opt/hot-config/gateway/fleet-discovery-push/build_and_push.py"

notify() {
  local priority="$1" title="$2" message="$3"
  [ -f "$NTFY_TOKEN_FILE" ] || return 0
  curl -fsS -m 10 -u ":$(cat "$NTFY_TOKEN_FILE")" \
    -H "X-Title: $title" -H "X-Priority: $priority" \
    -d "$message" "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1 || true
}

if [ ! -f "$PN_TOKEN_FILE" ]; then
  echo "$(date -Is) FATAL: no PN agent token at $PN_TOKEN_FILE" >> "$LOG"
  notify high "fleet-discovery-push: missing token" "No PN agent token at $PN_TOKEN_FILE — nothing pushed."
  exit 1
fi

# host -> ssh alias ("" = local Gateway), runtime_type -> real VALID_RUNTIME_TYPES
# value for that host's own system_info candidate (docker candidates are always
# "external", see header). hot-pn is deliberately excluded - it already pushes
# for itself via its own discovery-agent.timer.
declare -A HOSTS=(
  [gateway]=""
  [hot-bm-nl]="hot-bm-nl"
  [sn-infra]="sn-infra"
  [sn-web]="sn-web"
  [sn-monitor]="sn-monitor"
  [sn-security]="sn-security"
  [hot-erp-nl]="hot-erp-nl"
)
declare -A RUNTIME=(
  [gateway]="vps"
  [hot-bm-nl]="vps"
  [sn-infra]="vm"
  [sn-web]="vm"
  [sn-monitor]="vm"
  [sn-security]="vm"
  [hot-erp-nl]="vps"
)

collect_cmd='
  echo "HOSTNAME_F=$(hostname)"
  echo "OS_PRETTY=$(. /etc/os-release && echo "$PRETTY_NAME")"
  echo "KERNEL=$(uname -r)"
  echo "UPTIME_H=$(uptime -p)"
  echo "CPU_CORES=$(nproc)"
  echo "MEM_TOTAL_MB=$(free -m | awk "/^Mem:/{print \$2}")"
  echo "MEM_USED_MB=$(free -m | awk "/^Mem:/{print \$3}")"
  echo "DISK_TOTAL=$(df -h / | awk "NR==2{print \$2}")"
  echo "DISK_USED=$(df -h / | awk "NR==2{print \$3}")"
  echo "DISK_PCT=$(df -h / | awk "NR==2{print \$5}")"
  echo "---DOCKER---"
  docker ps --format "{{json .}}" 2>/dev/null
'

total_inserted=0
total_errors=0

for name in gateway hot-bm-nl sn-infra sn-web sn-monitor sn-security hot-erp-nl; do
  alias="${HOSTS[$name]}"
  runtime="${RUNTIME[$name]}"

  if [ -z "$alias" ]; then
    raw="$(bash -c "$collect_cmd")"
  else
    raw="$(ssh -o ConnectTimeout=8 -o BatchMode=yes "$alias" "$collect_cmd" 2>/dev/null)"
  fi

  if [ -z "$raw" ]; then
    echo "$(date -Is) $name: unreachable or empty response, skipping" >> "$LOG"
    total_errors=$((total_errors + 1))
    continue
  fi

  facts="$(echo "$raw" | sed -n '1,/^---DOCKER---$/p' | grep -v '^---DOCKER---$')"
  docker_json="$(echo "$raw" | sed -n '/^---DOCKER---$/,$p' | tail -n +2)"

  result="$(
    { echo "$facts"; } | \
    HOST_NAME="$name" RUNTIME_TYPE="$runtime" \
    PN_TOKEN="$(cat "$PN_TOKEN_FILE")" PN_INGEST_URL="$PN_INGEST_URL" \
    DOCKER_JSON="$docker_json" \
    python3 "$PYSCRIPT" 2>&1
  )"

  echo "$(date -Is) $name: $result" >> "$LOG"
  if echo "$result" | grep -qE '"ok": *true'; then
    ins="$(echo "$result" | grep -oE '"inserted": *[0-9]+' | grep -oE '[0-9]+' || echo 0)"
    total_inserted=$((total_inserted + ${ins:-0}))
  else
    total_errors=$((total_errors + 1))
  fi
done

echo "$(date -Is) run complete: inserted=$total_inserted errors=$total_errors" >> "$LOG"
if [ "$total_errors" -gt 0 ]; then
  notify high "fleet-discovery-push: $total_errors host(s) failed" "See $LOG on the Gateway for detail."
fi
