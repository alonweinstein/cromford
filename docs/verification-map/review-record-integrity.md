# Review-record integrity (the posted review carries its own findings)

**What it is:** the two lanes that post a harness review to a pull request now go
through one renderer/poster, `bin/lib/review-post.sh`, instead of publishing the
agent's stdout file verbatim. It does three things (BH-641):

| rule | where | what it means on a PR |
|---|---|---|
| count what you post | `rp_findings` / `rp_max_ref` / `rp_render` | the body leads with the verdict, then `N findings returned, M rendered`, then a numbered index of the findings the review carries, then the review verbatim |
| fail closed on a short count | `rp_render` rc 3 | when the verdict references `finding #3` and only 2 can be parsed, the first line is `PARSE_INCOMPLETE: …` and the raw review and the raw agent envelope ride in fenced blocks — never a clean-looking body with a finding missing. An out file that is EMPTY or missing fails closed the same way (0 references against 0 findings would otherwise compare equal and render "no verdict / 0 rendered" as a complete review) |
| persist before you post | `rp_persist`, called by `rp_post` before `rp_comment` | `builds/<record>/rereview-<head8>.md` and `.json` exist before the network call, so a machine that dies between the two still has the review |

The second half of the ticket is a mechanical gate, `bin/lib/guard-silenced.sh`:
a fix round whose whole diff is guard rules, allow-lists, ignore files or
fixtures (`checks/`, `guardrails/`, `*allowlist*`, `*ignore`, semgrep/eslint/
gitleaks config, `fixtures/`, `__snapshots__/`, `testdata/`) made the guard pass
without touching the code the guard pointed at. That is an automatic BLOCK in
`bin/run-build.sh`, a refused push in `bin/blocked-resolver.sh`, and a named
reject clause in all three re-review prompts.

The resolver's gate classifies **the fix round's own commits**, never
`"$lease"..HEAD`: `br_fix_round` merges `origin/main` into the worktree before
the agent runs, so a lease-to-HEAD diff carries every file main changed since
the branch diverged and answers `CODE_CHANGED` on every park where main had
moved — which is every mq-conflict park, by definition. It reads
`git log --no-merges --name-only --format= HEAD --not "$lease" origin/main`;
`--no-merges` drops the merge commit, so a conflict resolved inside it is not
counted as the round's own work (the safe direction).

