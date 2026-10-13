#!/bin/bash
# tests/split-watchdog-decider.bh-1793-test.sh — BH-1807 (BH-1793.2): the pure
# split-watchdog decider `sw_next_step` in bin/lib/split-watchdog.sh, driven by
# sourcing the REAL lib and piping a family TSV into it, the way the lane will.
#   P*  parsing: empty columns keep their place, malformed rows and bad args
#       print nothing and return 3 / 2, empty stdin prints nothing, rc 0.
#   R*  one case per rule (enqueue, reenqueue, owed-completion, handoff-rebase,
#       close-parent), B* the N-minute boundary.
#   N*  every adversarial negative: nothing (or not the named step) is printed.
#   AT-8 two rules due -> exactly one line, the first rule's.
#   IO1 no external binary is needed and the cwd stays untouched.
# Run from anywhere: tests/split-watchdog-decider.bh-1793-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
DLIB="$DIR/bin/lib/split-watchdog.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

NOW=1000000; N=10; M=30; RE='plan session produced no output|PLAN_STALE'
TAB=$'\t'

# row key=<k> [field=value ...] -> one 14-column TSV line; unnamed fields keep
# the default child (pr none, lock 0, queue none, not waiting, deploy unknown).
row() {
  local key="" tid=1 board=ready woc=0 pr=none url="" merged="" mergeable=unknown sha=""
  local lock=0 queue=none reason="" fin="" deploy=unknown kv
  for kv in "$@"; do
    case $kv in
      key=*) key=${kv#*=} ;; tid=*) tid=${kv#*=} ;; board=*) board=${kv#*=} ;;
      woc=*) woc=${kv#*=} ;; pr=*) pr=${kv#*=} ;; url=*) url=${kv#*=} ;;
      merged=*) merged=${kv#*=} ;; mergeable=*) mergeable=${kv#*=} ;;
      sha=*) sha=${kv#*=} ;; lock=*) lock=${kv#*=} ;; queue=*) queue=${kv#*=} ;;
      reason=*) reason=${kv#*=} ;; fin=*) fin=${kv#*=} ;; deploy=*) deploy=${kv#*=} ;;
      *) echo "row: bad field $kv" >&2; return 1 ;;
    esac
  done
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$key" "$tid" "$board" "$woc" "$pr" "$url" "$merged" "$mergeable" "$sha" \
    "$lock" "$queue" "$reason" "$fin" "$deploy"
}

