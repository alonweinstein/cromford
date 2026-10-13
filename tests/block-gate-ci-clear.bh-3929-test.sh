#!/bin/bash
# tests/block-gate-ci-clear.bh-3929-test.sh — BH-3934 (BH-3929.2): a BLOCK whose
# only finding is "CI did not run" clears itself once CI is green on that head.
#
#   bin/lib/mc/block-ci.sh   mc_block_ci_step: classify, dispatch CI once per
#                            (PR, head), write the block_ci_clear ledger row on
#                            an all-success head
#   bin/lib/block-gate.sh    bg_scan_read drops ONLY the block id that row names
#
#   C1-C8  the ticket's acceptance cases     P1-P3 / N1-N8  the classifier
#   O1 observe mode   F1/F2 a failed POST    H1 head moved   W2-W4 which workflow
#   V1-V3 verdict-row blocks   G2-G5 the gates   S1 no state/ or flags/ file
#   E1 the conductor's READY arm, lifted from bin/merge-conductor.sh, through
#      the real bin/lib/merge-conductor-lib.sh loader
#
# GitHub is a gh_rest FUNCTION answering from fixture files (no network), and
# bg_scan's own `gh api` reads go to a PATH shim. D1 is four shell functions
# over files in $T. Every time is a literal; nothing reads the clock.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/block-gate-ci-clear.bh-3929-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
export HARNESS="$H" MC_H="$H" ACTIONS=1
mkdir -p "$H/state/seed" "$H/flags" "$H/logs" "$T/fakebin"
echo keep > "$H/state/seed/x"; echo keep > "$H/flags/y"

SLUG=example-org/demo-os; NUM=41; PRKEY="example-org/demo-os#41"
URL="https://github.com/$SLUG/pull/$NUM"
HEAD=cccccccccccccccccccccccccccccccccccccccc
OTHER=dddddddddddddddddddddddddddddddddddddddd
BR=ticket/bh-9; BR_Q=ticket%2Fbh-9
T_HEAD=2026-10-03T10:00:00Z
CI_BODY='Automated harness review (r1)

- [BLOCK] CI did not run on this head

VERDICT: BLOCK'

# ── bg_scan's own reads: `gh api <path> --paginate -q …`, answered from files
# holding exactly what -q prints (bg_read's TSV). The CR-standing read
# (`gh api -X GET …reviews?per_page=100`) matches nothing and gets "".
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-cli.log"
case "\$*" in
  "api repos/$SLUG/issues/$NUM/comments "*) cat "$T/prcomments" 2>/dev/null ;;
  "api repos/$SLUG/pulls/$NUM/reviews "*)   cat "$T/reviews" 2>/dev/null ;;
  "api repos/$SLUG/pulls/$NUM/commits"*)    echo "$T_HEAD" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"

# ── the libraries under test, and the real mc_head_still behind them ─────────
. "$DIR/bin/lib/pr-health.sh"   || { echo "cannot source pr-health.sh"; exit 1; }
. "$DIR/bin/lib/verdicts.sh"    || { echo "cannot source verdicts.sh"; exit 1; }
. "$DIR/bin/lib/block-gate.sh"  || { echo "cannot source block-gate.sh"; exit 1; }
. "$DIR/bin/lib/mc/classify.sh" || { echo "cannot source mc/classify.sh"; exit 1; }
. "$DIR/bin/lib/mc/queue.sh"    || { echo "cannot source mc/queue.sh"; exit 1; }
. "$DIR/bin/lib/mc/block-ci.sh" || { echo "cannot source mc/block-ci.sh"; exit 1; }

# ── fake GitHub: $T/gh/<METHOD>/<path, / as __>; <file>.status = that status ─
_fx() { printf '%s/gh/%s/%s' "$T" "$1" "$(printf '%s' "$2" | sed 's|/|__|g')"; }
fx()        { local f; f=$(_fx "$1" "$2"); mkdir -p "${f%/*}"; printf '%s\n' "$3" > "$f"; }
fx_status() { local f; f=$(_fx "$1" "$2"); mkdir -p "${f%/*}"; echo "$3" > "$f.status"; }
gh_rest() {
  local m="$1" p="$2" f; shift 2
  printf '%s %s%s\n' "$m" "$p" "${*:+ $*}" >> "$T/calls.log"
  f=$(_fx "$m" "$p"); GH_REST_STATUS=200
  if [ -f "$f.status" ]; then
    GH_REST_STATUS=$(cat "$f.status"); [ "$GH_REST_STATUS" = 404 ] && return 44; return 75
  fi
  [ -f "$f" ] && { cat "$f"; return 0; }
  [ "$m" = GET ] && { GH_REST_STATUS=404; return 44; }
  GH_REST_STATUS=204; return 0
}

