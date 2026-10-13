# GitHub REST quota ledger and reserve

**What it is:** every `gh_rest` REST call now reads the response's
`X-RateLimit-*` headers, writes one append-only ledger line saying who made it,
and — below a reserve — refuses reads the caller marked OPTIONAL before the
request is issued.

**Why it exists (measured 2026-09-22 17:00Z).** The hub and the pool boxes run
every lane under ONE GitHub App installation, so every repo's token draws on the
SAME primary bucket: `rate_limit` read through the project-4, project-7 and
cromford tokens, from the hub AND from the small box, returned one counter
(used 2452..2535 of 6600, reset 17:33:58Z). Consumption ran ~95 calls/min —
about 5,700/h against a 6,600/h cap — so the fleet drained the bucket in the last
five minutes of every hourly window. The symptom was an hourly burst of ~30
"UNVERIFIABLE (HTTP 000)" lines across `merge-conductor.log` and
`merge-sweep.log` (203 + 93 in one hour), each one a decision path skipping a
tick: *"not merged this tick: the diff read was UNVERIFIABLE"*, *"stack-parent
read … answering NONE, which keeps the child waiting"*. Nothing read the rate
headers and nothing ledgered a call, so the quota was invisible until it was
gone and no lane could be blamed.

Three parts:

- `bin/lib/gh-rest.sh` — three code lines: the guarded source, the reserve gate
  BEFORE the request, and the header/ledger hook after the status line. The file
  is held to its contract functions and a source-time grammar by
  `tests/gh-rest-lib-test.sh` (a 112 code-line ceiling until BH-5228), which is
  why everything else lives next door.
- `bin/lib/gh-rest-ledger.sh` — the header parse, the path classifier, the
  ledger writer, the 48h sweep, the reserve resolution, the gate, and
  `gh_quota_line`. It contains no `gh api`: a meter that spends the thing it
  measures is worse than no meter.
- `bin/gh-quota-report.sh [hour|day]` — calls per bucket, calls per lane per
  hour and the top path classes, so "who burns it" is one command. It writes
  nothing and deletes nothing.

**Buckets.** The fleet does not spend from one meter. Every installation token
of the App shares the single 6,600/h installation bucket the ticket measured,
and each PAT in the token ladder (`bin/merge-sweep.sh`, `bin/lib/gh-repo-token.sh`
switch `GH_TOKEN` per repo inside one process) has its own 5,000/h user bucket.
So the reading is keyed by bucket (`state/gh-rest-ledger/.quota-<bucket>`), the
gate judges the bucket the token in scope is about to spend from, the ledger
carries the bucket as column 10, and `gh_quota_line` / the fleet push report the
`app` bucket and say so. A PAT is named by the first 12 hex of a sha1 of its
value — never by its value.

**How an operator reaches it:** `bin/merge-sweep.sh` prints one
`QUOTA rem=… limit=… reset=… reserve=…` line per tick (the merge conductor gets
the same line under BH-1486). The hub's `bin/fleet-status-push.sh` pushes
`gh_rest_quota.<box>` and `gh_quota_reserve`, and the Fleet screen's box tile
renders them, red with a `QUOTA LOW` pill under the reserve.

**How to drive it:**

| what | how |
|---|---|
| the whole feature (nine sections) | `bash tests/gh-rest-quota-test.sh` |
| the library contract it hooks into | `bash tests/gh-rest-lib-test.sh` |
| the ETag cache the `counted` column depends on | `bash tests/gh-rest-etag-test.sh`, `bash tests/gh-rest-etag.bh-1322-test.sh` |
| the box tile that renders it | `cd console-ui && node --test tests/fleet-gh-quota-column.test.js` |
| the orphan ratchet that covers the console lib | `TI_BASE=$(git merge-base HEAD origin/main) bin/test-impact.sh orphans --check` |
| the push it lands in | `bash tests/fleet-status-push-fields-test.sh` |

**Verify it works on a live box (read-only, costs no API call):**

