#!/bin/bash
# tests/hold-needs-human.bh-3443-test.sh — the waiting-on-human hold in
# bin/lib/hold.sh (BH-3443, slice 2 of BH-3433). A `NEEDS-HUMAN:` line opening a
# comment parks the ticket as `hold:waiting-on-human <at> <action>`, and a
# `HUMAN-STEP-DONE:` (or a `## Hub probe … PASS`) directly over it lifts it. A
# bot is heard only for the placer's own tagged marker.
#   §H  the hold            §R  the release          §N  negatives (invariant c)
#   §X  interaction with a person's HOLD/ABANDON, the label, closed, the title
#   §T  bin/lib/triage-state.sh's skip line
#   §M  mutation guard (D1): three edits to a copy of hold.sh each go red
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export HARNESS_TEST_SANDBOX=1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

LIB="$DIR/bin/lib/hold.sh"
. "$LIB" || { echo "FAIL: $LIB does not source"; exit 1; }

# The fixture thread carries literal timestamps, oldest first, so every row
# below says which comment is newer without reading a clock.
T1=2026-09-29T09:00:00Z; T2=2026-09-29T10:00:00Z; T3=2026-09-29T11:00:00Z; T4=2026-09-29T12:00:00Z
ISSUE() { # ISSUE [state] [labels csv] [title] [body]
  jq -nc --arg s "${1:-open}" --arg l "${2-ai-build}" --arg t "${3:-BH-1: a thing}" --arg b "${4:-## Scope}" \
    '{state:$s, labels:($l | split(",") | map(select(. != "")) | map({name:.})), title:$t, body:$b}'
}
CMT() { jq -nc --arg b "$1" --arg c "$2" --arg u "${3:-User}" '{body:$b, created_at:$c, user:{type:$u}}'; }
CMTS() { local IFS=","; printf '[%s]' "$*"; }
ACT='run vs_publish probe from the hub'
MARK="NEEDS-HUMAN: $ACT"
TAG='<!-- nh-fp:abc123def456 -->'
OPEN=$(ISSUE)

# row <want-rc> <want-exact-or-prefix*> <issue> <comments> <label> [lib]
row() {
  local out rc
  out=$(hold_classify "$3" "$4" 2>/dev/null); rc=$?
  out=$(printf '%s' "$out" | tr '\t' '|')
  case "$2" in
    *'*') [ "$rc" = "$1" ] && [[ "$out" == "${2%\*}"* ]] && ok || bad "$5 — wanted rc $1 '$2', got rc $rc '$out'" ;;
    *)    [ "$rc" = "$1" ] && [ "$out" = "$2" ] && ok || bad "$5 — wanted rc $1 '$2', got rc $rc '$out'" ;;
  esac
}

# ── §H: the hold ───────────────────────────────────────────────────────────
C=$(CMTS "$(CMT "$MARK" "$T2")")
row 1 "held|hold:waiting-on-human $T2 $ACT" "$OPEN" "$C" "H1: a person's NEEDS-HUMAN: line holds"
V=$(hold_classify "$OPEN" "$C")
hold_is_pause "$V" && ok || bad "H1: hold_is_pause must read the waiting-on-human verdict as a pause: '$V'"
hold_is_abandon "$V" && bad "H1: waiting-on-human is not an abandon" || ok
C=$(CMTS "$(CMT "$MARK

Builds of this ticket are paused until a person does the step above.
$TAG" "$T2" Bot)")
row 1 "held|hold:waiting-on-human $T2 $ACT" "$OPEN" "$C" "H2: the placer's tagged Bot marker holds"
LONG=$(printf 'x%.0s' $(seq 1 300))
V=$(hold_classify "$OPEN" "$(CMTS "$(CMT "NEEDS-HUMAN: $LONG" "$T2")")" | cut -f2)
A="${V#hold:waiting-on-human $T2 }"
[ "${#A}" = 160 ] && ok || bad "H3: a 300-char action must be capped at 160, got ${#A}"

