#!/bin/bash
# tests/observe-report.bh-3859-test.sh — BH-3859: bin/lib/observe-report.sh,
# the one operator message a lane that ships dark posts after N observe ticks.
# Sourced directly into a scratch root with a stub bin/lane-alert.sh that logs
# its argv; nothing reaches a real alert path.
#
#   R1 ticks 1..N-1 send nothing, the state file counts up
#   R2 tick N sends exactly one warn with per-action counts, an example, the
#      flip command, and skips WOULD_ lines older than `since` (also for a
#      second lane name: the lib is not dequeue-watch specific)
#   R3 ticks N+1..N+5 send nothing
#   R4 lane-alert absent -> no stamp; the next tick with it present sends
#      (R4b: a lane-alert that fails leaves no stamp either)
#   R5 empty root -> rc 1, no file created
#   R6 zero WOULD_ lines -> the message says it would have done nothing
#   R7 a corrupt state file is read as fresh, with one log line
#   R8 no awk line in the lib uses an interval quantifier ({n}): older mawk
#      reads it literally, matches nothing, and R6's message would go out falsely
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/observe-report.bh-3859-test.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $CASE: $1"; }
eq() { [ "$2" = "$3" ] && ok || bad "$1: got '$2', wanted '$3'"; }
CASE=setup

. "$DIR/bin/lib/observe-report.sh" || { echo "FAIL: bin/lib/observe-report.sh does not source"; exit 1; }
declare -F observe_report_tick >/dev/null || { echo "FAIL: observe_report_tick is not defined"; exit 1; }

R="$T/h"; LOGF="$R/logs/lane.log"; CALLS="$T/calls.log"
FLIP="bin/harness-ctl.sh set dequeue-watch DEQUEUE_WATCH_ACT 1"
stub_alert() {
  mkdir -p "$R/bin"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$CALLS" > "$R/bin/lane-alert.sh"
  chmod +x "$R/bin/lane-alert.sh"
}
reset() {
  CASE="$1"
  scratch_rm "$R" || exit 1
  mkdir -p "$R/logs"; : > "$LOGF"; : > "$CALLS"
  stub_alert
}
tick() { HARNESS="$R" observe_report_tick "$@"; }
state() { jq -r "$1" "$R/state/observe-report/$2.json" 2>/dev/null; }
sends() { grep -c -- "--id observe-report:$1" "$CALLS" 2>/dev/null || true; }
past() { date -u -d "$1" '+%Y-%m-%d %H:%M:%SZ'; }

# ── R1: below N nothing is sent, the counter counts ──────────────────────────
reset R1
for i in 1 2 3; do tick dequeue-watch 4 "$LOGF" "$FLIP"; done
eq "sends below N" "$(sends dequeue-watch)" 0
eq "ticks counted" "$(state .ticks dequeue-watch)" 3
eq "sent_at below N" "$(state .sent_at dequeue-watch)" null

# ── R2: tick N sends once, with the WOULD_ summary since `since` ─────────────
reset R2
# A WOULD_ line from before the counter started must not count.
echo "$(past '3 days ago') act: example-org/x#7 aaaaaaaaaaaa rule-break WOULD_FIX_ROUND" >> "$LOGF"
tick dequeue-watch 3 "$LOGF" "$FLIP"
sleep 1
{
  echo "$(past now) act: example-org/x#101 b49a1b832b0d rule-break WOULD_FIX_ROUND"
  echo "$(past now) act: example-org/x#102 c49a1b832b0d bystander WOULD_REQUEUE"
  echo "$(past now) act: example-org/x#103 d49a1b832b0d flake WOULD_REQUEUE"
  echo "$(past now) act: example-org/x#103 d49a1b832b0d stale-status WOULD_LEAD_REQUEST"
  echo "2026-10-03T13:00:00Z tick projects=1 dequeued=3 recorded=3 acted=0 would=4"
} >> "$LOGF"
tick dequeue-watch 3 "$LOGF" "$FLIP"
eq "sends before N" "$(sends dequeue-watch)" 0
tick dequeue-watch 3 "$LOGF" "$FLIP"; rc=$?
eq "rc on the send tick" "$rc" 0
eq "sends at N" "$(sends dequeue-watch)" 1
msg=$(grep -- '--id observe-report:dequeue-watch' "$CALLS")
case "$msg" in "--severity warn --id observe-report:dequeue-watch dequeue-watch "*) ok ;; *) bad "lane-alert argv is '$msg'" ;; esac
for want in "3 ticks" "4 things on 3 PRs" "2 WOULD_REQUEUE" "1 WOULD_FIX_ROUND" "1 WOULD_LEAD_REQUEST" \
            "example-org/x#101 b49a1b832b0d rule-break WOULD_FIX_ROUND" "$FLIP"; do
  case "$msg" in *"$want"*) ok ;; *) bad "the message lacks '$want': $msg" ;; esac
