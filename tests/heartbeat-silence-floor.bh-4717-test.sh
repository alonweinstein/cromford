#!/bin/bash
# tests/heartbeat-silence-floor.bh-4717-test.sh — the silence floor on the lane
# heartbeat (BH-4717.0). bin/lib/heartbeat.sh hb_state calls a live lane silent
# only past max(interval x HB_STALE_MULT, HB_SILENT_FLOOR_S), default 120, 0 = off,
# and bin/heartbeat-reaper.sh renders every age through hb_age_text ("<n>s" under
# a minute), so a wake-loop (interval 15) 50s after a tick no longer pages
# "wake-loop silent for 0m". 31 of those pages landed on 2026-10-05.
#
# The weight is on the NEGATIVES (W1, W1b, W4): a live lane under the floor stays
# quiet. W3 and W7 are the same fixture with the floor off, so a W1 that passes
# because the reaper never ran cannot pass here too.
#
# W1-W4 and W7 drive the REAL bin/heartbeat-reaper.sh against a scratch $HARNESS,
# on fixtures bin/lib/heartbeat.sh hb_start/hb_tick wrote at a pinned clock; the
# assertions are on logs/ALERTS.log and the beats a recorder beat.sh saw.
#
# Run from anywhere: tests/heartbeat-silence-floor.bh-4717-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date +%s)
BOOT=$((NOW - 86400))

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state/heartbeat" "$H/flags" "$H/locks" "$H/env" "$T/fakebin"
for s in bin/heartbeat-reaper.sh bin/lane-alert.sh bin/alert-line.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "FAIL: scratch_install_closure $s"; exit 1; }
done
cp "$DIR/bin/alert_family.py" "$H/bin/" 2>/dev/null
chmod +x "$H/bin/"*.sh 2>/dev/null
: > "$H/env/global.env"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/beats.txt"\n' "$T" > "$H/bin/beat.sh"
chmod +x "$H/bin/beat.sh"
printf '#!/bin/bash\nexec "$@"\n' > "$T/fakebin/setsid"; chmod +x "$T/fakebin/setsid"

export HARNESS="$H"
# shellcheck source=bin/lib/heartbeat.sh
. "$DIR/bin/lib/heartbeat.sh" 2>/dev/null || true
command -v hb_start >/dev/null 2>&1 || bad "bin/lib/heartbeat.sh is missing or does not define hb_start"

HBD="$H/state/heartbeat"
ALERTS="$H/logs/ALERTS.log"
ALL="$T/all-alerts.log"; : > "$ALL"

# A live pid this suite owns (`trap - EXIT` so the child never runs scratch.sh's trap).
( trap - EXIT; exec sleep 300 ) & LIVE=$!
__fl_exit() { local rc=$?
              [ "${__scratch_owner_pid:-}" = "${BASHPID:-$$}" ] || return 0
              kill "$LIVE" 2>/dev/null
              scratch_cleanup; exit "$rc"; }
trap __fl_exit EXIT

# mk <lane> <interval> <expect> <started-ago> <tick-ago> <pid> — written by the LIB.
mk() {
  HB_PID="$6" HB_NOW=$((NOW - $4)) hb_start "$1" "$2" "$3" ""
  HB_PID="$6" HB_NOW=$((NOW - $5)) hb_tick "$1" "tick"
}
# reset keeps every ALERTS.log this suite produced in $ALL, for W4.
reset() {
  [ -f "$ALERTS" ] && cat "$ALERTS" >> "$ALL"
  scratch_rm "$HBD" >/dev/null 2>&1
  scratch_rm "$H/state/alerts" >/dev/null 2>&1
  mkdir -p "$HBD"
  : > "$ALERTS"; : > "$T/beats.txt"; : > "$H/logs/heartbeat-reaper.log"
  : > "$H/env/global.env"
}
# reap [VAR=VAL ...] — one pass of the real reaper, clock pinned. HB_SILENT_FLOOR_S
# is unset first so the caller's own environment cannot pick the answer.
reap() {
  ( unset HB_SILENT_FLOOR_S HB_STALE_MULT
    export HARNESS="$H" HB_NOW="$NOW" HB_BOOT_AT="$BOOT" PATH="$T/fakebin:$PATH"
    while [ $# -gt 0 ]; do export "${1?}"; shift; done
    timeout 20 "$H/bin/heartbeat-reaper.sh"; echo "rc=$?" )
}
lines() { local n; n=$(grep -c 'orchestrator/heartbeat-reaper' "$ALERTS" 2>/dev/null); printf '%s' "${n:-0}"; }
beats() { local n; n=$(grep -c . "$T/beats.txt" 2>/dev/null); printf '%s' "${n:-0}"; }

# --- W1: a wake-loop (interval 15) 50s after its tick, default floor: quiet ----
reset
mk wake-loop 15 0 60 50 "$LIVE"
out=$(reap)
case "$out" in *rc=0*) ok ;; *) bad "W1 reaper did not exit 0: $out" ;; esac
[ "$(lines)" = 0 ] && ok || bad "W1 50s under the 120s floor must not page: $(cat "$ALERTS")"
[ "$(beats)" = 0 ] && ok || bad "W1 50s under the 120s floor must not beat: $(cat "$T/beats.txt")"

