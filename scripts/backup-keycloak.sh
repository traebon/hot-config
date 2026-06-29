#!/bin/bash
# Keycloak PostgreSQL nightly dump — runs 01:30 on Gateway VPS
# Output pushed to Proxmox /var/lib/vz/dump/gateway/ where B2 and Hetzner
# rclone jobs pick it up automatically at 06:00 and 07:30.
set -euo pipefail

DUMP_DIR="/var/backups/keycloak"
REMOTE_HOST="proxmox"
REMOTE_PATH="/var/lib/vz/dump/gateway"
DB_NAME="keycloak"
DB_USER="keycloak"
CONTAINER="keycloak-db"
RETENTION_DAYS=7
DATE=$(date '+%Y-%m-%d')
OUTFILE="$DUMP_DIR/keycloak-db-$DATE.sql.gz"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "Starting Keycloak PostgreSQL dump..."

mkdir -p "$DUMP_DIR"

# Dump via docker exec — no password needed (trust auth inside the container)
docker exec "$CONTAINER" pg_dump -U "$DB_USER" "$DB_NAME" | gzip > "$OUTFILE"

SIZE=$(du -sh "$OUTFILE" | cut -f1)
log "Dump complete: $OUTFILE ($SIZE)"

# Push to Proxmox so existing rclone jobs pick it up
ssh "$REMOTE_HOST" "mkdir -p $REMOTE_PATH"
scp "$OUTFILE" "$REMOTE_HOST:$REMOTE_PATH/"
log "Pushed to $REMOTE_HOST:$REMOTE_PATH/"

# Prune local dumps older than retention
find "$DUMP_DIR" -name "keycloak-db-*.sql.gz" -mtime "+$RETENTION_DAYS" -delete
log "Local retention cleanup done (>${RETENTION_DAYS}d)."

log "Done."
