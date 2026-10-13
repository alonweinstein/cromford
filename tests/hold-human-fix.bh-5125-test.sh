#!/bin/bash
# tests/hold-human-fix.bh-5125-test.sh — the human-fix hold in bin/lib/hold.sh
# (BH-5125, item 1). A comment LINE opening `Taken by: <person>` or
# `[human-fix]` parks the ticket as `hold:human-fix <at> <line>`, a pause to
# every lane that reads hold.sh. Free-text direction from a principal is NOT a
# take-over (the #5022 shape), a bot is never heard for it, and it is lifted the
# way NEEDS-HUMAN: is: a person's HUMAN-STEP-DONE: directly over it, or RESUME.
#   H1–H9 as the plan lists them, then §A hold_ambiguous still answers.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export HARNESS_TEST_SANDBOX=1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

LIB="$DIR/bin/lib/hold.sh"
. "$LIB" || { echo "FAIL: $LIB does not source"; exit 1; }

T1=2026-10-07T03:00:00Z; T2=2026-10-07T03:33:00Z; T3=2026-10-07T04:00:00Z
ISSUE() { # ISSUE [state] [labels csv] [title] [body]
  jq -nc --arg s "${1:-open}" --arg l "${2-ai-build}" --arg t "${3:-BH-1: a thing}" --arg b "${4:-## Scope}" \
    '{state:$s, labels:($l | split(",") | map(select(. != "")) | map({name:.})), title:$t, body:$b}'
}
CMT() { jq -nc --arg b "$1" --arg c "$2" --arg u "${3:-User}" --arg a "${4:-OWNER}" \
  '{body:$b, created_at:$c, user:{type:$u}, author_association:$a}'; }
CMTS() { local IFS=","; printf '[%s]' "$*"; }
OPEN=$(ISSUE)

# row <want-rc> <want-exact> <issue> <comments> <label>
row() {
  local out rc
  out=$(hold_classify "$3" "$4" 2>/dev/null); rc=$?
  out=$(printf '%s' "$out" | tr '\t' '|')
  [ "$rc" = "$1" ] && [ "$out" = "$2" ] && ok "$5" || bad "$5 — wanted rc $1 '$2', got rc $rc '$out'"
}

