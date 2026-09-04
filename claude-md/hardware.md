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
| 100 | sn-infra    | 1     | 3 GB | 250 GB | VLAN 10 / 10.10.10.100 | Forgejo, PowerDNS-Admin, Namevault, hot-wiki (Ntfy moved to Gateway VPS 2026-08-03) |
| 102 | sn-web      | 2     | 2 GB | 250 GB | VLAN 30 / 10.10.30.102 | Client sites (6 sites)                    |
| 104 | sn-monitor  | 1     | 3 GB | 250 GB | VLAN 50 / 10.10.50.104 | Prometheus, Grafana (+Postgres), Loki, Uptime Kuma |
| 106 | sn-security | 2     | 8 GB | 250 GB | VLAN 70 / 10.10.70.106 | Wazuh SIEM 4.14.5 (single-node) — deliberately NOT right-sized, see note below |
|     | **TOTAL**   | **6** |**16 GB**|**1 TB nominal (thin-provisioned)**| | sn-web (4→2GB), sn-infra (4→3GB), and sn-monitor (4→3GB) all right-sized 2026-09-04 (see Hard Limits note below) — real container footprints were ~150MB/~864MB/~957MB respectively, all leave real headroom. sn-monitor's cut was verified against its already-observed balloon floor (Proxmox had already been squeezing it to exactly 3072MB), not just an estimate. sn-security deliberately left untouched — real usage confirms it needs its full 8GB, see below. Historical 2026-07-30 baseline: `local-zfs` pool 3.58 TB, 393 GB allocated, 3.19 TB free — figures below are more current. |

### ⚠️ Hard Limits — Do Not Exceed Without Approval
- **RAM:** 20 GB allocated vs 32 GB physical. Host observed at 25/31 GB used (guest RSS + overhead) with 6.3 GB available and only 1.1 GB swap in use as of 2026-07-30 — comfortable but check headroom before adding another RAM-heavy VM. **⚠ By 2026-08-08 this had degraded to 29/31 GB used, 1.6 GB available, 4.7 GB swap** — root cause was an uncapped ZFS ARC (`zfs_arc_max=0`, i.e. unbounded up to `c_max`≈32.5 GB) that had grown to 13.7 GB, directly competing with guest RAM. **Fixed same day: `zfs_arc_max` capped at 8 GB**, both live (`echo 8589934592 > /sys/module/zfs/parameters/zfs_arc_max`, took effect immediately — ARC dropped 13.7 GB → 8.0 GB with no restart) and persisted via `/etc/modprobe.d/zfs.conf` (`options zfs zfs_arc_max=8589934592`) + `update-initramfs -u -k all` so it survives a reboot too. Available memory recovered to 6.4 GB immediately after. Not tracked in git (host-level modprobe config, not an app/compose file) — this note is the record. If host memory pressure resurfaces, check `grep -E '^size|^c_max' /proc/spl/kstat/zfs/arcstats` before assuming it's guest growth — ARC is a recurring, easy-to-miss culprit on ZFS hosts. **Same root cause also explains a second symptom found the same day: all 4 guest VMs showed recurring `node_memory_MemTotal_bytes` oscillation (Proxmox's KVM balloon driver squeezing each VM's visible RAM as the host ran low on free memory) — confirmed via Prometheus history, and confirmed stopped (flat `MemTotal` for 3+ hours) immediately after the ARC cap. If any single VM's memory graph on Grafana looks erratic, check `node_memory_MemTotal_bytes` for that instance before assuming an app-level leak — ballooning silently moves the denominator on any "% used" calculation. Full trace: `sms_alert_storm_investigation_2026_08_08` memory.

