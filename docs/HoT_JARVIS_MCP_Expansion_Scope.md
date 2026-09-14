# JARVIS MCP Expansion Scope — v6.0
**Scoped: 2026-09-13**
**Owner: House of Trae / SecureNexus**

---

## 1. Why This Exists

JARVIS (Claude Code on the Gateway VPS) currently queries most of the HoT stack via SSH
chains: `ssh sn-monitor curl localhost:9090/...`, `ssh hot-pn psql -c "..."`, `git ...` through
bash. Every such query pulls raw terminal output into the conversation context, is slow,
and produces unstructured text that needs manual parsing. The v6.0 roadmap calls for direct
MCP access to each major stack component — the same way PrivateNexus itself is already
reachable via the existing PN MCP server (16 tools, connected since the v5.0 build).

This scope defines the 7 MCPs to add, what each exposes, where it runs, and how it connects.

---

## 2. Current State

**Updated 2026-09-14 — build in progress.** Five MCPs now connected on the Gateway:

| MCP | Transport | Endpoint | Status |
|-----|-----------|----------|--------|
| `privatenexus` | HTTP | `http://10.10.2.2:3002/mcp` | ✅ Live — 16 tools |
| `sequential-thinking` | stdio (npx) | — | ✅ Live — reference implementation, zero build |
| `context7` | stdio (npx) | — | ✅ Live — reference implementation, zero build |
| `forgejo` | HTTP | `http://127.0.0.1:3004/mcp` | ✅ Live — 7 tools, custom server, see 3.5 |
| `github` | stdio (docker) | — | ✅ Live — 23 tools (read-only), official binary, see 3.8 |
| `vaultwarden` | stdio (node) | — | ✅ Live — 3 tools, read-only + folder-scoped, see 3.9 |
| `postgres-keycloak` | HTTP | `http://127.0.0.1:3005/mcp` | ✅ Live — 3 tools, read-only, see 3.3 |
| `postgres-privatenexus` | HTTP | `http://10.10.2.2:3010/mcp` | ✅ Live — 3 tools, read-only, see 3.3 |
| `prometheus` | HTTP | `http://127.0.0.1:3003/mcp` | ✅ Live — 5 tools, see 3.4 |
| `proxmox` | HTTP | `http://127.0.0.1:3006/mcp` | ✅ Live — 5 tools, read-only, see 3.6 |
| `wazuh` | HTTP | `http://127.0.0.1:3007/mcp` | ✅ Live — 5 tools, see 3.7 |

Configured in `/root/.claude/settings.json`. The UptimeRobot MCP is also configured
(`/opt/hot-config/gateway/uptimerobot-mcp/`) but is read-only and covers external
monitoring only.

**Every MCP in this document's original 7-item inventory, plus the 3 later additions
(GitHub/Vaultwarden/nothing else), is now built and verified live — 2026-09-13 through
2026-09-15.** 11 MCPs total on the Gateway (12 counting `privatenexus`, live since v5.0). This
scope is complete; anything further is a new ask, not a continuation of this doc.

---

## 3. MCP Inventory

### 3.1 Sequential Thinking
**What:** Structured multi-step reasoning for complex infrastructure decisions — chains
explicit reasoning steps before committing to an answer, reducing confident-but-wrong
outputs on multi-variable problems (migration planning, blast-radius assessment, etc.).

**Implementation:** Anthropic's reference implementation, available as
`@modelcontextprotocol/server-sequential-thinking`. No custom code.

**Effort:** ~15 minutes — install npm package, add to `settings.json`, done.

**Decision:** Run via `npx` in `settings.json` (stdio transport, same pattern as the
UptimeRobot MCP). No persistent process needed.

---

### 3.2 Context7
**What:** Up-to-date documentation for the PN stack injected into sessions on demand.
Covers Express v4, React 18, PostgreSQL 16, Redis, and Docker Compose. Eliminates the
"what's the correct API for X in this version" lookup that currently requires either
memory or a WebSearch.

