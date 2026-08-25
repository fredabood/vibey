---
name: review-ticket
description: Verify acceptance criteria for an issue — run tests, check conditions, post verification report to GitHub
user_invocable: true
---

# /review-ticket

**Before any GitHub operations**, set the skill execution context marker:
Run: `bash "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/lib/skill-marker.sh" set review-ticket "<issue key>"` — omit the key argument if it is not known yet

Verify all acceptance criteria for a GitHub issue before completion. Runs tests, checks conditions, posts a verification report, and sets board Status to "Review Complete" on pass.

## Usage

```
/review-ticket <#N | LAB-N | DRTY-N | RESORT-N>
```

(Historical `HL-N`/`DD-N` inputs still resolve: `HL-N` ≡ `LAB-N`, `DD-N` ≡ `DRTY-N`.)

Example: `/review-ticket LAB-963`

Migrated keys (`LAB-*`, `DRTY-*`, `LEGACY-*`) resolve to repo+number via `public.github_migration_key_map` (see `/start-task`).

## Steps

### Step 1: Fetch issue

Use `mcp__github__issue_read` (method: get) for the issue body and (method: get_comments) for all comments.

### Step 2: Extract acceptance criteria

Parse the `## Acceptance Criteria` task list from the issue **body**. If no criteria exist:
1. Check comments for criteria posted later (they belong in the body — offer to move them there via `mcp__github__issue_write`)
2. If still none found, report: "No acceptance criteria found. Run `/start-task` to draft criteria before reviewing."

### Step 3: Verify each criterion

For each criterion, determine the verification method and execute it:

| Criterion type | Verification method |
|---|---|
| Test-based (`Tests pass: <command>` or `[pytest:<marker>]` prefix) | Run the command, capture pass/fail output |
| File-based (file exists, config present) | Check file existence and content |
| Behavior-based (feature works as described) | Walk through verification steps, document evidence |
| Security (no regressions) | Run security checks on changed files |
| Documentation (docs updated) | Verify referenced docs exist and are current |
| `[HUMAN-APPROVAL]` prefixed | Requires explicit user confirmation — do not self-approve; record who approved |

### Step 4: Generate verification report

Use the exact `##`/`###` markers from `.claude/rules/custom-fields.md` — hooks and the mirror grep for them:

```markdown
## Verification Report

### Criteria Tested

| # | Criterion | Status | Evidence |
|---|-----------|--------|----------|
| 1 | <criterion text> | PASS | <how verified, command output summary> |
| 2 | <criterion text> | FAIL | <what failed, expected vs actual> |

### Results Summary
**Result:** ALL PASS / <N> FAILURES

<expanded evidence for any non-trivial verifications>
```

### Step 5: Update the body checklist

Tick the checkbox (`- [ ]` → `- [x]`) for each criterion that passed, using `mcp__github__issue_write` (method: update) on the issue body. Leave failing criteria unticked.

### Step 6: Post to GitHub

Use `mcp__github__add_issue_comment` to post the verification report on the issue.

### Step 7: Gate result

- **All pass:** Set board Status → "Review Complete" via `mcp__github__projects_write`:
  - Project `PVT_kwHOAM5y1M4BcqrU`, Status field `PVTSSF_lAHOAM5y1M4BcqrUzhXRxK4`, option **"Review Complete"** — resolve its id by name at call time; option ids are NOT stable (`.claude/rules/custom-fields.md`)

  Confirm the issue is ready for terminal close (`/complete-task` → close with `state_reason: completed`).
- **Any fail:** List what needs fixing. Do not advance the board Status and do not proceed to completion. Suggest specific actions to address each failure.

## Required Tools

- `mcp__github__issue_read` (method: get, get_comments)
- `mcp__github__issue_write` (method: update — tick body checkboxes)
- `mcp__github__add_issue_comment`
- `mcp__github__projects_get` / `mcp__github__projects_write` (board Status)

## Repos & Board

Repos: `fredabood/homelab`, `fredabood/dirtydata`. Board and Status option IDs: `.claude/rules/custom-fields.md`.

**Cleanup:** Run `bash "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/lib/skill-marker.sh" clear` to release the skill gate.
