# PrivateNexus — Tier 13 Security Assessment Report
**Date:** 24 June 2026
**Scope:** Unreviewed route files (`stacks.js`, `discovery.js`, `apps.js`, `catalogue.js`, `ops.js`); HTTP security headers; Docker socket proxy path traversal surface
**Tester:** JARVIS / Claude Code (assisted, operator-supervised)
**Branch assessed:** `main` @ `ff4589d`

---

## Executive Summary

Tier 13 completed the review of five route files that were absent from the Tier 12 "full route audit" claim: `stacks.js`, `discovery.js`, `apps.js`, `catalogue.js`, and `ops.js`. It also examined the HTTP security header posture of the frontend (nginx) and the Docker socket proxy path traversal surface.

`apps.js`, `catalogue.js`, and `ops.js` were found clean. `stacks.js` and `discovery.js` had five findings: missing HTTP security headers on the React frontend, Docker API path traversal via an unvalidated container ID parameter, Docker daemon error message leakage bypassing the global error handler, an unbounded candidate array in the discovery ingest endpoint, and a workspace ID tenant-verification gap repeated from Tier 12.

**5 findings were identified. All 5 were fixed in commit `ff4589d`.**

---

## Findings Summary

| ID    | Title                                                                                    | Severity | Status |
|-------|------------------------------------------------------------------------------------------|----------|--------|
| T13-1 | `nginx.conf` — no HTTP security headers (CSP, X-Frame-Options, Referrer-Policy, etc.)   | MEDIUM   | Fixed  |
| T13-2 | `stacks.js` — container ID parameter not validated; Docker API path traversal possible   | MEDIUM   | Fixed  |
| T13-3 | `stacks.js` — Docker error messages leaked via local catch blocks                        | LOW      | Fixed  |
| T13-4 | `discovery.js` — `POST /ingest` candidate array has no length cap (DoS vector)          | LOW      | Fixed  |
| T13-5 | `discovery.js` — `suggested_workspace_id` not tenant-verified in ingest and update paths | LOW      | Fixed  |

---

## Detailed Findings

---

### T13-1 — `nginx.conf` — no HTTP security headers on the React frontend
**Severity:** MEDIUM
**Component:** `docker/nginx.conf`

**Description:**
The nginx configuration serving the React SPA had no security headers. The Caddy block for `privatenexus.net` also adds no headers beyond the reverse proxy. The backend uses `helmet()` but with `contentSecurityPolicy: false`, and in any case helmet only applies to the Express JSON API responses, not to the HTML served by nginx.

**Missing headers:**
| Header | Risk of absence |
|--------|----------------|
| `Content-Security-Policy` | XSS attacks succeed without browser-enforced script restrictions |
| `X-Frame-Options` | Site can be embedded in iframes (clickjacking) |
| `X-Content-Type-Options` | MIME-type sniffing exploits possible on user-uploaded content |
| `Referrer-Policy` | Browser leaks full URL to third-party resources referenced by the app |
| `Permissions-Policy` | No constraint on browser feature access (camera, mic, geolocation) |

**XSS impact:** PrivateNexus handles container management, DNS manipulation, file editing, and emergency operations. An XSS — whether from an application bug or from attacker-controlled data displayed in the UI (service names, container labels, log excerpts) — would grant the attacker full API access within the victim's session. Without a CSP, even reflected XSS via URL parameters would execute.

**Fix:** Added all five headers to `docker/nginx.conf` using the `always` flag to cover error responses. Applied to both the `= /index.html` block and the `location /` SPA fallback block, since nginx's `add_header` is not inherited across location blocks:

```nginx
# In location = /index.html and location /
add_header X-Content-Type-Options  "nosniff" always;
add_header X-Frame-Options         "DENY" always;
add_header Referrer-Policy         "strict-origin-when-cross-origin" always;
add_header Permissions-Policy      "geolocation=(), microphone=(), camera=()" always;
add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'" always;
```

`style-src 'unsafe-inline'` is retained because React components use inline `style={{...}}` attributes. `script-src 'self'` is strict — Vite production builds contain no inline scripts or eval.

**Verification:** `curl -sI http://localhost:5173/` confirms all five headers present after rebuild.

---

### T13-2 — `stacks.js` — container ID not validated; Docker API path traversal via dockerode
**Severity:** MEDIUM
**Component:** `app/backend/src/routes/stacks.js`

**Description:**
`GET /api/stacks/:id` and `GET /api/stacks/:id/logs` pass `req.params.id` directly to `docker.getContainer(id)` without format validation:

```javascript
// Before fix
const container = docker.getContainer(req.params.id);
const info = await container.inspect();
```

