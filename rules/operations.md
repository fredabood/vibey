---
description: Behavioral rules for Docker/infrastructure operations — dry-run first, verify after, staging before production
globs:
  - "**/*"
---

# Operations — Infrastructure Behavioral Rules

When working with Docker stacks, Caddy, or any infrastructure component, follow these rules
automatically. These complement the conventions in `homelab-services.md` with enforceable behavior.

## Docker stack operations

**Before any `docker compose up` or config change:**
1. Run `docker compose ps` to check current running state
2. Run `docker compose -f stacks/<name>.yml --env-file .env config` to validate the compose file
3. Only proceed if config validates cleanly

**Always pass `--env-file .env`:**
```bash
docker compose -f stacks/<name>.yml --env-file .env up -d
```
Never omit `--env-file .env` — variables silently blank otherwise.

**After any `docker compose up` or restart:**
- Check logs: `docker logs <container> --tail 50`
- Confirm the container is running: `docker compose ps`
- Do not declare success until logs show no errors

## Caddy / reverse proxy changes

After any Caddyfile edit:
1. Validate config: `docker exec caddy caddy validate --config /etc/caddy/Caddyfile`
2. Reload: `docker exec caddy caddy reload --config /etc/caddy/Caddyfile`
3. Verify internal connectivity: `docker exec caddy wget -qO- http://<container>:<port>/`
4. Only declare success after the internal connectivity check passes

## Staging-first principle

