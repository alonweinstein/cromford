# Fly builders, as built

**This file used to hold the 2026-07 trial plan, and that plan is superseded.**
The trial's shape — one dedicated persistent machine per project, a job pushed
onto it, a staged rollout — was replaced on 2026-08-13 by the ephemeral pool in
`bin/fly-pool.sh` (SCALE-PLAN wave 3). The old text is in git history:
`git log -p -- docs/FLY-BUILDER-TRIAL.md`. What follows describes what the
scripts in this repo do today, and nothing else. No plan, no estimates, no
staged rollout.

The caps that apply to a Fly-routed build live in `docs/BUILD-CONCURRENCY.md`.
This file answers the other question: what runs where.

---

## The routing rule

`caps_route` in `bin/lib/build-caps.sh` is the one place this is decided, and
`bin/concurrency-plan.sh` prints the live table for the fleet:

| flags on the hub | route | who owns the build |
|---|---|---|
| `flags/builder-fly-<p>` **and** `flags/fly-pool-<p>` | **pool** | `bin/fly-pool.sh` — one ephemeral machine per build |
| `flags/builder-fly-<p>` alone | **fly1** | `bin/fly-dispatch.sh` — the legacy single-machine dispatcher, one job at a time |
| neither | **local** | the project's own watcher box, under its own flags |

Which projects sit on which route is whatever the hub's flags say today. Run
`bin/concurrency-plan.sh` to read it rather than trusting a number written in a
doc — that is the mistake this file is being rewritten to stop repeating.

## The two flags

- **`flags/builder-fly-<p>`** routes the build off the box. It has to exist on
  the OWNING BOX (so `bin/run-build.sh` enqueues instead of building) and on the
  HUB (so the dispatcher and the pool will look at the project at all).
- **`flags/fly-pool-<p>`** turns the pool on. Its presence is the switch; a
  NUMBER inside it is an optional hard ceiling on live machines. Empty means
  follow the queue. `bin/pool-cap.sh` resolves it: the number in the flag, else
  a reviewed `<project> <n>` line in `fly/pool-caps.conf`, else `0` — unlimited,
  one machine per queued build. `POOL_CAP_MAX` in `env/global.env` trims every
  answer, unlimited included.

Three guards sit next to them, and none of them route anything:

- **`flags/fly-pool-app-<p>`** names the Fly app the pool spawns into
  (`pool-<p>`, written by `bin/fly-pool-rollout.sh`, read by
  `bin/fly-machine-state.sh`). Without it the pool is reap-only — it will clean
  up but never spawn.
- **`flags/pool-halt-<p>`** brakes spawning after `bin/pipeline-health.sh` sees
  two consecutive pool builds refused at the context gate. A harness deploy
  clears it (`bin/harness-sync.sh` voids verdicts issued against old code), so
  it is a brake rather than an off switch. You can set it by hand for the same
  effect — it is the closest thing the pool has to "stop now" (see Rollback and
  kill).
- **`flags/fly-disabled`** stops the DISPATCHER, and only the dispatcher.
  `bin/fly-dispatch.sh` is the one script in the tree that reads it (its first
  guard, right after the lock), so with the flag set the fly1 path goes inert
  and nothing new is materialised into the hub's `state/build-queue/<p>/` —
  neither ledger rows nor the ssh pull from a watcher. `bin/fly-pool-tick.sh`,
  `bin/fly-pool.sh` and `bin/fly-results-ingest.sh` never read it. A pool
  project therefore keeps spawning machines for everything already sitting in
  its queue directory, and for a project the HUB owns `bin/run-build.sh` writes
  the queue file straight into `state/build-queue/<p>/` on the hub, so the pool
  keeps getting new work with the flag on. Read it as "stop feeding fly1", not
  "everything off". The pool has no global kill — it goes off one project at a
  time (see Rollback and kill).

## Machine lifecycle

