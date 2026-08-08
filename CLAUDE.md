# CLAUDE.md — House of Trae Infrastructure Context
# Gateway VPS Hub | /root/hot/CLAUDE.md
# Version: 2.0 | June 2026
# Always address the operator as Mr. Byrne.

---

## Identity & Role

You are JARVIS — the AI infrastructure co-pilot for House of Trae (HoT).
You are running on the Gateway VPS, which is the single control point for the entire stack.
From here you can SSH into every VM and the Proxmox host via pre-configured aliases.
All infrastructure decisions should respect the hardware limits, operational rules, and
architecture principles documented in this file.

Roadmap & full infrastructure state: /root/hot/docs/HoT_Infrastructure_State_Roadmap_v*.docx (use the highest version present)
(Canonical source: https://git.securenexus.net/house-of-trae/hot-infrastructure)

---

## Documentation Library

All reference documents are in /root/hot/docs/. Use docx2txt or pdftotext (both installed) to read them.

| File                                                    | Type  | Purpose                                                                         |
|---------------------------------------------------------|-------|---------------------------------------------------------------------------------|
| HoT_Infrastructure_State_Roadmap_v*.docx                | DOCX  | Master infrastructure state & roadmap — single source of truth (highest version) |
| HoT_Infrastructure_Architecture_Specification_v3.0.pdf  | PDF   | Architecture specification v3.0 — core pillars, platform layers                |
| HoT_Operations_Runbook.pdf                              | PDF   | Operations runbook — incident severity (P1–P3), recovery order, DR checklist   |
| PrivateNexus_Product_Specification.pdf                  | PDF   | PrivateNexus product spec — mission, MVP v1.0, v2–v4 scope                     |
| PrivateNexus_Build_Implementation_Guide_v1.0.docx       | DOCX  | PrivateNexus build guide v1.0 — phases, repo layout, security baseline         |
| PrivateNexus_Commercial_Product_Strategy.docx           | DOCX  | PrivateNexus commercial strategy — positioning, revenue ladder, GTM             |
| PrivateNexus_Phase0_Freeze.md                           | MD    | Phase 0 locked decisions — Node.js Express backend, stack freeze, v1.0 scope   |
| PrivateNexus_Release_Roadmap_v1.0.md                    | MD    | Detailed release roadmap v0.8 → v5.0 with sprints, acceptance gates, risks     |
| PrivateNexus_PRD_v1.0.md                                | MD    | Product Requirements Document — current build state, all functional reqs, gaps |
| PrivateNexus_Multitenancy_RBAC_Design.md                | MD    | Multi-tenancy and RBAC design — schema, isolation rules, migration path         |
| PrivateNexus_Security_Lockdown_Mode_Design.md            | MD    | Security lockdown mode design (v6.0 gate item) — tier model, Wazuh/CrowdSec integration, scoped+locked 2026-07-30, not yet built |
| PrivateNexus_Commercial_Packaging_Licensing.md          | MD    | Commercial packaging — edition model, pricing logic, open-core boundary, GTM   |
| dnssec-ds-records.md                                    | MD    | DNSSEC DS record reference for managed zones                                    |
| HoT_Bare_Metal_Migration_Checklist.md                   | MD    | Hostkey bare-metal server replacement — phased migration/rebuild checklist      |
| PrivateNexus_Security_Report_Tier4.md ... Tier19.md      | MD    | Progressive PrivateNexus security assessment series (Tiers 1-3 predate this archive) — infra exposure, RBAC, injection, deploy pipeline, dependency CVEs. All findings fixed; Tier 19 (25 Jun 2026) is the final/most recent tier. |

---

## Group Entities & Domains

| Entity              | Domain                   | Role                                              |
|---------------------|--------------------------|---------------------------------------------------|
| House of Trae       | house-of-trae.com        | Parent — shared services (SSO, mail, DNS)         |
| SecureNexus         | securenexus.net          | Cyber security, monitoring, infra management      |
| Byrne Accounts      | byrne-accounts.org       | Accounting services                               |
| Stratus Digital     | stratus-digital.com      | Web design & dev (formerly Cloud Architects)      |
| Discreet Elite      | discreet-elite.uk        | Private console application                       |
| Emerald Markets     | emerald-markets.net      | Second-hand ecommerce & in-person POS             |
| PrivateNexus        | privatenexus.net         | PrivateNexus prod/dev/build — all on hot-pn (see hot-pn section) |

---

## Network Topology

```
Internet
    │
    ▼
Gateway VPS — 151.241.217.91 (Hostkey B.V., Zürich)
    │  wg4 (ChaCha20-Poly1305)  10.10.3.1 → 10.10.3.2
    ▼
hot-bm-nl (Hostkey NL, server 22272, oVirt VPS — bare-metal replacement) — PVE 9.2.5
    │  VLAN routing via vmbr0 (VLAN-aware Linux bridge, no physical port — purely
    │  internal, matches the original architecture since these VLANs never touch
    │  the WAN; wg4 carries all Gateway↔VLAN traffic instead of a switch trunk)
    ├── VLAN 10 → sn-infra    (10.10.10.100) — rebuilt 2026-07-27 as VM 100 — LUKS2+Tang retrofit complete 2026-07-28
    ├── VLAN 30 → sn-web      (10.10.30.102) — rebuilt 2026-07-27 as VM 102 — LUKS2+Tang retrofit complete 2026-07-27 (pilot)
    ├── VLAN 50 → sn-monitor  (10.10.50.104) — rebuilt 2026-07-27 as VM 104 — LUKS2+Tang retrofit complete 2026-07-28
    └── VLAN 70 → sn-security (10.10.70.106) — rebuilt 2026-07-27 as VM 106 — LUKS2+Tang retrofit complete 2026-07-28 (cores=2 permanent, see sn-security section below)

    VLAN 20 (sn-business) and VLAN 40 (sn-personal) are NOT being rebuilt here — those
    roles permanently moved to hot-erp/hot-pn (see PERMANENT decision, 2026-07-24).
    VLAN 40 (sn-personal)'s own fate (retire vs. repurpose for Phase 4 "HoT Sync") is still open —
    see hostkey_server_replacement memory. VLAN 60 (pn-test) is settled: **retired outright, Mr.
    Byrne's decision 2026-08-03** — no rebuild planned, ever.

    ⚠ The ORIGINAL bare-metal host (AMD EPYC 3151, Switzerland DC, server 145990) is
    PERMANENTLY DECOMMISSIONED — unfixable NIC fault, refunded, replaced by hot-bm-nl.
    Its wg0 tunnel (10.10.0.1 → 10.10.0.2) was disabled 2026-07-24 (`wg-quick down` +
    `systemctl disable wg-quick@wg0`) after its stale routes for the VLAN subnets above
    blocked wg4 from claiming them — don't re-enable it, that server no longer exists.

Tailscale overlay (admin access ONLY — never production traffic):
    Gateway VPS:         100.106.41.10
    hot-bm-nl:           100.90.156.88 (added 2026-07-27 — Proxmox web UI access, port 8006 only, UFW-scoped to the tailscale0 interface)
    sn-infra:            100.99.52.12 (re-registered 2026-07-30 — Tailscale was never installed on the
                         hot-bm-nl rebuild of this VM at all; the VM Clone Checklist never included a
                         Tailscale step. New IP, replacing the stale/dead entry left over from the
                         original decommissioned bare-metal VM.)
    sn-web:              100.91.130.53 (re-registered 2026-07-30, same gap/fix as sn-infra above)
    sn-monitor:          100.109.177.48 (re-registered 2026-07-30, same gap/fix as sn-infra above)
    sn-security:         100.118.146.83 (re-registered 2026-07-30, same gap/fix as sn-infra above)
    Ubuntu workstation:  100.116.130.37
    Windows (latitude):  100.106.225.126
    Windows (traebake):  100.127.229.35
    Tailscale suffix:    spangled-atlas.ts.net

**Removed 2026-07-30**: `sn-business` (100.83.114.127), `sn-personal` (100.118.105.9), `pn-test`
(100.64.178.97) — same class of stale dead entry as the sn-infra/sn-web/sn-monitor/sn-security ones
above (all last seen 2026-07-01, the original decommissioned bare-metal VMs), removed via the
Tailscale API once Mr. Byrne confirmed. Matches the SSH alias cleanup done the same day — see
Network Topology above and the SSH Access table for why these VLANs aren't coming back as-is.

Other WireGuard interfaces on the Gateway VPS (separate from the wg0 bare-metal tunnel above):
    wg1 — Mr. Byrne's personal road-warrior VPN. 10.10.90.0/24 (Gateway 10.10.90.1), port 51821.
          Client configs: phone/windows/laptop.conf in /root/hot/wireguard-clients/. Predates this
          doc; discovered 2026-07-06 when a new tunnel was almost given the same interface name —
          check `wg show` before reusing wg<N>/ports on this box.
    wg2 — **REMOVED 2026-08-03.** Was the tunnel to the OLD hot-erp box (Hostinger,
          46.202.129.86, formerly named erp-temp), superseded 2026-08-01 when ERPNext's real
          permanent home became hot-erp-nl over `wg5` (see below). Kept running-but-idle as a
          safety net until Mr. Byrne confirmed the Hostinger account was set to close — confirmed
          2026-08-03, so the tunnel was torn down (`wg-quick down wg2` + `systemctl disable
          wg-quick@wg2`) and the account is being cancelled. Old addressing for reference only:
          Gateway 10.10.1.1 / old hot-erp 10.10.1.2, port 51822. See
          hot_erp_hostkey_ch_migration_scope memory for the migration and the hot-erp section
          below.
    wg3 — tunnel to hot-pn (151.241.217.140, formerly named pn-vps — renamed 2026-07-24, ssh alias
          `pn-vps` still works as a transitional alias), PrivateNexus's permanent home (Mr. Byrne's personal
          use + PrivateNexus product development; ERPNext/erp-temp is earmarked for hosting client
          companies' backend software later — not started, no timeline). Originally stood up as a
          bare-metal-outage stand-in for pn-test/sn-personal; **made permanent 2026-07-24** for the
          same reason as wg2 above. Gateway 10.10.2.1 / pn-vps 10.10.2.2, port 51823. See
          hostkey_server_replacement memory and the pn-vps section below.
    wg4 — tunnel to hot-bm-nl (server 22272, Hostkey NL, 31.207.47.146) — the bare-metal
          *replacement* candidate itself (server 145990 was decommissioned; NL not CH, see
          hostkey_server_replacement memory), NOT a temporary stand-in like wg2/wg3. Gateway
          10.10.3.1 / hot-bm-nl 10.10.3.2 (interface name wg0 on that host), port 51824. Enabled
          via systemd on both ends. No services live behind it yet — fleet migration architecture
          (Proxmox install? VLAN routing rebuild?) not yet decided, see
          HoT_Bare_Metal_Migration_Checklist.md when that work starts.
    wg5 — tunnel to hot-erp-nl (server 41614, Hostkey NL, 151.243.173.46) — ERPNext's new
          permanent home as of the 2026-08-01 migration off Hostinger, see the hot-erp section
          below and hot_erp_hostkey_ch_migration_scope memory. Gateway 10.10.4.1 / hot-erp-nl
          10.10.4.2 (interface name wg0 on that host), port 51825. Enabled via systemd on both
          ends.

**Key rule:** Production traffic never routes through Tailscale. Tailscale = admin SSH only.
**Key rule:** Bare metal has zero public-facing ports. All public traffic enters via the Gateway VPS.
**Key rule:** Before creating a new WireGuard interface on the Gateway VPS, run `wg show` first — wg1 (personal VPN) is easy to collide with by guessing sequential names.

---

## SSH Access — VM Aliases

All VMs are reachable directly from this Gateway via SSH aliases.
SSH key: /root/.ssh/claude_code_key
SSH config: /root/.ssh/config

| Alias       | IP             | VLAN |
|-------------|----------------|------|
| sn-infra    | 10.10.10.100   | 10   |
| sn-web      | 10.10.30.102   | 30   |
| sn-monitor  | 10.10.50.104   | 50   |
| sn-security | 10.10.70.106   | 70   |

**Removed 2026-07-30** (confirmed dead-end via full fleet health check, see fleet_health_check_2026_07_30 memory): `proxmox` (10.10.0.2), `sn-business` (10.10.20.101), `sn-personal` (10.10.40.103), `pn-test` (10.10.60.105) — all routed to VLANs/hosts that only existed behind the old wg0 tunnel to the permanently decommissioned original bare-metal host (EPYC 3151, server 145990). sn-business/sn-personal's roles moved permanently to hot-erp/hot-pn; pn-test is retired outright (Mr. Byrne's decision, 2026-08-03) and will not be revived — see Network Topology above and hostkey_server_replacement memory. sn-personal's own VLAN fate (retire vs. repurpose) remains separately open.

---

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
**101/sn-business, 103/sn-personal, and 105/pn-test do not exist on this host.** sn-business and
sn-personal's roles moved permanently to hot-erp/hot-pn (sn-personal's own VLAN fate is still
separately open); pn-test is retired outright, Mr. Byrne's decision 2026-08-03 — no rebuild, ever.
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

## Service Locations

All services use plain Docker Compose at /opt/stacks/<service>/
All VMs run as root.

### Gateway VPS (this machine — 151.241.217.91)
| Service           | Path                    | Notes                                                 |
|-------------------|-------------------------|-------------------------------------------------------|
| Caddy             | /opt/stacks/caddy/      | Caddyfile here — reload: docker compose restart caddy |
| PowerDNS          | /opt/stacks/powerdns/   | compose.yml (not docker-compose.yml)                  |
| Unbound           | /opt/stacks/unbound/    | Recursive resolver                                    |
| Keycloak          | /opt/stacks/keycloak/   | auth.house-of-trae.com                                |
| Docker Mailserver | /opt/stacks/mailserver/ | mail.house-of-trae.com                                |
| Roundcube         | /opt/stacks/roundcube/  | webmail.house-of-trae.com                             |
| CrowdSec          | /opt/stacks/crowdsec/   | LAPI mode + Caddy native bouncer module (caddy-cs-bouncer) |
| Tor               | /opt/stacks/tor/        | v3 hidden service for erp.dickson-supplies.com        |
| Tang              | systemd (tangd.socket)  | NBDE unlock for ALL 7 VMs — 10.10.0.1:7500 (WireGuard only, NOT Docker) |
| Vaultwarden       | /opt/stacks/vaultwarden/ | vault.house-of-trae.com — deliberately on the Gateway VPS, not a VM, so secrets stay reachable if bare metal goes down. `ADMIN_TOKEN_FILE` docker secret (pre-hashed argon2id PHC string, not plaintext). |
| Ntfy              | /opt/stacks/ntfy/       | ntfy.house-of-trae.com — moved here 2026-08-03 from sn-infra (was a single point of failure with the exact fleet it's meant to alert about being down — see Network Topology/sn-infra section). Reuses the container that's been running on the Gateway since 2026-07-02 (Ntfy's original deployment, never actually torn down after an earlier documented "move" to sn-infra) — CrowdSec's alert plugin had been quietly using it the whole time regardless of what Caddy's public vhost pointed at. The SMS relay (Node.js sms-relay — see Alerting Architecture and the Gateway VPS service table below) was rebuilt on the Gateway itself 2026-08-03/04, closing out the single-point-of-failure concern that used to apply when it lived on sn-infra. |
| Gatus             | /opt/stacks/gatus/      | Independent uptime monitor, port 8080 (internal only, no public vhost). Deliberately on the Gateway, not sn-monitor — sn-monitor (Grafana/Prometheus/Uptime Kuma) lives on hot-bm-nl, so it can't alert on its own host's death; Gatus exists specifically to catch that blind spot. 12 endpoints (Gateway-local services + the hot-bm-nl-hosted public services: Forgejo/Grafana/Wazuh/ERPNext). Alerts via email only (`notifications@house-of-trae.com`) — deliberately not Ntfy/SMS: true at the time this was built (both lived on sn-infra, part of the same failure domain), and still true for SMS (its relay is still on sn-infra), but Ntfy itself moved to the Gateway later the same day (see the sn-infra section above) — email remains the right choice here regardless, since it doesn't depend on Ntfy either. Was undocumented here for 9+ days until found+fixed 2026-08-03 (see gatus_alerting_gap memory) — had been correctly detecting the hot-bm-nl outage the whole time but had zero alerting providers configured, which is why nobody was told. Password secret lives only at `/opt/stacks/gatus/secrets/gatus.env` (`chmod 600`), never in the git-tracked `hot-config` copy. Its Grafana check was separately broken (checking the wrong path, root redirects rather than 200) — found+fixed during the same-day outage recovery, see the hot_bm_nl_outage memory. |
| sn-infra recovery watchdog | systemd (`sn-infra-recovery-check.timer`) | Not a container — a local systemd timer + script (`/usr/local/bin/sn-infra-recovery-check.sh`, tracked in `hot-config/gateway/scripts/`), added 2026-08-03 during the hot-bm-nl outage. Checks every 15 min whether sn-infra is reachable (fresh wg4 handshake + real SSH), emails a one-time notification via the same SMTP path as Gatus when it detects a down→up transition. Deliberately local, not a `/schedule` cloud agent — cloud sandboxes have no access to wg4/SSH/Tailscale. Served its purpose once already (2026-08-03 recovery); harmless to leave running for any future recurrence. See gatus_alerting_gap and hot_bm_nl_outage memories. |
| sms-relay | /opt/stacks/sms-relay/  | Rebuilt from scratch here 2026-08-03, fully functional as of 2026-08-04 (see sms_relay_migration_scope memory) — the original, documented as living on sn-infra, turned out to be completely gone (no container, no systemd unit, nothing on disk) since at least the 2026-07-27 sn-infra rebuild, which never redeployed it. Small Node.js service, no framework, subscribes directly to Ntfy's `hot-alerts` topic (anonymous read already granted there) and forwards only `priority=5`/"urgent" messages to Twilio SMS — CrowdSec's own ban notifications (`priority=high`/4) are correctly excluded. Rate-limited to 1 SMS per alert-group per 5 min, matching the documented Alerting Architecture limit — grouped by Grafana's own `groupKey` for Grafana-shaped payloads (added 2026-08-04, see Grafana Alerting section), message title otherwise. Real Twilio credentials wired in 2026-08-04 (`/opt/stacks/sms-relay/secrets/`); `SMS_FROM_NUMBER=+447403942795` (Twilio's own hosted number) / `SMS_TO_NUMBER=+447771724186` (Mr. Byrne's real mobile) — Twilio rejects identical To/From (error 21266), hit and fixed live, see user_contact memory. Verified with a real SMS sent and confirmed received. **Now has a real live publisher**: Grafana's 3 CRITICAL-severity alert rules (Node Down/Disk >95%/TLS cert <7d), wired 2026-08-04 — previously nothing published to Ntfy at priority=5 at all except manual tests. Tracked in `hot-config/gateway/sms-relay/` (secrets excluded, per the `**/secrets/` gitignore rule) — unlike its predecessor, this one won't silently vanish on a future rebuild. |

### sn-infra (ssh sn-infra — 10.10.10.100)
| Service        | Path                    | URL                           | Port |
|----------------|-------------------------|-------------------------------|------|
| Forgejo        | /opt/stacks/forgejo/    | git.securenexus.net           | 3000 |
| PowerDNS-Admin | /opt/stacks/pdns-admin/ | dns-admin.house-of-trae.com   | 9191 |
| Namevault      | /opt/stacks/namegen/    | namevault.co.uk               | 8010 |

**Ntfy moved to the Gateway VPS 2026-08-03** (see Gateway VPS service table below) — no longer
here. Was documented as living here, but during the 2026-08-03 hot-bm-nl outage, discovered its
public vhost (`10.10.10.100:8080`) had gone down along with the rest of this VM. Adopted a Gateway-
local `ntfy` container that had actually been running since 2026-07-02 (Ntfy's original deployment,
before an earlier "move to sn-infra" that apparently never fully decommissioned it) rather than
build fresh — confirmed it wasn't just an idle leftover: CrowdSec's own alert plugin
(`gateway/crowdsec/notifications/http.yaml`) had been posting real ban notifications to it via
`http://ntfy:80/hot-alerts` the whole time, using a still-valid bearer token, verified live.

### sn-business (ssh sn-business — 10.10.20.101)
| Service     | Path                 | URL                      | Port |
|-------------|----------------------|--------------------------|------|
| ERPNext v16 | /opt/stacks/dickson/ | erp.dickson-supplies.com | 8000 |

Stack: custom image (`/opt/stacks/dickson/docker/Dockerfile`) — `frappe/erpnext:v16` + posawesome. Services: `dickson-backend` (gunicorn), `dickson-db` (MariaDB 10.6), redis-cache, redis-queue, socketio, worker, scheduler. Secrets in `/opt/stacks/dickson/secrets/*.txt` — must be `chmod 644` (frappe UID 1000). Site DB name: `_ae77c090ad3ef28b`.

### sn-web (ssh sn-web — 10.10.30.102)
| Service          | Path                        | URL                  | Port |
|------------------|-----------------------------|----------------------|------|
| Stratus Digital  | /opt/stacks/stratus-digital/| stratus-digital.com  | 8001 |
| Discreet Elite   | /opt/stacks/discreet-elite/ | discreet-elite.uk    | 8002 |
| Emerald Markets  | /opt/stacks/emerald-markets/| emerald-markets.net  | 8003 |
| Ruby Osiris      | /opt/stacks/ruby/           | rubyosiris.com       | 8004 |
| Evil Rabbit Art  | /opt/stacks/evilrabbit/     | evilrabbitart.com    | 8005 |
| Dickson Supplies | /opt/stacks/dicksonweb/     | dickson-supplies.com | 8006 |

All 6 are nginx:alpine + static "Coming Soon" pages, reverse-proxied via Caddy (root + www).

### sn-personal — ⚠️ HISTORICAL, this VM does not currently exist
**Not rebuilt on hot-bm-nl** (VLAN 40 excluded — see Network Topology above) and its SSH alias
(`sn-personal`, 10.10.40.103) was removed 2026-07-30 as a dead end (fleet health check). The table
below describes what this VM ran **before** the original bare-metal host was decommissioned —
kept for historical reference only, not current state. `privatenexus.net` is **not** served from
here anymore; it's permanently routed to hot-pn (`10.10.2.2:5173`, see the hot-pn section below).
Cosmos (and the personal services it ran — Vaultwarden, Immich, Firefly III, Actual Budget,
Nextcloud, Notesnook) was fully removed in Jun 2026, data was never populated so no loss. **VLAN
40/sn-personal's fate is still an open decision** — Mr. Byrne has tentatively floated repurposing
it for the Phase 4 "HoT Sync" roadmap item, but wanted to scope that separately, not bundle it into
the fleet rebuild. See `hostkey_server_replacement` memory. Don't confuse this with pn-test
(VLAN 60), which Mr. Byrne confirmed 2026-08-03 is retired outright, not just historical.

| Service (historical, pre-outage) | Path                       | URL                 | Port |
|-----------------------------------|----------------------------|---------------------|------|
| PrivateNexus (former test env)    | /opt/privatenexus/compose/ | privatenexus.net    | 5173 |

### sn-monitor (ssh sn-monitor — 10.10.50.104)
| Service     | Path                    | URL                       | Port |
|-------------|-------------------------|---------------------------|------|
| Monitoring  | /opt/stacks/monitoring/ | grafana.house-of-trae.com | —    |
| Prometheus  | (inside monitoring)     | internal only             | 9090 |
| Loki        | (inside monitoring)     | 10.10.50.104:3100         | 3100 |
| Uptime Kuma | (inside monitoring)     | status.house-of-trae.com  | —    |

status.house-of-trae.com — slug `hot-status`, exposes only the 6 group entity sites. Admin at monitor.securenexus.net:3001.
Grafana admin password: reset via `grafana cli admin reset-admin-password` — GF_SECURITY_ADMIN_PASSWORD only applies on first init.
node-exporter UFW gotcha: Prometheus runs in bridge network 172.18.0.0/16 — UFW must allow that subnet to port 9100.

### pn-test — ⚠️ RETIRED (Mr. Byrne's decision, 2026-08-03)
Formerly VLAN 60 (10.10.60.105) — hosted PrivateNexus dev/build (local source builds) and was
earmarked for personal services alongside sn-personal, back when the original bare-metal host was
live. Its SSH alias was removed 2026-07-30 as a dead end; **confirmed retired outright, not just
undecided, 2026-08-03** — its only real purpose (PrivateNexus dev/build) is fully redundant now
that PrivateNexus's permanent home is hot-pn (which combines the old pn-test dev role and the old
sn-personal test role). No rebuild planned, no VLAN 60, no VM 105. See `hostkey_server_replacement`
memory for the full history.

