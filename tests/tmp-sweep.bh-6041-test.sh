#!/bin/bash
# tests/tmp-sweep.bh-6041-test.sh — BH-6041: the /tmp sweep also removes the
# builder, reviewer and lead-review leftovers that no pattern matched: bh<N>
# with no dash (/tmp/bh5775, 1.1 GB on box-small), pr<N>, the
# lead-review worker's own lr<pid>-<id> dir, and a rules-pack-snap.* snapshot
# a SIGKILLed worker left. Every keep-rule still holds.
#
# The shipped bin/tmp-sweep.sh is installed with its closure into a scratch
# harness and DRIVEN against a fixture /tmp under $T (TMP_SWEEP_ROOT), with a
# fixed clock (TMP_SWEEP_NOW) and a fixture /proc (TMP_SWEEP_PROC) for the held
# case. Cases:
#   S1  the default pattern list holds bh[0-9]*, pr[0-9]*, lr[0-9]*,
#       rules-pack-snap.* (in the script and in the registry row);
#   S2  rv4624, bh5775, pr5773, lr123-r4, rules-pack-snap.AbC at 7 h are
#       removed (red on main for all but rv4624);
#   S3  a 7 h rv8 named by a fake /proc/<pid>/cwd is kept, skipped_held=1;
#   S4  the negative list is kept: prisma-engines, pre-commit-abc, bhx, lrx,
#       prx, rules-pack (bare), a 179 min old bh5775, a symlink bh1 -> target;
#   S5  MIN_AGE_MIN=360 keeps a 5 h old bh5775.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/tmp-sweep.bh-6041-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset MIN_AGE_MIN TMP_ALERT_PCT TMP_SWEEP_SCAN_TIMEOUT_S TMP_SWEEP_RUN_DEADLINE_S TMP_SWEEP_PATTERNS \
      TMP_SWEEP_ROOT TMP_SWEEP_PROC TMP_SWEEP_NOW TMP_SWEEP_STOPGAP_FILE TMP_SWEEP_CLAIMS 2>/dev/null || true

scratch_install_closure bin/tmp-sweep.sh "$T/h" >/dev/null || { echo "FAIL: cannot install bin/tmp-sweep.sh's closure"; exit 1; }
mkdir -p "$T/h/logs" "$T/h/flags" "$T/h/state" "$T/h/env" "$T/fx/cron.d" "$T/fakebin"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/lane-alert.sh"; chmod +x "$T/h/bin/lane-alert.sh"
cat > "$T/fakebin/df" <<'SH'
#!/bin/bash
printf 'Filesystem     1024-blocks     Used Available Capacity Mounted on\ntmpfs 4194304 2000000 2097152 48%% /tmp\n'
SH
chmod +x "$T/fakebin/df"

NOW=1790000000
H7=$((NOW - 7 * 3600))
FX="$T/fx/tmp"
FP="$T/fx/proc"
LOG="$T/h/logs/tmp-sweep.log"

age() { find "$1" -exec touch -h -d "@$2" {} + 2>/dev/null; }
reset_fx() { scratch_rm "$FX"; scratch_rm "$FP"; mkdir -p "$FX" "$FP"; rm -f "$LOG"; }
mkold() { mkdir -p "$FX/$1/d"; echo x > "$FX/$1/d/f"; age "$FX/$1" "${2:-$H7}"; }
run() {
  timeout 120 env PATH="$T/fakebin:$PATH" HARNESS_ROOT="$T/h" HARNESS="$T/h" HOME="$T" \
    TMP_SWEEP_ROOT="$FX" TMP_SWEEP_PROC="$FP" TMP_SWEEP_NOW="$NOW" TMP_SWEEP_CLAIMS="$T/claims" \
    TMP_SWEEP_STOPGAP_FILE="$T/fx/cron.d/tmp-sweep" "$@" bash "$T/h/bin/tmp-sweep.sh" >/dev/null 2>&1
}
field() { grep -E ' tmp-sweep removed=' "$LOG" 2>/dev/null | tail -1 | grep -oE "(^| )$1=[^ ]*" | cut -d= -f2; }

