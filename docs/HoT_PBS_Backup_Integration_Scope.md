# HoT — Proxmox Backup Server (PBS) Integration

Scoping doc. Written 2026-08-22 after Mr. Byrne stood up a new PBS host and asked to connect it to
the fleet, then confirmed (via a direct exchange) that the intent is broader than just SSH access:
PBS should become a real backup consolidation point covering "all key info across the entire
fleet," and the box itself is **local hardware on Mr. Byrne's own network**, not a rented VPS like
the rest of the fleet.

Not a commitment to build — a scope to react to and prioritize against, per the pattern used for
`HoT_Edge_Load_Balancing_Scope.md` and `HoT_Automation_Self_Healing_Scope.md`. Nothing described
here has been built yet; the only change made so far is an SSH alias (`pbs`, `/root/.ssh/config`)
so this Gateway can reach the box for investigation.

---

## 1. Current state (verified live, 2026-08-22 — not assumed)

**Host itself:**
- Hostname `pbs`, Proxmox Backup Server 4.2.5, 4 vCPU / 7.6 GB RAM
- Two disks: `sda` (5.5 TB, LVM — OS root `pbs-root` 5.4 TB + swap, only 6.1 GB actually used) and
  `sdb` (3.6 TB, ext4, mounted `/mnt/backups`) — **one PBS datastore configured, `houseoftrae-backups`,
  on `sdb` only.** `sda`'s ~5.4 TB is sitting almost entirely unused as OS root headroom — worth
  asking whether that was intentional (e.g. plan to add a second datastore there) or whether `sdb`
  was meant to be the only backup disk and `sda` is oversized for what it's doing.
- **No RAID/redundancy on either disk** — `sdb` (the actual datastore) is a single physical disk.
  A single disk failure would take out the backup datastore itself. Worth flagging explicitly since
  this would be holding the fleet's actual backup data, not just OS state.
- **Real network misconfig found, tangential to backup scope but worth fixing regardless:**
  `/etc/network/interfaces` has `nic1` statically addressed `192.168.0.35/24` with `gateway
  192.168.1.1` — the gateway is not inside the declared `/24`. It currently works only because the
  kernel installs the default route with the `onlink` flag (confirmed via `ip route`), which
  bypasses the normal on-subnet check. Fragile, not itself blocking anything today.
- Only one user (`root@pam`), no `remote` entries configured yet — this is a genuinely fresh
  install, no existing backup jobs or fleet integration of any kind.

**Reachability (all confirmed live via real ping, not assumed from Tailscale's admin list):**

| Target        | Reachable from PBS? | Path                                  |
|----------------|---------------------|----------------------------------------|
| Gateway        | Yes                 | Tailscale, ~40ms                       |
| hot-bm-nl      | Yes                 | Tailscale, 34–520ms (first-packet spike, then stable ~34ms — looks like a Tailscale direct-path negotiation, not a sustained problem) |
| hot-pn         | Yes                 | Tailscale, 42–178ms (same first-packet pattern) |
| hot-erp-nl     | Yes                 | Tailscale, 34–74ms                     |
| sn-infra/web/monitor/security | Not tested directly | Only reachable via hot-bm-nl's VLAN routing today — PBS has no path to the 10.10.x.x VLAN mesh at all, Tailscale or otherwise |

PBS is **not** on any WireGuard tunnel — Tailscale is currently its only path off the local LAN
besides plain internet egress. This matters directly for the transport decision in Section 3.

**Existing backup architecture (unchanged, for context — see `alerting-backups.md`):**

| Tier | Destination | Notes |
|------|-------------|-------|
| hot-bm-nl vzdump (4 VMs, ~415GB/night full-image) | Local ZFS (`/var/lib/vz/dump`), then rclone-crypt push to Hetzner Storage Box | 14-day retention offsite; this is the tier PBS is best suited to replace — PBS's whole design point is content-addressable dedup/incremental-forever, which vzdump's full-image model doesn't do |
| Keycloak DB, Gateway config (Tor/PowerDNS/Mailserver) | Primary: hot-bm-nl; fallback: Hetzner+B2 | Small, daily |
| hot-pn PrivateNexus DB | hot-pn → Gateway pull → Hetzner+B2 (unconditional nightly, the reliability canary) | Small, daily |
| Config repo (`hot-config`) | Forgejo → Codeberg + GitHub mirrors | git-based, unrelated to any of the above |

---

## 2. What "connect PBS to the fleet" could mean — scope options

### Option A — PBS replaces/supplements only the hot-bm-nl VM backup tier
Install `proxmox-backup-client` on hot-bm-nl, point its vzdump jobs (or a parallel PBS-native backup
job) at PBS's `houseoftrae-backups` datastore instead of (or alongside) the current ZFS dump +
Hetzner push. This is PBS's core designed use case — Proxmox-to-PBS VM/CT backup — and needs the
least new plumbing. Narrowest scope, closest to "do the thing PBS is actually built for."

### Option B — Option A, plus fleet-wide file-level backups
`proxmox-backup-client` also supports arbitrary host-level backups (not just Proxmox VMs) via
`proxmox-backup-client backup`. Under this option, hot-pn/hot-erp-nl/Gateway/sn-infra etc. would
each get the client installed and push their own directories/dumps into PBS datastores too —
effectively replacing the existing per-host rclone-crypt scripts with one consolidated mechanism.
This is what "all key info across the entire fleet" (your answer) actually implies if taken
literally — broader than Option A, touches every host's backup script, not just hot-bm-nl's.

### Option C — Option B, and PBS becomes primary (Hetzner/B2 downgraded to a secondary/DR copy only)
Same footprint as B, but a deliberate decision to make PBS the main restore path day-to-day, keeping
Hetzner/B2 around only for disaster recovery (e.g. if PBS's home hardware is unreachable or lost).
This is the option where the single-disk/no-RAID/home-network findings above matter most — PBS
becoming the *primary* copy while sitting on unredundant local hardware would be a real downgrade
in reliability versus the current all-cloud setup, unless that's addressed first (RAID, UPS, a
documented plan for what happens if the home connection or the hardware itself goes down).

**My read:** given the current single-disk datastore and residential-network posture, PBS looks
better suited today as an *additional* fast local-restore copy alongside Hetzner/B2 (Option A or B),
not as a wholesale replacement (Option C) — but this is your infrastructure and your risk tolerance
to weigh, not something I should default on.

---

## 3. Transport: Tailscale vs. a dedicated WireGuard tunnel

**The tension:** `operational-rules.md` states plainly — *"Tailscale = admin only, never route
production traffic through Tailscale (DERP relay latency)."* Every other bulk/production data path
in this project (VLAN traffic, vzdump pushes, DB pulls) runs over a dedicated WireGuard tunnel
(wg1–wg5), never Tailscale. Nightly backup traffic at hundreds of GB is squarely "production
traffic" under that rule, not admin access.

Two real options:

- **New dedicated WireGuard tunnel (matches existing pattern).** Since PBS sits behind a home
  router (not a public IP — `192.168.0.35` is a private LAN address), it can't be dialed the way
  hot-bm-nl/hot-pn/hot-erp-nl are (Gateway initiating to their public IP). It would instead need to
  dial *out* to the Gateway's public endpoint, the same pattern already used for `wg1` (Mr. Byrne's
  road-warrior VPN) — PBS as a WireGuard client connecting to a new listener on the Gateway. This
  keeps backup traffic off Tailscale entirely, consistent with the existing rule, at the cost of
  building and maintaining one more tunnel (and depending on the home router not blocking outbound
  UDP, which is normally fine).
