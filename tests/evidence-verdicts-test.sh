#!/bin/bash
# tests/evidence-verdicts-test.sh — the deterministic scorer in
# bin/lib/evidence.sh (#546): the claim parser, the artifact locator, the
# proposal pointer and the six verdict rules.
#
# WHY THESE ASSERTIONS. The scorer's whole job is to refuse to say CONFIRMED
# when nothing proves the claim, so the negatives carry the weight here: a
# locator that finds nothing is INCONCLUSIVE (never a pass), `red.txt` is never
# a source, `HARNESS_EXIT: 0` names no test and confirms none, a harness FAIL
# beats an agent-recorded exit 0, and a model-written proposal is a POINTER —
# it can never upgrade a verdict the deterministic rules decided.
#
# No caller is wired yet (#547 wires it), so this suite IS the consumer: it
# sources the lib the way a lane does and drives the real `evidence_score` on
# real build dirs and a real scratch git repo. Every assertion reads
# evidence.json, the scorer's stdout or a return code; the one source-text pin
# (no vendor name, no network) is guarded so an absent file fails.
#
# Run: bash tests/evidence-verdicts-test.sh   (exit 0 = all pass)
set -uo pipefail
if [ -f "$(dirname "$0")/lib/scratch.sh" ]; then
  # shellcheck source=/dev/null
  . "$(dirname "$0")/lib/scratch.sh" || exit 1
else
  T=$(mktemp -d "${TMPDIR:-/tmp}/scratch.XXXXXX") || exit 1
  trap 'rm -rf "$T"' EXIT
fi
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/evidence.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: [$2] does not contain [$3]" ;; esac; }

# ── §0 sourcing is inert ─────────────────────────────────────────────────────
# A lib that prints or writes at source time corrupts every lane that sources
# it, so this runs first, in its own process, under `set -u`.
mkdir -p "$T/probe"
OUT=$(cd "$T/probe" && bash -u -c ". '$LIB'" 2>&1); RC=$?
eq "§0 sourcing under set -u prints nothing" "$OUT" ""
eq "§0 sourcing under set -u exits 0" "$RC" "0"
eq "§0 sourcing creates no files" "$(ls -A "$T/probe")" ""

# shellcheck source=../bin/lib/evidence.sh
. "$LIB" || { echo "evidence-verdicts: cannot source bin/lib/evidence.sh"; exit 1; }

# A scratch repo whose diff touches nothing: the staging check must say "no" for
# every test named below, so these sections test the LOCATOR, not staging.
REPO="$T/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main >/dev/null 2>&1
printf 'fixture\n' > "$REPO/README.md"
git -C "$REPO" add README.md >/dev/null 2>&1
git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -q -m base >/dev/null 2>&1

score() { # score <build> <plan> [base] [repo] — the production entry point
  SOUT=$(evidence_score "$1" "$2" "${3:-main}" "${4:-$REPO}" 2>&1); SRC=$?
}
j() { jq -r "$2" "$1/evidence.json" 2>/dev/null; }
mkb() { # mkb <build-dir> <test-path> — a one-claim plan naming one test
  mkdir -p "$1"
  printf '## Acceptance tests\n- the lane works, proven by `%s`\n' "$2" > "$1/plan.md"
}
tmpleft() { ls -A "$1" | grep -c 'evidence\.\(json\|rows\)\.'; }

# ── §1 the scorer end to end: one of each verdict ────────────────────────────
B1="$T/b1"; mkdir -p "$B1"
cat > "$B1/plan.md" <<'PLAN'
# Plan — fixture

## Scope
Nothing to see here.

## Acceptance tests
- the reader prints the counts, proven by `tests/a-test.sh`
- the gate demotes, proven by `tests/b-test.sh`
- the lane is reachable, proven by `tests/c-test.sh`

## Size
FILES: 1
PLAN
cat > "$B1/validate.txt" <<'VAL'
T1 — the reader
COMMAND: bash tests/a-test.sh
evidence-reader: 9 passed, 0 failed
exit 0

