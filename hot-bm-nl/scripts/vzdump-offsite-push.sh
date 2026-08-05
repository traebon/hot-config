#!/bin/bash
# Pushes the previous night's vzdump archives (VMs 100/102/104/106) from hot-bm-nl's
# local ZFS-backed dump storage to Hetzner + B2 (rclone crypt), mirroring the pattern
# already used by the Gateway VPS's own backup-*.sh scripts. Runs after the 02:00
# daily-fleet-backup vzdump job (systemd timer, see vzdump-offsite-push.timer).
set -uo pipefail

DUMP_DIR="/var/lib/vz/dump"
RETENTION_DAYS=14
ALERT_EMAIL="tristian@securenexus.net"
SMTP_HOST="10.10.3.1"
NTFY_URL="https://ntfy.house-of-trae.com/hot-alerts"
source /etc/vzdump-offsite/secrets.env

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

send_alert() {
    local title="$1" body="$2" priority="${3:-high}" tags="${4:-warning,floppy_disk}"
    curl -s --max-time 15 \
        --url "smtp://${SMTP_HOST}:587" --ssl-reqd --insecure \
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

log "=== vzdump offsite push START ==="

# Only push files from the last 26h — avoids re-uploading the whole local retention
# window (storage.cfg keeps everything, keep-all=1) every single night.
mapfile -t FILES < <(find "$DUMP_DIR" -maxdepth 1 -type f \( -name 'vzdump-qemu-*.vma.zst' -o -name 'vzdump-qemu-*.log' -o -name 'vzdump-qemu-*.notes' \) -mmin -1560)

if [ "${#FILES[@]}" -eq 0 ]; then
    log "  No fresh vzdump files found in the last 26h — nothing to push."
    send_alert \
        "vzdump Offsite Push — No Fresh Backups Found" \
        "The offsite push ran but found no vzdump-qemu-* files modified in the last 26h in ${DUMP_DIR}. Check whether last night's daily-fleet-backup job (02:00) actually ran — 'pvesh get /cluster/backup' and the Proxmox task log." \
        "high" "warning,floppy_disk"
    exit 1
fi

log "  Found ${#FILES[@]} fresh file(s) to push."

FAILED=0
FAIL_DETAIL=""
for REMOTE in hetzner-crypt b2-hot-crypt; do
    rclone listremotes 2>/dev/null | grep -q "^${REMOTE}:" || continue
    log "  Pushing to ${REMOTE}..."
    for f in "${FILES[@]}"; do
        set +e
        rclone copy "$f" "${REMOTE}:proxmox-vm-backups/" --no-traverse 2>&1 | while IFS= read -r l; do log "    rclone: $l"; done
        rc=${PIPESTATUS[0]}
        set -e
        if [ "$rc" -ne 0 ]; then
            FAILED=1
            FAIL_DETAIL+="${REMOTE}:$(basename "$f") "
        fi
    done
done

if [ "$FAILED" -eq 1 ]; then
    send_alert \
        "vzdump Offsite Push — Cloud Push Failed" \
        "One or more vzdump files failed to push to Hetzner/B2: ${FAIL_DETAIL}. Check /var/log/vzdump-offsite-push.log on hot-bm-nl. Local copies remain in ${DUMP_DIR}." \
        "high" "warning,floppy_disk"
fi

# Offsite retention — local storage.cfg keeps everything (keep-all=1), so prune the
# cloud copies here to avoid unbounded growth (this is what tripped the B2 cap before).
for REMOTE in hetzner-crypt b2-hot-crypt; do
    rclone listremotes 2>/dev/null | grep -q "^${REMOTE}:" || continue
    rclone delete "${REMOTE}:proxmox-vm-backups/" --min-age "${RETENTION_DAYS}d" 2>&1 | while IFS= read -r l; do log "    prune ${REMOTE}: $l"; done
done

log "=== vzdump offsite push DONE (failed=${FAILED}) ==="
