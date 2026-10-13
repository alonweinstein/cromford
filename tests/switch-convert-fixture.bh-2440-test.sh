#!/bin/bash
# tests/switch-convert-fixture.bh-2440-test.sh — the contract every BH-2408
# slice imports (BH-2440): tests/lib/switch-convert-fixture.sh and the
# per-ticket floor of tests/switch-ratchet.bh-2320-test.sh.
#
# What is proved here:
#   F1 sc_harness builds the tree, copies the two libs, the rendered registry
#      and the stub jobs client;
#   F2 sc_rows switch.dora-digest-off=1 makes `lane_switch dora-digest-off`
#      rc 0 from the fleet row there, and no rows leaves it to the legacy file;
#   F3 the stub was the one asked (GET /api/settings in $CALLS);
#   F4 sc_seed_cache answers in an outage, and without it nothing does;
#   F5 sc_ignored_lines counts the `flags/<name> ignored` line, 0 with no log;
#   F6 sc_trace writes a line-numbered bash -x trace (as root too) and
#      sc_trace_past reads it: rc 1 when the script stopped at the line, 0 when
#      it ran past, 2 with no trace;
#   F7 sc_stub_path's gh/curl/claude record and fail;
#   F8 sc_rows refuses an argument with no `=`;
#   F9 the fixture sourced alone, as root beside a live harness, builds its own
#      scratch tree with JOBS_BOX=hub-1, and sourced after scratch.sh keeps $T;
#   R3-R9 the ratchet run as shipped (strict mode) on a HERMETIC tree at its
#      floor (tests/lib/switch-ratchet-tree.sh) with converted bare reads:
#      effective floor = FLOOR - sum(tests/switch-ratchet.d/*.drop), and a
#      .drop file that is not a non-negative integer is a FAIL. The live tree
#      is switch-ratchet's own job and is never re-run here.
# Run from anywhere: tests/switch-convert-fixture.bh-2440-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
T_BEFORE=$T
. "$(dirname "$0")/lib/switch-convert-fixture.sh" || exit 1
. "$(dirname "$0")/lib/switch-ratchet-tree.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

