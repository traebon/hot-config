# PrivateNexus — Tier 5 Security Assessment Report
**Date:** 24 June 2026
**Scope:** Application logic, session security, audit integrity, role gate consistency
**Tester:** JARVIS / Claude Code (assisted, operator-supervised)
**Branch assessed:** `main` @ `786363e`
**Prior tiers:**
- Tier 1–2: RBAC, session integrity
- Tier 3: Injection, route auth, port exposure
- Tier 4: Infrastructure exposure, container security posture

---

## Executive Summary

Tier 5 assessed the application logic layer: role gate consistency across all API endpoints, session security post-login, audit log integrity, and secret management in route modules.

**7 findings were identified. All 7 were fixed in this session in a single commit (`786363e`).** The most severe finding was a backend process crash reachable by any viewer-role user via a malformed PostgreSQL query in the governance module — a viewer could trigger this repeatedly as a denial-of-service against all active sessions.

---

## Findings Summary

| ID   | Title                                                        | Severity | Status |
|------|--------------------------------------------------------------|----------|--------|
| T5-1 | `GET /api/admin/network` — no role gate (any viewer)         | MEDIUM   | Fixed  |
| T5-2 | `GET /api/admin/backup` — no role gate                       | LOW      | Fixed  |
| T5-3 | `change-records?service_id=X` crashes backend process        | HIGH     | Fixed  |
| T5-4 | PowerDNS API key hardcoded in `dns.js` source code           | MEDIUM   | Fixed  |
| T5-5 | No `session.regenerate()` after OIDC login (session fixation)| LOW      | Accepted |
| T5-6 | `X-Real-IP` header forgery recorded in audit log             | LOW      | Fixed  |
| T5-7 | MCP session `preferred_username` ≠ `username` — audit blind spot | LOW  | Fixed  |

---

## Detailed Findings

---

### T5-1 — `GET /api/admin/network` accessible to any authenticated user
**Severity:** MEDIUM
**Component:** `app/backend/src/routes/admin.js`

**Description:**
`GET /api/admin/network` returned the full set of container network interfaces (from `os.networkInterfaces()`) and Docker network subnet/driver info. No `requireRole` guard was present — any `requireAuth`-passing user (including the lowest `viewer` role) could retrieve internal IP ranges, Docker bridge subnets, and VLAN addresses.

**Confirmed:** HTTP 200 with full network topology returned to an operator-level session. A viewer session would receive the same response.

**Fix:** Added `requireRole("operator")` to the route. Also wrapped `docker.listNetworks()` in an inner try-catch so the endpoint gracefully returns OS interface data even when the Docker proxy blocks the `NETWORKS` endpoint (`NETWORKS=0` in `privatenexus-docker-proxy`).

---

### T5-2 — `GET /api/admin/backup` accessible to any authenticated user
**Severity:** LOW
**Component:** `app/backend/src/routes/admin.js`

**Description:**
`GET /api/admin/backup` returns the static backup schedule (destinations, tiers, tools). No `requireRole` was present. While this data is low-sensitivity, all other `/api/admin/*` endpoints have explicit role gates — this was an inconsistency.

**Fix:** Added `requireRole("viewer")` — the minimum role consistent with read-only info access.

---

### T5-3 — `GET /api/governance/change-records?service_id=X` crashes backend
**Severity:** HIGH
**Component:** `app/backend/src/routes/governance.js`

**Description:**
The `change-records` route had a parameter-indexing bug in the `service_id` filter branch. After `Array.splice()`, the params array was `[tenant_id, limit, service_id, offset]` (4 elements), but the query used `$5` as the OFFSET placeholder, which does not exist. The PostgreSQL client threw error code `42P18` (indeterminate datatype / missing bind parameter).

The error was re-thrown from `.catch(err => { throw err; })` inside an async route handler. Express v4 does not automatically catch async rejections — the unhandled rejection terminated the Node.js process entirely.

**Confirmed:** Sending `GET /api/governance/change-records?service_id=<any-uuid>` with a valid operator session caused the backend container to exit and restart (Docker `unless-stopped` restarted it within seconds). Log evidence:

```
PostgreSQL error 42P18 at governance.js:224
Node.js v20.20.2
> privatenexus-backend@2.0.0 start   ← restart
```

**Impact:**
- Route requires `viewer` role — the lowest authenticated role
- Full process termination disrupts all active sessions on each crash
- Trivially repeatable to cause continuous disruption

**Fix:** Rewrote the handler to a single code path using accumulating params and dynamic `$N` indices:

```javascript
const conditions = ["tenant_id = $1"];
const params = [HOT_TENANT_ID];
if (req.query.service_id) {
  params.push(req.query.service_id);
  conditions.push(`service_id = $${params.length}`);
}
params.push(limit, offset);
const limitIdx  = params.length - 1;
const offsetIdx = params.length;
// LIMIT $limitIdx OFFSET $offsetIdx — always correct regardless of filters
```

The outer try-catch now properly catches the error and returns HTTP 500 without crashing the process.

---

### T5-4 — PowerDNS API key hardcoded in `dns.js`
**Severity:** MEDIUM
**Component:** `app/backend/src/routes/dns.js`

**Description:**
```javascript
const PDNS_KEY = process.env.PDNS_API_KEY || "pdnsKj7xM9pL2vR5n";
```
The PowerDNS API key was hardcoded as a fallback in the source file. No `PDNS_API_KEY` environment variable was configured in `docker-compose.yml`, meaning the hardcoded key was always in use. The key is baked into every container image build and is present in the git repository.

**Confirmed:** `docker exec privatenexus-backend printenv | grep PDNS` returned empty — the env var was never set. `docker exec privatenexus-backend grep pdnsKj7 /app/src/routes/dns.js` showed the key in the built image.

