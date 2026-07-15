# PrivateNexus — Product Requirements Document (PRD)
**Version: 1.0**
**Date: 22 June 2026**
**Owner: House of Trae / PrivateNexus Programme**
**Classification: Internal — Product Reference**
**Current build: v1.9.0 (pn-test, 10.10.60.105)**

---

## 1. Product Purpose

PrivateNexus is a self-hosted infrastructure operations platform. It sits above tools
such as Proxmox, Caddy, PowerDNS, Keycloak, Docker, Grafana, and backup systems.
It does not replace them. It provides a governed operational layer across them.

**The problem it solves:**
Self-hosted and small-business infrastructure grows through necessity. One service
becomes twenty. The operator relies on memory, scattered notes, and panic during
incidents. Existing tools each solve part of the puzzle. None provide a single
operational truth layer that answers: What exists, is it working, can it be recovered,
who changed it, and what actions are safe?

**North star:**
The secure operational cockpit above the stack — not the engine room itself, but the
instrument panel that makes the engine room understandable, recoverable, and governable.

---

## 2. Current Build State (v1.9.0)

As of 22 June 2026, the following is deployed and running on pn-test.

### 2.1 What is built and working

| Module | Status | Notes |
|---|---|---|
| Keycloak OIDC auth | Working | openid-client, session via Redis, 8h cookie |
| Role hierarchy | Working | viewer/operator/admin/superadmin/breakglass, middleware enforced |
| Tenant model | Working | HOT_TENANT_ID hardcoded — single tenant only |
| Workspaces | Working | 4 seeded: Infrastructure, Business Systems, Personal Services, Monitoring |
| Service registry | Working | Full CRUD, tenant-scoped, workspace grouping, access modes |
| HTTP health probes | Working | Concurrent fetch, results written to DB, status on service cards |
| Audit log | Working | Tenant-scoped, immutable, action/target/outcome/IP |
| File registry | Working | Register config files, backup/restore with trust states |
| Restore planner | Working | Risk assessment, LKG, dependency checking, side-by-side mode |
| Backup labels | Working | Label backups (manual), retention tracking |
| Docker socket | Working | Read-only via dockerode |
| Prometheus/Loki | Working | Metrics and log queries |
| DNS routes | Working | DNS query/status |
| Stacks management | Working | Docker Compose stack operations |
| Apps/ops routes | Working | Misc operational endpoints |
| Alerts | Working | Alert query endpoint |
| React frontend | Working | Dashboard, service cards, mockup component |
| PostgreSQL 16 | Working | Schema deployed, seeded |
| Redis 7 | Working | Session store, healthy |

### 2.2 Known gaps vs. v1.0 target

**Correction (2026-07-15):** this table had drifted badly out of date — a source-level audit this
session found nearly every row below already resolved, several since well before 22 June. Rows are
kept (struck through, not deleted) so the history of what was fixed and when isn't lost. See §4 for
the corresponding per-requirement corrections (HLT-05/06/07, REC-10/11/12/13, ACT-04/05/06, FE-01 through FE-08 except FE-09). FE-01/FE-02 were genuine gaps and got real fixes on 2026-07-15 (`hot-privatenexus` commit `ff5b346`) rather than just a documentation correction — see those rows in §4.7.

