#!/bin/bash
# tests/board-conformance-board.bh-3947-test.sh — the in-app board probe,
# bc_probe_board in bin/lib/board-conformance/board.sh (BH-3959, slice 2 of
# BH-3947).
#
# Every case drives the REAL bin/board-conformance.sh, copied into a scratch
# harness by tests/lib/board-conformance-fixture.sh, with the stub curl
# answering from tests/fixtures/board-conformance/board-*. The origin and writes
# libs are swapped for no-op stubs (setup below; they are real probes since
# BH-3960 and have their own suite), so the item set in the state file is
# board.sh's own.
# Fixed BC_NOW, no sleep, no network.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/board-conformance-board.bh-3947-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/board-conformance-fixture.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

ENTRY="$DIR/bin/board-conformance.sh"
LIB="$DIR/bin/lib/board-conformance/board.sh"
LIVE_BEFORE=$(ls -la /root/harness/state/board-conformance 2>/dev/null)
ALLCURL="$T/curl.all"; : > "$ALLCURL"

[ -x "$ENTRY" ] || { echo "FAIL: $ENTRY missing"; exit 1; }
run() { OUT=$("$HARNESS/bin/board-conformance.sh" "$@" 2>"$T/err"); RC=$?; cat "$CURL_LOG" >> "$ALLCURL"; }
ST() { printf '%s' "$HARNESS/state/board-conformance/p1.json"; }
# js <jq filter> — true when the filter holds on p1's state file
js() { jq -e "$1" "$(ST)" >/dev/null 2>&1; }
# item <name> <status> — the state records <name> with <status>
item() { js ".items[\"$1\"].status==\"$2\""; }
note() { jq -r ".items[\"$1\"].note" "$(ST)" 2>/dev/null; }
# fx_copy <fixture> <name> — a writable copy of a fixture dir as the case's FX
fx_copy() { rm -rf "$T/fx-$2"; cp -r "$DIR/tests/fixtures/board-conformance/$1" "$T/fx-$2"; export FX="$T/fx-$2"; }
# setup — the fixture with origin.sh and writes.sh as no-op stubs, as
# board-conformance-origin.bh-3960-test.sh stubs board.sh: this suite pins
# board.sh's GETs and items only.
setup() {
  bc_fixture_setup || return 1
  printf '# shellcheck shell=bash\nbc_probe_origin() { :; }\n' > "$HARNESS/bin/lib/board-conformance/origin.sh"
  printf '# shellcheck shell=bash\nbc_write_routes() { :; }\n' > "$HARNESS/bin/lib/board-conformance/writes.sh"
}

NAMES='["boards.capability.dependencies","boards.envelope","boards.id","boards.keyPrefix","detail.comments","detail.envelope","ticket.commentCount","ticket.dependencies","ticket.id","ticket.key","ticket.labels","ticket.lastActivityAt","ticket.reporter.userId","ticket.status","ticket.title","ticket.triageVerdict","ticket.turnChangedAt","ticket.type","ticket.updatedAt","ticket.waitingOn"]'

# --- C-static ------------------------------------------------------------------
check "C-static bash -n" 'bash -n "$LIB"'
if command -v shellcheck >/dev/null 2>&1; then
  check "C-static shellcheck" 'shellcheck -S error "$LIB" >/dev/null'
fi
check "C-static no harness root, no project name (D43)" '! grep -qE "/root/harness|p1|p2" "$LIB"'
check "C-static no ALERTS write" '! grep -q ALERTS "$LIB"'
check "C-static no sleep, no clock" '! grep -qE "sleep|date " "$LIB"'
check "C-static GETs go through bc_get only" '! grep -qE "(^|[^_])curl " "$LIB"'
check "C-static capability jq is fc-board.sh verbatim" 'grep -qF "(.boards? // .) | if type == \"array\" then (.[0].capabilities | if type == \"array\" then any(.[]; . == \"dependencies\") else false end) else false end" "$LIB" && grep -qF "(.boards? // .) | if type == \"array\" then (.[0].capabilities | if type == \"array\" then any(.[]; . == \"dependencies\") else false end) else false end" "$DIR/bin/lib/fc-board.sh"'

