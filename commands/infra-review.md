Run a periodic infrastructure review. This is invoked by a scheduled trigger — not interactively.

Act as the infra-reviewer agent (see `.claude/agents/infra-reviewer.md` for full playbook).

## Step 1: Gather data (run all in parallel)

1. **Prometheus firing alerts:**
   ```bash
   curl -s http://localhost:9090/api/v1/alerts
   ```
   Read Prometheus directly, not Alertmanager: Alertmanager routes `severity: warning`
   to a `null` receiver by design (LAB-1297), so its API would hide exactly the
   lower-severity findings this review exists to catch. Only `severity: critical`
   reaches Buzz `#alerts`; everything else is yours to triage here.

2. **Container health:**
   ```bash
   docker ps -a --filter status=exited --format '{{.Names}}\t{{.Status}}'
   docker ps -a --filter status=restarting --format '{{.Names}}\t{{.Status}}'
   docker ps --filter health=unhealthy --format '{{.Names}}\t{{.Status}}'
   ```

3. **NAS mount status:**
   ```bash
   mount | grep Personal-Drive; cat ~/homelab-data/prometheus/textfile/nas_mount.prom
   ```

4. **Loki error logs (last 30 min):**
   ```bash
   curl -s 'http://localhost:3100/loki/api/v1/query_range' \
     --data-urlencode 'query={job="containers"} |~ "(?i)(error|fatal|panic|killed|oom)"' \
     --data-urlencode "start=$(date -v-30M +%s)000000000" \
     --data-urlencode "end=$(date +%s)000000000" \
     --data-urlencode 'limit=50'
   ```

5. **Disk pressure — HOST, not the Docker VM:**
   ```bash
   # LAB-1297: node_filesystem_* describes the Docker VM, NOT the Mac.
   # node-exporter runs inside the VM, and its /host_mnt/* virtiofs mounts report
   # a meaningless ~11,586 GB available. This check used that series and so never
   # saw the volume fill to 99% three times. Use the host-side collector instead.
   curl -s 'http://localhost:9090/api/v1/query?query=host_disk_avail_bytes' 
   curl -s 'http://localhost:9090/api/v1/query?query=host_apfs_local_snapshots'
   ```
   **Interpreting free space:** if `host_disk_avail_bytes` is low, check
   `host_apfs_local_snapshots` BEFORE concluding anything is leaking. Hourly Time
   Machine local snapshots pin deleted blocks, so free space can fall by tens of GB
   overnight with nothing wrong. Thinning them is the remedy, not a cleanup:
   `tmutil thinlocalsnapshots / 60000000000 4`. See
   `docs/operations/STORAGE_ARCHITECTURE.md` §6.

   Two more host-side signals from the same collector:
   ```bash
   # Scanner scratch — expect 0 at rest; non-zero means the LAB-1293 teardown regressed
   curl -s 'http://localhost:9090/api/v1/query?query=host_scanner_scratch_bytes'
   # launchd job failures — a job's ONLY failure signal is this exit status
   curl -s 'http://localhost:9090/api/v1/query?query=homelab_launchd_last_exit_code>0'
   ```
   A non-zero `homelab_launchd_last_exit_code{unit="..."}` is a real finding: the backup
   chain, pg-dump, vault-sync and the vulnerability scan all run here, and a failure is
   otherwise invisible. Note the label is `unit`, not `job` — Prometheus reserves `job`
   for the scrape target.

6. **Omnigent (native on the mini — LAB-1021):**
   ```bash
   curl -s -m 5 http://localhost:6767/health          # expect {"status":"ok"}
   omnigent host status 2>/dev/null | head -3          # expect process=online host=online
   ls ~/.omnigent/crashes/ 2>/dev/null | wc -l         # >0 = crash dumps to review (P3)
   ```
   Non-empty `~/.omnigent/crashes/` is a real signal (each file is a crash dump) —
   review the newest file's header before ticketing; clear handled dumps manually.

## Step 2: Analyze

Follow the analysis framework in the infra-reviewer agent definition:
- Separate real problems from noise
- Correlate related alerts to a single root cause
- Assess severity (P1–P4)
- Determine recommended fix

## Step 3: Act on findings

### If all clear:
- Do nothing. No Buzz message. No GitHub issue. Silent success.

### If real issues found (P1–P3):

For each distinct root cause:

1. Search Jira for an existing ticket: `project = LAB AND status != Done AND summary ~ "<keywords>"`
2. If found: add a status update comment
3. If not found: create a new ticket with:
   - Root cause analysis in the description
   - Acceptance criteria for the fix
   - Labels: appropriate work pattern + infrastructure layer
   - Priority: P1=Highest, P2=High, P3=Medium

4. If P1 or P2: Post ONE Buzz summary message with issue links and recommended immediate action

## Step 4: Log the review

Post a brief comment on the most recent active infrastructure ticket (or create a lightweight "Infra Review Log" ticket if none exists) noting:
- Timestamp
- What was checked
- Findings (or "all clear")
- Any tickets created/updated
