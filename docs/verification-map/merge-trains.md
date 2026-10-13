# Merge trains (what a day of running them by hand taught the lane)

**What it is:** `bin/batch-resolve.sh` takes approved sibling PRs whose only
conflicts are in files the repo itself marks machine-written, merges them into
ONE union branch cut from the base, regenerates the declared generated files
once, runs the repo's verification contract once, and lands the lot with a merge
commit so every member becomes merged by ancestry. One ticket, one PR, one
review, always: the batching is only in how it merged.

On 2026-09-21 a Mac ran the same idea by hand against `example-org/cromford`
— about fifty-two merges in a day, from a script a fifth the size — and beat the
lane on throughput. BH-1269 is the five things it was doing that the lane was
not.

| what the day learned | why the lane did not have it | the knob |
|---|---|---|
| **Trains of one.** A lone approved PR rides immediately. | A train of one costs exactly the CI run a direct merge costs and keeps the merge-tree probe, the one regenerate and the closure. Waiting for a partner bought none of that. | `BATCH_TRAIN_MIN` (1) |
| **Rebase an inherited red; never rerun it.** | When the base is red every open PR's own CI is red too. GitHub pins a run to the merge commit it was created for, so `rerun-failed-jobs` re-tests the same stale union and comes back red — proved on #1238/#1239/#1235 at 13:54Z. Only a rebase makes a fresh merge ref. | `BATCH_OWN_CI_RED`, `BATCH_REBASE_MAX` |
| **A merged `fix-main-red` PR lifts the freeze now.** | Its own CI ran on the merge ref, which IS the base's next state. Waiting for the detector's next pass over the base cost ~20 minutes per red episode, three times in one day. The head must have CONCLUDED SUCCESS — see "green is not the absence of red" below. | `BATCH_MAIN_RED_CLEAR`, `BATCH_CI_WORKFLOW`, `BATCH_CI_RUN_REQUIRED` |
| **A live skip list.** | An operator could not park one member without stopping the lane. | `state/batch-resolve/<project>/train-skip.txt` |
| **Pre-empt a member's late red.** | A job can conclude failure minutes after the train forms; the train then fails its one run and buys a binary split to rediscover which member it was. | `BATCH_PREEMPT_LATE_RED` |

**Green is not the absence of red.** The first draft of the freeze lift asked
"has anything concluded badly on this head", which is vacuously true on a head
with zero check runs, with everything still queued or in flight, with only
skipped or neutral ones, or with only names the ignore list drops — and a
`fix-main-red` PR admin-merged while its CI is still running is the most likely
way a human lands a hot fix during a red episode. `mrt_head_green` requires all
four: the named CI workflow run (`BATCH_CI_WORKFLOW`), if this repo raises one
for the sha, `completed` and `success`; at least one non-ignored check run;
every one of them `completed`; none red and at least one `success`. Every
unreadable answer is a refusal. The workflow run is asked for as well as the
check runs because check-run COUNTS lie: train #1229 merged at 08:45Z on "0
pending, 6 ok" while its shard jobs were still waiting for a pool runner and had
raised no check runs at all, and the run failed at 08:54Z.

Two runs of that workflow for one sha is ordinary — `mc_kick_ci`'s close/reopen
raises a second `pull_request` run for the same head, and so does a
`workflow_dispatch` — and GitHub lists them newest-first with one entry per run
at its latest attempt, so `run_attempt` ties and ordering by it picks the
OLDEST. The newest by `created_at` then `id` decides, which is the order
`mrt_run_id` already uses, and nothing of that name may still be in flight. A
superseded older run that was cancelled does not hold the freeze.

A sha with NO run of that workflow is refused, not waved through
(`BATCH_CI_RUN_REQUIRED`, default 1). That is this fleet's own shape rather than
a hypothesis: a push made with the App token raises no `pull_request` run, so a
fix PR landed that way carries a `Summary` success, a neutral Mergify run and
zero `Harness CI` runs — a head whose shards never ran, which the check-runs
half alone reads as green. The knob at 0 restores the check-runs-only fallback
for a repo that genuinely raises no workflow of that name, where requiring one
would make its freezes unliftable for ever. Either way the lane SAYS why a
freeze stands, naming the fix PR and the reason.

The ignore list is `^Mergify` rather than a full name because that reporter has
shipped as both "Mergify Merge Protections" and "Mergify Merge Queue": a name
that drifts out of the list makes a queued Mergify run read as "this head is
still pending", and the lift then never fires at all.

