#!/bin/bash
# tests/wake-pr-closed-retracts.bh-4055-test.sh — a PR close / merge / enqueue /
# label wake launches `pipeline-health.sh --sections stalepr,leadunqueued`, and
# that run retracts the ph-* rows through BH-4054's epilogue (BH-4055).
#
# Sources the REAL bin/lib/wake-class-pr-closed.sh. cooled() answers 0 (or a
# refusal for P6), and launch() records every launch and RUNS a pipeline-health
# launch synchronously: the REAL bin/pipeline-health.sh against a scratch tree
# (tests/lib/ph-sections-fixture.sh), with the real alert-line.sh / beat.sh.
#   P1  a pull_request.closed row -> the last launch is
#       pipeline-health.sh --sections stalepr,leadunqueued
#   P2  with stalepr:ts open and no stale PR left, that run resolves alert:ph-stalepr_ts
#   P3  a pull_request.enqueued row for o/r#5, #5 now labelled queued ->
#       alert:ph-leadunqueued_o_r_5_abcdef123456 resolves, and
#       alerts-merge-resolve.sh got --queued o/r#5
#   P4  labeled and dequeued rows launch the run; synchronize and a bare
#       pull_request do not
#   P5  a second drain in the same loop invocation launches no second run and
#       says it is held
#   P6  a cooldown that refuses -> no run, the other launches still happen
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/wake-pr-closed-retracts.bh-4055-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/ph-sections-fixture.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v python3 >/dev/null && command -v flock >/dev/null \
  || { echo "jq/python3/flock missing — skipping"; exit 0; }
CLASS="$DIR/bin/lib/wake-class-pr-closed.sh"

# drain <dir> <refuse-kind|-> <row>... — one class drain in a fresh shell
# (fresh = a new wake-loop invocation). A row is "<event> <repo> <key>".
# Writes <dir>/launches and <dir>/say.log.
drain() {
  local d="$1" refuse="$2"; shift 2
  ( SELF="$d/bin"; COOLDOWN=120; REFUSE="$refuse"; D="$d"
    cooled() { [ "$1" != "$REFUSE" ]; }
    say()    { echo "$*" >> "$D/say.log"; }
    launch() {
      shift; echo "$*" >> "$D/launches"
      case "$1" in */pipeline-health.sh)
        ( export HARNESS="$D"; phs_env; export LEAD_REVIEW_AUTO_REPOS=o/r; "$@" ) >/dev/null 2>>"$D/err.txt" ;;
      esac
    }
    # shellcheck source=bin/lib/wake-class-pr-closed.sh
    . "$CLASS" || exit 1
    for R in "$@"; do
      set -- $R
      wc_pr_closed_row ts pr "$3" "$1" "$2" 1
    done
    wc_pr_closed_dispatch
    [ -n "${SECOND:-}" ] && { wc_pr_closed_row ts pr 8 pull_request.closed o/r 2; wc_pr_closed_dispatch; }
    true )
}
ph_launches() { grep -c 'pipeline-health.sh' "$1/launches" 2>/dev/null || true; }
tree() { phs_mktree "$1"; : > "$1/launches"; }
WANT_ARGS="--sections stalepr,leadunqueued"

echo "--- P1/P2: a closed row launches the sections run, and it retracts stalepr"
D="$T/p1"; tree "$D"
printf '[%s]\n' "$(phs_pr 7)" > "$D/prs-r.json"
( export HARNESS="$D"; phs_env; "$D/bin/pipeline-health.sh" --sections stalepr ) >/dev/null 2>&1
grep -qxF ph-stalepr_ts "$D/open.ids" 2>/dev/null && ok || bad "P2 setup: ph-stalepr_ts never opened"
echo '[]' > "$D/prs-r.json"
drain "$D" - "pull_request.closed o/r 7"
[ "$(tail -1 "$D/launches")" = "$D/bin/pipeline-health.sh $WANT_ARGS" ] \
  && ok || bad "P1: last launch is '$(tail -1 "$D/launches")', want the sections run: $(cat "$D/launches")"
