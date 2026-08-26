#!/usr/bin/env bash
# worktree-gate.test.sh — tests for the LAB-1364 worktree entry gate.
# Harness modelled on submodules/work/.claude/hooks/tests/run.sh: a real sandbox git repo,
# synthetic stdin payloads, exit-code assertions, PASS/FAIL counters, and the final
# `[ "$FAIL" -eq 0 ]` as the script's exit status.
#
# Run: bash .claude/hooks/tests/worktree-gate.test.sh

set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$HOOKS_DIR/worktree-gate.sh"
BOOT="$HOOKS_DIR/session-bootstrap.sh"
PASS=0
FAIL=0

# The sandbox must NOT live anywhere wf_is_scratch() calls scratch — /tmp, /private/tmp,
# /var/folders, $TMPDIR — because the gate exits 0 on those paths without ever consulting
# its rules. A sandbox there turns every "must block" assertion into a silent pass.
#
# This suite was macOS-only by accident until LAB-1425. There `mktemp -d` yields
# /var/folders/…, which wf_abspath resolves through the /private symlink to
# /private/var/folders/… — matching none of the scratch patterns, so the gate guarded it and
# the tests were real. On Linux `mktemp -d` yields /tmp/…, which matches /tmp/* directly:
# 21 of the block assertions passed as allows the first time this ran on a hosted runner.
#
# $HOME is scratch on neither platform. Overridable for a machine where it is unusual.
SANDBOX="$(mktemp -d "${WF_TEST_ROOT:-$HOME}/wf-gate-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

# --- sandbox: a primary checkout, a linked worktree, and an out-of-scope repo -----
# WF_SCOPE_REPO is exported so the gate treats the sandbox repo named "homelab" as in-scope
# without needing a real GitHub remote.
export WF_SCOPE_REPO=homelab

PRIMARY="$SANDBOX/homelab"
mkdir -p "$PRIMARY"
cd "$PRIMARY" || { echo "cannot enter the sandbox primary checkout" >&2; exit 1; }
git init -q -b main
git config user.email t@t && git config user.name t
git remote add origin https://github.com/fredabood/homelab.git
mkdir -p internal/caddy stacks
echo "root" >README.md
echo "caddy" >internal/caddy/Caddyfile
git add -A && git commit -qm "init"
git worktree add -q "$SANDBOX/wt" -b feature main

# A second worktree in the REAL layout: Claude Code nests its worktrees INSIDE the primary
# checkout at .claude/worktrees/<name>. The sibling "$SANDBOX/wt" above cannot reproduce
# "a worktree is inside the shared checkout by path containment", which is exactly why the
# redirect guard's over-block on `cd <own worktree>` survived 86 assertions.
mkdir -p "$PRIMARY/.claude/worktrees"
git worktree add -q "$PRIMARY/.claude/worktrees/nested" -b nested main
NESTED="$PRIMARY/.claude/worktrees/nested"
mkdir -p "$NESTED/sub"

OTHER="$SANDBOX/other"
mkdir -p "$OTHER"
git -C "$OTHER" init -q -b main
git -C "$OTHER" config user.email t@t && git -C "$OTHER" config user.name t
git -C "$OTHER" remote add origin https://github.com/fredabood/dirtydata.git
echo x >"$OTHER/f.txt"
git -C "$OTHER" add -A && git -C "$OTHER" commit -qm init

NONGIT="$SANDBOX/plain"
mkdir -p "$NONGIT"

# --- harness -----------------------------------------------------------------
run_hook() { # $1 script, $2 payload -> $HOOK_EXIT, $HOOK_ERR
  HOOK_ERR="$(printf '%s' "$2" | bash "$1" 2>&1 >/dev/null)"
  HOOK_EXIT=$?
}

edit_payload() { # $1 path, $2 cwd, $3 tool(optional)
  jq -cn --arg p "$1" --arg c "$2" --arg t "${3:-Edit}" \
    '{tool_name:$t, cwd:$c, tool_input:{file_path:$p}}'
}
bash_payload() { # $1 command, $2 cwd
  jq -cn --arg m "$1" --arg c "$2" '{tool_name:"Bash", cwd:$c, tool_input:{command:$m}}'
}

expect() { # $1 desc, $2 expected exit, $3 script, $4 payload
  run_hook "$3" "$4"
  if [ "$HOOK_EXIT" -eq "$2" ]; then
    PASS=$((PASS + 1))
    echo "  ok: $1"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $1 (expected $2, got $HOOK_EXIT) [$HOOK_ERR]"
  fi
}

