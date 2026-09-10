---
description: Vault management policy — defines boundary between auto-memory and Obsidian vault, persistence triggers, quality bar, and structural conventions
globs:
  - "**/*"
---

# Vault Management Policy

Two memory systems exist. Each has a clear purpose — do not cross the boundary.

## Two-System Boundary

**Auto-memory** (`~/.claude/projects/.../memory/`) — Claude-only behavioral context:
- `user` type: role, preferences, knowledge level
- `feedback` type: corrections to Claude's approach
- `reference` type: pointers to external resources
- `project` type: lightweight ongoing-work context

**Vault** (`$MEMORY_VAULT_PATH/`) — durable project knowledge:

| Content type | Vault directory |
|---|---|
| Operational knowledge (how-tos, runbooks, config) | `homelab/knowledge/<category>/` |
| Architectural decisions (chose X over Y) | `homelab/decisions/` |
| Research findings (evaluations, comparisons) | `homelab/research/` |
| Session handoffs (continuity context) | `homelab/sessions/` |
| Sprint plans, roadmaps | `homelab/planning/` |
| Project milestones | `homelab/milestones/` |
| Project context, specs | `homelab/context/` |

**Rule of thumb:** Auto-memory answers "how should Claude behave?" Vault answers "what does the project know?"

## Persistence Routing

| Decision scope | Where |
|---|---|
| Ticket-specific (approach, trade-off) | Jira comment |
| Claude behavioral (user prefs, feedback, corrections) | Auto-memory |
| Architectural decision (chose X over Y because Z) | Vault → `decisions/` |
| Operational knowledge (how to run, deploy, configure) | Vault → `knowledge/` |
| Research findings (evaluation, comparison, analysis) | Vault → `research/` |
| Session continuity (handoff context) | Vault → `sessions/` |
| Workflow conventions (Jira config, commit format) | CLAUDE.md (rarely) |

## Proactive Persistence Triggers

### Hard triggers (always persist)

1. **Architectural decision made** → `decisions/` — any non-trivial "we chose X over Y because Z"
2. **Research conducted** → `research/` — any analysis, evaluation, or comparison that took significant effort
3. **New operational knowledge created** → `knowledge/` — how-tos, runbooks, config docs that don't exist yet
4. **Parent issue completed** → `milestones/` — summary of what was achieved and lessons learned

### Soft triggers (persist if substantial)

5. **Session handoff** → `sessions/` — only if the session has meaningful context for continuity
6. **Operational doc changed** → update existing file in `knowledge/` — keep docs in sync
7. **Sprint planned** → `planning/` — only if not already tracked in Jira

### Never persist to vault

- Test results, CI output, or transient state
- Information already in Jira (don't duplicate)
- Information derivable from code or git history
- User preferences or behavioral corrections (those go to auto-memory)

## Quality Bar

Before writing to the vault, evaluate:

- **Durability**: Will this be relevant in 30 days? If not, it's ephemeral → Jira comment at most.
- **Uniqueness**: Does this already exist in the vault? Search titles/aliases first.
- **Actionability**: Can a future session or human act on this? If it's just an observation with no practical use, skip it.

## Structural Conventions

### Frontmatter (required on every vault .md file)

```yaml
---
title: <Note title>
tags:
  - <tag-in-kebab-case>
created: YYYY-MM-DD
---
```

Optional fields: `type`, `aliases`, `entities`, `importance`, `source`, `_migrated`, `last_accessed`, `access_count`

### Staleness Tracking (auto-memory only)

Auto-memory files include staleness metadata maintained by `memory-access-tracker.sh`:

| Field | Type | Description |
|-------|------|-------------|
| `last_accessed` | date | ISO date when file was last loaded into context |
| `access_count` | integer | Cumulative access count across sessions |

Files not accessed in 90+ days are candidates for archival or consolidation.
Run `python3 scripts/memory-cleanup.py` to generate a staleness report.
Use `--archive` flag to move stale files to a `stale/` subdirectory.

### Filenames

- Use kebab-case for technical/operational directories
- Title Case acceptable in `reference/` and vault root

### Wikilinks

- Use `[[note-name]]` for internal links, not markdown-style `[text](path.md)`
- Link to related notes when creating new content

### Pre-commit validation

The `memory-frontmatter-check.sh` hook validates frontmatter on all staged `.md` files in the memory submodule. It blocks commits missing `title`, `tags`, or `created` fields. Run `/obsidian-lint --fix` to auto-repair issues.
