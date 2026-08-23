# GitHub Field Mapping — Statuses, Board IDs, and Structured Comments

Canonical mapping of the old Jira field vocabulary to GitHub-native constructs.
All skills, hooks, and agents reference this file for lifecycle operations.

> Rewritten for the GitHub Issues migration (2026-07). The Jira custom fields
> (customfield_10173–10195) are gone; their content lives in **structured issue
> comments** with `##` markers, and workflow status lives on the **Projects v2
> board**. Historical field values are preserved in the postgres mirror columns
> (`jira.issues.plan_*`, `verification_*`, `pm_*`, etc.) for migrated issues.

---

## Projects v2 Board — Stable IDs

| Object | ID |
|--------|-----|
| Project "Homelab Work" (user `fredabood`, number 1) | `PVT_kwHOAM5y1M4BcqrU` |
| `Status` single-select field | `PVTSSF_lAHOAM5y1M4BcqrUzhXRxK4` |

**Status options:**

| Option | ID |
|--------|-----|
| Backlog | `093793f1` |
| In Progress | `62ad3706` |
| Implementation Complete | `2eec8df1` |
| Review Complete | `0aa21637` |
| Deferred | `087e34a4` |

These IDs are stable for the life of the board. Scripts may hardcode them but must
fail loudly if a GraphQL mutation rejects them (board recreated → re-derive with
`gh api graphql` querying `user(login:"fredabood"){projectV2(number:1){...}}`).

## Status Transitions

There are no Jira transition IDs anymore. To move an issue:

| Action | How |
|--------|-----|
| Backlog → In Progress (etc.) | `mcp__github__projects_write` — update item's `Status` field |
| Any → Done | `mcp__github__issue_write` — `state: closed`, `state_reason: completed` |
| Any → Won't Do | `mcp__github__issue_write` — `state: closed`, `state_reason: not_planned` |
| Reopen | `mcp__github__issue_write` — `state: open`, then set board Status |

Closing an issue removes it from the board (D5). Reopening re-adds it via the
webhook receiver with `Status=Backlog`.

## Structured Comment Vocabulary

The old plan/verification/post-mortem custom fields map to issue comments whose
sections use these exact `##`/`###` markers (hooks and the Planned-check grep for them):

### Plan comment (replaces Plan: * fields)

```
## Implementation Plan
### Jira Tracking        → now: Issue Tracking (issues to create, parent-issue membership, dependencies)
### Testing Strategy
### Documentation
### Success Criteria
### Risk Assessment
```

A comment containing `## Implementation Plan` marks the issue as **Planned**
(together with an `## Acceptance Criteria` task list in the body).

### Verification comment (replaces Verification: * fields)

```
## Verification Report
### Criteria Tested      (each body checklist item, individually, with evidence)
### Results Summary
```

### Post-mortem comment (replaces Post-Mortem: * fields)

```
## Post-Mortem: <KEY> — <summary>
### What Went Well
### What Didn't Go Well
### Lessons Learned
### Metrics
### Follow-Up Items
```

### Doc review (replaces Doc Review: * fields)

Folded into the post-mortem or a standalone comment:

```
## Doc Review
### Documentation        (docs/ files created/updated and why)
### Memory Updates       (auto-memory + vault notes persisted)
```

### Agent assignment (replaces Primary/Assigned Agent fields)

```
Assigned Agent: <session-identifier>
Session: <ISO timestamp>
```

Posted as a short comment when picking up an issue. The most recent assignment
comment wins. Warn before overriding another agent's assignment.

## Acceptance Criteria / Success Criterion Issues

- Acceptance criteria = native task list (`- [ ]`) under `## Acceptance Criteria` in the issue **body** (not a comment — the body is editable and renders progress).
- The old Success Criterion subtask type is gone. If a criterion needs standalone tracking, convert the task-list item to a sub-issue (GitHub UI or `sub_issue_write`).
- Test Marker / Human Approval Required: prepend to the criterion text, e.g. `- [ ] [pytest:test_foo] [HUMAN-APPROVAL] <condition>`.