# --- C1: a conformant board ----------------------------------------------------
setup || bad "fixture setup"; bc_fixture_case board-ok
run p1
check "C1 rc 0 (got $RC: $(cat "$T/err"))" '[ "$RC" -eq 0 ]'
check "C1 all 20 names" "js '(.items|keys)==$NAMES'"
check "C1 every item ok (got $(jq -c '[.items|to_entries[]|select(.value.status!="ok")|.key]' "$(ST)" 2>/dev/null))" "js '[.items[].status]|all(.==\"ok\")'"
check "C1 no gaps" "js '.gaps==[]'"
check "C1 summary (got: $OUT)" '[ "$OUT" = "p1 ok=20 missing=0 malformed=0 unverified=0 gaps: " ]'
check "C1 the three GETs, in order" '[ "$(grep -oE "https://[^ ]+" "$CURL_LOG" | tr "\n" " ")" = "https://p1.example/api/board/boards https://p1.example/api/board/boards/b1/tickets https://p1.example/api/board/tickets/t1 " ]'
check "C14 at most 3 curl calls on one run (got $(wc -l < "$CURL_LOG"))" '[ "$(wc -l < "$CURL_LOG")" -le 3 ]'
check "C1 the bearer is sent" '[ "$(grep -c "Authorization: Bearer tok-p1" "$CURL_LOG")" -eq 3 ]'

# --- C-d404: the detail route 404s ---------------------------------------------
setup || bad "fixture setup"; fx_copy board-ok d404
rm -f "$FX/api_board_tickets_t1.code.txt"
run p1
check "C-d404 rc 1 (got $RC)" '[ "$RC" -eq 1 ]'
check "C-d404 detail.envelope missing" 'item detail.envelope missing'
check "C-d404 detail.comments missing" 'item detail.comments missing'
check "C-d404 gaps are the detail pair" "js '.gaps==[\"detail.comments\",\"detail.envelope\"]'"

# --- C2: a row without reporter, a row with triageVerdict "" -------------------
setup || bad "fixture setup"; bc_fixture_case board-c2
run p1
check "C2 rc 1 (got $RC)" '[ "$RC" -eq 1 ]'
check "C2 reporter.userId missing" 'item ticket.reporter.userId missing'
check "C2 reporter note (got $(note ticket.reporter.userId))" '[ "$(note ticket.reporter.userId)" = "absent on 1/3" ]'
check "C2 triageVerdict malformed" 'item ticket.triageVerdict malformed'
check "C2 triageVerdict note (got $(note ticket.triageVerdict))" '[ "$(note ticket.triageVerdict)" = "1/3" ]'
check "C2 exactly those two gaps" "js '.gaps==[\"ticket.reporter.userId\",\"ticket.triageVerdict\"]'"

# --- C-mut (D1): the "" triageVerdict test is what makes C2 red ----------------
setup || bad "fixture setup"; bc_fixture_case board-c2
ORIG_SUM=$(cksum < "$HARNESS/bin/lib/board-conformance/board.sh")
sed -i 's/(type == "string" and \. != "")/(type == "string" and true)/' "$HARNESS/bin/lib/board-conformance/board.sh"
check "C-mut sed changed the scratch copy" '[ "$(cksum < "$HARNESS/bin/lib/board-conformance/board.sh")" != "$ORIG_SUM" ]'
run p1
check "C-mut triageVerdict is no longer malformed (C2 goes red)" '! item ticket.triageVerdict malformed'
check "C-mut shipped lib untouched" '[ "$(cksum < "$LIB")" = "$ORIG_SUM" ]'

