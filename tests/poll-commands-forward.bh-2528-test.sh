#!/bin/bash
# tests/poll-commands-forward.bh-2528-test.sh — BH-2657 (BH-2528.4): the hub's
# console poller hands a box-owned project's command to that box as a
# box_console_commands row, never over ssh, and sweeps the rows nobody claimed.
#
# Every handler below is the block EXTRACTED VERBATIM from bin/poll-commands.sh
# by its `# >>> <name> handler` markers, run against the REAL jobs client, the
# REAL bin/lib/jobs/box-console-commands.sh, bin/lib/box-cmd-exec.sh and
# bin/lib/cron-lines.sh, the REAL box-for.sh / fleet-conf.sh, and a stubbed curl
# that records {method,url,body} for every request. The scripts a local command
# runs are stubs that record their argv; ssh and scp are stubs that record that
# they were called at all, which is the failure this suite exists to catch.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRC="${PC:-$DIR/bin/poll-commands.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/flags" "$T/fakebin" "$T/tmp"
cp -r "$DIR/bin/lib" "$T/bin/lib"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$T/bin/"
for f in bin/lib/jobs/box-console-commands.sh bin/lib/box-cmd-exec.sh bin/lib/cron-lines.sh; do
  [ -f "$T/$f" ] || { echo "FAIL: fixture has no $f"; exit 1; }
done
cat > "$T/fleet.conf" <<'EOF'
project-3 Org/project-3 https://o.example /api/board 2 box-project-3-2
project-4 Org/project-4 https://c.example /api/board 2 box-project-4-1
hub-os Org/hub https://h.example /api/board 2 local
EOF

# The scripts a command runs: one calls.log line each, argv joined by '|'.
for s in run-triage.sh fetch-log.sh fetch-artifact.sh box-chat.sh product-cmd.sh; do
  cat > "$T/bin/$s" <<'STUB'
#!/bin/bash
me=$(basename "$0")
{ printf '%s' "$me"; for a in "$@"; do printf '|%s' "$a"; done; printf '\n'; } >> "$CALLS"
case "$me" in
  fetch-log.sh)
    case "${1:-}" in
      --path) case "${2:-}" in triage|build) exit 0 ;; *) exit 1 ;; esac ;;
      --error) printf '{"kind":"log_tail","rkey":"log:%s","error":"%s"}\n' "$4" "$5"; exit 0 ;;
    esac
    [ -n "${FETCH_FAIL:-}" ] && { echo garbage; exit 0; }
    printf '{"kind":"log_tail","rkey":"log:%s","tail":"hello from %s"}\n' "$3" "$1" ;;
  fetch-artifact.sh)
    case "${1:-}" in
      --path) exit 0 ;;
      --error) printf '{"kind":"artifact_tail","rkey":"artifact:%s","error":"%s"}\n' "$5" "$6"; exit 0 ;;
    esac
    printf '{"kind":"artifact_tail","rkey":"artifact:%s"}\n' "$4" ;;
  product-cmd.sh) echo "product-cmd did $2" ;;
esac
exit 0
STUB
  chmod +x "$T/bin/$s"
done
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/BEATS.jsonl"\n' "$T" > "$T/bin/beat.sh"
chmod +x "$T/bin/beat.sh"

# ssh / scp: any call at all is a failure of this change.
for s in ssh scp; do
  printf '#!/bin/bash\nprintf "%s %%s\\n" "$*" >> "%s/SSH.calls"\nexit 0\n' "$s" "$T" > "$T/fakebin/$s"
  chmod +x "$T/fakebin/$s"
done
# mktemp: record every template, then do the real thing.
REAL_MKTEMP=$(command -v mktemp)
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/MKTEMP.calls"\nexec %s "$@"\n' "$T" "$REAL_MKTEMP" > "$T/fakebin/mktemp"
chmod +x "$T/fakebin/mktemp"

