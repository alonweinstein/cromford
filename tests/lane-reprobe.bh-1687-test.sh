#!/bin/bash
# tests/lane-reprobe.bh-1687-test.sh — BH-1687 (part 2 of BH-1674): the hub
# lane bin/lane-reprobe.sh, run for real from a scratch harness with the real
# bin/lib/lane-down.sh beside it. Only the edges are stubbed: bin/lane-probe.sh
# and fakebin/ssh answer $PROBE_OUT and count their calls, bin/lane-alert.sh
# records its argv, bin/fleet-conf.sh knows one box (project-3-2).
#
# The cases, from the plan:
#   L1 an ok probe clears record, flag and STATE line; one "back on" line; resolve;
#      a second run probes nothing and adds nothing
#   L2 a failed probe keeps the lane down and refreshes last_error/last_probe
#   L3 fast/slow backoff decides who is due; a non-numeric knob is its default
#   L4 every adversarial negative (rc 75, empty, 401, …) keeps the lane down
#   L5 ONE standing warn per outage at >=24h, stamped only after rc 0, resolved on ok
#   L6 seeding from STATE + contiguous flags, never bare box lines; no address
#      = one log line and no state change
#   L7 MAX_PER_RUN cap, oldest last_probe first, "deferred N"; DEADLINE=0 probes none
#   L8 a held locks/lane-reprobe.lock means exit 0 and no probe
#
# Run from anywhere: tests/lane-reprobe.bh-1687-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/fakebin"
cat > "$T/fakebin/ssh" <<'EOF'
#!/bin/bash
echo "ssh $*" >> "$CALLS"
printf '%s\n' "${PROBE_OUT:-}"
exit "${PROBE_RC:-0}"
EOF
chmod +x "$T/fakebin/ssh"

