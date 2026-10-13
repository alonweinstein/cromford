#!/bin/bash
# tests/reconcile-prs-owner-beat.bh-1595-test.sh — the reconcile-prs owner beats
# every tick, and the hub's jobs-watchdog pages ONCE, naming the configured
# owner, when that beat goes stale for N ticks (BH-1608, slice BH-1595.1).
#
# Driven, not grepped: the REAL bin/reconcile-prs.sh and the REAL
# bin/jobs-watchdog.sh run whole against a stub curl that records every request
# and plays the worker. The owner row the stub serves is stateful — a PATCH of
# the latch changes what the next GET answers — so three watchdog runs are three
# honest reads of one row, not three identical fixtures.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; FX="$T/fx"; export FX
mkdir -p "$H/bin/lib/jobs" "$H/bin/lib/mc" "$H/logs" "$H/locks" "$H/env" "$H/builds" "$H/state" "$H/flags" "$T/fakebin" "$FX"
cp "$DIR/bin/reconcile-prs.sh" "$DIR/bin/jobs-watchdog.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" "$DIR/bin/jobs-client.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
for f in merge-conductor-lib.sh gh-pr-list.sh gh-rest.sh gh-rest-var.sh gh-rest-etag.sh \
         lane-gate.sh hub-box.sh reconcile-read.sh reconcile-owner-beat.sh reconcile-owner-watch.sh env-path.sh; do
  [ -r "$DIR/bin/lib/$f" ] && cp "$DIR/bin/lib/$f" "$H/bin/lib/"
done
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >/dev/null 2>&1 \
  || { echo "could not render the lane registry"; exit 1; }
export LANE_REGISTRY="$T/lanes.json" LANE_GATE_CACHE_S=0 HUB_BOX_NAME=hub-x HARNESS_TEST_SANDBOX=1
echo 'alpha-os Example/alpha https://alpha.example /api/board 2 box-a' > "$H/fleet.conf"
printf 'CONSOLE_URL=https://console.example\nHARNESS_SECRET=shh\nJOBS_URL=https://jobs.example\n' > "$H/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nexec "$@"\n' > "$T/fakebin/setsid"; chmod +x "$T/fakebin/setsid"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/lane-alert.sh"; chmod +x "$H/bin/lane-alert.sh"
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"

# The worker. $FX/owner.json is GET /api/reconcile-prs/owner; a PATCH of the
# latch rewrites its .beat.alerted. $FX/beat.code / $FX/owner.code force a status.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"; BODY=""; WANT=0; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    --data-binary|--data|-d) BODY="$2"; shift 2 ;;
    -X) METHOD="$2"; shift 2 ;;
    -w) WANT=1; shift 2 ;;
    *) shift ;;
  esac
done
emit() { printf '%s' "$1"; [ "$WANT" = 1 ] && printf '\n%s' "${2:-200}"; printf '\n'; }
echo "$METHOD $URL $BODY" >> "$FX/curl.log"
case "$URL" in
  *"/api/reconcile-prs/beat") emit '{"ok":true}' "$(cat "$FX/beat.code" 2>/dev/null || echo 200)" ;;
  *"/api/reconcile-prs/owner/alert")
    jq -c --argjson a "$(jq -c .alerted <<<"$BODY")" '.beat.alerted=$a' "$FX/owner.json" > "$FX/owner.tmp" && mv "$FX/owner.tmp" "$FX/owner.json"
    emit '{"ok":true}' ;;
  *"/api/reconcile-prs/owner") emit "$(cat "$FX/owner.json")" "$(cat "$FX/owner.code" 2>/dev/null || echo 200)" ;;
  *"/api/builds/unmerged") emit '{"builds":[]}' ;;
  *"/api/settings") emit "$(cat "$FX/settings.json" 2>/dev/null || echo '{"settings":[]}')" ;;
  *"/api/jobs"*) emit '{"jobs":[]}' ;;
  *"/api/queue"*) emit '{"queue":[]}' ;;
  *"/api/lanes"*) emit '{"lanes":[]}' ;;
  *) emit '{}' 404 ;;
esac
exit 0
SH
chmod +x "$T/fakebin/curl"

