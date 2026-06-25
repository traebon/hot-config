# PrivateNexus — Tier 18 Security Assessment Report
**Date:** 25 June 2026
**Scope:** Frontend — `app/frontend/src/PrivateNexusV1Mockup.jsx`, `app/frontend/src/main.jsx`; dependency CVE audit — `app/backend/`, `app/frontend/`, `mcp/`; Caddy reverse-proxy configuration — `/opt/stacks/caddy/Caddyfile` (`privatenexus.net` block)
**Tester:** JARVIS / Claude Code (assisted, operator-supervised)
**Branch assessed:** `main` @ `264a3d6`

---

## Executive Summary

Tier 18 audited the remaining unreviewed frontend source (`PrivateNexusV1Mockup.jsx`, `main.jsx`), ran `npm audit` across all three package trees (backend, frontend, MCP), and inspected the Caddy reverse-proxy configuration for `privatenexus.net`.

`main.jsx` was found clean — a four-line React entry point with no security surface. `PrivateNexusV1Mockup.jsx` (8,099 lines) contained one significant finding: a duplicate `ErrorBoundary` class at the top of the file with the same unfixed stack-trace exposure pattern corrected in T15-4. Because this boundary is innermost relative to `App.jsx`'s boundary, it is the one that actually catches dashboard crashes — the T15-4 fix was effectively bypassed by this duplicate.

The backend `npm audit` found 1 CRITICAL and 1 HIGH now fixable without breaking changes (protobufjs and grpc-js, previously accepted in T9-2 as "not directly exploitable" — they can now be patched). Several MODERATE issues in qs/express/body-parser were also resolved. The frontend audit resolved a HIGH Vite path-traversal vulnerability and a MODERATE PostCSS XSS (both previously accepted in T9-5 as dev-server only, now patchable). The MCP package tree was clean.

The `privatenexus.net` Caddy block was missing `Strict-Transport-Security`. Other internal services in the same Caddyfile — Forgejo (`git.securenexus.net`), ERPNext (`erp.dickson-supplies.com`), and Nextcloud (`nextcloud.tresemme.space`) — all have HSTS configured. The missing header meant browsers had no guarantee to enforce HTTPS-only access to privatenexus.net.

**4 findings — all 4 fixed.**

---

## Findings Summary

| ID    | Title                                                                                           | Severity | Status |
|-------|-------------------------------------------------------------------------------------------------|----------|--------|
| T18-1 | `PrivateNexusV1Mockup.jsx` — duplicate `ErrorBoundary` exposes `error.stack` in production     | INFO     | Fixed  |
| T18-2 | Backend npm deps — CRITICAL protobufjs + HIGH grpc-js now fixable without breaking changes     | LOW      | Fixed  |
| T18-3 | Frontend npm deps — HIGH Vite path traversal + MODERATE PostCSS XSS now fixable               | INFO     | Fixed  |
| T18-4 | `privatenexus.net` Caddy block missing HSTS header                                             | LOW      | Fixed  |

---

## Detailed Findings

---

### T18-1 — `PrivateNexusV1Mockup.jsx` — duplicate `ErrorBoundary` exposes stack traces in production
**Severity:** INFO
**Component:** `app/frontend/src/PrivateNexusV1Mockup.jsx` (lines 3–16)

**Description:**

T15-4 fixed the `ErrorBoundary` class in `App.jsx` to suppress `error.stack` behind an `import.meta.env.DEV` gate. `PrivateNexusV1Mockup.jsx` contains its own separate `ErrorBoundary` class at the top of the file with the unfixed version:

```javascript
// Before fix — PrivateNexusV1Mockup.jsx lines 3–16
class ErrorBoundary extends React.Component {
  constructor(props) { super(props); this.state = { error: null }; }
  static getDerivedStateFromError(e) { return { error: e }; }
  render() {
    if (this.state.error) {
      return React.createElement('div', { ... },
        React.createElement('h2', null, 'React crash'),
        React.createElement('pre', null, String(this.state.error?.message || this.state.error)),
        React.createElement('pre', null, String(this.state.error?.stack || '')));  // exposed
    }
    return this.props.children;
  }
}
```

