#!/bin/bash
# tests/claims-cross-box.bh-5002-test.sh — the two overlap readers
# (bin/plan-overlap.sh, bin/overlap-schedule.sh) read the fleet's job_claims rows
# through the REAL bin/lib/file-claims.sh, DB first (BH-5002, BH-4951.3).
#
# The defect: both readers called fc_list_dir, the pre-BH-2627 name, behind a
# `command -v` guard that was therefore always false, so a claim made on another
# box (a Fly pool build) never deferred anything. The BH-2524 suite missed it
# because its fake lib defined the old name. This suite uses the real lib and
# stubs only _jobs_req, the one thing below it.
#
# One scratch watcher box $W. The Fly build BH-F1 exists ONLY as a row in
# $T/claims.json; nothing for it is on the watcher's disk.
#
#   C1  a Fly claim on src/x.ts defers the watcher's plan on src/x.ts
#   C2  a disjoint plan proceeds
#   C3  overlap-schedule HOLDs a candidate on the Fly claim
#   C4  a released claim (the worker stops listing it) stops deferring
#   C5  a released claim beats a lingering state/claims file; no fallback line
#   C6  unreadable DB -> state/claims is read, and one fallback line is logged
#   C7  the same for overlap-schedule, a non-contract 200, and no lib at all
#   C8  truncated:true is still an answer: FILE_CLAIMS_INCOMPLETE, no fallback
#   C9  the kill switches exit before any GET and log nothing
#   C10 negatives: the build's own row and a later claimer never defer it
#   M1-M3 mutations on copies of the readers
#
# No network, no gh, no LLM, no clock reads (the claim stamps are pinned).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

NOW=2026-10-07T04:00:00Z
EARLY=2026-10-07T03:00:00Z
LATE=2026-10-07T03:30:00Z
W="$T/W"
FBLOG="$W/logs/file-claims-fallback.log"

# The only stub: _jobs_req, serving GET /api/file-claims?project=proj from
# $T/claims.json, failing while $T/outage exists, logging every call.
STUB="$T/jobs-client.stub.sh"
cat > "$STUB" <<SH
_jobs_req() {
  printf '%s %s\n' "\$1" "\$2" >> "$T/req.log"
  [ -e "$T/outage" ] && return 1
  case "\$1 \$2" in
    "GET /api/file-claims?project=proj") cat "$T/claims.json" ;;
    *) return 1 ;;
  esac
}
SH

mkbox() { # mkbox [mutant-dir] — the watcher box; the readers come from the repo or the mutant dir
  scratch_rm "$W"
  mkdir -p "$W/bin/lib" "$W/env" "$W/flags" "$W/logs" "$W/plans" "$W/builds" \
           "$W/locks" "$W/state/claims/proj" "$W/state/preplan-candidates"
  # Written first: scratch_install_closure never clobbers, so the stub and a
  # mutant's scripts survive it and everything else is the repo's.
  cp "$STUB" "$W/bin/jobs-client.sh"
  [ -n "${1:-}" ] && cp "$1/plan-overlap.sh" "$1/overlap-schedule.sh" "$W/bin/"
  scratch_install_closure bin/plan-overlap.sh "$W" >/dev/null || bad "mkbox: closure of bin/plan-overlap.sh"
  scratch_install_closure bin/overlap-schedule.sh "$W" >/dev/null || bad "mkbox: closure of bin/overlap-schedule.sh"
  [ -f "$W/bin/lib/file-claims.sh" ] || bad "mkbox: the closure must carry the REAL bin/lib/file-claims.sh"
  printf 'proj  example-org/proj   -  -  0 local -\n' > "$W/fleet.conf"
}

# row <KEY> <claimed_at> <box> <file>... -> one job_claims row as JSON
row() {
  local K="$1" AT="$2" BOX="$3"; shift 3
  jq -cn --arg k "$K" --arg at "$AT" --arg b "$BOX" --arg f "$(printf '%s\n' "$@")" \
    '{ticket_id:$k, box:$b, status:"running", files_claimed_at:$at, planned_files:$f}'
}
store() { # store <truncated> <row-json>... -> $T/claims.json
  local tr="$1"; shift
  printf '%s\n' "$@" | jq -cs --argjson tr "$tr" '{claims: ., truncated: $tr}' > "$T/claims.json"
}
FLY() { row BH-F1 "$EARLY" pool-proj-abc src/x.ts src/y.ts; }

