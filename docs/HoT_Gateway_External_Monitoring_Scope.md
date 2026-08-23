# HoT — Gateway External Uptime Monitoring

Scoping doc. Written 2026-08-23 after tracing what looked like "PowerDNS API flakiness" in
PrivateNexus's own health data down to a real, previously uninvestigated ~22-minute full Gateway
VPS outage on 2026-08-13 (hypervisor-level, not guest-initiated — see
`gateway_unexplained_outage_2026_08_13` memory; Hostkey ticket CS-519377 filed the same day this
doc was written). That investigation surfaced the actual gap: **nothing external to the Gateway
currently monitors whether the Gateway itself is up.**

Not a commitment to build — a scope to react to and prioritize against, per the pattern used for
`HoT_PBS_Backup_Integration_Scope.md` and `HoT_Edge_Load_Balancing_Scope.md`. Nothing described
here has been built yet.

---

## 1. Why this is a real gap, not a theoretical one

Two separate structural problems, both stemming from the Gateway being the fleet's single edge
point:

**Detection gap.** Gatus (`/opt/stacks/gatus/` on the Gateway) was built specifically to catch
host-down scenarios independent of hot-bm-nl — its whole purpose, per `services-fleet.md`, is
covering the blind spot where sn-monitor's own Grafana/Uptime Kuma can't alert on their own host's
death because they live on hot-bm-nl. But Gatus runs *on* the Gateway. It has the identical blind
spot one layer up: it cannot alert on the death of the host it itself runs on. Uptime Kuma
(sn-monitor, VLAN 50 on hot-bm-nl) is a theoretical alternative vantage point — it likely has
independent internet egress via hot-bm-nl's own uplink rather than routing through the Gateway
(hot-bm-nl has its own public IP, `31.207.47.146`, per `hardware.md`'s note on the undocumented
`nginx-certbot` container) — **not confirmed live**, worth verifying before relying on it.

**Notification gap — the more serious half.** Even a perfect detector hosted somewhere else in the
fleet still has to tell a human. All three of HoT's alerting channels are themselves Gateway-hosted:
- SMTP (`notifications@house-of-trae.com`) — Docker Mailserver runs on the Gateway
- Ntfy — runs on the Gateway (moved here 2026-08-03, see `services-fleet.md`)
- SMS relay — subscribes to the Gateway's own Ntfy topic, also runs on the Gateway

So during a real Gateway outage, **none of HoT's existing notification paths can fire**, regardless
of which host detects the problem. This is the actual reason a genuinely external service is the
right call here, not a self-hosted default — the standard project preference for self-hosted infra
(see `feedback_vaultwarden_and_selfhosted_default` memory) doesn't apply cleanly when the thing
being monitored is the same infrastructure every self-hosted alerting path depends on. Mr. Byrne's
own real mobile number (`+447771724186`, see `user_contact` memory) is confirmed independent of
HoT infra; his `tristian@securenexus.net` address is **not** — it's served by the same Gateway-hosted
Mailserver, so it can't be relied on as the sole channel for a Gateway-down alert.

---

## 2. What's confirmed live vs. what needs checking

**Confirmed (this session):**
- `443/tcp`, `80/tcp`, and mail ports (`25`/`465`/`587`/`993`) are open to `Anywhere` in UFW — real
  candidates for an external HTTPS/TCP check
- `22/tcp` is scoped to `tailscale0` only (not a usable external-check target, correctly hardened)
- Mr. Byrne's real personal mobile (independent of HoT infra) is on file

**Not yet checked, worth confirming before committing to an approach:**
- Whether sn-monitor/hot-bm-nl's outbound internet egress is genuinely independent of the Gateway
  (relevant only if the fleet-internal-monitor option below is considered)
- Whether Mr. Byrne has a personal email address not hosted on HoT's own mail server, as an
  alternative/backup notification channel to SMS

---

## 3. Options

**A. Third-party external monitoring service (recommended).** A monitor hosted entirely outside
HoT's infrastructure, checking a public Gateway endpoint (e.g. `https://house-of-trae.com` or a
dedicated lightweight healthcheck path) on a short interval, alerting via the provider's own
independent channels (their own SMS credits, push notification via their mobile app, or email to
an address not hosted on the Gateway). This is the only option that's structurally immune to the
Gateway itself being the single point of failure for both detection and notification. Realistic
named options, roughly in order of fit:
  - **UptimeRobot** — generous free tier (50 monitors, 5-min interval), no card required, has its
    own mobile app (push notifications fully independent of HoT), email, and paid SMS add-on if
    wanted. Simple, well-established, easy to set up and forget.
  - **Better Stack (Better Uptime)** — similar free tier, nicer status-page product if a public
    status page is ever wanted, phone-call escalation on paid tiers.
  - **Healthchecks.io** — inverted model (the Gateway pings *it* on a schedule, alerts if the ping
    stops arriving) — good as a *second*, structurally different check alongside an HTTP-based one,
    weaker as a sole solution since it depends on the Gateway being able to make outbound calls,
    which is a slightly different failure mode than "is it serving HTTPS."
  Cost: free tier covers this use case (one host, a handful of checks) on any of the above.

