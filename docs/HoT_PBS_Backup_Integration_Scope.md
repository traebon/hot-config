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