# =============================================================== mode detection
echo "mode detection (lib):"
# shellcheck source=../lib/worktree-facts.sh
. "$HOOKS_DIR/lib/worktree-facts.sh"
check_mode() { # $1 desc, $2 dir, $3 expected
  local got
  got="$(wf_mode "$2")"
  if [ "$got" = "$3" ]; then
    PASS=$((PASS + 1))
    echo "  ok: $1"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $1 (expected $3, got $got)"
  fi
}
check_mode "primary checkout -> PRIMARY" "$PRIMARY" PRIMARY
check_mode "linked worktree -> WORKTREE" "$SANDBOX/wt" WORKTREE
check_mode "different repo -> OUT_OF_SCOPE" "$OTHER" OUT_OF_SCOPE
check_mode "non-git dir -> OUT_OF_REPO" "$NONGIT" OUT_OF_REPO

# ============================================================ blocks in primary
echo "blocks in the primary checkout:"
expect "Edit on a repo file blocked" 2 "$GATE" "$(edit_payload "$PRIMARY/README.md" "$PRIMARY")"
expect "Edit on a relative repo path blocked" 2 "$GATE" "$(edit_payload "README.md" "$PRIMARY")"
expect "Write blocked" 2 "$GATE" "$(edit_payload "$PRIMARY/new.txt" "$PRIMARY" Write)"
expect "MultiEdit blocked (currently ungated in homelab)" 2 "$GATE" "$(edit_payload "$PRIMARY/README.md" "$PRIMARY" MultiEdit)"
expect "NotebookEdit blocked (currently ungated in homelab)" 2 "$GATE" "$(edit_payload "$PRIMARY/n.ipynb" "$PRIMARY" NotebookEdit)"
expect "git commit blocked" 2 "$GATE" "$(bash_payload 'git commit -m "x"' "$PRIMARY")"
expect "git checkout -b blocked (moves shared HEAD)" 2 "$GATE" "$(bash_payload 'git checkout -b feat' "$PRIMARY")"
expect "git switch -c blocked" 2 "$GATE" "$(bash_payload 'git switch -c feat' "$PRIMARY")"
expect "git merge blocked" 2 "$GATE" "$(bash_payload 'git merge origin/main' "$PRIMARY")"
expect "git rebase blocked" 2 "$GATE" "$(bash_payload 'git rebase main' "$PRIMARY")"
expect "git push blocked" 2 "$GATE" "$(bash_payload 'git push origin main' "$PRIMARY")"
expect "git stash blocked (can capture another session's work)" 2 "$GATE" "$(bash_payload 'git stash push -m wip' "$PRIMARY")"
expect "sed -i on a repo file blocked" 2 "$GATE" "$(bash_payload 'sed -i "" s/a/b/ internal/caddy/Caddyfile' "$PRIMARY")"
expect "redirect into a repo file blocked" 2 "$GATE" "$(bash_payload 'echo x > README.md' "$PRIMARY")"
expect "append into a repo file blocked" 2 "$GATE" "$(bash_payload 'echo x >> internal/caddy/Caddyfile' "$PRIMARY")"
expect "rm of a repo file blocked" 2 "$GATE" "$(bash_payload 'rm internal/caddy/Caddyfile' "$PRIMARY")"
expect "mv of a repo file blocked" 2 "$GATE" "$(bash_payload 'mv README.md OLD.md' "$PRIMARY")"
expect "tee into a repo file blocked" 2 "$GATE" "$(bash_payload 'echo x | tee README.md' "$PRIMARY")"
expect "unresolvable variable target blocked (fails closed)" 2 "$GATE" "$(bash_payload 'rm -rf $SOMEDIR' "$PRIMARY")"

