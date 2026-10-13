#!/bin/bash
# BH-5781: every overload error on 2026-10-09 landed at minute :00/:15/:30/:45,
# the quarter-hour cron burst. lane_gate_or_exit now waits a stable per-box
# offset (cksum of the box name mod spread+1, default spread 120 s) BEFORE its
# first D1 read, but only at a quarter-hour minute and only for a lane whose
# registry cadence is a minute number, a minute list, or */N with N >= 5.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$T/h/state" "$T/h/logs"
REG="$T/lanes.json"
cat > "$REG" <<'JSON'
{"lanes":[
 {"id":"q15","cadence":"*/15 * * * *"},
 {"id":"q5","cadence":"*/5 * * * *"},
 {"id":"q2","cadence":"*/2 * * * *"},
 {"id":"every","cadence":"* * * * *"},
 {"id":"hourly","cadence":"0 * * * *"},
 {"id":"list","cadence":"0,30 * * * *"},
 {"id":"manual","cadence":"on demand (via an operator at the shell; no cron line)"}
]}
JSON
Q=1800000000              # minute 0 (1800000000 % 3600 == 0)
M7=$((Q + 7*60))
# off <lane> [box] [now] — prints lane_start_offset's answer for that box/time.
off() {
  ( HARNESS="$T/h" LANE_REGISTRY="$REG" JOBS_BOX="${2:-box-a}" LANE_GATE_NOW="${3:-$Q}" \
    bash -c '. "$1/bin/lib/lane-gate.sh"; lane_start_offset "$2"' bash "$DIR" "$1" 2>/dev/null )
}
want() { # want <box> <spread> — the stable offset the box must get
  echo $(( $(printf '%s' "$1" | cksum | cut -d' ' -f1) % ($2 + 1) ))
}
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1 -> $3"; else echo "FAIL $1 -> $3 (want $2)"; fail=1; fi; }
unset LANE_START_SPREAD_S  # scratch.sh exports 0 for every other suite

# L0: no settings row and no env (a scratch tree, a box before its first
# settings read): the default is 0, never a sleep. A default of 120 made
# tests/lookback-live.bh-3691-test.sh (env -i, so no LANE_START_SPREAD_S) sleep
# at every :15 and time out in the merge queue (run 38058329244).
check "L0 no row, no env, */15 at :15 -> 0" 0 "$(off q15 box-a $((Q + 15*60)))"
check "L0 no row, no env, 0 * * * * at :00 -> 0" 0 "$(off hourly box-a)"
# TEST-CHANGE (BH-5781 fix): L1-L3 ran on the old code default of 120; that
# value is now the seeded settings row (schema.d/0017-bh-5781-lane-start-spread.sql),
# so they set it explicitly. Every assertion is the same.
export LANE_START_SPREAD_S=120

# L1: stable per box, different across boxes, always 0..120.
a1=$(off q15 box-a); a2=$(off q15 box-a)
check "L1 same box twice" "$a1" "$a2"
seen=""; inrange=1
for b in box-a box-b orgo-hub pool-cromford-1 project-3-box; do
  o=$(off q15 "$b"); seen="$seen $o"
  case "$o" in ''|*[!0-9]*) inrange=0 ;; *) [ "$o" -le 120 ] || inrange=0 ;; esac
done
check "L1 offsets in 0..120 ($seen )" 1 "$inrange"
distinct=$(printf '%s\n' $seen | sort -u | wc -l)
[ "$distinct" -gt 1 ] && echo "ok   L1 offsets differ across boxes" || { echo "FAIL L1 every box got the same offset:$seen"; fail=1; }
# L2: */15 lane at each quarter-hour minute = cksum mod 121; minute 7 = 0.
for m in 0 15 30 45; do
  check "L2 */15 at :$m" "$(want box-a 120)" "$(off q15 box-a $((Q + m*60)))"
done
check "L2 */15 at :07" 0 "$(off q15 box-a $M7)"
check "L2 */15 at :13" 0 "$(off q15 box-a $((Q + 13*60)))"
check "L2 */15 at :58" 0 "$(off q15 box-a $((Q + 58*60)))"
check "L2 0 * * * * at :00" "$(want box-a 120)" "$(off hourly box-a)"
check "L2 0,30 at :30" "$(want box-a 120)" "$(off list box-a $((Q + 30*60)))"
# L3: lanes that would collide with their next tick, or have no cron line.
check "L3 */2 at :00" 0 "$(off q2)"
check "L3 * * * * * at :15" 0 "$(off every box-a $((Q + 15*60)))"
check "L3 on demand" 0 "$(off manual)"
check "L3 unknown lane" 0 "$(off nosuch)"
check "L3 missing registry" 0 "$( HARNESS="$T/h" LANE_REGISTRY="$T/none.json" JOBS_BOX=box-a LANE_GATE_NOW=$Q \
  bash -c '. "$1/bin/lib/lane-gate.sh"; lane_start_offset q15' bash "$DIR" 2>/dev/null)"
