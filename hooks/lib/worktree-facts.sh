#!/usr/bin/env bash
# worktree-facts.sh — THE single definition of "where am I" for the worktree gate (LAB-1364).
# Sourced by worktree-gate.sh, session-bootstrap.sh, and the test suite; no mode decision
# may be implemented anywhere else.
#
# Bash 3.2-compatible (macOS ships 3.2.57 — no associative arrays, no mapfile).
# Callers must have git. jq is required by the gate itself, not by this lib.
#
# Design notes:
#   * Nothing here hardcodes /Users/fredabood/homelab. Scope is decided by the ORIGIN REMOTE
#     of the repo containing a directory, and primary-vs-worktree by git's own metadata, so
#     this survives a move to different hardware (the Mac Studio, #969).
#   * Submodules fall out for free: work inside submodules/work resolves to fredabood/work,
#     which is out of scope, so the gate goes inert with no path special-casing.

set -u

WF_SCOPE_REPO="${WF_SCOPE_REPO:-homelab}" # overridable so the test suite can scope a sandbox

# --------------------------------------------------------------- identity ---

# Physical (symlink-resolved) form of an EXISTING directory.
#
# Load-bearing: `pwd` returns the LOGICAL path, while git's --absolute-git-dir returns the
# PHYSICAL one. On macOS /var -> /private/var and /tmp -> /private/tmp, so comparing the two
# forms makes a primary checkout under either path look like a linked worktree — a
# fail-OPEN misclassification that silently unguards the repo. Caught by the test suite
# (its sandbox lives under $TMPDIR); every path comparison in this lib goes through here.
wf_realdir() { (cd "$1" 2>/dev/null && pwd -P); }

# Repo root containing $1, or empty if $1 is not inside a git work tree.
wf_repo_root() {
  local r
  r="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -n "$r" ] || return 1
  wf_realdir "$r"
}

