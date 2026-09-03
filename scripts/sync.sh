#!/bin/bash
# Hot-config nightly sync — copies Gateway VPS stack configs into the repo,
# then commits and pushes to Forgejo if anything changed.
set -euo pipefail

REPO="/opt/hot-config"
STACKS="/opt/stacks"
GIT="git -C $REPO"

# Self-check alerting — added 2026-08-23 after a fleet-wide sweep found this script had been
# silently failing (dead sn-business host, a renamed sn-infra path) for weeks with nothing but an
# unread WARN line in a log file. Every failure mode below now reaches Ntfy instead of relying on
# someone noticing. Reuses the same shared Gateway Ntfy token every other script here uses
# (apt-daily-update, reboot-recovery-watchdog, fleet-health-sweep).
NTFY_URL="https://ntfy.house-of-trae.com"
NTFY_TOPIC="hot-alerts"
NTFY_TOKEN_FILE="/etc/apt-daily-update/ntfy_token"
WARNINGS=()

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

notify() {
  local priority="$1" title="$2" message="$3"
  [ -f "$NTFY_TOKEN_FILE" ] || return 0
  curl -fsS -m 10 -u ":$(cat "$NTFY_TOKEN_FILE")" \
    -H "X-Title: $title" -H "X-Priority: $priority" \
    -d "$message" "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1 || true
}

