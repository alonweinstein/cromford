#!/bin/bash
# tests/shape-capture-redaction-test.sh — the shape capture must leak NOTHING.
#
# This script's output is pasted into agent transcripts to design a jq filter.
# Board tickets carry client content: what they asked for, what they complained
# about, what they were quoted. None of it is needed to write a filter, all of
# it would end up in logs and context windows, and the people whose words they
# are did not agree to that.
#
# So the redaction is the feature, not a nicety, and it is the one property here
# that cannot be allowed to regress quietly — a leak is invisible to whoever
# runs the script and permanent wherever the output lands. Hence hostile
# fixtures: real-shaped client content, asserted absent from the output.
# Run from anywhere: tests/shape-capture-redaction-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRC="$DIR/bin/capture-ticket-shape.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# NO EXTRACTION. The script now exposes the redactor as a real entry point
# (--shape-stdin), so this drives THAT instead of lifting a copy out of the
# source. Strictly better: it exercises the shipped interface, and it removes
# the extraction-marker fragility that broke this suite three times today —
# every break caused by an insertion ABOVE a marker that named its neighbour
# rather than itself. An entry point cannot drift from itself.
shape_stdin() { bash "$SRC" --shape-stdin; }
ok   # the entry point exists and is exercised below

cat > "$T/payload.json" <<'EOF'
{"id":"TK-42",
 "title":"CONFIDENTIAL client ask about pricing",
 "description":"<p>We were quoted $412,500 by the other vendor</p>",
 "status":"review",
 "comments":[{"author":"jane@client.com","body":"Please drop the export banner, our auditor objected","createdAt":"2026-08-01"},
             {"author":"team","body":"acknowledged","createdAt":"2026-08-02"}],
 "nested":{"secret":"do not leak me","n":5,"ok":true,"none":null}}
EOF
OUT=$(shape_stdin < "$T/payload.json")

# The payload is INVENTED, and deliberately so. An earlier version of it read
# like a ticket someone had actually filed — the same feature, the same
# objector, the same contract value as a real engagement — which made a test
# fixture into a small leak of the thing it exists to prove we do not leak.
# Every string below is chosen to be distinctive enough to grep for and to
# resemble nothing in particular.

# --- 1. NOTHING from the payload survives ------------------------------------
for S in "CONFIDENTIAL" "412,500" "jane@client.com" "export banner" "do not leak me" "auditor" "acknowledged" "review" "other vendor"; do
  grep -qF "$S" <<<"$OUT" && bad "client content leaked into the shape output: $S"
done
ok

# --- 2. ...but the STRUCTURE survives, or the capture is useless -------------
# The filter has to be written against keys, nesting and array shape. Redaction
# that also destroyed those would be safe and pointless.
for K in id title description status comments author body createdAt nested; do
  grep -qF "\"$K\"" <<<"$OUT" || bad "key '$K' did not survive redaction — the shape is what this is FOR"
done
ok
grep -q '<string:' <<<"$OUT" && ok || bad "string lengths must survive — payload size is the thing being diagnosed"
grep -q '<number>' <<<"$OUT" && ok || bad "numbers must be typed, not dropped"
grep -q '<bool>'   <<<"$OUT" && ok || bad "booleans must be typed"
grep -q '<null>'   <<<"$OUT" && ok || bad "nulls must be typed — an absent field and a null one differ to a filter"

# --- 3. array LENGTH survives, element content does not ----------------------
# Whether a thread has 2 or 200 comments is the whole question the trimmer
# answers, so the count must survive while the comments themselves must not.
grep -q '2 items total' <<<"$OUT" \
  && ok || bad "array length must survive — thread length is exactly what the trim decision turns on"

# --- 3b. KEY NAMES ARE CONTENT TOO -------------------------------------------
# Label-keyed objects (customFields, per-label maps) are an ordinary board
# shape, and their KEYS are client data. The first version typed every value
# and printed every key verbatim, so "No values, ever" was true and
# insufficient: a key is not a value and can carry the same sentence.
cat > "$T/keys.json" <<'EOF'
{"id":"TK-9","createdAt":"2026-08-24","triageVerdict":"needs_clarification",
 "commentCount":3,"isInternal":true,
 "customFields":{"acme-corp-confidential":"yes","auditor objection: retention window":"open"}}
EOF
KOUT=$(shape_stdin < "$T/keys.json")
for S in "acme-corp-confidential" "auditor objection" "retention window"; do
  grep -qF "$S" <<<"$KOUT" && bad "a client-derived KEY leaked into the shape output: $S"
done
ok

# ...while every SCHEMA key survives, or the capture stops being useful. The
# filter is written against these names.
for K in id createdAt triageVerdict commentCount isInternal customFields; do
  grep -qF "\"$K\"" <<<"$KOUT" || bad "schema key '$K' was over-redacted — the filter needs it"
