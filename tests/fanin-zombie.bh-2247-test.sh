#!/bin/bash
# tests/fanin-zombie.bh-2247-test.sh — a zombie pid is a dead run (BH-2247).
#
# fanin_begin (bin/lib/fanin.sh) reports and deletes the ledger of a dead run
# of the same lane+scope. `kill -0` succeeds on a zombie, and a SIGKILLed
# conductor tick leaves its ledger pid as an orphan zombie until PID 1 reaps it
# (on /fly/init that took 0.35-0.7 s), so the next tick skipped the dead ledger
# as a live parallel run: tests/fanin.bh-186-test.sh C3, intermittently.
#
#   Z1  zombie ledger with a missing id -> one "(run died before fan-in)"
#       alert naming it, and the ledger is deleted
#   Z2  fully accounted zombie ledger -> deleted, no alert
#   Z3  live-pid ledger -> kept, no alert
#   Z4  stopped-pid ledger (state T) -> kept, no alert: stopped is not dead
#   Z5  no /proc (FANIN_PROC points nowhere) -> the kill -0 answer alone, so a
#       zombie reads as live, as before
#
# Run from anywhere: tests/fanin-zombie.bh-2247-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
[ -d /proc/self ] || { echo "no /proc — skipping"; exit 0; }

F="$T/f"; mkdir -p "$F/bin" "$F/logs" "$F/state/fanin/lane" || exit 1
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$F" > "$F/bin/lane-alert.sh"
chmod +x "$F/bin/lane-alert.sh"
FLOG="$F/logs/lane.log"
LD="$F/state/fanin/lane"
lib() { ( export HARNESS="$F"; . "$DIR/bin/lib/fanin.sh" 2>/dev/null || exit 9; "$@" ); }
reset_f() { scratch_rm "$LD"; mkdir -p "$LD"; : > "$F/alerts.txt"; : > "$FLOG"; }
pstate() { local s; s=$(cat "/proc/$1/stat" 2>/dev/null) || return 0; s=${s##*) }; echo "${s%% *}"; }

HOLDER=""; LIVE=""; STOPPED=""
cleanup() {
  for p in $HOLDER $LIVE $STOPPED; do kill -CONT "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
  wait 2>/dev/null
}
trap cleanup EXIT

# A real zombie: the child `sleep 0` exits, and its parent exec's into a
# `sleep` that never reaps it.
bash -c 'sleep 0 & echo $! > "$1"; exec sleep 30' _ "$T/zpid" &
HOLDER=$!
Z=""
for _ in $(seq 100); do
  Z=$(cat "$T/zpid" 2>/dev/null)
  [ -n "$Z" ] && [ "$(pstate "$Z")" = Z ] && break
  sleep 0.05
done
if [ -z "$Z" ] || [ "$(pstate "$Z")" != Z ]; then
  echo "FAIL: setup — no zombie after 5s (pid ${Z:-none}, state $(pstate "${Z:-0}"))"; exit 1
fi
sleep 30 & LIVE=$!
sleep 30 & STOPPED=$!; kill -STOP "$STOPPED"
for _ in $(seq 100); do [ "$(pstate "$STOPPED")" = T ] && break; sleep 0.05; done
[ "$(pstate "$STOPPED")" = T ] || { echo "FAIL: setup — pid $STOPPED never stopped"; exit 1; }

begin() { fanin_begin lane s "$FLOG"; }

# Z1
reset_f
printf 'E a\nE b\nA a x\n' > "$LD/s.$Z"
lib begin
[ "$(grep -c . "$F/alerts.txt")" = 1 ] && grep -qx -- '--severity warn lane ALERT FANIN lane s: enumerated 2 accounted 1 missing: b (run died before fan-in)' "$F/alerts.txt" \
  && ok || bad "Z1: a zombie ($Z) ledger is a dead run and alerts once (alerts: $(cat "$F/alerts.txt"))"
[ ! -e "$LD/s.$Z" ] && ok || bad "Z1: the zombie's ledger is deleted"

# Z2
reset_f
printf 'E a\nA a x\n' > "$LD/s.$Z"
lib begin
[ ! -s "$F/alerts.txt" ] && ok || bad "Z2: a fully accounted zombie ledger sends no alert: $(cat "$F/alerts.txt")"
[ ! -e "$LD/s.$Z" ] && ok || bad "Z2: a fully accounted zombie ledger is deleted"

# Z3
reset_f
printf 'E a\nE b\n' > "$LD/s.$LIVE"
lib begin
[ ! -s "$F/alerts.txt" ] && ok || bad "Z3: a live run's ledger sends no alert: $(cat "$F/alerts.txt")"
[ -e "$LD/s.$LIVE" ] && ok || bad "Z3: a live run's ledger is left alone"

# Z4
reset_f
printf 'E a\nE b\n' > "$LD/s.$STOPPED"
lib begin
[ ! -s "$F/alerts.txt" ] && ok || bad "Z4: a stopped run's ledger sends no alert: $(cat "$F/alerts.txt")"
[ -e "$LD/s.$STOPPED" ] && ok || bad "Z4: a stopped run's ledger is left alone"

# Z5
reset_f
printf 'E a\nE b\n' > "$LD/s.$Z"
FANIN_PROC=/nonexistent lib begin
[ ! -s "$F/alerts.txt" ] && ok || bad "Z5: with no /proc a zombie falls back to kill -0 (live): $(cat "$F/alerts.txt")"
[ -e "$LD/s.$Z" ] && ok || bad "Z5: with no /proc the zombie's ledger is kept"

echo "fanin-zombie.bh-2247: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
