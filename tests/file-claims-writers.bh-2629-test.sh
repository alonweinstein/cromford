#!/bin/bash
# tests/file-claims-writers.bh-2629-test.sh — the build pipeline publishes its
# file claim and its overlap not-before to the fleet (job_claims, through
# bin/lib/file-claims.sh) and reads the fleet not-before back (BH-2629, slice 2
# of BH-2524).
#
# The regions are cut out of the FLATTENED pipeline (tests/lib/rb-all.sh), the
# same text bin/run-build.sh runs, and executed against a scratch harness whose
# bin/lib/file-claims.sh is a FAKE honouring the contract's signatures: every
# call is appended to $FC_LOG, rc comes from FC_RC, and fclaim_not_before_left
# prints FC_LEFT only for key FC_LEFT_KEY.
#   S5.  `file claim db` (plan.sh): fclaim_put after the local cp; one honest
#        `FILE_CLAIM db=ok|failed|skipped` line; the local claim survives a DB
#        failure; a mutated region (no fclaim_put) fails the S5a checker.
#   S7a. `plan overlap` (gates.sh): fclaim_not_before_put <PO_NB> before RESULT,
#        rc 3, RESULT text unchanged.
#   S7b. `overlap not-before` (gates.sh): a live fleet window defers; another
#        key, an outage, junk or 0 never does; an expired local file is not an
#        answer; the kill flag skips the fleet read.
#   S-neg. no fclaim_release call anywhere in bin/lib/rb.
# Run from anywhere: tests/file-claims-writers.bh-2629-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/rb-all.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

RB=$(rb_all "$DIR" "$T/run-build.all.sh") || { echo "FAIL: rb_all could not flatten the pipeline"; exit 1; }
region() { sed -n "/^# >>> $1\$/,/^# <<< $1\$/p" "$RB"; }

H="$T/h"; P=proj; FC_LOG="$T/fc.log"; export FC_LOG
mkdir -p "$H/bin/lib"
cat > "$H/bin/lib/file-claims.sh" <<'EOF'
fclaim_put()             { echo "fclaim_put $*" >> "$FC_LOG"; return "${FC_RC:-0}"; }
fclaim_not_before_put()  { echo "fclaim_not_before_put $*" >> "$FC_LOG"; return "${FC_RC:-0}"; }
fclaim_list_dir()        { echo "fclaim_list_dir $*" >> "$FC_LOG"; return 1; }
fclaim_not_before_left() {
  echo "fclaim_not_before_left $*" >> "$FC_LOG"
  [ "${FC_RC:-0}" = 0 ] || return 1
  [ "$2" = "${FC_LEFT_KEY:-}" ] && printf '%s\n' "${FC_LEFT:-}"
  return 0
}
EOF

# --- S5: file claim db --------------------------------------------------------
CP_LINE=$(grep -m1 -F 'cp "$BUILD/planned-files.txt" "$HARNESS/state/claims/$PROJECT/$KEY"' "$RB")
[ -n "$CP_LINE" ] && ok || bad "S5 the local claims cp line is gone from the pipeline"
FCDB=$(region 'file claim db')
[ -n "$FCDB" ] && ok || bad "S5 no '# >>> file claim db' region in the pipeline"
# The db region must come AFTER the local cp: local file first, then DB.
L_CP=$(grep -n -m1 -F "$CP_LINE" "$RB" | cut -d: -f1)
L_DB=$(grep -n -m1 '^# >>> file claim db$' "$RB" | cut -d: -f1)
[ -n "$L_CP" ] && [ -n "$L_DB" ] && [ "$L_DB" -gt "$L_CP" ] && ok \
  || bad "S5 the file claim db region is not after the local cp (cp=${L_CP:-?} db=${L_DB:-?})"

