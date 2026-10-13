#!/bin/bash
# tests/plan-overlap-fleet.bh-5268-test.sh — the plan-time overlap gate
# sequences overlapping plans for ANY project, and a stored conflict hotspot a
# plan names only lightly still counts as a claim (BH-5268).
#
# The REAL bin/plan-overlap.sh, bin/lib/plan-hotspots.sh, bin/planned-files.sh
# and bin/lib/jobs/jobs.sh run in a scratch box for the fixture project `acme`
# (not cromford). The only stub is _jobs_req, which serves
# GET /api/file-claims and GET /api/conflict-hotspots from fixture JSON, takes
# PUT /api/jobs/<id>/artifacts, and logs every request.
#
#   F1  two plans name src/app/page.tsx (one a live local build) -> sequenced
#   F1b the same, the other side only a job_claims row          -> sequenced
#   F2  disjoint plans                                           -> parallel
#   F3  candidate names hotspot bin/deploy.sh in prose; AC-1 claims it -> sequenced
#   F3s the in-flight side names the hotspot only in its plan.md -> sequenced
#   F3b-F3g negatives: no row, Sibling-claims-only mention, conflicts<MIN,
#       outage (and the cache after it), near-miss paths, hotspot with no claim
#   F4  plan.sh publishes planned-files ∪ hotspot mentions as the claim
#   F5  nothing anywhere says Blocked-by
#   F6  kill switch and TOP=0 make no hotspot GET
#   H1-H7 the lib's units
#   M0  main's plan-overlap.sh (while main predates this lib) leaves F3 rc 0
#   M1-M3 mutants of plan-overlap.sh turn F3, F3s and F1 red
#
# No network, no gh, no LLM.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/rb-all.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/bin/lib/plan-hotspots.sh"
[ -f "$LIB" ] && ok || bad "setup: bin/lib/plan-hotspots.sh does not exist"

W="$T/W"
STUB="$T/jobs-client.stub.sh"
cat > "$STUB" <<SH
JOBS_BOX=box-test
[ -r "\$HARNESS/bin/lib/jobs/jobs.sh" ] && . "\$HARNESS/bin/lib/jobs/jobs.sh"
_jobs_req() {
  printf '%s %s\n' "\$1" "\$2" >> "$T/req.log"
  [ -e "$T/outage" ] && return 1
  case "\$1 \$2" in
    "GET /api/file-claims?project=acme") cat "$T/claims.json" ;;
    "GET /api/conflict-hotspots?project=acme&limit="*)
      [ -e "$T/hot-outage" ] && return 1
      cat "$T/hot.json" ;;
    "PUT /api/jobs/"*"/artifacts") printf '%s\n' "\$3" >> "$T/artifacts.log"; echo '{"ok":true}' ;;
    *) return 1 ;;
  esac
}
SH

