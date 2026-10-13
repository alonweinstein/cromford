#!/bin/bash
# tests/flaky-parse-harness.bh-3686-test.sh — flaky_parse_tests names cromford suites.
#
# WHAT IS UNDER TEST (BH-3700, split child 3 of BH-3686). The harness CI runner
# (bin/test-trace-safety.sh --gate) prints "--- tests/x-test.sh rc=<rc> <secs>s"
# for every suite. Before this slice flaky_parse_tests knew only vitest/jest, so
# every cromford red became "job:<shard>" in ci_flakes, which can never be
# quarantined. Pinned here:
#   P1  a --log-failed-shaped line with nonzero rc names the suite
#   P2  rc=0, HIT trace lines and non-tests/ paths name nothing
#   P3  the vitest/jest fixtures parse byte-identically to the pre-BH-3700 pipeline
#   P4  mixed input gives runner names first, then suite names, each once
#   E   flaky_run_tests (the production entry) names the suite instead of job:<shard>
# Run from anywhere: tests/flaky-parse-harness.bh-3686-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# shellcheck source=bin/lib/flaky.sh
. "$DIR/bin/lib/flaky.sh" || { echo "FAIL: cannot source bin/lib/flaky.sh"; exit 1; }

# The vitest/jest pipeline exactly as it stood before BH-3700 (bin/lib/flaky.sh
# at 6d859d75), kept here as the reference P3 compares against.
old_parse() {
  sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z[[:space:]]*//' 2>/dev/null \
  | grep -aE '(×|✕|✗|●)[[:space:]]|(^|[[:space:]])FAIL[[:space:]]' \
  | sed -E 's/.*(×|✕|✗|●)[[:space:]]+//' \
  | sed -E 's/^[[:space:]]*FAIL[[:space:]]+[^[:space:]]+[[:space:]]+>[[:space:]]+//; s/^[[:space:]]*FAIL[[:space:]]+//' \
  | sed -E 's/[[:space:]]+[0-9]+(\.[0-9]+)?[mun]?s$//' \
  | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
  | tr -d '\t\r' \
  | grep -avE '^$|^Console$|^Test suite failed to run$|^Deprecation Warning' \
  | cut -c1-300 \
  | awk '!seen[$0]++'
}

# A real `gh run view --log-failed` line: job<TAB>step<TAB>7-digit-fraction stamp.
PFX=$'shard-2\tRun tests\t2026-09-30T01:02:03.4567890Z '

# ===========================================================================
# P1 — nonzero rc names the suite, through the --log-failed prefix
# ===========================================================================
got=$(printf '%s--- tests/a-test.sh rc=1 3s\n' "$PFX" | flaky_parse_tests)
[ "$got" = "tests/a-test.sh" ] && ok || bad "P1 rc=1 must name tests/a-test.sh, got [$got]"
got=$(printf '%s--- tests/a-test.sh rc=124 600s\n' "$PFX" | flaky_parse_tests)
[ "$got" = "tests/a-test.sh" ] && ok || bad "P1 rc=124 (timeout) must name the suite, got [$got]"
got=$(printf '%s--- tests/mc/classify-test.sh rc=1 12s\n' "$PFX" | flaky_parse_tests)
[ "$got" = "tests/mc/classify-test.sh" ] && ok || bad "P1 tests/mc/ path must be named whole, got [$got]"
got=$(printf '%s--- tests/a-test.sh rc=10 3s\n' "$PFX" | flaky_parse_tests)
[ "$got" = "tests/a-test.sh" ] && ok || bad "P1 multi-digit rc=10 must name the suite, got [$got]"