# True when $1 is inside a git work tree at all.
wf_in_git_repo() {
  [ "$(git -C "$1" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ]
}

# Repo name from the origin remote, stripped of any .git suffix and path.
# e.g. https://github.com/fredabood/homelab.git -> homelab
wf_repo_name() {
  local url
  url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
  url="${url%.git}"
  printf '%s' "${url##*/}"
}

# True when $1 belongs to the repo this gate governs.
wf_in_scope() {
  [ "$(wf_repo_name "$1")" = "$WF_SCOPE_REPO" ]
}

# True when $1 sits in a LINKED WORKTREE rather than the primary checkout.
#
# git distinguishes them by metadata, not by path:
#   primary checkout   --absolute-git-dir == <repo>/.git            == --git-common-dir
#   linked worktree    --absolute-git-dir == <repo>/.git/worktrees/<name>
#                      --git-common-dir   == <repo>/.git
# Verified against a real linked worktree of the work submodule and both main checkouts.
#
# --git-common-dir is often returned RELATIVE to cwd (plain ".git" in a primary checkout),
# so it is resolved before comparison. Both sides are then reduced to their physical form
# via wf_realdir — see the warning there; comparing a logical path against a physical one
# is a fail-open misclassification.
wf_is_worktree() {
  local gd cd_
  gd="$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  cd_="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$cd_" in
    /*) : ;;
    *) cd_="$1/$cd_" ;;
  esac
  gd="$(wf_realdir "$gd")" || return 1
  cd_="$(wf_realdir "$cd_")" || return 1
  [ -n "$gd" ] && [ -n "$cd_" ] || return 1
  [ "$gd" != "$cd_" ]
}

# ------------------------------------------------------------------ paths ---

# Resolve $1 to an absolute PHYSICAL path WITHOUT requiring it to exist (the file being
# written usually does not yet).
#
# Always resolves the DIRECTORY part physically and re-appends the remaining tail. An
# earlier version only normalized when the deepest existing component was a directory,
# so a path to an EXISTING FILE kept its logical form and never matched the physical repo
# root — Edit on README.md was allowed while Write to a new file was blocked. The test
# suite caught it; the asymmetry is the tell.
wf_abspath() {
  local p="$1" base="$2" d tail
  case "$p" in
    /*) : ;;
    *) p="$base/$p" ;;
  esac
  d="$(dirname "$p")"
  tail="$(basename "$p")"
  while [ ! -d "$d" ] && [ -n "$d" ] && [ "$d" != "/" ] && [ "$d" != "." ]; do
    tail="$(basename "$d")/$tail"
    d="$(dirname "$d")"
  done
  d="$(wf_realdir "$d")" || d="$(dirname "$p")"
  printf '%s' "${d%/}/$tail"
}

# True when absolute path $1 lies inside directory $2.
wf_path_inside() {
  case "$1" in
    "$2") return 0 ;;
    "$2"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# True when $1 is a location we never guard even inside the repo root: scratch and
# temp space. Keeps ordinary shell work (writing to /tmp, the session scratchpad)
# free of false positives.
wf_is_scratch() {
  case "$1" in
    /dev/null | /dev/stdout | /dev/stderr) return 0 ;;
    /tmp/* | /private/tmp/* | /var/folders/*) return 0 ;;
  esac
  [ -n "${TMPDIR:-}" ] && case "$1" in "${TMPDIR%/}"/*) return 0 ;; esac
  return 1
}

# ----------------------------------------------------------------- verdict ---

# Prints exactly one of: OUT_OF_REPO | OUT_OF_SCOPE | WORKTREE | PRIMARY | UNRESOLVABLE
#
# UNRESOLVABLE means "cwd IS in a git repo but git could not answer" — the caller must
# fail CLOSED on it. OUT_OF_REPO is the one deliberate fail-open: a non-git directory is
# none of this gate's business, and treating it as guarded would break every other
# directory on the machine.
wf_mode() {
  local dir="$1"
  wf_in_git_repo "$dir" || { echo OUT_OF_REPO; return 0; }
  wf_repo_root "$dir" >/dev/null 2>&1 || { echo UNRESOLVABLE; return 0; }
  wf_in_scope "$dir" || { echo OUT_OF_SCOPE; return 0; }
  if wf_is_worktree "$dir"; then echo WORKTREE; else echo PRIMARY; fi
}

# ------------------------------------------------- .claude submodule repair ---
#
# A fresh worktree checks out the .claude GITLINK without populating it, so `.claude/`
# arrives EMPTY and the session has no project hooks, rules, skills or agents. Worse than
# absent: the hooks are still REGISTERED (project settings were read from the directory
# the session started in), so every gated tool call fails with a path that does not exist.
#
# session-bootstrap.sh has repaired this since LAB-1364 — but it is a SessionStart hook,
# and `EnterWorktree` switches directories MID-session, which does not re-fire SessionStart.
# So the repair existed and was unreachable on the very path CLAUDE.md recommends
# ("ask to work in a worktree"). Measured 2026-08-24: entering a worktree that way left
# ticket-reference-check.sh blocking every commit until `git submodule update --init
# .claude` was run by hand.
#
# It lives here, in the lib both hooks already source, rather than in a new file: the
# installer copies a FIXED list of files, so a new one would give a stale install a gate
# that sources something absent. For a gate, failing to load is not an acceptable
# failure mode.

# True when .claude is present as a directory and empty.
wf_claude_unpopulated() {
  local root="$1"
  [ -n "$root" ] || return 1
  [ -d "$root/.claude" ] || return 1
  [ -z "$(ls -A "$root/.claude" 2>/dev/null)" ]
}

# One attempt per session. A genuine failure — offline, or no credentials for the clone —
# must not re-run on every PreToolUse call for the rest of the session.
wf_claude_repair_marker() {
  local sid
  sid="$(printf '%s' "${1:-nosession}" | tr -c 'A-Za-z0-9_.-' '_')"
  printf '%s/wf-claude-repair-%s' "${TMPDIR:-/tmp}" "$sid"
}

# Returns 0 only when it actually populated the submodule.
wf_claude_repair_once() {
  local root="$1" sid="${2:-}" marker
  wf_claude_unpopulated "$root" || return 1
  marker="$(wf_claude_repair_marker "$sid")"
  [ -e "$marker" ] && return 1
  : >"$marker" 2>/dev/null || true
  git -C "$root" submodule update --init .claude >/dev/null 2>&1
}
