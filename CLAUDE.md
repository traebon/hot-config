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
| PrivateNexus        | privatenexus.net         | PrivateNexus test env (sn-personal) — dev/build on pn-test |

---

## Network Topology

```
Internet
    │
    ▼
Gateway VPS — 151.241.217.91 (Hostkey B.V., Zürich)
    │  WireGuard tunnel (ChaCha20-Poly1305)  10.10.0.1 → 10.10.0.2
    ▼
Proxmox Host — AMD EPYC 3151 (Switzerland DC)
    │  VLAN routing via vmbr0
    ├── VLAN 10 → sn-infra    (10.10.10.100)
    ├── VLAN 20 → sn-business (10.10.20.101)
    ├── VLAN 30 → sn-web      (10.10.30.102)
    ├── VLAN 40 → sn-personal (10.10.40.103)
    ├── VLAN 50 → sn-monitor  (10.10.50.104)
    ├── VLAN 60 → pn-test     (10.10.60.105)
    └── VLAN 70 → sn-security (10.10.70.106)

Tailscale overlay (admin access ONLY — never production traffic):
    Gateway VPS:         100.106.41.10
    sn-infra:            100.99.183.4
    sn-business:         100.83.114.127
    sn-web:              100.77.95.127
    sn-personal:         100.118.105.9
    sn-monitor:          100.122.98.79
    pn-test:             100.64.178.97
    sn-security:         100.112.71.39
    Ubuntu workstation:  100.116.130.37
    Windows (latitude):  100.106.225.126
    Windows (traebake):  100.127.229.35
    Tailscale suffix:    spangled-atlas.ts.net

Other WireGuard interfaces on the Gateway VPS (separate from the wg0 bare-metal tunnel above):
    wg1 — Mr. Byrne's personal road-warrior VPN. 10.10.90.0/24 (Gateway 10.10.90.1), port 51821.
          Client configs: phone/windows/laptop.conf in /root/hot/wireguard-clients/. Predates this
          doc; discovered 2026-07-06 when a new tunnel was almost given the same interface name —
          check `wg show` before reusing wg<N>/ports on this box.
    wg2 — TEMPORARY tunnel to erp-temp VPS (46.202.129.86) for the ERPNext stand-in during the
          bare-metal outage. Gateway 10.10.1.1 / erp-temp 10.10.1.2, port 51822. See
          hostkey_server_replacement memory and /opt/hot-config/erp-temp/dickson/README.md — tear
          down once bare metal is restored and reverted.
    wg3 — TEMPORARY tunnel to pn-vps (151.241.217.140) for the PrivateNexus stand-in during the
          same bare-metal outage (pn-test/sn-personal both unreachable). Gateway 10.10.2.1 /
          pn-vps 10.10.2.2, port 51823. See hostkey_server_replacement memory and the pn-vps
          section below — tear down once bare metal is restored and reverted.

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
| proxmox     | 10.10.0.2      | —    |
| sn-infra    | 10.10.10.100   | 10   |
| sn-business | 10.10.20.101   | 20   |
| sn-web      | 10.10.30.102   | 30   |
| sn-personal | 10.10.40.103   | 40   |
| sn-monitor  | 10.10.50.104   | 50   |
| pn-test     | 10.10.60.105   | 60   |
| sn-security | 10.10.70.106   | 70   |

---

## Hardware — Bare Metal (AMD EPYC 3151)

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

| VM  | Name        | vCPUs | RAM  | Disk   | VLAN / IP              | Primary Services                          |
|-----|-------------|-------|------|--------|------------------------|-------------------------------------------|
| 100 | sn-infra    | 1     | 4 GB | 250 GB | VLAN 10 / 10.10.10.100 | Forgejo, PowerDNS-Admin, Namevault, Ntfy  |
| 101 | sn-business | 2     | 8 GB | 300 GB | VLAN 20 / 10.10.20.101 | ERPNext v16, Dickson Supplies POS         |
| 102 | sn-web      | 2     | 4 GB | 250 GB | VLAN 30 / 10.10.30.102 | Client sites (6 sites)                    |
| 103 | sn-personal | 2     | 8 GB | 250 GB | VLAN 40 / 10.10.40.103 | PrivateNexus staging (registry images)    |
| 104 | sn-monitor  | 1     | 4 GB | 250 GB | VLAN 50 / 10.10.50.104 | Prometheus, Grafana, Loki, Uptime Kuma    |
| 105 | pn-test     | 1     | 4 GB | 250 GB | VLAN 60 / 10.10.60.105 | PrivateNexus dev/test                     |
| 106 | sn-security | 4     | 8 GB | 250 GB | VLAN 70 / 10.10.70.106 | Wazuh SIEM 4.14.5 (single-node)          |
|     | **TOTAL**   | **13**|**40 GB**|**1.75 TB**|                   | Over-provisioned — actual RSS ~7 GB across all VMs |

### ⚠️ Hard Limits — Do Not Exceed Without Approval
- **RAM:** 40 GB allocated vs 32 GB physical — KVM balloon keeps actual usage low. Do not add RAM-heavy VMs without checking pressure.
- **vCPU:** 13 vCPUs across 8 physical threads — flag further additions
- **Disk:** ~6.05 TB free on ZFS (1.09 TB used) — snapshots + backups consume this too
- **sn-personal disk:** 250 GB total. Root LV is 100 GB (98 GB filesystem) of a ~248 GB LVM VG — ~148 GB free in the VG, extend the LV with `lvextend` + `resize2fs` as needed before growing the Proxmox disk
- **sn-personal (250 GB)** and **sn-business (300 GB)** are the largest VMs and the only ones suitable for disk-heavy services

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

### sn-infra (ssh sn-infra — 10.10.10.100)
| Service        | Path                    | URL                           | Port |
|----------------|-------------------------|-------------------------------|------|
| Forgejo        | /opt/stacks/forgejo/    | git.securenexus.net           | 3000 |
| PowerDNS-Admin | /opt/stacks/pdns-admin/ | dns-admin.house-of-trae.com   | 9191 |
| Namevault      | /opt/stacks/namegen/    | namevault.co.uk               | 8010 |
| Ntfy           | /opt/stacks/ntfy/       | ntfy.house-of-trae.com        | 8080 |

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

### sn-personal (ssh sn-personal — 10.10.40.103)
Domain: privatenexus.net — primary PrivateNexus test environment (registry images from git.securenexus.net).
This is the environment used for all end-to-end testing. pn-test is dev/build (source builds + personal services).

Cosmos was fully removed (Jun 2026). All former personal services (Vaultwarden, Immich, Firefly III,
Actual Budget, Nextcloud, Notesnook) are GONE from this VM — data was never populated so no loss.

| Service                  | Path                       | URL                 | Port | Status |
|--------------------------|----------------------------|---------------------|------|--------|
| PrivateNexus (test env)  | /opt/privatenexus/compose/ | privatenexus.net    | 5173 | Active |

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

### pn-test (ssh pn-test — 10.10.60.105)
Domain: tresemme.space — personal services VM. Also hosts PrivateNexus dev/build (local source builds at /opt/privatenexus/).
Note: privatenexus.net routes to sn-personal (the primary PN test environment, registry images). pn-test = dev + personal services.

| Service      | Path               | Notes                                                                          |
|--------------|--------------------|--------------------------------------------------------------------------------|
| PrivateNexus | /opt/privatenexus/ | Active dev — React (frontend) + **Node.js Express v4 ESM** (API, v1.9.0) + PostgreSQL 16 + Redis |

**Phase 0 freeze (locked 22 June 2026):** Backend = Node.js Express v4 (ESM). Frontend = React. DB = PostgreSQL 16. Cache/queue = Redis. Identity = Keycloak (privatenexus realm). Gateway = Caddy. Do not suggest Go or NestJS as a rewrite — the codebase is at v1.9 and this decision is closed. See `/root/hot/docs/PrivateNexus_Phase0_Freeze.md` for full rationale and checklist.

### sn-security (ssh sn-security — 10.10.70.106)
VM: 4 vCPU / 8 GB RAM / 250 GB / VLAN 70. LUKS2 encrypted root (Clevis Tang → Gateway VPS preferred, sn-infra fallback). Dashboard: wazuh.house-of-trae.com

| Service        | Path                        | Notes                                                     |
|----------------|-----------------------------|------------------------------------------------------------|
| Wazuh SIEM     | /opt/stacks/wazuh/          | wazuh.house-of-trae.com — manager + indexer + dashboard   |
| Forgejo Runner | /opt/stacks/forgejo-runner/ | CI/CD runner for git.securenexus.net                      |

Wazuh creds (saved in Vaultwarden, "House of Trae — Gateway VPS" folder):
- Dashboard/admin login: `admin` / `bRSsn8P2v1YIbemCHejpEb6l`
- Wazuh API (wazuh-wui): `mHB2UhhMw0wTc3q8@22vJeOvr`
- OpenSearch kibanaserver: `h2huT1B1TrUXQg8Wri5FqhdP`

---

### erp-temp (ssh erp-temp — 46.202.129.86, public VPS, not a Proxmox VM) — TEMPORARY
Stood up 2026-07-06 as a stand-in for sn-business's ERPNext while bare metal is down (see
Hostkey Server Replacement in memory). 2 vCPU / 7.7 GB RAM / 96 GB disk, AMD EPYC 9354P (Zen 4,
full AVX-512 — no cpuv1 concerns here, unlike the bare-metal EPYC 3151). Reached from the
Gateway VPS over the dedicated `wg2` tunnel (10.10.1.1 ↔ 10.10.1.2) — see Network Topology.

| Service     | Path                | Notes                                                          |
|-------------|---------------------|------------------------------------------------------------------|
| ERPNext v16 | /opt/stacks/dickson/ | erp.dickson-supplies.com (Caddy repointed here) — **historical data restored 2026-07-09** from the 2026-06-29 Hetzner vzdump backup (the rclone crypt password was recovered — see [[rclone_crypt_password_vaultwarden]] — so the earlier "fresh site" decision was superseded). Live data now current as of the outage start (2026-07-02); anything entered into erp-temp between 2026-07-06 and 2026-07-09 was on the old fresh site and is in `.fresh-backup` volume copies on erp-temp, not merged in — needs Mr. Byrne's input if that window's data matters. Config synced to /opt/hot-config/erp-temp/dickson/ (README there has full rebuild notes/gotchas + the restore procedure). |

Caddy's `erp.dickson-supplies.com` block is temporarily pointed at `10.10.1.2:8000` instead of
`10.10.20.101:8000` — commented inline in the Caddyfile with the revert path. **Revert once bare
metal is restored** — see `/opt/hot-config/erp-temp/dickson/README.md` for the full revert plan
and what's genuinely different from the real sn-business stack (reconstructed Dockerfile,
posawesome source, etc. — several one-time setup gotchas that were never captured in
docker-compose.yml originally).

---

### pn-vps (ssh pn-vps — 151.241.217.140, Hostkey CH, public VPS, not a Proxmox VM) — TEMPORARY
Stood up 2026-07-15 as a stand-in for PrivateNexus's dev (pn-test) and test (sn-personal) roles
combined while bare metal is down (see [[hostkey_server_replacement]]). Ordered via the Hostkey
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
| PrivateNexus | /opt/privatenexus/ | privatenexus.net (Caddy repointed here) — full stack built and deployed from the current `origin/main` source (rsynced from this Gateway's `/root/privatenexus` clone, confirmed clean at the time). Reuses the existing Keycloak `privatenexus` client secret unchanged (its redirect URIs already targeted `privatenexus.net`, not pn-test/sn-personal specifically, so no Keycloak change was needed). `PROXMOX_URL` points at sn-monitor/bare-metal and will not work until that's reachable again — expected, not a bug (nothing to substitute for the real hypervisor). `PROXMOX_TOKEN` stays a placeholder for the same reason. `PDNS_API_KEY` was fixed 2026-07-15 (see PowerDNS reachability note below) — no longer a placeholder, DNS management from PrivateNexus now works. |

**PowerDNS reachability from pn-vps (fixed 2026-07-15):** the Gateway's PowerDNS API (`10.10.0.1:8081`, see PowerDNS section) was wrongly assumed unreachable from pn-vps due to being "outside the VLAN mesh" — actually PowerDNS lives on the Gateway itself, not bare metal, so it was reachable the whole time; three independent bugs just made it look like a bare-metal dependency:
1. **No UFW rule for port 8081 existed at all** on the Gateway (not even for the internal fleet) — added `ufw allow from 10.10.0.0/16 to any port 8081`.
2. **pn-vps's wg0 `AllowedIPs`** (its local interface name for the Gateway tunnel — the Gateway calls its side `wg3`, but naming is per-host) was scoped to just `10.10.2.1/32` (the Gateway's tunnel IP), so pn-vps never routed traffic bound for `10.10.0.1` into the tunnel. Widened to `10.10.2.1/32, 10.10.0.1/32` — deliberately narrow (just the one IP needed), not the full `10.10.0.0/16`, to keep this external/less-trusted box's blast radius minimal.
3. **`wg syncconf` (used to apply the AllowedIPs change live without dropping the tunnel) does NOT install kernel routes** — that's normally done by `wg-quick up`'s own route-installation logic, which `syncconf` bypasses entirely. Had to manually `ip route add 10.10.0.1/32 dev wg0` after. Config file is correct so a future `wg-quick` cycle (e.g. on reboot) will install it automatically — but any *live* AllowedIPs change applied via `syncconf` needs its route added manually too.

Also found `wg-quick@wg0` was never `systemctl enable`d on pn-vps — a reboot would have dropped the tunnel permanently until manually restarted. Enabled it.

`/opt/privatenexus/secrets/pdns_api_key.txt` was also `chmod 600` (root-only) instead of `644` — same class of bug as the documented ERPNext secrets gotcha (container runs as non-root `user: "1000"`, couldn't read a root-only file). Backend crash-looped with `PDNS_API_KEY secret not configured` until fixed to `644` to match every other secret in that directory.
| Monitoring (temp) | /opt/stacks/monitoring-temp/ | **Added 2026-07-15.** `PROMETHEUS_URL`/`LOKI_URL` were repointed from sn-monitor to a local Prometheus + node-exporter + Loki + Promtail stand-in here (`.env` in the PrivateNexus compose dir) — PrivateNexus's own health-scheduler/dashboard needs somewhere reachable to query. All four containers sit on the existing `compose_pn-internal` network only — no host ports published, no public exposure. Monitors pn-vps itself (node-exporter + container logs via Promtail), not the wider HoT fleet. Loki's `/ready` endpoint returns a cosmetic 503 (`"waiting for 15s after being ready"`, a known single-node quirk) despite actually ingesting logs correctly — don't mistake that for a real problem. Promtail's `container` label relabel rule originally stripped the leading slash from `__meta_docker_container_name`, unlike the Gateway's real Promtail config — silently broke every Logs board query on pn-vps until fixed 2026-07-15 (`hot-config` commit `f80c6b1`) to match Docker's raw `/name` convention. Revert `.env` back to `10.10.50.104` once bare metal is restored, then tear this stack down. |
| Watchtower | /opt/stacks/watchtower/ | **Added 2026-07-15.** Pinned v1.5.3, monitor-only (emails on available updates, doesn't auto-apply), matching the Gateway's pattern — see `gateway/watchtower/`. PrivateNexus's three locally-built services (`privatenexus-backend`/`-frontend`/`-mcp`) carry the `com.centurylinklabs.watchtower.enable=false` label to avoid the same pointless-nightly-pull-failure noise already known from `caddy`/`tor` on the Gateway (locally-built images have no registry path to check). Uptime Kuma was deliberately skipped — PrivateNexus's own internal health-scheduler doesn't need it. |
| Discovery agent | /opt/privatenexus/scripts/discovery-agent.sh | `privatenexus-discovery-agent.timer` (systemd, boot + hourly) pushes host + container facts to PrivateNexus's own `POST /api/discovery/ingest`. Units captured at `pn-vps/discovery-agent/` in this repo. See discovery-agent hardening note below. |

**Discovery agent hardening + registry drift closed (2026-07-15):** the agent was still running on the ingest endpoint's static bootstrap fallback token (`agent_tokens` table was empty — the code's own comment flags this path as "bootstrap only — rotate to DB tokens"). Rotated it: generated a random 64-hex-char token, inserted its SHA-256 hash into `agent_tokens` (label `pn-vps discovery-agent.timer`, no expiry), and wrote the plaintext into `/opt/privatenexus/secrets/discovery_agent_token.txt`. Confirmed via `last_used_at` updating on the next run that the agent now authenticates against the real scoped DB token, not the fallback. Also tightened that secret file from `644`→`600` — unlike the ERPNext/PowerDNS secrets pattern (needs `644` for a non-root container UID), this one is read directly by a root-owned systemd service, so world-readable was unnecessarily permissive.

Separately, the monitoring-temp + Watchtower containers deployed the same day had been correctly picked up by the discovery agent but sat unreviewed as pending candidates — approved all 5 into the service registry (`pn-loki`/`pn-node-exporter`/`pn-prometheus`/`pn-promtail` → `monitoring` workspace, `watchtower` → `infrastructure` workspace), closing the drift between what's actually running and what PrivateNexus's own registry knows about.

**Action-safety pipeline wired up + a live auth bug fixed (2026-07-15):** the Stacks board's restart/stop/start confirmation modal already promised a "blast-radius check," but `runAction()` called `POST /api/actions/run` (v1) — a bare cooldown/allowlist check with no blast-radius, elevation, or approval-queue logic. The real `/api/actions/run/v2` endpoint had all of that already built, with real seeded policies (`container.stop` requires dual-control approval, `restart`/`stop` both run a blast-radius check), but nothing in the UI ever called it. Fixed in `hot-privatenexus` commit `2043d30`:
- `stacks.js` now joins `GET /api/stacks` against `services.container_name` so the frontend can pass a real `service_id` into the v2 blast-radius check. Unregistered containers now say so honestly in the modal instead of implying protection that can't apply.
- `discovery.js`'s approve action never set `container_name` on the new service row, so that join (and the pre-existing MCP-triggered autonomous restart in `intelligence.js`) had nothing to match against for any service, ever — fixed to set it from the candidate's `raw_name` for docker-sourced candidates. Backfilled `container_name` for the 11 already-approved pn-vps services from their `discovery_candidates.raw_name`.
- **Found and fixed a live bug while wiring this up**: `actions.js`'s `userRoleLevel()` read `req.session.user.role` (singular) for the elevation check, but the only place a session's `user` object is ever populated (`routes/auth.js`, at the Keycloak callback) sets `.roles` (array). Every `/run/v2` elevation check had been silently 403ing every role since the endpoint was written — `ROLE_LEVEL[undefined]` always resolves to `-1`. Nothing had ever called `/run/v2` from the UI to expose this until now. Fixed by routing through the same `userRole()` helper `requireRole()` itself already uses. Verified directly in the running container (`-1` before, correct role level after).
- Frontend gained the UI that never existed for v2's response variants: a real blast-radius modal (hard-dependency list + "restart/stop anyway" force option) and a queued-for-approval toast.

Rebuilt and redeployed `privatenexus-backend`/`-frontend` on pn-vps; verified end-to-end (site 200, clean backend startup, services↔container join resolving all 11 containers correctly).

**Dashboard workspace view + Inventory status filter added (2026-07-15):** a source audit of the PRD's remaining `PARTIAL`/`MISSING` frontend rows (FE-01 through FE-08) found six of eight already fully built and just mis-tagged in the PRD (health history, recovery score, backup inventory, activity feed, admin panel, access-mode badges, missing-metadata flags — all verified in source, several running live on pn-vps). Two were genuine gaps, fixed in `hot-privatenexus` commit `ff5b346`:
- **FE-01** — the Home dashboard had an aggregate service-health summary but no breakdown by workspace (the "Workspaces" admin view is CRUD-only, not a dashboard panel). Added a "Workspaces" panel to Home showing healthy/total per workspace with click-through into Inventory grouped by workspace — no new fetch needed, `servicesData` already carried `workspace_name` from the existing backend join.
- **FE-02** — `GET /api/services` supported `category`/`workspace_id`/`archived` filters but not `status`, on either side. Added `?status=` (validated against the existing `VALID_STATUSES` list) and a matching dropdown in the Inventory toolbar next to the category filter.

Full corrected PRD status table: `/root/hot/docs/PrivateNexus_PRD_v1.0.md` §4.7 (commits `ebe488d`, `995810c`, and this one in `hot-config`).

**FE-09/10/11 audited (2026-07-15):** Catalogue (FE-09) was already accurately described in the PRD (static curated `APPS` array, category/search filter, no update-tracking yet — see roadmap v6.0) — verified in source, no change. Files board (FE-10) was mis-tagged `PARTIAL` — `routes/files.js` has 22 endpoints (read/draft/validate/write/apply/backups/restore/register), all 22 confirmed called from a substantial, fully-built frontend board. Logs board (FE-11) was fully built (Loki-backed, LogQL injection guards, filters) but had a real, live bug on pn-vps specifically — see the Promtail note above (`hot-config` commit `f80c6b1`): every log query was silently returning zero results until fixed. This closes out the full FE-01 through FE-11 PRD audit that started with the health-scheduler/recovery workstream earlier the same day.

**⚠ Intelligence board audit — closed a real container-blocklist bypass (2026-07-15, `hot-privatenexus` commit `1d8ed74`):** the autonomous remediation engine (`routes/intelligence.js`) has its own `container.restart` executor that calls Docker directly and never went through `actions.js`'s router — so it never got `actions.js`'s `CONTAINER_BLOCKLIST` protection (`privatenexus-db`/`privatenexus-redis` — restarting either mid-session causes data loss/session wipe, per that file's own comment). Reachable three ways, all funneling through the same executor: autonomous signal-driven execution (not exploitable here specifically — `container.restart` always requires human approval, never auto-executes), a human approving a pending remediation proposal (operator role, one click), and the MCP `pn_restart_service` tool. Dormant until earlier the same day: `services.container_name` was never populated by anything until the discovery-approval fix (commit `2043d30`), and `privatenexus-db`/`-redis` only got theirs backfilled as part of that change — before that, this exact code path could never target them at all. Both have since had `tcp://` health checks running continuously and stayed healthy throughout, so no dangerous proposal was ever actually generated (verified: zero rows in `remediation_proposals` for either container) — the gap was live and reachable, not yet triggered. Fixed by exporting `CONTAINER_BLOCKLIST` from `actions.js` and gating `intelligence.js`'s executor on it, matching the protection `/run` and `/run/v2` already had. **Lesson for future audits of this app:** any new container-control code path needs to check `CONTAINER_BLOCKLIST` explicitly — it is not enforced centrally at the Docker-client layer, only in `actions.js`'s own routes.

