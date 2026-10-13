# A bot review verdict has one consumer and never parks a PR

**What it is:** the three lanes that a `REQUEST_CHANGES` from `bin/review-prs.sh`
now passes through, and the rule that binds them: a bot verdict is an EVENT with
a consumer, not a state that stops a PR.

| lane | cron | what it does with the verdict |
|---|---|---|
| `bin/review-prs.sh` | `7,37` per box | dedupes against GitHub's own review rows, posts the verdict on a harness PR as a **COMMENT** review, and dismisses the standing `CHANGES_REQUESTED` reviews it left behind |
| `bin/blocked-resolver.sh` (`# >>> br-reviews`) | hub, `*/10` | reads that verdict back off GitHub and routes it into ONE fix round per (PR, head), then escalates with one comment |
| `bin/merge-conductor.sh` (`# >>> dequeue surface`) | hub, `*/5` | when Mergify ejects a PR because `github-review-approved` is false, says so on the PR and in the fleet feed |

**Why it exists** (BH-872, 2026-09-18). Four PRs — project-5 #2367 among them —
sat out of the merge queue on a bot's refusal. Three defects stacked:

1. `state/<project>.pr-reviews.json` was the only dedupe ledger and it fails
   SILENT. `jq -r '.["7"].sha // ""'` on an empty file prints nothing with rc 0,
   and the record write (`jq … "$STATE" > tmp && mv`) on that same file writes an
   empty file, also rc 0. One state loss and every tick bought another Fable
   review of the same head and posted another `CHANGES_REQUESTED` — about one an
   hour per PR, as `operator`, indistinguishable from the operator's own refusal.
2. The pipeline-skip marker was searched in the FIRST 2000 BYTES of the PR body,
   and `bin/run-build.sh` prints its `Plan: harness build …` line after the
   What/Why/verify/spec sections. So every pool-built PR was reviewed a second
   time by a lane whose own header (the operator, 2026-07-29) says it skips them.
3. Nothing in the fleet read the verdict. `CHANGES_REQUESTED` made Mergify's
   `github-review-approved` condition false, Mergify dequeued the PR, and the
   conductor's requeue arm needs `mergeStateStatus CLEAN` — which that same
   review denies. The findings were posted into a room with nobody in it.

**How an operator reaches it.** Three entry points, no new cron line.

*The review lane* (`bin/review-prs.sh <project>`, one line per project box):

| step | where | what it does |
|---|---|---|
| reseed | right after `LOG=` | a state file that is not a JSON object is replaced with `{}` and one line says so. The absent-file seed above it is unchanged |
| skip | inside the harness-author branch, FIRST | whether this is a PIPELINE PR (a build `RESULT` names it, or the body carries the marker) is decided before anything is dismissed, because the dismissal rule depends on the answer. The marker is searched over the WHOLE body and ANCHORED (`^Plan: harness build `, the shape `bin/run-build.sh` prints); the body read is `gh api repos/<slug>/pulls/<n>` (REST), never `gh pr view --json body` (GraphQL) |
| dismiss | same branch, after the skip decision, skipped when `.ledger_sha` already equals this head or when `gh_budget_low review-prs` says low (rc 2, unknown, proceeds) | one `gh api repos/<slug>/pulls/<n>/reviews` read; each row that is `CHANGES_REQUESTED` **and** carries the lane's footer **and** is by a harness author gets `PUT …/reviews/<id>/dismissals`. On a PIPELINE PR every such row goes, including one at the current head — the lane walks away and the conductor needs the queue back. On a HAND harness PR the row AT the current head is LEFT STANDING: this lane reviews that head itself and nothing else would consume the findings if the blocking state went. A stale row is dismissed on both paths The read itself is SKIPPED when the local record already answers for this head — `.ledger_sha` (BH-989), the watermark written only when a pass here completed with nothing left that had to go — so a second tick at the same head asks GitHub nothing; it used to run for every open harness PR on every tick, ~110 paginated reads an hour per box. The skip is NOT on `.sha`: a head can be reviewed on a tick whose dismissal pass was deferred or refused. |
| supersede | right after the post, only when an APPROVE of head H LANDED (a refused post that fell back to a comment supersedes nothing), the PR's author is NOT a harness author (`harness_pr_author_match`: the per-tick dismiss above covers those, builders App included since #1926) and `gh_budget_low review-prs` does not say low | one more `gh api repos/<slug>/pulls/<n>/reviews` read, then `rp_dismiss_own` with H kept: each of this lane's own footer `CHANGES_REQUESTED` rows on an OLDER head is dismissed with a message citing the new APPROVE's review id and H. Non-harness authors only, so no row is dismissed twice. An unreadable list dismisses nothing; no `ledger_sha` is written here (BH-2119) |
| ledger | `# >>> review-prs ledger`, after the CI debounce and before the diff is fetched | a review row by a harness author, with the footer, whose `commit_id` IS this head means this head is already reviewed: the local record is healed from it, `merge_retry` runs as it would on a local hit, and nothing is posted or spent |
| post | the verdict | `--approve` for APPROVE anywhere; `--comment` for `REQUEST_CHANGES` on a harness-authored PR; `--request-changes` for an external author, who gets the blocking state a real refusal deserves. All three go out on the App, and so do the dismissals; the one exception is an `--approve` on a PR the reviewing App itself opened (or when the App's login cannot be read), which keeps the lane's DEFAULT credential because GitHub 422s a self-approve (BH-2119). A refused post logs gh's own reason before the comment fallback runs |

*The resolver's source* reads the same three-part key (harness author, footer,
`commit_id == head`) and then the body's own `VERDICT:` line, so a COMMENT-state
review carrying `REQUEST_CHANGES` is a candidate and an `APPROVE` posted after it
ends the park. It is LAST in `br_candidates`, behind `gh_budget_low`, and only
PRs updated within `BR_REVIEW_LOOKBACK_SECS` have their reviews read at all.

