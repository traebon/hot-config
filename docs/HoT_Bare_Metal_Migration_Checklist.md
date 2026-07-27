# Bare-Metal Migration — Record & Residual Checklist

Status: **Migration substantially complete as of 2026-07-27.** This document originally described a
literal hardware-replacement plan (new physical box, ZFS disk transplant or restore-from-backup).
That plan was superseded — see [[hostkey_server_replacement]] for the full blow-by-blow. This
rewrite replaces the old speculative phases with what actually happened, plus the real remaining
open items. Don't follow the old Phase 1–3 steps below this line — they're gone; this is the
current, accurate record.

---

## What actually happened (summary)

1. Original bare-metal host (AMD EPYC 3151, server 145990, Switzerland DC) suffered an unfixable
   Intel I350 NIC PCIe fault. Hostkey could not repair or swap it. After a ticket saga (CS-471548)
   that dragged over two weeks, the decision was to take a pro-rata refund ($112.94 total credited,
   payout to PayPal requested 2026-07-20/21) rather than accept a downgraded 16GB replacement — see
   [[hostkey_server_replacement]] for the full ticket history if the refund ever needs chasing again.
2. Replacement sourced and ordered 2026-07-21: **Hostkey `vds.v1-storage-8`** — an oVirt-based VPS
   (NOT physical bare metal), Netherlands datacenter (not Switzerland — accepted trade-off, see
   below), 4 vCPU / 32GB RAM / 2×4TB HDD. Server ID 22272, hostname `hot-bm-nl`,
   `proxmox22272.hostkey.in` (PVE's node identity is baked in at install and can't be renamed — a
   rename attempt on 2026-07-22 broke Proxmox's own hostname resolution and was reverted; don't
   retry it).
3. **Swiss-residency reasoning preserved despite the NL location**: PrivateNexus and Discreet
   Elite's "hosted in Switzerland" positioning doesn't touch this box — PrivateNexus's permanent
   home is **hot-pn** (Hostkey CH, 151.241.217.140) and the Gateway VPS itself is Zürich. hot-bm-nl
   only ever needed to host the generic infra VLANs (sn-infra/sn-web/sn-monitor/sn-security), none
   of which carry that requirement.
4. Went through two reinstalls before landing (an accidental OS wipe from a misused Hostkey API
   probe on 2026-07-22, then a deliberate reinstall once nested virtualization was confirmed
   working) — final state: **Proxmox VE 9.2.5 on Debian 13**, delivered as Hostkey's pre-built PVE
   application image, not a manual Debian install.
5. Architecture decided: **nested Proxmox inside the VPS**, not a flat Docker/LXC consolidation —
   recreate the original VLAN-segmented fleet almost 1:1. Confirmed nested virt actually works
   (`vmx`/`kvm_intel nested=Y`, `/dev/kvm` present) after an earlier false start where Hostkey
   claimed a fix had landed but it hadn't (required a ticket reopen + full power cycle).
6. **VLAN routing rebuilt via `vmbr0` (VLAN-aware Linux bridge)** — no physical trunk involved,
   since these VLANs never touch the WAN; the `wg4` tunnel (Gateway `10.10.3.1` ↔ hot-bm-nl
   `10.10.3.2`, port 51824) carries all Gateway↔VLAN traffic instead. Storage: `sda` (LVM,
   `vg22272`) for root/local-lvm; `sdb` set up as a standalone `local-zfs` pool (not mirrored with
   `sda` — this is a VPS with underlying redundancy already handled by Hostkey's storage layer, not
   a scenario needing host-level ZFS mirroring the way the original 2×8TB physical disks did).
