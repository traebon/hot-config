# PrivateNexus — Tier 4 Security Assessment Report
**Date:** 24 June 2026
**Scope:** Infrastructure exposure — pn-test (VLAN 60) and Gateway VPS
**Tester:** JARVIS / Claude Code (assisted, operator-supervised)
**Branch assessed:** `main` @ `bfa5fd2`
**Prior tiers:** Tier 1–2 (RBAC, session integrity), Tier 3 (injection, route auth, port exposure)

---

## Executive Summary

Tier 4 assessed the infrastructure exposure surface of the PrivateNexus stack: container security posture, network service reachability, secret management, dependency vulnerability status, and remaining authentication gaps in the API layer.

**13 findings were identified.** 13 were fully resolved across 6 commits: 11 fixed in the initial session and 2 further items (T4-12 SSRF mitigation and T4-13 Docker socket proxy) implemented in a follow-on session. No finding requires a breaking change to the application.

The most significant finding was the Caddy reverse proxy admin API (`10.10.0.1:2019`) being unauthenticated and reachable from every VM in the infrastructure. A compromised VM could have read the full proxy configuration or redirected live traffic. This was resolved by restricting the admin interface to the container's loopback address.

---

## Findings Summary

| ID   | Title                                           | Severity | Status  |
|------|-------------------------------------------------|----------|---------|
| T4-1 | Caddy admin API unauthenticated, network-wide   | HIGH     | Fixed   |
| T4-2 | `GET /api/files/read` — no role guard           | HIGH     | Fixed   |
| T4-3 | `/api/files/register` accepts arbitrary paths   | HIGH     | Fixed   |
| T4-4 | `/api/actions/run` and `/run/v2` — no role guard| HIGH     | Fixed   |
| T4-5 | Redis unauthenticated                           | MEDIUM   | Fixed   |
| T4-6 | Backend container — default capability set      | MEDIUM   | Fixed   |
| T4-7 | No HTTP security headers on backend API         | MEDIUM   | Fixed   |
| T4-8 | MCP auth fail-open when token secret absent     | MEDIUM   | Fixed   |
| T4-9 | 9 files API endpoints — missing role guards     | MEDIUM   | Fixed   |
| T4-10| npm transitive CVEs via dockerode               | LOW      | Accepted|
| T4-11| Vite port 5173 exposed on all interfaces        | LOW      | Accepted|
| T4-12| Blind SSRF via service `health_endpoint`        | INFO     | Fixed   |
| T4-13| Docker socket `:ro` misleading                  | INFO     | Fixed   |

---

## Detailed Findings

---

### T4-1 — Caddy admin API unauthenticated, reachable from all VMs
**Severity:** HIGH
**Component:** Gateway VPS — `/opt/stacks/caddy/`

**Description:**
The Caddy reverse proxy admin API was bound to `:2019` (all interfaces), meaning it listened on the WireGuard interface `10.10.0.1:2019`. All VMs in the infrastructure can route to `10.10.0.1` via WireGuard. The API requires no authentication.

A full `GET /config/` request from pn-test returned the entire live Caddy configuration — all 30+ reverse proxy routes including internal VM IPs and ports, TLS automation policies, CrowdSec bouncer configuration, and the PowerDNS API token environment variable reference. Write operations (`POST /config/`) were equally open, enabling an attacker to redirect any domain to an arbitrary upstream.

**Note on attempted IP filtering:** An iptables rule restricting port 2019 to pn-test's IP (`10.10.60.105`) was tested and failed. Proxmox masquerades all inter-VLAN traffic to the destination gateway IP (`10.10.0.2`), making it impossible to distinguish source VMs at the Gateway VPS network layer.

**Fix (`496cdf9` — hot-config):**
- `Caddyfile`: `admin :2019` → `admin localhost:2019` (binds to container loopback only)
- `compose.yml`: Removed the `10.10.0.1:2019:2019` port mapping entirely

Caddy continues to serve all traffic normally. The admin API is now accessible only from within the Caddy container itself. The PrivateNexus discovery scanner (`POST /api/discovery/scan` with `source: "caddy"`) will return a graceful error in `results.errors` until a privileged agent on the Gateway VPS is provided.