**Phase 0 freeze (locked 22 June 2026):** Backend = Node.js Express v4 (ESM). Frontend = React. DB = PostgreSQL 16. Cache/queue = Redis. Identity = Keycloak (privatenexus realm). Gateway = Caddy. Do not suggest Go or NestJS as a rewrite — the codebase is at v1.9 and this decision is closed. See `/root/hot/docs/PrivateNexus_Phase0_Freeze.md` for full rationale and checklist.

### sn-security (ssh sn-security — 10.10.70.106)
VM: **2 vCPU** (permanently capped below the originally-planned 4 — see note below) / 8 GB RAM / 250 GB / VLAN 70. LUKS2 encrypted root (Clevis Tang → Gateway VPS preferred, sn-infra fallback). Dashboard: wazuh.house-of-trae.com

**⚠ Pinned at `cores=2`, not 4 — permanent, by Mr. Byrne's decision (2026-07-28), not a temporary workaround.** hot-bm-nl hangs at guest SMP bring-up whenever a VM is configured with more than 2 vCPUs — confirmed via a disposable test VM to be independent of CPU model (`host`/`kvm64`), core/socket topology, x2apic, HPET, and ACPI settings, and independent of whether the guest kernel actually starts the extra CPUs (`maxcpus=` doesn't help) — it fires purely from QEMU/ACPI declaring >2 CPUs exist. Most likely a real limitation of hot-bm-nl's double-nested virtualization depth (Hostkey's own hypervisor → hot-bm-nl as their VM → Proxmox/KVM inside that → this VM), not something fixable via Proxmox config or kernel boot parameters. Real-world impact checked and found negligible at current load: sn-security idles at 0.06–0.21 load average on its 2 cores even with the full Wazuh stack running. Full investigation, every ruled-out variable, and the diagnostic method: `sn_web_luks_pilot_fix.md` in memory. Don't re-investigate from scratch if this resurfaces on a future VM.

