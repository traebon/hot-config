#!/bin/bash
# Pushes the previous night's vzdump archive for VM 100 (sn-infra) from hot-bm-nl's local
# ZFS-backed dump storage to Hetzner (rclone crypt) — Hetzner only, deliberately not B2 (see
# backup_architecture_b2_scope_2026_08_08 memory). VM 100 only, deliberately — 102/104/106
# moved to PBS-only backup 2026-09-07 (daily-fleet-backup-pbs job, no offsite bridge by
# design, see docs/HoT_PBS_Backup_Integration_Scope.md). Scoped to vzdump-qemu-100-* here
# 2026-09-09 after a real incident: this script previously matched any vzdump-qemu-* file in
# DUMP_DIR, so it also pushed 102/104/106's images during the 2026-09-04→09-07 interim window
# when they were briefly back on local-backup-zfs — those never got cleaned up once 102/104/106
# left this path again, and 14-day retention wasn't fast enough to prevent Hetzner filling to
# 998GB/1TB (found+fixed 2026-09-09, ~747GB of orphaned 102/104/106 copies deleted — PBS already
# held current backups of all three throughout). Runs after the 02:00 daily-fleet-backup vzdump
# job (systemd timer, see vzdump-offsite-push.timer).
set -uo pipefail

DUMP_DIR="/local-zfs/vzdump-local/dump"
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
# window (storage.cfg keeps everything, keep-all=1) every single night. Scoped to VM 100
# only (vzdump-qemu-100-*) — see header note above for why matching any VMID here bit us.
mapfile -t FILES < <(find "$DUMP_DIR" -maxdepth 1 -type f \( -name 'vzdump-qemu-100-*.vma.zst' -o -name 'vzdump-qemu-100-*.log' -o -name 'vzdump-qemu-100-*.notes' \) -mmin -1560)

if [ "${#FILES[@]}" -eq 0 ]; then
    log "  No fresh VM 100 vzdump files found in the last 26h — nothing to push."
    send_alert \
        "vzdump Offsite Push — No Fresh Backups Found" \
        "The offsite push ran but found no vzdump-qemu-100-* files modified in the last 26h in ${DUMP_DIR}. Check whether last night's daily-fleet-backup job (02:00) actually ran — 'pvesh get /cluster/backup' and the Proxmox task log." \
        "high" "warning,floppy_disk"
    exit 1
fi

log "  Found ${#FILES[@]} fresh file(s) to push."

# Free-space guard — the 2026-09-09 incident's actual failure symptom was a cryptic
# SSH_FX_FAILURE from the storage box, not an obvious "disk full" error. Check headroom
# before pushing so a low-space condition is reported plainly instead of masquerading as
# an SFTP fault.
FREE_GIB=$(rclone about hetzner-crypt: --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(round(d.get("free",0)/1024/1024/1024,1))' 2>/dev/null || echo "")
if [ -n "$FREE_GIB" ]; then
    log "  Hetzner free space: ${FREE_GIB} GiB"
    if awk -v f="$FREE_GIB" 'BEGIN{exit !(f<50)}'; then
        send_alert \
            "vzdump Offsite Push — Hetzner Storage Box Low on Space" \
            "Only ${FREE_GIB} GiB free on the Hetzner Storage Box before tonight's push — check for orphaned/stale data (rclone size hetzner-crypt:<dir>) or the offsite push may start failing with cryptic SFTP errors." \
            "high" "warning,floppy_disk"
    fi
fi

FAILED=0
FAIL_DETAIL=""
for REMOTE in hetzner-crypt; do
    rclone listremotes 2>/dev/null | grep -q "^${REMOTE}:" || continue
    log "  Pushing to ${REMOTE}..."
    for f in "${FILES[@]}"; do
        set +e
        rclone copy "$f" "${REMOTE}:proxmox-vm-backups/" --no-traverse --bwlimit 20M --transfers 2 --checkers 4 2>&1 | while IFS= read -r l; do log "    rclone: $l"; done
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
        "One or more vzdump files failed to push to Hetzner: ${FAIL_DETAIL}. Check /var/log/vzdump-offsite-push.log on hot-bm-nl. Local copies remain in ${DUMP_DIR}." \
        "high" "warning,floppy_disk"
fi

# Offsite retention — local storage.cfg now uses keep-daily=3,keep-weekly=1 (fixed
# 2026-08-14, was keep-all=1 and filled the root LV to 100% — see
# hot_bm_nl_disk_full_2026_08_14 memory), but still prune the cloud copy independently
# to avoid unbounded growth there too.
for REMOTE in hetzner-crypt; do
    rclone listremotes 2>/dev/null | grep -q "^${REMOTE}:" || continue
    rclone delete "${REMOTE}:proxmox-vm-backups/" --min-age "${RETENTION_DAYS}d" 2>&1 | while IFS= read -r l; do log "    prune ${REMOTE}: $l"; done
done

log "=== vzdump offsite push DONE (failed=${FAILED}) ==="

# Real bug found+fixed 2026-09-09: this script never exited non-zero on a push failure
# (only the "no fresh files" early-exit path did), so systemd always saw the service as
# 0/SUCCESS even on a night the actual rclone push failed -- a silent-success trap of
# exactly the kind this project keeps re-finding elsewhere (fleet-state-backup's push()
# PIPESTATUS bug, ERPNext's unless-stopped trap). Exit code now reflects the real outcome
# so fleet-health-sweep's systemd-Result-based check actually sees a failure.
exit "$FAILED"