# --- C4: capability + blocked "true" -------------------------------------------
setup || bad "fixture setup"; bc_fixture_case board-c4
run p1
check "C4 rc 1 (got $RC)" '[ "$RC" -eq 1 ]'
check "C4 ticket.dependencies malformed" 'item ticket.dependencies malformed'
check "C4 note (got $(note ticket.dependencies))" '[ "$(note ticket.dependencies)" = "1/2" ]'
check "C4 the only gap" "js '.gaps==[\"ticket.dependencies\"]'"

# --- C5: no capability + blocked:true; capability + parentId "" ----------------
setup || bad "fixture setup"; bc_fixture_case board-c5-nocap
run p1
check "C5-nocap ticket.dependencies malformed" 'item ticket.dependencies malformed'
check "C5-nocap note (got $(note ticket.dependencies))" '[ "$(note ticket.dependencies)" = "1/2 rows served without the dependencies capability" ]'
check "C5-nocap capability missing" 'item boards.capability.dependencies missing'
setup || bad "fixture setup"; bc_fixture_case board-c5-parent
run p1
check "C5-parent ticket.dependencies malformed" 'item ticket.dependencies malformed'
check "C5-parent the only gap" "js '.gaps==[\"ticket.dependencies\"]'"
# capability + a row with no dependency keys at all -> missing
setup || bad "fixture setup"; fx_copy board-ok depabs
jq -c '.[1] |= del(.children)' "$FX/api_board_boards_b1_tickets.json" > "$T/x" && mv "$T/x" "$FX/api_board_boards_b1_tickets.json"
run p1
check "C5-absent ticket.dependencies missing" 'item ticket.dependencies missing'
check "C5-absent note (got $(note ticket.dependencies))" '[ "$(note ticket.dependencies)" = "absent on 1/2" ]'

# --- C7: detail in a {ticket} envelope -----------------------------------------
setup || bad "fixture setup"; bc_fixture_case board-c7
run p1
check "C7 rc 0 (got $RC)" '[ "$RC" -eq 0 ]'
check "C7 detail.envelope ok" 'item detail.envelope ok'
check "C7 detail.comments ok" 'item detail.comments ok'
# a detail body with no id and no comments
setup || bad "fixture setup"; fx_copy board-ok dbad
echo '{"ticket":{"title":"x"}}' > "$FX/api_board_tickets_t1.json"
run p1
check "C7-bad detail.envelope malformed" 'item detail.envelope malformed'
check "C7-bad detail.comments missing" 'item detail.comments missing'

# --- C15: the capability on board[1] only --------------------------------------
setup || bad "fixture setup"; bc_fixture_case board-c15
run p1
check "C15 capability missing" 'item boards.capability.dependencies missing'
check "C15 ticket.dependencies judged without the capability" 'item ticket.dependencies malformed && [ "$(note ticket.dependencies)" = "2/2 rows served without the dependencies capability" ]'

# --- C16: /boards transport failures are a failed probe, never a gap -----------
for c in 000 500 401; do
  setup || bad "fixture setup"; bc_fixture_case "board-c16-$c"
  run p1
  check "C16-$c rc 3 (got $RC)" '[ "$RC" -eq 3 ]'
  check "C16-$c state failed, no items" "js '.probe==\"failed\" and (.probe_note|test(\"/boards\")) and .items=={} and .gaps==[]'"
  check "C16-$c note names the code (got $(jq -r .probe_note "$(ST)"))" "js '.probe_note==\"GET /api/board/boards $c\"'"
  check "C16-$c no alert call" '[ ! -s "$CALLS" ]'
  check "C16-$c one GET only" '[ "$(wc -l < "$CURL_LOG")" -eq 1 ]'
done
# a transport failure on the 2nd or 3rd GET is also a failed probe
setup || bad "fixture setup"; fx_copy board-ok t503
echo 503 > "$FX/api_board_boards_b1_tickets.code.txt"
run p1
check "C16-tickets-503 rc 3 (got $RC)" '[ "$RC" -eq 3 ] && js ".probe==\"failed\" and .items=={} and (.probe_note|test(\"tickets 503\"))"'
setup || bad "fixture setup"; fx_copy board-ok d000
echo 000 > "$FX/api_board_tickets_t1.code.txt"
run p1
check "C16-detail-000 rc 3 (got $RC)" '[ "$RC" -eq 3 ] && js ".probe==\"failed\" and .items=={} and (.probe_note|test(\"tickets/t1 000\"))"'

