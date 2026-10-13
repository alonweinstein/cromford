#!/bin/bash
# tests/jobs-client-settings-test.sh — the operator-knob client, driven for real.
#
# THE PROPERTY UNDER TEST: a consumer that reads a threshold every tick must be
# able to tell the three answers apart. rc 0 = here is the number. rc 2 = there
# is no row, use your documented fallback. rc 1 = the worker did not answer, so
# use your fallback too — a blip must never look like an operator lowering a
# threshold. A worker that predates /api/settings answers 404, which is the same
# "no row" answer, so this file also pins the pre-deploy behaviour.
#
# Driven, not grepped: it sources the REAL bin/jobs-client.sh against a stubbed
# curl and reads back rcs, stdout and the PUT body, and drives the CLI verbs
# through the script's own dispatch.
# Run from anywhere: tests/jobs-client-settings-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/logs" "$T/state" "$T/bin" "$T/env" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
echo "HARNESS_SECRET=test-secret" > "$T/env/global.env"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# How many requests the stub recorded. Readability tested BEFORE the redirect:
# `2>/dev/null` on wc does not suppress the SHELL's message for a failed `<`.
reqs() { if [ -f "$T/req.log" ]; then wc -l < "$T/req.log"; else echo 0; fi; }

# GET /api/settings/<key> answers from $SETTING_JSON; PUT /api/settings echoes a
# row back. CURL_MODE picks the failure being modelled.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in
  down)   exit 7 ;;
  old)    printf '{"error":"not found"}\n404\n'; exit 0 ;;
  reject) printf '{"error":"key must match ^[a-z0-9_.-]{1,64}$"}\n400\n'; exit 0 ;;