# ── fake D1 ──────────────────────────────────────────────────────────────────
_d1() { printf '%s/d1/%s' "$T" "$(printf '%s' "$*" | tr '/# @' '____')"; }
pr_attempt_has() { [ "${ATT_OUTAGE:-0}" = 1 ] && return 1; [ -f "$(_d1 att "$@")" ] && return 0; return 2; }
pr_attempt_put() {
  printf 'PUT pr-attempts %s\n' "$*" >> "$T/calls.log"
  [ "${ATT_PUT_FAIL:-0}" = 1 ] && return 1
  mkdir -p "$T/d1"; touch "$(_d1 att "$@")"
}
job_ledger_row() {
  [ "${LEDGER_OUTAGE:-0}" = 1 ] && return 1
  local f; f=$(_d1 ledger "$1" "$2"); [ -f "$f" ] || return 2; cat "$f"
}
job_ledger_put() {
  printf 'PUT ledger %s\n' "$*" >> "$T/calls.log"
  [ "${LEDGER_PUT_FAIL:-0}" = 1 ] && return 1
  mkdir -p "$T/d1"; jq -nc --arg s "$3" --arg d "${4:-}" '{status:$s,detail:$d}' > "$(_d1 ledger "$1" "$2")"
}
ledger_seed() { mkdir -p "$T/d1"; jq -nc --arg d "$1" '{status:"cleared",detail:$d}' > "$(_d1 ledger block_ci_clear "$PRKEY@$HEAD")"; }
ledger_detail() { jq -r '.status + " " + .detail' "$(_d1 ledger block_ci_clear "$PRKEY@$HEAD")" 2>/dev/null; }
attempt_seed() { mkdir -p "$T/d1"; touch "$(_d1 att "$SLUG" "$NUM" blockci "$HEAD")"; }
vd_standing() { [ -f "$T/standing" ] || return 1; cat "$T/standing"; }

mc_log()   { printf '%s\n' "$*" >> "$T/mc.log"; }
mc_alert() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$T/alerts.log"; }
# BH-5793: the re-review request goes through bin/lead-verdict.sh; this stub
# logs each call and answers $T/lv.rc (0 by default).
printf '#!/bin/bash\necho "lead-verdict $*" >> "%s/calls.log"\nexit "$(cat "%s/lv.rc" 2>/dev/null || echo 0)"\n' "$T" "$T" > "$T/lead-verdict.sh"
chmod +x "$T/lead-verdict.sh"; export MC_LEAD_VERDICT="$T/lead-verdict.sh"

# ── fixtures ─────────────────────────────────────────────────────────────────
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
review_row() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$URL#pullrequestreview-$1" "$(b64 "$4")" >> "$T/reviews"; }
review_body() { fx GET "repos/$SLUG/pulls/$NUM/reviews/$1" "$(jq -nc --argjson i "$1" --arg b "$2" '{id:$i,body:$b}')"; }
runs() { fx GET "repos/$SLUG/actions/runs?head_sha=$HEAD&per_page=100" "{\"workflow_runs\":$1}"; }
run() { printf '{"id":%s,"workflow_id":%s,"head_sha":"%s","status":"%s","conclusion":%s}' "$1" "$2" "$3" "$4" "$5"; }
jobs_fx() { fx GET "repos/$SLUG/actions/runs/$1/jobs?filter=latest&per_page=100" "{\"total_count\":$2,\"jobs\":$3}"; }
workflows() { fx GET "repos/$SLUG/actions/workflows" "{\"workflows\":$1}"; }
wf() { printf '{"path":".github/workflows/%s","state":"active"}' "$1"; }
green2() { # two workflows' latest runs on HEAD (an older red one is superseded), every job success
  runs "[$(run 400 1 "$HEAD" completed '"failure"'),$(run 501 1 "$HEAD" completed '"success"'),$(run 502 2 "$HEAD" completed '"success"')]"
  jobs_fx 501 1 '[{"name":"a","conclusion":"success"}]'
  jobs_fx 502 2 '[{"name":"b","conclusion":"success"},{"name":"c","conclusion":"success"}]'
}
reset() {
  rm -rf "$T/gh" "$T/d1" "$T/standing" "$H/state/block-gate" "$T/lv.rc"
  : > "$T/calls.log"; : > "$T/mc.log"; : > "$T/alerts.log"; : > "$T/reviews"; : > "$T/prcomments"
  export ACTIONS=1; unset ATT_OUTAGE ATT_PUT_FAIL LEDGER_OUTAGE LEDGER_PUT_FAIL
  fx GET "repos/$SLUG/pulls/$NUM" "{\"number\":$NUM,\"head\":{\"sha\":\"$HEAD\",\"ref\":\"$BR\"}}"
  workflows "[$(wf harness-ci.yml)]"
  review_body 9001 "$CI_BODY"
  review_row 9001 2026-10-03T11:00:00Z lead "$CI_BODY"
}
step() { RC=0; mc_block_ci_step "$SLUG" "$NUM" "$HEAD" "$URL" "${1:-9001}" "${2:-}" >"$T/step.out" 2>/dev/null || RC=$?; }
scan() { BGOUT=$(bg_scan "$SLUG" "$NUM" "$URL" "$HEAD"); BGRC=$?; BGID=$(awk -F'\t' '{print $4}' <<<"$BGOUT"); }
n_calls() { grep -cF -- "$1" "$T/calls.log"; }
line_of() { grep -nF -- "$1" "$T/calls.log" | head -1 | cut -d: -f1; }
no_writes() { # no_writes <label> — no attempt row, no POST, no ledger row
  [ "$(n_calls 'PUT pr-attempts')" = 0 ] || bad "$1: an attempt row was written"
  [ "$(n_calls 'POST ')" = 0 ]           || bad "$1: a POST was sent"
  [ "$(n_calls 'PUT ledger')" = 0 ]      || bad "$1: a ledger row was written"
}
DISPATCH="POST repos/$SLUG/actions/workflows/harness-ci.yml/dispatches"
RUNS_GET="GET repos/$SLUG/actions/runs?head_sha=$HEAD&per_page=100"

