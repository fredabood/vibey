#!/usr/bin/env bash
# pre-commit-tests.test.sh — LAB-1437.
#
# The gate that runs the suites owning your staged files had no suite of its own,
# which is how it acquired the same defect twice: a kind it does not dispatch falls
# into the pytest arm, `pytest --collect-only` exits 5 on a file pytest never
# collects, and the gate reports "could not be COLLECTED here (usually missing
# deps) — SKIPPED, not passed". Shell suites lived that way until LAB-1455; rust
# suites did from the moment discovery grew the kind. Both times the gate printed a
# reason that was not the reason, about a suite it exists to enforce.
#
# Harness modelled on docker-safety-check.test.sh (synthetic PreToolUse payload on
# stdin, exit-code AND stderr assertions) plus worktree-gate.test.sh's sandbox-repo
# fixture, because this hook reads a real git index and a real discovery script.
#
# TWO THINGS THIS FIXTURE CONTROLS ON PURPOSE
#   1. Discovery is a STUB emitting a suites.json this file writes. The unit under
#      test is the DISPATCH, not discovery — which lives in the parent repo and is
#      tested there.
#   2. PATH is rebuilt from an explicit tool list, so `cargo` is absent by
#      construction rather than by luck. On this laptop cargo happens not to be
#      installed; on the ubuntu-latest runner that runs this suite in CI it is. A
#      "missing toolchain" test that only tests anything on one of the two machines
#      is the LAB-1425 defect (21 assertions vacuous on Linux) with the platforms
#      swapped.
#
# Run: bash .claude/hooks/tests/pre-commit-tests.test.sh

set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$HOOKS_DIR/pre-commit-tests.sh"
[ -f "$HOOK" ] || { echo "✗ not found: $HOOK" >&2; exit 1; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/pct-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

# --- sandbox repo -------------------------------------------------------------
mkdir -p "$SANDBOX/internal/scripts"
cd "$SANDBOX" || { echo "cannot enter the sandbox" >&2; exit 1; }
git init -q -b main
git config user.email t@t && git config user.name t

# Discovery stub: whatever suites.json says, verbatim.
cat >internal/scripts/discover-test-suites.sh <<'STUB'
#!/bin/bash
cat "$(dirname "$0")/suites.json"
STUB
chmod +x internal/scripts/discover-test-suites.sh

# A rust crate, in Cargo's shape: a manifest, inline unit tests, an integration target.
mkdir -p crates/rusty/src crates/rusty/tests
printf '[package]\nname = "rusty"\nversion = "0.1.0"\n' >crates/rusty/Cargo.toml
printf '#[cfg(test)]\nmod tests { #[test] fn t() { assert!(true); } }\n' >crates/rusty/src/lib.rs
printf '#[test]\nfn it() { assert!(true); }\n' >crates/rusty/tests/it.rs

# A directory discovery would call rust but that holds no manifest — the disagreement case.
mkdir -p crates/nomanifest/src
printf '#[cfg(test)]\nmod tests { #[test] fn t() {} }\n' >crates/nomanifest/src/lib.rs

# Bash suites: one green, one red. Regression controls for the arm LAB-1455 added.
mkdir -p comp/tests compfail/tests
printf '#!/bin/bash\nexit 0\n' >comp/tests/green.test.sh
printf '#!/bin/bash\necho "assertion 3 broke" >&2\nexit 1\n' >compfail/tests/red.test.sh

git add -A   # staged and never committed: every fixture dir owns its staged files

# --- PATH construction --------------------------------------------------------
# NOCARGO holds symlinks to exactly the binaries the hook and the stubs need, and
# nothing else. Anything absent from this list is absent from the hook's world.
NOCARGO="$SANDBOX/bin-nocargo"
SHIMBIN="$SANDBOX/bin-shim"
mkdir -p "$NOCARGO" "$SHIMBIN"
for t in bash sh cat python3 git jq grep sed tail head tr sort dirname basename env rm mkdir ls uname awk cut wc mktemp; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NOCARGO/$t"
done

# The fixture's own preconditions. A sanitized PATH missing jq or python3 would make
# the hook fall through in ways that look like passes, so this is checked, not assumed.
for t in bash cat python3 git jq grep sed tail; do
  [ -e "$NOCARGO/$t" ] || { echo "✗ fixture broken: $t not resolvable for the sanitized PATH" >&2; exit 1; }
done
if PATH="$NOCARGO" command -v cargo >/dev/null 2>&1; then
  echo "✗ fixture broken: cargo is still reachable on the sanitized PATH — the" >&2
  echo "  missing-toolchain assertions below would be vacuous." >&2
  exit 1
fi

# The cargo stand-in: records how it was called and from where, and exits with
# whatever the case asks for. A real toolchain is not needed to test a dispatch.
cat >"$SHIMBIN/cargo" <<'SHIM'
#!/bin/bash
{ printf 'argv=%s\n' "$*"; printf 'pwd=%s\n' "${PWD##*/}"; } >>"$CARGO_LOG"
echo "running 2 tests"
[ "${CARGO_RC:-0}" = 0 ] || echo "test tests::t ... FAILED"
exit "${CARGO_RC:-0}"
SHIM
chmod +x "$SHIMBIN/cargo"
WITHCARGO="$SHIMBIN:$NOCARGO"

CARGO_LOG="$SANDBOX/cargo.log"
ERRFILE="$SANDBOX/stderr"
PAYLOAD="$(python3 -c 'import json;print(json.dumps({"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}))')"

