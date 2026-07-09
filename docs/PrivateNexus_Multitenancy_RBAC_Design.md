# PrivateNexus — Multi-Tenancy & RBAC Design
**Version: 1.0**
**Date: 22 June 2026**
**Owner: House of Trae / PrivateNexus Programme**
**Classification: Internal — Build Reference**

---

## Purpose

This document defines how PrivateNexus isolates tenant data, enforces role-based
access control, and structures the database and API middleware to support multi-tenant
operation from the start, even while only House of Trae is the active tenant.

It is the implementation reference — not a product vision document. Every schema
decision and every middleware pattern described here must be followed consistently.

---

## Current State (v1.9.0)

The following is already deployed on pn-test as of 22 June 2026.

**Database tables live:**
- `tenants` — House of Trae seeded with stable UUID `10000000-0000-0000-0000-000000000001`
- `workspaces` — four seeded: Infrastructure, Business Systems, Personal Services, Monitoring
- `tenant_memberships` — user_sub → tenant_id → role mapping
- `services` — full CRUD, all rows carry `tenant_id`
- `audit_log` — all rows carry `tenant_id`

**Middleware live:**
- `requireAuth` — checks `req.session.user` exists, returns 401 otherwise
- `requireRole(minRole)` — checks role hierarchy against session, returns 403 otherwise
- `userRole(session)` — extracts highest role from session roles array

**Known gap:** `HOT_TENANT_ID` is hardcoded as a module-level constant in `db.js`.
Every route query passes it directly. This works for a single tenant but must be
replaced before a second tenant can be onboarded. See §6 for the migration path.

---

## 1. Tenancy Model

### 1.1 Hierarchy

```
Tenant (e.g. House of Trae)
  └── Workspace (e.g. Infrastructure, Business Systems)
       └── Service (e.g. ERPNext, Nextcloud)
```

A tenant is the top-level billing and isolation boundary.
A workspace is an operational grouping within a tenant — equivalent to a team or environment.
A service belongs to exactly one tenant and optionally one workspace.

### 1.2 Tenant table

```sql
CREATE TABLE tenants (
  id         UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  name       TEXT         NOT NULL,
  slug       TEXT         NOT NULL UNIQUE,
  created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- House of Trae — stable UUID used in seeds and fixtures
-- '10000000-0000-0000-0000-000000000001'
INSERT INTO tenants (id, name, slug)
VALUES ('10000000-0000-0000-0000-000000000001', 'House of Trae', 'house-of-trae')
ON CONFLICT (slug) DO NOTHING;
```

The stable UUID for House of Trae must never change. It is referenced in seeds, test
fixtures, and audit records. Any migration that touches this value is high-risk and
requires a separate approval.

### 1.3 Workspace table

```sql
CREATE TABLE workspaces (
  id         UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id  UUID         NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  name       TEXT         NOT NULL,
  slug       TEXT         NOT NULL,
  created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, slug)
);
```

Workspace slugs are unique per tenant, not globally. Two tenants may each have a
workspace named `infrastructure`.

---

## 2. User and Membership Model

### 2.1 User identity

PrivateNexus does not store passwords. Users authenticate through Keycloak. The
only user identifier stored by PrivateNexus is the Keycloak `sub` claim (a stable UUID).

```sql
CREATE TABLE tenant_memberships (
  id         BIGSERIAL    PRIMARY KEY,
  user_sub   TEXT         NOT NULL,   -- Keycloak sub claim
  tenant_id  UUID         NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  role       TEXT         NOT NULL,
  joined_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  UNIQUE (user_sub, tenant_id)
);
```

A user can belong to multiple tenants with different roles in each. The session
carries which tenant is active. Future versions will support a tenant-switcher UI.

### 2.2 Session structure

After Keycloak callback, the session is populated as:

```json
{
  "user": {
    "sub": "keycloak-uuid",
    "username": "tristian",
    "email": "tristian@securenexus.net",
    "roles": ["admin"],
    "tenantId": "10000000-0000-0000-0000-000000000001",
    "tenantSlug": "house-of-trae"
  }
}
```

The `tenantId` in the session is the source of truth for all tenant-scoped queries
in the current request. It must never come from a query parameter or request body.

---

## 3. Role-Based Access Control

### 3.1 Role hierarchy

```
breakglass  (level 4)  — emergency recovery; must be separately protected; heavily logged
superadmin  (level 3)  — full tenant admin; integration config; step-up auth for destructive actions
admin       (level 2)  — service management; user role assignment; approve discoveries
operator    (level 1)  — restart approved services; trigger health checks; maintenance mode
viewer      (level 0)  — read-only; no action endpoints
```

A user holding `admin` implicitly has all `operator` and `viewer` permissions.
The hierarchy is enforced by `requireRole(minRole)` — it checks `userLevel >= minLevel`.

### 3.2 Middleware implementation (current — v1.9)

```js
const ROLE_HIERARCHY = ["viewer", "operator", "admin", "superadmin", "breakglass"];

export function requireRole(minRole) {
  const minLevel = ROLE_HIERARCHY.indexOf(minRole);
  return (req, res, next) => {
    const userRoles = req.session?.user?.roles ?? [];
    const userLevel = Math.max(
      ...userRoles.map(r => ROLE_HIERARCHY.indexOf(r)).filter(l => l >= 0),
      -1
    );
    if (userLevel >= minLevel) return next();
    res.status(403).json({ error: "Forbidden", required: minRole });
  };
}
```

Rules:
- Always use `requireRole` server-side. Never trust the frontend to enforce role gates.
- Apply `requireRole` at the router level, not inside individual handler functions.
- `requireAuth` must be applied before `requireRole`. Both are already mounted globally
  on `/api` in `server.js` — do not duplicate them inside individual routers.

### 3.3 Route permission matrix

| Route group | Minimum role | Notes |
|---|---|---|
| `GET /api/*` (read) | viewer | Default for all read routes |
| `POST /api/services` | admin | Creating a service record |
| `PUT /api/services/:id` | admin | Full service update |
| `PATCH /api/services/:id` | admin | Status or archive toggle |
| `POST /api/services/workspaces` | admin | Create workspace |
| `DELETE /api/services/workspaces/:id` | admin | Delete workspace |
| `POST /api/actions/*` | operator | All safe action endpoints |
| `GET /api/admin/*` | admin | User list, role management |
| `POST /api/admin/roles` | superadmin | Role assignment |
| `GET /api/audit-events` | admin | Full audit log |
| `POST /api/discovery/approve` | admin | Approve discovery candidate |
| `POST /api/policies/*` | superadmin | Policy rule management |
| Breakglass routes | breakglass | Defined per-action, step-up auth required |

### 3.4 Keycloak role mapping

Roles are carried as a `roles` array in the Keycloak token (realm or client role claim).
The auth callback reads this claim and stores it in `req.session.user.roles`.

```js
// In auth callback — after token exchange
const roles = tokenClaims.roles ?? tokenClaims.realm_access?.roles ?? [];
req.session.user = {
  sub: tokenClaims.sub,
  username: tokenClaims.preferred_username,
  email: tokenClaims.email,
  roles: roles.filter(r => ROLE_HIERARCHY.includes(r)),
  tenantId: HOT_TENANT_ID,   // v1.x — replaced with lookup in v2.x
  tenantSlug: "house-of-trae",
};
```

Only roles that exist in `ROLE_HIERARCHY` are stored. Unknown Keycloak roles are
silently dropped — they do not error, they simply grant no additional access.

---

## 4. Tenant Isolation Rules

These rules are non-negotiable. A tenant isolation defect in production is a critical
incident and a commercial liability.

### 4.1 Database layer

