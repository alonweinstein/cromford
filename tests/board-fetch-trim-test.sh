#!/bin/bash
# tests/board-fetch-trim-test.sh — thread trimming at FETCH time, without
# losing what triage has to see to judge.
#
# THE MEASUREMENT. Hub triage: project-1 267 calls at ~482K mean input,
# alert-triage 204 at ~414K, against composed prompts of ~17KB. medic, which
# fetches almost nothing, runs at 30K. So ~478K/call is the agent's own reads —
# mostly changed tickets returned whole, comment history and all, on a board
# with 247 tickets. Those bytes arrive as tool results and then ride every
# remaining call of the turn, which is why a prompt cap cannot touch them and
# trimming has to happen before the model sees the payload.
#
# THE CORRECTNESS CONSTRAINT, which is the harder half. The standing rule is
# "read the whole thread before deciding" — from an early engagement, where a
# ticket looked obvious, triage had asked a question the client never answered,
# and a build went ahead on an unconfirmed mechanism. Blind truncation would
# recreate that exact bug to save money, which is not a trade anyone agreed to.
#
# So: keep the FIRST comment (the original ask), keep the LAST N (where "client
# answered, turn flipped back" lives), keep every decision field, and DECLARE
# the omission so a thread that was cut says so. A visible gap the agent can
# re-fetch is a different thing from a silent one.
# Run from anywhere: tests/board-fetch-trim-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# SHARE MIRROR: every assertion below reads a per-project prompt
# (prompts/<project>.md). Those carry a customer's product vocabulary and
# staff, so they are not published; prompts/TEMPLATE.md is what ships.
# Write your own per-project prompts and this suite runs in full.
_P1=$("$DIR"/bin/fleet-conf.sh --projects 2>/dev/null | head -1)
if [ -z "$_P1" ] || [ ! -f "$DIR/prompts/$_P1.md" ]; then
  echo "SKIP board-fetch-trim: no per-project prompt for $_P1 in this copy"
  exit 0
fi
BF="$DIR/bin/board-fetch.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# The jq program, lifted from the script so this exercises shipped code rather
# than a copy that can drift away from it.
python3 - "$BF" "$T/trim.jq" <<'EXTRACT'
import sys
src = open(sys.argv[1]).read()
# Anchored on the jq program's FIRST line. Inserting the type guard above the
# old anchor started the extraction mid-program and failed all 21 assertions —
# the third marker today broken by an insertion ABOVE it. A marker that names
# "the line before the thing I want" breaks whenever anything is added; one
# that names the thing's own opening does not.
# Anchored on the jq PROGRAM's own first line, which is inside the program and
# moves only if the program itself is rewritten. Anchoring on the invocation
# broke a fourth time today when the call gained --arg since and an OUT_JSON
# capture. Every break this session had one cause: a marker naming something
# ADJACENT to the target instead of the target.
start = src.index("  # GUARD THE WHOLE PROGRAM")
end = src.index("\n' 2>/dev/null", start)
open(sys.argv[2], "w").write(src[start:end])
EXTRACT
[ -s "$T/trim.jq" ] && ok || bad "could not extract the trim program from board-fetch.sh"

trim() { jq --argjson n "${2:-10}" --arg since "${3:-}" -f "$T/trim.jq"; }

# A long thread: original ask, 19 middle comments, then the client's answer.
python3 - > "$T/long.json" <<'PY'
import json
c = [{"author": "client", "createdAt": "t0", "body": "original ask", "html": "x"*400}]
c += [{"author": "team", "createdAt": f"t{i}", "body": f"mid {i}", "html": "y"*400} for i in range(1, 20)]
c += [{"author": "client", "createdAt": "t99", "body": "ANSWER: use method B"}]
print(json.dumps({"id": "TK-1", "status": "review", "waitingOn": "team",
                  "triageVerdict": "needs_clarification", "comments": c}))
PY

OUT=$(trim < "$T/long.json")

# --- 1. it actually shrinks the payload --------------------------------------
BEFORE=$(wc -c < "$T/long.json"); AFTER=$(printf '%s' "$OUT" | wc -c)
[ "$AFTER" -lt "$((BEFORE / 3))" ] \
  && ok || bad "trimming must materially shrink the payload ($BEFORE -> $AFTER bytes)"

# --- 2. THE CLIENT'S ANSWER SURVIVES -----------------------------------------
# This is the assertion that protects the an early engagement lesson. If the
# newest comment can be lost, the whole change is a regression dressed as a
# saving.
grep -q 'ANSWER: use method B' <<<"$OUT" \
  && ok || bad "the client's latest answer was trimmed away — that is the bug this must not recreate"
