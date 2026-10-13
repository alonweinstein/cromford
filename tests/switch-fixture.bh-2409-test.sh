#!/bin/bash
# tests/switch-fixture.bh-2409-test.sh — tests/lib/switch-fixture.sh and the
# tests/switch-ratchet.d/*.drop floor (BH-2426, the contract slice of BH-2409).
#
# What is proved here:
#   F1 a fleet row `switch.x-off=1` answers ON through the real lane_switch;
#   F2 a row 0 beats flags/x-off;
#   F3 no row + flags/x-off answers ON (legacy parity);
#   F4 two reads in one pinned tick cost ONE GET /api/settings (swf_gets);
#   F5 swf_setup refuses a root outside SCRATCH and creates nothing;
#   F6 swf_install copies a repo file keeping its exec bit, refuses `..`;
#   F7 a registry-seed row answers nothing;
#   Rd1 the ratchet, run as shipped (strict mode) over a HERMETIC tree at its
#      floor (tests/lib/switch-ratchet-tree.sh), is green unchanged. Whether
#      the LIVE tree passes is switch-ratchet's own job, never re-run here;
#   Rd2 three bare reads removed is red (below the floor) until a .drop of 3;
#   Rd3/Rd4 a .drop that is not one integer is red and names the file.
# Run from anywhere: tests/switch-fixture.bh-2409-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/switch-fixture.sh" || exit 1
. "$(dirname "$0")/lib/switch-ratchet-tree.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

# ask <name> — one read in a cold child shell through the real lane_switch.
ask() {
  bash -c '
    . "$HARNESS/bin/lib/lane-switch.sh" || exit 9
    lane_switch "$1"; echo "rc=$? src=${LANE_SWITCH_SRC:-unset}"' _ "$1" 2>/dev/null
}

if ! swf_setup "$T/h"; then
  bad "swf_setup $T/h failed"
  echo "switch-fixture.bh-2409: $PASS passed, $FAIL failed"; exit 1
fi
eq "setup pins JOBS_BOX" "${JOBS_BOX:-}" "hub-1"
eq "setup pins LANE_GATE_NOW" "${LANE_GATE_NOW:-}" "1758300000"
eq "setup points HARNESS at the root" "${HARNESS:-}" "$T/h"

# F1 — fleet row on, no file.
swf_rows switch.x-off=1
eq "F1 fleet row 1" "$(ask x-off)" "rc=0 src=fleet-row"

# F2 — row 0 beats the file.
swf_rows switch.x-off=0; swf_flag x-off
eq "F2 row 0 beats the file" "$(ask x-off)" "rc=1 src=fleet-row"

# F3 — no row: the file answers.
swf_rows
eq "F3 no row, file" "$(ask x-off)" "rc=0 src=legacy-file"
rm -f "$T/h/flags/x-off"

# F4 — two reads, one GET.
: > "$CALLS"; swf_rows switch.x-off=1
ask x-off >/dev/null; ask x-off >/dev/null
eq "F4 two reads cost one GET" "$(swf_gets)" "1"
rm -f "$CALLS"
eq "F4 swf_gets with no calls file" "$(swf_gets)" "0"

# F5 — the guard.
NS="/tmp/not-scratch-$$"
swf_setup "$NS" 2>/dev/null && bad "F5 swf_setup outside SCRATCH must fail" || ok
[ ! -e "$NS" ] && ok || bad "F5 swf_setup created $NS outside SCRATCH (left in place for inspection)"
eq "F5 the refusal left SWF_ROOT alone" "$SWF_ROOT" "$T/h"
swf_flag ../x 2>/dev/null && bad "F5 swf_flag must refuse a path" || ok

# F6 — swf_install.
swf_install bin/dora-digest.sh
[ -x "$T/h/bin/dora-digest.sh" ] && ok || bad "F6 swf_install bin/dora-digest.sh did not land executable"
swf_install ../x 2>/dev/null && bad "F6 swf_install ../x must be refused" || ok
swf_install /etc/passwd 2>/dev/null && bad "F6 an absolute path must be refused" || ok
swf_install bin/no-such-file.sh 2>/dev/null && bad "F6 a missing file must be refused" || ok