NOW=0; H=""; LOG=""; STATE=""; CALLS=""; ALERTCALLS=""
setup() {
  H=$T/h$1; scratch_rm "$H"
  mkdir -p "$H/bin/lib" "$H/env" "$H/state/lane-down" "$H/flags" "$H/logs" "$H/locks"
  cp "$DIR/bin/lane-reprobe.sh" "$H/bin/" 2>/dev/null
  cp "$DIR/bin/lib/lane-down.sh" "$H/bin/lib/"
  : > "$H/env/global.env"
  cat > "$H/bin/lane-probe.sh" <<'EOF'
#!/bin/bash
echo "local $1" >> "$CALLS"
printf '%s\n' "${PROBE_OUT:-}"
exit "${PROBE_RC:-0}"
EOF
  cat > "$H/bin/lane-alert.sh" <<'EOF'
#!/bin/bash
echo "$*" >> "$ALERTCALLS"
exit "${ALERT_RC:-0}"
EOF
  cat > "$H/bin/fleet-conf.sh" <<'EOF'
#!/bin/bash
[ "$1" = --tailnet-ip-of-box ] || exit 1
case "$2" in box-project-3-2) echo 192.0.2.2 ;; *) exit 1 ;; esac
EOF
  chmod +x "$H/bin/"*.sh
  LOG=$H/logs/lane-reprobe.log; STATE=$H/state/claude-auth-down.txt
  CALLS=$T/CALLS$1; ALERTCALLS=$T/ALERTCALLS$1; : > "$CALLS"; : > "$ALERTCALLS"
  NOW=$(date +%s)
}
# rec <ID> <addr> <since-ago-s> <last_probe-ago-s|""> [standing_at] — a record in the lib's format
rec() {
  local lp=""; [ -n "$4" ] && lp=$((NOW - $4))
  printf 'box=%s\nlane=%s\naddr=%s\nsince=%s\nlast_probe=%s\nlast_error=%s\nstanding_at=%s\n' \
    "${1%-*}" "${1##*-}" "$2" "$((NOW - $3))" "$lp" "earlier error" "${5:-}" > "$H/state/lane-down/$1"
}
get() { awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$H/state/lane-down/$1" 2>/dev/null; }
set_key() { local f=$H/state/lane-down/$1; awk -v k="$2" -v v="$3" 'index($0, k "=") == 1 { print k "=" v; next } { print }' "$f" > "$f.x" && mv "$f.x" "$f"; }
day() { date -u -d "@$((NOW - $1*86400))" +%Y%m%d; }
run() { HARNESS=$H CALLS=$CALLS ALERTCALLS=$ALERTCALLS PATH="$T/fakebin:$PATH" bash "$H/bin/lane-reprobe.sh"; }
ncalls() { grep -c . "$CALLS"; }

# L1 ------------------------------------------------------------------------
setup 1
rec hub-grok "" 7200 1860
printf 'hub\nhub-grok\n' > "$STATE"; touch "$H/flags/lanedown-hub-grok-$(day 0)"
PROBE_OUT=ok run; rc=$?
[ "$rc" -eq 0 ] && ok || bad "L1: rc=$rc"
[ ! -e "$H/state/lane-down/hub-grok" ] && ok || bad "L1: record survived an ok probe"
[ ! -e "$H/flags/lanedown-hub-grok-$(day 0)" ] && ok || bad "L1: today's flag survived an ok probe"
[ "$(cat "$STATE" 2>/dev/null)" = hub ] && ok || bad "L1: STATE is '$(tr '\n' ' ' < "$STATE" 2>/dev/null)', want exactly hub"
[ "$(grep -c 'lane grok back on hub after 2h' "$LOG" 2>/dev/null)" = 1 ] && ok || bad "L1: want one 'back on' line"
grep -q -- '--resolve --id lanedown-hub-grok ' "$ALERTCALLS" && ok || bad "L1: no resolve of lanedown-hub-grok"
[ "$(ncalls)" = 1 ] && grep -qx 'local grok' "$CALLS" && ok || bad "L1: want one local grok probe, got '$(tr '\n' ';' < "$CALLS")'"
PROBE_OUT=ok run
[ "$(grep -c 'back on' "$LOG")" = 1 ] && ok || bad "L1: second run added a 'back on' line"
[ "$(ncalls)" = 1 ] && ok || bad "L1: second run probed again"

# L2 ------------------------------------------------------------------------
setup 2
rec hub-grok "" 7200 1860
printf 'hub\nhub-grok\n' > "$STATE"; touch "$H/flags/lanedown-hub-grok-$(day 0)"
PROBE_OUT='xAI: team credit limit reached' run
[ -e "$H/flags/lanedown-hub-grok-$(day 0)" ] && ok || bad "L2: flag lost on a failed probe"
grep -qxF hub-grok "$STATE" && ok || bad "L2: STATE line lost on a failed probe"
[[ "$(get hub-grok last_error)" == *"credit limit"* ]] && ok || bad "L2: last_error='$(get hub-grok last_error)'"
lp=$(get hub-grok last_probe); d=$(( $(date +%s) - ${lp:-0} ))
[ "$d" -ge 0 ] && [ "$d" -le 5 ] && ok || bad "L2: last_probe=$lp is not now"
grep -q -- '--resolve' "$ALERTCALLS" && bad "L2: a failed probe resolved an alert" || ok
[ "$(grep -c 'lane grok still down on hub (2h 0m), next probe in 30m' "$LOG" 2>/dev/null)" = 1 ] && ok || bad "L2: no 'still down' line: $(cat "$LOG" 2>/dev/null)"
[ "$(get hub-grok since)" = "$((NOW - 7200))" ] && ok || bad "L2: since moved"

# L3 ------------------------------------------------------------------------
l3() { # <label> <since-ago> <lp-ago> <want calls> [env…]
  local label=$1 s=$2 l=$3 want=$4; shift 4
  setup "3$label"; rec hub-grok "" "$s" "$l"; printf 'hub-grok\n' > "$STATE"
  env "$@" PROBE_OUT=broken HARNESS="$H" CALLS="$CALLS" ALERTCALLS="$ALERTCALLS" PATH="$T/fakebin:$PATH" bash "$H/bin/lane-reprobe.sh"
  [ "$(ncalls)" = "$want" ] && ok || bad "L3$label: since -${s}s lp -${l}s: $(ncalls) probe calls, want $want"
}
l3 a 7200 600 0
l3 b 108000 7200 0
l3 c 108000 21660 1
l3 d 7200 1860 1
l3 e 7200 600 0 LANE_REPROBE_FAST_S=abc
l3 g 7200 1860 1 LANE_REPROBE_FAST_S=abc
l3 f 7200 600 1 LANE_REPROBE_FAST_S=300

# L4 ------------------------------------------------------------------------
n=0
while IFS= read -r neg; do
  n=$((n+1)); setup "4$n"
  rec hub-grok "" 7200 1860
  printf 'hub\nhub-grok\n' > "$STATE"; touch "$H/flags/lanedown-hub-grok-$(day 0)"
  rcv=0; case "$neg" in *"rc 75"*) rcv=75 ;; esac
  PROBE_OUT="$neg" PROBE_RC=$rcv run
  if [ -e "$H/state/lane-down/hub-grok" ] && [ -e "$H/flags/lanedown-hub-grok-$(day 0)" ] \
     && grep -qxF hub-grok "$STATE" && ! grep -q -- '--resolve' "$ALERTCALLS" && [ "$(ncalls)" = 1 ]; then ok
  else bad "L4: probe output '$neg' cleared the lane (or was not probed)"; fi
