#!/bin/bash
# tests/overlap-read-mostly.bh-6299-test.sh — a path every plan lists but no
# build edits is "read-mostly", and it never makes a COLLISION in
# bin/overlap-schedule.sh or bin/overlap-guard.sh. ONE rule decides it:
# read_mostly_list in bin/lib/read-mostly.sh, which both scripts call.
#
# THE NUMBER (BH-6299, project-6-os 2026-10-12): six tickets each listed the
# same six guard tests and checks. The builds RUN those files and almost never
# EDIT them (2 real commits across all of them since 2026-10-09), and the
# schedule spread the six tickets over six waves.
#
# Everything here drives the REAL scripts against a scratch $HARNESS with a
# fake jobs ledger. Assertions are on stdout and rc, never on source text.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/overlap-read-mostly.bh-6299-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

LIB="$DIR/bin/lib/read-mostly.sh"
[ -f "$LIB" ] && ok || bad "bin/lib/read-mostly.sh must exist"

H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$H/flags" "$H/logs" "$H/plans" "$H/builds" \
         "$H/locks" "$H/state/claims/proj" "$H/state/preplan-candidates"
scratch_install_closure bin/overlap-schedule.sh "$H" >/dev/null || bad "cannot install the schedule closure"
scratch_install_closure bin/overlap-guard.sh "$H" >/dev/null || bad "cannot install the guard closure"
: > "$H/env/global.env"

# The fake jobs ledger. The guard asks /api/jobs for running builds; the
# schedule's file-claims read gets no contract answer, so it reads
# state/claims/ — the same in-flight set, from the source each script uses.
cat > "$H/bin/jobs-client.sh" <<EOF
_jobs_req() {
  case "\$2" in
    */api/jobs\?*status=running*) cat "$T/ledger.json" 2>/dev/null ;;
    *) return 1 ;;
  esac
}
EOF
echo '{"jobs":[]}' > "$T/ledger.json"

RLS=tests/unit/rls-baseline.TK-1.test.ts
GUARDS=(tests/unit/rls-baseline.TK-1.test.ts tests/unit/no-direct-company-query.TK-3.test.ts
        scripts/checks/company-query.mjs tests/e2e/os-shell.TK-1.spec.ts
        src/lib/db/scoped.ts tests/unit/registry-loader.test.ts)

# hist <project> <plans> <edits> <prefix> <path>... — <plans> counted builds
# that each plan <path>..., the first <edits> of them also changed every one.
# Every build also plans and changes its own file, the way a real slice does.
# Odd builds are relayed pool dirs (pool-<project>-...), as fly-results-ingest
# lays them out.
hist() {
  local p="$1" n="$2" e="$3" pre="$4" i d k; shift 4
  for i in $(seq 1 "$n"); do
    k="${pre}-$i"
    if [ $((i % 2)) = 1 ]; then d="$H/builds/pool-$p-$k-202610120000"; else d="$H/builds/$p-$k-202610120000"; fi
    mkdir -p "$d"
    printf 'PR_CREATED https://example.invalid/pr/%s\n' "$i" > "$d/RESULT"
    printf '{"key":"%s"}\n' "$k" > "$d/ticket-meta.json"
    { echo "SOURCE: ticket-body"; printf '%s\n' "$@"; echo "src/own/$k.ts"; } > "$d/planned-files.txt"
    { echo "src/own/$k.ts"; [ "$i" -le "$e" ] && printf '%s\n' "$@"; } > "$d/changed-files.txt"
  done
}
rml() { # rml <project> -> read_mostly_list's output, cache bypassed unless set
  ( HARNESS="$H"; . "$H/bin/lib/read-mostly.sh" 2>/dev/null || exit 0
    READ_MOSTLY_MAX_AGE="${READ_MOSTLY_MAX_AGE-0}" read_mostly_list "$1" "$H" )
}
plan_files() { local k="$1"; shift; mkdir -p "$H/plans/proj-$k"; printf '%s\n' "$@" > "$H/plans/proj-$k/planned-files.txt"; }
cands() { printf '%s\t1\tahead\n' "$@" > "$H/state/preplan-candidates/proj.tsv"; }
reset() {
  scratch_rm "$H/builds"; scratch_rm "$H/plans"; scratch_rm "$H/state/claims/proj"
  scratch_rm "$H/state/read-mostly"; rm -f "$H/logs/read-mostly.log"
  mkdir -p "$H/builds" "$H/plans" "$H/state/claims/proj"
  echo '{"jobs":[]}' > "$T/ledger.json"
}
sched() { HARNESS="$H" READ_MOSTLY_MAX_AGE="${READ_MOSTLY_MAX_AGE-0}" "$H/bin/overlap-schedule.sh" proj "$@" 2>/dev/null; }
guard() { GOUT=$(HARNESS="$H" READ_MOSTLY_MAX_AGE="${READ_MOSTLY_MAX_AGE-0}" "$H/bin/overlap-guard.sh" proj "$1" 2>/dev/null); GRC=$?; }
wave_of() { awk -v k="$2" '/^WAVE /{n=$2; sub(":","",n); for(i=3;i<=NF;i++) if($i==k){print n; exit}}' <<<"$1"; }

