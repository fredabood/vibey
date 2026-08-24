#!/usr/bin/env bash
# ticket-reference-check.test.sh — LAB-1495.
#
# This hook has gated every commit in the repo since LAB-1364 and had NO test suite. It
# reads the message out of the command string, which meant `git commit -F <file>` — the
# way any commit with a body longer than one line is written, and what this repo's own
# structured-message convention asks for — was reported as "no reference" while holding a
# message whose first token was the key.
#
# Harness modelled on worktree-gate.test.sh: a real sandbox repo (the hook asks git for
# the branch name), synthetic stdin payloads, exit-code assertions.
#
# Run: bash .claude/hooks/tests/ticket-reference-check.test.sh

set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$HOOKS_DIR/ticket-reference-check.sh"
[ -f "$HOOK" ] || { echo "✗ not found: $HOOK" >&2; exit 1; }

PASS=0
FAIL=0

SANDBOX="$(mktemp -d "${WF_TEST_ROOT:-$HOME}/tref-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

REPO="$SANDBOX/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@t.invalid
git -C "$REPO" config user.name t
echo x >"$REPO/README.md"
git -C "$REPO" add -A
git -C "$REPO" -c commit.gpgsign=false commit -qm "LAB-0: init"

payload() { # $1 command
  jq -cn --arg m "$1" '{tool_name:"Bash", tool_input:{command:$m}}'
}

# The hook resolves the branch with `git rev-parse` in its OWN cwd, so every case runs
# from a repo whose branch name is known and deliberately carries no key.
expect() { # $1 desc, $2 expected exit, $3 command, $4 cwd(optional)
  local out rc
  out="$( cd "${4:-$REPO}" && payload "$3" | bash "$HOOK" 2>&1 )"
  rc=$?
  if [ "$rc" -eq "$2" ]; then
    PASS=$((PASS + 1)); echo "  ok: $1"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $1 (expected $2, got $rc) [$(printf '%s' "$out" | head -2 | tr '\n' ' ')]"
  fi
}

MSG_OK="$SANDBOX/ok.txt"
printf 'LAB-1495: read the message from a file\n\nA body line.\n' >"$MSG_OK"
MSG_NONE="$SANDBOX/none.txt"
printf 'Fix the thing\n\nA body line.\n' >"$MSG_NONE"
MSG_BODY_ONLY="$SANDBOX/body.txt"
printf 'Fix the thing\n\nRefs LAB-1495 in the body only.\n' >"$MSG_BODY_ONLY"
MSG_BLANK_FIRST="$SANDBOX/blank.txt"
printf '\n\nLAB-1495: after blank lines\n' >"$MSG_BLANK_FIRST"

echo "ticket-reference-check — branch '$(git -C "$REPO" rev-parse --abbrev-ref HEAD)' carries no key"
echo

echo "-m (unchanged behaviour):"
expect "-m with a key allowed"            0 'git commit -m "LAB-1495: x"'
expect "-m without a key blocked"         2 'git commit -m "fix the thing"'
expect "chore: prefix allowed"            0 'git commit -m "chore: tidy"'
expect "docs: prefix allowed"             0 'git commit -m "docs: update"'
expect "a deprecated HL- key allowed"     0 'git commit -m "HL-963: historical"'
expect "not a commit at all is ignored"   0 'git status --short'

echo
echo "-F / --file (LAB-1495 — the file was never opened):"
expect "-F with a key on the subject line allowed"  0 "git commit -F $MSG_OK"
expect "--file with a key allowed"                  0 "git commit --file $MSG_OK"
expect "--file= with a key allowed"                 0 "git commit --file=$MSG_OK"
expect "-F without a key anywhere blocked"          2 "git commit -F $MSG_NONE"
expect "-F with leading blank lines still allowed"  0 "git commit -F $MSG_BLANK_FIRST"

echo
echo "-F must not become a bypass:"
# A key in the BODY is not a subject. The convention is 'LAB-n: <description>' at the
# start of the message, and the check must keep meaning that.
expect "-F with the key only in the body blocked"   2 "git commit -F $MSG_BODY_ONLY"
expect "-F naming a missing file blocked"           2 "git commit -F $SANDBOX/nope.txt"
expect "-F - (stdin) blocked"                       2 'git commit -F -'
expect "-F with no argument blocked"                2 'git commit -F'

echo
echo "branch-name fallback (unchanged):"
BR="$SANDBOX/branched"
cp -R "$REPO" "$BR"
git -C "$BR" checkout -q -b LAB-1495-a-branch-with-a-key
expect "no key in the message but one in the branch allowed" 0 'git commit -m "fix the thing"' "$BR"
expect "a keyless -F file is still rescued by the branch"    0 "git commit -F $MSG_NONE" "$BR"

echo
echo "ticket-reference-check tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
