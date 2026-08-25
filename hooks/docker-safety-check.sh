#!/usr/bin/env bash
# Docker production safety gate.
# Blocks destructive docker commands (stop, rm, rmi, kill) on production containers.
# Staging containers (*-staging) are allowed freely.
#
# Exit codes:
#   0 = allow
#   2 = block (Claude Code surfaces the STDERR message to the operator)
#
# LAB-1358 — what was wrong and what changed
# ------------------------------------------
# The gate used to extract its targets with
#     sed 's/^docker (stop|rm|rmi|kill) *//' | tr ' ' '\n' | grep -v '^-'
# which is not command parsing, it is word splitting. Three defects followed:
#
#   1. Redirects and pipes became container names. `docker rm -f x-staging 2>&1 | tail -1`
#      yielded targets [x-staging, 2>&1, |, tail] — three of them do not end in -staging,
#      so a staging-only command was blocked anyway.
#   2. It failed as an ERROR, not a decision. Under `set -e`, a `grep -v` that matches
#      nothing exits 1 and kills the script, and the harness reported
#      "PreToolUse:Bash hook error ... No stderr output" instead of a refusal. The block
#      message was also written to STDOUT, which the harness does not surface.
#   3. `^` anchors per LINE, so a `docker rm` on the second line of a multi-line command
#      was parsed as though it began the command.
#
# The fix replaces word splitting with a quote-aware tokenizer (below) that models the
# shell well enough to know where one command ends and the next begins.
#
# DELIBERATE CHOICES (each of these is a decision, not an accident):
#
#   * MULTI-LINE: the WHOLE command is inspected on purpose. The token stream is split on
#     control operators — newline, `;`, `&&`, `||`, `|`, `&`, `(`, `)`, backtick — and
#     EVERY resulting segment is checked for a docker invocation. So `echo x && docker rm
#     n8n` and a `docker rm` on line 5 are both gated. This is stricter than the old
#     per-line `^` anchor, which caught the multi-line case by accident and missed the
#     `&&` case entirely. A safety gate that is easy to step around is not a gate.
#
#   * REDIRECTS are skipped with their operands, including the fd prefix: in `2>&1` the
#     bare `2` is a file descriptor, not a container.
#
#   * NO TARGETS -> ALLOW. `docker rm` / `docker rm -f` with no operands cannot destroy
#     anything; docker itself errors out. The old code crashed here (defect 2). Allowing
#     is the deliberate choice, and it is why the block path requires a named target.
#
#   * UNPARSEABLE -> BLOCK. If the tokenizer cannot make sense of the command (unbalanced
#     quotes) or python3 is unavailable, we fall back to a raw-text scan: if the text
#     looks like a destructive docker invocation we refuse and say why; otherwise we get
#     out of the way. The gate fails closed only for commands that look dangerous.
#
#   * ONE GRAMMAR, THREE PLACES. The tokenizer path, the shell fallback and the python
#     fallback must recognise the same invocations. The two fallbacks used to be two
#     hand-copied regexes; they shared every hole (#1530). They now share ONE string,
#     $RAW_DESTRUCTIVE_RE below, handed to the parser as HOOK_RAW_DESTRUCTIVE_RE. It is
#     spelled with `\s` and `[^ ]` on purpose: those mean the same thing to grep -E (BSD
#     and GNU) and to python re. `[[:space:]]` is not python, `[^\s]` is not ERE.
#
# LAB-1530 — the gate was fail-OPEN on most spellings of the same command
# --------------------------------------------------------------------
# Measured by feeding synthetic PreToolUse payloads to this hook: `docker rm n8n` was
# refused, but `docker container rm n8n`, `docker volume rm nextcloud_data`,
# `docker image rm x`, `docker network rm core` and `docker --context X rm n8n` were all
# ALLOWED. `targets_of()` required the verb to be the word IMMEDIATELY after `docker` and
# returned None otherwise — and None means "not a gated invocation", so every one of
# those became an allow. `docker volume rm` is the most destructive of the set on this
# fleet: it takes data no container rebuild brings back.
#
# The grammar is now: `docker` [global flags, with their operands] (<verb> | <noun>
# <verb>), noun in {container, image, volume, network}, verb in {stop, rm, rmi, kill}.
# The verb after a noun is REQUIRED, so `docker container ls` and `docker volume ls` stay
# allowed — a widened gate that blocks reads is a gate people route around.
#
# OUT OF SCOPE, deliberately (#1530), not overlooked:
#   * `prune` — `docker image|volume|system|network prune` destroys an unnamed SET. It
#     names no target, so `offenders` has nothing to report and the load-bearing
#     NO TARGETS -> ALLOW rule above passes it. Gating it needs a SECOND verdict path for
#     "destroys everything matching a filter", which is a different design, not a wider
#     regex. Recorded rather than half-built. Same for `docker compose down -v`, which
#     destroys a whole stack's volumes and likewise names no container.
#   * The intercepted verb set is still stop, rm, rmi, kill.
#
# PRESERVED EXACTLY (do not "fix" these without an issue):
#   * The verdict vocabulary: exit 0 allow, exit 2 block, never anything else.
#   * NO TARGETS -> ALLOW, and the block path requiring a named target.
#
# CHANGED by #1530 (was "PRESERVED EXACTLY" under #1358 — both entries were wrong):
#   * The exempt test was substring `*-staging*`. That was wrong in BOTH directions:
#     `docker rmi foo:staging` was blocked (no literal `-staging`) and
#     `docker rm my-staging-thing-prod` was allowed (it contains one). It is now a
#     tag/suffix test — see is_staging().
#   * The subcommand no longer has to follow `docker` immediately.
#
# Tests: .claude/hooks/tests/docker-safety-check.test.sh

