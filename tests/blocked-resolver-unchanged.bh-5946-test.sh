#!/bin/bash
# tests/blocked-resolver-unchanged.bh-5946-test.sh — BH-5946: a quiet row whose
# local inputs did not change since the last look is skipped on the next run,
# with no GitHub, D1 or model call (bin/lib/br/opt/unchanged.sh).
#
# WHAT IS CLAIMED. On the hub, 4 runs on 2026-10-09 took secs=2991..3498 over
# 600+ candidates. Most rows end on a quiet exit (held, escalated, stalled, a
# hold the rung gate respected) and are read again on the next run from the
# start: the HOLD issue, its comment pages, the merged-PR search. The module
# stores a fingerprint of the row's LOCAL inputs at a quiet exit, and the next
# run returns rc 3 at the top of br_one when the fingerprint is equal, the class
# is on the allowlist and the look is younger than BR_UNCHANGED_RECHECK_S.
#
# The REAL bin/blocked-resolver.sh runs over a scratch $HARNESS
# (tests/lib/br-repeat-cuts-fixture.sh). Every assertion is a recorded gh,
# jobs-client or agent call, a ledger file, a state json byte, a log line or a
# field of the run's own `prof:` line.
#
# Run from anywhere: tests/blocked-resolver-unchanged.bh-5946-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
. "$(dirname "$0")/lib/br-repeat-cuts-fixture.sh" || exit 1
# The module under test, and the profile module for the `prof:` line.
BRF_MODULES="profile unchanged"
brf_setup || { echo "fixture setup failed"; exit 1; }
[ -r "$DIR/bin/lib/br/opt/unchanged.sh" ] || bad "bin/lib/br/opt/unchanged.sh is missing"

U=https://github.com/o/tproj/pull
LOOKS="$ST/tproj/.looks"
# The four quiet rows of U1:
#   #71 held       a HELD record, a HOLD comment on issue 71
#   #72 escalated  an ESCALATED record on a review-changes-requested row
#   #73 stalled    a STALLED record whose stall fingerprint is this row
#   #74 rung-hold  no record; the rung gate reads the HOLD comment on issue 74
U1FIX() {
  local n
  for n in 71 72 73 74; do PRADD "$n"; done
  CROW 71 'head-not-reapproved: BLOCK on the head'
  CROW 72 'review-changes-requested: the lead asked for changes'
  CROW 73 'head-not-reapproved: BLOCK on the head'
  CROW 74 'head-not-reapproved: BLOCK on the head'
  HOLDCMT 71; HOLDCMT 74
  SEED tproj-TK-71 '{"outcome":"HELD"}'
  SEED tproj-TK-72 '{"outcome":"ESCALATED"}'
  SEED tproj-TK-73 "$(jq -nc --arg f "head-not-reapproved|$U/73|-|$(HEAD_OF 73)" '{outcome:"STALLED",stalled_fp:$f}')"
}
# CLEARREC — empty the recorders between run 1 and run 2.
CLEARREC() { : > "$T/gh.txt"; : > "$T/jobs.txt"; : > "$T/agent.txt"; }
# NROW <n> — the gh calls that read PR/issue #<n> outside discovery: every
# issues/<n> read, and every pulls/<n> read past the one discovery head read.
NISSUE() { NGH "repos/o/tproj/issues/$1([/?]|$)"; }
NPULL()  { NGH "repos/o/tproj/pulls/$1([/?]|$)"; }
BYTES() { cat "$ST/tproj/$1.json" 2>/dev/null; }
SETCOL() { # SETCOL <n> <column> <value> — rewrite one column of #<n>'s conductor row
  awk -F'\t' -v OFS='\t' -v k="o/tproj#$1" -v c="$2" -v v="$3" '$1 == k { $c = v } { print }' "$ROWS" > "$ROWS.t" \
    && mv "$ROWS.t" "$ROWS"
}

