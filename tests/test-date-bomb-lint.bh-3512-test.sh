#!/bin/bash
# tests/test-date-bomb-lint.bh-3512-test.sh — bin/test-date-bomb-lint.sh driven
# over hermetic `git init` repos.
#
#   THE PROPERTY UNDER TEST: an added test-file line that puts a hard-coded ISO
#   date on a deadline-shaped key (the #3414 shape: next_recheck_at pinned to a
#   day that later arrived) is reported with its real path and line, rc 1. It is
#   quiet when the date is far future, deliberately in the past, fed to the
#   code as its clock, waived with a reason, or the file pins the clock. Diff
#   mode judges added lines only; --all judges every line.
#
# Every bomb date below is built from parts, so neither this lint (in diff mode
# over the PR that adds this suite) nor bin/test-determinism-lint.sh sees a
# literal date on a deadline key in this file.
# Run from anywhere: tests/test-date-bomb-lint.bh-3512-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LINT="$DIR/bin/test-date-bomb-lint.sh"
CONF="$DIR/catalog/date-bomb-lint.conf"
DCONF="$DIR/catalog/determinism-lint.conf"
mkdir -p "$T/h/flags"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

Y=2026
BOMB="$Y-09-29T10:00:00Z"
SAFE="20""99-01-01T00:00:00Z"
OLD="20""20-01-01T00:00:00Z"
SOON="$Y-10-01T00:00:00Z"

# run [args...] -> combined output in $OUT, rc in $RC. HARNESS points at scratch
# so no box-local flags/ conf can leak in.
run() {
  OUT=$(HARNESS="$T/h" DATE_BOMB_LINT_CONF="${RUN_CONF:-$CONF}" DETERMINISM_LINT_CONF="$DCONF" \
        bash "${RUN_LINT:-$LINT}" "$@" 2>&1); RC=$?
}
G() { git -C "$T/r" -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false "$@"; }
# repo [base-line] — fresh repo, tests/a-test.sh with one line, branch `base`.
repo() {
  rm -rf "$T/r"; git init -q "$T/r" || exit 1
  mkdir -p "$T/r/tests"
  printf '%s\n' "${1:-echo base}" > "$T/r/tests/a-test.sh"
  G add -A && G commit -qm base && G branch base
}
commit() { G add -A && G commit -qm added; }
fline() { printf '%s\n' "$2" >> "$T/r/$1"; }
# findings <text> — count of fixture-timebomb lines
findings() { grep -c 'fixture-timebomb' <<<"$1"; }

# ── D1: the #3414 shape is reported at its real line ────────────────────────
repo; fline tests/a-test.sh "  next_recheck_at:\"$BOMB\","; commit
run --base base "$T/r"
[ "$RC" -eq 1 ] && ok || bad "D1 rc $RC (want 1): $OUT"
grep -qE "^tests/a-test\.sh:2: fixture-timebomb: next_recheck_at is a hard-coded $Y-09-29, it expires against the real clock; use a year >= 2099" <<<"$OUT" \
  && ok || bad "D1 output lacks the finding at tests/a-test.sh:2: $OUT"

# ── D2: far-future date is safe ─────────────────────────────────────────────
repo; fline tests/a-test.sh "  next_recheck_at:\"$SAFE\","; commit
run --base base "$T/r"
[ "$RC" -eq 0 ] && ok || bad "D2 rc $RC (want 0): $OUT"
[ -z "$OUT" ] && ok || bad "D2 output not empty: $OUT"

# ── M: mutation — max_safe_year 2100 makes D2's date a bomb ─────────────────
sed 's/^opt max_safe_year .*/opt max_safe_year 2100/' "$CONF" > "$T/mut.conf"
[ "$(grep -c '^opt max_safe_year 2100' "$T/mut.conf")" = 1 ] && ok || bad "M sed changed no line"
RUN_CONF="$T/mut.conf" run --base base "$T/r"
[ "$RC" -eq 1 ] && ok || bad "M max_safe_year 2100 rc $RC (want 1): $OUT"

# ── D3a: the file pins the clock at HEAD ────────────────────────────────────
repo; fline tests/a-test.sh 'NOW=1790000000'; fline tests/a-test.sh "  next_recheck_at:\"$BOMB\","; commit
run --base base "$T/r"
[ "$RC" -eq 0 ] && ok || bad "D3a pinned file rc $RC (want 0): $OUT"
# ── D3b: the date is the code's clock input ─────────────────────────────────
repo; fline tests/a-test.sh "triage_state_list due --now $BOMB"; commit
run --base base "$T/r"
[ "$RC" -eq 0 ] && ok || bad "D3b --now input rc $RC (want 0): $OUT"
# D3c: the same, with a deadline key on the line, so only input_re quiets it
repo; fline tests/a-test.sh "out=\$(triage_state_list due --now \"$BOMB\" next_recheck_at=\"$BOMB\")"; commit
run --base base "$T/r"
[ "$RC" -eq 0 ] && ok || bad "D3c --now input with a deadline key rc $RC (want 0): $OUT"

# ── D4: a deliberate "already due" date ─────────────────────────────────────
repo; fline tests/a-test.sh "  next_recheck_at:\"$OLD\","; commit
run --base base "$T/r"
[ "$RC" -eq 0 ] && ok || bad "D4 pre-floor date rc $RC (want 0): $OUT"
# D4b: the floor boundary — floor_year itself is a bomb, the year before is not
repo; fline tests/a-test.sh "  next_recheck_at:\"20""25-01-01T00:00:00Z\","; fline tests/a-test.sh "  next_a:\"20""24-12-31T00:00:00Z\","; commit
run --base base "$T/r"
[ "$RC" -eq 1 ] && ok || bad "D4b floor year rc $RC (want 1): $OUT"
[ "$(findings "$OUT")" = 1 ] && grep -qE '^tests/a-test\.sh:2: fixture-timebomb: next_recheck_at ' <<<"$OUT" \
  && ok || bad "D4b want exactly the floor-year line flagged: $OUT"

