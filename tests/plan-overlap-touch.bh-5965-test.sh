#!/bin/bash
# tests/plan-overlap-touch.bh-5965-test.sh — the overlap guard and the claim use
# the files a plan DECLARES (## Files to touch), not every path it mentions
# (BH-5965).
#
# The REAL bin/plan-overlap.sh, bin/touch-files.sh, bin/planned-files.sh,
# bin/plan-sibling.sh and bin/conflict-check.sh run in scratch boxes for the
# fixture project `acme`. The jobs stub is bh-5268's: _jobs_req serves
# GET /api/file-claims from fixture JSON and takes PUT .../artifacts.
#
#   P1  TK-35 / TK-36 declare different src/ files, both name
#       scripts/checks/company-query.mjs only in prose and under Not touched -> no defer
#   P1b the candidate has no touch-source yet: plan-overlap writes it and still does not defer
#   P2  the other side is only a job_claims row: narrowed list, and an old broad claim -> no defer
#   P3  both declare company-query.mjs under Modified -> OVERLAP_DEFER, stdout unchanged
#   P4  one side declares it, the other only mentions it -> no defer, both directions
#   P5  no declared section on either side -> today's defer
#   P6  kill switch (env and settings row) -> P1 defers as today
#   P7  P3's OVERLAP_DEFER_SRC line in pipeline.log names the declared line; stderr has none
#   P8  P3's plan_overlap artifact carries src and touch_source
#   S1  plan-sibling.sh check: declared set disjoint from the sibling PR -> build
#   C1  conflict-check.sh: declared and disjoint, mentions overlap -> 0; C2 declared overlap -> 1
#   C3  undeclared -> today's conflict; C4 / C5 one side declared -> judged on its own list
#   R1  the pipeline has `# >>> touch claim` between hotspot claim and file claim db
#   R2  the region publishes touch-files.txt as the local claim and to fclaim_put
#   R3  an undeclared plan leaves the claim as it was
#   R4  a test reroute is applied to the declared claim
#   M1  plan-overlap.sh with the candidate selector removed turns P2 red
#   M2  plan-overlap.sh with the sibling selector removed turns P4 red
#
# No network, no gh, no LLM.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/rb-all.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

W="$T/W"
STUB="$T/jobs-client.stub.sh"
cat > "$STUB" <<SH
JOBS_BOX=box-test
[ -r "\$HARNESS/bin/lib/jobs/jobs.sh" ] && . "\$HARNESS/bin/lib/jobs/jobs.sh"
_jobs_req() {
  printf '%s %s\n' "\$1" "\$2" >> "$T/req.log"
  case "\$1 \$2" in
    "GET /api/file-claims?project=acme") cat "$T/claims.json" ;;
    "GET /api/conflict-hotspots?project=acme&limit="*) cat "$T/hot.json" ;;
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
  scratch_install_closure bin/touch-files.sh "$W" >/dev/null || bad "mkbox: closure of bin/touch-files.sh"
  scratch_install_closure bin/planned-files.sh "$W" >/dev/null || bad "mkbox: closure of bin/planned-files.sh"
  scratch_install_closure bin/conflict-check.sh "$W" >/dev/null || bad "mkbox: closure of bin/conflict-check.sh"
  scratch_install_closure bin/lib/jobs/jobs.sh "$W" >/dev/null || bad "mkbox: closure of bin/lib/jobs/jobs.sh"
  printf 'acme  example-org/acme   -  -  0 local -\n' > "$W/fleet.conf"
}
reset() {
  scratch_rm "$W/builds"; scratch_rm "$W/state"
  mkdir -p "$W/builds" "$W/state/claims/acme"
  rm -f "$T/req.log" "$T/artifacts.log"
  echo '{"claims":[],"truncated":false}' > "$T/claims.json"
  echo '{"project":"acme","run":null,"hotspots":[],"total":0,"truncated":false}' > "$T/hot.json"
}
claim() { # claim <KEY> <file>... -> one earlier job_claims row
  local K="$1"; shift
  jq -cn --arg k "$K" --arg f "$(printf '%s\n' "$@")" \
    '{claims:[{ticket_id:$k, box:"pool-x", status:"running", files_claimed_at:"2026-10-07T03:00:00Z", planned_files:$f}], truncated:false}' \
    > "$T/claims.json"
}
bdir() { echo "$W/builds/acme-$1-20261010040000"; }
build() { # build <KEY> <plan-text> -> a live build dir, lists written by the REAL scripts (as plan.sh does)
  local D; D=$(bdir "$1")
  scratch_rm "$D"; mkdir -p "$D"
  printf '%s\n' "$2" > "$D/plan.md"
  printf '{"key":"%s"}\n' "$1" > "$D/ticket-meta.json"
  bash "$W/bin/planned-files.sh" "$D"
  env HARNESS="$W" bash "$W/bin/touch-files.sh" "$D" acme
}
po() { # po <KEY> [env...] -> plan-overlap on that build; sets RC OUT ERR
  local K="$1"; shift
  rm -f "$(bdir "$K")/pipeline.log"
  OUT=$(env HARNESS="$W" JOB_ID=job-1 "$@" bash "$W/bin/plan-overlap.sh" acme "$(bdir "$K")" 2>"$T/err.txt")
  RC=$?; ERR=$(cat "$T/err.txt"); PLOG=$(cat "$(bdir "$K")/pipeline.log" 2>/dev/null)
}