watcher() { # watcher <file>... -> the watcher build BH-W1 planning these files
  local D="$W/builds/proj-BH-W1-20261007040000"
  scratch_rm "$D"; mkdir -p "$D"
  printf '# plan for BH-W1\n' > "$D/plan.md"
  printf '%s\n' "$@" > "$D/planned-files.txt"
  printf '{"key":"BH-W1"}\n' > "$D/ticket-meta.json"
}
cand() { # cand <KEY> <file>... -> a pre-planned candidate for overlap-schedule
  local K="$1"; shift
  printf '%s\t2\tahead\n' "$K" > "$W/state/preplan-candidates/proj.tsv"
  mkdir -p "$W/plans/proj-$K"; printf '%s\n' "$@" > "$W/plans/proj-$K/planned-files.txt"
}
reset() { # no builds, no local claims, a healthy store holding only the Fly row
  scratch_rm "$W/builds"; scratch_rm "$W/state/claims/proj"; scratch_rm "$W/plans"
  mkdir -p "$W/builds" "$W/state/claims/proj" "$W/plans" "$W/logs"
  rm -f "$W/state/preplan-candidates/proj.tsv" "$T/outage" "$T/req.log" "$FBLOG"
  cp "$STUB" "$W/bin/jobs-client.sh"
  [ -f "$W/bin/lib/file-claims.sh.off" ] && mv -f "$W/bin/lib/file-claims.sh.off" "$W/bin/lib/file-claims.sh"
  store false "$(FLY)"
}
po() { # po [env...] — plan-overlap on BH-W1; sets RC OUT ERR
  OUT=$(env HARNESS="$W" "$@" bash "$W/bin/plan-overlap.sh" proj "$W/builds/proj-BH-W1-20261007040000" 2>"$T/err.txt")
  RC=$?; ERR=$(cat "$T/err.txt")
}
os() { # os [env...] — overlap-schedule full mode; sets RC OUT ERR
  OUT=$(env HARNESS="$W" "$@" bash "$W/bin/overlap-schedule.sh" proj 2>"$T/err.txt")
  RC=$?; ERR=$(cat "$T/err.txt")
}
fblines() { # fblines [pattern] -> count of fallback lines (matching pattern)
  [ -f "$FBLOG" ] || { echo 0; return; }
  grep -c -- "${1:-FILE_CLAIMS_FALLBACK}" "$FBLOG"
}
gets() { grep -c '^GET /api/file-claims?project=proj$' "$T/req.log" 2>/dev/null || echo 0; }

mkbox

# ---------- C1. a Fly build's claim defers the watcher's plan ---------------
reset; watcher src/x.ts
po
[ "$RC" = 1 ] && ok || bad "C1: plan-overlap must exit 1 on the Fly claim, got rc=$RC out=[$OUT] err=[$ERR]"
case "$OUT" in "OVERLAP_DEFER BH-W1 vs BH-F1 files=[src/x.ts"*) ok ;;
  *) bad "C1: stdout must start 'OVERLAP_DEFER BH-W1 vs BH-F1 files=[src/x.ts', got: [$OUT]" ;; esac
[ "$(gets)" = 1 ] && ok || bad "C1: exactly one GET /api/file-claims?project=proj, req.log: [$(cat "$T/req.log" 2>/dev/null)]"
[ "$(fblines)" = 0 ] && ok || bad "C1: the DB answered, no fallback line expected: [$(cat "$FBLOG")]"

# ---------- C2. disjoint plan proceeds --------------------------------------
reset; watcher src/z.ts
po
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "C2: disjoint plan must exit 0 silently, got rc=$RC out=[$OUT]"

# ---------- C3. overlap-schedule HOLDs on the Fly claim ---------------------
reset; cand BH-W2 src/y.ts
os
case "$OUT" in *"HELD: BH-W2 overlaps in-flight BH-F1"*) ok ;;
  *) bad "C3: overlap-schedule must HOLD BH-W2 on BH-F1, got rc=$RC out=[$OUT] err=[$ERR]" ;; esac
[ "$(fblines)" = 0 ] && ok || bad "C3: the DB answered, no fallback line expected: [$(cat "$FBLOG")]"

# ---------- C4. a released claim stops deferring ----------------------------
reset; watcher src/x.ts; cand BH-W2 src/y.ts
store false
po
[ "$RC" = 0 ] && ok || bad "C4: released BH-F1 must not defer plan-overlap, got rc=$RC out=[$OUT]"
os
case "$OUT" in *HELD*) bad "C4: released BH-F1 must not HOLD, got: [$OUT]" ;; *) ok ;; esac