# LAB-1482. Every one of these was ALLOWED against the primary checkout while rm/mv/cp
# were refused — the gate stopped you destroying a file in the shared checkout but not
# creating one, replacing it with a symlink, or changing its mode.
expect "touch a new repo file blocked" 2 "$GATE" "$(bash_payload 'touch newfile.txt' "$PRIMARY")"
expect "touch an absolute repo path blocked" 2 "$GATE" "$(bash_payload "touch $PRIMARY/newfile.txt" "$PRIMARY")"
expect "mkdir in the repo blocked" 2 "$GATE" "$(bash_payload 'mkdir newdir' "$PRIMARY")"
expect "chmod on a repo file blocked" 2 "$GATE" "$(bash_payload 'chmod 600 internal/caddy/Caddyfile' "$PRIMARY")"
expect "chown on a repo file blocked" 2 "$GATE" "$(bash_payload 'chown root README.md' "$PRIMARY")"
# The concrete harm: that Caddyfile is bind-mounted into a running container.
expect "ln -sf REPLACING a bind-mounted config blocked" 2 "$GATE" "$(bash_payload 'ln -sf /tmp/evil internal/caddy/Caddyfile' "$PRIMARY")"
expect "ln -sf onto an absolute repo path blocked" 2 "$GATE" "$(bash_payload "ln -sf /tmp/evil $PRIMARY/stacks/core-stack.yml" "$PRIMARY")"
# `ln -s <target>` links into the CWD, which here IS the primary checkout. The
# destination is implicit, so there is no token to resolve — it must not slip through.
expect "ln -s with an implicit destination blocked" 2 "$GATE" "$(bash_payload 'ln -s /tmp/target' "$PRIMARY")"

# The carve-outs below must not leak into the writing forms.
expect "git stash pop still blocked" 2 "$GATE" "$(bash_payload 'git stash pop' "$PRIMARY")"
expect "git stash apply still blocked" 2 "$GATE" "$(bash_payload 'git stash apply' "$PRIMARY")"
expect "git apply without --check still blocked" 2 "$GATE" "$(bash_payload 'git apply p.patch' "$PRIMARY")"
expect "git am still blocked" 2 "$GATE" "$(bash_payload 'git am p.patch' "$PRIMARY")"
expect "git reset --hard still blocked" 2 "$GATE" "$(bash_payload 'git reset --hard origin/main' "$PRIMARY")"
expect "git revert still blocked" 2 "$GATE" "$(bash_payload 'git revert HEAD' "$PRIMARY")"
expect "git cherry-pick still blocked" 2 "$GATE" "$(bash_payload 'git cherry-pick abc123' "$PRIMARY")"

# =========================================================== allows in primary
echo "allows in the primary checkout (deploys happen here):"
expect "docker compose ps allowed" 0 "$GATE" "$(bash_payload 'docker compose -f stacks/core-stack.yml --env-file .env ps' "$PRIMARY")"
expect "git pull allowed" 0 "$GATE" "$(bash_payload 'git pull --ff-only' "$PRIMARY")"
expect "git fetch allowed" 0 "$GATE" "$(bash_payload 'git fetch origin --prune' "$PRIMARY")"
expect "git status allowed" 0 "$GATE" "$(bash_payload 'git status --short' "$PRIMARY")"
expect "git log allowed" 0 "$GATE" "$(bash_payload 'git log --oneline -10' "$PRIMARY")"
expect "git diff allowed" 0 "$GATE" "$(bash_payload 'git diff --stat' "$PRIMARY")"
expect "git worktree add allowed (the remedy must never be blocked)" 0 "$GATE" "$(bash_payload 'git worktree add .claude/worktrees/x -b x origin/main' "$PRIMARY")"
expect "git worktree list allowed" 0 "$GATE" "$(bash_payload 'git worktree list' "$PRIMARY")"
expect "git checkout -- <path> allowed (restores bind-mounted config, no HEAD move)" 0 "$GATE" "$(bash_payload 'git checkout -- internal/caddy/Caddyfile' "$PRIMARY")"
expect "redirect to /tmp allowed" 0 "$GATE" "$(bash_payload 'echo x > /tmp/probe.txt' "$PRIMARY")"
expect "redirect to /dev/null allowed" 0 "$GATE" "$(bash_payload 'somecmd > /dev/null' "$PRIMARY")"
expect "fd-dup redirect not treated as a write" 0 "$GATE" "$(bash_payload 'somecmd 2>&1' "$PRIMARY")"
expect "Edit outside the repo allowed" 0 "$GATE" "$(edit_payload "/tmp/scratch.md" "$PRIMARY")"
expect "quoted verb in a commit message is not a commit" 0 "$GATE" "$(bash_payload 'echo "how to git commit and git push" > /tmp/notes.md' "$PRIMARY")"
expect "read-only command allowed" 0 "$GATE" "$(bash_payload 'cat README.md' "$PRIMARY")"

