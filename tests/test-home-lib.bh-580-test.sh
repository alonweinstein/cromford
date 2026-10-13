#!/bin/bash
# tests/test-home-lib.bh-580-test.sh — bin/lib/test-home-lib.sh is the ONE
# definition every BH-580 child imports: what a test path is, what a PER-TICKET
# test path is, the `REROUTE tests:` record format, the kill switch, and the two
# sentences the planner and the executor are handed.
#
# No caller is wired yet (that is the parent's later children), so this suite IS
# the consumer: it sources the lib the way a lane does, and section A8 drives a
# whole lane pass in a separate bash process — source, classify, reroute, rewrite
# the pre-plan list, print the note. Every assertion is on a return code, a
# printed value or a file the lib wrote; never on the lib's source text (D3).
#
# Run: bash tests/test-home-lib.bh-580-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }


# ── A0 sourcing is inert ─────────────────────────────────────────────────────
# A lib that prints or writes at source time corrupts every lane that sources
# it, so this runs before anything else, in its own process, under `set -u`.
mkdir -p "$T/probe"
OUT=$(cd "$T/probe" && bash -u -c ". '$DIR/bin/lib/test-home-lib.sh'" 2>&1); RC=$?
eq "A0 sourcing under set -u prints nothing" "$OUT" ""
eq "A0 sourcing under set -u exits 0" "$RC" "0"
eq "A0 sourcing creates no files" "$(ls -A "$T/probe")" ""

# shellcheck source=../bin/lib/test-home-lib.sh
. "$DIR/bin/lib/test-home-lib.sh" || { echo "test-home-lib: cannot source bin/lib/test-home-lib.sh"; exit 1; }

# ── A1 th_per_ticket_path ────────────────────────────────────────────────────
p() { eq "A1 $1 + $3 -> $2" "$(th_per_ticket_path "$1" "$3")" "$2"; }
p tests/level2-unit/foo.test.ts tests/level2-unit/foo.ab-1.test.ts AB-1
p x.spec.js                     x.ab-1.spec.js                     AB-1
p tests/x-test.sh               tests/x.ab-1-test.sh               AB-1
p tests/fixture.json            tests/fixture.ab-1.json            AB-1
p a.b.test.ts                   a.b.ab-1.test.ts                   AB-1
p tests/Makefile                tests/Makefile.ab-1                AB-1
p a/b/c/deep.test.ts            a/b/c/deep.ab-1.test.ts            AB-1
p tests/x-test.sh               tests/x.ab-1-test.sh               ab-1
p tests/level2-unit/foo.test.ts tests/level2-unit/foo.TK-1629.test.ts TK-1629
# already this ticket's own file: printed unchanged, whatever its shape
p tests/x.ab-1-test.sh          tests/x.ab-1-test.sh               AB-1
p tests/level2-unit/foo.ab-1.test.ts tests/level2-unit/foo.ab-1.test.ts AB-1
th_per_ticket_path "" AB-1 >/dev/null 2>&1 && bad "A1 an empty path must rc 1" || ok
th_per_ticket_path tests/x.test.ts "" >/dev/null 2>&1 && bad "A1 an empty key must rc 1" || ok

# ── A2 th_is_per_ticket / th_is_own ──────────────────────────────────────────
per()   { th_is_per_ticket "$1" && ok || bad "A2 must read as per-ticket: [$1]"; }
noper() { th_is_per_ticket "$1" && bad "A2 must NOT read as per-ticket: [$1]" || ok; }
for f in tests/cost-anchored.test.js tests/v2-report.test.ts tests/level2-unit/a-b.test.ts \
         tests/overlap-guard-test.sh tests/e2e-paths-lib-test.sh src/lib/pricing.ts ""; do noper "$f"; done
for f in tests/level2-unit/foo.ab-1.test.ts tests/x.ab-1-test.sh org-report.TK-1629.test.ts; do per "$f"; done
per "$0"   # this suite's own name is the rule it establishes
# A directory that looks like a key must not count: the BASENAME carries the key
noper tests/bh-580/shared.test.ts
th_is_per_ticket tests/foo.utf-8.test.ts && ok \
  || bad "A2 tests/foo.utf-8.test.ts reads as per-ticket on purpose: the safe direction is DEFER (leave it to its owner), never reroute someone else's file"

own()   { th_is_own "$1" "$2" && ok || bad "A2 must be $2's own file: [$1]"; }
noown() { th_is_own "$1" "$2" && bad "A2 must NOT be $2's own file: [$1]" || ok; }
own   tests/x.ab-1-test.sh AB-1
own   tests/x.ab-1-test.sh ab-1
own   tests/level2-unit/foo.ab-1.test.ts AB-1
noown tests/x.ab-1-test.sh AB-2
noown tests/x.ab-11-test.sh AB-1
noown tests/foo.test.ts AB-1
noown tests/x.ab-1-test.sh ""
noown "" AB-1

