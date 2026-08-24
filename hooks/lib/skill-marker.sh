#!/usr/bin/env bash
# skill-marker.sh — THE single definition of the skill execution marker (LAB-1426).
#
# The marker proves "a sanctioned skill run is in progress" to github-skill-gate.sh and
# lifecycle-field-check.sh. Both readers consult only its MTIME; the JSON body is
# informational, except that /oreilly --jira reads ticket_key.
#
# Why it does not live in the repo root any more:
#   14 skills used to write a bare `.skill-execution-context.json`, which resolves against
#   $CWD — the repo root. In the PRIMARY checkout that is a deploy mirror, so worktree-gate.sh
#   blocks the write (Write tool AND `>` redirect alike; there is no shell escape hatch).
#   Every one of those skills therefore failed at step 1 from a primary-rooted session.
#   The marker is ephemeral session state, gitignored in both .gitignore and .claude/.gitignore
#   precisely because it is not project content, so the fix is to stop putting it in the repo.
#
# Why $TMPDIR specifically: wf_is_scratch() in worktree-facts.sh already allowlists
# /tmp, /private/tmp, /var/folders and $TMPDIR. Landing here needs NO new gate exemption —
# it is a path the gate was already written to permit.
#
# Bash 3.2-compatible (macOS ships 3.2.57). Sourced by the two reader hooks and the test
# suite; also runnable directly as the writer, which is how skills invoke it.

set -u

# Freshness window. 600s, and since LAB-1425 it measures IDLE time, not run time: every
# reader calls skill_marker_touch() on its allow path, so the clock restarts at each
# sanctioned operation (see that function's header). The claim the number makes is
# therefore "a live skill run does not go ten minutes without a gated call", not "a run
# finishes in ten minutes" — the second would have been false for /workflow and for any
# bulk pass, which is how the window came to be questioned (#1443).
#
# Left at 600 deliberately: with refresh-on-use there is no observed case of it firing
# mid-run, so there is nothing to tune against, and a bigger number would only extend how
# long an ABANDONED marker keeps authorizing writes.
#
# Overridable so the test suite can age a marker without sleeping.
SKILL_MARKER_TTL="${SKILL_MARKER_TTL:-600}"

skill_marker_dir() {
  local base="${TMPDIR:-/tmp}"
  printf '%s/claude-skill-context' "${base%/}"
}

# Reduce an arbitrary string to something safe as a single filename component.
# Load-bearing: the reader's session id arrives from a hook's JSON payload, so an id of
# "../../etc/passwd" must not escape the marker directory.
skill_marker_slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# Resolved marker path. $1 = session id, optional.
#
# Keyed on the session when one is known, which is TIGHTER than the old repo-root marker:
# two sessions sharing a checkout can no longer authorize each other's GitHub writes.
# When no session id is available both sides fall back to the project directory, which is
# exactly the isolation the old marker had — never worse.
#
# Session-id agreement between writer and reader: CONFIRMED 2026-08-24 (#1443).
#
# The writer resolves its path from CLAUDE_CODE_SESSION_ID as the Bash tool sees it; the
# readers resolve theirs from the session_id field of the HOOK PAYLOAD — a different source,
# handed to them by the harness rather than inherited through the environment. Measured
# twice in one session: a marker written via the Bash tool landed at the real session id's
# path (cross-checked against the harness-assigned scratchpad path, which the shell cannot
# influence), and a subsequent gh lifecycle write was ALLOWED by github-skill-gate.sh, which
# had read that file. The two sources agree.
#
# Bounds, so the claim is not over-read: macOS, one harness version, the gh path,
# github-skill-gate.sh as the reader. It does not prove the invariant across harness
# versions, and lifecycle-field-check.sh's identical code path was not separately exercised.
#
# The design is unchanged and stays fail-closed: on disagreement the reader looks for a file
# the writer did not create, finds nothing, and BLOCKS. A false block is visible and fixable;
# a false allow would not be. The project-directory fallback stays CONDITIONAL — #1443's
# clause to make it unconditional was contingent on the two sources DISAGREEING. Making it
# unconditional now would loosen the gate: two sessions sharing a checkout could again
# authorize each other's writes.
skill_marker_path() {
  local sid="${1:-}"
  [ -n "$sid" ] || sid="${CLAUDE_CODE_SESSION_ID:-}"
  [ -n "$sid" ] || sid="project-${CLAUDE_PROJECT_DIR:-unknown}"
  printf '%s/%s.json\n' "$(skill_marker_dir)" "$(skill_marker_slug "$sid")"
}