# LAB-1482, the other direction. The old pattern was `git[^;|&]*\b(commit|merge|...)\b` —
# anchored at `git`, then free to find the verb anywhere later in the segment — and `-` is
# a word boundary in ERE. All three of these read-only commands were REFUSED, each costing
# a workaround in a real session. `git log --merges` and `git branch --merged` escaped only
# because \bmerge\b does not match a plural or a participle, which is luck, not a rule.
expect "git merge-base allowed (read-only; \\bmerge\\b used to match inside it)" 0 "$GATE" "$(bash_payload 'git merge-base --is-ancestor HEAD origin/main' "$PRIMARY")"
expect "git stash list allowed (read-only)" 0 "$GATE" "$(bash_payload 'git stash list' "$PRIMARY")"
expect "git stash show allowed (read-only)" 0 "$GATE" "$(bash_payload 'git stash show' "$PRIMARY")"
expect "git apply --check allowed (reports, does not apply)" 0 "$GATE" "$(bash_payload 'git apply --check p.patch' "$PRIMARY")"
expect "git apply --stat allowed" 0 "$GATE" "$(bash_payload 'git apply --stat p.patch' "$PRIMARY")"
expect "git log --merges allowed" 0 "$GATE" "$(bash_payload 'git log --merges --oneline' "$PRIMARY")"
expect "git branch --merged allowed" 0 "$GATE" "$(bash_payload 'git branch --merged main' "$PRIMARY")"
expect "git -C <elsewhere> log allowed (global flag skipped, not read as a verb)" 0 "$GATE" "$(bash_payload 'git -C /tmp/other log --oneline' "$PRIMARY")"

# The new mutators must only bite inside the repo.
expect "touch outside the repo allowed" 0 "$GATE" "$(bash_payload 'touch /tmp/probe.txt' "$PRIMARY")"
expect "mkdir outside the repo allowed" 0 "$GATE" "$(bash_payload 'mkdir -p /tmp/probe-dir' "$PRIMARY")"
expect "chmod outside the repo allowed (mode arg is not a path)" 0 "$GATE" "$(bash_payload 'chmod 600 /tmp/probe.txt' "$PRIMARY")"
expect "ln -sf outside the repo allowed" 0 "$GATE" "$(bash_payload 'ln -sf /tmp/a /tmp/b' "$PRIMARY")"
# Anchoring property (see the comment at the MUTATORS_ALL definition): prose mentioning a
# verb is not an invocation of it. Regressing this makes the gate unusable for writing
# about itself.
expect "prose naming the new verbs is not an invocation" 0 "$GATE" "$(bash_payload 'echo "you can touch, chmod or ln -sf a file" > /tmp/notes.md' "$PRIMARY")"

# =================================================================== worktree
echo "allows in a worktree (native isolation takes over):"
expect "Edit in a worktree allowed" 0 "$GATE" "$(edit_payload "$SANDBOX/wt/README.md" "$SANDBOX/wt")"
expect "git commit in a worktree allowed" 0 "$GATE" "$(bash_payload 'git commit -m "x"' "$SANDBOX/wt")"
expect "sed -i in a worktree allowed" 0 "$GATE" "$(bash_payload 'sed -i "" s/a/b/ README.md' "$SANDBOX/wt")"
expect "touch in a worktree allowed" 0 "$GATE" "$(bash_payload 'touch newfile.txt' "$SANDBOX/wt")"
expect "mkdir in a worktree allowed" 0 "$GATE" "$(bash_payload 'mkdir newdir' "$SANDBOX/wt")"
expect "chmod in a worktree allowed" 0 "$GATE" "$(bash_payload 'chmod 600 README.md' "$SANDBOX/wt")"
expect "ln -sf in a worktree allowed" 0 "$GATE" "$(bash_payload 'ln -sf /tmp/a README.md' "$SANDBOX/wt")"
expect "git stash in a worktree allowed" 0 "$GATE" "$(bash_payload 'git stash push -m wip' "$SANDBOX/wt")"

# ================================================================ out of scope
echo "inert outside fredabood/homelab:"
expect "Edit in another repo allowed" 0 "$GATE" "$(edit_payload "$OTHER/f.txt" "$OTHER")"
expect "git commit in another repo allowed" 0 "$GATE" "$(bash_payload 'git commit -m "x"' "$OTHER")"
expect "rm in another repo allowed" 0 "$GATE" "$(bash_payload 'rm f.txt' "$OTHER")"
expect "Edit in a non-git dir allowed" 0 "$GATE" "$(edit_payload "$NONGIT/x.txt" "$NONGIT")"
expect "git commit in a non-git dir allowed" 0 "$GATE" "$(bash_payload 'git commit -m x' "$NONGIT")"

