# Review PR D1 verdict row (review-prs records its own verdict)

**What it is:** `bin/review-prs.sh` pays for one Fable adversarial review per
unreviewed external-PR head. Until BH-1064 it recorded that purchase NOWHERE the
fleet could read: the lane row was opened with an empty ticket key and no
artifact was ever written, so `/api/verdict?pr=…` — which resolves a PR through
its `pr_url` artifact — could only answer for harness BUILD PRs, exactly the PRs
this lane skips. Its own dedup's D1 rung could never answer for its own reviews.

BH-1064 makes the lane record what it bought:

- **One job row per PAID review**, keyed `review/<project>/<num>@<sha>` (the
  lane string `review/<project>/claude` is unchanged, so the budget catalog
  resolves exactly as before). It used to be one row per TICK, reused by every
  PR the tick reviewed — and the worker upserts artifacts on
  `(job_id, artifact_kind)` (`ON CONFLICT(job_id, artifact_kind) DO UPDATE` in
  `worker/jobs/src/routes/job-artifacts.js`), so a tick that reviewed #7 and then #9 kept ONE
  `pr_url` and ONE `verdict`: #9's. #7 was unfindable and the surviving row was
  bound to the wrong head.
- After a paid, successful verdict the lane writes a `verdict` artifact (detail:
  `tier`, the real provenance `$SERVED`, `record:"review-prs:<project>:<num>"`,
  `headbound:"n/a"`, `reviewed_sha`, `settled:true`) and THEN a `pr_url`
  artifact (`https://github.com/<slug>/pull/<num>`, detail: `number`,
  `reviewed_sha`, the same `record`, `lane:"review-prs"`). That order is the
  point: the row only becomes findable when the `pr_url` lands, so a half-written
  pair is unfindable rather than mis-attributed. `record` is the field
  `/api/verdict` hands back verbatim — there is no build directory to name here,
  so it names the lane, project and PR instead of leaving a reader with `null`.
- No-verdict and not-billed exits write no artifacts, so a failed or refused
  review can never look like an approval later.

Same shape `bin/run-build.sh` writes, so `job_verdict` and
`job_verdict_headbound` read it unchanged.

**What this file does NOT cover:** the READ side. Asking those rows "have we
already paid for this head?" before spending is `rp_rehydrate` in BH-1017
(PR #1048, `review-gh-dedup.md`); this entry is the write side that gives that
rung something to find. The two touch different regions of the same script and
land in either order.

**How an operator reaches it:** there is no UI. The lane is the per-project
`review-prs.sh` line in `cron/<box>.cron` (twice an hour per project).

**Primary lanes / scripts:**
- `bin/review-prs.sh` — the `# >>> review-prs per-review row` block
  (`review_claim`, called once per paid review) and the
  `# >>> review-prs d1 artifacts` block that writes the `verdict`/`pr_url` pair
  after a successful verdict.
- `bin/jobs-client.sh` provides `job_lane_open`, `job_lane_close` and
  `job_artifact_put`; no change to their contracts.

**Knobs:** none.

**How to drive it:**
- `HARNESS_TEST_SANDBOX=1 bash tests/review-prs-d1-row.bh-1064-test.sh` — drives
  the real `bin/review-prs.sh` against a scratch `$HARNESS` with `gh`,
  `agent-call.sh` and a stubbed jobs-client injected via `BASH_ENV`. The stub
  models the DEPLOYED worker: every read materialises the artifact log
  last-write-wins per `(job_id, artifact_kind)`, and `verdict_for_pr` resolves a
  PR the way `/api/verdict?pr=` does. Covers: a paid review claims
  `review/<project>/<num>@<sha>` and writes both artifacts with the real head and
  provenance, verdict before pr_url; TWO PRs in one tick each keep their own row
  (red before this change — #7's pair was overwritten by #9's); a second head
  claims its own key and the lookup answers for the newest head; and a mutant
  with the artifact block removed writes no artifacts while still reviewing.

**Preconditions / seed needs:** none beyond the fixture suite.

**Verify it works (on a box):**

```sh
# After a review tick, the jobs ledger can answer for that PR — it could not
# before BH-1064 (the lookup 404'd for every external PR):
. /root/harness/bin/jobs-client.sh
job_verdict "https://github.com/<slug>/pull/<num>"
# -> "APPROVE<TAB>2<TAB>claude<TAB>-<TAB><job-id><TAB><reviewed-sha>"
# and the row that answered is keyed to the head it bought:
grep -c "review/<project>/<num>@" /root/harness/logs/jobs-client.log
```

**Manual-only / not automatable:** none.
