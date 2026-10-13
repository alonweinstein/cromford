#!/bin/bash
# tests/mergify-stuck-batch.bh-2611-test.sh — BH-2611: the two mergify-stuck-batch
# suites stay green whatever the wall clock says.
#
# The MERGIFY_BATCH_STUCK once-per-day key is `$((now / 86400))`
# (bin/lib/mc/queue.sh, mc_mergify_stuck_pass), and both suites offset their CLOCK
# ticks from a NOW taken from date(1). With NOW on the real clock, a start in
# [23:40:00, 23:49:59] UTC put midnight between the NOW+600 and NOW+1200 ticks,
# so bh-1790 §6 and bh-1887 §2b saw a second alert. This suite runs both under a
# `date -u +%s` shim pinned inside that window.
#
#   1. the shim is live: `date -u +%s` on the shimmed PATH prints the pinned epoch.
#   2. tests/mergify-stuck-batch.bh-1790-test.sh exits 0 at 23:40:00, 23:45:00, 23:49:59.
#   3. tests/mergify-stuck-batch.bh-1887-test.sh exits 0 at the same three instants.
# Run from anywhere: tests/mergify-stuck-batch.bh-2611-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

REAL_DATE=$(command -v date) || { echo "date missing — skipping"; exit 0; }
mkdir -p "$T/bin"
D=$(( $("$REAL_DATE" -u +%s) / 86400 * 86400 ))   # 00:00:00Z today

# write_shim EPOCH: `date -u +%s` prints EPOCH; every other call is the real date.
write_shim() {
  printf '#!/bin/bash\nif [ "$*" = "-u +%%s" ]; then echo %s; else exec %s "$@"; fi\n' \
    "$1" "$REAL_DATE" > "$T/bin/date"
  chmod +x "$T/bin/date"
}

# --- 1: the shim is live ---------------------------------------------------------
write_shim $((D - 900))
got=$(PATH="$T/bin:$PATH" date -u +%s)
[ "$got" = "$((D - 900))" ] && ok || bad "1: shimmed date -u +%s printed '$got', want $((D - 900))"

# --- 2/3: both suites at the edges of the failing window and the CI incident time -
for at in 1200:23:40:00 900:23:45:00 601:23:49:59; do
  off=${at%%:*}; label=${at#*:}
  write_shim $((D - off))
  for s in bh-1790 bh-1887; do
    out="$T/$s-${off}.out"
    PATH="$T/bin:$PATH" HARNESS_TEST_SANDBOX=1 bash "$DIR/tests/mergify-stuck-batch.$s-test.sh" > "$out" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then ok; else
      bad "$s at ${label}Z exited $rc"
      grep '^FAIL:' "$out" | cut -c1-200
    fi
  done
done

echo "mergify-stuck-batch.bh-2611: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
