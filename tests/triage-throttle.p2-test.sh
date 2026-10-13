#!/bin/bash
# tests/triage-throttle.p2-test.sh — P2: a per-project triage cadence and
# ceiling (bin/lib/triage-throttle.sh:triage_throttle_check), wired into the
# gate stage of the triage tick (bin/lib/rt/gate.sh:rt_gate) and counted where
# the money is actually spent (rt_launch / the shard dispatch).
# Run from anywhere: tests/triage-throttle.p2-test.sh   (exit 0 = all pass)
#
# WHAT THIS PINS AND WHY. Seven days of cost rows (2026-09-25): on the boards
# that ship least, triage is most of the bill — project-1 $637 of triage for 13
# merges, project-7 $649 for 6, project-8 $238 for 4. The gate already
# answers "did the world change", and on those boards it changes all day (queue
# restamps, result sweeps, comment bumps), so every change buys a session. The
# lever is VOLUME, not a dollar budget (the operator): a low-yield board gets its paid
# ticks at a cadence, plus the ticks that must never wait:
#   forced        an operator asked — never held
#   daily-sweep   the safety net — never held
#   no-gate-state first run — never held
#   event-wake    a webhook said the client moved — never held either (#2294
#                 review I4): the wake-loop's own cooldown is its limiter, and a
#                 client reply must not wait out a 24h ceiling
# Knobs are settings rows on the run-triage lane, per project
# (`lane.run-triage.<project>.triage_min_interval_s` /
# `.triage_max_runs_day`), exported by lane_env_apply; default 0 = today.
#
# THE LEDGER COUNTS PAID LAUNCHES, NOT GATE ANSWERS (#2294 review I3). A tick
# the gate lets through can still end without buying anything (scope.sh's
# "event-wake named no board object", a shard pass that dispatched nothing), so
# the check never records; triage_throttle_record does, at rt_launch before the
# agent call and at the shard dispatch when at least one shard went out.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

NOW=1790000000
export HARNESS="$T"
mkdir -p "$T/bin/lib/rt" "$T/state" "$T/logs" "$T/flags"
[ -r "$DIR/bin/lib/triage-throttle.sh" ] && cp "$DIR/bin/lib/triage-throttle.sh" "$T/bin/lib/" \
  || { bad "bin/lib/triage-throttle.sh must exist"; echo "triage-throttle.p2: $PASS passed, $FAIL failed"; exit 1; }
. "$T/bin/lib/triage-throttle.sh"
command -v triage_throttle_record >/dev/null 2>&1 && ok \
  || { bad "bin/lib/triage-throttle.sh must define triage_throttle_record (the launch-time ledger write)"; echo "triage-throttle.p2: $PASS passed, $FAIL failed"; exit 1; }

allow() { # allow <reason> <offset-seconds> — the gate-time question only
  TRIAGE_THROTTLE_NOW=$((NOW + $2)) triage_throttle_check "$T" proj "$1" >/dev/null 2>&1; }
paid() {  # paid <reason> <offset> — allowed AND launched (recorded), like a real tick
  allow "$1" "$2" && TRIAGE_THROTTLE_NOW=$((NOW + $2)) triage_throttle_record "$T" proj; }
held_why() { TRIAGE_THROTTLE_NOW=$((NOW + $2)) triage_throttle_check "$T" proj "$1" 2>/dev/null; }
rows() { local n; n=$(grep -c . "$T/state/triage-throttle/proj.runs" 2>/dev/null); printf '%s' "${n:-0}"; }
reset() { rm -rf "$T/state/triage-throttle" "$T/state/wake-proj"; }

# --- T1 no knobs: today's behaviour exactly ---------------------------------
reset
unset TRIAGE_MIN_INTERVAL_S TRIAGE_MAX_RUNS_DAY
A=0; for i in 1 2 3 4 5 6; do paid board-changed "$i" && A=$((A+1)); done
[ "$A" = 6 ] && ok || bad "T1 with no knob set every tick is allowed (allowed $A/6)"
[ "$(rows)" = 0 ] && ok || bad "T1 an unthrottled project keeps no ledger (got $(rows) rows)"

