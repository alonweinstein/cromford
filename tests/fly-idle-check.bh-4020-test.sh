#!/bin/bash
# tests/fly-idle-check.bh-4020-test.sh — bin/fly-idle-check.sh (BH-4020, split
# child 3 of #3989): the daily hub lane that flags Fly machines that are
# `started`, up longer than FLY_IDLE_HOURS, and doing nothing the harness knows
# of, and writes ONE ALERTS line per UTC day with each one's hourly burn.
#
# WHY. The 2026-10-03 cost report found 42 machines in the org, 25 running, and
# no way to see which of them were idle until the bill arrived.
#
# Every case runs the REAL bin/fly-idle-check.sh through its entry point, in a
# scratch HARNESS whose bin/ links the repo's scripts (the lane itself is a COPY
# so the mutation runs can break it), with a stub `curl` on PATH answering the
# Fly Machines API from fixture files and logging every request it sees.
#   C1  a 3h-idle machine -> one ALERTS line: app/mid, up 3h, $<rate*3600>/h;
#       the token text is in neither the log nor ALERTS
#   C2  a pool build's state json makes the machine active
#   C3  a dispatcher job (state/fly/<p>.json + <p>-active.json) is active; the
#       same record without -active.json is NOT, so the machine is flagged
#   C4  a same-day rerun adds no line (already alerted); the next day adds one
#   C5  1h59m, stopped, no-age and ignored-app machines are never flagged;
#       C5b a machine with no guest size alerts as `burn unpriced`
#   C6a apps HTTP 500 -> rc!=0, one ALERTS line naming HTTP 500, never "0 idle"
#   C6b no token -> `not configured`, rc 0, no alert
#   C7a every request the stub saw is a GET; C7b no stop/destroy/POST in source
#   C8  25 idle -> 20 listed, `... and 5 more`
#   C9  FLY_IDLE_MAX_APPS=1 -> `partial: 1 apps not checked`, b never read
#   C10 a claimed queue row naming the machine makes it active (queue=read);
#       a 500 or non-JSON queue answer still flags it (queue=unread(...));
#       500 rows read as queue=truncated and the claim still counts
#   M1  `-gt "$LIMIT"` flipped to `-lt` turns C1/C5 red
#   M2  the active check forced false turns C2 red
#   M3  the queue-claim test dropped from is_active turns C10 red
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/fly-idle-check.bh-4020-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRC="$DIR/bin/fly-idle-check.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); [ "${QUIET:-0}" = 1 ] || echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# C7b's precondition, first: an absent or empty script must not pass a grep.
if [ ! -s "$SRC" ]; then echo "FAIL: C7b bin/fly-idle-check.sh is missing or empty"; exit 1; fi

NOW=1790000000   # determinism: ok pinned — the lane's clock is FLY_IDLE_NOW
export FLY_IDLE_NOW=$NOW
H="$T/h"; export HARNESS="$H"
mkdir -p "$H/bin" "$H/logs" "$H/env" "$H/flags" "$H/state" "$T/fake" "$T/fx" "$T/req" "$T/tmp"
for f in "$DIR"/bin/* ; do
  [ "$(basename "$f")" = fly-idle-check.sh ] && continue
  ln -s "$f" "$H/bin/$(basename "$f")"
done
cp "$SRC" "$H/bin/fly-idle-check.sh"; chmod +x "$H/bin/fly-idle-check.sh"
ln -s "$DIR/catalog" "$H/catalog"
LANE="$H/bin/fly-idle-check.sh"
export TMPDIR="$T/tmp" HARNESS_ENV_DIR="$H/env" ENDPOINT_FLY_MACHINES=http://stub
export PATH="$T/fake:$PATH" STUB_DIR="$T"
# The queue read is configured per case through global.env, never by ambient env.
unset HARNESS_SECRET JOBS_URL
ALERTS="$H/logs/ALERTS.log"; LOG="$H/logs/fly-idle-check.log"
TOKEN_LINE='FLY_API_TOKEN="FlyV1 fm2_x"'

# ── the Fly Machines API, as a curl stub ─────────────────────────────────────
# Fixtures: $T/fx/apps.json (+ apps.code), $T/fx/m-<app>.json (+ m-<app>.code),
# $T/fx/queue.json (+ queue.code) for the jobs worker at http://jobs. A request
# with no -o (the jobs client) gets the body, a newline and the code, as
# `-w '\n%{http_code}'` would print them.
cat > "$T/fake/curl" <<'SH'
#!/bin/bash
D="$STUB_DIR"; M=GET; URL=""; OUT=""; DATA=0
printf '%s\n' "$*" | sed 's/Bearer [^ ]* [^ ]*/Bearer <redacted>/' >> "$D/req/argv.lines"
while [ $# -gt 0 ]; do
  case "$1" in
    -X|--request) M="$2"; shift 2 ;;
    -d|--data|--data-binary|--data-raw) DATA=1; shift 2 ;;
    -o) OUT="$2"; shift 2 ;;
    -H|-m|--connect-timeout|-w) shift 2 ;;
    http*) URL="$1"; shift ;;
    *) shift ;;
  esac
