#!/bin/bash
# tests/fleet-status-push-test.sh — locks the watchdog contract of
# bin/fleet-status-push.sh against a fixture harness, with curl and beat.sh
# replaced by capture stubs so nothing leaves the machine.
#
# What is worth locking here is not the JSON shape but three judgement calls a
# refactor could quietly undo:
#   1. the project list comes from fleet.conf, not a hardcoded array (it WAS a
#      hardcoded four while the registry had grown to a dozen);
#   2. a project with no triage log reports -1, not the ~29,000,000 minutes that
#      `stat` on a missing file produces — a fresh enrollment must not read as a
#      dead lane and page the fleet;
#   3. an unreadable/mid-rsync fleet.conf pushes NOTHING, rather than an
#      empty-but-perfectly-healthy fleet, which is the most reassuring possible
#      shape for a total outage.
# Run from anywhere: tests/fleet-status-push-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/flags" "$T/env" "$T/fakebin"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/fleet-fly-block.sh" "$T/bin/"
printf 'HARNESS_SECRET=test-secret\nCONSOLE_URL=http://console.invalid\nWATCHDOG_URL=http://watchdog.invalid\n' > "$T/env/global.env"
mkdir -p "$T/bin/lib"; cp "$DIR/bin/lib/watchdog-url.sh" "$T/bin/lib/"
printf '#!/bin/bash\nprintf %%s "$1" > %s/BEAT.json\n' "$T" > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
printf '#!/bin/bash\ncat > %s/PUSH.json\n' "$T" > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
# The script hardcodes H=/root/harness, the same way CI's inline gate fixtures
# retarget triage-gate.sh and merge-sweep.sh.
sed "s|^H=/root/harness|H=$T|" "$DIR/bin/fleet-status-push.sh" > "$T/fsp.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
run() { rm -f "$T/PUSH.json" "$T/BEAT.json"; PATH="$T/fakebin:$PATH" bash "$T/fsp.sh"; }

# ---------- 1. enumeration follows fleet.conf ----------
cat > "$T/fleet.conf" <<'EOF'
# fixture registry
alpha-os Org/alpha https://a.example /api/board 2 box-alpha
beta-os  Org/beta  https://b.example /api/board 4 box-beta
EOF
echo "a recent triage line" > "$T/logs/alpha-os.log"
run
[ -s "$T/PUSH.json" ] && jq -e . >/dev/null 2>&1 < "$T/PUSH.json" \
  && ok || bad "a healthy registry must push valid JSON"
[ "$(jq -r '.projects | keys | join(",")' "$T/PUSH.json")" = "alpha-os,beta-os" ] \
  && ok || bad "projects come from fleet.conf (got: $(jq -c '.projects|keys' "$T/PUSH.json"))"

# Add a third row and it appears with no code change — that IS the fix.
echo 'gamma-os Org/gamma - - 6 box-gamma' >> "$T/fleet.conf"
run
[ "$(jq -r '.projects | keys | join(",")' "$T/PUSH.json")" = "alpha-os,beta-os,gamma-os" ] \
  && ok || bad "a new fleet.conf row must appear without a code change"
[ "$(jq -r '.fly | keys | join(",")' "$T/PUSH.json")" = "alpha-os,beta-os,gamma-os" ] \
  && ok || bad "the fly block covers the same projects"

# ---------- 2. the -1 sentinel ----------
# beta-os and gamma-os have never written a triage log.
[ "$(jq -r '.projects."beta-os".triage_log_age_min' "$T/PUSH.json")" = "-1" ] \
  && ok || bad "no triage log must report -1, not a fabricated age (got: $(jq -r '.projects."beta-os".triage_log_age_min' "$T/PUSH.json"))"
# The sentinel is specifically NOT a huge number: that is what would page.
AGE=$(jq -r '.projects."gamma-os".triage_log_age_min' "$T/PUSH.json")
[ "$AGE" -lt 1000 ] && ok || bad "a logless project must not read as ancient (got: $AGE)"
# A project WITH a log still reports a real, non-negative age.
AGE=$(jq -r '.projects."alpha-os".triage_log_age_min' "$T/PUSH.json")
[ "$AGE" -ge 0 ] && ok || bad "a project with a log reports a real age (got: $AGE)"

# ---------- 3. the same snapshot reaches the console ----------
[ -s "$T/BEAT.json" ] && [ "$(jq -r .kind "$T/BEAT.json")" = fleet_status ] \
  && ok || bad "the snapshot must also be beaten to the console"
diff <(jq -S 'del(.kind,.rkey)' "$T/BEAT.json") <(jq -S . "$T/PUSH.json") >/dev/null \
  && ok || bad "beat and watchdog push must carry the same snapshot"

# ---------- 4. an empty registry pushes NOTHING ----------
# A mid-rsync or unreadable fleet.conf. Reporting zero projects would say the
# fleet is fine and empty; saying nothing lets the dead-man fire instead.
: > "$T/fleet.conf"
run
[ ! -s "$T/PUSH.json" ] && ok || bad "an empty registry must not push (got: $(cat "$T/PUSH.json"))"
[ ! -s "$T/BEAT.json" ] && ok || bad "an empty registry must not beat either"

rm -f "$T/fleet.conf"
run
[ ! -s "$T/PUSH.json" ] && ok || bad "a MISSING fleet.conf must not push either"

echo "fleet-status-push-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
