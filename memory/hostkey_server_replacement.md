---
name: hostkey-server-replacement
description: Bare-metal EPYC 3151 host (server 145990) unfixable by Hostkey; refunded, replacement ORDERED 2026-07-21 as Hostkey vds.v1-storage-8 (server 22272, Netherlands not Switzerland) — hostname `hot-bm-nl`/`proxmox22272.hostkey.in`. Reinstalled at least twice (2026-07-22 accidental wipe, 2026-07-23 Mr. Byrne-driven) — check uptime before trusting any prior state described here. As of 2026-07-26: PVE 9.2.5/Debian 13 up (same install since 2026-07-23, NOT re-wiped — see the 2026-07-26 "phantom reinstall" entry below), wg4 tunnel up, vmbr0/VLAN 10/30/50/70 bridging live, local-zfs on sdb intact, UFW locked down. Hostkey CLAIMS nested virt was enabled 2026-07-24 (ticket CS-505879, closed) but a full eq/off+eq/on power cycle on 2026-07-26 still shows zero vmx/svm flags and no /dev/kvm — their fix has NOT actually landed, needs a ticket reopen/follow-up. Storage layout (sdb is a standalone local-zfs pool now, not unused), the real hostname/PVE node-rename question, and the 7-VM fleet migration itself are all still open — get direction from Mr. Byrne before touching any of them. Also covers CS-498889, a since-resolved billing near-miss on the same server.
metadata: 
  node_type: memory
  type: project
  originSessionId: 662a2e2b-edf7-4613-857f-27ff2bf97ace
  modified: 2026-07-30T09:22:19.133Z
---

Hostkey support (Maxim Ryazantsev) confirmed 2026-07-02 19:44 that the recurring Intel I350 NIC PCIe link-loss fault on the bare-metal Proxmox host (AMD EPYC 3151, documented in CLAUDE.md under "Proxmox NIC PCIe link loss") cannot be fixed with a simple NIC swap — they have no matching replacement server config in current inventory. The ticket has been escalated internally to the team that handles full server replacement. No timeline given yet ("shortly" to coordinate solutions/timeline/replacement procedure).

**Why:** The `pcie_aspm=off` mitigation applied Jun 28 did not hold — crashes continued at ~34h intervals with the same fault signature. `ethtool -S nic0` showed rx_missed_errors/rx_fifo_errors climbing even between crashes, confirming the fault is hardware-level, not fixable in software. This most recently manifested as the wg0 WireGuard tunnel from the Gateway VPS to bare metal going down around 2026-07-02 ~13:00 with no recovery (100% packet loss, stale handshake) — which is what caused the SSH lockout to every VM (sn-infra, sn-business, sn-web, sn-personal, sn-monitor, pn-test, sn-security all unreachable) investigated in the 2026-07-03 session.

**How to apply:** Treat any future "VM(s) unreachable / wg0 down / Tailscale shows all VMs offline" symptom as *possibly* this same fault recurring, not a new issue — check `wg show` handshake age and `ping 10.10.0.2` first. Once Hostkey schedules the replacement, expect: a new public IP for the WireGuard endpoint (currently `194.147.214.169`) requiring `wg0.conf` update on the Gateway VPS, and a full re-establishment of the NBDE/Tang unlock chain, VLAN routing (10.10.10-70.0/24), and Clevis LUKS bindings on the new hardware for all 7 VMs. This is a full-stack migration, not a quick fix. A phased migration/rebuild checklist already exists at `/root/hot/docs/HoT_Bare_Metal_Migration_Checklist.md` (written 2026-07-03) — check it for current status before redrafting. See [[proxmox_bare_metal_fixes]] for other bare-metal operational history.