done
[ "$DATA" = 1 ] && M="$M+DATA"
printf '%s %s\n' "$M" "$URL" | tee -a "$D/ever.lines" >> "$D/req/all.lines"
body=""; code=404
case "$URL" in
  http://stub/v1/apps\?org_slug=*) body="$D/fx/apps.json"; code=$(cat "$D/fx/apps.code" 2>/dev/null || echo 200) ;;
  http://stub/v1/apps/*/machines) a=${URL#http://stub/v1/apps/}; a=${a%/machines}
    body="$D/fx/m-$a.json"; code=$(cat "$D/fx/m-$a.code" 2>/dev/null || echo 200) ;;
  http://jobs/api/queue\?status=claimed\&limit=500) body="$D/fx/queue.json"; code=$(cat "$D/fx/queue.code" 2>/dev/null || echo 200) ;;
esac
if [ -n "$OUT" ]; then { [ -f "$body" ] && cat "$body" || printf '{}'; } > "$OUT"
else { [ -f "$body" ] && cat "$body"; printf '\n'; }; fi
printf '%s' "$code"
SH
chmod +x "$T/fake/curl"

# mach <id> <state> <start-epoch|-> [kind cpus mem | noguest] — one machine
mach() {
  local id="$1" st="$2" since="$3" kind="${4:-performance}" cpus="${5:-8}" mem="${6:-16384}"
  jq -nc --arg id "$id" --arg st "$st" --arg s "$since" --arg k "$kind" \
     --argjson c "${cpus:-0}" --argjson m "${mem:-0}" '
    {id:$id, state:$st, events:(if $s == "-" then [] else
       [{type:"start", status:"started", timestamp:(($s|tonumber)*1000)},
        {type:"launch", status:"created", timestamp:((($s|tonumber)-60)*1000)}] end)}
    + (if $k == "noguest" then {} else {guest:{cpu_kind:$k, cpus:$c, memory_mb:$m}} end)'
}
apps() { printf '%s\n' "$@" | jq -R . | jq -sc '{apps: map({name: .})}' > "$T/fx/apps.json"; }
machines() { local a="$1"; shift; printf '%s\n' "$@" | jq -sc . > "$T/fx/m-$a.json"; }
reset() {
  local d
  for d in "$H/state" "$T/fx" "$T/req"; do scratch_rm "$d" || exit 1; mkdir -p "$d"; done
  : > "$ALERTS"; : > "$LOG"
  printf '%s\nFLY_ORG=personal\n' "$TOKEN_LINE" > "$H/env/global.env"
  unset FLY_IDLE_IGNORE_APPS FLY_IDLE_MAX_APPS
}
run() { bash "$LANE" > "$T/out" 2>&1; RC=$?; }
nalerts() { grep -c '\[fly-idle\]' "$ALERTS" 2>/dev/null | tr -dc 0-9; }
lastlog() { tail -n 1 "$LOG"; }
DAY=$(date -u -d "@$NOW" +%Y%m%d)
H3=$((NOW - 3*3600 - 120))