mk_s5() { # mk_s5 <region-text> <out>
  { echo 'set -uo pipefail'; echo 'STAMP() { echo stamp; }'
    echo 'mkdir -p "$HARNESS/state/claims/$PROJECT"'
    echo "$CP_LINE"; printf '%s\n' "$1"; echo 'echo DONE'; } > "$2"
}
run_s5() { # run_s5 <script> <build-dir> [env...]
  local s="$1" b="$2"; shift 2
  scratch_rm "$b"; scratch_rm "$H/state/claims"; mkdir -p "$b"; printf 'bin/a.sh\nbin/b.sh\n' > "$b/planned-files.txt"
  : > "$FC_LOG"
  env -u JOB_ID -u JOBS_URL HARNESS="$H" PROJECT="$P" KEY=BH-1 BUILD="$b" "$@" bash "$s" >/dev/null 2>&1
}
s5a_holds() { # the S5a assertion, as a checker the mutation row can turn red
  local b="$1"
  grep -qx "fclaim_put $b/planned-files.txt" "$FC_LOG" && grep -q 'FILE_CLAIM db=ok$' "$b/pipeline.log" 2>/dev/null
}
S5="$T/s5.sh"; mk_s5 "$FCDB" "$S5"
bash -n "$S5" && ok || bad "S5 the extracted region is not valid bash"

B="$T/b5"
run_s5 "$S5" "$B" JOB_ID=job-1 JOBS_URL=https://jobs.test FC_RC=0
s5a_holds "$B" && ok || bad "S5a rc 0: want fclaim_put + db=ok; log=[$(cat "$FC_LOG")] pipeline=[$(cat "$B/pipeline.log" 2>/dev/null)]"
[ "$(grep -c 'FILE_CLAIM db=' "$B/pipeline.log" 2>/dev/null)" = 1 ] && ok || bad "S5a want exactly one FILE_CLAIM line"

run_s5 "$S5" "$B" JOB_ID=job-1 JOBS_URL=https://jobs.test FC_RC=1
grep -q 'FILE_CLAIM db=failed$' "$B/pipeline.log" 2>/dev/null && ok || bad "S5b rc 1 must log db=failed: [$(cat "$B/pipeline.log" 2>/dev/null)]"
grep -q 'db=ok' "$B/pipeline.log" 2>/dev/null && bad "S5b rc 1 logged db=ok" || ok
grep -qx 'bin/a.sh' "$H/state/claims/$P/BH-1" 2>/dev/null && ok || bad "S5b a DB failure lost the local claim"

run_s5 "$S5" "$B" JOBS_URL=https://jobs.test FC_RC=0
grep -q 'FILE_CLAIM db=skipped$' "$B/pipeline.log" 2>/dev/null && ok || bad "S5c no JOB_ID must log db=skipped: [$(cat "$B/pipeline.log" 2>/dev/null)]"
grep -q '^fclaim_put' "$FC_LOG" && bad "S5c fclaim_put called without JOB_ID" || ok
run_s5 "$S5" "$B" JOB_ID=job-1 FC_RC=0
grep -q 'FILE_CLAIM db=skipped$' "$B/pipeline.log" 2>/dev/null && ok || bad "S5c no JOBS_URL must log db=skipped"

# S5-mut: the same region with the fclaim_put call neutered must fail the S5a checker.
S5M="$T/s5m.sh"; mk_s5 "$(printf '%s\n' "$FCDB" | sed 's/if fclaim_put "/if true "/')" "$S5M"
if grep -q 'fclaim_put "' "$S5M"; then bad "S5-mut the mutation did not apply"; else ok; fi
run_s5 "$S5M" "$B" JOB_ID=job-1 JOBS_URL=https://jobs.test FC_RC=0
s5a_holds "$B" && bad "S5-mut the S5a checker stays green with no fclaim_put call" || ok

