#!/bin/bash
# tests/main-red-gate.bh-987-test.sh — BH-987: two defects in the main-red gate
# found by the head-bound review of PR #957 (BH-945) at a4017e49.
#
# DEFECT 1 — THE EXEMPTION DEPENDED ON THE CWD. main_red_test_path word-splits
# $MC_MAIN_RED_TEST_PATHS with globbing ON, so from a directory that HAS a
# tests/ dir the pattern `tests/*` pathname-expanded to the list of EXISTING
# test files. A PR whose whole diff is a NEW test file then matched nothing and
# was never exempt. Cron lanes (cwd /root) were accidentally fine; the tier-1
# gate in bin/run-build.sh runs after `cd "$WT"` and held every such PR.
#
# DEFECT 2 — THE LANDING RE-ASK COULD NOT SEE A NEW FLAG. _mrg_flag_for memoised
# the NEGATIVE answer for the life of the process, so bin/merge-queue.sh's
# landing re-asks answered from assembly time. Its own comment claimed "a main
# that goes red in that window is exactly the one that must stop the merge",
# which was not true. The fix drops the memo once per landing pass
# (main_red_forget), keeping the one-read-per-pass budget.
#
# Driven, not grepped. The § E/N cases run the REAL main_red_test_path and the
# tier-1 merge gate extracted VERBATIM from bin/run-build.sh by its `# >>>`
# markers, from a cwd that CONTAINS a matching test file — the condition that
# made the bug invisible. The § L cases run the queue's `# >>> train landing`
# block verbatim with the REAL main_red_queue_hold (never a stub), in ONE
# process, so the memo is the thing under test. Assertions are on artifacts: the
# `gh pr merge` sink, pipeline.log, CONDUCTOR_OWNS_MERGES, a flag-read counter.
#
# bin/lib/main-red-gate.sh is copied only if it EXISTS, and the § E/L cases fail
# on the stack base (ticket/bh-945, where the gate exists but has both defects),
# which is this build's red proof.
#
# Every fixture value is a literal. Nothing here reads the wall clock.
# Run from anywhere: tests/main-red-gate.bh-987-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-1939: the scratch tree below carries no lane registry, and main-red-gate.sh
# no longer has a literal default; these are the values a box resolves from
# catalog/lanes.d/_lib.main-red-gate.json.
export MC_MAIN_RED_LABEL=fix-main-red MC_MAIN_RED_TEST_PATHS='tests/* worker/*/test/*'
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

PROJECT=demo-os
SLUG=example-org/demo-os
FLAGNAME=main-red-example-org-demo-os
H1=aaaaaaaa1111

GATE="$DIR/bin/lib/main-red-gate.sh"
HAVE_GATE=0
[ -r "$GATE" ] && HAVE_GATE=1
[ "$HAVE_GATE" = 1 ] && ok || bad "setup: bin/lib/main-red-gate.sh is absent — every case below is vacuous (stack base = ticket/bh-945)"

# ---------------------------------------------------------------------------
# The scratch harness, and THE CWD THAT MATTERS: a directory holding tests/ and
# worker/w1/test/, so an unguarded glob expands to real files.
# ---------------------------------------------------------------------------
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/flags" "$T/h/state" "$T/h/builds" "$T/h/env" \
         "$T/fakebin" "$T/repo/tests" "$T/repo/worker/w1/test" "$T/repo/bin"
: > "$T/repo/tests/existing.sh"
: > "$T/repo/tests/another-test.sh"
: > "$T/repo/worker/w1/test/existing.sh"
: > "$T/repo/bin/x.sh"
[ "$HAVE_GATE" = 1 ] && cp "$GATE" "$T/h/bin/lib/"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/env-path.sh" "$T/h/bin/lib/" 2>/dev/null
# BH-784: mc_pr_files pages the file list through bin/lib/gh-rest.sh, so the
# contract rides into the fixture tree with the lib. Without it the lib keeps its
# fail-closed shim, answers 75 without ever calling gh, mc_pr_files returns
# "cannot read", and main_red_exempt fails closed — a test-only PR then reads as
# HELD for a reason that has nothing to do with the gate E3 is about.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
# BH-680 (#929): merge-conductor-lib.sh is a shim that sources bin/lib/mc/*.sh and
# exits on a missing module — the fixture must carry the modules too.
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.invalid\n' > "$T/h/env/global.env"
: > "$T/h/env/$PROJECT.env"

