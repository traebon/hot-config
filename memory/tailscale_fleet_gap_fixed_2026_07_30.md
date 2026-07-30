---
name: tailscale-fleet-gap-fixed-2026-07-30
description: "Tailscale was never installed on any of the 4 hot-bm-nl rebuilt VMs (sn-infra/sn-web/sn-monitor/sn-security) — fixed 2026-07-30, new IPs, CLAUDE.md updated"
metadata: 
  node_type: memory
  type: project
  originSessionId: f361f2af-99b4-4220-ba53-a42472c872f0
  modified: 2026-07-30T10:59:14.126Z
---

Mr. Byrne asked to get Tailscale "back on servers" 2026-07-30. Investigation found this wasn't a
connectivity blip — **Tailscale had never been installed at all** on any of the 4 VMs rebuilt on
hot-bm-nl (sn-infra/sn-web/sn-monitor/sn-security, rebuilt 2026-07-27). The "offline, 29d ago"
entries showing in `tailscale status` were stale registrations from the *original decommissioned
bare-metal VMs* (confirmed via the Tailscale API: `lastSeen` on all 4 was `2026-07-01T08:49`,
matching the original NIC-failure outage almost exactly) — nobody had re-joined the new VMs to the
tailnet during the rebuild. Root cause: **the New VM Clone Checklist in CLAUDE.md never included a
Tailscale step** — fixed, added as item 11.

**Fixed 2026-07-30:** generated a short-lived (1h), reusable, pre-authorized auth key via the
Tailscale API (`/opt/stacks/tailscale-api/secrets/tailscale_api_key.txt`, see [[tailscale_api_key]])
— `devicesApprovalOn` is `false` tailnet-wide so no manual admin-console approval step was needed.
Installed + joined all 4 via `curl -fsSL https://tailscale.com/install.sh | sh` + `tailscale up
--authkey=... --hostname=<name> --accept-dns=false`. All 4 initially registered with a `-1` suffix
(`sn-infra-1` etc.) due to the naming collision with the stale dead entries — deleted the 4 stale
devices via `DELETE /api/v2/device/<id>`, then renamed the new ones back to clean hostnames via
`POST /api/v2/device/<id>/name` (note: `tailscale set --hostname=` on the device itself did **not**
actually rename it in the admin console/MagicDNS — the API rename endpoint was the one that
actually worked). Auth key revoked immediately after (`DELETE /api/v2/tailnet/-/keys/<id>`) rather
than left to expire naturally. Verified real reachability, not just registration, via `tailscale
ping` to all 4 — got real pongs routed over the underlying wg4→hot-bm-nl→VLAN path.

**New Tailscale IPs (CLAUDE.md updated, all tables):**
- sn-infra: `100.99.183.4` → **`100.99.52.12`**
- sn-web: `100.77.95.127` → **`100.91.130.53`**
- sn-monitor: `100.122.98.79` → **`100.109.177.48`**
- sn-security: `100.112.71.39` → **`100.118.146.83`**

**Also cleaned up, same session, after Mr. Byrne confirmed:** `sn-business` (`100.83.114.127`),
`sn-personal` (`100.118.105.9`), `pn-test` (`100.64.178.97`) were the exact same class of stale/dead
entry (same 2026-07-01 lastSeen, same decommissioned original bare-metal VMs). Deleted via the
Tailscale API — matches the SSH alias cleanup already done the same day, see
[[fleet_health_check_2026_07_30]]. CLAUDE.md's Tailscale overlay list and Quick Reference table both
updated to remove these 3 rows entirely (not just annotated as stale). No stale Tailscale entries
remain anywhere in the tailnet as of 2026-07-30.

**How to apply for any future VM rebuild/clone:** Tailscale is now item 11 in the New VM Clone
Checklist — don't let this gap recur. If a hostname was previously used by now-dead hardware,
delete the stale device via the API *before* joining the new one, or it'll register with a `-1`
suffix that needs a manual rename afterward.
