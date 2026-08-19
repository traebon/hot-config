#!/bin/bash
# House of Trae — one-shot health check of reboot-recovery-watchdog.timer, scheduled via
# `systemd-run --on-calendar` as a fail-safe that runs independent of any Claude Code session.
# Reports a summary via Ntfy since there's no chat session to report back into. Only looks at
# the last 24h of activity (see below) so it stays meaningful on repeat runs, not just the first.
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

issues=()

# 1. Timer actually active and firing
if ! systemctl is-active --quiet reboot-recovery-watchdog.timer; then
  issues+=("timer is NOT active")
fi

last_trigger="$(systemctl show reboot-recovery-watchdog.timer -p LastTriggerUSec --value 2>/dev/null)"
if [ -z "$last_trigger" ] || [ "$last_trigger" = "n/a" ]; then
  issues+=("timer has no recorded last-trigger time")
else
  last_epoch="$(date -d "$last_trigger" +%s 2>/dev/null || echo 0)"
  now_epoch="$(date +%s)"
  age_min=$(( (now_epoch - last_epoch) / 60 ))
  if [ "$age_min" -gt 10 ]; then
    issues+=("last run was ${age_min}min ago (expected ~5min cadence)")
  fi
fi

# 2. Any failed runs recorded in roughly the check window (journalctl --since scopes this;
# without --since, old already-known failures from before this host existed would re-flag forever)
fail_count="$(journalctl -u reboot-recovery-watchdog.service --since '24 hours ago' --no-pager 2>/dev/null | grep -c "status=1\|Failed with result" || true)"
if [ "${fail_count:-0}" -gt 0 ]; then
  issues+=("${fail_count} failed run(s) in the journal in the last 24h")
fi

# 3. Log file activity in the last 24h only — the log is a permanent append-only history, so
# counting all lines ever written would flag every future run forever once anything has happened
# even once. Only new activity since the last check window is actually worth surfacing.
if [ -f /var/log/reboot-watchdog.log ]; then
  cutoff="$(date -d '24 hours ago' -Is)"
  recent_lines="$(awk -v cutoff="$cutoff" '$1 >= cutoff' /var/log/reboot-watchdog.log 2>/dev/null | wc -l)"
  if [ "${recent_lines:-0}" -gt 0 ]; then
    issues+=("${recent_lines} watchdog log line(s) in the last 24h — see /var/log/reboot-watchdog.log for detail")
  fi
fi

# 4. Stale state files for hosts that are actually reachable now
for f in /var/lib/reboot-watchdog/*.down_since /var/lib/reboot-watchdog/*.stage; do
  [ -e "$f" ] || continue
  host="$(basename "$f" | cut -d. -f1)"
  issues+=("stale state file for $host: $(basename "$f") — check whether $host is actually reachable")
done

run_count="$(journalctl -u reboot-recovery-watchdog.service --since '24 hours ago' --no-pager 2>/dev/null | grep -c "Finished reboot-recovery-watchdog" || true)"

if [ "${#issues[@]}" -eq 0 ]; then
  notify default "Watchdog health check: clean" \
    "reboot-recovery-watchdog ran ${run_count} times in the last 24h with zero issues — no down events, no failed runs, no stale state. Timer is healthy."
else
  notify high "Watchdog health check: ${#issues[@]} issue(s) found" \
    "$(printf '%s\n' "${issues[@]}")"
fi
