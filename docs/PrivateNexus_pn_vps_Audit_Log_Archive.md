# PrivateNexus / hot-pn (pn-vps) — Audit Log Archive

Archived 2026-08-05 from `/root/hot/CLAUDE.md` to shrink that file back down to reference size —
it had accumulated a full chronological engineering journal of every audit/bug-fix session run
against the PrivateNexus app on hot-pn (2026-07-15, 2026-07-16, 2026-07-24), which doesn't need to
be reloaded into every conversation's context. This is the complete, unedited detail; CLAUDE.md's
`hot-pn` section now carries only a condensed current-state summary. All commit hashes below are in
the `hot-privatenexus` repo unless a file says `hot-config`.

---

## PowerDNS reachability from pn-vps (fixed 2026-07-15)

The Gateway's PowerDNS API (`10.10.0.1:8081`) was wrongly assumed unreachable from pn-vps due to
being "outside the VLAN mesh" — actually PowerDNS lives on the Gateway itself, not bare metal, so it
was reachable the whole time; three independent bugs just made it look like a bare-metal dependency:
1. **No UFW rule for port 8081 existed at all** on the Gateway (not even for the internal fleet) —
   added `ufw allow from 10.10.0.0/16 to any port 8081`.
2. **pn-vps's wg0 `AllowedIPs`** (its local interface name for the Gateway tunnel — the Gateway
   calls its side `wg3`) was scoped to just `10.10.2.1/32` (the Gateway's tunnel IP), so pn-vps
   never routed traffic bound for `10.10.0.1` into the tunnel. Widened to `10.10.2.1/32,
   10.10.0.1/32` — deliberately narrow, not the full `10.10.0.0/16`, to keep this external/
   less-trusted box's blast radius minimal.
3. **`wg syncconf` does NOT install kernel routes** — see the Operational Rules table entry in
   CLAUDE.md for the general lesson; here it meant manually `ip route add 10.10.0.1/32 dev wg0`.

Also found `wg-quick@wg0` was never `systemctl enable`d on pn-vps — enabled it. And
`/opt/privatenexus/secrets/pdns_api_key.txt` was `chmod 600` instead of `644` (container runs as
non-root `user: "1000"`) — fixed.

## Monitoring-temp, Watchtower, Discovery agent (added 2026-07-15)

- **Monitoring (temp)** — `PROMETHEUS_URL`/`LOKI_URL` repointed from sn-monitor to a local
  Prometheus + node-exporter + Loki + Promtail stand-in, all on `compose_pn-internal` only, no host
  ports published. Loki's `/ready` returns a cosmetic 503 (known single-node quirk, ingests fine).
  Promtail's `container` label relabel rule originally stripped the leading slash from
  `__meta_docker_container_name` — silently broke every Logs board query until fixed 2026-07-15
  (`hot-config` commit `f80c6b1`). Permanent now that pn-vps is PrivateNexus's home.
- **Watchtower** — pinned v1.5.3, monitor-only. PrivateNexus's 3 locally-built services carry
  `com.centurylinklabs.watchtower.enable=false` (no registry path to check). Given a real health
  check 2026-07-16 (`hot-config` commit `2589f3b`): `WATCHTOWER_HTTP_API_METRICS=true`
  (bearer-token gated, deliberately not `_UPDATE`), moved onto `compose_pn-internal` so the backend
  can reach it. `services.health_endpoint` uses `tcp://watchtower:8080` since the schema can't carry
  a bearer token for an HTTP check. Token saved to Vaultwarden ("pn-vps Watchtower HTTP API token").
- **Discovery agent** — `privatenexus-discovery-agent.timer` (systemd, boot + hourly) pushes host +
  container facts to `POST /api/discovery/ingest`. Hardened 2026-07-15: was running on the ingest
  endpoint's static bootstrap fallback token (`agent_tokens` was empty) — rotated to a real 64-hex
  token, hash in `agent_tokens`, plaintext in `/opt/privatenexus/secrets/discovery_agent_token.txt`
  (tightened to `600`, read by a root-owned systemd service, not a container).

## 2026-07-15 — full write-surface safety/audit sweep

Prompted by discovering the Stacks board's restart/stop confirmation modal called `POST
/api/actions/run` (v1, bare cooldown/allowlist) instead of the already-built `/run/v2` (real
blast-radius/elevation/approval-queue logic). Fixed in commit `2043d30`, which also surfaced a live
bug: `actions.js`'s `userRoleLevel()` read `req.session.user.role` (singular) but sessions only ever
populate `.roles` (array) — every `/run/v2` elevation check had been silently 403ing every role since
the endpoint was written, never caught because nothing in the UI called it until this fix.

This kicked off a systematic board-by-board audit of the entire app (every backend route file, the
MCP tool surface, every frontend action button), looking for two repeating bug classes: **(a)** a
new/parallel code path bypassing an existing safety gate (blocklist, cooldown, audit trail), and
**(b)** missing error handling that could crash the whole backend, not just fail one request. Findings,
in order:

- **Dashboard/Inventory (commit `ff5b346`)** — PRD FE-01/FE-02 gaps: added a per-workspace health
  panel to Home, and a `?status=` filter to `GET /api/services` + Inventory toolbar.
- **FE-09/10/11 audit** — Catalogue and Files boards were already fully built (PRD mis-tagged);
  Logs board was fully built but had the Promtail relabel bug above, fixed same day.
- **Intelligence board (commit `1d8ed74`)** — its own `container.restart` executor called Docker
  directly, bypassing `actions.js`'s `CONTAINER_BLOCKLIST` (`privatenexus-db`/`-redis` — restarting
  either mid-session causes data loss). Reachable via autonomous execution (human-approval-gated,
  not exploitable alone), a human approving a proposal, or the MCP `pn_restart_service` tool. Gap
  was live but never triggered (zero rows in `remediation_proposals` for either container, confirmed).
  Fixed by exporting `CONTAINER_BLOCKLIST` and gating the executor on it. Also found `POST
  /api/intelligence/incident` fully built but orphaned (not called from anywhere) — later resolved,
  see below.
- **DNS route audit (commit `b2e8813`)** — `App.jsx`'s `LOCKED_TYPES=["SOA","NS"]` only hid
  edit/delete buttons client-side; `routes/dns.js` had zero server-side type restriction, so any
  `operator` session could delete/overwrite a zone's SOA/NS via direct API call. Fixed with a
  matching server-side `LOCKED_RECORD_TYPES` check, 403 before any PowerDNS call.
- **Governance board (commits `6f3ab9e`, `07ba00e`)** — imported `recordAudit` but never called it:
  `PATCH /rules/:key/toggle`, `POST /exceptions`, `DELETE /exceptions/:id` had zero audit trail.
  Same gap found in `services.js`'s workspace CRUD and `recovery.js`'s simulation/restore-test
  deletes (the workspace DELETE case reassigns member services to `workspace_id=NULL` with no
  record of who/how-many). Fixed all; also fixed exception DELETE to return a real 404.
- **Full route audit closed (commit `2894e76`)** — last 5 files (`ops.js`, `alerts.js`, `apps.js`,
  `auth.js`, `metrics.js`) checked. One find: `auth.js`'s OIDC callback only logged failed logins to
  console, never `recordAudit` — backwards, since failures are the security-relevant case. Fixed.
- **MCP tool surface (commit `a544be5`)** — all 15 tools checked; auth model synthesizes
  `{username:"mcp-server", roles:["operator"]}`, no privilege escalation found beyond what an
  operator already has via the UI. One find: `pn_restart_service` had zero cooldown (unlike every
  UI restart path) — fixed by reusing `actions.js`'s `COOLDOWN_MS`, keyed by `container_name`.
- **Frontend cooldown sweep (commits `3a9b052`, `acc7ca2`, `a5bcddc`)** — found the `max_per_hour`
  autonomous-execution rate limit was structurally non-functional (counter reset to `{}` every call,
  `openSet` already prevented same-signal-twice so it could never exceed 1) — fixed by seeding from
  actual `remediation_proposals` in the last hour. `executeDeployContainer()` (the most destructive
  action type — full stop+remove+create) had zero cooldown across all 3 callers — fixed once, shared.
  Governance's `toggleRule`/`deleteException` and Discovery's `createAgentToken`/`revokeAgentToken`
  had no in-flight guard — fixed for consistency (lower severity, no lifecycle race). Deploy/Rollback
  frontend buttons got matching in-flight guards (`rollbackSaving` added to mirror `deploySaving`).
- **Emergency board (commit `203396b`)** — `POST /api/actions/emergency` never consulted
  `action_policies` despite a seeded row for `emergency.stop-all` requiring
  `elevation_required=superadmin`/`cooldown_secs=3600`/`requires_approval=true` — only
  `requireRole("admin")` gated it. **Asked Mr. Byrne rather than deciding unilaterally** since
  `requires_approval` (dual-control) risks locking him out solo during a real incident — he chose to
  enforce elevation + cooldown, explicitly skip `requires_approval`. Verified his account already
  carried `superadmin` before deploying.

## 2026-07-16 — governance cleared to zero, then re-audit found more

- Deleted the orphaned `/api/intelligence/incident` route (commits `b7418f3`, `9b744d5`) after
  confirming it duplicated `recovery.js`'s already-wired `/playbook` route, which had since gained
  restore-test staleness data the orphan never got.
- **Discovery auto-approval pipeline (commit `988af93`)** — 3 real bugs: `backup_policy` hardcoded
  to invalid `"unknown"` (fixed to honest `"none"`); `inferHealthEndpoint()` only worked for
  published host ports against `localhost` (wrong host even then) — rewrote to address containers by
  Docker network name on their real listening port, confirmed via `docker inspect`/`nc`, not
  `EXPOSE` metadata alone (watchtower `EXPOSE`s 8080 but nothing listens there without
  `_UPDATE=true`); `inferCategory()` emitted values with zero overlap with `VALID_CATEGORIES` — 4 of
  11 services carried a category with no matching UI option. Backfilled all 11 rows, verified live.
- **Real backup routine for `privatenexus-db` (commit `0b80afb`, `hot-config` script
  `backup-pn-vps-privatenexus-db.sh`)** — wired existing `pg_dump.sh` into a daily systemd timer,
  extended to `INSERT` into `service_backups`; Gateway-side script pulls the dump via rsync 30 min
  later, feeds it into the existing `hetzner-crypt`/`b2-hot-crypt` rclone remotes. Verified all 4
  landing spots via `rclone lsl`. `backup_policy` only set to `'daily'` after a real backup existed.
- **Remaining violations remedied, not exempted (2026-07-16)** — for the 10 non-DB services,
  registered `backup_type='config'` rows pointing at their real, verified-reachable (`200`) GitHub
  mirror commit — Codeberg came back 404, don't assume it's checkable — `backup_policy='manual'`
  (event-triggered by commits, the honest characterization). **Final: 0 violations across all 7
  governance rules**, except watchtower's `health_check_required` (later also closed, see above).
- **Recovery runbooks written for all 11 services (commit `127139b`)** — 5 real markdown docs in
  `docs/runbooks/`, each tailored to what's actually true (e.g. redis's notes there's no volume to
  back up), all URLs verified `200` before wiring into `services.recovery_runbook_url`.
- **Intelligence board re-audit (commit `ee8aae5`)** — `probeService()`'s HTTP branch didn't catch
  `fetch()` errors the way the real scheduler does; a thrown connection failure skipped the DB write
  entirely (no `health_events` row, no status update) — the exact failure mode the whole
  signal-detection system exists to catch, silently missed. Fixed by wrapping the HTTP branch,
  verified live by pointing a real endpoint at a closed port.
- **`container.restart` autonomous toggle (commit `9b1e49e`)** — found dormant: `requiresApproval`
  was hardcoded true for this action type regardless of the policy's `enabled` flag, so the toggle
  had zero effect. Flagged to Mr. Byrne as a safety tradeoff rather than fixed unilaterally; he chose
  to make it work. Wired up gated additionally on `sig.severity==="critical"` (5+ failures, matching
  the policy's documented intent) — verified live via a real container restart
  (`StartedAt` timestamp changed), then re-disabled and test data cleaned up.
- **Discovery drift detection (commits `7919ee0`, `f16f58a`)** — only checked candidates with
  `source='local_docker'` (the manual scan button), but the actual automated pathway
  (`discovery-agent.timer`) submits `source='docker'` — drift detection had been silently reporting
  "no scan data" regardless of real drift. Broadened the query to accept both.
- **Recovery board (commit `84294a1`)** — `computeConfidence()`'s "no runbook" blocker list was
  missing the `app`/`monitoring` categories added earlier the same day — 10 of 11 services could
  silently lose 10 confidence points with no explanation. Fixed.
- **Real restore test for `privatenexus-db`** — restored the actual 04:25 pg_dump into an isolated
  scratch `postgres:16-alpine` container (never touching live), verified schema/registry match and a
  clean `ON_ERROR_STOP=1` completion. Recorded via the real API. Service moved to `recoverable` (95)
  — the only one of 11 to cross that threshold at the time.
- **Dependency graph mapped, 7 real edges (2026-07-16)** — each verified against actual running
  config (compose `depends_on`, real nginx `proxy_pass` target, real `prometheus.yml` scrape target,
  etc.) before creating via the API — no edges fabricated. watchtower correctly kept its
  zero-dependency status (binds the Docker socket directly, no registered-service route).
- **Real restore tests for the remaining 10 services** — actual `docker compose build && up -d`
  from git HEAD for the 4 app containers (not just a restart), each verified with an independent
  functional check; `docker compose up -d --force-recreate` for the monitoring stack + watchtower,
  verified via real health probes and (for the monitoring 3) confirmed the actual scrape/log
  relationship survived the recreate. One gap caught mid-verification (Prometheus's restore-test
  recording call was missed, backfilled); one transient false-positive correctly diagnosed as
  `healthScheduler` catching the frontend mid-rebuild, not a real bug.
  **Final: all 11 services `recoverable` tier, avg score 94/100** (up from 70 at start of day).
- **External infra dependencies registered (commit `5dd586e`)** — 4 genuinely new externals
  (Keycloak, PowerDNS API, Caddy Admin API, Proxmox) that `privatenexus-backend`'s env vars
  reference but that were never in the service registry. Verified each live: Keycloak/PowerDNS
  healthy; Proxmox correctly `down` (real CS-471548 outage); **Caddy Admin API found unreachable
  because the Gateway's own Caddyfile has `admin off`** — a deliberate security choice, not a bug
  (confirmed by ruling out a network-path problem first). Recorded as a `health_check_required`
  exception. Wrote 4 more runbooks pointing at this same CLAUDE.md's real sections rather than
  duplicating documentation. **Final: 0 violations across all 15 services.**
- **⚠ Emergency board audit — a real production incident, self-caused (commits `d5fb4f2`,
  `ab0e344`)**: while wiring up `maintenance.enable`'s unenforced cooldown policy (same class as
  `emergency.stop-all` earlier), found `MAINTENANCE_FILE` lived at `/tmp/...` (ephemeral, vanishing
  on every redeploy). Attempting to move it to the standard `app/backend/data/` convention **crashed
  the backend** — unhandled `EACCES` on an unguarded top-level `mkdirSync` (`/app` is `root:root`
  755, container runs as non-root UID 1000), a real ~1-minute outage (`/api/*` 502). Reverted
  immediately, confirmed recovery, disclosed the mistake directly. Checking for the same pattern
  found it affected **all 8** modules writing to `app/backend/data/` — `drafts.js`/`fileBackups.js`
  also hardcoded a `/root/privatenexus/...` path that only exists on the Gateway, never inside any
  container. This meant **the Files board's live file edits could never actually save, in any
  deployment, until this was found** (`GET /api/files` had been silently 500ing the whole time).
  Fixed properly this time: `Dockerfile` now `chown`s `/app/data` at build time (root, before UID
  1000 ever touches it); portable `__dirname`-relative paths in the two hardcoded modules. Tested in
  an isolated throwaway `--user 1000` container before any live redeploy.
- **Files board re-audit, clean** — remaining modules (`restoreTargeting.js`, `restorePlanner.js`,
  `restoreRollbackAdvice.js`, `fileValidator.js`) all solid; live-verified the whole board end to end.
- **Dependencies board (commit `43b50db`)** — `restore-chain` built a full Kahn's-algorithm topo
  sort whose result was never used (a second, simpler BFS built the actual response) — dead code,
  every call silently did the same graph traversal twice. Removed ~50 dead lines, verified live.
- **Catalogue board (commit `fa160ac`)** — 2 bugs: tag search compared lowercased query against raw
  (non-lowercased) tags, dormant today but a real bug waiting for a mixed-case tag; and the "+ Add
  to Registry" category pre-fill passed invalid values (`"media"`/`"productivity"`/`"finance"`) for
  **20 of the catalogue's 52 apps** — remapped to the valid `"personal"` category.
- **⚠ Inventory/crash-risk sweep (commits `12397bb`, `3268eb5`)** — `DELETE /workspaces/:id` was the
  only one of 14 routes in `services.js` with zero `try/catch`, and with no global
  `unhandledRejection` handler in `server.js`, any thrown error there would have **crashed the
  entire backend**, not just failed one request. Prompted a full route-file sweep (route count vs.
  `try{` count) that found the same class, worse, in `discovery.js`: **5 of 9 routes** had zero
  error handling, including `POST /ingest` — the automated hourly discovery-agent's actual
  production pathway, meaning any transient DB hiccup on any of the 24 daily runs would have crashed
  the backend. Fixed all 5, verified live by triggering the real systemd timer end-to-end.
- **Alerts board (commit `10496f6`)** — the "Node down" Prometheus query (`up{job=~".*-node"}`)
  required the job label to *end with* `-node`, but pn-prometheus's real job is named
  `node-exporter` (ends `-exporter`) — could never match, structurally, confirmed against the raw
  API. Fixed to `.*node.*`, then proved the whole path live: stopped node-exporter, confirmed a real
  alert fired, restarted, confirmed it cleared. The other 2 queries return nothing for a genuine
  infra-absence reason (no alerting rules/Blackbox exporter on pn-vps) — left honest, not faked.
- **Logs board** — genuinely clean, all 3 routes properly try/catch'd, LogQL injection guards hold,
  the "legacy" single-container route confirmed still used by the Stacks board, not dead code.
- **Metrics board (commit `c0479cd`)** — no crash risk, but the Home board's "System Overview"
  section (unqualified CPU/Memory/Storage labels) was actually only the backend *container's* own
  usage, sitting directly above a genuinely separate, real fleet-wide "Fleet" section — a reasonable
  reader would assume both were host-wide. Relabeled to "Backend Container" with a pointer to Fleet.
- **Activity board (commit `fe648c8`)** — `from_ts`/`to_ts` passed straight into `new Date()` with
  no validity check; a malformed value became Postgres's literal-string rejection, surfaced to the
  client as a misleading generic "Service unavailable" instead of the real client-input problem.
  Added the same validation `since_id` already had.
- **Admin board (commit `e93d88b`)** — `GET /api/admin/backup` was returning **entirely fabricated**
  data: wrong tool name, a "QNAP NAS (Tailscale)" destination that has never existed anywhere in
  this infrastructure, a fabricated "Wasabi EU-Central-1" tier (HoT has only ever used Hetzner
  Storage Box + B2), wrong schedule, and no tier for the real pn-vps DB backup chain. This closed the
  full board-by-board sweep. Replaced with the real, documented Backup Architecture table content.

## 2026-07-24 — real production regression + 2 UI bugs from hands-on testing

- **⚠ Real production regression, self-caused and fixed same session**: PowerDNS API went
  unreachable from the whole VLAN mesh after `wg0` (the old, dead bare-metal tunnel) was torn down
  during the hot-bm-nl vmbr0 build. PowerDNS's compose bind was the specific IP `10.10.0.1:8081` —
  which was literally the Gateway's own address *on the wg0 interface itself*; deleting wg0 deleted
  that address, leaving a phantom bind (process alive, nothing routable to it). Caught only because
  Mr. Byrne was doing real hands-on UI testing and saw PowerDNS show down on the Dashboard. Fixed
  non-destructively: added `10.10.0.1/32` to `lo` via a new systemd oneshot unit
  (`powerdns-loopback-ip.service`, `Before=docker.service`) rather than reviving wg0 or changing
  PowerDNS's bind config. Verified end-to-end from hot-pn over wg3.
- **Real bug found only via browser testing (commit `c8115d7`)** — Service Detail view threw an
  uncaught `ReferenceError` on a bare, never-defined `userRole` variable, on **every single service
  detail open, for every service, 100% of the time** — no source-read or curl check had caught it;
  extensive static analysis of the data had wrongly assumed it was an edge case tied to unusual
  field values before the real browser console error was checked. Fixed by replacing all 5
  occurrences with the existing `can(minRole)` helper.
- **Exception-blindness pattern, found twice more (commits `4088bae`, `84d4215`)** — Governance's
  `evaluateViolations()` was the *only* place in the app that actually queried `policy_exceptions`;
  the Inventory badges, the "no backup" pill, and the Service Detail policy line all used a bare
  `svc.backup_policy === "none"` check with no awareness an exception could exist — the same
  underlying fact read as "fine" on one board and "flag it" everywhere else. Fixed by adding
  `backup_policy_exempt`/`health_check_exempt` to `GET /api/services` and wiring all display spots
  to check it. The same pattern recurred a third time **inside Governance's own** "Restore Readiness
  per Service" table, which built its ✓/✗ columns from raw booleans, bypassing
  `evaluateViolations()` entirely despite sitting on the same board.
  **Lesson for future audits of this app: whenever a rule has an exception mechanism, check that
  literally every UI surface displaying that rule's data actually consults the exception table — not
  just the one board whose whole purpose is evaluating rules, and not even assuming a board is safe
  just because it's the "real" evaluator's own board.**
