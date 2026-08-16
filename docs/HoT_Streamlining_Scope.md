# House of Trae — Streamlining Scope

Scoping doc. Written 2026-08-16, following up on Mr. Byrne's 2026-08-11 flag (while wiring up
Notesnook's public domains) that the project has grown scattered — many hosts, many domains, a
large CLAUDE.md, a fast-growing memory index — and will need streamlining at some point. See
`project_streamlining_intent` memory for the original note.

Not a commitment to build/execute — a scope to react to and prioritize against.

---

## 1. What "scattered" actually looks like today (verified, not assumed)

| Area | Evidence |
|---|---|
| **CLAUDE.md** | 1,184 lines, single monolithic file covering network topology, 7+ hosts, backup architecture, alerting, SSO, Tor, PrivateNexus product state, and a 100+ line operational-rules table — all in one doc that gets fully loaded every session. |
| **Memory** | 51 individual memory files, MEMORY.md index already at 52 lines (near the 200-line truncation ceiling noted in the harness prompt). Mostly dated incident write-ups (`sms_alert_storm_investigation_2026_08_08`, `wazuh_agent_enrollment_2026_08_08`, etc.) — organized chronologically by when the work happened, not by the system it concerns. |
| **`docs/`** | 55 files, concrete redundancy: **5 stacked roadmap `.docx` versions** (v3.2 → v3.6) still sitting side by side even though only the highest is ever meant to be read; **16 `PrivateNexus_Security_Report_Tier4–19.md` files**, all superseded/closed per CLAUDE.md's own note ("all findings fixed, Tier 19 is final") but never archived; the Build Implementation Guide exists as **both `.docx` and a hand-extracted `.txt`**; 9 loose screenshots and 2 `.cer` files with no folder structure or naming convention tying them to what they document. |
| **Hosts** | Gateway VPS, hot-bm-nl (4 VMs: sn-infra/sn-web/sn-monitor/sn-security), hot-pn, hot-erp-nl — 7 real hosts, 10 SSH aliases, 6 WireGuard tunnels (wg0 decommissioned, wg1 personal, wg2 removed, wg3/wg4/wg5 live), each with its own `AllowedIPs`/UFW-rule history that's been individually widened piecemeal (documented inline in CLAUDE.md, not in one place). |
| **Domains** | 13 PowerDNS-managed zones across 7 group entities, plus `tresemme.space` left over from the retired Cosmos era with a dead-record cleanup history repeating itself (`tresemme.space` leftovers found+removed once, then the *same class* of leftover found again independently on `privatenexus.net` days later — a wildcard `A` record this time). No single documented policy for "which domain does a new service go under" — CLAUDE.md shows the reasoning being re-derived per incident. |
| **No IaC** | Every host is configured by hand, session-by-session. Config drift is caught by periodic audits/health-checks (2026-07-30, 2026-08-08, 2026-08-16 fleet sweeps), not prevented — this is very likely *why* the recurring "silently broken for N days, found by a sweep" pattern exists across backups, Wazuh agents, and alerting (see prior status summary this session). |

**Bottom line:** the scatter isn't imagined — it's the natural residue of ~2.5 months of
session-by-session, individually-justified growth, and it's now large enough that routine
decisions (which domain, which memory file already covers this, is this roadmap doc current)
require non-trivial re-derivation each time.

---

## 2. What "done" looks like

Not a single deliverable — four independent tracks, each individually shippable, roughly ordered
by effort-to-value:

1. **`docs/` cleanup** — ✅ **Done 2026-08-16.** Archived (not deleted — `/root/hot` isn't a git
   repo, so archiving keeps it recoverable): 4 superseded roadmap versions →
   `docs/archive/roadmap-versions/`, all 16 closed Tier4–19 security reports →
   `docs/archive/security-reports/`, the duplicate `.txt` build guide → `docs/archive/`. Loose
   files organized: 16 screenshots → `docs/screenshots/`, 2 `.cer` files → `docs/certs/`.
   Top-level `docs/` went from 55 files to 17 + 3 subfolders. CLAUDE.md's Documentation Library
   table updated to point at the new locations so it doesn't go stale.