# --- T2 cadence -------------------------------------------------------------
reset
export TRIAGE_MIN_INTERVAL_S=3600
paid board-changed 0    && ok || bad "T2 the first paid tick is allowed"
allow queue-pending 600 && bad "T2 a tick 10m later is held by a 60m cadence" || ok
case "$(held_why results-sweep 900)" in *interval*|*cadence*) ok ;; *) bad "T2 the hold names the cadence (got: $(held_why results-sweep 900))" ;; esac
paid board-changed 3700 && ok || bad "T2 past the interval the tick runs again"

# --- T3/T4 exempt reasons ---------------------------------------------------
allow forced 3800        && ok || bad "T3 forced is never held"
allow forced-env 3810    && ok || bad "T3 forced-env is never held"
allow event-wake 3900    && ok || bad "T4 an event wake is exempt from the cadence"
allow daily-sweep 3950   && ok || bad "T4 the daily sweep is never held"
allow no-gate-state 3960 && ok || bad "T4 no-gate-state is never held"

# --- T5 ceiling -------------------------------------------------------------
reset
export TRIAGE_MIN_INTERVAL_S=0 TRIAGE_MAX_RUNS_DAY=2
paid board-changed 0   && ok || bad "T5 run 1/2 allowed"
paid board-changed 100 && ok || bad "T5 run 2/2 allowed"
allow board-changed 200 && bad "T5 run 3 is past the ceiling of 2/24h" || ok
case "$(held_why queue-pending 210)" in *ceiling*) ok ;; *) bad "T5 the hold names the ceiling (got: $(held_why queue-pending 210))" ;; esac
allow event-wake 300   && ok || bad "T5 an event wake is NOT held by the ceiling (I4: a client reply never waits out 24h)"
allow forced 310       && ok || bad "T5 forced passes the ceiling"
allow daily-sweep 320  && ok || bad "T5 the daily sweep passes the ceiling"
allow board-changed $((86400 + 400)) && ok || bad "T5 a day later the window has rolled and the tick runs"

# --- T6 an unreadable knob is never 'hold everything' ------------------------
reset
export TRIAGE_MIN_INTERVAL_S=soon TRIAGE_MAX_RUNS_DAY=-4
A=0; for i in 1 2 3; do paid board-changed "$i" && A=$((A+1)); done
[ "$A" = 3 ] && ok || bad "T6 garbage knobs fall back to off (allowed $A/3)"

# --- T7 the check never writes; only a launch does ---------------------------
reset
export TRIAGE_MIN_INTERVAL_S=3600 TRIAGE_MAX_RUNS_DAY=5
allow board-changed 0; allow event-wake 10; allow queue-pending 20
[ "$(rows)" = 0 ] && ok || bad "T7 an allowed-but-not-launched tick consumes nothing (got $(rows) rows)"
paid board-changed 30
for i in 60 120 180; do allow board-changed "$i"; done
[ "$(rows)" = 1 ] && ok || bad "T7 only the launched tick is on the ledger (got $(rows) rows)"

