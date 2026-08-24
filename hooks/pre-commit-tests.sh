#!/usr/bin/env bash
# Pre-commit quality gate: run the tests that OWN the staged files.
# Exit 0 = allow, Exit 2 = block the commit.
#
# Triggered by settings.json PreToolUse on "Bash(git commit)".
#
# WHY THIS WAS REWRITTEN (LAB-1369)
# ---------------------------------
# The previous version cd'd to CLAUDE_PROJECT_DIR and looked for a runner config at
# the REPO ROOT: pytest.ini / pyproject.toml, then package.json, then Makefile. This
# repo has none of those at the root, so every commit fell straight through to
# `exit 0`. It was a structural no-op — the second time this hook has silently done
# nothing (LAB-215, 2026-07-13, recorded in the old header).
#
# The distinction that matters: falling through because NO COMPONENT OWNS the staged
# files is correct. Falling through because the check looked in the wrong place is a
# bug that looks identical from outside. So this version always says which it did.
#
# It reuses internal/scripts/discover-test-suites.sh — the same discovery the CI
# matrix uses — so local and CI cannot drift apart.
#
# NOT disposable, as of #1382 (2026-08-23). This file used to say it would be retired
# with the rest of the Claude Code layer at the Omnigent cutover; that decision was
# evaluated and went the other way — the layer is KEPT, because it guards the surface
# this repo is actually worked in and Omnigent's own policies cannot reach a session
# Omnigent does not run. Still deliberately small.

set -uo pipefail

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print((d.get('tool_input') or {}).get('command') or '')" \
  2>/dev/null || echo "")
case "$CMD" in *"git commit"*) : ;; *) exit 0 ;; esac

ROOT="${CLAUDE_PROJECT_DIR:-.}"
cd "$ROOT" 2>/dev/null || { echo "[pre-commit-tests] cannot enter $ROOT — allowing" >&2; exit 0; }

DISCOVER="internal/scripts/discover-test-suites.sh"
if [ ! -x "$DISCOVER" ] && [ ! -f "$DISCOVER" ]; then
  echo "[pre-commit-tests] $DISCOVER not found — allowing, but this gate is NOT running." >&2
  exit 0
fi

staged="$(git diff --cached --name-only 2>/dev/null || true)"

# The .claude submodule's own index (LAB-1455). `git diff --cached` in the PARENT never
# reports a file inside a submodule — it reports the gitlink, if that moved at all. So a
# commit that edits a hook staged `hooks/foo.sh` in .claude's index and this gate saw
# nothing, concluded "staged files own no test suite", and allowed it. The one suite
# guarding the gates themselves was therefore unreachable from here even after the bash
# branch existed. Prefixed to match discovery, which collects .claude's test files the
# same way and for the same reason.
if [ -e ".claude/.git" ]; then
  claude_staged="$(git -C .claude diff --cached --name-only 2>/dev/null | sed 's|^|.claude/|' || true)"
  if [ -n "$claude_staged" ]; then
    staged="$(printf '%s\n%s' "$staged" "$claude_staged" | grep -v '^$' || true)"
  fi
fi

if [ -z "$staged" ]; then
  echo "[pre-commit-tests] nothing staged — no suite to run."
  exit 0
fi

suites="$(bash "$DISCOVER" 2>/dev/null || echo '[]')"
[ "$suites" = "[]" ] && { echo "[pre-commit-tests] no test suites discovered — allowing."; exit 0; }

# Which components own the staged files?
owners=""
while IFS= read -r dir; do
  [ -n "$dir" ] || continue
  if printf '%s\n' "$staged" | grep -q "^$dir/"; then
    owners="$owners$dir
"
  fi
done <<EOF
$(printf '%s' "$suites" | jq -r '.[].dir')
EOF

owners="$(printf '%s' "$owners" | grep -v '^$' || true)"

if [ -z "$owners" ]; then
  # The CORRECT fall-through: the staged files belong to no component with tests.
  echo "[pre-commit-tests] staged files own no test suite (docs/config only) — nothing to run."
  exit 0
fi

