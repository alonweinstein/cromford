#!/bin/bash
# tests/mc/ci-timeout-contract.bh-3784-test.sh — THE CI-TIMEOUT CONTRACT
# (BH-3784, the first slice of BH-3775).
#
# bin/lib/mc-ci-timeout.sh is the seam the BH-636 flake ladder in
# bin/merge-conductor.sh now consults before it re-runs a cancelled/timed_out
# run. This slice ships the knobs, the ledger, cit_assess and three fail-open
# stubs, so what is pinned here is the contract and its absence of effect:
#   K1  sourcing the lib with no registry gives the 8 code defaults, and a
#       non-integer value falls back to its default;
#   K2  cit_assess on the stubs leaves CIT_RUNS_LEFT = the input flake list and
#       resets every stale global; MC_CI_TIMEOUT=0 gives the same, and so
#       does a scan that reports a timeout (K2c: the other two stubs);
#   K3  part files replace the stubs in order (scan, rekick, budget), a step
#       that returns non-zero leaves the reset values, and an empty scan never
#       reaches the budget step;
#   K4  cit_ledger_put writes one 11-field line, a tab in the check name
#       becoming a space; no root at all refuses;
#   K5  the real bin/merge-conductor.sh on bh-636's B1 shape: exactly one
#       rerun, reason `checks flake`, no CI_TIMEOUT_ text anywhere;
#   K5b the conductor really calls cit_assess (a scan part file's sentinel).
# Run from anywhere: tests/mc/ci-timeout-contract.bh-3784-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/../lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
LIB="$DIR/bin/lib/mc-ci-timeout.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date -u +%s)
[ -r "$LIB" ] || { echo "FAIL: $LIB is missing"; echo "ci-timeout-contract.bh-3784: 0 passed, 1 failed"; exit 1; }

# A clean shell: no knob, registry or harness root inherited from the caller.
clean() { env -i PATH="$PATH" HOME="$T" "$@"; }