# ---------- C5. a released claim beats a lingering local claim file ---------
reset; watcher src/x.ts; cand BH-W2 src/x.ts
store false
printf 'src/x.ts\n' > "$W/state/claims/proj/BH-F1"
po
[ "$RC" = 0 ] && ok || bad "C5: DB answered without BH-F1, its local file must not defer, got rc=$RC out=[$OUT]"
scratch_rm "$W/builds"; mkdir -p "$W/builds"   # BH-W1's own dir would hold BH-W2 on src/x.ts
os
case "$OUT" in *HELD*) bad "C5: DB answered without BH-F1, overlap-schedule must not HOLD, got: [$OUT]" ;; *) ok ;; esac
[ "$(fblines)" = 0 ] && ok || bad "C5: the DB answered, the fallback log must be empty: [$(cat "$FBLOG")]"

# ---------- C6. unreadable DB -> local dir + one fallback line --------------
reset; watcher src/x.ts
touch "$T/outage"
printf 'src/x.ts\n' > "$W/state/claims/proj/BH-L1"
po
[ "$RC" = 1 ] && ok || bad "C6: outage must read state/claims and defer on BH-L1, got rc=$RC out=[$OUT]"
case "$OUT" in "OVERLAP_DEFER BH-W1 vs BH-L1 "*) ok ;; *) bad "C6: expected OVERLAP_DEFER BH-W1 vs BH-L1, got: [$OUT]" ;; esac
[ "$(fblines 'FILE_CLAIMS_FALLBACK proj plan-overlap')" = 1 ] && [ "$(wc -l < "$FBLOG")" = 1 ] && ok \
  || bad "C6: exactly one 'FILE_CLAIMS_FALLBACK proj plan-overlap' line expected, log: [$(cat "$FBLOG" 2>/dev/null)]"
grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z FILE_CLAIMS_FALLBACK proj plan-overlap: job_claims unreadable, read state/claims/proj$' "$FBLOG" 2>/dev/null \
  && ok || bad "C6: fallback line shape wrong: [$(cat "$FBLOG" 2>/dev/null)]"
case "$ERR" in *FILE_CLAIMS_FALLBACK*) bad "C6: the fallback line goes to the log only, not stderr: [$ERR]" ;; *) ok ;; esac
# no logs/ dir: the verdict is unchanged and nothing is printed about it
scratch_rm "$W/logs"
po
# BH-5268: the stub fails the hotspot GET too, so stderr carries exactly the
# PLAN_HOTSPOTS_UNREAD line for that; nothing else may be printed.
[ "$RC" = 1 ] && [ "$(printf '%s' "$ERR" | grep -vx 'PLAN_HOTSPOTS_UNREAD proj')" = "" ] && ok || bad "C6: a missing logs/ must not change the verdict, got rc=$RC err=[$ERR]"
mkdir -p "$W/logs"

# ---------- C7. overlap-schedule, non-contract 200, and no lib --------------
reset; cand BH-W2 src/x.ts
printf 'src/x.ts\n' > "$W/state/claims/proj/BH-L1"
printf '{"queue":[]}\n' > "$T/claims.json"
os
case "$OUT" in *"HELD: BH-W2 overlaps in-flight BH-L1"*) ok ;;
  *) bad "C7: a non-contract 200 must fall back to state/claims and HOLD on BH-L1, got: [$OUT]" ;; esac
[ "$(fblines 'FILE_CLAIMS_FALLBACK proj overlap-schedule')" = 1 ] && [ "$(wc -l < "$FBLOG")" = 1 ] && ok \
  || bad "C7: exactly one 'FILE_CLAIMS_FALLBACK proj overlap-schedule' line expected, log: [$(cat "$FBLOG" 2>/dev/null)]"
mv -f "$W/bin/lib/file-claims.sh" "$W/bin/lib/file-claims.sh.off"
store false "$(FLY)"
os
case "$OUT" in *"HELD: BH-W2 overlaps in-flight BH-L1"*) ok ;;
  *) bad "C7: no lib must fall back to state/claims and HOLD on BH-L1, got: [$OUT]" ;; esac
[ "$(fblines 'FILE_CLAIMS_FALLBACK proj overlap-schedule')" = 2 ] && [ "$(wc -l < "$FBLOG")" = 2 ] && ok \
  || bad "C7: no lib must append exactly one more line, log: [$(cat "$FBLOG" 2>/dev/null)]"

