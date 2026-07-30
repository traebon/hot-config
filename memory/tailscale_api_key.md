---
name: tailscale-api-key
description: "Location of the live Tailscale API key Mr. Byrne provided 2026-07-15, and what it can/can't do"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 662a2e2b-edf7-4613-857f-27ff2bf97ace
---

A Tailscale API key (`tskey-api-...`, tailnet `spangled-atlas.ts.net`) is stored at
`/opt/stacks/tailscale-api/secrets/tailscale_api_key.txt` on the Gateway VPS (chmod 600, root-only,
NOT git-tracked — deliberately kept out of `/opt/hot-config` since it has tailnet-wide admin scope
(devices/keys/ACLs) and hot-config mirrors to GitHub/Codeberg).

**Why it exists:** Provided while trying to resolve the duplicate Tailscale OIDC client ambiguity
(both `securenexus` and `house-of-trae` Keycloak realms have a `tailscale` client — see the
Keycloak orphaned-client audit in this session, 2026-07-15). Confirmed via `GET
/api/v2/tailnet/-/settings` and the ACL endpoint that **the Tailscale API does not expose custom-OIDC
/ SSO sign-in configuration** — that setting only lives on the admin console's "Sign in with..."
page. So this key does NOT resolve which Keycloak client the tailnet actually uses; that still needs
a manual console check by Mr. Byrne.

**What it's actually useful for:** device listing, ACL read/write, tailnet settings (approval flags,
key expiry, posture collection, etc.) — standard Tailscale API surface, not IdP config.

**Update 2026-07-15:** Also now in Vaultwarden — "Tailscale API Key (tailnet: spangled-atlas.ts.net)"
in the **House of Trae — Gateway VPS** folder. Added via Mr. Byrne running `bw unlock` himself and
pasting back only the resulting `BW_SESSION` token (never the master password) — session was used
once to create the item, then locked and the token file shredded immediately after. This is the
established pattern for any future one-off Vaultwarden write: ask him for a session token, never
the password, and don't keep the session alive longer than the single operation.

**How to apply:** Local file copy at `/opt/stacks/tailscale-api/secrets/` still kept as the
primary/working copy for scripted use; Vaultwarden copy is for durability/cross-device visibility.
