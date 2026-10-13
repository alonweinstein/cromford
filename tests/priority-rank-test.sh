#!/bin/bash
# tests/priority-rank-test.sh — the PRIORITY RANK VOCABULARY and the LANE
# DECLARATION FIELDS (#643 slice 1/5, BH-644).
#
# WHAT THIS PINS AND WHY. Every selector in the #643 family is supposed to sort
# by ONE rank — 0 hotfix, 1 main-red, 2 plain — and the whole point of putting
# that rank in one lib is that four children cannot each invent their own
# reading of a label. So what is asserted here is the ANSWER the sourced lib
# prints, never the shape of its source.
#
# The adversarial names carry the same weight they do next door in
# tests/hotfix-lib-test.sh: `fix-main-red-ish` is not the main-red label, and a
# substring match would promote it past every ordinary ticket in the fleet.
# FAIL-OPEN IS ALWAYS 2 — lane off, no jq, broken JSON, missing file — because
# 2 is what every ticket ranks today, so an uncertain answer changes nothing.
#
# The job.json half drives the VERBATIM block cut out of bin/run-build.sh (the
# `# >>> job json` markers), the same way tests/run-build-checkpoint-test.sh
# drives the checkpoint wiring: a paraphrase of a jq call proves the paraphrase.
#
# Run from anywhere: tests/priority-rank-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

export HARNESS="$T"
mkdir -p "$T/bin/lib" "$T/env" "$T/flags" "$T/logs" "$T/nojq"
cp "$DIR/bin/lib/hotfix-lib.sh"      "$T/bin/lib/" || exit 1
cp "$DIR/bin/lib/scheduler-conf.sh"  "$T/bin/lib/" || exit 1
export PATH="$T/bin:$PATH"
# shellcheck disable=SC1091
. "$T/bin/lib/hotfix-lib.sh" || exit 1

# A PATH with every tool these functions use EXCEPT jq, so "no jq -> 2" is a
# real absence rather than a mocked one.
for b in bash sed awk tr cat sort readlink date grep; do
  p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$T/nojq/$b"
done

# rank <expected> <fn> <arg> <what> — asserts the PRINTED rank and rc 0 together,
# because "never returns non-zero" is half the contract.
rank() {
  local want="$1" fn="$2" arg="$3" what="$4" out rc
  out=$("$fn" "$arg" "$T"); rc=$?
  [ "$out" = "$want" ] && [ "$rc" = 0 ] && ok \
    || bad "$what: want rank $want rc 0, got '$out' rc $rc"
}

# ---------- A1. main_red_label: a NAME, printed even when the lane is off ----
[ "$(main_red_label "$T")" = fix-main-red ] && ok || bad "main_red_label default should be fix-main-red, got $(main_red_label "$T")"
[ "$(MAIN_RED_LABEL=urgent-red main_red_label "$T")" = urgent-red ] && ok || bad "MAIN_RED_LABEL=urgent-red should print urgent-red"
echo 'MAIN_RED_LABEL=env-red' > "$T/env/global.env"
[ "$(main_red_label "$T")" = env-red ] && ok || bad "env/global.env should supply the label when the environment does not"
rm -f "$T/env/global.env"
touch "$T/flags/hotfix-lane-off"
[ "$(main_red_label "$T")" = fix-main-red ] && ok || bad "main_red_label must print even with the lane off"
rm -f "$T/flags/hotfix-lane-off"

# ---------- A2. csv ranks ----------------------------------------------------
rank 0 priority_rank_labels_csv 'hotfix'                 "csv hotfix"
rank 0 priority_rank_labels_csv 'HOTFIX '                "csv HOTFIX with a trailing space (trim + lowercase)"
rank 0 priority_rank_labels_csv 'merge-queue,hotfix'     "csv hotfix among others"
rank 1 priority_rank_labels_csv 'fix-main-red'           "csv fix-main-red"
rank 1 priority_rank_labels_csv 'merge-queue,fix-main-red' "csv fix-main-red among others"
rank 0 priority_rank_labels_csv 'hotfix,fix-main-red'    "csv with both labels ranks hotfix first"
rank 2 priority_rank_labels_csv 'hotfix-candidate'       "csv hotfix-candidate is a QUESTION, not an emergency"
rank 2 priority_rank_labels_csv 'not-hotfix'             "csv not-hotfix is a denial, not an emergency"
rank 2 priority_rank_labels_csv 'hotfixes'               "csv hotfixes is a different label"
rank 2 priority_rank_labels_csv 'fix-main-red-ish'       "csv fix-main-red-ish is a different label"
rank 2 priority_rank_labels_csv '-'                      "csv - is the tsv placeholder for no labels"
rank 2 priority_rank_labels_csv ''                       "csv empty"
rank 2 priority_rank_labels_csv 'release,*,docs'         "csv with a glob character must not expand"