- **Use Tailscale anyway, deliberately, as a scoped exception.** The measured pings above show a
  real *direct* Tailscale path exists between the Gateway and PBS (not relayed through DERP, per
  `tailscale status` showing `direct 151.241.217.91:41641`), so the latency concern the rule is
  actually about may not apply here the way it would for a relayed connection. This would need to be
  written up explicitly as a deliberate, documented exception (like the Vaultwarden Gateway
  placement or sn-security's cores=2 cap) — not silently done — and re-verified that the direct path
  holds under sustained bulk transfer, not just ICMP.

I'd lean toward the WireGuard tunnel for consistency with how every other bulk path in this project
works, but the direct-Tailscale-path finding is real enough that it's worth you weighing in rather
than me picking silently.

---

## 4. Open questions — need your call before anything gets built

1. **Scope** — Option A (hot-bm-nl VMs only), B (fleet-wide file-level too), or C (PBS becomes
   primary, Hetzner/B2 downgraded)?
2. **Transport** — new dedicated WireGuard tunnel, or a documented Tailscale exception for backup
   traffic specifically?
3. **Redundancy** — is the single-disk datastore acceptable as-is (e.g. because Hetzner/B2 remains
   the real disaster-recovery copy regardless of scope), or does this need RAID/a second disk before
   any real fleet data lands on it?
4. **The unused `sda` capacity and the `192.168.0.35/24` + `192.168.1.1` gateway mismatch** — both
   look like leftovers from provisioning. Want me to just fix the network config while I'm in there
   (low-risk, one-line change), and clarify what the extra ~5.4TB on `sda` was meant for?

---

## 5. Suggested next step

Once 1–3 above are answered, the natural first slice (regardless of which option is chosen) is
Option A end-to-end for a single VM as a pilot — wire the transport, add PBS as a Proxmox storage
target on hot-bm-nl, run one real backup + one real restore test for e.g. `sn-monitor` (smallest,
lowest-risk VM), and confirm actual dedup/storage-per-backup numbers before committing the rest of
the fleet to it. That also answers the "will 3.6TB actually hold what we need" question with real
data instead of a guess.

---

## 6. What actually happened since, and a real incident found investigating it (2026-09-04)

**Section 4's open questions were never formally answered in writing, but something closer to
Option A got built anyway, quietly, sometime between 22 Aug and 25 Aug** — this section exists
because re-checking this item live for a routine "scope the next parked job" pass turned up a
production incident, not just stale documentation. Found and fixed the same day; full trace in
`pbs_backup_crisis_and_wg6_outage_2026_09_04` memory.

**What's real, confirmed live:**
- The dedicated WireGuard tunnel (`wg6`, Section 3's first option) was built — Gateway
  `10.10.5.1` ↔ PBS `10.10.5.2`, port 51826, PBS dialing out road-warrior style. See
  `network.md`'s wg6 entry.
- `/etc/pve/storage.cfg` on hot-bm-nl has a real `pbs-hot` storage target (datastore
  `houseoftrae-backups`, `prune-backups keep-daily=3,keep-weekly=1`) — Option A's core mechanism.
- On **2026-08-25**, the `daily-fleet-backup` vzdump job was split in two: VM 100 (sn-infra) stayed
  on `local-zfs`; VM 102/104/106 (sn-web/sn-monitor/sn-security) were repointed to `pbs-hot`
  **with no fallback**. The job's own comment records why: *"local-zfs was out of space for 10 days
  straight"* — i.e. this was the reactive fix for the original capacity crisis this doc's Section 1
  never anticipated, done without ever updating this scope doc or Section 4's open questions.

**What was silently broken, found 2026-09-04:**
- `wg6`'s last successful handshake was **9 days, 14 hours** before it was checked — PBS had gone
  completely dark, 100% packet loss from the Gateway. `pvesm status` on hot-bm-nl confirmed
  `pbs-hot: inactive — Connection timed out`. The Gateway's own wg6 interface and service were
  healthy throughout (up since 22 Aug, zero errors) — this is entirely PBS-side (the home hardware
  itself, or its home network), not fixable remotely.
- **Net effect: sn-web, sn-monitor, and sn-security had zero real backups anywhere for 9+ days.**
  Every scheduled `daily-fleet-backup-pbs` run failed outright at storage activation before even
  starting a backup (`could not activate storage 'pbs-hot': ... Connection timed out`) — not a
  degraded backup, no backup attempt at all.
- **Nobody was told, because the one alerting path for this was also broken.** The job is
  configured `mailnotification failure` → `tristian@securenexus.net` via `legacy-sendmail`, but
  hot-bm-nl's local Postfix had no relay configured — it attempted direct-to-MX delivery,
  unauthenticated (no SPF/DKIM, no PTR/rDNS for its IP), and the house's own mail server correctly
  rejected every single attempt as spam (rspamd score 13–20 against an 11-point reject threshold,
  `554 5.7.1 Spam message rejected`) — confirmed via rspamd's own history, not guessed. This had
  been failing on *every* job run since 25 Aug, so this wasn't specific to the PBS outage — any
  Proxmox notification email from this host would have been silently dropped the same way.
- **A separate, smaller bug**: VM 100's own nightly prune step (still correctly targeting
  `local-zfs`) has been intermittently failing with `unable to activate storage 'local-backup-zfs'
  — directory ... does not exist or is unreachable`, right after a successful backup completes —
  the mount is confirmed genuinely healthy when checked directly, so this looks like a storage-
  activation timeout racing right after the backup's own heavy I/O, not a real misconfiguration.
  Left as a known follow-up, not chased further — lower urgency now that the pool has real headroom
  again (below), and it may simply need less I/O contention to stop happening.

**Fixed same day, Mr. Byrne confirmed each step:**
1. hot-bm-nl's Postfix reconfigured to relay through the house's own authenticated Universal SMTP
   (`mail.house-of-trae.com:587`, SASL, same `notifications@house-of-trae.com` credential used
   fleet-wide) instead of unauthenticated direct-send. Verified with a real test email, confirmed
   delivered to the mailbox via Dovecot LMTP (`... status=sent ... "Saved"`), not just accepted.
   **This fixes the alerting gap for any future Proxmox notification from this host, independent of
   the PBS issue itself.**
2. `daily-fleet-backup-pbs`'s storage interim-reverted to `local-backup-zfs` (same target VM 100
   already uses) via `pvesh set /cluster/backup/daily-fleet-backup-pbs --storage local-backup-zfs`,
   with the job comment updated to record why and that it should revert to `pbs-hot` once PBS/wg6
   is confirmed healthy again. Restores real backup coverage for all 3 VMs starting the next
   scheduled run.
