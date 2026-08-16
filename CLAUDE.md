# CLAUDE.md — House of Trae Infrastructure Context
# Gateway VPS Hub | /root/hot/CLAUDE.md
# Version: 2.1 | August 2026 — split into topic files 2026-08-16, see docs/HoT_Streamlining_Scope.md (track 2)
# Always address the operator as Mr. Byrne.

---

## Identity & Role

You are JARVIS — the AI infrastructure co-pilot for House of Trae (HoT).
You are running on the Gateway VPS, which is the single control point for the entire stack.
From here you can SSH into every VM and the Proxmox host via pre-configured aliases.
All infrastructure decisions should respect the hardware limits, operational rules, and
architecture principles documented across this file and its `claude-md/` imports below.

Roadmap & full infrastructure state: /root/hot/docs/HoT_Infrastructure_State_Roadmap_v*.docx (use the highest version present — superseded versions live in docs/archive/roadmap-versions/, not the top level, so the glob only ever matches the current one)
(Canonical source: https://git.securenexus.net/house-of-trae/hot-infrastructure)

---

## Documentation Library

All reference documents are in /root/hot/docs/. Use docx2txt or pdftotext (both installed) to read them.

**Docs cleanup, 2026-08-16:** superseded roadmap versions (v3.2–v3.5), all 16 closed
`PrivateNexus_Security_Report_Tier4–19.md` files, and the duplicate `.txt` build guide were moved
into `docs/archive/` (not deleted — `/root/hot` isn't a git repo, so archiving keeps them
recoverable). Loose screenshots/certs moved into `docs/screenshots/` and `docs/certs/`. See
`docs/HoT_Streamlining_Scope.md` (track 1) for the full rationale.

| File                                                    | Type  | Purpose                                                                         |
|---------------------------------------------------------|-------|---------------------------------------------------------------------------------|
| HoT_Infrastructure_State_Roadmap_v*.docx                | DOCX  | Master infrastructure state & roadmap — single source of truth (highest version) |
| HoT_Infrastructure_Architecture_Specification_v3.0.pdf  | PDF   | Architecture specification v3.0 — core pillars, platform layers                |
| HoT_Operations_Runbook.pdf                              | PDF   | Operations runbook — incident severity (P1–P3), recovery order, DR checklist   |
| PrivateNexus_Product_Specification.pdf                  | PDF   | PrivateNexus product spec — mission, MVP v1.0, v2–v4 scope                     |
| PrivateNexus_Build_Implementation_Guide_v1.0.docx       | DOCX  | PrivateNexus build guide v1.0 — phases, repo layout, security baseline. (A duplicate hand-extracted `.txt` copy was archived to `docs/archive/` 2026-08-16 — this `.docx` is canonical.) |
| PrivateNexus_Commercial_Product_Strategy.docx           | DOCX  | PrivateNexus commercial strategy — positioning, revenue ladder, GTM             |
| PrivateNexus_Phase0_Freeze.md                           | MD    | Phase 0 locked decisions — Node.js Express backend, stack freeze, v1.0 scope   |
| PrivateNexus_Release_Roadmap_v1.0.md                    | MD    | Detailed release roadmap v0.8 → v5.0 with sprints, acceptance gates, risks     |
| PrivateNexus_PRD_v1.0.md                                | MD    | Product Requirements Document — current build state, all functional reqs, gaps |
| PrivateNexus_Multitenancy_RBAC_Design.md                | MD    | Multi-tenancy and RBAC design — schema, isolation rules, migration path         |
| PrivateNexus_Security_Lockdown_Mode_Design.md            | MD    | Security lockdown mode design (v6.0 gate item) — tier model, Wazuh/CrowdSec integration, scoped+locked 2026-07-30, not yet built |
| PrivateNexus_Catalogue_Deploy_Flow_Scope.md               | MD    | Catalogue-driven deploy flow scope (item 21 follow-on) — Cosmos-style pick/customize/review-compose/deploy flow, scoped 2026-08-10, **Phase 1 (Nextcloud) and Phase 2 (Notesnook) both confirmed working end-to-end same day** — see hot-pn section below |
| PrivateNexus_Commercial_Packaging_Licensing.md          | MD    | Commercial packaging — edition model, pricing logic, open-core boundary, GTM   |
| dnssec-ds-records.md                                    | MD    | DNSSEC DS record reference for managed zones                                    |
| HoT_Bare_Metal_Migration_Checklist.md                   | MD    | Hostkey bare-metal server replacement — phased migration/rebuild checklist      |
| PrivateNexus_Security_Report_Tier4.md ... Tier19.md      | MD    | Progressive PrivateNexus security assessment series (Tiers 1-3 predate this archive) — infra exposure, RBAC, injection, deploy pipeline, dependency CVEs. All findings fixed; Tier 19 (25 Jun 2026) is the final/most recent tier. **Moved to `docs/archive/security-reports/` 2026-08-16** (all 16 closed/superseded, kept for historical reference only). |

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

### Domain Assignment Policy (added 2026-08-16, streamlining track 4)

Added after repeated ad-hoc re-derivation of "which domain does a new service go under" — no
documented rule existed across 13 managed zones, and the same class of dead-DNS-record incident
(Cosmos-era leftovers) recurred independently on two different domains (`tresemme.space`, then
`privatenexus.net`'s wildcard `A` record) before anyone connected them. See
`docs/HoT_Streamlining_Scope.md` (track 4) for the fuller rationale.

**Assignment order — first rule that applies wins:**

1. **Client-facing product/site for a group entity** (Stratus Digital, Discreet Elite, Emerald
   Markets, Byrne Accounts) → that entity's own domain. Not negotiable — it's the entity's public
   identity.
2. **Admin/infra tooling** → depends on how it authenticates, not just "it's infra":
   - Native Keycloak OIDC client (registered directly against a realm — e.g. Forgejo, PowerDNS-Admin,
     Grafana's own login, ERPNext, Wazuh dashboard) → `securenexus.net` (SecureNexus's documented
     role is "cyber security, monitoring, infra management") — the app's own OIDC flow doesn't care
     which domain it's served from.
   - Gated by the shared generic `import sso` (oauth2-proxy) wall instead of native OIDC (e.g.
     Uptime Kuma admin, Prometheus's raw UI) → **must be `house-of-trae.com`**, full stop — this is
     a hard technical constraint, not a style preference (see the checklists.md SSO section: the
     shared oauth2-proxy's callback is fixed to a `house-of-trae.com` URL, and a CSRF cookie scoped
     to any other domain can never reach it — this exact bug already happened once, on
     `monitor.securenexus.net`/`prometheus.securenexus.net`, and both had to be moved).
   - IP-allowlisted instead of SSO-gated at all (e.g. `gatus.securenexus.net`,
     `rspamd.securenexus.net`) → `securenexus.net` is fine, no domain constraint applies.
3. **PrivateNexus product/deployment surface** → `privatenexus.net`, and *only* things that are
   actually part of PN's own product surface. Not a dumping ground for personal services deployed
   through it — the wildcard-`A`-record incident happened specifically because Cosmos-era personal
   subdomains were left registered here after the services themselves were gone. If the Catalogue
   deploy flow (see hot-pn section) is ever wired to real public DNS instead of staying
   `127.0.0.1`-only, treat that as its own deliberate decision, not an automatic
   `privatenexus.net` subdomain grant.
4. **Personal services** (e.g. a future Phase 4 "HoT Sync") → no default domain right now.
   `tresemme.space`'s original use case (pn-test/sn-personal) is retired outright; don't default new
   personal-services work to `privatenexus.net` or silently reuse `tresemme.space` — this needs an
   explicit decision when the work is actually scoped.
5. **Parent/shared infra with no natural entity home** (SSO itself, mail, DNS, Vaultwarden, the Tor
   mirror, Ntfy, monitoring dashboards behind the generic SSO wall) → `house-of-trae.com`, per its
   documented "Parent — shared services" role.

**Decommission rule**, from the two repeated incidents above: when a service is torn down, delete
its DNS records — the specific name *and* any wildcard that could backfill it — the same day, not
"whenever someone notices." Both incidents were the same root gap recurring on two different
domains weeks apart.

---

## Detailed Reference (imported)

This file was split 2026-08-16 (streamlining track 2 — see `docs/HoT_Streamlining_Scope.md`) from a
single 1,191-line monolith into topic files under `claude-md/`, imported below via Claude Code's
`@path` syntax. **Note this is organizational, not a context-size win** — imported content still
loads in full at session start, same as before. The benefit is a smaller, single-topic file to find
and edit per change instead of scrolling one huge file. Each imported file targets under 200 lines
per Claude Code's own sizing guidance.

@claude-md/network.md
@claude-md/hardware.md
@claude-md/services-fleet.md
@claude-md/services-hoterp.md
@claude-md/services-hotpn.md
@claude-md/identity-dns-email.md
@claude-md/alerting-backups.md
@claude-md/automated-patching.md
@claude-md/operational-rules.md
@claude-md/checklists.md
@claude-md/tor.md
@claude-md/roadmap.md

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
# End of CLAUDE.md — v2.1
# "Sometimes you gotta run before you can walk." — Tony Stark
