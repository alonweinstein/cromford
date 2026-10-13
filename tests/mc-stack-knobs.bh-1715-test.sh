#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# tests/mc-stack-knobs.bh-1715-test.sh — BH-1715 item 1: the two limits on an
# owed stacked-child restack (BH-1670) are lane-registry knobs, not literals.
#
#   MC_STACK_FOLLOW_TRIES     failed follows before the restack is dropped
#   MC_STACK_FOLLOW_GIVEUP_S  age after which it is dropped, whatever the count
#
# Both are `required` on catalog/lanes.d/merge-conductor.json and read through
# lane_knob in bin/lib/mc/rebase.sh `_mc_stack_follow_retry`. A value that does
# not resolve to a positive integer FAILS CLOSED: the follow is dropped with the
# one STACK_FOLLOW alert, whose text names the knob. Never a hidden 3, never an
# endless silent retry.
#
# Every retry below is driven through `mc_stack_follow` (the function
# conductor_settle and pr_worker call) with the child read answering 502, which
# is the "not done this time" arm that counts a try.
#
# D1 MUTATIONS, run once before the PR and confirmed red: put the literal `3`
# back in the tries test (B red), put `21600` back (C red), read the env
# fallback as `${MC_STACK_FOLLOW_TRIES:-3}` (D2 red).
#
# Run from anywhere: tests/mc-stack-knobs.bh-1715-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -f "$DIR/bin/lib/mc/rebase.sh" ] || exit 1   # impact: bin/lib/mc/rebase.sh
[ -f "$DIR/bin/lib/merge-conductor-lib.sh" ] || exit 1   # impact: bin/lib/merge-conductor-lib.sh (fx_mc_harness copies it; sourced below)
[ -f "$DIR/catalog/lanes.d/merge-conductor.json" ] || exit 1   # impact: catalog/lanes.d/merge-conductor.json
SLUG=example-org/demo-os
PHEAD=aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111
PURL="https://github.com/$SLUG/pull/1"

# ============================================================================
# A. The rendered registry carries both rows with default, min, max and a note.
# ============================================================================
# shellcheck source=tests/lib/rendered.sh
. "$DIR/tests/lib/rendered.sh" || exit 1
REG=$(rendered_registry)
knob() { jq -c --arg e "$1" '.lanes[]|select(.id=="merge-conductor")|.knobs[]|select(.env==$e)' "$REG"; }
K=$(knob MC_STACK_FOLLOW_TRIES)
[ -n "$K" ] && ok || bad "A: merge-conductor must register MC_STACK_FOLLOW_TRIES"
[ "$(jq -r '[.default,.min,.max,.required,.type]|@tsv' <<<"${K:-null}" 2>/dev/null)" = "$(printf '3\t1\t20\ttrue\tint')" ] \
  && ok || bad "A: MC_STACK_FOLLOW_TRIES must be int, default 3, min 1, max 20, required (got: $K)"
[ -n "$(jq -r '.note // empty' <<<"${K:-null}" 2>/dev/null)" ] && ok || bad "A: MC_STACK_FOLLOW_TRIES needs a note"
[ "$(jq -r '.read_in // empty' <<<"${K:-null}" 2>/dev/null)" = bin/lib/mc/rebase.sh ] \
  && ok || bad "A: MC_STACK_FOLLOW_TRIES must say it is read in bin/lib/mc/rebase.sh"
K=$(knob MC_STACK_FOLLOW_GIVEUP_S)
[ -n "$K" ] && ok || bad "A: merge-conductor must register MC_STACK_FOLLOW_GIVEUP_S"
[ "$(jq -r '[.default,.min,.max,.required,.type]|@tsv' <<<"${K:-null}" 2>/dev/null)" = "$(printf '21600\t600\t604800\ttrue\tint')" ] \
  && ok || bad "A: MC_STACK_FOLLOW_GIVEUP_S must be int, default 21600, min 600, max 604800, required (got: $K)"
