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
