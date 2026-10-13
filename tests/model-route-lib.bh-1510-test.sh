#!/bin/bash
# tests/model-route-lib.bh-1510-test.sh — bin/lib/model-route.sh, driven for
# real against a stubbed curl, the same idiom tests/jobs-client-settings-test.sh
# uses and for the same reason: the helpers under test are the REAL ones, not a
# re-implementation, so a bug in the resolver shows up here instead of only in
# production.
#
# THE PROPERTIES UNDER TEST (BH-1510.0's ticket, verbatim):
#   - a hub row resolves; a project row OVERRIDES it, whole-ladder, for that
#     project only;
#   - the ladder prints in position order;
#   - a worker outage is served from this box's own cache of the last good
#     answer, logged once;
#   - a worker that is UP and says "no route" must NOT replay a stale cache —
#     that branch is kept apart from the outage branch on purpose;
#   - both the worker and the cache empty is rc 75 and exactly ONE ALERTS.log
#     line per (role, day) — never a guessed model;
#   - a malformed role/project is a caller bug: rc 1, no network call, no alert.
#
# Run from anywhere: tests/model-route-lib.bh-1510-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/logs" "$T/state" "$T/flags" "$T/bin/lib" "$T/env" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
cp "$DIR/bin/lib/model-route.sh" "$T/bin/lib/model-route.sh"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
echo "HARNESS_SECRET=test-secret" > "$T/env/global.env"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# GET /api/model-routes/<role>[?project=<p>] answers from $HARNESS/hub.json or
# $HARNESS/proj.json; anything else is a 404 (a real "no route" answer, not an
# outage — model_ladder must tell the two apart).
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"
[ -n "${REQ_SINK:-}" ] && printf '%s\n' "$URL" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in
  down) exit 7 ;;
esac
case "$URL" in
  *"/api/model-routes/build.execute?project=project-3")
    if [ -s "$HARNESS/proj.json" ]; then cat "$HARNESS/proj.json"; printf '\n200\n'
    else printf '{"error":"not found"}\n404\n'; fi ;;
  *"/api/model-routes/build.execute")
    if [ -s "$HARNESS/hub.json" ]; then cat "$HARNESS/hub.json"; printf '\n200\n'
    else printf '{"error":"not found"}\n404\n'; fi ;;
  *"/api/model-routes/empty.role")
    printf '{"role":"empty.role","project":null,"ladder":[],"source":"none"}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

# Sourced, so the function under test is the real one.
fn() { # fn <function> [args...]   -> stdout on fd 1, rc as the caller's rc
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid REQ_SINK="${REQ_SINK:-$T/req.log}" ${EXTRA_ENV:-}
    # shellcheck source=/dev/null
    . "$T/bin/lib/model-route.sh" 2>/dev/null
    "$@" )
}

# --- 1. a hub row: model_for prints the primary model ------------------------
cat > "$T/hub.json" <<'JSON'
{"role":"build.execute","project":null,"ladder":[{"position":0,"model":"model-hub-a","runner":"claude"},{"position":1,"model":"model-hub-b","runner":"grok"}],"source":"hub"}
JSON
OUT=$(fn model_for build.execute); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "model-hub-a" ] && ok || bad "model_for build.execute gave rc=$RC out='$OUT', wanted model-hub-a rc 0"

# --- 2. model_ladder prints every rung, in position order ---------------------
OUT=$(fn model_ladder build.execute)
WANT=$'0\tmodel-hub-a\tclaude\n1\tmodel-hub-b\tgrok'
[ "$OUT" = "$WANT" ] && ok || bad "model_ladder build.execute printed: $OUT"

# --- 3. a project override replaces the WHOLE ladder for that project --------
cat > "$T/proj.json" <<'JSON'
{"role":"build.execute","project":"project-3","ladder":[{"position":0,"model":"model-proj-x","runner":"codex"}],"source":"project"}
JSON
OUT=$(fn model_for build.execute project-3); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "model-proj-x" ] && ok || bad "model_for build.execute project-3 gave rc=$RC out='$OUT', wanted model-proj-x"
OUT2=$(fn model_runner_for build.execute project-3)
[ "$OUT2" = "codex" ] && ok || bad "model_runner_for build.execute project-3 gave '$OUT2', wanted codex"
# The hub ladder itself is untouched by a project-scoped read.
OUT3=$(fn model_for build.execute)
[ "$OUT3" = "model-hub-a" ] && ok || bad "a project-scoped read must not disturb the hub answer: got '$OUT3'"

# --- 4. worker down -> served from this box's own cache, logged once ---------
rm -f "$T/logs/model-route.log"
OUT=$(EXTRA_ENV="CURL_MODE=down" fn model_for build.execute); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "model-hub-a" ] && ok || bad "cache fallback gave rc=$RC out='$OUT', wanted model-hub-a rc 0"
grep -q "served from cache" "$T/logs/model-route.log" 2>/dev/null && ok || bad "no cache-served log line was written"