NOW=1758300000
# ask <name> — one lane_switch read in a cold child shell against $T/h.
ask() {
  env HARNESS="$T/h" LANE_GATE_NOW="$NOW" UNREACHABLE="${UNREACHABLE:-}" \
      bash -c '
        set -uo pipefail
        . "$HARNESS/bin/lib/lane-switch.sh" || exit 9
        lane_switch "$1"; rc=$?
        echo "rc=$rc src=${LANE_SWITCH_SRC:-unset}"' _ "$1" 2>/dev/null
}
fresh() {
  rm -rf "$T/h/state/lane-gate" "$T/h/logs/lane-gate.log"
  rm -f "$T/h/state/settings-cache.json" "$T/h/flags"/*
  : > "$CALLS"; UNREACHABLE=""
}

# F9b — sourced after scratch.sh, the fixture keeps the suite's tree.
eq "F9b the fixture kept the caller's \$T" "$T" "$T_BEFORE"
eq "F9b JOBS_BOX default" "$JOBS_BOX" "hub-1"

# F1 — the tree.
sc_harness "$T/h"; rc=$?
eq "F1 sc_harness rc" "$rc" "0"
for d in bin/lib flags state logs catalog/switches.d; do
  [ -d "$T/h/$d" ] && ok || bad "F1 $d missing"
done
for f in bin/lib/lane-gate.sh bin/lib/lane-switch.sh catalog/lanes.json bin/jobs-client.sh; do
  [ -s "$T/h/$f" ] && ok || bad "F1 $f missing or empty"
done
eq "F1 SC_ROOT" "${SC_ROOT:-}" "$T/h"

# F2 — the ticket's named check, and its mutation pin.
fresh; sc_rows switch.dora-digest-off=1
eq "F2 sc_rows switch.dora-digest-off=1" "$(ask dora-digest-off)" "rc=0 src=fleet-row"
# F3 — the stub answered.
grep -qx 'GET /api/settings' "$CALLS" && ok || bad "F3 \$CALLS holds no GET /api/settings: $(cat "$CALLS")"
fresh; sc_rows
eq "F2 no rows = legacy, off" "$(ask dora-digest-off)" "rc=1 src=legacy-file"
eq "F2 empty sc_rows writes []" "$(cat "$ROWS_FILE")" "[]"

# F4 — outage: only the seeded cache answers.
fresh; sc_rows switch.x-off=1; sc_seed_cache switch.x-off=1; rm -f "$ROWS_FILE"; UNREACHABLE=1
eq "F4 seeded cache answers in an outage" "$(ask x-off)" "rc=0 src=fleet-row"
eq "F4 the stub was asked and refused" "$(grep -c 'GET /api/settings' "$CALLS")" "1"
fresh; UNREACHABLE=1
eq "F4 no seed, outage = legacy" "$(ask x-off)" "rc=1 src=legacy-file"
( unset SC_ROOT; sc_seed_cache switch.x-off=1 ) 2>/dev/null && bad "F4 sc_seed_cache without SC_ROOT must fail" || ok

# F5 — the ignored-file line.
fresh
eq "F5 no log = 0" "$(sc_ignored_lines "$T/h" x-off)" "0"
sc_rows switch.x-off=0; touch "$T/h/flags/x-off"
eq "F5 row 0 beats the file" "$(ask x-off)" "rc=1 src=fleet-row"
eq "F5 one ignored line" "$(sc_ignored_lines "$T/h" x-off)" "1"
eq "F5 another name counts 0" "$(sc_ignored_lines "$T/h" y-off)" "0"

# F6 — a real bash -x trace.
printf 'echo one\nexit 0\necho three\n' > "$T/stop.sh"
printf 'echo one\ntrue\necho three\n' > "$T/run.sh"
sc_trace "$T/stop.trace" "$T/stop.sh" >/dev/null; eq "F6 sc_trace returns the script's rc" "$?" "0"
sc_trace "$T/run.trace" "$T/run.sh" >/dev/null
printf 'exit 3\n' > "$T/three.sh"
sc_trace "$T/three.trace" "$T/three.sh"; eq "F6 sc_trace passes rc 3 through" "$?" "3"
grep -qx '+2: exit 0' "$T/stop.trace" && ok || bad "F6 the trace carries line numbers: $(cat "$T/stop.trace")"
sc_trace_past "$T/stop.trace" 2; eq "F6 stopped at line 2" "$?" "1"
sc_trace_past "$T/run.trace" 2; eq "F6 ran past line 2" "$?" "0"
sc_trace_past "$T/nope.trace" 2 2>/dev/null; eq "F6 missing trace" "$?" "2"
: > "$T/empty.trace"
sc_trace_past "$T/empty.trace" 2 2>/dev/null; eq "F6 empty trace" "$?" "2"
sc_trace_past "$T/run.trace" two 2>/dev/null; eq "F6 non-integer line" "$?" "2"

# F7 — record-and-fail stubs, in a subshell so this suite's PATH stays real.
(
  sc_stub_path "$T/stubs"
  gh pr list >/dev/null 2>&1; echo "gh=$?"
  curl -s https://example.invalid >/dev/null 2>&1; echo "curl=$?"
  claude -p hi >/dev/null 2>&1; echo "claude=$?"
  command -v gh
) > "$T/f7.out"
eq "F7 stubs exit 1" "$(head -3 "$T/f7.out" | tr '\n' ' ')" "gh=1 curl=1 claude=1 "
eq "F7 gh resolves to the stub" "$(sed -n 4p "$T/f7.out")" "$T/stubs/gh"
eq "F7 calls.log" "$(cat "$T/stubs/calls.log" 2>/dev/null | tr '\n' '|')" "gh pr list|curl -s https://example.invalid|claude -p hi|"

# F8 — a typo is refused, never an empty table.
sc_rows switch.x-off=1
sc_rows bogus 2>/dev/null && bad "F8 sc_rows bogus must fail" || ok
eq "F8 a refused call leaves the table alone" "$(jq -r '.[0].key' "$ROWS_FILE")" "switch.x-off"

# F9 — sourced alone, as root beside a live harness, with no sandbox set.
out=$(env -u HARNESS_TEST_SANDBOX -u JOBS_BOX -u ROWS_FILE -u CALLS DIR= \
  bash -c '. "$1" || exit 9; [ -d "$T" ] || exit 8; echo "$JOBS_BOX $HARNESS_TEST_SANDBOX $ROWS_FILE"' \
  _ "$DIR/tests/lib/switch-convert-fixture.sh" 2>&1); rc=$?
eq "F9 fixture alone rc" "$rc" "0"
case "$out" in "hub-1 1 "*/rows.json) ok ;; *) bad "F9 defaults: got '$out'" ;; esac

