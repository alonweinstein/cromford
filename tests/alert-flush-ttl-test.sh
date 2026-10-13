#!/bin/bash
# tests/alert-flush-ttl-test.sh — the quarantine dead-man valve, with the row.
#
# alert-flush.sh is the reason quarantine can never silence a real fire: after
# 45 minutes anything still queued is force-escalated to the console marked
# [UNTRIAGED 45m]. BH-1070 gives it a second source — the worker's own expired
# claims — without weakening the first one:
#
#   * the DB pass POSTS FIRST and marks the row `new` only on a 2xx, so
#     "delivered" is never recorded for something that was not delivered;
#   * a quarantine entry whose row the box already owns (`"dbrow":true`) is
#     dropped from the file without a send, because the DB pass is what sends
#     it — but ONLY when the claim actually succeeded;
#   * a claim that fails (worker down, route absent) puts every entry back on
#     today's file path, dbrow or not. One duplicate page, never a lost one.
#
# Run from anywhere: tests/alert-flush-ttl-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# ONE anchor for every fixture age in this file.
NOW=$(date -u +%s)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# SAFETY GATE, not a behaviour assertion (c1..c6 below are those). Before this
# slice bin/alert-flush.sh hardcoded H=/root/harness, so driving it here would
# flock and DRAIN THE LIVE quarantine of whatever box this suite runs on. If the
# script has not been made HARNESS-relative, refuse to run it at all.
if ! grep -q 'H="${HARNESS:-/root/harness}"' "$DIR/bin/alert-flush.sh"; then
  echo "FAIL: bin/alert-flush.sh is not HARNESS-relative — refusing to drive it against the live /root/harness quarantine"
  echo "alert-flush-ttl: 0 passed, 1 failed"
  exit 1
fi

mkdir -p "$T/fakebin"
export PATH="$T/fakebin:$PATH"

# The same fake curl as tests/alerts-table-test.sh: the worker answers
# body\n<status>, the console answers the bare status (beat POSTs read it
# through -o /dev/null -w '%{http_code}').
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2 ;;
    --data-binary) BODY="$2"; shift 2 ;;
    -d) BODY="$2"; shift 2 ;;
    -H) shift 2 ;;
    *) shift ;;
  esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in down) exit 7 ;; esac
case "$URL" in
  *jobs.invalid*) [ "${JOBS_MODE:-ok}" = down ] && exit 7 ;;
esac
case "$METHOD $URL" in
  "POST "*console.invalid/api/beat)
    case "${CONSOLE_MODE:-200}" in 500) printf '500' ;; *) printf '200' ;; esac ;;
  "POST "*/api/alerts/flush)
    if [ -s "${FLUSH_JSON:-/nonexistent}" ]; then cat "$FLUSH_JSON"; printf '\n200\n'
    else printf '{"alerts":[],"as_of":"t"}\n200\n'; fi ;;
  "PATCH "*/api/alerts/state) printf '{"alert":{"id":"r1","state":"new"}}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

mktree() { # mktree <dir> <box>
  local d="$1" bx="$2" s
  mkdir -p "$d/bin/lib" "$d/logs" "$d/state" "$d/flags" "$d/env"
  for s in alert-flush.sh jobs-client.sh alert_family.py; do ln -sf "$DIR/bin/$s" "$d/bin/$s"; done
  ln -sf "$DIR/bin/lib/alert-state.sh" "$d/bin/lib/alert-state.sh"
  ln -sf "$DIR/bin/lib/env-path.sh" "$d/bin/lib/env-path.sh"
  # BH-1194: the client is a shim over bin/lib/jobs/ and refuses to half-load, so
  # a fixture that copies jobs-client.sh must copy the modules too.
  mkdir -p "$d/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$d/bin/lib/jobs/"
  printf 'CONSOLE_URL=https://console.invalid\nHARNESS_SECRET=testsecret\nJOBS_URL=https://jobs.invalid\nBOX_NAME=%s\n' \
    "$bx" > "$d/env/global.env"
  printf '%s\n' "$bx" > "$d/state/box-name"
}
flush() { # flush <dir> <req-sink>
  ( export HARNESS="$1" REQ_SINK="$2" ${EXTRA_ENV:-}
    "$DIR/bin/alert-flush.sh" >/dev/null 2>&1 )
}
qentry() { # qentry <dir> <epoch> <payload-json>
  printf '%s\t%s\n' "$2" "$3" >> "$1/state/alert-quarantine.jsonl"
}
# grep -c prints 0 AND exits 1 on no match, so every count goes through one
# helper that keeps the number and drops the rc.
countof() { local n; n=$(grep -c "$1" "$2" 2>/dev/null); printf '%s' "${n:-0}"; }
beats()   { countof 'POST https://console.invalid/api/beat' "$1"; }
patches() { countof 'PATCH .*/api/alerts/state' "$1"; }
body_of() { grep -m1 -- "$2" "$1" 2>/dev/null | sed 's/^[^ ]* [^ ]* //'; }
qlines()  { countof . "$1/state/alert-quarantine.jsonl"; }

