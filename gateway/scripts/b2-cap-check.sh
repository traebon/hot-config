#!/bin/bash
# House of Trae — one-shot check that last night's B2 pushes succeeded now that the B2 account
# cap was raised 2026-08-08. hot-pn-privatenexus-db.sh (03:30) is the reliable nightly B2 canary
# — it always attempts B2 unconditionally. keycloak (01:30) and gateway-vps (05:30) only touch B2
# as a fallback when hot-bm-nl is unreachable that night, so seeing no B2 activity from those two
# is normal, not a problem — this script only flags them if an actual B2 error shows up in
# whatever they did log. Scheduled via `systemd-run --on-calendar`, not CronCreate — see
# feedback_durable_scheduling memory. Reports via Ntfy since there's no chat session to report
# back into.
set -uo pipefail

NTFY_URL="https://ntfy.house-of-trae.com"
NTFY_TOPIC="hot-alerts"
NTFY_TOKEN_FILE="/etc/apt-daily-update/ntfy_token"

notify() {
  local priority="$1" title="$2" message="$3"
  [ -f "$NTFY_TOKEN_FILE" ] || return 0
  curl -fsS -m 10 -u ":$(cat "$NTFY_TOKEN_FILE")" \
    -H "X-Title: $title" -H "X-Priority: $priority" \
    -d "$message" "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1 || true
}

today="$(date +%Y-%m-%d)"
issues=()
ok=()

check_log() {
  local name="$1" logfile="$2"
  [ -f "$logfile" ] || { issues+=("$name: log file $logfile not found"); return; }
  local todays
  todays="$(awk -v d="$today" '$0 ~ "\\[" d' "$logfile")"
  if [ -z "$todays" ]; then
    issues+=("$name: no log entries found for today ($today) in $logfile — job may not have run")
    return
  fi
  if echo "$todays" | grep -qi "storage_cap_exceeded\|Failed to copy.*b2\|b2.*ERROR"; then
    issues+=("$name: still hitting a B2 error tonight — check $logfile")
  else
    ok+=("$name")
  fi
}

check_log "keycloak" "/var/log/hot-keycloak-backup.log"
check_log "gateway-vps" "/var/log/hot-gateway-vps-backup.log"
check_log "hot-pn-privatenexus-db" "/var/log/hot-pn-db-backup.log"

# Direct confirmation: a real small write to b2-hot-crypt, cleaned up immediately after.
b2_live_status="unknown"
if command -v rclone &>/dev/null; then
  tmp="$(mktemp)"
  echo "b2-cap-check $(date -Is)" > "$tmp"
  if rclone copy "$tmp" "b2-hot-crypt:cap-check/" --no-traverse 2>&1 | grep -qi "storage_cap_exceeded"; then
    b2_live_status="still capped"
    issues+=("live test push to b2-hot-crypt:cap-check/ still returns storage_cap_exceeded")
  else
    b2_live_status="writable"
    rclone delete "b2-hot-crypt:cap-check/" 2>/dev/null || true
  fi
  rm -f "$tmp"
fi

if [ "${#issues[@]}" -eq 0 ]; then
  notify default "B2 cap check: all clear" \
    "Live test push to B2 succeeded (cap is working). Last night's B2 pushes all clean: $(IFS=,; echo "${ok[*]}")."
else
  notify high "B2 cap check: ${#issues[@]} issue(s) found" \
    "Live B2 status: ${b2_live_status}.
$(printf '%s\n' "${issues[@]}")"
fi