[ -n "$(jq -r '.note // empty' <<<"${K:-null}" 2>/dev/null)" ] && ok || bad "A: MC_STACK_FOLLOW_GIVEUP_S needs a note"

# ── the scratch harness: the conductor lib and lane_knob over that registry ──
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
export HARNESS="$T/h"; fx_mc_harness "$DIR" "$T" || exit 1
cp "$DIR/bin/lib/gh-pr-merge.sh" "$DIR/bin/lib/gh-pr-create.sh" "$DIR/bin/lib/lane-gate.sh" \
   "$DIR/bin/lib/lanes-registry.sh" "$T/h/bin/lib/" || exit 1
export LANE_REGISTRY="$REG"
# The worker is never asked: a settings cache filled "now" answers every read,
# and one test below puts an operator row in it.
settings() { # settings <json-values-object>
  mkdir -p "$T/h/state"
  jq -nc --argjson fa "$(date +%s)" --argjson v "$1" '{fetched_at:$fa,values:$v,seeded:{}}' \
    > "$T/h/state/settings-cache.json"
}
settings '{}'
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-argv.txt"
case "\$*" in
  *"auth token"*) echo faketoken ;;
  *"rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"api -i -X GET repos/$SLUG/pulls/2"*) restpr --raw 502 '{"message":"bad gateway"}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
# shellcheck source=/dev/null
. "$T/h/bin/lib/lane-gate.sh"
command -v lane_knob >/dev/null || { echo "FAIL: lane_knob did not load"; exit 1; }
ACTIONS=1
PEND="$T/h/state/stack-follow/example-org_demo-os#2"
ALERTS="$T/h/logs/ALERTS.log"
fresh() { # fresh [since] — one owed follow, no alerts yet
  rm -rf "$T/h/state/stack-follow"; : > "$ALERTS"
  mc_stack_pending_put "$SLUG" 2 1 "$PURL" ticket/bh-1 "$PHEAD" main 0 "${1:-$(date +%s)}" \
    || bad "fixture: mc_stack_pending_put failed"
}
follow() { mc_stack_follow demo-os "$SLUG" 2 1 "$PURL" ticket/bh-1 "$PHEAD" main >/dev/null 2>&1; }
attempts() { cut -f6 "$PEND" 2>/dev/null; }
nalerts() { local n; n=$(grep -c 'could not be restacked' "$ALERTS" 2>/dev/null); echo "${n:-0}"; }

# ============================================================================
# B. MC_STACK_FOLLOW_TRIES=5 from the environment: four failed tries stay owed,
#    the fifth gives up with ONE alert that carries the resolved number.
# ============================================================================
unset MC_STACK_FOLLOW_TRIES MC_STACK_FOLLOW_GIVEUP_S
export MC_STACK_FOLLOW_TRIES=5
fresh
for _ in 1 2 3 4; do follow; done
[ "$(attempts)" = 4 ] && ok || bad "B: four failed tries under TRIES=5 must leave the follow owed with attempts=4 (got '$(attempts)', exists=$([ -e "$PEND" ] && echo y || echo n))"
[ "$(nalerts)" = 0 ] && ok || bad "B: no alert before the fifth try (got: $(cat "$ALERTS"))"
grep -q 'not done (try 4 of 5)' "$T/h/logs/merge-conductor.log" \
  && ok || bad "B: the retry line must carry the resolved number (got: $(grep 'demo-os#2' "$T/h/logs/merge-conductor.log" | tail -1))"
follow
[ -e "$PEND" ] && bad "B: the fifth failed try must drop the follow" || ok
[ "$(nalerts)" = 1 ] && ok || bad "B: exactly one alert on the give-up (got: $(cat "$ALERTS"))"
grep -q 'after 5 tries' "$ALERTS" && ok || bad "B: the alert must say 5 tries (got: $(cat "$ALERTS"))"

