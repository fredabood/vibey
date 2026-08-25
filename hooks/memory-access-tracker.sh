#!/bin/bash
# memory-access-tracker.sh — Updates last_accessed frontmatter on memory files
#
# Hook event: UserPromptSubmit (proxy for SessionStart — tracks which memories
# are loaded into context as the session progresses)
#
# LAB-93: Memory staleness tracking — files not accessed in 90+ days are
# candidates for archival or consolidation.
#
# Updates last_accessed and access_count in YAML frontmatter of memory files.
# Only processes files in the auto-memory directory (not vault — vault has
# its own lifecycle).

set -euo pipefail

# Only run once per session (track with a temp file)
SESSION_MARKER="/tmp/.memory-access-tracked-$$"
if [ -f "$SESSION_MARKER" ]; then
    exit 0
fi

MEMORY_DIR="$HOME/.claude/projects/-Users-fredabood-homelab/memory"
TODAY=$(date +%Y-%m-%d)

# Only process if the memory directory exists
if [ ! -d "$MEMORY_DIR" ]; then
    exit 0
fi

# Update last_accessed on all .md files (except MEMORY.md index)
for f in "$MEMORY_DIR"/*.md; do
    [ -f "$f" ] || continue
    basename_f=$(basename "$f")
    [ "$basename_f" = "MEMORY.md" ] && continue

    # Check if file has frontmatter.
    # Capture-then-test, NOT `head -1 "$f" | grep -q` (LAB-1603): under the `pipefail`
    # at the top of this file, `grep -q` closing the pipe on a match can SIGPIPE the
    # producer and invert the verdict. `head -1` is bounded to one line so this one was
    # not reachable in practice, but the construct is the defect — a bounded producer
    # today is an unbounded one after one edit.
    first_line=$(head -1 "$f")
    if ! grep -q '^---$' <<<"$first_line"; then
        continue
    fi

    # Use Python to update frontmatter (matches existing hook patterns)
    python3 -c "
import sys
from pathlib import Path

f = Path('$f')
text = f.read_text()
lines = text.split('\n')

# Find frontmatter boundaries
if not lines or lines[0] != '---':
    sys.exit(0)
end = -1
for i in range(1, len(lines)):
    if lines[i] == '---':
        end = i
        break
if end < 0:
    sys.exit(0)

# Parse frontmatter for last_accessed and access_count
fm_lines = lines[1:end]
has_last_accessed = False
has_access_count = False
new_fm = []
for line in fm_lines:
    if line.startswith('last_accessed:'):
        new_fm.append(f'last_accessed: $TODAY')
        has_last_accessed = True
    elif line.startswith('access_count:'):
        try:
            count = int(line.split(':')[1].strip())
        except ValueError:
            count = 0
        new_fm.append(f'access_count: {count + 1}')
        has_access_count = True
    else:
        new_fm.append(line)

if not has_last_accessed:
    new_fm.append(f'last_accessed: $TODAY')
if not has_access_count:
    new_fm.append('access_count: 1')

# Reconstruct file
result = ['---'] + new_fm + ['---'] + lines[end+1:]
f.write_text('\n'.join(result))
" 2>/dev/null || true
done

# Mark session as tracked
touch "$SESSION_MARKER"
exit 0