# ══ P1-P3 / N1-N8: the classifier. rc 0 gates an irreversible clear. ═════════
for B in "- [BLOCK] CI did not run on this head" \
         "- [BLOCK] the harness-ci workflow was cancelled" \
         "BLOCK: no CI run on this commit"; do
  _mc_bci_ci_only "$B" && ok || bad "P: must classify CI-only: $B"
done
N1="- [BLOCK] CI passed, but the migration did not run on prod"
N2="- [BLOCK] CI did not run
- [BLOCK] bin/x.sh:12 returns 0 on error"
N3="- [BLOCK] cron job skipped its lock check"
N4="- [BLOCK] the check for null was skipped in src/a.ts"
N5="- [BLOCK] tests did not run because bin/foo.sh exits early"
N7="- [BLOCK] CI workflow skipped the deploy step to production"
N8="- [BLOCK] the workflow was skipped; however the schema change is unreviewed"
i=0
for B in "$N1" "$N2" "$N3" "$N4" "$N5" "" "LGTM, nothing blocking here" "$N7" "$N8"; do
  i=$((i+1))
  _mc_bci_ci_only "$B" && bad "N: must NOT classify CI-only (#$i): ${B:-<empty>}" || ok
  # …and through the step: rc 2, nothing written, nothing sent.
  reset; review_body 9001 "VERDICT: BLOCK
$B"; green2
  step; [ "$RC" = 2 ] && ok || bad "N#$i: step rc must be 2, got $RC"
  no_writes "N#$i"
done

# ══ C1: dispatch once per (PR, head), attempt row BEFORE the POST ════════════
reset; runs '[]'
SNAP0=$(find "$H/state" "$H/flags" -type f | sort | xargs sha256sum)
step
[ "$RC" = 1 ] && ok || bad "C1 tick 1: not green yet must be rc 1, got $RC"
[ "$(n_calls "$DISPATCH")" = 1 ] && ok || bad "C1 tick 1: exactly one dispatch POST ($(n_calls "$DISPATCH"))"
[ "$(n_calls 'POST ')" = 1 ] && ok || bad "C1 tick 1: one POST in all"
pa=$(line_of "PUT pr-attempts $SLUG $NUM blockci $HEAD"); po=$(line_of "$DISPATCH")
[ -n "$pa" ] && [ -n "$po" ] && [ "$pa" -lt "$po" ] && ok || bad "C1: the attempt PUT must precede the POST (put=$pa post=$po)"
grep -qF "$DISPATCH -f ref=$BR" "$T/calls.log" && ok || bad "C1: the dispatch must name ref=$BR"
grep -qxF "BLOCK_CI_DISPATCH $PRKEY $HEAD harness-ci.yml" "$T/mc.log" && ok || bad "C1: BLOCK_CI_DISPATCH line missing: $(cat "$T/mc.log")"
: > "$T/calls.log"; step
[ "$(n_calls 'POST ')" = 0 ] && ok || bad "C1 tick 2: no second POST on the same head"
[ "$(n_calls "$RUNS_GET")" = 1 ] && ok || bad "C1 tick 2: the green check must still read the runs once"