# Fake curl. FWD_MODE picks the create answer (200, 500, 409, down); the expire
# route answers $EXPIRE_FIX, or empty arrays, or 500 under EXPIRE_MODE=500.
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
  "POST "*/api/box-console-commands/expire)
    [ "${EXPIRE_MODE:-}" = 500 ] && { printf '{"error":"boom"}\n500\n'; exit 0; }
    if [ -f "$EXPIRE_FIX" ]; then cat "$EXPIRE_FIX"; else printf '{"expired":[],"stale_claimed":[],"stale_truncated":false}'; fi
    printf '\n200\n' ;;
  "POST "*/api/box-console-commands)
    case "${FWD_MODE:-200}" in
      500)  printf '{"error":"boom"}\n500\n' ;;
      409)  printf '{"error":"payload differs"}\n409\n' ;;
      down) exit 7 ;;
      *)    printf '{"created":true}\n200\n' ;;
    esac ;;
  *) printf '{}\n404\n' ;;
esac
CURL
chmod +x "$T/fakebin/curl"

# extract <marker> <case-label> — the handler block, as a sourceable body.
extract() {
  awk -v n="$1" '
    $0 ~ "^    # >>> " n " handler" {f=1; next}
    $0 ~ "^    # <<< " n " handler" {exit}
    f {print}' "$SRC" | sed -e "1s/^    ${2})//" -e '$s/ ;;$//'
}
extract run_triage run_triage > "$T/run_triage.body"
extract fetch_log fetch_log > "$T/fetch_log.body"
extract fetch_artifact fetch_artifact > "$T/fetch_artifact.body"
extract chat chat > "$T/chat.body"
extract update_company_map update_company_map > "$T/update_company_map.body"
extract chat_proposal chat_proposal > "$T/chat_proposal.body"
extract proposal_gate 'post_proposal|kill_proposal|revise_proposal' > "$T/proposal_gate.body"
for b in run_triage fetch_log fetch_artifact chat update_company_map chat_proposal proposal_gate; do
  [ -s "$T/$b.body" ] || { echo "FAIL: could not extract the $b handler — markers missing?"; exit 1; }
done
# The chat hub path writes a hardcoded /root/orchestrator; keep it in the fixture.
sed -i "s|/root/orchestrator|$T/orchestrator|g" "$T/chat.body"
awk '/^    # >>> box-command expiry/ {f=1; next} /^    # <<< box-command expiry/ {exit} f {print}' "$SRC" > "$T/expiry.body"

