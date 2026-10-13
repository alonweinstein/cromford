#!/bin/bash
# tests/run-decompose-inapp-deps-test.sh — the in-app decompose lane writes the
# dependencies itself, from the keys and ids the create calls returned
# (BH-3965, slice 4 of BH-3946).
#
# Before this ticket the board lane asked a model to POST the children, and
# fc-board.sh's decompose arm dropped the contract from `dependsOn`. Now the
# model writes children.json only and the harness files it through
# file_children -> fc_file_board:
#   - a board that advertises `capabilities: ["dependencies"]` gets `parentId`
#     + `dependsOn` = [contract id, then any `after` sibling ids] and NO
#     `Blocked-by:` text line;
#   - a board that does not gets `Blocked-by: <contract key> (hard)[, …]` with
#     the keys the board returned, never `<KEY>.<n>`, and no dependency fields.
# `flags/decompose-board-filer-off` puts back the model-filed path and the
# BH-866 label re-map.
#
#   F1  file_children, decompose, no capability: Blocked-by text from create keys
#   F2  file_children, capability: dependsOn [contract, siblings], no Blocked-by
#   F2b resume after a failed create 3: child 3's ids come from the sidecar
#   D1  the real bin/run-decompose.sh, board lane, spec present, no capability
#   D1b an invalid board spec (1 child) is refused before any POST
#   D1c no spec: the model is asked for children.json only, then the harness files
#   D2  D1 with the capability
#   D3  decompose-board-filer-off: the model files, BH-866 re-map, no harness create
#   D4  DECOMPOSE_DRY_RUN=1 on the board lane: no model call, nothing sent
#
# A `curl` stub on PATH plays the board (the tests/fc-board.bh-983-test.sh
# pattern): it logs every argv line, keeps every --data-binary body, and answers
# a create with {ticket:{id:"c<n>",key:"LG-<40+n>"}} keyed by the
# Idempotency-Key's position. No network, no real board, no model.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

DEC="$DIR/bin/run-decompose.sh"
H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" lg-os || exit 1
mkdir -p "$H/bin/lib" "$H/logs" "$H/env" "$H/prompts" "$T/stub"
cp "$DIR/bin/fleet-conf.sh" "$H/bin/"
cat > "$H/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset> [box] [ip]
lg-os  example-org/lg-os  https://lg.example  /api/board  3 box-1
CONF
: > "$H/env/global.env"
printf 'LG_INTERNAL_API_TOKEN=tok-FIXTURE-3965\nLG_API_BASE=https://lg.example\n' > "$H/env/lg-os.env"
BASE="https://lg.example/api/board"

cat > "$T/stub/curl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$CURL_LOG"
seq=$(wc -l < "$CURL_LOG" | tr -d ' ')
method=GET; url=""; data=""; k=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift ;;
    --data-binary) data="$2"; shift ;;
    -d) shift ;;
    -H) case "$2" in Idempotency-Key:*) k="${2##*-}" ;; esac; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
[ -n "$data" ] && cp "${data#@}" "$CURL_BODIES/$seq.json"
case "$method $url" in
  "GET "*/boards)
    if [ "${CURL_CAP:-0}" = 1 ]; then printf '[{"id":"bd-1","capabilities":["dependencies"]}]\n'
    else printf '[{"id":"bd-1","capabilities":["reactions"]}]\n'; fi ;;
  "GET "*/boards/bd-1/tickets)
    cat "$CURL_LIST" ;;
  "GET "*/tickets/p9)
    printf '{"ticket":{"id":"p9","key":"LG-9","priority":"high","boardId":"bd-1"}}\n' ;;
  "POST "*/boards/bd-1/tickets)
    [ "$k" = "${CURL_FAIL_CREATE:-x}" ] && exit 22
    printf '{"ticket":{"id":"c%s","key":"LG-%s"}}\n' "$k" "$((40 + k))" ;;
  "POST "*/comments) printf '{"ok":true}\n' ;;
  "POST "*/move) printf '{"ticket":{"status":"in_progress"}}\n' ;;
  *) exit 22 ;;
esac
exit 0
SH
chmod +x "$T/stub/curl"

