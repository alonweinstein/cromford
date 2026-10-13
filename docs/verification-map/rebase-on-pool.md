# Pool rebase (`REBASE_ON_POOL`)

**What it is:** the per-project flag that moves a conductor rebase off the hub
and onto a pool machine. A rebase costs a clone, a worktree, a typecheck and a
unit run; on the hub that is serial work on the one box that also runs every
tick. Under the flag the hub writes a queue row and keeps only what it must own
— the lease on the sha it read, the approval rebind, and the merge.

**Nothing rebases on a pool yet.** #540 (BH-486.0) ships the CONTRACT: the flag
read, the key, the rc vocabulary, the RESULT words and two stubs whose bodies
land in the sibling slices. `mc_pool_rebase_enqueue` returns 7 ("queue
unreachable, nothing spent") on every call, so a project that turns the flag on
today gets rc 7 from `mc_rebase` and its callers' existing default arms park the
PR — the conductor at `NEEDS_REBASE "rebase setup failed rc=7"` (one attempt per
PR and head, recorded in `attempts.txt`), the resolver at `br_setup_blocked`.
**The flag ships OFF**, and with it off the rebase path is byte-identical to
before.

**How an operator reaches it:** there is no new lane and no new cron line. It is
a branch inside `mc_rebase` in `bin/lib/mc/rebase.sh`, which every
rebase in the fleet already goes through: the tick's inline path
(`bin/merge-conductor.sh`, `MC_DETACHED_REBASE=0`), `mc_rebase_run` (the
detached job body, the default), `br_mechanical` in `bin/blocked-resolver.sh`,
and `bin/rebase-train-ahead.sh`.

```sh
. /root/harness/bin/lib/merge-conductor-lib.sh (the shim over bin/lib/mc/)
mc_pool_rebase_enabled project-1 && echo pool || echo hub
mc_pool_rebase_key 21 aaaaaaaabbbbcccc      # RB-21-aaaaaaaa
```

**How to drive it:**

| what | how |
|---|---|
| the whole contract — guard, flag read, key, both stubs, the RESULT words | `bash tests/rebase-on-pool-contract-test.sh` |
| the flag-off path is unchanged (the guard sits above `mc_git_auth`) | `bash tests/mc-rebase-credentials-test.sh` |
| the reap gate accepts the five RESULT words and still refuses a flyctl panic | `bash tests/fly-pool-result-gate.bh-540-test.sh` |
| the suite reads no clock and no network | `bin/test-determinism-lint.sh tests/rebase-on-pool-contract-test.sh` |

**Files it names on a live box:**

- `env/<project>.env` — `REBASE_ON_POOL=1` turns it on for that project. An
  environment value wins over the file when it is set to anything non-empty.
- `flags/fly-pool-app-<project>` — the same flag `bin/fly-pool.sh` requires
  before it spawns anything. Without it the flag is a no-op fallback.
- `logs/merge-conductor.log` — `REBASE_ON_POOL=1 but no pool app for <project>;
  rebasing on the hub`, one line per call, no alert.

**Knobs:** `REBASE_ON_POOL` (exactly `1` is on; empty, unset or anything else is
off) and `MC_REBASE_POOL_TIMEOUT_SECS` (default 5400 — a pool rebase job older
than this is failed; nothing reads it until BH-486.2).

**What must never regress:**

- **The guard runs before `mc_git_auth`.** Under the flag no token is resolved,
  no askpass helper is written, no clone and no worktree appear. Section (b) of
  the suite asserts on the git argv file, the askpass file, `$H/tmp/conductor`
  and `$TMPDIR/mc-rebase-*` — not on source text.
- **Flag off is today.** Every caller reaches git exactly as it did; the six
  conductor suites are the witness.
- **`1` without a pool app is a fallback, not a page.** One `mc_log` line per
  call and the hub does the rebase. An alert here would fire every `*/5` tick.
- **A leading space is still a mexec miss.** `REBASED`, `CONFLICT` and
  `GATE_RED` are bare first-column words in `RESULT_PREFIX_RE`; adding them must
  not make a flyctl panic that merely contains one read as a RESULT.

### Contract (BH-486.0)

Shipped by #540. `MC_REBASE_POOL_TIMEOUT_SECS`, `mc_pool_rebase_enabled`,
`mc_pool_rebase_key`, the `mc_pool_rebase_enqueue` (rc 7) and
`mc_pool_rebase_apply` (rc 1) stubs, the `mc_rebase` guard and its rc 6/7
contract line, `bin/lib/rebase-job.sh` with the job.json shape, the RESULT
vocabulary and the `rebase_job_run` stub, and the four RESULT words in
`bin/result-prefix-ok.sh`. Suite: `tests/rebase-on-pool-contract-test.sh`.
Live-box files: `env/<project>.env`, `flags/fly-pool-app-<project>`, the
`no pool app` line in `logs/merge-conductor.log`.

### Hub conductor + resolver (BH-486.2)

Shipped by BH-541. The two stubs above now have bodies and three call sites read
their rcs:

- **`mc_pool_rebase_enqueue`** writes the job file FIRST (under
  `state/merge-conductor/rebase/.lock`, the same lock the detached lane takes),
  then one `queue_put` row keyed `RB-<num>-<head8>` with `ticket_id=<num>`,
  `target=fly` and `meta={kind:"rebase",slug,url,pr,branch,head,base:"main"}` —
  no token, no env value. Then it forgets this head's `rebasedone` /
  `rebasefailed` attempt lines (a queued row owes a fresh read) and writes a
  `queued` row to the jobs ledger under `<url>@<head>`. rc 6. A refused or
  unreachable queue removes the job file again and answers rc 7: nothing spent,
  no attempts line, the tick budget handed back.
- **The `pool` job state.** `mc_rb_state` reads `status:"pool"` as `running` on
  its age alone until `started_at + MC_REBASE_POOL_TIMEOUT_SECS` (default 5400)
  and `stale` after that. `mc_lane_state` is untouched, so the pid lanes keep
  the pid rule. A re-offer of a head already in `pool` keeps its `started_at`,
  or the timeout would never fire.
- **`mc_pool_rebase_apply`** turns a machine's RESULT into that job file. THE
  KEY WINS OVER THE FILE: the `PR:` line is used only when it names the key's
  number and the `HEAD:` line only when it is 40 lowercase hex starting with the
  key's head8; anything else is dropped, so no RESULT can rebind another PR's
  approval or steer the job-file path. The recorded rc is `mc_rebase`'s (0
  rebased, 1 conflict, 2 gate red, 3 lease rejected, 4 setup failed, 5 pushed
  but the approval did not move), and anything unparseable is 4, never 0. rc 0
  requires `job_verdict_rebind` to have answered 0; the record's `reviewed-sha`
  is rewritten only then, and only when the record already had one. Ledger
  statuses: `queued`, `REBASED`, `CONFLICT`, `GATE_RED`, `LEASE_REJECTED`,
  `SETUP_FAILED`, `TIMED_OUT`.