Also found, not fixed (low severity, noted for later): `POST /api/intelligence/incident` (AI-assisted incident response — restore-order BFS, confidence scores, pre-populated playbook) is fully implemented but not called from the frontend or the MCP server — orphaned, not a stub.

**⚠ DNS route audit — SOA/NS records had zero server-side protection (2026-07-15, `hot-privatenexus` commit `b2e8813`):** extended the container-blocklist audit to PowerDNS, the other system in PrivateNexus with real destructive-write capability against real production infrastructure (this manages the actual `house-of-trae.com`/`securenexus.net`/etc. zones — see PowerDNS section above, not a temp environment). Found the same bug class: `App.jsx`'s `LOCKED_TYPES = ["SOA","NS"]` only hid the edit/delete buttons for those record types in the React UI — `routes/dns.js`'s `POST`/`DELETE /api/dns/zones/:zone/records` had no type restriction at all, so any `operator`-role session could delete or overwrite a zone's own SOA/NS records via a direct API call (curl, devtools, a future MCP tool — none currently exists for DNS, but nothing would have stopped one), breaking DNS resolution for that entire domain. Fixed by adding the same `LOCKED_RECORD_TYPES` check server-side, returning 403 before any PowerDNS call. Checked the other candidate for this pattern (`policy_rules.built_in`, labeled "built-in" in the Governance board) and ruled it out — no delete endpoint exists for policy rules at all, only a reversible enable/disable toggle, so there's nothing to bypass.