**Both copies of `mc_batch_should_spawn`.** `bin/lib/merge-conductor-lib.sh`
sources `bin/lib/mc/queue.sh` and then re-defines the function further down; the
later definition wins, so a knob added only to the module is invisible to
`bin/merge-conductor.sh`. Until BH-477 deletes the duplicate the two are edited
together, and the suite sources the lib the way the conductor does and drives
the RESOLVED function rather than grepping either file. It resolves
`BATCH_TRAIN_MIN` through `lane_knob`, so the threshold the lane reads and the
spawn decision cannot come from different rows.

**What a carry is allowed to be.** A rebase moves the head, and a head-bound
APPROVE does not move with it unless something says the patch is the same patch.
`mc_patch_id_rebind` is the strict form — `git patch-id` over the whole diff,
context lines included, so a neighbouring line that changed on the base breaks
it. `mrt_carry_ok` (`bin/lib/mc/train.sh`) is the form the day used: the sorted
set of the patch's OWN added and removed lines must be identical, and
context-only drift is allowed. The repo's declared generated files are excluded
from that set, because they are a function of the tree and are rebuilt on both
sides. It is still conservative by construction: it can say "this is the same
patch" and it can never say "close enough", and the rebase is thrown away rather
than pushed when it does not hold.

**And the renders are settled before the push.** A rebase leaves a generated
index stale by construction — the member could not have predicted what the base
would add to it — so `mrt_regen_settle` runs the repo's own regenerate commands
over the rebased tree and commits the result, which is what `carry.sh` did and
which does not touch the carry (generated paths are outside the identity). What
is still refused is a generator with no fixed point: a second run that still
moves the files means the pushed head would be red for a brand-new reason, on a
head that is no longer behind the base and that this lane would therefore park
and never retry.

**What the freeze still costs.** BH-945's property is that a red base stops
this lane before it spends anything — no token probe, no clone, no fetch, no
union typecheck, and nothing written. The lift adds exactly one bounded READ
under a freeze, because a lane that may never ask cannot learn that the fix has
landed. `tests/main-red-box-freeze.bh-945-test.sh` asserts both halves: every
call a freeze buys is a read on the fix-probe endpoints and none is a write,
and with `BATCH_MAIN_RED_CLEAR=0` there is no GitHub call at all.