esac
case "$METHOD $URL" in
  "PUT "*/api/settings)  printf '{"setting":{"key":"gh_budget_min_remaining","value":"700"}}\n200\n' ;;
  "GET "*/api/settings/*)
    if [ -s "${SETTING_JSON:-/nonexistent}" ]; then cat "$SETTING_JSON"; printf '\n200\n'
    else printf '{"error":"not found"}\n404\n'; fi ;;
  *) printf '{}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

stub() { printf '%s' "$1" > "$T/setting.json"; }
# Sourced, so the helpers under test are the real ones, not a re-implementation.
fn() { # fn <function> [args...]   -> stdout on fd 1, rc as the caller's rc
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid SETTING_JSON="$T/setting.json" \
           REQ_SINK="${REQ_SINK:-$T/req.log}" ${EXTRA_ENV:-}
    # shellcheck source=/dev/null
    . "$T/bin/jobs-client.sh" 2>/dev/null
    "$@" )
}
cli() { # cli <verb> [args...]
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid SETTING_JSON="$T/setting.json" \
           REQ_SINK="${REQ_SINK:-$T/req.log}" ${EXTRA_ENV:-}
    bash "$T/bin/jobs-client.sh" "$@" 2>/dev/null )
}

# --- 1. the row exists: the value, and only the value, on stdout -------------
stub '{"key":"gh_budget_min_remaining","setting":{"key":"gh_budget_min_remaining","value":"1500"},"source":"settings"}'
OUT=$(fn setting_get gh_budget_min_remaining); RC=$?
[ "$OUT" = "1500" ] && [ "$RC" = 0 ] && ok || bad "setting_get printed '$OUT' rc=$RC, wanted 1500 rc 0"

# --- 2. no row is a real answer: rc 2, nothing on stdout ---------------------
stub '{"key":"nope","setting":null,"source":"none"}'
OUT=$(fn setting_get nope); RC=$?
[ "$RC" = 2 ] && [ -z "$OUT" ] && ok || bad "an absent row gave rc=$RC out='$OUT', wanted rc 2 and no value"

# --- 3. the worker is down: rc 1, never a number -----------------------------
stub '{"setting":{"value":"1500"}}'
OUT=$(EXTRA_ENV="CURL_MODE=down" fn setting_get gh_budget_min_remaining); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "an outage gave rc=$RC out='$OUT', wanted rc 1 (caller falls back)"

# --- 4. a worker that predates /api/settings: 404 = no row = rc 2 ------------
OUT=$(EXTRA_ENV="CURL_MODE=old" fn setting_get gh_budget_min_remaining); RC=$?
[ "$RC" = 2 ] && [ -z "$OUT" ] && ok || bad "a pre-deploy worker (404) gave rc=$RC, wanted rc 2"

# --- 5. setting_set sends the knob as JSON, with this box as the actor -------
rm -f "$T/req.log"
fn setting_set gh_budget_min_remaining 700 "why" >/dev/null; RC=$?
LINE=$(grep -m1 'PUT .*/api/settings ' "$T/req.log" 2>/dev/null)
BODY=${LINE#PUT * }
if [ "$RC" = 0 ] && [ -n "$BODY" ] \
  && [ "$(printf '%s' "$BODY" | jq -r '.key')" = "gh_budget_min_remaining" ] \
  && [ "$(printf '%s' "$BODY" | jq -r '.value')" = "700" ] \
  && [ "$(printf '%s' "$BODY" | jq -r '.value|type')" = "string" ] \
  && [ "$(printf '%s' "$BODY" | jq -r '.note')" = "why" ] \
  && [ -n "$(printf '%s' "$BODY" | jq -r '.actor // empty')" ]; then ok
else bad "setting_set rc=$RC sent body '$BODY'"; fi

# --- 6. a refused write is a failure, never laundered into success -----------
RC=0; EXTRA_ENV="CURL_MODE=reject" fn setting_set gh_budget_min_remaining 700 >/dev/null || RC=$?
[ "$RC" = 1 ] && ok || bad "a 400 from the worker came back as rc=$RC, wanted rc 1"

# --- 7. the CLI verbs an operator actually types -----------------------------
stub '{"key":"gh_budget_min_remaining","setting":{"key":"gh_budget_min_remaining","value":"1500"},"source":"settings"}'
OUT=$(cli setting-get gh_budget_min_remaining); RC=$?
stub '{"key":"nope","setting":null,"source":"none"}'
OUT2=$(cli setting-get nope); RC2=$?
RC3=0; cli setting-set gh_budget_min_remaining 700 "from the cli" >/dev/null || RC3=$?
[ "$(printf '%s' "$OUT" | tr -d '\n')" = "1500" ] && [ "$RC" = 0 ] && [ "$RC2" = 2 ] && [ "$RC3" = 0 ] \
  && ok || bad "CLI setting-get printed '$OUT' rc=$RC, absent key exited $RC2, setting-set exited $RC3 (wanted 1500/0, 2, 0)"

# --- 8. an illegal key never becomes a URL -----------------------------------
# A key with a space or a slash is a CALLER bug, and the client refuses it here
# rather than posting it: `/api/settings/a/b` is a different route entirely, and
# `/api/settings/bad key` would come back as a worker 400 logged as an http
# failure, which reads in logs/jobs-client.log exactly like the worker misbehaving.
BADFAIL=0
for BADKEY in 'bad key' 'a/b' 'GH_BUDGET' '../secrets' '' "$(printf 'a%.0s' $(seq 1 65))"; do
  rm -f "$T/req.log"
  OUT=$(fn setting_get "$BADKEY"); RC=$?
  SENT=$(reqs)
  if [ "$RC" != 1 ] || [ -n "$OUT" ] || [ "${SENT:-0}" -ne 0 ]; then
    BADFAIL=1; bad "setting_get '$BADKEY' gave rc=$RC out='$OUT' and sent $SENT request(s), wanted rc 1 and none"
    continue
  fi
  rm -f "$T/req.log"
  RCS=0; fn setting_set "$BADKEY" 700 >/dev/null || RCS=$?
  SENT=$(reqs)
  if [ "$RCS" != 1 ] || [ "${SENT:-0}" -ne 0 ]; then
    BADFAIL=1; bad "setting_set '$BADKEY' gave rc=$RCS and sent $SENT request(s), wanted rc 1 and none"
  fi
done
[ "$BADFAIL" -eq 0 ] && ok

# --- 9. no secret is an outage, not a number ---------------------------------
# Inherited from _jobs_req, and pinned here because "no credential" is the one
# failure that could plausibly have been written as "no row".
mkdir -p "$T/nosecret"
# Two traps: $0 must NOT be the script path (BASH_SOURCE[0] = "$0" is how the
# file tells "sourced" from "executed", and an equal pair runs the CLI dispatch
# instead of defining the function), and the secret is unset INSIDE the child —
# a box running this test has a real HARNESS_SECRET in its own environment.
OUT=$( PATH="$T/fakebin:$PATH" HARNESS="$T/nosecret" JOBS_URL=https://jobs.invalid \
       SETTING_JSON="$T/setting.json" \
       bash -c "unset HARNESS_SECRET; . \"\$1\"; setting_get gh_budget_min_remaining" no-secret-case "$T/bin/jobs-client.sh" 2>/dev/null ); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "HARNESS_SECRET unset gave rc=$RC out='$OUT', wanted rc 1"

echo "jobs-client-settings-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
