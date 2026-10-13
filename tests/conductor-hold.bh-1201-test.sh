#!/bin/bash
# tests/conductor-hold.bh-1201-test.sh — BH-1201.1 (BH-1382): the conductor HOLDS
# its two age pages under kill-switch/observe instead of sending them, flushes
# them capped when the mode returns, publishes the mode + held summary every
# tick, and reminds once every MC_HOLD_REMINDER_S while it is paused.
#
# WHAT IT DRIVES, AND WHY THAT AND NOT A GREP. The REAL mc_stuck_check,
# mc_budget_check, mc_hold_tick_begin and mc_hold_tick_end are called (D2), in a
# scratch harness with the REAL bin/jobs-client.sh and bin/lib/lane-gate.sh
# behind a fake curl. Every assertion is on what came OUT — the lane-alert stub's
# argv, the request bodies the stub recorded, $MC_LOG lines, $MC_STUCK_DIR
# contents and the row's `alerted` field — never on the source text (D3).
#
# THE DEFECT THIS PINS (the REPRO): before BH-1382, mc_stuck_check called
# mc_alert unconditionally once the TTL and identity checks passed, whatever the
# conductor's mode, and mc_budget_check's final `else` did the same. The hub's
# ALERTS.log carried 424 `mode=kill-switch` conductor pages 09-13..09-21 — pages
# about a lane an operator had deliberately switched off. Block 1 pins the
# behaviour that must NOT change (no mode = page, exactly as today); block 2 is
# the defect itself.
#
# Run from anywhere: tests/conductor-hold.bh-1201-test.sh   (exit 0 = all pass)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$DIR/bin/lib/merge-conductor-lib.sh" ] || exit 1   # impact: this suite sources the conductor lib
[ -d "$DIR/bin/lib/mc" ] || exit 1                       # impact: and drives log.sh + classify.sh through it
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1

# ONE clock read for the whole suite (bin/test-determinism-lint.sh's pin), and
# mc_now is overridden to it so every age in here is exact rather than "about".
NOW=$(date -u '+%s')

export HARNESS="$T/h"
fx_mc_harness "$DIR" "$T" || exit 1
mkdir -p "$T/h/bin/lib/jobs" "$T/h/env" "$T/h/state" "$T/h/flags" || exit 1
cp "$DIR/bin/jobs-client.sh" "$T/h/bin/jobs-client.sh" || exit 1
cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/" || exit 1
cp "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/lanes-registry.sh" "$T/h/bin/lib/" || exit 1
echo 'HARNESS_SECRET=test-secret' > "$T/h/env/global.env"

# The lane registry, rendered from catalog/lanes.d/ into the scratch tree: the
# two knobs this child adds (MC_FLUSH_MAX, MC_HOLD_REMINDER_S) are read through
# lane_knob, so a fixture without a real registry would prove the fallback and
# not the knob. `catalog/lanes.json` in the checkout is generated and git-ignored
# — it is never written from here.
mkdir -p "$T/reg/catalog" || exit 1
cp -r "$DIR/catalog/lanes.d" "$T/reg/catalog/" || exit 1
HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/lanes-build.sh" --root "$T/reg" --write >/dev/null 2>&1 \
  || { echo "FAIL: could not render the lane registry into the scratch tree"; exit 1; }
export LANE_REGISTRY="$T/reg/catalog/lanes.json"

# lane-alert.sh is RECORDED, never silenced: "did this page reach a human" is the
# whole question, and `$*` keeps --critical where an assertion can see it.
CALLS="$T/lane-alert.calls"
# It ALSO writes into \$REQ_SINK, interleaved with the curl stub's requests, so
# "the page went out before the release" is a fact about the recorded order
# rather than a reading of the source (block 4's page -> mark -> release check).
cat > "$T/h/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$CALLS"
[ -n "\${REQ_SINK:-}" ] && printf 'ALERT - %s\n' "\$*" >> "\$REQ_SINK"
exit 0
EOF
chmod +x "$T/h/bin/lane-alert.sh"
: > "$CALLS"

# The fake curl: answers the four conductor endpoints and /api/settings, records
# every request as "METHOD URL BODY" into \$REQ_SINK, and CURL_MODE=down is a
# transport failure (rc 7) — which is how the worker being down reaches
# _jobs_req's fail-open contract as rc 1.
REQ="$T/req.log"
mkdir -p "$T/fakebin"
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; BODY=""; METHOD=GET
while [ \$# -gt 0 ]; do
  case "\$1" in
    -X) METHOD="\$2"; shift 2 ;;
    --data-binary) BODY="\$2"; shift 2 ;;
    -H) shift 2 ;;
    *) shift ;;
  esac
done
[ -n "\${REQ_SINK:-}" ] && printf '%s %s %s\n' "\$METHOD" "\$URL" "\$BODY" >> "\$REQ_SINK"
case "\${CURL_MODE:-ok}" in down) exit 7 ;; esac
case "\$METHOD \$URL" in
  "PUT "*/api/settings)  printf '{"ok":true}\n200\n' ;;
  "GET "*/api/settings)
      printf '{"settings":%s}\n200\n' "\$(cat "$T/settings.json" 2>/dev/null || echo '[]')" ;;
  "PUT "*/api/conductor/held)          printf '{"ok":true}\n200\n' ;;
  "POST "*/api/conductor/held/release) printf '{"released":1}\n200\n' ;;
  "GET "*/api/conductor/held*)
      cat "$T/held.json" 2>/dev/null || printf '{"rows":[]}'
      printf '\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"
export HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid JOBS_BOX=test-box \
       JOBS_RETRIES=0 JOBS_ALERT=0 REQ_SINK="$REQ"
printf '[]' > "$T/settings.json"
printf '{"rows":[]}' > "$T/held.json"

# shellcheck source=/dev/null
. "$T/h/bin/jobs-client.sh" || exit 1
# shellcheck source=/dev/null
. "$T/h/bin/lib/lane-gate.sh" || exit 1
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh" || exit 1
mc_init
mc_now() { echo "$NOW"; }

U41=https://github.com/example-org/x/pull/41
U42=https://github.com/example-org/x/pull/42

# ── helpers ─────────────────────────────────────────────────────────────────
reset_io() { : > "$CALLS"; : > "$REQ"; }
ncalls()   { wc -l < "$CALLS" 2>/dev/null | tr -d ' '; }
nreq()     { grep -c "$1" "$REQ" 2>/dev/null || true; }
# body_n <pattern> <n> — the BODY column of the nth recorded request matching it
body_n()   { grep "$1" "$REQ" 2>/dev/null | sed -n "${2}p" | sed 's/^[^ ]* [^ ]* //'; }
logtail()  { tail -80 "$MC_LOG" 2>/dev/null; }
# A tick's own cache and counters, cleared so each block starts from a known one.
new_tick() {
  MC_TICK_ID="$1"
  rm -f "$MC_TICK_DIR/$MC_TICK_ID".* 2>/dev/null
  mkdir -p "$MC_TICK_DIR" 2>/dev/null
}
fresh_stuck() { scratch_rm "$MC_STUCK_DIR"; mkdir -p "$MC_STUCK_DIR"; }
nstuck()   { find "$MC_STUCK_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' '; }
# A settings-row change only reaches lane_knob through a COLD cache.
cold_settings() { rm -f "$T/h/state/settings-cache.json"; rm -rf "$T/h/state/lane-gate"; }
held_row() { # held_row <repo> <num> <state> <head> <kind> <text> <mark> <mode> <first>
  jq -nc --arg repo "$1" --arg num "$2" --arg state "$3" --arg head "$4" --arg kind "$5" \
        --arg text "$6" --arg mark "$7" --arg mode "$8" --arg f "$9" \
    '{repo:$repo,number:($num|tonumber),state:$state,head:$head,kind:$kind,
      text:$text,mark:$mark,mode:$mode,first_held_at:$f,last_seen_at:$f}'
}
set_held() { jq -sc '{rows:.,n_total:(.|length)}' > "$T/held.json"; }

echo "== block 1: no MC_MODE is not a hold — today's page, pinned =="
# The five other lanes that source this lib (merge-sweep, blocked-resolver,
# review-prs, batch-resolve, run-build) run with MC_MODE unset and must page
# exactly as they do today.
unset MC_MODE
new_tick t1; fresh_stuck; reset_io
mc_stuck_check example-org/x#41 WAIT_CI $((NOW-5400)) aaaaaaaa1111 "$U41" "checks pending"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "1 mc_stuck_check with MC_MODE unset gave rc=$RC, wanted 0 (page + re-kick)"
[ "$(ncalls)" = 1 ] && ok || bad "1b lane-alert was called $(ncalls) times, wanted 1"
grep -q 'STUCK: 90m' "$CALLS" && ok || bad "1c the page did not carry 'STUCK: 90m': $(cat "$CALLS")"
[ "$(nstuck)" = 1 ] && ok || bad "1d $(nstuck) markers in MC_STUCK_DIR, wanted 1"
[ "$(nreq 'PUT .*api/conductor/held')" = 0 ] && ok || bad "1e a held row was written with no mode set"

echo "== block 2: kill-switch HOLDS the stuck page =="
MC_MODE=kill-switch
new_tick t2; fresh_stuck; reset_io
mc_stuck_check example-org/x#41 WAIT_CI $((NOW-5400)) aaaaaaaa1111 "$U41" "checks pending"; RC=$?
[ "$RC" -eq 1 ] && ok || bad "2 mc_stuck_check under kill-switch gave rc=$RC, wanted 1 (no re-kick)"
[ "$(ncalls)" = 0 ] && ok || bad "2b lane-alert was called $(ncalls) times under kill-switch, wanted 0"
[ "$(nstuck)" = 0 ] && ok || bad "2c $(nstuck) markers written under kill-switch, wanted 0 (the page is unspent)"
[ "$(nreq 'PUT .*api/conductor/held')" = 1 ] && ok || bad "2d $(nreq 'PUT .*api/conductor/held') held PUTs, wanted 1"
B=$(body_n 'PUT .*api/conductor/held' 1)
[ "$(printf '%s' "$B" | jq -r '.kind')"   = STUCK ]        && ok || bad "2e kind: $B"
[ "$(printf '%s' "$B" | jq -r '.state')"  = WAIT_CI ]      && ok || bad "2f state: $B"
[ "$(printf '%s' "$B" | jq -r '.repo')"   = "example-org/x" ] && ok || bad "2g repo: $B"
[ "$(printf '%s' "$B" | jq -r '.number')" = 41 ]           && ok || bad "2h number: $B"
[ "$(printf '%s' "$B" | jq -r '.mode')"   = kill-switch ]  && ok || bad "2i mode: $B"
printf '%s' "$B" | jq -e '.text|test("STUCK: 90m")' >/dev/null && ok || bad "2j text: $B"
logtail | grep -q 'HELD (mode=kill-switch), not paged' && ok || bad "2k no HELD line in the conductor log"
# A SECOND CALL IN THE SAME TICK IS NOT A SECOND ROW. One PUT per newly held PR.
mc_stuck_check example-org/x#41 WAIT_CI $((NOW-5400)) aaaaaaaa1111 "$U41" "checks pending"; RC=$?
[ "$RC" -eq 1 ] && [ "$(nreq 'PUT .*api/conductor/held')" = 1 ] && ok \
  || bad "2l a second call this tick wrote $(nreq 'PUT .*api/conductor/held') PUTs, wanted 1"
