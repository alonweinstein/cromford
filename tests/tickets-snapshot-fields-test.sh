#!/bin/bash
# tests/tickets-snapshot-fields-test.sh — the ticket-mapping jq program from
# bin/tickets-snapshot-push.sh, extracted verbatim and run on real board shapes.
#
# Two reasons this exists rather than trusting a read-through:
#   1. The program is a multi-line single-quoted shell string. While writing it I
#      put an apostrophe in a comment inside it ("the operator's"), which terminated the
#      quote and turned the whole pipeline into a bash syntax error. Cheap to
#      catch, invisible to review.
#   2. Four different board APIs feed it and they do not agree on casing or
#      wrapper shape. A field that silently maps to "" everywhere looks exactly
#      like a fleet where nothing is waiting on a client.
# Run from anywhere: tests/tickets-snapshot-fields-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRC="$DIR/bin/tickets-snapshot-push.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

JQP=$(sed -n '/| jq -c --arg bid/,/> "\/tmp\/snap-/p' "$SRC" | sed '1d;$d' | sed "s/^        '//" | sed "s/' *\\\\$//")
[ -n "$JQP" ] && ok || bad "could not extract the jq program from $SRC"
map() { jq -c --arg bid b1 "$JQP" 2>/dev/null; }

# ---------- 1. camelCase board, bare array (project-1 / project-2 shape) ------
OUT=$(echo '[{"key":"TK-88","status":"open","title":"Fix login","updatedAt":"2026-08-23",
  "triageVerdict":"needs_clarification","waitingOn":"client","id":123,
  "url":"https://os.x.com/board/TK-88"}]' | map)
jq -e . >/dev/null 2>&1 <<<"$OUT" && ok || bad "camelCase board did not map (jq program broken?)"
T=$(jq -c '.tickets[0]' <<<"$OUT")
[ "$(jq -r .triage_verdict <<<"$T")" = needs_clarification ] && ok || bad "triageVerdict -> triage_verdict (got $T)"
[ "$(jq -r .waiting_on <<<"$T")" = client ] && ok || bad "waitingOn -> waiting_on"
[ "$(jq -r .url <<<"$T")" = "https://os.x.com/board/TK-88" ] && ok || bad "url passed through"
# ids arrive as numbers on some boards and cuid strings on others; the console
# renders it, so it is normalised to a string rather than shipped as either.
[ "$(jq -r '.id|type' <<<"$T")" = string ] && [ "$(jq -r .id <<<"$T")" = 123 ] \
  && ok || bad "numeric id must be stringified (got $(jq -c '.id' <<<"$T"))"

# ---------- 2. snake_case board wrapped in .tickets, no url ----------
OUT=$(echo '{"tickets":[{"number":7,"status":"ready","title":"Add sort","updated_at":"2026-08-22",
  "triage_verdict":"ready","waiting_on":"team","id":"clx01"}]}' | map)
T=$(jq -c '.tickets[0]' <<<"$OUT")
[ "$(jq -r .key <<<"$T")" = 7 ] && ok || bad "GitHub-issue shape: number -> key"
[ "$(jq -r .triage_verdict <<<"$T")" = ready ] && ok || bad "snake_case triage_verdict accepted"
[ "$(jq -r .waiting_on <<<"$T")" = team ] && ok || bad "snake_case waiting_on accepted"
[ "$(jq -r .url <<<"$T")" = "" ] && ok || bad "a board with no url must yield empty, not null"
[ "$(jq -r .updatedAt <<<"$T")" = "2026-08-22" ] && ok || bad "updated_at still accepted"

# ---------- 3. a board that returns none of the new fields ----------
# Must not error and must not drop the keys — the console reads them positionally.
OUT=$(echo '[{"key":"TK-3","status":"done","title":"Old"}]' | map)
T=$(jq -c '.tickets[0]' <<<"$OUT")
jq -e . >/dev/null 2>&1 <<<"$OUT" && ok || bad "a board missing the new fields must still map"
for F in waiting_on id url; do
  [ "$(jq -r ".$F" <<<"$T")" = "" ] || bad "$F should be an empty string when absent (got $(jq -c ".$F" <<<"$T"))"
done
ok
# The verdict is the exception: an unassessed ticket says so out loud, because
# "" would render as "no flag" and read as "nothing blocking".
[ "$(jq -r .triage_verdict <<<"$T")" = untriaged ] \
  && ok || bad "an unassessed ticket must report untriaged, not empty (got $(jq -c .triage_verdict <<<"$T"))"
# A board that sends an EMPTY STRING rather than omitting the field must land in
# the same state — jq's // only falls through on null, so this needs its own test.
OUT=$(echo '[{"key":"TK-4","status":"open","title":"t","triageVerdict":"","waitingOn":"team"}]' | map)
[ "$(jq -r '.tickets[0].triage_verdict' <<<"$OUT")" = untriaged ] \
  && ok || bad "an explicitly-empty verdict must also become untriaged"
# ...and a real verdict is never overwritten.
OUT=$(echo '[{"key":"TK-5","status":"open","title":"t","triageVerdict":"ready"}]' | map)
[ "$(jq -r '.tickets[0].triage_verdict' <<<"$OUT")" = ready ] \
  && ok || bad "a real verdict must survive untouched"
[ "$(jq -r 'keys_unsorted|join(",")' <<<"$T")" = "key,status,title,updatedAt,triage_verdict,waiting_on,id,url" ] \
  && ok || bad "field set/order changed: $(jq -r 'keys_unsorted|join(",")' <<<"$T")"

