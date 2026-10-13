#!/bin/bash
# tests/triage-state-unreadable.bh-3925-test.sh — BH-3925 (BH-3921.2): under
# TRIAGE_STATE_MODE=enforce, a tick whose triage_state rows cannot be read no
# longer sends every open ticket to the model. ts_rows_unreadable_tick
# (bin/lib/triage-state-unreadable.sh), driven through the real ts_tick:
#
#   D1 no work in scope: the tick exits skipped, logged, no model call; the gate
#      is NOT consumed, LANE_TICK skip, the job row closed, waste `unreadable`
#   D2 ONE alert per streak at N (default 3); a readable tick clears the streak
#      and the next outage alerts afresh
#   D3 queue work in scope: the session runs restricted to it (directive,
#      TS_ENFORCING=1, TS_SKIPSET = every non-work key); the streak is untouched.
#      D3b remote-results-pending and a `board prs:` line run restricted too, and an
#      UNBLOCKED / STACKABLE line's key is dispatched and its launch allowed;
#      D3c a daily sweep with no work is skipped and never consumed
#   D4 a forced tick is never skipped; gate-error is never skipped (NEGATIVE)
#   D5 no-gate-state and gate-fetch-failed skip like D1
#   D6 no board fingerprint (no decisions.tsv): the tick runs as before
#   D7 shadow: unchanged, the shadow line still says every ticket goes to the model
#   D8 lane-alert.sh not executable / failing: one line through the real
#      bin/alert-line.sh; both failing leaves the streak unalerted, so it retries
#   K  the threshold is the settings row lib.triage-state.triage_state_unreadable_alert_after
#
# Everything real except the worker and the lane edges: bin/lib/triage-state.sh,
# its modules, bin/triage-state.py, bin/triage-signal.py, the shard key lib, the
# lane gate (settings rows) and bin/alert-line.sh, against an in-app board
# fingerprint. triage_state_list serves a rows file, or fails when WORKER_UP=0.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/triage-state-unreadable.bh-3925-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required"; exit 1; }
export PYTHONDONTWRITEBYTECODE=1
unset TRIAGE_STATE_UNREADABLE_ALERT_AFTER HARNESS_SECRET JOBS_URL LANE_GATE_DISABLE

# the lane registry the settings rows resolve through (K)
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >"$T/lb.out" 2>&1 \
  || bad "fixture: catalog/lanes.json could not be composed: $(cat "$T/lb.out")"
export LANE_REGISTRY="$T/lanes.json" LANE_GATE_NOW=1000

# ── a scratch harness: the production files, linked ─────────────────────────
H="$T/h"; P=project-4
mkdir -p "$H/bin/lib" "$H/state" "$H/logs" "$H/builds" "$H/flags" "$T/calls"
for s in triage-state.py triage-signal.py alert_family.py; do ln -s "$DIR/bin/$s" "$H/bin/$s"; done
for s in triage-state.sh triage-state-unreadable.sh triage-state-waste.sh triage-shards-lib.sh \
         lane-switch.sh lane-gate.sh alert-state.sh revdep-lib.sh; do
  ln -s "$DIR/bin/lib/$s" "$H/bin/lib/$s"
done
cp "$DIR/bin/alert-line.sh" "$H/bin/alert-line.sh"; chmod +x "$H/bin/alert-line.sh"
cat > "$H/bin/lane-alert.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls/alert"
[ -e "$T/alert-fail" ] && exit 1
exit 0
STUB
chmod +x "$H/bin/lane-alert.sh"
SD="$H/state/triage-state/$P"; SF="$SD/rows-unreadable.streak"
ROWS="$T/rows.json"; echo '[]' > "$ROWS"; WORKER_UP=1
triage_state_list() { [ "$WORKER_UP" = 1 ] || return 1; cat "$ROWS"; }
triage_state_put() { :; }
LANE_TICK() { echo "LANE_TICK $*" >> "$T/calls/lane-tick"; }
rt_gate_consume() { echo consumed >> "$T/calls/consume"; }
job_update() { echo "$*" >> "$T/calls/job"; }
job_beat_stop() { echo "$*" >> "$T/calls/beat"; }
# shellcheck source=/dev/null
. "$H/bin/lib/triage-state.sh"
ts_waste_account() { echo "$1" >> "$T/calls/waste"; }

