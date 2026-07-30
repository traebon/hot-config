---
name: hot-erp-hostkey-ch-migration-scope
description: "Full scope (not yet approved to execute) for moving hot-erp/ERPNext from Hostinger to a Hostkey CH server, matching hot-pn/hot-bm-nl's provider"
metadata: 
  node_type: memory
  type: project
  originSessionId: f361f2af-99b4-4220-ba53-a42472c872f0
  modified: 2026-07-30T09:14:45.399Z
---

Full scope produced 2026-07-30 for item 26 in [[open_items_2026_07_27]] — moving `erp.dickson-supplies.com` (hot-erp, 46.202.129.86, currently on **Hostinger**, not Hostkey) onto a Hostkey CH server, matching the provider now used for hot-pn (Hostkey CH) and hot-bm-nl (Hostkey NL). **Mr. Byrne said to hold here for now — this is scoping only, no server has been ordered, nothing on the infrastructure has been touched.**

**Mr. Byrne's standing answers (2026-07-27, see [[open_items_2026_07_27]] item 26):** size = match current or smaller, don't over-provision; location = Hostkey CH (Zürich); fresh-vs-restore = deliberately left open, assess at pickup time; downtime = minimize; Hostinger account = cancel after the move is verified working.

**Current hot-erp real state (measured live 2026-07-30, not estimated):** 2 vCPU / 7.7GB RAM / 96GB disk on Hostinger, Ubuntu 26.04. All 9 containers under 1% CPU, ~900MB combined container RSS. Real ERPNext dataset (MariaDB + assets + sites + redis volumes) totals **~920MB** — 12GB of the 96GB disk used is mostly reclaimable Docker build cache (~4.3GB) plus images, not real data.

**Recommended Hostkey preset: `vm.v2-nano`** (2 vCPU / 4GB RAM / 60GB disk, $7.64/mo) — pulled live from `presets.php?action=list`. Matches current vCPU exactly, still ~4x real-usage headroom on RAM. Alternative: `vm.v2-mini` (4 vCPU/8GB/120GB, $9.11/mo) for more margin, but that doubles vCPU vs. current so is arguably not "smaller."
**Why not vm.v2-medium** (the preset actually used for hot-pn's CH order): 8 vCPU/16GB is real over-provisioning for hot-erp's tiny footprint — hot-pn is a much heavier PrivateNexus dev+test combo, not a comparable sizing precedent here.

**⚠ Real gotcha found, not yet resolved — `locations` field on `presets.php` is not a trustworthy CH-availability signal.** None of the `vm.v2-*` presets (including `vm.v2-medium`, which [[hostkey_invapi_notes]] confirms was actually successfully ordered in CH for hot-pn) list `CH` in their `locations` string. So don't treat a missing CH in that field as "unavailable" — it needs to be confirmed live via a real `order_instance` call at pickup time. Per [[hostkey_invapi_notes]], `order_instance` only creates an **unpaid WHMCS invoice** (no real charge, no active server) until manually paid — safe to test-order `vm.v2-nano` in CH to confirm availability/pricing without financial commitment, but still a real account action (creates a real invoice), not something to do casually — check with Mr. Byrne before placing even this reversible order.
**How to apply:** when this migration is picked up for real, the very first live step should be a test `order_instance` call for `vm.v2-nano`/CH to settle this, before assuming the preset works there.

**OS choice:** Hostkey has Ubuntu 26.04 available (`os_id 324`) — exact match to hot-erp's current OS. `os_id 237` (Ubuntu 24.04) is the already-proven path (used for hot-pn's real, successful provisioning) if preferring the validated route over an exact-version match.

**WireGuard tunnel:** `wg5` is the next free slot (wg1–4 all in use, confirmed via `wg show`/`/etc/wireguard/` listing 2026-07-30) — `10.10.4.1` (Gateway) ↔ `10.10.4.2` (new box), port `51825`, following the established `wg<N>` / `10.10.<N-1>.0/24` / port `5182<N>` pattern (wg2=erp-temp/10.10.1.0/24/51822, wg3=pn-vps/10.10.2.0/24/51823, wg4=hot-bm-nl/10.10.3.0/24/51824).

**Fresh vs. restore — recommendation for the open call:** given the real dataset is tiny (~920MB) and hot-erp has no LUKS/Tang/vzdump layer at all (it's a plain Docker-on-VPS box, not a Proxmox VM), this isn't really a fresh-vs-restore binary the way the bare-metal rebuilds were. Recommended path: **fresh ERPNext install on the new box + direct `mariadb-dump`/restore + volume rsync** of the real data while hot-erp stays live — much simpler than the original bare-metal vzdump/Tang recovery playbook (see `/opt/hot-config/erp-temp/dickson/README.md` for that older, heavier precedent, which doesn't cleanly apply here).

**Cutover plan (minimize downtime, per Mr. Byrne's instruction):** order CH box → stand up ERPNext fresh → bring `wg5` tunnel up → final `mariadb-dump` + volume rsync from hot-erp while still live → import on new box → verify (frappe.ping, real UI check through a browser, Tor mirror still resolves) → flip Caddy's `erp.dickson-supplies.com` block from `10.10.1.2:8000` to the new tunnel IP → confirm live → cancel Hostinger account.

**Separate gap noticed while scoping, not yet decided:** hot-erp currently has **no automated backup at all** — unlike hot-pn's DB, which got a real `pg_dump` chain wired up 2026-07-16 (see the hot-pn CLAUDE.md section). Worth deciding whether to add one on the new CH box as part of this move, independent of whether the migration itself proceeds.

**Status as of 2026-07-30: scoping complete, execution on hold per Mr. Byrne — do not order a server or begin migration steps without a fresh, explicit go-ahead.**
