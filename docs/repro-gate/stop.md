# The repro gate's stop stage (BH-2043)

`bin/lib/prebuild-repro/stop.sh` defines `pr_stop`, the stage `bin/prebuild-repro.sh` calls at step 6 when the drive
answered `NOT_REPRODUCED` or `ALREADY_FIXED`. It replaces the BH-2039 stub, so the stop row of the stage table in
[repro-gate.md](../repro-gate.md) ("stub: rc 0") and that doc's "not written by anything yet" line about the ledger
are superseded by this page for the stop stage.

```
pr_stop <project> <ticket-id> <key> <build> <thread-json> <verdict>
rc 0   build (a verdict that is not a stop, a ledger outage, a pre-send ledger write that failed)
rc 10  stopped: the ticket has its comment (this run's, or an earlier one for the same thread)
rc 11  a stop was wanted but the comment was not delivered
```

The runner maps rc 10 to a `stop` record and exit 10, and `bin/run-build.sh` then records
`BUILD_DEFERRED repro NOT_REPRODUCED …` and touches `COMMENTED`, so no build and no PR. rc 11 makes run-build delete
the record, so the next offer runs the gate again.

## The order

1. **Verdict.** `NOT_REPRODUCED` → `not_reproduced`, `ALREADY_FIXED` → `already_fixed`. Anything else, including
   the lowercase words, returns 0 without touching the ledger or the network. So does a thread `pr_ledger_key`
   cannot key.
2. **Read** `jobs-client.sh ledger-get repro_gate <project>/<KEY>/<thread_fp>`.
   - `not_reproduced` or `already_fixed`: a comment was already delivered for this exact thread. Return 10, post
     nothing. Either status counts, whatever this run's verdict is.
   - A miss (rc 2), or any other status (`reproduced`, `cannot_drive`, `*_uncommented`): go on.
   - Any other rc, or no `jobs-client.sh` on the box: an outage. Return 0 and build. The gate never stops blind.
3. **Write before send.** `ledger-put repro_gate <key> <v>_uncommented`, with no detail argument, so the worker's
   `COALESCE` keeps whatever detail the drive wrote. If this put fails, return 0 and post nothing: a comment we
   could not record would be posted again on the next offer.
4. **Compose once** from fixed copy. The role, URL, steps and observed text are the first `REPRO_ROLE:`,
   `REPRO_URL:`, `REPRO_STEPS:` and `REPRO_OBSERVED:` lines of `$BUILD/prebuild-repro.md`. A missing one is written
   as "not recorded". The observed text is capped at 2000 characters.
   - not_reproduced opens "We tried to reproduce this before building a fix, and we couldn't see the problem."
   - already_fixed opens "We tried this before building and it looks like it already works."
   - Both list the role, the URL, the steps, quote what we saw, and close with "Could you send a screenshot or the
     exact steps you took? We'll pick it straight back up."
5. **Send.**
   - In-app board (`fleet-conf.sh <p> board_prefix` is not `-`): HTML, every value escaped, the observed text in a
     `<blockquote>`, the whole body capped at 5000 characters by trimming the observed text first, then the steps.
     `POST <prod><prefix>/tickets/<ticket-id>/comments` with the project's internal token. Delivered means the
     answer carries `.comment`, `.id` or `.data`; a 200 with `{"error":…}` or an HTML page is not delivered.
   - GitHub issues (`board_prefix` is `-`): markdown with the observed text in a `>` quote, sent as a file through
     `gh_rest POST repos/<slug>/issues/<n>/comments -F body=@file` (`bin/lib/gh-rest.sh`) and nothing else. A box
     without that lib is a failed send; there is no bare `gh api` fallback, because a raw gh call with no
     gh-identity declaration turns the fleet gh App ratchet red. `<n>` is the ticket id, or the digits of the KEY. Delivered means
     the answer has `.id`.
   - Missing board config (no prod origin, prefix, token, repo slug or issue number) is a failed send.
6. **Delivered:** `ledger-put … <v>`, then, on in-app boards only, `POST …/tickets/<ticket-id>/turn {"to":"client"}`
   once. Return 10. A failed final put or a refused turn writes one line to `logs/<project>.log` and
   `$BUILD/pipeline.log`, and is not retried; the return is still 10, because the comment is on the ticket and a
   retry would post it twice. GitHub issues get no turn and no label change.
7. **Not delivered:** the ledger stays `<v>_uncommented`, one line goes to `logs/ALERTS.log`
   (`<stamp> [<project>] prebuild-repro: <KEY> <verdict> comment POST failed — ledger <key> left <v>_uncommented; the next offer retries`),
   and the return is 11. The next offer reads `_uncommented`, writes it again and posts once.

So `<v>` is only ever written after a response carrying a comment, and the turn is only sent after one.

## How a client reply re-arms the gate

The ledger key ends in `thread_fp`, which hashes the comment count and the newest comment's id and createdAt, of
the comments the harness did NOT write (BH-2133). The stop's own comment carries
`<!-- harness:repro-stop <thread_fp> -->` and is left out, so it never re-arms the gate by itself. The same marker
lets a retry after an unconfirmed send find the delivered comment instead of posting it twice. Model-supplied
text is escaped in markdown, and the in-app URL is a real link; see
[self-comment.md](self-comment.md). A client reply changes all three, so the next offer keys a new row, reads a miss, and the drive runs again with the
reply in the thread. An unchanged thread keeps reading `not_reproduced` or `already_fixed`: rc 10, no second comment.
On in-app boards the turn flip also puts the ticket in the client's court (`waitingOn=client`).

Verified by `tests/prebuild-repro-stop.bh-2043-test.sh`.
