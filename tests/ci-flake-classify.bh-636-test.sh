#!/bin/bash
# tests/ci-flake-classify.bh-636-test.sh — BH-636 W1: a KILLED RUNNER IS NOT A
# CODE FAILURE.
#
# THE BUG THIS PINS. `cancelled` stopped being a verdict in project-5 #586;
# `timed_out` did not, and it is the same fact — a runner that ran out of time
# or memory says nothing about the diff. A PR whose compile job timed out
# answered `red`, took a strike, and after its one rerun reached RED_TWICE,
# which buys a fresh rebuild of a ticket that was never broken.
#
# So: `timed_out` joins `cancelled`/`skipped`/`neutral` as not-evidence, and a
# head whose latest run of any workflow ended that way gets ONE FULL rerun of
# those runs (no strike), a `checks flake` reason, and — on a second flake on
# the same head — ONE actionable ALERTS line, because at that point the runner
# is the problem and nobody is coming for it.
#
# Driven, never grepped: section A runs the real lib functions against a fake
# gh that jq's a real actions/runs payload, and section B runs the real
# bin/merge-conductor.sh and asserts on state/, logs/ and the recorded gh writes.
# Every timestamp is derived from ONE clock read (NOW).
# Run from anywhere: tests/ci-flake-classify.bh-636-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date -u +%s)

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-budget.sh" "$T/h/bin/lib/"
# BH-1586: the CI reads go through gh_rest, so the fixture carries the library.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
: > "$T/h/env/global.env"
printf 'demo-os example-org/demo-os - - 2 box-demo\n' > "$T/h/fleet.conf"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/codegraph-ensure.sh"; chmod +x "$T/h/bin/codegraph-ensure.sh"

# ---- the actions/runs payload, and the fake gh that serves it --------------
# run <sha> <spec>... — spec: id|name|status|conclusion|created_at|attempt
runs_for() {
  local sha="$1"; shift
  local out='{"workflow_runs":[' first=1 spec id n s c t a
  for spec in "$@"; do
    IFS='|' read -r id n s c t a <<<"$spec"
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --arg id "$id" --arg n "$n" --arg s "$s" --arg t "$t" \
      --argjson a "${a:-1}" --arg c "$c" \
      '{id:($id|tonumber), name:$n, status:$s,
        conclusion:(if $c=="" then null else $c end),
        run_started_at:$t, created_at:$t, run_attempt:$a,
        html_url:("https://github.com/example-org/demo-os/actions/runs/"+$id)}')
  done
  printf '%s]}' "$out" > "$T/runs-$sha.json"
}
echo '{"workflow_runs":[]}' > "$T/runs-empty.json"

{ printf '#!/bin/bash\nT=%s\n' "$T"; cat <<'SHIM'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
# BH-1586: the run list is read through gh_rest (`api -i -X GET <path>`), which
# judges the HTTP status line and applies the jq itself — so this arm answers
# a whole HTTP response carrying the raw payload.
case "$1 $2 $3 $4 $5" in
  "api -i -X GET repos/"*"/actions/runs?head_sha="*)
    [ -f "$T/gh-runs-fail" ] && { printf 'HTTP/1.1 500 Server Error\r\n\r\n{"message":"boom"}'; exit 0; }
    SHA=${5##*head_sha=}; SHA=${SHA%%&*}
    F="$T/runs-$SHA.json"; [ -f "$F" ] || F="$T/runs-empty.json"
    printf 'HTTP/1.1 200 OK\r\n\r\n'; cat "$F"; exit 0 ;;
esac
case "$1 $2" in
  "api repos/"*"/actions/runs?head_sha="*)
    [ -f "$T/gh-runs-fail" ] && { echo "gh: HTTP 500" >&2; exit 1; }
    SHA=${2##*head_sha=}; SHA=${SHA%%&*}
    F="$T/runs-$SHA.json"; [ -f "$F" ] || F="$T/runs-empty.json"
    EXPR=""; shift 2
    while [ $# -gt 0 ]; do [ "$1" = "-q" ] && { EXPR="$2"; break; }; shift; done
    [ -n "$EXPR" ] || { cat "$F"; exit 0; }
    jq -r "$EXPR" "$F"; exit 0 ;;
esac
case "$*" in
  "run rerun "*) printf '%s\n' "$*" >> "$T/reruns.txt"
                 [ -f "$T/rerun-fail" ] && exit 1; exit 0 ;;
  *"pr merge"*|*"push"*|*"pr comment"*|*"issue close"*|*"issue comment"*|*"pr review"*|*"pr edit"*)
    printf '%s\n' "$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"api -X PATCH"*) printf '%s\n' "$*" >> "$T/patches.txt"; exit 0 ;;
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
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"
case "$URL" in
  */api/ledger) printf '{"ok":true}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"