# The claim answer: one expired row, 46 minutes old.
jq -nc --arg fs "$(date -u -d "@$((NOW - 2760))" '+%Y-%m-%dT%H:%M:%SZ')" \
  '{alerts:[{id:"r1",family:"0123456789ab",box:"h",project:"p1",state:"quarantined",count:2,
             first_seen:$fs,last_seen:$fs,claimed_by:"",claimed_at:"",notified_at:"",
             severity:"critical",line:"p1 watcher exited rc=1"}],as_of:"t"}' > "$T/flush-one.json"

echo "--- c1: an expired claim is escalated, then and only then marked new"
mktree "$T/h" h; touch "$T/h/flags/alerts-db"
S1="$T/req-c1.log"; : > "$S1"
EXTRA_ENV="FLUSH_JSON=$T/flush-one.json" flush "$T/h" "$S1"
[ "$(beats "$S1")" -eq 1 ] && ok || bad "the expired row produced $(beats "$S1") console beats, want 1"
B=$(body_of "$S1" 'POST https://console.invalid/api/beat')
case "$(jq -r '.line' <<<"$B" 2>/dev/null)" in
  "[UNTRIAGED 45m] p1 watcher exited rc=1") ok ;;
  *) bad "the escalation line is '$(jq -r '.line' <<<"$B" 2>/dev/null)', want the [UNTRIAGED 45m] prefix and the row's line" ;;
esac
[ "$(jq -r '.triaged' <<<"$B" 2>/dev/null)" = "true" ] \
  && ok || bad "the escalation is not marked triaged:true — the state machine would dedupe it away: $B"
[ "$(jq -r '.akey' <<<"$B" 2>/dev/null)" = "orclane:r1" ] \
  && ok || bad "the escalation akey is '$(jq -r '.akey' <<<"$B" 2>/dev/null)', want orclane:r1"
[ "$(jq -r '.project' <<<"$B" 2>/dev/null)" = "p1" ] \
  && ok || bad "the escalation lost the row's project (it would land in General): $B"
FB=$(body_of "$S1" 'POST .*/api/alerts/flush')
[ "$(jq -r '.box' <<<"$FB" 2>/dev/null)" = "h" ] \
  && ok || bad "the claim did not name this box: '$FB'"
[ "$(patches "$S1")" -eq 1 ] && ok || bad "$(patches "$S1") state PATCHes after a delivered escalation, want 1"
PB=$(body_of "$S1" 'PATCH .*/api/alerts/state')
[ "$(jq -r '.state' <<<"$PB" 2>/dev/null)" = "new" ] && [ "$(jq -r '.id' <<<"$PB" 2>/dev/null)" = "r1" ] \
  && ok || bad "the delivered row was not moved to new: '$PB'"

echo "--- c2: nothing claimed, nothing sent"
S2="$T/req-c2.log"; : > "$S2"
flush "$T/h" "$S2"
[ "$(beats "$S2")" -eq 0 ] && ok || bad "an empty claim still sent $(beats "$S2") beats"

