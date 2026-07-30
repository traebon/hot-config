---
name: uptime-kuma-setup-2026-07-30
description: "Uptime Kuma was never actually configured post-rebuild (zero users, zero monitors) despite the container running healthy — fixed 2026-07-30: admin account, 26 monitors, public hot-status status page all created"
metadata: 
  node_type: memory
  type: project
  originSessionId: f361f2af-99b4-4220-ba53-a42472c872f0
  modified: 2026-07-30T13:39:20.193Z
---

Confirmed via a full monitoring-stack audit (Prometheus scrape targets, Promtail→Loki shipping,
node-exporter/Watchtower presence — all clean across the 4 hot-bm-nl VMs) that the one real gap
was Uptime Kuma: the container was up and healthy, but its sqlite DB had **zero rows in both
`user` and `monitor`** — the setup wizard was never run after the 2026-07-27 rebuild. Live impact:
`https://status.house-of-trae.com` was 302-redirecting to `/dashboard` (the unconfigured
login/setup flow) instead of serving the public status page CLAUDE.md documents.

**Fixed 2026-07-30 — no REST API exists for this (Uptime Kuma is Socket.io-only), so drove it via
a Node script using the `socket.io-client` package already bundled in the container's
`node_modules`, calling the same events the frontend does:**
- `setup(username, password, cb)` — only works once, when `user` table is empty
- `login({username,password}, cb)` — get an authenticated session on the socket
- `add(monitorBean, cb)` — one call per monitor; had to mirror the frontend's exact
  `monitorDefaults` object (`src/pages/EditMonitor.vue`) since `bean.import()` takes whatever
  fields are passed with no server-side default-filling
- `addStatusPage(title, slug, cb)` then `saveStatusPage(slug, config, imgDataUrl,
  publicGroupList, cb)` — two-step; `config.domainNameList` must be an array or `saveStatusPage`
  throws "Invalid array" (hit this, fixed by passing `[]`)
- `setSettings({entryPage: "statusPage-hot-status"}, currentPassword, cb)` — per-key upsert
  (`Settings.setSettings` only touches keys present in the payload, safe to send just this one
  field) — needed separately to make `status.house-of-trae.com/` itself serve the page; without
  it only `/status/hot-status` worked, root still 302'd to `/dashboard`

**26 monitors created:**
- 6 `[Public]` — the group entity sites (house-of-trae.com, securenexus.net, byrne-accounts.org,
  stratus-digital.com, discreet-elite.uk, emerald-markets.net) — these are the only ones in the
  public `hot-status` status page's group list, matching CLAUDE.md's documented scope exactly.
  PrivateNexus deliberately excluded from the public page (dev/test env, not treated as a public
  group-entity site) — checked instead under Internal.
- 14 `[Internal]` — Keycloak, Grafana, Webmail, Forgejo, PowerDNS-Admin, Namevault, Ntfy,
  Vaultwarden, Wazuh, ERPNext (hot-erp), PrivateNexus (hot-pn), Ruby Osiris, Evil Rabbit Art,
  Dickson Supplies — admin-dashboard-only, not on the public page
- 6 `[Fleet]` — TCP port checks against node-exporter (9100) on Gateway VPS, sn-infra, sn-web,
  sn-monitor, sn-security, hot-bm-nl — mirrors the exact target list already proven reachable in
  Prometheus's scrape config, nothing new fabricated

**Real bug hit and fixed mid-setup:** Grafana and Webmail both initially came back `down`/`pending`
— not a real outage. Both sit behind Keycloak SSO (Grafana via its own OAuth client, Webmail via
the shared oauth2-proxy — see CLAUDE.md's SSO section), and Uptime Kuma's HTTP check follows
redirects by default (`maxredirects: 10`). Followed all the way to Keycloak's federated broker
login step (`.../broker/house-of-trae/login?session_code=...`), which returns `400` for a
cookie-less, session-less automated client — same class of issue as the documented multi-hop
broker-redirect gotcha under Keycloak SSO in CLAUDE.md. Fixed by setting `maxredirects: 0` on
just these two monitors (so the check stops at the first real `302` from the app itself, already
covered by widening `accepted_statuscodes` to include `300-399`) rather than treating a stalled
login-flow probe as a real health signal. Verified live: both flipped to healthy within one check
cycle after the fix. No other internal service needed this — they either serve their own login
page directly at `200` (PowerDNS-Admin, Wazuh, Vaultwarden) or don't force a redirect at all.

**Admin credential saved to Vaultwarden 2026-07-30** as "sn-monitor — Uptime Kuma admin" in the
"House of Trae — Gateway VPS" folder, matching the existing "sn-monitor — Grafana admin" naming
convention. Standard one-off pattern: Mr. Byrne shared a `bw unlock --raw` session token directly,
vault unlocked/synced, item created and verified (folder ID, username, password all confirmed
matching the local `/opt/stacks/monitoring/secrets/uptimekuma_admin_creds.txt` copy), vault locked
and session discarded immediately after the single write. That local file remains as a
non-authoritative secondary record (not consumed by the container, Kuma has no env-based
initial-admin path).

**How to apply:** if Uptime Kuma (or any other Socket.io-only app with no REST API) ever needs
scripted setup again, this same pattern works — `docker exec <container> node <script>` using the
app's own bundled `socket.io-client`, reading the real server-side socket handlers
(`grep -n 'socket.on(' server/server.js`) rather than guessing event names/payload shapes.
