# Restore lab (routes + hub lane)

**What it is:** an on-demand dry-run restore of one box's off-box state backup,
into a throwaway `/tmp` scratch dir on the hub. It answers "does this box's
backup pull, verify and extract right now?" without touching the live tree or
buying a computer (the weekly restore drill does that). The console or the MCP
asks for a run; the hub's `bin/restore-lab.sh` claims it within 5 minutes,
runs `bin/state-restore.sh` without `--apply`, and posts `ok` or `fail` back.

**How a user reaches it:** no screen in this slice. The `/hub` restore-lab
panel is #1946's and reads `GET /api/hub/restore-lab`. Today it is the worker
routes and the lane's log, `/root/harness/logs/restore-lab.log`.

**Key routes/screens** (worker, all behind the `HARNESS_SECRET` bearer):
- `POST /api/hub/restore-lab` body `{box, snapshot='latest', actor, confirm:true}`.
  - `201 {id, status:"requested", run, deduped:false}` when a run is created.
  - `200 {…, deduped:true}` with the open run's id when the same box+snapshot is
    already requested or claimed.
  - `400 {error:"confirm_required"}` unless `confirm` is the JSON literal `true`
    (writes one `restore_lab_refused` row to `hub_lease_changes`).
  - `400` for a box not `[A-Za-z0-9._-]{1,64}` or a snapshot not `latest` /
    `YYYYMMDDTHHMMSSZ`; `409 {error:"unknown_box"}` for a box with no `box_status` row.
  - `box` is the fleet box NAME (`box-project-3-2`); the lane maps it to the
    bucket prefix (`project-3`) with `cron_box_id_for`.
- `GET /api/hub/restore-lab` → `200 {runs:[last 20, newest first], truncated, as_of}`.
- `POST /api/hub/restore-lab/claim` body `{claimer}` → `200 {run}` (the oldest
  `requested` run, or a `claimed` one older than settings row
  `restore_lab_claim_ttl_s`, fallback 1800 s) or `200 {run:null}`.
- `POST /api/hub/restore-lab/:id/result` body `{claimer, ok, detail, sha256, snapshot_ts}`.
  - `ok` must be `true` or `false`; `ok:true` needs a 64-hex `sha256` and a
    `snapshot_ts`.
  - `200 {ok:true, run}`, or `409 {error:"not_claimed_by_you"}` unless the row is
    `claimed` by that claimer.

**The lane** (`bin/restore-lab.sh`, hub cron `*/5`, behind `hub-lease.sh check`):
- Off: `bin/harness-ctl.sh off restore-lab` (`flags/lane-off-restore-lab`).
- Knobs: `RESTORE_LAB_TIMEOUT_S` (1500) and `RESTORE_LAB_TMPDIR` (default `/tmp`).
- Verdict `ok` only on:
  - rc 0;
  - a `pulled <prefix>/<ts>.tar.zst` line;
  - `sha256 ok <hex>`;
  - a non-empty extracted tree.
- Exit codes: 0 recorded or nothing to do; 1 the result POST failed (one ALERTS
  line; the run is re-offered after the TTL); 2 the scratch dir would resolve
  inside `/root/harness` (one ALERTS line, nothing claimed).

**Selectors:** none (no screen).

**Preconditions / seed needs:**
- The box needs a `box_status` row.
- A real restore needs `BACKUP_S3_*` in the hub's `global.env`. Without it,
  state-restore answers `not configured` and the run is recorded `fail` with
  that line.

**Verify it works:**
- `curl -s -H "Authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/hub/restore-lab" | jq '.runs|length, .truncated'`
  answers 200.
- `curl -s -X POST -H "Authorization: Bearer $HARNESS_SECRET" -H 'content-type: application/json' -d '{"box":"hub"}' "$JOBS_URL/api/hub/restore-lab"`
  answers `400 {"error":"confirm_required"}`. That writes one audit row and no run.
- Lane by hand on the hub: `bin/restore-lab.sh; echo $?`. It exits 0 and writes
  nothing when no run is requested.

**Manual-only / not automatable:** never drive a CONFIRMED `POST
/api/hub/restore-lab` against production from QA. It queues a real pull of a
real box's backup from the bucket (metered egress) on the next hub tick.