*The conductor's surfacing* asks `mc_dequeue_reason` — the newest `mergify[bot]`
comment on the thread, else the Mergify check run's `output.summary` on the head.
Naming the token is NOT enough: Mergify prints `github-review-approved` in the
required-conditions checklist of every status comment on a repo whose ruleset
asks for a review, satisfied or not (live: project-5 #2029/#2120 dequeued on a
checks timeout, merged #2367). `mc_mergify_names_review` reads the body in LINES
and answers only when the `## Reason` section names the token on a line that is
not `[X]`, or — where there is no `## Reason`, i.e. a check-run summary — when
the token sits on an UNCHECKED `- [ ]` condition line. The comment it then posts
goes out over REST (`POST repos/<slug>/issues/<n>/comments`), never `gh pr
comment`, which is a GraphQL mutation.

**How to drive it:**

| what | how |
|---|---|
| the BH-989 follow-up (the cache- and budget-gated standing-review read, and its `.ledger_sha` watermark) | `HARNESS_TEST_SANDBOX=1 bash tests/review-prs-followups.bh-989-test.sh` (38 assertions; same stub construction, plus a `rate_limit` fixture with a literal reset epoch and a `DISMISS_FAIL` knob) |
| the review lane, end to end against the real script | `bash tests/review-prs-dedupe-test.sh` (57 assertions). The gh stub answers `api` from a GitHub-shaped JSON fixture and applies the lane's real `-q` filter with jq, and records the token every call went out on |
| a standing review at this head buys nothing and posts nothing | cases 1, 2, 16 of that suite (including the 0-byte state file, and a second tick that reads no ledger at all) |
| unreadable ≠ absent | case 3 — `reviews` read rc 1 defers, writes no record, logs `deferred` |
| the COMMENT state, and that an external author still blocks | cases 4 and 5 |
| the marker past byte 2000, and the negative control | cases 6 and 7 |
| the dismissal, and every adversarial negative | cases 8-13 (no footer, external author, `APPROVED` row, the parked pipeline PR, a failed PUT logged), plus 17/18 (at-head on a hand PR is kept, stale is dismissed) and 22 (a permanent refusal pages once) |
| App identity on the writes, PAT on the reads | cases 14 and 15; case 20 pins that an `--approve` on the reviewing App's own PR goes out on the DEFAULT credential and case 21 that a refused post keeps gh's reason |
| every other APPROVE on the App, and the post-APPROVE supersede | `HARNESS_TEST_SANDBOX=1 bash tests/review-prs-app-approve.bh-2119-test.sh` — A1 is project-5 #3244's shape on a non-harness author (the App's stale `CHANGES_REQUESTED`, APPROVE of the new head); A1b a builders-authored PR (BH-872 dismisses once, before the review); A1g the harness-author guard; A2-A4 the identity rule; N1-N5 the negatives on a non-harness author (a person's review, a stranger's footer, a row at the approved head, a non-APPROVE verdict, a refused APPROVE) |
| a LEAD's (or a human's) `CHANGES_REQUESTED` briefs the round, and a round that answers none of it is not pushed (BH-2200) | `HARNESS_TEST_SANDBOX=1 bash tests/fixround-lead-reviews.bh-2200-test.sh` — L1 the footer-less operator CR is the brief (LEAD FINDINGS header, every reason); L2 write access proved (OWNER/MEMBER/COLLABORATOR, or CONTRIBUTOR + a `write` permission read), never a bot or an unproved association; L3 only a standing CR; L4 an older head counts only when followed by merges alone; L5 the lane's own footer review unchanged; L6 unreadable is rc 75; F1-F8 the real `br_fix_round`: prompt, `fix-round-noop` (nothing pushed, `noop_heads`, one alert), a named file pushes, an unaddressed list is posted and pushes, a noop head is not re-run and makes zero review/compare/permission reads, a token is a file only when the repo tracks it (`e.g`, `Node.js`, a PR URL are not), and a named directory is answered by a change under it. Discovery: sections 2e2 and 2o2 of `tests/resolver-review-consumer-test.sh` (a noop-frozen head is skipped before the reviews read; only a new head re-arms it). The unaddressed list travels in the agent's final report, under a line reading exactly `UNADDRESSED:`, never a file the agent writes outside its worktree (BH-2276): `HARNESS_TEST_SANDBOX=1 bash tests/fixround-unaddressed-report.bh-2276-test.sh` drives `br_fix_round` with a sandboxed agent that is denied every write outside its cwd (U1 the prompt names no `$ST` path, U2 the list is posted and pushed, U3-U5 `none` / a bare header / a quoted instruction stay noop, U6 the last section wins) |
| the resolver source, the (PR, head) key, the cap and the escalation | `bash tests/resolver-review-consumer-test.sh` (104 assertions; section 2p pins that `ESCALATED` is terminal for the escalated PR and not for its ticket key; section 3 drives `bin/blocked-resolver.sh` itself against a real local git remote) |
| the dequeue surfacing | `bash tests/conductor-dequeue-surface-test.sh` (38 assertions, with the Mergify bodies copied from real project-5 comments; section B extracts the shipped `# >>> dequeue surface` block and runs THAT, so deleting the call site is red) |
| a PAT that 403s must not stop the ledger read | `bash tests/external-review-ci-read-test.sh` — the `app-only` case. The ledger read goes through `gh_ci_api`, so it falls back to the read-only App token exactly like the Actions read |
| red-before-green | `bin/repro-gate.sh <merge-base>`: at the base tree the dedupe suite fails 25 assertions (another review bought, `--request-changes` posted, no dismissal, marker past byte 2000 reviewed) |