# The A-fixture: TK-61 and TK-62 share ONLY $RLS.
a_fixture() { # a_fixture <plans> <edits>
  reset
  hist proj "$1" "$2" HX "$RLS"
  plan_files TK-61 src/app/mk61.ts "$RLS"
  plan_files TK-62 src/app/mk62.ts "$RLS"
  cands TK-61 TK-62
}
inflight_61() { # TK-61 is building: a claim for the schedule, a ledger row for the guard
  printf '%s\n' src/app/mk61.ts "$RLS" > "$H/state/claims/proj/TK-61"
  echo '{"jobs":[{"kind":"build","ticket_id":"TK-61"}]}' > "$T/ledger.json"
  cands TK-62
}

# ============================================================================
# C. read_mostly_list — the decision rule and its negatives
# ============================================================================
# C1: 10 plans / 1 edit = 0.1 -> listed
hist c1 10 1 HX "$RLS"
O=$(rml c1)
[ "$O" = "$RLS" ] && ok || bad "C1: 10 plans/1 edit must list $RLS (got: '$O')"
# C2: 5 plans / 1 edit = 0.2 -> NOT listed (strict <)
hist c2 5 1 HX "$RLS"
O=$(rml c2)
[ -z "$O" ] && ok || bad "C2: 5 plans/1 edit is 0.2, not below 0.2 (got: '$O')"
# ...and 5 plans / 0 edits is the smallest read-mostly case
hist c2b 5 0 HX "$RLS"
O=$(rml c2b)
[ "$O" = "$RLS" ] && ok || bad "C2b: 5 plans/0 edits must list $RLS (got: '$O')"
# C3: 4 plans / 0 edits -> too little history
hist c3 4 0 HX "$RLS"
O=$(rml c3)
[ -z "$O" ] && ok || bad "C3: 4 plans is below the 5-plan floor (got: '$O')"
# C4: two dirs for one KEY count once: 5 dirs, 4 keys
hist c4 4 0 HX "$RLS"
d="$H/builds/c4-HX-1-202610110000"; mkdir -p "$d"
cp "$H/builds/pool-c4-HX-1-202610120000/"* "$d/"
O=$(rml c4)
[ -z "$O" ] && ok || bad "C4: a rebuild of one KEY must count once (got: '$O')"
# C5: an unwritable state dir still answers
hist c5 10 0 HX "$RLS"
scratch_rm "$H/state/read-mostly"; : > "$H/state/read-mostly"
O=$(rml c5)
[ "$O" = "$RLS" ] && ok || bad "C5: an unwritable state dir must still print the set (got: '$O')"
[ -f "$H/state/read-mostly" ] && ok || bad "C5: the blocking file must be left as it was"
rm -f "$H/state/read-mostly"
# C6: no builds at all -> empty
O=$(rml c6-none)
[ -z "$O" ] && ok || bad "C6: no history must print nothing (got: '$O')"
# C7: the cache round-trip. A second call inside MAX_AGE reads the cache.
hist c7 10 0 HX "$RLS"
O1=$(READ_MOSTLY_MAX_AGE=900 rml c7)
[ -s "$H/state/read-mostly/c7.tsv" ] && ok || bad "C7: a compute must write state/read-mostly/c7.tsv"
for x in "$H/builds/"*c7-*; do scratch_rm "$x"; done
O2=$(READ_MOSTLY_MAX_AGE=900 rml c7)
[ "$O1" = "$RLS" ] && [ "$O2" = "$O1" ] && ok || bad "C7: the cache must answer the same set (first '$O1', second '$O2')"
O3=$(READ_MOSTLY_MAX_AGE=0 rml c7)
[ -z "$O3" ] && ok || bad "C7: MAX_AGE=0 must recompute, and with no builds the set is empty (got: '$O3')"
# C8: MAX_RATE=0 is off
O=$(READ_MOSTLY_MAX_RATE=0 rml c1)
[ -z "$O" ] && ok || bad "C8: READ_MOSTLY_MAX_RATE=0 must list nothing (got: '$O')"
# C9: a planned directory is EDITED when a build changes a file under it.
# 10 plans of src/lib/db, 3 builds changed src/lib/db/scoped.ts = 0.3.
for i in $(seq 1 10); do
  d="$H/builds/c9-HX-$i-202610120000"; mkdir -p "$d"
  echo "PR_MERGED https://example.invalid/pr/$i" > "$d/RESULT"
  printf 'src/lib/db/\nsrc/own/x%s.ts\n' "$i" > "$d/planned-files.txt"
  { echo "src/own/x$i.ts"; [ "$i" -le 3 ] && echo src/lib/db/scoped.ts; } > "$d/changed-files.txt"
