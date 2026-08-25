# Work Taxonomy — Label Classification

Every GitHub issue requires exactly one **work pattern** label and one **infrastructure layer** label.
These labels drive decomposition templates, agent routing, and dependency validation.
The label taxonomy exists identically in both repos (`fredabood/homelab`, `fredabood/dirtydata`).

> Design rationale: `submodules/memory/homelab/decisions/work-taxonomy.md`

---

## Dimension 1: Work Pattern (REQUIRED — exactly one)

| Label | Description | Keyword hints |
|---|---|---|
| `scraper` | Data scraper or API connector — fetch external data into storage | scrape, crawl, fetch, ingest, connector, API client |
| `agent` | AI agent with tool-use — autonomous task execution | agent, AI, LLM, tool-use, autonomous, chat |
| `workflow` | n8n workflow or scheduled automation | n8n, workflow, automation, schedule, trigger, webhook |
| `deployment` | Deploy, configure, or operate a service | deploy, service, stack, container, Caddy route, Docker |
| `pipeline` | Data pipeline — transform, enrich, or aggregate data | pipeline, ETL, medallion, transform, schema, data quality |
| `migration` | Migrate data or consolidate systems | migrate, consolidate, export, import, decommission, move |
| `platform` | Platform or infrastructure change | infrastructure, Docker, security, networking, monitoring, backup, DNS |

## Dimension 2: Infrastructure Layer (REQUIRED — exactly one)

| Label | Scope | Examples |
|---|---|---|
| `L1-platform` | Foundation everything else depends on | Docker, Caddy, networking, DNS, Cloudflare, Tailscale, security, backup, OS, storage |
| `L2-services` | Running services shared across domains | PostgreSQL, Ollama, n8n, Grafana, MinIO, pgvector, MLflow, Open WebUI, MCP servers, Prometheus |
| `L3-framework` | Reusable components that domain apps build on | Scraper framework, agent runtime, Claude Code primitives, n8n workflow patterns |
| `L4-domain` | Business logic specific to one project | REAL deal scoring, GAME game logic, COS email triage, HOME automations, FOOD recipe workflow |

**Key property:** An issue at Layer N may depend on issues at Layers 1 through N-1, but never on Layer N+1.

## Dimension 3: Data Source (OPTIONAL)

For scraper and pipeline work, add a `source:` prefixed label identifying the external system.
Examples: `source:rentcast`, `source:gmail`, `source:bsa-online`

---

## Status Workflow (INFORMATIONAL — not a label)

Workflow status is NOT a label. Open-issue status lives on the Projects v2 board
**"Homelab Work"** (`Status` single-select); terminal states are the native GitHub
issue `state` + `state_reason`. This section documents the workflow so all agents
and rules share a consistent understanding.

| Status | Where | Description | Entry trigger | Exit trigger |
|---|---|---|---|---|
| `Backlog` | board Status | Queued, not started | Issue created (auto-added by webhook receiver) | Agent picks up work |
| `In Progress` | board Status | Active implementation | Agent starts (projects_write) | Implementation + tests done |
| `Implementation Complete` | board Status | Code + tests + post-mortem done | CI gates pass | Review verified |
| `Review Complete` | board Status | Docs + memory + testing verified | Review passes | Close as completed |
| `Deferred` | board Status | Parked for later — valid idea, not prioritized now | Manual decision | Reactivate to Backlog |
| Done | `closed` + `state_reason: completed` | Terminal | All gates pass | — |
| Won't Do | `closed` + `state_reason: not_planned` | Cancelled or abandoned | Manual decision | Terminal |

**Valid transitions:**

```
Backlog ──→ In Progress ──→ Implementation Complete ──→ Review Complete ──→ closed/completed
   │                                  │
   ├──→ closed/not_planned (Won't Do) ←──┘   (from any open status)
   └──→ Deferred ←──────────────────────      (from any open status; reactivate to Backlog)
```

