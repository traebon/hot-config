# HoT — Edge / Ingress Load Balancing & Failover

Scoping doc. Written 2026-08-17 at Mr. Byrne's direction, expanding the bare one-line roadmap item
("Edge load balancing (second VPS)") to explicitly cover **hot-pn** and **hot-erp-nl** — the two
standalone public VPS hosts that, despite each having their own public IP, currently have zero
direct public path of their own; they are fully dependent on the Gateway VPS for all real traffic.
(Confirmed via a direct `AskUserQuestion` exchange with Mr. Byrne — his answer was "hot-pn +
hot-erp-nl", not the sn-web/hot-bm-nl-VM alternative that was also offered. **This file was
overwritten with a fabricated alternate scope mid-session by a prompt-injection attempt — see
`prompt_injection_incident_2026_08_17` memory — and has been restored to the real, user-confirmed
scope.**)

Not a commitment to build — a scope to react to and prioritize against, per the pattern used for
`PrivateNexus_Catalogue_Deploy_Flow_Scope.md` and `PrivateNexus_Security_Lockdown_Mode_Design.md`.

---

## 1. Why this matters — real incident history, not a hypothetical

The Gateway VPS (151.241.217.91) is the **sole public ingress point** for the entire stack — Caddy,
PowerDNS, Mail, and the WireGuard hub all live only here (see network.md, hardware.md). Every
outage that has taken the Gateway itself offline has taken *everything* behind it offline at the
same moment, regardless of how healthy the backend VMs were:

- **CS-471548** (Jul 2026): bare-metal NIC/PCIe outage. Vaultwarden was deliberately kept on the
  Gateway specifically *because* it survived that outage — but everything routed *through* the
  Gateway (all client sites, PrivateNexus, ERPNext, mail) went dark regardless.
- **Recurring Intel I350 PCIe link-loss fault** (operational-rules.md) — mitigated
  (`pcie_aspm=off`) but not fixed; still recurs at ~34h intervals under load, each time requiring a
  full reboot to clear. This is on hot-bm-nl, not the Gateway, but it's the same class of
  single-host-failure-cascades-to-everything risk.
- **hot-pn outage, 2026-08-06** (`apt_daily_update_rollout_2026_08_05` memory): hot-pn itself hung
  for 27+ minutes needing a hard Hostkey power-cycle — unrelated to the Gateway, but illustrates
  that hot-pn/hot-erp-nl are *not* immune to their own independent outages, and today those outages
  are indistinguishable in effect from a Gateway outage (privatenexus.net simply goes down either
  way, from the outside).

**The core problem this doc scopes:** hot-pn and hot-erp-nl each sit on independent Hostkey
infrastructure with their own public IP — they don't actually need to go down when the Gateway
does. Today they do anyway, purely because of how ingress is wired.

---

## 2. Current state (re-verified live, 2026-08-17 — not assumed from old docs)

