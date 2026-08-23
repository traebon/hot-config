### hot-pn (ssh hot-pn — 151.241.217.140, Hostkey CH, public VPS, not a Proxmox VM) — PERMANENT
**Renamed from pn-vps 2026-07-24** (the `pn-vps` ssh alias still works, kept as a transitional
alias — see hostkey_server_replacement memory). Stood up 2026-07-15 as a stand-in for PrivateNexus's dev (pn-test) and test (sn-personal) roles
combined while bare metal is down (see [[hostkey_server_replacement]]). **Made PrivateNexus's
permanent home 2026-07-24** (Mr. Byrne decision) rather than migrated back once hot-bm-nl is
ready — deliberately kept off bare metal so a future Proxmox/bare-metal outage doesn't take
PrivateNexus down with it, same reasoning as the Vaultwarden Gateway placement. PrivateNexus here
serves both Mr. Byrne's personal use and ongoing PrivateNexus product development. Ordered via the Hostkey
`invapi.hostkey.com` billing API — see [[hostkey_invapi_notes]] for the auth/order quirks
discovered along the way. `vm.v2-medium` preset — 8 vCPU / 16 GB RAM / 160 GB NVMe, Ubuntu 26.04
LTS (upgraded from the 24.04 base image via a Hostkey panel reinstall — neither `do-release-upgrade`
nor the invapi API could drive this server, a real gap: `eq/list`/`eq/show` never recognized this
server's ID (4683) under this account's API key, even after payment and provisioning completed).
Reached from the Gateway VPS over the dedicated `wg3` tunnel (10.10.2.1 ↔ 10.10.2.2) — see Network
Topology. UFW locked down (deny-by-default; app ports and SSH scoped to 10.10.2.1 — see the SSH
hardening note below for why "SSH scoped" wasn't actually true until 2026-08-18). Claude Code
(native install) is also set up on this box for direct use there.

**⚠ SSH hardening, 2026-08-18 — closed a real oversight, not a deliberate design choice.**
`22/tcp` had been open to `Anywhere` (IPv4 and IPv6) since this box's original 2026-07-15 standup —
a plain default `ufw allow ssh` rule, never revisited when the rest of the fleet's admin-access
pattern (tunnel/Tailscale-only SSH) was established. Confirmed live before fixing: `PermitRootLogin
yes`, no fail2ban/CrowdSec running locally, and **83,020 failed/invalid-user SSH attempts in the
prior 7 days** — a real, actively-exploited, unmitigated exposure, not theoretical. Found while
investigating the SSH-asymmetry side-finding in `docs/HoT_Edge_Load_Balancing_Scope.md` (hot-pn
open vs. hot-erp-nl correctly scoped to its wg5 peer). The dedicated Termius SSH key
(`tristian-termius-pn-vps`, below) offered a plausible-after-the-fact justification for public
access, but was never documented as a deliberate trade-off the way genuine trade-offs elsewhere in
this project always are (Vaultwarden's Gateway placement, sn-security's cores=2 cap) — its absence
was itself a signal this was a gap, not a decision.

**Fixed**: installed Tailscale on hot-pn (`100.121.175.15` — see CLAUDE.md Quick Reference; this
box had never had Tailscale at all, unlike the rest of the fleet, which is likely *why* direct
public SSH existed in the first place — no admin-only overlay path was available here). Added UFW
rules scoping `22/tcp` to `10.10.2.1` (wg3 peer, matches hot-erp-nl exactly) and to
`100.64.0.0/10` (Tailscale CGNAT range, preserves Mr. Byrne's direct Termius access). Verified both
new paths work via a real SSH connection through each before removing anything, then deleted the
`Anywhere`/`Anywhere (v6)` rules and re-verified: tunnel and Tailscale SSH still work, direct public
IP (`151.241.217.140:22`) now times out. Gateway's own `hot-pn`/`pn-vps` SSH alias
(`/root/.ssh/config`) updated to use the wg3 tunnel IP (`10.10.2.2`) instead of the public IP, same
as hot-bm-nl/hot-erp-nl. See `hot_pn_ssh_hardening_2026_08_18` memory for the full trace.

**Catalogue deploy flow, Phase 1 — built 2026-08-10** (see `docs/PrivateNexus_Catalogue_Deploy_Flow_Scope.md`
for the full scope this implements). New: `GET/POST /api/catalogue/:id/deploy-form|preview` in
`routes/catalogue.js`, a `service.provision_from_catalogue` action type + executor in
`routes/actions.js` (reuses the existing `action_requests` governance queue — propose → review
real generated compose in the UI → admin approve → real deploy on this host → auto-registered in
`services`, no Discovery round-trip needed). Nextcloud is the first real templated app
(`catalogue/templates/nextcloud/docker-compose.yml.tmpl`, Postgres + Redis) — template and the
original approved/executed deploy (2026-08-10 01:21 UTC, `action_requests` row `78f8f3f2`) both
bind to `127.0.0.1` only, DNS/Caddy deliberately not auto-wired (Option A from the scope doc —
generate-not-apply, revisit later). **This is no longer what's actually running — see the
2026-08-20 binding correction below.**

**Real architecture bug found+fixed the same day, once actually exercised end-to-end**: the
original executor shelled out to `docker compose up -d`, which could never have worked —
`privatenexus-backend` has no `docker` CLI, no host socket, and (until fixed) no `/opt/stacks`
mount; it only reaches Docker via `privatenexus-docker-proxy` (`NETWORKS: 0` — network create/list
deliberately blocked). Fixed with a real 3-part change: `/opt/stacks` bind-mounted into the backend
(host dir `chown root:1000`/`775` for the container's real UID/GID); one shared Docker network
(`pn-catalogue-deployments`) pre-created once via direct host access, outside the restricted proxy;
executor rewritten to parse the rendered compose YAML (added the `yaml` npm dependency) and drive
`dockerode` directly (`createContainer`+`start` per service, `NetworkMode` set to the shared
network). Verified live via a real dockerode probe through the actual proxy connection before
trusting it — `NETWORKS: 0` turns out to only block create/list, not *attaching* to an
already-existing network at container-creation time. Full detail, including the read-only-`/app`
gotcha hit while writing the verification probe itself, in
`pn_catalogue_deploy_flow_phase1_build_2026_08_10` memory.

Both containers rebuilt multiple times this session (image-baked, not bind-mounted — edits need a
real `docker compose build`, not just a restart/`up -d`); frontend also gained real error-surfacing
on the Approve/Reject buttons (previously failed silently) and a self-approval relaxation for
single-operator tenants (`tristian` is the only account here — dual-control can't be satisfied by
exactly one person; now auto-relaxes when no other proposer/reviewer exists on record, with a
distinct audit entry, and re-tightens the moment a second real person acts). Also caught a real
naming collision before shipping (`deployError`/`showDeployModal` already existed for the unrelated
image-redeploy feature — renamed all new state to a `catalogueDeploy*` prefix).

**End-to-end confirmed working, 2026-08-10.** Real deploy through the actual UI succeeded — 3
containers (Nextcloud + Postgres + Redis), auto-registered, real `status.php` check green. One more
bug found+fixed along the way: the Redis template's `$$(cat ...)` (correct for Docker Compose's own
variable-escaping) needed to be a single `$` now that there's no Compose layer left to unescape it —
found via `docker inspect` showing the literal unresolved `$$` in the real container `Cmd`, not
assumed. Fixed the template, rebuilt the backend, and fixed the already-running Redis container
directly (stateless, safe to recreate) since it predated the fix. Verified fully: real `PONG` with
the real secret, and `config.php` inside the container confirmed to hold the matching real password.
See `pn_catalogue_deploy_flow_phase1_build_2026_08_10` memory for the full trace.

**Phase 2 (Notesnook) built same day.** A real 5+-service stack (Mongo, MinIO + a one-shot bucket-
setup container, identity/sync/SSE/monograph servers) — adapted from HoT's own previously-working
self-hosted Notesnook compose file (still sitting in `hot-config` git history from the old pn-test
VM, `pn-test/notesnook/docker-compose.yml`), not guessed. Required real executor upgrades Nextcloud
never exercised: health-check-gated startup ordering and one-shot init-container support (`routes/
actions.js` — `waitForHealthy`/`waitForExit`, translates compose `depends_on` conditions and
`healthcheck:` blocks into real dockerode polling). Also added a `static_secret_files` concept to
the preview route (`routes/catalogue.js`) for reusing a real existing credential — Notesnook's
identity server needs working SMTP, wired to HoT's real shared relay password (same one Grafana
already uses) via a file reference rather than embedding the plaintext value in this app's
git-tracked `default-repo.json`. Verified the new mechanics with real isolated dockerode probes
before considering it done (the actual Mongo healthcheck-as-init trick genuinely reaches `healthy`
in ~6s; one-shot exit-code detection confirmed).

**Confirmed working end-to-end, 2026-08-10, after 4 real bugs found+fixed via live deploy
attempts** (isolated probes hadn't caught any of these): (1) Mongo's string-form `command:` broke
the raw Docker API's array-only `Cmd` field — added a `cmdArrayFor()` helper in `routes/actions.js`;
(2) the 3 ASP.NET-based images (identity/sync/sse) all bake in `ASPNETCORE_HTTP_PORTS=8080` as an
image default, silently overriding the 8264/5264/7264 ports the template assumes — fixed with an
explicit per-service override; (3) the real deeper cause once (2) alone didn't fix it: the `yaml`
npm package does **not** expand `<<: *anchor` merge keys by default — without `{ merge: true }`,
`<<` parses as a literal string key, silently dropping every real `server-discovery` env var
(including the port var these images likely read to pick their own Kestrel bind port) across all 4
services using the anchor. Fixed via `parseYaml(generated_compose, { merge: true })` in
`routes/actions.js` — **this is a generic executor bug, not Notesnook-specific**, any future
template using YAML anchors would have hit it too; (4) `notesnook-monograph` (Bun-based, no
wget/curl, dev server binds only `::1` not `127.0.0.1`) needed a `bun -e 'fetch(...)'`-based
healthcheck against `[::1]` explicitly instead of the wget+`localhost` pattern that worked fine for
the other 3 .NET services. All 7 containers now up (6 healthy, `s3-setup` exited 0 as designed),
service auto-registered. **5th bug found+fixed same day**: Caddy's default proxy timeout was
killing the client-facing HTTP response before a deploy this long finished server-side (backend
kept processing correctly regardless, confirmed via direct polling) — fixed via a scoped `/api/*`
`response_header_timeout 10m` in the Gateway's Caddyfile (see the Gateway VPS Caddy row below for
the exact change), verified with a real throwaway deploy through the public URL (clean `200` in
30s, no `504`), then fully torn down. See `pn_catalogue_deploy_flow_phase2_notesnook_2026_08_10`
memory for the full trace. Ready for Mr. Byrne to try through the real UI.

**⚠ `nextcloud`'s real binding diverged from its approval — found+reconciled 2026-08-20.** The
governance record (`action_requests` row `78f8f3f2`, executed 2026-08-10 01:21 UTC) shows Mr.
Byrne approved and the executor deployed `127.0.0.1:28142` only, matching the template and the
Phase 1 scope's "not publicly wired" design. But the live container was **recreated 2026-08-11
03:27 UTC — about a day later — rebound to `10.10.2.2:28142`** (the wg3 tunnel IP), with the
on-disk `docker-compose.yml` rewritten to match at the same moment. No second `action_requests`
row exists for this change, and no origin could be traced (no shell history on hot-pn, no local
Claude Code project directory there) — it went through no governance step at all, and sat
undocumented until the 2026-08-19 health-endpoint session found the binding already in place and
wrote a comment treating it as pre-existing convention rather than flagging the mismatch. **Real
current exposure, confirmed live 2026-08-20**: reachable at `http://10.10.2.2:28142/status.php`
from the Gateway (`200`), NOT reachable via the public IP (connection refused) — tunnel-scoped,
not internet-facing. **Resolved, Mr. Byrne's call**: formalize the `10.10.2.2` binding rather than
revert it, since PN's own health check for this service (`health_endpoint =
http://10.10.2.2:28142/status.php`, wired 2026-08-19) now depends on it and reverting would break
that check again. Vaultwarden's "hot-pn Nextcloud" entry corrected to match. **Any future
Catalogue-deployed stack's live container should be spot-checked against its own approved
`generated_compose`** — this is the first confirmed case of the two silently diverging, and
nothing in the deploy flow itself would catch a drift like this.

**`nextcloud-personal` — resolved 2026-08-20, removed.** A second, previously undocumented
Nextcloud stack (`/opt/stacks/nextcloud-personal`, containers `nextcloud-personal`/
`nextcloud-personal-db`) was found registered in PN's `services` table (created 2026-08-09 22:55,
~2.5h before the first Catalogue deploy attempt — predates the real Catalogue Nextcloud). Checked
real usage before deciding: it held only 63MB of Nextcloud's stock first-run demo content
(Templates/Photos/Documents sample files), zero real uploads, an empty log file, and
`occ files:scan` reported 0 new/updated — genuinely never used, evidently a manual scratch/
prototype stack from just before the Catalogue flow went live, abandoned the moment the real one
(12GB of real data as of 2026-08-20) came online the same day. Removed with Mr. Byrne's
confirmation: both containers stopped+removed, `/opt/stacks/nextcloud-personal/` deleted, its
orphaned `nextcloud-personal_nextcloud-internal` Docker network removed, both `services` table rows
deleted. Closes out the last of the 3 unresolved rows from `pn_health_endpoint_gap_2026_08_19`
memory (the other two — Caddy Admin API's pre-existing exemption, and hot-pn's own infra-row health
check — remain open, no natural container endpoint for either).

