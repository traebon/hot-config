---
name: stalwart-hold
description: Stalwart mail server is on hold — keeping Docker Mailserver + Roundcube until Stalwart has a web client or one is built in-house
metadata: 
  node_type: memory
  type: project
  originSessionId: 860e0291-9df6-45e9-96a0-4559b48971ee
---

Stalwart (`/opt/hot-config/gateway/stalwart/`) is held in reserve — not being deployed.

**Why:** Stalwart lacks a native web client. Current stack (Docker Mailserver + Roundcube) is complete and working. Migration will be reconsidered when Stalwart ships a web client or HoT builds one themselves.

**How to apply:** Do not suggest migrating to Stalwart until the web client situation changes. Do not raise it as an improvement option.
