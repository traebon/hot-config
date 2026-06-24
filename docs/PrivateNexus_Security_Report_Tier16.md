# PrivateNexus — Tier 16 Security Assessment Report
**Date:** 24 June 2026
**Scope:** Server configuration (`server.js`); authentication flow (`auth.js`); eight remaining route files — `governance.js`, `alerts.js`, `activity.js`, `admin.js`, `logs.js`, `intelligence.js`, `recovery.js`, `services.js`; supporting modules — `fileValidator.js`, `healthScheduler.js`, `metrics.js`
**Tester:** JARVIS / Claude Code (assisted, operator-supervised)
**Branch assessed:** `main` @ `0d5d831`

---

## Executive Summary

Tier 16 completed the audit of the remaining unreviewed route files and the global server configuration. `server.js` and `auth.js` had three findings: a logout endpoint CSRF check that could be bypassed by stripping both Origin and Referer headers, a non-constant-time string comparison for the MCP internal authentication token, and an unbounded search parameter on the Loki log query endpoint. The most pervasive finding was a systematic `err.message` leakage pattern across eight route files — the same class as T13-3 (stacks.js), but not caught in that tier's scope. Fifty-seven catch blocks across governance, alerts, activity, admin, logs, intelligence, recovery, and services routes were responding with internal error details (PostgreSQL constraint names, Prometheus/Loki HTTP error codes, Docker error strings) visible to authenticated callers at viewer and operator level.

`fileValidator.js`, `healthScheduler.js`, and `metrics.js` were found clean.

**4 findings were identified. All 4 were fixed in commit `9ac84e8`.**

---

## Findings Summary

| ID    | Title                                                                                       | Severity | Status |
|-------|---------------------------------------------------------------------------------------------|----------|--------|
| T16-1 | `err.message` leakage in 57 catch blocks across 8 route files — exposes internal error details | LOW   | Fixed  |
| T16-2 | `GET /api/auth/logout` CSRF check bypassed when Origin and Referer both absent              | LOW      | Fixed  |
| T16-3 | `server.js` — MCP token compared with `===` (non-constant-time)                            | INFO     | Fixed  |
| T16-4 | `logs.js` — `search` query parameter has no length cap (unbounded LogQL query)             | INFO     | Fixed  |

---

## Detailed Findings

---

### T16-1 — `err.message` leakage across 8 route files
**Severity:** LOW
**Component:** `routes/governance.js` (10), `routes/intelligence.js` (12), `routes/recovery.js` (6+5), `routes/services.js` (13), `routes/admin.js` (6), `routes/logs.js` (3), `routes/activity.js` (1), `routes/alerts.js` (1)

**Description:**

The global Express error handler introduced in `server.js` correctly sanitises unhandled errors:

```javascript
app.use((err, _req, res, _next) => {
  if (status >= 500) return res.status(500).json({ ok: false, error: 'Internal server error' });
  ...
});
```

However, 57 catch blocks across 8 route files used local `try/catch` with direct `err.message` responses, bypassing the global handler:

```javascript
// Before fix — example from governance.js (viewer-accessible)
} catch (err) { res.status(500).json({ ok: false, error: err.message }); }
```

The `err.message` content varies by context but includes:
- **PostgreSQL errors**: constraint names, column names, relation names, violation details — e.g. `duplicate key value violates unique constraint "policy_rules_rule_key_key"`, `null value in column "tenant_id" violates not-null constraint`
- **Prometheus/Loki errors**: `Prometheus 503`, `Loki 502`, internal URL construction failures
- **Docker daemon errors**: container name, API path details from dockerode failures

**Affected access levels:**
- `governance.js` summary/recommendations/rules/exceptions/change-records → viewer+
- `alerts.js` `/` and `/stream` → viewer+
- `logs.js` query/sources → viewer+
- `activity.js` `/` → operator+
- `admin.js` network/certs/disk/users/audit → operator+/admin+
- `intelligence.js`, `recovery.js`, `services.js` → varies by route, operator+ to admin+

The T13-3 fix addressed this pattern in `stacks.js` but the same pattern was present throughout the codebase, unreviewed until this tier.

**Fix:** All 57 catch blocks were updated to log server-side and return a generic response:

```javascript
// After fix
} catch (err) {
  console.error("[governance] error:", err.message);
  res.status(500).json({ ok: false, error: "Service unavailable" });
}
```

The log prefix (`[governance]`, `[alerts]`, etc.) identifies the source route in server logs without exposing details to the client.

