---
name: complete-task
description: Complete a task — run quality gates, add summary comment, set board Status to "Implementation Complete" (or close as completed)
user_invocable: true
---

# /complete-task

**This skill does repo work and must run from a worktree.** Before anything else:
Run: `bash "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/lib/skill-marker.sh" require-worktree complete-task`
If it exits non-zero, stop and report its message verbatim — do not continue.

**Before any GitHub operations**, set the skill execution context marker:
Run: `bash "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/lib/skill-marker.sh" set complete-task "<issue key>"` — omit the key argument if it is not known yet

Finish work on a GitHub issue. Verifies acceptance criteria, runs quality checks, posts a summary and post-mortem, and advances the issue — board Status "Implementation Complete" by default, or close as completed for terminal Done.

Cancelling instead of finishing takes a different path: see **Won't Do closes** below, which prompts the artifact close-out checklist rather than the verification/post-mortem sequence.

## Usage

```
/complete-task <#N | LAB-N | DRTY-N | RESORT-N>
```

(Historical `HL-N`/`DD-N` inputs still resolve: `HL-N` ≡ `LAB-N`, `DD-N` ≡ `DRTY-N`.)

Example: `/complete-task LAB-963`

Migrated keys (`LAB-*`, `DRTY-*`, `LEGACY-*`) resolve to repo+number via `public.github_migration_key_map` (see `/start-task`).

## Steps

### Step 1: Fetch the issue

Use `mcp__github__issue_read` (method: get) to retrieve current state, and `mcp__github__projects_get` to confirm board Status is "In Progress".

### Step 2: Run quality gates

