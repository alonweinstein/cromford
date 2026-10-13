#!/bin/bash
# tests/extra-usage-xcheck.bh-167-test.sh — BH-1915 (BH-167.2): after each run,
# bin/extra-usage-track.sh compares the vendor meter delta with the dollars in
# cost_rows for every login it polled ok, and says so ONCE when they disagree.
#
# DRIVEN, NOT GREPPED. The real script runs in a sandbox against the same
# fixture usage endpoint as tests/extra-usage-logins-test.sh, the REAL
# lane-alert + alert-state machine, and a curl stub that answers
# GET /api/metrics/account-usage?window=5h|7d from fixture files in the exact
# shape worker/jobs/src/lib/account-usage.js documents. Every assertion reads
# what reached the beat (the console), the request log, the CSV or the run log.
#
#   T3a  comparable, 60% gap over a 10% knob: one alert, with the numbers
#   T3b  the same run again: nothing new (lane-alert dedupe by id)
#   T3c  no alert: unmeasured, gap == knob, delta under the floor, HTTP 500,
#        no accounts key, a label this box did not poll ok
#   T3d  back within the knob: one resolve, then silence
#   T3d2 a failed read never clears, even when the other window is within
#   T3e  the knob moves the threshold; a non-numeric knob falls back and says so
#   T3f  a box whose only login 429s makes no account-usage request at all
# Run from anywhere: tests/extra-usage-xcheck.bh-167-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
trap 'scratch_cleanup; [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null' EXIT
mkdir -p "$T/bin" "$T/env" "$T/logs" "$T/state" "$T/flags" "$T/catalog" "$T/cfg-own" "$T/cfg-mk" "$T/cfg-setup" "$T/fx"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing — skipping"; exit 0; }

cp "$DIR/bin/extra-usage-track.sh" "$T/bin/"
cp "$DIR/bin/jobs-client.sh"       "$T/bin/"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
# scratch-closure-allow: BH-4080 the lane under test runs under env -i or in its own harness root, so HARNESS_DEPLOYMENT_FILE does not reach it and bin/lib/deployment.sh must sit beside its copied libs
cp "$DIR/bin/lib/deployment.sh" "$T/bin/lib/"  # BH-4080: req.sh builds the worker URL from it
chmod +x "$T/bin/extra-usage-track.sh"
echo "HARNESS_SECRET=test-secret" > "$T/env/global.env"

cat > "$T/bin/oauth-refresh.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$T/bin/oauth-refresh.sh"

# The REAL lane-alert and alert state machine; the stub is one layer down at
# beat.sh, so "$T/alerts" is what would have reached the console.
ln -sf "$DIR/bin/lane-alert.sh" "$T/bin/lane-alert.sh"
mkdir -p "$T/bin/lib"; ln -sf "$DIR/bin/lib/alert-state.sh" "$T/bin/lib/alert-state.sh"
ln -sf "$DIR/bin/alert_family.py" "$T/bin/alert_family.py"
# TEST-CHANGE (BH-4054): lane-alert.sh --resolve also sends a console twin
# (kind "alert", akey alert:<id>) carrying the same line. It goes to its own
# sink so "$T/alerts" still counts the lane's decisions; T3d asserts the twin.
cat > "$T/bin/beat.sh" <<'EOF'
#!/bin/bash
if [ "$(jq -r '.kind // ""' <<<"${1:-}")" = alert ]; then
  jq -r '.akey // ""' <<<"${1:-}" >> "$ALERT_SINK.twin"
else
  jq -r '.line // ""' <<<"${1:-}" >> "$ALERT_SINK"
fi
exit 0
EOF
chmod +x "$T/bin/beat.sh"

# curl is jobs-client's transport. Every request is logged; the account-usage
# route answers its per-window fixture with a per-window status, everything
# else answers the logins suite's {"snapshot":{}}.
mkdir -p "$T/fakebin"
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}") ;; esac
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "$URL" in
  *'/api/metrics/account-usage?window=5h')
    cat "$XCHECK_FIXTURE_5H"; printf '\n%s\n' "${XCHECK_STATUS_5H:-${XCHECK_STATUS:-200}}"; exit 0 ;;
  *'/api/metrics/account-usage?window=7d')
    cat "$XCHECK_FIXTURE_7D"; printf '\n%s\n' "${XCHECK_STATUS_7D:-${XCHECK_STATUS:-200}}"; exit 0 ;;
esac
printf '{"snapshot":{}}\n200\n'
CURL
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"

