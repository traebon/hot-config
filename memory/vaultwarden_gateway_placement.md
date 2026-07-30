---
name: vaultwarden-gateway-placement
description: "Vaultwarden runs on the Gateway VPS itself (not a VM) so credentials stay reachable during a bare-metal outage — a deliberate exception to the \"no databases on Gateway VPS\" rule"
metadata: 
  node_type: memory
  type: project
  originSessionId: 9338d7f0-c0cb-4516-8715-dee614781485
---

Vaultwarden (vault.house-of-trae.com) is deployed directly on the Gateway VPS at `/opt/stacks/vaultwarden/`, using its bundled SQLite backend. This is a deliberate exception to CLAUDE.md's "never deploy databases on the Gateway VPS" rule.

**Why:** Mr. Byrne's own words — the vault needs to be on the Gateway specifically "so passwords would always be available." This was validated in practice during the 2026-07 Hostkey NIC outage (see [[hostkey_server_replacement]]): the entire bare-metal host and all 7 VMs behind it went unreachable for 2+ days, but the Gateway VPS itself stayed up, so Vaultwarden (and the credentials in it — including ones needed to respond to the outage itself, like the temporary Hostkey support account) remained accessible throughout.

**How to apply:** Don't propose "fixing" this by relocating Vaultwarden to a VM for architectural purity — that would reintroduce the exact single point of failure this placement avoids. `ADMIN_TOKEN` is stored as a Docker secret (`ADMIN_TOKEN_FILE`, pre-hashed argon2id PHC string, not plaintext) as of 2026-07-03. This is documented directly in CLAUDE.md's VPS Resource Warning section now too.
