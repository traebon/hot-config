# PrivateNexus — Security Lockdown Mode Design
**Version: 1.0**
**Date: 30 July 2026**
**Owner: House of Trae / PrivateNexus Programme**
**Classification: Internal — Build Reference**
**Status: Scoped and locked in by Mr. Byrne — not yet built**

---

## Purpose

This document scopes PrivateNexus's Security Lockdown Mode — the v6.0 release-gate
item listed in `PrivateNexus_Release_Roadmap_v1.0.md` as "appears entirely unbuilt."
It is the implementation reference for building it — not a product vision document.
All decisions below were reviewed with Mr. Byrne on 2026-07-30 and are locked in,
not open for re-litigation without him.

---

## Current State (confirmed 2026-07-30, not assumed)

Verified directly against the live codebase and infrastructure before writing this
scope, not inferred from the roadmap text:

- **Zero lockdown-related code exists anywhere** in `hot-privatenexus` — no routes,
  no frontend, no DB tables, no `lockdown` string anywhere in `app/backend/src/` or
  `app/frontend/src/`. Fully greenfield.
- **Wazuh's `<active-response>` block on sn-security is the stock commented-out
  template** — nothing configured. Confirmed via `ossec.conf` on `wazuh-wazuh.manager-1`.
- **CrowdSec's LAPI is bound only to the Tailscale interface**
  (`100.106.41.10:8082:8080` in `/opt/stacks/crowdsec/compose.yaml`) — hot-pn has no
  network path to it today. Metrics port 6060 is separately bound to the WireGuard
  mesh (`10.10.0.1`), but that's metrics only, not the decision API.
- **What already exists and this build reuses, rather than reinventing:**
  - `action_policies` table (`elevation_required`, `cooldown_secs`, `max_per_hour`,
    `blast_radius_check`, `requires_approval`) — live schema confirmed on hot-pn's
    `privatenexus` DB, already has a seeded `emergency.stop-all` row
    (`elevation_required=superadmin`, `cooldown_secs=3600`).
  - `ROLE_LEVEL` hierarchy in `actions.js`: `viewer(0) < operator(1) < admin(2) <
    superadmin(3) < breakglass(4)` — `breakglass` already exists as a role, unused
    until this feature.
  - `CONTAINER_BLOCKLIST` (exported from `actions.js`) — `privatenexus-db`/`-redis`
    protection, already reused by `intelligence.js`'s remediation executor.
  - `recordAudit()` — audit trail helper used consistently across every other route
    file per the 2026-07-15/16 audit sweep.
  - `intelligence_signals` table and `detectSignals()` in `intelligence.js` — existing
    signal-detection pipeline this feature adds two new tiers on top of.
  - `agent_tokens` table — SHA-256-hashed bearer tokens, the existing pattern for
    machine-to-machine auth (currently used by the discovery-agent), reused here for
    Wazuh's webhook auth.
  - `POST /api/actions/emergency` (`stop-all` action) — the exact blast-radius/
    blocklist/cooldown logic Full tier reuses rather than reimplementing.

**No formal migration tooling exists in this repo** — every prior schema change this
year was applied as a one-off `INSERT`/`ALTER` run directly against the live DB, not
tracked as a versioned `.sql` file anywhere in git. This build should not perpetuate
that — see §6.

---

## Locked Decisions (2026-07-30)

These were open questions in the initial scope; Mr. Byrne reviewed the
recommendations and locked all four in as-is:

1. **CrowdSec LAPI network exposure**: bind an additional LAPI listener on
   `10.10.0.1` (WireGuard mesh), UFW-scoped narrowly to hot-pn's tunnel IP only
   (`10.10.2.2/32`) — matching the existing PowerDNS reachability pattern, not a
   blanket `10.10.0.0/16` rule. This is production automation traffic (PN calling
   CrowdSec to add a ban), not admin traffic, so it does not belong on Tailscale per
   CLAUDE.md's standing rule.