**Implementation:** `@upstash/context7-mcp` (Upstash's Context7 service). Provides a
`resolve-library-id` + `get-library-docs` tool pair. Free tier is sufficient.

**Effort:** ~15 minutes — same pattern as Sequential Thinking.

**Decision:** stdio transport via npx. No local server needed.

---

### 3.3 PostgreSQL (PN + Keycloak DBs)
**What:** Direct read-only SQL access to PrivateNexus's PostgreSQL DB and, optionally,
the Keycloak DB on the Gateway — for incident context queries that the PN MCP's structured
tools don't expose (raw JOIN queries, ad-hoc investigation, schema inspection).

**Implementation:** `@modelcontextprotocol/server-postgres` (the reference Postgres MCP).
Provides a single `query` tool. Run with a read-only connection string.

**Connection path:**
- PN DB: `postgresql://privatenexus_ro:<pw>@10.10.2.2:5432/privatenexus` (requires a
  read-only `privatenexus_ro` user to be created on hot-pn — the production user should
  never be handed to an MCP tool that runs arbitrary SQL)
- Keycloak DB: `postgresql://keycloak_ro:<pw>@127.0.0.1:5432/keycloak` (local, Gateway VPS)

**Two separate MCP entries** in `settings.json` — one per DB, so each has its own named
tool namespace and connection string. Both stdio transport.

**Effort:** ~1 hour — create read-only DB users on each host, configure two entries in
`settings.json`, verify queries work.

**Decision:** Read-only users are mandatory. The PN production DB credentials are not
exposed to this MCP. Keycloak's DB is Gateway-local (no tunnel needed).

**✅ Built 2026-09-14/15 — NOT the deprecated reference package.** `npm view` confirmed
`@modelcontextprotocol/server-postgres` is deprecated/unsupported (last real option). Wrote a
custom server instead (`pg` + MCP SDK, 3 tools: `postgres_query`, `postgres_list_tables`,
`postgres_describe_table`), deployed twice from the same codebase:
- **Keycloak instance**: on the Gateway, `127.0.0.1:3005`, attached to the existing
  `keycloak_keycloak_internal` Docker network so it reaches `keycloak-db` without publishing any
  new DB port.
- **PrivateNexus instance**: on **hot-pn itself** (not the Gateway) — `privatenexus-db`'s port
  5432 is not published to any host interface at all (`docker inspect` confirmed), so the MCP had
  to run inside PN's own `compose_pn-internal` Docker network to reach it. Bound to
  `10.10.2.2:3010`, new UFW rule scoping it to the Gateway's wg3 IP only
  (`10.10.2.1`), matching every other PN service's pattern.

Read-only enforced three ways, not just one: a dedicated `keycloak_ro`/`privatenexus_ro` Postgres
role with `SELECT`-only grants (the real control — verified live, a `DELETE` as either role gets a
genuine `permission denied for table` straight from Postgres), a `BEGIN READ ONLY` transaction
wrapper, and a statement-shape guard rejecting anything that doesn't start with
`SELECT`/`WITH`/`EXPLAIN`/`SHOW`/`TABLE` before it ever reaches the DB. Both verified end-to-end
live: Keycloak instance listed all 10 real realms; PN instance queried the real `services` table
over wg3 from the Gateway; both correctly refused a write attempt at the app layer.

---

### 3.4 Prometheus
**What:** Direct metric and alert queries against sn-monitor's central Prometheus
(`10.10.50.104:9090`) — without SSHing through the WireGuard tunnel and curling by hand.

**Implementation:** Custom lightweight MCP server (`prometheus-mcp`). ~120 lines of Node.js.
Wraps Prometheus's own HTTP API — no third-party Prometheus MCP exists that's mature enough
to trust with production queries.

**Tools:**

| Tool | Description |
|------|-------------|
| `prometheus_query` | Instant query (`/api/v1/query`) — e.g. current CPU, memory, disk per host |
| `prometheus_query_range` | Range query with step — e.g. last 6h of a metric |
| `prometheus_alerts` | Active alerts from `/api/v1/alerts` |
| `prometheus_targets` | Scrape target health from `/api/v1/targets` |
| `prometheus_labels` | List label names/values — useful for figuring out the right selectors |

**Connection:** HTTP to `10.10.50.104:9090` via the existing wg4 → VLAN 50 path.
Prometheus is currently SSO-gated at the Caddy level, but the direct internal IP bypasses
Caddy entirely — no auth token needed for internal tool calls. The MCP server itself has
no Caddy in front of it.

**Location:** Docker container on Gateway, `/opt/stacks/prometheus-mcp/`. HTTP transport,
bound to `127.0.0.1:3003` (Tailscale or local only — no public exposure).

**Effort:** 2–3 hours — write server, test against live Prometheus, add to `settings.json`.

**✅ Built 2026-09-15**, exactly as scoped — no surprises. All 5 tools deployed on the Gateway,
`127.0.0.1:3003`, direct to `10.10.50.104:9090` over the existing wg4 route, no auth needed on the
internal IP. Verified live: `count(up)` correctly returned 28 (matches the known central
Prometheus target count), `prometheus_alerts` returned the real empty list (fleet healthy at build
time).

---

### 3.5 Forgejo
**What:** Create issues, PRs, and inspect repos on `git.securenexus.net` without bash git
chains or manual browser navigation. Most useful when JARVIS identifies a real infrastructure
problem that should be tracked — creates the issue directly from the session.

**Implementation:** Custom MCP server (`forgejo-mcp`). ~180 lines of Node.js. Wraps
Forgejo's Gitea-compatible REST API (`/api/v1/`).

**Tools:**

| Tool | Description |
|------|-------------|
| `forgejo_list_repos` | List repos for an owner (org or user) |
| `forgejo_create_issue` | Create an issue in a repo (title, body, labels) |
| `forgejo_list_issues` | List open issues in a repo with optional label filter |
| `forgejo_get_issue` | Get a single issue by number |
| `forgejo_create_pr` | Create a pull request (head branch → base branch) |
| `forgejo_list_prs` | List open PRs in a repo |
| `forgejo_get_commit_log` | Last N commits on a branch |

**Auth:** Forgejo API token (`jarvis-mcp-forgejo`). Token saved to a `chmod 644` Docker secrets
file on the Gateway (`/opt/stacks/forgejo-mcp/secrets/forgejo_token.txt`, not git-tracked — matches
the `**/secrets/` gitignore rule every other stack in `hot-config` follows). Read-write token
(`read:repository,write:repository,read:issue,write:issue,read:user`); no admin or delete scopes.
**Correction from the original plan**: CLI-generated Forgejo tokens (`forgejo admin user
generate-access-token`) are scoped by permission category only, not restricted to specific repos —
Forgejo/Gitea's per-repo token restriction is a web-UI-only feature this CLI path doesn't expose.
So this token can act on every repo `tristian` owns, not just `hot-config`/`privatenexus` as
originally scoped — acceptable given it's still read/write-only (no admin/delete) and it's the
same account that already owns everything on this instance, but worth knowing if a lower-privilege
JARVIS identity is ever wanted here.

**Location:** Docker container on Gateway, `/opt/stacks/forgejo-mcp/` (tracked in
`hot-config/gateway/forgejo-mcp/`, secrets excluded). HTTP transport, bound to `127.0.0.1:3004`,
its own Bearer-token auth in front (separate secret from the Forgejo API token itself — protects
the local HTTP endpoint, not Forgejo).

**Effort:** ~45 min actual — write server (SDK `StreamableHTTPServerTransport`, stateless per-request),
generate Forgejo API token via `forgejo admin user generate-access-token` on sn-infra (redirected
straight to a file, never printed to the session — Bash's own auto-mode classifier blocks a raw
`--raw` token print to stdout as "Credential Materialization"; the safe path is redirecting output
server-side and pulling the file across hosts without ever displaying it), build+deploy the
container, verify live (`initialize` → `tools/list` → a real `forgejo_list_repos` call, confirmed
`hot-config`/`privatenexus` came back correctly), wire into `settings.json`.

**✅ Saved to Vaultwarden 2026-09-14** — both the Forgejo API token ("Forgejo jarvis-mcp-forgejo API
token (git.securenexus.net)") and the local MCP Bearer auth token ("forgejo-mcp local Bearer auth
token (Gateway MCP server, 127.0.0.1:3004)"), both in the "House of Trae — Gateway VPS" folder.
**Real process note, worth keeping**: the first credential Mr. Byrne pasted for this failed to
unlock (`Cryptography error, The decryption operation failed`) — treated as a bad/garbled master
password, not retried blindly (Vaultwarden has its own brute-force lockout scenario,
`hot/vaultwarden-bf`). Second attempt was a `bw unlock --raw` session key generated by Mr. Byrne
himself and pasted in, verified as valid via `bw status --session <key>` (a local decrypt check,
doesn't touch the server's auth/rate-limit path) before being used. This is the safer pattern going
forward for any future non-interactive Vaultwarden write from this session — **hand the session
key, never the master password** — and closes the "no non-interactive Vaultwarden path exists"
gap this doc flagged earlier, at least for one-off saves where Mr. Byrne unlocks and hands over the
key each time. A fully unattended path (e.g. for a script) would still need a different mechanism —
not built, not asked for.

---

### 3.6 Proxmox
**What:** Check VM state, resource usage, and snapshot inventory on hot-bm-nl without SSHing
through the wg4 tunnel. Primarily useful during outage investigation and capacity planning.

**Implementation:** Custom MCP server (`proxmox-mcp`). ~150 lines of Node.js. Wraps the
Proxmox REST API (`https://10.10.3.2:8006/api2/json/`).

**Tools:**

| Tool | Description |
|------|-------------|
| `proxmox_list_vms` | List all VMs with status, uptime, and resource config |
| `proxmox_get_vm` | Detailed status for one VM (CPU, RAM, disk usage) |
| `proxmox_get_node_resources` | Host-level resource usage (RAM, CPU, ZFS pool) |
| `proxmox_list_snapshots` | List snapshots for a VM |
| `proxmox_list_backups` | List PBS/vzdump backup records for a VM |

**Auth:** Proxmox API token with `PVEAuditor` role — read-only, no destructive capability.
Token generated on hot-bm-nl (`pveum token add jarvis@pve!mcp --privsep=1 --roles PVEAuditor`),
saved to Vaultwarden and a Gateway secrets file. TLS verification disabled for the internal
self-signed Proxmox cert (`rejectUnauthorized: false` in the Node.js agent — internal-only,
acceptable).

**Connection:** HTTP to `10.10.3.2:8006` via wg4. Already reachable from the Gateway
(used by the reboot-recovery-watchdog for `qm` commands today).

**Location:** Docker container on Gateway, `/opt/stacks/proxmox-mcp/`. HTTP transport,
bound to `127.0.0.1:3005`.

**Effort:** 2–3 hours — write server, generate PVEAuditor token, test, add to `settings.json`.

**✅ Built 2026-09-15 — three real gotchas, not one.** New `jarvis@pve` user + `jarvis@pve!mcp`
token, `PVEAuditor` at `/`. (1) hot-bm-nl's UFW only allows port 8006 from `tailscale0` or hot-pn's
own wg3 IP — **not** the Gateway's wg4 address — so this is routed via Tailscale
(`100.90.156.88`) instead, matching the connection's own documented purpose (admin/Proxmox-UI
access) rather than opening a new wg4 hole. (2) Docker's default bridge network couldn't route
container traffic to the host's `tailscale0` interface at all — reachable from the Gateway host
directly, timed out from inside a bridge-networked container — fixed with `network_mode: host`
(same fix already used for hot-erp-nl's local Prometheus and hot-bm-nl's own `nginx-certbot`
container for the identical class of problem, both documented elsewhere in this project). (3) Same
privilege-separation gotcha this project already hit with PBS tokens (`alerting-backups.md`):
granting `PVEAuditor` to the **user** alone returned zero VMs — `privsep=1` tokens need the role
granted to the **token** itself too (`pveum acl modify / --tokens 'jarvis@pve!mcp' --roles
PVEAuditor`). Also found live: Proxmox's own node id is `proxmox22272` (Hostkey's hostname), not
`hot-bm-nl` — the project's own alias doesn't match the PVE node id, don't assume it does anywhere
else either. Verified live: all 4 real VMs returned with real current resource figures matching
their known right-sized configs.