# ── D5: waivers ─────────────────────────────────────────────────────────────
repo; fline tests/a-test.sh "  next_recheck_at:\"$BOMB\", # determinism: ok frozen payload, never compared"; commit
run --base base "$T/r"
[ "$RC" -eq 0 ] && ok || bad "D5a reasoned waiver rc $RC (want 0): $OUT"
repo; fline tests/a-test.sh "  next_recheck_at:\"$BOMB\", # determinism: ok"; commit
run --base base "$T/r"
[ "$RC" -eq 1 ] && ok || bad "D5b reasonless waiver rc $RC (want 1): $OUT"
repo; fline tests/a-test.sh "  next_recheck_at:\"$BOMB\", // determinism: ok ab"; commit
run --base base "$T/r"
[ "$RC" -eq 1 ] && ok || bad "D5c 2-char reason rc $RC (want 1): $OUT"

# ── D6: a JS test file, then the same file with fake timers ─────────────────
repo; mkdir -p "$T/r/worker/jobs/test"; fline worker/jobs/test/b.test.js "  expires_at: '$SOON',"; commit
run --base base "$T/r"
[ "$RC" -eq 1 ] && ok || bad "D6a rc $RC (want 1): $OUT"
grep -qE '^worker/jobs/test/b\.test\.js:1: fixture-timebomb: expires_at ' <<<"$OUT" && ok || bad "D6a output lacks b.test.js expires_at: $OUT"
FT="vi.use""FakeTimers();"
repo; mkdir -p "$T/r/worker/jobs/test"; fline worker/jobs/test/b.test.js "$FT"; fline worker/jobs/test/b.test.js "  expires_at: '$SOON',"; commit
run --base base "$T/r"
[ "$RC" -eq 0 ] && ok || bad "D6b fake timers rc $RC (want 0): $OUT"

# ── D7: a pre-existing bomb is silent in diff mode, loud under --all ────────
repo "  next_recheck_at:\"$BOMB\","; fline tests/a-test.sh 'echo hi'; commit
run --base base "$T/r"
[ "$RC" -eq 0 ] && ok || bad "D7 diff mode rc $RC (want 0): $OUT"
run --all "$T/r"
[ "$RC" -eq 1 ] && ok || bad "D7 --all rc $RC (want 1): $OUT"
grep -qE '^tests/a-test\.sh:1: fixture-timebomb: next_recheck_at ' <<<"$OUT" && ok || bad "D7 --all lacks the pre-existing line: $OUT"

# ── D8: the real #3414 line, from history ───────────────────────────────────
if git -C "$DIR" cat-file -e '35657019b^:tests/triage-state-client-test.sh' 2>/dev/null; then
  SRC=$(git -C "$DIR" show '35657019b^:tests/triage-state-client-test.sh')
  REAL=$(grep -m1 'next_recheck_at:"20' <<<"$SRC")
  repo; mkdir -p "$T/r/tests"; fline tests/c-test.sh "$REAL"; commit
  run --base base "$T/r"
  [ "$RC" -eq 1 ] && ok || bad "D8 real #3414 line rc $RC (want 1): $OUT"
  grep -qE '^tests/c-test\.sh:1: fixture-timebomb: next_recheck_at ' <<<"$OUT" && ok || bad "D8 output lacks next_recheck_at: $OUT"
else
  echo "SKIP D8: 35657019b not reachable (shallow clone)"
fi

# ── D9: rc 2 on bad args, no conf, no base, no repo ─────────────────────────
repo
run --bogus "$T/r"
[ "$RC" -eq 2 ] && ok || bad "D9a --bogus rc $RC (want 2): $OUT"
run --base
[ "$RC" -eq 2 ] && ok || bad "D9b --base with no value rc $RC (want 2): $OUT"
run --base no-such-ref "$T/r"
[ "$RC" -eq 2 ] && ok || bad "D9c unresolvable base rc $RC (want 2): $OUT"
grep -q 'cannot resolve base no-such-ref' <<<"$OUT" && ok || bad "D9c message does not name the ref: $OUT"
mkdir -p "$T/copy/bin"; cp "$LINT" "$T/copy/bin/" 2>/dev/null
RUN_LINT="$T/copy/bin/test-date-bomb-lint.sh" RUN_CONF="$T/missing" run --base base "$T/r"
[ "$RC" -eq 2 ] && ok || bad "D9d no conf rc $RC (want 2): $OUT"
grep -q 'no conf found' <<<"$OUT" && ok || bad "D9d message does not say no conf: $OUT"
mkdir -p "$T/notgit/tests"
run --base base "$T/notgit"
[ "$RC" -eq 2 ] && ok || bad "D9e non-git root rc $RC (want 2): $OUT"

# ── D10: each date on a line is judged on its own ───────────────────────────
repo; fline tests/a-test.sh "  next_a:\"$SAFE\", valid_to:\"$BOMB\","; commit
run --base base "$T/r"
[ "$RC" -eq 1 ] && ok || bad "D10 rc $RC (want 1): $OUT"
[ "$(findings "$OUT")" = 1 ] && ok || bad "D10 want exactly one finding: $OUT"
grep -qE 'fixture-timebomb: valid_to is a hard-coded' <<<"$OUT" && ok || bad "D10 finding does not name valid_to: $OUT"

echo "test-date-bomb-lint.bh-3512: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