1. **Enqueue.** `bin/run-build.sh` hits its `flags/builder-fly-$PROJECT` gate,
   writes a queue row (`queue_put` into the jobs ledger, or the hub's
   `state/build-queue/<p>/<KEY>.json` file), answers
   `RESULT "QUEUED_FLY $KEY"` and exits. It exits ABOVE the wip gate, the
   per-key flock and `job_open`, so no local cap has been consulted.
2. **Materialise.** `bin/fly-dispatch.sh` (hub, `*/10`) turns ledger rows into
   queue files. For a pool project it stands down immediately —
   `dispatch_project()` opens with
   `flag_on fly-pool "$p" && return 0`.
3. **Spawn.** `bin/fly-pool-tick.sh` (hub, `*/10`) ticks every flagged project at
   once; each `bin/fly-pool.sh` self-locks with `flock -n` and exits if held.
   One ephemeral, volume-less machine per queued job. The env bundle comes from
   `bin/fly-envbundle.sh`; bundle and job are pushed over
   `flyctl ssh console -C` and `flyctl ssh sftp`.
4. **Build.** `fly/builder-runner.sh` is the one process on the machine. It
   waits for the push, warms up the checkout if it is missing, then runs
   `BUILDER_EXEC=1 BUILDER_NO_MERGE=1 … bin/run-build.sh`, heartbeats every 60s
   and writes `/run/harness/RESULT`.
5. **Reap.** On a RESULT the pool pulls the artifacts and either REUSES the
   machine for the next queued job or destroys it. A spawn costs about five
   minutes, which is why the runner idles for ten before it autostops.
6. **Ingest.** `bin/fly-results-ingest.sh` (hub, `*/2`) pulls artifacts into
   `builds/fly-<p>-<KEY>-<ts>/`, clears the builder and marks custody. With the
   direct path armed it relays nothing — see the stage map below.
7. **Death.** A machine that stops or goes heartbeat-stale with no RESULT gets
   its job requeued at `attempt+1`. The pool gives up at the SECOND observed
   death rather than spawning into the same wall forever.

## The stage map

This is the one place it is stated. Everything else should point here.

**On the Fly machine:** PLAN, EXECUTE, the REVIEW lenses, PR creation, preview
QA, and the what-shipped board close-out (`bin/board-closeout.sh`, called from
`bin/run-build.sh` when `BUILDER_DIRECT_ON=1` — the default). Set
`BUILDER_DIRECT=0` or `touch flags/builder-direct-off` and the close-out comment
comes from the owning box's triage session instead, off the RESULT that
`bin/fly-results-ingest.sh` relays. The vocabulary for both paths is
`bin/lib/builder-direct.sh`.

**Never on the Fly machine:**

| stage | where it runs |
|---|---|
| merge | the box's `bin/merge-queue.sh`, the hub's `bin/merge-conductor.sh`. A builder runs with `BUILDER_NO_MERGE=1` and the tier-1 merge branch of `bin/run-build.sh` is skipped outright. |
| triage | `bin/run-triage.sh`, per project, on the owning box |
| pre-plan | `bin/preplan-tick.sh`, on the owning box |
| external-PR review | `bin/review-prs.sh` on boxes, `bin/review-autopilot.sh` on the hub |
| deploy verify | `bin/deploy-train.sh`, on the owning box |
| post-merge QA | `bin/postmerge-qa.sh`, on the owning box |
| orchestrator | `bin/orchestrator-burn.sh`, hub only |

All of those are `cron/*.cron` lanes. None of them has a Fly path.

## What carried over from the trial

- **Transport is Fly's own ssh/sftp**, not tailnet ssh (Tailscale-SSH stalls in
  userspace mode). `fly sftp put` refuses to overwrite and swallows errors, so
  every push goes to a fresh temp path and is `mv`'d into place over
  `flyctl ssh console -C`, with the outcome checked explicitly. Tailnet is used
  for reachability checks only.
