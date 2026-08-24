#!/usr/bin/env bash
# worktree-gate.sh — PreToolUse worktree-entry gate for fredabood/homelab (LAB-1364).
#
# WHY THIS EXISTS
#   Claude Code already enforces worktree isolation at the kernel level ONCE A SESSION IS
#   INSIDE a worktree (edits to the main checkout, Bash cwd, git redirects, unverifiable
#   command shapes — four checks, none disableable). It does NOT force a session launched in
#   the primary checkout INTO a worktree. That gap is what let concurrent sessions share one
#   HEAD and stack commits onto each other's branches (PR #1355, the rescue/* branches).
#
# WHY IT IS INSTALLED AT USER LEVEL
#   .claude is a git submodule. A fresh worktree checks out the gitlink but does not populate
#   it, so the worktree's .claude/ is EMPTY and zero project hooks fire. A gate registered in
#   the repo's .claude/settings.json would vanish exactly when a session enters a worktree.
#   It therefore lives in ~/.claude/settings.json and self-scopes by origin remote.
#
# THE HONEST GUARANTEE
#   No un-worktreed change reaches main. NOT "no un-worktreed byte can exist in a tree".
#   An agent with a shell can defeat any command-parsing gate; the merge gate (#1370) is the
#   second ring that makes the guarantee hold anyway. Do not chase parser completeness here.
#
# FAIL CLOSED: exit 2 blocks the tool call; stderr names what was blocked and the remedy.
# Parses the STDIN JSON payload (never an env var).

set -u

GATE_NAME="worktree-gate"

command -v jq >/dev/null 2>&1 || {
  echo "[$GATE_NAME] jq is required but not found — gate fails closed. Install jq." >&2
  exit 2
}

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/worktree-facts.sh"
# shellcheck source=lib/worktree-facts.sh
. "$LIB" 2>/dev/null || {
  echo "[$GATE_NAME] cannot source lib/worktree-facts.sh — gate fails closed." >&2
  exit 2
}

PAYLOAD="$(cat)"
TOOL="$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // empty' 2>/dev/null)" || TOOL=""
CWD="$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty' 2>/dev/null)" || CWD=""

block() {
  echo "[$GATE_NAME] BLOCKED: $1" >&2
  echo "" >&2
  echo "This SESSION is in the primary checkout (${PRIMARY:-unknown})." >&2
  echo "It is a deploy mirror pinned to main: its Caddyfile and stack files are" >&2
  echo "bind-mounted into running containers, and its HEAD is shared by every" >&2
  echo "concurrent session." >&2
  echo "" >&2
  echo "Remedy — move the session into a worktree, then retry:" >&2
  echo "  * ask to work in a worktree (EnterWorktree), or" >&2
  echo "  * relaunch: claude --worktree <KEY>-<slug>" >&2
  echo "" >&2
  echo "Reads, git pull/status/log/diff, docker, and anything outside the repo stay allowed here." >&2
  exit 2
}

# A target under .claude/worktrees/<x> is physically inside the primary checkout but
# belongs to a different working tree. Blocking is correct — the session must MOVE there,
# not reach in from outside, or it never gets Claude Code's own isolation checks. But the
# generic message ("editing X in the primary checkout") reads as wrong when X is plainly a
# worktree file, so that case gets its own remedy.
block_nested_worktree() {
  local target_wt="$1" fp="$2"
  echo "[$GATE_NAME] BLOCKED: $fp belongs to the worktree $target_wt," >&2
  echo "but this SESSION is in the primary checkout, so it is reaching in from outside." >&2
  echo "" >&2
  echo "A session that edits a worktree by path never gets Claude Code's own isolation" >&2
  echo "checks — it only looks isolated. Move into it instead:" >&2
  echo "  EnterWorktree with path: $target_wt" >&2
  exit 2
}

