#!/bin/bash
# tests/preplan-publish.bh-3437-test.sh — every watcher box publishes the
# pre-plan it just wrote, whatever routing flags it happens to carry (BH-3437).
# Run from anywhere: tests/preplan-publish.bh-3437-test.sh   (exit 0 = all pass)
#
# THE DEFECT. bin/run-preplan.sh gated the publish on preplan_publish_wanted,
# evaluated before jobs-client.sh was sourced, so it fell back to
# `[ -f flags/builder-fly-<p> ]` — a hub-side routing file a watcher box need not
# have. project-5, project-1 and project-3 published 0 rows, and every one of
# their pool builds re-planned from scratch.
#
# HOW IT IS DRIVEN. The `# >>> consumable record` block is extracted verbatim
# from bin/run-preplan.sh and run with the REAL bin/lib/preplan-lib.sh loaded
# (so a surviving routing gate would still bite) and a stub jobs-client.sh
# whose preplan_put logs its arguments and answers a fixture rc.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin/lib" "$T/flags" "$T/logs" "$T/pd"
cp "$DIR/bin/lib/preplan-lib.sh" "$T/bin/lib/"
awk '/^  # >>> consumable record/{f=1} /^  # <<< consumable record/{exit} f' "$DIR/bin/run-preplan.sh" > "$T/block.sh"
[ -s "$T/block.sh" ] || { echo "FAIL: could not extract the consumable record block"; exit 1; }
cat > "$T/bin/jobs-client.sh" <<'EOF'
preplan_put() {
  printf '%s %s %s\n' "$1" "$2" "$3" >> "$HARNESS/put-calls"
  return "$(cat "$HARNESS/put-rc" 2>/dev/null || echo 0)"
}
EOF
printf '## Scope\nx\n' > "$T/pd/plan.md"

run() { # run -> the block's rc in $RC, the log in $T/logs/run.log
  rm -f "$T/put-calls" "$T/logs/run.log"
  ( HARNESS="$T"; PROJECT=proj; KEY=AB-1; PLANDIR="$T/pd"; WT="$T"; BASE=main; LOG="$T/logs/run.log"
    # shellcheck source=/dev/null
    . "$T/bin/lib/preplan-lib.sh"
    STAMP() { printf '2026-09-29 17:08:14Z'; }
    TICKET_FP() { printf 'fp\n'; }
    preplan_record() { printf 'abc\n' > "$1/base-sha"; }
    # shellcheck source=/dev/null
    . "$T/block.sh" ) >/dev/null 2>&1
  RC=$?
}

echo "--- 1. no flags/builder-fly-* on the box -> still published"
printf '0\n' > "$T/put-rc"; run
[ "$(cat "$T/put-calls" 2>/dev/null)" = "proj AB-1 $T/pd" ] && ok \
  || bad "a box with no routing flag must publish once (calls: $(cat "$T/put-calls" 2>/dev/null))"
grep -q 'pre-plan published' "$T/logs/run.log" 2>/dev/null && ok || bad "a publish must log 'pre-plan published'"
[ "$RC" = 0 ] && ok || bad "the block must exit 0 (rc $RC)"

echo "--- 2. the flag present is irrelevant -> published once"
touch "$T/flags/builder-fly-proj"; run
[ "$(grep -c . "$T/put-calls" 2>/dev/null)" = 1 ] && ok || bad "with the flag, still exactly one publish"
rm -f "$T/flags/builder-fly-proj"

echo "--- 3. the worker refuses -> REFUSED line, rc 0"
printf '3\n' > "$T/put-rc"; run
grep -q 'pre-plan publish REFUSED' "$T/logs/run.log" 2>/dev/null && ok || bad "a 4xx must log REFUSED (log: $(cat "$T/logs/run.log" 2>/dev/null))"
[ "$RC" = 0 ] && ok || bad "a refused publish must never change the stage rc (rc $RC)"

echo "--- 4. no jobs client on the box -> nothing published, no error"
mv "$T/bin/jobs-client.sh" "$T/bin/jobs-client.off"; printf '0\n' > "$T/put-rc"; run
[ ! -e "$T/put-calls" ] && ok || bad "no client must publish nothing"
[ "$RC" = 0 ] && ok || bad "no client must be rc 0 (rc $RC)"
mv "$T/bin/jobs-client.off" "$T/bin/jobs-client.sh"

echo "--- 5. the routing gate is gone for good"
! grep -q preplan_publish_wanted "$DIR/bin/run-preplan.sh" "$DIR/bin/lib/preplan-lib.sh" && ok \
  || bad "preplan_publish_wanted must not survive in bin/run-preplan.sh or bin/lib/preplan-lib.sh"

echo "preplan-publish: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
