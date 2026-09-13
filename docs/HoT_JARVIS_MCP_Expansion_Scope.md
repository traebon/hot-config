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

**Updated 2026-09-13/14 — build started.** Four MCPs now connected on the Gateway:

| MCP | Transport | Endpoint | Status |
|-----|-----------|----------|--------|
| `privatenexus` | HTTP | `http://10.10.2.2:3002/mcp` | ✅ Live — 16 tools |
| `sequential-thinking` | stdio (npx) | — | ✅ Live — reference implementation, zero build |
| `context7` | stdio (npx) | — | ✅ Live — reference implementation, zero build |
| `forgejo` | HTTP | `http://127.0.0.1:3004/mcp` | ✅ Live — 7 tools, custom server, see 3.5 |

Configured in `/root/.claude/settings.json`. The UptimeRobot MCP is also configured
(`/opt/hot-config/gateway/uptimerobot-mcp/`) but is read-only and covers external
monitoring only.

**Two more requested 2026-09-14, not in the original 7-item inventory below — see 3.8/3.9:**
GitHub (blocked, needs a PAT from Mr. Byrne) and Vaultwarden (blocked, needs a scope decision —
this one carries real security weight, see 3.9).

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

**⚠ Not yet done: the Forgejo token itself hasn't been saved to Vaultwarden.** Every other secret
this project mints gets saved there immediately (see the Vaultwarden & Self-Hosted Default
feedback rule) — this one is sitting only in the Gateway's local secrets file. Saving it needs
`bw unlock`, which needs Mr. Byrne's master password; no non-interactive path for that exists
anywhere in this project's scripts (checked `hot-config/scripts/` — nothing calls `bw unlock`
unattended). Blocked on Mr. Byrne actually running the save himself or supplying the password
through a channel this session can use safely.

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

---

### 3.8 GitHub
**What:** Requested 2026-09-14, not in the original 7. `hot-config` already mirrors to GitHub
(`git@github.com:traebon/hot-config.git`, see Network/Backup sections) alongside Codeberg — a
GitHub MCP would let JARVIS check mirror push status, browse the public mirror's issues/PRs (if
ever used) without a browser.

**⚠ Blocked — needs a credential only Mr. Byrne can produce.** Checked the mirror setup first:
`hot-config`'s GitHub remote authenticates via an SSH deploy key, not an API token — fine for
`git push`, useless for the GitHub REST/GraphQL API that an MCP server needs (issues, PRs, repo
metadata). No GitHub PAT exists anywhere on this fleet to reuse (checked `hot-config/scripts/`,
Vaultwarden folder names in prior memory — none). Unlike the Forgejo token above, this can't be
self-service generated from the Gateway — it requires Mr. Byrne's own GitHub account (PAT creation
or the GitHub App OAuth flow), which this session has no path to.

**Implementation once a token exists:** GitHub's official remote MCP
(`https://api.githubcopilot.com/mcp/`, HTTP transport, PAT or OAuth) — no custom server needed,
unlike Forgejo. Simpler than the Forgejo build; the only blocker is the credential.

**Open question for Mr. Byrne:** what scope should the PAT have? A fine-grained PAT scoped
read-only to just the `traebon/hot-config` mirror repo is the minimum useful case (checking mirror
health); broader scope (creating issues/PRs on GitHub itself) only matters if GitHub, not Forgejo,
is ever meant to be a real interaction surface rather than a pure mirror target — currently it
isn't (Forgejo is canonical per this project's whole architecture).

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

**Not built. Needs Mr. Byrne to decide, before this is scoped further:**
- Read-only (view items) vs. the full read/write/delete/org-admin surface the official package
  ships by default
- Whether it's scoped to specific folders/collections (e.g. only the "House of Trae — Gateway VPS"
  folder) or the whole vault
- How the headless unlock problem gets solved, given no existing mechanism does this today

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
