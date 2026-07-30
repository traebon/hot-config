---
name: keycloak-federated-identity
description: How to manually link a federated identity in a child realm — correct userId to use and common pitfalls
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 72515b90-85c0-4d53-9895-24c980349751
---

When manually linking a federated identity to a user in a child realm via `kcadm.sh create users/<id>/federated-identity/<idp-alias>`, the `userId` must be the user's UUID **in the realm the IDP points to**, not the master realm UUID.

**Why:** The `sub` claim in the OIDC token is the user's UUID in the issuing realm. If the `house-of-trae` IDP in the `privatenexus` realm points to `https://auth.house-of-trae.com/realms/house-of-trae`, the userId must come from the `house-of-trae` realm — not master. Using the wrong UUID means Keycloak can't match the incoming token to the link, so it falls through to the first_broker_login flow and asks for re-authentication.

**How to apply:**
1. Check the IDP's `tokenUrl` to identify which realm it points to: `kcadm.sh get identity-provider/instances/<alias> --target-realm <realm>`
2. Get the user ID from that specific realm: `kcadm.sh get users --target-realm <issuing-realm> --query username=<user>`
3. Use that UUID for the `userId` field in the federated identity create call

Also: after any federated identity link is set manually, raise `accessCodeLifespan` on the child realm to 300s (`kcadm.sh update realms/<realm> -s accessCodeLifespan=300 -s accessCodeLifespanUserAction=300 -s accessCodeLifespanLogin=1800`) — the default 60s causes `expired_code` errors during the broker flow. [[keycloak-admin]]
