#!/bin/bash
# Gateway VPS nightly backup — runs 05:30 daily
# Covers: Tor hidden service keys, PowerDNS DB, Mailserver data
# Primary: push to hot-bm-nl /local-zfs/vzdump-local/dump/gateway/ (picked up by rclone at 06:00/07:30)
# Fallback: direct rclone to hetzner-crypt: if configured, extended 30-day local retention
# Path moved off the root LV 2026-08-14 — see hot_bm_nl_disk_full_2026_08_14 memory (root LV
# hit 100% because vzdump backups + this path were never pruned; both moved to the ZFS pool).
set -euo pipefail

BACKUP_DIR="/var/backups/gateway-vps"
REMOTE_HOST="hot-bm-nl"
REMOTE_PATH="/local-zfs/vzdump-local/dump/gateway"
RETENTION_DAYS=7
RETENTION_DAYS_EXTENDED=30
DATE=$(date '+%Y-%m-%d')
SMTP_PASS=$(grep -m1 WATCHTOWER_SMTP_PASSWORD /opt/stacks/watchtower/.env | cut -d= -f2)
ALERT_EMAIL="tristian@securenexus.net"
NTFY_URL="https://ntfy.house-of-trae.com/hot-alerts"
NTFY_TOKEN="tk_c2efkgyxtt24uf48bo1snua86tthb"

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
    # Ntfy best-effort
    curl -s -o /dev/null --max-time 5 \
        -H "Authorization: Bearer ${NTFY_TOKEN}" \
        -H "Title: ${title}" -H "Priority: ${priority}" -H "Tags: ${tags}" \
        -d "${body}" "$NTFY_URL" || true
}

log "=== Gateway VPS backup START ==="
mkdir -p "$BACKUP_DIR/tor" "$BACKUP_DIR/powerdns" "$BACKUP_DIR/mailserver"

# ── 1. Tor hidden service keys (unrecoverable — losing key = losing onion address) ──
# tar exit code 1 ("some files differ", e.g. changed mid-read) is a non-fatal warning, not an
# error — only exit code 2+ is a real tar failure. Under set -e, an unguarded tar call would
# otherwise kill the whole script silently on exit 1, before any alert code ever runs (this is
# exactly what happened to the mailserver archive below on 2026-08-08 — see backup_architecture
# notes). Guard both tar calls the same way for consistency.
log "Backing up Tor hidden service keys..."
tar -czf "$BACKUP_DIR/tor/tor-hidden-service-$DATE.tar.gz" -C /opt/stacks/tor/data erp || {
    rc=$?
    [ "$rc" -eq 1 ] && log "  WARNING: tar exit 1 (files changed mid-read) — archive still usable, continuing." || exit "$rc"
}
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
    data state config mailserver.env || {
    rc=$?
    [ "$rc" -eq 1 ] && log "  WARNING: tar exit 1 (files changed mid-read, e.g. live rspamd/postfix state) — archive still usable, continuing." || exit "$rc"
}
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
    RCLONE_FAILED=0
    RCLONE_FAIL_DETAIL=""
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
                set +e
                rclone copy "$f" "${REMOTE}:gateway-vps-backups/${subdir}/" \
                    --no-traverse 2>&1 | while IFS= read -r l; do log "    rclone: $l"; done
                rc=${PIPESTATUS[0]}
                set -e
                if [ "$rc" -ne 0 ]; then
                    RCLONE_FAILED=1
                    RCLONE_FAIL_DETAIL+="${REMOTE}:${subdir}/$(basename "$f") "
                fi
            done
        done
        log "  rclone push complete (failed=${RCLONE_FAILED})."
    fi

    send_alert \
        "Gateway Backup — Proxmox Push Failed" \
        "Gateway VPS nightly backup OK (${SIZES}) but hot-bm-nl unreachable — retained locally for ${RETENTION_DAYS_EXTENDED}d in ${BACKUP_DIR}." \
        "high" "warning,floppy_disk"

    if [ "$RCLONE_FAILED" -eq 1 ]; then
        send_alert \
            "Gateway Backup — Cloud (rclone) Push Failed" \
            "One or more rclone pushes to Hetzner/B2 failed tonight: ${RCLONE_FAIL_DETAIL}. Check /var/log/hot-gateway-vps-backup.log. Local copy is safe in ${BACKUP_DIR} for ${RETENTION_DAYS_EXTENDED}d." \
            "high" "warning,floppy_disk"
    fi
fi

# ── Local retention ───────────────────────────────────────────────────────────
log "Pruning local backups older than ${PRUNED_AFTER}d..."
find "$BACKUP_DIR" -type f \( -name "*.tar.gz" -o -name "*.sql.gz" \) \
    -mtime "+${PRUNED_AFTER}" -delete

log "=== Gateway VPS backup DONE ==="
