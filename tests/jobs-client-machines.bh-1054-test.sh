#!/bin/bash
# tests/jobs-client-machines.bh-1054-test.sh — the Fly machine registry client verbs.
#
# Drives the REAL bin/jobs-client.sh against a stubbed curl. The worker routes
# are out of scope for BH-1054; this file only pins the client-side contract:
# fail-open (nonzero, no stdout on API failure), env-override-first resolution
# for the flag, omitted-when-empty optional fields, and the right HTTP verbs.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/logs" "$T/state" "$T/bin" "$T/env" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
echo "HARNESS_SECRET=test-secret" > "$T/env/global.env"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
reqs() { if [ -f "$T/req.log" ]; then wc -l < "$T/req.log"; else echo 0; fi; }
settings_reqs() { if [ -f "$T/req.log" ]; then grep -c 'GET .*/api/settings/' "$T/req.log" 2>/dev/null || true; else echo 0; fi; }

# Fake curl: answers per CURL_MODE and records every request so PUT/PATCH/GET
# bodies and URLs can be read back. The GET /api/machines response is wrapped
# in {machines:[...]} so the client can use .machines[] (the routes slice will
# likely return the same envelope).
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
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in
  down) exit 7 ;;
  old404) printf '{"error":"not found"}\n404\n'; exit 0 ;;
  list404) printf '{"error":"not found"}\n404\n'; exit 0 ;;
esac
case "$METHOD $URL" in
  "GET "*/api/settings/*)
    if [ -s "${SETTING_JSON:-/nonexistent}" ]; then cat "$SETTING_JSON"; printf '\n200\n'
    else printf '{"error":"not found"}\n404\n'; fi ;;
  "PUT "*/api/machines)
    printf '{"ok":true}\n200\n' ;;
  "PUT "*/api/machines/observe)
    printf '{"ok":true,"received":3}\n200\n' ;;
  "PATCH "*/api/machines/*)
    printf '{"ok":true}\n200\n' ;;
  "GET "*/api/machines*)
    printf '{"machines":[{"machine_id":"m1","project":"tproj","app":"pool-tproj","role":"pool","key":"K-1","ticket":"1","state":"spawned","spawned_at":"2026-09-19T00:00:00Z","last_seen":"2026-09-19T01:00:00Z"}]}\n200\n' ;;
  *) printf '{}\n404\n' ;;
esac
CURL
chmod +x "$T/fakebin/curl"

stub() { printf '%s' "$1" > "$T/setting.json"; }
fn() { # fn <function> [args...]
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid SETTING_JSON="$T/setting.json" \
           REQ_SINK="$T/req.log" ${EXTRA_ENV:-}
    # shellcheck source=/dev/null
    . "$T/bin/jobs-client.sh" >/dev/null 2>&1
    "$@" )
}
cli() { # cli <verb> [args...]
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid SETTING_JSON="$T/setting.json" \
           REQ_SINK="$T/req.log" ${EXTRA_ENV:-}
    bash "$T/bin/jobs-client.sh" "$@" )
}

# --- 1. machines_rows_on: row off => rc 1, nothing printed -------------------
stub '{"key":"fly_machines_rows","setting":{"key":"fly_machines_rows","value":"off"},"source":"settings"}'
OUT=$(fn machines_rows_on); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "row off gave rc=$RC out='$OUT'"

# --- 2. machines_rows_on: row on => rc 0, nothing printed --------------------
stub '{"key":"fly_machines_rows","setting":{"key":"fly_machines_rows","value":"on"},"source":"settings"}'
OUT=$(fn machines_rows_on); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "row on gave rc=$RC out='$OUT'"

# --- 3. env override off beats row on, and skips the settings GET -------------
: > "$T/req.log"
stub '{"key":"fly_machines_rows","setting":{"key":"fly_machines_rows","value":"on"},"source":"settings"}'
OUT=$(EXTRA_ENV="FLY_MACHINES_ROWS=off" fn machines_rows_on); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && [ "$(settings_reqs)" -eq 0 ] \
  && ok || bad "FLY_MACHINES_ROWS=off override gave rc=$RC out='$OUT' settings_reqs=$(settings_reqs)"

# --- 4. env override on beats row off, and skips the settings GET ------------
: > "$T/req.log"
stub '{"key":"fly_machines_rows","setting":{"key":"fly_machines_rows","value":"off"},"source":"settings"}'
OUT=$(EXTRA_ENV="FLY_MACHINES_ROWS=on" fn machines_rows_on); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ "$(settings_reqs)" -eq 0 ] \
  && ok || bad "FLY_MACHINES_ROWS=on override gave rc=$RC out='$OUT' settings_reqs=$(settings_reqs)"

# --- 5. worker down => rc 1, nothing printed ---------------------------------
: > "$T/setting.json"
: > "$T/req.log"
OUT=$(EXTRA_ENV="CURL_MODE=down" fn machines_rows_on); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "worker down gave rc=$RC out='$OUT'"