The post itself goes out over REST (`rp_comment` → `gh_rest_comment` in
`bin/lib/gh-rest.sh`), never `gh pr comment`: that wraps GraphQL, which is the
credential that rate-limits first and answers with silence (#768, BH-783). The
conductor reaches the poster through `hb_post`, the one place its
`hb_approve_bind` / `hb_block_park` helpers post from.

**How an operator reaches it:** nothing to run by hand. `cron/hub.cron` runs
`bin/merge-conductor.sh` every 5 minutes — a PR whose head moved off its
reviewed sha buys a detached re-review, and the tick that finds that job `done`
posts through this lib. `bin/blocked-resolver.sh` posts the same way for the
extra re-review it buys on a `no-verdict` park. The GUARD_SILENCED gate fires
inside a build, right after the merged fix round pushes.

**How to drive it:**

| what | how |
|---|---|
| the renderer, every shape (3 findings, a short count, `### Finding N` headers, an APPROVE with nothing to list, a missing envelope, a 60000-char review, `rp_persist` with no record) | `bash tests/review-post-test.sh` |
| the classifier, with every adversarial negative | `bash tests/guard-silenced-test.sh` |
| the real posters and both real gates — the conductor's done branch (including an out file that is named and gone), the resolver's re-review, the run-build gate in a scratch git repo, the resolver's gate in a scratch repo that has `origin/main` merged in exactly as `br_fix_round` merges it, and the prompt clause in the file `mc_rereview` actually sends | `bash tests/review-record-integrity-test.sh` |
| the lanes these blocks live in, unchanged | `bash tests/merge-conductor-test.sh`, `bash tests/review-provenance-test.sh`, `bash tests/blocked-resolver-test.sh`, `bash tests/run-build-graph-test.sh` |

The three suites stub `gh` on `$PATH`; the stub records the body it was handed
AND whether the build record already held the review at call time, which is the
whole ordering claim. A poster that writes the record after the post reads
`PERSISTED=no` there.

**Files it writes on a live box:**

- `builds/<record>/rereview-<head8>.md` — the review the lane produced, byte for
  byte, keyed on the head sha it was about. A re-spawn on the same head
  overwrites the same name; nothing accumulates.
- `builds/<record>/rereview-<head8>.json` — the agent-call envelope beside it,
  when the lane wrote one.
- the PR comment — first line `**Verdict:** …` or `PARSE_INCOMPLETE: the verdict
  references finding #N but only M findings could be rendered`.
- `logs/merge-conductor.log` / `logs/blocked-resolver.log` — one line when a post
  did NOT land, naming the file the findings were kept in. Before BH-641 that
  failure was `|| true` and silent.
- `$BUILD/guard-silenced.txt` + `logs/ALERTS.log` — `[<project>/<KEY>] BLOCKED:
  the fix round edited only guard rules/allow-lists/fixtures (GUARD_SILENCED)`,
  and `RESULT` = `REVIEW_BLOCKED guard-silenced: …`.

**Knobs:** `RP_RAW_CAP` / `RP_TEXT_CAP` (how much raw text rides in a body before
it is truncated with a pointer to the persisted copy; the caps exist because
GitHub refuses a comment over 65536 chars), `GUARD_SILENCED_EXTRA_GLOBS` (extra
guard paths for a target repo, space-separated globs).

**What must never regress:**

- **A short findings count never posts as a clean body.** The count is the
  gate: `rp_render` compares the findings it parsed against the highest
  `finding #N` the text references, and anything short is `PARSE_INCOMPLETE`
  with the raw material attached. Over-counting (a numbered step in prose read
  as a finding) is the safe direction and is deliberate.
- **Persist comes before post.** Not "in the same function" — before. The `gh`
  stub asserts it at call time.
- **A missing build record never costs the comment.** `rp_persist` answers rc 1,
  one line is logged, the post proceeds. Losing the comment because there was
  nowhere to file it would be the same evidence loss in reverse — see
  cromford#630, where the only copy of a remote build's artifacts died with
  the machine that held them. Same failure class: evidence that only ever
  existed in one place.
- **A failed post is never recorded as posted.** The REST call's own exit code
  (0 / 44 / 75) is read and logged (D9); the transition it accompanies is
  unchanged either way.
- **The resolver's gate judges only what the round wrote.** The merge of
  `origin/main` happens first and is not the round's work; classifying it is
  what made this gate inert for the whole of its first review round. Section 5
  of the suite drives the merged-main shape, and asserts main's own file IS in
  `$lease..HEAD` so the fixture cannot quietly stop reproducing the park.
- **A review file the lane never wrote is never posted as a review.** A named
  out file that is unreadable posts `PARSE_INCOMPLETE` and logs the path,
  instead of the footer alone ("BLOCK. Push fixes.") with no findings in it —
  which is the artifact this ticket exists to end. `rp_persist` refuses an empty
  copy, so a review an earlier tick kept at that head is never overwritten.
  The `.json` envelope beside a missing `.md` is fenced into that
  PARSE_INCOMPLETE body and the log line names both paths (BH-1320); the
  envelope is not copied into the build record, so an earlier tick's pair there
  is never split.
- **The gate's own absence blocks nothing.** A box mid-sync that carries the new
  `bin/run-build.sh` with the old `bin/lib` has no `gs_classify`, classifies
  nothing and demotes nothing; `rp_post` falls back to the pre-BH-641 comment
  rather than dropping it.
- **The transitions did not change.** This is a rendering and durability fix.
  `mc_attempted rereviewdone`, `mc_transition`, `mc_hb_refuse` and the resolver's
  `br_record` counters behave exactly as before.

**Not covered here:** `bin/review-prs.sh` and `bin/review-autopilot.sh` post
model output verbatim too, but they have no build record to persist into; they
can adopt the lib later. `bin/fly-results-ingest.sh` copies a fixed artifact
list and does not carry `rereview-*` files back from a remote builder — these
two lanes run on the hub against local records, so that is not a gap today.