# F7 — a seed row answers nothing.
swf_rows seed:switch.x-off=1
eq "F7 a registry-seed row answers nothing" "$(ask x-off)" "rc=1 src=legacy-file"
swf_rows 'switch.y-off=a=b'
eq "F7 the value keeps everything after the first =" "$(jq -r '.[0].value' "$ROWS_FILE")" "a=b"

# Rd — the ratchet's .drop floor, over a hermetic tree of five single-read
# files that sits AT its floor. t/u/g.drop below stack on the tree's own drop.
RT="$T/rt"
srt_tree "$RT" 5 || bad "Rd0 srt_tree could not build the fixture tree"
ratchet() { srt_run "$RT"; }

out=$(ratchet); rc=$?
eq "Rd1 the tree at its floor is green" "$rc" "0"
[ "$rc" -eq 0 ] || echo "$out"

# The regex is the suite's own, never retyped here.
BARE_RE=$(sed -n "s/^BARE_RE='\(.*\)'\$/\1/p" "$RT/tests/switch-ratchet.bh-2320-test.sh")
[ -n "$BARE_RE" ] && ok || bad "Rd2 could not read BARE_RE out of the ratchet suite"
# The first three lines under bin/ that each carry exactly one bare read,
# deleted bottom-up inside each file so the line numbers stay true.
PICK=$(grep -rnoE "$BARE_RE" "$RT/bin" | cut -d: -f1,2 | uniq -c | awk '$1==1{print $2}' | head -3)
eq "Rd2 three single-read lines found" "$(printf '%s\n' "$PICK" | grep -c .)" "3"
BEFORE=$(grep -rhoE "$BARE_RE" "$RT/bin" "$RT/fly" | wc -l | tr -d ' ')
printf '%s\n' "$PICK" | sort -t: -k1,1 -k2,2nr | while IFS=: read -r f ln; do sed -i "${ln}d" "$f"; done
AFTER=$(grep -rhoE "$BARE_RE" "$RT/bin" "$RT/fly" | wc -l | tr -d ' ')
eq "Rd2 exactly three bare reads removed" "$((BEFORE - AFTER))" "3"
out=$(ratchet); rc=$?
eq "Rd2 three fewer reads and no .drop is below the floor" "$rc" "1"
printf '# BH-test: three readers converted\n3\n' > "$RT/tests/switch-ratchet.d/t.drop"
out=$(ratchet); rc=$?
eq "Rd2 a .drop of 3 lowers the floor by 3" "$rc" "0"
[ "$rc" -eq 0 ] || echo "$out"
printf '2\n' > "$RT/tests/switch-ratchet.d/t.drop"
out=$(ratchet); rc=$?
eq "Rd2 a .drop of 2 leaves the floor one too high" "$rc" "1"
printf '1\n' > "$RT/tests/switch-ratchet.d/t.drop"; printf '02\n' > "$RT/tests/switch-ratchet.d/u.drop"
out=$(ratchet); rc=$?
eq "Rd2 two .drop files sum (1 + 02)" "$rc" "0"
rm -f "$RT/tests/switch-ratchet.d/u.drop"

# Rd3/Rd4 — garbage. t.drop holds the right 3, so only g.drop can turn it red.
printf '3\n' > "$RT/tests/switch-ratchet.d/t.drop"
for g in 'three' '1\n2' '-3' '3x' '# only a comment'; do
  printf -- "$g\n" > "$RT/tests/switch-ratchet.d/g.drop"
  out=$(ratchet); rc=$?
  eq "Rd3 .drop '$g' fails" "$rc" "1"
  case "$out" in *g.drop*) ok ;; *) bad "Rd3 .drop '$g': the failure must name g.drop, got: $out" ;; esac
done
rm -f "$RT/tests/switch-ratchet.d/g.drop"

echo "switch-fixture.bh-2409: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
