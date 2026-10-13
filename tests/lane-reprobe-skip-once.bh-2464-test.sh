#!/bin/bash
# tests/lane-reprobe-skip-once.bh-2464-test.sh — BH-2464 (from the #2472
# review): a fleet `lane` row whose box id is malformed logs its "skipping
# fleet row" line ONCE per row, not on every bin/lane-reprobe.sh tick until the
# row expires. FLEET_COOLDOWN_STORE (the contract's file backend) is the fleet.
#   S1  two real ticks over one malformed row -> exactly one skipping line
#   S2  a second malformed row appearing later gets its own one line
#   S3  once the row is gone (expired), a new row for the same id logs again
#   S4  a well-formed row beside it is still seeded, no skipping line for it
# Run from anywhere: tests/lane-reprobe-skip-once.bh-2464-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

R=$T/h
scratch_rm "$R"; mkdir -p "$R/bin/lib" "$R/env" "$R/state" "$R/flags" "$R/logs" "$R/locks" "$R/fakebin"
cp "$DIR/bin/lane-reprobe.sh" "$R/bin/lane-reprobe.sh"
cp "$DIR/bin/lib/lane-down.sh" "$DIR/bin/lib/fleet-cooldown.sh" "$R/bin/lib/"
: > "$R/env/global.env"; : > "$R/state/claude-auth-down.txt"
printf '#!/bin/bash\necho "401 unauthorized"\nexit 1\n' > "$R/bin/lane-probe.sh"
printf '#!/bin/bash\necho "401 unauthorized"\nexit 1\n' > "$R/fakebin/ssh"
printf '#!/bin/bash\nexit 0\n' > "$R/bin/lane-alert.sh"
printf '#!/bin/bash\nexit 1\n' > "$R/bin/fleet-conf.sh"
chmod +x "$R"/bin/*.sh "$R"/fakebin/*
run() { HARNESS=$R FLEET_COOLDOWN_STORE=$R/store.tsv PATH="$R/fakebin:$PATH" bash "$R/bin/lane-reprobe.sh"; }
now=$(date +%s)
# fleet_row <vendor> <subject> <until>
fleet_row() { printf 'lane\t%s\t%s\t%s\t%s\terr\tsomebox\t%s\n' "$1" "$2" "$3" "$((now - 100))" "$now" >> "$R/store.tsv"; }
skips() { grep -c "skipping fleet row $1:" "$R/logs/lane-reprobe.log" 2>/dev/null; }

# S1 / S4
fleet_row openrouter 'project-3-2' "$((now + 3600))"
fleet_row openrouter project-3-3 "$((now + 3600))"
run; run; run
n=$(skips project-3-2-openrouter); [ "$n" = 1 ] && ok || bad "S1 three ticks over one malformed row logged $n skipping lines, want 1"
[ -e "$R/state/lane-down/project-3-3-openrouter" ] && ok || bad "S4 well-formed row not seeded"
grep -q 'skipping fleet row project-3-3' "$R/logs/lane-reprobe.log" && bad "S4 well-formed row logged a skipping line" || ok

# S2
fleet_row codex 'Box_X' "$((now + 3600))"
run; run
n=$(skips Box_X-codex); [ "$n" = 1 ] && ok || bad "S2 a later malformed row logged $n lines, want 1"
n=$(skips project-3-2-openrouter); [ "$n" = 1 ] && ok || bad "S2 the first row logged again ($n)"

# S3: both rows expire, one tick sees them gone, then the same id comes back
awk -F'\t' -v OFS='\t' -v t="$((now - 10))" '$3 ~ /[A-Z]/ { $4 = t } { print }' "$R/store.tsv" > "$R/store.tmp" && mv "$R/store.tmp" "$R/store.tsv"
run
n=$(skips project-3-2-openrouter); [ "$n" = 1 ] && ok || bad "S3 an expired row logged ($n)"
fleet_row openrouter 'project-3-2' "$((now + 7200))"
run; run
n=$(skips project-3-2-openrouter); [ "$n" = 2 ] && ok || bad "S3 a new row after the old one expired logged $n lines in all, want 2"

echo "lane-reprobe-skip-once.bh-2464: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
