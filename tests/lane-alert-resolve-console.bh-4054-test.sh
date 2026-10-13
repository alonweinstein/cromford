#!/bin/bash
# tests/lane-alert-resolve-console.bh-4054-test.sh — `lane-alert.sh --resolve`
# closes the console twin too (BH-4054). A lane alert's line is re-beaten by
# poll-commands.sh as kind:"alert", and the alias lands that re-beat on
# alert:<id>, so a console row exists under that akey; the resolve used to beat
# only orclane:<id> and left it open until the 48h auto-stale.
#
#   L1 open critical, resolve -> one kind:"alert" resolved:true beat for
#      alert:<id>, the orclane:<id> resolve is still sent (2 resolve beats)
#   L2 a resolve of nothing open sends no beat at all
#   L3 a warn condition's twin rides the digest batch, not the console
#
# Real bin/lane-alert.sh, bin/beat.sh and bin/lib/alert-state.sh against a
# scratch $HARNESS; curl is the only fake (alert-state-machine-test's harness).
# Run from anywhere: tests/lane-alert-resolve-console.bh-4054-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/env" "$T/stub"
export HARNESS="$H" HARNESS_ENV_DIR="$H/env" LANE_GATE_DISABLE=1
export PATH="$T/stub:$PATH"
for s in beat.sh lane-alert.sh alert_family.py project-of.sh fleet-conf.sh; do ln -sf "$DIR/bin/$s" "$H/bin/$s"; done
for s in alert-state.sh conf-row.sh env-path.sh; do ln -sf "$DIR/bin/lib/$s" "$H/bin/lib/$s"; done
touch "$H/flags/alert-quarantine-disabled" "$H/flags/remediation-disabled"
printf 'CONSOLE_URL=https://console.invalid\nHARNESS_SECRET=testsecret\n' > "$H/env/global.env"
cat > "$T/stub/curl" <<STUB
#!/bin/bash
prev=""
for a in "\$@"; do
  [ "\$prev" = "-d" ] && { printf '%s\n' "\$a" >> "$T/sent.jsonl"; break; }
  prev="\$a"
done
printf '200'
STUB
chmod +x "$T/stub/curl"
export ALERTS_CONF="$H/flags/alerts.conf"; : > "$ALERTS_CONF"

reset() { scratch_rm "$H/state/alerts"; rm -f "$T/sent.jsonl" "$H/state/alert-warn-batch.jsonl"; : > "$H/logs/ALERTS.log"; }
la() { "$DIR/bin/lane-alert.sh" "$@" >/dev/null 2>&1; }
sent() { [ -s "$T/sent.jsonl" ] && grep -c . "$T/sent.jsonl" || echo 0; }

echo "--- L1: --resolve closes alert:<id> as well as orclane:<id>"
reset
la --id lx --severity critical lane "boom"
[ "$(sent)" = 1 ] && ok || bad "L1: the open sent $(sent) beats, want 1"
la --resolve --id lx lane "ok"
N=$(jq -c 'select(.kind=="alert" and .akey=="alert:lx" and .resolved==true)' "$T/sent.jsonl" 2>/dev/null | grep -c .)
[ "$N" = 1 ] && ok || bad "L1: want 1 alert:lx resolve, got $N: $(cat "$T/sent.jsonl")"
N=$(jq -c 'select(.kind=="fleet_alert" and .akey=="orclane:lx" and .resolved==true)' "$T/sent.jsonl" 2>/dev/null | grep -c .)
[ "$N" = 1 ] && ok || bad "L1: the orclane:lx resolve is gone ($N): $(cat "$T/sent.jsonl")"
[ "$(jq -c 'select(.resolved==true)' "$T/sent.jsonl" | grep -c .)" = 2 ] && ok || bad "L1: want 2 resolve beats: $(cat "$T/sent.jsonl")"
[ "$(jq -r 'select(.kind=="alert")|.alertid' "$T/sent.jsonl")" = lx ] && ok || bad "L1: the twin's alertid is not lx"
# A second --resolve: nothing is open any more, so nothing at all is sent.
B=$(sent); la --resolve --id lx lane "ok"
[ "$(sent)" = "$B" ] && ok || bad "L1: a repeat resolve sent again: $(cat "$T/sent.jsonl")"

echo "--- L2: a resolve of nothing open sends nothing"
reset
la --resolve --id nothing-open lane "ok"
[ "$(sent)" = 0 ] && ok || bad "L2: sent $(sent): $(cat "$T/sent.jsonl" 2>/dev/null)"

echo "--- L3: a warn condition's twin is batched, not POSTed"
reset
la --id lw --severity warn lane "slow"
la --resolve --id lw lane "fast again"
[ "$(sent)" = 0 ] && ok || bad "L3: a warn resolve reached the console: $(cat "$T/sent.jsonl")"
N=$(sed 's/^[^{]*//' "$H/state/alert-warn-batch.jsonl" 2>/dev/null | jq -c 'select(.kind=="alert" and .akey=="alert:lw" and .resolved==true)' 2>/dev/null | grep -c .)
[ "$N" = 1 ] && ok || bad "L3: the alert:lw twin is not in the warn batch: $(cat "$H/state/alert-warn-batch.jsonl" 2>/dev/null)"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
