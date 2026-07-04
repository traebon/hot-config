#!/bin/bash
# Keycloak PostgreSQL nightly dump — runs 01:30 on Gateway VPS
# Primary: push to Proxmox /var/lib/vz/dump/gateway/ (picked up by rclone at 06:00/07:30)
# Fallback: direct rclone to hetzner-crypt: if configured, extended 30-day local retention
set -euo pipefail

DUMP_DIR="/var/backups/keycloak"
REMOTE_HOST="proxmox"
REMOTE_PATH="/var/lib/vz/dump/gateway"
DB_NAME="keycloak"
DB_USER="keycloak"
CONTAINER="keycloak-db"
RETENTION_DAYS=7
RETENTION_DAYS_EXTENDED=30
DATE=$(date '+%Y-%m-%d')
OUTFILE="$DUMP_DIR/keycloak-db-$DATE.sql.gz"
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

log "=== Keycloak backup START ==="
mkdir -p "$DUMP_DIR"

# Dump — fatal if this fails (dump is the whole point)
docker exec "$CONTAINER" pg_dump -U "$DB_USER" "$DB_NAME" | gzip > "$OUTFILE"
SIZE=$(du -sh "$OUTFILE" | cut -f1)
log "Dump complete: $OUTFILE ($SIZE)"

# Push to Proxmox (non-fatal — Proxmox may be unreachable during outage)
PRUNED_AFTER=$RETENTION_DAYS
if ssh -o ConnectTimeout=10 -o BatchMode=yes "$REMOTE_HOST" "mkdir -p $REMOTE_PATH" 2>/dev/null; then
    scp "$OUTFILE" "$REMOTE_HOST:$REMOTE_PATH/"
    log "Pushed to $REMOTE_HOST:$REMOTE_PATH/"
else
    log "WARNING: Proxmox unreachable — extending retention to ${RETENTION_DAYS_EXTENDED}d."
    PRUNED_AFTER=$RETENTION_DAYS_EXTENDED

    # Direct rclone push if configured (runs when rclone is set up with hetzner-crypt remote)
    if command -v rclone &>/dev/null && rclone listremotes 2>/dev/null | grep -q "^hetzner-crypt:"; then
        log "Pushing direct to hetzner-crypt via rclone..."
        rclone copy "$OUTFILE" "hetzner-crypt:gateway-vps-backups/keycloak/" \
            --no-traverse 2>&1 | while IFS= read -r l; do log "  rclone: $l"; done
        log "rclone push complete."
    fi

    send_alert \
        "Keycloak Backup — Proxmox Push Failed" \
        "Keycloak nightly dump OK (${SIZE}) but Proxmox unreachable — retained locally for ${RETENTION_DAYS_EXTENDED}d in ${DUMP_DIR}." \
        "high" "warning,floppy_disk"
fi

find "$DUMP_DIR" -name "keycloak-db-*.sql.gz" -mtime "+${PRUNED_AFTER}" -delete
log "Local retention cleanup done (>${PRUNED_AFTER}d)."
log "=== Keycloak backup DONE ==="
