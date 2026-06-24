# PrivateNexus — Tier 9 Security Assessment Report
**Date:** 24 June 2026
**Scope:** Middleware chain, server configuration, dependency vulnerabilities, core modules
**Tester:** JARVIS / Claude Code (assisted, operator-supervised)
**Branch assessed:** `main` @ `098ba60`
**Prior tiers:**
- Tier 1–2: RBAC, session integrity
- Tier 3: Injection, route auth, port exposure
- Tier 4: Infrastructure exposure, container security posture
- Tier 5: Application logic, session, audit integrity
- Tier 6: Emergency ops safety, role completeness, input validation
- Tier 7: Audit trail integrity, workflow logic, validation completeness
- Tier 8: File management surface, remaining routes, ESM compatibility

---

## Executive Summary

Tier 9 reviewed the complete middleware chain (`server.js`, `requireAuth.js`, `requireRole.js`), core modules (`db.js`, `auditLog.js`), and ran `npm audit` across both the backend and frontend. The middleware and RBAC implementation are sound. The key findings were a known CVE in the `path-to-regexp` dependency (used by Express for route matching), a hardcoded session secret fallback that could silently weaken session security if the Docker secret is ever missing, and reversed priority for the database password source.

Frontend npm audit found Vite dev server CVEs, but the frontend container runs nginx with pre-built static assets — the Vite dev server is not exposed at runtime.

**5 findings were identified. 3 were fixed in commit `098ba60`. 2 were accepted.**

---

## Findings Summary

| ID   | Title                                                                           | Severity | Status   |
|------|---------------------------------------------------------------------------------|----------|----------|
| T9-1 | `path-to-regexp@0.1.12` — ReDoS via route parameters (CVE, range `<0.1.13`)   | HIGH     | Fixed    |
| T9-2 | `protobufjs` (CRITICAL) + `@grpc/grpc-js` (HIGH) — transitive via dockerode   | MEDIUM   | Accepted |
| T9-3 | `sessionSecret` silently falls back to `"dev-secret-change-me"` if unconfigured | LOW    | Fixed    |
| T9-4 | `db.js` — `DB_PASSWORD` env var takes priority over Docker secret               | LOW     | Fixed    |
| T9-5 | Vite frontend CVEs — path traversal + `server.fs.deny` bypass                  | INFO     | Accepted |

---

## Detailed Findings

---

### T9-1 — `path-to-regexp@0.1.12` ReDoS via route parameters
**Severity:** HIGH
**Component:** `app/backend/package.json` (transitive via `express@4.22.1`)

**Description:**
`npm audit` identified `path-to-regexp@0.1.12` as vulnerable to Regular Expression Denial of Service (ReDoS) via multiple route parameters (advisory range `< 0.1.13`). Express uses `path-to-regexp` to compile route patterns at startup and to match incoming request paths against registered routes.

The vulnerability is triggered by route patterns with multiple repeated or optional capture groups (e.g., `/:a-:b` or `/:foo+`) that cause catastrophic regex backtracking when matched against crafted inputs. A single malformed request to a vulnerable route could cause the matching regex to spin for an extended period, blocking the event loop and rendering the server unresponsive.

**PrivateNexus context:** All registered routes use simple single-parameter patterns (`/:id`, `/:container`, `/:fileId`). None use `+`, `*`, or hyphen-separated patterns. The practical ReDoS risk is low for the current route set, but patching eliminates the dependency class entirely and protects against future routes added with more complex patterns.

**Confirmed:** `npm audit` output, `path-to-regexp@0.1.12` installed; version `0.1.13` available as fixed version.

**Fix:** Added npm `overrides` to force `0.1.13` across all consumers of the package:

```json
// package.json
"overrides": {
  "path-to-regexp": "^0.1.13"
}
```

After `npm install` and container rebuild, `path-to-regexp@0.1.13` is confirmed inside the running container.

**Remaining npm audit items:** `express` still appears as moderate for a `qs` issue (separate advisory, unrelated to path-to-regexp). The advisory tracking lags the override — no new vulnerability is present.

