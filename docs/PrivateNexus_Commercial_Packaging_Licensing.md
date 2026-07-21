# PrivateNexus — Commercial Packaging & Licensing Plan
**Version: 1.0**
**Date: 22 June 2026**
**Owner: House of Trae / PrivateNexus Programme**
**Classification: Internal — Strategic**

---

## 1. Strategic Context

PrivateNexus is currently an internal tool for House of Trae, running at v1.9 on pn-test.
Before any commercial packaging decision is made, the product must pass two internal gates:

1. **House of Trae relies on it daily** — not just runs it, but actually uses it to operate
   the estate during incidents, health monitoring, and recovery planning.
2. **Recovery intelligence is proven in practice** — at least one real incident where
   PrivateNexus provided actionable restore guidance that was used.

**Rule:** Do not over-monetise too early. Revenue before product trust is reputational risk.

This document defines the packaging model, pricing logic, and go-to-market path to be
used when the product is ready for external audiences. It is a planning reference, not
an active commercial operation.

---

## 2. Product Category and Positioning

**Category:** Infrastructure Operations Platform (IOP)

**What it is:** A governed visibility, recovery, and safe-action layer above self-hosted
infrastructure tools (Docker, Proxmox, Caddy, Keycloak, PowerDNS, Grafana, backup systems).

**What it is not:** A Proxmox replacement, a Portainer clone, an identity provider, a DNS
authority, or a monitoring database.

**Primary differentiator:** Recovery intelligence at homelab and SMB simplicity and
self-hosted price. No tool in the self-hosted/homelab/SMB segment provides:
- Dependency-aware restore planning
- Trust-state backup inventory
- Sandbox-validated recovery scores

That is the wedge. All commercial materials must state it this way. "Recovery intelligence"
alone is not unique in 2026 — enterprise tools (Veeam, AWS Backup) use the same phrase.
The qualifier — **self-hosted, SMB-simple, homelab-priced** — is what makes it defensible.

---

## 3. Edition Model

### 3.1 Three editions

| Edition | Audience | Price model | Tenant model |
|---|---|---|---|
| **Community** | Self-hosters, homelab operators | Free, open source (Apache 2 or MIT) | Single tenant |
| **Professional** | Small businesses, MSPs, consultants | Paid licence / subscription | Multi-tenant |
| **Managed** | Customers who do not want to self-host | Hosted SaaS, per-tenant fee | Hosted by HoT / SecureNexus |

### 3.2 Community Edition

**Goal:** Adoption, trust, feedback, and community-driven discovery.

**Who it is for:** Homelab operators, advanced self-hosters, solo technical operators.
These users are the primary feedback engine and early adopters who will refer Professional
buyers when they grow into a business context.

**What it includes:**
- Single-tenant installation
- Service inventory (full CRUD, workspaces, access modes)
- HTTP and TCP health checks
- Backup record visibility (manual entry)
- Restore planner (dry-run, risk assessment)
- Basic recovery score (heuristic — backup age, trust state, not tested)
- Audit log (full, local)
- Safe actions: restart, health refresh, maintenance mode
- Keycloak SSO (self-hosted Keycloak required — documented)
- Docker Compose installation
- Community support (GitHub Issues / Discussions)

**What it does NOT include:**
- Multi-tenant management
- Automated discovery agents
- Sandbox restore testing (recovery score becomes proven)
- Governance reports and recommendations feed
- Action policy engine
- Dependency graphs
- Priority support

**Licence:** Open source. The core product (Community Edition) is fully open.
Professional features are closed source, delivered as a licence-gated plugin or a
separate container that the Community Edition can optionally connect to.

### 3.3 Professional Edition

**Goal:** Revenue from the segment that benefits most — small businesses, MSPs, consultants
running infrastructure for clients or operating multi-site environments.

**Who it is for:**
- Small businesses with a dedicated IT operator (2–20 technical users)
- MSPs managing infrastructure for multiple clients
- Consultants who need to present recovery readiness to clients

**What it includes (in addition to Community):**
- Multi-tenant workspace (unlimited tenants)
- Automated discovery agents (Docker labels, Proxmox API, Caddy routes)
- Sandbox restore testing → proven recovery score
- Dependency graphs and blast-radius analysis
- Restore chain planner (dependency-ordered restore sequences)
- Governance engine: policy checks, recommendations feed
- Client-ready governance reports (PDF / JSON export)
- Advanced audit log: date range export, retention policy configuration
- Action policy engine: declarative policies, approval workflows
- Priority email support (next-business-day response)
- Licence tied to number of managed nodes or tenants (see §4)

