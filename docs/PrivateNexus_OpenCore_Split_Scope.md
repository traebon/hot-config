# PrivateNexus v6.0 — Open-Core Split Scope
**Scoped: 2026-09-13**
**Owner: House of Trae / PrivateNexus Programme**

---

## 1. Why This Exists

The v6.0 gate requires a Community Edition on GitHub with an MIT licence, a Docker Hub
image, and a working install guide. All three are currently blocked by one decision: the
MIT licence file is deliberately empty because the codebase is a monolith where Professional-
tier features (multi-tenancy, discovery agents, governance reports, sandbox restore, action
policy engine) are indistinguishable from the CE core at the source level.

This scope defines how to make that split real, unblock the gate, and open the launch path.

---

## 2. Architecture Decision — Licence-Gate Model

**Chosen approach: feature-gate middleware in a single repo.**

The alternative (two separate repos, Pro as a plugin container) was considered and rejected for
v6.0: it requires restructuring the Docker Compose, the DB schema, and the API surface in ways
that add 3–4 weeks of work with zero user-visible benefit in the first release. The licence-gate
model is how most open-core projects actually ship their first version (GitLab CE/EE, Grafana OSS/
Enterprise, Netdata Community/Pro all use the same approach).

**What this means in practice:**

- One repo, one codebase.
- CE routes/files carry an MIT SPDX header.
- Pro routes/files carry a separate commercial licence header (not MIT, clearly marked).
- A single `EDITION` environment variable (`community` | `professional`) controls what activates.
- A `requireEdition("professional")` middleware gates Pro API routes — returns `402 Payment Required`
  with a plain `{ error: "Professional Edition required", upgrade_url: "https://privatenexus.net" }`
  body for CE installs hitting those routes.
- The frontend hides Pro nav items when `edition: "community"` is returned from `/api/health`.

**MIT scope:** Every file that is CE-only gets `// SPDX-License-Identifier: MIT` at the top.
Pro files get `// SPDX-License-Identifier: LicenseRef-PrivateNexus-Pro`. The LICENSE file in
the repo root becomes the MIT text, and a separate LICENSE.pro file covers the commercial code.
A CE install can be fully audited — no Pro code is hidden, but it is not MIT.

**Licence key v6.0:** A hardcoded environment variable (`PN_EDITION=professional`) is sufficient
for v6.0. Cryptographic key validation (a real licence server checking a signed key) is a v7.0
concern — the first 2–3 beta customers can simply receive an env-var instruction. The licence key
validation endpoint listed in the v6.0 gate is therefore descoped to a stub that returns
`{ ok: true, edition: "professional" }` when `PN_EDITION=professional` is set.

---

## 3. CE / Pro Boundary

### 3.1 Community Edition — what stays free

| Surface | Why it's CE |
|---------|-------------|
| Service registry (CRUD, workspaces, categories, access modes) | Core inventory — gating this kills CE adoption |
| HTTP + TCP health probes + background scheduler | Same reason |
| Recovery score (heuristic, without sandbox restore) | Differentiator must be demonstrable for free |
| Restore planner (dry-run, dependency-aware) | Same |
| Safe actions — restart, maintenance mode, health refresh | Operators need these without a licence |
| Audit log (all action types) | Business credibility requirement |
| Single-tenant RBAC (all 5 roles) | CE installs are always single-tenant |
| Catalogue (browse + Catalogue deploy flow for personal services) | HoT curation is a feature, not Pro gating |
| File registry | Config management basics |
| Lockdown mode | Security posture shouldn't be paywalled |
| Basic intelligence signals (latency_trending, auth_failure_burst, resource_trending) | These drive the recovery score — same as above |
| Basic stacks management | Read-only ops |
| DNS query view | Informational only |

### 3.2 Professional Edition — what gates

| Surface | Why it's Pro | Route file(s) |
|---------|--------------|---------------|
| Multi-tenancy — tenant CRUD, SuperAdmin console, tenant isolation | No single-operator use case for this | `tenants.js` |
| Discovery agents — Docker/Proxmox/Caddy scan, approval workflow, agent tokens | Scales away from manual registry; MSP/SMB feature | `discovery.js` |
| Governance reports — policy engine, recommendations feed, exceptions, change records | Client-facing audit artefacts; SMB/MSP differentiator | `governance.js` |
| Sandbox restore testing — automated runner, validation_result, isolation | The proven recovery score vs. heuristic divide | `recovery.js` (sandbox routes only) |
| Action policy engine v2 — approval workflows, blast-radius pre-checks, bulk windows | Controlled orchestration at scale | Parts of `actions.js` |
| Dependencies graph management — add/edit/delete edges | Read-only dependency view stays CE; write is Pro | Parts of `dependencies.js` |

### 3.3 Grey areas — resolved

- **Restore planner (dry-run read):** CE. The planner itself is free; sandbox-validated results
  (restore_tested_at, validation_result) require Pro to generate, but CE can display any results
  that were generated when Pro was active.
- **Dependency graph (read-only view):** CE. Writing dependency edges is Pro.
- **Lockdown mode:** CE. Security posture is not a revenue lever.
- **MCP server:** CE. Read-only infrastructure queries should not be paywalled.

---

## 4. Work Items