**Governance board audit — missing audit trail across 3 route files (2026-07-15, `hot-privatenexus` commits `6f3ab9e`, `07ba00e`):** checked `governance.js` for the same shadow-bypass pattern as Intelligence/DNS — didn't find one (`admin_service_protected` is dashboard-only everywhere in the app consistently, by design, not a gap — `services.js`'s own `validate()` never cross-checks category+access_mode either). Found something different instead: `governance.js` imports `recordAudit` but never calls it anywhere in the file — `PATCH /rules/:key/toggle`, `POST /exceptions`, `DELETE /exceptions/:id` all had zero audit_log trail, ironic for the one board whose purpose is compliance auditing. Systematically checked every other route file's mutating-endpoint count against its actual `recordAudit()` call count to find the same pattern elsewhere: `services.js`'s workspace CRUD (`POST`/`PATCH`/`DELETE /workspaces`) and `recovery.js`'s `DELETE /simulations/:id` + `DELETE /restore-tests/:id` had the identical gap. The workspace DELETE case is the most notable — it silently reassigns member services to `workspace_id=NULL` before deleting, with no record of who did it or how many services were affected. Fixed all of them; also fixed `governance.js`'s exception DELETE to use `RETURNING` + a real 404 (it previously returned 200 even when nothing was deleted). Checked `dependencies.js` and `admin.js` too — both already had full coverage, no fix needed there. `recovery.js`'s `POST /playbook` is correctly unaudited — pure read/compute, no DB writes.

