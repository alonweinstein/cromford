#!/bin/bash
# tests/wake-lanes-armed-watchdog.bh-4060-test.sh — the armed-line watchdog
# (BH-4060): a `wake-lanes-<class>` flag is on but bin/wake-loop.sh has not
# logged `wake classes armed:` for WAKE_ARMED_WATCH_S -> one page keyed
# wakearmed:hub; a fresh line, no flags, a kill switch or a stopped loop -> none.
# Run from anywhere: tests/wake-lanes-armed-watchdog.bh-4060-test.sh  (exit 0 = pass)
#
# Driven two ways: bin/lib/wake-armed-watch.sh's wake_armed_watch_eval directly,
# and the `# >>> wake classes armed (BH-4060)` block extracted verbatim from
# bin/pipeline-health.sh with a stub alert and a stub flag_active. The clock is
# pinned (NOW below); every stamp is formatted from it.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

NOW=1790000000
STAMPAT() { date -u -d "@$1" '+%Y-%m-%d %H:%M:%SZ'; }  # the format bin/wake-loop.sh's say() writes
R="$T/h"
mkdir -p "$R/bin/lib" "$R/flags" "$R/logs" "$R/state"
cp "$DIR/bin/lib/wake-armed-watch.sh" "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$R/bin/lib/" 2>/dev/null
for c in deploy flaky pr-ci pr-closed push split-chain; do : > "$R/bin/lib/wake-class-$c.sh"; done
LOGF="$R/logs/wake-loop.log"