mkbox() { # mkbox [mutant-plan-overlap.sh]
  scratch_rm "$W"
  mkdir -p "$W/bin/lib" "$W/env" "$W/flags" "$W/logs" "$W/builds" "$W/state/claims/acme"
  cp "$STUB" "$W/bin/jobs-client.sh"
  [ -n "${1:-}" ] && cp "$1" "$W/bin/plan-overlap.sh"
  scratch_install_closure bin/plan-overlap.sh "$W" >/dev/null || bad "mkbox: closure of bin/plan-overlap.sh"
  scratch_install_closure bin/planned-files.sh "$W" >/dev/null || bad "mkbox: closure of bin/planned-files.sh"
  scratch_install_closure bin/lib/jobs/jobs.sh "$W" >/dev/null || bad "mkbox: closure of bin/lib/jobs/jobs.sh"
  [ -n "${1:-}" ] || [ -f "$W/bin/lib/plan-hotspots.sh" ] || bad "mkbox: the closure must carry the REAL bin/lib/plan-hotspots.sh"
  printf 'acme  example-org/acme   -  -  0 local -\n' > "$W/fleet.conf"
}
reset() { # no builds, no claims, no hotspots, no cache
  scratch_rm "$W/builds"; scratch_rm "$W/state"
  mkdir -p "$W/builds" "$W/state/claims/acme"
  rm -f "$T/outage" "$T/hot-outage" "$T/req.log" "$T/artifacts.log"
  echo '{"claims":[],"truncated":false}' > "$T/claims.json"
  echo '{"project":"acme","run":null,"hotspots":[],"total":0,"truncated":false}' > "$T/hot.json"
}
hot() { # hot <file> <conflicts> ... -> $T/hot.json
  local rows=()
  while [ $# -ge 2 ]; do rows+=("$(jq -cn --arg f "$1" --argjson c "$2" '{file:$f, conflicts:$c, rebases:0}')"); shift 2; done
  printf '%s\n' "${rows[@]}" | jq -cs '{project:"acme", run:{id:1}, hotspots:., total:length, truncated:false}' > "$T/hot.json"
}
claim() { # claim <KEY> <file>... -> one earlier job_claims row in $T/claims.json
  local K="$1"; shift
  jq -cn --arg k "$K" --arg f "$(printf '%s\n' "$@")" \
    '{claims:[{ticket_id:$k, box:"pool-x", status:"running", files_claimed_at:"2026-10-07T03:00:00Z", planned_files:$f}], truncated:false}' \
    > "$T/claims.json"
}
build() { # build <KEY> <plan-text> -> a live build dir; planned-files.txt from the REAL planned-files.sh
  local D="$W/builds/acme-$1-20261007040000"
  scratch_rm "$D"; mkdir -p "$D"
  printf '%s\n' "$2" > "$D/plan.md"
  printf '{"key":"%s"}\n' "$1" > "$D/ticket-meta.json"
  bash "$W/bin/planned-files.sh" "$D"
}
CAND="$W/builds/acme-AC-2-20261007040000"
po() { # po [env...] -> plan-overlap on AC-2; sets RC OUT ERR
  OUT=$(env HARNESS="$W" JOB_ID=job-2 "$@" bash "$W/bin/plan-overlap.sh" acme "$CAND" 2>"$T/err.txt")
  RC=$?; ERR=$(cat "$T/err.txt")
  printf '%s\n%s\n' "$OUT" "$ERR" >> "$T/all-output.txt"
  [ -f "$T/artifacts.log" ] && cat "$T/artifacts.log" >> "$T/all-output.txt"
}
arts() { # arts <ref> -> count of plan_overlap artifacts with that ref
  [ -f "$T/artifacts.log" ] || { echo 0; return; }
  jq -r --arg r "$1" 'select(.artifact_kind=="plan_overlap" and .artifact_ref==$r) | .artifact_ref' "$T/artifacts.log" | grep -c .
}
hotgets() { cat "$T/req.log" 2>/dev/null | grep -c '^GET /api/conflict-hotspots'; }

PLAN_HOT_LIGHT='# Plan AC-2
## Tasks
Edit src/c.ts. Callers: bin/deploy.sh is touched lightly.'
PLAN_HOT_SIBLING='# Plan AC-2
## Tasks
Edit src/c.ts.
## Sibling claims (not touched)
AC-1 owns bin/deploy.sh.'

: > "$T/all-output.txt"
mkbox

# ---------- F1. same file, local sibling build -> sequenced --------------------
reset
build AC-1 $'# Plan AC-1\nEdit src/app/page.tsx and src/app/x.ts.'
build AC-2 $'# Plan AC-2\nChange src/app/page.tsx.'
po
[ "$RC" = 1 ] && ok || bad "F1: want rc 1, got rc=$RC out=[$OUT] err=[$ERR]"
case "$OUT" in "OVERLAP_DEFER AC-2 vs AC-1 files=[src/app/page.tsx"*) ok ;;
  *) bad "F1: stdout must start 'OVERLAP_DEFER AC-2 vs AC-1 files=[src/app/page.tsx', got [$OUT]" ;; esac
[ "$(arts sequenced)" = 1 ] && ok || bad "F1: want one plan_overlap artifact ref=sequenced, log=[$(cat "$T/artifacts.log" 2>/dev/null)]"
[ "$(arts parallel)" = 0 ] && ok || bad "F1: a sequenced run must not also record parallel"
DET=$(jq -r 'select(.artifact_kind=="plan_overlap") | .detail' "$T/artifacts.log" 2>/dev/null | head -1)
[ "$(printf '%s' "$DET" | jq -r '.project + " " + .other + " " + (.files|index("src/app/page.tsx")|tostring)' 2>/dev/null)" = "acme AC-1 0" ] \
  && ok || bad "F1: artifact detail must name project acme, other AC-1, files [src/app/page.tsx], got [$DET]"