# ================================================================= fail closed
echo "fail-closed behaviour:"
expect "payload with no cwd fails closed" 2 "$GATE" '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}'
expect "malformed payload fails closed" 2 "$GATE" 'not json at all'
expect "empty payload fails closed" 2 "$GATE" ''

# A PATH with git+bash but no jq. /nonexistent alone would hide `bash` itself, so the
# test would pass for the wrong reason (command-not-found, not the gate's own check).
NOJQ="$SANDBOX/nojq"
mkdir -p "$NOJQ"
for b in bash sh git sed grep cmp; do
  p="$(command -v "$b")" && ln -sf "$p" "$NOJQ/$b"
done
HOOK_ERR="$(printf '%s' "$(bash_payload 'git commit -m x' "$PRIMARY")" | env PATH="$NOJQ" "$NOJQ/bash" "$GATE" 2>&1 >/dev/null)"
RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$HOOK_ERR" | grep -q 'jq is required'; then
  PASS=$((PASS + 1))
  echo "  ok: missing jq fails closed with its own message"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: missing jq should fail closed (rc=$RC) [$HOOK_ERR]"
fi

# ================================================================ kill switch
echo "kill switch:"
HOOK_ERR="$(printf '%s' "$(bash_payload 'git commit -m x' "$PRIMARY")" | HOMELAB_WORKTREE_GATE=off bash "$GATE" 2>&1 >/dev/null)"
if [ $? -eq 0 ] && printf '%s' "$HOOK_ERR" | grep -q DISABLED; then
  PASS=$((PASS + 1))
  echo "  ok: HOMELAB_WORKTREE_GATE=off allows and announces itself loudly"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: kill switch [$HOOK_ERR]"
fi
expect "a command TEXT setting the var does not disable the gate" 2 "$GATE" \
  "$(bash_payload 'HOMELAB_WORKTREE_GATE=off git commit -m x' "$PRIMARY")"

# =============================================================== anti-tamper
echo "anti-self-tamper:"
expect "Edit on ~/.claude/settings.json blocked" 2 "$GATE" "$(edit_payload "$HOME/.claude/settings.json" "$SANDBOX/wt")"
expect "Edit on the installed gate blocked even from a worktree" 2 "$GATE" "$(edit_payload "$HOME/.claude/hooks/worktree-gate.sh" "$SANDBOX/wt")"
expect "Edit on the canonical repo copy allowed from a worktree" 0 "$GATE" "$(edit_payload "$SANDBOX/wt/.claude/hooks/worktree-gate.sh" "$SANDBOX/wt")"

# =================================== user-level ~/.claude is not the submodule (LAB-1649)
# #1649 reported that this gate matches the path FRAGMENT `.claude/` and therefore blocks the
# user's config directory, mistaking it for the repo's `.claude` submodule. Measured, it does
# not: every path test here is wf_path_inside containment, and the anti-self-tamper case above
# matches four literal paths rather than a prefix. The refusal that issue reported came from
# Claude Code's own worktree isolation, one layer BELOW this hook. The tell is cheap — every
# refusal from this gate is prefixed `[worktree-gate] BLOCKED:`, and that one was not.
#
# The PRIMARY-cwd rows are the load-bearing ones. In WORKTREE mode the gate short-circuits
# (`case "$MODE" in … WORKTREE) exit 0`) ~90 lines ABOVE its Edit rules, so a fragment match
# reintroduced later would not even be REACHABLE from a worktree payload — it would go red
# only here. A worktree-only test would stay green while the bug was back, which is why the
# obvious spelling of this test is the useless one.
echo "user-level ~/.claude is not the repo's .claude submodule (LAB-1649):"
expect "Write on ~/.claude/plans allowed from the primary checkout" 0 "$GATE" \
  "$(edit_payload "$HOME/.claude/plans/lab1649-probe.md" "$PRIMARY" Write)"
expect "Write on the ~/.claude/jobs scratchpad allowed from the primary checkout" 0 "$GATE" \
  "$(edit_payload "$HOME/.claude/jobs/lab1649/tmp/probe.md" "$PRIMARY" Write)"
expect "Write on ~/.claude/plans allowed from a worktree" 0 "$GATE" \
  "$(edit_payload "$HOME/.claude/plans/lab1649-probe.md" "$SANDBOX/wt" Write)"
