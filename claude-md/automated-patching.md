## Automated Patching (apt update && upgrade — deployed 2026-08-05)

Every host runs a daily systemd timer (`apt-daily-update.timer` / `apt-daily-check.timer`,
`OnCalendar=09:00`, `RandomizedDelaySec=10min` — deliberately outside the 01:00–07:30 backup
window above). Two variants:

| Variant | Hosts | Behavior |
|---------|-------|----------|
| Full auto-upgrade (`apt-daily-update.sh`) | Gateway, sn-infra, sn-web, sn-monitor, sn-security, hot-pn, hot-erp | `apt-get update && apt-get -y upgrade` daily, unattended. |
| Check-only, manual approval (`apt-daily-check.sh` + `apt-approve-upgrade`) | **hot-bm-nl only** | Lists upgradable packages via Ntfy, never applies. Run `apt-approve-upgrade` on hot-bm-nl by hand to review + apply — this host runs all 4 production VMs, so a bad `pve-kernel`/`qemu-server` bump or unattended reboot here would take the whole fleet down at once. |

**Reboot policy is per-host** (`/etc/apt-daily-update/auto_reboot`, Mr. Byrne's decision
2026-08-05): `false` (notify only, never reboot) on **Gateway** (single control point — WireGuard
hub, Tang server for all 7 VMs, DNS, mail) and **hot-bm-nl** (not on this variant at all — see
above). `true` (auto-reboot ~2 min after upgrading, if `/var/run/reboot-required` exists) on every
other host — sn-security included, since its LUKS2+Tang binding auto-unlocks on boot without any
manual step (see NBDE unlock chain in Operational Rules), so an unattended reboot there is safe.

Failures and reboot-required events notify via the same shared Ntfy token CrowdSec/Grafana already
use (`gateway/crowdsec/notifications/http.yaml`), at `priority=high` — below the `priority=5`
threshold that triggers SMS (see Alerting Architecture), so a routine patch failure doesn't page
Mr. Byrne's phone, just shows up in Ntfy/logs.

Verified live on first deploy: ran every script manually on every host before trusting the
unattended timer. hot-pn and hot-erp-nl both had a genuine pending kernel update and really
auto-rebooted during this verification — confirmed both came back up cleanly (docker active, all
containers healthy) before moving on. hot-bm-nl's check-only run correctly listed upgradable
packages (including `qemu-server` itself) without applying anything, exactly the scenario that
variant exists to gate. Full detail: `scripts/apt-daily-update-README.md` in `hot-config`.