In dockerode, `.inspect()` constructs the Docker API path as:
```javascript
{ path: `/containers/${this.id}/json?` }
```

Express URL-decodes path parameters before assigning them to `req.params`. If a request contains a percent-encoded slash in the container ID (`%2F`), Express decodes it and passes the literal slash to dockerode. Dockerode embeds it in the Docker API path, which Go's HTTP router normalises via `path.Clean` before routing.

**Attack path:** A viewer sends `GET /api/stacks/..%2Fimages` — Express decodes to `id = "../images"` — dockerode constructs path `/containers/../images/json?` — Go's HTTP server normalises to `/images/json` — Docker returns the full image list for the host.

The docker-socket-proxy (`tecnativa/docker-socket-proxy`) has `IMAGES: 1` set. The proxy's path matching runs against the raw (un-normalised) path `/v1.41/containers/../images/json`, which starts with `/v*/containers/` and therefore passes the `CONTAINERS: 1` check. After forwarding, Go normalises to `/images/json` — which is then served by Docker because `IMAGES: 1` is also set. The proxy's per-endpoint filtering is bypassed by the path traversal.

**Impact:** A viewer-level user can obtain the full Docker image inventory of the host, including image names, tags, sizes, and creation timestamps, without any admin or operator privilege.

**Fix:** Added a `validateContainerId` guard to both `/:id` handlers, rejecting any ID that does not match the safe character set for Docker container IDs and names:

```javascript
const CONTAINER_ID_RE = /^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$/;
function validateContainerId(id) {
  return typeof id === "string" && CONTAINER_ID_RE.test(id);
}

// Applied at the top of GET /:id and GET /:id/logs:
if (!validateContainerId(req.params.id))
  return res.status(400).json({ error: "invalid container identifier" });
```

The regex covers valid Docker short IDs (12 hex chars), full IDs (64 hex chars), and container names (alphanumeric, hyphens, underscores, dots). The `%2F` → `/` traversal sequences are rejected because `/` is not in the allowed set.

---

### T13-3 — `stacks.js` — Docker error messages leaked via local catch blocks
**Severity:** LOW
**Component:** `app/backend/src/routes/stacks.js`

**Description:**
Three endpoints in `stacks.js` use local `try/catch` blocks that forward `err.message` directly to the client, bypassing the global Express error handler which sanitises 500s to `"Internal server error"`:

```javascript
// GET / — Docker list containers
res.status(500).json({ error: "Docker unavailable", detail: err.message });

// GET /:id — container inspect
res.status(500).json({ error: err.message });

// GET /:id/logs — container logs
res.status(500).json({ error: err.message });
```

Docker daemon error messages include internal details such as container names, network names, socket paths, and API version strings. The `detail: err.message` field on the list endpoint was the most explicit example.

**Fix:** Log the error server-side, return a generic message to the client:

```javascript
console.error("[stacks] inspect failed:", err.message);
res.status(500).json({ error: "Docker unavailable" });
```

---

### T13-4 — `discovery.js` — `POST /ingest` candidate array has no length cap
**Severity:** LOW
**Component:** `app/backend/src/routes/discovery.js`

**Description:**
The `POST /api/discovery/ingest` endpoint accepts an array of candidates from external discovery agents. The only size constraint is the express.json body limit of 1 MB. A 1 MB body can contain hundreds of candidate records, each triggering an async DB INSERT:

```javascript
// Before fix — no cap
for (const c of incoming) {
  await upsertCandidate(pool, ...);  // INSERT per candidate
}
```

With a valid agent token, a compromised agent (or stolen token) could submit large batches in rapid succession, exhausting PostgreSQL connection pool resources without being rate-limited beyond the general API rate limiter (300 req/min).

**Fix:** Added an explicit cap before processing:

```javascript
const MAX_CANDIDATES_PER_INGEST = 100;
if (incoming.length > MAX_CANDIDATES_PER_INGEST) {
  return res.status(400).json({ ok: false, error: `Batch size exceeds limit of ${MAX_CANDIDATES_PER_INGEST}` });
}
```

---

### T13-5 — `discovery.js` — `suggested_workspace_id` not tenant-verified in ingest and update paths
**Severity:** LOW
**Component:** `app/backend/src/routes/discovery.js`

**Description:**
This repeats the T12-2 pattern for the discovery subsystem. Two code paths accept `suggested_workspace_id` without verifying it belongs to `HOT_TENANT_ID`:

1. **`POST /ingest`** — external agents can submit candidates with any workspace UUID. On approval, the unvalidated workspace ID is written into the `services` table.
2. **`PATCH /candidates/:id` with `action: "update"`** — operators can set `suggested_workspace_id` to any UUID. The allowed-field list includes it, but no tenant check runs before the UPDATE.