done
ok

# Redacted keys keep their LENGTH and stay DISTINCT. Two prose keys of the same
# length collapsing into one entry would silently change the apparent shape.
[ "$(jq -r '.customFields | keys | length' <<<"$KOUT")" = "2" ] \
  && ok || bad "two redacted keys collapsed into one — the shape is now wrong"
grep -qE '<key[0-9]+:[0-9]+>' <<<"$KOUT" \
  && ok || bad "redacted keys must keep their length, which is shape information"

# --- 4. a non-JSON payload prints NO bytes of it -----------------------------
# The tempting debug aid is "print the first 200 bytes so we can see what came
# back". Those bytes are client content on the one path where we know least
# about the response.
NONJSON=$(printf 'this is an HTML error page containing SECRETVALUE and client names' | shape_stdin 2>&1 || true)
grep -q 'SECRETVALUE' <<<"$NONJSON" \
  && bad "a non-JSON payload leaked its bytes — that is the path where we know LEAST about the content" || ok

# --- 5. BOARD-ID DISCOVERY across every response shape ----------------------
# project-4's /api/accounting/requests-board/boards returns a BARE TOP-LEVEL ARRAY.
# The old expression reached for `.boards` first, which against an array is a
# jq ERROR — and the caller's 2>/dev/null turned that error into silence, so
# the capture failed with no id and no reason. Same lesson as #82's finding 1
# (decide on type before reaching for a key), one step earlier in the pipeline.
DISC=$(python3 - "$SRC" <<'@PY@'
import sys
src = open(sys.argv[1]).read()
i = src.index("BOARD=$(printf '%s' \"$BOARDS_RAW\" | jq -r '")
j = src.index("' 2>/dev/null)", i)
print(src[src.index("\n", i) + 1:j])
@PY@
)
[ -n "$DISC" ] && ok || bad "could not extract the board-id discovery expression"
printf '%s' "$DISC" > "$T/disc.jq"

disc() { jq -rf "$T/disc.jq" 2>/dev/null; }
[ "$(printf '[{"id":"project-4-b1","keyPrefix":"CX"}]' | disc)" = "project-4-b1" ] \
  && ok || bad "a BARE TOP-LEVEL ARRAY board list must resolve — this is the project-4 shape that failed"
[ "$(printf '{"boards":[{"id":"mom-b1"}]}' | disc)" = "mom-b1" ] \
  && ok || bad "the {boards:[...]} shape (project-1/project-2) must still resolve"
[ "$(printf '{"data":{"boards":[{"boardId":"om-b1"}]}}' | disc)" = "om-b1" ] \
  && ok || bad "a nested {data:{boards}} shape must resolve — project-3 is still unknown"
[ "$(printf '{"items":[{"_id":"x1"}]}' | disc)" = "x1" ] \
  && ok || bad "an {items:[{_id}]} shape must resolve"
# Claimed verified in the comment but never driven — a claim with no assertion
# behind it is the thing this suite exists to prevent.
[ "$(printf '{"results":[{"slug":"s1"}]}' | disc)" = "s1" ] \
  && ok || bad "a {results:[{slug}]} shape must resolve — it is claimed verified in the comment"
# An unrecognised shape must yield NOTHING, so the caller falls through to the
# redacted shape dump — the branch that diagnosed project-4 in the first place.
[ -z "$(printf '{"nothing":true}' | disc)" ] \
  && ok || bad "an unrecognised shape must yield empty so the diagnostic dump runs"
[ -z "$(printf '[]' | disc)" ] \
  && ok || bad "an empty board list must yield empty, not crash"
# --- 6. THE CAP, AND ITS MARKER ---------------------------------------------
# The 71dbdec dedupe silently halved this 8000 -> 4000 by routing the success
# path through the failure path's body, and NOTHING went red — the suite had no
# fixture large enough to reach either cap. A regression that no test can see
# is one nobody will notice until a large board is captured and the shape is
# quietly short.
python3 -c "
import json
print(json.dumps({'field_%03d'%i: 'x'*60 for i in range(500)}))" > "$T/big.json"
BIG=$(shape_stdin < "$T/big.json")
grep -q 'truncated at 8000 chars' <<<"$BIG" \
  && ok || bad "a payload past the cap must DECLARE the truncation — a short shape must not read as a complete one"
# The 8000 cap must actually be in force: at 4000 the shape stops around
# field_137, at 8000 it reaches past field_250.
grep -q 'field_250' <<<"$BIG" \
  && ok || bad "the cap has regressed below 8000 — the shape is being cut in half again"
# A small payload must carry no marker at all.
grep -q 'truncated' <<<"$(printf '{"id":"x"}' | shape_stdin)" \
  && bad "a small payload must not claim it was truncated" || ok

echo "shape-capture-redaction-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