# ── A3 matcher parity with bin/test-tamper-scan.sh ───────────────────────────
# The production function VERBATIM, extracted from the real script (never run it:
# the scan itself shells out to git at top level).
sed -n '/^is_test_path() {/,/^}/p' "$DIR/bin/test-tamper-scan.sh" > "$T/tamper.sh"
[ -s "$T/tamper.sh" ] && ok || bad "A3 could not extract is_test_path from bin/test-tamper-scan.sh"
# shellcheck source=/dev/null
. "$T/tamper.sh"
th_is_test_path tests/a.sh  && ok || bad "A3 tests/a.sh must be a test path (a matcher that says no to everything has no parity to prove)"
th_is_test_path src/x.ts    && bad "A3 src/x.ts must not be a test path" || ok
for q in tests/a.sh src/x.ts a/test/b.js foo.test.ts foo.spec.tsx x_test.go test_x.py FooTest.java \
         run-test.sh README.md spec/a.rb __tests__/a.js bin/lib/x.sh Foo.Tests.cs docs/tests.md ""; do
  is_test_path "$q"; A=$?
  th_is_test_path "$q"; B=$?
  [ "$A" = "$B" ] && ok || bad "A3 matcher parity on [$q]: test-tamper-scan rc $A, th_is_test_path rc $B"
done

# ── A4 th_record_add ─────────────────────────────────────────────────────────
R=$(th_record_path "$T/h" proj AB-1)
th_record_add "$R" tests/foo.test.ts tests/foo.ab-1.test.ts && ok || bad "A4 the first add must rc 0"
th_record_add "$R" tests/foo.test.ts tests/foo.ab-1.test.ts && ok || bad "A4 a repeated add must still rc 0"
eq "A4 the same pair twice leaves ONE line" "$(grep -c . "$R")" "1"
eq "A4 the record line format" "$(sed -n 1p "$R")" "REROUTE tests: tests/foo.test.ts -> tests/foo.ab-1.test.ts"
th_record_add "$R" tests/bar-test.sh tests/bar.ab-1-test.sh && ok || bad "A4 a second pair must rc 0"
eq "A4 a second pair appends a second line" "$(grep -c . "$R")" "2"
[ -d "$T/h/state/preplan-files" ] && ok || bad "A4 must mkdir -p the record's parent"
: > "$T/afile"
th_record_add "$T/afile/rec" tests/a.test.ts tests/a.ab-1.test.ts && bad "A4 a file where a dir is needed must rc 1" || ok
[ ! -e "$T/afile/rec" ] && ok || bad "A4 a refused add must leave no partial file"
# The record path itself unwritable — the append has to carry the refusal, not the
# mkdir above it, and this shape refuses for root too (mode bits would not).
mkdir -p "$T/dirrec"
th_record_add "$T/dirrec" tests/a.test.ts tests/a.ab-1.test.ts && bad "A4 a record path that is a directory must rc 1" || ok
if [ "$(id -u)" != 0 ]; then
  mkdir -p "$T/ro"; chmod 000 "$T/ro"
  th_record_add "$T/ro/rec" tests/a.test.ts tests/a.ab-1.test.ts && bad "A4 an unwritable parent must rc 1" || ok
  chmod 755 "$T/ro"
else
  ok   # root ignores mode bits; the file-where-a-dir-is-needed case above pins rc 1 on this runner
fi
th_record_add "$R" tests/x.test.ts "" && bad "A4 an empty target must rc 1" || ok
th_record_add "$R" "" tests/x.ab-1.test.ts && bad "A4 an empty shared path must rc 1" || ok
th_record_add "" tests/x.test.ts tests/x.ab-1.test.ts && bad "A4 an empty record path must rc 1" || ok
eq "A4 a refused add writes no line" "$(grep -c . "$R")" "2"