> **Interim (LAB-1110/#1175, 2026-08-12):** staging routes + containers are retired until
> the Mac Studio re-establishes staging (#983). Until then, validate non-trivial changes
> with `compose config`, targeted single-service recreates, and health checks instead.

For any non-trivial production change:
1. Apply the change to the staging replica (`*-staging`) first
2. Verify the staging service works as expected
3. Then apply to production

Skip staging-first only for: emergency fixes, changes with no staging equivalent, or when the
user explicitly says to skip.

## Production safety

- Never run `docker rm`, `docker stop`, or `docker volume rm` on production containers without
  explicit confirmation from the user — the `docker-safety-check.sh` hook enforces this
- Never force-recreate a production container if you haven't verified the image builds cleanly first
- If a container fails to start after an update, check logs before attempting fixes — don't
  blindly retry

## NAS mount dependencies

The NAS at `/Volumes/Personal-Drive` is an SMB share that does NOT auto-mount after reboot.
Several stacks have bind mounts to NAS paths — these are **commented out by default** to prevent
containers from failing when the NAS isn't mounted.

**Before any `docker compose up` on a stack with NAS mounts:**
1. Check if NAS is mounted: `mount | grep Personal-Drive`
2. If not mounted and the stack needs NAS data: run `./internal/scripts/mount-unas.sh` first
3. Uncomment the NAS mount lines in the stack file before recreating
4. After container starts, verify NAS data is accessible inside: `docker exec <container> ls <mount-path>`

**Stacks with NAS mount dependencies:**
| Stack | Service | NAS path | Purpose |
|-------|---------|----------|---------|
| `nextcloud-stack.yml` | nextcloud, nextcloud-cron | `/Volumes/Personal-Drive/homelab/google-drive` | Google Drive mirror |
| `privacy-stack.yml` | calibre-web | `$CALIBRE_LIBRARY_PATH`, `$GUTENBERG_MIRROR_PATH` | Book library |
| `data-platform-stack.yml` | n8n | `/Volumes/Personal-Drive/homelab/google-drive` | NAS access for workflows |
| `wikipedia-stack.yml` | kiwix, eventstreams-daemon | `/Volumes/Personal-Drive/homelab/wikipedia` | Wikipedia data |

**CRITICAL: Never add NAS bind mounts while rclone is actively writing to the same NAS path.**
Docker Desktop crashes when containers have NAS SMB bind mounts during active writes (FUSE/gRPC
bridge overwhelmed). Sequence: finish rclone writes → mount NAS → add container mounts.

## One *bulk* NAS writer at a time (LAB-1407)

**The rule: at most one BULK writer to `/Volumes/Personal-Drive` at any moment.**

*Bulk* means a job that writes thousands of files, or gigabytes, in a burst: restic, an rclone sync,
an imagery pull, a Wikipedia mirror, an Immich thumbnail or metadata run. It does **not** mean any
write at all. A handful of phone uploads a day, or an SSE daemon appending a Parquet file every few
minutes, is low-rate and does not contend for the smbfs mount.

> **This restates the older wording, "one NAS writer at a time — serialize imagery/rclone/sync
> jobs", which was already false when written.** `eventstreams-daemon`
> (`stacks/wikipedia-stack.yml`) holds a **continuous `rw` bind** on
> `/Volumes/Personal-Drive/homelab/wikipedia` and has since LAB-72 — a permanent second writer
> living under a rule that forbade one. That matters beyond pedantry: a rule the fleet visibly
> violates is read as advisory, and an advisory rule stops being consulted before the next
> always-on writer is added. The narrower claim is the one that is actually true, so it is the one
> worth defending.

### The incidents this is derived from — not a principle, a pair of outages

| Date | What happened | What was actually concurrent |
|---|---|---|
| 2026-04 | Docker Desktop crash loop, FUSE/gRPC bridge overwhelmed | Container SMB bind mounts added **while rclone was bulk-writing the same path** |
| 2026-07-06 | The share wedged — mounted and dead at the same time (detection: #1406) | **Two containers writing concurrently** |

Neither incident implicates "two writers". Both implicate **two bulk writers on smbfs at once**.

### The 02:00–06:00 NAS write window and its occupants

| Writer | Schedule | NAS path | Where it is defined |
|---|---|---|---|
| **restic (primary repo)** | **daily 02:00** | `homelab/backups/restic` | `internal/launchd/com.homelab.backup.plist` |
| wikipedia-zim-sync | monthly 1st, 02:00 | `homelab/wikipedia` | n8n |
| db-backup | daily 02:30 | MinIO (local only — **not** a NAS writer) | n8n |
| **rclone gdrive-sync** | **daily 03:00, 12 h timeout** | `homelab/google-drive` | n8n |
| gutenberg-sync | weekly Sun 03:00 | `homelab/books` | n8n |
| restore-test (heavy *reader*) | weekly Sun 03:00 | restic repo | `internal/launchd/com.homelab.restore-test.plist` |
| wikidump-sync | monthly 5th, 04:00 | `homelab/wikipedia` | n8n |
| wikipedia-images-sync | monthly 10th, 06:00 | `homelab/wikipedia` | n8n |
| **eventstreams-daemon** | **continuous** | `homelab/wikipedia` | `stacks/wikipedia-stack.yml` — low-rate, the standing exception |
| Immich job queues | **paused 01:55–06:05** | `${IMMICH_MEDIA_PATH}` | `internal/n8n/workflows/immich-quiet-window.json` |
| ~~sentinel2-native / naip / usgs-3dep~~ | ~~02:15 / 03:00 / 04:00~~ | ~~`homelab/imagery`~~ | **RETIRED** in the LAB-1258 launchd audit (Q4 TCC disqualification); intent carried to `fredabood/9215resort#60`. Re-landing them means re-entering this table |

**02:00–03:00 is the busiest hour**, and `gdrive-sync` at 03:00 carries a **12-hour timeout**, so
that slot can still be live at mid-morning. Anything new that writes the NAS in bulk must be
scheduled against this table — "at night" is not a schedule.

### The worked example: Immich

Immich is the first *always-on* NAS writer the fleet has taken on, so it cannot be serialised by
picking a time slot — it has to be told when not to write. `immich-quiet-window` pauses its seven
job queues at 01:55 and resumes them at 06:05, with a 10:15 safety resume.

It pauses the **queues, not the container**, and that distinction is the whole design: the API stays
up, so the phone's background backup still succeeds during the window and derivatives are generated
after 06:05. Stopping the container would fail mobile backup silently for four hours every night.

No filesystem lock was added. `flock` is unreliable on smbfs, none of the existing writers takes
one, and retrofitting a locking protocol onto six scripts to protect one new consumer buys less than
a schedule does.

### What this is not

This is **not** a licence to add writers. The bulk/low-rate distinction narrows the rule to
something true; it does not widen what is permitted. Before adding anything that writes the NAS:

1. Say whether it is bulk or low-rate, and why — with a file count or a byte volume, not an adjective.
2. If bulk: name the slot in the table above that it takes, and what it is now adjacent to.
3. If continuous: it needs a quiet-window mechanism of its own, like Immich's. `eventstreams-daemon`
   is grandfathered because it is low-rate, not because continuous writers are fine.
4. Add the row to the table in the same change. A writer absent from this table is invisible to the
   next person scheduling work, which is exactly how 02:00–03:00 got crowded.

## Networking changes

- New services behind Caddy must bind to `0.0.0.0` (not `127.0.0.1`)
- Debug 502s with `docker exec caddy wget -qO- http://<svc>:<port>/` before changing config
- Docker network names: `homelab-frontend`, `homelab-backend`, `homelab-data`, `homelab-monitoring`
- Confirm a service is on the correct network before declaring a routing issue fixed

## Compose env-var strictness (LAB-965)

Every `${VAR}` reference in `stacks/*.yml` must carry an explicit posture:

- `${VAR:?VAR required}` — credentials, tokens, DSN components, webhook URLs, and
  environment-specific paths/hosts (`HOMELAB_DATA_PATH`, `HOMELAB_REPO_PATH`, …).
  Compose FAILS LOUDLY instead of silently interpolating an empty string.
- `${VAR:-<default>}` — genuinely optional vars with a safe default; use `${VAR:-}`
  + `# optional` comment for integrations that may be unset (e.g. DATABRICKS_*).
- Non-colon `${VAR?msg}` — rare: var must EXIST but may legitimately be empty
  (e.g. ANTHROPIC_API_KEY placeholder).

Verification pattern for any change: `docker compose -f <stack> --env-file .env config`
must exit 0 AND diff empty against the pre-change resolved config; a probe with
`--env-file /dev/null` must fail naming a required variable. Note: compose prints
"variable is not set" warnings from `.env`-internal interpolation even when resolution
succeeds — trust the resolved config, not warning absence.

**Every `:?`-required var must also exist in `.env.tpl`** (op:// ref or non-secret
literal). `inject-secrets.sh` regenerates `.env` wholesale with `--force`, so a var
present only in the live `.env` (or surviving only in a running container's env) is a
redeploy time bomb — LAB-1124 found `JIRA_GRAPH_WRITE_ALLOWED`/`JIRA_GRAPH_SERVICE_TOKEN`
this way. After adding a required var to a stack, add it to `.env.tpl` in the same change
and verify with a fresh inject + `compose config`.