**Full backend route audit closed out (2026-07-15, `hot-privatenexus` commit `2894e76`):** finished reading all 19 route files in `app/backend/src/routes/` (last five: `ops.js`, `alerts.js`, `apps.js`, `auth.js`, `metrics.js`). `ops.js`/`alerts.js`/`metrics.js` are clean — read-only, viewer-gated, no injection risk. `apps.js` is a static app-launcher shortcut list (same pattern as Catalogue, not a gap). `auth.js` had one real find: only successful logins/logouts were ever audited — the OIDC callback's catch block (invalid state, expired code, Keycloak errors) only `console.error`'d, no `recordAudit` call. Failed logins are the more security-relevant case (brute force, CSRF/replay against the state/nonce check), so this was backwards. Fixed. This closes the safety/audit sweep started with the Intelligence board — every backend route file has now been checked for both bug classes found this session (shadow-bypass of an existing safety gate, and missing audit trail on a real mutation).

**MCP tool surface audited (2026-07-15, `hot-privatenexus` commit `a544be5`):** all 15 tools (9 read, 6 write). Auth model: MCP requests get synthesized as `{username: "mcp-server", roles: ["operator"]}` (`server.js`'s `X-MCP-Internal` middleware, ahead of `requireAuth`) — checked every write tool's backend route and confirmed all are `requireRole("operator")` or lower, so there's no privilege escalation available via MCP beyond what an operator can already do through the web UI. Every MCP-reachable write endpoint already has `recordAudit` coverage (will correctly attribute to `mcp-server` as actor). Argument validation is solid — parameterized SQL throughout, UUID regex on `proposal_id`. One real find: `pn_restart_service` → `POST /api/intelligence/service/:id/restart` had zero cooldown, unlike every restart path in `actions.js` — nothing in the frontend reaches this endpoint, only this MCP tool and the autonomous scanner do. Fixed by exporting `actions.js`'s `COOLDOWN_MS`/`actionCooldowns` and reusing them in `intelligence.js`'s executor (keyed by `container_name` — not perfectly unified with `actions.js`'s own ID-keyed cooldown, which would need an extra Docker inspect call to resolve consistently, but closes the actual "zero cooldown at all" gap). Also checked `mcp_token.txt`'s `644` permission against the discovery-agent-token pattern found earlier — ruled out here: `privatenexus-backend` (non-root) also reads this file to validate `X-MCP-Internal`, so it can't be tightened without breaking that.

