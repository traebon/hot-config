#!/bin/bash
# Pulls PrivateNexus's nightly pg_dump off hot-pn (PrivateNexus's permanent home,
# formerly a temporary stand-in named pn-vps -- made permanent 2026-07-24, see
# hostkey_server_replacement memory) onto the Gateway VPS, then pushes it into the
# same rclone-crypt cloud pipeline everything else on the Gateway already uses.
#
# Deliberately pull-from-Gateway rather than push-from-hot-pn: hot-pn is a
# less-trusted, external box (see CLAUDE.md's hot-pn section) and already has its
# own dedicated pg_dump.sh + local retention + service_backups registration (runs
# ~03:00 CEST via privatenexus-pg-dump.timer). Keeping the Hetzner/B2 rclone-crypt
# credentials off hot-pn entirely, and only pulling via the Gateway's existing SSH
# trust to hot-pn, keeps that box's blast radius minimal -- consistent with the
# wg3/UFW scoping already done for it.
set -euo pipefail

BACKUP_DIR="/var/backups/hot-pn-privatenexus-db"
REMOTE_HOST="hot-pn"
REMOTE_PATH="/opt/privatenexus/backups"
RETENTION_DAYS=30
SMTP_PASS=$(grep -m1 WATCHTOWER_SMTP_PASSWORD /opt/stacks/watchtower/.env | cut -d= -f2)
ALERT_EMAIL="tristian@securenexus.net"
NTFY_URL="https://ntfy.house-of-trae.com/hot-alerts"
NTFY_TOKEN="tk_c2efkgyxtt24uf48bo1snua86tthb"

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
        -H "Authorization: Bearer ${NTFY_TOKEN}" \
        -H "Title: ${title}" -H "Priority: ${priority}" -H "Tags: ${tags}" \
        -d "${body}" "$NTFY_URL" || true
}

log "=== hot-pn PrivateNexus DB backup pull START ==="
mkdir -p "$BACKUP_DIR"

# Retry once after a short wait — hot-pn can now auto-reboot for kernel updates
# (2026-08-05 apt rollout) and a reboot landing right at 03:30 would otherwise
# cause a one-night gap. A single 90s-delayed retry covers a normal boot cycle
# without meaningfully delaying the rest of the backup chain (Gateway pulls this
# at 03:30, well ahead of the 06:00/07:30 cloud syncs).
REACHABLE=0
for attempt in 1 2; do
    if ssh -o ConnectTimeout=10 -o BatchMode=yes "$REMOTE_HOST" "test -d $REMOTE_PATH" 2>/dev/null; then
        REACHABLE=1
        break
    fi
    log "  hot-pn unreachable (attempt ${attempt}/2)."
    [ "$attempt" -eq 1 ] && sleep 90
done

if [ "$REACHABLE" -eq 0 ]; then
    log "  ERROR: hot-pn unreachable after retry — skipping this run."
    send_alert \
        "hot-pn PrivateNexus DB Backup — Pull Failed" \
        "hot-pn was unreachable (after a 90s retry) when the Gateway tried to pull the latest privatenexus-db pg_dump ($(date '+%Y-%m-%d %H:%M')). Local dump + service_backups registration on hot-pn itself is unaffected — this only skips the off-host copy for this run." \
        "high" "warning,floppy_disk"
    exit 1
fi

if ! rsync -az "${REMOTE_HOST}:${REMOTE_PATH}/" "$BACKUP_DIR/"; then
    log "  ERROR: rsync pull failed after hot-pn was confirmed reachable."
    send_alert \
        "hot-pn PrivateNexus DB Backup — rsync Failed" \
        "hot-pn responded to the reachability check but the rsync pull itself failed ($(date '+%Y-%m-%d %H:%M')). Check /var/log/hot-pn-db-backup.log." \
        "high" "warning,floppy_disk"
    exit 1
fi
log "  Pulled. Local copy: $(du -sh "$BACKUP_DIR" | cut -f1) across $(ls "$BACKUP_DIR"/*.sql.gz 2>/dev/null | wc -l) file(s)."

# Push into the same cloud pipeline the rest of the Gateway's backups use.
# NOTE: the rclone destination folder name changed from "pn-vps-privatenexus-db/"
# to "hot-pn-privatenexus-db/" on 2026-07-24 (the rename). Historical backups
# pushed before that date remain under the old folder name on Hetzner/B2 --
# they were not moved, just left as history. Nothing new writes there anymore.
RCLONE_FAILED=0
RCLONE_FAIL_DETAIL=""
if command -v rclone &>/dev/null; then
    REMOTES=$(rclone listremotes 2>/dev/null)
    for REMOTE in hetzner-crypt b2-hot-crypt; do
        echo "$REMOTES" | grep -q "^${REMOTE}:" || continue
        log "  Pushing to ${REMOTE}..."
        set +e
        rclone copy "$BACKUP_DIR" "${REMOTE}:hot-pn-privatenexus-db/" \
            --no-traverse 2>&1 | while IFS= read -r l; do log "    rclone: $l"; done
        rc=${PIPESTATUS[0]}
        set -e
        if [ "$rc" -ne 0 ]; then
            RCLONE_FAILED=1
            RCLONE_FAIL_DETAIL+="${REMOTE} "
        fi
    done
fi

if [ "$RCLONE_FAILED" -eq 1 ]; then
    send_alert \
        "hot-pn PrivateNexus DB Backup — Cloud (rclone) Push Failed" \
        "The local pull from hot-pn succeeded, but the rclone push failed for: ${RCLONE_FAIL_DETAIL}. Check /var/log/hot-pn-db-backup.log. Local copy is safe in ${BACKUP_DIR} for ${RETENTION_DAYS}d." \
        "high" "warning,floppy_disk"
fi

find "$BACKUP_DIR" -name '*.sql.gz' -mtime +${RETENTION_DAYS} -delete

log "=== hot-pn PrivateNexus DB backup pull DONE ==="
