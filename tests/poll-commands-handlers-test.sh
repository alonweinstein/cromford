#!/bin/bash
# tests/poll-commands-handlers-test.sh — runs the fetch_log / fetch_artifact
# case bodies EXTRACTED VERBATIM from bin/poll-commands.sh against a fixture
# harness. The unit tests next door prove the resolvers; this proves the glue
# the poller actually executes — and specifically the invariant that is easy to
# lose in a refactor: EVERY exit beats.
#
# The console pane is keyed on log:<command_id> / artifact:<command_id>. A
# refusal or a dead box that answers with silence is indistinguishable from a
# fetch still in flight, and a box being down is exactly when someone is
# staring at that pane waiting for it to say something.
#
# Extraction is anchored on the `# >>> <name> handler` / `# <<< <name> handler`
# markers in poll-commands.sh — moving the block is fine, deleting a marker
# fails this test loudly rather than silently skipping it.
# Run from anywhere: tests/poll-commands-handlers-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin" "$T/logs" "$T/fakebin" "$T/builds/alpha-os-TK-88-202608230900"
cp "$DIR/bin/fetch-log.sh" "$DIR/bin/fetch-artifact.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$T/bin/"
# BH-2657: a local fetch runs through bcx_run and a far one is queued as a
# box_console_commands row, so the fixture carries the real libs and client.
cp -r "$DIR/bin/lib" "$T/bin/lib"; cp "$DIR/bin/jobs-client.sh" "$T/bin/"
# Stub jobs worker: records {argv,url} and answers per $WORKER (200, 500, 502
# with an HTML page, down = connection refused, hang = curl's timeout rc 28).
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
{ printf '%s' "$*" | tr '\n' ' '; echo; } >> "$CURL_LOG"   # one line per call
case "${WORKER:-200}" in
  500)  printf '{"error":"boom"}\n500\n' ;;
  502)  printf '<html>Bad Gateway</html>\n502\n' ;;
  down) exit 7 ;;
  hang) exit 28 ;;
  *)    printf '{"created":true}\n200\n' ;;
esac
CURL
chmod +x "$T/fakebin/curl"
cat > "$T/fleet.conf" <<'EOF'
alpha-os Org/alpha https://a.example /api/board 2 local
remote-os Org/remote https://r.example /api/board 4 box-remote
EOF
export FLEET_CONF="$T/fleet.conf"
echo "a triage line" > "$T/logs/alpha-os.log"
echo "a plan" > "$T/builds/alpha-os-TK-88-202608230900/plan.md"
# beat.sh stand-in: append every payload so a test can count and inspect them.
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> %s/BEATS.jsonl\n' "$T" > "$T/bin/beat.sh"
chmod +x "$T/bin/beat.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

extract() { # extract <handler-name> -> a sourceable case body
  awk -v n="$1" '
    $0 ~ "^    # >>> " n " handler" {f=1; next}
    $0 ~ "^    # <<< " n " handler" {exit}
    f {print}' "$DIR/bin/poll-commands.sh" \
    | sed -e "1s/^    ${1})//" -e '$s/ ;;$//'
}
for H in fetch_log fetch_artifact; do
  extract "$H" > "$T/$H.body"
  [ -s "$T/$H.body" ] || { echo "FAIL: could not extract the $H handler — markers missing?"; exit 1; }
done

run() { # run <handler> <command-id> <payload-json>; echoes "OK=.. RESULT=.."
  HARNESS="$T" BEAT="$T/bin/beat.sh" ID="$2" PROJECT="alpha-os" PAYLOAD="$3" OK=false RESULT="" \
    PATH="$T/fakebin:$PATH" CURL_LOG="$T/CURL.log" JOBS_URL=https://jobs.invalid HARNESS_SECRET=test-secret JOBS_RETRIES=0 \
    bash -c 'set -uo pipefail
      . "$HARNESS/bin/jobs-client.sh"; . "$HARNESS/bin/lib/jobs/box-console-commands.sh"
      . "$HARNESS/bin/lib/box-cmd-exec.sh"; . "$HARNESS/bin/lib/cron-lines.sh"
      . "$0"; echo "OK=$OK RESULT=$RESULT"' "$T/$1.body"
}
beats() { local n=0; [ -f "$T/BEATS.jsonl" ] && n=$(grep -c . "$T/BEATS.jsonl" 2>/dev/null); echo "${n:-0}"; }
last()  { tail -1 "$T/BEATS.jsonl" 2>/dev/null; }
reset() { : > "$T/BEATS.jsonl"; : > "$T/CURL.log"; }