# ── §R: the release ────────────────────────────────────────────────────────
C=$(CMTS "$(CMT "$MARK" "$T1")" "$(CMT 'HUMAN-STEP-DONE: ran it, output ok' "$T2")")
row 0 "clear|lifted-by-human-step $T2" "$OPEN" "$C" "R1: HUMAN-STEP-DONE: over the marker lifts it"
C=$(CMTS "$(CMT "$MARK" "$T1")" "$(CMT '## Hub probe vs_publish PASS
all green' "$T2")")
row 0 "clear|lifted-by-human-step $T2" "$OPEN" "$C" "R2: a '## Hub probe … PASS' over the marker lifts it"
C=$(CMTS "$(CMT "$MARK" "$T1")" "$(CMT 'RESUME' "$T2")")
row 0 "clear|lifted-by-comment $T2" "$OPEN" "$C" "R3: RESUME over the marker lifts it"
C=$(CMTS "$(CMT "NEEDS-HUMAN: old ask" "$T1")" "$(CMT 'HUMAN-STEP-DONE: did it' "$T2")" "$(CMT "$MARK" "$T3")")
row 1 "held|hold:waiting-on-human $T3 $ACT" "$OPEN" "$C" "R4: a new marker over a done holds again"
C=$(CMTS "$(CMT "$MARK" "$T1")" "$(CMT 'HUMAN-STEP-DONE: first' "$T2")" "$(CMT 'HUMAN-STEP-DONE: second' "$T3")")
row 0 "clear|lifted-by-human-step $T2" "$OPEN" "$C" "R5: two dones over a marker lift it, at the done directly above"

# ── §N: negatives ──────────────────────────────────────────────────────────
C=$(CMTS "$(CMT "$MARK" "$T2" Bot)")
row 0 "clear|no-hold" "$OPEN" "$C" "N1: a Bot marker without the nh-fp tag holds nothing"
C=$(CMTS "$(CMT "see NEEDS-HUMAN: x for the format" "$T2")")
row 0 "clear|no-hold" "$OPEN" "$C" "N2: a mid-line NEEDS-HUMAN: holds nothing"
C=$(CMTS "$(CMT "NEEDS-HUMAN:   " "$T2")")
row 0 "clear|no-hold" "$OPEN" "$C" "N3: NEEDS-HUMAN: with only whitespace holds nothing"
row 0 "clear|no-hold" "$(ISSUE open ai-build 'BH-1: x' "## Scope
NEEDS-HUMAN: x")" '[]' "N4: a NEEDS-HUMAN: line in the BODY holds nothing"
row 0 "clear|no-hold" "$(ISSUE open ai-build 'NEEDS-HUMAN: x')" '[]' "N4: …nor in the title"
C=$(CMTS "$(CMT "$MARK" "$T1")" "$(CMT 'HUMAN-STEP-DONE: bot says so' "$T2" Bot)")
row 1 "held|hold:waiting-on-human $T1 $ACT" "$OPEN" "$C" "N5: a Bot HUMAN-STEP-DONE: never releases"
C=$(CMTS "$(CMT "$MARK" "$T1")" "$(CMT 'Do NOT post HUMAN-STEP-DONE yet' "$T2")")
row 1 "held|hold:waiting-on-human $T1 $ACT" "$OPEN" "$C" "N6: 'Do NOT post HUMAN-STEP-DONE yet' does not release"
C=$(CMTS "$(CMT "$MARK" "$T1")" "$(CMT '## Hub probe results FAIL' "$T2")")
row 1 "held|hold:waiting-on-human $T1 $ACT" "$OPEN" "$C" "N7: a FAILed hub probe does not release"
C=$(CMTS "$(CMT 'HOLD: wait' "$T1")" "$(CMT 'HUMAN-STEP-DONE: did a thing' "$T2")")
row 1 "held|hold:comment $T1 HOLD: wait" "$OPEN" "$C" "N8: a done with no marker beneath never lifts a person's HOLD"
row 2 "unreadable*" 'not json' '[]' "N9: unparseable issue json is unreadable"

# ── §X: interaction ────────────────────────────────────────────────────────
C=$(CMTS "$(CMT 'HOLD: wait for the operator' "$T1")" "$(CMT "$MARK" "$T2")" "$(CMT 'HUMAN-STEP-DONE: ran it' "$T3")")
row 1 "held|hold:comment $T1 HOLD: wait for the operator" "$OPEN" "$C" "X1: a done over a marker over a person's HOLD leaves the HOLD"
C=$(CMTS "$(CMT 'ABANDON this one' "$T1")" "$(CMT "$MARK" "$T2")" "$(CMT 'HUMAN-STEP-DONE: ran it' "$T3")")
row 1 "held|abandon:comment $T1 ABANDON this one" "$OPEN" "$C" "X2: a done over a marker over an ABANDON leaves the ABANDON"
row 1 "held|hold:label hold" "$(ISSUE open 'ai-build,hold')" "$(CMTS "$(CMT "$MARK" "$T2")")" "X3: the hold label wins over a marker"
row 1 "held|closed" "$(ISSUE closed ai-build)" "$(CMTS "$(CMT "$MARK" "$T2")")" "X4: closed wins"
C=$(CMTS "$(CMT "$MARK" "$T1")" "$(CMT 'HUMAN-STEP-DONE: ran it' "$T2")")
row 1 "held|hold:title BH-1 (HOLD): x" "$(ISSUE open ai-build 'BH-1 (HOLD): x')" "$C" "X5: a title HOLD survives a human-step lift"
C=$(CMTS "$(CMT "$MARK" "$T1")" "$(CMT 'HOLD: not yet' "$T2")" "$(CMT 'RESUME' "$T3")")
row 0 "clear|lifted-by-comment $T3" "$OPEN" "$C" "X6: RESUME over HOLD over a marker lifts (the law is unchanged)"
C=$(CMTS "$(CMT 'HOLD: from the app' "$T2" Bot)")
row 0 "clear|no-hold" "$OPEN" "$C" "X7: a bot HOLD is still ignored"

# ── §T: triage-state says it skipped ──────────────────────────────────────
TH="$T/ts"; mkdir -p "$TH/logs"
(
  export HARNESS="$TH" PROJECT=cromford LOG="$T/ts.log"
  . "$DIR/bin/lib/triage-state.sh" || exit 9
  _ts_prs_json() { printf '[]\n' > "$2/prs.json"; }
  mkdir -p "$(_ts_dir)"
  jq -nc --argjson i "$OPEN" --argjson c "$(CMTS "$(CMT "$MARK" "$T2")")" '{doc:{issue:$i, comments:$c}}' > "$(_ts_dir)/K1.raw"
  _ts_owned K1 BH-1 h "" 1 > "$T/ts.out"
)
[[ "$(cat "$T/ts.out" 2>/dev/null)" == "held:held hold:waiting-on-human "* ]] && ok \
  || bad "T: _ts_owned must answer held:held hold:waiting-on-human …, got '$(cat "$T/ts.out" 2>/dev/null)'"
[ "$(grep -c "triage-state: BH-1 skip :: waiting on human: $ACT\$" "$T/ts.log" 2>/dev/null)" = 1 ] && ok \
  || bad "T: exactly one 'triage-state: BH-1 skip :: waiting on human: $ACT' line: $(cat "$T/ts.log" 2>/dev/null)"

# ── §M: the mutation guard (D1) ────────────────────────────────────────────
# Each edit is applied to a COPY of hold.sh; the suite first proves the edit
# changed the file (a sed that matched nothing would make the red vacuous),
# then that the named case reads differently under it.
mkdir -p "$T/m"
mutant() { # mutant <name> <sed-expr> <issue> <comments> <good-verdict>
  local f="$T/m/$1.sh" got
  sed -E "$2" "$LIB" > "$f"
  cmp -s "$LIB" "$f" && { bad "$1: the mutation did not change hold.sh (sed matched nothing)"; return; }
  got=$( . "$f" && hold_classify "$3" "$4" | tr '\t' '|' )
  [ "$got" != "$5" ] && ok || bad "$1: the suite stays green under the mutation (still '$got')"
}
mutant M1 's/ or \(\.d == "needs-human" and \(\.body \| test\(\$nhtag\)\)\)//' "$OPEN" \
  "$(CMTS "$(CMT "$MARK
$TAG" "$T2" Bot)")" "held|hold:waiting-on-human $T2 $ACT"
mutant M2 's/then "done"/then "lift"/' "$OPEN" \
  "$(CMTS "$(CMT 'HOLD: wait' "$T1")" "$(CMT 'HUMAN-STEP-DONE: did a thing' "$T2")")" "held|hold:comment $T1 HOLD: wait"
mutant M3 's/test\(\$nh\) then "needs-human"/false then "needs-human"/' "$OPEN" \
  "$(CMTS "$(CMT "$MARK" "$T2")")" "held|hold:waiting-on-human $T2 $ACT"

echo "hold-needs-human.bh-3443: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
