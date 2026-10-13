# A stub flip is not a deletion (test-tamper gate)

**What it is:** `bin/test-tamper-scan.sh` counts test cases a diff removed and
blocks a build that lost coverage. A contract-first decomposition breaks that:
the `.0` child ships test cases that are named STUBS, and the `.N` filler
deletes those stubs and writes the real cases in another file. The count saw
lost coverage and ended every filler `REVIEW_BLOCKED test-tamper` — TK-1828,
1872, 1896, 1908 and 1909 each sat a day or two and were then ruled on by hand.

Since BH-1047 the scanner classifies each removed opener as a **stub** or a
**real** case, and a stub is exempt only in exchange for a replacement:

- **Marker (a), the case itself.** Its own opener text, one of the three
  COMMENT lines immediately above it in the same hunk (added lines never count,
  and ANY non-blank line that is not itself a comment — an opener, a `const`, a
  `beforeEach` — ends the window: a comment marks the case written under it and
  nothing further down), or an enclosing `describe`/`context`
  carries one of `stub`, `placeholder`, `until <KEY>-`, `implements the
  body/bodies`, `must flip`, this build's own ticket key, or a `<PARENT>.<N>`
  sibling key of the build's parent. Matched case-insensitively on word
  boundaries — `stubborn` is not `stub`.
- **Marker (b), the file's provenance.** The file was created by the `.0`
  contract child OF THE SAME PARENT, and that is only ever read off a `.0`
  build record on this box: the build must be a `.N` child (`PARENT` from its
  `ticket-meta.json` title) and a record titled `<PARENT>.0:` must either name
  the file in its `changed-files.txt`, or name in its `branch` file the very
  ref this build is based on — in which case the files added between
  `merge-base(origin/<base>, BASE)` and `BASE` are candidates too. Both lists
  are then filtered twice: the path must be ABSENT from the mainline (the
  record's `changed-files.txt` is its full diff list, so naming a file is not
  writing it), and the commit that ADDED the path must name the `.0` record in
  its subject — its own ticket key or the `<PARENT>.0` title. Neither
  "reachable from the `.0` branch" nor "absent from main" is authorship: the
  `.0` can itself be stacked on an unmerged ticket, and that ticket's suites
  are absent from main and inside the range.
  Being stacked is NOT the marker, deliberately: `bin/run-build.sh` stacks a
  child on ANY blocked-by parent's branch and `bin/run-decompose.sh` stacks
  siblings on each other, and a sibling's branch carries real cases. Without a
  `.0` record to prove the provenance the build falls back to marker (a).
- **The exchange.** The same diff must ADD at least one case in another test
  file that imports the SAME module (JS/TS specifier equality after path
  normalisation, dotted-name equality for Python; bare packages never pair).
  A stub with no such replacement counts as a deletion exactly as before.

What is deliberately NOT exempt: a whole test FILE deleted, the `.0` contract
child deleting its own stubs, a marker that appears only on an ADDED line, a
real case that merely sits under a stub, a real case a marker comment reaches
past a line of setup, a suite created by an unmerged ticket the `.0` child is
itself stacked on, a build stacked on a branch no `.0` record claims, and any
case whose only "replacement" is in a file importing something else.

**How an operator reaches it:** no UI. The scanner runs inside every build —
`bin/run-build.sh` (`# >>> mechanical gates`) writes its report to
`<record>/test-tamper.txt`, and `bin/review-rescue.sh` re-runs it on a blocked
record into `test-tamper-rescan.txt`. The report lines BH-1047 added, after the
four count lines every caller greps:

```
TAMPER_COUNT: 0 (deleted_files=0 deleted_cases=0 added_skips=0 stub_flips=2)
CONTRACT_CHILD: TK-1531.1 (parent TK-1531, key TK-1828)
DELETED_CASES:
  tests/chan.test.ts: it("cancels a run the operator owns"
STUB_FLIPS: 2
stub-flip: tests/chan.test.ts: it("is a stub that cancels nothing yet" (stub marker) -> tests/chan.impl.test.ts
stub-flip-unpaired: tests/x.test.ts: it("is a stub" (no added case in a test file importing: src/x)
```

On rc 0 with a `stub-flip:` line the build's `GATES_NOTE` carries the whole
report into the GENERAL review lens rather than the one-line "clean" —
mechanically the scanner can only see that a replacement exists, so whether it
tests what the stub promised is the reviewer's call.

`bin/blocked-resolver.sh` reads the same report: a record blocked on
**test-tamper** whose report says `CONTRACT_CHILD:` skips the 6-hour
review-rescue floor (the 90-minute floor stays), the adjudication prompt and
both comment bodies are prefixed with `Deleted cases under adjudication:` and
the list, and an adjudication that produces no verdict pages once through
`bin/lane-alert.sh` with that list and leaves
`<record>/.adjudicate-noverdict-paged`. Both are scoped to a tamper block on
purpose: the scanner prints `CONTRACT_CHILD:` on every `.N` child's scan, so a
contract child parked on the reproduction or intent gate carries the line while
having lost no case at all, and it keeps the backstop it has today.

**How to drive it:**

| what | how |
|---|---|
| the classifier, the pairing, the lineage and every adversarial negative, over real throwaway git repos | `bash tests/test-tamper-scan.bh-1047-test.sh` |
| the counts, markers and exit codes that existed before it | `bash tests/test-tamper-scan-test.sh` |
| the pairing reaching the reviewer through the real gate block | `bash tests/run-build-gates.bh-1047-test.sh` |
| the resolver floor, the named cases in the ruling, the no-verdict page | `bash tests/blocked-resolver.bh-1047-test.sh` |

**Files it writes on a live box:** the scanner writes stdout only. The resolver
writes `<record>/.adjudicate-noverdict-paged` (one page per record) and one
`logs/ALERTS.log` line through `bin/lane-alert.sh`.

**What must never regress:**

- **The four count lines stay first and keep their shape.** `bin/run-build.sh`
  blocks on `JUSTIFICATION: NONE` plus `^BLOCKING_COUNT: [1-9]`, and
  `bin/evidence-summary.sh` greps `^BLOCKING_COUNT: [1-9]`. Only `stub_flips=N`
  was added, inside the existing parentheses on line 1.
- **Every derivation fails to the empty answer.** No `jq`, a shallow clone
  whose `merge-base` will not resolve, no build record: the sets are empty and
  the scan behaves exactly as it did before BH-1047. A derivation that guessed
  would hand a builder a way to delete real tests.
- **A builder cannot manufacture the exemption.** Added lines are invisible to
  the scope stack, the comment window and the opener scan alike.
- **Added openers pay off REAL removals first.** A stub retitled in the same
  file can never absorb the add that a real deletion needed.