# L4: a */5 lane is capped at half its period (150 s): with a 600 s spread a
# box whose raw offset is above 150 gets 150.
big=""; for b in box-a box-b box-c box-d box-e box-f; do [ "$(want "$b" 600)" -gt 150 ] && { big=$b; break; }; done
check "L4 */5 capped at 150 (box $big, raw $(want "$big" 600))" 150 "$(LANE_START_SPREAD_S=600 off q5 "$big")"
check "L4 */15 not capped at 150 (raw $(want "$big" 600))" "$(want "$big" 600)" "$(LANE_START_SPREAD_S=600 off q15 "$big")"
# The spread: settings row (from the cache FILE, fresh or stale) > env > 120.
C="$T/h/state/settings-cache.json"
printf '{"fetched_at":1,"values":{"lane_start_spread_s":"0"},"seeded":{}}' > "$C"
check "L4 row lane_start_spread_s=0 (stale cache file) -> off" 0 "$(LANE_START_SPREAD_S=90 off q15 box-a)"
printf '{"fetched_at":1,"values":{"lane_start_spread_s":"30"},"seeded":{}}' > "$C"
check "L4 row 30 beats env 90" "$(want box-a 30)" "$(LANE_START_SPREAD_S=90 off q15 box-a)"
printf '{"fetched_at":1,"values":{"lane_start_spread_s":"abc"},"seeded":{}}' > "$C"
check "L4 row abc -> env 90" "$(want box-a 90)" "$(LANE_START_SPREAD_S=90 off q15 box-a)"
# TEST-CHANGE (BH-5781 fix): junk in both places falls to the code default,
# now 0 (was 120); the row seeds 120.
check "L4 row abc, env abc -> the default 0" 0 "$(LANE_START_SPREAD_S=abc off q15 box-a)"
check "L4 env 601 is out of range -> the default 0" 0 "$(LANE_START_SPREAD_S=601 off q15 box-a)"
rm -f "$C"
check "L4 env 0 -> off" 0 "$(LANE_START_SPREAD_S=0 off q15 box-a)"
# L6: with JOBS_BOX unset (the gate runs before the jobs client is sourced) the
# box is the fleet name in state/box-name, never the shared Orgo hostname.
printf 'box-b\n' > "$T/h/state/box-name"
check "L6 state/box-name names the box" "$(want box-b 120)" \
  "$( env -u JOBS_BOX -u BOX_NAME HARNESS="$T/h" LANE_REGISTRY="$REG" LANE_GATE_NOW=$Q \
      bash -c '. "$1/bin/lib/lane-gate.sh"; lane_start_offset q15' bash "$DIR" 2>/dev/null)"
rm -f "$T/h/state/box-name"
# L5: the gate itself sleeps the offset first, through the real entry point.
# `sleep` is shadowed by a function that records its argument; JOBS_URL is
# empty (scratch.sh), so every worker read fails open with no network.
gate() { # gate <lane> <now> -> what the gate slept, "none" when nothing
  ( HARNESS="$T/h" LANE_REGISTRY="$REG" JOBS_BOX=box-a LANE_GATE_NOW="$2" SLEPT="$T/slept" \
    bash -c '. "$1/bin/lib/lane-gate.sh"; sleep() { printf "%s " "$1" >> "$SLEPT"; }; lane_gate_or_exit "$2"; echo RAN >> "$SLEPT"' \
      bash "$DIR" "$1" >/dev/null 2>&1 )
  local s; s=$(cat "$T/slept" 2>/dev/null); rm -f "$T/slept"; echo "${s:-none}"
}
check "L5 gate at :15 sleeps the offset, then runs" "$(want box-a 120) RAN" "$(gate q15 $((Q + 15*60)))"
check "L5 gate at :07 does not sleep" "RAN" "$(gate q15 $M7)"
grep -q "q15.*start offset $(want box-a 120)s.*box-a" "$T/h/logs/lane-gate.log" 2>/dev/null \
  && echo "ok   L5 lane-gate.log names the offset and the box" \
  || { echo "FAIL L5 no offset line in lane-gate.log: $(cat "$T/h/logs/lane-gate.log" 2>/dev/null)"; fail=1; }
t0=$(date +%s)
( HARNESS="$T/h" LANE_REGISTRY="$REG" JOBS_BOX=box-a LANE_GATE_NOW=$Q LANE_START_SPREAD_S=0 \
  bash -c '. "$1/bin/lib/lane-gate.sh"; lane_gate_or_exit q15' bash "$DIR" >/dev/null 2>&1 )
el=$(( $(date +%s) - t0 ))
[ "$el" -lt 2 ] && echo "ok   L5 spread 0: gate returned in ${el}s" || { echo "FAIL L5 spread 0: gate took ${el}s"; fail=1; }
exit $fail