Caddy's `privatenexus.net` block is temporarily pointed at `10.10.2.2:5173` instead of
`10.10.40.103:5173` — commented inline in the Caddyfile with the revert path. The frontend
container's port publish was changed from `127.0.0.1:5173:80` (in the source repo, unreachable
from another host) to `10.10.2.2:5173:80` (bound to the tunnel interface specifically) — binding
to `0.0.0.0` was deliberately avoided since Docker's own iptables rules are known to bypass UFW's
filtering for published ports; binding to the specific tunnel IP means Docker's NAT rule itself
never matches traffic to the public IP, which is more robust than relying on UFW alone. **Revert
Caddy and the port binding once bare metal is restored.**

Root password and the wg3 keypair are saved in Vaultwarden under the **PrivateNexus** folder
("pn-vps root password (Hostkey CH VPS)" and "pn-vps wg3 WireGuard tunnel keys"). A separate SSH
keypair (`tristian-termius-pn-vps`) was also generated for Mr. Byrne's direct Termius access,
scoped only to this VPS (not the shared fleet `claude_code_key`) — its private key is backed up
in the same Vaultwarden folder ("pn-vps Termius SSH key (tristian)").

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
| privatenexus    | PrivateNexus app users (dev/test env, pn-test + sn-personal) |

10 realms total. All realms: MFA enforced, brute force detection, strong password policy.
Keycloak OIDC API URL must point to realm root: `.../realms/<realm-name>` (NOT the protocol endpoint — causes 500 errors).

