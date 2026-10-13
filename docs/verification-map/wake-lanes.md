# Wake classes — the BH-1034 contract + BH-1060 pr-closed/pr-ci + BH-1061 push/flaky wiring

**What it is:** the shared machinery that turns GitHub webhook events into
suffixed wake events (`pull_request.closed`, `check_suite.completed`, ...) and
routes them through pluggable class files (`bin/lib/wake-class-<class>.sh`).
BH-1059 shipped the contract; BH-1060 wires the `pr-closed` and `pr-ci` classes; BH-1061 wires the `push` and `flaky` classes.

**How a user reaches it:** there is no UI. The receiver is armed per repo as
documented in `docs/EVENTS.md` §4. The loop runs on the hub via `cron/hub.cron`:
```
* * * * * /root/harness/bin/wake-loop.sh
```

**Key routes / scripts:**
- `POST /webhooks/github` — `worker/jobs/src/routes/webhooks.js` (routed from `worker/jobs/src/index.js`) stores the suffixed event in the `wakes` table.
- `bin/wake-loop.sh` — polls `/api/wakes`, runs legacy lanes, calls active class hooks, and offers classes `lane_runs_here` / `remote_launch` (launch a lane on the box `bin/box-for.sh` names, detached).
- `bin/lib/wake-lanes.sh` — shared library every lane script sources: `wake_class_of` (lane→class), `wake_stamp` (`state/wake-ran/<lane>[-<project>]`), `wake_backstop_skip` (skips a redundant cron tick, one line into `logs/wake-backstop.log`).
- `bin/lib/wake-class-<class>.sh` — per-class file defining `wc_<class>_row` and `wc_<class>_dispatch`.
- `bin/lib/wake-class-pr-closed.sh` — `pull_request.closed` rows launch `bin/reconcile-prs.sh`, `bin/check-migration-prs.sh` and `bin/alerts-groom.sh` on the hub.
- `bin/lib/wake-class-pr-ci.sh` — `checks` rows whose event is `check_suite.completed` (BH-1292: per-job `check_run.completed` is ignored, like the flaky class) and `pull_request.{opened,synchronize,reopened,ready_for_review}` run `bin/review-prs.sh` on the owning box and launch `bin/review-autopilot.sh`; any `pr`/`issue` row launches `bin/tickets-snapshot-push.sh`.
- `bin/lib/wake-class-push.sh` — BH-1061: `push` wakes drive `rebase-train.sh` per project, plus `fleet-propagate.sh` and `prompt-eval.sh --cron` for `cromford` pushes that touch `prompts/`.
- `bin/lib/wake-class-flaky.sh` — BH-1061: `check_suite.completed` wakes drive `flaky-detect.sh <project> --days 1` per project; `check_run.completed` is ignored.
- The six lanes named above (`reconcile-prs`/`check-migration-prs`/`alerts-groom`, `review-prs`/`review-autopilot`/`tickets-snapshot-push`) plus `bin/rebase-train.sh`, `bin/fleet-propagate.sh`, `bin/flaky-detect.sh` (BH-1061) each carry a `wake backstop` block after their own lock: a cron tick within the contract's window (`${WAKE_BACKSTOP_S:-1800}`, or a per-call override) of a `WAKE_LAUNCH=1` run of the same lane stands down. `bin/reconcile-prs.sh` passes a per-call `300` (BH-1292: its wake run cannot clear a closure younger than `MC_CLOSED_SETTLE`, so the default 1800 held the `*/10` lane down past the settle window).

- `bin/lib/wake-class-pr-ci.sh` — `checks` rows and `pull_request.{opened,synchronize,reopened,ready_for_review}` run `bin/review-prs.sh` on the owning box and launch `bin/review-autopilot.sh`; any `pr`/`issue` row launches `bin/tickets-snapshot-push.sh`.
- `bin/lib/wake-class-push.sh` — BH-1061: `push` wakes drive `rebase-train.sh` per project, plus `fleet-propagate.sh` and `prompt-eval.sh --cron` for `cromford` pushes that touch `prompts/`. BH-1351: `prompts_touched` fetches the pushed sha (bounded, objects and `FETCH_HEAD` only — no remote-tracking ref moves) when the hub checkout lacks it, so the dispatch fires on the normal path instead of only when something else happened to fetch first; a sha still missing after the fetch logs one line and launches nothing. The prompt-eval window is `${WAKE_PROMPT_EVAL_COOLDOWN_S:-86400}`.
- `bin/lib/wake-class-flaky.sh` — BH-1061: `check_suite.completed` wakes drive `flaky-detect.sh <project> --days 1` per project; `check_run.completed` is ignored. BH-1351: the per-project window is `${WAKE_FLAKY_COOLDOWN_S:-21600}`.
- Both windows and `HARNESS_CHECKOUT` are registered knobs on the `wake-loop` lane (`catalog/lanes.d/wake-loop.json`), so they render on the settings page; `HARNESS_CHECKOUT` carries `settable: false` because it is a path a root lane uses.
- The six lanes named above (`reconcile-prs`/`check-migration-prs`/`alerts-groom`, `review-prs`/`review-autopilot`/`tickets-snapshot-push`) plus `bin/rebase-train.sh`, `bin/fleet-propagate.sh`, `bin/flaky-detect.sh` (BH-1061) each carry a `wake backstop` block after their own lock: a cron tick within the contract's window (`${WAKE_BACKSTOP_S:-1800}`, or a per-call override) of a `WAKE_LAUNCH=1` run of the same lane stands down.