Q=scripts/checks/company-query.mjs
plan_mention() { # plan_mention <KEY> <own file> — declares one file, names $Q only in prose and under Not touched
  printf '# Plan %s\n## Files to touch\n- `%s` (Modified)\n\nNot touched: `%s`\n\n## Tasks\nAdd the table. `%s` is the check that covers new tables.\n' "$1" "$2" "$Q" "$Q"
}
plan_modify() { # plan_modify <KEY> <own file> — declares $Q under Modified
  printf '# Plan %s\n## Files to touch\n- `%s` (Modified)\n- `%s` (Modified) — the new table joins the check\n\n## Tasks\nEdit both.\n' "$1" "$2" "$Q"
}
plan_bare() { # plan_bare <KEY> <own file> — no declared section
  printf '# Plan %s\n## Tasks\nEdit `%s`. `%s` is the check that covers new tables.\n' "$1" "$2" "$Q"
}
p1() { reset; build TK-35 "$(plan_mention TK-35 src/a.ts)"; build TK-36 "$(plan_mention TK-36 src/b.ts)"; }

mkbox

# ---------- P1. mentions only -> no defer, both directions ---------------------
p1
grep -qxF "$Q" "$(bdir TK-35)/planned-files.txt" && grep -qxF "$Q" "$(bdir TK-36)/planned-files.txt" && ok \
  || bad "P1: fixture: both planned-files.txt must list $Q (the mention superset)"
po TK-35
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "P1: TK-35 vs TK-36 must be rc 0 silent, got rc=$RC out=[$OUT] err=[$ERR]"
po TK-36
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "P1: TK-36 vs TK-35 must be rc 0 silent, got rc=$RC out=[$OUT]"

# ---------- P1b. plan-overlap writes the candidate's touch-source ----------------
p1; rm -f "$(bdir TK-35)/touch-source" "$(bdir TK-35)/touch-files.txt" "$(bdir TK-35)/touch-files.src"
po TK-35
[ "$RC" = 0 ] && ok || bad "P1b: with no touch-source the guard must extract it and not defer, got rc=$RC out=[$OUT]"
[ "$(cat "$(bdir TK-35)/touch-source" 2>/dev/null)" = declared ] && ok || bad "P1b: plan-overlap must write touch-source=declared"
# ... and never re-runs it when touch-source exists (a th_apply'd list survives).
printf 'src/rerouted.ts\n' > "$(bdir TK-35)/touch-files.txt"
po TK-35
[ "$(cat "$(bdir TK-35)/touch-files.txt")" = src/rerouted.ts ] && ok || bad "P1b: an existing touch-source must not be re-extracted"

# ---------- P2. job_claims side -----------------------------------------------
reset; claim TK-36 src/b.ts; build TK-35 "$(plan_mention TK-35 src/a.ts)"
po TK-35
[ "$RC" = 0 ] && ok || bad "P2: a narrowed job_claims row must not defer, got rc=$RC out=[$OUT]"
reset; claim TK-36 src/b.ts "$Q"; build TK-35 "$(plan_mention TK-35 src/a.ts)"
po TK-35
[ "$RC" = 0 ] && ok || bad "P2: an old broad claim on $Q must not defer a candidate that only mentions it, got rc=$RC out=[$OUT]"

