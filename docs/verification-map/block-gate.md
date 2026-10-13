# The BLOCK gate (a human BLOCK refuses every merge)

**What it is:** one shared gate, `bin/lib/block-gate.sh`, that reads a PR's
conversation, its review bodies and — on an Issues-board project — the ticket
thread immediately before a merge, and refuses when a BLOCK marker is newer than
the head and no later comment from the same author clears it (BH-762). It is
sourced by `bin/lib/merge-conductor-lib.sh` (the shim over `bin/lib/mc/`), which every automatic merge path
already sources, so the six lanes share ONE answer to "is this PR blocked".

| lane | where the gate is called | what it does on a block |
|---|---|---|
| merge conductor | `bin/merge-conductor.sh`, `READY` arm (`# >>> block gate`) | logs, comments once, row stays `READY`, no merge budget spent |
| tier-2 merge sweep | `bin/merge-sweep.sh` (`# >>> block gate`) | logs, comments once, `continue` — NOT `sweep_record`ed |
| box merge queue | `bin/merge-queue.sh` `bg_queue_hold`, both landing paths, and again in the train's landing loop | logs, comments once, entry stays queued (never `.blocked`) |
| union merge train | `bin/batch-resolve.sh` `bg_batch_hold` (`# >>> batch candidates`) | logs, comments once, the PR is simply not a candidate — no exclusion row to undo |
| tier-1 gate in a build | `bin/run-build.sh` (`# >>> tier-1 merge gate`) | stands down to `PR_CREATED`, the conductor owns it |
| reviewer | `bin/review-prs.sh` `bg_review_hold` | APPROVE posted, merge withheld, no box-queue entry |
| CI-only BLOCK self-clear | `bin/lib/mc/block-ci.sh` `mc_block_ci_step`, from the conductor READY arm after a refusal | dispatches CI once per (PR, head), writes `block_ci_clear` on an all-`success` head; `bg_scan_read` then drops only the named id |

`bin/batch-resolve.sh` needs its own call rather than the conductor's: the
conductor holds a train's members and never reaches their `READY` arm while the
train is in flight, and the train is a new PR with an empty thread of its own.

The console `merge_pr` command (`bin/poll-commands.sh`) is deliberately NOT
gated: it is a human at Mission Control giving an explicit order.

**How an operator reaches it:** there is no UI and nothing to run by hand. The
lanes are `cron/hub.cron` (`bin/merge-conductor.sh` every 5 minutes,
`bin/merge-sweep.sh` every 10), the per-box crons for `bin/merge-queue.sh` and
`bin/review-prs.sh`, and `bin/batch-resolve.sh`, which the conductor tick spawns
itself. `docs/MERGE-CONDUCTOR.md` section 17 is the contract.

**How to drive it:**

| what | how |
|---|---|
| the conductor and the tier-2 sweep, both run WHOLE against a blocked thread | `bash tests/conductor-block-gate-test.sh` |
| the box merge queue (whole), the train's member and landing loops, the union train's candidate selection, the tier-1 gate and the reviewer (blocks extracted by their `# >>>` markers) | `bash tests/block-gate-lanes-test.sh` |
| the marker vocabulary, the two dates, the three sources, the failure answers, the cross-box dedupe marker, the posted-comment ledger | `bash tests/block-gate-lib-test.sh` |
| a same-author terminal verdict clearing its own BLOCK, the REST head-time read, the repeated-refusal alert, and PR #728's real thread replayed | `bash tests/block-gate.bh-1131-test.sh` |
| a lead/human MERGE verdict row on the live head lifting a MACHINE's comment BLOCK (never a person's), the `logs/block-gate.log` lift line, and the fail-closed negatives (older head, `box` row, no row, unreadable table) (BH-4468) | `bash tests/block-gate-human-over-bot.bh-4468-test.sh` |
| the marker predicates and the head binding on bodies longer than one pipe write, under `set -o pipefail` with SIGPIPE ignored (BH-1290) | `bash tests/block-gate.bh-1290-test.sh` |
| a BLOCK whose only finding is "CI did not run": the classifier and its negatives, the one dispatch per (PR, head), the green check, the clear row, and `bg_scan` lifting only the id that row names (BH-3934) | `HARNESS_TEST_SANDBOX=1 bash tests/block-gate-ci-clear.bh-3929-test.sh` |
| the alert threshold (default 6 consecutive refusals of the same PR, head and reason) | `BLOCK_GATE_STREAK_K=<n>`, an env/global.env knob, same shape as `BLOCK_GATE_ENFORCE` |
| the gate is OFF (rollback) | any of the above with `BLOCK_GATE_ENFORCE=0` — section G of the conductor suite pins warn-only |

