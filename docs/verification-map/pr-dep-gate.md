# The PR-dependency gate (an open `Depends on #N (PR #M)` holds the merge)

**What it is:** one shared gate, `bin/lib/pr-dep-gate.sh`, that reads the
dependency a PR declares in its own body and holds the merge while that
dependency is still open (BH-629). It is sourced by
`bin/lib/merge-conductor-lib.sh` (the shim over `bin/lib/mc/`), which every automatic merge path already
sources, so the lanes share ONE answer to "is this PR's dependency landed yet".

The incident: #615 merged at 03:33Z on 2026-09-17 with "Depends on #459
(PR #609) for tests/lib/scratch.sh, which both suites source" in its own body,
while #609 was still open. Main then carried a suite sourcing a file main did not
have. Every open PR in the repo went red on the same job for about 7.5 hours,
each one looking individually broken, and the merge sweep will not touch a red
PR — so the repo froze.

**Status as of BH-629.2:** all four lanes below now ask the gate — the conductor
and the sweep call `pdg_hold`, the box queue calls `pdg_queue_hold` through its
own `dep_queue_hold` wrapper (which is what keeps rc 2 a hold), and the tier-1
step in a build stands down to `PR_CREATED`. Every call site is guarded on
`command -v`, so a tree without `bin/lib/pr-dep-gate.sh` behaves exactly as it
did before BH-629. Merge behaviour on a live box is still unchanged, because the
library is still BH-629.0's contract stub: `pdg_hold` reads the kill switch,
writes one log line and returns 1 whatever it is handed. The parser arrives with
BH-629.1, and the moment it lands these four call sites start holding merges
with no further lane change.

**Status as of BH-994 (2026-09-19):** the body read is REST, never GraphQL.
Between 17:53Z and 18:04Z on 2026-09-19 every READY cromford row (#933,
#956, #955, #785) was held for four consecutive conductor ticks on
`dep gate: could not read the PR body — HOLD (rc 2)` with `merges=0`, while CI
was green and `mergeable_state=clean`. Under the conductor's own repo token
`gh pr view <url> --json body` answered `GraphQL: API rate limit already
exceeded for installation ID 161623167` while REST core on the same token still
had 3141 of 6600 points; the GraphQL window reset at 18:04:42Z and the holds
cleared by themselves. `logs/pr-dep-gate.log` carried 81 such rc-2 lines that
day. `pdg_hold` now fetches a body it was not handed with
`gh api repos/<slug>/pulls/<n> -q '.body // ""'`, and the conductor's second
body read per PR per tick — the `mc_is_harness_pr` probe in its
`# >>> harness pr probe` block — went over the same endpoint, through
`pr_body_read` -> `mc_pr_view` -> `bin/lib/gh-rest.sh` (BH-784), so a refused
read is logged as "body unread", never as "no marker". rc 2 is unchanged:
a body nobody can read still holds. The conductor still hands the gate an empty
body, and deliberately: its rows are tab-separated lines and a multi-line PR
body cannot ride one, and its open-PR list asks for `mergeStateStatus` /
`mergeable` / `isInMergeQueue`, which are outside `gh-pr-list.sh`'s
REST-mappable set — so adding `body` there would grow the very budget this
ticket moved off. The same wave moved the conductor's pre-merge state guard
(`# >>> pre-merge state guard`), which is the read that actually refused the
merges: see [merge-rest.md](merge-rest.md) for all three reads in one table.

**Status as of BH-629.0:** `bin/lib/pr-dep-gate.sh` ships as the contract only —
`pdg_hold` reads the kill switch, writes one log line and returns 1 whatever it
is handed, and no lane calls it. Merge behaviour is byte-for-byte what it was.
The only suite of this page's four that exists on main today is
`tests/pr-dep-gate-contract-test.sh`. The parser arrives with BH-629.1, the four
lane call sites with BH-629.2, and only then does anything below hold a merge.

**Status as of BH-629.1:** `pdg_hold` now answers for real. It reads the kill
switch first, scans the PR body (fenced blocks and inline code spans blanked
before the marker sees a line), resolves each distinct `<slug>#<n>` ONCE through
`repos/<slug>/issues/<n>` and memoises the answer for the life of the shell — no
file, so nothing to go stale. An open dependency holds (rc 0), a closed one
passes (rc 1, and the log line says whether it merged), and a dependency nobody
could read holds with rc 2. A body it was not handed is fetched with one
`gh pr view`; a PR that declares nothing costs no API read at all. What has NOT
changed is merge behaviour: no lane calls the gate until BH-629.2, so nothing in
production holds yet. Two of this page's four suites exist on main today,
`tests/pr-dep-gate-contract-test.sh` and `tests/pr-dep-gate-test.sh`; the lanes
suite arrives with the call sites.

| lane | where the gate is called | what it does on a hold |
|---|---|---|
| merge conductor | `bin/merge-conductor.sh`, `READY` arm (BH-629.2) | one `depwaithold` line in `state/merge-conductor/attempts.txt`, one log line, the row stays `READY`, no merge budget spent |
| tier-2 merge sweep | `bin/merge-sweep.sh` (BH-629.2) | one `$LOG` line and `continue` — no `sweep_claim`, no ledger row, no `gh` write |
| box merge queue | `bin/merge-queue.sh` `pdg_queue_hold`, beside each `bg_queue_hold` (BH-629.2) | the entry stays queued and lands on a later pass |
| tier-1 gate in a build | `bin/run-build.sh` (BH-629.2) | stands down to `PR_CREATED`, the conductor owns it |

The console `merge_pr` command (`bin/poll-commands.sh`) is deliberately NOT
gated: that is a human at Mission Control giving an explicit order.

**How an operator reaches it:** there is no UI and nothing to run by hand. The
lanes are `cron/hub.cron` (`bin/merge-conductor.sh`, `bin/merge-sweep.sh`), the
per-box cron for `bin/merge-queue.sh`, and the tier-1 step inside a build. Two
switches turn the gate off: `PR_DEP_GATE=0` in `env/global.env` (documented in
`env-templates/global.env.example`) and the file `flags/pr-dep-gate-off` under
the harness root. Either one makes every lane merge as it did before BH-629.

**How to drive it:**

| what | how |
|---|---|
| the contract — the lib is armed by the conductor lib, `pdg_hold` passes and reads nothing, a tree without the file leaves the lanes unchanged | `bash tests/pr-dep-gate-contract-test.sh` |
| parsing and resolving a declared dependency (BH-629.1) | `bash tests/pr-dep-gate-test.sh` |
| the four lanes asking the gate (BH-629.2) | `bash tests/pr-dep-gate-lanes.bh-878-test.sh` |
| both body reads answer over REST while GraphQL is exhausted (BH-994) | `bash tests/pr-dep-gate-rest.bh-994-test.sh` |
| the gate is OFF (rollback) | any of the above with `PR_DEP_GATE=0` |

**Files it writes on a live box:**

- `logs/pr-dep-gate.log` — one stamped line per decision, in the gate's own file
  rather than a lane's: the gate has no lane context.
- the lane logs (`logs/merge-conductor.log`,

- once BH-629.2 lands: the lane logs (`logs/merge-conductor.log`,
  `logs/merge-sweep.log`, `logs/merge-queue.log`, a build's `pipeline.log`) carry
  the lane's own hold line, and `state/merge-conductor/attempts.txt` carries one
  `depwaithold` or `depwaitunread` line per (PR, head).

**What must never regress:**

- **The PR body is read over REST, never `gh pr view`.** `gh pr view` is
  GraphQL, and the App installation's GraphQL budget is the one that empties —
  on 2026-09-19 it went to zero with REST at 3141/6600 and the merge step went
  dark for every project on the hub. A body read that reaches for GraphQL turns
  a rate limit into a fleet-wide merge freeze.
- **rc 2 is a HOLD, never a pass.** The rc contract is 0 = hold, 1 = pass,
  2 = could not read, and a dependency nobody could read is not a dependency that
  closed. Mapping rc 2 to rc 1 is the shape of the original incident.
- **A hold writes nothing to GitHub.** No comment, no label, no state
  transition — the hold ends by itself when the dependency closes, so nothing a
  human has to undo, and a lane that holds costs no merge budget.
- **The gate is read BEFORE the merge is written, never the reverse.** A hold
  that records a merge it did not make is worse than no gate.
- **`>`-quoted lines never declare a dependency.** A quoted `> Depends on #609`
  is somebody repeating an old body. `>` is deliberately absent from the marker's
  markdown-noise class, exactly as it is in `BG_BLOCK_RE`.
- **`Fixes #N` / `Closes #N` never declare a dependency.** That is the closing
  keyword the harness writes into every PR body it creates, naming the ticket the
  PR ships. Matching it would hold every PR in the fleet for ever.
- **No second token mint.** Every read the gate will ever make runs on the token
  the calling lane armed for that repo. A mint here would override the tier-2
  sweep's admin-PAT fallback and answer "cannot judge" on exactly the repos the
  gate exists for.
