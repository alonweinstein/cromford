#!/bin/bash
# tests/fast-lints-data.bh-3860-test.sh — the committed data bin/fast-lints.sh
# joins (BH-3860.3 / BH-3864): catalog/test-impact-always.txt, read from this
# repo as it is, and the suite durations file.
#
# THE DURATIONS FILE IS NOT COMMITTED (BH-5518 C1). CI composes it from its own
# runs (bin/ci-durations.sh, docs/ci-durations.md). D0, D1, D2 and D4 read
# FLD_DURATIONS, else FAST_LINTS_DURATIONS, else catalog/ci-suite-durations.tsv.
# When none of them is readable they SKIP and count no failure, so a missing
# row can no longer turn a merge-queue batch red. With a readable file, D0 is
# still red on a malformed row, and D1 warns on an unmeasured always-suite
# (BH-5292).
#
# HARNESS points at an empty tree so no live settings row reaches a knob.
#   A7a  bin/test-impact.sh always lists tests/gh-app-ratchet-test.sh
#   A7b  the always file names it on a non-comment line, with a comment reason
#   D0   every non-comment row of the durations file is well-formed:
#        <tests/...>\t<seconds>\t<run id>[\t<v1,v2,v3>]. A malformed row FAILS (BH-5292 kept
#        this hard: it is a broken file, not a missing measurement)
#   D1   every always-suite has a numeric durations row. A missing one is a
#        WARNING (BH-5292), named with the line that put it in the set
#        (BH-4551's hint): bin/fast-lints.sh --list and the shard split weigh
#        it at the file's median until a refresh measures it
#   D2   bin/fast-lints.sh --list: rc 0, the summary line, and stdout has
#        tests/gh-rest-no-subshell-lint.sh when the file measures it under the
#        cap (BH-5653). "unmeasured: <list>" is a WARNING
#   D4   bin/fast-lints.sh --list stdout has tests/gh-app-ratchet-test.sh (the
#        refresh measured it under the 10 s default)
#
# FLD_ROOT / FLD_DURATIONS point D0 and D1 at a scratch tree and durations
# file (tests/test-impact-always-re.bh-4551-test.sh F9 and
# tests/gates-to-reports.bh-5292-test.sh R1 drive them that way). A7 always reads
# this repo's own always set: it pins a fact about this repo.
#
# WHY WARNINGS (BH-5292, the operator 2026-10-07). A missing or stale timing row is not
# itself harmful: the split already weighs an unmeasured suite at the median. As
# a red it ejected every merge-queue batch from 12:08 to about 18:30Z on
# 2026-10-07 (fixed by #5256). Gates vs reports: docs/GATES-VS-REPORTS.md.
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REAL="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
WARN=0
warn() { WARN=$((WARN + 1)); echo "  WARN $1"; }

mkdir -p "$T/h"
export HARNESS="$T/h"
DUR="${FLD_DURATIONS:-${FAST_LINTS_DURATIONS:-$REAL/catalog/ci-suite-durations.tsv}}"
unset FAST_LINTS_MAX_S FAST_LINTS_BUDGET_S FAST_LINTS_DURATIONS PROJECT

ALWAYS_TXT="$REAL/catalog/test-impact-always.txt"
TI_ROOT="${FLD_ROOT:-$REAL}"
RATCHET=tests/gh-app-ratchet-test.sh

"$REAL/bin/test-impact.sh" --root "$TI_ROOT" always > "$T/always" 2> "$T/always.err"
RC=$?
[ "$RC" = 0 ] && [ -s "$T/always" ] && ok "always set readable" || bad "always rc=$RC err=$(cat "$T/always.err")"

echo "A7: the gh-app ratchet is always-run"
if [ "$TI_ROOT" = "$REAL" ]; then cp "$T/always" "$T/always-real"
else "$REAL/bin/test-impact.sh" --root "$REAL" always > "$T/always-real" 2>/dev/null; fi
grep -qxF "$RATCHET" "$T/always-real" && ok "A7a always lists $RATCHET" || bad "A7a $RATCHET not in the always set"
awk -v s="$RATCHET" '!/^[[:space:]]*#/ && $1 == s {f = 1} END {exit !f}' "$ALWAYS_TXT" \
  && ok "A7b non-comment line names $RATCHET" || bad "A7b no non-comment line for $RATCHET"
grep -E '^[[:space:]]*#.*gh-app-ratchet' "$ALWAYS_TXT" > /dev/null \
  && ok "A7b a comment gives the reason" || bad "A7b no reason comment names gh-app-ratchet"

