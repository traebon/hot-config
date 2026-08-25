## Hardware — Bare Metal (AMD EPYC 3151) — ⚠️ DECOMMISSIONED, table kept for historical reference

**This physical host is permanently gone** (unfixable NIC fault, refunded — see
hostkey_server_replacement memory) and has been replaced by **hot-bm-nl**, a Hostkey NL
oVirt VPS with real specs of **8 vCore (Intel Xeon E5-2680 v2, 1 socket × 8 cores × 1
thread, confirmed via `lscpu`/`nproc` on the host — corrected 2026-07-28, previously
misdocumented here as 4 vCore) / 32 GB RAM / 2×4 TB HDD** (one disk as ext4/LVM
root, the other as a standalone `local-zfs` pool — see the VLAN topology note above for
why it's a VPS, not colocated hardware). Do not size new workloads against the table
below — it describes hardware that no longer exists. The Zen 1/AVX-512 warning below is
also now moot on the replacement (hot-bm-nl's CPU is a generic virtualized Intel core,
not Zen 1) but may still matter if HoT ever colocates real hardware again.

| Parameter       | Value                                        |
|-----------------|----------------------------------------------|
| CPU             | AMD EPYC 3151 — 4 cores / 8 threads          |
| Clock           | 2.7 GHz base / 3.0 GHz boost                 |
| Architecture    | Zen 1 — NO AVX-512                           |
| RAM             | 32 GB DDR4 ECC total                         |
| Storage         | 2×8 TB HDD — ZFS mirror (rpool) ~8 TB usable |
| ZFS             | lz4 compression, weekly scrub                |
| Usable for VMs  | ~28 GB RAM / ~8 TB disk                      |

### ⚠️ EPYC 3151 Zen 1 CPU Warning
- NO AVX-512 support — always use cpuv1 image tags where required
- Known affected: MinIO (used by Notesnook) — must use cpuv1 tag
- Before suggesting any new container image, verify it does not require AVX-512

---

## Hardware — VM Allocation (COMMITTED RESOURCES)

Only 4 of the original 7 VM roles were ever rebuilt on hot-bm-nl (see Network Topology above) —
**101/sn-business, 103/sn-personal, and 105/pn-test do not exist on this host.** sn-business's role
moved permanently to hot-erp/hot-pn; sn-personal and pn-test are both retired outright (Mr. Byrne's
decisions, sn-personal 2026-08-09, pn-test 2026-08-03) — no rebuild for either, ever.
Their SSH aliases were removed 2026-07-30 (see SSH Access table above) after a fleet health check
confirmed they were dead ends. Do not plan capacity against the old 7-VM/11-vCPU/40GB figures below —
they're historical.

| VM  | Name        | vCPUs | RAM  | Disk   | VLAN / IP              | Primary Services                          |
|-----|-------------|-------|------|--------|------------------------|-------------------------------------------|
| 100 | sn-infra    | 1     | 4 GB | 250 GB | VLAN 10 / 10.10.10.100 | Forgejo, PowerDNS-Admin, Namevault (Ntfy moved to Gateway VPS 2026-08-03) |
| 102 | sn-web      | 2     | 4 GB | 250 GB | VLAN 30 / 10.10.30.102 | Client sites (6 sites)                    |
| 104 | sn-monitor  | 1     | 4 GB | 250 GB | VLAN 50 / 10.10.50.104 | Prometheus, Grafana, Loki, Uptime Kuma    |
| 106 | sn-security | 2     | 8 GB | 250 GB | VLAN 70 / 10.10.70.106 | Wazuh SIEM 4.14.5 (single-node)          |
|     | **TOTAL**   | **6** |**20 GB**|**1 TB nominal (thin-provisioned)**| | Confirmed live 2026-07-30 (`zpool list`/`zfs list` on hot-bm-nl): `local-zfs` pool 3.58 TB, only 393 GB actually allocated, 3.19 TB free. Combined guest RSS ~15.4 GB (sn-security 7.7GB, sn-monitor 3.5GB, sn-infra 2.1GB, sn-web 2.1GB) — host sits at 25/31 GB used, normal for KVM (guest RAM shows as host process RSS), not a leak. |

### ⚠️ Hard Limits — Do Not Exceed Without Approval
- **RAM:** 20 GB allocated vs 32 GB physical. Host observed at 25/31 GB used (guest RSS + overhead) with 6.3 GB available and only 1.1 GB swap in use as of 2026-07-30 — comfortable but check headroom before adding another RAM-heavy VM. **⚠ By 2026-08-08 this had degraded to 29/31 GB used, 1.6 GB available, 4.7 GB swap** — root cause was an uncapped ZFS ARC (`zfs_arc_max=0`, i.e. unbounded up to `c_max`≈32.5 GB) that had grown to 13.7 GB, directly competing with guest RAM. **Fixed same day: `zfs_arc_max` capped at 8 GB**, both live (`echo 8589934592 > /sys/module/zfs/parameters/zfs_arc_max`, took effect immediately — ARC dropped 13.7 GB → 8.0 GB with no restart) and persisted via `/etc/modprobe.d/zfs.conf` (`options zfs zfs_arc_max=8589934592`) + `update-initramfs -u -k all` so it survives a reboot too. Available memory recovered to 6.4 GB immediately after. Not tracked in git (host-level modprobe config, not an app/compose file) — this note is the record. If host memory pressure resurfaces, check `grep -E '^size|^c_max' /proc/spl/kstat/zfs/arcstats` before assuming it's guest growth — ARC is a recurring, easy-to-miss culprit on ZFS hosts. **Same root cause also explains a second symptom found the same day: all 4 guest VMs showed recurring `node_memory_MemTotal_bytes` oscillation (Proxmox's KVM balloon driver squeezing each VM's visible RAM as the host ran low on free memory) — confirmed via Prometheus history, and confirmed stopped (flat `MemTotal` for 3+ hours) immediately after the ARC cap. If any single VM's memory graph on Grafana looks erratic, check `node_memory_MemTotal_bytes` for that instance before assuming an app-level leak — ballooning silently moves the denominator on any "% used" calculation. Full trace: `sms_alert_storm_investigation_2026_08_08` memory.
- **vCPU:** 6 vCPUs across 8 physical threads (sn-security pinned at cores=2 permanently — see sn-security section below) — 2 threads of headroom, flag further additions.
- **Disk:** `local-zfs` ZFS pool — 3.58 TB total, 393 GB actually allocated (thin-provisioned; each VM's 250 GB disk is a nominal size cap, not pre-reserved space), 3.19 TB free as of 2026-07-30 — snapshots + backups consume this too.
- With only 4 VMs now on hot-bm-nl (vs. the original 7-VM plan), there's substantially more RAM/vCPU/disk headroom than the historical figures above imply — worth factoring in before assuming a new workload needs to go elsewhere.

### `nginx-certbot` container on the hot-bm-nl host itself — RESOLVED 2026-08-25, left in place, documented as permanent
Found 2026-08-19 by `fleet-judgment-review`'s first run: a container running directly on hot-bm-nl
(not inside one of its 4 VMs), never fleet-discovery-pushed or documented anywhere. A real
`jonasal/nginx-certbot:latest` container (`nginx-nginx-1`), `network_mode: host`, reverse-proxying
HTTPS on 443 to the local Proxmox UI (`proxy_pass https://127.0.0.1:8006`) under the hostname
`proxmox22272.hostkey.in` with a real, auto-renewing Let's Encrypt cert
(`CERTBOT_EMAIL=hkadm@hostkey.com`).

**Investigated further 2026-08-25, Mr. Byrne's call: leave it, document as permanent, do not
contact Hostkey.** Assessed as Hostkey's own provisioning/support tooling for this oVirt VPS, not
built by House of Trae or any prior Claude Code session — strong circumstantial evidence, not a
direct Hostkey confirmation (deliberately not sought, per Mr. Byrne):
- Created **2026-07-23 03:03**, four days before this project's own 2026-07-27 hot-bm-nl rebuild —
  nothing House of Trae did could have created it.
- `CERTBOT_EMAIL=hkadm@hostkey.com` — registered against Hostkey's own domain, not ours.
- `/root/.ssh/authorized_keys` on hot-bm-nl holds exactly two keys: this project's own
  `gateway-claude-code`, and one nobody here added — an RSA key labeled
  `root@proxmox22272.hostkey.in` (the box's own hostname, not a client machine — consistent with a
  provider-baked support-access key, not something House of Trae generated). **Left untouched** —
  not rotated or removed, since revoking an unconfirmed provider support key without asking them
  risks locking out legitimate access for no verified benefit. Login history (`last -a`) only goes
  back to this project's own 2026-07-27 access, so actual use of that key by Hostkey couldn't be
  directly confirmed either way — its mere presence, pre-dating our control of the box, is the
  evidence.

**Not a security exposure regardless of origin**: confirmed `ufw status verbose` shows `Default:
deny (incoming)` with no `443` allow rule, and a real external connection attempt to hot-bm-nl's
public IP (`31.207.47.146:443`) timed out. Host-networking containers bypass Docker's own NAT
(unlike the `-p`-published-port case in the hot-pn section, where Docker's iptables rules are known
to bypass UFW) but not UFW's own INPUT chain — correctly firewalled off from the public internet.
Even if reached, it only forwards to Proxmox's own login-gated UI.

Real gap this exposed, still open: `fleet-health-sweep`'s stacks-inventory check only covers each
VM's `/opt/stacks/`, never hot-bm-nl's own root-level Docker containers — this had zero chance of
being caught by the deterministic nightly sweep (Option A), only by D1's judgment pass noticing it
in the Discovery queue's raw candidate list. Worth considering as a future `fleet-health-sweep`
scope addition if this pattern recurs.

---

## Hardware — Gateway VPS

| Parameter | Value                                             |
|-----------|---------------------------------------------------|
| CPU       | 4 vCPU                                            |
| RAM       | 8 GB                                              |
| Disk      | 120 GB NVMe                                       |
| Public IP | 151.241.217.91                                    |
| Role      | Edge ONLY — Caddy, DNS, Mail, WireGuard, CrowdSec |

### ⚠️ VPS Resource Warning
- 8 GB RAM shared across: Caddy, PowerDNS, Unbound, Docker Mailserver, Roundcube, CrowdSec, WireGuard, Keycloak, Vaultwarden
- Keycloak alone uses ~512 MB–1 GB at idle
- VPS = edge/proxy only — never deploy databases, media, or ERPNext here
- **Exception: Vaultwarden.** Deliberately placed on the Gateway VPS (not a bare-metal VM) specifically so credentials stay reachable during a bare-metal/Proxmox outage — proven necessary during the Jul 2026 NIC/PCIe outage (ticket CS-471548), when every VM behind the bare metal host was unreachable but the Gateway VPS itself stayed up. Its bundled SQLite backend (128 MB mem_limit) is an accepted trade-off for this availability guarantee. Do not "fix" this by relocating it to a VM without recognizing the trade-off you'd be reintroducing.

---

## Hardware Decision Rules

1. Adding a new service to an existing VM → check RAM headroom first
2. Suggesting a new VM → confirm bare metal has RAM and disk capacity
3. Any image without explicit version tag → verify Zen 1 / cpuv1 compatibility
4. Disk-heavy services → sn-personal or sn-business only
5. Monitoring/logging growth → watch sn-monitor disk (Loki retention policy)
6. Never deploy databases or media services on the Gateway VPS (Vaultwarden is the one deliberate exception — see VPS Resource Warning above)

---

