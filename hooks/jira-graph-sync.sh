#!/usr/bin/env bash
# jira-graph-sync.sh — PostToolUse: keep the jira.* mirror's BOARD STATUS fresh (LAB-1446).
#
# THIS IS A SYNC, NOT A GATE. It must never block anything and never report failure: every
# path here exits 0. A PostToolUse hook that exits non-zero turns a successful GitHub write
# into an apparent error, which is strictly worse than a stale mirror.
#
# ---------------------------------------------------------------------------------------
# Why this exists at all — measured 2026-08-24, not assumed (#1446):
#
#   * A `gh` issue write (comment, edit, close, dependency, sub-issue) reaches the mirror in
#     1.5-3.5 s through the n8n `github-webhook-receiver`. That path is REPO-side, so it sees
#     `gh` and MCP writes identically. Nothing here is needed for it — and the old
#     `mcp__github__issue_write` registration was not merely redundant, it was harmful:
#     jira-graph's PATCH endpoint sets `updated_at = NOW()`, fabricating a local wall-clock
#     value over what is supposed to mirror GitHub's `issue.updated_at`. That matcher is
#     DROPPED. Do not re-add it.
#
#   * Board Status is the exception, and it is a big one. `projects_v2_item` webhooks have
#     NEVER fired — zero events in `jira.activity_log`, ever — because a USER-owned Projects
#     v2 board emits none (the event is organization-level). The receiver's LAB-1179 branch
#     for it is dead code. So board Status reaches the mirror by exactly two routes: the
#     10-minute `github-full-sync` sweep, and this hook. Measured staleness without it:
#     9 min 56 s for homelab#1490.
#
#   * A 10-minute SLA on the field the agent work queue keys on means TWO AGENTS CAN CLAIM
#     THE SAME ISSUE — an issue moved to In Progress via `gh` stays `Status=Backlog` in the
#     mirror, i.e. still queue-eligible, for up to ten minutes. This hook narrows that to
#     ~1 s. It does not fix it; the sweep interval is the real defect, tracked separately.
#
# Why a Bash matcher and not just the MCP one: a freshness guarantee that holds only for
# whichever tool path happens to be in use is the #1409 pattern. `gh` IS the path everything
# takes while the GitHub MCP server is disconnected.
# ---------------------------------------------------------------------------------------
#
# Bash 3.2-compatible (macOS ships 3.2.57).

set -u

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$HOOK_DIR/../.." && pwd)}"

# The sync target lives in the HOMELAB repo, not in this one — .claude is a submodule and is
# usable standalone. Absent target = nothing to do, and that is not an error.
TRANSITION_HOOK="${JIRA_GRAPH_TRANSITION_HOOK:-$PROJECT_DIR/submodules/jira-graph/bin/on-jira-transition}"

PAYLOAD="$(cat 2>/dev/null || true)"
[ -n "$PAYLOAD" ] || exit 0

TOOL="$(printf '%s' "$PAYLOAD" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("tool_name",""))
except Exception: print("")' 2>/dev/null || true)"

# $1 = payload to hand to on-jira-transition. Never propagates a failure.
deliver() {
  [ -x "$TRANSITION_HOOK" ] || return 0
  printf '%s' "$1" | "$TRANSITION_HOOK" >/dev/null 2>&1 || true
  return 0
}

case "$TOOL" in
  mcp__github__projects_write)
    # MCP path: on-jira-transition already understands this payload verbatim.
    deliver "$PAYLOAD"
    exit 0
    ;;
  Bash) ;;                     # fall through to classification
  *) exit 0 ;;
esac

CMD="$(printf '%s' "$PAYLOAD" | python3 -c 'import json,sys
try: print((json.load(sys.stdin).get("tool_input") or {}).get("command",""))
except Exception: print("")' 2>/dev/null || true)"
[ -n "$CMD" ] || exit 0

# Cheap pre-filter so the overwhelming majority of Bash commands never pay for the lexer.
# A board mutation is always a `gh` invocation.
case "$CMD" in
  *gh*) ;;
  *) exit 0 ;;
esac

# Classify with the SAME lib the three PreToolUse gates use (LAB-1425), so "what counts as a
# board write" has one definition. Only the `board` verdict proceeds: reads, comments, closes,
# edits, creates and non-lifecycle commands all fall through to exit 0.
LIB="$HOOK_DIR/lib/gh-lifecycle.sh"
[ -f "$LIB" ] || exit 0
# shellcheck source=/dev/null
. "$LIB" 2>/dev/null || exit 0

VERDICT="$(gh_lifecycle_parse "$CMD" 2>/dev/null | cut -d'|' -f1)"
[ "$VERDICT" = "board" ] || exit 0

# Synthesize the projects_write-shaped payload on-jira-transition expects. It walks nested
# dict VALUES looking for a `PVTI_` item id and a Status option id or name, then resolves the
# item id to repo+number over GraphQL — so supplying those two strings is sufficient, and it
# keeps this hook from duplicating that script's status→category mapping.
#
# The haystack is the command text plus any `query=@file` the command references, matching how
# gh-lifecycle.sh resolves the documented board-status idiom (an inline mutation string trips
# the worktree gate, so `-F query=@file.graphql` is what custom-fields.md prescribes).
SYNTH="$(CMD="$CMD" python3 -c '
import json, os, re, shlex

cmd = os.environ.get("CMD", "")
try:
    toks = shlex.split(cmd)
except ValueError:
    toks = cmd.split()

hay = cmd
for t in toks:
    ref = ""
    if t.startswith("query=@"):
        ref = t[len("query=@"):]
    elif t.startswith("-F") and "query=@" in t:
        ref = t.split("query=@", 1)[1]
    if not ref:
        continue
    try:
        if os.path.isfile(ref) and os.path.getsize(ref) <= 100_000:
            with open(ref, "r", errors="replace") as fh:
                hay += " " + fh.read()
    except OSError:
        pass

# Status option ids (.claude/rules/custom-fields.md). Names accepted too, for
# `gh project item-edit` forms that spell the status out.
OPTIONS = ["093793f1", "62ad3706", "2eec8df1", "0aa21637", "087e34a4"]
NAMES = ["Implementation Complete", "Review Complete", "In Progress", "Backlog", "Deferred"]

m = re.search(r"PVTI_[A-Za-z0-9_-]+", hay)
item = m.group(0) if m else ""

status = ""
for o in OPTIONS:
    if o in hay:
        status = o
        break
if not status:
    for n in NAMES:
        if n in hay:
            status = n
            break

# Without BOTH, on-jira-transition would exit 0 anyway. Bail here so the common case costs
# nothing rather than spawning the whole sync for a no-op.
if not item or not status:
    raise SystemExit(1)

print(json.dumps({
    "tool_name": "mcp__github__projects_write",
    "tool_input": {"item_id": item, "status": status},
    "tool_response": {},
}))
' 2>/dev/null)" || exit 0
[ -n "$SYNTH" ] || exit 0

deliver "$SYNTH"
exit 0