---

### T9-2 — `protobufjs` (CRITICAL) + `@grpc/grpc-js` (HIGH) transitive via dockerode
**Severity:** MEDIUM
**Status:** Accepted

**Description:**
`npm audit` reports two high-severity transitive dependency chains:

```
privatenexus-backend
└── dockerode@4.0.10
    ├── @grpc/grpc-js@1.14.3    (HIGH: malformed request crashes gRPC server)
    └── protobufjs@7.5.4        (CRITICAL: code injection via bytes field defaults)
```

**Why not directly exploitable:**
- `protobufjs` code injection is triggered when parsing an untrusted protobuf **schema** with malicious `bytes` field defaults. PrivateNexus only uses protobufjs indirectly for Docker API communication using fixed, bundled proto schemas — no user-controlled schema parsing occurs.
- `@grpc/grpc-js` server crash requires the application to act as a **gRPC server** receiving malformed requests. PrivateNexus acts exclusively as a gRPC **client** (connecting to the Docker daemon); it does not expose a gRPC server endpoint.

**Mitigating path:** `dockerode@5.0.0` is available and may include patched transitive dependencies. Upgrading dockerode is a major version change that may require API adjustments. Recommended as a follow-on task outside the security tier scope.

**Action:** Accepted for this tier. Track `dockerode` upgrade separately.

---

### T9-3 — `sessionSecret` silently falls back to hardcoded `"dev-secret-change-me"`
**Severity:** LOW
**Component:** `app/backend/src/server.js`

**Description:**
The session secret resolution:
```javascript
const sessionSecret =
  readSecret("/run/secrets/session_secret") ??
  process.env.SESSION_SECRET ??
  "dev-secret-change-me";
```

If `/run/secrets/session_secret` is absent (e.g., secret not mounted after a compose change) and `SESSION_SECRET` is not set, the application starts silently using the literal string `"dev-secret-change-me"`. This string is in the public source repository. An attacker with the source code could forge `connect.sid` session cookies by computing the HMAC-SHA256 signature with this known key, bypassing authentication entirely.

The actual Docker secret was confirmed properly configured (62-byte random value). However, the silent fallback means a future misconfiguration (accidentally removing the secret from compose) would not be detected until an attacker exploits it.

**Fix:** Added a startup assertion that throws in non-development environments:

```javascript
if (sessionSecret === "dev-secret-change-me") {
  const envType = process.env.NODE_ENV || "production";
  if (envType !== "development") {
    throw new Error("FATAL: sessionSecret is the insecure default — configure /run/secrets/session_secret or SESSION_SECRET env var");
  }
  console.warn("[WARN] Using insecure default session secret — development only");
}
```

The container now fails to start (rather than silently using the known key) if the secret is absent in any non-development environment.

---

### T9-4 — `db.js` `DB_PASSWORD` env var takes priority over Docker secret
**Severity:** LOW
**Component:** `app/backend/src/db.js`

**Description:**
```javascript
// Before fix
password: process.env.DB_PASSWORD || readDbPassword(),
```

The `||` operator means `DB_PASSWORD` environment variable takes priority over `/run/secrets/db_password`. Environment variables are visible to all processes in the container, are logged by `docker inspect`, and are often captured in CI logs. Docker secrets are mounted as files with controlled permissions and are not exposed in `docker inspect` output.

The intended security model has Docker secrets as the authoritative source. If `DB_PASSWORD` were set (e.g., via an accident in compose), it would override the properly secured secret.

**Current state:** `DB_PASSWORD` is not set in `docker-compose.yml`; the compose file uses `POSTGRES_PASSWORD_FILE` (Docker secrets) for the database container. The issue is not currently exploited.

**Fix:**
```javascript
// After fix — secret file takes priority; env var is fallback for local dev only
password: readDbPassword() ?? process.env.DB_PASSWORD,
```

The `??` (nullish coalescing) ensures the secret file value is used if it returns a non-null/non-undefined value. `process.env.DB_PASSWORD` is only used if the secret file is absent.