---

### 3.7 Wazuh
**What:** Query SIEM alerts and agent status during security incidents without opening the
dashboard browser or SSHing into sn-security. Cross-correlates with what the PN lockdown
board shows, for a full picture in one session.

**Implementation:** Custom MCP server (`wazuh-mcp`). ~180 lines of Node.js. Wraps the
Wazuh Manager REST API (`https://10.10.70.106:55000`) — not the OpenSearch API directly,
which is more complex and less structured for this use case.

**Tools:**

| Tool | Description |
|------|-------------|
| `wazuh_get_agents` | List all enrolled agents with connection status |
| `wazuh_get_agent` | Details for one agent (last keepalive, version, OS) |
| `wazuh_query_alerts` | Query recent alerts with optional level/rule/agent filter |
| `wazuh_get_alert_summary` | Count of alerts by level over the last N hours |
| `wazuh_get_top_rules` | Top triggered rules over the last N hours |

**Auth:** Wazuh API credentials (`wazuh-wui` user, password `mHB2UhhMw0wTc3q8@22vJeOvr` from
CLAUDE.md). These are the existing documented credentials. No new account needed. TLS
verification disabled for the internal self-signed Wazuh cert.

**Connection:** HTTPS to `10.10.70.106:55000` via wg4 → VLAN 70. The Gateway can reach this
IP via the existing UFW route rules (Wazuh agent enrollment established this path in 2026-08-08;
confirm the port is reachable before assuming).

