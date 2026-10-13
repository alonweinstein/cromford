#!/bin/bash
# tests/mc/ci-timeout-rekick.bh-3775-test.sh — A RERUN OF A TIMED-OUT RUN NEVER
# SEES THE FIXED WORKFLOW (BH-3787, slice 4 of BH-3775).
#
# A PR whose required check died at its `timeout-minutes` gets the BH-636
# ladder's `gh run rerun`. A rerun keeps the run's old merge ref and its old
# workflow file, so once the repo has fixed that file on the base branch the
# rerun dies the same way and the PR sits in WAIT_CI with a CI_FLAKE_TWICE
# page. bin/lib/mc-ci-timeout-rekick.sh fills the contract's cit_rekick_step:
# when the base has a commit touching the dead run's workflow file AFTER the run
# started, the conductor closes and reopens the PR (mc_kick_ci) ONCE per head,
# for a fresh pull_request run, and skips the rerun.
#
#   R0  red-first: on the contract alone the R1 shape gets a rerun, no PATCH
#   R1  two stuck heads, base changed after the run: 2+2 PATCH, two citkick
#       marks, no rerun, ONE commits read for both PRs in the tick
#   R2  the next tick on the same heads: no new PATCH
#   R3  base change OLDER than the run: no PATCH, the ladder's rerun
#   R4  #41 moves to a new head: exactly one more close/reopen, #41 only
#   R5  the commits read answers 500: no PATCH, no mark
#   R6  a HOLD on #41's ticket: no close, the log says held, the mark is kept
#   R7  observe mode: no PATCH, no mark, a `would kick` line
#
# Driven, never grepped: every row runs the real bin/merge-conductor.sh and
# asserts on the argv the stub gh recorded, attempts.txt and the log. The scan
# slice is NOT a dependency: a fixture bin/lib/mc-ci-timeout-scan.sh in the
# scratch tree fills CIT_TIMEOUTS from $T/cit-<head>.tsv.
# Every timestamp is derived from ONE clock read (NOW).
# Run from anywhere: tests/mc/ci-timeout-rekick.bh-3775-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/../lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date -u +%s)
ISO() { date -u -d "@$((NOW - $1))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
        || date -u -r $((NOW - $1)) '+%Y-%m-%dT%H:%M:%SZ'; }

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib/mc" "$T/h/bin/lib/jobs" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" \
  "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-budget.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/hold.sh" \
   "$DIR/bin/lib/mc-ci-timeout.sh" "$T/h/bin/lib/"
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
: > "$T/h/env/global.env"
printf 'demo-os example-org/demo-os - - 2 box-demo\n' > "$T/h/fleet.conf"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/codegraph-ensure.sh"
chmod +x "$T/h/bin/agent-call.sh" "$T/h/bin/beat.sh" "$T/h/bin/codegraph-ensure.sh"
# The scan slice's stand-in, overwriting any real one: one fixture file a head.
# shellcheck disable=SC2016
printf 'cit_scan() { [ -r "%s/cit-$3.tsv" ] || return 0; CIT_TIMEOUTS=$(cat "%s/cit-$3.tsv"); }\n' "$T" "$T" \
  > "$T/h/bin/lib/mc-ci-timeout-scan.sh"

# ---- the fake gh: bh-636's, plus the commits read and the hold reads --------
{ printf '#!/bin/bash\nT=%s\n' "$T"; cat <<'SHIM'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
case "$1 $2 $3 $4 $5" in
  "api -i -X GET repos/"*"/actions/runs?head_sha="*)
    SHA=${5##*head_sha=}; SHA=${SHA%%&*}
    F="$T/runs-$SHA.json"; [ -f "$F" ] || F="$T/runs-empty.json"
    printf 'HTTP/1.1 200 OK\r\n\r\n'; cat "$F"; exit 0 ;;
  "api -i -X GET repos/"*"/commits?sha="*)
    [ -f "$T/commits-fail" ] && { printf 'HTTP/1.1 500 Server Error\r\n\r\n{"message":"boom"}'; exit 0; }
    printf 'HTTP/1.1 200 OK\r\n\r\n'; cat "$T/commits.json"; exit 0 ;;