1. **Every tenant-owned table must have a `tenant_id` column.** No exceptions.
   Tables: `services`, `workspaces`, `audit_log`, `health_events` (future),
   `backups` (future), `discovery_candidates` (future), `action_policies` (future).

2. **Every SELECT on a tenant-owned table must include `WHERE tenant_id = $n`.**
   Use `req.session.user.tenantId` — never trust a tenant ID from the request body
   or query string.

3. **Every INSERT on a tenant-owned table must supply `tenant_id` from the session.**

4. **Every UPDATE and DELETE on a tenant-owned table must include `AND tenant_id = $n`**
   as the final condition. This prevents a user in Tenant A from modifying records
   owned by Tenant B even if they guess the UUID.

5. **Joins must not leak cross-tenant data.** When joining `services` to `workspaces`,
   include `AND w.tenant_id = s.tenant_id` or filter by the session tenant_id.

### 4.2 API layer

1. **Never trust the frontend for tenant filtering.** A request that includes
   `?tenant_id=<other-uuid>` must be ignored — use the session value only.

2. **Tenant ID in the session is set once at login and carried for the session lifetime.**
   It changes only when the user explicitly switches tenants (future feature).

3. **Response bodies must never include data from another tenant.** Even in error
   messages — never expose another tenant's record IDs, names, or slugs.

4. **Audit events must always include the session tenant_id.** An audit event with
   a null tenant_id is a data integrity problem, not a valid state.

### 4.3 Testing tenant isolation

Before every minor or major release, run the following checks:

```
1. Create two tenants: tenant-a and tenant-b.
2. Create a service owned by tenant-a.
3. Authenticate as a user with tenant-b membership.
4. Attempt GET /api/services — confirm tenant-a service is not in the response.
5. Attempt GET /api/services/<tenant-a-service-id> — confirm 404.
6. Attempt PUT /api/services/<tenant-a-service-id> — confirm 404.
7. Confirm audit log for tenant-b does not contain any tenant-a records.
```

---

## 5. Audit Log Design

### 5.1 Schema

```sql
CREATE TABLE audit_log (
  id         BIGSERIAL    PRIMARY KEY,
  ts         TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  tenant_id  UUID         REFERENCES tenants(id),
  user_sub   TEXT         NOT NULL,
  username   TEXT         NOT NULL,
  role       TEXT         NOT NULL,
  action     TEXT         NOT NULL,
  target     TEXT,
  outcome    TEXT         NOT NULL CHECK (outcome IN ('success', 'failure')),
  detail     JSONB,
  ip         TEXT
);
CREATE INDEX audit_log_ts_idx       ON audit_log (ts DESC);
CREATE INDEX audit_log_username_idx ON audit_log (username);
CREATE INDEX audit_log_action_idx   ON audit_log (action);
CREATE INDEX audit_log_tenant_idx   ON audit_log (tenant_id);
```

### 5.2 Immutability rule

**No UPDATE or DELETE on `audit_log` is permitted under any circumstances.**
Grant the application user only INSERT and SELECT on this table.
Archive old records to cold storage after the retention window — do not delete in place.

### 5.3 Action naming convention

```
<resource>.<verb>          — e.g. service.create, service.archive
<resource>.<verb>.<detail> — e.g. service.restart.cooldown_active
auth.<verb>                — e.g. auth.login, auth.logout, auth.login_failed
user.<verb>                — e.g. user.role_assigned, user.removed
discovery.<verb>           — e.g. discovery.approved, discovery.rejected
policy.<verb>              — e.g. policy.created, policy.evaluated
```

All action names are lowercase with dots. No spaces, no camelCase in action names.

### 5.4 What must be audited

Every write operation (create, update, delete, archive) on any tenant-owned resource.
Every authentication event (login, logout, failed login).
Every privileged action (restart, backup trigger, maintenance mode, role assignment).
Every forbidden access attempt (403 responses from requireRole).
Every discovery approval or rejection.

