#!/bin/bash
# tests/box-console-commands-lane.bh-2528-test.sh — BH-2655 (BH-2528.2): the
# box-side executor bin/lib/box-cmd-exec.sh (bcx_run) and the per-box lane
# bin/box-console-commands.sh that claims forwarded console commands, runs them
# locally and posts each outcome back to its row.
#
# Drives the REAL lane, the REAL libs, the REAL box-for.sh / fleet-conf.sh and
# the REAL jobs client against a stubbed curl. The scripts a command runs
# (run-triage, fetch-log, fetch-artifact, box-chat, product-cmd) are stubs that
# record their argv, plus their open fds, into calls.log.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LANE="$DIR/bin/box-console-commands.sh"
BCX="$DIR/bin/lib/box-cmd-exec.sh"
NOW=$(date -u +%s)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin" "$T/env" "$T/logs" "$T/state" "$T/locks" "$T/fakebin"
cp -r "$DIR/bin/lib" "$T/bin/lib"   # carries bin/lib/jobs/*.sh, which the client needs
[ -f "$T/bin/lib/jobs/req.sh" ] || { echo "FAIL: fixture has no bin/lib/jobs/req.sh"; exit 1; }
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/box-for.sh" "$DIR/bin/fleet-conf.sh" "$T/bin/"
[ -f "$LANE" ] && cp "$LANE" "$T/bin/box-console-commands.sh"
[ -f "$BCX" ] && cp "$BCX" "$T/bin/lib/box-cmd-exec.sh"
printf 'JOBS_URL=https://jobs.invalid\nHARNESS_SECRET=test-secret\n' > "$T/env/global.env"
cat > "$T/fleet.conf" <<'EOF'
proj-a Org/a https://a.example /api/board 2 box-project-4-1
proj-b Org/b https://b.example /api/board 2 box-project-3-2
EOF

# Stubbed scripts: one line per call, argv joined by '|', then the fd list.
for s in run-triage.sh box-chat.sh product-cmd.sh fetch-log.sh fetch-artifact.sh; do
  cat > "$T/bin/$s" <<'STUB'
#!/bin/bash
me=$(basename "$0")
{ printf '%s' "$me"; for a in "$@"; do printf '|%s' "$a"; done
  printf ' fds=%s\n' "$(ls /proc/$$/fd | sort -n | tr '\n' ,)"; } >> "$CALLS"
case "$me" in
  fetch-log.sh)
    case "${1:-}" in
      --path) case "${2:-}" in triage|build) exit 0 ;; *) exit 1 ;; esac ;;
      --error) printf '{"error":"%s","which":"%s"}\n' "$5" "$3"; exit 0 ;;
    esac
    printf '{"tail":"hello from %s","which":"%s"}\n' "$1" "$2" ;;
  fetch-artifact.sh)
    case "${1:-}" in
      --path) case "${3:-}" in ''|*[!A-Za-z0-9_-]*) exit 1 ;; esac; exit 0 ;;
      --error) printf '{"error":"%s"}\n' "$6"; exit 0 ;;
    esac
    printf '{"artifact":"%s/%s"}\n' "$2" "$3" ;;
  product-cmd.sh)
    [ "${2:-}" = update_company_map ] && { cp "$4" "$MAPCOPY"; printf '%s\n' "$4" > "$MAPPATH"; }
    echo "product-cmd did $2" ;;
esac
exit 0
STUB
  chmod +x "$T/bin/$s"
done