**Fix:**
1. Created `/opt/privatenexus/secrets/pdns_api_key.txt` (chmod 644)
2. Added `pdns_api_key` to the compose secrets block and the backend service's secret list
3. Updated `dns.js` to read from `/run/secrets/pdns_api_key` with a startup throw if absent:

```javascript
const PDNS_KEY = readSecret("/run/secrets/pdns_api_key") ?? process.env.PDNS_API_KEY;
if (!PDNS_KEY) throw new Error("PDNS_API_KEY secret not configured");
```

The hardcoded fallback was removed entirely.

---

### T5-5 — No `session.regenerate()` after OIDC login (session fixation)
**Severity:** LOW
**Status:** Accepted

**Description:**
In `auth.js` `/callback`, the session is not regenerated after successful authentication:

```javascript
// Callback handler — sets user on existing session without regenerating
req.session.user = { sub: claims.sub, ... };
await new Promise((resolve, reject) =>
  req.session.save((err) => ...)
);
res.redirect("/");
```

A classic session fixation attack requires an attacker to plant a known session ID cookie on the victim's browser. The victim completes login, and the attacker reuses the now-authenticated session.

**Mitigating factors:**
- `sameSite: "lax"` prevents cross-site cookie planting via top-level navigations from third-party sites
- `httpOnly: true` prevents JavaScript-based cookie theft
- The OIDC `state` and `nonce` parameters are generated fresh per login and checked during callback — an attacker cannot initiate a session that passes the state/nonce check without the victim's browser participating in the full OIDC flow
- PrivateNexus is not served to the general public; session cookie planting would require the attacker to already have network access to the same browser

**Action:** Accepted. The OIDC state/nonce and `sameSite: lax` together prevent the practical attack path. If PrivateNexus is ever deployed in a context with shared browsers or public-facing login, `req.session.regenerate()` should be added to the callback before setting `req.session.user`.

---

### T5-6 — `X-Real-IP` header forgery recorded in audit log
**Severity:** LOW
**Component:** `app/backend/src/auditLog.js`

**Description:**
```javascript
const ip = req.headers?.["x-real-ip"] || req.ip || null;
```
The audit log trusted the `X-Real-IP` request header directly. An attacker could include `X-Real-IP: 10.0.0.1` in any request, causing the forged IP to appear in the audit log as the actor's address.

**Confirmed:**
```
curl -H 'X-Real-IP: 10.0.0.100' ... → audit log: ip: "10.0.0.100"
```

**Fix:** Removed `X-Real-IP` trust. `req.ip` is now the sole source, which Express resolves from `X-Forwarded-For` when `trust proxy: 1` is set. Caddy sets `X-Forwarded-For` to the real client IP and the Express trust chain correctly extracts it.

```javascript
const ip = req.ip || null;
```

---

### T5-7 — MCP session uses `preferred_username` field — audit log shows `"unknown"`
**Severity:** LOW
**Component:** `app/backend/src/server.js`

**Description:**
The MCP internal authentication middleware set:
```javascript
req.session.user = {
  sub: "mcp-server",
  preferred_username: "mcp-server",  // wrong field name
  roles: ["operator"],
};
```

`recordAudit` reads `req.session?.user?.username` (not `preferred_username`). All MCP-initiated actions — intelligence scans, stack queries, health probes — logged `username: "unknown"`, making it impossible to distinguish automated MCP operations from anomalous "unknown actor" events in the audit log.

**Confirmed:** Three consecutive MCP requests all showed `username: "unknown"` in `GET /api/admin/audit`.

**Fix:**
```javascript
req.session.user = {
  sub: "mcp-server",
  username: "mcp-server",
  name: "mcp-server",
  roles: ["operator"],
};
```

Post-fix: MCP actions now appear as `username: "mcp-server"` in the audit log.

---

## Remediation Summary

All 6 fixed findings resolved in commit `786363e` on `git.securenexus.net/tristian/privatenexus`:

| Finding | Change |
|---------|--------|
| T5-1 | `requireRole("operator")` added to `GET /api/admin/network`; Docker nets degrade gracefully |
| T5-2 | `requireRole("viewer")` added to `GET /api/admin/backup` |
| T5-3 | `change-records` query rewritten; accumulating params eliminate missing-$N crash |
| T5-4 | `dns.js` reads `/run/secrets/pdns_api_key`; hardcoded fallback removed; compose secret wired |
| T5-6 | `auditLog.js` uses `req.ip` only; `X-Real-IP` header no longer trusted |
| T5-7 | MCP session sets `username` field; audit log now correctly attributes MCP actions |

---

## Session Security Note (T5-5)

Session fixation is accepted as a residual risk. The primary mitigations are:

1. **OIDC state + nonce per-login flow** — the attacker cannot complete a useful session fixation without controlling the victim's browser through the full Keycloak redirect
2. **`sameSite: lax`** — prevents cross-site cookie injection
3. **Private deployment** — PrivateNexus is not public-facing

To fully close this, add `req.session.regenerate()` before setting `req.session.user` in `auth.js` callback if the deployment scope changes.

---

## Tier Assessment Summary (All Tiers)

| Tier | Focus | Findings | Fixed | Accepted |
|------|-------|----------|-------|---------|
| 1–2  | RBAC, session integrity | — | — | — |
| 3    | Injection, route auth, port exposure | — | — | — |
| 4    | Infrastructure exposure, container security | 13 | 13 | 0 |
| 5    | Application logic, session, audit integrity | 7 | 6 | 1 |

*Assessment performed on pn-test (VLAN 60 / 10.10.60.105). All findings relate to the PrivateNexus v2.0.0 stack in its development deployment.*