# ══ C2: every job of every latest run is success → the row, the log, rc 0 ════
green2; step
[ "$RC" = 0 ] && ok || bad "C2: green must be rc 0, got $RC"
[ "$(ledger_detail)" = "cleared 502 9001" ] && ok || bad "C2: ledger row must be 'cleared 502 9001', got '$(ledger_detail)'"
grep -qxF "block-cleared-by-ci $PRKEY $HEAD 502" "$T/mc.log" && ok || bad "C2: block-cleared-by-ci line missing: $(cat "$T/mc.log")"
SNAP1=$(find "$H/state" "$H/flags" -type f | sort | xargs sha256sum)
[ "$SNAP0" = "$SNAP1" ] && ok || bad "S1: the step must write nothing under state/ or flags/"
scan
[ "$BGRC" = 0 ] && [ -z "$BGOUT" ] && ok || bad "C2: bg_scan after the clear must be rc 0 and silent (rc=$BGRC out=$BGOUT)"
# The same thread with no row refuses: the clear, not the fixture, lifted it.
rm -rf "$T/d1"; scan
[ "$BGRC" = 1 ] && [ "$BGID" = 9001 ] && ok || bad "C2 control: without the row bg_scan must refuse on 9001 (rc=$BGRC id=$BGID)"

# ══ C3 / G2 / G3: not green → no row ════════════════════════════════════════
for v in skipped zero-jobs in-progress failure partial-page; do
  reset; attempt_seed; green2
  case $v in
    skipped)     jobs_fx 502 2 '[{"name":"b","conclusion":"success"},{"name":"c","conclusion":"skipped"}]' ;;
    zero-jobs)   jobs_fx 502 0 '[]' ;;
    in-progress) runs "[$(run 501 1 "$HEAD" completed '"success"'),$(run 502 2 "$HEAD" in_progress null)]" ;;
    failure)     jobs_fx 501 1 '[{"name":"a","conclusion":"failure"}]' ;;
    partial-page) jobs_fx 502 101 '[{"name":"b","conclusion":"success"}]' ;;
  esac
  step
  [ "$RC" = 1 ] && ok || bad "C3/$v: rc must be 1, got $RC"
  [ "$(n_calls 'PUT ledger')" = 0 ] && ok || bad "C3/$v: no ledger row may be written"
  grep -q block-cleared-by-ci "$T/mc.log" && bad "C3/$v: logged a clear" || ok
  scan; [ "$BGRC" = 1 ] && ok || bad "C3/$v: bg_scan must still refuse (rc=$BGRC)"
done

# ══ C4: a green run on ANOTHER head clears nothing ═══════════════════════════
reset; attempt_seed
runs "[$(run 700 1 "$OTHER" completed '"success"')]"; jobs_fx 700 1 '[{"name":"a","conclusion":"success"}]'
step
[ "$RC" = 1 ] && ok || bad "C4: rc must be 1, got $RC"
[ "$(n_calls 'PUT ledger')" = 0 ] && ok || bad "C4: no ledger row"
scan; [ "$BGRC" = 1 ] && ok || bad "C4: bg_scan must refuse"

# ══ C5: CI + code BLOCK → rc 2, nothing written ══════════════════════════════
reset; review_body 9001 "$N2"; runs '[]'
step; [ "$RC" = 2 ] && ok || bad "C5: rc must be 2, got $RC"
no_writes C5

# ══ C6: a clear lifts only the id it names; ids accumulate ═══════════════════
reset; : > "$T/reviews"
review_row 9001 2026-10-03T11:00:00Z lead  "$CI_BODY"
review_row 9002 2026-10-03T12:00:00Z other "$CI_BODY"
review_body 9002 "$CI_BODY"
ledger_seed "502 9001"; scan
[ "$BGRC" = 1 ] && [ "$BGID" = 9002 ] && ok || bad "C6: naming A must leave B (rc=$BGRC id=$BGID)"
ledger_seed "502 9002"; scan
[ "$BGRC" = 1 ] && [ "$BGID" = 9001 ] && ok || bad "C6: naming B must leave A (rc=$BGRC id=$BGID)"
rm -rf "$T/d1"; attempt_seed; green2
step 9001; step 9002
[ "$(ledger_detail)" = "cleared 502 9001 9002" ] && ok || bad "C6: the detail must hold both ids, got '$(ledger_detail)'"
step 9002
[ "$(ledger_detail)" = "cleared 502 9001 9002" ] && ok || bad "C6: a repeat clear must not duplicate an id, got '$(ledger_detail)'"
scan; [ "$BGRC" = 0 ] && ok || bad "C6: both named → bg_scan rc 0 (rc=$BGRC out=$BGOUT)"

# ══ C7: a ledger outage keeps the block (rc 1, the block line) ═══════════════
reset; scan; BASE="$BGOUT"
ledger_seed "502 9001"; export LEDGER_OUTAGE=1; scan; unset LEDGER_OUTAGE
[ "$BGRC" = 1 ] && [ "$BGOUT" = "$BASE" ] && [ "$BGID" = 9001 ] && ok \
  || bad "C7: an outage must keep the block line (rc=$BGRC out=$BGOUT)"

