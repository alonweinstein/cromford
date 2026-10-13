#!/bin/bash
# tests/mc/rerun-stale-head.bh-3804-test.sh — BH-3804: every CI write the merge
# conductor makes re-reads the PR's LIVE head first, and a write for a head the
# PR has already left dispatches nothing.
#
# 2026-10-01, project-4 #1815: the tick read head 3b0fd01b, a fix was pushed
# (94fafc78) while the tick ran, and mc_red_rerun re-ran the OLD head's failed
# run. The repo's per-PR `cancel-in-progress` concurrency group then cancelled
# every shard of the CURRENT head's run. So, before a rerun, a flake kick or a
# close/reopen kick:
#   * one `pulls/<n>` read through gh_rest; a moved head logs
#     `stale head: tick read <old>, PR is at <new>`, bumps
#     stale_head_rerun_skipped and writes NO rerun mark for either sha;
#   * an unreadable head dispatches nothing either (fail closed, no rung spent);
#   * a listed run whose head_sha is not the live head is never re-run.
#
# Driven, never grepped: every assertion is about the argv the stub `gh`
# RECORDED and the attempt store the real lib wrote.
# Run from anywhere: tests/mc/rerun-stale-head.bh-3804-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
export HARNESS="$T/h"; fx_mc_harness "$DIR" "$T" || exit 1
cp "$DIR/bin/lib/flaky.sh" "$T/h/bin/lib/" || exit 1
[ -f "$DIR/bin/lib/mc/classify.sh" ] && [ -f "$DIR/bin/lib/mc/rebase.sh" ] && [ -f "$DIR/bin/lib/mc/locks.sh" ] || exit 1
export PATH="$T/fakebin:$PATH" GH_ETAG=0
export MC_KICK_REOPEN_TRIES=1 MC_KICK_REOPEN_SLEEP=0

# The stub: every argv is recorded. The live PR read answers the sha in $T/live
# (absent = a 500, the read failed). Reruns and the close/reopen PATCHes are
# recorded in their own files so a case can count them.
cat > "$T/fakebin/gh" <<GH
#!/bin/bash
printf '%s\n' "\$*" >> "$T/argv.log"
case "\$*" in
  "api -i -X GET repos/o/r/pulls/7"*)
    if [ -s "$T/live" ]; then restpr OPEN "\$(cat "$T/live")"; else restpr --raw 500; fi; exit 0 ;;
  "api -i -X GET repos/o/r/actions/runs"*) restpr --raw 200 "\$(cat "$T/runs.json")"; exit 0 ;;
  "run rerun "*) printf '%s\n' "\$*" >> "$T/reruns.log"; exit 0 ;;
  *"-X PATCH"*"state=closed"*) printf '%s\n' "\$*" >> "$T/closed.log"; echo '{}'; exit 0 ;;
  *"-X PATCH"*"state=open"*)   printf '%s\n' "\$*" >> "$T/reopened.log"; echo '{}'; exit 0 ;;
esac
echo '{}'
exit 0
GH
chmod +x "$T/fakebin/gh"

# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
export ACTIONS=1 P=demo MC_TICK_ID=t1
# Transports only: the run list, the test names, the flake ledger and the hold
# read. Everything this ticket changed — the live read, the guard, the marks,
# the dispatch loops, the counter — is the real lib.
flaky_failed_runs() { cat "$T/runs" 2>/dev/null; }
flaky_run_tests()   { echo t1; }
flaky_all_known()   { cat >/dev/null; return 0; }
mc_hold_keeps_pr()  { return 1; }
mc_alert()          { printf '%s\n' "$*" >> "$T/alerts.log"; }

