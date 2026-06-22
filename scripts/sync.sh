#!/bin/bash
# Hot-config nightly sync — copies Gateway VPS stack configs into the repo,
# then commits and pushes to Forgejo if anything changed.
set -euo pipefail

REPO="/opt/hot-config"
STACKS="/opt/stacks"
GIT="git -C $REPO"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ── Sync Gateway VPS configs ────────────────────────────────────────────────

sync_file() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
}

sync_remote() {
  local vm="$1" src="$2" dst="$3"
  mkdir -p "$(dirname "$dst")"
  ssh "$vm" "cat $src" > "$dst" 2>/dev/null || log "WARN: could not sync $vm:$src"
}

log "Syncing Gateway VPS configs..."

# CLAUDE.md (master infra context)
sync_file /root/hot/CLAUDE.md "$REPO/CLAUDE.md"

# Infrastructure roadmap (master state & roadmap — DOCX)
sync_file /root/hot/docs/HoT_Infrastructure_State_Roadmap_v3_3.docx "$REPO/docs/HoT_Infrastructure_State_Roadmap_v3_3.docx"

# Caddy
sync_file "$STACKS/caddy/Caddyfile"      "$REPO/gateway/caddy/Caddyfile"
sync_file "$STACKS/caddy/compose.yml"    "$REPO/gateway/caddy/compose.yml"

# PowerDNS
sync_file "$STACKS/powerdns/compose.yml"          "$REPO/gateway/powerdns/compose.yml"
sync_file "$STACKS/powerdns/pdns.conf.template"   "$REPO/gateway/powerdns/pdns.conf.template"
sync_file "$STACKS/powerdns/entrypoint.sh"        "$REPO/gateway/powerdns/entrypoint.sh"

# Stalwart (mail)
sync_file "$STACKS/stalwart/compose.yaml"  "$REPO/gateway/stalwart/compose.yaml"
sync_file "$STACKS/stalwart/entrypoint.sh" "$REPO/gateway/stalwart/entrypoint.sh"

# Unbound
sync_file "$STACKS/unbound/compose.yml"  "$REPO/gateway/unbound/compose.yml"
sync_file "$STACKS/unbound/unbound.conf" "$REPO/gateway/unbound/unbound.conf"

# Keycloak
sync_file "$STACKS/keycloak/compose.yaml" "$REPO/gateway/keycloak/compose.yaml"

# Mailserver
sync_file "$STACKS/mailserver/compose.yaml" "$REPO/gateway/mailserver/compose.yaml"

# Roundcube
sync_file "$STACKS/roundcube/compose.yaml" "$REPO/gateway/roundcube/compose.yaml"

# CrowdSec
sync_file "$STACKS/crowdsec/compose.yaml" "$REPO/gateway/crowdsec/compose.yaml"

# Promtail
sync_file "$STACKS/promtail/docker-compose.yml"   "$REPO/gateway/promtail/docker-compose.yml"
sync_file "$STACKS/promtail/promtail-config.yml"  "$REPO/gateway/promtail/promtail-config.yml"

# Watchtower
sync_file "$STACKS/watchtower/docker-compose.yml" "$REPO/gateway/watchtower/docker-compose.yml"

# ── Sync sn-monitor configs (via SSH) ────────────────────────────────────────

log "Syncing sn-monitor configs..."
sync_remote sn-monitor /opt/stacks/monitoring/docker-compose.yml         "$REPO/sn-monitor/monitoring/docker-compose.yml"
sync_remote sn-monitor /opt/monitoring/prometheus/config/prometheus.yml  "$REPO/sn-monitor/monitoring/prometheus.yml"

# ── Sync sn-infra configs (via SSH) ──────────────────────────────────────────

