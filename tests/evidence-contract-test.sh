#!/bin/bash
# tests/evidence-contract-test.sh — bin/lib/evidence.sh is the contract every
# BH-527 child imports: the evidence.json schema, the three verdict words, and
# the two readers every consumer calls (#545).
#
# No caller is wired yet (the wiring is a sibling's child), so this suite IS the
# consumer: it sources the lib the way a lane does and drives all three
# functions, including the paths that must FAIL — jq absent, a build dir that
# cannot be written, a file that does not parse, and a note carrying a shell
# substitution that must stay data. Every assertion is on a return code, a
# printed value or a file the lib wrote; the two source-text greps at the end
# are the ticket's own acceptance lines (no vendor name, no network) and are
# guarded so an absent file fails rather than passes.
#
# Run: bash tests/evidence-contract-test.sh   (exit 0 = all pass)
set -uo pipefail
if [ -f "$(dirname "$0")/lib/scratch.sh" ]; then
  # shellcheck source=/dev/null
  . "$(dirname "$0")/lib/scratch.sh" || exit 1
else
  T=$(mktemp -d "${TMPDIR:-/tmp}/scratch.XXXXXX") || exit 1
  trap 'rm -rf "$T"' EXIT
fi
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/evidence.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

# ── A0 sourcing is inert ─────────────────────────────────────────────────────
# A lib that prints or writes at source time corrupts every lane that sources
# it, so this runs first, in its own process, under `set -u`.
mkdir -p "$T/probe"
OUT=$(cd "$T/probe" && bash -u -c ". '$LIB'" 2>&1); RC=$?
eq "A0 sourcing under set -u prints nothing" "$OUT" ""
eq "A0 sourcing under set -u exits 0" "$RC" "0"
eq "A0 sourcing creates no files" "$(ls -A "$T/probe")" ""

# shellcheck source=../bin/lib/evidence.sh
. "$LIB" || { echo "evidence-contract: cannot source bin/lib/evidence.sh"; exit 1; }

# ── A1 a plan it cannot read is refused; a plan with nothing to score is 0 ───
# TEST-CHANGE (#546): this block used to pin the stub's line
# "EVIDENCE VERDICTS: 0 claims (scorer not implemented)" and rc 0 on a
# nonexistent plan.md. The scorer that replaced the stub must REFUSE a plan it
# cannot read (rc 1, one could-not-run line, evidence.json untouched), so those
# two assertions described behaviour the ticket retires. What they were really
# protecting — the zero schema, and no temp file left behind — is asserted here
# on a plan that exists and has no acceptance section. Nothing else in this
# suite changed.
mkdir -p "$T/b1" "$T/repo"
OUT=$(evidence_score "$T/b1" "$T/nosuchplan.md" main "$T/repo" 2>&1); RC=$?
eq "A1 an unreadable plan returns 1" "$RC" "1"
eq "A1 an unreadable plan prints exactly one line" "$OUT" \
  "EVIDENCE VERDICTS: could not run (plan unreadable)"
eq "A1 an unreadable plan writes nothing at all" "$(ls -A "$T/b1")" ""
printf '# Plan\n\n## Scope\nnothing here to score\n' > "$T/plan-noacc.md"
OUT=$(evidence_score "$T/b1" "$T/plan-noacc.md" main "$T/repo"); RC=$?
eq "A1 a plan with no acceptance section returns 0" "$RC" "0"
eq "A1 a plan with no acceptance section prints exactly one line" "$OUT" \
  "EVIDENCE VERDICTS: 0 confirmed, 0 refuted, 0 inconclusive of 0 claims"
[ -f "$T/b1/evidence.json" ] && ok || bad "A1 a scored build must have an evidence.json"
jq -e '.total==0 and .claims==[] and .confirmed==0 and .refuted==0 and .inconclusive==0' \
  "$T/b1/evidence.json" >/dev/null 2>&1 && ok \
  || bad "A1 evidence.json must parse with the zero schema: [$(cat "$T/b1/evidence.json" 2>&1)]"
eq "A1 the atomic write leaves no temp file behind" "$(ls -A "$T/b1")" "evidence.json"

# ── A2 jq absent: rc 1, one line, nothing written ────────────────────────────
# The scorer's whole output is jq-shaped, so a box without jq must say so and
# write NOTHING — a half-written evidence.json would be read as a scored build.
mkdir -p "$T/b2" "$T/nobin"
OUT=$( PATH="$T/nobin"; evidence_score "$T/b2" plan.md main "$T/repo" 2>&1 ); RC=$?
eq "A2 jq missing returns 1" "$RC" "1"
eq "A2 jq missing prints exactly one line" "$OUT" "EVIDENCE VERDICTS: could not run (jq missing)"
eq "A2 jq missing writes nothing at all" "$(ls -A "$T/b2")" ""

# ── A2b an unwritable build dir is a failure, never the success line ─────────
OUT=$(evidence_score "$T/nosuchbuild" plan.md main "$T/repo" 2>&1); RC=$?
eq "A2b a missing build dir returns 1" "$RC" "1"
eq "A2b a missing build dir prints the could-not-run line" "$OUT" \
  "EVIDENCE VERDICTS: could not run (build dir not writable)"
[ ! -e "$T/nosuchbuild" ] && ok || bad "A2b a refused score must create no build dir"

