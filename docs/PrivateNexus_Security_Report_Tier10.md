# PrivateNexus — Tier 10 Security Assessment Report
**Date:** 24 June 2026
**Scope:** Auth flow, file registry defaults, health probe SSRF, services route gate
**Tester:** JARVIS / Claude Code (assisted, operator-supervised)
**Branch assessed:** `main` @ `c678525`
**Prior tiers:**
- Tier 1–2: RBAC, session integrity
- Tier 3: Injection, route auth, port exposure
- Tier 4: Infrastructure exposure, container security posture
- Tier 5: Application logic, session, audit integrity
- Tier 6: Emergency ops safety, role completeness, input validation
- Tier 7: Audit trail integrity, workflow logic, validation completeness
- Tier 8: File management surface, remaining routes, ESM compatibility
- Tier 9: Middleware chain, server configuration, dependency vulnerabilities

---

## Executive Summary

Tier 10 completed the review of the authentication flow (`auth.js`), health scheduler and probe (`healthScheduler.js`, `healthProbe.js`), file registry module (`filesRegistry.js`), service management route (`services.js`), and the full `docker-compose.yml`.

The most significant finding was a critical bypass of the T8-3 path blocklist: two entries in the `filesRegistry.js` DEFAULTS array hardcoded app source files as `editable: true`, making them writable via `POST /api/files/write` despite the registration API correctly blocking those paths. Three further findings were identified — raw error message leakage on auth failures, a logout CSRF vector, and a missing role gate on the services list endpoint.

The health scheduler and Docker Compose configuration were both found well-configured, with one blind SSRF risk accepted.

**5 findings were identified. 4 were fixed in commit `c678525`. 1 was accepted.**

---

## Findings Summary

| ID    | Title                                                                        | Severity | Status   |
|-------|------------------------------------------------------------------------------|----------|----------|
| T10-1 | `filesRegistry.js` DEFAULTS — `server.js` hardcoded as `editable: true`     | CRITICAL | Fixed    |
| T10-2 | `auth.js` — raw `err.message` sent to client on login/callback failure       | LOW      | Fixed    |
| T10-3 | `GET /api/auth/logout` — no CSRF protection                                  | LOW      | Fixed    |
| T10-4 | `healthProbe.js` — blind SSRF via `health_endpoint` (admin-controlled)       | LOW      | Accepted |
| T10-5 | `GET /api/services/` — missing `requireRole("viewer")` gate                  | INFO     | Fixed    |

---

## Detailed Findings

---

### T10-1 — `filesRegistry.js` DEFAULTS hardcodes `server.js` as `editable: true`
**Severity:** CRITICAL
**Component:** `app/backend/src/filesRegistry.js`

**Description:**
Tier 8 added `/opt/privatenexus/app` to the `BLOCKED_PREFIXES` list in the `POST /api/files/register` handler to prevent admins from registering backend source files as editable entries. However, the `DEFAULTS` array in `filesRegistry.js` — which is merged into the registry at every `loadRegistry()` call without passing through the API blocklist — contained two entries that hardcoded app source paths as `editable: true`:

```javascript
// Before fix — both entries had editable: true
{
  id: "privatenexus-backend-server",
  path: "/opt/privatenexus/app/backend/src/server.js",
  editable: true,    // ← bypasses BLOCKED_PREFIXES in the register API
  ...
},
{
  id: "privatenexus-frontend-env",
  path: "/opt/privatenexus/app/frontend/.env",
  editable: true,
  applyStrategy: "compose-up",
  ...
}
```

Since DEFAULTS entries are returned directly by `getRegisteredFileById()`, they are accepted by the `/api/files/write` handler (which checks the registry, not BLOCKED_PREFIXES). A user with admin role could:

1. Call `GET /api/files/` — `privatenexus-backend-server` appears in the registry with `editable: true`
2. Call `POST /api/files/write` with `id: "privatenexus-backend-server"` and arbitrary JavaScript content
3. The write overwrites `/opt/privatenexus/app/backend/src/server.js` on the host volume
4. Call `POST /api/emergency/stacks.restart-all` (superadmin) or wait for container restart — the new `server.js` is executed by Node.js

This is a complete container escape path: arbitrary code execution under the container's UID 1000, with access to all mounted secrets and the Docker socket proxy.

**Confirmed:** DEFAULTS array reviewed directly. `getRegisteredFileById("privatenexus-backend-server")` returns the entry; `/api/files/write` checks `entry.editable === true` before proceeding.

**Fix:**
```javascript
// After fix — source files are read-only registry entries
{ id: "privatenexus-backend-server", editable: false, ... }
{ id: "privatenexus-frontend-env",   editable: false, ... }
```

The compose file (`privatenexus-compose`) remains `editable: true` — it is an intended managed artefact. The source files are informational-only entries; admins who need to modify backend source should use git and the CI pipeline.

---

### T10-2 — `auth.js` raw `err.message` sent to client on auth failure
**Severity:** LOW
**Component:** `app/backend/src/routes/auth.js`