7. **4 of the original 7 VMs rebuilt on hot-bm-nl, 2026-07-27**: sn-infra (100), sn-web (102),
   sn-monitor (104), sn-security (106) — full service stacks redeployed fresh (data was not
   recoverable/transplantable from the dead original host; nightly backups existed but a
   restore-from-vzdump path was not pursued once the "rebuild fresh" decision was made — see the
   per-VM memories below for what was and wasn't recoverable service-by-service).
8. **VLANs 20 (sn-business) and 40 (sn-personal) are permanently NOT being rebuilt here** — those
   roles moved to dedicated external VPSs instead (**hot-erp** for ERPNext, **hot-pn** for
   PrivateNexus), a decision made permanent 2026-07-24 specifically so a future bare-metal/Proxmox
   outage can't take either down again, same reasoning as Vaultwarden's deliberate placement on the
   Gateway VPS itself. See CLAUDE.md's Network Topology section and the hot-erp/hot-pn entries for
   current state — this is closed, not a pending migration step.
9. **Tailscale admin access + a real HTTPS cert** added for the Proxmox web UI on hot-bm-nl
   (100.90.156.88, port 8006 only, UFW-scoped to the `tailscale0` interface) — admin-only, per the
   standing "Tailscale = admin access, never production traffic" rule.

Per-VM rebuild detail (network bugs found/fixed, service deployment specifics, credentials,
verification steps) lives in dedicated memories, not duplicated here: [[sn_infra_rebuild]],
[[sn_web_rebuild]], [[sn_monitor_rebuild]], [[sn_security_rebuild]].

---

## Residual open items (as of 2026-07-27)

- [ ] **LUKS2 + Tang disk encryption retrofit.** All 4 rebuilt VMs are currently **unencrypted**
  cloud-init installs — the original fleet had per-VM LUKS2+Tang (see CLAUDE.md's "NBDE unlock
  chain" row); that's not yet been re-added. Tang server prerequisite is done and verified on
  sn-infra. A pilot attempt to build sn-web with encryption from scratch (QEMU direct
  `-kernel`/`-initrd` preseed boot) hit genuinely unresolved, reproducible flakiness — see
  [[open_items_2026_07_27]] item 1 for the detailed failure account. VM 102 is currently stopped,
  not destroyed, pending a fresh investigation approach next session.
- [ ] **VLAN 60 (pn-test) fate undecided.** Unlike VLANs 20/40 (permanently moved off bare metal),
  pn-test's future hasn't been decided — rebuild it here, retire it, or something else. Needs Mr.
  Byrne's input, don't decide unilaterally.
- [ ] **CS-506940** — a separate, smaller Hostkey refund/credit thread from this same saga; last
  checked it had only a generic "forwarded to billing" ack. See [[hostkey_server_replacement]] for
  the full ticket ID trail if it needs chasing.
- [ ] **Per-VM node-exporter/Promtail/Prometheus/Uptime Kuma/Watchtower wiring** for the 4 rebuilt
  VMs — confirm each item in CLAUDE.md's "New VM Clone Checklist" was actually completed during the
  rebuild, not just assumed; the per-VM rebuild memories linked above should already confirm this
  but it's worth a final cross-check sweep once the LUKS retrofit question is settled, since that's
  the one piece of the original fleet's operational parity still open.

## Superseded — kept for historical reference only, do not follow

The original document assumed: a literal replacement physical server, a possible ZFS-mirror disk
transplant from the dead host, or a worst-case full 7-VM restore-from-vzdump onto new hardware, with
Gateway-side `wg0.conf` endpoint repointing. None of that happened — the actual path was a VPS with
nested Proxmox, fresh rebuilds (not restores) for 4 VMs, 2 VLANs retired from this host entirely, and
a brand-new `wg4` tunnel rather than repointing the old `wg0` (which stays permanently disabled — its
stale VLAN routes once conflicted with `wg4` during the vmbr0 build and had to be torn down, see
[[hostkey_server_replacement]]). If a similar full-fleet DR scenario ever recurs, treat this document
as a narrative precedent, not a runbook — write a fresh plan against whatever the actual failure and
replacement option looks like at the time.
