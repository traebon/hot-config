## Alerting Architecture (3 Channels)

| Severity | Triggers                                          | SMTP | Ntfy | SMS |
|----------|---------------------------------------------------|------|------|-----|
| CRITICAL | Service down, cert <7d, WireGuard down, disk >95% | ✓    | ✓    | ✓   |
| HIGH     | Cert <14d, target down >10 min, disk >85%         | ✓    | ✓    | —   |
| WARNING  | Memory >90%, backup failure, CrowdSec spike       | ✓    | ✓    | —   |
| INFO     | Backup completed, Watchtower update available     | —    | ✓    | —   |

SMS rate limit: max 1 SMS per alert group per 5 minutes.
SMS relay: **rebuilt on the Gateway VPS 2026-08-03, fully functional as of 2026-08-04** (see
Gateway VPS service table and sms_relay_migration_scope memory) — the original, documented as
living on sn-infra, was found to be completely gone (confirmed during the 2026-08-03 hot-bm-nl
outage recovery, not merely at risk from it — see hot_bm_nl_outage memory) since at least the
2026-07-27 sn-infra rebuild, which never redeployed it. Subscribes to Ntfy directly (`hot-alerts`
topic) rather than a per-publish webhook. Real Twilio credentials wired in 2026-08-04; a genuine
FROM/TO number mixup was found and fixed the same day (Twilio's only hosted number,
`+447403942795`, is the sender identity — Mr. Byrne's actual mobile is `+447771724186`, see
user_contact memory) — verified with a real SMS sent via Twilio's API and confirmed received on his
phone. `⚠ Worth auditing separately, not blocking`: whether Grafana/Wazuh actually publish at
Ntfy `priority=5` for genuinely CRITICAL events — the relay's trigger logic is proven correct end
to end, but no current publisher has been confirmed to use that priority yet.

---

## Backup Architecture

**Corrected 2026-08-08 — there is no separate generic "06:00 Hetzner / 07:30 B2" pull job.** Each
script below pushes to its cloud remote(s) directly, on its own cron schedule. This table previously
implied a shared pull-everything step at fixed times; that mechanism doesn't exist. Verified against
the Gateway's live crontab (`crontab -l`) and each script's actual logic while investigating a
2026-08-08 silent-failure bug (see below).

| Tier           | Tool                  | Schedule    | Destination             | Encryption                         |
|----------------|-----------------------|-------------|-------------------------|------------------------------------|
| VM snapshots   | vzdump (Proxmox)      | 02:00 daily | /var/lib/vz/dump (ZFS)  | zstd compressed                    |
| VM snapshots offsite (hot-bm-nl) | rclone crypt (`vzdump-offsite-push.sh`, systemd timer) | 04:30 daily (after the 02:00 vzdump job) | **Hetzner Storage Box only** | rclone crypt (hetzner-crypt remote) |
| Config sync    | git + cron            | 01:00 daily | Forgejo → Codeberg + GH | Forgejo auth                       |
| Keycloak DB (Gateway) | `backup-keycloak.sh`, cron | 01:30 daily | Primary: hot-bm-nl. **Hetzner+B2 only as a fallback** when hot-bm-nl is unreachable that night — not a nightly B2 write | rclone crypt (same two remotes) |
| hot-pn PrivateNexus DB (formerly pn-vps) | pg_dump (hot-pn, own timer ~03:00) + Gateway rsync pull + rclone crypt | 03:30 daily | Local (hot-pn, 14d) → Gateway (30d) → **Hetzner + B2, both attempted every night unconditionally** — this is the one reliable nightly B2 write, useful as the canary for whether B2 pushes are currently healthy | rclone crypt (hetzner-crypt/b2-hot-crypt) |
| Gateway VPS backup (Tor keys, PowerDNS DB, Mailserver) | `backup-gateway-vps.sh`, cron | 05:30 daily | Primary: hot-bm-nl. **Hetzner+B2 only as a fallback** when hot-bm-nl is unreachable that night, same pattern as Keycloak above | rclone crypt (same two remotes) |
| Cloud (B2), overall scope | — | — | Backblaze B2 — **small DB/config backups only, not VM images** (see backup_architecture_b2_scope_2026_08_08 memory) | rclone crypt — hard_delete=true |

