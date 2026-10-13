#!/bin/bash
# tests/lane-down-canary.bh-1674-test.sh — BH-1688 (BH-1674.2): the 6h runner
# canary in bin/claude-auth-check.sh marks, clears and announces lane-down
# state through bin/lib/lane-down.sh.
#   C1  a down lane that answers again is cleared the same pass: today's flag,
#       the record and the exact STATE line go (the midnight-lag bug), one
#       "back on" line, one RECOVERED line, lanedown-<ID> resolved. The bare
#       `hub` STATE line survives. C1b: a never-down healthy lane is silent.
#   C2  a lane already in STATE that fails again gets its record and today's
#       flag updated and NO ALERTS line and NO beat (no daily re-nag). A new
#       failing lane gets the day-1 LANE DOWN line and one beat whose akey is
#       lanedown:<ID>, with no date.
#   M1  the per-day akey restored in a copy of the script turns C2's akey
#       check red.
#   C3  lib absent: the inline behaviour (LANE DOWN (new)); since V1 alert hygiene
#       its akey is the condition too (no date: a date mints a console row a day).
# Drives the real script end to end (HARNESS=$T), hour forced to 06 by a date
# shim. Run from anywhere: tests/lane-down-canary.bh-1674-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
REAL_DATE=$(command -v date)

