# Merges over REST (the `gh-pr-merge` ladder)

**What it is:** every merge write in the fleet goes out as
`PUT /repos/{owner}/{repo}/pulls/{n}/merge` with `merge_method=squash` and the
REVIEWED sha, instead of `gh pr merge` (a GraphQL mutation). REST and GraphQL are
separate budgets, and on 2026-09-18 the PAT's GraphQL bucket was empty while REST
was fine: Mission Control commands 15934 and 15937 dead-lettered on
example-org/project-4 #1598 and #1599 with `merge failed: GraphQL: API rate limit
already exceeded for user ID 2220366`, while the same PRs merged instantly over
REST. `bin/lib/gh-pr-merge.sh` is the ladder; `bin/lib/gh-pr-create.sh` (BH-848)
is the lib it is built on and sources.

**THE READS FOLLOWED THE WRITE (BH-994, 2026-09-19).** The merge WRITE moved to
REST on 2026-09-18; the three per-PR READS on the same path had not, and eleven
months of budget headroom did not save them. Between 17:53Z and 18:04Z on
2026-09-19 every READY cromford row (#933, #956, #955, #785) was refused on
four consecutive conductor ticks with `merges=0`, CI green and
`mergeable_state=clean`, because the App installation's GraphQL bucket was empty
while REST on the same token had 3141 of 6600 points. Three reads went over:

| read | where | what an empty answer did |
|---|---|---|
| the PR body, for the dependency gate | `pdg_hold` in `bin/lib/pr-dep-gate.sh` | `dep gate: could not read the PR body — HOLD (rc 2)` — 81 such lines that day |
| the PR body, for "is this ours" | the `# >>> harness pr probe` block of `bin/merge-conductor.sh` | the row reads as "not a harness PR" and the tick walks away from it |
| state + head + base, immediately before the write | the `# >>> pre-merge state guard` block of `bin/merge-conductor.sh` | `not merged: state changed under the tick ()` — the empty parenthesis names no state, and THIS is the one that refused the merges |

All three are now `gh api repos/<slug>/pulls/<n>`. The guard keeps its three
fields in the same order and case (`.state|ascii_upcase`, `.head.sha`,
`.base.ref // ""`), and every fail-closed rule is unchanged: an unreadable
answer still refuses. One nuance lives in the log line only — REST spells a
merged PR `closed`, so a PR merged under the tick now logs CLOSED where it used
to log MERGED. The guard tests `= OPEN`, and neither spelling is OPEN.

**How an operator reaches it:** there is no UI. The lanes below call it from
cron, and the one human-driven surface is Mission Control's merge button, which
posts a `merge_pr` command that `bin/poll-commands.sh` executes.

**The four lanes:**
- `bin/merge-sweep.sh` — the hub's tier-2 sweep, inside
  `# >>> merge over rest (BH-892)`. Passes `HB_SHA`, the sha the review bound its
  approval to, and asks for the branch delete (`--delete-branch`'s replacement).
- `bin/merge-queue.sh` — both landing paths (the union merge train and the serial
  loop) through the `mq_land` helper. Passes `hb_sha <num>` from the ledger.
- `bin/lib/mc/queue.sh` — `mc_merge`, called from
  `bin/merge-conductor.sh` through `mc_merge_locked`. Passes the reviewed head
  and prints the merge sha on stdout on rc 0; the call site captures it
  (`ERR=$(mc_merge_locked …)`) and `conductor_settle` hands it to
  `mc_settle_merged` as its trailing argument, so the settle needs no GraphQL
  read for it. A 405 runs the old state read first, so a PR that landed
  between the list read and the merge call is rc 0, not a mergefail row.
- `HEADBOUND_ENFORCE=0` (sweep and queue): the head/reviewed-sha mismatch is
  a log line AND the PUT goes out unbound, so the operator switch merges
  instead of collecting a 409 from the head it waved through.
- `bin/poll-commands.sh` — the console `merge_pr` handler, inside
  `# >>> merge_pr handler`. Passes the payload's `sha` when the console supplies
  one, and otherwise the ledger's reviewed sha (`job_verdict <pr-url>` field 6,
  the same lookup `hb_sha` does) — Mission Control's merge button posts only
  `{type, project, ticket, pr_url}`, so without that lookup this lane would be
  the one merging unbound. A ledger row that makes no claim ("-") stays unbound.