# Deliberately NOT `set -e`. This script's whole job is to return a VERDICT; an
# unexamined non-zero from any helper used to become an opaque harness error instead of
# an allow or a block (defect 2 above). Every step below is checked explicitly, and the
# only ways out are `exit 0` and `exit 2`.
set -uo pipefail

GATE_NAME="docker-safety-check"

INPUT=$(cat)

# THE shared grammar for both fail-closed fallbacks — the shell one just below and the
# python one inside the parser, which receives this exact string in the environment.
# Mirrors targets_of(): docker, then any global flags (optionally with an operand), then
# either <verb> or <noun> <verb>. Deliberately crude — it only decides whether the text
# LOOKS like a destructive docker invocation, and it never allows one through on a guess.
# Portability: `\s` outside brackets and `[^ ]` / `[^- ]` inside them are the only
# whitespace spellings that mean the same thing to grep -E and to python re.
RAW_DESTRUCTIVE_RE='(^|[^A-Za-z0-9_-])docker(\s+-[^ ]+(\s+[^- ][^ ]*)?)*(\s+(container|image|volume|network))?\s+(stop|rm|rmi|kill)(\s|$)'

# A herestring, NOT `printf ... | grep -q`: under `pipefail` a grep that exits early on a
# match can SIGPIPE the producer, and the pipeline then reports failure ON A MATCH.
raw_looks_destructive() {
  grep -qE "$RAW_DESTRUCTIVE_RE" <<<"$1"
}

block_header() {
  echo "[$GATE_NAME] BLOCKED: $1" >&2
  echo "" >&2
}

block_footer() {
  echo "" >&2
  echo "Production containers must not be stopped or deleted accidentally." >&2
  echo "Staging containers (*-staging) are exempt from this check." >&2
  echo "" >&2
  echo "This gate has no bypass token. A confirmation comment in the command does not" >&2
  echo "change the verdict — the mechanism the old message described was never built." >&2
  echo "If the operation is intended, get explicit confirmation from the user and then" >&2
  echo "re-issue it. A block here is a request for confirmation, not a permanent refusal." >&2
  exit 2
}

if ! command -v python3 >/dev/null 2>&1; then
  # No parser available. Refuse anything that looks destructive; leave everything else
  # alone, because blocking every Bash call on this machine would be worse than the bug.
  if raw_looks_destructive "$INPUT"; then
    block_header "python3 is unavailable, so the command could not be parsed."
    echo "The payload contains what looks like a destructive docker invocation," >&2
    echo "so the gate fails closed rather than guessing." >&2
    block_footer
  fi
  exit 0
fi

