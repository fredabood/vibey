#!/usr/bin/env bash
# session-bootstrap.sh — SessionStart companion to worktree-gate.sh (LAB-1364).
#
# SessionStart CANNOT block (exit 2 only renders a notice; the session proceeds), so this
# hook does not try to. It does three things:
#
#   1. REPAIRS an unpopulated worktree. .claude is a submodule; a fresh worktree checks out
#      the gitlink without populating it, so the worktree's .claude/ is empty and ZERO
#      project hooks, rules, skills, or agents load. Observed live: the LAB-1363 worktree
#      came up with .claude containing 0 entries.
#   2. ORIENTS the agent via additionalContext — names the gate and where the session is.
#   3. WARNS when the INSTALLED gate under ~/.claude/hooks has drifted from the canonical
#      copy in the repo. The installed copy is what actually runs, so drift is invisible.
#
# Always exits 0. Emits a single JSON object on stdout.

set -u

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/worktree-facts.sh"
# shellcheck source=lib/worktree-facts.sh
. "$LIB" 2>/dev/null || exit 0

command -v jq >/dev/null 2>&1 || exit 0

PAYLOAD="$(cat)"
CWD="$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty' 2>/dev/null)" || CWD=""
[ -n "$CWD" ] || exit 0

MODE="$(wf_mode "$CWD")"
case "$MODE" in
  OUT_OF_REPO | OUT_OF_SCOPE) exit 0 ;;
esac

ROOT="$(wf_repo_root "$CWD")"
NOTES=""
add() { NOTES="${NOTES}${NOTES:+$'\n'}$1"; }

# ------------------------------------------------ 1. repair an empty .claude ---
# Shared with worktree-gate.sh via lib/worktree-facts.sh so the two cannot drift, and so
# the repair is reachable on BOTH paths: SessionStart (a session launched in a worktree)
# and PreToolUse (a session that entered one mid-flight via EnterWorktree, which does not
# re-fire SessionStart — LAB-1495).
if [ "$MODE" = WORKTREE ] && wf_claude_unpopulated "$ROOT"; then
  SID="$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null)"
  if wf_claude_repair_once "$ROOT" "$SID"; then
    add "Bootstrapped the .claude submodule in this worktree (it checks out empty, which would otherwise leave the session with no project hooks, rules, or skills)."
  else
    add "WARNING: .claude is empty in this worktree and 'git submodule update --init .claude' failed. Project hooks, rules, and skills are NOT loaded. Run it by hand."
  fi
fi

# ------------------------------------------------------- 2. orient the agent ---
if [ "$MODE" = PRIMARY ]; then
  add "You are in the PRIMARY CHECKOUT ($ROOT). It is a deploy mirror pinned to main: its Caddyfile and stack files are bind-mounted into running containers, and its HEAD is shared by every concurrent session."
  add "The worktree gate BLOCKS file edits, history-moving git commands, and file-mutating shell commands here. Reads, git pull/status/log/diff, docker, and anything outside the repo are allowed."
  add "Before changing anything in this repo, move into a worktree: ask to work in a worktree (EnterWorktree), or relaunch with 'claude --worktree <KEY>-<slug>'."
elif [ "$MODE" = WORKTREE ]; then
  add "You are in a WORKTREE ($ROOT), branch '$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)'. Edits are allowed here; Claude Code's own isolation blocks writes back to the primary checkout."
fi

# ----------------------------------------------------- 3. installed-vs-source ---
INSTALLED="$HOME/.claude/hooks"
CANON="$ROOT/.claude/hooks"
if [ -d "$INSTALLED" ] && [ -d "$CANON" ]; then
  for f in worktree-gate.sh session-bootstrap.sh lib/worktree-facts.sh; do
    if [ -f "$INSTALLED/$f" ] && [ -f "$CANON/$f" ]; then
      if ! cmp -s "$INSTALLED/$f" "$CANON/$f"; then
        add "WARNING: the INSTALLED $f (~/.claude/hooks/$f) differs from the repo copy. The installed copy is what runs — re-run internal/scripts/install-claude-user-hooks.sh to resync."
      fi
    fi
  done
fi

[ -n "$NOTES" ] || exit 0

jq -cn --arg ctx "$NOTES" \
  '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$ctx}}'
exit 0