tick_env() { # tick_env <mode> [gate-reason]
  export HARNESS="$H" TRIAGE_STATE_MODE="$1" TRIAGE_STATE_MAX_FETCH=0
  PROJECT=$P; STAMP="2026-10-01 10:00:00Z"; LOG="$H/logs/$P.log"
  GATE_REASON="${2:-board-changed}"; SCOPE_N=full
  TICK_SCOPE=""; BOARD_SEC=""; QLINES=""; QDIRS=""; RDIRS=""; JOB_ID=""; JOB_BEAT=""
  PROMPT_TEXT="SOP PROMPT"
}
calls_reset() { rm -f "$T/calls/"*; : > "$H/logs/$P.log"; }
# the in-app fingerprint (r1 r2 r3 -> TK-r1 ...), its keymap and the thread cache
board() {
  local i sep=""
  mkdir -p "$SD"
  { printf '{"b1":['
    for i in r1 r2 r3; do printf '%s{"id":"%s","key":"TK-%s","title":"t %s","status":"open","commentCount":1,"lastActivityAt":"2026-09-30T00:00:00Z"}' "$sep" "$i" "$i" "$i"; sep=,; done
    printf ']}\n'; } > "$H/state/$P.gate.pending"
  jq -S '[.b1[] | {(.id): .key, (.key): .id}] | add' "$H/state/$P.gate.pending" > "$H/state/$P.keymap.json"
  for i in r1 r2 r3; do
    jq -n --arg i "$i" '{kind:"inapp",doc:{id:$i,key:("TK-" + $i),title:("t " + $i),status:"open",description:"d",
      comments:[{id:("m-" + $i),authorName:"Client",body:"please",createdAt:"2026-09-30T00:00:00Z"}]}}' > "$SD/$i.raw"
  done
  python3 "$DIR/bin/triage-state.py" entries --world "$H/state/$P.gate.pending" > "$T/entries.tsv"
  while IFS=$'\t' read -r k _ esha _; do printf '%s' "$esha" > "$SD/$k.entry"; done < "$T/entries.tsv"
}
tick() { ts_tick >/dev/null 2>&1; echo "CONTINUED [$PROMPT_TEXT]"; }
alerts() { cat "$T/calls/alert" 2>/dev/null | grep -c -- '--id triage-rows-unreadable:project-4'; }
dead_tick() { WORKER_UP=0; tick_env enforce "${1:-board-changed}"; OUT=$(tick) 2>/dev/null; }
board

# ═══ D1 — no work in scope: skipped, logged, not consumed ════════════════════
calls_reset; rm -f "$SF"
WORKER_UP=0; tick_env enforce board-changed; JOB_ID=j1; JOB_BEAT=b1
OUT=$(tick) 2>/dev/null
case "$OUT" in *CONTINUED*) bad "(D1) an unreadable enforce tick with no work must not continue to the model: [$OUT]" ;; *) ok ;; esac
L1=$(grep 'rows unreadable' "$H/logs/$P.log")
case "$L1" in "2026-10-01 10:00:00Z [$P] rc=skip :: triage-state: rows unreadable — tick skipped, no model call (streak 1) [gate=board-changed]") ok ;;
  *) bad "(D1) the skip line: [$L1]" ;; esac
