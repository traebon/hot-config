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

# ── Register a completed backup into PN's own service_backups table ─────────────────────────────
# So PN's own Governance/Recovery views reflect reality instead of showing "Backup Policy: Daily"
# right next to "never backed up" — found 2026-09-10 while investigating Mr. Byrne's "health checks
# and backup jobs still need updating and fixing" report: the real backup mechanisms all genuinely
# run (that's what backup_policy=daily was correctly asserting), but nothing outside PN's own
# pg_dump.sh (privatenexus-db only) ever told PN about it — 32 of 33 'daily'-labeled services had
# zero rows in service_backups. Same exact pattern pg_dump.sh already uses (direct psql INSERT, run
# where the DB actually lives — hot-pn — not through the app's session-gated API, since this script
# runs unattended with no session to hold). Failure here is logged but never fails the backup
# itself — the real backup already succeeded by the time this runs, this is just telling PN about
# it after the fact.
# args: service_id  label  location  size_bytes
register_backup() {
  local service_id="$1" label="$2" location="$3" size_bytes="$4"
  [ -z "$service_id" ] && return 0
  local esc_label esc_location
  esc_label="$(printf '%s' "$label" | sed "s/'/''/g")"
  esc_location="$(printf '%s' "$location" | sed "s/'/''/g")"
  local sql="INSERT INTO service_backups (tenant_id, service_id, label, backup_type, trust_state, location, size_bytes, notes) VALUES ('10000000-0000-0000-0000-000000000001', '${service_id}', '${esc_label}', 'full', 'trusted', '${esc_location}', ${size_bytes:-NULL}, 'Registered by fleet-state-backup.sh (Gateway) -- same pattern pg_dump.sh uses for privatenexus-db.');"
  if ! ssh -o ConnectTimeout=10 -o BatchMode=yes hot-pn \
      "docker exec -i privatenexus-db psql -U privatenexus -d privatenexus -v ON_ERROR_STOP=1 -c \"$sql\"" \
      >/tmp/register_backup.err 2>&1; then
    log "  register_backup FAILED for service_id=$service_id (non-fatal — the backup itself already succeeded): $(cat /tmp/register_backup.err 2>/dev/null)"
  fi
  rm -f /tmp/register_backup.err
}

