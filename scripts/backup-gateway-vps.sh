#!/bin/bash
# Gateway VPS nightly backup — runs 05:30 daily
# Covers: Tor hidden service keys, PowerDNS DB, Mailserver data
# Primary: push to Proxmox /var/lib/vz/dump/gateway/ (picked up by rclone at 06:00/07:30)
# Fallback: direct rclone to hetzner-crypt: if configured, extended 30-day local retention
set -euo pipefail

BACKUP_DIR="/var/backups/gateway-vps"
REMOTE_HOST="proxmox"
REMOTE_PATH="/var/lib/vz/dump/gateway"
RETENTION_DAYS=7
RETENTION_DAYS_EXTENDED=30
DATE=$(date '+%Y-%m-%d')
SMTP_PASS=$(grep -m1 WATCHTOWER_SMTP_PASSWORD /opt/stacks/watchtower/.env | cut -d= -f2)
ALERT_EMAIL="tristian@securenexus.net"
NTFY_URL="http://10.10.10.100:8080/hot-alerts"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

send_alert() {
    local title="$1" body="$2" priority="${3:-high}" tags="${4:-warning,floppy_disk}"
    # Email via local mailserver (always up on Gateway VPS)
    curl -s --max-time 15 \
        --url "smtp://127.0.0.1:587" --ssl-reqd --insecure \
        --mail-from "notifications@house-of-trae.com" \
        --mail-rcpt "$ALERT_EMAIL" \
        --user "notifications@house-of-trae.com:${SMTP_PASS}" \
        --upload-file - 2>/dev/null <<MAIL || true
From: notifications@house-of-trae.com
To: ${ALERT_EMAIL}
Subject: [HoT] ${title}
Content-Type: text/plain

${body}
MAIL
    # Ntfy best-effort — sn-infra may also be unreachable during bare-metal outage
    curl -s -o /dev/null --max-time 5 \
        -H "Title: ${title}" -H "Priority: ${priority}" -H "Tags: ${tags}" \
        -d "${body}" "$NTFY_URL" || true
}

log "=== Gateway VPS backup START ==="
mkdir -p "$BACKUP_DIR/tor" "$BACKUP_DIR/powerdns" "$BACKUP_DIR/mailserver"

# ── 1. Tor hidden service keys (unrecoverable — losing key = losing onion address) ──
log "Backing up Tor hidden service keys..."
tar -czf "$BACKUP_DIR/tor/tor-hidden-service-$DATE.tar.gz" -C /opt/stacks/tor/data erp
log "  Tor: $(du -sh "$BACKUP_DIR/tor/tor-hidden-service-$DATE.tar.gz" | cut -f1)"

# ── 2. PowerDNS PostgreSQL ────────────────────────────────────────────────────
log "Dumping PowerDNS PostgreSQL..."
docker exec powerdns-db pg_dump -U powerdns powerdns \
    | gzip > "$BACKUP_DIR/powerdns/powerdns-db-$DATE.sql.gz"
log "  PowerDNS: $(du -sh "$BACKUP_DIR/powerdns/powerdns-db-$DATE.sql.gz" | cut -f1)"

# ── 3. Mailserver data ────────────────────────────────────────────────────────
log "Archiving mailserver data..."
tar -czf "$BACKUP_DIR/mailserver/mailserver-$DATE.tar.gz" \
    --exclude='state/spool-postfix/private' \
    --exclude='state/spool-postfix/public' \
    --exclude='state/lib-rspamd/*.sock' \
    -C /opt/stacks/mailserver \
    data state config mailserver.env
log "  Mailserver: $(du -sh "$BACKUP_DIR/mailserver/mailserver-$DATE.tar.gz" | cut -f1)"

# ── Push to Proxmox (non-fatal — Proxmox may be unreachable during outage) ───
log "Pushing to $REMOTE_HOST:$REMOTE_PATH ..."
PRUNED_AFTER=$RETENTION_DAYS
if ssh -o ConnectTimeout=10 -o BatchMode=yes "$REMOTE_HOST" "mkdir -p $REMOTE_PATH" 2>/dev/null; then
    scp "$BACKUP_DIR/tor/tor-hidden-service-$DATE.tar.gz"  "$REMOTE_HOST:$REMOTE_PATH/"
    scp "$BACKUP_DIR/powerdns/powerdns-db-$DATE.sql.gz"    "$REMOTE_HOST:$REMOTE_PATH/"
    scp "$BACKUP_DIR/mailserver/mailserver-$DATE.tar.gz"   "$REMOTE_HOST:$REMOTE_PATH/"
    log "  Push complete."
else
    log "  WARNING: Proxmox unreachable — extending retention to ${RETENTION_DAYS_EXTENDED}d."
    PRUNED_AFTER=$RETENTION_DAYS_EXTENDED
    SIZES="tor:$(du -sh "$BACKUP_DIR/tor/tor-hidden-service-$DATE.tar.gz" | cut -f1)"
    SIZES+=" powerdns:$(du -sh "$BACKUP_DIR/powerdns/powerdns-db-$DATE.sql.gz" | cut -f1)"
    SIZES+=" mailserver:$(du -sh "$BACKUP_DIR/mailserver/mailserver-$DATE.tar.gz" | cut -f1)"

    # Direct rclone push to both cloud remotes — belt-and-suspenders
    if command -v rclone &>/dev/null; then
        REMOTES=$(rclone listremotes 2>/dev/null)
        for REMOTE in hetzner-crypt b2-hot-crypt; do
            echo "$REMOTES" | grep -q "^${REMOTE}:" || continue
            log "  Pushing to ${REMOTE}..."
            for f in \
                "$BACKUP_DIR/tor/tor-hidden-service-$DATE.tar.gz" \
                "$BACKUP_DIR/powerdns/powerdns-db-$DATE.sql.gz" \
                "$BACKUP_DIR/mailserver/mailserver-$DATE.tar.gz"; do
                subdir=$(basename $(dirname "$f"))
                rclone copy "$f" "${REMOTE}:gateway-vps-backups/${subdir}/" \
                    --no-traverse 2>&1 | while IFS= read -r l; do log "    rclone: $l"; done
            done
        done
        log "  rclone push complete."
    fi

    send_alert \
        "Gateway Backup — Proxmox Push Failed" \
        "Gateway VPS nightly backup OK (${SIZES}) but Proxmox unreachable — retained locally for ${RETENTION_DAYS_EXTENDED}d in ${BACKUP_DIR}." \
        "high" "warning,floppy_disk"
fi

# ── Local retention ───────────────────────────────────────────────────────────
log "Pruning local backups older than ${PRUNED_AFTER}d..."
find "$BACKUP_DIR" -type f \( -name "*.tar.gz" -o -name "*.sql.gz" \) \
    -mtime "+${PRUNED_AFTER}" -delete

log "=== Gateway VPS backup DONE ==="
