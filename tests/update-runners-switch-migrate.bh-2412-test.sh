#!/bin/bash
# tests/update-runners-switch-migrate.bh-2412-test.sh — bin/update-runners.sh
# runs bin/switch-migrate.sh on its daily tick (BH-2412).
#
# The `# >>> switch migrate` block is extracted verbatim from the real
# update-runners.sh (the cron-fleet-parity pattern), so the test cannot drift
# from the shipped code, and run with the variables update-runners sets above it.
#   U1 the REAL bin/switch-migrate.sh, through the block, writes the box row for
#      a file-only switch and its `wrote` line lands in the log
#   U2 a migrate that exits 1 -> exactly one ALERTS line naming rc=1 and the
#      failed line
#   U3 a migrate that exits 75 -> no ALERTS line, one log line
#   U4 CRON_RC is never touched; both script paths missing -> one log line
#   U5 the block sits after harness-sync and cli-update, before the rules
#      render and the exit, and the script still parses
# Run from anywhere: tests/update-runners-switch-migrate.bh-2412-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

UR="$DIR/bin/update-runners.sh"
MIGRATE="$DIR/bin/switch-migrate.sh"
awk '/^# >>> switch migrate/{f=1;next} /^# <<< switch migrate/{exit} f' "$UR" > "$T/block.sh"
[ -s "$T/block.sh" ] && ok || bad "could not extract the switch migrate block from update-runners.sh — markers missing?"

# A scratch harness the real switch-migrate reads: the registry and a stub
# worker that records PUTs (the switch-migrate suite's own stub shape).
mkdir -p "$T/h/bin" "$T/h/flags" "$T/h/state" "$T/h/logs" "$T/h/catalog/switches.d" "$T/co/bin"
cp "$DIR/catalog/switches.d/dora-digest-off.json" "$T/h/catalog/switches.d/"
# The alert goes through the real bin/alert-line.sh (BH-2314), which appends to
# <HARNESS>/logs/ALERTS.log; no beat.sh here, so it only appends.
cp "$DIR/bin/alert-line.sh" "$T/h/bin/"
AL="$T/h/logs/ALERTS.log"
cat > "$T/h/bin/jobs-client.sh" <<'SH'
_jobs_req() {
  JOBS_HTTP=""
  case "$1 $2" in
    "GET /api/settings") JOBS_HTTP=200; printf '{"settings":%s}' "$(cat "$ROWS_FILE")" ;;
    "PUT /api/settings")
      printf '%s\n' "$3" >> "$PUTS"
      jq -c --argjson b "$3" '. + [$b]' "$ROWS_FILE" > "$ROWS_FILE.new" && mv "$ROWS_FILE.new" "$ROWS_FILE"
      JOBS_HTTP=200; printf '{"setting":%s}' "$3" ;;
    *) return 1 ;;
  esac
}
SH

# stub <rc> <line> — a stand-in migrate that prints <line> and exits <rc>.
stub() { printf '#!/bin/bash\necho %q\nexit %s\n' "$2" "$1" > "$T/stub-migrate.sh"; chmod +x "$T/stub-migrate.sh"; }

# run <SWITCH_MIGRATE> — the block, in a child shell. CRON_RC starts as a
# sentinel so a block that assigned it would show. Prints CRON_RC.
run() {
  : > "$T/log"; : > "$T/alerts"; : > "$AL"
  env HARNESS="$T/h" JOBS_BOX=hub-1 ROWS_FILE="$T/rows.json" PUTS="$T/puts" \
      SWITCH_MIGRATE="$1" LOG="$T/log" HARNESS_ALERTS="$T/alerts" BOX_TAG=hub-1 \
      CHECKOUT="$T/co" CRON_RC=sentinel \
      bash -c 'set -uo pipefail; STAMP(){ echo TS; }; . "$1"; echo "CRON_RC=$CRON_RC"' _ "$T/block.sh" 2>/dev/null
}
lines() { grep -c . "$1" | tr -d ' '; }

# U1 — the real migrate, through the real block.
printf '[]' > "$T/rows.json"; : > "$T/puts"; touch "$T/h/flags/dora-digest-off"
eq "U1 CRON_RC untouched" "$(run "$MIGRATE")" "CRON_RC=sentinel"
eq "U1 one PUT" "$(lines "$T/puts")" "1"
eq "U1 the box row, value 1" "$(jq -r '"\(.key)=\(.value)"' "$T/puts" 2>/dev/null)" "switch.dora-digest-off.hub-1=1"
grep -q '^TS switch-migrate: wrote dora-digest-off switch.dora-digest-off.hub-1$' "$T/log" && ok \
  || bad "U1 the log must carry the wrote line: '$(cat "$T/log")'"