# ── generic Postgres dump: pg_dump over (optional) SSH, gzip, push ──────────────────────────────
# args: label  ssh_alias  container  db_user  db_name  subpath  [service_id]
pg_backup() {
  local label="$1" alias="$2" container="$3" user="$4" db="$5" sub="$6" service_id="${7:-}"
  local out="$DUMP_DIR/${label}-$DATE.sql.gz"
  if run_remote "$alias" "docker exec $container pg_dump -U $user $db" 2>/tmp/"$label".err | gzip > "$out"; then
    if [ -s "$out" ]; then
      log "$label dump OK: $out ($(du -sh "$out" | cut -f1))"
      push "$out" "$sub"
      register_backup "$service_id" "Automated fleet-state-backup — ${label} ${DATE}" "fleet-state-backups:${sub}/$(basename "$out")" "$(stat -c%s "$out" 2>/dev/null)"
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
pg_backup "grafana-db" sn-monitor grafana-db grafana grafana "sn-monitor" "75cc2f58-61c6-4252-9fc2-bad362a050ca"

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
    register_backup "38216cea-f752-4c11-a1aa-5dfd4a27f696" "Automated fleet-state-backup — uptime-kuma ${DATE}" "fleet-state-backups:sn-monitor/$(basename "$KUMA_OUT")" "$(stat -c%s "$KUMA_OUT" 2>/dev/null)"
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
    register_backup "1845174e-bdb3-4920-bdd7-0ed29d91207f" "Automated fleet-state-backup — vaultwarden-db ${DATE}" "fleet-state-backups:gateway/$(basename "$VW_OUT")" "$(stat -c%s "$VW_OUT" 2>/dev/null)"
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
pg_backup "forgejo-db" sn-infra forgejo-db forgejo forgejo "sn-infra" "d04dfe22-503a-4210-a70e-b8aeb323d546"
FORGEJO_OUT="$DUMP_DIR/forgejo-data-$DATE.tar.gz"
if ssh -o ConnectTimeout=10 -o BatchMode=yes sn-infra \
    "docker exec forgejo tar -cf - -C /data ." 2>/tmp/forgejo-data.err | gzip > "$FORGEJO_OUT"; then
  if [ -s "$FORGEJO_OUT" ]; then
    log "Forgejo data tar OK: $FORGEJO_OUT ($(du -sh "$FORGEJO_OUT" | cut -f1))"
    push "$FORGEJO_OUT" "sn-infra"
    register_backup "b8e89522-88e4-4eea-bd36-1755a4fbd917" "Automated fleet-state-backup — forgejo-data ${DATE}" "fleet-state-backups:sn-infra/$(basename "$FORGEJO_OUT")" "$(stat -c%s "$FORGEJO_OUT" 2>/dev/null)"
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
pg_backup "pdns-admin-db" sn-infra pdns-admin-db pdnsadmin pdnsadmin "sn-infra" "dcfa2725-8bf4-44f7-90dc-b7f87b0ce10f"
pg_backup "hot-wiki-db" sn-infra hot-wiki-db wikijs wiki "sn-infra" "c1f16fc8-cbea-4757-bb65-95dea60fa4bf"
pg_backup "namevault-db" sn-infra namegen-db namegen namegen "sn-infra" "35131f43-a0b0-4942-87bf-cea50631d5c4"

# ── hot-erp-nl: ERPNext (MariaDB + real uploaded-file volumes) ───────────────
ERP_DB_OUT="$DUMP_DIR/dickson-db-$DATE.sql.gz"
if ssh -o ConnectTimeout=10 -o BatchMode=yes hot-erp-nl \
    "docker exec dickson-db sh -c 'mariadb-dump -u root -p\$(cat /run/secrets/dickson_db_password) _ae77c090ad3ef28b'" \
    2>/tmp/dickson-db.err | gzip > "$ERP_DB_OUT"; then
  if [ -s "$ERP_DB_OUT" ]; then
    log "ERPNext DB dump OK: $ERP_DB_OUT ($(du -sh "$ERP_DB_OUT" | cut -f1))"
    push "$ERP_DB_OUT" "hot-erp-nl"
    register_backup "9fa5d495-1e3c-4f69-8b43-4e9787eedf3c" "Automated fleet-state-backup — dickson-db ${DATE}" "fleet-state-backups:hot-erp-nl/$(basename "$ERP_DB_OUT")" "$(stat -c%s "$ERP_DB_OUT" 2>/dev/null)"
    # Also registered against dickson-backend -- the row with ERPNext's real public access_url,
    # what Mr. Byrne actually looks at, not the DB sidecar row.
    register_backup "0d84e024-b19c-43f6-9893-22fdaa67343f" "Automated fleet-state-backup — dickson-db ${DATE}" "fleet-state-backups:hot-erp-nl/$(basename "$ERP_DB_OUT")" "$(stat -c%s "$ERP_DB_OUT" 2>/dev/null)"
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
    register_backup "0d84e024-b19c-43f6-9893-22fdaa67343f" "Automated fleet-state-backup — dickson-files ${DATE}" "fleet-state-backups:hot-erp-nl/$(basename "$ERP_FILES_OUT")" "$(stat -c%s "$ERP_FILES_OUT" 2>/dev/null)"
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
pg_backup "nextcloud-db" hot-pn nextcloud-db nextcloud nextcloud "hot-pn" "2b97cd5c-0e0e-4322-8d60-df1597c7f922"
NEXTCLOUD_OUT="$DUMP_DIR/nextcloud-data-$DATE.tar.gz"
log "Streaming Nextcloud's real data directory (~13GB) -- this is the largest single piece, may take several minutes..."
if ssh -o ConnectTimeout=10 -o BatchMode=yes hot-pn \
    "docker exec nextcloud tar -cf - -C /var/www/html data" 2>/tmp/nextcloud-data.err | gzip > "$NEXTCLOUD_OUT"; then
  if [ -s "$NEXTCLOUD_OUT" ]; then
    log "Nextcloud data tar OK: $NEXTCLOUD_OUT ($(du -sh "$NEXTCLOUD_OUT" | cut -f1))"
    push "$NEXTCLOUD_OUT" "hot-pn"
    # Also register against the parent app row -- nextcloud-data (not nextcloud-db) is the size
    # that matters for readiness/RTO on the row Mr. Byrne actually looks at in the UI.
    register_backup "3c4b8f16-dbd7-449d-814d-8bebfd3f9248" "Automated fleet-state-backup — nextcloud-data ${DATE}" "fleet-state-backups:hot-pn/$(basename "$NEXTCLOUD_OUT")" "$(stat -c%s "$NEXTCLOUD_OUT" 2>/dev/null)"
  else
    log "Nextcloud data tar empty — treating as failure. $(cat /tmp/nextcloud-data.err 2>/dev/null)"
    FAILED=1; FAIL_DETAIL+="nextcloud-data(empty) "
  fi
else
  log "Nextcloud data tar FAILED: $(cat /tmp/nextcloud-data.err 2>/dev/null)"
  FAILED=1; FAIL_DETAIL+="nextcloud-data(tar) "
fi
rm -f /tmp/nextcloud-data.err

# ── hot-pn: Immich (Postgres DB + real photo/video library) ─────────────────
# Added 2026-09-09, deployed via the Catalogue flow same day as the Nextcloud/Notesnook domain
# consolidation under privatenexus.net -- see claude-md/services-hotpn.md and network.md. Same
# treatment as Nextcloud above (container-side tar -> gzip, no local disk use on either end).
pg_backup "immich-db" hot-pn immich-db immich immich "hot-pn" "01e867df-446d-47b7-ac5c-25659bc7dff0"
IMMICH_OUT="$DUMP_DIR/immich-library-$DATE.tar.gz"
log "Streaming Immich's photo/video library -- size grows over time, may take a while..."
if ssh -o ConnectTimeout=10 -o BatchMode=yes hot-pn \
    "docker exec immich tar -cf - -C /data ." 2>/tmp/immich-library.err | gzip > "$IMMICH_OUT"; then
  if [ -s "$IMMICH_OUT" ]; then
    log "Immich library tar OK: $IMMICH_OUT ($(du -sh "$IMMICH_OUT" | cut -f1))"
    push "$IMMICH_OUT" "hot-pn"
    # Registered against the parent "immich" row (not immich-db) -- the library is what matters
    # for readiness/RTO on the row Mr. Byrne actually looks at.
    register_backup "6d0bed55-30c2-434c-88d7-5280163152d0" "Automated fleet-state-backup — immich-library ${DATE}" "fleet-state-backups:hot-pn/$(basename "$IMMICH_OUT")" "$(stat -c%s "$IMMICH_OUT" 2>/dev/null)"
  else
    log "Immich library tar empty — treating as failure. $(cat /tmp/immich-library.err 2>/dev/null)"
    FAILED=1; FAIL_DETAIL+="immich-library(empty) "
  fi
else
  log "Immich library tar FAILED: $(cat /tmp/immich-library.err 2>/dev/null)"
  FAILED=1; FAIL_DETAIL+="immich-library(tar) "
fi
rm -f /tmp/immich-library.err

# ── hot-pn: Notesnook (MongoDB + real S3 attachment store) ───────────────────
# Added 2026-09-10 -- found genuinely missing while investigating Mr. Byrne's report of wrong/blank
# service metadata in PN's Inventory: Notesnook was deployed 2026-08-10 and had ZERO
# application-consistent backup anywhere in this script, unlike Nextcloud/Immich (only
# pbs-host-backup.sh's broad nightly /opt tar would have caught it, a raw non-Mongo-aware copy of
# live WiredTiger files, not a real dump). mongodump against the live replica-set-mode Mongo
# (notesnook-db, real 544MB as of 2026-09-10 despite zero end-user adoption -- see
# personal_services_privatenexus_banner memory) inside the container, tarred, gzipped, pushed --
# same no-local-disk pattern as everything else here. MinIO's attachment store (notesnook-s3,
# 328KB as of this writing, essentially empty) included too for completeness even though there's
# nothing real in it yet.
NOTESNOOK_DB_OUT="$DUMP_DIR/notesnook-db-$DATE.archive.gz"
if ssh -o ConnectTimeout=10 -o BatchMode=yes hot-pn \
    "docker exec notesnook-db mongodump --archive" 2>/tmp/notesnook-db.err | gzip > "$NOTESNOOK_DB_OUT"; then
  if [ -s "$NOTESNOOK_DB_OUT" ]; then
    log "Notesnook DB dump OK: $NOTESNOOK_DB_OUT ($(du -sh "$NOTESNOOK_DB_OUT" | cut -f1))"
    push "$NOTESNOOK_DB_OUT" "hot-pn"
    register_backup "9a518a5d-a780-4019-a797-1b4190080db9" "Automated fleet-state-backup — notesnook-db ${DATE}" "fleet-state-backups:hot-pn/$(basename "$NOTESNOOK_DB_OUT")" "$(stat -c%s "$NOTESNOOK_DB_OUT" 2>/dev/null)"
    # Also registered against the parent "notesnook" row -- the actual note content lives in this
    # dump, not in notesnook-s3 (attachments only, currently near-empty).
    register_backup "184eb7a7-3503-4c0b-86d6-a360e327cb2c" "Automated fleet-state-backup — notesnook ${DATE}" "fleet-state-backups:hot-pn/$(basename "$NOTESNOOK_DB_OUT")" "$(stat -c%s "$NOTESNOOK_DB_OUT" 2>/dev/null)"
  else
    log "Notesnook DB dump empty — treating as failure. $(cat /tmp/notesnook-db.err 2>/dev/null)"
    FAILED=1; FAIL_DETAIL+="notesnook-db(empty) "
  fi
else
  log "Notesnook DB dump FAILED: $(cat /tmp/notesnook-db.err 2>/dev/null)"
  FAILED=1; FAIL_DETAIL+="notesnook-db(dump) "
fi
rm -f /tmp/notesnook-db.err

NOTESNOOK_S3_OUT="$DUMP_DIR/notesnook-s3-$DATE.tar.gz"
# Real bug found+fixed 2026-09-11 (first real production run of this block): `docker exec
# notesnook-s3 tar ...` always failed -- MinIO's image is minimal/scratch-based and has no `tar`,
# `which`, or `grep` binaries at all (confirmed live via `docker exec notesnook-s3 which tar` ->
# "executable file not found"). The failure was silent in practice because `[ -s "$OUT" ]` only
# checks the output file is non-empty, and gzip's own header+trailer for zero real input is itself
# a small non-empty file (~20-30 bytes) -- so this block had been reporting false "OK" (the
# "notesnook-s3-...-4.0K" size in earlier logs was disk block-size rounding on an essentially empty
# archive, not real content). Fixed two ways: (1) tar the host-side bind mount directly over SSH
# instead of going through the container at all (MinIO's data is a bind mount, not a named volume --
# `/opt/stacks/notesnook/s3-data` on hot-pn -- so no docker exec is even needed); (2) raised the
# emptiness threshold from "any non-zero size" to a real minimum, so a bare gzip header can never
# pass as success again.
if ssh -o ConnectTimeout=10 -o BatchMode=yes hot-pn \
    "tar -cf - -C /opt/stacks/notesnook/s3-data ." 2>/tmp/notesnook-s3.err | gzip > "$NOTESNOOK_S3_OUT"; then
  if [ -s "$NOTESNOOK_S3_OUT" ] && [ "$(stat -c%s "$NOTESNOOK_S3_OUT" 2>/dev/null || echo 0)" -gt 100 ]; then
    log "Notesnook S3 tar OK: $NOTESNOOK_S3_OUT ($(du -sh "$NOTESNOOK_S3_OUT" | cut -f1))"
    push "$NOTESNOOK_S3_OUT" "hot-pn"
    register_backup "34b80515-e6ec-4e92-b0bc-7d859832c805" "Automated fleet-state-backup — notesnook-s3 ${DATE}" "fleet-state-backups:hot-pn/$(basename "$NOTESNOOK_S3_OUT")" "$(stat -c%s "$NOTESNOOK_S3_OUT" 2>/dev/null)"
  else
    log "Notesnook S3 tar empty — treating as failure. $(cat /tmp/notesnook-s3.err 2>/dev/null)"
    FAILED=1; FAIL_DETAIL+="notesnook-s3(empty) "
  fi
else
  log "Notesnook S3 tar FAILED: $(cat /tmp/notesnook-s3.err 2>/dev/null)"
  FAILED=1; FAIL_DETAIL+="notesnook-s3(tar) "
fi
rm -f /tmp/notesnook-s3.err

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
        register_backup "9660b974-bdb7-46ac-ad8f-73c9dc21b049" "Automated fleet-state-backup — wazuh-indexer-snapshot ${DATE}" "fleet-state-backups:sn-security/$(basename "$WAZUH_SNAP_OUT")" "$(stat -c%s "$WAZUH_SNAP_OUT" 2>/dev/null)"
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