FIX="$T/fix"; mkdir -p "$FIX"
# 45: tests/ + bin/ (NOT test-only). 47: a BRAND-NEW test file that does not
# exist in the cwd — the exact diff the defect held.
printf '%s\t\n' "$H1" > "$FIX/labels-45"; printf 'tests/a-test.sh\nbin/b.sh\n' > "$FIX/files-45"
printf '%s\t\n' "$H1" > "$FIX/labels-47"; printf 'tests/brand-new.sh\n'        > "$FIX/files-47"

cat > "$T/fakebin/gh" <<'SHIM'
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "$*" >> "${GH_SINK:-/dev/null}"
N=$(printf '%s' "$*" | grep -oE '[0-9]+' | head -1)
case "$*" in
  *"pr merge"*)   printf 'pr merge %s | %s\n' "$N" "$*" >> "${GH_MERGES:-/dev/null}"; exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"--json headRefOid,labels"*)
      [ -f "$FIX/labels-$N" ] || exit 1
      cat "$FIX/labels-$N" ;;
  # mc_pr_files reads the list over REST now (BH-587 review round 1, #715) and
  # has no GraphQL fallback; the old spelling stays for any caller still using
  # it. Without the REST arm this shim answers nothing, mc_pr_files returns
  # "cannot read", and main_red_exempt fails closed — which is the ONE thing
  # E3/N1 must not be able to confuse with a real hold.
  # The REST-pages spelling of the same read (BH-784), matched FIRST: gh-rest.sh
  # judges the HTTP status line, so a bare list with no status line is unreadable
  # to it. The body is the files ARRAY — the jq that names the filenames is
  # mc_pr_files's own, not a gh -q template. The two arms below stay, as #1225
  # kept them, so a reader that goes back to either spelling is still answered
  # and still visible in GH_SINK.
  *"-i -X GET"*"/pulls/"*"/files"*)
      restpr --raw 200 "$(jq -R -s -c 'split("\n")|map(select(length>0))|map({filename:.})' < "$FIX/files-$N" 2>/dev/null)" ;;
  *"/files"*)         cat "$FIX/files-$N" 2>/dev/null ;;
  *"--json files"*)   cat "$FIX/files-$N" 2>/dev/null ;;
  *"--json headRefOid"*) printf '%s\n' "aaaaaaaa1111" ;;
  *"--json state,mergeable,headRefName"*) printf 'OPEN MERGEABLE ticket/demo-%s\n' "$N" ;;
  *"--json state,headRefName"*)           printf 'OPEN ticket/demo-%s\n' "$N" ;;
  *"--json state"*)
      if grep -q "pr merge $N " "${GH_MERGES:-/dev/null}" 2>/dev/null; then echo MERGED; else echo OPEN; fi ;;
  *"--json mergeCommit"*) printf 'dddddddd4444\n' ;;
  *) printf '\n' ;;
esac
exit 0
SHIM
chmod +x "$T/fakebin/gh"
for s in flock git sleep curl; do
  printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/$s"; chmod +x "$T/fakebin/$s"
done

GH_SINK="$T/gh-calls.txt"; GH_MERGES="$T/gh-merges.txt"
export FIX GH_SINK GH_MERGES
reset_sinks() { : > "$GH_SINK"; : > "$GH_MERGES"; }
flag_up()   { : > "$T/h/flags/$1"; }
flag_down() { rm -f "$T/h/flags"/main-red-* 2>/dev/null; }
merged()  { grep -q "pr merge $1 " "$GH_MERGES"; }

