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
echo "Management-command spelling is gated too (#1530 — these all used to exit 0):"
expect "docker container rm blocked"                 2 'docker container rm n8n'
expect "docker container stop blocked"               2 'docker container stop n8n'
expect "docker container kill blocked"               2 'docker container kill n8n'
expect "docker image rm blocked"                     2 'docker image rm n8n_img'
expect "docker volume rm blocked"                    2 'docker volume rm nextcloud_data'
expect "docker network rm blocked"                   2 'docker network rm core'
expect_stderr "noun-form block names its target" "nextcloud_data" 'docker volume rm nextcloud_data'

echo
echo "Global flags no longer hide the verb (#1530 — the verb need not be adjacent):"
expect "--context then rm blocked"                   2 'docker --context prod rm n8n'
expect "-H then rm blocked"                          2 'docker -H tcp://docker-socket-proxy:2375 rm n8n'
expect "--host=X then rm blocked"                    2 'docker --host=tcp://x rm n8n'
expect "--log-level then rm blocked"                 2 'docker --log-level debug rm n8n'
expect "-D (boolean flag) then rm blocked"           2 'docker -D rm n8n'
expect "global flag + noun form blocked"             2 'docker --context prod container rm n8n'

echo
echo "Over-blocking guards: the noun alone is not destructive, a verb must follow:"
expect "docker container ls allowed"                 0 'docker container ls'
expect "docker container inspect allowed"            0 'docker container inspect n8n'
expect "docker image ls allowed"                     0 'docker image ls'
expect "docker network inspect allowed"              0 'docker network inspect core'
expect "docker volume ls allowed"                    0 'docker volume ls'
expect "docker volume inspect allowed"               0 'docker volume inspect nextcloud_data'
expect "docker --context prod ps allowed"            0 'docker --context prod ps -a'
expect "noun form on staging allowed"                0 'docker volume rm scratch-staging'

echo
echo "The staging exemption is suffix/tag aware, not a substring match (#1530):"
expect "foo:staging tag is exempt"                   0 'docker rmi foo:staging'
expect "name-staging with a tag is exempt"           0 'docker rmi foo-staging:latest'
expect "'-staging' in the MIDDLE is not exempt"      2 'docker rm my-staging-thing-prod'
expect "'staging' as a bare name is exempt"          0 'docker rm staging'
expect "a registry port is not read as a tag"        2 'docker rmi localhost:5000/n8n'
expect "production image with a tag still blocked"   2 'docker rmi n8n-img:latest'

echo
echo "Out of scope, asserted so the decision is pinned (see the header): prune and"
echo "compose down name no target, so the NO TARGETS rule allows them:"
expect "docker image prune is allowed"               0 'docker image prune -a -f'
expect "docker system prune is allowed"              0 'docker system prune -a -f'
expect "docker volume prune is allowed"              0 'docker volume prune -f'
expect "docker compose down -v is allowed"           0 'docker compose down -v'

echo
echo "The two fail-closed fallbacks agree on a shared table (#1530):"
# They used to be two hand-copied regexes with the same hole in each. They now share ONE
# string — $RAW_DESTRUCTIVE_RE in the hook, exported to the parser as
# HOOK_RAW_DESTRUCTIVE_RE — and this table proves the two ENGINES (grep -E and python
# re) still reach the same verdict from it. The inputs are not byte-identical: the shell
# scan sees the raw JSON payload, the python scan sees the decoded command. Agreeing on
# the verdict across both is the property that matters.
STUB_BIN="$(mktemp -d)"
trap 'rm -f "$STDERR_FILE"; rm -rf "$STUB_BIN"' EXIT
for B in cat grep; do
  BP="$(command -v "$B")" && ln -sf "$BP" "$STUB_BIN/$B"
done

run_shell_fallback() { # $1 command — python3 removed from PATH
  payload "$1" | env PATH="$STUB_BIN" /bin/bash "$HOOK" >/dev/null 2>"$STDERR_FILE"
  RC=$?
}
run_python_fallback() { # $1 command — trailing unbalanced quote makes tokenize() raise
  payload "$1 \"" | /bin/bash "$HOOK" >/dev/null 2>"$STDERR_FILE"
  RC=$?
}

# Sanity: the stub PATH really does hide python3, or every row below is vacuous.
if payload 'ls' | env PATH="$STUB_BIN" /bin/bash -c 'command -v python3 >/dev/null' 2>/dev/null; then
  bad "stub PATH still exposes python3 — the shell-fallback rows would be vacuous"
else
  ok "stub PATH hides python3 (the shell fallback is really being exercised)"
fi

FALLBACK_CASES=(
  "2|docker rm n8n"
  "2|docker container rm n8n"
  "2|docker volume rm nextcloud_data"
  "2|docker image rm n8n_img"
  "2|docker network rm core"
  "2|docker --context prod rm n8n"
  "2|docker -H tcp://x rm n8n"
  "0|docker ps -a"
  "0|docker container ls"
  "0|docker volume ls"
  "0|docker compose down -v"
  "0|ls -la /tmp"
)
for ROW in "${FALLBACK_CASES[@]}"; do
  WANT="${ROW%%|*}"
  CMD="${ROW#*|}"
  run_shell_fallback "$CMD";  SHELL_RC=$RC
  run_python_fallback "$CMD"; PY_RC=$RC
  if [ "$SHELL_RC" = "$WANT" ] && [ "$PY_RC" = "$WANT" ]; then
    ok "both fallbacks exit $WANT for: $CMD"
  else
    bad "fallback disagreement for '$CMD' (want $WANT; shell=$SHELL_RC python=$PY_RC)"
  fi
done

echo
echo "----"
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