# The usage endpoint. live-own sits inside its credits (no overage/cap alert of
# its own, so the sink holds only what this lane says); setup-tok gets 429.
cat > "$T/server.py" <<'PY'
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
BODY = {"five_hour": {"utilization": 10}, "seven_day": {"utilization": 42, "resets_at": "2026-09-21T00:00:00Z"},
        "extra_usage": {"is_enabled": True, "used_credits": 1200, "monthly_limit": 3500000,
                        "utilization": 0, "decimal_places": 2, "spend_limit_reached": False}}
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        tok = (self.headers.get("Authorization") or "").replace("Bearer ", "")
        if tok == "live-own":
            b = json.dumps(BODY).encode()
            self.send_response(200); self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
        elif tok == "setup-tok":
            self.send_error(429, "Too Many Requests")
        else:
            self.send_error(403, "OAuth token does not meet scope requirement user:profile")
    def log_message(self, *a):
        pass
s = HTTPServer(("127.0.0.1", 0), H)
print(s.server_port, flush=True)
s.serve_forever()
PY
python3 "$T/server.py" > "$T/port" 2>/dev/null &
SRV_PID=$!
for _ in $(seq 1 50); do [ -s "$T/port" ] && break; sleep 0.1; done
PORT=$(cat "$T/port" 2>/dev/null)
[ -n "$PORT" ] && ok || { echo "FAIL: the fixture usage endpoint did not start"; echo "extra-usage-xcheck: 0 pass, 1 fail"; exit 1; }
OAUTH_USAGE_URL="http://127.0.0.1:$PORT/api/oauth/usage"

cred() { # cred <dir> <token>
  printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"r","expiresAt":99999999999999}}\n' "$2" > "$1/.credentials.json"
}
cred "$T/cfg-own"   live-own
cred "$T/cfg-mk"    live-own
cred "$T/cfg-setup" setup-tok

# fx <file> <window> <label> comparable <meter_delta> <rows> <gap_pct> <unpriced>
# fx <file> <window> <label> unmeasured
#   One account-usage response in the contract shape. The unmeasured variant
#   carries NO gap keys, exactly as the JSDoc says.
#   The span and window instants are built off one captured NOW, not frozen
#   calendar dates: the request asks for a rolling ?window=, so the answer it
#   stands in for is always "the last 5h/7d" (the #360 rule).
NOW=$(date -u +%s)
iso_ago() { date -u -d "@$((NOW - $1))" +%Y-%m-%dT%H:%M:%SZ; }
W_FROM=$(iso_ago 18000); W_TO=$(iso_ago 0); S_TO=$(iso_ago 900)
fx() {
  local f="$1" w="$2" label="$3" state="$4" cc
  if [ "$state" = comparable ]; then
    cc=$(jq -nc --argjson m "$5" --argjson r "$6" --argjson g "$7" --argjson u "$8" \
      --arg sf "$W_FROM" --arg st "$S_TO" '{state:"comparable",meter_delta_usd:$m,rows_usd:$r,unpriced_in_span:$u,gap_usd:($m-$r),gap_pct:$g,
        span_from:$sf,span_to:$st}')
  else
    cc=$(jq -nc --arg s "$state" '{state:$s,reason:"fixture"}')
  fi
  jq -nc --arg w "$w" --arg label "$label" --argjson cc "$cc" --arg from "$W_FROM" --arg to "$W_TO" '{
    window:$w, from:$from, to:$to,
    accounts:[{account:"acct@example.com", calls:12, usd:20, unpriced_calls:0, input_toks:1, output_toks:1,
      cache_read:0, cache_write:0, untokened_calls:0, first_ts:null, last_ts:null, projects:[],
      meter:{label:$label, session_pct:10, weekly_pct:42, weekly_resets_at:null, extra_used_usd:12, polls:20},
      cross_check:$cc}],
    totals:{calls:12, usd:20, unpriced_calls:0, input_toks:1, output_toks:1, cache_read:0, cache_write:0},
    truncated:{groups:false, projects:false, snapshots:false}}' > "$f"
}

