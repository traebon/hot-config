#!/bin/bash
# House of Trae — nightly fleet health sweep (Option A + C of
# docs/HoT_Automation_Self_Healing_Scope.md, first automation slice, 2026-08-19).
#
# Institutionalizes what used to be an irregular manual "fleet health check" session
# (see fleet_health_checks memory — 2026-07-30, then not again until 2026-08-16, over
# two weeks apart, which is roughly how long several real incidents sat undetected).
#
# Point checks (systemctl --failed, dpkg --audit, wazuh agent liveness, hot-pn's
# catalogue-binding-drift — added 2026-08-20, see below) persist a per-host/per-check
# streak and escalate Ntfy priority after ESCALATE_AFTER consecutive failing nights —
# directly answers the "alert fired at too low a severity and nobody looked" failure
# class (the grub-pc incident: 4 identical unescalated priority=high alerts, ignored).
# Drift checks (/opt/stacks inventory, ufw rules) are one-shot snapshot diffs — a config
# change is a single event, not an ongoing condition, so no streak/escalation applies;
# the snapshot is updated after reporting so tomorrow's diff is against today, not stuck
# repeating the same change forever.
#
# Deliberately a plain systemd timer on the Gateway, not a cloud-scheduled routine —
# a cloud sandbox has no path to wg4/SSH/Tailscale, same constraint already documented
# for sn-infra-recovery-check.timer.
set -uo pipefail

NTFY_URL="https://ntfy.house-of-trae.com"
NTFY_TOPIC="hot-alerts"
NTFY_TOKEN_FILE="/etc/apt-daily-update/ntfy_token"
STATE_DIR="/var/lib/fleet-health-sweep"
LOG=/var/log/fleet-health-sweep.log
ESCALATE_AFTER=3   # consecutive failing nights before priority=high -> urgent (SMS)

mkdir -p "$STATE_DIR"

notify() {
  local priority="$1" title="$2" message="$3"
  [ -f "$NTFY_TOKEN_FILE" ] || return 0
  curl -fsS -m 10 -u ":$(cat "$NTFY_TOKEN_FILE")" \
    -H "X-Title: $title" -H "X-Priority: $priority" \
    -d "$message" "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1 || true
}

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
# hosts that run app stacks under /opt/stacks (hot-bm-nl is the bare hypervisor, no stacks itself)
STACK_HOSTS="gateway sn-infra sn-web sn-monitor sn-security hot-pn hot-erp-nl"

run_remote() {
  local alias="$1" cmd="$2"
  if [ -z "$alias" ]; then
    bash -c "$cmd" 2>&1
  else
    ssh -o ConnectTimeout=8 -o BatchMode=yes "$alias" "$cmd" 2>&1
  fi
}

# report_check: point checks with streak-based escalation.
# args: host check status(ok|fail) detail
report_check() {
  local host="$1" check="$2" status="$3" detail="$4"
  local streakfile="$STATE_DIR/${host}__${check}.streak"
  local streak
  streak="$(cat "$streakfile" 2>/dev/null || echo 0)"

  if [ "$status" = "ok" ]; then
    if [ "$streak" -gt 0 ]; then
      notify high "RECOVERED: $host $check" "Was failing $streak consecutive night(s), now healthy."
      echo "$(date -Is) RECOVERED $host/$check after $streak night(s)" >> "$LOG"
    fi
    echo 0 > "$streakfile"
    return
  fi

  streak=$((streak + 1))
  echo "$streak" > "$streakfile"
  echo "$(date -Is) FAIL $host/$check (streak=$streak): $detail" >> "$LOG"
  if [ "$streak" -ge "$ESCALATE_AFTER" ]; then
    notify urgent "PERSISTENT ($streak nights): $host $check" "$detail"
  else
    notify high "$host $check FAILED" "$detail"
  fi
}

# report_drift: one-shot snapshot diff, no streak — updates the snapshot after reporting.
# args: host check current_content
report_drift() {
  local host="$1" check="$2" current="$3"
  local snapfile="$STATE_DIR/${host}__${check}.snapshot"

  if [ ! -f "$snapfile" ]; then
    echo "$current" > "$snapfile"
    echo "$(date -Is) BASELINE $host/$check captured (first run, not diffed)" >> "$LOG"
    return
  fi

  local prev diff_out
  prev="$(cat "$snapfile")"
  if [ "$current" = "$prev" ]; then
    return
  fi

  diff_out="$(diff <(echo "$prev") <(echo "$current") || true)"
  echo "$(date -Is) DRIFT $host/$check:" >> "$LOG"
  echo "$diff_out" >> "$LOG"
  notify default "Config drift: $host $check" "$diff_out"
  echo "$current" > "$snapfile"
}

