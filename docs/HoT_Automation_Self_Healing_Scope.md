# HoT — Increased Fleet Automation / Self-Healing ("more JARVIS, less manual sweep")

Scoping doc. Written 2026-08-19 at Mr. Byrne's direction, expanding the one-line roadmap item
added the same day ("More autonomous fleet operation") in `claude-md/roadmap.md`.

Not a commitment to build — a scope to react to and prioritize against, same pattern as
`HoT_Edge_Load_Balancing_Scope.md` and `PrivateNexus_Catalogue_Deploy_Flow_Scope.md`.

---

## 1. Why this matters — the pattern across this project's real incident history

Every incident below has the same shape: a genuine, actively-bad condition existed for days to
weeks, and the thing that ended it was either a scheduled-but-irregular manual "fleet health check"
session, or Mr. Byrne noticing something directly. None of HoT's existing automation caught any of
them while they were live.

| Incident | How long it went unnoticed | What finally caught it |
|---|---|---|
| hot-pn public SSH open to `Anywhere`, 83,020 failed logins/7d, no Tailscale | ~1 month (since 2026-07-15 standup) | Direct investigation while scoping an unrelated doc — not a check built for this |
| Tailscale missing entirely on 4 rebuilt hot-bm-nl VMs | 3 days | Scheduled fleet health check, 2026-07-30 |
| Wedged `grub-pc` silently aborting every `apt upgrade` on hot-pn | 4 nights straight | Fleet health check, 2026-08-16 |
| sn-infra's Wazuh agent fully dead (all 5 subprocesses) after a reboot-night timeout | ~1 week | Same fleet health check, 2026-08-16 |
| PN Catalogue-deployed services (Nextcloud, Notesnook) never got `health_endpoint` populated | Since 2026-08-10 (9 days) | Mr. Byrne noticed it directly in the PN UI, 2026-08-19 |
| `discovery-agent.sh` on hot-pn silently losing its execute bit, hourly ingest failing every run | Unknown duration | Same fleet health check, 2026-08-16 |
| PN's Proxmox health check pointed at a decommissioned host's dead address | 19 days | Direct investigation of an unrelated user report, 2026-08-09 |

**What HoT's existing automation *does* already cover well** — worth being explicit about so this
doc doesn't propose rebuilding what already works:
- **Reachability/liveness**: `reboot-recovery-watchdog.timer` (soft→hard→manual escalation),
  Gatus (21 endpoints, deliberately independent of sn-monitor), Uptime Kuma, Grafana's Node Down
  rule.
- **Resource thresholds**: Grafana's Disk >85%/>95%, Memory >90% rules.
- **Patch application**: `apt-daily-update.timer` fleet-wide, `apt-daily-check` on hot-bm-nl.
- **Security events**: CrowdSec (4 custom scenarios + generic brute-force scenarios), Wazuh SIEM.
- **Container image staleness**: Watchtower (monitor-only across every host).
- **Backup completion**: nightly cron chain, B2 cap canary check.

**The actual gap** is a distinct layer none of the above touches: **config drift, silent partial
failures where a process is dead but its supervising layer doesn't know it, and things that exist
but were never registered anywhere** — plus, in more than one case above, **an alert that DID fire
but nobody looked at it** (the `grub-pc` failure correctly sent an `apt upgrade FAILED` Ntfy
notification at `priority=high` every single night for 4 nights — it just never escalated past a
severity tier that pages nobody, so it sat unread). That's two separate problems, not one:
detection gaps, and alert-visibility gaps for the detection that already exists.

---

## 2. Failure-class taxonomy — what actually needs a new kind of check

Grouping the incidents above (and other findings from this project's history) by mechanism, since
each needs a genuinely different kind of detector:

1. **Process-vs-supervisor-state mismatch.** systemd reports a unit "enabled" / not `--failed`,
   but the actual process(es) are dead — sn-infra's Wazuh agent case exactly. `systemctl status`
   alone is not sufficient; needs a check against the application's own "are you actually running"
   signal (`wazuh-control status`, not just `systemctl status wazuh-agent`).
2. **Alert fired, severity too low to be seen.** The `grub-pc` failure and (differently) the
   Grafana SQLite lock-contention flapping burst both correctly triggered *something*, but at a
   tier that doesn't escalate — no mechanism exists today for "this alert has been repeating
   unacknowledged for N cycles, escalate it."
3. **Config drift with no re-audit trigger.** hot-pn's SSH exposure was correct-by-omission at
   standup (no VLAN/Tailscale pattern existed yet for standalone VPS hosts) and then never
   revisited as the rest of the fleet's pattern matured around it. Nothing re-checks "does this
   host's config still match the fleet's current baseline" after initial setup.
4. **Undocumented / unregistered deployments.** `nextcloud-personal` exists, runs, and was
   deliberately deployed — but isn't in CLAUDE.md, isn't in PN's `services` governance table
   (unlike PN's own Catalogue deploys, which self-register), and would only ever be found by
   someone manually listing `/opt/stacks/` on that specific host.
5. **New code paths that don't inherit existing invariants.** PN's Catalogue executor is the clean
   example — Discovery's `inferHealthEndpoint()` already existed and worked correctly, but the
   newer Catalogue deploy flow was written without reusing it, so a whole class of PN-deployed
   services silently lacked health checks from day one. This is a code-review-shaped gap, not an
   infra-monitoring-shaped one — no runtime check would have caught it, only a "does every service
   creation path set the fields the health system expects" audit.

Classes 1-4 are candidates for a runtime detector. Class 5 is not — it needs to stay a code-review
practice (worth noting in PN's own dev workflow, out of scope for this infra-automation doc).

---

## 3. Options

### Option A — Institutionalize the manual fleet health check as a scheduled deterministic sweep
Turn what's currently an ad hoc, irregularly-triggered session (`fleet_health_checks` memory: run
2026-07-30, then not again until 2026-08-16 — over two weeks between sweeps, which is exactly how
long several of the incidents above sat undetected) into a real recurring job. A single script, run
via systemd timer from the Gateway (same execution model as `reboot-recovery-watchdog.timer` and
`sn-infra-recovery-check.timer` — deliberately **not** a cloud-scheduled Claude Code routine, since
a cloud sandbox has no path to wg4/SSH/Tailscale, the same constraint already documented for the
sn-infra recovery watchdog), SSHing to every host and running the same mechanical checks a human
currently does by hand:
- `dpkg --audit` + `systemctl --failed` on every host
- Application-level liveness checks against known state-mismatch-prone services (Wazuh agent
  subprocess list, others as found) rather than trusting `systemctl is-active` alone
- Diff `/opt/stacks/*` directory listings against a maintained inventory file, flag anything new
- Confirm each host's UFW rule set against a small maintained baseline (would have caught the SSH
  gap, if the baseline had been written down at the time — this only works going forward, not
  retroactively)

Reports via Ntfy, same channel/token as everything else. Cheap, mechanical, immediately closes
several of the specific gaps above. Doesn't catch anything requiring judgment (is this new
`/opt/stacks/` directory a problem, or an intentional deploy that just needs documenting?) — it can
only flag for a human/Claude to look at, not decide.