done <<'EOF'
no model route for the grok lane (rc 75) — not probed

codex-cli-version=0.46.0
401 Unauthorized
ssh: connect to host 192.0.2.2 port 22: Connection timed out
xAI: team credit limit reached
tokens
broken
invoked
EOF
[ "$n" = 9 ] && ok || bad "L4: ran $n negatives, want 9"

# L5 ------------------------------------------------------------------------
setup 5
rec hub-grok "" 90000 25200
printf 'hub-grok\n' > "$STATE"
PROBE_OUT='xAI: team credit limit reached' run
[ "$(grep -c -- '--id lanedown-stale-hub-grok --severity warn' "$ALERTCALLS")" = 1 ] && ok || bad "L5: want one standing warn, got: $(cat "$ALERTCALLS")"
grep -q 'Last error: xAI: team credit limit reached\. That fallback tier' <<<"$(grep -- '--id lanedown-stale-hub-grok' "$ALERTCALLS")" && ok || bad "L5: standing warn does not name the last error"
grep -q 'RUNNER LANE grok on hub down 1d 1h' <<<"$(grep -- '--id lanedown-stale-hub-grok' "$ALERTCALLS")" && ok || bad "L5: standing warn text: $(cat "$ALERTCALLS")"
sa=$(get hub-grok standing_at)
[ -n "$sa" ] && ok || bad "L5: standing_at not stamped"
set_key hub-grok last_probe $((NOW - 25200))
PROBE_OUT='xAI: team credit limit reached' run
[ "$(ncalls)" = 2 ] && ok || bad "L5: forced-due second run did not probe ($(ncalls) calls)"
[ "$(grep -c -- '--id lanedown-stale-hub-grok --severity warn' "$ALERTCALLS")" = 1 ] && ok || bad "L5: second standing warn in one outage"
[ "$(get hub-grok standing_at)" = "$sa" ] && ok || bad "L5: standing_at moved"
set_key hub-grok last_probe $((NOW - 25200))
PROBE_OUT=ok run
grep -q -- '--resolve --id lanedown-stale-hub-grok ' "$ALERTCALLS" && ok || bad "L5: ok run did not resolve lanedown-stale-hub-grok"
# under 24h: no standing warn at all
setup 5u
rec hub-grok "" 82800 1860; printf 'hub-grok\n' > "$STATE"
PROBE_OUT=broken run
grep -q -- 'lanedown-stale' "$ALERTCALLS" && bad "L5: standing warn under 24h" || ok
# L5b: undelivered warn leaves standing_at empty, and the next due probe retries it
setup 5b
rec hub-grok "" 90000 25200; printf 'hub-grok\n' > "$STATE"
ALERT_RC=1 PROBE_OUT=broken run
[ "$(grep -c -- '--id lanedown-stale-hub-grok' "$ALERTCALLS")" = 1 ] && ok || bad "L5b: standing warn not attempted"
[ -z "$(get hub-grok standing_at)" ] && ok || bad "L5b: standing_at stamped though lane-alert failed"
set_key hub-grok last_probe $((NOW - 25200))
PROBE_OUT=broken run
[ "$(grep -c -- '--id lanedown-stale-hub-grok' "$ALERTCALLS")" = 2 ] && ok || bad "L5b: failed warn not retried"
[ -n "$(get hub-grok standing_at)" ] && ok || bad "L5b: standing_at not stamped after a delivered retry"