# ---------- F1b. the other side is only a job_claims row -----------------------
reset
claim AC-1 src/app/page.tsx
build AC-2 $'# Plan AC-2\nChange src/app/page.tsx.'
po
[ "$RC" = 1 ] && ok || bad "F1b: want rc 1 on the fleet claim, got rc=$RC out=[$OUT]"
case "$OUT" in "OVERLAP_DEFER AC-2 vs AC-1 files=["*) ok ;; *) bad "F1b: stdout [$OUT]" ;; esac

# ---------- F2. disjoint -> parallel ------------------------------------------
reset
build AC-1 $'# Plan AC-1\nEdit src/a.ts.'
build AC-2 $'# Plan AC-2\nEdit src/b.ts.'
po
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "F2: disjoint must be rc 0 silent, got rc=$RC out=[$OUT]"
[ "$(arts parallel)" = 1 ] && ok || bad "F2: want one plan_overlap artifact ref=parallel, log=[$(cat "$T/artifacts.log" 2>/dev/null)]"
[ "$(arts sequenced)" = 0 ] && ok || bad "F2: no sequenced artifact on a disjoint plan"

# ---------- F3. hotspot named lightly vs an in-flight claim on it --------------
f3() { reset; hot bin/deploy.sh 9; claim AC-1 bin/deploy.sh; build AC-2 "$PLAN_HOT_LIGHT"; }
f3; po
[ "$RC" = 1 ] && ok || bad "F3: want rc 1 (hotspot mention vs claim), got rc=$RC out=[$OUT] err=[$ERR]"
case "$OUT" in "OVERLAP_DEFER AC-2 vs AC-1 files=[bin/deploy.sh"*) ok ;; *) bad "F3: stdout [$OUT]" ;; esac
case "$ERR" in *"PLAN_OVERLAP_HOTSPOT AC-2 vs AC-1 hot=[bin/deploy.sh]"*) ok ;;
  *) bad "F3: stderr must carry 'PLAN_OVERLAP_HOTSPOT AC-2 vs AC-1 hot=[bin/deploy.sh]', got [$ERR]" ;; esac
grep -qx 'src/c.ts' "$CAND/planned-files.txt" && ! grep -q 'deploy' "$CAND/planned-files.txt" \
  && ok || bad "F3: planned-files.txt must stay the allowlist's output (src/c.ts only): [$(cat "$CAND/planned-files.txt")]"
DET=$(jq -r 'select(.artifact_kind=="plan_overlap") | .detail' "$T/artifacts.log" 2>/dev/null | head -1)
[ "$(printf '%s' "$DET" | jq -r '(.hot|join(",")) + " " + .hot_source' 2>/dev/null)" = "bin/deploy.sh rows" ] \
  && ok || bad "F3: artifact detail hot=[bin/deploy.sh] hot_source=rows, got [$DET]"
[ "$(hotgets)" = 1 ] && ok || bad "F3: exactly one hotspot GET, req.log=[$(cat "$T/req.log")]"
grep -q '^GET /api/conflict-hotspots?project=acme&limit=50$' "$T/req.log" && ok || bad "F3: the GET must be project=acme&limit=50: [$(cat "$T/req.log")]"

# ---------- F3s. the in-flight side's plan.md names the hotspot ----------------
f3s() {
  reset; hot bin/deploy.sh 9
  build AC-1 $'# Plan AC-1\nEdit src/z.ts; bin/deploy.sh gets one flag.'
  build AC-2 "$PLAN_HOT_LIGHT"
}
f3s
! grep -q deploy "$W/builds/acme-AC-1-20261007040000/planned-files.txt" && ok || bad "F3s: fixture: AC-1 planned-files must not list the hotspot"
po
[ "$RC" = 1 ] && ok || bad "F3s: want rc 1 (both sides name the hotspot), got rc=$RC out=[$OUT] err=[$ERR]"
case "$OUT" in "OVERLAP_DEFER AC-2 vs AC-1 files=[bin/deploy.sh"*) ok ;; *) bad "F3s: stdout [$OUT]" ;; esac

