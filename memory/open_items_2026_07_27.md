---
name: open-items-2026-07-27
description: "Full sweep of every open/deferred item across all memory files, CLAUDE.md, and docs/ as of 2026-07-27 — compiled after the 4-VM rebuild completed"
metadata: 
  node_type: memory
  type: project
  originSessionId: f361f2af-99b4-4220-ba53-a42472c872f0
  modified: 2026-07-30T00:12:59.204Z
---

Compiled 2026-07-27 at Mr. Byrne's request, by grepping every memory file + CLAUDE.md for
open-item indicators (not yet/pending/awaiting/flagged/not decided/etc.) and cross-checking each
hit against current live state rather than trusting the text blindly. One item found already
resolved during this sweep (Grafana SMTP password — confirmed matching the current rotated value
live, memory deleted per its own instruction).

**Re-swept 2026-07-30 (per this file's own "how to apply" instruction).** Re-grepped memory +
CLAUDE.md and cross-checked every hit against live state again. Resolved since the 07-27 pass:
- **Item 1 (LUKS2+Tang retrofit): now fully COMPLETE for all 4 VMs** (sn-monitor and sn-security
  finished 2026-07-28, after this file was originally written — see [[sn_web_luks_pilot_fix]]'s
  "Status: COMPLETE AND VERIFIED" close-out). CLAUDE.md's Network Topology diagram still said
  "retrofit pending" for all 4 — fixed 2026-07-30.
- **hot-bm-nl SMP hang (>2 vCPU boot hang)**: root-caused via a disposable test VM + live register
  inspection (genuine kernel spin loop, not a QEMU freeze); concluded to be a double-nested-virt
  limitation, not fixable from guest/Proxmox side. Mr. Byrne decided 2026-07-28 to keep
  sn-security permanently at `cores=2`. CLAUDE.md's hot-bm-nl (was wrongly documented as 4 vCore,
  actually 8) and sn-security specs (VM table + inline spec) corrected to match, and the stale
  "open decision" language in [[sn_web_luks_pilot_fix]]/[[sn_security_rebuild]] updated.
- **sn-infra loose ends, all 3 confirmed resolved live**: PowerDNS-Admin's `tristian` account is
  promoted to Administrator (role_id=1, confirmed in `pdns-admin-db`); Namevault has a real
  Anthropic API key configured (was a placeholder); `namevault.co.uk` resolves cleanly via public
  DNS end-to-end (was the DNSSEC DS-mismatch bug, fixed 2026-07-27, cross-verified now). See
  [[sn_infra_rebuild]] for detail.
- **Grafana's "Node Down" alert regex checked against real Prometheus job names** (prompted by
  finding the identical-looking bug on PrivateNexus's Alerts board) — ruled out, not a bug: this
  fleet's job names genuinely end in `-node` (`sn-infra-node`, `gateway-node`, etc.), unlike PN's
  `node-exporter` job name. No fix needed.
- **CS-506940** (Hostkey refund) — checked again, still no substantive reply, only 4 duplicate
  auto-generated "New assistance request" notifications (2026-07-26/27). Unchanged, still open.

**Still open, unchanged from 07-27, not re-verified live this pass** (items 6-27 below, the Phase 4
roadmap, and the PN roadmap gate items) — these all still require Mr. Byrne's direction/input
rather than live verification, so there's nothing to re-check without him. One addition: Forgejo's
`tristian` admin password (sn-infra) and Grafana's admin password (sn-monitor) both still need a
Vaultwarden write via Mr. Byrne's `bw unlock` — same standing pattern as every other pending vault
write, not new.

