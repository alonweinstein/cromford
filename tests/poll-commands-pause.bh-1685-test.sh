#!/bin/bash
# tests/poll-commands-pause.bh-1685-test.sh — BH-1685 (BH-1672.4): the poller's
# pause handlers and the flags beat's env_pauses field, run from the blocks
# EXTRACTED VERBATIM from bin/poll-commands.sh.
#
# pause_board / resume_board keep the flag file as the box's authority and
# ALSO write the worker's pauses row; pause_set / pause_end write only the row,
# so a failed write is a failed command. Every gate that picks which row gets
# written or ended is tried with adversarial input and must not call out.
#
# Extraction is anchored on `# >>> pause handlers` / `# <<< pause handlers` and
# `# >>> flags beats` / `# <<< flags beats`; a missing marker fails loudly.
# Run from anywhere: tests/poll-commands-pause.bh-1685-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/h/flags" "$T/h/bin"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The four case arms, wrapped back into a case so the body is sourceable.
{ echo 'case "$TYPE" in'
  awk '/^    # >>> pause handlers/{f=1;next} /^    # <<< pause handlers/{exit} f{print}' "$DIR/bin/poll-commands.sh"
  echo 'esac'
} > "$T/pause.body"
[ "$(wc -l < "$T/pause.body")" -gt 3 ] || { echo "FAIL: could not extract the pause handlers block — markers missing?"; exit 1; }

awk '/^# >>> flags beats/{f=1;next} /^# <<< flags beats/{exit} f{print}' "$DIR/bin/poll-commands.sh" > "$T/flags.body"
[ -s "$T/flags.body" ] || { echo "FAIL: could not extract the flags beats block"; exit 1; }

# _jobs_req stand-in: every call is recorded as "METHOD PATH BODY" in CALLS.
# STUB_RC is the rc for writes; a GET answers STUB_GET on rc 0.
# The PUT enforces the worker's own body rules (worker/jobs/src/routes/pauses.js,
# #1874): a reason or actor that is blank once trimmed is a 400, which the real
# _jobs_req (bin/lib/jobs/req.sh) returns as rc 1 with JOBS_HTTP=400. A fake
# that answers 200 to anything pins a guessed contract, not the worker's.
cat > "$T/stubs.sh" <<'EOF'
set_flag() {
  printf 'set_flag %s\n' "$*" >> "$STUB_LOG"
  case "${2:-}" in on) touch "$HARNESS/flags/$1" ;; off) rm -f "$HARNESS/flags/$1" ;; esac
  return 0
}
_jobs_req() {
  printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$CALLS"
  if [ "$1" = GET ]; then JOBS_HTTP=200; printf '%s' "${STUB_GET:-}"; return 0; fi
  if [ "$1 $2" = "PUT /api/pauses" ]; then
    local f
    for f in reason actor; do
      if [ -z "$(jq -r --arg f "$f" '.[$f] // "" | tostring | sub("^\\s+"; "") | sub("\\s+$"; "")' <<<"${3:-}" 2>/dev/null)" ]; then
        JOBS_HTTP=400; JOBS_BODY="{\"error\":\"$f required\"}"; return 1
      fi
    done
  fi
  case "${STUB_RC:-0}" in
    0) JOBS_HTTP=200; printf '{}'; return 0 ;;
    2) JOBS_HTTP=404; return 2 ;;
    *) JOBS_HTTP=""; return 1 ;;
  esac
}
EOF

CALLS="$T/calls.log"; STUB_LOG="$T/stub.log"
run() { # run <type> <payload-json> [stub_rc] -> "OK=.. RESULT=.."
  : > "$CALLS"; : > "$STUB_LOG"
  HARNESS="$T/h" CALLS="$CALLS" STUB_LOG="$STUB_LOG" STUB_RC="${3:-0}" STUB_GET="${STUB_GET:-}" \
    TYPE="$1" PROJECT="${PROJECT_OVERRIDE:-project-3}" PAYLOAD="$2" ID=42 OK=false RESULT="" \
    bash -c 'set -uo pipefail; . "$0"; . "$1"; echo "OK=$OK RESULT=$RESULT"' "$T/stubs.sh" "$T/pause.body"
}
ncalls() { grep -c . "$CALLS" 2>/dev/null || true; }
body_of() { sed -n "${1}p" "$CALLS" | cut -d' ' -f3-; }

