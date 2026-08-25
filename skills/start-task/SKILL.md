---
name: start-task
description: Start working on a GitHub issue — sets board Status to "In Progress" and sets context
user_invocable: true
---

# /start-task

**This skill does repo work and must run from a worktree.** Before anything else:
Run: `bash "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/lib/skill-marker.sh" require-worktree start-task`
If it exits non-zero, stop and report its message verbatim — do not continue.

**Before any GitHub operations**, set the skill execution context marker:
Run: `bash "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/lib/skill-marker.sh" set start-task "<issue key>"` — omit the key argument if it is not known yet

Start working on a GitHub issue. Checks acceptance criteria, sets the board Status to "In Progress", posts an assignment comment, and sets up the working context for the session.

## Usage

```
/start-task <#N | LAB-N | DRTY-N | RESORT-N>
```

(Historical `HL-N`/`DD-N` inputs still resolve: `HL-N` ≡ `LAB-N`, `DD-N` ≡ `DRTY-N`.)

Example: `/start-task LAB-963`

Key resolution: post-migration keys map directly to issue numbers — `LAB-<n>` = `fredabood/homelab#n` (n ≥ 941), `DRTY-<n>` = `fredabood/dirtydata#n`, `RESORT-<n>` = `fredabood/9215resort#n`. Migrated keys (`LAB-*` ≤ 286, `DRTY-*`, `LEGACY-*`) resolve via the mirror:
```
docker exec postgres-memory psql -U postgres -d agent_memory -c \
  "SELECT gh_repo, gh_number FROM public.github_migration_key_map WHERE old_key = '<KEY>'"
```

## Steps

### Step 1: Fetch the issue

Use `mcp__github__issue_read` (method: get) to retrieve the issue (title, body with acceptance criteria, state, labels), and (method: get_comments) for the comment history. Use `mcp__github__projects_get` to read the current board Status.

### Step 2: Validate state and assignment

Confirm the issue is not closed. If board Status is already "In Progress", check whether it's stale (per `.claude/rules/work-tracking.md`):

1. Find the most recent `Assigned Agent: <session-id>` comment
2. Check `git log --oneline -20` for recent commits referencing the issue key (`LAB-<n>` / `DRTY-<n>` / `RESORT-<n>`, or deprecated-era `HL-<n>`/`DD-<n>`)
3. **Recent commits (~24h) + same agent:** resume normally, skip the board transition
4. **Assigned to a different agent:** warn the user — another agent claimed this issue. Ask whether to take over (post a new assignment comment) or pick a different issue
5. **No relevant commits / older than 24h:** flag as potentially stale and ask the user whether to resume or restart

### Step 3: Check for blockers

Read the issue's dependencies (no MCP tool — use `gh api`):

```bash
gh api repos/fredabood/<repo>/issues/<n>/dependencies/blocked_by \
  -H "X-GitHub-Api-Version: 2026-03-10"
```

**If all blockers are closed (or no blockers):** Proceed.

**If any blocker is still open:** Display:
```
Warning: This issue has unresolved blockers:
- <repo>#<n> (LAB-nnn): <title> (state: open, board Status: <status>)
```

Ask the user whether to:
- Proceed anyway (acknowledge risk of rework)
- Switch to a blocker instead (suggest highest-priority open blocker)
- View next-eligible issues (no open blockers)

### Step 4: Check planning state

Scan the comments (from Step 1) for a plan comment containing `## Implementation Plan`:

- **If no plan comment exists:** Note: "This issue has no implementation plan posted. Consider running /implement-feature or /workflow for structured planning before implementation."
- **If a plan comment exists:** Display which plan sections (`### Issue Tracking`, `### Testing Strategy`, `### Documentation`, `### Success Criteria`, `### Risk Assessment`) are present.

This is informational — do not block; the user may intend to plan during implementation.

### Step 5: Check acceptance criteria

Parse the issue **body** for an `## Acceptance Criteria` task list.

- **If criteria exist:** Confirm they are measurable and deterministic. Display them for the session.
- **If criteria are missing:** Prompt: "This issue has no acceptance criteria. Would you like me to draft some before we begin?"
  - If the user agrees, draft criteria based on the body following the standard format:
    ```
    ## Acceptance Criteria
    - [ ] <Specific verifiable condition>
    - [ ] Tests pass: `<command>`
    - [ ] No security regressions
    - [ ] Documentation updated (if applicable)
    ```
  - Add them to the issue **body** using `mcp__github__issue_write` (method: update) — criteria live in the body as a native task list, not in a comment.
  - If the user declines, note the gap and proceed.

### Step 6: Set board Status to In Progress

Use `mcp__github__projects_write` to update the issue's item on the "Homelab Work" board:

- Project: `PVT_kwHOAM5y1M4BcqrU` (user `fredabood`, number 1)
- `Status` field: `PVTSSF_lAHOAM5y1M4BcqrUzhXRxK4`
- Option **"In Progress"** — resolve its id by name at call time; option ids are NOT stable (`.claude/rules/custom-fields.md`)

These IDs are stable for the life of the board (`.claude/rules/custom-fields.md`). If the mutation rejects them, fail loudly and re-derive via `gh api graphql` querying `user(login:"fredabood"){projectV2(number:1){...}}` — never silently skip the transition. If the issue is somehow not on the board, note it (the n8n webhook should have added it) and add it via `projects_write`.

### Step 7: Post the assignment comment

Use `mcp__github__add_issue_comment` to post (this replaces the old Primary/Assigned Agent custom fields):

```
Assigned Agent: <session-identifier>
Session: <ISO timestamp>

Starting work on this issue.
```

The most recent assignment comment wins. One active assignment per issue.

### Step 8: Set working context

Summarize the issue for the session:
- Issue number, mirror key, and title
- Body / acceptance criteria
- Issues this blocks — work waiting on this issue (`gh api repos/fredabood/<repo>/issues/<n>/dependencies/blocking`, or mirror: `SELECT target_key FROM jira.issue_links WHERE source_key = '<KEY>' AND link_type = 'Blocks'`)
- Issues this is blocked by (from Step 3) — with current state
- Relevant files (if mentioned in the issue)

### Step 9: Output

Display a brief summary confirming the task is started and what needs to be done.

## Required Tools

- `mcp__github__issue_read` (method: get, get_comments)
- `mcp__github__issue_write` (method: update — body edits for drafted criteria)
- `mcp__github__projects_get` / `mcp__github__projects_write` (board Status)
- `mcp__github__add_issue_comment`
- `gh api .../dependencies/blocked_by` — blocker readback (Bash)

## Repos & Board

Repos: `fredabood/homelab`, `fredabood/dirtydata`. Board and Status option IDs: `.claude/rules/custom-fields.md`.

**Cleanup:** Run `bash "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/lib/skill-marker.sh" clear` to release the skill gate.