## Issue Types

GitHub's native issue types are an **organization** feature; `fredabood` is a personal
account, so there are **no issue types**. A **parent issue** is simply an issue that has
sub-issues (GitHub's native parent-issue role) — there is no "Epic". Defects use the
`bug` label. The mirror's legacy `issue_type='Epic'` derivation is **deprecated** (detect
parent issues via has-sub-issues); `Relates` links are dropped — GitHub has no native
"relates to", only **blocked by** / **blocking** dependencies.

## Mirror Columns (read-only reference)

> [!WARNING]
> **Corrected 2026-08-23 (LAB-966 Phase 4).** This section previously stated that
> historical field content "is preserved" in the `jira.issues.plan_*` /
> `verification_*` / `pm_*` columns for migrated issues. **Measured, that is false** —
> those columns are ~1% populated, and treating them as the recovery surface sends you
> to an empty table. The real surface is `jira.issue_changelog`. The wrong claim cost a
> session: `plan_*` was queried, returned zero, and 85 issues were written off as
> unrecoverable when their content was in the changelog all along.

The `jira.issues` columns `plan_jira_tracking`, `plan_testing_strategy`,
`plan_documentation`, `plan_success_criteria`, `plan_risk_assessment`,
`verification_*`, `pm_*`, `doc_review_*`, `primary_agent`, `assigned_agent`,
`agent_runtime`, `workflow_phase`, `test_marker` and `human_approval_required` exist,
but are **almost entirely empty**. Measured against 1,128 migrated issues
(1,817 total rows):

| Columns | Rows populated |
|---------|---------------:|
| `plan_*` (all five) | **12** — `LAB-101`–`LAB-113`, one two-day window in 2026-03 |
| `verification_*`, `pm_*`, `primary_agent`, `assigned_agent`, `workflow_phase` | **2** |
| `doc_review_*`, `test_marker`, `human_approval_required` | **0** |

**Use `jira.issue_changelog` instead.** Jira's change history was mirrored, so the last
value of an edited field survives even though the issue body did not. It retains **34
distinct fields** and covers an order of magnitude more issues:

| Field | Issues with recoverable content |
|-------|--------------------------------:|
| `description` | **184** |
| `Plan: Jira Tracking` / `Plan: Documentation` | **130** each |
| `labels` | 133 |

```sql
-- Recover a field's last surviving value
SELECT DISTINCT ON (issue_key) issue_key, to_string
FROM jira.issue_changelog
WHERE field = 'description'      -- or any of the 34 fields
ORDER BY issue_key, changed_at DESC;
```

**Caveat that bounds the whole surface:** the changelog only captured *edits inside its
sync window* (roughly 2026-02-28 → 2026-04-24). A field set once at creation and never
edited has no row, and is genuinely gone. That is why some issues are recoverable and
others are not — it is not random, and it is not worth re-deriving per issue.

Recovery status and the remaining sweep: `fredabood/homelab#1479`. Full recovery-surface
map: `submodules/memory/homelab/research/jira-content-recovery-map.md`.

New (post-migration) issues have all of these NULL by design — their equivalents are the
structured comments above, fetched via `mcp__github__issue_read` (method `get_comments`).

## Usage

### Reading lifecycle state

```
mcp__github__issue_read  method=get           → state, state_reason, labels, body (criteria)
mcp__github__issue_read  method=get_comments  → plan / verification / post-mortem / assignment
mcp__github__projects_get                     → board Status for open issues
```

### Writing

```
mcp__github__issue_write                      → create/update/close (state_reason!)
mcp__github__add_issue_comment                → structured comments
mcp__github__projects_write                   → board Status
mcp__github__sub_issue_write                  → parent-issue membership
gh api .../dependencies/blocked_by            → Blocks links (no MCP tool yet)
```