3. **Real capacity risk in that interim fix, caught before it bit**: 2.44TB of stale VM 102/104/106
   backups (all dated before 15 Aug, i.e. before the PBS switch, never pruned since) were still
   sitting on `local-zfs`, and with only 642GB free at the time plus VM 100's own prune bug above,
   the pool would likely have filled again within a day or two — recreating the exact original
   crisis. Deleted the 16 stale files older than each VM's most-recent (15 Aug) copy, keeping one
   real fallback per VM rather than wiping everything. Freed **642GB → 2.38TB free** (pool
   82% → 33% full). Every deletion and the interim storage repoint were confirmed with Mr. Byrne
   before being applied, not done unilaterally, given the precedent in
   `hot_bm_nl_backup_crisis_2026_08_18` of deliberately not deleting backups without being certain.

**Real open questions now, sharper than Section 4's original framing:**
1. **Is PBS itself actually reachable right now?** This needs Mr. Byrne to check the box directly
   (power, home network, whether its own WireGuard client/service is still running) — nothing on
   the Gateway or hot-bm-nl side can diagnose or fix this.
2. **Once PBS is confirmed healthy again, does the fleet actually want to revert VM 102/104/106
   back to `pbs-hot`?** The original Option A/B/C decision in Section 4 was never formally made —
   what got built was a partial, unmonitored version of Option A. Worth deciding for real now,
   informed by what just happened: a single-disk, no-RAID, home-network backup target went
   completely dark for over a week with zero visibility, and the interim local-zfs fallback (which
   worked fine once space was reclaimed) may honestly be simpler and more reliable for these 3 VMs
   than PBS turned out to be in practice.
3. **Whatever the fleet lands on, it needs monitoring it doesn't have today.** Neither `wg6`'s
   handshake staleness nor `pbs-hot`'s storage-activation state are watched by `fleet-health-sweep`,
   Gatus, or anything else — this is exactly the kind of silent, week-plus-long gap that automation
   layer exists to catch, and it didn't, because nothing was ever pointed at this specific failure
   mode. If PBS stays in the picture at all, this needs a real check (e.g. `wg show wg6` handshake
   age, or `pvesm status` for `pbs-hot`) added to the nightly sweep.

## 7. PBS reachable again, 2026-09-06 — answers Section 6 question 1, question 2 still open

Mr. Byrne reported PBS's local address changed to `192.168.86.250` — a different `/24` from the
`192.168.0.35` documented in Section 1 (and its `192.168.1.1` gateway mismatch, fixed 2026-08-22),
with a new gateway (`192.168.86.1`) that's actually inside the declared subnet this time. This
reads as the home router itself being replaced or reset, not a routine DHCP lease change, and lines
up with the ~9-day-14-hour dead window Section 6 found (last real handshake ~25 Aug) — plausibly
the router swap is the actual root cause of the outage, though that's inference, not confirmed by
Mr. Byrne directly.

**Confirmed live, both ends, same day:**
- SSH to `pbs` (Tailscale alias) shows `wg6` with a handshake ~2 minutes old, `nic1` now
  `192.168.86.250/24`, default route `via 192.168.86.1 dev nic1 proto kernel onlink` — a clean
  onlink route this time, gateway genuinely inside the subnet.
- Gateway's own `wg6` shows a current handshake too, peer endpoint now `148.252.145.134:<port>` —
  a new WAN IP as well, consistent with a full router replacement.
- `pvesm status` on hot-bm-nl shows `pbs-hot` `active` with 3.6TB free.

**Section 6 question 1 ("is PBS actually reachable right now") is answered: yes.**