**What it does NOT include:**
- Hosting — operator runs their own instance
- Managed updates — operator manages upgrades
- SLA guarantees — Professional edition is self-operated

### 3.4 Managed Edition

**Goal:** Recurring revenue from customers who want the value but not the operational overhead.

**Who it is for:**
- Small businesses without a dedicated infrastructure operator
- Clients of SecureNexus / House of Trae managed services
- Operators who want PrivateNexus but do not want to manage its hosting

**What it includes:**
- Hosted PrivateNexus instance managed by SecureNexus
- All Professional Edition features
- Lightweight agents installed on customer infrastructure
- Managed updates and backups of the PrivateNexus platform itself
- Monthly health and recovery readiness reports delivered to client
- Monitored by sn-monitor (existing HoT monitoring stack)
- SLA: 99.5% uptime target for the PrivateNexus control plane
- Support: dedicated support contact, 4-hour response for critical issues

**Billing:** Monthly or annual subscription per tenant / per node.

---

## 4. Pricing Logic

**Principle:** Price on value delivered, not on artificial feature gates. The
recovery confidence report is worth more to a business than a health dashboard —
price that way.

### 4.1 Community Edition

Free. No trial period. No feature expiry. The Community Edition is a genuine product,
not a lead-gen crippleware demo.

### 4.2 Professional Edition — suggested pricing tiers

| Tier | Nodes managed | Price |
|---|---|---|
| Small | Up to 10 nodes | £49/month or £490/year |
| Business | Up to 50 nodes | £149/month or £1,490/year |
| MSP | Unlimited nodes, up to 20 tenants | £349/month or £3,490/year |

A **node** is defined as a VM, physical host, or external service registered in PrivateNexus.
The Gateway VPS, Proxmox host, and each VM each count as one node.

HoT estate = 9 nodes (Gateway VPS + bare metal + 7 VMs). Small tier.

**Note:** These are indicative figures for planning. Final pricing requires market
validation — test with the first external customer before publishing a pricing page.

### 4.3 Managed Edition — suggested pricing

| Tier | Managed nodes | Monthly fee |
|---|---|---|
| Starter | Up to 10 nodes | £199/month |
| Growth | Up to 50 nodes | £499/month |
| Partner | Unlimited, white-label option | Negotiated |

Managed Edition pricing includes the hosting cost (pn-test or a dedicated VM per
large client). Margin must cover: VM cost, time for updates, incident response, reporting.

---

## 5. Proof Points Required Before External Launch

These must all be true before any public Community Edition release.

| Proof point | Why it matters |
|---|---|
| Stable install from scratch on a clean VM | Nobody pays for or recommends a painful install |
| Documented upgrade path v1.0 → v1.x | Commercial users need upgrade confidence |
| Recovery planner used during at least one real HoT incident | Differentiator must be proven, not claimed |
| RBAC tested with two users in separate roles | Business credibility requires real access control |
| Audit log verified for all v1.0 action types | Business customers require accountability |
| All House of Trae services registered and health-checked | PN must be battle-tested on its own creator's estate |
| Documentation written for a stranger to follow | Repeatability beyond the creator is required for commercial viability |
| No critical open security issues | Required before any public release |

---

## 6. Go-To-Market Path

### Stage 1 — Internal (now → v1.0)
Use House of Trae as the proving ground. Build daily reliance.
Document real problems solved. Collect specific examples of PN providing value during
an incident or health review.

### Stage 2 — Community Edition launch (v1.0 → v1.5)
- Publish GitHub repository (open source core)
- Write public documentation: install guide, upgrade guide, demo walkthrough
- Target: advanced self-hoster communities (r/selfhosted, Reddit, HomeLabOS forums,
  LinuxServer.io, Homelab subreddit)
- No paid advertising at this stage — community-driven discovery only
- Collect feedback; identify the top 3 pain points the product does not yet solve