Line 8098 of the file wraps `PrivateNexusDashboard` with this local boundary:

```javascript
return React.createElement(ErrorBoundary, null,
  React.createElement(PrivateNexusDashboard, { authUser }));
```

React error boundary resolution is innermost-first. Any error thrown within the dashboard — which is the entire application's interactive surface — is caught by this mockup-local boundary before `App.jsx`'s corrected boundary can handle it. The T15-4 fix therefore only applies to errors that occur *outside* the dashboard component (e.g., during route resolution or auth loading), not to the 99% of crashes that happen inside it.

**Fix:** Applied the same `import.meta.env.DEV` gate as T15-4:

```javascript
render() {
  if (this.state.error) {
    const isDev = typeof import.meta !== 'undefined' && import.meta.env?.DEV;
    return React.createElement('div', { ... },
      React.createElement('h2', null, 'Something went wrong'),
      React.createElement('p', null, 'An unexpected error occurred. Please refresh the page or contact support.'),
      isDev && React.createElement('pre', { style: { marginTop: 16, fontSize: 12, opacity: 0.7 } },
        String(this.state.error?.stack || this.state.error?.message || this.state.error)));
  }
  return this.props.children;
}
```

---

### T18-2 — Backend npm deps — CRITICAL protobufjs + HIGH grpc-js now fixable
**Severity:** LOW
**Component:** `app/backend/package.json`, `app/backend/package-lock.json`

**Description:**

T9-2 accepted protobufjs (CRITICAL: arbitrary code execution) and grpc-js (HIGH: server crash via malformed request) as "transitive via dockerode, not directly exploitable." At that point, no non-breaking fix was available.

`npm audit fix` now resolves both without breaking changes:

| Package | Before | After | CVE |
|---------|--------|-------|-----|
| `protobufjs` | 7.5.4 | 7.6.4 | GHSA-h755-8qp9-cq85 — arbitrary code execution |
| `@grpc/grpc-js` | 1.14.3 | 1.14.4 | GHSA-5375-pq7m-f5r2, GHSA-99f4-grh7-6pcq — server crash |
| `express` | 4.22.1 | 4.22.2 | via qs |
| `body-parser` | 1.20.4 | 1.20.5 | via qs |
| `qs` | 6.14.2 | 6.15.3 | GHSA-wo2m-3k5f-8rqp — DoS via stringify |
| `dockerode` | 4.0.10 | 4.0.12 | partial — uuid still pinned |

**Remaining after fix:** `uuid` (MODERATE: missing buffer bounds check in v3/v5/v6) — still present via dockerode 4.0.12. The full fix requires upgrading to `dockerode@5.0.1` which is a breaking API change. Deferred to T19 for controlled upgrade and testing.

T9-2 is partially superseded: protobufjs and grpc-js are now patched. The accepted rationale ("transitive, not directly exploitable") remains true for uuid/dockerode.

---

### T18-3 — Frontend npm deps — HIGH Vite path traversal + MODERATE PostCSS XSS now fixable
**Severity:** INFO
**Component:** `app/frontend/package.json`, `app/frontend/package-lock.json`

**Description:**

T9-5 accepted Vite CVEs as "dev server only; nginx serves pre-built assets at runtime." `npm audit fix` now resolves the two remaining exploitable entries:

| Package | Severity | CVE | Notes |
|---------|----------|-----|-------|
| `vite` | HIGH | GHSA-4w7w-66w2-5vf9 — path traversal in optimized deps `.map` handling | Dev server only; nginx serves static in prod |
| `postcss` | MODERATE | GHSA-qx2v-qp2m-jg93 — XSS via unescaped `</style>` in CSS stringify | Build-time only; built CSS is static |

