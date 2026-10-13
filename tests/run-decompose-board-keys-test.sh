#!/bin/bash
# tests/run-decompose-board-keys-test.sh — a decomposed child's queue key is the
# BOARD's key, never the `<PARENT>.<n>` title label (BH-866).
#
# THE DEFECT THIS PINS. The board lane asks a model to title each child
# `$KEY.<n>: <slice>` AND to "write the created child keys" to children.txt.
# Nothing forced those two to be different things, so the model wrote the
# LABELS. Everything downstream — the triage prompts, the queue, job_open,
# the worker's double-build guard — then treats `TK-1766.5` as a build identity,
# while the board's own key for that same ticket is `TK-1789`. One board ticket,
# two identities, two builds, two PRs.
#
# The fix keeps the model doing the filing (the board assigns the key) and makes
# the SCRIPT enforce the key on the way out: every `<KEY>.<n>` line in
# children.txt is re-mapped to the key of the board ticket whose title carries
# that label, and a label that matches no board ticket FAILS the split rather
# than being synthesized. Nothing pretends a split landed when it did not.
#
# Driven, not grepped: the real script runs against a stub agent-call that
# writes what the model actually wrote, and a stub board API.
# Run from anywhere: tests/run-decompose-board-keys-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

DEC="$DIR/bin/run-decompose.sh"
H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" widget-os || exit 1  # BH-1510.2: lanes read models from model_routes
mkdir -p "$H/bin/lib" "$H/logs" "$H/env" "$H/prompts" "$T/fakebin"
cp "$DIR/bin/fleet-conf.sh" "$H/bin/"
printf 'widget-os Example/widget-os https://widget.example /api/board 3 box-a\n' > "$H/fleet.conf"
: > "$H/env/global.env"
printf 'WIDGET_INTERNAL_API_TOKEN=tok-abc\nWIDGET_API_BASE=https://widget.example\n' > "$H/env/widget-os.env"
# The model-filed path this suite pins lives behind the switch since BH-3965.
mkdir -p "$H/flags" && : > "$H/flags/decompose-board-filer-off"

# The model's half of the split: it files the children and writes what it thinks
# their keys are. THIS IS THE REAL OUTPUT from the TK-1766 split — the labels.
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
echo "call" >> "$AGENT_CALLS"
B=$(dirname "$5")
cat "$CHILDREN_FIXTURE" > "$B/children.txt"
printf 'DECOMPOSED: %s\n' "$(paste -sd, "$B/children.txt")" > "$5"
exit 0
SH
chmod +x "$H/bin/agent-call.sh"

# The board. Three real children were filed, and the board gave them ITS keys.
# Two decoys sit alongside them, both of which a loose prefix match would eat:
#   TK-1999  a ticket from another parent whose label merely SHARES a prefix
#   TK-1998  a title that contains the label mid-string
BOARD_FULL='{"tickets":[
  {"key":"TK-1784","id":"9001","title":"TK-1766.0: contract — shared types","createdAt":"2026-09-18T10:00:00Z"},
  {"key":"TK-1785","id":"9002","title":"TK-1766.1: ingest lane","createdAt":"2026-09-18T10:01:00Z"},
  {"key":"TK-1786","id":"9003","title":"TK-1766.2: the report screen","createdAt":"2026-09-18T10:02:00Z"},
  {"key":"TK-1999","id":"9004","title":"TK-17660.1: a different parent entirely","createdAt":"2026-09-18T10:03:00Z"},
  {"key":"TK-1998","id":"9005","title":"follow-up to TK-1766.2: do not match me","createdAt":"2026-09-18T10:04:00Z"}]}'
BOARD_SHORT='{"tickets":[
  {"key":"TK-1784","id":"9001","title":"TK-1766.0: contract — shared types","createdAt":"2026-09-18T10:00:00Z"},
  {"key":"TK-1785","id":"9002","title":"TK-1766.1: ingest lane","createdAt":"2026-09-18T10:01:00Z"}]}'
printf '%s\n' "$BOARD_FULL" > "$T/board.json"

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; BODY=""
while [ \$# -gt 0 ]; do case "\$1" in --data-binary|--data|-d) BODY="\$2"; shift 2 ;; *) shift ;; esac; done
printf '%s %s\n' "\$URL" "\$BODY" >> "$T/curl-calls.txt"
case "\$URL" in
  *"/api/board/tickets/1766/move") printf '{"status":"in_progress"}\n' ;;
  *"/api/board/tickets/1766")      printf '{"ticket":{"id":"1766","key":"TK-1766","boardId":"bd-1"}}\n' ;;
  *"/api/board/boards/bd-1/tickets") cat "$T/board.json" ;;
  *) printf '{}\n' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl"