case_c1() {
  reset
  apps pool-a
  machines pool-a "$(mach m-idle started "$H3")"
  run
  [ "$RC" = 0 ] && ok || bad "C1a rc 0, got $RC: $(cat "$T/out")"
  [ "$(nalerts)" = 1 ] && ok || bad "C1b exactly one ALERTS line, got: $(cat "$ALERTS")"
  local L rate want; L=$(grep '\[fly-idle\]' "$ALERTS")
  case "$L" in *pool-a/m-idle*) ok ;; *) bad "C1c line names pool-a/m-idle: $L" ;; esac
  case "$L" in *"up 3h"*) ok ;; *) bad "C1d line says up 3h: $L" ;; esac
  rate=$( . "$DIR/bin/lib/fly-cost-row.sh"; fly_price_per_s "$DIR/catalog/fly-prices.json" performance 8 16384 | awk '{print $1}')
  want=$(awk -v r="$rate" 'BEGIN{printf "%.2f", r*3600}')
  case "$L" in *"\$$want/h)"*) ok ;; *) bad "C1e line carries \$$want/h for the machine: $L" ;; esac
  case "$L" in *"1 started machines idle >2h, \$$want/h total"*) ok ;; *) bad "C1f header count and total: $L" ;; esac
  grep -q 'fm2_x' "$ALERTS" "$LOG" "$T/out" && bad "C1g the token reached a log/ALERTS/stdout" || ok
  grep -q 'idle=1 ' "$LOG" && grep -q 'queue=unread' "$LOG" && ok || bad "C1h log counts idle=1 and queue=unread: $(cat "$LOG")"
}

case_c2() {
  reset
  apps pool-a
  machines pool-a "$(mach m-busy started "$H3")"
  mkdir -p "$H/state/fly-pool/project-5"; echo '{}' > "$H/state/fly-pool/project-5/m-busy.json"
  run
  grep -q m-busy "$ALERTS" && bad "C2a a pool-build machine was flagged: $(cat "$ALERTS")" || ok
  grep -q 'active=1 ' "$LOG" && grep -q 'idle=0 ' "$LOG" && ok || bad "C2b log has active=1 idle=0: $(cat "$LOG")"
}

case_c3() {
  reset
  apps disp
  machines disp "$(mach m-disp started "$H3")"
  mkdir -p "$H/state/fly"; echo '{"machine_id":"m-disp"}' > "$H/state/fly/proj.json"; echo '{}' > "$H/state/fly/proj-active.json"
  run
  [ "$(nalerts)" = 0 ] && ok || bad "C3a a dispatcher job's machine was flagged: $(cat "$ALERTS")"
  rm -f "$H/state/fly/proj-active.json" "$H/state/fly-idle-check/$DAY"
  run
  grep -q 'disp/m-disp' "$ALERTS" && ok || bad "C3b a stale dispatcher record must not hide an idle machine: $(cat "$ALERTS") / $(cat "$LOG")"
}

case_c4() {
  case_c1 >/dev/null
  run
  [ "$(nalerts)" = 1 ] && ok || bad "C4a a same-day rerun added a line: $(cat "$ALERTS")"
  case "$(lastlog)" in *"already alerted"*) ok ;; *) bad "C4b log says already alerted: $(lastlog)" ;; esac
  FLY_IDLE_NOW=$((NOW + 86400)) bash "$LANE" > "$T/out" 2>&1
  [ "$(nalerts)" = 2 ] && ok || bad "C4c next UTC day adds one line: $(cat "$ALERTS")"
  [ -e "$H/state/fly-idle-check/$(date -u -d "@$((NOW + 86400))" +%Y%m%d)" ] && ok || bad "C4d next day's marker exists"
}

case_c5() {
  reset
  apps pool-a svc-keep
  machines pool-a "$(mach m-young started $((NOW - 7140)))" "$(mach m-stopped stopped $((NOW - 5*86400)))" \
    '{"id":"m-noage","state":"started","guest":{"cpu_kind":"shared","cpus":1,"memory_mb":256}}'
  machines svc-keep "$(mach m-keep started "$H3")"
  FLY_IDLE_IGNORE_APPS=svc-keep run
  [ "$RC" = 0 ] && ok || bad "C5a rc 0, got $RC"
  [ "$(nalerts)" = 0 ] && ok || bad "C5b nothing flagged, got: $(cat "$ALERTS")"
  grep -q 'age-unknown=1 ' "$LOG" && grep -q 'idle=0 ' "$LOG" && grep -q 'ignored=1 ' "$LOG" && ok \
    || bad "C5c log has age-unknown=1 idle=0 ignored=1: $(cat "$LOG")"
  grep -q 'svc-keep/machines' "$T/req/all.lines" && bad "C5d an ignored app was read" || ok
  # C5b: a 3h-idle machine with no guest size is unpriced, never $0
  reset
  apps pool-a
  machines pool-a "$(mach m-nosize started "$H3" noguest)"
  run
  grep -q 'pool-a/m-nosize.*burn unpriced' "$ALERTS" && grep -q '(1 unpriced)' "$ALERTS" && ok \
    || bad "C5e unknown size alerts as burn unpriced: $(cat "$ALERTS")"
}