# ══ C8: a cancelled / skipped latest run is RE-RUN, not dispatched ═══════════
for c in cancelled skipped; do
  reset; runs "[$(run 601 1 "$HEAD" completed "\"$c\"")]"
  step
  [ "$(n_calls "POST repos/$SLUG/actions/runs/601/rerun")" = 1 ] && ok || bad "C8/$c: one rerun POST"
  [ "$(n_calls '/dispatches')" = 0 ] && ok || bad "C8/$c: no dispatch"
  grep -qxF "BLOCK_CI_DISPATCH $PRKEY $HEAD run:601" "$T/mc.log" && ok || bad "C8/$c: log line missing: $(cat "$T/mc.log")"
  [ "$(line_of 'PUT pr-attempts')" -lt "$(line_of '/rerun')" ] && ok || bad "C8/$c: attempt row before the rerun POST"
done

# ══ O1: observe mode logs WOULD and writes nothing ═══════════════════════════
reset; runs '[]'; export ACTIONS=0
step
grep -qF "$PRKEY WOULD dispatch CI for ${HEAD:0:8} (block 9001)" "$T/mc.log" && ok || bad "O1: WOULD dispatch missing: $(cat "$T/mc.log")"
green2; step
grep -qF "$PRKEY WOULD clear block 9001 on ${HEAD:0:8} (run 502)" "$T/mc.log" && ok || bad "O1: WOULD clear missing: $(cat "$T/mc.log")"
[ "$RC" = 0 ] && ok || bad "O1: would-clear is rc 0, got $RC"
no_writes O1
[ ! -e "$T/d1" ] && ok || bad "O1: no D1 file may exist"
export ACTIONS=1

# ══ F1 / F2: a failed POST — no retry; one alert, none on a 422 ══════════════
reset; runs '[]'; fx_status POST "repos/$SLUG/actions/workflows/harness-ci.yml/dispatches" 500
step; step
[ "$(n_calls "$DISPATCH")" = 1 ] && ok || bad "F1: one POST over two ticks"
grep -qF "BLOCK_CI_DISPATCH_FAILED $PRKEY $HEAD harness-ci.yml 500" "$T/mc.log" && ok || bad "F1: FAILED line missing: $(cat "$T/mc.log")"
[ "$(grep -c . "$T/alerts.log")" = 1 ] && ok || bad "F1: exactly one alert ($(cat "$T/alerts.log"))"
reset; runs '[]'; fx_status POST "repos/$SLUG/actions/workflows/harness-ci.yml/dispatches" 422
step; step
[ "$(n_calls "$DISPATCH")" = 1 ] && ok || bad "F2: one POST over two ticks"
grep -qF "BLOCK_CI_DISPATCH_FAILED $PRKEY $HEAD harness-ci.yml 422 no workflow_dispatch trigger" "$T/mc.log" && ok || bad "F2: 422 line missing"
[ ! -s "$T/alerts.log" ] && ok || bad "F2: a 422 must not alert"
# The attempt row cannot be written → no POST at all.
reset; runs '[]'; export ATT_PUT_FAIL=1; step; unset ATT_PUT_FAIL
[ "$RC" = 2 ] && [ "$(n_calls 'POST ')" = 0 ] && ok || bad "F3: an unwritten attempt row must send nothing (rc=$RC)"
grep -qF "BLOCK_CI_DISPATCH_FAILED $PRKEY $HEAD attempt-row-unwritten" "$T/mc.log" && ok || bad "F3: log line missing"
# The attempt ledger is unreadable → no POST, the check still runs.
reset; green2; export ATT_OUTAGE=1; step; unset ATT_OUTAGE
[ "$(n_calls 'POST ')" = 0 ] && [ "$(n_calls 'PUT pr-attempts')" = 0 ] && ok || bad "F4: an unread attempt ledger must send nothing"
[ "$RC" = 0 ] && [ "$(ledger_detail)" = "cleared 502 9001" ] && ok || bad "F4: the green check still runs (rc=$RC)"
# The clear row cannot be written → rc 1 and no clear logged.
reset; attempt_seed; green2; export LEDGER_PUT_FAIL=1; step; unset LEDGER_PUT_FAIL
[ "$RC" = 1 ] && ok || bad "F5: an unwritten clear row is rc 1, got $RC"
grep -q block-cleared-by-ci "$T/mc.log" && bad "F5: logged a clear with no row" || ok

# ══ H1: the head moved → rc 3 before any write ═══════════════════════════════
reset; runs '[]'
fx GET "repos/$SLUG/pulls/$NUM" "{\"number\":$NUM,\"head\":{\"sha\":\"$OTHER\",\"ref\":\"$BR\"}}"
step; [ "$RC" = 3 ] && ok || bad "H1: rc must be 3, got $RC"
no_writes H1

