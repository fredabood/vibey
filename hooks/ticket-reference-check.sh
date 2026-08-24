#!/usr/bin/env bash
# PreToolUse hook: blocks commits without a work item reference.
# Accepted keys: LAB-<n> (homelab), DRTY-<n> (dirtydata), RESORT-<n> (9215resort),
# JG-<n> (jira-graph), WORK-<n> (work), and LEGACY-<n> for migrated issues.
# Deprecated HL-<n>/DD-<n> (the 2026-07 interim scheme, HL-n ≡ LAB-n /
# DD-n ≡ DRTY-n) stay accepted for historical commits and amend flows.
# Checks both commit message and branch name.
# Allowlist: messages starting with chore:, typo:, docs:, sync: bypass the check.

set -euo pipefail

# Read tool input from stdin and do all logic in python
INPUT=$(cat)
BRANCH_NAME=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

echo "$INPUT" | python3 -c "
import sys, json, re, shlex

data = json.load(sys.stdin)
cmd = data.get('tool_input', {}).get('command', '')
branch = '$BRANCH_NAME'

# Only run on git commit commands
if 'git commit' not in cmd:
    sys.exit(0)

# Extract commit message using shlex
msg = ''
parts = []
try:
    parts = shlex.split(cmd)
    for i, part in enumerate(parts):
        if part == '-m' and i + 1 < len(parts):
            msg = parts[i + 1]
            break
except ValueError:
    pass

# -F / --file: the message lives in a FILE, and this check used to inspect only the
# command string. A commit whose message began 'LAB-1495:' was therefore reported as
# having no reference — the file was never opened. -F is not exotic; it is how any commit
# with a body longer than a line gets written, which is exactly what this repo's own
# convention asks for. Measured 2026-08-24 (LAB-1495).
#
# This must not become a bypass. An unreadable or missing file, and '-F -' (stdin, which
# cannot be read from here by construction), all fall through to the same 'no reference'
# path as before.
if not msg:
    path = ''
    for i, part in enumerate(parts):
        if part in ('-F', '--file') and i + 1 < len(parts):
            path = parts[i + 1]
            break
        if part.startswith('--file='):
            path = part.split('=', 1)[1]
            break
    if path and path != '-':
        try:
            with open(path, encoding='utf-8', errors='replace') as fh:
                for line in fh:
                    line = line.strip()
                    if line:
                        msg = line
                        break
        except OSError:
            pass

if not msg:
    # Fallback: heredoc pattern
    m = re.search(r'<<.*?EOF.*?\n(.*?)\n.*?EOF', cmd, re.DOTALL)
    if m:
        msg = m.group(1).strip().split('\n')[0]

# Check allowlist — trivial commits bypass
if re.match(r'^\s*(chore|typo|docs|sync):', msg, re.IGNORECASE):
    sys.exit(0)

# Check for work item reference pattern (unified keys LAB/DRTY/RESORT/JG/WORK
# + LEGACY, plus deprecated HL/DD for historical commits and amend flows)
ticket_re = re.compile(r'\b(LAB|DRTY|RESORT|JG|WORK|LEGACY|HL|DD)-[0-9]+\b')
commit_has_ref = bool(ticket_re.search(msg)) if msg else False
branch_has_ref = bool(ticket_re.search(branch)) if branch else False

if not commit_has_ref and not branch_has_ref:
    print('BLOCKED: No work item reference found in commit message or branch name.')
    print()
    print(f'  Commit message: no reference (expected pattern: LAB-963 / DRTY-45 / RESORT-12 / JG-8 / WORK-25, or LEGACY- for migrated issues)')
    print(f'  Branch name: \"{branch}\" — no reference')
    print()
    print('To fix:')
    print('  - Include the mirror key in the commit message: LAB-963: <description> (homelab), DRTY-45: <description> (dirtydata), RESORT-12: <description> (9215resort), JG-8: <description> (jira-graph), or WORK-25: <description> (work)')
    print('  - Deprecated HL-/DD- keys are still accepted for historical commits (HL-n = LAB-n, DD-n = DRTY-n) but do not use them for new work')
    print('  - Or use an allowlisted prefix: chore: / typo: / docs: / sync:')
    print('  - Or create a tracking issue with /create-ticket')
    sys.exit(2)

if not commit_has_ref and branch_has_ref:
    print(f'NOTE: Commit message does not include a work item reference.')
    print(f'  Branch \"{branch}\" has a reference, but prefer including it in the commit message too.')
    print(f'  Format: LAB-963: <description>')

sys.exit(0)
"