### Option B — Extend PN's existing Discovery/governance model fleet-wide
PN already has a working answer to failure-class 4 (undocumented deployments) for its own
containers: the hourly `discovery-agent.sh` → `POST /api/discovery/ingest` → candidate → admin
review flow, plus the `services` governance table's `recoverable` tier / readiness scoring model.
Rather than building a second, parallel inventory system from scratch, this option is: point the
same discovery pattern (or a lightweight fleet-wide sibling of it) at every host's `/opt/stacks/`,
not just hot-pn's own — surfacing "container running, not in the registry" as a first-class,
already-has-a-UI signal instead of a script's Ntfy line.

Real advantage: reuses infrastructure that's already built, tested, and has a review workflow
attached (`discovery_candidates` → its own direct approve/reject route, `POST
/api/discovery/candidates/:id`, `routes/discovery.js` — a lighter single-approval flow, *not* the
`action_requests` dual-control queue the Catalogue flow uses; corrected here 2026-08-19 after
reading the real code, an earlier draft of this doc conflated the two). Real cost / design question:
see Section 6 below for a full deep-dive, done 2026-08-19 after reading the actual
`discovery-agent.sh`/`routes/discovery.js` implementation — the short version is that Discovery is
**push**-based (each host's agent posts to PN over HTTPS, bearer-token-authenticated via a real
per-source `agent_tokens` table), not pull-based, so this does **not** actually require PN's backend
to gain SSH/Docker-API reach into every host the way the original draft of this option assumed.

### Option C — Alert-escalation layer, orthogonal to A/B
Directly answers failure-class 2 (alert fired, nobody looked). A small addition, not a full system:
any Ntfy notification tagged at `priority=high` (below the SMS threshold) that repeats N times for
the same host+check without being cleared gets promoted — either to `priority=5`/SMS, or to a daily
digest email that can't be as easily missed as a stream of individual Ntfy pushes. This is a
narrower, cheaper fix than A or B and would have caught the `grub-pc` case specifically (4
consecutive identical `apt upgrade FAILED` alerts, ignored) without needing any new detection logic
at all — the detection already existed, only escalation was missing.

### Option D — Periodic LLM-driven review, on top of A
Once Option A's mechanical sweep produces a real, regular data stream (systemd/dpkg state,
inventory diffs, UFW baselines), a second layer — a scheduled Claude Code session reading that
report plus recent memory/CLAUDE.md, reasoning about what's actually worth flagging (the judgment
class of check A explicitly can't do) — is the closer analogue to what "more JARVIS" actually
implies, versus A/B/C which are all conventional monitoring. Needs its own follow-up scoping once
A exists to feed it: whether this runs as a local scheduled session (same execution-location
constraint as A) or whether a narrower read-only report can safely be handed to a cloud routine
without needing live infra access itself.

---

## 4. Recommendation to react to

Option A is the highest-leverage first step — cheap, mechanical, and directly closes most of the
concrete gaps found this project has actually hit. Option C is small enough to bundle in alongside
it (same delivery mechanism, same Ntfy channel) and specifically fixes the "alert fired but was
invisible" failure mode, which is arguably the more embarrassing of the two gap types since the
detection work was already done. Option B is the more architecturally correct long-term answer but
a real scope increase to PN itself — worth its own follow-up scoping session once Option A is live
and has demonstrated which failure classes actually recur, rather than guessing the design now.
Option D is the genuinely "JARVIS" piece but depends on A existing first as its data source.

---

## 5. Open questions for Mr. Byrne

1. Start with Option A+C as a bundled first slice (deterministic sweep + alert escalation), or is
   Option B (extending PN's governance model fleet-wide) the actual destination worth designing
   toward directly, even if it's a bigger lift?
2. Target detection latency — the incidents above ranged from days to a month. Is nightly the right
   cadence for Option A's sweep, or would weekly be sufficient given the mechanical checks are
   comparatively cheap either way?
3. For Option A's UFW-baseline check: worth writing that baseline down now (as part of building the
   check) even though it only protects against *future* drift, not a retroactive guarantee the rest
   of the fleet is currently clean?
4. Is Option D (scheduled LLM-driven judgment review) something worth committing to in principle
   now, so Option A's sweep is designed with that consumer in mind from the start (e.g., structured
   output, not just free-text Ntfy lines) — or defer that decision until A is running?

---

## 6. Option B deep-dive — extending PN's Discovery model fleet-wide

Scoped 2026-08-19 at Mr. Byrne's direction, after Option A+C shipped (`fleet-health-sweep`, see
`claude-md/services-fleet.md`). Grounded in reading the real code
(`/opt/privatenexus/scripts/discovery-agent.sh`, `routes/discovery.js`, and the live `tenants`/
`workspaces`/`services`/`agent_tokens` tables on hot-pn) rather than inferring from the earlier
one-paragraph sketch in Section 3 — two things assumed there turned out to be wrong, corrected
above.

### 6.1 What Discovery actually is, verified live

- **Push, not pull.** `discovery-agent.sh` runs locally on a host, gathers `docker ps` + host facts
  (OS/kernel/uptime/mem/disk/WireGuard handshake) via a Python helper, and POSTs to
  `https://privatenexus.net/api/discovery/ingest` over HTTPS with a `Bearer` token. **PN's backend
  never reaches out to anything** — it only ever receives. This means extending Discovery fleet-wide
  does not require giving `privatenexus-backend` SSH or Docker-API access into sn-infra/sn-web/etc.,
  which is a materially smaller ask than the original Section 3 sketch assumed.
- **Auth is already per-source, not a single shared secret.** `/ingest` checks the bearer token
  against a real `agent_tokens` table (`tenant_id`, `label`, `token_hash`, `revoked`,
  `last_used_at`) — a legacy static-token fallback exists but is explicitly marked bootstrap-only.
  hot-pn's own agent already uses a real rotated DB token (`c951fffe...`, label "pn-vps
  discovery-agent.timer"). Issuing a distinct token per fleet host is already exactly how this table
  is designed to be used, not a new mechanism to build.
