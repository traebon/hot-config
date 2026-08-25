#!/bin/bash
# House of Trae — weekly refresh of the "Open Items" status artifact.
#
# Companion to fleet-judgment-review (Option D1) rather than a replacement: that job
# reasons over automation logs and flags what needs attention; this one keeps the
# human-facing status page (bugs/parked-decisions/roadmap) in sync with CLAUDE.md and
# memory so it doesn't silently go stale between sessions the way the 19 Aug -> 25 Aug
# gap did (see open_items_artifact_refresh memory).
#
# Same safety posture as D1 and for the same reason: the claude invocation below gets
# Read/Grep/Glob/Write only — no Bash/SSH — so it cannot verify anything live and is
# told not to claim to. It grounds every change in CLAUDE.md/claude-md/memory as they
# stand today, the same sources a human would check first.
#
# Known platform limitation, confirmed live 2026-08-25: the Artifact tool (needed to
# actually publish to claude.ai) is NOT available to a headless `claude -p` invocation
# — tested directly, it reports the tool doesn't exist in its tool list. So this job
# can only regenerate and stage the content; the actual publish step needs a live
# Claude Code session (interactive or a future one) to pick up the staged file and
# call Artifact with it. This mirrors the D2-cloud-egress wall found 2026-08-19 — a
# real platform boundary, not a bug to work around silently.
set -uo pipefail

STAGE_DIR="/opt/hot-config/gateway/open-items-refresh"
STAGED_FILE="$STAGE_DIR/latest.html"
PREV_FILE="$STAGE_DIR/.previous.html"
REPORT_LOG="/var/log/open-items-refresh.log"
NTFY_URL="https://ntfy.house-of-trae.com"
NTFY_TOPIC="hot-alerts"
NTFY_TOKEN_FILE="/etc/apt-daily-update/ntfy_token"
ARTIFACT_URL="https://claude.ai/code/artifact/58eedec2-cb24-47f3-ad44-eb7bde69d2dd"

mkdir -p "$STAGE_DIR"

notify() {
  local priority="$1" title="$2" message="$3"
  [ -f "$NTFY_TOKEN_FILE" ] || return 0
  curl -fsS -m 10 -u ":$(cat "$NTFY_TOKEN_FILE")" \
    -H "X-Title: $title" -H "X-Priority: $priority" \
    -d "$message" "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1 || true
}

if [ ! -f "$STAGED_FILE" ]; then
  notify high "open-items-refresh: not seeded" "No $STAGED_FILE on disk — this job expects to be seeded with the currently-published artifact HTML before its first run. Not touching anything."
  echo "$(date -Is) missing seed file, aborting" >> "$REPORT_LOG"
  exit 1
fi

cp "$STAGED_FILE" "$PREV_FILE"

export PATH="/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

PROMPT="You are refreshing a private ops status page for House of Trae infrastructure called \
'Open Items' — it tracks open bugs, decisions parked awaiting Mr. Byrne specifically, and roadmap \
status, grouped into sections (operating tone / actionable / parked / deferred / resolved / \
Phase 4 roadmap / PrivateNexus roadmap). \
\
Read the current staged file at $STAGED_FILE first — it is last week's version and your exact \
structural/design template (title, style block, div.wrap content — no other wrapper tags). \
Preserve its CSS, layout, and section structure exactly. Your job is ONLY to update CONTENT: item \
lists, chip statuses (open/progress/parked/deferred/fixed), the stat-strip counts and group-count \
badges, dates, and the resolved-items list. \
\
Ground every change in real, current sources — you have Read/Grep/Glob/Write only, no Bash/SSH, so \
you cannot verify anything live and must not claim to. Read: \
  /root/hot/CLAUDE.md and every file it imports under /root/hot/claude-md/ \
  /root/.claude/projects/-root-hot/memory/MEMORY.md and the individual memory files it indexes, \
    especially anything dated since the staged file's own 'refreshed' date \
Cross-reference claims against both sources before changing an item's status — CLAUDE.md and \
memory sometimes disagree or one is more current; where genuinely ambiguous, keep the item at its \
prior status and say so in its body text rather than guessing, matching how the existing content \
already hedges on the unresolved Gateway-reboot item. \
\
Move items between Actionable / Parked / Deferred / Resolved as their real status has changed \
since the staged version. Add newly-relevant items you find in CLAUDE.md/memory that aren't on the \
page yet. Never fabricate a resolution. \
\
Update the subtitle's 'refreshed <date>' line to today's date (you can get today's date from this \
prompt's own generation time context, or note it generically as 'this run' if genuinely unsure), \
and recompute the stat-strip counts and every group-count badge to match the actual list contents \
after your edits. \
\
Write the complete updated file back to $STAGED_FILE — same format as what you read (title, style, \
div.wrap content only, no markdown fences, no explanation before or after the file content itself \
in the file). \
\
After writing the file, your final response text (and ONLY this, nothing else) must be a plain \
prose summary under 150 words of what actually changed since the prior version: items resolved, \
items newly opened, items moved between sections, counts. If genuinely nothing changed, say so \
plainly rather than inventing churn."

SUMMARY="$(claude -p "$PROMPT" \
  --add-dir /root/hot --add-dir /root/.claude/projects/-root-hot/memory --add-dir "$STAGE_DIR" \
  --allowedTools "Read,Grep,Glob,Write" \
  --permission-mode dontAsk \
  2>>"$REPORT_LOG")"
run_status=$?

echo "$(date -Is) run: exit=$run_status" >> "$REPORT_LOG"
echo "$SUMMARY" >> "$REPORT_LOG"

if [ "$run_status" -ne 0 ] || [ -z "$SUMMARY" ]; then
  notify high "open-items-refresh: run failed" "See $REPORT_LOG on the Gateway — the claude invocation failed or returned nothing."
  cp "$PREV_FILE" "$STAGED_FILE"
  exit 1
fi

if ! grep -q "<title>" "$STAGED_FILE" 2>/dev/null || ! grep -q "class=\"wrap\"" "$STAGED_FILE" 2>/dev/null; then
  notify high "open-items-refresh: output looked wrong" "The regenerated file failed a basic sanity check (missing <title> or div.wrap) — reverted to last week's version, did not stage a broken file. See $REPORT_LOG."
  cp "$PREV_FILE" "$STAGED_FILE"
  exit 1
fi

if diff -q "$PREV_FILE" "$STAGED_FILE" >/dev/null 2>&1; then
  notify default "Open Items: no changes this week" "$SUMMARY"
else
  notify default "Open Items: refreshed, ready to publish" "$SUMMARY

Staged: $STAGED_FILE (tracked in hot-config git)
Still needs a live Claude Code session to actually publish — the Artifact tool isn't reachable from this headless job. Ask Claude to publish the staged refresh to: $ARTIFACT_URL"
fi