| Service      | Path               | Notes                                                                 |
|--------------|--------------------|-----------------------------------------------------------------------|
| PrivateNexus | /opt/privatenexus/ | privatenexus.net (Caddy repointed here) — full stack built and deployed from `origin/main`. Reuses the existing Keycloak `privatenexus` client secret unchanged. **`PROXMOX_URL` corrected 2026-08-09/10** (now points at hot-bm-nl, `10.10.3.2:8006`, real connectivity confirmed) — the original "won't work until bare metal is reachable" note is stale, bare metal has been reachable for weeks. **`PROXMOX_TOKEN` is still a literal placeholder** (`unavailable-proxmox-behind-dead-baremetal`, checked live 2026-08-10) — a real Proxmox API token needs generating on hot-bm-nl before this specific governance-API integration actually works; not done, not attempted without checking first. `PDNS_API_KEY` is live and working (PowerDNS reachability fixed 2026-07-15 — Gateway UFW rule, wg0 AllowedIPs widened to `10.10.2.1/32, 10.10.0.1/32`, and a manual route add after `wg syncconf`, which doesn't install kernel routes on its own — see Operational Rules). |
| Monitoring (temp) | /opt/stacks/monitoring-temp/ | Local Prometheus + node-exporter + Loki + Promtail stand-in (added 2026-07-15), `compose_pn-internal` only, no host ports published. Loki `/ready` returns a cosmetic 503 (known single-node quirk, still ingests correctly) — don't "fix" this into a broken HTTP health check. Permanent now that pn-vps is PrivateNexus's home. **Real stale-target bug found+fixed 2026-08-09**: `pn-prometheus`'s own scrape config had a hardcoded target for the decommissioned old Hostinger ERP box (`10.10.1.2:9100`, the dead `wg2` tunnel IP, torn down 2026-08-03) still labeled `instance: erp-temp` — reported `down` continuously for 6 days, and PN's own live "Alert Monitor" UI feature (polls this Prometheus directly, not PN's own DB) correctly surfaced it as a permanent "Node down" banner the whole time. This was the real answer to a user-reported alert that took most of a session to trace past two unrelated bugs found along the way. Fixed by removing the target + purging the stale series (`--web.enable-admin-api` enabled temporarily, `delete_series`, then disabled again) — see `pn_erp_temp_stale_target_2026_08_09` memory. **Separately, PN's `.env` had 3 vars marked "TEMPORARY (2026-07-15) ... revert once bare metal is back"** that were never reverted despite hot-bm-nl being back since 2026-07-27 — **all 3 fixed 2026-08-09/10**: `PROMETHEUS_URL` → sn-monitor's real central Prometheus `10.10.50.104:9090` (new `wg3` AllowedIPs + Gateway forward rule + sn-monitor UFW rule, port 9090 — powers PN's home-page "Fleet" VM-tiles widget, previously only ever showed `pn-vps`); `LOKI_URL` → `10.10.50.104:3100` (same connectivity pattern, port 3100, verified via the real `/loki/api/v1/labels` endpoint since `/ready` always cosmetically 503s per the note above); `PROXMOX_URL` → `10.10.3.2:8006` (hot-bm-nl, correcting the dead `10.10.0.2` — connectivity already existed from the same week's services-table Proxmox health-check fix, just a value change). The stale "TEMPORARY" comment block in `.env` was also rewritten to reflect current state. See `pn_erp_temp_stale_target_2026_08_09` memory. |
| Watchtower | /opt/stacks/watchtower/ | Pinned v1.5.3, monitor-only. PrivateNexus's 3 locally-built services carry `com.centurylinklabs.watchtower.enable=false` (no registry to check). Has a real bearer-token-gated metrics health check (`WATCHTOWER_HTTP_API_METRICS=true`, deliberately not `_UPDATE`) — `services.health_endpoint` uses `tcp://watchtower:8080` since the schema can't carry the token for an HTTP check. Token in Vaultwarden ("pn-vps Watchtower HTTP API token"). |
| Discovery agent | /opt/privatenexus/scripts/discovery-agent.sh | `privatenexus-discovery-agent.timer` (systemd, hourly) pushes host + container facts to `POST /api/discovery/ingest`, authenticating with a real rotated DB token (`agent_tokens`, `600`-permission secret file) — not the bootstrap fallback. **Found+fixed 2026-08-16**: the script had lost its execute bit (`-rw-r--r--`, cause unknown) at some point, silently failing every hourly run with `Permission denied` — found during a full fleet health check, `chmod +x`'d and verified with a real successful run (exit 0). **Timer fixed 2026-08-19**: was `OnBootSec`+`OnUnitActiveSec` only (no `OnCalendar`) — same silent-wedge-after-reboot bug class found and fixed twice on the Gateway the same day (see `gateway_timer_wedge_bug_2026_08_19` memory) — not yet actually wedged here, fixed proactively. Now `OnCalendar=*:15`. **The `discovery_candidates` dedup index was also fixed the same day** (`(tenant_id, source, raw_name)` → `(tenant_id, source, host, raw_name)`, `routes/discovery.js`'s `upsertCandidate()`) — needed once the Gateway's new `fleet-discovery-push` (below) started pushing candidates for other hosts too; without `host` in the key, generic container names (`watchtower`, `promtail`, `node-exporter`) reused across most of the fleet would silently overwrite each other's candidate row. Doesn't change this agent's own behavior (it only ever pushed for `hot-pn` itself, no collision risk existed before). |
| fleet-discovery-push (Gateway) | `/opt/hot-config/gateway/fleet-discovery-push/` | **Added 2026-08-19** — Option B2 of `docs/HoT_Automation_Self_Healing_Scope.md` Section 6. Runs on the Gateway (`fleet-discovery-push.timer`, hourly at `:45`, offset from this agent's own `:15`), pushes Discovery candidates for every fleet host *except* hot-pn (which already covers itself, above) by reusing the Gateway's existing SSH reach rather than giving each VLAN-internal host a new outbound path (Option B1, not chosen). Uses its own dedicated `agent_tokens` row (label "gateway fleet-discovery-push"). Deliberately pushes every docker-sourced candidate as `suggested_runtime: "external"`, never `"docker"` — PN's approve handler sets `services.container_name = raw_name` only when `runtime === "docker"`, on the assumption that means a container PN's own Docker proxy can reach, which is false for every host this pusher covers (and hot-pn already runs its own container literally named `watchtower` too — an unqualified `"docker"` runtime risked PN's automation acting on the wrong physical container on the wrong host). `suggested_slug` is host-qualified (`sn-web-watchtower`) for the same reason. Verified live: 69 candidates across 7 hosts, zero errors, zero cross-host collisions. See `option_b_discovery_scope_2026_08_19` memory. |
| Proxmox health check | (PN's `services` table, monitored-service row named "Proxmox") | **Fixed 2026-08-09** — had pointed at `tcp://10.10.0.2:8006`, the decommissioned original bare-metal host's address (dead since 2026-07-24), for 19 days straight with zero alerting on the mismatch itself, only a permanently-stuck `down_spike` signal + orphaned `pending` remediation proposal. Repointed to `tcp://10.10.3.2:8006` (hot-bm-nl) with real connectivity: scoped UFW on hot-bm-nl (`10.10.2.2` → port 8006 only), hot-pn's `wg3` `AllowedIPs` widened to add `10.10.3.2/32` (+ manual `ip route add`, `syncconf` doesn't install routes), a matching Gateway `wg3→wg4` forward rule — same pattern as the sn-security/Wazuh fix above. Verified live: service flipped to `healthy` on the next 2-min scheduler cycle, the stuck signal self-resolved automatically. **Separate PN-code-level bug found and left in place on purpose**: the orphaned remediation proposal did not auto-dismiss when its signal resolved — see `pn_proxmox_health_endpoint_fix_2026_08_09` memory. Note this is unrelated to the `PROXMOX_URL`/`PROXMOX_TOKEN` note above (a different governance-API integration, not re-verified during this fix — worth rechecking separately now that hot-bm-nl is reachable, since that note may itself be stale). |

**Current governance state (as of the 2026-07-16/24 audit sessions):** all 15 registered services
(the original 11 pn-vps containers + 4 mapped external dependencies — Keycloak, PowerDNS API, Caddy
Admin API, Proxmox) sit at **0 governance violations**, all 11 pn-vps-native services at
**`recoverable` tier, avg readiness 94/100**, with real (not fabricated) backups, dependency edges,
and restore tests behind every one of those numbers. `privatenexus-db` has a genuine daily pg_dump
chain (pn-vps → Gateway pull → hetzner-crypt/b2-hot-crypt) verified via a real scratch-container
restore test; the 10 stateless containers are backed by their tracked git config (real, verified
GitHub commit URLs — Codeberg mirrors are NOT reliably checkable, don't assume otherwise). Caddy Admin
API and Proxmox correctly show as unreachable/exempted for real, documented reasons (`admin off` in
the Caddyfile; the CS-471548 bare-metal outage), not bugs.

**Recurring bug pattern worth remembering for future audits of this app:** whenever a rule has an
exception mechanism (`policy_exceptions`), every UI surface displaying that rule's data must
independently consult the exception table — this was missed in three separate places in one session
(Inventory badges, Service Detail, and even a secondary table *inside* the Governance board itself),
because only the one route computing violations was checking it. Also worth remembering: two
separate large-scale audits this app went through (`recordAudit()` coverage, and `try/catch`
coverage — the latter found a real all-request-crash risk in `discovery.js`'s automated hourly
ingest path) each found gaps by literally counting route-handler occurrences against
audit/error-handling call counts per file, then reading only the mismatches. **Full blow-by-blow
audit history (every bug found/fixed, commit hashes, verification steps) for 2026-07-15, -16, and
-24 sessions:** `/root/hot/docs/PrivateNexus_pn_vps_Audit_Log_Archive.md`.

Caddy's `privatenexus.net` block points at `10.10.2.2:5173` — this is now the permanent target,
not `10.10.40.103:5173` (see the pn-vps PERMANENT decision above, 2026-07-24); the inline Caddyfile
comment was updated 2026-08-02 to say so directly (was previously stale "TEMPORARY... revert"
language left over from the original bare-metal-outage stand-in). The frontend container's port publish was changed from `127.0.0.1:5173:80` (in the source
repo, unreachable from another host) to `10.10.2.2:5173:80` (bound to the tunnel interface
specifically) — binding to `0.0.0.0` was deliberately avoided since Docker's own iptables rules are
known to bypass UFW's filtering for published ports; binding to the specific tunnel IP means
Docker's NAT rule itself never matches traffic to the public IP, which is more robust than relying
on UFW alone.

Root password and the wg3 keypair are saved in Vaultwarden under the **PrivateNexus** folder
("hot-pn root password (Hostkey CH VPS)" and "hot-pn wg3 WireGuard tunnel keys" — renamed from the
`pn-vps` prefix 2026-07-24). A separate SSH keypair (`tristian-termius-pn-vps`, alias not renamed)
was also generated for Mr. Byrne's direct Termius access, scoped only to this VPS (not the shared
fleet `claude_code_key`) — its private key is backed up in the same Vaultwarden folder ("hot-pn
Termius SSH key (tristian)").

**⚠ Real production regression caused and fixed same-session, 2026-07-24: PowerDNS API went
unreachable from the whole VLAN mesh after `wg0` (the old, permanently-dead bare-metal tunnel) was
torn down during the hot-bm-nl vmbr0 build (see hostkey_server_replacement memory).** PowerDNS's
docker-compose port binding is a specific-IP bind, `10.10.0.1:8081` (not `0.0.0.0`) — and
`10.10.0.1` was literally the Gateway's own address *on the wg0 interface itself*. Deleting wg0
deleted that address from existence; `docker-proxy` kept reporting itself as `LISTEN` on it
(phantom bind — process alive, but nothing could route to an address that no longer exists on any
interface). Caught only because Mr. Byrne was doing real hands-on UI testing and saw PowerDNS API
show as down on the Dashboard. Fixed non-destructively: added `10.10.0.1/32` to `lo` (loopback) via
a new systemd oneshot unit (`/etc/systemd/system/powerdns-loopback-ip.service`, `Before=docker.service`,
enabled) rather than reviving wg0 or changing PowerDNS's bind config. Verified end-to-end
(Gateway-local curl, then from hot-pn over wg3). **If `10.10.0.1` ever needs to move again, it's now
a plain loopback alias, not tied to any WireGuard interface's lifecycle — check `ip addr show dev
lo` before assuming it's gone.**

---