- **The conductor.** The `NEEDS_REBASE` arm takes the INLINE path under the flag
  — no `mc_rebase_spawn`, no setsid child, no hub worktree — and `rebase_result`
  gained arm 6 (`REBASING`, reason `pool rebase queued (RB-…)`) and arm 7
  (`NEEDS_REBASE`, reason `pool queue unreachable, retry`). A `pool` job past
  its timeout is failed by `rebase_consume` with a `TIMED_OUT` ledger row and
  the row goes back to `NEEDS_REBASE`; a RESULT that arrives later still
  applies, because a head a machine pushed is a fact.
- **The resolver.** `br_mechanical` arm 6 records the mechanical rung (it RAN —
  a queue row exists), moves the conductor row to `REBASING` so the next tick of
  the lane cannot start a fix round on top of a running rebase, and says so. Arm
  7 spends no rung and writes no state.

**How to drive it:**

| what | how |
|---|---|
| enqueue, the `pool` state, the RESULT parser, the driven tick, the consume | `bash tests/rebase-on-pool-test.sh` |
| the resolver's two pool arms | `bash tests/blocked-resolver.bh-541-test.sh` |
| both suites read no clock and no network | `bin/test-determinism-lint.sh tests/rebase-on-pool-test.sh tests/blocked-resolver.bh-541-test.sh` |

