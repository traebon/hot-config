#!/bin/bash
# Fleet state backup — nightly backup of every genuinely irreplaceable piece of state across the
# whole fleet: databases and real user/business data that no config file or PBS image backup
# covers. Started 2026-09-06 as the direct answer to the PBS-offsite-bridge scoping
# (docs/HoT_PBS_Backup_Integration_Scope.md Section 8) for sn-monitor alone; widened the same day
# after auditing the rest of the fleet for the same class of gap and finding a genuinely critical
# one — Vaultwarden (every credential in this project) had zero backup coverage anywhere.
#
# Docker-compose files, Caddyfile, and other static config are covered separately by
# scripts/sync.sh (git, daily 01:00). Real mail content (Maildir) is covered by
# backup-gateway-vps.sh. This script is specifically for state that lives in a database or a real
# user-data directory that neither of those touch.
#
# Known gap, deliberately not covered here yet: Wazuh's indexer data (~228MB of real
# security-event history on sn-security) — needs a real OpenSearch snapshot/export mechanism to
# back up safely and consistently, not a raw file copy of a live index. Wazuh's *config*
# (rules/decoders/manager.conf) is covered via scripts/sync.sh already.
set -uo pipefail

DUMP_DIR="/var/backups/fleet-state"
RETENTION_DAYS=30
NTFY_URL="https://ntfy.house-of-trae.com"
NTFY_TOPIC="hot-alerts"
NTFY_TOKEN_FILE="/etc/apt-daily-update/ntfy_token"
DATE=$(date '+%Y-%m-%d')
FAILED=0
FAIL_DETAIL=""

mkdir -p "$DUMP_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

notify() {
  local priority="$1" title="$2" message="$3"
  [ -f "$NTFY_TOKEN_FILE" ] || return 0
  curl -fsS -m 10 -u ":$(cat "$NTFY_TOKEN_FILE")" \
    -H "X-Title: $title" -H "X-Priority: $priority" \
    -d "$message" "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1 || true
}

# host -> ssh alias, empty string means "local" (the Gateway itself) — same convention as
# fleet-health-sweep.sh.
run_remote() {
  local alias="$1" cmd="$2"
  if [ -z "$alias" ]; then
    bash -c "$cmd"
  else
    ssh -o ConnectTimeout=10 -o BatchMode=yes "$alias" "$cmd"
  fi
}

push() {
  # args: local_file  remote_subpath
  # Uses PIPESTATUS to check rclone's own exit code, not the logging while-loop's (which is
  # always 0) — a real bug caught and fixed 2026-09-06 during this script's own bring-up: the
  # first version always reported success regardless of whether rclone actually worked.
  local f="$1" sub="$2"
  local ok=0
  for REMOTE in hetzner-crypt b2-hot-crypt; do
    rclone listremotes 2>/dev/null | grep -q "^${REMOTE}:" || continue
    set +e
    rclone copy "$f" "${REMOTE}:fleet-state-backups/${sub}/" --no-traverse 2>&1 | while IFS= read -r l; do log "  rclone($REMOTE): $l"; done
    rc=${PIPESTATUS[0]}
    set -e
    if [ "$rc" -eq 0 ]; then
      ok=1
    else
      log "  rclone($REMOTE) FAILED with exit $rc"
    fi
  done
  if [ "$ok" -eq 0 ]; then
    FAILED=1
    FAIL_DETAIL+="$(basename "$f") "
  fi
}

# ── generic Postgres dump: pg_dump over (optional) SSH, gzip, push ──────────────────────────────
# args: label  ssh_alias  container  db_user  db_name  subpath
pg_backup() {
  local label="$1" alias="$2" container="$3" user="$4" db="$5" sub="$6"
  local out="$DUMP_DIR/${label}-$DATE.sql.gz"
  if run_remote "$alias" "docker exec $container pg_dump -U $user $db" 2>/tmp/"$label".err | gzip > "$out"; then
    if [ -s "$out" ]; then
      log "$label dump OK: $out ($(du -sh "$out" | cut -f1))"
      push "$out" "$sub"
    else
      log "$label dump empty — treating as failure. $(cat /tmp/"$label".err 2>/dev/null)"
      FAILED=1; FAIL_DETAIL+="${label}(empty) "
    fi
  else
    log "$label dump FAILED: $(cat /tmp/"$label".err 2>/dev/null)"
    FAILED=1; FAIL_DETAIL+="${label}(dump) "
  fi
  rm -f /tmp/"$label".err
}

