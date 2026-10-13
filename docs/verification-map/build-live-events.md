# Live build events (sub-stage progress on a running build)

**What it is:** a build in flight now says what it is doing. `bin/run-build.sh`
posts one short event per gate it passes — plan written, execute started, tests
red, tests green, semgrep, e2e, each review lens's verdict, fix rounds, the tier
decision, the PR, the final verdict and the hand-off — and the jobs worker hands
them back in order through one polling read. Before this, a jobs row carried one
`stage` word plus two events (`done`, `BUDGET_STOP`), so minute 3 and minute 70
of the same build were indistinguishable without ssh-ing to the box.

**How a user reaches it:** the events are an API read, not a screen — the console
screen that renders them is a follow-up ticket. Operators reach them with the
`curl` below, or through the console's same-origin proxy at
`/api/coord/jobs/<job_id>/live` once signed in with the `dash` cookie.

**Key routes/screens:**
- `GET /api/jobs/:id/live?since=<event_id>` (harness-jobs worker,
  `worker/jobs/src/index.js`, the `liveMatch` route above `detailMatch`) —
  `{ job, phases, events, spend_usd, cursor }`. Events are `id > since` only,
  ascending, capped at 200; `cursor` is the last event handed over, so a
  >200 backlog drains across polls without skipping. `since` beyond the last id
  returns `events: []` and `cursor: since`. A mangled cursor (`1e3`, `-1`,
  17 digits) is a `400`, never a silent replay from 0. Unknown job → `404`.
  `spend_usd` sums the finite phase spends only — a null spend stays null in its
  phase row and is never counted as 0.
- `/builds/:id` also shows RETRY / REQUEUE above the mission block when the
  joined job is stalled, quiet or orphaned (BH-2323, see
  [job-actions.md](job-actions.md)).
- `GET /api/coord/jobs/:id/live?since=` (`console-ui/functions/api/coord/[[path]].js`)
  — the existing proxy, unchanged: it already forwards every GET with the bearer
  and 403s without the dash cookie.

**Where the job_id comes from:** `bin/run-build.sh`'s claim (`job_open`) sets
`JOB_ID`; it is also the `id` column of every row `GET /api/jobs?status=running`
returns.

**The event vocabulary** (stage → what it means):
`plan` (plan written + size-gate verdict), `size` (splitting instead of
building), `execute` (started, with the model), `tests_red` (the reproduction
gate: `proven` / `none` / `not-green` / `not-run`), `tests_green` (the harness's
own suite run: `pass` / `fail` / `none` / `not-run`), `semgrep`
(`skipped` / `clean` / `findings`), `e2e` (`pass` / `fail` / `skip`), `review`
(one per lens, its verdict plus its blocking-finding count), `fix`
(`started` / `done`), `tier` (the heuristic decision, then the settled tier
after every demoter), `pr_opened` (with the url, or `failed`), `verdict`
(`APPROVE` / `BLOCK` with the reviewed sha), `handoff`
(`merged` / `conductor` / `merge-queue` / `hub-sweep` / `failed`).

**Preconditions / seed needs:** no schema change and no new env var.
`stage_events.id` is the existing `INTEGER PRIMARY KEY` and
`idx_events_job(job_id)` already serves the read. The emitters need a claim:
with `JOB_ID` empty (worker unreachable at claim time) every one of them is a
no-op and the build behaves byte-identically.

**Verify it works:**
- `bash tests/run-build-live-events-test.sh` — every emitter block extracted
  VERBATIM from `bin/run-build.sh` and driven with the real `job_event` over a
  stubbed transport: the stage/verdict/message of each gate, the 200-char cap
  and newline flattening, `JOB_ID=""` posting nothing, a failing transport not
  failing the build, and the negatives that matter — a failing suite never
  rendering as `pass`, a missing suite never as green, an absent findings
  heading counting `-` and not 0, a `BLOCK` artifact never emitting `APPROVE`,
  and a build whose `gh pr create` failed never emitting an open PR or claiming
  "the PR is open and approved".
- `cd worker/jobs && npm test` — the route's shape, ordering, cursor, cap,
  spend sum, `404`, `400` and `401` cases.
- `cd console-ui && npm test` — `tests/coord-live-fn.test.js`: the proxy
  forwards `/live?since=` to the jobs worker with the bearer, and 403s without
  the dash cookie.

**On a live box**, against a build that is actually running:
```
curl -s -H "authorization: Bearer $HARNESS_SECRET" \
  "$JOBS_URL/api/jobs/<running job id>/live" | jq '{cursor, spend_usd, last: .events[-3:]}'
```
Poll it again with `?since=<cursor>` and only the new events come back.

**Manual-only / not automatable:** the worker route ships in this diff but is
only served after `npx wrangler deploy` is run in `worker/jobs`. Until that
happens `/live` answers 404 on the deployed worker and this feature is at rung
MERGED, not LIVE. The emitters need no deploy — they are in `bin/run-build.sh`
and reach every box through the normal harness sync.