**A fourth, previously-undiscovered problem was found checking Question 2, and it changes the
answer.** `vzdump-offsite-push.sh` (hot-bm-nl, pushes the previous night's vzdump output to
Hetzner via rclone crypt) only reads flat `.vma.zst` files from `local-zfs`'s dump directory
(`DUMP_DIR="/local-zfs/vzdump-local/dump"`). When a VM's vzdump job targets `pbs-hot` instead,
Proxmox streams directly into PBS's own chunked dedup datastore — no flat file is ever produced,
so this script finds nothing to push. **Confirmed live against the real Hetzner listing**
(`rclone lsl hetzner-crypt:proxmox-vm-backups/`): VM 100 (always on `local-zfs`) has an unbroken
nightly entry throughout; VM 102/104/106 have **zero entries from 2026-08-24 through 2026-09-04**
— the entire period they were on `pbs-hot` — and entries resume the day after the 09-04 revert to
`local-zfs`. This means the true gap wasn't just the 9-day `wg6` outage — it's the full ~10 days
these 3 VMs were on `pbs-hot` at all, they had **no encrypted offsite copy anywhere**, including the
first ~1-4 days before `wg6` even died, while PBS itself was still healthy.

**Mr. Byrne's decision, 2026-09-06: stay on `local-backup-zfs` for VM 102/104/106 (don't revert to
`pbs-hot` yet) until this offsite-bridge gap is actually closed** — not just monitored. Nothing
today bridges PBS-format backups to an encrypted offsite copy; reverting now would silently
reintroduce the exact gap this section just found, just without the 9-day tunnel outage on top of
it. This needs real design work before building: most likely extending the offsite-push mechanism
to export PBS snapshots (e.g. via `proxmox-backup-client restore ... | rclone rcat`) rather than
relying on a flat vzdump file, or an equivalent — not yet scoped in detail, no code written.