B="$T/b"
run() { # run  -> prints the rc
  scratch_rm "$B"; mkdir -p "$B"
  : > "$T/curl-calls.txt"; : > "$T/agent.calls"
  ( env HARNESS="$H" FLEET_CONF="$H/fleet.conf" AGENT_CALLS="$T/agent.calls" \
        CHILDREN_FIXTURE="$T/children-fixture.txt" PATH="$T/fakebin:$PATH" \
        bash "$DEC" widget-os 1766 TK-1766 "$B" 300 12 ) >"$T/dec.out" 2>"$T/dec.err"
  echo $?
}

# ════════════════════════════════════════════════════════════════════════════
# 1. THE LABELS THE MODEL WROTE BECOME THE BOARD'S KEYS
# ════════════════════════════════════════════════════════════════════════════
printf 'TK-1766.0\nAR-1766.1\nAR-1766.2\n' > "$T/children-fixture.txt"
RC=$(run)
[ "$RC" = 0 ] && ok || bad "a split whose labels all resolve must succeed (rc=$RC): $(cat "$B/pipeline.log" 2>/dev/null)"
GOT=$(tr '\n' ' ' < "$B/children.txt" 2>/dev/null | sed 's/ *$//')
[ "$GOT" = "TK-1784 TK-1785 TK-1786" ] \
  && ok || bad "children.txt must carry the BOARD's keys, in the order the model landed them, got: '$GOT'"
grep -qE '^TK-1766\.[0-9]+$' "$B/children.txt" \
  && bad "not one '<PARENT>.<n>' label may survive into children.txt — that label is what becomes a second build identity: $(cat "$B/children.txt")" \
  || ok
# The decoys stay where they are.
grep -qE '^(TK-1999|TK-1998)$' "$B/children.txt" \
  && bad "a label match must be the exact '<label>:' title prefix — TK-17660.1 and a mid-string mention are not this parent's children: $(cat "$B/children.txt")" \
  || ok
for m in 'TK-1766.0 -> TK-1784' 'TK-1766.1 -> TK-1785' 'TK-1766.2 -> TK-1786'; do
  grep -qF "$m" "$B/pipeline.log" \
    && ok || bad "every mapping must be logged ('$m' missing): $(cat "$B/pipeline.log" 2>/dev/null)"
done
grep -q 'parent parked in_progress' "$B/pipeline.log" \
  && ok || bad "a successful split still parks the parent: $(cat "$B/pipeline.log" 2>/dev/null)"
grep -q '/api/board/tickets/1766/move' "$T/curl-calls.txt" \
  && ok || bad "...and that park is a real POST: $(cat "$T/curl-calls.txt")"
[ "$(wc -l < "$T/agent.calls")" = 1 ] \
  && ok || bad "the re-map is a BOARD READ, not a second model call — it must cost nothing: $(cat "$T/agent.calls")"

# ════════════════════════════════════════════════════════════════════════════
# 2. A LABEL THAT MATCHES NO BOARD TICKET FAILS THE SPLIT
# A child the model claims it filed but the board has never heard of is not a
# key to be synthesized — it is a split that did not land (D9/D11/D26).
# ════════════════════════════════════════════════════════════════════════════
printf '%s\n' "$BOARD_SHORT" > "$T/board.json"
printf 'TK-1766.0\nAR-1766.1\nAR-1766.2\n' > "$T/children-fixture.txt"
RC=$(run)
[ "$RC" = 1 ] && ok || bad "an unresolvable child must fail the split, got rc=$RC"
grep -q 'DECOMPOSE_FAILED' "$B/decompose-run.txt" \
  && ok || bad "the failure must be written where the pipeline reads the decompose outcome: $(cat "$B/decompose-run.txt" 2>/dev/null)"
grep 'DECOMPOSE_FAILED' "$B/decompose-run.txt" 2>/dev/null | grep -q 'TK-1766.2' \
  && ok || bad "...and must name the child that could not be resolved: $(cat "$B/decompose-run.txt" 2>/dev/null)"
grep -q 'TK-1766' "$B/children.txt" 2>/dev/null \
  && bad "a failed split must not leave labels in children.txt for the queue to launch: $(cat "$B/children.txt")" || ok
[ -s "$B/children.txt.labels" ] \
  && ok || bad "the labels the model wrote are kept for the operator, beside the failure, not deleted"
# FIXED ASSERTION (2026-09-20, review finding 1). This used to read "a failed
# split must NOT park the parent — the ticket is still whole and still
# claimable", and that was wrong: by the time the re-map runs the model has
# already FILED the children on the board and posted the split comment. Only
# the label→key mapping failed. A parent left in todo/ready is re-claimed by the
# next triage tick, re-enters the size gate and files a SECOND set of children —
# the exact duplicate this ticket exists to stop, with a client watching the
# board. So a POST-FILING failure parks the parent and says, loudly, that the
# children exist under their labels and need a human.
grep -q '/api/board/tickets/1766/move' "$T/curl-calls.txt" \
  && ok || bad "a split that filed children and then failed to map them must STILL park the parent — otherwise the next tick files a second set: $(cat "$T/curl-calls.txt")"