# ── A5 th_apply ──────────────────────────────────────────────────────────────
mk_list() { printf 'SOURCE: ticket-body\nsrc/a.ts\ntests/foo.test.ts\ntests/foo.test.ts.bak\n' > "$1"; }
mkdir -p "$T/plan"
L="$T/plan/planned-files.txt"; mk_list "$L"
AR="$T/apply-rec"
th_record_add "$AR" tests/foo.test.ts tests/foo.ab-1.test.ts
th_apply "$AR" "$L" && ok || bad "A5 th_apply must rc 0"
printf 'SOURCE: ticket-body\nsrc/a.ts\ntests/foo.ab-1.test.ts\ntests/foo.test.ts.bak\n' > "$T/want"
cmp -s "$L" "$T/want" && ok || bad "A5 th_apply must swap the exact line and leave the SOURCE header and the .bak substring line alone: [$(cat "$L")]"
cp "$L" "$T/after1"
th_apply "$AR" "$L"
cmp -s "$L" "$T/after1" && ok || bad "A5 a second th_apply must be byte-identical"
mk_list "$T/miss"; cp "$T/miss" "$T/miss-orig"
th_apply "$T/nosuch" "$T/miss" && ok || bad "A5 a missing record must rc 0"
cmp -s "$T/miss" "$T/miss-orig" && ok || bad "A5 a missing record must leave the list byte-identical"
: > "$T/emptyrec"
mk_list "$T/miss2"
th_apply "$T/emptyrec" "$T/miss2" && ok || bad "A5 an empty record must rc 0"
cmp -s "$T/miss2" "$T/miss-orig" && ok || bad "A5 an empty record must leave the list byte-identical"
th_apply "$AR" "$T/nosuchlist" && ok || bad "A5 a missing list must rc 0"
[ ! -e "$T/nosuchlist" ] && ok || bad "A5 a missing list must not be created"
printf 'tests/foo.test.ts\ntests/foo.ab-1.test.ts\n' > "$T/both"
th_apply "$AR" "$T/both"
eq "A5 a list already carrying the target is left alone" "$(cat "$T/both")" "$(printf 'tests/foo.test.ts\ntests/foo.ab-1.test.ts')"
# a stray non-REROUTE line in the record is not a pair
printf 'SOURCE: ticket-body\n' > "$T/strayrec"
th_record_add "$T/strayrec" tests/a.test.ts tests/a.ab-1.test.ts
printf 'SOURCE: ticket-body\ntests/a.test.ts\n' > "$T/straylist"
th_apply "$T/strayrec" "$T/straylist"
eq "A5 a non-REROUTE line in the record is never read as a pair" "$(cat "$T/straylist")" "$(printf 'SOURCE: ticket-body\ntests/a.ab-1.test.ts')"
# record and list the same file: pairs are read before the rewrite
cp "$AR" "$T/self"; printf 'tests/foo.test.ts\n' >> "$T/self"
th_apply "$T/self" "$T/self" && ok || bad "A5 record == list must rc 0"
grep -qxF 'tests/foo.ab-1.test.ts' "$T/self" && ok || bad "A5 record == list must still swap the line"
grep -qxF 'REROUTE tests: tests/foo.test.ts -> tests/foo.ab-1.test.ts' "$T/self" && ok || bad "A5 record == list must keep the record line intact"

# ── A5b th_exec_note / th_plan_rule ──────────────────────────────────────────
th_exec_note "$AR" > "$T/note"
grep -qF 'to `tests/foo.ab-1.test.ts`, NOT to `tests/foo.test.ts`' "$T/note" \
  && ok || bad "A5b the note must name target then shared: [$(cat "$T/note")]"
grep -qF 'Do not create or append to `tests/foo.test.ts`.' "$T/note" \
  && ok || bad "A5b the note must forbid the shared file by name"
eq "A5b the note ends with exactly one trailing space (it is concatenated into a prompt)" "$(tail -c 1 "$T/note")" " "
th_record_add "$AR" tests/bar-test.sh tests/bar.ab-1-test.sh
th_exec_note "$AR" > "$T/note2"
grep -qF 'tests/bar.ab-1-test.sh' "$T/note2" && ok || bad "A5b the note must name EVERY pair in the record"
eq "A5b an empty record prints no note"   "$(th_exec_note "$T/emptyrec")" ""
eq "A5b a missing record prints no note"  "$(th_exec_note "$T/nosuch")" ""
eq "A5b no record at all prints no note"  "$(th_exec_note)" ""

th_plan_rule AB-1 > "$T/rule"
grep -qF 'tests/<tier>/<area>.ab-1.test.ts' "$T/rule" && ok || bad "A5b the plan rule must carry the literal example path"
grep -qF 'tests/<area>.ab-1-test.sh' "$T/rule" && ok || bad "A5b the plan rule must carry the shell-suite example path"
grep -qF 'never appended to an existing shared test file' "$T/rule" && ok || bad "A5b the plan rule must carry the rule itself"
grep -qF "List the per-ticket file in the plan's files-to-touch." "$T/rule" && ok || bad "A5b the plan rule must tell the planner to list the file"
grep -qF 'AB-1' "$T/rule" && bad "A5b the plan rule must lower-case the key" || ok
eq "A5b the plan rule ends with exactly one trailing space" "$(tail -c 1 "$T/rule")" " "
th_plan_rule TK-1629 > "$T/rule2"
grep -qF 'tests/<tier>/<area>.TK-1629.test.ts' "$T/rule2" && ok || bad "A5b the plan rule substitutes the real key"
grep -qF '<tier>' "$T/rule2" && ok || bad "A5b <tier>/<area> stay literal placeholders"