**Preconditions / seed needs:**
- A fleet repo with a GitHub webhook pointing at `https://harness-jobs.operator.workers.dev/webhooks/github` and the `GITHUB_WEBHOOK_SECRET` set in the worker.
- A class file dropped into `bin/lib/wake-class-<class>.sh` and its class flag on: `bin/jobs-client.sh flag-set wake-lanes-<class> on` (`pr-closed`, `pr-ci`, `push`, `deploy`, `flaky`).
- The shipped classes stay inert until an operator runs `bin/jobs-client.sh flag-set wake-lanes-pr-closed on "BH-1034"`, `wake-lanes-pr-ci on "BH-1034"`, `wake-lanes-push on "BH-1061"` and `wake-lanes-flaky on "BH-1061"`.
- The `queue` class (BH-4169) is armed with `bin/jobs-client.sh flag-set wake-lanes-queue on "BH-4059"`. Until then `bin/fly-dispatch.sh` and `bin/fly-pool-tick.sh` run only on their `*/10` cron backstops (BH-4172); `bin/fly-results-ingest.sh` stays on its `*/2` sweep and no wake launches it.
- A lane's backstop skip reads that SAME class flag (`wake_class_of` maps each lane onto its class), so one flip arms both the class's dispatch and its lanes' backstops. Without it every lane keeps its full cron cadence.
- `flags/wake-lanes-off` suppresses every class regardless of individual flags, and opens every lane's backstop.

**Verify it works:**
- A signed `pull_request.closed` delivery returns `wake.event === "pull_request.closed"` and stores that value.
- `bash tests/wake-lanes-lib.bh-1034-test.sh` exercises the lane→class map and the backstop truth table (flag, stamp age, `WAKE_BACKSTOP_S`, `WAKE_LAUNCH=1`, kill switch).
- `bash tests/wake-classes-hook.bh-1034-test.sh` exercises the loader, the armed-classes log line, row/dispatch hooks, `remote_launch` routing (owning box or crontab: launched here; another box: the "owned by <box>" line and no ssh, BH-2525.2), and `WAKE_LAUNCH=1`.
- `bash tests/wake-pr-closed-drives-lanes.bh-1034-test.sh` drives the `pr-closed` class through the real loop and the backstop paste through the real `bin/reconcile-prs.sh`.
- `bash tests/wake-ci-drives-review.bh-1034-test.sh` drives the `pr-ci` class through the real loop (a local launch on the owning box, never ssh) and the backstop paste through the real `bin/tickets-snapshot-push.sh`.
- `HARNESS_TEST_SANDBOX=1 bash tests/wake-push-drives-lanes.bh-1061-test.sh` exercises the push class through the real `bin/wake-loop.sh` and the backstop in the real `bin/fleet-propagate.sh`.
- `HARNESS_TEST_SANDBOX=1 bash tests/wake-checks-drives-flaky.bh-1061-test.sh` exercises the flaky class through the real `bin/wake-loop.sh` and the backstop in the real `bin/flaky-detect.sh`.
- `HARNESS_TEST_SANDBOX=1 bash tests/wake-pr-ci-suite-only.bh-1292-test.sh` pins that only `check_suite.completed` among `checks` rows reaches `bin/review-prs.sh`, through the real loop.
- `HARNESS_TEST_SANDBOX=1 bash tests/reconcile-prs-backstop-window.bh-1292-test.sh` pins the `300`s window in the real `bin/reconcile-prs.sh` paste (boundary, log line, and that `WAKE_BACKSTOP_S` does not widen it back).

- `HARNESS_TEST_SANDBOX=1 bash tests/wake-push-prompts-fetch.bh-1351-test.sh` drives `prompts_touched` against a REAL git origin: a local sha is not fetched, a sha only at origin is fetched and diffed, the fetch moves no remote-tracking ref, an unreachable origin fails closed with one line and no prompt-eval launch, and both cooldown knobs reach `cooled`.
- `HARNESS_TEST_SANDBOX=1 bash tests/lanes-registry-class-libs.bh-1351-test.sh` plants a class lib reading an unregistered `${WAKE_ZZ_BOGUS_S:-5}` into a copy of the tree and proves `tests/lanes-registry-test.sh` §7 goes red on it (and that a class-LOCAL does not).
- With no class files on disk, `bash tests/wake-loop-test.sh` and `bash tests/event-wake-scope-test.sh` stay green.

**Manual-only / not automatable:** arming the live webhook and secret is operator setup (documented in `docs/EVENTS.md`); nothing in this repo performs those writes.