PARSER=$(cat <<'PYEOF'
import json
import os
import re
import sys

DESTRUCTIVE = ("stop", "rm", "rmi", "kill")

# `docker <noun> <verb>` is the same command as `docker <verb>`. The verb is still
# required after the noun, so `docker container ls` is not gated (#1530).
OBJECT_NOUNS = ("container", "image", "volume", "network")

# docker's GLOBAL flags that take a SEPARATE operand. Any other `-...` word is treated as
# a boolean flag and simply skipped; that is the safe direction, because the only way to
# be wrong is to read a flag's value as a verb, which over-blocks rather than under-.
GLOBAL_VALUE_FLAGS = frozenset((
    "-c", "--context", "-H", "--host", "-l", "--log-level", "--config",
    "--tlscacert", "--tlscert", "--tlskey",
))

# Control operators end one command and start the next; redirect operators do not.
# Parentheses and backticks open a nested command, which is treated as a new segment,
# so a docker rm inside a command substitution is gated like any other invocation.
#
# The backtick is spelled \x60 on purpose: this whole program is a quoted heredoc inside
# a $( ... ) substitution, and bash still hunts for a matching backtick in there. A
# literal one truncates the script at parse time — and because a bash syntax error also
# exits 2, the gate then LOOKS like it is blocking correctly while every allow path is
# broken. Found by this hook's own suite, LAB-1358.
CONTROL_CHARS = set("|&;()\x60")
REDIR_CHARS = set("<>")
OP_CHARS = CONTROL_CHARS | REDIR_CHARS

# Leading words that precede the actual command word and are not it.
LEADING_NOISE = {"{", "!", "then", "else", "elif", "do", "time"}
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

# The SAME string the shell fallback greps with, handed over in the environment so the two
# can never drift apart again (#1530). A KeyError here is deliberate: it exits non-zero,
# which the caller treats as a parser failure and answers with its own copy of the scan.
RAW_DESTRUCTIVE = re.compile(os.environ["HOOK_RAW_DESTRUCTIVE_RE"])


def tokenize(cmd):
    """Quote-aware tokenizer. Returns [(kind, text)] with kind in {'word', 'op'}.

    Only as much shell as this gate needs: quoting, escapes, comments, and the
    operators that separate or redirect commands. Anything it cannot make sense of
    raises, and the caller fails closed.
    """
    toks = []
    i, n = 0, len(cmd)
    while i < n:
        c = cmd[i]
        if c in " \t\r":
            i += 1
            continue
        if c == "\\" and i + 1 < n and cmd[i + 1] == "\n":
            i += 2                      # line continuation: not a command boundary
            continue
        if c == "\n":
            toks.append(("op", "\n"))
            i += 1
            continue
        if c == "#":                    # comment runs to end of line
            j = cmd.find("\n", i)
            i = n if j < 0 else j
            continue
        if c in OP_CHARS:
            j = i
            while j < n and cmd[j] in OP_CHARS:
                j += 1
            toks.append(("op", cmd[i:j]))
            i = j
            continue
        buf = ""
        while i < n and cmd[i] not in " \t\r\n" and cmd[i] not in OP_CHARS:
            c = cmd[i]
            if c == "\\" and i + 1 < n:
                buf += cmd[i + 1]
                i += 2
                continue
            if c == "'":
                j = cmd.find("'", i + 1)
                if j < 0:
                    raise ValueError("unbalanced single quote")
                buf += cmd[i + 1:j]
                i = j + 1
                continue
            if c == '"':
                j = i + 1
                while j < n and cmd[j] != '"':
                    j += 2 if cmd[j] == "\\" else 1
                if j >= n:
                    raise ValueError("unbalanced double quote")
                buf += cmd[i + 1:j]
                i = j + 1
                continue
            buf += c
            i += 1
        toks.append(("word", buf))
    return toks


def is_control(op):
    """A run of operator characters is a redirect if it redirects, else control."""
    return not (set(op) & REDIR_CHARS)


def segments(toks):
    seg = []
    for kind, text in toks:
        if kind == "op" and is_control(text):
            if seg:
                yield seg
            seg = []
            continue
        seg.append((kind, text))
    if seg:
        yield seg


def targets_of(seg):
    """Targets named by one command segment, or None if it is not a gated invocation."""
    i = 0
    # Step over VAR=value prefixes and shell noise to reach the command word.
    while i < len(seg) and seg[i][0] == "word" and (
        seg[i][1] in LEADING_NOISE or ASSIGNMENT.match(seg[i][1])
    ):
        i += 1
    if i >= len(seg) or seg[i][0] != "word":
        return None
    word = seg[i][1]
    if word != "docker" and not word.endswith("/docker"):
        return None
    i += 1

    # Step over docker's GLOBAL flags and their operands. `docker --context prod rm n8n`
    # is `docker rm n8n` against another daemon; requiring the verb to be adjacent made
    # it an ALLOW (#1530).
    while i < len(seg) and seg[i][0] == "word" and seg[i][1].startswith("-"):
        flag = seg[i][1]
        i += 1
        if (
            flag in GLOBAL_VALUE_FLAGS
            and i < len(seg)
            and seg[i][0] == "word"
            and not seg[i][1].startswith("-")
        ):
            i += 1                       # `--context X`, not `--context=X`

    if i >= len(seg) or seg[i][0] != "word":
        return None
    head = seg[i][1]
    if head in OBJECT_NOUNS:
        # Management-command spelling: `docker volume rm x`. The VERB is what makes it
        # destructive, so it is required — `docker volume ls` must stay allowed.
        i += 1
        if i >= len(seg) or seg[i][0] != "word" or seg[i][1] not in DESTRUCTIVE:
            return None
    elif head not in DESTRUCTIVE:
        return None
    i += 1

    found = []
    while i < len(seg):
        kind, text = seg[i]
        if kind == "op":                     # a redirect: skip it and its operand
            i += 1
            if i < len(seg) and seg[i][0] == "word":
                i += 1
            continue
        if text.isdigit() and i + 1 < len(seg) and seg[i + 1][0] == "op":
            i += 1                           # fd prefix, e.g. the 2 of 2>&1
            continue
        if text.startswith("-"):             # a flag, not a container
            i += 1
            continue
        found.append(text)
        i += 1
    return found


def is_staging(target):
    """True if this target names a staging artefact, by SUFFIX or TAG (#1530).

    The old test was `"-staging" in target`, wrong in both directions: it blocked
    `foo:staging` (no literal `-staging`) and exempted `my-staging-thing-prod`.
    """
    name = target.split("@", 1)[0]          # drop any `@sha256:...` digest
    head, sep, tail = name.rpartition(":")
    if sep and head and "/" not in tail:    # a tag, not a `registry:5000/img` port
        if tail == "staging" or tail.endswith("-staging"):
            return True
        name = head
    return name == "staging" or name.endswith("-staging")


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        print("allow")
        return
    # Payload shape is {"tool_name":"Bash","tool_input":{"command":...}} on current
    # Claude Code; older harnesses passed a top-level "command". Support both — the
    # top-level-only parse left this gate silently fail-open (LAB-215/LAB-961, 2026-07-13).
    if not isinstance(payload, dict):
        print("allow")
        return
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        tool_input = {}
    cmd = tool_input.get("command") or payload.get("command") or ""
    if not isinstance(cmd, str) or not cmd.strip():
        print("allow")
        return

    try:
        toks = tokenize(cmd)
    except ValueError as exc:
        if RAW_DESTRUCTIVE.search(cmd):
            print("blockraw")
            print(str(exc))
        else:
            print("allow")
        return

    gated = False
    offenders = []
    for seg in segments(toks):
        found = targets_of(seg)
        if found is None:
            continue
        gated = True
        offenders.extend(t for t in found if not is_staging(t))

    if not gated or not offenders:
        # Not a gated command, or a gated one naming only staging containers, or naming
        # nothing at all (see NO TARGETS above).
        print("allow")
        return

    print("block")
    print(" ".join(offenders))
    print(" ".join(cmd.split())[:300])


main()
PYEOF
)

