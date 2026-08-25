#!/usr/bin/env bash
# jira-graph-sync.test.sh — tests for the LAB-1446 PostToolUse board-status sync.
#
# The hook is a SYNC, not a gate, so exit codes prove almost nothing (every path exits 0 by
# design). What matters is whether it DELIVERED to on-jira-transition and with what payload.
# So the real target is a stub standing in for that script via JIRA_GRAPH_TRANSITION_HOOK:
# it records the payload it was handed, and the assertions read that file.
#
# Every case is asserted in BOTH directions. A sync that only ever fires proves nothing —
# the control cases (reads, comments, non-gh commands) are the ones that matter, because
# #1446's criterion is explicitly "must not fire on reads or non-lifecycle commands".
#
# Run: bash .claude/hooks/tests/jira-graph-sync.test.sh

set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$HOOKS_DIR/jira-graph-sync.sh"
PASS=0
FAIL=0

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

SEEN="$SANDBOX/delivered.json"
STUB="$SANDBOX/on-jira-transition-stub"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
cat > "$STUB_RECORD"
exit 0
STUBEOF
chmod +x "$STUB"
export STUB_RECORD="$SEEN"
export JIRA_GRAPH_TRANSITION_HOOK="$STUB"

ok() { PASS=$((PASS + 1)); echo "  ok: $1"; }
no() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; [ -n "${2:-}" ] && echo "        $2"; return 0; }

run() { # $1 = payload; resets the record first
  rm -f "$SEEN"
  printf '%s' "$1" | bash "$HOOK" >/dev/null 2>&1
  echo $?
}

bash_payload() { # $1 = command
  CMD="$1" python3 -c '
import json, os
print(json.dumps({"tool_name": "Bash",
                  "tool_input": {"command": os.environ["CMD"]},
                  "tool_response": {}}))'
}

expect_delivered() { # $1 = label
  if [ -s "$SEEN" ]; then ok "$1"; else no "$1" "on-jira-transition was NOT called"; fi
}

expect_silent() { # $1 = label
  if [ -s "$SEEN" ]; then
    no "$1" "on-jira-transition WAS called with: $(cat "$SEEN")"
  else
    ok "$1"
  fi
}

expect_rc() { # $1 expected, $2 actual, $3 label
  if [ "$1" = "$2" ]; then ok "$3"; else no "$3" "expected rc=$1 got rc=$2"; fi
}

ITEM="PVTI_lAHOAM5y1M4BcqrUzg2t6LM"

# Board Status option ids are NOT stable — one `updateProjectV2Field` call reissues every one
# of them (measured 2026-08-25, LAB-1352). So no test here pins a real id: the suite seeds its
# own deliberately-fake table and asserts the hook resolves an id to the option NAME. A test
# that pins a live id is part of why the reassignment went unnoticed for as long as it did.
# A seeded table is also authoritative in the hook, so no case below can reach the network.
INPROG="deadbe01"
export HOMELAB_BOARD_STATUS_OPTIONS="deadbe01 In Progress
deadbe02 Backlog
deadbe03 Implementation Complete
deadbe04 Review Complete
deadbe05 Deferred
deadbe06 Done"

echo "== a gh board mutation FIRES the sync =="

RC="$(run "$(bash_payload "gh api graphql -f query='mutation{updateProjectV2ItemFieldValue(input:{projectId:\"PVT_kwHOAM5y1M4BcqrU\",itemId:\"$ITEM\",fieldId:\"PVTSSF_x\",value:{singleSelectOptionId:\"$INPROG\"}}){projectV2Item{id}}}'")")"
expect_rc 0 "$RC" "gh graphql board mutation exits 0"
expect_delivered "gh graphql board mutation delivers to on-jira-transition"

# The delivered payload must be shaped so on-jira-transition can act on it: it keys on the
# tool name, walks dict VALUES for a PVTI_ id and a Status option, and resolves repo+number
# from the item id. A payload missing either string is a silent no-op downstream.
if [ -s "$SEEN" ] && python3 - "$SEEN" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert "projects_write" in d.get("tool_name", ""), d.get("tool_name")
vals = list(d.get("tool_input", {}).values())
assert any(isinstance(v, str) and v.startswith("PVTI_") for v in vals), vals
# The status must be the resolved option NAME, never the id. An id forwarded downstream is a
# silent no-op the moment Projects v2 reissues it — which it does on any field edit.
assert "In Progress" in vals, vals
assert "deadbe01" not in vals, vals
PY
then ok "delivered payload carries tool_name=projects_write, the PVTI_ item id and the resolved option NAME"
else no "delivered payload carries tool_name=projects_write, the PVTI_ item id and the resolved option NAME" "$(cat "$SEEN" 2>/dev/null)"
fi

