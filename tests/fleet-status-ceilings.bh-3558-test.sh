#!/bin/bash
# tests/fleet-status-ceilings.bh-3558-test.sh — BH-3558.1 (issue #3568): the
# hub's fleet-status push carries bin/concurrency-plan.sh --json as a top-level
# `.ceilings`, so the console's Controls page can say what actually limits
# builds. Driven against a fixture harness with a fake curl and a stub
# concurrency-plan.sh that prints $T/plan-fixture.
#
# What this pins:
#   C1 a 2-row array is carried as-is, the stub was asked for --json, and the
#      beat carries the same `.ceilings`;
#   C2 the script missing is `.ceilings == null` and the push still happens;
#   C3 non-JSON and a non-array are null, and the push still happens;
#   C4 the 60000-byte backstop sheds `.ceilings`;
#   C5 a real empty fleet `[]` stays [], never null.
# Run from anywhere: tests/fleet-status-ceilings.bh-3558-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/flags" "$T/env" "$T/builds" "$T/fakebin"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/fleet-fly-block.sh" "$T/bin/"
cp "$DIR/bin/alert_family.py" "$T/bin/"
printf 'HARNESS_SECRET=test-secret\nWATCHDOG_URL=https://wd-fixture.example\n' > "$T/env/global.env"
printf '#!/bin/bash\nprintf %%s "$1" > %s/BEAT.json\n' "$T" > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
cat > "$T/fakebin/curl" <<SH
#!/bin/bash
case "\$*" in */api/standby*) echo '[]'; exit 0 ;; esac
cat > "$T/PUSH.json"
SH
chmod +x "$T/fakebin/curl"
cat > "$T/fleet.conf" <<'EOF'
alpha-os Org/alpha https://a.example /api/board 2 box-alpha
EOF

stub() {
  cat > "$T/bin/concurrency-plan.sh" <<SH
#!/bin/bash
printf '%s\n' "\$*" > "$T/PLAN.args"
cat "$T/plan-fixture"
SH
  chmod +x "$T/bin/concurrency-plan.sh"
  printf '%s' "$1" > "$T/plan-fixture"
}
run() {
  rm -f "$T/PUSH.json" "$T/BEAT.json" "$T/PLAN.args"
  PATH="$T/fakebin:$PATH" HARNESS="$T" FLEET_CONF="$T/fleet.conf" bash "$DIR/bin/fleet-status-push.sh" </dev/null >/dev/null 2>&1
}
q() { jq -r "$1" "$T/PUSH.json" 2>/dev/null; }

TWO='[
  {"project":"alpha","box_read":"hub","route":"pool","pool_cap":"unlimited","box_slots":"-","effective":"unlimited","bound_by":"no numeric cap applies","applies":{"pool_cap":true,"box_slots":false}},
  {"project":"beta","box_read":"hub","route":"local","pool_cap":"-","box_slots":"4","effective":"4","bound_by":"box-slots 4 (route: local)","applies":{"pool_cap":false,"box_slots":true}}
]'

# ── C1: a 2-row array ───────────────────────────────────────────────────────
stub "$TWO"; run
jq -e . >/dev/null 2>&1 < "$T/PUSH.json" && ok || bad "C1: the push must be valid JSON"
[ "$(q '.ceilings | length')" = 2 ] && ok || bad "C1: .ceilings carries both rows (got: $(q '.ceilings|tojson'))"
[ "$(q '.ceilings[0].project')" = alpha ] && ok || bad "C1: .ceilings[0].project is alpha (got: $(q '.ceilings[0]|tojson'))"
[ "$(q '.ceilings[1].applies.box_slots')" = true ] && ok || bad "C1: rows are carried whole (got: $(q '.ceilings[1]|tojson'))"
case "$(cat "$T/PLAN.args" 2>/dev/null)" in *--json*) ok ;; *) bad "C1: concurrency-plan.sh must be asked for --json (got: $(cat "$T/PLAN.args" 2>/dev/null))" ;; esac
[ "$(jq -c '.ceilings' "$T/BEAT.json" 2>/dev/null)" = "$(q '.ceilings|tojson')" ] \
  && ok || bad "C1: the beat carries the same .ceilings (got: $(jq -c '.ceilings' "$T/BEAT.json" 2>/dev/null))"

# ── C2: script missing ──────────────────────────────────────────────────────
rm -f "$T/bin/concurrency-plan.sh"; run
[ -s "$T/PUSH.json" ] && ok || bad "C2: the push must still happen without concurrency-plan.sh"
[ "$(q '.ceilings')" = null ] && ok || bad "C2: missing script is null, never [] (got: $(q '.ceilings|tojson'))"
[ "$(q 'has("ceilings")')" = true ] && ok || bad "C2: .ceilings is present as null, so 'could not ask' is explicit"
[ "$(q 'has("projects")')" = true ] && ok || bad "C2: the rest of the snapshot must survive"

# ── C3: garbage ─────────────────────────────────────────────────────────────
stub 'not json'; run
[ -s "$T/PUSH.json" ] && ok || bad "C3: the push must still happen on non-JSON"
[ "$(q '.ceilings')" = null ] && ok || bad "C3: non-JSON is null (got: $(q '.ceilings|tojson'))"
stub '{}'; run
[ "$(q '.ceilings')" = null ] && ok || bad "C3: a non-array is null (got: $(q '.ceilings|tojson'))"
[ "$(q 'has("projects")')" = true ] && ok || bad "C3: the rest of the snapshot must survive a non-array"

# ── C4: the size backstop sheds .ceilings ───────────────────────────────────
pad() { jq -n --arg k "$(printf 'p%.0s' $(seq 1 61000))" '{($k):{count:3}}' > "$T/state/stale-owed.json"; rm -f "$T/state/stale-owed-reported.json"; }
pad; stub "$TWO"; run
[ "$(q '.snapshot_trimmed')" = size ] && ok || bad "C4: an oversized payload must be trimmed (got: $(q 'keys|tojson'))"
[ "$(q 'has("ceilings")')" = false ] && ok || bad "C4: .ceilings must be shed (got: $(q 'keys|tojson'))"
rm -f "$T/state/stale-owed.json"

# ── C5: an empty fleet stays [] ─────────────────────────────────────────────
stub '[]'; run
[ "$(q '.ceilings|tojson')" = "[]" ] && ok || bad "C5: a real empty fleet stays [] (got: $(q '.ceilings|tojson'))"

# ── the console half: the lib that reads .ceilings, and its node suite ──────
# console-ui/tests/controls-legibility.bh-3558.test.js renders the Controls
# page and the BUILD CEILINGS panel over the lib below. Run here too, so this
# suite is its door as well as the console-ui CI job's.
CEIL_LIB="$DIR/console-ui/src/lib/ceilings.js"
[ -f "$CEIL_LIB" ] && ok || bad "console: $CEIL_LIB is missing"
grep -q 'export function ceilingRows' "$CEIL_LIB" 2>/dev/null && ok || bad "console: ceilings.js must export ceilingRows"
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "fleet-status-ceilings: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/controls-legibility.bh-3558.test.js 2>&1); then ok
  else bad "console-ui/tests/controls-legibility.bh-3558.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "fleet-status-ceilings.bh-3558: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