# Verb matching must ignore quoted strings — a commit MESSAGE mentioning "git merge" is not
# a merge. Strips "..." and '...' spans; verb greps run on the stripped text.
#
# LIMIT: sed is LINE-oriented, so a quoted span crossing newlines is NOT stripped. A
# multi-line command carrying prose that mentions a guarded verb therefore survives this.
# That is why verb matching is additionally ANCHORED (see cmd_segments / segment_invokes):
# stripping alone is not sufficient, as a `gh issue edit` whose body text said
# "`git commit` is blocked" proved by blocking itself.
strip_quotes() { printf '%s' "$1" | sed -e 's/"[^"]*"//g' -e "s/'[^']*'//g"; }

# One shell command segment per line: split on ; | & and newlines.
cmd_segments() { printf '%s' "$1" | tr ';|&\n' '\n\n\n\n'; }

# True when some segment actually INVOKES $2 (an alternation) as a command — i.e. the verb
# sits at the head of a segment, after optional env assignments and sudo. Prose that merely
# mentions "git commit" mid-sentence is not an invocation and no longer matches.
segment_invokes() {
  cmd_segments "$1" |
    grep -qE "^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(sudo[[:space:]]+)?($2)\b"
}

# The git SUBCOMMAND of each segment whose head is `git`, one line per segment, emitted
# as "<subcommand> <remaining args>".
#
# WHY NOT A REGEX (LAB-1482)
# --------------------------
# The old pattern was `git[^;|&]*\b(commit|merge|...)\b`: anchored at `git`, then free to
# find the verb ANYWHERE later in the segment. And `-` is a word boundary in ERE. Measured
# in a live session, all three of these read-only commands were REFUSED:
#
#   git merge-base --is-ancestor a b     \bmerge\b matches inside `merge-base`
#   git stash list                       a read-only form of a writing verb
#   git apply --check p.patch            likewise
#
# `git log --merges` and `git branch --merged` escaped only because \bmerge\b does not
# match a plural or a participle. That is luck, not a rule, and the next verb to grow a
# hyphenated sibling would have been refused too.
#
# Taking the subcommand as a WHOLE TOKEN in the subcommand position fixes the class, not
# the three instances.
git_subcommands() {
  # `|| [ -n "$seg" ]` is load-bearing: cmd_segments ends its output with printf '%s', so
  # the LAST segment carries no trailing newline and a bare `read` drops it. For a
  # single-segment command that is every segment. segment_invokes never noticed because
  # grep reads a final partial line happily; `read` does not.
  cmd_segments "$1" | while IFS= read -r seg || [ -n "$seg" ]; do
    seg="$(printf '%s' "$seg" |
      sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//; s/^[[:space:]]*(sudo[[:space:]]+)?//')"
    case "$seg" in git | git[[:space:]]*) : ;; *) continue ;; esac
    # shellcheck disable=SC2086
    set -- $seg
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        # Global flags that take a separate value.
        -C | -c | --git-dir | --work-tree | --namespace | --exec-path)
          shift
          [ "$#" -gt 0 ] && shift
          continue
          ;;
        -*) shift; continue ;;
        *) printf '%s\n' "$*"; break ;;
      esac
    done
  done
}

# True when some segment invokes a git subcommand that moves HEAD or writes history.
# Read-only forms of otherwise-writing verbs are carved out here, the same way
# `git checkout -- <path>` is carved out below.
git_invokes_write() {
  local rest sub args second
  while IFS= read -r rest; do
    [ -n "$rest" ] || continue
    sub="${rest%% *}"
    args="${rest#"$sub"}"
    case "$sub" in
      commit | merge | rebase | reset | cherry-pick | push | am | revert) return 0 ;;
      stash)
        # `stash list` / `stash show` only read. Bare `stash`, and push/pop/apply/drop/
        # clear/branch, all write.
        second="$(printf '%s' "$args" | awk '{print $1}')"
        case "$second" in list | show) continue ;; *) return 0 ;; esac
        ;;
      apply)
        # --check/--stat/--summary/--numstat report without touching the tree.
        printf '%s' "$args" |
          grep -qE '(^|[[:space:]])--(check|stat|summary|numstat)([[:space:]]|$)' && continue
        return 0
        ;;
    esac
  done <<EOF
$(git_subcommands "$1")
EOF
  return 1
}

