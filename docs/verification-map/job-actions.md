# Job RETRY / REQUEUE / ABANDON buttons

**What it is:** RETRY and REQUEUE buttons for one coordination job, on the Job
screen and on the Build screen (BH-2323), and ABANDON beside them (BH-2406). A
click opens the in-app confirm. Confirming sends one POST to the worker's retry,
requeue or abandon route and shows the worker's decision and reason. Then the
page reloads the row. ABANDON's dialog has a REASON field and its ABANDON
button stays disabled until the reason has text.

**How a user reaches it:**
- JOBS tab → `/jobs` → click a job row → `/jobs/:id`. The buttons sit under the
  stats row.
- FLEET → a project → a build → `/builds/:id`. The buttons sit above the
  mission block, only when the build joins to a job row (`matchBuildJob` in
  `console-ui/src/lib/live.js`). A build with no job row shows its existing job
  note and no buttons.

**Key routes/screens:**
- `POST /api/coord/jobs/:id/retry`, `POST /api/coord/jobs/:id/requeue` and
  `POST /api/coord/jobs/:id/abandon` (`console-ui/functions/api/coord/[[path]].js`).
  The proxy forwards exactly these three job writes with the bearer, and sets
  `actor: "console"` over any value the page sent. Retry and requeue forward
  only `detail`; abandon forwards only `reason`. A body that is not a JSON
  object answers 400. Every other `jobs/*` write (PUT/PATCH/DELETE,
  `jobs/:id/beat`, `jobs/:id/abandon/extra`, a `.` or `..` id) stays 405.
- ABANDON's worker route is `worker/jobs/src/routes/job-abandon.js`. It moves the
  row to the terminal `abandoned` in one batch with an ABANDONED stage event
  (actor and reason) and closes the ticket's `ready`/`queued` build_queue rows.
  It answers 400 with no reason, 409 on a done or budget-stopped row, and
  `already` on an abandoned one. The resume pass, the pool's requeue and the
  blocked-resolver then leave the ticket alone (`tests/job-abandon.bh-2406-test.sh`).
  They read the ticket's newest BUILD row (`kind=build`), so a later triage,
  lead-review, orc or migration row for the same key does not un-abandon it;
  only a newer build attempt does (§6 of that suite).
- The worker routes are `worker/jobs/src/routes/job-retry.js`, unchanged. The
  stage event they write names actor `console`, and it shows in the Job
  screen's STAGE EVENTS table after the reload.
- Which buttons show (`availableActions` in `console-ui/src/lib/job-actions.js`):
  a running job with no activity for 10 minutes (STALLED or QUIET) gets RETRY,
  REQUEUE and ABANDON. An ORPHANED job gets REQUEUE and ABANDON. A queued, parked
  or failed job gets ABANDON. A freshly beating job and every done,
  budget-stopped or abandoned row gets none.

**Selectors:**
- `role=button[name="RETRY"]`, `role=button[name="REQUEUE"]`,
  `role=button[name="ABANDON"]` (in `.job-actions`)
- `role=dialog[name="RETRY JOB"]` / `role=dialog[name="REQUEUE JOB"]` (CANCEL /
  RETRY or REQUEUE)
- `role=dialog[name="ABANDON JOB"]`, its `role=textbox[name="Reason"]`, and
  CANCEL / ABANDON (disabled until the reason has text)
- `.job-actions [role=status]` (the outcome line)

**Preconditions / seed needs:** a job that is stalled, quiet or orphaned (or,
for ABANDON, parked, queued or failed). On a healthy fleet there may be none.
JOBS → filter status `orphaned` or `parked` finds one if it exists. ABANDON is
final, so try it on a job that really is over.

**Verify it works:** open a stalled or orphaned job. Click REQUEUE, check the
dialog names the job id, press Escape or CANCEL, and devtools shows no request.
Click again and confirm: one `POST /api/coord/jobs/<id>/requeue`, then an
outcome line with the worker's reason (`Queued for the lane's next tick`,
`Held, not requeued`, `Parked, it will not re-run`, `Nothing changed`, or
`... failed: <error>`). The STAGE EVENTS table then shows a REQUEUED row with
actor `console`. At 375px the button row wraps and the body does not scroll
sideways.

ABANDON: open a parked or orphaned job and click ABANDON. The dialog names the
job, says the move is final, and focuses the Reason box; ABANDON is disabled.
Type a reason and it enables, with focus still in the box. Escape sends nothing.
Confirm sends one `POST /api/coord/jobs/<id>/abandon` with `{"reason": ...}`,
the outcome line reads `ABANDON: Abandoned: <reason>`, the row reloads as
`abandoned` with no buttons, and STAGE EVENTS shows an ABANDONED row with actor
`console` and the reason.

**Tests:** `console-ui/tests/job-actions-proxy.bh-2323.test.js` (the real
`onRequest`) and `console-ui/tests/job-actions.bh-2323.test.js` (helpers, the
mounted component, and the real `JobScreen` / `BuildScreen`). ABANDON:
`console-ui/tests/job-abandon.bh-2406.test.js`,
`console-ui/tests/job-abandon-proxy.bh-2406.test.js`,
`worker/jobs/test/job-abandon.bh-2406.test.js` and
`tests/job-abandon.bh-2406-test.sh`.

**Not here:** ABANDON does not stop a process that is still running and does
not close a PR.