: > "$T/gh-calls.txt"; : > "$T/reruns.txt"; : > "$T/gh-writes.txt"; : > "$T/patches.txt"

# ============================================================================
# A. The classifier, against a real actions/runs payload
# ============================================================================
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
S=example-org/demo-os
TA=2026-09-17T10:00:00Z; TB=2026-09-17T11:00:00Z

# A1 — timed_out is NOT a verdict. A killed runner and a cancelled one are the
#      same fact, and neither is `red`.
runs_for a1 "11|CI|completed|timed_out|$TA|1"
[ "$(mc_ci_state "$S" a1)" = none ] && ok || bad "A1: a head whose only run TIMED OUT must be 'none' (no verdict), got '$(mc_ci_state "$S" a1)'"
runs_for a1b "11|CI|completed|success|$TA|1" "12|E2E|completed|timed_out|$TA|1"
[ "$(mc_ci_state "$S" a1b)" = green ] && ok || bad "A1: success + a timed_out sibling must be green, got '$(mc_ci_state "$S" a1b)'"
runs_for a1c "11|CI|completed|failure|$TA|1"
[ "$(mc_ci_state "$S" a1c)" = red ] && ok || bad "A1: a real failure must still be red, got '$(mc_ci_state "$S" a1c)'"
runs_for a1d "11|CI|completed|cancelled|$TA|1" "11|CI|completed|success|$TB|2"
[ "$(mc_ci_state "$S" a1d)" = green ] && ok || bad "A1: a cancelled run superseded by a later success must be green, got '$(mc_ci_state "$S" a1d)'"
runs_for a1e "11|CI|in_progress||$TA|1"
[ "$(mc_ci_state "$S" a1e)" = pending ] && ok || bad "A1: an in-flight run must still be pending, got '$(mc_ci_state "$S" a1e)'"

# A2 — mc_ci_flake_runs names the runs to re-run, latest-per-workflow only.
[ "$(mc_ci_flake_runs "$S" a1)" = "11|CI" ] && ok || bad "A2: the cancelled/timed_out latest run must be named as '<id>|<name>', got '$(mc_ci_flake_runs "$S" a1)'"
[ "$(mc_ci_flake_runs "$S" a1b)" = "12|E2E" ] && ok || bad "A2: only the flaked workflow is named, got '$(mc_ci_flake_runs "$S" a1b)'"
[ -z "$(mc_ci_flake_runs "$S" a1d)" ] && ok || bad "A2: a cancelled run SUPERSEDED by a success on the same sha is not a flake, got '$(mc_ci_flake_runs "$S" a1d)'"
[ -z "$(mc_ci_flake_runs "$S" a1c)" ] && ok || bad "A2: a real failure is the red ladder's, never a flake, got '$(mc_ci_flake_runs "$S" a1c)'"
runs_for a2e "11|CI|completed|skipped|$TA|1" "12|E2E|completed|neutral|$TA|1"
[ -z "$(mc_ci_flake_runs "$S" a2e)" ] && ok || bad "A2: skipped/neutral are path filters and abstentions, not killed runners, got '$(mc_ci_flake_runs "$S" a2e)'"

# A3 — A FAILED READ IS NOT FLAKE EVIDENCE. It prints nothing and succeeds, so
#      no rerun is ever bought off a 500.
touch "$T/gh-runs-fail"
FOUT=$(mc_ci_flake_runs "$S" a1); FRC=$?
{ [ -z "$FOUT" ] && [ "$FRC" = 0 ]; } && ok || bad "A3: an API failure must print nothing and rc 0 (got rc=$FRC out='$FOUT')"
rm -f "$T/gh-runs-fail"

# A3b — the log word for each state.
[ "$(mc_ci_word none)"    = absent  ] && ok || bad "A3b: 'none' reads as ci=absent in the log, got '$(mc_ci_word none)'"
[ "$(mc_ci_word pending)" = pending ] && ok || bad "A3b: pending is itself, got '$(mc_ci_word pending)'"
[ "$(mc_ci_word red)"     = red     ] && ok || bad "A3b: red is itself, got '$(mc_ci_word red)'"
[ "$(mc_ci_word none "11|CI")" = flake ] && ok || bad "A3b: a non-empty flake list makes the word 'flake', got '$(mc_ci_word none "11|CI")'"