[ -s "$H/state/$P.gate.pending" ] && ok || bad "(D1) state/<p>.gate.pending survives the skip"
[ ! -e "$T/calls/consume" ] && ok || bad "(D1) rt_gate_consume is never called on a skip"
[ "$(cat "$T/calls/lane-tick" 2>/dev/null)" = "LANE_TICK skip" ] && ok || bad "(D1) LANE_TICK skip: [$(cat "$T/calls/lane-tick" 2>/dev/null)]"
[ "$(cat "$T/calls/waste" 2>/dev/null)" = unreadable ] && ok || bad "(D1) ts_waste_account unreadable: [$(cat "$T/calls/waste" 2>/dev/null)]"
[ "$(cat "$T/calls/job" 2>/dev/null)" = "j1 stage=done status=done meta=triage-state: rows unreadable" ] && ok \
  || bad "(D1) the job row is closed with the rows-unreadable meta: [$(cat "$T/calls/job" 2>/dev/null)]"
[ "$(cat "$T/calls/beat" 2>/dev/null)" = b1 ] && ok || bad "(D1) the job beat is stopped: [$(cat "$T/calls/beat" 2>/dev/null)]"
[ "$(cat "$SF" 2>/dev/null)" = 1 ] && ok || bad "(D1) the streak file reads 1: [$(cat "$SF" 2>/dev/null)]"
[ ! -e "$T/calls/alert" ] && ok || bad "(D1) no alert below the threshold"

# ═══ D2 — one alert per streak ═══════════════════════════════════════════════
calls_reset; rm -f "$SF"
dead_tick; dead_tick
[ "$(alerts)" = 0 ] && ok || bad "(D2) no alert at 2 skips: [$(cat "$T/calls/alert" 2>/dev/null)]"
dead_tick
[ "$(alerts)" = 1 ] && ok || bad "(D2) exactly one alert at 3 skips: [$(cat "$T/calls/alert" 2>/dev/null)]"
A1=$(grep -- '--id triage-rows-unreadable:' "$T/calls/alert" 2>/dev/null)
case "$A1" in "--id triage-rows-unreadable:project-4 --severity warn triage project-4: triage skipped 3 ticks in a row: "*) ok ;; *) bad "(D2) the alert's id, severity, lane and text: [$A1]" ;; esac
grep -q '(streak 3)' "$H/logs/$P.log" && ok || bad "(D2) the third skip line carries streak 3"
dead_tick
[ "$(alerts)" = 1 ] && ok || bad "(D2) a 4th skip sends no second alert: [$(cat "$T/calls/alert" 2>/dev/null)]"
[ "$(sed -n 1p "$SF" 2>/dev/null) $(sed -n 2p "$SF" 2>/dev/null)" = "4 alerted" ] && ok || bad "(D2) the streak file is '4' + 'alerted': [$(cat "$SF" 2>/dev/null)]"
WORKER_UP=1; tick_env enforce board-changed; OUT=$(tick) 2>/dev/null
[ ! -e "$SF" ] && ok || bad "(D2) a readable tick removes the streak file: [$(cat "$SF" 2>/dev/null)]"
case "$OUT" in *CONTINUED*) ok ;; *) bad "(D2) a readable tick runs: [$OUT]" ;; esac
dead_tick; dead_tick; dead_tick
[ "$(alerts)" = 2 ] && ok || bad "(D2) the next outage alerts afresh: [$(cat "$T/calls/alert" 2>/dev/null)]"
# a corrupt streak file reads as 0 and is rewritten
printf 'junk\nalerted\n' > "$SF"; dead_tick
[ "$(cat "$SF" 2>/dev/null)" = 1 ] && ok || bad "(D2) a corrupt streak file reads as 0: [$(cat "$SF" 2>/dev/null)]"

# ═══ D3 — queue work in scope: restricted, the streak untouched ══════════════
calls_reset; printf '2\n' > "$SF"
printf 'r1\tboard\nr2\tboard\nr2\tqueue\nr3\tboard\n' > "$T/units.tsv"
WORKER_UP=0; tick_env enforce queue-pending; QLINES="TK-r2 ready to launch"
D3=$( ts_tick >/dev/null 2>&1
      echo "CONTINUED [$PROMPT_TEXT]"
      echo "ENF=$TS_ENFORCING"
      ts_unit_skip "$T/units.tsv" r1; echo "R1=$?"
      ts_unit_skip "$T/units.tsv" r2; echo "R2=$?" ) 2>/dev/null