echo "--- pause_set"
OUT=$(run pause_set '{"what":"merges","reason":"x","ttl_s":3600}')
[ "$(ncalls)" = 1 ] && [ "$(cut -d' ' -f1-2 "$CALLS")" = "PUT /api/pauses" ] \
  && [ "$(body_of 1 | jq -c -S .)" = '{"actor":"console","reason":"x","scope":"project-3","ttl_s":3600,"what":"merges"}' ] \
  && grep -q '^OK=true RESULT=paused merges on project-3$' <<<"$OUT" \
  && ok || bad "pause_set happy path (out=$OUT calls=$(cat "$CALLS"))"

OUT=$(run pause_set '{"what":"merges","reason":"x","ttl_s":3600}' 1)
grep -q '^OK=false' <<<"$OUT" && ! grep -q 'RESULT=paused' <<<"$OUT" && grep -q 'unreachable' <<<"$OUT" \
  && ok || bad "pause_set with the worker down must fail honestly (out=$OUT)"

OUT=$(run pause_set '{"what":"merges","reason":"x"}' 2)
grep -q '^OK=false RESULT=pause not recorded: http=404$' <<<"$OUT" \
  && ok || bad "pause_set on a 404 must fail (out=$OUT)"

OUT=$(run pause_set '{"what":"reviews","reason":"r"}')
[ "$(body_of 1 | jq -c -S .)" = '{"actor":"console","reason":"r","scope":"project-3","what":"reviews"}' ] \
  && grep -q '^OK=true' <<<"$OUT" \
  && ok || bad "pause_set with no ttl omits ttl_s so the worker default applies (body=$(body_of 1))"

echo "--- the worker's reason rule (400 on a blank reason)"
# The fake itself: a blank reason is refused, a supplied one lands. If this
# half fails, every assertion below is testing a fake, not the contract.
( CALLS=/dev/null; . "$T/stubs.sh"
  _jobs_req PUT /api/pauses '{"scope":"project-3","what":"merges","reason":"  ","actor":"console"}' >/dev/null
  echo "rc=$? http=$JOBS_HTTP"
  _jobs_req PUT /api/pauses '{"scope":"project-3","what":"merges","reason":"freeze","actor":"console"}' >/dev/null
  echo "rc=$? http=$JOBS_HTTP" ) > "$T/fake.out"
[ "$(cat "$T/fake.out")" = $'rc=1 http=400\nrc=0 http=200' ] \
  && ok || bad "the fake must 400 a blank reason and 200 a supplied one ($(tr '\n' ' ' < "$T/fake.out"))"
# No reason from the caller (the MCP tool, a bare console action, a blank
# form): the handler names the console as the reason instead of sending the
# blank the worker rejects, so the row lands.
DEFAULT_REASON='paused from console, no reason given'
for P in '{"what":"reviews"}' '{"what":"reviews","reason":""}' '{"what":"reviews","reason":"   "}' '{"what":"reviews","reason":null}'; do
  OUT=$(run pause_set "$P")
  [ "$(body_of 1 | jq -r .reason)" = "$DEFAULT_REASON" ] && grep -q '^OK=true RESULT=paused reviews on project-3$' <<<"$OUT" \
    && ok || bad "pause_set $P must send the default reason and land (out=$OUT body=$(body_of 1))"
done
for P in '{}' '{"reason":""}' '{"reason":"  "}'; do
  rm -f "$T/h/flags/paused-project-3"
  OUT=$(run pause_board "$P")
  [ -f "$T/h/flags/paused-project-3" ] && [ "$(body_of 1 | jq -r .reason)" = "$DEFAULT_REASON" ] \
    && grep -q '^OK=true RESULT=paused$' <<<"$OUT" \
    && ok || bad "pause_board $P must record the row with the default reason (out=$OUT body=$(body_of 1))"
done
# A supplied reason is sent as typed (trimmed), never replaced by the default.
OUT=$(run pause_board '{"reason":"  release freeze "}')
[ "$(body_of 1 | jq -r .reason)" = 'release freeze' ] && grep -q '^OK=true RESULT=paused$' <<<"$OUT" \
  && ok || bad "pause_board keeps a supplied reason (out=$OUT body=$(body_of 1))"

echo "--- fleet scope (the console routes it to the hub: project=hub, scope=fleet)"
OUT=$(PROJECT_OVERRIDE=hub run pause_set '{"what":"builds","reason":"fleet freeze","scope":"fleet"}')
[ "$(body_of 1 | jq -c -S .)" = '{"actor":"console","reason":"fleet freeze","scope":"fleet","what":"builds"}' ] \
  && grep -q '^OK=true RESULT=paused builds on fleet$' <<<"$OUT" \
  && ok || bad "a fleet-scope pause_set writes scope fleet (out=$OUT body=$(body_of 1))"