Before completing, verify:
- All tests pass (run the project's test suite)
- No obvious security issues in changed files (grep for hardcoded secrets)
- Changed files are committed
- Test coverage on changed files has not decreased

**Hard gate:** Do not proceed if tests fail or security issues are found.

### Step 3: Verify acceptance criteria

Extract the `## Acceptance Criteria` task list from the issue **body**. For each criterion:
- Run the specified verification (test command from a `[pytest:...]` marker or `Tests pass:` text, file check, behavior walkthrough)
- Record pass/fail with evidence
- `[HUMAN-APPROVAL]` criteria require explicit user confirmation — do not self-approve

Generate and post a verification report comment using `mcp__github__add_issue_comment` (exact `##`/`###` markers per `.claude/rules/custom-fields.md`):

```markdown
## Verification Report

### Criteria Tested

| # | Criterion | Status | Evidence |
|---|-----------|--------|----------|
| 1 | <criterion> | PASS/FAIL | <how verified> |

### Results Summary
**Result:** ALL PASS / <N> FAILURES
```

Then tick the passing checkboxes in the issue body (`- [ ]` → `- [x]`) using `mcp__github__issue_write` (method: update).

**Hard gate:** Do not proceed if any criterion fails. List what needs fixing.

### Step 4: Generate summary

Collect:
- Files changed (`git diff --name-only` against the branch start)
- Key decisions made during implementation
- Any deviations from the original issue body
- Anything the next person should know
- Linked commits from the mirror: query `SELECT commit_short, repo, message FROM jira.commit_links WHERE issue_key = '<KEY>' ORDER BY committed_at` via `docker exec postgres-memory psql -U postgres -d agent_memory` (issue_key is the mirror key: `LAB-<n>`, `DRTY-<n>`, or `RESORT-<n>` — post-migration `<n>` = GitHub issue number, migrated issues keep their original keys) and include as a commits table in the summary

### Step 5: Add summary comment

Use `mcp__github__add_issue_comment` to post the summary in Markdown format.

### Step 6: Generate and post post-mortem

Generate a structured post-mortem following the `/post-mortem` workflow (heading marker must be `## Post-Mortem:`):

```markdown
## Post-Mortem: <KEY> — <Summary>

**Completed:** <date>
**Duration:** <time from In Progress to close>

### What Went Well
- <positive outcomes>

### What Didn't Go Well
- <issues, unexpected problems, time sinks>

### Lessons Learned
- <actionable insights>

### Metrics
- Files changed: <count>
- Commits: <count>
- Tests added/modified: <count>
- Acceptance criteria met: <X/Y>

### Follow-Up Items
- [ ] <remaining work>
```

Post using `mcp__github__add_issue_comment`. There are no custom fields on GitHub — the structured comment IS the canonical record (hooks and the mirror parse the `##`/`###` markers).

### Step 7: Advance status

**Preferred target:** board Status → "Implementation Complete" — use `mcp__github__projects_write` with the IDs from `.claude/rules/custom-fields.md`:
- Project `PVT_kwHOAM5y1M4BcqrU`, Status field `PVTSSF_lAHOAM5y1M4BcqrUzhXRxK4`, option "Implementation Complete" = `2eec8df1`

This leaves the issue open for `/review-ticket` (docs + memory + testing verification) before terminal close.

**Terminal Done (only when the user wants to skip the review stage or the review has already passed):** close the issue with `mcp__github__issue_write` — `state: closed`, `state_reason: completed`. Closing removes it from the board (D5 prune).

`state_reason: not_planned` is **not** the completion path — it means Won't Do, and the work was cancelled rather than finished. Do not reach for it to make a stalled issue go away. If the user does want a Won't Do close, jump to the Won't Do section below instead of continuing through Steps 8–11.

### Step 8: Check parent epic

If this issue is a sub-issue of an epic, check whether all siblings are closed: `mcp__github__issue_read` (method: get_sub_issues) on the parent, or `gh api repos/fredabood/<repo>/issues/<epic#>/sub_issues`. If all sub-issues are closed, note that the epic may be ready to close (as completed).

### Step 9: Persist lessons to memory

If the post-mortem contains significant lessons learned:
- Save to a memory file in the project memory directory
- Include enough context for future sessions to apply the lesson

### Step 10: Create follow-up issues

If follow-up items were identified in the post-mortem:
- Present them to the user
- Offer to create each as a new issue using `/create-ticket` logic

### Step 11: Output

Confirm completion with a brief summary (issue number, mirror key, new status, verification result).

## Won't Do closes (`state_reason: not_planned`)

A Won't Do close cancels the work. Steps 2–6 do not apply — there is nothing to verify and no
post-mortem of a thing that was not built. What replaces them is the close-out checklist, because
cancelling the *tracking* does not remove the artifacts the work already landed, and a
cancelled-but-present artifact reads as live to the next agent.

**This is a soft prompt, not a gate.** Nothing blocks a `not_planned` close today (LAB-1361 ruled a
hard hook gate a follow-up). Run the prompt anyway — it is the only thing standing between a
cancellation and a stack file that still fails `compose config` a week later (#1304).

1. **Read the issue's labels** — `mcp__github__issue_read` (method `get`).
2. **If the issue carries the `deployment` label** (or it is a `platform`/`pipeline` issue that
   landed a stack file, a route, a runbook, or an env var), **prompt the user with the artifact
   checklist** from `.claude/rules/work-tracking.md` → *Won't Do close-out*: stack file, runbook,
   service catalog, homepage tile, Caddy route, DNS record, images/volumes, env vars
   (`.env.tpl` **and** `.env.example` — the security row), build context, scanner/CI config.
3. **Record a disposition for every row**, not just the ones that apply. `N/A` is a valid answer;
   an absent row is not — that distinction is the whole point, because it is what lets a later
   reader tell "considered and irrelevant" from "never looked at".
4. **Post the dispositions** as a comment under the `## Won't Do Close-Out` marker
   (`mcp__github__add_issue_comment`) **before** closing. That marker is the artifact a future hard
   gate would key on, so emit it even when every row is `N/A`.
5. **If the work never started** — no repo or fleet artifact exists — say exactly that in one line
   under the same marker and skip the table. Do not skip the comment.
6. **Then close:** `mcp__github__issue_write` — `state: closed`, `state_reason: not_planned`.
   Closing removes the issue from the board (D5 prune).

## Required Tools

- `mcp__github__issue_read` (method: get, get_comments, get_sub_issues)
- `mcp__github__issue_write` (body checkbox updates; close with `state_reason: completed`, or
  `not_planned` for a Won't Do — see the Won't Do section)
- `mcp__github__projects_get` / `mcp__github__projects_write` (board Status)
- `mcp__github__add_issue_comment` (verification report, summary, post-mortem)
- `mcp__github__search_issues` / `mcp__github__sub_issue_write` — for follow-ups
- `gh api` — sub-issue/dependency readback; `docker exec postgres-memory psql` — commit links (Bash)

## Repos & Board

Repos: `fredabood/homelab`, `fredabood/dirtydata`. Board and Status option IDs: `.claude/rules/custom-fields.md`.

**Cleanup:** Run `bash "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/lib/skill-marker.sh" clear` to release the skill gate.