# ---------- A3. json ranks, in all three shapes ------------------------------
json_obj() { jq -nc --arg n "$1" '[{name:$n}]'; }
json_str() { jq -nc --arg n "$1" '[$n]'; }
json_lab() { jq -nc --arg n "$1" '{labels:[{name:$n}]}'; }
for pair in 'hotfix|0' 'HOTFIX |0' 'fix-main-red|1' 'hotfix-candidate|2' \
            'not-hotfix|2' 'hotfixes|2' 'fix-main-red-ish|2'; do
  lbl=${pair%|*}; want=${pair#*|}
  for shape in json_obj json_str json_lab; do
    rank "$want" priority_rank_labels_json "$($shape "$lbl")" "json $shape $lbl"
  done
done
rank 2 priority_rank_labels_json 'not json'   "a payload that is not JSON"
rank 2 priority_rank_labels_json '{}'         "an object with no .labels"
rank 2 priority_rank_labels_json '[]'         "an empty label array"
rank 2 priority_rank_labels_json ''           "an empty payload"

# ---------- A4. the knob moves BOTH readers ----------------------------------
OUT=$(MAIN_RED_LABEL=urgent-red priority_rank_labels_csv 'urgent-red' "$T")
[ "$OUT" = 1 ] && ok || bad "MAIN_RED_LABEL=urgent-red: csv urgent-red should rank 1, got $OUT"
OUT=$(MAIN_RED_LABEL=urgent-red priority_rank_labels_csv 'fix-main-red' "$T")
[ "$OUT" = 2 ] && ok || bad "MAIN_RED_LABEL=urgent-red: csv fix-main-red should rank 2, got $OUT"
OUT=$(MAIN_RED_LABEL=urgent-red priority_rank_labels_json "$(json_obj urgent-red)" "$T")
[ "$OUT" = 1 ] && ok || bad "MAIN_RED_LABEL=urgent-red: json urgent-red should rank 1, got $OUT"
OUT=$(MAIN_RED_LABEL=urgent-red priority_rank_labels_json "$(json_obj fix-main-red)" "$T")
[ "$OUT" = 2 ] && ok || bad "MAIN_RED_LABEL=urgent-red: json fix-main-red should rank 2, got $OUT"

# ---------- A5. the meta file ------------------------------------------------
json_obj hotfix       > "$T/meta-hot.json"
json_str fix-main-red > "$T/meta-red.json"
json_lab not-hotfix   > "$T/meta-plain.json"
printf 'not json\n'   > "$T/meta-broken.json"
: > "$T/meta-empty.json"
rank 0 priority_rank_meta "$T/meta-hot.json"     "meta carrying the hotfix label"
rank 1 priority_rank_meta "$T/meta-red.json"     "meta carrying the main-red label"
rank 2 priority_rank_meta "$T/meta-plain.json"   "meta carrying neither"
rank 2 priority_rank_meta "$T/meta-broken.json"  "meta that is not JSON"
rank 2 priority_rank_meta "$T/meta-empty.json"   "an empty meta file"
rank 2 priority_rank_meta "$T/meta-missing.json" "a missing meta file"

# ---------- A6. the kill flag puts everything back to plain ------------------
touch "$T/flags/hotfix-lane-off"
rank 2 priority_rank_labels_csv  'hotfix'                "csv hotfix with the lane off"
rank 2 priority_rank_labels_csv  'fix-main-red'          "csv fix-main-red with the lane off"
rank 2 priority_rank_labels_json "$(json_obj hotfix)"    "json hotfix with the lane off"
rank 2 priority_rank_labels_json "$(json_obj fix-main-red)" "json fix-main-red with the lane off"
rank 2 priority_rank_meta        "$T/meta-red.json"      "meta with the lane off"
rm -f "$T/flags/hotfix-lane-off"
rank 0 priority_rank_labels_csv  'hotfix' "removing the flag turns the rank back on"
OUT=$(HOTFIX_LANE=0 priority_rank_labels_json "$(json_obj fix-main-red)" "$T")
[ "$OUT" = 2 ] && ok || bad "HOTFIX_LANE=0 must rank everything 2, got $OUT"

# ---------- A7. no jq -> 2 (and still rc 0) ----------------------------------
# The payload is built BEFORE the PATH is cut down — built inside, jq would be
# missing for the fixture too and the rank would be 2 for the wrong reason.
HOTJSON=$(json_obj hotfix)
OUT=$( export PATH="$T/nojq"; priority_rank_labels_json "$HOTJSON" "$T" ); RC=$?
[ "$OUT" = 2 ] && [ "$RC" = 0 ] && ok || bad "no jq: json should rank 2 rc 0, got '$OUT' rc $RC"
OUT=$( export PATH="$T/nojq"; priority_rank_meta "$T/meta-hot.json" "$T" ); RC=$?
[ "$OUT" = 2 ] && [ "$RC" = 0 ] && ok || bad "no jq: meta should rank 2 rc 0, got '$OUT' rc $RC"

# ---------- A8. the sort: ascending by rank, STABLE within a rank ------------
# The two rank-2 rows are in REVERSE lexical order on purpose. `sort -k3,3n`
# without -s falls back to comparing whole lines when the keys tie, which would
# put `a` before `c` and look correct by accident; discovery order is the FIFO
# the selectors promise, so the tie has to come out c-then-a.
IN=$(printf 'c\tx\t2\nb\ty\t0\na\tz\t2\nd\tw\t1\n')
WANT=$(printf 'b\ty\t0\nd\tw\t1\nc\tx\t2\na\tz\t2\n')
GOT=$(printf '%s\n' "$IN" | priority_sort_tsv 3); RC=$?
[ "$GOT" = "$WANT" ] && [ "$RC" = 0 ] && ok || bad "priority_sort_tsv 3 should sort by rank and keep discovery order within a rank, got: $(printf '%s' "$GOT" | tr '\n' '/')"
GOT=$(printf '%s\n' "$IN" | priority_sort_tsv x); RC=$?
[ "$GOT" = "$IN" ] && [ "$RC" = 0 ] && ok || bad "a non-numeric rank column must pass stdin through untouched, got: $(printf '%s' "$GOT" | tr '\n' '/')"
GOT=$(printf '%s\n' "$IN" | priority_sort_tsv ''); RC=$?
[ "$GOT" = "$IN" ] && [ "$RC" = 0 ] && ok || bad "an empty rank column must pass stdin through untouched"
GOT=$(printf '%s\n' "$IN" | priority_sort_tsv 0); RC=$?
[ "$GOT" = "$IN" ] && [ "$RC" = 0 ] && ok || bad "column 0 is not a column: pass through"

# ---------- A9. the lib does not read HOTFIX ---------------------------------
# A caller holding HOTFIX=1 takes rank 0 itself (#643); the lib answers from
# labels only, so an exported HOTFIX must change nothing here.
OUT=$(HOTFIX=1 priority_rank_labels_csv '-' "$T")
[ "$OUT" = 2 ] && ok || bad "HOTFIX=1 in the environment must not make an unlabelled ticket rank 0, got $OUT"
OUT=$(HOTFIX=1 priority_rank_labels_json "$(json_obj plain)" "$T")
[ "$OUT" = 2 ] && ok || bad "HOTFIX=1 in the environment must not change the json rank, got $OUT"

# ---------- A10. scope: the slices on this branch touch four product files ---
# The contract slice (#644) owns bin/lib/hotfix-lib.sh and bin/run-build.sh. Its
# children STACK ON ITS BRANCH rather than waiting for it to merge (#643's own
# instruction), so this diff-against-main is the union of the slices that have
# landed on the branch, not one slice's file list — #645, the first child, adds
# the two selectors it declares. Anything outside this list is still a stray,
# which is the guard this was written to be.
#
# BH-645 rebase note: main split bin/run-triage.sh's scope/shard-dispatch body
# into bin/lib/rt/scope.sh and bin/lib/rt/shards.sh (the rt_scope/rt_shards
# stages) after this slice was first written. #645's selectors now live in
# those two files rather than inline in bin/run-triage.sh, so they join the
# allowlist and the lib-count ceiling — they are the SAME two selectors this
# guard has always pinned, only moved to where main's own refactor put them,
# not a second, unrelated lib. triage_hot_load/triage_hot_mark/hot_sop moved
# out of bin/run-triage.sh into bin/lib/triage-hotfix-lib.sh at the same
# rebase, to keep the driver under its own line ceiling (tests/rt-split-layout-
# test.sh A6; since BH-5228 a structural check that the driver carries no
# stage body, not a line count) — that file is #645's own, not a second lib
# either.
# BH-1485 fix round (review C1): the old gate fired on ANY branch that touched
# hotfix-lib.sh/triage-hotfix-lib.sh for ANY reason. BH-1485's 21-site
# $(gh_rest …) conversion has one line in triage-hotfix-lib.sh among ~130 files
# spanning the whole tree, unrelated to BH-644/645's scope work, and the old
# gate read that single line as "this is BH-644/645's slice" and then failed
# the STRAY check on every other file the branch touches. a10_own_slice fires
# the same as the old gate on a real BH-644/645 branch — its spec has landed,
# or (before the spec commit) the lib is the ONLY thing this branch touches
# under bin/ — and stays quiet the moment a second, unrelated bin/ file shows
# up with no spec commit backing it.
#
# BH-1522 (N3) — the pre-spec arm is DOCUMENTED, not tightened, on purpose.
# BH-644 and BH-645 are both closed, so the `libonly && no binstray` arm judges
# no live branch any more: every future branch that legitimately carries this
# scope work does it behind a `.harness/specs/BH-64[45]/` commit, which is the
# spec arm. What the pre-spec arm cannot do is tell a genuine pre-spec slice
# (the lib plus nothing else under bin/) apart from a wide sweep that happens
# to touch the lib plus ONE stray bin/ file: the first triggers, the second
# stays quiet, and with no spec commit to anchor on there is nothing else in
# the diff to distinguish them. That slip is intended and row 3 below pins it
# (the BH-1485 shape returns 0). Removing the arm outright would need a spec
# commit to exist first; until one does, the spec arm is the real trigger and
# this arm is kept only so a pre-spec branch is not silently unguarded.
a10_own_slice() { # a10_own_slice <<<"one touched path per line" -> echoes 1 or 0
  local paths spec libonly binstray
  paths=$(cat)
  spec=$(printf '%s\n' "$paths" | grep -cE '^\.harness/specs/BH-64[45]/')
  libonly=$(printf '%s\n' "$paths" | grep -cE '^bin/lib/(hotfix-lib|triage-hotfix-lib)\.sh$')
  binstray=$(printf '%s\n' "$paths" | grep -E '^bin/' \
             | grep -v -e '^bin/lib/hotfix-lib\.sh$' -e '^bin/lib/triage-hotfix-lib\.sh$')
  if [ "$spec" -gt 0 ] || { [ "$libonly" -gt 0 ] && [ -z "$binstray" ]; }; then
    echo 1
  else
    echo 0
  fi
}
# a10_own_slice driven directly, no git diff needed: a real BH-644/645 branch
# (spec committed, or the lib alone with no spec yet) still fires; this PR's
# own shape (the lib plus a pile of unrelated bin/ files, BH-1485's) stays
# quiet.
[ "$(printf '.harness/specs/BH-644/plan.md\nbin/lib/triage-hotfix-lib.sh\n' | a10_own_slice)" = 1 ] \
  && ok || bad "A10: a branch carrying BH-644's spec must still trigger the untouched-files arm"
[ "$(printf 'bin/lib/triage-hotfix-lib.sh\n' | a10_own_slice)" = 1 ] \
  && ok || bad "A10: a branch touching only triage-hotfix-lib.sh under bin/ (no spec yet) must still trigger"
[ "$(printf 'bin/lib/triage-hotfix-lib.sh\nbin/lib/gh-rest-var.sh\nbin/fly-pool.sh\n' | a10_own_slice)" = 0 ] \
  && ok || bad "A10: a branch that touches triage-hotfix-lib.sh alongside unrelated bin/ files (BH-1485's own shape) must stay quiet"
[ "$(printf '' | a10_own_slice)" = 0 ] \
  && ok || bad "A10: an empty diff must not trigger"
B=main; git -C "$DIR" rev-parse --verify -q main >/dev/null || B=origin/main
# This arm judges BH-644/BH-645's OWN slices; on any other branch (one that
# edits a bin/ script for its own ticket) it must stay inert. Same guard as
# file-children.bh-981's A11 and run-rollout.bh-984's A15 (2026-09-22: #1091
# went red here for touching bin/flaky-detect.sh on BH-1061; BH-1485 hit the
# same class through the lib-file arm rather than the missing-gate arm).
OWN=$(git -C "$DIR" diff --name-only "$B" 2>/dev/null; git -C "$DIR" diff --name-only 2>/dev/null)
if [ "$(printf '%s\n' "$OWN" | a10_own_slice)" != 1 ]; then
  echo "note: this branch is not BH-644/BH-645's slice — the A10 untouched-files arm judges only those tickets' own branches"
elif git -C "$DIR" rev-parse --verify -q "$B" >/dev/null; then
  STRAY=$(git -C "$DIR" diff --name-only "$B" -- bin/ \
          | grep -v -e '^bin/lib/hotfix-lib.sh$' -e '^bin/run-build.sh$' \
                    -e '^bin/run-triage.sh$' -e '^bin/merge-conductor.sh$' \
                    -e '^bin/lib/rt/scope.sh$' -e '^bin/lib/rt/shards.sh$' \
                    -e '^bin/lib/triage-hotfix-lib.sh$' | head -5)
  [ -z "$STRAY" ] && ok || bad "the slices on this branch may touch only hotfix-lib.sh, run-build.sh, run-triage.sh, merge-conductor.sh, the rt/scope.sh + rt/shards.sh stages it was split into, and triage-hotfix-lib.sh: $STRAY"
  [ "$(git -C "$DIR" diff --name-only "$B" -- bin/lib/ | grep -v -e '^bin/lib/rt/scope.sh$' -e '^bin/lib/rt/shards.sh$' -e '^bin/lib/triage-hotfix-lib.sh$' | grep -c .)" -le 1 ] \
    && ok || bad "no second lib may change in this slice"
fi

# ---------- A11. the job.json lane declaration, cut VERBATIM ----------------
# BH-568 seam: read the driver through rb_all, not raw — a block that has
# already moved into a bin/lib/rb/ stage module is still found, in place.
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh") || exit 1
cut_block() { # cut_block <marker-word...> <outfile>
  local name="$1" out="$2"
  awk -v n="$name" 'index($0,"# >>> " n)==1{f=1;next} index($0,"# <<< " n)==1{exit} f' \
    "$RB_ALL" > "$out"
}
cut_block "job json"    "$T/jobjson.sh"
cut_block "job json id" "$T/jobid.sh"
for B2 in jobjson jobid; do
  [ -s "$T/$B2.sh" ] && ok || bad "could not extract the '$B2' block from bin/run-build.sh — markers missing?"
  bash -n "$T/$B2.sh" 2>/dev/null && ok || bad "the extracted '$B2' block does not parse on its own"
done

# The environment bin/run-build.sh evaluates that block in: the three ticket
# identifiers, $BUILD, and STAMP. Everything else the block needs it derives.
DRIVE_JOB() { # DRIVE_JOB <build-dir>
  ( set -uo pipefail
    PROJECT=p; TICKET=7; KEY=P-1; BUILD="$1"; HARNESS="$T"
    STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }   # determinism: ok the block stamps created_at; nothing asserts its value
    mkdir -p "$BUILD"
    # shellcheck disable=SC1090
    . "$T/jobjson.sh" )
}
DRIVE_JOB "$T/b1"; RC=$?
[ "$RC" = 0 ] && ok || bad "the job.json block must never be fatal (rc $RC)"
jq -e '.project=="p" and .ticket_id=="7" and .key=="P-1" and (.created_at|type)=="string"' \
  "$T/b1/job.json" >/dev/null 2>&1 && ok || bad "the four keys resume-dead-builds.sh reads must survive: $(cat "$T/b1/job.json" 2>/dev/null)"