**Note on internal intelligence.js `return { ok: false, error: err.message }` patterns:** Two occurrences in `intelligence.js` (`probeService()` and `executeAction()`) use `return { ok: false, error: err.message }` in internal helper functions whose return values are consumed by the scheduler, not sent as HTTP responses. These were intentionally left unchanged — they are not HTTP leaks.

---

### T16-2 — `GET /api/auth/logout` CSRF check bypassed when Origin and Referer both absent
**Severity:** LOW
**Component:** `app/backend/src/routes/auth.js`

**Description:**

The logout endpoint protects against CSRF by checking Origin and Referer against the application's expected origin:

```javascript
// Before fix
const origin = req.headers.origin || "";
const referer = req.headers.referer || "";
const appOrigin = new URL(POST_LOGOUT_URI).origin;
if ((origin && origin !== appOrigin) || (referer && !referer.startsWith(appOrigin))) {
  return res.status(403).send("Logout CSRF check failed");
}
```

The logic reads: _if Origin is present AND wrong → reject; if Referer is present AND wrong → reject_. When both are empty strings (falsy), neither condition fires and the check passes entirely. This means:

- A request with no `Origin` or `Referer` header bypasses all CSRF protection.
- CSRF attacks that strip outgoing headers (e.g. `fetch("/api/auth/logout", { referrerPolicy: "no-referrer", headers: {} })` embedded in a malicious page) would proceed past the check.

**Attack path:** The session cookie is `sameSite: lax`, which sends the cookie on top-level GET navigation but NOT on cross-origin fetch/XHR. A cross-origin fetch with `referrerPolicy: "no-referrer"` does not qualify as a top-level navigation, so the cookie would not be sent in that case — this partially mitigates the risk. However, a `<form method="get" action="https://privatenexus.net/api/auth/logout">` submission from an attacker's page qualifies as top-level navigation and sends the lax cookie with no Referer (form GET navigation does not set Referer in many browsers/configurations). That path would succeed.

**Impact:** Forced logout — the victim's session is destroyed and they are redirected through the Keycloak logout flow. No data is accessed or modified. However, forced logout during an active incident response session is disruptive and meets the bar for a finding.

**Fix:** Added an explicit check for the case where both headers are absent. Legitimate browser navigation from within the application always sends a `Referer` header (same-origin GET navigation with Vite's default `strict-origin-when-cross-origin` policy sends the full referrer to same-origin targets):

```javascript
// T16-2: both headers absent means the check is trivially bypassed.
// Legitimate same-origin navigation always sends Referer.
if (!origin && !referer) {
  return res.status(403).send("Logout rejected — Origin or Referer header required");
}
if ((origin && origin !== appOrigin) || (referer && !referer.startsWith(appOrigin))) {
  return res.status(403).send("Logout CSRF check failed");
}
```

---

### T16-3 — `server.js` — MCP token compared with `===` (non-constant-time)
**Severity:** INFO
**Component:** `app/backend/src/server.js`

**Description:**

The MCP internal authentication middleware compares the `x-mcp-internal` header against the configured `MCP_TOKEN` using JavaScript's `===` operator:

```javascript
// Before fix
if (tok && MCP_TOKEN && tok === MCP_TOKEN) {
```

JavaScript `===` on strings performs a lexicographic comparison that may short-circuit on the first differing character. This creates a timing oracle: a caller can distinguish a "wrong token — wrong at byte N" from "wrong token — wrong at byte N+1" by measuring response time differences. On a local Docker bridge network, this is extremely difficult to exploit in practice (network jitter far exceeds character-comparison timing differences), but the pattern violates the principle of constant-time secret comparison.

**Fix:** Replaced with `crypto.timingSafeEqual`, which performs a constant-time byte comparison regardless of where the tokens diverge:

```javascript
import { timingSafeEqual } from "crypto";

// T16-3: constant-time comparison prevents timing-based token enumeration
const mcpMatch = tok && MCP_TOKEN && (() => {
  try {
    const a = Buffer.from(tok);
    const b = Buffer.from(MCP_TOKEN);
    return a.length === b.length && timingSafeEqual(a, b);
  } catch { return false; }
})();
if (mcpMatch) {
```

The `try/catch` handles the edge case where `Buffer.from()` throws (malformed string encoding). The length check before `timingSafeEqual` is required — `timingSafeEqual` throws if the buffers have different lengths.

---

### T16-4 — `logs.js` — `search` query parameter has no length cap
**Severity:** INFO
**Component:** `app/backend/src/routes/logs.js`

**Description:**

`GET /api/logs/query` accepts a `search` query parameter that is embedded in a LogQL filter expression:

```javascript
if (search.trim()) query += ` |= ${JSON.stringify(search.trim())}`;
```

The `source` parameter is validated against `/^[a-zA-Z0-9._-]+$/` (preventing LogQL injection), and `JSON.stringify` escapes the search string safely (no LogQL injection vector via special characters). However, there was no length limit on `search`. An authenticated viewer could submit a multi-kilobyte or megabyte search string, causing Loki to process an oversized query string on every matching log line.

**Note:** `express.json` limits the request body to 1 MB. However, query parameters are not subject to this limit — the `search` value arrives in `req.query.search` from the URL.

**Fix:** Added a length cap before the LogQL filter is constructed:

```javascript
// T16-4: cap search length to prevent oversized LogQL queries
if (search.length > 500) return res.status(400).json({ ok: false, error: "search too long (max 500 chars)" });
```

500 characters accommodates all realistic log search patterns while preventing abuse.

---

## Supporting Modules — Clean Assessment

| Module | Lines | Assessment |
|--------|-------|------------|
| `fileValidator.js` | 120 | Clean — pure content validation (env/compose/caddy); no user-controlled file paths; no external calls; output is structured `{ status, issues }` — no shell or DB access |
| `healthScheduler.js` | 60 | Clean — no user input; runs fixed probeAllServices/runIntelligenceScan on a timer; retention DELETE is parameterised; errors logged and swallowed (non-fatal cycle errors are correct behaviour) |
| `metrics.js` | 130 | Clean — `execSync("df -P / \| awk 'NR==2 {print $5}'"`) and `execSync(\`cat /sys/class/net/${iface}/...\`)` contain no user input; `iface` comes from `os.networkInterfaces()` (kernel-provided, interface names are constrained to 15 ASCII chars by Linux IFNAMSIZ); blocking `execSync` in timer context is an accepted tradeoff for a 2-minute polling interval |