expect "Write on the repo's OWN .claude still blocked from the primary checkout" 2 "$GATE" \
  "$(edit_payload "$PRIMARY/.claude/rules/lab1649-probe.md" "$PRIMARY" Write)"

# ================================================== nested worktree messaging
# A worktree living under .claude/worktrees/ is physically inside the primary checkout.
# Reaching into it from a primary-checkout session must still be blocked, but with the
# remedy that actually applies (enter it), not the generic primary-checkout text.
echo "nested worktree under the primary checkout:"
mkdir -p "$PRIMARY/.claude/worktrees"
git -C "$PRIMARY" worktree add -q "$PRIMARY/.claude/worktrees/nested" -b nested main
run_hook "$GATE" "$(edit_payload "$PRIMARY/.claude/worktrees/nested/README.md" "$PRIMARY")"
if [ "$HOOK_EXIT" -eq 2 ] && printf '%s' "$HOOK_ERR" | grep -q "belongs to the worktree"; then
  PASS=$((PASS + 1))
  echo "  ok: reaching into a nested worktree from primary is blocked with the enter-it remedy"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: nested worktree message (rc=$HOOK_EXIT) [$HOOK_ERR]"
fi
expect "editing that same file FROM inside the nested worktree is allowed" 0 "$GATE" \
  "$(edit_payload "$PRIMARY/.claude/worktrees/nested/README.md" "$PRIMARY/.claude/worktrees/nested")"

# ============================================================ session-bootstrap
echo "session-bootstrap:"
OUT="$(printf '%s' "$(jq -cn --arg c "$PRIMARY" '{hook_event_name:"SessionStart",cwd:$c}')" | bash "$BOOT" 2>/dev/null)"
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | test("PRIMARY CHECKOUT")' >/dev/null 2>&1; then
  PASS=$((PASS + 1))
  echo "  ok: emits additionalContext naming the primary checkout"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: bootstrap primary context [$OUT]"
fi
OUT="$(printf '%s' "$(jq -cn --arg c "$SANDBOX/wt" '{hook_event_name:"SessionStart",cwd:$c}')" | bash "$BOOT" 2>/dev/null)"
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | test("WORKTREE")' >/dev/null 2>&1; then
  PASS=$((PASS + 1))
  echo "  ok: emits additionalContext naming the worktree"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: bootstrap worktree context [$OUT]"
fi
OUT="$(printf '%s' "$(jq -cn --arg c "$OTHER" '{hook_event_name:"SessionStart",cwd:$c}')" | bash "$BOOT" 2>/dev/null)"
if [ -z "$OUT" ]; then
  PASS=$((PASS + 1))
  echo "  ok: silent in an out-of-scope repo"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: bootstrap should be silent out of scope [$OUT]"
fi

# ============================================ prose vs invocation (anchoring)
# strip_quotes is line-oriented (sed), so a quoted span crossing newlines survives it.
# Verb matching is therefore anchored to the head of a command segment. Regression: a
# `gh issue edit` carrying body text that said "git commit" blocked itself.
echo "prose mentioning guarded verbs is not an invocation:"
PROSE='python3 - <<PY
new = """## Criteria
- [x] on main: `git commit` is blocked; `docker compose ps` allowed
- [x] `rm` of a repo file is blocked
"""
PY'
expect "multi-line prose naming git commit / rm is allowed" 0 "$GATE" "$(bash_payload "$PROSE" "$PRIMARY")"
expect "gh issue edit with a body file is allowed" 0 "$GATE" \
  "$(bash_payload 'gh issue edit 1364 --repo fredabood/homelab --body-file /tmp/b.md' "$PRIMARY")"
expect "a real invocation is still blocked" 2 "$GATE" "$(bash_payload 'git commit -m "LAB-1: x"' "$PRIMARY")"
expect "a real invocation after && is still blocked" 2 "$GATE" "$(bash_payload 'git add -A && git commit -m "LAB-1: x"' "$PRIMARY")"
expect "env-prefixed invocation is still blocked" 2 "$GATE" "$(bash_payload 'FOO=1 git commit -m "LAB-1: x"' "$PRIMARY")"
expect "real rm of a repo file is still blocked" 2 "$GATE" "$(bash_payload 'rm README.md' "$PRIMARY")"

# ================================ worktree sessions may not reach the shared checkout
# A session that `cd`-ed into a worktree satisfies this gate but never engages Claude
# Code's native isolation, so the redirect guard is load-bearing there.
echo "worktree may not redirect git into the shared checkout:"
expect "git -C <primary> commit from a worktree blocked" 2 "$GATE" \
  "$(bash_payload "git -C $PRIMARY commit -m x" "$SANDBOX/wt")"