**Description:**
Both the login and callback error handlers returned the full exception message string directly to the HTTP client:

```javascript
// Before fix
res.status(500).send(`Auth init failed: ${err.message}`);
res.status(500).send(`Auth callback failed: ${err.message}`);
```

`err.message` from the `openid-client` library can contain Keycloak discovery endpoint URLs, OIDC token endpoint details, internal realm names, HTTP response bodies from the IdP, and connection error details (e.g., IP addresses of internal services). This information aids an attacker in mapping the SSO architecture and identifying misconfiguration vectors.

**Fix:**
```javascript
// After fix — generic message; actual error logged server-side
console.error("[auth] login error:", err.message);
res.status(500).send("Authentication failed. Please try again.");

console.error("[auth] callback error:", err.message);
res.status(500).send("Authentication failed. Please try again.");
```

The error is preserved in server logs (visible in `docker logs privatenexus-backend`) for operator debugging without being exposed to the client.

---

### T10-3 — `GET /api/auth/logout` — CSRF via cross-site GET navigation
**Severity:** LOW
**Component:** `app/backend/src/routes/auth.js`

**Description:**
The logout endpoint accepts `GET` requests with no CSRF token or origin validation:

```javascript
// Before fix
authRouter.get("/logout", (req, res) => {
  // destroys session immediately
  req.session.destroy(() => { res.redirect(keycloakLogoutUrl); });
});
```

The session cookie is set with `sameSite: "lax"`. Under the `lax` policy, browsers include the cookie for **top-level cross-site navigations** (clicking a link, `<a href="...">`, `window.location` redirect from a cross-origin page, etc.). A malicious page can silently log out a PrivateNexus user by including:

```html
<a href="https://privatenexus.net/api/auth/logout">Click here</a>
<!-- or auto-redirecting via JavaScript -->
<script>window.location = "https://privatenexus.net/api/auth/logout";</script>
```

**Impact:** Forced logout causes disruption (session loss, active work interrupted). If the victim re-authenticates immediately, they are redirected to Keycloak — the attacker cannot intercept credentials, but can force re-authentication repeatedly (DoS on session).

**Fix:** Added Origin/Referer validation before destroying the session:

```javascript
authRouter.get("/logout", (req, res) => {
  const origin  = req.headers.origin  || "";
  const referer = req.headers.referer || "";
  const appOrigin = new URL(POST_LOGOUT_URI).origin;   // "https://privatenexus.net"
  if ((origin && origin !== appOrigin) || (referer && !referer.startsWith(appOrigin))) {
    return res.status(403).send("Logout CSRF check failed");
  }
  // ... proceed with session destroy
```

Cross-site GET navigations that carry an `Origin` header mismatching the app origin are rejected. Legitimate logouts from the app UI either carry the correct `Origin` or omit it (direct navigation), both of which pass the check.

---

### T10-4 — `healthProbe.js` — blind SSRF via `health_endpoint`
**Severity:** LOW
**Status:** Accepted

**Description:**
`probeAllServices()` fetches every `health_endpoint` stored in the `services` table without an IP allowlist:

```javascript
const r = await fetch(svc.health_endpoint, { method: "GET", signal: AbortSignal.timeout(PROBE_TIMEOUT_MS) });
```

The `validateUrl()` function in `services.js` validates that `health_endpoint` uses `http:`, `https:`, or `tcp:` schemes, but does not check whether the target IP is internal. An admin (the only role that can create/update services) could set:

```
health_endpoint = "http://10.10.0.2:8006/api2/json"    // Proxmox API
health_endpoint = "http://10.10.50.104:9090/metrics"    // Prometheus
health_endpoint = "tcp://10.10.10.100:22"               // Forgejo host SSH
```

The health scheduler would probe these every 2 minutes. The **response body is never returned** to any client — only `status`, `statusCode`, and `latencyMs` are stored in `health_events`. This is **blind SSRF**: an attacker can determine if an internal service is up/responding on a specific port, but cannot exfiltrate response content.

**Why accepted:**
- Setting `health_endpoint` requires admin role
- Admin already has access to compose file editing, emergency restart, and other high-privilege operations
- No response body is ever returned — information leakage is limited to port reachability
- All services on the internal network are already documented in CLAUDE.md and visible to admins

**Recommendation:** If a lower-privileged role (e.g., operator) is ever granted `health_endpoint` write access, add an RFC 1918 / loopback blocklist to `validateUrl()`:
```javascript
// Suggested future guard
const { hostname } = new URL(urlStr);
const ip = await dns.lookup(hostname);
if (isPrivateIP(ip)) return `${field} must not target a private IP range`;
```

---

### T10-5 — `GET /api/services/` missing `requireRole("viewer")`
**Severity:** INFO
**Component:** `app/backend/src/routes/services.js`

**Description:**
Every other data-bearing route in the codebase uses an explicit `requireRole` guard. The service list endpoint was the sole exception:

```javascript
// Before fix — no requireRole, only global requireAuth
servicesRouter.get("/", async (req, res) => { ... });
```