# Fake curl: {method,url,body} per request into req.log. The claim answers the
# fixture file once (then []), unless CLAIM_MODE=503; a result answers 200
# unless RESULT_MODE=500. Anything else (settings, flags) is a 404.
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
  "POST "*/api/box-console-commands/claim)
    [ "${CLAIM_MODE:-}" = 503 ] && { printf '{"error":"down"}\n503\n'; exit 0; }
    if [ -f "$CLAIM_FIX" ]; then cat "$CLAIM_FIX"; rm -f "$CLAIM_FIX"; else printf '[]'; fi
    printf '\n200\n' ;;
  "POST "*/api/box-console-commands/*/result)
    [ "${RESULT_MODE:-}" = 500 ] && { printf '{"error":"boom"}\n500\n'; exit 0; }
    printf '{"ok":true}\n200\n' ;;
  *) printf '{}\n404\n' ;;
esac
CURL
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
cat > "$T/fakebin/timeout" <<'TO'
#!/bin/bash
echo "timeout $1 $(basename "$2")" >> "$TIMEOUTS"
shift; exec "$@"
TO
chmod +x "$T/fakebin/curl" "$T/fakebin/sleep" "$T/fakebin/timeout"

# row <id> <type> <project> <payload-json> [created_at] — one claimed row.
row() {
  jq -nc --arg id "$1" --arg t "$2" --arg p "$3" --arg pl "$4" --arg c "${5:-}" \
    '{command_id:$id, box:"project-4", type:$t, project:$p, payload:$pl, status:"claimed"}
     + (if $c == "" then {} else {created_at:$c} end)'
}
# claims <row>... — the fixture the first claim answers.
claims() { printf '%s\n' "$@" | jq -sc . > "$T/claim.json"; }

reset() {
  : > "$T/req.log"; : > "$T/calls.log"; : > "$T/timeouts.log"
  rm -f "$T/logs/box-console-commands.log" "$T/claim.json" "$T/mapcopy" "$T/mappath"
  echo project-4 > "$T/state/box-id"
}
run_lane() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" FLEET_CONF="$T/fleet.conf" \
      REQ_SINK="$T/req.log" CLAIM_FIX="$T/claim.json" CALLS="$T/calls.log" \
      TIMEOUTS="$T/timeouts.log" MAPCOPY="$T/mapcopy" MAPPATH="$T/mappath" \
      JOBS_RETRIES=0 LANE_GATE_DISABLE=1 ${EXTRA_ENV:-}
    unset BOX_ID
    bash "$T/bin/box-console-commands.sh" ) >"$T/out" 2>&1
}
nclaims() { jq -c 'select(.url|endswith("/api/box-console-commands/claim"))' "$T/req.log" | wc -l; }
# result <id> — the body of the result POST for that id (one line per post).
result() { jq -c --arg id "$1" 'select(.url|endswith("/api/box-console-commands/"+$id+"/result"))|.body|fromjson' "$T/req.log"; }
# wait_call <pattern> — detached launches land asynchronously.
wait_call() { local i; for i in $(seq 1 50); do grep -q -- "$1" "$T/calls.log" && return 0; /bin/sleep 0.1; done; return 1; }

# --- A1: fetch_log round trip; 4 claims; limit from the knob ------------------
reset
claims "$(row f1 fetch_log proj-a '{"which":"triage"}')"
run_lane; RC=$?
R=$(result f1)
[ "$RC" = 0 ] && [ "$(nclaims)" = 4 ] \
  && [ "$(jq -c 'select(.url|endswith("/claim"))|.body|fromjson' "$T/req.log" | sort -u)" = '{"box":"project-4","limit":10}' ] \
  && [ "$(jq -r .ok <<<"$R")" = 1 ] \
  && [ "$(jq -r .body <<<"$R")" = '{"tail":"hello from proj-a","which":"triage"}' ] \
  && grep -q '^fetch-log.sh|proj-a|triage|f1 ' "$T/calls.log" \
  && ok || bad "A1 rc=$RC claims=$(nclaims) result=$R calls=$(cat "$T/calls.log") out=$(head -c 300 "$T/out")"
reset
EXTRA_ENV="BOX_CONSOLE_COMMANDS_CLAIM_LIMIT=3" run_lane
[ "$(jq -c 'select(.url|endswith("/claim"))|.body|fromjson|.limit' "$T/req.log" | sort -u)" = 3 ] \
  && ok || bad "A1 limit knob: $(head -c 300 "$T/req.log")"

# --- A2: a row for a project this box does not own is refused, not run --------
reset
claims "$(row o1 fetch_log proj-b '{"which":"triage"}')"
run_lane
R=$(result o1)
[ "$(jq -r .ok <<<"$R")" = 0 ] && [ "$(jq -r .result <<<"$R")" = "refused: proj-b is not owned by project-4" ] \
  && ! grep -q '^fetch-log.sh' "$T/calls.log" \
  && ok || bad "A2 result=$R calls=$(cat "$T/calls.log")"

# --- A3: per-type argv, timeout bounds ---------------------------------------
reset
claims "$(row t1 run_triage proj-a '{}')" \
       "$(row t2 fetch_artifact proj-a '{"key":"BH-1","which":"plan"}')" \
       "$(row t3 chat proj-a '{"text":"hi there","origin":"tg"}')" \
       "$(row t4 update_company_map proj-a '{"content":"# map\nline"}')" \
       "$(row t5 chat_proposal proj-a '{"slug":"good-slug","message":"m1"}')" \
       "$(row t6 post_proposal proj-a '{"slug":"good-slug","notes":"n1"}')"
run_lane
wait_call '^run-triage.sh' && wait_call '^box-chat.sh' && wait_call '^product-cmd.sh|proj-a|chat_proposal'
grep -q '^run-triage.sh|proj-a fds' "$T/calls.log" && [ "$(jq -r '.ok,.result' <<<"$(result t1)" | tr '\n' ' ')" = "1 triage launched " ] \
  && ok || bad "A3 run_triage: $(cat "$T/calls.log") $(result t1)"
grep -q '^fetch-artifact.sh|--path|proj-a|BH-1|plan ' "$T/calls.log" && grep -q '^fetch-artifact.sh|proj-a|BH-1|plan|t2 ' "$T/calls.log" \
  && [ "$(jq -r .body <<<"$(result t2)")" = '{"artifact":"BH-1/plan"}' ] \
  && ok || bad "A3 fetch_artifact: $(grep fetch-artifact "$T/calls.log") $(result t2)"
CB=$(sed -n 's/^box-chat.sh|--b64|\([^|]*\)|t3 .*/\1/p' "$T/calls.log")
[ "$(printf '%s' "$CB" | base64 -d 2>/dev/null | jq -c .)" = '{"text":"hi there","command_id":"t3","origin":"tg","project":"proj-a"}' ] \
  && ok || bad "A3 chat b64: '$CB' -> $(printf '%s' "$CB" | base64 -d 2>/dev/null)"
