#!/bin/bash
# tests/sql-command-injection-allowlist.bh-4501-test.sh — BH-4501: the
# sql-command-injection check stops parking constant-only and ?N-placeholder
# interpolations, and keeps every true positive.
#
# Every assertion goes through bin/checks-run.sh, the runner bin/merge-sweep.sh
# and bin/run-build.sh call, over the committed fixtures in
# checks/sql-command-injection/fixtures/:
#   1. green-*.diff, one per accepted shape (a)-(d): no hit, no CHECK-ERROR,
#      and the pre-BH-4501 check DID hit each one (the fixture carries the shape).
#   2. red-*.diff, the near misses: rc 1 and a hit on the exact expected line.
#   3. replay-*.diff, the parked PRs #4044/#4142/#4232: zero hits now, and the
#      pre-BH-4501 check gives 1/1/3 on them.
#   4. violation.diff still gives its 3 hits.
#   5. whole-file-0ad5fe5-worker.diff (every file of main@0ad5fe5 whose hits
#      changed, all lines added): the new hits are a subset of the old ones and
#      the removed set is exactly the hand-read list below. Plus the same subset
#      check over the live worker/ tree, built from disk (no git needed).
# The pre-BH-4501 check is the frozen copy fixtures/pre-bh4501-check.sh.txt
# (byte-identical to main@0ad5fe5), so this suite still means something after
# the change lands on main.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
RUN="$DIR/bin/checks-run.sh"
S=sql-command-injection
FX="$DIR/checks/$S/fixtures"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The old check, alone in its own catalog.
mkdir -p "$T/old/$S"
cp "$DIR/checks/$S/fixtures/pre-bh4501-check.sh.txt" "$T/old/$S/check.sh" && chmod +x "$T/old/$S/check.sh" \
  && ok || bad "could not stage the pre-BH-4501 check"
oldrun() { CHECKS_DIR="$T/old" "$RUN" "$@"; }
nhits()  { grep -c "^CHECK-HIT $S " <<<"$1"; }
locs()   { grep "^CHECK-HIT $S " <<<"$1" | awk '{print $3}' | sort; }

# ── 1. green: one fixture per accepted shape ────────────────────────────────
NG=0
for F in "$FX"/green-*.diff; do
  [ -f "$F" ] || continue
  NG=$((NG+1)); B=$(basename "$F")
  OUT=$("$RUN" "$F" 2>&1)
  [ "$(nhits "$OUT")" = 0 ] && ok || bad "$B: still flagged: $(grep "^CHECK-HIT $S " <<<"$OUT" | head -3)"
  grep -q '^CHECK-ERROR' <<<"$OUT" && bad "$B: CHECK-ERROR: $OUT" || ok
  grep -qE '^CHECKS: clean \([0-9]+ check\(s\), [1-9][0-9]* added line' <<<"$OUT" \
    && ok || bad "$B: runner did not report a clean scan of added lines: $(tail -1 <<<"$OUT")"
  OLD=$(oldrun "$F" 2>&1)
  [ "$(nhits "$OLD")" -ge 1 ] && ok || bad "$B: the pre-BH-4501 check never flagged it, so it proves nothing"
done
[ "$NG" = 4 ] && ok || bad "expected 4 green fixtures (a)-(d), found $NG"

# ── 2. red: near misses still flag, on the exact line ───────────────────────
# fixture | expected hit lines (space separated)
RED="red-req-query 2
red-body-table 2
red-cols-from-input 3
red-placeholder-nonnumeric 2
red-placeholder-body-length 2
red-tainted-push 4
red-shadowed-const 4
red-param-shadow 3
red-ternary-tainted 2 3
red-concat-tainted 2
red-nested-template-tainted 2
red-reassigned-array 4
red-local-const 3
red-second-interp-tainted 3
red-context-only-const 3
red-array-context-gap 4
red-push-multi-arg 4
red-const-array-push 6
red-const-array-index-assign 4
red-const-array-splice 4
red-class-method-param 4
red-object-method-param 4"
NR_=0
while read -r NAME LINES; do
  NR_=$((NR_+1))
  F="$FX/$NAME.diff"
  [ -f "$F" ] || { bad "$NAME.diff missing"; continue; }
  OUT=$("$RUN" "$F" 2>&1); RC=$?
  [ "$RC" = 1 ] && ok || bad "$NAME: rc $RC, expected 1"
  WANT=$(for L in $LINES; do echo "worker/jobs/src/routes/r.js:$L"; done | sort)
  [ "$(locs "$OUT")" = "$WANT" ] && ok || bad "$NAME: hits [$(locs "$OUT" | tr '\n' ' ')] expected [$(tr '\n' ' ' <<<"$WANT")]"