# ADVERSARIAL: the match is the two exact words. A typo or the wrong case must
# PAGE — silently suppressing on a misspelling is the failure this lane exists
# to avoid.
ADV=0
for M in unknown Kill-switch "observe "; do
  ADV=$((ADV+1))
  new_tick "t2adv$ADV"; fresh_stuck; reset_io
  MC_MODE="$M"
  mc_stuck_check example-org/x#43 WAIT_CI $((NOW-5400)) aaaaaaaa2222 "$U41" "checks pending" >/dev/null
  [ "$(ncalls)" = 1 ] && ok || bad "2m MC_MODE='$M' suppressed the page ($(ncalls) calls), wanted 1"
done

echo "== block 3: kill-switch HOLDS the budget page, and leaves 'alerted' unspent =="
# READY's budget age is a state note by default since BH-4717, so it never
# reaches the hold. This block pins the HOLD machinery, which did not change,
# so it runs on the pre-BH-4717 note set, where a READY budget age still pages.
SAVED_NOTE_STATES="$MC_STATE_NOTE_STATES"
MC_STATE_NOTE_STATES="HEAD_MOVED STACKED_WAIT NEEDS_REBASE REBASING"
MC_MODE=kill-switch
new_tick t3; reset_io
mc_row_put example-org/x#42 READY $((NOW-1200)) bbbbbbbb1111 bbbbbbbb1111 "" - "$U42"
mc_budget_check example-org/x#42 READY $((NOW-1200)) "$U42" clean
[ "$(ncalls)" = 0 ] && ok || bad "3 lane-alert called $(ncalls) times on a held budget page, wanted 0"
[ -z "$(mc_row_get example-org/x#42 | cut -f6)" ] && ok \
  || bad "3b the row's alerted field was spent while held: '$(mc_row_get example-org/x#42 | cut -f6)'"
[ "$(nreq 'PUT .*api/conductor/held')" = 1 ] && ok || bad "3c $(nreq 'PUT .*api/conductor/held') held PUTs, wanted 1"
B=$(body_n 'PUT .*api/conductor/held' 1)
[ "$(printf '%s' "$B" | jq -r '.kind')" = BUDGET ] && ok || bad "3d kind: $B"
[ "$(printf '%s' "$B" | jq -r '.mark')" = "READY@$((NOW-1200))" ] && ok || bad "3e mark: $B"
# observe holds on the same terms, and the cache means no second row.
MC_MODE=observe
mc_budget_check example-org/x#42 READY $((NOW-1200)) "$U42" clean
[ "$(ncalls)" = 0 ] && [ "$(nreq 'PUT .*api/conductor/held')" = 1 ] && ok \
  || bad "3f observe: $(ncalls) calls / $(nreq 'PUT .*api/conductor/held') PUTs, wanted 0 / 1"
# actions PAGES, and spends the mark.
new_tick t3b; reset_io
MC_MODE=actions
mc_budget_check example-org/x#42 READY $((NOW-1200)) "$U42" clean
[ "$(ncalls)" = 1 ] && ok || bad "3g MC_MODE=actions gave $(ncalls) calls, wanted 1 (it pages)"
[ "$(mc_row_get example-org/x#42 | cut -f6)" = "READY@$((NOW-1200))" ] && ok \
  || bad "3h actions did not spend the mark: '$(mc_row_get example-org/x#42 | cut -f6)'"
# A STATE NOTE IS NEVER A PAGE AND NEVER A HOLD (BH-979 stays untouched).
new_tick t3c; reset_io
MC_MODE=kill-switch
mc_row_put example-org/x#45 HEAD_MOVED $((NOW-1800)) cccccccc1111 cccccccc1111 "" - "$U42"
mc_budget_check example-org/x#45 HEAD_MOVED $((NOW-1800)) "$U42" "moved"
[ "$(ncalls)" = 0 ] && [ "$(nreq 'PUT .*api/conductor/held')" = 0 ] && ok \
  || bad "3i a state note was held or paged: $(ncalls) calls / $(nreq 'PUT .*api/conductor/held') PUTs"
logtail | grep -q 'state note (not an alert)' && ok || bad "3j the state note did not reach the conductor log"
MC_STATE_NOTE_STATES="$SAVED_NOTE_STATES"

