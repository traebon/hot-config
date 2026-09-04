## Service Locations

All services use plain Docker Compose at /opt/stacks/<service>/
All VMs run as root.

### Gateway VPS (this machine — 151.241.217.91)
| Service           | Path                    | Notes                                                 |
|-------------------|-------------------------|-------------------------------------------------------|
| Caddy             | /opt/stacks/caddy/      | Caddyfile here — reload: docker compose restart caddy |
| PowerDNS          | /opt/stacks/powerdns/   | compose.yml (not docker-compose.yml)                  |
| Unbound           | /opt/stacks/unbound/    | Recursive resolver                                    |
| Keycloak          | /opt/stacks/keycloak/   | auth.house-of-trae.com                                |
| Docker Mailserver | /opt/stacks/mailserver/ | mail.house-of-trae.com                                |
| Roundcube         | /opt/stacks/roundcube/  | webmail.house-of-trae.com                             |
| CrowdSec          | /opt/stacks/crowdsec/   | LAPI mode + Caddy native bouncer module (caddy-cs-bouncer) |
| Tor               | /opt/stacks/tor/        | v3 hidden service for erp.dickson-supplies.com        |
| Tang              | systemd (tangd.socket)  | NBDE unlock for ALL 7 VMs — 10.10.0.1:7500 (WireGuard only, NOT Docker) |
| Vaultwarden       | /opt/stacks/vaultwarden/ | vault.house-of-trae.com — deliberately on the Gateway VPS, not a VM, so secrets stay reachable if bare metal goes down. `ADMIN_TOKEN_FILE` docker secret (pre-hashed argon2id PHC string, not plaintext). |
| Ntfy              | /opt/stacks/ntfy/       | ntfy.house-of-trae.com — moved here 2026-08-03 from sn-infra (was a single point of failure with the exact fleet it's meant to alert about being down — see Network Topology/sn-infra section). Reuses the container that's been running on the Gateway since 2026-07-02 (Ntfy's original deployment, never actually torn down after an earlier documented "move" to sn-infra) — CrowdSec's alert plugin had been quietly using it the whole time regardless of what Caddy's public vhost pointed at. The SMS relay (Node.js sms-relay — see Alerting Architecture and the Gateway VPS service table below) was rebuilt on the Gateway itself 2026-08-03/04, closing out the single-point-of-failure concern that used to apply when it lived on sn-infra. |
| Gatus             | /opt/stacks/gatus/      | Independent uptime monitor, port 8080 (internal only, no public vhost). Deliberately on the Gateway, not sn-monitor — sn-monitor (Grafana/Prometheus/Uptime Kuma) lives on hot-bm-nl, so it can't alert on its own host's death; Gatus exists specifically to catch that blind spot. **21 endpoints as of 2026-08-17** (was 12) — widened while scoping the edge load-balancing project (`docs/HoT_Edge_Load_Balancing_Scope.md`): found that despite Gatus's whole purpose being independent-of-hot-bm-nl coverage, it only had 1 check per VM (ERPNext/Forgejo/Grafana/Wazuh) and zero coverage of sn-web's 6 client sites or sn-infra's PowerDNS-Admin/Namevault — all of which had *only* an Uptime Kuma monitor, which is itself hosted on sn-monitor and therefore dies with the same host outage it's supposed to catch. Added PowerDNS-Admin, Namevault, Prometheus, and all 6 sn-web client sites (Stratus Digital/Discreet Elite/Emerald Markets/Ruby Osiris/Evil Rabbit Art/Dickson Supplies), all verified live via real curl checks before writing conditions, not guessed. **Real bug hit adding the Prometheus check**: it's SSO-gated (`import sso`), and Gatus's Go HTTP client follows redirects into the stateless oauth2-proxy/Keycloak dance by default, which 400s without real browser cookies — condition permanently false-failed against a genuinely healthy endpoint until `client.ignore-redirect: true` was added (found by testing several wrong field-name guesses, not from docs — WebFetch/raw.githubusercontent.com were both 429-rate-limited at the time). Alerts via email only (`notifications@house-of-trae.com`) — deliberately not Ntfy/SMS: true at the time this was built (both lived on sn-infra, part of the same failure domain), and still true for SMS (its relay is still on sn-infra), but Ntfy itself moved to the Gateway later the same day (see the sn-infra section above) — email remains the right choice here regardless, since it doesn't depend on Ntfy either. Was undocumented here for 9+ days until found+fixed 2026-08-03 (see gatus_alerting_gap memory) — had been correctly detecting the hot-bm-nl outage the whole time but had zero alerting providers configured, which is why nobody was told. Password secret lives only at `/opt/stacks/gatus/secrets/gatus.env` (`chmod 600`), never in the git-tracked `hot-config` copy. Its Grafana check was separately broken (checking the wrong path, root redirects rather than 200) — found+fixed during the same-day outage recovery, see the hot_bm_nl_outage memory. **A second, unrelated Grafana-check bug found+fixed 2026-08-08**: the `[BODY].database == "ok"` JSON-path condition had been silently failing on every check but the very first one after a restart (1497 consecutive false results over 5 days) despite the real endpoint always returning correct content — replaced with a `pat()` raw-body pattern match, confirmed holding across 3+ consecutive check cycles post-fix. See `gatus_grafana_check_bug_2026_08_08` memory. |
| sn-infra recovery watchdog | systemd (`sn-infra-recovery-check.timer`) | Not a container — a local systemd timer + script (`/usr/local/bin/sn-infra-recovery-check.sh`, tracked in `hot-config/gateway/scripts/`), added 2026-08-03 during the hot-bm-nl outage. Checks every 15 min whether sn-infra is reachable (fresh wg4 handshake + real SSH), emails a one-time notification via the same SMTP path as Gatus when it detects a down→up transition. Deliberately local, not a `/schedule` cloud agent — cloud sandboxes have no access to wg4/SSH/Tailscale. Served its purpose once already (2026-08-03 recovery); harmless to leave running for any future recurrence. See gatus_alerting_gap and hot_bm_nl_outage memories. **⚠ Found dead 2026-08-19**: its timer (`OnBootSec`+`OnUnitActiveSec` only, no `OnCalendar`) silently wedged and hadn't fired in 6 days — `systemctl` reported it `enabled`/`active` the whole time with no error state. Same bug, same fix, same day as `reboot-recovery-watchdog.timer` (see `automated-patching.md`'s reboot-recovery-watchdog section, including a same-day correction to which reboot actually triggered it — caught by the first real `fleet-judgment-review` run) — switched to `OnCalendar=*:0/15`. See `gateway_timer_wedge_bug_2026_08_19` memory. |
| fleet-health-sweep | systemd (`fleet-health-sweep.timer`) | Not a container — nightly (07:45, `hot-config/gateway/fleet-health-sweep/`) systemd timer + script sweeping every host (gateway, hot-bm-nl, sn-infra/web/monitor/security, hot-pn, hot-erp-nl) for `systemctl --failed`, `dpkg --audit`, wazuh-agent process-vs-systemd-state liveness, `/opt/stacks` inventory drift, and `ufw` rule drift. Built 2026-08-19 — first slice of `docs/HoT_Automation_Self_Healing_Scope.md` (Option A+C), replacing what had been an irregular manual "fleet health check" session (weeks apart, see `fleet_health_checks` memory) with a real recurring job. Point checks (systemd/dpkg/wazuh) persist a per-host/per-check streak and escalate Ntfy `priority=high`→`urgent`/SMS after 3 consecutive failing nights — directly closes the "alert fired but nobody looked" gap (the `grub-pc` incident: 4 identical unescalated alerts, ignored). Drift checks (stacks/ufw) are one-shot snapshot diffs at `priority=default`, no escalation. First live run found one real but benign issue (hot-bm-nl's masked `openipmi.service` had a 2-week-old stale failed-record — no real IPMI hardware on this virtualized host — cleared via `reset-failed`); second run came back fully clean. Deliberately a local systemd timer, not a cloud-scheduled routine — same wg4/SSH/Tailscale-reachability constraint as the sn-infra recovery watchdog above. **Its own timer was built with `OnCalendar` from the start** — see the note below on the `reboot-recovery-watchdog`/`sn-infra-recovery-check` timer bug found the same day. **`catalogue-binding-drift` check added 2026-08-20** (hot-pn only): the `stacks-inventory` check above only diffs directory *names* under `/opt/stacks/` — it never caught hot-pn's `nextcloud` container being silently rebound from its governance-approved `127.0.0.1:28142` to `10.10.2.2:28142` (found while tracing an unrelated Nextcloud password request; the directory itself never changed, only the live container's port binding did). New check compares each Catalogue-deployed stack's live `docker inspect` port bindings against its approved `action_requests.params.generated_compose` via `/usr/local/bin/catalogue-drift-check.py` on hot-pn (tracked in `hot-config/hot-pn/catalogue-drift-check/`), filtered against a git-tracked exceptions file (`catalogue-drift-exceptions.conf`, same directory as the sweep script — only entries Mr. Byrne has explicitly decided to formalize). Deliberately a streak-based `report_check`, not a one-shot `report_drift` like `stacks-inventory`/`ufw-rules` — those two correctly auto-accept a new state as the next baseline, but doing that here would silently bless an undocumented governance bypass forever. Full design + the "does formalizing need a fresh `action_requests` row" question (resolved — no, the exceptions file is enough) in `docs/HoT_Automation_Self_Healing_Scope.md` Section 8. **First real run found a second drift, resolved same day** — `nextcloud` correctly cleared (excepted); `notesnook` had 4 real mismatches (`notesnook-s3`/`notesnook-identity`/`notesnook-sse` approved as internal-only but live-published to `10.10.2.2`, plus `notesnook-sync`'s host port itself drifted). **Real mistake made and fixed investigating it**: initially assessed 3 of the 4 as having "no known consumer" (checked only PN's `services.health_endpoint`, which references `notesnook-identity` alone) and reverted those three per that read — wrong. Caddy's live Caddyfile has real public site blocks (`notes-sync`/`notes-sse`/`notes-s3.house-of-trae.com`) reverse-proxying directly to those exact bindings, wired the same day (2026-08-11) as the container recreate — genuine production wiring, just never reflected in governance or docs. The revert caused a real ~2-5 minute outage (`502`s) on those 3 public endpoints, caught via a direct check against the live URLs and fixed immediately by recreating all 3 back to their prior state. All 4 formalized together after that correction. **Separately, verifying the fix also caused a real false `priority=urgent` alert (SMS-triggering)** for `fleet-judgment-review.service` — its underlying bug had already been fixed and verified 18h earlier, but the systemd unit's own `failed` state was never cleared (`systemctl reset-failed` never run), so re-running the sweep script manually twice during this investigation counted as 2 additional "failing nights" against a real streak of 1, crossing the escalation threshold on a stale, already-resolved issue. Fixed via `systemctl reset-failed` + a clean re-run, which correctly fired a `RECOVERED` notice. See `pn_nextcloud_binding_and_personal_cleanup_2026_08_20` memory for the full trace of both incidents. **Fleet-wide version scoped 2026-08-20, built 2026-08-25**: `docs/HoT_Automation_Self_Healing_Scope.md` Section 9 extends the same principle to every host's plain `docker compose`-deployed stacks (live container config vs. the `docker-compose.yml`/`compose.yml`/`compose.yaml` sitting next to it) — real facts checked first, not guessed: 3 filename conventions in live use, 2 Gateway stack dirs aren't Docker at all, and `wazuh` on sn-security declares zero `container_name:` across all 3 of its services, meaning a container-name-keyed parser (what works for hot-pn) would have zero coverage there without a naming fallback. Deliberately scoped as one-shot `report_drift`, not streak-based `report_check` like the hot-pn version — no formal approval flow exists for the general fleet's compose files, so a mismatch is ordinary drift, not a governance bypass. **The naming-resolution piece**: `/usr/local/bin/compose-service-names.py` (deployed to all 7 `STACK_HOSTS`, tracked in `hot-config/gateway/fleet-health-sweep/compose-service-names/`) resolves every service in a stack to its real live container name via Docker's own `com.docker.compose.project`/`.service` labels — ground truth, no naming-algorithm guesswork. **The comparison logic**: `/usr/local/bin/compose-drift-check.py` (deployed to all 7 `STACK_HOSTS`, tracked in `hot-config/gateway/fleet-health-sweep/`) diffs each resolved container's declared `ports:` against its real `docker inspect` `PortBindings`, wired into `fleet-health-sweep.sh` as a `compose-vs-live-drift` block on every `STACK_HOST`. **Two real parsing bugs in `compose-service-names.py` found+fixed while testing this against the actual fleet, not just the motivating Wazuh case**: its port regex originally matched only quoted strings, missing Wazuh's own bare-form `- 443:5601` entirely (the exact stack this check exists to cover); fixing that surfaced a second false positive on caddy/mailserver/unbound/pdns-admin, all of which annotate port lines with trailing inline comments (`# HTTP/3 QUIC` etc.) that the fixed regex's end-of-line anchor didn't tolerate. Both fixed, then verified clean across all 7 hosts directly before wiring in, then verified again via a real `systemctl start fleet-health-sweep.service` run (the actual timer trigger path) — all 7 hosts correctly captured a clean baseline, zero errors. Correction to the original scoping note: `sms-relay`/`tor` were flagged as having the same container-naming gap from a rough `grep` proxy count — false positive (both build **and** tag one image in a single service block); re-verified with the real parser, only Wazuh has that particular gap. |
| fleet-judgment-review | systemd (`fleet-judgment-review.timer`) | Not a container — weekly (Sun 08:30) headless `claude -p` invocation, Option D1 of `docs/HoT_Automation_Self_Healing_Scope.md` Section 7, built 2026-08-19. Reads `fleet-health-sweep.log`, `fleet-discovery-push.log`, escalation streak state, a scoped `journalctl` snapshot of this project's own automation units, and (as of the same day, folded in from what was originally a separate Option D2 cloud routine — see below) a live pull of PrivateNexus's Discovery-candidate queue — the judgment layer fixed-rule checks can't be. Report-only: the `claude` invocation itself gets `Read`/`Grep`/`Glob` tools only, no `Bash`/`Edit`/`Write`/SSH, cannot verify anything live and is instructed not to claim to (the wrapper *script* does have real Bash/network access, used only to collect the snapshot files before the read-only invocation starts). Structured output via `--json-schema`, a `needs_attention` field gates whether Ntfy notifies at `high` or stays quiet at `default`. Own fail-safe (`fleet-judgment-review-healthcheck.timer`, daily) built in from day one, not retrofitted — see the compounding fail-safe lesson in the `reboot-watchdog-healthcheck.sh` note above. **First real run found something real**: flagged a genuine inconsistency in this same session's own `reboot-recovery-watchdog` wedge-bug write-up (wrong reboot date attributed as the cause) — checked and confirmed correct via `journalctl --list-boots`, documentation corrected same day. Its other first-run theory (stock `unattended-upgrades` silently overriding `auto_reboot=false`) was checked and disproven directly — real validation that its report-only design (flag for a human to verify, never assert unverified inference as fact) works as intended. Real cost: ~$1.29/run at last measurement (mostly CLAUDE.md context caching), weekly cadence keeps this modest. **D2 (originally a standalone cloud routine reviewing PN's Discovery queue) folded in here the same day** after the cloud sandbox turned out unable to reach `privatenexus.net` at all (default CCR egress policy blocks arbitrary internet hosts, confirmed via both `curl` and `WebFetch`) — the wrapper script now curls `GET https://privatenexus.net/api/discovery/review-export` directly (real network access, unlike the cloud routine) using a dedicated read-only Bearer token (`/etc/fleet-judgment-review-d2/pn_review_token`, also in Vaultwarden's PrivateNexus folder), and the judgment prompt was extended with D2's original review criteria. **A real bug was caught folding this in**: the systemd service had no `PATH` set, so the bare `claude` invocation (`/root/.local/bin/claude`, not on systemd's minimal default `PATH`) failed with `command not found` (exit 127) under the *actual* `systemctl start` trigger path — the original build had only ever been verified via an interactive shell, which has the right `PATH`, so this had been silently broken since day one and would have failed the very first real Sunday run. Fixed via an explicit `Environment="PATH=..."` line in `fleet-judgment-review.service`. **Verified end-to-end after the fix, real paid run via the actual systemd unit**: found the folded-in Discovery data got fetched and reasoned over correctly, and flagged something real — an undocumented `jonasal/nginx-certbot` container running directly on hot-bm-nl itself (not inside a VM), verified live and detailed in `hardware.md`. See `option_d_judgment_review_scope_2026_08_19` memory for the full trace of both D2's cloud attempt and the fold-in. |
| open-items-refresh | systemd (`open-items-refresh.timer`) | Not a container — weekly (Sun 09:00, offset after `fleet-judgment-review`'s 08:30) headless `claude -p` invocation, built 2026-08-25, that keeps the private "House of Trae — Open Items" status Artifact (`claude.ai/code/artifact/58eedec2-...`) in sync with current `CLAUDE.md`/`claude-md/` and memory instead of it silently going stale between sessions the way it did 19→25 Aug. Same safety posture as `fleet-judgment-review` and for the same reason: `Read`/`Grep`/`Glob`/`Write` only, no `Bash`/`Edit`/SSH — cannot verify anything live and is told not to claim to, grounds every change in the same sources a human would check first. Writes the regenerated page to `/opt/hot-config/gateway/open-items-refresh/latest.html` (tracked in git — diffs are real change history over time), sanity-checks the output isn't truncated/broken before accepting it (reverts to last week's version otherwise), and Ntfy-notifies with a plain-English summary of what changed. **Known platform limitation, confirmed live via a real test the same day**: the Artifact tool needed to actually publish to claude.ai is not reachable from a headless `claude -p` invocation at all (it reported the tool doesn't exist in its tool list) — the same class of wall as D2's cloud-egress block. So this job stages content only; the Ntfy notification's job is to prompt a live Claude Code session to pick up the staged file and actually publish it, not to publish it itself. Verified end-to-end via a real manual `systemctl start` run before the timer was trusted, matching the project's standard verification convention. |
| Dockge            | /opt/stacks/dockge/     | Docker Compose stack management UI (`louislam/dockge:1`) for every stack in `/opt/stacks/` on the Gateway. Running since 2026-02-19, found undocumented during the 2026-08-08 diagnostic sweep — not a stray leftover, a deliberately-scoped admin tool: `ports: "100.106.41.10:5001:5001"` binds it to the Gateway's own Tailscale IP only, same access pattern already used for hot-bm-nl's Proxmox UI (port 8006, also Tailscale-scoped) — no UFW rule needed since it's not bound to a public interface at all. Mounts `/var/run/docker.sock` + the full `/opt/stacks` tree, so it has complete management capability over every service on this host — reachable only over Tailscale by design, matches the "Tailscale = admin only" rule. Access: `http://100.106.41.10:5001` from an admin device on the tailnet. |
| sms-relay | /opt/stacks/sms-relay/  | Rebuilt from scratch here 2026-08-03, fully functional as of 2026-08-04 (see sms_relay_migration_scope memory) — the original, documented as living on sn-infra, turned out to be completely gone (no container, no systemd unit, nothing on disk) since at least the 2026-07-27 sn-infra rebuild, which never redeployed it. Small Node.js service, no framework, subscribes directly to Ntfy's `hot-alerts` topic (anonymous read already granted there) and forwards only `priority=5`/"urgent" messages to Twilio SMS — CrowdSec's own ban notifications (`priority=high`/4) are correctly excluded. Rate-limited to 1 SMS per alert-group per 5 min, matching the documented Alerting Architecture limit — grouped by Grafana's own `groupKey` for Grafana-shaped payloads (added 2026-08-04, see Grafana Alerting section), message title otherwise. Real Twilio credentials wired in 2026-08-04 (`/opt/stacks/sms-relay/secrets/`); `SMS_FROM_NUMBER=+447403942795` (Twilio's own hosted number) / `SMS_TO_NUMBER=+447771724186` (Mr. Byrne's real mobile) — Twilio rejects identical To/From (error 21266), hit and fixed live, see user_contact memory. Verified with a real SMS sent and confirmed received. **Now has a real live publisher**: Grafana's 3 CRITICAL-severity alert rules (Node Down/Disk >95%/TLS cert <7d), wired 2026-08-04 — previously nothing published to Ntfy at priority=5 at all except manual tests. Tracked in `hot-config/gateway/sms-relay/` (secrets excluded, per the `**/secrets/` gitignore rule) — unlike its predecessor, this one won't silently vanish on a future rebuild. |

### sn-infra (ssh sn-infra — 10.10.10.100)
| Service        | Path                    | URL                           | Port |
|----------------|-------------------------|-------------------------------|------|
| Forgejo        | /opt/stacks/forgejo/    | git.securenexus.net           | 3000 |
| PowerDNS-Admin | /opt/stacks/pdns-admin/ | dns-admin.house-of-trae.com   | 9191 |
| Namevault      | /opt/stacks/namevault/  | namevault.co.uk               | 8010 |
| hot-wiki       | /opt/stacks/wiki/       | wiki.house-of-trae.com        | 3030 |

**hot-wiki — found undocumented 2026-09-02, real build confirmed live 25&nbsp;Aug.** `requarks/wiki:2`
(Wiki.js) + its own Postgres 16 container (`hot-wiki-db`), created 2026-08-25 — the actual answer
to the long-standing "wiki.house-of-trae.com still a bare 502" open item, which was wrong: the
Caddy route (`import crowdsec`/`compress`/`secure_headers`, no `import sso` — same public-docs
exception as `docs.privatenexus.net`) and the backend were both real and correctly wired the whole
time; the backend was just down. Bound to `10.10.10.100:3030`, tunnel-internal, matching every
other sn-infra service. 21 authentication strategies loaded including Keycloak — not yet confirmed
whether OIDC login is actually wired to a realm client the way `docs.privatenexus.net`'s was, or
whether Keycloak's just present as an available-but-unconfigured strategy; worth checking before
telling Mr. Byrne it's ready to use. No Uptime Kuma/Gatus/UptimeRobot monitor exists for it either —
same class of gap as `docs.privatenexus.net`. **Taken down 2026-09-02 by the same qm hard-cycle bug
that stopped this VM for 4 days** (see `reboot_watchdog_proxmox_failure_outage_2026_09_02` memory) —
found+fixed the same session, see the note under Hardware/Operational Rules on stale `docker-proxy`
processes surviving a VM hard-cycle. Currently reachable and serving `200` both locally and via the
public URL — confirmed live, but nothing in it (content, users, first-run setup) has been checked or
documented yet.

**Ntfy moved to the Gateway VPS 2026-08-03** (see Gateway VPS service table below) — no longer
here. Was documented as living here, but during the 2026-08-03 hot-bm-nl outage, discovered its
public vhost (`10.10.10.100:8080`) had gone down along with the rest of this VM. Adopted a Gateway-
local `ntfy` container that had actually been running since 2026-07-02 (Ntfy's original deployment,
before an earlier "move to sn-infra" that apparently never fully decommissioned it) rather than
build fresh — confirmed it wasn't just an idle leftover: CrowdSec's own alert plugin
(`gateway/crowdsec/notifications/http.yaml`) had been posting real ban notifications to it via
`http://ntfy:80/hot-alerts` the whole time, using a still-valid bearer token, verified live. The
leftover `/opt/stacks/ntfy/` stack here (still present but `Exited`, never actually removed when
the service moved) was confirmed unused and torn down 2026-08-08 (`docker compose down -v` +
directory removal) — nothing pointed at it anymore.

### sn-business (ssh sn-business — 10.10.20.101)
| Service     | Path                 | URL                      | Port |
|-------------|----------------------|--------------------------|------|
| ERPNext v16 | /opt/stacks/dickson/ | erp.dickson-supplies.com | 8000 |

Stack: custom image (`/opt/stacks/dickson/docker/Dockerfile`) — `frappe/erpnext:v16` + posawesome. Services: `dickson-backend` (gunicorn), `dickson-db` (MariaDB 10.6), redis-cache, redis-queue, socketio, worker, scheduler. Secrets in `/opt/stacks/dickson/secrets/*.txt` — must be `chmod 644` (frappe UID 1000). Site DB name: `_ae77c090ad3ef28b`.

### sn-web (ssh sn-web — 10.10.30.102)
| Service          | Path                        | URL                  | Port |
|------------------|-----------------------------|----------------------|------|
| Stratus Digital  | /opt/stacks/stratus-digital/| stratus-digital.com  | 8001 |
| Discreet Elite   | /opt/stacks/discreet-elite/ | discreet-elite.uk    | 8002 |
| Emerald Markets  | /opt/stacks/emerald-markets/| emerald-markets.net  | 8003 |
| Ruby Osiris      | /opt/stacks/ruby/           | rubyosiris.com       | 8004 |
| Evil Rabbit Art  | /opt/stacks/evilrabbit/     | evilrabbitart.com    | 8005 |
| Dickson Supplies | /opt/stacks/dicksonweb/     | dickson-supplies.com | 8006 |

**Real client sites, 2026-09-02/04, replacing the original 6 identical "Coming Soon" placeholders**
one design brief at a time (`stratus-digital`/`discreet-elite`/`emerald-markets` in the prior
session, `ruby`/`evilrabbit`/`dicksonweb` here) — all 6 are still `nginx:alpine` + static
`index.html`, ports/Caddy routing unchanged, except Stratus Digital itself (below). Ruby Osiris
(dropship jewellery, Egyptian-revival crimson/gold, Marcellus display serif), Evil Rabbit Art
(gallery + shop for `@evilrabbitart`, dark punk-gallery palette — **built from the brand name only,
not real reference**: Instagram 429-rate-limited the fetch and TikTok returned only the JS app
shell, no post content was actually reachable, flag to Mr. Byrne to redirect if it doesn't match
the real account), Dickson Supplies (medical/clinical B2B distribution, clinical blue/teal, no
specific certification claimed as fact — copy deliberately says "reviewed for CE marking," not "CE
certified"). All 5 non-Stratus sites (discreet-elite/emerald-markets/ruby/evilrabbit/dicksonweb)
now carry a "Site by Stratus Digital → stratus-digital.com" footer credit link, styled to match each
site's own accent color.

**Stratus Digital rebuilt from bare nginx to a real Express app, 2026-09-03/04** — the only sn-web
site with actual application logic now, not just static content (source tracked in `hot-config`,
`sync.sh`, unlike the other 5 sites' still-untracked `html/`, a pre-existing gap). Added at Mr.
Byrne's request: client sites need a real authenticated portal (not just a links page or a footer
credit — both of which were considered and are also implemented, see above) where each client logs
in to see their own site's live status. `/opt/stacks/stratus-digital/app/` (Dockerfile, `server.js`,
`package.json`, `public/index.html` — the marketing homepage, now served by Express's static
middleware rather than nginx, unchanged content plus a new "Client Login" nav link to `/portal`).
Container now listens on :3000 internally (compose maps `10.10.30.102:8001:3000`, same external
port as before — no Caddy change needed).

Auth: native Keycloak OIDC (manual authorization-code flow, `jose` for JWKS-verified ID token
validation — no `openid-client`/framework dependency) against a new confidential client
`stratus-portal` registered directly in the existing `stratus-digital` realm (redirect URI
`https://stratus-digital.com/portal/callback`). Per-user site access is carried via two custom
Keycloak User Profile attributes on this realm, `portal_access` (comma-separated site slugs, or
`all` for House of Trae staff) and `portal_label` (display name), surfaced into the ID token via
two dedicated protocol mappers on the client. Dashboard (`/portal`, session-gated via
`express-session`) shows only the sites a user's `portal_access` grants, each with a real live
status check (a direct `fetch` against the site's own public URL, 5s timeout, HTTP status +
latency) — not a stub.

**Two real Keycloak gotchas hit building this, both realm-wide fixes, not app workarounds:** (1)
this realm's browser flow auto-redirects through the `house-of-trae` staff broker by default (the
documented identity-provider-redirector pattern, see the Keycloak SSO section below) — real
external clients would never reach a local login form at all. Fixed by adding `kc_idp_hint=`
(empty) to the authorization request, which bypasses the redirector and lands on the realm's own
local username/password form; staff can still use the broker separately if that's ever wired back
in. (2) Admin-API-created users kept getting redirected to Keycloak's own `VERIFY_PROFILE`
required-action page mid-login despite `requiredActions: []` on the user record — root cause was
that `portal_access`/`portal_label` weren't declared in the realm's User Profile schema yet
(`unmanagedAttributePolicy: None` here, so undeclared custom attributes are silently dropped even
though the admin API accepts them with 201) — fixed by declaring both as admin-only User Profile
attributes. `VERIFY_PROFILE` still fired after that fix for unclear reasons and was disabled
realm-wide (`enabled: false`) as the pragmatic fix — this realm had zero local users before this
build, so the change has no other blast radius, and a client portal shouldn't dead-end an
admin-provisioned account behind Keycloak's own profile-review UI anyway.

**Verified end-to-end via a real curl-driven OIDC flow** (same pattern as the `AUTH-07` MFA
verification — disposable test accounts, deleted after): a full-access "staff" test account
correctly saw all 6 sites live; a scoped test account (`portal_access: rubyosiris`) correctly saw
only Ruby Osiris. Both test accounts removed after verification. **No real client accounts exist
yet** — Mr. Byrne doesn't have client login emails on hand; the mechanism is built and proven, next
step is provisioning real accounts (create a local user in the `stratus-digital` realm, set
`portal_access`/`portal_label`) once there's a real client to onboard. `stratus-portal`'s client
secret is in Vaultwarden ("stratus-digital.com Client Portal (Keycloak stratus-portal client)",
House of Trae — Gateway VPS folder) with the full onboarding steps in the note.

### sn-personal — ⚠️ RETIRED (Mr. Byrne's decision, 2026-08-09), this VM does not currently exist
**Not rebuilt on hot-bm-nl** (VLAN 40 excluded — see Network Topology above) and its SSH alias
(`sn-personal`, 10.10.40.103) was removed 2026-07-30 as a dead end (fleet health check). The table
below describes what this VM ran **before** the original bare-metal host was decommissioned —
kept for historical reference only, not current state. `privatenexus.net` is **not** served from
here anymore; it's permanently routed to hot-pn (`10.10.2.2:5173`, see the hot-pn section below).
Cosmos (and the personal services it ran — Vaultwarden, Immich, Firefly III, Actual Budget,
Nextcloud, Notesnook) was fully removed in Jun 2026, data was never populated so no loss. **VLAN
40/sn-personal's fate: confirmed retired outright, 2026-08-09** — same call as pn-test, no rebuild
planned, ever. Mr. Byrne had tentatively floated repurposing it for the Phase 4 "HoT Sync" roadmap
item, but decided against reserving it for that; HoT Sync will need a different landing spot if it
ever gets scoped. See `hostkey_server_replacement` memory. Matches pn-test (VLAN 60), which Mr.
Byrne confirmed 2026-08-03 is retired outright — both VLANs are now settled, not just historical.

| Service (historical, pre-outage) | Path                       | URL                 | Port |
|-----------------------------------|----------------------------|---------------------|------|
| PrivateNexus (former test env)    | /opt/privatenexus/compose/ | privatenexus.net    | 5173 |

### sn-monitor (ssh sn-monitor — 10.10.50.104)
| Service     | Path                    | URL                       | Port |
|-------------|-------------------------|---------------------------|------|
| Monitoring  | /opt/stacks/monitoring/ | grafana.house-of-trae.com | —    |
| Prometheus  | (inside monitoring)     | internal only             | 9090 |
| Loki        | (inside monitoring)     | 10.10.50.104:3100         | 3100 |
| Uptime Kuma | (inside monitoring)     | status.house-of-trae.com  | —    |

status.house-of-trae.com — slug `hot-status`, exposes only the 6 group entity sites. Admin at **monitor.house-of-trae.com** (moved from monitor.securenexus.net:3001 2026-08-09, old URL 301-redirects — see the SSO section below for why).
Grafana admin password: reset via `grafana cli admin reset-admin-password` — GF_SECURITY_ADMIN_PASSWORD only applies on first init.
node-exporter UFW gotcha: Prometheus runs in bridge network 172.18.0.0/16 — UFW must allow that subnet to port 9100.

### pn-test — ⚠️ RETIRED (Mr. Byrne's decision, 2026-08-03)
Formerly VLAN 60 (10.10.60.105) — hosted PrivateNexus dev/build (local source builds) and was
earmarked for personal services alongside sn-personal, back when the original bare-metal host was
live. Its SSH alias was removed 2026-07-30 as a dead end; **confirmed retired outright, not just
undecided, 2026-08-03** — its only real purpose (PrivateNexus dev/build) is fully redundant now
that PrivateNexus's permanent home is hot-pn (which combines the old pn-test dev role and the old
sn-personal test role). No rebuild planned, no VLAN 60, no VM 105. See `hostkey_server_replacement`
memory for the full history.

**Phase 0 freeze (locked 22 June 2026):** Backend = Node.js Express v4 (ESM). Frontend = React. DB = PostgreSQL 16. Cache/queue = Redis. Identity = Keycloak (privatenexus realm). Gateway = Caddy. Do not suggest Go or NestJS as a rewrite — the codebase is at v1.9 and this decision is closed. See `/root/hot/docs/PrivateNexus_Phase0_Freeze.md` for full rationale and checklist.

### sn-security (ssh sn-security — 10.10.70.106)
VM: **2 vCPU** (permanently capped below the originally-planned 4 — see note below) / 8 GB RAM / 250 GB / VLAN 70. LUKS2 encrypted root (Clevis Tang → Gateway VPS preferred, sn-infra fallback). Dashboard: wazuh.house-of-trae.com

**⚠ Pinned at `cores=2`, not 4 — permanent, by Mr. Byrne's decision (2026-07-28), not a temporary workaround.** hot-bm-nl hangs at guest SMP bring-up whenever a VM is configured with more than 2 vCPUs — confirmed via a disposable test VM to be independent of CPU model (`host`/`kvm64`), core/socket topology, x2apic, HPET, and ACPI settings, and independent of whether the guest kernel actually starts the extra CPUs (`maxcpus=` doesn't help) — it fires purely from QEMU/ACPI declaring >2 CPUs exist. Most likely a real limitation of hot-bm-nl's double-nested virtualization depth (Hostkey's own hypervisor → hot-bm-nl as their VM → Proxmox/KVM inside that → this VM), not something fixable via Proxmox config or kernel boot parameters. Real-world impact checked and found negligible at current load: sn-security idles at 0.06–0.21 load average on its 2 cores even with the full Wazuh stack running. Full investigation, every ruled-out variable, and the diagnostic method: `sn_web_luks_pilot_fix.md` in memory. Don't re-investigate from scratch if this resurfaces on a future VM.