# Branch switching moves the shared HEAD. Separate from the above because it carries its
# own `-- <path>` exception.
git_invokes_switch() {
  local rest
  while IFS= read -r rest; do
    [ -n "$rest" ] || continue
    case "${rest%% *}" in checkout | switch) return 0 ;; esac
  done <<EOF
$(git_subcommands "$1")
EOF
  return 1
}

# Normalize ONE segment so the verb that actually runs sits at its head.
#
# Anchoring the verb match (segment_invokes) fixed prose-as-invocation but created the
# mirror-image hole: a verb hidden behind a wrapper is no longer at the head either. All
# eight of these reached the shared checkout unchallenged --
#   bash -c "<git write>"   sh -c "rm ..."   eval "..."   timeout 5 <git write>
#   nice -n 10 <git write>  env <git write>  command <git write>  exec <git write>
# because the segment head was `bash` / `timeout` / `env`, and for the -c forms
# strip_quotes had already deleted the payload being hidden.
#
# Two passes, repeated to a bounded depth so `bash -c "timeout 5 <git write>"` resolves:
#   1. drop leading env assignments and wrapper words. The flag-carrying wrappers must
#      also consume their own option values and (for timeout) its duration positional,
#      or a flag is left looking like the command -- the GHSA-7mqg-cx4g-x2rf shape.
#   2. drop a shell-interpreter `-c` / `eval` prefix and remove the quote characters that
#      delimited its argument, so the inner command is classified as if typed directly.
#      Quotes are removed ONLY when the unwrap actually matched, so `sha256sum "..."`
#      (which merely starts with "sh") keeps its quoting and its prose protection.
normalize_segment() {
  local s="$1" prev="" t i=0
  while [ "$i" -lt 4 ] && [ "$s" != "$prev" ]; do
    prev="$s"
    s="$(printf '%s' "$s" | sed -E \
      -e 's/^[[:space:]]+//' \
      -e 's/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)+//' \
      -e 's/^(sudo|env|command|exec|time|nohup|setsid)[[:space:]]+//' \
      -e 's/^nice([[:space:]]+(-n[[:space:]]*[0-9]+|--adjustment[[:space:]]+[0-9]+|-[0-9]+))?[[:space:]]+//' \
      -e 's/^stdbuf([[:space:]]+-[ioe][[:space:]]*[A-Za-z0-9]+)+[[:space:]]+//' \
      -e 's/^xargs([[:space:]]+(-[0adprtx]+|-I[[:space:]]*[^[:space:]]+|-[nP][[:space:]]*[0-9]+))*[[:space:]]+//' \
      -e 's/^timeout([[:space:]]+(-s[[:space:]]*[A-Za-z0-9]+|--signal=[A-Za-z0-9]+|-k[[:space:]]*[0-9smhd.]+|--kill-after=[0-9smhd.]+|--preserve-status|--foreground))*[[:space:]]+[0-9]+[smhd.]*[[:space:]]+//')"
    # An absolute interpreter path (`/bin/bash -c`) and a combined flag that merely
    # CONTAINS c (`bash -lc`) are the same hole as `bash -c`; both are matched here.
    t="$(printf '%s' "$s" | sed -E \
      -e 's@^(/[^[:space:]]*/)?(bash|sh|zsh|dash|ksh)([[:space:]]+-[A-Za-z]+)*[[:space:]]+-[A-Za-z]*c[[:space:]]+@@' \
      -e 's/^eval[[:space:]]+//')"
    if [ "$t" != "$s" ]; then
      s="$(printf '%s' "$t" | tr -d '\042\047')"
    fi
    i=$((i + 1))
  done
  printf '%s' "$s"
}

# Whole command -> one normalized segment per line, ready for segment_invokes and for the
# per-verb target extraction. An unwrapped inner command may carry its own `;` / `&&`; those
# are re-split downstream because every consumer runs cmd_segments over this output.
expand_code() {
  local seg out=""
  while IFS= read -r seg; do
    out="$out$(normalize_segment "$seg")
"
  done <<EOF
$(cmd_segments "$1")
EOF
  printf '%s' "$out"
}