# flag_active stub: a flag is on when its file exists, which is what the real
# one answers from after reconciling the row.
FA_DEF='flag_active() { [ -f "$HARNESS/flags/$1" ]; }'
reset() { rm -f "$R"/flags/*; : > "$LOGF"; }
armed_line() { echo "$(STAMPAT "$((NOW - $1))") wake classes armed: ${2:-pr-closed}" >> "$LOGF"; }

ev() { # ev <window> [nofa] -> stdout of wake_armed_watch_eval; rc in $RC
  OUT=$( export HARNESS="$R"
    # shellcheck source=bin/lib/wake-armed-watch.sh
    . "$R/bin/lib/wake-armed-watch.sh" || exit 9
    [ "${2:-}" = nofa ] || eval "$FA_DEF"
    wake_armed_watch_eval "$1" "$NOW" ); RC=$?
}

echo "--- lib"
# 1
reset; touch "$R/flags/wake-lanes-pr-closed"; ev 3600
[ "$OUT" = "FIRE never pr-closed" ] && ok || bad "1 flag, no armed line -> FIRE never pr-closed (got '$OUT' rc $RC)"
# 2
armed_line 300; ev 3600
[ "$OUT" = "OK 300 pr-closed" ] && ok || bad "2 flag, line 5m old -> OK 300 pr-closed (got '$OUT')"
# 3
reset; touch "$R/flags/wake-lanes-pr-closed" "$R/flags/wake-lanes-push"; armed_line 3660 "pr-closed push"; ev 3600
[ "$OUT" = "FIRE 3660 pr-closed,push" ] && ok || bad "3 flag, line 61m old -> FIRE 3660 pr-closed,push (got '$OUT')"
reset; touch "$R/flags/wake-lanes-pr-closed"; armed_line 3540; ev 3600
[ "$OUT" = "OK 3540 pr-closed" ] && ok || bad "3b line 59m old -> OK (got '$OUT')"
reset; touch "$R/flags/wake-lanes-pr-closed"; armed_line 3600; ev 3600
[ "${OUT%% *}" = FIRE ] && ok || bad "3c a line exactly one window old fires (got '$OUT')"
reset; touch "$R/flags/wake-lanes-pr-closed"; armed_line 9000; armed_line 60; ev 3600
[ "$OUT" = "OK 60 pr-closed" ] && ok || bad "3d the NEWEST armed line is the one judged (got '$OUT')"
# 4
reset; ev 3600
[ "$OUT" = NONE ] && ok || bad "4 no flags -> NONE (got '$OUT')"
touch "$R/flags/wake-lanes-off"; ev 3600
[ "$OUT" = "SKIP killswitch" ] && ok || bad "4b a wake-lanes-off FILE alone is not a class flag -> SKIP killswitch, never FIRE (got '$OUT')"
reset; touch "$R/flags/wake-lanes-bogus"; ev 3600
[ "$OUT" = NONE ] && ok || bad "4c a flag with no class file is not watched (got '$OUT')"
# 5
reset; touch "$R/flags/wake-lanes-pr-closed" "$R/flags/wake-lanes-off"; ev 3600
[ "$OUT" = "SKIP killswitch" ] && ok || bad "5 kill switch + class flag -> SKIP killswitch (got '$OUT')"
# 6
reset; touch "$R/flags/wake-lanes-pr-closed" "$R/flags/wake-loop-off"; ev 3600
[ "$OUT" = "SKIP loop-off" ] && ok || bad "6 wake-loop-off -> SKIP loop-off (got '$OUT')"
reset; touch "$R/flags/wake-lanes-pr-closed" "$R/flags/lane-off-wake-loop"; ev 3600
[ "$OUT" = "SKIP loop-off" ] && ok || bad "6b lane-off-wake-loop -> SKIP loop-off (got '$OUT')"
reset; touch "$R/flags/wake-lanes-pr-closed" "$R/flags/all-off"; ev 3600
[ "$OUT" = "SKIP loop-off" ] && ok || bad "6c all-off stops the loop's lane gate -> SKIP loop-off (got '$OUT')"
# 7
reset; touch "$R/flags/wake-lanes-pr-closed"; ev 0
[ "$OUT" = "SKIP off" ] && ok || bad "7 window 0 -> SKIP off (got '$OUT')"
ev abc
[ "$RC" != 0 ] && [ -z "$OUT" ] && ok || bad "7b a non-number window -> rc 1, nothing printed (got '$OUT' rc $RC)"
# 8
ev 3600 nofa
[ "$OUT" = "SKIP unknown" ] && ok || bad "8 flag_active undefined -> SKIP unknown (got '$OUT')"
# 9
reset; touch "$R/flags/wake-lanes-pr-closed"; echo "2026-13-45 99:99:99Z wake classes armed: pr-closed" >> "$LOGF"; ev 3600
[ "$OUT" = "FIRE never pr-closed" ] && ok || bad "9 unparseable stamp -> FIRE never, never fresh (got '$OUT')"
echo "garbage wake classes armed: pr-closed" >> "$LOGF"; ev 3600
[ "$OUT" = "FIRE never pr-closed" ] && ok || bad "9b a stampless armed line -> FIRE never (got '$OUT')"
# 10
reset; touch "$R/flags/wake-lanes-pr-closed"
echo "$(STAMPAT "$((NOW - 60))") grep says: x.log: wake classes armed: pr-closed" >> "$LOGF"; ev 3600
[ "$OUT" = "FIRE never pr-closed" ] && ok || bad "10 a line quoting the phrase mid-text is not the armed line (got '$OUT')"
rm -f "$LOGF"; ev 3600
[ "$OUT" = "FIRE never pr-closed" ] && ok || bad "10b a missing log -> FIRE never (got '$OUT')"
# 11
OUT=$( unset HARNESS H
  # shellcheck source=bin/lib/wake-armed-watch.sh
  . "$R/bin/lib/wake-armed-watch.sh" || exit 9
  flag_active() { echo called >> "$T/fa-called"; return 0; }
  wake_armed_watch_eval 3600 "$NOW" ); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && [ ! -e "$T/fa-called" ] && ok \
  || bad "11 empty HARNESS/H -> rc 1, nothing printed, no flag read (got '$OUT' rc $RC)"
( . "$R/bin/lib/wake-armed-watch.sh" ) >"$T/src.out" 2>&1
[ -s "$T/src.out" ] && bad "sourcing the lib must print nothing ($(cat "$T/src.out"))" || ok

echo "--- block (extracted verbatim from bin/pipeline-health.sh)"
extract() { awk '/^# >>> wake classes armed \(BH-4060\)/{f=1;next} /^# <<< wake classes armed/{exit} f' "$1"; }
extract "$DIR/bin/pipeline-health.sh" > "$T/blk.sh"
[ -s "$T/blk.sh" ] && ok || bad "could not extract the wake classes armed block from bin/pipeline-health.sh"

drive() { # drive [VAR=VAL ...] -> $T/alerts.txt, $T/fired; rc in $RC. Default window 3600.
  : > "$R/logs/pipeline-health.log"; : > "$T/alerts.txt"; : > "$T/fired"
  ( export T R NOW FA_DEF WAKE_ARMED_WATCH_S=3600 NOFA="" "$@"
    bash -c '
      set -uo pipefail
      H="$R"; FIRED="$T/fired"; ACTIVE="$R/state/active.txt"
      STAMP() { echo TS; }
      [ -n "$NOFA" ] || eval "$FA_DEF"
      alert() { echo "$2" >> "$FIRED"; printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/alerts.txt"; }
      . "$0"' "$T/blk.sh" 2>"$T/err.txt" )
  RC=$?
}
NCALLS() { grep -c . "$T/alerts.txt"; }
: > "$R/state/active.txt"
[ -f "$R/bin/lib/wake-armed-watch.sh" ] || cp "$DIR/bin/lib/wake-armed-watch.sh" "$R/bin/lib/"

# 12
reset; touch "$R/flags/wake-lanes-pr-closed"; drive
[ "$(NCALLS)" = 1 ] && grep -q '^3600|wakearmed:hub|.*pr-closed.*wake classes armed:' "$T/alerts.txt" && ok \
  || bad "12 flag + no line -> exactly one alert, ttl 3600, key wakearmed:hub (alerts: $(cat "$T/alerts.txt"); err: $(cat "$T/err.txt"))"
[ "$RC" = 0 ] && ok || bad "12 block rc must be 0 (rc $RC)"
# 13
armed_line 300; drive
[ "$(NCALLS)" = 0 ] && ok || bad "13 flag + 5m line -> no alert (alerts: $(cat "$T/alerts.txt"))"
grep -q wakearmed "$T/fired" && bad "13 a fresh line must leave nothing in FIRED, so a standing key retracts" || ok
armed_line 3540; drive
[ "$(NCALLS)" = 0 ] && ok || bad "13b flag + 59m line -> no alert"
reset; touch "$R/flags/wake-lanes-pr-closed"; armed_line 3660; drive
[ "$(NCALLS)" = 1 ] && grep -q 'for 3660s' "$T/alerts.txt" && ok || bad "13c flag + 61m line -> one alert naming the age (alerts: $(cat "$T/alerts.txt"))"
# 14
reset; drive
[ "$(NCALLS)" = 0 ] && ok || bad "14 no flags -> no alert"
touch "$R/flags/wake-lanes-pr-closed" "$R/flags/wake-lanes-off"; drive
[ "$(NCALLS)" = 0 ] && ok || bad "14b kill switch -> no alert"
reset; touch "$R/flags/wake-lanes-pr-closed" "$R/flags/wake-loop-off"; drive
[ "$(NCALLS)" = 0 ] && ok || bad "14c wake-loop-off -> no alert"
reset; touch "$R/flags/wake-lanes-pr-closed"; drive WAKE_ARMED_WATCH_S=0
[ "$(NCALLS)" = 0 ] && ok || bad "14d window 0 -> no alert"
drive WAKE_ARMED_WATCH_S=
[ "$(NCALLS)" = 0 ] && grep -q "WAKE_ARMED_WATCH_S='' is not a whole number" "$R/logs/pipeline-health.log" && ok \
  || bad "14e an unset window -> no alert and one log line (log: $(cat "$R/logs/pipeline-health.log"))"
# 15
printf 'wakearmed:hub\nstalepr:x#1\n' > "$R/state/active.txt"
drive NOFA=1
[ "$(NCALLS)" = 0 ] && grep -qx 'wakearmed:hub' "$T/fired" && ok \
  || bad "15 flag_active missing -> the standing wakearmed:hub is carried into FIRED (fired: $(cat "$T/fired"))"
grep -q stalepr "$T/fired" && bad "15 only wakearmed keys are carried" || ok
mv "$R/bin/lib/wake-armed-watch.sh" "$T/lib.bak"; drive
grep -qx 'wakearmed:hub' "$T/fired" && [ "$(NCALLS)" = 0 ] && ok || bad "15b no lib -> the standing key is carried (fired: $(cat "$T/fired"))"
mv "$T/lib.bak" "$R/bin/lib/wake-armed-watch.sh"
reset; drive
grep -q wakearmed "$T/fired" && bad "15c a known NONE must not carry the key (so it retracts)" || ok
: > "$R/state/active.txt"
# 16
reset; touch "$R/flags/wake-lanes-pr-closed"; drive; K1=$(cut -d'|' -f2 "$T/alerts.txt")
touch "$R/flags/wake-lanes-push" "$R/flags/wake-lanes-deploy"; armed_line 7200; drive; K2=$(cut -d'|' -f2 "$T/alerts.txt")
[ "$K1" = wakearmed:hub ] && [ "$K2" = wakearmed:hub ] && grep -q 'deploy,pr-closed,push' "$T/alerts.txt" && ok \
  || bad "16 two FIRE ticks with different classes and ages -> the same key (k1=$K1 k2=$K2; $(cat "$T/alerts.txt"))"
# 17
sed '/^# >>> wake classes armed (BH-4060)/,/^# <<< wake classes armed/d' "$DIR/bin/pipeline-health.sh" > "$T/ph-noblock.sh"
[ -z "$(extract "$T/ph-noblock.sh")" ] && ok || bad "17 a copy with the block deleted must extract nothing"
[ -n "$(extract "$DIR/bin/pipeline-health.sh")" ] && ok || bad "17 the real script must carry the block"
# 18
RETRACT_NS=""
eval "$(grep '^RETRACT_NS=' "$DIR/bin/pipeline-health.sh")"
[ -n "$RETRACT_NS" ] && grep -qE "^($RETRACT_NS):" <<<"wakearmed:hub" && ok || bad "18 RETRACT_NS must match wakearmed:hub (RETRACT_NS=$RETRACT_NS)"

echo "wake-lanes-armed-watchdog: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