# ---------- P3. both declare it -> defer ----------------------------------------
p3() { reset; build TK-35 "$(plan_modify TK-35 src/a.ts)"; build TK-36 "$(plan_modify TK-36 src/b.ts)"; }
p3; po TK-35
[ "$RC" = 1 ] && ok || bad "P3: both declare $Q -> rc 1, got rc=$RC out=[$OUT] err=[$ERR]"
case "$OUT" in "OVERLAP_DEFER TK-35 vs TK-36 files=[$Q"*) ok ;;
  *) bad "P3: stdout must start 'OVERLAP_DEFER TK-35 vs TK-36 files=[$Q', got [$OUT]" ;; esac
[ "$(printf '%s\n' "$OUT" | grep -c .)" = 1 ] && ok || bad "P3: stdout must stay one line"

# ---------- P7. the source trace -------------------------------------------------
LQ=$(grep -nF -- "$Q" "$(bdir TK-35)/plan.md" | head -1 | cut -d: -f1)
SRCL=$(printf '%s\n' "$PLOG" | grep '^OVERLAP_DEFER_SRC ')
[ "$(printf '%s\n' "$SRCL" | grep -c .)" = 1 ] && ok || bad "P7: want exactly one OVERLAP_DEFER_SRC line in pipeline.log, log=[$PLOG]"
case "$ERR" in *OVERLAP_DEFER_SRC*) bad "P7: the trace goes to pipeline.log, not stderr: [$ERR]" ;; *) ok ;; esac
[ "$SRCL" = "OVERLAP_DEFER_SRC TK-35 vs TK-36 touch=declared src=[$Q@L$LQ:declared]" ] && ok \
  || bad "P7: want 'OVERLAP_DEFER_SRC TK-35 vs TK-36 touch=declared src=[$Q@L$LQ:declared]', got [$SRCL]"

# ---------- P8. the artifact ----------------------------------------------------
DET=$(jq -r 'select(.artifact_kind=="plan_overlap" and .artifact_ref=="sequenced") | .detail' "$T/artifacts.log" 2>/dev/null | head -1)
case "$(printf '%s' "$DET" | jq -r '.src[0] // empty' 2>/dev/null)" in "$Q@L"*) ok ;; *) bad "P8: .src[0] must start '$Q@L', detail=[$DET]" ;; esac
[ "$(printf '%s' "$DET" | jq -r '.touch_source' 2>/dev/null)" = declared ] && ok || bad "P8: .touch_source must be declared, detail=[$DET]"
[ "$(printf '%s' "$DET" | jq -r '(.files|index("'"$Q"'")|tostring) + " " + .other' 2>/dev/null)" = "0 TK-36" ] && ok \
  || bad "P8: .files and .other must still be present, detail=[$DET]"

# ---------- P4. mixed: one side declares, the other mentions ---------------------
reset; build TK-35 "$(plan_modify TK-35 src/a.ts)"; build TK-36 "$(plan_mention TK-36 src/b.ts)"
po TK-35
[ "$RC" = 0 ] && ok || bad "P4: candidate declares, sibling only mentions -> rc 0, got rc=$RC out=[$OUT]"
po TK-36
[ "$RC" = 0 ] && ok || bad "P4: sibling declares, candidate only mentions -> rc 0, got rc=$RC out=[$OUT]"

# ---------- P5. undeclared plans keep today's behaviour ----------------------------
reset; build TK-35 "$(plan_bare TK-35 src/a.ts)"; build TK-36 "$(plan_bare TK-36 src/b.ts)"
[ "$(cat "$(bdir TK-35)/touch-source")" = none ] && ok || bad "P5: fixture must be touch-source=none"
po TK-35
[ "$RC" = 1 ] && ok || bad "P5: two undeclared plans that mention $Q must defer, got rc=$RC out=[$OUT]"
case "$PLOG" in *"OVERLAP_DEFER_SRC TK-35 vs TK-36 touch=none src=[$Q@L"*":mention]"*) ok ;;
  *) bad "P5: the trace must say touch=none and :mention, log=[$PLOG]" ;; esac

# ---------- P6. kill switch -------------------------------------------------------
p1; po TK-35 PLAN_TOUCH_DECLARED=0
[ "$RC" = 1 ] && ok || bad "P6: PLAN_TOUCH_DECLARED=0 must defer P1 as today, got rc=$RC out=[$OUT]"
case "$PLOG" in *"touch=off"*) ok ;; *) bad "P6: the trace must say touch=off, log=[$PLOG]" ;; esac
p1; jq -nc '{fetched_at:1760000000, values:{"switch.plan-touch-off":"1"}, seeded:{}}' > "$W/state/settings-cache.json"
po TK-35 LANE_GATE_NOW=1760000010
[ "$RC" = 1 ] && ok || bad "P6: settings row switch.plan-touch-off=1 must defer P1 as today, got rc=$RC out=[$OUT]"
rm -f "$W/state/settings-cache.json"