# ══ S1 the default list ═════════════════════════════════════════════════════
def=$(sed -n 's/^PATTERNS="\${TMP_SWEEP_PATTERNS:-\(.*\)}"$/\1/p' "$SRC/bin/tmp-sweep.sh")
[ -n "$def" ] && ok || bad "S1 the PATTERNS default line was not found in bin/tmp-sweep.sh"
reg=$(jq -r '.knobs[]|select(.env=="TMP_SWEEP_PATTERNS").default' "$SRC/catalog/lanes.d/tmp-sweep.json")
for g in 'bh[0-9]*' 'pr[0-9]*' 'lr[0-9]*' 'rules-pack-snap.*'; do
  [[ " $def " == *" $g "* ]] && ok || bad "S1 the script default holds $g ('$def')"
  [[ " $reg " == *" $g "* ]] && ok || bad "S1 the registry default holds $g ('$reg')"
done
[ "$def" = "$reg" ] && ok || bad "S1 the script and registry defaults are the same list"

# ══ S2 the ticket's names at 7 h are removed ════════════════════════════════
reset_fx
POS="rv4624 bh5775 pr5773 lr123-r4 rules-pack-snap.AbC"
for n in $POS; do mkold "$n"; done
run
for n in $POS; do
  [ ! -e "$FX/$n" ] && ok || bad "S2 the 7 h old $n is removed ($(cat "$LOG" 2>/dev/null))"
done
[ "$(field removed)" = 5 ] && ok || bad "S2 removed=5 ($(cat "$LOG" 2>/dev/null))"

# ══ S3 held by a process cwd ════════════════════════════════════════════════
reset_fx; mkold rv8; mkold bh5775
mkdir -p "$FP/4242"; ln -s "$FX/rv8/d" "$FP/4242/cwd"
run
[ -d "$FX/rv8" ] && ok || bad "S3 rv8, a live process's cwd, is kept"
[ "$(field skipped_held)" = 1 ] && ok || bad "S3 skipped_held=1 ($(cat "$LOG" 2>/dev/null))"
[ ! -e "$FX/bh5775" ] && ok || bad "S3 the unheld bh5775 beside it is removed"

# ══ S4 the negative list ════════════════════════════════════════════════════
reset_fx
NEG="prisma-engines pre-commit-abc bhx lrx prx rules-pack lr pr bh"
for n in $NEG; do mkold "$n"; done
mkold bh5775 $((NOW - 179 * 60))
mkdir -p "$T/fx/target"; echo t > "$T/fx/target/f"; age "$T/fx/target" "$H7"
ln -s "$T/fx/target" "$FX/bh1"; touch -h -d "@$H7" "$FX/bh1"
run
for n in $NEG; do
  [ -e "$FX/$n" ] && ok || bad "S4 $n is not a sweep name and is kept"
done
[ -d "$FX/bh5775" ] && ok || bad "S4 a 179 min old bh5775 is kept (fresh)"
[ -L "$FX/bh1" ] && [ -f "$T/fx/target/f" ] && ok || bad "S4 the symlink bh1 and its target are kept"
[ "$(field removed)" = 0 ] && ok || bad "S4 removed=0 ($(cat "$LOG" 2>/dev/null))"

# ══ S5 the age knob ═════════════════════════════════════════════════════════
reset_fx; mkold bh5775 $((NOW - 5 * 3600))
run MIN_AGE_MIN=360
[ -d "$FX/bh5775" ] && [ "$(field min_age_min)" = 360 ] && ok || bad "S5 MIN_AGE_MIN=360 keeps a 5 h bh5775 ($(cat "$LOG" 2>/dev/null))"
run
[ ! -e "$FX/bh5775" ] && ok || bad "S5 at the default 180 the same 5 h bh5775 is removed"

echo "tmp-sweep.bh-6041: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