MP=$(cat "$T/mappath" 2>/dev/null)
grep -qF "product-cmd.sh|proj-a|update_company_map|map|$MP " "$T/calls.log" && [ -n "$MP" ] \
  && [ "$(cat "$T/mapcopy")" = "$(printf '# map\nline')" ] && [ ! -e "$MP" ] \
  && [ "$(jq -r .ok <<<"$(result t4)")" = 1 ] \
  && ok || bad "A3 map: mp=$MP left=$([ -e "$MP" ] && echo yes) $(grep update_company_map "$T/calls.log") $(result t4)"
[ "$(sed -n 's/^product-cmd.sh|proj-a|chat_proposal|good-slug|\([^ ]*\) .*/\1/p' "$T/calls.log" | base64 -d | jq -c .)" = '{"message":"m1","origin":"dash"}' ] \
  && ok || bad "A3 chat_proposal: $(grep chat_proposal "$T/calls.log")"
[ "$(sed -n 's/^product-cmd.sh|proj-a|post_proposal|good-slug|\([^ ]*\) .*/\1/p' "$T/calls.log" | base64 -d)" = n1 ] \
  && [ "$(jq -r '.ok,.result' <<<"$(result t6)" | tr '\n' ' ')" = "1 product-cmd did post_proposal " ] \
  && ok || bad "A3 post_proposal: $(grep post_proposal "$T/calls.log") $(result t6)"
[ "$(sort -u "$T/timeouts.log")" = "$(printf 'timeout 30 fetch-artifact.sh\ntimeout 30 product-cmd.sh')" ] \
  && ok || bad "A3 timeouts: $(cat "$T/timeouts.log")"

# --- A4: hostile slugs and paths never reach a script ------------------------
reset
rm -f /tmp/x "$T/x"
i=0; ROWS=()
for s in 'a;touch /tmp/x' '../x' '$(id)' ''; do
  for ty in chat_proposal kill_proposal; do
    i=$((i+1)); ROWS+=("$(row "h$i" "$ty" proj-a "$(jq -nc --arg s "$s" '{slug:$s}')")")
  done
