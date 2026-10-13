#!/bin/bash
# tests/hub-lease-promote-no-lease.bh-2282-test.sh — BH-2282: drives the real
# bin/hub-lease.sh `promote` against a stubbed curl when the worker answers
# GET /api/hub-lease with 200 {"lease":null} (an empty hub_lease table). It
# must say "no lease row", not "cannot read the live epoch (http=200 ...)",
# still exit 1 and still send nothing. Every other failed read keeps the
# generic message.
#
# Run from anywhere: tests/hub-lease-promote-no-lease.bh-2282-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/flags" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/box-name.sh" "$T/bin/box-name.sh"
printf 'box-hub\n' > "$T/state/box-name"
cp "$DIR/bin/fleet-conf.sh" "$T/bin/fleet-conf.sh"
cat > "$T/fleet-fixture.conf" <<'CONF'
# FIXTURE fleet.conf for tests/hub-lease-promote-no-lease.bh-2282-test.sh
# @standby box-small box-hub hub
demo-os example-org/demo-os - - 3 box-demo 192.0.2.10
CONF
export FLEET_CONF="$T/fleet-fixture.conf"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# Fake curl: payload\nHTTP_CODE, like real curl -w $'\n%{http_code}'.
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; METHOD=""; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2 ;;
    --data-binary) BODY="$2"; case "$BODY" in @*) BODY=$(cat "${BODY#@}");; esac; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "${REQ_SINK:-}" ] && printf '[%s] %s\n%s\n---\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "$URL" in
  */api/hub/promote*)
    TGT=$(printf '%s' "$BODY" | jq -r '.target // ""' 2>/dev/null)
    jq -nc --arg h "$TGT" '{ok:true, promoted:true, lease:{holder:$h,epoch:4,expired:false,live:true,expires_at:"2026-09-26T01:00:00Z",updated_at:"2026-09-26T00:00:00Z"}}'
    printf '200'; exit 0 ;;
  */api/hub-lease*)
    case "${CURL_MODE:-ok}" in
      no-lease)      printf '{"lease":null,"as_of":"2026-09-26T00:00:00Z"}\n200' ;;
      missing-lease) printf '{"not_lease":true}\n200' ;;
      not-deployed)  printf '{"error":"not deployed"}\n503' ;;
      ok|*)          printf '{"lease":{"holder":"box-hub","epoch":3,"expired":false,"expires_at":"2026-09-26T01:00:00Z","updated_at":"2026-09-26T00:00:00Z"},"as_of":"2026-09-26T00:00:00Z"}\n200' ;;
    esac
    exit 0 ;;
  *) printf '{}\n404'; exit 0 ;;
esac
CURL
chmod +x "$T/fakebin/curl"

SINK="$T/state/req-sink"
ERR="$T/state/stderr"
# run_promote <mode> — the real CLI; sets RC, OUT; stderr in $ERR, requests in $SINK.
run_promote() {
  rm -f "$T/state/hub-lease.json" "$T/logs/hub-lease.log"
  : > "$SINK"; : > "$ERR"
  OUT=$(CURL_MODE="$1" PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid \
    HUB_LEASE_HOLDER=box-hub HUB_LEASE_NOW=1000000000 REQ_SINK="$SINK" \
    bash "$DIR/bin/hub-lease.sh" promote --holder box-hub 2>"$ERR")
  RC=$?
}
posts() { grep -c '^\[POST\] .*/api/hub/promote' "$SINK" 2>/dev/null; }

# N1: empty hub_lease table → 200 {"lease":null} → "no lease row", rc 1, nothing sent
run_promote no-lease
[ "$RC" = 1 ] && ok || bad "N1: rc must stay 1 (got $RC)"
grep -q 'no lease row' "$ERR" && ok || bad "N1: stderr must say 'no lease row' (got: $(cat "$ERR"))"
grep -q 'http=200' "$ERR" && bad "N1: stderr must not print http=200 (got: $(cat "$ERR"))" || ok
grep -q 'cannot read the live epoch' "$ERR" && bad "N1: an empty table is not a failed read (got: $(cat "$ERR"))" || ok
grep -q 'nothing sent' "$ERR" && ok || bad "N1: stderr must still say nothing was sent (got: $(cat "$ERR"))"
[ "$(posts)" = 0 ] && ok || bad "N1: no POST /api/hub/promote may be sent (sink: $(cat "$SINK"))"
grep -q 'promote: no lease row' "$T/logs/hub-lease.log" 2>/dev/null && ok || bad "N1: the run log must record 'promote: no lease row'"

# N2: a 200 with no lease key is a malformed answer, not an empty table
run_promote missing-lease
[ "$RC" = 1 ] && ok || bad "N2: rc must be 1 (got $RC)"
grep -q 'cannot read the live epoch' "$ERR" && ok || bad "N2: must keep the generic message (got: $(cat "$ERR"))"
grep -q 'no lease row' "$ERR" && bad "N2: a body with no lease key is not 'no lease row'" || ok
[ "$(posts)" = 0 ] && ok || bad "N2: no POST may be sent"

# N3: worker not deployed → the generic message with the real status
run_promote not-deployed
[ "$RC" = 1 ] && ok || bad "N3: rc must be 1 (got $RC)"
grep -q 'cannot read the live epoch' "$ERR" && ok || bad "N3: must keep the generic message (got: $(cat "$ERR"))"
grep -q 'http=503' "$ERR" && ok || bad "N3: must name http=503 (got: $(cat "$ERR"))"
[ "$(posts)" = 0 ] && ok || bad "N3: no POST may be sent"

# N4 (control): a live row at epoch 3 → one POST carrying expected_epoch 3, rc 0
run_promote ok
[ "$RC" = 0 ] && ok || bad "N4: rc must be 0 (got $RC, stderr: $(cat "$ERR"))"
[ "$(posts)" = 1 ] && ok || bad "N4: exactly one POST /api/hub/promote (sink: $(cat "$SINK"))"
PB=$(awk '/^\[POST\] .*\/api\/hub\/promote/{getline; print; exit}' "$SINK")
[ "$(printf '%s' "$PB" | jq -r '.expected_epoch' 2>/dev/null)" = 3 ] && ok || bad "N4: expected_epoch must be 3 (body: $PB)"

echo "hub-lease-promote-no-lease.bh-2282-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