# build_tree <root> [nolib]: a scratch harness with one box (hub) and stubs.
build_tree() {
  local R=$1
  scratch_rm "$R"; mkdir -p "$R/bin/lib" "$R/fakebin" "$R/state" "$R/flags" "$R/logs" "$R/locks"
  [ "${2:-}" = nolib ] || cp "$DIR/bin/lib/lane-down.sh" "$R/bin/lib/"
  cp "$DIR/bin/claude-auth-check.sh" "$R/bin/"
  cp "$DIR/bin/alert-line.sh" "$R/bin/"
  echo 'lane_role_model() { echo m-test; }' > "$R/bin/lib/lane-model.sh"
  printf '#!/bin/bash\nexit 0\n' > "$R/bin/fleet-conf.sh"
  printf '#!/bin/bash\nexit 0\n' > "$R/bin/box-for.sh"
  printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "$(dirname "$0")/../beats.txt"\n' > "$R/bin/beat.sh"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$(dirname "$0")/../lane-alert-calls.txt"\n' > "$R/bin/lane-alert.sh"
  cat > "$R/bin/lane-probe.sh" <<'SH'
#!/bin/bash
R=$(dirname "$0")/..
echo "hub $1" >> "$R/probe-calls.txt"
if [ -f "$R/probe-$1" ]; then cat "$R/probe-$1"; else echo ok; fi
SH
  cat > "$R/fakebin/date" <<SH
#!/bin/bash
for a in "\$@"; do [ "\$a" = "+%H" ] && { echo 06; exit 0; }; done
exec $REAL_DATE "\$@"
SH
  printf '#!/bin/bash\necho "Not logged in · Please run /login"\n' > "$R/fakebin/claude"
  printf '#!/bin/bash\nexit 1\n' > "$R/fakebin/ssh"
  printf '#!/bin/bash\n# BH-2560: the probe now calls agent-call.sh; forward it to the stub claude on PATH\nclaude -p "$6" --model "$3" >"$5" 2>"$5.err"; exit $?\n' > "$R/bin/agent-call.sh"; chmod +x "$R/bin/agent-call.sh"
  chmod +x "$R"/bin/*.sh "$R"/fakebin/*
  # The two claude lanes are already down, so both loops stay silent.
  printf 'hub\nproject-1-lane\n' > "$R/state/claude-auth-down.txt"
  : > "$R/logs/ALERTS.log"; : > "$R/beats.txt"
}
run_check() { # run_check <root> -> rc; the production entry point
  HARNESS="$1" PATH="$1/fakebin:$PATH" bash "$1/bin/claude-auth-check.sh" >"$1/out.txt" 2>&1
}
TODAY=$("$REAL_DATE" -u +%Y%m%d)
YDAY=$("$REAL_DATE" -u -d yesterday +%Y%m%d)

# ---- C1: hub-grok down with today's flag, probe answers ok --------------------
R="$T/c1"; build_tree "$R"
echo hub-grok >> "$R/state/claude-auth-down.txt"
touch "$R/flags/lanedown-hub-grok-$TODAY"
mkdir -p "$R/state/lane-down"
printf 'box=hub\nlane=grok\naddr=local\nsince=%s\nlast_probe=1\nlast_error=x\nstanding_at=\n' \
  "$(( $("$REAL_DATE" -u +%s) - 7200 ))" > "$R/state/lane-down/hub-grok"
run_check "$R"; rc=$?
[ "$rc" = 0 ] && ok || bad "C1 rc=$rc: $(cat "$R/out.txt")"
grep -q '^hub grok$' "$R/probe-calls.txt" 2>/dev/null && ok || bad "C1 lane-probe stub not driven: $(cat "$R/probe-calls.txt" 2>/dev/null)"
[ ! -e "$R/flags/lanedown-hub-grok-$TODAY" ] && ok || bad "C1 today's flag survived recovery (midnight lag)"
[ ! -e "$R/state/lane-down/hub-grok" ] && ok || bad "C1 record survived recovery"
[ "$(grep -c 'lane grok back on hub after' "$R/logs/lane-reprobe.log" 2>/dev/null)" = 1 ] \
  && ok || bad "C1 expected one back-on line: $(cat "$R/logs/lane-reprobe.log" 2>/dev/null)"
[ "$(grep -c '\[auth\] hub-grok RECOVERED' "$R/logs/ALERTS.log")" = 1 ] && ok || bad "C1 RECOVERED line: $(cat "$R/logs/ALERTS.log")"
grep -qxF hub-grok "$R/state/claude-auth-down.txt" && bad "C1 STATE line survived" || ok
grep -qxF hub "$R/state/claude-auth-down.txt" && ok || bad "C1 bare hub STATE line lost"
grep -qxF project-1-lane "$R/state/claude-auth-down.txt" && ok || bad "C1 project-1-lane STATE line lost"
grep -q -- '--resolve --id lanedown-hub-grok ' "$R/lane-alert-calls.txt" 2>/dev/null && ok || bad "C1 lanedown-hub-grok not resolved: $(cat "$R/lane-alert-calls.txt" 2>/dev/null)"
# C1b: hub-codex was never down and answered ok: nothing about it anywhere
grep -q 'hub-codex' "$R/logs/ALERTS.log" && bad "C1b healthy never-down lane logged: $(cat "$R/logs/ALERTS.log")" || ok
grep -q 'codex' "$R/logs/lane-reprobe.log" 2>/dev/null && bad "C1b healthy lane got a back-on line" || ok
[ -s "$R/beats.txt" ] && bad "C1 unexpected beat: $(cat "$R/beats.txt")" || ok

# ---- C2: hub-grok already down (yesterday's flag), hub-fireworks new; both fail
c2_setup() {
  build_tree "$1" "${2:-}"
  echo hub-grok >> "$1/state/claude-auth-down.txt"
  touch "$1/flags/lanedown-hub-grok-$YDAY"
  mkdir -p "$1/state/lane-down"
  printf 'box=hub\nlane=grok\naddr=local\nsince=1\nlast_probe=1\nlast_error=old\nstanding_at=\n' > "$1/state/lane-down/hub-grok"
  echo 'grok 503 upstream' > "$1/probe-grok"
  echo 'fireworks 401 denied' > "$1/probe-fireworks"
}
akey_exact() { # one beat, akey exactly lanedown:hub-fireworks
  [ "$(jq -r 'select(.akey != null) | .akey' "$1/beats.txt" 2>/dev/null | grep -c '^lanedown:hub-fireworks')" = 1 ] \
    && jq -r '.akey' "$1/beats.txt" | grep -qx 'lanedown:hub-fireworks'
}
R="$T/c2"; c2_setup "$R"
B4=$("$REAL_DATE" -u +%s); run_check "$R"; rc=$?; AFT=$("$REAL_DATE" -u +%s)
[ "$rc" = 0 ] && ok || bad "C2 rc=$rc: $(cat "$R/out.txt")"
grep -q 'hub-grok' "$R/logs/ALERTS.log" && bad "C2 already-down lane re-nagged in ALERTS: $(cat "$R/logs/ALERTS.log")" || ok
grep -q 'hub-grok\|grok on hub' "$R/beats.txt" && bad "C2 already-down lane beat: $(cat "$R/beats.txt")" || ok
[ -e "$R/flags/lanedown-hub-grok-$TODAY" ] && ok || bad "C2 today's flag not touched for hub-grok"
LP=$(awk -F= '$1=="last_probe"{print $2}' "$R/state/lane-down/hub-grok" 2>/dev/null)
[ -n "$LP" ] && [ "$LP" -ge "$B4" ] && [ "$LP" -le "$AFT" ] && ok || bad "C2 record last_probe not updated: '$LP' ($B4..$AFT)"
grep -q '^last_error=grok 503 upstream' "$R/state/lane-down/hub-grok" 2>/dev/null && ok || bad "C2 record last_error: $(cat "$R/state/lane-down/hub-grok" 2>/dev/null)"
[ "$(grep -c '\[auth\] hub-fireworks LANE DOWN (new)' "$R/logs/ALERTS.log")" = 1 ] && ok || bad "C2 new lane day-1 line: $(cat "$R/logs/ALERTS.log")"
akey_exact "$R" && ok || bad "C2 new lane beat akey not exactly lanedown:hub-fireworks: $(cat "$R/beats.txt")"
# BH-2363: alert-line.sh also beats kind:"alert"
[ "$(jq -r 'select(.kind=="fleet_alert") | .alertid + " " + .severity' "$R/beats.txt" 2>/dev/null)" = "lanedown-hub-fireworks warn" ] && ok || bad "C2 alertid/severity: $(cat "$R/beats.txt")"
grep -qxF hub-fireworks "$R/state/claude-auth-down.txt" && ok || bad "C2 new lane not in STATE"
[ -e "$R/state/lane-down/hub-fireworks" ] && ok || bad "C2 new lane has no record"
grep -qxF hub "$R/state/claude-auth-down.txt" && ok || bad "C2 bare hub STATE line lost"

# ---- M1: the per-day akey restored -> C2's akey check goes red ---------------
R="$T/m1"; c2_setup "$R"
sed -i 's|akey "lanedown:\$ID"|akey "lanedown:$ID:$(date -u +%Y%m%d)"|' "$R/bin/claude-auth-check.sh"
if grep -qF 'akey "lanedown:$ID:$(date' "$R/bin/claude-auth-check.sh"; then
  run_check "$R"
  akey_exact "$R" && bad "M1 per-day akey mutation stayed green: $(cat "$R/beats.txt")" || ok
else bad "M1 mutation did not apply: no undated akey in the script"; fi

# ---- C3: lib missing -> today's inline behaviour (fail-open) ------------------
R="$T/c3"; c2_setup "$R" nolib
run_check "$R"; rc=$?
[ "$rc" = 0 ] && ok || bad "C3 rc=$rc: $(cat "$R/out.txt")"
grep -q '\[auth\] hub-fireworks LANE DOWN (new)' "$R/logs/ALERTS.log" && ok || bad "C3 inline day-1 line: $(cat "$R/logs/ALERTS.log")"
grep -q "\"akey\":\"lanedown:hub-fireworks\"" "$R/beats.txt" && ok || bad "C3 inline akey must be the undated condition key: $(cat "$R/beats.txt")"
[ -e "$R/flags/lanedown-hub-fireworks-$TODAY" ] && ok || bad "C3 inline flag"

echo "lane-down-canary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