done
ROWS+=("$(row h-log fetch_log proj-a '{"which":"../../etc/passwd"}')")
ROWS+=("$(row h-art fetch_artifact proj-a '{"key":"BH-1/../x","which":"plan"}')")
claims "${ROWS[@]}"
run_lane; /bin/sleep 0.3
N=0; for id in $(seq 1 $i | sed 's/^/h/') h-log h-art; do
  R=$(result "$id")
  if [ "$(jq -r .ok <<<"$R")" = 0 ] && case "$(jq -r .result <<<"$R")" in refused*) true ;; *) false ;; esac; then N=$((N+1))
  else bad "A4 $id not refused: $R"; fi
done
[ "$N" = $((i+2)) ] && ! grep -q '^product-cmd.sh' "$T/calls.log" \
  && [ -z "$(grep -E '^fetch-(log|artifact)\.sh' "$T/calls.log" | grep -vE '^fetch-(log|artifact)\.sh\|--(path|error)\|')" ] \
  && [ ! -e /tmp/x ] && [ ! -e "$T/x" ] \
  && ok || bad "A4 calls=$(cat "$T/calls.log")"
[ "$(jq -r .body <<<"$(result h-log)")" = '{"error":"refused","which":"../../etc/passwd"}' ] \
  && ok || bad "A4 fetch_log refusal body: $(result h-log)"

# --- A5: empty inputs, non-fleet project, foreign type, bad JSON --------------
reset
claims "$(row e1 update_company_map proj-a '{"content":""}')" \
       "$(row e2 chat proj-a '{"text":""}')" \
       "$(row e4 merge_pr proj-a '{"pr":1}')" \
       "$(row e5 run_triage proj-a 'not json')" \
       "$(row e6 fetch_log proj-a '{"which":"triage","project":"proj-b"}')"
BEFORE=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -newer "$T/claim.json" 2>/dev/null | sort)
run_lane; /bin/sleep 0.3
AFTER=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -newer "$T/claim.json" 2>/dev/null | sort)
chk() { [ "$(jq -r '.ok,.result' <<<"$(result "$1")" | tr '\n' ' ')" = "0 $2 " ] && ok || bad "A5 $1: $(result "$1")"; }
chk e1 "refused: empty map content"
chk e2 "refused: empty chat text"
chk e4 "refused: merge_pr does not run on a box"
chk e5 "refused: payload is not JSON"
chk e6 "refused: payload project 'proj-b' does not match row project 'proj-a'"
[ ! -s "$T/calls.log" ] && ok || bad "A5 something ran: $(cat "$T/calls.log")"
[ "$BEFORE" = "$AFTER" ] && ok || bad "A5 temp file left: $(comm -13 <(echo "$BEFORE") <(echo "$AFTER"))"
# a project fleet.conf does not know: bcx_run itself refuses it
OUT=$( export HARNESS="$T" FLEET_CONF="$T/fleet.conf" CALLS="$T/calls.log"
  . "$T/bin/lib/box-cmd-exec.sh" && bcx_run run_triage proj-z '{}' z1 && printf '%s|%s' "$BCX_OK" "$BCX_RESULT")
[ "$OUT" = "0|refused: 'proj-z' is not a fleet.conf project" ] && ok || bad "A5 non-fleet project: '$OUT'"
# and the lane never lets it (or hub) that far
reset
claims "$(row z1 run_triage proj-z '{}')" "$(row z2 fetch_log hub '{"which":"triage"}')"
run_lane
[ "$(jq -r .result <<<"$(result z1)")" = "refused: proj-z is not owned by project-4" ] \
  && [ "$(jq -r .result <<<"$(result z2)")" = "refused: hub is not owned by project-4" ] && [ ! -s "$T/calls.log" ] \
  && ok || bad "A5 lane ownership of proj-z/hub: $(result z1) $(result z2)"

# --- A6: the hub never runs this lane ----------------------------------------
reset; echo hub > "$T/state/box-id"
claims "$(row x1 run_triage proj-a '{}')"
run_lane; RC=$?
[ "$RC" = 0 ] && [ ! -s "$T/req.log" ] && [ ! -s "$T/logs/box-console-commands.log" ] \
  && ok || bad "A6 hub rc=$RC reqs=$(wc -l < "$T/req.log")"