# ── A6 th_enabled (the kill switch) ──────────────────────────────────────────
th_enabled "$T/h" && ok || bad "A6 the default is ON"
( export TEST_REROUTE=0; th_enabled "$T/h" ) && bad "A6 TEST_REROUTE=0 must turn it OFF" || ok
( export TEST_REROUTE=1; th_enabled "$T/h" ) && ok || bad "A6 TEST_REROUTE=1 stays ON"
( export TEST_REROUTE=;  th_enabled "$T/h" ) && ok || bad "A6 an empty TEST_REROUTE is not the kill switch"
mkdir -p "$T/h/flags"; : > "$T/h/flags/test-reroute-off"
th_enabled "$T/h" && bad "A6 flags/test-reroute-off must turn it OFF" || ok
rm -f "$T/h/flags/test-reroute-off"
th_enabled "$T/h" && ok || bad "A6 removing the flag turns it back ON"
th_enabled "$T/nosuchharness" && ok || bad "A6 a harness dir with no flags dir is ON"

# ── A7 the two paths ─────────────────────────────────────────────────────────
eq "A7 th_record_path" "$(th_record_path /root/harness cromford BH-583)" \
  "/root/harness/state/preplan-files/cromford-BH-583"
eq "A7 th_relay_path default" "$(th_relay_path cromford BH-583)" \
  "/run/harness/test-reroute-cromford-BH-583"
eq "A7 th_relay_path honours TEST_REROUTE_RELAY_DIR" \
  "$(TEST_REROUTE_RELAY_DIR=$T/relay th_relay_path cromford BH-583)" \
  "$T/relay/test-reroute-cromford-BH-583"

# ── A8 one whole lane pass, in its own process ───────────────────────────────
# The way a sibling child will use this lib end to end: source it, refuse when
# the switch is off, classify the shared file, name the per-ticket file, record
# the reroute, rewrite the pre-plan LIST, hand the executor its note.
cat > "$T/lane.sh" <<'LANE'
set -uo pipefail
. "$1/bin/lib/test-home-lib.sh"
H="$2"; KEY=AB-1; SHARED=tests/level2-unit/foo.test.ts
th_enabled "$H" || { echo "OFF"; exit 0; }
th_is_test_path "$SHARED" || { echo "NOT-A-TEST-PATH"; exit 0; }
th_is_per_ticket "$SHARED" && { echo "ALREADY-PER-TICKET"; exit 0; }
TARGET=$(th_per_ticket_path "$SHARED" "$KEY")
REC=$(th_record_path "$H" proj "$KEY")
th_record_add "$REC" "$SHARED" "$TARGET" || { echo "NOT-REROUTED"; exit 0; }
th_apply "$REC" "$H/planned-files.txt"
th_exec_note "$REC"
LANE
mkdir -p "$T/lane"
printf 'SOURCE: ticket-body\nsrc/a.ts\ntests/level2-unit/foo.test.ts\n' > "$T/lane/planned-files.txt"
LOUT=$(bash "$T/lane.sh" "$DIR" "$T/lane" 2>&1); LRC=$?
eq "A8 the lane exits 0" "$LRC" "0"
eq "A8 the lane rewrote the pre-plan list" "$(cat "$T/lane/planned-files.txt")" \
  "$(printf 'SOURCE: ticket-body\nsrc/a.ts\ntests/level2-unit/foo.ab-1.test.ts')"
[ -f "$T/lane/state/preplan-files/proj-AB-1" ] && ok || bad "A8 the lane wrote no reroute record"
eq "A8 the record holds the pair" "$(cat "$T/lane/state/preplan-files/proj-AB-1")" \
  "REROUTE tests: tests/level2-unit/foo.test.ts -> tests/level2-unit/foo.ab-1.test.ts"
case "$LOUT" in *'tests/level2-unit/foo.ab-1.test.ts`, NOT to `tests/level2-unit/foo.test.ts'*) ok ;;
  *) bad "A8 the lane must print the executor note: [$LOUT]" ;; esac
# the same lane with the kill switch on changes nothing at all
mkdir -p "$T/lane-off"
printf 'SOURCE: ticket-body\ntests/level2-unit/foo.test.ts\n' > "$T/lane-off/planned-files.txt"
cp "$T/lane-off/planned-files.txt" "$T/lane-off-orig"
OFFOUT=$(TEST_REROUTE=0 bash "$T/lane.sh" "$DIR" "$T/lane-off" 2>&1)
eq "A8 TEST_REROUTE=0 stops the lane" "$OFFOUT" "OFF"
cmp -s "$T/lane-off/planned-files.txt" "$T/lane-off-orig" && ok || bad "A8 a switched-off lane must not touch the list"
[ ! -e "$T/lane-off/state/preplan-files/proj-AB-1" ] && ok || bad "A8 a switched-off lane must write no record"

echo "test-home-lib: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
