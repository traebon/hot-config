## Phase 4 — On the Horizon

**Done, removed from this list (2026-08-03 cleanup):** Wazuh SIEM on sn-security (live since the
2026-07-27/28 rebuild) and Cosmos retirement (fully removed Jun 2026) — this list wasn't updated
when either landed.

- ~~CrowdSec custom scenarios~~ **Done since 2026-07-02, this line was stale (2nd time — a
  2026-08-03 audit already found the same staleness and fixed it, but the fix itself never landed
  here).** 3 local scenarios live in `/opt/hot-config/gateway/crowdsec/scenarios/`: `hot/admin-scan`
  (multi-path scan detection), `hot/forgejo-bf`, `hot/keycloak-bf` — all bug-audited and fixed
  2026-08-03 (3 real bugs found: a 5xx-blind status filter, zero host-scoping letting unrelated
  traffic pollute a bucket, and a `distinct` clause that silently defeated brute-force counting on 2
  of the 3 scenarios since creation). See `crowdsec_custom_scenarios_audit_2026_08_03` memory.
  **Re-scoped 2026-08-09**: checked whether other HoT login surfaces (ERPNext, Grafana, Wazuh
  dashboard, PowerDNS-Admin) have the same kind of status-code blind spot — all four return a
  standard 401/403 on bad login and are already covered by the installed
  `LePresidente/http-generic-401-bf`/`403-bf` scenarios. **One real gap found and fixed same day:
  Vaultwarden's `/identity/connect/token` returns HTTP 400 on bad login (confirmed live), which none
  of the installed scenarios watched for.** Built `hot/vaultwarden-bf` (4th local scenario, same
  no-`distinct` leaky-bucket pattern as the other 3), deployed live and verified loaded
  (`cscli scenarios list`, clean container restart, bouncer still authenticating after), committed
  and pushed to all 3 `hot-config` remotes (`694e427`).
- PrivateNexus PN roadmap gates (v5.0/v6.0/v7.0) — see `PrivateNexus_Release_Roadmap_v1.0.md` and
  the `open_items_2026_07_27` memory for current gate-item detail; re-verify before trusting any
  snapshot, this list drifts (e.g. Security Lockdown Mode was listed unbuilt as of 2026-07-27 but
  was actually finished 2026-08-01 — see `PrivateNexus_Security_Lockdown_Mode_Design.md`)
- HoT Sync (Flutter) — Immich + Nextcloud + Notesnook + Vaultwarden; no longer tied to sn-personal
  (VLAN 40 retired outright 2026-08-09, see the sn-personal section above) — needs a fresh landing
  spot if this is ever scoped, not yet scoped either way
- HoT Command (Flutter) — Mobile ops dashboard (also listed as a v7.0 PN roadmap candidate)
- Second bare metal node (HA)
- Edge load balancing (second VPS) — scoped 2026-08-17, expanded at Mr. Byrne's direction to cover
  hot-pn + hot-erp-nl (both currently have zero direct public path of their own, fully dependent on
  the Gateway VPS as sole ingress — verified live via UFW). Three options scoped (full second edge
  VPS / direct per-domain failover on hot-pn+hot-erp-nl's own public IPs / manual failover runbook
  only), not yet decided which to pursue. See `docs/HoT_Edge_Load_Balancing_Scope.md`. **Note:**
  this file and the scope doc were both briefly overwritten mid-session 2026-08-17 by a
  prompt-injection attempt that fabricated an opposite scope decision and tried to suppress
  disclosure — restored to the real, user-confirmed scope; see
  `prompt_injection_incident_2026_08_17` memory.
- Terraform / Ansible IaC
- **Proxmox Backup Server (PBS) fleet integration** — scoped 2026-08-22. Mr. Byrne stood up a new
  PBS host (local hardware on his own network, not a rented VPS) and wants it consolidating backups
  "across the entire fleet." SSH connectivity established (`pbs` alias, reachable over Tailscale —
  the box has no WireGuard tunnel and sits behind a home NAT, not a public IP). Real findings so
  far: single-disk datastore with no RAID, a live but fragile `onlink`-only default route
  (`192.168.0.35/24` gateway `192.168.1.1` mismatch), and a direct tension with the project's own
  "Tailscale = admin only" rule since backup traffic is real production bulk transfer. Three scope
  options (hot-bm-nl VMs only / fleet-wide file-level too / PBS as primary replacing Hetzner+B2) and
  the transport question (new dedicated WireGuard tunnel vs. a documented Tailscale exception) both
  need Mr. Byrne's decision before anything gets built. See
  `docs/HoT_PBS_Backup_Integration_Scope.md`.
