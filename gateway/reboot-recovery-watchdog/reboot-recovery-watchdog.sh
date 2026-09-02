#!/bin/bash
# House of Trae — auto-reboot recovery watchdog.
#
# Built after the 2026-08-05 hot-pn incident: an apt-daily-update auto-reboot left hot-pn's
# WireGuard/ICMP/TCP:22 all healthy while sshd never responded, and it took 27+ minutes of
# manual checking + a Hostkey hard-stop+power-on (same fix as the 2026-08-03 hot-bm-nl outage,
# CS-510977) before it recovered. This watches every auto-reboot host and, if one stays
# unreachable too long, escalates automatically the same way: soft reboot first, then a hard
# power-cycle if that doesn't clear it — always notifying what was done.
#
# Detection uses a real SSH command, not ping/TCP — those stayed healthy the whole time during
# the hot-pn incident and would not have caught it.
set -uo pipefail

# host -> recovery mechanism. "hostkey:<server_id>" uses the invapi (standalone VPS,
# hard_off/on). "proxmox:<vmid>" uses `qm` on hot-bm-nl (VM living on the shared host).
declare -A RECOVERY=(
  [hot-pn]="hostkey:4683"
  [hot-erp]="hostkey:41614"
  [sn-infra]="proxmox:100"
  [sn-web]="proxmox:102"
  [sn-monitor]="proxmox:104"
  [sn-security]="proxmox:106"
)
# hot-erp's ssh alias is hot-erp-nl, not hot-erp — map for the reachability check.
declare -A SSH_ALIAS=( [hot-erp]="hot-erp-nl" )

STATE_DIR=/var/lib/reboot-watchdog
LOG=/var/log/reboot-watchdog.log
NTFY_URL="https://ntfy.house-of-trae.com"
NTFY_TOPIC="hot-alerts"
NTFY_TOKEN_FILE="/etc/apt-daily-update/ntfy_token"
HOSTKEY_KEY_FILE="/opt/stacks/hostkey-api/secrets/hostkey_api_key.txt"

SOFT_THRESHOLD_SEC=$((10 * 60))   # first escalation: soft reboot
HARD_THRESHOLD_SEC=$((20 * 60))   # second escalation: hard stop + power-on
REPEAT_ALERT_SEC=$((15 * 60))     # after hard attempt, re-alert (no further auto action) this often

mkdir -p "$STATE_DIR"

notify() {
  local priority="$1" title="$2" message="$3"
  [ -f "$NTFY_TOKEN_FILE" ] || return 0
  curl -fsS -m 10 -u ":$(cat "$NTFY_TOKEN_FILE")" \
    -H "X-Title: $title" -H "X-Priority: $priority" \
    -d "$message" "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1 || true
}

log() { echo "$(date -Is) $*" >> "$LOG"; }

hostkey_token() {
  [ -f "$HOSTKEY_KEY_FILE" ] || return 1
  local key resp
  key="$(cat "$HOSTKEY_KEY_FILE")"
  resp="$(curl -fsS -m 15 "https://invapi.hostkey.com/auth.php" -d "action=login&key=$key" 2>/dev/null)" || return 1
  # Hostkey nests the token under a top-level "result" object:
  # {"result":{"token":"...", ...}} — not top-level. Verified 2026-08-06 after a real
  # 7.5h hot-pn outage went unrecovered because this parsed the wrong shape and silently
  # failed every auth call from day one.
  python3 -c "import json,sys; print(json.loads(sys.argv[1])['result']['token'])" "$resp" 2>/dev/null
}

hostkey_call() {
  local action="$1" id="$2" token="$3"
  curl -fsS -m 15 "https://invapi.hostkey.com/eq.php" -d "action=$action&token=$token&id=$id" 2>/dev/null
}

do_soft_reboot() {
  local host="$1" kind="$2" id="$3"
  case "$kind" in
    hostkey)
      local token
      token="$(hostkey_token)" || { log "$host: hostkey auth FAILED, cannot soft-reboot"; return 1; }
      hostkey_call reboot "$id" "$token" > /dev/null || { log "$host: eq/reboot call FAILED"; return 1; }
      log "$host: hostkey eq/reboot(id=$id) issued"
      ;;
    proxmox)
      ssh -o ConnectTimeout=10 -o BatchMode=yes hot-bm-nl "qm reboot $id" > /dev/null 2>&1 || { log "$host: qm reboot $id FAILED (ssh/qm error, or hot-bm-nl itself unreachable)"; return 1; }
      log "$host: qm reboot $id issued on hot-bm-nl"
      ;;
  esac
}