**Files it names on a live box:** `state/merge-conductor/rebase/<owner_repo>_<num>_<head>.json`
(`status:"pool"`, `rc:"-"`, `pid:0`) and its `.out` sibling;
`state/merge-conductor/attempts.txt` (`rebase <key> <head>`, one per head);
`logs/merge-conductor.log` (`pool rebase queued as RB-…`, `pool rebase running
on a pool machine`, `produced no RESULT within …s`);
`logs/blocked-resolver.log` (`MECHANICAL — pool rebase queued for …`).

**Not proven on a pool.** The flag ships OFF and nothing in this slice turns it
on. `bin/fly-pool.sh` does not yet read `meta.kind=rebase` (BH-486.3), so a row
queued today would be claimed as a ticket build of `ticket_id=<num>` —
`REBASE_ON_POOL` must stay unset fleet-wide until that lands. The live proof
(flag on for one project, one real DIRTY PR, a RESULT from a machine, hub `tmp/`
flat) is OWED after BH-486.3 and BH-486.4 merge; everything above is proven by
the two fixture suites, which drive the real `bin/merge-conductor.sh` and
`bin/blocked-resolver.sh` against a scratch harness.

### Pool transport (BH-486.3)

Shipped by #542 (board title BH-486.2). Two sites, both additive.

**Dispatch.** In `bin/fly-dispatch.sh`'s materialise loop — the one that turns a
`build_queue` row into `state/build-queue/<p>/<KEY>.json` — a row whose `meta` is
an OBJECT with `kind == "rebase"` writes that whole object onto the queue file as
a top-level `rebase:{…}`, appended after `stack_base` and `hotfix`. The object
travels whole because the machine reads it whole: `bin/lib/rebase-job.sh`
documents `job.json`'s `rebase:{kind,slug,url,pr,branch,head,base}`, and neither
`spawn_one` nor `next_job_or_destroy` unpacks the file — they push it as it is.
Every other row — no `meta`, a `meta` that is a string, `kind:"build"`, even
`kind:"Rebase"` (the test is case-sensitive) — writes byte-for-byte the file this
loop wrote before.

Both meta shapes are accepted. The producer writes the fields FLAT
(`{kind:"rebase",slug,url,pr,branch,head,base}`); `bin/lib/merge-conductor-lib.sh` (the shim over `bin/lib/mc/`)'s
comment documents the NESTED `{kind:"rebase",rebase:{…}}`. The materialise
collapses a nested object to the flat one (keeping `kind`) BEFORE it validates,
so either shape is held to the same checks below and lands as the same
`rebase:{…}` on the queue file. When a row carries both, the nested object wins.

An unusable rebase object is **refused, not dropped**. `slug`, `branch`, `base`
and `head` are held to the same charset `stack_base` is (`A-Za-z0-9._/-`) and
`pr` must be digits; a field that fails closes the queue row `failed` with reason
`rebase meta rejected (<field>)`, writes ONE `logs/ALERTS.log` line naming the
key and the field, and writes no queue file at all. Dropping the field the way
`stack_base` drops would leave `{ticket_id:"21",key:"RB-21-…"}`, which the pool
dispatches as an ordinary BUILD of ticket 21 — a PR and a board comment nobody
asked for. `failed` rather than a release, because a release re-offers the same
bad row every two minutes forever.

**Reap.** In `bin/fly-pool.sh`, between `RLINE=$(head -1 …)` and the deferral
branch, inside the `# >>> pool rebase reap` / `# <<< pool rebase reap` markers: a
first word of `REBASED`, `CONFLICT`, `GATE_RED` or `REBASE_*` calls
`mc_pool_rebase_apply <project> <key> <result-file>` — the machine's own full
relayed RESULT file, not the head-1 — and then `continue`s. Nothing below runs
for these words: no `state/remote-results`, no relay ssh, no merge-queue row, no
PR-verify gate. `bin/lib/merge-conductor-lib.sh` (the shim over `bin/lib/mc/`) is sourced at the top of the
file, type-guarded on `command -v mc_pool_rebase_apply` beside the
`bin/jobs-client.sh` source.

- **rc 0** — `REBASE` sentinel in the build dir, the queue row closed `done`, a
  `reaped rebase <key>` line in `logs/fly-pool.log`, and one `beat.sh` with
  `stage:"pool_rebase"` (never `pool_result`).