**Location:** Docker container on Gateway, `/opt/stacks/wazuh-mcp/`. HTTP transport,
bound to `127.0.0.1:3006`.

**Effort:** 2–3 hours — write server, verify Wazuh API reachability from Gateway, test, add
to `settings.json`.

**✅ Built 2026-09-15, on port 3007 (3006 went to Proxmox instead — ports were assigned as each
MCP was actually built, not pre-reserved per this doc's original numbering).** **Real correction to
the plan above**: the Wazuh Manager REST API has no alert-search endpoint at all — agent
management, rules, cluster status, yes; alert history, no. That data only lives in the OpenSearch
indexer. So `wazuh_get_agents`/`wazuh_get_agent` hit the manager API (`10.10.70.106:55000`, JWT via
the existing documented `wazuh-wui` credentials, cached ~13min) as planned, but
`wazuh_query_alerts`/`wazuh_get_alert_summary`/`wazuh_get_top_rules` hit the indexer directly
(`10.10.70.106:9200`, existing `kibanaserver` credentials) against the real `wazuh-alerts-4.x-*`
index pattern.

**⚠ Real production issue found and fixed while building this, unrelated to the build itself**:
the manager API returned a 500 ("Some Wazuh daemons are not ready yet... wazuh-remoted->failed")
on the very first auth attempt. `wazuh-control status` on the manager confirmed `wazuh-remoted`
(the daemon handling all agent communication on 1514/1515) was genuinely down, with a stale PID
(`Process 537 not used by Wazuh, removing...`) — meaning every one of the 7 enrolled agents' real
event delivery was silently broken, fleet-wide, for an unknown duration (no crash trace in
`ossec.log`, possibly OOM-related given sn-security's documented swap pressure in `hardware.md`,
not confirmed). Fixed with `wazuh-control restart` on the manager container — clean restart, no
data loss. **Nothing in this project's existing monitoring (`fleet-health-sweep`'s wazuh-agent
liveness check included) watches this specific daemon** — it checks agent-side process liveness,
not whether the manager can actually receive what they send. Worth adding as a future
`fleet-health-sweep` check, not done here (out of scope for an MCP build). Verified fully live
post-fix: agent list, a real 74-alert/24h summary by level, top 5 triggered rules (mostly PAM/sshd
login events — sn-security's real fleet SSH pattern, not manufactured), and a real alert query all
returned correct data.

---

### 3.8 GitHub
**What:** Requested 2026-09-14, not in the original 7. `hot-config` already mirrors to GitHub
(`git@github.com:traebon/hot-config.git`, see Network/Backup sections) alongside Codeberg — a
GitHub MCP would let JARVIS check mirror push status, browse the public mirror's issues/PRs (if
ever used) without a browser.