jq -e '(.pid|type)=="number" and (.pgid|type)=="number" and (.started_at|type)=="number" and (.expected_by|type)=="number" and (.script|type)=="string"' \
  "$T/b1/job.json" >/dev/null 2>&1 && ok || bad "pid/pgid/started_at/expected_by/script must be typed: $(cat "$T/b1/job.json" 2>/dev/null)"
[ "$(jq -r '.expected_by - .started_at' "$T/b1/job.json" 2>/dev/null)" = 14400 ] \
  && ok || bad "expected_by must be started_at + the 14400 default"
SC=$(jq -r '.script' "$T/b1/job.json" 2>/dev/null)
case "$SC" in /*) ok ;; *) bad "script must be an absolute path, got $SC" ;; esac
[ -e "$SC" ] && ok || bad "script must be a path that exists, got $SC"
[ "$(jq -r '.pid' "$T/b1/job.json" 2>/dev/null)" -gt 0 ] && ok || bad "pid must be a real process id"

# The knob, three ways round — env, flags/scheduler.conf, and a value that will
# not parse. A hardcoded 14400 passes the case above and fails all three.
LANE_EXPECTED_SECS=60 DRIVE_JOB "$T/b2"
[ "$(jq -r '.expected_by - .started_at' "$T/b2/job.json" 2>/dev/null)" = 60 ] \
  && ok || bad "LANE_EXPECTED_SECS=60 in the environment must move expected_by"
echo 'LANE_EXPECTED_SECS=90' > "$T/flags/scheduler.conf"
DRIVE_JOB "$T/b3"
[ "$(jq -r '.expected_by - .started_at' "$T/b3/job.json" 2>/dev/null)" = 90 ] \
  && ok || bad "LANE_EXPECTED_SECS in flags/scheduler.conf must move expected_by"
rm -f "$T/flags/scheduler.conf"
LANE_EXPECTED_SECS=abc DRIVE_JOB "$T/b4"
[ "$(jq -r '.expected_by - .started_at' "$T/b4/job.json" 2>/dev/null)" = 14400 ] \
  && ok || bad "a LANE_EXPECTED_SECS that will not parse must fall back to 14400, never to 0"

# ---------- A12. job_id, written once job_open answers ----------------------
DRIVE_ID() { # DRIVE_ID <build-dir> <job-id>
  ( set -uo pipefail
    BUILD="$1"; JOB_ID="$2"
    # shellcheck disable=SC1090
    . "$T/jobid.sh" )
}
DRIVE_ID "$T/b1" job-42; RC=$?
[ "$RC" = 0 ] && ok || bad "the job_id block must never be fatal (rc $RC)"
jq -e '.job_id=="job-42" and .project=="p" and (.expected_by|type)=="number"' \
  "$T/b1/job.json" >/dev/null 2>&1 && ok || bad "job_id must be added WITHOUT dropping a key: $(cat "$T/b1/job.json" 2>/dev/null)"
[ ! -e "$T/b1/job.json.tmp" ] && ok || bad "the temp file must not be left behind"
mkdir -p "$T/b9"
DRIVE_ID "$T/b9" job-9; RC=$?
[ "$RC" = 0 ] && ok || bad "a missing job.json must not make the job_id write fatal (rc $RC)"
[ ! -e "$T/b9/job.json.tmp" ] && ok || bad "a failed job_id write must leave no job.json.tmp behind"

echo "priority-rank: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