case "$D3" in *CONTINUED*) ok ;; *) bad "(D3) queue work runs the session: [$D3]" ;; esac
case "$D3" in *"TRIAGE STATE UNREADABLE: do NOT re-triage any ticket this tick; work only the queue lines, finished-build close-outs, UNBLOCKED/STACKABLE launches and PR lines in scope."*) ok ;;
  *) bad "(D3) the restricted directive is appended: [$D3]" ;; esac
case "$D3" in *"ENF=1"*) ok ;; *) bad "(D3) TS_ENFORCING=1: [$D3]" ;; esac
case "$D3" in *"R1=0"*) ok ;; *) bad "(D3) a board-only key is skipped by the shard filter: [$D3]" ;; esac
case "$D3" in *"R2=1"*) ok ;; *) bad "(D3) the queue key is dispatched: [$D3]" ;; esac
[ "$(cat "$SF" 2>/dev/null)" = 2 ] && ok || bad "(D3) a restricted tick leaves the streak alone: [$(cat "$SF" 2>/dev/null)]"
grep -q 'triage-state enforce: rows unreadable — session restricted to the queue and finished-build work in scope \[gate=queue-pending\]' "$H/logs/$P.log" && ok \
  || bad "(D3) the restricted line: $(cat "$H/logs/$P.log")"
[ "$(cat "$T/calls/waste" 2>/dev/null)" = restricted ] && ok || bad "(D3) ts_waste_account restricted: [$(cat "$T/calls/waste" 2>/dev/null)]"
[ ! -e "$T/calls/lane-tick" ] && [ ! -e "$T/calls/consume" ] && ok || bad "(D3) a restricted tick neither skips nor consumes"
# D3b — remote results and a PR line in scope are never starved behind a dead worker
calls_reset
WORKER_UP=0; tick_env enforce remote-results-pending; OUT=$(tick) 2>/dev/null
case "$OUT" in *CONTINUED*"TRIAGE STATE UNREADABLE"*) ok ;; *) bad "(D3b) remote-results-pending runs restricted: [$OUT]" ;; esac
WORKER_UP=0; tick_env enforce board-changed; TICK_SCOPE="board prs: #12 open"; OUT=$(tick) 2>/dev/null
case "$OUT" in *CONTINUED*"TRIAGE STATE UNREADABLE"*) ok ;; *) bad "(D3b) a 'board prs:' scope line runs restricted: [$OUT]" ;; esac
[ "$(cat "$SF" 2>/dev/null)" = 2 ] && ok || bad "(D3b) the streak is still untouched: [$(cat "$SF" 2>/dev/null)]"
# an UNBLOCKED / STACKABLE line's key is launch work: dispatched, and the prompt allows the launch
printf 'r1\tboard\nr2\tboard\nr3\tboard\n' > "$T/units.tsv"
WORKER_UP=0; tick_env enforce board-changed
TICK_SCOPE='board b1: UNBLOCKED r1 "t r1" (dependency done)'
BOARD_SEC=$'board b1:\n[HOTFIX] board b1: STACKABLE r3 "t r3" base=ticket/x'
D3B=$( ts_tick >/dev/null 2>&1
       echo "CONTINUED [$PROMPT_TEXT]"
       ts_unit_skip "$T/units.tsv" r1; echo "R1=$?"
       ts_unit_skip "$T/units.tsv" r2; echo "R2=$?"
       ts_unit_skip "$T/units.tsv" r3; echo "R3=$?" ) 2>/dev/null
