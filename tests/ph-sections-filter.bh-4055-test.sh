#!/bin/bash
# tests/ph-sections-filter.bh-4055-test.sh — `bin/pipeline-health.sh --sections`
# (and PH_SECTIONS) runs ONLY the named PR checks, and never retracts a key of a
# section it skipped (BH-4055).
#
# Drives the REAL bin/pipeline-health.sh against a scratch tree
# (tests/lib/ph-sections-fixture.sh), with the real alert-line.sh, beat.sh and
# alert-state.sh. The only fakes are gh, curl and jobs-client. ACTIVE is seeded
# with stalepr:ts, stuckqueue:x, leadunqueued:o/r#5:abcdef123456, tmpfull:root.
#   S1  --sections stalepr, no stale PR -> one resolve, for alert:ph-stalepr_ts
#   S2  no other section ran: no commits/*/status read, no leadunqueued list,
#       no section-12/14 artifact written
#   S3  the skipped namespaces stay in ACTIVE and get no RESOLVED line
#   S4  PH_SECTIONS=stalepr (env form) behaves the same
#   S5  --sections bogus -> rc 0, ACTIVE and DEDUP byte-identical, nothing sent
#   S6  a held locks/pipeline-health.lock -> a sections run exits 0, ACTIVE unchanged
#   S7  budget low -> no resolve, stalepr:ts kept
#   S8  a held locks/pipeline-health-full.lock -> a full run exits 0, ACTIVE
#       unchanged; a sections run is not blocked by it (BH-6044)
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/ph-sections-filter.bh-4055-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/ph-sections-fixture.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v python3 >/dev/null && command -v flock >/dev/null \
  || { echo "jq/python3/flock missing — skipping"; exit 0; }

SEED=$'stalepr:ts\nstuckqueue:x\nleadunqueued:o/r#5:abcdef123456\ntmpfull:root'
ph() { # ph <dir> [args...] — one REAL pipeline-health run; RC is its exit code
  local d="$1"; shift
  ( export HARNESS="$d"; phs_env; export LEAD_REVIEW_AUTO_REPOS=o/r
    "$DIR/bin/pipeline-health.sh" "$@" ) >/dev/null 2>"$d/err.txt"
  RC=$?
}
# open <dir> — the stalepr:ts row is open on the console (a stale run), then
# the PR list goes clean and ACTIVE carries the seed.
open() {
  local d="$1"; phs_mktree "$d"
  printf '[%s]\n' "$(phs_pr 50)" > "$d/prs-r.json"
  ph "$d" --sections stalepr
  grep -qxF ph-stalepr_ts "$d/open.ids" 2>/dev/null || bad "setup: the stale run did not open ph-stalepr_ts: $(cat "$d/err.txt")"
  echo '[]' > "$d/prs-r.json"
  printf '%s\n' "$SEED" > "$d/state/health-active.txt"
  : > "$d/gh.calls"
}
has_line() { grep -qxF "$2" "$1/state/health-active.txt"; }

echo "--- S1: --sections stalepr retracts only stalepr:ts"
D="$T/s1"; open "$D"
ph "$D" --sections stalepr
[ "$RC" = 0 ] && ok || bad "S1: rc=$RC err=$(cat "$D/err.txt")"
[ "$(phs_resolved "$D")" = alert:ph-stalepr_ts ] && ok || bad "S1: resolves '$(phs_resolved "$D" | tr '\n' ' ')', want exactly alert:ph-stalepr_ts"
has_line "$D" stalepr:ts && bad "S1: stalepr:ts still active" || ok
grep -qF 'RESOLVED stalepr:ts' "$D/logs/pipeline-health.log" && ok || bad "S1: no RESOLVED stalepr:ts line"

echo "--- S2: no other section ran"
grep -q '/commits/' "$D/gh.calls" && bad "S2: a commit status was read: $(grep commits "$D/gh.calls")" || ok
[ -n "$(grep -E 'pulls\?state=' "$D/gh.calls" | grep -v -- '-i ')" ] && bad "S2: the leadunqueued list was read: $(cat "$D/gh.calls")" || ok
grep -qE 'pulls\?state=' "$D/gh.calls" && ok || bad "S2: the stalepr list was never read: $(cat "$D/gh.calls")"
[ ! -e "$D/state/sweep-clean-seen.txt" ] && ok || bad "S2: section 12 ran (sweep-clean-seen.txt written)"
[ ! -e "$D/state/permared.stamp" ] && ok || bad "S2: section 14 ran (permared.stamp written)"

echo "--- S3: skipped namespaces are carried, never retracted"
for K in stuckqueue:x leadunqueued:o/r#5:abcdef123456 tmpfull:root; do
  has_line "$D" "$K" && ok || bad "S3: $K dropped from ACTIVE: $(tr '\n' ' ' < "$D/state/health-active.txt")"
  grep -qF "RESOLVED $K" "$D/logs/pipeline-health.log" && bad "S3: $K was retracted" || ok
done
[ ! -s "$D/err.txt" ] && ok || bad "S3: stderr: $(cat "$D/err.txt")"