**Question 3 (monitoring) — built 2026-09-06.** `fleet-health-sweep.sh` now carries two new
streak-based checks (`hot-config/gateway/fleet-health-sweep/`, verified via a real
`systemctl start fleet-health-sweep.service` run — caught and fixed an awk field-index bug in the
`pbs-hot-storage` check before trusting it, `pvesm status`'s Status column is `$3` not `$2`):
`wg6-handshake` (fails if the Gateway's last handshake with PBS is >1h old) and `pbs-hot-storage`
(fails if `pvesm status` on hot-bm-nl doesn't report `pbs-hot` as `active`). Both escalate to
`priority=urgent`/SMS after 3 consecutive failing nights, same as every other point check in the
sweep — a future outage like this one gets caught within a day, not 9.

**Real open items now:**
1. Design + build the PBS-to-offsite-encrypted-copy bridge — blocking any revert to `pbs-hot` for
   VM 102/104/106.
2. Once that's built and verified, revisit whether to revert those 3 VMs to `pbs-hot` at all, given
   Section 6's separate point that a single-disk, no-RAID, home-network target going dark for 9+
   days with zero visibility is a real factor, independent of the offsite-copy question.

## 8. PBS-to-offsite bridge — design scope (2026-09-06)

Real facts checked live on `pbs` before writing this, not assumed:

- **PBS 4.2.5** (`proxmox-backup-manager version`). This matters directly — 4.x has real, native
  **S3 object-storage backend support**: `proxmox-backup-manager s3 endpoint create` (access/secret
  key, endpoint, region, rate limits) and `datastore create --backend <s3-config>` both exist and
  are documented CLI commands, not a guess from release notes. A second local datastore can be
  backed by an S3 bucket instead of local disk.
- **Datastore layout**: `houseoftrae-backups` is a single ext4 filesystem (`/dev/sdb1`, 3.6TB,
  currently only 42GB used) at `/mnt/backups`. The real content lives in `/mnt/backups/.chunks`
  (content-addressed, fixed-size chunk files, dotdir — easy to miss with a naive `du -sh /*`, which
  is why the first check of this looked nearly empty) — this is genuinely deduplicated storage, not
  a metadata layer over full images; matches the Section-under-`pbs_backup_integration_scope`
  pilot's earlier finding (42GB landed for a 250GB nominal VM104 disk).
- **`sync-job` exists too** (`proxmox-backup-manager sync-job create --remote-store ... --store
  ...`) — PBS's native incremental replication mechanism, chunk-aware (only transfers what the
  target doesn't already have). It targets a `remote` (`remote create --host ...`), which in PBS's
  model is another PBS server's API — real server-to-server sync, not a generic "any storage"
  target. A **second real PBS instance is not currently a decided piece of this fleet's
  architecture** (would be new standing infrastructure, its own monitoring, its own home — the
  roadmap's separate "second bare metal node (HA)" item is the nearest existing appetite for that
  kind of thing, and it's undecided too).
- **No backup-content encryption key exists anywhere in this setup today.**
  `~/.config/proxmox-backup/` on PBS is empty (no `.key` files — PBS's own client-side backup
  encryption, a distinct feature from transport/at-rest encryption, has never been set up), and the
  existing `pbs-hot` storage entry on hot-bm-nl was registered without one either. **This means the
  PBS datastore's current contents are not encrypted under any key House of Trae controls** — a
  materially weaker guarantee than every other offsite copy in this project (Hetzner/B2 both go
  through `rclone crypt`, meaning the storage provider itself never sees plaintext). This gap exists
  independent of the offsite-bridge question and is worth flagging on its own, not just as a
  precondition for one of the options below.
- **B2's cap ($2/mo, ≈330GB, set 2026-08-08 — see `backup_architecture_b2_scope_2026_08_08`
  memory) is no longer the obstacle it was for the old flat-vzdump target.** That cap was sized
  against full, undeduped VM images (~415GB/night fleet-wide, ruled B2 out entirely). PBS's own
  dedup changes that math completely — if a bridge preserves PBS's dedup (rather than re-expanding
  to flat images), the real steady-state volume for VM 102/104/106 is plausibly in the low hundreds
  of GB, i.e. close to or within B2's current cap, not a categorical mismatch the way it was before.
  Hetzner Storage Box, by contrast, is SFTP/CIFS/Borg-style storage — **not S3-compatible**, so it
  cannot be a target for PBS's native S3 backend at all, only for a raw file-level copy (Option B
  below).

### Option A — second PBS datastore, S3-backed (on B2), synced via a native `sync-job`

Create an S3 endpoint config on PBS pointing at Backblaze B2's S3-compatible API, a second
datastore (e.g. `houseoftrae-backups-offsite`) backed by it, and a `sync-job` replicating
`houseoftrae-backups` → the S3-backed one, on a schedule. This is the mechanism PBS's own docs
actually design for — real incremental, chunk-level, resumable sync, with PBS's own verify/GC
semantics applying to both copies.

- **Pros:** No new server. Reuses B2 (already paid for, already has working rclone-crypt
  credentials for the *unrelated* small-DB tier — though this would need its own B2 Application Key
  with S3-compatible credentials, a different credential type than the native B2 API key already in
  use). Genuinely incremental at the chunk level — matches PBS's own dedup efficiency, unlike
  re-exporting flat images. No change needed to `vzdump-offsite-push.sh` or the existing
  `local-zfs`→Hetzner pipeline at all.
- **Cons / open questions:** Doesn't match the existing rclone-crypt security bar on its own — B2
  would receive plaintext chunk data over TLS unless PBS's own client-side backup encryption is
  *also* set up (a real, separate build step: generate a master key, store it safely — losing it
  makes the backups permanently unreadable, same risk class as the Tor onion service's private key
  — and reconfigure `pbs-hot` on hot-bm-nl to encrypt going forward; existing unencrypted snapshots
  stay unencrypted unless re-backed-up). B2's cap likely needs a modest raise once real volume is
  measured (cheap, not the ~$hundreds/mo the old flat-image estimate implied). New B2 S3-compatible
  key needs generating and saving to Vaultwarden.

### Option B — raw file-level mirror of the chunk store to the existing Hetzner Storage Box

Point a plain `rclone sync` (reusing the existing `hetzner-crypt` remote and its encryption) at
`/mnt/backups/.chunks` + the datastore's `vm/` index/manifest tree, uploaded to a new path on the
same Storage Box already in use. No PBS reconfiguration at all.

- **Pros:** Reuses the exact encryption model already trusted for everything else (Hetzner never
  sees plaintext, same as today). No new credentials, no new PBS config, smallest build.
  Content-addressed chunk files mean re-running the sync only pushes genuinely new chunks —
  incremental in practice even though the mechanism is dumb.
- **Cons / real risks, not yet resolved:** This is not PBS's own supported sync path — it's a raw
  filesystem copy of an internal format PBS doesn't document as externally stable. Two concrete
  risks worth testing before trusting it: (1) whether a sync running concurrently with an active
  backup or GC job could capture a chunk mid-write (PBS's own atomicity/write semantics for chunk
  files haven't been checked here — needs verifying, e.g. does it write-then-rename or write in
  place); (2) restoring from this mirror isn't "grab a file back" — it means standing up a fresh PBS
  instance (or datastore) pointed at a restored copy of the same directory tree and confirming PBS
  itself considers it intact (`proxmox-backup-manager` verify-equivalent), which has never been
  tested here and could surface format assumptions this plan doesn't currently know about.

### Option C — reconstruct flat images, reuse the existing `local-zfs`→Hetzner pipeline unchanged

Use `proxmox-backup-client restore` to rebuild a full `.img`/`.vma`-equivalent from each PBS
snapshot, then hand it to the exact same `vzdump-offsite-push.sh` mechanism already proven for VM
100 — zero new pipeline, zero new encryption story (already rclone-crypt).

- **Pros:** Lowest engineering risk — reuses a pipeline that's been running correctly for months.
  Matches the existing security bar exactly, no new key management.
- **Cons:** Throws away PBS's dedup benefit for the offsite leg specifically — back to
  full-image-sized transfers (VM 102 alone was ~268GB/night undeduped). Needs real scratch disk
  space to reconstruct each image before pushing, and the obvious place to put that scratch space
  (`local-zfs`) is the exact resource PBS was adopted to relieve pressure on in the first place
  (`hot_bm_nl_backup_crisis_2026_08_18`) — would need a dedicated scratch volume or streaming
  restore-to-pipe (untested whether `proxmox-backup-client restore` can stream to stdout rather than
  a file) to avoid recreating that problem.

### Recommendation and what's still undecided

**Option A is the best fit on paper** — it's the only one that keeps both properties this project
already insists on elsewhere (encrypted-before-it-leaves-the-network, and real incremental/dedup
efficiency) once the backup-encryption-key step is done — but it's also the option needing the most
new build work (S3 endpoint, second datastore, sync-job schedule, PBS backup-encryption key
generation and safe storage, a new B2 S3-compatible credential). **Option B is the fastest to stand
up** but carries real unresolved integrity/restorability questions that should be tested (ideally
against a disposable snapshot, not production data) before being trusted as a real DR copy. **Option
C is the safest/most-proven** but permanently gives up PBS's efficiency for the offsite leg, which
may be an acceptable trade if PBS's local dedup copy is considered "fast local recovery" and Hetzner
stays "slow full-image DR," a two-tier framing this project hasn't explicitly adopted yet.

No option has been built or started — this section is scope only, per the request. Needs Mr.
Byrne's call on: (1) which option (or hybrid — e.g., Option C now as a quick fix, Option A later as
the real answer), and (2) independent of that choice, whether to close the "no backup-content
encryption key exists at all" gap regardless, since it currently applies to every backup PBS is
holding today, not just the offsite question.

## 9. Resolution, 2026-09-06 — none of A/B/C were built; the real problem was reframed instead