**WebAuthn/passkey policy (rolled out 2026-07-02, verified 2026-07-04 via admin API against all 10 realms):**
- 2FA WebAuthn policy: `rpId=house-of-trae.com`, signature algorithm `ES256`, `userVerification=preferred`
- Passwordless policy: same `rpId`/`ES256`, `userVerification=required`, `requireResidentKey=required`, `authenticatorAttachment=platform` (passkey-grade — platform authenticator + resident key forces a real synced/hardware passkey, not just any FIDO2 token)
- Required actions `webauthn-register` and `webauthn-register-passwordless` enabled (not default) on every realm — so users can register a passkey from their account console, but aren't force-enrolled
- Config is identical across all 10 realms including `master` — confirmed via `admin/realms/<realm>` and `admin/realms/<realm>/authentication/required-actions` REST calls, not just inferred from the commit message

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
  apex (placeholder), subdomains added as personal services deploy on pn-test
  Removed: nextcloud, vaultwarden, photos, notes, firefly, firefly-iii, actual, pn

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
SMS relay: Node.js sms-relay on sn-infra (Ntfy webhook → Twilio API).

---

## Backup Architecture

| Tier           | Tool                  | Schedule    | Destination             | Encryption                         |
|----------------|-----------------------|-------------|-------------------------|------------------------------------|
| VM snapshots   | vzdump (Proxmox)      | 02:00 daily | /var/lib/vz/dump (ZFS)  | zstd compressed                    |
| Config sync    | git + cron            | 01:00 daily | Forgejo → Codeberg + GH | Forgejo auth                       |
| Cloud (Hetzner)| rclone crypt          | 06:00 daily | Hetzner Storage Box     | rclone crypt (hetzner-crypt remote)|
| Cloud (B2)     | rclone crypt + B2     | 07:30 daily | Backblaze B2            | rclone crypt — hard_delete=true    |