log "=== fleet state backup START ==="

# ── sn-monitor: Grafana Postgres DB ──────────────────────────────────────────
pg_backup "grafana-db" sn-monitor grafana-db grafana grafana "sn-monitor"

# ── sn-monitor: Uptime Kuma SQLite DB ────────────────────────────────────────
# Online backup via a throwaway alpine+sqlite container (not a raw cp) — kuma.db runs in WAL
# mode under active writes, and sqlite3's own .backup command is the only way to get a
# guaranteed-consistent copy without stopping the container.
KUMA_OUT="$DUMP_DIR/uptime-kuma-$DATE.db.gz"
if ssh -o ConnectTimeout=10 -o BatchMode=yes sn-monitor \
    "docker run --rm -v /opt/monitoring/uptime-kuma:/data:ro alpine sh -c 'apk add --no-cache sqlite >/dev/null 2>&1 && sqlite3 /data/kuma.db \".backup /tmp/k.db\" && cat /tmp/k.db'" \
    2>/tmp/kuma-dump.err | gzip > "$KUMA_OUT"; then
  if [ -s "$KUMA_OUT" ]; then
    log "Uptime Kuma DB backup OK: $KUMA_OUT ($(du -sh "$KUMA_OUT" | cut -f1))"
    push "$KUMA_OUT" "sn-monitor"
  else
    log "Uptime Kuma DB backup empty — treating as failure. $(cat /tmp/kuma-dump.err 2>/dev/null)"
    FAILED=1; FAIL_DETAIL+="uptime-kuma(empty) "
  fi
else
  log "Uptime Kuma DB backup FAILED: $(cat /tmp/kuma-dump.err 2>/dev/null)"
  FAILED=1; FAIL_DETAIL+="uptime-kuma(dump) "
fi
rm -f /tmp/kuma-dump.err

# ── Gateway: Vaultwarden SQLite DB ───────────────────────────────────────────
# The single most critical piece in this whole backup -- every credential in this project lives
# here -- and had ZERO backup coverage anywhere until 2026-09-06 (sync.sh only ever tracked
# compose.yaml; backup-gateway-vps.sh's scope is Tor/PowerDNS/Mailserver only, never this).
# Local (no SSH -- Vaultwarden runs on the Gateway itself). Same online-backup approach as Uptime
# Kuma -- db.sqlite3 is a live database, not a static file.
VW_OUT="$DUMP_DIR/vaultwarden-db-$DATE.sqlite3.gz"
if docker run --rm -v vaultwarden_vaultwarden_data:/data:ro alpine sh -c \
    'apk add --no-cache sqlite >/dev/null 2>&1 && sqlite3 /data/db.sqlite3 ".backup /tmp/v.db" && cat /tmp/v.db' \
    2>/tmp/vaultwarden.err | gzip > "$VW_OUT"; then
  if [ -s "$VW_OUT" ]; then
    log "Vaultwarden DB backup OK: $VW_OUT ($(du -sh "$VW_OUT" | cut -f1))"
    push "$VW_OUT" "gateway"
  else
    log "Vaultwarden DB backup empty — treating as failure. $(cat /tmp/vaultwarden.err 2>/dev/null)"
    FAILED=1; FAIL_DETAIL+="vaultwarden(empty) "
  fi
else
  log "Vaultwarden DB backup FAILED: $(cat /tmp/vaultwarden.err 2>/dev/null)"
  FAILED=1; FAIL_DETAIL+="vaultwarden(dump) "
fi
rm -f /tmp/vaultwarden.err