# ---------- F3b. no hotspot row -> main's behaviour ---------------------------
reset; hot src/other.ts 9; claim AC-1 bin/deploy.sh; build AC-2 "$PLAN_HOT_LIGHT"; po
[ "$RC" = 0 ] && ok || bad "F3b: no hotspot row for bin/deploy.sh must be rc 0, got rc=$RC out=[$OUT]"

# ---------- F3c. the mention is only under Sibling claims ----------------------
reset; hot bin/deploy.sh 9; claim AC-1 bin/deploy.sh; build AC-2 "$PLAN_HOT_SIBLING"; po
[ "$RC" = 0 ] && ok || bad "F3c: a Sibling-claims-only mention must be rc 0, got rc=$RC out=[$OUT]"

# ---------- F3d. below MIN -----------------------------------------------------
reset; hot bin/deploy.sh 1; claim AC-1 bin/deploy.sh; build AC-2 "$PLAN_HOT_LIGHT"; po
[ "$RC" = 0 ] && ok || bad "F3d: conflicts 1 < MIN 2 must be rc 0, got rc=$RC out=[$OUT]"

# ---------- F3e. outage: no cache -> unaugmented; then the cache answers -------
f3; touch "$T/hot-outage"; po
[ "$RC" = 0 ] && ok || bad "F3e: hotspot outage with no cache must be rc 0, got rc=$RC out=[$OUT]"
case "$ERR" in *"PLAN_HOTSPOTS_UNREAD acme"*) ok ;; *) bad "F3e: want PLAN_HOTSPOTS_UNREAD acme on stderr, got [$ERR]" ;; esac
rm -f "$T/hot-outage"; po
[ "$RC" = 1 ] && ok || bad "F3e: a good read must defer, got rc=$RC"
[ -s "$W/state/plan-hotspots/acme.txt" ] && ok || bad "F3e: a good read must write state/plan-hotspots/acme.txt"
rm -f "$T/artifacts.log"; touch "$T/hot-outage"; po
[ "$RC" = 1 ] && ok || bad "F3e: the outage after a good read must defer from the cache, got rc=$RC err=[$ERR]"
case "$ERR" in *"PLAN_HOTSPOTS_CACHED acme"*) ok ;; *) bad "F3e: want PLAN_HOTSPOTS_CACHED acme, got [$ERR]" ;; esac
DET=$(jq -r 'select(.artifact_kind=="plan_overlap") | .detail' "$T/artifacts.log" 2>/dev/null | head -1)
[ "$(printf '%s' "$DET" | jq -r .hot_source 2>/dev/null)" = cache ] && ok || bad "F3e: hot_source must be cache, got [$DET]"

# ---------- F3f. near-miss paths are not the hotspot ---------------------------
reset; hot bin/deploy.sh 9; claim AC-1 bin/deploy.sh
build AC-2 $'# Plan AC-2\nEdit src/c.ts; see bin/deploy.sh.bak, xbin/deploy.sh and old/bin/deploy.sh.'
po
[ "$RC" = 0 ] && ok || bad "F3f: near-miss paths must not mention bin/deploy.sh, got rc=$RC out=[$OUT] err=[$ERR]"

# ---------- F3g. a hotspot with no in-flight claim on it does not defer --------
reset; hot bin/deploy.sh 9; claim AC-1 src/unrelated.ts; build AC-2 "$PLAN_HOT_LIGHT"; po
[ "$RC" = 0 ] && ok || bad "F3g: a hotspot alone (no claim on it) must be rc 0, got rc=$RC out=[$OUT]"
[ "$(arts parallel)" = 1 ] && ok || bad "F3g: a judged rc 0 records parallel"

