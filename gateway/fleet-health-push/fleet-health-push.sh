#!/bin/bash
# fleet-health-push — pushes real docker-container liveness/health facts into PrivateNexus for
# every service PN's own pull-based prober (healthProbe.js) structurally cannot reach itself:
# containers on other hosts with no published network port at all, plus the 5 VM/VPS meta-rows
# hot-pn's own deliberately-narrow wg3 tunnel can't reach directly (only sn-monitor/sn-security
# are widened — see network.md's wg3 note; widening further just for health checks would undo
# this project's own long-standing narrow-tunnel-scoping discipline).
#
# Built 2026-09-11 at Mr. Byrne's direct request: "none of these squares should be without a
# health check or backup policy or record ... that's why we have created jarvis" — every service
# needs real, honest coverage, not a blank field. This reuses the Gateway's existing fleet-wide SSH
# reach (same trust boundary as fleet-health-sweep.sh/fleet-discovery-push.sh) rather than
# widening PN's own network reach, and reuses fleet-discovery-push's existing PN agent token rather
# than provisioning a new docker secret.
set -uo pipefail

PN_HEALTH_PUSH_URL="https://privatenexus.net/api/services/health-push"
PN_TOKEN_FILE="/etc/fleet-discovery-push/pn_agent_token"
NTFY_URL="https://ntfy.house-of-trae.com"
NTFY_TOPIC="hot-alerts"
NTFY_TOKEN_FILE="/etc/apt-daily-update/ntfy_token"
LOG="/var/log/fleet-health-push.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

notify() {
  local priority="$1" title="$2" message="$3"
  [ -f "$NTFY_TOKEN_FILE" ] || return 0
  curl -fsS -m 10 -u ":$(cat "$NTFY_TOKEN_FILE")" \
    -H "X-Title: $title" -H "X-Priority: $priority" \
    -d "$message" "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1 || true
}

if [ ! -f "$PN_TOKEN_FILE" ]; then
  log "FATAL: no PN agent token at $PN_TOKEN_FILE"
  notify high "fleet-health-push: missing token" "No PN agent token at $PN_TOKEN_FILE — nothing pushed."
  exit 1
fi
PN_TOKEN="$(cat "$PN_TOKEN_FILE")"

# Results accumulator — JSON array built incrementally via a temp file (bash has no clean way to
# build a large JSON array in-memory across many small appends without a real array + join, and
# this keeps each entry's construction trivially inspectable in the log on failure).
RESULTS_FILE=$(mktemp)
echo "[]" > "$RESULTS_FILE"