- **nonzero** — ONE `logs/ALERTS.log` line naming `$LOCAL/RESULT`, the queue row
  left `claimed`, no `REBASE`, no beat. `bin/jobs-watchdog.sh` requeues only the
  `triage`/`preplan`/`pr-*` classes, so a `claimed` `RB-` row after a refused
  apply is **manual cleanup**.
- **rc 127** — the box has no `bin/lib/merge-conductor-lib.sh` (the shim over `bin/lib/mc/`) (a half-synced
  sync). `RBRC` is seeded 127 BEFORE the guarded call, so a missing function
  takes the refusal path and never falls through to the build one.

**Dead or deferred, with no RESULT.** An `RB-` machine that dies (state `""`,
`stopped`, `destroyed`, `failed`, `suspended`, or a heartbeat over 900s) or that
answers `BUILD_DEFERRED` closes its queue row **`failed` and is never requeued**.
Both of the ordinary arms rebuild the queue FILE out of the machine json, which
carries no `rebase` — so a requeued `RB-` row reaches the next machine as
`{ticket_id:"21",key:"RB-21-…"}` and is dispatched as an ordinary BUILD of
"ticket 21", the very shape the materialise above refuses. So instead: the row is
closed `failed` with a reason that contains neither `died N times` nor
`deferred N times` (`br_from_queue`'s two triggers in `bin/blocked-resolver.sh`),
NO `state/build-queue/<p>/<KEY>.failed.json` is written (that file is the
resolver's other trigger — it rebuilds `ticket_id`, which here is the PR number),
ONE `logs/ALERTS.log` line is written naming the key and why, and the machine is
destroyed and its tracking file removed exactly as for any other key. The dead
arm runs before the `deaths >= 2` park, so neither death count writes a
`.failed.json`. No `fleet_alert` and no `pool_deferred` beat — both would put a
rebase on the console as a pool BUILD. The deferred arm's row reason is a
CONSTANT sentence: the runner's own RESULT text rides in the ALERTS line and the
log, never in the ledger row (BH-986).

Nothing in the pool retries. What recovers the PR is the HUB JOB FILE, and both
arms now act on it: `mc_pool_rebase_fail "$P" "$KEY" "<reason>"` marks
`state/merge-conductor/rebase/<owner_repo>_<num>_<head>.json` `failed` with
`rc: 4` (rc 0 = at least one `pool` file marked; rc 1 = none found, or every one
was already `done`/`failed`, which is never rewritten — a late machine RESULT is
a fact). With that file `failed`, `bin/merge-conductor.sh`'s `rebase_consume`
failed/stale arm parks the PR in `NEEDS_REBASE` on its NEXT tick, and the
`NEEDS_REBASE` TTL (`mc_ttl`, `MC_TTL_NEEDS_REBASE`, default 1800s) is then
what forgets this head's attempt marker and lets a later tick queue a fresh
rebase. Marking the file failed deliberately does NOT clear that marker or
remove the file — the TTL stays the pacing, so a flapping pool cannot buy a
machine for the same head every tick.

The ledger row it writes beside the failed file is keyed on `<url>@<40-sha>`,
read back from the job file's own `head_sha` — the key `mc_pool_rebase_enqueue`
wrote. When that field is missing the row is SKIPPED rather than keyed on the
8-hex `head8` from the queue key: an 8-hex key matches no row any reader has,
so it would only add an orphan. The file is still marked `failed`; only the row
goes unwritten, which is the rule `mc_pool_rebase_apply` already follows.

On a box where the lib defines no `mc_pool_rebase_fail` the `command -v` guard
misses, nothing is marked, and the ALERTS line says so: recovery then waits for
`MC_REBASE_POOL_TIMEOUT_SECS` (default 5400s) to fail the job first. Both texts
are in the arm, one per rc, because a `pool` job file reads as `running` to
`mc_rb_state` on its age alone. Every other key keeps today's requeue and
deferral behaviour untouched.

**Sentinel.** `COMMENTED` is stamped on BOTH paths. `bin/pipeline-health.sh`
check 4 (`# >>> no board close-out`) skips a dir on `RELAYED`, `DEFERRED`, a
`BUILD_DEFERRED` head or `COMMENTED`; check 5 (`# >>> empty url`) skips on
`RELAYED` or `COMMENTED`; `bin/orphan-reconcile.sh`'s `UNSWEPT` loop and
`bin/triage-gate.sh`'s results-sweep gate (which globs `builds/pool-<p>-*`) both
read "has a RESULT and no `COMMENTED`". `COMMENTED` is the one file all four
honour. `DEFERRED` would claim the build
stood down and `RELAYED` that custody moved to a box; both are false. `REBASE`
is stamped on rc 0 only.

**Accepted idle.** `bin/fly-pool.sh`'s autoscale counts queue FILES, so an `RB-`
file spawns one machine under the per-project cap, and `spawn_one` takes a
`pool_account_lease` that idles for the length of one rebase. Cost rows need no
new code: `push_pool_cost_rows` runs above the rebase branch.

**Files it names on a live box:**

- `state/build-queue/<p>/RB-<num>-<head8>.json` — the queue file, with `.rebase`.
- `builds/pool-<p>-RB-<num>-<head8>-<stamp>/` — `RESULT` always, `COMMENTED`
  always, `REBASE` only when the apply returned 0. A `BUILD_DEFERRED` dir carries
  `DEFERRED` **and** `COMMENTED`, and no `REBASE`.
- `logs/fly-pool.log` — `reaped rebase RB-…`, `rebase RB-…: apply refused rc=…`,
  `rebase RB-…: deferred (…) — row failed, not requeued`, or a dead-machine line
  ending `-> rebase row FAILED, not requeued`.
- `logs/ALERTS.log` — the refusal line, the dispatch's `rebase meta rejected`, or
  the one `row is FAILED and NOT requeued` line from the dead/deferred path.
- `state/merge-conductor/rebase/<owner_repo>_<num>_<head>.json` — after a
  dead/deferred reap it reads `"status":"failed","rc":"4"`, flipped from `pool`
  by `mc_pool_rebase_fail`, with `head_sha` and `started_at` preserved.
- No `state/build-queue/<p>/RB-….failed.json` is EVER written — asserted in
  §7.7 and §7.10, because `br_from_queue` would rebuild ticket `<pr>` from it.

**How to drive it:** `HARNESS_TEST_SANDBOX=1 bash tests/rebase-on-pool-reap.bh-542-test.sh`
(§6 drives `bin/fly-dispatch.sh` whole, §7 `bin/fly-pool.sh` whole) and
`HARNESS_TEST_SANDBOX=1 bash tests/rebase-on-pool-reap.bh-986-test.sh` (the hub
job file flips to `failed` and the two ALERTS texts, both arms, with and without
`mc_pool_rebase_fail` on the box).

**What the enqueue and the apply do today.** Both have real bodies, and three
call sites read them. `mc_pool_rebase_enqueue` (`bin/lib/mc/rebase.sh`)
writes the `pool` job file, `queue_put`s the `RB-` row with `meta.kind=rebase`,
clears the two `rebasedone`/`rebasefailed` attempt markers and returns **rc 6**
(queued, nothing cloned on the hub); every refusal — no PR number in the url, an
unwritable `$MC_RB_DIR`, no queue client sourced, an unreachable queue — is
**rc 7**, which spends nothing and is retried on the next tick.
`mc_pool_rebase_apply` returns **rc 0** when the job file was written (its own
`rc` field carries `mc_rebase`'s verdict, and an unreadable RESULT is rc 4, never
0) and **rc 1** when nothing could be written, which leaves the queue row
`claimed` and alerts. The callers: `mc_rebase` enqueues (so the tick's inline
path, `mc_rebase_run`, `br_mechanical` and `bin/rebase-train-ahead.sh` all reach
it), `bin/fly-pool.sh`'s reap applies, and `bin/merge-conductor.sh`'s
`NEEDS_REBASE` arm reads the result through `rebase_consume`.

**What it still does NOT do.** Nothing on the pool side retries a failed `RB-`
row. A stand-down is marked `failed` on the hub job file and handed back to the
conductor's `NEEDS_REBASE` arm, which is gated by the `NEEDS_REBASE` TTL
(`MC_TTL_NEEDS_REBASE`, default 1800s); there is no immediate second machine for
the same head, by design.

### Machine job (BH-486.4)

Shipped by BH-543 (the ticket calls this slice BH-486.3; the heading keeps the
parent plan's numbering, which the other sections here use). Two halves:
`rebase_job_run` in `bin/lib/rebase-job.sh` — the stub body is gone — and
`run_rebase_job` in `fly/builder-runner.sh`, its only production caller.

**What the body does.** Resolver first: `<harness>/bin/lib/merge-conductor-lib.sh (the shim over bin/lib/mc/)`
must be readable or the job answers `REBASE_SETUP_FAILED no conflict resolver`
and stops. A rebase that cannot resolve must never fall back to a plain merge,
so the check is unconditional and only the `source` is skipped when
`mc_resolve_conflicts` is already in the shell. Then job sanity before any git:
an empty branch, head or base is refused, and so is a branch named `main`,
`master`, or the base itself — this box does not force-push a protected branch,
whatever the job says. Then fetch, worktree, lease, merge, regenerate, gates,
push.

**Step 6b, the regenerate (BH-969).** Between the merge and the gates the body
runs the base's own `## Generated files` commands over the merged tree and
commits the declared paths as one extra commit when the output differs — the
pool twin of `mc_rebase`'s call, so a pooled rebase does not push a head whose
generated file is stale and then fail CI's drift step on it. `node_modules` is
linked before it (a generator may need the deps, and step 7's own idempotent
link stays), the call is `type mc_regen_generated`-guarded so a machine carrying
a pre-BH-969 conductor lib rebases exactly as it did before, and the RESULT line
is unchanged: still `REBASED <sha>` with the sha read after the push. A failing
generator is logged and changes nothing.
See [regen-on-rebase.md](regen-on-rebase.md).

**Why the fetch looks like that.** `fly/Dockerfile` clones the machine's repo
with `--depth 50`, and `--depth` implies `--single-branch`. Two consequences the
fetch has to answer: a bare `fetch origin <branch>` lands in `FETCH_HEAD` only
(no `refs/remotes/origin/<branch>` to check out), and a branch that forked before
the depth boundary has no merge base, so the merge dies on "refusing to merge
unrelated histories". So both refs are fetched by EXPLICIT destination refspec
(`+refs/heads/<ref>:refs/remotes/origin/<ref>`), and `--unshallow` is added only
when `git rev-parse --is-shallow-repository` says `true` — on an
already-complete repo `--unshallow` is fatal, which is exactly what a second job
on a reused machine would hit. `--unshallow` on a large history is the known
cost here; a bounded `--deepen` loop to the merge base is the follow-up, not
this slice.

**Gates need deps.** `typecheck` and `test:unit` run only when
`<repo>/node_modules` exists — the same condition as the hub twin `mc_rebase`.
Warm-up installs with `npm install || true`, so a machine whose install failed
would otherwise report `GATE_RED` and tell the hub the BRANCH is bad when the
problem is the box. No deps is recorded honestly as
`GATE: typecheck=skipped unit=skipped` and the push proceeds; CI on the PR is
the gate, as on the hub. The unit seam: an executable
`<harness>/bin/test-select.sh` is called as `<worktree> <branch> <base>` and
recorded as `unit=select`, otherwise `npm run test:unit`. That file does not
exist in this repo yet — the hook is the seam, not a promise.

**The one write that leaves the machine** is
`git push --force-with-lease=<branch>:<head> origin HEAD:<branch>`. The RESULT is
written AFTER the push returns, from the sha read after it, so a `REBASED` line
without a push cannot happen by construction. A refused lease is
`REBASE_LEASE_REJECTED push` and origin keeps whatever the interloper put there.
No approval rebind happens on the machine — the ledger is the hub's.

**Knobs** (both optional, both with a documented fallback):

- `REBASE_JOB_URL` — the `PR:` line. The signature carries no url, so
  `run_rebase_job` exports it from the job's `.rebase.url`. Unset falls back to
  `https://github.com/<slug>/pull/-`; a number is never invented.
- `REBASE_WT_DIR` — where the per-job worktree is made. Unset uses
  `/data/worktrees` when it exists, else `$TMPDIR`. The worktree is aborted,
  removed, `rm -rf`ed and pruned on every exit path.

**How to drive it:**

| what | how |
|---|---|
| the body and the runner branch, against a real bare origin and a real shallow clone | `bash tests/rebase-job.bh-543-test.sh` |
| the contract the body now fills (resolver guard, RESULT shape, rc) | `bash tests/rebase-on-pool-contract-test.sh` |
| the suite reads no clock and no network | `bin/test-determinism-lint.sh tests/rebase-job.bh-543-test.sh` |

**Files it names on a live pool machine:**

- `/run/harness/job.json` — the job, with the `rebase:{kind,slug,url,pr,branch,head,base}`
  member that routes it here instead of to `run-build.sh`.
- `/run/harness/RESULT` — one of the five words plus the
  `PR:/HEAD:/BRANCH:/BASE:/GATE:` trailer, written with a single `printf` so a
  reader never sees a first line without its trailer.
- `/data/harness/logs/merge-conductor.log` — the resolver's own lines
  (`mc_log`); `mc_init` is never called, so no hub state tree is created.
- `/data/worktrees/rebase-*` — the per-job worktree, gone before the RESULT.

**Still owed, and NOT claimed.** This is BUILT: the suites above are the
evidence. Nobody has watched a real rebase job run on a real machine, because
nothing sends one — `mc_pool_rebase_enqueue` still returns 7 and
`bin/fly-dispatch.sh` carries no `rebase` meta, so the runner branch is
unreachable in production until BH-486.2/.3 land and the flag is turned on. The
manual proof that is owed: flag on for one project, one genuinely dirty PR, the
rebase job in `fly-pool.log`, the PR head moving, and the hub's `tmp/` staying
flat.

### /tmp guard (BH-486.5)

Shipped by #544 (the ticket titles it BH-486.4). Section 11 of
`bin/pipeline-health.sh`, between `# >>> tmp headroom` and `# <<< tmp headroom`,
running on the hub `*/10` with the rest of the lane. A full tmpfs kills every
lane on the box at once and reads like a vendor outage, so the guard pages
early, names who ate the space, and clears itself.

What it does on a tick: read `df --output=pcent` for `/tmp`; at or above
`TMP_FULL_PCT` (default 80) sweep the known scratch classes older than a day —
`wt-*`, `tmp.*`, `old-baseline-*`, `lander-*` and `mc-rebase-*` (the conductor's
hub-clone rebase scratch; a live rebase never lasts a day, `MC_REBASE_POOL_TIMEOUT_SECS`
is 5400) — re-read, and if it is still over, page under `tmpfull:<host>` (TTL
7200s) with the top consumer from `du -xs /tmp/* | sort -rn | head -1`.
`tmpfull` is in `RETRACT_NS`, so the retraction epilogue writes
`RESOLVED tmpfull:<host>` on the first tick the tmpfs is back under the line and
clears the dedupe stamp, which is what makes a recurrence page immediately.

A `df` that gives no reading (no output, header only, an unreadable mount) is
NOT a full disk: no alert, nothing swept, one line in `logs/pipeline-health.log`
naming the missing reading.

**Knobs:** `TMP_FULL_PCT` (default 80, set in `env/global.env` if a box needs a
different line; a non-numeric value is operator error — the comparison fails and
the block stays quiet) and `HEALTH_TMP_ROOT` (default `/tmp`, so the suite can
point the real `find`/`du` at a fixture tree; cron never sets it).

**How to drive it:** `bash tests/pipeline-health-tmp-guard-test.sh` — the block,
`alert()` and the retraction epilogue extracted from the real script and driven
against a scratch tmpfs with stubbed `df`/`du`/`hostname`, plus one case that
runs `bin/pipeline-health.sh` whole.

**Files it names on a live box:** `logs/ALERTS.log` (the page and the RESOLVED
line), `logs/pipeline-health.log` (both, plus the missing-reading line),
`state/health-alerted.json` (the `tmpfull:<host>` TTL stamp),
`state/health-active.txt` (the key while the condition holds).

**What must never regress:**

- **A missing reading pages nothing.** `[ "" -ge 80 ]` is a crash, not a check,
  and a guard that goes quiet on an unreadable mount hides the outage it exists
  to find.
- **Retraction is condition-driven, not tick-driven.** Still full on the next
  tick = no second page inside the TTL and no RESOLVED.
- **The self-clean runs only over the threshold, and only on age.** A fresh
  `mc-rebase-*` is a running rebase; deleting it kills the rebase.
- **The threshold is operator data.** It is read from `TMP_FULL_PCT` on both
  reads, never a constant in the script.