# ---------- 4. the standing product-board rule survives the round trip -------
# needs_clarification + client is "the client owes an answer, do NOT build".
# That pair is the entire reason these fields were added.
OUT=$(echo '[{"key":"TK-1","status":"open","title":"t","triageVerdict":"needs_clarification","waitingOn":"client"},
             {"key":"TK-2","status":"open","title":"t","triageVerdict":"ready","waitingOn":"team"}]' | map)
[ "$(jq '[.tickets[]|select(.triage_verdict=="needs_clarification" and .waiting_on=="client")]|length' <<<"$OUT")" = 1 ] \
  && ok || bad "the not-buildable pair must be selectable from the snapshot"

# ---------- 5. the coverage diagnostic reports zero when a board omits them --
# Without this line, a board API that never sends triageVerdict is
# indistinguishable from a fleet where nothing is waiting on a client.
COVJQ=$(sed -n '/^COV=\$(jq -r/,/join(" | ")./p' "$SRC" | sed "s/^COV=\$(jq -r '//" | sed "s/' \"\$OUT\".*$//")
[ -n "$COVJQ" ] && ok || bad "could not extract the coverage diagnostic"
EMPTY='{"projects":{"p":{"board_id":"b","tickets":[{"triage_verdict":"","waiting_on":"","url":""},{"triage_verdict":"","waiting_on":"","url":""}]}}}'
OUT=$(jq -r "$COVJQ" <<<"$EMPTY" 2>/dev/null)
grep -q 'verdict=0' <<<"$OUT" && grep -q 'waiting_on=0' <<<"$OUT" \
  && ok || bad "coverage must report 0 when the board sends nothing (got: $OUT)"

# The counter must not read "untriaged" as a verdict — that would invert the
# signal, reporting full coverage precisely when nothing has been assessed.
UNTR='{"projects":{"p":{"board_id":"b","tickets":[{"triage_verdict":"untriaged","waiting_on":"team","url":""},{"triage_verdict":"ready","waiting_on":"team","url":""}]}}}'
OUT=$(jq -r "$COVJQ" <<<"$UNTR" 2>/dev/null)
grep -q 'verdict=1' <<<"$OUT" && ok || bad "untriaged must not count as a verdict (got: $OUT)"
grep -q 'untriaged=1' <<<"$OUT" && ok || bad "untriaged must be counted on its own (got: $OUT)"
FULL='{"projects":{"p":{"board_id":"b","tickets":[{"triage_verdict":"x","waiting_on":"client","url":"u"}]}}}'
OUT=$(jq -r "$COVJQ" <<<"$FULL" 2>/dev/null)
grep -q 'verdict=1' <<<"$OUT" && grep -q 'url=1' <<<"$OUT" \
  && ok || bad "coverage must count populated fields (got: $OUT)"

# ---------- 6b. the vocabulary each board actually uses ----------
# Counts catch a field going missing. They do NOT catch a board quietly changing
# its words: "Needs Clarification" is a different string from
# needs_clarification, and the card keying off that pair would stop matching
# while still rendering happily. Case is normalised downstream; separator drift
# is not, and the producer is the only place that sees all four boards at once.
VOC='{"projects":{"p":{"board_id":"b","tickets":[
  {"triage_verdict":"needs_clarification","waiting_on":"client","url":""},
  {"triage_verdict":"ready","waiting_on":"team","url":""},
  {"triage_verdict":"untriaged","waiting_on":"team","url":""}]}}}'
OUT=$(jq -r "$COVJQ" <<<"$VOC" 2>/dev/null)
grep -q 'verdicts=\[needs_clarification,ready,untriaged\]' <<<"$OUT" \
  && ok || bad "the distinct verdict vocabulary must be listed (got: $OUT)"
grep -q 'waiting=\[client,team\]' <<<"$OUT" \
  && ok || bad "the distinct waiting_on vocabulary must be listed (got: $OUT)"

# The case this exists for: a board that drifts shows BOTH spellings side by side.
DRIFT='{"projects":{"p":{"board_id":"b","tickets":[
  {"triage_verdict":"Needs Clarification","waiting_on":"client","url":""},
  {"triage_verdict":"needs_clarification","waiting_on":"client","url":""}]}}}'
OUT=$(jq -r "$COVJQ" <<<"$DRIFT" 2>/dev/null)
grep -q 'Needs Clarification,needs_clarification' <<<"$OUT" \
  && ok || bad "separator/case drift must surface as two distinct values (got: $OUT)"

# A free-text waiting_on (person names) must not turn one log line into forty.
BIG=$(python3 -c "
import json
t=[{'triage_verdict':'ready','waiting_on':'person-%d'%i,'url':''} for i in range(40)]
print(json.dumps({'projects':{'p':{'board_id':'b','tickets':t}}}))")
OUT=$(jq -r "$COVJQ" <<<"$BIG" 2>/dev/null)
grep -q ',+32\]' <<<"$OUT" && ok || bad "a high-cardinality field must be capped with a +N suffix (got: $OUT)"
[ "${#OUT}" -lt 400 ] && ok || bad "the coverage line must stay readable (was ${#OUT} chars)"

# An empty value is shown, not rendered as a blank gap between commas.
EMPTYV='{"projects":{"p":{"board_id":"b","tickets":[{"triage_verdict":"untriaged","waiting_on":"","url":""}]}}}'
OUT=$(jq -r "$COVJQ" <<<"$EMPTYV" 2>/dev/null)
grep -q 'waiting=\[(empty)\]' <<<"$OUT" && ok || bad "an empty value must be visible as (empty) (got: $OUT)"

echo "tickets-snapshot-fields-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