case "$D3B" in *CONTINUED*"UNBLOCKED/STACKABLE launches"*) ok ;; *) bad "(D3b) the directive allows UNBLOCKED/STACKABLE launches: [$D3B]" ;; esac
case "$D3B" in *"R1=1"*) ok ;; *) bad "(D3b) the UNBLOCKED key is dispatched: [$D3B]" ;; esac
case "$D3B" in *"R3=1"*) ok ;; *) bad "(D3b) the STACKABLE key is dispatched: [$D3B]" ;; esac
case "$D3B" in *"R2=0"*) ok ;; *) bad "(D3b) a key no line releases is still skipped: [$D3B]" ;; esac
[ "$(cat "$SF" 2>/dev/null)" = 2 ] && ok || bad "(D3b) an UNBLOCKED tick leaves the streak alone: [$(cat "$SF" 2>/dev/null)]"
# D3c — a daily sweep with nothing in scope is skipped, never consumed
calls_reset
dead_tick daily-sweep
case "$OUT" in *CONTINUED*) bad "(D3c) a daily sweep with no work is skipped: [$OUT]" ;; *) ok ;; esac
[ ! -e "$T/calls/consume" ] && ok || bad "(D3c) the skipped daily sweep is not consumed (the sweep clock is not stamped)"
[ "$(sed -n 1p "$SF" 2>/dev/null)" = 3 ] && ok || bad "(D3c) the skip bumps the streak: [$(cat "$SF" 2>/dev/null)]"

# ═══ D4 — a forced tick and a gate-error tick are never skipped ══════════════
for r in forced forced-env gate-error; do
  calls_reset; rm -f "$SF"
  dead_tick "$r"
  case "$OUT" in *CONTINUED*) ok ;; *) bad "(D4) a $r tick runs: [$OUT]" ;; esac
  case "$OUT" in *"TRIAGE STATE UNREADABLE"*) bad "(D4) a $r tick is not restricted: [$OUT]" ;; *) ok ;; esac
  [ ! -e "$SF" ] && ok || bad "(D4) a $r tick writes no streak file"
  grep -q 'tick skipped' "$H/logs/$P.log" && bad "(D4) a $r tick logs no skip" || ok
done

# ═══ D5 — no-gate-state and gate-fetch-failed skip like D1 ═══════════════════
for r in no-gate-state gate-fetch-failed; do
  calls_reset; rm -f "$SF"
  dead_tick "$r"
  case "$OUT" in *CONTINUED*) bad "(D5) a $r tick with no work is skipped: [$OUT]" ;; *) ok ;; esac
  grep -qF "rc=skip :: triage-state: rows unreadable — tick skipped, no model call (streak 1) [gate=$r]" "$H/logs/$P.log" && ok \
    || bad "(D5) the $r skip line: $(cat "$H/logs/$P.log")"
  [ ! -e "$T/calls/consume" ] && ok || bad "(D5) a $r skip is not consumed"
done

# ═══ D6 — no board fingerprint: the pre-check never read the rows ════════════
calls_reset; rm -f "$SF"
mv "$H/state/$P.gate.pending" "$T/gp.save"
dead_tick
case "$OUT" in *CONTINUED*) ok ;; *) bad "(D6) no fingerprint: the tick runs as before: [$OUT]" ;; esac
grep -q 'tick skipped' "$H/logs/$P.log" && bad "(D6) no skip line with no fingerprint" || ok
[ ! -e "$SF" ] && ok || bad "(D6) no streak file with no fingerprint"
mv "$T/gp.save" "$H/state/$P.gate.pending"

# ═══ D7 — shadow is unchanged ════════════════════════════════════════════════
calls_reset; rm -f "$SF"
WORKER_UP=0; tick_env shadow board-changed; OUT=$(tick) 2>/dev/null
case "$OUT" in "CONTINUED [SOP PROMPT]") ok ;; *) bad "(D7) shadow runs the tick untouched: [$OUT]" ;; esac
grep 'triage-state shadow:' "$H/logs/$P.log" | grep -qF '(rows unreadable: every ticket to the model)' && ok \
  || bad "(D7) the shadow line still names the rows-unreadable fail-open: $(cat "$H/logs/$P.log")"
