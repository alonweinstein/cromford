#!/bin/bash
# tests/triage-health.p2-test.sh — P2: a deterministic health precondition in
# front of every PAID triage tick (bin/lib/triage-throttle.sh:triage_health_check,
# wired into bin/lib/rt/gate.sh:rt_gate).
# Run from anywhere: tests/triage-health.p2-test.sh   (exit 0 = all pass)
#
# WHAT THIS PINS AND WHY. project-9 spent $643 in seven days with ZERO merges
# (2026-09-25): the lane kept buying triage sessions against a board/repo pair
# that could not turn any of them into a build. A session bought for a project
# that has no repo, no board, or a board whose fetch has failed tick after tick
# concludes nothing — and the gate fails OPEN on a failed fetch
# (`RUN gate-fetch-failed`), so the broken project was the one paying every tick.
#
# The check is free (fleet.conf, one marker file, the fetch streak, and ONE
# re-probe of the board fetch when the streak says it is down) and names no
# project. After the #2294 review:
#   - it holds only the gate reasons that NEED the board read (S1): a queue,
#     split-chain, results or remote-results tick proceeds;
#   - only a real fetch failure feeds the streak, never a gate crash (S4);
#   - the claude-auth-down.txt read is GONE (I2): that file holds short labels
#     (`small`, `hub`, `<box>-openrouter`) and lives only on the hub, so it could
#     never match a box — H7 now proves the file has no effect at all;
#   - the hold is a warn DIGEST via bin/lane-alert.sh --id triage-health:<p>
#     (S3), once a day, and the tick reports LANE_TICK paused.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HARNESS="$T" REPOS_ROOT="$T/repos" FLEET_CONF="$T/fleet.conf"
mkdir -p "$T/bin/lib/rt" "$T/state" "$T/logs" "$T/flags" "$T/repos"
[ -r "$DIR/bin/lib/triage-throttle.sh" ] && cp "$DIR/bin/lib/triage-throttle.sh" "$T/bin/lib/" \
  || { bad "bin/lib/triage-throttle.sh must exist"; echo "triage-health.p2: $PASS passed, $FAIL failed"; exit 1; }
cp "$DIR/bin/fleet-conf.sh" "$T/bin/"
printf '#!/bin/bash\necho box-small\n' > "$T/bin/box-name.sh"
# The board re-probe: bin/triage-gate.sh <p> --pending. rc from PROBE_RC.
printf '#!/bin/bash\n[ "$2" = --pending ] && { echo probed >> "$HARNESS/probes.txt"; exit "${PROBE_RC:-1}"; }\necho "${GATE_STUB:-RUN board-changed}"\n' > "$T/bin/triage-gate.sh"
# lane-alert.sh records its argv, one call per line.
printf '#!/bin/bash\necho "$*" >> "$HARNESS/lane-alerts.txt"\n' > "$T/bin/lane-alert.sh"
chmod +x "$T/bin/"*.sh
. "$T/bin/lib/triage-throttle.sh"

conf() { printf '%s\n' "$@" > "$T/fleet.conf"; }
healthy() { triage_health_check "$T" "${1:-proj}" >/dev/null 2>&1; }
why()     { triage_health_check "$T" "${1:-proj}" 2>/dev/null; }

GOOD='proj example-org/proj https://os.example.com /api/board 0 box-a -'
conf "$GOOD"; mkdir -p "$T/repos/proj/.git"

# --- H1 healthy ------------------------------------------------------------
healthy && ok || bad "H1 a project with a repo, a board and a checkout is healthy (why: $(why))"

# --- H2 no repo -----------------------------------------------------------
conf 'proj - https://os.example.com /api/board 0 box-a -'
healthy && bad "H2 fleet.conf repo '-' is has_repo=false" || ok
case "$(why)" in *repo*) ok ;; *) bad "H2 the reason names the repo (got: $(why))" ;; esac
conf 'other example-org/o - - 0 box-a -'
healthy && bad "H2 a project fleet.conf does not list has no repo and no board" || ok

# --- H3 no checkout (opt-in) -------------------------------------------------
conf "$GOOD"; rm -rf "$T/repos/proj"
healthy && ok || bad "H3 by default a missing checkout does not hold triage (TRIAGE_HEALTH_NEED_CLONE defaults 0)"
TRIAGE_HEALTH_NEED_CLONE=1 triage_health_check "$T" proj >/dev/null 2>&1 \
  && bad "H3 with TRIAGE_HEALTH_NEED_CLONE=1, no checkout at REPOS_ROOT/<project> is unhealthy" || ok
case "$(TRIAGE_HEALTH_NEED_CLONE=1 triage_health_check "$T" proj 2>/dev/null)" in *checkout*) ok ;; *) bad "H3 the reason names the checkout" ;; esac
mkdir -p "$T/repos/proj/.git"