Both are now patched. T9-5 is superseded and removed from the accepted findings list.

The MCP package tree (`mcp/package-lock.json`) was found clean — 0 vulnerabilities.

---

### T18-4 — `privatenexus.net` Caddy block missing HSTS
**Severity:** LOW
**Component:** `/opt/stacks/caddy/Caddyfile`

**Description:**

The `privatenexus.net` Caddy block had no `Strict-Transport-Security` header:

```caddyfile
# Before fix
privatenexus.net {
    import crowdsec
    reverse_proxy 10.10.60.105:5173
}
```

Caddy does not add HSTS automatically. Without it, browsers have no cached instruction to enforce HTTPS — a network attacker (e.g., on an enterprise proxy or shared network) can attempt SSL stripping on first visit or after HSTS expiry. Other services in the same Caddyfile already set HSTS:

- `git.securenexus.net` — `max-age=31536000; includeSubDomains`
- `erp.dickson-supplies.com` — `max-age=31536000; includeSubDomains`
- `nextcloud.tresemme.space` — `max-age=15552000; includeSubDomains; preload`

**Fix:**

```caddyfile
privatenexus.net {
    import crowdsec
    reverse_proxy 10.10.60.105:5173
    header Strict-Transport-Security "max-age=31536000; includeSubDomains"
}
```

Caddy reloaded. Verified via `curl -sI https://privatenexus.net` — `strict-transport-security: max-age=31536000; includeSubDomains` present in response.

Note: The nginx container already applies `X-Frame-Options`, `CSP`, `Referrer-Policy`, and `Permissions-Policy` to HTML responses (T13-1). HSTS at the Caddy layer is the correct placement as Caddy is the TLS-terminating server.

---

## `main.jsx` — Clean Assessment

```javascript
import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import "./index.css";

ReactDOM.createRoot(document.getElementById("root")).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
```

Four lines of standard Vite/React entry point. No security surface.

---

## Remediation Summary

| Finding | Files | Change |
|---------|-------|--------|
| T18-1 | `app/frontend/src/PrivateNexusV1Mockup.jsx` | `ErrorBoundary.render()` — `error.stack` suppressed in production via `import.meta.env.DEV` gate |
| T18-2 | `app/backend/package-lock.json` | `npm audit fix` — protobufjs 7.5.4→7.6.4, grpc-js →1.14.4, express →4.22.2, qs →6.15.3, body-parser →1.20.5 |
| T18-3 | `app/frontend/package-lock.json` | `npm audit fix` — vite patched (path traversal), postcss patched (XSS) |
| T18-4 | `/opt/stacks/caddy/Caddyfile` | `header Strict-Transport-Security "max-age=31536000; includeSubDomains"` added to `privatenexus.net` block |

Fixes in commit `b67aa53` on `git.securenexus.net/tristian/privatenexus` (T18-1, T18-2, T18-3).
Caddyfile change in hot-config (T18-4).

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
| 18   | Frontend mockup, dependency CVEs, Caddy HSTS       | 4        | 4     | 0        |
| **Total** | **All tiers**                                | **80**   | **75**| **5**    |

**Accepted findings (cumulative — updated):**
- T5-5: Session fixation — mitigated by OIDC state/nonce + `sameSite: lax`
- T8-4: Docker labels expose compose paths — viewer-only, operator debugging use case
- T9-2: Partially superseded — protobufjs/grpc-js now patched; uuid/dockerode deferred to T19
- T10-4: Blind SSRF via `health_endpoint` — admin-only; no response body exfiltration
- T17-5: MCP read tools bypass audit log — high-value credential, write ops are audited; v2 hardening task

**Note:** T9-5 (Vite frontend CVEs) is fully resolved and removed from accepted list. T9-2 is partially superseded; the residual uuid/dockerode MODERATE carries forward to T19.

*Assessment performed on pn-test (VLAN 60 / 10.10.60.105). All findings relate to the PrivateNexus v2.0.0 stack in its development deployment.*