# ── sn-infra: Forgejo (Postgres DB + real repo data) ─────────────────────────
pg_backup "forgejo-db" sn-infra forgejo-db forgejo forgejo "sn-infra"
FORGEJO_OUT="$DUMP_DIR/forgejo-data-$DATE.tar.gz"
if ssh -o ConnectTimeout=10 -o BatchMode=yes sn-infra \
    "docker exec forgejo tar -cf - -C /data ." 2>/tmp/forgejo-data.err | gzip > "$FORGEJO_OUT"; then
  if [ -s "$FORGEJO_OUT" ]; then
    log "Forgejo data tar OK: $FORGEJO_OUT ($(du -sh "$FORGEJO_OUT" | cut -f1))"
    push "$FORGEJO_OUT" "sn-infra"
  else
    log "Forgejo data tar empty — treating as failure. $(cat /tmp/forgejo-data.err 2>/dev/null)"
    FAILED=1; FAIL_DETAIL+="forgejo-data(empty) "
  fi
else
  log "Forgejo data tar FAILED: $(cat /tmp/forgejo-data.err 2>/dev/null)"
  FAILED=1; FAIL_DETAIL+="forgejo-data(tar) "
fi
rm -f /tmp/forgejo-data.err

# ── sn-infra: PowerDNS-Admin, hot-wiki, Namevault Postgres DBs ───────────────
pg_backup "pdns-admin-db" sn-infra pdns-admin-db pdnsadmin pdnsadmin "sn-infra"
pg_backup "hot-wiki-db" sn-infra hot-wiki-db wikijs wiki "sn-infra"
pg_backup "namevault-db" sn-infra namegen-db namegen namegen "sn-infra"

# ── hot-erp-nl: ERPNext (MariaDB + real uploaded-file volumes) ───────────────
ERP_DB_OUT="$DUMP_DIR/dickson-db-$DATE.sql.gz"
if ssh -o ConnectTimeout=10 -o BatchMode=yes hot-erp-nl \
    "docker exec dickson-db sh -c 'mariadb-dump -u root -p\$(cat /run/secrets/dickson_db_password) _ae77c090ad3ef28b'" \
    2>/tmp/dickson-db.err | gzip > "$ERP_DB_OUT"; then
  if [ -s "$ERP_DB_OUT" ]; then
    log "ERPNext DB dump OK: $ERP_DB_OUT ($(du -sh "$ERP_DB_OUT" | cut -f1))"
    push "$ERP_DB_OUT" "hot-erp-nl"
  else
    log "ERPNext DB dump empty — treating as failure. $(cat /tmp/dickson-db.err 2>/dev/null)"
    FAILED=1; FAIL_DETAIL+="dickson-db(empty) "
  fi
else
  log "ERPNext DB dump FAILED: $(cat /tmp/dickson-db.err 2>/dev/null)"
  FAILED=1; FAIL_DETAIL+="dickson-db(dump) "
fi
rm -f /tmp/dickson-db.err

ERP_FILES_OUT="$DUMP_DIR/dickson-files-$DATE.tar.gz"
if ssh -o ConnectTimeout=10 -o BatchMode=yes hot-erp-nl \
    "docker run --rm -v dickson_dickson-sites-data:/sites:ro -v dickson_dickson-assets-data:/assets:ro alpine tar -cf - -C / sites assets" \
    2>/tmp/dickson-files.err | gzip > "$ERP_FILES_OUT"; then
  if [ -s "$ERP_FILES_OUT" ]; then
    log "ERPNext files tar OK: $ERP_FILES_OUT ($(du -sh "$ERP_FILES_OUT" | cut -f1))"
    push "$ERP_FILES_OUT" "hot-erp-nl"
  else
    log "ERPNext files tar empty — treating as failure. $(cat /tmp/dickson-files.err 2>/dev/null)"
    FAILED=1; FAIL_DETAIL+="dickson-files(empty) "
  fi
else
  log "ERPNext files tar FAILED: $(cat /tmp/dickson-files.err 2>/dev/null)"
  FAILED=1; FAIL_DETAIL+="dickson-files(tar) "
fi
rm -f /tmp/dickson-files.err