# --- 6. machine-put sends the right PUT body with optional fields omitted ----
: > "$T/req.log"
RC=0; cli machine-put tproj pool-tproj m1 pool K-1 1 >/dev/null || RC=$?
LINE=$(grep -m1 'PUT .*/api/machines ' "$T/req.log" 2>/dev/null)
BODY=${LINE#PUT * }
if [ "$RC" = 0 ] && [ -n "$BODY" ] \
  && [ "$(printf '%s' "$BODY" | jq -r '.project')" = "tproj" ] \
  && [ "$(printf '%s' "$BODY" | jq -r '.app')" = "pool-tproj" ] \
  && [ "$(printf '%s' "$BODY" | jq -r '.machine_id')" = "m1" ] \
  && [ "$(printf '%s' "$BODY" | jq -r '.role')" = "pool" ] \
  && [ "$(printf '%s' "$BODY" | jq -r '.key')" = "K-1" ] \
  && [ "$(printf '%s' "$BODY" | jq -r '.ticket')" = "1" ] \
  && [ "$(printf '%s' "$BODY" | jq -r '.state')" = "spawned" ] \
  && [ "$(printf '%s' "$BODY" | jq -r 'has("image")')" = "false" ] \
  && [ "$(printf '%s' "$BODY" | jq -r 'has("auth_account")')" = "false" ] \
  && [ -n "$(printf '%s' "$BODY" | jq -r '.actor // empty')" ]; then
  ok
else bad "machine-put rc=$RC sent body '$BODY'"; fi

# --- 7. machine-put with empty machine_id => rc 1, no request ----------------
: > "$T/req.log"
RC=0; cli machine-put tproj pool-tproj "" pool >/dev/null || RC=$?
[ "$RC" = 1 ] && [ "$(reqs)" -eq 0 ] \
  && ok || bad "empty machine_id gave rc=$RC reqs=$(reqs)"

# --- 8. machines-observe maps a JSON array to PUT /api/machines/observe -------
: > "$T/req.log"
printf '[{"id":"a1","state":"started","updated_at":"2026-09-19T00:00:00Z"},{"id":"a2","state":"started"},{"id":"a3","state":"stopped","updated_at":"2026-09-19T02:00:00Z"}]' > "$T/list.json"
RC=0; cli machines-observe tproj pool-tproj "$T/list.json" >/dev/null || RC=$?
LINE=$(grep -m1 'PUT .*/api/machines/observe ' "$T/req.log" 2>/dev/null)
BODY=${LINE#PUT * }
if [ "$RC" = 0 ] \
  && [ "$(printf '%s' "$BODY" | jq '.machines | length')" -eq 3 ] \
  && [ "$(printf '%s' "$BODY" | jq -r '.machines[0].machine_id')" = "a1" ] \
  && [ "$(printf '%s' "$BODY" | jq -r '.machines[0].state')" = "started" ] \
  && [ "$(printf '%s' "$BODY" | jq -r '.machines[2].machine_id')" = "a3" ] \
  && [ "$(printf '%s' "$BODY" | jq -r '.project')" = "tproj" ] \
  && [ "$(printf '%s' "$BODY" | jq -r '.app')" = "pool-tproj" ] \
  && [ -n "$(printf '%s' "$BODY" | jq -r '.actor // empty')" ]; then
  ok
else bad "machines-observe rc=$RC sent body '$BODY'"; fi

# --- 9. machines-observe rejects a non-array file -----------------------------
: > "$T/req.log"
printf '{"a":{"id":"a1","state":"started"},"b":{"id":"a2","state":"started"}}' > "$T/list.json"
RC=0; cli machines-observe tproj pool-tproj "$T/list.json" >/dev/null || RC=$?
[ "$RC" = 1 ] && [ "$(reqs)" -eq 0 ] \
  && ok || bad "non-array observe file gave rc=$RC reqs=$(reqs)"

# --- 10. machine-close sends PATCH with optional detail -----------------------
: > "$T/req.log"
RC=0; cli machine-close tproj pool-tproj m1 gone "listing omitted it" >/dev/null || RC=$?
LINE=$(grep -m1 'PATCH .*/api/machines/m1 ' "$T/req.log" 2>/dev/null)
BODY=${LINE#PATCH * }
if [ "$RC" = 0 ] \
  && [ "$(printf '%s' "$BODY" | jq -r '.state')" = "gone" ] \
  && [ "$(printf '%s' "$BODY" | jq -r '.detail')" = "listing omitted it" ] \
  && [ "$(printf '%s' "$BODY" | jq -r '.project')" = "tproj" ] \
  && [ "$(printf '%s' "$BODY" | jq -r '.app')" = "pool-tproj" ]; then
  ok
else bad "machine-close rc=$RC sent body '$BODY'"; fi

# --- 11. machine-close with empty required arg => rc 1, no request -----------
: > "$T/req.log"
RC=0; cli machine-close tproj pool-tproj m1 "" >/dev/null || RC=$?
[ "$RC" = 1 ] && [ "$(reqs)" -eq 0 ] \
  && ok || bad "empty state gave rc=$RC reqs=$(reqs)"

# --- 12. machines-list prints TSV and sends the right query -------------------
: > "$T/req.log"
OUT=$(cli machines-list tproj live); RC=$?
URL=$(grep -m1 'GET .*/api/machines' "$T/req.log" 2>/dev/null | awk '{print $2}')
KEYCOL=$(printf '%s' "$OUT" | awk -F'\t' '{print $5}')
if [ "$RC" = 0 ] \
  && [ -n "$OUT" ] \
  && [ "$KEYCOL" = "K-1" ] \
  && case "$URL" in *"project=tproj"*) true;; *) false;; esac \
  && case "$URL" in *"live=1"*) true;; *) false;; esac; then
  ok
else bad "machines-list rc=$RC url='$URL' keycol='$KEYCOL' out='$OUT'"; fi

# --- 13. machines-list on a 404 => rc nonzero, empty stdout ------------------
: > "$T/req.log"
OUT=$(EXTRA_ENV="CURL_MODE=list404" cli machines-list tproj live); RC=$?
[ "$RC" != 0 ] && [ -z "$OUT" ] \
  && ok || bad "machines-list 404 gave rc=$RC out='$OUT'"

echo "jobs-client-machines.bh-1054-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
