# PrivateNexus — Tier 8 Security Assessment Report
**Date:** 24 June 2026
**Scope:** File management surface, unreviewed routes (ops, apps, catalogue, stacks), ESM compatibility
**Tester:** JARVIS / Claude Code (assisted, operator-supervised)
**Branch assessed:** `main` @ `0b8b728`
**Prior tiers:**
- Tier 1–2: RBAC, session integrity
- Tier 3: Injection, route auth, port exposure
- Tier 4: Infrastructure exposure, container security posture
- Tier 5: Application logic, session security, audit integrity
- Tier 6: Emergency ops safety, role gate completeness, input validation
- Tier 7: Audit trail integrity, workflow logic, validation completeness

---

## Executive Summary

Tier 8 completed the full route audit, covering the file management system (`files.js` — 842 lines, the largest route file), and four previously unreviewed routes: `ops.js`, `apps.js`, `catalogue.js`, and `stacks.js`. The file management system is well-structured with whitelist-based file registration, backup/restore safety guards, and `validateTargetPath` enforcing same-directory constraints for side-by-side restores. Three issues were found and fixed; one was accepted.

**4 findings were identified. 3 were fixed in commit `0b8b728`. 1 accepted.**

---

## Findings Summary

| ID   | Title                                                                        | Severity | Status   |
|------|------------------------------------------------------------------------------|----------|----------|
| T8-1 | `POST /api/files/register` — `require()` in ESM module crashes backend      | MEDIUM   | Fixed    |
| T8-2 | `GET /api/apps/` — no `requireRole` guard                                   | LOW      | Fixed    |
| T8-3 | File registry path allowlist — `/opt/privatenexus/app/` not blocked         | LOW      | Fixed    |
| T8-4 | `GET /api/stacks/:id` — Docker labels expose compose config file paths      | INFO     | Accepted |

---

## Detailed Findings

---

### T8-1 — `POST /api/files/register` uses `require()` in ESM — backend crash
**Severity:** MEDIUM
**Component:** `app/backend/src/routes/files.js`

**Description:**
The `POST /api/files/register` endpoint (admin-only) contained a CommonJS `require()` call inside an ESM module:

```javascript
// Before fix — ReferenceError: require is not defined
const resolvedPath = require("path").resolve(filePath);
```

The project is declared as ESM (`"type": "module"` in `package.json`, Phase 0 freeze). `require` is not available in ESM modules. The call is synchronous and outside the endpoint's `try-catch` block. In an `async` route handler, a synchronous throw outside a try-catch propagates as an unhandled Promise rejection.

**Impact:** Node.js 20 terminates the process on unhandled rejections. Any admin calling `POST /api/files/register` — including accidental calls from the UI — would crash the backend process. Docker `unless-stopped` restarts it within seconds, creating a brief service disruption. The path traversal protection (`BLOCKED_PREFIXES` check, `/opt/` allowlist) that follows the crash never executes.

`path` is already imported at the top of the file (`import path from "path"`), making the fix a one-character change.

**Confirmed:** `"type": "module"` in `package.json`. Code review confirms `require` is used with no `createRequire` setup. Endpoint returns `403 Forbidden` for operator-role sessions (requireRole("admin") fires first), so the crash can only be triggered by an authenticated admin.

**Fix:**
```javascript
// After fix
const resolvedPath = path.resolve(filePath);
```

---

### T8-2 — `GET /api/apps/` missing `requireRole` guard
**Severity:** LOW
**Component:** `app/backend/src/routes/apps.js`

**Description:**
The app status endpoint had no `requireRole` guard. While the global `requireAuth` middleware prevents unauthenticated access, any session that passes `requireAuth` — regardless of role — could retrieve the list of 16 HoT applications including their container names, internal probe URLs, and live up/down status from Prometheus:

```javascript
// Before fix — no requireRole
appsRouter.get("/", async (_req, res) => {
```

Container names (e.g., `dickson-backend`, `monitoring-grafana-1`, `immich_server`) and internal probe URLs (e.g., `https://photos.tresemme.space`, `https://auth.house-of-trae.com`) are part of the response. Every other data-bearing route in the codebase uses an explicit `requireRole`.

**Confirmed:** `curl http://127.0.0.1:3001/api/apps/` → `401`. With operator session via MCP token → `200 — 16 apps`.

**Fix:** Added import and role gate:
```javascript
import { requireRole } from "../middleware/requireRole.js";
// ...
appsRouter.get("/", requireRole("viewer"), async (_req, res) => {
```

---

### T8-3 — File registry path allowlist doesn't block `/opt/privatenexus/app/`
**Severity:** LOW
**Component:** `app/backend/src/routes/files.js`

**Description:**
`POST /api/files/register` validates the requested path against a blocklist and an `/opt/` allowlist:

```javascript
// Before fix
const BLOCKED_PREFIXES = ["/run/secrets", "/opt/privatenexus/secrets", "/root", "/etc", "/proc", "/sys"];
if (BLOCKED_PREFIXES.some((p) => resolvedPath === p || resolvedPath.startsWith(p + "/"))) {
  return res.status(403).json({ ok: false, error: "Path is in a restricted directory" });
}
if (!resolvedPath.startsWith("/opt/")) {
  return res.status(403).json({ ok: false, error: "Registered paths must be under /opt/" });
}
```

`/opt/privatenexus/secrets` is correctly blocked. However, `/opt/privatenexus/app/` — the backend source code directory — was not. After T8-1's fix, an admin could:

1. Register `/opt/privatenexus/app/backend/src/server.js` as an editable file
2. Use `POST /api/files/write` to overwrite it with arbitrary content
3. Trigger a restart (via `stacks.restart-all` emergency action) to execute the injected code

This is admin-only and requires deliberate abuse of privileged operations; it is not an escalation beyond existing admin capability. However, defence-in-depth requires the file management system not to grant write access to its own runtime files.

**Fix:** Added `/opt/privatenexus/app` to `BLOCKED_PREFIXES`:
```javascript
const BLOCKED_PREFIXES = [
  "/run/secrets", "/opt/privatenexus/secrets", "/opt/privatenexus/app",
  "/root", "/etc", "/proc", "/sys"
];
```

---

### T8-4 — `GET /api/stacks/:id` — Docker labels expose compose config paths
**Severity:** INFO
**Status:** Accepted

**Description:**
`GET /api/stacks/:id` returns the full `Config.Labels` object from the Docker container inspect response:

```javascript
labels: info.Config?.Labels || {},
```

Docker Compose sets `com.docker.compose.project.config_files` to the full host path of the compose file (e.g., `/opt/privatenexus/compose/docker-compose.yml`). The code already consciously omits mount source paths ("src (host path) omitted — would expose secret file locations on the host"), but labels carry the same information via this key.

The route requires `requireRole("viewer")`, which is the minimum authenticated role. Operators need compose file path context to debug deployment issues. The `GET /api/stacks/` list endpoint also exposes `composeFile` from `formatContainer()` for the same reason.

**Mitigating factors:**
- Viewer is the minimum role — no lower-privileged authenticated user exists
- The paths exposed are well-known compose directories (`/opt/privatenexus/compose/`, `/opt/stacks/*/`)
- Filtering would break the operator debugging use case

**Action:** Accepted. If the product ever exposes a read-only guest role below viewer, filter `com.docker.compose.project.config_files` from label output.

---

## Remediation Summary

All 3 fixed findings resolved in commit `0b8b728` on `git.securenexus.net/tristian/privatenexus`:

| Finding | Change |
|---------|--------|
| T8-1 | `require("path").resolve()` → `path.resolve()` (uses already-imported `path` module) |
| T8-2 | `requireRole("viewer")` added to `GET /api/apps/`; `requireRole` import added to `apps.js` |
| T8-3 | `/opt/privatenexus/app` added to `BLOCKED_PREFIXES` in register handler |

---

## File Management System Assessment (files.js)

The `files.js` module (842 lines) is the most complex route file in the codebase. Overall it is well-designed:

- **All write operations** (`/write`, `/restore`, `/restore-and-apply`, `/prune`, `/apply`) require `admin` role
- **Read operations** (`/read`, `/backups`, `/backups/read`) require `operator`
- **Informational routes** (`/restore-log`, `/apply-log`, `/known-good-summary`) require `viewer`
- **Side-by-side restore** uses `validateTargetPath()` which enforces same-directory constraint — cannot write to an arbitrary path
- **Backup naming** uses `${id}__...bak` prefix enforcement — cannot read/restore a backup belonging to another file
- **Pre-write and pre-apply validation** runs `validateFile()` for validatable file types (e.g., YAML, Caddyfile) before touching the live path
- **`applyFile()`** uses an explicit `HANDLERS` allowlist (`compose-up`, `caddy-reload`) — no arbitrary command execution

No additional findings in the file management system beyond T8-1 and T8-3.

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
| 8    | File management, remaining routes, ESM compat      | 4        | 3     | 1       |
| **Total** | **All tiers**                                 | **34**   | **32**| **2**   |

**Accepted findings:**
- T5-5: Session fixation — mitigated by OIDC state/nonce + `sameSite: lax`
- T8-4: Docker labels expose compose paths — viewer-only, operator debugging use case

*Assessment performed on pn-test (VLAN 60 / 10.10.60.105). All findings relate to the PrivateNexus v2.0.0 stack in its development deployment.*