**B. Extend Uptime Kuma (sn-monitor) to check the Gateway.** Cheap to add, stays inside the
self-hosted stack — but doesn't close the notification gap at all unless its alert channel is
also changed to something independent of the Gateway (which just becomes a smaller version of
Option A anyway). Only useful as a *secondary* signal, not a replacement.

**C. Do nothing beyond what exists.** Rejected — this is the exact gap that let the 2026-08-13
outage go unnoticed and uninvestigated for 10 days until an unrelated PN data trace surfaced it.

---

## 4. Recommendation

Option A (UptimeRobot as the specific pick, given the free tier and independent mobile push) for
the check itself, checking `https://house-of-trae.com/` or a dedicated `/healthz`-style path on
Caddy, at the shortest free-tier interval (5 min), alerting via UptimeRobot's own app push +
optionally SMS to `+447771724186` if the paid SMS add-on is worth it to Mr. Byrne. Optionally
layer Option B's Uptime Kuma check as a secondary signal once egress independence is confirmed —
cheap to add, no reason not to if it turns out to be real.

Natural extension worth considering at the same time, same mechanism and near-zero extra cost:
**hot-pn and hot-erp-nl both have their own public IPs and currently no external monitor either**
(see `HoT_Edge_Load_Balancing_Scope.md`'s note that both are "fully dependent on the Gateway VPS
as sole ingress" from HoT's own internal tooling perspective — an external monitor sidesteps that
entirely by checking their public IPs directly). Adding 2 more checks to the same free-tier account
costs nothing extra.

---

## 5. Decisions (Mr. Byrne, 2026-08-23)

1. **Provider: UptimeRobot.**
2. **Notification: app push only** (free tier, no SMS add-on).
3. **Scope: Gateway + hot-pn + hot-erp-nl**, all three on the same account.
4. **Check target: root domain** for each — `https://house-of-trae.com/`, `https://privatenexus.net/`,
   `https://erp.dickson-supplies.com/`. No Caddy changes needed.

## 6. Status: built and verified live, 2026-08-23

Mr. Byrne signed up and created all 3 monitors himself via the UptimeRobot dashboard, then handed
over the account's Main API Key for verification. Confirmed live via the API (not assumed):

| Monitor | ID | Interval | Status | Alert contacts |
|---|---|---|---|---|
| `https://house-of-trae.com` | 803807823 | 300s | up | email (tristian@securenexus.net), push (Pixel 10 Pro) |
| `https://privatenexus.net` | 803807861 | 300s | up | email, push, 2 inactive phone contacts (status 0) |
| `https://erp.dickson-supplies.com/` | 803807865 | 300s | up | email, push, 2 inactive phone contacts (status 0) |

Push notification (type 13, "Pixel 10 Pro") is active and attached to all 3 — this is the channel
that actually matters for the Gateway case, and it's live. The email alert contact
(`tristian@securenexus.net`) is also attached to all 3 but is **not a reliable channel during a
Gateway outage specifically** — it's served by the same Gateway-hosted mailserver this whole effort
exists to route around; fine for hot-pn/hot-erp-nl-only incidents, not for the Gateway case. Two
inactive (`status: 0`) phone/SMS contacts exist on the privatenexus.net and erp.dickson-supplies.com
monitors but not on house-of-trae.com — inconsistent but functionally irrelevant since they're not
activated (matches the "app push only, no SMS" decision).

**Not yet done**: Mr. Byrne hasn't confirmed via UptimeRobot's dashboard test-alert button that push
actually lands on his phone (no such test exists via their public API, only the dashboard UI) —
worth doing once, not urgent given the account+device pairing itself already implies it's wired up.

**Credential handling**: the Main API Key now lives in Vaultwarden — "UptimeRobot Main API Key
(Gateway/hot-pn/hot-erp-nl external monitoring)", **House of Trae — Gateway VPS** folder. Mr. Byrne
unlocked the vault via a shared `bw unlock` session key 2026-08-23; the transient local copy
(`/etc/uptimerobot-api/api_key.txt`) was removed once the Vaultwarden item was created and
confirmed, since nothing on the Gateway runs an automated job against this key — Vaultwarden is the
sole copy.