# ---------- F6. kill switch and TOP=0 ------------------------------------------
f3; po OVERLAP_SCHED=0
[ "$RC" = 0 ] && [ ! -s "$T/req.log" ] && ok || bad "F6: OVERLAP_SCHED=0 must exit 0 with no request, rc=$RC req=[$(cat "$T/req.log" 2>/dev/null)]"
[ "$(arts sequenced)$(arts parallel)" = 00 ] && ok || bad "F6: the kill switch records no decision"
f3; po PLAN_OVERLAP_HOTSPOT_TOP=0
[ "$RC" = 0 ] && ok || bad "F6: TOP=0 turns hotspots off, F3's shape must be rc 0, got rc=$RC"
[ "$(hotgets)" = 0 ] && ok || bad "F6: TOP=0 must make no hotspot GET: [$(cat "$T/req.log")]"
f3; po PLAN_OVERLAP_HOTSPOT_TOP=9999
[ "$RC" = 0 ] && [ "$(hotgets)" = 0 ] && ok || bad "F6: an out-of-range TOP is off (no GET, rc 0), got rc=$RC gets=$(hotgets)"
case "$ERR" in *"PLAN_HOTSPOTS_BADKNOB PLAN_OVERLAP_HOTSPOT_TOP=9999"*) ok ;; *) bad "F6: want the BADKNOB line, got [$ERR]" ;; esac

# ---------- F4. plan.sh publishes the hotspot mention in the claim -------------
RB=$(rb_all "$DIR" "$T/run-build.all.sh") || { echo "FAIL: rb_all could not flatten the pipeline"; exit 1; }
region() { sed -n "/^# >>> $1\$/,/^# <<< $1\$/p" "$RB"; }
CP_LINE=$(grep -m1 -F 'cp "$BUILD/planned-files.txt" "$HARNESS/state/claims/$PROJECT/$KEY"' "$RB")
HC=$(region 'hotspot claim'); FCDB=$(region 'file claim db')
[ -n "$CP_LINE" ] && ok || bad "F4: the local claims cp line is gone"
[ -n "$HC" ] && ok || bad "F4: no '# >>> hotspot claim' region in the pipeline"
[ -n "$FCDB" ] && ok || bad "F4: no '# >>> file claim db' region in the pipeline"
L_CP=$(grep -n -m1 -F "$CP_LINE" "$RB" | cut -d: -f1)
L_HC=$(grep -n -m1 '^# >>> hotspot claim$' "$RB" | cut -d: -f1)
L_DB=$(grep -n -m1 '^# >>> file claim db$' "$RB" | cut -d: -f1)
[ -n "$L_HC" ] && [ "$L_CP" -lt "$L_HC" ] && [ "$L_HC" -lt "$L_DB" ] && ok \
  || bad "F4: order must be local cp < hotspot claim < file claim db (cp=$L_CP hc=${L_HC:-?} db=$L_DB)"
H4="$T/h4"; scratch_rm "$H4"; mkdir -p "$H4/bin/lib"
cat > "$H4/bin/lib/file-claims.sh" <<EOF
fclaim_put() { echo "fclaim_put \$*" >> "$T/fc.log"; cp "\$1" "$T/fc-arg.txt"; return 0; }
EOF
cp "$STUB" "$H4/bin/jobs-client.sh"
scratch_install_closure bin/lib/plan-hotspots.sh "$H4" >/dev/null || bad "F4: closure of bin/lib/plan-hotspots.sh"
F4S="$T/f4.sh"
{ echo 'set -uo pipefail'; echo 'STAMP() { echo stamp; }'
  echo '. "$HARNESS/bin/jobs-client.sh"'
  echo 'mkdir -p "$HARNESS/state/claims/$PROJECT"'
  echo "$CP_LINE"; printf '%s\n' "$HC" "$FCDB"; echo 'echo DONE'; } > "$F4S"
bash -n "$F4S" && ok || bad "F4: the extracted regions are not valid bash"
run_f4() { # run_f4 <plan-text> -> B4 build dir
  B4="$T/b4"; scratch_rm "$B4"; scratch_rm "$H4/state"; mkdir -p "$B4"
  rm -f "$T/fc.log" "$T/fc-arg.txt" "$T/req.log"
  printf '%s\n' "$1" > "$B4/plan.md"
  bash "$DIR/bin/planned-files.sh" "$B4"; cp "$B4/planned-files.txt" "$T/pf.before"
  F4OUT=$(env HARNESS="$H4" PROJECT=acme KEY=AC-2 BUILD="$B4" JOB_ID=job-2 JOBS_URL=https://jobs.test bash "$F4S" 2>&1)
  printf '%s\n' "$F4OUT" >> "$T/all-output.txt"
}
reset; hot bin/deploy.sh 9; run_f4 "$PLAN_HOT_LIGHT"
case "$F4OUT" in *DONE*) ok ;; *) bad "F4: the regions did not run to the end: [$F4OUT]" ;; esac
grep -qx 'bin/deploy.sh' "$H4/state/claims/acme/AC-2" && grep -qx 'src/c.ts' "$H4/state/claims/acme/AC-2" \
  && ok || bad "F4: the local claim must carry src/c.ts AND bin/deploy.sh: [$(cat "$H4/state/claims/acme/AC-2" 2>/dev/null)]"