esac
case "$*" in
  "run rerun "*) printf '%s\n' "$*" >> "$T/reruns.txt"; exit 0 ;;
  *"pr merge"*|*"push"*|*"pr comment"*|*"issue close"*|*"issue comment"*|*"pr review"*|*"pr edit"*)
    printf '%s\n' "$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"api -X PATCH"*) printf '%s\n' "$*" >> "$T/patches.txt"; exit 0 ;;
  *"issues/41/comments"*) [ -f "$T/hold-comments.json" ] && { cat "$T/hold-comments.json"; exit 0; }; echo "" ;;
  "api repos/example-org/demo-os/issues/41") [ -f "$T/hold-issue.json" ] && { cat "$T/hold-issue.json"; exit 0; }; echo "" ;;
  "api repos/example-org/demo-os/pulls/41") [ -f "$T/hold-pr.json" ] && { cat "$T/hold-pr.json"; exit 0; }; echo "" ;;
  *"pr list -R example-org/demo-os --state open"*) cat "$T/list.json" ;;
  *"pr list"*) echo "[]" ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
SHIM
} > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nURL="${!#}"\ncase "$URL" in */api/ledger) printf '"'"'{"ok":true}\\n200\\n'"'"' ;; *) printf '"'"'{"error":"not found"}\\n404\\n'"'"' ;; esac\n' > "$T/fakebin/curl"
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"
echo '{"workflow_runs":[]}' > "$T/runs-empty.json"