done
O=$(rml c9)
[ -z "$O" ] && ok || bad "C9: an edit under a planned dir counts as an edit of it (got: '$O')"
# C10: only PR_CREATED/PR_MERGED builds count; SOURCE: is never a path.
for i in $(seq 1 10); do
  d="$H/builds/c10-HX-$i-202610120000"; mkdir -p "$d"
  case $((i % 3)) in 0) r="BUILD_DEFERRED file overlap" ;; 1) r="PLAN_BLOCKED x" ;; *) r="REVIEW_BLOCKED https://example.invalid/pr/$i" ;; esac
  echo "$r" > "$d/RESULT"
  printf 'SOURCE: ticket-body\n%s\nsrc/own/y%s.ts\n' "$RLS" "$i" > "$d/planned-files.txt"
  echo "src/own/y$i.ts" > "$d/changed-files.txt"
done
O=$(rml c10)
[ -z "$O" ] && ok || bad "C10: builds that opened no PR must not count (got: '$O')"
O=$(rml c1)
grep -qi '^source:' <<<"$O" && bad "C10: a SOURCE: header must never be listed (got: '$O')" || ok

# ============================================================================
# A. the schedule and the guard
# ============================================================================
# A1: shared only on a read-mostly path -> one wave, no HELD, guard LAUNCH
a_fixture 10 1
OUT=$(sched)
[ "$(wave_of "$OUT" TK-61)" = 1 ] && [ "$(wave_of "$OUT" TK-62)" = 1 ] && ok \
  || bad "A1: TK-61 and TK-62 share only a read-mostly path, both must be in WAVE 1 (got: $OUT)"
grep -q '^HELD:' <<<"$OUT" && bad "A1: no HELD line (got: $OUT)" || ok
inflight_61
OUT=$(sched)
grep -q '^HELD:' <<<"$OUT" && bad "A1: TK-61 in flight must not hold TK-62 on a read-mostly path (got: $OUT)" || ok
[ "$(wave_of "$OUT" TK-62)" = 1 ] && ok || bad "A1: TK-62 must be in WAVE 1 while TK-61 builds (got: $OUT)"
guard TK-62
[ "$GRC" = 0 ] && grep -q '^LAUNCH TK-62' <<<"$GOUT" && ok \
  || bad "A4/A1: the guard must LAUNCH TK-62, as the schedule does (rc $GRC, out: $GOUT)"
grep -q 'read-mostly: 1 path(s) not judged' "$H/logs/overlap-guard.log" && ok \
  || bad "A4/A1: the guard log must say a read-mostly path was not judged"
A1_GUARD="$GRC"

# A2: edit_rate 0.6 -> the old rule
a_fixture 10 6
OUT=$(sched)
[ "$(wave_of "$OUT" TK-62)" = 2 ] && ok || bad "A2: at 0.6 TK-62 must be WAVE 2 (got: $OUT)"
inflight_61
OUT=$(sched)
grep -qF "HELD: TK-62 overlaps in-flight TK-61 on $RLS" <<<"$OUT" && ok \
  || bad "A2: at 0.6 TK-62 must be HELD by TK-61 (got: $OUT)"
guard TK-62
[ "$GRC" = 1 ] && grep -q '^DEFER TK-62 vs TK-61(building)' <<<"$GOUT" && ok \
  || bad "A4/A2: the guard must DEFER TK-62, as the schedule HELDs it (rc $GRC, out: $GOUT)"
[ "$A1_GUARD" = 0 ] && [ "$GRC" = 1 ] && ok || bad "A4: guard verdicts must follow the schedule (A1 rc $A1_GUARD, A2 rc $GRC)"

# A3: 4 plans of history -> the old rule
a_fixture 4 0
OUT=$(sched)
[ "$(wave_of "$OUT" TK-62)" = 2 ] && ok || bad "A3: 4 plans of history must keep the old rule, WAVE 2 (got: $OUT)"
inflight_61
guard TK-62
[ "$GRC" = 1 ] && ok || bad "A3: the guard must DEFER on 4 plans of history (rc $GRC, out: $GOUT)"

# C6 again, through the schedule: no history = today's answer
a_fixture 0 0
OUT=$(sched)
[ "$(wave_of "$OUT" TK-62)" = 2 ] && ok || bad "C6: with no history the schedule must answer as today, WAVE 2 (got: $OUT)"
# C8 through the schedule: MAX_RATE=0 gives today's WAVE 2 on the A1 fixture
a_fixture 10 1
OUT=$(READ_MOSTLY_MAX_RATE=0 sched)
[ "$(wave_of "$OUT" TK-62)" = 2 ] && ok || bad "C8: READ_MOSTLY_MAX_RATE=0 must give today's WAVE 2 (got: $OUT)"

