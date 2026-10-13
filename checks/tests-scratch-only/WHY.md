# tests-scratch-only

- **Family key:** `b3957447980a`
- **30-day count when promoted:** 1 — this is an INCIDENT family, not a miner family
- **Projects:** cromford (the harness itself)
- **Ruled by:** nobody. `bin/rule-miner.sh` never saw this one. It was earned in
  a single event, on 2026-09-15 at 16:50Z.
- **Promoted to `checks/`:** 2026-09-17 (#461, child 3 of scope #394)

## The one finding it was mined from

```
2026-09-15 16:50Z [cromford] incident #388 :: the live /root/harness was wiped
2026-09-15       [cromford] root cause #404 :: a tests/*.sh re-derived $H as the
                                                    real harness root and rm -rf'd it
2026-09-15 19:37Z [cromford] scope #394     :: the three rules below
```

A top-level test never sourced a scratch library, so nothing had set `$T` for
it. It computed its own `H="${HARNESS:-/root/harness}"`, treated that as its
fixture tree, and cleaned up after itself. The cleanup was the live hub.

Every other check in this catalog costs a review round when it is wrong. This
one costs a restore from backup when it is missing, which is why it is here on a
count of one.

## The three rules

- **R1** — a top-level test (`tests/*.sh`) that does not source
  `tests/lib/scratch.sh` **before** its first `mktemp` / `rm` / `trap` /
  line-leading `cd`. Comments, blank lines, `set …`, `DIR=$(cd … && pwd)` and
  plain assignments above the source line are fine: a mechanical port keeps its
  preamble, and a rule that forbade the preamble would flag the very output the
  port produces.
- **R2** — a top-level test with a recursive `rm` in command position (line
  start, after `;` `&&` `||` `(` `{` `then` `do` `else`, or immediately after a
  single quote, so `trap 'rm -rf "$H"'` and `bash -c 'rm -rf "$1/calls"'` are
  both in scope) whose **first** argument expands a variable that is neither
  `T` nor `SCRATCH`. Those two are the only names the lib hands out.
- **R3** — a `bin/**/*.sh` recursive `rm` whose first argument is a
  `$HARNESS`-derived path — textually `$HARNESS…` / `${HARNESS}…` / `$H/…` /
  `${H}…`, or a `$VAR` the same file assigns from a `$HARNESS`-derived
  expression — with no `case "$VAR" in "$HARNESS/…"*)` prefix guard in the six
  lines above it (the same line counts). The reference shape is
  `bin/run-build.sh:1177`, which stays silent.

## The objectivity test

- **Measurable observation:** the three rules above, each decided from the text
  of one file, with no judgement call and no cross-file inference.
- **Named tool:** `checks/tests-scratch-only/check.sh`, in either mode —
  `check.sh` on the added-line stream, or `check.sh --tree <root>` on a whole
  checkout. `bin/checks-run.sh --tree <root>` runs it the second way.
- **Explicit threshold:** one or more such lines.

## Known false positives

- **R2 flags `rm -rf "$D"` even when `D="$T/x"` two lines up.** The rule is a
  textual prefix rule on purpose. One-hop dataflow is exactly what the
  2026-09-15 wipe defeated: the variable was reassigned by a file that was
  sourced in between. The remedy is `scratch_rm "$D"`, which checks the path at
  run time instead of guessing at scan time.
- **R2 flags `rm` text inside a single-quoted string that is not a heredoc** —
  a test that builds a fixture script with `printf 'rm -rf "$X"'` reads as a
  deletion. Heredoc bodies are skipped, so the remedy is to write fixture
  scripts as heredocs (which is how nearly all of them are written already).
- **R3 flags an `rm` whose variable was assigned from `$HARNESS` in a branch
  that can never run.** Cheap to read, cheap to guard anyway.
- **R2 scans the body of a `<<\EOF` heredoc.** The backslash-quoted spelling of
  a quoted tag is not recognised; `<<'EOF'` and `<<"EOF"` are. Write the quoted
  form and the body is skipped.

## Known false negatives

- **R3 misses a loop variable.** `find "$HARNESS/…" | while read -r d; do rm -rf
  "$d"` is not an assignment this rule can see (`bin/preplan-tick.sh:79,144`
  today). #462's dynamic tracer and a follow-up own that shape.
- **Non-recursive `rm -f` is out of scope** in both R2 and R3.
- **Diff mode sees only added lines.** An `rm` added below an assignment that is
  unchanged context has no visible derivation, so R3 cannot fire on it there.
  Tree mode is the complete pass, which is why it exists.
- **Tree mode scans `bin/**/*.sh`; diff mode scans every `bin/` path.** A
  `bin/` script without a `.sh` suffix is visible to the diff lane only.
- **`rm -rf "$(dirname "$X")"` has no first-argument variable** to key on and is
  not flagged by either rule.
- **Only the literal `rm` verb, in command position.** `command rm -rf "$X"`,
  `sudo rm -rf "$X"`, `xargs rm -rf` and `find "$X" -delete` are all silent in
  R2 and R3. `find "$H" -delete` in a test with no `mktemp` / `rm` / `trap` / `cd`
  of its own also passes R1, because nothing triggers the rule.
- **The R3 guard window is six textual lines, and it is textual all the way
  down.** Four shapes read as guarded when they are not: (a) a `case` on the
  right variable that CLOSES before the `rm` but still sits inside the window;
  (b) a `case` on the right variable whose arms do not match, when any
  `$HARNESS/` text appears anywhere in the window — `case "$E" in /tmp/*) echo
  "$HARNESS/log"; rm -rf "$E" ;; esac` is silent; (c) the `rm` in the `*)` arm
  of an otherwise correct `case`; (d) `: "${D:=$HARNESS/…}"`, whose assignment
  R3 cannot see, so a later `rm -rf "$D"` is silent. These are design limits of
  a rule the ticket pinned as textual, not bugs to fix here — #462's dynamic
  tracer is what closes them. `for K in "$HARNESS"/builds/*; do rm -rf "$K"` and
  `H="${HARNESS:-/root/harness}"; rm -rf "$H"` ARE caught.
- **Diff mode truncates a text field at an embedded tab.** The stream is
  `path<TAB>line<TAB>text` and only `$3` is read, so a literal tab inside the
  source line hides everything after it. Tree mode reads the file and is exact.

## The fixtures are inert, and that is tested

`fixtures/tree-bad/` is a checkout shaped wrong on purpose, and
`tree-bad/tests/rm-h-test.sh` is the #388 wipe itself. The files are mode 644
and nothing in the repo runs them, but that is not a guarantee this repo owns:
`bin/repro-gate.sh` globs `tests/`-shaped paths out of a diff and runs `bash`
over them, and it selected all fifteen fixture scripts from this very PR. So
both stub `tests/lib/scratch.sh` files `exit 0` on source — every fixture that
sources one stops there, before its own `mkdir` / `trap` / `rm` — and
`rm-h-test.sh` defaults its target to `/dev/null/no-such-harness`, which cannot
be created or deleted. Both rules read TEXT, so all seven seeded hits are
unchanged, and section A0 of `tests/tests-scratch-only-check-test.sh` executes
every fixture against a fake harness under `$T` and fails if any of it vanishes.

## What it deliberately does NOT do

It does not fix, rewrite, or delete anything — least of all the lines it finds.
A check that "helpfully" edited an `rm` would be the same class of mistake as
the incident that produced it: a script deleting something a human never looked
at. Converting the 300-odd `tests/*.sh` hits to `scratch_rm` is a mechanical
port done by a person with a diff in front of them (#460), not by this file.