| Service        | Path                        | Notes                                                     |
|----------------|-----------------------------|------------------------------------------------------------|
| Wazuh SIEM     | /opt/stacks/wazuh/          | wazuh.house-of-trae.com — manager + indexer + dashboard   |
| Forgejo Runner | /opt/stacks/forgejo-runner/ | CI/CD runner for git.securenexus.net                      |

Wazuh creds (saved in Vaultwarden, "House of Trae — Gateway VPS" folder):
- Dashboard/admin login: `admin` / `bRSsn8P2v1YIbemCHejpEb6l`
- Wazuh API (wazuh-wui): `mHB2UhhMw0wTc3q8@22vJeOvr`
- OpenSearch kibanaserver: `h2huT1B1TrUXQg8Wri5FqhdP`

---

### hot-erp (ssh hot-erp-nl — Hostkey NL, server 41614, public VPS, not a Proxmox VM) — PERMANENT
**Migrated 2026-08-01 from Hostinger (46.202.129.86, the original `hot-erp`/`erp-temp` box, item 26
in [[open_items_2026_07_27]]) to a fresh Hostkey NL `vm.v2-nano` (2 vCPU / 4 GB RAM / 60 GB NVMe,
$7.74/mo).** CH was found to be blocked for new `vm.v2-*` orders at migration time (confirmed live
against the invapi — `vm.v2-nano`/`-mini`/`-medium` all rejected for CH even though hot-pn's
existing `vm.v2-medium` CH rental keeps renewing fine), so this landed in NL instead, same region
as hot-bm-nl — see [[hot_erp_hostkey_ch_migration_scope]] for the full ordering investigation.
Reached from the Gateway VPS over the dedicated `wg5` tunnel (10.10.4.1 ↔ 10.10.4.2, port 51825).
Public SSH closed (UFW deny-by-default, matching the hot-pn pattern) — admin access is tunnel-only.
The old Hostinger box had been retained running as a safety net, no longer receiving traffic.
**Mr. Byrne confirmed 2026-08-03 the Hostinger account is set to close** — the now-redundant `wg2`
tunnel to it was torn down the same day (`wg-quick down wg2` + `systemctl disable wg-quick@wg2`,
see Network Topology above), and its `hot-erp`/`erp-temp` SSH aliases were removed from
`/root/.ssh/config` the same day. The account itself is in the process of being cancelled on
Hostinger's side.

Data migration: real DB (`mysqldump` of the site's own DB user, not a full-instance dump — the
MariaDB root password on the old box had drifted from what's in its own secrets file, a real,
still-unresolved discrepancy worth investigating separately) + `sites-data`/`assets-data` volume
rsync while the old box stayed live, re-synced immediately before cutover to minimize staleness.
Verified via matching table/row counts (747 tables, 35 Items, 6 Users, identical on both boxes) and
a real `frappe.db.count` query post-migration, not just a file-copy assumption.

**Original 2026-07-06/07-09 history (Hostinger box, now superseded but kept for context):** stood
up as a stand-in for sn-business's ERPNext while the original bare-metal host was down (see
[[hostkey_server_replacement]]); historical data restored 2026-07-09 from the 2026-06-29 Hetzner
vzdump backup (see [[rclone_crypt_password_vaultwarden]]); made ERPNext's permanent home (off bare
metal entirely, deliberately, same reasoning as the Vaultwarden Gateway placement) 2026-07-24.
Earmarked later (no timeline) to also host client companies' backend software — not started.

| Service     | Path                | Notes                                                          |
|-------------|---------------------|------------------------------------------------------------------|
| ERPNext v16 | /opt/stacks/dickson/ | erp.dickson-supplies.com (Caddy repointed to `10.10.4.2:8000` 2026-08-01). Config synced to `/opt/hot-config/hot-erp/dickson/` (README there has full rebuild notes/gotchas — reconstructed Dockerfile, posawesome source, several one-time setup steps never captured in docker-compose.yml originally; still accurate post-migration since the volume/DB content was migrated as-is, not rebuilt from scratch). |

Caddy's `erp.dickson-supplies.com` block (and the Tor onion mirror block) both point at
`10.10.4.2:8000` as of the 2026-08-01 cutover — verified live via a real public HTTPS request
(`frappe.ping` → `pong`) and a local Host-header test against the onion block's site key itself
(`Host: <onion-address>`, not the public domain — the two are separate Caddy site blocks and using
the wrong Host header silently hits the other one), confirmed `200`/`pong`.

**Re-checked 2026-08-03, correcting a prior mischaracterization:** a direct SOCKS5 request through
the Gateway's own local Tor proxy (`127.0.0.1:9050`) to the onion address fails with `curl: (97)`,
and the Tor daemon's own logs show why: `"Fail to decrypt descriptor for requested onion address.
It is likely requiring client authorization."` This was previously logged as the test being
"uncompletable — egress-restricted, not a config problem" — that diagnosis was wrong. The request
genuinely reaches Tor and gets a real protocol-level response; it fails only because this session
doesn't hold the client-auth private key (`authorized_clients/tristian.auth` is pubkey-only, see
the Tor Hidden Services section above) — the service is correctly refusing to decrypt its
descriptor for an unauthorized client, which is the access-control feature working as designed, not
a sandbox/network limitation. Separately, the Tor daemon itself is confirmed healthy: bootstrapped
100%, 15-23 circuits open continuously, and its heartbeat logs show real `INTRODUCE2` cells being
received periodically — i.e., genuine inbound requests are reaching the hidden service from the
live Tor network.

