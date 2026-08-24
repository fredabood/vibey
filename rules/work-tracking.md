---
description: GitHub-Issues-first work tracking — automatically search for and create issues, post updates, include identifiers in commits
globs:
  - "**/*"
---

# Work Tracking — GitHub-Issues-First Behavior

> Invoke `/workflow` for full gated lifecycle with deterministic enforcement. This rule covers issue search/create mechanics and is active in all sessions.

All implementation work is tracked in GitHub Issues by default. Follow these behaviors automatically without waiting for the user to invoke a skill.

**Repo routing:** Infer the target repo from the work context:
- Working in the homelab repo root or `stacks/`, `internal/`, `.claude/` → **`fredabood/homelab`** (keys `LAB-<n>`; `HL-*` prefix deprecated 2026-07-12, LAB-963)
- Working in `submodules/dirtydata/` or on DRTY-prefixed issues → **`fredabood/dirtydata`** (keys `DRTY-<n>`; `DD-*` deprecated)
- Working in `submodules/9215resort/` or on RESORT-prefixed issues → **`fredabood/9215resort`** (keys `RESORT-<n>`; the LAB-221 + LAB-228 trees transferred here 2026-07-12 — old↔new map in `public.resort_transfer_key_map`, LAB-962)

All open issues from all three repos live on the Projects v2 board **"Homelab Work"** (user `fredabood`, project number 1). Board Status values: `Backlog`, `In Progress`, `Implementation Complete`, `Review Complete`, `Deferred`. See `.claude/rules/custom-fields.md` for stable board/field IDs.

## On any implementation request

Before writing code:

1. **Search GitHub Issues** for a matching issue using `mcp__github__search_issues` (or `mcp__github__list_issues`). Search by keywords from the request; scope to the target repo. The postgres mirror (`jira.*`) can also be queried read-only for richer SQL search.
2. **If found:** Set it as the active issue for the session. Move its board Status to "In Progress" using `mcp__github__projects_write` if not already.
3. **If not found:** Prompt the user: "No GitHub issue found for this work. Should I create one?" If yes, follow the `/create-ticket` workflow to create a structured issue with acceptance criteria (task list in the body).
4. **Evaluate decomposition:** Before beginning work, assess whether it should be multiple issues:
   - Multiple independent codebase areas?
   - Independently verifiable acceptance criteria?
   - More than one session of effort?
   - Mix of setup/infrastructure and feature work?

   If decomposition is warranted, present the proposed breakdown to the user. Use `/create-ticket` for each piece, then create blocked-by dependency links between them:
   ```bash
   gh api -X POST repos/fredabood/<repo>/issues/<BLOCKED#>/dependencies/blocked_by \
     -H "X-GitHub-Api-Version: 2026-03-10" -F issue_id=<BLOCKER-database-id>
   ```
   (Get the blocker's database id with `gh api repos/fredabood/<repo>/issues/<BLOCKER#> --jq .id`.)

## Taxonomy label requirement

When creating or updating issues, apply taxonomy labels per `.claude/rules/label-taxonomy.md`:

- **Work pattern:** exactly one of `scraper`, `agent`, `workflow`, `deployment`, `pipeline`, `migration`, `platform`
- **Infrastructure layer:** exactly one of `L1-platform`, `L2-services`, `L3-framework`, `L4-domain`
- If work matches a known pattern, offer the standard decomposition template from the label-taxonomy rule
- Cross-repo blocked-by links must flow downward: L1 → L2 → L3 → L4

## Stale in-progress issues

At session start, if an issue is already at board Status "In Progress":

1. Check `git log --oneline -20` for recent commits referencing the issue identifier (`LAB-<n>`/`DRTY-<n>`/`RESORT-<n>`, deprecated-era `HL-<n>`/`DD-<n>`, or `#<n>`)
2. **If commits exist within ~24h:** Treat it as actively in progress — resume normally
3. **If the last relevant commit is older than 24h:** Note the gap to the user and ask whether to resume or restart
4. **If no commits reference the identifier at all:** Flag it as potentially stale — ask the user to confirm intent before proceeding
5. **If an `Assigned Agent:` comment exists** and differs from the current session: another agent started but did not finish — warn the user and ask whether to take over or leave it

Do not silently assume a stale In Progress issue is active work.

## Exceptions

- **Trivial changes** (typo fixes, single-line formatting, comment updates) skip tracking
- The user can say **"skip tracking"** to bypass for any change
- If the user explicitly says they don't want an issue, respect that and don't ask again in the session

## Agent assignment protocol

Before moving an issue to "In Progress":

1. Post an assignment comment via `mcp__github__add_issue_comment` (there are no custom fields on GitHub Issues):
   ```
   Assigned Agent: <session-id>
   Session: <ISO timestamp>
   ```
2. Set board Status to "In Progress" using `mcp__github__projects_write`
3. Post context comment: "Starting work. Assigned Agent: `<session-id>`. Session: `<timestamp>`" (may be combined with step 1)

If the issue already has an `Assigned Agent:` comment (most recent wins):
- **Same agent:** Resume normally
- **Different agent:** Warn the user that another agent claimed this issue — ask whether to override or pick a different issue

## Won't Do close-out (service and deployment cancellations)

Closing an issue `not_planned` ends the *tracking*. It does not remove the artifacts the cancelled
work already landed, and nothing else in this file says to. Cancelled-but-present artifacts read as
**live** to the next agent: a stack file that still exists is a service that was going to be deployed,
and the repo carries no signal distinguishing that from one that is.

**Scope of this section:** it applies when closing an issue as `not_planned` where work already
touched the repo or the fleet — in practice, issues carrying the `deployment` label, and any
`platform`/`pipeline` issue that landed a stack file, a route, a runbook, or an env var. It does
**not** apply to a Won't Do on work that never started; there is nothing to retire, and saying so in
the close comment takes one line.

Before closing, walk the table and record the disposition of **every** row in the closing comment.
The point is not that every row applies — most cancellations touch three or four. The point is that
each was *considered*, so a later reader can tell `N/A` from *not looked at*.

| Artifact | Where | Disposition to record |
|---|---|---|
| Stack file | `stacks/<name>.yml` | Retire per `stacks/DEPRECATED_STACKS.md` — `git mv` to `<name>.yml.deprecated` so it leaves the `stacks/*.yml` glob, and add a tombstone entry to that file |
| Runbook | `docs/operations/<name>.md` | Retirement banner at the top (state the issue, the date, and that it is a design record — not operating instructions), or delete |
| Service catalog | `.claude/rules/homelab-services.md` | Remove the service-catalog row **and** the stack-list entry — both, they are separate places |
| Homepage tile | `homelab-data/homepage/services.yaml` | Remove the entry (and the group from `settings.yaml` if it was the last member) |
| Caddy route | `internal/caddy/Caddyfile` | Remove. Do **not** merely comment out — a commented route in the public site block is a one-`reload` publish waiting to happen (#1386, and the radicale tombstone that documents it) |
| DNS record | Cloudflare | Decide and say which: **leave** (the name 404s) or **remove**. Both are fine; silence is not |
| Images / volumes | `docker images` / `docker volume ls` | Record whether the image is **rebuildable** (in a registry, or from a retained build context) and whether volumes are **preserved or dropped**. A locally-built image that is in no registry and whose build context is deleted is gone for good |
| Env vars | `.env.tpl` **and** `.env.example` | Remove the service's vars from both, especially any `:?`-required ones. This is the security row: a cancelled service's credential template is a standing instruction to mint a credential nobody wants |
| Build context | `internal/<name>/` | Retain (reproducible) or delete — record which, and why |
| Scanner / CI config | `.trivyignore.yaml`, `ci/test-allowlist.json`, `internal/scripts/docker-cleanup.sh` | Remove any path-scoped entry that now points at a retired artifact, or note why it stays |

**Why the env-var row is not hypothetical.** OpenDraft was closed Won't Do on 2026-08-12
(#1062, #1045, #1063). A week later its stack file was still present and was **the only one of 20 that failed
compose resolution** — `required variable GOOGLE_API_KEY is missing a value`, because #1063 had
declined to mint the key. An unresolvable stack contributes an empty keep-set to
`docker-cleanup.sh`, so it was also an *unprotected* stack: the 1.6 GB locally-built image had
already been deleted. A session that found this filed #1304 as a credential-provisioning bug, having
no way to know the service was cancelled — the fix it was heading for would have minted a Gemini key
and deployed an abandoned service. `GOOGLE_API_KEY` was the one `:?`-required var missing from
`.env.tpl` across all 52; retiring the stack took that class to zero.

**Recording the dispositions.** Post them as a comment on the issue before closing, under a
`## Won't Do Close-Out` marker, one line per row:

```text
## Won't Do Close-Out

- Stack file: retired → `stacks/opendraft-stack.yml.deprecated` (+ DEPRECATED_STACKS.md entry)
- Runbook: banner added, `docs/operations/opendraft.md`
- Service catalog: 2 rows removed
- Homepage tile: N/A — never had one (batch CLI, no web UI)
- Caddy route: N/A — never had one
- DNS record: N/A — no subdomain was ever created
- Images / volumes: image `homelab/opendraft:1.7.4` already deleted; no volumes; rebuildable from
  the retained build context
- Env vars: `GOOGLE_API_KEY` deliberately NOT added to `.env.tpl` — #1063 declined it
- Build context: retained (`internal/opendraft/`) — the image is in no registry
- Scanner / CI config: `.trivyignore.yaml` still path-scopes `internal/opendraft/Dockerfile`; kept,
  because the build context is retained
```

`N/A` is a valid answer on any row. An absent row is not.

**Retiring the stack file is the load-bearing step.** Everything else is documentation drift; the
`.yml` → `.yml.deprecated` rename is what stops the file from being resolved, cleaned, scanned and
read as live by every tool that globs `stacks/*.yml`.

**What this is not.** It is a checklist, not a script — nothing here automates the removal. And it
does not apply to the `completed` path, which already has `/complete-task`, verification reports and
post-mortems.

**Enforcement, stated honestly.** This is a **soft** gate: `/complete-task` prompts for the checklist
on a `not_planned` close of a `deployment`-labelled issue, and nothing else does. A close made
through raw `gh issue close --reason not_planned` bypasses it entirely — which is exactly what
happened to 34 issues during the LAB-966 audit. A hard hook gate was deliberately deferred (#1361):
gating on a `## Won't Do Close-Out` comment before anything produces one is how "authorised
bypasses" get manufactured. Once the marker is routinely present, the gate becomes cheap.

## Suggesting next work (Planned+Unblocked agent queue)

When an issue is completed or the user asks what to work on next, use the agent work queue
defined in `.claude/rules/label-taxonomy.md`:

1. **Query base candidates:** open issues with acceptance criteria at board Status "Backlog":
   - `mcp__github__search_issues` with `repo:fredabood/homelab is:open "Acceptance Criteria" in:body` (repeat for `fredabood/dirtydata`), or `mcp__github__list_issues` filtered by state/labels
   - Cross-check board Status = `Backlog` via `mcp__github__projects_get` (or read the mirror: `jira.issues WHERE status = 'Backlog'`)
2. For each candidate, use `mcp__github__issue_read` (methods `get`, `get_comments`) and apply three filters:
   - **Planned check:** Body has an `## Acceptance Criteria` task list AND a comment contains `## Implementation Plan`
   - **Blocker check:** No open blockers — `gh api repos/fredabood/<repo>/issues/<n>/dependencies/blocked_by` returns only closed issues (or mirror `jira.issue_links` shows no open blockers)
   - **Assignment check:** If the latest `Assigned Agent:` comment names another agent, skip
3. An issue is **eligible** only if: Planned = true AND Blocked = false AND (unassigned or assigned to current agent)
4. Present results in three tiers:
   - **Ready for pickup:** Eligible items, ordered by priority
   - **Blocked:** Planned but waiting on dependencies — show which blockers are closest to completion
   - **Needs planning:** Missing acceptance criteria or plan comment — note what's missing
5. For blocked candidates, identify which blockers are closest to completion

If no eligible items exist, report: (a) unplanned issues that need criteria/plans, (b) which blockers need resolving to unlock the next tier.