Real cron order: 01:00 config sync → 01:30 Keycloak → 02:00 vzdump (~3h, done ~05:00) → 03:00
hot-pn's own pg_dump → 03:30 Gateway pulls it + pushes Hetzner/B2 → 04:30 hot-bm-nl's own
vzdump→Hetzner push → 05:30 Gateway VPS backup (Tor/PowerDNS/Mailserver, primary path to hot-bm-nl).
⚠️ vzdump runs on hot-bm-nl's 4 VMs (100/102/104/106) — real fleet-wide nightly output is **~415GB**
(VM 102/sn-web alone is ~268GB/backup), so full-image offsite retention (14d) is a ~5.8TB
steady-state footprint. This is why B2 is deliberately scoped to DB/config-only above — B2's account
cap was sized for that small scale, not full VM images (Hetzner absorbs those instead).

**Real bug found+fixed 2026-08-08: `backup-gateway-vps.sh`'s mailserver `tar` step could silently
kill the entire nightly run with zero alerting.** The script runs under `set -e`; `tar` returns exit
code 1 (not 2) for the ordinary, non-fatal "file changed as we read it" warning that happens when
archiving a live mail spool/rspamd state directory mid-write — `set -e` doesn't distinguish that
from a real failure and killed the script immediately, before any of its own alert-sending code
could run. This happened for real on 2026-08-08's 05:30 run: the log just stops mid-archive, no
push to hot-bm-nl, no cloud fallback, no email/Ntfy — a full night's backup silently vanished. Fixed
by wrapping both `tar` calls (Tor keys + mailserver) to tolerate exit code 1 specifically while
still treating exit 2+ as fatal. Verified same-day: ran the fixed script manually, completed cleanly
end-to-end (Tor → PowerDNS → Mailserver 300M → pushed to hot-bm-nl). Config repo: /opt/hot-config →
Forgejo (git.securenexus.net) + Codeberg + GitHub mirrors. ⚠️ Cloud uploads must NOT start before
06:00 if ever scheduled directly against local disk — concurrent HDD I/O caused nightly crashes (Jun
26–28) — not currently a live constraint given the schedule above, kept here as the original reason.

**Fleet-wide sweep for the same bug pattern, same day, turned up a separate housekeeping item:**
`/usr/local/bin/backup-gateway-vps.sh` and `/usr/local/bin/backup-keycloak.sh` were both stale,
unused duplicates (dated 2026-07-04, still referencing the retired `proxmox` SSH alias and old
sn-infra-hosted Ntfy) sitting alongside the real, live scripts at `/opt/hot-config/scripts/` — cron
only ever called the `/opt/hot-config/` copies (see the table above), so both `/usr/local/bin/`
duplicates were dead weight, never executed. Both removed 2026-08-08/09 after confirming no
cron/systemd reference to either path. `/usr/local/bin/` now has no leftover backup scripts at all —
`backup-keycloak.sh`/`backup-gateway-vps.sh` only exist under `/opt/hot-config/scripts/`.

**B2 cap fix confirmed via the real nightly canary, not just an ad hoc test:** `b2-cap-check.sh`
(`/usr/local/bin/`, mirrored to `hot-config/gateway/scripts/`, run once via a `systemd-run
--on-calendar` one-shot timer 2026-08-09 06:15) checked the prior night's real scheduled runs —
`hot-pn`'s 03:30 pg_dump pushed to `b2-hot-crypt` with zero errors on 2026-08-09, vs. real `403
storage_cap_exceeded` failures on both 2026-08-07 and 2026-08-08. See
backup_architecture_b2_scope_2026_08_08 memory for full detail.

---