**Not yet done, follow-up needed:** investigate why the old box's MariaDB root password no longer
matched its own secrets file (worked around via the site's own DB user, not blocking, and likely
moot now the box is being decommissioned). Root password + wg5 keys were already saved to
Vaultwarden 2026-08-01 ("hot-erp-nl root password (Hostkey NL VPS)" / "hot-erp-nl wg5 WireGuard
tunnel keys", House of Trae — Gateway VPS folder) — verified still present 2026-08-03. Hostinger
account cancellation confirmed by Mr. Byrne 2026-08-03 — see the note above and Network Topology's
wg2 entry.

---

### hot-pn (ssh hot-pn — 151.241.217.140, Hostkey CH, public VPS, not a Proxmox VM) — PERMANENT
**Renamed from pn-vps 2026-07-24** (the `pn-vps` ssh alias still works, kept as a transitional
alias — see hostkey_server_replacement memory). Stood up 2026-07-15 as a stand-in for PrivateNexus's dev (pn-test) and test (sn-personal) roles
combined while bare metal is down (see [[hostkey_server_replacement]]). **Made PrivateNexus's
permanent home 2026-07-24** (Mr. Byrne decision) rather than migrated back once hot-bm-nl is
ready — deliberately kept off bare metal so a future Proxmox/bare-metal outage doesn't take
PrivateNexus down with it, same reasoning as the Vaultwarden Gateway placement. PrivateNexus here
serves both Mr. Byrne's personal use and ongoing PrivateNexus product development. Ordered via the Hostkey
`invapi.hostkey.com` billing API — see [[hostkey_invapi_notes]] for the auth/order quirks
discovered along the way. `vm.v2-medium` preset — 8 vCPU / 16 GB RAM / 160 GB NVMe, Ubuntu 26.04
LTS (upgraded from the 24.04 base image via a Hostkey panel reinstall — neither `do-release-upgrade`
nor the invapi API could drive this server, a real gap: `eq/list`/`eq/show` never recognized this
server's ID (4683) under this account's API key, even after payment and provisioning completed).
Reached from the Gateway VPS over the dedicated `wg3` tunnel (10.10.2.1 ↔ 10.10.2.2) — see Network
Topology. UFW locked down (deny-by-default; only SSH, the wg3 port, and 5173/tcp scoped to
10.10.2.1 are open). Claude Code (native install) is also set up on this box for direct use there.

| Service      | Path               | Notes                                                                 |
|--------------|--------------------|-----------------------------------------------------------------------|
| PrivateNexus | /opt/privatenexus/ | privatenexus.net (Caddy repointed here) — full stack built and deployed from `origin/main`. Reuses the existing Keycloak `privatenexus` client secret unchanged. `PROXMOX_URL`/`PROXMOX_TOKEN` won't work until bare metal is reachable — expected, not a bug. `PDNS_API_KEY` is live and working (PowerDNS reachability fixed 2026-07-15 — Gateway UFW rule, wg0 AllowedIPs widened to `10.10.2.1/32, 10.10.0.1/32`, and a manual route add after `wg syncconf`, which doesn't install kernel routes on its own — see Operational Rules). |
| Monitoring (temp) | /opt/stacks/monitoring-temp/ | Local Prometheus + node-exporter + Loki + Promtail stand-in (added 2026-07-15), `compose_pn-internal` only, no host ports published. Loki `/ready` returns a cosmetic 503 (known single-node quirk, still ingests correctly) — don't "fix" this into a broken HTTP health check. Permanent now that pn-vps is PrivateNexus's home. |
| Watchtower | /opt/stacks/watchtower/ | Pinned v1.5.3, monitor-only. PrivateNexus's 3 locally-built services carry `com.centurylinklabs.watchtower.enable=false` (no registry to check). Has a real bearer-token-gated metrics health check (`WATCHTOWER_HTTP_API_METRICS=true`, deliberately not `_UPDATE`) — `services.health_endpoint` uses `tcp://watchtower:8080` since the schema can't carry the token for an HTTP check. Token in Vaultwarden ("pn-vps Watchtower HTTP API token"). |
| Discovery agent | /opt/privatenexus/scripts/discovery-agent.sh | `privatenexus-discovery-agent.timer` (systemd, boot + hourly) pushes host + container facts to `POST /api/discovery/ingest`, authenticating with a real rotated DB token (`agent_tokens`, `600`-permission secret file) — not the bootstrap fallback. |

**Current governance state (as of the 2026-07-16/24 audit sessions):** all 15 registered services
(the original 11 pn-vps containers + 4 mapped external dependencies — Keycloak, PowerDNS API, Caddy
Admin API, Proxmox) sit at **0 governance violations**, all 11 pn-vps-native services at
**`recoverable` tier, avg readiness 94/100**, with real (not fabricated) backups, dependency edges,
and restore tests behind every one of those numbers. `privatenexus-db` has a genuine daily pg_dump
chain (pn-vps → Gateway pull → hetzner-crypt/b2-hot-crypt) verified via a real scratch-container
restore test; the 10 stateless containers are backed by their tracked git config (real, verified
GitHub commit URLs — Codeberg mirrors are NOT reliably checkable, don't assume otherwise). Caddy Admin
API and Proxmox correctly show as unreachable/exempted for real, documented reasons (`admin off` in
the Caddyfile; the CS-471548 bare-metal outage), not bugs.

**Recurring bug pattern worth remembering for future audits of this app:** whenever a rule has an
exception mechanism (`policy_exceptions`), every UI surface displaying that rule's data must
independently consult the exception table — this was missed in three separate places in one session
(Inventory badges, Service Detail, and even a secondary table *inside* the Governance board itself),
because only the one route computing violations was checking it. Also worth remembering: two
separate large-scale audits this app went through (`recordAudit()` coverage, and `try/catch`
coverage — the latter found a real all-request-crash risk in `discovery.js`'s automated hourly
ingest path) each found gaps by literally counting route-handler occurrences against
audit/error-handling call counts per file, then reading only the mismatches. **Full blow-by-blow
audit history (every bug found/fixed, commit hashes, verification steps) for 2026-07-15, -16, and
-24 sessions:** `/root/hot/docs/PrivateNexus_pn_vps_Audit_Log_Archive.md`.

Caddy's `privatenexus.net` block points at `10.10.2.2:5173` — this is now the permanent target,
not `10.10.40.103:5173` (see the pn-vps PERMANENT decision above, 2026-07-24); the inline Caddyfile
comment was updated 2026-08-02 to say so directly (was previously stale "TEMPORARY... revert"
language left over from the original bare-metal-outage stand-in). The frontend container's port publish was changed from `127.0.0.1:5173:80` (in the source
repo, unreachable from another host) to `10.10.2.2:5173:80` (bound to the tunnel interface
specifically) — binding to `0.0.0.0` was deliberately avoided since Docker's own iptables rules are
known to bypass UFW's filtering for published ports; binding to the specific tunnel IP means
Docker's NAT rule itself never matches traffic to the public IP, which is more robust than relying
on UFW alone.