Cron: 01:00 config sync → 02:00 vzdump (~3h, done ~05:00) → 06:00 Hetzner → 07:30 B2
⚠️ vzdump runs 3h on 7 VMs. Cloud uploads must NOT start before 06:00 — concurrent HDD I/O caused nightly crashes (Jun 26–28).
Config repo: /opt/hot-config → Forgejo (git.securenexus.net) + Codeberg + GitHub mirrors
Config repo: /opt/hot-config → Forgejo (git.securenexus.net) + Codeberg + GitHub mirrors

---

## Grafana Alerting

SMTP: mail.house-of-trae.com:587 via notifications@house-of-trae.com. Contact point: "email-hot" → tristian@securenexus.net.
Alert rules (folder "HoT Infrastructure Alerts"): Node Down (critical, 2m), Disk >85% (high), Disk >95% (critical), Memory >90% (warning), TLS cert <14d/<7d (via Blackbox Exporter — deployed, probing 17 endpoints).
Notification policy: group by severity/alertname/instance — group_wait 30s, repeat 1h for critical/high, 4h default.

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
Client private key for tristian: Vaultwarden — "ERPNext Onion Client Auth Key (tristian)".
Auth files: `/opt/stacks/tor/data/erp/authorized_clients/` (chown 100:101, chmod 600). Reload: `docker compose restart tor`.

