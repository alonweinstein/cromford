# Launch gates on the REST contract (BH-782)

**What it is:** the five "is there already a PR / branch / build for this
ticket?" reads that gate a build launch, moved onto `bin/lib/gh-rest.sh`. They
exist as one entry because they share one rule:

> A non-200 — or a 2xx with an unusable body — is **UNKNOWN**: the launch is
> skipped for this tick and the status is logged. A 200 with `[]` is a real
> empty and the launch proceeds.

It exists because of #768 (2026-09-18 02:49-03:05Z): a rate-limited GraphQL
`gh pr list` exited 0 and printed nothing, five gates mapped that silence to
`[]`, and the harness launched builds on top of work that was already written.

**How an operator reaches it:** no UI. These are cron lanes on the hub and the
watcher boxes.

**Primary lanes / scripts:**

| lane | the read | what an UNKNOWN answer does |
|---|---|---|
| `bin/preplan-candidates.sh` (pre-plan tick, `bin/preplan-tick.sh`) | `GET /repos/{slug}/issues?labels=ai-build&state=all` and `gh_rest_pr_list … open` | `gate_unknown`: the READY-QUEUE rows still print, **no candidate row** does, one `launch gate UNKNOWN (HTTP <s>)` line lands in `logs/<project>.log`, exit 0 |
| `bin/triage-gate.sh` (every per-project triage line) | the same issue list, `gh_rest_pr_list … open` for the PR half of the fingerprint, `gh_rest_pr_state` for the queue gate | fail-OPEN, unchanged: `RUN`, never `SKIP` |
| `bin/overlap-guard.sh` (launch time) | `harness_pr_list … number,url,headRefName,isDraft,files` | the ONE non-fail-open case: with **no cache** it prints `DEFER <KEY> gh unknown (HTTP n/a) …` and exits 1 — `n/a` on essentially every real invocation, because `files` sends this read down the per-author path where no HTTP status is ever seen (a status number appears only if the read reached REST, rc 44/75). It also writes one `ALERTS.log` line per project per UTC day, because this arm stops every launch for the project. With a cache it judges from the cache, and a failed read never overwrites it |
| `bin/dep-verify.sh` | `gh_rest_pr_list … all` and `GET /repos/{slug}/issues/{child}` | `UNKNOWN gh HTTP <status> …`, exit 0, and never cached (`state/dep-verify/` cannot freeze an outage in). Each UNKNOWN is answered at the point where the read it lost actually costs a verdict — never at the read, because `RECORD` is terminal and UNKNOWN under the default `DEP_UNKNOWN_MODE=soft` RELEASES the child |
| `bin/lib/gh-pr-list.sh` | `GET /repos/{slug}/pulls` per page | rc 44 (404) / 75 (everything else unreadable) / 1 (per-author path, every author failed or answered empty) — never a GraphQL retry |

**Why overlap-guard is the exception:** the other four fail open because the
question they could not ask is "is there more work to do". The guard's missing
half is the one holding work ALREADY WRITTEN, so an empty answer means "no
overlap, go" — which is exactly how #768 launched three builds for TK-2302.

**The per-author path is still GraphQL, on purpose.** `files`,
`mergeStateStatus`, `mergeable` and `isInMergeQueue` are GraphQL-only LIST
fields (`merge-conductor`, `rebase-train-ahead`, `batch-resolve`,
`overlap-guard` ask for them). Only the GraphQL **retry after a REST failure**
was removed. The property is preserved from the other side instead: an author
that exits 0 and prints nothing now counts as a FAILED author, so the #768
shape reaches a caller as a non-zero rc rather than as an empty list. That is
why overlap-guard's DEFER usually reads `HTTP n/a` — the per-author path saw no
HTTP status, and the guard says so rather than naming one it never got.

**What left the triage-gate fingerprint:** `prs[].mergeStateStatus`. REST list
responses do not carry it and buying it back costs one `GET /pulls/{n}` per open
PR per tick. A merge, a close, a rebase (head sha), a new comment or a state
change all still wake the tick; a bare CHECK flip no longer does — which is the
same argument `bin/triage-gate.sh`'s queue gate already made about that field.
Knock-on: `bin/gate-diff.sh`'s NEW-PR line printed the field unconditionally and
would have rendered a literal `mergeState None`, so that one token was dropped
in the same commit; `describe()` still maps the key for fingerprints written
before this change.