2. **Wazuh → PN integration direction**: **push**, not poll. Wazuh's active-response
   calls PN's webhook directly over the public internet (`https://privatenexus.net/...`)
   — no new WireGuard exposure needed for this leg, since it's a normal outbound
   HTTPS call from sn-security, same as any other egress traffic.
3. **Tier trigger thresholds**: concrete Wazuh rule-level cutoffs (see §2), Full tier
   has **no automatic trigger** — manual only, breakglass-gated.
4. **Full tier blast radius**: reuses `emergency.stop-all`'s exact existing logic
   (same `CONTAINER_BLOCKLIST` protection, same cooldown/elevation pattern), plus
   auto-enabling maintenance mode. No new blast-radius surface (e.g. no Caddy-level
   IP blocking in Full — that's Hard tier's job via CrowdSec, not duplicated here).

---

## 1. Tier Model

```
Alert  →  Soft  →  Hard  →  Full
(notify)  (throttle) (block+contain) (fleet stop)
```

Tiers are **monotonic escalation only** in this v1 — de-escalation is always a
manual action (see §4), never automatic, so a transient signal can't silently
self-clear a real incident.

### 1.1 Alert
- **Trigger**: Wazuh rule level ≥10 (push webhook), OR any `intelligence_signals` row
  at `severity='warning'` or higher.