OUT=$(PROJECT_OVERRIDE=hub run pause_set '{"what":"builds","reason":"x"}')
[ "$(ncalls)" = 0 ] && grep -q '^OK=false RESULT=refused: no project$' <<<"$OUT" \
  && ok || bad "a hub command with no fleet scope must not write a row scoped 'hub' (out=$OUT calls=$(ncalls))"
for S in FLEET 'fleet ' other; do
  OUT=$(run pause_set "$(jq -nc --arg s "$S" '{what:"builds",reason:"x",scope:$s}')")
  [ "$(body_of 1 | jq -r .scope)" = project-3 ] \
    && ok || bad "scope '$S' is not the fleet: the row stays on the command's project (body=$(body_of 1))"
done

for W in all '' MERGES 'merges;x'; do
  OUT=$(run pause_set "$(jq -nc --arg w "$W" '{what:$w}')")
  [ "$(ncalls)" = 0 ] && grep -q '^OK=false RESULT=refused: invalid what$' <<<"$OUT" \
    && ok || bad "pause_set what='$W' must be refused with no call (out=$OUT calls=$(ncalls))"
done
# "1e3" as a STRING: a bare JSON 1e3 is 1000 to jq 1.6 (a valid ttl there) and
# "1E+3" to jq 1.7, so only the string form is refused on every box's jq.
for TTL in 0 -1 1.5 '"1e3"' '"3600 "' '"abc"' '""' true; do
  OUT=$(run pause_set "{\"what\":\"merges\",\"ttl_s\":$TTL}")
  [ "$(ncalls)" = 0 ] && grep -q '^OK=false RESULT=refused: invalid ttl_s$' <<<"$OUT" \
    && ok || bad "pause_set ttl_s=$TTL must be refused with no call (out=$OUT calls=$(ncalls))"
done
# Injection-shaped reason travels as data, never as JSON syntax.
OUT=$(run pause_set '{"what":"builds","reason":"a\",\"scope\":\"fleet"}')
[ "$(body_of 1 | jq -r .scope)" = project-3 ] && [ "$(body_of 1 | jq -r .reason)" = 'a","scope":"fleet' ] \
  && ok || bad "a quote in the reason must not rewrite the scope (body=$(body_of 1))"

echo "--- pause_end"
OUT=$(run pause_end '{"id":7}')
[ "$(ncalls)" = 1 ] && [ "$(cut -d' ' -f1-2 "$CALLS")" = "POST /api/pauses/7/end" ] && grep -q '^OK=true' <<<"$OUT" \
  && ok || bad "pause_end happy path (out=$OUT calls=$(cat "$CALLS"))"
OUT=$(run pause_end '{"id":"7"}' 2)
grep -q '^OK=false RESULT=no such pause 7$' <<<"$OUT" && ok || bad "pause_end 404 (out=$OUT)"
OUT=$(run pause_end '{"id":7}' 1)
grep -q '^OK=false' <<<"$OUT" && ok || bad "pause_end with the worker down (out=$OUT)"
for PID in '"7;rm -rf /"' '"../x"' '""' 'null' '"7/end"'; do
  OUT=$(run pause_end "{\"id\":$PID}")
  [ "$(ncalls)" = 0 ] && grep -q '^OK=false RESULT=refused: invalid id$' <<<"$OUT" \
    && ok || bad "pause_end id=$PID must be refused with no call (out=$OUT calls=$(ncalls))"
done

echo "--- pause_board"
rm -f "$T/h/flags/paused-project-3"
OUT=$(run pause_board '{"reason":"deploy","ttl_s":600}')
[ -f "$T/h/flags/paused-project-3" ] && [ "$(cut -d' ' -f1-2 "$CALLS")" = "PUT /api/pauses" ] \
  && [ "$(body_of 1 | jq -c -S .)" = '{"actor":"console","reason":"deploy","scope":"project-3","ttl_s":600,"what":"triage"}' ] \
  && grep -q '^OK=true RESULT=paused$' <<<"$OUT" \
  && ok || bad "pause_board writes the flag AND the triage row (out=$OUT calls=$(cat "$CALLS"))"

rm -f "$T/h/flags/paused-project-3"
OUT=$(run pause_board '{}' 1)
[ -f "$T/h/flags/paused-project-3" ] && grep -q '^OK=true RESULT=paused (flag set; pause row not recorded: http=unreachable)$' <<<"$OUT" \
  && ok || bad "pause_board with the worker down keeps the flag and says the row is missing (out=$OUT)"