# ===========================================================================
# U1 — run 2 over four unchanged quiet rows reads nothing (acceptance 1).
# ===========================================================================
brf_reset; U1FIX
B71=$(BYTES tproj-TK-71); B72=$(BYTES tproj-TK-72); B73=$(BYTES tproj-TK-73)
TICK
for k in o-tproj-71 o-tproj-72 o-tproj-73 o-tproj-74; do
  [ -s "$LOOKS/$k" ] && ok || bad "U1: run 1 must leave a ledger line for $k (ls: $(ls -A "$LOOKS" 2>/dev/null | tr '\n' ' '))"
done
[ "$(cut -f2 "$LOOKS/o-tproj-71" 2>/dev/null)" = held ] && ok || bad "U1: #71's class must be held: '$(cat "$LOOKS/o-tproj-71" 2>/dev/null)'"
[ "$(cut -f2 "$LOOKS/o-tproj-72" 2>/dev/null)" = escalated ] && ok || bad "U1: #72's class must be escalated: '$(cat "$LOOKS/o-tproj-72" 2>/dev/null)'"
[ "$(cut -f2 "$LOOKS/o-tproj-73" 2>/dev/null)" = stalled ] && ok || bad "U1: #73's class must be stalled: '$(cat "$LOOKS/o-tproj-73" 2>/dev/null)'"
[ "$(cut -f2 "$LOOKS/o-tproj-74" 2>/dev/null)" = rung-hold ] && ok || bad "U1: #74's class must be rung-hold: '$(cat "$LOOKS/o-tproj-74" 2>/dev/null)'"
# U9 — the quiet looks of run 1 wrote nothing to the three seeded records.
[ "$(BYTES tproj-TK-71)" = "$B71" ] && ok || bad "U9: the held look must not write #71's record"
[ "$(BYTES tproj-TK-72)" = "$B72" ] && ok || bad "U9: the escalated look must not write #72's record"
[ "$(BYTES tproj-TK-73)" = "$B73" ] && ok || bad "U9: the stalled look must not write #73's record"
B74=$(BYTES tproj-TK-74)
CLEARREC; TICK
U1_ON=$(( $(NISSUE 71) + $(NISSUE 74) ))
for n in 71 72 73 74; do
  [ "$(NISSUE "$n")" = 0 ] && ok || bad "U1: run 2 must not read issue #$n, got $(NISSUE "$n"): $(grep -E "issues/$n" "$T/gh.txt" | head -3)"
  # One pulls/<n> read per conductor row is discovery's head-branch read
  # (br_conductor_emit, out of scope). Nothing past it.
  [ "$(NPULL "$n")" = 1 ] && ok || bad "U1: run 2 may read pulls/$n once (discovery), got $(NPULL "$n")"
done
[ "$(NGH 'search/issues')" = 0 ] && ok || bad "U1: run 2 must make no merged-PR search, got $(NGH 'search/issues')"
[ "$(grep -c . "$T/agent.txt")" = 0 ] && ok || bad "U1: run 2 must make no model call: $(cat "$T/agent.txt")"
[ "$(grep -cE 'TK-7[1-4]|pr=7[1-4]' "$T/jobs.txt")" = 0 ] && ok || bad "U1: run 2 must make no jobs call for the four keys: $(grep -E 'TK-7|pr=7' "$T/jobs.txt")"
[ "$(PFIELD unchanged)" = 4 ] && ok || bad "U1: run 2's prof: line must say unchanged=4, got '$(PROF)'"
# The skipped rows took no GitHub call at all: the per-row profile says 0.
R2GH=$(PROWS | awk -F'\t' '$2 ~ /^o-tproj-7[1-4]$/ { s += $7 } END { print s + 0 }')
[ "$R2GH" = 0 ] && ok || bad "U1: the per-row profile must show 0 GitHub calls for the four rows on run 2, got $R2GH: $(PROWS)"
# U9 — and #74, now HELD, is held by a look that writes nothing either: a run
# with the module switched off reads it again and leaves its bytes alone.
BRENV=(BR_OPT_OFF=unchanged); CLEARREC; TICK
[ "$(BYTES tproj-TK-74)" = "$B74" ] && ok || bad "U9: a held look must not write #74's record"
[ "$(BYTES tproj-TK-71)" = "$B71" ] && ok || bad "U9: a held look must not write #71's record"
# Red-first evidence, measured in this run: without the module the same
# unchanged rows read their issues again.
OFFREADS=$(( $(NISSUE 71) + $(NISSUE 74) ))
[ "$OFFREADS" -ge 2 ] && ok || bad "U1: with BR_OPT_OFF=unchanged run 2 must read issues #71/#74 again, got $OFFREADS"
echo "unchanged U1 fixture run 2: issue reads for the quiet rows with BR_OPT_OFF=unchanged = $OFFREADS; with the module = $U1_ON"