T2 — the gate
COMMAND: bash tests/b-test.sh
evidence-gate: 7 passed, 2 failed
exit 1
VAL
printf 'HARNESS_EXIT: no-test-script\n' > "$B1/harness-suite.txt"
LA=$(grep -n 'bash tests/a-test.sh' "$B1/validate.txt" | cut -d: -f1)
LB=$(grep -n '^exit 1' "$B1/validate.txt" | cut -d: -f1)
score "$B1" "$B1/plan.md"
eq "§1 the scorer returns 0" "$SRC" "0"
eq "§1 three top-level items are three claims" "$(j "$B1" '.total')" "3"
eq "§1 the claim text is the folded item text" "$(j "$B1" '.claims[0].claim')" \
  "the reader prints the counts, proven by tests/a-test.sh"
eq "§1 claim 1 is CONFIRMED" "$(j "$B1" '.claims[0].verdict')" "CONFIRMED"
eq "§1 claim 1's artifact is the agent-recorded validate line" \
  "$(j "$B1" '.claims[0].artifact')" "validate.txt:$LA (agent-recorded)"
eq "§1 claim 2 is REFUTED" "$(j "$B1" '.claims[1].verdict')" "REFUTED"
eq "§1 claim 2's artifact points at the exit 1 line" \
  "$(j "$B1" '.claims[1].artifact')" "validate.txt:$LB (agent-recorded)"
has "§1 claim 2's note carries the exit line" "$(j "$B1" '.claims[1].note')" "exit 1"
eq "§1 claim 3 is INCONCLUSIVE" "$(j "$B1" '.claims[2].verdict')" "INCONCLUSIVE"
has "§1 claim 3's note says the test never appears" "$(j "$B1" '.claims[2].note')" "never appears"
eq "§1 the counts are 1/1/1" "$(j "$B1" '"\(.confirmed)/\(.refuted)/\(.inconclusive)"')" "1/1/1"
eq "§1 the contract reader agrees with the file" "$(evidence_counts "$B1")" \
  "confirmed=1 refuted=1 inconclusive=1 total=3"
eq "§1 stdout carries one CLAIM line per claim" "$(grep -c '^CLAIM ' <<<"$SOUT")" "3"
eq "§1 the summary line is the last line" "$(tail -1 <<<"$SOUT")" \
  "EVIDENCE VERDICTS: 1 confirmed, 1 refuted, 1 inconclusive of 3 claims"
eq "§1 the atomic write leaves no temp file behind" "$(tmpleft "$B1")" "0"
# evidence_claims is the documented two-field reader siblings call directly.
eq "§1 evidence_claims prints <n>TAB<bounded claim text>" \
  "$(evidence_claims "$B1/plan.md" | head -1)" \
  "$(printf '1\tthe reader prints the counts, proven by tests/a-test.sh')"
eq "§1 evidence_claims numbers every top-level item from 1" \
  "$(evidence_claims "$B1/plan.md" | cut -f1 | tr '\n' ' ')" "1 2 3 "

# Mutation: the only thing that made claim 1 CONFIRMED was the recorded exit 0.
B1M="$T/b1m"; mkdir -p "$B1M"
cp "$B1/plan.md" "$B1/harness-suite.txt" "$B1M/"
sed 's/^exit 0$/exit 1/' "$B1/validate.txt" > "$B1M/validate.txt"
score "$B1M" "$B1M/plan.md"
eq "§1 mutation: a recorded exit 1 flips claim 1 to REFUTED" "$(j "$B1M" '.claims[0].verdict')" "REFUTED"

# The exit number must be IN the 60-line window, not anywhere in the file.
B1W="$T/b1w"; mkdir -p "$B1W"
cp "$B1/plan.md" "$B1W/"
{ printf 'COMMAND: bash tests/a-test.sh\n'
  for i in $(seq 1 61); do printf 'log line %s\n' "$i"; done
  printf 'exit 0\n'; } > "$B1W/validate.txt"
score "$B1W" "$B1W/plan.md"
eq "§1 an exit 0 past the 60-line window locates nothing" "$(j "$B1W" '.claims[0].verdict')" "INCONCLUSIVE"

# ── §1e the real executor template: `TASK:`/`CMD :`/`EXIT: 0` (finding #1) ───
# 304 of 851 real validate.txt files use this exact uppercase-colon shape; the
# suite above is all lowercase `exit 0`, which is why the case-sensitivity bug
# shipped green.
B="$T/e1"; mkb "$B" tests/e-test.sh
printf 'TASK: T1\nCMD : bash tests/e-test.sh\nEXIT: 0\n' > "$B/validate.txt"
score "$B" "$B/plan.md"
eq "§1e uppercase EXIT: 0 is located as a pass" "$(j "$B" '.claims[0].verdict')" "CONFIRMED"

