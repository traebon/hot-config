#!/bin/bash
# House of Trae — weekly LLM-driven judgment review (Option D1 of
# docs/HoT_Automation_Self_Healing_Scope.md Section 7, report-only tier, 2026-08-19).
#
# A/B2/C (fleet-health-sweep, fleet-discovery-push) are all fixed rules — a threshold,
# a diff, a streak counter. This is the layer that can actually reason about whether
# something matters: correlating unrelated signals, noticing when logs look normal but
# CLAUDE.md/memory suggest they shouldn't, catching the kind of thing this project's
# own incident history shows fixed checks keep missing (see Section 7.1 of the scope
# doc for 5 concrete examples from the same day this was built).
#
# Report-only, by design: the claude invocation below gets Read/Grep/Glob only — no
# Bash, no Edit, no Write, no SSH. It cannot verify anything live and is instructed not
# to claim to; its job is to flag what's worth a human (or a future session) checking,
# not to re-check things itself or touch anything. Every fact it reasons over is
# collected into a local snapshot BEFORE the claude invocation starts, by THIS script
# (which does have real network access, unlike the claude invocation itself) — mostly
# local Gateway files (fleet-health-sweep/fleet-discovery-push logs, local journalctl,
# systemd timer state), since A/B2/C already did that collection work and this only
# re-reads what they produced, plus one live pull: PrivateNexus's Discovery-candidate
# queue (formerly a standalone cloud routine, Option D2 — folded in here 2026-08-19
# after the cloud sandbox turned out unable to reach privatenexus.net at all; see the
# PN_REVIEW_URL section below).
set -uo pipefail

SNAPSHOT_ROOT="/var/lib/fleet-judgment-review/snapshots"
STATE_DIR="/var/lib/fleet-judgment-review"
REPORT_LOG="/var/log/fleet-judgment-review.log"
NTFY_URL="https://ntfy.house-of-trae.com"
NTFY_TOPIC="hot-alerts"
NTFY_TOKEN_FILE="/etc/apt-daily-update/ntfy_token"
LOOKBACK_DAYS=7
SCHEMA_FILE="/opt/hot-config/gateway/fleet-judgment-review/schema.json"

# Option D2 (a standalone cloud-scheduled routine reviewing PrivateNexus's
# Discovery-candidate queue) was built 2026-08-19 but paused the same day — the
# CCR cloud sandbox's default network egress policy blocks it from reaching
# privatenexus.net at all (confirmed via both curl and WebFetch). Folded into
# D1 instead, same day, at Mr. Byrne's direction: the Gateway already has real
# outbound network access, so this script just pulls the same read-only export
# directly. See docs/HoT_Automation_Self_Healing_Scope.md Section 7.5 and the
# option_d_judgment_review_scope_2026_08_19 memory for the full trace.
PN_REVIEW_URL="https://privatenexus.net/api/discovery/review-export"
PN_TOKEN_FILE="/etc/fleet-judgment-review-d2/pn_review_token"

mkdir -p "$SNAPSHOT_ROOT" "$STATE_DIR"

notify() {
  local priority="$1" title="$2" message="$3"
  [ -f "$NTFY_TOKEN_FILE" ] || return 0
  curl -fsS -m 10 -u ":$(cat "$NTFY_TOKEN_FILE")" \
    -H "X-Title: $title" -H "X-Priority: $priority" \
    -d "$message" "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1 || true
}

RUN_ID="$(date +%Y%m%d-%H%M%S)"
SNAPSHOT_DIR="$SNAPSHOT_ROOT/$RUN_ID"
mkdir -p "$SNAPSHOT_DIR"
cutoff="$(date -d "${LOOKBACK_DAYS} days ago" -Is)"

# --- collect: only local files/commands, nothing that needs SSH into the fleet ---
if [ -f /var/log/fleet-health-sweep.log ]; then
  awk -v cutoff="$cutoff" '$1 >= cutoff' /var/log/fleet-health-sweep.log > "$SNAPSHOT_DIR/fleet-health-sweep.log"
fi
if [ -f /var/log/fleet-discovery-push.log ]; then
  awk -v cutoff="$cutoff" '$1 >= cutoff' /var/log/fleet-discovery-push.log > "$SNAPSHOT_DIR/fleet-discovery-push.log"
fi