VERDICT_RAW=$(HOOK_RAW_DESTRUCTIVE_RE="$RAW_DESTRUCTIVE_RE" python3 -c "$PARSER" 2>/dev/null <<<"$INPUT")
PARSER_RC=$?

if [[ $PARSER_RC -ne 0 || -z "$VERDICT_RAW" ]]; then
  # The parser itself failed. Same posture as a missing python3: refuse what looks
  # destructive, allow the rest, and never exit through an unhandled error.
  if raw_looks_destructive "$INPUT"; then
    block_header "the command could not be parsed (parser exited $PARSER_RC)."
    echo "The payload contains what looks like a destructive docker invocation," >&2
    echo "so the gate fails closed rather than guessing." >&2
    block_footer
  fi
  exit 0
fi

VERDICT="${VERDICT_RAW%%$'\n'*}"
DETAIL="${VERDICT_RAW#*$'\n'}"

case "$VERDICT" in
  allow)
    exit 0
    ;;
  blockraw)
    block_header "the command could not be parsed ($DETAIL)."
    echo "The payload contains what looks like a destructive docker invocation," >&2
    echo "so the gate fails closed rather than guessing." >&2
    block_footer
    ;;
  block)
    OFFENDERS="${DETAIL%%$'\n'*}"
    SHOWN="${DETAIL#*$'\n'}"
    block_header "this command targets a production container."
    echo "  command:  $SHOWN" >&2
    echo "  targets:  $OFFENDERS" >&2
    block_footer
    ;;
  *)
    # An unrecognised verdict is a bug in this gate, not a decision. Fail closed and
    # say so, rather than reproducing the opaque error this issue was filed about.
    block_header "internal error — unrecognised verdict '$VERDICT'."
    echo "This is a defect in $GATE_NAME. The gate fails closed." >&2
    block_footer
    ;;
esac

# Unreachable: every branch above exits. Present so the script can never fall off the
# end into an implicit exit status.
exit 2