B="$T/e2"; mkb "$B" tests/e-test.sh
printf 'TASK: T1\nCMD : bash tests/e-test.sh\nEXIT: 1\n' > "$B/validate.txt"
score "$B" "$B/plan.md"
eq "§1e uppercase EXIT: 1 is located as a fail" "$(j "$B" '.claims[0].verdict')" "REFUTED"

# ── §1f a prose mention of the path must not be read as its run (finding #2) ─
# The FIRST line naming the path is prose, not a run; a window opened from
# there catches an unrelated "rc 1" mid-sentence. Only a RUN line (`$ `, CMD,
# COMMAND:, bash, RED, GREEN) may open the window.
B="$T/e3"; mkb "$B" tests/e-test.sh
{ printf 'Note: tests/e-test.sh has flaked in CI before.\n'
  printf 'Last week the driver saw rc 1 here, unrelated to this run.\n\n'
  printf 'CMD : bash tests/e-test.sh\n'
  printf 'EXIT: 0\n'; } > "$B/validate.txt"
score "$B" "$B/plan.md"
eq "§1f a prose line naming the path is not a run; the real CMD/EXIT below decides" \
  "$(j "$B" '.claims[0].verdict')" "CONFIRMED"

# ── §1g the LAST run of a test wins, not the first (finding #2) ─────────────
# A RED block's failing rerun sits above a later GREEN rerun of the same test:
# the GREEN one is the current state and must decide, not the RED one.
B="$T/e4"; mkb "$B" tests/f-test.sh
{ printf 'RED:\n$ bash tests/f-test.sh\nexit=1\n\n'
  printf 'GREEN:\n$ bash tests/f-test.sh\nexit=0\n'; } > "$B/validate.txt"
score "$B" "$B/plan.md"
eq "§1g a later GREEN rerun outranks an earlier RED one" \
  "$(j "$B" '.claims[0].verdict')" "CONFIRMED"

# ── §1h a pass summary's "0 failed" is not a fail marker (finding #3) ───────
B="$T/e5"; mkb "$B" tests/g-test.sh
printf '✓ tests/g-test.sh 12 passed, 0 failed\n' > "$B/harness-suite.txt"
score "$B" "$B/plan.md"
eq "§1h a bare '0 failed' in a pass summary does not refute the claim" \
  "$(j "$B" '.claims[0].verdict')" "CONFIRMED"

B="$T/e6"; mkb "$B" tests/g-test.sh
printf '✗ tests/g-test.sh 11 passed, 1 failed\n' > "$B/harness-suite.txt"
score "$B" "$B/plan.md"
eq "§1h a real nonzero '1 failed' still refutes the claim" \
  "$(j "$B" '.claims[0].verdict')" "REFUTED"

# ── §1i an `@` in the test path must not break the own-token scrub (finding #8) ─
B="$T/e7"; mkb "$B" 'tests/@weird-test.sh'
printf '✓ tests/@weird-test.sh (1 test)\n' > "$B/harness-suite.txt"
score "$B" "$B/plan.md"
eq "§1i a path containing @ still locates as a pass" "$(j "$B" '.claims[0].verdict')" "CONFIRMED"

# ── §1j the validate.txt window stops at the NEXT run/NOT RUN line (round-2 #1) ─
# The executor writes one block per task; without a stop, a's window reaches
# six lines into b's block and borrows b's EXIT.
B="$T/j1"; mkdir -p "$B"
{ printf '## Acceptance tests\n- a runs, proven by `tests/a-test.sh`\n- b runs, proven by `tests/b-test.sh`\n'
} > "$B/plan.md"
{ printf 'TASK: T1\n'
  printf 'CMD : bash tests/a-test.sh\n'
  printf 'NOT RUN: needs a browser\n'
  printf 'TASK: T2\n'
  printf 'CMD : bash tests/b-test.sh\n'
  printf 'EXIT: 0\n'; } > "$B/validate.txt"
score "$B" "$B/plan.md"
eq "§1j a NOT RUN test does not borrow its neighbour's EXIT (CONFIRMED)" \
  "$(j "$B" '.claims[0].verdict')" "INCONCLUSIVE"
eq "§1j the neighbour is still located correctly" "$(j "$B" '.claims[1].verdict')" "CONFIRMED"