| Service        | Path                        | Notes                                                     |
|----------------|-----------------------------|------------------------------------------------------------|
| Wazuh SIEM     | /opt/stacks/wazuh/          | wazuh.house-of-trae.com — manager + indexer + dashboard   |
| Forgejo Runner | /opt/stacks/forgejo-runner/ | CI/CD runner for git.securenexus.net                      |

Wazuh creds (saved in Vaultwarden, "House of Trae — Gateway VPS" folder):
- Dashboard/admin login: `admin` / `bRSsn8P2v1YIbemCHejpEb6l`
- Wazuh API (wazuh-wui): `mHB2UhhMw0wTc3q8@22vJeOvr`
- OpenSearch kibanaserver: `h2huT1B1TrUXQg8Wri5FqhdP`

**Agent enrollment — full fleet coverage as of 2026-08-08.** Until this date only the manager
itself and the Gateway VPS had an agent installed; sn-infra/sn-web/sn-monitor/hot-bm-nl/hot-pn/
hot-erp-nl all lacked one. All 7 non-manager hosts are now enrolled and Active (`agent_control -l`
on the manager container). Install pattern: Wazuh's own apt repo
(`packages.wazuh.com/4.x/apt stable main`, `wazuh.gpg` keyring — minimal Debian VM images need
`gnupg` installed first), `WAZUH_MANAGER=10.10.70.106 apt-get install -y wazuh-agent`, then
`/var/ossec/bin/agent-auth -m 10.10.70.106 -A $(hostname)` (talks to `wazuh-authd` on
sn-security:1515, already running/exposed, no manager-side change needed), `systemctl enable --now
wazuh-agent`. hot-bm-nl's agent registered under its real hostname `proxmox22272.hostkey.in`.