expect "GIT_DIR pointed at the shared checkout blocked" 2 "$GATE" \
  "$(bash_payload "GIT_DIR=$PRIMARY/.git git commit -m x" "$SANDBOX/wt")"
expect "cd into the primary then commit blocked" 2 "$GATE" \
  "$(bash_payload "cd $PRIMARY && git commit -m x" "$SANDBOX/wt")"
expect "ordinary commit inside the worktree still allowed" 0 "$GATE" \
  "$(bash_payload 'git commit -m x' "$SANDBOX/wt")"
# A bare `cd` home is navigation, not a redirect. Blocking it strands the session with no
# way back to the primary checkout — which this guard did on its first live run.
expect "bare cd back to the primary allowed" 0 "$GATE" \
  "$(bash_payload "cd $PRIMARY" "$SANDBOX/wt")"
expect "cd primary then ls allowed" 0 "$GATE" \
  "$(bash_payload "cd $PRIMARY && ls" "$SANDBOX/wt")"
expect "cd primary then rm still blocked" 2 "$GATE" \
  "$(bash_payload "cd $PRIMARY && rm README.md" "$SANDBOX/wt")"
expect "cd primary then a READ-ONLY git command allowed" 0 "$GATE" \
  "$(bash_payload "cd $PRIMARY && git status --short" "$SANDBOX/wt")"
expect "cd primary then git branch --show-current allowed" 0 "$GATE" \
  "$(bash_payload "cd $PRIMARY && git branch --show-current" "$SANDBOX/wt")"
expect "cd primary then git checkout -b still blocked" 2 "$GATE" \
  "$(bash_payload "cd $PRIMARY && git checkout -b x" "$SANDBOX/wt")"

# ============================================ tokens that only look like paths
# A jq filter, a flag value, or any bare word that is neither slash-bearing nor an
# existing file is not a path. Reading `--jq .body` as one blocked an ordinary
# `gh issue view ... > /tmp/x` from the primary checkout.
echo "non-path tokens are not treated as targets:"
expect "gh issue view --jq .body redirected to /tmp allowed" 0 "$GATE" \
  "$(bash_payload 'gh issue view 1364 --repo fredabood/homelab --json body --jq .body > /tmp/b.md' "$PRIMARY")"
expect "jq filter with a dot allowed" 0 "$GATE" \
  "$(bash_payload 'docker inspect caddy --format .State.Status > /tmp/s.txt' "$PRIMARY")"
expect "wc on a /tmp file allowed" 0 "$GATE" "$(bash_payload 'wc -l /tmp/b.md' "$PRIMARY")"
expect "redirect to a NEW repo file still blocked" 2 "$GATE" \
  "$(bash_payload 'echo x > brand-new-file.txt' "$PRIMARY")"
expect "rm of an existing repo file still blocked" 2 "$GATE" \
  "$(bash_payload 'rm README.md' "$PRIMARY")"
expect "cp into the repo still blocked" 2 "$GATE" \
  "$(bash_payload 'cp /tmp/a.txt internal/caddy/Caddyfile' "$PRIMARY")"
expect "cp creating a NEW repo file still blocked (destination need not exist)" 2 "$GATE" \
  "$(bash_payload 'cp /tmp/a.txt brand-new.txt' "$PRIMARY")"
expect "mv creating a NEW repo file still blocked" 2 "$GATE" \
  "$(bash_payload 'mv /tmp/a.txt also-new.txt' "$PRIMARY")"
expect "cp from the repo out to /tmp allowed" 0 "$GATE" \
  "$(bash_payload 'cp README.md /tmp/copy.md' "$PRIMARY")"
expect "gh with an owner/name flag value allowed" 0 "$GATE" \
  "$(bash_payload 'gh issue list --repo fredabood/homelab --json number > /tmp/i.json' "$PRIMARY")"

                                        # --- shell-wrapper bypasses (LAB-1380) ---
# Anchoring the verb match to a segment head fixed prose-as-invocation but opened the
# mirror-image hole: a verb behind a wrapper is not at the head either. All eight forms
# below were measured returning 0 against the installed gate before this fix. None was
# caught by the 86 assertions above, which is why they are pinned here permanently.
echo ""
echo "shell-wrapper bypasses must not reach the shared checkout:"
expect "bash -c hiding a git write blocked" 2 "$GATE" \
  "$(bash_payload 'bash -c "git commit -m x"' "$PRIMARY")"