B="$T/j2"; mkdir -p "$B"
{ printf '## Acceptance tests\n- a runs, proven by `tests/a-test.sh`\n- b runs, proven by `tests/b-test.sh`\n'
} > "$B/plan.md"
{ printf 'CMD : bash tests/a-test.sh\n'
  printf '(output truncated)\n'
  printf 'CMD : bash tests/b-test.sh\n'
  printf 'EXIT: 1\n'; } > "$B/validate.txt"
score "$B" "$B/plan.md"
eq "§1j a test with no exit line of its own does not borrow the next block's REFUTED" \
  "$(j "$B" '.claims[0].verdict')" "INCONCLUSIVE"
eq "§1j the neighbour is still REFUTED" "$(j "$B" '.claims[1].verdict')" "REFUTED"

# ── §1k the RUN_RE gate and the exit-token anchor bite standalone (round-2 #2) ─
# §1f/§1g only exercise these in combination with the LAST-run rule; these two
# fixtures isolate each half so a mutation that removes either one goes red on
# its own (M5, M6 in the round-2 review).
B="$T/k1"; mkb "$B" tests/e-test.sh
{ printf 'CMD : bash tests/e-test.sh\n'
  printf 'EXIT: 0\n'
  printf '\n'
  printf 'Note: tests/e-test.sh is also invoked by the driver.\n'
  printf 'rc 1 was what the driver saw last week.\n'; } > "$B/validate.txt"
score "$B" "$B/plan.md"
eq "§1k only a RUN line names a test; a later prose mention does not reopen the window" \
  "$(j "$B" '.claims[0].verdict')" "CONFIRMED"

B="$T/k2"; mkb "$B" tests/e-test.sh
{ printf 'CMD : bash tests/e-test.sh\n'
  printf 'the driver saw rc 1 here in a previous run\n'
  printf 'EXIT: 0\n'; } > "$B/validate.txt"
score "$B" "$B/plan.md"
eq "§1k the exit token must be line-leading, not mid-sentence" \
  "$(j "$B" '.claims[0].verdict')" "CONFIRMED"

# ── §1l TAP '# SKIP' is not a pass (round-2 finding #3) ──────────────────────
B="$T/l1"; mkb "$B" tests/a-test.sh
printf 'ok 1 - tests/a-test.sh # SKIP no browser\n' > "$B/harness-suite.txt"
score "$B" "$B/plan.md"
eq "§1l a TAP SKIP does not confirm the claim" "$(j "$B" '.claims[0].verdict')" "INCONCLUSIVE"

# ── §1b harness-run output is ground truth; validate.txt is hearsay ──────────
B="$T/b2"; mkb "$B" tests/a-test.sh
printf 'running the suite\n✗ tests/a-test.sh (2 failed)\n' > "$B/harness-suite.txt"
printf 'COMMAND: bash tests/a-test.sh\nexit 0\n' > "$B/validate.txt"
LN=$(grep -n '✗' "$B/harness-suite.txt" | cut -d: -f1)
score "$B" "$B/plan.md"
eq "§1b a harness FAIL beats an agent-recorded exit 0" "$(j "$B" '.claims[0].verdict')" "REFUTED"
eq "§1b the artifact is the harness line" "$(j "$B" '.claims[0].artifact')" "harness-suite.txt:$LN"

B="$T/b3"; mkb "$B" tests/a-test.sh
printf 'running the suite\n✓ tests/a-test.sh (2 tests)\n' > "$B/harness-suite.txt"
printf 'COMMAND: bash tests/a-test.sh\nexit 0\n' > "$B/validate.txt"
LN=$(grep -n '✓' "$B/harness-suite.txt" | cut -d: -f1)
score "$B" "$B/plan.md"
eq "§1b a harness pass is CONFIRMED" "$(j "$B" '.claims[0].verdict')" "CONFIRMED"
eq "§1b the harness line is preferred over the validate line" \
  "$(j "$B" '.claims[0].artifact')" "harness-suite.txt:$LN"

B="$T/b4"; mkb "$B" tests/a-test.sh
printf '✗ tests/a-test.sh (1 failed)\n' > "$B/harness-suite-head.txt"
printf '✓ tests/a-test.sh (2 tests)\n' > "$B/harness-suite.txt"
score "$B" "$B/plan.md"
eq "§1b harness-suite-head.txt wins the precedence" "$(j "$B" '.claims[0].verdict')" "REFUTED"
eq "§1b and supplies the artifact" "$(j "$B" '.claims[0].artifact')" "harness-suite-head.txt:1"

