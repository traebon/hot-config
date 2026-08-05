#!/bin/bash
# House of Trae — daily apt update && upgrade
# Reboot behavior is per-host: /etc/apt-daily-update/auto_reboot contains
# "true" (auto-reboot ~2min after a required update) or "false" (notify only).
# Gateway VPS and hot-bm-nl are always "false" — see CLAUDE.md Operational Rules.
set -uo pipefail

HOST_TAG="$(hostname)"
LOG=/var/log/apt-daily-update.log
NTFY_URL="https://ntfy.house-of-trae.com"
NTFY_TOPIC="hot-alerts"
NTFY_TOKEN_FILE="/etc/apt-daily-update/ntfy_token"
AUTO_REBOOT_FILE="/etc/apt-daily-update/auto_reboot"

notify() {
  local priority="$1" title="$2" message="$3"
  [ -f "$NTFY_TOKEN_FILE" ] || return 0
  curl -fsS -m 10 -u ":$(cat "$NTFY_TOKEN_FILE")" \
    -H "X-Title: $title" -H "X-Priority: $priority" \
    -d "$message" "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1 || true
}

{
  echo "=== $(date -Is) apt-daily-update starting on $HOST_TAG ==="
  export DEBIAN_FRONTEND=noninteractive

  if ! apt-get update; then
    echo "apt-get update FAILED"
    notify high "apt update FAILED on $HOST_TAG" "apt-get update failed - see $LOG"
    exit 1
  fi

  if ! apt-get -y upgrade; then
    echo "apt-get upgrade FAILED"
    notify high "apt upgrade FAILED on $HOST_TAG" "apt-get upgrade failed - see $LOG"
    exit 1
  fi

  apt-get -y autoremove --purge
  apt-get clean

  if [ -f /var/run/reboot-required ]; then
    pkgs="$(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null || true)"
    echo "Reboot required. Packages: ${pkgs:-unknown}"
    if [ -f "$AUTO_REBOOT_FILE" ] && [ "$(cat "$AUTO_REBOOT_FILE")" = "true" ]; then
      echo "auto_reboot=true — scheduling reboot in 2 minutes"
      notify default "Rebooting $HOST_TAG for pending updates" "Packages needing reboot: ${pkgs:-unknown} — auto-reboot in 2 min."
      shutdown -r +2 "House of Trae automated patching reboot"
    else
      notify default "Reboot required on $HOST_TAG" "Packages needing reboot: ${pkgs:-unknown} — reboot manually when convenient (auto-reboot disabled on this host)."
    fi
  fi

  echo "=== $(date -Is) apt-daily-update finished on $HOST_TAG ==="
} >> "$LOG" 2>&1
