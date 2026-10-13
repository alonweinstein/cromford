#!/bin/bash
# tests/model-route-hub-noroute.bh-1588-test.sh — a HUB-scope "no route" answer
# drops the hub cache, so the next outage fails closed instead of replaying it.
#
# #1581 made a project-scope source=none answer delete that project's hub-era
# cache and its .hub marker. The hub scope kept its `<role>.tsv` through the same
# answer, and the outage branch of model_ladder served it on the next
# unreachable call: rungs the worker had just said no longer exist (BH-1588, N2).
#
# The resolver is the REAL bin/lib/model-route.sh, sourced against a stubbed
# curl — the idiom of tests/model-route-lib.bh-1510-test.sh.
#
# Run from anywhere: tests/model-route-hub-noroute.bh-1588-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/logs" "$T/state" "$T/flags" "$T/bin/lib/jobs" "$T/env" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
cp "$DIR/bin/lib/model-route.sh" "$T/bin/lib/model-route.sh"
cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
echo "HARNESS_SECRET=test-secret" > "$T/env/global.env"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The hub read answers from $HARNESS/hub.json; CURL_MODE=down is an outage.
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"
case "${CURL_MODE:-ok}" in
  down) exit 7 ;;
esac
case "$URL" in
  *"/api/model-routes/build.execute")
    if [ -s "$HARNESS/hub.json" ]; then cat "$HARNESS/hub.json"; printf '\n200\n'
    else printf '{"error":"not found"}\n404\n'; fi ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
STUB
chmod +x "$T/fakebin/curl"

fn() { # fn <function> [args...]   -> the real sourced function's stdout and rc
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid ${EXTRA_ENV:-}
    # shellcheck source=/dev/null
    . "$T/bin/lib/model-route.sh" 2>/dev/null
    "$@" )
}
HUBC="$T/state/model-routes/build.execute.tsv"
PROJC="$T/state/model-routes/build.execute@project-3.tsv"
HUB_OK='{"role":"build.execute","project":null,"ladder":[{"position":0,"model":"model-hub-a","runner":"claude"},{"position":1,"model":"model-hub-b","runner":"grok"}],"source":"hub"}'
HUB_NONE='{"role":"build.execute","project":null,"ladder":[],"source":"none"}'

# --- 1. setup: a hub answer is cached ------------------------------------------
printf '%s\n' "$HUB_OK" > "$T/hub.json"
OUT=$(fn model_for build.execute); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "model-hub-a" ] && [ -s "$HUBC" ] && ok \
  || bad "setup: a source=hub answer must resolve and write the hub cache (rc=$RC out='$OUT')"

# A project's OWN cache (no .hub marker) that predates the hub's none answer.
printf '0\tmodel-proj-x\tcodex\n' > "$PROJC"

# --- 2. the worker says no route: fail closed AND drop the hub cache ------------
printf '%s\n' "$HUB_NONE" > "$T/hub.json"
OUT=$(fn model_for build.execute); RC=$?
[ "$RC" = 75 ] && [ -z "$OUT" ] && ok || bad "a hub source=none answer must fail closed: rc=$RC out='$OUT'"
[ ! -e "$HUBC" ] && ok || bad "a hub source=none answer must delete build.execute.tsv, it is still there"

# --- 3. the next outage has nothing to replay ----------------------------------
OUT=$(EXTRA_ENV="CURL_MODE=down" fn model_for build.execute); RC=$?
[ "$RC" = 75 ] && [ -z "$OUT" ] && ok \
  || bad "an outage after a hub no-route answer must fail closed, not replay the old hub rungs: rc=$RC out='$OUT'"

# --- 4. the fail-closed alert is kept, once per (role, day) --------------------
[ "$(grep -c "build.execute" "$T/logs/ALERTS.log" 2>/dev/null)" = "1" ] && ok \
  || bad "expected exactly one ALERTS line naming build.execute, got $(grep -c "build.execute" "$T/logs/ALERTS.log" 2>/dev/null)"

# --- 5. neighbours: the hub clear does not reach a project's own cache, and a
#        plain outage with a warm hub cache still serves it -----------------------
[ -s "$PROJC" ] && grep -q model-proj-x "$PROJC" && ok \
  || bad "a hub-scope no-route answer must not touch the project's own cache $PROJC"
printf '%s\n' "$HUB_OK" > "$T/hub.json"
fn model_for build.execute >/dev/null                      # warm the hub cache again
OUT=$(EXTRA_ENV="CURL_MODE=down" fn model_for build.execute); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "model-hub-a" ] && ok \
  || bad "an outage with a warm hub cache (no none answer between) must serve it: rc=$RC out='$OUT'"

echo "model-route-hub-noroute-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
