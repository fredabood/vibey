#!/usr/bin/env bash
# skill-marker.test.sh — tests for the LAB-1426 skill execution marker relocation.
#
# Harness modelled on worktree-gate.test.sh: a real sandbox git repo, synthetic stdin
# payloads, exit-code assertions, PASS/FAIL counters, `[ "$FAIL" -eq 0 ]` as exit status.
#
# Every gate case is asserted in BOTH directions. A gate that only ever allows proves
# nothing — the cases that matter here are the ones that must BLOCK.
#
# Run: bash .claude/hooks/tests/skill-marker.test.sh

set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$HOOKS_DIR/lib/skill-marker.sh"
GATE="$HOOKS_DIR/github-skill-gate.sh"
LIFECYCLE="$HOOKS_DIR/lifecycle-field-check.sh"
PASS=0
FAIL=0

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# Isolate the marker directory from the live session's own marker. Without this the suite
# would read and delete the real marker of whoever is running it.
export TMPDIR="$SANDBOX/tmp"
mkdir -p "$TMPDIR"

# Scope the sandbox repo named "homelab" as in-scope without a real GitHub remote.
export WF_SCOPE_REPO=homelab

# --- sandbox: a primary checkout and a linked worktree -----------------------
PRIMARY="$SANDBOX/homelab"
mkdir -p "$PRIMARY"
cd "$PRIMARY" || exit 1
git init -q -b main
git config user.email t@t && git config user.name t
git remote add origin https://github.com/fredabood/homelab.git
echo root >README.md
git add -A && git commit -qm init
git worktree add -q "$SANDBOX/wt" -b feature main
WT="$SANDBOX/wt"

NONGIT="$SANDBOX/plain"
mkdir -p "$NONGIT"

# --- harness -----------------------------------------------------------------
ok() { # $1 description
  PASS=$((PASS + 1)); echo "  ok: $1"
}
no() { # $1 description, $2 detail
  FAIL=$((FAIL + 1)); echo "  FAIL: $1"; [ -n "${2:-}" ] && echo "        $2"
}
expect_rc() { # $1 expected, $2 actual, $3 description
  if [ "$1" = "$2" ]; then ok "$3"; else no "$3" "expected rc=$1, got rc=$2"; fi
}

marker_for() { # $1 session id -> path
  SESSION_OVERRIDE="$1" bash "$LIB" path "$1"
}

write_payload() { # $1 session id
  printf '{"tool_name":"mcp__github__issue_write","session_id":"%s"}' "$1"
}

age_marker() { # $1 path, $2 seconds into the past
  python3 - "$1" "$2" <<'PY'
import os, sys, time
p, secs = sys.argv[1], int(sys.argv[2])
t = time.time() - secs
os.utime(p, (t, t))
PY
}

echo "== path resolution =="