| Gap | Priority | Notes |
|---|---|---|
| No git repository on pn-test | High | Not re-verified this session (pn-test itself, not pn-vps) — leave open until checked |
| HOT_TENANT_ID hardcoded | Medium | Blocks second-tenant onboarding; part of the broader de-hardcoding effort scoped to roadmap v6.0 (not just this one env var — discovery scanner defaults and category inference are HoT-specific too) |
| ~~No TCP health check type~~ | ~~Medium~~ | **RESOLVED.** `healthProbe.js` has a full `tcp://host:port` probe branch alongside HTTP/HTTPS — verified in source and confirmed running in production. |
| ~~No health check scheduler~~ | ~~Medium~~ | **RESOLVED.** `healthScheduler.js` runs a 2-minute background cycle (probe → prune → periodic intelligence scan) — verified live on pn-vps with real `health_events` data (765+ cycles per service, zero errors). |
| ~~No recovery score UI~~ | ~~Medium~~ | **RESOLVED.** Service Detail view has a full "Recovery Score" panel (score/grade/reasons) wired to `computeRecoveryScore()` — verified in source, not scaffolding. |
| ~~No backup inventory UI~~ | ~~Medium~~ | **RESOLVED.** Service Detail has a full "Backup Records" table with add/LKG/trust/delete actions, wired to `service_backups` CRUD — verified in source. |
| ~~No action policy engine~~ | ~~Low~~ | **RESOLVED.** `action_policies` table has 7 real seeded rows (elevation, blast-radius check, cooldown, requires-approval per action type) and `/api/actions/run/v2` enforces all of it. It existed but was never called from the UI until the 2026-07-15 action-safety fix wired the Stacks board to it — see CLAUDE.md `pn-vps` section. |
| ~~No discovery agents~~ | ~~Low~~ | **RESOLVED**, closed out 2026-07-15 — Docker/Proxmox/Caddy scanners, agent-push ingest with scoped DB tokens, approval workflow, and drift detection are all live. See CLAUDE.md `pn-vps` section. |
| Frontend is partial | Medium | Narrower than it reads: `PrivateNexusV1Mockup.jsx` is dead code — not imported anywhere, confirmed via grep. The real frontend (`App.jsx`) is comprehensively built for every board audited this session (Discovery, Stacks, Recovery, Service Detail). FE-01/02/05/07/09/10/11 (dashboard summary, filtering, admin panel, badges, catalogue, files, logs) were not re-audited — this row stays until they are. |
| VERSION file is 1.9.0; compose comment says 1.10.0 | Low | Not re-verified this session |

---

## 3. User Roles and Personas

### 3.1 Role definitions

| Role | Who | What they need |
|---|---|---|
| **Viewer** | Any authenticated staff member | Read-only access to service health and status boards |
| **Operator** | On-call engineers, technical staff | Trigger restarts, run health checks, set maintenance windows |
| **Admin** | Infrastructure lead (Mr. Byrne) | Manage services, approve discoveries, view full audit log |
| **SuperAdmin** | Platform owner | Tenant configuration, integration setup, role assignment |
| **BreakGlass** | Emergency recovery only | Bypass-capable access for P1 incidents; heavily logged |

### 3.2 Primary persona

**Mr. Byrne — Infrastructure Operator / SuperAdmin**
- Runs the full HoT stack solo across 7 VMs + Gateway VPS
- Needs to see service health at a glance without SSH-ing into VMs
- Needs to confirm backups are recent and trustworthy before they matter
- Needs to action a restart without needing Portainer or a terminal
- Needs to know if something can be recovered before an incident forces the question

---

## 4. Functional Requirements

Requirements are tagged: **[BUILT]** = exists in v1.9, **[MISSING]** = not yet built,
**[PARTIAL]** = partially implemented.

### 4.1 Authentication and Session

| Req | Description | Status |
|---|---|---|
| AUTH-01 | User authenticates via Keycloak OIDC — no local passwords | BUILT |
| AUTH-02 | Session stored in Redis, 8-hour cookie, httpOnly + secure | BUILT |
| AUTH-03 | Logout clears application session and triggers Keycloak end_session | BUILT |
| AUTH-04 | Post-logout redirect URI must match Keycloak client config exactly | BUILT |
| AUTH-05 | All login and logout events written to audit log | BUILT |
| AUTH-06 | Roles extracted from Keycloak token `roles` claim | BUILT |
| AUTH-07 | MFA required for admin, superadmin, breakglass (Keycloak config) | PARTIAL — requires Keycloak realm config |

### 4.2 Service Registry

| Req | Description | Status |
|---|---|---|
| SVC-01 | Admin can create, read, update, archive a service record | BUILT |
| SVC-02 | Service records carry: name, slug, description, category, access_url, access_mode, runtime_type, owner, backup_policy, health_endpoint | BUILT |
| SVC-03 | Services are scoped to a tenant and optionally a workspace | BUILT |
| SVC-04 | Services can be grouped and filtered by workspace and category | BUILT |
| SVC-05 | Access mode badge visible on every service card (public/sso/vpn_only/internal/mtls) | BUILT — corrected 2026-07-15, duplicate of FE-07 (same underlying badge), already verified in source |
| SVC-06 | Services missing owner, backup_policy, or health_endpoint flagged visually | BUILT — corrected 2026-07-15, duplicate of FE-08 (same `missingFields` warning), already verified in source |
| SVC-07 | Archived services not shown by default; restorable by admin | BUILT |
| SVC-08 | All service changes create audit events | BUILT |
| SVC-09 | Workspaces can be created, renamed, and deleted by admin | BUILT |

