#!/usr/bin/env bash
# Pre-commit: validates frontmatter on memory vault .md files.
# Exit 0 = allow, Exit 2 = block.
#
# This hook is triggered by settings.json PreToolUse on "Bash(git commit)".
# It only runs when the commit involves the memory submodule.

set -euo pipefail

# Modern hook payload arrives as JSON on stdin (legacy TOOL_INPUT env was always
# empty, making this gate a silent no-op — LAB-215, 2026-07-13). Self-filter: only
# git commit commands matter; the staged-file check below scopes to the vault.
INPUT=$(cat)
CMD=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print((d.get('tool_input') or {}).get('command') or '')" 2>/dev/null || echo "")
if [[ "$CMD" != *"git commit"* ]]; then
  exit 0
fi

# Find staged .md files in the memory submodule (anchored to project root, not CWD)
MEMORY_DIR="${CLAUDE_PROJECT_DIR:-.}/submodules/memory"
if [[ ! -d "$MEMORY_DIR" ]]; then
  exit 0
fi

cd "$MEMORY_DIR"

STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACM -- '*.md' 2>/dev/null || true)
if [[ -z "$STAGED_FILES" ]]; then
  exit 0
fi

ERRORS=0
while IFS= read -r file; do
  [[ -f "$file" ]] || continue

  # Check frontmatter exists
  if [[ "$(head -1 "$file")" != "---" ]]; then
    echo "ERROR: $file — missing frontmatter (no opening ---)"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # Extract frontmatter block (lines between first and second ---)
  FM=$(awk '/^---$/{n++; if(n==2) exit} n==1{print}' "$file")

  if [[ -z "$FM" ]]; then
    echo "ERROR: $file — unclosed frontmatter block (missing closing ---)"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # Check required fields.
  # Herestrings throughout, NOT `echo "$FM" | grep -q` (LAB-1603): under the `pipefail`
  # at the top of this file, `grep -q` exits at its first match and closes the pipe, the
  # producer takes SIGPIPE, and `pipefail` promotes that to the pipeline's status — so
  # the test reports FAILURE precisely when the field IS present. Here that inverts a
  # `!`, meaning a valid file would be reported as missing a required field.
  for field in title tags created; do
    if ! grep -q "^${field}:" <<<"$FM"; then
      echo "ERROR: $file — missing required field: $field"
      ERRORS=$((ERRORS + 1))
    fi
  done

  # Validate created date format
  # `grep` without -q here, so it reads to EOF and cannot SIGPIPE its producer; the
  # -q test below is the herestring form for the same reason as the loop above.
  CREATED=$(grep "^created:" <<<"$FM" | sed 's/created: *//' | sed 's/^["'"'"']//;s/["'"'"']$//')
  if [[ -n "$CREATED" ]] && ! grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' <<<"$CREATED"; then
    echo "ERROR: $file — created date not in YYYY-MM-DD format: $CREATED"
    ERRORS=$((ERRORS + 1))
  fi
done <<< "$STAGED_FILES"

if [[ $ERRORS -gt 0 ]]; then
  echo ""
  echo "Vault frontmatter validation failed ($ERRORS errors)."
  echo "Run /obsidian-lint --fix to auto-repair, or fix manually."
  exit 2
fi

echo "Vault frontmatter: all checks passed."
exit 0
