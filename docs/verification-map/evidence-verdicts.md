# Evidence verdicts (per-claim CONFIRMED/REFUTED/INCONCLUSIVE)

**What it is:** `bin/lib/evidence.sh`, the acceptance-claim evidence contract
(#545) plus the deterministic scorer that fills it in (#546). It reads a build
directory and the plan that build was executed from, and writes one verdict per
acceptance claim: `CONFIRMED` when a named test was located as passing (or a
proposed artifact really exists), `REFUTED` when a named test was located as
failing or its assertions were weakened in the diff, `INCONCLUSIVE` for
everything else. It exists because "the builder says it is green" is not
evidence: #527's whole point is that a claim with no artifact is INCONCLUSIVE,
never CONFIRMED.

**Wired.** `bin/run-build.sh` sources the lib and calls `evidence_score`,
teeing its stdout to `<build>/evidence-verdicts.txt` for the reviewer prompt
(warn-only today: `EVIDENCE_GATE_ENFORCE` defaults off, so a REFUTED verdict
does not itself block a build — see Knobs below).

**How an operator reaches it:** it is a sourced library, not a lane. From a repo
checkout or against `/root/harness`:

```sh
. /root/harness/bin/lib/evidence.sh
B=/root/harness/builds/<project>-<KEY>-<stamp>
evidence_score "$B" "$B/plan.md" main /root/repos/<project>   # scores, writes $B/evidence.json
evidence_counts "$B"                                          # confirmed=… refuted=… inconclusive=… total=…
evidence_note "$B"                                            # the CLAIM lines again, from the JSON
jq . "$B/evidence.json"
```

`evidence_score` prints one `CLAIM n: <VERDICT> :: <artifact> :: <note>` line
per claim, then any `EVIDENCE NOTE:` lines, then
`EVIDENCE VERDICTS: C confirmed, R refuted, I inconclusive of T claims`. It
returns 1 without touching `evidence.json` when jq is missing, the build dir is
not writable, or the plan cannot be read.

**How to drive it:**

| what | how |
|---|---|
| the schema, the two readers, the fail-open paths, one whole lane pass in its own process | `bash tests/evidence-contract-test.sh` |
| the claim parser, the artifact locator, the proposal pointer and the six verdict rules | `bash tests/evidence-verdicts-test.sh` |
| the `[$]` run-line prefix stops the window at a NEXT block's `$ bash …` line, driven under every awk on PATH | `bash tests/evidence-verdicts.bh-1346-test.sh` |
| the staging check (assertions counted at the merge-base of `<base>` and HEAD vs the working tree) and the ASSERT_RE parity pin | `bash tests/evidence-no-staging-test.sh` |
| both new suites read no clock and no network | `bash bin/test-determinism-lint.sh tests/evidence-verdicts-test.sh tests/evidence-no-staging-test.sh` |

**Files it names on a live box** (all inside one build directory; the scorer
writes only the first one):

- `<build>/evidence.json` — the structured verdicts, written via `mktemp` in the
  build dir then `mv`, so a crashed scorer never leaves a truncated file.
- `<build>/evidence-proposed.txt` — optional, model-written, one
  `CLAIM <n>: <VERDICT> :: <artifact> :: <note>` line per claim. A pointer only.
- `<build>/harness-suite-head.txt`, `harness-suite-fix.txt`, `harness-suite.txt`
  — the harness's own suite runs, in that precedence, and the ground truth.
- `<build>/validate.txt` — the executor's recorded VALIDATE blocks, read only
  after the harness files decide nothing, and always labelled
  `(agent-recorded)`.
- `<build>/plan.md` — where the `## Acceptance tests` claims are read from.
- `<build>/qa-shots/…` — where a proposal's artifact usually points.

**Knobs:** none in this file. `EVIDENCE_GATE_ENFORCE`
(`env-templates/global.env.example`, default 0) is the warn-first demoter for
these verdicts and is read by the wiring sibling, not here.

**What must never regress:**

- **`red.txt` is never a source.** It is the file that is SUPPOSED to be full of
  failures; a `✓` in it confirms nothing.
- **`HARNESS_EXIT: 0` alone never confirms a claim.** It names no test. A claim
  whose named test appears nowhere in the suite output is INCONCLUSIVE.
- **A harness-run FAIL beats an agent-recorded pass.** The precedence is
  head → fix → suite → `validate.txt`, and inside one suite file a fail marker
  anywhere for that test wins over a pass.
- **A test never confirms itself.** The test's own path and basename are deleted
  from a line before markers are matched, so `tests/ok-test.sh` does not read
  its own name as a pass and `bad` in a filename is not a failure. TAP
  `not ok` is checked as a fail before `ok` is read as a pass.
- **Whole-token naming.** `tests/foo-test.sh` must not be matched by
  `tests/foo-test.sh.bak` or `tests/foo-tests.sh`.
- **A line beginning `not run` closes the window, indented or not.** The
  `validate.txt` window opened by a run line ends at the next run line or at the
  first line whose leading non-blank text is `not run`, whichever comes first
  (any case, so `NOT RUN:` and an indented `  not run yet` both count). That is
  by design: an exit token recorded after such a line is never read, so the
  worst case is INCONCLUSIVE, never a borrowed CONFIRMED from a neighbouring
  task's block. Write `NOT RUN: <why>` on its own line for a check you could not
  run, and start no other output line with those words. The stop and the run-line
  set both come from one `RUN_RE` string that `bin/lib/evidence.sh` hands to awk
  with `-v re=`, which is why the `$` prefix is written `[$]` and not `\$`: a
  `-v` value goes through awk's string-escape pass, and gawk and BSD awk turn
  `\$` into a bare `$` anchor that matches no `$ bash …` line at all. Pinned by
  `tests/evidence-verdicts-test.sh` §1j/§1n and
  `tests/evidence-verdicts.bh-1346-test.sh`.
- **Named tests are scanned from the WHOLE item.** The 300-char bound applies to
  the claim text that gets RECORDED, never to the scan — most real plan items
  run past 300 characters and name their test at the end.
- **ASSERT_RE parity.** The `ASSERT_RE=` line here is byte-identical to
  `bin/test-tamper-scan.sh`'s. Two different ideas of "an assertion" would let a
  weakened test pass one check and not the other; §3 of the no-staging suite
  fails if they drift.
- **A proposal can demote, never upgrade.** A proposed `REFUTED` always stands;
  a proposed `CONFIRMED` never overrides a verdict the deterministic rules
  decided, its artifact must be an existing NON-EMPTY file under the build dir,
  and `../x` or `/etc/passwd` count as missing.
- **The summary prints only after the `mv`.** A build with no `evidence.json` is
  un-scored; printing "0 claims" after a failed write would stamp it as scored.
- **Sourcing is inert.** No `set -e`, no `exit`, no output and no file written at
  source time: a sourced `exit` would kill the lane that sourced it.
- **File content stays data.** No `eval`, nothing under a build dir is sourced,
  jq is called with `-n`/`-s` and `--arg` only, and every printed line is
  assembled inside jq — a claim carrying `$(…)` or a backtick reaches the
  reviewer as text.