grep -qx "fclaim_put $B4/claim-files.txt" "$T/fc.log" 2>/dev/null && ok || bad "F4: fclaim_put must get claim-files.txt: [$(cat "$T/fc.log" 2>/dev/null)]"
grep -qx 'bin/deploy.sh' "$T/fc-arg.txt" 2>/dev/null && ok || bad "F4: the published job_claims list must carry bin/deploy.sh"
cmp -s "$T/pf.before" "$B4/planned-files.txt" && ok || bad "F4: planned-files.txt must be byte-identical"
grep -q 'HOTSPOT_CLAIM n=1 source=rows$' "$B4/pipeline.log" 2>/dev/null && ok || bad "F4: pipeline.log HOTSPOT_CLAIM n=1 source=rows: [$(cat "$B4/pipeline.log" 2>/dev/null)]"
# F4b. nothing to add: the claim is exactly today's.
reset; hot bin/deploy.sh 9; run_f4 $'# Plan\nEdit src/c.ts.'
grep -qx "fclaim_put $B4/planned-files.txt" "$T/fc.log" 2>/dev/null && ok || bad "F4b: no mention -> fclaim_put planned-files.txt: [$(cat "$T/fc.log" 2>/dev/null)]"
[ ! -e "$B4/claim-files.txt" ] && cmp -s "$B4/planned-files.txt" "$H4/state/claims/acme/AC-2" && ok || bad "F4b: no mention -> local claim == planned-files.txt, no claim-files.txt"
grep -q 'HOTSPOT_CLAIM n=0 source=rows$' "$B4/pipeline.log" && ok || bad "F4b: want n=0 source=rows: [$(cat "$B4/pipeline.log" 2>/dev/null)]"
# F4c. hotspot outage, no cache: today's claim, source=none.
reset; hot bin/deploy.sh 9; touch "$T/hot-outage"; run_f4 "$PLAN_HOT_LIGHT"
grep -qx "fclaim_put $B4/planned-files.txt" "$T/fc.log" 2>/dev/null && ok || bad "F4c: outage -> fclaim_put planned-files.txt: [$(cat "$T/fc.log" 2>/dev/null)]"
grep -q 'HOTSPOT_CLAIM n=0 source=none$' "$B4/pipeline.log" && ok || bad "F4c: want n=0 source=none: [$(cat "$B4/pipeline.log" 2>/dev/null)]"

# ---------- F5. nothing says Blocked-by ---------------------------------------
grep -qi 'blocked-by' "$T/all-output.txt" && bad "F5: an output stream or artifact body says Blocked-by" || ok
[ -s "$T/all-output.txt" ] && ok || bad "F5: nothing was collected to check"

