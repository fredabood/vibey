---
name: obsidian-lint
description: Lint Obsidian vault files — validate frontmatter, normalize tags, convert wikilinks, detect broken links and orphans
user_invocable: true
---

# /obsidian-lint

Lint an Obsidian vault for structural issues: frontmatter validation, wikilink consistency, broken links, tag normalization, attachment hygiene, file naming, and orphan detection. Produces a structured report and optionally auto-fixes safe issues.

## Usage

```
/obsidian-lint              → lint entire vault (default: $MEMORY_VAULT_PATH/)
/obsidian-lint <path>       → lint specific file or folder
/obsidian-lint --fix        → auto-apply safe fixes
```

Examples:

- `/obsidian-lint` — scan the full vault at `$MEMORY_VAULT_PATH/`
- `/obsidian-lint $MEMORY_VAULT_PATH/operations/` — scan only the operations directory
- `/obsidian-lint --fix` — fix all auto-fixable issues across the vault
- `/obsidian-lint $MEMORY_VAULT_PATH/knowledge/some-note.md --fix` — fix a single file

## Steps

### Step 1: Resolve target path

1. If no path argument is given, default to `$MEMORY_VAULT_PATH/` relative to the repository root.
2. If a path is given, resolve it relative to the repository root.
3. Verify the path exists and contains `.md` files.
4. Collect all `.md` files in the target (recursively if directory).
5. Note whether `--fix` mode is active.

### Step 2: Frontmatter validation

For each `.md` file, parse the YAML frontmatter block (between `---` delimiters at the top of the file).

**Required fields:**
- `title` — must be a string
- `tags` — must be a YAML array (list), not a comma-separated string
- `created` — must be a date in `YYYY-MM-DD` format

**Optional fields (do not flag if missing):** `type`, `aliases`, `entities`, `importance`, `source`, `_migrated`

**Flag as errors:**
- Missing required fields (`title`, `tags`, `created`)
- `created` value that does not match `YYYY-MM-DD` pattern
- `tags` that is not a YAML array (e.g., a comma-separated string or a single string)
- Malformed YAML frontmatter (parse errors)

**`--fix` behavior:**
- Add missing `title` by extracting the first `# Heading` from the file body; if no H1 exists, derive from filename (strip `.md`, replace hyphens with spaces, title-case)
- Add missing `created` with today's date in `YYYY-MM-DD` format
- Convert comma-separated tags string to a YAML array (split on commas, trim whitespace)

### Step 3: Wikilink conversion

Scan each file for internal markdown-style links that should be wikilinks.

**Detect:** Markdown links matching `[text](path)` where:
- `path` is a relative path (does not start with `http://` or `https://`)
- `path` points to a `.md` file (ends with `.md` or contains `.md#`)

**Convert to:** `[[note-name|text]]` where `note-name` is the filename without extension and without directory path. If `text` equals `note-name`, use the short form `[[note-name]]`.

**Preserve:** All external links (`http://`, `https://`, `mailto:`, etc.) are left untouched.

**`--fix` behavior:** Auto-convert detected internal markdown links to wikilinks.

### Step 4: Broken link detection

Build an index of all `.md` filenames (without extension, case-insensitive) in the vault.

For each file, extract all wikilinks: `[[target]]` and `[[target|display]]`.

**Resolution rules:**
- Strip any `#heading` anchors before matching
- Match `target` against vault filenames case-insensitively
- A wikilink is broken if no file matches

**Flag as errors:** Each broken wikilink with the source file and the unresolved target.

**Not auto-fixable** — broken links require human judgment.

### Step 5: Tag normalization

For each file, extract the `tags` array from frontmatter.

**Tag rules:**
- Must be lowercase
- Must be kebab-case (words separated by hyphens, no spaces, no underscores)
- Must not have a `#` prefix in YAML frontmatter
- Must not contain spaces

**Flag as warnings:**
- `CamelCase` or `PascalCase` tags (contain uppercase letters)
- Tags with spaces
- Tags with `#` prefix
- Tags with underscores instead of hyphens

**`--fix` behavior:**
- Convert to lowercase
- Strip leading `#` prefix
- Replace spaces and underscores with hyphens
- Convert camelCase/PascalCase to kebab-case (insert hyphen before each uppercase letter, then lowercase)

### Step 6: Attachment hygiene

Scan each file for image references using the pattern `![alt](path)`.

**Flag as warnings:** Image references where the path does not include an `_attachments/` directory segment.

**`--fix` behavior:** For each flagged image:
1. Determine the `_attachments/` directory relative to the referencing file
2. If the image file exists at the referenced path, move it to the `_attachments/` directory
3. Update the image reference path in the markdown file
4. If the `_attachments/` directory does not exist, create it

### Step 7: File naming enforcement

Check each `.md` filename against naming conventions based on its directory.

**Technical/operational directories** (must use kebab-case filenames):
- `operations/`
- `security/`
- `development/`
- `networking/`
- `getting-started/`
- `migrations/`
- `integrations/`
- `platforms/`

Kebab-case means: all lowercase, words separated by hyphens, no spaces, no underscores, no uppercase letters. Example: `backup-restore.md`

**Reference/personal directories** (Title Case acceptable):
- `reference/`
- Knowledge root (top-level files in the vault)

**Flag as warnings:** Files in technical directories that violate kebab-case naming.

**Not auto-fixable** — renaming files affects all wikilinks pointing to them and requires user decision.

### Step 8: Orphan detection

Build a directed graph of all wikilinks across the entire vault:
- For each file, record all outbound wikilinks (files it links to)
- For each file, record all inbound wikilinks (files that link to it)

**Flag as warnings:** Files that have **zero inbound AND zero outbound** wikilinks (completely disconnected from the vault graph).

**Exclusions:** Skip files named `INDEX.md` (case-insensitive) from orphan detection — index files are expected entry points.

**Not auto-fixable** — orphans need review to decide if they should be linked, merged, or removed.

### Step 9: Generate report

After all checks are complete, output a structured report:

```
## Obsidian Lint Report: <path>

**Files scanned:** N
**Issues found:** N (N auto-fixable)

### Errors (must fix)
| File | Check | Issue | Fixable |
|------|-------|-------|---------|
| ... | ... | ... | Yes/No |

### Warnings (review)
| File | Check | Issue |
|------|-------|-------|
| ... | ... | ... |

### Summary
- Frontmatter: N valid, N issues
- Links: N valid, N broken
- Tags: N normalized, N issues
- Naming: N compliant, N violations
- Orphans: N detected
```

**Categorization:**
- **Errors:** Missing required frontmatter fields, broken wikilinks, malformed YAML
- **Warnings:** Tag normalization issues, attachment hygiene, naming violations, orphans

If no issues are found, output a clean report confirming all checks passed.

### Step 10: Apply fixes (when --fix is active)

When `--fix` is specified:

1. Apply all auto-fixable changes (frontmatter fixes, wikilink conversions, tag normalization, attachment moves)
2. Write changes to disk
3. Re-run all lint checks on the modified files
4. Output the report showing remaining (non-auto-fixable) issues
5. Summarize what was fixed: number of files modified, number of fixes applied per category
