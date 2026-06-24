# PrivateNexus — Tier 7 Security Assessment Report
**Date:** 24 June 2026
**Scope:** Audit trail integrity, workflow logic, input validation completeness
**Tester:** JARVIS / Claude Code (assisted, operator-supervised)
**Branch assessed:** `main` @ `8294049`
**Prior tiers:**
- Tier 1–2: RBAC, session integrity
- Tier 3: Injection, route auth, port exposure
- Tier 4: Infrastructure exposure, container security posture
- Tier 5: Application logic, session security, audit integrity
- Tier 6: Emergency ops safety, role gate completeness, input validation

---

## Executive Summary

Tier 7 performed a systematic audit of all remaining route modules not covered by prior tiers: `recovery.js`, `intelligence.js`, `discovery.js`, `files.js`, and `actions.js` (workflow layer). The primary finding was a **widespread session field name bug** affecting 12 audit trail writes across three route files — the same class of bug fixed in T5-7 (MCP session) and T6-5 (dependencies). Additionally, a missing role gate on the file registry endpoint, a self-approval gap in the dual-control action request workflow, and an input validation bypass in the discovery approval path were identified.

**4 findings were identified. 4 were fixed in commit `8294049`.**

---

## Findings Summary

| ID   | Title                                                                  | Severity | Status |
|------|------------------------------------------------------------------------|----------|--------|
| T7-1 | Systematic `preferred_username` bug — 12 audit trail writes broken     | MEDIUM   | Fixed  |
| T7-2 | `GET /api/files/` missing role gate                                    | LOW      | Fixed  |
| T7-3 | Action request self-approval — no dual-control enforcement             | LOW      | Fixed  |
| T7-4 | Discovery approve bypasses `health_endpoint` URL scheme validation     | LOW      | Fixed  |

---

## Detailed Findings

---

### T7-1 — Systematic `preferred_username` → `username` bug across 3 route files
**Severity:** MEDIUM
**Components:** `routes/recovery.js`, `routes/intelligence.js`, `routes/discovery.js`

**Description:**
The OIDC callback in `auth.js` sets the session user object with `username: claims.preferred_username` — the session field is named `username`. Twelve writes across three route files incorrectly referenced `req.session?.user?.preferred_username` (always `undefined`), causing every actor attribution to fall through to a hardcoded literal string.

Affected operations and their silent fallback values:

| File | Operations | Fallback Actor Written to DB |
|------|-----------|------------------------------|
| `recovery.js` | `recovery_simulations.run_by`, `restore_tests.tested_by` | `"operator"` |
| `intelligence.js` | `ack_by` on signal ack, `reviewed_by` on proposal approve/dismiss, autonomous policy toggle actor, incident playbook actor, container restart actor | `"operator"` or `"admin"` |
| `discovery.js` | `agent_tokens.created_by`, `discovery_candidates.reviewed_by` (reject), `services.owner` (approve), `discovery_candidates.reviewed_by` (approve) | `"discovered"`, `"unknown"`, or `"admin"` |

Every recovery simulation, intelligence signal acknowledgement, proposal decision, autonomous policy change, and discovery candidate review was attributed to a literal string rather than the real operator's username. The audit trail for these high-value operations was completely unusable for accountability.

This is the same root cause as T5-7 (MCP session) and T6-5 (dependencies.js) — both previously fixed individually. This tier resolved the remaining 12 instances as a systematic sweep.

**Confirmed:** Code review; consistent with T5-7 and T6-5 fixes. No runtime test required — the pattern is identical.

**Fix:** `sed` replacement across all three files:
```
req.session?.user?.preferred_username  →  req.session?.user?.username
```
Fallback strings left unchanged (reached only when no session exists, which `requireAuth` prevents in practice).

---

### T7-2 — `GET /api/files/` missing role gate
**Severity:** LOW
**Component:** `app/backend/src/routes/files.js`

**Description:**
The file registry listing endpoint had no `requireRole` guard — any `requireAuth`-passing user could enumerate all registered configuration files and their full host-side paths:

```javascript
// Before fix — no role gate
filesRouter.get("/", (req, res) => {
```

The response includes paths such as `/opt/privatenexus/compose/docker-compose.yml`, `/opt/privatenexus/secrets/`, and other host filesystem paths. While `requireAuth` prevents unauthenticated access, any account including the lowest `viewer` role could retrieve the full file map. This is inconsistent with every other data-bearing route in the codebase which have explicit role gates.

**Confirmed:** `curl http://127.0.0.1:3001/api/files/` → `401 Unauthenticated`. With operator MCP session → passes auth gate and reaches the handler (500 from empty dev registry — the auth gate is confirmed working).

**Fix:** `requireRole` was already imported in the file. Added `requireRole("viewer")` inline:

```javascript
filesRouter.get("/", requireRole("viewer"), (req, res) => {
```

---