do_hard_cycle() {
  local host="$1" kind="$2" id="$3"
  case "$kind" in
    hostkey)
      local token
      token="$(hostkey_token)" || { log "$host: hostkey auth FAILED, cannot hard-cycle"; return 1; }
      hostkey_call hard_off "$id" "$token" > /dev/null || { log "$host: eq/hard_off call FAILED"; return 1; }
      sleep 15
      hostkey_call on "$id" "$token" > /dev/null || { log "$host: eq/on call FAILED"; return 1; }
      log "$host: hostkey eq/hard_off + eq/on (id=$id) issued"
      ;;
    proxmox)
      ssh -o ConnectTimeout=10 -o BatchMode=yes hot-bm-nl "qm stop $id --skiplock" > /dev/null 2>&1 || { log "$host: qm stop --skiplock $id FAILED (ssh/qm error, or hot-bm-nl itself unreachable)"; return 1; }
      sleep 5
      ssh -o ConnectTimeout=10 -o BatchMode=yes hot-bm-nl "qm start $id" > /dev/null 2>&1 || { log "$host: qm start $id FAILED after stop (ssh/qm error, or hot-bm-nl itself unreachable) — host may now be left stopped, needs manual qm start"; return 1; }
      log "$host: qm stop --skiplock $id + qm start $id issued on hot-bm-nl"
      ;;
  esac
}

now=$(date +%s)

for host in "${!RECOVERY[@]}"; do
  ssh_target="${SSH_ALIAS[$host]:-$host}"
  kind="${RECOVERY[$host]%%:*}"
  id="${RECOVERY[$host]##*:}"

  down_since_file="$STATE_DIR/$host.down_since"
  stage_file="$STATE_DIR/$host.stage"          # none -> soft -> hard
  last_repeat_file="$STATE_DIR/$host.last_repeat"

  if ssh -o ConnectTimeout=8 -o BatchMode=yes "$ssh_target" 'true' 2>/dev/null; then
    if [ -f "$down_since_file" ]; then
      down_since="$(cat "$down_since_file")"
      mins=$(( (now - down_since) / 60 ))
      stage="$(cat "$stage_file" 2>/dev/null || echo none)"
      notify default "Recovered: $host" "$host is reachable again after ~${mins}min down (last action taken: $stage)."
      log "$host: recovered after ~${mins}min, last stage was $stage"
    fi
    rm -f "$down_since_file" "$stage_file" "$last_repeat_file"
    continue
  fi

  # unreachable
  if [ ! -f "$down_since_file" ]; then
    echo "$now" > "$down_since_file"
    echo none > "$stage_file"
    log "$host: went unreachable"
  fi
  down_since="$(cat "$down_since_file")"
  elapsed=$(( now - down_since ))
  stage="$(cat "$stage_file" 2>/dev/null || echo none)"

  if [ "$stage" = "none" ] && [ "$elapsed" -ge "$SOFT_THRESHOLD_SEC" ]; then
    last_repeat="$(cat "$last_repeat_file" 2>/dev/null || echo 0)"
    if [ $(( now - last_repeat )) -ge "$REPEAT_ALERT_SEC" ]; then
      mins=$(( elapsed / 60 ))
      if do_soft_reboot "$host" "$kind" "$id"; then
        notify urgent "CRITICAL: $host down ${mins}min — soft-rebooting" \
          "$host unreachable for ${mins}+ min (network/ping can look fine while this happens). Issued a soft reboot automatically."
        echo soft > "$stage_file"
      else
        notify urgent "CRITICAL: $host down ${mins}min — soft reboot FAILED, will retry" \
          "$host unreachable for ${mins}+ min. Automatic soft-reboot attempt failed (see /var/log/reboot-watchdog.log on the Gateway) — will retry."
      fi
      echo "$now" > "$last_repeat_file"
    fi

  elif [ "$stage" = "soft" ] && [ "$elapsed" -ge "$HARD_THRESHOLD_SEC" ]; then
    last_repeat="$(cat "$last_repeat_file" 2>/dev/null || echo 0)"
    if [ $(( now - last_repeat )) -ge "$REPEAT_ALERT_SEC" ]; then
      mins=$(( elapsed / 60 ))
      if do_hard_cycle "$host" "$kind" "$id"; then
        notify urgent "CRITICAL: $host still down ${mins}min — hard power-cycling" \
          "$host still unreachable ${mins}+ min after a soft reboot. Escalated to a hard stop + power-on (same fix as the 2026-08-03 hot-bm-nl outage)."
        echo hard > "$stage_file"
      else
        notify urgent "CRITICAL: $host still down ${mins}min — hard power-cycle FAILED, will retry" \
          "$host still unreachable ${mins}+ min after a soft reboot. Automatic hard power-cycle attempt failed (see /var/log/reboot-watchdog.log on the Gateway) — will retry."
      fi
      echo "$now" > "$last_repeat_file"
    fi

  elif [ "$stage" = "hard" ]; then
    last_repeat="$(cat "$last_repeat_file" 2>/dev/null || echo "$down_since")"
    if [ $(( now - last_repeat )) -ge "$REPEAT_ALERT_SEC" ]; then
      mins=$(( elapsed / 60 ))
      notify urgent "CRITICAL: $host still down ${mins}min after hard power-cycle" \
        "$host has not recovered even after an automatic hard stop + power-on. This needs the Hostkey KVM console — no further automatic action will be taken."
      echo "$now" > "$last_repeat_file"
      log "$host: still down ${mins}min after hard cycle, re-alerted"
    fi
  fi
done