done <<<"$RED"
NF=$(ls "$FX"/red-*.diff | wc -l | tr -d ' ')
[ "$NF" = "$NR_" ] && ok || bad "$NF red-*.diff fixtures but $NR_ in this test's table"

# ── 3. replays of the three parked PRs ──────────────────────────────────────
for P in "replay-4044-usage 1" "replay-4142-initiatives 1" "replay-4232-lead-protected-paths 3"; do
  set -- $P
  OUT=$("$RUN" "$FX/$1.diff" 2>&1)
  [ "$(nhits "$OUT")" = 0 ] && ok || bad "$1: still flagged: $(locs "$OUT" | tr '\n' ' ')"
  grep -q '^CHECK-ERROR' <<<"$OUT" && bad "$1: CHECK-ERROR" || ok
  OLD=$(oldrun "$FX/$1.diff" 2>&1)
  [ "$(nhits "$OLD")" = "$2" ] && ok || bad "$1: pre-BH-4501 check gave $(nhits "$OLD") hit(s), expected $2"
done

# ── 4. the seeded violation keeps all 3 ─────────────────────────────────────
OUT=$("$RUN" "$DIR/checks/$S/fixtures/violation.diff" 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "violation.diff: rc $RC"
[ "$(nhits "$OUT")" = 3 ] && ok || bad "violation.diff: $(nhits "$OUT") hit(s), expected 3"

# ── 5. whole files: true positives kept, removals exactly the safe ones ─────
REMOVED="worker/jobs/src/routes/alert-actions.js:50
worker/jobs/src/routes/alert-actions.js:76
worker/jobs/src/routes/alert-family-scripts.js:77
worker/jobs/src/routes/alert-family-scripts.js:91
worker/jobs/src/routes/alert-family-scripts.js:96
worker/jobs/src/routes/cost-live.js:163
worker/jobs/src/routes/cost.js:131
worker/jobs/src/routes/dequeue-watch.js:214
worker/jobs/src/routes/dequeue-watch.js:252
worker/jobs/src/routes/dequeue-watch.js:281
worker/jobs/src/routes/dequeue-watch.js:308
worker/jobs/src/routes/flakes.js:146
worker/jobs/src/routes/flakes.js:68
worker/jobs/src/routes/reconcile-memory.js:74
worker/jobs/src/routes/reconcile-owner.js:31
worker/jobs/src/routes/reconcile-owner.js:71
worker/jobs/src/routes/usage.js:72"
W="$FX/whole-file-0ad5fe5-worker.diff"
locs "$(oldrun "$W" 2>&1)" > "$T/old.hits"
locs "$("$RUN" "$W" 2>&1)" > "$T/new.hits"
[ "$(wc -l < "$T/old.hits")" -ge 30 ] && ok || bad "whole-file: old check found only $(wc -l < "$T/old.hits") hits"
ADDED=$(comm -13 "$T/old.hits" "$T/new.hits")
[ -z "$ADDED" ] && ok || bad "whole-file: new hits the old check never had: $ADDED"
[ "$(comm -23 "$T/old.hits" "$T/new.hits")" = "$(sort <<<"$REMOVED")" ] && ok \
  || bad "whole-file: removed set differs: $(diff <(comm -23 "$T/old.hits" "$T/new.hits") <(sort <<<"$REMOVED") | tr '\n' ' ')"
for L in 149 175 181 394; do
  F=usage.js; [ "$L" -gt 300 ] && F=cost.js
  grep -qx "worker/jobs/src/routes/$F:$L" "$T/new.hits" && ok || bad "whole-file: lost true-positive-shaped hit $F:$L"
done

# Live tree, built from disk: every worker/ source file as an all-added diff.
( cd "$DIR" && find worker -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.ts' \) -not -path '*/node_modules/*' | sort ) \
  | while read -r F; do
      printf 'diff --git a/%s b/%s\n--- /dev/null\n+++ b/%s\n@@ -0,0 +1 @@\n' "$F" "$F" "$F"
      sed 's/^/+/' "$DIR/$F"
    done > "$T/live.diff"
locs "$(oldrun "$T/live.diff" 2>&1)" > "$T/live-old.hits"
NEWOUT=$("$RUN" "$T/live.diff" 2>&1)
grep -q '^CHECK-ERROR' <<<"$NEWOUT" && bad "live tree: CHECK-ERROR: $(grep '^CHECK-ERROR' <<<"$NEWOUT")" || ok
locs "$NEWOUT" > "$T/live-new.hits"
[ "$(wc -l < "$T/live-old.hits")" -ge 30 ] && ok || bad "live tree: old check found only $(wc -l < "$T/live-old.hits") hits"
LADDED=$(comm -13 "$T/live-old.hits" "$T/live-new.hits")
[ -z "$LADDED" ] && ok || bad "live tree: new hits the old check never had: $LADDED"

echo "sql-command-injection-allowlist (BH-4501): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