reset() {
  : > "$T/req.log"; : > "$T/calls.log"; : > "$T/BEATS.jsonl"; : > "$T/SSH.calls"; : > "$T/MKTEMP.calls"
  : > "$T/logs/console-commands.log"; : > "$T/logs/ALERTS.log"; : > "$T/logs/poll-commands.log"
  rm -f "$T/expire.json" "$T/flags/"alerted-* "$T/tmp/"*
}
# run <body> <type> <project> <id> <payload> — OK=/RESULT= lines land in $T/out.
# LIBS=0 runs the block with none of the three libs loaded.
# The payload rides a file: a 200 KB map in the environment would hit the
# per-string execve cap in the test itself, which production never does.
run() {
  printf '%s' "$5" > "$T/payload.in"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" FLEET_CONF="$T/fleet.conf" REQ_SINK="$T/req.log" \
      CALLS="$T/calls.log" EXPIRE_FIX="$T/expire.json" JOBS_URL=https://jobs.invalid \
      HARNESS_SECRET=test-secret JOBS_RETRIES=0 TMPDIR="$T/tmp" BEAT="$T/bin/beat.sh" \
      ID="$4" TYPE="$2" PROJECT="$3" LIBS="${LIBS:-1}"
    bash -c 'set -uo pipefail; OK=false; RESULT=""; PAYLOAD=$(cat "$HARNESS/payload.in")
      if [ "$LIBS" = 1 ]; then
        . "$HARNESS/bin/jobs-client.sh"; . "$HARNESS/bin/lib/jobs/box-console-commands.sh"
        . "$HARNESS/bin/lib/box-cmd-exec.sh"; . "$HARNESS/bin/lib/cron-lines.sh"
      fi
      . "$0"; printf "OK=%s\nRESULT=%s\n" "$OK" "$RESULT"' "$T/$1.body" ) > "$T/out" 2>"$T/err"
}
run_expiry() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" FLEET_CONF="$T/fleet.conf" REQ_SINK="$T/req.log" \
      CALLS="$T/calls.log" EXPIRE_FIX="$T/expire.json" JOBS_URL=https://jobs.invalid \
      HARNESS_SECRET=test-secret JOBS_RETRIES=0 TMPDIR="$T/tmp" BEAT="$T/bin/beat.sh"
    bash -c 'set -uo pipefail
      . "$HARNESS/bin/jobs-client.sh"; . "$HARNESS/bin/lib/jobs/box-console-commands.sh"
      . "$0"' "$T/expiry.body" ) > "$T/out" 2>"$T/err"
}
okv()     { sed -n 's/^OK=//p' "$T/out"; }
resultv() { sed -n 's/^RESULT=//p' "$T/out"; }
posts()   { jq -c 'select(.method=="POST" and (.url|endswith("/api/box-console-commands")))' "$T/req.log"; }
nposts()  { posts | grep -c . ; }
nreq()    { grep -c . "$T/req.log"; }
nbeats()  { grep -c . "$T/BEATS.jsonl"; }
bcalerts() { grep -c '\[box-console-commands\]' "$T/logs/ALERTS.log"; }
wait_call() { local i; for i in $(seq 1 50); do grep -q -- "$1" "$T/calls.log" && return 0; sleep 0.1; done; return 1; }

# ssh_sites <file> — how many ssh/scp invocations the file carries. zero_ssh
# is the assertion: rc 0 only when there are none.
ssh_sites() { grep -cE '\b(ssh|scp)\b +-o|timeout [0-9]+ (ssh|scp)' "$1"; }
zero_ssh()  { [ "$(ssh_sites "$1")" = 0 ]; }

# --- 1. no ssh/scp site is left in the poller ---------------------------------
zero_ssh "$SRC" && ok || bad "1 bin/poll-commands.sh still has $(ssh_sites "$SRC") ssh/scp site(s)"
grep -q 'root@' "$SRC" && bad "1 bin/poll-commands.sh still names root@<box>" || ok

# --- 1b. the shipped source lines load the three libs --------------------------
SRCLINES=$(grep -E '^\[ -r "\$HARNESS/bin/lib/(jobs/box-console-commands|box-cmd-exec|cron-lines)\.sh" \] && \. ' "$SRC")
[ "$(grep -c . <<<"$SRCLINES")" = 3 ] && ok || bad "1b expected 3 guarded source lines, got: $SRCLINES"
GOT=$(HARNESS="$T" bash -c ". \"\$HARNESS/bin/jobs-client.sh\"; $SRCLINES
  for f in box_ccmd_forward box_ccmd_expire bcx_run cron_box_id_for; do command -v \$f >/dev/null || echo \"missing \$f\"; done" 2>&1)