Root password and the wg3 keypair are saved in Vaultwarden under the **PrivateNexus** folder
("hot-pn root password (Hostkey CH VPS)" and "hot-pn wg3 WireGuard tunnel keys" — renamed from the
`pn-vps` prefix 2026-07-24). A separate SSH keypair (`tristian-termius-pn-vps`, alias not renamed)
was also generated for Mr. Byrne's direct Termius access, scoped only to this VPS (not the shared
fleet `claude_code_key`) — its private key is backed up in the same Vaultwarden folder ("hot-pn
Termius SSH key (tristian)").

**⚠ Real production regression caused and fixed same-session, 2026-07-24: PowerDNS API went
unreachable from the whole VLAN mesh after `wg0` (the old, permanently-dead bare-metal tunnel) was
torn down during the hot-bm-nl vmbr0 build (see hostkey_server_replacement memory).** PowerDNS's
docker-compose port binding is a specific-IP bind, `10.10.0.1:8081` (not `0.0.0.0`) — and
`10.10.0.1` was literally the Gateway's own address *on the wg0 interface itself*. Deleting wg0
deleted that address from existence; `docker-proxy` kept reporting itself as `LISTEN` on it
(phantom bind — process alive, but nothing could route to an address that no longer exists on any
interface). Caught only because Mr. Byrne was doing real hands-on UI testing and saw PowerDNS API
show as down on the Dashboard. Fixed non-destructively: added `10.10.0.1/32` to `lo` (loopback) via
a new systemd oneshot unit (`/etc/systemd/system/powerdns-loopback-ip.service`, `Before=docker.service`,
enabled) rather than reviving wg0 or changing PowerDNS's bind config. Verified end-to-end
(Gateway-local curl, then from hot-pn over wg3). **If `10.10.0.1` ever needs to move again, it's now
a plain loopback alias, not tied to any WireGuard interface's lifecycle — check `ip addr show dev
lo` before assuming it's gone.**

---

## Keycloak SSO

URL: https://auth.house-of-trae.com
Backend: Gateway VPS — PostgreSQL backend

| Realm           | Used By                                                      |
|-----------------|--------------------------------------------------------------|
| securenexus     | Grafana, Forgejo, PowerDNS-Admin, HoT staff                  |
| personal        | Vaultwarden, Nextcloud, Immich, Notesnook (tresemme.space)   |
| byrne-accounts  | Byrne Accounts staff                                         |
| stratus-digital | Stratus Digital staff                                        |
| discreet-elite  | Discreet Elite users                                         |
| emerald-markets | Emerald Markets users                                        |
| clients         | Client portal users                                          |
| house-of-trae   | House of Trae parent — master identity-provider-redirector broker |
| master          | Keycloak's own built-in admin realm (not app-facing)         |
| privatenexus    | PrivateNexus app users (prod/dev/test, all on hot-pn)        |

10 realms total. All realms: MFA enforced, brute force detection, strong password policy.
Keycloak OIDC API URL must point to realm root: `.../realms/<realm-name>` (NOT the protocol endpoint — causes 500 errors).

**WebAuthn/passkey policy (rolled out 2026-07-02, verified 2026-07-04 via admin API against all 10 realms):**
- 2FA WebAuthn policy: `rpId=house-of-trae.com`, signature algorithm `ES256`, `userVerification=preferred`
- Passwordless policy: same `rpId`/`ES256`, `userVerification=required`, `requireResidentKey=required`, `authenticatorAttachment=platform` (passkey-grade — platform authenticator + resident key forces a real synced/hardware passkey, not just any FIDO2 token)
- Required actions `webauthn-register` and `webauthn-register-passwordless` enabled (not default) on every realm — so users can register a passkey from their account console, but aren't force-enrolled
- Config is identical across all 10 realms including `master` — confirmed via `admin/realms/<realm>` and `admin/realms/<realm>/authentication/required-actions` REST calls, not just inferred from the commit message

**`privatenexus` realm — MFA actually enforced for privileged roles (2026-07-23):** the `webauthn-register` required action above is *optional* realm-wide (users can enroll, aren't forced to) — this was flagged as PRD gap AUTH-07 since it meant `admin`/`superadmin`/`breakglass` could log into PrivateNexus with password only. **Two separate flows had to be fixed, not one** — this realm's `house-of-trae` identity provider link (federated broker login) is a completely different code path from local username/password, and most real users (including tristian, whose `privatenexus` account is broker-linked to `house-of-trae`) never touch the local form at all. Fixing only the local flow (first attempt) left the actual login path most people use completely unenforced.
- **Local path:** duplicated `browser` → `browser - privileged MFA` (bound as this realm's `browserFlow`), added 3 role-gated conditional sub-flows under `forms` (password → `Force MFA - superadmin`/`-breakglass`/`-admin`, each `Condition - user role` + `OTP Form` REQUIRED), excluded those roles from the pre-existing optional-2FA fallback via negated role conditions to avoid a double OTP prompt.
- **Broker path:** built `privatenexus post-broker MFA` (same 3 role-gated sub-flows) and bound it as the `house-of-trae` IdP's `postBrokerLoginFlowAlias` (**not** `firstBrokerLoginFlowAlias` — that one only fires once, at initial account linking, never again). **Gotcha hit here:** a post-broker flow made only of conditional sub-flows throws `AuthenticationFlowException` ("Invalid username or password") when none match, since literally nothing in the flow executes — fixed by adding a REQUIRED `allow-access-authenticator` ("Allow access") as an explicit unconditional pass-through.

Verified end-to-end on both paths with disposable test accounts, including a real linked house-of-trae+privatenexus federated pair driven through the actual multi-hop broker redirect chain via curl (not just the local form): role assigned → `CONFIGURE_TOTP`; role removed → normal flow. All test accounts deleted after. Full detail: PRD `AUTH-07`. **If replicating this pattern on another realm: (1) built-in `browser`/`forms` flows can't be edited in place ("illegal to add sub-flow to a built in flow") — copy first, edit the copy, then rebind; (2) check whether users of that realm log in locally or via a broker link — a conditional-role MFA flow bound only to `browserFlow` silently does nothing for brokered users; (3) any post-broker (or similarly freestanding) flow built entirely from conditional sub-flows needs an unconditional `allow-access-authenticator` fallback or it fails outright for anyone matching none of the conditions.**

---

## PowerDNS

API port: 8081 (NOT 8053)
API key: pdnsKj7xM9pL2vR5n
Bound on: 10.10.0.1:8081 (WireGuard interface — reachable from bare metal)
Authoritative nameservers: ns1.house-of-trae.com / ns2.house-of-trae.com

Zones managed (confirmed live):
  house-of-trae.com, securenexus.net, byrne-accounts.org, stratus-digital.com,
  discreet-elite.uk, emerald-markets.net, privatenexus.net, tresemme.space,
  namevault.co.uk, dickson-supplies.com, evilrabbitart.com, rubyosiris.com,
  cloud-architects.online (legacy)

tresemme.space records — all → 151.241.217.91:
  apex (placeholder). This was pn-test's domain for personal services (Cosmos-era Nextcloud/
  Vaultwarden/Immich/etc., removed Jun 2026) — pn-test is now retired outright (2026-08-03), so no
  further subdomains are planned here unless a future personal-services plan (e.g. Phase 4 "HoT
  Sync", tentatively eyed for sn-personal instead) explicitly picks this domain back up.
  `pn`/`notes` subdomains are still live — plain Caddy redirects to real external services
  (privatenexus.net, app.notesnook.com respectively), never actually depended on pn-test, kept as-is.
  Removed from Caddy 2026-08-03 (DNS records not touched, harmless if still present): `sync`,
  `identity`, `sse`, `s3`, `monograph` — a leftover self-hosted Notesnook-stack cluster that had been
  reverse_proxy'ing to the dead pn-test VM (10.10.60.105) since it was decommissioned; found while
  auditing an unrelated CrowdSec scenario bug (real scan traffic against `monograph.tresemme.space`
  was being miscounted as Forgejo brute-force activity — see crowdsec_custom_scenarios_audit memory).
  Older "Removed" list below predates this session and was never reconciled against the live
  Caddyfile — it lists `notes`/`pn` as removed, but both are confirmed live today (verified via real
  redirect checks), so that list is stale for at least those two; left as-is rather than guess at
  the actual history.
  Previously noted as removed: nextcloud, vaultwarden, photos, notes, firefly, firefly-iii, actual, pn

house-of-trae.com — `_tailscale-challenge` TXT record added 2026-07-16 (Tailscale domain
verification, admin console "Add + verify domain" flow): `_tailscale-challenge.house-of-trae.com`
TXT `"v2=XK2oDuhegVHtA3SRM7bFE9CcKHsNBZxyB8GMKKf6Nwk3"`, TTL 3600. Added via the PowerDNS API
(PATCH .../zones/house-of-trae.com.), confirmed resolving publicly. Purely a proof-of-ownership
record for Tailscale's background verification — no service routing implication; safe to remove
once Tailscale confirms verification if it doesn't clean itself up.

---

## Email Infrastructure

Host: mail.house-of-trae.com | Webmail: webmail.house-of-trae.com
Stack: Docker Mailserver + Roundcube
Universal SMTP: notifications@house-of-trae.com | port 587 | STARTTLS

Email domains: @house-of-trae.com, @securenexus.net, @byrne-accounts.org,
               @stratus-digital.com, @discreet-elite.uk, @emerald-markets.net, @privatenexus.net

---

## Alerting Architecture (3 Channels)

| Severity | Triggers                                          | SMTP | Ntfy | SMS |
|----------|---------------------------------------------------|------|------|-----|
| CRITICAL | Service down, cert <7d, WireGuard down, disk >95% | ✓    | ✓    | ✓   |
| HIGH     | Cert <14d, target down >10 min, disk >85%         | ✓    | ✓    | —   |
| WARNING  | Memory >90%, backup failure, CrowdSec spike       | ✓    | ✓    | —   |
| INFO     | Backup completed, Watchtower update available     | —    | ✓    | —   |

SMS rate limit: max 1 SMS per alert group per 5 minutes.
SMS relay: **rebuilt on the Gateway VPS 2026-08-03, fully functional as of 2026-08-04** (see
Gateway VPS service table and sms_relay_migration_scope memory) — the original, documented as
living on sn-infra, was found to be completely gone (confirmed during the 2026-08-03 hot-bm-nl
outage recovery, not merely at risk from it — see hot_bm_nl_outage memory) since at least the
2026-07-27 sn-infra rebuild, which never redeployed it. Subscribes to Ntfy directly (`hot-alerts`
topic) rather than a per-publish webhook. Real Twilio credentials wired in 2026-08-04; a genuine
FROM/TO number mixup was found and fixed the same day (Twilio's only hosted number,
`+447403942795`, is the sender identity — Mr. Byrne's actual mobile is `+447771724186`, see
user_contact memory) — verified with a real SMS sent via Twilio's API and confirmed received on his
phone. `⚠ Worth auditing separately, not blocking`: whether Grafana/Wazuh actually publish at
Ntfy `priority=5` for genuinely CRITICAL events — the relay's trigger logic is proven correct end
to end, but no current publisher has been confirmed to use that priority yet.

---

## Backup Architecture

| Tier           | Tool                  | Schedule    | Destination             | Encryption                         |
|----------------|-----------------------|-------------|-------------------------|------------------------------------|
| VM snapshots   | vzdump (Proxmox)      | 02:00 daily | /var/lib/vz/dump (ZFS)  | zstd compressed                    |
| Config sync    | git + cron            | 01:00 daily | Forgejo → Codeberg + GH | Forgejo auth                       |
| Cloud (Hetzner)| rclone crypt          | 06:00 daily | Hetzner Storage Box     | rclone crypt (hetzner-crypt remote)|
| Cloud (B2)     | rclone crypt + B2     | 07:30 daily | Backblaze B2            | rclone crypt — hard_delete=true    |
| hot-pn PrivateNexus DB (formerly pn-vps) | pg_dump (hot-pn) + Gateway pull + rclone crypt | 03:00 hot-pn dump → 03:30 Gateway pull/push | Local (hot-pn, 14d) → Gateway (30d) → Hetzner + B2 | rclone crypt (same hetzner-crypt/b2-hot-crypt remotes) |

Cron: 01:00 config sync → 02:00 vzdump (~3h, done ~05:00) → 03:00 pn-vps DB dump → 03:30 Gateway pulls it → 06:00 Hetzner → 07:30 B2
⚠️ vzdump runs 3h on 7 VMs. Cloud uploads must NOT start before 06:00 — concurrent HDD I/O caused nightly crashes (Jun 26–28).
Config repo: /opt/hot-config → Forgejo (git.securenexus.net) + Codeberg + GitHub mirrors
Config repo: /opt/hot-config → Forgejo (git.securenexus.net) + Codeberg + GitHub mirrors

---

## Automated Patching (apt update && upgrade — deployed 2026-08-05)

Every host runs a daily systemd timer (`apt-daily-update.timer` / `apt-daily-check.timer`,
`OnCalendar=09:00`, `RandomizedDelaySec=10min` — deliberately outside the 01:00–07:30 backup
window above). Two variants:

| Variant | Hosts | Behavior |
|---------|-------|----------|
| Full auto-upgrade (`apt-daily-update.sh`) | Gateway, sn-infra, sn-web, sn-monitor, sn-security, hot-pn, hot-erp | `apt-get update && apt-get -y upgrade` daily, unattended. |
| Check-only, manual approval (`apt-daily-check.sh` + `apt-approve-upgrade`) | **hot-bm-nl only** | Lists upgradable packages via Ntfy, never applies. Run `apt-approve-upgrade` on hot-bm-nl by hand to review + apply — this host runs all 4 production VMs, so a bad `pve-kernel`/`qemu-server` bump or unattended reboot here would take the whole fleet down at once. |

**Reboot policy is per-host** (`/etc/apt-daily-update/auto_reboot`, Mr. Byrne's decision
2026-08-05): `false` (notify only, never reboot) on **Gateway** (single control point — WireGuard
hub, Tang server for all 7 VMs, DNS, mail) and **hot-bm-nl** (not on this variant at all — see
above). `true` (auto-reboot ~2 min after upgrading, if `/var/run/reboot-required` exists) on every
other host — sn-security included, since its LUKS2+Tang binding auto-unlocks on boot without any
manual step (see NBDE unlock chain in Operational Rules), so an unattended reboot there is safe.

Failures and reboot-required events notify via the same shared Ntfy token CrowdSec/Grafana already
use (`gateway/crowdsec/notifications/http.yaml`), at `priority=high` — below the `priority=5`
threshold that triggers SMS (see Alerting Architecture), so a routine patch failure doesn't page
Mr. Byrne's phone, just shows up in Ntfy/logs.

Verified live on first deploy: ran every script manually on every host before trusting the
unattended timer. hot-pn and hot-erp-nl both had a genuine pending kernel update and really
auto-rebooted during this verification — confirmed both came back up cleanly (docker active, all
containers healthy) before moving on. hot-bm-nl's check-only run correctly listed upgradable
packages (including `qemu-server` itself) without applying anything, exactly the scenario that
variant exists to gate. Full detail: `scripts/apt-daily-update-README.md` in `hot-config`.

### Reboot recovery watchdog (`reboot-recovery-watchdog.timer`, Gateway VPS, deployed 2026-08-05)

Built the same day, after hot-pn's auto-reboot above genuinely hung: WireGuard/ICMP/TCP:22 all
stayed healthy while sshd never responded, and it took 27+ minutes of manual checking plus a
Hostkey hard-stop+power-on (same fix as the 2026-08-03 hot-bm-nl outage, CS-510977) before it
recovered. This watchdog automates that detection-and-recovery sequence going forward, for every
host that can auto-reboot (`sn-infra`, `sn-web`, `sn-monitor`, `sn-security`, `hot-pn`, `hot-erp`
— not Gateway/hot-bm-nl, which never auto-reboot in the first place).

Runs every 5 min via systemd timer, checks reachability with a real SSH command (not ping/TCP —
those stayed healthy the whole time during the hot-pn incident and would not have caught it).
Per-host state tracked in `/var/lib/reboot-watchdog/`. Escalation, mirroring what actually worked
for hot-bm-nl and hot-pn:

1. **Unreachable 10+ min** → CRITICAL Ntfy alert (`priority=5/urgent`, triggers SMS) + automatic
   **soft reboot** — `eq.php?action=reboot` via the Hostkey invapi for `hot-pn` (id `4683`) /
   `hot-erp` (id `41614`, standalone VPS), or `qm reboot <vmid>` on hot-bm-nl for the 4 Proxmox
   VMs (`sn-infra`=100, `sn-web`=102, `sn-monitor`=104, `sn-security`=106).
2. **Still unreachable 20+ min** (10 min after the soft attempt) → CRITICAL alert + automatic
   **hard power-cycle** — `eq.php?action=hard_off` then `action=on` for the Hostkey-hosted pair,
   or `qm stop --skiplock <vmid>` + `qm start <vmid>` for the Proxmox VMs.
3. **Still down after the hard cycle** → re-alerts every 15 min, but takes **no further automatic
   action** — at that point it's flagged as needing the Hostkey KVM console by hand, same as any
   hardware/hypervisor-level failure (see the hot-bm-nl outage precedent).
4. Recovery (SSH reachable again) always sends a follow-up Ntfy notification naming which stage
   was last attempted, so Mr. Byrne has full visibility even though the whole sequence ran
   unattended.

Hostkey server IDs (`4683`=hot-pn, `41614`=hot-erp) were verified live against the invapi
(`eq.php?action=show`, matching each server's real public IP) before being hardcoded here — not
just trusted from memory, since this script can genuinely hard-power-cycle production
infrastructure unattended. The escalation logic itself was verified with an isolated test harness
(fake host, stubbed reachability + actions, compressed thresholds) before being enabled for real,
confirming the full down → soft → hard → repeat-alert → recovered state machine transitions
correctly — deliberately not tested by forcing a real host down, given what's at stake if the
logic were wrong.

Uses the same shared Ntfy token and Hostkey invapi key already documented elsewhere
(`/opt/stacks/hostkey-api/secrets/hostkey_api_key.txt` — see the `hostkey-invapi-notes` memory).

**⚠ Real bug found+fixed 2026-08-06/07: the Hostkey token parser used the wrong JSON shape,
silently failing every hostkey-backed recovery action for 7.5 hours.** `hostkey_token()` parsed
`auth.php`'s response as `{"token": "..."}` top-level, but the real shape nests it —
`{"result": {"token": "...", ...}}`. Every `hostkey_token()` call therefore failed, which the
action functions correctly logged ("hostkey auth FAILED") — but the main loop **unconditionally**
advanced `stage_file` to `soft`/`hard` regardless of whether the action actually succeeded, so the
state machine locked into `hard` after the first failed attempt and then just re-alerted every
~15 min with **no further action ever taken or retried**. This let a real hot-pn outage run
unremediated from 09:12 to ~16:59 on 2026-08-06 (27 identical "still down, needs the Hostkey KVM
console" alerts) — found during routine follow-up verification of this watchdog, not by active
monitoring. Fixed: (1) corrected the JSON parse to `['result']['token']`; (2) `stage_file` now only
advances when `do_soft_reboot`/`do_hard_cycle` actually return success — on failure it sends a
distinct "FAILED, will retry" alert and leaves the stage unchanged so the next tick retries, gated
by the same `REPEAT_ALERT_SEC` throttle. The live outage was recovered manually the same way the
watchdog was supposed to (hostkey `hard_off` + `on` against id `4683`) before the code fix landed.
**Verified for real, not just by inspection**: the very next day (2026-08-07 06:07–06:40) sn-monitor
genuinely went down and the *fixed* script correctly self-healed it end-to-end (soft reboot at
06:21, hard cycle at 06:36, recovered 06:40) — the first real proof this watchdog works as designed
end-to-end, not just in the isolated test harness. Root lesson: the original test harness stubbed
out `do_soft_reboot`/`do_hard_cycle` specifically to avoid touching real APIs while validating
timing — correct for safety, but it meant the real `hostkey_token()`/`hostkey_call()` code path was
never actually exercised before deploy. State-machine logic and real API-calling logic both need
independent verification, not just one via a stub.

**Fail-safe health check** (`reboot-watchdog-healthcheck.sh` on the Gateway, run via one-shot
`systemd-run --on-calendar` transient units rather than the CronCreate tool, deliberately, so it
survives independent of any Claude Code session) reports timer liveness, recent journal failures,
recent watchdog-log activity, and stale per-host state files via Ntfy. Had its own latent bug fixed
2026-08-08: it originally flagged the watchdog log as "an issue" if it had **any** content ever,
which — once the log has real permanent history (as it now does, from the incidents above) — would
report "issues found" on literally every future run forever. Fixed to only look at the last 24h of
journal/log activity so repeat runs stay meaningful.

---

## Grafana Alerting

SMTP: mail.house-of-trae.com:587 via notifications@house-of-trae.com. Contact points: "email-hot" → tristian@securenexus.net (all critical/high alerts); "ntfy-critical" → webhook to `https://ntfy.house-of-trae.com/hot-alerts` (severity=critical only, added 2026-08-04 — see below).
Alert rules (folder "HoT Infrastructure Alerts"): Node Down (critical, 2m), Disk >85% (high), Disk >95% (critical), Memory >90% (warning), TLS cert <14d/<7d (via Blackbox Exporter — deployed, probing 17 endpoints).
Notification policy: group by severity/alertname/instance — group_wait 30s, repeat 1h for critical/high, 4h default. A `severity="critical"` route (matching Node Down/Disk >95%/TLS cert <7d, the 3 rules actually labeled `severity: critical`) fires to `ntfy-critical` with `continue: true`, then falls through to the existing critical|high route so email still sends too — both receivers fire for every critical alert.

**Grafana → Ntfy → SMS wired up 2026-08-04** (closes the gap noted in sms_relay_migration_scope memory — Grafana previously had zero path to Ntfy at all, only the SMTP contact point existed). `ntfy-critical` is a `webhook` contact point, `authorization_scheme: Bearer` / `authorization_credentials` = the same Ntfy token CrowdSec's notification plugin already uses (`gateway/crowdsec/notifications/http.yaml`) — **`username`/`password` Basic-Auth fields do NOT work for this** despite matching curl tests succeeding manually; Grafana's webhook notifier 403'd until switched to the `authorization_scheme`/`authorization_credentials` fields, confirmed via a real temporary always-firing test rule pushed through the full pipeline (created, verified delivery + a real SMS, then deleted — no residue). URL includes `?title=Grafana+CRITICAL+Alert&priority=urgent` as query params (Ntfy accepts title/priority via querystring same as headers). Grafana's webhook contact point has **no payload templating** — the Ntfy message body is always Grafana's raw alert-group JSON, so `sms-relay` (see Gateway VPS service table) was extended to detect that shape and extract a readable line + Grafana's own `groupKey` for rate-limiting, instead of colliding on the one static Ntfy title every Grafana-critical alert would otherwise share. Wazuh was checked too — zero Ntfy integration exists there either (only path out is the PN Lockdown Mode webhook for level≥10, unrelated to Ntfy) — not wired up, no ask to do so yet.

**⚠ Real bug found+fixed 2026-08-08: all 6 alert rules were `execErrState: Alerting` (fail-open on query error), causing a mass false-CRITICAL SMS storm.** Grafana and Prometheus both run on sn-monitor itself — when sn-monitor went down and got hard-power-cycled by the reboot-recovery-watchdog (see below) on 2026-08-07 ~06:07–06:40, every alert rule's query to its own just-restarting Prometheus datasource errored out simultaneously, and `execErrState: Alerting` meant every rule (Node Down, Disk >85%/>95%, Memory >90%, TLS cert <14d/<7d) fired CRITICAL for every instance it had last seen — a burst of bogus "Disk >95%"/"Node Down" texts for hosts that were never actually in trouble (real disk usage checked live: 2–32% everywhere). Fixed by setting `execErrState: Error` on all 6 rules via the provisioning API (`PUT /api/v1/provisioning/alert-rules/<uid>` with `X-Disable-Provenance: true`, admin creds in `/opt/stacks/monitoring/secrets/admin_password`) — a query/datasource error now shows as a distinct Error state in Grafana's UI instead of paging as a false CRITICAL. Verified live: all alert states back to Normal, no residual false firings. This will recur on any future sn-monitor restart if `execErrState` ever drifts back to `Alerting` — check `curl -s -u admin:<pw> localhost:3000/api/v1/provisioning/alert-rules` on sn-monitor if unexplained mass CRITICAL SMS bursts happen again.

**Real capacity finding from the same investigation, fixed same day: hot-bm-nl was memory-constrained due to an uncapped ZFS ARC.** This is what triggered the (correctly real, not a false positive) "Memory >90% proxmox-host" alert seen "Pending" during this investigation — full detail and the fix (`zfs_arc_max` capped at 8 GB) now lives in the Hardware — VM Allocation section's Hard Limits note, not duplicated here.

---

## Operational Rules (Hard-Won Learnings)

| Rule                              | Detail                                                                                                                                 |
|-----------------------------------|----------------------------------------------------------------------------------------------------------------------------------------|
| No Docker in LXC                  | Requires privileged containers — undermines security — Docker stays on full VMs                                                        |
| UFW rules use /16                 | Proxmox masquerades IPs between VLANs — rules must allow 10.10.0.0/16                                                                 |
| WireGuard AllowedIPs              | Must update on BOTH VPS and bare metal when adding a new VLAN/subnet                                                                   |
| VM clone checklist                | Fix UFW input policy (DROP→ACCEPT) and nameserver on every clone                                                                       |
| Caddy reload                      | `docker compose restart caddy` from /opt/stacks/caddy/ — kill -USR1 and admin API both FAIL                                           |
| PowerDNS API                      | Port 8081 (not 8053) — Caddy TLS uses acme_dns with api_token                                                                         |
| Docker secrets                    | chmod 644 (not 600) for non-root container users                                                                                       |
| Caddy remote_ip                   | Sees Docker bridge IP not real client IP — IP-based access control ineffective                                                         |
| Tailscale = admin only            | Never route production traffic through Tailscale (DERP relay latency)                                                                  |
| Keycloak OIDC URL                 | Must point to realm root (.../realms/<realm>) not the protocol endpoint                                                                |
| pda-legacy OIDC config            | Use OIDC_OAUTH_AUTO_CONFIGURE=true + OIDC_OAUTH_METADATA_URL — manual TOKEN_URL/AUTHORIZE_URL omits jwks_uri, causing RuntimeError    |
| pda-legacy OIDC_OAUTH_API_URL     | Must be `https://auth.house-of-trae.com/realms/<realm>/protocol/openid-connect/` WITH trailing slash — urljoin drops last segment otherwise, causing KeyError: 'preferred_username' |
| pda-legacy OIDC auto-provisioning | First OIDC login creates new "User" role account — promote via `UPDATE "user" SET role_id=1 WHERE username='<oidc-username>'` in pdns-admin DB |
| Keycloak realm-federation broker  | All child realms broker from house-of-trae master via identity-provider-redirector. Raise access_code_lifespan to 300s on every child realm — default 60s causes expired_code broker errors. SQL changes need Keycloak restart to bust Infinispan cache. |
| user_oidc CLI                     | Silent fail on Nextcloud v8.6.1 — must configure via web UI                                                                           |
| PostgreSQL reserved words         | "user" must be quoted in queries                                                                                                       |
| ERPNext apps.txt                  | Manually reconcile after restore — ghost entries cause silent failures                                                                 |
| ERPNext healthcheck PID leak      | `init: true` on dickson-backend (already applied) — tini reaps orphaned curl processes from healthcheck; without it PID limit fills and container becomes unkillable |
| ERPNext `unless-stopped` trap     | After `docker stop`/maintenance the stack stays down — always follow with `docker compose up -d` to restart                            |
| ERPNext tabError Log corruption   | After unclean shutdown: `docker exec dickson-db mariadb -u root -p<pw> _ae77c090ad3ef28b -e "REPAIR TABLE \`tabError Log\`;"` — password in secrets/dickson_db_password.txt |
| ERPNext backend = gunicorn        | Never revert to `bench serve` — command is `gunicorn --workers=2 --worker-class=gthread --threads=4 --timeout=120 wsgi:application` from `/home/frappe/frappe-bench/sites` |
| ERPNext asset hash drift          | `regen_assets.py` runs at startup to rebuild assets.json from image-layer files; `redis-cli DEL assets_json` also runs to bust ClientCache. Never run `bench build` inside the container — it invalidates hashes lost on next restart. |
| ERPNext `dickson-worker` stuck restart | `docker restart`/`docker start` on `dickson-worker` alone can get permanently stuck crash-looping on `rm: cannot remove '/home/frappe/frappe-bench/sites/assets': Device or resource busy` (the base image's `entrypoint.sh` does a naive `rm -rf`+`ln -s` against what's actually a named-volume mountpoint — `dickson-backend` avoids this via its own `regen_assets.py`, which clears contents in place instead of removing the mountpoint itself, but `dickson-worker`/`dickson-scheduler` rely on the raw entrypoint). First hit 2026-08-05 when hot-erp-nl auto-rebooted for a kernel update — `dickson-backend`/`dickson-scheduler` came back fine, `dickson-worker` didn't, and repeated `docker restart`/`stop`+`start` cycles on the existing container instance kept failing identically. Fixed by `cd /opt/stacks/dickson && docker compose up -d --force-recreate dickson-worker` — a full container recreate (fresh mount namespace) cleared it immediately; reused container instances did not. |
| ERPNext secrets must be 644       | frappe runs as UID 1000 — `chmod 600` secrets are unreadable, silently breaking Redis cache/queue                                      |
| rclone B2                         | hard_delete=true required — otherwise leaves hidden versions                                                                           |
| Watchtower version                | v1.5.3 only — v1.7.1 Docker API negotiation bug                                                                                        |
| MinIO + EPYC 3151                 | Must use cpuv1 image tag — Zen1 architecture, no AVX-512                                                                               |
| Cosmos = abandoned                | Aggressively pulls images, breaks local builds — plain Docker Compose only                                                             |
| forgejo-runner + docker.sock      | `chown 1000:1000 ./data` on host or registration fails. Add `group_add` with host docker.sock GID (`stat -c '%g' /var/run/docker.sock`) or every job fails with permission denied. |
| No combined stacks                | Each service has its own compose file — never combine unrelated services                                                               |
| Secrets management                | Docker secrets for all credentials — never plain environment variables                                                                 |
| Namevault pg.Pool idle drop       | Add `keepAlive: true`, `idleTimeoutMillis: 60000`, `connectionTimeoutMillis: 5000` — Docker DNS returns EAI_AGAIN when pool connections go idle overnight and session pruner fires |
| Keycloak post-logout redirect     | `post.logout.redirect.uris` on the client must match exactly what the app sends — old dev Tailscale address causes silent redirect failure after logout |
| `wg syncconf` doesn't add routes  | `wg syncconf <iface> <(wg-quick strip <iface>)` applies AllowedIPs/peer changes to WireGuard's own crypto-routing live, without dropping the tunnel — but it does NOT touch the kernel's IP routing table. Route installation for new AllowedIPs ranges is normally done by `wg-quick up`'s own logic, which `syncconf` bypasses entirely. After widening AllowedIPs via `syncconf`, manually `ip route add <new-range> dev <iface>` or the new range stays unreachable despite `wg show` reporting it correctly. A future `wg-quick` cycle (reboot, manual restart) will install the route correctly on its own since the config file itself is updated. |
| qemu-guest-agent on all VMs       | Every VM (100–106) runs `qemu-guest-agent` with `agent: enabled=1` in its Proxmox config. Without the in-guest package, `qm reboot`/`qm shutdown` fall back to ACPI and time out (guest-ping fails), forcing a hard `qm stop`/`qm reset` — this bit 101 and 105. The service is `static` (virtio-serial activated): it auto-starts on boot and cannot be `systemctl enable`d. Reinstall on any new clone: `apt-get install -y qemu-guest-agent && systemctl start qemu-guest-agent`; verify from host with `qm agent <id> ping`. |
| NBDE unlock chain                 | ALL 7 VMs have LUKS2-encrypted root on `/dev/sda3`. All use dual-binding: **slot 3 (preferred) → Gateway VPS Tang** (`http://10.10.0.1:7500`), **slot 2 (fallback) → sn-infra Tang** (`http://10.10.10.100:80`). Gateway Tang is a systemd socket service (NOT Docker) bound to WireGuard interface only. On bare metal reboot: Proxmox boots → WireGuard up → all VMs start at order=1 in parallel → each initramfs contacts Gateway Tang (always-on) → LUKS unlocks. sn-infra Tang is only needed if Gateway is unreachable. To bind a new VM: (1) get key: `clevis luks pass -d /dev/sda3 -s 2`, (2) bind: `echo KEY \| clevis luks bind -d /dev/sda3 tang '{"url":"http://10.10.0.1:7500"}' -y -k -` (needs PTY — use Python pty script), (3) set preferred: `cryptsetup config --priority prefer --key-slot 3 /dev/sda3`. |
| sn-security LUKS offline access   | Offline disk access from Proxmox: `qemu-nbd --connect=/dev/nbd0 -f raw /dev/zvol/rpool/data/vm-106-disk-0` → `clevis luks unlock -d /dev/nbd0p3 -n vm106root` → `vgchange -ay ubuntu-vg` → `mount /dev/ubuntu-vg/ubuntu-lv /mnt/vm106`. Boot partition is separate: also mount `mount /dev/nbd0p2 /mnt/vm106/boot`. |
| Wazuh needs 8 GB RAM             | OpenSearch JVM heap is 1 GB but total process RSS during initialization peaks at 3-4 GB. sn-security must stay at 8 GB; reducing below 6 GB causes OOM and indexer crash-loops during startup, keeping the dashboard in permanent 503. |
| Proxmox NIC PCIe link loss        | Intel I350 NIC (`igb 0000:03:00.0 nic0`) has intermittent PCIe link loss causing complete outages (Jun 26, Jun 27, Jun 28). Fix: `pcie_aspm=off` in `/etc/kernel/cmdline` (NOT /etc/default/grub — Proxmox uses proxmox-boot-tool/systemd-boot, not GRUB). Run `proxmox-boot-tool refresh` after editing cmdline. Applied Jun 28 18:55 boot on kernel 7.0.12-1-pve. **This is a MITIGATION, not a fix** — crashes continued Jun 30 at 05:30 and 08:49 with the identical fault signature (`PCIe link lost` / `Failed to read reg 0xc030!` / NETDEV WATCHDOG timeout / adapter reset), just at ~34h intervals instead of daily. `ethtool -S nic0` shows rx_missed_errors/rx_fifo_errors climbing even between crashes, confirming the fault is still present at a sub-crash level. `lm-sensors` installed Jul 1 — CPU (k10temp) reads ~33°C at time of fault window, ruling out thermal as the cause. Hostkey ticket still open and required: physical NIC reseat/replacement — this is the real fix. NIC watchdog cron at `/etc/cron.d/nic-watchdog` (`/usr/local/bin/nic-watchdog.sh`, every 2 min) attempts `ip link down/up` + `wg-quick up` on link loss but has a 100% failure rate recovering from this specific fault (log: `/var/log/nic-watchdog.log`) — a full reboot is required to restore the NIC. Watchdog now pushes an Ntfy CRITICAL alert on recovery failure (added Jul 1). |
| Wazuh offline disk edit           | Wazuh compose and config can be edited offline: stop VM → mount disk via NBD → Clevis unlock → LVM activate → mount → edit → unmount all → `qemu-nbd --disconnect` → start VM. |
| Wazuh dashboard wazuh.yml default password | `/opt/stacks/wazuh/config/wazuh_dashboard/wazuh.yml` ships with placeholder password `MyS3cr37P450r.*-` for the `wazuh-wui` API user. Must be replaced with the real API password after every fresh deploy, then `docker restart wazuh-wazuh.dashboard-1`. Symptom: dashboard shows "could not accept any API entry". |
| Docker Mailserver ClamAV stale signatures | `ghcr.io/docker-mailserver/docker-mailserver:latest` (currently release 15.1.0) hasn't been rebuilt by upstream since 2025-08-12 — confirmed via the GHCR registry digest directly, not a local pull/cache issue. Bundled ClamAV (1.0.7) is stuck in a permanent freshclam CDN cool-down loop ("Forbidden; Blocked by CDN") since ClamAV's CDN blocks outdated client versions — `docker compose pull` is a no-op until upstream ships a new release. The `:edge` tag does have current ClamAV (1.4.3, live signatures) but is upstream's nightly/unstable branch — deliberately NOT adopted for production mail (every domain's SMTP/IMAP, including notifications@house-of-trae.com alerting) just to fix a secondary AV layer; rspamd remains the unaffected primary spam/phishing filter. Real long-term fix if ever prioritized: decouple ClamAV into its own sidecar (`clamav/clamav` image, actively maintained independently) with docker-mailserver's milter pointed at that external clamd socket — scoped but not started as of 2026-07-05. |

