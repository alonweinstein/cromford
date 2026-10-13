#!/bin/bash
# tests/blocked-resolver-prepass.bh-1512-test.sh — BH-1512: a ZERO-BYTE state
# record is indexed as unparseable, exactly the way a `not json` record already
# is, instead of being dropped without a count, a line or a mark.
#
# THE BUG. br_record_index walks state/blocked-resolver/<p>/<k>.json through
# `awk 'FNR==1 { printf "%s\t%s\n", FILENAME, $0 }'`. awk runs its rule on
# RECORDS, and a zero-byte file contributes none — so FNR==1 never fires for it,
# no `<path>\t<payload>` line is emitted, and the record never reaches the jq
# stage that turns an unparseable payload into `!PARSE`. BH-1457 made "every
# degradation is loud" the rule of this pre-pass: a record that will not parse is
# counted into `$bad`, named on ONE log line and marked on the tick line as
# `+index-short`. A zero-byte record got none of that, and a zero-byte record is
# exactly what a non-atomic `printf > "$f"` leaves behind mid-write — which is
# every record write in this lane. An operator read a clean tick.
#
# WHY A NEW FILE, AND WHAT IT MIRRORS. The ticket asks for a red-first case
# "beside the existing §12" of tests/blocked-resolver-prepass.bh-1457-test.sh
# (the `not json` record). The fixture and the assertion shape below are that
# section's, deliberately: same two conductor rows, same seeded ABANDONED record,
# same three readings (`retired`, the `+index-short` mark, the one count line).
# A new file rather than a §12c so two builds touching this lane do not collide
# on one suite.
#
# WHAT IS DRIVEN. Every section runs the real bin/blocked-resolver.sh end to end
# against a scratch $HARNESS. Nothing here greps the source of the lane: every
# assertion is a field of the tick line the run wrote or a count of lines in its
# own log.
#
# Run from anywhere: tests/blocked-resolver-prepass.bh-1512-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh): every fixture
# age below is derived from it.
NOW=$(date -u +%s)

H="$T/h"
mkdir -p "$H/bin"
# The scripts this suite drives. The copy stays HERE, in the suite's own text, so
# bin/test-impact.sh still selects this suite when one of them changes.
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$H/bin/"
# The whole fixture — scratch tree, br modules, sibling libs, stubbed PATH and
# the RUN helper — is tests/lib/fixture-harness.sh (BH-1196).
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
fx_br_harness "$DIR" "$T" || exit 1
[ -d "$DIR/bin/lib/br" ] || exit 1   # impact: this suite runs when bin/lib/br/ changes

# THE gh STUB IS THE 1457 SUITE'S, not the fixture's, for one reason: the shared
# fixture answers every PR read with the same branch (ticket/TK-9), so two rows
# would derive ONE ticket key and no seeded record could be keyed to one of them.
# Here the branch, title and head are derived from the PR NUMBER in the argv, so
# #31 is TK-31 and #32 is TK-32 and the sections below can put a record under one
# of them.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pull|pulls|issues)/([0-9]+).*#\2#p' | head -1)
case "\$*" in
  *"-i -X "*)
    GHT="$T"
    printf 'ticket/ts-%s' "\$N" > "$T/prbranch"
    printf 'TK-%s: a thing' "\$N" > "$T/prtitle"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$T/prhead"
    . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"issues/"*"/comments"*) cat "$T/comments-\$N.json" 2>/dev/null || echo '[]' ;;
  *"repos/"*"/issues/"*)
    cat "$T/issue-\$N.json" 2>/dev/null || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; } ;;
  *"pr close"*)   printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"pr comment"*|*"issue comment"*) printf '%s\n' "\$*" >> "$T/comments.txt"; exit 0 ;;
  *"--json state"*) cat "$T/prstate" 2>/dev/null || echo OPEN ;;
  *"/pulls/"*)    echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/ts-\$N" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
: > "$T/gh.txt"; : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/comments.txt"
: > "$T/run.log"
echo OPEN > "$T/prstate"
touch "$H/flags/fly-pool-tproj"

# The jobs client, the 1457 suite's JOBS_OK verbatim: a rebuild rung enqueues
# into it, so a non-retired merge-failed-twice row still dispatches and the tick
# line is still written.
JOBS_OK() { cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
}
JOBS_OK

ISSUE() {  # ISSUE <number> <labels-csv>
  local labels="[]"
  [ -n "${2:-}" ] && labels=$(printf '%s' "$2" | jq -Rc 'split(",")|map({name:.})')
  jq -nc --argjson n "$1" --argjson l "$labels" --arg t "TK-$1: a parked ticket" \
         --arg c "$(date -u -d "@$((NOW - 604800))" '+%Y-%m-%dT%H:%M:%SZ')" \
         '{number:$n,state:"open",labels:$l,title:$t,body:"## Scope",created_at:$c}'
}
for N in 31 32; do
  ISSUE "$N" ai-build > "$T/issue-$N.json"
  echo '[]' > "$T/comments-$N.json"
done

ROWS="$H/state/merge-conductor/pr-state.tsv"
ST="$H/state/blocked-resolver"
# The reason that dispatches the dearest rung with no record pre-seeded, so a
# row that is NOT retired still reaches a rung and the tick reports.
MFT="merge-failed-twice: gh pr merge refused"
# ROWADD APPENDS — the fixture's ROW overwrites, and these sections need two rows.
ROWADD() { printf '%s\t%s\t%s\t%s\t%s\t-\t%s\t%s\n' \
             "$1" "${5:-BLOCKED_HUMAN}" "$2" "${6:-abc123}" "${6:-abc123}" "$3" "$4" >> "$ROWS"; }