[ -z "$GOT" ] && ok || bad "1b the shipped source lines do not define the verbs: $GOT"
# ...and guarded: a box without the files still runs them without an error.
GOT=$(HARNESS="$T/nowhere" bash -c "set -u; $SRCLINES
  echo survived" 2>&1)
[ "$GOT" = survived ] && ok || bad "1b the source lines are not guarded: $GOT"

# --- 2. every box-owned block becomes exactly one row, never ssh ---------------
# block|type|id|payload
CASES=(
  'run_triage|run_triage|r1|{}'
  'fetch_log|fetch_log|f1|{"project":"project-3","which":"triage"}'
  'fetch_artifact|fetch_artifact|a1|{"project":"project-3","key":"TK-1","which":"plan"}'
  'chat|chat|c1|{"text":"why is the queue stuck","origin":"dash"}'
  'update_company_map|update_company_map|m1|{"content":"# project-3 map\nline two"}'
  'chat_proposal|chat_proposal|p1|{"slug":"weekly-digest","message":"hi","origin":"dash"}'
  'proposal_gate|post_proposal|g1|{"slug":"weekly-digest","notes":"ship it"}'
)
for C in "${CASES[@]}"; do
  IFS='|' read -r B TY ID PL <<<"$C"
  reset; run "$B" "$TY" project-3 "$ID" "$PL"
  P=$(posts)
  if [ "$(nposts)" = 1 ] \
     && [ "$(jq -r '.body|fromjson|.box' <<<"$P")" = project-3 ] \
     && [ "$(jq -r '.body|fromjson|.command_id' <<<"$P")" = "$ID" ] \
     && [ "$(jq -r '.body|fromjson|.type' <<<"$P")" = "$TY" ] \
     && [ "$(jq -r '.body|fromjson|.project' <<<"$P")" = project-3 ] \
     && [ "$(jq -r '.body|fromjson|.payload' <<<"$P")" = "$PL" ]; then ok
  else bad "2 $B: want one POST /api/box-console-commands {box:project-3,command_id:$ID,type:$TY,payload verbatim}, got: $(cat "$T/req.log") err=$(head -c 300 "$T/err")"; fi
  grep -q '/api/box-commands' "$T/req.log" && bad "2 $B: posted to the superseded /api/box-commands route"
  R=$(resultv)
  [ "$(okv)" = true ] && [[ "$R" == *"queued for box-project-3-2"* ]] && [[ "$R" != *launched* ]] \
    && ok || bad "2 $B: want OK=true 'queued for box-project-3-2', got OK=$(okv) RESULT=$R"
  [ -s "$T/SSH.calls" ] && bad "2 $B: ssh/scp called: $(cat "$T/SSH.calls")" || ok
  # The hub runs nothing for a box-owned command beyond the fetch whitelist check.
  RAN=$(grep -v -- '|--path|' "$T/calls.log")
  [ -z "$RAN" ] && ok || bad "2 $B: the hub ran a box's script itself: $RAN"
done
# A forwarded fetch does not beat: the console reads the row (#2656).
for B in fetch_log fetch_artifact; do
  reset; run "$B" "$B" project-3 x1 '{"project":"project-3","key":"TK-1","which":"triage"}'
  [ "$(nbeats)" = 0 ] && ok || bad "2 $B: a queued forward must not beat, got $(cat "$T/BEATS.jsonl")"
done
reset; run fetch_log fetch_log project-3 x1 '{"project":"project-3","which":"triage"}'
grep -q 'fetch_log id=x1 project=project-3 which=triage box=box-project-3-2 -> queued for' "$T/logs/console-commands.log" \
  && ok || bad "2 fetch_log: the console-commands.log line is missing: $(cat "$T/logs/console-commands.log")"
# run_triage reads nothing from its payload: a non-JSON one still queues, as {}.
reset; run run_triage run_triage project-3 r2 'not json'
[ "$(okv)" = true ] && [ "$(jq -r '.body|fromjson|.payload' <<<"$(posts)")" = '{}' ] \
  && ok || bad "2 run_triage non-JSON payload: $(cat "$T/out") req=$(cat "$T/req.log")"
# A project fleet.conf does not know is refused before any request.
reset; run run_triage run_triage nope-os n1 '{}'
[ "$(okv)" = false ] && [[ "$(resultv)" == *"unknown project"* ]] && [ "$(nreq)" = 0 ] \
  && ok || bad "2 unknown project: want OK=false, no request; got $(cat "$T/out") req=$(cat "$T/req.log")"

# --- 3. a forward that fails is OK=false and answers the pane ------------------
reset; FWD_MODE=500 run fetch_log fetch_log project-3 e1 '{"project":"project-3","which":"triage"}'
[ "$(okv)" = false ] && [ "$(resultv)" = "forward to box-project-3-2 failed (jobs worker 500)" ] \
  && [ "$(nbeats)" = 1 ] && [ "$(jq -r .error "$T/BEATS.jsonl")" = fetch_failed ] && [ "$(jq -r .rkey "$T/BEATS.jsonl")" = log:e1 ] \
  && ok || bad "3 fetch_log 500: $(cat "$T/out") beats=$(cat "$T/BEATS.jsonl")"
reset; FWD_MODE=500 run fetch_artifact fetch_artifact project-3 e2 '{"project":"project-3","key":"TK-1","which":"plan"}'
[ "$(okv)" = false ] && [ "$(resultv)" = "forward to box-project-3-2 failed (jobs worker 500)" ] \
  && [ "$(nbeats)" = 1 ] && [ "$(jq -r .error "$T/BEATS.jsonl")" = fetch_failed ] && [ "$(jq -r .rkey "$T/BEATS.jsonl")" = artifact:e2 ] \
  && ok || bad "3 fetch_artifact 500: $(cat "$T/out") beats=$(cat "$T/BEATS.jsonl")"
reset; FWD_MODE=500 run chat chat project-3 e3 '{"text":"anyone home","origin":"dash"}'
[ "$(okv)" = false ] && [ "$(nbeats)" = 1 ] && [ "$(jq -r .error "$T/BEATS.jsonl")" = routing_failed ] \
  && [ "$(jq -r .rkey "$T/BEATS.jsonl")" = chat:e3 ] \
  && ok || bad "3 chat 500: $(cat "$T/out") beats=$(cat "$T/BEATS.jsonl")"
[ -s "$T/SSH.calls" ] && bad "3 a failed forward fell back to ssh: $(cat "$T/SSH.calls")" || ok
reset; FWD_MODE=down run run_triage run_triage project-3 e4 '{}'
[ "$(okv)" = false ] && [ "$(resultv)" = "forward to box-project-3-2 failed (jobs worker unreachable)" ] \
  && ok || bad "3 worker down: $(cat "$T/out")"
# A replayed id with a different payload is a 409: refused, never run twice.
reset; FWD_MODE=409 run chat_proposal chat_proposal project-3 e5 '{"slug":"weekly-digest","message":"hi"}'
[ "$(okv)" = false ] && [ "$(resultv)" = "forward to box-project-3-2 failed (jobs worker 409)" ] \
  && ok || bad "3 409: $(cat "$T/out")"
[ -s "$T/SSH.calls" ] && bad "3 ssh called on a failed forward: $(cat "$T/SSH.calls")" || ok

# --- 4. no client, no request and no ssh ----------------------------------------
reset; LIBS=0 run run_triage run_triage project-3 n2 '{}'
[ "$(okv)" = false ] && [[ "$(resultv)" == *"client not loaded"* ]] && [ "$(nreq)" = 0 ] && [ ! -s "$T/SSH.calls" ] \
  && ok || bad "4 client not loaded: $(cat "$T/out") req=$(nreq) ssh=$(cat "$T/SSH.calls")"
reset; LIBS=0 run run_triage run_triage hub-os n3 '{}'
[ "$(okv)" = false ] && [[ "$(resultv)" == *"box-cmd-exec not loaded"* ]] && [ ! -s "$T/calls.log" ] \
  && ok || bad "4 bcx not loaded: $(cat "$T/out") calls=$(cat "$T/calls.log")"

# --- 5. a hub-owned command runs here through bcx_run, with no request ---------
reset; run fetch_log fetch_log hub h1 '{"project":"hub","which":"triage"}'
[ "$(okv)" = true ] && [ "$(nposts)" = 0 ] && grep -q '^fetch-log.sh|hub|triage|h1$' "$T/calls.log" \
  && [ "$(nbeats)" = 1 ] && [ "$(jq -r .tail "$T/BEATS.jsonl")" = "hello from hub" ] \
  && [ "$(resultv)" = "log tail beat from local" ] \
  && ok || bad "5 fetch_log hub: $(cat "$T/out") calls=$(cat "$T/calls.log") beats=$(cat "$T/BEATS.jsonl")"
reset; run run_triage run_triage hub-os h2 '{}'
wait_call '^run-triage.sh|hub-os$' && [ "$(okv)" = true ] && [ "$(nreq)" = 0 ] \
  && ok || bad "5 run_triage local: $(cat "$T/out") calls=$(cat "$T/calls.log")"
# A local fetch that fails still beats exactly once.
reset; FETCH_FAIL=1 run fetch_log fetch_log hub-os h3 '{"project":"hub-os","which":"build"}'
[ "$(okv)" = false ] && [ "$(resultv)" = "fetch failed on local" ] && [ "$(nbeats)" = 1 ] \
  && [ "$(jq -r .error "$T/BEATS.jsonl")" = fetch_failed ] && [ "$(jq -r .rkey "$T/BEATS.jsonl")" = log:h3 ] \
  && ok || bad "5 a local fetch that fails must beat fetch_failed once: $(cat "$T/out") beats=$(cat "$T/BEATS.jsonl")"

# --- 6. update_company_map: no hub temp file, the map rides in the row ---------
reset; run update_company_map update_company_map project-3 m2 '{"content":"# Map\nsecond line"}'
[ "$(jq -r '.body|fromjson|.payload|fromjson|.content' <<<"$(posts)")" = "$(printf '# Map\nsecond line')" ] \
  && ok || bad "6 map content did not ride in the POST: $(cat "$T/req.log")"
grep -q 'map-inbound' "$T/MKTEMP.calls" && bad "6 the hub still writes a map temp file: $(cat "$T/MKTEMP.calls")" || ok
grep -q map-inbound <<<"$(ls "$T/tmp")" && bad "6 a map temp file was left behind" || ok
reset; run update_company_map update_company_map project-3 m3 '{"content":""}'
[ "$(okv)" = false ] && [ "$(resultv)" = "refused: empty map content" ] && [ "$(nreq)" = 0 ] \
  && ok || bad "6 empty map: $(cat "$T/out") req=$(cat "$T/req.log")"
# A map over the 128 KB argv cap still arrives whole.
BIG=$(head -c 200000 /dev/zero | tr '\0' 'm')
reset; run update_company_map update_company_map project-3 m4 "$(printf '%s' "$BIG" | jq -Rsc '{content:.}')"
[ "$(okv)" = true ] && [ "$(jq -r '.body|fromjson|.payload|fromjson|.content|length' <<<"$(posts)")" = 200000 ] \
  && ok || bad "6 a 200 KB map did not arrive whole: $(cat "$T/out") err=$(head -c 300 "$T/err")"

# --- 7. expiry: failure beats, log lines, one ALERTS line per box --------------
EXP='{"expired":[
  {"command_id":"x1","box":"project-3","type":"chat","project":"project-3","payload":"{\"text\":\"hi\",\"origin\":\"dash\"}","status":"expired"},
  {"command_id":"x2","box":"project-3","type":"fetch_log","project":"project-3","payload":"{\"project\":\"project-3\",\"which\":\"triage\"}","status":"expired"}],
  "stale_claimed":[],"stale_truncated":false}'
