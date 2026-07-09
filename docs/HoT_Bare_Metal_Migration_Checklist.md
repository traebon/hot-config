# Bare-Metal Migration Checklist — Hostkey Server Replacement

Status: **Pending — Hostkey has offered replacement configs, still negotiating** (last update 2026-07-09, see [[hostkey_server_replacement]] memory)
Trigger: recurring Intel I350 NIC PCIe link-loss fault on the AMD EPYC 3151 host could not be fixed with a NIC swap (no matching inventory) — Hostkey is doing a full server replacement instead.
Assumption: **worst case is now effectively confirmed — a brand new machine, existing ZFS mirror disks do NOT move over.** On 2026-07-08 Hostkey offered two configs (bm.v2-promo: EPYC 3151/32GB/1TB NVMe; bm.v2-medium: i9-9900K/64GB/1TB NVMe) — both are a different disk technology (NVMe, 1TB) from the current 2x8TB HDD ZFS mirror, which rules out a disk transplant regardless of which config is picked. Both offers were pushed back on 2026-07-09 over the disk-capacity gap (~8TB usable today vs ~1.09TB already in use, before snapshots/backups) and a downtime-credit request — awaiting reply. Phase 2 (VM restore from backup) should be planned for now rather than treated as a fallback.

---

## Phase 0 — Do now, before Hostkey schedules anything

These don't depend on the new hardware and reduce risk regardless of how the migration actually goes.