# --- C17: adversarial negatives are not gaps -----------------------------------
for v in board-c17 board-c17-bare; do
  setup || bad "fixture setup"; bc_fixture_case "$v"
  run p1
  check "$v rc 0 (got $RC: $OUT)" '[ "$RC" -eq 0 ]'
  check "$v no gaps (got $(jq -c .gaps "$(ST)" 2>/dev/null))" "js '.gaps==[]'"
  check "$v all 20 ok" "js '(.items|keys)==$NAMES and ([.items[].status]|all(.==\"ok\"))'"
  check "$v numeric ids reach the URLs" 'grep -q "/api/board/boards/42/tickets" "$CURL_LOG" && grep -q "/api/board/tickets/7 *$" "$CURL_LOG"'
done

# --- C-empty: zero tickets is unverified, never ok, never a gap ----------------
setup || bad "fixture setup"; bc_fixture_case board-empty-tickets
run p1
check "C-empty rc 0 (got $RC)" '[ "$RC" -eq 0 ]'
check "C-empty ticket.* and detail.* unverified" "js '([.items|to_entries[]|select(.key|test(\"^(ticket|detail)[.]\"))|.value] | length==16 and all(.status==\"unverified\" and .note==\"board has no tickets\"))'"
check "C-empty boards.* ok" "js '[.items|to_entries[]|select(.key|startswith(\"boards.\"))|.value.status]==[\"ok\",\"ok\",\"ok\",\"ok\"]'"
check "C-empty no gaps" "js '.gaps==[]'"
check "C-empty no detail GET" '[ "$(wc -l < "$CURL_LOG")" -eq 2 ]'

# --- C-env404 / C-envbad / C-kp --------------------------------------------------
setup || bad "fixture setup"; fx_copy base env404
run p1
check "C-env404 rc 1 (got $RC)" '[ "$RC" -eq 1 ]'
check "C-env404 boards.envelope missing, the only gap" "js '.items[\"boards.envelope\"].status==\"missing\" and .gaps==[\"boards.envelope\"]'"
check "C-env404 the other 19 unverified" "js '[.items|to_entries[]|select(.key!=\"boards.envelope\")|.value]|length==19 and all(.status==\"unverified\" and .note==\"no board list\")'"
check "C-env404 one GET only" '[ "$(wc -l < "$CURL_LOG")" -eq 1 ]'
for body in '{"x":1}' '<html>login</html>' '"boards"'; do
  setup || bad "fixture setup"; fx_copy board-ok envbad
  printf '%s\n' "$body" > "$FX/api_board_boards.json"
  run p1
  check "C-envbad $body boards.envelope malformed" 'item boards.envelope malformed && js ".gaps==[\"boards.envelope\"]"'