case_c6() {
  reset
  apps pool-a; echo 500 > "$T/fx/apps.code"
  run
  [ "$RC" != 0 ] && ok || bad "C6a apps 500 must be rc!=0"
  [ "$(nalerts)" = 1 ] && grep -q 'HTTP 500' "$ALERTS" && ok || bad "C6b one ALERTS line naming HTTP 500: $(cat "$ALERTS")"
  grep -qE 'idle=0| 0 started machines idle' "$LOG" "$ALERTS" && bad "C6c a failed read reported 0 idle" || ok
  reset
  echo 'FLY_ORG=personal' > "$H/env/global.env"
  run
  [ "$RC" = 0 ] && ok || bad "C6d no token is rc 0, got $RC"
  grep -q 'not configured: FLY_API_TOKEN unset' "$LOG" && ok || bad "C6e log says not configured: $(cat "$LOG")"
  [ ! -s "$ALERTS" ] && ok || bad "C6f no token writes no alert: $(cat "$ALERTS")"
}

case_c8() {
  reset
  apps pool-a
  local i ms=()
  for i in $(seq -w 1 25); do ms+=("$(mach "m-$i" started "$H3" shared 1 256)"); done
  machines pool-a "${ms[@]}"
  run
  local L; L=$(grep '\[fly-idle\]' "$ALERTS")
  case "$L" in *"25 started machines idle"*) ok ;; *) bad "C8a header counts 25: $L" ;; esac
  [ "$(grep -o 'pool-a/m-' <<< "$L" | wc -l)" = 20 ] && ok || bad "C8b exactly 20 listed: $L"
  case "$L" in *"... and 5 more") ok ;; *) bad "C8c ends '... and 5 more': $L" ;; esac
}

case_c9() {
  reset
  apps a b
  machines a "$(mach m-a started "$H3")"
  machines b "$(mach m-b started "$H3")"
  FLY_IDLE_MAX_APPS=1 run
  [ "$RC" = 0 ] && ok || bad "C9a a capped run is rc 0, got $RC"
  grep -q 'a/m-a.*partial: 1 apps not checked' "$ALERTS" && ok || bad "C9b alert says partial: $(cat "$ALERTS")"
  grep -q '/v1/apps/b/machines' "$T/req/all.lines" && bad "C9c app b was read past the cap" || ok
  # partial and nothing idle in the rest still says so, once
  reset
  apps a b
  machines a "$(mach m-a started $((NOW - 60)))"
  FLY_IDLE_MAX_APPS=1 run
  grep -q 'partial: 1 apps not checked, no idle machine in the rest' "$ALERTS" && ok || bad "C9d partial with 0 idle still alerts: $(cat "$ALERTS")"
}

# queue_on — this case's global.env names a jobs worker and a secret
queue_on() { printf 'HARNESS_SECRET=qsecret\nJOBS_URL=http://jobs\n' >> "$H/env/global.env"; }