2. **CLAUDE.md split** — ✅ **Done 2026-08-16.** Verified first (via the claude-code-guide agent,
   not assumed) that Claude Code supports `@path/to/file` imports, resolved relative to the
   importing file's own directory, up to 4 levels of nesting — confirmed real, so the physical
   split went ahead. **Note: imports still load in full at session start** — this is an
   organizational win (smaller, single-topic files to find/edit), not a context-size reduction.
   Split the 1,191-line monolith into a 124-line root `CLAUDE.md` (Identity, Documentation Library,
   Group Entities, Quick Reference) + 12 topic files under `claude-md/` (network, hardware,
   services-fleet, services-hoterp, services-hotpn, identity-dns-email, alerting-backups,
   automated-patching, operational-rules, checklists, tor, roadmap), each under the ~200-line
   target. Verified no content lost or duplicated by diffing the full header list before/after.
3. **Memory consolidation** — ✅ **Done 2026-08-16.** Read all candidate files first (not just
   filenames) to merge without losing the "why," per the note in `project_streamlining_intent`.
   Merged 19 date-named incident files into 9 topic-owned ones: `pn_catalogue_deploy_flow.md`
   (scope+phase1+phase2, 3→1), `crowdsec_fixes.md`, `caddy_fixes_2026_08_09.md`,
   `fleet_health_checks.md`, `pn_monitoring_stale_targets_2026_08_09.md`, `tailscale.md`,
   `keycloak.md`, `gatus_monitoring.md`, and `grafana_alerting_bugs.md` (the exact
   execErrState/SQLite-lock pairing this line originally proposed as the example). Fixed every
   `[[cross-reference]]` in the remaining files that pointed at a merged-away name. Memory file
   count dropped 51 → 41; `MEMORY.md`'s index dropped 52 → 42 lines, comfortably under the 200-line
   truncation ceiling. **Deliberately left unmerged**: per-VM rebuild memories (one per VM is
   already the right granularity) and large standalone sagas (`hostkey_server_replacement.md`,
   `open_items_2026_07_27.md`) that are already internally organized and would only get harder to
   navigate if merged into something bigger.
4. **A documented domain-assignment policy** — ✅ **Done 2026-08-16.** Added a "Domain Assignment
   Policy" section directly in CLAUDE.md's Group Entities & Domains section (loaded every session,
   not buried in `docs/`), a 5-rule priority order: client-facing entity sites → their own domain;
   admin/infra tooling → `securenexus.net` unless it's gated by the shared generic `import sso`
   wall, which has a hard technical constraint to `house-of-trae.com` (the oauth2-proxy callback is
   fixed there — this exact bug already broke `monitor`/`prometheus.securenexus.net` once, see
   `caddy_fixes_2026_08_09` memory); PrivateNexus product surface → `privatenexus.net`, explicitly
   not a personal-services dumping ground (root cause of the wildcard-`A`-record incident); personal
   services → no default domain until actually scoped; parent/shared infra → `house-of-trae.com`.
   Also added a decommission rule (delete DNS records same day a service is torn down) since the
   same dead-record gap recurred independently on two different domains weeks apart.

**Deliberately out of scope for this pass:** IaC (Terraform/Ansible) is already tracked
separately under Phase 4 and is a much larger undertaking (rewriting how every host is actually
configured, not just how it's documented) — this scope is about the *documentation and memory*
surface, not the infrastructure-as-code gap. Worth flagging that IaC would structurally prevent
the "silently drifted, caught by sweep" pattern in a way that better docs alone cannot — but that's
a separate, larger decision for Mr. Byrne to make deliberately, not a byproduct of a docs cleanup.

---

## 3. Status: all 4 tracks done (2026-08-16)

Mr. Byrne prioritized all four in order (1→2→3→4) across the same session. Each open question above
got resolved through execution rather than left as a standing decision:

- **Priority/order** — ran sequentially, no blocking dependencies between tracks as predicted.
- **CLAUDE.md split** — confirmed real via the claude-code-guide agent before committing to it
  (`@path` imports exist, 4-level nesting, resolved relative to the importing file) — see track 2.
- **Archive vs. delete** — archived, not deleted, specifically because `/root/hot` still isn't a
  git repo (unchanged by this pass) — deletion would have been unrecoverable.
- **Memory merge granularity** — merged strictly by system/topic (the CrowdSec/Caddy/Grafana/etc.
  pairs), not into broad "closed incidents" buckets — kept the one-off sagas
  (`pve_node_rename_attempt`, `hostkey_server_replacement`) standalone rather than diluting them
  into a catch-all.

**Remaining item, explicitly deferred, not forgotten**: `/root/hot` still isn't a git repo — this
was flagged as "itself arguably part of the scatter" in track 1's own open question and wasn't in
scope for this pass. Worth raising as its own decision if it comes up again, not assumed here.

**Not reopened**: IaC (Terraform/Ansible) — still deliberately out of scope, per §2 above.