grep -qi 'children' "$B/decompose-run.txt" 2>/dev/null \
  && ok || bad "...and the failure must say the children EXIST on the board under their labels, or an operator reads 'no children were filed' and re-splits by hand: $(cat "$B/decompose-run.txt" 2>/dev/null)"
grep -qi 'parked' "$B/pipeline.log" 2>/dev/null \
  && ok || bad "...and the record must say the parent was parked: $(cat "$B/pipeline.log" 2>/dev/null)"
grep -qE 'TK-17(84|85)' "$B/decompose-run.txt" "$B/children.txt" 2>/dev/null \
  && bad "a partial re-map must not half-land: nothing is written when one child cannot be resolved" || ok

# ── the board read itself failing is the same answer ────────────────────────
printf '{"tickets":[]}\n' > "$T/board.json"
RC=$(run)
[ "$RC" = 1 ] && ok || bad "an empty board read must fail the split, not pass the labels through (rc=$RC)"

# ════════════════════════════════════════════════════════════════════════════
# 3. CHILDREN THAT ARE ALREADY BOARD KEYS ARE LEFT ALONE
# A model that followed the instruction costs no board read at all.
# ════════════════════════════════════════════════════════════════════════════
printf '%s\n' "$BOARD_FULL" > "$T/board.json"
printf 'TK-1784\nAR-1785\n' > "$T/children-fixture.txt"
RC=$(run)
[ "$RC" = 0 ] && ok || bad "a compliant split must pass straight through (rc=$RC)"
GOT=$(tr '\n' ' ' < "$B/children.txt" | sed 's/ *$//')
[ "$GOT" = "TK-1784 TK-1785" ] && ok || bad "board keys must be untouched, got '$GOT'"
grep -q '/api/board/boards/' "$T/curl-calls.txt" \
  && bad "nothing to re-map means no board list read: $(cat "$T/curl-calls.txt")" || ok

# ════════════════════════════════════════════════════════════════════════════
# 3b. A BOARD WHOSE LIST CARRIES `number` AND NO `key` — the project-4 shape
# project-4 is the board this ticket was written from, and its list endpoint
# (project-4 `boards/[boardId]/tickets`, CARD_SELECT) returns `number`; the key is
# formatted from the board's keyPrefix and only ever appears on the single-ticket
# and create responses. A re-map that requires `.key` therefore matches ZERO
# tickets on project-4: every label fails to resolve, DEC_FAIL fires, and every
# board decompose that wrote labels ends DECOMPOSE_FAILED with the parent
# unparked — worse than the bug this block fixes.
# ════════════════════════════════════════════════════════════════════════════
BOARD_NUMBERED='{"tickets":[
  {"number":1784,"id":"9001","title":"TK-1766.0: contract — shared types","createdAt":"2026-09-18T10:00:00Z"},
  {"number":1785,"id":"9002","title":"TK-1766.1: ingest lane","createdAt":"2026-09-18T10:01:00Z"},
  {"number":1786,"id":"9003","title":"TK-1766.2: the report screen","createdAt":"2026-09-18T10:02:00Z"},
  {"number":1999,"id":"9004","title":"TK-17660.1: a different parent entirely","createdAt":"2026-09-18T10:03:00Z"}]}'
printf '%s\n' "$BOARD_NUMBERED" > "$T/board.json"
printf 'TK-1766.0\nAR-1766.1\nAR-1766.2\n' > "$T/children-fixture.txt"
RC=$(run)
[ "$RC" = 0 ] \
  && ok || bad "a board that returns number-without-key must still re-map (rc=$RC): $(cat "$B/decompose-run.txt" 2>/dev/null)"
GOT=$(tr '\n' ' ' < "$B/children.txt" 2>/dev/null | sed 's/ *$//')
[ "$GOT" = "TK-1784 TK-1785 TK-1786" ] \
  && ok || bad "the key is the parent's prefix plus the board number when the list omits .key, got: '$GOT'"
grep -qE '^TK-1999$' "$B/children.txt" 2>/dev/null \
  && bad "the exact-prefix match still holds when the key is derived: $(cat "$B/children.txt")" || ok

# ════════════════════════════════════════════════════════════════════════════
# 4. THE PROMPT SAYS WHICH KEY IT WANTS
# The mechanical re-map above is the proof; this is the instruction that stops
# the model from filing under a label in the first place.
# ════════════════════════════════════════════════════════════════════════════
grep -q 'that prefix is a LABEL' "$DEC" \
  && ok || bad "the board-lane prompt must tell the model the '<KEY>.<n>' prefix is a title label, not the child's key"

echo "run-decompose-board-keys: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