# ---- K1 the code defaults, with no registry ---------------------------------
mkdir -p "$T/k1/bin/lib"; cp "$LIB" "$T/k1/bin/lib/"
K1OUT=$(clean MC_STATE_DIR="$T/k1/state" bash -c '. "$1/bin/lib/mc-ci-timeout.sh"
  printf "%s " "$MC_CI_TIMEOUT" "$MC_CI_TIMEOUT_SLACK_S" "$MC_CI_TIMEOUT_DEFAULT_MIN" "$MC_CI_TIMEOUT_MIN_PRS" \
    "$MC_CI_TIMEOUT_RATIO_PCT" "$MC_CI_TIMEOUT_HISTORY_N" "$MC_CI_TIMEOUT_HISTORY_MIN" "$MC_CI_TIMEOUT_WINDOW_S"
  printf "%s %s" "$CIT_LEDGER" "$CIT_FIRING_TSV"' _ "$T/k1")
[ "$K1OUT" = "1 60 360 3 50 20 10 259200 $T/k1/state/ci-timeout.tsv $T/k1/state/ci-timeout-firing.tsv" ] \
  && ok || bad "K1: the 8 code defaults and the two state paths, got '$K1OUT'"
K1B=$(clean MC_CI_TIMEOUT_SLACK_S=abc MC_CI_TIMEOUT_WINDOW_S=90 bash -c '. "$1/bin/lib/mc-ci-timeout.sh"; printf "%s %s" "$MC_CI_TIMEOUT_SLACK_S" "$MC_CI_TIMEOUT_WINDOW_S"' _ "$T/k1")
[ "$K1B" = "60 90" ] && ok || bad "K1b: a non-integer knob falls back to its default and an integer one is kept, got '$K1B'"
K1C=$(clean HARNESS="$T/k1h" bash -c '. "$1/bin/lib/mc-ci-timeout.sh"; printf "%s" "$CIT_LEDGER"' _ "$T/k1")
[ "$K1C" = "$T/k1h/state/merge-conductor/ci-timeout.tsv" ] && ok || bad "K1c: no MC_STATE_DIR resolves under HARNESS, got '$K1C'"

# ---- K2 cit_assess on the stubs ---------------------------------------------
FL=$(printf '11|CI\n12|Lint')   # the id|name shape mc_ci_flake_runs prints
# shellcheck disable=SC2016
K2SCRIPT='. "$1/bin/lib/mc-ci-timeout.sh"
  CIT_FIRING=1; CIT_SKIP_RUNG=1; CIT_REKICK=1; CIT_TIMEOUTS=stale; CIT_CHECK=stale; CIT_T=9
  cit_assess o/r o/r#1 h b 1 "$2"; rc=$?
  printf "%s\n--\n%s|%s|%s|%s|%s|%s|%s" "$CIT_RUNS_LEFT" "$CIT_FIRING" "$CIT_REKICK" "$CIT_SKIP_RUNG" "$CIT_TIMEOUTS" "$CIT_CHECK" "$CIT_T" "$rc"'
WANT2=$(printf '%s\n--\n0|0|0||||0' "$FL")
K2OUT=$(clean MC_STATE_DIR="$T/k2" bash -c "$K2SCRIPT" _ "$T/k1" "$FL")
[ "$K2OUT" = "$WANT2" ] && ok || bad "K2: stubs must leave the flake list whole and reset every global, got: $K2OUT"
K2OFF=$(clean MC_STATE_DIR="$T/k2" MC_CI_TIMEOUT=0 bash -c "$K2SCRIPT" _ "$T/k1" "$FL")
[ "$K2OFF" = "$WANT2" ] && ok || bad "K2: MC_CI_TIMEOUT=0 must give the same, got: $K2OFF"
[ ! -e "$T/k2/ci-timeout-firing.tsv" ] && [ ! -e "$T/k2/ci-timeout.tsv" ] \
  && ok || bad "K2: nothing writes the ledger or the firing file in this slice"
# K2c: a scan that DOES report a timeout reaches the rekick and budget stubs,
# and those stubs must still hand the whole list back.
mkdir -p "$T/k2c/bin/lib"; cp "$LIB" "$T/k2c/bin/lib/"
# shellcheck disable=SC2016
printf 'cit_scan() { CIT_TIMEOUTS=$(printf "11\\tCI\\t.github/workflows/ci.yml\\t10\\t2026-10-01T00:00:00Z"); }\n' > "$T/k2c/bin/lib/mc-ci-timeout-scan.sh"
K2C=$(clean MC_STATE_DIR="$T/k2" bash -c '. "$1/bin/lib/mc-ci-timeout.sh"; cit_assess o/r o/r#1 h b 1 "$2"
  printf "%s|%s|%s|%s" "$CIT_RUNS_LEFT" "$CIT_FIRING" "$CIT_REKICK" "$CIT_SKIP_RUNG"' _ "$T/k2c" "$FL")
[ "$K2C" = "$FL|0|0|0" ] && ok || bad "K2c: the rekick and budget stubs must leave the flake list whole, got '$K2C'"

# ---- K3 part files replace the stubs ----------------------------------------
mk3() { rm -rf "$T/k3"; mkdir -p "$T/k3/bin/lib"; cp "$LIB" "$T/k3/bin/lib/"; }
run3() { clean MC_STATE_DIR="$T/k3/state" S="$T/k3" bash -c '. "$1/bin/lib/mc-ci-timeout.sh"
  cit_assess o/r o/r#1 h b 1 "$2"
  printf "%s|%s|%s" "$CIT_RUNS_LEFT" "$CIT_FIRING" "$CIT_SKIP_RUNG"' _ "$T/k3" "$FL"; }
mk3
# shellcheck disable=SC2016
printf 'cit_scan() { CIT_TIMEOUTS=$(printf "11\\tCI\\t.github/workflows/ci.yml\\t10\\t2026-10-01T00:00:00Z"); }\n' > "$T/k3/bin/lib/mc-ci-timeout-scan.sh"
printf 'cit_rekick_step() { CIT_SKIP_RUNG=0; }\n' > "$T/k3/bin/lib/mc-ci-timeout-rekick.sh"
# shellcheck disable=SC2016
printf 'cit_budget_step() { CIT_RUNS_LEFT=""; CIT_FIRING=1; touch "$S/budget-ran"; }\n' > "$T/k3/bin/lib/mc-ci-timeout-budget.sh"
K3A=$(run3)
[ "$K3A" = "|1|0" ] && ok || bad "K3: the budget part file must replace the stub and withhold the list, got '$K3A'"
# shellcheck disable=SC2016
printf 'cit_budget_step() { CIT_FIRING=1; CIT_RUNS_LEFT=""; CIT_SKIP_RUNG=1; return 1; }\n' > "$T/k3/bin/lib/mc-ci-timeout-budget.sh"
K3B=$(run3)
[ "$K3B" = "$FL|0|0" ] && ok || bad "K3: a step that returns 1 must leave the reset values (fail open), got '$K3B'"
# shellcheck disable=SC2016
printf 'cit_rekick_step() { CIT_SKIP_RUNG=1; return 3; }\n' > "$T/k3/bin/lib/mc-ci-timeout-rekick.sh"
K3C=$(run3)
[ "$K3C" = "$FL|0|0" ] && ok || bad "K3: a failed rekick step must reset CIT_SKIP_RUNG too, got '$K3C'"
mk3
printf 'cit_scan() { return 0; }\n' > "$T/k3/bin/lib/mc-ci-timeout-scan.sh"
# shellcheck disable=SC2016
printf 'cit_budget_step() { touch "$S/budget-ran"; CIT_RUNS_LEFT=""; }\n' > "$T/k3/bin/lib/mc-ci-timeout-budget.sh"
K3D=$(run3)
{ [ "$K3D" = "$FL|0|0" ] && [ ! -e "$T/k3/budget-ran" ]; } \
  && ok || bad "K3: a scan that finds no timeout never reaches the budget step, got '$K3D' (sentinel: $([ -e "$T/k3/budget-ran" ] && echo present || echo absent))"
mk3
# shellcheck disable=SC2016
printf 'cit_scan() { return 1; }\ncit_budget_step() { touch "$S/budget-ran"; }\n' > "$T/k3/bin/lib/mc-ci-timeout-scan.sh"
K3E=$(run3)
{ [ "$K3E" = "$FL|0|0" ] && [ ! -e "$T/k3/budget-ran" ]; } && ok || bad "K3: a failed scan stops there and fails open, got '$K3E'"

# ---- K4 the ledger ----------------------------------------------------------
K4D="$T/k4/state"
clean MC_STATE_DIR="$K4D" bash -c '. "$1/bin/lib/mc-ci-timeout.sh"
  cit_ledger_put "$2" o/r "$(printf "Unit\ttests")" o/r#7 h 7 600 10 TIMEOUT .github/workflows/ci.yml 2026-10-01T00:00:00Z' _ "$T/k1" "$NOW"
K4RC=$?
[ "$K4RC" = 0 ] && ok || bad "K4: cit_ledger_put must answer rc 0 on a written line, got $K4RC"
[ "$(wc -l < "$K4D/ci-timeout.tsv" 2>/dev/null)" = 1 ] && ok || bad "K4: exactly one ledger line, got: $(cat "$K4D/ci-timeout.tsv" 2>/dev/null)"
[ "$(awk -F'\t' '{print NF}' "$K4D/ci-timeout.tsv" 2>/dev/null)" = 11 ] && ok || bad "K4: the line must have 11 tab-separated fields"
[ "$(awk -F'\t' '{print $1 "|" $3 "|" $9}' "$K4D/ci-timeout.tsv" 2>/dev/null)" = "$NOW|Unit tests|TIMEOUT" ] \
  && ok || bad "K4: a tab in the check name becomes a space, got '$(awk -F'\t' '{print $1 "|" $3 "|" $9}' "$K4D/ci-timeout.tsv" 2>/dev/null)'"
clean bash -c '. "$1/bin/lib/mc-ci-timeout.sh"; [ -z "$CIT_LEDGER" ] || exit 9
  cit_ledger_put 1 o/r c k h 7 600 10 TIMEOUT w t' _ "$T/k1"
K4N=$?
{ [ "$K4N" != 0 ] && [ "$K4N" != 9 ]; } && ok || bad "K4: with no state root at all the ledger path is empty and the write refuses (rc=$K4N)"

# ---- K5 the real conductor, bh-636's B1 shape -------------------------------
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-budget.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$LIB" "$T/h/bin/lib/"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
: > "$T/h/env/global.env"
printf 'demo-os example-org/demo-os - - 2 box-demo\n' > "$T/h/fleet.conf"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/codegraph-ensure.sh"
chmod +x "$T/h/bin/agent-call.sh" "$T/h/bin/beat.sh" "$T/h/bin/codegraph-ensure.sh"
HF=ffffffff1111; TA=2026-09-17T10:00:00Z
jq -nc --arg t "$TA" '{workflow_runs:[
  {id:901,name:"compile",status:"completed",conclusion:"cancelled",run_started_at:$t,created_at:$t,run_attempt:1,html_url:"https://github.com/example-org/demo-os/actions/runs/901"},
  {id:902,name:"lint",status:"completed",conclusion:"skipped",run_started_at:$t,created_at:$t,run_attempt:1,html_url:"https://github.com/example-org/demo-os/actions/runs/902"}]}' > "$T/runs-$HF.json"
echo '{"workflow_runs":[]}' > "$T/runs-empty.json"
{ printf '#!/bin/bash\nT=%s\n' "$T"; cat <<'SHIM'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
case "$1 $2 $3 $4 $5" in
  "api -i -X GET repos/"*"/actions/runs?head_sha="*)
    SHA=${5##*head_sha=}; SHA=${SHA%%&*}
    F="$T/runs-$SHA.json"; [ -f "$F" ] || F="$T/runs-empty.json"
    printf 'HTTP/1.1 200 OK\r\n\r\n'; cat "$F"; exit 0 ;;
esac
case "$*" in
  "run rerun "*) printf '%s\n' "$*" >> "$T/reruns.txt"; exit 0 ;;
  *"pr merge"*|*"push"*|*"pr comment"*|*"issue close"*|*"issue comment"*|*"pr review"*|*"pr edit"*)
    printf '%s\n' "$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"api -X PATCH"*) exit 0 ;;
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
d="$T/h/builds/pool-demo-os-TK-21-202609170021"; mkdir -p "$d"
echo "PR_CREATED https://github.com/example-org/demo-os/pull/21" > "$d/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
echo "$HF" > "$d/reviewed-sha"
printf '[{"number":21,"url":"https://github.com/example-org/demo-os/pull/21","headRefOid":"%s","headRefName":"ticket/TK-21","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"main"}]' "$HF" > "$T/list.json"
touch "$T/h/flags/merge-conductor-actions" "$T/h/logs/ALERTS.log"
: > "$T/gh-calls.txt"; : > "$T/reruns.txt"; : > "$T/gh-writes.txt"
# K5b's probe: a scan part file that records the call it got and finds nothing.
# shellcheck disable=SC2016
printf 'cit_scan() { printf "%%s|" "$@" > "%s/scan-called"; return 0; }\n' "$T" > "$T/h/bin/lib/mc-ci-timeout-scan.sh"
( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
  MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }
K21='example-org/demo-os#21'
[ "$(grep -c 'run rerun 901 -R example-org/demo-os' "$T/reruns.txt")" = 1 ] && [ "$(wc -l < "$T/reruns.txt")" = 1 ] \
  && ok || bad "K5: exactly one rerun of the cancelled run, as BH-636 (got: $(cat "$T/reruns.txt"))"
case "$(awk -F'\t' -v k="$K21" '$1==k {print $7}' "$T/h/state/merge-conductor/pr-state.tsv" 2>/dev/null)" in
  *"checks flake"*) ok ;;
  *) bad "K5: the reason must still say 'checks flake' (got '$(awk -F'\t' -v k="$K21" '$1==k {print $7}' "$T/h/state/merge-conductor/pr-state.tsv" 2>/dev/null)')" ;;
esac
CITX=$(grep -rl 'CI_TIMEOUT_' "$T/h/logs" "$T/h/state" 2>/dev/null)
[ -z "$CITX" ] && ok || bad "K5: no CI_TIMEOUT_ text may appear with the stubs in place (found in: $CITX)"
[ ! -e "$T/h/state/merge-conductor/ci-timeout-firing.tsv" ] && [ ! -e "$T/h/state/merge-conductor/ci-timeout.tsv" ] \
  && ok || bad "K5: the tick writes neither the ledger nor the firing file"
[ "$(cat "$T/scan-called" 2>/dev/null)" = "example-org/demo-os|$K21|$HF|main|21|901|compile|" ] \
  && ok || bad "K5b: the conductor must call cit_assess with slug, key, head, base, PR number and the flake list (scan saw: '$(cat "$T/scan-called" 2>/dev/null)')"

echo "ci-timeout-contract.bh-3784: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