eq "U1 no ALERTS line" "$(lines "$AL")" "0"
# A second daily run writes nothing: the row is there now.
run "$MIGRATE" >/dev/null
eq "U1 the next day writes nothing" "$(lines "$T/puts")" "1"
grep -q 'switch-migrate: exists dora-digest-off' "$T/log" && ok || bad "U1 the second run must log exists: '$(cat "$T/log")'"

# U2 — rc 1: one ALERTS line naming the rc and the failed line.
stub 1 "failed x-off switch.x-off.hub-1 http=500"
eq "U2 CRON_RC untouched" "$(run "$T/stub-migrate.sh")" "CRON_RC=sentinel"
eq "U2 exactly one ALERTS line" "$(lines "$AL")" "1"
grep -q '\[hub-1\] switch-migrate rc=1 .*failed x-off switch.x-off.hub-1 http=500' "$AL" && ok \
  || bad "U2 the ALERTS line must name rc=1 and the failed line: '$(cat "$AL")'"
grep -q 'switch-migrate: failed x-off' "$T/log" && ok || bad "U2 the output must also be in the log"
eq "U2 no raw write to HARNESS_ALERTS (the line goes through alert-line.sh)" "$(lines "$T/alerts")" "0"
# Any other rc is the same ALERTS line.
stub 2 "usage: switch-migrate.sh [--dry-run]"
run "$T/stub-migrate.sh" >/dev/null
grep -q 'switch-migrate rc=2' "$AL" && ok || bad "U2 rc 2 must alert: '$(cat "$AL")'"

# U3 — rc 75: the worker is down, which the jobs client already pages. Log only.
printf '#!/bin/bash\nexit 75\n' > "$T/stub-migrate.sh"
eq "U3 CRON_RC untouched" "$(run "$T/stub-migrate.sh")" "CRON_RC=sentinel"
eq "U3 no ALERTS line" "$(lines "$AL")" "0"
eq "U3 one log line" "$(lines "$T/log")" "1"
grep -q 'switch-migrate rc=75' "$T/log" && ok || bad "U3 the log line must name rc=75: '$(cat "$T/log")'"

# U4 — both paths missing: one log line, no ALERTS, CRON_RC untouched.
eq "U4 CRON_RC untouched" "$(run "$T/no-such-migrate.sh")" "CRON_RC=sentinel"
eq "U4 no ALERTS line" "$(lines "$AL")" "0"
eq "U4 one log line" "$(lines "$T/log")" "1"
grep -q 'switch-migrate.sh missing' "$T/log" && ok || bad "U4 the log must say it is missing: '$(cat "$T/log")'"
# The checkout copy is the fallback when the installed path is not executable.
stub 0 "absent dora-digest-off"; cp "$T/stub-migrate.sh" "$T/co/bin/switch-migrate.sh"
run "$T/no-such-migrate.sh" >/dev/null
grep -q 'switch-migrate: absent dora-digest-off' "$T/log" && ok || bad "U4 the checkout fallback must run: '$(cat "$T/log")'"
rm -f "$T/co/bin/switch-migrate.sh"
grep -q 'CRON_RC' "$T/block.sh" && bad "U4 the block must not touch CRON_RC" || ok

# U5 — where the block sits in the real script, and that the script parses.
at() { grep -n -m1 -F -- "$1" "$UR" | cut -d: -f1; }
B=$(at '# >>> switch migrate'); S=$(at 'bin/harness-sync.sh >/dev/null'); C=$(at 'CLI_UPDATER=/root/harness/bin/cli-update.sh')
R=$(at 'CANON="$CHECKOUT/rules/CLAUDE.md"'); X=$(at 'exit "$CRON_RC"')
if [ -n "$B" ] && [ -n "$S" ] && [ -n "$C" ] && [ -n "$R" ] && [ -n "$X" ] \
   && [ "$B" -gt "$S" ] && [ "$B" -gt "$C" ] && [ "$B" -lt "$R" ] && [ "$B" -lt "$X" ]; then ok
else bad "U5 the block must sit after harness-sync ($S) and cli-update ($C), before the rules render ($R) and exit ($X): block at '$B'"; fi
bash -n "$UR" && ok || bad "U5 bin/update-runners.sh does not parse"

echo "update-runners-switch-migrate.bh-2412: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