# ---------- 1. happy path still beats the real tail ----------
reset; OUT=$(run fetch_log c1 '{"project":"alpha-os","which":"triage"}')
grep -q 'OK=true' <<<"$OUT" && [ "$(beats)" -eq 1 ] \
  && [ "$(jq -r .kind <<<"$(last)")" = log_tail ] \
  && [ "$(jq -r .error <<<"$(last)")" = null ] \
  && ok || bad "fetch_log happy path (out=$OUT beats=$(beats))"

reset; OUT=$(run fetch_artifact c2 '{"project":"alpha-os","key":"TK-88","which":"plan"}')
grep -q 'OK=true' <<<"$OUT" && [ "$(beats)" -eq 1 ] \
  && [ "$(jq -r .kind <<<"$(last)")" = artifact_tail ] \
  && ok || bad "fetch_artifact happy path (out=$OUT beats=$(beats))"

# ---------- 2. REFUSED still beats ----------
reset; OUT=$(run fetch_log c3 '{"project":"alpha-os","which":"/etc/passwd"}')
grep -q 'OK=false' <<<"$OUT" && [ "$(beats)" -eq 1 ] \
  && [ "$(jq -r .rkey <<<"$(last)")" = "log:c3" ] \
  && [ "$(jq -r .error <<<"$(last)")" = refused ] \
  && [ "$(jq -r .content <<<"$(last)")" = "" ] \
  && [ "$(jq -r .missing <<<"$(last)")" = true ] \
  && ok || bad "refused fetch_log must still beat (out=$OUT beat=$(last))"

reset; OUT=$(run fetch_artifact c4 '{"project":"alpha-os","key":"../../etc","which":"plan"}')
grep -q 'OK=false' <<<"$OUT" && [ "$(beats)" -eq 1 ] \
  && [ "$(jq -r .rkey <<<"$(last)")" = "artifact:c4" ] \
  && [ "$(jq -r .error <<<"$(last)")" = refused ] \
  && ok || bad "refused fetch_artifact must still beat (out=$OUT beat=$(last))"

# ---------- 3. a forward that fails still beats ----------
# remote-os is queued for its box as a box_console_commands row. A worker that
# answers 500, answers an HTML error page, refuses the connection or times out
# is a forward that did not happen, and the pane must hear fetch_failed.
for W in 500 502 down hang; do
  reset; OUT=$(WORKER=$W run fetch_log c5 '{"project":"remote-os","which":"alerts"}')
  grep -q 'OK=false' <<<"$OUT" && [ "$(beats)" -eq 1 ] \
    && [ "$(jq -r .rkey <<<"$(last)")" = "log:c5" ] \
    && [ "$(jq -r .error <<<"$(last)")" = fetch_failed ] \
    && [ "$(jq -r .missing <<<"$(last)")" = true ] \
    && ok || bad "worker $W: a failed forward must still beat fetch_failed (out=$OUT beat=$(last))"
  reset; OUT=$(WORKER=$W run fetch_artifact c6 '{"project":"remote-os","key":"TK-1","which":"review"}')
  grep -q 'OK=false' <<<"$OUT" && [ "$(beats)" -eq 1 ] && [ "$(jq -r .error <<<"$(last)")" = fetch_failed ] \
    && [ "$(jq -r .rkey <<<"$(last)")" = "artifact:c6" ] \
    && ok || bad "worker $W: a failed artifact forward must still beat fetch_failed (out=$OUT beat=$(last))"
done
# A queued forward is not an answer: the box posts the tail to the row and the
# console reads it there, so the hub beats nothing.
reset; OUT=$(run fetch_log c7 '{"project":"remote-os","which":"alerts"}')
grep -q 'OK=true RESULT=queued for box-remote' <<<"$OUT" && [ "$(beats)" -eq 0 ] \
  && ok || bad "a queued fetch must ack queued and not beat (out=$OUT beats=$(beats))"

# ---------- 4. the forward is time-bounded ----------
# The poller holds poller.lock while it forwards, so chat, merges and triage all
# queue behind a hung call. The hand-off is ONE curl with a total deadline.
[ "$(grep -c . "$T/CURL.log")" -eq 1 ] && grep -qE '(^| )-m [0-9]+ ' "$T/CURL.log" \
  && ok || bad "the forward must be one curl bounded by -m (got: $(cat "$T/CURL.log"))"

# ---------- 5. every exit above beat exactly once ----------
# Two beats for one command would double-render the pane; zero would hang it.
reset
run fetch_log c8 '{"project":"alpha-os","which":"triage"}' >/dev/null
run fetch_log c9 '{"project":"alpha-os","which":"nope"}' >/dev/null
run fetch_artifact c10 '{"project":"alpha-os","key":"TK-88","which":"qa"}' >/dev/null
[ "$(beats)" -eq 3 ] && ok || bad "three commands should produce exactly three beats (got $(beats))"

echo "poll-commands-handlers-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