# The model. AGENT_MODE=spec writes the spec, labels files "the way a model did"
# (title labels in children.txt), anything else writes nothing.
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf 'AGENT CALL: %s %s\n' "$1" "$2" >> "$AGENT_LOG"
printf '%s' "$6" > "$AGENT_PROMPT"
B=$(dirname "$5")
case "${AGENT_MODE:-}" in
  spec)   cat "$AGENT_SPEC" > "$B/children.json"; echo DECOMPOSE_SPEC_READY > "$5" ;;
  labels) printf 'LG-9.0\nLG-9.1\n' > "$B/children.txt"; echo 'DECOMPOSED: LG-9.0,LG-9.1' > "$5" ;;
esac
exit 0
SH
chmod +x "$H/bin/agent-call.sh"

# Child 3 names the contract (dropped: it is seeded once) and sibling 2.
SPEC='[{"title":"tracer","contract":"src/x.ts: x()","after":[],"body":"The tracer.\n\n## Observable outcome\nGET /x answers."},
 {"title":"list","after":[],"body":"The list.\n\n## Observable outcome\nthe list renders."},
 {"title":"export","after":["1: types","2: x"],"body":"The export.\n\n## Observable outcome\nthe CSV downloads."}]'
printf '%s\n' "$SPEC" > "$T/spec.json"
# The board as the legacy model left it: two children titled with their labels.
printf '%s\n' '{"tickets":[{"key":"LG-61","id":"c61","title":"LG-9.0: contract — tracer","createdAt":"2026-10-03T10:00:00Z"},
 {"key":"LG-62","id":"c62","title":"LG-9.1: list","createdAt":"2026-10-03T10:01:00Z"}]}' > "$T/list.json"

_reset() { : > "$T/curl.log"; : > "$T/agent.log"; : > "$T/prompt.txt"; rm -rf "$T/bodies"; mkdir -p "$T/bodies"; }
_env() {
  env HARNESS="$H" FLEET_CONF="$H/fleet.conf" PATH="$T/stub:$PATH" \
    CURL_LOG="$T/curl.log" CURL_BODIES="$T/bodies" CURL_LIST="$T/list.json" \
    AGENT_LOG="$T/agent.log" AGENT_PROMPT="$T/prompt.txt" AGENT_SPEC="$T/spec.json" "$@"
}
# fcb <build> [VAR=value …] — file_children through the repo's real dispatch.
fcb() {
  local b="$1"; shift; _reset; mkdir -p "$b"
  _env "$@" bash -c '. "$1/bin/lib/file-children.sh" || exit 9
    file_children lg-os p9 LG-9 "$2" "$2/children.json"; rc=$?
    printf "%s" "${FC_ERROR:-}" > "$3/fc_error.txt"; exit $rc' _ "$DIR" "$b" "$T"
}
# dec <build> [VAR=value …] — the real bin/run-decompose.sh, stdout to $T/dec.out.
dec() {
  local b="$1"; shift; _reset; mkdir -p "$b"
  _env "$@" bash "$DEC" lg-os p9 LG-9 "$b" 300 12 > "$T/dec.out" 2>&1
}
creates() { grep -c -- "-X POST .*$BASE/boards/bd-1/tickets\$" "$T/curl.log"; }
body_of() { # body_of <n-th create> -> the JSON it sent
  local seq; seq=$(grep -n -- "-X POST .*/boards/bd-1/tickets\$" "$T/curl.log" | sed -n "${1}p" | cut -d: -f1)
  cat "$T/bodies/$seq.json" 2>/dev/null
}
desc_of() { body_of "$1" | jq -r '.description // empty'; }
blocked_of() { desc_of "$1" | grep -o 'Blocked-by: [^<]*'; }
keys() { paste -sd' ' "$1/children.txt" 2>/dev/null; }

# --- F1 -------------------------------------------------------------------
B="$T/f1"; mkdir -p "$B"; cp "$T/spec.json" "$B/children.json"
fcb "$B"; RC=$?
[ "$RC" = 0 ] && ok || bad "F1 rc=$RC: $(cat "$T/fc_error.txt")"
[ "$(creates)" = 3 ] && ok || bad "F1 three creates, got $(creates)"
[ "$(blocked_of 2)" = 'Blocked-by: LG-41 (hard)' ] && ok || bad "F1 child 2 has exactly one 'Blocked-by: LG-41 (hard)': '$(blocked_of 2)'"
[ "$(blocked_of 3)" = 'Blocked-by: LG-41 (hard), LG-42 (hard)' ] && ok || bad "F1 child 3 blocked on the contract then sibling 2: '$(blocked_of 3)'"
[ -z "$(blocked_of 1)" ] && ok || bad "F1 the contract waits on nothing: '$(blocked_of 1)'"
for n in 1 2 3; do
  [ "$(body_of $n | jq 'has("parentId") or has("dependsOn")')" = false ] && ok || bad "F1 child $n carries dependency fields: $(body_of $n)"
  grep -qE 'LG-9\.[0-9]' <<<"$(desc_of $n)" && bad "F1 child $n description names a title label: $(desc_of $n)" || ok
