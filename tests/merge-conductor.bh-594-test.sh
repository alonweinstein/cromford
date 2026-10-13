#!/bin/bash
# tests/merge-conductor.bh-594-test.sh — BH-594 ask 3: a provenance park that a
# head-bound re-review BLOCKs is re-reasoned onto `head-not-reapproved`, and
# that re-reason IS a hand-off to bin/blocked-resolver.sh.
#
# THE GAP. mc_transition wrote the hand-off record only on a STATE change. A row
# already parked `BLOCKED_HUMAN provenance` that hb_block_park moves to
# `BLOCKED_HUMAN head-not-reapproved` is the same state, so the reason was
# rewritten, the "handed to bin/blocked-resolver.sh" line was logged, and no
# hand-off file was ever written. mc_handoff_sticky, the resolver's recovery
# loop and every reader that asks "is this park the resolver's" read that file.
#
# Driven against the REAL sourced lib: hb_block_park and mc_transition as the
# conductor tick calls them. hb_post (the PR comment) is replaced, because the
# comment is not what this suite is about and it would need a GitHub.
# Run from anywhere: tests/merge-conductor.bh-594-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
export HARNESS="$T/h"; fx_mc_harness "$DIR" "$T" || exit 1
[ -d "$DIR/bin/lib/mc" ] || exit 1   # impact: this suite runs when bin/lib/mc/ changes
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
hb_post() { printf '%s\n' "$*" >> "$T/posted.txt"; return 0; }

KEY="o/tproj#7"; URL="https://github.com/o/tproj/pull/7"
HD=1111111111111111111111111111111111111111
HF() { mc_handoff_file "$KEY"; }
PUT() { # PUT <state> <reason> — the row as the conductor left it
  : > "$MC_ROWS"; rm -f "$(HF)" "$(mc_handoff_rel_file "$KEY")"
  mc_row_put "$KEY" "$1" "$(( $(mc_now) - 300 ))" "$HD" "$HD" "-" "$2" "$URL"
}

# ---- (a) provenance park, head-bound re-review BLOCKs → a hand-off
PUT BLOCKED_HUMAN provenance
: > "$MC_LOG"
hb_block_park "$KEY" "$URL" - "$HD" "$HD" CLEAN "" "the head was not re-approved"
[ -f "$(HF)" ] && ok || bad "a: the re-reason onto head-not-reapproved must write the hand-off file ($(HF))"
[ "$(cut -f3 "$(HF)" 2>/dev/null)" = head-not-reapproved ] && ok || bad "a: the hand-off reason must be head-not-reapproved (got '$(cut -f3 "$(HF)" 2>/dev/null)')"
[ "$(cut -f2 "$(HF)" 2>/dev/null)" = "$HD" ] && ok || bad "a: the hand-off must name the parked head"
[ "$(mc_row_field "$KEY" 2)" = BLOCKED_HUMAN ] && ok || bad "a: the stored state stays BLOCKED_HUMAN (got $(mc_row_field "$KEY" 2))"
[ "$(mc_row_field "$KEY" 7)" = head-not-reapproved ] && ok || bad "a: the row's reason must be head-not-reapproved (got '$(mc_row_field "$KEY" 7)')"
[ "$(mc_state_display BLOCKED_HUMAN head-not-reapproved)" = BLOCKED_AGENT ] && ok || bad "a: it must DISPLAY as BLOCKED_AGENT"
grep -q "re-reasoned provenance -> head-not-reapproved" "$MC_LOG" && ok || bad "a: the re-reason must be logged ($(cat "$MC_LOG"))"
grep -q 'handed to bin/blocked-resolver.sh' "$MC_LOG" && ok || bad "a: the hand-off log line must still be written"
mc_handoff_sticky "$KEY" "$HD" && ok || bad "a: the park must now be sticky (the conductor leaves it to the resolver)"

# ---- (b) NEGATIVE: owned → owned (the resolver's own no-verdict → head-not-
#          reapproved path) must NOT re-record, or it clears the release marker
PUT BLOCKED_HUMAN no-verdict
mc_handoff_record "$KEY" "$HD" no-verdict "$URL"
mc_handoff_release "$KEY" blocked-resolver/test
BEFORE=$(cat "$(HF)")
sleep 1
mc_transition "$KEY" BLOCKED_HUMAN head-not-reapproved "$HD" "$HD" "$URL" BLOCK CLEAN - >/dev/null
[ -f "$(mc_handoff_rel_file "$KEY")" ] && ok || bad "b: owned→owned must keep the resolver's release marker"
[ "$(cat "$(HF)")" = "$BEFORE" ] && ok || bad "b: owned→owned must not rewrite the hand-off ($(cat "$(HF)"))"

# ---- (c) NEGATIVE: same reason again
PUT BLOCKED_HUMAN provenance
mc_transition "$KEY" BLOCKED_HUMAN provenance "$HD" "$HD" "$URL" BLOCK CLEAN - >/dev/null
[ -f "$(HF)" ] && bad "c: provenance→provenance is not a hand-off" || ok

# ---- (d) NEGATIVE: non-owned → non-owned
PUT BLOCKED_HUMAN provenance
mc_transition "$KEY" BLOCKED_HUMAN tightened "$HD" "$HD" "$URL" BLOCK CLEAN - >/dev/null
[ -f "$(HF)" ] && bad "d: provenance→tightened is not a hand-off" || ok

# ---- (e) the state-change path is untouched: WAIT_REVIEW → BLOCKED_HUMAN owned
PUT WAIT_REVIEW "waiting"
mc_transition "$KEY" BLOCKED_HUMAN head-not-reapproved "$HD" "$HD" "$URL" BLOCK CLEAN - >/dev/null
[ -f "$(HF)" ] && ok || bad "e: a state change into an owned park still writes the hand-off"

echo "merge-conductor.bh-594: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