echo "--- S4: the env form PH_SECTIONS=stalepr"
D="$T/s4"; open "$D"
( export HARNESS="$D"; phs_env; export LEAD_REVIEW_AUTO_REPOS=o/r PH_SECTIONS=stalepr
  "$DIR/bin/pipeline-health.sh" ) >/dev/null 2>"$D/err.txt"; RC=$?
[ "$RC" = 0 ] && ok || bad "S4: rc=$RC"
[ "$(phs_resolved "$D")" = alert:ph-stalepr_ts ] && ok || bad "S4: resolves '$(phs_resolved "$D" | tr '\n' ' ')'"
for K in stuckqueue:x leadunqueued:o/r#5:abcdef123456 tmpfull:root; do
  has_line "$D" "$K" && ok || bad "S4: $K dropped from ACTIVE"
done
[ ! -e "$D/state/sweep-clean-seen.txt" ] && ok || bad "S4: section 12 ran"

echo "--- S5: --sections bogus is a logged no-op, never a full run"
D="$T/s5"; open "$D"
cp "$D/state/health-active.txt" "$D/active.before"; cp "$D/state/health-alerted.json" "$D/dedup.before"
SENT=$(grep -c . "$D/sent.jsonl")
ph "$D" --sections bogus
[ "$RC" = 0 ] && ok || bad "S5: rc=$RC"
cmp -s "$D/active.before" "$D/state/health-active.txt" && ok || bad "S5: ACTIVE changed"
cmp -s "$D/dedup.before" "$D/state/health-alerted.json" && ok || bad "S5: DEDUP changed"
[ "$(grep -c . "$D/sent.jsonl")" = "$SENT" ] && ok || bad "S5: something was sent"
[ ! -s "$D/gh.calls" ] && ok || bad "S5: gh was called: $(cat "$D/gh.calls")"
[ ! -e "$D/state/sweep-clean-seen.txt" ] && ok || bad "S5: fell back to a full run"
grep -q 'bogus' "$D/logs/pipeline-health.log" && ok || bad "S5: the unknown section was not logged"
ls "$D/state/health-fired."* >/dev/null 2>&1 && bad "S5: a health-fired temp file was left behind" || ok

echo "--- S6: a run in flight -> the sections run skips"
D="$T/s6"; open "$D"
cp "$D/state/health-active.txt" "$D/active.before"
( exec 8>"$D/locks/pipeline-health.lock"; flock 8; exec sleep 30 ) & HOLDER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do flock -n "$D/locks/pipeline-health.lock" true && sleep 0.1 || break; done
ph "$D" --sections stalepr
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
[ "$RC" = 0 ] && ok || bad "S6: rc=$RC"
cmp -s "$D/active.before" "$D/state/health-active.txt" && ok || bad "S6: ACTIVE changed under a held lock"
[ -z "$(phs_resolved "$D")" ] && ok || bad "S6: resolved under a held lock"
grep -q 'skipped, a run is in flight' "$D/logs/pipeline-health.log" && ok || bad "S6: no skip line"
# The lock is released: the same run now goes through.
ph "$D" --sections stalepr
[ "$(phs_resolved "$D")" = alert:ph-stalepr_ts ] && ok || bad "S6: after release the run did not resolve"

echo "--- S7: budget low -> nothing retracted"
D="$T/s7"; open "$D"
( export HARNESS="$D" GH_BUDGET_CORE_REMAINING=100; phs_env
  "$DIR/bin/pipeline-health.sh" --sections stalepr,leadunqueued ) >/dev/null 2>"$D/err.txt"; RC=$?
[ "$RC" = 0 ] && ok || bad "S7: rc=$RC"
[ -z "$(phs_resolved "$D")" ] && ok || bad "S7: a budget-low run resolved: $(phs_resolved "$D")"
for K in stalepr:ts stuckqueue:x leadunqueued:o/r#5:abcdef123456 tmpfull:root; do
  has_line "$D" "$K" && ok || bad "S7: $K dropped from ACTIVE"
done

echo "--- S8: a full run in flight -> the next full run skips (BH-6044)"
D="$T/s8"; open "$D"
cp "$D/state/health-active.txt" "$D/active.before"
( exec 8>"$D/locks/pipeline-health-full.lock"; flock 8; exec sleep 30 ) & HOLDER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do flock -n "$D/locks/pipeline-health-full.lock" true && sleep 0.1 || break; done
ph "$D"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
[ "$RC" = 0 ] && ok || bad "S8: rc=$RC"
cmp -s "$D/active.before" "$D/state/health-active.txt" && ok || bad "S8: ACTIVE changed while another full run held the lock"
grep -q 'full run skipped, another full run is in flight' "$D/logs/pipeline-health.log" && ok || bad "S8: no full-run skip line"
# A sections run is not a full run: it never holds the full-run lock.
( exec 8>"$D/locks/pipeline-health-full.lock"; flock 8; exec sleep 30 ) & HOLDER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do flock -n "$D/locks/pipeline-health-full.lock" true && sleep 0.1 || break; done
ph "$D" --sections stalepr
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
[ "$(phs_resolved "$D")" = alert:ph-stalepr_ts ] && ok || bad "S8: a held full-run lock blocked a sections run"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