# Call before any exit path (including the early "nothing to commit" one) so a sync_remote
# failure never gets silently absorbed just because no *doc* changes happened to trigger a commit.
alert_if_warnings() {
  if [ ${#WARNINGS[@]} -gt 0 ]; then
    notify high "hot-config sync: ${#WARNINGS[@]} issue(s)" "$(printf '%s\n' "${WARNINGS[@]}")"
  fi
}

# ── Sync Gateway VPS configs ────────────────────────────────────────────────

sync_file() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
}

sync_remote() {
  local vm="$1" src="$2" dst="$3"
  local tmp
  tmp=$(mktemp)
  mkdir -p "$(dirname "$dst")"
  if ssh -o ConnectTimeout=10 -o BatchMode=yes "$vm" "cat $src" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$dst"
  else
    log "WARN: could not sync $vm:$src — leaving $dst untouched"
    WARNINGS+=("could not sync $vm:$src")
    rm -f "$tmp"
  fi
}

log "Syncing Gateway VPS configs..."

# CLAUDE.md (master infra context)
sync_file /root/hot/CLAUDE.md "$REPO/CLAUDE.md"

# claude-md/ topic files — CLAUDE.md was split 2026-08-16 (streamlining track 2) into per-topic
# imports (@claude-md/network.md etc.). This block was never added at split time, so every one of
# those files — i.e. essentially all of CLAUDE.md's real content — had been silently absent from
# the git mirror ever since; only the top-level shell file that imports them was ever backed up.
# Found+fixed 2026-08-23 while chasing an unrelated sync warning.
mkdir -p "$REPO/claude-md"
for f in /root/hot/claude-md/*.md; do
  [ -e "$f" ] || continue
  sync_file "$f" "$REPO/claude-md/$(basename "$f")"
done

# Infrastructure roadmap (master state & roadmap — DOCX, version-agnostic)
# Picks the highest-versioned roadmap docx and drops any older tracked copy,
# so version bumps (v3.3 -> v3.4 -> ...) are followed automatically.
ROADMAP_SRC=$(ls -1 /root/hot/docs/HoT_Infrastructure_State_Roadmap_v*.docx 2>/dev/null | sort -V | tail -1 || true)
if [ -n "$ROADMAP_SRC" ]; then
  mkdir -p "$REPO/docs"
  rm -f "$REPO"/docs/HoT_Infrastructure_State_Roadmap_v*.docx
  cp "$ROADMAP_SRC" "$REPO/docs/$(basename "$ROADMAP_SRC")"
else
  log "WARN: no infrastructure roadmap docx found to sync"
fi

# All other reference docs (.md/.pdf/.docx) — mirror everything except the
# versioned roadmap above, which has its own "keep only the latest" handling.
# Without this, docs added under /root/hot/docs/ (PRDs, design docs, runbooks,
# checklists...) silently never reach git and are lost if the Gateway VPS disk is.
log "Syncing remaining docs..."
mkdir -p "$REPO/docs"
for f in /root/hot/docs/*.md /root/hot/docs/*.pdf /root/hot/docs/*.docx; do
  [ -e "$f" ] || continue
  case "$(basename "$f")" in
    HoT_Infrastructure_State_Roadmap_v*.docx) continue ;;
  esac
  sync_file "$f" "$REPO/docs/$(basename "$f")"
done

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
sync_file "$STACKS/keycloak/compose.yaml"                        "$REPO/gateway/keycloak/compose.yaml"

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

# Vaultwarden, oauth2-proxy, Gatus, Ntfy, sms-relay, Dockge — found 2026-08-23 during a full
# fleet sync sweep: none of these were ever wired into the recurring sync, only ever hand-copied
# once. oauth2-proxy/Gatus/Ntfy happened to still match live by luck; Vaultwarden and sms-relay
# had genuinely drifted — sms-relay's tracked copy was frozen at the pre-fix 2026-08-03 state,
# the exact broken FROM/TO Twilio config from the 2026-08-04 incident (SMS_TO_NUMBER pointing at
# the sender number, SMS_FROM_NUMBER a literal "REPLACE_ME" placeholder) — a restore from this
# repo would have silently reintroduced an already-fixed bug. Dockge had zero backup coverage at
# all. `gatus/config.yaml`'s only "secret-looking" line is `${GATUS_SMTP_PASSWORD}` (env-var
# indirection, not a literal value) — safe for the leak-guard and for git, matching the
# `secrets/gatus.env` split already documented in CLAUDE.md.
sync_file "$STACKS/vaultwarden/compose.yaml"   "$REPO/gateway/vaultwarden/compose.yaml"
sync_file "$STACKS/oauth2-proxy/compose.yaml"  "$REPO/gateway/oauth2-proxy/compose.yaml"
sync_file "$STACKS/gatus/compose.yaml"         "$REPO/gateway/gatus/compose.yaml"
sync_file "$STACKS/gatus/config.yaml"          "$REPO/gateway/gatus/config.yaml"
sync_file "$STACKS/ntfy/compose.yaml"          "$REPO/gateway/ntfy/compose.yaml"
sync_file "$STACKS/ntfy/server.yml"            "$REPO/gateway/ntfy/server.yml"
sync_file "$STACKS/sms-relay/compose.yaml"     "$REPO/gateway/sms-relay/compose.yaml"
sync_file "$STACKS/sms-relay/Dockerfile"       "$REPO/gateway/sms-relay/Dockerfile"
sync_file "$STACKS/sms-relay/package.json"     "$REPO/gateway/sms-relay/package.json"
sync_file "$STACKS/sms-relay/src/index.js"     "$REPO/gateway/sms-relay/src/index.js"
sync_file "$STACKS/dockge/compose.yml"         "$REPO/gateway/dockge/compose.yml"

# UptimeRobot MCP server for JARVIS itself — not a /opt/stacks Docker service, lives at
# /opt/mcp-servers/ instead. API key deliberately excluded (Vaultwarden is the source of truth,
# a second live copy sits at /etc/uptimerobot-mcp/api_key.txt for the running process to read).
sync_file /opt/mcp-servers/uptimerobot/server.py "$REPO/gateway/uptimerobot-mcp/server.py"

# ── Sync sn-monitor configs (via SSH) ────────────────────────────────────────

log "Syncing sn-monitor configs..."
sync_remote sn-monitor /opt/stacks/monitoring/docker-compose.yml         "$REPO/sn-monitor/monitoring/docker-compose.yml"
sync_remote sn-monitor /opt/monitoring/prometheus/config/prometheus.yml  "$REPO/sn-monitor/monitoring/prometheus.yml"

# ── Sync sn-infra configs (via SSH) ──────────────────────────────────────────

log "Syncing sn-infra configs..."
sync_remote sn-infra /opt/stacks/pdns-admin/docker-compose.yml  "$REPO/sn-infra/pdns-admin/docker-compose.yml"
# Path corrected 2026-08-23: on-disk directory is `namevault`, not `namegen` (renamed at some
# point after the 2026-07-27 sn-infra rebuild — container_names inside the compose still say
# `namegen-app`/`namegen-db`, that's just internal naming, unrelated). The old `namegen` path had
# been silently WARN-failing every sync since, last successful pull was the rebuild day itself.
sync_remote sn-infra /opt/stacks/namevault/docker-compose.yml   "$REPO/sn-infra/namevault/docker-compose.yml"
sync_remote sn-infra /opt/stacks/forgejo/docker-compose.yml     "$REPO/sn-infra/forgejo/docker-compose.yml"

# ── Sync sn-web configs (via SSH) ────────────────────────────────────────────

log "Syncing sn-web configs..."
sync_remote sn-web /opt/stacks/stratus-digital/docker-compose.yml "$REPO/sn-web/stratus-digital/docker-compose.yml"
# stratus-digital moved from a bare static nginx site to a real Express app (2026-09-03/04, the
# client portal build) — its source is real application logic now, not just content, so it's
# tracked here unlike the other 5 sn-web sites' still-untracked html/ (a pre-existing gap, not
# introduced by this change).
sync_remote sn-web /opt/stacks/stratus-digital/app/Dockerfile      "$REPO/sn-web/stratus-digital/app/Dockerfile"
sync_remote sn-web /opt/stacks/stratus-digital/app/package.json    "$REPO/sn-web/stratus-digital/app/package.json"
sync_remote sn-web /opt/stacks/stratus-digital/app/server.js       "$REPO/sn-web/stratus-digital/app/server.js"
sync_remote sn-web /opt/stacks/stratus-digital/app/public/index.html "$REPO/sn-web/stratus-digital/app/public/index.html"
sync_remote sn-web /opt/stacks/discreet-elite/docker-compose.yml  "$REPO/sn-web/discreet-elite/docker-compose.yml"
sync_remote sn-web /opt/stacks/emerald-markets/docker-compose.yml "$REPO/sn-web/emerald-markets/docker-compose.yml"
sync_remote sn-web /opt/stacks/ruby/docker-compose.yml            "$REPO/sn-web/ruby/docker-compose.yml"
sync_remote sn-web /opt/stacks/evilrabbit/docker-compose.yml      "$REPO/sn-web/evilrabbit/docker-compose.yml"
sync_remote sn-web /opt/stacks/dicksonweb/docker-compose.yml      "$REPO/sn-web/dicksonweb/docker-compose.yml"

# ── Sync hot-erp-nl configs (via SSH) ────────────────────────────────────────
# ERPNext/Dickson permanently moved off sn-business to hot-erp-nl (2026-08-01) — sn-business
# itself has no live host or SSH alias and never will again (role moved permanently, see
# CLAUDE.md's services-hoterp.md). This replaces the old dead `sync_remote sn-business ...` line,
# which had been silently WARN-failing every run since the migration.

log "Syncing hot-erp-nl configs..."
sync_remote hot-erp-nl /opt/stacks/dickson/docker-compose.yml "$REPO/hot-erp/dickson/docker-compose.yml"

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
# Wazuh SIEM — found 2026-08-23 during the full fleet sync sweep: never synced at all despite
# being a major service on this host (manager + indexer + dashboard).
sync_remote sn-security /opt/stacks/wazuh/docker-compose.yml          "$REPO/sn-security/wazuh/docker-compose.yml"

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
  notify urgent "hot-config sync ABORTED: secret leak detected" \
    "Plaintext secret found in staged changes, not committed or pushed. Run sync.sh manually to see what tripped it: $LEAK"
  alert_if_warnings
  exit 1
fi

if $GIT diff --cached --quiet; then
  log "No changes — nothing to commit."
  alert_if_warnings
  exit 0
fi

CHANGED=$($GIT diff --cached --name-only | wc -l | tr -d ' ')
log "Committing $CHANGED changed file(s)..."

$GIT commit -m "chore: nightly config sync $(date '+%Y-%m-%d %H:%M')"

# Push to all three remotes independently — one unreachable remote (most
# often origin/Forgejo, which sits behind the internal WireGuard tunnel)
# must not block the others. External mirrors go first since they're the
# most likely to still be reachable during an internal network outage.
PUSH_FAILED=0
for remote in github codeberg origin; do
  if $GIT push "$remote" main; then
    log "Pushed to $remote."
  else
    log "WARN: push to $remote failed."
    WARNINGS+=("git push to $remote failed")
    PUSH_FAILED=1
  fi
done

alert_if_warnings

if [ "$PUSH_FAILED" -eq 1 ]; then
  log "Push complete with one or more failures — see WARNs above."
else
  log "Push complete."
fi
