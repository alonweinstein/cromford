#!/bin/bash
# tests/switch-migrate.bh-2320-test.sh — bin/switch-migrate.sh (BH-2320): a
# registered kill switch that exists only as flags/<name> on this box becomes
# the settings row `switch.<name>.<box>=1`, once, and a failure is never
# reported as a write.
#
#   M1 file present, no rows -> one PUT, box row, value 1, actor switch-migrate
#   M2 a second run writes nothing (`exists`)
#   M3 a fleet row already there -> nothing written
#   M4 --dry-run writes nothing and says what it would write
#   M5 a registry file whose name is not its filename -> rc 1, nothing written
#   M6 the PUT answers 500 -> rc 1, `failed`; settings unreadable or no client
#      -> rc 75, nothing written
# Run from anywhere: tests/switch-migrate.bh-2320-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

mkdir -p "$T/h/bin" "$T/h/flags" "$T/h/state" "$T/h/logs" "$T/h/catalog/switches.d"
cp "$DIR/catalog/switches.d/dora-digest-off.json" "$T/h/catalog/switches.d/" 2>/dev/null

# The stub worker. GET returns $T/rows.json; a PUT that succeeds is appended to
# it (so the second run sees the row, as it would against the real table) and
# its body to $T/puts. PUT_FAIL=1 answers 500, SETTINGS_DOWN=1 fails the GET.
cat > "$T/h/bin/jobs-client.sh" <<'SH'
_jobs_req() {
  JOBS_HTTP=""
  case "$1 $2" in
    "GET /api/settings")
      [ -n "${SETTINGS_DOWN:-}" ] && return 1
      JOBS_HTTP=200; printf '{"settings":%s}' "$(cat "$ROWS_FILE")" ;;
    "PUT /api/settings")
      printf '%s\n' "$3" >> "$PUTS"
      [ -n "${PUT_FAIL:-}" ] && { JOBS_HTTP=500; return 1; }
      jq -c --argjson b "$3" '. + [$b]' "$ROWS_FILE" > "$ROWS_FILE.new" && mv "$ROWS_FILE.new" "$ROWS_FILE"
      JOBS_HTTP=200; printf '{"setting":%s}' "$3" ;;
    *) return 1 ;;
  esac
}
SH
reset() { printf '[]' > "$T/rows.json"; rm -f "$T/puts"; : > "$T/puts"; PUT_FAIL=""; SETTINGS_DOWN=""; }
mig() {
  env HARNESS="$T/h" JOBS_BOX=Hub-1 ROWS_FILE="$T/rows.json" PUTS="$T/puts" \
      PUT_FAIL="$PUT_FAIL" SETTINGS_DOWN="$SETTINGS_DOWN" \
      "$DIR/bin/switch-migrate.sh" "$@" > "$T/out" 2>&1
}
puts() { wc -l < "$T/puts" | tr -d ' '; }

# M1
reset; touch "$T/h/flags/dora-digest-off"
mig; RC=$?
eq "M1 rc" "$RC" "0"
eq "M1 one PUT" "$(puts)" "1"
eq "M1 the box row" "$(jq -r '.key' "$T/puts" 2>/dev/null)" "switch.dora-digest-off.hub-1"
eq "M1 value 1" "$(jq -r '.value' "$T/puts" 2>/dev/null)" "1"
eq "M1 actor" "$(jq -r '.actor' "$T/puts" 2>/dev/null)" "switch-migrate"
grep -q '^wrote dora-digest-off switch.dora-digest-off.hub-1$' "$T/out" && ok || bad "M1 prints wrote: $(cat "$T/out")"
[ -f "$T/h/flags/dora-digest-off" ] && ok || bad "M1 the file must be left in place"

# M2 — the row now exists.
: > "$T/puts"
mig; RC=$?
eq "M2 rc" "$RC" "0"
eq "M2 no PUT" "$(puts)" "0"
grep -q '^exists dora-digest-off switch.dora-digest-off.hub-1$' "$T/out" && ok || bad "M2 prints exists: $(cat "$T/out")"

# M3 — a fleet row covers it.
reset; printf '[{"key":"switch.dora-digest-off","value":"0","actor":"api"}]' > "$T/rows.json"
mig; RC=$?
eq "M3 rc" "$RC" "0"
eq "M3 no PUT" "$(puts)" "0"
grep -q '^exists dora-digest-off switch.dora-digest-off$' "$T/out" && ok || bad "M3 prints exists: $(cat "$T/out")"

# M3b — no file on this box: nothing to migrate.
reset; rm -f "$T/h/flags/dora-digest-off"
mig; RC=$?
eq "M3b rc" "$RC" "0"
eq "M3b no PUT" "$(puts)" "0"
grep -q '^absent dora-digest-off$' "$T/out" && ok || bad "M3b prints absent: $(cat "$T/out")"

# M4 — dry run.
reset; touch "$T/h/flags/dora-digest-off"
mig --dry-run; RC=$?
eq "M4 rc" "$RC" "0"
eq "M4 no PUT" "$(puts)" "0"
grep -q '^would-write dora-digest-off switch.dora-digest-off.hub-1$' "$T/out" && ok || bad "M4 prints would-write: $(cat "$T/out")"

# M5 — a registry file that lies about its name refuses the whole run.
reset; touch "$T/h/flags/dora-digest-off"
printf '{"name":"bar-off","readers":[],"box_scoped":true,"what":"x"}\n' > "$T/h/catalog/switches.d/foo-off.json"
mig; RC=$?
eq "M5 rc" "$RC" "1"
eq "M5 no PUT" "$(puts)" "0"
grep -q 'foo-off.json' "$T/out" && ok || bad "M5 names the refused file: $(cat "$T/out")"
rm -f "$T/h/catalog/switches.d/foo-off.json"

# M6 — a failed PUT is failed, and an unreadable table writes nothing.
reset; touch "$T/h/flags/dora-digest-off"; PUT_FAIL=1
mig; RC=$?
eq "M6 PUT 500 rc" "$RC" "1"
grep -q '^failed dora-digest-off switch.dora-digest-off.hub-1' "$T/out" && ok || bad "M6 prints failed: $(cat "$T/out")"
grep -q '^wrote' "$T/out" && bad "M6 a failed PUT must never print wrote" || ok
reset; SETTINGS_DOWN=1
mig; RC=$?
eq "M6 settings unreadable rc" "$RC" "75"
eq "M6 settings unreadable: no PUT" "$(puts)" "0"
reset; mv "$T/h/bin/jobs-client.sh" "$T/h/bin/jobs-client.sh.off"
mig; RC=$?
eq "M6 no client rc" "$RC" "75"
eq "M6 no client: no PUT" "$(puts)" "0"
mv "$T/h/bin/jobs-client.sh.off" "$T/h/bin/jobs-client.sh"

# The header's own usage line runs as documented.
env HARNESS="$T/h" "$DIR/bin/switch-migrate.sh" --help > "$T/out" 2>&1; RC=$?
eq "--help rc" "$RC" "0"
grep -q 'switch-migrate.sh \[--dry-run\]' "$T/out" && ok || bad "--help prints the usage: $(cat "$T/out")"

echo "switch-migrate.bh-2320: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