P_A="$(CLAUDE_CODE_SESSION_ID=sess-a bash "$LIB" path)"
case "$P_A" in
  "$TMPDIR"/*) ok "marker path is under \$TMPDIR" ;;
  *) no "marker path is under \$TMPDIR" "got $P_A" ;;
esac

case "$P_A" in
  "$PRIMARY"/*) no "marker path is outside the repo" "got $P_A" ;;
  *) ok "marker path is outside the repo" ;;
esac

# The whole point: writer (env) and reader (payload argument) must land on one path.
P_ENV="$(CLAUDE_CODE_SESSION_ID=sess-a bash "$LIB" path)"
P_ARG="$(bash "$LIB" path sess-a)"
if [ "$P_ENV" = "$P_ARG" ]; then
  ok "writer (env) and reader (argument) resolve the same path"
else
  no "writer (env) and reader (argument) resolve the same path" "$P_ENV != $P_ARG"
fi

P_B="$(bash "$LIB" path sess-b)"
if [ "$P_A" != "$P_B" ]; then
  ok "different sessions resolve different paths (no cross-authorization)"
else
  no "different sessions resolve different paths" "both got $P_A"
fi

# A session id arrives from a JSON payload, so it is not trusted input.
P_EVIL="$(bash "$LIB" path '../../etc/passwd')"
case "$P_EVIL" in
  "$TMPDIR"/claude-skill-context/*) ok "path traversal in a session id is neutralized" ;;
  *) no "path traversal in a session id is neutralized" "escaped to $P_EVIL" ;;
esac

# With no session id at all, both sides must still agree — the project-scoped fallback.
P_NS1="$(env -u CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR=/some/proj bash "$LIB" path)"
P_NS2="$(env -u CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR=/some/proj bash "$LIB" path)"
if [ "$P_NS1" = "$P_NS2" ] && [ -n "$P_NS1" ]; then
  ok "no-session fallback is deterministic and project-scoped"
else
  no "no-session fallback is deterministic" "$P_NS1 vs $P_NS2"
fi

echo "== the invocation form the skills actually use =="

# $CLAUDE_PROJECT_DIR is exported to HOOK subprocesses but NOT to the Bash tool, so a skill
# instruction written as "$CLAUDE_PROJECT_DIR/.claude/..." expands to /.claude/... and dies
# with rc=127. That shipped once and was only caught by invoking /status for real; these two
# assertions are what would have caught it in CI.
SKILLS_DIR="$(cd "$HOOKS_DIR/../skills" 2>/dev/null && pwd || true)"
if [ -n "$SKILLS_DIR" ]; then
  BARE="$(grep -rl '"\$CLAUDE_PROJECT_DIR/\.claude/hooks/lib/skill-marker\.sh"' "$SKILLS_DIR" 2>/dev/null || true)"
  if [ -z "$BARE" ]; then
    ok "no skill uses the unguarded \$CLAUDE_PROJECT_DIR form"
  else
    no "no skill uses the unguarded \$CLAUDE_PROJECT_DIR form" "$BARE"
  fi
else
  ok "skills directory not present (hooks checked out alone) — skipped"
fi

# The documented form must resolve with the variable unset. Works whether this repo is the
# homelab superproject (.claude/hooks/...) or the .claude submodule checked out alone.
if [ -d "$HOOKS_DIR/../../.claude/hooks" ]; then
  FORM_BASE="$HOOKS_DIR/../.."; FORM_REL=".claude/hooks/lib/skill-marker.sh"
else
  FORM_BASE="$HOOKS_DIR/.."; FORM_REL="hooks/lib/skill-marker.sh"
fi
(
  unset CLAUDE_PROJECT_DIR
  cd "$FORM_BASE" || exit 1
  bash "${CLAUDE_PROJECT_DIR:-.}/$FORM_REL" path
) >/dev/null 2>&1
expect_rc 0 $? "the \${CLAUDE_PROJECT_DIR:-.} form resolves with the variable unset"

echo "== set / fresh / clear =="

CLAUDE_CODE_SESSION_ID=sess-a bash "$LIB" set demo LAB-1426 >/dev/null
if [ -f "$P_A" ]; then ok "set creates the marker"; else no "set creates the marker" "$P_A absent"; fi

if grep -q '"ticket_key": "LAB-1426"' "$P_A"; then
  ok "set records ticket_key (the one field /oreilly reads)"
else
  no "set records ticket_key" "$(cat "$P_A")"
fi

CLAUDE_CODE_SESSION_ID=sess-c bash "$LIB" set demo >/dev/null
P_C="$(bash "$LIB" path sess-c)"
if grep -q '"ticket_key": null' "$P_C"; then
  ok "set with no ticket writes null, not an empty string"
else
  no "set with no ticket writes null" "$(cat "$P_C")"
fi

bash "$LIB" fresh sess-a; expect_rc 0 $? "fresh marker reports fresh"
bash "$LIB" fresh sess-nonexistent; expect_rc 1 $? "absent marker reports not fresh"

age_marker "$P_A" 601
bash "$LIB" fresh sess-a; expect_rc 1 $? "marker aged 601s reports not fresh"
age_marker "$P_A" 0
bash "$LIB" fresh sess-a; expect_rc 0 $? "re-freshened marker reports fresh again"

CLAUDE_CODE_SESSION_ID=sess-a bash "$LIB" clear
bash "$LIB" fresh sess-a; expect_rc 1 $? "clear removes the marker"
CLAUDE_CODE_SESSION_ID=sess-a bash "$LIB" clear
expect_rc 0 $? "clear is idempotent (no error when already absent)"

echo "== github-skill-gate: allow and block =="

CLAUDE_CODE_SESSION_ID=sess-a bash "$LIB" set demo >/dev/null

write_payload sess-a | bash "$GATE" >/dev/null 2>&1
expect_rc 0 $? "gate ALLOWS a write with a fresh marker"

write_payload sess-nomarker | bash "$GATE" >/dev/null 2>&1
expect_rc 2 $? "gate BLOCKS a write with no marker"

age_marker "$P_A" 601
write_payload sess-a | bash "$GATE" >/dev/null 2>&1
expect_rc 2 $? "gate BLOCKS a write with a stale (601s) marker"
age_marker "$P_A" 0

# Regression guard for the relocation itself. The old readers used
# "${CLAUDE_PROJECT_DIR:-.}/.skill-execution-context.json"; a legacy marker sitting in a
# repo root must no longer authorize anything, or the fix would have moved the write while
# quietly leaving the old path honoured.
echo '{}' > "$PRIMARY/.skill-execution-context.json"
CLAUDE_PROJECT_DIR="$PRIMARY" write_payload sess-nomarker | CLAUDE_PROJECT_DIR="$PRIMARY" bash "$GATE" >/dev/null 2>&1
expect_rc 2 $? "gate BLOCKS despite a legacy marker in the repo root"
( cd "$PRIMARY" && write_payload sess-nomarker | bash "$GATE" >/dev/null 2>&1 )
expect_rc 2 $? "gate BLOCKS with cwd == repo root (no root-relative read survives)"
rm -f "$PRIMARY/.skill-execution-context.json"

printf '{"tool_name":"mcp__github__issue_read","session_id":"sess-nomarker"}' | bash "$GATE" >/dev/null 2>&1
expect_rc 0 $? "gate ignores read tools (unchanged)"

echo "== lifecycle-field-check: allow and block =="

close_payload() { # $1 session id, $2 state_reason
  printf '{"tool_name":"mcp__github__issue_write","session_id":"%s","tool_input":{"state":"closed","state_reason":"%s","owner":"fredabood","repo":"homelab","issue_number":1}}' "$1" "$2"
}

close_payload sess-a completed | bash "$LIFECYCLE" >/dev/null 2>&1
expect_rc 0 $? "lifecycle ALLOWS close-as-completed with a fresh marker"

close_payload sess-a not_planned | bash "$LIFECYCLE" >/dev/null 2>&1
expect_rc 0 $? "lifecycle ignores close-as-not_planned (unchanged)"

echo "== require-worktree =="

( cd "$WT" && bash "$LIB" require-worktree start-task ) >/dev/null 2>&1
expect_rc 0 $? "require-worktree ALLOWS inside a worktree"

( cd "$NONGIT" && bash "$LIB" require-worktree start-task ) >/dev/null 2>&1
expect_rc 0 $? "require-worktree ALLOWS outside any repo"

( cd "$PRIMARY" && bash "$LIB" require-worktree start-task ) >/dev/null 2>&1
expect_rc 2 $? "require-worktree REFUSES in the primary checkout"

MSG="$( cd "$PRIMARY" && bash "$LIB" require-worktree start-task 2>&1 >/dev/null )"
if printf '%s' "$MSG" | grep -q -- '--worktree'; then
  ok "refusal message names the remedy"
else
  no "refusal message names the remedy" "$MSG"
fi
if printf '%s' "$MSG" | grep -q 'start-task'; then
  ok "refusal message names the skill"
else
  no "refusal message names the skill" "$MSG"
fi

( cd "$PRIMARY" && SKILL_ALLOW_PRIMARY=1 bash "$LIB" require-worktree start-task ) >/dev/null 2>&1
expect_rc 0 $? "SKILL_ALLOW_PRIMARY=1 overrides the refusal"

( cd "$PRIMARY" && SKILL_ALLOW_PRIMARY=0 bash "$LIB" require-worktree start-task ) >/dev/null 2>&1
expect_rc 2 $? "SKILL_ALLOW_PRIMARY=0 does NOT override (only the literal 1 does)"

echo "== the require-worktree set, asserted against the SKILL.md files that SHIP =="

# The guard only refuses skills that actually invoke it, so testing the function alone
# proves nothing about which skills are guarded. Assert the shipped prompt text (LAB-1426's
# lesson: a test that builds its own copy cannot catch a defect in the artifact), and
# assert the guard really refuses for each of those skill names.
#
# /handoff joined this set in LAB-1443: its Step 8 writes vault notes, so a primary-rooted
# run used to fail LATE — after Steps 1-7 had posted issue comments that cannot be retracted.
SKILLS_DIR="$(cd "$HOOKS_DIR/../skills" 2>/dev/null && pwd)"
for s in start-task implement-feature workflow complete-task handoff; do
  f="$SKILLS_DIR/$s/SKILL.md"
  if [ -f "$f" ] && grep -q "require-worktree $s" "$f"; then
    ok "/$s SKILL.md invokes require-worktree $s"
  else
    no "/$s SKILL.md invokes require-worktree $s" "not found in $f"
  fi
  ( cd "$PRIMARY" && bash "$LIB" require-worktree "$s" ) >/dev/null 2>&1
  expect_rc 2 $? "require-worktree REFUSES /$s in the primary checkout"
done

# The complement: a skill that legitimately runs from anywhere must NOT have acquired the
# guard by copy-paste. Without this the loop above passes if every skill is guarded.
for s in status jira-search create-ticket; do
  f="$SKILLS_DIR/$s/SKILL.md"
  if [ -f "$f" ] && grep -q "require-worktree" "$f"; then
    no "/$s stays runnable from the primary checkout" "unexpected require-worktree in $f"
  else
    ok "/$s stays runnable from the primary checkout"
  fi
done

echo
echo "skill-marker tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