case_c10() {
  reset; queue_on
  apps pool-a
  machines pool-a "$(mach m-q started "$H3")"
  echo '{"queue":[{"id":1,"machine":"m-q"},{"id":2,"machine":null}]}' > "$T/fx/queue.json"
  run
  [ "$RC" = 0 ] && ok || bad "C10a rc 0, got $RC: $(cat "$T/out")"
  grep -q m-q "$ALERTS" && bad "C10b a machine a claimed queue row names was flagged: $(cat "$ALERTS")" || ok
  grep -q 'active=1 ' "$LOG" && grep -q 'idle=0 ' "$LOG" && grep -q 'queue=read' "$LOG" && ok \
    || bad "C10c log has active=1 idle=0 queue=read: $(cat "$LOG")"
  grep -qxF 'GET http://jobs/api/queue?status=claimed&limit=500' "$T/req/all.lines" && ok \
    || bad "C10d the claimed queue was read with one GET: $(cat "$T/req/all.lines")"
  grep -q 'qsecret' "$ALERTS" "$LOG" "$T/out" && bad "C10e the jobs secret reached a log/ALERTS/stdout" || ok
  # a worker that answers 500 is unread, and the machine is still flagged
  reset; queue_on
  apps pool-a
  machines pool-a "$(mach m-q started "$H3")"
  echo '{"error":"boom"}' > "$T/fx/queue.json"; echo 500 > "$T/fx/queue.code"
  run
  grep -q 'pool-a/m-q' "$ALERTS" && ok || bad "C10f a 500 queue answer must not hide an idle machine: $(cat "$ALERTS")"
  grep -qF 'queue=unread(http 500)' "$LOG" && ok || bad "C10g log says queue=unread(http 500): $(cat "$LOG")"
  # a 200 that is not JSON is unread too
  reset; queue_on
  apps pool-a
  machines pool-a "$(mach m-q started "$H3")"
  echo '<html>gateway</html>' > "$T/fx/queue.json"
  run
  grep -q 'pool-a/m-q' "$ALERTS" && ok || bad "C10h a non-JSON queue answer must not hide an idle machine: $(cat "$ALERTS")"
  grep -qF 'queue=unread(unparseable)' "$LOG" && ok || bad "C10i log says queue=unread(unparseable): $(cat "$LOG")"
  # 500 rows is the worker's cap: the claim still counts, the read says truncated
  reset; queue_on
  apps pool-a
  machines pool-a "$(mach m-q started "$H3")"
  jq -nc '{queue: ([range(499) | {id: ., machine: ("m-other-" + tostring)}] + [{id: 499, machine: "m-q"}])}' > "$T/fx/queue.json"
  run
  grep -q m-q "$ALERTS" && bad "C10j a claim in a full queue page was ignored: $(cat "$ALERTS")" || ok
  grep -q 'queue=truncated' "$LOG" && ok || bad "C10k 500 rows log queue=truncated: $(cat "$LOG")"
}

case_c1; case_c2; case_c3; case_c4; case_c5; case_c6; case_c8; case_c9; case_c10
# C7a: everything the stub ever saw, across every case above. With a jobs
# secret set (C10) the shared lib/lane-gate.sh also posts the lane's liveness
# and beat, as it does for every lane; those two exact endpoints are its
# telemetry, not this lane's, and are the only requests excluded here.
LG_TELEMETRY='^POST\+DATA (http://jobs/api/lanes/liveness|https://[^ /]+/api/beat)$'
grep -vE "$LG_TELEMETRY" "$T/ever.lines" | grep -v '^GET http' >/dev/null 2>&1 \
  && bad "C7a a non-GET request: $(grep -vE "$LG_TELEMETRY" "$T/ever.lines" | grep -v '^GET http')" || ok
grep -E '^[^G].*(stub/|/machines|/api/queue)' "$T/ever.lines" && bad "C7a a non-GET reached the Fly API or the queue" || ok
grep -qE '/stop|/destroy|DELETE' "$T/ever.lines" && bad "C7a a stop/destroy URL was requested" || ok
[ "$(grep -c '^GET http' "$T/ever.lines" 2>/dev/null)" -gt 5 ] && ok || bad "C7a the stub saw too few requests to judge"
# C7b: no stop/destroy/POST anywhere in the script's code (comments excluded)
grep -vE '^[[:space:]]*#' "$SRC" | grep -nE 'machine stop|machine destroy|/stop|-X POST|-X DELETE|--request' && bad "C7b the lane can mutate a machine" || ok

# ── M1/M2: break the lane, confirm the cases above go red, restore ──────────
mutate() { # mutate <sed-expr> -> exactly one changed line, or the run fails
  sed "$1" "$SRC" > "$LANE"
  local n; n=$(diff "$SRC" "$LANE" | grep -c '^>')
  [ "$n" = 1 ] && ok || bad "mutation '$1' changed $n lines, want 1"
}
red() { # red <name> <case...> -> at least one assertion fails
  local name="$1" before=$FAIL p=$PASS; shift
  QUIET=1; for c in "$@"; do "$c"; done; QUIET=0
  if [ "$FAIL" -gt "$before" ]; then FAIL=$before; PASS=$((p + 1)); else PASS=$p; bad "$name: suite stayed green under mutation"; fi
}
mutate 's/-gt "\$LIMIT"/-lt "$LIMIT"/'; red M1 case_c1 case_c5
mutate '/^is_active() {/,/^}/c\
is_active() { return 1; }'; red M2 case_c2
mutate 's/^  grep -qxF -- "\$mid" "\$WORK\/claimed.txt" && return 0$/  :/'; red M3 case_c10
cp "$SRC" "$LANE"

echo "fly-idle-check.bh-4020: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