echo "== block 4: merge mode flushes, oldest first, capped =="
# THE FIXTURE: 12 held rows oldest first. Ten of them are walked (MC_FLUSH_MAX=10)
# and two are left for the next tick. One of the ten (row 4) has MOVED under the
# hold — its local row is on a different head — so it is released `moved` and
# never paged, which is why nine pages come out of ten walked rows.
# Row 6 and row 7 are the SAME PR held twice, as STUCK and as BUDGET: two rows on
# the PK, two pages, two releases.
new_tick t4; fresh_stuck; : > "$MC_ROWS"
MC_FLUSH_MAX=10
{
  held_row example-org/x 101 WAIT_CI h101 STUCK  "STUCK: 100m on h101 — waiting"  mk101 kill-switch 2026-09-13T00:00:00Z
  held_row example-org/x 102 READY   h102 BUDGET "20m in READY: clean"            "READY@900"   kill-switch 2026-09-13T01:00:00Z
  held_row example-org/x 103 WAIT_CI h103 STUCK  "STUCK: 95m on h103 — waiting"   mk103 observe     2026-09-13T02:00:00Z
  held_row example-org/x 104 WAIT_CI h104 STUCK  "STUCK: 99m on h104 — waiting"   mk104 kill-switch 2026-09-13T03:00:00Z
  held_row example-org/x 105 BLOCKED_HUMAN h105 BUDGET "0m in BLOCKED_HUMAN: park" "BLOCKED_HUMAN@1@20260913" kill-switch 2026-09-13T04:00:00Z
  held_row example-org/x 106 WAIT_CI h106 STUCK  "STUCK: 91m on h106 — waiting"   mk106 kill-switch 2026-09-13T05:00:00Z
  held_row example-org/x 106 WAIT_CI h106 BUDGET "45m in WAIT_CI: checks"         "WAIT_CI@1800" kill-switch 2026-09-13T06:00:00Z
  held_row example-org/x 107 WAIT_CI h107 STUCK  "STUCK: 92m on h107 — waiting"   mk107 kill-switch 2026-09-13T07:00:00Z
  held_row example-org/x 108 WAIT_CI h108 STUCK  "STUCK: 93m on h108 — waiting"   mk108 kill-switch 2026-09-13T08:00:00Z
  held_row example-org/x 109 WAIT_CI h109 STUCK  "STUCK: 94m on h109 — waiting"   mk109 kill-switch 2026-09-13T09:00:00Z
  held_row example-org/x 110 WAIT_CI h110 STUCK  "STUCK: 96m on h110 — waiting"   mk110 kill-switch 2026-09-13T10:00:00Z
  held_row example-org/x 111 WAIT_CI h111 STUCK  "STUCK: 97m on h111 — waiting"   mk111 kill-switch 2026-09-13T11:00:00Z
} | set_held
mc_row_put example-org/x#101 WAIT_CI $((NOW-6000)) h101 h101 "" - "$U41"
mc_row_put example-org/x#102 READY   $((NOW-1300)) h102 h102 "" - "$U41"
mc_row_put example-org/x#103 WAIT_CI $((NOW-5800)) h103 h103 "" - "$U41"
# 104 MOVED under the hold: the local row is on a new head.
mc_row_put example-org/x#104 WAIT_CI $((NOW-100))  h104moved h104moved "" - "$U41"
mc_row_put example-org/x#105 BLOCKED_HUMAN $((NOW-9000)) h105 h105 "" - "$U41"
mc_row_put example-org/x#106 WAIT_CI $((NOW-5600)) h106 h106 "" - "$U41"
mc_row_put example-org/x#107 WAIT_CI $((NOW-5700)) h107 h107 "" - "$U41"
mc_row_put example-org/x#108 WAIT_CI $((NOW-5900)) h108 h108 "" - "$U41"
mc_row_put example-org/x#109 WAIT_CI $((NOW-6100)) h109 h109 "" - "$U41"
mc_row_put example-org/x#110 WAIT_CI $((NOW-6200)) h110 h110 "" - "$U41"
mc_row_put example-org/x#111 WAIT_CI $((NOW-6300)) h111 h111 "" - "$U41"
MC_MODE=merge
reset_io
mc_hold_tick_begin
[ "$(ncalls)" = 9 ] && ok || bad "4 the flush sent $(ncalls) pages, wanted 9 (10 walked, one of them moved)"
[ "$(grep -c '(held since ' "$CALLS")" = 9 ] && ok \
  || bad "4b only $(grep -c '(held since ' "$CALLS") pages carried the held-since suffix, wanted 9"
# ORDER: the pages come out oldest first_held_at first.
ORDER=$(sed 's/.*(held since \([^ ]*\) under mode=.*/\1/' "$CALLS" | tr '\n' ' ')
[ "$ORDER" = "2026-09-13T00:00:00Z 2026-09-13T01:00:00Z 2026-09-13T02:00:00Z 2026-09-13T04:00:00Z 2026-09-13T05:00:00Z 2026-09-13T06:00:00Z 2026-09-13T07:00:00Z 2026-09-13T08:00:00Z 2026-09-13T09:00:00Z " ] \
  && ok || bad "4c pages were not in first_held_at order: $ORDER"
[ "$(nreq 'POST .*api/conductor/held/release')" = 10 ] && ok \
  || bad "4d $(nreq 'POST .*api/conductor/held/release') releases, wanted 10"