# ── hot-pn: Nextcloud (Postgres DB + real 13GB user-data directory) ──────────
pg_backup "nextcloud-db" hot-pn nextcloud-db nextcloud nextcloud "hot-pn"
NEXTCLOUD_OUT="$DUMP_DIR/nextcloud-data-$DATE.tar.gz"
log "Streaming Nextcloud's real data directory (~13GB) -- this is the largest single piece, may take several minutes..."
if ssh -o ConnectTimeout=10 -o BatchMode=yes hot-pn \
    "docker exec nextcloud tar -cf - -C /var/www/html data" 2>/tmp/nextcloud-data.err | gzip > "$NEXTCLOUD_OUT"; then
  if [ -s "$NEXTCLOUD_OUT" ]; then
    log "Nextcloud data tar OK: $NEXTCLOUD_OUT ($(du -sh "$NEXTCLOUD_OUT" | cut -f1))"
    push "$NEXTCLOUD_OUT" "hot-pn"
  else
    log "Nextcloud data tar empty — treating as failure. $(cat /tmp/nextcloud-data.err 2>/dev/null)"
    FAILED=1; FAIL_DETAIL+="nextcloud-data(empty) "
  fi
else
  log "Nextcloud data tar FAILED: $(cat /tmp/nextcloud-data.err 2>/dev/null)"
  FAILED=1; FAIL_DETAIL+="nextcloud-data(tar) "
fi
rm -f /tmp/nextcloud-data.err

# ── sn-security: Wazuh indexer (OpenSearch) snapshot ─────────────────────────
# Added 2026-09-08, closing the last flagged gap in this script: Wazuh's security-event history
# had no application-consistent backup anywhere, only whatever crash-consistent state happened to
# be on disk during the nightly whole-VM vzdump backup to pbs-hot. A raw copy of live Lucene
# segment files risks an inconsistent, untested-restorable copy -- OpenSearch's own snapshot API
# (registered against a filesystem repo, path.repo added to opensearch.yml 2026-09-08) is the
# correct mechanism, same reasoning as pg_dump/sqlite3 .backup for every other database above.
# `partial: true` is deliberate -- a handful of old, empty, pre-existing indices with genuinely
# unallocated shards (found during this build, unrelated to it) would otherwise fail the whole
# snapshot; partial mode captures everything healthy and marks the rest, rather than an all-or-
# nothing failure over data that was already gone. See docs/HoT_PBS_Backup_Integration_Scope.md
# Section 11.
# Real timeout finding, 2026-09-08: a genuine full snapshot took 106s in isolated testing, and
# longer under real concurrent load the same night (this script's own earlier steps were still
# competing for Gateway RAM/swap at the time) -- an initial 60s curl timeout was nowhere near
# enough and caused a silent, hard-to-diagnose script failure (exit 28, zero log output from this
# block at all) the first time this ran for real. 900s gives real headroom.
WAZUH_SNAP_REPO="hot_backup_repo"
WAZUH_SNAP_NAME="wazuh-$(date '+%Y-%m-%d')"
WAZUH_INDEXER_PW="$(run_remote sn-security "grep '^WAZUH_INDEXER_PASSWORD=' /opt/stacks/wazuh/.env | cut -d= -f2" 2>/dev/null)"

if [ -z "$WAZUH_INDEXER_PW" ]; then
  log "Wazuh indexer snapshot FAILED: could not read WAZUH_INDEXER_PASSWORD from sn-security"
  FAILED=1; FAIL_DETAIL+="wazuh-indexer(no-password) "
else
  # Idempotency check, added 2026-09-08: OpenSearch keeps a snapshot running server-side even if
  # the client curl connection dies first (a real timeout misconfiguration caused exactly this the
  # first time this ran for real -- the script logged a false failure while the actual snapshot
  # completed 144/144 on the server). Checking for an existing SUCCESS/PARTIAL snapshot under
  # today's name first makes a retry (manual or from a prior partial run) safe instead of hitting
  # invalid_snapshot_name_exception on the already-completed snapshot.
  EXISTING="$(run_remote sn-security "curl -sk -m 15 -u admin:$WAZUH_INDEXER_PW https://localhost:9200/_snapshot/$WAZUH_SNAP_REPO/$WAZUH_SNAP_NAME" 2>/dev/null)"
  if echo "$EXISTING" | grep -qE '"state":"(SUCCESS|PARTIAL)"'; then
    SNAP_RESULT="$EXISTING"
    log "Wazuh indexer snapshot $WAZUH_SNAP_NAME already exists and succeeded (prior run's server-side result) -- skipping re-creation"
  else
    SNAP_RESULT="$(run_remote sn-security "curl -sk -m 900 -u admin:$WAZUH_INDEXER_PW -X PUT https://localhost:9200/_snapshot/$WAZUH_SNAP_REPO/$WAZUH_SNAP_NAME?wait_for_completion=true -H 'Content-Type: application/json' -d '{\"indices\":\"*\",\"ignore_unavailable\":true,\"include_global_state\":false,\"partial\":true}'" 2>/tmp/wazuh-snap.err)"
  fi
  if echo "$SNAP_RESULT" | grep -qE '"state":"(SUCCESS|PARTIAL)"'; then
    log "Wazuh indexer snapshot OK: $WAZUH_SNAP_NAME ($(echo "$SNAP_RESULT" | grep -o '"state":"[A-Z]*"'))"

    # prune snapshots older than 14 days -- the repo dedups internally at the segment level, so
    # retention here keeps the nightly tar-and-push below bounded rather than growing forever
    OLD_SNAPS="$(run_remote sn-security "curl -sk -m 30 -u admin:$WAZUH_INDEXER_PW https://localhost:9200/_snapshot/$WAZUH_SNAP_REPO/_all" 2>/dev/null | python3 -c "