# ══ W2-W4: which workflow ════════════════════════════════════════════════════
reset; runs '[]'; workflows "[$(wf harness-ci.yml),$(wf ci.yml)]"
review_body 9001 "- [BLOCK] the ci.yml workflow never ran on this head"
step
[ "$(n_calls "POST repos/$SLUG/actions/workflows/ci.yml/dispatches")" = 1 ] && [ "$(n_calls "$DISPATCH")" = 0 ] \
  && ok || bad "W2: the workflow the body names wins: $(grep POST "$T/calls.log")"
reset; runs '[]'; workflows "[$(wf a.yml),$(wf b.yml)]"
fx GET "repos/$SLUG/contents/.github/workflows/a.yml?ref=$BR_Q" "{\"content\":\"$(b64 $'on:\n  push:\n')\"}"
fx GET "repos/$SLUG/contents/.github/workflows/b.yml?ref=$BR_Q" "{\"content\":\"$(b64 $'on:\n  push:\n  workflow_dispatch:\n')\"}"
step
[ "$(n_calls "POST repos/$SLUG/actions/workflows/b.yml/dispatches")" = 1 ] && [ "$(n_calls 'POST ')" = 1 ] \
  && ok || bad "W3: the first workflow with a workflow_dispatch trigger: $(grep POST "$T/calls.log")"
reset; runs '[]'; workflows "[$(wf a.yml)]"
fx GET "repos/$SLUG/contents/.github/workflows/a.yml?ref=$BR_Q" "{\"content\":\"$(b64 $'on:\n  push:\n')\"}"
step; step
[ "$(n_calls 'POST ')" = 0 ] && ok || bad "W4: nothing dispatchable → no POST"
grep -qF "BLOCK_CI_DISPATCH_FAILED $PRKEY $HEAD no-dispatchable-workflow" "$T/mc.log" && ok || bad "W4: log line missing"
[ "$(grep -c . "$T/alerts.log")" = 1 ] && ok || bad "W4: one alert over two ticks"