# Shell verbs that write files. Shared by the primary-checkout rules and the worktree
# redirect guard so the two cannot drift apart.
#
# touch/mkdir/ln/chmod/chown added 2026-08-24 (LAB-1482). Measured in a live session with
# this gate installed and firing, they were ALL permitted against the primary checkout
# while rm/mv/cp/tee/dd/sed -i were refused. The asymmetry was the tell: the gate stopped
# you DESTROYING a file in the shared checkout but not CREATING one, REPLACING it with a
# symlink, or changing its mode.
#
# `ln` is the one that mattered. `ln -sf /anywhere <repo>/stacks/core-stack.yml` succeeds,
# and that checkout is bind-mounted into running containers — precisely the harm this
# gate's own block message describes. Blocking the verb outright is right: `ln -sf`
# replaces, plain `ln` onto an existing target fails, and this is a discipline gate rather
# than a hardened surface. `install` was already here, which is the precedent — the bar is
# "can it mutate a path", not "is it commonly typed".
MUTATORS_ALL='(rm|mv|cp|tee|dd|truncate|install|touch|mkdir|ln|chmod|chown|sed[^;|&]*-i)\b'

# ------------------------------------------------- anti-self-tamper (always) ---
# Checked BEFORE the mode short-circuit: the installed gate lives in ~/.claude, which is
# outside any repo, so a mode check would have already exited 0 and let it through.
# Only the edit TOOLS are blocked — the installer writes these paths via Bash by design.
GATE_HOME="$HOME/.claude"
case "$TOOL" in
  Edit | Write | MultiEdit | NotebookEdit)
    FP="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)"
    if [ -n "$FP" ]; then
      ABS="$(wf_abspath "$FP" "${CWD:-$PWD}")"
      case "$ABS" in
        "$GATE_HOME"/settings.json | "$GATE_HOME"/hooks/worktree-gate.sh | \
          "$GATE_HOME"/hooks/session-bootstrap.sh | "$GATE_HOME"/hooks/lib/*)
          echo "[$GATE_NAME] BLOCKED: $FP is the installed gate itself." >&2
          echo "Edit the canonical copy in the repo (.claude/hooks/) from a worktree and" >&2
          echo "re-run internal/scripts/install-claude-user-hooks.sh." >&2
          exit 2
          ;;
      esac
    fi
    ;;
esac

# ------------------------------------------------------------- kill switch ---
# Agent-proof by construction: a PreToolUse hook is spawned by Claude Code with Claude
# Code's OWN environment, before the agent's command runs. A `VAR=x cmd` prefix inside an
# agent Bash call cannot reach the hook deciding on that very call. So this is reachable
# by the human at launch (HOMELAB_WORKTREE_GATE=off claude) and not by the model.
if [ "${HOMELAB_WORKTREE_GATE:-}" = "off" ]; then
  echo "[$GATE_NAME] DISABLED via HOMELAB_WORKTREE_GATE=off — worktree isolation is NOT enforced." >&2
  exit 0
fi

# --------------------------------------------------------------------- mode ---
[ -n "$CWD" ] || {
  echo "[$GATE_NAME] payload carried no cwd — gate fails closed (mode would be a guess)." >&2
  exit 2
}

MODE="$(wf_mode "$CWD")"

# A worktree whose .claude never got populated has NO project hooks — and they are still
# registered, so every gated call fails on a missing path instead of being evaluated.
# session-bootstrap.sh repairs this, but it only runs at SessionStart, and EnterWorktree
# switches directories mid-session. This gate is user-level and fires on every Bash and
# edit call, which makes it the only place that can still reach the problem (LAB-1495).
#
# Cost on the normal path is one `[ -d ]` test: wf_claude_unpopulated returns immediately
# unless .claude exists AND is empty.
if [ "$MODE" = WORKTREE ] && command -v wf_claude_repair_once >/dev/null 2>&1; then
  SID="$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null)"
  if wf_claude_repair_once "$(wf_repo_root "$CWD" 2>/dev/null)" "$SID"; then
    echo "[$GATE_NAME] .claude was empty in this worktree and has been initialized." >&2
    echo "Project hooks, rules and skills are now loaded." >&2
  fi
fi

# ------------------------------------------- worktree: guard the shared checkout ---
# Claude Code's native isolation covers a session that entered a worktree via
# EnterWorktree or --worktree. It does NOT cover a session that merely `cd`-ed into one
# with Bash: cwd moves (so this gate is satisfied) while native isolation never engages.
# In that state `git -C <primary> commit` would reach the shared checkout unchallenged.
# This is the one place the gate deliberately overlaps native isolation — it is redundant
# for a properly entered worktree and load-bearing for a cd-ed one.
if [ "$MODE" = WORKTREE ] && [ "$TOOL" = "Bash" ]; then
  CMD="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  if [ -n "$CMD" ]; then
    COMMON="$(git -C "$CWD" rev-parse --git-common-dir 2>/dev/null)"
    case "$COMMON" in /*) : ;; *) COMMON="$CWD/$COMMON" ;; esac
    SHARED="$(dirname "$(wf_realdir "$COMMON" 2>/dev/null || echo /nonexistent)")"
    if [ -n "$SHARED" ] && [ "$SHARED" != "/" ]; then
      CODE="$(strip_quotes "$(expand_code "$CMD")")"
      # Form extraction scans the RAW text as well as the normalized text. normalize_segment
      # strips leading env assignments to expose a wrapped verb, which also deletes the
      # `GIT_DIR=` / `GIT_WORK_TREE=` this guard is looking for -- scanning only the
      # normalized text silently unblocked the GIT_DIR redirect. Raw catches the env forms;
      # normalized catches a `git -C <shared>` hidden inside `bash -c "..."`.
      SCAN="$(strip_quotes "$CMD")
$CODE"
      WT_ROOT="$(wf_repo_root "$CWD" 2>/dev/null)"
      # `cd <primary>` is only a redirect when the command also RUNS something that could
      # write there. A bare `cd` back to the primary checkout is navigation, and blocking
      # it strands the session with no way home — which this gate did to its own author
      # the first time it ran. The -C / --git-dir / GIT_DIR forms need no such qualifier:
      # they are git invocations by construction.
      # Qualify on a WRITING command, not on git generally: `cd <primary> && git status`
      # is a read and must stay allowed, or the session cannot even look at the checkout
      # it deploys from.
      FORMS='-C[[:space:]]+|--git-dir[= ]|--work-tree[= ]|GIT_DIR=|GIT_WORK_TREE='
      if git_invokes_write "$CODE" || git_invokes_switch "$CODE" ||
        segment_invokes "$CODE" "$MUTATORS_ALL"; then
        FORMS="$FORMS|(^|[[:space:]])cd[[:space:]]+"
      fi
      # Extract the OPERAND of each redirect form and resolve it, rather than matching the
      # shared path as a literal string: the command may spell it logically (/var/...)
      # while git reports it physically (/private/var/...). Same symlink trap as wf_realdir.
      for tok in $(printf '%s' "$SCAN" |
        grep -oE "($FORMS)[^[:space:];|&]+" |
        sed -E 's/^.*(-C[[:space:]]+|--git-dir[= ]|--work-tree[= ]|GIT_DIR=|GIT_WORK_TREE=|cd[[:space:]]+)//'); do
        [ -n "$tok" ] || continue
        RESOLVED="$(wf_abspath "$tok" "$CWD")"
        case "$RESOLVED" in */.git | */.git/*) RESOLVED="${RESOLVED%%/.git*}" ;; esac
        # Claude Code's native worktrees live at <shared>/.claude/worktrees/<name>, so EVERY
        # worktree is inside the shared checkout by path containment. Without these two
        # exemptions the guard reads `cd <this very worktree> && <write>` as a redirect and
        # strands the session -- the same over-block shape as the bare-cd bug in #1378.
        # A worktree is never the primary checkout, whatever its path says.
        [ -n "$WT_ROOT" ] && wf_path_inside "$RESOLVED" "$WT_ROOT" && continue
        wf_path_inside "$RESOLVED" "$SHARED/.claude/worktrees" && continue
        if wf_path_inside "$RESOLVED" "$SHARED"; then
          echo "[$GATE_NAME] BLOCKED: this command redirects into the shared checkout" >&2
          echo "$SHARED from inside a worktree." >&2
          echo "" >&2
          echo "Reaching into the primary checkout moves the HEAD every other session" >&2
          echo "depends on. Do that work from a session actually rooted there, or stay" >&2
          echo "in this worktree and land the change through a PR." >&2
          exit 2
        fi
      done
    fi
  fi
fi

case "$MODE" in
  OUT_OF_REPO | OUT_OF_SCOPE | WORKTREE) exit 0 ;;
  UNRESOLVABLE)
    echo "[$GATE_NAME] cwd is inside a git repo but git could not resolve it — fails closed." >&2
    exit 2
    ;;
  PRIMARY) : ;;
  *)
    echo "[$GATE_NAME] unknown mode '$MODE' — fails closed." >&2
    exit 2
    ;;
esac

PRIMARY="$(wf_repo_root "$CWD")"

# ===================================================== PRIMARY CHECKOUT ONLY ===

case "$TOOL" in

  Edit | Write | MultiEdit | NotebookEdit)
    FP="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)"
    [ -n "$FP" ] || exit 0
    ABS="$(wf_abspath "$FP" "$CWD")"
    wf_is_scratch "$ABS" && exit 0
    if wf_path_inside "$ABS" "$PRIMARY"; then
      TARGET_DIR="$(dirname "$ABS")"
      if [ -d "$TARGET_DIR" ] && wf_is_worktree "$TARGET_DIR"; then
        block_nested_worktree "$(wf_repo_root "$TARGET_DIR")" "$FP"
      fi
      block "editing $FP in the primary checkout."
    fi
    exit 0
    ;;

  Bash)
    CMD="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    [ -n "$CMD" ] || exit 0
    # expand_code first: wrapper prefixes are stripped and `bash -c` / `eval` payloads are
    # lifted to segment heads BEFORE strip_quotes runs, so a hidden verb is classified as
    # an invocation rather than deleted along with its quotes.
    CODE="$(strip_quotes "$(expand_code "$CMD")")"

    # --- git verbs that move HEAD or write history -----------------------------
    # Allowlist-by-omission: pull/fetch/status/log/diff/show/worktree add|list are absent
    # from these patterns and therefore pass.
    #
    # Matching is ANCHORED to the head of a command segment. An earlier version matched
    # `\bgit[^;|&]*\bcommit\b` anywhere, which blocked a `gh issue edit` whose body text
    # contained the words "git commit" — strip_quotes could not remove it because the
    # quoted span crossed newlines and sed works line by line.
    if git_invokes_write "$CODE"; then
      block "a history-moving git command in the primary checkout."
    fi
    # Branch switching moves the shared HEAD — the exact failure this gate exists to stop.
    if git_invokes_switch "$CODE"; then
      # `git checkout -- <path>` and `git checkout <sha> -- <path>` restore files without
      # moving HEAD; they are how a deploy mirror recovers a clobbered bind-mounted config.
      printf '%s' "$CODE" | grep -qE '\bgit[^;|&]*\b(checkout|switch)\b[^;|&]*--[[:space:]]' ||
        block "git checkout/switch moves the shared HEAD for every concurrent session."
    fi

    # --- file-mutating shell verbs --------------------------------------------
    # Redirect pattern excludes fd-dups ([^&]) so `2>&1` and `>&2` never trip it. The verb
    # forms are anchored the same way as the git verbs, so prose mentioning "rm" or "cp"
    # inside a multi-line payload is not mistaken for an invocation.
    if printf '%s' "$CODE" | grep -qE '>[[:space:]]*[^&[:space:]]' || segment_invokes "$CODE" "$MUTATORS_ALL"; then
      VERDICT=allow
      SAW_PATH=no

      is_target() { # $1 token, $2 "redirect"|"word"
        case "$1" in
          rm | mv | cp | tee | sed | dd | truncate | install | touch | mkdir | ln | chmod | \
            chown | echo | cat | printf | git | gh | \
            docker | sudo | env | bash | sh | python3 | jq | then | do | fi | done | if | else) return 1 ;;
          *=*) return 1 ;;
        esac
        # Redirect operands and destinations always count, existing or not.
        case "$2" in redirect | dest) return 0 ;; esac
        # Absolute paths always count.
        case "$1" in /*) return 0 ;; esac
        # A RELATIVE token counts only if it actually exists. Without this, a jq filter
        # (`--jq .body`) and a flag value that looks like a path (`--repo owner/name`)
        # were both read as repo-relative files and blocked ordinary reads.
        [ -e "$CWD/$1" ] && return 0
        return 1
      }

      check_tok() { # $1 token
        # A token carrying an unexpanded variable or glob cannot be resolved statically.
        case "$1" in
          *'$'* | *'`'* | *'*'* | *'?'*)
            SAW_PATH=yes
            VERDICT=block
            return
            ;;
        esac
        SAW_PATH=yes
        local abs
        abs="$(wf_abspath "$1" "$CWD")"
        wf_is_scratch "$abs" && return
        wf_path_inside "$abs" "$PRIMARY" && VERDICT=block
      }

      # Which operands are WRITTEN depends on the verb, so targets are collected per
      # segment rather than from the command as a whole:
      #   cp / install  only the destination — the sources are reads, and
      #                 `cp README.md /tmp/x` must stay allowed
      #   mv / rm       every operand — a move removes its source too
      #   tee / sed -i  every operand
      #   redirects     the operand, in any segment, existing or not
      while IFS= read -r seg; do
        [ "$VERDICT" = block ] && break
        [ -n "$seg" ] || continue

        for t in $(printf '%s' "$seg" | grep -oE '>>?[[:space:]]*[^[:space:]]+' | sed -e 's/^>>*[[:space:]]*//'); do
          [ "$VERDICT" = block ] && break
          is_target "$t" redirect && check_tok "$t"
        done
        [ "$VERDICT" = block ] && break

        HEAD="$(printf '%s' "$seg" |
          sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//; s/^(sudo[[:space:]]+)?//' |
          awk '{print $1}')"
        OPERANDS="$(printf '%s' "$seg" | grep -oE '[^[:space:]]+' | grep -vE '^[->]' | tail -n +2 || true)"

        case "$HEAD" in
          cp | install | mv | ln)
            # Destination: written, so it counts even if it does not exist yet.
            LAST="$(printf '%s' "$seg" | awk '{print $NF}')"
            is_target "$LAST" dest && check_tok "$LAST"
            ;;
        esac
        # `ln -s <target>` with no destination creates the link in the CWD, which in this
        # branch IS the primary checkout. The destination is implicit, so there is no token
        # to resolve — check the cwd itself rather than letting it through unexamined.
        if [ "$HEAD" = ln ] && [ "$(printf '%s' "$OPERANDS" | wc -w | tr -d ' ')" -lt 2 ]; then
          check_tok "."
        fi
        [ "$VERDICT" = block ] && break
        case "$HEAD" in
          touch | mkdir | chmod | chown)
            # Every operand is written: touch/mkdir create, chmod/chown mutate metadata.
            # `word` rather than `dest` on purpose — a mode or owner argument (600, u:g) is
            # not a path, and `word` requires a relative token to EXIST before it counts, so
            # `chmod 600 /tmp/x` from inside the repo is not read as touching ./600.
            for t in $OPERANDS; do
              [ "$VERDICT" = block ] && break
              is_target "$t" word && check_tok "$t"
            done
            ;;
        esac
        [ "$VERDICT" = block ] && break
        case "$HEAD" in
          mv | rm | tee | truncate | dd | sed)
            # Sources too: a move or remove takes the original away. cp/install are
            # absent here on purpose — their sources are only read.
            for t in $OPERANDS; do
              [ "$VERDICT" = block ] && break
              is_target "$t" word && check_tok "$t"
            done
            ;;
        esac
      done <<EOF
$(cmd_segments "$CODE")
EOF
      # No resolvable path at all: relative operands default to cwd, which IS the repo.
      [ "$SAW_PATH" = no ] && VERDICT=block
      [ "$VERDICT" = block ] &&
        block "a file-mutating shell command whose target resolves inside the primary checkout (or could not be resolved statically)."
    fi

    exit 0
    ;;
esac

exit 0
