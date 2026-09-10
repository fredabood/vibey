# Memory Management — Guidelines

When and how to proactively manage Claude's memory systems.
These are guidelines for all sessions. When `/workflow` is active,
memory persistence becomes a mandatory gate (Phase 8) enforced by the state machine.

> Invoke `/workflow` for Phase 8 (Memory & Knowledge Persistence) with gated enforcement.

## Session Start

- MEMORY.md index is auto-loaded — scan for relevant context
- If resuming work on a known topic, check for related memories
- If a session handoff note exists in vault `sessions/`, read it for continuity

## Mandatory Persistence Triggers

Save immediately when these occur — don't defer to session end:

| Trigger | Memory type | Location |
|---------|------------|----------|
| User corrects Claude's approach | `feedback` | Auto-memory |
| User shares role/preference/context | `user` | Auto-memory |
| New external resource discovered | `reference` | Auto-memory |
| Architectural decision (chose X over Y) | — | Vault → `decisions/` |
| New operational knowledge | — | Vault → `knowledge/` |
| Research conducted (significant effort) | — | Vault → `research/` |

## Memory Hygiene

- Before creating a new memory file: check MEMORY.md for existing entry on same topic
- **Update** existing entries rather than creating duplicates
- When a memory is proven wrong by current observation: update or delete it
- Keep MEMORY.md index under 200 lines — consolidate if approaching limit

## What NOT to Save

- Code patterns or architecture (derivable from code)
- Transient debugging state or test output
- Information already in Jira comments (don't duplicate)
- Git history or recent changes (use `git log`)
- Ephemeral task details only relevant to the current conversation

## Two-System Boundary

**Auto-memory** (`~/.claude/projects/.../memory/`) answers: "How should Claude behave?"
**Vault** (`$MEMORY_VAULT_PATH/`) answers: "What does the project know?"

`$MEMORY_VAULT_PATH` is exported from `~/.dotfiles/zsh/.zshenv` and resolves to
`~/Repositories/memory` — the standalone `fredabood/memory.md` repo. It was
`homelab/submodules/memory` until the 2026-09-10 de-monorepo split. The vault
stays ONE central repo across every project (`homelab/`, `projects/<name>/`)
rather than splitting per-repo: cross-project linking and a single Postgres
embedding index are the reason it exists.

Don't cross the boundary. User preferences go to auto-memory. Project decisions go to the vault.
