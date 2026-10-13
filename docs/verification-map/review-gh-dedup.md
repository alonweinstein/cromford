# Review dedup survives a wiped ledger (the ledger file is a cache, not the truth)

**What it is:** `bin/review-prs.sh` buys one Fable session per unreviewed PR
head. Until BH-1017 the only thing standing between a tick and a second paid
review of the same head was `state/<project>.pr-reviews.json` — a file on one
box's disk. BH-977 stopped that file lying about its own contents; it did
nothing about the file being GONE. A ledger that was reseeded, restored from an
older snapshot, deleted by hand or lost with the box reads as "nothing has ever
been reviewed", so every open head is bought again.

On project-5, 2026-09-18/19: 460 verdicts across 122 distinct PR+head pairs, #229
reviewed 52 times, about USD 1.1K in two days — while GitHub was holding every
one of those reviews and the D1 jobs ledger was holding the verdict rows.
Neither was ever asked.

So the ledger is now a cache. Before the money is spent, two free reads answer
"have we already paid for THIS head?":

1. **The D1 verdict row** (`job_verdict "https://github.com/<slug>/pull/<n>"`).
   It is the only source that also carries PROVENANCE, so when it answers with a
   `reviewed_sha` equal to the current head the rehydrated record is as good as
   the original one — verdict, tier and serving lane all recovered.
   **It cannot answer for this lane's own reviews today.** `/api/verdict?pr=`
   resolves through a `pr_url` artifact, and `bin/review-prs.sh` records none:
   `review_claim` opens its row with an empty key and nothing writes an
   artifact. So the D1 rung answers only for harness-BUILD PRs — which this
   lane skips anyway — and in practice every external-PR rehydration comes from
   GitHub. The rung is kept because it costs nothing when absent (rc 2 falls
   through) and because it is the rung that will carry provenance once the lane
   records its own row (follow-up: #1064).
2. **The PR's own reviews, over REST** (`gh api repos/<slug>/pulls/<n>/reviews`,
   never GraphQL). Every review this lane posts ends with the marker
   `Automated harness review (Fable) of <sha>`, spelled once in the script as
   `RP_MARKER` so the writer and the reader cannot drift. A review authored by a
   harness identity (`bin/lib/gh-pr-list.sh` `harness_pr_author_match`, so the
   App and the PAT spellings both count) carrying that marker for the CURRENT
   head is the receipt.

Either one rehydrates the ledger entry and the call is skipped, with one
`logs/pr-reviews.log` line saying which source answered.

**It fails OPEN, deliberately.** An unreadable source is "no claim": one log
line and the review is bought. A GitHub or worker outage must never be able to
stop reviews. The cost of failing open is one duplicate review; the cost of
failing closed is a lane that reviews nothing for the length of an outage.

**`served` is not guessed on the GitHub path.** The posted body does not say
which lane answered, so a GitHub-rehydrated record is written
`served: "rehydrated"`, which `rp_prov_is_claude` does not accept. A rehydrated
APPROVE therefore does not auto-merge through `merge_retry`. Recording `claude`
there would let the lane merge an APPROVE that judge provenance may have
deliberately withheld.

**A withheld APPROVE is as loud as the live one, on BOTH rungs.**
`merge_retry` returns silently on `served:"rehydrated"` on every later tick,
and no other lane in the fleet lists an external author's PR — so a log line
alone would leave an approved PR sitting open with nothing pointing at it.
`rp_withheld_beat` fires the same `beat.sh` `fleet_alert` the live
provenance-withheld path fires, with the same `provenance:<project>:<num>:<sha>`
akey, so a head withheld by both announces once. A rehydrated REQUEST_CHANGES
is not news and beats nothing, and a D1 row that DOES carry provenance
rehydrates as that lane and beats nothing either.

It is a helper rather than an inline block because it was inline once: it lived
in the GitHub rung, and when review round 2 made a D1 row with no provenance
write `served:"rehydrated"` too, the D1 rung silently acquired the muteness the
GitHub rung had just been fixed for — the hub's own review of `5376a75e` caught
it. Both rungs now record through one `rp_rehydrate_record`, which is also
where the announcement decision lives.

**The rehydrate write merges; it does not replace.** A wholesale
`.[$n] = {…}` dropped `deferred_sha`, `deferred_at` and `ci_alerted_sha` —
harmless on the wiped ledger it was written for, but on a live one it reset
that PR's CI-debounce clock and bought an extra `gh pr diff --name-only` plus
`actions/runs` read on the next head. Those keys survive now. The judgement
fields do not: a record being rehydrated may still hold a PREVIOUS head's
verdict, so `rp_rehydrate_record` deletes the same set `rp_freeze` deletes
before writing the new one.

**The in-flight marker.** The ledger used to learn about a head only AFTER
`agent-call.sh` returned, so a tick killed mid-review left no trace and the next
tick bought the same head again with nothing counting the attempts.
`reviewing_sha` / `reviewing_attempts` / `reviewing_at` are now written BEFORE
the call and replaced wholesale by the verdict record after it, so a completed
review clears them by itself. A crashed review is owed exactly one retry
(`REVIEW_INFLIGHT_MAX`, default 2); a head that dies twice mid-call is frozen
with terminal `sha` and one `logs/ALERTS.log` line naming the PR.