---

## New VM Clone Checklist

1. Set UFW input policy to ACCEPT (template defaults to DROP)
2. Correct /etc/resolv.conf nameserver
3. Apply UFW rule: allow from 10.10.0.0/16
4. If new VLAN: update WireGuard AllowedIPs on Gateway VPS AND bare metal; wg-quick down/up
5. Add new VM alias to /root/.ssh/config on this Gateway
6. Install qemu-guest-agent (`apt-get install -y qemu-guest-agent && systemctl start qemu-guest-agent`); confirm `agent: enabled=1` in the VM's Proxmox config and verify from host with `qm agent <id> ping` — without it `qm reboot`/`qm shutdown` time out and need a forced power-cycle
7. Install node-exporter and Promtail, configure to ship to 10.10.50.104:3100
8. Add to Prometheus scrape targets on sn-monitor
9. Add to Uptime Kuma monitors
10. Add Watchtower v1.5.3 on the new VM
11. Install Tailscale for admin-access redundancy (`curl -fsSL https://tailscale.com/install.sh | sh`, then `tailscale up --hostname=<vm-name>`) — **missed entirely during the 2026-07-27 hot-bm-nl 4-VM rebuild** (sn-infra/sn-web/sn-monitor/sn-security all went 3 days with no Tailscale at all, fixed 2026-07-30, see fleet_health_check/tailscale memory). If the same hostname was previously registered by a now-dead VM, delete the stale device first (`api.tailscale.com/api/v2/device/<id>`, DELETE) to avoid a `-1` suffix on the new registration.

