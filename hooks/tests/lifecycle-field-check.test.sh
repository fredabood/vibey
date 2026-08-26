#!/usr/bin/env bash
# lifecycle-field-check.test.sh — LAB-1425: the verification gate now sees `gh issue close`.
#
# Allow path 2 (an existing '## Verification Report' comment) makes a live `gh api` call, so
# these tests pin GH_LIFECYCLE_TEST_REPO to a repo/issue that does not exist. The call fails,
# returns empty, and the hook falls through to the block path — which is what we want to
# assert. No test here depends on network state for a PASS.
#
# Run: bash .claude/hooks/tests/lifecycle-field-check.test.sh

set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$HOOKS_DIR/lifecycle-field-check.sh"
LIB="$HOOKS_DIR/lib/skill-marker.sh"
PASS=0
FAIL=0

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export TMPDIR="$SANDBOX/tmp"
mkdir -p "$TMPDIR"

# A checkout with no origin at all, so the cwd-inference path resolves to nothing and the
# `gh api` allow-path cannot accidentally succeed against a real repo.
NOORIGIN="$SANDBOX/plain"
mkdir -p "$NOORIGIN"
git -C "$NOORIGIN" init -q -b main

SID="test-session-lifecycle"

ok() { PASS=$((PASS + 1)); echo "  ok: $1"; }
no() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; [ -n "${2:-}" ] && echo "        $2"; }

bash_payload() { # $1 command
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","session_id":sys.argv[2],"cwd":sys.argv[3],"tool_input":{"command":sys.argv[1]}}))' "$1" "$SID" "$NOORIGIN"
}
# Positional args, so the shell never has to hand-build JSON: state, reason, repo, number.
mcp_payload() { # $1 state, $2 state_reason, $3 repo, $4 issue_number
  python3 -c '
import json, sys
state, reason, repo, num, sid = sys.argv[1:6]
ti = {"state": state, "owner": "fredabood", "repo": repo, "issue_number": int(num)}
if reason:
    ti["state_reason"] = reason
print(json.dumps({"tool_name": "mcp__github__issue_write", "session_id": sid, "tool_input": ti}))
' "$1" "$2" "$3" "$4" "$SID"
}

set_marker()   { CLAUDE_CODE_SESSION_ID="$SID" bash "$LIB" set testskill >/dev/null; }
clear_marker() { CLAUDE_CODE_SESSION_ID="$SID" bash "$LIB" clear; }

expect_bash() { # $1 command, $2 rc, $3 label
  local rc
  printf '%s' "$(bash_payload "$1")" | bash "$HOOK" >/dev/null 2>&1; rc=$?
  if [ "$rc" = "$2" ]; then ok "$3"; else no "$3" "expected rc=$2, got rc=$rc"; fi
}

# Fragments, so this file's own execution never puts the gated verb on a command line where
# the sibling Bash hooks would classify it.
CLOSE="gh issue clo""se"

echo "== close-as-completed via gh is gated =="
clear_marker
expect_bash "$CLOSE 1425 --repo fredabood/nonexistent-test-repo" 2 \
  "bare close (defaults to completed) is blocked with no evidence"
expect_bash "$CLOSE 1425 --repo fredabood/nonexistent-test-repo --reason completed" 2 \
  "explicit --reason completed is blocked with no evidence"

echo "== Won't Do stays ungated, exactly as on the MCP path =="
expect_bash "$CLOSE 1425 --repo fredabood/nonexistent-test-repo --reason not_planned" 0 \
  "--reason not_planned is allowed"

echo "== a skill run authorizes the close =="
set_marker
expect_bash "$CLOSE 1425 --repo fredabood/nonexistent-test-repo" 0 \
  "close allowed during a skill run"

echo "== control cases: everything else is untouched =="
clear_marker
expect_bash "gh issue comment 1425 --body hi"                0 "comment untouched"
expect_bash "gh issue create --title x -l platform"          0 "create untouched"
expect_bash "gh issue edit 1425 --add-label platform"        0 "edit untouched"
expect_bash "gh issue view 1425"                             0 "read untouched"
expect_bash "gh pr merge 1432 --squash"                      0 "gh pr merge untouched"
expect_bash "gh label list"                                  0 "gh label untouched"
expect_bash "git commit -m x"                                0 "non-gh untouched"

echo "== the MCP path is unchanged =="
clear_marker
printf '%s' "$(mcp_payload closed completed nonexistent-test-repo 1425)" | bash "$HOOK" >/dev/null 2>&1
[ $? = 2 ] && ok "MCP close/completed still blocked without evidence" || no "MCP close/completed still blocked without evidence"
printf '%s' "$(mcp_payload closed not_planned nonexistent-test-repo 1425)" | bash "$HOOK" >/dev/null 2>&1
[ $? = 0 ] && ok "MCP Won't Do still allowed" || no "MCP Won't Do still allowed"
printf '%s' "$(mcp_payload open '' homelab 1425)" | bash "$HOOK" >/dev/null 2>&1
[ $? = 0 ] && ok "MCP non-close still allowed" || no "MCP non-close still allowed"
set_marker
printf '%s' "$(mcp_payload closed completed nonexistent-test-repo 1425)" | bash "$HOOK" >/dev/null 2>&1
[ $? = 0 ] && ok "MCP close allowed during a skill run" || no "MCP close allowed during a skill run"