# ============================================================================
# H1. HOT-FILES keeps the path and marks it
# ============================================================================
a_fixture 10 1
plan_files TK-63 src/hot.ts
plan_files TK-64 src/hot.ts
cands TK-61 TK-62 TK-63 TK-64
OUT=$(OVERLAP_HOT_MIN=2 sched)
grep -qxF "$RLS :: TK-61 TK-62 (read-mostly)" <<<"$OUT" && ok \
  || bad "H1: the read-mostly hot line must end '(read-mostly)' (got: $OUT)"
grep -qxF "src/hot.ts :: TK-63 TK-64" <<<"$OUT" && ok \
  || bad "H1: a normal hot path carries no marker (got: $OUT)"
# --key and --hot-for keep their one-line contracts
V=$(sched --key TK-62)
[ "$V" = "TK-62 WAVE 1 (shares no planned file with an in-flight build)" ] && ok \
  || bad "H1: --key TK-62 must be WAVE 1 (got: $V)"

# ============================================================================
# L1. a real edit of a read-mostly path is logged once per (KEY, file)
# ============================================================================
a_fixture 10 1
rml proj >/dev/null
rml proj >/dev/null
N=$(grep -c "READ_MOSTLY_EDITED $RLS HX-1\$" "$H/logs/read-mostly.log" 2>/dev/null)
[ "${N:-0}" = 1 ] && ok || bad "L1: READ_MOSTLY_EDITED $RLS HX-1 must be logged exactly once over two computes (got ${N:-0})"
N=$(grep -c 'READ_MOSTLY_EDITED' "$H/logs/read-mostly.log" 2>/dev/null)
[ "${N:-0}" = 1 ] && ok || bad "L1: only the build that edited the path logs (got ${N:-0} lines)"
# An edit of a path that is NOT read-mostly (0.6) is not a READ_MOSTLY_EDITED.
a_fixture 10 6
rml proj >/dev/null
N=$(grep -c 'READ_MOSTLY_EDITED' "$H/logs/read-mostly.log" 2>/dev/null)
[ "${N:-0}" = 0 ] && ok || bad "L1: an edit of a path at 0.6 must not log READ_MOSTLY_EDITED (got ${N:-0} lines)"

# ============================================================================
# R1. the project-6-os replay: six tickets, six shared guard paths
# ============================================================================
r_fixture() { # r_fixture <with-history 0|1>
  reset
  [ "$1" = 1 ] && { hist proj 10 0 HX "${GUARDS[@]}"; hist proj 1 1 HY "${GUARDS[@]}"; }
  local k
  for k in TK-61 TK-62 TK-136 TK-146 TK-154 TK-155; do
    plan_files "$k" "src/registry/$k.ts" "${GUARDS[@]}"
  done
  cands TK-61 TK-62 TK-136 TK-146 TK-154 TK-155
}
r_fixture 1
OUT=$(sched)
grep -qx 'WAVE 1: TK-61 TK-62 TK-136 TK-146 TK-154 TK-155' <<<"$OUT" && ok \
  || bad "R1: all six project-6 tickets must be in WAVE 1 (got: $OUT)"
grep -q '^HELD:\|^WAVE 2' <<<"$OUT" && bad "R1: no HELD and no WAVE 2 (got: $OUT)" || ok
r_fixture 0
OUT=$(sched)
grep -qx 'WAVE 6: TK-155' <<<"$OUT" && ok || bad "R1: with no history the six still take six waves (got: $OUT)"

# ============================================================================
# M1. mutation check (D1): with the set stubbed empty, A1 and R1 go red
# ============================================================================
mv "$H/bin/lib/read-mostly.sh" "$T/rm-real.sh"
printf 'read_mostly_list() { :; }\n' > "$H/bin/lib/read-mostly.sh"
a_fixture 10 1
OUT=$(sched)
[ "$(wave_of "$OUT" TK-62)" = 2 ] && ok || bad "M1: with read_mostly_list stubbed empty A1 must fall back to WAVE 2 (got: $OUT)"
r_fixture 1
OUT=$(sched)
grep -qx 'WAVE 1: TK-61 TK-62 TK-136 TK-146 TK-154 TK-155' <<<"$OUT" \
  && bad "M1: with read_mostly_list stubbed empty R1 must not be one wave (got: $OUT)" || ok
mv -f "$T/rm-real.sh" "$H/bin/lib/read-mostly.sh"

echo "overlap-read-mostly.bh-6299: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