# --- 5. both the worker and the cache empty -> rc 75, one ALERTS line --------
rm -f "$T/logs/ALERTS.log"
OUT=$(fn model_for empty.role); RC=$?
[ "$RC" = 75 ] && [ -z "$OUT" ] && ok || bad "empty.role gave rc=$RC out='$OUT', wanted rc 75 and nothing on stdout"
[ "$(grep -c "empty.role" "$T/logs/ALERTS.log" 2>/dev/null)" = "1" ] && ok || bad "expected exactly one ALERTS line naming empty.role"
# A second call the same day must not page again (the daily reservoir).
OUT=$(fn model_for empty.role); RC=$?
[ "$RC" = 75 ] && ok || bad "second same-day call for empty.role gave rc=$RC, wanted 75 again"
[ "$(grep -c "empty.role" "$T/logs/ALERTS.log" 2>/dev/null)" = "1" ] && ok || bad "a second same-day call must not write a second ALERTS line"

# --- 6. a REACHABLE worker saying 'no route' must not replay a stale cache ---
# (proves outage-fallback and reachable-but-empty are two different branches).
rm -f "$T/state/model-routes/build.execute.tsv"
OUT=$(fn model_for build.execute); RC=$? # warm the cache back up
[ "$RC" = 0 ] && [ "$OUT" = "model-hub-a" ] || bad "warm-up call failed rc=$RC out='$OUT'"
mv "$T/hub.json" "$T/hub.json.bak"
printf '{"role":"build.execute","project":null,"ladder":[],"source":"none"}\n' > "$T/hub.json"
OUT=$(fn model_for build.execute); RC=$?
[ "$RC" = 75 ] && [ -z "$OUT" ] && ok || bad "a reachable worker answering 'no route' must fail closed, not replay the cache: rc=$RC out='$OUT'"
mv "$T/hub.json.bak" "$T/hub.json"

# --- 7. a malformed role/project is a caller bug: rc 1, no network call ------
rm -f "$T/req.log"
OUT=$(fn model_for 'bad role'); RC=$?
if [ "$RC" = 1 ] && [ -z "$OUT" ] && [ ! -s "$T/req.log" ]; then ok
else bad "malformed role gave rc=$RC out='$OUT', sent-a-request=$( [ -s "$T/req.log" ] && echo yes || echo no )"; fi
rm -f "$T/req.log"
OUT=$(fn model_for build.execute 'has spaces'); RC=$?
if [ "$RC" = 1 ] && [ -z "$OUT" ] && [ ! -s "$T/req.log" ]; then ok
else bad "malformed project gave rc=$RC out='$OUT'"; fi

# --- 8. a scope with NO rung 0 is absent, never a silent promotion (BH-1510.3) -
# A ladder whose position 0 is missing (an older worker that let two writes
# interleave) must not hand its rung 2 over as the primary. A PROJECT answer
# like that falls back to the hub ladder, alerted once per day.
printf '%s\n' '{"role":"build.execute","project":"project-3","ladder":[{"position":2,"model":"model-proj-stray","runner":"grok"}],"source":"project"}' > "$T/proj.json"
rm -f "$T/logs/ALERTS.log" "$T"/flags/alerted-model-route-* "$T/state/model-routes/build.execute@project-3.tsv"
OUT=$(fn model_for build.execute project-3); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "model-hub-a" ] && ok \
  || bad "a project ladder with no rung 0 must fall back to the hub primary, got rc=$RC out='$OUT'"
[ "$(grep -c "no rung 0" "$T/logs/ALERTS.log" 2>/dev/null)" = "1" ] && ok || bad "a gapped scope must alert once (got $(grep -c "no rung 0" "$T/logs/ALERTS.log" 2>/dev/null))"
OUT=$(fn model_for build.execute project-3)
[ "$(grep -c "no rung 0" "$T/logs/ALERTS.log" 2>/dev/null)" = "1" ] && ok || bad "the gap alert is once per day, not per call"
if [ -e "$T/state/model-routes/build.execute@project-3.tsv" ] && grep -q model-proj-stray "$T/state/model-routes/build.execute@project-3.tsv"; then
  bad "a gapped answer must never be cached as the last good one"
else ok; fi

# ...and a HUB answer with no rung 0 has nothing to fall back to: fail closed.
mv "$T/hub.json" "$T/hub.json.bak"
printf '%s\n' '{"role":"build.execute","project":null,"ladder":[{"position":1,"model":"model-hub-b","runner":"grok"}],"source":"hub"}' > "$T/hub.json"
rm -f "$T/state/model-routes/build.execute.tsv"
OUT=$(fn model_for build.execute); RC=$?
[ "$RC" = 75 ] && [ -z "$OUT" ] && ok || bad "a hub ladder with no rung 0 must fail closed (rc 75), not promote rung 1: rc=$RC out='$OUT'"
mv "$T/hub.json.bak" "$T/hub.json"
rm -f "$T/proj.json"

echo "model-route-lib-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