B="$T/b5"; mkb "$B" tests/a-test.sh
printf 'Running tests/a-test.sh\n' > "$B/harness-suite.txt"
printf 'COMMAND: bash tests/a-test.sh\nexit 0\n' > "$B/validate.txt"
score "$B" "$B/plan.md"
eq "§1b a suite line with no marker falls through to validate.txt" \
  "$(j "$B" '.claims[0].verdict')" "CONFIRMED"
eq "§1b with the agent-recorded label on the artifact" \
  "$(j "$B" '.claims[0].artifact')" "validate.txt:1 (agent-recorded)"

B="$T/b6"; mkb "$B" tests/ok-test.sh
printf 'tests/ok-test.sh\n' > "$B/harness-suite.txt"
score "$B" "$B/plan.md"
eq "§1b a test whose own name contains 'ok' does not confirm itself" \
  "$(j "$B" '.claims[0].verdict')" "INCONCLUSIVE"

B="$T/b7"; mkb "$B" tests/a-test.sh
printf 'not ok tests/a-test.sh\n' > "$B/harness-suite.txt"
printf 'COMMAND: bash tests/a-test.sh\nexit 0\n' > "$B/validate.txt"
score "$B" "$B/plan.md"
eq "§1b TAP 'not ok' is a fail marker, checked before 'ok'" \
  "$(j "$B" '.claims[0].verdict')" "REFUTED"

B="$T/b8b"; mkdir -p "$B"
# A plan may name its test bare, with no backticks around it (the ticket:
# "from backticks or bare"). Splitting only on punctuation would miss it.
printf '## Acceptance tests\n- the lane works, proven by tests/a-test.sh in the suite\n- the reader prints the counts, proven by tests/b-test.sh\n' > "$B/plan.md"
printf 'COMMAND: bash tests/a-test.sh\nexit 1\n\nCOMMAND: bash tests/b-test.sh\nexit 1\n' > "$B/validate.txt"
score "$B" "$B/plan.md"
eq "§1b a bare (un-backticked) test path is still a named test" \
  "$(j "$B" '.claims[0].verdict')" "REFUTED"
eq "§1b a bare test path at the very end of the item is still a named test" \
  "$(j "$B" '.claims[1].verdict')" "REFUTED"

B="$T/b8"; mkb "$B" tests/a-test.sh
printf '✓ tests/a-test.sh.bak (1 test)\n✓ tests/a-tests.sh (1 test)\n' > "$B/harness-suite.txt"
score "$B" "$B/plan.md"
eq "§1b a near-miss path does not name the test (whole-token)" \
  "$(j "$B" '.claims[0].verdict')" "INCONCLUSIVE"

# ── §1c nothing to score, and the three sources that prove nothing ──────────
ZERO="EVIDENCE VERDICTS: 0 confirmed, 0 refuted, 0 inconclusive of 0 claims"
B="$T/c1"; mkdir -p "$B"
printf '# Plan\n\n## Scope\nno acceptance section at all\n' > "$B/plan.md"
score "$B" "$B/plan.md"
eq "§1c no section returns 0" "$SRC" "0"
eq "§1c no section is zero claims" "$(j "$B" '"\(.total)\(.claims)"')" "0[]"
eq "§1c no section prints only the zero summary" "$SOUT" "$ZERO"

# TEST-CHANGE (finding #7, 2026-09-22): a section that EXISTS but scores zero
# items (empty, prose-only, or table-only) is no longer byte-identical to "no
# section at all" — it now carries one distinguishing EVIDENCE NOTE line ahead
# of the summary, so a consumer (#547) can tell "nothing to score" apart from
# "the plan forgot the acceptance tests". Only the SOUT assertions below change
# (c1, the true no-heading case, is untouched); total/claims/counts stay zero
# either way.
NOTED_ZERO="$(printf 'EVIDENCE NOTE: acceptance section present, no list items\n%s' "$ZERO")"

B="$T/c2"; mkdir -p "$B"
printf '## Acceptance tests\n\n## Size\nFILES: 1\n' > "$B/plan.md"
score "$B" "$B/plan.md"
eq "§1c an empty section is zero claims" "$(j "$B" '"\(.total)\(.claims)"')" "0[]"
eq "§1c an empty section notes the section was present, then the zero summary" \
  "$SOUT" "$NOTED_ZERO"

