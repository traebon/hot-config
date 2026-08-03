#!/bin/bash
# Checks whether sn-infra (and by extension hot-bm-nl) has recovered from the 2026-08-03 outage
# (Hostkey ticket CS-510977). Fires a one-time email when it transitions from down to up, since
# Ntfy/SMS both depend on that same fleet and can't be trusted to report on its own recovery.
set -euo pipefail

STATE_DIR="/var/lib/sn-infra-recovery-check"
STATE_FILE="${STATE_DIR}/state"
mkdir -p "$STATE_DIR"

SMTP_PASS_FILE="/opt/stacks/vaultwarden/secrets/smtp_password.txt"
ALERT_TO="tristian@securenexus.net"

is_up() {
  # Primary signal: wg4 handshake to hot-bm-nl must be fresh (< 120s, keepalive is 25s)
  local handshake now age
  handshake=$(wg show wg4 latest-handshakes 2>/dev/null | awk '{print $2}')
  [ -z "$handshake" ] && return 1
  [ "$handshake" = "0" ] && return 1
  now=$(date +%s)
  age=$((now - handshake))
  [ "$age" -gt 120 ] && return 1

  # Confirming signal: sn-infra itself must actually answer, not just the tunnel to hot-bm-nl
  timeout 5 ssh -o ConnectTimeout=3 -o BatchMode=yes sn-infra "true" 2>/dev/null || return 1
  return 0
}

send_recovery_email() {
  local pass
  pass=$(cat "$SMTP_PASS_FILE")
  {
    echo "From: notifications@house-of-trae.com"
    echo "To: ${ALERT_TO}"
    echo "Subject: sn-infra is back up - SMS relay migration unblocked"
    echo ""
    echo "sn-infra (and hot-bm-nl) responded successfully as of $(date -u '+%Y-%m-%d %H:%M:%S UTC')."
    echo ""
    echo "This was checked via a fresh wg4 handshake plus a real SSH connection to sn-infra,"
    echo "not just a ping."
    echo ""
    echo "The SMS relay migration scoped on 2026-08-03 was blocked entirely on sn-infra being"
    echo "unreachable - its source code and Twilio credentials only exist there. That blocker"
    echo "is now cleared. See the sms_relay_migration_scope_2026_08_03 memory for the full scope"
    echo "and next steps."
    echo ""
    echo "This is a one-time notification - this watchdog will not email again unless sn-infra"
    echo "goes down and recovers again."
  } | curl -sS --url 'smtp://mail.house-of-trae.com:587' \
    --ssl-reqd \
    --mail-from 'notifications@house-of-trae.com' \
    --mail-rcpt "${ALERT_TO}" \
    --user "notifications@house-of-trae.com:${pass}" \
    --upload-file - >/dev/null 2>&1
}

prev_state="down"
[ -f "$STATE_FILE" ] && prev_state=$(cat "$STATE_FILE")

if is_up; then
  if [ "$prev_state" = "down" ]; then
    send_recovery_email
  fi
  echo "up" > "$STATE_FILE"
else
  echo "down" > "$STATE_FILE"
fi