**Update 2026-07-03 17:42:** Hostkey (via ticket CS-471548, checked directly on the mail server — tristian's Gmail connector doesn't cover this, it's on Docker Mailserver) offered two options: (1) `bm.v1-str-16t` — Xeon E3-12xx(6 cores)/**16GB RAM**/2×8TB HDD at the same price, or (2) a refund back to the ticket-creation date. We pushed back same day asking if they have anything ≥32GB RAM at a comparable price, since 16GB is half the current allocation and doesn't fit the documented 44GB-allocated/32GB-physical fleet footprint — refund was offered as fallback if nothing suitable exists. Awaiting their reply. Also note as of 2026-07-03 the server still won't even boot into its installed OS (per their Jul 1 message) — this is beyond NIC flapping, the box itself may need a fresh install regardless of which resolution path is taken, so the documented nightly vzdump/rclone backups (Hetzner + B2) will be the DR path either way.

**Update 2026-07-03 19:35 (latest as of 2026-07-05):** Our ≥32GB RAM pushback was forwarded internally to Hostkey's **Sales & Billing** department "for further processing," per Vladimir Usoltsev — no ETA given beyond "at the first opportunity within working hours." No reply since (2 days of silence as of 2026-07-05 22:04 check). wg0 tunnel to bare metal remains down the whole time (handshake still stuck at 2026-07-02 07:01:23) — confirms this is a single continuous outage, not a resolved-then-recurred fault. Nothing actionable until Hostkey replies; if pressing, a follow-up nudge on the ticket may be warranted.

**Update 2026-07-06 — temporary ERPNext stand-in deployed on erp-temp:** Mr. Byrne provided a spare VPS (erp-temp, 46.202.129.86, AMD EPYC 9354P/Zen4 — full AVX-512, no cpuv1 concerns) to stand up a fresh ERPNext v16 + posawesome instance while sn-business stays unreachable. Explicit decision: **no historical data restore** — the real vzdump backups are on Hetzner (`hetzner:vzdump/`, confirmed present, dozens of dated full-VM blobs) but were believed at the time to be encrypted with an rclone crypt password that lived only on Proxmox itself, unreachable during this outage. Fresh empty site was the only viable path. Full details, gotchas, and revert plan: `/opt/hot-config/erp-temp/dickson/README.md` and CLAUDE.md's new erp-temp service section. Caddy's `erp.dickson-supplies.com` block is temporarily repointed at erp-temp over a new `wg2` WireGuard tunnel — revert both once bare metal is back. See also [[wg1_personal_vpn_discovery]] for an unrelated but important discovery made while setting this up.

**Correction 2026-07-09 — the "Proxmox-only" crypt password claim above was stale.** The rclone crypt password/salt for `hetzner-crypt:`/`b2-hot-crypt:`/`b2-snap-crypt:` was actually already recovered and saved to Vaultwarden back on 2026-07-04 (session ending 8ee3b24b), just mislabeled as "gocryptfs" instead of "rclone crypt" — that's why the 2026-07-06 session didn't find it and assumed it was Proxmox-only. Relabeled and verified correct on 2026-07-09: see [[rclone_crypt_password_vaultwarden]] for the current entry name/location. This means the Hetzner vzdump backups were decryptable on the Gateway VPS the whole time during this outage, if a restore had ever become urgent — worth remembering for the *next* outage so this dead-end isn't rediscovered.

**Update 2026-07-15 — ticket thread went sideways; reply sent to re-align it.** Checked the mailbox
(mail.house-of-trae.com, tristian@securenexus.net inbox — not the Gmail connector) for the first
time since the 07-03 19:35 Sales & Billing forward and found the ticket had drifted onto a separate,
disconnected troubleshooting track:
- 07-08 11:50 (Ilya Fedorov): asked permission to reboot the server and disable the second network
  adapter in BIOS as a stability workaround (follow-up to an earlier 07-01 GRUB-modification attempt
  that didn't resolve anything — bootloader was modified, server still wouldn't boot).
- 07-09 17:18: ticket marked "We resolved the issue" with zero detail — doesn't match reality, wg0
  is still down. Unclear if this refers to the BIOS step (never confirmed as authorized or performed)
  or is a mistaken/premature auto-close.
- 07-15 08:38: a billing-triggered "you've paid for the next period, is the issue resolved?" note —
  suggests the RAM-replacement escalation from 07-03 got lost in the Sales & Billing handoff and
  nobody connected these threads.

Sent a reply (message-id `hot-cs471548-reply-20260715123013@securenexus.net`, threaded via
In-Reply-To/References into the existing chain, delivered via the mailserver's local sendmail —
confirmed `status=sent` in the Postfix log) that: (1) clarified the server is still unreachable from
our side and asked what "resolved" actually referred to, (2) granted permission for the BIOS
reboot/second-NIC-disable step since the host is already offline with nothing to lose, and
(3) re-asked for a status update on the ≥32GB RAM replacement question, noting we'll accept the
16GB `bm.v1-str-16t` offer over a refund if nothing bigger is available.

**How to apply:** Next session checking this ticket should read the mailbox directly
(`docker exec mailserver doveadm search/fetch -u tristian@securenexus.net ...`) rather than relying
on this memory's summary, since the thread has already shown a tendency to drift across disconnected
support reps/departments. Don't assume "resolved" in a support message means bare metal is actually
back — verify independently (`wg show`, `ping 10.10.0.2`) before treating it as such.

**Update 2026-07-15 (later same day) — Hostkey's reply to the 12:30 nudge was a stale resend, not a
fresh answer.** Checked the mailbox again after the 12:30 reply logged above. Two more messages
arrived same day: 09:38 was a billing-triggered "you've paid for the next period, is it resolved?"
(sent *before* our 12:30 reply, so unrelated to it). Then 14:58 arrived as Hostkey's actual response
to the 12:30 nudge — but its body is byte-for-byte the same canned message originally sent 07-09
19:17 ("we don't have any available presets close to your current server ... pro-rata refund from
the day of the ticket creation ... for your request, the custom solution may be the best option"),
just re-threaded onto the new reply. **It does not address the ≥32GB RAM question or confirm/deny
the `bm.v1-str-16t` 16GB offer** — reads like the rep resent their standard boilerplate without
registering that we'd already agreed to accept the 16GB downgrade if nothing bigger exists. Ticket
is effectively stalled pending a clearer nudge that names the `bm.v1-str-16t` preset explicitly, or
a decision from Mr. Byrne to just take the refund/go custom instead of pushing further.

**Update 2026-07-15/16 — separate billing near-miss discovered (CS-498889), then final decision made: taking the refund, not the 16GB downgrade.**
While checking CS-471548 on 2026-07-16, found a second, previously-unknown ticket thread:
CS-498889, a suspension notice for server **145990** — confirmed via cross-referencing subject
lines (CS-369211 reinstall ticket, the original "your new server is online" provisioning email)
that 145990 is this same production bare-metal box (spec match: EPYC 3151 2.7GHz/4 cores/32GB/
2x8TB HDD). Timeline: suspended 13-Jul 11:56 CEST for overdue invoice 583723 with a **24-hour
warning before cancellation and permanent data deletion**; two $20 account-balance credit
top-ups (WHMCS invoices 1042355 and 1042357) posted 15-Jul ~04:30-04:50 CEST; Hostkey confirmed
resolved 15-Jul 13:05 CEST ("payment has been received and the service is active"). Cause of the
overdue invoice not investigated — not pursued since the ticket was already closed by the time
it was found. Note: unrelated order/invoice emails landing in the same window (Order Confirmation
9660307960, invoice 589507, "your new server is online" for a `vm.v2-medium`) are **not** part of
this incident — those are pn-vps's normal recurring billing, already covered by
[[hostkey_invapi_notes]].

This near-miss, combined with CS-471548 dragging for 2+ weeks with repeated mishandling (wrong
troubleshooting thread, premature "resolved", two identical boilerplate resends never
acknowledging the accepted `bm.v1-str-16t` offer), tipped the decision: **take the pro-rata
refund instead of the 16GB downgrade.** Reasoning: `bm.v1-str-16t` (16GB RAM) doesn't actually
fit the documented fleet — sn-security alone needs a fixed 8GB (Wazuh/OpenSearch init spike, see
CLAUDE.md) and sn-business is allocated 8GB for ERPNext; those two VMs alone consume the entire
16GB budget with nothing left for the other 5 VMs or Proxmox/ZFS overhead. Actual fleet RSS
(~7GB) doesn't matter here — it's burst/init ceiling that's constrained, not steady-state.

Sent the final decision to Hostkey 2026-07-16 02:35 BST (message-id
`hot-cs471548-reply-20260716033506@securenexus.net`, threaded via In-Reply-To/References,
confirmed `status=sent` to support@hostkey.com in the Postfix log): declining `bm.v1-str-16t`,
requesting the pro-rata refund amount/calculation, refund timeline/method, and a firm
decommission date for server 145990 (backups already covered via nightly vzdump, not a blocker,
just want the date). **Awaiting Hostkey's reply — check the mailbox directly for movement, this
thread has a track record of drifting or resending stale boilerplate.** Once refund terms are
confirmed, next step is sourcing a properly-specced (32GB+) replacement, either a Hostkey custom
quote or another provider — not yet started.

**Update 2026-07-20 — refund confirmed, termination deadline already passed with no reply sent; this closes the "awaiting Hostkey's reply" step.** Checked the mailbox again (`doveadm search/fetch` on the `mailserver` container — same method as always, not the Gmail connector). Hostkey replied to the 07-16 02:35 final-decision email the same day, at 07-16 11:20 (Veronica Gracheva): invoices #1042301 and #1042307 refunded **in full** (the billing period hadn't started), and the pro-rata refund on the live invoice #1031692 is **USD 25.63** (19 calendar days elapsed as of June 29th). All refunds credited as **Hostkey account balance**, not the original payment method — a payout to the original method has to be requested separately, it isn't automatic. The same message stated: **"the server should be terminated tomorrow, on July 17th, or earlier. Please let us know if you need additional time."**

Checked for any response: nothing in the IMAP "Sent" folder (35 messages total, none to Hostkey since a Feb ticket) — but that's expected, every prior reply on this thread was injected directly via Postfix/sendmail, which doesn't copy to IMAP Sent. Checked the real source of truth instead: `zgrep -ih hostkey /var/log/mail/mail.log*` on the mailserver container. Confirmed the last outbound message to `support@hostkey.com` from this account is still the 07-16 02:35:07 final-decision email — **no reply was ever sent** acknowledging the termination deadline or requesting more time, and no further messages have arrived on the thread since 07-16 11:20 (checked as of 2026-07-20).

**What this means:** the refund negotiation itself is now settled/closed — there's nothing further to chase on that front unless a payout to the original payment method is wanted. Server 145990 is very likely already decommissioned (4 days past its stated termination date with silence on both sides) — this was already the accepted outcome (the decision on 07-16 was explicitly to let the box go and take the refund), so this isn't a new problem, just confirmation the transition already happened. **The live next step is no longer "wait on Hostkey" — it's sourcing a 32GB+ replacement** (Hostkey custom quote or another provider), which per the last check had not been started.

**How to apply:** Don't re-check CS-471548 for movement expecting more news — treat it as closed on Hostkey's side. If Mr. Byrne wants the refund paid out rather than left as Hostkey account credit, that's a new, separate request to send. Next actionable thread for the bare-metal saga is replacement sourcing, not this ticket.

**Update 2026-07-20 — payout-to-PayPal request sent.** Mr. Byrne asked to request the account
balance be paid out rather than left as Hostkey credit. Hostkey's 07-16 11:20 reply had already
said this needs an explicit ask ("If you want a refund to the original payment method, the refund
credit should be created."), so replied on the same CS-471548 thread (threaded via
In-Reply-To/References onto their message `8d5bfc59-4e7c-4a1f-832e-5323e1361cb1@smtp-relay.sendinblue.com`),
requesting payout to the original method (PayPal) of the full credited balance: invoices #1042301
and #1042307 (refunded in full) plus the USD 25.63 pro-rata on #1031692. Message-id
`hot-cs471548-reply-20260720113832@securenexus.net`.

First send attempt bounced — DMARC reject from Google (Hostkey's mail host) because the envelope
sender came through as `root@mail.house-of-trae.com` instead of `tristian@securenexus.net` (piped
into `docker exec -i mailserver sendmail -t` without `-f`, so Postfix pickup used the local `uid=0`
identity rather than the From: header address). Confirmed via `postfix/pickup` log line showing
`from=<root@...>` on the failed attempt vs. `from=<tristian@securenexus.net>` on every prior
successful send in this thread. Fixed by resending with `sendmail -f tristian@securenexus.net -t`
— confirmed `status=sent` in the Postfix log on the second attempt, no duplicate reached Hostkey
(the first attempt never left the Gateway). **How to apply:** any future one-off email injected
via the mailserver container's local `sendmail` needs `-f tristian@securenexus.net` (or whichever
mailbox it should appear from) explicitly — otherwise it silently defaults to the container's root
identity and fails DMARC on any recipient that enforces it.

Awaiting Hostkey's reply on the payout — check the mailbox directly (doveadm on the `mailserver`
container) for movement, same as the rest of this thread's history.

**Update 2026-07-21 — replacement provider/plan decided: Hostkey vds.v1-storage-8, not yet ordered.**
Compared Hostkey bare metal, Hostkey VPS, Hetzner, and OVHcloud (Kimsufi + RISE) against the
target spec (4c/8t, 32GB+ DDR4 ECC, ~8TB HDD mirror, ideally Switzerland for data-residency
reasons — two product lines, PrivateNexus and Discreet Elite, lean on "hosted in Switzerland" as
part of their privacy positioning). Findings:
- **Hostkey bare metal**: no preset fits (confirms their own earlier CS-471548 boilerplate,
  independently verified via public catalog); Switzerland dedicated servers show "coming soon"
  regardless; would need a custom quote with no fixed price.
- **Hostkey VPS**: `vds.v1-storage-8` (4 vCPU dedicated/32GB/2x4TB HDD, €51/mo, Zürich) and
  `vds.v1-storage-36` (4 vCPU/32GB/2x18TB HDD, €87/mo, Zürich) both fit and keep Swiss residency.
- **Hetzner**: no clean match — standard dedicated line (EX/AX/RX) is NVMe-only at this tier;
  Server Auction (hetzner.com/sb) might have a cheap HDD-heavy used box but isn't scrapeable via
  WebFetch, never queried live.
- **OVHcloud Kimsufi KS-1-B**: best price/spec fit of any option found — Xeon D-2123IT 4c/8t,
  32GB DDR4 ECC, 2x4TB HDD Soft RAID, $28.32/mo — but no Switzerland datacenter (Frankfurt/
  Gravelines/Roubaix/Strasbourg/London/Warsaw only), so it downgrades the hosting-jurisdiction
  story from "Switzerland" to "generic EU."
- **Iceland** (checked as a Swiss-equivalent alternative): Kimsufi has no Iceland location at
  all; Hostkey has an Iceland dedicated-server line (Reykjavík) but no 32GB+RAM+HDD config exists
  there (32GB tiers are all SSD/NVMe-only, ECC unconfirmed) and Iceland VPS is currently listed
  as unavailable site-wide — ruled out.

Mr. Byrne chose **Hostkey vds.v1-storage-8** (2026-07-21) — keeps Swiss residency, closest price
match to the original box, at the cost of half the HDD capacity (4TB vs. the original 8TB mirror)
and being virtualized rather than true bare metal. **Not yet ordered** — the invapi customer API
key from the 2026-07-15 pn-vps provisioning session was never saved to a secrets file and isn't
available this session (see [[hostkey_invapi_notes]]); ordering needs either a fresh API key from
Mr. Byrne or him driving it through the invapi.hostkey.com web panel himself, same constraint as
the pending PayPal payout above.

**How to apply:** next step is actually placing the `vds.v1-storage-8` order (need invapi API key
or Mr. Byrne to order via the panel), then following the same post-provision pattern already used
for pn-vps/erp-temp — dedicated WireGuard tunnel from the Gateway, temporary Caddy repoints where
needed, NBDE/Tang re-binding, VLAN routing rebuild for the fleet. This is the actual bare-metal
replacement, not a temporary stand-in like erp-temp/pn-vps — plan the full 7-VM migration once
it's provisioned, referencing `/root/hot/docs/HoT_Bare_Metal_Migration_Checklist.md`.

**Update 2026-07-21 — ordered, but discovered it's Netherlands not Switzerland; ordered anyway per Mr. Byrne's call.**
Before ordering, queried the live invapi preset catalog directly (`presets.php action=list`) rather
than trusting the public hostkey.com/vps/ page, which is what the earlier "Zürich ✓" comparison
table was based on. The catalog disagrees with the public page: preset id 133 (`vds.v1-storage-8`)
and id 136 (`vds.v1-storage-36`) both show `"locations": "NL"` only — every other location
including `CH` prices as `-1` (unorderable). The only 32GB+ VPS preset actually orderable in
Switzerland is `vds.ryzen-32` (8 vCPU/32GB/**400GB NVMe**, not HDD, ~$103/mo) — a materially
different storage profile. **Public marketing pages should not be trusted for real location
availability going forward — always check `presets.php action=list`'s `locations` field before
quoting a location to Mr. Byrne.**

Flagged this to Mr. Byrne before ordering (his choice, not decided unilaterally, since it directly
affects the Swiss-residency reasoning that helped pick Hostkey over Kimsufi in the first place).
He said: order it in NL anyway, keep anything that needs to stay private/Swiss-hosted on actual
Swiss infrastructure instead. Confirmed this is satisfiable without any change: **pn-vps
(151.241.217.140, PrivateNexus's stand-in) is already Hostkey CH**, and **the Gateway VPS itself
is already Zürich** — neither PrivateNexus nor Discreet Elite's hosting touches this NL box.

**Order details:** `eq.php action=order_instance`, preset=`vds.v1-storage-8`, location_name=`NL`,
os_id=`237` (Ubuntu 24.04), deploy_period=1, traffic_plan=`25` (same reused generic ID from the
pn-vps order — `traffic_plans.php action=list` still can't be queried directly, every filter combo
tried returns `invalid request`, unresolved from [[hostkey_invapi_notes]]). WHMCS invoice id
**591761** / invoice number **1043836** — **auto-paid in full, $58.20, entirely from existing
account credit** (the CS-471548 refund balance), zero PayPal charge. Root password generated and
used at order time — **not yet saved to Vaultwarden, do this next session if not already done.**
As of order time + ~30s, the new server had not yet appeared
in `eq.php action=list` (still just `[4683, 50265]`) — provisioning was still in progress when this
session ended; **next session should check `eq.php action=list` for a 3rd server ID, then follow
the standard post-provision pattern (root login → add Gateway SSH key → WireGuard tunnel → Caddy/DNS
as needed → plan the actual 7-VM fleet migration).**

**Note on `eq/list` visibility gap:** confirmed across two different API keys (both same
underlying account, whmcs_id 60326/customer_id 310890) that newly-ordered servers don't appear in
`eq.php action=list` for a while after ordering, even with `status=all`/`include_inactive=1`/`all=1`
params tried — matches the same gap CLAUDE.md documents for pn-vps/4683. Mr. Byrne confirmed via
the web panel directly that the server showed status "installing" while the API still only listed
`[4683, 50265]` — **the panel is the reliable source for provisioning status, not `eq/list`, at
least during the install phase.** Don't waste time re-polling `eq/list` variants next time; check
the panel or wait for the "your new server is online" notification email instead.

**Update 2026-07-21 (same session) — PayPal payout finally requested, but balance is now $0.**
Ticket **CS-503992** ("Unused funds refund request"), created 11:38, ~4 min after the NL order's
auto-payment at 11:34 — confirmed by Mr. Byrne this is him finally submitting the self-service
"Refund credit" step from invapi.hostkey.com → Billing that's been pending since 2026-07-20 (see
above). **Practical catch: the entire account credit balance ($58.20) was just consumed paying for
the NL order** (invoice 1043836: credit=58.20, total=0.00, balance=0.00) — so this refund request
likely has nothing left to actually pay out. Not yet confirmed either way from Hostkey's side.
**How to apply:** if/when Hostkey replies to CS-503992, expect them to say there's no balance to
refund — that's consistent with this timeline, not a new problem, and shouldn't trigger re-litigating
the NL order. If Mr. Byrne wants the payout to actually happen, the balance would need to build up
again first (e.g., from a future refund/credit) or he'd need to accept there's nothing to withdraw
right now.

**Update 2026-07-20 16:52 — Hostkey replied: payout is self-service, not something they process manually.** Veronica Gracheva's reply to the payout request says a refund-to-original-method request isn't actioned by support at all — it's a self-service flow: log in at `https://invapi.hostkey.com/`, go to Billing, select "Refund credit." Once submitted, funds return via the original payment gateway (PayPal, per our request) within 10 business days. **Nothing further will arrive on this thread unprompted** — the ball is entirely in our court now, specifically Mr. Byrne's (this needs a real Hostkey account login, not something I can drive headlessly without credentials/2FA in front of me). As of this check (2026-07-21) the "Refund credit" step has not been confirmed as done.

**How to apply:** stop checking the mailbox for movement on the payout — there won't be any until someone submits the Billing → Refund credit request in the portal. The live next step is: Mr. Byrne (or me, if given portal access/session) logs into invapi.hostkey.com and submits that request. Once that's done, the refund-negotiation thread is fully closed and the only remaining bare-metal-replacement work is sourcing a 32GB+ box (still not started as of this check).

**Update 2026-07-22 — NL server (22272) is up, root-accessible, and meets spec; eq/list visibility
gap has resolved on its own.** `eq.php action=list` now returns all three servers (`[4683, 22272,
50265]`) — no more querying-around-the-panel needed for this one. `eq.php action=show id=22272`
confirms: preset `vds.v1-storage-8`, NL datacenter, IP `31.207.47.146`, hostname tag
`hostkey22272`, OS tag "95-HKM Ubuntu 24.04". Found the "HOSTKEY: your new server is online" email
(sent 2026-07-21 19:56, in the mailbox — same `doveadm` method as the rest of this thread) with
root credentials: **user `root` / password `2ziozY3Uy_`** (email explicitly says "change it
immediately!" — not yet done). Verified live, not just from the email: pinged (18ms RTT), SSH'd in
with that password, confirmed `Ubuntu 24.04.4 LTS`, **8 vCPU / 32Gi RAM / 3.6T disk available**
(`free -h`/`df -h` output) — the 32GB+ RAM target that drove this whole replacement search is
actually met. **Note this is double the "4 vCPU dedicated" the `vds.v1-storage-8` catalog listing
above advertised (see the 2026-07-21 comparison research entry)** — Hostkey delivered more vCPU
than their own preset description promised, not less; not investigated further since it was a
pleasant surprise rather than a shortfall, but worth remembering if the catalog number and the
live-verified number are ever compared again and look like they disagree. **This 8 vCPU figure is
the one that's actually correct and running** — CLAUDE.md's Hardware section briefly documented
this as "4 vCore" (presumably sourced from the catalog listing instead of this verified entry),
corrected 2026-07-28 via direct `lscpu`/`nproc` re-verification on the live host, matching this
entry exactly. Hostname is still the generic default (`22272.example.com`), uptime ~5h at check
time. Not yet done: root password rotation, Gateway SSH key added, Vaultwarden entry, or any of
the post-provision pattern (WireGuard tunnel, hostname, fleet migration planning) — this check was
read-only, deliberately not started without Mr. Byrne's go-ahead given the standing "leave it,
check again later" instruction from the previous check.

**How to apply:** next actionable step is the same as before but now unblocked: root password
rotation + Vaultwarden save, add the Gateway's SSH key (`/root/.ssh/claude_code_key`) for
passwordless access matching the rest of the fleet, then start the actual bare-metal replacement
work (dedicated WireGuard tunnel, hostname, and eventually planning the full 7-VM migration per
`/root/hot/docs/HoT_Bare_Metal_Migration_Checklist.md`). Ask before starting any of that — this
server holds real production replacement duty, not a throwaway test box.

**Update 2026-07-22 (same day) — basic post-provision setup done.** Mr. Byrne approved starting
setup. Completed: (1) added the Gateway's SSH key (`/root/.ssh/claude_code_key`) to
`~/.ssh/authorized_keys`, verified key-based login before relying on it; (2) rotated the
Hostkey-issued root password to a freshly generated one (`openssl rand`-based), set via `chpasswd`
over the still-working key session; (3) set hostname to **`hot-bm-nl`** (was the generic
`22272.example.com` default) — chosen as a neutral "bare-metal NL" name since it's not yet decided
whether this box will actually run Proxmox itself or something else, so avoided presuming a
`proxmox-*` name; (4) added an SSH config alias (`Host hot-bm-nl` → `31.207.47.146`) on the Gateway,
matching the `pn-vps`/`erp-temp` pattern; (5) saved the new root password to Vaultwarden as
"hot-bm-nl root password (Hostkey NL VPS — bare-metal replacement)" in the **House of Trae —
Gateway VPS** folder (not the PrivateNexus folder pn-vps's creds live in — this box isn't
PrivateNexus-specific, it's general infra, same folder as the Proxmox/Gateway/WireGuard entries).
Vaultwarden write used the same one-off `bw unlock --raw` → session-token-from-Mr.-Byrne → write →
`bw lock` pattern as every other vault write this fleet has used; token was never logged or reused
after the single write. Verified end-to-end after all changes: `ssh hot-bm-nl` (alias, no password)
→ correct new hostname, correct RAM.

**What's still NOT done, deliberately** (only the post-provision access setup was in scope for this
pass): no UFW lockdown on hot-bm-nl itself, no decision on whether this box gets Proxmox installed
to recreate the 7-VM fleet or is used some other way, no NBDE/Tang binding, no VLAN routing. All of
that is real architecture/scope decisions for a dedicated migration-planning pass — see
`/root/hot/docs/HoT_Bare_Metal_Migration_Checklist.md` when that's picked up.

**Update 2026-07-22 (same day) — WireGuard tunnel to the Gateway established: wg4.** Checked
`wg show` + `systemctl list-unit-files 'wg-quick@*'` first per CLAUDE.md's own standing rule (avoid
colliding with wg1, the easy-to-forget personal VPN interface) — wg0-wg3 all taken (wg0=old
bare-metal tunnel now stale/dead but config still present, wg1=personal VPN, wg2=erp-temp,
wg3=pn-vps), so this became **wg4**. Unlike wg2/wg3 this is **not temporary** — it's the tunnel to
the actual bare-metal replacement candidate, so it wasn't given the "tear down once bare metal is
restored" framing those two have.

Setup: generated a fresh keypair on each side (Gateway's wg4, hot-bm-nl's own `wg0` — client-side
interface naming doesn't have to match the Gateway's name for it, same as pn-vps's `wg0` mapping to
the Gateway's `wg3`). Gateway `10.10.3.1/24` ↔ hot-bm-nl `10.10.3.2/24`, port 51824. Opened
`51824/udp` (v4+v6) in UFW before bringing the tunnel up, not after. Verified bidirectional ping
across the tunnel in both directions before considering it done, not just a clean handshake.
**Explicitly `systemctl enable`d `wg-quick@wg4` (Gateway) and `wg-quick@wg0` (hot-bm-nl)** —
learned from the documented pn-vps gotcha where `wg-quick@wg0` was never enabled and a reboot
would have dropped that tunnel permanently; checked and confirmed this new tunnel doesn't repeat
that mistake on either end (`systemctl is-enabled` returns `enabled` on both). Documented in
CLAUDE.md's Network Topology section (the wg1-wg3 list, now wg1-wg4) rather than only here in
memory, since that section exists specifically so future sessions don't collide on interface names
— same reasoning CLAUDE.md itself gives for wg1's entry.

No services route through wg4 yet — it's just the transport layer, ready for whatever the eventual
migration architecture turns out to be.

**Update 2026-07-22 (same day) — fleet-wide WireGuard health check found and fixed two real
systemd gaps on wg2/wg3.** Prompted by setting up wg4, checked whether the two existing temporary
tunnels had the same class of problem already documented for pn-vps's own side (`wg-quick@wg0`
there was never `systemctl enable`d). Found two different issues, not one:
- **wg2 (erp-temp):** `enabled` but `systemctl is-active` reported `inactive` despite a live,
  passing-traffic tunnel (fresh handshake, real transfer counters) — cosmetic only, caused by the
  interface having been brought up at some point via a bare `wg-quick up` rather than
  `systemctl start`, so the oneshot unit's tracked state never matched reality. Would have
  self-corrected on the next reboot (already enabled) but made `systemctl status` misleadingly
  read as down in the meantime. Fixed by `wg-quick down wg2` + `systemctl start wg-quick@wg2` —
  re-handshake took ~2 seconds, confirmed erp.dickson-supplies.com stayed at HTTP 200 throughout.
- **wg3 (pn-vps):** genuinely `disabled` — not a status mismatch, a real persistence gap. A Gateway
  reboot would have silently failed to bring this tunnel back up at all, breaking
  privatenexus.net's routing through it. Fixed with a plain `systemctl enable wg-quick@wg3` —
  since `enable` only creates the boot-time symlink and doesn't touch the running interface, this
  needed no restart and caused zero disruption (handshake age kept incrementing normally through
  the fix, confirming the live tunnel was never touched).

**How to apply:** the "was this tunnel ever `systemctl enable`d and actually started via systemd,
not just `wg-quick up` by hand" question is worth checking on *any* WireGuard interface on this
Gateway, not just new ones — `wg show` alone can't tell you, you need
`systemctl is-enabled`/`is-active wg-quick@<iface>` too, and the two can diverge from each other and
from reality in different ways (wg2's case: enabled+working but shown inactive; wg3's case:
genuinely not enabled despite currently working).

**Update 2026-07-22 (same day) — wg1 (personal VPN) had the same cosmetic mismatch as wg2, now
fixed.** Checked as the last interface in this fleet-wide sweep: `enabled` but `is-active` reported
`inactive`, same root cause as wg2 (interface brought up via a bare `wg-quick up` at some point,
not `systemctl start`). No client was actively connected at check time (no handshake shown for any
of the 3 peers — normal for a road-warrior VPN, not a fault), so there was no live session to
protect during the fix. Fixed identically: `wg-quick down wg1` + `systemctl start wg-quick@wg1`;
confirmed all 3 peers (phone/laptop/windows, `10.10.90.2/3/4`) came back with their config intact
after the bounce.

**Correction, same check:** initially claimed here that all four interfaces were fully clean after
this — wrong. wg3 had only ever gotten the `systemctl enable` half of the fix (closing the
reboot-persistence gap), never the `wg-quick down` + `systemctl start` bounce that wg1/wg2 got to
fix the `is-active` tracking — so it was still showing `inactive` despite `enabled` and despite the
tunnel itself working fine (fresh handshake, `privatenexus.net` returning 200 throughout). Caught
on a follow-up "check pn-vps tunnel" request and fixed the same way: `wg-quick down wg3` +
`systemctl start wg-quick@wg3`, re-handshake in ~2 seconds, confirmed `privatenexus.net` stayed at
HTTP 200 across the bounce. **All four Gateway WireGuard interfaces (wg1-wg4) are now actually both
`enabled` and correctly showing `active` in systemd** — verified individually, not assumed from a
partial fix. This closes the fleet-wide WireGuard systemd-state sweep that started while setting up
wg4.

**Correction #2 — wg4 itself had the identical bug, on both ends.** A follow-up "check hot-bm-nl
and wg4 too" caught it: wg4 (Gateway) and its peer wg0 (hot-bm-nl) were both `enabled` but
`is-active: inactive`, live tunnel working fine regardless (handshake ~1m50s old on both sides).
Root cause, in hindsight obvious: wg4 was originally brought up during initial setup with a bare
`wg-quick up wg4` / `wg-quick up wg0` on each side, then `systemctl enable`d afterward — the exact
same sequence that caused the wg1/wg2/wg3 mismatches, just not recognized as the same bug at the
time because it was "new setup" rather than "found a pre-existing tunnel." Fixed identically on
both ends: `wg-quick down` + `systemctl start wg-quick@<iface>`; re-handshake in 7 seconds,
`ping 10.10.3.2` clean, hot-bm-nl host itself confirmed healthy (correct hostname, 30GB free RAM,
6h11m uptime — no side effects from the bounce).

**How to apply, updated:** the real lesson isn't "check existing tunnels for this" — it's that
**`wg-quick up` and `systemctl start wg-quick@<iface>` are NOT equivalent** and this codebase/host
has now demonstrated a standing habit of using the former. Any time a WireGuard interface is
brought up by running `wg-quick up` directly (including during initial setup of a brand-new
tunnel, not just when fixing a found one), immediately follow with `wg-quick down` +
`systemctl start wg-quick@<iface>` before considering the tunnel done — don't just `systemctl
enable` and assume that's sufficient, and don't treat "I just set this up correctly" as a reason to
skip verifying `is-active` specifically. All 4 Gateway interfaces × their remote peers (8
enable/active checks total across wg1-wg4) have now been individually verified clean as of this
session.

**Update 2026-07-09 — full historical data restore completed on erp-temp.** Once the crypt password was confirmed recoverable, restored the 2026-06-29 sn-business vzdump backup into erp-temp end to end: download (rclone's SFTP client stalled deterministically at ~8.4GB/25% twice — worked around with plain OpenSSH `sftp` + password auth, since the SFTP account's key turned out to be registered SFTP-subsystem-only, not exec-capable), local decrypt via a temporary rclone crypt remote pointed at local disk, `zstd -d --rm` decompress, `vma extract` (built the tool standalone from Proxmox .debs via `dpkg-deb -x`, no system install), `losetup` + `clevis luks unlock` (via a temporary SSH-reverse-tunnel bridge to the Gateway's wg0-bound Tang, torn down after use), then a live docker-volume swap into erp-temp's running dickson-db/sites/assets volumes (originals kept as `.fresh-backup`). Verified via `frappe.ping` and real inventory data (Feb/Mar 2026) through the public erp.dickson-supplies.com URL. Full narrative and exact commands: `/opt/hot-config/erp-temp/dickson/README.md`. **erp-temp is no longer a fresh empty site** — CLAUDE.md's erp-temp row and the README were both updated; don't reintroduce the "fresh site, no historical data" framing. Known gap: anything entered into the fresh site during 2026-07-06→09 isn't merged in, only preserved in `.fresh-backup` — Mr. Byrne said erp-temp had been sitting unused, so this is expected to be nothing, but wasn't independently verified.

**Update 2026-07-22 — fleet migration architecture decided (nested Proxmox), then hot-bm-nl
reinstalled to Debian 12 as OS to Proxmox VE on.** Mr. Byrne chose nested Proxmox over a flat
Docker/LXC consolidation, after confirming nested virtualization is actually available on this VPS
(`vmx` flag exposed, `/dev/kvm` present, `kvm_intel` loaded with `nested=Y` — Hostkey's ovirt
platform passes this through, not guaranteed on every provider). Plan: install Proxmox VE inside
hot-bm-nl, recreate the original 7-VM fleet with VLAN routing and per-VM LUKS+Tang, matching
CLAUDE.md's existing topology almost 1:1. `HoT_Bare_Metal_Migration_Checklist.md` predates this
outcome entirely (written assuming literal replacement bare metal with a ZFS mirror) and needs a
real rewrite once the new host is up — don't follow its Phase 1-3 steps as-is.

Proxmox VE requires a Debian base (built against Debian 12 for the current 8.x line), but
hot-bm-nl was provisioned with Ubuntu 24.04 — no supported in-place conversion path, and no
confirmed rescue console for this box ruled out anything riskier than a clean reinstall (matches
the precedent already used for pn-vps's OS upgrade). **This wipes everything done on hot-bm-nl so
far**: the LVM RAID1 mirror (root+swap across sda3/sdb1), the rotated root password, the
`hot-bm-nl` hostname, the SSH key in authorized_keys — all need to be redone once Debian 12 is up.
The wg4 tunnel config itself lives on the Gateway side and survives, but the hot-bm-nl-side `wg0`
config/keys are gone with the reinstall and need regenerating (a fresh keypair, not reusing the
old one, since the private key only ever lived on the wiped disk).

**⚠ Real mistake made triggering this reinstall — see [[hostkey_invapi_notes]] for the full API
gotcha.** Intended `eq.php?action=reinstall` with no `os_id` as a read-only probe to discover the
required parameters (a pattern that's safe on most APIs) — it actually executed immediately,
confirmed within seconds via `ssh`/`ping` (ICMP responded, SSH refused, `eq/show` reported
`"OS": null`). Recovered by immediately finding Debian 12's real `os_id` (219, via the separate
read-only `os.php?action=list` catalog) and issuing a corrected `eq/reinstall` call with it, rather
than leaving the box in a half-wiped no-OS state. **Disclosed to Mr. Byrne immediately, not
discovered by him later** — this cost nothing of real value (hot-bm-nl had no live services yet)
but the same mistake against a server with real production data would have been serious. Lesson
already captured in hostkey_invapi_notes: never call any `eq/*` write action just to see its error
message — assume every one executes on the first successful call.

**How to apply:** once Debian 12 confirms up (watch for SSH becoming reachable, same pattern as
the original provisioning wait — Hostkey's API gives no useful progress detail mid-reinstall, per
the same memory), redo in order: SSH key → root password rotation + Vaultwarden update (the old
Vaultwarden entry now describes a dead password, needs replacing not just supplementing) →
hostname → LVM RAID1 mirror (this time leaving real free space in the VG from the start instead of
filling it entirely — see the partition planning note below) → regenerate the wg4 tunnel's
hot-bm-nl-side keypair and reconnect → *then* start on Proxmox VE itself (add the Debian 12 →
Proxmox apt repo, install `proxmox-ve`, configure `vmbr0`, VLAN-aware bridging for 10/20/30/40/50/60/70).

**Partition planning for the redo:** don't repeat the original mistake where root+swap consumed
every extent on the disk, which forced a live swap shrink just to free room for the RAID1
metadata. This time: small root LV (~100GB) + modest swap (8-16GB), leaving the rest of the VG
free — that free space becomes both the RAID1 metadata headroom (no shrink dance needed) and,
later, the pool Proxmox uses for `local-lvm` VM storage. ~3.6TB usable after mirroring comfortably
fits the original 7-VM fleet's ~1.75TB total allocation with room to spare. If Hostkey's automated
reinstall doesn't expose partition customization at all (quite possible, given the original
auto-provisioning didn't), the fallback is to shrink root immediately post-install before any real
data lives on it — a cleaner moment than doing it live, which was the situation last time.

**Update 2026-07-22 (later same session) — hot-bm-nl still not booted; separately, built a
temporary cross-tunnel monitoring hub for erp-temp+pn-vps.** Checked hot-bm-nl again: pings, but
SSH still refused — last known state was stuck on a live/rescue ISO boot menu waiting on Mr. Byrne
to flip the boot-device order to HDD in the Hostkey panel and reboot. No confirmation yet that
he's done this.

Separately, Mr. Byrne asked how to get "the fleet" to pick up the new replacement servers
(hot-bm-nl/erp-temp/pn-vps). Checked rather than assumed: `sn-monitor` (Prometheus/Grafana/Loki/
Uptime Kuma) is itself one of the 7 VMs on the dead bare-metal host — `wg0`'s handshake to the old
EPYC 3151 is 20+ days stale, doesn't respond to ping. There is no live fleet monitoring for anyone
right now. He chose to extend pn-vps's existing `monitoring-temp` stack (built 2026-07-15) to also
cover erp-temp, rather than build a new hub on the Gateway (would violate "no databases on the
Gateway VPS") or leave it fully manual.

**Network problem:** erp-temp (wg2) and pn-vps (wg3) are separate external VPS's, each with only a
tunnel back to the Gateway — no path to each other directly. The Gateway is the only box that can
reach both.

**Recipe (reusable for any future spoke-to-spoke connection through this Gateway):**
1. Gateway: narrow `ufw route allow` rules, not a blanket forward-open — `DEFAULT_FORWARD_POLICY`
   being `ACCEPT` in `/etc/default/ufw` does NOT mean the live `ufw-after-forward` chain actually
   accepts anything (it was empty; raw `FORWARD` policy is `DROP`) — always check the real chains,
   not the `ufw status verbose` summary label. Added narrowly-scoped rules for just the 2 ports
   needed (`9100` pn-vps→erp-temp, `3100` erp-temp→pn-vps); `ufw-before-forward` already has a
   blanket `ESTABLISHED,RELATED` accept so no reverse rule was needed.
2. Both spokes: widen `AllowedIPs` to route through the Gateway to each other (same technique as
   the pn-vps→PowerDNS fix in CLAUDE.md's pn-vps section) — erp-temp's peer AllowedIPs gained
   `10.10.2.2/32`, pn-vps's gained `10.10.1.2/32`. Applied via `wg syncconf`, then **manually
   `ip route add`** (syncconf never installs routes — confirmed true again here, not just for the
   original PowerDNS case). Once the config file has the widened AllowedIPs, a future `wg-quick`
   cycle installs the route automatically — no manual step needed again after a restart.
3. Per-host UFW: `ufw allow from <peer-tunnel-ip> to any port <port> proto tcp` on each side for
   the specific inbound traffic.
4. node-exporter deployed on erp-temp (`network_mode: host`, bound to `10.10.1.2:9100`
   specifically, not `0.0.0.0`).
5. **⚠ Docker `internal: true` networks silently no-op port publishing — the real gotcha.**
   pn-vps's `compose_pn-internal` network (deliberately internal, for isolation) accepted a
   `ports:` directive on the `loki` service with no error and even showed the intended mapping in
   `docker inspect`'s `HostConfig.PortBindings` — but nothing actually listened, no `docker-proxy`,
   no DNAT rule. Internal networks have no gateway (`sbJoin: gwep4 ''->''` in the docker log is the
   tell) and can't publish host ports at all. **Fix: give the container a second, non-internal
   bridge network** (`loki-external`) alongside its existing internal-network membership — port
   publishing then works, isolation for everything else is unchanged. **Hit the identical bug from
   the other direction on `pn-prometheus`**: its own scrape of `10.10.1.2:9100` failed with
   `network is unreachable` (that specific error, not `connection refused`, is the tell) because
   the container itself had no route out — even though a plain `ssh pn-vps curl ...` test from the
   *host* worked fine (host routing table ≠ container routing table; don't let a host-level test
   convince you the container's own path also works). Fixed the same way — added prometheus to
   `loki-external` too.
6. promtail deployed on erp-temp (`network_mode: host`, pushing to
   `http://10.10.2.2:3100/loki/api/v1/push`, static `host: erp-temp` label via relabel_configs).

**Verified live:** pn-prometheus's target list shows `erp-temp` `up` (checked from inside the
container after the network fix, not just the host); a Loki `query_range` for `{host="erp-temp"}`
returned real `dickson-worker`/`dickson-backend` log lines from erp-temp's actual ERPNext stack.

**Also fixed in passing:** erp-temp's `wg-quick@wg2` had the identical live-but-systemd-untracked
mismatch documented above for the Gateway's own wg1/wg2/wg4 — same fix, zero disruption, fresh
handshake confirmed.

**Revert/teardown when sn-monitor is restored:** remove the 2 `ufw route` rules + 2 per-host `ufw
allow` rules, delete `/opt/stacks/node-exporter/` and `/opt/stacks/promtail/` on erp-temp, drop the
`loki-external` network + `ports:` block from pn-vps's `monitoring-temp/docker-compose.yml`, narrow
both `AllowedIPs` back down. Not yet added to the erp-temp/pn-vps README teardown notes in
`/opt/hot-config` — do that next time those files are touched.

**PrivateNexus Inventory `backup_policy` question, same session:** checked the live DB rather than
trust the CLAUDE.md narrative — it's accurate. `privatenexus-db`=`daily`, 10 services=`manual`, and
the 5 rows showing `none` (Keycloak/PowerDNS API/Caddy Admin API/Proxmox + the archived stand-in-VPS
row) all have real `policy_exceptions` rows with genuine reasoning — not a gap. Asked Mr. Byrne
whether the Inventory board's raw `none` display (no inline indication it's an intentional
exception) is the actual source of confusion — no answer yet, worth a follow-up if he raises it
again.

**Update 2026-07-22 (same session) — Mr. Byrne had approved two phantom "app" services
(`mystifying_raman`/`objective_khorana`) into the Inventory, unsure if he should have.** Root
cause: PrivateNexus's `discovery-agent.sh` (hourly timer on pn-vps) does a single `docker ps`
point-in-time snapshot each run. Something on pn-vps — source not identified, see below — spins up
short-lived, unnamed `curlimages/curl:latest` containers (Docker auto-assigns the
adjective_surname name) roughly every 3 seconds, each alive well under a second, doing a plain
`curl -s http://pn-prometheus:9090/api/v1/targets`. Twice (00:34 and 01:34 UTC) the hourly snapshot
caught one mid-life and queued it as a `source=docker` candidate; Mr. Byrne approved both around
06:17 without realizing they weren't real running services.

**⚠ Unresolved side-finding, not a security issue but genuinely unexplained:** spent real effort
trying to find what's launching these curl probes — not in `hot-privatenexus`'s backend/mcp source
(`healthProbe.js` uses native `fetch()`/`net.Socket`, no container spawning anywhere), not cron,
not root's crontab, not any systemd service/timer, not a screen/tmux session. Ruled out my own
session's polling loops (those used `docker exec ... wget`, a different mechanism, and the pattern
predates this session's pn-vps work by hours per the candidates' `discovered_at` timestamps). Traced
one red herring to ground: a root-owned `haproxy -f /tmp/haproxy.cfg` process turned out to just be
the already-documented `privatenexus-docker-proxy` (tecnativa/docker-socket-proxy) container
operating normally, not anything new. The curl target (Prometheus's own `/api/v1/targets`, i.e.
scrape-target health) and cadence read like someone/something watching for a target to come up
healthy — plausibly Mr. Byrne's own tooling/dashboard/browser session, outside what's visible from
the box itself. Flagged to him directly rather than guessing further.

**Fixed regardless of the source** (`hot-privatenexus` commit `d272bd3`, pushed to `github`+
`codeberg` mirrors — `origin`/Forgejo unreachable behind the dead bare metal, same as every other
push this session): `discovery-agent.sh` now skips any container whose image starts with
`curlimages/curl` before building its candidate list, so this class of ephemeral probe container
can never be queued as a discovery candidate again, whatever process turns out to be creating them.
Archived the two bad service rows directly via SQL (`services.archived=true`, matching the exact
`PATCH /services/:id` admin route's effect) with matching `audit_log` rows explaining why — kept
the audit trail rather than hard-deleting, consistent with the archive-not-delete pattern used
throughout this app's governance work.

**Update 2026-07-22 (later session) — hot-bm-nl checked again, no change.** Ping alive (18ms),
SSH still refused. Cross-checked against the invapi API (`eq.php action=show id=22272`, read-only)
rather than relying on network probes alone: confirms `"OS": null`, same as the accidental-wipe
state from earlier the same day. `eq/status`, `eq/console`, and `eq/ovirt_novnc` all returned
nothing but a fresh opaque `callback` ID each call — reconfirms the already-documented gap that
this API has no real way to poll operation progress. Noticed the API key's permission list
includes `eq/boot_dev` — plausibly the same action the Hostkey panel's boot-order toggle drives —
but did **not** call it: every `eq/*` write action on this API executes immediately with no
dry-run (the exact mechanism that caused the accidental OS wipe earlier the same day), and its
parameter contract isn't confirmed safe. Asked Mr. Byrne rather than guess; he chose to leave it
for the panel (flip boot order to HDD himself), not attempt the API route. **How to apply:** don't
re-check this box proactively — same standing instruction as before, wait for Mr. Byrne to do the
panel step or raise it again himself. If asked to try the API route in a future session, look for
`eq/boot_dev`'s parameter contract via read-only means first (same approach that worked for
`os_id` via `os.php action=list`) rather than probing it directly.

**Update 2026-07-22 (moments later) — Mr. Byrne flipped the boot order himself; reinstall now
actively running.** Confirmed independently, not just taken on his word: `ping` flipped from
18ms/alive to 100% loss (VM rebooting/reprovisioning), and `eq.php action=show`'s `reinstall`
field went from empty string to a populated job ID (`8228b6bd65a4ffce97e191902487e872`) — `OS`
still `null` as expected mid-install. **How to apply:** next check should watch for `ping` coming
back first (network/hypervisor layer), then SSH becoming reachable (OS actually booted) — same
"direct SSH/ping polling is the reliable signal, not the API" pattern documented earlier in this
file. Once SSH is up, redo the full post-provision sequence from scratch (this is a fresh Debian
12 install, not a resume): SSH key → root password rotation + Vaultwarden update (replace, not
supplement, the now-dead entry) → hostname → LVM RAID1 mirror (small root LV + modest swap this
time, see the partition-planning note above) → regenerate wg4's hot-bm-nl-side keypair → *then*
Proxmox VE itself.

**Update 2026-07-22 (later same day) — reinstall completed, but Hostkey deployed a pre-built
ProxmoxVE 9 image, not a bare Debian 12 install; this invalidates several planning assumptions
above.** Confirmed via the "[HOSTKEY] Reinstall for 22272 is done" email (mailbox UID 22046, sent
22:18 CEST — CS-504413 thread) and verified live over SSH (password from that email): OS is
**Debian 13 (trixie)**, kernel `7.0.14-6-pve`, `pveversion` reports **pve-manager/9.2.5** already
installed and all core services (`pve-cluster`/`pvedaemon`/`pveproxy`/`pvestatd`) active out of the
box. The CS-504413 ticket subject says "reinstall to debian" but Hostkey's actual provisioning
apparently used their "ProxmoxVE 9 community edition" application image — so the manual "install
Debian 12 → add PVE apt repo → `apt install proxmox-ve`" step from the plan above is now moot,
already done, just landed on PVE 9 (Debian 13 base) instead of the PVE 8.x/Debian 12 line every
prior note assumed. Worth knowing if any PVE-version-specific behavior (API differences, VLAN-aware
bridge config syntax, storage.cfg format) is assumed later — check against PVE 9 docs, not PVE 8.

**Real state found (all read-only checks, nothing destructive done to storage/network yet):**
- **Disk**: two 3.6T (8TB raw) disks, `sda`/`sdb`. Only `sda` is used — Hostkey's own auto-partitioner
  put `sda3` into a single LVM VG (`vg22272`) and gave the entire thing to `root` (`vgs` shows
  **0 free**), plus a 4G `swap` LV. **`sdb` is completely untouched** — not mirrored, not in any VG,
  raw. This directly contradicts the "leave free space in the VG for local-lvm + RAID1 headroom"
  partition plan above — that plan assumed we'd control partitioning during a manual Debian install;
  Hostkey's automated PVE image install took that choice away. `pvesm status` shows only the default
  `local` (dir-type) storage — **no `local-lvm` exists**, so there's currently nowhere sane to put
  VM disks with thin-provisioning/snapshots. Real open question for Mr. Byrne: shrink `root` to free
  VG space for `local-lvm` on `sda` alone, or bring `sdb` into an LVM RAID1 mirror with `sda3`
  (matching the original bare-metal's "2×8TB HDD mirror" design) and rebuild storage on top of that,
  or something else. Not decided, not started.
- **Network**: only `ens1` (the single public NIC, DHCP) is configured, no `vmbr0` bridge exists at
  all yet. VLAN-aware bridging for 10/20/30/40/50/60/70 (the whole point of this migration) hasn't
  been started — this is greenfield network config work, not a resume.
- **Hostname**: still Hostkey's default (`proxmox22272.hostkey.in`) — see the mistake below for why
  this was intentionally left alone rather than renamed to `hot-bm-nl` as originally planned.

**Post-provision access redone:** Gateway's SSH key (`/root/.ssh/claude_code_key`) added to
`~/.ssh/authorized_keys`, verified key-based login before relying on it (matches the standing
pattern). Root password rotated via `chpasswd` over the working key session (new password
generated with `openssl rand`, sitting in this session's scratchpad pending a Vaultwarden write —
**not yet saved to Vaultwarden**, needs Mr. Byrne's `bw unlock --raw` session token, same one-off
pattern as every other vault write on this fleet; the old "hot-bm-nl root password" Vaultwarden
entry from the pre-wipe install is now fully dead and should be replaced, not supplemented, once
the new one is written).

**⚠ Real mistake #2 on this same box — hostname rename broke Proxmox's own hostname resolution,
caught and reverted within the same check, not left broken.** Ran `hostnamectl set-hostname
hot-bm-nl` following the original plan's step order ("hostname" comes right after password
rotation) — this is safe on an ordinary Linux box but **not on an already-provisioned Proxmox
node**: PVE's node identity is fixed at install time and baked into `/etc/pve/nodes/<name>/`
(here, `proxmox22272` — matches the Hostkey-assigned default hostname the PVE installer ran under),
and is *not* a simple hostname-rename operation post-install (real PVE node renames need a specific,
riskier documented procedure, not `hostnamectl`). Caught immediately via `pvecm status` failing
with `hostname lookup 'hot-bm-nl' failed` right after the change (the OS hostname and `/etc/hosts`
went out of sync, and more importantly diverged from the PVE node directory name) — reverted with
`hostnamectl set-hostname proxmox22272.hostkey.in`, confirmed `hostname -f` resolves clean again and
all 4 core PVE services stayed active throughout (never actually went down, just the resolution
path broke). **How to apply: don't rename the hostname on a Proxmox node with a plain
`hostnamectl`/`/etc/hosts` edit — if a `hot-bm-nl` hostname is still wanted, that needs the real PVE
node-rename procedure (or accepting `proxmox22272.hostkey.in` as the permanent node name) — ask
Mr. Byrne which, don't just retry the naive approach.** This is the second real mistake made against
this specific box today (see the earlier accidental OS-wipe entry above) — same root cause pattern
both times: assuming a normally-safe action is equally safe against Proxmox's own internal state
without checking first.

**How to apply, overall:** Proxmox VE 9 itself is up and reachable (`ssh hot-bm-nl` alias works,
key-based) — that's real progress, most of the "install Proxmox" work is done. But storage layout,
network bridging, hostname, and the wg4 hot-bm-nl-side tunnel (its keypair was wiped by the reinstall
like expected, not yet regenerated) are all still open, and the storage/hostname questions in
particular are real architecture decisions that shouldn't be picked unilaterally given this box's
track record today. Next session: get direction from Mr. Byrne on (1) storage layout given `sdb` is
untouched and `sda`'s VG has zero free space, (2) whether to pursue the real PVE node-rename or keep
`proxmox22272.hostkey.in`, then regenerate wg4's hot-bm-nl-side keypair, build `vmbr0`, and only then
start on VLAN-aware bridging for the 7-VM fleet per `HoT_Bare_Metal_Migration_Checklist.md` (which
still needs the rewrite noted above regardless of any of this).

---

**Another reinstall happened 2026-07-23 (Mr. Byrne-driven, not by me) — lost from my context across
a compaction, caught 2026-07-24 only because a changed SSH host key on the public IP forced the
question.** Box uptime on 2026-07-24 confirmed ~1 day, matching. State after this reinstall: PVE
9.2.5 / Debian 13 (trixie), hostname already back to `proxmox22272.hostkey.in` (the revert from the
mistake documented above held). Storage: same single `hot-bm-nl-vg` on `sda`, but now ~46GB free in
the VG (not 0 as before) — still only `local` (dir) registered in Proxmox, no `local-lvm` thin pool.
`sdb` (3.6TB) still completely untouched. **Storage/hostname decisions are still open** — nothing
about this reinstall resolved them, ask Mr. Byrne before touching either.

**Lesson: reinstalls of this box need to be logged here immediately when they happen, not left to be
inferred later** — this one only surfaced because `ssh hot-bm-nl` over the public IP threw a
`REMOTE HOST IDENTIFICATION HAS CHANGED` warning, which could just as easily have been a real MITM/
compromise indicator. Don't silently `ssh-keygen -R` past that warning — confirm with Mr. Byrne first
(done correctly this time, but only because the timing happened to prompt a question).

**wg4 tunnel rebuilt + UFW locked down 2026-07-24 (following this reinstall):** the reinstall wiped
`/etc/wireguard/` on hot-bm-nl entirely (expected, keys aren't preserved across a reinstall) and no
`ufw` was installed at all — the box was sitting with SSH open to the whole internet on its public
IP with zero firewall. Fixed:
- New wg0 keypair generated on hot-bm-nl (`Address = 10.10.3.2/24`, `ListenPort = 51824`, `Endpoint`
  pointed at the Gateway's public IP so hot-bm-nl initiates). Gateway's `/etc/wireguard/wg4.conf`
  peer `PublicKey` updated to match (old one was permanently dead — private key wiped by the
  reinstall) and `wg-quick down/up wg4` cycled to pick it up. Handshake confirmed within seconds,
  ping and SSH both verified working over the tunnel **before** touching the firewall, to avoid a
  lockout.
- `ufw` installed on hot-bm-nl, brought up with SSH temporarily open publicly + the wg4 port, then
  tightened once the tunnel was proven live: `ufw delete allow 22/tcp` (both v4 and v6) +
  `ufw allow from 10.10.3.1 to any port 22 proto tcp` — public SSH now hard-closed (verified: public
  IP SSH times out, tunnel SSH still works), matching the "bare metal has zero public-facing ports"
  rule in CLAUDE.md. `51824/udp` stays open to the world (required for the tunnel peer to reach it).
- `/root/.ssh/config`'s `hot-bm-nl` alias repointed from the public IP (`31.207.47.146`) to the
  tunnel IP (`10.10.3.2`), matching the `proxmox` alias's existing pattern of never using bare
  metal's public IP directly. Public IP kept only as a comment for reference.

Still open, unchanged by any of this: storage layout (`sdb` unused, no `local-lvm`), the real
PVE node-rename question, `vmbr0`/VLAN-aware bridging, and the 7-VM fleet migration itself.

---

**Major decision 2026-07-24: erp-temp and pn-vps made PERMANENT, not folded back into bare metal.**
Prompted by a direct question from Mr. Byrne after the hot-bm-nl wg4/UFW rebuild work above — he
pushed back on the assumption that these two stand-in VPS's would be retired once hot-bm-nl was
ready, pointing out the collective cost of erp-temp + hot-pn is still less than running bare metal
+ Gateway together, and that keeping them permanently split off from bare metal avoids a repeat of
this exact outage (bare metal down 3+ weeks, and the replacement candidate itself has needed two
reinstalls before anything's even running on it). Same reasoning as [[vaultwarden_gateway_placement]]
— deliberately keep the highest-stakes workloads off the single point of failure. Decision:
- **hot-erp** (formerly erp-temp) stays ERPNext's permanent home. Mr. Byrne may move this specific
  workload to a proper dedicated Hostkey server at some point instead of this spare VPS — not
  decided or scheduled, a later-date question.
- **hot-pn** (formerly pn-vps) stays PrivateNexus's permanent home — both Mr. Byrne's personal use
  and ongoing PrivateNexus product development.
- The other 4 original VMs (sn-infra, sn-web, sn-monitor, sn-security) get consolidated onto
  hot-bm-nl once it's ready — low-stakes, near-fully reproducible from `hot-config`.
- **Role purpose noted, action deferred**: Mr. Byrne said ERPNext (hot-erp) is intended to also
  eventually host backend software for client companies who ask for it — explicitly "for a later
  date," not started, no timeline. Don't start building multi-tenant ERPNext hosting unprompted.
- **Open question, not addressed yet**: sn-personal and pn-test's original purpose (PrivateNexus
  staging/dev) is now moot since PrivateNexus permanently lives on hot-pn — whether those 2 VMs get
  repurposed or retired once bare metal is back hasn't been decided. Ask before assuming either way.

**Renamed erp-temp → hot-erp, pn-vps → hot-pn (2026-07-24)**, matching the `hot-bm-nl` naming
convention for standalone non-VLAN-mesh boxes. Scope of what was actually renamed:
- OS hostname on both boxes (`hostnamectl set-hostname` + `/etc/hosts` — neither box had "erp-temp"/
  "pn-vps" as its real OS hostname before this; those were Hostkey-assigned defaults `srv900420`
  and `4683.example.ch`). Safe to do directly on these — unlike hot-bm-nl, neither is a Proxmox node,
  so no `/etc/pve/nodes/` internal-state risk.
- `/root/.ssh/config`: `hot-erp`/`hot-pn` are now the primary aliases; `erp-temp`/`pn-vps` kept as
  secondary aliases on the same `Host` line for a transition period (both work identically) — drop
  them later once nothing still references the old names.
- CLAUDE.md: section headers, Network Topology (wg2/wg3), and the Backup Architecture table row
  updated to the new names with an inline "formerly X" note. **Deliberately NOT rewritten**: the
  extensive dated historical narrative entries throughout CLAUDE.md's hot-pn/hot-erp sections still
  say "pn-vps"/"erp-temp" — those are a log of what was true at the time, left as-is rather than
  rewriting hundreds of historical mentions.
- **Not yet renamed (flagged, not done)** — deeper internal identifiers that carry real operational
  risk if renamed carelessly: the `backup-pn-vps-privatenexus-db.sh` script filename + its cron
  entry on the Gateway, `/opt/hot-config/erp-temp/dickson/` directory path, the `monitoring-temp`
  stack directory name on hot-pn, Docker network/compose project names, and whatever Prometheus
  `instance` label or `VM_NAMES`-style hardcoded mapping `ops.js` uses internally (audited earlier
  as falling back to a literal `"pn-vps"` label). None of these block anything — purely a naming
  consistency gap if left alone. Ask Mr. Byrne before touching any of them, since some are
  live-automation-referenced paths, not just cosmetic strings.

---

**Storage decision reversed mid-session 2026-07-24 — no more reinstalls.** Initially recommended
(and Mr. Byrne approved) a ZFS-mirror reinstall of hot-bm-nl. Before executing, discovered via
Hostkey's own invapi (`eq.php?action=show&id=22272`) that hot-bm-nl's `"Platform"` is `"Ovirt VM"`
— it's a **virtualized VPS on Hostkey's oVirt infrastructure, not colocated physical bare metal**.
This weakens the ZFS-mirror-for-redundancy rationale (two virtual disks likely sit on the same
underlying physical array already, so mirroring them buys little real protection) and Mr. Byrne
independently said no to another reinstall regardless ("im not reinstalling again"). **Final
storage layout, done non-destructively, no reinstall:** left `sda`/root exactly as it was (single
`hot-bm-nl-vg` LVM, `local` dir storage) and created a standalone `local-zfs` pool on the
previously-idle `sdb` (`zpool create -o ashift=12 -O compression=lz4 -O atime=off local-zfs
/dev/sdb`, registered via `pvesm add zfspool`), weekly scrub cron added
(`/etc/cron.d/zfs-scrub-local-zfs`, matches the original rpool convention). No mirror redundancy,
but that tradeoff is now a deliberate, informed choice, not an oversight.

**⚠ IMPORTANT — server 22272 is a Hostkey invapi note worth re-reading before touching this
account's API again:** `hostkey_invapi_notes` memory documents that `eq.php?action=reinstall`
executes immediately with no dry-run, even when probed with missing params — nearly triggered a
reinstall again this session before catching it via read-only `eq/show`/`os/list` first. That
discipline is why the oVirt-VM discovery above was made safely. Keep following it.

**vmbr0 + VLAN-aware bridging built 2026-07-24, no reinstall needed:** added a VLAN-aware Linux
bridge (`bridge-ports none` — no physical port, purely internal, since this is a VPS not colocated
hardware trunked to a real switch) via `/etc/network/interfaces` + `ifreload -a` (ifupdown2 is
installed, live-apply without rebooting — critical since a reboot risked losing the only access
path over the wg4 tunnel). Host-side gateway IPs added for VLANs actually needed now: `vmbr0.10`
(10.10.10.1), `vmbr0.30` (10.10.30.1), `vmbr0.50` (10.10.50.1), `vmbr0.70` (10.10.70.1) — VLANs 20
(sn-business) and 40 (sn-personal) deliberately excluded since those roles permanently moved to
hot-erp/hot-pn; VLAN 60 (pn-test) excluded pending the still-open decision in this memory. IP
forwarding was already on by default (`net.ipv4.ip_forward=1`).

**⚠ Real mistake made and fixed live during this same step — briefly took wg4 down:** editing the
Gateway's `wg4.conf` to add the new VLAN subnets to `AllowedIPs`, then `wg-quick down/up wg4`,
failed with `RTNETLINK answers: File exists` on the `10.10.70.0/24` route add — **`wg0`'s stale
routes for those exact subnets, left over from the original wg0 tunnel to the now-permanently-
decommissioned server 145990, were still occupying the kernel routing table** even though wg0's
peer has been unreachable for weeks. `wg-quick`'s all-or-nothing failure mode tore the newly-created
wg4 interface back down on that error, leaving wg4 (and hot-bm-nl SSH access) briefly dead. Fixed by
running `wg-quick down wg0` (safe — that server can never come back, it's decommissioned and
refunded) and `systemctl disable wg-quick@wg0` (so it can't resurrect this same conflict on a
Gateway reboot), then `wg-quick up wg4` succeeded cleanly. **How to apply: before adding any new
route/AllowedIPs range to a WireGuard tunnel, check `ip route | grep <subnet>` first for a
conflicting stale route from another interface — don't assume a dead tunnel's routes are harmless
just because its peer is unreachable, they still occupy the kernel routing table.**

Also fixed: hot-bm-nl's `/etc/network/interfaces.new` was a stale staging file from initial
provisioning (Jul 23, before any manual edits) — Proxmox's own network API (`pvesh get
.../network`) reads from `.new` in preference over the live file when it exists, so it was
reporting only `ens1` and hiding vmbr0 entirely from Proxmox's own view even though the interface
was actually up and working at the OS level. Fixed by copying the live `interfaces` over
`interfaces.new` so Proxmox's tracked config matches reality — confirmed via `pvesh get network`
correctly listing `vmbr0` (type `bridge`) and all 4 VLAN sub-interfaces (type `vlan`) afterward.
**Watch for this same staleness on any Proxmox node where `/etc/network/interfaces` was hand-edited
instead of driven through Proxmox's own network UI/API.**

Also added UFW routing rules on hot-bm-nl (default `deny (routed)` would otherwise block all
forwarded traffic to future VMs): `ufw route allow in on wg0 out on vmbr0 from 10.10.0.0/16 to
10.10.0.0/16` and the reverse — matches the fleet's established "/16, not exact IPs" convention
(Proxmox VLAN routing rule in Operational Rules).

Verified end-to-end: all 4 VLAN gateway IPs (10.10.10.1/30.1/50.1/70.1) ping cleanly from the
Gateway over wg4 (~19ms). No VMs exist on any VLAN yet — next step is actually building
sn-infra/sn-web/sn-monitor/sn-security there, tracked as a separate open task.

**sn-personal / pn-test decision made 2026-07-24: drop both, don't rebuild.** Their original
purpose (PrivateNexus staging/dev) is fully redundant now that PrivateNexus permanently lives on
hot-pn. Considered repurposing sn-personal for the Phase 4 "HoT Sync" roadmap item (Immich +
Nextcloud + Notesnook + Vaultwarden — there's already an unused `personal` Keycloak realm sitting
ready for exactly this, and these services ran on sn-personal before Cosmos removal with no data
to lose) — Mr. Byrne liked the idea but wants to revisit it separately later, not bundle it into
this fleet-rebuild pass. **VLAN 40 and VLAN 60 are not part of the hot-bm-nl rebuild** — only
VLANs 10/30/50/70 (sn-infra/sn-web/sn-monitor/sn-security) are being recreated. If HoT Sync gets
picked up later, it'll need its own fresh scoping conversation (which VM/VLAN, whether it reuses
the old `personal` realm as-is or needs updates, etc.) — don't assume this note is a green light to
just build it unprompted.

**Rebuild order decided: sn-infra first** — restores Forgejo (hot-config's own `origin` remote,
currently unreachable) plus PowerDNS-Admin and Ntfy alerting, unblocking the most other stuff.
Then sn-security (Wazuh — the one VM with real non-reproducible SIEM history, worth restoring
before that trail goes any colder), then sn-web and sn-monitor in whatever order.

---

**⚠ MAJOR BLOCKER 2026-07-24: hot-bm-nl cannot run real VMs at all — no nested virtualization.**
Got as far as creating VM 100 (sn-infra: Debian 12 cloud image, cloud-init networking on
`vmbr0` VLAN 10, 10.10.10.100/24) and it failed to start: `KVM virtualisation configured, but not
available`. Confirmed via `/proc/cpuinfo` (zero `vmx`/`svm` flags) and `/dev/kvm` not existing —
Hostkey's oVirt hypervisor isn't exposing hardware virtualization to this VPS at all. Proxmox
itself runs fine (it's just software), it just has nothing to actually run guest VMs with. VM 100
left in place (stopped, harmless) in case this gets resolved — don't delete it reflexively.

**Mr. Byrne's decision: try asking Hostkey to enable nested virt first; if that fails, fall back to
running everything as Docker stacks directly on the hot-bm-nl host OS (no VM layer at all — matches
how hot-erp/hot-pn already work, loses VM-level isolation between sn-infra/sn-web/sn-monitor/
sn-security but avoids the hardware limit entirely).** A third option (LXC instead of VMs) was
raised and explicitly NOT chosen since it conflicts with the documented "No Docker in LXC" rule.

**Support ticket opened: CS-505879** (`jira.php?action=request_assistance`, NOT `rtm.php` — see the
API-notes correction below), asking Hostkey to expose VMX/SVM to server 22272. **Status: pending a
reply as of 2026-07-24 — do not assume failure and jump to the Docker-on-host fallback without
either an explicit "no" from Hostkey or Mr. Byrne deciding to stop waiting.** Check
`jira.php?action=... ` — actually check via `rtm.php?action=get_ticket_by_id&ticket_id=<issueId>`
(the ticket IS readable through rtm.php even though it had to be *created* through jira.php) for
replies before resuming this task.

**API correction for [[hostkey_invapi_notes]]: opening a NEW support ticket is `jira.php?
action=request_assistance`, not `rtm.php?action=open_ticket`** (the latter consistently returned a
bare `{"result":"error"}` with zero detail no matter what params were tried — probably exists for
something else or is deprecated/internal-only). Required params: `id` (server ID, integer) and
`terminate_reason_custom` (yes, that's really the field name for "detailed problem description" —
oddly named, reused from a termination-request form, but confirmed safe to use for a generic
assistance request as long as the optional `cancellation_type`/`terminate_*` fields are left
omitted entirely). Response gives `jira_issue` (e.g. `CS-505879`) and `jira_url`. Once created,
`rtm.php?action=get_ticket_by_id&ticket_id=<numeric issueId, not the CS-xxxxx key>` reads the full
comment thread — confirmed working against the pre-existing CS-504413 ticket. `rtm.php?
action=get_tickets` (no extra params) lists all tickets across the account, useful to check
before opening a new one to avoid duplicates.

---

**⚠ Consequence of the wg0 teardown above, caught and fixed 2026-07-24: PowerDNS API went dark
mesh-wide.** PowerDNS's docker-compose binds to the specific IP `10.10.0.1:8081`, which was
literally the Gateway's own address *on the wg0 interface* — deleting wg0 deleted that address
entirely, leaving `docker-proxy` phantom-listening on an IP that existed nowhere. Only caught
because Mr. Byrne was doing real hands-on UI testing of PrivateNexus and saw it flagged down on the
Dashboard — nothing in my own verification after the wg0/wg4 work caught this. Fixed by adding
`10.10.0.1/32` to loopback via a new enabled systemd unit
(`powerdns-loopback-ip.service`), not by reviving wg0. Full detail in CLAUDE.md's hot-pn section
(search "PowerDNS API went unreachable"). **Lesson: tearing down a WireGuard interface can silently
break anything bound to that interface's own IP, not just routes through it — check `ss -tlnp` /
`docker ps` port bindings against an interface's addresses before deleting it, not just the routing
table.**

---

**Update 2026-07-26 — "phantom reinstall": Mr. Byrne believed he'd reinstalled hot-bm-nl again
after a lockout, but he hadn't — it was just a ~2-day outage.** He reported getting locked out of
hot-bm-nl entirely (no SSH, no working native/rescue console) and, believing a reinstall was the
easiest recovery path, said he'd already started one via Hostkey's panel. Checked live rather than
trusting the report: SSH over wg4 connected immediately, and every artifact pointed at the same
2026-07-23 install, not a fresh one — `/etc/machine-id` birth date `2026-07-23 01:43`, `last -x`
showing the box was simply powered off from `2026-07-24 16:37` to `2026-07-26 22:26` (uptime 2 min
at check time) then came back, and wg0/UFW/vmbr0+VLAN bridges/the `local-zfs` pool/VM 100 all still
present exactly as the 2026-07-24 entries above describe. Confirmed definitively via Hostkey's own
API (`eq.php?action=show&id=22272`): the `reinstall` field was empty and `OS` still read
`Debian 13` — **no reinstall job was ever actually queued or run**, despite Mr. Byrne's belief that
one was in progress. Presented this to him; he chose to leave the box as-is rather than reinstall,
since nothing was actually lost.

**How to apply:** if a future session is told "we reinstalled hot-bm-nl again," don't take it at
face value — check `eq.php?action=show`'s `reinstall`/`OS` fields and the box's own
`/etc/machine-id` birth time / `last -x` boot history first. This is now the second time this box's
actual state has diverged from what was believed about it (see the 2026-07-24 "lost from context
across a compaction" entry above) — always re-verify live rather than trust a carried-forward
assumption, in either direction (assuming it's fine when it's been wiped, or assuming it's wiped
when it's actually fine).

**Also discovered/actioned this session — Hostkey's nested-virt fix (CS-505879) doesn't actually
work yet.** Ticket CS-505879 (opened 2026-07-24, asking Hostkey to enable nested virtualization
after the "hot-bm-nl cannot run real VMs at all" blocker above) shows Hostkey replied 2026-07-24
14:02 CEST claiming "We have enabled nested virtualization for your VPS," and the ticket
auto-closed 2026-07-26 01:27 CEST with no further action from our side. Live-verified this was
premature: even after a **full `eq/off` + `eq/on` power cycle** via the invapi (not just an in-guest
`reboot`, since the fix is CPU-flag-passthrough and plausibly needs a real hypervisor-level
stop/start to take effect — confirmed via API polling and ping, box was down ~18s of ping-loss then
back within ~90s), `/proc/cpuinfo` still shows zero `vmx`/`svm` flags and `/dev/kvm` still doesn't
exist. `qm start 100` still fails with the same `KVM virtualisation configured, but not available`
error as before. Everything else survived the power cycle cleanly (wg4 re-handshook in ~30s,
vmbr0/VLAN bridges, local-zfs pool, UFW rules all intact — confirmed individually, not assumed).

**How to apply:** CS-505879's "resolved" status is not trustworthy — Hostkey's own fix has not
actually landed despite them saying so and the ticket auto-closing. Next step is reopening
CS-505879 (or filing a fresh `jira.php?action=request_assistance`, same pattern as before) stating
explicitly that a full power cycle was tried post-fix and the flags are still absent — don't just
re-ask the same question, cite the power-cycle test so their team doesn't repeat "have you tried
restarting it." This is still the live blocker on running any guest VMs on hot-bm-nl (sn-infra,
sn-web, sn-monitor, sn-security rebuild all wait on this) — Mr. Byrne's fallback-if-this-fails
decision from 2026-07-24 still stands: Docker stacks directly on the host OS, no VM layer, if
Hostkey can't actually deliver nested virt for this VPS class.

**Follow-up sent 2026-07-26: CS-506937 filed, referencing CS-505879.** Tried to comment directly on
the closed CS-505879 thread first via `rtm.php?action=add_comment` — confirmed the correct field
names are `ticket_id` + `message` (every other name either errors "Ticket id required" or "Empty
message"), but even with the right fields it returned `"Ticket not found or you has no
permissions"` once the ticket was closed; `rtm.php?action=toggle_ticket_status` also failed
(`"Authorization required"`, a different error, not tried further). **New finding for
[[hostkey_invapi_notes]]: closed tickets can't be commented on or reopened via this API role at
all — the only working path for a follow-up is a brand-new `jira.php?action=request_assistance`**
(same call used to originally open CS-505879), with the old ticket number mentioned in the message
body for context since there's no real "linked ticket" field. Sent via
`terminate_reason_custom` (same oddly-named field as before) explicitly citing the eq/off+eq/on
power-cycle test and asking Hostkey to re-check the oVirt node-level config. New ticket:
**CS-506937**. Awaiting reply — check via `rtm.php?action=get_ticket_by_id&ticket_id=<numeric
issueId, not the CS- key>` once Hostkey responds, same as every other ticket on this account.

---

**Update 2026-07-26 (same session) — CS-503992 refund request revisited, turned out to still be
live (account balance is not $0 like previously assumed), follow-up sent as CS-506940.** The
2026-07-21 entry above assumed the account credit balance hit $0.00 after paying for the hot-bm-nl
NL order and treated CS-503992 (refund $118.25) as moot. Checked live via `whmcs.php?
action=get_client` rather than trust that stale assumption: **current balance is $112.94** — later
refund credits (Invoice 589458 $69.91, invoice 583723 $76.90, invoice 569173 $25.63, all landing
2026-07-16) rebuilt the balance after the $58.20 NL-order payment, minus a small $5.31 applied to a
later invoice (#592250, 2026-07-22). CS-503992 itself is still `status: "open"` — Hostkey's Veronica
asked on 2026-07-21 whether to refund or keep as credit, and no reply was ever sent confirming
either way. Asked Mr. Byrne; he chose refund to PayPal (matching the earlier payout preference).

Tried replying directly on the CS-503992 thread via `rtm.php?action=add_comment` first — failed
with `"Ticket not found or you has no permissions"` even though the ticket is open (not closed like
CS-505879 was) — see [[hostkey_invapi_notes]] for the fuller writeup, this looks like a broken
permission for this API role generally, not specific to closed tickets. Fell back to a new
`jira.php?action=request_assistance` call referencing CS-503992 by number — first attempt reused
server id `22272` and hit a dedup error since CS-506937 (the nested-virt follow-up, filed minutes
earlier) was still open against that same server ID; worked by using server id `50265` (the Gateway
VPS) instead, since the dedup key is per-server-ID not per-topic. New ticket: **CS-506940**,
confirming the refund-to-PayPal request with the current $112.94 balance stated explicitly.
Awaiting Hostkey's reply — same `rtm.php?action=get_ticket_by_id` check as CS-506937.

**How to apply:** don't trust a stale "balance is $0" note without re-checking
`whmcs.php?action=get_client`'s `credit` field live — this account's balance has moved multiple
times since via refund credits landing after the fact. If Mr. Byrne asks about the refund again,
check this ticket and the live balance fresh rather than reciting the 2026-07-21 assumption.

---

**Update 2026-07-26 (later same session) — Hostkey replied to CS-506937: nested virt re-enabled at
the hypervisor level, needs a power cycle to apply. Separately, hot-bm-nl went unreachable on its
own right as this landed.** Maxim Ryazantsev replied: "We have re-enabled nested virtualization on
the hypervisor/node level for your VPS. Please perform a full power cycle to apply the changes." —
worded differently from the 2026-07-24 reply on CS-505879 (which only said "enabled," not
"hypervisor/node level"), suggesting the first fix really was guest-level/incomplete and this one
is the real thing. **Not yet verified live** — right around when this reply was checked, hot-bm-nl
independently went unreachable (public IP + wg4 both down, `mtr` shows the path dying right at
Hostkey's edge, not a Gateway-side problem) — unprompted, not caused by any action this session
(last successful check was the post-power-cycle verification, several minutes before). Hostkey's
`eq/show` reports nothing wrong (`status: rent`, `OS: Debian 13`, no reinstall) — consistent with
the already-documented gap that this API has no real live-status visibility.

**How to apply:** once hot-bm-nl comes back (self-recovers or needs another `eq/off`+`eq/on`), the
outage itself may double as the power cycle Hostkey asked for — check `/proc/cpuinfo` for
`vmx`/`svm` and `/dev/kvm` immediately once reachable, before assuming another deliberate power
cycle is still needed. If flags are present, try `qm start 100` (VM 100/sn-infra, already defined,
currently stopped) as the real end-to-end test. CS-506940 (refund) just got the standard
"forwarded to Sales & Billing" auto-ack, no real movement yet.

---

**Update 2026-07-30 — CS-506940 refund destination corrected: Stripe, not PayPal. Still not
processed, waiting per Mr. Byrne's instruction.** Checked the ticket via `rtm.php?action=get_ticket_by_id`
(numeric `ticket_id=1168696`, not the `CS-506940` key — same gotcha as always) and found a real reply
thread, not just the auto-ack: Veronica Gracheva confirmed 2026-07-27 the refund would go "through
the same gateway used for the initial transaction," then immediately corrected herself in the very
next comment — **"only Stripe was used in your payments... refunds can be processed only through the
initial gateway we will use this system."** So despite Mr. Byrne's stated PayPal preference (see the
2026-07-26 entry above), Hostkey's own records show Stripe as the actual original payment method, and
the refund will land there instead. Sent a follow-up via email (threads into the ticket automatically
as an "author":"You" comment — Hostkey's Jira has email-in integration, confirmed working) asking for
a status update; Andrey Vasiliev replied 4 minutes later (2026-07-30 00:51 UTC) reiterating the same
"within 10 business days, we'll inform you once it's done" — no new information, no completion
confirmation. Checked the live account balance directly (`whmcs.php?action=get_client`) rather than
trust the ticket text alone: still **$112.94**, unchanged — the refund has not actually processed yet.
**Mr. Byrne's decision: let it ride, don't push back on the Stripe-vs-PayPal point, just wait.**
**How to apply:** don't re-raise the PayPal question — Mr. Byrne has accepted Stripe as the refund
destination. Check the live `credit` balance (not just ticket status) to know when it's actually
processed — expect it to drop from $112.94 once the refund lands, and cross-check against a Stripe
account/statement if he ever asks for proof rather than trusting the ticket thread alone.

---

**Decision made 2026-07-26 (same session, box still down at decision time) — do the real PVE node
rename, `proxmox22272.hostkey.in` → `hot-bm-nl`.** Asked Mr. Byrne rather than defaulting to
"leave it" (my recommendation, for consistency-only risk-avoidance) — he chose to do the real
rename. **Not yet executed — hot-bm-nl was unreachable at decision time**, this is queued as the
next step once it's back, alongside the nested-virt verification and resuming the sn-infra Docker
work.

**Plan for when the box is reachable again** (more involved than the 2026-07-24 attempt since real
state now lives under the node directory — VM 100's config and the `local-zfs` storage
registration, not an empty dir):
1. `systemctl stop pvestatd pveproxy pvedaemon pve-cluster` (stop top-down; pmxcfs/`pve-cluster`
   last since the others depend on `/etc/pve` being mounted).
2. With `pve-cluster` stopped, `/etc/pve` is unmounted — start `pmxcfs -l` (local/standalone mode)
   to get a writable local copy of the config DB without full cluster locking.
3. `mv /etc/pve/nodes/proxmox22272.hostkey.in /etc/pve/nodes/hot-bm-nl`.
4. Fix `/etc/pve/local` (symlink → `nodes/hot-bm-nl`) and `/etc/pve/local/qemu-server` etc. — these
   are usually auto-created by pmxcfs based on the live hostname, so order matters: hostname change
   should happen *before* pmxcfs re-derives these, not after.
5. `hostnamectl set-hostname hot-bm-nl` + fix `/etc/hosts` (127.0.1.1 line).
6. Kill the local `pmxcfs -l` instance, restart real `pve-cluster` → `pvedaemon` → `pveproxy` →
   `pvestatd` in that order.
7. Verify before considering done: `pvecm status` clean (no hostname lookup failure, the exact
   failure mode from 2026-07-24), `pvesm status` still shows both `local` and `local-zfs`, `qm
   config 100` still resolves VM 100's config intact, `ssh hot-bm-nl` (alias) still works. Reboot
   once at the end to confirm it comes back clean cold, not just hot-patched — this box has a
   history of config that looks fine live but isn't actually persisted correctly (the
   `interfaces.new` staleness bug from 2026-07-24 is the precedent).

**How to apply:** don't skip step 7's reboot check — this box's track record (interfaces.new
staleness, the original naive-hostnamectl mistake) means "looks fine right now" isn't sufficient
proof for a change to `/etc/pve` internals specifically.

---

**⚠ MAJOR BLOCKER RESOLVED 2026-07-26 — nested virtualization genuinely works now.** hot-bm-nl came
back on its own from the unplanned outage (down ~20 min, self-recovered — never got a deliberate
`eq/off`/`eq/on` this time, the outage+auto-recovery cycle apparently did what a manual power cycle
would have). Verified live, not just `eq/show` optimism: `/proc/cpuinfo` now shows the `vmx` flag,
`/dev/kvm` exists (`crw-rw---- root:kvm`), and **`qm start 100` actually succeeded** — VM 100
(sn-infra) is running for the first time ever on this box. This closes the blocker opened
2026-07-24 and the CS-505879/CS-506937 ticket saga. `pvecm status` errors with "Corosync config
does not exist" — expected/harmless, this is a standalone node, not a cluster, not a new problem.

**How to apply:** the fleet migration is unblocked. Real next steps, in order: (1) do the queued PVE
node rename (`proxmox22272.hostkey.in` → `hot-bm-nl`, plan above) — now touching a *running* VM's
config directory, so extra care warranted, consider stopping VM 100 first; (2) finish provisioning
VM 100 as actual sn-infra (Debian 12 cloud image already selected per the 2026-07-24 entry, network
already wired to VLAN 10/10.10.10.100 — needs cloud-init credentials, then the real Forgejo/
PowerDNS-Admin/Ntfy stack deploy) rather than the Docker-on-host fallback, since VMs work now — the
fallback plan is moot, don't pursue it unless VM 100 hits some other blocker; (3) sn-security,
sn-web, sn-monitor per the existing rebuild order. No reply yet needed from Hostkey on CS-506937 —
their fix worked, can close the loop with a thank-you reply when convenient, not urgent.

---

**Update 2026-07-27 — hot-bm-nl joined Tailscale for Proxmox UI admin access, real HTTPS cert
installed.** Mr. Byrne asked why he couldn't reach the Proxmox web UI — turned out hot-bm-nl was
the only box in the whole fleet without Tailscale (every other VM/box uses it for admin access per
the standing "Tailscale = admin only" rule). Fixed:
- Generated a one-time preauthorized Tailscale auth key via the API (`/opt/stacks/tailscale-api/`
  key, see [[tailscale_api_key]]), `tailscale up --hostname=hot-bm-nl --ssh=false`. Joined as
  `100.90.156.88`. Added to CLAUDE.md's Tailscale overlay table and Quick Reference.
- Added a UFW rule scoped specifically to the `tailscale0` interface (`ufw allow in on tailscale0
  to any port 8006`) — port 8006 is NOT open on any other interface, so Proxmox UI access only
  works over the tailnet, matching the existing "bare metal has zero public-facing ports" model.
- **Replaced Proxmox's self-signed cert with a real one**, per Mr. Byrne's follow-up ask: `tailscale
  cert hot-bm-nl.spangled-atlas.ts.net` issues a genuine Let's Encrypt cert scoped to the tailnet's
  `.ts.net` domain (requires HTTPS certs enabled tailnet-wide, which they already were). Installed
  to `/etc/pve/local/pve-ssl.pem`/`.key` (backed up the originals first with a dated suffix),
  `systemctl restart pveproxy`. Verified via `openssl s_client` — real Let's Encrypt CN, not
  self-signed. **Set up monthly auto-renewal**: `/usr/local/bin/renew-tailscale-proxmox-cert.sh`
  (tracked in `hot-config` at `hot-bm-nl/scripts/`) + `/etc/cron.d/tailscale-proxmox-cert-renew`
  (1st of the month, 03:00).

Access is now: `https://hot-bm-nl.spangled-atlas.ts.net:8006` from any Tailscale-connected device,
trusted cert, no browser warnings.

**Also found and removed a stale Tailscale device while in there**: a device named `pve`
(100.125.223.41) had `lastSeen` of 2026-07-02 — exactly matching when the original decommissioned
EPYC 3151 bare-metal server's NIC died for good. Almost certainly its leftover Tailscale
registration, never cleaned up since that box can never check in again to remove itself. Deleted
via the API (`DELETE /api/v2/device/<id>`), confirmed `200`.