**Rung order:** `rest` (the identity the caller already holds) →
`rest:default-pat` (what `bin/lib/gh-app-auth.sh` saved before swapping in an App
token) → `rest:admin-pat` (`GH_ADMIN_TOKEN` from the env bundle). A rung that
answers 403/429/404/5xx/no status CLIMBS; a rung that answers 200/405/409/422 has
GitHub's answer ABOUT THE MERGE and STOPS the ladder — a second identity never
re-tries a merge GitHub already refused.

**The rc contract (`gh_pr_merge_rest`):**

| rc | means | stdout | what the caller does |
|----|-------|--------|----------------------|
| 0 | merged over REST | the merge sha (may be empty) | records the merge; no GraphQL state read needed |
| 2 | no rung reached a verdict, or the ladder is off | — | runs its own `gh pr merge` line, unchanged |
| 3 | HTTP 405 — a named park | GitHub's message | logs the reason, parks; no GraphQL retry; the console acks `ok:false` + `outcome:"refused"` + `refused:` (terminal `refused`, never stamped merged, BH-932) |
| 4 | HTTP 409 — the head moved | GitHub's message | same; the console acks `ok:false` + `outcome:"refused"` + `refused:` (terminal `refused`, never stamped merged, BH-932) |
| 5 | HTTP 422 / other 4xx refusal | GitHub's message | same; the console acks `ok:false` + `outcome:"refused"` + `refused:` (terminal `refused`, never stamped merged, BH-932) |

**A whitelist that could not be READ is not a refusal (BH-2009).** Before any
rc above, the console `merge_pr` handler checks the url against every repo in
fleet.conf. If `fleet-conf.sh --projects` fails or lists nothing, or a project's
`repo` read fails, and the url matches none of the slugs that WERE read, it acks
`ok:false` + `merge failed: whitelist unreadable (<what failed>)`, with no
`outcome` and no `refused:` prefix. The console re-leases that row. A url that
matches a slug that was read still merges. A url that is not in a fully read
whitelist stays `refused: not a whitelisted fleet PR` (BH-4080 dropped the org name), which the console
treats as terminal because of its prefix. Pinned by
`tests/poll-commands-whitelist-unreadable.bh-2009-test.sh`.

**THE METHOD COMES FROM THE REPO (BH-1313, 2026-09-22).** The PUT no longer
hard-codes `merge_method=squash`. `_gpm_method` reads `GET repos/<slug>` ONCE per
process per slug, caches the answer in a variable, and resolves:

| the repo says | the merge goes out as |
|---|---|
| squash refused, merge commits allowed | `merge` |
| rebase is the only method allowed | `rebase` |
| squash AND merge allowed, and the PR is a TRAIN (`train/…` head ref or a `merge train:` title) | `merge` |
| anything else — including a read that answered non-200, unparseable, or without the three fields | `squash`, today's behaviour, plus one log line saying the settings could not be read |

Why it exists: example-org/cromford was set to `allow_squash_merge=false`,
`allow_rebase_merge=false`, `allow_merge_commit=true` at ~04:10Z on 2026-09-22,
after an App-identity actor squash-merged three merge trains and #1191 within a
minute of CI going green, once while the run was red. Under that setting every
hub-lane merge on this repo answered HTTP 405, so the four merge lanes were off.
A squash also strands a TRAIN's members: the train's commits never reach main,
merged-by-ancestry never becomes true, and each member has to be closed by hand.

