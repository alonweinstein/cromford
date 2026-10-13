#!/bin/bash
# tests/box-console-commands-beat.bh-3945-test.sh — BH-3945: a forwarded
# fetch_artifact / fetch_log answered on a far box must reach the beat-fed
# reader (/api/dash/logs/<id>, the harness MCP), not only the row. The lane
# posts the body to the row FIRST, then sends the same JSON through
# bin/beat.sh with BEAT_STRICT=1. A failed beat is one log line and never
# changes the row's outcome; no beat.sh means no beat and no error.
#
# Drives the REAL lane and libs against a stubbed curl; fetch-log.sh,
# fetch-artifact.sh, run-triage.sh and beat.sh are stubs. curl and beat.sh
# write to one sink so the order (row, then beat) is observable.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin" "$T/env" "$T/logs" "$T/state" "$T/locks" "$T/fakebin"
cp -r "$DIR/bin/lib" "$T/bin/lib"
ls "$T"/bin/lib/jobs/*.sh >/dev/null 2>&1 || { echo "FAIL: scratch tree is missing bin/lib/jobs/*.sh, which jobs-client.sh sources"; exit 1; }
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/box-for.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-console-commands.sh" "$T/bin/"
printf 'JOBS_URL=https://jobs.invalid\nHARNESS_SECRET=test-secret\n' > "$T/env/global.env"
cat > "$T/fleet.conf" <<'CONF'
proj-a Org/a https://a.example /api/board 2 box-project-4-1
CONF

cat > "$T/bin/fetch-artifact.sh" <<'STUB'
#!/bin/bash
case "${1:-}" in --path) exit 0 ;; --error) exit 0 ;; esac
jq -nc --arg cid "$4" --arg k "$2" '{kind:"artifact_tail",rkey:("artifact:"+$cid),command_id:$cid,key:$k,content:"the review",missing:false}'
STUB
cat > "$T/bin/fetch-log.sh" <<'STUB'
#!/bin/bash
case "${1:-}" in --path) exit 0 ;; --error) exit 0 ;; esac
jq -nc --arg cid "$3" --arg w "$2" '{kind:"log_tail",rkey:("log:"+$cid),command_id:$cid,which:$w,content:"log text"}'
STUB
printf '#!/bin/bash\nexit 0\n' > "$T/bin/run-triage.sh"
cat > "$T/beat.stub" <<'STUB'
#!/bin/bash
jq -nc --arg s "${BEAT_STRICT:-}" --arg b "$1" '{beat:true, strict:$s, body:$b}' >> "$REQ_SINK"
exit "${BEAT_RC:-0}"
STUB
chmod +x "$T/bin/"*.sh "$T/beat.stub"

cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2;;
    --data-binary) BODY="$2"; case "$BODY" in @*) BODY=$(cat "${BODY#@}");; esac; shift 2;;
    *) shift;;
  esac
done
printf '%s' "$BODY" | jq -Rsc --arg m "$METHOD" --arg u "$URL" '{method:$m, url:$u, body:.}' >> "$REQ_SINK"
case "$METHOD $URL" in
  "POST "*/api/box-console-commands/claim)
    if [ -f "$CLAIM_FIX" ]; then cat "$CLAIM_FIX"; rm -f "$CLAIM_FIX"; else printf '[]'; fi
    printf '\n200\n' ;;
  "POST "*/api/box-console-commands/*/result) printf '{"ok":true}\n200\n' ;;
  *) printf '{}\n404\n' ;;
esac
CURL
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
chmod +x "$T/fakebin/"*

row() { jq -nc --arg id "$1" --arg t "$2" --arg pl "$3" \
  '{command_id:$id, box:"project-4", type:$t, project:"proj-a", payload:$pl, status:"claimed"}'; }
claims() { printf '%s\n' "$@" | jq -sc . > "$T/claim.json"; }
reset() { : > "$T/req.log"; rm -f "$T/logs/box-console-commands.log" "$T/claim.json"; echo project-4 > "$T/state/box-id"; }
run_lane() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" FLEET_CONF="$T/fleet.conf" \
      REQ_SINK="$T/req.log" CLAIM_FIX="$T/claim.json" JOBS_RETRIES=0 LANE_GATE_DISABLE=1 ${EXTRA_ENV:-}
    unset BOX_ID BEAT_STRICT
    bash "$T/bin/box-console-commands.sh" ) >"$T/out" 2>&1
}
# events <id> — the result posts and beats for one command id, in order.
events() { jq -c --arg id "$1" '
  if .beat then (.body|fromjson) as $b | select($b.command_id==$id) | {beat:.strict, body:$b}
  elif (.url|endswith("/api/box-console-commands/"+$id+"/result")) then {result:(.body|fromjson|.body|fromjson? // null)}
  else empty end' "$T/req.log"; }
nbeats() { jq -c 'select(.beat)' "$T/req.log" | wc -l; }

# --- B1: fetch_artifact: row result first, then one strict beat of the same body
reset; cp "$T/beat.stub" "$T/bin/beat.sh"
claims "$(row a1 fetch_artifact '{"key":"BH-1","which":"review"}')"
run_lane; RC=$?
E=$(events a1)
EXP='{"kind":"artifact_tail","rkey":"artifact:a1","command_id":"a1","key":"BH-1","content":"the review","missing":false}'
[ "$RC" = 0 ] && [ "$(wc -l <<<"$E")" = 2 ] \
  && [ "$(sed -n 1p <<<"$E" | jq -c .result)" = "$EXP" ] \
  && [ "$(sed -n 2p <<<"$E" | jq -c .body)" = "$EXP" ] \
  && [ "$(sed -n 2p <<<"$E" | jq -r .beat)" = 1 ] \
  && ok || bad "B1 rc=$RC events=$E out=$(head -c 300 "$T/out")"

# --- B2: fetch_log is beaten the same way; run_triage (no body) is not -------
reset; cp "$T/beat.stub" "$T/bin/beat.sh"
claims "$(row l1 fetch_log '{"which":"triage"}')" "$(row r1 run_triage '{}')"
run_lane; RC=$?
E=$(events l1)
[ "$RC" = 0 ] && [ "$(wc -l <<<"$E")" = 2 ] && [ "$(sed -n 2p <<<"$E" | jq -r '.body.kind,.body.rkey,.beat' | tr '\n' ' ')" = "log_tail log:l1 1 " ] \
  && [ "$(nbeats)" = 1 ] \
  && ok || bad "B2 events=$E beats=$(nbeats)"

# --- B3: a failing beat is logged; the row was still posted once; exit 0 -----
reset; cp "$T/beat.stub" "$T/bin/beat.sh"
claims "$(row f1 fetch_artifact '{"key":"BH-1","which":"review"}')"
EXTRA_ENV="BEAT_RC=1" run_lane; RC=$?
[ "$RC" = 0 ] && [ "$(events f1 | jq -c 'select(.result)' | wc -l)" = 1 ] && [ "$(nbeats)" = 1 ] \
  && grep -q 'beat failed id=f1 type=fetch_artifact rc=1' "$T/logs/box-console-commands.log" \
  && grep -q 'claimed=1 done=1 failed=0$' "$T/logs/box-console-commands.log" \
  && ok || bad "B3 rc=$RC events=$(events f1) log=$(cat "$T/logs/box-console-commands.log" 2>/dev/null)"

# --- B4: no beat.sh -> no beat and no error ---------------------------------
reset; rm -f "$T/bin/beat.sh"
claims "$(row n1 fetch_artifact '{"key":"BH-1","which":"review"}')"
run_lane; RC=$?
[ "$RC" = 0 ] && [ "$(nbeats)" = 0 ] && [ "$(events n1 | wc -l)" = 1 ] \
  && ! grep -q 'beat failed' "$T/logs/box-console-commands.log" \
  && grep -q 'claimed=1 done=1 failed=0$' "$T/logs/box-console-commands.log" \
  && ok || bad "B4 rc=$RC events=$(events n1) log=$(cat "$T/logs/box-console-commands.log" 2>/dev/null)"

echo "box-console-commands beat: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