What must NOT be in the audit log: passwords, raw secrets, session tokens,
full request bodies containing credentials.

---

## 6. Multi-Tenant Migration Path (v1.x → v2.x)

The current v1.9 codebase hardcodes `HOT_TENANT_ID` in `db.js`. This is the correct
approach for a single-tenant phase but must be replaced before a second tenant can
be onboarded. The migration is a breaking change and must be done in one coordinated release.

### 6.1 What changes

**db.js** — Remove `HOT_TENANT_ID` export. Replace with a `getTenantId(req)` helper:

```js
export function getTenantId(req) {
  const id = req.session?.user?.tenantId;
  if (!id) throw new Error("No tenant in session");
  return id;
}
```

**Every route** — Replace `HOT_TENANT_ID` with `getTenantId(req)`.

**Auth callback** — Replace hardcoded tenant assignment with a lookup:

```js
// Look up which tenant(s) the user belongs to based on user_sub or email domain
const membership = await pool.query(
  "SELECT tenant_id, role FROM tenant_memberships WHERE user_sub = $1 LIMIT 1",
  [tokenClaims.sub]
);
// If no membership found, check if auto-provisioning is enabled for this tenant
```

**Tenant switcher** — A new `/api/auth/switch-tenant` endpoint sets a new `tenantId`
in the session after verifying the user has a membership in the target tenant.

### 6.2 Migration checklist

- [ ] `getTenantId(req)` helper implemented and unit-tested
- [ ] All routes updated to use `getTenantId(req)` — grep for `HOT_TENANT_ID` in routes/
- [ ] Auth callback uses membership lookup, not hardcoded UUID
- [ ] Tenant boundary integration tests pass for two-tenant scenario
- [ ] Tenant switcher endpoint implemented and protected by `requireAuth`
- [ ] Admin UI shows current tenant in header
- [ ] All audit events confirmed to carry correct tenant_id after migration

---

## 7. Future: Action Policies and Tenant Scoping

When the action policy engine is built (v3.0), policies must be tenant-scoped:

```sql
CREATE TABLE action_policies (
  id              UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID         NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  action          TEXT         NOT NULL,
  allowed_roles   TEXT[]       NOT NULL,
  requires_confirm BOOLEAN     NOT NULL DEFAULT TRUE,
  allowed_targets JSONB,
  audit_level     TEXT         NOT NULL DEFAULT 'standard',
  cooldown_secs   INTEGER      NOT NULL DEFAULT 60,
  created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
```

Policy evaluation must always include `WHERE tenant_id = $session_tenant_id`.
A platform superadmin may define global policy templates, but tenants may not see or
inherit another tenant's policies.

---

## 8. Keycloak Realm Configuration Reference

Realm: `privatenexus` on `auth.house-of-trae.com`

| Setting | Value |
|---|---|
| Client ID | `privatenexus` |
| Access type | confidential |
| Standard flow | enabled |
| Valid redirect URIs | `https://privatenexus.net/api/auth/callback` |
| Post-logout redirect | `https://privatenexus.net` |
| Token claim for roles | `roles` (realm role mapper) |
| MFA required for | admin, superadmin, breakglass |
| access_code_lifespan | 300s (default 60s causes expired_code errors — see CLAUDE.md) |

Roles defined in Keycloak: `viewer`, `operator`, `admin`, `superadmin`, `breakglass`.
These must match `ROLE_HIERARCHY` in `requireRole.js` exactly.

For the identity-provider-redirector from house-of-trae master realm:
- Raise `access_code_lifespan` to 300s in the privatenexus realm
- SQL changes to realm config need a Keycloak restart to bust the Infinispan cache

---

*Document owner: House of Trae / PrivateNexus Programme*
*Next revision trigger: multi-tenant migration (v2.x), action policy engine (v3.0)*
*Related: `PrivateNexus_Phase0_Freeze.md`, `PrivateNexus_Release_Roadmap_v1.0.md`*
