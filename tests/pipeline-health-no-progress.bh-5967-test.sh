#!/bin/bash
# tests/pipeline-health-no-progress.bh-5967-test.sh — BH-5967 part 5: two
# per-project counts (stranded tickets, parked PRs) and one page when either
# stands above 0 for PH_NOPROGRESS_ALERT_MIN (120) minutes.
#
# THE CENSUS (2026-10-10). 39 cromford tickets had no blocker and no build
# for hours, and 9 approved stacked PRs sat parked, and nothing paged.
#
#   N1  above 0 for less than 2 h: counted, logged, no page
#   N2  above 0 for 2 h or more: one page per metric, naming the project
#   N3  the count falls to 0: the clock goes, and the next rise starts it again
#   N4  a stale stranded count (older than PH_NOPROGRESS_COUNT_MAX_AGE_S) is
#       not read as a number; parked rows of another repo are not counted
#   N5  noprogress is a retractable namespace, so a cleared page is RESOLVED
#
# The block is cut out of bin/pipeline-health.sh by its markers and driven with
# a recording alert(). Run from anywhere (exit 0 = pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

PH="$DIR/bin/pipeline-health.sh"
A=$(grep -c '^# >>> no progress (BH-5967)' "$PH"); B=$(grep -c '^# <<< no progress' "$PH")
[ "$A" = 1 ] && [ "$B" = 1 ] && ok || bad "bin/pipeline-health.sh must carry one '# >>> no progress' block (open=$A close=$B)"
awk '/^# >>> no progress \(BH-5967\)/{f=1;next} /^# <<< no progress/{exit} f' "$PH" > "$T/block.sh"
grep -q 'noprogress:' "$T/block.sh" && ok || bad "the extracted block is not the no-progress check"
RNS=$(sed -n 's/^RETRACT_NS="\(.*\)"$/\1/p' "$PH")
grep -qE "^($RNS):" <<<"noprogress:cromford:parked" && ok || bad "N5: noprogress is not in RETRACT_NS"

H="$T/h"
mkdir -p "$H/state/merge-conductor" "$H/state/stranded-watch/bh" "$H/logs"
printf 'bh example-org/cromford - - 3 box\nts example-org/project-5 - - 0 box\n' > "$H/fleet.conf"
NOW=1789000000
STAMP() { echo "2026-10-10 00:00:00Z"; }
rows() { # rows <n-parked-bh> — conductor rows: n parked for bh, one parked for ts, one READY for bh
  local i
  { for i in $(seq 1 "$1"); do printf 'example-org/cromford#%s\tBLOCKED_HUMAN\t0\th\th\t-\tconflict-unresolvable: x\tu\n' "$((100 + i))"; done
    printf 'example-org/project-5#7\tRED_TWICE\t0\th\th\t-\tred\tu\n'
    printf 'example-org/cromford#99\tREADY\t0\th\th\t-\t-\tu\n'; } > "$H/state/merge-conductor/pr-state.tsv"
}
count() { printf '%s\t%s\n' "$1" "$2" > "$H/state/stranded-watch/bh/.count"; }
drive() { # drive <now>
  : > "$T/alerts.txt"
  ( alert() { printf '%s\t%s\n' "$2" "$3" >> "$T/alerts.txt"; }
    NOW="$1"; PROJECTS="bh ts"
    # shellcheck disable=SC1090
    . "$T/block.sh" )
}

# ── N1: above 0 for less than 2 h ──
rows 9; count "$NOW" 39
drive "$NOW"
[ ! -s "$T/alerts.txt" ] && ok || bad "N1: no page in the first two hours: $(cat "$T/alerts.txt")"
grep -q 'no-progress counts: bh=stranded:39,parked:9 ts=stranded:-,parked:1' "$H/logs/pipeline-health.log" && ok \
  || bad "N1: one line with both counts per project: $(tail -1 "$H/logs/pipeline-health.log")"

# ── N2: two hours later, still above 0 ──
T2=$((NOW + 7200)); count "$T2" 37
drive "$T2"
grep -q '^noprogress:bh:stranded	bh: 37 open ai-build ticket(s) with no blocker and no build attempt, above 0 for 120 min' "$T/alerts.txt" && ok \
  || bad "N2: THE POINT: the stranded page fires at 2 h: $(cat "$T/alerts.txt")"
grep -q '^noprogress:bh:parked	bh: 9 PR(s) parked BLOCKED_HUMAN or RED_TWICE in the conductor, above 0 for 120 min' "$T/alerts.txt" && ok \
  || bad "N2: the parked page fires at 2 h: $(cat "$T/alerts.txt")"
grep -q '^noprogress:ts:parked' "$T/alerts.txt" && ok || bad "N2: project-5's parked PR pages too: $(cat "$T/alerts.txt")"
[ "$(grep -c . "$T/alerts.txt")" = 3 ] && ok || bad "N2: three conditions, three pages: $(cat "$T/alerts.txt")"

# ── N3: the count falls to 0, then rises again ──
T3=$((T2 + 600)); rows 0; count "$T3" 0
drive "$T3"
[ ! -e "$H/state/pipeline-health/noprogress/bh.stranded" ] && [ ! -e "$H/state/pipeline-health/noprogress/bh.parked" ] && ok \
  || bad "N3: a count of 0 ends the clock"
T4=$((T3 + 600)); rows 2; count "$T4" 1
drive "$T4"
grep -q '^noprogress:bh' "$T/alerts.txt" && bad "N3: a new rise starts a new 2-hour clock: $(cat "$T/alerts.txt")" || ok

# ── N4: a stale count is no number ──
T5=$((T4 + 7200)); count "$((T5 - 6000))" 5
drive "$T5"
grep -q '^noprogress:bh:stranded' "$T/alerts.txt" && bad "N4: a 100-minute-old count is not read: $(cat "$T/alerts.txt")" || ok
grep -q '^noprogress:bh:parked	bh: 2 PR(s)' "$T/alerts.txt" && ok || bad "N4: parked counts only cromford's rows: $(cat "$T/alerts.txt")"

echo "pipeline-health-no-progress.bh-5967: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