# ===========================================================================
# U10 — a row that arrives KEYLESS is skipped too (lead review NOTE at
# blocked-resolver.sh:8869). Discovery asks for no title, so #75 (branch
# feature/x, title "TK-75: ...") reaches br_one with no key, and br_one derives
# TK-75 from the title. The quiet look is marked under that derived key. The
# skip must fingerprint with the same key, so it runs after the derivation.
# ===========================================================================
brf_reset
PRADD 75 feature/x 'TK-75: the work'
CROW 75 'head-not-reapproved: BLOCK on the head'
HOLDCMT 75
TICK
[ -s "$LOOKS/o-tproj-75" ] && ok || bad "U10: run 1 must leave a ledger line for the keyless row (ls: $(ls -A "$LOOKS" 2>/dev/null | tr '\n' ' '); log: $(LOG | grep -E '75' | tail -3))"
grep -q 'tproj/o-tproj-75: discovery carried no ticket key — derived TK-75' "$H/logs/blocked-resolver.log" && ok \
  || bad "U10 setup: #75 must arrive keyless and derive TK-75: $(LOG | grep -E '75' | tail -3)"
# Without the derived-key cache (a restored hub, a first run on a new box), run 2
# sees #75 keyless at discovery again. The cache otherwise hides the order.
rm -f "$ST/tproj/o-tproj-75.tkey"
CLEARREC; TICK
[ "$(NISSUE 75)" = 0 ] && ok || bad "U10: THE NOTE: run 2 must skip the unchanged keyless row (issue reads: $(NISSUE 75); prof: $(PROF))"
[ "$(PFIELD unchanged)" = 1 ] && ok || bad "U10: run 2's prof: line must say unchanged=1, got '$(PROF)'"

# U11 — D43: with H unset the fingerprint builds no path from an empty root;
# the queue part reads `-` (lead review NOTE at unchanged.sh:85).
# HERMETIC (TEST-CHANGE, batch run 38112731835): the first cut read the queue
# line off `set -x`, and CI's traced shard sends xtrace elsewhere, so the trace
# never reached the capture. The fingerprint's own input is read instead: in
# this subshell `sha1sum` is `cat`, so the function prints the lines it would
# hash. H and HARNESS are both unset explicitly.
FP=$( ( unset H HARNESS; ST="$ST"; mc_row_get() { :; }; sha1sum() { cat; }
        . "$DIR/bin/lib/br/opt/unchanged.sh" 2>/dev/null
        br_opt_unchanged_fp tproj o-tproj-75 r - - TK-75 src tproj-TK-75 ) 2>/dev/null )
grep -q '/state/build-queue' <<<"$FP" && bad "U11: an empty H must not build /state/build-queue/...: $(grep -m1 build-queue <<<"$FP")" || ok
grep -qx "queue=- -" <<<"$FP" && ok || bad "U11: the queue part reads '- -' with H unset: $(tail -3 <<<"$FP")"
# ...and with H set, the queue part is two stat answers (here `- -`, no files),
# read from $H/state/build-queue, never from the root.
FP=$( ( H="$T/u11h"; export H; unset HARNESS; ST="$ST"; mc_row_get() { :; }; sha1sum() { cat; }
        mkdir -p "$H/state/build-queue/tproj"; : > "$H/state/build-queue/tproj/TK-75.json"
        . "$DIR/bin/lib/br/opt/unchanged.sh" 2>/dev/null
        br_opt_unchanged_fp tproj o-tproj-75 r - - TK-75 src tproj-TK-75 ) 2>/dev/null )