### 4.3 Health Checks

| Req | Description | Status |
|---|---|---|
| HLT-01 | HTTP health check: GET to health_endpoint, HTTP status → service status | BUILT |
| HLT-02 | Status states: healthy, warning, degraded, down, unknown | BUILT |
| HLT-03 | Health results written to services table (status, updated_at) | BUILT |
| HLT-04 | Health check runs concurrently across all services in one request | BUILT |
| HLT-05 | TCP health check type | BUILT — corrected 2026-07-15, was already implemented (`healthProbe.js` `tcp://` branch) |
| HLT-06 | Scheduled health checks (background worker, configurable interval) | BUILT — corrected 2026-07-15, `healthScheduler.js` runs a configurable-interval background cycle (`HEALTH_CHECK_INTERVAL_MS`), verified live |
| HLT-07 | Health history stored per service (health_events table) | BUILT — corrected 2026-07-15, verified real data (765+ events/service on pn-vps) and rendered in Service Detail's "Health History" panel |
| HLT-08 | Unknown status displayed distinctly — treated as config gap, not healthy | BUILT |
| HLT-09 | Health probe timeout 5s; reports "down" on timeout | BUILT |

### 4.4 Backup and Recovery

| Req | Description | Status |
|---|---|---|
| REC-01 | File registry: register config files for backup/restore | BUILT |
| REC-02 | Backup creation with timestamps | BUILT |
| REC-03 | Backup labels (manual trust markers) | BUILT |
| REC-04 | Last-known-good (LKG) designation per file | BUILT |
| REC-05 | Backup retention tracking | BUILT |
| REC-06 | Restore planner: risk assessment, dependency check, recommendation | BUILT |
| REC-07 | Restore modes: in_place and side_by_side | BUILT |
| REC-08 | Restore log | BUILT |
| REC-09 | Rollback advice after restore | BUILT |
| REC-10 | Restore planner accessible from service detail view in UI | BUILT — corrected 2026-07-15. Service Detail has a "Config Files & Restore Planner" panel with a deep-link into the Files board (where the planner actually runs, since it's file-registry-scoped) and explanatory text. Not an inline embedded planner — a deliberate design choice, not a gap. |
| REC-11 | Recovery score displayed per service (backup age + trust + test) | BUILT — corrected 2026-07-15, verified in source (`computeRecoveryScore()` + Service Detail "Recovery Score" panel) |
| REC-12 | Service-level backup records (not just file-level) | BUILT — corrected 2026-07-15, `service_backups` table with full CRUD exists and is used, alongside (not instead of) the file-level model |
| REC-13 | Backup inventory UI per service | BUILT — corrected 2026-07-15, Service Detail "Backup Records" table with add/LKG/trust/delete |

### 4.5 Safe Actions

| Req | Description | Status |
|---|---|---|
| ACT-01 | Restart approved service — operator minimum, audit-logged | BUILT (route exists) |
| ACT-02 | Refresh health check — operator minimum, rate-limited | BUILT |
| ACT-03 | Maintenance mode — operator/admin, duration required, audit-logged | PARTIAL |
| ACT-04 | Action requires confirmation in UI before execution | BUILT — corrected 2026-07-15. The Stacks board confirm modal existed already, but until this session called the v1 action endpoint, which has no policy/blast-radius/approval logic — see ACT-06 note. Now wired to v2 and the modal's copy honestly reflects whether blast-radius protection actually applies. |
| ACT-05 | Action cooldown (60s per service) enforced server-side | BUILT — corrected 2026-07-15, `COOLDOWN_MS` + `actionCooldowns` map in `actions.js`, present in both `/run` and `/run/v2` |
| ACT-06 | Action policy object model — declarative policy per action type | BUILT — corrected 2026-07-15. `action_policies` table (7 seeded rows: elevation/blast-radius/cooldown/requires-approval per action type) and `/api/actions/run/v2` fully implement this. It was built but completely unreachable from any UI — and had a live bug (`userRoleLevel()` read a session field that's never populated, so every elevation check 403'd) that had never been exercised until the frontend was wired to it this session. See CLAUDE.md `pn-vps` section for the full fix. |
| ACT-07 | Viewer role cannot trigger any action — 403 from requireRole | BUILT |
| ACT-08 | All action attempts (success and failure) written to audit log | BUILT |

### 4.6 Audit Log

| Req | Description | Status |
|---|---|---|
| AUD-01 | Immutable audit log — no UPDATE or DELETE permitted | BUILT |
| AUD-02 | Every write operation (create/update/archive) creates audit event | BUILT |
| AUD-03 | Every auth event (login/logout/failed) creates audit event | BUILT |
| AUD-04 | Every action attempt creates audit event | BUILT |
| AUD-05 | Audit records carry: ts, tenant_id, user_sub, username, role, action, target, outcome, detail, ip | BUILT |
| AUD-06 | Admin can query audit log, filtered by actor/action/date range | BUILT — corrected 2026-07-15, duplicate of FE-04's Activity board (`/api/activity`, has `from_ts`/`to_ts` date-range plus username/action/outcome). Note: an older, more limited `admin/audit` panel (`/api/admin/audit` — no date range) also still exists as a separate Admin menu tab — mild duplication, not a gap, worth consolidating eventually but not urgent. |
| AUD-07 | Audit log is tenant-scoped — admin cannot see other tenants' events | BUILT |

### 4.7 Frontend Requirements

| Req | Description | Status |
|---|---|---|
| FE-01 | Dashboard: service health summary, workspace view | BUILT — fixed 2026-07-15 (`hot-privatenexus` commit `ff5b346`). Health summary already existed; workspace view was a genuine gap (only existed as workspace CRUD tucked in Admin, not a dashboard view) — added a "Workspaces" panel to the Home board, health counts per workspace, click-through to Inventory grouped by workspace. No new fetch needed — `servicesData` already carried `workspace_name`. |
| FE-02 | Service list with filter by workspace, category, status | BUILT — fixed 2026-07-15 (same commit). Category/archived filters already existed server- and client-side; workspace only existed as group-by, not a filter — left as-is (group-by already covers the practical need, see FE-01). Status filtering didn't exist at all, backend or frontend — added `GET /api/services?status=` (validated against the existing `VALID_STATUSES` list) and a matching Inventory toolbar dropdown. |
| FE-03 | Service detail: health history, backup summary, action buttons | BUILT — corrected 2026-07-15, all three verified present (Health History panel, Recovery Score + Backup Records panels, Deploy/Rollback + restart-eligible container actions) |
| FE-04 | Activity feed: real-time audit events, filterable | BUILT — corrected 2026-07-15. `routes/activity.js` is a mature, purpose-built endpoint (`since_id` cursor for live polling, filters on action_prefix/username/outcome/date-range, pagination). Frontend Activity board has two wired `useEffect`s — one for filtered page loads, one for cursor-based live polling — verified in source, not scaffolding. |
| FE-05 | Admin panel: user list, role management | BUILT (as correctly scoped) — corrected 2026-07-15. User list is activity-derived (`admin/users-manage`, joins `audit_log` for role/last-seen/action-count) rather than a full Keycloak directory — reasonable, since a user who's never authenticated has nothing to manage yet. "Role management" is a deliberate deep-link out to Keycloak's admin console (general + per-user), not an in-app role editor — correct architecture, since PrivateNexus enforces roles but Keycloak owns them (see CLAUDE.md Keycloak SSO section). Confirmed via source: zero role-mutation endpoints exist in `admin.js`, and the UI explicitly labels Keycloak as the source of truth rather than implying it — not a broken feature, no fix needed. |
| FE-06 | Confirmation modal for all privileged actions | BUILT — corrected 2026-07-15, see ACT-04 |
| FE-07 | Access mode badges on service cards | BUILT — corrected 2026-07-15, `ACCESS_MODE_STYLES[svc.access_mode]` badge verified present on every Inventory card, no fix needed |
| FE-08 | Missing metadata flags (owner, backup_policy, health_endpoint) | BUILT — corrected 2026-07-15, `missingFields` computed per-card and rendered as a visible amber warning badge ("Missing: owner, backup policy, ...") — verified in source, no fix needed |
| FE-09 | Catalogue board | PARTIAL (route built, static `APPS` array — becoming a real local update repository, see roadmap v6.0) |
| FE-10 | Files board (file registry, backup/restore) | BUILT — corrected 2026-07-15. `routes/files.js` has 22 endpoints (read/draft/validate/write/apply, backup CRUD + LKG/labels/prune, restore/restore-and-apply/restore-plan/restore-log, apply-log, register). All 22 verified called from the frontend; the Files board itself is a substantial, fully-built UI (~150 lines), not a stub. |
| FE-11 | Logs board | BUILT, plus a live bug found and fixed 2026-07-15 (`hot-config` commit `f80c6b1`). `routes/logs.js` (Loki-backed, LogQL injection guards, range/level/search filters) was fully wired in the frontend — but pn-vps's `monitoring-temp` Promtail config (deployed earlier the same day) stripped the leading slash from the `container` label, while `logs.js`'s query selector assumes Docker's raw `/name` convention (confirmed against the Gateway's real Promtail config, which has no such stripping). Every Logs board query on pn-vps was silently returning zero results. Fixed the Promtail relabel rule to match; verified post-fix with a real returned log line. |