add_result() {
  local slug="$1" status="$2" detail="$3"
  local esc_detail
  esc_detail=$(printf '%s' "$detail" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
  python3 - "$RESULTS_FILE" "$slug" "$status" "$esc_detail" <<'PYEOF'
import json, sys
path, slug, status, esc_detail = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(path) as f:
    results = json.load(f)
results.append({"slug": slug, "status": status, "detail": json.loads(esc_detail)})
with open(path, "w") as f:
    json.dump(results, f)
PYEOF
}

# Maps a real `docker inspect` State (as JSON) to PN's status vocabulary — same rule healthProbe.js
# itself uses server-side, kept consistent here since we're pushing the same kind of signal.
# Takes the JSON on stdin (not as an interpolated argument) -- embedding raw JSON straight into a
# python -c source string via bash variable substitution is fragile (any quote/backslash inside the
# JSON breaks it silently) and was the real cause of several blank results on this script's first
# real run, 2026-09-11.
classify_docker_state() {
  python3 -c "
import json, sys
s = json.load(sys.stdin)
if not s.get('Running'):
    print('down|container not running (' + s.get('Status','unknown') + ')')
else:
    h = s.get('Health', {}).get('Status')
    if not h or h == 'healthy':
        print('healthy|')
    elif h == 'starting':
        print('warning|container healthcheck starting')
    else:
        print('down|container healthcheck failing')
"
}

# Runs `docker inspect <container> --format '{{json .State}}'` either locally (no ssh_host given)
# or via an SSH alias, and registers one health-push result for the given slug.
push_container_health() {
  local slug="$1" container="$2" ssh_host="${3:-}"
  local state_json rc
  if [ -z "$ssh_host" ]; then
    state_json=$(docker inspect "$container" --format '{{json .State}}' 2>&1); rc=$?
  else
    state_json=$(ssh -o ConnectTimeout=8 -o BatchMode=yes "$ssh_host" "docker inspect '$container' --format '{{json .State}}'" 2>&1); rc=$?
  fi
  if [ $rc -ne 0 ]; then
    add_result "$slug" "down" "docker inspect failed: $state_json"
    log "  $slug ($container@${ssh_host:-local}): FAILED — $state_json"
    return
  fi
  local classified
  classified=$(printf '%s' "$state_json" | classify_docker_state)
  local status="${classified%%|*}" detail="${classified#*|}"
  add_result "$slug" "$status" "${detail:-container inspected via fleet-health-push}"
  log "  $slug ($container@${ssh_host:-local}): $status"
}

# Host-liveness check (for the 5 VM/VPS meta-rows hot-pn's own tunnel can't reach directly) — a
# real SSH command succeeding is a genuine "this host is up and admin-reachable" signal, same
# class of check reboot-recovery-watchdog.sh already relies on.
push_host_liveness() {
  local slug="$1" ssh_host="$2"
  if ssh -o ConnectTimeout=8 -o BatchMode=yes "$ssh_host" true 2>/tmp/fhp_ssh_err; then
    add_result "$slug" "healthy" "SSH reachable via fleet-health-push (Gateway)"
    log "  $slug (ssh $ssh_host): healthy"
  else
    add_result "$slug" "down" "SSH unreachable: $(cat /tmp/fhp_ssh_err 2>/dev/null)"
    log "  $slug (ssh $ssh_host): DOWN"
  fi
  rm -f /tmp/fhp_ssh_err
}

log "=== fleet-health-push START ==="

# ── VM/VPS meta-rows unreachable from hot-pn's own narrow wg3 scope ─────────────────────────────
# "gateway" itself needs no SSH at all -- this script already runs on the Gateway, so a real
# systemd/network sanity check stands in for "is this host up" rather than a meaningless
# ssh-to-itself round trip (which failed outright on the first run -- no local SSH trust to
# localhost is configured, and there's no reason to add one just for this).
if systemctl is-system-running --quiet 2>/dev/null || [ "$(systemctl is-system-running 2>/dev/null)" = "degraded" ]; then
  add_result "gateway" "healthy" "local host check via fleet-health-push (running on this host)"
  log "  gateway (local): healthy"
else
  add_result "gateway" "down" "systemctl is-system-running reported a non-degraded failure state"
  log "  gateway (local): DOWN"
fi
push_host_liveness "hot-bm-nl"  "hot-bm-nl"
push_host_liveness "hot-erp-nl" "hot-erp-nl"
push_host_liveness "sn-infra"   "sn-infra"
push_host_liveness "sn-web"     "sn-web"

# ── hot-bm-nl-nginx-nginx-1 (host-networking, no published port to check via TCP) ───────────────
push_container_health "hot-bm-nl-nginx-nginx-1" "nginx-nginx-1" "hot-bm-nl"

# ── Gateway's own internal-only containers (local docker inspect, no SSH needed) ────────────────
push_container_health "gateway-crowdsec"     "crowdsec"
push_container_health "gateway-dockge"       "dockge"
push_container_health "gateway-gatus"        "gatus"
push_container_health "gateway-keycloak-db"  "keycloak-db"
push_container_health "gateway-mailserver"   "mailserver"
push_container_health "gateway-oauth2-proxy" "oauth2-proxy"
push_container_health "gateway-powerdns-db"  "powerdns-db"
push_container_health "gateway-sms-relay"    "sms-relay"
push_container_health "gateway-tor"          "tor"
push_container_health "gateway-unbound"      "unbound"

# ── hot-erp-nl's internal-only containers ────────────────────────────────────────────────────────
push_container_health "hot-erp-nl-dickson-db"          "dickson-db"          "hot-erp-nl"
push_container_health "hot-erp-nl-dickson-redis-cache" "dickson-redis-cache" "hot-erp-nl"
push_container_health "hot-erp-nl-dickson-redis-queue" "dickson-redis-queue" "hot-erp-nl"
push_container_health "hot-erp-nl-dickson-scheduler"   "dickson-scheduler"   "hot-erp-nl"
push_container_health "hot-erp-nl-dickson-socketio"    "dickson-socketio"    "hot-erp-nl"
push_container_health "hot-erp-nl-dickson-worker"      "dickson-worker"      "hot-erp-nl"
push_container_health "hot-erp-nl-erp-prometheus"      "erp-prometheus"      "hot-erp-nl"
push_container_health "hot-erp-nl-node-exporter"       "node-exporter"       "hot-erp-nl"

# ── sn-infra's internal-only DB sidecars ─────────────────────────────────────────────────────────
push_container_health "sn-infra-forgejo-db"     "forgejo-db"     "sn-infra"
push_container_health "sn-infra-hot-wiki-db"    "hot-wiki-db"    "sn-infra"
push_container_health "sn-infra-namegen-db"     "namegen-db"     "sn-infra"
push_container_health "sn-infra-pdns-admin-db"  "pdns-admin-db"  "sn-infra"

# ── sn-monitor's internal-only DB sidecar ────────────────────────────────────────────────────────
push_container_health "sn-monitor-grafana-db" "grafana-db" "sn-monitor"

# ── sn-security's internal-only containers ───────────────────────────────────────────────────────
push_container_health "sn-security-forgejo-runner" "forgejo-runner" "sn-security"
push_container_health "sn-security-watchtower"     "watchtower"     "sn-security"

COUNT=$(python3 -c "import json; print(len(json.load(open('$RESULTS_FILE'))))")
log "Pushing $COUNT results to $PN_HEALTH_PUSH_URL"

RESP=$(curl -fsS -m 30 -X POST "$PN_HEALTH_PUSH_URL" \
  -H "Authorization: Bearer $PN_TOKEN" \
  -H "Content-Type: application/json" \
  --data "{\"results\": $(cat "$RESULTS_FILE")}" 2>&1)
RC=$?

rm -f "$RESULTS_FILE"

if [ $RC -eq 0 ]; then
  log "Push OK: $RESP"
else
  log "Push FAILED: $RESP"
  notify high "fleet-health-push FAILED" "POST to $PN_HEALTH_PUSH_URL failed: $RESP"
  exit 1
fi

log "=== fleet-health-push DONE ==="