log "Syncing sn-infra configs..."
sync_remote sn-infra /opt/stacks/pdns-admin/docker-compose.yml  "$REPO/sn-infra/pdns-admin/docker-compose.yml"
sync_remote sn-infra /opt/stacks/namegen/docker-compose.yml     "$REPO/sn-infra/namegen/docker-compose.yml"
sync_remote sn-infra /opt/stacks/forgejo/docker-compose.yml     "$REPO/sn-infra/forgejo/docker-compose.yml"

# ── Sync sn-web configs (via SSH) ────────────────────────────────────────────

log "Syncing sn-web configs..."
sync_remote sn-web /opt/stacks/stratus-digital/docker-compose.yml "$REPO/sn-web/stratus-digital/docker-compose.yml"
sync_remote sn-web /opt/stacks/discreet-elite/docker-compose.yml  "$REPO/sn-web/discreet-elite/docker-compose.yml"
sync_remote sn-web /opt/stacks/emerald-markets/docker-compose.yml "$REPO/sn-web/emerald-markets/docker-compose.yml"
sync_remote sn-web /opt/stacks/ruby/docker-compose.yml            "$REPO/sn-web/ruby/docker-compose.yml"
sync_remote sn-web /opt/stacks/evilrabbit/docker-compose.yml      "$REPO/sn-web/evilrabbit/docker-compose.yml"
sync_remote sn-web /opt/stacks/dicksonweb/docker-compose.yml      "$REPO/sn-web/dicksonweb/docker-compose.yml"

# ── Sync sn-business configs (via SSH) ───────────────────────────────────────

log "Syncing sn-business configs..."
sync_remote sn-business /opt/stacks/dickson/docker-compose.yml "$REPO/sn-business/dickson/docker-compose.yml"

# ── Sync Tor hidden service configs ──────────────────────────────────────────
# data/ is intentionally excluded — private keys must NEVER go to git

log "Syncing Tor configs..."
sync_file "$STACKS/tor/docker-compose.yml" "$REPO/gateway/tor/docker-compose.yml"
sync_file "$STACKS/tor/Dockerfile"         "$REPO/gateway/tor/Dockerfile"
sync_file "$STACKS/tor/torrc"              "$REPO/gateway/tor/torrc"

# ── Sync sn-security configs (via SSH) ───────────────────────────────────────

log "Syncing sn-security configs..."
sync_remote sn-security /opt/stacks/forgejo-runner/docker-compose.yml "$REPO/sn-security/forgejo-runner/docker-compose.yml"
sync_remote sn-security /opt/stacks/forgejo-runner/config.yaml        "$REPO/sn-security/forgejo-runner/config.yaml"
sync_remote sn-security /opt/stacks/forgejo-runner/entrypoint.sh      "$REPO/sn-security/forgejo-runner/entrypoint.sh"

# ── Secret-leak guard ─────────────────────────────────────────────────────────
# Synced compose files must use *_FILE / *__FILE Docker-secret indirection only.
# Abort the sync rather than push a plaintext credential to public mirrors.

log "Scanning staged changes for plaintext secrets..."
$GIT add -A
LEAK=$($GIT diff --cached -U0 -- '*.yml' '*.yaml' | grep -E '^\+' | grep -iE '(PASSWORD|SECRET|_KEY|_TOKEN)\s*:\s*"[^"]+"' | grep -viE '_FILE\s*:|__FILE\s*:' || true)
if [ -n "$LEAK" ]; then
  log "ABORT: plaintext secret detected in staged changes — not committing or pushing."
  echo "$LEAK" | sed 's/^/  /'
  $GIT reset >/dev/null
  exit 1
fi

if $GIT diff --cached --quiet; then
  log "No changes — nothing to commit."
  exit 0
fi

CHANGED=$($GIT diff --cached --name-only | wc -l | tr -d ' ')
log "Committing $CHANGED changed file(s)..."

$GIT commit -m "chore: nightly config sync $(date '+%Y-%m-%d %H:%M')"

$GIT push origin main
$GIT push github main
$GIT push codeberg main

log "Push complete."