### `server.js` — Additional Notes (No Finding)

| Aspect | Assessment |
|--------|-----------|
| `cors({ origin: false })` | Correct for same-origin SPA — disables CORS headers entirely; frontend and API are same-origin via nginx reverse proxy |
| `app.set("trust proxy", 1)` | Correct — Caddy sets `X-Forwarded-For` to the real client IP; `trust proxy: 1` tells express-rate-limit to use it; requires Caddy to be correctly configured upstream |
| `sessionSecret` fallback guard | Throws in production if default value is used — correct |
| `authLimiter` skip for `/callback` | Acceptable — callback validates OIDC state/nonce; Keycloak issues each code once; mass-replay not possible |
| Redis session data | `idToken` stored unencrypted in Redis memory — accepted given Redis is container-internal only |

---

## Remediation Summary

All 4 findings fixed in commit `9ac84e8` on `git.securenexus.net/tristian/privatenexus`:

| Finding | Files | Change |
|---------|-------|--------|
| T16-1 | 8 route files (governance, alerts, activity, admin, logs, intelligence, recovery, services) | 57 catch blocks: `err.message` → `"Service unavailable"` + `console.error` prefix |
| T16-2 | `routes/auth.js` | Added guard for missing Origin+Referer before the existing check |
| T16-3 | `server.js` | `===` → `crypto.timingSafeEqual` for MCP token comparison |
| T16-4 | `routes/logs.js` | `search.length > 500` cap before LogQL filter construction |

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
| 11   | DNS route, MCP server, utility routes              | 5        | 5     | 0        |
| 12   | Full route audit completion — actions, deps, intel | 5        | 5     | 0        |
| 13   | Missed routes, security headers, socket proxy      | 5        | 5     | 0        |
| 14   | Supporting modules, schema audit, middleware       | 4        | 4     | 0        |
| 15   | File registry pipeline, Docker client, ErrorBoundary | 4      | 4     | 0        |
| 16   | Server config, auth flow, remaining route files    | 4        | 4     | 0        |
| **Total** | **All tiers**                                | **71**   | **66**| **5**    |

**Accepted findings (cumulative — unchanged):**
- T5-5: Session fixation — mitigated by OIDC state/nonce + `sameSite: lax`
- T8-4: Docker labels expose compose paths — viewer-only, operator debugging use case
- T9-2: protobufjs/grpc-js — transitive via dockerode, not directly exploitable
- T9-5: Vite frontend CVEs — dev server only; nginx serves pre-built assets at runtime
- T10-4: Blind SSRF via `health_endpoint` — admin-only; no response body exfiltration

*Assessment performed on pn-test (VLAN 60 / 10.10.60.105). All findings relate to the PrivateNexus v2.0.0 stack in its development deployment.*