- **Action**: no enforcement. Dashboard banner + existing Ntfy/email alert channels
  (reuses CLAUDE.md's documented alerting architecture, no new channel).
- **Auto-trigger**: yes.

### 1.2 Soft
- **Trigger**: Wazuh rule level ≥12 (sustained/likely-real pattern), OR
  `intelligence_signals` at `severity='critical'` persisting across 2+ consecutive
  scan cycles.
- **Action**: auto-enables maintenance mode (existing `maintenance.enable` action,
  already built and audited); tightens `action_policies` cooldowns fleet-wide by
  applying a temporary multiplier (config value, default 3x) to every enabled
  policy's `cooldown_secs` for the duration of the tier.
- **Auto-trigger**: yes.

### 1.3 Hard
- **Trigger**: Wazuh rule level ≥15, OR a correlated multi-rule pattern from the same
  source IP within a rolling 5-minute window (active-attack signature — exact
  correlation query to be finalized during build against real Wazuh rule IDs, not
  guessed here).
- **Action**:
  - CrowdSec range-ban via LAPI (`POST /v1/decisions`) against the offending
    source IP/CIDR, using the new `pn-lockdown` bouncer's API key.
  - `container.stop` against any non-blocklisted container flagged in the
    triggering signal, routed through the **existing** `actions.js` blast-radius
    check — this feature does not bypass that check, it calls into it.
- **Auto-trigger**: yes, but every container-stop this tier performs is still subject
  to the existing blast-radius/blocklist logic — Hard tier does not get a bypass.

### 1.4 Full
- **Trigger**: **none automatic.** Manual activation only, gated at `breakglass`
  role level (`ROLE_LEVEL.breakglass = 4`, the highest level, already defined and
  currently unused).
- **Action**: calls the existing `POST /api/actions/emergency` `stop-all` action
  directly (same `CONTAINER_BLOCKLIST`-respecting logic already live and audited),
  plus auto-enables maintenance mode.
- **System may recommend Full** (surfaced prominently on the dashboard when Hard
  tier fails to contain an ongoing signal) but never executes it — a human with
  `breakglass` clicks it.
- **MCP note**: MCP requests are synthesized with `roles: ["operator"]` (see
  `server.js`'s `X-MCP-Internal` middleware) — structurally below `breakglass`, so
  Full tier is **inherently unreachable via MCP** with no extra gating code needed.
  Worth stating explicitly so a future audit doesn't mistake this for a gap.

---

## 2. Data Model

New tables, to be written as a real versioned migration file (see §6), not another
ad-hoc live `INSERT`:

```sql
CREATE TABLE lockdown_state (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID REFERENCES tenants(id) ON DELETE CASCADE,
  tier            TEXT NOT NULL CHECK (tier IN ('none','alert','soft','hard','full')),
  activated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  activated_by    TEXT,              -- username, or 'system' for auto-triggers
  trigger_source  TEXT,              -- 'wazuh', 'intelligence_signal', 'manual'
  trigger_ref     TEXT,              -- Wazuh rule id / signal id, for traceability
  reason          TEXT,
  expires_at      TIMESTAMPTZ,       -- null = indefinite until manually cleared
  cleared_at      TIMESTAMPTZ,
  cleared_by      TEXT
);

CREATE TABLE lockdown_events (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  lockdown_id     UUID REFERENCES lockdown_state(id) ON DELETE CASCADE,
  event_type      TEXT NOT NULL,     -- 'tier_change','action_taken','action_failed'
  detail          JSONB,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

`lockdown_events` feeds a dashboard timeline; every row also gets a matching
`recordAudit()` call into the existing `audit_log` table — not a replacement for it.

---

## 3. API Surface

New routes in a new `app/backend/src/routes/lockdown.js`, following the existing
route-file conventions exactly (try/catch on every async handler — see the
`services.js`/`discovery.js` crash-risk lesson from the 2026-07-16 audit sweep,
`requireRole`/`requireAuth` gating, `recordAudit` on every mutation):

- `GET /api/lockdown/status` — current tier, active since, reason. `viewer`+.
- `GET /api/lockdown/history` — `lockdown_events` timeline. `viewer`+.
- `POST /api/lockdown/webhook/wazuh` — Wazuh active-response calls this. Auth via
  a dedicated `agent_tokens` row (`label: 'sn-security wazuh active-response'`),
  same bearer-token pattern as the discovery-agent, **not** the human session auth
  every other route uses.
- `POST /api/lockdown/escalate` — manual escalate to a specific tier. `operator`+
  for Alert/Soft, `admin`+ for Hard, **`breakglass` only for Full** (enforced the
  same way `actions.js` already gates `emergency.stop-all`).
- `POST /api/lockdown/clear` — de-escalate to `none`. `admin`+ (deliberately not
  `breakglass`-gated — clearing a false alarm shouldn't need the highest role, only
  *entering* Full does).

Internal (not routed, called by the tier-escalation logic):
- `applyCrowdSecBan(ip, durationSecs)` — wraps the LAPI call, in a new
  `crowdsecClient.js` alongside the existing `keycloak.js`/`pdns.js`-style external
  service clients already in the codebase.

---

## 4. Frontend

New "Lockdown" board (or a section on the existing Emergency board — **recommend a
new dedicated board**, since Emergency's existing UI is built around one-shot
fleet actions, not a persistent state machine with a visible current tier):
- Current tier banner (color-coded, matches existing severity color conventions
  from the Alerts board).
- Timeline of `lockdown_events`.
- Manual escalate/clear controls, each gated client-side by the same role check
  the backend enforces (defense in depth, not the actual gate).
- Full-tier escalate button only rendered for sessions with `breakglass` — mirrors
  how other role-gated UI elements already work (`can(minRole)` helper).

---

## 5. Infrastructure Changes Required

Concrete, sequenced list — this is real infra work, not just application code:

1. **CrowdSec**: `cscli bouncers add pn-lockdown` on the Gateway → new API key.
   Edit `/opt/stacks/crowdsec/compose.yaml` to add a second `ports` binding for the
   LAPI on `10.10.0.1` (a distinct port from the existing Tailscale one, to keep
   the two access paths clearly separable in `docker ps`/firewall rules).
   `ufw allow from 10.10.2.2/32 to any port <new-port>` on the Gateway.
2. **Wazuh**: write a real `<active-response>` block in `ossec.conf` plus a custom
   response script (bash, calling `curl` against PN's webhook with the new agent
   token) bound to the rule-level thresholds in §1. Needs a restart of
   `wazuh-wazuh.manager-1` to pick up config changes.
3. **PN**: new `agent_tokens` row for the Wazuh webhook (mirrors the discovery-agent
   token rotation already documented), new DB migration (§6), new route file,
   new frontend board.

---

## 6. Migration Tooling — a process fix bundled into this build

No prior schema change in this repo has a tracked migration file — everything was
applied as one-off SQL run directly against the live DB and never committed. This
build introduces the first one: `app/backend/migrations/0001_lockdown_tables.sql`
plus a `migrations/README.md` documenting how to apply it (`psql -f` against the
live DB, same connection details already used for every ad-hoc fix this session).
This does not retroactively migrate the other 22 existing tables — just stops the
pattern from getting worse on new schema going forward.

---

## 7. Build Sequence

1. Migration file + `lockdown_state`/`lockdown_events` tables (§2, §6).
2. `lockdown.js` route file — status/history/escalate/clear, no external
   integrations yet, manual-only tiers to prove the state machine and audit trail.
3. CrowdSec bouncer + network exposure (§5.1) + `crowdsecClient.js` + wire into
   Hard tier's escalate path.
4. Wazuh active-response block + webhook route + agent token (§5.2, §3) + wire
   into Alert/Soft/Hard auto-triggers.
5. Frontend board (§4).
6. MCP: read-only `pn_get_lockdown_status` tool only — no escalate/clear tool,
   consistent with Full tier's inherent MCP-unreachability and the general
   principle (established in the 2026-07-15 MCP audit) of not adding MCP write
   tools beyond what's already been deliberately scoped.
7. End-to-end test: force a real Wazuh alert (e.g. repeated bad SSH logins against
   sn-security) and confirm the full chain — rule fires → webhook → Alert tier →
   escalation logic → CrowdSec ban applied — the same "verify live, not just code
   review" standard used throughout this session's PN audit work.

   **Done 2026-08-01.** Real target ended up being the Gateway VPS, not
   sn-security — sn-security's manager doesn't monitor its own auth log at
   all (checked its `ossec.conf`, no sshd `<localfile>`), and the Gateway
   runs Wazuh's other real agent (`001`, native, not Docker). A genuine
   9-attempt SSH brute-force from another host in the fleet against the
   Gateway produced a real rule 5712 (level 10, brute-force correlation)
   alert, which drove the full real chain (rule → active-response dispatch
   → script → webhook → Alert-tier auto-escalation) end-to-end with no
   simulated input anywhere in the path. This also caught a real deployment
   gap (the AR script/token were only ever on the manager, not the
   agent that actually needed them — see [[pn_lockdown_mode_scope_2026_07_30]]
   for the fix). Soft/Hard tier's action logic (cooldown multiplier,
   maintenance window, CrowdSec ban) was **not** re-driven by a genuinely
   real level-12+/15+ Wazuh alert here — deliberately kept the live SSH test
   at the safe Alert-tier threshold rather than manufacture a real
   brute-force-to-successful-login pattern against production infrastructure
   just to reach Hard tier. Soft/Hard's own logic was already verified in
   step 4 through the real script and real webhook, using a realistic
   simulated alert payload piped into the actual deployed script — the only
   thing step 7 adds on top is proof that Wazuh's real detection layer
   itself (decoder → rule → active-response dispatch) genuinely fires and
   reaches that script, which nothing before step 7 had confirmed.

---

## Open Items Deferred to Build Time (not blocking scope sign-off)

- Exact Wazuh rule IDs for the Hard-tier correlation query — needs real rule-ID
  research against this Wazuh instance's actual ruleset, not guessable in advance.
- Cooldown-multiplier default (3x) for Soft tier is a starting proposal, tunable
  once real signal volume is observed.
- Whether Hard tier's CrowdSec ban duration should scale with signal severity or
  stay fixed — propose fixed (e.g. 4h) for v1, revisit once real data exists.
