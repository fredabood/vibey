---
name: vault-add
description: Add a new note to the Obsidian vault with proper frontmatter, deduplication, and wikilink suggestions
user_invocable: true
---

# /vault-add

Create a new note in the Obsidian vault (`$MEMORY_VAULT_PATH/`) with correct structure, frontmatter, and cross-references.

## Usage

```
/vault-add <title>                    → interactive: asks for type, tags, target dir
/vault-add <title> --type knowledge   → homelab/knowledge/
/vault-add <title> --type decision    → homelab/decisions/
/vault-add <title> --type research    → homelab/research/
/vault-add <title> --type session     → homelab/sessions/
/vault-add <title> --type milestone   → homelab/milestones/
/vault-add <title> --type planning    → homelab/planning/
/vault-add <title> --type context     → homelab/context/
```

## Steps

### Step 1: Parse input and determine target

1. Extract the title from the arguments.
2. If `--type` is provided, map to the target directory:
   - `knowledge` → `$MEMORY_VAULT_PATH/homelab/knowledge/` (may prompt for subcategory)
   - `decision` → `$MEMORY_VAULT_PATH/homelab/decisions/`
   - `research` → `$MEMORY_VAULT_PATH/homelab/research/`
   - `session` → `$MEMORY_VAULT_PATH/homelab/sessions/`
   - `milestone` → `$MEMORY_VAULT_PATH/homelab/milestones/`
   - `planning` → `$MEMORY_VAULT_PATH/homelab/planning/`
   - `context` → `$MEMORY_VAULT_PATH/homelab/context/`
3. If `--type` is not provided, ask the user which type fits.
4. For `knowledge` type, list existing subcategories (subdirectories of `homelab/knowledge/`) and ask which one to use, or offer to create a new one.

### Step 2: Generate filename

Convert the title to a kebab-case filename:
- Lowercase all characters
- Replace spaces with hyphens
- Remove special characters except hyphens
- Strip leading/trailing hyphens
- Collapse consecutive hyphens

Example: `"Backup Restore Strategy"` → `backup-restore-strategy.md`

### Step 3: Check for duplicates

Scan existing vault files for conflicts:
1. Check if a file with the same kebab-case name already exists in the target directory.
2. Search `title:` and `aliases:` fields across all vault `.md` files for case-insensitive matches.
3. If a potential duplicate is found, show it to the user and ask whether to proceed, merge, or cancel.

### Step 4: Generate frontmatter

Build the YAML frontmatter block:

```yaml
---
title: <Original title as provided>
tags:
  - <inferred from type and content>
created: <today's date in YYYY-MM-DD>
---
```

Tag inference rules:
- `decision` type → include `decision` tag
- `research` type → include `research` tag
- `session` type → include `session` tag
- `knowledge` type → include the subcategory name as a tag (e.g., `networking`, `security`)
- Add additional tags based on the title keywords if obvious (e.g., "Docker" → `docker`)

### Step 5: Create the file

Write the file with:
1. YAML frontmatter from Step 4
2. H1 heading matching the title
3. Content scaffold appropriate to the type:

**Knowledge:**
```markdown
## Overview

## Details

## Related
```

**Decision:**
```markdown
## Context

## Options Considered

## Decision

## Consequences
```

**Research:**
```markdown
## Objective

## Findings

## Recommendations
```

**Session:**
```markdown
## Session Context

## What Was Done

## Open Questions

## Next Steps
```

**Milestone:**
```markdown
## Summary

## What Was Achieved

## Lessons Learned

## Follow-Up
```

### Step 6: Suggest wikilinks

1. Scan vault files for tag overlap with the new note's tags.
2. Present up to 5 related notes and suggest adding `[[wikilinks]]` in the body.
3. If the user confirms, insert a `## Related` section (or append to existing) with the wikilinks.

### Step 7: Update INDEX.md

If an `INDEX.md` exists in the target directory:
1. Read it.
2. Add a link to the new file in the appropriate section.
3. Write the updated index.

### Step 8: Lint the new file

Run `/obsidian-lint <path-to-new-file>` to validate the note passes all checks.

### Step 9: Commit

Stage and commit the new file in the memory submodule:
```
cd $MEMORY_VAULT_PATH && git add <file> && git commit -m "KEY-XXX: Add <title> to vault"
```

Use the active Jira ticket key if one exists, otherwise use a descriptive message.

## Output

Display:
- File path created
- Frontmatter summary (title, tags, created)
- Related notes found (if any)
- Lint result (pass/fail)
- Commit hash