status=0
while IFS= read -r dir; do
  [ -n "$dir" ] || continue
  entry="$(printf '%s' "$suites" | jq -c --arg d "$dir" '.[] | select(.dir==$d)')"
  kind="$(printf '%s' "$entry" | jq -r .kind)"
  ignore="$(printf '%s' "$entry" | jq -r .ignore)"

  echo "[pre-commit-tests] running $kind suite for $dir"

  if [ "$kind" = bash ]; then
    # LAB-1455. Until this branch existed there was no `bash` case at all: shell suites
    # fell through to the pytest path, where `--collect-only` exits 5 because pytest does
    # not collect .sh files. That was read as "could not be COLLECTED (usually missing
    # deps)" and skipped — so .claude/hooks (7 suites, including worktree-gate's 109
    # assertions), validate-ports and deploy-range have NEVER run in this gate, while it
    # printed a reason that was not the reason.
    #
    # The glob mirrors tests.yml exactly, so local and CI cannot disagree about which
    # files are the suite. Nothing to install: bash and git are already here.
    found=0
    for t in "$dir"/tests/*.test.sh; do
      [ -f "$t" ] || continue
      found=$((found + 1))
      # Output only on failure: a passing gate should be quiet, a failing one should say
      # which assertion broke rather than making you re-run it by hand.
      if ! out="$(bash "$t" 2>&1)"; then
        echo "[pre-commit-tests] FAILED: $t" >&2
        printf '%s\n' "$out" | tail -20 >&2
        status=1
      fi
    done
    if [ "$found" -eq 0 ]; then
      # Discovery emits a bash suite only when it found a tests/*.test.sh, so zero here
      # means the two disagree. Loud, not skipped — the same stance tests.yml takes.
      echo "[pre-commit-tests] $dir: discovery says bash, but no tests/*.test.sh found." >&2
      status=1
    fi
  elif [ "$kind" = node ]; then
    if [ ! -d "$dir/node_modules" ]; then
      echo "[pre-commit-tests] $dir has no node_modules — SKIPPED (not a pass). Run npm install." >&2
      continue
    fi
    ( cd "$dir" && npm test >/dev/null 2>&1 ) || status=1
  else
    # Prefer the component's own venv; a bare `pytest` usually cannot import the
    # component under test.
    py="pytest"
    [ -x "$dir/.venv/bin/pytest" ] && py="$PWD/$dir/.venv/bin/pytest"
    if [ "$py" = pytest ] && ! command -v pytest >/dev/null 2>&1; then
      echo "[pre-commit-tests] pytest not available for $dir — SKIPPED (not a pass)." >&2
      continue
    fi
    args=""
    for p in $ignore; do args="$args --ignore=${p#"$dir"/}"; done

    # Ask whether the suite can even be COLLECTED before running it. Exit codes cannot
    # tell the two cases apart: with -x, a missing-dependency collection error reports
    # exit 1, exactly like a genuine test failure. Blocking on that would stop commits
    # on any machine without every component's venv built — which is how a gate earns a
    # reputation for being in the way, and how it ends up disabled.
    # shellcheck disable=SC2086
    if ! ( cd "$dir" && "$py" --collect-only -q $args ) >/dev/null 2>&1; then
      echo "[pre-commit-tests] $dir could not be COLLECTED here (usually missing deps)." >&2
      echo "                   SKIPPED, not passed — CI runs this suite with a clean install." >&2
      continue
    fi

    # shellcheck disable=SC2086
    ( cd "$dir" && "$py" -x -q $args )
    rc=$?
    # 5 == no tests collected; not a failure.
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 5 ]; then status=1; fi
  fi
done <<EOF
$owners
EOF

if [ "$status" -ne 0 ]; then
  echo "" >&2
  echo "[pre-commit-tests] BLOCKED: tests failed for a component you staged changes in." >&2
  echo "" >&2
  echo "  Fix the failing tests, or unstage that component's files." >&2
  echo "  Run the suite directly to see the failures:" >&2
  printf '    (cd %s && pytest -q)\n' "$(printf '%s' "$owners" | head -1)" >&2
  exit 2
fi

echo "[pre-commit-tests] all owning suites passed."
exit 0