done
[ "$(keys "$B")" = 'LG-41 LG-42 LG-43' ] && ok || bad "F1 children.txt: $(keys "$B")"

# --- F2 -------------------------------------------------------------------
B="$T/f2"; mkdir -p "$B"; cp "$T/spec.json" "$B/children.json"
fcb "$B" CURL_CAP=1; RC=$?
[ "$RC" = 0 ] && ok || bad "F2 rc=$RC: $(cat "$T/fc_error.txt")"
[ "$(body_of 1 | jq -c .dependsOn)" = '[]' ] && ok || bad "F2 child 1 dependsOn: $(body_of 1)"
[ "$(body_of 2 | jq -c '[.parentId, .dependsOn]')" = '["p9",["c1"]]' ] && ok || bad "F2 child 2 [parentId, dependsOn]: $(body_of 2)"
[ "$(body_of 3 | jq -c '[.parentId, .dependsOn]')" = '["p9",["c1","c2"]]' ] && ok || bad "F2 child 3 [parentId, dependsOn]: $(body_of 3)"
for n in 1 2 3; do
  grep -q 'Blocked-by:' <<<"$(desc_of $n)" && bad "F2 child $n still carries a Blocked-by line: $(desc_of $n)" || ok
done
for n in 2 3; do
  desc_of $n | grep -q 'DEPENDS: LG-41 hard' && ok || bad "F2 child $n lost its DEPENDS line: $(desc_of $n)"
done

# --- F2b ------------------------------------------------------------------
B="$T/f2b"; mkdir -p "$B"; cp "$T/spec.json" "$B/children.json"
fcb "$B" CURL_CAP=1 CURL_FAIL_CREATE=3; RC=$?
[ "$RC" != 0 ] && ok || bad "F2b a failed create 3 returned 0"
[ "$(keys "$B")" = 'LG-41 LG-42' ] && ok || bad "F2b the record holds children 1-2: $(keys "$B")"
fcb "$B" CURL_CAP=1; RC=$?
[ "$RC" = 0 ] && ok || bad "F2b resume rc=$RC: $(cat "$T/fc_error.txt")"
[ "$(creates)" = 1 ] && ok || bad "F2b only child 3 re-created, got $(creates)"
[ "$(body_of 1 | jq -c .dependsOn)" = '["c1","c2"]' ] && ok || bad "F2b child 3 dependsOn from the sidecar: $(body_of 1)"

# --- D1 -------------------------------------------------------------------
B="$T/d1"; mkdir -p "$B"; cp "$T/spec.json" "$B/children.json"
dec "$B"; RC=$?
[ "$RC" = 0 ] && ok || bad "D1 rc=$RC: $(cat "$T/dec.out") $(cat "$B/decompose-run.txt" 2>/dev/null) $(tail -5 "$B/pipeline.log" 2>/dev/null)"
[ ! -s "$T/agent.log" ] && ok || bad "D1 a spec in the build dir must buy no model call: $(cat "$T/agent.log")"
[ "$(creates)" = 3 ] && ok || bad "D1 the harness files three children, got $(creates)"
[ "$(blocked_of 2)" = 'Blocked-by: LG-41 (hard)' ] && ok || bad "D1 child 2 Blocked-by from the create answer: '$(blocked_of 2)'"
for n in 1 2 3; do grep -qE 'LG-9\.[0-9]' <<<"$(desc_of $n)" && bad "D1 child $n names a title label" || ok; done
[ "$(keys "$B")" = 'LG-41 LG-42 LG-43' ] && ok || bad "D1 children.txt: $(keys "$B")"
grep -q -- "-X POST .*$BASE/tickets/p9/move\$" "$T/curl.log" && ok || bad "D1 the master is parked: $(cat "$T/curl.log")"

