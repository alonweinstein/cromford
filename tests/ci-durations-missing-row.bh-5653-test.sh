#!/bin/bash
# tests/ci-durations-missing-row.bh-5653-test.sh — a suite with no durations row
# gets the default weight and never fails the gate (BH-5653, the #5256 case).
#
#   MR1 a scratch root with a new always-run suite and a durations file that
#       has no row for it -> tests/fast-lints-data.bh-3860-test.sh rc 0, and it
#       still prints the D1 hint naming the line that made the suite always-run
#   MR2 suite_shard_plan 3 with that suite absent from the file -> it weighs
#       exactly the file's median, and every suite is placed exactly once
#   MR3 the same through bin/ci-durations.sh fetch from the REAL worker
#       (tests/lib/ci-durations-worker.bh-5653.mjs) whose rows lack it -> the
#       median of the fetched file
#   MR4 MUTATION (D11): a row that EXISTS for an always-suite but is not a
#       number still turns fast-lints-data red — unparseable is not absent
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
FLD="$DIR/tests/fast-lints-data.bh-3860-test.sh"
CDS="$DIR/bin/ci-durations.sh"
SRV="$DIR/tests/lib/ci-durations-worker.bh-5653.mjs"
PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
unset SUITE_DURATIONS_FILE FAST_LINTS_DURATIONS FLD_DURATIONS FLD_ROOT CI_DURATIONS_TOKEN HARNESS_SECRET
mkdir -p "$T/h"
export HARNESS="$T/h" CI_DURATIONS_CACHE="$T/cache/api.tsv" CI_DURATIONS_GH="$T/no-gh"

# A scratch root: one always-run suite (it reads the whole tree with git
# ls-files, BH-4551's detector) and two ordinary ones.
R="$T/root"
mkdir -p "$R/tests" "$R/catalog"
: > "$R/catalog/test-impact-always.txt"
printf '%s\n' 'git -C "$DIR" ls-files | wc -l' > "$R/tests/brand-new-test.sh"
printf '%s\n' 'echo one' > "$R/tests/old-one-test.sh"
printf '%s\n' 'echo two' > "$R/tests/old-two-test.sh"
DUR="$T/dur.tsv"
printf '# fixture durations, no row for tests/brand-new-test.sh\ntests/old-one-test.sh\t10\t1\ntests/old-two-test.sh\t30\t1\ntests/other-test.sh\t50\t1\n' > "$DUR"

echo "MR1: the gate passes on an always-suite with no row"
FLD_ROOT="$R" FLD_DURATIONS="$DUR" HARNESS_TEST_SANDBOX=1 bash "$FLD" > "$T/mr1.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "MR1 fast-lints-data rc 0" || bad "MR1 rc=$rc $(grep FAIL "$T/mr1.out" | head -5)"
grep -qF 'D1 hint: tests/brand-new-test.sh is always-run via tests/brand-new-test.sh:1: git -C "$DIR" ls-files | wc -l' "$T/mr1.out" \
  && ok "MR1 the D1 hint still names the matched line" || bad "MR1 no hint: $(grep D1 "$T/mr1.out")"
grep -q '^  FAIL ' "$T/mr1.out" && bad "MR1 a FAIL line: $(grep '^  FAIL ' "$T/mr1.out" | head -3)" || ok "MR1 no FAIL line"

echo "MR2: suite_shard_plan weighs it at the median"
plan() { ( . "$DIR/bin/lib/suite-runner.sh" || exit 1; SUITE_DURATIONS_FILE="$1" suite_shard_plan 3 "${@:2}" ); }
plan "$DUR" "$R"/tests/*.sh > "$T/mr2.plan"
# file seconds 10, 30, 50 -> median 30 s -> 30000 ms
awk -F'\t' '$3 ~ /brand-new-test.sh$/ {print $2}' "$T/mr2.plan" | grep -qx 30000 \
  && ok "MR2 brand-new weighs the median (30000 ms)" || bad "MR2 plan: $(cat "$T/mr2.plan")"
[ "$(cut -f3 "$T/mr2.plan" | sort | uniq -d | wc -l)" = 0 ] && [ "$(grep -c . "$T/mr2.plan")" = 3 ] \
  && ok "MR2 every suite placed exactly once" || bad "MR2 placement: $(cat "$T/mr2.plan")"

echo "MR3: the same through fetch from the worker"
command -v node >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && SRVOK=1 || SRVOK=0
if [ "$SRVOK" = 1 ]; then
  : > "$T/w.log"
  node "$SRV" worker "$T/w.log" > "$T/w.port" 2> "$T/w.err" &
  WPID=$!
  for _ in $(seq 1 100); do [ -s "$T/w.port" ] && break; kill -0 "$WPID" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/w.port")
fi
if [ "$SRVOK" = 0 ] || [ -z "${PORT:-}" ]; then
  echo "SKIP MR3: no node, or node:sqlite unavailable"
else
  printf '{"run_id":5,"rows":[{"suite":"tests/old-one-test.sh","seconds":10},{"suite":"tests/old-two-test.sh","seconds":30},{"suite":"tests/other-test.sh","seconds":50}]}' \
    | curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'authorization: Bearer fixture-ci-token' \
        -H 'content-type: application/json' --data-binary @- "http://127.0.0.1:$PORT/api/ci/suite-durations" > "$T/mr3.code"
  [ "$(cat "$T/mr3.code")" = 200 ] && ok "MR3 the worker took three rows" || bad "MR3 POST $(cat "$T/mr3.code")"
  JOBS_URL="http://127.0.0.1:$PORT" CI_DURATIONS_TOKEN=fixture-ci-token "$CDS" fetch --out "$T/mr3.tsv" --root "$R" > "$T/mr3.out" 2>&1; rc=$?
  [ "$rc" = 0 ] && [ "$(head -1 "$T/mr3.tsv")" = "# source: api" ] && ok "MR3 fetch source=api" || bad "MR3 rc=$rc $(head -1 "$T/mr3.tsv") $(cat "$T/mr3.out")"
  plan "$T/mr3.tsv" "$R"/tests/*.sh > "$T/mr3.plan"
  cmp -s "$T/mr3.plan" "$T/mr2.plan" && ok "MR3 the plan from the worker equals the plan from the file" || bad "MR3 plans differ: $(diff "$T/mr2.plan" "$T/mr3.plan")"
  kill "$WPID" 2>/dev/null
fi

echo "MR4: MUTATION — a non-numeric row is still red"
printf 'tests/brand-new-test.sh\tn/a\t1\n' >> "$DUR"
FLD_ROOT="$R" FLD_DURATIONS="$DUR" HARNESS_TEST_SANDBOX=1 bash "$FLD" > "$T/mr4.out" 2>&1; rc=$?
[ "$rc" != 0 ] && ok "MR4 fast-lints-data is red on a non-numeric row" || bad "MR4 rc=0 with a non-numeric row"
# TEST-CHANGE (main merge): main's fast-lints-data (BH-5292) owns this case as
# D0, "malformed durations row(s) … line N". The behaviour pinned is the same:
# a row that exists and is not a number is red, and the failure names its row
# (line 5 of the fixture: the comment, three rows, then this one).
grep -q 'FAIL D0 malformed durations row(s) in .* line 5' "$T/mr4.out" && ok "MR4 the FAIL names the row" || bad "MR4 out: $(grep -E 'D0|D1' "$T/mr4.out")"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