# ---------- H. the lib's units -------------------------------------------------
# Each case runs in its own bash with the REAL lib and the stub _jobs_req.
lib() { # lib <bash-snippet> [env...] -> LOUT LERR LRC
  local snip="$1"; shift
  LOUT=$(env HARNESS="$W" "$@" bash -c '. "$HARNESS/bin/jobs-client.sh"; . "$0"; '"$snip" "$LIB" 2>"$T/lerr.txt")
  LRC=$?; LERR=$(cat "$T/lerr.txt")
}
# H1 contract: a 200 that is not {hotspots:[...]} is an outage, not "none".
reset; echo '{"hotspots":"nope"}' > "$T/hot.json"
lib 'ph_hot_list acme "$HARNESS/h1.txt"; echo "rc=$? src=$PH_SOURCE"'
[ "$LOUT" = "rc=1 src=none" ] && ok || bad "H1: non-array hotspots must be rc 1 src=none, got [$LOUT] err=[$LERR]"
[ ! -e "$W/state/plan-hotspots/acme.txt" ] && ok || bad "H1: a non-contract answer must not write the cache"
# H2 MIN filter, H3 path validation.
reset; hot bin/deploy.sh 9 src/one.ts 1 ../x 9 /etc/passwd 9 "" 9 a//b.sh 9 'bin/x;rm.sh' 9 "$(printf 'ok.sh\nevil.sh')" 9 lib/ok-2.ts 2
lib 'ph_hot_list acme "$HARNESS/h2.txt"; echo "rc=$?"; cat "$HARNESS/h2.txt"'
[ "$LOUT" = $'rc=0\nbin/deploy.sh\nlib/ok-2.ts' ] && ok || bad "H2/H3: want only bin/deploy.sh and lib/ok-2.ts, got [$LOUT]"
lib 'ph_hot_list acme "$HARNESS/h2.txt"; cat "$HARNESS/h2.txt"' PLAN_OVERLAP_HOTSPOT_MIN=9
[ "$LOUT" = 'bin/deploy.sh' ] && ok || bad "H2: MIN=9 keeps only conflicts>=9, got [$LOUT]"
# H4 cache: written on success only; an answered-empty list is an answer.
cmp -s <(printf 'bin/deploy.sh\n') "$W/state/plan-hotspots/acme.txt" && ok || bad "H4: the cache must hold the last good list: [$(cat "$W/state/plan-hotspots/acme.txt" 2>/dev/null)]"
touch "$T/hot-outage"
lib 'ph_hot_list acme "$HARNESS/h4.txt"; echo "rc=$? src=$PH_SOURCE"; cat "$HARNESS/h4.txt"'
[ "$LOUT" = $'rc=0 src=cache\nbin/deploy.sh' ] && ok || bad "H4: outage must answer from the cache, got [$LOUT]"
lib 'ph_hot_list other "$HARNESS/h4.txt"; echo "rc=$? src=$PH_SOURCE"'
[ "$LOUT" = "rc=1 src=none" ] && ok || bad "H4: another project never reads acme's cache, got [$LOUT]"
case "$LERR" in *"PLAN_HOTSPOTS_UNREAD other"*) ok ;; *) bad "H4: want PLAN_HOTSPOTS_UNREAD other, got [$LERR]" ;; esac
rm -f "$T/hot-outage"; hot
lib 'ph_hot_list acme "$HARNESS/h4.txt"; echo "rc=$? src=$PH_SOURCE"; wc -c < "$HARNESS/h4.txt"'
[ "$LOUT" = $'rc=0 src=rows\n0' ] && ok || bad "H4: an answered-empty list is rc 0 and empty, got [$LOUT]"
[ ! -s "$W/state/plan-hotspots/acme.txt" ] && ok || bad "H4: the answered-empty list replaces the cache"
lib 'ph_hot_list "../x" "$HARNESS/h4.txt"; echo "rc=$?"'
[ "$LOUT" = "rc=1" ] && ! grep -q 'project=\.\./x' "$T/req.log" && ok || bad "H4: a bad project name never reaches the URL, got [$LOUT]"
# H5 TOP=0 through the DB knob (a fake lib_env_apply standing in for lane-gate's).
reset; hot bin/deploy.sh 9
lib 'lib_env_apply() { [ "$1" = plan-overlap-hotspots ] && [ "$2" = acme ] && export PLAN_OVERLAP_HOTSPOT_TOP=0; }; ph_hot_list acme "$HARNESS/h5.txt"; echo "rc=$?"'
[ "$LOUT" = "rc=1" ] && [ "$(hotgets)" = 0 ] && ok || bad "H5: a settings row TOP=0 must be off with no GET, got [$LOUT] gets=$(hotgets)"
lib 'lib_env_apply() { export PLAN_OVERLAP_HOTSPOT_TOP=7; }; ph_hot_list acme "$HARNESS/h5.txt"; echo "rc=$?"'
grep -q 'limit=7$' "$T/req.log" && ok || bad "H5: the knob's TOP=7 must reach the GET: [$(cat "$T/req.log")]"
# H6 bad knob -> off, never clamped.
for kv in PLAN_OVERLAP_HOTSPOT_TOP=abc PLAN_OVERLAP_HOTSPOT_TOP=501 PLAN_OVERLAP_HOTSPOT_MIN=0 PLAN_OVERLAP_HOTSPOT_MIN=-3; do
  rm -f "$T/req.log"
  lib 'ph_hot_list acme "$HARNESS/h6.txt"; echo "rc=$?"' "$kv"
  [ "$LOUT" = "rc=1" ] && [ "$(hotgets)" = 0 ] && ok || bad "H6: $kv must be off with no GET, got [$LOUT]"
  case "$LERR" in *"PLAN_HOTSPOTS_BADKNOB $kv"*) ok ;; *) bad "H6: $kv: want BADKNOB line, got [$LERR]" ;; esac