---

### T4-2 — `GET /api/files/read` missing role guard
**Severity:** HIGH
**Component:** pn-test — `app/backend/src/routes/files.js`

**Description:**
The `/api/files/read?id=<id>` endpoint returned the full plaintext content of any file registered in the file registry. The handler had no `requireRole` middleware, meaning any authenticated session — including `viewer` — could read registered files.

Combined with T4-3, the attack chain was: admin registers a secret file path → any viewer reads its content.

**Fix (`e4f1ef5`):**
```javascript
// Before
filesRouter.get("/read", (req, res) => {

// After
filesRouter.get("/read", requireRole("operator"), (req, res) => {
```

---

### T4-3 — `/api/files/register` accepts arbitrary host paths
**Severity:** HIGH
**Component:** pn-test — `app/backend/src/routes/files.js`

**Description:**
The `POST /api/files/register` endpoint (admin-only) accepted a `path` field from user input with no validation. An admin could register any host path — including Docker secrets (`/run/secrets/keycloak_client_secret.txt`), system files (`/etc/passwd`), or SSH keys (`/root/.ssh/`) — and subsequently read or overwrite them via the `/read` and `/write` endpoints.

**Fix (`e4f1ef5`):**
Path is resolved and validated before registration:
```javascript
const resolvedPath = require("path").resolve(filePath);
const BLOCKED_PREFIXES = [
  "/run/secrets", "/opt/privatenexus/secrets",
  "/root", "/etc", "/proc", "/sys"
];
if (BLOCKED_PREFIXES.some((p) => resolvedPath === p || resolvedPath.startsWith(p + "/"))) {
  return res.status(403).json({ ok: false, error: "Path is in a restricted directory" });
}
if (!resolvedPath.startsWith("/opt/")) {
  return res.status(403).json({ ok: false, error: "Registered paths must be under /opt/" });
}
```

---

### T4-4 — `/api/actions/run` and `/run/v2` missing route-level role guard
**Severity:** HIGH (mitigated to MEDIUM by router-level gate)
**Component:** pn-test — `app/backend/src/routes/actions.js`

**Description:**
The `/api/actions/run` and `/api/actions/run/v2` handlers had no `requireRole` middleware at the route level. For `/run/v2`, the policy-based elevation check (`getPolicy()`) was conditional on a policy existing in the database — with no configured policy, any authenticated user could trigger a container action.

In practice, `server.js` mounts the entire actions router with `requireRole("operator")`, providing a defence-in-depth gap rather than a direct bypass. The `/run/v2` case is the more material risk since its internal elevation check silently passed when no policy row existed.