---

## New Service Deployment Checklist

1.  Check RAM and disk headroom on target VM before proceeding
2.  Verify image is Zen1/cpuv1 compatible if running on bare metal VMs
3.  Create /opt/stacks/<service>/docker-compose.yml
4.  Use Docker secrets for all credentials (chmod 644 secret files)
5.  Add Caddy block in /opt/stacks/caddy/Caddyfile
6.  Add PowerDNS A record (via API or PowerDNS-Admin)
7.  Reload Caddy: cd /opt/stacks/caddy && docker compose restart caddy
8.  Add UFW rule: allow from 10.10.0.0/16 to any port <service-port>
9.  Verify TLS certificate provisioned
10. Add to Uptime Kuma monitors
11. Add Prometheus scrape target if service exposes metrics
12. Configure SMTP (notifications@house-of-trae.com) if service sends notifications
13. **SSO is default, not optional.** Gate the app behind Keycloak: if the app has a native OIDC option, wire it to the appropriate realm directly; otherwise `import sso` in its Caddy block (see below) to gate it with the shared oauth2-proxy instance. Only skip this for services that can't sensibly support a browser login gate (e.g. raw SMTP/IMAP ports, API-only backends called machine-to-machine) — note the exception inline in the Caddy block if so.

### SSO via oauth2-proxy (default pattern for new web apps)

