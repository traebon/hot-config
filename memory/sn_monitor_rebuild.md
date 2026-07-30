---
name: sn-monitor-rebuild
description: "sn-monitor rebuilt as VM 104 on hot-bm-nl (2026-07-27) — full Prometheus/Grafana/Loki/Uptime Kuma/Blackbox stack live, fleet-wide node-exporter/Promtail wired up, two new UFW forward-rule bugs found and fixed"
metadata: 
  node_type: memory
  type: project
  originSessionId: f361f2af-99b4-4220-ba53-a42472c872f0
  modified: 2026-07-30T13:35:02.156Z
---

**2026-07-27 — sn-monitor rebuilt as VM 104 on hot-bm-nl.** Same VM-creation recipe as sn-web (see
[[sn_web_rebuild]]): reused the cached Debian 12 genericcloud qcow2, `qm create`/`importdisk`/
`resize scsi0 250G`, cloud-init network/SSH. 1 vCPU/4GB/250GB, VLAN 50, `10.10.50.104`, matching
CLAUDE.md's spec.

**Two real deploy bugs found and fixed, both fresh (not documented anywhere before):**
1. **Prometheus/Grafana/Loki all crash-looped on first boot** — classic bind-mount permission
   mismatch: the host directories under `/opt/monitoring/` were created root-owned, but these
   images run as non-root UIDs (`65534` prometheus/nobody, `472` grafana, `10001` loki). Fixed with
   `chown -R` to the right UID:GID per directory. Nothing wrong with the compose/config itself,
   pure host-side ownership gap on a fresh install.
2. **Loki push and node-exporter scrapes from sn-infra/sn-web both timed out** even after the
   VLAN-forward-rule fix — because that earlier fix only covered `wg0 <-> vmbr0.X` (Gateway-mesh
   access into each VLAN). It never covered **VM-to-VM traffic across VLANs on the same
   hypervisor** (sn-monitor on `vmbr0.50` needing to reach sn-infra on `vmbr0.10` and sn-web on
   `vmbr0.30`, and vice versa) — a different traffic path entirely, still hits the FORWARD chain
   since they're different subnets, just never had rules. Fixed: added bidirectional
   `vmbr0.50 <-> vmbr0.10/30/70` route rules (70 added preemptively for sn-security). **How to
   apply: any future monitoring/cross-VM traffic on this box needs its own explicit forward rule —
   don't assume the wg0-mesh fix covers VLAN-to-VLAN traffic, it's a genuinely separate path.**

**Config fixes to what already existed in hot-config:**
- `loki.yml` was referenced by the compose file (`-config.file=/etc/loki/loki.yml`) but never
  actually existed anywhere in `hot-config` — wrote a standard single-node config (filesystem
  storage, tsdb schema, inmemory ring).
- `prometheus.yml`'s scrape targets still had `sn-business`/`sn-personal`/`pn-test` pointed at
  their original VLAN IPs (10.10.20.101/10.10.40.103/10.10.60.105) — all permanently dead per the
  2026-07-24 decision (roles moved to hot-erp/hot-pn, VLANs 20/40/60 not part of this rebuild).
  Removed; left a comment explaining why, and noting sn-security's job should be added once that
  VM actually exists (not pre-declared).