The train rule is the only one that spends a second read (the pull object, for
the head ref and the title) and it is skipped whenever the repo's own settings
already decide. An unreadable pull object is NOT a train. The method is decided
ONCE before the first rung and every rung sends the same one — a climb changes
the IDENTITY, never what the merge is.

**HTTP 405 is one loud line.** It names the repo, the method that was tried and
the repo's allowed methods (`… example-org/cromford refused
merge_method=merge; the repo allows: merge`), is still rc 3, and is never
followed by a second attempt with another method — that would be this ladder
re-trying a merge GitHub already refused.

**Who merged it.** The merged line names the method and the identity RUNG by
word (`merged <slug>#<n> at <sha> over REST with merge_method=merge, on identity
rest:admin-pat`). There is no `GET /user`: it is 403 for an installation token
and would spend a call per merge to learn what the rung already says.

**The four lanes' fallback lines** (`gh pr merge …`, run only when no REST rung
reached a verdict) take the same answer through `gh_pr_merge_flag <slug>`, which
prints `--merge` / `--rebase` / `--squash`. On a box whose harness sync has not
landed the lib, and while the kill flag is on, each line keeps its own
`--squash` and spends no REST call to decide it.

**THE POOL-SIDE MERGES TAKE THE SAME ANSWER (BH-1428).** `bin/review-prs.sh`'s
`# >>> review-prs merge` block and `bin/run-build.sh`'s `# >>> tier-1 merge gate`
block each source the ladder INSIDE the marked block the suites extract and run,
and take their flag from `gh_pr_merge_flag`. cromford has no `.mergify.yml`,
so the conductor-only gate does not hold those PRs: before this, every APPROVE +
tier-1 external PR and every tier-1 build merge on this repo 405'd there,
self-healed later through the box queue, and logged nothing.

**A NON-200 SETTINGS READ IS NEVER CACHED (BH-1428).** The cache key is set only
after a 200 that named at least one of the three fields. A rate-limited (403/429)
or blind (404) identity used to pin `squash` for the whole process, so the next
identity's PUT 405-parked on a merge-commit-only repo and two conductor ticks
later the wave was BLOCKED_HUMAN. Each rung now resolves the method with its OWN
token immediately before its PUT: on the healthy path that is one read for the
whole ladder (the 200 is cached), and after an unread answer the next rung asks
again rather than inheriting a guess.