rm -f "$T/h/flags/paused-project-3"
# TEST-CHANGE (pause expiry): a dropped ttl_s no longer means "omit it and let
# the worker's generic 24h default apply" — that silent 24h lapse is the bug.
# The bad value is still dropped (never sent, never refused) and the board's
# own settings-row default (PAUSE_BOARD_TTL_S, 604800) is sent in its place;
# tests/pause-board-expiry-test.sh pins the knob itself.
OUT=$(run pause_board '{"ttl_s":-3}')
[ -f "$T/h/flags/paused-project-3" ] && [ "$(body_of 1 | jq '.ttl_s')" = 604800 ] && grep -q '^OK=true' <<<"$OUT" \
  && ok || bad "pause_board drops a bad ttl_s and still pauses (body=$(body_of 1) out=$OUT)"

echo "--- resume_board"
touch "$T/h/flags/paused-project-3"
# Mixed rows: another project's triage, this project's merges and a fleet
# triage must all survive — only id 7 is this board's triage pause.
MIXED='{"pauses":[
  {"id":7,"scope":"project-3","what":"triage","ended_at":null},
  {"id":8,"scope":"project-3","what":"merges","ended_at":null},
  {"id":9,"scope":"project-5","what":"triage","ended_at":null},
  {"id":10,"scope":"fleet","what":"triage","ended_at":null},
  {"id":11,"scope":"project-3","what":"triage","ended_at":"2026-09-24T00:00:00Z"}],"truncated":false}'
OUT=$(STUB_GET="$MIXED" run resume_board '{}')
[ ! -f "$T/h/flags/paused-project-3" ] \
  && [ "$(grep -c '^POST' "$CALLS")" = 1 ] && grep -q '^POST /api/pauses/7/end' "$CALLS" \
  && grep -q '^GET /api/pauses?active=1&scope=project-3' "$CALLS" \
  && grep -q '^OK=true RESULT=resumed$' <<<"$OUT" \
  && ok || bad "resume_board clears the flag and ends only this project's triage row (out=$OUT calls=$(cat "$CALLS"))"

OUT=$(STUB_GET='{"pauses":[]}' run resume_board '{}')
[ "$(grep -c '^POST' "$CALLS")" = 0 ] && grep -q '^OK=true RESULT=resumed$' <<<"$OUT" \
  && ok || bad "resume_board with no row is a plain resumed (out=$OUT)"

touch "$T/h/flags/paused-project-3"
OUT=$(STUB_GET='{"pauses":[{"id":7,"scope":"project-3","what":"triage","ended_at":null}]}' run resume_board '{}' 1)
[ ! -f "$T/h/flags/paused-project-3" ] && grep -q '^OK=true RESULT=resumed (flag cleared; pause row not ended: http=unreachable)$' <<<"$OUT" \
  && ok || bad "resume_board with the end failing says so (out=$OUT)"

echo "--- the console lib and this handler agree (console-ui/src/lib/pauses.js)"
# What the Project PAUSE form and the Fleet END button build is what these
# handlers read. The action endpoint between them (cromford-console
# applyAction) passes reason/ttl_s/what/id/scope through and routes a fleet
# scope to project "hub"; this drives the lib's real output through the real
# handler with that routing applied, so a drift on either side is red here.
PLIB="$DIR/console-ui/src/lib/pauses.js"
[ -r "$PLIB" ] && ok || bad "missing $PLIB"
if ! command -v node >/dev/null 2>&1; then
  echo "poll-commands-pause: lib-agreement SKIPPED — node is not installed on this box"