- Blackbox probe target list had two dead Cosmos-era URLs (`nextcloud`/`vaultwarden.tresemme.space`
  — both removed months ago per CLAUDE.md's sn-personal section). Removed, replaced with genuinely
  live endpoints that were missing (`rubyosiris.com`, `evilrabbitart.com`, `dickson-supplies.com`,
  `ntfy.house-of-trae.com`, `vault.house-of-trae.com` — the real Vaultwarden location, which was
  never in this list at all even before the outage).

**Fleet-wide node-exporter + Promtail deployed** — closes the deferred step from the VM Clone
Checklist (item 7) that couldn't be done during sn-infra/sn-web's builds since sn-monitor didn't
exist yet to receive them. Deployed on sn-infra, sn-web, sn-monitor (self), and hot-bm-nl itself
(native `prometheus-node-exporter` apt package rather than Docker, since hot-bm-nl doesn't run
Docker and this avoids adding it just for one exporter — matches CLAUDE.md's `proxmox-node` job
target at `10.10.50.1:9100`, hot-bm-nl's own vmbr0.50 gateway IP). Also needed a new UFW rule
(`ufw allow from 10.10.0.0/16 to any port 9100`) since hot-bm-nl's own INPUT chain had never had
anything opened for this. **Verified live, not just "container running":** all 4 node-exporter
targets show `up` in Prometheus, all blackbox HTTPS probes show `up`, and real Promtail log lines
(actual Forgejo access logs) confirmed flowing into Loki via `query_range`, not just checking the
`/ready` endpoint (which has the documented cosmetic-503 quirk on single-node Loki — don't mistake
that for broken).

**Caddy/DNS for all 4 URLs (`grafana.house-of-trae.com`, `monitor.securenexus.net`,
`status.house-of-trae.com`, `prometheus.securenexus.net`) were already correctly configured** —
no fixes needed there, unlike ntfy's cross-host bug on sn-infra. Grafana's Keycloak OIDC client
(securenexus realm) was untouched by the outage, reused its existing secret. Fresh
`admin_password` generated for Grafana's local admin account (env-var-driven
`GF_SECURITY_ADMIN_PASSWORD__FILE` — CLAUDE.md's existing gotcha about this only applying on
*first* init doesn't bite here since the data volume is genuinely fresh). SMTP password reused
from Watchtower's already-correctly-rotated value (see [[grafana_smtp_password_pending]] — **that
memory is now stale/resolved**, Grafana's SMTP config on this fresh instance has the current
password baked in from the start, nothing to migrate).

**Not yet saved to Vaultwarden** — Grafana admin password sitting in this session's scratchpad,
needs Mr. Byrne's `bw unlock` session token, same standing pattern. **Superseded — see the
2026-07-27 update below, this was in fact saved that same day.**

**Known gap, not addressed this session:** CLAUDE.md documents real Grafana alert rules (Node
Down, Disk >85%/>95%, Memory >90%, TLS cert <14d/<7d) and a notification policy — none of that
exists on this fresh Grafana instance, it's Grafana-internal state that was never captured as
config/IaC anywhere, so there's nothing to redeploy from. Would need to be manually recreated via
Grafana's UI or API if wanted. Flagged, not built — wasn't asked for explicitly and is a
meaningfully separate chunk of work from standing the stack up.

---

**Update 2026-07-27 — Grafana alert rules built after all.** Mr. Byrne asked to finish open items
before moving to sn-security. Discovered along the way: **no Prometheus or Loki datasource existed
in Grafana at all** — the compose/provisioning never created them, so dashboards and alerting
would have had nothing to query even once logged in. Added both via `POST /api/datasources`
(Prometheus as default, `http://prometheus:9090`; Loki `http://loki:3100` — both resolve via the
shared `monitoring` Docker network). Confirmed the Prometheus datasource's own `/health` check
returns `OK` before building anything on top of it.

Built the full alerting setup from CLAUDE.md's spec, all via Grafana's provisioning API:
- Folder **"HoT Infrastructure Alerts"** (`uid: aftbizkw4zj7kc`).
- Contact point **"email-hot"** → `tristian@securenexus.net` (uses Grafana's own SMTP config,
  already pointed at `notifications@house-of-trae.com` via the compose env vars).
- Notification policy: root `group_by=[severity,alertname,instance]`, `group_wait=30s`,
  `repeat_interval=4h` (default), with a nested route matching `severity=~critical|high` at
  `repeat_interval=1h` — matches the documented spec exactly.
- **6 alert rules**, all in the new folder, condition = threshold on a reduced (`last`) instant
  query: Node Down (`up{job=~".*-node"} == 0`, critical, 2m), Disk >85% (high, 5m), Disk >95%
  (critical, 2m), Memory >90% (warning, 5m), TLS cert <14d (high, 10m), TLS cert <7d (critical,
  10m) — the disk/memory queries use standard node-exporter math
  (`100 - (avail/total*100)`), TLS uses `(probe_ssl_earliest_cert_expiry - time()) / 86400` against
  the blackbox exporter data already flowing in.

Verified properly, not just "created successfully": confirmed all 6 show `inactive` (correct —
nothing is actually wrong right now) via `/api/prometheus/grafana/api/v1/rules`, then independently
re-ran the raw disk-usage query directly against Prometheus and got real, sane per-host values
(gateway-vps 39%, others 5-6%) — proves the query logic itself is sound, not just that the API
call to create the rule succeeded.

**Grafana admin password saved to Vaultwarden 2026-07-27** as "sn-monitor — Grafana admin", same
"House of Trae — Gateway VPS" folder as the other sn-infra/sn-monitor service creds. Standard
one-off pattern: Mr. Byrne's `bw unlock --raw` session token, vault locked and token/scratchpad
copy discarded immediately after the single write.

**How to apply overall:** sn-monitor is now fully complete with zero open items — stack, fleet
telemetry, alerting, and secrets all live, verified, and saved. Next in the rebuild order per
[[hostkey_server_replacement]] is sn-security (Wazuh) — the last of the 4 VMs.

---

**Update 2026-07-28 — sn-monitor re-rebuilt with LUKS2+Tang encryption** (VM 104, same 14-step
recipe as sn-infra/sn-web, see [[sn_web_luks_pilot_fix]]). Unlike the sn-web pilot, UFW and hostname
were already correctly set from earlier steps in this same session before the verification reboot —
no post-fix needed for those two this time. Unattended Tang auto-unlock confirmed via
`journalctl -u systemd-cryptsetup@sda5_crypt.service` showing `Volume sda5_crypt already active` on
the fresh boot, uptime ~2 min, no manual passphrase entry.

**Full service restore from `/root/pre-rebuild-backups/sn-monitor-2026-07-28/` (secrets +
grafana-data + uptime-kuma-data tars) went cleanly** — no double-nesting bug this time (unlike the
sn-infra secrets tar issue), all three tars extracted directly into place with correct relative
paths. Docker reinstalled fresh, all config files (`prometheus.yml`/`loki.yml`/`blackbox.yml`/
compose files) copied from `hot-config`.

**Two new bugs found and fixed, both host-permission issues on the fresh install (same class as the
original 2026-07-27 build's bug #1, but different paths this time):**
1. Prometheus crash-looped: `open /etc/prometheus/prometheus.yml: permission denied` — the config
   file copied in via `scp` landed root-only. Fixed `chmod 644` on `prometheus.yml`/`loki.yml`/
   `blackbox.yml`.
2. Prometheus and Loki both then crash-looped a second time on their **data** directories
   (`/prometheus` TSDB dir, `/loki/rules`) — same non-root-UID bind-mount ownership gap as the
   original build, freshly reintroduced by the new install. Fixed with `chmod -R 777` (faster than
   chasing exact UIDs 65534/10001 again — matches the existing `chmod 644`-for-non-root-secrets
   philosophy elsewhere in this infra).

**Watchtower's `WATCHTOWER_SMTP_PASSWORD` env var came back unset** — the `.env` file (gitignored,
never in `hot-config`) didn't survive the rebuild since it was never captured in the pre-rebuild
backup tars. Recovered by copying the identical password value already sitting in the **Gateway
VPS's own** `/opt/stacks/watchtower/.env` (the same SMTP password is deliberately reused across all
Watchtower instances fleet-wide per the existing pattern) — no Vaultwarden lookup needed, no new
secret generated. **Lesson: any future VM rebuild should explicitly capture `.env` files (not just
`secrets/` dirs) in the pre-rebuild backup tar, or know to pull the reused value from the Gateway.**

