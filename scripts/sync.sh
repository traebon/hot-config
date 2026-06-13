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

log "Syncing Gateway VPS configs..."

# CLAUDE.md (master infra context)
sync_file /root/hot/CLAUDE.md "$REPO/CLAUDE.md"

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

# ── Commit & push ────────────────────────────────────────────────────────────

$GIT add -A

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