grep -q 'original ask' <<<"$OUT" \
  && ok || bad "the original ask was trimmed away — the decision table needs it to judge a mechanism"

# --- 3. every decision field survives ----------------------------------------
# The decision table reads these directly; losing one silently changes verdicts.
for f in status waitingOn triageVerdict; do
  [ "$(jq -r ".$f // empty" <<<"$OUT")" != "" ] \
    || bad "decision field .$f did not survive the trim"
done
ok

# --- 4. THE OMISSION IS DECLARED ---------------------------------------------
# A visible gap the agent can re-fetch is a different thing from a silent one.
# Without this the trim is exactly the blind truncation it must not be.
[ "$(jq -r '[.comments[] | select(._omitted)] | length' <<<"$OUT")" = "1" ] \
  && ok || bad "a trimmed thread must SAY it was trimmed"
[ "$(jq -r '.comments[] | select(._omitted) | ._omitted' <<<"$OUT")" = "10" ] \
  && ok || bad "the omission count must be accurate (20 comments, keep first + last 10 = 10 omitted)"
jq -r '.comments[] | select(._note) | ._note' <<<"$OUT" | grep -q 'full' \
  && ok || bad "the note must say how to get the omitted comments"

# --- 5. a SHORT thread is untouched ------------------------------------------
# Most tickets are short. Trimming them would add a confusing note for nothing.
python3 -c "
import json
print(json.dumps({'id':'TK-2','comments':[{'author':'a','createdAt':'t','body':f'c{i}'} for i in range(4)]}))" > "$T/short.json"
SHORT=$(trim < "$T/short.json")
[ "$(jq '.comments | length' <<<"$SHORT")" = "4" ] \
  && ok || bad "a 4-comment thread must pass through whole"
[ "$(jq -r '[.comments[] | select(._omitted)] | length' <<<"$SHORT")" = "0" ] \
  && ok || bad "a short thread must not claim anything was omitted"

# --- 6. FAIL OPEN on an unrecognised shape -----------------------------------
# Board APIs differ per project. An unknown shape must cost tokens, never lose
# a client's answer: the expensive failure is recoverable and the silent one is
# not. This is the assertion that makes the change safe to roll out before
# every project's response shape has been verified.
python3 -c "
import json
print(json.dumps({'id':'TK-3','thread':{'entries':[{'body':f'c{i}'} for i in range(50)]}}))" > "$T/weird.json"
WEIRD=$(trim < "$T/weird.json")
[ "$(jq '.thread.entries | length' <<<"$WEIRD")" = "50" ] \
  && ok || bad "an unrecognised shape must pass through UNCHANGED, not be silently dropped"

# ...and the nested shapes that ARE recognised must be trimmed.
python3 -c "
import json
c=[{'author':'x','createdAt':'t','body':f'c{i}'} for i in range(30)]
print(json.dumps({'ticket':{'id':'TK-4','comments':c}}))" > "$T/nested.json"
NEST=$(trim < "$T/nested.json")
[ "$(jq '.ticket.comments | length' <<<"$NEST")" = "12" ] \
  && ok || bad "a .ticket.comments shape must trim to first + note + last 10 (got $(jq '.ticket.comments|length' <<<"$NEST"))"

# --- 7. heavy per-comment fields are dropped ---------------------------------
# The kept comments carry author/date/body. Rendered HTML and attachments are
# bulk the decision never reads.
[ "$(jq -r '.comments[-1] | has("html")' <<<"$OUT")" = "false" ] \
  && ok || bad "heavy per-comment fields must be dropped from kept comments"
[ "$(jq -r '.comments[-1].body' <<<"$OUT")" = "ANSWER: use method B" ] \
  && ok || bad "the body must survive field-trimming intact"

# --- 8. the grok tool loop is BOUNDED, and the bound is honest --------------
# Same mechanism from the other end: trimming shrinks each read, --max-turns
# caps how many reads a run can accumulate. Together they are the fix; either
# alone is partial.
AC="$DIR/bin/agent-call.sh"
grep -q -- '--max-turns "\${GROK_MAX_TURNS:-25}"' "$AC" \
  && ok || bad "the grok lane has no tool-loop bound"
# Generous by design: medic runs healthy at 30K/call, so a bound that bites
# normal work would be a correctness regression rather than a saving.
[ "$(grep -o 'GROK_MAX_TURNS:-[0-9]*' "$AC" | head -1 | sed 's/.*:-//')" -ge 10 ] \
  && ok || bad "the turn bound is tight enough to cut healthy runs"
# The semantics are UNVERIFIED and the code must say so, or the next reader
# treats an unproven bound as an established one.
grep -q 'SEMANTICS UNVERIFIED' "$AC" \
  && ok || bad "the unverified tool-loop semantics are not flagged in the code"

# --- 9. FINDING 1: a bare top-level ARRAY must not vanish -------------------
# `.comments?` against an array does NOT error into the fallback — `?`
# SUPPRESSES, so jq emits an empty stream and exits 0. The caller gets NOTHING
# and nothing failed, so fail-open never fires. A bare array is a real board
# response shape, making this the one input that could silently return an empty
# ticket instead of a whole one.
python3 -c "
import json
print(json.dumps([{'id':'TK-1','comments':[{'body':'x'} for _ in range(30)]}]))" > "$T/arr.json"
AOUT=$(trim < "$T/arr.json")
[ -n "$AOUT" ] \
  && ok || bad "a bare top-level array produced EMPTY output — ?-suppression, not fail-open"
[ "$(jq -r 'type' <<<"$AOUT" 2>/dev/null)" = "array" ] \
  && ok || bad "a bare top-level array must come back as an array, unchanged"

# --- 10. FINDING 2: narrowing is DECLARED, and the real fields survive -------
# The verified project-1/project-2 shape makes this concrete: `author` is an
# OBJECT {userId,name}, not a string, and comments carry `mentions[]` and
# `isInternal`. isInternal bears directly on the early-engagement question — did
# the CLIENT answer, or was that our own note — so an allowlist rebuild to
# {author,createdAt,body} would drop the field the decision turns on, and would
# flatten author from an object to whatever the rebuild picked.
python3 -c "
import json
c=[{'id':str(i),'author':{'userId':'u1','name':'Jane'},'body':'c%d'%i,
    'mentions':[],'isInternal':(i%2==0),'html':'<p>'+'x'*400+'</p>'} for i in range(30)]
print(json.dumps({'id':'TK-2','status':'review','comments':c}))" > "$T/real.json"
ROUT=$(trim < "$T/real.json")
[ "$(jq -r '.comments[-1].author | type' <<<"$ROUT")" = "object" ] \
  && ok || bad "author was flattened — it is an OBJECT {userId,name} in the verified shape"
[ "$(jq -r '.comments[-1] | has("isInternal")' <<<"$ROUT")" = "true" ] \
  && ok || bad "isInternal was dropped — it answers 'did the CLIENT answer or did we?'"
[ "$(jq -r '.comments[-1] | has("mentions")' <<<"$ROUT")" = "true" ] \
  && ok || bad "mentions[] was dropped by an allowlist rebuild"
[ "$(jq -r '.comments[-1] | has("html")' <<<"$ROUT")" = "false" ] \
  && ok || bad "the heavy html field must still be dropped — that is the saving"
[ "$(jq -r '[.comments[]|select(._narrowed)]|length' <<<"$ROUT")" = "1" ] \
  && ok || bad "field-level narrowing must be DECLARED, exactly like the omission is"
# ...and it must still actually shrink, or the denylist has become a no-op.
[ "$(printf '%s' "$ROUT" | wc -c)" -lt "$(($(wc -c < "$T/real.json") / 3))" ] \
  && ok || bad "the trim no longer shrinks the payload materially"

# --- 11. WHICH SOPs ARE WIRED, and which deliberately are not ---------------
# Only boards whose response shape has been CAPTURED AND VERIFIED get wired.
# board-fetch fails open, so wiring an unverified board buys nothing and risks
# the opposite: if its shape differs, the fetch passes through whole and the
# SOP now claims a trim that is not happening. project-1 and project-2
# are captured (comments[] with author objects, mentions, isInternal); project-3 and
# project-4 are not yet.
for P in project-1 project-2; do
  grep -q 'board-fetch.sh' "$DIR/prompts/$P.md" \
    || bad "$P.md is not wired to the trim helper — its shape is verified, so it should be"
done
ok
for P in project-3 project-4; do
  [ -f "$DIR/prompts/$P.md" ] || continue
  grep -q 'board-fetch.sh' "$DIR/prompts/$P.md" \
    && bad "$P.md is wired but its shape has NOT been captured — fail-open makes that a silent no-op that the SOP describes as a trim" || true
done
ok

# The token must be the PROJECT's, not the harness secret. board-fetch reads
# INTERNAL_TOKEN, and the boards reject HARNESS_SECRET — a wiring that omitted
# the prefix would 401, and before the HTTP check that error body would have
# reached the agent looking like an empty ticket.
grep -q 'INTERNAL_TOKEN="\$PROJECT_1_INTERNAL_API_TOKEN"' "$DIR/prompts/project-1.md" \
  && ok || bad "project-1 SOP does not pass the project token to board-fetch"
grep -q 'INTERNAL_TOKEN="\$PROJECT_2_INTERNAL_API_TOKEN"' "$DIR/prompts/project-2.md" \
  && ok || bad "project-2 SOP does not pass the project token to board-fetch"

# Both SOPs must tell the agent what the omission marker MEANS and how to undo
# it. A trim the agent cannot reverse is a trim it must not trust.
for P in project-1 project-2; do
  grep -q '_omitted' "$DIR/prompts/$P.md" \
    || bad "$P.md never explains the _omitted marker — the agent cannot act on a gap it was not told about"
  grep -q -- '--full' "$DIR/prompts/$P.md" \
    || bad "$P.md never tells the agent how to re-fetch whole"
  grep -q 'BOARD-FETCH FAILED' "$DIR/prompts/$P.md" \
    || bad "$P.md does not warn that an HTTP failure is not a ticket"
done
ok

# An HTTP error must not read as a ticket. Fail-open is for unrecognised
# SHAPES; a 401 body is an error page, and judging a client's request from one
# is worse than not fetching at all.
grep -q 'BOARD-FETCH FAILED' "$BF" \
  && ok || bad "board-fetch does not distinguish an HTTP failure from a shape it cannot parse"

# --- 12. THE CHANGED SET IS STRUCTURALLY WHOLE ------------------------------
# last-N satisfied "a client answer always arrives whole" only because a new
# answer is usually newest. If more than N land between ticks the OLDEST of the
# NEW ones is trimmed, and the guarantee then rests on the agent noticing
# _omitted and choosing --full. Not hypothetical: TK-88 posted 213 comments in
# 5.5 hours, about 6 per tick. With --since-file the omission window respects
# the fingerprint instead.
python3 -c "
import json
old=[{'id':str(i),'author':{'name':'x'},'body':'old %d'%i,'createdAt':'2026-08-25T07:%02d:00Z'%i} for i in range(24)]
new=[{'id':'n%d'%i,'author':{'name':'c'},'body':'NEW %d'%i,'createdAt':'2026-08-25T09:%02d:00Z'%i} for i in range(6)]
print(json.dumps({'id':'TK-88','comments':old+new}))" > "$T/burst.json"
W=$(jq --argjson n 3 --arg since "2026-08-25T08:00:00Z" -f "$T/trim.jq" < "$T/burst.json")
[ "$(jq '[.comments[]|select(has("body"))|select(.body|startswith("NEW"))]|length' <<<"$W")" = "6" ] \
  && ok || bad "a burst of 6 new comments must ALL survive with --since — the changed set is not agent-discretion"
[ "$(jq -r '[.comments[]|select(._window)]|length' <<<"$W")" = "1" ] \
  && ok || bad "the fingerprint window must be declared in the marker"
# Without a since, the old behaviour: only last-N of the new ones. Asserted so
# the difference is visible rather than assumed.
N=$(jq --argjson n 3 --arg since "" -f "$T/trim.jq" < "$T/burst.json")
[ "$(jq '[.comments[]|select(has("body"))|select(.body|startswith("NEW"))]|length' <<<"$N")" = "3" ] \
  && ok || bad "without --since the last-N fallback should keep exactly N — if this changed, the comparison is stale"

# --- 13. BOTH SOPs carry the never-trimmed line and the fingerprint flag -----
# project-1 had the never-trimmed sentence and project-2 did not, so either
# copy could lose it silently. Asserted in both now.
for P in project-1 project-2; do
  grep -qi 'never trimmed' "$DIR/prompts/$P.md" \
    || bad "$P.md does not state that the TICK SCOPE / changed set is never trimmed"
  grep -q -- '--since-file' "$DIR/prompts/$P.md" \
    || bad "$P.md does not pass --since-file, so its changed set is only agent-discretion whole"
done
ok

# --- 14. the helper logs every invocation -----------------------------------
# A wiring whose only evidence is an aggregate that three other commits also
# move has not been verified. This makes "did the lane obey" a grep.
# CALLED, not merely defined. Grepping the name matched the definition, so
# deleting the call left this green — the exact gap the capstone's wiring rule
# exists for, hit again in the test written the same day as the rule.
[ "$(grep -cE '(^|[^a-z_])_bf_log[ "]' "$BF")" -ge 1 ] \
  && ok || bad "board-fetch defines _bf_log but never calls it — the log would be dead code"
grep -qE 'in=.*out=.*omitted=' "$BF" \
  && ok || bad "the log line must carry bytes in/out and the omission count, or it cannot show the trim worked"

echo "board-fetch-trim-test: $PASS pass, $FAIL fail"
echo "NOTE: response shapes are verified for .comments / .ticket.comments /"
echo "      .data.comments only. Anything else FAILS OPEN (full payload), so a"
echo "      project whose shape has not been confirmed loses tokens, not data."
[ "$FAIL" -eq 0 ]