for name in gateway hot-bm-nl sn-infra sn-web sn-monitor sn-security hot-pn hot-erp-nl; do
  alias="${HOSTS[$name]}"

  # Reachability is reboot-recovery-watchdog's job, not this sweep's — if a host doesn't
  # answer, skip its checks and note it plainly (no escalation of our own, avoid duplicate
  # alerting for a condition another system already owns).
  if [ -n "$alias" ] && ! ssh -o ConnectTimeout=8 -o BatchMode=yes "$alias" "true" 2>/dev/null; then
    echo "$(date -Is) UNREACHABLE $name — skipping checks" >> "$LOG"
    notify default "Fleet sweep: $name unreachable" "Skipped this host's checks — reboot-recovery-watchdog owns liveness/recovery, not this sweep."
    continue
  fi

  # --- systemd failed units ---
  failed="$(run_remote "$alias" "systemctl --failed --no-legend 2>/dev/null")"
  if [ -z "$failed" ]; then
    report_check "$name" "systemd-failed" ok ""
  else
    report_check "$name" "systemd-failed" fail "$failed"
  fi

  # --- dpkg broken packages ---
  audit="$(run_remote "$alias" "dpkg --audit 2>/dev/null")"
  if [ -z "$audit" ]; then
    report_check "$name" "dpkg-audit" ok ""
  else
    report_check "$name" "dpkg-audit" fail "$audit"
  fi

  # --- wazuh agent liveness (process-vs-systemd-state, the sn-infra bug class) ---
  wazuh_check="$(run_remote "$alias" '
    if [ -x /var/ossec/bin/wazuh-control ]; then
      /var/ossec/bin/wazuh-control status 2>/dev/null | grep -i "is not running" || true
    fi
  ')"
  if [ -n "$wazuh_check" ]; then
    report_check "$name" "wazuh-agent" fail "$wazuh_check"
  elif run_remote "$alias" "[ -x /var/ossec/bin/wazuh-control ] && echo present" | grep -q present; then
    report_check "$name" "wazuh-agent" ok ""
  fi
  # (hosts without wazuh-agent installed at all are silently skipped for this check)

  # --- /opt/stacks inventory drift (undocumented deployments) ---
  if [[ " $STACK_HOSTS " == *" $name "* ]]; then
    stacks="$(run_remote "$alias" "ls -1 /opt/stacks/ 2>/dev/null | sort")"
    report_drift "$name" "stacks-inventory" "$stacks"
  fi

  # --- ufw rule drift (config drift, e.g. the hot-pn SSH-open-to-Anywhere case) ---
  ufw="$(run_remote "$alias" "ufw status verbose 2>/dev/null")"
  [ -n "$ufw" ] && report_drift "$name" "ufw-rules" "$ufw"

  # --- catalogue-deployed stack drift: live port binding vs. governance-approved binding
  # (hot-pn only -- the only host running PN's Catalogue deploy flow). Scoped in
  # docs/HoT_Automation_Self_Healing_Scope.md Section 8 (2026-08-20), after hot-pn's
  # `nextcloud` container was found silently rebound 2026-08-11 outside the
  # propose->review->approve governance flow entirely, undetected for 9 days -- see
  # pn_nextcloud_binding_and_personal_cleanup_2026_08_20 memory. Deliberately a
  # streak-based report_check, NOT a one-shot report_drift like stacks-inventory/ufw-rules
  # above: those two correctly auto-accept a new state as the next baseline, but doing
  # that here would silently bless an undocumented governance-bypass forever -- exactly
  # the failure this check exists to catch. Uses
  # /usr/local/bin/catalogue-drift-check.py (deployed on hot-pn, tracked in
  # hot-config/hot-pn/catalogue-drift-check/) to compare live docker inspect bindings
  # against the latest approved action_requests row per slug, filtered against this
  # repo's catalogue-drift-exceptions.conf (only entries Mr. Byrne has explicitly
  # decided to formalize, e.g. the nextcloud case above -- not a general silence list).
  if [ "$name" = "hot-pn" ]; then
    exceptions_file="/opt/hot-config/gateway/fleet-health-sweep/catalogue-drift-exceptions.conf"
    drift_raw="$(run_remote "$alias" "python3 /usr/local/bin/catalogue-drift-check.py")"
    drift_unresolved=""
    while IFS= read -r dline; do
      [ -z "$dline" ] && continue
      key="$(echo "$dline" | awk -F'|' '{print $1":"$2":"$4}')"
      if [ -f "$exceptions_file" ] && grep -vE '^\s*(#|$)' "$exceptions_file" | grep -qxF "$key"; then
        continue
      fi
      drift_unresolved="${drift_unresolved}${dline}"$'\n'
    done <<< "$drift_raw"
    if [ -z "$drift_unresolved" ]; then
      report_check "$name" "catalogue-binding-drift" ok ""
    else
      report_check "$name" "catalogue-binding-drift" fail "$drift_unresolved"
    fi
  fi

done

echo "$(date -Is) sweep complete" >> "$LOG"