### Phase 1 — Feature gate + boundary (2–3 days)

1. **`src/middleware/requireEdition.js`** — new middleware, mirrors `requireRole.js` pattern.
   Reads `process.env.PN_EDITION` (defaults to `"community"`). Returns 402 for CE hitting Pro.

2. **`/api/health` edition field** — add `edition: process.env.PN_EDITION || "community"` to the
   health response. Frontend uses this to show/hide Pro nav items.

3. **Gate Pro routes** — wire `requireEdition("professional")` before the router mount in
   `server.js` for: `tenantsRouter`, `discoveryRouter`, `governanceRouter`, and the sandbox-
   restore subroutes in `recoveryRouter` + approval-workflow subroutes in `actionsRouter` +
   dependency-write routes in `dependenciesRouter`.

4. **CE single-tenant path** — when `PN_EDITION=community`, `req.tenantId` is resolved to the
   single seeded tenant (slug `house-of-trae`) directly in `requireAuth.js`, instead of from the
   session's tenant claim. This means CE installs work without the tenant provisioning flow.

5. **Frontend Pro gating** — gate Pro nav items (Tenants, Discovery board, Governance board,
   Sandbox restore) behind `edition === "professional"` check in App.jsx. Show a tasteful
   "Professional Edition" upgrade prompt in place of each board rather than hiding them entirely.

6. **SPDX headers** — add correct headers to all 44 backend source files + App.jsx. Two passes:
   CE files get MIT, Pro files get LicenseRef-PrivateNexus-Pro.

7. **LICENSE + LICENSE.pro** — populate LICENSE with the actual MIT text (standard boilerplate).
   Create LICENSE.pro with a simple commercial licence statement covering the Pro-marked files.

### Phase 2 — CE packaging (1–2 days)

8. **README rewrite** — currently says "v1.0.0" and describes only v1.0 features. Rewrite to:
   - Describe the real product accurately (v5.0/v6.0 feature set)
   - CE vs Pro distinction clearly stated
   - Quick-start badge and install command at the top
   - Architecture diagram (lightweight ASCII)

9. **Install guide** (`docs/install.md`) — target: a stranger can go from zero to running CE
   in under 30 minutes on a fresh Ubuntu/Debian VM. Covers: Docker Compose copy, env var set,
   first run, Keycloak realm setup, first service registration.

10. **Upgrade guide** (`docs/upgrade.md`) — covers the version bump process: pull latest image,
    run `docker compose up -d`, migration auto-runs on startup. One tested upgrade (5.0.0 → 6.0.0)
    verified before the guide is written.

11. **Docker Hub workflow** — a `scripts/build-ce.sh` that builds `privatenexus/community:latest`
    from the `app/` directory, excluding any Pro-only directories. Initial manual push; CI/CD
    automation is post-v6.0.

### Phase 3 — Gate verification (0.5 days)

12. **Proof point sweep** — run through the 8 commercial proof points in Packaging §5:
    - Install guide tested from scratch on a clean VM ✓ (item 9)
    - Upgrade path tested ✓ (item 10)
    - Recovery planner used during at least one real HoT incident — document the first real
      incident where PN's planner output was consulted (already happened; needs write-up)
    - RBAC tested with two real users ✓ (done 2026-07-22)
    - Audit log verified for all action types ✓ (done)
    - All HoT services registered and health-checked ✓ (done)
    - Documentation written for a stranger ✓ (item 9)
    - No critical security issues ✓ (pending final check)

13. **ERPNext sandbox restore** — a real automated restore test for ERPNext on hot-erp-nl,
    equivalent to the PN self-restore test done 2026-07-16. Uses an isolated scratch MariaDB
    container, restores from the nightly mysqldump, runs a smoke query. Records result in
    `restore_tests`. Closes the one half-open sandbox restore gate item.

---

## 5. Out of Scope

- Cryptographic licence key validation (v7.0) — v6.0 uses `PN_EDITION` env var only
- Plugin/container architecture for Pro (may be revisited for v7.0 if CE/Pro split needs
  to be more hermetic than a single-repo model provides)
- Automated CI/CD for Docker Hub (manual push for the first release is fine)
- Managed Edition or hosted PrivateNexus (post-v7.0)
- First Professional beta customer (separate action item — requires the CE launch first)

---

## 6. Acceptance Gate

The v6.0 gate items this scope closes:

- [ ] `LICENSE` file contains real MIT text; `LICENSE.pro` created
- [ ] `PN_EDITION=community` install: Pro routes return 402, Pro nav items show upgrade prompt
- [ ] `PN_EDITION=professional` install: full feature set, no regressions
- [ ] README accurately describes the product (version, features, CE/Pro distinction)
- [ ] Install guide: tested from scratch on a clean VM — zero to running in under 30 minutes
- [ ] Upgrade guide: tested across one real version bump
- [ ] Docker Hub `privatenexus/community:latest` published and pullable
- [ ] All 8 commercial proof points from Packaging §5 documented and confirmed true
- [ ] ERPNext sandbox restore test recorded in `restore_tests`

---

*Related: `PrivateNexus_Commercial_Packaging_Licensing.md` §7 (open-core boundary),
`PrivateNexus_Release_Roadmap_v1.0.md` v6.0 gate*