reset; printf '%s' "$EXP" > "$T/expire.json"; run_expiry
[ "$(jq -c 'select(.url|endswith("/api/box-console-commands/expire"))|.body|fromjson' "$T/req.log")" = '{"ttl_s":300}' ] \
  && ok || bad "7 expire call: $(cat "$T/req.log") err=$(head -c 300 "$T/err")"
[ "$(nbeats)" = 2 ] \
  && [ "$(jq -r 'select(.rkey=="chat:x1")|.error' "$T/BEATS.jsonl")" = routing_failed ] \
  && [ "$(jq -r 'select(.rkey=="chat:x1")|.text' "$T/BEATS.jsonl")" = "project-3 box project-3 did not pick this up within 300s" ] \
  && [ "$(jq -r 'select(.rkey=="log:x2")|.error' "$T/BEATS.jsonl")" = fetch_failed ] \
  && ok || bad "7 expiry beats: $(cat "$T/BEATS.jsonl")"
[ "$(bcalerts)" = 1 ] \
  && grep -qF '[box-console-commands] project-3: 2 command(s) expired unclaimed after 300s (oldest chat x1); is bin/box-console-commands.sh running there?' "$T/logs/ALERTS.log" \
  && ok || bad "7 expiry ALERTS: $(cat "$T/logs/ALERTS.log")"