⚠️ Backup: Gateway VPS is NOT a Proxmox VM. Losing `hs_ed25519_secret_key` means the onion address is permanently lost. Include `/opt/stacks/tor/data/erp/` in any VPS backup.
`data/` is never committed to git (only docker-compose.yml, Dockerfile, torrc are synced).

---

## Phase 4 — On the Horizon

- Wazuh SIEM on sn-security (VLAN 70)
- CrowdSec custom scenarios
- PrivateNexus PN-1 → PN-4 + Cosmos retirement
- HoT Sync (Flutter) — Immich + Nextcloud + Notesnook + Vaultwarden
- HoT Command (Flutter) — Mobile ops dashboard
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
| Tailscale sn-infra          | 100.99.183.4                                         |
| Tailscale sn-business       | 100.83.114.127                                       |
| Tailscale sn-web            | 100.77.95.127                                        |
| Tailscale sn-personal       | 100.118.105.9                                        |
| Tailscale sn-monitor        | 100.122.98.79                                        |
| Tailscale pn-test           | 100.64.178.97                                        |
| Tailscale sn-security       | 100.112.71.39                                        |
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
| PrivateNexus dev VM         | pn-test — VLAN 60, 10.10.60.105                      |
| This project directory      | /root/hot/                                           |
| Full roadmap                | /root/hot/docs/HoT_Infrastructure_State_Roadmap_v*.docx — use highest version present (currently v3.3), docx2txt |
| PN Phase 0 freeze           | /root/hot/docs/PrivateNexus_Phase0_Freeze.md         |

---
# End of CLAUDE.md — v2.0
# "Sometimes you gotta run before you can walk." — Tony Stark
