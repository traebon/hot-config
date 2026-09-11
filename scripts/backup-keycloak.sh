#!/bin/bash
# Keycloak PostgreSQL nightly dump — runs 01:30 on Gateway VPS
# Primary: push to hot-bm-nl /local-zfs/vzdump-local/dump/gateway/ (picked up by rclone at 06:00/07:30)
# Fallback: direct rclone to hetzner-crypt: if configured, extended 30-day local retention
# Path moved off the root LV 2026-08-14 — see hot_bm_nl_disk_full_2026_08_14 memory (root LV
# hit 100% because vzdump backups + this path were never pruned; both moved to the ZFS pool).
set -euo pipefail

DUMP_DIR="/var/backups/keycloak"
REMOTE_HOST="hot-bm-nl"
REMOTE_PATH="/local-zfs/vzdump-local/dump/gateway"
DB_NAME="keycloak"
DB_USER="keycloak"
CONTAINER="keycloak-db"
RETENTION_DAYS=7
RETENTION_DAYS_EXTENDED=30
DATE=$(date '+%Y-%m-%d')
OUTFILE="$DUMP_DIR/keycloak-db-$DATE.sql.gz"
SMTP_PASS=$(grep -m1 WATCHTOWER_SMTP_PASSWORD /opt/stacks/watchtower/.env | cut -d= -f2)
ALERT_EMAIL="tristian@securenexus.net"
NTFY_URL="https://ntfy.house-of-trae.com/hot-alerts"
NTFY_TOKEN="tk_c2efkgyxtt24uf48bo1snua86tthb"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ── Register a completed backup into PN's own service_backups table ─────────────────────────────
# Same gap, same fix as fleet-state-backup.sh/backup-gateway-vps.sh (2026-09-10/11): this dump has
# always genuinely run, but nothing ever told PN — gateway-keycloak-db/keycloak-hot both showed
# backup_policy=daily next to zero rows in service_backups. Direct psql INSERT (this script runs
# unattended on cron, no session to hold), same pattern pg_dump.sh already used for privatenexus-db.
# args: service_id  label  location  size_bytes
register_backup() {
  local service_id="$1" label="$2" location="$3" size_bytes="$4"
  [ -z "$service_id" ] && return 0
  local esc_label esc_location
  esc_label="$(printf '%s' "$label" | sed "s/'/''/g")"
  esc_location="$(printf '%s' "$location" | sed "s/'/''/g")"
  local sql="INSERT INTO service_backups (tenant_id, service_id, label, backup_type, trust_state, location, size_bytes, notes) VALUES ('10000000-0000-0000-0000-000000000001', '${service_id}', '${esc_label}', 'full', 'trusted', '${esc_location}', ${size_bytes:-NULL}, 'Registered by backup-keycloak.sh (Gateway) -- same pattern pg_dump.sh uses for privatenexus-db.');"
  if ! ssh -o ConnectTimeout=10 -o BatchMode=yes hot-pn \
      "docker exec -i privatenexus-db psql -U privatenexus -d privatenexus -v ON_ERROR_STOP=1 -c \"$sql\"" \
      >/tmp/register_backup.err 2>&1; then
    log "  register_backup FAILED for service_id=$service_id (non-fatal): $(cat /tmp/register_backup.err 2>/dev/null)"
  fi
  rm -f /tmp/register_backup.err
}

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

log "=== Keycloak backup START ==="
mkdir -p "$DUMP_DIR"

# Dump — fatal if this fails (dump is the whole point)
docker exec "$CONTAINER" pg_dump -U "$DB_USER" "$DB_NAME" | gzip > "$OUTFILE"
SIZE=$(du -sh "$OUTFILE" | cut -f1)
log "Dump complete: $OUTFILE ($SIZE)"
SIZE_BYTES=$(stat -c%s "$OUTFILE" 2>/dev/null)
register_backup "4d5cff0b-50aa-4eb2-abc5-2c87bef57919" "Automated backup-keycloak — $DATE" "$OUTFILE" "$SIZE_BYTES"
register_backup "de386f0b-78bc-4161-9233-aa55084ed1e1" "Automated backup-keycloak — $DATE" "$OUTFILE" "$SIZE_BYTES"

# Push to Proxmox (non-fatal — Proxmox may be unreachable during outage)
PRUNED_AFTER=$RETENTION_DAYS
if ssh -o ConnectTimeout=10 -o BatchMode=yes "$REMOTE_HOST" "mkdir -p $REMOTE_PATH" 2>/dev/null; then
    scp "$OUTFILE" "$REMOTE_HOST:$REMOTE_PATH/"
    log "Pushed to $REMOTE_HOST:$REMOTE_PATH/"
else
    log "WARNING: Proxmox unreachable — extending retention to ${RETENTION_DAYS_EXTENDED}d."
    PRUNED_AFTER=$RETENTION_DAYS_EXTENDED

    # Direct rclone push to both cloud remotes — belt-and-suspenders
    RCLONE_FAILED=0
    RCLONE_FAIL_DETAIL=""
    if command -v rclone &>/dev/null; then
        REMOTES=$(rclone listremotes 2>/dev/null)
        if echo "$REMOTES" | grep -q "^hetzner-crypt:"; then
            log "Pushing to hetzner-crypt..."
            set +e
            rclone copy "$OUTFILE" "hetzner-crypt:gateway-vps-backups/keycloak/" \
                --no-traverse 2>&1 | while IFS= read -r l; do log "  rclone: $l"; done
            rc=${PIPESTATUS[0]}
            set -e
            if [ "$rc" -ne 0 ]; then
                RCLONE_FAILED=1
                RCLONE_FAIL_DETAIL+="hetzner-crypt "
            fi
        fi
        if echo "$REMOTES" | grep -q "^b2-hot-crypt:"; then
            log "Pushing to b2-hot-crypt..."
            set +e
            rclone copy "$OUTFILE" "b2-hot-crypt:gateway-vps-backups/keycloak/" \
                --no-traverse 2>&1 | while IFS= read -r l; do log "  rclone: $l"; done
            rc=${PIPESTATUS[0]}
            set -e
            if [ "$rc" -ne 0 ]; then
                RCLONE_FAILED=1
                RCLONE_FAIL_DETAIL+="b2-hot-crypt "
            fi
        fi
    fi

    send_alert \
        "Keycloak Backup — Proxmox Push Failed" \
        "Keycloak nightly dump OK (${SIZE}) but hot-bm-nl unreachable — retained locally for ${RETENTION_DAYS_EXTENDED}d in ${DUMP_DIR}." \
        "high" "warning,floppy_disk"

    if [ "$RCLONE_FAILED" -eq 1 ]; then
        send_alert \
            "Keycloak Backup — Cloud (rclone) Push Failed" \
            "rclone push failed for: ${RCLONE_FAIL_DETAIL}. Check /var/log/hot-keycloak-backup.log. Local copy is safe in ${DUMP_DIR} for ${RETENTION_DAYS_EXTENDED}d." \
            "high" "warning,floppy_disk"
    fi
fi

find "$DUMP_DIR" -name "keycloak-db-*.sql.gz" -mtime "+${PRUNED_AFTER}" -delete
log "Local retention cleanup done (>${PRUNED_AFTER}d)."
log "=== Keycloak backup DONE ==="