echo "--- c3: a console 500 leaves the claim for the lease"
mktree "$T/h3" h3; touch "$T/h3/flags/alerts-db"
S3="$T/req-c3.log"; : > "$S3"
EXTRA_ENV="FLUSH_JSON=$T/flush-one.json CONSOLE_MODE=500" flush "$T/h3" "$S3"
[ "$(beats "$S3")" -eq 1 ] && ok || bad "the escalation was not attempted at all"
[ "$(patches "$S3")" -eq 0 ] \
  && ok || bad "a 500 from the console was recorded as delivered — the alert is now lost to both paths"

echo "--- c4: a claimed entry is dropped from the file without a second send"
mktree "$T/h4" h4; touch "$T/h4/flags/alerts-db"
qentry "$T/h4" "$((NOW - 3000))" '{"kind":"fleet_alert","project":"p1","akey":"orclane:r1","line":"the claimed one","dbrow":true}'
qentry "$T/h4" "$((NOW - 3000))" '{"kind":"fleet_alert","project":"p2","akey":"orclane:r2","line":"the unclaimed one"}'
S4="$T/req-c4.log"; : > "$S4"
flush "$T/h4" "$S4"
[ "$(beats "$S4")" -eq 1 ] \
  && ok || bad "$(beats "$S4") console beats, want 1 (the dbrow entry is the DB pass's job, the plain one is the file's)"
B4=$(body_of "$S4" 'POST https://console.invalid/api/beat')
[ "$(jq -r '.line' <<<"$B4" 2>/dev/null)" = "[UNTRIAGED 45m] the unclaimed one" ] \
  && ok || bad "the wrong entry was escalated: '$(jq -r '.line' <<<"$B4" 2>/dev/null)'"
[ "$(qlines "$T/h4")" -eq 0 ] && ok || bad "the quarantine still holds $(qlines "$T/h4") expired entries"

echo "--- c5: flag absent = today's file valve, byte for byte"
mktree "$T/h5" h5
qentry "$T/h5" "$((NOW - 3000))" '{"kind":"fleet_alert","project":"p1","akey":"orclane:old","line":"the old one"}'
qentry "$T/h5" "$((NOW - 60))"   '{"kind":"fleet_alert","project":"p1","akey":"orclane:young","line":"the young one"}'
S5="$T/req-c5.log"; : > "$S5"
flush "$T/h5" "$S5"
[ "$(beats "$S5")" -eq 1 ] && ok || bad "flag absent: $(beats "$S5") beats, want 1 (only the entry past the cutoff)"
[ "$(jq -r '.line' <<<"$(body_of "$S5" 'POST https://console.invalid/api/beat')" 2>/dev/null)" = "[UNTRIAGED 45m] the old one" ] \
  && ok || bad "flag absent: the wrong entry was escalated"
[ "$(qlines "$T/h5")" -eq 1 ] && grep -q "$((NOW - 60))" "$T/h5/state/alert-quarantine.jsonl" \
  && ok || bad "flag absent: the young entry must stay queued WITH its timestamp: $(cat "$T/h5/state/alert-quarantine.jsonl")"
[ "$(countof '/api/alerts' "$S5")" -eq 0 ] \
  && ok || bad "flag absent still called the alerts API: $(grep '/api/alerts' "$S5" | head -2)"

echo "--- c6: a failed claim puts EVERY entry back on today's path"
mktree "$T/h6" h6; touch "$T/h6/flags/alerts-db"
qentry "$T/h6" "$((NOW - 3000))" '{"kind":"fleet_alert","project":"p1","akey":"orclane:r1","line":"the claimed one","dbrow":true}'
qentry "$T/h6" "$((NOW - 3000))" '{"kind":"fleet_alert","project":"p2","akey":"orclane:r2","line":"the unclaimed one"}'
S6="$T/req-c6.log"; : > "$S6"
EXTRA_ENV="JOBS_MODE=down FLUSH_JSON=$T/flush-one.json" flush "$T/h6" "$S6"
[ "$(beats "$S6")" -eq 2 ] \
  && ok || bad "with the worker down BOTH expired entries must escalate; got $(beats "$S6") beats"
[ "$(patches "$S6")" -eq 0 ] && ok || bad "a row was marked delivered while the worker was unreachable"
[ "$(qlines "$T/h6")" -eq 0 ] && ok || bad "the quarantine was not drained on the fallback path"

echo "alert-flush-ttl: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