run() { # run [env=val ...] — one tracker run in the sandbox
  : > "$T/reqs"; : > "$T/alerts"; : > "$T/alerts.twin"; : > "$T/logs/agent-rules.log"
  env -i PATH="$PATH" HOME="$T" HARNESS="$T" CLAUDE_CONFIG_DIR="$T/cfg-own" \
    OAUTH_USAGE_URL="$OAUTH_USAGE_URL" REQ_SINK="$T/reqs" ALERT_SINK="$T/alerts" \
    XCHECK_FIXTURE_5H="$T/fx/5h.json" XCHECK_FIXTURE_7D="$T/fx/7d.json" \
    EXTRA_USAGE_LOGINS="mk=$T/cfg-mk" "$@" bash "$T/bin/extra-usage-track.sh" hub >"$T/out" 2>"$T/err"
}
reset_state() { rm -rf "$T/logs"/*.csv "$T/state"/* "$T/flags"/* 2>/dev/null; : > "$T/logs/ALERTS.log"; }
n_xc() { grep -c 'ACCOUNT USAGE \[' "$T/alerts" 2>/dev/null; }

# ===========================================================================
# T3a. 60% gap over a 10% knob fires once, with the numbers
# ===========================================================================
reset_state
fx "$T/fx/5h.json" 5h mk comparable 50 20 60 3
fx "$T/fx/7d.json" 7d mk unmeasured
run
[ "$(grep -c 'ACCOUNT USAGE \[mk\]' "$T/alerts")" = 1 ] \
  && ok || bad "T3a: a 60% gap did not raise exactly one alert: $(cat "$T/alerts")"
grep -qF 'ACCOUNT USAGE [mk]: cost rows say $20.00 over 5h, the meter moved $50.00 (gap 60.0%, threshold 10%); 3 unpriced rows in span.' "$T/alerts" \
  && ok || bad "T3a: alert text is wrong: $(cat "$T/alerts")"
grep -q 'account-usage?window=5h' "$T/reqs" && grep -q 'account-usage?window=7d' "$T/reqs" \
  && ok || bad "T3a: both windows were not read: $(cat "$T/reqs")"
tail -1 "$T/logs/extra-usage-mk.csv" 2>/dev/null | grep -q ',ok$' \
  && ok || bad "T3a: the meter row was not written"
grep -q 'extra-usage-track xcheck: gap threshold 10% (code default), meter floor \$1 (code default), ok logins: mk' "$T/logs/agent-rules.log" \
  && ok || bad "T3a: the per-run threshold line is missing: $(cat "$T/logs/agent-rules.log")"

# ===========================================================================
# T3b. the same run again says nothing new
# ===========================================================================
run
[ "$(n_xc)" = 0 ] && ok || bad "T3b: an identical run re-fired: $(cat "$T/alerts")"

# ===========================================================================
# T3c. none of these may fire (each from a clean alert state)
# ===========================================================================
reset_state; fx "$T/fx/5h.json" 5h mk unmeasured; fx "$T/fx/7d.json" 7d mk unmeasured; run
[ "$(n_xc)" = 0 ] && ok || bad "T3c-unmeasured fired: $(cat "$T/alerts")"

reset_state; fx "$T/fx/5h.json" 5h mk comparable 50 45 10 0; fx "$T/fx/7d.json" 7d mk unmeasured; run
[ "$(n_xc)" = 0 ] && ok || bad "T3c-equal: a gap equal to the knob fired: $(cat "$T/alerts")"

reset_state; fx "$T/fx/5h.json" 5h mk comparable 0.5 0 100 0; fx "$T/fx/7d.json" 7d mk unmeasured; run
[ "$(n_xc)" = 0 ] && ok || bad "T3c-floor: a \$0.50 meter delta fired: $(cat "$T/alerts")"

reset_state; fx "$T/fx/5h.json" 5h mk comparable 50 20 60 3; fx "$T/fx/7d.json" 7d mk comparable 50 20 60 3
run XCHECK_STATUS=500
[ "$(n_xc)" = 0 ] && ok || bad "T3c-500: a failed read fired: $(cat "$T/alerts")"
[ "$(grep -c 'xcheck\[5h\]: account-usage read unusable' "$T/logs/agent-rules.log")" = 1 ] \
  && ok || bad "T3c-500: no single 5h failed-read line: $(cat "$T/logs/agent-rules.log")"
[ "$(grep -c 'xcheck\[7d\]: account-usage read unusable' "$T/logs/agent-rules.log")" = 1 ] \
  && ok || bad "T3c-500: no single 7d failed-read line: $(cat "$T/logs/agent-rules.log")"

reset_state; printf '{"snapshot":{}}' > "$T/fx/5h.json"; printf 'not json' > "$T/fx/7d.json"; run
[ "$(n_xc)" = 0 ] && ok || bad "T3c-nokey fired: $(cat "$T/alerts")"
grep -q 'xcheck\[5h\]: account-usage read unusable (no accounts key)' "$T/logs/agent-rules.log" \
  && grep -q 'xcheck\[7d\]: account-usage read unusable (no accounts key)' "$T/logs/agent-rules.log" \
  && ok || bad "T3c-nokey: a body with no accounts key was not logged as unusable: $(cat "$T/logs/agent-rules.log")"

reset_state; fx "$T/fx/5h.json" 5h other comparable 50 20 60 3; fx "$T/fx/7d.json" 7d other comparable 50 20 60 3; run
[ "$(n_xc)" = 0 ] && ok || bad "T3c-label: an account this box did not poll fired: $(cat "$T/alerts")"

# ===========================================================================
# T3d. back within the knob: one resolve, then silence
# ===========================================================================
reset_state; fx "$T/fx/5h.json" 5h mk comparable 50 20 60 3; fx "$T/fx/7d.json" 7d mk unmeasured; run
[ "$(n_xc)" = 1 ] && ok || bad "T3d: setup fire did not happen: $(cat "$T/alerts")"
fx "$T/fx/5h.json" 5h mk comparable 50 47.5 5 0; run
[ "$(n_xc)" = 1 ] && grep -q 'RESOLVED.*ACCOUNT USAGE \[mk\]: cost rows and the meter agree again (gap 5.0% in 5h, threshold 10%)' "$T/alerts" \
  && ok || bad "T3d: a 5% gap did not resolve exactly once: $(cat "$T/alerts")"
[ "$(grep -c '^alert:' "$T/alerts.twin")" = 1 ] && ok || bad "T3d: the resolve's console twin was not sent once: $(cat "$T/alerts.twin")"
run
[ "$(n_xc)" = 0 ] && ok || bad "T3d: a second within run said something: $(cat "$T/alerts")"

# ===========================================================================
# T3d2. a failed read never clears (it may be the window that is over)
# ===========================================================================
reset_state; fx "$T/fx/5h.json" 5h mk comparable 50 20 60 3; fx "$T/fx/7d.json" 7d mk unmeasured; run
fx "$T/fx/5h.json" 5h mk comparable 50 47.5 5 0; run XCHECK_STATUS_7D=500
[ "$(n_xc)" = 0 ] && ok || bad "T3d2: a clear went out with the 7d read failed: $(cat "$T/alerts")"
run
[ "$(n_xc)" = 1 ] && grep -q 'agree again' "$T/alerts" \
  && ok || bad "T3d2: the clear did not follow once both reads succeeded: $(cat "$T/alerts")"

# ===========================================================================
# T3e. the knob moves the threshold; a bad knob falls back and says so
# ===========================================================================
reset_state; fx "$T/fx/5h.json" 5h mk comparable 50 20 60 3; fx "$T/fx/7d.json" 7d mk unmeasured
run EXTRA_USAGE_XCHECK_GAP_PCT=70
[ "$(n_xc)" = 0 ] && ok || bad "T3e: a 60% gap fired under a 70% knob: $(cat "$T/alerts")"
grep -q 'gap threshold 70% (env/settings)' "$T/logs/agent-rules.log" \
  && ok || bad "T3e: the 70% knob is not logged with its source: $(cat "$T/logs/agent-rules.log")"
reset_state
run EXTRA_USAGE_XCHECK_GAP_PCT=abc
[ "$(n_xc)" = 1 ] && grep -q 'threshold 10%)' "$T/alerts" \
  && ok || bad "T3e: a non-numeric knob did not fall back to 10: $(cat "$T/alerts")"
grep -q "gap threshold 10% (code default (rejected 'abc' from env/settings))" "$T/logs/agent-rules.log" \
  && ok || bad "T3e: the rejected knob value is not logged: $(cat "$T/logs/agent-rules.log")"

# ===========================================================================
# T3f. a box whose only login 429s asks the route nothing
# ===========================================================================
reset_state
run EXTRA_USAGE_LOGINS="mk=$T/cfg-setup"
[ "$(grep -c account-usage "$T/reqs")" = 0 ] \
  && ok || bad "T3f: a box with no ok login still read account-usage: $(cat "$T/reqs")"
tail -1 "$T/logs/extra-usage-mk.csv" 2>/dev/null | grep -q ',no-login$' \
  && ok || bad "T3f: the no-login meter row was not written"
grep -q 'ok logins: none' "$T/logs/agent-rules.log" \
  && ok || bad "T3f: the per-run line does not say no login polled ok: $(cat "$T/logs/agent-rules.log")"

echo "extra-usage-xcheck: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