# L6 ------------------------------------------------------------------------
setup 6
printf 'hub\nproject-4-grok\nproject-4\nhub-notalane\n' > "$STATE"
touch "$H/flags/lanedown-project-4-grok-$(day 0)" "$H/flags/lanedown-project-4-grok-$(day 1)" "$H/flags/lanedown-project-4-grok-$(day 3)"
run
[ -f "$H/state/lane-down/project-4-grok" ] && ok || bad "L6: project-4-grok not seeded"
[ "$(get project-4-grok since)" = "$(date -u -d "$(day 1)" +%s)" ] && ok || bad "L6: since='$(get project-4-grok since)', want yesterday 00:00Z"
le=$(get project-4-grok last_error); [ "${le% }" = "(pre-BH-1674 outage, error not recorded)" ] && ok || bad "L6: seed error text '$(get project-4-grok last_error)'"
[ ! -e "$H/state/lane-down/hub" ] && [ ! -e "$H/state/lane-down/project-4" ] && [ ! -e "$H/state/lane-down/hub-notalane" ] && ok || bad "L6: seeded a non-lane line: $(ls "$H/state/lane-down")"
[ "$(ncalls)" = 0 ] && ok || bad "L6: seeding probed on the same tick"
[ "$(sort "$STATE" | tr '\n' ' ')" = "project-4 project-4-grok hub hub-notalane " ] && ok || bad "L6: STATE changed: $(tr '\n' ' ' < "$STATE")"
# no address: a box fleet-conf cannot resolve
setup 6n
rec project-4-grok "" 7200 1860; printf 'project-4-grok\n' > "$STATE"
before=$(cat "$H/state/lane-down/project-4-grok")
run
[ "$(grep -c 'no address for project-4, not probed' "$LOG" 2>/dev/null)" = 1 ] && ok || bad "L6: no 'no address' line: $(cat "$LOG" 2>/dev/null)"
[ "$(cat "$H/state/lane-down/project-4-grok")" = "$before" ] && ok || bad "L6: no-address record changed"
[ "$(ncalls)" = 0 ] && ok || bad "L6: no-address lane was probed"
# a box fleet-conf DOES resolve goes over ssh to that address
setup 6s
rec project-3-2-grok "" 7200 1860; printf 'project-3-2-grok\n' > "$STATE"
PROBE_OUT=ok run
grep -q 'ssh .*root@192.0.2.2 /root/harness/bin/lane-probe.sh grok' "$CALLS" && ok || bad "L6: remote probe not via ssh: $(cat "$CALLS")"
[ ! -e "$H/state/lane-down/project-3-2-grok" ] && ok || bad "L6: remote ok did not clear"

# L7 ------------------------------------------------------------------------
setup 7
i=0
for id in hub-codex hub-openrouter hub-fireworks hub-grok momo-grok taxi-grok; do
  i=$((i+1)); rec "$id" 10.0.0.$i 7200 $((1800 + i*60))   # taxi-grok oldest, hub-codex youngest
  echo "$id" >> "$STATE"
done
LANE_REPROBE_MAX_PER_RUN=4 PROBE_OUT=broken run
[ "$(ncalls)" = 4 ] && ok || bad "L7: $(ncalls) probes, want 4"
grep -q 'deferred 2' "$LOG" && ok || bad "L7: no 'deferred 2': $(cat "$LOG")"
for id in taxi-grok momo-grok hub-grok hub-fireworks; do
  d=$(( $(date +%s) - $(get "$id" last_probe) )); [ "$d" -le 5 ] && ok || bad "L7: $id (old) not probed"
done
for id in hub-codex hub-openrouter; do
  d=$(( $(date +%s) - $(get "$id" last_probe) )); [ "$d" -ge 1800 ] && ok || bad "L7: $id (youngest) probed ahead of older ones"
done
setup 7b
for id in hub-codex hub-openrouter hub-fireworks hub-grok momo-grok taxi-grok; do rec "$id" 10.0.0.9 7200 1860; echo "$id" >> "$STATE"; done
LANE_REPROBE_DEADLINE_S=0 PROBE_OUT=broken run
[ "$(ncalls)" = 0 ] && ok || bad "L7b: DEADLINE=0 still probed $(ncalls)"
grep -q 'deferred 6' "$LOG" && ok || bad "L7b: no 'deferred 6': $(cat "$LOG" 2>/dev/null)"

# L8 ------------------------------------------------------------------------
setup 8
rec hub-grok "" 7200 1860; printf 'hub-grok\n' > "$STATE"
# The holder touches a readiness file once it HOLDS the lock, and the run waits
# for that file (bounded), never a fixed sleep that races a loaded host.
flock "$H/locks/lane-reprobe.lock" sh -c ': > "$1"; sleep 5' _ "$H/holding" & holder=$!
for _ in $(seq 1 200); do [ -e "$H/holding" ] && break; sleep 0.05; done
[ -e "$H/holding" ] && ok || bad "L8: the lock holder never took the lock"
PROBE_OUT=ok run; rc=$?
pkill -P "$holder" 2>/dev/null; kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
[ "$rc" -eq 0 ] && ok || bad "L8: rc=$rc under a held lock"
[ "$(ncalls)" = 0 ] && ok || bad "L8: probed under a held lock"
[ -e "$H/state/lane-down/hub-grok" ] && ok || bad "L8: record changed under a held lock"

echo "lane-reprobe.bh-1687: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
