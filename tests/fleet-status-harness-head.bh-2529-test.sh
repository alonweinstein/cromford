#!/bin/bash
# tests/fleet-status-harness-head.bh-2529-test.sh — BH-2529: the fleet-status
# snapshot carries the harness HEAD — the hub checkout's own, and every box's
# as box_status holds it — so "which commit is each box on" is answered from
# the DB and the pushed snapshot, never by ssh-ing into a box.
#
# WHAT IS DRIVEN. The real bin/fleet-status-push.sh, whole, against a scratch
# harness (the tests/fleet-status-push-fields-test.sh seam): curl and beat.sh
# are capture stubs, and bin/jobs-client.sh is a stub that defines only
# box_heads, answering per $BH_MODE.
#   C1 box_heads answering two boxes -> .harness_heads[box] = {head, reported_at}
#   C2 box_heads failing -> .harness_heads null + harness_heads_error
#      "unreachable" (never {}: "no box reported" and "could not ask" differ),
#      and the push still happens
#   C3 .hub_harness_head is the checkout's short HEAD (beside .hub, whose
#      nine keys other suites pin); an oversized answer is
#      shed from the payload rather than costing the dead-man push
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/fleet-status-harness-head.bh-2529-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null && command -v git >/dev/null || { echo "jq/git missing — skipping"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/flags" "$T/env" "$T/builds" "$T/fakebin"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/fleet-fly-block.sh" "$DIR/bin/alert_family.py" "$T/bin/"
printf 'HARNESS_SECRET=test-secret\nWATCHDOG_URL=http://watchdog.invalid\n' > "$T/env/global.env"
printf '#!/bin/bash\nprintf %%s "$1" > %s/BEAT.json\n' "$T" > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
# The watchdog POST is the only curl with a body; the standby GET reads /dev/null.
printf '#!/bin/bash\nB=$(cat); [ -n "$B" ] && printf %%s "$B" > %s/PUSH.json\nexit 0\n' "$T" > "$T/fakebin/curl"
chmod +x "$T/fakebin/curl"
cat > "$T/bin/jobs-client.sh" <<'SH'
#!/bin/bash
# stub: sourced for box_heads only; run as a command it answers nothing
case "${BH_MODE:-rows}" in
  rows) box_heads() { printf 'box-project-4-1\tabc1234\t2026-09-25T20:00:00Z\nbox-project-3-2\tdef5678\t2026-09-25T20:05:00Z\n'; } ;;
  big)  box_heads() { local i; for i in $(seq 1 900); do printf 'box-%04d-padding-padding-padding\t%040d\t2026-09-25T20:00:00Z\n' "$i" "$i"; done; } ;;
  fail) box_heads() { return 1; } ;;
esac
[ "${BASH_SOURCE[0]}" = "$0" ] && exit 1
return 0
SH
chmod +x "$T/bin/jobs-client.sh"
cat > "$T/fleet.conf" <<'EOF'
alpha-os Org/alpha https://a.example /api/board 2 box-alpha
EOF
git init -q "$T/co"
git -C "$T/co" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
HUBHEAD=$(git -C "$T/co" rev-parse --short HEAD)

run() { rm -f "$T/PUSH.json" "$T/BEAT.json"
  PATH="$T/fakebin:$PATH" HARNESS="$T" FLEET_CONF="$T/fleet.conf" HARNESS_CHECKOUT="$T/co" BH_MODE="$1" \
    bash "$DIR/bin/fleet-status-push.sh" >/dev/null 2>&1; }
q() { jq -r "$1" "$T/PUSH.json" 2>/dev/null; }

# C1
run rows
[ -s "$T/PUSH.json" ] && ok || bad "C1: the snapshot must be pushed"
[ "$(q '.harness_heads["box-project-4-1"].head')" = abc1234 ] && ok \
  || bad "C1: harness_heads[box-project-4-1].head must be the box_status sha (got: $(q '.harness_heads'))"
[ "$(q '.harness_heads["box-project-3-2"].reported_at')" = 2026-09-25T20:05:00Z ] && ok \
  || bad "C1: reported_at must be box_status's harness_reported_at"
[ "$(q 'has("harness_heads_error")')" = false ] && ok || bad "C1: a good read carries no harness_heads_error"
[ "$(jq -r '.harness_heads["box-project-4-1"].head' "$T/BEAT.json" 2>/dev/null)" = abc1234 ] && ok \
  || bad "C1: the console beat carries the same heads"

# C2
run fail
[ -s "$T/PUSH.json" ] && ok || bad "C2: a failed box_heads read must not cost the push"
[ "$(q '.harness_heads')" = null ] && [ "$(q '.harness_heads_error')" = unreachable ] && ok \
  || bad "C2: a failed read is harness_heads null + harness_heads_error unreachable (got: $(q '{harness_heads, harness_heads_error}'))"

# C3
run rows
[ "$(q '.hub_harness_head')" = "$HUBHEAD" ] && ok || bad "C3: hub_harness_head must be the checkout's short HEAD (got: $(q '.hub_harness_head'))"
[ "$(q '.hub | has("harness_head")')" = false ] && ok || bad "C3: .hub keeps its nine keys; the head rides beside it"
run big
[ -s "$T/PUSH.json" ] && [ "$(q '.snapshot_trimmed')" = size ] && [ "$(q 'has("harness_heads")')" = false ] && ok \
  || bad "C3: an oversized harness_heads must be shed (trimmed: $(q '.snapshot_trimmed'), size $(wc -c < "$T/PUSH.json" 2>/dev/null))"
[ "$(wc -c < "$T/PUSH.json" 2>/dev/null || echo 0)" -le 64000 ] && ok || bad "C3: the shed payload must fit the watchdog's 64000 B cap"

echo "fleet-status-harness-head: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