grep -qE '^queue=[0-9]+ -$' <<<"$FP" && ok || bad "U11: with H set the queue part stats \$H/state/build-queue: $(grep queue= <<<"$FP")"

# ===========================================================================
# U2/U3/U4/U5 — a change in head, verdict, reason or record re-arms the row.
# ===========================================================================
# RERUN <what> — run 1, then <what>, then run 2: #71 must be looked at again
# (it reads issue 71) and the other three stay skipped.
RERUN() {
  local label="$1"; shift
  brf_reset; U1FIX; TICK
  "$@"
  CLEARREC; TICK
  [ "$(NISSUE 71)" -ge 1 ] && ok || bad "$label: #71 must be looked at again (read issue 71), got $(NISSUE 71)"
  [ "$(NISSUE 74)" = 0 ] && ok || bad "$label: #74 must stay skipped, got $(NISSUE 74) issue reads"
  [ "$(PFIELD unchanged)" = 3 ] && ok || bad "$label: the other three stay skipped (unchanged=3), got '$(PROF)'"
}
RERUN "U2 (head)"    SETCOL 71 4 "$(HEAD_OF 71 moved)"
RERUN "U3 (verdict)" SETCOL 71 5 "$(HEAD_OF 71 reviewed)"
RERUN "U4 (reason)"  SETCOL 71 7 'review-changes-requested: a new park reason'
BUMP() { jq -c '.fixrounds = 1' "$ST/tproj/tproj-TK-71.json" > "$T/s.json" && mv "$T/s.json" "$ST/tproj/tproj-TK-71.json"; }
RERUN "U5 (record)"  BUMP

# ===========================================================================
# U6/U10 — an old look is looked at again; a rung clears the ledger.
# ===========================================================================
brf_reset; U1FIX; TICK
: > "$H/flags/blocked-resolver-observe"
# The look is one second past BR_UNCHANGED_RECHECK_S (1800 by default), and the
# HOLD comment is gone, so the hold lifts and the ladder runs.
awk -F'\t' -v OFS='\t' -v e="$((NOW - 1801))" '{ $3 = e; print }' "$LOOKS/o-tproj-71" > "$T/l" && mv "$T/l" "$LOOKS/o-tproj-71"
rm -f "$T/f/comments-71.json"
CLEARREC; TICK
[ "$(NISSUE 71)" -ge 1 ] && ok || bad "U6: a look older than BR_UNCHANGED_RECHECK_S must read issue 71 again, got $(NISSUE 71)"
LOG | grep -q 'HOLD lifted on o/tproj#71' && ok || bad "U6: the lifted hold must be logged: $(LOG | grep 'o-tproj-71' | tail -3)"
LOG | grep -qE 'o-tproj-71 \[conductor/head-not-reapproved\] -> ' && ok || bad "U10: #71 must reach the dispatch line: $(LOG | grep 'o-tproj-71' | tail -3)"
[ -e "$LOOKS/o-tproj-71" ] && bad "U10: a row that took a rung must lose its ledger line: $(cat "$LOOKS/o-tproj-71")" || ok
[ -s "$LOOKS/o-tproj-74" ] && ok || bad "U10: #74's ledger line must stay"

# ===========================================================================
# U7 — the two kill switches: every row is read again.
# ===========================================================================
brf_reset; U1FIX; TICK
: > "$H/flags/br-unchanged-off"; CLEARREC; TICK
[ "$(NISSUE 71)" -ge 1 ] && [ "$(NISSUE 74)" -ge 1 ] && ok || bad "U7: flags/br-unchanged-off must read #71 and #74 again, got $(NISSUE 71)/$(NISSUE 74)"
[ "$(PFIELD unchanged)" = 0 ] && ok || bad "U7: flags/br-unchanged-off must skip nothing, got '$(PROF)'"
brf_reset; U1FIX; TICK
BRENV=(BR_UNCHANGED_RECHECK_S=0); CLEARREC; TICK
[ "$(NISSUE 71)" -ge 1 ] && [ "$(NISSUE 74)" -ge 1 ] && ok || bad "U7: BR_UNCHANGED_RECHECK_S=0 must read #71 and #74 again, got $(NISSUE 71)/$(NISSUE 74)"
[ "$(PFIELD unchanged)" = 0 ] && ok || bad "U7: BR_UNCHANGED_RECHECK_S=0 must skip nothing, got '$(PROF)'"

