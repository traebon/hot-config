# PrivateNexus — Tier 11 Security Assessment Report
**Date:** 24 June 2026
**Scope:** DNS route, MCP server, admin route, metrics/logs/alerts routes
**Tester:** JARVIS / Claude Code (assisted, operator-supervised)
**Branch assessed:** `main` @ `a399e66`
**Prior tiers:**
- Tier 1–2: RBAC, session integrity
- Tier 3: Injection, route auth, port exposure
- Tier 4: Infrastructure exposure, container security posture
- Tier 5: Application logic, session, audit integrity
- Tier 6: Emergency ops safety, role completeness, input validation
- Tier 7: Audit trail integrity, workflow logic, validation completeness
- Tier 8: File management, remaining routes, ESM compatibility
- Tier 9: Middleware chain, server config, dependencies
- Tier 10: Auth flow, file registry, health probes, compose

---

## Executive Summary

Tier 11 completed the review of the DNS management route (`dns.js`), the MCP server (`mcp/server.js`), and the infrastructure utility routes (`admin.js`, `metrics.js`, `logs.js`, `alerts.js`). The DNS route had a path traversal vulnerability allowing an operator to reach arbitrary PowerDNS API endpoints beyond `/zones/`. The MCP server had three issues: a missing UUID validation that enabled path traversal via prompt injection, the T9-4 DB password priority pattern repeated in the MCP pool configuration, and no request body size limit. The utility routes (`logs.js`, `metrics.js`, `alerts.js`) were found clean.

**5 findings were identified. All 5 were fixed in commit `a399e66`.**

---

## Findings Summary

| ID    | Title                                                                              | Severity | Status |
|-------|------------------------------------------------------------------------------------|----------|--------|
| T11-1 | `dns.js` — `req.params.zone` path traversal reaches arbitrary PowerDNS endpoints  | MEDIUM   | Fixed  |
| T11-2 | `mcp/server.js` — `proposal_id` not validated before URL path construction        | LOW      | Fixed  |
| T11-3 | `mcp/server.js` — `DB_PASSWORD` env var takes priority over Docker secret         | LOW      | Fixed  |
| T11-4 | `mcp/server.js` — no request body size limit on raw HTTP server                   | LOW      | Fixed  |
| T11-5 | `dns.js` — full PowerDNS error response body forwarded to client                  | INFO     | Fixed  |

---

## Detailed Findings

---

### T11-1 — `dns.js` — zone parameter path traversal into PowerDNS API
**Severity:** MEDIUM
**Component:** `app/backend/src/routes/dns.js`

**Description:**
The DNS route proxies requests to the PowerDNS API. For zone-specific operations, it directly interpolates the URL path parameter into the PowerDNS API path:

```javascript
// Before fix — zone param used verbatim
const zone = await pdns("GET", `/zones/${req.params.zone}`);
await pdns("PATCH", `/zones/${req.params.zone}`, { ... });
```

Express captures a URL path segment for `/:zone`, which stops at `/`. However, it **does not strip `.` characters**, so `req.params.zone` can be a dotted path segment like `..`. When the `pdns()` function constructs `${PDNS_BASE}/zones/../../config`, the Node.js URL parser normalises it during `fetch()`:

```
http://10.10.0.1:8081/api/v1/servers/localhost/zones/../../config
  → normalises to →
http://10.10.0.1:8081/api/v1/servers/localhost/config
```

This reaches the PowerDNS `/servers/localhost/config` endpoint, which returns server configuration including the API bind address and allowed ranges. With more traversal steps (`../../../`), an attacker could reach `/api/v1/servers` (listing all servers) or root-level PowerDNS API paths.

**Attack path:** An operator calls `GET /api/dns/zones/..%2F..%2Fconfig` or, in a URL context where Express doesn't URL-decode the segment, the route matches `..` as the zone name directly.

**Impact:** An operator (minimum role for DNS write operations) can read PowerDNS server configuration and access endpoints outside the intended `/zones/` scope. The PowerDNS API key is present in the server config response. PowerDNS write endpoints (zone creation, deletion, DNSSEC operations) could also be reached with crafted zone names.