# ---------- C1 / C2. conflict-check.sh -----------------------------------------------
cc() { OUT=$(env HARNESS="$W" bash "$W/bin/conflict-check.sh" acme "$(bdir "$1")"); RC=$?; }
p1; cc TK-35
[ "$RC" = 0 ] && ok || bad "C1: declared and disjoint must be rc 0, got rc=$RC out=[$OUT]"
p3; cc TK-35
[ "$RC" = 1 ] && ok || bad "C2: declared overlap must be rc 1, got rc=$RC"
case "$OUT" in "CONFLICT with acme-TK-36-20261010040000: $Q ~ $Q") ok ;; *) bad "C2: want 'CONFLICT with ...: $Q ~ $Q', got [$OUT]" ;; esac
reset; build TK-35 "$(plan_bare TK-35 src/a.ts)"; build TK-36 "$(plan_bare TK-36 src/b.ts)"; cc TK-35
[ "$RC" = 1 ] && ok || bad "C3: undeclared plans keep today's conflict, got rc=$RC"
# C4 / C5: each side is chosen on its own (one declared, one not).
reset; build TK-35 "$(plan_mention TK-35 src/a.ts)"; build TK-36 "$(plan_bare TK-36 src/b.ts)"; cc TK-35
[ "$RC" = 0 ] && ok || bad "C4: a declared candidate is judged on its touch list, got rc=$RC out=[$OUT]"
reset; build TK-35 "$(plan_bare TK-35 src/a.ts)"; build TK-36 "$(plan_mention TK-36 src/b.ts)"; cc TK-35
[ "$RC" = 0 ] && ok || bad "C5: a declared in-flight build is judged on its touch list, got rc=$RC out=[$OUT]"