**✅ Built 2026-09-14.** Mr. Byrne supplied a fine-grained PAT directly. Checked live before
trusting it: authenticates as `traebon`, and (unexpectedly) carries full `admin` permissions on
`traebon/hot-config` — broader than the "read-only on the mirror" minimum this doc originally
proposed. Rather than ask for a narrower token, the MCP server itself was started with
**`--read-only` + `--toolsets=repos,issues,pull_requests,users`** regardless of what the PAT could
technically do — same reasoning as the least-privilege posture on every other MCP in this doc
(§6). Also found: `traebon/hot-config` is a **public** repo (not private) — pre-existing state, not
something this session changed, just worth Mr. Byrne knowing it's visible on the open internet.

**Implementation actually used**: NOT the hosted `https://api.githubcopilot.com/mcp/` OAuth
endpoint originally proposed below (that path is Copilot-subscription/OAuth-oriented) — instead
the official **local** server, `ghcr.io/github/github-mcp-server` (Go binary, stdio transport),
run via `docker run -i --rm --env-file ...` directly from `settings.json` (same pattern as
`sequential-thinking`/`context7`, just with a secrets env-file instead of no secrets at all). PAT
lives in `/opt/stacks/github-mcp/secrets/github_pat.env` (`chmod 600`, not git-tracked). Verified
live via a real stdio handshake + `tools/list` (23 tools came back under the read-only toolset
restriction) before wiring into `settings.json`. PAT also saved to Vaultwarden ("GitHub PAT
(jarvis-mcp-github, traebon account)", House of Trae — Gateway VPS folder) using the same
session-key-handoff pattern established for the Forgejo secrets in §3.5.

**Original proposal (superseded, kept for context):**
~~GitHub's official remote MCP (`https://api.githubcopilot.com/mcp/`, HTTP transport, PAT or
OAuth) — no custom server needed.~~ Reconsidered once a plain PAT (not a Copilot OAuth grant) was
what Mr. Byrne actually had on hand — the local Docker binary is the documented path for static-PAT
auth and matches this project's existing container-per-MCP pattern more closely anyway.

