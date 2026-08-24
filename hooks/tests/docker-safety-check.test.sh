#!/usr/bin/env bash
# docker-safety-check.test.sh — LAB-1358.
#
# This gate has intercepted `docker stop/rm/rmi/kill` since LAB-215 and had NO test
# suite. It extracted its targets by word-splitting the command, so `docker rm -f
# x-staging 2>&1 | tail -1` was blocked (the redirect and the pipe were read as
# container names), and a `grep -v` that matched nothing killed the script under
# `set -e` — the harness then reported "hook error ... No stderr output" rather than
# a refusal.
#
# Harness modelled on ticket-reference-check.test.sh: synthetic PreToolUse payloads on
# stdin, exit-code assertions, plus stderr assertions because a refusal the operator
# cannot see is the other half of the bug.
#
# Run: bash .claude/hooks/tests/docker-safety-check.test.sh

set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$HOOKS_DIR/docker-safety-check.sh"
[ -f "$HOOK" ] || { echo "✗ not found: $HOOK" >&2; exit 1; }

PASS=0
FAIL=0

# Payload built with python3 rather than jq: python3 is already a hard dependency of the
# gate itself, so a machine that can run the hook can run its tests.
payload() { # $1 command
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"
}

STDERR_FILE="$(mktemp)"
trap 'rm -f "$STDERR_FILE"' EXIT

run_hook() { # $1 command -> sets RC, STDOUT_TEXT, STDERR_TEXT
  STDOUT_TEXT="$(payload "$1" | bash "$HOOK" 2>"$STDERR_FILE")"
  RC=$?
  STDERR_TEXT="$(cat "$STDERR_FILE")"
}

ok()   { PASS=$((PASS + 1)); echo "  ok: $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

expect() { # $1 desc, $2 expected exit, $3 command
  run_hook "$3"
  if [ "$RC" -eq "$2" ]; then
    ok "$1"
  else
    bad "$1 (expected exit $2, got $RC) [$(printf '%s' "$STDERR_TEXT" | head -2 | tr '\n' ' ')]"
  fi
}

expect_stderr() { # $1 desc, $2 substring, $3 command
  run_hook "$3"
  case "$STDERR_TEXT" in
    *"$2"*) ok "$1" ;;
    *)      bad "$1 (stderr lacked '$2'; got: $(printf '%s' "$STDERR_TEXT" | head -2 | tr '\n' ' '))" ;;
  esac
}

DESTRUCTIVE_SUBCOMMANDS="stop rm rmi kill"

echo "docker-safety-check — $HOOK"
echo

echo "Staging exemption (the LAB-1358 regression: redirects and pipes are not containers):"
expect "plain staging container allowed"            0 'docker rm -f pg-restore-test-staging'
expect "staging + 2>&1 | tail allowed"              0 'docker rm -f pg-restore-test-staging 2>&1 | tail -1'
expect "staging + >/dev/null 2>&1 allowed"          0 'docker stop pg-restore-test-staging >/dev/null 2>&1'
expect "staging piped into grep allowed"            0 'docker rm n8n-staging | grep -q removed'
expect "two staging containers allowed"             0 'docker rm a-staging b-staging'
expect "staging + trailing comment allowed"         0 'docker stop n8n-staging  # cleanup'
expect "staging with an env prefix allowed"         0 'DOCKER_HOST=tcp://docker-socket-proxy:2375 docker rm x-staging'

echo
echo "Production is still refused (the security half — nothing new gets through):"
for SUB in $DESTRUCTIVE_SUBCOMMANDS; do
  expect "docker $SUB on production blocked"        2 "docker $SUB n8n"
  expect "docker $SUB on production + pipe blocked" 2 "docker $SUB n8n 2>&1 | tail -1"
done
expect "mixed staging + production blocked"         2 'docker rm a-staging n8n'
expect "production behind a redirect blocked"       2 'docker rm 2>/dev/null n8n'
expect "production with an env prefix blocked"      2 'DOCKER_HOST=tcp://x docker rm postgres-memory'
expect "docker rm \$(docker ps -aq) blocked"        2 'docker rm $(docker ps -aq)'

echo
echo "The refusal reaches the operator (it used to go to stdout):"
expect_stderr "block message is on stderr"      "BLOCKED" 'docker rm n8n'
expect_stderr "block message names the target"  "n8n"     'docker rm n8n'
expect_stderr "block message explains staging"  "-staging" 'docker rm n8n'
run_hook 'docker rm n8n'
if [ -z "$STDOUT_TEXT" ]; then
  ok "block message writes nothing to stdout"
else
  bad "block message leaked to stdout: $STDOUT_TEXT"
fi

echo
echo "Multi-line commands (handled on purpose, not per-line by accident):"
expect "production on line 2 blocked"               2 'echo starting
docker rm n8n'
expect "staging on line 2 allowed"                  0 'echo starting
docker rm n8n-staging'
expect "staging on line 2 with a pipe allowed"      0 'echo starting
docker rm n8n-staging 2>&1 | tail -1'
expect "production after && blocked"                2 'echo starting && docker rm n8n'
expect "production after ; blocked"                 2 'echo starting; docker rm n8n'

echo
echo "No-target and non-docker commands (the \`grep -v\` crash, and over-blocking):"
expect "bare 'docker rm' allowed, not an error"     0 'docker rm'
expect "'docker rm -f' with no target allowed"      0 'docker rm -f'
expect "'docker stop' with no target allowed"       0 'docker stop'
expect "docker ps is not gated"                     0 'docker ps -a'
expect "docker compose up is not gated"             0 'docker compose -f stacks/core-stack.yml --env-file .env up -d'
expect "docker logs is not gated"                   0 'docker logs n8n --tail 50'
expect "a quoted mention is not an invocation"      0 'echo "docker rm n8n"'
expect "a grep for the string is not an invocation" 0 "grep -rn 'docker rm n8n' ."
expect "an unrelated command is allowed"            0 'ls -la /tmp'
expect "an empty command is allowed"                0 ''

echo
echo "The hook returns a verdict, never an error (exit is 0 or 2, always):"
CASES=(
  'docker rm'
  'docker rm -f'
  'docker rm n8n'
  'docker rm x-staging 2>&1 | tail -1'
  'docker rm "unterminated'
  'docker rm $(cat list)'
  'echo hi'
  ''
)
for C in "${CASES[@]}"; do
  run_hook "$C"
  if [ "$RC" -eq 0 ] || [ "$RC" -eq 2 ]; then
    ok "exit $RC (a verdict) for: ${C:-<empty>}"
  else
    bad "exit $RC (not a verdict) for: ${C:-<empty>}"
  fi
done

echo
echo "Unparseable input fails CLOSED when it looks destructive:"
expect "unbalanced quote around a production rm blocked" 2 'docker rm "n8n'
expect "unbalanced quote elsewhere is allowed"           0 'echo "hello'

echo
echo "----"
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