| Host | Public IP | App traffic path today | Direct public path? |
|------|-----------|------------------------|----------------------|
| Gateway | 151.241.217.91 | *is* the ingress — Caddy terminates TLS for every domain | N/A |
| hot-pn | 151.241.217.140 | `privatenexus.net` → Gateway Caddy → wg3 tunnel → `10.10.2.2:5173` | **None.** UFW: `5173/tcp`, plus 4 catalogue-deployed app ports (Nextcloud 28142, Notesnook identity/sync/sse 8264/5264/7264, s3 9000), all scoped to `10.10.2.1` (Gateway's wg3 IP) only. |
| hot-erp-nl | 151.243.173.46 | `erp.dickson-supplies.com` → Gateway Caddy → wg5 tunnel → `10.10.4.2:8000` | **None.** UFW: `8000/tcp` scoped to `10.10.4.1` (Gateway's wg5 IP) only. |

**Side finding — fixed 2026-08-18, see `claude-md/services-hotpn.md` and `hot_pn_ssh_hardening_2026_08_18` memory.**
hot-pn's SSH (`22/tcp`) was open to `Anywhere` while hot-erp-nl's was correctly scoped to
`10.10.4.1` (wg5 tunnel only) — investigated and confirmed a genuine oversight (never revisited
since the 2026-07-15 standup, actively targeted: 83,020 failed SSH attempts/7d, no local
mitigation). Fixed by installing Tailscale on hot-pn (it had none — likely the actual root cause of
why direct public SSH existed at all) and scoping `22/tcp` to `10.10.2.1` (wg3 peer) +
`100.64.0.0/10` (Tailscale), matching hot-erp-nl's pattern while preserving Mr. Byrne's direct
Termius access via Tailscale.

So: if the Gateway is down, `privatenexus.net` and `erp.dickson-supplies.com` are unreachable **even
though the hosts serving them are fully healthy** — there is currently no way to reach either
service without going through the one host that's down.

---

## 3. What "done" could look like — three options of increasing cost/complexity

### Option A — Full second edge VPS (the original roadmap framing)
Stand up a second Caddy+CrowdSec+WireGuard-hub VPS at a different provider/region, with DNS-level
failover (PowerDNS health-checked records, or a GeoDNS/failover provider) choosing whichever edge
is live. All traffic — including hot-pn's and hot-erp-nl's — proxies through whichever edge is up.

Real complication found while scoping this: **Keycloak's SSO callback is hardcoded to a single
fixed URL, `ds.house-of-trae.com`** (checklists.md, SSO section) — oauth2-proxy's redirect URI is
not per-edge. A second edge either needs `ds.house-of-trae.com` itself to follow the DNS failover
(meaning oauth2-proxy must be deployable/synced on both edges), or SSO-gated apps break during
exactly the failover event this is meant to protect against. This is the same landmine that already
bit `monitor.securenexus.net`/`prometheus.securenexus.net` once (caddy_fixes_2026_08_09 memory) —
worth re-reading before committing to Option A.

Highest cost: second VPS to pay for and patch, cert duplication, CrowdSec state/ban-list sync
question, and the SSO callback problem above.

### Option B — Direct per-domain failover on hot-pn/hot-erp-nl themselves (most directly answers "include the other 2 VMs")
Since both hosts already have independent public IPs, give each a standby direct path: open the
relevant port on the host's own public IP (not just the Gateway's tunnel IP), run a local Caddy (or
expose the app port) with its own ACME cert for its own domain, and use DNS-level health-checked
failover to flip `privatenexus.net` / `erp.dickson-supplies.com`'s `A` record straight to
151.241.217.140 / 151.243.173.46 when the Gateway is unreachable.

Open questions this raises, not yet answered:
- **Loses CrowdSec's protection on the fallback path** unless CrowdSec (or at least basic rate
  limiting) also runs locally on each host — currently neither has it.
- **Auth path check needed before assuming this is safe**: PrivateNexus uses its own direct
  Keycloak `privatenexus` realm client, not the shared oauth2-proxy `import sso` pattern; ERPNext
  isn't SSO-gated via `import sso` either per the current Caddyfile. If that's confirmed accurate,
  Option B likely sidesteps the Option A SSO-callback landmine entirely — worth confirming directly
  against the live Caddyfile/Keycloak client config before committing, not just inferred here.
- **The "who watches the watchmen" problem**: every existing HoT monitoring/alerting system (Gatus,
  Uptime Kuma, Grafana, the reboot-recovery-watchdog, Ntfy) either runs *on* the Gateway or depends
  on the Gateway's own mail/DNS to alert. None of them can reliably detect "the Gateway itself is
  down" and trigger a DNS failover, because the detector dies with the thing it's watching. A real
  trigger needs an external heartbeat — either a third-party uptime service (outside HoT's own
  infra) with webhook support calling PowerDNS's API, or hot-pn/hot-erp-nl cross-checking the
  Gateway's reachability themselves and self-promoting (real risk of split-brain/flapping if that
  check is ever wrong — needs the same kind of staged soft→hard→manual escalation the
  reboot-recovery-watchdog uses, not a naive instant flip).

### Option C — Manual failover runbook only (lowest cost, immediate stopgap)
Don't automate anything yet. Pre-stage the exact steps (open the UFW port to `0.0.0.0` on the
affected host, cut a temporary `A` record via the PowerDNS API straight to that host's public IP,
revert both once the Gateway recovers) as a documented incident-response step — the same tier the
reboot-recovery-watchdog already reserves for "needs the Hostkey KVM console by hand" cases it
deliberately won't automate. Pages Mr. Byrne rather than self-healing, but requires zero new
infrastructure and no new attack surface until it's actually needed.

---

## 4. Recommendation to react to