# --- harness ------------------------------------------------------------------
suites() { printf '%s' "$1" >"$SANDBOX/internal/scripts/suites.json"; }

run_gate() { # $1 PATH, $2 cargo exit code, $3 payload -> RC, OUT, ERR, CARGO_CALLS
  : >"$CARGO_LOG"
  OUT="$(printf '%s' "${3:-$PAYLOAD}" | env -i \
    PATH="$1" HOME="$HOME" CLAUDE_PROJECT_DIR="$SANDBOX" \
    CARGO_LOG="$CARGO_LOG" CARGO_RC="${2:-0}" \
    "$NOCARGO/bash" "$HOOK" 2>"$ERRFILE")"
  RC=$?
  ERR="$(cat "$ERRFILE")"
  CARGO_CALLS="$(cat "$CARGO_LOG")"
}

expect_rc() { # $1 desc, $2 expected
  if [ "$RC" -eq "$2" ]; then ok "$1"
  else bad "$1 (expected exit $2, got $RC) [$(printf '%s' "$ERR" | head -3 | tr '\n' ' ')]"; fi
}
expect_has() { # $1 desc, $2 haystack, $3 needle
  case "$2" in
    *"$3"*) ok "$1" ;;
    *)      bad "$1 (missing '$3'; got: $(printf '%s' "$2" | head -3 | tr '\n' ' '))" ;;
  esac
}
expect_lacks() { # $1 desc, $2 haystack, $3 needle
  case "$2" in
    *"$3"*) bad "$1 (unexpectedly contained '$3'; got: $(printf '%s' "$2" | head -3 | tr '\n' ' '))" ;;
    *)      ok "$1" ;;
  esac
}

RUST_SUITE='[{"dir":"crates/rusty","kind":"rust","install":"cargo","ignore":""}]'

echo "pre-commit-tests — $HOOK"
echo

echo "Control: the fixture itself works (a green bash suite passes the gate):"
suites '[{"dir":"comp","kind":"bash","install":"none","ignore":""}]'
run_gate "$WITHCARGO"
expect_rc "green bash suite -> allow" 0
expect_has "and says so" "$OUT" "all owning suites passed"

echo
echo "A rust suite reaches cargo, not pytest (the LAB-1437 defect):"
suites "$RUST_SUITE"
run_gate "$WITHCARGO"
expect_rc "green rust suite -> allow" 0
expect_has "cargo was invoked"                 "$CARGO_CALLS" "argv=test"
expect_has "cargo ran from the suite's dir"    "$CARGO_CALLS" "pwd=rusty"
# The needle is "pytest", not "could not be COLLECTED": which of the pytest arm's two
# skip messages a misrouted rust suite lands on depends on whether pytest happens to be
# installed on the machine running this suite (it is on the CI runner, not on this
# laptop). Only "pytest" is present in both, so only "pytest" fails on both.
expect_lacks "not routed through the pytest arm" "$ERR" "pytest"
expect_lacks "not reported as missing deps"    "$ERR" "SKIPPED"

echo
echo "A failing rust suite BLOCKS (the gate's whole purpose):"
suites "$RUST_SUITE"
run_gate "$WITHCARGO" 1
expect_rc "failing rust suite -> block" 2
expect_has "names the failing runner"  "$ERR" "FAILED: cargo test in crates/rusty"
expect_has "prints the block banner"   "$ERR" "BLOCKED"
expect_has "surfaces cargo's output"   "$ERR" "test tests::t ... FAILED"

echo
echo "A missing toolchain SKIPS LOUDLY — it is not a pass, and not a failure either:"
suites "$RUST_SUITE"
run_gate "$NOCARGO"
expect_rc "no cargo -> allow, not block" 0
expect_has "says which tool is missing"      "$ERR" "cargo not available for crates/rusty"
expect_has "says it is not a pass"           "$ERR" "SKIPPED (not a pass)"
expect_lacks "absent cargo is not read as a test failure" "$ERR" "FAILED: cargo test"

echo
echo "Discovery/runner disagreement is loud, not skipped:"
suites '[{"dir":"crates/nomanifest","kind":"rust","install":"cargo","ignore":""}]'
run_gate "$WITHCARGO"
expect_rc "rust suite with no Cargo.toml -> block" 2
expect_has "says the two disagree" "$ERR" "discovery says rust, but no Cargo.toml"
expect_lacks "cargo was not run in a non-crate dir" "$CARGO_CALLS" "argv=test"

echo
echo "\`ignore\` is a pytest concept; a rust suite says so rather than dropping it:"
suites '[{"dir":"crates/rusty","kind":"rust","install":"cargo","ignore":"crates/rusty/tests/integration"}]'
run_gate "$WITHCARGO"
expect_rc "ignore does not change the verdict" 0
expect_has "warns that cargo will not honour it" "$ERR" "which rust suites do not honour"

echo
echo "Regression controls — the arms that already existed still behave:"
suites '[{"dir":"compfail","kind":"bash","install":"none","ignore":""}]'
run_gate "$WITHCARGO"
expect_rc "failing bash suite -> block" 2
expect_has "names the failing suite" "$ERR" "FAILED: compfail/tests/red.test.sh"

suites "$RUST_SUITE"
run_gate "$WITHCARGO" 1 '{"tool_name":"Bash","tool_input":{"command":"git status"}}'
expect_rc "a non-commit command is not gated at all" 0
expect_lacks "and runs nothing" "$CARGO_CALLS" "argv=test"

echo
echo "----"
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