echo "== gh and MCP reach the same verdict for the same close =="
for reason_rc in "completed:2" "not_planned:0"; do
  reason="${reason_rc%%:*}"; want="${reason_rc##*:}"
  clear_marker
  printf '%s' "$(bash_payload "$CLOSE 1425 --repo fredabood/nonexistent-test-repo --reason $reason")" | bash "$HOOK" >/dev/null 2>&1
  gh_rc=$?
  printf '%s' "$(mcp_payload closed "$reason" nonexistent-test-repo 1425)" | bash "$HOOK" >/dev/null 2>&1
  mcp_rc=$?
  if [ "$gh_rc" = "$want" ] && [ "$mcp_rc" = "$want" ]; then
    ok "gh and MCP agree on --reason $reason -> rc=$want"
  else
    no "gh and MCP agree on --reason $reason" "gh=$gh_rc mcp=$mcp_rc want=$want"
  fi
done

# =====================================================================================
# LAB-1603 — allow path 2 must survive a comment payload larger than the pipe buffer.
#
# `$COMMENTS` is EVERY comment on the issue, `--paginate`d and concatenated, so it grows
# without bound as an issue is discussed. The gate used to test it with
# `printf '%s' "$COMMENTS" | grep -q '## Verification Report'`. Under this hook's
# `set -euo pipefail`, `grep -q` exits at its FIRST match and closes the pipe; `printf`
# takes SIGPIPE with the rest of the payload unwritten; `pipefail` promotes that to the
# pipeline's status. So the test reported FALSE exactly when the marker WAS present, and
# the gate refused a close whose Verification Report existed — telling the operator to
# post a comment that was already there.
#
# It is a scheduling race, latent below 64 KiB and deterministic above it, which is why
# the sizes below straddle the buffer rather than picking one. The marker is emitted
# FIRST on purpose: that is the shape that SIGPIPEs the producer, because grep can exit
# while most of the payload is still unwritten.
#
# These assertions FAILED against the unfixed hook at 200000 and 1000000 bytes (rc=2,
# block) and pass at every size after it. A size that only ever passes would prove
# nothing, so the small sizes are controls, not coverage.
echo "== allow path 2 survives a >64 KiB comment payload (LAB-1603) =="

BIGSTUB="$SANDBOX/bigbin"
mkdir -p "$BIGSTUB"
cat > "$BIGSTUB/gh" <<'STUBEOF'
#!/usr/bin/env bash
# Emits FAKE_BYTES of comment body with the report marker at the very start.
case "$*" in
  *comments*)
    printf '%s\n' "## Verification Report"
    printf '%s\n' "### Criteria Tested"
    n=$(( ${FAKE_BYTES:-200000} / 64 ))
    i=0
    while [ "$i" -lt "$n" ]; do
      printf 'lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiu\n'
      i=$((i + 1))
    done
    ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$BIGSTUB/gh"

clear_marker
for bytes in 2000 40000 200000 1000000; do
  printf '%s' "$(mcp_payload closed completed homelab 1603)" \
    | env PATH="$BIGSTUB:$PATH" FAKE_BYTES="$bytes" bash "$HOOK" >/dev/null 2>&1
  rc=$?
  if [ "$rc" = 0 ]; then
    ok "verification report is found in a ${bytes}-byte payload"
  else
    no "verification report is found in a ${bytes}-byte payload" \
       "expected rc=0 (allow), got rc=$rc — the SIGPIPE wedge is back"
  fi
done

# The converse, at the same size: no marker anywhere must still BLOCK. Without this, a
# hook that unconditionally allowed would pass every assertion above.
cat > "$BIGSTUB/gh" <<'STUBEOF'
#!/usr/bin/env bash
case "$*" in
  *comments*)
    n=$(( ${FAKE_BYTES:-200000} / 64 ))
    i=0
    while [ "$i" -lt "$n" ]; do
      printf 'lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiu\n'
      i=$((i + 1))
    done
    ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$BIGSTUB/gh"

printf '%s' "$(mcp_payload closed completed homelab 1603)" \
  | env PATH="$BIGSTUB:$PATH" FAKE_BYTES=200000 bash "$HOOK" >/dev/null 2>&1
[ $? = 2 ] && ok "a large payload with NO report still blocks" \
            || no "a large payload with NO report still blocks" "expected rc=2"

echo
echo "lifecycle-field-check tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
