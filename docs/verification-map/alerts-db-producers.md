# Alerts table, producer side (the row decides, the files follow)

**What it is:** with `flags/alerts-db` present on a box, the alert state machine
stops deciding from a per-box json and asks the `alerts` table instead. Four
producers are wired (BH-1070, the box half of BH-1030): `bin/lib/alert-state.sh`
(`alert_state_note` / `alert_state_resolve`), `bin/beat.sh` (project passthrough
+ the quarantine marking its row), `bin/lane-alert.sh` (project passthrough),
`bin/alert-flush.sh` (the worker's expired claims as a second input) and
`bin/alert-digest.sh` (reader). Every local file today's readers read is still
written — `state/alerts/<id>.json`, `state/alert-quarantine.jsonl` — as a
write-through cache, never as the primary. A fifth producer this ticket
originally scoped, `bin/fleet-heartbeat.sh`, was dropped on rebase: BH-1031
deleted the file, replacing its box-reachability ssh probe with the DB-driven
lane-liveness table (`tests/lane-liveness-single-fact-test.sh`).

**With the flag absent nothing above happens at all:** no `/api/alerts*` request
is made by any of the four, and each behaves as it did before this slice. The
gate is `alerts_db_on()` (BH-1068), which also requires `ALERTS_DB_ENABLED` not
to be `0` and the jobs client to be loadable.

**Fail-open, per rc:** rc 1 (worker unreachable) and rc 2 (route absent / no row)
both fall through to today's file logic and log `db-miss id=… rc=…`; rc 9 (a
sibling box won the compare-and-swap) is a `fire`, logged `db-race`; an answer
that is not `<fire|remind|suppress> <int>` is `rc=parse` and takes the file path.
The note request is made OUTSIDE the per-id flock — the worker's CAS is the
serialisation point, and a lock held across a network call would make every
same-id sibling time out into a duplicate page.

**Write-vs-send ordering (the two places it matters):**
- quarantine: file append → `alert_state_set … quarantined` → stamp
  `"dbrow":true` on the queued line, and only on rc 0. An unmarked row is never
  stamped, because that stamp is what makes `alert-flush.sh` skip the entry.
- flush: POST to the console → 2xx → `alert_state_set <id> new flush`. A non-2xx
  leaves the claim to expire and be re-offered; nothing is ever recorded as
  delivered because an HTTP call returned.
- re-mark (BH-2366): after its TTL pass `alert-flush.sh` retries
  `alert_state_set <id> quarantined flush` for each kept entry with no
  `"dbrow":true` (retractions excluded) and stamps it only on rc 0, with the same
  network-outside-lock, rewrite-under-flock order as beat.sh. rc 1 ends the pass
  for the run; rc 2/9 leave the entry on the dead-man path. One
  `flush remark: N stamped, M left unmarked (last rc=R)` line goes to
  `logs/alerts-state.log`; it counts only lines actually rewritten. With the
  flush claim ok, an overdue retraction (`"resolved":true`) is dropped from the
  queue instead of being sent raw as `[UNTRIAGED 45m]`: its row is already
  closed, and the hub no longer grabs it to settle it. Driven by
  `tests/alert-triage-no-ssh.bh-2314-test.sh` r1-r8.

**How an operator reaches it:** no UI. `flags/alerts-db` is the switch (console
flip → row → `flag_active alerts-db` in `bin/poll-commands.sh`'s flags-beats
block → the file). The observable surfaces are `logs/ALERTS.log` (unchanged
shape, one line per condition), `logs/alerts-state.log` (`fire` / `remind` /
`still firing` / `db-miss` / `db-race` / `quarantine-mark`),
`state/alert-quarantine.jsonl` (entries stamped `"dbrow":true` once their row is
marked), `state/alerts/<id>.json` and the console beat payloads.

**Primary lanes / scripts:**
- `bin/lib/alert-state.sh` — `alert_state_note <id> <sev> [line] [project]`,
  `alert_state_resolve <id>`, `_as_db_write_file`.
- `bin/beat.sh` — the chokepoint every emitter passes through (`cron` via its
  callers); the quarantine block marks the row.
- `bin/lane-alert.sh` — the writer side for detached orchestrator lanes.
- `bin/alert-flush.sh` — `cron/box.cron`, `*/15`; the dead-man valve.
- `bin/alert-digest.sh` — hub cron, daily; parked rows.
- `bin/poll-commands.sh` — `# >>> flags beats` reconciles `alerts-db`;
  `# >>> alerts re-beat` keeps running with the flag on.

**How to drive it:**
- `HARNESS_TEST_SANDBOX=1 bash tests/alerts-table-test.sh` — c0 flag-absent
  (zero `/api/alerts` requests across all four scripts, plus the four
  neighbouring suites run as subprocesses), c1 two boxes/one condition, c2
  remind, c3 resolve `1` vs `0`, c4 outage + 409, c5 the ALERTS.log append is
  neither removed nor duplicated, c6 the quarantine mark (and the worker-down
  half), c8 the re-beat block, c9 the digest's parked rows / `500+` /
  medic-parked fallback, c10 the flag reconcile, c11 write-through + no
  undeclared request shape. (c7 tested `bin/fleet-heartbeat.sh`; removed
  2026-09-22 when BH-1031 deleted the file — see the producer count above.)
- `HARNESS_TEST_SANDBOX=1 bash tests/alert-flush-ttl-test.sh` — c1 claim →
  escalate → mark new, c2 empty claim, c3 console 500 leaves the claim, c4
  `dbrow` entries dropped without a send, c5 flag absent, c6 failed claim puts
  every entry back on the file path.

**Preconditions / seed needs:** the worker's `/api/alerts*` routes (BH-1068's
sibling deploy) and `flags/alerts-db` on the box. Until the routes exist the
client answers rc 2 and every script above takes today's path, which is exactly
the state the fleet is in as this lands.

**Verify it works:** both suites report `0 failed`
(`alerts-table: 49 passed, 0 failed`, `alert-flush-ttl: 21 passed, 0 failed`, run
2026-09-22 after the fleet-heartbeat.sh removal). On a live box with the flag on:
`grep -E 'db-miss|db-race|quarantine-mark' /root/harness/logs/alerts-state.log`
shows the fallback path being taken (or nothing, if the worker is healthy), and
`jq '.dbrow' /root/harness/state/alert-quarantine.jsonl` shows `true` for entries
whose row was marked.

**Manual-only / not automatable:** the end-to-end path against the deployed
worker (the suites stub curl); flipping `flags/alerts-db` on a real box is an
operator action, and this slice was not run with the flag on in production.