---

### T9-5 — Vite frontend CVEs (path traversal, `server.fs.deny` bypass)
**Severity:** INFO
**Status:** Accepted

**Description:**
`npm audit` on the frontend reports two HIGH vulnerabilities in `vite@8.0.1`:
- "Vite Vulnerable to Path Traversal in Optimized Deps `.map` Handling"
- "Vite: `server.fs.deny` bypassed with queries"

Both vulnerabilities affect only the **Vite dev server** (`vite dev`), not the build output.

**Runtime verification:** The `privatenexus-frontend` container runs `nginx -g daemon off;` — it serves pre-built static assets via nginx, not via the Vite dev server. The Vite process is not running at runtime. The Vite CVEs have no attack surface in the deployed configuration.

**Build-time note:** The build step itself (`vite build`) is not affected by the server-side path traversal CVEs. The PostCSS moderate issue (XSS via unescaped `</style>`) is a build-time code generation concern but does not apply to the existing build output.

**Action:** Accepted. Update Vite to a patched version as a routine dependency bump. No runtime risk in the current nginx-based deployment.

---

## Server Configuration Assessment

The following global configuration was reviewed and found correctly implemented:

| Setting | Value | Assessment |
|---------|-------|------------|
| `trust proxy` | `1` | Correct — Caddy sets `X-Forwarded-For`; `req.ip` resolves client IP accurately |
| `helmet()` | CSP disabled | Accepted trade-off for SPA inline scripts; all other Helmet defaults active |
| `x-powered-by` | Disabled | Correct — `app.disable("x-powered-by")` removes Express fingerprinting |
| CORS | `origin: false` | Correct — no cross-origin headers emitted; browsers enforce same-origin |
| Body limit | `1mb` | Reasonable; prevents oversized JSON DoS |
| Auth limiter | 20 req / 15 min | Appropriate for login flow |
| API limiter | 300 req / min | Reasonable for internal operator tool |
| Session cookie | `httpOnly: true, secure: true (non-dev), sameSite: "lax"` | Correct |
| MCP token fallback | Throws if both sources absent | Correct — disables MCP rather than bypassing |

## RBAC Middleware Assessment

`requireAuth.js` and `requireRole.js` were reviewed and found sound:

- `requireAuth` checks `req.session?.user` — set only by the OIDC callback or MCP internal token; cannot be forged without the session signing secret
- `requireRole` uses a strict hierarchy with `Math.max(...[].filter(), -1)` correctly returning `-1` (below all roles) for empty role arrays
- No role name can be injected by the client — roles come exclusively from Keycloak JWT claims at OIDC callback time and are stored server-side in Redis
- `userRole()` helper correctly returns the highest role from an array of roles

---

## Remediation Summary

All 3 fixed findings resolved in commit `098ba60` on `git.securenexus.net/tristian/privatenexus`:

| Finding | Change |
|---------|--------|
| T9-1 | `"overrides": {"path-to-regexp": "^0.1.13"}` in `package.json`; container rebuilt with `0.1.13` |
| T9-3 | Startup assertion throws `FATAL` error if default secret used outside development |
| T9-4 | `readDbPassword() ?? process.env.DB_PASSWORD` — Docker secret now takes priority |

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
| 8    | File management surface, remaining routes, ESM     | 4        | 3     | 1       |
| 9    | Middleware, server config, dependencies            | 5        | 3     | 2       |
| **Total** | **All tiers**                                 | **39**   | **35**| **4**   |

**Accepted findings:**
- T5-5: Session fixation — mitigated by OIDC state/nonce + `sameSite: lax`
- T8-4: Docker labels expose compose paths — viewer-only, operator debugging use case
- T9-2: protobufjs/grpc-js — transitive via dockerode, not directly exploitable; upgrade dockerode separately
- T9-5: Vite frontend CVEs — dev server only; frontend container runs nginx with built static assets

*Assessment performed on pn-test (VLAN 60 / 10.10.60.105). All findings relate to the PrivateNexus v2.0.0 stack in its development deployment.*