**⚠ Renewed pressure found 2026-09-04, different cause from 08-08's regression — structural, not a bug.** All 4 VMs were actively balloon-squeezed below their configured max and doing real (if modest) guest-level swapping (sn-security highest at 42% of its swap in use, down to sn-web at 6%). ARC was confirmed still correctly pinned at its 8 GB cap (not a repeat of the unbounded-ARC regression) — the renewed pressure is simple arithmetic: 8 GB ARC + the 4 VMs' combined configured RAM (was 4+4+4+8=20 GB) leaves only ~3 GB of slack on this 31 GB host, and that slack has been consumed now that ARC has organically grown to fill its full cap under real workload (it hadn't yet back at the 07-30/08-08 baselines, which is why more headroom looked available then). Host was stable, not actively degrading further, when checked (settled into this state shortly after all 4 VMs were hard-power-cycled back up during the `reboot_watchdog_proxmox_failure_outage_2026_09_02` incident) — but real enough to plausibly have contributed to the same night's Grafana SQLite lock storm (see `automated-patching.md`'s Grafana Alerting section).

**Fixed for sn-web same day, Mr. Byrne's call**: real usage there is tiny (6 static `nginx:alpine` sites + node-exporter/promtail/watchtower, ~150 MB combined container footprint) against a 4 GB configured max — dropped to 2 GB (`qm set 102 --memory 2048`, `balloon: 2048` already matched so ballooning is now a no-op here). `memory:` is a boot-time QEMU parameter — takes effect only after a VM restart, not live; applied via a graceful `qm reboot 102` (qemu-guest-agent-driven, ~3 min real downtime on all 6 sites, all 9 containers came back clean via `restart: always`, no orphaned `docker-proxy` this time since it was a real reboot not a hard power-cycle). **Real, separate gotcha hit during that reboot, self-resolved, worth remembering**: the one Node/Express container (`stratus-digital`, the client-portal app — see `services-fleet.md`) took ~3-4 minutes to actually start listening on its port after the container itself showed "Up" — confirmed via `wchan` it was genuinely I/O-bound (`do_epoll_wait` → `__ext4_find_entry`, near-zero CPU time consumed) resolving `jose`'s many small ESM module files against a cold post-reboot page cache, not crashed or hung — cleared on its own with no intervention. The other 5 plain-nginx sites (trivial filesystem footprint) came back instantly. **If a Node/Express app on this fleet is slow to respond right after a VM reboot, check `wchan`/CPU time via `/proc/<pid>/wchan` before assuming a crash** — a genuinely-running-but-I/O-bound cold start looks identical to "stuck" from `docker ps` alone. Confirmed real host-wide benefit post-fix: available host memory improved 3.2 GB → 4.4 GB immediately. sn-web's own guest memory also improved (1.1 GB → 1.3 GB available, swap use dropped to 0).

**sn-infra right-sized the same day, 4 GB → 3 GB (not 2 GB like sn-web)** — real container usage there is meaningfully higher (~864 MB: Forgejo + PowerDNS-Admin + hot-wiki + 3 Postgres DBs + Namevault), so a smaller, more conservative cut was used rather than mechanically repeating sn-web's number — same methodology (measure real usage, size with real margin), different result because the workload is genuinely different. Same `qm set --memory` + `qm reboot` pattern. **Same slow-cold-start pattern repeated on reboot, same self-resolving non-issue**: Forgejo (Go binary, real DB-backed app) and hot-wiki (Wiki.js/Node) both took 1-4 minutes to actually start serving after `docker ps` showed "Up" — confirmed each was genuinely progressing (real DB migration/connection logs advancing, not stuck) rather than restarted blind. `pdns-admin`/Namevault (`namegen-app`) came back near-instantly, matching the pattern that apps with real dependency trees (Forgejo's Go modules, Wiki.js's Node stack, `jose`'s many small files on sn-web) are the ones affected by cold post-reboot disk cache, not simple/static services. Confirmed benefit: sn-infra's own swap use dropped 287 MB → 51 MB; host-wide available memory improved further, 4.4 GB → 5.4 GB.

**sn-security deliberately NOT right-sized** — checked first, and the numbers argue against it: real container usage is already ~3.9 GB steady-state (Wazuh manager 2.17 GB + indexer 1.42 GB + dashboard 205 MB), it's already the most swap-pressured VM in the fleet (42% of its swap in use) despite having several GB "available," and the existing hard limit two sections up ("Wazuh needs 8 GB RAM... reducing below 6 GB causes OOM and indexer crash-loops") is a real, previously-hit failure mode, not theoretical. Its current `balloon: 7168` floor is already close to that minimum — cutting further risks reproducing the exact crash-loop this note already warns about. Left at 8 GB.

**sn-monitor right-sized the same day too, 4 GB → 3 GB, closing out the last flagged VM.** Real
container usage there was ~957 MB (Grafana itself the heaviest single consumer at ~397 MB after
its Postgres migration, followed by Uptime Kuma/Loki/Prometheus/`grafana-db`) — but unlike
sn-infra's cut, this one had direct empirical evidence backing it: Proxmox's own balloon manager
had *already* been squeezing this VM down to exactly 3072 MB before the change (`balloon: 3072`),
meaning the fleet had already been running stably at that level, not just estimated as safe from
container totals. Same `qm set --memory` + `qm reboot` pattern; all 9 containers came back clean,
Grafana included — briefly showed the same false-alarm "stuck" pattern as previous reboots
(SQL-poller errors from the *old* container's shutdown mixed into the new one's boot log, real
progress confirmed via advancing plugin-load/status-registration lines, not actually hung) before
serving `200` within about a minute. **Real confirmation this survives a reboot cleanly**: all 6
alert rules, both contact points, and both datasources were still present and correct after the
restart — first live proof the Postgres backend (not SQLite) persists Grafana's state across a
guest reboot the way it's supposed to. Loki's `/ready` briefly 503'd immediately after boot
(`"Ingester not ready: waiting for 15s after being ready"`) — confirmed cosmetic via its own logs
(real WAL recovery, real log flushing from Forgejo/Caddy) and the labels API returning real data,
not a functional problem. Confirmed benefit: sn-monitor's own swap use dropped to 0; host-wide
available memory improved further, 5.4 GB → 6.0 GB — a **3.2 GB → 6.0 GB** total recovery across
sn-web + sn-infra + sn-monitor from where this investigation started.

See `fleet_memory_ballooning_2026_09_04` memory for the full trace of all four VMs (three cuts, one
deliberate no-op).
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