{
  echo "# fleet-health-sweep streak state (current, not time-filtered — small file, whole thing is useful)"
  for f in /var/lib/fleet-health-sweep/*.streak; do
    [ -e "$f" ] || continue
    echo "$(basename "$f"): $(cat "$f")"
  done
} > "$SNAPSHOT_DIR/streak-state.txt"

journalctl --since "${LOOKBACK_DAYS} days ago" --no-pager \
  -u fleet-health-sweep.service -u fleet-discovery-push.service \
  -u reboot-recovery-watchdog.service -u sn-infra-recovery-check.service \
  -u reboot-watchdog-healthcheck.service -u apt-daily-update.service \
  > "$SNAPSHOT_DIR/journal-recent.log" 2>/dev/null

systemctl list-timers --all > "$SNAPSHOT_DIR/systemd-timers-snapshot.txt" 2>/dev/null

# Former Option D2: pull PrivateNexus's Discovery-candidate queue directly (real
# outbound internet access, unlike the paused cloud routine). Read-only token,
# GET-only endpoint — this script never approves/rejects/mutates anything here,
# same report-only posture as the rest of this job.
pn_discovery_ok=false
if [ -f "$PN_TOKEN_FILE" ]; then
  if curl -fsS -m 20 -H "Authorization: Bearer $(cat "$PN_TOKEN_FILE")" \
      "$PN_REVIEW_URL" > "$SNAPSHOT_DIR/pn-discovery-review.json" 2>>"$REPORT_LOG"; then
    pn_discovery_ok=true
  else
    echo '{"ok": false, "error": "fetch failed - see fleet-judgment-review.log for this run"}' \
      > "$SNAPSHOT_DIR/pn-discovery-review.json"
  fi
else
  echo '{"ok": false, "error": "PN_TOKEN_FILE missing on this host"}' > "$SNAPSHOT_DIR/pn-discovery-review.json"
fi

cat > "$SNAPSHOT_DIR/README.txt" <<EOF
Snapshot for fleet-judgment-review run $RUN_ID, covering the last $LOOKBACK_DAYS days
(cutoff: $cutoff). Collected entirely from local Gateway files/commands — no SSH into
the fleet was performed for this review; fleet-health-sweep.log and
fleet-discovery-push.log already reflect whatever those two scripts found when they
ran (see hourly/nightly timers). Files:
  fleet-health-sweep.log       - drift/failure findings from the nightly sweep
  fleet-discovery-push.log     - hourly Discovery ingest results per host
  streak-state.txt             - current escalation streak per host/check (0 = healthy)
  journal-recent.log           - systemd journal for this project's own automation units
  systemd-timers-snapshot.txt  - current `systemctl list-timers --all` output (check for
                                  any NEXT showing "-" — the exact wedge-bug signature
                                  found and fixed 2026-08-19, see the Operational Rules
                                  entry on OnCalendar)
  pn-discovery-review.json     - PrivateNexus's Discovery-candidate queue (pending
                                  candidates + recently-registered services + status
                                  counts), fetched live via a read-only Bearer token
                                  (former Option D2, folded into this job 2026-08-19 —
                                  fetch ok: $pn_discovery_ok)
EOF

# --- judge: read-only claude invocation, structured output ---
PROMPT="You are reviewing House of Trae's fleet automation output for the past $LOOKBACK_DAYS days. \
Read every file in this directory (via the Read tool — you have Read/Grep/Glob only, no Bash/Edit/Write/SSH, \
so you cannot verify anything live; do not claim to have checked current state, only reason from what's in \
these files) plus /root/hot/CLAUDE.md and its claude-md/ imports for context on what's normal for this project. \
Your job is judgment, not re-detection — fleet-health-sweep and fleet-discovery-push already did the mechanical \
checking; don't just restate their findings. Look specifically for: (1) patterns across multiple log lines that \
suggest something systemic rather than isolated; (2) any streak in streak-state.txt approaching escalation \
(nonzero and climbing) worth flagging before it hits the 3-night threshold; (3) any timer in \
systemd-timers-snapshot.txt whose NEXT column shows '-' or looks wrong — this is the exact wedge-bug signature \
found and fixed 2026-08-19 (see claude-md/operational-rules.md), a recurrence anywhere is worth flagging even \
if that specific host/timer wasn't checked before; (4) discrepancies between what CLAUDE.md documents as true \
and what these logs actually show; (5) anything resembling a past documented incident's early signature. Do NOT \
flag routine items the mechanical system is already handling correctly (e.g. a streak that recovered to 0, a \
clean sweep with zero findings) — only flag what needs a human's judgment or a documentation update. \
\
Also read pn-discovery-review.json — PrivateNexus's Discovery-candidate queue (this used to be a separate cloud \
routine, Option D2, folded into this job because the cloud sandbox couldn't reach privatenexus.net; ignore it \
entirely if the file shows ok:false, that just means this week's fetch failed, not that the queue is empty). It \
has 'candidates' (all currently-pending Discovery candidates awaiting human review — fields include source, host, \
raw_name, raw_image, suggested_slug/name/category/access_mode/runtime/health_ep, completeness_score, \
discovered_at), 'recent_services' (the last 30 real registered services, for pattern context), and 'summary' \
(status counts). Apply the same judgment-not-restatement standard: (6) any candidate whose raw_name/raw_image \
looks sensitive or unexpected for this fleet's normal stack (Caddy/PowerDNS/Keycloak/Wazuh/Grafana/Prometheus/ \
Loki/ERPNext/PrivateNexus's own containers/Nextcloud/Notesnook/node-exporter/Promtail/Watchtower/host agents) — \
flag anything that doesn't fit; (7) any candidate whose suggested_slug looks like it duplicates something already \
in recent_services (points at a real dedup bug upstream); (8) a large or growing backlog, or candidates with an \
old discovered_at (multiple weeks) still pending — flag as 'someone should clear this queue' with a rough count \
and oldest date, not by listing every item; (9) low completeness_score on candidates that should obviously be \
well-identified (a well-known raw_image but null suggested_category/health_ep) — may point at a gap in how the \
hourly discovery-push script infers metadata; (10) anything in summary that looks like a healthy queue isn't \
actually being reviewed (e.g. approved/rejected essentially never happening while pending keeps growing). Do NOT \
flag routine, unremarkable candidates just because they exist — an ordinary backlog of normal House of Trae \
service containers is expected and not worth a line of the report. \
\
If nothing in any of these files warrants attention, say so plainly and set needs_attention to false — a \
genuinely quiet week is a valid, expected result, not a failure to find something."

SCHEMA="$(cat "$SCHEMA_FILE")"

result="$(claude -p "$PROMPT" \
  --add-dir "$SNAPSHOT_DIR" --add-dir /root/hot \
  --allowedTools "Read,Grep,Glob" \
  --permission-mode dontAsk \
  --output-format json \
  --json-schema "$SCHEMA" \
  2>>"$REPORT_LOG")"
run_status=$?

echo "$(date -Is) run $RUN_ID: exit=$run_status" >> "$REPORT_LOG"
echo "$result" >> "$REPORT_LOG"

if [ "$run_status" -ne 0 ] || [ -z "$result" ]; then
  notify high "fleet-judgment-review: run failed" "See $REPORT_LOG on the Gateway — the claude invocation itself failed or returned nothing (run $RUN_ID)."
  exit 1
fi

# --json-schema + --output-format json puts the validated payload directly at the
# top-level "structured_output" key (verified live 2026-08-19 — NOT nested inside the
# "result" string field, which also exists but is just the same thing pre-serialized).
structured="$(echo "$result" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    r = d.get("structured_output")
    if r is None:
        raise ValueError("no structured_output field in response")
    print(json.dumps(r))
except Exception as e:
    print(json.dumps({"needs_attention": True, "summary": f"parse error: {e}", "findings": []}))
')"

echo "$structured" > "$STATE_DIR/last-report.json"
date -Is > "$STATE_DIR/last-success"

needs_attention="$(echo "$structured" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("needs_attention", False))')"
summary="$(echo "$structured" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("summary", ""))')"

if [ "$needs_attention" = "True" ] || [ "$needs_attention" = "true" ]; then
  notify high "Weekly fleet review: needs attention" "$summary — full detail in $STATE_DIR/last-report.json on the Gateway."
else
  notify default "Weekly fleet review: quiet" "$summary"
fi

# Keep snapshots bounded — 8 weeks is plenty for a weekly job, avoid unbounded growth.
find "$SNAPSHOT_ROOT" -maxdepth 1 -mindepth 1 -type d | sort | head -n -8 | xargs -r rm -rf