- **Real precedent already exists for a non-hot-pn host holding a PN agent token**: a second row,
  `label = "sn-security wazuh active-response"`, `last_used_at` 2026-08-11 — a different subsystem
  (Wazuh active-response for PN's Security Lockdown Mode, not Discovery), but it confirms
  `agent_tokens` is already treated as fleet-shared infrastructure, not something scoped exclusively
  to hot-pn's own discovery agent. Not investigated further — out of scope for this doc.
- **Only one tenant exists**: `tenants` has exactly one row, `house-of-trae`, with 4 workspaces
  already modeled — `infrastructure`, `business-systems`, `personal-services`, `monitoring`. The
  multi-tenant schema is designed for PN's eventual SaaS future, but *today* it is single-tenant in
  practice, and that one tenant's workspace model already anticipates exactly the kind of general
  fleet-inventory categories Option B would need. This meaningfully de-risks the "mixing HoT's
  internal ops into PN's own product data model" concern — there's no second tenant to blur
  boundaries with right now, and the schema already expected this shape of data.
- **Review flow is the direct candidate approve/reject route**, not the `action_requests`
  dual-control queue the Catalogue deploy flow uses (correction to Section 3 above) — a single
  `operator`-role approval, no second-approver requirement.

### 6.2 The real design fork this raises

Because Discovery is push-based, "extend it fleet-wide" has two genuinely different shapes,
not one:

**B1 — every host runs its own `discovery-agent.sh`, pushes directly to `privatenexus.net`.**
Literally what the name "extend fleet-wide" suggests: install the agent + issue a token on
sn-infra, sn-web, sn-monitor, sn-security, hot-bm-nl, hot-erp-nl, and the Gateway itself. Real cost:
today, sn-infra/sn-web/sn-monitor/sn-security are VLAN-internal VMs with **zero direct public
network involvement of their own** (network.md's key rule: "bare metal has zero public-facing
ports" — that rule is about inbound exposure, but B1 would still be the first time these specific
hosts *originate* real internal-topology data (container names, images, ports, memory/disk figures)
out over the public internet, authenticated by nothing stronger than a bearer token over TLS. That's
a new category of data leaving the VLAN mesh that doesn't exist today for these hosts, even though
outbound internet access itself is nothing new (they already reach the internet for apt/Docker
pulls). Real benefit: it's the most literal interpretation of Option B, and each host's data stays
fresh independent of any other host being reachable.

**B2 — the Gateway becomes the single discovery pusher, reusing its existing SSH reach (the same
reach `fleet-health-sweep` already uses) instead of every host gaining a new outbound path.** The
Gateway SSHes into each host (already established, already the fleet's admin-access pattern),
gathers the same facts `discovery-agent.sh` gathers today, and pushes one consolidated batch to
`/api/discovery/ingest` under a single Gateway-held token. No VLAN-internal host gains any new
outbound capability it doesn't already have; the only thing that changes is what the Gateway does
with data it can already collect (it's already collecting `/opt/stacks` listings for
`fleet-health-sweep`). Real cost: loses per-host push independence — if the Gateway's own sweep job
is broken or delayed, every host's Discovery data goes stale together, not independently; and it's
a small rewrite of `fleet-health-sweep.sh` to also format+push a Discovery-shaped payload rather
than just diffing locally, not zero-cost.

Either B1 or B2 still needs the same amount of new PN-side work (issuing/rotating tokens, deciding
which workspace new candidates default into, deciding whether `discovery_candidates`' completeness
scoring makes sense for non-Docker infra rows like the Gateway or hot-bm-nl itself) — the fork is
specifically about *where the collection happens and what leaves each host's network boundary*, not
about the PN-side review experience, which is identical either way.

### 6.3 Built, 2026-08-19 — Mr. Byrne chose B2

`fleet-discovery-push` (Gateway, `fleet-discovery-push.timer`, hourly at `:45`) now pushes Discovery
candidates for every fleet host except hot-pn (which keeps its own agent, offset to `:15` to avoid
both hitting the ingest endpoint at once). Two real bugs found and fixed before this could work
correctly, both live-verified:

1. **`discovery_candidates`' dedup index didn't include `host`** — `(tenant_id, source, raw_name)`
   only. Confirmed live before fixing: `watchtower` runs under that exact name on 6 of 8 fleet
   hosts, `promtail` on 5, `node-exporter` on 6 — without `host` in the key, the 2nd+ host's push
   would silently overwrite the 1st's candidate row, no error. Migrated to `(tenant_id, source,
   host, raw_name)`, updated `upsertCandidate()`'s `ON CONFLICT` clause to match, verified with a
   real same-`raw_name`-different-`host` test (`{"ok":true,"inserted":2}`, both rows persisted
   distinctly) before building the pusher.
2. **PN's approve handler sets `services.container_name = raw_name` whenever `runtime ===
   "docker"`**, assuming that means "reachable through PN's own Docker proxy" — true for hot-pn's
   own agent, false for every host this pusher covers, and hot-pn already runs its own container
   literally named `watchtower` too. Fixed by having the pusher always send `suggested_runtime:
   "external"` for docker-sourced candidates (a real, valid `runtime_type`) instead of `"docker"` —
   PN can see these, not act on them. `suggested_slug` is also host-qualified
   (`sn-web-watchtower`, not `watchtower`) so approving same-named services from different hosts
   doesn't 409 on `services.slug`.

Also fixed proactively while here: hot-pn's own `privatenexus-discovery-agent.timer` had the exact
same `OnBootSec`+`OnUnitActiveSec`-only wedge risk as the two Gateway timers fixed earlier the same
day (Section on Operational Rules, `gateway_timer_wedge_bug_2026_08_19` memory) — not yet actually
wedged, fixed before it could be. Verified live: dry-ran the new pusher against all 7 hosts, 69
candidates inserted, zero errors, zero cross-host collisions (spot-checked `watchtower` specifically
— 6 hosts, 6 distinct correctly-qualified rows). See `claude-md/services-hotpn.md` and
`option_b_discovery_scope_2026_08_19` memory.

### 6.3b Recommendation to react to (superseded — kept for the reasoning trail)

B2 is the more conservative, more consistent choice — it extends a pattern (Gateway SSHes into
every host) that's already the established trust boundary for this project (matches
`fleet-health-sweep`, `reboot-recovery-watchdog`, `fleet-memcheck.sh`, `apt-daily-update`'s own
per-host secrets model) rather than opening a new one (VLAN-internal hosts talking directly to a
public HTTPS endpoint) for hosts that have deliberately never done that before. B1 is more
architecturally "correct" in the sense of being the literal, most decoupled extension of Discovery's
existing design, and worth it if per-host independence (one host's data doesn't go stale because
the Gateway's own job had a bad night) turns out to matter more in practice than the network-
boundary conservatism argument above.

### 6.4 Open questions specific to Option B

1. ~~B1 or B2~~ **Decided 2026-08-19 — B2**, built same day (Section 6.3 above).
2. Should HoT's own fleet inventory really live inside PN's `services`/`discovery_candidates`
   tables at all (under the single existing `house-of-trae` tenant), or does treating "PN as a
   product" and "PN as HoT's own ops dashboard" as the same data model risk being an awkward mix
   once PN has a second real tenant — worth deciding now, or is "there's no second tenant yet, cross
   that bridge later" good enough?
3. If pursued, does this replace `fleet-health-sweep`'s own drift checks (Option A) with PN's
   Discovery UI as the one canonical place to review this, or run alongside it as a second, richer
   surface for the same underlying data — worth deciding to avoid two systems quietly drifting out
   of sync with each other.

---

## 7. Option D deep-dive — periodic LLM-driven judgment review

Scoped 2026-08-19 at Mr. Byrne's direction, after Options A/B2/C all shipped. This is the one
option that's genuinely "more JARVIS" rather than conventional monitoring — A/B2/C are all fixed
rules (a threshold, a diff, a streak counter); D is the layer that can actually reason about
*whether something matters*, the way this session has been doing by hand all day.

### 7.1 What the judgment gap actually looks like — concrete examples from today, not hypothetical

Every one of the following, found in this single session, required real investigation and judgment
a fixed check could not have produced:
- Reading the real `discovery-agent.sh`/`routes/discovery.js` code and discovering two wrong
  assumptions in Section 6's *own first draft* (push vs pull, which review queue) — a fixed check
  can verify a fact, not catch that an earlier written assumption was wrong.
- Noticing `reboot-recovery-watchdog.timer` said `enabled`/`active` while `NEXT` silently showed
  nothing — recognizing that mismatch as suspicious required knowing what a healthy timer's output
  *should* look like, not matching a pattern against a known-bad string.
- Realizing the fail-safe *for* that bug (`reboot-watchdog-healthcheck.sh`) had a completely
  unrelated failure mode (transient-unit non-persistence) that happened to share the same 6-day
  window — connecting two independently-caused outages because they overlapped in time.
- Predicting, before deploying `fleet-discovery-push`, that pushing real container names from
  multiple hosts would collide (`watchtower` on 6 hosts) and separately that it would create a
  cross-host `container_name` safety risk — neither was an error yet, both were foreseeable
  consequences of a design choice, caught by reasoning about the code path, not by anything failing.
- The previously-undocumented `nextcloud-personal` stack, and the stale `notesnook`
  `docker-compose.yml`-vs-live-container drift, both found earlier this session (see
  `pn_health_endpoint_gap_2026_08_19` memory) — neither is a "failure" by any mechanical
  definition (nothing is down, nothing errored), just quietly wrong in a way only cross-referencing
  multiple sources surfaces.

None of these are things `fleet-health-sweep`'s dpkg/systemd/wazuh/drift checks, or PN's Discovery
pipeline, could have been written to catch as fixed rules — they required reading code, correlating
unrelated signals, and knowing what "normal" looks like well enough to notice its absence.

### 7.2 The real design fork: where does D actually run

**D1 — local, headless `claude -p` on the Gateway, full local context.** A systemd timer (`OnCalendar`
from the start, per the Operational Rules entry from earlier today) runs the real `claude` CLI in
non-interactive mode, reading `fleet-health-sweep.log`, recent `journalctl` output, and the CLAUDE.md/
memory tree, then produces a judgment. This is the only design that can actually see what A/C
produce, since that data lives on the Gateway's local disk and (per the wg4/SSH/Tailscale constraint
already established for every other piece of automation in this doc) isn't reachable from a cloud
sandbox.

**Verified live, 2026-08-19, not assumed**: the `claude` CLI is already installed on this Gateway
(`/root/.local/bin/claude`, v2.1.235) and **runs headlessly without any interactive login** —
`claude -p "reply with exactly: OK"` returned `OK` immediately, unattended. The CLI also exposes
exactly the plumbing a safe scheduled invocation needs, confirmed via `--help`, not guessed:
`--allowedTools`/`--disallowedTools` for a tool allowlist, `--permission-mode dontAsk` for a
non-interactive run, `--output-format json` + `--json-schema` for structured, parseable output
instead of free text a wrapper script would have to interpret. This means D1 doesn't need
`--dangerously-skip-permissions` at all if the tool allowlist is kept to inherently-unprompted
read-only tools (`Read`, `Grep`, `Glob`) — there's nothing dangerous to skip a permission check for
in the first place.

**D2 — cloud-scheduled, narrow.** Using the existing `schedule` skill (a real, already-available
mechanism for cron-scheduled cloud Claude Code routines), reviewing only what's reachable over the
public internet — PN's `discovery_candidates`/`services` API at `privatenexus.net`. Lower
operational complexity (no Gateway-side systemd unit, no local auth/session concerns), but
structurally blind to everything A/C produce (the fleet-health-sweep log, journal state, UFW/stacks
drift) unless that data is separately re-published somewhere cloud-reachable — which is new scope
this doc doesn't otherwise call for. D2 is real but strictly narrower than D1, not a full substitute
for it.

These aren't mutually exclusive — D2's "review Discovery candidates" job is a plausible, small,
genuinely cloud-safe first task on its own regardless of whether D1 is ever built, since Discovery
candidates already need a judgment call an LLM is well-suited for (is this container safe to
approve, does its suggested category look right) that today just sits in a queue until a human
looks at it.

### 7.3 What D should actually be allowed to *do* — autonomy tiers

Every other piece of automation in this project stops short of autonomous mutating action without a
human step: `reboot-recovery-watchdog` escalates to hard power-cycle and then refuses to go further,
re-alerting instead of guessing; PN's Catalogue flow and Discovery both sit behind a real
human-approval queue, never auto-deploy/auto-merge; Wazuh's active-response is scoped, not open-ended.
D should match that posture, not be the first exception to it. Three tiers, increasing autonomy:

1. **Report-only** (recommended starting point): D reads, reasons, produces a structured digest,
   and a wrapper script decides whether to notify Mr. Byrne based on the structured
   `needs_attention` field — D itself never writes anything, never calls Ntfy directly, never
   touches infra. Lowest risk, matches the tool-allowlist design in 7.2 exactly (`Read`/`Grep`/`Glob`
   only).
2. **Memory-writer**: D is additionally allowed to write findings into the persistent memory system
   / propose a CLAUDE.md diff for a human to review — essentially an autonomous, scheduled version
   of the documentation work this session has been doing by hand all day (see 7.1's examples). Real
   step up in risk (write access to the project's own source-of-truth docs), but still nothing that
   touches live infrastructure.
3. **Actor**: D is allowed to take narrow remediation actions itself — e.g. approving a Discovery
   candidate that clearly matches an established safe pattern, or `reset-failed`ing a known-benign
   masked unit. This is the tier that would make D genuinely autonomous rather than advisory, and
   it's the one this doc does **not** recommend defaulting to, given the project's consistent
   precedent above — worth revisiting only after Report-only or Memory-writer has run long enough to
   show what its judgment actually looks like in practice.

### 7.4 Recommendation to react to

Start with **D1, Report-only, weekly** — matches the cadence of the old ad hoc "fleet health check"
sessions this whole doc set out to replace, keeps real LLM-invocation cost low (weekly, not nightly),
and has zero write/mutate capability so a bad judgment call costs nothing worse than a wasted Ntfy
notification or a wasted quiet week. D2 (cloud, Discovery-candidates-only) is a reasonable
independent add-on given how cheap it is (the mechanism already exists), not a dependency of D1.
Memory-writer is the natural next step once Report-only has run for a few weeks and its judgment
quality can be assessed against what this session has been doing manually — Actor stays off the
table barring a specific, narrow case Mr. Byrne wants to carve out deliberately later.

### 7.5 Built, 2026-08-19 — Mr. Byrne chose D1, Report-only, weekly

Answers 3 of the 4 open questions below directly (D1 not D2; Report-only not Memory-writer; weekly
not nightly); question 4 (does D need its own fail-safe from day one) was answered by building one
in from the start rather than waiting, given the project already re-learned that exact lesson twice
the same day on `reboot-watchdog-healthcheck.sh`.

`fleet-judgment-review.timer` (Sun 08:30) + `fleet-judgment-review-healthcheck.timer` (daily,
9-day staleness threshold) are both live — see `claude-md/services-fleet.md` for the full detail.
**First real run, same day, real cost paid (~$1.29, 165s), found something real**: it flagged a
genuine dating error in this same doc's own Section 6/CLAUDE.md's account of the
`reboot-recovery-watchdog` wedge bug (attributed to "the 2026-08-16 reboot," which doesn't reconcile
with the incident's own documented 6-day duration) — checked directly via `journalctl --list-boots`
and confirmed correct: an earlier, previously-unaccounted-for reboot (~Aug 13) actually triggered it.
Corrected in `claude-md/operational-rules.md`, `automated-patching.md`, `services-fleet.md`, and
`gateway_timer_wedge_bug_2026_08_19` memory. Its other first-run theory (stock `unattended-upgrades`
silently overriding `auto_reboot=false`) was checked and disproven directly — real, live validation
that the report-only design (flag for a human to verify, never assert unverified inference as fact)
works exactly as intended on its very first real use. See `option_d_judgment_review_scope_2026_08_19`
memory for the full trace.

**D2 attempted same day — built, tested live, and paused after hitting a real platform constraint
this doc didn't anticipate.** The plan (per 7.2/7.4) was a cloud-scheduled routine (the `schedule`
skill's `RemoteTrigger` mechanism) hitting a new read-only PrivateNexus endpoint over the public
internet. Built for real: `GET /api/discovery/review-export` on hot-pn (Bearer-token auth against
the existing `agent_tokens` table, reusing the same mechanism as `/ingest` — GET-only, structurally
incapable of approving/rejecting/mutating anything, verified live with a real 401 on a PATCH attempt
using the same token), plus a dedicated narrowly-scoped token ("cloud fleet-judgment-review D2",
`agent_tokens` row `72071272-...`). Verified working end-to-end from the public internet via `curl`
before touching the cloud side at all.

**The cloud routine itself could not reach it, and this is a real CCR sandbox limitation, not a
misconfiguration on either end**: a live test run's `curl` got a 403 on the CONNECT tunnel to
`privatenexus.net`; a second live test explicitly swapped in the `WebFetch` tool instead of
`Bash`/curl and got a structured `EGRESS_BLOCKED` error naming the domain directly. Both of the
sandbox's two plausible HTTP-capable tools independently confirmed the same thing: this environment's
default network egress policy allowlists only a curated set of hosts (package registries, `anthropic.com`,
RFC1918/Tailscale-style ranges, and whatever an attached MCP connector provides) — arbitrary public
internet hosts like `privatenexus.net` are blocked by default, with no field in `RemoteTrigger`'s
create/update body to widen it. This directly contradicts 7.2's original assumption that D2 would
have normal outbound HTTP access "using only what's reachable over the public internet" — that
assumption was wrong; being *public* doesn't make it reachable from this specific sandboxed
environment.

**Paused, not deleted** (routines can't be deleted via the API — see the `schedule` skill's own
note): `enabled: false`, renamed to flag the pause state, prompt replaced with a plain "don't run,
here's why" note in case it's ever manually re-enabled by accident. Left running would have meant a
guaranteed-fail Ntfy/email every single Monday forever for zero value — worse than not building it.
The PN backend endpoint and its token are harmless to leave in place (real, narrowly-scoped,
read-only capability — could still be useful for something else later) and were not rolled back.

**Two real paths forward if D2 is ever revisited, neither pursued without Mr. Byrne's direction**:
(1) check whether the CCR "Default" environment has a configurable egress allowlist somewhere in
`claude.ai` environment settings (no tool available to this session can read or change that,
only the routine's own `job_config` — which has no such field); (2) give up on a cloud routine
reaching PrivateNexus directly, and instead have D1 (which already has full local network access on
the Gateway) additionally read from PN's Discovery API itself and fold that into its existing weekly
report — which would fold D2's whole goal into D1 rather than keeping it independent, the opposite
of 7.2/7.4's original reasoning for keeping them separate. See
`option_d_judgment_review_scope_2026_08_19` memory for the full trace, including the exact error
payloads from both failed test runs.

**Notification-channel correction, same day**: the first build wired the routine's report output to
the Gmail MCP connector rather than House of Trae's own SMTP (`notifications@house-of-trae.com`,
Docker Mailserver) — reasoning at the time was narrowly about not embedding the shared Ntfy bearer
token into a routine config stored in Anthropic's own routine store, but that skipped the more
obvious point: this project uses its own self-hosted infra for everything, and email is already a
first-class alert channel here (see Alerting Architecture) — reaching for a third-party connector
instead doesn't fit that pattern. Corrected: the Gmail connector was detached from the paused
routine (`clear_mcp_connections`). If D2 is ever unblocked, the right default is HoT's own SMTP —
but note that's its own real credential-exposure decision (an SMTP account password embedded in a
cloud-hosted routine config) deserving the same explicit scrutiny the Ntfy token got, not an
automatic pass just because it's "the project's own" system, and untested whether the CCR sandbox's
egress policy even permits raw SMTP (port 587) to a non-allowlisted host at all — a second
reachability question to verify before assuming it works.

**Resolved same day: folded into D1, per Mr. Byrne's direction.** Of the two paths listed above,
Mr. Byrne chose (2) outright rather than spending more time on (1) — collapsing D2's goal into D1
rather than keeping them independent. Implementation: `fleet-judgment-review.sh` (the D1 wrapper
script, which has real Bash/network access even though the `claude` invocation it runs does not)
now also curls `GET /api/discovery/review-export` directly before invoking `claude`, saves it into
the same snapshot directory as `pn-discovery-review.json`, and the judgment prompt was extended with
D2's original review criteria (sensitive/unexpected candidates, duplicate-slug dedup-bug signals,
backlog age, low completeness scores, healthy-queue-not-actually-reviewed signals) verbatim. The
cloud routine (`trig_01GF7gT6Yk3RJJRdmWBPpAmF`) stays paused/disabled — it's now fully superseded,
not just blocked — its PN token and the backend endpoint it used are reused by D1's own fetch, not
duplicated.

**A real, separate bug was caught in the process of re-verifying this**: `fleet-judgment-review.service`
had no `PATH` set, and the `claude` binary only resolves via `/root/.local/bin`, which is not on
systemd's default minimal unit environment. The *original* D1 build's only verification had been via
an interactive shell (full login `PATH`) — the actual `systemctl start` trigger path was never
exercised until this fold-in change surfaced `claude: command not found` (exit 127) on a real test
run. This means the very first scheduled Sunday run would have silently failed the same way. Fixed
with an explicit `Environment="PATH=..."` line in the service unit. This is the same class of lesson
as the `OnCalendar` timer-wedge bugs earlier the same day: **verify via the actual trigger mechanism
a job will really fire through, not a proxy for it** (an interactive shell is not systemd; `bash -x`
by hand is not `systemctl start`).

**Verified end-to-end after the fix, via a real paid run through the actual systemd unit**: the
Discovery data fetched correctly, the judgment prompt reasoned over it correctly, and the run
surfaced something real and previously undocumented — an `nginx-certbot` container running directly
on the hot-bm-nl host itself (not inside any of its 4 VMs), verified live (not just relayed from the
LLM output) via direct SSH, `docker inspect`, and a real external-reachability check. See
`hardware.md`'s new section for the full finding (evidence points to this being Hostkey's own
provisioning tooling, not confirmed on their side or touched here) and
`option_d_judgment_review_scope_2026_08_19` memory for the complete trace of D2's cloud attempt, the
notification-channel and Vaultwarden corrections, the PATH bug, and this finding.

### 7.6 Open questions (for reference — answered above, kept for the reasoning trail)

1. ~~D1 vs D2~~ **Decided — D1**, built same day. D2 was also attempted same day — built, verified
   working server-side, but paused after confirming the cloud sandbox's default network egress
   policy blocks it from reaching `privatenexus.net` at all (see 7.5) — a real platform constraint,
   not a design choice.
2. ~~Report-only vs Memory-writer~~ **Decided — Report-only**, built same day.
3. ~~Weekly vs nightly~~ **Decided — weekly.**
4. ~~Does D need its own fail-safe from day one~~ **Decided — yes**, built in from the start
   (`fleet-judgment-review-healthcheck.timer`), not retrofitted after a gap.

---

## 8. Fleet-health-sweep addition — catalogue-deployed live-vs-approved binding drift (scoped 2026-08-20)

**Concrete trigger, not hypothetical.** Investigating a Nextcloud admin-password request 2026-08-20
found that hot-pn's Catalogue-deployed `nextcloud` container had been silently recreated
2026-08-11T03:27:23Z — about a day after its original approved+executed deploy
(`action_requests` row `78f8f3f2`, 2026-08-10 01:21 UTC, approved as `127.0.0.1:28142`) — rebound to
`10.10.2.2:28142` (the wg3 tunnel IP, genuinely reachable from the Gateway). No second
`action_requests` row exists for the change, and no origin could be traced (no shell history on
hot-pn, no local Claude Code project directory for either `root` or the `user` account). It sat
undocumented for 9 days until a 2026-08-19 session built a health check on top of the undocumented
binding without ever flagging the mismatch itself. Full trace:
`pn_nextcloud_binding_and_personal_cleanup_2026_08_20` memory.

**Why `fleet-health-sweep`'s existing checks didn't catch it.** Its `stacks-inventory` drift check
(`services-fleet.md`) only diffs `ls -1 /opt/stacks/` — directory *names* — on every stack host,
hot-pn included. `nextcloud`'s directory existed the whole time; only its container's runtime port
binding changed. Nothing in Option A/B/C/D as built today compares a Catalogue-deployed stack's
actual running config against what the governance flow (`action_requests`) says was approved — the
entire point of that propose→review→approve→execute flow is a WYSIWYG guarantee between what Mr.
Byrne approves and what runs, and this is the first confirmed case of it silently failing to hold.

**What the check would do**, added as a new block in `fleet-health-sweep.sh`, hot-pn only (the only
host running the Catalogue deploy flow):
1. Query `action_requests` for the most recent `status='executed'` row per `slug` where
   `action_type='service.provision_from_catalogue'` (via `ssh hot-pn "docker exec
   privatenexus-db psql -U privatenexus -d privatenexus -c ..."`, same pattern already used to
   investigate this incident).
2. Parse each row's `params->>'generated_compose'` (YAML) to extract the approved `ports:` binding
   per service — host IP, host port, container port.
3. For each service's real `container_name`, pull the live binding via `docker inspect <name>
   --format '{{json .HostConfig.PortBindings}}'` (ground truth — this is what actually decided the
   incident above, the on-disk `docker-compose.yml` copy is not reliably trustworthy, see finding
   above where it had also been silently rewritten to match the drifted state).
4. Compare. Any mismatch (host IP, host port, or a container that's vanished/been added) is a
   real finding.

**Report as a streak-based `report_check`, not a one-shot `report_drift` — this is the one
deliberate design choice worth calling out.** Every other drift check in `fleet-health-sweep`
(`stacks-inventory`, `ufw-rules`) reports a diff once and then *accepts the new state as the new
baseline* — correct for those, since "a new directory appeared" or "a UFW rule changed" isn't
inherently wrong, it just needs a human to notice and decide. A live-vs-approved-governance
mismatch is different in kind: the approved record is the source of truth by design, and silently
re-baselining against whatever's currently running would defeat the entire point of the check —
it would have accepted the 2026-08-11 rebind as fine forever, exactly the failure this is meant to
catch. So this check should behave like `systemd-failed`/`dpkg-audit`/`wazuh-agent`: fail every
night the mismatch persists, streak, escalate to `urgent`/SMS after `ESCALATE_AFTER` (3) consecutive
nights, and only clear when the live state is actually brought back in line with an approved
`action_requests` record (either by fixing the container, or — as happened with this incident — by
Mr. Byrne explicitly deciding to formalize the new state, which should itself go through a new
approved action, not just a doc edit, so the check has something to reconcile against).

**Built and live, 2026-08-20.** `/usr/local/bin/catalogue-drift-check.py` (deployed on hot-pn,
tracked in `hot-config/hot-pn/catalogue-drift-check/`) does steps 1-4 above — queries the DB via
`json_agg` rather than the base64 column originally sketched (Postgres's `encode(...,'base64')`
inserts a line break every 76 chars, which silently truncated every compose blob on first test —
JSON output escapes embedded newlines properly instead), then diffs live `docker inspect`
bindings against the approved compose. **Extended beyond the original sketch**: it tracks every
`container_name` in the approved compose, not just ones with a declared `ports:` — the first real
test run against hot-pn's actual `notesnook` stack found `notesnook-s3`/`notesnook-identity`/
`notesnook-sse` all published to `10.10.2.2` on their container-native ports despite having **no**
`ports:` entry at all in the approved compose (meant to stay internal-only) — a version of the
checker that only compared declared ports would have missed all three. `fleet-health-sweep.sh` now
calls it for hot-pn only and reports as `catalogue-binding-drift`, streak-based as designed above.

**Open question resolved during build**: a documented decision is sufficient to clear the check —
no fresh `action_requests` row required. Implemented as a git-tracked exceptions file,
`catalogue-drift-exceptions.conf` (same directory), one `slug:container:accepted_live_binding` line
per formalized case, each with an inline comment naming the memory/decision it traces to. Chosen
over requiring a synthetic `action_requests` insert because that would mean writing directly into
PN's live governance table outside its own app/API — a bigger, separately-worth-deciding step, not
a housekeeping default. The `nextcloud` case (see above) is currently the only entry.

**First real run, 2026-08-20 — found a second drift, resolved the same day after a real mistake
and a real (brief) production outage.** `nextcloud` correctly cleared (exceptions file match).
`notesnook` did not: 4 mismatches, `notesnook-s3`/`notesnook-identity`/`notesnook-sse` approved as
internal-only (no `ports:` at all) but live-published to `10.10.2.2`, plus `notesnook-sync`'s host
port itself drifted (`23683` approved vs `5264` live).

Asked Mr. Byrne to decide per-container, same pattern as `nextcloud`. **Initial assessment of 3 of
the 4 was wrong**: checked only PN's `services.health_endpoint` (references `notesnook-identity`
alone), concluded `s3`/`sync`/`sse` had "no known consumer," and reverted those three on that basis
— Mr. Byrne's answer ("revert the three unused ones") was correct given the information provided,
the information itself was incomplete. Caddy's live Caddyfile has real public site blocks
(`notes-sync`/`notes-sse`/`notes-s3.house-of-trae.com`) reverse-proxying directly to those exact
bindings, wired the same day (2026-08-11) as the container recreate — this was genuine, deliberate
production wiring, just never reflected back into the governance record or documented anywhere
(which is why the drift check flagged it as unexplained in the first place — the *governance* gap
was real, the *usage* gap was the mistaken part). The revert caused a real outage: `notes-sync`,
`notes-sse`, and `notes-s3.house-of-trae.com` all returned `502` for roughly 2-5 minutes, caught by
checking the live public URLs directly (not assumed) and fixed immediately by recreating all 3
containers back to their pre-revert configuration, replicating the exact `docker inspect` config
that was captured before touching anything. All 4 `notesnook` containers (including `identity`,
which was correctly identified as needing formalization from the start) are now in the exceptions
file together.

**A second, unrelated mistake happened re-verifying the fix.** Re-running `fleet-health-sweep.sh`
manually (twice, for testing) advanced the streak on an unrelated check —
`gateway/systemd-failed`, flagging `fleet-judgment-review.service` — from its real value of 1
(today's genuine 07:45 run) to 3, crossing `ESCALATE_AFTER` and firing a real
`priority=urgent`/SMS-triggering alert reporting "3 consecutive nights." The underlying bug
(`claude: command not found` under the real systemd trigger path, exit 127) had already been fixed
and verified via a direct script run 18 hours earlier (`fleet-judgment-review.log` shows the
very next invocation, 9 seconds later, succeeding cleanly) — but that verification ran the script
directly rather than through `systemctl start`, so the unit's own `Active: failed` state was never
cleared, and `systemctl --failed` kept reporting it as newly-failed on every sweep run since. Fixed
via `systemctl reset-failed fleet-judgment-review.service` + one more clean sweep run, which
correctly fired a `RECOVERED` notice. **Lesson for manually re-running `fleet-health-sweep.sh` for
testing in the future: it has real side effects on every host's real streak state, not just the
check being tested** — a stale-but-resolved `systemctl --failed` entry anywhere in the fleet can
get pushed past its escalation threshold by pure repetition, independent of whatever you're
actually testing.

Full trace of both incidents: `pn_nextcloud_binding_and_personal_cleanup_2026_08_20` memory.

---

## 9. Fleet-health-sweep addition — compose-vs-live drift, every host (scoped 2026-08-20)

**Why this is worth scoping, not just fixing hot-pn.** Section 8's check only covers hot-pn's
PrivateNexus Catalogue deploy flow, because that's the one place a formal "approved config" record
(`action_requests`) exists to diff against. But the underlying failure mode — a container's real
runtime config silently diverging from the file that's supposed to define it — isn't specific to
that governance flow. Every other host in the fleet deploys via plain `docker compose up -d`
against a `docker-compose.yml` in `/opt/stacks/<service>/`; nothing currently checks whether the
live container's actual `docker inspect` config still matches that file. `fleet-health-sweep`'s
existing `stacks-inventory` check only diffs directory *names*, same blind spot as before Section
8 — it would not have caught either the `nextcloud` or `notesnook` drift, and it wouldn't catch
the equivalent on any other host either.

**Real facts checked before scoping this, not assumed** (`ls`/`grep` across every host's
`/opt/stacks/`, 2026-08-20):
- **Three filename conventions in live use, not one**: `docker-compose.yml` (most hosts),
  `compose.yml` (Gateway's `caddy`, `powerdns`, `dockge`, `unbound`), `compose.yaml` (Gateway's
  `crowdsec`, `keycloak`, `mailserver`, `ntfy`, `oauth2-proxy`, `roundcube`, `sms-relay`,
  `stalwart`, `vaultwarden`, `gatus`). A checker must try all three per stack directory.
- **Two Gateway stack directories have no compose file at all** — `hostkey-api`, `tailscale-api`
  — not Docker services (systemd/script-based); must be skipped, not flagged as broken.
- **Most services declare an explicit `container_name:`** (confirmed: every stack on sn-web,
  sn-infra, sn-monitor, hot-erp-nl does), matching the assumption the hot-pn checker already
  relies on. **But not all** — real counterexample found: **`wazuh` on sn-security (3 services)
  declares zero `container_name:` lines** — a container-name-keyed parser (what Section 8's
  checker does) would have **zero coverage of Wazuh entirely**, silently. Wazuh in particular is
  too high-value a target (it already has its own documented history of process-vs-systemd-state
  mismatches, see `fleet_health_checks` memory) to leave uncovered by default. (Correction: the
  Gateway's `sms-relay`/`tor` were originally flagged here too, from a rough `grep -c
  'image:\|build:'` proxy count of 2 — false positive, both build **and** tag their own image in
  one service block, `image:`+`build:` together, so the "2" was really one service matched twice.
  Verified directly with the real parser below: both resolve to exactly 1 declared service each,
  no gap. Wazuh is the only confirmed real case.)

**What the check would do**, one new block in `fleet-health-sweep.sh`, all `STACK_HOSTS`:
1. For each `/opt/stacks/<service>/` directory, find its compose file (try all three names) and
   parse `container_name:`/`ports:` pairs the same way `catalogue-drift-check.py` does (regex,
   not a full YAML parser — same tradeoff, same justification). For services with no explicit
   `container_name:`, derive Compose's default name from the directory + service key as a
   fallback rather than skipping.
2. For each named container, pull the live binding via `docker inspect ... PortBindings` (same
   ground-truth approach as Section 8 — a stale/edited-but-not-reapplied compose file on disk is
   not a valid comparison target either way).
3. Compare. Track "no `ports:` at all" as `None`/unpublished the same way Section 8's checker
   does, for the same reason — the more severe drift direction (internal-only service quietly
   published) is exactly the kind Section 8's first real run found on `notesnook`, and there's no
   reason to expect it's confined to hot-pn.

**Report as a one-shot `report_drift`, not a streak-based `report_check` — the opposite call from
Section 8, and worth stating why explicitly.** Section 8's hot-pn check escalates because a real
governance record exists and is authoritative by design; silently re-baselining there would bless
an actual policy bypass. No such formal approval step exists for the general fleet's compose
files — a mismatch here just means "the file on disk doesn't describe reality," which is
ordinary config drift, the same category `stacks-inventory`/`ufw-rules` already handle as
one-shot diffs. Escalating it to `urgent`/SMS after 3 nights would be disproportionate for what is
usually going to be *someone forgot to update the compose file after a manual change*, not a
security-relevant bypass.

**The one lesson from Section 8 that must carry over regardless of report type**: today's real
outage happened because "no known consumer" was concluded from checking only one internal
reference (PN's `health_endpoint` field) without checking the thing that actually mattered
(Caddy's live config). Any drift this check reports — on any host — needs the same caution before
anyone "fixes" it by reverting: check the host's actual Caddyfile blocks (and anything else that
might reverse-proxy to it) for real consumers before assuming a mismatched binding is safe to
change, not just the one most-obvious internal reference. Worth stating directly in the
notification/runbook for this check, not left as tribal knowledge.

**Container-name resolution piece built and verified, 2026-08-20** —
`/usr/local/bin/compose-service-names.py`, deployed to all 7 `STACK_HOSTS` (tracked in
`hot-config/gateway/fleet-health-sweep/compose-service-names/`). Rather than reimplementing
Compose's default-naming algorithm from the spec, it asks the Docker daemon directly: every
container `docker compose` creates carries `com.docker.compose.project`/
`com.docker.compose.service` labels regardless of whether `container_name:` was set, so matching
on those labels is ground truth with no naming-scheme guesswork needed — one code path handles
both the "declared" and "compose-default" cases identically, rather than a normal-case-plus-a-special-
fallback. Parses the `services:` block specifically (stops at the next 0-indent top-level key —
found live that a naive "any 2-space-indented `key:`" match also catches `volumes:`'s own
top-level entries sitting at the same indent, e.g. Wazuh's file has 13 volume names right after
its 3 real services).

Verified against real multi-service stacks on every host, not just Wazuh: correctly resolves all 3
Wazuh services via the `compose-default` path (`wazuh.manager` → `wazuh-wazuh.manager-1`, etc.,
confirmed against live `docker ps`), and correctly resolves every `declared`-path stack tested
(`keycloak`, `powerdns`, `dickson` [7 services], `monitoring` [5 services], `forgejo`) with zero
mismatches. Along the way, captured real port-string formats the hot-pn-only parser never had to
handle — 2-part `"1514:1514"` (no host IP, implicit `0.0.0.0`), a `/udp` protocol suffix
(`"514:514/udp"`), and an explicit-IP 3-part form with protocol (`"0.0.0.0:53:53/tcp"`) — captured
verbatim rather than semantically parsed, correctly deferring the actual comparison logic (which
needs to understand these formats, not just store them) to whichever check eventually consumes this
script's output.

**Still not built**: the actual drift-comparison logic (step 2/3 above) that would call this script
and diff its output against live `docker inspect` bindings, and the `fleet-health-sweep.sh`
wiring. Running this from the Gateway (SSH out to every host, matching every other
`fleet-health-sweep` check) is fine as-is — checked whether shipping compose file contents over
SSH risked exposing secrets (grepped every Gateway compose file for
`PASSWORD`/`SECRET`/`TOKEN`/`API_KEY` outside the `*_FILE`/Docker-secrets pattern, 2026-08-20):
every hit is either a Compose top-level `secrets:` definition (points at a file, no literal value
in the compose file itself) or `${VAR}` shell interpolation, never a bare plaintext value. And this
check specifically only ever needs `ports:`/`container_name:` from the file and `PortBindings`
from `docker inspect` — it has no reason to ever touch `environment:` or `docker inspect`'s
`Config.Env` (which, unlike the compose file, *does* hold fully-resolved real secret values once a
container is actually running — confirmed while building the `notesnook` restore scripts in the
incident above). So the secrets concern doesn't actually constrain this design; noted here so a
future implementer doesn't have to re-derive it.
