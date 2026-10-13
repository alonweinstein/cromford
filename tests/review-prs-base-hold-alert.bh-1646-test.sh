#!/bin/bash
# BH-1646: review-prs alerts ONCE per (PR, head) when a stacked PR stays
# base-held for REVIEW_BASE_HOLD_ALERT_TICKS (default 6) consecutive ticks.
#   AT-1: default N=6 -> exactly one ALERTS line naming #77, the base and the url; more ticks add none.
#   AT-2: a new head resets the count; its own alert comes on its 6th hold.
#   AT-3: REVIEW_BASE_HOLD_ALERT_TICKS=2 fires on the 2nd hold.
#   AT-4: 5 holds -> no alert; every tick stays MERGED=no FENCED=1 with no gh merge.
#   AT-5: a main base counts nothing, alerts nothing, and reaches the merge.
# Drives the real `>>> review-prs merge` and `state write` blocks extracted from bin/review-prs.sh.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

awk '/^# >>> review-prs state write/{f=1;next} /^# <<< review-prs state write/{f=0} f' "$DIR/bin/review-prs.sh" > "$T/sw.sh"
awk '/^# >>> review-prs merge \(/{f=1;next} /^# <<< review-prs merge$/{exit} f' "$DIR/bin/review-prs.sh" > "$T/merge.sh"
[ -s "$T/sw.sh" ] && [ -s "$T/merge.sh" ] && ok || { echo "FAIL: could not extract blocks"; exit 1; }
mkdir -p "$T/h/logs" "$T/h/bin"
cp "$DIR/bin/alert-line.sh" "$T/h/bin/"

# tick <head> <base> [knob] — one merge_step call on the shared state file.
tick() {
  HARNESS="$T/h" PROJECT=demo SLUG=example-org/demo STATE="$T/state.json" LOG="$T/lane.log" \
  RP_BASE="$2" RP_KNOB="${3:-}" bash -c 'set -uo pipefail
    STAMP() { echo TS; }
    [ -n "$RP_KNOB" ] && export REVIEW_BASE_HOLD_ALERT_TICKS="$RP_KNOB"
    rp_prov_is_claude() { :; }; mc_queue_conductor_only() { return 1; }; mc_pr_queued() { return 1; }
    mc_pr_view() { case "$2" in .base.ref) echo "$RP_BASE" ;; *) echo OPEN ;; esac; }
    gh() { echo "$*" >> "$T_GH"; }; sleep() { :; }
    . "$0"; . "$1"
    rp_ticket_fence() { return 1; }; bg_review_hold() { return 1; }; hold_main_red() { return 1; }
    merge_step 77 "$RP_HEAD" claude
    printf "MERGED=%s FENCED=%s\n" "$MERGED" "${RP_FENCED:-0}"' "$T/sw.sh" "$T/merge.sh" >> "$T/out.txt" 2>>"$T/err.txt"
}
reset() { echo '{}' > "$T/state.json"; : > "$T/h/logs/ALERTS.log"; : > "$T/out.txt"; : > "$T/gh.txt"; }
alerts() { grep -c "base-held" "$T/h/logs/ALERTS.log"; }
export T_GH="$T/gh.txt"
H1=aaaaaaaa1111; H2=bbbbbbbb2222

# AT-4 then AT-1 on one head
reset; export RP_HEAD=$H1
for _ in 1 2 3 4 5; do tick $H1 ticket/bh-872; done
[ "$(alerts)" = 0 ] && ok || bad "AT-4: 5 holds must not alert (got $(alerts))"
[ "$(grep -c 'MERGED=no FENCED=1' "$T/out.txt")" = 5 ] && ok || bad "AT-4: every hold is MERGED=no FENCED=1 ($(cat "$T/out.txt"))"
[ ! -s "$T/gh.txt" ] && ok || bad "AT-4: a held PR reached gh merge"
tick $H1 ticket/bh-872
[ "$(alerts)" = 1 ] && ok || bad "AT-1: 6th hold must alert once (got $(alerts))"
grep "base-held" "$T/h/logs/ALERTS.log" | grep "#77" | grep "ticket/bh-872" | grep -q "https://github.com/example-org/demo/pull/77" \
  && ok || bad "AT-1: alert names PR, base and url ($(cat "$T/h/logs/ALERTS.log"))"
tick $H1 ticket/bh-872; tick $H1 ticket/bh-872
[ "$(alerts)" = 1 ] && ok || bad "AT-1: ticks past N add no alert (got $(alerts))"

# AT-2: new head
export RP_HEAD=$H2
for _ in 1 2 3 4 5; do tick $H2 ticket/bh-872; done
[ "$(alerts)" = 1 ] && ok || bad "AT-2: new head restarts at 0 (got $(alerts) after 5)"
tick $H2 ticket/bh-872
[ "$(alerts)" = 2 ] && ok || bad "AT-2: new head alerts on its 6th hold (got $(alerts))"
grep "base-held" "$T/h/logs/ALERTS.log" | tail -n 1 | grep -q "@bbbbbbb" && ok || bad "AT-2: second alert names the new head"

# AT-3: knob
reset; export RP_HEAD=$H1
tick $H1 ticket/bh-872 2
[ "$(alerts)" = 0 ] && ok || bad "AT-3: knob=2, first hold must not alert"
tick $H1 ticket/bh-872 2
[ "$(alerts)" = 1 ] && ok || bad "AT-3: knob=2 must alert on the 2nd hold (got $(alerts))"

# AT-5: main base
reset
for _ in 1 2 3 4 5 6 7; do tick $H1 main; done
[ "$(alerts)" = 0 ] && ok || bad "AT-5: main base must not alert"
[ "$(jq -r '.["77"].base_hold_count // "none"' "$T/state.json")" = none ] && ok || bad "AT-5: main base must not count"
grep -q "pr merge 77" "$T/gh.txt" && ok || bad "AT-5: main base must reach gh pr merge ($(cat "$T/err.txt"))"

echo "bh-1646 base-hold alert: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