run "$(bash_payload "gh project item-edit --id $ITEM --field-id PVTSSF_x --single-select-option-id $INPROG --project-id PVT_kwHOAM5y1M4BcqrU")" >/dev/null
expect_delivered "gh project item-edit delivers"

echo "== the @file idiom that custom-fields.md prescribes =="

# An inline mutation string trips the worktree gate, so `-F query=@file.graphql` is the
# documented form. If the hook only read the command text it would miss every real board
# write made the way the docs tell you to make it.
QF="$SANDBOX/board.graphql"
cat > "$QF" <<GQL
mutation {
  updateProjectV2ItemFieldValue(input:{
    projectId:"PVT_kwHOAM5y1M4BcqrU", itemId:"$ITEM",
    fieldId:"PVTSSF_lAHOAM5y1M4BcqrUzhXRxK4",
    value:{singleSelectOptionId:"$INPROG"}}) { projectV2Item { id } } }
GQL
run "$(bash_payload "gh api graphql -F query=@$QF")" >/dev/null
expect_delivered "gh api graphql -F query=@file delivers (ids resolved from the file)"

echo "== option ids are resolved BY NAME, never trusted as literals (LAB-1352) =="

# The point of LAB-1352. `92510fdd` is a real, live board option id — and it is exactly what
# an id the local table has never seen looks like after a reassignment. It must NOT be
# forwarded: downstream maps ids through its own table, so an unknown id becomes a silent
# no-op write. Silence here is the correct behaviour, not a miss.
run "$(bash_payload "gh api graphql -f query='mutation{updateProjectV2ItemFieldValue(input:{itemId:\"$ITEM\",value:{singleSelectOptionId:\"92510fdd\"}}){projectV2Item{id}}}'")" >/dev/null
expect_silent "an option id absent from the table is NOT forwarded downstream"

# ...and the NAME path needs no table, no cache and no network at all. Same board mutation,
# with the status named in the query file the way an agent actually writes one.
QF2="$SANDBOX/board-named.graphql"
cat > "$QF2" <<GQL
# board: move to In Progress
mutation {
  updateProjectV2ItemFieldValue(input:{
    projectId:"PVT_kwHOAM5y1M4BcqrU", itemId:"$ITEM",
    fieldId:"PVTSSF_lAHOAM5y1M4BcqrUzhXRxK4",
    value:{singleSelectOptionId:"1a2b3c4d"}}) { projectV2Item { id } } }
GQL
SAVED_OPTS="$HOMELAB_BOARD_STATUS_OPTIONS"
export HOMELAB_BOARD_STATUS_OPTIONS=""
export HOMELAB_BOARD_OPTION_LOOKUP="off"
run "$(bash_payload "gh api graphql -F query=@$QF2")" >/dev/null
expect_delivered "a status spelled by NAME delivers with an empty table and the lookup disabled"
if [ -s "$SEEN" ] && grep -q "In Progress" "$SEEN"; then
  ok "the NAME wins over an unknown option id in the same haystack"
else
  no "the NAME wins over an unknown option id in the same haystack" "$(cat "$SEEN" 2>/dev/null)"
fi
export HOMELAB_BOARD_STATUS_OPTIONS="$SAVED_OPTS"
unset HOMELAB_BOARD_OPTION_LOOKUP

echo "== control cases: the sync must NOT fire =="

run "$(bash_payload "gh issue view 1490 --repo fredabood/homelab --json body")" >/dev/null
expect_silent "a gh issue READ does not fire the sync"

run "$(bash_payload "gh issue comment 1490 --repo fredabood/homelab --body hello")" >/dev/null
expect_silent "a gh issue COMMENT does not fire the sync (webhook CDC covers it in ~2s)"