NPAGED=$(grep 'POST .*release' "$REQ" | sed 's/^[^ ]* [^ ]* //' | jq -r 'select(.why=="paged")|.number' | wc -l | tr -d ' ')
[ "$NPAGED" = 9 ] && ok || bad "4e $NPAGED releases said why=paged, wanted 9"
MOVED=$(grep 'POST .*release' "$REQ" | sed 's/^[^ ]* [^ ]* //' | jq -r 'select(.why=="moved")|.number' | tr '\n' ' ')
[ "$MOVED" = "104 " ] && ok || bad "4f the moved release named '$MOVED', wanted '104 '"
grep -q 'h104' "$CALLS" && bad "4g the moved row was paged anyway" || ok
# ORDER OF SIDE EFFECTS: page -> mark -> release, never release first. Both the
# alert and the release land in $REQ in the order they happened, so the line
# numbers answer it.
A101=$(grep -n 'ALERT .*example-org/x#101' "$REQ" | head -1 | cut -d: -f1)
R101=$(grep -n 'POST .*release.*"number":101' "$REQ" | head -1 | cut -d: -f1)
{ [ -n "$A101" ] && [ -n "$R101" ] && [ "$A101" -lt "$R101" ]; } && ok \
  || bad "4h #101 was released (line $R101) before it was paged (line $A101)"
[ -e "$MC_STUCK_DIR/mk101" ] && ok || bad "4h2 the STUCK mark mk101 was not recorded"
[ "$(nstuck)" = 6 ] && ok || bad "4i $(nstuck) STUCK marks on disk, wanted 6 (the six STUCK rows that paged)"
[ "$(mc_row_get example-org/x#102 | cut -f6)" = "READY@900" ] && ok \
  || bad "4j the BUDGET mark was not written to the row: '$(mc_row_get example-org/x#102 | cut -f6)'"
[ "$(mc_row_get example-org/x#106 | cut -f6)" = "WAIT_CI@1800" ] && ok \
  || bad "4k the STUCK+BUDGET pair's BUDGET mark is missing: '$(mc_row_get example-org/x#106 | cut -f6)'"
[ "$(grep -c 'example-org/x#106' "$CALLS")" = 2 ] && ok \
  || bad "4l the PR held as STUCK and BUDGET paged $(grep -c 'example-org/x#106' "$CALLS") times, wanted 2"
grep -q -- '--critical' "$CALLS" && ok || bad "4m the park's page was not critical: $(grep 105 "$CALLS")"
[ "$(grep -c -- '--critical' "$CALLS")" = 1 ] && ok \
  || bad "4n $(grep -c -- '--critical' "$CALLS") critical pages, wanted 1 (the park only)"
logtail | grep -q 'flush: 2 held pages remain, next tick' && ok \
  || bad "4o the log does not say 2 held pages remain"
