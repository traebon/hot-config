#!/bin/bash
# House of Trae — fail-safe health check for fleet-judgment-review.timer (Option D1).
# Built in from day one, not retrofitted after a gap — this project found the same
# "fail-safe for a fail-safe" lesson twice already on 2026-08-19
# (reboot-watchdog-healthcheck.sh had been silently gone for the same 6-day window as
# the bug it exists to catch, for a completely unrelated reason). Same pattern here:
# checks the timer's own liveness AND that a report has actually landed recently,
# since a weekly LLM-driven job failing silently is exactly the kind of gap this whole
# automation initiative was scoped to close, not repeat.
set -uo pipefail

NTFY_URL="https://ntfy.house-of-trae.com"
NTFY_TOPIC="hot-alerts"
NTFY_TOKEN_FILE="/etc/apt-daily-update/ntfy_token"
STATE_DIR="/var/lib/fleet-judgment-review"
# Weekly cadence + generous slack for a missed/delayed run before flagging.
MAX_AGE_DAYS=9

notify() {
  local priority="$1" title="$2" message="$3"
  [ -f "$NTFY_TOKEN_FILE" ] || return 0
  curl -fsS -m 10 -u ":$(cat "$NTFY_TOKEN_FILE")" \
    -H "X-Title: $title" -H "X-Priority: $priority" \
    -d "$message" "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1 || true
}

issues=()

if ! systemctl is-active --quiet fleet-judgment-review.timer; then
  issues+=("fleet-judgment-review.timer is NOT active")
fi

last_trigger="$(systemctl show fleet-judgment-review.timer -p LastTriggerUSec --value 2>/dev/null)"
next_elapse="$(systemctl show fleet-judgment-review.timer -p NextElapseUSecRealtime --value 2>/dev/null)"
if [ -z "$next_elapse" ] || [ "$next_elapse" = "n/a" ]; then
  issues+=("timer has no computed next-fire time (the exact wedge-bug signature — see claude-md/operational-rules.md)")
fi

if [ ! -f "$STATE_DIR/last-success" ]; then
  issues+=("no last-success file at all — the review script may never have completed successfully")
else
  last_epoch="$(date -d "$(cat "$STATE_DIR/last-success")" +%s 2>/dev/null || echo 0)"
  now_epoch="$(date +%s)"
  age_days=$(( (now_epoch - last_epoch) / 86400 ))
  if [ "$age_days" -gt "$MAX_AGE_DAYS" ]; then
    issues+=("last successful report was ${age_days} day(s) ago (expected weekly, ${MAX_AGE_DAYS}d threshold)")
  fi
fi

if [ "${#issues[@]}" -eq 0 ]; then
  notify default "fleet-judgment-review health check: clean" \
    "Timer active, last trigger $last_trigger, last successful report within ${MAX_AGE_DAYS}d threshold."
else
  notify high "fleet-judgment-review health check: ${#issues[@]} issue(s)" \
    "$(printf '%s\n' "${issues[@]}")"
fi
