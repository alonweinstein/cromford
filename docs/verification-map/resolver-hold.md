# A HOLD on the ticket stops every rebuild

**What it is:** `bin/lib/hold.sh`, and the two lanes that ask it whether a
ticket may be (re)started at all — `bin/blocked-resolver.sh`'s rebuild rung and
`bin/orphan-reconcile.sh`'s owner class (d). It answers one question, once:
*has a human said not yet?*

**Why it exists:** console alert 6726 (2026-09-14). project-5 #414's parent PR
was CLOSED, the issue put on HOLD and de-labelled by the operator ("do not rebuild",
07:03Z) — and `bin/blocked-resolver.sh` enqueued a fresh build of it three times
that morning (05:04, 06:44, 08:24Z). The rung read the PR's merge state and its
own counters; the only `gh issue` calls in the whole file were the two comment
WRITES. A human instruction on the ticket was invisible to the one lane whose
job is restarting tickets. The reconciler did honour a HOLD, and never let one
go: any `HOLD` ever written held the ticket for ever, which in a harness where
nothing waits on a person (the operator, 2026-09-13) is a ticket nobody can un-park.

**How an operator reaches it:** it is not a cron lane of its own — it is a gate
inside two lanes:

| Script | Where | Refuses | Result |
|---|---|---|---|
| `bin/blocked-resolver.sh` | `br_hold_gate`, called at the top of `br_rebuild_fresh` (after the MERGED check, BEFORE the cap check) | the rebuild rung | rc 1: nothing closed, nothing enqueued, **no rung spent**, row parked `HELD`, one `[resolver] HOLD respected <ticket>` line |
| `bin/blocked-resolver.sh` | `br_hold_gate` again, in the test-tamper ACCEPT branch before the `RESUME_BUILD=… run-build.sh` launch | the in-place resume | same. **That branch is unreachable today** — its `${rec##*/pool-}` guard compares a full path with a basename — so every ACCEPT currently takes the pool-copy arm, which the first call site gates. The gate is there so the hole cannot reopen when that guard is fixed |
| `bin/blocked-resolver.sh` | `br_hold_recheck`, in `br_one` right after the ABANDONED early-return | the whole tick for that row | rc 3 — and rc 3 does **not** count against `BR_PER_TICK`, because that budget counts rungs and a held row took none |
| `bin/orphan-reconcile.sh` | owner class (d), inside the python3 classifier | the launch | verdict `OWNED hold:comment` / `hold:title` / `hold:body`; the ticket is never `setsid run-build.sh`'d |
| `bin/lib/mc/rebase.sh` | `mc_hold_keeps_pr`, inside `mc_kick_ci` and `mc_close_for_rebuild` | the CLOSE (and the close half of the CI kick) | rc 1 from both, one `<slug>#<n> held, PR kept` line, and the PR untouched. An `abandon:` verdict, a clear one, an unreadable read, a PR that is not open, a head ref that is not a build branch and a box with no hold library all close exactly as they did. The ticket comes from `mc_ticket_of_branch`, NOT from the ref's trailing digits — `ticket/bh-1000-r2` is ticket #1000, not #2 — and a HELD answer is memoised for the life of the process, so a held PR costs its three reads once per tick rather than once per kick attempt |
| `bin/fly-pool.sh` | `pool_spawn_decision` gate 1 (`pool_hold_check`) | the spawn | `skipping <KEY>: HOLD (<why>)`, the queue file LEFT in place for the next tick, `state/pool/<p>/<KEY>.held` written, and ONE comment on the ticket naming the matched line and `RESUME` (`<KEY>.hold-noted`). Both files are deleted the moment the gate answers clear |
| `bin/launch-fastpath.sh` | condition 12, in its own copy of the reconciler's classifier block (pinned byte-identical by `tests/launch-fastpath-test.sh` T1.32) | the fast-path launch | `FASTPATH-DECLINED <key> :: HOLD in body` / `in title` / `in comment`; the key falls through to the triage tick. **The body arm is `body_re`, the same line regex** — four lanes, one reading of what a body hold is |
| `bin/blocked-resolver.sh` | `br_one`, once the ladder has resolved the rung and before the `-> <rung>` line (BH-2504) | every rung but the two rebuilds (they gate themselves) and `adjudicate` (a ruling; its restarts are gated where they happen) | `br_rung_hold_gate`: rc 3, row parked `HELD`, one `HOLD respected` line — a `review-changes-requested` fix round on a held ticket is never chosen (the #2476 shape). An UNREADABLE read runs the rung with one line: every rung that writes the branch pushes through `hold_push`, which re-reads and refuses on the same answer |
| every PR-branch writer | `hold_push` (`bin/lib/hold-push.sh`), at the push itself (BH-2504) | the push | re-reads the hold AT the push (the #2481 shape: a HOLD 29 s after the round started), pushes `--force-with-lease=<branch>:<start sha>` so a lead commit that landed mid-round is never overwritten. rc 3 held (the `hold` label counts), rc 4 unreadable, rc 1 the lease; one line, nothing pushed. A board ticket has no issue: the lease is the whole guard. `tests/hold-push-ratchet.bh-2504-test.sh` keeps every other `git push` under `bin/` on an allowlist with its reason |

**What counts as held** (`hold_classify`, in this order): the issue is not
`open` → `closed`; the `hold` label is on it → `hold:label` (BH-2504: a
pause no RESUME lifts — taking the label off does); the `ai-build` label is
absent → `label-absent`; otherwise
the thread by RECENCY — comments newest-first, `user.type == "Bot"` skipped, the
first DECISIVE comment wins (a lift → clear, a `HOLD` word → held); with no
decisive comment, the title hold IDIOM, then an explicit `HOLD` LINE in
the body; otherwise clear.

**A TITLE holds only in the idiom** (`HOLD_TITLE_RE`, 2026-09-28): `(HOLD)`,
`(ON HOLD)` or `[HOLD]` anywhere, or `HOLD` / `ON HOLD` opening the title (after
an optional leading ticket key, `TK-9:`) followed by `:` or a dash (`—`, `–`, `-`). A title that names the hold
feature ("per-PR HOLD / RESUME / DROP", `REVIEW_D1_HOLD_MAX_H`, `_` being a word
character) holds nothing.

**A COMMENT holds only when its first non-blank line starts with `HOLD`**
(`HOLD_COMMENT_RE`, BH-6297): `HOLD`, `HOLD —`, `HOLD:`, `HOLD this until …`.
A `HOLD` in a later line, `Please HOLD`, a `>` quote, a `- HOLD` list item, a
code span, `HOLD-free` and `HOLDING` hold nothing (#5239: "the Cloud PRs … are
on HOLD here" in a fourth line held a launch blocker for 4 h 27 min).

**A BODY holds only on a line that BEGINS with the instruction**
(`HOLD_BODY_RE`, BH-1461): `HOLD` alone on its line, `HOLD:`, `HOLD —` (en dash
and hyphen too). A mid-sentence mention, a code span, a `>` quote and a
`| HOLD |` table cell are prose and hold nothing. On 2026-09-22 the
word-anywhere rule held BH-1325 ("after the operator HOLD (…)"), BH-1381
("`merge-conductor.held_pages`") and BH-1419 ("a per-project HOLD row") on every
tick for four hours, so a ticket that DESCRIBES this mechanism could never be
built. Titles and comments keep the word rule: `Compliance P7 (HOLD): EU
residency` is the title idiom, and a comment is a deliberate gesture rather than
documentation.

**The operator shapes that now hold NOTHING**, said out loud because a non-hold
is silent by design: `**HOLD**`, `- HOLD: …`, `## HOLD` and `HOLD until …` are
all prose to this regex — the first three do not open the line with the bare
word, and the fourth carries no `:` or dash after it. That is in contract
(BH-1461): the gesture that holds is `HOLD:` at the start of its own line.
`(?m)` in the pattern is required by BOTH engines — Python `re` and jq's
Perl-syntax Oniguruma each anchor `^` to the whole string without it — so it is
never a redundancy to clean up.

**The verdict names the line that decided:** `hold:body <line>`,
`hold:title <line>`, `hold:comment <at> <line>`. The token in front is what
callers match on; the tail is for the human, and `bin/fly-pool.sh` quotes it
back on the ticket.

**A HOLD PAUSES; IT NEVER CLOSES** (BH-1460). `HOLD` means "stop the automation
on this ticket" — no fix rounds, no rebuilds, no re-reviews — and it leaves an
open PR exactly as it is. The word that throws the work away is `ABANDON` (or
`CLOSE-PR`), capitals and word-bounded like the lift vocabulary, **in a comment
only**: a title or body that says it is prose about the word, which is BH-1461's
lesson applied before the incident rather than after it. A negation in front of
it is not an instruction either ("Do NOT ABANDON this yet"). The verdict is
`held<TAB>abandon:comment <at> <line>` — still rc 1, because an abandon is also
"do not build", so a caller that reads only the rc is unchanged. Callers that
can CLOSE something read it through `hold_is_pause` / `hold_is_abandon` rather
than matching the string three different ways.

On an `abandon:` verdict `bin/blocked-resolver.sh`'s `br_hold_abandon` closes
the PR with a comment **naming the word that did it**, writes the ABANDONED
terminal, moves the conductor row and closes the queue row — and writes no
ALERTS line, because an obeyed instruction is not an incident.

**What lifts one:** a person's comment whose FIRST word is `RESUME`,
`RELEASE`, `RELEASED`, `UNHOLD` or `PROCEED`, any case (`HOLD_LIFT_LEAD_RE`,
BH-3435), and then a capital `HOLD` elsewhere in it never re-holds
("RELEASED … This supersedes the HOLD." lifts); anywhere in a comment, the
capital words `RESUME` / `UNHOLD`, or an explicit phrase — `hold lifted` /
`hold is off` / `lift the hold` / `unhold`. Nothing else, and never behind a
negation or a condition ("Do NOT RESUME this yet", "until the operator lifts the
hold", "if the hold is lifted we can build"). A bot's comment never lifts, and
neither does the harness's own `<!-- harness:hold-ambiguous` note.

**When a person's newest comment says neither** on a ticket held by a comment,
the title or the body, `hold_check` / `hold_read` raise ONE
`lane-alert.sh --severity warn --id hold-ambiguous:<slug>#<n>:<comment id>`
quoting its first line, and post one ticket comment naming the five lift words.
The verdict stays `held`. Dedupe: `state/hold-ambiguous/<owner>__<repo>-<n>-<id>`
per box, the `hold_ambiguous` ledgers row across boxes. The five
regexes live in `bin/lib/hold.sh` as `HOLD_COMMENT_RE`, `HOLD_WORD_RE` (the
no-lib python fallback only), `HOLD_BODY_RE`,
`HOLD_LIFT_RE`, `HOLD_ABANDON_RE`, `HOLD_NEG_RE` and are exported, so the
reconciler's python3 classifier reads the same strings the resolver's jq does.
In the thread walk a LIFT is asked first, then an ABANDON, then a HOLD, so the
recency law reads the same in every direction: `ABANDON` then `RESUME` is clear,
and `ABANDON` then `HOLD` is a pause again.

**How to drive it:**

| what | how |
|---|---|
| the classifier, including every adversarial negative | section 1 of `bash tests/resolver-hold-test.sh` |
| the resolver, end to end against the real script | sections 2-10 of the same suite (HOLD newest, label absent, issue closed, unreadable, the lift, the slot, the resume path, an in-app lane, observe mode) |
| the reconciler's recency rule | section 12 of `bash tests/orphan-reconcile-test.sh` (and its sections 1 `#14` / `#887` rows, unchanged) |
| the pool's held marker, its one-time comment per arm (body / title / comment) and a prose-HOLD body that still spawns | cases s / s2 / t / u of `bash tests/fly-pool-respawn-cap.bh-1075-test.sh` |
| the fast path's body arm, and that its classifier block has not drifted from the reconciler's | T1.4c and T1.32 of `bash tests/launch-fastpath-test.sh` |
| the fleet page's held / failed split | `bash tests/fleet-status-held-queued.bh-1461-test.sh` |
| the pause/abandon split, and the conductor's two closers obeying it | section 1 (`abandon:comment` rows, the two predicates) and section 2b of `bash tests/resolver-hold-test.sh`, plus `bash tests/conductor-hold-keeps-pr.bh-1460-test.sh` |
| red-before-green | `bin/repro-gate.sh <merge-base>` — sections 2-10 fail at the base tree, where the resolver never reads the issue |

**Files it owns on a live box:**

- `logs/blocked-resolver.log` — one `[resolver] HOLD respected <KEY> (<why>) —
  no rebuild, no enqueue, PR <url> left as it is` line per transition, and one
  `HOLD lifted on <slug>#<n> — the ladder resumes with its counters intact` line
  when the thread releases it. Nothing per tick in between.
- `state/blocked-resolver/<project>/<cap-key>.json` — `.outcome == "HELD"`, the
  attempt actions `held` / `hold-unreadable` / `hold-lifted`, and `.held_rec`.
- `state/blocked-resolver/<project>/<cap-key>.hold-unreadable` — the "gh could
  not answer for this ticket" episode marker, so an outage writes ONE attempt
  rather than one every ten minutes. Deleted the moment a read succeeds.
- `<build-record>/.blocked-resolver-held` — the record-level twin of
  `.blocked-resolver-abandoned`. `br_from_builds` keeps re-offering a record that
  has it *while the ladder's state row still says `HELD`* — that is how a park
  whose PR is already closed (the incident's own shape, and a park the conductor
  therefore has no row for) gets its issue re-read every tick. With no `HELD`
  row the marker means what `.blocked-resolver-abandoned` means: out of the
  candidate list.
- `logs/<project>.log` — the reconciler's `reconcile: … owned=…` line, with the
  `hold:*` verdicts visible under `--explain`.

**Knobs:** none. The label name `ai-build` is the fleet-wide literal, and the
hold vocabulary is code, not config — a per-box regex is a per-box definition of
"do not build this".

**What must never regress:**

- **A missing lib fails OPEN in the resolver and CLOSED in the reconciler, and
  both of those are today's behaviour.** `br_hold_gate` returns "proceed" when
  `hold_check` is not defined (a box mid-sync runs the pre-2026-09-18 code
  rather than dying on an unset function); the reconciler's fallbacks are the
  word regex it always had and NO lift vocabulary, so every HOLD keeps holding.
  Neither direction invents an answer.
- **Unreadable is never clear.** rc 2 (gh non-zero, an empty body, a rate limit)
  spends no rung, closes nothing, enqueues nothing, holds the conductor hand-off
  where it was, and writes ONE `hold-unreadable` attempt per episode. The hour
  both hub PATs shared one exhausted GraphQL bucket is exactly the hour a "clear"
  default would have rebuilt every held ticket on the board — and the hour a
  per-tick record write would have buried what the ladder actually TRIED under
  144 copies of "could not read it". The hold attempts are also read past by
  `br_from_rebuilds`, which finds a build in flight by the last `rebuild-fresh`
  attempt: a failed read must not erase a rebuild this lane is waiting on.
- **The thread has no size limit.** `hold_classify` feeds both documents to `jq`
  on STDIN, never through `--argjson`: a single argv string dies at 131072 bytes
  (Linux `MAX_ARG_STRLEN`), and a ticket with ~60 harness comments on it is
  already past that. Through argv, such a ticket reads UNREADABLE on every tick
  for ever — never rebuilt, never lifted, and silent about it. Section 1 pins a
  thread larger than the limit.
- **The read is REST and it is bounded.** `gh api repos/…/issues/N` plus one
  `--paginate` comments call, on the core bucket — never `gh issue view --json`,
  which is GraphQL and spends the bucket the whole hub shares
  (docs/verification-map/gh-pr-list-rest.md). Two calls per gated decision,
  bounded by `BR_PER_TICK`.
- **The gate runs BEFORE anything irreversible.** Before `br_close_pr`, before
  `br_enqueue_fresh`, and before the cap check that writes the ABANDONED alert —
  so there is no state where a PR has been closed and the rebuild is then
  refused on a hold, and a held ticket never collects an ABANDONED comment.
- **A HOLD NEVER CLOSES A PR** (BH-1460). Not in this lane, and since this
  change not in the merge conductor either — the two functions that can throw a
  PR away ask the ticket first, at the choke point inside them rather than at
  their eleven call sites. `ABANDON` is the only word that closes, and it says
  so on the PR it closes. `mc_kick_ci` is the sharp edge: it CLOSES and reopens,
  and a reopen GitHub refuses leaves the PR closed until a person intervenes.
- **A HELD ROW IS NOT A QUEUED ONE** (BH-1461). `bin/fleet-status-push.sh`
  counts a `build_queue` row (or a `state/build-queue/<p>/*.json` file) as
  `queue_depth` only when no `state/pool/<p>/<KEY>.held` marker exists for it
  and it is not a `*.failed.json` park, and ages `oldest_queued_min` over the
  same set; the rest ride in `held` and `failed`. Otherwise a pool with nothing
  to do reads as wedged — 8 queued / oldest 265 min on 2026-09-22 — and
  `worker/watchdog/src/index.js` pages on that number at 40 minutes. They are
  REPORTED, never dropped: parked work invisible on the fleet page is the
  opposite error. Driven by `bash tests/fleet-status-held-queued.bh-1461-test.sh`.
- **A respected hold is logged, and said on the ticket exactly ONCE.** No
  `logs/ALERTS.log` line and no page: it is an instruction being obeyed, not an
  incident. The resolver says nothing on the board at all; the pool posts one
  comment per held episode (`<KEY>.hold-noted`), because a silent skip is how
  three authors watched their tickets not build for four hours with no way to
  see why. The sentinel dies with the marker, so a re-hold after a `RESUME`
  speaks again. One line per transition, and every source that can re-offer the park
  — the conductor hand-off, the build record, the pool queue row — re-reads the
  issue each tick, so the lift needs no human plumbing.
- **HELD is terminal for the LADDER, not for the ticket.** No rung, no counter,
  no `PER_TICK` slot — and the counters survive the hold, so a lifted ticket
  resumes its ladder where it stopped rather than starting from rung 1.
- **An in-app product board is not gated.** project-3, project-4, project-1 and project-2
  tickets are not GitHub issues; `br_hold_issue` answers "nothing to read" and
  the rung behaves exactly as it did. Those boards are gated at dispatch time by
  `bin/triage-gate.sh --buildable`.