# Exit 0 when a marker exists AND is younger than the TTL. Absent and stale are the same
# answer on purpose — the readers treat both as "no sanctioned skill run", and block.
skill_marker_fresh() {
  local p age now mtime
  p="$(skill_marker_path "${1:-}")"
  [ -f "$p" ] || return 1
  now="$(date +%s)"
  if [ "$(uname)" = "Darwin" ]; then
    mtime="$(stat -f %m "$p" 2>/dev/null)" || return 1
  else
    mtime="$(stat -c %Y "$p" 2>/dev/null)" || return 1
  fi
  [ -n "$mtime" ] || return 1
  age=$(( now - mtime ))
  [ "$age" -lt "$SKILL_MARKER_TTL" ]
}

# Extend a live marker's window by one TTL (LAB-1425). Called by a gate on its ALLOW path,
# so the window measures time since the last SANCTIONED operation rather than since `set`.
#
# Why this and not a bigger TTL: a /workflow run, or a bulk pass over many issues, routinely
# exceeds ten minutes between setting the marker and its next gated call, and would then be
# refused mid-run — which is how "authorised bypasses" get manufactured. Widening the window
# would weaken the gate for every caller; this only helps a run that is demonstrably active.
# An abandoned marker is never touched, so it still expires on schedule.
#
# Deliberately silent and non-fatal: a gate must never fail because it could not bump an
# mtime. If the touch fails the caller simply gets the original window.
skill_marker_touch() {
  local p
  p="$(skill_marker_path "${1:-}")"
  [ -f "$p" ] || return 0
  touch "$p" 2>/dev/null || true
  return 0
}

skill_marker_set() {
  local skill="$1" ticket="${2:-}" p dir tk
  p="$(skill_marker_path)"
  dir="$(dirname "$p")"
  mkdir -p "$dir" || return 1
  if [ -n "$ticket" ]; then tk="\"$ticket\""; else tk="null"; fi
  printf '{"skill": "%s", "started_at": "%s", "ticket_key": %s}\n' \
    "$skill" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$tk" > "$p" || return 1
  printf '%s\n' "$p"
}

skill_marker_clear() { rm -f "$(skill_marker_path)"; }

# Refuse to start in the primary checkout. This is an ERGONOMICS guard, not a security
# boundary: it converts an opaque failure several steps later into an immediate message
# naming the remedy. The real enforcement is worktree-gate.sh.
#
# Only PRIMARY refuses. UNRESOLVABLE deliberately does not — over-blocking is the
# demonstrated failure mode of every gate in this tree, and the worktree gate will still
# block any actual edit with its own message.
skill_marker_require_worktree() {
  local skill="$1" lib mode
  if [ "${SKILL_ALLOW_PRIMARY:-}" = "1" ]; then
    echo "[skill-marker] SKILL_ALLOW_PRIMARY=1 — running /$skill in the primary checkout anyway." >&2
    return 0
  fi
  lib="$(dirname "${BASH_SOURCE[0]:-$0}")/worktree-facts.sh"
  [ -f "$lib" ] || return 0   # gate lib absent: not this script's business to invent a verdict
  # shellcheck source=/dev/null
  . "$lib"
  mode="$(wf_mode "$PWD")"
  [ "$mode" = "PRIMARY" ] || return 0
  cat >&2 <<MSG
[skill-marker] BLOCKED: /$skill does repo work and cannot run from the primary checkout.

The primary checkout is a deploy mirror — its files are bind-mounted into running
containers and its HEAD is shared by every concurrent session, so edits here are blocked.

Remedy — start a worktree:
    claude --worktree <KEY>-<kebab-description>
or ask to work in a worktree in this session, then re-run /$skill.

Override for a run that genuinely needs no repo write:
    SKILL_ALLOW_PRIMARY=1
MSG
  return 2
}

# Direct invocation = writer/CLI. Sourcing = reader.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  cmd="${1:-}"
  shift 2>/dev/null || true
  case "$cmd" in
    path)  skill_marker_path "${1:-}" ;;
    fresh) skill_marker_fresh "${1:-}" ;;
    set)
      [ $# -ge 1 ] || { echo "usage: skill-marker.sh set <skill> [ticket-key]" >&2; exit 64; }
      skill_marker_set "$1" "${2:-}"
      ;;
    clear) skill_marker_clear ;;
    require-worktree)
      [ $# -ge 1 ] || { echo "usage: skill-marker.sh require-worktree <skill>" >&2; exit 64; }
      skill_marker_require_worktree "$1"
      ;;
    *)
      echo "usage: skill-marker.sh {path|fresh|set <skill> [ticket]|clear|require-worktree <skill>}" >&2
      exit 64
      ;;
  esac
fi