B="$T/c3"; mkdir -p "$B"
cat > "$B/plan.md" <<'PLAN'
## Acceptance tests
The suite covers the reader and the gate. Nothing is listed here.

```
- tests/z-test.sh proves the fence is skipped
```

## Size
PLAN
score "$B" "$B/plan.md"
eq "§1c a prose-only section with a fenced list is zero claims" \
  "$(j "$B" '"\(.total)\(.claims)"')" "0[]"
eq "§1c and notes the section was present, then the zero summary" "$SOUT" "$NOTED_ZERO"

B="$T/c6"; mkdir -p "$B"
printf '## Acceptance tests\n\n| # | Test |\n|---|---|\n| 1 | tests/a-test.sh |\n\n## Size\n' \
  > "$B/plan.md"
score "$B" "$B/plan.md"
eq "§1c a table-only section is zero claims (a table row is not a bullet)" \
  "$(j "$B" '"\(.total)\(.claims)"')" "0[]"
eq "§1c a table-only section notes the section was present too" "$SOUT" "$NOTED_ZERO"

# ── §1m a CRLF plan is not silently read as "no section" (round-2 finding #4) ─
B="$T/c7"; mkdir -p "$B"
printf '## Acceptance tests\r\n- the reader prints the counts, proven by `tests/a-test.sh`\r\n' \
  > "$B/plan.md"
printf 'COMMAND: bash tests/a-test.sh\nexit 0\n' > "$B/validate.txt"
score "$B" "$B/plan.md"
eq "§1m a CRLF heading and item are still read" "$(j "$B" '.total')" "1"
eq "§1m and the claim still locates" "$(j "$B" '.claims[0].verdict')" "CONFIRMED"

B="$T/c8"; mkdir -p "$B"
printf '## Acceptance tests\r\n\r\n## Size\r\nFILES: 1\r\n' > "$B/plan.md"
score "$B" "$B/plan.md"
eq "§1m a CRLF empty section still notes the section was present" "$SOUT" "$NOTED_ZERO"

# ── §1n the NOT RUN stop must be awk-portable, not `\b` (round-3 finding #1) ─
# `\b` is the backspace character in mawk/gawk, not a word boundary — the
# fleet's mawk never matched the old `NOT RUN\b`, so a `NOT RUN:` block that
# ALSO carries an EXIT line (the prompt asks for one per block; a template
# loop can emit it anyway), or one followed by a next block with no CMD-shaped
# line before its own EXIT, still borrowed a false CONFIRMED. Both shapes are
# from the round-3 review, verified to reproduce on mawk before this fix.
B="$T/n1"; mkb "$B" tests/a-test.sh
{ printf 'CMD : bash tests/a-test.sh\n'
  printf 'NOT RUN: needs a browser\n'
  printf 'EXIT: 0\n'; } > "$B/validate.txt"
score "$B" "$B/plan.md"
eq "§1n NOT RUN: with an EXIT line in the SAME block is still INCONCLUSIVE" \
  "$(j "$B" '.claims[0].verdict')" "INCONCLUSIVE"

B="$T/n2"; mkb "$B" tests/a-test.sh
{ printf 'CMD : bash tests/a-test.sh\n'
  printf 'NOT RUN: needs a browser\n'
  printf 'TASK: T2\n'
  printf 'EXIT: 0\n'; } > "$B/validate.txt"
score "$B" "$B/plan.md"
eq "§1n NOT RUN: does not borrow a next block whose own line is TASK:-only" \
  "$(j "$B" '.claims[0].verdict')" "INCONCLUSIVE"

B="$T/c4"; mkb "$B" tests/c-test.sh
printf '✓ tests/c-test.sh (4 tests)\n' > "$B/red.txt"
score "$B" "$B/plan.md"
eq "§1c red.txt is never a source" "$(j "$B" '.claims[0].verdict')" "INCONCLUSIVE"

B="$T/c5"; mkb "$B" tests/c-test.sh
printf 'HARNESS_EXIT: 0\n' > "$B/harness-suite.txt"
score "$B" "$B/plan.md"
eq "§1c HARNESS_EXIT: 0 names no test and confirms none" \
  "$(j "$B" '.claims[0].verdict')" "INCONCLUSIVE"

