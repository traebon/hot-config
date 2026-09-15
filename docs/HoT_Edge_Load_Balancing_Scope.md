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

**Worked through further 2026-09-15, at Mr. Byrne's direction ("scope Option A further") — this
turns out to be tractable, not a fundamental redesign.** Keycloak's redirect_uri check is a literal
string match against the registered URI, not an IP or host-binding check — it doesn't care which
physical edge actually answers for `ds.house-of-trae.com`, only that the URL string matches. So the
fix is two things, both already implied by Option A's own premise, not a separate special case:
1. **Include `ds.house-of-trae.com` in the exact same DNS-failover mechanism protecting every other
   domain.** No new failover logic needed — this hostname just needs to be on the list, not
   special-cased or excluded.
2. **Deploy oauth2-proxy identically on both edges, sharing the same `--cookie-secret` and the same
   Keycloak `oauth2-proxy` client secret.** Since oauth2-proxy's session cookie is just a signed
   token, any edge holding the same cookie-secret can validate a session a *different* edge issued
   — a login that starts on Edge 1 and completes (or continues) after failover to Edge 2 survives
   cleanly as long as both edges hold the same secret. This is a secrets-sync problem, the same
   class this project already solves elsewhere (Vaultwarden + manual/scripted distribution), not an
   architecture problem.

**What this does NOT need**: no oauth2-proxy config change, no new Keycloak client, no second
registered redirect URI. The existing single-URI design already works for a failover edge — it was
never actually incompatible with Option A, just under-scoped. **Separately, unrelated to SSO**: each
edge would run its own independent CrowdSec instance — ban-list/decision state does *not* need to
be shared for correctness (each edge can independently ban its own attackers against its own
traffic), only worth noting so it's not confused with the cookie-secret sync requirement above,
which *does* need to be shared.

**Net effect on the cost picture**: the SSO callback was flagged as the thing making Option A
"materially bigger than B or C" — with a concrete fix in hand, the honest remaining cost is: second
VPS to pay for and patch, cert duplication (real but mechanical — Caddy's own ACME handles this per
domain, no design work needed), the DNS-failover trigger mechanism itself (still open, see Option
B's "who watches the watchmen" discussion above — UptimeRobot, live since 2026-08-23, is the
natural candidate now), and secrets distribution to the second edge (cookie-secret, client secrets,
WireGuard hub config). No longer a landmine, just a checklist.