**Files it owns on a live box:**

- `logs/pr-reviews.log` — `left its own CHANGES_REQUESTED review <id> standing`; `already reviewed on GitHub at <sha8> (review <id>, <verdict>) — state healed, nothing posted`; `reviews unreadable on GitHub — deferred`; `dismissed its own standing CHANGES_REQUESTED review <id> (BH-872)`; `could not dismiss its own standing review <id>`; `state file was not a JSON object — reseeded`.
- `state/<project>.pr-reviews.json` — now a CACHE, healed from the ledger and reseeded when it is not an object. Losing it costs one REST read per open PR, not a re-review. `.ledger_sha` (BH-989) is the per-PR watermark for the dismissal pass: it carries no `.verdict`, so `merge_retry` returns at its first check on a row that has only that key, and `bin/review-autopilot.sh` (which reads `.sha`) is unaffected.
- `logs/blocked-resolver.log` — `EVENT resolver_rung … review-changes-requested`, `fix round already ran on <sha8>`, and the `ESCALATED` line.
- `state/blocked-resolver/<project>/<cap-key>.json` — `review_fix_heads[]` (the (PR, head) key, appended BEFORE the agent runs) and `outcome: ESCALATED`; since BH-2200 also `noop_heads[]` (a head whose lead-blocked round ended `fix-round-noop`, never re-run) and a `fix-round-noop` attempt.
- `logs/blocked-resolver.log` — BH-2200: `fix-round-noop — the round changed none of the files the lead's findings name …`, `fix-round-noop already stands on <sha8>`, and `EVENT resolver_fix_noop`; `logs/ALERTS.log` one `[blocked-resolver] … fix-round-noop` line per noop round. A standing lead/human `CHANGES_REQUESTED` (LEAD FINDINGS) makes a `review-changes-requested` candidate even with no `VERDICT:` line, and outranks the lane's own later APPROVE.
- `state/merge-conductor/attempts.txt` — `dequeue-surfaced <key> <head>`, written before the comment.
- `logs/merge-conductor.log` — `DEQUEUED_REVIEW github-review-approved on <sha8>`.
- `logs/ALERTS.log` — one `[blocked-resolver] ESCALATED <project>/<rkey>` line per escalated park, written once per record (`escalate_alerted`) whether the comment landed or was refused; a `DISMISSED` review row never briefs a round, and an `ESCALATED` record is skipped by the source before the reviews read.