**Why a 403 on the PR half fails the whole triage-gate fetch:** substituting
`prs:[]` reads like the fail-open and is not one. On a board with no open PRs
the substitute fingerprint is byte-identical to the stored one, so the tick
answers `SKIP no-change` off a read it never made; and on any board
`bin/lib/rt/gate.sh` promotes `state/<p>.gate.pending` into the stored
fingerprint once a session has run, so tick 2 of an outage matches tick 1's
substitute. `fetch_fingerprint` returns non-zero instead, which is this file's
documented fail-OPEN: `RUN gate-fetch-failed`, `--pending` exits 1 ("run with
full context"), `--seed` prints SEED-FAILED.

**Knobs:** `OVERLAP_PR_CACHE_SECS`, `OVERLAP_PR_LIMIT` (`flags/scheduler.conf`),
`GH_PR_LIST_REST_PAGES`, `HARNESS_PR_AUTHORS`, `DEP_VERIFY`,
`PREPLAN_SPECULATIVE`. No new env var.

**How to drive it:**
- `HARNESS_TEST_SANDBOX=1 bash tests/launch-gate-unknown.bh-782-test.sh` — 96
  assertions driving the four real scripts against a scratch `$HARNESS` with a
  `gh` stub that replays canned `-i` responses: §A pre-plan (403 ⇒ zero
  candidates + one log line; 200+`[]` ⇒ the candidate is emitted; a 2xx body
  neither mapping jq can read takes the same arm as the 403, on both reads; a
  `pull_request` row in the REST issue list is filtered out; no token in any
  log), §B triage-gate (SKIP on an unchanged board, RUN on a 403 including on a
  board with no open PRs and on tick 2 after `gate.pending` was promoted, a
  comment bump and a moved head both wake it, the queue-gate vector round-trips
  through `gh_rest_pr_state` and a 403 empties it), §C dep-verify (403 on the
  list and on the body both answer UNKNOWN naming the status; a 403 on the body
  still lets a local `DEPENDS: … hard` pre-plan and a file overlap answer HARD;
  nothing is cached; `merged_at` ranks as MERGED; `DEP_PRS_FILE` costs no gh
  call), §D overlap-guard (DEFER with no cache plus exactly one ALERTS.log line
  per day, LAUNCH from a cache, the cache's sha256 is unchanged by a failed
  read, `OVERLAP_GUARD=0` reads nothing, no `gh` binary still fails open), §F
  the rc table and the "no GraphQL retry" argv check, §E four mutation checks.
- `HARNESS_TEST_SANDBOX=1 bash tests/gh-no-graphql-decision-guard-test.sh` — the
  marker guard, pinned at six marked files.
- The regression suites whose `gh` stubs encode these argv:
  `tests/gh-pr-list-test.sh`, `tests/harness-pr-authors-test.sh`,
  `tests/overlap-guard-test.sh`, `tests/dep-verify-test.sh`,
  `tests/gate-prs-fingerprint-test.sh`, `tests/preplan-speculative-test.sh`,
  `tests/planned-files-cheap-test.sh`, `tests/hotfix-dispatch-order-test.sh`,
  `tests/pr-state-rehydrate-test.sh`, `tests/pipeline-health-detectors-test.sh`,
  `tests/merge-conductor-test.sh`, `tests/rt-split-layout-test.sh`.

**Preconditions / seed needs:** `jq` and `python3` on PATH. Nothing else — `gh`
is a stub in every suite, so no token and no network.

**On a live box, without spending a build:**

```bash
# the pre-plan lane's answer under a dead token (read-only, prints candidates)
GH_TOKEN=invalid /root/harness/bin/preplan-candidates.sh <project>
tail -1 /root/harness/logs/<project>.log     # launch gate UNKNOWN (HTTP 401)

# the guard's answer for a ticket it has a plan for
/root/harness/bin/overlap-guard.sh <project> <KEY>; echo "rc=$?"
tail -3 /root/harness/logs/overlap-guard.log
```
