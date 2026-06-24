# PrivateNexus — Tier 15 Security Assessment Report
**Date:** 24 June 2026
**Scope:** File registry pipeline — `routes/files.js` (`POST /register`), `filesRegistry.js`; `dockerClient.js` (TCP mode); React `ErrorBoundary` (`App.jsx`)
**Tester:** JARVIS / Claude Code (assisted, operator-supervised)
**Branch assessed:** `main` @ `559ba28`

---

## Executive Summary

Tier 15 audited the file registration pipeline (the `POST /api/files/register` handler, `filesRegistry.js`, and the `fileApply.js` consumer introduced in Tier 14), the Docker client TCP configuration path, and the React frontend's error boundary.

The previous tier's fix for `drafts.js` (`assertSafeId()`) introduced a secondary DoS vector: because `filesRegistry.js` calls `hasDraft(entry.id)` for each registered file during `GET /api/files`, any registry entry with a non-slug ID would cause every call to that endpoint to throw. The root cause — the registration handler accepting arbitrary IDs — was the unfixed gap. The `applyStrategy` field had a parallel problem: unknown strategies persisted silently in the registry and caused `applyFile()` to return `{ ok: false }` at apply time with no indication at write time. Both were fixed in the registration handler with format and allowlist validation.

`dockerClient.js` used `protocol: "http"` for TCP connections, which is correct for the `docker-socket-proxy` pattern but would silently connect to a raw Docker daemon over plain HTTP if `DOCKER_HOST` were ever misconfigured. A hostname-pattern warning was added to flag non-proxy targets. The React `ErrorBoundary` was rendering the full JavaScript stack trace to the browser in production — suppressed to a generic message behind an `import.meta.env.DEV` gate.

**4 findings were identified. All 4 were fixed in commit `0d5d831`.**

---

## Findings Summary

| ID    | Title                                                                                      | Severity | Status |
|-------|--------------------------------------------------------------------------------------------|----------|--------|
| T15-1 | `routes/files.js` — no `id` format validation at registration; malformed ID poisons registry and DoS-es `GET /api/files` | MEDIUM | Fixed |
| T15-2 | `routes/files.js` — `applyStrategy` not validated against `KNOWN_STRATEGIES` at registration | LOW | Fixed |
| T15-3 | `dockerClient.js` — TCP mode uses `protocol: "http"` with no guard against raw daemon targets | LOW     | Fixed  |
| T15-4 | `App.jsx` `ErrorBoundary` — full JavaScript stack trace rendered to browser in production  | INFO     | Fixed  |

---

## Detailed Findings

---

### T15-1 — `routes/files.js` — no `id` format validation; malformed ID causes persistent `GET /api/files` DoS
**Severity:** MEDIUM
**Component:** `app/backend/src/routes/files.js`, `app/backend/src/filesRegistry.js`

**Description:**

The `POST /api/files/register` handler accepted `id` from the request body with no format validation:

```javascript
// Before fix
const { id, label, path: filePath, stack, type = "compose", editable = true,
        validatable = false, applyStrategy = null } = req.body;
if (!id || !label || !filePath || !stack) {
  return res.status(400).json({ ok: false, error: "id, label, path, stack are required" });
}
// No id format check — any string accepted
const resolvedPath = path.resolve(filePath);
// ... calls registerFile({ id, ... })
```

`filesRegistry.js` stores the entry verbatim. On every call to `GET /api/files`, `listRegisteredFiles()` iterates all registered entries and calls `hasDraft(entry.id)`:

```javascript
// filesRegistry.js — listRegisteredFiles()
return DEFAULTS.concat(customEntries).map(entry => ({
  ...entry,
  hasDraft: hasDraft(entry.id),  // throws if entry.id fails assertSafeId()
}));
```

The Tier 14 fix added `assertSafeId()` to `drafts.js`, which throws for any ID that does not match `/^[a-zA-Z0-9_-]{1,128}$/`. If an admin registers a file with a non-slug ID (e.g. `../../etc/hosts`, `my file`, or `id<script>`), the thrown error propagates through `listRegisteredFiles()` to the route handler. Without a per-entry `try/catch`, a single bad entry causes `GET /api/files` to return 500 for **all users** until the JSON registry file is manually edited on disk.

**Attack surface:** Requires admin access. An admin who is compromised, coerced, or unaware of the ID format constraint can trigger a persistent DoS. The fix ensures validation at the write path rather than relying on the read path to surface the error.

**Fix:** Added format validation immediately after the required-field check:

```javascript
// T15-1: id must be a safe slug — same pattern as assertSafeId() in drafts.js
if (!/^[a-zA-Z0-9_-]{1,128}$/.test(id)) {
  return res.status(400).json({ ok: false, error: "id must be alphanumeric with hyphens/underscores, max 128 chars" });
}
```

The pattern is identical to `assertSafeId()` in `drafts.js`, keeping the two in sync. All existing DEFAULTS entries (`privatenexus-compose`, `caddy-caddyfile`, etc.) pass this regex.

---

### T15-2 — `routes/files.js` — `applyStrategy` not validated at registration time
**Severity:** LOW
**Component:** `app/backend/src/routes/files.js`, `app/backend/src/fileApply.js`

**Description:**

`POST /api/files/register` accepted any string for `applyStrategy` with no allowlist check. The value is stored in the registry and used later when `POST /api/files/apply` is called. At apply time, `fileApply.js` checks `KNOWN_STRATEGIES` and returns `{ ok: false, output: "Unknown apply strategy: ..." }` for unrecognised values.

The consequence is a misleading write-then-silent-fail pattern: the registration call returns HTTP 201, the UI shows the file as successfully registered, but any subsequent apply attempt fails silently. There is no code execution risk (the handler returns `{ ok: false }` rather than attempting execution), but the persistent invalid state is confusing and difficult to debug.

**Fix:** Imported `KNOWN_STRATEGIES` from `fileApply.js` at request time and validated before storing:

```javascript
// T15-2: validate applyStrategy against known handlers
if (applyStrategy !== null && applyStrategy !== undefined) {
  const { KNOWN_STRATEGIES } = await import("../fileApply.js");
  if (!KNOWN_STRATEGIES.includes(applyStrategy)) {
    return res.status(400).json({
      ok: false,
      error: `Unknown applyStrategy — must be one of: ${KNOWN_STRATEGIES.join(", ")}`
    });
  }
}
```

Dynamic `import()` is used to avoid a circular dependency. `KNOWN_STRATEGIES` is `Object.keys(HANDLERS)` from `fileApply.js` — currently `["compose-up", "caddy-reload"]`.

---

### T15-3 — `dockerClient.js` — TCP mode uses `protocol: "http"` with no guard against raw daemon targets
**Severity:** LOW
**Component:** `app/backend/src/dockerClient.js`

**Description:**

When `DOCKER_HOST` is set to a TCP URL, `dockerClient.js` connects using `protocol: "http"`:

```javascript
// Before fix
const url = new URL(host.replace(/^tcp:\/\//, "http://"));
_client = new Docker({ host: url.hostname, port: Number(url.port), protocol: "http" });
```

The **current** deployment sets `DOCKER_HOST=tcp://privatenexus-docker-proxy:2375`, which points to the `tecnativa/docker-socket-proxy` container on the internal Docker bridge network. Plain HTTP on an internal Docker network is acceptable — the proxy provides filtering, and the network is not reachable externally. This is the recommended pattern.

The risk is a misconfiguration trap: if `DOCKER_HOST` were ever changed to point directly at the Docker daemon's TCP port (e.g. `tcp://host:2375` with `DOCKER_TCP=1` enabled on the daemon), the backend would connect over unencrypted HTTP to an unfiltered daemon with no authentication. The daemon would then accept any API call from the backend, including `exec`, `bind-mount`, and image operations not blocked by the proxy.

There was no runtime check to distinguish the proxy-targeting case from the direct-daemon case.

**Fix:** Added a hostname pattern check at client initialisation. If the TCP target hostname does not contain `docker-proxy` or `socket-proxy`, a warning is logged:

```javascript
// The supported deployment routes through docker-socket-proxy (tcp://...docker-proxy:2375).
// If DOCKER_HOST is ever pointed directly at the Docker daemon TCP port, that would be
// unauthenticated and unfiltered. Log a warning to catch that misconfiguration.
const url = new URL(host.replace(/^tcp:\/\//, "http://"));
const isSocketProxy = url.hostname.includes("docker-proxy") || url.hostname.includes("socket-proxy");
if (!isSocketProxy) {
  console.warn("[docker] WARNING: DOCKER_HOST TCP target does not look like a socket proxy — " +
    "connecting to a raw Docker daemon over plain HTTP is unauthenticated. " +
    "Use docker-socket-proxy or set DOCKER_TLS_VERIFY=1 with TLS certificates.");
}
_client = new Docker({ host: url.hostname, port: Number(url.port), protocol: "http" });
```

The warning fires during startup and appears in container logs, providing an operational signal without breaking the deployment.