**One gap, tracked separately (#1281).** `bin/main-red-detector.sh`'s STREAK
arm reads completed runs only, so in an episode where the base was red on two
consecutive runs it can re-raise the freeze this lane just lifted — and rewrite
the flag file, whose mtime is this lane's lower bound, so the merged fix is then
excluded. The behaviour degrades to the pre-BH-1269 wait plus one spurious page;
the fix is to give that arm the same in-flight suppression the TIP arm already
has.

## N trains at once, on disjoint file sets (BH-1270)

One train in flight bounds the base branch's merge rate at one CI run — about
seventeen minutes on 2026-09-21 — and **nothing about that wait is a safety
property**. Two unions cut from the same base only meet if they TOUCH THE SAME
FILES, and the conductor has known what each PR's ticket set out to touch since
BH-475: `plans/<project>-<KEY>/planned-files.txt`, the same list
`bin/overlap-guard.sh` and `bin/overlap-schedule.sh` read. So the pass
partitions its candidates into groups that cannot meet and opens one train per
group in ONE tick.

**The rule, in one sentence: two candidates that could ever conflict must ride
the SAME train, never two trains at once.** That is why `mrt_group_plan` is a
connected-component walk and not a bin-packing — overlap is an EDGE, a component
is indivisible, components are disjoint by construction, and merging two
components into one group is always safe because a group is just a bigger train.
Three things count as "could ever conflict":

| | why |
|---|---|
| their planned-file sets intersect (file equals file, or a directory of one contains a file of the other — `bin/conflict-check.sh`'s rule) | the two unions would meet |
| they touch the same MODULE directory (`BATCH_MODULE_DIRS`: `bin/lib/*/`, `bin/lib/`, `bin/`, `worker/jobs/src/routes/`, `worker/jobs/src/lib/`, `console-ui/src/screens/`) | two PRs editing different files of one module are a textual non-conflict and often a semantic one, and it is that module's own suite that would catch it |
| either one's set could not be determined at all | an unjudged candidate conflicts with EVERYTHING, which collapses the partition back to one group — i.e. to BH-1269, which is the conservative arm and the one a missing plan must land on |

The list deliberately contains the repo's most-coupled directories: `bin/lib/`
(the top-level libs every lane sources), `bin/` (the lane scripts) and
`worker/jobs/src/lib/` (the worker's shared code) were in NO module until
BH-1306, so two PRs editing the files the whole fleet runs on could ride two
trains at once. Order matters — the first pattern that matches wins, so the
`*/` child pattern precedes its plain parent and `bin/lib/mc/x.sh` is still
`bin/lib/mc/`, never `bin/lib/` and never `bin/`.

**A set is read from the DIFF first, then the plan, then the build record**
(BH-1306). The diff is the patch the PR actually carries and the thing its
review was of; `plans/<project>-<KEY>/planned-files.txt` is a PREDICTION of that
patch written before a line was typed, and the build record holds a copy of the
same prediction. Reading the prediction first meant a PR whose patch grew past
its plan was partitioned on files it does not touch — and, worse, was called
disjoint from a sibling it really meets. A diff that is EMPTY once the declared
generated files come out is not an answer, so the plan and the record still
speak for a regen-only PR; only a candidate with no readable answer anywhere is
UNJUDGED.

**The declared generated files are SUBTRACTED from every set**, with the same
exclude list the carry identity uses. Every member of every train rewrites the
registry this lane regenerates — that is the entire tail it exists for — so
counting those paths would make every candidate overlap every other one and the
partition would collapse to one group on the only repo the feature is for. A
conflict there is not a reason to serialise: it is resolved by the one
regenerate each union already runs, and by the re-form below when the other
group lands first.

**Re-form on the new tip; never re-review.** When one group's train lands — or
anything else moves the tip — the other group's union is in one of two states:
DIRTY (it no longer merges) or BEHIND (it still merges, because its merge base
is the OLD tip, but it was verified against a base that does not contain what
landed). **Both re-form.** The BEHIND half is BH-1306 and it is the one that
could put main red: GitHub calls such a PR MERGEABLE/CLEAN, `bin/merge-queue.sh`
lands a train PR without reading any CI, and this repo's branch protection
declares no required checks — so nothing but this lane ever runs the two
changes' union through the verification contract. Reviewer probe P7 of #1297:
a contract that is red only when both feature files exist gives two trains that
are each green alone and a main that is red after both land. "Behind" is asked
of git (`merge-base --is-ancestor <tip> origin/<union>`), not of GitHub, because
`mergeStateStatus=BEHIND` is only reported under strict required status checks,
which is exactly what this repo does not have. An unreadable answer — no auth,
no fetch — is never read as behind: the train is left where it is and one line
says so. Neither is an UNREAD PR state: the trigger fires only when GitHub
answered `OPEN`, because a train that has in fact MERGED reads as behind by
construction (the tip contains the union, not the reverse), so acting on a
failed `gh pr view` would re-form — or close — a train that is already landed.
The DIRTY arm needs no such guard, since a `mergeable` of `CONFLICTING` cannot
be read out of a failed call.

**A BEHIND train that cannot be re-formed is CLOSED, not left to its age
budget.** A DIRTY train is harmless while it waits, because nobody can merge a
union that does not merge; a BEHIND one is landable right now. So when the
re-verify on the tip is RED, when `BATCH_REFORM_MAX` is spent, or when too few
members survive to rebuild it, the train PR is closed, its members released and
excluded at the heads they rode with, its branch deleted and one alert raised.
`BATCH_REFORM_MAX=0` turns the whole thing off, behind included, and a gated
pass (`flags/batch-resolve-off`, the BH-945 main-red freeze) never even asks —
the behind check sits inside the same guard, so it costs a gated tick nothing.
An ungated tick with an open, non-dirty train does pay for it: one auth and two
fetches, memoised per pass.

**A re-form is never a re-review.** Its members have not moved — each is still
at the head its own head-bound APPROVE names — so nothing any
verdict is bound to has changed, and what moved is the BASE, which the union
branch was cut from and which nothing ever reviewed. `reform_train` rebuilds the
union on the new tip and force-pushes the SAME branch: same PR, same queue
entry, same D1 row, same `created_at` and therefore the same age budget, a fresh
CI run, and no re-review of anything. A member whose branch HAS moved is dropped
instead (its approval no longer binds to what is on the remote), and the push is
`--force-with-lease` on the union sha the record remembers, because a train
branch nobody else should be writing to is still a branch.
`BATCH_REFORM_MAX` bounds it, so a repo whose base moves faster than a union
verifies stops chasing it and falls back to the age budget.

**The CI pool is the other bound.** N trains in flight raise N concurrent runs
of the repo's workflow, and this repo's run is eight shard jobs wide (two 4-way
matrices). Two of those on a pool of eight runners does not make anything
faster: the second run's shards QUEUE, and a queued job is indistinguishable
from a slow one (`docs/CI-RUNNERS.md`). So the effective cap is
`min(TRAIN_PARALLEL, floor(BATCH_CI_RUNNERS / BATCH_CI_SHARDS))`, with
`BATCH_CI_RUNNERS` 0 — the default — meaning no pool size is declared, which is
this fleet's honest state: CI runs on the `CI_RUNNER` repo variable, hosted,
whose concurrency is the account's and not ours to count.

**And a train already in flight holds its own files.** A new union must not
touch a file a live train carries: that train's members are about to land and
the new one would be cut from a base that does not contain them. One in-flight
member whose set cannot be read stands the whole pass down to the
one-train-at-a-time behaviour — the honest answer to "I cannot tell what that
train holds" is BH-1269, not a guess. The lane also honours its OWN
`mc_batch_hold` on a candidate now, which before BH-1270 it never had to: the
pass stopped dead at the first in-flight train and could not reach that line.

**`TRAIN_PARALLEL=1` is BH-1269, byte for byte** — one group, every candidate in
it, in the order the pass found them, capped at `BATCH_MAX_MEMBERS`. No
partition is computed that can change that answer.

**Where the trains are visible.** Every train writes a `merge_trains` row —
members, union sha, the one CI run id, and how it ended — through
`PUT /api/merge-trains`. Before that the only record was
`state/batch-resolve/<project>/train-*.json` on one box, so Mission Control
could not show a train at all and a box rebuilt mid-flight lost the members.
The file record is still what the lane reads; the row is what everything else
reads, and `merge_train_put` fails open like every other jobs-client call.

**How an operator reaches it:** the lane has no crontab line of its own —
`bin/merge-conductor.sh` spawns it — so it is stopped with
`bin/harness-ctl.sh off batch-resolve [<project>]` (or `flags/batch-resolve-off`,
which still works). One member is parked by appending its number to
`state/batch-resolve/<project>/train-skip.txt`, which is read live.

**How to drive it:**

| what | how |
|---|---|
| a train of one; the rebase-not-rerun recovery, its carry, its two refusals and its render settle; the second red parking a PR; the `fix-main-red` lift and the five shapes that must NOT lift it; the live skip list; the late-red pre-emption and the run cancel; the `merge_trains` rows and the client verbs; the fleet lane gate; the spawn decision the conductor resolves | `bash tests/batch-resolve-trains.bh-1269-test.sh` |
| the union branch, the deferred regenerate, the binary split, the settle and the close-out | `bash tests/batch-resolve-test.sh` |
| two disjoint sets forming two trains in one tick; overlapping and same-module candidates riding one; the re-form on the new tip and its budget; a red group not holding a green one; `TRAIN_PARALLEL=1` reproducing BH-1269; the pool cap; a live train's files being off limits | `bash tests/batch-resolve-trains.bh-1270-test.sh` |
| a BEHIND (not dirty) train re-verified on the tip before it lands, closed when that verification is red or its budget is spent, and left alone when nothing moved, when the pass is gated or when `BATCH_REFORM_MAX=0`; the diff beating the plan and still falling back to it on a regen-only patch; `bin/`, `bin/lib/` and `worker/jobs/src/lib/` as modules | `bash tests/batch-resolve-trains.bh-1306-test.sh` |
| a lead PR with a box APPROVE kept out of a train until a lead MERGE row stands on its exact head; a held ticket's PR kept out; an unreadable hold or lead row failing closed with one lane-wide alert; the App token's expiry read before the union is pushed (BH-1630) | `bash tests/batch-resolve-lead-fence.bh-1630-test.sh` |
| the two `/api/merge-trains` routes over a real SQLite database, including `train_group` and the additive column on a database that predates it | `cd worker/jobs && npm test` (`test/merge-trains.bh-1269.test.js`) |
| every knob has a registry row and the lane really gates | `bash tests/lanes-registry-test.sh` |