**Fix — ingest path:** Pre-fetch valid workspace IDs for the tenant and null out any foreign IDs before calling `upsertCandidate`:

```javascript
const { rows: wsRows } = await pool.query(
  "SELECT id FROM workspaces WHERE tenant_id = $1",
  [HOT_TENANT_ID]
);
const validWsIds = new Set(wsRows.map(r => r.id));

// In loop:
const safeWsId = (c.suggested_workspace_id && validWsIds.has(c.suggested_workspace_id))
  ? c.suggested_workspace_id : null;
```

**Fix — update path:** Validate workspace_id before executing the UPDATE:

```javascript
if (updates?.suggested_workspace_id !== undefined && updates.suggested_workspace_id !== null) {
  const { rows: wsCheck } = await pool.query(
    "SELECT id FROM workspaces WHERE id = $1 AND tenant_id = $2",
    [updates.suggested_workspace_id, HOT_TENANT_ID]
  );
  if (!wsCheck.length)
    return res.status(404).json({ ok: false, error: "workspace_id not found for this tenant" });
}
```

---

## Routes Assessed — Clean

| Route file     | Lines | Assessment |
|----------------|-------|------------|
| `apps.js`      | 39    | Clean — `probeStatus()` queries Prometheus at a fixed URL from env/compose; all data is hardcoded or Prometheus-sourced; `requireRole("viewer")` |
| `catalogue.js` | 69    | Clean — entirely static data (hardcoded APPS and CATEGORIES arrays); two string query params (`category`, `q`) are used only for client-side filtering with no DB access; `requireRole("viewer")` |
| `ops.js`       | 46    | Clean — all five PromQL strings are fixed literals; no user input reaches the Prometheus query; `requireRole("viewer")` |

---

## Docker Socket Proxy Assessment

| Setting | Value | Assessment |
|---------|-------|------------|
| `CONTAINERS` | 1 | Allows `/containers/*` — correct for container inspect/list/manage |
| `IMAGES` | 1 | Allows `/images/*` — required for deploy (pull new image) |
| `POST` | 1 | Allows POST requests — required for start/stop/restart |
| `EXEC` | 0 | Blocks `/containers/*/exec` — critical control, correct |
| `NETWORKS` | 0 | Correct — network manipulation blocked |
| `INFO` | 1 | Allows `/info` — exposes host-level Docker daemon info |
| `VERSION` | 1 | Allows `/version` — minimal risk |

The T13-2 path traversal exploited the fact that the proxy matches raw (un-normalised) paths while Docker routes normalised paths. The container ID validation fix eliminates this traversal surface regardless of proxy config. The `INFO: 1` setting is the minimum needed; consider setting `INFO: 0` if nothing in the frontend uses `GET /api/docker/info` (no such route exists in the backend — it was only accessible via traversal).

---

## Remediation Summary

All 5 findings fixed in commit `ff4589d` on `git.securenexus.net/tristian/privatenexus`:

| Finding | File | Change |
|---------|------|--------|
| T13-1 | `docker/nginx.conf` | Added CSP, X-Frame-Options, X-Content-Type-Options, Referrer-Policy, Permissions-Policy to `= /index.html` and `location /` blocks |
| T13-2 | `routes/stacks.js` | `CONTAINER_ID_RE` regex + `validateContainerId()` guard on `/:id` and `/:id/logs` |
| T13-3 | `routes/stacks.js` | All three local catch blocks now log error and return generic `"Docker unavailable"` |
| T13-4 | `routes/discovery.js` | `MAX_CANDIDATES_PER_INGEST = 100` cap in `POST /ingest` |
| T13-5 | `routes/discovery.js` | Tenant workspace ID pre-fetch in ingest loop; workspace_id tenant check in PATCH update action |

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
| **Total** | **All tiers**                                | **59**   | **54**| **5**    |

**Accepted findings (cumulative — unchanged):**
- T5-5: Session fixation — mitigated by OIDC state/nonce + `sameSite: lax`
- T8-4: Docker labels expose compose paths — viewer-only, operator debugging use case
- T9-2: protobufjs/grpc-js — transitive via dockerode, not directly exploitable
- T9-5: Vite frontend CVEs — dev server only; nginx serves pre-built assets at runtime
- T10-4: Blind SSRF via `health_endpoint` — admin-only; no response body exfiltration

*Assessment performed on pn-test (VLAN 60 / 10.10.60.105). All findings relate to the PrivateNexus v2.0.0 stack in its development deployment.*