[ ! -e "$SF" ] && ok || bad "(D7) shadow writes no streak file"

# ═══ D8 — lane-alert cannot run: the real bin/alert-line.sh ══════════════════
calls_reset; rm -f "$SF" "$H/logs/ALERTS.log"
chmod -x "$H/bin/lane-alert.sh"
dead_tick; dead_tick; dead_tick; dead_tick
[ "$(grep -c 'triage skipped' "$H/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok || bad "(D8) one alert-line line: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
case "$(cat "$H/logs/ALERTS.log" 2>/dev/null)" in "2026-10-01 10:00:00Z project-4: triage skipped 3 ticks in a row: the triage_state rows could not be read"*) ok ;;
  *) bad "(D8) the line is stamped and carries the text: $(cat "$H/logs/ALERTS.log" 2>/dev/null)" ;; esac
[ ! -e "$T/calls/alert" ] && ok || bad "(D8) the non-executable lane-alert is never run"
chmod +x "$H/bin/lane-alert.sh"
# lane-alert answers non-zero: the same fallback, and the streak is marked
calls_reset; rm -f "$SF" "$H/logs/ALERTS.log"; touch "$T/alert-fail"
dead_tick; dead_tick; dead_tick
[ "$(alerts)" = 1 ] && [ "$(grep -c 'triage skipped 3 ticks' "$H/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok \
  || bad "(D8) a failing lane-alert falls back to alert-line: [$(cat "$T/calls/alert" 2>/dev/null)] [$(cat "$H/logs/ALERTS.log" 2>/dev/null)]"
[ "$(sed -n 2p "$SF" 2>/dev/null)" = alerted ] && ok || bad "(D8) the delivered fallback marks the streak: [$(cat "$SF" 2>/dev/null)]"
# both fail: not marked, so the next skip sends again
calls_reset; rm -f "$SF" "$H/logs/ALERTS.log"; chmod -x "$H/bin/alert-line.sh"
dead_tick; dead_tick; dead_tick
[ "$(sed -n 2p "$SF" 2>/dev/null)" = "" ] && ok || bad "(D8) no delivery leaves the streak unalerted: [$(cat "$SF" 2>/dev/null)]"
chmod +x "$H/bin/alert-line.sh"; rm -f "$T/alert-fail"
dead_tick
[ "$(alerts)" = 2 ] && [ "$(sed -n 2p "$SF" 2>/dev/null)" = alerted ] && ok \
  || bad "(D8) the next skip retries and marks it: [$(cat "$T/calls/alert" 2>/dev/null)] [$(cat "$SF" 2>/dev/null)]"

# ═══ K — the threshold is a settings row ═════════════════════════════════════
calls_reset; rm -f "$SF"
printf '{"fetched_at":1000,"values":{"lib.triage-state.triage_state_unreadable_alert_after":"2"},"seeded":{}}\n' > "$H/state/settings-cache.json"
( unset TRIAGE_STATE_UNREADABLE_ALERT_AFTER; dead_tick; echo "after1=$(alerts)" > "$T/k1"
  dead_tick; echo "after2=$(alerts)" > "$T/k2" ) 2>/dev/null
[ "$(cat "$T/k1" 2>/dev/null)" = after1=0 ] && ok || bad "(K) no alert at tick 1 with the row at 2: [$(cat "$T/k1" 2>/dev/null)]"
[ "$(cat "$T/k2" 2>/dev/null)" = after2=1 ] && ok || bad "(K) the alert at tick 2 with the row at 2: [$(cat "$T/k2" 2>/dev/null)] [$(cat "$T/calls/alert" 2>/dev/null)]"
case "$(cat "$T/calls/alert" 2>/dev/null)" in *"triage skipped 2 ticks in a row"*) ok ;; *) bad "(K) the alert names 2 ticks: [$(cat "$T/calls/alert" 2>/dev/null)]" ;; esac
rm -f "$H/state/settings-cache.json"

echo "triage-state-unreadable.bh-3925: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
