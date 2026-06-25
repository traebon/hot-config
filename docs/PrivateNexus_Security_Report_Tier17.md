# PrivateNexus — Tier 17 Security Assessment Report
**Date:** 24 June 2026
**Scope:** Container infrastructure — `compose/docker-compose.yml`, `docker/backend.Dockerfile`, `docker/frontend.Dockerfile`, `docker/mcp.Dockerfile`; MCP server — `mcp/server.js`; health probe module — `healthProbe.js`; supporting context — `healthScheduler.js` (reference only)
**Tester:** JARVIS / Claude Code (assisted, operator-supervised)
**Branch assessed:** `main` @ `9ac84e8`

---

## Executive Summary

Tier 17 audited the container infrastructure (Docker Compose configuration and all three Dockerfiles) and completed the review of the MCP server. `healthProbe.js` was reviewed and found clean.

The MCP server had the same non-constant-time token comparison pattern fixed in T16-3 for `server.js`. The compose file had two container hardening gaps: the MCP container ran as root without capability dropping, and the frontend port binding exposed nginx on all interfaces rather than loopback-only, allowing direct access from the internal network that bypasses Caddy's security headers. All three Dockerfiles used `npm install` instead of `npm ci`, meaning the package lockfile was not enforced during image builds — the host's `node_modules/` directory was also being silently baked into the backend image via an unbounded `COPY` with no `.dockerignore`. The MCP Dockerfile had no `package-lock.json` at all.

**5 findings — 4 fixed, 1 accepted.**

---

## Findings Summary

| ID    | Title                                                                                        | Severity | Status   |
|-------|----------------------------------------------------------------------------------------------|----------|----------|
| T17-1 | MCP container runs as root without `cap_drop`/`security_opt`; frontend missing `no-new-privileges` | MEDIUM | Fixed  |
| T17-2 | Frontend port bound to all interfaces — direct access bypasses Caddy security headers        | LOW      | Fixed    |
| T17-3 | MCP server Bearer token uses `!==` (non-constant-time)                                      | LOW      | Fixed    |
| T17-4 | `npm install` in all Dockerfiles; host `node_modules/` baked into backend image; MCP has no lockfile | LOW | Fixed |
| T17-5 | MCP read tools query PostgreSQL directly — read operations produce no audit log entries      | INFO     | Accepted |

---

## Detailed Findings

---

### T17-1 — MCP container runs as root; frontend missing `no-new-privileges`
**Severity:** MEDIUM
**Component:** `compose/docker-compose.yml`

**Description:**

The backend container was correctly hardened in the compose file:
```yaml
privatenexus-backend:
  user: "1000"
  cap_drop:
    - ALL
  security_opt:
    - no-new-privileges:true
```

Neither the MCP container nor the frontend container had any of these directives:

```yaml
# Before fix
privatenexus-mcp:
  # runs as root — no user:, cap_drop:, security_opt:

privatenexus-frontend:
  # runs as root — no user:, cap_drop:, security_opt:
```

**MCP container:** The MCP server is a Node.js process that holds a direct PostgreSQL connection and can execute backend API calls including container restarts and proposal approvals. Running it as root means any code execution vulnerability in the MCP server (or in the `pg` library) would immediately have root access within the container, with the ability to write to the Docker socket mount or escalate further. The `node:20-alpine` image ships a `node` user (UID 1000) suitable for running the server.

**Frontend container:** The nginx master process legitimately requires elevated capabilities for its initialisation sequence — it calls `chown` on its cache directories and `setuid`/`setgid` to drop worker processes to the `nginx` user. Applying `cap_drop: [ALL]` without careful capability restoration causes nginx to fail at startup (verified — `chown("/var/cache/nginx/client_temp", 101) failed (1: Operation not permitted)` on first attempt). The fix therefore applies only `no-new-privileges:true` to the frontend, which prevents privilege escalation without breaking nginx startup.

**Fix:**

```yaml
# MCP — full hardening
privatenexus-mcp:
  user: "node"
  cap_drop:
    - ALL
  security_opt:
    - no-new-privileges:true

# Frontend — no-new-privileges only; cap_drop omitted (nginx master requires CAP_CHOWN + CAP_SETUID)
privatenexus-frontend:
  security_opt:
    - no-new-privileges:true
```

---

### T17-2 — Frontend port bound to all interfaces
**Severity:** LOW
**Component:** `compose/docker-compose.yml`

**Description:**

The backend and MCP ports were bound to loopback only:
```yaml
privatenexus-backend:
  ports:
    - "127.0.0.1:3001:3001"   # correct

privatenexus-mcp:
  ports:
    - "127.0.0.1:3002:3002"   # correct
```