### Stage 3 — Professional Edition preview (v1.5 → v2.0)
- Announce Professional Edition plans publicly
- Offer early access to 2–3 MSP or small-business beta customers (free or heavily discounted)
- Focus beta on multi-tenant, discovery agents, and recovery score validation
- Build case studies from beta customers

### Stage 4 — Professional Edition GA (v2.0)
- Publish pricing page
- Target: MSPs and small businesses via content marketing (recovery intelligence,
  "do you know if your backups actually work?")
- SecureNexus can market PrivateNexus as part of a managed services package

### Stage 5 — Managed Edition (v2.5+)
- Offer Managed Edition to SecureNexus clients who already have a managed relationship
- Do not build a self-service signup for Managed Edition — operate it as a concierge
  service initially

---

## 7. Open-Core Boundary

The open-core split is the most important commercial architecture decision after the product
itself. Getting it wrong either kills adoption (too much closed) or kills revenue (too much free).

**Principle:** Everything needed to run a useful single-tenant PrivateNexus instance should
be in the Community Edition. The Professional tier earns revenue by solving the problems
that only appear at scale or in commercial contexts.

### 7.1 What must stay free (Community)

Locking these would kill homelab adoption and damage the community trust that feeds Professional:
- Service inventory
- Health checks
- Backup record visibility
- Restore planner (dry-run)
- Audit log
- Safe actions (restart, health refresh, maintenance mode)
- Single-tenant RBAC

### 7.2 What belongs in Professional

These features only make sense at multi-tenant / multi-user scale, or require additional
infrastructure investment (sandbox restore environments):
- Multi-tenant management
- Automated discovery agents
- Sandbox restore testing (proven recovery score)
- Dependency graphs and restore chain planner
- Governance engine and recommendations feed
- Client-ready reports (PDF / JSON export)
- Action policy engine and approval workflows
- Advanced audit log export and retention controls
- Priority support

### 7.3 Avoid these mistakes

- Do not gate health checks or audit logs in the Community Edition — operators need these
  and locking them breeds resentment, not upgrades
- Do not add artificial user-count limits to Community — one-person homelabs are often
  the entry point for future MSP buyers
- Do not release a "freemium" version that silently degrades — Community Edition must
  be a complete, useful product with no hidden timers

---

## 8. Competitive Positioning Summary

| Competitor | Strength | Why PN wins in its segment |
|---|---|---|
| Portainer | Container management, huge community | PN wraps approved actions in policy; does not expose raw container power |
| Komodo | Multi-server, config-as-code, good automation | PN adds recovery intelligence and governance; Komodo is deployment-centric |
| NetBox Labs | Infrastructure intelligence, enterprise-grade | Enterprise-priced, network/DCIM-centric. PN targets service-level recovery at SMB price |
| Coolify | PaaS deployment, MCP server, great DX | Deployment-centric, not recovery-centric. PN's own MCP server shipped read-only in v2.0 and read-write (operator-scoped) in v5.0 — parity here already, differentiation is recovery intelligence, not deploy automation |
| Glance / Homepage | Minimal, fast, no database | The "good enough" threat for casual users. PN must justify its depth with recovery + governance |

**The segment PN owns:** Self-hosted infrastructure with recovery confidence requirements,
operated by small teams or solo operators who cannot afford enterprise DR tooling.

---

## 9. Revenue Projections (Indicative)

Not a financial model — these are indicative targets to validate before external launch.

| Stage | Target | Revenue indicator |
|---|---|---|
| Community launch | 100 GitHub stars, 10 active installs in 90 days | Validation of market fit |
| Professional preview | 3 paying beta customers | Product-market fit signal |
| Professional GA | 10 paying customers (£490–£1,490/year each) | £5,000–£15,000 ARR |
| Managed Edition | 3 managed clients | £600–£1,500/month recurring |
| Growth | 50 Professional + 10 Managed | ~£30,000–£50,000 ARR |

These numbers are small by SaaS standards. The goal at this stage is not hypergrowth —
it is building a product the HoT group relies on, proving the recovery intelligence
differentiator, and establishing a sustainable revenue stream that funds further
PN development without external funding dependency.

---

*Document owner: House of Trae / PrivateNexus Programme*
*Next revision trigger: Community Edition launch decision, first external customer*
*Related: `PrivateNexus_Commercial_Product_Strategy.docx`, `PrivateNexus_Release_Roadmap_v1.0.md`*