**⚠ Real bug found+fixed 2026-08-16: `apt-daily-update.service` silently failed on hot-pn for 4
straight nights (Aug 13–15), meaning zero security patches landed there in that window.** Root
cause: `grub-pc`'s debconf `install_devices` list (`grub-pc/install_devices`) had 4 targets —
the raw disk, its boot partition, the LVM PV, and the LVM root LV itself — a stale artifact of
however the image was originally provisioned. `grub-install` succeeds against the raw disk/partition
but always fails against the LVM PV/LV ("embedding is not possible... required for RAID and LVM
install"), which left `grub-pc` permanently stuck `iF` (not fully installed) and made every
`apt-get upgrade` abort with `E: Sub-process /usr/bin/dpkg returned an error code (1)` before
touching any other package. The failure was real but silent — `apt-daily-update.sh`'s own Ntfy
`notify high` call should have fired on this (`apt upgrade FAILED`), but with no follow-up until a
fleet health check on 2026-08-16 caught the 3-day `systemctl --failed` streak. **Fixed**:
`debconf-set-selections` reset `grub-pc/install_devices` to just the raw disk
(`/dev/disk/by-id/scsi-...`, the one target that already installs cleanly), then
`DEBIAN_FRONTEND=noninteractive dpkg --configure -a` — clean run, `dpkg --audit` confirmed no other
broken packages. Ran `apt-daily-update.sh` manually afterward to clear the backlog (`0 upgraded, 0
newly installed` — nothing had actually queued up behind the block). **This is a generic cloud-VPS
LVM/grub-pc debconf gotcha, not hot-pn-specific** — check `dpkg -l grub-pc` / `dpkg --audit` on any
host using LVM-on-a-single-disk (hot-erp-nl is the other Hostkey VPS on a similar layout) if its
`apt-daily-update.service` ever shows `--failed`, before assuming a transient network blip. See the
Operational Rules table below for the generic form of this gotcha.

### Reboot recovery watchdog (`reboot-recovery-watchdog.timer`, Gateway VPS, deployed 2026-08-05)

Built the same day, after hot-pn's auto-reboot above genuinely hung: WireGuard/ICMP/TCP:22 all
stayed healthy while sshd never responded, and it took 27+ minutes of manual checking plus a
Hostkey hard-stop+power-on (same fix as the 2026-08-03 hot-bm-nl outage, CS-510977) before it
recovered. This watchdog automates that detection-and-recovery sequence going forward, for every
host that can auto-reboot (`sn-infra`, `sn-web`, `sn-monitor`, `sn-security`, `hot-pn`, `hot-erp`
— not Gateway/hot-bm-nl, which never auto-reboot in the first place).

Runs every 5 min via systemd timer, checks reachability with a real SSH command (not ping/TCP —
those stayed healthy the whole time during the hot-pn incident and would not have caught it).
Per-host state tracked in `/var/lib/reboot-watchdog/`. Escalation, mirroring what actually worked
for hot-bm-nl and hot-pn:

1. **Unreachable 10+ min** → CRITICAL Ntfy alert (`priority=5/urgent`, triggers SMS) + automatic
   **soft reboot** — `eq.php?action=reboot` via the Hostkey invapi for `hot-pn` (id `4683`) /
   `hot-erp` (id `41614`, standalone VPS), or `qm reboot <vmid>` on hot-bm-nl for the 4 Proxmox
   VMs (`sn-infra`=100, `sn-web`=102, `sn-monitor`=104, `sn-security`=106).
2. **Still unreachable 20+ min** (10 min after the soft attempt) → CRITICAL alert + automatic
   **hard power-cycle** — `eq.php?action=hard_off` then `action=on` for the Hostkey-hosted pair,
   or `qm stop --skiplock <vmid>` + `qm start <vmid>` for the Proxmox VMs.
3. **Still down after the hard cycle** → re-alerts every 15 min, but takes **no further automatic
   action** — at that point it's flagged as needing the Hostkey KVM console by hand, same as any
   hardware/hypervisor-level failure (see the hot-bm-nl outage precedent).
4. Recovery (SSH reachable again) always sends a follow-up Ntfy notification naming which stage
   was last attempted, so Mr. Byrne has full visibility even though the whole sequence ran
   unattended.

Hostkey server IDs (`4683`=hot-pn, `41614`=hot-erp) were verified live against the invapi
(`eq.php?action=show`, matching each server's real public IP) before being hardcoded here — not
just trusted from memory, since this script can genuinely hard-power-cycle production
infrastructure unattended. The escalation logic itself was verified with an isolated test harness
(fake host, stubbed reachability + actions, compressed thresholds) before being enabled for real,
confirming the full down → soft → hard → repeat-alert → recovered state machine transitions
correctly — deliberately not tested by forcing a real host down, given what's at stake if the
logic were wrong.

Uses the same shared Ntfy token and Hostkey invapi key already documented elsewhere
(`/opt/stacks/hostkey-api/secrets/hostkey_api_key.txt` — see the `hostkey-invapi-notes` memory).

**⚠ Real bug found+fixed 2026-08-06/07: the Hostkey token parser used the wrong JSON shape,
silently failing every hostkey-backed recovery action for 7.5 hours.** `hostkey_token()` parsed
`auth.php`'s response as `{"token": "..."}` top-level, but the real shape nests it —
`{"result": {"token": "...", ...}}`. Every `hostkey_token()` call therefore failed, which the
action functions correctly logged ("hostkey auth FAILED") — but the main loop **unconditionally**
advanced `stage_file` to `soft`/`hard` regardless of whether the action actually succeeded, so the
state machine locked into `hard` after the first failed attempt and then just re-alerted every
~15 min with **no further action ever taken or retried**. This let a real hot-pn outage run
unremediated from 09:12 to ~16:59 on 2026-08-06 (27 identical "still down, needs the Hostkey KVM
console" alerts) — found during routine follow-up verification of this watchdog, not by active
monitoring. Fixed: (1) corrected the JSON parse to `['result']['token']`; (2) `stage_file` now only
advances when `do_soft_reboot`/`do_hard_cycle` actually return success — on failure it sends a
distinct "FAILED, will retry" alert and leaves the stage unchanged so the next tick retries, gated
by the same `REPEAT_ALERT_SEC` throttle. The live outage was recovered manually the same way the
watchdog was supposed to (hostkey `hard_off` + `on` against id `4683`) before the code fix landed.
**Verified for real, not just by inspection**: the very next day (2026-08-07 06:07–06:40) sn-monitor
genuinely went down and the *fixed* script correctly self-healed it end-to-end (soft reboot at
06:21, hard cycle at 06:36, recovered 06:40) — the first real proof this watchdog works as designed
end-to-end, not just in the isolated test harness. Root lesson: the original test harness stubbed
out `do_soft_reboot`/`do_hard_cycle` specifically to avoid touching real APIs while validating
timing — correct for safety, but it meant the real `hostkey_token()`/`hostkey_call()` code path was
never actually exercised before deploy. State-machine logic and real API-calling logic both need
independent verification, not just one via a stub.

**Fail-safe health check** (`reboot-watchdog-healthcheck.sh` on the Gateway) reports timer liveness
(via `LastTriggerUSec` staleness, >10min triggers a flag), recent journal failures, recent
watchdog-log activity, and stale per-host state files via Ntfy. Had its own latent bug fixed
2026-08-08: it originally flagged the watchdog log as "an issue" if it had **any** content ever,
which — once the log has real permanent history (as it now does, from the incidents above) — would
report "issues found" on literally every future run forever. Fixed to only look at the last 24h of
journal/log activity so repeat runs stay meaningful.

**⚠ Real compounding bug found+fixed 2026-08-19: this fail-safe was itself silently gone for 6
days, for a completely different reason than the bug it exists to catch.** It had only ever been
scheduled via ad hoc `systemd-run --on-calendar` **transient** one-shot units — which, unlike a real
unit file under `/etc/systemd/system/`, do not survive a reboot — and was never tracked in
`hot-config` git at all. It vanished entirely after a Gateway reboot (see the corrected date below —
originally attributed to 2026-08-16 here, actually the earlier ~2026-08-13 reboot), the same reboot
that wedged `reboot-recovery-watchdog.timer` itself (see the bug below) — so the fail-safe for that
exact failure mode was gone for the same 6 days, and nothing re-created it. Its actual detection
logic was never broken — running it manually during the 2026-08-19 investigation confirmed it would
have correctly flagged the wedge via the `LastTriggerUSec` staleness check. **Fixed**: gave it a
real persistent timer (`reboot-watchdog-healthcheck.timer`, `OnCalendar` 4x daily, from the start —
see the timer-wedge bug immediately below), and added the script + units to `hot-config` for the
first time (`gateway/reboot-recovery-watchdog/`). See `gateway_timer_wedge_bug_2026_08_19` memory.

**⚠ Real bug found+fixed 2026-08-19: `reboot-recovery-watchdog.timer` itself silently wedged dead
for 6 days** — `systemctl` reported it `enabled`/`active` the whole time, zero error state, but it
had not fired once since 2026-08-13. **Correction, same day, caught by the first real
`fleet-judgment-review` (Option D1) run**: originally attributed here to "the same 2026-08-16
reboot" — wrong, `journalctl --list-boots` shows an earlier reboot (boot ending Aug 13 09:20:17 →
next boot starting Aug 13 09:42:00) that the last real pre-wedge firing (09:16:53) predates; 6 days
back from the Aug 19 fix lands on Aug 13, not Aug 16, so the original numbers never actually
reconciled. Root cause: the timer used only
`OnBootSec=2min` + `OnUnitActiveSec=5min`, no `OnCalendar` — if the `OnBootSec` window is missed
(most likely `network-online.target` came up later than 2min after this particular boot),
`OnUnitActiveSec` has no reference to anchor "next fire" on since the unit has never been active,
and `NextElapseUSecMonotonic` permanently becomes `infinity`. `systemctl restart` alone does not fix
this — only manually running the service once re-arms it, and that's not durable across the next
reboot either. Fixed by switching to `OnCalendar=*:0/5` (same fix applied to
`sn-infra-recovery-check.timer`, identical bug, same day) — immune to this bug class since `NEXT` is
computed from wall-clock, not unit history. **Any new recurring timer in this project must use
`OnCalendar`, never `OnBootSec`/`OnUnitActiveSec` alone** — see the Operational Rules table and
`gateway_timer_wedge_bug_2026_08_19` memory. Found while building `fleet-health-sweep` (first slice
of `docs/HoT_Automation_Self_Healing_Scope.md`), not by either watchdog's own alerting.

---

## Grafana Alerting

SMTP: mail.house-of-trae.com:587 via notifications@house-of-trae.com. Contact points: "email-hot" → tristian@securenexus.net (all critical/high alerts); "ntfy-critical" → webhook to `https://ntfy.house-of-trae.com/hot-alerts` (severity=critical only, added 2026-08-04 — see below).
Alert rules (folder "HoT Infrastructure Alerts"): Node Down (critical, 2m), Disk >85% (high), Disk >95% (critical), Memory >90% (warning), TLS cert <14d/<7d (via Blackbox Exporter — deployed, probing 17 endpoints).
Notification policy: group by severity/alertname/instance — group_wait 30s, repeat 1h for critical/high, 4h default. A `severity="critical"` route (matching Node Down/Disk >95%/TLS cert <7d, the 3 rules actually labeled `severity: critical`) fires to `ntfy-critical` with `continue: true`, then falls through to the existing critical|high route so email still sends too — both receivers fire for every critical alert.

**Grafana → Ntfy → SMS wired up 2026-08-04** (closes the gap noted in sms_relay_migration_scope memory — Grafana previously had zero path to Ntfy at all, only the SMTP contact point existed). `ntfy-critical` is a `webhook` contact point, `authorization_scheme: Bearer` / `authorization_credentials` = the same Ntfy token CrowdSec's notification plugin already uses (`gateway/crowdsec/notifications/http.yaml`) — **`username`/`password` Basic-Auth fields do NOT work for this** despite matching curl tests succeeding manually; Grafana's webhook notifier 403'd until switched to the `authorization_scheme`/`authorization_credentials` fields, confirmed via a real temporary always-firing test rule pushed through the full pipeline (created, verified delivery + a real SMS, then deleted — no residue). URL includes `?title=Grafana+CRITICAL+Alert&priority=urgent` as query params (Ntfy accepts title/priority via querystring same as headers). Grafana's webhook contact point has **no payload templating** — the Ntfy message body is always Grafana's raw alert-group JSON, so `sms-relay` (see Gateway VPS service table) was extended to detect that shape and extract a readable line + Grafana's own `groupKey` for rate-limiting, instead of colliding on the one static Ntfy title every Grafana-critical alert would otherwise share. Wazuh was checked too — zero Ntfy integration exists there either (only path out is the PN Lockdown Mode webhook for level≥10, unrelated to Ntfy) — not wired up, no ask to do so yet.

**⚠ Real bug found+fixed 2026-08-08: all 6 alert rules were `execErrState: Alerting` (fail-open on query error), causing a mass false-CRITICAL SMS storm.** Grafana and Prometheus both run on sn-monitor itself — when sn-monitor went down and got hard-power-cycled by the reboot-recovery-watchdog (see below) on 2026-08-07 ~06:07–06:40, every alert rule's query to its own just-restarting Prometheus datasource errored out simultaneously, and `execErrState: Alerting` meant every rule (Node Down, Disk >85%/>95%, Memory >90%, TLS cert <14d/<7d) fired CRITICAL for every instance it had last seen — a burst of bogus "Disk >95%"/"Node Down" texts for hosts that were never actually in trouble (real disk usage checked live: 2–32% everywhere). Fixed by setting `execErrState: Error` on all 6 rules via the provisioning API (`PUT /api/v1/provisioning/alert-rules/<uid>` with `X-Disable-Provenance: true`, admin creds in `/opt/stacks/monitoring/secrets/admin_password`) — a query/datasource error now shows as a distinct Error state in Grafana's UI instead of paging as a false CRITICAL. Verified live: all alert states back to Normal, no residual false firings. This will recur on any future sn-monitor restart if `execErrState` ever drifts back to `Alerting` — check `curl -s -u admin:<pw> localhost:3000/api/v1/provisioning/alert-rules` on sn-monitor if unexplained mass CRITICAL SMS bursts happen again.

**Real capacity finding from the same investigation, fixed same day: hot-bm-nl was memory-constrained due to an uncapped ZFS ARC.** This is what triggered the (correctly real, not a false positive) "Memory >90% proxmox-host" alert seen "Pending" during this investigation — full detail and the fix (`zfs_arc_max` capped at 8 GB) now lives in the Hardware — VM Allocation section's Hard Limits note, not duplicated here.

**⚠ Separate, previously-undiscovered bug found+fixed 2026-08-09: Grafana's own SQLite database (`grafana.db`) had chronic lock contention (`SQLITE_BUSY`) since 2026-08-05 — 15,761 "database is locked" errors over 7 days, still ongoing when found.** Different root cause from the `execErrState` bug above (that one's still correctly set to `Error`, didn't drift back) — this one caused a genuine 44-minute alert-state flapping burst (02:55-03:39 UTC that morning) across all 6 rules, with **zero real infrastructure impact** (confirmed via range query: every scrape target stayed `up=1` throughout). Also explains an empty Log Explorer datasource picker Mr. Byrne separately hit — both datasources were actually still registered fine (`/api/datasources` confirmed), the picker just couldn't render reliably while Grafana's own DB was locked. No delivered notification went out for the burst (Grafana's notifier was itself failing from the same lock during that window) — what Mr. Byrne saw was the state directly in Grafana's Alerts UI, not an email/SMS/Ntfy message. Root cause: `grafana.ini`'s `[database]` section was fully default, no WAL (write-ahead logging) mode — default SQLite journal mode requires an exclusive lock per write, chokes under concurrent alert-rule evaluation writes. Ruled out an image-version cause (container `Created` timestamp unchanged since 2026-07-28; Watchtower here is deliberately `MONITOR_ONLY=true`, same as PN's). **Fixed**: added `GF_DATABASE_WAL: "true"` to sn-monitor's `docker-compose.yml`, recreated the `grafana` container, verified datasources/alert rules intact and zero lock errors across a real 5-minute post-fix monitoring window spanning multiple evaluation cycles. See `grafana_sqlite_lock_2026_08_09` memory for full detail, including one unresolved oddity (no `-wal`/`-shm` sidecar files appeared despite the fix working — didn't block declaring this fixed since the practical symptom is confirmed gone).

---