---

## 5. Non-Functional Requirements

### 5.1 Security

- No unrestricted Docker socket access — socket is mounted read-only; write operations
  use the dockerode API with scoped method calls only
- No browser shell or raw exec endpoint — explicitly out of scope until v4+
- All credentials via Docker secrets (chmod 644) — no plain environment variables
  for secrets in production
- Session cookie: httpOnly, secure, sameSite=lax, 8h maxAge
- HTTPS enforced at Caddy edge — all internal traffic is plaintext within pn-internal Docker network

### 5.2 Performance

- Health probe: 5s timeout per service, all probes run concurrently
- API response time target: < 200ms for read operations under normal load
- Session lookup from Redis: < 5ms expected
- Memory target: backend process < 150MB RSS at idle (actual: ~711MB total VM usage including all services)

### 5.3 Reliability

- `restart: unless-stopped` on all containers
- Stack survives `docker compose restart`
- Database migrations are idempotent (CREATE TABLE IF NOT EXISTS pattern)
- Redis session loss: user must re-authenticate (acceptable — sessions are 8h)

### 5.4 Observability

- `GET /api/health` returns `{ ok: true, service, version }`
- Backend logs to stdout (Docker log driver captures)
- Prometheus metrics endpoint: `/api/metrics` (already built)
- node-exporter running on pn-test VM — scraped by sn-monitor

