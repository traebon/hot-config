# PrivateNexus — Detailed Release Roadmap
**Version: 1.1**
**Date: 30 June 2026**
**Owner: House of Trae / PrivateNexus Programme**
**Classification: Internal — Strategic Planning**
**Covers: v0.8 → v6.0**

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
- Docker Compose baseline: Go API, React frontend, PostgreSQL 16, Redis 7
- Database migration runner (golang-migrate)
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

- [ ] User logs in through Keycloak
- [ ] Logout clears session
- [ ] Roles visible to backend from token claims
- [ ] Viewer role cannot reach any action endpoint
- [ ] Admin and superadmin routes return 403 for lower roles
- [ ] All login attempts (success and failure) create audit events
- [ ] All privileged route attempts create audit events
- [ ] Tenant ID present on all tenant-owned records
- [ ] `GET /me` returns correct user, role, tenant

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
  likely to degrade before they fail
- Anomaly detection: flag unusual patterns in health, resource usage, or audit activity
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

- [ ] Predictive degradation alert fires before at least one real service failure
  (validated retrospectively against incident history)
- [ ] Autonomous execution of approved low-risk actions runs without errors for
  30 consecutive days before v5.0 release
- [ ] MCP v2 write actions are constrained to operator-class policy and fully audit-logged
- [ ] No incident where autonomous execution caused unintended state change

### Commercial Relevance

Long-term platform differentiation. Positions PrivateNexus as an infrastructure
operations platform with intelligence, not just a dashboard with a recovery report.
This is the version that justifies an Enterprise tier and MSP partnerships.

---

## Dependencies and Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Backend Go velocity slower than NestJS in early sprints | v0.8/v0.9 delivery slips | Scaffold API surface from Build Guide Appendix B before Sprint 1. Use sqlc + pgx rather than raw SQL. |
| pn-test VM resource pressure (8 GB shared) | Stack instability during development | Monitor actual RSS. Go API should idle < 50 MB. Sandbox restore testing (v2.0) needs its own isolated environment — plan that resource now. |
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

**JARVIS MCP expansion**
- Prometheus MCP: JARVIS queries metrics and alert states directly without SSH to sn-monitor
- PostgreSQL MCP: JARVIS direct read access to PN and Keycloak DBs for incident context queries
- Forgejo MCP: JARVIS creates issues, PRs, and manages repos at git.securenexus.net without bash git chains
- Proxmox MCP: JARVIS checks VM state, snapshots, and resource usage without SSH through WireGuard
- Wazuh MCP: JARVIS queries SIEM alerts during security incidents for cross-correlation
- Sequential Thinking MCP: structured multi-step reasoning for complex infrastructure decisions
- Context7 MCP: up-to-date documentation for the PN stack (Express v4, React, PostgreSQL) injected into JARVIS sessions on demand

### Acceptance Gate

- [ ] Second tenant created and isolated from House of Trae — data boundary verified by direct DB query
- [ ] SuperAdmin console shows all tenants with health summary and last activity
- [ ] `HOT_TENANT_ID` hardcode absent from all backend code (grep confirms)
- [ ] Sandbox restore test runs for ERPNext and PrivateNexus without any production contact
- [ ] Restore test result visible in recovery score breakdown as a proven signal (not heuristic)
- [ ] PrivateNexus registered as a managed service with health check, backup policy, and non-zero recovery score
- [ ] PN's own pg_dump runs on schedule and delivers encrypted backup to B2
- [ ] Maintenance window suppresses Ntfy alerts for its full duration, then resumes on expiry
- [ ] GitHub repository live with Community Edition source and MIT licence
- [ ] Docker Hub image: clean install from scratch on a fresh VM in under 30 minutes
- [ ] Upgrade guide tested across at least one version bump
- [ ] All five commercial proof points from Packaging & Licensing document confirmed true
- [ ] First Professional beta customer onboarded (even at £0 for beta period)
- [ ] RBAC tested with two users in different roles (closes the commercial proof point)
- [ ] No critical security issues open at release tag

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
- Managed Edition pilot (hosted PrivateNexus for SecureNexus clients)
- Billing and licence key self-service portal
- Multi-site federation (multiple Proxmox clusters under one PN instance)
- Formal compliance modules (ISO 27001 evidence collection, CIS benchmark checks)

---

*Document owner: House of Trae / PrivateNexus Programme*
*Next revision trigger: any release ships, any scope changes, or a new version is planned*
*Related documents:*
- *`PrivateNexus_Phase0_Freeze.md` — locked architectural decisions*
- *`PrivateNexus_Build_Implementation_Guide_v1.0.docx` — phase-by-phase build detail*
- *`PrivateNexus_Commercial_Product_Strategy.docx` — positioning and revenue model*
- *`PrivateNexus_Product_Specification.pdf` — product boundary and core functions*
