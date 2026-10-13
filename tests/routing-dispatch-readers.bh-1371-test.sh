#!/bin/bash
# tests/routing-dispatch-readers.bh-1371-test.sh — BH-1371 (BH-1027.2): the Fly
# dispatch / pool / capacity readers ask the routing accessors (BH-1369) and
# keep the bare flags/ file as the no-client fallback. Every case drives the
# REAL scripts (fly-dispatch, fly-pool, fly-pool-tick, fly-machine-state,
# free-slots, healthcheck, fly-image-refresh, build-caps) in a scratch harness
# against a stubbed curl; fly/flyctl/ssh/rsync/scp are stubs appending to a sink.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
H="$T/h"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$H/logs" "$H/state/fly" "$H/flags" "$H/locks" "$H/env" "$H/fly" "$T/fakebin" "$T/rows"
cp -R "$DIR/bin" "$H/bin"
cp "$DIR/fleet.conf" "$H/fleet.conf" 2>/dev/null || true
echo "HARNESS_SECRET=test-secret" > "$H/env/global.env"
: > "$H/env/fly.env"
for p in v z; do printf '{"app":"builder-%s"}\n' "$p" > "$H/state/fly/$p.json"; done
F="$H/flags"

cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2;;
    --data-binary) BODY="$2"; shift 2;;
    *) shift;;
  esac
done
printf '%s %s\n' "$METHOD" "$URL" >> "$REQ_SINK"
case "$METHOD $URL" in
  "GET "*/api/settings/routing_rows)
    if [ -s "$T_SETTING" ]; then cat "$T_SETTING"; printf '\n200\n'; else printf '{"error":"not found"}\n404\n'; fi; exit 0 ;;
  "GET "*/api/flags/*)
    n="${URL##*/api/flags/}"
    if [ -f "$T_FLAGROWS/$n.json" ]; then printf '{"flag":%s}\n200\n' "$(cat "$T_FLAGROWS/$n.json")"
    else printf '{"error":"not found"}\n404\n'; fi; exit 0 ;;
esac
case "$URL" in
  */api/routing*)
    [ "${CURL_MODE:-ok}" = http500 ] && { printf '{"error":"boom"}\n500\n'; exit 0; } ;;
esac
case "$METHOD $URL" in
  "GET "*/api/routing)
    printf '{"routing":['; first=1
    for f in "$ROWS"/*.json; do [ -f "$f" ] || continue; [ $first = 1 ] || printf ','; first=0; cat "$f"; done
    printf ']}\n200\n' ;;
  "GET "*/api/routing/*)
    p="${URL##*/api/routing/}"
    if [ -f "$ROWS/$p.json" ]; then printf '{"routing":%s}\n200\n' "$(cat "$ROWS/$p.json")"
    else printf '{"error":"not found"}\n404\n'; fi ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
CURL
for s in ssh rsync scp fly flyctl; do
  printf '#!/bin/bash\necho "%s $*" >> "$SINK"\nexit 0\n' "$s" > "$T/fakebin/$s"