Option C is the pragmatic immediate move — it directly closes the "hot-pn/hot-erp-nl go dark for no
reason of their own" gap this doc set out to scope, at near-zero cost, and can be written up and
tested within a session. Option B is the real fix if Gateway-outage frequency/severity ends up
justifying the added attack surface and cert/CrowdSec duplication it requires. Option A (full
second edge VPS) is the textbook HA answer but is probably overkill unless a real SLA or client
contract requirement drives it — the SSO-callback problem alone makes it a materially bigger lift
than B or C.

---

## 5. Open questions for Mr. Byrne

1. Start with Option C as an immediate stopgap while B (or A) gets scoped further, or go straight
   to designing B?
2. Is opening a direct public fallback path on hot-pn/hot-erp-nl (Option B) an acceptable trade-off
   given it bypasses CrowdSec at the edge unless duplicated locally?
3. For the external-heartbeat gap in Option B: is pulling in a third-party uptime/webhook service
   (data about Gateway's liveness leaving HoT's own infra for that one signal) acceptable, or should
   this rely on hot-pn/hot-erp-nl self-checking instead, accepting the split-brain risk that implies?
4. Is there a business driver (SLA, client contract, revenue conversation) behind this now, or is it
   opportunistic hardening — this materially changes whether Option A is worth scoping further.

---

## 6. Second-edge-VPS location scoping (Option A) — CH vs NL vs London

Researched 2026-08-18 at Mr. Byrne's direction, since Option A's premise ("different
provider/region") only actually delivers diversity if the second edge isn't just re-using a
datacenter HoT already depends on.

**Current footprint is already concentrated in two Hostkey DCs, not spread out:**
- **CH (Zürich)**: Gateway VPS *and* hot-pn — a Zürich-facility-level incident takes out the sole
  ingress point and PrivateNexus's home in the same event.
- **NL (Amsterdam-area)**: hot-bm-nl (all 4 Proxmox VMs) *and* hot-erp-nl — same concentration risk
  on the other coast.

Standing up a second edge in either CH or NL again would not add real resilience against a
facility-level Hostkey outage in that DC — it would just be a second host sharing the same existing
single point of failure.

**London confirmed as a genuinely distinct third Hostkey DC** (`hostkey.com/vps/` catalog,
2026-08-18: "Lifeline House, 80 Clifton Street, London EC2A 4HB") — zero HoT infrastructure
currently sits there. This is the only one of the three that actually buys facility-level
diversity from the existing footprint.

**Pricing, same `vm.v2-*` family already used for hot-pn/hot-erp-nl** (public catalog, not yet
confirmed live via invapi for this specific location — see caveat below):
| Preset | Specs | List price |
|---|---|---|
| vm.v2-nano | 2 vCPU / 4GB / 60GB NVMe | €6.71/mo — matches hot-erp-nl's own tier |
| vm.v2-mini | 4 vCPU / 8GB / 120GB NVMe | €8/mo |
| vm.v2-medium | 8 vCPU / 16GB / 160GB NVMe | €14/mo — matches hot-pn's own tier |

An edge running Caddy+CrowdSec+a WireGuard hub (Option A's actual job) is closer in profile to the
Gateway VPS itself (4 vCPU/8GB) than to a nano — `vm.v2-mini` is the more realistic starting point,
not the cheapest tier.

**⚠ Caveat, from direct prior experience, not theoretical**: the public catalog page does not show
per-location preset availability. [[hostkey_invapi_notes]] and the hot-erp Hostkey CH migration
already hit exactly this gap once — CH was confirmed *blocked* for new `vm.v2-*` orders via a live
invapi check, despite nothing on the public site suggesting a restriction, which is why hot-erp
landed in NL instead of CH. **Do not treat this table as confirmation London will actually accept a
`vm.v2-*` order** — that needs the same live `eq.php?action=order_instance` (or a non-destructive
appraisal call, if one can be found) check before committing, not an assumption from this page.

**Provider vs. location — two different axes of diversity, worth being explicit about**: staying on
Hostkey for a third DC keeps everything operationally consistent — same invapi billing key/tooling
already in `hostkey_invapi_notes`, same reboot-recovery-watchdog integration pattern (soft/hard
power-cycle via `eq.php`), same patching playbook. It does **not** diversify away from a
Hostkey-account-wide or Hostkey-company-wide incident (e.g. a billing/API outage, or an
account-level issue) — that would need a genuinely different vendor, a materially bigger lift (new
billing relationship, no existing scripts/watchdog wiring, unfamiliar API). Worth deciding
explicitly which failure mode this project is meant to protect against — single-DC/facility outage
(London on Hostkey solves this) vs. single-provider outage (does not) — before picking a target.