**Knobs:** `BR_REVIEW_FIX_ROUNDS` (2) and `BR_REVIEW_LOOKBACK_SECS` (172800),
both in `env/global.env`, both documented in `docs/MERGE-CONDUCTOR.md` section 12
with the code constant as the documented fallback; `RP_DISMISS_FAIL_ALERT` (3,
`env-templates/global.env.example`) — how many consecutive refused dismissals of
the same review page a person, once. `BR_REVIEW_FIX_ROUNDS` is read by
`br_fix_cap <record> <reason>`, which since BH-579 answers every OTHER reason
from the record (conflict shape plus the contested bonus): a review park has no
conflict of its own, so its cap is the knob alone and a conflict record can
never raise or lower it. The lane's footer string and
the `github-review-approved` token are code, not config: they are GitHub's and
Mergify's vocabulary, not this box's.

**What must never regress:**

- **A human's changes-requested is for a human.** A `CHANGES_REQUESTED` review
  without the lane's footer is never dismissed and never briefs an agent, whoever
  wrote it — and nothing is ever dismissed on an external author's PR.
- **Unreadable is not "no review".** A failed reviews read defers the review lane
  for that tick (no state written) and makes the resolver consume nothing; the
  one thing neither may do is treat it as "never reviewed" and post again.
- **A failed write never watermarks.** A refused dismissal or an unreadable
  reviews list leaves `.ledger_sha` unwritten, so the next tick reads and
  retries. Skipping the read to save a call must never look like having made it.
- **The ledger gate is not budget-guarded.** It is the last dedupe check before
  a paid review and it already runs only on a cache miss; guarding it would
  either defer every review while the budget is low or buy a duplicate.
- **An older `commit_id` never stands in for the current head.** A footer review
  at the previous sha is answered by whatever was pushed since, so the new head
  is reviewed normally.
- **A dismissal needs a consumer.** The lane never dismisses a blocking row at
  the head of a PR it is about to review itself: `rp_rehydrate`'s GitHub rung has
  no DISMISSED filter and `br_review_newest` skips DISMISSED rows, so such a
  dismissal would silently turn findings into nothing.
- **`ESCALATED` is terminal for the escalated PR, not for the ticket.** The cap
  key is the TICKET key whenever the branch names one, so the escalating rung
  stamps `escalated_rkey` and only that PR is skipped; a second PR for the same
  ticket is a candidate again. A record written before that stamp existed stays
  terminal, so nothing already handed to a person is re-offered.
- **The footer line is load-bearing.** `Automated harness review (Fable) of ` is
  how all three lanes recognise their own verdict. Reword it and the dedupe, the
  dismissal and the resolver's source all stop matching on the same day.
- **One round per (PR, head), marked before the spend.** The head goes on the
  record before the agent runs; a crash costs that head its round, which is the
  right side to fail on when the alternative is an execute call every ten minutes.
- **The escalation is an outcome record, not a review request.** One comment, one
  ALERTS line, one beat; the outcome is stamped only after the comment succeeded,
  the PR is not closed and the ticket is not rebuilt.
- **An unarmed box is untouched.** No `env/github-app.env` means `gh_auth_for`
  returns 1 without spawning a process, and every write goes out on the PAT
  exactly as it did before BH-872.
- **The conductor stays silent when it cannot name a reason.** An API failure, a
  red batch, a checks TIMEOUT whose checklist happens to mention the condition,
  a MERGED PR's status comment, or Mergify's idle "Merge queue is ready" check
  all answer "" — the review-approved comment is only ever posted when the body
  says the review is why the PR left the queue.
- **The known limit, carried on purpose:** the conductor requeues a head at most
  once (`mc_requeued_mark`). A PR whose head was already requeued before the
  review blocked it needs a new head or a person even after the dismissal, and
  the surfacing comment says so.
