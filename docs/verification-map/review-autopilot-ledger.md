# Review-autopilot ledger (a review is paid for once, delivered later)

**What it is:** `bin/review-autopilot.sh` buys one adversarial Fable review per
harness PR that has been open more than 12 hours, and dedupes that spend on
`state/review-autopilot/<slug>-<num>-<head12>`. Until BH-1018 that key file was
written only after `gh pr comment` succeeded, and an empty model answer wrote
nothing at all. Both are non-success exits, and both left the guard false — so
the next hourly tick bought the same review again. The Mac-side runaway-spend
audit of 2026-09-17..19 measured it across the fleet: **156 of 372 review spends
were re-buys**, one PR sixteen times.

The fix is the shape `~/.claude/rules/metered-api-dedup.md` asks for: the
persisted check runs BEFORE the billable call, the call has three outcomes
rather than two, "succeeded but returned nothing" is billed and terminal, and
terminal state is written on every non-success path.

The key file's first line is now the state machine, and a tick dispatches on it
before it spends anything:

| first line | means | what the next tick does |
|---|---|---|
| `reviewed <stamp> verdict=<V>` | posted | nothing, ever, for this head |
| `skipped <stamp>: …` | `review-prs.sh` covered this head | nothing |
| `status=reviewed-unposted <stamp> verdict=<V> tries=<n>` | PAID FOR, comment cached in `<key>.body` | re-posts those bytes, **no model call** |
| `empty <stamp> n=1` | the model returned nothing (billed) | one more call, then terminal |
| `empty-terminal <stamp> n=2` | nothing there, billed twice | no further call for this head |
| `unposted-terminal <stamp> verdict=<V> tries=<n>` | paid for, cached, undelivered `REVIEW_AUTOPILOT_POST_TRIES` times (post attempts **and** failed marker reads — both count, both bound the lane) | nothing; the `.body` is kept for a human to post, and the transition fires one ALERTS line + one `fleet_alert` beat, worded for what the number counts |
| `failed <stamp> n=<k> rc=<rc>` | the agent call DIED (rc≠0, and not a not-billed code): billed or unknowable | one more call, up to `REVIEW_AUTOPILOT_FAIL_TRIES`, then terminal |
| `failed-terminal <stamp> n=<k> rc=<rc>` | it died `FAIL_TRIES` times | no further call for this head |

Anything else on that first line — a zero-byte key, a truncated write, hand-edited
junk — is **unreadable state**, and the tick logs one line per key per tick
naming the key path and the words `unreadable state`. It still buys nothing: an
unreadable guard is not permission to spend. Before BH-1066 it fell into a bare
`*) continue`, which disabled the lane for that head for ever and looked exactly
like "already reviewed".

**The agent-call rc decides all three of cap, key and post (BH-1066).** It used
to be discarded (`|| true`) with the daily cap charged unconditionally on the
next line. `bin/agent-call.sh` exits **75/76/77/78/79** when *nothing was called
and nothing was billed* (a lock, no account with headroom, the hub refusing build
work, a no-tools refusal, an argv-only or cliff-routed refusal) and leaves a
one-line marker in the out file — so the lane posted that marker to the PR as the
review, stamped `reviewed … verdict=UNPARSED`, and charged a spend that never
happened. A head reviewed that way could never be reviewed again. Now:

- **75/76/77/78/79** → no key, no cap charge, nothing posted, one log line
  (`agent-call returned before billing (rc=… : <marker>)`), retried next tick.
- **any other nonzero rc** → counted (billed, or billed in a way this lane cannot
  see), parked as `failed n=<k> rc=<rc>`, and the out file is **never posted** —
  a partial review or a `CONTEXT KILL:` truncation is a verdict on code nobody
  finished reading.
- **rc 0 with empty output** is unchanged: billed, `empty`, terminal on the
  second. "Nothing was called" and "it was called and said nothing" are
  different facts and take different arms.

**A re-post asks the PR first (BH-1066).** `gh pr comment` can put the comment up
and still exit nonzero — a 502 reading the response, a token that died after the
write — and the rc alone cannot tell that from "it never landed". Probed: three
identical reviews on one PR in three ticks. So when `tries > 0`, `ap_post` makes
**one** REST read of `repos/<slug>/issues/<num>/comments?per_page=100` and looks
for `<!-- harness-review-autopilot <head12> -->`. Present → the key is promoted to
`reviewed <stamp> verdict=<V>`, the `.body` is dropped, nothing is posted. Absent
→ it posts as before. Unreadable (the endpoint failed) → it does **not** post
blind; that tick counts as a try, so `POST_TRIES` still bounds it. The FIRST post
makes no REST call: nothing can have landed yet, and the happy path must not buy
an extra call. It reads the first 100 comments only — one call is the bound, and
a PR past 100 comments falls back to the old re-post behaviour.