**Files it writes on a live box:**

- `logs/merge-conductor.log`, `logs/merge-sweep.log`, `logs/merge-queue.log`,
  `logs/pr-reviews.log`, `logs/batch-resolve.log`, a build's `pipeline.log` — one
  `… MERGE_REFUSED block-gate: <comment-url> by @<login> at <time> blocks head
  <sha8> …` line per lane per tick, and `… block gate could not read <source> …`
  when a read failed.
- `logs/block-gate.log` — one stamped `block-gate: bot BLOCK <comment id> lifted
  by human verdict #<row id> (<slug>#<num> head <sha8>, <source> <verdict>,
  @<login>)` line per machine block a standing lead/human MERGE row lifted
  (BH-4468). Every lane that scans writes it, so a lift repeats once per tick
  until the PR merges.
- `state/block-gate/posted.txt` — append-only, `<slug>#<num> <head>
  <comment-id>`, one line per refusal comment actually posted. Written AFTER the
  `gh pr comment` succeeds. Per box, which is why it is not the only dedupe.
- `state/block-gate/streak/<slug>-<num>` — ONE line, rewritten in place:
  `<head>\t<reason>\t<count>\t<alerted>` (BH-1131). The consecutive-refusal
  counter. A clean scan deletes the file; a new head, a different failed read or
  a different blocking comment restarts it at 1. When the count reaches
  `BLOCK_GATE_STREAK_K` (default 6 — ~30 minutes at the conductor's 5-minute
  tick) the gate raises ONE `bin/lane-alert.sh` line, id
  `block-gate-stuck:<slug>#<num>:<head12>:<reason>`, naming the PR, the head,
  the reason and the count; it does not repeat until the head or the reason
  changes. The file is per (box, PR) and NOT per lane: on the hub the conductor
  (`*/5`) and the merge sweep (`6,16,…`) both write it, so six ticks is ~20
  minutes when both refuse, and the in-place rewrite is not atomic between those
  two cron lanes — worst case one alert early or one extra. `--severity warn`
  routes it to `bin/lane-alert.sh`'s batched digest, not to a page.
- D1, for a CI-only block only (BH-3934, conductor only, nothing under
  `state/` or `flags/`): a `pr_attempts` row `(repo, number, blockci, head)`
  written before the one CI dispatch or re-run POST on that head, and a
  `ledgers` row `block_ci_clear` / `<slug>#<num>@<head>` / `cleared` /
  `"<run-id> <block-id> [<block-id>…]"` once CI is green there.
  `logs/merge-conductor.log` gets `BLOCK_CI_DISPATCH <pr> <sha> <wf|run:id>`,
  `BLOCK_CI_DISPATCH_FAILED …` and `block-cleared-by-ci <pr> <sha> <run>`.
- the PR itself — one comment per (PR, head, blocking comment) FLEET-WIDE,
  naming the blocking comment's URL and carrying an invisible
  `<!-- block-gate refused <sha8> <comment-id> -->` marker. A lane on another box
  with an empty ledger looks for that marker before it posts, so the six lanes
  across three machines say it once between them.

**What must never regress:**

- **A read that fails is not a clear.** `gh` nonzero, or an answer that is not
  the agreed shape, means "cannot judge": nothing merges, nothing is posted, the
  next tick asks again. rc 2 is never mapped to rc 0. The single exception is an
  HTTP 404 on the TICKET thread, which means there is no such thread (the issue
  number was guessed from a branch name) and reads as empty; a 404 on the PR's
  own comments or reviews stays fail-closed.
