---
name: keycloak-admin
description: Keycloak master realm admin account — username and auth method for API access
metadata: 
  node_type: memory
  type: project
  originSessionId: 467adec3-5929-48d1-bfe1-ffcb03e89ed2
---

Master realm admin: `tristian` — password stored in `/opt/stacks/keycloak/secrets/admin_password`

**Why:** Original `trae` account password was unknown. `tristian` was created directly via DB insert (argon2id hash) on 2026-06-03 when bootstrap env var method was blocked by Keycloak 26's behaviour on already-initialised instances.

**How to apply:** Use `tristian` + the secret file password when authenticating to the Keycloak Admin API. The secret file is `/opt/stacks/keycloak/secrets/admin_password` (no `.txt` extension — that's the active one used by `compose.yaml`).

Bootstrap env var in `compose.yaml`: `KC_BOOTSTRAP_ADMIN_USERNAME: tristian` — only creates user if master realm has zero users; does NOT update existing users.

Active compose file: `/opt/stacks/keycloak/compose.yaml` (not `compose.yml` — that file was backed up to `.bak`)