**And the marker is AUTHOR-BOUND, because that path deletes money** (round-2
review of #1093, confirmed by probe: with the fixture's comment author swapped to
a stranger the suite still passed — the key settled and the `.body` went in the
bin). The marker on its own is a dedup hint, not a credential: anyone with
comment rights could paste `<!-- harness-review-autopilot <head12> -->` on a
parked head and the paid-for review nobody had read would be dropped. So the
comment must ALSO be written by a login in `harness_pr_authors_json`
(`bin/lib/gh-pr-list.sh`), normalised the way that file normalises it — `app/`
prefix and `[bot]` suffix stripped, because REST, GraphQL and git each hand us a
different one of the three spellings of the App. It is exactly the binding
`mc_autopilot_verdict` applies to the same marker. **Fail-closed:** no callable
author list, or an empty one, makes the marker count as ABSENT (one log line,
then the bytes are posted). A duplicate comment is cheap; a review that was
bought and then deleted on a stranger's say-so is not.

`reviewed <stamp> verdict=<V>` is this lane's own dedupe ledger, and since
BH-1951 nothing else reads it. `mc_autopilot_verdict` in `bin/lib/mc/classify.sh`
reads the `source=box` verdict row that `ap_box_row` POSTs right before the key
reaches `reviewed` (then the PR comment). The key still lands only after the
comment is up AND the row recorded (or the row was skipped as not configured,
logged). A row POST that fails leaves the key `status=reviewed-unposted`
(tries+1), and the next tick retries the row with no model call and no second
comment.

The daily cap (`REVIEW_AUTOPILOT_DAILY_CAP`) still counts the SPEND, not the
success — a review that takes two ticks to deliver counts once, an empty answer
counts because it was billed, and a died call counts because it may have been.
A call that never happened (the not-billed rcs above) does not.

**The `.body` outlives the sweep, not its PR (BH-1066).** The 90-day
`find … -delete` used to include `<key>.body`, so the paid-for review an operator
was alerted to post went in the bin with the money. `*.body` is now exempt from
that sweep. It is dropped instead when its PR is **no longer open** — and that is
earned by a POSITIVE per-PR read, never by absence from a list. The open-PR list
the tick already fetched is only a free "still open, skip" short-circuit, because
`harness_pr_list` can return rc 0 and a SHORT list (its REST rung walks a bounded
number of pages of all open PRs newest-first and only logs `cap_reached`; its
`gh pr list` fallback returns rc 0 when one author's list succeeded and another's
failed — the BH-847 rate-limit shape), and both drop the OLDEST harness PRs, which
are exactly the long-lived heads that go `unposted-terminal`. Anything the list
does not carry is asked through `gh_rest_pr_state` (`bin/lib/gh-rest.sh`, REST and
never GraphQL), and only rc 0 with a state that is not `open` deletes: 44 (the
token cannot see it) and 75 (network, rate limit, unparseable) are "we could not
look" and keep the body (D12). The KEY is untouched by the drain and still ages out
at 90 days, so a head nobody ever merged is reviewed once more after a quarter.

**How an operator reaches it:** there is no UI. The lane is the hourly
`review-autopilot.sh` line in `cron/hub.cron` (`:17`).

**Primary lanes / scripts:**
- `bin/review-autopilot.sh` — the key-state dispatch above the daily-cap check,
  the `ap_post` helper (the one writer of `reviewed …`, the one caller of the
  marker read, and the source of the promote's rc 2 — settled, nothing posted),
  `ap_unposted_alert`, the agent-call rc `case`, `ap_attempts` (the ONE
  non-success counter the empty and died tracks share, so a head alternating the
  two still goes terminal), the cache write that precedes `gh pr comment`, and the
  per-project `.body` drain over `gh_rest_pr_state`.
- `bin/lib/mc/classify.sh` `mc_autopilot_verdict` — reads the autopilot's
  `source=box` row (`vd_box_word`, BH-1951), never this key file.
- `bin/beat.sh` — the `fleet_alert` beat fired on the `unposted-terminal`
  transition, akey `review-autopilot-unposted:<slug>#<num>:<head12>`.

**Knobs:**
- `REVIEW_AUTOPILOT_DAILY_CAP` — dispatched reviews per project per UTC day, 0 =
  unlimited (unchanged).
- `REVIEW_AUTOPILOT_POST_TRIES` — gh attempts at one cached review before it
  parks as `unposted-terminal`, default 6. A tick that could not READ the
  comments counts too (it is what bounds the lane when that endpoint stays
  down), so the alert says "could not be delivered N times (post attempts +
  comment reads)" rather than claiming N refusals. No model spend either way.