Gateway runs a shared `oauth2-proxy` (`/opt/stacks/oauth2-proxy/`) as an OIDC client (`oauth2-proxy` in the `securenexus` Keycloak realm), with `--cookie-domain=.house-of-trae.com` so one login covers every app that gates behind it, and a fixed `--redirect-url=https://ds.house-of-trae.com/oauth2/callback` (must stay the sole Keycloak-registered redirect URI regardless of which app initiated login — oauth2-proxy carries the original app URL through the OAuth `state` param and 302s back to it after auth).

The Caddyfile has an `(sso)` snippet (global snippets section) that wires this up correctly — including the path-matcher fix needed so `/oauth2/*` callback requests don't get caught by their own auth check (`forward_auth` has no path scoping by default, so without a `not path /oauth2/*` matcher it loops on itself). To gate a new app, just add `import sso` alongside `import crowdsec` in its site block:
```
newapp.house-of-trae.com {
    import crowdsec
    import compress
    import sso
    reverse_proxy newapp:PORT
}
```
First deployed for `webmail.house-of-trae.com` (Roundcube) — Roundcube's own IMAP/SMTP login still runs after the gate (this is a pre-auth wall using centralized identity, not a skip-login IMAP OAUTH2 integration). True passwordless SSO into Roundcube would require enabling Docker Mailserver's OAUTH2/XOAUTH2 support against Keycloak plus the Roundcube `oauth2` plugin — bigger scope, not yet done, evaluate only if the pre-auth wall proves insufficient.

---

## Tor Hidden Services

Stack: `/opt/stacks/tor/` on Gateway VPS. `network_mode: host` — `HiddenServicePort 80 127.0.0.1:80` hits Caddy directly.

| Service          | Onion Address                                                    | Auth      | Notes                              |
|------------------|------------------------------------------------------------------|-----------|------------------------------------|
| ERPNext (mirror) | qcrzygpg5qbzch4c2qlcgiktuvzf3xwqwtd7mkcn5r4g4mxebmpptkid.onion | x25519 v3 | Mirror of erp.dickson-supplies.com |

Caddy block uses `http://` prefix + `header_up Host erp.dickson-supplies.com`.
Client private key for tristian: Vaultwarden — "ERPNext Onion Client Auth Key (tristian)" (regenerated 2026-08-02, see note below).
Auth files: `/opt/stacks/tor/data/erp/authorized_clients/` (chown 100:101, chmod 600). Reload: `docker compose restart tor`.

⚠️ **`authorized_clients/*.auth` on disk is the server-side PUBLIC key only** (`descriptor:x25519:<pubkey>`) — Tor's standard v3 client-auth layout. It is NOT what Tor Browser's client-auth popup asks for. The matching PRIVATE key (the bare base32 string Tor Browser wants) only ever exists client-side and is never stored in this directory — it must be captured at keypair-generation time and saved separately (Vaultwarden), or it's permanently unrecoverable (X25519 — private can't be derived from public). **2026-08-02 incident:** the Vaultwarden entry had been holding the public key mislabeled as private the whole time; the real original private key was never saved anywhere and was lost. Fixed by generating a fresh keypair, installing the new public half here, restarting Tor, and saving the real private key to Vaultwarden. If this ever needs regenerating again: generate an X25519 keypair, base32-encode (RFC4648, no padding) both halves, write `descriptor:x25519:<pubkey_b32>` to this directory (chown 100:101, chmod 600), restart the tor container, and give the client the bare `<privkey_b32>` string — never store the private half server-side.

⚠️ Backup: Gateway VPS is NOT a Proxmox VM. Losing `hs_ed25519_secret_key` means the onion address is permanently lost. Include `/opt/stacks/tor/data/erp/` in any VPS backup.
`data/` is never committed to git (only docker-compose.yml, Dockerfile, torrc are synced).

---

## Phase 4 — On the Horizon

**Done, removed from this list (2026-08-03 cleanup):** Wazuh SIEM on sn-security (live since the
2026-07-27/28 rebuild) and Cosmos retirement (fully removed Jun 2026) — this list wasn't updated
when either landed.

- CrowdSec custom scenarios
- PrivateNexus PN roadmap gates (v5.0/v6.0/v7.0) — see `PrivateNexus_Release_Roadmap_v1.0.md` and
  the `open_items_2026_07_27` memory for current gate-item detail; re-verify before trusting any
  snapshot, this list drifts (e.g. Security Lockdown Mode was listed unbuilt as of 2026-07-27 but
  was actually finished 2026-08-01 — see `PrivateNexus_Security_Lockdown_Mode_Design.md`)
- HoT Sync (Flutter) — Immich + Nextcloud + Notesnook + Vaultwarden; tentatively tied to sn-personal
  (VLAN 40)'s still-open fate, not yet scoped
- HoT Command (Flutter) — Mobile ops dashboard (also listed as a v7.0 PN roadmap candidate)
- Second bare metal node (HA)
- Edge load balancing (second VPS)
- Terraform / Ansible IaC

---

## Quick Reference

| Resource                    | Value                                                |
|-----------------------------|------------------------------------------------------|
| Gateway VPS public IP       | 151.241.217.91                                       |
| WireGuard VPS               | 10.10.0.1                                            |
| WireGuard bare metal        | 10.10.0.2                                            |
| Tailscale Gateway VPS       | 100.106.41.10                                        |
| Tailscale hot-bm-nl         | 100.90.156.88 (Proxmox UI, port 8006 only)           |
| Tailscale sn-infra          | 100.99.52.12                                         |
| Tailscale sn-web            | 100.91.130.53                                        |
| Tailscale sn-monitor        | 100.109.177.48                                        |
| Tailscale sn-security       | 100.118.146.83                                        |
| Tailscale Ubuntu WS         | 100.116.130.37                                       |
| Tailscale Windows (latitude)| 100.106.225.126                                      |
| Tailscale Windows (traebake)| 100.127.229.35                                       |
| Tailscale suffix            | spangled-atlas.ts.net                                |
| PowerDNS API key            | pdnsKj7xM9pL2vR5n                                    |
| PowerDNS API port           | 8081 (on 10.10.0.1)                                  |
| Caddyfile location          | /opt/stacks/caddy/Caddyfile                          |
| Caddy reload                | cd /opt/stacks/caddy && docker compose restart caddy |
| Universal SMTP              | notifications@house-of-trae.com:587 STARTTLS         |
| Keycloak URL                | https://auth.house-of-trae.com                       |
| All secrets                 | Vaultwarden — vault.house-of-trae.com (Gateway VPS)  |
| Config git repo             | /opt/hot-config                                      |
| B2 backup bucket            | hot-proxmox-backups                                  |
| Hetzner Storage Box         | u622237@u622237.your-storagebox.de:23 (hetzner:vzdump)|
| PrivateNexus prod/dev host  | hot-pn — 151.241.217.140 (pn-test retired 2026-08-03)|
| This project directory      | /root/hot/                                           |
| Full roadmap                | /root/hot/docs/HoT_Infrastructure_State_Roadmap_v*.docx — use highest version present (currently v3.6), docx2txt |
| PN Phase 0 freeze           | /root/hot/docs/PrivateNexus_Phase0_Freeze.md         |

---
# End of CLAUDE.md — v2.0
# "Sometimes you gotta run before you can walk." — Tony Stark