The frontend port was bound to all interfaces:
```yaml
privatenexus-frontend:
  ports:
    - "${PRIVATENEXUS_FRONTEND_PORT:-5173}:80"  # binds 0.0.0.0:5173
```

On pn-test (10.10.60.105), port 5173 was accessible from anywhere in the 10.10.0.0/16 network — the Gateway VPS, sn-monitor, sn-infra — without going through Caddy. Direct access to port 5173 bypasses the security headers added in T13-1 (CSP, X-Frame-Options, Referrer-Policy, Permissions-Policy), because those headers are applied by nginx in the container, not by Caddy. Any client on the internal network accessing `http://10.10.60.105:5173/` would receive the frontend without the security headers.

**Fix:**
```yaml
privatenexus-frontend:
  ports:
    - "127.0.0.1:${PRIVATENEXUS_FRONTEND_PORT:-5173}:80"
```

All access to the frontend must now go through Caddy (which reverse-proxies to `localhost:5173`), ensuring security headers are consistently applied.

---

### T17-3 — MCP server Bearer token compared with `!==` (non-constant-time)
**Severity:** LOW
**Component:** `mcp/server.js`

**Description:**

The MCP HTTP server's authentication check used `!==` for Bearer token comparison:

```javascript
// Before fix
const auth = req.headers.authorization || "";
if (!TOKEN || auth !== `Bearer ${TOKEN}`) {
  return jsonResp(res, { error: "Unauthorized" }, 401);
}
```

This is the same class as T16-3 (fixed in `server.js`) but the MCP server was not included in that tier's scope. JavaScript's `!==` operator short-circuits on the first differing character, creating a timing oracle. The MCP server binds to `127.0.0.1:3002` and is only accessible from within the Docker network and from the Gateway VPS over WireGuard; direct timing attacks from the internet are not possible. However, an attacker with access to pn-test or the internal network could exploit this.

**Fix:** Applied `crypto.timingSafeEqual` identical to the T16-3 fix:

```javascript
import { timingSafeEqual } from "node:crypto";

// T17-3: constant-time comparison to prevent timing oracle on token
const auth = req.headers.authorization || "";
const expected = TOKEN ? `Bearer ${TOKEN}` : "";
const authOk = TOKEN && (() => {
  try {
    const a = Buffer.from(auth);
    const b = Buffer.from(expected);
    return a.length === b.length && timingSafeEqual(a, b);
  } catch { return false; }
})();
if (!authOk) {
  return jsonResp(res, { error: "Unauthorized" }, 401);
}
```

---

### T17-4 — `npm install` in Dockerfiles; host `node_modules/` baked into image; MCP has no lockfile
**Severity:** LOW
**Component:** `docker/backend.Dockerfile`, `docker/frontend.Dockerfile`, `docker/mcp.Dockerfile`

**Description:**

**Issue A — `npm install` instead of `npm ci`:**
All three Dockerfiles used `npm install` during the image build:
```dockerfile
RUN npm install        # backend.Dockerfile, frontend.Dockerfile
RUN npm install --omit=dev  # mcp.Dockerfile
```

`npm install` installs packages based on the ranges in `package.json` (e.g. `^4.21.0`) and may silently update dependencies between builds if a new minor/patch version is released. `npm ci` requires a `package-lock.json`, verifies the lockfile matches `package.json`, and installs exact versions — making builds reproducible and verifiable.

**Issue B — host `node_modules/` baked into backend image:**
The backend Dockerfile sequence was:
```dockerfile
COPY app/backend/package*.json ./
RUN npm install           # installs to /app/node_modules
COPY app/backend/ ./      # overwrites /app/node_modules with host's node_modules!
```

The build context is `/opt/privatenexus/`. With no `.dockerignore`, `COPY app/backend/ ./` copied the host's `/opt/privatenexus/app/backend/node_modules/` into the image at `/app/node_modules/`, silently overwriting the freshly-installed ones. The `RUN npm install` step was effectively dead code. The image ran the host's installed modules rather than reproducibly-built ones, including any host-side patches or version differences.

**Issue C — MCP has no `package-lock.json`:**
The MCP Dockerfile copied only `mcp/package.json` — there was no `mcp/package-lock.json`. Without a lockfile, `npm install` (or `npm ci`) resolves the latest compatible version of `pg` on each build.

**Fix:**
1. Created `/opt/privatenexus/.dockerignore` excluding all `node_modules/` directories, `.git/`, and `secrets/` from the build context:
   ```
   **/node_modules/
   **/.git/
   **/secrets/
   ```