[ "$(grep -c 'box_command_expired' "$T/logs/console-commands.log")" = 2 ] \
  && grep -q 'box_command_expired id=x2 type=fetch_log box=project-3 project=project-3' "$T/logs/console-commands.log" \
  && ok || bad "7 console-commands.log: $(cat "$T/logs/console-commands.log")"
# Nothing expired: no line, no beat.
rm -f "$T/expire.json"; : > "$T/BEATS.jsonl"; run_expiry
[ "$(bcalerts)" = 1 ] && [ "$(nbeats)" = 0 ] && ok || bad "7 an empty sweep wrote something: $(cat "$T/logs/ALERTS.log") $(cat "$T/BEATS.jsonl")"
# Two boxes: one line each. The TTL knob is read.
reset
printf '%s' '{"expired":[{"command_id":"y1","box":"project-3","type":"run_triage","project":"project-3","payload":"{}"},
  {"command_id":"y2","box":"project-4","type":"run_triage","project":"project-4","payload":"{}"},
  {"command_id":"y3","box":"project-4","type":"chat_proposal","project":"project-4","payload":"{}"}],"stale_claimed":[],"stale_truncated":false}' > "$T/expire.json"
BOX_CONSOLE_COMMANDS_TTL_S=600 run_expiry
[ "$(bcalerts)" = 2 ] \
  && grep -qF '[box-console-commands] project-4: 2 command(s) expired unclaimed after 600s (oldest run_triage y2)' "$T/logs/ALERTS.log" \
  && grep -qF '[box-console-commands] project-3: 1 command(s) expired unclaimed after 600s (oldest run_triage y1)' "$T/logs/ALERTS.log" \
  && [ "$(nbeats)" = 0 ] \
  && [ "$(jq -r '.body|fromjson|.ttl_s' "$T/req.log")" = 600 ] \
  && ok || bad "7 two boxes: $(cat "$T/logs/ALERTS.log") beats=$(cat "$T/BEATS.jsonl")"