# ============================================================================
# B. The ladder, through the real bin/merge-conductor.sh
# ============================================================================
HF=ffffffff1111   # every run on it died: one cancelled, one skipped by a filter
HG=aaaaaaaa2222   # a head whose cancelled run was superseded by a success
HB=bbbbbbbb3333   # every run we can SEE passed, but the required one was killed
mkrec() { # mkrec <num> <head>
  local d="$T/h/builds/pool-demo-os-TK-$1-2026091700$1"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/example-org/demo-os/pull/$1" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  echo "$2" > "$d/reviewed-sha"
}
list_row() { # list_row <num> <head> <mergeState> <mergeable>
  printf '{"number":%s,"url":"https://github.com/example-org/demo-os/pull/%s","headRefOid":"%s","headRefName":"ticket/pb-%s","isDraft":false,"mergeStateStatus":"%s","mergeable":"%s","state":"OPEN","labels":[],"baseRefName":"main"}' \
    "$1" "$1" "$2" "$1" "$3" "$4"
}
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
  MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 env "$@" \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
state_of()  { awk -F'\t' -v k="$1" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv"; }
reason_of() { awk -F'\t' -v k="$1" '$1==k {print $7}' "$T/h/state/merge-conductor/pr-state.tsv"; }
A="$T/h/state/merge-conductor/attempts.txt"
ALOG="$T/h/logs/ALERTS.log"
CLOG="$T/h/logs/merge-conductor.log"
K21='example-org/demo-os#21'

mkrec 21 "$HF"; mkrec 22 "$HF"; mkrec 23 "$HG"; mkrec 25 "$HB"
runs_for "$HF" "901|compile|completed|cancelled|$TA|1" "902|lint|completed|skipped|$TA|1"
runs_for "$HG" "903|compile|completed|cancelled|$TA|1" "903|compile|completed|success|$TB|2"
runs_for "$HB" "904|lint|completed|success|$TA|1" "905|e2e|completed|timed_out|$TA|1"
touch "$T/h/flags/merge-conductor-actions" "$T/h/logs/ALERTS.log"

# B1 — an all-flake head: ONE full rerun, a `checks flake` reason, no red strike.
printf '[%s]' "$(list_row 21 "$HF" CLEAN MERGEABLE)" > "$T/list.json"
: > "$T/reruns.txt"
run_tick
[ "$(grep -c 'run rerun 901 -R example-org/demo-os' "$T/reruns.txt")" = 1 ] \
  && ok || bad "B1: the cancelled run must be re-run in FULL exactly once (got: $(cat "$T/reruns.txt"))"
grep -q 'run rerun 902' "$T/reruns.txt" \
  && bad "B1: a SKIPPED run is a path filter doing its job, not a killed runner — never re-run it (got: $(cat "$T/reruns.txt"))" || ok
grep -qE "^cirerun $K21 $HF [0-9]+$" "$A" \
  && ok || bad "B1: the rerun must be recorded once per (PR, head) BEFORE the dispatch (attempts: $(cat "$A"))"
grep -qxF "red $K21 $HF" "$A" \
  && bad "B1: a killed runner must NEVER take a red strike (attempts: $(cat "$A"))" || ok
[ "$(state_of "$K21")" = WAIT_CI ] && ok || bad "B1: a flaky head stays WAIT_CI (got $(state_of "$K21"))"
case "$(reason_of "$K21")" in *"checks flake"*) ok ;; *) bad "B1: the reason must say 'checks flake' (got '$(reason_of "$K21")')" ;; esac
grep -q "CI_FLAKE_RERUN $K21 $HF" "$CLOG" \
  && ok || bad "B1: the rerun must be logged as CI_FLAKE_RERUN (got: $(grep -o 'demo-os#21 .*' "$CLOG" | tail -2))"
grep -q 'CI_FLAKE_TWICE' "$ALOG" 2>/dev/null \
  && bad "B1: the FIRST flake never alerts — it buys a rerun" || ok

# B2 — the next tick, inside the settle window: no second rerun, no alert.
: > "$T/reruns.txt"
run_tick
[ ! -s "$T/reruns.txt" ] && ok || bad "B2: a rerun already in flight must not be dispatched again (got: $(cat "$T/reruns.txt"))"
grep -q 'flake rerun in flight' "$CLOG" && ok || bad "B2: the tick must say the rerun is in flight"
grep -q 'CI_FLAKE_TWICE' "$ALOG" 2>/dev/null && bad "B2: still inside the settle window is not 'twice'" || ok