done
printf '#!/bin/bash\nshift\nexec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/tailscale"
chmod +x "$T/fakebin"/*
printf '#!/bin/bash\necho "image-build $1" >> "$SINK"\nexit 1\n' > "$H/bin/fly-image-build.sh"
chmod +x "$H/bin/fly-image-build.sh"
mkdir -p "$T/flagrows"

knob() { printf '{"key":"routing_rows","setting":{"key":"routing_rows","value":"%s"}}' "$1" > "$T/setting.json"; }
row() { # row <project> <builder> <pool_app|null>
  local app='null'; [ "$3" = null ] || app="\"$3\""
  printf '{"project":"%s","builder":"%s","pool_app":%s,"halted":0,"updated_at":"2026-09-23T00:00:00Z"}' "$1" "$2" "$app" > "$T/rows/$1.json"
}
reset() { : > "$T/req.log"; : > "$T/sink"; rm -f "$H/logs/"*.log; }
run() { # run <script> [args...] — the real script, from the scratch tree
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret \
      JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 T_SETTING="$T/setting.json" \
      T_FLAGROWS="$T/flagrows" ROWS="$T/rows" REQ_SINK="$T/req.log" SINK="$T/sink" \
      CURL_MODE="${CURL_MODE:-ok}" FLEET_CONF="$H/fleet.conf" HARNESS_TEST_SANDBOX=1 \
      FLY_BIN_DIR="$T/fakebin" FLY_API_TOKEN_V=tok FLY_API_TOKEN_Z=tok POOL_SPAWN=0
    bash "$@" )
}
route() { # route <project> — caps_route through the real lib + real client
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret \
      JOBS_URL=https://jobs.invalid T_SETTING="$T/setting.json" T_FLAGROWS="$T/flagrows" \
      ROWS="$T/rows" REQ_SINK="$T/req.log" SINK="$T/sink" CURL_MODE="${CURL_MODE:-ok}"
    [ -d "$H/bin/lib/jobs" ] && . "$H/bin/jobs-client.sh" 2>/dev/null
    . "${CAPS_LIB:-$H/bin/lib/build-caps.sh}"
    caps_route "$H" "$1" )
}
routing_reqs() { grep -c '/api/routing' "$T/req.log" 2>/dev/null || true; }
no_hops() { ! grep -qE '^(ssh|rsync|scp) ' "$T/sink"; }

# --- 1. row-only pool enrollment, knob on, no files ----------------------------
knob on; row x pool harness-pool-x; reset
[ "$(route x)" = pool ] && ok || bad "1: caps_route x should be pool from the row"
rm -f "$F"/*-x
case "$(run "$H/bin/free-slots.sh" x)" in unlimited*) ok ;; *) bad "1: free-slots x should be unlimited: $(run "$H/bin/free-slots.sh" x)" ;; esac
rm -f "$F"/*-x
run "$H/bin/fly-dispatch.sh" >/dev/null 2>&1
[ -f "$F/builder-fly-x" ] && ok || bad "1: dispatch glob should see builder-fly-x synced from the row"
[ -d "$H/state/build-queue/x" ] && ok || bad "1: dispatch loop should enumerate x"
no_hops && ok || bad "1: pool project must not be pushed by the single-machine dispatcher: $(cat "$T/sink")"

# --- 2. row flips pool -> local: dispatch stands down --------------------------
row x local null; reset; scratch_rm "$H/state/build-queue/x"
run "$H/bin/fly-dispatch.sh" >/dev/null 2>&1
[ ! -e "$F/builder-fly-x" ] && ok || bad "2: builder-fly-x should be gone after the local row"
[ ! -d "$H/state/build-queue/x" ] && ok || bad "2: x should not be enumerated"
no_hops && ok || bad "2: no ssh/rsync for a local row: $(cat "$T/sink")"
rm -f "$T/rows/x.json"

# --- 3/4. knob off == lib moved aside, byte for byte ---------------------------
knob off; touch "$F/builder-fly-y" "$F/fly-pool-y"
snapshot() {
  printf 'fs=%s\n' "$(run "$H/bin/free-slots.sh" y)"
  printf 'route=%s\n' "$(route y)"
  printf 'mstate=%s\n' "$(run "$H/bin/fly-machine-state.sh" y m1)"
  printf 'hc-fly=%s\n' "$(run "$H/bin/healthcheck.sh" y >/dev/null 2>&1; grep -c 'build-queue/y' "$T/sink" || true)"
}
reset; ON=$(snapshot)
run "$H/bin/fly-dispatch.sh" >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "3: knob-off dispatch tick should exit 0 (rc $RC)"
no_hops && ok || bad "3: knob-off pool project y must not be pushed: $(cat "$T/sink")"
OFFREQ=$(routing_reqs)
[ "$OFFREQ" = 0 ] && ok || bad "3: knob off must make zero /api/routing requests (saw $OFFREQ)"
mv "$H/bin/lib/jobs" "$T/jobs-aside"
reset; ASIDE=$(snapshot)
mv "$T/jobs-aside" "$H/bin/lib/jobs"
[ "$ON" = "$ASIDE" ] && ok || bad "3/4: knob-off answers must equal the no-client answers
--- knob off:
$ON
--- lib aside:
$ASIDE"
case "$ON" in *"route=pool"*"mstate=unknown"*) ok ;; *) bad "4: file answers wrong: $ON" ;; esac
echo harness-pool-y > "$F/fly-pool-app-y"
mv "$H/bin/lib/jobs" "$T/jobs-aside"; reset
run "$H/bin/fly-machine-state.sh" y m1 >/dev/null 2>&1
grep -q 'harness-pool-y' "$T/sink" && ok || bad "4: fly-machine-state should read the app file with no client"
mv "$T/jobs-aside" "$H/bin/lib/jobs"
rm -f "$F"/*-y

# --- 5. knob on, routing 500s: files decide ------------------------------------
knob on; row w local null; touch "$F/builder-fly-w" "$F/fly-pool-w"; reset
[ "$(CURL_MODE=http500 route w)" = pool ] && ok || bad "5: outage must answer from the files (pool)"
case "$(CURL_MODE=http500 run "$H/bin/free-slots.sh" w)" in unlimited*) ok ;; *) bad "5: free-slots must stay unlimited on outage" ;; esac
CURL_MODE=http500 run "$H/bin/fly-dispatch.sh" >/dev/null 2>&1
[ -f "$F/builder-fly-w" ] && [ -f "$F/fly-pool-w" ] && ok || bad "5: outage must leave the files alone"
no_hops && ok || bad "5: no push on outage: $(cat "$T/sink")"
rm -f "$F"/*-w "$T/rows/w.json"

# --- 6. builder=pool with pool_app NULL: reap-only, no spawn -------------------
row v pool null; reset; route v >/dev/null
run "$H/bin/fly-pool.sh" v >/dev/null 2>&1
grep -q 'no dedicated pool app' "$H/logs/fly-pool.log" 2>/dev/null && ok || bad "6: fly-pool should refuse to spawn without a pool app"
! grep -qE 'machine (run|create|clone)' "$T/sink" && ok || bad "6: nothing spawned: $(cat "$T/sink")"
run "$H/bin/fly-dispatch.sh" >/dev/null 2>&1
no_hops && ok || bad "6: dispatcher must not claim a pool project"
rm -f "$F"/*-v "$T/rows/v.json"

# --- 7. row-only project reaches the tick and the nightly bake -----------------
row z pool app-z; reset
run "$H/bin/fly-pool-tick.sh" >/dev/null 2>&1
grep -q '\[pool/z\]' "$H/logs/fly-pool.log" 2>/dev/null && ok || bad "7: fly-pool-tick should run fly-pool.sh for row-only z"
rm -f "$F"/*-z; reset
run "$H/bin/fly-image-refresh.sh" >/dev/null 2>&1
grep -q 'image-build z' "$T/sink" && ok || bad "7: fly-image-refresh should bake row-only z: $(cat "$T/sink")"
rm -f "$F"/*-z "$T/rows/z.json"

# --- 8. sync-created empty fly-pool file leaves pool-cap.conf in charge --------
row u pool app-u; reset; route u >/dev/null
[ -f "$F/fly-pool-u" ] && [ ! -s "$F/fly-pool-u" ] && ok || bad "8: sync should create fly-pool-u empty"
echo "u 4" > "$H/fly/pool-caps.conf"
[ "$(run "$H/bin/pool-cap.sh" u)" = 4 ] && ok || bad "8: pool-cap u should read 4: $(run "$H/bin/pool-cap.sh" u)"
rm -f "$F"/*-u "$T/rows/u.json" "$H/fly/pool-caps.conf"

# --- 9. fly-disabled as a DB flag row, no file ---------------------------------
echo '{"name":"fly-disabled","active":1,"updated_at":"2026-09-23T01:00:00Z"}' > "$T/flagrows/fly-disabled.json"
row x pool harness-pool-x; reset
run "$H/bin/fly-dispatch.sh" >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "9: fly-disabled should exit 0 (rc $RC)"
grep -q 'fly-disabled present' "$H/logs/fly-dispatch.log" 2>/dev/null && ok || bad "9: no-op line missing"
[ ! -e "$F/builder-fly-x" ] && ok || bad "9: a disabled dispatcher must touch nothing"
rm -f "$T/flagrows/fly-disabled.json" "$F/fly-disabled" "$T/rows/x.json"
scratch_rm "$H/state/flags-db"

# --- 10. mutation: caps_route without the accessor goes red --------------------
row x pool harness-pool-x; rm -f "$F"/*-x
sed 's/&& routing_builder "\$p" 2>\/dev\/null; then/\&\& false; then/' "$H/bin/lib/build-caps.sh" > "$T/caps-mutant.sh"
cmp -s "$T/caps-mutant.sh" "$H/bin/lib/build-caps.sh" && bad "10: mutation did not apply"
[ "$(CAPS_LIB="$T/caps-mutant.sh" route x)" != pool ] && ok || bad "10: the mutant must NOT answer pool with no files"
rm -f "$F"/*-x
[ "$(route x)" = pool ] && ok || bad "10: the original must answer pool"

echo "routing-dispatch-readers: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