run "$(bash_payload "gh issue close 1490 --repo fredabood/homelab --reason completed")" >/dev/null
expect_silent "a gh issue CLOSE does not fire the sync (issue_write matcher was dropped)"

run "$(bash_payload "gh issue create --repo fredabood/homelab --title t --body b")" >/dev/null
expect_silent "a gh issue CREATE does not fire the sync"

# THE discriminating control. The cases above are also stopped by the later "no item id"
# guard, so on their own they do not prove the VERDICT check does anything. Agents routinely
# quote board mechanics in issue comments, so a comment carrying a PVTI_ id and an option id
# is both realistic and the one command that reaches the synthesis step with everything it
# needs. It must still not fire: a comment is not a board mutation, and the webhook receiver
# already mirrors it in ~2 s.
run "$(bash_payload "gh issue comment 1490 --repo fredabood/homelab --body 'Moved to In Progress (option $INPROG, item $ITEM) via the board.'")" >/dev/null
expect_silent "a comment QUOTING a board item id + option id still does not fire the sync"

run "$(bash_payload "gh pr create --title t --body b")" >/dev/null
expect_silent "a gh PR command does not fire the sync"

run "$(bash_payload "gh api graphql -f query='{viewer{login}}'")" >/dev/null
expect_silent "a non-mutating graphql query does not fire the sync"

run "$(bash_payload "ls -la /tmp")" >/dev/null
expect_silent "a non-gh command does not fire the sync"

run "$(bash_payload "git status")" >/dev/null
expect_silent "a git command does not fire the sync"

# A board verdict with no resolvable item id is a downstream no-op; bail before spawning it.
run "$(bash_payload "gh project item-edit --help")" >/dev/null
expect_silent "a board-shaped command with no PVTI_ item id does not fire the sync"

echo "== other tool payloads =="

run '{"tool_name":"mcp__github__projects_write","tool_input":{"item_id":"'"$ITEM"'","status":"In Progress"},"tool_response":{}}' >/dev/null
expect_delivered "the MCP projects_write payload is passed through verbatim"

if [ -s "$SEEN" ] && grep -q "$ITEM" "$SEEN"; then
  ok "the passed-through MCP payload is unmodified"
else
  no "the passed-through MCP payload is unmodified" "$(cat "$SEEN" 2>/dev/null)"
fi

run '{"tool_name":"mcp__github__issue_write","tool_input":{"state":"closed","state_reason":"completed","repo":"homelab","issue_number":1}}' >/dev/null
expect_silent "mcp__github__issue_write does NOT fire (dropped: redundant, and it fabricated updated_at)"

run '{"tool_name":"mcp__github__issue_read","tool_input":{}}' >/dev/null
expect_silent "an MCP read tool does not fire the sync"

echo "== it never blocks =="

# A PostToolUse hook that exits non-zero turns a successful GitHub write into an apparent
# error. Assert exit 0 even when the sync target is missing or broken.
RC="$(JIRA_GRAPH_TRANSITION_HOOK="$SANDBOX/does-not-exist" run "$(bash_payload "gh api graphql -f query='mutation{updateProjectV2ItemFieldValue(input:{itemId:\"$ITEM\",value:{singleSelectOptionId:\"$INPROG\"}}){projectV2Item{id}}}'")")"
expect_rc 0 "$RC" "exits 0 when on-jira-transition is absent (submodule not checked out)"

BOOM="$SANDBOX/boom"
printf '#!/usr/bin/env bash\nexit 3\n' > "$BOOM"
chmod +x "$BOOM"
RC="$(JIRA_GRAPH_TRANSITION_HOOK="$BOOM" run "$(bash_payload "gh api graphql -f query='mutation{updateProjectV2ItemFieldValue(input:{itemId:\"$ITEM\",value:{singleSelectOptionId:\"$INPROG\"}}){projectV2Item{id}}}'")")"
expect_rc 0 "$RC" "exits 0 when on-jira-transition itself fails"

RC="$(printf '' | bash "$HOOK" >/dev/null 2>&1; echo $?)"
expect_rc 0 "$RC" "exits 0 on an empty payload"

RC="$(printf 'not json at all' | bash "$HOOK" >/dev/null 2>&1; echo $?)"
expect_rc 0 "$RC" "exits 0 on a malformed payload"

echo
echo "jira-graph-sync tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
