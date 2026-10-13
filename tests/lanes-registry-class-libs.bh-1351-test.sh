#!/bin/bash
# tests/lanes-registry-class-libs.bh-1351-test.sh — §7 of the lanes registry
# suite really goes RED on a knob hidden in a wake class library.
#
# WHY. tests/lanes-registry-test.sh §7 only ever read a lane's own `script`.
# bin/wake-loop.sh sources bin/lib/wake-class-*.sh, so WAKE_PROMPT_EVAL_COOLDOWN_S
# sat unregistered for a release and the suite stayed green — the guard reported
# that it existed while a metered lane's window was invisible on the settings
# page. BH-1351 widened the scan set; this file is the proof that the widened
# check can FAIL, because a check nobody has seen fail is a check nobody has.
# It plants a bogus class lib in a COPY of the tree and runs the real suite.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lanes-registry-class-libs.bh-1351-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# --- a copy of the tracked tree, plus the untracked fleet.conf §9/§14 read ---
mkdir -p "$T/repo"
git -C "$DIR" ls-files -z | tar -C "$DIR" --null -T - -cf - | tar -C "$T/repo" -xf - \
  || { echo "FAIL: could not copy the tracked tree"; exit 1; }
[ -f "$DIR/fleet.conf" ] && cp "$DIR/fleet.conf" "$T/repo/fleet.conf"

# --- plant a class lib that reads one bogus knob and one class-local ---------
cat > "$T/repo/bin/lib/wake-class-zz-bogus.sh" <<'SH'
#!/bin/bash
# planted by tests/lanes-registry-class-libs.bh-1351-test.sh
# shellcheck shell=bash
WC_ZZ_LOCAL=0
wc_zz_bogus_row() {
  WC_ZZ_LOCAL=1
  return 0
}
wc_zz_bogus_dispatch() {
  local x y
  x="${WC_ZZ_LOCAL:-0}"
  y="${WAKE_ZZ_BOGUS_S:-5}"
  echo "$x $y" > /dev/null
  WC_ZZ_LOCAL=0
  return 0
}
SH

OUT="$T/out.txt"
( cd "$T/repo" && HARNESS_TEST_SANDBOX=1 bash "$T/repo/tests/lanes-registry-test.sh" ) > "$OUT" 2>&1
RC=$?

# R1 the suite fails at all
[ "$RC" -ne 0 ] && ok || bad "R1 a bogus knob in a class lib must fail tests/lanes-registry-test.sh (rc $RC)"

# R2 it fails on §7, naming the planted knob under the wake-loop lane
LINE=$(grep -m1 '7 wired lanes read env knobs the registry does not carry' "$OUT")
case "$LINE" in
  *wake-loop/WAKE_ZZ_BOGUS_S*) ok ;;
  *) bad "R2 §7 must name wake-loop/WAKE_ZZ_BOGUS_S (line: ${LINE:-<no §7 failure at all>})" ;;
esac

# R3 a class-LOCAL stays a local: concatenating the libs into one scan buffer is
# what keeps WC_ZZ_LOCAL=0 visible to the assignment check.
case "$LINE" in
  *WC_ZZ_LOCAL*) bad "R3 §7 reported a class-local as a missing knob (line: $LINE)" ;;
  *) ok ;;
esac

# R4 the three knobs BH-1351 registered are really read — no phantom-knob
# failure from §6 while the planted lib is in place.
grep -q '6 registered knobs nothing reads' "$OUT" \
  && bad "R4 §6 reported a phantom knob: $(grep -m1 '6 registered knobs nothing reads' "$OUT")" || ok

# ---------------------------------------------------------------------------
echo "lanes-registry-class-libs.bh-1351-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
