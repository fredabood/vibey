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

# ---------------------------------------------------------------------------------------
# BOARD STATUS OPTION IDS ARE NOT STABLE. Do not reintroduce a hardcoded list here.
#
# Measured 2026-08-25 (LAB-1352): adding a `Done` option to the Status field needs
# `updateProjectV2Field`, which is the only mechanism GitHub offers and which REPLACES the
# entire option list — every existing option id was reissued in that one call. The list that
# used to live on this line (093793f1 / 62ad3706 / 2eec8df1 / 0aa21637 / 087e34a4) died with
# it, and this hook would have gone quietly blind to every board write made by id.
#
# So detection is by option NAME, which is stable because a human authored it; an option id
# appearing in a GraphQL mutation is resolved to its name AT RUNTIME against the live field
# (cached, bounded, and entirely optional — failure means no sync, never an error). The
# payload handed downstream always carries the NAME, which on-jira-transition accepts
# directly, so this hook does not depend on that script's own id map either.
#
# This is the rule the n8n `ReconcileBoard` node has followed all along:
#   "Option ids are resolved BY NAME every run. `Done` is created live and Projects v2
#    reissues every option id on a board rebuild, so a hardcoded id would rot into a
#    silent no-op write."
# See `.claude/rules/custom-fields.md` § "Status options — the ids are NOT stable".
# ---------------------------------------------------------------------------------------

BOARD_OWNER="${HOMELAB_BOARD_OWNER:-fredabood}"
BOARD_NUMBER="${HOMELAB_BOARD_NUMBER:-1}"
OPTION_CACHE="${TMPDIR:-/tmp}/claude-board-status-options-${BOARD_OWNER}-${BOARD_NUMBER}.txt"
OPTION_CACHE_TTL_MIN=10

# The option table is "<option-id> <option name>", one per line. Sources, in order:
#   1. $HOMELAB_BOARD_STATUS_OPTIONS — pre-seeded; authoritative, and suppresses the network
#      path entirely (this is what the test suite uses, so no test pins a literal id).
#   2. a cache file younger than $OPTION_CACHE_TTL_MIN minutes.
#   3. one live `gh` read, cached. Only ever reached for a board mutation carrying an id we
#      cannot name — i.e. after a reassignment, which is exactly when it is worth paying for.
seeded_options() { printf '%s' "${HOMELAB_BOARD_STATUS_OPTIONS:-}"; }

cached_options() {
  [ -f "$OPTION_CACHE" ] || return 0
  [ -n "$(find "$OPTION_CACHE" -mmin "-$OPTION_CACHE_TTL_MIN" -print 2>/dev/null)" ] || return 0
  cat "$OPTION_CACHE" 2>/dev/null
  return 0
}

options_table() {
  SEEDED="$(seeded_options)"
  if [ -n "$SEEDED" ]; then printf '%s' "$SEEDED"; return 0; fi
  cached_options
}

# Run "$@" with stdout to $1 under a hard ~5s ceiling. A hook that hangs is worse than a
# stale mirror, and `timeout` is not on macOS.
run_bounded() {
  BOUND_OUT="$1"; shift
  : >"$BOUND_OUT" 2>/dev/null || return 1
  "$@" >"$BOUND_OUT" 2>/dev/null &
  BOUND_PID=$!
  ( sleep 5; kill -9 "$BOUND_PID" >/dev/null 2>&1 ) >/dev/null 2>&1 &
  BOUND_WATCHDOG=$!
  wait "$BOUND_PID" >/dev/null 2>&1
  BOUND_RC=$?
  kill "$BOUND_WATCHDOG" >/dev/null 2>&1
  wait "$BOUND_WATCHDOG" >/dev/null 2>&1
  return "$BOUND_RC"
}

PARSE_PY='
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
try:
    opts = d["data"]["user"]["projectV2"]["field"]["options"] or []
except Exception:
    raise SystemExit(1)
seen = 0
for o in opts:
    oid = (o.get("id") or "").strip()
    name = (o.get("name") or "").strip()
    if oid and name:
        print(oid + " " + name)
        seen += 1
