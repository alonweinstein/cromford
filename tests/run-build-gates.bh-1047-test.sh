#!/bin/bash
# tests/run-build-gates.bh-1047-test.sh — BH-1047: a stub-flip pairing reaches
# the reviewer.
#
# The scanner can now answer rc 0 on a diff that DID remove test cases, because
# it found the replacements. That is a weaker statement than the old rc 0 and
# the reviewer has to be told which cases were flipped and where their
# replacements live — a pairing nobody reads is a silent pass, which is the
# thing the tamper gate exists to prevent. So the gate block is extracted
# VERBATIM from bin/run-build.sh (via tests/lib/rb-all.sh, like its sibling
# suite) and driven with a stubbed scanner: this pins the WIRING, not the
# scanner, which is tested in tests/test-tamper-scan.bh-1047-test.sh.
# Run from anywhere: tests/run-build-gates.bh-1047-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
mkdir -p "$T/bin" "$T/logs" "$T/build"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

awk '/^# >>> mechanical gates/{f=1;next} /^# <<< mechanical gates/{exit} f' \
  "$RB_ALL" > "$T/gates.sh"
[ -s "$T/gates.sh" ] && ok || bad "could not extract the gate block — markers missing?"

mkstub() { printf '#!/bin/bash\ncat <<"REPORT_EOF"\n%s\nREPORT_EOF\nexit %s\n' "$2" "$1" > "$T/bin/$3"; chmod +x "$T/bin/$3"; }
mkstub 0 "REPRO_REPORT_0" repro-gate.sh

# run <tamper-report> — runs the gate block with the scanner stubbed at rc 0
run() {
  mkstub 0 "$1" test-tamper-scan.sh
  rm -f "$T/build/RESULT" "$T/NOTE.txt"
  ( HARNESS="$T" BUILD="$T/build" ALERTS="$T/logs/ALERTS.log" \
    PROJECT=p KEY=K BASE=main \
    bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      RESULT() { echo "$*" > "$BUILD/RESULT"; }
      . "$0"
      printf "%s" "$GATES_NOTE" > '"$T"'/NOTE.txt
    ' "$T/gates.sh" >/dev/null 2>&1 )
  echo "$? $(cat "$T/build/RESULT" 2>/dev/null || echo none)"
}
note() { cat "$T/NOTE.txt" 2>/dev/null; }

FLIPREPORT='TAMPER_COUNT: 0 (deleted_files=0 deleted_cases=0 added_skips=0 stub_flips=2)
BLOCKING_COUNT: 0 (deletions only)
ASSERTION_DELTA: 3 (added=5 removed=2) — reported, not gated
REWORDED_CASES: 1 (case openers removed and re-added in the same file)
CONTRACT_CHILD: TK-1531.1 (parent TK-1531, key TK-1828)
STUB_FLIPS: 2
stub-flip: tests/chan.test.ts: it("is a stub that cancels nothing yet" (stub marker) -> tests/chan.impl.test.ts
stub-flip: tests/chan.test.ts: it("is a stub that lists nothing yet" (stub marker) -> tests/chan.impl.test.ts
VERDICT: no test DELETIONS; 2 stub case(s) flipped and paired with a replacement'

# ---------- 1. a pairing is carried into the review note, in full ----------
OUT=$(run "$FLIPREPORT")
grep -q '^0 none' <<<"$OUT" && ok || bad "a paired stub flip must not block the build (got: $OUT)"
note | grep -q 'TEST-TAMPER GATE: clean' && ok \
  || bad "the clean headline tests/run-build-gates-test.sh pins must survive: $(note)"
note | grep -q 'stub-flip: tests/chan.test.ts.*-> tests/chan.impl.test.ts' && ok \
  || bad "the pairing lines must reach the reviewer: $(note)"
note | grep -q '2 stub-flip pairing' && ok || bad "the note must say how many pairings there are: $(note)"
note | grep -qi 'a missing assertion there is a BLOCK' && ok \
  || bad "the note must tell the reviewer what to do with the pairing: $(note)"
note | grep -q 'CONTRACT_CHILD: TK-1531.1' && ok \
  || bad "the whole scanner report travels, not a summary of it: $(note)"

# ---------- 2. a genuinely clean scan keeps the old one-liner ----------
# D13: the longer note claims pairings exist. On a diff that removed nothing it
# would be a false statement, so it must not render.
OUT=$(run "TAMPER_COUNT: 0 (deleted_files=0 deleted_cases=0 added_skips=0 stub_flips=0)
BLOCKING_COUNT: 0 (deletions only)
VERDICT: no test tampering detected")
grep -q '^0 none' <<<"$OUT" && ok || bad "a clean scan must not block (got: $OUT)"
note | grep -q 'TEST-TAMPER GATE: clean (no tests deleted or removed)\.' && ok \
  || bad "a clean scan must keep its one-line note: $(note)"
grep -q 'stub-flip' <<<"$(note)" && bad "a clean scan must not mention pairings: $(note)" || ok
grep -q 'pairing' <<<"$(note)" && bad "a clean scan must not claim pairings exist: $(note)" || ok

# ---------- 3. an unpaired flip is NOT a pairing note ----------
# stub-flip-unpaired lines arrive on the rc 1 path, but a scanner that reported
# them at rc 0 (a future arm, a stale binary) must not be read as a pairing.
OUT=$(run "TAMPER_COUNT: 0 (deleted_files=0 deleted_cases=0 added_skips=0 stub_flips=0)
BLOCKING_COUNT: 0 (deletions only)
stub-flip-unpaired: tests/chan.test.ts: it(\"is a stub\" (no added case in a test file importing: src/chan)
VERDICT: no test tampering detected")
grep -q '^0 none' <<<"$OUT" && ok || bad "an rc 0 scan must not block whatever it printed (got: $OUT)"
grep -q 'pairing(s) below' <<<"$(note)" && bad "an unpaired line is not a pairing: $(note)" || ok

echo "run-build-gates.bh-1047-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