# A FLUSHED PARK DOES NOT PAGE AGAIN SECONDS LATER, IN THIS SAME TICK. The park
# was held on 09-13 and its held mark carries that day, because a park pages once
# per UTC day. Recording that stale day would leave mc_budget_check's own mark —
# today's — unmatched when the project fan-out reaches the same PR moments after
# the flush, with the held row already released and nothing left to suppress it:
# two --critical pages for one held row, the second of them carrying text frozen
# nine days ago. What the flush spends is the mark for the row as it stands now.
F6=$(mc_row_get example-org/x#105 | cut -f6)
case "$F6" in
  "BLOCKED_HUMAN@$((NOW-9000))@"[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ok ;;
  *) bad "4p the flushed park's mark is '$F6', wanted BLOCKED_HUMAN@$((NOW-9000))@<today>" ;;
esac
reset_io
mc_budget_check example-org/x#105 BLOCKED_HUMAN $((NOW-9000)) "$U41" park
[ "$(ncalls)" = 0 ] && ok \
  || bad "4q the flushed park paged again in the same tick ($(ncalls) calls): $(cat "$CALLS")"
# The non-park BUDGET mark is still recorded verbatim (4j above), so a state
# entry that ends still pages when it next ages.

echo "== block 5: the rest flush next tick; a cached row never pages twice =="
new_tick t5; reset_io
{
  held_row example-org/x 110 WAIT_CI h110 STUCK "STUCK: 96m on h110 — waiting" mk110 kill-switch 2026-09-13T10:00:00Z
  held_row example-org/x 111 WAIT_CI h111 STUCK "STUCK: 97m on h111 — waiting" mk111 kill-switch 2026-09-13T11:00:00Z
} | set_held
MC_MODE=merge
mc_hold_tick_begin
[ "$(ncalls)" = 2 ] && ok || bad "5 the second tick sent $(ncalls) pages, wanted 2"
[ "$(nreq 'POST .*api/conductor/held/release')" = 2 ] && ok \
  || bad "5b $(nreq 'POST .*api/conductor/held/release') releases on the second tick, wanted 2"
# A ROW THE FLUSH OWNS IS SKIPPED BY THE PAGERS, in every mode. The 12-row
# fixture under kill-switch flushes nothing and suppresses nothing twice.
new_tick t5b; fresh_stuck; reset_io
{
  held_row example-org/x 201 WAIT_CI h201 STUCK "STUCK: 100m on h201 — waiting" mk201 kill-switch 2026-09-14T00:00:00Z
  held_row example-org/x 202 WAIT_CI h202 STUCK "STUCK: 100m on h202 — waiting" mk202 kill-switch 2026-09-14T01:00:00Z
} | set_held
MC_MODE=kill-switch
mc_hold_tick_begin
[ "$(ncalls)" = 0 ] && ok || bad "5c kill-switch flushed $(ncalls) pages, wanted 0"
[ "$(nreq 'POST .*api/conductor/held/release')" = 0 ] && ok \
  || bad "5d kill-switch released $(nreq 'POST .*api/conductor/held/release') rows, wanted 0"
mc_row_put example-org/x#201 WAIT_CI $((NOW-6000)) h201 h201 "" - "$U41"
reset_io
mc_stuck_check example-org/x#201 WAIT_CI $((NOW-6000)) h201 "$U41" "checks pending"; RC=$?
[ "$RC" -eq 1 ] && ok || bad "5e a cached held row gave rc=$RC from mc_stuck_check, wanted 1 (no re-kick)"
[ "$(ncalls)" = 0 ] && [ "$(nreq 'PUT .*api/conductor/held')" = 0 ] && ok \
  || bad "5f a cached held row paged or re-held: $(ncalls) calls / $(nreq 'PUT .*api/conductor/held') PUTs"
# ... and in MERGE mode too: the flush owns it, not the pager.
MC_MODE=merge
reset_io
mc_stuck_check example-org/x#201 WAIT_CI $((NOW-6000)) h201 "$U41" "checks pending"; RC=$?
[ "$RC" -eq 1 ] && [ "$(ncalls)" = 0 ] && ok \
  || bad "5g under merge a cached row gave rc=$RC and $(ncalls) calls, wanted 1 / 0"
# ONE PAGE PER ROW IN THE TICK THE MODE RETURNS, end to end: hold a real STUCK
# row (so the held mark is the one mc_stuck_check itself computes), flush it, and
# let the pager run again in that same tick the way the project fan-out does.
# The marker the flush wrote is the one that pager looks for, so the page is
# already spent and it neither pages nor re-kicks.
new_tick t5c; fresh_stuck; reset_io
printf '{"rows":[]}' > "$T/held.json"
MC_MODE=kill-switch
mc_hold_tick_begin
mc_row_put example-org/x#501 WAIT_CI $((NOW-5400)) h501 h501 "" - "$U41"
mc_stuck_check example-org/x#501 WAIT_CI $((NOW-5400)) h501 "$U41" "checks pending" >/dev/null
MK=$(body_n 'PUT .*api/conductor/held' 1 | jq -r '.mark')
{ [ -n "$MK" ] && [ "$MK" = "$(basename "$MK")" ]; } && ok \
  || bad "5h the held STUCK mark is not a leaf name: '$MK'"
{ held_row example-org/x 501 WAIT_CI h501 STUCK "STUCK: 90m on h501 — waiting" "$MK" kill-switch 2026-09-15T00:00:00Z; } | set_held
new_tick t5d; reset_io
MC_MODE=merge
mc_hold_tick_begin
mc_stuck_check example-org/x#501 WAIT_CI $((NOW-5400)) h501 "$U41" "checks pending"; RC=$?
[ "$(ncalls)" = 1 ] && ok \
  || bad "5i the flushed STUCK row paged $(ncalls) times in the tick that flushed it, wanted 1"
[ "$RC" -eq 1 ] && ok || bad "5j the flush's own page was re-kicked (rc=$RC), wanted 1"

echo "== block 6: the summary line and the two published settings rows =="
new_tick t6; fresh_stuck; reset_io
printf '%s\n' "$NOW" > "$MC_STATE_DIR/hold-reminder-at"   # block 7 owns the reminder
MC_MODE=kill-switch
printf '{"rows":[]}' > "$T/held.json"
mc_hold_tick_begin
mc_stuck_check example-org/x#301 WAIT_CI $((NOW-5400)) h301 "$U41" "checks pending" >/dev/null
reset_io
mc_hold_tick_end
logtail | grep -qE 'mode=kill-switch: 1 PRs would have paged \(STUCK 1' && ok \
  || bad "6 no summary line: $(logtail | tail -3)"
logtail | grep -E 'PRs would have paged' | tail -1 | grep -q -- ' — suppressed$' && ok \
  || bad "6b the summary line does not end in ' — suppressed'"
[ "$(nreq 'PUT .*api/settings')" = 2 ] && ok || bad "6c $(nreq 'PUT .*api/settings') settings PUTs, wanted 2"
B1=$(body_n 'PUT .*api/settings' 1); B2=$(body_n 'PUT .*api/settings' 2)
[ "$(printf '%s' "$B1" | jq -r '.key')" = "merge-conductor.mode" ] \
  && [ "$(printf '%s' "$B1" | jq -r '.value')" = "kill-switch" ] && ok || bad "6d mode row: $B1"
[ "$(printf '%s' "$B2" | jq -r '.key')" = "merge-conductor.held_pages" ] \
  && [ "$(printf '%s' "$B2" | jq -r '.value')" = "1 WAIT_CI=1" ] && ok || bad "6e held row: $B2"
[ "$(ncalls)" = 0 ] && ok || bad "6f the summary tick paged $(ncalls) times, wanted 0"
# A merge-mode tick publishes too, with 0, and writes NO summary line.
new_tick t6b; reset_io
MC_MODE=merge
mc_hold_tick_end
B1=$(body_n 'PUT .*api/settings' 1); B2=$(body_n 'PUT .*api/settings' 2)
[ "$(printf '%s' "$B1" | jq -r '.value')" = "merge" ] && ok || bad "6g merge mode row: $B1"
[ "$(printf '%s' "$B2" | jq -r '.value')" = "0" ] && ok || bad "6h merge held row: $B2"
grep -q 'mode=merge: .* would have paged' <<<"$(logtail)" && bad "6i a merge tick wrote a suppressed-summary line" || ok
# THE PUBLISHED ROW AND THE REMINDER ARE ABOUT WHAT IS HELD, NOT ABOUT THIS
# TICK'S NEW HOLDS. On the second and every later tick of a pause nothing new is
# held — every aged PR already has its row — so a count of the tick's counters is
# 0 while the worker holds the whole backlog. The operator's only view of a
# nine-day pause would say it holds nothing. This is the tick that proves it:
# three rows held by the worker, nothing new this tick.
new_tick t6c; fresh_stuck
{
  held_row example-org/x 601 WAIT_CI h601 STUCK  "STUCK: 100m on h601 — waiting" mk601 kill-switch 2026-09-14T00:00:00Z
  held_row example-org/x 602 WAIT_CI h602 STUCK  "STUCK: 101m on h602 — waiting" mk602 kill-switch 2026-09-14T01:00:00Z
  held_row example-org/x 603 READY   h603 BUDGET "20m in READY: clean"           "READY@900" kill-switch 2026-09-14T02:00:00Z
} | set_held
MC_MODE=kill-switch
mc_hold_tick_begin
rm -f "$MC_STATE_DIR/hold-reminder-at"
reset_io
mc_hold_tick_end
logtail | grep -q 'mode=kill-switch: 0 PRs would have paged' && ok \
  || bad "6j the tick's own counters are not 0 on a tick that held nothing new: $(logtail | tail -3)"
B2=$(body_n 'PUT .*api/settings' 2)
[ "$(printf '%s' "$B2" | jq -r '.key')" = "merge-conductor.held_pages" ] \
  && [ "$(printf '%s' "$B2" | jq -r '.value')" = "3 READY=1 WAIT_CI=2" ] && ok \
  || bad "6k the published held row says '$(printf '%s' "$B2" | jq -r '.value')', wanted '3 READY=1 WAIT_CI=2'"
grep -q 'is holding 3 pages (STUCK 2, HEAD_MOVED 0, BLOCKED_HUMAN 0, RED_TWICE 0, READY 1, WAIT_CI 2)' "$CALLS" && ok \
  || bad "6l the PAUSED reminder does not report the three held pages: $(cat "$CALLS")"
printf '{"rows":[]}' > "$T/held.json"

echo "== block 7: the PAUSED reminder, once every MC_HOLD_REMINDER_S =="
MC_MODE=kill-switch
new_tick t7; reset_io
rm -f "$MC_STATE_DIR/hold-reminder-at"
cold_settings
mc_hold_tick_end
[ "$(ncalls)" = 1 ] && ok || bad "7 no stamp gave $(ncalls) reminders, wanted 1"
grep -q 'PAUSED' "$CALLS" && ok || bad "7b the reminder did not say PAUSED: $(cat "$CALLS")"
grep -q -- '--critical' "$CALLS" && bad "7c the PAUSED reminder was sent critical" || ok
[ "$(cat "$MC_STATE_DIR/hold-reminder-at" 2>/dev/null)" = "$NOW" ] && ok \
  || bad "7d the stamp was not written after the send: '$(cat "$MC_STATE_DIR/hold-reminder-at" 2>/dev/null)'"
new_tick t7b; reset_io
printf '%s\n' "$((NOW-100))" > "$MC_STATE_DIR/hold-reminder-at"
mc_hold_tick_end
[ "$(ncalls)" = 0 ] && ok || bad "7e a 100s-old stamp still sent $(ncalls) reminders, wanted 0"
new_tick t7c; reset_io
printf '%s\n' "$((NOW-21601))" > "$MC_STATE_DIR/hold-reminder-at"
mc_hold_tick_end
[ "$(ncalls)" = 1 ] && ok || bad "7f a 21601s-old stamp sent $(ncalls) reminders, wanted 1"
[ "$(cat "$MC_STATE_DIR/hold-reminder-at" 2>/dev/null)" = "$NOW" ] && ok \
  || bad "7g the stamp was not refreshed: '$(cat "$MC_STATE_DIR/hold-reminder-at" 2>/dev/null)'"
# THE KNOB IS A SETTINGS ROW, resolved through lane_knob — not a literal.
new_tick t7d; reset_io
jq -nc '[{key:"lane.merge-conductor.mc_hold_reminder_s",value:"600"}]' > "$T/settings.json"
cold_settings
printf '%s\n' "$((NOW-601))" > "$MC_STATE_DIR/hold-reminder-at"
mc_hold_tick_end
[ "$(ncalls)" = 1 ] && ok \
  || bad "7h lane.merge-conductor.mc_hold_reminder_s=600 with a 601s stamp sent $(ncalls), wanted 1"
printf '[]' > "$T/settings.json"; cold_settings
printf '%s\n' "$NOW" > "$MC_STATE_DIR/hold-reminder-at"

echo "== block 8: every OTHER mc_alert call site still pages under kill-switch =="
MC_MODE=kill-switch
reset_io
mc_alert example-org/x#51 MERGED       "DEPLOY_VERIFY: the merge sha is not serving — $U41"
mc_alert example-org/x#52 MERGED       "landed while the conductor was off — $U41"
mc_alert example-org/x#53 NEEDS_REBASE "IDENTITY_NOT_PERMITTED: the push identity is refused on the base — $U41"
mc_alert example-org/x#54 CLOSED       "closed unmerged and its issue is still open — $U41"
mc_alert example-org/x#55 WAIT_CI      "CI_ABSENT_TWICE: no check has reported on two heads — $U41"
mc_alert example-org/x#56 WAIT_CI      "CI_FLAKE_TWICE: the same test flaked twice — $U41"
mc_alert example-org/x#57 NEEDS_REBASE "contested: another PR holds this path — $U41"
mc_alert example-org/x#58 QUEUED       "mergify is degraded — $U41"
mc_alert example-org/x#59 STACKED_WAIT "PDG hold: the parent PR has not merged — $U41"
[ "$(ncalls)" = 9 ] && ok || bad "8 $(ncalls) of the nine other call sites reached the stub under kill-switch"
[ "$(nreq 'PUT .*api/conductor/held')" = 0 ] && ok \
  || bad "8b a direct mc_alert was held: $(nreq 'PUT .*api/conductor/held') PUTs"

echo "== block 9: the worker down is logged, never counted as held =="
export CURL_MODE=down
MC_MODE=kill-switch
new_tick t9; fresh_stuck; reset_io
mc_hold_tick_begin
logtail | grep -q 'held pages unreadable this tick (rc=1)' && ok \
  || bad "9 the outage was not logged: $(logtail | tail -3)"
mc_stuck_check example-org/x#61 WAIT_CI $((NOW-5400)) h61 "$U41" "checks pending"; RC=$?
[ "$(ncalls)" = 0 ] && ok || bad "9b the outage paged $(ncalls) times under kill-switch, wanted 0"
logtail | grep -q 'held_page_put rc=1' && ok || bad "9c the failed PUT did not name its rc"
[ "$(find "$MC_TICK_DIR" -name "t9.hold-count.*" 2>/dev/null | wc -l | tr -d ' ')" = 0 ] && ok \
  || bad "9d a failed PUT was counted as held"
mc_hold_tick_end
logtail | grep -q 'mode=kill-switch: 0 PRs would have paged' && ok \
  || bad "9e the summary did not say 0 held: $(logtail | tail -3)"
# Under merge the same outage is today's behaviour: an empty cache, one page.
new_tick t9b; fresh_stuck; reset_io
MC_MODE=merge
mc_hold_tick_begin
mc_stuck_check example-org/x#62 WAIT_CI $((NOW-5400)) h62 "$U41" "checks pending"; RC=$?
[ "$RC" -eq 0 ] && [ "$(ncalls)" = 1 ] && [ "$(nstuck)" = 1 ] && ok \
  || bad "9f merge mode during an outage gave rc=$RC, $(ncalls) calls, $(nstuck) markers; wanted 0 / 1 / 1"
unset CURL_MODE

echo "== block 10: a mark read back from the API is a leaf name, never a path =="
# THE MARK MAKES A FILENAME ON THE HUB, AS ROOT. The conductor sends a basename,
# but the row comes back from an API that stores whatever string it was given, so
# the flush treats it as untrusted: a `../../` mark must not reach outside
# MC_STUCK_DIR, and it must not be able to name an existing file and quietly flip
# the flush's mark-already-stands guard, which would release the row as paged
# without a page having been sent.
new_tick t10; fresh_stuck; reset_io
{
  held_row example-org/x 401 WAIT_CI h401 STUCK  "STUCK: 100m on h401 — waiting" "../../pwned-by-mark" kill-switch 2026-09-15T00:00:00Z
  held_row example-org/x 402 READY   h402 BUDGET "20m in READY: clean"           "../../../etc/passwd" kill-switch 2026-09-15T01:00:00Z
} | set_held
mc_row_put example-org/x#401 WAIT_CI $((NOW-6000)) h401 h401 "" - "$U41"
mc_row_put example-org/x#402 READY   $((NOW-1300)) h402 h402 "" - "$U41"
MC_MODE=merge
mc_hold_tick_begin
[ ! -e "$MC_STUCK_DIR/../../pwned-by-mark" ] && ok \
  || bad "10 the flush wrote through the mark to $MC_STUCK_DIR/../../pwned-by-mark"
[ -e "$MC_STUCK_DIR/pwned-by-mark" ] && ok \
  || bad "10b the mark was not reduced to a leaf inside MC_STUCK_DIR: $(ls "$MC_STUCK_DIR")"
[ "$(ncalls)" = 2 ] && ok \
  || bad "10c $(ncalls) pages went out for the two traversal marks, wanted 2 (neither is silently released)"
[ "$(mc_row_get example-org/x#402 | cut -f6)" = "passwd" ] && ok \
  || bad "10d the BUDGET mark was recorded unreduced: '$(mc_row_get example-org/x#402 | cut -f6)'"
printf '{"rows":[]}' > "$T/held.json"

echo "conductor-hold-bh-1201: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