# ══ V1-V3: a verdicts-table BLOCK row ════════════════════════════════════════
VRURL="$URL#issuecomment-555"
reset; : > "$T/reviews"; attempt_seed; green2
printf 'BLOCK\tlead\t7\t2026-10-03T11:00:00Z\t%s\tlead\n' "$VRURL" > "$T/standing"
fx GET "repos/$SLUG/issues/comments/555" "$(jq -nc --arg b "$CI_BODY" --arg s "$SLUG" '{id:555,issue_url:("https://api.github.com/repos/"+$s+"/issues/41"),body:$b}')"
scan; [ "$BGRC" = 1 ] && [ "$BGID" = verdict-7 ] && ok || bad "V1: the verdict row must refuse first (rc=$BGRC id=$BGID)"
step verdict-7
[ "$RC" = 0 ] && [ "$(ledger_detail)" = "cleared 502 verdict-7" ] && ok || bad "V1: clear row must name verdict-7 (rc=$RC '$(ledger_detail)')"
scan; [ "$BGRC" = 0 ] && ok || bad "V1: the cleared verdict row lifts (rc=$BGRC out=$BGOUT)"
reset; : > "$T/reviews"; attempt_seed; green2
printf 'BLOCK\tlead\t7\t2026-10-03T11:00:00Z\t-\tlead\n' > "$T/standing"
step verdict-7
[ "$RC" = 2 ] && ok || bad "V2: no report url → no body → rc 2, got $RC"
# TEST-CHANGE (BH-5793): an unreadable block body no longer just stands. The
# body is read a second way (the PR's reviews on this head), then ONE re-review
# is requested for the head, deduped by a pr-attempts row written first. No
# GitHub POST and no ledger row, as before.
[ "$(n_calls 'POST ')" = 0 ] && [ "$(n_calls 'PUT ledger')" = 0 ] && ok || bad "V2: a GitHub POST or a ledger row: $(cat "$T/calls.log")"
[ "$(n_calls "GET repos/$SLUG/pulls/$NUM/reviews?per_page=100")" = 1 ] && ok || bad "V2: the body must be re-fetched once from the PR's reviews: $(cat "$T/calls.log")"
[ "$(n_calls "PUT pr-attempts $SLUG $NUM rereview $HEAD")" = 1 ] && ok || bad "V2: one rereview attempt row: $(cat "$T/calls.log")"
[ "$(n_calls "lead-verdict request $SLUG $NUM $HEAD")" = 1 ] && ok || bad "V2: one re-review request: $(cat "$T/calls.log")"
[ "$(line_of "PUT pr-attempts $SLUG $NUM rereview")" -lt "$(line_of 'lead-verdict request')" ] && ok || bad "V2: the attempt row comes before the request"
grep -qF "needs re-review" "$T/mc.log" && ok || bad "V2: no 'needs re-review' log line: $(cat "$T/mc.log")"
scan; [ "$BGRC" = 1 ] && [ "$BGID" = verdict-7 ] && ok || bad "V2: bg_scan still refuses on verdict-7"
# V2b: the next tick on the same head requests nothing more
step verdict-7
[ "$(n_calls 'lead-verdict request')" = 1 ] && ok || bad "V2b: a second re-review request on the same head: $(cat "$T/calls.log")"
# V2c: observe mode writes nothing and requests nothing
reset; : > "$T/reviews"; export ACTIONS=0
printf 'BLOCK\tlead\t7\t2026-10-03T11:00:00Z\t-\tlead\n' > "$T/standing"
step verdict-7
no_writes V2c
[ "$(n_calls 'lead-verdict')" = 0 ] && grep -qF 'WOULD request a re-review' "$T/mc.log" && ok || bad "V2c observe mode: $(cat "$T/calls.log") / $(cat "$T/mc.log")"
export ACTIONS=1
# V2d: the request already exists for this head (409): the finished one is reset
reset; : > "$T/reviews"; echo 1 > "$T/lv.rc"
printf 'BLOCK\tlead\t7\t2026-10-03T11:00:00Z\t-\tlead\n' > "$T/standing"
step verdict-7
[ "$(n_calls 'lead-verdict request')" = 1 ] && [ "$(n_calls 'lead-verdict list')" = 1 ] && ok || bad "V2d a refused request falls back to list + reset: $(cat "$T/calls.log")"
rm -f "$T/lv.rc"
# V2e: the re-fetch finds the lead's BLOCK review on this head: classified, no re-review
# TEST-CHANGE (lead review lr-5809-fd9e59c3edcc): the fixture is now a real lead
# review (a Bot author, the lead-review marker, the "# Lead review lr-<n>-<head12>"
# title of THIS head, CHANGES_REQUESTED), because the fallback now binds to it.
LEAD_TITLE="# Lead review lr-$NUM-${HEAD:0:12} ($SLUG#$NUM at $HEAD)"
lead_review() { # lead_review <id> <state> <title-line> <body> [user-type] -> one review object
  jq -nc --argjson i "$1" --arg st "$2" --arg t "$3" --arg b "$4" --arg h "$HEAD" --arg u "${5:-Bot}" \
    '{id:$i,commit_id:$h,state:$st,user:{login:"cromford[bot]",type:$u},body:("<!-- lead-review:x -->\n"+$t+"\n\n"+$b)}'
}
reviews_fx() { fx GET "repos/$SLUG/pulls/$NUM/reviews?per_page=100" "$(printf '%s\n' "$@" | jq -sc .)"; }
v2_base() { reset; : > "$T/reviews"; attempt_seed; green2; printf 'BLOCK\tlead\t7\t2026-10-03T11:00:00Z\t-\tlead\n' > "$T/standing"; }
v2_base
reviews_fx '{"id":1,"commit_id":"0000000000000000000000000000000000000000","body":"old"}' "$(lead_review 2 CHANGES_REQUESTED "$LEAD_TITLE" "$CI_BODY")"
step verdict-7
[ "$RC" = 0 ] && [ "$(n_calls 'lead-verdict')" = 0 ] && ok || bad "V2e: the PR review on this head is the body (rc=$RC): $(cat "$T/calls.log")"
# V2f-V2i (lead review lr-5809-fd9e59c3edcc BLOCK): the fallback reads ONLY the
# lead's own BLOCK review of this head. Anything else is no body: no clear, the
# block stands and a re-review is requested.
v2_none() { # v2_none <case> — no ledger clear, rc 2, one re-review request
  step verdict-7
  [ "$RC" = 2 ] && [ "$(n_calls 'PUT ledger')" = 0 ] && [ "$(n_calls "lead-verdict request $SLUG $NUM $HEAD")" = 1 ] && ok \
    || bad "$1: read as the block body (rc=$RC): $(cat "$T/calls.log")"
}
# V2f: a CI-only VERDICT body with no lead marker (a tier or builder review)
v2_base
reviews_fx "$(jq -nc --arg b "$CI_BODY" --arg h "$HEAD" '{id:3,commit_id:$h,state:"CHANGES_REQUESTED",user:{login:"cromford[bot]",type:"Bot"},body:$b}')"
v2_none V2f
# V2g: the lead's review of this head is a MERGE, not the block
v2_base
reviews_fx "$(lead_review 4 APPROVED "$LEAD_TITLE" "$(printf 'Findings\n- none\n\nVERDICT: MERGE')")"
v2_none V2g
# V2h: a lead-marked BLOCK body posted by a person, not the App
v2_base
reviews_fx "$(lead_review 5 CHANGES_REQUESTED "$LEAD_TITLE" "$CI_BODY" User)"
v2_none V2h
# V2i: a lead BLOCK review whose title names another head
v2_base
reviews_fx "$(lead_review 6 CHANGES_REQUESTED "# Lead review lr-$NUM-${OTHER:0:12} ($SLUG#$NUM at $OTHER)" "$CI_BODY")"
v2_none V2i
reset; : > "$T/reviews"; attempt_seed; green2
printf 'BLOCK\tlead\t7\t2026-10-03T11:00:00Z\t%s\tlead\n' "$VRURL" > "$T/standing"
fx GET "repos/$SLUG/issues/comments/555" "$(jq -nc --arg b "$CI_BODY" '{id:555,issue_url:"https://api.github.com/repos/Evil/other/issues/1",body:$b}')"
step verdict-7
[ "$RC" = 2 ] && ok || bad "V3: a comment from another repo is no body, got $RC"
# TEST-CHANGE (BH-5793): no body is a re-review request now (see V2); still no
# GitHub POST and no ledger row, and the foreign comment is never read as one.
[ "$(n_calls 'POST ')" = 0 ] && [ "$(n_calls 'PUT ledger')" = 0 ] && ok || bad "V3: a GitHub POST or a ledger row: $(cat "$T/calls.log")"
[ "$(n_calls "lead-verdict request $SLUG $NUM $HEAD")" = 1 ] && ok || bad "V3: one re-review request: $(cat "$T/calls.log")"

