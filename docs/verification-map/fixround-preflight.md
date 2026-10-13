# Fix-round preflight (the PR as it is now, before any fix round spends)

**What it is:** `bin/lib/fixround-preflight.sh` and the three places that call it.
Before `bin/blocked-resolver.sh` buys a fix round it reads the PR's current head, the
CI of that exact sha and the head the posted findings were written against, and decides
whether a round is the answer at all. The two review prompts get the same live CI, and
the PR body gets a live-CI block a reviewer can trust.

**Why it exists** (BH-1794, project-3 #378 / TK-202, 2026-09-23). Fix round 1 fixed the code;
CI went green on b8e228d3. The Fable re-review 23 minutes later still blocked, on
paperwork: the PR body's Evidence block said `HARNESS_EXIT: 1` / head-red from the first
build, and the reviewer's token 403s on check-runs, so it could not see the green CI. A
second paid fix round and a second re-review were bought only to refresh that block.

## Fix-round flow

`br_fix_round` (hub, `*/10`), after it has read the head (`br_pr_ref`) and the findings
(`br_findings`), and before it fetches, merges or creates a worktree:

| step | what it does |
|---|---|
| read | `frp_ci <slug> <head>`: `actions/runs?head_sha=` and `commits/<sha>/check-runs`, each through `gh_ci_api` (default token, then the read-only App token). Latest run per name; cancelled/timed_out/skipped/neutral/stale set aside. `green`, `red`, `pending`, `none`, or `unreadable` — a refused read is never `red` |
| findings head | the 40-hex sha in the findings' own footer (`… of <sha>`) |
| decide | `frp_decide`: `rereview` (findings on an older sha, head moved, CI green) · `wait` (head moved, CI not finished) · `skip` (a `red-ci-twice`/`red-twice` park green at head) · `evidence` (every blocking numbered finding is about the PR body's Evidence block/table/row, HARNESS_EXIT, head-red, check-runs or an unreadable/red CI claim, names no source file, and CI is green — the bare word "evidence" is not enough) · `fix` (everything else, unreadable CI included) |
| cap | `wait`/`skip` are counted per head on the record (`preflight_wait_head`, `_n`, `_first`); past `BR_PREFLIGHT_WAIT_MAX` (6) on one head the round runs, and CI `none` for `BR_PREFLIGHT_NOCI_S` (1800 s) since the first wait reads as `unreadable` (a round). A moved head restarts the count; a wait that cannot be recorded runs the round (BH-1992) |
| route | `rereview`/`evidence` are taken ONCE per (PR, head) — `preflight_heads` on the resolver record. A conductor park calls `br_rereview … preflight` (the head-bound re-review, live CI in its prompt, charged to `preflight_rereviews` and logged `[preflight-rereview]`, not to `BR_NOVERDICT_MAX`). A review-lane park (`review-changes-requested`) gets the live-CI block written into the body and a PR comment (hub identity) carrying `<!-- harness:rereview-requested <sha> -->`, and `preflight_route_at` stamped; a body that refuses the block, or a comment that will not post, falls through to `fix` |
| defer | a review-lane park already routed on this head waits (nothing spent, one `defer` event) until a verdict author has reviewed the head since `preflight_route_at` or `BR_PREFLIGHT_DEFER_S` (1800 s, one review-prs cadence) has passed; no stamp, or an unreadable review list, runs the round (BH-1992) |
| record | every route: one `resolver_preflight` event (`br_event`: the tick line plus a `fleet_event` beat). The one ALERT: a body whose begin marker has no end (below). A PR that cannot be read at all never reaches the preflight (`br_fix_round` retries it next tick) |
| brief | on `fix`, `BR_PREFLIGHT_BRIEF` leads the agent's prompt (and says so when the no-CI timeout read the head as unreadable): the live head sha, whether the findings were written against it, and every run with its conclusion and URL. The body block is refreshed too |
| after the push | `br_preflight_after_push` rewrites the body block for the pushed head (usually `NONE`/`PENDING` that soon), so nobody reads the old head's result as the new one's |

**The body block.** Between `<!-- harness:live-ci:begin -->` and `<!-- harness:live-ci:end -->`,
directly above the build's `## Evidence` (or at the end of a body that has none). It carries no
timestamp: the same head in the same CI state renders the same bytes, so a second refresh sends
no PATCH. The build's own Evidence block is left alone — it is history rendered from files only
the build box has. A begin marker with no end (or a second begin while one is open) is refused:
`frp_body_refresh` rc 4, no PATCH, the body byte-identical, and `br_preflight_marker_alert` sends
ONE `lane-alert.sh blocked-resolver` line per PR (`marker_alerted`, recorded before the send).
An end marker with no begin is an ordinary line.

**Whose words count** (BH-1992). `br_findings` briefs a conductor park only from a "Head-bound"
comment whose author is in the verdict-trust set (`HARNESS_VERDICT_AUTHORS`,
`bin/lib/gh-pr-list.sh`); no trust set on the box is rc 75 (unreadable), never the unfiltered read.

**The review lanes.**

| lane | what changed |
|---|---|
| `bin/review-prs.sh` (`# >>> review-prs live ci`) | the reviewer prompt carries `LIVE CI ON THIS HEAD` (`REVIEW_LIVE_CI`) |
| `bin/review-prs.sh` (`# >>> review-prs rereview request`) | a head whose verdict on record is `REQUEST_CHANGES` and that has a PR comment from a verdict author (`harness_verdict_author_match`) carrying the marker for that exact sha is reviewed once more (`REVIEW_REREVIEW_ON_REQUEST`); the marker in the body alone triggers nothing, and an unreadable comments list asks for nothing (BH-1992). The request is SPENT (`rereq_sha`, kept across the verdict write) only at `# >>> review-prs rereview consume`, after the green-CI debounce and the diff read, so a head still waiting on CI keeps it; the GitHub rehydrate that would dedupe the head is skipped for it. The comments are read only for a blocked head |
| `bin/lib/mc/rebase.sh` `mc_rereview` | the head-bound re-review prompt carries the same live CI (`MC_RR_LIVE_CI`) |

**Knobs** (settings rows, env fallback; each `0` restores the behaviour before this):
`BR_FIXROUND_PREFLIGHT`, `BR_PREFLIGHT_WAIT_MAX`, `BR_PREFLIGHT_NOCI_S`, `BR_PREFLIGHT_DEFER_S`
(blocked-resolver; for the last three `0` means off), `REVIEW_LIVE_CI` and `REVIEW_REREVIEW_ON_REQUEST`
(review-prs), `MC_RR_LIVE_CI` (merge-conductor, read in `bin/lib/mc/rebase.sh`).

**Proof:** `tests/fixround-preflight.bh-1794-test.sh` — the real lib, the real
`br_preflight` and `br_fix_round` (extracted, the lane's bookkeeping stubbed, git and the agent
recorded), the real review-prs blocks and the real `mc_rereview`, against a fake GitHub whose
PR body is rewritten by the PATCH. BH-1992's three suites share
`tests/lib/fixround-preflight-fixture.sh`: `tests/fixround-preflight-wait-cap.bh-1992-test.sh`
(wait/skip cap and no-CI timeout through `br_fix_round`, the marker refusal and its one alert),
`tests/fixround-preflight-trust.bh-1992-test.sh` (trusted findings, the comment-only re-review
request) and `tests/fixround-preflight-defer.bh-1992-test.sh` (the defer, the preflight
re-review's own counter).

**Invariants**

- **Unreadable is never red.** Both CI endpoints refused → `unreadable`, and the decision is a
  round (today's behaviour), never a skip or an evidence route.
- **No model call before the decision.** The preflight is bash + REST; the only spend it can
  cause is the re-review it routes to, which replaces a fix round.
- **No loop.** A route away from a round happens once per head on the resolver side, and the
  re-review request is honoured once per head on the review side.
- **Nothing waits for ever.** `wait`/`skip` are capped per head, a head with no CI times out to
  `unreadable`, and a defer ends after one review cadence.
- **Never truncate the body.** A body the splice cannot read safely is left exactly as it is.
- **Fail open.** No lib on the box, or a knob at 0, and every lane runs exactly as before.
