#!/bin/bash
# tests/triage-gate-contested-test.sh — the launch gate's contested-hold skip
# (BH-590, the launch-gate slice of BH-579).
#
# WHY DRIVEN AND NOT GREPPED. Every claim here is about what the REAL script
# prints to a launch path and what it leaves in logs/contested.log: whether a
# ticket whose pre-plan files hit a live hold it does not own is skipped, whether
# the winner is ever skipped, and whether an expired/malformed/keyless/plan-less
# case fails OPEN. `grep -q contested bin/triage-gate.sh` passes on a block that
# blocks everything and on one that blocks nothing.
#
# The NEGATIVES come first: a gate that can suppress a build has to be proven
# quiet on an empty store and open on every failure before its one block matters.
#
# Run from anywhere: tests/triage-gate-contested-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
GATE="$DIR/bin/triage-gate.sh"
LOG="$H/logs/contested.log"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/plans" "$T/fakebin"
NOW=$(date +%s)

# The gate resolves the board through bin/fleet-conf.sh, which prefers the LIVE
# /root/harness/fleet.conf unless FLEET_CONF names another one.
printf 'tproj o/tproj - - 0 box-t 10.0.0.13\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
ln -sf "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"

# A gh that cannot reach the network and leaves a marker if anything calls it:
# the contested block is local files only (case 11).
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
: > "$T/gh-called"
exit 1
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"

printf '%s' '{"7":"TK-7","TK-7":"7","5":"TK-5","TK-5":"5","8":"TK-8","TK-8":"8","9":"TK-9","TK-9":"9","13":"TK-13","TK-13":"13"}' > "$H/state/tproj.keymap.json"

# The pre-plan lists bin/run-preplan.sh writes: file paths AND directory scopes.
mkdir -p "$H/plans/tproj-TK-7" "$H/plans/tproj-TK-5" "$H/plans/tproj-TK-8" "$H/plans/tproj-TK-9"
printf 'src/lib/x/a.ts\n' > "$H/plans/tproj-TK-7/planned-files.txt"
printf 'src/lib/x/a.ts\n' > "$H/plans/tproj-TK-5/planned-files.txt"
printf 'src/lib/y.ts\nsrc/lib/x/a.tsx\n' > "$H/plans/tproj-TK-8/planned-files.txt"
printf 'src/lib/x\n' > "$H/plans/tproj-TK-9/planned-files.txt"

# Hold paths are built LITERALLY, never through the function under test: a
# missing helper expands to nothing and a test that then writes to / is worse
# than a red one.
hold_file() { printf '%s/state/contested/tproj/%s' "$H" "$(printf '%s' "$1" | sha1sum | cut -c1-16)"; }
write_hold() { # <path> <winner_key> <created-epoch>
  mkdir -p "$H/state/contested/tproj"
  jq -nc --arg p "$1" --arg w "$2" --argjson c "$3" \
    '{project:"tproj",repo:"o/tproj",path:$p,winner_key:$w,
      winner_url:"https://gh/o/tproj/pull/40",loser_prs:[],loser_tickets:["TK-7"],
      created:$c,ttl:21600,why:"t"}' > "$(hold_file "$1")"
}
gate() { # <tid-or-KEY> [script]
  HARNESS="$H" bash "${2:-$GATE}" tproj --buildable "$1" 2>/dev/null
}
logcount() { if [ -f "$LOG" ]; then wc -l < "$LOG" | tr -d ' '; else echo 0; fi; }

HOLD="src/lib/x/a.ts"

# ============================================================================
# 9. an empty store is SILENT: no answer changes, no log file is created
# ============================================================================
out=$(gate 7)
[ "$out" = "OK" ] && ok || bad "empty store must answer OK, got: $out"
[ ! -e "$LOG" ] && ok || bad "empty store must not create logs/contested.log"

# ============================================================================
# 5. an EXPIRED hold is inert, and silent (it is not a failure)
# ============================================================================
write_hold "$HOLD" TK-5 "$((NOW - 21601))"
n0=$(logcount)
out=$(gate 7)
[ "$out" = "OK" ] && ok || bad "expired hold must answer OK, got: $out"
[ "$(logcount)" = "$n0" ] && ok || bad "expired hold must not log (was $n0, now $(logcount))"

