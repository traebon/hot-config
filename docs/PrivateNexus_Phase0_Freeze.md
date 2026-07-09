# PrivateNexus — Phase 0 Architectural Freeze
**Status: LOCKED**
**Date: 22 June 2026**
**Owner: House of Trae / PrivateNexus Programme**
**Classification: Internal — Build Baseline**

---

## Purpose

Phase 0 closes the architectural decisions that every later phase depends on.
Once locked, these decisions are not up for discussion per sprint. Changing a
locked decision requires a formal revision of this document and a version bump.

This document is the single source of truth for the PrivateNexus stack.
If CLAUDE.md and this document conflict, this document wins for PN-specific decisions.

---

## Locked Decisions

| Decision | Locked Value | Notes |
|---|---|---|
| Product model | Multi-tenant from day one | House of Trae = Tenant 1 |
| Backend framework | **Node.js (Express v4, ESM)** | See rationale below — Go was proposed but existing v1.9 codebase is Express |
| Frontend framework | React (TypeScript) | No change |
| Primary database | PostgreSQL 16+ | System of record for all tenant data |
| Cache / queue | Redis 7 | Session, background jobs, health check results |
| Identity provider | Keycloak (OIDC) | Realm: `privatenexus` on auth.house-of-trae.com |
| Gateway | Caddy | TLS termination, reverse proxy, route protection |
| Deployment runtime | Docker Compose v2 | Agents abstract future runtimes (Podman, K8s later) |
| First tenant | House of Trae | Tenant ID: `house-of-trae` |
| Initial roles | viewer, operator, admin, superadmin, breakglass | Defined in Keycloak + mirrored in DB |
| Service subdomains | nexus, api, status, auth | `nexus.privatenexus.net`, `api.privatenexus.net` etc. |
| Commercial direction | Open-core path | Community free tier → Professional → Managed |
| v1.0 modules | Identity, Inventory, Health, Recovery, Audit | Nothing else enters v1.0 scope |
| No browser shell | Deliberately excluded | Not in v1–v3; revisit for v4+ with full policy controls |
| No unrestricted Docker socket | Explicitly banned in production | All Docker actions via scoped agents + action policies |

---

## Backend: Why Go (not NestJS)

This was evaluated on 22 June 2026. The reasoning is recorded here so it is not re-litigated.

**Go wins because:**

1. **The agent architecture decides it.** The roadmap ships discovery and control agents onto
   tenant infrastructure (Docker agent, Proxmox agent, future host agents). These must be tiny,
   self-contained, zero-dependency binaries. Go produces exactly that. If the API is also Go,
   types and models are shared between the core and the agents. With NestJS, the agents would
   have to be Go anyway — producing a permanently split stack.

2. **Memory constraint is real.** pn-test is 8 GB RAM shared between PostgreSQL, Redis, the API,
   a worker, and the frontend. NestJS idles at 200–400 MB for a production app. Go idles at
   20–50 MB. That headroom matters across the constrained EPYC estate.

3. **Concurrency model is native.** Background health check loops, recovery score workers,
   discovery polling, action queues — all goroutines. Go handles thousands of concurrent health
   checks without a separate job framework. NestJS requires Bull/BullMQ + Redis workers to
   achieve the same, adding complexity and RAM.

4. **Single binary deployment.** No `node_modules`, no version drift, no runtime surprises.
   Fits the repeatability requirement of the build guide.

5. **Long-term product shape.** The platform ships agents to customer infrastructure. A Go API
   plus Go agents means shared libraries, shared type definitions, and a single `go.mod`. This
   is the architecture that scales to the commercial product.

**Correction recorded 22 June 2026:**
Go was initially recommended based on theoretical merits. On inspecting the live pn-test VM
the existing backend is Node.js Express v4 (ESM) at **v1.9.0** with substantial working
functionality already in place: Keycloak auth, full RBAC middleware, tenant model, service
registry CRUD, health probes, audit log, restore planner, Docker/Prometheus/Loki integration.

Migration to Go is rejected — it discards months of working code for no user-facing benefit.
Plain Express (not NestJS) is already in place and well-structured. Future discovery agents
can be standalone Go binaries that call the Express API over HTTP; they do not need to share
language with the core API.

