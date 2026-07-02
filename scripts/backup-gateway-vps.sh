#!/bin/bash
# Gateway VPS nightly backup — runs 05:30 daily (after vzdump ~05:00, before rclone 06:00)
# Covers: Tor hidden service keys, PowerDNS DB, Mailserver data
# Pushes to Proxmox /var/lib/vz/dump/gateway/ — picked up by Hetzner/B2 rclone jobs.
set -euo pipefail

BACKUP_DIR="/var/backups/gateway-vps"
REMOTE_HOST="proxmox"
REMOTE_PATH="/var/lib/vz/dump/gateway"
RETENTION_DAYS=7
DATE=$(date '+%Y-%m-%d')

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "=== Gateway VPS backup START ==="
mkdir -p "$BACKUP_DIR/tor" "$BACKUP_DIR/powerdns" "$BACKUP_DIR/mailserver"

# ── 1. Tor hidden service keys ─────────────────────────────────────────────
# hs_ed25519_secret_key is unrecoverable — losing it means losing the onion address.
log "Backing up Tor hidden service keys..."
tar -czf "$BACKUP_DIR/tor/tor-hidden-service-$DATE.tar.gz" -C /opt/stacks/tor/data erp
log "  Tor: $(du -sh "$BACKUP_DIR/tor/tor-hidden-service-$DATE.tar.gz" | cut -f1)"

# ── 2. PowerDNS PostgreSQL ─────────────────────────────────────────────────
log "Dumping PowerDNS PostgreSQL..."
docker exec powerdns-db pg_dump -U powerdns powerdns \
    | gzip > "$BACKUP_DIR/powerdns/powerdns-db-$DATE.sql.gz"
log "  PowerDNS: $(du -sh "$BACKUP_DIR/powerdns/powerdns-db-$DATE.sql.gz" | cut -f1)"

# ── 3. Mailserver data ─────────────────────────────────────────────────────
log "Archiving mailserver data..."
tar -czf "$BACKUP_DIR/mailserver/mailserver-$DATE.tar.gz" \
    --exclude='state/spool-postfix/private' \
    --exclude='state/spool-postfix/public' \
    --exclude='state/lib-rspamd/*.sock' \
    -C /opt/stacks/mailserver \
    data state config mailserver.env
log "  Mailserver: $(du -sh "$BACKUP_DIR/mailserver/mailserver-$DATE.tar.gz" | cut -f1)"

# ── Push to Proxmox (non-fatal — Proxmox may be unreachable during outage) ──
log "Pushing to $REMOTE_HOST:$REMOTE_PATH ..."
if ssh -o ConnectTimeout=10 -o BatchMode=yes "$REMOTE_HOST" "mkdir -p $REMOTE_PATH" 2>/dev/null; then
    scp "$BACKUP_DIR/tor/tor-hidden-service-$DATE.tar.gz"    "$REMOTE_HOST:$REMOTE_PATH/"
    scp "$BACKUP_DIR/powerdns/powerdns-db-$DATE.sql.gz"      "$REMOTE_HOST:$REMOTE_PATH/"
    scp "$BACKUP_DIR/mailserver/mailserver-$DATE.tar.gz"     "$REMOTE_HOST:$REMOTE_PATH/"
    log "  Push complete."
else
    log "  WARNING: Proxmox unreachable — backups retained locally for ${RETENTION_DAYS}d."
    curl -s -o /dev/null \
        -H "Title: Gateway Backup — Proxmox Push Failed" \
        -H "Priority: high" \
        -H "Tags: warning,floppy_disk" \
        -d "Gateway VPS nightly backup completed locally but could not push to Proxmox (unreachable). Archives retained for ${RETENTION_DAYS} days in ${BACKUP_DIR}." \
        "http://10.10.10.100:8080/hot-alerts" || true
fi

# ── Local retention ────────────────────────────────────────────────────────
log "Pruning local backups older than ${RETENTION_DAYS}d..."
find "$BACKUP_DIR" -type f \( -name "*.tar.gz" -o -name "*.sql.gz" \) \
    -mtime "+$RETENTION_DAYS" -delete

log "=== Gateway VPS backup DONE ==="