Reaching sn-security from hot-pn/hot-erp-nl required widening their own wg3/wg5 tunnel `AllowedIPs`
(client-side only, scoped to `10.10.70.106/32`) **and** hot-bm-nl's wg4 peer `AllowedIPs` (to accept
their real source IPs, `10.10.2.2/32`+`10.10.4.2/32` — WireGuard drops non-matching sources silently
at the crypto layer, before iptables ever sees the packet) — plus 4 narrowly-scoped Gateway
`ufw route allow` rules (wg3/wg5→wg4, restricted to `10.10.70.106` ports `1514`/`1515` only, not
general VLAN access). Full detail, including the missing-VLAN30↔70-forward-rule bug found along the
way: `wazuh_agent_enrollment_2026_08_08` memory.

**⚠ sn-infra's agent found fully down for a week, fixed 2026-08-16.** All 5 wazuh-agent subprocesses
(`wazuh-modulesd`/`-logcollector`/`-syscheckd`/`-agentd`/`-execd`) were dead — not just a stale
`systemctl --failed` flag, genuinely not running. Root cause: sn-infra rebooted 2026-08-09 00:47 UTC
(the fleet-wide apt auto-reboot night) and `wazuh-agent.service` hit a start-operation timeout during
that boot (`systemd-journal-flush.service` failed with the identical "timeout" signature at the same
moment — a slow-boot contention issue, not specific to Wazuh) and never came back, silently, with zero
alerting on the gap itself. Found during a full fleet health check 2026-08-16, fixed with `systemctl
restart wazuh-agent`, confirmed processes running and re-confirmed `Active` on the manager via
`agent_control -l`. Worth checking `/var/ossec/bin/wazuh-control status` directly (not just
`systemctl status`) on any host after a reboot night — a service that's "enabled" and not in
`--failed` can still be silently not-running if its own start attempt timed out weeks ago and nothing
retried it.

---