expect "sh -c hiding an rm blocked" 2 "$GATE" \
  "$(bash_payload 'sh -c "rm -f README.md"' "$PRIMARY")"
expect "eval hiding a git write blocked" 2 "$GATE" \
  "$(bash_payload 'eval "git commit -m x"' "$PRIMARY")"
expect "eval with single quotes blocked" 2 "$GATE" \
  "$(bash_payload "eval 'rm -f README.md'" "$PRIMARY")"
expect "timeout <duration> prefix blocked" 2 "$GATE" \
  "$(bash_payload 'timeout 5 git commit -m x' "$PRIMARY")"
expect "timeout with its own flags blocked (GHSA-7mqg-cx4g-x2rf shape)" 2 "$GATE" \
  "$(bash_payload 'timeout -s KILL 5m git commit -m x' "$PRIMARY")"
expect "nice -n N prefix blocked" 2 "$GATE" \
  "$(bash_payload 'nice -n 10 git commit -m x' "$PRIMARY")"
expect "env prefix blocked" 2 "$GATE" \
  "$(bash_payload 'env git commit -m x' "$PRIMARY")"
expect "command prefix blocked" 2 "$GATE" \
  "$(bash_payload 'command git commit -m x' "$PRIMARY")"
expect "exec prefix blocked" 2 "$GATE" \
  "$(bash_payload 'exec git commit -m x' "$PRIMARY")"
expect "stacked wrappers blocked" 2 "$GATE" \
  "$(bash_payload 'sudo env git commit -m x' "$PRIMARY")"
expect "nested wrapper inside bash -c blocked" 2 "$GATE" \
  "$(bash_payload 'bash -c "timeout 5 git commit -m x"' "$PRIMARY")"
expect "absolute interpreter path blocked" 2 "$GATE" \
  "$(bash_payload '/bin/bash -c "git commit -m x"' "$PRIMARY")"
expect "combined interpreter flag (-lc) blocked" 2 "$GATE" \
  "$(bash_payload 'bash -lc "git commit -m x"' "$PRIMARY")"
expect "redirect hidden inside bash -c blocked" 2 "$GATE" \
  "$(bash_payload 'bash -c "echo x > README.md"' "$PRIMARY")"

# Guards. Unwrapping must not resurrect the over-blocking that #1377-#1379 fixed: the
# payload of a wrapper is only a command when the wrapper actually runs it.
echo ""
echo "wrapper handling must not over-block:"
expect "prose naming a wrapper and a verb allowed" 0 "$GATE" \
  "$(bash_payload 'echo "timeout 5 git commit -m x"' "$PRIMARY")"
expect "read-only git inside bash -c allowed" 0 "$GATE" \
  "$(bash_payload 'bash -c "git status"' "$PRIMARY")"
expect "a command merely starting with sh keeps its quoting" 0 "$GATE" \
  "$(bash_payload 'sha256sum "README.md"' "$PRIMARY")"
expect "shellcheck on a repo file allowed (sh* prefix trap)" 0 "$GATE" \
  "$(bash_payload 'shellcheck internal/caddy/Caddyfile' "$PRIMARY")"

                                # --- a worktree is not the shared checkout (LAB-1380) ---
# Native worktrees live at <shared>/.claude/worktrees/<name>, so every worktree is inside
# the primary checkout by path containment. The redirect guard read `cd <own worktree>`
# as a redirect and stranded the session. Pre-existing; found by the gate blocking its
# own pointer-bump commit.
echo ""
echo "the redirect guard must not treat a worktree as the shared checkout:"
expect "cd into the session's OWN worktree allowed" 0 "$GATE" \
  "$(bash_payload "cd $NESTED && git commit -m x" "$NESTED")"
expect "cd into a subdirectory of the own worktree allowed" 0 "$GATE" \
  "$(bash_payload "cd $NESTED/sub && git commit -m x" "$NESTED")"
expect "cd into the PRIMARY checkout still blocked" 2 "$GATE" \
  "$(bash_payload "cd $PRIMARY && git commit -m x" "$NESTED")"
expect "git -C at the PRIMARY checkout still blocked" 2 "$GATE" \
  "$(bash_payload "git -C $PRIMARY commit -m x" "$NESTED")"

echo ""
echo "worktree-gate tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
