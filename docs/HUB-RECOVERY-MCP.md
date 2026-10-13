# Hub recovery MCP tools — contract (BH-1942 / BH-1909.0)

Five MCP tools let an operator's agent see and act on hub recovery. They are
backed by database state the jobs worker already holds: the hub lease
(`hub_lease`), the backup stamps each box reports (`box_status.backup_*`) and
the restore-lab queue (`restore_lab_runs`). They never SSH to a box.

Each tool is a thin call to one jobs-worker route. The routes are contract
stubs as of BH-1942: every one answers `501 {"error":"not_implemented","ticket":"BH-1909"}`
until #1943 (promote, recovery read) and #1944 (restore lab) implement them.
The request and response shapes are pinned in the header comments of
`worker/jobs/src/routes/hub-recovery.js` and `worker/jobs/src/routes/restore-lab.js`.

## Tools

### backups
Read. Returns `.backups` of `GET /api/hub/recovery`: one entry per box,
`{box, backup_ts, backup_off, backup_unconfigured, backup_reported_at}`.

### restore_lab
Write and read. Requesting a run is `POST /api/hub/restore-lab`
`{box, snapshot='latest', actor, confirm}` → `201 {id, status:"requested"}`, or
`409 {error:"already_open", id}` when that box+snapshot already has an open run.
The run history is `GET /api/hub/restore-lab` → `{runs, truncated}`, newest first.

### hub_role
Read. Returns `.role` of `GET /api/hub/recovery`: `{active, standby}`.

### promote_hub
Write. `POST /api/hub/promote` `{target, expected_epoch, actor, reason, confirm,
override_live_lease}` → `200 {ok:true, before, after, override_live_lease,
stop_old_hub}`; otherwise `403 promote-disabled`, `400 confirm_required`,
`400 unknown_box`, `409 stale_epoch` or `409 lease_live`.

**Stop the old hub first (BH-2198).** Before promoting, stop the old hub (stop
its cron, or power it off) or cut its lane gate. The epoch bump only fences a
hub that can still hear the worker: `bin/hub-lease.sh` fails OPEN on the
configured hub while the worker is unreachable (BH-1000), so an old hub that is
alive but cut off keeps running its lanes after the promote, and the fleet has
two hubs. The worker enforces what it can:

- The route is off until the `hub.promote_enabled` settings row is `1`. It is
  seeded `0`; while off every call is `403 promote-disabled` and audited.
- A lease that has not expired is refused with `409 lease_live` and nothing is
  written. `override_live_lease: true` (the JSON literal) promotes anyway, for
  the case where you have already stopped the old hub; that promote is audited
  with outcome `ok:override_live_lease`.
- A stale `expected_epoch` is still `409 stale_epoch`, audited, override or not.
- Every 200 carries `stop_old_hub`, the command to run on the old holder now:
  an expired lease can be exactly the isolated, still-running hub.

The actor is set by the console proxy (`'console'`, overwriting any client
value, #2204); the route rejects a call with no actor.

### hub.epoch
Read. Returns `.lease` of `GET /api/hub/recovery`:
`{holder, epoch, expires_at, updated_at, live}` or `null`. `promote_hub` needs
this epoch as its `expected_epoch`.

## Confirm-first

This is the contract the tools and the worker routes are built to; neither is
implemented yet. The two write tools (`restore_lab` request, `promote_hub`) are
confirm-first.
Called without `confirm: true`, a tool returns a preview of what it would do and
makes **zero worker calls**. Called with it, the tool sends `confirm: true`, and
the worker checks again on its own side: anything but the JSON literal `true`
(`"true"`, `1`, a missing field) is refused with `400 confirm_required`. Every
refusal is written to `hub_lease_changes` as a `promote_refused` or
`restore_lab_refused` row, so a refused promote is on the record too.

## Fake-worker acceptance

The tools are accepted against a fake worker, not the real one:

- The read tools (`backups`, `hub_role`, `hub.epoch`, `restore_lab` history)
  return exactly the fake worker's data.
- A write tool called without confirm makes 0 fetches.
- A write tool called with confirm sends `confirm: true` in its body.
- A 501, 503 or 409 from the worker is surfaced verbatim and never read as success.

## Human step

The tool code lives in the private `example-org/cromford-console` repo, which
answers 404 from the boxes, so no build lane can implement it. the operator implements
the five tools from his own checkout against this contract.