# H1: Taken by: opening a line holds, and the verdict is a pause.
C=$(CMTS "$(CMT "Taken by: operator
I'll push the fix tonight" "$T2")")
row 1 "held|hold:human-fix $T2 Taken by: operator" "$OPEN" "$C" "H1: a person's 'Taken by: operator' line holds as hold:human-fix"
V=$(hold_classify "$OPEN" "$C")
hold_is_pause "$V" && ok "H1: hold_is_pause reads hold:human-fix as a pause" \
  || bad "H1: hold_is_pause must read the human-fix verdict as a pause: '$V'"
hold_is_abandon "$V" && bad "H1: human-fix is not an abandon" || ok "H1: human-fix is not an abandon"

# H2: [human-fix] opening a line holds.
C=$(CMTS "$(CMT "[human-fix] I have this one, agents keep off" "$T2")")
row 1 "held|hold:human-fix $T2 [human-fix] I have this one, agents keep off" "$OPEN" "$C" "H2: '[human-fix]' opening a line holds"

# H3: the #5022 shape — a principal's free-text direction is not a take-over.
C=$(CMTS "$(CMT "Narrow the fix to the parser. The agent round should only touch bin/lib/x.sh, and I'm watching this one." "$T2" User OWNER)")
row 0 "clear|no-hold" "$OPEN" "$C" "H3: an OWNER's free-text direction holds nothing"

# H4: a Bot comment carrying both markers holds nothing (no tag escape hatch).
C=$(CMTS "$(CMT "[human-fix]
Taken by: x
<!-- nh-fp:abc123def456 -->" "$T2" Bot)")
row 0 "clear|no-hold" "$OPEN" "$C" "H4: a Bot comment with [human-fix] and Taken by: holds nothing"

# H5: prose shapes hold nothing.
row 0 "clear|no-hold" "$OPEN" "$(CMTS "$(CMT "this was Taken by: surprise, honestly" "$T2")")" "H5a: Taken by: mid-line holds nothing"
row 0 "clear|no-hold" "$OPEN" "$(CMTS "$(CMT "> Taken by: operator" "$T2")")" "H5b: a '>' quoted Taken by: holds nothing"
row 0 "clear|no-hold" "$OPEN" "$(CMTS "$(CMT "**Taken by:** operator" "$T2")")" "H5c: '**Taken by:**' holds nothing"
row 0 "clear|no-hold" "$OPEN" "$(CMTS "$(CMT "see the [human-fix] marker in the docs" "$T2")")" "H5d: a mid-line [human-fix] holds nothing"
row 0 "clear|no-hold" "$OPEN" "$(CMTS "$(CMT "Taken by:   " "$T2")")" "H5e: 'Taken by:' with no name holds nothing"

# H6: HUMAN-STEP-DONE: over the marker lifts it.
C=$(CMTS "$(CMT "Taken by: operator" "$T1")" "$(CMT "HUMAN-STEP-DONE: pushed" "$T2")")
row 0 "clear|lifted-by-human-step $T2" "$OPEN" "$C" "H6: HUMAN-STEP-DONE: newer than the marker lifts it"

# H7: RESUME over the marker lifts it.
C=$(CMTS "$(CMT "[human-fix]" "$T1")" "$(CMT "RESUME" "$T2")")
row 0 "clear|lifted-by-comment $T2" "$OPEN" "$C" "H7: RESUME newer than the marker lifts it"

# H8: a done lifts the marker only, a person's older HOLD still stands.
C=$(CMTS "$(CMT "HOLD — wait for the operator" "$T1")" "$(CMT "Taken by: operator" "$T2")" "$(CMT "HUMAN-STEP-DONE: pushed" "$T3")")
row 1 "held|hold:comment $T1 HOLD — wait for the operator" "$OPEN" "$C" "H8: a done over the marker over a person's HOLD leaves the HOLD"
C=$(CMTS "$(CMT "HUMAN-STEP-DONE: old" "$T1")" "$(CMT "Taken by: operator again" "$T2")")
row 1 "held|hold:human-fix $T2 Taken by: operator again" "$OPEN" "$C" "H8b: a newer Taken by: over an older done holds again"
C=$(CMTS "$(CMT "Taken by: operator" "$T1")" "$(CMT "HUMAN-STEP-DONE: pushed" "$T2" Bot)")
row 1 "held|hold:human-fix $T1 Taken by: operator" "$OPEN" "$C" "H8c: a Bot's done never lifts the marker"

# H9: comments only — the body and title hold nothing.
row 0 "clear|no-hold" "$(ISSUE open ai-build 'BH-1: x' "## Scope
[human-fix]
Taken by: operator")" '[]' "H9: [human-fix] / Taken by: lines in the BODY hold nothing"
row 0 "clear|no-hold" "$(ISSUE open ai-build '[human-fix] Taken by: operator')" '[]' "H9b: …nor in the title"

# §A: hold_ambiguous still compiles its jq (it shares HOLD__JQ_DEFS). A HOLD
# followed by a person's neutral comment is ambiguous; a Taken by: is decisive.
C='[{"id":11,"body":"HOLD: wait","created_at":"'"$T1"'","user":{"type":"User"}},{"id":12,"body":"thinking about it","created_at":"'"$T2"'","user":{"type":"User"}}]'
A=$(hold_ambiguous "$OPEN" "$C"); rc=$?
[ "$rc" = 0 ] && [[ "$A" == "12	$T2	thinking about it" ]] && ok "A1: hold_ambiguous still answers on a neutral person comment" \
  || bad "A1: hold_ambiguous rc $rc '$A'"

echo "hold-human-fix.bh-5125: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