# --- R: the ratchet as shipped, on a scratch copy -----------------------------
BARE_RE='\[ -[ef] [^]]*flags/[a-z0-9-]+-(off|disabled)'
bare() { grep -rhoE "$BARE_RE" "$1/bin" "$1/fly" 2>/dev/null | wc -l | tr -d ' '; }
# Twelve single-read files, so two conversions and the '08' drop below still
# leave the effective floor positive; D0 is the tree's own drop.
srt_tree "$T/r" 12 || bad "R0 srt_tree could not build the fixture tree"
RD="$T/r/tests/switch-ratchet.d"
D0=$(grep -vE '^[[:space:]]*(#|$)' "$RD/base.drop")
ratchet() { srt_run "$T/r" > "$T/r.out"; }

ratchet; eq "R9 the tree at its floor rc" "$?" "0"

# convert_one — turn the first bare read of the copy into a lane_switch read (a
# name with a registry file). Found, not named: the BH-2408 slices convert the
# reads this suite once named (lane-reaper-off went in BH-2441).
convert_one() {
  local f
  f=$(grep -rlE "$BARE_RE" "$T/r/bin" | sort | head -1)
  [ -n "$f" ] || return 1
  sed -i -E '0,/\[ -[ef] [^]]*flags\/[a-z0-9-]+-(off|disabled)[^]]*\]/s//lane_switch dora-digest-off/' "$f"
}
B0=$(bare "$T/r")
convert_one
eq "R convert one read" "$(bare "$T/r")" "$((B0 - 1))"

# R3 — BH-TEST.drop = 1: green.
printf '1\n' > "$RD/BH-TEST.drop"
ratchet; rc=$?; eq "R3 one converted read + .drop 1" "$rc" "0"
[ "$rc" = 0 ] || sed 's/^/  | /' "$T/r.out"
# R4 — the same tree without it: red on R2.
rm -f "$RD/BH-TEST.drop"
ratchet; rc=$?
[ "$rc" -ne 0 ] && ok || bad "R4 converted read without .drop must be red"
grep -q 'FAIL: R2' "$T/r.out" && ok || bad "R4 the failure must name R2: $(cat "$T/r.out")"
# R5 — `x`: red on R0.
printf 'x\n' > "$RD/BH-TEST.drop"
ratchet; rc=$?
[ "$rc" -ne 0 ] && ok || bad "R5 .drop 'x' must be red"
grep -q 'FAIL: R0' "$T/r.out" && ok || bad "R5 the failure must name R0: $(cat "$T/r.out")"
# R6 — `-1`: red on R0.
printf -- '-1\n' > "$RD/BH-TEST.drop"
ratchet; rc=$?
[ "$rc" -ne 0 ] && grep -q 'FAIL: R0' "$T/r.out" && ok || bad "R6 .drop '-1' must be red on R0 (rc $rc)"
# R7 — empty: red on R0.
: > "$RD/BH-TEST.drop"
ratchet; rc=$?
[ "$rc" -ne 0 ] && grep -q 'FAIL: R0' "$T/r.out" && ok || bad "R7 empty .drop must be red on R0 (rc $rc)"
# R8 — two files, 0 then 1: the SUM, not the first file.
rm -f "$RD/BH-TEST.drop"
printf '0\n' > "$RD/BH-A.drop"; printf '1\r\n' > "$RD/BH-B.drop"
ratchet; eq "R8 files 0 + 1 (CRLF)" "$?" "0"
# R8b — a second converted read, 1 + 1.
convert_one
eq "R8b convert a second read" "$(bare "$T/r")" "$((B0 - 2))"
printf '1\n' > "$RD/BH-A.drop"
ratchet; eq "R8b files 1 + 1" "$?" "0"
# R8c — 08 is eight, not a bad octal (1 + 8: R1 names floor 93 less the
# tree's own drops D0), and 0102 is 102, not octal 66, so 1 + 0102 is a sum
# over FLOOR: R0. D0 is the sum of the real .drop files copied in above.
printf '1\n' > "$RD/BH-A.drop"; printf '08\n' > "$RD/BH-B.drop"
ratchet; rc=$?
[ "$rc" -ne 0 ] && grep -qF "effective floor $((SRT_FLOOR - D0 - 9)) (FLOOR $SRT_FLOOR less $((9 + D0)) dropped)" "$T/r.out" && ! grep -q 'FAIL: R0' "$T/r.out" && ok \
  || bad "R8c '08' must parse as 8 (floor $((SRT_FLOOR - D0 - 9)), red but not on R0): $(cat "$T/r.out")"
printf '0102\n' > "$RD/BH-B.drop"
ratchet; rc=$?
[ "$rc" -ne 0 ] && grep -q "FAIL: R0 the .drop files sum to $((103 + D0))" "$T/r.out" && ok \
  || bad "R8c 1 + 0102 must be red on R0 as a sum of $((103 + D0)) (rc $rc): $(cat "$T/r.out")"

echo "switch-convert-fixture.bh-2440: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