2. Changed all three Dockerfiles to use `npm ci`:
   ```dockerfile
   RUN npm ci              # backend + frontend
   RUN npm ci --omit=dev   # mcp
   ```
3. Generated `mcp/package-lock.json` with `npm install --package-lock-only`.
4. Updated `mcp.Dockerfile` to `COPY mcp/package*.json ./` to include the new lockfile.

The `.dockerignore` also excludes `/secrets/` from the build context as a defense-in-depth measure — secret files should never be reachable by the image build layer, even if a `COPY` command were accidentally added.

---

### T17-5 — MCP read tools bypass audit log (Accepted)
**Severity:** INFO
**Status:** Accepted

**Description:**

MCP write tools (`pn_approve_proposal`, `pn_refresh_health`, `pn_restart_service`, `pn_run_simulation`, `pn_get_playbook`) call the backend HTTP API with the `X-MCP-Internal` header, which causes the backend to log actions against `username: "mcp-server"` in the audit log. This provides a complete trail of write operations.

MCP read tools (`pn_summary`, `pn_list_services`, `pn_get_service`, `pn_blast_radius`, `pn_restore_chain`, `pn_health_history`, `pn_list_backups`, `pn_recent_activity`, `pn_discovery_pending`, `pn_list_signals`) query PostgreSQL directly, bypassing the backend and producing no audit log entries. A compromised MCP token can silently read all service data, backup records, health history, and the audit log itself.

**Why accepted:** Adding audit logging to MCP read operations would require either adding explicit `INSERT INTO audit_log` queries to each MCP read handler, or routing all reads through the backend API (which would require new read-only API endpoints for each operation). The MCP token is a high-value internal secret stored in Docker secrets, not exposed to users. The read operations are information disclosure from an already-privileged credential. The backend already rate-limits and validates all mutations. Adding silent-read logging is a v2 hardening task appropriate for the PN-2 multi-tenant milestone.

---

## `healthProbe.js` — Clean Assessment

| Aspect | Assessment |
|--------|-----------|
| TCP probe (`tcp://host:port`) | Blind SSRF potential — but `health_endpoint` is admin-set, and T10-4 (HTTP health SSRF) was already accepted. Same risk class, same accepted status. |
| HTTP/HTTPS probe | `fetch()` with `AbortSignal.timeout(PROBE_TIMEOUT_MS)` — correct timeout handling |
| URL parsing | `new URL(svc.health_endpoint)` — malformed URLs throw and are caught safely |
| DB writes | Parameterised `UPDATE services` and `INSERT INTO health_events` — no injection vector |
| Concurrency | `Promise.all(services.map(probeOne))` — all probes run in parallel; each probe has an independent timeout. If PROBE_TIMEOUT_MS fires on all services simultaneously, the scheduler will take up to PROBE_TIMEOUT_MS per cycle. Acceptable for a 2-minute interval. |

---

## Remediation Summary

All 4 fixed findings in commit `264a3d6` on `git.securenexus.net/tristian/privatenexus`:

| Finding | Files | Change |
|---------|-------|--------|
| T17-1 | `compose/docker-compose.yml` | MCP: `user: "node"` + `cap_drop: [ALL]` + `no-new-privileges`. Frontend: `no-new-privileges` only (nginx master requires CAP_CHOWN) |
| T17-2 | `compose/docker-compose.yml` | Frontend port: `"0.0.0.0:5173:80"` → `"127.0.0.1:5173:80"` |
| T17-3 | `mcp/server.js` | `auth !== \`Bearer \${TOKEN}\`` → `crypto.timingSafeEqual` |
| T17-4 | All three Dockerfiles, new `.dockerignore`, new `mcp/package-lock.json` | `npm install` → `npm ci`; `.dockerignore` excludes `**/node_modules/` + `**/secrets/`; MCP lockfile generated |

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
| 17   | Container infrastructure, MCP server, build pipeline | 5      | 4     | 1        |
| **Total** | **All tiers**                                | **76**   | **70**| **6**    |

**Accepted findings (cumulative):**
- T5-5: Session fixation — mitigated by OIDC state/nonce + `sameSite: lax`
- T8-4: Docker labels expose compose paths — viewer-only, operator debugging use case
- T9-2: protobufjs/grpc-js — transitive via dockerode, not directly exploitable
- T9-5: Vite frontend CVEs — dev server only; nginx serves pre-built assets at runtime
- T10-4: Blind SSRF via `health_endpoint` — admin-only; no response body exfiltration
- T17-5: MCP read tools bypass audit log — high-value credential, write ops are audited; v2 hardening task

*Assessment performed on pn-test (VLAN 60 / 10.10.60.105). All findings relate to the PrivateNexus v2.0.0 stack in its development deployment.*
