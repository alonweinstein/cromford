#!/bin/bash
# tests/review-autopilot-pause.bh-1672-test.sh — BH-1684 (BH-1672.3): the review
# autopilot honours a `reviews` pause.
#
# A pause is a row in the jobs worker's `pauses` table, mirrored onto the box as
# state/pauses.json and read through bin/lib/pause.sh. For this lane that means:
#
#   R. A live reviews row on project p: p lists no PRs (the gh stub never sees
#      its repo) and buys no review (the agent-call stub never sees p), and the
#      log carries exactly one `TICK p PAUSED(reviews) reason=runaway fix age=`
#      line. The other project on the box is reviewed as normal.
#   C. #1683's env shape `env:review-cap=<n>` is REPORTED on the TICK line and
#      nothing more: with cap 1 and two eligible PRs, one review is dispatched.
#      Cap 0, unset, and caps that are not 1..4 print no PAUSED( at all.
#   E. An expired row does not block. Neither does an ended row, a merges-only
#      row, a row for another project, a garbage expires_at, an empty pauses
#      array, a missing cache, or a box without the pause lib at all.
#   F. pause_refresh runs exactly once per tick.
#
# Everything below drives the REAL bin/review-autopilot.sh in a scratch
# $HARNESS with gh, agent-call and beat stubbed (D2) and asserts what the run
# did: gh calls, agent calls, log lines (D3). Nothing greps the script's source.
#
# Run from anywhere: bash tests/review-autopilot-pause.bh-1672-test.sh  (0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh). PAUSE_NOW is
# pinned to it, so every row's "live or expired" is a fact of the fixture.
NOW=$(date -u +%s)
ISO() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }
CREATED=$(ISO $((NOW - 86400)))

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/locks" "$H/env" "$H/state" "$T/fakebin"
cp "$DIR/bin/review-autopilot.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
chmod +x "$H/bin/"*.sh
printf 'p o/p - - 2 box-p 192.0.2.1\nq o/q - - 2 box-q 192.0.2.2\n' > "$H/fleet.conf"
: > "$H/env/global.env"
cp "$DIR/bin/lib/review-model.sh" "$H/bin/lib/"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" p q

# THE PAUSE LIB, real, with the two #1683 seams replaced the way the plan fixes
# them: refresh counts its calls and leaves the hand-written cache alone, and
# env_shapes follows #1683's contract for this knob (a cap of 1..4 is a pause
# shape; 0, unset and anything else is not).
install_pause_lib() {
  cp "$DIR/bin/lib/pause.sh" "$DIR/bin/lib/pause-rows.sh" "$H/bin/lib/"
  { printf '\npause_refresh(){ echo x >> %q; return 0; }\n' "$T/refresh.calls"
    cat <<'EOF'
pause_env_shapes() {
  case "${REVIEW_AUTOPILOT_DAILY_CAP:-}" in
    1|2|3|4) printf 'env:review-cap=%s\n' "$REVIEW_AUTOPILOT_DAILY_CAP" ;;
  esac
  return 0
}
EOF
  } >> "$H/bin/lib/pause.sh"
}
install_pause_lib

# Open PRs: p has two harness PRs (#7, #8), q has one (#9). All a day old.
PR() { jq -n --arg sha "$2" --arg c "$CREATED" --argjson n "$1" --arg r "$3" \
  '{number:$n,html_url:("https://github.com/"+$r+"/pull/"+($n|tostring)),title:"BH-x: a thing",
    body:"Closes #1",head:{sha:$sha,ref:("ticket/x"+($n|tostring))},base:{ref:"main"},
    draft:false,user:{login:"operator",type:"User"},created_at:$c,updated_at:$c,
    merged_at:null,closed_at:null,labels:[],state:"open"}'; }
{ PR 7 aaaaaaaaaaaa0000000000000000000000000007 o/p
  PR 8 aaaaaaaaaaaa0000000000000000000000000008 o/p; } | jq -s . > "$T/pulls-p.json"
PR 9 aaaaaaaaaaaa0000000000000000000000000009 o/q | jq -s . > "$T/pulls-q.json"