## Actionable now / soon
1. **LUKS2 + Tang retrofit** for sn-infra/sn-web/sn-monitor/sn-security — scoped 2026-07-27, see
   [[sn_security_rebuild]] for the earlier failed attempt and [[hostkey_server_replacement]] for
   the fleet context. **Prerequisite done**: Tang server installed and verified working on
   sn-infra. **sn-web (VM 102) pilot: COMPLETE AND VERIFIED 2026-07-27** — the first genuine
   success in this whole saga. See [[sn_web_luks_pilot_fix]] for the full writeup. Summary: the
   "genuinely mixed/random" flakiness across ~5+ attempts was never actually random — it was a
   fully deterministic 4-bug chain, misdiagnosed as random because QEMU screendump (VGA) is
   permanently frozen at the BIOS handoff on this boot method. Fixed via real serial-console
   capture (`pyte` terminal reconstruction): (1) wrong installer image (netinst-style, expects CD
   media never attached) → switched to the **netboot** variant; (2) DHCP attempted before the
   preseed file's own static-IP directives could load → fixed via static netcfg params on the
   kernel cmdline; (3) **fleet-wide**: the ad-hoc preseed HTTP server had no UFW rule, silently
   dropping the guest's fetch requests — likely the same bug that killed the original sn-security
   attempt; (4) the installer's default post-finish reboot looped back into the installer itself
   (boot args were hardcoded to the installer kernel), silently re-wiping and restarting from
   scratch — fixed with `d-i debian-installer/exit/poweroff boolean true`, then swapping
   `boot: order=scsi0` + removing the `-args` override once it powered off cleanly.
   **Verified end-to-end**: GRUB boots from the real disk (the exact step that killed
   sn-security's host-chroot approach), LUKS passphrase prompt appears on VGA (not serial, since
   the installed system's GRUB_CMDLINE_LINUX includes `console=tty0`), unlocked successfully via
   `qm sendkey`, reached a real login prompt, SSH confirmed working, real LUKS→LVM layout
   (`sda5_crypt` → `sn-web-vg-root`/`-swap`) confirmed via `lsblk`.
   **Tang/NBDE automatic unlock: DONE AND VERIFIED 2026-07-27** — sn-web now unlocks fully
   unattended on reboot, confirmed via a real reboot with zero manual input and log verification
   (`journalctl` showing "already active" before systemd's own cryptsetup service ran). Three
   things had to be fixed beyond just `clevis luks bind`: (a) real UFW/forward-rule gaps to both
   Tang servers that didn't exist for this new hot-bm-nl architecture (Gateway Tang's rule was a
   stale `/10.10.0.0/30` from the old NAT'd-bare-metal design; no direct VLAN30↔VLAN10 forward
   rule existed; sn-infra had no local rule for its own Tang port 80 from other VLANs) — none of
   this can be assumed just because other VMs can reach these services; (b) `clevis luks bind`
   fails silently over non-interactive SSH (a TOFU trust prompt needing a real TTY) — fixed by
   fetching each Tang server's `/adv` explicitly and embedding it in the bind config; (c) the real
   hard part — Debian's `clevis-initramfs` defaults to DHCP/RARP for early-boot networking, not
   the system's static `/etc/network/interfaces`, so it retried forever with no DHCP server
   present — fixed with an explicit static `ip=` kernel parameter in `GRUB_CMDLINE_LINUX`. Full
   8-step recipe for the remaining 3 VMs in [[sn_web_luks_pilot_fix]] — this is now a completely
   proven, repeatable process, not exploratory work.
   **sn-infra (VM 100): COMPLETE AND VERIFIED 2026-07-28** — same recipe, live production rebuild
   this time (Forgejo/git.securenexus.net, PowerDNS-Admin, Namevault, Ntfy), all fully restored
   from a manual pre-rebuild backup (no vzdump job exists on hot-bm-nl at all — real gap, DB dumps
   + data volumes + secrets pulled off-host before wiping) and verified reachable through Caddy
   with real data afterward. 6 new findings beyond the sn-web recipe, full detail in
   [[sn_web_luks_pilot_fix]]: (1) a VM that itself hosts fallback Tang can't dual-bind to itself
   (chicken/egg) — Gateway Tang only, and its own Tang *keys* must be preserved/restored so the
   rest of the fleet's existing fallback bindings don't silently break; (2) `console=tty0` in
   GRUB_CMDLINE_LINUX is actively harmful on VMs with `vga: serial0` (no real VGA) — swallows the
   LUKS prompt and all input into a console that can't initialize, looks exactly like a hung boot;
   fixed offline via qemu-nbd+chroot; (3) the serial socket only exists while the VM is running,
   attach socat after `qm start`, not before; (4) `clevis luks bind`'s wrapper silently failed
   where the same config worked via `clevis encrypt` — the reliable form is calling
   `clevis-luks-bind` directly with flags before the positional `PIN CFG` args; (5) fresh
   netboot+preseed installs have **no UFW at all** (unlike cloud-init-templated VMs) — fixed on
   both sn-infra and sn-web to match the fleet's permissive-default-plus-specific-rules
   convention; (6) preseed's `netcfg/get_hostname` didn't persist to the installed system, fixed
   manually post-install. Updated 14-step recipe (was 8) for sn-monitor/sn-security in
   [[sn_web_luks_pilot_fix]].
2. **CS-506940** (Hostkey refund ticket, $112.94) — still just the standard "forwarded to billing"
   ack, no real reply as of last check. See [[hostkey_server_replacement]].
3. ~~VM balloon targets not configured~~ **Fixed 2026-07-27.** Applied the original documented
   targets (same VM specs match exactly): sn-infra 2560, sn-web 2048, sn-monitor 3072, sn-security
   7168 (out of maxes 4096/4096/4096/8192). Verified live via `qm monitor <id> info balloon` —
   balloon devices active on all 3 then-running VMs, targets applied (Proxmox's balloon daemon
   adjusts gradually, not instant). Confirmed sn-security is genuinely using ~7.6GB of its 8GB
   right now (real Wazuh feed-build work, not misconfiguration) — the new floor just protects it
   from being squeezed below the documented 6GB minimum under host pressure going forward.
4. ~~CLAUDE.md's Network Topology section is stale~~ **Fixed 2026-07-27** — updated to reflect
   the completed rebuild (VM IDs, rebuild date, LUKS2+Tang retrofit noted as pending). Other spots
   in CLAUDE.md may still describe pre-rebuild state as current — this pass only covered the
   Network Topology diagram specifically, not a full document sweep.
5. ~~`HoT_Bare_Metal_Migration_Checklist.md` needs a rewrite~~ **Fixed 2026-07-27.** Replaced the
   old speculative ZFS-transplant/restore-from-backup phases with an accurate record of what
   actually happened (refund → vds.v1-storage-8 order → nested Proxmox → 4-VM rebuild → VLANs
   20/40 permanently off this host) plus the real residual items (LUKS2/Tang retrofit, VLAN 60
   fate, CS-506940, final clone-checklist cross-check). Old content kept in a "superseded" section
   for historical reference, marked do-not-follow.

## Added by Mr. Byrne directly, 2026-07-27
17. **Client websites need creating** — the 6 sn-web sites (stratus-digital.com, discreet-elite.uk,
    emerald-markets.net, rubyosiris.com, evilrabbitart.com, dickson-supplies.com) currently only
    have the minimal placeholder "Coming Soon" pages written during the sn-web rebuild — see
    [[sn_web_rebuild]]. Real site content/design for each still needs to be built.
18. **Email client OAuth (IMAP/SMTP) not built** — investigated 2026-07-27, resolved as "not a
    bug." Mr. Byrne clarified this meant SSO/OAuth login *inside an email client* (Outlook/
    Thunderbird), not the webmail pre-auth wall. Confirmed this was never built — same documented
    gap CLAUDE.md already flags under the SSO section ("True passwordless SSO into Roundcube would
    require enabling Docker Mailserver's OAUTH2/XOAUTH2 support... bigger scope, not yet done").
    Separately, the **webmail login gate itself was tested end-to-end and is genuinely healthy** —
    DNS, Caddy, oauth2-proxy, the Keycloak `oauth2-proxy` client (redirect URI + secret both
    verified matching live), and the full realm-federation broker chain (securenexus →
    house-of-trae) all check out clean, landing on a real error-free Keycloak login page.
    **Mr. Byrne separately reported a real live symptom** (webmail showing Roundcube directly with
    no login prompt, reproduced even in a fresh incognito window with zero cookies) — genuinely
    alarming since it ruled out session/cache reuse as the explanation. Investigated live:
    oauth2-proxy's logs showed every recent real browser hit correctly getting `401` on
    `/oauth2/auth` then `302` to `/oauth2/start` — no bypass visible server-side, and the Caddy
    container was confirmed running the exact on-disk config (no drift). Asked him to check the
    browser's Network tab for the real status code as the next diagnostic step; before that
    happened, **a second incognito attempt showed the correct Keycloak login page** — resolved on
    its own with zero server-side changes made in between. Conclusion: transient, most likely an
    ISP-level cache or DNS propagation delay on his end, not a HoT-side misconfiguration. Nothing
    to fix there. If real IMAP/SMTP OAuth is wanted, it's a genuine build task (Docker Mailserver
    config + Roundcube's `oauth2` plugin), not a fix — scope it properly before starting.
19. **Complete testing of PrivateNexus (PN)** — see the PN roadmap section below for the specific
    gate items this maps to (v5.0's 30-day autonomous-execution clean run, v6.0's remaining
    unchecked gate items).
20. **Complete wiki/encyclopedia for HoT and PN** — checked live: `wiki.house-of-trae.com` has a
    real Caddy route (`reverse_proxy 10.10.10.100:3030`) but returns a bare `502` — nothing has
    ever been deployed behind it. Not in CLAUDE.md's documented sn-infra service table at all, so
    this was either an informal addition on the original decommissioned VM or was always
    aspirational. No PN-side wiki route found either. Both need to be built from scratch, not just
    reconnected.
21. **Migrate all personal services to hot-pn** — ties into item 6 below (the "HoT Sync" idea) but
    Mr. Byrne's phrasing here is more specific: services should land on **hot-pn**, not a
    repurposed sn-personal VM. Treat this as the current direction for that decision rather than
    the open multiple-choice framing item 6 previously described — but still get his sign-off on
    which services and an actual migration plan before starting, this is still just a stated
    intent, not a scoped task.
22. **PrivateNexus: add a Vault feature** — a secure-storage area within PN, referenced against
    Google Drive's "Secure folder" as the comparison point. Not scoped yet (encryption model,
    what "secure" means concretely — client-side encryption vs. just access-gated storage, storage
    backend, whether it's part of the existing Files board or a new board entirely). Genuine new
    product feature request, not a bug/gap in something already built.
23. **PrivateNexus: add a Portals feature** — a place within PN that links out to *other* systems
    Mr. Byrne wants quick access to without hosting them inside PN itself. First concrete example:
    a link to his own ERPNext instance (used for his businesses) — he doesn't want ERPNext run
    inside PN, just reachable from PN's inventory/launcher alongside PN's other apps. Note: he said
    "sn-business" but per CLAUDE.md, ERPNext's permanent home is now **hot-erp**
    (erp.dickson-supplies.com), not sn-business — worth confirming which he means when this is
    scoped, since sn-business (VLAN 20) isn't being rebuilt on hot-bm-nl at all per the 2026-07-24
    decision. **Likely overlaps existing infrastructure**: PN already has a static app-launcher
    shortcut list (`apps.js`/the Catalogue board, confirmed in the 2026-07-16 route audit — "a
    static app-launcher shortcut list, same pattern as Catalogue, not a gap"). "Portals" may be an
    extension of that existing pattern (external links, not just internal registered services)
    rather than something needing to be built from scratch — worth checking that code first before
    scoping new work.

24. **PrivateNexus: revisit the visual design/aesthetics** — Mr. Byrne wants to work on how PN
    looks, not just what it does. Not scoped yet (no direction given on what's wrong with the
    current look, what feel he's going for, or whether this is a full redesign vs. targeted
    polish). Get his actual design direction/preferences before starting any visual changes rather
    than guessing at a style.

25. **Tor node + crypto node ("potentially")** — Mr. Byrne floated running a Tor node and a
    cryptocurrency node, explicitly tentative, not committed. Note there's already a Tor
    presence on the Gateway (`/opt/stacks/tor/`, a v3 hidden service mirroring
    erp.dickson-supplies.com, `network_mode: host`) — worth clarifying whether "a Tor node" means
    a real relay/exit node contributing to the Tor network (different resourcing/legal
    considerations than a hidden service) or another hidden service, before scoping. "Crypto node"
    is undefined — which coin/chain, full node vs. light client, and why (personal use? Emerald
    Markets/Discreet Elite payment acceptance?) all need Mr. Byrne's input. Purely an idea on the
    list right now, not scoped or approved to start.

26. **Move erp.dickson-supplies.com from Hostinger to the Hostkey account** — confirmed by Mr.
    Byrne 2026-07-27: **hot-erp (46.202.129.86, currently serving erp.dickson-supplies.com) is
    hosted on Hostinger**, not Hostkey — CLAUDE.md just didn't name the provider explicitly ("a
    public VPS, not a Proxmox VM"). Worth updating CLAUDE.md's hot-erp entry with this once this
    task is picked up. Goal: move ERPNext onto a Hostkey-provisioned server instead, matching the
    provider now used for hot-pn (Hostkey CH) and hot-bm-nl (Hostkey NL). Likely follows the same
    playbook already used for those moves: order a Hostkey VPS via invapi.hostkey.com, stand up
    ERPNext (fresh or restored from the existing vzdump/backup chain — see the erp-temp restore
    procedure in `/opt/hot-config/erp-temp/dickson/README.md` for precedent), dedicated WireGuard
    tunnel from the Gateway, Caddy repoint, retire/cancel the Hostinger box once verified.

    **Scoping answers from Mr. Byrne, 2026-07-27:**
    - **Size**: match hot-erp's current spec or smaller is fine, as long as it copes with
      erp.dickson-supplies.com's real traffic — don't over-provision.
    - **Location**: **Hostkey CH** (Zürich), matching hot-pn.
    - **Fresh install vs. restore**: deliberately left open — "depends on the progress and state of
      the infrastructure," meaning assess the fleet's state (this LUKS retrofit, the wider rebuild)
      at the time this is actually picked up before deciding; not a fixed answer now.
    - **Downtime**: needs to be minimized — plan the cutover (DNS/Caddy repoint + WireGuard swap)
      for as little erp.dickson-supplies.com disruption as possible, not just "acceptable."
    - **Hostinger account**: will be closed/cancelled after the move is verified working.

    Still not started — this is scoping only, not a go-ahead to begin the migration itself.

27. **PrivateNexus: rethink the "brain" of PN — a more JARVIS-like feel** — Mr. Byrne wants to
    explore giving PN a more conversational/AI-copilot character (in the spirit of this assistant
    itself), but explicitly hasn't decided the approach or scope yet ("how and what road that
    takes I'm not sure yet"). Purely a future direction to keep in mind, not a scoped task — don't
    propose a specific implementation (e.g. an embedded chat assistant, the existing MCP
    server/intelligence engine surfaced differently, etc.) until he's ready to talk through
    direction.

## Real decisions parked — need Mr. Byrne specifically, don't decide unilaterally
6. **sn-personal / pn-test (VLANs 40/60) fate** — see item 21 above, which narrows this: personal
   services are headed to hot-pn specifically, not a repurposed sn-personal. What happens to the
   sn-personal/pn-test VLANs themselves (retire outright vs. something else) is still open.
7. **hot-erp** may move to a dedicated Hostkey server instead of the current spare VPS "at some
   point" — not scheduled, purely his call on timing.
8. **hot-erp hosting client companies' backend software** — a stated future goal, "not started, no
   timeline." Don't start building multi-tenant hosting unprompted.

## Low-priority, deliberately deferred — don't raise unprompted
9. **ClamAV sidecar decoupling** on Docker Mailserver (`gateway/mailserver`) — scoped (real plan:
   `clamav/clamav` sidecar + point docker-mailserver's milter at it) but not started. Only worth
   picking up if the current stale-signature situation actually causes a problem.
10. **Roundcube passwordless SSO** (real OAUTH2/XOAUTH2 against Keycloak + Roundcube's own oauth2
    plugin) — current pre-auth wall (oauth2-proxy gate in front of Roundcube's own login) works
    fine; bigger scope, evaluate only if that proves insufficient.
11. **Stalwart mail server** — on hold until it ships a real web client or HoT builds one in-house.
    Don't suggest migrating from Docker Mailserver + Roundcube until that changes.

## Phase 4 roadmap — long-term, nothing started
12. CrowdSec custom scenarios
13. HoT Command (Flutter mobile ops dashboard)
14. Second bare metal node (HA)
15. Edge load balancing (second VPS)
16. Terraform / Ansible IaC

## PrivateNexus (PN) roadmap — pulled from `PrivateNexus_Release_Roadmap_v1.0.md` (v1.7, current
as of 2026-07-27). Full doc has extensive shipped-feature history; this is just what's still open.

**v5.0 (Autonomous Operations) — gate closes 2026-08-20, currently open:**
- Predictive degradation alert firing before a real failure — structurally possible now
  (`latency_trending` signal added 2026-07-21) but hasn't organically closed yet, needs a real
  predicted-then-confirmed failure pair
- 30 consecutive days of autonomous low-risk execution with zero errors — clock restarted
  2026-07-21 after the first claimed run turned out to be unsubstantiated on audit; new target
  2026-08-20
- No incident of autonomous execution causing unintended state change — ongoing, self-closing if
  the above holds

**v6.0 (Open Platform) — most gate items already shipped and verified; genuinely still open:**
- Sandbox restore test for ERPNext (PN's own restore test is done; ERPNext's isn't — and note
  ERPNext now runs permanently on hot-erp, not sn-business, so this needs re-scoping regardless)
- GitHub repo with real MIT-licensed Community Edition source — deliberately blocked until the
  Pro-gated code (multi-tenancy, discovery agents, sandbox restore, governance reports, action
  policy engine) is split into its own module first; `LICENSE` file is empty on purpose until then
- Docker Hub image + clean from-scratch install in under 30 minutes
- Upgrade guide tested across a real version bump
- All five commercial proof points from the Packaging & Licensing doc confirmed
- First Professional beta customer onboarded (even at £0)
- No critical security issues open at release tag
- **Security lockdown mode — appears entirely unbuilt** (every checkbox for this deliverable is
  unchecked): tiered Alert/Soft/Hard/Full response, `POST /api/lockdown` endpoint, Wazuh
  active-response integration, CrowdSec range-ban webhook integration, breakglass-gated Full tier,
  dashboard lockdown indicator, lockdown audit trail. **Worth flagging: the Wazuh integration leg
  of this is now actually buildable** — Wazuh SIEM went live on sn-security this same session (see
  [[sn_security_rebuild]]), so this is no longer blocked on infrastructure that doesn't exist.

**v7.0 — candidates only, nothing committed:** HoT Command mobile app, in-product notifications
(PN currently has zero notification path to a logged-in operator — all alerting is external to the
app), Managed Edition pilot, billing/licence self-service portal, multi-site federation, formal
compliance modules (ISO 27001/CIS).

**How to apply:** re-run this same sweep periodically (grep all memory + CLAUDE.md for the same
indicator phrases) rather than trusting this snapshot indefinitely — several items on past
sweeps like this turn out to already be resolved by the time anyone rechecks (see the Grafana SMTP
example above). Verify live before reporting anything from this list as still-open in a future
session.