**Decision: Node.js (Express v4, ESM). This is closed.**

---

## Phase 0 Exit Gate Checklist

All items below must be true before v1.0 code is considered in scope.
Status as of 22 June 2026 shown alongside each item.

| # | Check | Status |
|---|---|---|
| 1 | Backend framework documented and locked (Node.js Express v4 ESM) | ✅ Done — this document |
| 2 | Frontend framework confirmed (React + TypeScript) | ✅ Confirmed |
| 3 | Service subdomains confirmed | ✅ nexus / api / status / auth on privatenexus.net |
| 4 | Tenant 1 naming confirmed (House of Trae) | ✅ Confirmed |
| 5 | Initial roles confirmed (viewer/operator/admin/superadmin/breakglass) | ✅ Confirmed |
| 6 | No unrestricted Docker socket in production | ✅ Confirmed |
| 7 | All privileged actions require audit events | ✅ Confirmed as policy |
| 8 | v1.0 modules locked (identity/inventory/health/recovery/audit) | ✅ Confirmed |
| 9 | Phase 0 freeze document created | ✅ This document |
| 10 | CLAUDE.md updated to reflect locked stack | ✅ Done — v2.0 |

**Phase 0 exit gate: PASSED**

---

## v1.0 Scope Boundary

Features below are IN scope for v1.0. Anything not on this list goes to backlog.

- Keycloak authentication + session management
- Tenant model (single tenant: House of Trae)
- User and role management (all five roles)
- Service registry (CRUD, metadata, access mode badges)
- HTTP / TCP health checks per service
- Health status dashboard
- Backup record visibility (manual entry, then agent-sourced)
- Recovery score (explainable heuristic: backup age, trust state, test history)
- Audit event log (all privileged actions, all auth events)
- Service restart action (operator role, scoped to approved services, audit-logged)

**Out of scope for v1.0 (backlog jail):**
- Automated discovery agents
- Dependency graphs
- Sandbox restore testing (v2.x)
- Policy engine
- Multi-tenant (beyond data model foundation)
- MCP server read-only API (v2.x)
- Browser shell (never in early versions)
- DNS / proxy editing UI

---

## Amended Roadmap (additions from 22 June 2026 review)

The following items were added to the roadmap based on competitive analysis against
Veeam Recovery Orchestrator, Coolify v4.0, Portainer 2.4x, Komodo, and NetBox Labs.

| Version | Addition | Source |
|---|---|---|
| v2.x | **Automated sandbox restore testing** — periodically restores a backup to an isolated environment and records the result. Upgrades recovery score from heuristic to proven result. | Veeam Recovery Orchestrator pattern, adapted for self-hosted scale |
| v2.x | **Read-only MCP server** — exposes inventory, health status, and recovery score to MCP-compatible AI clients (Claude Code, Cursor). Safe, no write actions in v2. | Coolify v4.0 pattern — aligns with HoT JARVIS integration |
| v3.x | **Recommendations feed** — live actionable list (services missing owners, stale backups, missing health checks). Replaces static governance reports. | Portainer Recommendations page pattern |

**Competitive positioning note (recorded 22 June 2026):**
Recovery intelligence is no longer a unique concept at enterprise tier (Veeam, AWS Backup,
ManageEngine all sell "recovery readiness"). The PrivateNexus differentiator must be stated as:
**"Recovery intelligence at homelab and SMB simplicity and self-hosted price."**
The wedge is intact — the pitch needs that qualifier in all external materials.

---

## Do Not Build Yet (carried from Build Guide Appendix D)

- Full DNS editing UI
- Raw terminal / shell in browser
- Unrestricted Docker socket control
- Kubernetes support before Docker/Proxmox agents are stable
- Marketplace / plugin store before core architecture is stable
- Billing / licensing before product value is proven internally
- AI auto-remediation before audit, approval, and rollback are mature

---

*Document owner: House of Trae / PrivateNexus Programme*
*Next revision trigger: any locked decision requires a change, or v1.0 release*