WF=.github/workflows/ci.yml
STARTED=$(ISO 3600)
H41=4141414141aa; H42=4242424242bb; H41B=4141414141cc
# stuck <head> <run_id> — the head's one run TIMED OUT, and the scan fixture
# names it as a TIMEOUT in the contract's 5-field shape.
stuck() {
  jq -nc --arg t "$STARTED" --argjson id "$2" '{workflow_runs:[{id:$id,name:"ci",status:"completed",
    conclusion:"timed_out",run_started_at:$t,created_at:$t,run_attempt:1,
    html_url:("https://github.com/example-org/demo-os/actions/runs/"+($id|tostring))}]}' > "$T/runs-$1.json"
  printf '%s\tci\t%s\t10\t%s\n' "$2" "$WF" "$STARTED" > "$T/cit-$1.tsv"
}
base_changed() { jq -nc --arg d "$(ISO "$1")" '[{sha:"cafe",commit:{committer:{date:$d}}}]' > "$T/commits.json"; }
mkrec() { # mkrec <num> <head>
  local d="$T/h/builds/pool-demo-os-TK-$1-2026100100$1"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/example-org/demo-os/pull/$1" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  echo "$2" > "$d/reviewed-sha"
}
list_row() { # list_row <num> <head>
  printf '{"number":%s,"url":"https://github.com/example-org/demo-os/pull/%s","headRefOid":"%s","headRefName":"ticket/pb-%s","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"main"}' \
    "$1" "$1" "$2" "$1"
}
list() { local out='' sep='' a; for a in "$@"; do out+="$sep$(list_row "${a%%:*}" "${a#*:}")"; sep=,; done; printf '[%s]' "$out" > "$T/list.json"; }
# fresh — a clean conductor state and empty recorders; the scratch tree stays.
fresh() {
  rm -rf "$T/h/state" "$T/h/builds" "$T/h/logs" "$T/h/locks"
  mkdir -p "$T/h/state" "$T/h/builds" "$T/h/logs" "$T/h/locks"
  touch "$T/h/flags/merge-conductor-actions" "$T/h/logs/ALERTS.log"
  rm -f "$T/commits-fail" "$T"/hold-*.json
  : > "$T/gh-calls.txt"; : > "$T/reruns.txt"; : > "$T/gh-writes.txt"; : > "$T/patches.txt"
  mkrec 41 "$H41"; mkrec 42 "$H42"; list "41:$H41" "42:$H42"
  base_changed 600
}
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
  MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_KICK_REOPEN_TRIES=1 MC_KICK_REOPEN_SLEEP=0 \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
A="$T/h/state/merge-conductor/attempts.txt"
CLOG="$T/h/logs/merge-conductor.log"
K41='example-org/demo-os#41'; K42='example-org/demo-os#42'
npatch() { grep -c . "$T/patches.txt" 2>/dev/null | tr -dc '0-9'; }
has_patch() { grep -qE "repos/example-org/demo-os/pulls/$1 .*state=$2" "$T/patches.txt"; }
stuck "$H41" 941; stuck "$H42" 942; stuck "$H41B" 943

# ---- R0 red-first: the contract alone --------------------------------------
fresh
rm -f "$T/h/bin/lib/mc-ci-timeout-rekick.sh"
run_tick
[ "$(npatch)" = 0 ] && ok || bad "R0: with no rekick lib nothing closes a PR (patches: $(cat "$T/patches.txt"))"
grep -q 'run rerun 941' "$T/reruns.txt" && ok || bad "R0: with no rekick lib the BH-636 ladder re-runs the dead run (reruns: $(cat "$T/reruns.txt"))"

# From here on the lib under test is in the scratch tree.
cp "$DIR/bin/lib/mc-ci-timeout-rekick.sh" "$T/h/bin/lib/" 2>/dev/null \
  || bad "the lib bin/lib/mc-ci-timeout-rekick.sh does not exist"

# ---- R1 two stuck heads, the workflow changed on base after the runs ---------
fresh
run_tick
{ has_patch 41 closed && has_patch 41 open && has_patch 42 closed && has_patch 42 open && [ "$(npatch)" = 4 ]; } \
  && ok || bad "R1: one close and one reopen per PR, 4 PATCH lines (patches: $(cat "$T/patches.txt"))"
{ grep -qxF "citkick $K41 $H41" "$A" && grep -qxF "citkick $K42 $H42" "$A"; } \
  && ok || bad "R1: a citkick mark per (PR, head) (attempts: $(cat "$A" 2>/dev/null))"
[ ! -s "$T/reruns.txt" ] && ok || bad "R1: a kicked PR gets no rerun — it would reuse the old merge ref (reruns: $(cat "$T/reruns.txt"))"
[ "$(grep -c 'CI_TIMEOUT_REKICK example-org/demo-os#4[12] ' "$CLOG")" = 2 ] \
  && ok || bad "R1: two CI_TIMEOUT_REKICK log lines (log: $(grep -o 'CI_TIMEOUT_REKICK.*' "$CLOG"))"
grep -q "CI_TIMEOUT_REKICK $K41 $H41 (ci: $WF changed on main after the run)" "$CLOG" \
  && ok || bad "R1: the log names the check, the workflow file and the base (log: $(grep -o 'CI_TIMEOUT_REKICK.*' "$CLOG"))"
[ "$(grep -c 'commits?sha=main' "$T/gh-calls.txt")" = 1 ] \
  && ok || bad "R1: one commits read per (slug, base, path) per tick, got $(grep -c 'commits?sha=main' "$T/gh-calls.txt")"
grep -q 'commits?sha=main&path=.github/workflows/ci.yml&per_page=1' "$T/gh-calls.txt" \
  && ok || bad "R1: the read asks the base branch for the workflow path (calls: $(grep commits "$T/gh-calls.txt"))"

# ---- R2 the next tick on the same heads ------------------------------------
: > "$T/patches.txt"
run_tick
[ "$(npatch)" = 0 ] && ok || bad "R2: never kick the same head twice (patches: $(cat "$T/patches.txt"))"
[ "$(grep -c "^citkick $K41 $H41\$" "$A")" = 1 ] && ok || bad "R2: no second mark for the same head"

# ---- R3 the base change is OLDER than the run ------------------------------
fresh; base_changed 7200
run_tick
[ "$(npatch)" = 0 ] && ok || bad "R3: an older workflow change buys no kick (patches: $(cat "$T/patches.txt"))"
{ grep -q 'run rerun 941' "$T/reruns.txt" && grep -q 'run rerun 942' "$T/reruns.txt"; } \
  && ok || bad "R3: the ladder runs as usual (reruns: $(cat "$T/reruns.txt"))"
grep -q '^citkick ' "$A" && bad "R3: no mark without a kick (attempts: $(cat "$A"))" || ok
# R3b: a change at exactly the run's start is not AFTER it.
fresh; base_changed 3600
run_tick
[ "$(npatch)" = 0 ] && ok || bad "R3b: a change dated the run's own start is not after it (patches: $(cat "$T/patches.txt"))"

# ---- R4 a new head on #41 ---------------------------------------------------
fresh
run_tick
: > "$T/patches.txt"
mkrec 41 "$H41B"; list "41:$H41B" "42:$H42"
run_tick
{ [ "$(npatch)" = 2 ] && has_patch 41 closed && has_patch 41 open; } \
  && ok || bad "R4: a new head buys exactly one more close/reopen, for #41 only (patches: $(cat "$T/patches.txt"))"
grep -qxF "citkick $K41 $H41B" "$A" && ok || bad "R4: the new head has its own mark (attempts: $(cat "$A"))"

# ---- R5 the commits read fails ---------------------------------------------
fresh; touch "$T/commits-fail"
run_tick
[ "$(npatch)" = 0 ] && ok || bad "R5: a failed read is never 'changed' (patches: $(cat "$T/patches.txt"))"
grep -q '^citkick ' "$A" && bad "R5: a failed read writes no mark (attempts: $(cat "$A"))" || ok
grep -q 'run rerun 941' "$T/reruns.txt" && ok || bad "R5: and the ladder runs as usual (reruns: $(cat "$T/reruns.txt"))"

# ---- R6 a HOLD on #41's ticket ---------------------------------------------
fresh
jq -nc --arg h "$H41" '{number:41,state:"open",head:{ref:"ticket/TK-41",sha:$h},base:{ref:"main"}}' > "$T/hold-pr.json"
jq -nc '{number:41,state:"open",labels:[{name:"ai-build"}],title:"TK-41",body:"## Scope"}' > "$T/hold-issue.json"
jq -nc --arg c "$(ISO 600)" '[{body:"HOLD — looking at this by hand",created_at:$c,user:{type:"User"}}]' > "$T/hold-comments.json"
run_tick
has_patch 41 closed && bad "R6: a held ticket's PR is never closed (patches: $(cat "$T/patches.txt"))" || ok
grep -q "$K41 held, PR kept" "$CLOG" && ok || bad "R6: the log says the PR was held (log: $(grep -o 'demo-os#41 .*' "$CLOG" | tail -3))"
grep -q "CI_TIMEOUT_REKICK failed $K41 $H41 .*held or refused" "$CLOG" \
  && ok || bad "R6: the rekick says its kick did not land (log: $(grep -o 'CI_TIMEOUT_REKICK.*' "$CLOG"))"
grep -qxF "citkick $K41 $H41" "$A" && ok || bad "R6: the mark is kept, so a held PR is not re-asked every tick (attempts: $(cat "$A"))"
has_patch 42 closed && ok || bad "R6: #42 is not held and is still kicked (patches: $(cat "$T/patches.txt"))"

# ---- R7 observe mode -------------------------------------------------------
fresh; rm -f "$T/h/flags/merge-conductor-actions"
run_tick
[ "$(npatch)" = 0 ] && ok || bad "R7: observe mode closes nothing (patches: $(cat "$T/patches.txt"))"
grep -q '^citkick ' "$A" && bad "R7: observe mode writes no mark (attempts: $(cat "$A"))" || ok
grep -q "$K41 would kick ${H41:0:8}" "$CLOG" && ok || bad "R7: observe mode logs what it would do (log: $(grep -o 'demo-os#41 .*' "$CLOG" | tail -3))"

echo "ci-timeout-rekick.bh-3775: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
