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

# ── Register a completed backup into PN's own service_backups table ─────────────────────────────
# Same gap, same fix as fleet-state-backup.sh/backup-gateway-vps.sh/backup-keycloak.sh (2026-09-10/
# 11): this backup has always genuinely run on all 3 hosts, but nothing ever told PN -- the
# gateway/hot-pn/hot-erp-nl VPS-meta rows all showed backup_policy=daily next to zero rows in
# service_backups. Deployed identically to all 3 hosts, so the service_id is resolved from
# $HOSTNAME_ID at runtime rather than hardcoded once. Direct psql INSERT via SSH to hot-pn (where
# the DB lives) -- same pattern pg_dump.sh already used, since this runs unattended with no
# session to hold.
case "$HOSTNAME_ID" in
  gateway)    PN_SERVICE_ID="8ad79707-00e1-4bbd-90ea-ed33b1d49f93" ;;
  hot-pn)     PN_SERVICE_ID="0fb41b5c-e449-46fa-b01d-4ead2047a46c" ;;
  hot-erp-nl) PN_SERVICE_ID="c8ad967a-b566-462e-936f-6d8df5c71aeb" ;;
  *)          PN_SERVICE_ID="" ;;
esac

register_backup() {
  local service_id="$1" label="$2" location="$3" size_bytes="$4"
  [ -z "$service_id" ] && return 0
  local esc_label esc_location
  esc_label="$(printf '%s' "$label" | sed "s/'/''/g")"
  esc_location="$(printf '%s' "$location" | sed "s/'/''/g")"
  local sql="INSERT INTO service_backups (tenant_id, service_id, label, backup_type, trust_state, location, size_bytes, notes) VALUES ('10000000-0000-0000-0000-000000000001', '${service_id}', '${esc_label}', 'full', 'trusted', '${esc_location}', ${size_bytes:-NULL}, 'Registered by pbs-host-backup.sh -- same pattern pg_dump.sh uses for privatenexus-db.');"
  local psql_cmd="docker exec -i privatenexus-db psql -U privatenexus -d privatenexus -v ON_ERROR_STOP=1 -c \"$sql\""
  # This script deploys identically to Gateway/hot-pn/hot-erp-nl, but only Gateway (which has
  # fleet-wide SSH reach by design) and hot-pn (local -- the DB is right there) can actually reach
  # privatenexus-db. hot-erp-nl has no SSH trust relationship to hot-pn at all (confirmed live,
  # 2026-09-11: no alias, and a raw hostname attempt fails host key verification outright) -- that's
  # a real cross-host trust boundary, not something to route around for a cosmetic registration.
  # Skip cleanly there rather than let it silently host-key-fail every night; hot-erp-nl's PBS
  # backup registration is a known open gap, follow-up would be a Gateway-side check (same shape as
  # fleet-discovery-push.sh, which solved the identical "only Gateway can reach everywhere" problem
  # for Discovery) rather than teaching hot-erp-nl to reach hot-pn directly.
  if [ "$HOSTNAME_ID" != "hot-pn" ] && [ "$HOSTNAME_ID" != "gateway" ]; then
    log "  register_backup skipped for service_id=$service_id -- $HOSTNAME_ID has no path to privatenexus-db (known gap, not attempted)"
    return 0
  fi
  local rb_out rb_rc
  if [ "$HOSTNAME_ID" = "hot-pn" ]; then
    rb_out=$(eval "$psql_cmd" 2>&1); rb_rc=$?
  else
    rb_out=$(ssh -o ConnectTimeout=10 -o BatchMode=yes hot-pn "$psql_cmd" 2>&1); rb_rc=$?
  fi
  if [ "$rb_rc" -ne 0 ]; then
    log "  register_backup FAILED for service_id=$service_id (non-fatal): $rb_out"
  fi
}

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
  register_backup "$PN_SERVICE_ID" "Automated pbs-host-backup — $HOSTNAME_ID $(date '+%Y-%m-%d')" "pbs-hot:host/$HOSTNAME_ID" ""
  notify 2 "PBS host backup OK ($HOSTNAME_ID)" "Daily encrypted rebuild backup completed."
else
  log "Backup FAILED for $HOSTNAME_ID (exit $RC)"
  notify 4 "PBS host backup FAILED ($HOSTNAME_ID)" "proxmox-backup-client exited $RC. See $LOG."
fi

exit $RC