# --- W1b: a non-numeric floor falls back to 120, never to 0 -----------------------
reset
mk wake-loop 15 0 60 50 "$LIVE"
reap HB_SILENT_FLOOR_S=abc >/dev/null
[ "$(lines)" = 0 ] && ok || bad "W1b HB_SILENT_FLOOR_S=abc must read as 120: $(cat "$ALERTS")"

# --- W2: past the floor it pages once, in minutes ---------------------------------
reset
mk wake-loop 15 0 200 121 "$LIVE"
reap >/dev/null
[ "$(lines)" = 1 ] && ok || bad "W2 121s past the tick must page exactly once: $(cat "$ALERTS")"
grep -q 'wake-loop silent for 2m' "$ALERTS" && ok || bad "W2 a 121s age reads 'silent for 2m': $(cat "$ALERTS")"

# --- W3: floor 0 is today's arithmetic, and a sub-minute age reads in seconds -----
reset
mk wake-loop 15 0 60 50 "$LIVE"
reap HB_SILENT_FLOOR_S=0 >/dev/null
[ "$(lines)" = 1 ] && ok || bad "W3 HB_SILENT_FLOOR_S=0 at 50s must page once: $(cat "$ALERTS")"
grep -q 'wake-loop silent for 50s' "$ALERTS" && ok || bad "W3 a 50s age reads 'silent for 50s': $(cat "$ALERTS")"
grep -q '0m' "$ALERTS" && bad "W3 no '0m' in the page: $(cat "$ALERTS")" || ok

# --- W7: the reaper's env/global.env read reaches the lib --------------------------
reset
mk wake-loop 15 0 60 50 "$LIVE"
printf 'HB_SILENT_FLOOR_S=0\n' > "$H/env/global.env"
reap >/dev/null
[ "$(lines)" = 1 ] && ok || bad "W7 env/global.env HB_SILENT_FLOOR_S=0 must reach hb_state: $(cat "$ALERTS")"
grep -q 'wake-loop silent for 50s' "$ALERTS" && ok || bad "W7 page reads 'silent for 50s': $(cat "$ALERTS")"

# --- W4: nothing this suite produced ever said "silent for 0m" ---------------------
reset
n=$(grep -c 'silent for 0m' "$ALL"); n=${n:-0}
[ "$n" = 0 ] && ok || bad "W4 $n page(s) read 'silent for 0m': $(grep 'silent for 0m' "$ALL")"
grep -q 'orchestrator/heartbeat-reaper' "$ALL" && ok || bad "W4 is vacuous: no page was produced at all"

# --- W5: hb_age_text ---------------------------------------------------------------
for c in '0 0s' '59 59s' '60 1m' '2400 40m' '-1 0s' 'x 0s' ' 0s'; do
  in=${c% *}; want=${c##* }
  got=$(hb_age_text "$in")
  [ "$got" = "$want" ] && ok || bad "W5 hb_age_text '$in' printed '$got', want '$want'"
done

# --- W6: both knobs registered and settable ---------------------------------------
REGF="$DIR/catalog/lanes.d/heartbeat-reaper.json"
jq -e '[.knobs[]|select(.env=="HB_SILENT_FLOOR_S" and .type=="int" and .default==120
         and .unit=="seconds" and .zero_means=="off" and .settable!=false)]|length==1' "$REGF" >/dev/null \
  && ok || bad "W6 HB_SILENT_FLOOR_S is not registered int/120/seconds/off/settable in $REGF"
jq -e '[.knobs[]|select(.env=="HB_STALE_MULT" and .type=="int" and .default==3 and .settable!=false)]|length==1' "$REGF" >/dev/null \
  && ok || bad "W6 HB_STALE_MULT is not registered int/3/settable in $REGF"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --check >/dev/null 2>&1 \
  && ok || bad "W6 bin/lanes-build.sh --check failed"

echo "heartbeat-silence-floor (BH-4717): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