# ===========================================================================
# U8 — a transient exit is never marked: the rebuild cap, and a merged-state
# read GitHub did not answer.
# ===========================================================================
brf_reset
PRADD 81; CROW 81 'merge-failed-twice: gh pr merge refused'
PRADD 82; CROW 82 'head-not-reapproved: BLOCK on the head'
# Records with a first_seen: the merged guard searches only with a park time.
SEED tproj-TK-81 '{}'; SEED tproj-TK-82 '{}'
echo 500 > "$T/f/search-status"
BRENV=(BR_REBUILDS_PER_TICK=0); TICK
# The search answers 500 for both rows, so this run proves the UNVERIFIABLE exit.
LOG | grep -q 'o-tproj-82 .*merged-state UNVERIFIABLE' && ok || bad "U8: #82 must stop on merged-state UNVERIFIABLE: $(LOG | grep o-tproj-82 | tail -2)"
[ -e "$LOOKS/o-tproj-82" ] && bad "U8: an UNVERIFIABLE exit must not be marked: $(cat "$LOOKS/o-tproj-82")" || ok
rm -f "$T/f/search-status"; CLEARREC; TICK
LOG | grep -q 'o-tproj-81 .*BR_REBUILDS_PER_TICK' && ok || bad "U8: #81 must be refused by the rebuild cap: $(LOG | grep o-tproj-81 | tail -2)"
[ -e "$LOOKS/o-tproj-81" ] && bad "U8: a rebuild-cap refusal must not be marked: $(cat "$LOOKS/o-tproj-81")" || ok
CLEARREC; TICK
[ "$(NGH 'search/issues')" -ge 2 ] && ok || bad "U8: the next run must look at #81 and #82 again (merged search), got $(NGH 'search/issues')"
[ "$(PFIELD unchanged)" = 0 ] && ok || bad "U8: nothing may be skipped, got '$(PROF)'"

# ===========================================================================
# U11 — the ledger is bounded: a line older than twice BR_UNCHANGED_RECHECK_S
# for a row no source offers any more is pruned by the next run that marks.
# ===========================================================================
brf_reset; U1FIX; TICK
printf '%s\theld\t%s\n' "$(printf '%040d' 0)" "$((NOW - 3660))" > "$LOOKS/o-tproj-99"
touch -d "@$((NOW - 3660))" "$LOOKS/o-tproj-99"
# The prune ran on run 1 and stamped .pruned; it is due again after 1800 s.
touch -d "@$((NOW - 1801))" "$LOOKS/.pruned"
SETCOL 74 4 "$(HEAD_OF 74 moved)"   # #74 is looked at again, and marked again
CLEARREC; TICK
[ -e "$LOOKS/o-tproj-99" ] && bad "U11: a ledger line older than 2 x BR_UNCHANGED_RECHECK_S must be pruned" || ok
[ -s "$LOOKS/o-tproj-71" ] && [ -s "$LOOKS/o-tproj-74" ] && ok || bad "U11: the live ledger lines must stay: $(ls -A "$LOOKS" | tr '\n' ' ')"
# Not due: a fresh .pruned marker keeps an old line until the window passes.
printf '%s\theld\t%s\n' "$(printf '%040d' 0)" "$((NOW - 3660))" > "$LOOKS/o-tproj-98"
touch -d "@$((NOW - 3660))" "$LOOKS/o-tproj-98"
SETCOL 74 4 "$(HEAD_OF 74 moved-again)"; CLEARREC; TICK
[ -e "$LOOKS/o-tproj-98" ] && ok || bad "U11: the prune runs at most once per BR_UNCHANGED_RECHECK_S"

echo "blocked-resolver-unchanged: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