```bash
bin/gh-quota-report.sh hour            # this hour, per lane, top path classes
bin/gh-quota-report.sh day             # everything still on disk (<= 48h)
cat state/gh-rest-ledger/.quota-app    # remaining limit reset observed-epoch
tail -n 5 state/gh-rest-ledger/*.tsv   # the raw lines
grep QUOTA logs/merge-sweep.log | tail # the per-tick line
grep '\[gh-ledger\]' logs/gh-rate.log  # why a ledger line was dropped, if one was
```

**Files it owns on a live box:**

- `state/gh-rest-ledger/<utc-hour>.tsv` — append-only, tab separated:
  `ts  lane  project  method  path-class  status  counted  remaining  reset  bucket`.
  Swept at 48h (`GH_LEDGER_TTL_H`, floored at 1h so it can never delete the hour
  a lane is writing into), at most once an hour, behind `.swept`. The sweep is
  `gh_quota_ledger_sweep`, called by `bin/merge-sweep.sh` — never by the report.
- `state/gh-rest-ledger/.quota-<bucket>` — `remaining limit reset observed-epoch`,
  the last reading any lane on this box took OF THAT BUCKET. Written tmp+mv, so
  a concurrent reader gets one whole line or the previous one.
- `state/gh-rest-ledger/.reserve` — `value epoch`, a 300s cache of the resolved
  knob, so the gate never puts a worker request in front of a REST read.
- `logs/gh-rate.log` — at most one `[gh-ledger]` line per process when the
  ledger could not be written.

**Knobs:** `gh.quota.reserve` via `setting_get` (seeded to `600` in
`worker/jobs/schema.sql`, editable in the console), overridable per run with
`GH_QUOTA_RESERVE`, code fallback `600`. A non-integer is logged once and
ignored rather than clamped. `GH_REST_OPTIONAL=1` is set by the CALLER, per
call, and is the only thing the gate ever refuses.

**What must never regress:**

- The gate runs BEFORE the request. A guard that judges the response has already
  spent the call it exists to save — the same shape as a post-charge dedup on
  any metered API. `tests/gh-rest-quota-test.sh` §5 asserts the stub `gh` was
  not invoked at all, not merely that the rc was 75.
- A decision-critical read is NEVER gated. Starving the merge and close paths is
  a worse failure than draining the bucket, and is exactly what the drained
  bucket already causes.
- UNKNOWN IS NOT ZERO, in four places: a response with no rate headers leaves
  `GH_REST_QUOTA_REMAINING` empty; an empty reading never gates; `gh_quota_line`
  renders `rem=?`; and the console renders nothing rather than `0`.
- A reading whose reset window has already passed is an UNKNOWN everywhere, not
  only in the gate: it does not gate, `gh_quota_line` prints `stale=1` and drops
  the numbers, and the fleet push omits the entry so the tile renders unknown.
  A reading with no reset at all is the same kind of unknown and does not gate.
  The screen and the gate have to agree, or a paused fleet wears a red QUOTA LOW
  for hours against a bucket that refilled.
- A reading is never judged against another bucket's headroom. The red-first
  case is in §5 of the suite: an App read that follows a PAT read must be gated
  on the App bucket's 100, not waved through on the PAT's 4,900.
- The report is read-only. It is what an operator runs while wondering what is
  happening, and a read that sweeps can destroy the evidence it was called to
  show (§7 asserts a ten-day-old file it was shown is still there afterwards).
- The ledger never fails a caller and never changes a body. Every function
  returns 0, which matters because `gh_rest` calls them as the last statement of
  an `if` block under `set -e`.
- `counted=0` for a 304 and for a 000. GitHub does not charge a conditional
  request that answers 304, and nothing reached it on a 000; counting either
  would hide the real burn under the ETag cache's own success.
- The path CLASS, not the raw path: shas collapse before digits, and the query
  string is dropped, or one endpoint read four thousand times reports as four
  thousand endpoints read once.