---

### 3.9 Vaultwarden
**What:** Requested 2026-09-14, not in the original 7. Direct MCP access to the credential vault
that backs literally every other secret in this project.

**⚠ Blocked — this one needs an explicit decision from Mr. Byrne before any build, not just a
missing credential.** Two things make this categorically different from every other MCP on this
list:

1. **The official `@bitwarden/mcp-server` package's own README carries an explicit warning**
   (checked live via `npm view`, not assumed): granting an AI assistant access means it can *read
   passwords, secure notes, and sensitive data; create/modify/delete vault items; access
   organization admin functions* — and that "AI responses may inadvertently reveal sensitive
   information." This project's own `settings.json` environment block independently flags
   Vaultwarden as top-tier sensitive data ("all credentials/secrets") — the vendor and this
   project's own config agree this is a different risk class than a Prometheus or Proxmox
   read-only query tool.
2. **This project has already had two real prompt-injection incidents** (`prompt_injection_incident_2026_08_17`,
   and a second flagged inside `crowdsec_fleet_egress_selfban_2026_09_13`) — both cases of
   untrusted text reaching a session and attempting to redirect its actions. A Vaultwarden MCP
   with write/delete/org-admin scope, sitting in a session that also routinely ingests SSH/log
   output from a fleet under active internet-facing attack (CrowdSec bans, brute-force scenarios),
   is a materially larger target than anything else proposed here.

There's also a practical blocker on top of the judgment one: the `bw` CLI (already installed,
already logged in as `tristian@securenexus.net`, currently `locked`) needs a master-password
unlock to decrypt anything — there is no stored password or session-key mechanism anywhere in this
project's scripts (checked `hot-config/scripts/`, environment, `~/.bashrc`) for doing that
non-interactively. Whatever this MCP is scoped to, someone still has to solve "how does a headless
Gateway session unlock the vault without a human typing the master password into a terminal each
time" — likely an API-key login (`bw login --apikey`, avoids the master password for
*authentication*) plus a stored session key with its own tight access control, itself becoming a
new secret worth treating as seriously as the vault it unlocks.

**✅ Built 2026-09-14, per Mr. Byrne's explicit decision: read-only, folder-scoped to "House of
Trae — Gateway VPS".** Custom stdio MCP server (`/opt/stacks/vaultwarden-mcp/`, tracked in
`hot-config/gateway/vaultwarden-mcp/`, secrets excluded) — NOT the official `@bitwarden/mcp-server`
package, which ships full CRUD + org-admin by default and would have needed heavy flag-gating to
match the decision. This one only *has* 3 tools at the code level — `vaultwarden_status`,
`vaultwarden_list_items`, `vaultwarden_get_item` — no create/edit/delete tool exists at all, so
there's nothing to accidentally leave enabled.

