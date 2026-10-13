# Backup freshness (a backup that stopped says so)

**What it is:** the age of each box's last VERIFIED off-box copy, carried as a
fleet signal. `bin/state-backup.sh` (#447) stamps `state/backup-last.json` only
after `head-object` confirms the remote size, so that `ts` is the only honest
answer to "what would come back". Nothing raised an error when it stopped: a box
whose uploader died looked, from every angle, exactly like one whose uploader
ran — and the hub wipe (#388) is the reason that matters. Three surfaces now
read the same number through one library, `bin/lib/backup-freshness.sh`.

**How an operator reaches it:**

- the console, Mission Control → **Fleet** → the MACHINES tiles: each box tile
  carries `backup <age>`, with a red `STALE` pill past the threshold;
- the snapshot, on any box:
  `curl -s "$JOBS_URL/../api/status?s=$HARNESS_SECRET" | jq .backups`
  (or `mcp fleet_status`) → `{"<box>": {state, backup_age_min?}}`;
- `logs/ALERTS.log` / `logs/pipeline-health.log` on the hub, for the pages.

**Primary lane:** `bin/state-backup.sh` (every box, `5,20,35,50`) states this
box's three raw facts on the way out of the tick that produced them
(`box-backup-set`); `bin/backup-records-sync.sh` (`cron/hub.cron`, `*/5`) turns
every box's row back into `state/fleet-heartbeat/backup-<box>`, dated from the
report; `bin/fleet-status-push.sh` (`*/10`) publishes `backups`;
`bin/pipeline-health.sh` (`*/10`) alerts. The push never makes a network call of
its own for this — it is the watchdog's layer-2 dead-man signal, and a slow box
must not be able to stop it.

**The direction reversed in BH-1031 and the record did not.** Until state→DB
slice 6 the hub COLLECTED these facts: the probe was spliced into the 15-minute
ssh hop `bin/fleet-heartbeat.sh` already made to every box. That lane answered
"can the hub REACH the box", not "is the lane alive", and it is deleted. The
report now travels from the machine that owns the fact, nine ssh hops an hour
become one `GET /api/boxes`, and the record keeps its path, its three fields and
its mtime convention — the shape is a published contract with three consumers
and a console screen. **The report lives inside `bin/state-backup.sh` on
purpose**: it is the writer of the stamp, so the age it reports is the age the
stamp actually has. A reporter on its own cron would publish the previous run's
timestamp, and a 15-minute rhythm under a 30-minute threshold would flap.

**Five states, and only two of them page.** This is the whole design:

| state | means | pages? |
|---|---|---|
| `ok` | a parseable `ts`; `backup_age_min` = now − ts | only past the threshold, as `backupstale:<box>` |
| `off` | `flags/state-backup-off` or `STATE_BACKUP=0`. Checked FIRST, so switching the lane off also silences the stale stamp it leaves behind | no |
| `unconfigured` | a **current** `state/state-backup-unconfigured-<DAY>` exists (touched inside 48h) — the `BACKUP_*` keys are still a handoff. `bin/state-backup.sh` already writes one ALERTS line per UTC day | no |
| `missing` | none of the above: the lane should be stamping and never has | `backupmissing:<box>` |
| `unknown` | a `ts` that will not parse — a bug in this lane, not a dead backup | no; one line to `logs/pipeline-health.log` |

A box never heard from produces **no entry at all**. Silence from a box is not
evidence about its backups, and the lane-liveness pass already owns that story.

**A record only counts while it is current.** A box that has STOPPED being heard
from is the same silence arriving late, so it produces no entry either.
`bf_rows` reads `state/fleet-heartbeat/backup-<box>` only when all three hold:
the file's mtime is inside `BF_RECORD_FRESH_MIN` (35 min — `backup-records-sync.sh`
dates the file from the report itself, so mtime is the moment the box spoke),
there is no `state/fleet-heartbeat/unreachable-<box>` (nothing writes that marker
since BH-1031, and the sync clears a leftover the moment its box answers again),
and `fleet.conf` still names the box. A box that stopped reporting KEEPS its last
record — a stale report is not written at all, rather than rewritten with old
facts and a fresh date — and the other half of that promise is that the kept
record must then stop ageing. Without the bound, minute 30 of any outage starts
an hourly `backupstale` page whose text ("uploads are failing, not
just slow") is false, a dead heartbeat lane pages for every box at once, and a
retired box's leftover file pages forever with no retraction possible —
`bin/fleet-slo.sh` SLO 4 measured two such files on the hub on 2026-09-15.
The trade this makes on purpose: a box that goes unreachable while it is
`backupstale` gets a `RESOLVED backupstale:<box>` line from the retraction
epilogue, because the condition is no longer observable. `UNREACHABLE` is then
the live alert, and the stale reading comes back the tick the box does.

**How to drive it:**

| what | how |
|---|---|
| the whole lane, against fixtures | `HARNESS_TEST_SANDBOX=1 bash tests/backup-freshness-test.sh` |
| the midnight window, clock pinned | `HARNESS_TEST_SANDBOX=1 bash tests/backup-freshness.bh-1308-test.sh` — the undatable-row cases at a held `BACKUP_SYNC_NOW`, so they do not depend on what time the suite happens to run |
| the console half | `cd console-ui && node --test tests/fleet-backup-column.test.js` |
| the uploader that writes the marker | `HARNESS_TEST_SANDBOX=1 bash tests/state-backup.bh-447-test.sh` |
| the live reading, on the hub | `bin/fleet-status-push.sh` then `jq .backups` on the pushed body, or `cat state/fleet-heartbeat/backup-<box>` |
| force the frozen-record case | on the hub, `touch -d '-3 hours' state/fleet-heartbeat/backup-<box>` — that box's entry disappears from `.backups` and stops alerting. The AGE comes from the `ts` inside the record; whether it is an answer at all comes from the mtime |
| force a stale reading | on a box, `touch -d '-2 hours' state/backup-last.json` does NOT work — the age comes from the `ts` INSIDE the file, not its mtime. Edit the `ts`, or set `BACKUP_STALE_MIN=0` for one run of `bin/pipeline-health.sh` |

**Knobs:** `backup_stale_min` — the operator knob store, so it changes with no
deploy: `bin/jobs-client.sh setting-set backup_stale_min 45 "why"`. One knob
moves both surfaces: `bin/pipeline-health.sh` pages on it, and
`bin/fleet-status-push.sh` publishes it as the snapshot's `backup_stale_min` so
the console's `STALE` pill uses the same number (the console cannot reach the
knob store; a threshold compiled into the bundle would show a red pill at 31m
for a box nothing pages about at 40m). It is pushed as a number or omitted,
never as `null` — `Number(null)` is `0`, which would make every box stale.
Resolution order is `setting_get backup_stale_min` → `BACKUP_STALE_MIN` in
`env/global.env` → **30**, the documented code fallback (`bin/state-backup.sh`
runs at `5,20,35,50`, so 30 minutes is two missed cycles). A non-numeric value
is refused and the next source used, never clamped in silence. There is no seed
row: `GET /api/settings/<key>` answers `{setting:null}` for an absent row, which
is the documented "use your fallback" answer, so no schema change ships with
this.

**Preconditions / seed needs:** none beyond a fleet that already heartbeats. The
signal is honest before `BACKUP_*` is configured anywhere — every box simply
reads `unconfigured` until its keys land, which is the true state, and reads
`missing` (which pages) from the first configured tick if the uploader then
never stamps. Two things make the second half true, and both are load-bearing:
`bin/state-backup.sh` **deletes** every `state-backup-unconfigured-*` the moment
the config check passes, and the reader counts a marker only while it is current
(`-mmin -2880`, `BF_UNCONF_FRESH_MIN`). Without either one the state would latch:
every box in the fleet has run unconfigured for days, so every box carries old
markers, and a reader that accepted any of them would make `backupmissing`
unreachable fleet-wide and tell the operator who just configured a failing box
that its backup is "not configured".

**One expected page per brand-new box.** Between `bootstrap-machine.sh` and
`bin/state-backup.sh`'s first tick (≤15 min) a box has no stamp and no marker,
so it reads `missing` and pages once (TTL 1h), then retracts with a `RESOLVED`
line once the lane speaks. That is the honest reading — nothing of that box is
off-box yet — and it is not worth chasing.

**What must never regress:**

- **`backup_age_min` is absent unless an age is knowable.** A fabricated `0` is
  the HEALTHY value for the very number the fleet alerts on, so it would read as
  "backed up just now" forever. `unknown` must never render as fresh either.
- **`off` and `unconfigured` must never page.** Both already have an owner that
  says them once. An hourly duplicate per box is the page-fatigue that gets the
  channel muted, and a muted channel costs the alerts that matter.
- **The push must survive this field.** No lib, no `jq`, no `date -d` → the
  field is absent and the dead-man push still goes out.
- **An unreachable box must not have its record overwritten.** Inventing
  `missing` out of a failed ssh pages twice for one fault.
- **A stale RECORD is not an answer either.** Keep both halves: the record
  survives the failed hop, and it stops ageing. A frozen `ts` read as a fresh
  reading is the same "twice for one fault", with a worse message — and the
  same rule keeps a retired box's leftover file out (`fleet.conf` membership,
  the `bin/fleet-slo.sh` SLO 4 idiom).