# --- D1b ------------------------------------------------------------------
B="$T/d1b"; mkdir -p "$B"; jq -c '[.[0]]' "$T/spec.json" > "$B/children.json"
dec "$B"; RC=$?
[ "$RC" = 1 ] && ok || bad "D1b a one-child spec must fail rc 1, got $RC"
grep -q 'DECOMPOSE_FAILED' "$B/decompose-run.txt" 2>/dev/null && ok || bad "D1b decompose-run.txt: $(cat "$B/decompose-run.txt" 2>/dev/null)"
grep -q -- '-X POST' "$T/curl.log" && bad "D1b nothing may be sent: $(cat "$T/curl.log")" || ok

# --- D1c ------------------------------------------------------------------
B="$T/d1c"; mkdir -p "$B"
dec "$B" AGENT_MODE=spec; RC=$?
[ "$RC" = 0 ] && ok || bad "D1c rc=$RC: $(cat "$B/decompose-run.txt" 2>/dev/null)"
[ "$(grep -c 'AGENT CALL: decompose lg-os' "$T/agent.log")" = 1 ] && ok || bad "D1c one decompose call: $(cat "$T/agent.log")"
for P in "$B/children.json" 'YOU DO NOT FILE ANYTHING' '/root/harness/prompts/lg-os.md' 'Ticket LG-9 (id p9)'; do
  grep -qF -- "$P" "$T/prompt.txt" && ok || bad "D1c the prompt must say '$P'"
done
for N in 'gh issue view' 'POST .../boards' 'ai-build label'; do
  grep -qF -- "$N" "$T/prompt.txt" && bad "D1c the board prompt must not say '$N'" || ok
done
[ "$(keys "$B")" = 'LG-41 LG-42 LG-43' ] && ok || bad "D1c the harness filed the spec: $(keys "$B")"

# --- D2 -------------------------------------------------------------------
B="$T/d2"; mkdir -p "$B"; cp "$T/spec.json" "$B/children.json"
dec "$B" CURL_CAP=1; RC=$?
[ "$RC" = 0 ] && ok || bad "D2 rc=$RC: $(cat "$B/decompose-run.txt" 2>/dev/null)"
[ "$(body_of 2 | jq -c '[.parentId, .dependsOn]')" = '["p9",["c1"]]' ] && ok || bad "D2 child 2: $(body_of 2)"
[ "$(body_of 3 | jq -c '[.parentId, .dependsOn]')" = '["p9",["c1","c2"]]' ] && ok || bad "D2 child 3: $(body_of 3)"
for n in 1 2 3; do grep -q 'Blocked-by:' <<<"$(desc_of $n)" && bad "D2 child $n carries Blocked-by text" || ok; done

# --- D3 -------------------------------------------------------------------
B="$T/d3"; mkdir -p "$B" "$H/flags"; cp "$T/spec.json" "$B/children.json"
: > "$H/flags/decompose-board-filer-off"
dec "$B" AGENT_MODE=labels; RC=$?
rm -f "$H/flags/decompose-board-filer-off"
[ "$RC" = 0 ] && ok || bad "D3 rc=$RC: $(cat "$B/decompose-run.txt" 2>/dev/null)"
grep -q 'AGENT CALL: decompose lg-os' "$T/agent.log" && ok || bad "D3 the switch must put the model back on the filing: $(cat "$T/agent.log")"
grep -q 'Create each child on the SAME board' "$T/prompt.txt" && ok || bad "D3 the legacy filing prompt"
[ "$(keys "$B")" = 'LG-61 LG-62' ] && ok || bad "D3 BH-866 re-map: $(keys "$B")"
[ "$(creates)" = 0 ] && ok || bad "D3 the harness must create nothing, got $(creates)"

# --- D4 -------------------------------------------------------------------
B="$T/d4"; mkdir -p "$B"; cp "$T/spec.json" "$B/children.json"
dec "$B" DECOMPOSE_DRY_RUN=1; RC=$?
[ "$RC" = 0 ] && ok || bad "D4 rc=$RC: $(cat "$T/dec.out")"
[ ! -s "$T/agent.log" ] && ok || bad "D4 a dry run buys no model call: $(cat "$T/agent.log")"
grep -q '^DRYRUN curl ' "$T/dec.out" && ok || bad "D4 the dry run prints its curls: $(cat "$T/dec.out")"
[ ! -s "$T/curl.log" ] && ok || bad "D4 the dry run sent: $(cat "$T/curl.log")"

echo "run-decompose-inapp-deps: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