# ── A3 evidence_counts: the file, an empty dir, an unparseable file ──────────
OUT=$(evidence_counts "$T/b1"); RC=$?
eq "A3 counts on the stub's file" "$OUT" "confirmed=0 refuted=0 inconclusive=0 total=0"
eq "A3 counts returns 0 on a good file" "$RC" "0"
mkdir -p "$T/empty"
OUT=$(evidence_counts "$T/empty"); RC=$?
eq "A3 counts on a dir with no evidence.json" "$OUT" "not-recorded"
eq "A3 counts returns 0 when there is nothing to read" "$RC" "0"
mkdir -p "$T/bad"; printf '{not json\n' > "$T/bad/evidence.json"
OUT=$(evidence_counts "$T/bad"); RC=$?
eq "A3 counts on a file that does not parse" "$OUT" "not-recorded"
eq "A3 counts returns 0 on a file that does not parse" "$RC" "0"

# ── A4 evidence_note on a 3-row fixture, one of each verdict ─────────────────
# The hostile note is the point: the scorer will copy model-written text into
# this file, so evidence_note must print it as DATA. If any of it reaches a
# shell, $T/PWNED appears.
mkdir -p "$T/b3"
HOSTILE='$(touch '"$T"'/PWNED)'
jq -n --arg hostile "$HOSTILE" '{total:3,confirmed:1,refuted:1,inconclusive:1,claims:[
  {n:1,claim:"the counts render",verdict:"CONFIRMED",artifact:"bin/a.sh:3",note:"ran it",proposed:"CONFIRMED"},
  {n:2,claim:"the gate demotes",verdict:"REFUTED",artifact:"bin/x.sh:12",note:$hostile,proposed:"CONFIRMED"},
  {n:3,claim:"the lane is reachable",verdict:"INCONCLUSIVE",artifact:"",note:"no artifact named",proposed:""}]}' \
  > "$T/b3/evidence.json" || bad "A4 could not write the fixture"
evidence_note "$T/b3" > "$T/note.txt"; RC=$?
eq "A4 note returns 0" "$RC" "0"
eq "A4 note prints one line per claim" "$(grep -c . "$T/note.txt")" "3"
eq "A4 every line is a CLAIM line in one of the three verdicts" \
  "$(grep -cE '^CLAIM [0-9]+: (CONFIRMED|REFUTED|INCONCLUSIVE) :: .* :: .' "$T/note.txt")" "3"
eq "A4 the CONFIRMED row" "$(sed -n 1p "$T/note.txt")" "CLAIM 1: CONFIRMED :: bin/a.sh:3 :: ran it"
eq "A4 the REFUTED row carries its artifact and its note verbatim" "$(sed -n 2p "$T/note.txt")" \
  "CLAIM 2: REFUTED :: bin/x.sh:12 :: $HOSTILE"
eq "A4 the INCONCLUSIVE row prints an empty artifact" "$(sed -n 3p "$T/note.txt")" \
  "CLAIM 3: INCONCLUSIVE ::  :: no artifact named"
[ ! -e "$T/PWNED" ] && ok || bad "A4 a note containing \$(…) was expanded by a shell — file content must stay data"
OUT=$(evidence_note "$T/empty"); RC=$?
eq "A4 note on a dir with no evidence.json prints nothing" "$OUT" ""
eq "A4 note returns 0 when there is nothing to read" "$RC" "0"
OUT=$(evidence_note "$T/bad" 2>&1); RC=$?
eq "A4 note on a file that does not parse prints nothing" "$OUT" ""
eq "A4 note returns 0 on a file that does not parse" "$RC" "0"

# ── A5 counts come from the file's own fields ────────────────────────────────
eq "A5 counts on the 3-row fixture" "$(evidence_counts "$T/b3")" \
  "confirmed=1 refuted=1 inconclusive=1 total=3"

# ── A6 the ticket's own two source-level acceptance lines ────────────────────
# Guarded: an absent lib must fail here, not pass by grepping nothing.
[ -s "$LIB" ] && ok || bad "A6 bin/lib/evidence.sh must exist and be non-empty"
grep -qE 'claude|codex|anthropic|http' "$LIB" \
  && bad "A6 the lib must name no model vendor and reach no network" || ok
bash -n "$LIB" 2>/dev/null && ok || bad "A6 bash -n bin/lib/evidence.sh must pass"

# ── A7 one whole lane pass, in its own process ───────────────────────────────
# How the wiring sibling will use the lib end to end: source it under the same
# `set -uo pipefail` a lane runs with, score the build, then read the artifact
# back with both readers. Nothing is wired yet, so this pass IS the consumer.
cat > "$T/lane.sh" <<'LANE'
set -uo pipefail
. "$1/bin/lib/evidence.sh"
B="$2"
evidence_score "$B" "$B/plan.md" main "$1" || exit 9
printf 'EVIDENCE %s\n' "$(evidence_counts "$B")"
evidence_note "$B"
LANE
mkdir -p "$T/lane"
# TEST-CHANGE (#546): the lane now needs a plan to score — the scorer refuses an
# unreadable one (A1) instead of printing the stub's "0 claims" line. A plan with
# no acceptance section is the smallest honest lane fixture: nothing to score.
printf '# Plan — the lane fixture, no acceptance section\n' > "$T/lane/plan.md"
LOUT=$(bash "$T/lane.sh" "$DIR" "$T/lane" 2>&1); LRC=$?
eq "A7 the lane exits 0" "$LRC" "0"
eq "A7 the lane prints the zero summary then the counts, and no note rows" "$LOUT" \
  "$(printf 'EVIDENCE VERDICTS: 0 confirmed, 0 refuted, 0 inconclusive of 0 claims\nEVIDENCE confirmed=0 refuted=0 inconclusive=0 total=0')"
jq -e '.claims==[]' "$T/lane/evidence.json" >/dev/null 2>&1 && ok \
  || bad "A7 the lane must leave a parseable evidence.json in the build dir"

echo "evidence-contract: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
