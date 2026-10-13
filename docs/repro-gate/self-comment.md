# The repro gate never pays twice for its own comment (BH-2133)

Must land before #2040 wires `pr_fetch_thread`. Until then the gate records `cannot-drive fetch-not-wired` on
every bug build, so nothing below changes a live build today; it changes what happens the moment the thread
fetch is switched on.

## The loop it closes

The `repro_gate` ledger key ends in `thread_fp`, and `thread_fp` counted every comment on the thread, including
the one `pr_stop` had just posted. On a GitHub-Issues board there is no turn flip, so the pool re-offered the
stop's `BUILD_DEFERRED`; the next offer's key was new, the ledger missed, the drive paid for another prod drive
(up to `REPRO_GATE_MAX_USD`, $3) and the stop posted a second comment. Only the spawn cap bounded it.

## What changed

| Where | Change |
|---|---|
| `pr_ledger_key` (`bin/lib/prebuild-repro.sh`) | A comment is left out of `thread_fp` when the normalized thread flags it `harness: true`. It is also left out when its body carries `<!-- harness:repro-stop` AND its `author` is one of the harness Apps (`HARNESS_SELF_APPS`, `bin/lib/harness-self.sh`). The marker alone is not enough (review of #2208, N2). A client quoting our comment carries it too, and a PAT-posted stop (author `operator`) cannot be told from the operator: both move the key. Only principal and client comments that are not the harness's own move the key. |
| `pr_stop` (`stop.sh`) | Every stop comment ends with `<!-- harness:repro-stop <thread_fp> -->`. The marker renders as nothing on GitHub or in-app. |
| `pr_stop` retry | When the ledger reads `<v>_uncommented`, the earlier send failed or was never confirmed. Before posting again the stop reads the ticket's comments (`gh_rest GET …/issues/<n>/comments`, or `GET <prod><prefix>/tickets/<id>`) for its marker on a comment of its own: a harness-App author on GitHub, or `isInternal` in-app. If found, the comment was delivered: write `<v>`, send the in-app turn, return 10, post nothing. An unreadable read keeps the old behaviour, which is to post. |
| GitHub markdown | The URL and role are code spans. Steps and observed text go through `_prs_md_esc`, which backslash-escapes markdown punctuation, turns `&`, `<`, `>` into entities, and puts a zero-width space after `@` and `#`. The result has no @-mention, markdown link or image, raw HTML or `#` cross-reference. A bare `https://…` inside the model's text can still be autolinked by GitHub. The escaping does not claim to stop that; it is plain text the drive already saw on the prod origin. |
| In-app HTML | The URL is `<a href="…">…</a>` when it is http(s). The drive only answers NOT_REPRODUCED / ALREADY_FIXED for a URL on the prod origin, so it is already origin-checked. Any other value stays a `<code>` span. |
| `pr_drive` claim (`drive.sh`) | Before the paid call, the drive takes a non-blocking `flock` on `locks/repro-drive-<sha16 of key>.lock` and puts a `repro_gate_claim` row `driving:<epoch>`. The row is set to `released` after the call. A fresh claim (younger than `REPRO_DRIVE_CLAIM_TTL_S`, default 1200 s), or a held lock, answers `CANNOT_DRIVE drive-in-flight` with no spend. The ledger has no compare-and-set, so a claim that cannot be *written* is logged to `$BUILD/pipeline.log` and the drive goes on under the local lock alone. |
| `pr_drive` post-spend put | A failed `repro_gate` put after the call writes `state/repro-gate/<sha16>.json` (`{status,key,detail}`) and one `ALERTS.log` line (`prebuild-repro: <KEY> drive ledger put of <status> failed …`). A later ledger miss on this box reads that file, reuses the verdict (`ledger-reuse`, 0 calls) and writes the row back best-effort. |
| `pr_drive` env | `AGENT_CALL_LANE=prebuild-repro` and `AGENT_CALL_BUDGET_USD_REPRO` are set by `env` inside `_pr_drive_env`, after `global.env` and `<project>.env` load (BH-1165). As prefix assignments they were overwritten by any line of the same name in those files. |

## The normalized thread: one additive field

`pr_fetch_thread` (#2040) should set `"harness": true` on a comment the harness wrote. On GitHub that means the
author is one of the harness Apps (`HARNESS_SELF_APPS`), not any Bot. In-app it is the board's system actor. It
should also carry the author login as `"author"`, so the marker check can verify it. `principal` stays as #2040
defines it. Until the fetcher sets these fields, the marker plus an App `author` covers the stop comment.

Verified by `tests/prebuild-repro-self-comment.bh-2133-test.sh`. S1 is the ticket's test: the stop comment
lands, the ticket is re-offered with no human reply, and there are 0 new drives, 0 new comments and 0 new cost
rows. The suite also covers M1-M3 and H1-H3.
