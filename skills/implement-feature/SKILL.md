---
name: implement-feature
description: 7-step feature development lifecycle — from design through commit with quality gates
user_invocable: true
---

# /implement-feature

**This skill does repo work and must run from a worktree.** Before anything else:
Run: `bash "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/lib/skill-marker.sh" require-worktree implement-feature`
If it exits non-zero, stop and report its message verbatim — do not continue.

**Before any GitHub issue operations**, set the skill execution context marker:
Run: `bash "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/lib/skill-marker.sh" set implement-feature "<issue key>"` — omit the key argument if it is not known yet

Walk through a complete feature development lifecycle in 7 steps with quality gates between each phase.

## Usage

```
/implement-feature "<feature description>"
/implement-feature <ISSUE-KEY>
```

Example: `/implement-feature "Add user profile page with avatar upload"`
Example: `/implement-feature LAB-963` (homelab #963) or `/implement-feature DRTY-7` (dirtydata #7)

Post-migration keys map directly to issue numbers: `LAB-<n>` ↔ `fredabood/homelab#n` (n ≥ 941), `DRTY-<n>` ↔ `fredabood/dirtydata#n`, `RESORT-<n>` ↔ `fredabood/9215resort#n`. (Deprecated `HL-N`/`DD-N` inputs resolve as `LAB-N`/`DRTY-N`.) Migrated keys (`LAB-*` ≤ 286, `DRTY-*`) resolve via the mirror:

```bash
docker exec postgres-memory psql -U postgres -d agent_memory -t -A -c \
  "SELECT gh_repo || '|' || gh_number FROM jira.issues WHERE issue_key = '<KEY>'"
```

## Steps

Execute each step sequentially. Do not proceed to the next step until the current one passes its quality check.

### Step 1: Design

- **Ensure an issue exists:**
  - If input is an issue key, resolve repo/number (above) and fetch it with `mcp__github__issue_read` (method `get`)
  - If input is a description, search for an existing issue with `mcp__github__search_issues` (scope `repo:fredabood/homelab` or `repo:fredabood/dirtydata`). If none found, create one using `/create-ticket` logic.
- **Set board Status to In Progress** if not already — use `mcp__github__projects_write` with the project and field ids from `.claude/rules/custom-fields.md` (project `PVT_kwHOAM5y1M4BcqrU`, Status field `PVTSSF_lAHOAM5y1M4BcqrUzhXRxK4`), and resolve the **"In Progress"** option BY NAME at call time. Option ids are NOT stable — a single `updateProjectV2Field` reissues all of them, so never hardcode or reuse one.
- **Post the assignment comment** (replaces the old Primary/Assigned Agent custom fields) using `mcp__github__add_issue_comment`:
  ```
  Assigned Agent: <session-identifier>
  Session: <ISO timestamp>
  ```
  If a more recent assignment comment names a different agent, warn the user before overriding.
- **Check acceptance criteria** — the issue **body** must contain an `## Acceptance Criteria` task list (`- [ ]`). If missing, draft criteria (minimum: 1 functional + 1 test-based + 1 security) and add them to the body via `mcp__github__issue_write`; confirm with the user before proceeding.
- Understand the requirements (from the description or issue body)
- Identify affected files and components
- Choose the implementation approach
- Note dependencies and risks — read blockers with `gh api repos/fredabood/<repo>/issues/<n>/dependencies/blocked_by` and warn if any blocker is still open
- **Post the implementation plan** — use `mcp__github__add_issue_comment` with the structured markers from `.claude/rules/custom-fields.md`:
  ```markdown
  ## Implementation Plan
  ### Issue Tracking        (issues to create, epic membership, dependencies)
  ### Testing Strategy      (types of tests, specific scenarios, commands)
  ### Documentation         (what docs/memory to update)
  ### Success Criteria
  ### Risk Assessment       (risks and mitigations)
  ```
  Include files to modify, approach, and rationale under the relevant sections.
- **Output:** Brief design summary with file list and approach

### Step 2: Implement

- Write the code following project conventions
- Keep changes minimal and focused
- Handle errors at system boundaries
- **Quality check:** Code passes linting / type checks if configured

### Step 3: Test

- Write tests for the new functionality
- Cover happy path, edge cases, and error paths
- For bug fixes, start with a failing test that reproduces the bug
- Run the full test suite to check for regressions
- **Quality check:** All tests pass, coverage adequate for business logic

### Step 4: Security Review

Review the changed code against these 9 areas:

1. **Hardcoded secrets** — grep for API keys, passwords, tokens in changed files
2. **Environment variables** — verify secrets come from env vars, not code
3. **Input sanitization** — check for SQL injection, XSS, URL injection risks
4. **Logging** — ensure no credentials or PII in log statements
5. **Rate limiting** — verify external API calls have appropriate limits
6. **TLS/HTTPS** — all external URLs use HTTPS, no disabled SSL verification
7. **Error messages** — no system internals or credentials leaked in errors
8. **Dependencies** — no known CVEs in new dependencies
9. **Test security** — no real credentials in test code, external calls mocked

- **Quality check:** No critical or high severity issues. Fix any found before proceeding.

### Step 5: Integration

- Ensure the feature integrates with the existing codebase
- Wire up routes, configuration, or registration as needed
- Run integration tests if they exist
- **Quality check:** Feature accessible and working end-to-end

### Step 6: Documentation

- Update relevant documentation (README, API docs, inline comments)
- Update docs in `docs/` if operational behavior changed
- Update memory files if project-level knowledge or decisions changed
- Only add docs where the code isn't self-explanatory
- **Quality check:** Key behaviors and non-obvious decisions documented

### Step 6.5: Update the Issue

Post a milestone comment using `mcp__github__add_issue_comment` summarizing:
- What was implemented
- Tests added
- Documentation updated
- Any deviations from the plan posted in Step 1

Check off completed acceptance-criteria items in the issue body task list (`- [x]`) via `mcp__github__issue_write`.

### Step 7: Commit

- Review all changes with `git diff`
- Verify no secrets in staged files
- Create a descriptive commit with the issue reference in format `LAB-963: <description>` (or `DRTY-45: ...` / `RESORT-12: ...`; deprecated `HL-*`/`DD-*` prefixes appear only in historical commits). Optionally append `(#963)` for GitHub auto-linking.
- **Quality check:** Clean commit, all tests still pass

## Gate Policy

If any quality check fails, stop and fix the issue before proceeding. Do not skip gates. If the security review finds critical issues, return to Step 2 and fix them.

## Required Tools

- `mcp__github__issue_read` (methods `get`, `get_comments`)
- `mcp__github__issue_write` (create/update — body edits, task-list check-offs)
- `mcp__github__add_issue_comment`
- `mcp__github__search_issues`
- `mcp__github__projects_write` (board Status)
- `gh api .../dependencies/blocked_by` (blocker check — no MCP tool)

**Cleanup:** Run `bash "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/lib/skill-marker.sh" clear` to release the skill gate.
