#!/bin/bash
# House of Trae — hot-bm-nl (Proxmox host) daily apt CHECK ONLY.
# Never applies upgrades automatically — this host runs all 4 production VMs,
# so package upgrades here need a human look first. Run `apt-approve-upgrade`
# to actually apply after reviewing.
set -uo pipefail

HOST_TAG="$(hostname)"
LOG=/var/log/apt-daily-check.log
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

{
  echo "=== $(date -Is) apt-daily-check starting on $HOST_TAG ==="
  export DEBIAN_FRONTEND=noninteractive

  if ! apt-get update; then
    echo "apt-get update FAILED"
    notify high "apt update check FAILED on $HOST_TAG" "apt-get update failed - see $LOG"
    exit 1
  fi

  upgradable="$(apt list --upgradable 2>/dev/null | grep -v '^Listing' || true)"
  count=0
  [ -n "$upgradable" ] && count="$(echo "$upgradable" | grep -c .)"

  if [ "$count" -gt 0 ]; then
    echo "$upgradable"
    summary="$(echo "$upgradable" | cut -d/ -f1 | tr '\n' ' ')"
    notify default "hot-bm-nl: $count package(s) upgradable — approval needed" \
      "Run 'apt-approve-upgrade' on hot-bm-nl to review+apply. Packages: $summary"
  else
    echo "No upgrades available."
  fi

  echo "=== $(date -Is) apt-daily-check finished on $HOST_TAG ==="
} >> "$LOG" 2>&1
