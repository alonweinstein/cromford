#!/bin/bash
# tests/alerts-families-state.bh-2343-test.sh — BH-2343 (BH-2316.0): the optional
# third arg of `alert_families <lane> <claimed_since_s> [state]`.
#
# Drives the real bin/jobs-client.sh — the sourced function AND the CLI verb —
# against a fake curl that records the exact URL it was asked for. The 2-arg
# form must send today's URL byte for byte; the 3-arg form appends &state=.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/alerts-families-state.bh-2343-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin/lib/jobs" "$T/fakebin" "$T/env"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
echo 'HARNESS_SECRET=test-secret' > "$T/env/global.env"

cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2 ;; *) shift ;; esac
done
printf '%s %s\n' "$METHOD" "$URL" >> "$REQ_SINK"
case "$URL" in
  */api/alerts/families*) printf '{"families":[{"family":"f1","last_claimed_at":"t1","n":3}]}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

fn() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid REQ_SINK="$T/req.log"
    # shellcheck source=/dev/null
    . "$T/bin/jobs-client.sh" 2>/dev/null
    "$@" )
}
cli() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid REQ_SINK="$T/req.log"
    bash "$T/bin/jobs-client.sh" "$@" 2>/dev/null )
}
# check <label> <wanted-url> <runner> <args...>
check() {
  local label="$1" want="$2" out rc got; shift 2
  rm -f "$T/req.log"
  out=$("$@"); rc=$?
  got=$(cat "$T/req.log" 2>/dev/null)
  [ "$rc" -eq 0 ] && [ "$out" = "$(printf 'f1\tt1\t3')" ] && [ "$got" = "GET $want" ] \
    && ok || bad "$label: rc=$rc out='$out' request='$got', wanted 'GET $want'"
}

BASE=https://jobs.invalid/api/alerts/families
check "2-arg function"  "$BASE?lane=medic&claimed_since_s=900"               fn  alert_families medic 900
check "2-arg CLI"       "$BASE?lane=medic&claimed_since_s=900"               cli alert-families medic 900
check "3-arg function"  "$BASE?lane=medic&claimed_since_s=900&state=triaged" fn  alert_families medic 900 triaged
check "3-arg CLI"       "$BASE?lane=medic&claimed_since_s=900&state=triaged" cli alert-families medic 900 triaged
check "empty window"    "$BASE?lane=medic&state=triaged"                     fn  alert_families medic "" triaged
check "empty state"     "$BASE?lane=medic&claimed_since_s=900"               fn  alert_families medic 900 ""
check "lane only"       "$BASE?lane=medic"                                   fn  alert_families medic

echo "alerts-families-state.bh-2343: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