# ── §1d the 300-char bound is on the RECORDED text, not on the scan ─────────
B="$T/d1"; mkdir -p "$B"
{ printf '## Acceptance tests\n'
  printf -- '- the summary line renders after the atomic write, and the reader and the gate and the lane all agree on the counts, which matters because a half-written file reads as a scored build and a scored build is never re-scored, so the write ordering is the property under test here and it is proven by `tests/d-test.sh`\n'
} > "$B/plan.md"
printf 'COMMAND: bash tests/d-test.sh\nexit 1\n' > "$B/validate.txt"
score "$B" "$B/plan.md"
eq "§1d the recorded claim text is bounded to 300 chars" \
  "$(j "$B" '.claims[0].claim | length <= 300')" "true"
eq "§1d a test named past the cut is still found" "$(j "$B" '.claims[0].verdict')" "REFUTED"

# ── §5 a proposal is a pointer, never an upgrade ─────────────────────────────
# Claim 3 here names NO test, which is the only case where rule 5 applies.
NOTEST="$T/plan-notest.md"
cat > "$NOTEST" <<'PLAN'
## Acceptance tests
- the reader prints the counts, proven by `tests/a-test.sh`
- the gate demotes, proven by `tests/b-test.sh`
- the queue page renders its empty state
PLAN

B="$T/p1"; mkdir -p "$B"
cp "$B1/validate.txt" "$B/validate.txt"
printf 'CLAIM 3: CONFIRMED :: qa-shots/never.png :: looked fine\n' > "$B/evidence-proposed.txt"
score "$B" "$NOTEST"
eq "§5 a proposal whose artifact does not exist stays INCONCLUSIVE" \
  "$(j "$B" '.claims[2].verdict')" "INCONCLUSIVE"
eq "§5 and says why" "$(j "$B" '.claims[2].note')" "proposed CONFIRMED but artifact missing"
eq "§5 the proposal is still recorded beside the decided verdict" \
  "$(j "$B" '.claims[2].proposed')" "CONFIRMED"

B="$T/p2"; mkdir -p "$B/qa-shots"
cp "$B1/validate.txt" "$B/validate.txt"
printf 'CLAIM 3: CONFIRMED :: qa-shots/c.png :: the empty state renders\n' > "$B/evidence-proposed.txt"
printf 'not really a png\n' > "$B/qa-shots/c.png"
score "$B" "$NOTEST"
eq "§5 an existing non-empty artifact confirms a claim that names no test" \
  "$(j "$B" '.claims[2].verdict')" "CONFIRMED"
eq "§5 the artifact is the proposed path" "$(j "$B" '.claims[2].artifact')" "qa-shots/c.png"

B="$T/p3"; mkdir -p "$B/qa-shots"
printf 'CLAIM 3: CONFIRMED :: qa-shots/e.png :: looked fine\n' > "$B/evidence-proposed.txt"
: > "$B/qa-shots/e.png"
score "$B" "$NOTEST"
eq "§5 an existing but EMPTY artifact counts as missing" "$(j "$B" '.claims[2].verdict')" "INCONCLUSIVE"
eq "§5 and says so" "$(j "$B" '.claims[2].note')" "proposed CONFIRMED but artifact missing"

B="$T/p4"; mkdir -p "$B/qa-shots"
cp "$B1/validate.txt" "$B/validate.txt"
printf 'not really a png\n' > "$B/qa-shots/c.png"
printf 'CLAIM 3: CONFIRMED :: qa-shots/c.png :: looked fine\n' > "$B/evidence-proposed.txt"
score "$B" "$B1/plan.md"
eq "§5 a valid pointer never upgrades a claim whose named test was never located" \
  "$(j "$B" '.claims[2].verdict')" "INCONCLUSIVE"
has "§5 the deterministic note stands" "$(j "$B" '.claims[2].note')" "never appears"

B="$T/p5"; mkdir -p "$B"
cp "$B1/validate.txt" "$B/validate.txt"
printf 'CLAIM 1: REFUTED :: bin/lib/evidence.sh:120 :: the counts were wrong on screen\n' > "$B/evidence-proposed.txt"
score "$B" "$B1/plan.md"
eq "§5 a proposed REFUTED always stands, even over a passing artifact" \
  "$(j "$B" '.claims[0].verdict')" "REFUTED"
eq "§5 with the proposal's artifact" "$(j "$B" '.claims[0].artifact')" "bin/lib/evidence.sh:120"
eq "§5 and the proposal's note" "$(j "$B" '.claims[0].note')" "the counts were wrong on screen"