else
  LIBOUT=$(node --input-type=module -e "
import { PAUSE_WHATS, pauseCommandFor, endCommandFor } from '$PLIB';
const o = {
  whats: [...PAUSE_WHATS].sort().join(' '),
  blank: pauseCommandFor('project-3', { what: 'merges', reason: '  ', ttlS: '' }),
  set: pauseCommandFor('project-3', { what: 'merges', reason: ' freeze ', ttlS: '600' }),
  board: pauseCommandFor('project-3', { what: 'triage', reason: 'deploy', ttlS: '' }),
  fleetEnd: endCommandFor({ id: 9, scope: 'fleet', what: 'builds' })
};
console.log(JSON.stringify(o));
" 2>&1)
  # The poller's own what whitelist, read from the handler it runs.
  PWHATS=$(sed -n 's/^ *case "\$PWHAT" in \([a-z|]*\)) ;;.*/\1/p' "$T/pause.body" | tr '|' '\n' | sort | paste -sd' ' -)
  [ -n "$PWHATS" ] && [ "$(jq -r .whats <<<"$LIBOUT")" = "$PWHATS" ] \
    && ok || bad "PAUSE_WHATS and the pause_set whitelist differ (lib=$(jq -r .whats <<<"$LIBOUT" 2>/dev/null) poller=$PWHATS out=$LIBOUT)"
  [ "$(jq -r .blank.error <<<"$LIBOUT")" = 'reason required' ] \
    && ok || bad "the form must refuse a blank reason itself, not lean on the poller's default ($LIBOUT)"
  # The payload the endpoint enqueues is the command minus type/project.
  toPayload() { jq -c "$1 | del(.type, .project)" <<<"$LIBOUT"; }
  OUT=$(run pause_set "$(toPayload .set)")
  [ "$(body_of 1 | jq -c -S .)" = '{"actor":"console","reason":"freeze","scope":"project-3","ttl_s":600,"what":"merges"}' ] \
    && grep -q '^OK=true' <<<"$OUT" \
    && ok || bad "the form's pause_set lands as typed (out=$OUT body=$(body_of 1))"
  rm -f "$T/h/flags/paused-project-3"
  OUT=$(run pause_board "$(toPayload .board)")
  [ "$(body_of 1 | jq -r .reason)" = deploy ] && grep -q '^OK=true RESULT=paused$' <<<"$OUT" \
    && ok || bad "the form's pause_board lands with its reason (out=$OUT body=$(body_of 1))"
  [ "$(jq -r .fleetEnd.scope <<<"$LIBOUT")" = fleet ] && [ "$(jq -r '.fleetEnd.project // "none"' <<<"$LIBOUT")" = none ] \
    && ok || bad "a fleet END names scope fleet and no project, so the endpoint routes it to the hub ($LIBOUT)"
  OUT=$(PROJECT_OVERRIDE=hub run pause_end "$(toPayload .fleetEnd)")
  [ "$(cut -d' ' -f1-2 "$CALLS")" = "POST /api/pauses/9/end" ] && grep -q '^OK=true RESULT=pause 9 ended$' <<<"$OUT" \
    && ok || bad "a fleet END routed to the hub ends that row (out=$OUT calls=$(cat "$CALLS"))"
fi

echo "--- flags beat env_pauses"
cat > "$T/h/bin/fleet-projects-or-alert.sh" <<'EOF'
#!/bin/bash
echo "p1 p2"
EOF
chmod +x "$T/h/bin/fleet-projects-or-alert.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> %s/BEATS.jsonl\n' "$T" > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
flagsrun() { # flagsrun <env_shapes-definition>
  : > "$T/BEATS.jsonl"
  ( export HARNESS="$T/h" BEAT="$T/h/bin/beat.sh"
    eval "$1"
    # shellcheck source=/dev/null
    . "$T/flags.body" ) >/dev/null 2>&1
}
# The contract stub, verbatim from the lib.
flagsrun ". '$DIR/bin/lib/pause.sh'"
[ "$(grep -c . "$T/BEATS.jsonl")" = 2 ] && [ "$(jq -s -c '[.[].env_pauses]' "$T/BEATS.jsonl")" = '[[],[]]' ] \
  && ok || bad "with the contract stub every flags beat carries env_pauses [] ($(cat "$T/BEATS.jsonl"))"
flagsrun "pause_env_shapes() { printf '[{\"what\":\"reviews\"}]'; }"
[ "$(jq -s -c '[.[].env_pauses]' "$T/BEATS.jsonl")" = '[[{"what":"reviews"}],[{"what":"reviews"}]]' ] \
  && ok || bad "env_pauses carries what pause_env_shapes prints ($(cat "$T/BEATS.jsonl"))"
flagsrun "pause_env_shapes() { printf 'garbage{'; }"
[ "$(jq -s -c '[.[].env_pauses]' "$T/BEATS.jsonl")" = '[[],[]]' ] \
  && ok || bad "garbage from pause_env_shapes is [] ($(cat "$T/BEATS.jsonl"))"
flagsrun "unset -f pause_env_shapes 2>/dev/null; true"
[ "$(jq -s -c '[.[].env_pauses]' "$T/BEATS.jsonl")" = '[[],[]]' ] && [ "$(jq -s -c '[.[].paused]' "$T/BEATS.jsonl")" = '[false,false]' ] \
  && ok || bad "no lib at all still beats, env_pauses [] ($(cat "$T/BEATS.jsonl"))"

echo "poll-commands-pause: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