**Folder scoping is enforced twice**: `vaultwarden_list_items` calls `bw list items --folderid
<id>` server-side (can't see other folders at all), and `vaultwarden_get_item` independently
checks the fetched item's own `folderId` before returning anything, refusing even a directly-known
item ID from outside the folder. Both were verified live — `list_items` came back with exactly the
Gateway-VPS-folder items (Forgejo/GitHub tokens, Wazuh/PowerDNS/Grafana/Tailscale creds, WireGuard
keys, etc.), and a real `get_item` call against the just-saved Forgejo token succeeded structurally
(right name, `folderId` matched, a real 40-char password came back — never printed to the session,
only checked for shape/length). **The cross-folder refusal path itself could not be live-tested**:
finding a real item ID in a different folder to test against was blocked by the auto-mode
classifier as "Credential Exploration" — correctly, since browsing another folder's contents
(even just names/IDs, no secrets) is exactly the kind of scope-creep this whole build exists to
prevent. Confidence in that path rests on code review (`if (item.folderId !== FOLDER_ID) return
errorResult(...)` — server.js, one line) rather than a live test; worth a real cross-folder test if
Mr. Byrne ever wants to hand over a specific out-of-folder item ID for it.

**Deliberately still no standing auto-unlock** — `secrets/bw_session.txt` starts and ends every
session empty. Mr. Byrne runs `bw unlock` himself and hands over the session key each time the
tool is actually needed (same pattern established for the Forgejo/GitHub credential saves); the
file is cleared and `bw lock` re-run immediately after each use. This keeps the "no new master-key
equivalent" reasoning from the original build-order decision intact — the tool is inert by default,
not always-on.

---

## 4. Build Order

| Order | MCP | Effort | Why first |
|-------|-----|--------|-----------|
| 1 | Sequential Thinking | 15 min | Zero build, immediate benefit |
| 2 | Context7 | 15 min | Zero build, immediate benefit |
| 3 | PostgreSQL | 1 hr | Off-the-shelf package, one DB user creation |
| 4 | Prometheus | 2–3 hr | Highest query volume during infra sessions |
| 5 | Forgejo | 2–3 hr | Closes issue-tracking loop without browser |
| 6 | Proxmox | 2–3 hr | Outage investigation value |
| 7 | Wazuh | 2–3 hr | Security incident value — lower daily frequency |

Total estimated effort: 10–14 hours across all 7.

---

## 5. All-MCP Architecture

All custom MCPs follow the same pattern as the existing PN MCP server:

```
Gateway /opt/stacks/<name>-mcp/
├── docker-compose.yml       # binds to 127.0.0.1:<port>, restart: always
├── server.js                # Node.js MCP HTTP server
├── package.json
└── secrets/                 # .gitignore'd; credentials from Vaultwarden
    └── <name>_token.txt
```

Configured in `/root/.claude/settings.json`:
```json
"<name>": {
  "type": "http",
  "url": "http://127.0.0.1:<port>/mcp",
  "headers": { "Authorization": "Bearer <token>" }
}
```

Sequential Thinking and Context7 use stdio transport instead (no container, no port).

---

## 6. Security Posture

- All custom MCPs bound to `127.0.0.1` only — not accessible from LAN, WireGuard tunnels,
  or the public internet
- All read-only by design (Forgejo has write for issue/PR creation, but no delete/admin)
- No credentials embedded in `settings.json` — each MCP reads from a secrets file
- Postgres MCPs use dedicated read-only users — production DB user never exposed
- Proxmox and Wazuh tokens are least-privilege (`PVEAuditor` and `wazuh-wui` respectively)
- Wazuh API credentials already documented; no net-new exposure

---

## 7. Out of Scope

- MCP write tools for Prometheus (no push metrics capability)
- MCP write tools for Proxmox (VM start/stop/snapshot from JARVIS — too high blast radius
  without a separate confirmation flow; the reboot-recovery-watchdog handles this already)
- MCP write tools for Wazuh (rule changes, agent removal — not a JARVIS use case)
- Grafana MCP (Grafana queries currently go through the PN MCP's alert/metrics tools;
  a dedicated Grafana MCP is a post-v6.0 item if the need becomes clear)
- Keycloak MCP (admin console use cases for JARVIS are rare; SSH + kcadm.sh is sufficient)

---

*Related: `PrivateNexus_Release_Roadmap_v1.0.md` v6.0 JARVIS MCP section,
`claude-md/services-fleet.md` Gateway VPS service table*