# --- R. wired into the tick ---------------------------------------------------
# rt_gate / rt_launch are sourced from the real files; everything they shell
# out to is a stub.
cp "$DIR/bin/lib/rt/gate.sh" "$DIR/bin/lib/rt/launch.sh" "$T/bin/lib/rt/"
printf '#!/bin/bash\necho "${GATE_STUB:-RUN board-changed}"\n' > "$T/bin/triage-gate.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/orphan-reconcile.sh"
cp "$T/bin/orphan-reconcile.sh" "$T/bin/hotfix-seen.sh"
cp "$T/bin/orphan-reconcile.sh" "$T/bin/decision-log.sh"
cp "$T/bin/orphan-reconcile.sh" "$T/bin/lane-alert.sh"
printf '#!/bin/bash\necho "$1" >> "$HARNESS/agent-calls.txt"\nexit 0\n' > "$T/bin/agent-call.sh"
printf '#!/bin/bash\n[ "$1" = --projects ] && { echo proj; exit 0; }\ncase "$2" in repo) echo example-org/proj ;; board_prefix) echo /api/board ;; prod) echo https://x ;; esac\n' > "$T/bin/fleet-conf.sh"
chmod +x "$T/bin/"*.sh
mkdir -p "$T/repos/proj/.git"
tick() { # tick [launch] -> prints CONTINUED when rt_gate returned (the paid path)
  ( PROJECT=proj STAMP=now LOG="$T/logs/proj.log" ALERTS="$T/logs/ALERTS.log" REPOS_ROOT="$T/repos" \
    ORPHAN_RECONCILE=0 GH_TOKEN=ghs_x OUT="$T/out.txt" PROMPT_TEXT=p TRIAGE_MODEL=m \
    EFFECTIVE_GROK_EFFORT="" TRIAGE_APPEND="" SCOPE_N=full
    LANE_TICK() { echo "$1" >> "$T/lane-ticks.txt"; }
    lock_run_unheld() { "$@"; }
    . "$T/bin/lib/rt/gate.sh"; . "$T/bin/lib/rt/launch.sh"
    rt_gate
    echo "CONTINUED ${GATE_DECISION:-}"
    [ "${1:-}" = launch ] && rt_launch >/dev/null 2>&1
    exit 0 ) 2>/dev/null
}
reset; : > "$T/logs/proj.log"; : > "$T/lane-ticks.txt"
unset TRIAGE_MAX_RUNS_DAY; export TRIAGE_MIN_INTERVAL_S=3600
case "$(TRIAGE_THROTTLE_NOW=$NOW tick launch)" in CONTINUED*) ok ;; *) bad "R1 the first paid tick continues past rt_gate" ;; esac
[ "$(rows)" = 1 ] && ok || bad "R1 rt_launch records the paid tick BEFORE the agent call (got $(rows) rows)"
case "$(TRIAGE_THROTTLE_NOW=$((NOW+60)) tick)" in CONTINUED*) bad "R2 a tick inside the cadence must end in rt_gate" ;; *) ok ;; esac
grep -q 'rc=skip :: .*throttle' "$T/logs/proj.log" && ok \
  || bad "R2 the held tick logs rc=skip with the throttle reason (log: $(tail -2 "$T/logs/proj.log"))"
tail -1 "$T/lane-ticks.txt" | grep -qx paused && ok || bad "R2 a held tick reports LANE_TICK paused, not skip (got: $(tail -1 "$T/lane-ticks.txt"))"
case "$(GATE_STUB='RUN forced' TRIAGE_THROTTLE_NOW=$((NOW+120)) tick)" in CONTINUED*) ok ;; *) bad "R3 forced continues inside the cadence" ;; esac
case "$(GATE_STUB='SKIP no-change (3 tickets)' TRIAGE_THROTTLE_NOW=$((NOW+130)) tick)" in CONTINUED*) bad "R4 a gate SKIP still ends the tick" ;; *) ok ;; esac

# R5 I3: a wake the gate lets through but that never launches (scope.sh:387,
# "event-wake named no board object") consumes no ceiling slot.
reset; export TRIAGE_MIN_INTERVAL_S=0 TRIAGE_MAX_RUNS_DAY=1
for i in 1 2 3; do GATE_STUB='RUN event-wake' TRIAGE_THROTTLE_NOW=$((NOW+i)) tick >/dev/null; done
[ "$(rows)" = 0 ] && ok || bad "R5 wakes that skipped after the gate consumed $(rows) ceiling slot(s)"
case "$(TRIAGE_THROTTLE_NOW=$((NOW+10)) tick launch)" in CONTINUED*) ok ;; *) bad "R5 the ceiling slot is still free for a real launch" ;; esac
case "$(TRIAGE_THROTTLE_NOW=$((NOW+20)) tick)" in CONTINUED*) bad "R5 the launched tick used the only slot" ;; *) ok ;; esac

# R6 the shard dispatch records too: one row per tick that dispatched at least
# one shard, written in the dispatch block of rt_shards.
awk '/SHARD_N" -gt 0/ && /triage_throttle_record/ {f=1} END {exit !f}' "$DIR/bin/lib/rt/shards.sh" && ok \
  || bad "R6 bin/lib/rt/shards.sh must call triage_throttle_record when SHARD_N > 0"
unset TRIAGE_MIN_INTERVAL_S TRIAGE_MAX_RUNS_DAY
case "$(TRIAGE_THROTTLE_NOW=$((NOW+140)) tick)" in CONTINUED*) ok ;; *) bad "R7 with no knob the gate's RUN is today's RUN" ;; esac

echo "triage-throttle.p2: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