**Uptime Kuma restored data confirmed genuinely empty, not a restore bug:** `kuma.db` has a real
`jwtSecret` (auto-generated on first container boot, unrelated to user setup) but zero rows in
`user`/`monitor`/`heartbeat` — cross-checked against Grafana's own restored `grafana.db` in the same
tar batch, which DOES show real data (1 dashboard folder, 2 real datasources, non-empty `user`
table) proving the restore mechanism itself works correctly. Conclusion: Uptime Kuma's first-run
setup wizard (admin account + monitors) was simply never completed between the 2026-07-27 original
build and the 2026-07-27/28 LUKS pilot destroying it — a genuine gap in that VM's history, not
something lost in this rebuild. Flagged for Mr. Byrne to complete via the browser if he wants
Uptime Kuma actually monitoring anything (currently just an empty, unconfigured instance sitting
behind `status.house-of-trae.com`/`monitor.securenexus.net`).

**Verified externally after restore:** all 8 containers stable (prometheus/grafana/loki/uptime-kuma/
blackbox/promtail/node-exporter/watchtower), Grafana's real dashboards+datasources+admin login
intact, all 4 external URLs (`grafana.house-of-trae.com`, `status.house-of-trae.com`,
`monitor.securenexus.net`) return expected 302s through Caddy, and Prometheus's `/api/v1/targets`
shows every fleet node-exporter (gateway-vps, proxmox-host, sn-infra, sn-web, sn-monitor,
sn-security) plus all 21 Blackbox HTTPS probes reporting `up` — confirms the whole monitoring
pipeline survived the encryption retrofit end-to-end, not just that containers are running.

---

**Update 2026-07-30 — Uptime Kuma gap finally closed.** The "flagged for Mr. Byrne to complete"
note above was still true as of today's fleet-wide monitoring audit — zero users, zero monitors,
`status.house-of-trae.com` 302ing to an unconfigured `/dashboard`. Fully set up this session; full
detail in [[uptime_kuma_setup_2026_07_30]]. Short version: 26 monitors added (6 public group-entity
sites on the `hot-status` public status page, 14 internal services, 6 fleet node-exporter TCP
checks), admin account created, `entryPage` setting wired so the root domain serves the status page
directly. All 26 confirmed healthy after fixing one real bug (Grafana/Webmail's SSO redirect chains
were being followed all the way into a cookie-less 400, not stopped at the app's own healthy 302).