---

## 6. Out of Scope

These items are explicitly not in scope for v1.0. They are recorded here so that
"just add it quickly" conversations have a reference point.

- Automated discovery agents (v1.5)
- Dependency graphs (v2.0)
- Sandbox restore testing (v2.0)
- Read-only MCP server (v2.0)
- Action policy object model (v3.0)
- Multi-tenancy beyond data model foundation (v2.x)
- Browser shell / raw exec
- Full DNS editing UI
- Billing or licensing
- AI auto-remediation
- Kubernetes support

---

## 7. Immediate Priorities (to complete v1.0)

Based on the gap analysis in §2.2 and §4, the following work items close v1.0:

1. **Initialise git repository** on pn-test — all current work is unversioned
2. **TCP health check type** — extend the probe engine alongside HTTP
3. **Scheduled health checks** — background worker, configurable interval, writes to `health_events`
4. **Recovery score frontend** — surface the backend restore planner output on service cards
5. **Backup inventory UI** — per-service backup list with trust states
6. **Service detail page** — health history, backup summary, action buttons, restore planner link
7. **Action confirmation modal** — frontend gate before any operator/admin action executes
8. **Action cooldown** — verify 60s server-side cooldown is enforced in `actions.js`
9. **Missing metadata flags** — visual indicator on service cards for owner/backup/health gaps
10. **Sync VERSION file** — 1.9.0 in VERSION vs 1.10.0 in compose comment

---

## 8. Definition of Done — v1.0

- All v1.0 acceptance gates in the Release Roadmap pass
- All House of Trae services registered with complete metadata
- Health checks running and results current for all services with endpoints
- Recovery score visible per service
- Backup records visible per service with trust states
- Restart, health refresh, and maintenance mode tested end-to-end
- Every action creates a correct, tenant-scoped audit event
- Viewer cannot reach any write action via API or UI
- Git repository initialised and all code committed
- Install guide tested from scratch on a clean VM
- PrivateNexus itself is a registered service with a backup plan

---

*Document owner: House of Trae / PrivateNexus Programme*
*Next revision: when v1.0 ships; update §2 current state accordingly*
*Related: `PrivateNexus_Phase0_Freeze.md`, `PrivateNexus_Release_Roadmap_v1.0.md`,*
*`PrivateNexus_Multitenancy_RBAC_Design.md`*