# gh: every call recorded; the PR list answers per repo in the REST shape
# bin/lib/gh-rest.sh parses.
{ printf '#!/bin/bash\nT=%q\n' "$T"; cat <<'EOF'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
if [ "${1:-}" = pr ] && [ "${2:-}" = comment ]; then echo post >> "$T/post-count.txt"; exit 0; fi
case "$*" in
  *repos/o/p/pulls\?*|*repos/o/q/pulls\?*|api\ repos/o/p/pulls|api\ repos/o/q/pulls)
    R=p; case "$*" in *repos/o/q/*) R=q ;; esac
    case "$*" in *" -i "*) printf 'HTTP/2.0 200 OK\r\n\r\n' ;; esac
    cat "$T/pulls-$R.json" ;;
  *"pr diff"*--name-only*)  printf 'bin/x.sh\n' ;;
  *"pr diff"*)              printf 'diff --git a/bin/x.sh b/bin/x.sh\n+echo hi\n' ;;
  *"pr view"*--json\ body*) printf 'Closes #1\n' ;;
  *"pr view"*)              printf 'mergeable=MERGEABLE mergeState=CLEAN checks=ci=SUCCESS\n' ;;
  api\ repos/*/issues/*/comments*) printf '[]\n' ;;
  *) : ;;
esac
exit 0
EOF
} > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"

# The billable call: argv is `review <project> <model> <timeout> <out> @<prompt>`.
{ printf '#!/bin/bash\nT=%q\n' "$T"; cat <<'EOF'
printf '%s\n' "$*" >> "$T/agent-calls.txt"
printf 'Reads fine.\n\nVERDICT: MERGE — reads fine\n' > "$5"
exit 0
EOF
} > "$H/bin/agent-call.sh"
{ printf '#!/bin/bash\n'; echo 'exit 0'; } > "$H/bin/beat.sh"
chmod +x "$H/bin/agent-call.sh" "$H/bin/beat.sh"

RLOG="$H/logs/review-autopilot.log"
CACHE="$H/state/pauses.json"
PNOW="$NOW"
CAPV=""          # REVIEW_AUTOPILOT_DAILY_CAP for the next RUN; empty = unset
RUN() { ( if [ -n "$CAPV" ]; then export REVIEW_AUTOPILOT_DAILY_CAP="$CAPV"; else unset REVIEW_AUTOPILOT_DAILY_CAP; fi
          PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" GH_TOKEN="" \
          PAUSE_NOW="$PNOW" bash "$H/bin/review-autopilot.sh" >>"$T/run.log" 2>&1 ) || true; }
# Counts are `wc -l` / `grep -c ... || true`, never `grep -c || echo 0`.
LINES()   { wc -l < "$1" 2>/dev/null | tr -d ' '; }
ACALLS()  { awk -v p="$1" '$1=="review" && $2==p' "$T/agent-calls.txt" 2>/dev/null | wc -l | tr -d ' '; }
GHFOR()   { grep -cE "o/$1([^a-zA-Z0-9_.-]|$)" "$T/gh-calls.txt" 2>/dev/null || true; }
LOGC()    { grep -cF -- "$1" "$RLOG" 2>/dev/null || true; }
RESET()   { scratch_rm "$H/state/review-autopilot"; mkdir -p "$H/state/review-autopilot"
            : > "$T/agent-calls.txt"; : > "$T/gh-calls.txt"; : > "$T/post-count.txt"
            : > "$RLOG"; : > "$T/refresh.calls"; : > "$T/run.log"; rm -f "$CACHE"; PNOW="$NOW"; CAPV=""; }
# ROW <id> <scope> <what> <reason> <created_epoch> <expires_at-string> [ended_at]
ROW() { jq -n --arg id "$1" --arg s "$2" --arg w "$3" --arg r "$4" --arg c "$(ISO "$5")" \
          --arg e "$6" --arg end "${7:-}" \
  '{id:$id,scope:$s,what:$w,reason:$r,actor:"operator",created_at:$c,expires_at:$e,
    ended_at:(if $end=="" then null else $end end),end_reason:(if $end=="" then null else "resumed" end)}'; }
CACHEW() { jq -s '{pauses:., truncated:false}' > "$CACHE"; }
EXP21H=$(ISO $((NOW + 75600)))
: > "$T/run.log"

# ============================================================================
# R. A live reviews row on p: no PR list, no model call, one TICK line for p
# ============================================================================
RESET
ROW r1 p reviews "runaway fix" $((NOW - 7500)) "$EXP21H" | CACHEW
RUN
[ "$(GHFOR p)" = 0 ] && ok || bad "R: a paused project must list no PRs and touch no PR (gh calls for o/p=$(GHFOR p))"
[ "$(ACALLS p)" = 0 ] && ok || bad "R: a paused project must buy no review (agent calls for p=$(ACALLS p))"
[ "$(LOGC 'TICK p PAUSED(reviews) reason=runaway fix age=')" = 1 ] && ok \
  || bad "R: exactly one 'TICK p PAUSED(reviews) reason=runaway fix age=' line (got $(LOGC 'TICK p PAUSED(reviews) reason=runaway fix age='))"
[ "$(LOGC 'TICK p PAUSED(reviews) reason=runaway fix age=2h 5m')" = 1 ] && ok \
  || bad "R: the age is now - created_at through pause_dur (want '2h 5m'; log: $(grep -F 'TICK p' "$RLOG"))"
[ "$(ACALLS q)" = 1 ] && ok || bad "R: the unpaused project on the same box is still reviewed (agent calls for q=$(ACALLS q))"
[ "$(LOGC 'TICK q')" = 0 ] && ok || bad "R: no TICK line for an unpaused project"
[ "$(LINES "$T/refresh.calls")" = 1 ] && ok || bad "R: pause_refresh runs once per tick (calls=$(LINES "$T/refresh.calls"))"
RUN
[ "$(GHFOR p)" = 0 ] && [ "$(ACALLS p)" = 0 ] && ok || bad "R: a second paused tick still buys nothing for p"
[ "$(LINES "$T/refresh.calls")" = 2 ] && ok || bad "R: two ticks, two refreshes (calls=$(LINES "$T/refresh.calls"))"

# M. Two live reviews rows for p (fleet + project): skipped once, one line, and
# the row with the latest expiry supplies the reason.
RESET
{ ROW m1 fleet reviews "fleet hold" $((NOW - 600)) "$(ISO $((NOW + 3600)))"
  ROW m2 p reviews "runaway fix" $((NOW - 7500)) "$EXP21H"; } | CACHEW
RUN
[ "$(LOGC 'TICK p ')" = 1 ] && ok || bad "M: fleet + project rows skip p once with one TICK line (got $(LOGC 'TICK p '))"
[ "$(LOGC 'TICK p PAUSED(reviews) reason=runaway fix age=2h 5m')" = 1 ] && ok \
  || bad "M: the latest-expiring row names the reason (log: $(grep -F 'TICK p' "$RLOG"))"
[ "$(LOGC 'TICK q PAUSED(reviews) reason=fleet hold age=10m')" = 1 ] && ok \
  || bad "M: a fleet row pauses q too (log: $(grep -F 'TICK q' "$RLOG"))"
[ "$(ACALLS p)" = 0 ] && [ "$(ACALLS q)" = 0 ] && ok || bad "M: a fleet reviews pause buys no review anywhere"

# ============================================================================
# C. The env shape is reported, and the cap still caps
# ============================================================================
RESET
CAPV=1
RUN
[ "$(LOGC 'TICK p PAUSED(env:review-cap=1) cap=1')" = 1 ] && ok \
  || bad "C1: the TICK line reports the env shape (log: $(grep -F 'TICK' "$RLOG"))"
[ "$(ACALLS p)" = 1 ] && ok || bad "C1: two eligible PRs, cap 1 -> exactly one review for p (got $(ACALLS p))"
[ "$(LOGC 'daily review cap 1 reached')" -ge 1 ] && ok || bad "C1: the cap logic still runs and says so"
for CV in 0 "" 5 50 abc; do
  RESET
  CAPV="$CV"
  RUN
  [ "$(LOGC 'PAUSED(')" = 0 ] && ok || bad "C'$CV': no PAUSED( line for a cap that is not a pause shape"
  [ "$(ACALLS p)" -ge 1 ] && ok || bad "C'$CV': p is reviewed (agent calls=$(ACALLS p))"
done

# ============================================================================
# E / N. Rows that must NOT stop reviews (and must print no label)
# ============================================================================
neg() {  # neg <label> — the cache is already written; the tick must be normal
  RUN
  [ "$(ACALLS p)" = 2 ] && ok || bad "$1: p must be reviewed as normal (agent calls for p=$(ACALLS p))"
  [ "$(GHFOR p)" -ge 1 ] && ok || bad "$1: p's PRs must be listed"
  [ "$(LOGC 'PAUSED(')" = 0 ] && ok || bad "$1: no PAUSED( label (log: $(grep -F 'PAUSED(' "$RLOG"))"
  [ "$(LINES "$T/refresh.calls")" = 1 ] && ok || bad "$1: one refresh per tick (calls=$(LINES "$T/refresh.calls"))"
}
RESET; ROW e1 p reviews "runaway fix" $((NOW - 7500)) "$EXP21H" | CACHEW
PNOW=$((NOW + 75601)); neg "E expired row"
RESET; ROW n1 p reviews "runaway fix" $((NOW - 7500)) "$EXP21H" "$(ISO $((NOW - 60)))" | CACHEW; neg "N ended row"
RESET; ROW n2 p merges "runaway fix" $((NOW - 7500)) "$EXP21H" | CACHEW; neg "N merges-only row"
RESET; ROW n3 other reviews "runaway fix" $((NOW - 7500)) "$EXP21H" | CACHEW; neg "N other project's row"
RESET; ROW n4 p reviews "runaway fix" $((NOW - 7500)) "not-a-date" | CACHEW; neg "N garbage expires_at"
RESET; printf '{"pauses":[],"truncated":false}\n' > "$CACHE"; neg "N empty pauses"
RESET; neg "N missing cache"
RESET; printf 'not json{' > "$CACHE"; neg "N garbage cache"

# A box mid-sync without the pause lib runs exactly as before.
RESET
rm -f "$H/bin/lib/pause.sh" "$H/bin/lib/pause-rows.sh"
ROW l1 p reviews "runaway fix" $((NOW - 7500)) "$EXP21H" | CACHEW
RUN
[ "$(ACALLS p)" = 2 ] && ok || bad "L: no pause lib -> p reviewed as normal (agent calls=$(ACALLS p))"
grep -qiE 'command not found|syntax error' "$T/run.log" && bad "L: no pause lib must not error ($(grep -iE 'command not found|syntax error' "$T/run.log" | head -2))" || ok
install_pause_lib

echo "review-autopilot-pause: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