# --- H4 no board ------------------------------------------------------------
conf 'proj example-org/proj - /api/board 0 box-a -'
healthy && bad "H4 an in-app board prefix with no base URL is has_board=false" || ok
case "$(why)" in *board*) ok ;; *) bad "H4 the reason names the board (got: $(why))" ;; esac
conf 'proj example-org/proj https://x - 0 box-a -'
healthy && ok || bad "H4 a GitHub-Issues board (prefix '-') with a repo is a board"

# --- H5 board-fetch streak, with a re-probe -------------------------------
conf "$GOOD"; rm -f "$T/probes.txt"
for i in 1 2; do triage_health_note "$T" proj 'RUN gate-fetch-failed'; done
healthy && ok || bad "H5 two failed fetches are weather, not an outage (default streak 3)"
[ -e "$T/probes.txt" ] && bad "H5 under the streak no re-probe is spent" || ok
for i in 1 2 3 4; do triage_health_note "$T" proj 'RUN gate-error'; done
PROBE_RC=1 triage_health_check "$T" proj >/dev/null 2>&1 && ok \
  || bad "H5 S4: a gate crash (RUN gate-error) is not a board fetch failure and never feeds the streak"
triage_health_note "$T" proj 'RUN gate-fetch-failed'
PROBE_RC=1 triage_health_check "$T" proj >/dev/null 2>&1 && bad "H5 three failed fetches and a failed re-probe is unhealthy" || ok
case "$(PROBE_RC=1 triage_health_check "$T" proj 2>/dev/null)" in *fetch*) ok ;; *) bad "H5 the reason names the board fetch" ;; esac
PROBE_RC=0 triage_health_check "$T" proj >/dev/null 2>&1 && ok || bad "H5 a re-probe that answers heals the project at once"
PROBE_RC=1 triage_health_check "$T" proj >/dev/null 2>&1 && ok || bad "H5 a healed streak is reset (no re-probe owed until 3 more failures)"
for i in 1 2 3; do triage_health_note "$T" proj 'RUN gate-fetch-failed'; done
triage_health_note "$T" proj 'SKIP no-change (4 tickets)'
PROBE_RC=1 triage_health_check "$T" proj >/dev/null 2>&1 && ok || bad "H5 a successful board read resets the streak"
for i in 1 2 3; do triage_health_note "$T" proj 'RUN gate-fetch-failed'; done
triage_health_note "$T" proj 'RUN queue-pending'
PROBE_RC=1 triage_health_check "$T" proj >/dev/null 2>&1 && bad "H5 a tick that never fetched is neutral — the streak stands" || ok
TRIAGE_HEALTH_FETCH_FAILS=0 PROBE_RC=1 triage_health_check "$T" proj >/dev/null 2>&1 && ok \
  || bad "H5 TRIAGE_HEALTH_FETCH_FAILS=0 turns the fetch probe off"
rm -rf "$T/state/triage-health"

# --- H6 an explicit down marker (an operator or any probe writes it) -------
mkdir -p "$T/state/triage-health"; echo 'board token 401 since 09-24' > "$T/state/triage-health/proj.down"
healthy && bad "H6 state/triage-health/<p>.down makes the project unhealthy" || ok
case "$(why)" in *401*) ok ;; *) bad "H6 the marker's own words are the reason (got: $(why))" ;; esac
rm -f "$T/state/triage-health/proj.down"

# --- H7 claude-auth-down.txt is NOT read (I2) -----------------------------
# Every spelling that file could hold for this box — the full box name, the
# short label claude-auth-check writes, the -openrouter account id — and none
# of them holds triage: the check was removed because it could never match a
# box, and a test that passed on matching names would be claiming it works.
printf 'box-small\nsmall\nsmall-openrouter\nhub\n' > "$T/state/claude-auth-down.txt"
healthy && ok || bad "H7 claude-auth-down.txt must have no effect on triage health (the check is removed)"
grep -qE '^[[:space:]]*[^#[:space:]][^#]*claude-auth-down' "$T/bin/lib/triage-throttle.sh" \
  && bad "H7 no code line may read claude-auth-down.txt" || ok
rm -f "$T/state/claude-auth-down.txt"

# --- H8 the switch -----------------------------------------------------------
conf 'proj - - - 0 box-a -'
TRIAGE_HEALTH_GATE=0 triage_health_check "$T" proj >/dev/null 2>&1 && ok || bad "H8 TRIAGE_HEALTH_GATE=0 turns the gate off"
touch "$T/flags/triage-health-off"
healthy && ok || bad "H8 flags/triage-health-off turns the gate off"
rm -f "$T/flags/triage-health-off"

