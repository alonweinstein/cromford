# Contested-hold launch gate

**What it is:** the third defer reason at the one per-ticket launch gate,
`bin/triage-gate.sh --buildable`, next to `bin/overlap-guard.sh` and
`bin/plan-overlap.sh`. A CONTESTED HOLD (`state/contested/<project>/*`, written
by the merge-conductor lib, BH-579/#587) records who won a path two tickets both
wanted to edit. When a ticket's PRE-PLAN file list hits a live hold it does not
own, the gate answers `BLOCKED contested=<path> winner=<KEY>` and the ticket is
re-offered next tick. It is a DEDUPE/defer answer, not a queue: nothing waits on
anything, no lock is taken, and the hold ages out on its own `ttl`
(`CONTESTED_TTL`, default 6h).

**Where the block is:** `bin/triage-gate.sh`, the `# >>> contested-hold gate`
block plus the two-line call at the top of `buildable_gate`. It runs BEFORE the
`GH_ISSUES_REPO` early return, because holds are local files and need no board
fetch — a GitHub-Issues board has holds too.

**How an operator reaches it:** run the gate by hand on a box, exactly as the
lanes do.

```sh
HARNESS=/root/harness /root/harness/bin/triage-gate.sh cromford --buildable 590
OK
```

`OK` is the answer on a box with no live hold (no `state/contested/<project>/`
at all), and it writes nothing. The other shape, when a live hold covers one of
the ticket's planned files, is `BLOCKED contested=<path> winner=<KEY>` — one
line, on stdout, plus one line in `logs/contested.log`.

The three production callers all consume any `BLOCKED*` answer already:

| caller | what it does with the answer |
|---|---|
| `bin/lib/rt/shards.sh:131` (the client-court guard of `bin/run-triage.sh`) | drops the shard unit, logs `triage shards: client-court skipped` |
| `bin/fly-dispatch.sh:500` | leaves the job in `state/build-queue/<project>/` |
| `bin/board-closeout.sh:94` | exits 4 and posts no close-out comment |

Note the third one: a live hold on a finished ticket's planned files also defers
its close-out COMMENT until the hold expires or is released. That is the same
gate the other two call, and the re-offer is the results-sweep on the next tick.

**How to drive it:**

| what | how |
|---|---|
| every case — block, winner, near-miss extension, planned dir, expired, malformed, no key, no pre-plan, missing lib, no network | `bash tests/triage-gate-contested-test.sh` (drives the real script against a scratch `$HARNESS`) |
| the suite reads no clock twice and no network | `bin/test-determinism-lint.sh tests/triage-gate-contested-test.sh` |
| the store the gate reads | `bash tests/contested-store-test.sh` (BH-587's contract) |

**Files it names on a live box:**

- `state/contested/<project>/<sha1(path)[0:16]>` — one hold per contested path.
  Read only; this gate never writes one.
- `state/<project>.keymap.json` — id→KEY, written by the gate's own
  `fetch_fingerprint` on in-app boards.
- `plans/<project>-<KEY>/planned-files.txt` — the pre-plan file list
  `bin/run-preplan.sh` writes. Both spellings match: a planned FILE equal to the
  hold path, and a planned DIR the hold path sits under.
- `logs/contested.log` — one line per skip
  (`<stamp> <project> <tid>/<KEY> skipped: contested <path> (winner <KEY>)`) and
  one line per could-not-decide (`cannot evaluate …`, `malformed hold … ignored`).

**What must never regress:**

- **Fail-open everywhere.** No lib, no hold, no KEY, no pre-plan list, a hold
  that will not parse, a hold past its `ttl` — every one answers `OK`. Blocking
  work silently is worse than launching one extra build.
- **Silent on the everyday path.** An empty store logs nothing and creates no
  `logs/contested.log`; the gate runs once per ticket per tick on every project.
- **Loud when it could not decide.** While a live hold exists, a ticket whose KEY
  or pre-plan list cannot be resolved writes one line. An unenforced hold is
  never silent.
- **The winner is never skipped.** `mc_contested_wins` short-circuits to `OK`
  before any path matching.
- **Contract only.** The block imports `mc_contested_list`, `mc_contested_live`,
  `mc_contested_wins` and `mc_stamp`. A tree whose lib predates them answers
  `OK`.
- **No network.** The block reads local files only; the suite pins that with a
  `gh` stub that leaves a marker.

**Known blind spot:** `bin/planned-files.sh` only keeps paths under
`src|prisma|scripts|e2e|tests|app|lib|components|pages|public|docs|content|middleware`,
so a hold on a `bin/` path is invisible to this gate — a harness-repo ticket
editing `bin/` can still be launched against a contested `bin/` file. Widening
the extractor changes overlap scheduling for every project, so it is deliberately
not done here.
