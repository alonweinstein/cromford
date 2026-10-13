# Scratch-only check (static scan for deletions a script does not own)

**What it is:** `checks/tests-scratch-only/check.sh`, the static half of the
answer to the 2026-09-15 hub wipe (#388, root cause #404, scope #394). It reads
a checkout (or a diff) and prints every line that could delete a path the script
does not own: a `tests/*.sh` that never sourced `tests/lib/scratch.sh` before it
started making temp dirs (R1), a test that `rm -rf`s a variable the lib never
handed out (R2), and a `bin/**/*.sh` that `rm -rf`s a `$HARNESS`-derived path
with no prefix guard (R3). It also ships the three guards that make the live
checkout's `bin/` side of that answer true today —
`bin/preplan-tick.sh:131`, `bin/lib/rt/staging.sh` (the `case "$RDEST" in
"$HARNESS/builds/"*` guard — it moved out of `bin/run-triage.sh` with the rest of
the staging stage in BH-479), `bin/run-preplan.sh:138`, all three mirroring
`bin/run-build.sh:1177`.

**Detection only.** The check has no write path of any kind. The `tests/*.sh`
port landed in #460: every top-level test sources `tests/lib/scratch.sh` before
its first `mktemp`/`rm`/`trap`/`cd`, and every recursive `rm` the check flagged
goes through `scratch_rm`, so `bash checks/tests-scratch-only/check.sh --tree .`
is expected clean on main. `--tree` runs on every PR as the first step of the CI
job `Tests cannot touch a real harness` (`.github/workflows/harness-ci.yml`),
which is what keeps it that way; #463 wired it and ported the last five tests
the check was still flagging.

**How an operator reaches it:** two commands, from a checkout or from
`/root/harness`.

```sh
bin/checks-run.sh --tree .                        every tree-capable check, whole checkout
bash checks/tests-scratch-only/check.sh --tree .  this check on its own
bin/checks-run.sh <a-diff-file>                   the diff lane (R3 only — see below)
```

`bin/checks-run.sh` drops every `tests/` path before a check sees it, so **R1 and
R2 can only fire in tree mode**. Diff mode is R3 over the added-line stream, and
an assignment that is unchanged context is invisible there. Tree mode is the
complete pass.

**Reading the output:** one `path:line<TAB>reason` per hit through the check,
one `CHECK-HIT <slug> <path:line> <reason>` per hit through the runner. rc is
**0 clean / 1 hits / 2 could not run**, and "could not run" includes a root with
no `tests/` and `bin/`, an `awk` stage inside the check that died (both modes),
a tree check that crashed, and a catalog with nothing tree-capable in it — a
scan that did not happen never reads as a clean tree.

**How to drive it:**

| what | how |
|---|---|
| all three rules, against seeded bad and good checkouts, plus both runner modes | `bash tests/tests-scratch-only-check-test.sh` |
| the catalog contract (shape, family key, WHY.md, diff fixtures, cross-fixture silence) and tree mode for every tree-capable check | `bash tests/checks-suite-test.sh` (sections 1–3 and 8) |
| the live checkout's `bin/` guards still hold | section F of `tests/tests-scratch-only-check-test.sh`, or `bash checks/tests-scratch-only/check.sh --tree . \| grep '^bin/'` (must be empty) |
| the suite reads no clock and no network | `bin/test-determinism-lint.sh tests/tests-scratch-only-check-test.sh` |

The fixture trees under `checks/tests-scratch-only/fixtures/tree-bad/` and
`tree-good/` are **data, mode 644**, and nothing in the repo executes them — but
they are written to be **inert if something does**, because "nothing runs them"
is not a property this repo controls. `bin/repro-gate.sh` already globbed all
fifteen fixture scripts as added test files and ran `bash` over the list; it did
no damage only because `check.sh` sorts first in argv and that runner executes
one file. `tree-bad/tests/rm-h-test.sh` is a loaded #388 by design, so:

- both stub `tests/lib/scratch.sh` files `exit 0` on source, which stops every
  fixture that sources them before its own `mkdir` / `trap` / `rm`;
- `rm-h-test.sh` defaults its target to `/dev/null/no-such-harness` (`/dev/null`
  is not a directory, so neither the `mkdir` nor the `rm` can reach anything).

Both rules read TEXT, so all seven seeded hits are unchanged. Section A0 of
`tests/tests-scratch-only-check-test.sh` executes every fixture script against a
fake harness under `$T` and fails if any of it goes missing.

**Files it names on a live box:** none. The check writes stdout and nothing
else — no state file, no ledger, no lock, no cache.

**Knobs:** `CHECKS_DIR` (the runner's catalog directory, default `../checks`).
Nothing here is a new required env var.

**What must never regress:**

- **Tree-capability is declared by `fixtures/tree-bad/`, not by a registry.** A
  stdin-only check must never be handed `--tree`: it would read an empty stream
  and report a pass it never earned. `tests/checks-suite-test.sh` section 8 and
  section D of the check's own suite both pin this.
- **Diff mode is byte-for-byte unchanged.** `bin/checks-run.sh` gained a
  `--tree` branch ahead of the stdin path and nothing else;
  `bin/merge-sweep.sh` and `bin/run-build.sh` call it in diff mode only.
- **Zero `^bin/` hits on the live checkout.** A new unguarded `rm -rf` on a
  `$HARNESS`-derived path in `bin/` turns section F red, which is the whole
  reason the three guards ship alongside the check.
- **No `{n}` quantifiers in any pattern.** `/usr/bin/awk` is mawk on Debian and
  on GitHub's Ubuntu runners, and older mawk silently does not support them — a
  pattern that quietly matches nothing is the failure this catalog prevents.
- **The check fails CLOSED when its own scanner dies.** Every `awk` stage in
  both modes carries `|| exit 3`, and the check reads that rc and answers 2 with
  a reason on stderr. Section C and section D of the check's suite prove it with
  a fake `awk` that exits 3, against the tree that holds seven violations: rc 2
  and `CHECK-ERROR`, never `CHECKS: clean`. This is the mode CI runs, where a
  silently-empty scan would be the most expensive answer available.
- **The fixtures stay inert.** Section A0 executes every fixture script against
  a fake harness. A fixture that grows teeth turns it red.