# A hostile box/id cannot forge an ALERTS line.
reset
printf '%s' '{"expired":[{"command_id":"z1\nFAKE [vm] forged","box":"om ya;rm","type":"run_triage","project":"project-3","payload":"{}"}],"stale_claimed":[],"stale_truncated":false}' > "$T/expire.json"
run_expiry
[ "$(grep -c . "$T/logs/ALERTS.log")" = 1 ] && grep -qF '[box-console-commands] project-3rm: 1 command(s)' "$T/logs/ALERTS.log" \
  && ok || bad "7 hostile row forged a line: $(cat "$T/logs/ALERTS.log")"
# An empty type keeps its slot: the id is not shifted into it (tab IFS collapsed it).
reset
printf '%s' '{"expired":[{"command_id":"e1","box":"project-3","type":"","project":"project-3","payload":"{}"}],"stale_claimed":[],"stale_truncated":false}' > "$T/expire.json"
run_expiry
grep -qF '[box-console-commands] project-3: 1 command(s) expired unclaimed after 300s (oldest  e1);' "$T/logs/ALERTS.log" \
  && ok || bad "7 empty type shifted fields: $(cat "$T/logs/ALERTS.log")"

# --- 8. stale claims page once per id -------------------------------------------
reset; rm -f "$T/state/box-console-commands-stale.ids"
printf '%s' '{"expired":[],"stale_claimed":[{"command_id":"s1","box":"project-3","type":"chat","status":"claimed"}],"stale_truncated":false}' > "$T/expire.json"
run_expiry
[ "$(bcalerts)" = 1 ] && grep -qF '[box-console-commands] project-3: command(s) claimed but never answered: s1' "$T/logs/ALERTS.log" \
  && ok || bad "8 stale: $(cat "$T/logs/ALERTS.log") err=$(head -c 300 "$T/err")"