Any session that passed the global `requireAuth` middleware — regardless of role — could retrieve the full service list, including `health_endpoint`, `access_url`, container names, and access modes. The global `requireAuth` prevents unauthenticated access; however, consistent role enforcement is required for the eventual multi-tenant and guest-access scenarios.

**Fix:**
```javascript
servicesRouter.get("/", requireRole("viewer"), async (req, res) => { ... });
```

`viewer` is the minimum application role — this change does not restrict any legitimate user and aligns the endpoint with all other read routes.

---

## Health Scheduler Assessment

`healthScheduler.js` was reviewed and found well-implemented:

| Property | Value | Assessment |
|----------|-------|------------|
| Interval | 2 min | Reasonable for operational dashboards |
| Concurrent cycle guard | `running` flag with `try/finally` | Correct — prevents overlapping cycles |
| Error handling | `try/finally` always resets `running` | Correct — scheduler survives probe failures |
| Retention | 30 days (`RETENTION_DAYS`) | Appropriate |
| Intel enrichment | Every 5th cycle (`INTEL_EVERY_N = 5`) | Rate-limited as expected |

No security issues found in the scheduler itself beyond the T10-4 SSRF surface it invokes.

---

## Docker Compose Security Assessment

`compose/docker-compose.yml` was reviewed:

| Control | Value | Assessment |
|---------|-------|------------|
| Backend user | `user: "1000"` | Non-root — correct |
| Capabilities | `cap_drop: ALL` | Correct — no ambient capabilities |
| Privilege escalation | `no-new-privileges: true` | Correct |
| Docker socket | Via `tecnativa/docker-socket-proxy` only | Correct — `EXEC: 0`, `NETWORKS: 0` |
| Secrets | All credentials via Docker secrets | Correct — no plaintext env vars for credentials |
| Network segmentation | `pn-internal` (internal) + `pn-edge` | Correct — DB/Redis not reachable from edge |
| Backend port | `127.0.0.1:3001:3001` | Localhost-only bind — correct |
| MCP port | `127.0.0.1:3002:3002` | Localhost-only bind — correct |
| `REDIS_URL` | `redis://privatenexus-redis:6379` | No auth in URL — password via Redis `requirepass` in `command:` | ✓ |

**One observation:** The backend volume mount is `- /opt/privatenexus:/opt/privatenexus`. This gives the container write access to `/opt/privatenexus/secrets/*.txt` (the Docker secret source files) at runtime, in addition to the secrets mounted at `/run/secrets/`. The secrets are already blocked from being registered as file registry entries (T8-3 BLOCKED_PREFIXES includes `/opt/privatenexus/secrets`), and the `file registry` admin write path validates against this list. No additional fix needed, but noted for awareness.

---

## Remediation Summary

All 4 fixed findings resolved in commit `c678525` on `git.securenexus.net/tristian/privatenexus`:

| Finding | Change |
|---------|--------|
| T10-1 | `editable: false` on `privatenexus-backend-server` and `privatenexus-frontend-env` in `DEFAULTS` |
| T10-2 | `console.error` + generic `"Authentication failed. Please try again."` in login/callback error handlers |
| T10-3 | Origin/Referer validation before session destroy in `GET /api/auth/logout` |
| T10-5 | `requireRole("viewer")` added to `GET /api/services/` |

---

## Cumulative Tier Assessment

| Tier | Focus                                              | Findings | Fixed | Accepted |
|------|----------------------------------------------------|----------|-------|----------|
| 1–2  | RBAC, session integrity                            | —        | —     | —        |
| 3    | Injection, route auth, port exposure               | —        | —     | —        |
| 4    | Infrastructure exposure, container security        | 13       | 13    | 0        |
| 5    | Application logic, session, audit integrity        | 7        | 6     | 1        |
| 6    | Emergency ops safety, role completeness, input val | 6        | 6     | 0        |
| 7    | Audit trail integrity, workflow logic, validation  | 4        | 4     | 0        |
| 8    | File management, remaining routes, ESM compat      | 4        | 3     | 1        |
| 9    | Middleware, server config, dependencies            | 5        | 3     | 2        |
| 10   | Auth flow, file registry, health probes, compose   | 5        | 4     | 1        |
| **Total** | **All tiers**                                | **44**   | **39**| **5**    |

**Accepted findings (cumulative):**
- T5-5: Session fixation — mitigated by OIDC state/nonce + `sameSite: lax`
- T8-4: Docker labels expose compose paths — viewer-only, operator debugging use case
- T9-2: protobufjs/grpc-js — transitive via dockerode, not directly exploitable; upgrade dockerode separately
- T9-5: Vite frontend CVEs — dev server only; frontend container runs nginx with built static assets
- T10-4: Blind SSRF via `health_endpoint` — admin-only; no response body exfiltration; add IP blocklist if operator role gains write access

*Assessment performed on pn-test (VLAN 60 / 10.10.60.105). All findings relate to the PrivateNexus v2.0.0 stack in its development deployment.*