if not seen:
    raise SystemExit(1)
'

refresh_options() {
  case "${HOMELAB_BOARD_OPTION_LOOKUP:-on}" in
    0|off|no|false|OFF|NO|FALSE) return 1 ;;
  esac
  [ -z "$(seeded_options)" ] || return 1
  command -v gh >/dev/null 2>&1 || return 1
  RAW="${OPTION_CACHE}.raw.$$"
  run_bounded "$RAW" gh api graphql -f query="query{user(login:\"$BOARD_OWNER\"){projectV2(number:$BOARD_NUMBER){field(name:\"Status\"){... on ProjectV2SingleSelectField{options{id name}}}}}}" || {
    rm -f "$RAW"
    return 1
  }
  python3 -c "$PARSE_PY" <"$RAW" >"${OPTION_CACHE}.tmp.$$" 2>/dev/null
  PARSE_RC=$?
  rm -f "$RAW"
  if [ "$PARSE_RC" -ne 0 ] || [ ! -s "${OPTION_CACHE}.tmp.$$" ]; then
    rm -f "${OPTION_CACHE}.tmp.$$"
    return 1
  fi
  mv -f "${OPTION_CACHE}.tmp.$$" "$OPTION_CACHE" 2>/dev/null || {
    rm -f "${OPTION_CACHE}.tmp.$$"
    return 1
  }
  return 0
}

# Synthesize the projects_write-shaped payload on-jira-transition expects. It walks nested
# dict VALUES looking for a `PVTI_` item id and a Status option name, then resolves the item
# id to repo+number over GraphQL — so supplying those two strings is sufficient, and it keeps
# this hook from duplicating that script's status→category mapping.
#
# The haystack is the command text plus any `query=@file` the command references, matching how
# gh-lifecycle.sh resolves the documented board-status idiom (an inline mutation string trips
# the worktree gate, so `-F query=@file.graphql` is what custom-fields.md prescribes).
#
# Exit codes: 0 = payload on stdout; 2 = an option-id-shaped token we cannot name, so the
# caller should refresh the table and retry; anything else = nothing to sync.
SYNTH_PY='
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

m = re.search(r"PVTI_[A-Za-z0-9_-]+", hay)
item = m.group(0) if m else ""

# Without an item id, on-jira-transition would exit 0 anyway. Bail before doing any work.
if not item:
    raise SystemExit(1)

# Option NAMES, longest first so "Implementation Complete" wins over "Complete". These are
# the stable identifiers; ids are not. Names are accepted anywhere in the haystack, which
# also covers forms that spell the status out.
NAMES = ["Implementation Complete", "Review Complete", "In Progress",
         "Backlog", "Deferred", "Done"]

status = ""
for n in NAMES:
    if n in hay:
        status = n
        break

if not status:
    table = {}
    for line in (os.environ.get("OPTION_TABLE") or "").splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2 and parts[0].strip() and parts[1].strip():
            table[parts[0].strip()] = parts[1].strip()
    ids = re.findall(r"\b[0-9a-f]{8}\b", hay)
    for i in ids:
        if i in table:
            status = table[i]
            break
    if not status and ids:
        raise SystemExit(2)

if not status:
    raise SystemExit(1)

print(json.dumps({
    "tool_name": "mcp__github__projects_write",
    "tool_input": {"item_id": item, "status": status},
    "tool_response": {},
}))
'

SYNTH="$(CMD="$CMD" OPTION_TABLE="$(options_table)" python3 -c "$SYNTH_PY" 2>/dev/null)"
SYNTH_RC=$?
if [ "$SYNTH_RC" -eq 2 ] && refresh_options; then
  SYNTH="$(CMD="$CMD" OPTION_TABLE="$(cat "$OPTION_CACHE" 2>/dev/null)" python3 -c "$SYNTH_PY" 2>/dev/null)"
  SYNTH_RC=$?
fi
[ "$SYNTH_RC" -eq 0 ] || exit 0
[ -n "$SYNTH" ] || exit 0

deliver "$SYNTH"
exit 0