run_expiry
[ "$(bcalerts)" = 1 ] && ok || bad "8 the same stale id paged twice: $(cat "$T/logs/ALERTS.log")"
printf '%s' '{"expired":[],"stale_claimed":[{"command_id":"s1","box":"project-3"},{"command_id":"s2","box":"project-3"}],"stale_truncated":false}' > "$T/expire.json"
run_expiry
[ "$(bcalerts)" = 2 ] && [ "$(tail -1 "$T/logs/ALERTS.log" | sed 's/.*answered: //')" = s2 ] \
  && ok || bad "8 a new stale id: $(cat "$T/logs/ALERTS.log")"
# Pruned to the current list only when the list is complete.
printf '%s' '{"expired":[],"stale_claimed":[{"command_id":"s2","box":"project-3"}],"stale_truncated":true}' > "$T/expire.json"
run_expiry
grep -qx s1 "$T/state/box-console-commands-stale.ids" && ok || bad "8 a truncated list pruned the seen set: $(cat "$T/state/box-console-commands-stale.ids")"
printf '%s' '{"expired":[],"stale_claimed":[{"command_id":"s2","box":"project-3"}],"stale_truncated":false}' > "$T/expire.json"
run_expiry
[ "$(cat "$T/state/box-console-commands-stale.ids")" = s2 ] && [ "$(bcalerts)" = 2 ] \
  && ok || bad "8 prune: $(cat "$T/state/box-console-commands-stale.ids") alerts=$(bcalerts)"

# --- 9. a failed expire is one poller log line, nothing else --------------------
reset; printf '%s' "$EXP" > "$T/expire.json"
( export EXPIRE_MODE=500; run_expiry )
[ "$(grep -c 'box-console-commands expire failed rc=1 http=500' "$T/logs/poll-commands.log")" = 1 ] \
  && [ "$(bcalerts)" = 0 ] && [ "$(nbeats)" = 0 ] \
  && ok || bad "9 expire 500: log=$(cat "$T/logs/poll-commands.log") alerts=$(cat "$T/logs/ALERTS.log") beats=$(nbeats)"

# --- 10. mutation: the zero-ssh check notices one ssh line coming back ----------
sed '/^    run_triage)$/a\        timeout 30 ssh -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 "root@$PROJECT" true' "$SRC" > "$T/mut.sh"
[ "$(ssh_sites "$T/mut.sh")" = 1 ] && ! zero_ssh "$T/mut.sh" \
  && ok || bad "10 the zero-ssh check did not notice an ssh line (count $(ssh_sites "$T/mut.sh"))"
# ...and case 2's no-ssh assertion notices it too, run on the mutated block.
KEEP="$SRC"; SRC="$T/mut.sh"; extract run_triage run_triage > "$T/run_triage.body"; SRC="$KEEP"
reset; run run_triage run_triage project-3 mu1 '{}'
[ -s "$T/SSH.calls" ] && ok || bad "10 the mutated run_triage block ran without the ssh stub seeing it"

echo "poll-commands-forward.bh-2528: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