import json,sys
from datetime import datetime, timedelta
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
cutoff = datetime.utcnow() - timedelta(days=14)
for s in data.get('snapshots', []):
    name = s.get('snapshot', '')
    if name.startswith('wazuh-') and not name.startswith('wazuh-test'):
        try:
            dt = datetime.strptime(name[len('wazuh-'):], '%Y-%m-%d')
            if dt < cutoff:
                print(name)
        except ValueError:
            pass
" 2>/dev/null)"
    while read -r old; do
      [ -n "$old" ] && run_remote sn-security "curl -sk -m 30 -u admin:$WAZUH_INDEXER_PW -X DELETE https://localhost:9200/_snapshot/$WAZUH_SNAP_REPO/$old" >/dev/null 2>&1
    done <<< "$OLD_SNAPS"

    WAZUH_SNAP_OUT="$DUMP_DIR/wazuh-indexer-snapshot-$DATE.tar.gz"
    if ssh -o ConnectTimeout=10 -o BatchMode=yes sn-security \
        "tar -cf - -C /opt/stacks/wazuh/snapshots ." 2>/tmp/wazuh-snap-tar.err | gzip > "$WAZUH_SNAP_OUT"; then
      if [ -s "$WAZUH_SNAP_OUT" ]; then
        log "Wazuh indexer snapshot tar OK: $WAZUH_SNAP_OUT ($(du -sh "$WAZUH_SNAP_OUT" | cut -f1))"
        push "$WAZUH_SNAP_OUT" "sn-security"
      else
        log "Wazuh indexer snapshot tar empty — treating as failure. $(cat /tmp/wazuh-snap-tar.err 2>/dev/null)"
        FAILED=1; FAIL_DETAIL+="wazuh-indexer(empty) "
      fi
    else
      log "Wazuh indexer snapshot tar FAILED: $(cat /tmp/wazuh-snap-tar.err 2>/dev/null)"
      FAILED=1; FAIL_DETAIL+="wazuh-indexer(tar) "
    fi
    rm -f /tmp/wazuh-snap-tar.err
  else
    log "Wazuh indexer snapshot FAILED or incomplete: $SNAP_RESULT $(cat /tmp/wazuh-snap.err 2>/dev/null)"
    FAILED=1; FAIL_DETAIL+="wazuh-indexer(snapshot) "
  fi
  rm -f /tmp/wazuh-snap.err
fi

# ── retention cleanup ─────────────────────────────────────────────────────────
find "$DUMP_DIR" -type f -mtime "+${RETENTION_DAYS}" -delete
for REMOTE in hetzner-crypt b2-hot-crypt; do
  rclone listremotes 2>/dev/null | grep -q "^${REMOTE}:" || continue
  rclone delete "${REMOTE}:fleet-state-backups/" --min-age "${RETENTION_DAYS}d" 2>&1 | while IFS= read -r l; do log "  prune $REMOTE: $l"; done
done

if [ "$FAILED" -eq 1 ]; then
  notify high "fleet-state-backup: failure" "One or more state backups failed: ${FAIL_DETAIL}. Check /var/log/fleet-state-backup.log on the Gateway."
fi

log "=== fleet state backup DONE (failed=${FAILED}) ==="