# ===========================================================================
# P2 — rc=0, HIT trace lines, non-tests/ paths: nothing
# ===========================================================================
got=$(printf '%s--- tests/a-test.sh rc=0 3s\n' "$PFX" | flaky_parse_tests)
[ -z "$got" ] && ok || bad "P2 rc=0 must name nothing, got [$got]"
got=$(printf '%s--- tests/a-test.sh rc=0 3s\n%s--- tests/b-test.sh rc=0 1s\n' "$PFX" "$PFX" | flaky_parse_tests)
[ -z "$got" ] && ok || bad "P2 a run of rc=0 lines must name nothing, got [$got]"
got=$(printf '%sHIT tests/a-test.sh bin/lib/flaky.sh:94 rc=1\n' "$PFX" | flaky_parse_tests)
[ -z "$got" ] && ok || bad "P2 a HIT trace line must name nothing, got [$got]"
got=$(printf '%s--- src/x.sh rc=1 3s\n' "$PFX" | flaky_parse_tests)
[ -z "$got" ] && ok || bad "P2 a path outside tests/ must name nothing, got [$got]"

# ===========================================================================
# P3 — the vitest and jest fixtures of tests/flaky-detect-test.sh, unchanged
# ===========================================================================
cat > "$T/vitest.txt" <<'L'
2026-09-12T01:02:03Z  FAIL  src/lib/queue.test.ts > queue > drains under load
2026-09-12T01:02:03Z    × queue > drains under load 42ms
2026-09-12T01:02:04Z    ✓ queue > accepts a job 2ms
L
cat > "$T/jest.txt" <<'L'
2026-09-12T01:02:03Z   ● Auth › rejects an expired token
2026-09-12T01:02:03Z   ● Auth › rejects an expired token
L
for f in vitest jest; do
  flaky_parse_tests < "$T/$f.txt" > "$T/$f.new"
  old_parse < "$T/$f.txt" > "$T/$f.old"
  cmp -s "$T/$f.new" "$T/$f.old" && ok || bad "P3 $f fixture must parse byte-identically to the old pipeline: new=[$(cat "$T/$f.new")] old=[$(cat "$T/$f.old")]"
done
[ "$(cat "$T/vitest.new")" = "queue > drains under load" ] && ok || bad "P3 vitest name, got [$(cat "$T/vitest.new")]"
[ "$(cat "$T/jest.new")" = "Auth › rejects an expired token" ] && ok || bad "P3 jest name, got [$(cat "$T/jest.new")]"

# ===========================================================================
# P4 — mixed input: runner names first, then suite names, each once
# ===========================================================================
{
  cat "$T/vitest.txt"
  printf '%s--- tests/a-test.sh rc=1 3s\n' "$PFX"
  printf '%s--- tests/ok-test.sh rc=0 1s\n' "$PFX"
  printf '%s--- tests/b-test.sh rc=2 4s\n' "$PFX"
  printf '%s--- tests/a-test.sh rc=1 3s\n' "$PFX"
} > "$T/mixed.txt"
got=$(flaky_parse_tests < "$T/mixed.txt")
want=$(printf 'queue > drains under load\ntests/a-test.sh\ntests/b-test.sh')
[ "$got" = "$want" ] && ok || bad "P4 mixed input must give [$want], got [$got]"

# ===========================================================================
# E — flaky_run_tests, the production entry, with gh stubbed
# ===========================================================================
mkdir -p "$T/fakebin"
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
case "$*" in
  "run view "*"--log-failed"*) cat "$GH_LOG" ;;
  *"actions/runs/"*"/jobs"*) echo "shard-2" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/fakebin/gh"
printf '%s--- tests/a-test.sh rc=1 3s\nshard-2\tRun tests\t2026-09-30T01:02:03.4567891Z FAIL: something\n' "$PFX" > "$T/red.log"
got=$(PATH="$T/fakebin:$PATH" GH_LOG="$T/red.log" flaky_run_tests owner/repo 101)
[ "$got" = "tests/a-test.sh" ] && ok || bad "E flaky_run_tests must name tests/a-test.sh, not job:<shard>, got [$got]"
printf '%s--- tests/a-test.sh rc=0 3s\n' "$PFX" > "$T/green.log"
got=$(PATH="$T/fakebin:$PATH" GH_LOG="$T/green.log" flaky_run_tests owner/repo 102)
[ "$got" = "job:shard-2" ] && ok || bad "E an rc=0-only log must fall back to job:<shard>, got [$got]"

echo "flaky-parse-harness: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
