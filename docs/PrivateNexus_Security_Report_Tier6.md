# PrivateNexus — Tier 6 Security Assessment Report
**Date:** 24 June 2026
**Scope:** Emergency action safety, role gate completeness, input validation, runtime integrity
**Tester:** JARVIS / Claude Code (assisted, operator-supervised)
**Branch assessed:** `main` @ `46df44e`
**Prior tiers:**
- Tier 1–2: RBAC, session integrity
- Tier 3: Injection, route auth, port exposure
- Tier 4: Infrastructure exposure, container security posture
- Tier 5: Application logic, session security, audit integrity

---

## Executive Summary

Tier 6 audited the remaining untested routes (actions, logs, alerts, activity, metrics, dependencies) with focus on emergency operation safety, role gate completeness, and input validation correctness. All routes had been authenticated by the global `requireAuth` middleware introduced in earlier tiers; Tier 6 found gaps in the *role level* required to access specific endpoints.

**6 findings were identified. All 6 were fixed in a single commit (`46df44e`).** The most critical was `stacks.restart-all` lacking the container blocklist that its sibling `stacks.stop-all` had — an admin could restart the database and Redis, wiping all active sessions fleet-wide.

---

## Findings Summary

| ID   | Title                                                           | Severity | Status |
|------|-----------------------------------------------------------------|----------|--------|
| T6-1 | `stacks.restart-all` — missing CONTAINER_BLOCKLIST check        | HIGH     | Fixed  |
| T6-2 | `GET /api/logs/:container` — no role gate (any viewer)          | MEDIUM   | Fixed  |
| T6-3 | `BigInt(since_id)` leaks JS error to client                     | LOW      | Fixed  |
| T6-4 | `GET /api/alerts/` and `/stream` — no role gate; SSE no timeout | LOW      | Fixed  |
| T6-5 | `dependencies.js` uses `preferred_username` for `created_by`   | LOW      | Fixed  |
| T6-6 | `GET /api/metrics/` — no role gate                              | INFO     | Fixed  |

---

## Detailed Findings

---

### T6-1 — `stacks.restart-all` missing CONTAINER_BLOCKLIST
**Severity:** HIGH
**Component:** `app/backend/src/routes/actions.js`

**Description:**
`POST /api/actions/emergency { action: "stacks.restart-all" }` iterated all running containers and restarted each without checking `CONTAINER_BLOCKLIST`. Its sibling action `stacks.stop-all` correctly skips blocklisted containers:

```javascript
// stop-all (correct)
if (CONTAINER_BLOCKLIST.has(name)) {
  results.push({ name, ok: false, skipped: true, reason: "blocklisted — not stopped" });
  continue;
}

// restart-all (missing check — BEFORE fix)
const name = (c.Names?.[0] || "").replace(/^\//, "");
try {
  await docker.getContainer(c.Id).restart({ t: 10 });  // restarts DB and Redis too
```

`CONTAINER_BLOCKLIST` contains `privatenexus-db` and `privatenexus-redis`. Restarting Redis invalidates all session data (no persistence configured) — every active user is logged out. Restarting the DB causes transient connection failures for all in-flight requests.

**Confirmed:** Code review. Not triggered in testing to avoid production disruption.

**Fix:** Added the identical blocklist check to `stacks.restart-all`:

```javascript
if (CONTAINER_BLOCKLIST.has(name)) {
  results.push({ name, ok: false, skipped: true, reason: "blocklisted — not restarted" });
  continue;
}
```

---

### T6-2 — Legacy `GET /api/logs/:container` missing role gate
**Severity:** MEDIUM
**Component:** `app/backend/src/routes/logs.js`

**Description:**
The legacy container log route had no `requireRole` guard:

```javascript
// before fix — any authenticated user (even viewer) can read any container's logs
logsRouter.get("/:container", async (req, res) => {
```

The newer `/api/logs/query` and `/api/logs/sources` routes correctly require `viewer`. Docker container logs can contain sensitive output: Redis AUTH commands in debug mode, database query errors with credential hints, session tokens in error stack traces, or API keys printed during startup.

**Confirmed:** `curl http://127.0.0.1:3001/api/logs/privatenexus-backend` (no session) → `401`. With a valid session (any role) → `200` with last 150 log lines.

**Fix:** Added `requireRole("operator")` — consistent with `GET /api/stacks/:id/logs` which already guards at operator level:

```javascript
logsRouter.get("/:container", requireRole("operator"), async (req, res) => {
```

---

### T6-3 — `BigInt(since_id)` leaks JS error text
**Severity:** LOW
**Component:** `app/backend/src/routes/activity.js`

**Description:**
`since_id` is passed to `BigInt()` without prior validation. A non-numeric value causes a `SyntaxError` that propagates to the catch block, which returns the raw JS error message to the client:

```
GET /api/activity?since_id=abc → HTTP 500
{"ok":false,"error":"Cannot convert abc to a BigInt"}
```

While the process did not crash (the route has a try-catch), the raw engine error text reveals that the implementation uses JavaScript BigInt for this ID, aiding fingerprinting.

**Fix:** Validate before conversion:

```javascript
if (!/^\d+$/.test(req.query.since_id))
  return res.status(400).json({ ok: false, error: "since_id must be a non-negative integer" });
params.push(BigInt(req.query.since_id));
```

---

### T6-4 — `GET /api/alerts/` and `/stream` missing role gate; SSE no timeout
**Severity:** LOW
**Component:** `app/backend/src/routes/alerts.js`

**Description:**
Both alert endpoints had no `requireRole` guard. Any authenticated user could read all firing Prometheus alerts and establish a streaming SSE connection. Additionally, the SSE stream had no connection timeout — a client could hold the connection open indefinitely, potentially exhausting available file descriptors or Caddy upstream connections.

**Fix:**
- Added `requireRole("viewer")` to both `GET /` and `GET /stream`
- Added a 10-minute hard timeout on the SSE connection:

```javascript
const timeout = setTimeout(() => { clearInterval(interval); res.end(); }, 10 * 60 * 1000);
req.on("close", () => { clearInterval(interval); clearTimeout(timeout); });
```

---

### T6-5 — `dependencies.js` uses `preferred_username` for `created_by`
**Severity:** LOW
**Component:** `app/backend/src/routes/dependencies.js`

**Description:**
```javascript
req.session?.user?.preferred_username || "operator"
```

The `req.session.user` object set by the OIDC callback uses `username`, not `preferred_username`. The `preferred_username` field is undefined for all real user sessions — so `created_by` was silently set to the literal string `"operator"` for every human-initiated dependency creation, making the audit trail useless for this table.

(This mirrors T5-7's MCP session bug, but affects the `service_dependencies.created_by` column rather than the audit log.)

**Fix:**
```javascript
req.session?.user?.username || "operator"
```

---

### T6-6 — `GET /api/metrics/` missing role gate
**Severity:** INFO
**Component:** `app/backend/src/routes/metrics.js`

**Description:**
`metricsRouter.get("/")` had no `requireRole`, making local CPU, memory, storage, and network history available to any authenticated session. The data is low-sensitivity but inconsistent with all other data-bearing routes in the codebase.

**Fix:** Added `requireRole("viewer")` for consistency.

---

## Remediation Summary

All 6 findings fixed in commit `46df44e` on `git.securenexus.net/tristian/privatenexus`:

| Finding | Change |
|---------|--------|
| T6-1 | `restart-all` blocklist check added (parity with `stop-all`) |
| T6-2 | `requireRole("operator")` on legacy `GET /api/logs/:container` |
| T6-3 | `since_id` validated as `/^\d+$/` before BigInt; returns HTTP 400 |
| T6-4 | `requireRole("viewer")` on alerts routes; SSE max 10-minute lifetime |
| T6-5 | `dependencies.js` uses `username` field for `created_by` |
| T6-6 | `requireRole("viewer")` on `GET /api/metrics/` |

---

## Cumulative Tier Assessment

| Tier | Focus                                              | Findings | Fixed | Accepted |
|------|----------------------------------------------------|----------|-------|---------|
| 1–2  | RBAC, session integrity                            | —        | —     | —       |
| 3    | Injection, route auth, port exposure               | —        | —     | —       |
| 4    | Infrastructure exposure, container security        | 13       | 13    | 0       |
| 5    | Application logic, session, audit integrity        | 7        | 6     | 1       |
| 6    | Emergency ops safety, role completeness, input val | 6        | 6     | 0       |

*Assessment performed on pn-test (VLAN 60 / 10.10.60.105). All findings relate to the PrivateNexus v2.0.0 stack in its development deployment.*