Testing Option C's mechanism (proven correct — a streamed `restore` piped through zstd into
`rclone`, verified via an exact hash round-trip) surfaced the real blocker: **measured throughput
was ~1.5-2 MiB/s**, both via `map`+`dd` and via the real sequential `restore` stream — consistent
convergence, not a fluke. At that rate a full 250GB VM image takes **~47 hours**. Compared against
the pilot backup's write-direction speed (42GB in 45 minutes, ~16MB/s), this confirms PBS's home
link is asymmetric — fast download (into PBS), slow upload (out of PBS) — which rules out *any*
mechanism needing to move full-image volume off PBS regularly, Option A's initial full sync
included.

**Mr. Byrne's question that actually resolved this**: does a nightly offsite copy need to be a
byte-identical VM image at all, or just enough to rebuild? Checked live, per VM:

| VM | Genuinely irreplaceable state | Size |
|---|---|---|
| sn-web | 6 sites' content + Stratus app source | <200KB |
| sn-monitor | Grafana Postgres DB (dashboards/alerts) + Uptime Kuma SQLite | ~130MB |
| sn-security | Wazuh rules/config (indexer/security-event history not yet covered — see below) | ~3MB config, 228MB indexer (deferred) |

Against a 250GB nominal disk each — the rest is OS, Docker image layers, and empty space, all
rebuildable via the New VM Clone Checklist + `docker compose up`, not data that needs preserving
byte-for-byte. This reframes the whole problem: **PBS's job becomes fast local recovery only**
(already proven — 45 minutes for a full VM), and offsite protection comes from a separate, much
smaller "rebuild recipe" pipeline that never touches PBS's slow link at all.

**Built and verified same day, real facts checked before each step:**
- **Config coverage audit, fleet-wide** (not just these 3 VMs) — found real gaps: `hot-wiki`
  (sn-infra) was live since 25 Aug with zero tracking; Wazuh's actual config tree (sn-security) was
  only ever synced as `docker-compose.yml`, the `config/` subdirectory in `hot-config` was a stale
  one-time copy; 5 of sn-web's 6 sites' `html/` content was untracked; hot-pn's Catalogue-deployed
  stacks (`nextcloud`, `notesnook`) had **zero** config tracking anywhere. All fixed in
  `scripts/sync.sh` (extending the existing daily 01:00 git sync, not a new mechanism) and verified
  via a real run. **One real secret-leak caught by the existing guard, not by inspection**:
  `wazuh_dashboard/wazuh.yml` embeds the real wazuh-wui API password inline (no Docker-secret
  indirection exists for that file — matches the standing `operational-rules.md` note) — excluded
  before the second, clean run.
- **`fleet-state-backup.sh`** (new, `hot-config/scripts/` + a systemd timer, `03:10` daily,
  `OnCalendar` per this project's own rule) — pg_dumps Grafana's Postgres DB and takes a proper
  SQLite online backup of Uptime Kuma's DB (via `sqlite3 .backup`, not a raw copy — `kuma.db` runs
  in WAL mode under active writes), pushes both directly to `hetzner-crypt`/`b2-hot-crypt`, same
  pipeline Keycloak/PrivateNexus's DB backups already use. **Verified restorable, not just
  pushed**: Grafana's dump has 91 valid `CREATE TABLE` statements; Uptime Kuma's copy passes
  `PRAGMA integrity_check` with all 26 monitors intact. **A real bug caught before trusting it**:
  the first version's `push()` checked the logging `while` loop's exit code instead of `rclone`'s
  own (via `PIPESTATUS`) — would have silently reported success on a real failure. Fixed, redeployed,
  and re-verified via the actual `systemctl start` path before being left running.

**Still open, deliberately not done in this pass**: Wazuh's indexer data (~228MB of real
security-event history) needs a proper OpenSearch snapshot/export, not a raw live-volume copy —
more involved than the Postgres/SQLite cases above, scoped as a follow-up. Practical effect: the
"rebuild recipe" for sn-security today covers its config (rules/decoders/manager.conf, via the
sync.sh fix) but not yet its alert history. sn-web and sn-monitor are fully covered.

**What this changes**: the original blocker on reverting VM 102/104/106 to `pbs-hot` — "no offsite
copy exists for PBS-format backups" — no longer applies the way it did. Offsite protection for
these 3 VMs now comes from `fleet-state-backup.sh` + `sync.sh`, independent of whichever storage
`daily-fleet-backup-pbs` targets. Whether to actually revert is still Mr. Byrne's call, not decided
here — but the reason to keep waiting is gone for sn-web/sn-monitor, and mostly gone for
sn-security (config only, pending the indexer-data follow-up).

**Widened fleet-wide the same day, at Mr. Byrne's explicit direction** ("all key databases...
email... I mean everything"), after he asked why this shouldn't cover the whole fleet, not just
the 3 VMs this item started with. Auditing every host for the same class of gap found something
far more severe than anything this scope doc was originally about: **Vaultwarden — the system
holding every credential in this entire project — had zero backup coverage anywhere.** Full detail
in `fleet_state_backup_fleet_wide_2026_09_07` memory and the `fleet-state-backup` row in
`services-fleet.md`; not duplicated here since it's no longer really a PBS question. Short version:
`fleet-state-backup.sh` now also covers Forgejo, PowerDNS-Admin, hot-wiki, Namevault (sn-infra),
ERPNext (hot-erp-nl), and Nextcloud (hot-pn) — 12 pieces total, ~13GB, first full run 2026-09-07
succeeded with zero failures and was spot-verified restorable, not just pushed.

---

## 10. PBS made the actual local-storage rebuild backup, 2026-09-07 — Mr. Byrne's direct request

The framing changed again, the day after Section 9's resolution. Mr. Byrne's ask was explicit: he
wants PBS itself — his own local hardware — to be a continuously-updated, fully-encrypted backup
covering everything needed to rebuild HoT from scratch, not a one-off encrypted archive delivered
somewhere. First attempt at this request was to propose a single encrypted export archive (age,
delivered via SendUserFile); corrected immediately once he clarified he meant PBS as the living
backup target, updated daily.

**Two gaps stood between "PBS backs up 3 VMs" and "PBS backs up everything":**

