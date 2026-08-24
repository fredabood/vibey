---
name: handoff
description: Generate a session handoff summary for continuity between conversations
user_invocable: true
---

# /handoff

**This skill does repo work and must run from a worktree.** Before anything else:
Run: `bash "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/lib/skill-marker.sh" require-worktree handoff`
If it exits non-zero, stop and report its message verbatim — do not continue.

Why the *whole* skill refuses when only Step 8 writes to the repo: Steps 1–7 post issue comments,
which cannot be retracted. Failing at Step 8 leaves comments claiming a continuity the vault does
not have. For a run that genuinely only posts comments, the refusal message names the override
(`SKILL_ALLOW_PRIMARY=1`).

**Before any GitHub issue operations**, set the skill execution context marker:
Run: `bash "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/lib/skill-marker.sh" set handoff`

Generate a session handoff summary and persist it to the active GitHub issue(s) and memory for continuity across conversations.

## Usage

```
/handoff
```

## Steps

### Step 1: Collect session activity

- Files changed: `git diff --name-only` (staged and unstaged)
- Commits made: `git log --oneline` since session start (compare to recent history)
- Issues touched (any issues whose board Status changed, that were commented on, created, or closed during the session — keys `LAB-<n>`/`DRTY-<n>`/`RESORT-<n>`; deprecated `HL-*`/`DD-*` ≡ `LAB-*`/`DRTY-*`)

### Step 2: Summarize work done

- What features were implemented or bugs fixed
- What tests were added or updated
- What documentation was changed

### Step 3: Capture decisions

- Any design choices made and their rationale
- Any trade-offs accepted
- Any deviations from the original plan

### Step 4: Identify open items

- Uncommitted changes and their purpose
- Failing tests or known issues
- Issues still In Progress on the board
- Next steps that should be taken

### Step 5: Note blockers

- Anything that prevented completion
- Questions that need answers
- External dependencies waiting on (including open blocked-by links — `gh api repos/fredabood/<repo>/issues/<n>/dependencies/blocked_by`)

### Step 6: Format handoff

```markdown
## Session Handoff — <date>

### Completed
- <what was done>

### Decisions
- <decision and why>

### Open Items
- <what's pending>

### Blockers
- <what's blocked and why>

### Next Steps
1. <recommended next action>
2. <follow-up>

### Files Changed
- <file list>
```

### Step 7: Post to GitHub

For each issue touched during the session:

1. Use `mcp__github__add_issue_comment` to post the relevant subset of the handoff summary as a comment. Each issue gets only the context relevant to it — not the full handoff.
2. For issues still In Progress, state the lifecycle point reached in the handoff comment (there is no Workflow Phase field on GitHub — the comment is the record), e.g.:
   ```
   Workflow phase reached: 5 (implementation — tests passing, verification pending)
   Assigned Agent: <session-id>
   ```
   If an active `/workflow` run exists, its phase state is already in `workflow.runs` / `.workflow-state.json` — quote the phase number from there. This ensures the next agent or session knows where the issue stands.
3. Leave board Status as-is — handoff does not transition issues.

### Step 8: Save to memory

- **Session continuity context** → vault: `submodules/memory/homelab/sessions/` (use `/vault-add` logic with proper frontmatter) — decisions, open items, and next-session checkpoints the next conversation needs
- **Behavioral corrections or user preferences** learned this session → auto-memory (`~/.claude/projects/.../memory/`) + MEMORY.md index
- Lessons learned during the session (if significant) → appropriate vault directory per `.claude/rules/vault-management.md`

### Step 9: Update docs if needed

If project-level documentation or conventions changed during the session, ensure `docs/` is updated and changes are committed.

## Required Tools

- `mcp__github__add_issue_comment`
- `mcp__github__issue_read` (method `get` — confirm issue state before commenting)
- `gh api .../dependencies/blocked_by` (blocker readback, optional)

**Cleanup:** Run `bash "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/lib/skill-marker.sh" clear` to release the skill gate.