**Note:** The finding is accepted as LOW rather than MEDIUM because the proxy is the only production configuration, the Docker bridge network is not externally reachable, and the proxy filters the most dangerous operations (EXEC, NETWORKS). The fix is defensive-in-depth.

---

### T15-4 — `App.jsx` `ErrorBoundary` — full JavaScript stack trace rendered to browser in production
**Severity:** INFO
**Component:** `app/frontend/src/App.jsx`

**Description:**

The React `ErrorBoundary` class rendered `this.state.error?.stack` directly to the browser in all environments:

```javascript
// Before fix
render() {
  if (this.state.error) {
    return React.createElement('div', { style: { ... } },
      React.createElement('h2', null, 'React crash'),
      React.createElement('pre', null, String(this.state.error?.message || this.state.error)),
      React.createElement('pre', null, String(this.state.error?.stack || '')));  // exposed
  }
  return this.props.children;
}
```

JavaScript stack traces expose internal source file paths, component names, and line numbers. In a Vite production build these are minified, but component and module names remain readable. An attacker who triggers a React crash (e.g. via a malformed API response that causes a rendering error) would see the internal structure of the application.

**Fix:** Gated the stack trace display behind `import.meta.env?.DEV`. In production builds, Vite replaces `import.meta.env.DEV` with `false`, so `isDev && React.createElement(...)` evaluates to `false` — the `false` node is not rendered by React. The fallback UI shows a generic message:

```javascript
// After fix
render() {
  if (this.state.error) {
    // Never expose stack traces in production — they leak internal file paths and component tree.
    const isDev = typeof import.meta !== 'undefined' && import.meta.env?.DEV;
    return React.createElement('div', { style: { ... } },
      React.createElement('h2', null, 'Something went wrong'),
      React.createElement('p', null, 'An unexpected error occurred. Please refresh the page or contact support.'),
      isDev && React.createElement('pre', { style: { marginTop: 16, fontSize: 12, opacity: 0.7 } },
        String(this.state.error?.stack || this.state.error?.message || this.state.error)));
  }
  return this.props.children;
}
```

In the current Vite 8 build, `import.meta.env.DEV` is tree-shaken to `false` in production bundles, so zero stack content reaches the DOM in deployed builds.

---

## Supporting Module — `filesRegistry.js` Assessment

`filesRegistry.js` was reviewed as part of the Tier 15 scope. The assessment of the module itself (as distinct from the registration handler gap) found no additional findings:

- `registerFile(entry)` stores entries in a JSON file with `atomicWrite()` — no path traversal from the JSON path itself
- `unregisterFile(id)` checks `DEFAULTS.some(d => d.id === id)` before attempting deletion — prevents removal of built-in entries
- `listRegisteredFiles()` reads from a fixed `REGISTRY_PATH` — not user-controlled
- `atomicWrite()` uses `writeFileSync` to a temp path then `renameSync` — correct atomic write pattern

The sole gap was the lack of ID validation at the write path (T15-1), which propagated to the read path via `hasDraft()`.

---

## Remediation Summary

All 4 findings fixed in commit `0d5d831` on `git.securenexus.net/tristian/privatenexus`:

| Finding | File | Change |
|---------|------|--------|
| T15-1 | `routes/files.js` | `id` format check (`/^[a-zA-Z0-9_-]{1,128}$/`) added before `registerFile()` call |
| T15-2 | `routes/files.js` | `applyStrategy` validated against `KNOWN_STRATEGIES` imported from `fileApply.js` |
| T15-3 | `dockerClient.js` | Hostname pattern check logs warning if TCP target does not appear to be a socket proxy |
| T15-4 | `App.jsx` | `ErrorBoundary.render()` suppresses stack trace in production via `import.meta.env.DEV` gate |

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
| **Total** | **All tiers**                                | **67**   | **62**| **5**    |

**Accepted findings (cumulative — unchanged):**
- T5-5: Session fixation — mitigated by OIDC state/nonce + `sameSite: lax`
- T8-4: Docker labels expose compose paths — viewer-only, operator debugging use case
- T9-2: protobufjs/grpc-js — transitive via dockerode, not directly exploitable
- T9-5: Vite frontend CVEs — dev server only; nginx serves pre-built assets at runtime
- T10-4: Blind SSRF via `health_endpoint` — admin-only; no response body exfiltration

*Assessment performed on pn-test (VLAN 60 / 10.10.60.105). All findings relate to the PrivateNexus v2.0.0 stack in its development deployment.*