1. **`pbs-hot`'s datastore had no client-side encryption at all.** Flagged back in Section 8 as an
   open gap, never closed. Fixed: `pvesm set pbs-hot --encryption-key autogen` on hot-bm-nl —
   PVE-storage-integrated PBS encryption only supports a non-passphrase-protected raw key (a real
   PVE limitation, confirmed via `pvesm set --help`, not a design choice made here); the resulting
   key (`/etc/pve/priv/storage/pbs-hot.enc`, fingerprint `f0:c3:8b:0a:...4a:e5:0f`) was immediately
   pulled off hot-bm-nl and saved to Vaultwarden — it's the *only* thing standing between "encrypted"
   and "permanently unrecoverable" for every VM backup on `pbs-hot` from this point forward.

2. **Gateway, hot-pn, and hot-erp-nl are standalone VPS's, not Proxmox VMs — `pbs-hot`/vzdump can
   never reach them, at all, structurally.** Their real state (Vaultwarden's own data, Keycloak,
   Nextcloud, ERPNext, PrivateNexus, every Docker named volume) had cloud backup coverage
   (`fleet-state-backup.sh`, `backup-gateway-vps.sh`, hot-pn's own pg_dump chain) but zero copy on
   Mr. Byrne's own local storage. Fixed with a new mechanism, `pbs-host-backup.sh` — installed
   `proxmox-backup-client` on all 3 hosts (Proxmox's own client-only apt repo, `pbs-client trixie`,
   works cleanly on Ubuntu 26.04 despite no official Ubuntu target) and built a daily (03:40)
   systemd-timed push of `/opt`, `/root`, `/var/lib/docker/volumes`, and `/etc/wireguard` where
   present, encrypted client-side with a dedicated key.

**Real facts checked before assuming `/opt` alone was enough**: `/var/lib/docker/volumes` was
confirmed non-trivial on all 3 hosts (778MB Gateway, 1.3GB hot-pn, 915MB hot-erp-nl) — hot-erp-nl's
ERPNext data in particular lives entirely in named Docker volumes
(`dickson_dickson-{db,sites,assets}-data`), not a bind mount, and would have been silently missed
backing up `/opt` alone (hot-erp-nl's `/opt` is only 108KB). This is exactly the kind of gap the
project's "rebuild recipe" backups keep finding when checked live instead of assumed.

**Encryption**: a dedicated `proxmox-backup-client` key (`fleet-hosts.key`), scrypt-KDF,
passphrase-protected — generated via a Python PTY script (`key create` needs a real terminal, no
env-var bypass exists for that specific subcommand, unlike `backup`/`restore` which do respect
`PBS_ENCRYPTION_PASSWORD`). Same key file distributed to all 3 hosts via `scp` over already-trusted
channels; the passphrase lives in Vaultwarden, not in any script. A dedicated least-privilege PBS
user/token (`fleet-hosts@pbs!hostbackup`, `DatastoreBackup` role only — cannot read or modify any
other backup, including the VM backups the `hot-bm-nl@pbs!vzdump` token holds) was created rather
than reusing an existing identity.

**Two real bugs hit standing this up, both fixed same-session**: `proxmox-backup-client backup
--ns hosts` failed with "namespace not found" — this PBS version's client has no dedicated
`namespace create` subcommand in `proxmox-backup-manager`, and creating one via the client itself
needs `Datastore.Modify`, which the least-privilege token deliberately doesn't have. Simplest fix,
not a workaround: dropped the `--ns` entirely — PBS's `host`-type backup groups don't collide with
the existing `vm`-type VM backups even sharing the datastore root, so no namespace was actually
needed. Second: the very first `vzdump 104 --storage pbs-hot` verification run was killed mid-backup
by an unrelated local low-memory event that took down the foreground SSH session carrying it — real
data loss risk from running a long verification test in a way that dies with the terminal, not a
PBS/encryption bug. Fixed by re-running fully detached (`nohup ... & disown`) and by using the
`Monitor` tool to watch for completion instead of holding the session open.

**Verified live before trusting any timer**, same convention as every other automation in this
project: real first backups on all 3 hosts (Gateway 2.9GB in 150s reusing 32MB incrementally already
just from re-running the fixed script twice; hot-erp-nl 838MB in 48s over Tailscale; hot-pn 13.5GB
in 54min, the genuine cold-start baseline — its `/opt` alone is 14GB, dominated by Nextcloud's real
user data and Notesnook's Mongo/MinIO state). `daily-fleet-backup-pbs` (102/104/106) reverted from
Section 9's interim `local-backup-zfs` fallback back to `pbs-hot`; a new job,
`daily-fleet-backup-pbs-sninfra` (02:15), additionally sends VM 100/sn-infra to PBS too —
deliberately additive, not a replacement for its existing `local-backup-zfs`+Hetzner-offsite path
(keeping sn-infra's backup coverage independent of PBS/wg6 health, since it hosts the Tang fallback
and other core infra other VMs depend on).

**Throughput finding, resolved same session**: VM 104's real first encrypted backup to `pbs-hot`
showed ~4 MiB/s mid-transfer, which projected to 15-18h for a full 250GB image if sustained. A clean
full re-run showed this was a false alarm: PBS's chunk dedup reused 99% of the VM's data from a
pre-outage backup already sitting on the datastore, so the real transfer was 1.12GB in 169s
(6.8 MiB/s) — this is what real nightly runs should look like going forward, not the cold-start
number. Confirms the earlier ~1.5-2 MiB/s figure from Section 8 was specific to that test's
direction (pulling a full image *off* PBS, bound by its home upload) and doesn't apply here (pushing
*into* PBS, which rides its fast download side and, more importantly, PBS's own dedup means most
nights transfer only the delta, not the full image either way).

**Real bug found+fixed the same session: the retention-prune step on both the VM and host-level
paths was failing on every run, even though the backup itself always succeeded.** `vzdump`'s own
inline `proxmox-backup-client prune` call (driven by the job's `prune-backups` config) errored with
`missing Datastore.Modify|Datastore.Prune`, which failed the whole job nightly via `mail-to-root`
despite the actual backup data landing safely — a real, easy-to-miss false-failure signal that would
have looked like a broken backup pipeline every night. Root cause: the `DatastoreBackup` role
originally granted to both `hot-bm-nl@pbs!vzdump` and the new `fleet-hosts@pbs!hostbackup` tokens
doesn't include prune privilege, and granting `DatastorePowerUser` to the *token* alone wasn't
enough — PBS tokens are privilege-separated by default, so effective permission is the intersection
of the token's own ACL and its underlying user's ACL. Fixed by granting `DatastorePowerUser` to both
the user and the token for each identity. Verified clean via real reruns on all 4 paths (VM 104's
full vzdump job including its inline prune, plus Gateway/hot-pn/hot-erp-nl's `pbs-host-backup.sh`,
which now also calls `proxmox-backup-client prune` on its own `host/<name>` group,
`--keep-daily 7 --keep-weekly 4`, after every successful backup).

**Still not done**: neither `pbs-host-backup.sh` nor the newly-encrypted `pbs-hot` VM backups have
been wired into `fleet-health-sweep`'s monitoring the way `wg6-handshake`/`pbs-hot-storage` already
are — a failed host-level backup currently only alerts via its own inline Ntfy `notify()` call, with
no streak-based escalation if it fails silently for several nights running. Worth folding in as a
future `fleet-health-sweep` check, same shape as the existing PBS checks, rather than assuming the
per-run Ntfy alert alone is sufficient (it wasn't, historically, for exactly this class of gap — see
the `grub-pc`/apt-daily-update precedent in `operational-rules.md`).

---

## 11. Wazuh indexer OpenSearch snapshot — the last flagged gap, closed 2026-09-08

`fleet-state-backup.sh` covered every other database in the fleet with a proper dump command
(`pg_dump`/`mariadb-dump`/`sqlite3 .backup`) from day one, but explicitly deferred sn-security's
Wazuh indexer — a raw copy of its live OpenSearch/Lucene data risked an inconsistent, untested
restore, and building a real snapshot mechanism was flagged as its own follow-up. Built this
session, at Mr. Byrne's direct request after he asked why it wasn't covered yet.

**Mechanism**: OpenSearch's native snapshot API against a filesystem repository — `path.repo`
added to `wazuh.indexer.yml` (a bind mount, `./snapshots:/usr/share/wazuh-indexer/snapshots`, owned
by the container's UID 1000), a repo registered once (`PUT /_snapshot/hot_backup_repo`, idempotent —
`fleet-state-backup.sh` re-registers it every run, harmless if already present and self-healing if
config ever drifts). Nightly: take a new dated snapshot into the same repo (`wait_for_completion`),
prune snapshots older than 14 days via the API, tar the repo directory, push through the same
`push()`/rclone-crypt pipeline every other piece in this script uses. `partial: true` is deliberate —
found live during this build that a handful of old (Jul/Aug), empty, genuinely-unallocated-primary-
shard indices exist on this indexer (pre-existing, unrelated to this work — see the incident note
below), and an all-or-nothing snapshot would fail entirely over data that was already gone; partial
mode captures everything healthy and records the rest as failed shards without blocking the backup
that actually matters (the current month's real alert data, confirmed green throughout).

**Verified for real, not just pushed**: a full snapshot succeeded 144/144 shards once the cluster
was fully green (a first attempt mid-recovery came back PARTIAL with the known-bad old indices,
confirmed harmless, deleted, redone clean). Restorability was checked directly — restored a real
alert index under a renamed copy (`restore-test-wazuh-alerts-4.x-2026.09.06`), confirmed matching
doc count (2/2) and genuine alert content (`rule.description`, real timestamp, real agent name), not
an empty shell. Test index and test snapshot both deleted after. Wired into `fleet-state-backup.sh`
and verified via the real `systemctl start fleet-state-backup.service` path alongside every other
piece, not in isolation.

**Real incident hit mid-build, unrelated to the snapshot work itself, fixed the same session**:
recreating the indexer container to pick up the new `path.repo` config took it down for ~5 minutes
while its ~144 shards reallocated. During that window, Wazuh's dashboard returned enough 403s to
Blackbox Exporter's routine public-URL probing that CrowdSec's `http-generic-403-bf` scenario banned
**hot-bm-nl's own public IP** (`31.207.47.146`) at the Caddy edge — and since every VM on hot-bm-nl
shares that IP as its NAT egress for public-internet traffic, the ban broke *every* public health
probe from the whole host, not just Wazuh's, matching Mr. Byrne's real-time report ("probes failing
all over the shop"). Investigating turned up the real, separate root cause: `forgejo-runner` (also
on sn-security) had a stale auth token and had been silently failing to poll Forgejo since
**2026-09-05** (3 days, undetected — nothing watches this) at a 2-second retry interval against
`git.securenexus.net`'s *public* URL (a real design flaw — internal CI polling should never depend
on the public edge at all) — each round of 403s re-triggered the same ban within ~14 seconds, faster
than it could be manually cleared, a self-sustaining loop. Fixed: stopped the runner to break the
loop, cleared the ban, force-registered the runner fresh via its still-valid shared secret (moving
aside its stale `.runner` state file — act-runner's own documented recovery path), confirmed clean
task-fetch and zero new bans. **Two real follow-ups flagged, not yet done**: point `forgejo-runner`
at Forgejo's internal address instead of the public one, and add a `fleet-health-sweep` check for
actual task-fetch success (not just container/process liveness) so a repeat doesn't run silently for
days again.

**Separate, pre-existing finding, not caused by or blocking this work**: the indexer's cluster health
was briefly `red` during the same recovery window due to a set of old (2026-07-27 through 08-19),
empty indices with unallocated primary shards — resolved on its own once shard reallocation finished
(fully `green`, 144/144, within a few minutes), but worth a closer look separately: genuinely lost
primary shard data on old indices is a real question mark on Wazuh's own index lifecycle/retention,
independent of anything backup-related.
