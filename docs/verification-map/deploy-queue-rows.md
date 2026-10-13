# Deploy queue rows (the request, the claim, and the departure)

**What it is:** the READ/WRITE half of #1026's deploy slice. Until now the queue
of merged shas waiting to be deployed was a directory on ONE box —
`state/deploy-queue/<project>/<epoch>-<sha8>`, each file holding
`<merge-sha> <build-dir>` — so nothing outside that box could see what was
waiting, and the only guard against two trains departing the same sha was a
per-box `flock`. This slice puts the queue in the `deploy_queue` table
(#1026.0 shipped the table), and makes `bin/deploy-request.sh` write a row
before it writes its file and `bin/deploy-train.sh` CLAIM every member of the
batch before it fires a deploy hook.

**The file dir is NOT gone.** `bin/deploy-request.sh` still writes a file for
every request, in every mode, and `bin/deploy-train.sh` still reads that
directory whenever the rows are not available. Removing the file store is a
later slice; this one adds the row beside it.

**It is off by default.** The `deploy_queue_rows` settings row seeds `'0'`, and
at `'0'` the lane makes no deploy-queue request at all and behaves byte for
byte as it does today.

**How an operator reaches it:** there is no UI — cromford has no app. The
surfaces are the client and the worker, both bearer-gated:

- `bin/jobs-client.sh setting-get deploy_queue_rows` — `0` is the shipped state
- `bin/jobs-client.sh setting-set deploy_queue_rows 1 "<why>"` — arms the slice
- `bin/jobs-client.sh deploy-list <project> [status] [stale-min]` — the queue
- `bin/jobs-client.sh deploy-put <project> <sha> [build-dir]`
- `bin/jobs-client.sh deploy-claim <project> <sha> [stale-min]`
- `bin/jobs-client.sh deploy-depart <project> <sha> done|failed|queued [reason]`
- `curl -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/deploy-queue?project=<p>"`
  → `{"deploy_queue":[…],"as_of":"…"}`

**Key routes:**
- `POST /api/deploy-queue` — `{project, sha, build_dir?}`. IDEMPOTENT on
  `(project, sha)`. A `queued`, `claimed` or `held` row answers
  `{duplicate:true}` and is not written (an in-flight departure is never reset
  under the train carrying it, and an operator's hold is never undone by a
  merge, an ADOPT or a self-source); a TERMINAL row is **RE-OPENED** — status back to `queued`,
  `departed_at`/`reason`/`claimed_by` cleared, `enqueued_at` restamped. The sha
  is trimmed, lower-cased and checked against `^[0-9a-f]{7,64}$` once, here;
  anything else is a 400.
- `GET /api/deploy-queue?project=&status=&sha=&limit=&stale_min=` — `SELECT *`
  ordered `enqueued_at ASC, sha ASC` (a batch of merges lands inside one second
  routinely), bounded to `[1, 500]` with a default of 200. `?stale_min=N`
  post-filters to `claimed` rows never departed whose `updated_at` is at least
  N minutes old — the threshold is the caller's, the clock is the server's.
- `POST /api/deploy-queue/claim` — `{project, sha, box, stale_min?}`. A single
  compare-and-swap with NO read before it. 200 when it took the row, 409 when
  another claimant has it, 404 when there is no such row.
- `POST /api/deploy-queue/depart` — `{project, sha, status, reason?}` with
  `status` one of `done`, `failed`, `queued`. Refused (409) unless the row is
  `claimed`. `departed_at` is stamped here and nowhere else; `queued` is the
  RELEASE, and it clears the claimant.

**Selectors:** none (no UI). The observable surfaces are the TSV a helper
prints, the JSON a route answers, `logs/deploy-train.log`, `logs/ALERTS.log`
and the files under `state/deploy-queue/<project>/`.

**Preconditions / seed needs:**
- `worker/jobs/schema.sql` applied — which happens on its own:
  `bin/harness-sync.sh` applies each statement before `wrangler deploy` and
  skips the deploy if one fails. There is no hand step, and this slice adds no
  schema statement (the table shipped in #1026.0).
- the `deploy_queue_rows` settings row at `'1'` (or `DEPLOY_QUEUE_ROWS=1` in
  `env/global.env`, the documented env fallback — the only way the slice is on
  while the worker is unreachable).
- `HARNESS_SECRET` and `JOBS_URL` (the client reads both from `env/global.env`
  when the caller has not exported them).
- a project with `VERSION_URL` set: that is the whole gate on the train.

**The knob:** `DEPLOY_CLAIM_STALE_MIN` (registered in
`catalog/lanes.d/deploy-train.json`, default 30, `0` = off). Minutes after which
a `claimed` row whose `departed_at` is still NULL is re-offered to the next
departure, so a train that died mid-flight does not strand its batch. The
default is above one full poll window (`TRAIN_POLLS` 40 × `TRAIN_POLL_SECS`
20s ≈ 13 min), so a live train is never re-offered from under itself. It reaches
the lane as a settings row through `lane_env_apply`; the literal `30` in the
script is the documented fallback only.

**What the train does with the flag ON:**
1. ADOPT — one idempotent `deploy_queue_put` per file in `state/deploy-queue/<p>/`,
   so a request written while the worker was down (file, no row) is not orphaned
   the moment the worker comes back.
2. LIST — `deploy_queue_list <p> queued`, plus `deploy_queue_list <p> claimed
   <stale>` when the knob is above 0.
3. HOLD (BH-3154) — `deploy_queue_list <p> held`, on the file-dir fallback
   too. Any held row: one `deploy hold: <sha8…> held` line and the tick
   departs NOTHING (no claim, no self-source, no file batch). The held list not
   answering: one `deploy hold: … (fail closed)` line and nothing departs.
   The hold itself is `POST /api/deploy-queue/action` `{action:"hold"}` from the
   console's QUEUES panel ([queue-panel.md](queue-panel.md)).
4. CLAIM every member. rc 9 or rc 2 drops that sha from the batch and logs why;
   rc 1 is a worker outage MID-CLAIM, which releases what was already taken,
   logs, and departs NOTHING this tick — half a batch is not a batch.
5. Fire the hook once, poll the version endpoint, then either
   `depart … done` per sha and delete the matching files, or
   `depart … queued` per sha and keep the files, exactly as both failure modes
   keep them today.

**What it does with the flag OFF, or with the worker down while the flag
comes from the settings row:** the `ls -tr "$DQ"` batch, byte for byte, with
zero `/api/deploy-queue` requests, EXCEPT for the held read. A train that sees
the knob on leaves `state/deploy-hold-armed/<project>`. The held list (step 3)
is also read when the settings read did not answer (the knob then resolves off,
and the worker only accepts a hold while the settings row is on) and while that
marker is there. A held row still departs nothing. An unanswered held list
departs nothing on an armed box and reads the file dir only on a box that has
never seen the knob on. With the knob answered off, a held row writes one
`DEPLOY HOLD: deploy_queue_rows is off but <sha8…> is still held` ALERTS line
per held set, and the marker goes only once the knob answers off AND the held
list answers empty. **With the flag ON and the queued list not answering:**
the same file batch, but only after the held list (step 3) answered empty. rc 1
from the worker is never read as "nothing queued" or "nothing held".

**Verify it works:**
- flag off: a merge writes one file and no row, and the train departs it with no
  deploy-queue request in flight at all.
- flag on: `deploy-list <p> queued` shows one TSV line per waiting sha; after a
  departure both rows read `done` with `departed_at` set and their files are
  gone.
- a second train on the same tick: every claim answers 409, no hook fires, and
  nothing is departed.
- a hook that never arrived: the rows read `queued` with `departed_at` empty and
  no claimant, the files are still there, the ALERTS line fired, and the next
  tick claims the same sha exactly once.
- a claim 45 minutes old with `departed_at` NULL is re-offered at
  `stale_min=30`; one 5 minutes old is not asked for at all.

**Manual-only / not automatable:** flipping `deploy_queue_rows` to `'1'` on the
LIVE fleet. It changes which store this lane believes, so it is an operator
decision with a rollback (set the row back to `'0'`), not something a test
drives. Nothing here may be driven against a real box or a real deploy hook
either — firing one costs a production build.

Driven by `tests/deploy-queue-rows.bh-1026-test.sh` (the four helpers against a
live and a dead worker, and the REAL `bin/deploy-request.sh` and
`bin/deploy-train.sh` against a stubbed `curl` that is the worker, the version
endpoint and the deploy hook at once) and
`worker/jobs/test/deploy-queue-routes.bh-1026.test.js` (the four routes through
`worker.fetch` over real SQLite, including a genuine interleaved claim race).
The table, the knob rows and the re-open contract are
`worker/jobs/test/schema-deploy-queue.bh-1026.test.js` and
`tests/queue-rows-flags.bh-1026-test.sh`, from #1026.0.
