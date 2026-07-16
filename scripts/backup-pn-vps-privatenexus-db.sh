#!/bin/bash
# Pulls PrivateNexus's nightly pg_dump off pn-vps (a temporary external VPS)
# onto the Gateway VPS, then pushes it into the same rclone-crypt cloud
# pipeline everything else on the Gateway already uses.
#
# Deliberately pull-from-Gateway rather than push-from-pn-vps: pn-vps is a
# less-trusted, external, temporary box (see CLAUDE.md's pn-vps section) and
# already has its own dedicated pg_dump.sh + local retention + service_backups
# registration (runs ~03:00 CEST via privatenexus-pg-dump.timer). Keeping the
# Hetzner/B2 rclone-crypt credentials off pn-vps entirely, and only pulling
# via the Gateway's existing SSH trust to pn-vps, keeps that box's blast
# radius minimal — consistent with the wg3/UFW scoping already done for it.
set -euo pipefail

BACKUP_DIR="/var/backups/pn-vps-privatenexus-db"
REMOTE_HOST="pn-vps"
REMOTE_PATH="/opt/privatenexus/backups"
RETENTION_DAYS=30
SMTP_PASS=$(grep -m1 WATCHTOWER_SMTP_PASSWORD /opt/stacks/watchtower/.env | cut -d= -f2)
ALERT_EMAIL="tristian@securenexus.net"
NTFY_URL="http://10.10.10.100:8080/hot-alerts"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

send_alert() {
    local title="$1" body="$2" priority="${3:-high}" tags="${4:-warning,floppy_disk}"
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
    curl -s -o /dev/null --max-time 5 \
        -H "Title: ${title}" -H "Priority: ${priority}" -H "Tags: ${tags}" \
        -d "${body}" "$NTFY_URL" || true
}

log "=== pn-vps PrivateNexus DB backup pull START ==="
mkdir -p "$BACKUP_DIR"

if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$REMOTE_HOST" "test -d $REMOTE_PATH" 2>/dev/null; then
    log "  ERROR: pn-vps unreachable — skipping this run."
    send_alert \
        "pn-vps PrivateNexus DB Backup — Pull Failed" \
        "pn-vps was unreachable when the Gateway tried to pull the latest privatenexus-db pg_dump ($(date '+%Y-%m-%d %H:%M')). Local dump + service_backups registration on pn-vps itself is unaffected — this only skips the off-host copy for this run." \
        "high" "warning,floppy_disk"
    exit 1
fi

rsync -az "${REMOTE_HOST}:${REMOTE_PATH}/" "$BACKUP_DIR/"
log "  Pulled. Local copy: $(du -sh "$BACKUP_DIR" | cut -f1) across $(ls "$BACKUP_DIR"/*.sql.gz 2>/dev/null | wc -l) file(s)."

# Push into the same cloud pipeline the rest of the Gateway's backups use.
if command -v rclone &>/dev/null; then
    REMOTES=$(rclone listremotes 2>/dev/null)
    for REMOTE in hetzner-crypt b2-hot-crypt; do
        echo "$REMOTES" | grep -q "^${REMOTE}:" || continue
        log "  Pushing to ${REMOTE}..."
        rclone copy "$BACKUP_DIR" "${REMOTE}:pn-vps-privatenexus-db/" \
            --no-traverse 2>&1 | while IFS= read -r l; do log "    rclone: $l"; done
    done
fi

find "$BACKUP_DIR" -name '*.sql.gz' -mtime +${RETENTION_DAYS} -delete

log "=== pn-vps PrivateNexus DB backup pull DONE ==="
