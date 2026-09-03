---
globs:
  - "**/*"
---

# Homelab Services Reference

Canonical reference for all deployed homelab services. Loaded in every session.
Source of truth for service names, URLs, and ports: `internal/caddy/Caddyfile` and `stacks/`.

---

## Service Catalog

### Production Services (in Caddyfile)

> **ALL app UIs are tailnet-gated (LAB-1110 complete, 2026-08-12):** every URL below follows
> the LAB-1008 pattern — DNS-only A → Tailscale IP, fleet HTTPS block on the tailnet-bound
> 443; subdomains canonical, Tailscale required. **CF Access retired** (wildcard allow-gate
> deleted); the ONLY live public route is `hooks.dirtydata.studio` (webhook ingress +
> `/health`; tunnel ingress narrowed to it, #1176). `api.*` + `health.*` decommissioned
> (#1168); ALL `staging-*` routes retired (#1175). code-server has an app password (M10).
> Access truth: `docs/operations/SERVICE_ACCESS.md`.

| Service | Container | External URL | Internal host:port | Purpose | Primary access pattern |
|---|---|---|---|---|---|
| Homepage | homepage | home.dirtydata.studio | homepage:3000 | Service dashboard | Web UI |
| Portainer | portainer | portainer.dirtydata.studio | portainer:9000 | Docker management | Web UI + REST API |
| Uptime Kuma | uptime-kuma | status.dirtydata.studio | uptime-kuma:3001 | Uptime monitoring | Web UI + REST API |
| ~~Open-WebUI~~ | ~~open-webui~~ | ~~chat.dirtydata.studio~~ | ~~open-webui:8080~~ | ~~Chat UI for Ollama~~ | DECOMMISSIONED 2026-08-21 (LAB-1399) — re-downloaded its embedding model on every boot and spiralled to 22.9 GB of orphaned `.incomplete` blobs; chat moved to Omnigent and Buzz. Container, volume, image, Caddy route and DNS record all removed |
| Ollama | ollama | ollama.dirtydata.studio | ollama:11434 | Local LLM inference | REST `/api/generate`, `/api/chat` |
| Code-Server | code-server | code.dirtydata.studio | code-server:8080 | Browser VSCode | Web UI |
| Grafana | grafana | grafana.dirtydata.studio | grafana:3000 | Metrics dashboards | Web UI; HTTP API `/api/` |
| MLflow | mlflow | mlflow.dirtydata.studio | mlflow:5000 | ML experiment tracking | REST API + web UI |
| n8n | n8n | n8n.dirtydata.studio | n8n:5678 | Workflow automation | REST `/api/v1/` + web UI |
| ~~Jellyfin~~ | ~~jellyfin~~ | ~~jellyfin.dirtydata.studio~~ | ~~jellyfin:8096~~ | ~~Media server~~ | DECOMMISSIONED 2026-04-05 — reactivate when mobile access resolved |
| ~~Sonarr~~ | ~~sonarr~~ | ~~sonarr.dirtydata.studio~~ | ~~sonarr:8989~~ | ~~TV show management~~ | DECOMMISSIONED 2026-04-05 — media stack paused |
| ~~Radarr~~ | ~~radarr~~ | ~~radarr.dirtydata.studio~~ | ~~radarr:7878~~ | ~~Movie management~~ | DECOMMISSIONED 2026-04-05 — media stack paused |
| ~~Prowlarr~~ | ~~prowlarr~~ | ~~prowlarr.dirtydata.studio~~ | ~~prowlarr:9696~~ | ~~Indexer management~~ | DECOMMISSIONED 2026-04-05 — media stack paused |
| Mealie | mealie | mealie.dirtydata.studio | mealie:9000 | Recipe manager | REST API |
| Twenty CRM | twenty-server | crm.dirtydata.studio | twenty-server:3000 | Self-hosted CRM | Web UI + REST API |
| Jira-Graph | jira-graph | jira.dirtydata.studio (**tailnet-gated**, LAB-1008 — DNS-only A → mini Tailscale IP, NOT the CF tunnel; caddy host 443 published only on the Tailscale IP; DNS-01 cert) | jira-graph:8090 | Issue & program visualizer (GitHub-backed) | FastAPI REST; mutations authorized by tailnet transport (Caddy attaches `X-Service-Token`, op://Homelab "Jira Graph Service Token") or `Tailscale-User-Login` ∈ `WRITE_ALLOWED` |
| ~~SearXNG~~ | ~~searxng~~ | ~~search.dirtydata.studio~~ | ~~searxng:8080~~ | ~~Private search~~ | DECOMMISSIONED 2026-04-05 |
| FreshRSS | freshrss | rss.dirtydata.studio | freshrss:80 | RSS reader | Web UI + Fever API |
| Calibre-Web | calibre-web | books.dirtydata.studio | calibre-web:8083 | Ebook library | Web UI |
| ~~Radicale~~ | ~~radicale~~ | ~~dav.dirtydata.studio~~ | ~~radicale:5232~~ | ~~CalDAV/CardDAV~~ | DECOMMISSIONED 2026-04-04 — CalDAV consolidated into Nextcloud |
| ~~Immich~~ | ~~immich-server~~ | ~~photos.dirtydata.studio~~ | ~~immich-server:2283~~ | ~~Photo management~~ | DECOMMISSIONED 2026-04-04 — reactivate when photo storage needed |
| Nextcloud | nextcloud | cloud.dirtydata.studio | nextcloud:80 | File storage | WebDAV + REST |
| Kiwix | kiwix | wiki.dirtydata.studio | kiwix:8080 | Self-hosted Wikipedia browser | Web UI |
| MCP Gateway | mcp-gateway | ~~mcp.dirtydata.studio~~ (public route DISABLED 2026-07-21, LAB-979 — tailnet-only at `${TAILSCALE_IP}:3100`; re-enable planned in #978 with CF Access service token) | mcp-gateway:3100 | Aggregated MCP server (16 tools / 7 tool groups) for Claude clients | Streamable HTTP `/mcp` |
| Omnigent | (native on mini, :6767 loopback) | omni.dirtydata.studio (**tailnet-gated**, LAB-1111 — DNS-only A → mini Tailscale IP; caddy 443-on-Tailscale-IP → host.docker.internal:6767) | 127.0.0.1:6767 (host) | Agent orchestrator (own login auth; #1015 blocker) | Web UI + REST `/v1/*`; CLI uses loopback |
| Vaultwarden | vaultwarden | vault.dirtydata.studio (**tailnet-gated**, LAB-1311 — fleet block, DNS-only A → mini Tailscale IP) | vaultwarden:80 | Human credential store (browser/mobile passwords, TOTP, passkeys). **1Password stays the machine-secrets backbone (D8) and is strictly upstream** — nothing here feeds `inject-secrets.sh` | Web UI + Bitwarden clients (enter the custom server URL **before** the email). **No host ports**; no auto-login header — the master password + TOTP is the authenticator, the tailnet is defence in depth. `/admin` disabled in steady state (a disabled panel answers **200**, not 404). State is SPLIT: `vaultwarden` pg DB **+** `homelab-data/vaultwarden/` — a restore needs BOTH. Runbook: `docs/operations/vaultwarden.md` |
| Buzz | buzz-relay | buzz.dirtydata.studio (**tailnet-gated**, LAB-1029 — fleet block, DNS-only A → mini Tailscale IP) | buzz-relay:3000 | Human+agent workspace relay (block/buzz Nostr, closed-relay mode; shared pg16 `buzz` DB + shared MinIO `buzz-media` + local `buzz-redis`) | WSS (Nostr) + REST; health `buzz-relay:8080/_liveness`, metrics `:9102`; desktop/mobile clients need Tailscale |
| Buzz Admin | buzz-relay (same process) | admin-buzz.dirtydata.studio (**tailnet-gated**, LAB-1212 — fleet block, DNS-only A → mini Tailscale IP) — **DISABLED BY DEFAULT** | buzz-relay:3000 | Read-only deployment admin dashboard (moderation reports + product feedback). `BUZZ_ADMIN_HOST` is empty in the stack ⇒ no admin router at all; set it in `.env` + recreate to enable for a session, then unset. DNS + Caddy route stay in place | Web UI (`/`, `/reports`, `/feedback`) + `GET /api/admin/v1/*`. **UNAUTHENTICATED, and a Host header is not an access control inside the fleet** — ~40 containers reach `buzz-relay:3000` directly and can forge it (verified from n8n), which is why it ships off. Deliberately NOT on the homepage (a tile to a disabled surface misleads). `curl -sI /` 404s; `/` needs `Accept: text/html`. Runbook: `submodules/memory/homelab/knowledge/buzz-runbook.md` |

### Infrastructure Services (internal only / not in production Caddyfile)

| Service | Container | External URL | Internal host:port | Purpose | Primary access pattern |
|---|---|---|---|---|---|
| Agent Runtime | agent-runtime | (internal only) | agent-runtime:8095 | Autonomous agent workflow engine | REST API `/api/workflow/*`, `/api/search/jira` |
| Prometheus | prometheus | (internal only) | prometheus:9090 | Metrics scraping | HTTP API `/api/v1/query` |
| Alertmanager | alertmanager | (internal only) | alertmanager:9093 | Alert routing | HTTP API |
| postgres-memory | postgres-memory | host: localhost:5432 | postgres-memory:5432 | Agent memory + GitHub issue mirror (`jira.*`) | asyncpg / psql |
| MinIO | minio | (staging only) | minio:9000 (S3), minio:9001 (console) | Object storage | AWS S3 API; bucket `jira-activity` |
| qBittorrent | qbittorrent | host: localhost:8081 | gluetun:8080 | Torrent client (VPN via gluetun) | Web API `/api/v2/` |
| Claude Remote | claude-remote | claude.ai/code (no direct port) | outbound HTTPS only | Claude Code Remote Control server | claude.ai/code + Claude mobile app |
| Earthdata Downloader | earthdata-downloader | (internal only) | sleep-idle, invoked via `docker exec` | NASA Earthdata bulk granule archive (RESORT-2, ex-LAB-221 — tracker in fredabood/9215resort) | `python -m earthdata_downloader download --daac <DAAC>` from n8n |
| NAIP Downloader | naip-downloader | (internal only) | sleep-idle, invoked via `docker exec` | NAIP aerial vintages for the 9215 AOI (RESORT-60) | `python -m naip pull-archive` from n8n, monthly |
| Sentinel-2 Downloader | sentinel2-downloader | (internal only) | sleep-idle, invoked via `docker exec` | Sentinel-2 L2A native-resolution scenes (RESORT-60) | `python -m sentinel2_native backfill --start --end` from n8n, daily |
| USGS 3DEP Downloader | usgs-3dep-downloader | (internal only) | sleep-idle, invoked via `docker exec` | 1 m 3DEP DEM tiles for the 9215 AOI (RESORT-60) | `python -m usgs_3dep pull-dem` from n8n, monthly |

### API Gateway (`api.dirtydata.studio`) — DECOMMISSIONED 2026-08-12 (LAB-1110/#1168, zero consumers)

| Path prefix | Strips prefix | Routes to |
|---|---|---|
| `/ollama/*` | yes | ollama:11434 |
| `/mlflow/*` | yes | mlflow:5000 |

The staging API gateway (`staging-api.dirtydata.studio`) additionally routes `/s3/*`.

---

## MCP Server Capabilities

| Server | What it can do | Key use cases |
|---|---|---|
| github | Create/update/close issues, add comments, sub-issues (parent issues), Projects v2 board status, search (github-mcp-server) | All issue ops — `fredabood/homelab` + `fredabood/dirtydata`; dependencies (blocked-by) via `gh api`, not MCP |
| obsidian | Read/write/search vault notes | Knowledge base at `submodules/memory/` |
| google-workspace | Gmail, Calendar, Contacts | Email, scheduling |
| postgres-cos | Read-only SQL on `agent_memory` DB | Query `jira.*` schema, inspect data |

---

## Data Store Schemas

### postgres-memory (`agent_memory` database)

**Custom image (LAB-218):** `homelab/postgres-memory:pg16` (built from `internal/postgres-memory/Dockerfile`)
**Base:** `timescale/timescaledb-ha:pg16` + `postgresql-16-age` (PGDG)
**Extensions on agent_memory:** postgis 3.6.2, timescaledb 2.26.1, vector 0.8.2 (pgvector), age 1.6.0, plpgsql
**PGDATA path:** `/home/postgres/pgdata/data` (NOT vanilla `/var/lib/postgresql/data` — image uses its own path)
**Active volume:** `homelab_postgres_memory_data_v2` (the original `homelab_postgres_memory_data` is preserved as a recovery snapshot from LAB-218)
**Connection ceiling (LAB-1300):** `max_connections = 200` (was 50 — the fleet's measured steady-state demand is **87**, so 50 was structurally oversubscribed and any simultaneous restart crash-looped whichever client reconnected last). Set via `ALTER SYSTEM` in `postgresql.auto.conf`, not `postgresql.conf`. `shared_buffers` 1 GB / `work_mem` 10 MB, deliberately unchanged (~5 MB per backend ⇒ ~2 GB at 200, inside the 4 GB container cap). **No connection metric or alert exists yet** — threshold when built is 160/200, tracked in LAB-1348. Per-database budget and diagnostics: the runbook's *Connection budget* section.
**ADR:** `submodules/memory/homelab/decisions/postgres-extension-stack.md`
**Runbook:** `submodules/memory/homelab/knowledge/postgres-memory-runbook.md`

- **`jira` schema:** `issues`, `issue_links`, `commit_links`, `sprints`, `status_transitions`, `sync_metadata`, `sync_drifts`, `activity_log`, `issue_changelog` — active, used by jira-graph. **Now mirrors GitHub Issues** (2026-07 migration): `gh_repo`/`gh_number` columns identify the GitHub issue; keys follow the unified scheme (LAB-963): `LAB-<n>` (homelab) / `DRTY-<n>` (dirtydata) / `RESORT-<n>` (9215resort) / `WORK-<n>` (work — **mirror-only**, LAB-1010: mirrored + rendered in jira-graph but never on the "Homelab Work" board; open work issues carry the `Backlog` fallback status) — `<n>` is the GitHub issue number for post-migration issues, migrated issues keep their original keys; resolve with `jira.gh_issue_key(repo, number)` (deprecated `HL-*`/`DD-*` ≡ `LAB-*`/`DRTY-*`). Read-only for agents — GitHub is the write side.
- **`google` schema:** `emails`, `calendar_events`, `sync_metadata` — Google Workspace sync data (LAB-199, migrated from SQLite 2026-04-04). Email bodies inline as TEXT, labels as TEXT[], attendees as JSONB.
- **`wikipedia` schema:** `embed_progress`, `image_metadata_progress` — Wikipedia RAG pipeline progress tracking (LAB-190, migrated from SQLite 2026-04-04)
- **`domains` schema:** `domains`, `dns_records`, `blockchain_records`, `validation_checks`, `routing`, `events`, `sync_metadata` — unified domain registry for LAB-164 (Domain Management System). Migrations: `internal/domain-manager/migrations/` (`001_domain_schema.sql`, `002_classification_taxonomy.sql`). Control plane: **`mcp-domain-manager`** MCP server (18 tools, port 3101 on Tailscale + `.mcp.json`; `internal/mcp-servers/domain-manager/`). Post-migration state (2026-07-14): all ~45 ICANN domains at **Porkbun**, DNS on **Cloudflare**, GoDaddy exited (LAB-178). Ops doc: `docs/operations/domain-management.md`.
- **`plane` schema:** (archived) mirror of jira schema from Plane CE experiment — 30-day retention then drop
- **`public` schema:** pgvector tables for embeddings (`wikipedia_embeddings` for RAG), `memories` — the semantic index of the Obsidian vault at `submodules/memory/`, **live-written every 15 minutes** by `internal/scripts/sync-memory-vault.py` under the `com.homelab.vault-sync` launchd job (LAB-1258 moves that job into the n8n `vault-sync` workflow; only one of the two may run) — `migration_key_map` (Jira↔Plane ID mapping), `plane_to_jira_key_map` (reverse migration mapping). `action_logs` was **dropped 2026-08-25** with the Memory Consolidation retirement (LAB-1514): 0 rows lifetime, 0 index scans, and that workflow was its only ever writer.
- **Connection (from host):** `postgresql://postgres@localhost:5432/agent_memory`
- **Connection (from container):** `postgresql://postgres@postgres-memory:5432/agent_memory`
- **MCP postgres-cos is read-only.** For writes: `docker exec postgres-memory psql -U postgres -d agent_memory`

### postgres-memory — All Databases (consolidated via LAB-145)

| Database | Owner | Size | Service | Purpose |
|----------|-------|------|---------|---------|
| `agent_memory` | postgres | ~221 MB | Jira Graph, MCP | GitHub mirror schemas (`jira.*`), pgvector embeddings. Open-WebUI's `public.document_chunk` was dropped with its decommission (LAB-1399); `public.knowledge_embeddings` belongs to `ingest-gdrive-to-pgvector.py` and stays; `public.memories` belongs to `sync-memory-vault.py` (`com.homelab.vault-sync`, every 15 min) and stays; `public.action_logs` was dropped 2026-08-25 with the Memory Consolidation retirement (LAB-1514) |
| `twenty_db` | twenty_user | ~16 MB | Twenty CRM | CRM application data |
| `n8n` | postgres | ~19 MB | n8n | Workflow automation backend |
| `freshrss_db` | freshrss | ~9 MB | FreshRSS | RSS feed data |
| `mealie` | postgres | ~11 MB | Mealie | Recipe management |
| `mlflow` | postgres | ~9 MB | MLflow | ML experiment tracking |
| `grafana` | postgres | ~13 MB | Grafana | Dashboard metadata, users, alerts |
| `homeassistant` | postgres | empty | Home Assistant | Empty — HA auto-creates schema on boot |
| `omnigent` | postgres | ~9 MB | omnigent (native on mini) | Sessions, transcripts, agent registry, usage ledger (LAB-1022; alembic-managed by omnigent, NOT a homelab migration dir) |
| `plane_db` | postgres | ~88 MB | (legacy) | Plane CE — archived, pending drop |
| `redmine_eval` | postgres | ~10 MB | (inactive) | PM evaluation stack |

### MinIO (S3-compatible)

- **S3 API:** `minio:9000` (internal) — AWS S3 SDK compatible
- **Console:** `minio:9001` (internal)
- **Known buckets:** `jira-activity` (legacy n8n sync payloads)
- **Client:** use `mc` (MinIO client) inside containers, or AWS SDK with `endpoint_url=http://minio:9000`

### n8n

- **Database:** PostgreSQL backend on `postgres-memory` (migrated from SQLite 2026-04-03)
- **REST API:** `n8n:5678/api/v1/` — use for reading/writing workflows
- **Custom image:** `homelab/n8n-puppeteer:${N8N_VERSION}` — includes Python 3.12+pip, psycopg2-binary, caldav, pyarrow, mwparserfromhell, rclone, rsync, docker-cli, mc, chromium, puppeteer-core, openssh-client, sqlite CLI. Google sync writes to `google` schema, Wikipedia pipeline writes to `wikipedia` schema.
- **Scheduling role:** Single orchestration plane for all scheduled jobs (LAB-162). Only macOS-native jobs (NAS mount, Cloudflare tunnel) and host-filesystem jobs (restic backup) stay on launchd. See `docs/operations/n8n-scheduling.md`.
- **Docker access:** Docker CLI via socket proxy (`DOCKER_HOST=tcp://docker-socket-proxy:2375`)
- **Activation ownership (LAB-1476):** **content** is declared by `internal/n8n/workflows/*.json` and pushed repo→runtime at DEPLOY time by `PUT /api/v1/workflows/{id}` (the `n8n-sync` action, #1420). **There is no boot import** — it was removed in #1580 because no export value can survive it with activation intact: measured, `active` omitted makes the import FAIL (NOT NULL), `false` writes `f`, and `true` also writes `f`. Boot asserts nothing at all; **activation** is declared by `internal/n8n/activation.txt` (`active`/`off` + mandatory reason) and applied out-of-band by `internal/scripts/n8n-apply-activation.sh` via `POST /api/v1/workflows/{id}/activate`. The 29-entry `update:workflow --active=true` chain is gone too. Exports must carry a stable top-level `"id"` and must NOT carry `"active"` (both CI-gated). Those invariants pre-date the import's removal and still hold: an id-less export used to mint a duplicate row per boot (#1513), and an `"active": true` export was force-*deactivated* on every boot — the 133-day Health Monitor outage. `PUT /workflows/{id}` rejects `active` (400, readOnly); the CLI and direct SQL write a flag the running process never sees. Divergence is reported by `internal/scripts/check-n8n-activation-parity.sh`, never auto-repaired. Superseded: the holistic audit §7.2b claim that the runtime reverts external edits
- **Known workflow IDs:** `n8n-activation-parity` (LAB-1476; daily 07:00, runs the read-only parity checker and fails its own execution on divergence — Buzz notification hop is #1541, blocked by #1437; no chat node other than the shared `Buzz Notify` sub-workflow is permitted), `homelab-deploy` (LAB-1372; **deploy on green `main`** — webhook-only, `POST /webhook/homelab-deploy`, HMAC-SHA256 over the raw body via `DEPLOY_WEBHOOK_SECRET` with a 600s replay window, 401 on a refused signature. Triggered by `.github/workflows/deploy.yml` once all four required checks are green; runs `internal/scripts/deploy-on-green.sh`, which pulls the deploy mirror and recreates **only** the stacks `affected-stacks.sh` maps. Refuses `data-platform` (defines the n8n container running the deploy) and `jira-graph` (needs a build; the socket proxy denies `/build`). Since LAB-1424 it also runs `git submodule update --init` for exactly the gitlinks a merge moved, so a `.claude` bump reaches the mirror without a manual step; a failure there stops the deploy rather than reporting success on a stale mirror), `github-webhook-receiver` (real-time GitHub CDC — `POST /webhook/github-event`, HMAC-verified; repo policy from `jira.mirror_repos` (LAB-1103, the one operator-writable `jira.*` table); mirrors issue/comment/board events into `jira.*`, auto-registers unseen `fredabood` repos as mirror-only, and auto-adds new issues to the board at `Status=Backlog` for `on_board=true` repos), `github-full-sync` (hourly reconciliation + manual `POST /webhook/github-full-sync`; sweeps every `mirror=true` repo + auto-discovers new `fredabood` repos), `github-weekly-export` (Sun 3AM + manual `POST /webhook/github-weekly-export`), Wikipedia mirrors `wikipedia-zim-sync` (monthly 1st 2AM), `wikidump-sync` (monthly 5th 4AM), `wikipedia-images-sync` (monthly 10th 6AM, self-chaining tranches), `wikipedia-embeddings-sync` (webhook-only, self-chaining 1K tranches via Ollama), `earthdata-download-date` ID `1ttQHbNvhrlJHT4h` (RESORT-2, ex-LAB-221; webhook-triggered, accepts `{"date":"YYYY-MM-DD"}` body, downloads all imagery for that date across all collections — `POST /webhook/earthdata-download-date`), `imagery-sentinel2-daily` ID `HR5EJue882S0HUTH` (RESORT-60; daily 06:30, `docker exec sentinel2-downloader python -m sentinel2_native backfill` over the trailing 10 days — two revisits of overlap, so one failed run cannot open a permanent hole), `imagery-naip-monthly` ID `IHVSZC6QobkkHjNw` (RESORT-60; monthly 1st 06:45) and `imagery-3dep-monthly` ID `vB6EI2f5BCV5uvrx` (RESORT-60; monthly 1st 07:15) — the latter two expect to download **nothing** almost every run (NAIP publishes this AOI every 2 years, 3DEP LiDAR arrives years apart) and exist so a new vintage is noticed rather than stumbled on. All three replace launchd plists that were tracked but never installed and **could not have worked**: a venv python writing `/Volumes` under launchd hits TCC's hang-forever consent prompt. n8n cannot run them directly either — its own imagery bind is read-only by design — so each drives a container holding the `rw` bind, exactly like `earthdata-download-date`. Each asserts the RESORT-63 NAS sentinel **before** invoking its downloader, because the `/nas` bind resolves to an auto-created empty directory when the share is absent, and an unguarded unattended run would "succeed" into container-local storage. Only failures notify; a scheduled "nothing to do" message is how the launchd versions lost their credibility. `Domain Registry Sync` ID `nPuYlMXr4BSKumkt` (LAB-170; daily 3AM, syncs porkbun/cloudflare into `domains.*` via mcp-domain-manager, Buzz alert on failure only), `Domain Monitoring Digest` ID `1Si24nP1pOgDHhy7` (LAB-172; weekly Mon 9am ET, validate_all + expiry tiers + drift → Buzz `#digest` when actionable), `omnigent-usage-sync` (LAB-1021; nightly 2:30AM + manual `POST /webhook/omnigent-usage-sync`; login-per-run → `GET /v1/usage` → per-session/per-model upserts into `tooling.omnigent_session_usage` (agent_memory) with notional/real/unpriced/local cost labeling; Buzz alert on failure only; Grafana dashboard `omnigent-usage`). `Twenty CRM Backup` ID `X5S10yiL6ezul6dq` and `Twenty CRM Backup Freshness` ID `hVSG4ZPMKWm8JYG1` (LAB-1534; daily 03:30 and 09:00). The backup replaced the busybox `crond` **inside** the `twenty-backup` sidecar, which was the only reason that container ran as root — crond loads a crontab only as uid 0, and LAB-1391 measured four non-root configurations that all parsed nothing and never fired. The container now idles on `sleep infinity` as `USER app` and is driven by a **detached** `docker exec`, with markers written to `/proc/1/fd/1` and read back via `docker logs`, because an attached exec cannot cross the socket proxy (the same constraint `vault-sync` works around). The freshness workflow is deliberately separate: it asserts the newest object under `twenty-backups/postgres/` is under 26h old, so a backup that silently stops firing is loud — an assertion living inside the runner could not fire when the runner does not. Also `BAtJo3Ps5plvrZ9T` — **Homelab Health Monitor** (every 15 min; silent 2026-04-04 → 2026-08-22 because the boot chain's "protection" named its `meta.n8nId` `J5jtDHh7RO4Sbh9v`, which was never a workflow; that id is retired). **Deliberately off:** the list is `grep '^off ' internal/n8n/activation.txt` — one line per decision, with date and reason — not a copy kept here or in the stack. `off` means "do not revive"; an undeclared workflow that merely happens to be inactive asserts nothing. Context: "Deliberately Off" in `docs/operations/n8n-scheduling.md`

---

## Docker / Infrastructure Conventions

### Stack files

- All stacks are in `stacks/` — always run with `--env-file .env` (vars silently blank otherwise):
  ```bash
  docker compose -f stacks/<name>.yml --env-file .env up -d
  ```
- Stack files by category:
  - `core-stack.yml` — MinIO, core services
  - `llm-stack.yml` — Ollama (Open-WebUI decommissioned 2026-08-21, LAB-1399)
  - `monitoring-stack.yml` — Prometheus, Alertmanager, Grafana, Loki
  - `memory-stack.yml` — postgres-memory
  - `data-platform-stack.yml` — MLflow, n8n, qBittorrent (via gluetun), and the imagery downloader sidecars: earthdata-downloader, naip-downloader, sentinel2-downloader, usgs-3dep-downloader (all sleep-idle, driven by `docker exec` from n8n)
  - `media-stack.yml` — Jellyfin, Sonarr, Radarr, Prowlarr, Mealie
  - `crm-stack.yml` — Twenty CRM
  - `jira-graph-stack.yml` — jira-graph (dependency visualization, reads from jira.* schema)
  - `smarthome-stack.yml` — (decommissioned 2026-04-03, LAB-119 Won't Do)
  - `privacy-stack.yml` — SearXNG, FreshRSS, Calibre-Web, Radicale
  - `immich-stack.yml` — Immich
  - `nextcloud-stack.yml` — Nextcloud
  - `dev-tools-stack.yml` — Code-Server
  - `claude-remote-stack.yml` — Claude Code web terminal (Tailscale-only)
  - `mcp-stack.yml` — MCP servers
  - `security-stack.yml` — Vaultwarden (human credential store, tailnet-only, no host ports)
  - `staging-stack.yml` — all staging replicas

### Restart vs rebuild

- `docker restart <container>` — soft restart, same image, picks up env var changes
- `docker compose -f stacks/<name>.yml --env-file .env up --force-recreate <service>` — picks up rebuilt image

### Networking

- Services behind Caddy **must bind to `0.0.0.0`** (not 127.0.0.1)
- Debug 502s: `docker exec caddy wget -qO- http://<container>:<port>/` to verify internal connectivity
- Docker network names: `homelab-frontend`, `homelab-backend`, `homelab-data`, `homelab-monitoring`
- Container name == service name in Caddyfile (e.g. `n8n` container ↔ `n8n:5678` in Caddyfile)

### Staging mirrors

Every production service has a staging mirror at `staging-<name>.dirtydata.studio` with basicauth.
Staging containers are named `<service>-staging` (e.g. `n8n-staging`, `ollama-staging`).

### Safety

- `.claude/hooks/docker-safety-check.sh` intercepts the destructive verbs — `stop`, `rm`,
  `rmi`, `kill` — on named production targets, in **either** spelling: `docker rm n8n` and
  the management-command form `docker container|image|volume|network rm n8n`. Global flags
  no longer hide the verb, so `docker --context prod rm n8n` is gated too (LAB-1530; every
  one of those but the first used to be allowed, `docker volume rm` included).
- **Not gated, by design:** `prune` (`docker image|volume|system|network prune`) and
  `docker compose down -v`. They destroy an unnamed *set*, so the gate's "no named target
  → allow" rule passes them; refusing them needs a second verdict path, which is tracked
  rather than half-built. Treat them as unguarded.
- Never use `docker rm` on production containers without explicit confirmation
- Staging containers are exempt — matched by **suffix or tag** (`n8n-staging`,
  `foo:staging`), not by substring, so `my-staging-thing-prod` is still refused