- **Every row keeps its fields.** The comment rows are unit-separated, not
  tab-separated: `IFS=$'\t' read` collapses a run of tabs, so a comment with an
  empty `html_url` would shift its body into the url field and the BLOCK would
  vanish without a trace.
- **The happy path costs two reads and nothing else.** The head's commit dates
  are bought only when a BLOCK marker was actually found.
- **Author dates, not committer dates.** The conductor's own rebase rewrites
  committer dates; reading those would let the harness clear every block by
  rebasing, which is precisely the incident.
- **A BARE approve does not clear a BLOCK.** `LGTM`, `APPROVED`, or the word
  APPROVE on its own is somebody being agreeable, not somebody retracting a
  finding. What DOES clear (BH-1131) is a TERMINAL VERDICT LINE —
  `VERDICT: APPROVE`, `VERDICT: MERGE-WITH-NOTES`, `VERDICT: MERGE` — posted
  LATER than the block, by the SAME login, where that login is a MACHINE account
  (`<name>[bot]` / `app/<name>`), in a body that NAMES THIS HEAD. Before this,
  the review autopilot — which never writes the word UNBLOCK — could BLOCK a
  head that only a new commit could then free, and a new commit buys another
  review: PR #728 sat 7h40m on exactly that loop with CI green.
- **…and a PERSON's BLOCK is not clearable that way at all.**
  `bin/review-prs.sh` posts its `VERDICT: APPROVE` under whatever token the lane
  armed, and the fleet PAT's login is `operator` — the login the operator's own comments
  carry (live: project-3 #355, project-1 #691, project-2 #525/#526). The
  machine-login condition is what keeps the review lane from clearing a block a
  person typed; GitHub refuses `[`, `]` and `/` in a user name, so that login
  class cannot be worn by a human and the per-login drop can never reach a
  human's pending block.
- **A verdict is a fact about ONE sha.** The body must carry this head (the
  first 12 characters are enough; every lane writes the sha into its own
  footer, and the gate matches the SHA rather than the footer's wording). A
  verdict bound to another head, or one that names none, clears nothing, and a
  head the caller could not read fails closed. A different login's verdict
  clears nothing, a later `VERDICT: BLOCK` blocks again, and a comment that
  carries a BLOCK marker anywhere blocks whatever its last line says.
- **What this rule does NOT separate:** the harness's lanes share one App login,
  so a head-bound verdict from any of them clears a machine BLOCK from any
  other. That is the #728 escalation itself (the autopilot blocked, the
  conductor's head-bound re-review — which is handed the earlier review — cleared
  it), so it is deliberate; a per-lane credential is what would narrow it.
- **The head time is a REST read.** `repos/<slug>/pulls/<num>/commits`, never
  the CLI's GraphQL `--json commits`: the App token's GraphQL budget is capped
  and invisible in `rate_limit`, and an exhausted one made the gate answer rc 2
  `head-time` 81 times in one day without a single alert. The max is taken in
  the shell, not in jq — `--paginate -q` runs the jq program once per page, so a
  jq-side `| max` answers one line per page.
- **a CI clear lifts only the block id it names, on the head it names.** The
  `block_ci_clear` row is keyed `<slug>#<num>@<head>`, so a push invalidates it,
  and `bg_scan_read` drops a pending block only when its id is a whole word of
  the row's detail (fields 2..n; field 1 is the run id). A `skipped` job is not
  green, a run on another head is not green, and a ledger outage keeps the
  block: an unreadable row lifts nothing. A standing CHANGES_REQUESTED
  (`cr-*`) is never CI-cleared.
- **A refusal that repeats is said once, out loud.** Per-tick log lines are not
  an alert; `bg_streak_note` is.
- **A refusal is never silent and never sticky.** One log line every tick, one
  comment per (PR, head, block), and no state that a human has to undo: the hold
  ends by itself on a newer commit or an `UNBLOCK` from the same author.