done
# H7 mention boundaries.
printf 'bin/deploy.sh\nsrc/app/page.tsx\nnext.config.js\n' > "$T/h7.hot"
cat > "$T/h7.md" <<'EOF'
# Plan
Touch `bin/deploy.sh`.
Not bin/deploy.sh.bak, not xbin/deploy.sh, not old/bin/deploy.sh, not src/app/page.tsx-old.
Root file next.config.js, at the end of a sentence.
## Sibling claims (not touched)
src/app/page.tsx belongs to AC-9.
### Task 1
EOF
lib "ph_mentions '$T/h7.md' '$T/h7.hot'"
[ "$LOUT" = $'bin/deploy.sh\nnext.config.js' ] && ok || bad "H7: want bin/deploy.sh and next.config.js only, got [$LOUT]"
printf '# Plan\nonly old/bin/deploy.sh and bin/deploy.sh.bak\n' > "$T/h7b.md"
lib "ph_mentions '$T/h7b.md' '$T/h7.hot'"
[ -z "$LOUT" ] && ok || bad "H7: near misses only must print nothing, got [$LOUT]"

# ---------- M. mutants ---------------------------------------------------------
# M0: main's plan-overlap.sh, while main still predates this lib, leaves F3 rc 0.
MAIN_PO="$T/main-plan-overlap.sh"
if git -C "$DIR" show origin/main:bin/plan-overlap.sh > "$MAIN_PO" 2>/dev/null; then
  if grep -q 'plan-hotspots' "$MAIN_PO"; then
    echo "note: M0 skipped, origin/main's plan-overlap.sh already carries plan-hotspots"
  else
    mkbox "$MAIN_PO"; f3; po
    [ "$RC" = 0 ] && ok || bad "M0: main's plan-overlap.sh must NOT defer F3 (the test would be vacuous), got rc=$RC"
  fi
else
  echo "note: M0 skipped, origin/main is not available in this checkout"
fi
mutant() { # mutant <sed-expr> -> $T/mut.sh, rc 1 when the expression changed nothing
  sed "$1" "$DIR/bin/plan-overlap.sh" > "$T/mut.sh"
  if cmp -s "$T/mut.sh" "$DIR/bin/plan-overlap.sh"; then bad "mutant: '$1' did not apply"; return 1; fi
  mkbox "$T/mut.sh"
}
# M1: the candidate-side union removed -> F3 goes red.
if mutant 's/^ph_union "\$CFILES" "\$PHD\/cand-hot" "\$CAND"/cp "$CFILES" "$CAND"/'; then
  f3; po
  [ "$RC" = 0 ] && ok || bad "M1: without the candidate hotspot union F3 must not defer, got rc=$RC"
fi
# M2: the local-sibling union removed -> F3s goes red.
if mutant 's/^  ph_union "\$D\/planned-files.txt" "\$PHD\/other-hot" "\$PHD\/other"/  cp "$D\/planned-files.txt" "$PHD\/other"/'; then
  f3s; po
  [ "$RC" = 0 ] && ok || bad "M2: without the sibling plan.md union F3s must not defer, got rc=$RC"
fi
# M3: the decision record neutered -> F1's artifact assertion goes red.
if mutant 's/^po_record() {$/po_record() { return 0/'; then
  reset
  build AC-1 $'# Plan AC-1\nEdit src/app/page.tsx.'
  build AC-2 $'# Plan AC-2\nChange src/app/page.tsx.'
  po
  [ "$(arts sequenced)" = 0 ] && ok || bad "M3: with po_record neutered no artifact may appear"
fi
mkbox

echo "plan-overlap-fleet.bh-5268: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