**ONE TRAIN RECOGNISER (BH-1428).** `bin/lib/train-shape.sh`'s `train_is_train
<title> <head-ref>` is the only answer to "is this a train", and both
`_gpm_is_train` and `ti_ci_select` in `bin/test-impact.sh` ask it. It covers both
shapes this repo opens — `batch/` branches with `batch(` titles from
`bin/batch-resolve.sh`, and `train/` branches with `merge train:` titles — and
matches by PREFIX, so `Revert "merge train: …"`, `retrain:` and
`feature/train-schedule` are not trains. Without that lib a PR is simply not a
train, which is the pre-BH-1313 answer.

**Knobs:** `PR_MERGE_REST=0` (env) or `flags/pr-merge-rest-off` — the kill flag.
Either one makes the ladder answer rc 2 without spending a REST call, so every
lane runs the `gh pr merge` line it ran before BH-892 — and, since BH-1313, with
the `--squash` those lines carried before it.

**The branch delete** (what `--delete-branch` did) runs only after a 200, is best
effort, and never changes the merge verdict. It deletes `refs/heads/<head ref>`
in the BASE repo only when the PR's head actually lives there
(`.head.repo.full_name` equals the slug) — a fork's head is skipped, the way
`gh pr merge --delete-branch` skips a cross-repository head, so a same-named
branch in the base repo is never destroyed.

**A STACKED CHILD IS RETARGETED, NEVER CLOSED (BH-1483, 2026-09-22).** Deleting a
branch that an open PR is BASED on is how GitHub closes that PR, and
`delete_branch_on_merge` is `false` on these repos so GitHub's own
retarget-on-delete never runs: on example-org/cromford#1453 the merge of #1441
(`ticket/bh-1385` → `main`) was followed by `base_ref_deleted` two seconds later
and `closed` one second after that, and a human reopened it by hand at 14:48:57Z.
So before the DELETE the ladder reads
`GET repos/<slug>/pulls?state=open&base=<head ref, @uri-encoded>&per_page=100` and
PATCHes every PR it names to the MERGED PR's own `.base.ref` — its own base, not
the repo's default branch, because a doubly stacked PR's base is itself a feature
branch and flattening that is not ours to do. Only when every PATCH answered 200
is the ref deleted, and the PATCHes always go out first. Anything that leaves the
list unproven KEEPS the branch and logs one line naming what kept it: a non-200, a
200 whose body is not a JSON array, a FULL page of 100 (`_gpc_split` drops the
`Link` header, so a second page cannot be proven absent), a PATCH that was refused,
or a merged PR whose own `.base.ref` did not read. `_gpm_delete_branch` answers
non-zero in exactly those arms; the call site discards that rc, because the merge
has already happened. A branch left behind costs one line of cleanup, a closed PR
costs a human.

**Preconditions / seed needs:** none beyond a gh token that can merge. Repos
behind GitHub's NATIVE merge queue are skipped by the callers (there `gh pr
merge` IS the enqueue and REST has no equivalent); Mergify repos already stand
the sweeps down before the merge line.

**How to drive it:**
- `HARNESS_TEST_SANDBOX=1 bash tests/merge-rest-test.sh` — the ladder itself
  (rungs, verdicts, kill flag, branch delete) plus the sweep, the merge queue's
  two landing paths and `mc_merge` driven against a stub `gh`.
- `HARNESS_TEST_SANDBOX=1 bash tests/merge-branch-delete-children.bh-1483-test.sh`
  — the stacked-child retarget: the PATCH-before-DELETE order, the empty-list
  delete, and every arm that keeps the branch (list non-200, non-array body, full
  page, refused PATCH, unreadable base), plus the mutation that drops the lookup.
- `HARNESS_TEST_SANDBOX=1 bash tests/merge-method-rungs.bh-1428-test.sh` — the
  per-rung re-read, the cache-only-a-200 rule, the shared train recogniser, and
  the two pool-side blocks extracted by their markers and run.
- `HARNESS_TEST_SANDBOX=1 bash tests/merge-method.bh-1313-test.sh` — the method
  resolution, its cache, the 405 alert line, `gh_pr_merge_flag` and the train
  rule, against a stub `gh` that answers the repo's settings per case.
- `HARNESS_TEST_SANDBOX=1 bash tests/poll-commands-merge-pr.bh-892-test.sh` — the
  console `merge_pr` handler extracted from `bin/poll-commands.sh` and run.
- `HARNESS_TEST_SANDBOX=1 bash tests/pr-dep-gate-rest.bh-994-test.sh` — the three
  READS above, driven with a `gh` that fails every GraphQL spelling with the
  incident's own rate-limit message and answers only over REST.

**Verify it works:** on a live box, `logs/merge-sweep.log` and
`logs/merge-queue.log` carry `rung rest: merged <slug>#<n> at <sha> over REST`
after a landing, `logs/console-commands.log` carries the same line for a console
merge, and the command ack reads `merged https://github.com/<slug>/pull/<n> at
<sha>` rather than `merge failed: GraphQL: API rate limit …`. A PR whose head
moved acks `refused: head moved since sha <8 chars> — Head branch was modified…`.

**Manual-only / not automatable:** the live-box evidence above needs a real merge
on a real token, so it lands a tick after this ships; the suites prove the call
shape with a stub `gh` and nothing in a build session ever merges.
