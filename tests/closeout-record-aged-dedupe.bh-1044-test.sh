#!/bin/bash
# tests/closeout-record-aged-dedupe.bh-1044-test.sh — closeout_record_aged's
# "the file is a set keyed on the build dir" contract, under the exact shell
# options its only caller runs with.
#
# THE BUG THIS PINS (BH-1044 review, found on the hub's 45 MB tsv). The dedupe
# read was `cut -f2 "$tsv" | grep -qxF "$dir" && exit 0`. grep -q exits at the
# first match; when that match is not inside the last ~64 KB of the file, cut is
# still writing and dies of SIGPIPE. bin/pipeline-health.sh runs
# `set -uo pipefail` and the recording subshell inherits it, so the pipeline
# returned 141, the `&& exit 0` was NOT taken, and the row was appended again.
# Every ten minutes, for every dir recorded near the top of the file: ~800 aged
# dirs x 144 ticks a day x ~100 bytes is the ~11 MB/day the audit measured.
# Under 64 KB the same code is green, which is why no fixture ever caught it.
#
# So every case below is driven with `set -o pipefail` ON and against a file
# BIGGER than the pipe buffer, with the target row first — the exact shape that
# was silently re-appending. A fix that answers only the small-file case leaves
# this red.
#
# Run from anywhere: tests/closeout-record-aged-dedupe.bh-1044-test.sh
#   (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/state" "$T/locks"
TSV="$T/state/closeout-aged-out.tsv"
LOCK="$T/locks/closeout-aged-out.lock"
PIPEBUF=65536

# The caller's shape: pipeline-health.sh sources the lib under `set -uo pipefail`
# and calls the function in that shell. record() reproduces exactly that.
record() { # record <dir> <reason>
  ( set -uo pipefail
    # shellcheck source=bin/lib/closeout-terminal.sh
    . "$DIR/bin/lib/closeout-terminal.sh" || exit 9
    closeout_record_aged "$TSV" "$LOCK" "x-os" "$1" "PR_CREATED https://x.example/pull/1" "$2" )
}
rows()    { wc -l < "$TSV" | tr -d ' '; }
dirrows() { grep -cxF "$1" <(cut -f2 "$TSV"); }

# A file well past the pipe buffer, with the dir under test as its FIRST row.
FIRST="x-os-BH-1-202607010000"
LAST="x-os-BH-900-202607010000"
{
  printf 'x-os\t%s\tPR_CREATED https://x.example/pull/1\taged-out >168h\n' "$FIRST"
  i=2
  while [ "$i" -le 900 ]; do
    printf 'x-os\tx-os-BH-%s-202607010000\tPR_CREATED https://x.example/pull/%s\taged-out >168h\n' "$i" "$i"
    i=$((i + 1))
  done
} > "$TSV"
SZ=$(stat -c%s "$TSV")
[ "$SZ" -gt "$PIPEBUF" ] \
  && ok || bad "fixture: the tsv is $SZ bytes, the bug only shows above the $PIPEBUF-byte pipe buffer"
BEFORE=$(rows)

# ── C1: a dir already recorded FIRST in a >64 KB file is not recorded again ──
record "$FIRST" "aged-out >168h" ; RC=$?
[ "$RC" -eq 0 ] && ok || bad "C1: the writer returned $RC for a dir it had already recorded"
[ "$(rows)" -eq "$BEFORE" ] \
  && ok || bad "C1: the row was appended again ($BEFORE rows before, $(rows) after) — the dedupe read is losing its own rc"
[ "$(dirrows "$FIRST")" -eq 1 ] \
  && ok || bad "C1: $FIRST now has $(dirrows "$FIRST") rows; the file is no longer a set keyed on the build dir"

# ── C2: ten more ticks change nothing (the lane runs every 10 minutes) ───────
i=1
while [ "$i" -le 10 ]; do record "$FIRST" "aged-out >168h"; i=$((i + 1)); done
[ "$(rows)" -eq "$BEFORE" ] \
  && ok || bad "C2: ten ticks grew the file to $(rows) rows from $BEFORE"

# ── C3: the same for the LAST row (the case that was always green) ──────────
record "$LAST" "aged-out >168h"
[ "$(rows)" -eq "$BEFORE" ] && ok || bad "C3: a dir recorded last in the file was appended again"

# ── C4: a dir that is NOT in the file is still appended, exactly once ───────
NEW="x-os-BH-1044-202609190000"
record "$NEW" "aged-out >168h (empty-url)"
[ "$(rows)" -eq "$((BEFORE + 1))" ] \
  && ok || bad "C4: a new dir did not append one row ($(rows) rows, want $((BEFORE + 1)))"
[ "$(dirrows "$NEW")" -eq 1 ] && ok || bad "C4: the new dir landed $(dirrows "$NEW") times"
grep -qF "aged-out >168h (empty-url)" "$TSV" \
  && ok || bad "C4: the reason column did not survive the append"
record "$NEW" "aged-out >168h (empty-url)"
[ "$(rows)" -eq "$((BEFORE + 1))" ] \
  && ok || bad "C5: the second tick re-appended the dir it had just written"

# ── C6: a first write against no file at all ────────────────────────────────
rm -f "$TSV"
record "$NEW" "aged-out >168h"
[ -f "$TSV" ] && [ "$(rows)" -eq 1 ] \
  && ok || bad "C6: the first ever record wrote $(rows 2>/dev/null) rows"
record "$NEW" "aged-out >168h"
[ "$(rows)" -eq 1 ] && ok || bad "C6: the second record on a one-row file appended again"

# ── C7: a row whose dir is a prefix of another dir is not confused for it ───
record "x-os-BH-10440-202609190000" "aged-out >168h"
[ "$(rows)" -eq 2 ] \
  && ok || bad "C7: a dir whose name extends an existing one was treated as already recorded"

echo "closeout-record-aged-dedupe: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