# ══ G4 / G5 ══════════════════════════════════════════════════════════════════
reset; step "cr-123@abcabcabcabc"
[ "$RC" = 2 ] && [ ! -s "$T/calls.log" ] && ok || bad "G4: a cr-* id is rc 2 with zero calls (rc=$RC)"
reset; ledger_seed "r 90012"; scan
[ "$BGRC" = 1 ] && [ "$BGID" = 9001 ] && ok || bad "G5: 90012 must not lift 9001 (rc=$BGRC id=$BGID)"
reset; ledger_seed "r 900"; scan
[ "$BGRC" = 1 ] && [ "$BGID" = 9001 ] && ok || bad "G5: 900 must not lift 9001 (rc=$BGRC id=$BGID)"
# The run id in field 1 is not a block id.
reset; ledger_seed "9001 x"; scan
[ "$BGRC" = 1 ] && ok || bad "G5: the run-id field must not lift a block of the same number"
# A row whose status is not `cleared` lifts nothing.
reset; mkdir -p "$T/d1"; jq -nc '{status:"pending",detail:"502 9001"}' > "$(_d1 ledger block_ci_clear "$PRKEY@$HEAD")"; scan
[ "$BGRC" = 1 ] && ok || bad "G5: a non-cleared status must lift nothing"
# A row on another head lifts nothing on this one.
reset; mkdir -p "$T/d1"; jq -nc '{status:"cleared",detail:"502 9001"}' > "$(_d1 ledger block_ci_clear "$PRKEY@$OTHER")"; scan
[ "$BGRC" = 1 ] && ok || bad "G5: a clear on another head must lift nothing here"

# ══ E1: the conductor's READY arm, through the real lib loader ═══════════════
# bin/merge-conductor.sh's block-gate arm, lifted verbatim (as L10 does in
# tests/pr-health-lib.bh-3929-test.sh) and run in a subshell that loaded the
# step through bin/lib/merge-conductor-lib.sh. A refusal on a CI-only block must
# reach the real step and dispatch, and the refusal must still stand.
BLK=$(sed -n '/# >>> block gate$/,/# <<< block gate$/p' "$DIR/bin/merge-conductor.sh")
[ -n "$BLK" ] || bad "E1: the >>> block gate markers are gone from bin/merge-conductor.sh"
reset; runs '[]'
OUT=$(
  unset -f mc_block_ci_step _mc_bci_ci_only ph_ci_only_body
  . "$DIR/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
  # the lib's loader brought its own modules; put the fakes back on top
  mc_log()   { printf '%s\n' "$*" >> "$T/mc.log"; }
  mc_alert() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$T/alerts.log"; }
  bg_enforce() { return 0; }; bg_refuse() { echo REFUSED; return 0; }
  bg_why() { echo why; }; bg_reason() { echo reason; }
  ready_arm() {
    local SLUG="$SLUG" NUM="$NUM" HEAD="$HEAD" URL="$URL" P=demo KEY="$PRKEY" PROVIDER=native REC=x BR=x H="$H"
    eval "$BLK"
    echo FELL-THROUGH
  }
  ready_arm
)
grep -q REFUSED <<<"$OUT" && ! grep -q FELL-THROUGH <<<"$OUT" && ok || bad "E1: the refusal must stand ($OUT)"
[ "$(n_calls "$DISPATCH")" = 1 ] && ok || bad "E1: the READY arm must reach the real step and dispatch: $(cat "$T/calls.log")"

echo "block-gate-ci-clear: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ] || exit 1