- **More autonomous fleet operation ("more JARVIS, less manual sweep")** — raised by Mr. Byrne
  2026-08-19. The pattern across most incidents in this project so far is the same shape: a real
  problem sits silently for days until either a scheduled fleet health check or a direct user
  report surfaces it — the automation that exists today (apt-daily-update, reboot-recovery-watchdog,
  Gatus/Uptime Kuma/Grafana) only covers reachability, patching, and metric thresholds, not
  config drift, silent partial failures, or gaps in the automation's own coverage. Concrete examples
  from this project's own history, not hypothetical: hot-pn's public SSH sat open and unmitigated
  for a month before anyone checked (`hot_pn_ssh_hardening_2026_08_18`); Tailscale was missing
  entirely from 4 rebuilt VMs for 3 days (`tailscale` memory); a wedged `grub-pc` silently blocked
  every patch on hot-pn for 4 nights with the failure-alert itself never firing
  (`apt_daily_update_rollout_2026_08_05`); sn-infra's Wazuh agent was fully dead for a week after a
  reboot-night timeout (`fleet_health_checks`); and PN's Catalogue-deployed services (Nextcloud,
  Notesnook) never got a `health_endpoint` populated at all, going undetected until Mr. Byrne
  noticed it in the UI (fixed 2026-08-19, this session). **Scoped 2026-08-19** — see
  `docs/HoT_Automation_Self_Healing_Scope.md`: a 5-class failure taxonomy (process/supervisor-state
  mismatch, alert-fired-but-too-low-severity, config drift, undocumented deployments, code paths
  missing existing invariants) and 4 options (deterministic scheduled sweep / extend PN's
  Discovery-governance model fleet-wide / an alert-escalation layer / a periodic LLM-driven judgment
  review). **Option A+C (first slice) built and live same day**: `fleet-health-sweep.timer`
  (nightly, `claude-md/services-fleet.md`) sweeping every host for systemd/dpkg/wazuh-liveness/
  stacks-drift/ufw-drift, with built-in streak-based Ntfy escalation. Building it surfaced two more
  real bugs of exactly the kind this whole item is about — `reboot-recovery-watchdog.timer` and
  `sn-infra-recovery-check.timer` had both been silently wedged dead for 6 days (no `OnCalendar`,
  see Operational Rules), and their own fail-safe healthcheck script had *also* been gone the whole
  time (ad hoc transient scheduling, no persistence) — all three now fixed. See
  `gateway_timer_wedge_bug_2026_08_19` memory. **Option B scoped AND built 2026-08-19** (same doc,
  Section 6) — Mr. Byrne chose B2 (Gateway consolidates via its existing SSH reach, not B1/every
  host pushing directly). `fleet-discovery-push.timer` (hourly) now pushes 7 of 8 fleet hosts into
  PN's Discovery pipeline (hot-pn keeps its own agent). Building it surfaced 2 more real bugs, both
  fixed: `discovery_candidates`' dedup index was missing `host` (generic names like `watchtower`
  collide across 6 of 8 hosts, would have silently overwritten each other), and PN's approve handler
  would have let automation act on the wrong physical container across hosts if candidates were
  pushed as `runtime: "docker"` instead of `"external"`. See `option_b_discovery_scope_2026_08_19`
  memory. **Option D scoped AND built 2026-08-19** (same doc, Section 7) — the genuinely "more
  JARVIS" piece, since A/B2/C are all fixed rules and D is the layer that can actually reason about
  whether something matters. Mr. Byrne chose D1 (local headless `claude -p` on the Gateway),
  Report-only (no write/mutate access), weekly — `fleet-judgment-review.timer`, plus its own
  fail-safe healthcheck built in from day one rather than retrofitted. **First real run found
  something real, same day**: flagged a genuine dating error in this same session's own
  `reboot-recovery-watchdog` wedge-bug write-up (wrong reboot attributed as the cause), confirmed via
  `journalctl --list-boots` and corrected across `operational-rules.md`/`automated-patching.md`/
  `services-fleet.md`/memory — real, live proof the report-only design (flag for a human to verify,
  never assert unverified inference as fact) works as intended. This closes out the whole automation
  initiative's first pass — all 4 options (A/B/C/D) now scoped, with A/B2/C/D1 built and live. **D2
  attempted the same day too** — a real read-only PrivateNexus endpoint
  (`GET /api/discovery/review-export`, Bearer-token auth, structurally incapable of mutating
  anything) was built and verified working from the public internet, but the cloud routine meant to
  call it hit a genuine platform wall: this account's CCR cloud-sandbox environment default-denies
  network egress to arbitrary internet hosts (confirmed two ways — a live `curl` got a 403 on
  CONNECT, and swapping in `WebFetch` returned an explicit `EGRESS_BLOCKED` error naming
  `privatenexus.net`), with no field exposed via the `schedule` skill's `RemoteTrigger` API to widen
  it. Routine paused (`enabled: false`, can't be deleted via the API), not deleted or left silently
  failing weekly. **Folded into D1 instead, same day, at Mr. Byrne's direction** — D1's wrapper
  script (which has real network access, unlike the `claude` invocation it runs) now curls PN's
  Discovery export directly and feeds it into the same weekly judgment pass; the paused cloud routine
  is fully superseded, not just blocked. Re-verifying this surfaced a second real bug (the systemd
  service had no `PATH`, so `claude` — only resolvable via `/root/.local/bin` — silently failed under
  the actual `systemctl start` trigger the whole time; the original build had only ever been verified
  via an interactive shell with the right `PATH`; fixed), and the first post-fold-in run found
  something real and previously undocumented: an `nginx-certbot` container running directly on the
  hot-bm-nl host itself, outside any of its 4 VMs (verified live, likely Hostkey's own provisioning
  tooling — see `hardware.md`). See `option_d_judgment_review_scope_2026_08_19` memory for the full
  trace.