- **The env bundle is a whitelist, and it is the isolation choke point.**
  `bin/fly-envbundle.sh` runs on the hub, pulls the project's secrets from its
  OWNING watcher box at dispatch time, assembles them in a mktemp dir and
  shreds it right after the push. The hub never keeps another project's
  secrets on disk. `ORGO_API_KEY`, `TELEGRAM_*`, the `FLY_*` tokens, `TS_AUTHKEY_*`
  and any other project's env never leave the hub. Blanket copy is forbidden —
  explicit keys only.
- **Two credentials in that bundle are per-machine.** `bin/fly-pool.sh` replaces
  the `GH_TOKEN` line (a repo-scoped App token) and the
  `CLAUDE_CODE_OAUTH_TOKEN` line (a leased account from
  `bin/lib/pool-account.sh`) in its own copy before it is pushed.
- **Secrets are pushed at machine start, never stored as Fly secrets**, and they
  live on tmpfs (`/run/harness-env`), which the runner clears when it goes idle.
- **Per-app deploy tokens.** `bin/fly-api.sh` reads `FLY_API_TOKEN_<PROJECT>`
  from `env/fly.env`; `bin/fly-pool-rollout.sh` mints one per app. One Fly org,
  builders only.
- **The image is baked, not installed per boot.** `fly/Dockerfile` with
  `fly/entrypoint.sh` and `fly/warm-bake.sh`; `bin/fly-image-refresh.sh` rebuilds
  it nightly.

## Rollback and kill

There is no one lever that stops everything. Pick by what you actually want:

| what you want | do this |
|---|---|
| stop spawning for one project, keep draining | `touch flags/pool-halt-<p>` on the hub. `bin/fly-pool.sh` checks it after the reap half, so running machines still finish, get ingested and get reaped; no new machine starts. A reaped machine can still take the next queued job. It is a BRAKE, not an off switch: the next harness deploy clears it (`bin/harness-sync.sh`). |
| pool off for one project | `rm flags/fly-pool-<p>` on the hub. `bin/fly-pool.sh` exits on its first check, and `bin/fly-dispatch.sh` stops standing down, so the project falls back to the fly1 dispatcher. Do it on an idle pool: with the flag gone the REAP half stops too, so a machine mid-build is yours to finish or destroy by hand (`flyctl machine list -a pool-<p>`). |
| Fly off for one project | `rm flags/builder-fly-<p>` on the hub AND on the owning box — `bin/run-build.sh` builds locally again. Jobs already queued still belong to Fly; drain them first. |
| stop the fly1 dispatcher fleet-wide | `touch flags/fly-disabled` — `bin/fly-dispatch.sh` no-ops. It does NOT stop the pool; see "The two flags" above. |
| the fly1 teardown lever | `bin/fly-trial-kill.sh [project\|all]` — LEGACY, single-machine dispatcher only. It sets `flags/fly-disabled`, walks `state/fly/*.json`, stops `builder-<p>` through `bin/fly-api.sh`, removes the hub's `flags/builder-fly-<p>` and prints the `rm` to run on the owning box. It never touches `flags/fly-pool-<p>`, `state/fly-pool/` or a `pool-<p>` app, so on a pool project it stops no pool machine and leaves the pool flag set — use the rows above instead. `--destroy` destroys the app named in `state/fly/<p>.json`, which is the persistent builder, not the pool. |
| drain what is queued | `bin/fly-dispatch.sh --drain <p>` prints the queued jobs as local `bin/run-build.sh` invocations |

## Where to look when it is wrong

- `logs/fly-pool.log` — the spawn/reap loop, one line per decision.
- `state/fly-pool/<p>/` — the tracked machines and their jobs.
- `state/build-queue/<p>/` — what is waiting.
- `builds/fly-<p>-<KEY>-<ts>/` — the artifacts a finished remote build left on
  the hub.