# chk <name> <want_rc> <want_stdout> [args...] ; the family is in $IN.
chk() {
  local name=$1 wrc=$2 want=$3 out rc; shift 3
  [ $# -gt 0 ] || set -- "$NOW" "$N" "$M" "$RE"
  out=$(printf '%s' "$IN" | bash -c 'set -u; . "$1"; shift; sw_next_step "$@"' _ "$DLIB" "$@" 2>/dev/null); rc=$?
  if [ "$rc" = "$wrc" ] && [ "$out" = "$want" ]; then ok
  else bad "$name rc=$rc out=[$out], want rc $wrc out=[$want]"; fi
}

M601=$((NOW-601)); M600=$((NOW-600)); M599=$((NOW-599))
C1M=$(row key=c1 board=done pr=merged url=u1 merged=$M601)

# --- P: parsing -----------------------------------------------------------------
IN=$(row key=c1 board=in_progress pr=merged deploy=1)$'\n'
chk P1 0 "owed-completion${TAB}c1${TAB}merged , deploy serves merge, board in_progress"
IN=$'c1\t1\tready\t0\tnone\t\t\tunknown\t\t0\tnone\t\t\n'   # 13 columns
chk P2 3 ""
IN=$C1M$'\n'$(row key=c2)$'\n'
chk P3 2 "" abc "$N" "$M" "$RE"
chk P3b 2 "" "$NOW" "" "$M" "$RE"
IN=""
chk P4 0 ""
IN=$'\n\n'
chk P4b 0 ""

# --- R2 / B: enqueue ------------------------------------------------------------
WANT2="enqueue${TAB}c2${TAB}predecessors merged: c1 @$M601"
IN=$C1M$'\n'$(row key=c2)$'\n';                          chk R2 0 "$WANT2"
IN=$C1M$'\r\n'$(row key=c2)$'\r\n';                      chk R2crlf 0 "$WANT2"
IN=$(row key=c1 board=done pr=merged merged=$M600)$'\n'$(row key=c2)$'\n'
chk B1 0 "enqueue${TAB}c2${TAB}predecessors merged: c1 @$M600"
IN=$(row key=c1 board=done pr=merged merged=$M599)$'\n'$(row key=c2)$'\n'
chk B2 0 ""
IN=$C1M$'\n'$(row key=c2 queue=done)$'\n';               chk R2d 0 "$WANT2"
# latest predecessor merge is the one measured against N
IN=$(row key=c1 board=done pr=merged merged=1000)$'\n'$(row key=c2 board=done pr=merged merged=$M599)$'\n'$(row key=c3)$'\n'
chk R2max 0 ""
IN=$C1M$'\n'$(row key=c2 woc=1)$'\n';                    chk N1 0 ""
IN=$C1M$'\n'$(row key=c2 woc=unknown)$'\n';              chk N1b 0 ""
IN=$(row key=c1 pr=open url=u1 mergeable=clean)$'\n'$(row key=c2)$'\n'; chk N2 0 ""
IN=$(row key=c1 pr=closed merged=$M601)$'\n'$(row key=c2)$'\n';        chk N3 0 ""
IN=$(row key=c1 pr=unknown merged=$M601)$'\n'$(row key=c2)$'\n';       chk N4 0 ""
IN=$(row key=c1 board=done pr=merged)$'\n'$(row key=c2)$'\n';          chk N5 0 ""
IN=$C1M$'\n'$(row key=c2 pr=open url=u2 mergeable=clean sha=s2)$'\n'$(row key=c3)$'\n'
chk N6 0 ""
IN=$C1M$'\n'$(row key=c2 lock=1)$'\n';                   chk N7 0 ""
IN=$C1M$'\n'$(row key=c2 lock=unknown)$'\n';             chk N7b 0 ""
for q in queued ready claimed; do
  IN=$C1M$'\n'$(row key=c2 queue=$q)$'\n';               chk "N8 $q" 0 ""
done
IN=$C1M$'\n'$(row key=c2 queue=unknown)$'\n';            chk N9 0 ""
IN=$(row key=c1 board=done pr=none merged=$M601)$'\n'$(row key=c2)$'\n'; chk N10 0 ""
IN=$'c1\t1\tready\t0\tnone\t\t\tunknown\t\t0\tnone\t\t\tunknown\n'     # contract C3 row
chk N11 0 ""

# --- R3: reenqueue --------------------------------------------------------------
F1801=$((NOW-1801)); F1799=$((NOW-1799))
IN=$(row key=c1 queue=failed reason=PLAN_STALE fin=$F1801)$'\n'
chk R3 0 "reenqueue${TAB}c1${TAB}retry failed: PLAN_STALE"
IN=$(row key=c1 queue=failed "reason=BUILD_DEFERRED file overlap" fin=$F1801)$'\n'
chk N12 0 "" "$NOW" "$N" "$M" "BUILD_DEFERRED|PLAN_STALE"
IN=$(row key=c1 queue=failed "reason=PLAN_STALE REFUSED" fin=$F1801)$'\n'
chk N12b 0 ""
IN=$(row key=c1 queue=failed reason=PLAN_STALE fin=$F1799)$'\n';  chk N13 0 ""
IN=$(row key=c1 queue=failed reason=PLAN_STALE fin=)$'\n';        chk N13b 0 ""
IN=$(row key=c1 queue=failed reason=boom fin=$F1801)$'\n';        chk N14 0 ""
IN=$(row key=c1 queue=failed reason=PLAN_STALE fin=$F1801)$'\n'
chk N15 0 "" "$NOW" "$N" "$M" ""
IN=$(row key=c1 woc=1 queue=failed reason=PLAN_STALE fin=$F1801)$'\n';    chk N16 0 ""
IN=$(row key=c1 lock=1 queue=failed reason=PLAN_STALE fin=$F1801)$'\n';   chk N16b 0 ""
IN=$(row key=c1 pr=open queue=failed reason=PLAN_STALE fin=$F1801)$'\n';  chk N16c 0 ""

# --- R4: owed-completion --------------------------------------------------------
WANT4="owed-completion${TAB}c1${TAB}merged https://gh/pr/1, deploy serves merge, board in_progress"
IN=$(row key=c1 board=in_progress pr=merged url=https://gh/pr/1 merged=$M601 deploy=1)$'\n'
chk R4 0 "$WANT4"
IN=$(row key=c1 board=in_progress woc=1 pr=merged url=https://gh/pr/1 merged=$M601 deploy=1)$'\n'
chk R4w 0 "$WANT4"
IN=$(row key=c1 board=in_progress pr=merged url=u merged=$M601 deploy=unknown)$'\n'$(row key=c2 pr=open)$'\n'
chk N17 0 ""
IN=$(row key=c1 board=in_progress pr=merged url=u merged=$M601 deploy=0)$'\n'$(row key=c2 pr=open)$'\n'
chk N18 0 ""
IN=$(row key=c1 board=review pr=merged url=u merged=$M601 deploy=1)$'\n'$(row key=c2 pr=open)$'\n'
chk N22 0 ""

# --- R5: handoff-rebase ---------------------------------------------------------
IN=$(row key=c1 pr=open url=https://gh/pr/2 mergeable=dirty sha=abc)$'\n'
chk R5 0 "handoff-rebase${TAB}c1${TAB}PR https://gh/pr/2 dirty @abc"
IN=$(row key=c1 pr=open url=https://gh/pr/2 mergeable=dirty sha=def)$'\n'
chk R5b 0 "handoff-rebase${TAB}c1${TAB}PR https://gh/pr/2 dirty @def"
IN=$(row key=c1 pr=open url=u mergeable=unknown sha=abc)$'\n';   chk N19 0 ""
IN=$(row key=c1 pr=open url=u mergeable=dirty sha=)$'\n';        chk N23 0 ""
IN=$(row key=c1 woc=1 pr=open url=u mergeable=dirty sha=abc)$'\n'
chk N21 0 "handoff-rebase${TAB}c1${TAB}PR u dirty @abc"

# --- R6: close-parent -----------------------------------------------------------
IN=$C1M$'\n'$(row key=c2 board=done pr=merged merged=$M601)$'\n'$(row key=c3 board=review pr=merged merged=$M601)$'\n'
chk R6 0 "close-parent${TAB}-${TAB}family merged: c1,c2,c3"
IN=$C1M$'\n'$(row key=c2 board=done pr=merged merged=$M601)$'\n'$(row key=c3 pr=closed)$'\n'
chk N20 0 ""

# --- AT-8: two rules due, exactly the first prints --------------------------------
IN=$(row key=c1 board=in_progress pr=merged url=u1 merged=$M601 deploy=1)$'\n'$(row key=c2 board=done pr=merged merged=$M601)$'\n'$(row key=c3)$'\n'
chk AT-8 0 "enqueue${TAB}c3${TAB}predecessors merged: c2 @$M601"
out=$(printf '%s' "$IN" | bash -c 'set -u; . "$1"; shift; sw_next_step "$@"' _ "$DLIB" "$NOW" "$N" "$M" "$RE")
[ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] && ok || bad "AT-8 line count != 1: [$out]"

# --- IO1: no external binary, no file written ------------------------------------
mkdir -p "$T/io"
IN=$C1M$'\n'$(row key=c2)$'\n'
out=$(cd "$T/io" && printf '%s' "$IN" | PATH=/nonexistent "$BASH" -c 'set -u; . "$1"; shift; sw_next_step "$@"' _ "$DLIB" "$NOW" "$N" "$M" "$RE" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$out" = "$WANT2" ] && ok || bad "IO1 rc=$rc out=[$out] with PATH=/nonexistent"
[ -z "$(ls -A "$T/io")" ] && ok || bad "IO1 cwd not empty: $(ls -A "$T/io")"

echo "split-watchdog-decider.bh-1793: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