- `REVIEW_AUTOPILOT_FAIL_TRIES` — agent calls that DIED (rc≠0 and not one of the
  not-billed codes) before the head parks as `failed-terminal`, default 3. It has
  a default, so no environment needs it set.

**How to drive it:**
- `HARNESS_TEST_SANDBOX=1 bash tests/review-autopilot-post-retry-test.sh` —
  drives the REAL script against a scratch `$HARNESS` with `gh`, `agent-call.sh`
  and `beat.sh` stubbed and one harness PR a day old. Covers: a failing
  `gh pr comment` (key + `.body` land, one model call), the retry tick (posted
  bytes are the cached bytes, still one model call, first line becomes the
  `reviewed` format, cap counted once), the real `mc_autopilot_verdict`
  reading nothing off the key file, posted or unposted (BH-1951),
  two empty answers (`empty n=1` then `empty-terminal`, third tick makes no
  call), and a cache that is gone (re-reviews rather than posting nothing).
- `HARNESS_TEST_SANDBOX=1 bash tests/review-autopilot.bh-1066-test.sh` — the same
  scratch tree, with the agent-call stub's exit code and a `gh pr comment` that
  LANDS and then exits nonzero under fixture control. Covers: rc 76 and rc 79
  write no key, charge no cap, post nothing and retry next tick; a died call
  (rc 1) parks `failed n=1..2` then `failed-terminal n=3` and is never posted;
  a parked `failed` head recovers on the next good call; rc 0 + empty output is
  still billed; zero-byte and corrupt keys log one `unreadable state` line per
  tick and buy nothing, while every known terminal shape stays silent; a landed-
  but-nonzero post is promoted without a second comment (and a marker for a
  DIFFERENT head, a marker from a login outside `HARNESS_PR_AUTHORS`, or a
  failed comments read, is not — while the App's own `x[bot]` spelling still
  promotes); the `unposted-terminal`
  transition alerts and beats exactly once; and the `.body` survives the 90-day
  sweep, survives a failed PR list, and is dropped when its PR is no longer open.
- `HARNESS_TEST_SANDBOX=1 bash tests/merge-conductor-deadend-test.sh` — the
  conductor consuming the autopilot's `source=box` verdict row.
- `HARNESS_TEST_SANDBOX=1 bash tests/verdict-files-retired.bh-1951-test.sh` — the
  row POST before each `reviewed` write, a failed POST retried without a model
  call, and the conductor reading rows, never the file (BH-1951).

**Preconditions / seed needs:** none beyond the fixture suite. On the hub, a
harness PR open more than 12 hours is needed to see a review at all.

**Verify it works (on the hub):**

```sh
ls /root/harness/state/review-autopilot/ | head            # head-keyed rows
head -1 /root/harness/state/review-autopilot/*-*-* | sort -u | head
ls /root/harness/state/review-autopilot/*.body 2>/dev/null # paid-for, undelivered
grep 'cached review posted on retry' /root/harness/logs/review-autopilot.log
grep 'empty review twice — terminal' /root/harness/logs/review-autopilot.log
grep -E 'before billing|the review call died|unreadable state|promoted to reviewed|dropped the cached review body' \
  /root/harness/logs/review-autopilot.log | tail
grep 'unposted-terminal:' /root/harness/logs/ALERTS.log     # paid for, undelivered
```

The user-visible effect is in the log: an `@<head12>` that already appears with
a `reviewed ->` or `empty-terminal` line never appears again with a new spend.
Counting distinct `@<head12>` values against `reviewed ->` lines over a day is
the fleet-level version of the audit's requests-per-distinct-input ratio.

**Manual-only / not automatable:** the `unposted-terminal` drain. A review that
gh could not take six times is paid-for work sitting in a `.body` file; posting it (or
deciding the PR has moved on) is an operator action, and the lane deliberately
does not keep trying. Since BH-1066 the operator is **told**: the transition
writes one `logs/ALERTS.log` line and fires one `fleet_alert` beat, both naming
the exact command —

```sh
gh pr comment <num> -R <slug> --body-file /root/harness/state/review-autopilot/<key>.body
```

— and the `.body` is kept until that PR is no longer open, so the alert is still
actionable weeks later. That is the whole reason it is exempt from the 90-day
sweep.