**Location decided 2026-09-15, Mr. Byrne's explicit call: a duplicate of the Gateway itself, in
Switzerland** — not the London-diversity framing this doc originally argued for (Section 6 below
still stands as real research, just not what got chosen; "opportunistic hardening," not protection
against a specific facility-level failure mode, per his own framing when asked directly). Checked
live before committing to a location, not assumed:
- **Catalog-level**: `vm.v2-mini` (4 vCPU / 8 GB / 120 GB NVMe — the tier that actually matches the
  Gateway's own spec, not the cheaper `nano`) shows available in both NL and CH per Hostkey's
  `presets.php?action=list` (a genuinely read-only catalog endpoint, no invoice side effect — better
  than the "appraisal call, if one can be found" this doc's Section 6 caveat was hoping existed).
- **Account-level, CH specifically**: this account had a *documented prior block* ordering `vm.v2-*`
  in CH during the hot-erp-nl migration (`hostkey_invapi_notes` memory) — catalog-level "available"
  was known not to be sufficient evidence on its own. Tested for real, with Mr. Byrne's explicit
  go-ahead given the side effect: a real `eq.php?action=order_instance` call for `vm.v2-mini`/CH
  succeeded (invoice #615674, $7.59/mo) — **the prior CH block is no longer in effect on this
  account.**
- **Mr. Byrne paid the invoice the same session** — real infrastructure, not a scoping exercise.
  Public IP `82.38.64.63`. Base bring-up done and verified: `ssh hot-edge-ch` alias, own SSH key
  installed, password auth disabled, Tailscale enrolled (`100.90.107.32`), UFW default-deny with
  SSH scoped to the WireGuard tunnel + Tailscale only (public port 22 confirmed unreachable), a
  dedicated `wg7`/`wg0` tunnel to the Gateway (`10.10.6.1`/`10.10.6.2`, port 51827) with a real
  handshake. Root password and both tunnel keypairs saved to Vaultwarden.

## 7. Edge role built and verified live, 2026-09-15

**Scope deliberately narrow**: Caddy + CrowdSec for exactly the two domains this whole doc has been
about — `privatenexus.net` and `erp.dickson-supplies.com` — not a full Gateway replica. Duplicating
Vaultwarden, mail, Keycloak, or the Gateway's other ~30 site blocks is a separate, much larger
decision not made here.

**Real finding: the SSO-callback design work in Section 3 turned out not to be needed for this
scope at all.** Neither `privatenexus.net` nor `erp.dickson-supplies.com` uses the shared
oauth2-proxy `import sso` pattern — PrivateNexus authenticates directly against its own Keycloak
`privatenexus` realm client, and ERPNext isn't SSO-gated via Caddy at all. The cookie-secret-sync
design is still the right answer *if* this edge is ever extended to cover a Gateway-hosted
`import sso` app, but building it now would have been solving a problem this specific scope doesn't
have.

**Network path**: hot-edge-ch reaches hot-pn and hot-erp-nl over two new dedicated tunnels, not
through the Gateway (routing through the thing you're failing away from defeats the point):
- `wg1` (hot-edge-ch) ↔ `wg1` (hot-pn): `10.10.7.1`/`10.10.7.2`, port 51828
- `wg2` (hot-edge-ch) ↔ `wg1` (hot-erp-nl): `10.10.8.1`/`10.10.8.2`, port 51829

Both backends needed a real fix to be reachable this way: PrivateNexus's frontend and ERPNext's
backend both bind to a *specific* IP (their existing Gateway-tunnel address), not `0.0.0.0` —
correct, deliberate hardening already in place (avoids Docker's NAT-bypasses-UFW risk), but it
meant traffic arriving via the new tunnel's different local IP was refused outright. Fixed by
adding a **second** specific-IP port binding on each (`10.10.7.2:5173:80` alongside the existing
`10.10.2.2:5173:80` on hot-pn; `10.10.8.2:8000:8000` alongside `10.10.4.2:8000:8000` on
hot-erp-nl) — both paths verified working side by side, zero disruption to the existing production
path through the Gateway.

**Certificates**: DNS-01 via PowerDNS's API (`caddy-dns/powerdns` plugin, same xcaddy build as the
Gateway's own Caddy), not HTTP-01 — this edge isn't live ingress under normal DNS, so an HTTP-01
challenge could never complete. Needed the same PowerDNS-API-over-WireGuard access hot-pn already
has: widened `wg7`'s `AllowedIPs` (both directions) to include `10.10.0.1/32` (the Gateway's
PowerDNS bind), installed the resulting route by hand (`wg syncconf` doesn't do this — see
`operational-rules.md`). No new Gateway UFW rule needed — the existing PowerDNS API rule already
covers the whole `10.10.0.0/16` range, which `10.10.6.x` falls inside. Real Let's Encrypt certs
issued and verified for both domains (`privatenexus.net` confirmed via a live TLS handshake showing
a genuine Let's Encrypt leaf cert, not self-signed/staging).

**CrowdSec**: independent instance on hot-edge-ch (`crowdsecurity/caddy`/`http-cve`/`linux`
collections, matching the Gateway's own), no ban-list sync with the Gateway's instance — per the
design decision in Section 3, each edge protects its own traffic independently, this isn't a
correctness requirement. Bouncer registered and confirmed `validated` with a live `last_pull`
timestamp via `cscli bouncers list`, not just configured-and-assumed-working.

**Verified end-to-end, both domains, via real requests against the public IP with `--resolve`**
(DNS itself still points at the Gateway — this is the standby path, not live traffic): `privatenexus.net`
returns real app HTML (200, genuine PrivateNexus `index.html`) through the new `wg1` tunnel to
hot-pn; `erp.dickson-supplies.com` returns 200 through the new `wg2` tunnel to hot-erp-nl.

## 8. Real active-active load balancing built same night, superseding pure failover

**Mr. Byrne pushed back on "failover only"** — correctly: the roadmap item has always been called
"load balancing," and the original scope doc's own reasoning for pure failover (no automated
trigger existed) was itself the gap, not a fixed decision. Real load balancing with automatic
failover built in is achievable using PowerDNS's own Lua records feature (`enable-lua-records`,
confirmed supported at v4.9.15/4.9.17, was off, now on) — no third-party GSLB, no centralized
HAProxy (which would just relocate the Gateway's single-point-of-failure problem onto whatever
machine ran it, not solve it — DNS-level distribution is the only mechanism that spans two
genuinely independent hosts without introducing a new SPOF).

**`privatenexus.net` and `erp.dickson-supplies.com` are now both `LUA` records**, not plain `A`
records:
```
ifurlup('https://privatenexus.net/', {{'151.241.217.91'}, {'82.38.64.63'}})
ifurlup('https://erp.dickson-supplies.com/', {{'151.241.217.91'}, {'82.38.64.63'}})
```
TTL dropped from 300s to 60s on both, so a dead candidate falls out of rotation fast.

**Real gotcha found building this**: `ifportup()` (the obvious first choice — bare port check) does
NOT work here. Caddy on hot-edge-ch (and the Gateway) has no catch-all TLS certificate — SNI-based
routing only, by design — so a health check that connects without specifying a real hostname gets a
TLS `internal_error` alert even though the server is completely healthy for real traffic. Confirmed
directly: raw TCP connect to hot-edge-ch:443 succeeds, TLS without SNI fails, TLS with the correct
SNI works perfectly. **`ifurlup()` against a real URL is the correct tool** — it negotiates real
SNI/Host matching a live site block, so the health check sees the same thing a real visitor does.

**Verified three ways, all live, before touching the real production records**:
1. A disposable test record (`lb-test.house-of-trae.com`) proved both `ifportup()`'s failure mode
   and `ifurlup()`'s correct behavior, including real alternation between both edges across repeat
   queries when both are healthy.
2. **Failover exclusion proven unambiguously**: swapped one candidate for `192.0.2.1` (a reserved,
   guaranteed-unreachable TEST-NET address) — across 5 queries spanning well past the TTL, the dead
   address was never once returned, only the real healthy IP.
3. **The real production cutover itself verified end-to-end**, not just via crafted tests: after
   switching, an unmodified `curl https://privatenexus.net/` (system resolver, no `--resolve`
   override) returned a real 200; same for `erp.dickson-supplies.com`, which resolved to
   hot-edge-ch on that particular query — genuine live traffic through the standby edge for the
   first time since it was built.

**What's proven vs. what's observed but not fully characterized**: the failover mechanism (excluding
a dead candidate) is proven solid. The exact distribution algorithm across healthy candidates is
NOT simple per-query random rotation — repeated queries from the same source (this session's own
fleet hosts) tended to return the same answer consistently, which lines up with PowerDNS's
`lua-consistent-hashes-*` config (hash-based selection per querier, avoiding cache-thrash for any
one resolver) rather than a bug — but this wasn't independently confirmed against PowerDNS's own
documentation or source, only inferred from the observed behavior and the presence of those config
options. Worth watching real traffic patterns over time rather than treating the exact mechanism as
fully understood.

**This changes hot-edge-ch's status materially**: it was standby-only, never having served a real
visitor, as of earlier tonight. It is now genuinely in the live rotation for both domains, all the
time, not just during a Gateway outage. `edge-failover.sh` (Section 7) still exists as a manual
override — useful for e.g. deliberately forcing all traffic to one side during maintenance — but is
no longer the only mechanism keeping these two domains resilient.

**What's still open, not built tonight**:
- ~~The actual failover trigger~~ **Superseded by Section 8** — PowerDNS's own `ifurlup()` health
  checking now does this automatically, no UptimeRobot/webhook automation needed for these two
  domains specifically. UptimeRobot's Gateway/hot-pn/hot-erp-nl monitoring (live since 2026-08-23)
  remains valuable as an independent, human-facing signal — it's not replaced, just no longer the
  only path to DNS actually moving.
  - **⚠ Real gap that still applies regardless of Section 8**: DNS routing traffic away from a dead
    Gateway does not give anyone an admin path *to* the Gateway to actually fix it — hot-edge-ch's
    SSH is intentionally tunnel/Tailscale-only, same access story as the rest of the fleet. Load
    balancing traffic and being able to intervene on a broken host are two separate problems; this
    section only ever solved the first one.
- ~~Manual cutover runbook~~ **Built 2026-09-15**: `edge-failover.sh` (`status`/`cutover`/`revert`),
  deployed identically on both the Gateway and hot-edge-ch (has to work when the Gateway can't be
  reached). `cutover` refuses to run if a real preflight check against hot-edge-ch's own IP shows
  either domain unhealthy, and requires explicit confirmation (`--yes` to skip the prompt). PATCH
  mechanics verified live against a disposable test record before being pointed at the real zones;
  the full preflight+abort path verified clean from both hosts with zero DNS mutation on decline.
  Tracked in `hot-config/gateway/edge-failover/`. **A real cutover/revert cycle against the
  production domains was not executed** — the mechanics are proven correct, but actually flipping
  live traffic even briefly is a separate decision from building the tool; worth doing once Mr.
  Byrne wants that specific proof.
- **hot-edge-ch has no monitoring of its own yet** — not in Gatus, Uptime Kuma, or UptimeRobot.
  Same class of gap this session already found and fixed for `hot-wiki` earlier tonight.
- **CrowdSec here has no alerting wired** — the Gateway's CrowdSec posts ban notifications to Ntfy;
  this instance doesn't yet.

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
