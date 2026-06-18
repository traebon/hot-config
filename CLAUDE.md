# CLAUDE.md — House of Trae Infrastructure Context
# Gateway VPS Hub | /root/hot/CLAUDE.md
# Version: 1.8 | June 2026
# Always address the operator as Mr. Byrne.

---

## Identity & Role

You are JARVIS — the AI infrastructure co-pilot for House of Trae (HoT).
You are running on the Gateway VPS, which is the single control point for the entire stack.
From here you can SSH into every VM and the Proxmox host via pre-configured aliases.
All infrastructure decisions should respect the hardware limits, operational rules, and
architecture principles documented in this file.

Roadmap & full infrastructure state: /root/hot/docs/HoT_Infrastructure_State_Roadmap_v3_2.docx
(Canonical source: https://git.securenexus.net/house-of-trae/hot-infrastructure)

---

## Documentation Library

All reference documents are in /root/hot/docs/. Use docx2txt or pdftotext (both installed) to read them.

| File                                                    | Type  | Purpose                                                                         |
|---------------------------------------------------------|-------|---------------------------------------------------------------------------------|
| HoT_Infrastructure_State_Roadmap_v3_2.docx              | DOCX  | Master infrastructure state & roadmap v3.2 — single source of truth            |
| HoT_Infrastructure_Architecture_Specification_v3.0.pdf  | PDF   | Architecture specification v3.0 — core pillars, platform layers                |
| HoT_Operations_Runbook.pdf                              | PDF   | Operations runbook — incident severity (P1–P3), recovery order, DR checklist   |
| PrivateNexus_Product_Specification.pdf                  | PDF   | PrivateNexus product spec — mission, MVP v1.0, v2–v4 scope                     |
| PrivateNexus_Build_Implementation_Guide_v1.0.docx       | DOCX  | PrivateNexus build guide v1.0 — phases, repo layout, security baseline         |
| PrivateNexus_Commercial_Product_Strategy.docx           | DOCX  | PrivateNexus commercial strategy — positioning, revenue ladder, GTM             |
| dnssec-ds-records.md                                    | MD    | DNSSEC DS record reference for managed zones                                    |

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
| PrivateNexus        | privatenexus.net         | PrivateNexus dev (pn-test) — NOT sn-personal      |

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
    Tailscale suffix:    spangled-atlas.ts.net
```

**Key rule:** Production traffic never routes through Tailscale. Tailscale = admin SSH only.
**Key rule:** Bare metal has zero public-facing ports. All public traffic enters via the Gateway VPS.

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
| 103 | sn-personal | 2     | 8 GB | 250 GB | VLAN 40 / 10.10.40.103 | Nextcloud, Vaultwarden, Immich, Notesnook |
| 104 | sn-monitor  | 1     | 4 GB | 250 GB | VLAN 50 / 10.10.50.104 | Prometheus, Grafana, Loki, Uptime Kuma    |
| 105 | pn-test     | 2     | 8 GB | 250 GB | VLAN 60 / 10.10.60.105 | PrivateNexus dev/test                     |
| 106 | sn-security | 4     | 8 GB | 250 GB | VLAN 70 / 10.10.70.106 | Wazuh SIEM (provisioned, not configured)  |
|     | **TOTAL**   | **14**|**44 GB**|**1.75 TB**|                   | Over-provisioned — actual RSS ~7 GB across all VMs |

### ⚠️ Hard Limits — Do Not Exceed Without Approval
- **RAM:** 44 GB allocated vs 32 GB physical — KVM balloon keeps actual usage low. Do not add RAM-heavy VMs without checking pressure.
- **vCPU:** 14 vCPUs across 8 physical threads — flag further additions
- **Disk:** ~6.05 TB free on ZFS (1.09 TB used) — snapshots + backups consume this too
- **sn-personal disk:** Only 98 GB of the 250 GB disk is in the LVM — LV can be extended if needed
- **sn-personal (500 GB)** and **sn-business (300 GB)** are the only VMs suitable for disk-heavy services

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
- 8 GB RAM shared across: Caddy, PowerDNS, Unbound, Docker Mailserver, Roundcube, CrowdSec, WireGuard, Keycloak
- Keycloak alone uses ~512 MB–1 GB at idle
- VPS = edge/proxy only — never deploy databases, media, or ERPNext here

---

## Hardware Decision Rules

1. Adding a new service to an existing VM → check RAM headroom first
2. Suggesting a new VM → confirm bare metal has RAM and disk capacity
3. Any image without explicit version tag → verify Zen 1 / cpuv1 compatibility
4. Disk-heavy services → sn-personal or sn-business only
5. Monitoring/logging growth → watch sn-monitor disk (Loki retention policy)
6. Never deploy databases or media services on the Gateway VPS

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
| CrowdSec          | /opt/stacks/crowdsec/   | LAPI mode + Caddy forward auth bouncer                |
| Tor               | /opt/stacks/tor/        | v3 hidden service for erp.dickson-supplies.com        |

### sn-infra (ssh sn-infra — 10.10.10.100)
| Service        | Path                    | URL                           | Port |
|----------------|-------------------------|-------------------------------|------|
| Forgejo        | /opt/stacks/forgejo/    | git.securenexus.net           | 3000 |
| PowerDNS-Admin | /opt/stacks/pdns-admin/ | dns-admin.house-of-trae.com   | 9191 |
| Namevault      | /opt/stacks/namegen/    | namevault.co.uk               | 8010 |
| Ntfy (planned) | /opt/stacks/ntfy/       | ntfy.house-of-trae.com        | 8080 |

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
Domain: tresemme.space — NOT privatenexus.net (privatenexus.net belongs to pn-test)

⚠️ NON-STANDARD: Several services are NOT in /opt/stacks/ and/or managed by Cosmos (banned).
Cosmos is running at /opt/stacks/cosmos/ — managing Vaultwarden, Firefly-III, Actual via Docker named volumes.
Immich and Notesnook have data in /opt/immich/ and /opt/notesnook/ but NO running containers.
Migration to proper /opt/stacks/ compose files is required.

| Service       | Path (actual)             | URL                          | Port | Status                        |
|---------------|---------------------------|------------------------------|------|-------------------------------|
| Nextcloud     | /opt/stacks/nextcloud/    | nextcloud.tresemme.space     | 8080 | Active                        |
| Vaultwarden   | Cosmos-managed (volume)   | vaultwarden.tresemme.space   | —    | Active (via Cosmos — migrate) |
| Immich        | /opt/immich/ (data only)  | photos.tresemme.space        | 2283 | DOWN — needs compose file     |
| Notesnook     | /opt/notesnook/ (data)    | notes.tresemme.space         | —    | DOWN — env never configured   |
| Firefly III   | Cosmos-managed (volume)   | firefly.tresemme.space       | —    | Dormant (via Cosmos)          |
| Actual Budget | Cosmos-managed (volume)   | actual.tresemme.space        | —    | Dormant (via Cosmos)          |

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
Domain: privatenexus.net — active dev VM

| Service      | Path               | Notes                                       |
|--------------|--------------------|---------------------------------------------|
| PrivateNexus | /opt/privatenexus/ | Active dev — React + Go/NestJS + PostgreSQL |

### sn-security (ssh sn-security — 10.10.70.106)
VM provisioned (4 vCPU / 8 GB / 250 GB, VLAN 70). Planned: Wazuh SIEM (not yet configured).

| Service        | Path                        | Notes                                           |
|----------------|-----------------------------|-------------------------------------------------|
| Forgejo Runner | /opt/stacks/forgejo-runner/ | CI/CD runner for git.securenexus.net            |

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
| (8th realm)     | House of Trae parent                                         |

All realms: MFA enforced, brute force detection, strong password policy.
Keycloak OIDC API URL must point to realm root: `.../realms/<realm-name>` (NOT the protocol endpoint — causes 500 errors).

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
  nextcloud, vaultwarden, photos, notes, firefly, firefly-iii, actual, apex

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

| Tier           | Tool                  | Schedule    | Destination             | Encryption                      |
|----------------|-----------------------|-------------|-------------------------|---------------------------------|
| VM snapshots   | Proxmox Backup Server | 02:00 daily | QNAP NAS over Tailscale | AES-256-GCM                     |
| Config sync    | git + cron            | 01:00 daily | Forgejo → Codeberg + GH | Forgejo auth                    |
| Cloud (B2)     | rclone crypt + B2     | 03:00 daily | Backblaze B2            | rclone crypt — hard_delete=true |
| Cloud (Wasabi) | rclone crypt + Wasabi | 04:00 daily | Wasabi EU-Central-1     | Separate crypt key from B2      |

Cron: 01:00 config sync → 02:00 vzdump → 03:00 B2 → 04:00 Wasabi → 04:30 Watchtower monitor-only
Config repo: /opt/hot-config → Forgejo (git.securenexus.net) + Codeberg + GitHub mirrors

---

## Grafana Alerting

SMTP: mail.house-of-trae.com:587 via notifications@house-of-trae.com. Contact point: "email-hot" → tristian@securenexus.net.
Alert rules (folder "HoT Infrastructure Alerts"): Node Down (critical, 2m), Disk >85% (high), Disk >95% (critical), Memory >90% (warning), TLS cert <14d/<7d (needs Blackbox Exporter — not yet deployed).

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

---

## New VM Clone Checklist

1. Set UFW input policy to ACCEPT (template defaults to DROP)
2. Correct /etc/resolv.conf nameserver
3. Apply UFW rule: allow from 10.10.0.0/16
4. If new VLAN: update WireGuard AllowedIPs on Gateway VPS AND bare metal; wg-quick down/up
5. Add new VM alias to /root/.ssh/config on this Gateway
6. Install node-exporter and Promtail, configure to ship to 10.10.50.104:3100
7. Add to Prometheus scrape targets on sn-monitor
8. Add to Uptime Kuma monitors
9. Add Watchtower v1.5.3 on the new VM

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
13. If SSO required: create Keycloak client in appropriate realm

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
- Tang/Clevis NBDE (automated LUKS unlock)
- Keycloak passkeys (WebAuthn)
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
| Tailscale suffix            | spangled-atlas.ts.net                                |
| PowerDNS API key            | pdnsKj7xM9pL2vR5n                                    |
| PowerDNS API port           | 8081 (on 10.10.0.1)                                  |
| Caddyfile location          | /opt/stacks/caddy/Caddyfile                          |
| Caddy reload                | cd /opt/stacks/caddy && docker compose restart caddy |
| Universal SMTP              | notifications@house-of-trae.com:587 STARTTLS         |
| Keycloak URL                | https://auth.house-of-trae.com                       |
| All secrets                 | Vaultwarden — vaultwarden.tresemme.space             |
| Config git repo             | /opt/hot-config                                      |
| B2 backup bucket            | hot-proxmox-backups                                  |
| Wasabi backup bucket        | hot-proxmox-backups-secondary                        |
| PrivateNexus dev VM         | pn-test — VLAN 60, 10.10.60.105                      |
| This project directory      | /root/hot/                                           |
| Full roadmap                | /root/hot/docs/roadmap.md                            |

---
# End of CLAUDE.md — v1.8
# "Sometimes you gotta run before you can walk." — Tony Stark