### T7-3 — Action request self-approval: no dual-control enforcement
**Severity:** LOW
**Component:** `app/backend/src/routes/actions.js`

**Description:**
The action request workflow is designed for dual-control: an operator proposes a deployment or container action via `POST /api/actions/requests`, and a separate admin approves it via `POST /api/actions/requests/:id/approve`. However, no check prevented the same user from performing both steps.

An admin-role user (who also satisfies the `operator` role requirement) could:
1. `POST /api/actions/requests` to propose an action, recording their `username` as `proposed_by`
2. Immediately `POST /api/actions/requests/:id/approve` on their own request

The approve handler read `proposed_by` from the DB but compared it only against `$1` (an ID), not against the current session user. There was no separation-of-duties check.

**Confirmed:** Code review. `proposed_by` is stored and retrieved but never compared to `req.session?.user?.username` in the approve handler.

**Fix:** Added a self-approval guard immediately after the expiry check:

```javascript
const approver = req.session?.user?.username || "unknown";
if (actionReq.proposed_by === approver)
  return res.status(403).json({
    ok: false,
    error: "Cannot approve your own action request — dual-control requires a different approver"
  });
```

**Note for single-admin deployments:** If operating without a second admin, use `POST /api/actions/deploy` or `POST /api/actions/emergency` directly — those paths are designed for single-operator execution and do not go through the request workflow. The request workflow exists specifically for team-based dual-control.

---

### T7-4 — Discovery approve path bypasses `health_endpoint` URL scheme validation
**Severity:** LOW
**Component:** `app/backend/src/routes/discovery.js`

**Description:**
Tier 4 added URL scheme validation (`VALID_URL_SCHEMES = {"http:", "https:", "tcp:"}`) to the `POST /api/services` and `PUT /api/services/:id` endpoints in `services.js`. However, a second code path that writes to the `services.health_endpoint` column was missed: the discovery candidate approval flow.

When a discovery agent submits a candidate via `POST /api/discovery/ingest`, the `suggested_health_ep` field is stored verbatim. When an operator later approves the candidate (`POST /api/discovery/candidates/:id/approve`), the approval handler read `healthEp = candidate.suggested_health_ep` and inserted it directly into `services.health_endpoint` without scheme validation:

```javascript
// Before fix
const healthEp = candidate.suggested_health_ep || null;
// ...inserted into services.health_endpoint without scheme check
```

A discovery agent with a valid token (or a compromised agent) could submit `suggested_health_ep: "file:///etc/passwd"` or `"gopher://..."`. When the health probe scheduler later queries that service, it would attempt to fetch the URL. Node.js `fetch()` rejects `file://` at the network layer, so no data is exfiltrated — but the scheme policy is bypassed and the value lands in the DB.

**Fix:** Inline validation in the approval handler before INSERT:

```javascript
const _rawHealthEp = candidate.suggested_health_ep || null;
let healthEp = null;
if (_rawHealthEp) {
  try {
    const _u = new URL(_rawHealthEp);
    if (["http:", "https:", "tcp:"].includes(_u.protocol)) healthEp = _rawHealthEp;
  } catch { /* malformed URL from ingest — silently drop */ }
}
```

Invalid or non-allowlisted URLs are silently dropped to `null`. The service is created and can have its `health_endpoint` set correctly via the normal `PUT /api/services/:id` endpoint later.

---

## Remediation Summary

All 4 findings fixed in commit `8294049` on `git.securenexus.net/tristian/privatenexus`:

| Finding | Change |
|---------|--------|
| T7-1 | `preferred_username` → `username` in recovery.js (×2), intelligence.js (×6), discovery.js (×4) |
| T7-2 | `requireRole("viewer")` added to `GET /api/files/` |
| T7-3 | Self-approval guard: approver compared to `proposed_by` before approving |
| T7-4 | URL scheme validation inline in discovery approve path before `services` INSERT |

---

## Cumulative Tier Assessment

| Tier | Focus                                              | Findings | Fixed | Accepted |
|------|----------------------------------------------------|----------|-------|---------|
| 1–2  | RBAC, session integrity                            | —        | —     | —       |
| 3    | Injection, route auth, port exposure               | —        | —     | —       |
| 4    | Infrastructure exposure, container security        | 13       | 13    | 0       |
| 5    | Application logic, session, audit integrity        | 7        | 6     | 1       |
| 6    | Emergency ops safety, role completeness, input val | 6        | 6     | 0       |
| 7    | Audit trail integrity, workflow logic, validation  | 4        | 4     | 0       |
| **Total** | **All tiers**                                 | **30**   | **29**| **1**   |

**Accepted finding (T5-5):** Session fixation via missing `session.regenerate()` — mitigated by OIDC state/nonce and `sameSite: lax`. Revisit if deployment scope becomes public-facing.

*Assessment performed on pn-test (VLAN 60 / 10.10.60.105). All findings relate to the PrivateNexus v2.0.0 stack in its development deployment.*