**Mechanics:** Board Status changes via `mcp__github__projects_write`; close/reopen via
`mcp__github__issue_write` (always set `state_reason`). Closed issues **stay on the board** at
`Status = Done` (corrected 2026-08-25, LAB-1352 — the D5 prune was never implemented and is no
longer the intended semantics); reopening moves the item back to `Backlog`. Both are done by the
webhook receiver in ~2 s. Board and field ids — and why the **option** ids must be resolved by
name rather than hardcoded — are in `.claude/rules/custom-fields.md`.

---

## Planned (CALCULATED — not a label)

An issue is **Planned** when it has both:
1. An `## Acceptance Criteria` task list (`- [ ]`) in the issue **body**
2. An implementation plan posted as an issue comment (contains `## Implementation Plan`)

| Value | Meaning |
|---|---|
| `true` | Both criteria and plan exist — ready for work queue consideration |
| `false` | Missing criteria, plan, or both — needs planning before pickup |

**Detection logic (agent-side):**
1. `mcp__github__issue_read` (method `get`) → inspect body for `## Acceptance Criteria` heading with a task list
2. `mcp__github__issue_read` (method `get_comments`) → search for a comment containing `## Implementation Plan`
3. Both present = Planned

This is calculated at read time, not stored anywhere. See `.claude/rules/label-taxonomy.md` (this file) as the canonical definition.

---

## Blocked (CALCULATED — not a label)

An issue is **Blocked** when it has at least one open blocker in its dependency list — i.e., another issue that must finish first but hasn't.

| Value | Meaning |
|---|---|
| `true` | At least one blocker is still open |
| `false` | No blockers, or all blockers are closed |

**Detection logic (agent-side):**
1. Read blockers: `gh api repos/fredabood/<repo>/issues/<n>/dependencies/blocked_by -H "X-GitHub-Api-Version: 2026-03-10"`
2. If any returned issue has `state: open` → Blocked = true
3. Alternative (read-only mirror): query `jira.issue_links` joined to `jira.issues` — `source_key` = blocker, `target_key` = blocked; any blocker not Done → Blocked = true

This is calculated at read time, not stored anywhere.

---

## Agent Work Queue

The agent work queue consists of issues eligible for autonomous pickup:

```
Eligible = board Status:"Backlog" AND Planned:true AND Blocked:false
```

**Base query:**
```
mcp__github__search_issues:  repo:fredabood/<repo> is:open is:issue "Acceptance Criteria" in:body
  (or mcp__github__list_issues with state=open, sorted oldest first)
```
Cross-check board Status = `Backlog` via `mcp__github__projects_get`, or query the mirror directly:
```sql
SELECT issue_key, summary, priority FROM jira.issues
WHERE status = 'Backlog' ORDER BY priority DESC, created_at ASC;
```

**Agent-side filtering (after query results):**
1. **Plan check:** Verify a comment containing `## Implementation Plan` exists (`issue_read` method `get_comments`)
2. **Blocker check:** Verify no open blockers (`gh api .../dependencies/blocked_by` or mirror `issue_links`)
3. **Assignment check:** If the latest `Assigned Agent:` comment names another agent, skip

**Pickup protocol:**
1. Query the work queue using the base query + agent-side filters above
2. Select the highest-priority eligible issue
3. Post an assignment comment (`Assigned Agent: <session-id>` + `Session: <ISO timestamp>`) via `mcp__github__add_issue_comment`
4. Set board Status to "In Progress" via `mcp__github__projects_write`
5. Post context comment with session timestamp (may be combined with the assignment comment)

**Priority within the queue:** priority (descending, from mirror or issue labels) → created date (ascending, oldest first).

---

## Issue Placement Decision Tree

```
How many L4 domain projects consume this work's output?

  ZERO (generic infrastructure) → fredabood/homelab
    Running service? → L2 parent issue
    Platform/infra? → L1 parent issue

  ONE (single domain) → that domain's repo (L4)
    Cross-repo blocked-by link to homelab if it touches shared infra.

  MULTIPLE (shared across domains) → fredabood/homelab as L3 framework
    Blocked-by links FROM domain issues TO this homelab issue (it blocks them).
```