[ "$(ph_launches "$D")" = 1 ] && ok || bad "P1: $(ph_launches "$D") pipeline-health launches"
[ "$(phs_resolved "$D")" = alert:ph-stalepr_ts ] && ok || bad "P2: resolves '$(phs_resolved "$D" | tr '\n' ' ')', want alert:ph-stalepr_ts; err=$(cat "$D/err.txt" 2>/dev/null)"
grep -qxF stalepr:ts "$D/state/health-active.txt" && bad "P2: stalepr:ts still active" || ok
[ ! -s "$D/err.txt" ] && ok || bad "P2: stderr: $(cat "$D/err.txt")"

echo "--- P3: an enqueued row retracts leadunqueued"
D="$T/p3"; tree "$D"
echo '{"statuses":[{"context":"lead-verdict","state":"success","updated_at":"2026-09-01T00:00:00Z"}]}' > "$D/status.json"
lu() { printf '[{"number":5,"draft":false,"base":{"ref":"main","repo":{"default_branch":"main"}},"head":{"sha":"abcdef1234567890"},"labels":[%s]}]\n' "$1" > "$D/lu.json"; }
lu ''
( export HARNESS="$D"; phs_env; export LEAD_REVIEW_AUTO_REPOS=o/r; "$D/bin/pipeline-health.sh" --sections leadunqueued ) >/dev/null 2>&1
grep -qxF 'leadunqueued:o/r#5:abcdef123456' "$D/state/health-active.txt" && ok || bad "P3 setup: leadunqueued never fired: $(cat "$D/state/health-active.txt")"
grep -qxF ph-leadunqueued_o_r_5_abcdef123456 "$D/open.ids" 2>/dev/null && ok || bad "P3 setup: the row never opened: $(cat "$D/open.ids" 2>/dev/null)"
lu '{"name":"queued"}'
drain "$D" - "pull_request.enqueued o/r 5"
[ "$(phs_resolved "$D")" = alert:ph-leadunqueued_o_r_5_abcdef123456 ] \
  && ok || bad "P3: resolves '$(phs_resolved "$D" | tr '\n' ' ')'; err=$(cat "$D/err.txt" 2>/dev/null)"
grep -qx "$D/bin/alerts-merge-resolve.sh --queued o/r#5" "$D/launches" \
  && ok || bad "P3: alerts-merge-resolve did not get --queued o/r#5: $(cat "$D/launches")"
grep -q 'alerts-resolve-closed-prs' "$D/launches" && bad "P3: an enqueue is not a closure" || ok

echo "--- P4: which rows launch the run"
for EV in pull_request.labeled pull_request.dequeued pull_request.enqueued pull_request.closed; do
  D="$T/p4-$EV"; tree "$D"
  drain "$D" - "$EV o/r 9"
  [ "$(ph_launches "$D")" = 1 ] && ok || bad "P4: $EV launched $(ph_launches "$D") runs"
done
for EV in pull_request.synchronize pull_request pull_request.opened; do
  D="$T/p4-$EV"; tree "$D"
  drain "$D" - "$EV o/r 9"
  [ ! -s "$D/launches" ] && ok || bad "P4: $EV launched: $(cat "$D/launches")"
done
# dequeued is not a queued PR: it never reaches --queued.
grep -q -- '--queued' "$T/p4-pull_request.dequeued/launches" && bad "P4: dequeued was handed to --queued" || ok

echo "--- P5: one run per loop invocation"
D="$T/p5"; tree "$D"
SECOND=1 drain "$D" - "pull_request.closed o/r 7"
[ "$(ph_launches "$D")" = 1 ] && ok || bad "P5: $(ph_launches "$D") runs in one invocation"
grep -q 'held, per-tick cap' "$D/say.log" 2>/dev/null && ok || bad "P5: no held line: $(cat "$D/say.log" 2>/dev/null)"
[ "$(grep -c 'alerts-resolve-closed-prs.sh' "$D/launches")" = 2 ] && ok || bad "P5: the second drain's other launches must still happen"

echo "--- P6: a refused cooldown"
D="$T/p6"; tree "$D"
drain "$D" pipeline-health "pull_request.closed o/r 7"
[ "$(ph_launches "$D")" = 0 ] && ok || bad "P6: launched under a refused cooldown"
grep -q 'alerts-resolve-closed-prs.sh o/r#7' "$D/launches" && grep -q 'reconcile-prs.sh' "$D/launches" \
  && ok || bad "P6: the other launches must still happen: $(cat "$D/launches")"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