**Fix:** Added `validateZone()` helper and applied it to all three zone-parameter handlers:

```javascript
function validateZone(zone) {
  return typeof zone === "string" && zone.length > 0
    && /^[a-zA-Z0-9._-]+$/.test(zone)
    && !zone.includes("..");
}

// Applied to all three handlers:
if (!validateZone(req.params.zone)) return res.status(400).json({ ok: false, error: "invalid zone name" });
```

Valid DNS zone names contain only alphanumeric characters, hyphens, and dots — any `..` traversal sequence is rejected at the gate.

---

### T11-2 — `mcp/server.js` — `proposal_id` path traversal via prompt injection
**Severity:** LOW
**Component:** `mcp/server.js`

**Description:**
The `pn_approve_proposal` MCP tool constructs a backend API URL directly from the `proposal_id` argument:

```javascript
// Before fix — no validation
case "pn_approve_proposal": {
  const { proposal_id } = args;
  if (!proposal_id) return { error: "proposal_id is required" };
  return backendCall("POST", `/api/intelligence/proposals/${proposal_id}/approve`);
}
```

If `proposal_id` contains path traversal sequences (e.g., `"../service/some-uuid/restart"`), `backendCall` constructs:
```
POST /api/intelligence/proposals/../service/some-uuid/restart
  → normalises to →
POST /api/intelligence/service/some-uuid/restart
```

This would trigger a container restart for an arbitrary service without the approval audit trail.

**Threat model:** The MCP server is called by Claude Code / JARVIS. `proposal_id` values shown to Claude come from `pn_list_signals` (which returns UUIDs from the database), making routine exploitation unlikely. However, the MCP server processes data from monitored services — service names, log lines, error messages — which are attacker-controllable vectors for prompt injection. A malicious service name or log entry could instruct Claude to call `pn_approve_proposal` with a crafted `proposal_id`.

**Fix:** Added UUID format validation before URL construction:

```javascript
if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(proposal_id)) {
  return { error: "proposal_id must be a valid UUID" };
}
```

UUIDs cannot contain `/` or `.`, making path traversal impossible.

---

### T11-3 — `mcp/server.js` — `DB_PASSWORD` env var takes priority over Docker secret
**Severity:** LOW
**Component:** `mcp/server.js`

**Description:**
The MCP server's PostgreSQL pool configuration repeated the T9-4 pattern (fixed in the backend in Tier 9 but not in the MCP server):

```javascript
// Before fix — env var takes priority
password: process.env.DB_PASSWORD || readSecret("/run/secrets/db_password"),
```

The `||` operator means `DB_PASSWORD` environment variable takes priority over the Docker secret. If `DB_PASSWORD` were accidentally set (e.g., left over from a development `.env` file), it would override the properly secured secret file.

**Fix:**
```javascript
// After fix — Docker secret takes priority
password: readSecret("/run/secrets/db_password") ?? process.env.DB_PASSWORD,
```

Consistent with the T9-4 fix in the backend: secret file is authoritative, env var is dev-only fallback.

---

### T11-4 — `mcp/server.js` — no request body size limit
**Severity:** LOW
**Component:** `mcp/server.js`

**Description:**
The MCP server uses the raw Node.js `http.createServer` API and accumulates the request body by string concatenation without any size limit:

```javascript
// Before fix — unbounded accumulation
let body = "";
req.on("data", c => body += c);
```

A client holding a valid Bearer token (the MCP token) could send an arbitrarily large request body, causing the `body` string to grow until Node.js runs out of heap memory or the OS kills the process.

**Context:** The MCP server is bound to `127.0.0.1:3002` and requires the `mcp_token` Bearer token. The attack requires compromise of the token. However, the raw HTTP server has no framework-level protection, unlike the Express backend which uses `express.json({ limit: "1mb" })`.

**Fix:** Added a 1 MB guard with early abort:

```javascript
let body = "";
let tooLarge = false;
req.on("data", c => {
  if (!tooLarge) {
    body += c;
    if (body.length > 1_048_576) {
      tooLarge = true;
      jsonResp(res, { error: "Request body too large" }, 413);
    }
  }
});
req.on("end", async () => {
  if (tooLarge) return;
  // ... existing handler
```