A=aaaaaaaa1111; B=bbbbbbbb2222; KEY='o/r#7'
reset() {
  : > "$MC_ATTEMPTS"; : > "$MC_LOG"
  rm -f "$T/argv.log" "$T/reruns.log" "$T/closed.log" "$T/reopened.log" "$T/live" "$T/runs"
  rm -f "$MC_TICK_DIR"/* 2>/dev/null
  unset MC_LIVE_HEAD
}
live() { printf '%s' "$1" > "$T/live"; }
runs() { printf '%s\n' "$@" > "$T/runs"; }
nlines() { [ -f "$1" ] && grep -c . "$1" || echo 0; }
marks() { grep -c "^$1 o/r#7 " "$MC_ATTEMPTS" || true; }
counter() { mc_count_get demo stale_head_rerun_skipped; }
logged() { grep -qF -- "$1" "$MC_LOG"; }

# ============================================================================
# H. the live read
# ============================================================================
reset; live "$B"
out=$(mc_pr_live_head o/r 7); rc=$?
check "H1 live head read prints the PR's head" "$out" "$B"
check "H1 rc 0" "$rc" 0
grep -qx "api -i -X GET repos/o/r/pulls/7" "$T/argv.log" 2>/dev/null && ok "H3 the read is REST through gh_rest (api -i -X GET repos/o/r/pulls/7)" || bad "H3 the live read must be gh_rest GET pulls/7 (argv: $(cat "$T/argv.log" 2>/dev/null))"
grep -q "pr view" "$T/argv.log" 2>/dev/null && bad "H3 the live read must never be gh pr view" || ok "H3 no gh pr view"
reset
out=$(mc_pr_live_head o/r 7); rc=$?
check "H2 unreadable head prints nothing" "$out" ""
check "H2 unreadable head rc 1" "$rc" 1

# ============================================================================
# R. mc_red_rerun
# ============================================================================
# R1 — the #1815 shape: the tick read A, the PR is at B.
reset; live "$B"; runs "900|.github/workflows/ci.yml|CI|$A"
mc_red_rerun o/r "$KEY" "$A"; rc=$?
[ "$rc" != 0 ] && ok "R1 stale head -> rc != 0" || bad "R1 stale head must not report a dispatched rerun"
check "R1 no gh run rerun" "$(nlines "$T/reruns.log")" 0
check "R1 no cirerun mark for A or B" "$(marks cirerun)" 0
logged "$KEY stale head: tick read aaaaaaaa, PR is at bbbbbbbb — no rerun" && ok "R1 stale line logged" || bad "R1 stale line missing (log: $(cat "$MC_LOG"))"
check "R1 stale_head_rerun_skipped = 1" "$(counter)" 1
check "R1 MC_LIVE_HEAD exported for the caller" "${MC_LIVE_HEAD:-}" "$B"

# M1 — the counter reaches the TICK line and the tick JSON.
mc_tick_metrics demo "$NOW" "$NOW"
tl=$(grep 'TICK demo ' "$MC_LOG" | tail -1)
case "$tl" in *" stale_head_rerun_skipped=1") ok "M1 TICK line ends stale_head_rerun_skipped=1" ;; *) bad "M1 TICK line: $tl" ;; esac
check "M1 tick JSON carries the counter" "$(jq -r '.stale_head_rerun_skipped' "$MC_STATE_DIR/tick-demo.json" 2>/dev/null)" 1

# R2 — tick head = live head: behaviour unchanged.
reset; live "$B"; runs "901|.github/workflows/ci.yml|CI|$B"
mc_red_rerun o/r "$KEY" "$B"; rc=$?
check "R2 same head -> rc 0" "$rc" 0
check "R2 exactly one rerun, --failed, of B's run" "$(cat "$T/reruns.log" 2>/dev/null)" "run rerun 901 --failed -R o/r"
check "R2 one cirerun mark, for B" "$(grep -c "^cirerun o/r#7 $B " "$MC_ATTEMPTS")" 1
check "R2 counter untouched" "$(counter)" 0

# R3 — live head = B, but the failed run listed belongs to A.
reset; live "$B"; runs "900|.github/workflows/ci.yml|CI|$A"
mc_red_rerun o/r "$KEY" "$B"; rc=$?
[ "$rc" != 0 ] && ok "R3 nothing dispatched -> rc != 0" || bad "R3 must not report a rerun"
check "R3 A's run is not re-run" "$(nlines "$T/reruns.log")" 0
logged "run 900 is on aaaaaaaa, not the PR head bbbbbbbb" && ok "R3 the skipped run is named" || bad "R3 skip line missing (log: $(cat "$MC_LOG"))"

# R4 — the live read fails: fail closed, no rung spent.
reset; runs "901|.github/workflows/ci.yml|CI|$B"
mc_red_rerun o/r "$KEY" "$B"; rc=$?
[ "$rc" != 0 ] && ok "R4 unreadable -> rc != 0" || bad "R4 must not report a rerun"
check "R4 no rerun" "$(nlines "$T/reruns.log")" 0
check "R4 no cirerun mark (the rung is not spent)" "$(marks cirerun)" 0
logged "live head unreadable" && ok "R4 unreadable line logged" || bad "R4 unreadable line missing"
check "R4 counter untouched" "$(counter)" 0

# R5 — a 3-field run line (an older lib) is dispatched as before.
reset; live "$B"; runs "902|.github/workflows/ci.yml|CI"
mc_red_rerun o/r "$KEY" "$B"
check "R5 run with no head_sha field falls back to the API's own head filter" "$(cat "$T/reruns.log" 2>/dev/null)" "run rerun 902 --failed -R o/r"

# ============================================================================
# K. mc_flake_kick (runs are "id|name|sha")
# ============================================================================
reset; live "$B"
mc_flake_kick o/r "$KEY" "$A" "910|unit|$A"; rc=$?
[ "$rc" != 0 ] && ok "K1 stale -> rc != 0" || bad "K1 must not report a kick"
check "K1 no rerun" "$(nlines "$T/reruns.log")" 0
check "K1 no cirerun mark" "$(marks cirerun)" 0
logged "stale head: tick read aaaaaaaa, PR is at bbbbbbbb — no rerun" && ok "K1 stale line logged" || bad "K1 stale line missing"
reset; live "$B"
mc_flake_kick o/r "$KEY" "$B" "911|unit|$B"; rc=$?
check "K2 same head -> rc 0" "$rc" 0
check "K2 one FULL rerun (no --failed)" "$(cat "$T/reruns.log" 2>/dev/null)" "run rerun 911 -R o/r"
check "K2 one mark" "$(marks cirerun)" 1
logged "(1 run(s): unit)" && ok "K2 the names list is the workflow name, not the sha" || bad "K2 names wrong (log: $(cat "$MC_LOG"))"
reset; live "$B"
mc_flake_kick o/r "$KEY" "$B" "910|unit|$A"
check "K3 A's run is not re-run" "$(nlines "$T/reruns.log")" 0

# K4 — the real list read carries the run's head_sha, and the kick refuses a
# cancelled run that GitHub filed under A while the PR is at B.
reset; live "$B"
printf '{"workflow_runs":[{"id":930,"name":"unit","head_sha":"%s","status":"completed","conclusion":"cancelled","run_started_at":"2026-10-01T00:00:00Z","run_attempt":1}]}' "$A" > "$T/runs.json"
fl=$(mc_ci_flake_runs o/r "$B")
check "K4 mc_ci_flake_runs prints id|name|head_sha" "$fl" "930|unit|$A"
mc_flake_kick o/r "$KEY" "$B" "$fl"
check "K4 the run on A is not re-run" "$(nlines "$T/reruns.log")" 0

# ============================================================================
# F. mc_flake_rerun (every failing test is a known flake)
# ============================================================================
reset; live "$B"; runs "920|.github/workflows/ci.yml|CI|$A"
mc_flake_rerun o/r "$KEY" "$A"; rc=$?
check "F1 stale -> rc 1 (count the strike)" "$rc" 1
check "F1 no rerun" "$(nlines "$T/reruns.log")" 0
check "F1 no flakererun mark" "$(marks flakererun)" 0
check "F1 no cirerun mark" "$(marks cirerun)" 0
reset; live "$B"; runs "921|.github/workflows/ci.yml|CI|$B"
mc_flake_rerun o/r "$KEY" "$B"; rc=$?
check "F2 same head -> rc 0" "$rc" 0
check "F2 exactly one --failed rerun" "$(cat "$T/reruns.log" 2>/dev/null)" "run rerun 921 --failed -R o/r"
reset; live "$B"; runs "920|.github/workflows/ci.yml|CI|$A"
mc_flake_rerun o/r "$KEY" "$B"
check "F3 A's run is not re-run" "$(nlines "$T/reruns.log")" 0

# ============================================================================
# C. mc_kick_ci (close/reopen)
# ============================================================================
reset; live "$B"
mc_kick_ci o/r 7 "$A"; rc=$?
check "C1 stale head -> rc 1" "$rc" 1
check "C1 nothing closed" "$(nlines "$T/closed.log")" 0
check "C1 MC_KICK_CLOSED = 0 (nothing changed)" "$MC_KICK_CLOSED" 0
logged "stale head: tick read aaaaaaaa, PR is at bbbbbbbb — no CI kick" && ok "C1 stale line names the CI kick" || bad "C1 stale line missing"
reset; live "$B"
mc_kick_ci o/r 7 "$B"; rc=$?
check "C2 same head -> rc 0" "$rc" 0
check "C2 one close" "$(nlines "$T/closed.log")" 1
check "C2 one reopen" "$(nlines "$T/reopened.log")" 1
reset; live "$B"
mc_kick_ci o/r 7; rc=$?
check "C3 legacy call (no head) -> rc 0" "$rc" 0
check "C3 legacy call closes" "$(nlines "$T/closed.log")" 1
grep -q 'repos/o/r/pulls/7' "$T/argv.log" && grep -q '^api -i -X GET' "$T/argv.log" && bad "C3 a legacy call must not pay the live read" || ok "C3 no live read without a head"

# C4 — through a production caller: ci_absent_kick hands its head to the kick.
reset; live "$B"
mc_row_field() { [ "$2" = 3 ] && echo $((NOW - 3600)); }
ci_absent_kick "$KEY" o/r 7 https://x/7 "$A" CLEAN
check "C4 ci_absent_kick on a stale head closes nothing" "$(nlines "$T/closed.log")" 0
check "C4 no cikick mark for the stale head" "$(marks cikick)" 0
reset; live "$B"
ci_absent_kick "$KEY" o/r 7 https://x/7 "$B" CLEAN
check "C4 ci_absent_kick on the live head kicks" "$(nlines "$T/closed.log")" 1
unset -f mc_row_field

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