- [ ] **Close the Proxmox VM config gap.** Only `vm-105-pn-test.conf` and `vm-106-sn-security.conf` are captured in `/opt/hot-config/proxmox/`. VMs 100–104 (sn-infra, sn-business, sn-web, sn-personal, sn-monitor) have no text config backup anywhere in git. Once the WireGuard tunnel to bare metal is back (even briefly), pull `/etc/pve/qemu-server/{100,101,102,103,104}.conf` into `/opt/hot-config/proxmox/` and commit. This is the single highest-value prep item — without it, rebuilding VM definitions from scratch means re-deriving vCPU/RAM/disk/VLAN tag/MAC address from CLAUDE.md's tables by hand.
- [ ] **Fix `sync.sh`'s all-or-nothing push.** `set -euo pipefail` means a single failed remote (origin/Forgejo, which lives behind the same tunnel that's currently down) aborts the codeberg/github pushes too — this happened on 2026-07-03 and was caught/fixed manually. Reorder to push external mirrors (codeberg, github) before origin, or wrap each push so one failure doesn't block the others. Otherwise every night the tunnel is down, config history silently stops reaching the offsite mirrors.
- [ ] **Verify current backup health once Proxmox is reachable again:**
  - `zpool status rpool` — confirm no degraded state, note last scrub date
  - Confirm the 2026-07-03 vzdump actually ran (Gateway's own backup push to `proxmox:/var/lib/vz/dump/gateway` failed that day due to the outage — check whether Proxmox's own vzdump cron for the 7 VMs also failed, or just the Gateway's push into it)
  - Confirm rclone crypt pushes to Hetzner Storage Box and B2 are current (rclone isn't on the Gateway — it runs from Proxmox — so this can only be checked once reachable)
- [ ] **Export/save independently (not just in the ZFS pool):**
  - Tang/Clevis key slot bindings per VM (slot 2 → sn-infra, slot 3 → Gateway) — the binding metadata lives in each VM's LUKS header, which *will* be lost in a full rebuild; document the bind procedure (already in CLAUDE.md's "NBDE unlock chain" row) so it's a known 3-step repeat, not a re-discovery
  - Keycloak realm export (in addition to the daily Postgres dump already running) — a full realm JSON export is easier to sanity-check post-restore than a raw DB dump
  - PowerDNS zone data — confirm the nightly PowerDNS Postgres dump (part of the Gateway backup) covers all 13 zones listed in CLAUDE.md

## Phase 1 — When Hostkey gives a timeline

- [ ] Get written confirmation from Hostkey: **do the ZFS disks move, or is this a from-scratch machine?** This single answer determines whether Phase 2 is "import pool + fix networking" (hours) or "restore 7 VMs from backup" (likely 1-2 days). Update this doc's assumption once known.
- [ ] Get the new machine's spec sheet before cutover — specifically **confirm it's not another Zen 1 (no-AVX-512) gotcha in reverse**: if it's a *newer* CPU, no problem, but re-verify the cpuv1 image-tag workarounds (MinIO/Notesnook) are still needed or can be dropped.
- [ ] Schedule the cutover window with awareness of the backup cron chain (01:00 config sync → 02:00 vzdump → 06:00 Hetzner → 07:30 B2) — don't cut over mid-window.
- [ ] Notify anyone depending on client-facing services during the window (Dickson ERPNext, the 6 sn-web static sites, PrivateNexus test env on sn-personal) — Gateway VPS itself stays up throughout (it's not part of this migration), so only backend/VM-hosted services go dark, not DNS/mail/edge.

## Phase 2 — Rebuild (worst-case: from backup)

Per VM (100–106), in dependency order — bring up sn-infra first since Forgejo/DNS-admin and other VMs' config history depend on reaching it:

- [ ] Recreate VM shell from the saved `.conf` (Phase 0 gap-fill makes this copy-paste instead of manual re-entry): vCPU, RAM, disk size, `net0` bridge+VLAN tag, MAC address if it matters anywhere (static DHCP reservations, firewall rules keyed to MAC)
- [ ] Restore the VM disk from the most recent vzdump (or rclone crypt copy if vzdump itself was lost)
- [ ] Re-run the **New VM Clone Checklist** from CLAUDE.md for every VM, since a restore effectively is a clone:
  1. UFW input policy ACCEPT (template/restore may default to DROP)
  2. `/etc/resolv.conf` nameserver correct
  3. UFW rule: allow from `10.10.0.0/16`
  4. `qemu-guest-agent` installed + `agent: enabled=1` confirmed with `qm agent <id> ping`
  5. node-exporter + Promtail shipping to `10.10.50.104:3100`
  6. Add to Prometheus scrape targets (sn-monitor)
  7. Add to Uptime Kuma monitors
  8. Watchtower v1.5.3 (not v1.7.1 — API negotiation bug) on the VM
- [ ] Re-bind Tang/Clevis NBDE for LUKS unlock on every VM (3-step procedure documented in CLAUDE.md under "NBDE unlock chain") — this has to happen fresh regardless of disk-transplant vs rebuild, since it's tied to the VM's LUKS header
- [ ] Re-establish VLAN routing on the new host's `vmbr0` (10/20/30/40/50/60/70 → matching subnets)

## Phase 3 — Network re-point (Gateway side)

- [ ] Update `wg0.conf` `Endpoint` on the Gateway VPS to the new bare-metal public IP (currently `194.147.214.169`) — everything else in `wg0.conf` (internal 10.10.0.1/30 addressing, AllowedIPs for the VLAN subnets) stays the same as long as the new host keeps `10.10.0.2`
- [ ] `wg-quick down wg0 && wg-quick up wg0`, then confirm handshake: `wg show` should show a fresh handshake timestamp within seconds
- [ ] `ping 10.10.0.2` and each VM's `10.10.x0.10x` address to confirm routing before touching anything else
- [ ] Re-verify Tang reachability both directions: Gateway Tang (`10.10.0.1:7500`) reachable from new host's VMs at boot; sn-infra Tang (`10.10.10.100:80`) reachable as fallback
- [ ] No DNS changes needed — all public zone records point at the Gateway VPS's public IP (`151.241.217.91`), which doesn't change in this migration. Only the WireGuard endpoint IP is bare-metal-specific.

## Phase 4 — Post-migration verification

- [ ] Every VM reachable via its SSH alias (`ssh sn-infra`, etc.) and via Tailscale
- [ ] Forgejo (git.securenexus.net) reachable, then immediately: `cd /opt/hot-config && git push origin main` to catch up any commits stranded during the outage
- [ ] ERPNext (erp.dickson-supplies.com) — check gunicorn workers came up, not `bench serve`; watch for the `tabError Log` corruption symptom if the shutdown before migration was unclean
- [ ] All 6 sn-web static sites reachable through Caddy
- [ ] Grafana/Prometheus/Loki/Uptime Kuma on sn-monitor showing all targets green
- [ ] Wazuh dashboard on sn-security — check `wazuh_dashboard/wazuh.yml` API password wasn't reset to the placeholder by the restore process (known gotcha in CLAUDE.md)
- [ ] PrivateNexus test env on sn-personal reachable at privatenexus.net
- [ ] Run a full `zpool scrub rpool` once everything's stable, confirm clean
- [ ] Update this checklist's Phase 0 gap-fill items (100-104 configs) again post-migration so the *next* incident has current configs captured