# --- A7: no box identity -> exit 0, no claim ---------------------------------
reset; rm -f "$T/state/box-id"
run_lane; RC=$?
[ "$RC" = 0 ] && [ "$(nclaims)" = 0 ] && ok || bad "A7 rc=$RC claims=$(nclaims)"

# --- A8: an empty run writes nothing; a busy one writes one counted line -----
reset
run_lane; RC=$?
[ "$RC" = 0 ] && [ ! -s "$T/logs/box-console-commands.log" ] && ok || bad "A8 empty run logged: $(cat "$T/logs/box-console-commands.log" 2>/dev/null)"
reset
claims "$(row c1 fetch_log proj-a '{"which":"triage"}')" "$(row c2 fetch_log proj-b '{"which":"triage"}')"
run_lane
[ "$(wc -l < "$T/logs/box-console-commands.log")" = 1 ] && grep -q 'claimed=2 done=1 failed=1$' "$T/logs/box-console-commands.log" \
  && ok || bad "A8 busy log: $(cat "$T/logs/box-console-commands.log" 2>/dev/null)"

# --- A9: a failed claim is one line and exit 0, no ALERTS --------------------
reset; : > "$T/logs/ALERTS.log"
EXTRA_ENV="CLAIM_MODE=503" run_lane; RC=$?
[ "$RC" = 0 ] && [ "$(nclaims)" = 1 ] && [ "$(wc -l < "$T/logs/box-console-commands.log")" = 1 ] \
  && grep -q 'claim failed rc=1 http=503' "$T/logs/box-console-commands.log" && [ ! -s "$T/logs/ALERTS.log" ] \
  && ok || bad "A9 rc=$RC claims=$(nclaims) log=$(cat "$T/logs/box-console-commands.log" 2>/dev/null) alerts=$(cat "$T/logs/ALERTS.log")"
# A9b: a failed result post names the id, is not counted done, is not re-run
reset
claims "$(row p1 fetch_log proj-a '{"which":"triage"}')"
EXTRA_ENV="RESULT_MODE=500" run_lane; RC=$?
[ "$RC" = 0 ] && grep -q 'result post failed id=p1 type=fetch_log rc=1 http=500' "$T/logs/box-console-commands.log" \
  && grep -q 'claimed=1 done=0 failed=1$' "$T/logs/box-console-commands.log" \
  && [ "$(grep -c '^fetch-log.sh|proj-a|triage|p1 ' "$T/calls.log")" = 1 ] \
  && ok || bad "A9b log=$(cat "$T/logs/box-console-commands.log" 2>/dev/null) calls=$(cat "$T/calls.log")"

# --- A10: the registry entry ------------------------------------------------
J="$DIR/catalog/lanes.d/box-console-commands.json"
# TEST-CHANGE (BH-5747): the box list is fleet.conf's watcher boxes, read from
# the registry rather than pinned as a count, so a registered box needs no edit here.
WATCHERS=$(FLEET_CONF="$DIR/fleet.conf" "$DIR/bin/fleet-conf.sh" --box-ids | grep -vx hub | jq -R . | jq -cs 'sort')
[ "$WATCHERS" != "[]" ] && [ "$(jq -c '.boxes|sort' "$J" 2>/dev/null)" = "$WATCHERS" ] \
  && [ "$(jq -r '[.id,.scope,.script,((.boxes|index("hub"))|tostring),.switch.name]|join(" ")' "$J" 2>/dev/null)" \
    = "box-console-commands box bin/box-console-commands.sh null lane-off-box-console-commands" ] \
  && [ "$(jq -c '[.knobs[]|[.env,.default]]' "$J" 2>/dev/null)" = '[["BOX_CONSOLE_COMMANDS_CLAIM_LIMIT",10],["BOX_CONSOLE_COMMANDS_TTL_S",300]]' ] \
  && ok || bad "A10 registry entry: $(jq -c . "$J" 2>&1 | head -c 300)"