# --- R. wired into the gate stage -------------------------------------------
cp "$DIR/bin/lib/rt/gate.sh" "$T/bin/lib/rt/"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/orphan-reconcile.sh"; cp "$T/bin/orphan-reconcile.sh" "$T/bin/hotfix-seen.sh"
chmod +x "$T/bin/"*.sh
tick() {
  ( PROJECT=proj STAMP=now LOG="$T/logs/proj.log" ALERTS="$T/logs/ALERTS.log" ORPHAN_RECONCILE=0 GH_TOKEN=ghs_x
    LANE_TICK() { echo "$1" >> "$T/lane-ticks.txt"; }
    . "$T/bin/lib/rt/gate.sh"
    rt_gate
    echo "CONTINUED ${GATE_DECISION:-}" ) 2>/dev/null
}
conf 'proj - https://os.example.com /api/board 0 box-a -'   # has_repo=false
: > "$T/logs/proj.log"; : > "$T/logs/ALERTS.log"; : > "$T/lane-ticks.txt"; rm -f "$T/lane-alerts.txt"
case "$(tick)" in CONTINUED*) bad "R1 an unhealthy project's board-changed tick must end in rt_gate" ;; *) ok ;; esac
grep -q 'rc=skip :: .*health' "$T/logs/proj.log" && ok || bad "R1 the held tick logs rc=skip with the health reason (log: $(tail -1 "$T/logs/proj.log"))"
tail -1 "$T/lane-ticks.txt" | grep -qx paused && ok || bad "R1 S3: a health hold reports LANE_TICK paused (got: $(tail -1 "$T/lane-ticks.txt"))"
N=$(grep -c . "$T/lane-alerts.txt" 2>/dev/null); [ "${N:-0}" = 1 ] && ok || bad "R2 one lane-alert on the first held tick (got ${N:-0})"
grep -q -- '--id triage-health:proj' "$T/lane-alerts.txt" 2>/dev/null && grep -q -- '--severity warn' "$T/lane-alerts.txt" && ok \
  || bad "R2 S3: the hold goes through bin/lane-alert.sh --id triage-health:<p> --severity warn (got: $(cat "$T/lane-alerts.txt" 2>/dev/null))"
tick >/dev/null; tick >/dev/null
N=$(grep -c . "$T/lane-alerts.txt"); [ "$N" = 1 ] && ok || bad "R2 one alert per project per day, not per tick (got $N)"
grep -q 'triage-health' "$T/logs/ALERTS.log" && bad "R2 S3: no raw ALERTS.log line when lane-alert.sh ran" || ok
case "$(GATE_STUB='RUN forced' tick)" in CONTINUED*) ok ;; *) bad "R3 an operator's forced tick runs even when unhealthy" ;; esac
# S1: only reasons that need the board read are held.
for r in queue-pending split-ready remote-results-pending results-sweep; do
  case "$(GATE_STUB="RUN $r" tick)" in CONTINUED*) ok ;; *) bad "R3 S1: RUN $r does not need the board fetch and must proceed while unhealthy" ;; esac
done
for r in board-changed daily-sweep event-wake no-gate-state gate-fetch-failed; do
  case "$(GATE_STUB="RUN $r" tick)" in CONTINUED*) bad "R3 S1: RUN $r needs the board and must be held while unhealthy" ;; *) ok ;; esac
done
conf "$GOOD"
case "$(tick)" in CONTINUED*) ok ;; *) bad "R4 a healthy project's RUN continues" ;; esac
# the streak is fed by the gate's own answers, including the SKIPs
rm -rf "$T/state/triage-health"
for i in 1 2 3; do GATE_STUB='RUN gate-fetch-failed' PROBE_RC=1 tick >/dev/null; done
[ "$(head -1 "$T/state/triage-health/proj.fetchfail" 2>/dev/null)" -ge 2 ] 2>/dev/null && ok \
  || bad "R5 rt_gate feeds the gate's decision into the fetch streak"
case "$(GATE_STUB='RUN gate-fetch-failed' PROBE_RC=1 tick)" in CONTINUED*) bad "R5 past the streak a fail-open RUN is held" ;; *) ok ;; esac
case "$(GATE_STUB='RUN queue-pending' PROBE_RC=1 tick)" in CONTINUED*) ok ;; *) bad "R5 S1: a dead board fetch does not hold a queue tick" ;; esac
GATE_STUB='SKIP no-change (2 tickets)' tick >/dev/null
case "$(GATE_STUB='RUN board-changed' PROBE_RC=1 tick)" in CONTINUED*) ok ;; *) bad "R6 a board read that worked (SKIP no-change) heals the streak through rt_gate" ;; esac

echo "triage-health.p2: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