set_rows() {
  local kv out="[]"
  for kv in "$@"; do
    out=$(jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + [{key:$k,value:$v,actor:"console"}]' <<<"$out")
  done
  printf '{"settings":%s}\n' "$out" > "$FX/settings.json"
}
# owner_row <age_s|null> [alerted] — beat:null when age is null (expected_since 5m ago)
owner_row() {
  if [ "$1" = null ]; then
    jq -nc '{owner:"hub-x",owner_source:"settings",beat:null,tick_s:600,as_of:"2026-09-23T08:00:00Z"}'
  else
    jq -nc --argjson age "$1" --argjson al "${2:-false}" \
      '{owner:"hub-x",owner_source:"settings",beat:{box:"hub-x",beat_at:"2026-09-23T07:29:00Z",expected_since:"2026-09-20T00:00:00Z",age_s:$age,alerted:$al},tick_s:600,as_of:"2026-09-23T08:00:00Z"}'
  fi > "$FX/owner.json"
}
tick() { # tick <box> — one reconcile-prs pass
  : > "$FX/curl.log"
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" BOX_NAME="$1" \
      JOBS_RETRIES=0 bash "$H/bin/reconcile-prs.sh" >/dev/null 2>"$T/tick.err" ); TICK_RC=$?
}
watch() { # watch [env...] — one jobs-watchdog pass on the hub
  ( cd "$T" && export PATH="$T/fakebin:$PATH" HARNESS="$H" BOX_NAME=hub-x JOBS_RETRIES=0
    [ $# -gt 0 ] && export "$@"
    bash "$H/bin/jobs-watchdog.sh" >/dev/null 2>"$T/watch.err" )
}
beats()   { grep -c '^POST https://jobs.example/api/reconcile-prs/beat' "$FX/curl.log" 2>/dev/null || true; }
silent()  { grep -c 'RECONCILE OWNER SILENT' "$H/logs/ALERTS.log" 2>/dev/null || true; }
resumed() { grep -c 'RECONCILE OWNER RESUMED' "$H/logs/ALERTS.log" 2>/dev/null || true; }
patches() { grep -c "^PATCH .*/api/reconcile-prs/owner/alert {\"alerted\":$1}" "$FX/curl.log" 2>/dev/null || true; }
reset_watch() { : > "$H/logs/ALERTS.log"; : > "$FX/curl.log"; }
set_rows

# 1. the owner beats, once, with its own name
tick hub-x
[ "$(beats)" = 1 ] && ok || bad "1a the owner tick must POST exactly one beat, got $(beats): $(cat "$FX/curl.log")"
grep -q '/api/reconcile-prs/beat {"box":"hub-x"}' "$FX/curl.log" && ok || bad "1b the beat names the fixture box hub-x: $(grep beat "$FX/curl.log")"

# 2. a non-owner never beats
set_rows lane.reconcile-prs.reconcile_prs_owner=other-box
tick hub-x
[ "$(beats)" = 0 ] && ok || bad "2 a non-owner box must not beat, got $(beats)"
set_rows

# 3. a failing beat does not stop the tick
echo 500 > "$FX/beat.code"
tick hub-x
[ "$(beats)" = 1 ] && ok || bad "3a the beat was attempted"
grep -q '/api/builds/unmerged' "$FX/curl.log" && ok || bad "3b the tick still reached /api/builds/unmerged after a 500 beat"
[ "$TICK_RC" = 0 ] && ok || bad "3c the tick exits 0, got $TICK_RC"
[ -s "$T/tick.err" ] && bad "3d the beat is silent on stderr: $(cat "$T/tick.err")" || ok
rm -f "$FX/beat.code"

# 4. core: 31m old beat, tick 10m, N=3 → ONE page over three runs
reset_watch; owner_row 1860
watch RECONCILE_PRS_OWNER_STALE_TICKS=3; watch RECONCILE_PRS_OWNER_STALE_TICKS=3; watch RECONCILE_PRS_OWNER_STALE_TICKS=3
[ "$(silent)" = 1 ] && ok || bad "4a exactly ONE SILENT line over three runs, got $(silent): $(cat "$H/logs/ALERTS.log") / $(cat "$T/watch.err")"
grep 'RECONCILE OWNER SILENT' "$H/logs/ALERTS.log" | grep -q 'configured owner hub-x (settings)' \
  && ok || bad "4b the page names the configured owner and its source: $(grep SILENT "$H/logs/ALERTS.log")"
grep 'RECONCILE OWNER SILENT' "$H/logs/ALERTS.log" | grep -q '31m (3 ticks of 10m); last beat 2026-09-23T07:29:00Z from hub-x' \
  && ok || bad "4c the page carries age, threshold and last beat: $(grep SILENT "$H/logs/ALERTS.log")"
[ "$(patches true)" = 1 ] && ok || bad "4d one latch PATCH alerted:true, got $(patches true)"

# 5. the beat comes back → one RESUMED, latch cleared, no new SILENT
: > "$H/logs/ALERTS.log"; : > "$FX/curl.log"
jq -c '.beat.age_s=120' "$FX/owner.json" > "$FX/o" && mv "$FX/o" "$FX/owner.json"
watch RECONCILE_PRS_OWNER_STALE_TICKS=3; watch RECONCILE_PRS_OWNER_STALE_TICKS=3
[ "$(resumed)" = 1 ] && ok || bad "5a one RESUMED line, got $(resumed): $(cat "$H/logs/ALERTS.log")"
[ "$(patches false)" = 1 ] && ok || bad "5b one latch PATCH alerted:false, got $(patches false)"
[ "$(silent)" = 0 ] && ok || bad "5c no new SILENT line"

# 6. the knob is honoured
reset_watch; owner_row 1860
watch RECONCILE_PRS_OWNER_STALE_TICKS=5
[ "$(silent)" = 0 ] && ok || bad "6a 31m with N=5 (50m) must not page"
watch RECONCILE_PRS_OWNER_STALE_TICKS=2
[ "$(silent)" = 1 ] && ok || bad "6b 31m with N=2 (20m) pages"
reset_watch; owner_row 1860
watch RECONCILE_PRS_OWNER_STALE_TICKS=abc
[ "$(silent)" = 0 ] && ok || bad "6c a non-integer knob runs no check"
grep -q 'RECONCILE_PRS_OWNER_STALE_TICKS' "$H/logs/jobs-watchdog.log" && ok || bad "6d ...and says so in the log"

# 7. negatives: unreachable, paused, never-beat-but-new
reset_watch; owner_row 1860; echo 500 > "$FX/owner.code"
watch RECONCILE_PRS_OWNER_STALE_TICKS=3
[ "$(silent)" = 0 ] && ok || bad "7a an unreachable worker is not a stale owner"
rm -f "$FX/owner.code"
reset_watch; owner_row 1860 true; touch "$H/flags/lane-off-reconcile-prs"
watch RECONCILE_PRS_OWNER_STALE_TICKS=3
[ "$(silent)" = 0 ] && ok || bad "7b a paused lane does not page"
[ "$(patches false)" = 1 ] && ok || bad "7c a paused lane clears the latch, got $(patches false)"
grep -q 'paused, not dead' "$H/logs/jobs-watchdog.log" && ok || bad "7d ...with a paused-not-dead log line"
rm -f "$H/flags/lane-off-reconcile-prs"
reset_watch; owner_row 300; jq -c '.beat.beat_at=null | .beat.box=null' "$FX/owner.json" > "$FX/o" && mv "$FX/o" "$FX/owner.json"
watch RECONCILE_PRS_OWNER_STALE_TICKS=3
[ "$(silent)" = 0 ] && ok || bad "7e never beat but expected_since 5m ago is not stale"
reset_watch; owner_row null
watch RECONCILE_PRS_OWNER_STALE_TICKS=3
[ "$(silent)" = 0 ] && ok || bad "7f beat:null is not stale"

# 8. only the hub pages
reset_watch; owner_row 1860
watch RECONCILE_PRS_OWNER_STALE_TICKS=3 BOX_NAME=box-a
[ "$(silent)" = 0 ] && ok || bad "8 a non-hub watchdog does not page (the hub's does)"

echo "reconcile-prs-owner-beat: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