done
setup || bad "fixture setup"; fx_copy board-ok env403
echo 403 > "$FX/api_board_boards.code.txt"
run p1
check "C-env403 is malformed, not a failed probe (got $RC)" '[ "$RC" -eq 1 ] && item boards.envelope malformed && [ "$(note boards.envelope)" = "GET boards 403" ]'
setup || bad "fixture setup"; fx_copy board-ok emptyboards
echo '{"boards":[]}' > "$FX/api_board_boards.json"
run p1
check "C-emptyboards envelope ok, the rest unverified" "js '.items[\"boards.envelope\"].status==\"ok\" and ([.items|to_entries[]|select(.key!=\"boards.envelope\")|.value]|length==19 and all(.status==\"unverified\" and .note==\"board list is empty\")) and .gaps==[]'"
setup || bad "fixture setup"; fx_copy board-ok kp5
echo '[{"id":"b1","keyPrefix":5,"capabilities":["dependencies"]},{"keyPrefix":"P2"}]' > "$FX/api_board_boards.json"
run p1
check "C-kp keyPrefix 5 malformed" 'item boards.keyPrefix malformed'
check "C-kp boards.id missing on 1/2" 'item boards.id missing && [ "$(note boards.id)" = "absent on 1/2" ]'
setup || bad "fixture setup"; fx_copy board-ok kpabs
echo '[{"id":"b1","capabilities":["dependencies"]}]' > "$FX/api_board_boards.json"
run p1
check "C-kp keyPrefix absent missing" 'item boards.keyPrefix missing'
setup || bad "fixture setup"; fx_copy board-ok noid
echo '[{"keyPrefix":"P1","capabilities":["dependencies"]}]' > "$FX/api_board_boards.json"
run p1
check "C-noid ticket.* and detail.* unverified" "js '[.items|to_entries[]|select(.key|test(\"^(ticket|detail)[.]\"))|.value]|length==16 and all(.status==\"unverified\" and .note==\"board[0] has no id\")'"
check "C-noid one GET only" '[ "$(wc -l < "$CURL_LOG")" -eq 1 ]'

# --- the ticket list itself: 404, non-array, mixed absent + wrong type ----------
setup || bad "fixture setup"; fx_copy board-ok t404
rm -f "$FX/api_board_boards_b1_tickets.code.txt"
run p1
check "C-t404 every ticket.* missing" "js '[.items|to_entries[]|select(.key|startswith(\"ticket.\"))|.value]|length==14 and all(.status==\"missing\" and .note==\"GET tickets 404\")'"
check "C-t404 detail.* unverified" 'item detail.envelope unverified && item detail.comments unverified'
setup || bad "fixture setup"; fx_copy board-ok tobj
echo '{"rows":[]}' > "$FX/api_board_boards_b1_tickets.json"
run p1
check "C-tobj every ticket.* malformed" "js '[.items|to_entries[]|select(.key|startswith(\"ticket.\"))|.value.status]|length==14 and all(.==\"malformed\")'"
setup || bad "fixture setup"; fx_copy board-ok mixed
jq -c '.[0].commentCount="2" | .[1] |= del(.commentCount) | .[0].key=null | .[0].number=3.5 | .[1].reporter=null | .[0].labels="a" | .[1].type=5' \
  "$FX/api_board_boards_b1_tickets.json" > "$T/x" && mv "$T/x" "$FX/api_board_boards_b1_tickets.json"
run p1
check "C-mixed commentCount missing beats malformed (got $(note ticket.commentCount))" 'item ticket.commentCount missing && [ "$(note ticket.commentCount)" = "absent on 1/2; wrong type on 1/2" ]'
check "C-mixed key number 3.5 malformed" 'item ticket.key malformed'
check "C-mixed reporter null is absent" 'item ticket.reporter.userId missing'
check "C-mixed labels string malformed" 'item ticket.labels malformed'
check "C-mixed type 5 malformed" 'item ticket.type malformed'

# --- C14: GET only, over every curl call this suite made ------------------------
check "C14 the suite made curl calls" '[ -s "$ALLCURL" ]'
check "C14 no -X/-d/--data" '! grep -qE "(^| )(-X|-d|--data[a-z-]*)( |$)" "$ALLCURL"'
check "C14 no write path" '! grep -qE "/(comments|move|turn|triage)( |$|/|\?)" "$ALLCURL"'
check "C14 every call reads its code" '[ "$(grep -c -- "-w %{http_code}" "$ALLCURL")" -eq "$(wc -l < "$ALLCURL")" ]'

# --- the live harness was never touched ------------------------------------------
check "live /root/harness/state/board-conformance unchanged" '[ "$(ls -la /root/harness/state/board-conformance 2>/dev/null)" = "$LIVE_BEFORE" ]'

echo "board-conformance-board: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