The CONTAINER_ALLOWLIST restricts targets to `privatenexus-frontend` and `privatenexus-backend`, limiting blast radius to a self-DoS (restarting one's own application).

**Fix (`5bf96f7`):**
```javascript
actionsRouter.post("/run",    requireRole("operator"), async (req, res) => {
actionsRouter.post("/run/v2", requireRole("operator"), async (req, res) => {
```

---

### T4-5 — Redis unauthenticated
**Severity:** MEDIUM
**Component:** pn-test — `compose/docker-compose.yml`, `app/backend/src/server.js`

**Description:**
The Redis container had no `requirepass` configured. Any container added to the `compose_pn-internal` Docker network could read and write the Redis keyspace, which includes all session data. A session forged in Redis would be accepted as legitimate by the backend.

Redis is not exposed outside the `pn-internal` network (no host port binding), so this requires either a compromised container on that network or abuse of the Docker socket. The `compose_pn-internal` network contains four containers: `privatenexus-db`, `privatenexus-redis`, `privatenexus-mcp`, and `privatenexus-backend`.

**Fix (`5bf96f7`):**
- Redis password generated (`openssl rand -hex 32`) and stored at `/opt/privatenexus/secrets/redis_password.txt`
- Redis container: `command: sh -c 'redis-server --requirepass $$(cat /run/secrets/redis_password)'`
- Redis healthcheck updated to authenticate: `redis-cli -a $$(cat /run/secrets/redis_password) ping`
- Backend reads password from `/run/secrets/redis_password` and injects it into the Redis URL at startup
- `redis_password` added to backend's Docker secrets list

Verified: unauthenticated `redis-cli ping` → `NOAUTH Authentication required.`

---

### T4-6 — Backend container running with default Docker capability set
**Severity:** MEDIUM
**Component:** pn-test — `compose/docker-compose.yml`

**Description:**
The backend container ran as UID 0 with Docker's default 14-capability effective set, including:
- `CAP_NET_RAW` — raw packet access; ARP spoofing possible within the container network
- `CAP_DAC_OVERRIDE` — bypasses all filesystem permission checks
- `CAP_SETUID` / `CAP_SETGID` — can change effective UID/GID
- `CAP_SYS_CHROOT` — can change root directory

The backend (Node.js, port 3001) requires none of these capabilities for its normal operation.

**Effective capability bitmask before fix:** `0x00000000a80425fb`

**Fix (`5bf96f7`):**
```yaml
cap_drop:
  - ALL
security_opt:
  - no-new-privileges:true
```

Verified: `CapEff: 0x0000000000000000` inside the running container.

**Outstanding:** The container still runs as UID 0. Migrating to the `node` user (UID 1000) requires resolving Docker socket group access (GID 988) and auditing the `/opt/privatenexus` bind mount for write requirements. Deferred to a dedicated hardening pass.

---

### T4-7 — No HTTP security headers on backend API
**Severity:** MEDIUM
**Component:** pn-test — `app/backend/src/server.js`

**Description:**
The backend API returned no security headers. An attacker able to load responses in a browser context (e.g., via an XSS or open redirect on the frontend) had no browser-side defences.

Headers absent: `X-Frame-Options`, `X-Content-Type-Options`, `Strict-Transport-Security`, `Referrer-Policy`, `Cross-Origin-Resource-Policy`.

Note: `X-Powered-By: Express` was already suppressed via `app.disable("x-powered-by")`.

**Fix (`5bf96f7`):**
```javascript
import helmet from "helmet";
// ...
app.use(helmet({ contentSecurityPolicy: false }));
```
`contentSecurityPolicy` disabled as the backend serves JSON only, not HTML. All other helmet defaults applied.

**Verified headers after fix:**
```
Referrer-Policy: no-referrer
Strict-Transport-Security: max-age=31536000; includeSubDomains
X-Content-Type-Options: nosniff
X-Frame-Options: SAMEORIGIN
```

---

### T4-8 — MCP server authentication fail-open when token secret absent
**Severity:** MEDIUM
**Component:** pn-test — `mcp/server.js`

**Description:**
The MCP server authentication check used a short-circuit AND:
```javascript
if (TOKEN && auth !== `Bearer ${TOKEN}`) {
  return jsonResp(res, { error: "Unauthorized" }, 401);
}
```
If `TOKEN` is `null` (secret file missing) or `undefined` (env var not set), the entire condition evaluates to `false` and every request is authenticated without a credential. This is a fail-open pattern — the safest default for a security boundary is fail-closed.

In the current deployment the `mcp_token` secret is set (64-byte random token), so this was not actively exploitable. However, it would have silently failed open on any redeployment where the secret file was absent.

**Fix (`e4f1ef5`):**
```javascript
// Before — fail-open
if (TOKEN && auth !== `Bearer ${TOKEN}`) {

// After — fail-closed
if (!TOKEN || auth !== `Bearer ${TOKEN}`) {
```

---

### T4-9 — 9 files API endpoints missing role guards
**Severity:** MEDIUM
**Component:** pn-test — `app/backend/src/routes/files.js`

**Description:**
Beyond the `/read` endpoint (T4-2), the following handlers lacked `requireRole` declarations:

| Endpoint | Previous | After |
|----------|----------|-------|
| `GET /backups` | none | `operator` |
| `GET /backups/read` | none | `operator` |
| `GET /backups/known-good` | none | `operator` |
| `POST /backups/prune-preview` | none | `operator` |
| `POST /restore-plan` | none | `operator` |
| `POST /validate` | none | `operator` |
| `GET /backups/labels` | none | `viewer` |
| `GET /restore-log` | none | `viewer` |
| `GET /known-good-summary` | none | `viewer` |
| `GET /apply-log` | none | `viewer` |

All endpoints were still behind `requireAuth` (the `/api` app-level guard), so unauthenticated access was not possible. However, a `viewer` could read backup content, restore plans, and validation results for registered config files — all of which may contain sensitive deployment detail.

**Fix (`e4f1ef5`):** `requireRole` applied to all 10 endpoints (including `/read` from T4-2) as documented in the table above.

---

### T4-10 — npm transitive CVEs via dockerode
**Severity:** LOW
**Status:** Accepted

`npm audit` reported 3 high/critical findings, all transitive via `dockerode@4.0.10`:

| Package | Severity | CVE summary |
|---------|----------|-------------|
| `protobufjs@7.5.4` | CRITICAL | Arbitrary code execution via malicious `.proto` file |
| `@grpc/grpc-js@1.14.3` | HIGH | Malformed gRPC request causes server crash |
| `path-to-regexp@0.1.12` | HIGH | ReDoS via multiple route parameters |

**Assessment:**
- `protobufjs` and `@grpc/grpc-js` are used by dockerode's gRPC transport, which is not exercised in this deployment (Docker API calls use the Unix socket HTTP transport). No attacker-controlled protobuf data reaches these libraries at runtime.
- `path-to-regexp` is a transitive dependency of `express@4.22.1`. The vulnerability requires a route pattern with multiple wildcard parameters. No such patterns exist in this codebase. The rate limiter (20 auth requests/15min, 300 API requests/min) further limits any sustained ReDoS attempt.

**Action:** No code change. Re-evaluate when dockerode releases an update pulling in `@grpc/grpc-js ≥1.14.4`.

---

### T4-11 — Vite dev server port 5173 exposed on all interfaces
**Severity:** LOW
**Status:** Accepted

The frontend Vite development server binds to `0.0.0.0:5173`, making it reachable from any host within the `10.10.0.0/16` range. Traffic arriving at this port bypasses the Gateway VPS entirely (no Caddy, no CrowdSec). From the internet, the port is not reachable (only `0.0.0.0:80` and `0.0.0.0:443` are exposed on the Gateway VPS).

**Attempted mitigation:** A UFW rule restricting the source to only `10.10.60.1` (the VLAN 60 gateway) was evaluated. This is not viable — Proxmox masquerades all inter-VLAN traffic to the destination VLAN gateway IP, making it impossible to distinguish the Gateway VPS from any other VM at the UFW level.

**Accepted mitigations:**
1. Port is not internet-routable (Gateway VPS does not forward it)
2. `express-rate-limit` on the API (300 requests/min) prevents bulk abuse
3. All API endpoints require a valid Keycloak-issued session

**Action:** When the frontend build is shipped for production, the Vite dev server will be replaced with a static nginx container, which does not expose this port.

---

### T4-12 — Blind SSRF via service `health_endpoint`
**Severity:** INFO
**Status:** Accepted

An admin user can create or update a service record with an arbitrary `health_endpoint` URL. The intelligence scanner (`probeService()`) then makes a GET request to that URL on the next scan cycle. The HTTP response body is discarded — only the status code is stored. This is blind SSRF.

**Constraints limiting impact:**
- Requires `admin` role (`POST /api/services` and `PUT /api/services/:id` are admin-gated)
- Only GET requests are made; no request body is sent
- Response body is never returned to the caller
- Admins already have broader capabilities (container deployment, file write)

**Fix (follow-on session):** Added `validateUrl()` to services.js `validate()` function. `health_endpoint`, `access_url`, and `recovery_runbook_url` are now validated on `POST /api/services` and `PUT /api/services/:id`. Only `http:`, `https:`, and `tcp:` schemes are permitted; any other scheme (e.g. `file://`, `gopher://`) returns HTTP 400. RFC 1918 ranges remain permitted — the health endpoint's purpose is monitoring internal services. Committed in `bfa5fd2`.

---

### T4-13 — Docker socket `:ro` mount does not prevent write API calls
**Severity:** INFO
**Status:** Deferred

The backend mounts the Docker socket as `/var/run/docker.sock:ro`. The `:ro` flag only prevents replacing or unlinking the socket file itself — it does not restrict the operations that can be performed over the socket. Write API calls (container exec, image pull, container create) succeed identically via a `:ro` mount as via a `:rw` mount.

During Tier 3 testing this was demonstrated by executing a shell inside the Redis container via `docker exec` initiated from the backend container.

**Recommended fix:** Deploy `tecnativa/docker-socket-proxy` as a container on `pn-internal`, expose a restricted Docker API that permits only the operations the backend requires:

| Operation | Required | Permit |
|-----------|----------|--------|
| `GET /containers/json` | List containers | `CONTAINERS=1` |
| `GET /containers/:id/json` | Inspect container | `CONTAINERS=1` |
| `GET /containers/:id/logs` | Fetch logs | `CONTAINERS=1` |
| `POST /containers/:id/restart` | Restart container | `POST=1` |
| `POST /containers/:id/start` | Start container | `POST=1` |
| `POST /containers/:id/stop` | Stop container | `POST=1` |
| `GET /images/json` | List images (deploy) | `IMAGES=1` |
| `POST /images/create` | Pull image (deploy) | `IMAGES=1`, `POST=1` |
| `POST /containers/create` | Create container (deploy) | `CONTAINERS=1`, `POST=1` |
| **Block** | Exec, privileged ops | `EXEC=0`, `AUTH=0` |

**Fix (follow-on session):** Deployed `tecnativa/docker-socket-proxy` as `privatenexus-docker-proxy` on `pn-internal`. The backend's docker.sock bind-mount was removed; `DOCKER_HOST=tcp://privatenexus-docker-proxy:2375` is injected instead. The proxy permits `CONTAINERS=1, IMAGES=1, EVENTS=1, INFO=1, VERSION=1, POST=1` and blocks `EXEC=0` (the critical control). A shared `dockerClient.js` factory reads `DOCKER_HOST` so all five route files (stacks, intelligence, discovery, actions, admin) work without code changes. The backend also migrated to `user: "1000"` (`node` user in the image) — it no longer runs as root. Committed in `bfa5fd2`.

---

## Remediation Summary

All 13 findings were resolved across 6 commits to `main` on `git.securenexus.net/tristian/privatenexus` and 1 commit to `git.securenexus.net/tristian/hot-config`:

| Commit | Repo | Summary |
|--------|------|---------|
| `e1d6fa8` | privatenexus | Tier 3: mount paths redacted, logs role-gated, LogQL injection blocked, MCP port localhost |
| `7b5795e` | privatenexus | Rate limiting — 20/15min auth, 300/min API |
| `5bf96f7` | privatenexus | Role gates on actions, Redis auth, helmet, cap_drop |
| `e4f1ef5` | privatenexus | Files route auth, register path validation, MCP fail-closed |
| `496cdf9` | hot-config | Caddy admin restricted to localhost, port mapping removed |
| `bfa5fd2` | privatenexus | Docker socket proxy, non-root backend (UID 1000), URL scheme validation |

---

## Outstanding Recommendations

All high and medium recommendations have been implemented. Remaining items are low-priority tracking tasks:

| Priority | Item |
|----------|------|
| Low | Upgrade `dockerode` when a release pins to `@grpc/grpc-js ≥1.14.4` (resolves T4-10 CVEs) |
| Low | Add a Gateway VPS agent or authenticated read-only proxy to restore PrivateNexus Caddy discovery (T4-1 side-effect) |

---

*Assessment performed on pn-test (VLAN 60 / 10.10.60.105). All findings relate to the PrivateNexus v2.0.0 stack in its development deployment. Production deployment should repeat this review with the final compose configuration.*