# ---------- C8. truncated:true is an answer, not a fallback -----------------
reset; watcher src/x.ts
store true "$(FLY)"
po
[ "$RC" = 1 ] && case "$OUT" in "OVERLAP_DEFER BH-W1 vs BH-F1 "*) true ;; *) false ;; esac && ok \
  || bad "C8: truncated answer must still defer on BH-F1, got rc=$RC out=[$OUT]"
case "$ERR" in *"FILE_CLAIMS_INCOMPLETE proj"*) ok ;; *) bad "C8: expected FILE_CLAIMS_INCOMPLETE on stderr, got [$ERR]" ;; esac
[ "$(fblines)" = 0 ] && ok || bad "C8: truncated must not log a fallback: [$(cat "$FBLOG")]"

# ---------- C9. kill switches: no GET, no fallback line ---------------------
reset; watcher src/x.ts; cand BH-W2 src/x.ts
po OVERLAP_SCHED=0
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "C9: OVERLAP_SCHED=0 must exit 0 silently, got rc=$RC out=[$OUT]"
os OVERLAP_SCHEDULE=0
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "C9: OVERLAP_SCHEDULE=0 must exit 0 silently, got rc=$RC out=[$OUT]"
[ "$(gets)" = 0 ] && [ "$(fblines)" = 0 ] && ok \
  || bad "C9: kill switches must make no GET and log nothing, req=[$(cat "$T/req.log" 2>/dev/null)] log=[$(cat "$FBLOG" 2>/dev/null)]"

# ---------- C10. negatives: own row, later claimer --------------------------
reset; watcher src/x.ts
store false "$(row BH-W1 "$EARLY" pool-proj-abc src/x.ts)"
po
[ "$RC" = 0 ] && ok || bad "C10: the build's own DB row must not defer it, got rc=$RC out=[$OUT]"
store false "$(row BH-W1 "$EARLY" watcher src/x.ts)" "$(row BH-F1 "$LATE" pool-proj-abc src/x.ts)"
po
[ "$RC" = 0 ] && ok || bad "C10: a later DB claimer must not defer the earlier one, got rc=$RC out=[$OUT]"
store false "$(row BH-W1 "$NOW" watcher src/x.ts)" "$(FLY)"
po
[ "$RC" = 1 ] && ok || bad "C10: an earlier Fly claimer must defer the later watcher, got rc=$RC out=[$OUT]"

# ---------- M. mutations on copies of the readers ---------------------------
# Each mutant must CHANGE its copy (an anchor that does not match FAILS) and
# must turn the named case red.
mutant() { # mutant <name> <file> <sed-expr>
  local M="$T/mut-$1"
  mkdir -p "$M"; cp "$DIR/bin/plan-overlap.sh" "$DIR/bin/overlap-schedule.sh" "$M/"
  sed -i "$3" "$M/$2"
  if cmp -s "$M/$2" "$DIR/bin/$2"; then bad "mutation $1: sed anchor did not match $2"; return 1; fi
  mkbox "$M"
}
# M1. plan-overlap back on the dead name -> C1 goes red
if mutant M1 plan-overlap.sh 's/fclaim_list_dir/fc_list_dir/g'; then
  reset; watcher src/x.ts; po
  [ "$RC" = 0 ] && ok || bad "mutation M1: fc_list_dir in plan-overlap must lose the Fly claim (C1 red), got rc=$RC"
fi
# M2. overlap-schedule back on the dead name -> C3 goes red
if mutant M2 overlap-schedule.sh 's/fclaim_list_dir/fc_list_dir/g'; then
  reset; cand BH-W2 src/y.ts; os
  case "$OUT" in *HELD*) bad "mutation M2: fc_list_dir in overlap-schedule must lose the HOLD (C3 red), got: [$OUT]" ;; *) ok ;; esac
fi
# M3. source 1 read regardless of the DB answer -> C5 goes red
if mutant M3 plan-overlap.sh 's/^if \[ "\$FC_OK" = 0 \]; then$/if true; then/'; then
  reset; watcher src/x.ts; store false
  printf 'src/x.ts\n' > "$W/state/claims/proj/BH-F1"
  po
  [ "$RC" = 1 ] && ok || bad "mutation M3: without the FC_OK gate the lingering file must defer (C5 red), got rc=$RC"
fi
mkbox

echo "claims-cross-box.bh-5002: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
