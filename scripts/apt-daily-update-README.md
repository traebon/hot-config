# Daily apt update && upgrade — fleet rollout (2026-08-05)

Deployed to all hosts reachable from the Gateway. Two variants, per-host config lives in
`/etc/apt-daily-update/` on each live host (not tracked in git — `ntfy_token` is a secret,
`auto_reboot` is a one-line flag copied below for reference).

## Variant 1 — full auto-upgrade (`apt-daily-update.sh`)

`apt-get update && apt-get -y upgrade` daily via systemd timer (`OnCalendar=09:00`,
`RandomizedDelaySec=10min` — deliberately outside the 01:00-07:30 nightly backup window, see
CLAUDE.md Backup Architecture). Logs to `/var/log/apt-daily-update.log`. Sends an Ntfy
notification (`priority=high`, below the `priority=5` SMS threshold — see sms-relay) on
`apt-get update`/`upgrade` failure, and on reboot-required.

Deployed to: gateway, sn-infra, sn-web, sn-monitor, sn-security, hot-pn, hot-erp.

**`auto_reboot` per host** (`/etc/apt-daily-update/auto_reboot`, `true`/`false` — Mr. Byrne's
explicit decision 2026-08-05):

| Host        | auto_reboot | Why |
|-------------|-------------|-----|
| gateway     | false       | Single control point — WireGuard hub, Tang server for all 7 VMs, DNS, mail. Notify-only. |
| sn-infra    | true        | |
| sn-web      | true        | |
| sn-monitor  | true        | |
| sn-security | true        | LUKS2+Tang auto-unlocks on boot — safe to reboot unattended. |
| hot-pn      | true        | |
| hot-erp     | true        | |
| hot-bm-nl   | n/a         | Not on this variant at all — see Variant 2. |

When `auto_reboot=true` and `/var/run/reboot-required` exists after upgrading, the script runs
`shutdown -r +2` (2 min grace) and sends an Ntfy notification first. When `false`, it only
notifies — never reboots.

## Variant 2 — check-only, manual approval (`apt-daily-check.sh` + `apt-approve-upgrade`)

Deployed to **hot-bm-nl only** (the Proxmox host running all 4 production VMs — a bad
`pve-kernel`/`pve-manager`/`qemu-server` bump or unattended reboot here takes the whole fleet
down at once, so this host never auto-applies). Same daily timer schedule, but the script only
runs `apt-get update` + `apt list --upgradable` and Ntfy-notifies with the package list — it
never runs `apt-get upgrade`.

`apt-approve-upgrade` is installed at `/usr/local/bin/apt-approve-upgrade` on hot-bm-nl —
run it by hand (interactive, shows the package list, asks y/N) to actually apply after
reviewing. It never auto-reboots either — reboot hot-bm-nl manually if one ends up required.

## Shared bits

- Ntfy token: reuses the same shared publish token already used by CrowdSec/Grafana
  (`/opt/hot-config/gateway/crowdsec/notifications/http.yaml`) — not duplicated per-service.
  Written to `/etc/apt-daily-update/ntfy_token` (chmod 600) on each host directly; not tracked
  in git (matches the `**/secrets/` exclusion pattern in spirit, even though this particular
  path isn't literally under a `secrets/` dir).
- Verified live on first deploy (2026-08-05): ran each script manually on every host before
  trusting the unattended timer. hot-pn and hot-erp-nl both had a pending kernel update and
  genuinely auto-rebooted during this verification — confirmed both came back up cleanly
  (docker active, all containers healthy) before moving on. hot-bm-nl's check-only run
  correctly listed upgradable packages (including `qemu-server` itself) without applying
  anything — exactly the scenario this variant exists to gate.