# --- S7a: plan overlap publishes the not-before --------------------------------
PO=$(region 'plan overlap')
[ -n "$PO" ] && ok || bad "S7a no plan overlap region"
[ "$(grep -c 'bin/plan-overlap\.sh" "\$PROJECT"' "$RB")" = 1 ] && ok || bad "S7a plan-overlap.sh must be invoked exactly once"
cat > "$H/bin/plan-overlap.sh" <<'EOF'
#!/bin/bash
echo "overlap: bin/a.sh is claimed by BH-9"; exit 1
EOF
chmod +x "$H/bin/plan-overlap.sh"
S7A="$T/s7a.sh"
{ echo 'set -uo pipefail'; echo 'STAMP() { echo stamp; }'
  echo 'RESULT() { echo RESULT >> "$FC_LOG"; printf "%s\n" "$*" > "$T_RES"; }'
  echo '. "$HARNESS/bin/lib/file-claims.sh"'   # production: sourced by the not-before gate earlier
  printf '%s\n' "$PO"; echo 'echo BUILT'; } > "$S7A"
B="$T/b7"; mkdir -p "$B"; : > "$B/plan.md"; : > "$FC_LOG"; rm -f "$T/res"
OUT=$(env -u JOB_ID HARNESS="$H" PROJECT="$P" KEY=BH-1 BUILD="$B" T_RES="$T/res" bash "$S7A" 2>/dev/null); RC=$?
[ "$RC" = 3 ] && ok || bad "S7a want rc 3, got $RC ($OUT)"
grep -q '^BUILD_DEFERRED overlap: bin/a.sh is claimed by BH-9; not before' "$T/res" 2>/dev/null && ok \
  || bad "S7a RESULT text changed: [$(cat "$T/res" 2>/dev/null)]"
[ "$(cat "$FC_LOG")" = "$(printf 'fclaim_not_before_put 600\nRESULT')" ] && ok \
  || bad "S7a want 'fclaim_not_before_put 600' then RESULT, got [$(tr '\n' '|' < "$FC_LOG")]"
[ -s "$H/state/overlap-defer/$P/BH-1" ] && ok || bad "S7a the local not-before marker is not written"
# A failing fleet write changes nothing.
: > "$FC_LOG"; scratch_rm "$H/state/overlap-defer"
OUT=$(env -u JOB_ID HARNESS="$H" PROJECT="$P" KEY=BH-1 BUILD="$B" T_RES="$T/res" FC_RC=1 OVERLAP_DEFER_NOTBEFORE_SECS=120 bash "$S7A" 2>/dev/null); RC=$?
[ "$RC" = 3 ] && grep -qx 'fclaim_not_before_put 120' "$FC_LOG" && [ -s "$H/state/overlap-defer/$P/BH-1" ] && ok \
  || bad "S7a fleet write rc 1 must still defer locally (rc $RC, log [$(tr '\n' '|' < "$FC_LOG")])"
scratch_rm "$H/state/overlap-defer"; scratch_rm "$H/bin/plan-overlap.sh"

# --- S7b: overlap not-before reads the fleet window ----------------------------
NB=$(region 'overlap not-before')
[ -n "$NB" ] && ok || bad "S7b no overlap not-before region"
# In the pipeline the gate that sources the lib runs before the plan-overlap hook
# that calls fclaim_not_before_put.
L_NB=$(grep -n -m1 '^# >>> overlap not-before$' "$RB" | cut -d: -f1)
L_PO=$(grep -n -m1 '^# >>> plan overlap$' "$RB" | cut -d: -f1)
[ -n "$L_NB" ] && [ -n "$L_PO" ] && [ "$L_NB" -lt "$L_PO" ] && ok || bad "S7b not-before gate is not before the plan-overlap hook"
S7B="$T/s7b.sh"
{ echo 'set -uo pipefail'; echo 'RESULT() { printf "%s\n" "$*" > "$T_RES"; }'
  printf '%s\n' "$NB"; echo 'echo BUILT'; } > "$S7B"
bash -n "$S7B" && ok || bad "S7b the extracted region is not valid bash"
run_nb() { # run_nb <key> [env...]  -> OUT, RC
  local k="$1"; shift
  : > "$FC_LOG"; rm -f "$T/res"
  OUT=$(env -u JOB_ID -u JOBS_URL HARNESS="$H" PROJECT="$P" KEY="$k" T_RES="$T/res" "$@" bash "$S7B" 2>/dev/null); RC=$?
}
run_nb BH-B1 FC_LEFT_KEY=BH-B1 FC_LEFT=300
[ "$RC" = 3 ] && grep -q '^BUILD_DEFERRED plan overlap not-before' "$T/res" 2>/dev/null && ok \
  || bad "S7b-1 a live fleet window must defer (rc $RC, $OUT, [$(cat "$T/res" 2>/dev/null)])"
grep -qx "fclaim_not_before_left $P BH-B1" "$FC_LOG" && ok || bad "S7b-1 fclaim_not_before_left not asked with <project> <key>"
grep -q '5m left' "$T/res" 2>/dev/null && ok || bad "S7b-1 the window is not now+300: [$(cat "$T/res" 2>/dev/null)]"
run_nb BH-B2 FC_LEFT_KEY=BH-B1 FC_LEFT=300
[ "$RC" = 0 ] && [ "$OUT" = BUILT ] && ok || bad "S7b-2 another key's window must not defer (rc $RC, $OUT)"
run_nb BH-B1 FC_LEFT_KEY=BH-B1 FC_LEFT=300 FC_RC=1
[ "$RC" = 0 ] && [ "$OUT" = BUILT ] && ok || bad "S7b-3 an outage must not defer (rc $RC, $OUT)"
for junk in abc 0 ''; do
  run_nb BH-B1 FC_LEFT_KEY=BH-B1 FC_LEFT="$junk"
  [ "$RC" = 0 ] && [ "$OUT" = BUILT ] && ok || bad "S7b-3 left_s '$junk' must not defer (rc $RC, $OUT)"
done
mkdir -p "$H/state/overlap-defer/$P"
echo "$(( $(date -u +%s) - 10 ))" > "$H/state/overlap-defer/$P/BH-B1"
run_nb BH-B1 FC_LEFT_KEY=BH-B1 FC_LEFT=300
[ "$RC" = 3 ] && ok || bad "S7b-4 an expired local file must still ask the fleet row (rc $RC, $OUT)"
[ -e "$H/state/overlap-defer/$P/BH-B1" ] && bad "S7b-4 the expired local file is not consumed" || ok
echo "$(( $(date -u +%s) + 120 ))" > "$H/state/overlap-defer/$P/BH-B1"
run_nb BH-B1 FC_LEFT_KEY=BH-B1 FC_LEFT=900
[ "$RC" = 3 ] && ok || bad "S7b a live local file must defer (rc $RC)"
grep -q '^fclaim_not_before_left' "$FC_LOG" && bad "S7b a live local file must win without asking the fleet" || ok
rm -f "$H/state/overlap-defer/$P/BH-B1"
run_nb BH-B1 FC_LEFT_KEY=BH-B1 FC_LEFT=300 OVERLAP_SCHED=0
[ "$RC" = 0 ] && [ "$OUT" = BUILT ] && ok || bad "S7b-5 OVERLAP_SCHED=0 must build (rc $RC, $OUT)"
grep -q '^fclaim_not_before_left' "$FC_LOG" && bad "S7b-5 OVERLAP_SCHED=0 still asked the fleet" || ok
mkdir -p "$H/flags"; : > "$H/flags/plan-overlap-off"
run_nb BH-B1 FC_LEFT_KEY=BH-B1 FC_LEFT=300
[ "$RC" = 0 ] && ! grep -q '^fclaim_not_before_left' "$FC_LOG" && ok || bad "S7b-5 flags/plan-overlap-off must skip the fleet read (rc $RC)"
rm -f "$H/flags/plan-overlap-off"
# No lib at all: the gate behaves as it did before this slice.
mv "$H/bin/lib/file-claims.sh" "$H/bin/lib/file-claims.sh.off"
run_nb BH-B1 FC_LEFT_KEY=BH-B1 FC_LEFT=300
[ "$RC" = 0 ] && [ "$OUT" = BUILT ] && ok || bad "S7b no lib must build (rc $RC, $OUT)"
mv "$H/bin/lib/file-claims.sh.off" "$H/bin/lib/file-claims.sh"

# --- S-neg: no release call in this slice --------------------------------------
[ "$(cat "$DIR"/bin/lib/rb/*.sh | grep -c 'fclaim_release')" = 0 ] && ok || bad "S-neg fclaim_release is called from bin/lib/rb"

echo "file-claims-writers: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