# B2. An operator SETTINGS ROW beats the environment: the knob is DB-driven.
settings '{"lane.merge-conductor.mc_stack_follow_tries":"2"}'
fresh
follow
[ "$(attempts)" = 1 ] && ok || bad "B2: one failed try under a settings row of 2 stays owed (got '$(attempts)')"
follow
[ -e "$PEND" ] && bad "B2: the settings row (2) must decide the give-up, not the env (5)" || ok
[ "$(nalerts)" = 1 ] && ok || bad "B2: exactly one alert (got: $(cat "$ALERTS"))"
settings '{}'
unset MC_STACK_FOLLOW_TRIES

# ============================================================================
# C. MC_STACK_FOLLOW_GIVEUP_S=600 and a follow owed for 700 s: the FIRST failed
#    try gives up with one alert.
# ============================================================================
export MC_STACK_FOLLOW_GIVEUP_S=600
fresh $(( $(date +%s) - 700 ))
follow
[ -e "$PEND" ] && bad "C: a follow older than GIVEUP_S=600 must be dropped on its first failed try" || ok
[ "$(nalerts)" = 1 ] && ok || bad "C: exactly one alert (got: $(cat "$ALERTS"))"
# …and one owed for 500 s is still inside the window.
fresh $(( $(date +%s) - 500 ))
follow
[ "$(attempts)" = 1 ] && ok || bad "C: a follow 500 s old under GIVEUP_S=600 stays owed (got '$(attempts)')"
unset MC_STACK_FOLLOW_GIVEUP_S

# ============================================================================
# D. The defaults come from the REGISTRY; with no registry answer and no env,
#    the first failure gives up LOUDLY and names the knob.
# ============================================================================
fresh
follow; follow
[ "$(attempts)" = 2 ] && ok || bad "D: two failed tries under the registry default (3) stay owed (got '$(attempts)')"
follow
[ -e "$PEND" ] && bad "D: the registry default of 3 must give up on the third try" || ok
[ "$(nalerts)" = 1 ] && ok || bad "D: exactly one alert at the registry default (got: $(cat "$ALERTS"))"
# D2. lane_knob absent (a box without lane-gate.sh) and no env: not a hidden 3.
unset -f lane_knob
fresh
follow
[ -e "$PEND" ] && bad "D2: an unresolved knob must never leave the follow retrying silently" || ok
[ "$(nalerts)" = 1 ] && ok || bad "D2: an unresolved knob gives up with exactly one alert (got: $(cat "$ALERTS"))"
grep -q 'MC_STACK_FOLLOW_TRIES' "$ALERTS" && ok || bad "D2: the alert must name the knob that did not resolve (got: $(cat "$ALERTS"))"
# D3. …and a value that is not a positive integer is the same fail-closed arm.
export MC_STACK_FOLLOW_TRIES=abc MC_STACK_FOLLOW_GIVEUP_S=21600
fresh
follow
[ -e "$PEND" ] && bad "D3: TRIES=abc must not be read as a number" || ok
grep -q "MC_STACK_FOLLOW_TRIES.*abc" "$ALERTS" && ok || bad "D3: the alert must say what the knob resolved to (got: $(cat "$ALERTS"))"
unset MC_STACK_FOLLOW_TRIES MC_STACK_FOLLOW_GIVEUP_S

# ============================================================================
# E. No literal is left: the give-up test reads no bare number.
# ============================================================================
FN=$(sed -n '/^_mc_stack_follow_retry() {/,/^}/p' "$DIR/bin/lib/mc/rebase.sh")
[ -n "$FN" ] && ok || bad "E: _mc_stack_follow_retry not found in bin/lib/mc/rebase.sh"
grep -qE -- '-ge (3|21600)\b|:-(3|21600)\}' <<<"$FN" && bad "E: a literal 3 / 21600 is still in the give-up test" || ok

echo "mc-stack-knobs.bh-1715-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
