# Test home (per-ticket test files)

**What it is:** `bin/lib/test-home-lib.sh`, the fleet's one definition of what a
test path is, what a PER-TICKET test path is (`tests/<area>.<key-lower>-test.sh`,
`tests/<tier>/<area>.<key-lower>.test.ts`), the `REROUTE tests:` record format,
and the two sentences that carry the rule into a prompt — the planner rule and
the executor note. It exists because test files are the fleet's largest
merge-conflict surface: 20 of 24 unresolvable conductor cases were siblings
appending cases to the same shared test file.

**Who sources it** (#583 shipped the contract; BH-584 wired the first two
callers; #585 the executor side). All three source it guarded by `[ -r ]` and
behave byte-for-byte as they did before on a box whose `bin/` predates the lib:

| caller | what it does with it | driven by |
|---|---|---|
| `bin/overlap-guard.sh` | partitions the launch-time hit set: a shared test file is recorded as a reroute and dropped from the set instead of deferring the ticket (`th_enabled`, `th_is_test_path`, `th_is_per_ticket`, `th_per_ticket_path`, `th_record_add`, `th_apply`) — see docs/SCHEDULER.md §2 | `bash tests/overlap-guard.bh-580-test.sh` |
| `bin/fly-pool.sh` | `push_reroute` relays the record to a pool machine at `th_relay_path`, at both the spawn and the machine-reuse path | `bash tests/fly-pool-reroute.bh-580-test.sh` |
| `bin/run-build.sh` | the executor side (#585), in five marker blocks: `# >>> plan prompt` prefixes the planner's prompt with `th_plan_rule "$KEY"`; `# >>> test reroute` (after the 2nd `planned-files.sh`, before the claims `cp`) reads the record — relay path first, hub second — into `$BUILD/test-reroute.txt`, `th_apply`s it onto `$BUILD/planned-files.txt` so the claim, `conflict-check.sh` and `plan-overlap.sh` all see the per-ticket path, sets `REROUTE_EXEC_NOTE` and logs `TEST_REROUTE: <n> path(s) forwarded to EXECUTE`; `# >>> test home plan` (nested, before the swap) and `# >>> test home diff` (after `# <<< mechanical gates`) are the two ADVISORY findings; `# >>> execute prompt` carries the note into the EXECUTE session | `bash tests/run-build-test-home.bh-580-test.sh` |

The two advisories are advisory in the strongest sense: they write
`$BUILD/test-home.txt` and one `TEST-HOME GATE:` paragraph into `GATES_NOTE`
for the general review lens, and never a `RESULT`, never an exit, never a block.
The diff-time one takes its sibling PR list from `TEST_HOME_PRS_FILE` if set,
else `state/overlap-guard/<project>-prs.json` while it is younger than
`OVERLAP_PR_CACHE_SECS` (the operator's existing knob in `flags/scheduler.conf`,
default 120) — READ only, never written, `bin/overlap-guard.sh` owns that file —
else ONE `harness_pr_list` call written to `$BUILD/test-home-prs.json`.

**How an operator reaches it:** it is a sourced library, not a lane. From any
box, in a repo checkout or against `/root/harness`:

```sh
. /root/harness/bin/lib/test-home-lib.sh
th_per_ticket_path tests/level2-unit/foo.test.ts BH-583   # tests/level2-unit/foo.bh-583.test.ts
th_record_path /root/harness cromford BH-583         # the record a pre-plan writes
th_relay_path cromford BH-583                        # where a pool machine receives it
th_enabled /root/harness && echo on || echo off           # the kill switch
```

**How to drive it:**

| what | how |
|---|---|
| every function, plus one whole lane pass in its own process (section A8) | `bash tests/test-home-lib.bh-580-test.sh` |
| matcher parity with the tamper scan — the production `is_test_path` extracted verbatim from `bin/test-tamper-scan.sh` and driven side by side | section A3 of that suite |
| the suite reads no clock and no network | `bin/test-determinism-lint.sh tests/test-home-lib.bh-580-test.sh` |
| the five `bin/run-build.sh` marker blocks, each extracted verbatim by its markers and driven in a scratch harness (plan prompt, claim-list swap, plan finding, execute prompt, diff backstop) | `bash tests/run-build-test-home.bh-580-test.sh` |
| that suite reads no clock and no network either | `bin/test-determinism-lint.sh tests/run-build-test-home.bh-580-test.sh` |

**Files it names on a live box** (the lib only ever writes the first one, and
only when a caller asks it to):

- `state/preplan-files/<project>-<KEY>` — the reroute record, one
  `REROUTE tests: <shared> -> <target>` line per rerouted file, append-only and
  idempotent on an exact-line match. The same directory already holds this
  ticket's `<project>-<KEY>.called` markers from `bin/planned-files-cheap.sh`;
  they do not collide.
- `${TEST_REROUTE_RELAY_DIR:-/run/harness}/test-reroute-<project>-<KEY>` — the
  flat copy a pool machine receives the record at.
- `flags/test-reroute-off` — the file form of the kill switch.
- `$BUILD/test-reroute.txt` — the build's own copy of the record; both the claim
  list swap and the executor note are read off THIS file, never off the original.
- `$BUILD/test-home.txt` — the advisory findings: `SHARED: <path> -> <per-ticket>`
  from plan time, `SHARED: <path> (PR#<n>) -> <per-ticket>` from diff time, a
  `TEST_HOME_PLAN: <n>` count and one `TEST_HOME_VERDICT: clean|shared|not-judged`.
  Truncated at plan time, so a resumed build never doubles its findings.
- `$BUILD/test-home-prs.json` — the one `harness_pr_list` read, kept only when
  the cheaper sources were unusable.

The pre-plan LIST `th_apply` rewrites is a different file:
`plans/<project>-<KEY>/planned-files.txt`, whose first line is `SOURCE: <tier>`.
`REROUTE tests:` lines never live in that list, so `dep_norm` and
`bin/overlap-guard.sh` never read one as a path.

**Knobs:** `TEST_REROUTE` (exactly `0` turns rerouting off; empty or anything
else is ON) and `TEST_REROUTE_RELAY_DIR` (defaults to `/run/harness`). Both are
read with defaults at call time — no environment needs either one set, and
nothing here is a new required env var.

**What must never regress:**

- **Matcher parity.** `th_is_test_path` must agree with
  `bin/test-tamper-scan.sh:is_test_path` on every path. The arms are copied, not
  moved — the scan is untouched — so the only thing keeping them honest is A3,
  which drives the real function out of the real script.
- **The negatives in `th_is_per_ticket`.** `tests/cost-anchored.test.js`,
  `tests/v2-report.test.ts`, `tests/level2-unit/a-b.test.ts` and
  `tests/overlap-guard-test.sh` are shared files that must never read as someone's
  per-ticket file — a false positive here hands a sibling's file away. The one
  deliberate false positive is `tests/foo.utf-8.test.ts`: it matches, and that is
  the safe direction, because "looks owned" makes a caller DEFER rather than
  reroute.
- **rc 1 from `th_record_add` means "not rerouted".** An unwritable record must
  refuse and leave no partial file; a caller that treats the refusal as success
  would tell an executor to write to a file nothing recorded.
- **A missing or empty record is a no-op, never an error.** `th_apply` leaves the
  list byte-identical and `th_exec_note` prints nothing — the pipeline runs
  unchanged on any box that never rerouted anything.
- **Whole-line replacement only.** `th_apply` matches `$0==shared`, so
  `tests/foo.test.ts.bak` survives a reroute of `tests/foo.test.ts`, and the
  `SOURCE:` header is never touched.
- **Sourcing is inert.** No `set -e`, no `exit`, no output and no file written at
  source time: a sourced `exit` would kill the lane that sourced it.
- **The swap happens BEFORE the claim is published.** `# >>> test reroute` sits
  between the second `planned-files.sh` call and the `cp … state/claims/…` line,
  so the claims ledger, `bin/conflict-check.sh` and `bin/plan-overlap.sh` all see
  the path this build will actually write. A swap after the copy would publish a
  claim on a file nobody is going to touch.
- **The note and the claim are read off the SAME file.** Both `th_apply` and
  `th_exec_note` run against `$BUILD/test-reroute.txt`, so an executor can never
  be told about a reroute the claim list never got.
- **The backstop never lands on `clean` from a failure.** A broken `git diff`, an
  unresolvable merge base, a missing PR list and a `jq` failure are all
  `not-judged`. `clean` is reachable only after a judgement that actually ran —
  a reviewer told "no sibling holds these files" off a read that failed has been
  told something false, which is worse than being told nothing.