# ---------- S1. plan-sibling.sh check ----------------------------------------------
H="$T/hs"; scratch_rm "$H"
mkdir -p "$H/bin/lib" "$H/env" "$H/flags" "$H/logs" "$H/fx" "$T/stub"
printf 'cromford  example-org/cromford  -  -     0 local -\n' > "$H/fleet.conf"
cat > "$H/bin/lib/gh-rest-list.sh" <<'SH'
gh_rest_issue_list() { cat "$HARNESS/fx/issues.json"; }
gh_rest_pr_list_all() { cat "$HARNESS/fx/pulls.json"; }
gh_rest() {
  local n
  case "$2" in repos/example-org/cromford/pulls/*/files) ;; *) return 75 ;; esac
  n=${2#repos/example-org/cromford/pulls/}; n=${n%/files}
  cat "$HARNESS/fx/files.$n.json"
}
gh_rest_comment() { return 0; }
SH
printf '#!/bin/bash\nexit 99\n' > "$T/stub/gh"; chmod +x "$T/stub/gh"
scratch_install_closure bin/plan-sibling.sh "$H" >/dev/null || bad "S1: closure of bin/plan-sibling.sh"
scratch_install_closure bin/touch-files.sh "$H" >/dev/null || bad "S1: closure of bin/touch-files.sh"
scratch_install_closure bin/planned-files.sh "$H" >/dev/null || bad "S1: closure of bin/planned-files.sh"
[ -e "$H/bin/fleet-conf.sh" ] || cp "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"
sib_body() { printf 'Scope for this slice.\n\n---\nPart of #%s\nOrder: %s of 3\n' "$1" "$2"; }
jq -c --arg b "$(sib_body 4975 2)" '[{number:5000,title:"slice",body:$b,state:"open"},{number:5001,title:"slice",body:$b,state:"open"}]' -n > "$H/fx/issues.json"
printf '[{"number":900,"state":"open","head":{"ref":"ticket/bh-5000"}}]\n' > "$H/fx/pulls.json"
printf '[{"filename":"%s","status":"modified"}]\n' "$Q" > "$H/fx/files.900.json"
SB="$T/sb"
sib() { # sib <plan-text> -> plan-sibling check on $SB
  scratch_rm "$SB"; mkdir -p "$SB"
  printf '%s\n' "$1" > "$SB/plan.md"
  jq -n --arg b "$(sib_body 4975 3)" '{key:"BH-5001",body:$b}' > "$SB/ticket-meta.json"
  bash "$H/bin/planned-files.sh" "$SB"
  env HARNESS="$H" bash "$H/bin/touch-files.sh" "$SB" cromford
  OUT=$(env HARNESS="$H" FLEET_CONF="$H/fleet.conf" PATH="$T/stub:$PATH" bash "$H/bin/plan-sibling.sh" check cromford "$SB" 2>"$T/serr")
  RC=$?
}
sib "$(plan_mention BH-5001 src/a.ts)"
grep -qxF "$Q" "$SB/planned-files.txt" && ok || bad "S1: fixture: planned-files.txt must list $Q"
[ "$RC" = 0 ] && ok || bad "S1: declared set disjoint from the sibling PR must build, got rc=$RC out=[$OUT] err=[$(cat "$T/serr")]"
sib "$(plan_modify BH-5001 src/a.ts)"
[ "$RC" = 1 ] && ok || bad "S1: a declared $Q vs the sibling PR must defer, got rc=$RC out=[$OUT] err=[$(cat "$T/serr")]"
case "$OUT" in "OVERLAP_DEFER BH-5001 vs BH-5000 files=[$Q"*) ok ;; *) bad "S1: stdout [$OUT]" ;; esac

# ---------- R. bin/lib/rb/plan.sh publishes the declared claim --------------------
RB=$(rb_all "$DIR" "$T/run-build.all.sh") || { echo "FAIL: rb_all could not flatten the pipeline"; exit 1; }
region() { sed -n "/^# >>> $1\$/,/^# <<< $1\$/p" "$RB"; }
L_HC=$(grep -n -m1 '^# <<< hotspot claim$' "$RB" | cut -d: -f1)
L_TC=$(grep -n -m1 '^# >>> touch claim$' "$RB" | cut -d: -f1)
L_DB=$(grep -n -m1 '^# >>> file claim db$' "$RB" | cut -d: -f1)
[ -n "$L_HC" ] && [ -n "$L_TC" ] && [ -n "$L_DB" ] && [ "$L_HC" -lt "$L_TC" ] && [ "$L_TC" -lt "$L_DB" ] && ok \
  || bad "R1: order must be <<< hotspot claim < >>> touch claim < >>> file claim db (hc=${L_HC:-?} tc=${L_TC:-?} db=${L_DB:-?})"
CP_LINE=$(grep -m1 -F 'cp "$BUILD/planned-files.txt" "$HARNESS/state/claims/$PROJECT/$KEY"' "$RB")
TC=$(region 'touch claim'); FCDB=$(region 'file claim db')
H4="$T/h4"; scratch_rm "$H4"; mkdir -p "$H4/bin/lib"
cat > "$H4/bin/lib/file-claims.sh" <<EOF
fclaim_put() { echo "fclaim_put \$*" >> "$T/fc.log"; cp "\$1" "$T/fc-arg.txt"; return 0; }
EOF
scratch_install_closure bin/touch-files.sh "$H4" >/dev/null || bad "R: closure of bin/touch-files.sh"
scratch_install_closure bin/lib/test-home-lib.sh "$H4" >/dev/null || bad "R: closure of bin/lib/test-home-lib.sh"
R4S="$T/r.sh"
{ echo 'set -uo pipefail'; echo 'STAMP() { echo stamp; }'
  echo '. "$HARNESS/bin/lib/test-home-lib.sh"'
  echo 'mkdir -p "$HARNESS/state/claims/$PROJECT"'
  echo "$CP_LINE"; echo 'CLAIM_FILES=""'; printf '%s\n' "$TC" "$FCDB"; echo 'echo DONE'; } > "$R4S"
bash -n "$R4S" && ok || bad "R: the extracted regions are not valid bash"
run_r() { # run_r <plan-text> [reroute-record] -> RB4 build dir
  RB4="$T/rb4"; scratch_rm "$RB4"; scratch_rm "$H4/state"; mkdir -p "$RB4"
  rm -f "$T/fc.log" "$T/fc-arg.txt"
  printf '%s\n' "$1" > "$RB4/plan.md"
  [ -n "${2:-}" ] && printf '%s\n' "$2" > "$RB4/test-reroute.txt"
  bash "$DIR/bin/planned-files.sh" "$RB4"
  ROUT=$(env HARNESS="$H4" PROJECT=acme KEY=TK-35 BUILD="$RB4" JOB_ID=job-1 JOBS_URL=https://jobs.test bash "$R4S" 2>&1)
}
run_r "$(plan_mention TK-35 src/a.ts)"
case "$ROUT" in *DONE*) ok ;; *) bad "R2: the regions did not run to the end: [$ROUT]" ;; esac
cmp -s "$H4/state/claims/acme/TK-35" "$RB4/touch-files.txt" && [ "$(cat "$RB4/touch-files.txt")" = src/a.ts ] && ok \
  || bad "R2: the local claim must equal touch-files.txt (src/a.ts): [$(cat "$H4/state/claims/acme/TK-35" 2>/dev/null)]"
grep -qx "fclaim_put $RB4/touch-files.txt" "$T/fc.log" 2>/dev/null && ok || bad "R2: fclaim_put must get touch-files.txt: [$(cat "$T/fc.log" 2>/dev/null)]"
grep -q 'TOUCH_CLAIM source=declared n=1 excluded=1$' "$RB4/pipeline.log" 2>/dev/null && ok \
  || bad "R2: pipeline.log TOUCH_CLAIM source=declared n=1 excluded=1: [$(cat "$RB4/pipeline.log" 2>/dev/null)]"
grep -qxF "$Q" "$RB4/planned-files.txt" && ok || bad "R2: planned-files.txt keeps the mention superset"
run_r "$(plan_bare TK-35 src/a.ts)"
cmp -s "$H4/state/claims/acme/TK-35" "$RB4/planned-files.txt" && ok || bad "R3: an undeclared plan's claim must stay planned-files.txt"
grep -qx "fclaim_put $RB4/planned-files.txt" "$T/fc.log" 2>/dev/null && ok || bad "R3: fclaim_put must get planned-files.txt: [$(cat "$T/fc.log" 2>/dev/null)]"
grep -q 'TOUCH_CLAIM source=none n=0 excluded=0$' "$RB4/pipeline.log" 2>/dev/null && ok \
  || bad "R3: pipeline.log TOUCH_CLAIM source=none n=0 excluded=0: [$(cat "$RB4/pipeline.log" 2>/dev/null)]"
run_r $'# Plan TK-35\n## Files to touch\n- `tests/x-test.sh`\n- `src/a.ts`' 'REROUTE tests: tests/x-test.sh -> tests/x.bh-9-test.sh'
grep -qx 'tests/x.bh-9-test.sh' "$H4/state/claims/acme/TK-35" && ! grep -qx 'tests/x-test.sh' "$H4/state/claims/acme/TK-35" && ok \
  || bad "R4: the reroute must reach the published claim: [$(cat "$H4/state/claims/acme/TK-35" 2>/dev/null)]"
grep -qx 'tests/x.bh-9-test.sh' "$T/fc-arg.txt" 2>/dev/null && ok || bad "R4: the reroute must reach job_claims"

# ---------- M. mutants ---------------------------------------------------------
mutant() { # mutant <sed-expr> -> $T/mut.sh in a fresh box, rc 1 when the expression changed nothing
  sed "$1" "$DIR/bin/plan-overlap.sh" > "$T/mut.sh"
  if cmp -s "$T/mut.sh" "$DIR/bin/plan-overlap.sh"; then bad "mutant: '$1' did not apply"; return 1; fi
  mkbox "$T/mut.sh"
}
# M1: the candidate selector removed -> TK-35 judges its mention superset
# against P2's old broad claim.
if mutant 's/^  cp "\$TL" "\$CAND"$/  :/'; then
  reset; claim TK-36 src/b.ts "$Q"; build TK-35 "$(plan_mention TK-35 src/a.ts)"
  po TK-35
  [ "$RC" = 1 ] && ok || bad "M1: without the candidate selector P2's broad claim must defer, got rc=$RC"
fi
# M2: the sibling selector removed -> P4's in-flight side is its mention superset.
if mutant 's/^  OTL=\$(touch_list "\$D") \&\& cp "\$OTL" "\$PHD\/other"$/  :/'; then
  reset; build TK-35 "$(plan_modify TK-35 src/a.ts)"; build TK-36 "$(plan_mention TK-36 src/b.ts)"
  po TK-35
  [ "$RC" = 1 ] && ok || bad "M2: without the sibling selector P4 must defer, got rc=$RC"
fi
mkbox

echo "plan-overlap-touch.bh-5965: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
