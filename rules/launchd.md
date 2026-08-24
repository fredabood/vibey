---
description: When work belongs on launchd vs n8n vs Docker, and the ten plist conventions every launchd job must satisfy
globs:
  - "**/*"
---

# launchd — Placement Rule and Plist Conventions

n8n is the scheduler of record (LAB-162). **launchd is the exception layer, and the burden of
proof is on the exception.** Long form, with the failure evidence behind every line:
`docs/operations/launchd.md`.

## Placement decision procedure

Run in order on one unit of work. **Stop at the first question that decides.**

| # | Question | If it decides |
|---|---|---|
| **Q0** | Does it run as a process on the mini's host OS? If it runs in a container — or could — it belongs to n8n or the container's own supervisor. | **STOP — not a launchd candidate** |
| **Q1** | **Is the work still wanted?** Name a live consumer: a service that reads the output, a person who acts on it, a metric or heartbeat that would be missed. | No consumer → **RETIRE**, whatever the technical answers would have been. A tracked-but-uninstalled plist is *not* "pending deployment" by default. |
| **Q2** | **Can n8n structurally *not* run it?** Must hit ≥1: **(a)** host-native (SMB into `/Volumes`, `pfctl`, a host loopback port, a GUI-session process); **(b)** must run before Docker; **(c)** must survive Docker being down; **(d)** host metrics. | Hits none → **MOVE to n8n.** |
| **Q3** | **PATH gate.** Does it invoke anything outside `/usr/bin:/bin:/usr/sbin:/sbin`? (`docker`, `restic`, `uv`, `node`, `python`, `cloudflared`, `mc`, `tailscale`, all of `/opt/homebrew/bin` and `/usr/local/bin`.) | Yes → `EnvironmentVariables → PATH` is **mandatory**. Not disqualifying: a required amendment before KEEP. |
| **Q4** | **TCC gate.** Does it touch `/Volumes/Personal-Drive`? The question is not *whether* but **which executable performs the access**. bash builtin = OK. Platform binary (`/bin/ls`, a `>` redirect) = **silently denied**. Non-platform binary with a demonstrated working path (`restic`) = OK, **record the exact path**. Any other non-platform binary = **hangs forever** on a consent prompt launchd cannot display. | Row 4 → **disqualifying**. Default: **write locally**; restic and Time Machine carry `~/homelab-data/` to the NAS. |
| **Q5** | **Reader?** Name a metric, heartbeat, or human. "It writes a log" is not a reader. | Does not gate. A KEEP with no reader is **recorded as one**. |

**Verdict:** **KEEP** (name the Q2 reason(s) — "it has always been here" is not one) · **MOVE** to n8n ·
**RETIRE**.

> **Q2c has a dependency test that is easy to skip.** A job survives Docker being down only if
> its sources *and* its sinks are also outside Docker. `db-backup.sh` looks like a backup but
> reaches Postgres via `docker exec` and uploads to MinIO — Q2c does not apply.

## Plist conventions

Requirements, not preferences. Each traces to the failure it prevents.

1. **Label is `com.homelab.<job>`**, matching the filename and the log directory.
   *Prevents:* a job you cannot find from a log path, or grep for in `launchctl list`.
2. **`StandardOutPath`/`StandardErrorPath` set, under `~/homelab-data/logs/<job>/`.** No `/tmp`,
   no paths inside the repo tree. *Prevents:* the post-mortem evidence being wiped at boot, and
   job logs landing in `git status`.
3. **`ThrottleInterval` whenever `KeepAlive` is set.** *Prevents:* a crash-looping daemon
   respawning on an undeclared default nobody reviewed.
4. **Explicit `EnvironmentVariables → PATH` when invoking any non-system binary.** *Prevents:*
   `docker-cleanup`'s months of exiting 1 with a plausible, wrong "Docker daemon not running".
5. **No secrets in plists, and no ad-hoc `source <path>` in `ProgramArguments`** — env comes from
   a documented wrapper. *Prevents:* `vault-sync` inheriting `.env`'s `set -u` ordering bug, and
   credentials landing in a world-readable file git tracks.
6. **A job needing a NAS artifact writes locally; restic/Time Machine carry it.** Exception only
   for an executable path already demonstrated to work from launchd (`restic`). *Prevents:* the
   silent-EPERM and hang-forever halves of Q4 — `pg-dump`'s five dead months.
7. **`Program` is the script itself** (own shebang, mode 755), not `/bin/bash <script>`.
   *Prevents:* a future TCC grant scoping to the system shell instead of to the job.
8. **Paths absolute and mechanically validatable** — every `ProgramArguments[0]` and every log
   path must exist. *Prevents:* the `~/Repositories/homelab` class of failure that killed three
   jobs at once.
9. **The repo mirror is the source of truth, and `internal/launchd/` is its single home** — every
   `com.homelab.*` plist, regardless of subsystem; scripts stay with their subsystems. Conformance
   diffs installed against the **tip of `main`**, not the local checkout. *Prevents:* a checker
   that needs an exception list, and a hand-edited installed plist drifting unnoticed.
10. **Every KEEP declares its Q2 reason and its reader** in the inventory row. *Prevents:*
    re-litigating placement from scratch at the next audit.

## Operational reflexes

- Never `launchctl` anything from an agent session without an explicit instruction — installs and
  reloads are live mutations.
- Reload is **`bootout` → `cp` → `bootstrap`**, in that order; editing the installed plist in
  place changes nothing until the job is re-bootstrapped.
- `pgrep -f <pattern>` as a liveness probe **self-matches** and can never go false. Use
  `pgrep -x`, a pidfile, or `launchctl list`.
- A launchd job's only failure signal is a non-zero status in `launchctl list` plus a file on
  disk. Alert on **job failure semantics**, not blindly on non-zero: some jobs (`security-monitor`)
  define exit 1 as *findings*, and "never ran since load" (`-`) must stay distinguishable from
  exit 0.