# B3 — flaked AGAIN on the same head after its one rerun: ONE ALERTS line, ever.
#      The mark is aged past MC_RED_RERUN_SETTLE_SECS from the single clock read.
grep -v "^cirerun $K21 $HF " "$A" > "$T/a.tmp"; mv "$T/a.tmp" "$A"
echo "cirerun $K21 $HF $((NOW-400))" >> "$A"
: > "$T/reruns.txt"
run_tick
[ "$(grep -c 'CI_FLAKE_TWICE' "$ALOG")" = 1 ] \
  && ok || bad "B3: a second flake on the same head must raise exactly ONE actionable ALERTS line (got: $(grep -c 'CI_FLAKE_TWICE' "$ALOG"))"
grep -q 'compile' "$ALOG" && ok || bad "B3: the alert must name the workflow that keeps dying (got: $(grep CI_FLAKE_TWICE "$ALOG"))"
[ ! -s "$T/reruns.txt" ] && ok || bad "B3: the second flake buys no second rerun (got: $(cat "$T/reruns.txt"))"
[ "$(state_of "$K21")" = WAIT_CI ] && ok || bad "B3: the row stays WAIT_CI — a killed runner is not RED_TWICE (got $(state_of "$K21"))"
run_tick
[ "$(grep -c 'CI_FLAKE_TWICE' "$ALOG")" = 1 ] \
  && ok || bad "B3: a third tick must not page again (got: $(grep -c 'CI_FLAKE_TWICE' "$ALOG"))"

# B4 — observe mode writes nothing and says what it would have done.
rm -f "$T/h/flags/merge-conductor-actions"
printf '[%s]' "$(list_row 22 "$HF" CLEAN MERGEABLE)" > "$T/list.json"
: > "$T/reruns.txt"
run_tick
[ ! -s "$T/reruns.txt" ] && ok || bad "B4: observe mode must dispatch no rerun (got: $(cat "$T/reruns.txt"))"
grep -q 'demo-os#22 would re-run' "$CLOG" && ok || bad "B4: observe mode must log what it would have done"
grep -qE "^cirerun example-org/demo-os#22 " "$A" \
  && bad "B4: observe mode must write no attempt mark (attempts: $(grep 22 "$A"))" || ok
touch "$T/h/flags/merge-conductor-actions"

# B5 — a DIRTY head with a cancelled run belongs to the rebase, not the ladder.
printf '[%s]' "$(list_row 24 "$HF" DIRTY CONFLICTING)" > "$T/list.json"
mkrec 24 "$HF"
: > "$T/reruns.txt"
run_tick MC_DETACHED_REBASE=0 MC_MERGE_TREE=1
[ ! -s "$T/reruns.txt" ] && ok || bad "B5: a conflicted head runs no workflow at all — the rebase owns it, not the flake ladder (got: $(cat "$T/reruns.txt"))"

# B6 — the adversarial negative: a cancelled run SUPERSEDED by a success is
#      green, and green buys nothing.
printf '[%s]' "$(list_row 23 "$HG" CLEAN MERGEABLE)" > "$T/list.json"
: > "$T/reruns.txt"
run_tick
[ ! -s "$T/reruns.txt" ] && ok || bad "B6: latest-per-workflow wins — a superseded cancellation is not a flake (got: $(cat "$T/reruns.txt"))"
[ "$(state_of 'example-org/demo-os#23')" = READY ] \
  && ok || bad "B6: that head is green, approved and clean — it must be READY (got $(state_of 'example-org/demo-os#23'))"

# B7 — the OTHER shape of the same fact: every run we can see passed, but a
#      REQUIRED context is not green, because the run that reports it was killed.
#      mc_ci_state says `green` here; only mergeStateStatus knows better.
printf '[%s]' "$(list_row 25 "$HB" BLOCKED MERGEABLE)" > "$T/list.json"
: > "$T/reruns.txt"
run_tick
grep -q 'run rerun 905' "$T/reruns.txt" \
  && ok || bad "B7: a green-looking head whose required context was timed_out must still be re-run (got: $(cat "$T/reruns.txt"))"
case "$(reason_of 'example-org/demo-os#25')" in
  *"checks flake"*) ok ;;
  *) bad "B7: and the reason must name it, not 'required context not green' (got '$(reason_of 'example-org/demo-os#25')')" ;;
esac

echo "ci-flake-classify.bh-636: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