**Promotion rule:** single-consumer → multi-consumer = move issue to homelab L3.

## Project-Layer Mapping

Former Jira projects now live as **repos** (LAB→homelab, DRTY→dirtydata) or as
**domain scopes within a repo** (labels/parent issues) — there are no separate REAL/GAME/FOOD trackers.

| Project (legacy key) | Now | Layers | Scope |
|---|---|---|---|
| **LAB** | repo `fredabood/homelab` (keys `LAB-<n>`; deprecated `HL-*` ≡ `LAB-*`) | L1, L2, L3, L4 | Homelab platform — infra, services, frameworks, and consolidated domain work |
| **DRTY** | repo `fredabood/dirtydata` (keys `DRTY-<n>`; deprecated `DD-*` ≡ `DRTY-*`) | L1, L2, L3, L4 | DirtyData intelligence platform — same taxonomy as homelab |
| **REAL** | domain scope under `fredabood/dirtydata` | L4 | Real estate investing |
| **GAME** | domain scope under `fredabood/homelab` | L4 | Autonomous game studio |
| **FOOD** | domain scope under `fredabood/homelab` | L4 | Recipe/cooking workflows |

> **Consolidated into homelab:** HOME (smart home automation → LAB-119 parent issue), WEB (personal website → LAB-120 parent issue), and COS (AI personal assistant → LAB-134 parent issue) were migrated as L4-domain parent issues. All history is preserved in the migrated issues and the postgres mirror.

---

## Decomposition Templates

When an issue matches a work pattern, offer the standard decomposition. User can always override.

### Scraper (4 steps)
1. Configure credentials / evaluate API access
2. Build scraper — fetch raw data to storage
3. Design schema + transformation for normalized data
4. Schedule execution (n8n) + add monitoring

### Agent (5 steps)
1. Document agent architecture + tool interface spec
2. Create tool functions for data access
3. Build agent (MVP)
4. Add tests + error handling
5. Document + monitoring

### Workflow (3 steps)
1. Design workflow (inputs, triggers, nodes)
2. Implement + test
3. Schedule + monitor

### Deployment (5 steps)
1. Research — evaluate image, config, resource needs
2. Stack file + environment config
3. Caddy route + staging deployment
4. Production deployment + homepage + monitoring
5. Document operations runbook

### Pipeline (5 steps)
1. Schema design (source → normalized → derived)
2. Ingestion layer (raw data landing)
3. Transformation layer (entity resolution, enrichment)
4. Business logic layer (scoring, ranking, aggregation)
5. Validation + data quality checks

### Migration (5 steps)
1. Audit current state
2. Export / extract data
3. Import / transform to target
4. Verify completeness + functional test
5. Decommission source (if applicable)

### Platform (4 steps)
1. Research / design
2. Implement change
3. Test (staging-first for production changes)
4. Document

---

## Agent Routing

| Work Pattern | Primary Agent | Secondary Agents |
|---|---|---|
| `scraper` | `data-engineer` | `security-reviewer`, `test-engineer` |
| `agent` | `architecture-reviewer` | `test-engineer`, `security-reviewer` |
| `workflow` | `n8n-designer` | `observability-reviewer` |
| `deployment` | `homelab-ops` | `security-reviewer`, `observability-reviewer` |
| `pipeline` | `data-engineer` | `test-engineer` |
| `migration` | `data-engineer` | `homelab-ops` |
| `platform` | `homelab-ops` | `security-reviewer`, `architecture-reviewer` |

---

## Dependency Direction

1. **Cross-repo blocked-by links** flow downward: L1 → L2 → L3 → L4 (the lower layer is the blocker)
2. **Within-repo blocked-by links** flow through the template: step 1 → step 2 → step 3
3. **No native "relates to":** GitHub has only blocked-by / blocking dependencies — for a soft shared-concern connection, use body backlinks (`fredabood/<repo>#<n>`), not dependencies
4. **No circular dependencies** — if found, decomposition is wrong