# ============================================================================
# 6. a malformed hold is logged and skipped — never read as a block
# ============================================================================
printf 'not json\n' > "$(hold_file "$HOLD")"
: > "$H/state/contested/tproj/0000000000000000"
n0=$(logcount)
out=$(gate 7)
[ "$out" = "OK" ] && ok || bad "malformed holds must answer OK, got: $out"
n1=$(logcount)
[ "$((n1 - n0))" = "2" ] && ok || bad "two malformed holds want 2 log lines, got $((n1 - n0))"
[ "$(tail -2 "$LOG" | grep -c 'malformed hold')" = "2" ] && ok || bad "log must name the malformed holds: $(tail -2 "$LOG")"
rm -f "$H/state/contested/tproj/0000000000000000"

# ============================================================================
# 7. a ticket whose KEY cannot be resolved while a live hold exists: OK, loudly
# ============================================================================
write_hold "$HOLD" TK-5 "$NOW"
n0=$(logcount)
out=$(gate 12)
[ "$out" = "OK" ] && ok || bad "unresolvable ticket must answer OK, got: $out"
n1=$(logcount)
[ "$((n1 - n0))" = "1" ] && ok || bad "unresolvable ticket wants 1 log line, got $((n1 - n0))"
tail -1 "$LOG" | grep -q 'cannot evaluate 12' && ok || bad "log must say it could not evaluate 12: $(tail -1 "$LOG")"

# ============================================================================
# 12. a resolvable ticket with no pre-plan list: OK, loudly
# ============================================================================
n0=$(logcount)
out=$(gate 13)
[ "$out" = "OK" ] && ok || bad "ticket with no pre-plan must answer OK, got: $out"
n1=$(logcount)
[ "$((n1 - n0))" = "1" ] && ok || bad "ticket with no pre-plan wants 1 log line, got $((n1 - n0))"
tail -1 "$LOG" | grep -q 'no planned-files list' && ok || bad "log must name the missing pre-plan list: $(tail -1 "$LOG")"

# ============================================================================
# 1. the block itself: TK-7 plans the held file, TK-5 owns the hold
# ============================================================================
n0=$(logcount)
out=$(gate 7)
[ "$out" = "BLOCKED contested=src/lib/x/a.ts winner=TK-5" ] && ok || bad "TK-7 must be skipped, got: $out"
n1=$(logcount)
[ "$((n1 - n0))" = "1" ] && ok || bad "a skip wants exactly 1 log line, got $((n1 - n0))"
line=$(tail -1 "$LOG")
case "$line" in
  *"7/TK-7"*"src/lib/x/a.ts"*"winner TK-5"*) ok ;;
  *) bad "skip line must name ticket, path and winner: $line" ;;
esac

# ============================================================================
# 2. the WINNER is never skipped
# ============================================================================
n0=$(logcount)
out=$(gate 5)
[ "$out" = "OK" ] && ok || bad "the winner TK-5 must answer OK, got: $out"
[ "$(logcount)" = "$n0" ] && ok || bad "the winner must not log a skip"

# ============================================================================
# 3. a different file, and a near-miss extension, are both OK (exact match)
# ============================================================================
out=$(gate 8)
[ "$out" = "OK" ] && ok || bad "src/lib/y.ts + src/lib/x/a.tsx must answer OK, got: $out"

# ============================================================================
# 4. a planned DIRECTORY blocks on a hold for a file under it
# ============================================================================
out=$(gate 9)
[ "$out" = "BLOCKED contested=src/lib/x/a.ts winner=TK-5" ] && ok || bad "planned dir src/lib/x must be skipped, got: $out"

# ============================================================================
# 8. no keymap at all: the plans/ glob, and a raw KEY from the shard path
# ============================================================================
mv "$H/state/tproj.keymap.json" "$T/keymap.json"
out=$(gate 7)
[ "$out" = "BLOCKED contested=src/lib/x/a.ts winner=TK-5" ] && ok || bad "plans/ glob fallback must skip TK-7, got: $out"
out=$(gate TK-7)
[ "$out" = "BLOCKED contested=src/lib/x/a.ts winner=TK-5" ] && ok || bad "a raw KEY must skip TK-7, got: $out"
mv "$T/keymap.json" "$H/state/tproj.keymap.json"

# ============================================================================
# 10. no merge-conductor lib anywhere: fail OPEN, with a live hold in the store
# ============================================================================
cp -r "$DIR/bin" "$T/bincopy"
rm -f "$T/bincopy/lib/merge-conductor-lib.sh"
n0=$(logcount)
out=$(gate 7 "$T/bincopy/triage-gate.sh")
[ "$out" = "OK" ] && ok || bad "a missing lib must fail open to OK, got: $out"
[ "$(logcount)" = "$n0" ] && ok || bad "a missing lib must not log"

# ============================================================================
# 11. nothing above reached the network
# ============================================================================
[ ! -e "$T/gh-called" ] && ok || bad "the contested gate must not call gh"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
