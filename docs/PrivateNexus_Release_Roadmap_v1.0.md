# PrivateNexus — Detailed Release Roadmap
**Version: 1.7**
**Date: 30 June 2026 (corrected/updated 22 July 2026 — see notes below)**
**Owner: House of Trae / PrivateNexus Programme**
**Classification: Internal — Strategic Planning**
**Covers: v0.8 → v6.0**

**22 July 2026 addition (v1.7):** v6.0's full multi-tenancy work landed and deployed (backend
per-request tenant resolution across all 12 route/background-job files, Tenant CRUD API,
SuperAdmin console frontend, per-tenant discovery-scanner config) — four of the acceptance gate's
checkboxes moved from open to checked, see the gate itself for detail and commit references. No
scope change, just marking real progress.

**22 July 2026, second pass (later same day):** reconciled the rest of the acceptance gate against
what the 2026-07-16 governance/recovery/backup work actually landed, rather than trust the prior
unchecked state. Three more items verified done and checked (restore-test-as-proven-signal,
PN self-registration, PN's own B2 backup) — see the gate for detail and evidence. Two items were
checked *against the actual code* and confirmed genuinely not done, not just unstarted busywork:
maintenance-window Ntfy suppression is explicitly a no-op today (the code's own comment says so),
and the GitHub mirror's `LICENSE` file is empty — no scope change, just correcting the record so
these don't get assumed-done later.

**22 July 2026, third pass (later still):** ran a real, non-simulated two-user RBAC test (a fresh
disposable `viewer`-role Keycloak account through the actual OIDC browser flow, compared against
the standing `tristian` superadmin session) rather than infer from code review alone. Closed 8 more
long-stale checkboxes across the old Sprint 4 gate and the v6.0 gate's RBAC item with direct
evidence. Found one real gap while testing — `requireRole()` never audited *rejected* privileged
attempts, only successes — fixed live (`hot-privatenexus` commit `2aa82fb`) and re-verified.
Left one genuine open question rather than guess: whether `action_policies`/`policy_rules` being
unscoped-by-tenant (shared globally across all tenants) is deliberate platform design or a real
multi-tenancy gap — needs Mr. Byrne's call, not a unilateral fix. Test accounts deleted from
Keycloak afterward; the real audit_log rows they generated were left in place as evidence.
**Resolved same session**: Mr. Byrne confirmed the global scoping is deliberate (see the gate).

**22 July 2026, fourth pass (same day):** the RBAC-testing momentum surfaced a wider question —
is `recordAudit` coverage actually complete everywhere, not just in `requireRole`? Ran a file-by-
file sweep (mutating-route count vs. `recordAudit` count per route file) across all 19 backend
route files. Found two more real gaps, both fixed and pushed (`hot-privatenexus` commit `f019135`):
`dns.js`'s `POST`/`DELETE /zones/:zone/records` — which write directly to the real production
PowerDNS instance managing all 13 live HoT zones — had **zero** audit coverage at all (success,
failure, or the locked-SOA/NS-record rejection); and `intelligence.js`'s signal ack/resolve and
proposal dismiss actions had none, unlike their sibling routes in the same file. Verified the DNS
fix live via the safe locked-record-rejection path (never touches real PowerDNS data). This isn't
claimed as proof of *zero remaining gaps* — it's evidence toward the "audit log verified for all
v1.0 action types" commercial proof point, not a completion claim; every route file now shows a
mutating-route-count/recordAudit-count match, but that's a coverage heuristic, not a formal audit.

**21 July 2026 corrections:**
1. Sprint 1 and the Dependencies/Risks table still described the backend as Go, predating the
   22 June 2026 Phase 0 freeze that locked it to Node.js (Express v4, ESM). Both references
   updated to match `PrivateNexus_Phase0_Freeze.md`, the authoritative source for this decision.
2. v5.0's acceptance gate item 4 ("autonomous execution runs without errors for 30 consecutive
   days") was marked done on a claim that live data didn't support — see the gate itself for
   detail. Reopened, clock genuinely restarted 2026-07-21, gate close date moved to 2026-08-20.

No feature scope changed by either correction — both are accuracy fixes to what was recorded as
already true.

**21 July 2026 addition (v1.6):** ran a market scan of comparable self-hosted ops/dashboard and
DR tools against current roadmap scope — see "Market Positioning Check" under "What Happens
After v6.0". Added one new v7.0 candidate (in-product notifications); everything else found was
already covered by existing scope or deliberately out of scope, and is recorded as such rather
than silently dropped.

---

## How to Read This Document

Each release has a theme, deliverables, sprint breakdown (near-term releases only),
acceptance gate, and commercial relevance. Sprints are two weeks each. Versions
after v1.5 have defined scope but no sprint breakdown — that detail is written when
the preceding release ships.

**Roadmap rule:** A feature not listed under a version goes to backlog. Adding scope
to a release requires updating this document. "We'll fit it in" is not a plan.

**Phase 0 freeze:** Stack decisions are closed. See `PrivateNexus_Phase0_Freeze.md`.
Do not re-open backend framework, database, or identity provider discussions.

---

## Version Summary

| Version | Theme | Status | Target |
|---|---|---|---|
| v0.8 | Recovery foundations | Shipped | — |
| v0.9 | Identity, tenancy, RBAC | Shipped | — |
| v1.0 | Operations console (MVP) | Shipped | — |
| v1.5 | Discovery | Shipped | — |
| v2.0 | Dependency intelligence | Shipped | — |
| v2.5 | Governance engine | Shipped | — |
| v3.0 | Controlled orchestration | Shipped | — |
| v4.0 | Recovery intelligence | Shipped | — |
| v5.0 | Autonomous operations | Gate closes 2026-07-30 | — |
| v6.0 | Open platform | Planned | Post-gate |

---

## v0.8 — Recovery Foundations

**Theme:** Prove the recovery differentiator early. Before users see a dashboard,
the backup model and recovery score logic must exist and be testable. This makes
every subsequent version commercially credible, not just pretty.

**Why this comes before v0.9 identity:** Recovery logic is pure domain code — no
auth dependency. It can be designed, tested, and validated in isolation. Shipping
it here means v1.0 inherits proven recovery intelligence rather than bolting it on.

### Deliverables

**Backup data model**
- `backups` table: service_id, backup_id, created_at, source, storage_target, encrypted,
  checksum, trust_state, retention_class, restore_tested_at, validation_result
- Trust states: `trusted`, `untrusted`, `expired`, `failed`, `unknown`
- Retention classes: `daily`, `weekly`, `monthly`, `manual`, `last-known-good`

**Recovery score engine (v1 — explainable heuristic)**
- Score computed from six signals: backup age, backup trust, restore tested, dependencies
  known, documentation present, secrets available
- Score presented as a named tier: `Recoverable`, `At Risk`, `Unproven`, `Blocked`
- Score is always explainable — each signal shows its contribution with a plain reason
- No magic percentages. No progress bars pretending to be science.

**Restore planner (dry-run only)**
- Input: a service ID
- Output: ordered restore sequence, risk flags, blockers, estimated data loss window
- Does not execute anything — generates a plan document
- Requires: dependency map (can be manual v0.8), backup inventory, secrets checklist

**Seed data**
- House of Trae service catalog seeded manually (all services from CLAUDE.md)
- Backup records seeded from known backup architecture (Proxmox PBS, B2, Wasabi)
- Recovery scores computed for all seeded services — immediately shows real gaps

### Sprint Breakdown

**Sprint 1 — Foundation**
- Repository structure per Build Guide §4 layout
- Docker Compose baseline: Node.js (Express v4, ESM) API, React frontend, PostgreSQL 16, Redis 7
- Database schema migrations (SQL-based)
- `GET /health` returning `{ ok: true, version: "0.8.0" }`
- All core containers healthy in `docker compose ps`
- Postgres not bound to 0.0.0.0
- Stack survives `docker compose restart`

**Sprint 2 — Recovery model**
- Backup entity CRUD (API only, no auth yet — local dev token)
- Recovery score engine: all six signals implemented and unit-tested
- Restore planner: dry-run output for a given service_id
- Seed script: House of Trae services + backup records from known architecture
- Unit test coverage: recovery score logic, trust state transitions, planner output

### Acceptance Gate

- [ ] `GET /health` returns ok
- [ ] All six recovery score signals return correct values for seeded data
- [ ] Restore planner produces a dry-run plan for at least three seeded services
- [ ] Recovery score for every seeded service is explainable (no black-box output)
- [ ] At least one service scores `Blocked` (flags a real gap in the estate)
- [ ] Unit tests pass for recovery engine and planner
- [ ] Database migrations apply cleanly from a fresh schema

### Commercial Relevance

Proves the flagship differentiator exists and works before a single user logs in.
Recovery intelligence cannot be a UI claim — it must be a tested code path.

---

## v0.9 — Identity, Tenancy, and RBAC

**Theme:** Make the app multi-user and multi-tenant before building any admin
actions. Doing actions before identity is how tiny dashboards become tiny disasters.

### Deliverables

**Keycloak integration**
- Realm `privatenexus` on auth.house-of-trae.com
- OIDC client: `privatenexus` (confidential, standard flow)
- Roles: viewer, operator, admin, superadmin, breakglass
- MFA required for admin, superadmin, breakglass
- Token claim: `roles` array

**Tenant and user model**
- `tenants` table: id, slug, name, created_at
- `users` table: id, keycloak_sub, email, display_name, tenant_id, role, last_login
- `tenant_memberships`: user_id, tenant_id, role_id, granted_at, granted_by
- Tenant 1 seeded: House of Trae (`slug: house-of-trae`)
- All existing seed data assigned tenant_id

**RBAC middleware**
- Every API route protected by Keycloak JWT validation
- Role extracted from token, checked against route policy
- Viewer cannot trigger any action endpoint
- Superadmin and breakglass routes require elevated role claim
- All auth events written to audit_events table

**Session management**
- Login via Keycloak redirect flow
- Logout clears application session and redirects to Keycloak end_session
- Session tied to Keycloak token lifetime
- Post-logout redirect URI registered correctly (see CLAUDE.md Keycloak gotcha)

**Workspace model**
- `workspaces` table: id, tenant_id, name, slug, description
- House of Trae workspaces seeded: Infrastructure, Business Systems, Personal Services, Monitoring
- All seeded services assigned to a workspace

**Audit log foundation**
- `audit_events` table: id, tenant_id, actor_id, actor_email, action, target_type,
  target_id, outcome, metadata (jsonb), created_at
- Immutable — no update or delete on audit_events
- Written for: every login, every logout, every privileged route attempt (success and failure)

### Sprint Breakdown

**Sprint 3 — Auth and tenancy**
- Keycloak realm and client provisioned
- JWT validation middleware on all routes
- `GET /me` returns current user with role and tenant
- Login and logout flows working end-to-end
- Tenant and workspace tables created and seeded
- All seed data migrated to tenant-scoped records

**Sprint 4 — RBAC and audit**
- Role-based route guards for all five roles
- Viewer blocked from action endpoints (403, logged)
- Audit event model and write path
- Activity feed endpoint: `GET /audit-events` (tenant-scoped, paginated)
- RBAC unit tests: all five roles against all route groups

### Acceptance Gate

- [x] User logs in through Keycloak — this whole gate was never checked despite being obviously true for a v1.9 app in daily use; verified fresh 2026-07-22 with a real end-to-end OIDC flow (see the v6.0 gate's RBAC entry for full detail)
- [x] Logout clears session — verified live 2026-07-22: called `/api/auth/logout` with a same-origin `Referer` on a real session, got the expected `302`, then confirmed the *same* cookie immediately returns `{"error":"Unauthenticated"}` from `/api/auth/me` — server-side `req.session.destroy()` genuinely fires, not just a client-side redirect
- [x] Roles visible to backend from token claims — `GET /api/auth/me` on the test viewer session returned `"roles": ["viewer", "offline_access", "uma_authorization"]` straight from `realm_access.roles`
- [x] Viewer role cannot reach any action endpoint — confirmed 403 on `POST /api/actions/run/v2`
- [x] Admin and superadmin routes return 403 for lower roles — confirmed on `POST /api/services` (admin) and `GET /api/tenants` (admin)
- [x] All login attempts (success and failure) create audit events — success confirmed (`auth.login`/`success`); failure confirmed by deliberately hitting `/api/auth/callback` with a bad `state` param — real credential failures happen inside Keycloak itself (has its own event log) before ever reaching the app, so "failure" at the app layer means a bad/expired/tampered callback, which was already fixed 2026-07-16 and re-confirmed live here
- [x] All privileged route attempts create audit events — **was false until today.** `requireRole()` only audited successes; fixed in `hot-privatenexus` commit `2aa82fb`, confirmed live (see v6.0 gate entry)
- [x] Tenant ID present on all tenant-owned records — 17 of 21 tenant-scoped tables have `tenant_id NOT NULL`. `audit_log` is nullable at the schema level but the app always populates it (`recordAudit`'s `HOT_TENANT_ID` fallback), fine in practice. `action_policies` and `policy_rules` have no tenant filter anywhere in the codebase, and `autonomous_policies` supports both global defaults and tenant overrides (`tenant_id IS NULL OR tenant_id=$1`) — **Mr. Byrne confirmed 2026-07-22 this is deliberate, not a gap**: House of Trae keeps action-cooldown/elevation and governance-rule control centrally for every tenant, including Professional customers, rather than letting each tenant configure its own security posture. Not planned to change; if that ever needs revisiting, `autonomous_policies`' existing `tenant_id IS NULL OR tenant_id=$1` pattern is the template to follow.
- [x] `GET /me` returns correct user, role, tenant — `authRouter.get("/me", ...)` exists and was exercised directly throughout today's test, returning correct `username`/`roles`/`tenant_id` for both test accounts

### Commercial Relevance

Required for any business use. Without this, PrivateNexus is a personal tool.
With this, it is a product that can be handed to a second person.

---

## v1.0 — Operations Console (MVP)

**Theme:** Minimum serious internal product. Service inventory, health dashboard,
backup visibility, safe restart, and a working activity feed. This is the version
that House of Trae relies on daily.

### Deliverables

**Service registry**
- Full CRUD for service records (all fields from Build Guide §8.1)
- Services grouped by workspace and category (business, personal, ops, admin, infra)
- Access mode badge on every service card: public, sso, vpn_only, internal, mtls
- Missing owner, backup policy, or health check flagged visually
- Service archive and disable (not delete — audit trail preserved)

**Health checks**
- HTTP and TCP check types
- Check configured per service (one or more)
- Background worker runs checks on schedule (configurable, default 60s)
- Status states: healthy, warning, degraded, down, unknown
- Unknown treated as a configuration problem, shown distinctly
- `health_events` table: service_id, check_id, status, checked_at, response_ms, detail
- Dashboard shows last check time, current status, trend (last 24h)

**Backup visibility**
- Backup records from v0.8 model now visible in UI
- Per-service backup inventory: trust state, age, retention class, validation result
- Recovery score displayed on every service card
- Restore planner dry-run accessible from service detail view

**Safe actions (v1 set)**
- Restart approved service (operator role minimum)
  - Service must be on the approved restart allowlist
  - Requires confirmation in UI
  - Creates audit event: actor, target service, timestamp, outcome
  - 60-second cooldown per service
- Refresh health check (operator role)
  - Rate-limited: once per 30 seconds per service
  - Creates audit event
- Enable / disable maintenance mode (operator/admin role)
  - Duration required (1h, 4h, 8h, 24h, custom)
  - Pauses health check alerting for the service
  - Creates audit event with actor and duration

**Activity feed**
- Real-time feed of audit events (WebSocket or polling, 10s interval)
- Filterable by: tenant, workspace, actor, action type, severity
- Persistent — all events since v0.9 retained

**React frontend — v1 UI**
- Dashboard: service health summary, recent alerts, recovery score overview
- Service list: filterable by workspace, category, access mode, health status
- Service detail: health history, backup inventory, recovery score breakdown, action buttons
- Activity feed page
- User settings (display name, session info)
- Admin panel: user list, role management (superadmin only)

### Sprint Breakdown

**Sprint 5 — Service registry**
- Service CRUD API and frontend
- Workspace grouping and category filtering
- Access mode badges
- Missing metadata flags (owner, backup policy, health check)
- Service detail page

**Sprint 6 — Health and recovery UI**
- Health check configuration per service
- Background worker for check execution
- Health events table and history graph
- Backup inventory UI (consuming v0.8 model)
- Recovery score displayed per service
- Restore planner dry-run accessible from UI

**Sprint 7 — Safe actions**
- Action policy evaluation engine
- Restart, health refresh, and maintenance mode actions
- Confirmation modal in frontend
- Cooldown enforcement
- Audit events for all actions
- Viewer blocked from action buttons

**Sprint 8 — Pilot hardening**
- All House of Trae services registered and health checks configured
- All backup records seeded and trust states verified
- Recovery scores reviewed for entire estate — gaps documented
- PrivateNexus itself added as a managed service (self-referential)
- Backup plan for PrivateNexus's own PostgreSQL and config implemented
- Load and restart testing
- Documentation: install guide, upgrade guide, runbook
- v1.0 release tag

### Acceptance Gate

- [ ] All House of Trae services registered with complete metadata
- [ ] Health checks running for all services with public or internal endpoints
- [ ] No service in `unknown` health state due to misconfiguration
- [ ] Backup records visible for all services with known backup coverage
- [ ] Recovery score displayed and explainable for every service
- [ ] Restart, health refresh, and maintenance mode actions work end-to-end
- [ ] Every action creates a correct audit event
- [ ] Viewer cannot reach any action in UI or API
- [ ] PrivateNexus itself is backed up and has a recovery score
- [ ] Upgrade from v0.9 tested with real data
- [ ] Install guide tested from scratch on a clean VM

### Commercial Relevance

Minimum viable internal product. The version House of Trae actually uses daily.
After v1.0 ships, the question changes from "does PrivateNexus work?" to
"does PrivateNexus solve real problems?" The answer should be yes, documented
with real incidents where it helped.

---

## v1.5 — Discovery

**Theme:** Reduce the manual burden of keeping the service registry accurate.
Automated discovery candidates, human approval workflow, and the beginning of
living infrastructure documentation.

### Deliverables

- Docker label discovery agent (reads running containers on approved hosts)
- Proxmox API integration (VM/LXC names, status, resource overview — read-only token)
- Caddy route discovery (reads Caddyfile or Caddy admin API for active routes)
- `discovery_candidates` table: raw discovered data, metadata completeness score,
  suggested workspace, status (pending, approved, rejected, merged)
- Admin approval workflow: review candidate, fill missing metadata, approve to registry
- Manual registry drift detection: flag registered services whose runtime no longer matches
- Completeness scoring: penalise candidates missing owner, backup policy, health check

### Sprint Breakdown

**Sprint 9 — Docker and Proxmox agents**
- Docker agent: connects to Docker socket on approved hosts, reads container labels,
  reports candidates to PrivateNexus API via scoped token
- Proxmox agent: reads VM/LXC list via Proxmox API (restricted token, read-only)
- Candidate ingestion endpoint: `POST /discovery/candidates`
- Candidate list in admin UI with completeness scores

**Sprint 10 — Caddy discovery and approval workflow**
- Caddy route discovery (admin API polling or Caddyfile parse)
- Approval workflow UI: review, enrich, approve/reject
- Approved candidates create service records with full audit trail
- Rejected candidates archived with reason

**Sprint 11 — Drift detection and agent hardening**
- Scheduled drift detection: compare registry against discovered state
- Drift alerts: services in registry with no matching runtime discovered
- Agent authentication: scoped JWT tokens, tenant-bound, expiry enforced
- Agent action separation: discovery agent cannot trigger control actions

**Sprint 12 — v1.5 release**
- Discovery running against full HoT estate
- All approval decisions audited
- Agent tokens rotated and documented in secrets store
- Discovery runbook written

### Acceptance Gate

- [ ] Docker agent discovers all running containers on pn-test and sn-infra
- [ ] Proxmox agent lists all VMs with correct status
- [ ] Caddy agent identifies all active reverse proxy routes
- [ ] Admin can approve a candidate and produce a complete service record in < 3 minutes
- [ ] Drift detection flags a deregistered service within one check cycle
- [ ] Agent tokens are tenant-scoped and have expiry
- [ ] Discovery never auto-adds to the registry without human approval

### Commercial Relevance

Removes the largest adoption blocker for new customers: manually inventorying
an existing estate. Discovery + approval makes PrivateNexus credible for MSP
onboarding scenarios.

---

## v2.0 — Dependency Intelligence

**Theme:** Answer the blast-radius question. When a service fails, what breaks
with it? When restoring, what must come back first?

### Deliverables

- `service_dependencies` table: upstream_id, downstream_id, dependency_type
  (hard, soft, data, auth, network), manually defined or discovery-inferred
- Dependency graph UI: interactive visualisation of service relationships
- Blast radius analysis: given a service failure, show affected downstream services
- Restore chain planner: given a service to restore, compute the correct restoration order
  accounting for dependencies
- Restore planner v2: replaces v0.8 planner — dependency-aware, not just single-service
- Recovery score v2: penalises services with unknown or unresolved dependencies

**Sandbox restore testing (from Phase 0 additions)**
- Periodic automated restore test: pull a backup, restore to an isolated environment,
  run a smoke test, record the result as `validation_result` on the backup record
- Schedule: configurable per service (weekly default for critical services)
- Result feeds directly into recovery score — `restore_tested` signal becomes proven, not assumed
- Isolation: restore target must be separate from production (isolated Docker network or VM snapshot)
- This is the single most important feature for converting the recovery score from
  a heuristic into an auditable proof

**Read-only MCP server (from Phase 0 additions)**
- MCP server exposing PrivateNexus data to AI clients (Claude Code, Cursor, Cline)
- Read-only in v2.0 — no write or action capabilities
- Exposed resources: service inventory, health status, recovery scores, backup records,
  audit event summary
- Authentication: MCP client authenticates with a scoped operator-role token
- Use case: JARVIS (Claude Code on Gateway VPS) can query PN status directly during
  infrastructure sessions without manual SSH chains

### Acceptance Gate

- [ ] Dependency graph renders for full HoT estate
- [ ] Blast radius analysis produces correct affected-service list for at least three test failures
- [ ] Restore chain planner produces dependency-correct ordering for at least five services
- [ ] Sandbox restore test runs for at least one critical service (Nextcloud or ERPNext)
- [ ] Sandbox restore result appears in recovery score signal breakdown
- [ ] MCP server responds to inventory and health queries from Claude Code
- [ ] MCP server rejects any attempted write or action

### Commercial Relevance

Strongest commercial differentiator. No self-hosted tool in the SMB/homelab space
does dependency-aware restore planning with automated proof. This is the version
that justifies the Professional tier pricing.

---

## v2.5 — Governance Engine

**Theme:** Turn passive visibility into active standards enforcement. Produce
client-ready governance reports and a live recommendations feed.

### Deliverables

- Policy rule engine: configurable checks run against the full service registry
- Built-in policy checks (from Build Guide §13.1):
  - Every service must have an owner
  - Every production service must have a backup policy
  - Every public service must have an access mode classification
  - Every admin service must be VPN, SSO, or mTLS protected
  - Every service must have a health check configured
  - Every service must have a recovery runbook URL
- **Recommendations feed** (from Phase 0 additions): live, actionable list replacing
  static report documents. Shows: services failing policies, sorted by severity.
  Updates in real time as services are edited.
- Governance reports: tenant-scoped, exportable (PDF / JSON)
  - Services missing owners
  - Services with stale or untested backups
  - Services without health checks
  - Public services without stated auth reason
  - Admin actions by user over rolling 30/90 days
  - Restore readiness summary per workspace
- Change records: structured record of significant service state changes
  (not just audit events — higher-level summaries for non-technical stakeholders)
- Policy exception workflow: document a known exception to a policy with reason and expiry

### Acceptance Gate

- [ ] All built-in policy checks run against HoT estate and produce correct results
- [ ] Recommendations feed shows real gaps (at least one per workspace expected)
- [ ] Governance report exports to PDF for at least the "restore readiness" report
- [ ] Policy exceptions can be recorded with reason and expiry date
- [ ] Change record created automatically for service approval, role change, and action execution
- [ ] Tenant boundary: governance reports for tenant A never include tenant B data

### Commercial Relevance

Required for client and MSP use cases where audit trails and standards reporting
matter. The recommendations feed turns PrivateNexus from a visibility tool into
an operations improvement tool — a meaningfully different value claim.

---

## v3.0 — Controlled Orchestration

**Theme:** Move from visibility into safe, policy-driven action across the full
service lifecycle. Deploy, rollback, and maintenance workflows with guardrails.

### Deliverables

- Action policy engine v2: full policy object model (from Build Guide §11.2),
  evaluated server-side, never client-controlled
- Extended action set:
  - Service deploy (approved images, version pin, rollback point created before deploy)
  - Service rollback (to last known-good version, audit-logged)
  - Secret rotation workflow (rotate → validate → commit, not raw credential exposure)
  - Bulk maintenance window (multi-service, coordinated pause/resume)
  - Approved configuration change (diff shown, confirmation required, audit-logged)
- Step-up authentication for destructive actions (superadmin and breakglass)
- Action cooldowns, rate limits, and blast-radius pre-checks (if dependency graph shows
  downstream impact, additional confirmation required)
- Approval workflow option: operator proposes, admin approves, action executes
- No arbitrary shell access. No raw Docker socket. These boundaries are permanent.

**Recommendations feed v2:** Recommendations now include suggested actions (not just flags).
Example: "Nextcloud backup is 72h old — click to trigger backup now." Action is
policy-gated, confirmation-required, audit-logged.

### Acceptance Gate

- [ ] Deploy workflow tested end-to-end with rollback for at least one service
- [ ] Rollback restores previous version and creates correct audit trail
- [ ] Step-up auth challenge fires for superadmin-class actions
- [ ] Blast-radius pre-check blocks action when downstream impact is detected
  without explicit override
- [ ] Approval workflow: operator proposes, admin approves, action executes or expires
- [ ] No raw shell or unrestricted Docker socket exposed at any point

### Commercial Relevance

Moves PrivateNexus into the managed operations tier. MSP use cases and clients who
want a controlled deployment surface without direct server access become viable.

---

## v4.0 — Recovery Intelligence (Flagship)

**Theme:** Full recovery intelligence. Simulate failures, prove recoverability,
produce board-level recovery confidence reports. The Professional tier's headline feature.

### Deliverables

- Recovery simulator: given a hypothetical failure scenario (service down, VM lost,
  DC unavailable), simulate the restore sequence, estimated RTO, data loss window,
  and blockers — without touching production
- Recovery confidence score v3: fully evidence-based — driven by sandbox restore
  results, dependency chain completeness, secret availability checks, and runbook
  presence. Every signal is verifiable, not assumed.
- Recovery readiness report: per-tenant, per-workspace report suitable for
  presenting to a business stakeholder or auditor
  - Services: recoverable / at-risk / unproven / blocked
  - Estimated RTO per service
  - Last validated restore date
  - Outstanding blockers with remediation steps
- Automated recovery gap detection: identifies services where the recovery path
  would fail (missing dependency, expired backup, unvalidated restore, secret not
  in vault) and raises a recommendation before an incident forces discovery
- Recovery playbook generation: produces a human-readable ordered recovery runbook
  for a defined incident scenario, auto-populated from the dependency graph and
  backup inventory

### Acceptance Gate

- [ ] Recovery simulator runs against the full HoT estate without touching production
- [ ] Simulation output matches what a manual restore attempt would require
- [ ] Recovery confidence score differences between services are explainable and accurate
- [ ] Recovery readiness report exported and reviewed by Mr. Byrne for accuracy
- [ ] At least one real recovery gap identified that was not previously known

### Commercial Relevance

This is the version that justifies the Professional tier price point. No self-hosted
competitor delivers automated, dependency-aware, sandbox-validated recovery confidence
at this level. This is the feature clients will pay for and auditors will ask for.

---

## v5.0 — Autonomous Operations

**Theme:** Predictive, assisted remediation. PrivateNexus moves from reactive
reporting to proactive recommendations with optional autonomous execution for
pre-approved, low-risk action classes.

### Deliverables

- Predictive health degradation: trend analysis on health events to surface services
  likely to degrade before they fail — shipped 2026-07-21 as the `latency_trending`
  signal (`hot-privatenexus` commit `c3e0265`)
- Anomaly detection: flag unusual patterns in health, resource usage, or audit activity
  — shipped 2026-07-21, both legs: `auth_failure_burst` (login-attempt bursts by IP,
  commit `1f7131c`) and `resource_trending` (sustained CPU/RAM/disk climbs per VM via
  Prometheus, commit `07fd939`). Resource leg currently only covers pn-vps — same
  known limitation as the Ops board's Fleet section, resolves once bare metal is
  restored and `PROMETHEUS_URL` reverts to sn-monitor.
- Assisted remediation: for a detected problem, PrivateNexus proposes a specific
  action (restart service, rotate credential, scale resource) with full policy
  evaluation and a one-click approve path
- Autonomous execution (low-risk class only): pre-approved, policy-gated action classes
  can execute without manual confirmation (e.g. health check refresh, log rotation trigger)
  — all still audit-logged, all still rate-limited, all still within policy
- MCP server v2: read-write (action-capable) for MCP-authenticated AI clients operating
  under operator-class permissions — allows JARVIS and similar to propose and execute
  pre-approved actions during live sessions
- AI-assisted recovery planning: given a live incident, surface the recommended restore
  order, highlight blockers, and pre-populate the recovery playbook

**Hard guardrails that do not change in v5:**
- No autonomous execution of destructive or irreversible actions
- No bypass of the audit trail
- No action execution without a valid policy match
- Breakglass role still requires step-up auth

### Acceptance Gate

**Gate closes: 2026-08-20** (revised — see 2026-07-21 correction below)

- [ ] Predictive degradation alert fires before at least one real service failure
  (validated retrospectively against incident history) — pending, closes organically
  during 30-day run; signals fired Jun 29 during NIC incident but not before onset.
  Re-checked 2026-07-21 against live data: the only degradation-class signal in the
  entire window since 2026-06-30 was a single Keycloak `latency_spike` (2026-07-16)
  that self-resolved with no follow-on failure — still genuinely unmet, not close.
  **Detection strengthened 2026-07-21** (`hot-privatenexus` commit `c3e0265`): the four
  existing signal types (down_spike, degrading, latency_spike, intermittent) all require
  at least one already-observed non-healthy or already-slow event, so none of them could
  ever satisfy this gate item by design — they're reactive, not predictive. Added a fifth
  signal, `latency_trending`, that fires only while a service is still passing every
  recent check but its latency shows a genuine sustained climb (linear regression slope +
  an oldest-third-vs-newest-third ratio check to reject noise/outliers) — the first
  detector actually capable of firing before a real failure. Validated against synthetic
  cases and a clean live scan (zero false positives) before deploying. This doesn't close
  the gate item — it still needs a real predicted-then-confirmed failure pair — but it's
  no longer structurally impossible for it to close organically.
- [ ] **Reopened 2026-07-21.** Autonomous execution of approved low-risk actions runs
  without errors for 30 consecutive days. Previously marked done (clock started
  2026-06-30 17:31 UTC), but a live audit found the claim unsubstantiated: zero
  autonomous-executed remediation proposals existed anywhere in that 30-day window,
  all five autonomous policies were already disabled, and no audit trail explained
  when or why — consistent with the 2026-07-16 container.restart toggle test being
  switched off and cleaned up afterward, not a sustained run. Corrected rather than
  left as a false positive. The four `health.refresh` policies (down_spike, degrading,
  latency_spike, intermittent) were re-enabled 2026-07-21 to start a real clock;
  `down_spike:container.restart` deliberately left disabled — that one is a separate,
  higher-consequence decision, not part of this gate item. New target: 2026-08-20.
- [x] MCP v2 write actions are constrained to operator-class policy and fully audit-logged
  — confirmed 2026-06-30: intelligence.service.probe via mcp-server token appears in
  audit_log with role=operator, outcome=success
- [ ] No incident where autonomous execution caused unintended state change — ongoing

### Commercial Relevance

Long-term platform differentiation. Positions PrivateNexus as an infrastructure
operations platform with intelligence, not just a dashboard with a recovery report.
This is the version that justifies an Enterprise tier and MSP partnerships.

---

## Dependencies and Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Backend framework decision (Go vs NestJS) reopened mid-build | Wasted sprints on speculative migration | Resolved 2026-06-22 (Phase 0 freeze): existing Node.js Express v4 (ESM) codebase, already at v1.9.0 with substantial working functionality, kept as-is rather than migrated. See `PrivateNexus_Phase0_Freeze.md`. Not re-litigated. |
| pn-test VM resource pressure (8 GB shared) | Stack instability during development | Monitor actual RSS. Express backend idles ~55 MB in production (pn-vps, confirmed live) — the memory-pressure concern that motivated evaluating Go never materialized in practice. Sandbox restore testing (v2.0) needs its own isolated environment — plan that resource now. |
| Keycloak `privatenexus` realm not yet created | v0.9 blocked | Create realm and client before Sprint 3 begins. Reference CLAUDE.md Keycloak OIDC gotchas. |
| Sandbox restore testing requires isolated environment | v2.0 delivery risk | Size the isolated restore environment in v1.5 planning. Can be a Proxmox snapshot-based approach. |
| Discovery agents need Docker socket access | Security risk if mishandled | Agent reads labels only — no write, no exec, no container lifecycle. Socket access is read-only and scoped to the agent binary. |
| Multi-tenant isolation defects are expensive | Trust and commercial risk | Add tenant boundary integration tests from v0.9. Every query in the API must be tenant-scoped. Never trust frontend for tenant filtering. |
| NetBox Labs entering the IOP category | Competitive pressure | Stay focused on service-level recovery + SMB/homelab simplicity. Do not compete on network/DCIM inventory. |

---

## Versioning Policy

- `v0.x` — Internal builds, House of Trae only, no external stability guarantees
- `v1.0` — First stable internal release, upgrade path guaranteed forward
- `v1.x` — Backwards-compatible feature additions
- `v2.0+` — May include database migrations; upgrade guide required; no breaking API changes without deprecation period
- All releases: version tag in git, changelog entry, smoke test before tagging

---

---

## v6.0 — Open Platform

**Theme:** Transform PrivateNexus from a single-tenant internal tool into an open,
multi-tenant platform ready for its first external users. Ship the Community Edition.
Enable the first Professional beta customers. Prove the recovery differentiator for real,
not just in code — in production, against real services.

**Gate to define this version:** Passed. v5.0 autonomous execution clean-run (30 days)
confirmed PrivateNexus is stable enough to open to external users.

### Deliverables

**Full multi-tenancy**
- Remove `HOT_TENANT_ID` hardcode — dynamic tenant resolution from authenticated session
- Tenant CRUD API and provisioning workflow (SuperAdmin only)
- SuperAdmin console: view all tenants with service counts, health summary, and last activity
- House of Trae migrated cleanly to tenant slug `house-of-trae`
- Tenant isolation regression suite: every API endpoint verified to be tenant-scoped

**De-hardcode HoT-specific assumptions (Catalogue is the deliberate exception)**
- Audit goes beyond `HOT_TENANT_ID`: discovery scanner defaults are currently baked-in HoT
  topology (`scanProxmox`'s `10.10.0.2:8006` default, `scanCaddy`'s `10.10.0.1:2019` default),
  `inferCategory()`'s image-name list is tuned to HoT's actual stack (ERPNext/Keycloak/Forgejo/
  etc.), and workspace lookups assume seeded slugs like `infrastructure` exist. These move to
  per-tenant configuration (DB-backed settings, not env-var defaults) so a second tenant isn't
  silently scanning House of Trae's infrastructure or matching HoT-specific categories.
- Seed data (workspaces, categories, the House of Trae tenant itself) becomes install-time
  configuration rather than assumed-present rows.
- **Explicit exception: the Catalogue board is not genericized away — it's built out.** Today
  `GET /api/catalogue` (`app/backend/src/routes/catalogue.js`) serves a static in-memory `APPS`
  array with no update/version tracking and no way to point at a different source. Catalogue
  becomes a real local repository: a versioned app/update source PrivateNexus can query for
  available updates to itself and to any catalogue app a tenant has installed, with support for
  pointing at a self-hosted repository (not just the bundled default list). This is the one place
  HoT-shaped curation is a feature, not a hardcoding smell — it's the update-delivery mechanism
  every install (including HoT's own) depends on. Closes PRD gap FE-09 (Catalogue board —
  currently PARTIAL, route built but static).

**Proven recovery score**
- Automated sandbox restore runner using an isolated Docker network (no production contact)
- Restore test scheduling — weekly default for critical services, configurable per service
- Test results written to `validation_result` and `restore_tested_at` on backup records
- Recovery score tier upgrades from heuristic to proven when sandbox test passes
- ERPNext (sn-business) and PrivateNexus itself are the first two validated services

**PrivateNexus self-registration**
- PN registered as a managed service in its own registry with owner, backup policy, health check, and recovery runbook
- pg_dump backup automated: encrypted, shipped to Backblaze B2 on the existing backup schedule, 30-day retention
- Recovery score computed for PN itself — closes the v1.0 acceptance gate that was deferred

**Alerting completion**
- Maintenance window suppression: Ntfy notifier checks `maintenance_mode_until` before firing; silences alerts for the duration
- End-to-end verification of all four topic routes (hot-critical / hot-high / hot-warning / hot-info)
- Alert deduplication confirmed: sustained state does not repeat, only state transitions fire (already enforced by state-change detection — needs maintenance window integration)

**Community Edition ship**
- GitHub repository published with open-source Community Edition core (MIT licence)
- Docker Hub images: `privatenexus/community:latest`
- Install guide: tested from scratch on a clean VM — zero to running in under 30 minutes
- Upgrade guide: clean, tested migration path between minor versions
- README and walkthrough screenshots
- Passes all five commercial proof points from the Packaging & Licensing document

**Professional Edition foundation**
- Edition flag resolved from licence key, enforced by middleware feature gate
- Pro feature list defined and gated: multi-tenant, discovery agents, sandbox restore, governance reports, action policy engine
- Licence key validation endpoint
- First Professional beta: 2–3 small businesses or MSPs at free or heavily discounted rate
- Beta feedback triaged before v6.0 GA tag is cut

**Security lockdown mode**

Tiered automated response to confirmed intrusion events. Triggered by Wazuh active response
or CrowdSec decision webhook, or manually from the PrivateNexus UI by an admin/superadmin.
All tier actions are audit-logged with actor, trigger source, tier, timestamp, and duration.

| Tier | Trigger examples | Actions |
|---|---|---|
| **Alert** | Any level 7+ Wazuh rule, any CrowdSec ban | Ntfy hot-critical push with full details. No service changes. |
| **Soft** | Brute force confirmed, credential stuffing, active scan | Flush all Redis sessions (force re-auth), tighten Caddy rate limits, ban offending IP range via CrowdSec API, SMS escalation |
| **Hard** | Confirmed intrusion, lateral movement detected | Stop Keycloak, PrivateNexus backend, and ERPNext containers. Public auth and ops surfaces go dark. SMS + Ntfy urgent. |
| **Full** | Active data exfiltration, worst-case scenario | `qm stop` all VMs. LUKS seals all data at rest. Nothing decrypts without Tang (Gateway VPS). Manual restart required. |

Implementation:
- `POST /api/lockdown` endpoint (superadmin/breakglass only) — accepts tier, duration, trigger_source, reason
- Wazuh active response script calls the PN lockdown API on level 12+ rules
- CrowdSec HTTP notification triggers soft lockdown on range bans (subnet-scale attacks)
- Lockdown state stored in Redis with TTL — auto-expires for soft tier, manual release for hard/full
- UI indicator: red banner across PN dashboard when any lockdown is active, with tier label and elapsed time
- Recovery: explicit `POST /api/lockdown/release` (admin+) with reason recorded in audit log

Hard guardrails:
- Full lockdown (`qm stop`) requires breakglass role — cannot be triggered by automated response alone
- All lockdown actions are reversible except Full (which requires manual VM restart + Tang unlock)
- Rate limit: lockdown API is limited to 3 calls per minute to prevent API-based denial of service

**JARVIS MCP expansion**
- Prometheus MCP: JARVIS queries metrics and alert states directly without SSH to sn-monitor
- PostgreSQL MCP: JARVIS direct read access to PN and Keycloak DBs for incident context queries
- Forgejo MCP: JARVIS creates issues, PRs, and manages repos at git.securenexus.net without bash git chains
- Proxmox MCP: JARVIS checks VM state, snapshots, and resource usage without SSH through WireGuard
- Wazuh MCP: JARVIS queries SIEM alerts during security incidents for cross-correlation
- Sequential Thinking MCP: structured multi-step reasoning for complex infrastructure decisions
- Context7 MCP: up-to-date documentation for the PN stack (Express v4, React, PostgreSQL) injected into JARVIS sessions on demand

### Acceptance Gate

- [x] Second tenant created and isolated from House of Trae — data boundary verified by direct DB query (proven in an isolated throwaway stack, `hot-privatenexus` commit `92b94f2` and re-verified `15dbd9c` — a service created under the House of Trae tenant was invisible to a second tenant both via direct DB query and the live API)
- [x] SuperAdmin console shows all tenants with health summary and last activity — `hot-privatenexus` commit `0d51048`, live on pn-vps
- [x] `HOT_TENANT_ID` hardcode absent from all backend code (grep confirms) — only deliberate references remain: `db.js`'s own definition/seed, `server.js`'s MCP-internal session (JARVIS has no real tenant), `auditLog.js`'s pre-resolution fallback, `discovery.js`'s bootstrap static-token fallback — none silently drive business logic for a real tenant
- [x] Discovery scanner defaults (Proxmox/Caddy URLs, category inference) are per-tenant config, not hardcoded HoT topology — `tenant_settings` table, `hot-privatenexus` commit `15dbd9c`
- [x] Catalogue serves from a real local repository (versioned, update-checkable) instead of the static `APPS` array, with at least one non-default repository source configurable — `hot-privatenexus` commit `3eeecc2`. The 52-app default moved from hardcoded JS to a versioned JSON file (`repository.name`/`version`/`updated_at`); a new per-tenant `catalogue_repo_url` setting lets a tenant point at a self-hosted repo instead, with shape validation and a visible (never silent) fallback to bundled if it's unreachable. Verified live end-to-end: bundled default unchanged (52 apps), a real throwaway custom-repo container correctly took over the catalogue, and an unreachable URL correctly fell back with the real fetch error surfaced via `repository_fallback`/`fetch_error`. **Deliberately not done in this pass**: per-app upstream-registry version-drift detection ("updates to any catalogue app a tenant has installed"). PrivateNexus's own self-update check was blocked on a versioning inconsistency (`VERSION`=4.0.0, `package.json`=2.0.0, `server.js`'s hardcoded `/api/health`=5.0.0) — **resolved same day, `hot-privatenexus` commit `d56591f`**. Traced the git history first rather than guess: `VERSION` and the server.js literal were bumped together at every release through v4.0.0, but the v5.0.0 commit only bumped the literal, forgetting both `VERSION` and `package.json` (which had actually been stale since v2.0.0, several releases further behind — same for `frontend`/`mcp` package.json at 1.10.0/2.0.0). Fixed all five files to `5.0.0`, and — the actual root-cause fix — `server.js` now reads its served version from `package.json` at startup instead of a separately hardcoded literal, so one bump is the only thing needed going forward; verified live post-rebuild. `VERSION` stays a plain-text file (`scripts/install.sh` reads it directly, deliberately not made to parse JSON) kept in sync by convention. **Self-update-check feature built same day, `hot-privatenexus` commit `3d3ffc1`**: new `GET /api/admin/update-check`, surfaced as a "Version & Updates" panel under Admin > System. Reads the highest semver git tag from `github.com/traebon/hot-privatenexus` — checked first rather than assumed: no GitHub Releases exist for this repo (API returns an empty array), only pushed tags, so it reads `/tags` not `/releases/latest`. Cached in-memory 1h to stay under GitHub's 60 req/hr unauthenticated limit, `?force=true` bypasses it. Reports fetch failures honestly rather than defaulting to "up to date" on error. `PACKAGE_VERSION` extracted into its own `src/version.js` so the health check and this route share one read instead of duplicating it. Verified live on pn-vps: correctly reports `5.0.0 == 5.0.0`, 401s unauthenticated, cache/force-refresh both behave correctly; semver comparison (numeric, skips non-plain tags like the historical `v0.4.0-rc1`) verified in isolation.
- [ ] Sandbox restore test runs for ERPNext and PrivateNexus without any production contact — **half done**: PrivateNexus's own restore test was run for real (2026-07-16, isolated scratch `postgres:16-alpine` container, schema+registry verified, never touched the live DB) and is recorded in `restore_tests`. ERPNext has no equivalent test recorded anywhere — and note ERPNext currently runs on erp-temp, a temporary stand-in VPS, not sn-business, so "without any production contact" needs re-scoping once that's back on real infrastructure anyway.
- [x] Restore test result visible in recovery score breakdown as a proven signal (not heuristic) — confirmed in `recovery.js`'s `computeConfidence()`: "Restore validated" is a real 15-point weighted signal keyed off actual `restore_tests` rows (pass/fail, staleness by age), not a heuristic guess. Proven live: `privatenexus-db` moved from `at_risk` (70) to `recoverable` (95) specifically because of a real recorded test.
- [x] PrivateNexus registered as a managed service with health check, backup policy, and non-zero recovery score — all done as of the 2026-07-16 governance/recovery work: `privatenexus-db` + all other PN containers are registered with real health checks, `privatenexus-db` has `backup_policy=daily`, and every PN service sits at `recoverable` tier (avg 94/100, `privatenexus-db` itself at 95).
- [x] PN's own pg_dump runs on schedule and delivers encrypted backup to B2 — `privatenexus-pg-dump.timer` (daily 03:00 CEST on pn-vps) + Gateway pull + rclone crypt, confirmed landing in both `hetzner-crypt:` and `b2-hot-crypt:` via `rclone lsl` (2026-07-16).
- [x] Maintenance window suppresses Ntfy alerts for its full duration, then resumes on expiry — **built 2026-07-22, `hot-privatenexus` commit `eb21388`.** Mr. Byrne chose the Grafana-silence approach over a second, PN-native Ntfy path (consistent with Grafana already being the documented single source of truth for the 3-channel alerting architecture, and it gets the "resumes on expiry" half for free via Grafana's own `endsAt` auto-expiry — no PN-side timer needed for that part). New `src/grafana.js`; wired into `maintenance.enable`/`.disable` in `actions.js`; `GRAFANA_URL`/`grafana_token` follow the exact `PROXMOX_URL`/`proxmox_token` placeholder pattern since sn-monitor (where Grafana lives) is behind the same dead bare-metal host and is just as unreachable (confirmed: 20+ day stale WireGuard handshake, no ping, 502 through Caddy) — `grafana_token.txt` is a real placeholder, ready for a live token once sn-monitor is back. Global/fleet-wide scope, matching maintenance mode's existing Emergency-board scope. Requires a bounded duration (Grafana silences can't be open-ended) — indefinite maintenance honestly reports suppression as unavailable rather than silently covering only part of the window. Grafana success/failure is tracked and surfaced separately from the maintenance flag itself (API response + a new Emergency board status line) so a Grafana failure can never make the UI imply protection that isn't happening — same bug class as the `down_spike` toggle and the `emergency.stop-all` policy gap found earlier this session. Verified live end-to-end with a real disposable Keycloak admin test user (created, tested, deleted): enable/disable/status/audit trail all behave correctly, and the Grafana failure is honestly reported (`"Grafana returned 502"`) rather than faked as success — cannot be verified against a real Grafana instance until sn-monitor is restored. **Also fixed along the way**: rsyncing the full `docker-compose.yml` to pn-vps briefly clobbered a manual, pn-vps-only port-binding override and caused a real ~1-2 minute site outage (caught immediately via `/api/health` 502, fixed without touching the tracked file, which intentionally differs from the live pn-vps config here) — deploying individual files from now on instead of the whole compose file.
- [ ] GitHub repository live with Community Edition source and MIT licence — the `github`/`codeberg` mirrors exist and are being pushed to routinely, but `LICENSE` in the repo root is a 0-byte empty file (checked 2026-07-22). **Deliberately left empty, not just unfinished** — Mr. Byrne confirmed 2026-07-22: adding MIT now would license the current monolithic codebase as-is, which still contains everything §7 of `PrivateNexus_Commercial_Packaging_Licensing.md` (Open-Core Boundary) says should be closed-source Professional-tier (multi-tenancy, discovery agents, sandbox restore, governance reports, action policy engine) — that split is itself an unstarted v6.0 deliverable (see "Pro feature list defined and gated" above). Real blocker order: separate Pro-gated code into its own module/plugin/container first, *then* MIT the Community-only remainder — not the other way around.
- [ ] Docker Hub image: clean install from scratch on a fresh VM in under 30 minutes
- [ ] Upgrade guide tested across at least one version bump
- [ ] All five commercial proof points from Packaging & Licensing document confirmed true
- [ ] First Professional beta customer onboarded (even at £0 for beta period)
- [x] RBAC tested with two users in different roles (closes the commercial proof point) — real test 2026-07-22, not simulated: created a genuine second Keycloak user (`rbac-test-viewer`, realm role `viewer`) and ran the actual browser-equivalent OIDC flow end-to-end (login redirect → Keycloak form POST → profile-verify step → code exchange → real `pn.sid` session cookie), compared against the existing `tristian` (superadmin) session used throughout this session's work. Confirmed live: viewer reads `GET /api/services`/`GET /api/governance/rules` (200), correctly 403s on `POST /api/actions/run/v2`, `POST /api/services`, `GET /api/tenants` with the right `required` role in the response body. **Found and fixed a real gap along the way**: `requireRole()` — the middleware gating nearly every write/admin route — only ever audited successes (each route's own handler called `recordAudit`); a 403 rejection left zero `audit_log` trace. Fixed in `hot-privatenexus` commit `2aa82fb` (adds `access.forbidden` on rejection, with route/method/required-role in `detail`), verified safe via an isolated circular-import test before touching the live container (the fix requires `requireRole.js` to import `recordAudit` from `auditLog.js`, which already imports back from `requireRole.js`), then confirmed live: all three rejected requests above now produce real `audit_log` rows. Test user deleted from Keycloak afterward; the real audit rows were left in place as evidence, not cleaned up.
- [ ] No critical security issues open at release tag
- [ ] Lockdown API endpoint live and tested for all four tiers (Alert, Soft, Hard, Full)
- [ ] Wazuh active response calls lockdown API on level 12+ alert (end-to-end test in staging)
- [ ] CrowdSec range ban triggers soft lockdown via webhook
- [ ] Full lockdown (`qm stop` path) requires breakglass role — verified that lower roles are rejected
- [ ] Lockdown state visible in PN dashboard with tier label and elapsed time
- [ ] Lockdown and release events appear in audit log with full actor and trigger context

### Commercial Relevance

The version that opens the door to revenue. Without multi-tenancy there are no external
customers. Without the Community Edition on GitHub there is no discovery funnel. Without
the proven recovery score the flagship differentiator is a claim not a proof. v6.0 makes
all three real simultaneously.

Passing this gate enables GTM Stage 2 (Community Edition launch) and Stage 3 (Professional
Edition preview) from the Packaging & Licensing plan to begin. The first ARR target —
3 paying Professional beta customers — becomes achievable within 60 days of v6.0 GA.

---

## What Happens After v6.0

Not defined yet. The question to answer at v6.0 is whether the external market validates
the recovery intelligence differentiator. If Community Edition adoption signals clear demand
and Professional beta customers convert, v7.0 will be defined around the top feedback
themes from those first external users.

Candidates for v7.0 scope (not committed):
- HoT Command mobile app (Flutter or React Native PWA)
- **In-product notifications** — PrivateNexus itself currently has no notification path to a
  logged-in operator; every alert (SMTP/Ntfy/SMS) is fired by the wider HoT stack, outside the
  app, to HoT-wide channels. Added 2026-07-21 after a market scan of comparable self-hosted
  ops/dashboard tools turned up push/mobile notification support as a recurring, concrete ask
  (see Market Positioning Check below). Scope: browser push or PWA notification for
  critical/high signals while the dashboard is open, plus per-user alert-channel preference
  (own Ntfy topic or webhook) rather than only the shared hot-critical/-high/-warning/-info
  topics. Not full mobile push — that stays HoT Command's job.
- Managed Edition pilot (hosted PrivateNexus for SecureNexus clients)
- Billing and licence key self-service portal
- Multi-site federation (multiple Proxmox clusters under one PN instance)
- Formal compliance modules (ISO 27001 evidence collection, CIS benchmark checks)

### Market Positioning Check (2026-07-21)

Scanned comparable self-hosted/homelab ops tools (Coolify, Komodo, Portainer, Dashy/Homarr,
Pulse) and DR-dashboard peers (Veeam Recovery Orchestrator and alternatives) for recurring
feature-request themes, to sanity-check v6.0/v7.0 scope against what the market actually asks
for rather than assuming. Findings and how each maps onto this roadmap:

| Theme found | Source pattern | Disposition |
|---|---|---|
| Unified cross-environment dashboard | Veeam DR peers | Already the product (Home/Ops/Fleet boards). "Cross-environment" reading maps to the existing Multi-site federation v7.0 candidate above — no new item needed. |
| Automated, provable restore testing | Veeam DR peers | Already the flagship differentiator (v2.0 sandbox restore, v4.0 recovery readiness report) — validates the positioning, not a gap. |
| Push/mobile notifications | Homelab dashboards generally | Genuine gap — added as the In-product notifications v7.0 candidate above. |
| No artificial usage caps on the free/self-hosted tier | Pulse (open device-limit complaint) | Checked against `PrivateNexus_Commercial_Packaging_Licensing.md` §7.3 — already explicit policy ("do not add artificial user-count limits to Community"). No change needed; confirmed, not assumed. |
| Git-push PaaS-style deploy automation | Coolify | **Deliberately rejected.** Coolify's whole product is deployment; PrivateNexus's is recovery. Chasing this dilutes the wedge described in Packaging §2. Not added to any version. |
| Docker Swarm / multi-server orchestration breadth | Komodo | **Deliberately rejected** as a general orchestration surface — PrivateNexus wraps *approved* actions under policy (Packaging §8 competitive table), it does not aim to be a general multi-server control plane. The one legitimate slice of this (multiple independent estates under one pane of glass) is already the Multi-site federation v7.0 candidate; no broader scope added. |

No version's committed scope changed as a result of this check — one net-new v7.0 candidate
added, everything else either already covered or explicitly out of scope for the stated reason.

---

*Document owner: House of Trae / PrivateNexus Programme*
*Next revision trigger: any release ships, any scope changes, or a new version is planned*
*Related documents:*
- *`PrivateNexus_Phase0_Freeze.md` — locked architectural decisions*
- *`PrivateNexus_Build_Implementation_Guide_v1.0.docx` — phase-by-phase build detail*
- *`PrivateNexus_Commercial_Product_Strategy.docx` — positioning and revenue model*
- *`PrivateNexus_Product_Specification.pdf` — product boundary and core functions*