# --- A11: a held lock is dedupe (exit 0, no claim); children drop fd 9 --------
reset
( exec 9>"$T/locks/box-console-commands.lock"; flock 9; /bin/sleep 3 ) &
HOLD=$!; /bin/sleep 0.3
run_lane; RC=$?
kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null
[ "$RC" = 0 ] && [ "$(nclaims)" = 0 ] && ok || bad "A11 lock held: rc=$RC claims=$(nclaims)"
reset
claims "$(row l1 run_triage proj-a '{}')"
run_lane; wait_call '^run-triage.sh'
FDS=$(sed -n 's/^run-triage.sh|proj-a fds=//p' "$T/calls.log")
[ -n "$FDS" ] && ! case ",$FDS" in *,9,*|*,7,*) true ;; *) false ;; esac \
  && ok || bad "A11b detached child fds='$FDS'"

# --- A12: no model strings, no #2518 names; poll-commands kept separate -----
PRODUCT=("$LANE" "$BCX" "$DIR/catalog/lanes.d/box-console-commands.json" "$DIR/cron/lanes/011-box-console-commands.cron")
[ -z "$(grep -E 'claude-[a-z0-9-]+' "${PRODUCT[@]}" 2>&1)" ] && [ -z "$(grep -E '\bbox_commands\b|box_cmd_[a-z]' "${PRODUCT[@]}" 2>&1)" ] \
  && ok || bad "A12 forbidden token: $(grep -nE 'claude-[a-z0-9-]+|\bbox_commands\b|box_cmd_[a-z]' "${PRODUCT[@]}" 2>&1 | head -5)"
# A12b: the two lanes never share a claim route or a lock (plan: "neither lane
# can take the other's rows"). Pinned as that invariant, not as a diff against
# origin/main: a diff held BH-2655's own "don't edit poll-commands" to every
# later PR, and BH-2314 edits poll-commands' alerts re-beat by design.
# BH-2657 makes poll-commands the queue's PRODUCER (box_ccmd_forward) and its
# expiry sweeper (box_ccmd_expire), so what it must never do is CLAIM a row or
# take this lane's lock.
PC="$DIR/bin/poll-commands.sh"
grep -q '/api/commands/claim' "$PC" && grep -q 'locks/poller.lock' "$PC" \
  && ! grep -qE 'box_ccmd_claim|/api/box-console-commands/claim|locks/box-console-commands\.lock' "$PC" \
  && grep -q 'box_ccmd_claim' "$LANE" && grep -q 'locks/box-console-commands.lock' "$LANE" \
  && grep -q '/api/box-console-commands/claim' "$DIR/bin/lib/jobs/box-console-commands.sh" \
  && ! grep -qE '/api/commands/claim|locks/poller\.lock' "$LANE" "$DIR/bin/lib/jobs/box-console-commands.sh" \
  && ok || bad "A12b poll-commands and the box lane share a claim route or a lock"

# --- A13: project-4's crontab carries the lane, the hub's does not ----------------
C=$(HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/render-cron.sh" project-4 2>/dev/null | grep -c 'box-console-commands.sh')
Hh=$(HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/render-cron.sh" hub 2>/dev/null | grep -c 'box-console-commands.sh')
[ "$C" -ge 1 ] && [ "$Hh" = 0 ] && ok || bad "A13 render-cron project-4=$C hub=$Hh"

# --- A14: a row older than the TTL is refused; a fresh one runs ---------------
reset
claims "$(row s1 run_triage proj-a '{}' 2000-01-01T00:00:00Z)" \
       "$(row s2 fetch_log proj-a '{"which":"triage"}' "$(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)")"
run_lane; /bin/sleep 0.3
case "$(jq -r '.ok,.result' <<<"$(result s1)" | tr '\n' ' ')" in
  "0 refused: expired (queued "*"s ago, ttl 300s) ") ok ;; *) bad "A14 stale row: $(result s1)" ;; esac
! grep -q '^run-triage.sh' "$T/calls.log" && [ "$(jq -r .ok <<<"$(result s2)")" = 1 ] \
  && ok || bad "A14 stale ran or fresh refused: $(cat "$T/calls.log") $(result s2)"

echo "box-console-commands lane: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