# ============================================================================
# E. main_red_test_path, called FROM A CWD THAT CONTAINS MATCHING FILES.
#    This is the whole defect: the same call from /root always worked.
# ============================================================================
tp() { # tp <path> ; prints the rc, run from $T/repo
  ( cd "$T/repo" && HARNESS="$T/h" bash -c '
      . "'"$T"'/h/bin/lib/main-red-gate.sh" 2>/dev/null || exit 99
      main_red_test_path "$1"; echo "rc=$?"' _ "$1" )
}

# E1 — a NEW test file, from the repo cwd. rc 0 required.
[ "$(tp tests/brand-new.sh)" = "rc=0" ] \
  && ok || bad "E/new-test-file-from-repo-cwd: THE DEFECT — a new tests/ file is not exempt from a cwd that has tests/ (got '$(tp tests/brand-new.sh)')"
[ "$(tp worker/w1/test/new.sh)" = "rc=0" ] \
  && ok || bad "E/new-test-file-from-repo-cwd: a new worker/*/test/ file must be exempt too (got '$(tp worker/w1/test/new.sh)')"
# An EXISTING test file was exempt before and must stay exempt.
[ "$(tp tests/existing.sh)" = "rc=0" ] \
  && ok || bad "E/existing-test-file-still-exempt: an existing test file must remain exempt (got '$(tp tests/existing.sh)')"

# E2 — the negatives are unchanged, and the shell's own noglob state is not leaked.
[ "$(tp bin/x.sh)" = "rc=1" ] \
  && ok || bad "E/negatives-unchanged: bin/x.sh must NOT be a test path (got '$(tp bin/x.sh)')"
[ "$(tp src/tests/x.sh)" = "rc=1" ] \
  && ok || bad "E/negatives-unchanged: src/tests/x.sh must NOT match tests/* (got '$(tp src/tests/x.sh)')"
[ "$(tp tests)" = "rc=1" ] \
  && ok || bad "E/negatives-unchanged: bare 'tests' must NOT match (got '$(tp tests)')"
NOGLOB_OUT=$( cd "$T/repo" && HARNESS="$T/h" bash -c '
    . "'"$T"'/h/bin/lib/main-red-gate.sh" 2>/dev/null || exit 99
    main_red_test_path tests/brand-new.sh
    set -o | grep "^noglob"' )
grep -q 'noglob[[:space:]]*off' <<<"$NOGLOB_OUT" \
  && ok || bad "E/negatives-unchanged: the call must not leak set -f to its caller (got '$NOGLOB_OUT')"
# A pattern list with NO matching file in the cwd still matches (the accidental
# pre-fix case that appeared to work).
OUT=$( cd "$T/repo" && HARNESS="$T/h" MC_MAIN_RED_TEST_PATHS='nowhere/*' bash -c '
    . "'"$T"'/h/bin/lib/main-red-gate.sh" 2>/dev/null || exit 99
    main_red_test_path nowhere/new.sh; echo "rc=$?"' )
[ "$OUT" = "rc=0" ] \
  && ok || bad "E/unmatched-pattern-still-matches: a pattern with no files on disk must still match (got '$OUT')"

# ============================================================================
# E3/N1. bin/run-build.sh's tier-1 merge gate, extracted and driven FROM THE
#        REPO CWD — the production entry point where the defect held PRs (D2).
# ============================================================================
awk '/^# >>> tier-1 merge gate/{f=1;next} /^# <<< tier-1 merge gate/{exit} f' \
  "$RB_ALL" > "$T/gate.sh"
[ -s "$T/gate.sh" ] && ok || bad "E3: could not extract the tier-1 merge gate from bin/run-build.sh — markers missing?"

run_gate() { # run_gate <pr> ; prints the RESULT line. cwd = $T/repo (has tests/).
  reset_sinks
  rm -f "$T/RESULT"; mkdir -p "$T/h/builds/gate"
  printf 'VERDICT: APPROVE\n' > "$T/h/builds/gate/review.md"; printf 'plan\n' > "$T/h/builds/gate/plan.md"
  : > "$T/h/builds/gate/pipeline.log"
  ( cd "$T/repo" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" BUILD="$T/h/builds/gate" \
      ALERTS="$T/h/logs/ALERTS.log" \
      PROJECT="$PROJECT" KEY=BH-1 SLUG="$SLUG" TIER=1 PR_URL="https://github.com/$SLUG/pull/$1" \
      QA_NOTE="" MIG_NOTE="" REBASE_NOTE="" CLOSES_LINE="Closes #$1" HEADBOUND_SHA="$H1" \
      BUILDER_NO_MERGE= \
      bash -c 'set -uo pipefail
        STAMP() { printf TS; }
        RESULT() { echo "$*" > '"$T"'/RESULT; }
        BB() { :; }
        CLOSE_ISSUE_AFTER_MERGE() { :; }
        mc_queue_conductor_only() { return 1; }
        mc_pr_queued() { return 1; }
        . "$HARNESS/bin/lib/merge-conductor-lib.sh"
        . "$0"' "$T/gate.sh" >/dev/null 2>"$T/gate.err" ) || true
  cat "$T/RESULT" 2>/dev/null
}

# E3 — flag up, PR 47 is a brand-new test file: the exemption must fire even
# though the gate runs from a worktree that has tests/.
flag_down; flag_up "$FLAGNAME"
OUT=$(run_gate 47)
grep -q "tier-1 merge HELD by the main-red freeze" "$T/h/builds/gate/pipeline.log" \
  && bad "E3/tier1-gate-exempts-new-test: THE DEFECT — a test-only PR was HELD because the gate ran from a cwd with tests/ (log: $(cat "$T/h/builds/gate/pipeline.log"))" || ok
merged 47 \
  && ok || bad "E3/tier1-gate-exempts-new-test: a test-only PR must still merge under the freeze (RESULT '$OUT', log: $(cat "$T/h/builds/gate/pipeline.log"), stderr: $(cat "$T/gate.err"))"
# ...and it merged because the gate READ the diff, not because the read failed
# open: the exemption is only honest if the PR's file list was actually bought.
grep -q 'pulls/47/files' "$GH_SINK" \
  && ok || bad "E3/tier1-gate-exempts-new-test: the gate never read PR 47's file list over REST — the exemption cannot have been decided on the diff (gh calls: $(cat "$GH_SINK"))"

# N1 — the negative that must NOT regress: tests/ + bin/ is not test-only.
OUT=$(run_gate 45)
merged 45 \
  && bad "N/tier1-mixed-diff-still-held: a mixed diff must NOT merge into a red main ($(cat "$GH_MERGES"))" || ok
grep -q "tier-1 merge HELD by the main-red freeze" "$T/h/builds/gate/pipeline.log" \
  && ok || bad "N/tier1-mixed-diff-still-held: the build log must say why (RESULT '$OUT', log: $(cat "$T/h/builds/gate/pipeline.log"), stderr: $(cat "$T/gate.err"))"

# ============================================================================
# L. bin/merge-queue.sh's train landing, run VERBATIM with the REAL gate, in
#    ONE process — the memo is the thing under test.
# ============================================================================
awk '/^# >>> main-red gate/{f=1;next} /^# <<< main-red gate/{exit} f' \
  "$DIR/bin/merge-queue.sh" > "$T/qmr.sh"
[ -s "$T/qmr.sh" ] && ok || bad "L: could not extract the queue's main-red wrapper from bin/merge-queue.sh"
awk '/^        # >>> train landing/{f=1;next} /^        # <<< train landing/{exit} f' \
  "$DIR/bin/merge-queue.sh" > "$T/land.sh"
[ -s "$T/land.sh" ] && ok || bad "L: could not extract the train landing block from bin/merge-queue.sh"
awk '/^# >>> mq_land/{f=1;next} /^# <<< mq_land/{exit} f' \
  "$DIR/bin/merge-queue.sh" > "$T/mqland.sh"
[ -s "$T/mqland.sh" ] && ok || bad "L: could not extract mq_land from bin/merge-queue.sh"

Q="$T/h/state/merge-queue/$PROJECT"; mkdir -p "$Q"

# land_pass runs, in ONE bash process: an ASSEMBLY-time gate read (no flag, so
# the negative is memoised), then $1 (raise/clear the flag), then the real
# landing block. Nothing about the gate is stubbed — main_red_queue_hold comes
# from the real lib via the real queue wrapper.
land_pass() { # land_pass <mid-action> <batch> [extra-preamble]
  reset_sinks; : > "$T/land.log"; : > "$T/reads.txt"
  rm -f "$Q"/*; for n in $2; do : > "$Q/$n"; done
  ( cd "$T/repo" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" SLUG="$SLUG" PROJECT="$PROJECT" \
      LOG="$T/land.log" Q="$Q" BATCH="$2" FLAGFILE="$T/h/flags/$FLAGNAME" \
      READS="$T/reads.txt" \
      bash -c 'set -uo pipefail
        STAMP() { printf TS; }
        MQROW() { :; }
        bg_queue_hold() { return 1; }
        dep_queue_hold() { return 1; }
        LANDED=0; LAST_SHA=""
        . "$HARNESS/bin/lib/main-red-gate.sh"
        . "'"$T"'/qmr.sh"
        . "'"$T"'/mqland.sh"
        '"${3:-}"'
        # ASSEMBLY: the first gate read of this process, with the flag as it
        # stands now. This is what fills the memo.
        for A in $BATCH; do mr_queue_hold "$A" >/dev/null 2>&1 || true; done
        # The window between assembly and landing.
        '"$1"'
        . "$0"' "$T/land.sh" >/dev/null 2>"$T/land.err" ) || true
}

# L1 — the acceptance case: no flag at assembly, flag RAISED before landing.
flag_down
land_pass 'flag_up_inproc' "41 43" 'flag_up_inproc() { : > "$FLAGFILE"; }'
merged 41 \
  && bad "L/train-landing-flag-raised-after-assembly: THE DEFECT — a flag raised between assembly and landing did not stop the merge; the memo answered from assembly time ($(cat "$GH_MERGES"), err: $(cat "$T/land.err"))" || ok
grep -q "#41 HELD by the main-red freeze" "$T/land.log" \
  && ok || bad "L/train-landing-flag-raised-after-assembly: the landing pass must log the hold (log: $(cat "$T/land.log"), err: $(cat "$T/land.err"))"
[ -f "$Q/41" ] \
  && ok || bad "L/train-landing-flag-raised-after-assembly: the held entry stays queued for the next pass"

# L3 — the inverse: flag UP at assembly, CLEARED before landing → it lands.
flag_down; flag_up "$FLAGNAME"
land_pass 'flag_down_inproc' "41" 'flag_down_inproc() { rm -f "$FLAGFILE"; }'
merged 41 \
  && ok || bad "L/flag-cleared-lands: a freeze cleared before landing must let the member land in this same pass (merges: $(cat "$GH_MERGES"), log: $(cat "$T/land.log"), err: $(cat "$T/land.err"))"

# L2 — the budget the memo exists for: ONE flag-store read per spelling per
# landing pass, not one per member. flag_active is overridden with a counter.
flag_down
land_pass ':' "41 43 45" '
  flag_active() { printf "%s\n" "$1" >> "$READS"; return 1; }'
# The counter above spans assembly AND landing: assembly makes one read per
# spelling, the landing pass makes one more per spelling. 4, never 12.
NREADS=$(wc -l < "$T/reads.txt")
[ "$NREADS" -le 4 ] \
  && ok || bad "L/one-read-per-pass: a 3-member pass must cost at most 4 flag reads (2 spellings x assembly+landing), got $NREADS ($(sort -u "$T/reads.txt" | tr '\n' ' '))"
[ "$NREADS" -ge 3 ] \
  && ok || bad "L/one-read-per-pass: the landing pass must re-read at all — got only $NREADS reads, the memo was never dropped"

# ============================================================================
# S. The serial landing path calls main_red_forget exactly once before its
#    re-ask. Extracted by its own anchor and driven with a counting stub.
# ============================================================================
awk '/# The thread is re-read here/{f=1} f{print} /read -r MQST MQSHA < <\(mq_land "\$NUM"\)/{if(f) exit}' \
  "$DIR/bin/merge-queue.sh" > "$T/serial.sh"
if [ -s "$T/serial.sh" ]; then
  ok
  : > "$T/forgets.txt"
  ( PATH="$T/fakebin:$PATH" HARNESS="$T/h" NUM=41 FORGETS="$T/forgets.txt" \
      bash -c 'set -uo pipefail
        main_red_forget() { printf "f\n" >> "$FORGETS"; }
        bg_queue_hold()  { return 1; }
        dep_queue_hold() { return 1; }
        mr_queue_hold()  { return 1; }
        mq_land() { printf "MERGED dddddddd4444\n"; }
        . "$0"' "$T/serial.sh" >/dev/null 2>"$T/serial.err" ) || true
  NF=$(wc -l < "$T/forgets.txt")
  [ "$NF" = 1 ] \
    && ok || bad "S/serial-forget-present: the serial landing re-ask must drop the memo exactly once, got $NF call(s) (err: $(cat "$T/serial.err"))"
else
  bad "S/serial-forget-present: could not extract the serial landing re-ask from bin/merge-queue.sh — the anchor comment moved, so this case proved nothing"
fi

echo "main-red-gate.bh-987: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