---

### T11-5 — `dns.js` — full PowerDNS error body forwarded to client
**Severity:** INFO
**Component:** `app/backend/src/routes/dns.js`

**Description:**
The `pdns()` helper forwarded the full PowerDNS API error response body to the client:

```javascript
// Before fix
const text = await res.text().catch(() => res.statusText);
throw Object.assign(new Error(text || res.statusText), { status: res.status });
```

PowerDNS error responses can include internal details such as zone names, rrset counts, server configuration fields, and DNSSEC key IDs. These are forwarded verbatim to the operator via the `error` field in the JSON response.

**Fix:** Truncated to the first non-empty line, maximum 200 characters:

```javascript
const raw = await res.text().catch(() => "");
const brief = (raw.split("\n").find(l => l.trim()) || res.statusText || "PowerDNS error").slice(0, 200);
throw Object.assign(new Error(brief), { status: res.status });
```

---

## Routes Assessed — Clean

| Route file   | Lines | Assessment |
|--------------|-------|------------|
| `logs.js`    | 119   | Clean — `source` parameter validated with `/^[a-zA-Z0-9._-]+$/` before LogQL construction; `search` param escaped via `JSON.stringify`; rate-limited by Express middleware |
| `metrics.js` | 163   | Clean — `execSync` calls use fixed string literals; no user input in shell commands; OS interface names are kernel-controlled |
| `alerts.js`  | 94    | Clean — Prometheus queries use fixed PromQL strings; SSE stream has 10-minute hard timeout; no user input in query construction |
| `admin.js`   | 202   | Clean — `execSync("df -Pk 2>/dev/null")` is a fixed string; Docker network/volume data is system-controlled; audit log queries use parameterised SQL |

---

## MCP Server Architecture Assessment

| Property | Value | Assessment |
|----------|-------|------------|
| Authentication | `Authorization: Bearer <mcp_token>` on every request | Correct |
| Token source | Docker secret (`/run/secrets/mcp_token`) with no hardcoded fallback | Correct — MCP disabled if secret absent |
| Listen address | `0.0.0.0:3002` inside container; host binding `127.0.0.1:3002:3002` | Acceptable — host-side binding restricts external access |
| Read tools | Direct PostgreSQL queries with parameterised SQL | Correct — no injection surface |
| Write tools | Via backend HTTP API with `X-MCP-Internal` header | Correct — writes go through backend auth/audit |
| Concurrent cycle guard | N/A (stateless HTTP server) | N/A |
| Error handling | `try/catch` in `callTool`, errors returned as `isError: true` | Correct |

---

## Remediation Summary

All 5 findings fixed in commit `a399e66` on `git.securenexus.net/tristian/privatenexus`:

| Finding | Change |
|---------|--------|
| T11-1 | `validateZone()` function added; checks `[a-zA-Z0-9._-]+` and rejects `..` sequences; applied to all 3 zone-parameter handlers |
| T11-2 | UUID regex check on `proposal_id` in `pn_approve_proposal` before URL construction |
| T11-3 | `readSecret() ?? process.env.DB_PASSWORD` in MCP pool config |
| T11-4 | 1 MB body size guard with `tooLarge` flag and early 413 response |
| T11-5 | PowerDNS error body truncated to first non-empty line ≤ 200 chars |

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
| **Total** | **All tiers**                                | **49**   | **44**| **5**    |

**Accepted findings (cumulative):**
- T5-5: Session fixation — mitigated by OIDC state/nonce + `sameSite: lax`
- T8-4: Docker labels expose compose paths — viewer-only, operator debugging use case
- T9-2: protobufjs/grpc-js — transitive via dockerode, not directly exploitable
- T9-5: Vite frontend CVEs — dev server only; nginx serves pre-built assets at runtime
- T10-4: Blind SSRF via `health_endpoint` — admin-only; no response body exfiltration

*Assessment performed on pn-test (VLAN 60 / 10.10.60.105). All findings relate to the PrivateNexus v2.0.0 stack in its development deployment.*
