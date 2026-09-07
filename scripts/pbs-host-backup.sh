#!/bin/bash
# PBS host-level rebuild backup — daily encrypted proxmox-backup-client push of this host's real
# persistent state (config + Docker named volumes) to PBS (Mr. Byrne's own local hardware, over
# wg6/Tailscale — never leaves HoT-controlled storage). Built 2026-09-07 at Mr. Byrne's direct
# request: PBS should be a continuously-updated, fully-encrypted local copy of everything needed
# to rebuild HoT, not just the 3 Proxmox VMs it already covered.
#
# Deployed identically on Gateway, hot-pn, hot-erp-nl (the 3 fleet hosts that are standalone VPS's,
# not Proxmox VMs, so vzdump/pbs-hot can't reach them at all). Backs up /opt (stacks, secrets,
# hot-config) + /root (SSH keys, WireGuard client configs where present) + /var/lib/docker/volumes
# (named-volume data that isn't bind-mounted under /opt — confirmed present and non-trivial on all
# 3 hosts before this was written, not assumed empty). Deliberately NOT a whole-OS backup — matches
# the project's established "rebuild recipe" philosophy (docs/HoT_PBS_Backup_Integration_Scope.md
# Section 9): OS/packages are reprovisionable, real state and secrets are not.
#
# Encryption: proxmox-backup-client's own client-side AEAD encryption (AES-256-GCM under a
# scrypt-derived key), keyfile+passphrase at /etc/pbs-fleet-backup/ (chmod 600, root-only) on every
# host running this script. Master key + passphrase are saved in Vaultwarden — losing both means
# every backup this script ever wrote becomes permanently unrecoverable, PBS's chunk store has no
# other way to decrypt them.
set -uo pipefail

HOSTNAME_ID="${PBS_BACKUP_HOSTNAME:-$(hostname)}"
NTFY_URL="https://ntfy.house-of-trae.com"
NTFY_TOPIC="hot-alerts"
NTFY_TOKEN_FILE="/etc/apt-daily-update/ntfy_token"
KEY_DIR="/etc/pbs-fleet-backup"
LOG="/var/log/pbs-host-backup.log"

notify() {
  local priority="$1" title="$2" message="$3"
  [ -f "$NTFY_TOKEN_FILE" ] || return 0
  curl -fsS -m 10 -u ":$(cat "$NTFY_TOKEN_FILE")" \
    -H "X-Title: $title" -H "X-Priority: $priority" \
    -d "$message" "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1 || true
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

if [ ! -f "$KEY_DIR/pbs-token" ] || [ ! -f "$KEY_DIR/fleet-hosts.key" ] || [ ! -f "$KEY_DIR/passphrase" ]; then
  log "FATAL: missing key material in $KEY_DIR"
  notify 4 "PBS host backup FAILED ($HOSTNAME_ID)" "Missing key/token files in $KEY_DIR — backup did not run."
  exit 1
fi

AUTH_ID="$(cut -d: -f1 "$KEY_DIR/pbs-token")"
TOKEN_SECRET="$(cut -d: -f2 "$KEY_DIR/pbs-token")"
export PBS_PASSWORD="$TOKEN_SECRET"
export PBS_ENCRYPTION_PASSWORD="$(cat "$KEY_DIR/passphrase")"
export PBS_FINGERPRINT="40:b8:6a:a3:bd:91:b0:99:92:08:c4:08:a4:da:b2:60:4e:3e:6a:be:4d:29:bf:94:30:6a:c1:ed:6b:6a:69:9c"

REPOSITORY="${AUTH_ID}@${PBS_REPO_HOST}:houseoftrae-backups"

BACKUP_SPEC=(opt.pxar:/opt root.pxar:/root)
[ -d /var/lib/docker/volumes ] && BACKUP_SPEC+=(docker-volumes.pxar:/var/lib/docker/volumes)
[ -d /etc/wireguard ] && [ -n "$(ls -A /etc/wireguard 2>/dev/null)" ] && BACKUP_SPEC+=(wireguard.pxar:/etc/wireguard)

log "Starting backup for $HOSTNAME_ID -> $REPOSITORY (type host, id $HOSTNAME_ID)"

OUTPUT=$(proxmox-backup-client backup "${BACKUP_SPEC[@]}" \
  --repository "$REPOSITORY" \
  --backup-id "$HOSTNAME_ID" \
  --crypt-mode encrypt \
  --keyfile "$KEY_DIR/fleet-hosts.key" \
  --skip-lost-and-found 2>&1)
RC=$?

echo "$OUTPUT" >> "$LOG"

if [ $RC -eq 0 ]; then
  log "Backup OK for $HOSTNAME_ID"
  PRUNE_OUTPUT=$(proxmox-backup-client prune "host/$HOSTNAME_ID" \
    --repository "$REPOSITORY" --keep-daily 7 --keep-weekly 4 2>&1)
  echo "$PRUNE_OUTPUT" >> "$LOG"
  notify 2 "PBS host backup OK ($HOSTNAME_ID)" "Daily encrypted rebuild backup completed."
else
  log "Backup FAILED for $HOSTNAME_ID (exit $RC)"
  notify 4 "PBS host backup FAILED ($HOSTNAME_ID)" "proxmox-backup-client exited $RC. See $LOG."
fi

exit $RC