**How an operator reaches it:** there is no UI. The lane is the per-project
`review-prs.sh` line in `cron/<box>.cron` (twice an hour per project).

**Primary lanes / scripts:**
- `bin/review-prs.sh` — `RP_MARKER`, the `# >>> review-prs gh dedup` block
  (`rp_withheld_beat`, `rp_rehydrate_record`, `rp_rehydrate`) and the
  `# >>> review-prs gh dedup call` line in the PR loop, which sits immediately
  before the diff fetch; `rp_freeze` and the `# >>> review-prs inflight` block,
  which sits immediately before the paid call.
- `bin/jobs-client.sh` `job_verdict` — read when the box has a jobs client;
  rc 2 (no row) and rc 1 (outage) both fall through to GitHub, never to a
  purchase.
- `bin/lib/gh-pr-list.sh` `harness_pr_author_match` — whose review counts.

**A frozen head carries no verdict.** Both caps — the pre-existing no-verdict
cap and the in-flight cap — write their terminal record through `rp_freeze`,
which deletes `verdict`, `tier`, `served`, `rehydrated_from` and the merge
counters before setting `sha`. `sha` is what stops the re-buy, but it is also
what arms `merge_retry`, so a freeze written as a `+` merge carries a PREVIOUS
head's APPROVE onto the NEW sha and the next tick squash-merges a head nobody
read. That was live in the first cut of this change and in the no-verdict cap
before it; `tests/review-prs-gh-dedup-test.sh` G14 and G15 pin both.

**The in-flight marker sits below the free reads.** It is written after the
diff, the body and the thread are in hand, immediately before `review_claim`.
The budget counts SESSIONS, so it may only be charged where a session is about
to start: an earlier cut wrote it before `gh pr diff`, and two ticks of a
transient GitHub read failure then spent the whole budget, froze the head and
paged "started a review 2 times" with nothing bought. G16 pins that.

**Knobs:** `REVIEW_INFLIGHT_MAX` (default 2, listed in
`env-templates/global.env.example`) — how many times one head may enter a
review without a verdict coming back before the lane freezes it.

**How to drive it:**
- `HARNESS_TEST_SANDBOX=1 bash tests/review-prs-gh-dedup-test.sh` — drives the
  REAL script against a scratch `$HARNESS` with `gh`, `agent-call` and the jobs
  client stubbed, and counts `agent-call.sh` invocations. Covers: a reseeded
  ledger with a harness review on file for the head (0 calls, entry rehydrated,
  source recorded), the same under the App identity, a review for an OLDER head
  (1 call), a GitHub read failure (1 call, exactly one fail-open line, no
  ALERTS), a 0-byte ledger (0 calls, and only BH-977's own reseed line), a
  stranger's body carrying the marker (1 call), a body with no parseable
  VERDICT (0 calls, verdict taken from the review state, head still terminal),
  the D1 row answering, a D1 row with no provenance rehydrating as
  `rehydrated` AND beating once across three ticks, a D1 row that carries
  provenance beating nothing, a rehydrate preserving the CI-debounce
  bookkeeping while replacing the judgement, a D1 row bound to another head, a
  D1 outage falling through to GitHub, the in-flight retry and its cap, the
  marker landing before the spend and clearing after, both freeze sites
  dropping the verdict so nothing merges an unreviewed head, a diff-read
  outage that must not spend the attempt budget, the GitHub rung's beat, a
  mutation with the whole dedup removed, and the static pins that the marker is
  spelled once and the dedup block's code reaches GitHub only through
  `gh api`.
- `HARNESS_TEST_SANDBOX=1 bash tests/review-prs-state.bh-977-test.sh` — the
  ledger-integrity half; its S6/S7 assertions were rewritten here to test the
  property (a refused write lands no verdict) rather than the byte shape, which
  the in-flight marker changed.

**Preconditions / seed needs:** none beyond the fixture suite. On a box, an open
external PR with a prior harness review is needed to see a rehydration.

**Verify it works (on a box):**

```sh
grep 'ledger entry rehydrated' /root/harness/logs/pr-reviews.log
grep 'could not read' /root/harness/logs/pr-reviews.log        # fail-open reads
jq '.[] | select(.rehydrated_from)' /root/harness/state/<project>.pr-reviews.json
```

The direct proof is destructive and belongs on one box at a time: move the
ledger aside, run the lane once, and confirm `logs/pr-reviews.log` shows
rehydration lines instead of `verdict=` lines for heads that already carry a
harness review.

**What is still uncovered:** a review that had to fall back to `gh pr comment`
(when `gh pr review` was refused) is a COMMENT, not a review, so it is
invisible to `repos/<slug>/pulls/<n>/reviews` — and, per the D1 note above, the
jobs ledger does not hold a row for this lane either. That head is bought once
more after a wipe. Neither source covers it today; #1064 closes it from the
D1 side.

**Manual-only / not automatable:** the live wiped-ledger drill above — move the
ledger aside on one box, run the lane once, confirm rehydration lines instead
of `verdict=` lines.