B="$T/p6"; mkdir -p "$B/qa-shots"
cp "$B1/validate.txt" "$B/validate.txt"
printf 'not really a png\n' > "$B/qa-shots/c.png"
printf 'CLAIM 9: CONFIRMED :: qa-shots/c.png :: out of range\n' > "$B/evidence-proposed.txt"
score "$B" "$B1/plan.md"
eq "§5 an out-of-range proposal adds no row" "$(j "$B" '.total')" "3"
has "§5 an out-of-range proposal is mentioned in the run's stdout" "$SOUT" \
  "EVIDENCE NOTE: proposal CLAIM 9 ignored"

mkdir -p "$T/etc"; printf 'root:x:0:0\n' > "$T/etc/passwd"
B="$T/p7"; mkdir -p "$B"
printf 'CLAIM 3: CONFIRMED :: ../../etc/passwd :: escaped the build dir\n' > "$B/evidence-proposed.txt"
score "$B" "$NOTEST"
eq "§5 a ../ artifact counts as missing" "$(j "$B" '.claims[2].verdict')" "INCONCLUSIVE"
B="$T/p8"; mkdir -p "$B"
printf 'CLAIM 3: CONFIRMED :: /etc/passwd :: absolute path\n' > "$B/evidence-proposed.txt"
score "$B" "$NOTEST"
eq "§5 an absolute artifact counts as missing" "$(j "$B" '.claims[2].verdict')" "INCONCLUSIVE"

# ── §7 hygiene: file content is DATA, never shell ───────────────────────────
B="$T/h1"; mkdir -p "$B"
HOSTILE='$(touch '"$T"'/PWNED)'
{ printf '## Acceptance tests\n'
  printf -- '- the gate demotes `%s` | and `%s` too\n' "$HOSTILE" '`touch '"$T"'/PWNED2`'
  printf -- '- the reader prints \007\010 control bytes\n'
} > "$B/plan.md"
printf 'CLAIM 1: REFUTED :: %s :: %s\n' "$HOSTILE" "$HOSTILE" > "$B/evidence-proposed.txt"
score "$B" "$B/plan.md"
eq "§7 the scorer returns 0 on hostile text" "$SRC" "0"
[ ! -e "$T/PWNED" ] && ok || bad "§7 a claim carrying \$(…) reached a shell"
[ ! -e "$T/PWNED2" ] && ok || bad "§7 a claim carrying a backtick reached a shell"
jq -e . "$B/evidence.json" >/dev/null 2>&1 && ok \
  || bad "§7 evidence.json must parse: [$(cat "$B/evidence.json" 2>&1)]"
eq "§7 no pipe survives in the recorded claim text" \
  "$(jq -r '.claims[].claim' "$B/evidence.json" 2>/dev/null | grep -c '|')" "0"
eq "§7 no backtick survives either" \
  "$(jq -r '.claims[].claim' "$B/evidence.json" 2>/dev/null | grep -c '`')" "0"
evidence_note "$B" > "$T/h1-note.txt"
eq "§7 evidence_note reprints the hostile note as data" \
  "$(grep -c 'touch' "$T/h1-note.txt")" "1"
[ ! -e "$T/PWNED" ] && ok || bad "§7 evidence_note expanded a substitution"
[ -s "$LIB" ] && ok || bad "§7 bin/lib/evidence.sh must exist and be non-empty"
grep -qE 'claude|codex|anthropic|http' "$LIB" \
  && bad "§7 the lib must name no model vendor and reach no network" || ok

# ── §8 fail-open: a plan it cannot read is never a score ────────────────────
B="$T/f1"; mkdir -p "$B"
printf '{"total":7,"confirmed":7,"refuted":0,"inconclusive":0,"claims":[]}\n' > "$B/evidence.json"
BEFORE=$(cat "$B/evidence.json")
score "$B" "$T/nosuchplan.md"
eq "§8 an unreadable plan returns 1" "$SRC" "1"
eq "§8 an unreadable plan prints exactly one could-not-run line" "$SOUT" \
  "EVIDENCE VERDICTS: could not run (plan unreadable)"
eq "§8 the previous evidence.json is untouched" "$(cat "$B/evidence.json")" "$BEFORE"
eq "§8 and no temp file is left behind" "$(tmpleft "$B")" "0"

echo "evidence-verdicts: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