- **The box-side probe and its local twin must agree.** `bf_remote_probe` is
  the only place the box-side rule is written down, and the suite runs it and
  `bf_facts_local` against the same fixture tree.
- **`unconfigured` must stay escapable.** An old marker is not evidence. Keep
  both halves: the cleanup in `bin/state-backup.sh` and the freshness window in
  the reader. The unconfigured branch also sweeps every marker but today's, so a
  box left unconfigured for a year carries one file, not 365.
- **The threshold the console draws is the threshold the hub paged on.** It
  travels in the snapshot (`backup_stale_min`); a number compiled into the
  bundle puts a red pill on a box nothing pages about.
- **The probe's answer is found by its `BF<TAB>` tag, never by line number.**
  `bf_remote_probe` outlives the ssh hop it was written for: it is the
  executable statement of the box-side rule, it is what an operator runs by hand
  against one box, and the suite runs it against the same fixture tree as
  `bf_facts_local` — which is what keeps the twin honest now that the twin is
  the production path.
- **Both ends of the record are cut BY POSITION, never `IFS=$'\t' read`.** Tab
  is IFS whitespace, so `read` collapses a run of tabs and drops the leading
  ones: a healthy quiet box reports three empty fields, and a `read` would hand
  the sync the collection time in the `ts` slot and nothing in the collection
  slot — every such box silently skipped, by a loop that looks correct.
- **A stale report is not written at all.** Rewriting one hands `bf_rows` a
  fresh-looking file full of old facts, so the record could never age out: the
  frozen-record bug one layer down from the bound that exists to prevent it.
- **An undatable row is refused BEFORE `date` sees it.** GNU `date -u -d ""`
  answers today's 00:00:00 with rc 0, so an empty collection time was not
  rejected — it was DATED at midnight, which is inside the collection window
  for the 35 minutes after 00:00Z. `bin/backup-records-sync.sh` writes a record
  only for a value that starts with a real `YYYY-MM-DD`; a blank one, and every
  relative word (`now`, `today`) that `date` would otherwise guess at, is
  skipped and counted. The version of this that read as a flaky test cost a day
  of drains (BH-1308).