done
case "$msg" in *"x#7"*) bad "a WOULD_ line older than since was counted: $msg" ;; *) ok ;; esac
[ "$(state .sent_at dequeue-watch)" != null ] && ok || bad "sent_at was not stamped after the send"
grep -q 'observe-report: sent after 3 ticks' "$LOGF" && ok || bad "no 'sent after' log line"
# The same lib, another lane, its own state and id.
tick demo-lane 1 "$LOGF" "bin/harness-ctl.sh set demo-lane DEMO_ACT 1"
eq "demo-lane sends" "$(sends demo-lane)" 1
demo=$(grep -- '--id observe-report:demo-lane demo-lane ' "$CALLS")
case "$demo" in *"DEMO_ACT 1"*) ok ;; *) bad "demo-lane message lacks its own flip command: $demo" ;; esac
eq "dequeue-watch sends after demo-lane" "$(sends dequeue-watch)" 1

# ── R3: never a second message ───────────────────────────────────────────────
CASE=R3
for i in 1 2 3 4 5; do
  echo "$(past now) act: example-org/x#104 e49a1b832b0d rule-break WOULD_FIX_ROUND" >> "$LOGF"
  tick dequeue-watch 3 "$LOGF" "$FLIP"
done
eq "sends after N+5" "$(sends dequeue-watch)" 1

# ── R4: no lane-alert, no stamp; it sends once lane-alert is back ─────────────
reset R4
rm -f "$R/bin/lane-alert.sh"
tick dequeue-watch 1 "$LOGF" "$FLIP"; rc=$?
eq "rc with lane-alert missing" "$rc" 1
eq "sent_at with lane-alert missing" "$(state .sent_at dequeue-watch)" null
grep -q 'observe-report: lane-alert missing, not sent' "$LOGF" && ok || bad "no lane-alert-missing log line"
stub_alert
tick dequeue-watch 1 "$LOGF" "$FLIP"
eq "sends once lane-alert is back" "$(sends dequeue-watch)" 1
[ "$(state .sent_at dequeue-watch)" != null ] && ok || bad "no stamp after the retried send"

# A lane-alert that fails is not a send either.
reset R4b
printf '#!/bin/bash\nexit 3\n' > "$R/bin/lane-alert.sh"
tick dequeue-watch 1 "$LOGF" "$FLIP"; rc=$?
eq "rc with lane-alert failing" "$rc" 1
eq "sent_at with lane-alert failing" "$(state .sent_at dequeue-watch)" null
grep -q 'observe-report: lane-alert rc 3, not sent' "$LOGF" && ok || bad "no lane-alert-failed log line"

# ── R5: empty root refuses and builds no path ────────────────────────────────
CASE=R5
before=$(find / -maxdepth 2 -name observe-report 2>/dev/null | wc -l)
( cd "$T" && HARNESS= H= observe_report_tick dequeue-watch 1 "$LOGF" "$FLIP" ); rc=$?
eq "rc with an empty root" "$rc" 1
eq "observe-report dirs near / after an empty root" "$(find / -maxdepth 2 -name observe-report 2>/dev/null | wc -l)" "$before"
[ -e "$T/state" ] && bad "a relative state path was built under the cwd" || ok

# ── R6: nothing would have been done ─────────────────────────────────────────
reset R6
tick dequeue-watch 2 "$LOGF" "$FLIP"; tick dequeue-watch 2 "$LOGF" "$FLIP"
eq "sends with no WOULD_ lines" "$(sends dequeue-watch)" 1
zero=$(grep -- '--id observe-report:dequeue-watch' "$CALLS")
case "$zero" in *"would have done nothing in 2 ticks"*) ok ;; *) bad "the zero message is '$zero'" ;; esac

# ── R7: a corrupt state file starts fresh, logged ────────────────────────────
reset R7
mkdir -p "$R/state/observe-report"; echo 'not json' > "$R/state/observe-report/dequeue-watch.json"
tick dequeue-watch 5 "$LOGF" "$FLIP"
eq "ticks after a corrupt file" "$(state .ticks dequeue-watch)" 1
eq "corrupt-state log lines" "$(grep -c 'observe-report: dequeue-watch state unreadable' "$LOGF")" 1

# ── R8: no interval quantifiers in the lib's awk (older mawk matches nothing) ─
CASE=R8
LIB="$DIR/bin/lib/observe-report.sh"
iv=$(grep -n 'awk' "$LIB" | grep -E '\{[0-9]+(,[0-9]*)?\}' || true)
eq "awk lines with {n} in observe-report.sh" "$iv" ""

echo "observe-report: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