# SEED <project> <key> <json> — a state record as an earlier tick left it.
SEED() { mkdir -p "$ST/$1"; printf '%s\n' "$3" | jq -c \
           --arg p "$1" --arg k "$2" '.project=$p | .rkey=$k' > "$ST/$1/$2.json"; }
LOG() { cat "$H/logs/blocked-resolver.log" 2>/dev/null; }
LASTTICK() { grep 'tick: candidates=' "$H/logs/blocked-resolver.log" \
             | tail -1 | sed -E 's/^[0-9-]+ [0-9:]+Z //'; }
LFIELD() { LASTTICK | sed -nE "s/.*(^| )$1=([^ ]*).*/\2/p"; }
NLINES() { grep -c "$1" "$H/logs/blocked-resolver.log" 2>/dev/null; }
CLEAN() { scratch_rm "$ST" 2>/dev/null
          scratch_rm "$H/state/merge-conductor/handoff" 2>/dev/null
          scratch_rm "$H/state/merge-conductor/handoff-released" 2>/dev/null
          : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/gh.txt"; : > "$T/ssh.txt"
          : > "$T/comments.txt"
          : > "$H/logs/blocked-resolver.log"; rm -f "$H/logs/ALERTS.log"
          echo OPEN > "$T/prstate"; JOBS_OK
          : > "$ROWS"; }

# ============================================================================
# 1. THE BUG: A ZERO-BYTE RECORD IS COUNTED, NAMED AND MARKED. It is the same
#    degradation as §12's `not json` record — a record the index cannot use —
#    and until this change it was the SILENT one: awk emits nothing for a file
#    with no first line, so the record never reached jq and the tick read clean.
# ============================================================================
CLEAN
SEED tproj tproj-TK-31 '{"outcome":"ABANDONED","attempts":[]}'
# ZERO BYTES, asserted: a one-byte file (a lone newline) was already loud, so a
# fixture that drifted into one would prove nothing this ticket is about.
: > "$ST/tproj/aaa-empty.json"
[ ! -s "$ST/tproj/aaa-empty.json" ] && ok \
  || bad "1: the fixture record must be zero bytes (size: $(wc -c < "$ST/tproj/aaa-empty.json"))"
ROWADD "o/tproj#31" "$NOW" "$MFT" "https://github.com/o/tproj/pull/31"
ROWADD "o/tproj#32" "$NOW" "$MFT" "https://github.com/o/tproj/pull/32"
RUN
case "$(LFIELD reason)" in
  *+index-short*) ok ;;
  *) bad "1: THE BUG: a zero-byte record must mark the tick +index-short (tick: $(LASTTICK))" ;;
esac
[ "$(NLINES 'could not be parsed and were not indexed')" = 1 ] && ok \
  || bad "1: and the one line must count it (log: $(LOG | tail -3))"
[ "$(LFIELD retired)" = 1 ] && ok \
  || bad "1: and the ABANDONED row beside it must still retire (tick: $(LASTTICK))"

# ============================================================================
# 1b. THE EMPTY RECORD IS THE CANDIDATE'S OWN KEY. Indexed under an outcome
#     br_finished never matches, so nothing is retired off it and the park is
#     costed off zero counters — the safe direction, unchanged by this fix.
# ============================================================================
CLEAN
mkdir -p "$ST/tproj"
: > "$ST/tproj/tproj-TK-31.json"
ROWADD "o/tproj#31" "$NOW" "$MFT" "https://github.com/o/tproj/pull/31"
RUN
[ "$(LFIELD retired)" = 0 ] && ok \
  || bad "1b: an empty record must retire nothing (tick: $(LASTTICK))"
case "$(LFIELD reason)" in
  *+index-short*) ok ;;
  *) bad "1b: THE BUG: and the tick must still be marked (tick: $(LASTTICK))" ;;
esac
[ "$(LFIELD candidates)" = 1 ] && ok \
  || bad "1b: the row is still a candidate (tick: $(LASTTICK))"

# ============================================================================
# 1c. A CLEAN TREE IS STILL NOT MARKED (§12b's twin). The mark has to mean
#     something, or an operator learns to ignore it.
# ============================================================================
CLEAN
SEED tproj tproj-TK-31 '{"outcome":"ABANDONED","attempts":[]}'
ROWADD "o/tproj#31" "$NOW" "$MFT" "https://github.com/o/tproj/pull/31"
ROWADD "o/tproj#32" "$NOW" "$MFT" "https://github.com/o/tproj/pull/32"
RUN
case "$(LFIELD reason)" in
  *+index-short*) bad "1c: a clean tree must not be marked (tick: $(LASTTICK))" ;;
  *) ok ;;
esac
[ "$(NLINES 'could not be parsed')" = 0 ] && ok \
  || bad "1c: and no count line is written (log: $(LOG | tail -3))"

# ============================================================================
# 1d. THE COUNT IS THE SUM. An empty record and a `not json` record are the same
#     degradation, so they share one counter and one line — not a second line
#     and not a second vocabulary word on the tick.
# ============================================================================
CLEAN
SEED tproj tproj-TK-31 '{"outcome":"ABANDONED","attempts":[]}'
: > "$ST/tproj/aaa-empty.json"
printf 'not json at all\n' > "$ST/tproj/bbb-broken.json"
ROWADD "o/tproj#31" "$NOW" "$MFT" "https://github.com/o/tproj/pull/31"
ROWADD "o/tproj#32" "$NOW" "$MFT" "https://github.com/o/tproj/pull/32"
RUN
[ "$(NLINES '2 state record(s) could not be parsed and were not indexed')" = 1 ] && ok \
  || bad "1d: THE BUG: both must be counted into the one line (log: $(LOG | grep 'could not be parsed'))"

echo "blocked-resolver-prepass.bh-1512: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
