#!/bin/bash
# tests/lane-alert-test.sh — bin/lane-alert.sh: the one alert path for detached
# orchestrator lanes. Always an ALERTS.log line + a fleet_alert beat; with
# --critical and the monitor OFF, a direct Telegram DM to the operator as well —
# because on 2026-09-12 a correct lane alert sat unread 10.5h in a file only
# the (off) monitor would have read. curl is a shim: no network, and the bot
# token must never reach a log.
#
# The akey is asserted on its `orclane:` PREFIX, not on the lane+minute tail it
# used to carry. Since 2026-09-15 the tail is the CONDITION'S id (an explicit
# --id, else a normalised hash of the line) rather than a clock — that is the
# point of the state machine, and a minute-stamped key was exactly what let one
# condition mint a fresh console row every time it was re-observed. Fire-once,
# resolve-once and severity routing are pinned in
# tests/alert-state-machine-test.sh; this file stays the DM-path fixture.
# Run from anywhere: tests/lane-alert-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1938: the DM chat has no literal in lane-alert.sh any more; its default is
# the registry's (lib.lane-alert), so the fixture needs the rendered registry.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
export LANE_REGISTRY; LANE_REGISTRY=$(rendered_registry)
mkdir -p "$T/bin" "$T/logs" "$T/flags" "$T/env" "$T/orc/flags" "$T/fakebin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "$BEAT_SINK"\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$CURL_SINK"\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
echo 'TELEGRAM_BOT_TOKEN=tok123' > "$T/env/global.env"
la() { # la [args...]
  : > "$T/beats.txt"; : > "$T/curl.txt"; : > "$T/logs/ALERTS.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" ORCHESTRATOR="$T/orc" BEAT_SINK="$T/beats.txt" CURL_SINK="$T/curl.txt"
    "$DIR/bin/lane-alert.sh" "$@"; echo "rc=$?" )
}

# 1. plain: line + beat, no DM even with the monitor off
touch "$T/orc/flags/monitor-off"
OUT=$(la pr254-gate "CI FAILED, project-5 stays unswept")
grep -q "rc=0" <<<"$OUT" && grep -q "\[orchestrator/pr254-gate\] CI FAILED, project-5 stays unswept" "$T/logs/ALERTS.log" \
  && grep -q '"kind":"fleet_alert"' "$T/beats.txt" && grep -q '"akey":"orclane:' "$T/beats.txt" \
  && grep -q '"alertid":"' "$T/beats.txt" \
  && [ ! -s "$T/curl.txt" ] && ok || bad "plain alert: $OUT alerts=$(cat "$T/logs/ALERTS.log") beats=$(cat "$T/beats.txt") curl=$(cat "$T/curl.txt")"
# 2. --critical with the monitor ON: no DM (the monitor relays)
rm -f "$T/orc/flags/monitor-off"
la --critical pr254-gate "x" >/dev/null
[ ! -s "$T/curl.txt" ] && grep -q "\[orchestrator/pr254-gate\] x" "$T/logs/ALERTS.log" && ok || bad "monitor on must not DM: $(cat "$T/curl.txt")"
# 3. --critical with the monitor OFF (orchestrator flag): a DM to the operator's chat, carrying the lane and text
touch "$T/orc/flags/monitor-off"
la --critical pr254-gate "CI FAILED" >/dev/null
grep -q "api.telegram.org/bottok123/sendMessage" "$T/curl.txt" && grep -q "chat_id=100000000" "$T/curl.txt" \
  && grep -q "text=CRITICAL \[orchestrator/pr254-gate\] CI FAILED" "$T/curl.txt" \
  && ok || bad "no DM: $(cat "$T/curl.txt")"
grep -q tok123 "$T/logs/ALERTS.log" "$T/beats.txt" && bad "the bot token leaked into a log/beat" || ok
# 4. the harness-side flag works too, and the chat id is overridable
rm -f "$T/orc/flags/monitor-off"; touch "$T/flags/monitor-off"
LANE_ALERT_DM_CHAT=1 la --critical l "y" >/dev/null
grep -q "chat_id=1" "$T/curl.txt" && ok || bad "harness flag / chat override: $(cat "$T/curl.txt")"
# 5. no token on the box: no DM, and the ALERTS line says so
: > "$T/env/global.env"
la --critical l "z" >/dev/null
[ ! -s "$T/curl.txt" ] && grep -q "TELEGRAM_BOT_TOKEN is not set" "$T/logs/ALERTS.log" && ok || bad "missing token must be said: $(cat "$T/logs/ALERTS.log")"

# 6. --help and -h are usage requests, not a lane named --help: no ALERTS line, no beat
: > "$T/logs/ALERTS.log"; : > "$T/beats.txt"
OUT=$(la --help)
grep -q "rc=0" <<<"$OUT" && [ ! -s "$T/logs/ALERTS.log" ] && [ ! -s "$T/beats.txt" ] && ok || bad "--help fired an alert: alerts=$(cat "$T/logs/ALERTS.log") beats=$(cat "$T/beats.txt")"
: > "$T/logs/ALERTS.log"; : > "$T/beats.txt"
OUT=$(la -h)
grep -q "rc=0" <<<"$OUT" && [ ! -s "$T/logs/ALERTS.log" ] && [ ! -s "$T/beats.txt" ] && ok || bad "-h fired an alert: alerts=$(cat "$T/logs/ALERTS.log") beats=$(cat "$T/beats.txt")"
# 7. flags before --help are still a usage request
: > "$T/logs/ALERTS.log"; : > "$T/beats.txt"
OUT=$(la --critical --help)
grep -q "rc=0" <<<"$OUT" && [ ! -s "$T/logs/ALERTS.log" ] && [ ! -s "$T/beats.txt" ] && ok || bad "--critical --help fired an alert: alerts=$(cat "$T/logs/ALERTS.log") beats=$(cat "$T/beats.txt")"

echo "lane-alert: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
