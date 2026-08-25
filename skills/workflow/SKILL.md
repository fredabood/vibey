---
name: workflow
description: Full lifecycle workflow — work tracking, planning, git, implementation, verification, completion, memory, handoff
user_invocable: true
---

# /workflow

**This skill does repo work and must run from a worktree.** Before anything else:
Run: `bash "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/lib/skill-marker.sh" require-worktree workflow`
If it exits non-zero, stop and report its message verbatim — do not continue.

**Before any GitHub issue operations**, set the skill execution context marker:
Run: `bash "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/lib/skill-marker.sh" set workflow "<issue key>"` — omit the key argument if it is not known yet

End-to-end 12-phase development lifecycle with deterministic gates at every phase.
Phases 1-6: planning + implementation. Phase 7: Implementation Complete (post-mortem). Phases 8-9: Doc Review + Review Complete. Phases 10-12: memory persistence, PR landing, handoff.
Backed by a persistent state machine (postgres + file cache) that enables hook enforcement and cross-session resume.

When active, hooks on Edit/Write/Commit/Transition block out-of-sequence actions. When not active, Claude operates normally.

## Usage

```
/workflow <ISSUE-KEY>
/workflow "<description>"
```

Example: `/workflow LAB-963` (homelab issue #963) or `/workflow DRTY-45` (dirtydata issue #45)
Example: `/workflow LAB-164` (migrated issue — key resolves via the mirror)
Example: `/workflow "Add user profile page with avatar upload"`

## Key → Repo/Number Resolution

The work item key is the mirror key (unified scheme, LAB-963): `LAB-<n>` ↔ `fredabood/homelab#n` (post-migration, n ≥ 941), `DRTY-<n>` ↔ `fredabood/dirtydata#n`, `RESORT-<n>` ↔ `fredabood/9215resort#n`. Migrated issues keep their original `LAB-*`/`DRTY-*`/`LEGACY-*` keys, and deprecated `HL-<n>`/`DD-<n>` inputs resolve as `LAB-<n>`/`DRTY-<n>` — resolve any key to its GitHub coordinates via the mirror:

```bash
docker exec postgres-memory psql -U postgres -d agent_memory -t -A -c \
  "SELECT gh_repo || '|' || gh_number FROM jira.issues WHERE issue_key = '<KEY>'"
```

Use the resolved `<repo>` (`homelab`, `dirtydata`, or `9215resort`, owner `fredabood`) and `<number>` for all `mcp__github__*` calls. The reverse map is `jira.gh_issue_key(repo, number)`.

## State Machine

Each phase writes state to **both** postgres (`workflow.runs`) and `.workflow-state.json` (gitignored file cache for fast hook reads).

**State write helper** — run after every phase gate passes:

```bash
# DB write (phases 1-10 have dedicated columns)
docker exec postgres-memory psql -U postgres -d agent_memory -c \
  "UPDATE workflow.runs SET phase_<N>_at = NOW() WHERE work_item_key = '<KEY>' AND completed_at IS NULL"

# Phases 11-12 have no dedicated column — record in metadata instead:
docker exec postgres-memory psql -U postgres -d agent_memory -c \
  "UPDATE workflow.runs SET metadata = metadata || jsonb_build_object('phase_<N>_at', now()::text) WHERE work_item_key = '<KEY>' AND completed_at IS NULL"

# File write
python3 -c "
import json, os, datetime
f = '.workflow-state.json'
state = json.load(open(f)) if os.path.exists(f) else {}
state['phase_<N>_at'] = datetime.datetime.now().isoformat()
json.dump(state, open(f, 'w'), indent=2)
"
```

Replace `<N>` with the phase number and `<KEY>` with the work item key.

## Initialization

### If input is a key (e.g., LAB-963, DRTY-45, RESORT-12)

1. Resolve the key to `<repo>`/`<number>` (see Key → Repo/Number Resolution above)
2. Check postgres for an active (incomplete) workflow:
   ```bash
   docker exec postgres-memory psql -U postgres -d agent_memory -t -A -c \
     "SELECT row_to_json(r) FROM workflow.runs r WHERE work_item_key = '<KEY>' AND completed_at IS NULL"
   ```
3. **If a row exists** (cross-session resume):
   - Write the DB state to `.workflow-state.json` (hydrate file cache)
   - Identify the next incomplete phase (first `phase_N_at` that is NULL)
   - Output: `> Resuming workflow <KEY> at Phase N: <name>`
   - Skip to that phase
4. **If no row exists** (fresh start):
   - Insert a new row:
     ```bash
     docker exec postgres-memory psql -U postgres -d agent_memory -c \
       "INSERT INTO workflow.runs (work_item_key) VALUES ('<KEY>')"
     ```
   - Write initial `.workflow-state.json`: `{"work_item_key": "<KEY>"}`
   - Proceed to Phase 1

### If input is a description

1. Search for an existing issue using `mcp__github__search_issues` (scope: `repo:fredabood/homelab` or `repo:fredabood/dirtydata` per context) — the mirror's semantic search (`agent-runtime:8095/api/search/jira`) is also acceptable
2. If found: use the existing key, follow the key path above
3. If not found: create a new issue using `/create-ticket` logic, then follow the key path

## Phases

Execute each phase sequentially. Do not proceed to the next phase until the current gate passes.
Output a status line after each phase: `> Phase N: <name> ✓`

---

### Phase 1: Work Item

1. Fetch the work item with `mcp__github__issue_read` (method `get`) — confirm it is open
2. If board Status is not already "In Progress", set it via `mcp__github__projects_write` (project `PVT_kwHOAM5y1M4BcqrU`, Status field `PVTSSF_lAHOAM5y1M4BcqrUzhXRxK4`, option **"In Progress"** resolved by name at call time — option ids are NOT stable, see `.claude/rules/custom-fields.md`)
3. Post the assignment comment (there are no custom fields on GitHub — this replaces Primary/Assigned Agent) using `mcp__github__add_issue_comment`:
   ```
   Assigned Agent: <session-identifier>
   Session: <ISO timestamp>

   Starting workflow.
   ```
   If a more recent assignment comment names a *different* agent, warn the user before overriding.
4. **Write state:** DB + file (`phase_1_at`)

**Gate:** Work item exists, board Status = In Progress, assignment comment posted.

---

### Phase 2: Acceptance Criteria

1. Parse the issue **body** for an `## Acceptance Criteria` task list (`- [ ]` items)
2. **If criteria exist:** Confirm they are measurable and deterministic. Display them.
3. **If criteria are missing:**
   - Draft criteria following the standard format (minimum: 1 functional + 1 test-based + 1 security)
   - Add them to the issue **body** (not a comment — the body renders task-list progress) using `mcp__github__issue_write` (update, preserving existing body content)
   - Confirm with the user before proceeding
4. **Write state:** DB + file (`phase_2_at`)

**Gate:** Acceptance criteria exist in the issue body.

---

### Phase 3: Implementation Plan

1. Draft an implementation plan including:
   - **Approach:** files to modify, components affected, rationale
   - **Testing strategy:** types of tests, specific scenarios, verification commands
   - **Documentation plan:** what docs/memory/vault to update
   - **Risk assessment:** what could go wrong, mitigations, fallback approaches
2. Post the plan as an issue comment using `mcp__github__add_issue_comment`, using the exact section markers from `.claude/rules/custom-fields.md` (hooks and the Planned-check grep for them):

```markdown
## Implementation Plan

### Issue Tracking
<issues to create, epic membership, dependencies>

### Testing Strategy
<...>

### Documentation
<...>

### Success Criteria
<...>

### Risk Assessment
<...>
```

3. **Ask the user to confirm the plan before proceeding.** Do not continue until confirmed.
4. **Write state:** DB + file (`phase_3_at`)

**Gate:** Plan comment (`## Implementation Plan`) posted AND user has confirmed.

> After this phase completes, the Edit/Write hook gate opens — code edits are now allowed.

---

### Phase 4: Worktree Setup

Work happens in a **worktree**. The primary checkout (`/Users/fredabood/homelab`) is a deploy
mirror pinned to `main`: its Caddyfile and stack files are bind-mounted into running containers,
and its `HEAD` is shared by every concurrent session. **Nothing in this phase may move it.**

1. Confirm the session is in a worktree. `wf_mode` is the canonical detector — do not
   reimplement it:

   ```bash
   . .claude/hooks/lib/worktree-facts.sh && wf_mode "$PWD"
   ```

   - `WORKTREE` → proceed.
   - `PRIMARY` → **stop and tell the user.** Ask to work in a worktree (`EnterWorktree`,
     name it `<KEY>-<kebab-description>`), or relaunch with
     `claude --worktree <KEY>-<kebab-description>`. Do **not** try to create one by running git
     in the shared checkout — the worktree gate blocks that, correctly.
   - Anything else (`OUT_OF_SCOPE`, `OUT_OF_REPO`, `UNRESOLVABLE`) → stop and report; the
     session is not where it thinks it is.

2. A fresh worktree checks out tracked files only, so `.claude` (a submodule) may be **empty** —
   which means zero hooks, rules and skills. If `ls -A .claude` returns 0 entries:

   ```bash
   git submodule update --init .claude
   ```

   See `docs/development/worktrees.md`. `.env` arrives automatically via `.worktreeinclude`.

3. **Do not `git stash`.** Another session may have unstaged work in a shared tree, and a stash
   would capture it. There is nothing to stash in a fresh worktree.

4. **Write state:** DB + file (`phase_4_at`, `branch_name`)
   - Record the branch **as git reports it**, not as you would compose it — `EnterWorktree`
     names the branch `worktree-<name>`:
     ```bash
     git rev-parse --abbrev-ref HEAD
     ```
   - DB: `UPDATE workflow.runs SET branch_name = '<branch>' WHERE ...`
   - File: add `"branch_name": "<branch>"` and `"worktree": "<path>"` to `.workflow-state.json`

**Gate:** `wf_mode` reports `WORKTREE`, and the branch is named for the work item.

---

### Phase 5: Implementation

1. Write code following project conventions
2. Write tests:
   - Unit tests for business logic (target 90%+ coverage on new code)
   - Integration tests for external service interactions
   - Cover happy path, edge cases, and error paths
   - For bug fixes: write a failing test that reproduces the bug first
3. Security review (9-point checklist):
   - Hardcoded secrets, environment variables, input sanitization, logging, rate limiting, TLS/HTTPS, error messages, dependencies (CVEs), test security
4. Update `docs/` if operational behavior changed
5. Commit with issue reference: `<KEY>: <description>` (e.g., `LAB-963: Add avatar upload`; optionally append `(#963)` for GitHub auto-linking)
6. Post milestone comment(s) to the issue at significant checkpoints (tests passing, integration working, docs updated) via `mcp__github__add_issue_comment`
7. **Write state:** DB + file (`phase_5_at`)

**Gate:** Code compiles/lints, tests written, security review clean, changes committed.

---

### Phase 6: Verification

1. Run the full test suite — all tests must pass
2. For each acceptance criterion:
   - Run the specified verification (test command, file check, behavior walkthrough)
   - Record pass/fail with evidence
3. Post a verification report as an issue comment using `mcp__github__add_issue_comment`, with the exact markers from `.claude/rules/custom-fields.md`:

```markdown
## Verification Report

### Criteria Tested
| # | Criterion | Status | Evidence |
|---|-----------|--------|----------|
| 1 | <criterion text> | PASS/FAIL | <how verified> |
| 2 | ... | ... | ... |

### Results Summary
**Result:** ALL PASS / <N> FAILURES — <X/Y> criteria passed
```

4. Check off passing criteria in the issue body task list (`- [x]`) via `mcp__github__issue_write`
5. **Write state:** DB + file (`phase_6_at`)

**Hard gate:** ALL criteria must pass. If any fail, stop and fix before retrying Phase 6. Do not proceed with failures.

---

### Phase 7: Completion (Implementation Complete)

1. Generate a structured post-mortem (same format as before)
2. Post the post-mortem as an issue comment using `mcp__github__add_issue_comment`, with the exact markers:

```markdown
## Post-Mortem: <KEY> — <summary>

### What Went Well
### What Didn't Go Well
### Lessons Learned
### Metrics
### Follow-Up Items
```

3. Move board Status → **Implementation Complete** via `mcp__github__projects_write` (resolve that option BY NAME — ids are reissued on any field edit, `.claude/rules/custom-fields.md`)
4. Check if the work item has a parent epic — `mcp__github__issue_read` (method `get`, look for parent) or check the parent's sub-issues (method `get_sub_issues`). If all sibling sub-issues are closed or in Implementation Complete, note it.
5. **Write state:** DB + file (`phase_7_at`)

**Gate:** Post-mortem comment posted, board Status = Implementation Complete.

---

### Phase 8: Doc Review

1. Review all documentation changes from the session:
   - What docs in `docs/` were created or updated?
   - What memory files were written or updated?
   - What vault notes were created?
   - What issue comments were posted?
2. Generate a documentation summary and a memory update summary
3. Post a doc review comment to the issue using `mcp__github__add_issue_comment`, with the exact markers:

```markdown
## Doc Review

### Documentation
<docs/ files created/updated and why — or "No updates — <reason>">

### Memory Updates
<auto-memory + vault notes persisted — or "No updates — <reason>">
```

4. **Write state:** DB + file (`phase_8_at`)

**Gate:** Doc Review comment posted.

---

### Phase 9: Review Complete

1. Move board Status → **Review Complete** via `mcp__github__projects_write` (resolve that option BY NAME — ids are reissued on any field edit, `.claude/rules/custom-fields.md`)
2. **Write state:** DB + file (`phase_9_at`)

**Gate:** Board Status = Review Complete.

---

### Phase 10: Memory & Knowledge Persistence

1. Review all decisions made during the session
2. For each decision or lesson learned, route to the correct store:

| Scope | Store | Method |
|-------|-------|--------|
| Issue-specific (approach, trade-off) | Already posted as issue comment | Done in earlier phases |
| Claude behavioral (user correction, preference) | Auto-memory (`~/.claude/projects/.../memory/`) | Write memory file + update MEMORY.md |
| Architectural (chose X over Y because Z) | Vault → `submodules/memory/homelab/decisions/` | Use `/vault-add` logic |
| Operational knowledge (how to run, deploy, configure) | Vault → `submodules/memory/homelab/knowledge/` | Use `/vault-add` logic |
| Research findings (evaluation, comparison, analysis) | Vault → `submodules/memory/homelab/research/` | Use `/vault-add` logic |

3. If follow-up items were identified in the post-mortem, present them to the user and offer to create new issues (`/create-ticket` logic; add blocked-by links where ordering matters)
4. **Write state:** DB + file (`phase_10_at`)

**Gate:** At least one persistence action taken, or explicitly noted "nothing to persist" with justification.

---

### Phase 11: Land through a PR

`main` is protected server-side (ruleset `21157484`) and cannot be pushed to directly. Landing
is a PR, merged only when the required checks are green. **Never** `git checkout main`,
`git merge`, or `git branch -d` — those move the shared checkout's `HEAD` and the worktree gate
blocks them.

1. Commit and push from the worktree:

   ```bash
   git add <paths>
   git commit -F <message-file>        # subject: "<KEY>: <description>"
   git push -u origin "$(git rev-parse --abbrev-ref HEAD)"
   ```

   Use `-F <file>` rather than `-m` when the message contains backticks — the shell will
   command-substitute them otherwise.

2. Open the PR. Body carries the acceptance-criteria summary and the verification evidence from
   Phase 6:

   ```bash
   gh pr create --repo fredabood/<repo> --base main \
     --head "$(git rev-parse --abbrev-ref HEAD)" \
     --title "<KEY>: <description>" --body-file <body-file>
   ```

   > If the title or body must contain the literal `.env`, `gh pr create` is refused by
   > `env-secret-guard.sh`. Build a JSON payload and post it instead:
   > `gh api repos/fredabood/<repo>/pulls --input <payload.json>`.

3. Wait for green, then merge. **Do not use `--auto`** — auto-merge is disabled on this repo
   (`allow_auto_merge: false`), so it fails. `delete_branch_on_merge` is also false, so
   `--delete-branch` is required:

   ```bash
   gh pr checks <pr> --repo fredabood/<repo> --watch --fail-fast
   gh pr merge  <pr> --repo fredabood/<repo> --squash --delete-branch
   ```

   `main` requires `Config validation`, `Lint`, `Discover suites` and `tests-complete`. If a
   check goes red, fix it and push again — **never** merge with `--admin`.

4. Confirm the merge, reading the SHA back rather than composing it:

   ```bash
   gh pr view <pr> --repo fredabood/<repo> --json state,mergeCommit --jq '"\(.state) \(.mergeCommit.oid)"'
   ```

5. Remove the worktree — `ExitWorktree` (action `remove`), or from the primary checkout
   `git worktree remove <path> && git worktree prune`.

6. **Write state:** DB (metadata `phase_11_at`) + file (`phase_11_at`)

**Gate:** PR is `MERGED`, the worktree is removed, and the primary checkout's `HEAD` was never
moved by this session.

> Editing the `.claude` submodule? It has no rulesets: push the branch to `.claude` `main`,
> then open a **homelab** PR bumping the gitlink, titled `<KEY>: Bump .claude — <what changed>`.

---

### Phase 12: Handoff

1. Close the issue as Done using `mcp__github__issue_write`: `state: closed`, `state_reason: completed`. (Closing removes it from the board — D5 prune. For a Won't Do outcome instead, use `state_reason: not_planned`.)
2. Mark the workflow as complete:
   ```bash
   docker exec postgres-memory psql -U postgres -d agent_memory -c \
     "UPDATE workflow.runs SET metadata = metadata || jsonb_build_object('phase_12_at', now()::text), completed_at = NOW() WHERE work_item_key = '<KEY>' AND completed_at IS NULL"
   ```
3. Delete `.workflow-state.json` (deactivates hook enforcement)
4. Output final summary:

```markdown
## Workflow Complete: <KEY>

- **Work item:** <KEY> — <summary> → closed (completed)
- **Worktree:** <path> → removed
- **PR:** #<pr> → <state> (<merge-sha>)
- **Commits:** <count>
- **Verification:** <X/Y> criteria passed
- **Post-mortem:** posted
- **Memory:** <what was persisted>
- **Follow-ups:** <created / none>
```

---

## Aborting a Workflow

If the user needs to abort an active workflow:

1. Delete `.workflow-state.json` (deactivates hooks immediately)
2. Update the DB row: `UPDATE workflow.runs SET completed_at = NOW(), metadata = metadata || '{"aborted": true}' WHERE work_item_key = '<KEY>' AND completed_at IS NULL`
3. The issue remains in its current state/board Status — no automatic transition or close
4. **Leave the worktree on disk** (`ExitWorktree` with action `keep`) unless the user asks for it
   to go — an abort usually means the work resumes later, and removing it discards the commits

## Required Tools

- `mcp__github__issue_read` (methods `get`, `get_comments`, `get_sub_issues`)
- `mcp__github__issue_write` (create/update/close — `state_reason` matters)
- `mcp__github__add_issue_comment`
- `mcp__github__search_issues` / `mcp__github__list_issues`
- `mcp__github__projects_write` / `mcp__github__projects_get` (board Status)
- `gh api repos/fredabood/<repo>/issues/<n>/dependencies/blocked_by` — dependency read/create (no MCP tool)
- `gh pr create` / `gh pr checks --watch --fail-fast` / `gh pr merge --squash --delete-branch` — Phase 11 landing
- `EnterWorktree` / `ExitWorktree` — Phase 4 entry, Phase 11 cleanup
- `docker exec postgres-memory psql ...` — state machine + key resolution (mirror is read-only for `jira.*`)

## Board IDs

Use the stable IDs from `.claude/rules/custom-fields.md` (project `PVT_kwHOAM5y1M4BcqrU`, Status field `PVTSSF_lAHOAM5y1M4BcqrUzhXRxK4`). If a mutation rejects them, re-derive via `gh api graphql` — fail loudly, do not guess.

**Cleanup:** Run `bash "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/lib/skill-marker.sh" clear` to release the skill gate.
