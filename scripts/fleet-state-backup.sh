#!/bin/bash
# Fleet state backup — nightly small-state backups for VM 102/104/106 (sn-web/sn-monitor/
# sn-security), added 2026-09-06 as the direct answer to the PBS-offsite-bridge scoping
# (docs/HoT_PBS_Backup_Integration_Scope.md Section 8): rather than needing a full 250GB VM
# image to cross PBS's slow home-network upload link (~1.5-2 MiB/s, measured live — 47+ hours
# for one VM), this backs up only the genuinely irreplaceable state on each — small enough to
# push directly via the same proven rclone-crypt pipeline Keycloak/PrivateNexus's DB backups
# already use, no PBS/home-network dependency at all. Docker-compose files and static configs
# for these VMs are covered separately by scripts/sync.sh (git, daily 01:00) — this script is
# specifically for *runtime state* that lives in a database or data directory, not a config
# file: Grafana's dashboards/alert-rules/datasources, and Uptime Kuma's monitor definitions.
#
# Known gap, deliberately not covered here yet: Wazuh's indexer data (~228MB of actual
# security-event history on sn-security) — needs a real OpenSearch snapshot/export mechanism to
# back up safely and consistently, not a raw file copy of a live index. Wazuh's *config*
# (rules/decoders/manager.conf) is covered via scripts/sync.sh already. Follow-up, not blocking.
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

log "=== fleet state backup START ==="

# ── sn-monitor: Grafana Postgres DB ──────────────────────────────────────────
GRAFANA_OUT="$DUMP_DIR/grafana-db-$DATE.sql.gz"
if ssh -o ConnectTimeout=10 -o BatchMode=yes sn-monitor \
    "docker exec grafana-db pg_dump -U grafana grafana" 2>/tmp/grafana-dump.err | gzip > "$GRAFANA_OUT"; then
  if [ -s "$GRAFANA_OUT" ]; then
    log "Grafana DB dump OK: $GRAFANA_OUT ($(du -sh "$GRAFANA_OUT" | cut -f1))"
    push "$GRAFANA_OUT" "sn-monitor"
  else
    log "Grafana DB dump empty — treating as failure. $(cat /tmp/grafana-dump.err 2>/dev/null)"
    FAILED=1; FAIL_DETAIL+="grafana-db(empty) "
  fi
else
  log "Grafana DB dump FAILED: $(cat /tmp/grafana-dump.err 2>/dev/null)"
  FAILED=1; FAIL_DETAIL+="grafana-db(dump) "
fi
rm -f /tmp/grafana-dump.err

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