if [ ! -r "$DUR" ]; then
  echo "SKIP D1-D4: no durations file (CI composes it; bin/ci-durations.sh fetch renders it locally)"
  echo "PASS=$PASS FAIL=$FAIL"
  [ "$FAIL" = 0 ]; exit
fi

echo "D0: every durations row is well-formed"
malformed=$(awk -F'\t' '/^[[:space:]]*(#|$)/ { next }
  (NF != 3 && NF != 4) || $1 !~ /^tests\// || $2 !~ /^[0-9]+(\.[0-9]+)?$/ || $3 !~ /^[0-9]+$/ ||
  (NF == 4 && $4 !~ /^[0-9]+(\.[0-9]+)?(,[0-9]+(\.[0-9]+)?)*$/) { printf " line %d", NR }' "$DUR")
[ -z "$malformed" ] && ok "D0 every row is <suite>, seconds, run id[, values]" \
  || bad "D0 malformed durations row(s) in $DUR:$malformed (want tests/<suite>, seconds, run id[, v1,v2,v3], tab-separated)"

echo "D1: every always-suite has a numeric durations row (missing: a warning)"
miss=""
while IFS= read -r s; do
  awk -F'\t' -v s="$s" '$1 == s && $2 ~ /^[0-9]+(\.[0-9]+)?$/ {f = 1} END {exit !f}' "$DUR" || miss="$miss $s"
done < "$T/always"
[ -z "$miss" ] && ok "D1 all $(wc -l < "$T/always") always-suites measured" \
  || warn "D1 no durations row (weighed at the file's median until measured):$miss"
if [ -n "$miss" ]; then
  "$REAL/bin/test-impact.sh" --root "$TI_ROOT" always-why > "$T/always-why" 2>&1
  for s in $miss; do
    src=$(awk -F'\t' -v s="$s" '$1 == s {print $2; exit}' "$T/always-why")
    echo "  D1 hint: $s is always-run via ${src:-<always-why gave no row>}; add a durations row or stop matching"
  done
fi

echo "D2: fast-lints --list on that durations file"
FAST_LINTS_DURATIONS="$DUR" HARNESS_TEST_SANDBOX=1 "$REAL/bin/fast-lints.sh" --list > "$T/fl.out" 2> "$T/fl.err"
RC=$?
[ "$RC" = 0 ] && ok "D2 rc 0" || bad "D2 rc=$RC err=$(cat "$T/fl.err")"
grep -qE '^fast-lints: [0-9]+ of [0-9]+ always-suites at <=[0-9.]+s; unmeasured: .+; over: [0-9]+$' "$T/fl.err" \
  && ok "D2 stderr carries the summary line" || bad "D2 stderr=$(cat "$T/fl.err")"
grep -qE '; unmeasured: none; ' "$T/fl.err" || warn "D2 $(grep -oE 'unmeasured: [^;]*' "$T/fl.err")"
# measured_fast <suite>: the durations file measures it at or under the 10 s
# default cap. D2 and D4 pin that a MEASURED fast suite makes the fast set; a
# suite the file does not measure (a scratch FLD_DURATIONS, BH-5653's MR1)
# weighs the median and runs in the batch, which is not a failure (BH-5292).
measured_fast() {
  awk -F'\t' -v s="$1" '!/^[[:space:]]*#/ && $1 == s { v = $2 }
    END { exit !(v ~ /^[0-9]+(\.[0-9]+)?$/ && v + 0 <= 10) }' "$DUR"
}
if measured_fast tests/gh-rest-no-subshell-lint.sh; then
  grep -qxF tests/gh-rest-no-subshell-lint.sh "$T/fl.out" \
    && ok "D2 stdout has tests/gh-rest-no-subshell-lint.sh" || bad "D2 stdout lacks gh-rest-no-subshell-lint: $(tr '\n' ' ' < "$T/fl.out")"
else
  echo "  D2 note: the file does not measure tests/gh-rest-no-subshell-lint.sh under 10 s, so it runs in the batch"
fi

echo "D4: the gh-app ratchet made the fast set"
if measured_fast "$RATCHET"; then
  grep -qxF "$RATCHET" "$T/fl.out" \
    && ok "D4 fast-lints --list stdout has $RATCHET" || bad "D4 $RATCHET not in --list stdout: $(cat "$T/fl.err")"
else
  echo "  D4 note: the file does not measure $RATCHET under 10 s, so it runs in the batch"
fi

echo "PASS=$PASS FAIL=$FAIL WARN=$WARN"
[ "$FAIL" = 0 ]
