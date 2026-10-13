#!/bin/bash
# tests/cadence-backstop.c2-test.sh — C2 (2026-09-24): with webhooks live, the
# merge conductor's */5 and the blocked resolver's */10 cron ticks are backstops,
# stretched by a settings ROW, not by editing the schedule.
#
# PINNED:
#   1. the first tick runs and stamps; a tick inside the backstop is skipped with
#      one SKIP line in logs/cadence-backstop.log; a tick past it runs (with 30s
#      of cron-jitter slack, so 15 minutes never becomes 20);
#   2. a wake — a file in a --wake-dir newer than the last run — beats the clock;
#   3. the knob: 0 is every tick (pre-C2), a value is read, defaults are 60/30
#      (BH-5521 made the conductor's an hourly sweep);
#   4. FAIL-OPEN: an unknown lane, a garbage stamp, a clock in the future or a
#      state dir that cannot be written all RUN the lane — rc 3 only ever means
#      "decided to skip" (lead review of #2231: it was rc 1, which a set -u
#      abort or a crash also returns, and the cron line read those as skips);
#   5. the two cron fragments put the gate after the hub lease and before the
#      lane, with the conductor's hand-off dir as the resolver's wake;
#   6. the cron line skips the lane ONLY on rc 3: a missing gate (126/127), a
#      gate that aborted (rc 1) or any other rc runs the lane.
#
# Run from anywhere: bash tests/cadence-backstop.c2-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
GATE="$DIR/bin/lib/cadence-backstop.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"; mkdir -p "$H/logs" "$T/wake"
gate() { env -i PATH="/usr/bin:/bin" HARNESS="$H" ${GENV:-} bash "$GATE" "$@" >/dev/null 2>&1; }
setlast() { mkdir -p "$H/state/cadence-backstop"; printf '%s\n' "$(( $(date -u +%s) - $2 ))" > "$H/state/cadence-backstop/$1.last"; }

[ -x "$GATE" ] && ok || bad "0: bin/lib/cadence-backstop.sh must exist and be executable (the cron line runs it)"

# ── 1. the clock ────────────────────────────────────────────────────────────
scratch_rm "$H/state"
gate merge-conductor; [ $? = 0 ] && ok || bad "1a: the first tick (no stamp) must run"
[ -s "$H/state/cadence-backstop/merge-conductor.last" ] && ok || bad "1b: a run must stamp"
gate merge-conductor; [ $? = 3 ] && ok || bad "1c: a tick right after a run must be skipped"
grep -q 'SKIP merge-conductor' "$H/logs/cadence-backstop.log" 2>/dev/null && ok || bad "1d: a skip must say so in logs/cadence-backstop.log"
setlast merge-conductor 600;  gate merge-conductor; [ $? = 3 ] && ok || bad "1e: 10 min into a 15 min backstop must skip"
# TEST-CHANGE BH-5521: the default is 60 min now (tests/conductor-events.bh-5521-test.sh
# S1), so the 15-min slack case names its row.
setlast merge-conductor 875;  GENV="CADENCE_BACKSTOP_MIN_MERGE_CONDUCTOR=15" gate merge-conductor; [ $? = 0 ] && ok || bad "1f: 14m35s is inside the 30s cron-jitter slack of a 15 min row and must run"
setlast merge-conductor 3600; gate merge-conductor; [ $? = 0 ] && ok || bad "1g: an hour since the last run must run"
setlast blocked-resolver 1200; gate blocked-resolver; [ $? = 3 ] && ok || bad "1h: the resolver's default backstop is 30 min — 20 min must skip"
setlast blocked-resolver 1790; gate blocked-resolver; [ $? = 0 ] && ok || bad "1i: 29m50s must run the resolver"

# ── 2. a wake beats the clock ───────────────────────────────────────────────
setlast blocked-resolver 60
touch -d '-10 minutes' "$T/wake/old" 2>/dev/null || touch "$T/wake/old"
gate blocked-resolver --wake-dir "$T/wake"; [ $? = 3 ] && ok || bad "2a: a hand-off OLDER than the last run is not a wake"
sleep 1; touch "$T/wake/new-handoff"
gate blocked-resolver --wake-dir "$T/wake"; [ $? = 0 ] && ok || bad "2b: a hand-off newer than the last run must let the tick through"
grep -q 'RUN blocked-resolver: wake pending' "$H/logs/cadence-backstop.log" && ok || bad "2c: a wake run must say why"
gate blocked-resolver --wake-dir "$T/wake"; [ $? = 3 ] && ok || bad "2d: the same wake is consumed by the run it caused"
gate blocked-resolver --wake-dir "$T/no-such-dir"; [ $? = 3 ] && ok || bad "2e: a missing wake dir is no wake (and no error)"
# The conductor rewrites <handoff>.logged hourly for every parked PR — a log
# marker, not a new hand-off. It must never wake the resolver (review of #2231).
sleep 1; touch "$T/wake/new-handoff.logged"
gate blocked-resolver --wake-dir "$T/wake"; [ $? = 3 ] && ok || bad "2f: a rewritten *.logged marker is not a wake"

# ── 3. the knob ─────────────────────────────────────────────────────────────
setlast merge-conductor 30
GENV="CADENCE_BACKSTOP_MIN_MERGE_CONDUCTOR=0" gate merge-conductor; [ $? = 0 ] && ok || bad "3a: 0 = every tick runs, as before C2"
setlast merge-conductor 300
GENV="CADENCE_BACKSTOP_MIN_MERGE_CONDUCTOR=5" gate merge-conductor; [ $? = 0 ] && ok || bad "3b: a 5 min row makes a 5 min-old run due"
setlast merge-conductor 300
GENV="CADENCE_BACKSTOP_MIN_MERGE_CONDUCTOR=abc" gate merge-conductor; [ $? = 0 ] && ok || bad "3c: a garbage knob is read as 0 (run), never as a skip"

# ── 4. fail-open ────────────────────────────────────────────────────────────
gate some-other-lane; [ $? = 0 ] && ok || bad "4a: a lane with no knob always runs"
gate; [ $? = 0 ] && ok || bad "4b: no lane name runs"
printf 'garbage\n' > "$H/state/cadence-backstop/merge-conductor.last"
gate merge-conductor; [ $? = 0 ] && ok || bad "4c: a garbage stamp runs (and re-stamps)"
printf '%s\n' "$(( $(date -u +%s) + 3600 ))" > "$H/state/cadence-backstop/merge-conductor.last"
gate merge-conductor; [ $? = 0 ] && ok || bad "4d: a stamp in the future (clock moved back) runs"
scratch_rm "$H/state"; : > "$H/state"
gate merge-conductor; [ $? = 0 ] && ok || bad "4e: a state dir that cannot be created runs the lane"
rm -f "$H/state"

# ── 5. the fragments wire it ────────────────────────────────────────────────
grep -qE '^\*/30 .*hub-lease\.sh check && \{ /root/harness/bin/lib/cadence-backstop\.sh merge-conductor; \[ \$\? -ne 3 \]; \} && /root/harness/bin/merge-conductor\.sh' \
  "$DIR/cron/lanes/410-merge-conductor.cron" && ok || bad "5a: the conductor's */30 line must run the gate between the lease and the lane, skipping only on rc 3"
grep -qE 'hub-lease\.sh check && \{ /root/harness/bin/lib/cadence-backstop\.sh blocked-resolver --wake-dir /root/harness/state/merge-conductor/handoff; \[ \$\? -ne 3 \]; \} && /root/harness/bin/blocked-resolver\.sh' \
  "$DIR/cron/lanes/580-blocked-resolver.cron" && ok || bad "5b: the resolver's line must run the gate with the hand-off dir as its wake, skipping only on rc 3"
for k in CADENCE_BACKSTOP_MIN_MERGE_CONDUCTOR CADENCE_BACKSTOP_MIN_BLOCKED_RESOLVER; do
  jq -e --arg k "$k" '.libs[] | select(.id=="cadence-backstop") | .knobs[] | select(.env==$k)' \
    "$DIR/catalog/lanes.d/_lib.cadence-backstop.json" >/dev/null 2>&1 && ok || bad "5c: $k must be a registered lib knob (a row, not a literal)"
done

# ── 6. the cron line itself: only rc 3 skips the lane ──────────────────────
# Run each fragment's real command line under /bin/sh (what cron uses) against a
# scratch /root/harness: a stub lease that passes, a stub lane that records it
# ran, and a gate that is the real one, missing, aborting (rc 1) or skipping.
C="$T/cronh"; mkdir -p "$C/bin/lib" "$C/logs" "$C/state/merge-conductor/handoff"
printf '#!/bin/sh\nexit 0\n' > "$C/bin/hub-lease.sh"
for l in merge-conductor blocked-resolver; do printf '#!/bin/sh\necho ran >> "%s/ran-%s"\n' "$T" "$l" > "$C/bin/$l.sh"; done
chmod +x "$C/bin/hub-lease.sh" "$C/bin/merge-conductor.sh" "$C/bin/blocked-resolver.sh"
cronline() { # cronline <fragment> <gate-mode>; echoes ran|skipped
  local frag="$1" mode="$2" line
  line=$(grep -E '^[0-9*]' "$DIR/cron/lanes/$frag" | head -n 1 | sed -E 's/^([^ ]+ ){5}//; s#/root/harness#'"$C"'#g')
  rm -f "$C/bin/lib/cadence-backstop.sh" "$T"/ran-*
  case "$mode" in
    real)    cp "$GATE" "$C/bin/lib/cadence-backstop.sh"; chmod +x "$C/bin/lib/cadence-backstop.sh" ;;
    missing) : ;;
    abort)   printf '#!/bin/bash\nset -u\necho "$UNBOUND_FOR_TEST"\n' > "$C/bin/lib/cadence-backstop.sh"; chmod +x "$C/bin/lib/cadence-backstop.sh" ;;
    skip)    printf '#!/bin/sh\nexit 3\n' > "$C/bin/lib/cadence-backstop.sh"; chmod +x "$C/bin/lib/cadence-backstop.sh" ;;
    noexec)  printf '#!/bin/sh\nexit 3\n' > "$C/bin/lib/cadence-backstop.sh"; chmod -x "$C/bin/lib/cadence-backstop.sh" ;;
  esac
  env -i PATH=/usr/bin:/bin HARNESS="$C" /bin/sh -c "$line" >/dev/null 2>&1
  if ls "$T"/ran-* >/dev/null 2>&1; then echo ran; else echo skipped; fi
}
for frag in 410-merge-conductor.cron 580-blocked-resolver.cron; do
  [ "$(cronline "$frag" missing)" = ran ] && ok || bad "6a: $frag: a MISSING gate (127) must run the lane"
  [ "$(cronline "$frag" noexec)" = ran ] && ok || bad "6b: $frag: a non-executable gate (126) must run the lane"
  [ "$(cronline "$frag" abort)" = ran ] && ok || bad "6c: $frag: a gate that aborted under set -u (rc 1) must run the lane"
  [ "$(cronline "$frag" skip)" = skipped ] && ok || bad "6d: $frag: a deliberate skip (rc 3) must skip the lane"
done
scratch_rm "$C/state/cadence-backstop"
[ "$(cronline 410-merge-conductor.cron real)" = ran ] && ok || bad "6e: the real gate's first tick runs the conductor"
[ "$(cronline 410-merge-conductor.cron real)" = skipped ] && ok || bad "6f: the real gate's second tick inside the backstop skips it"
# bash < 4.4 treats "${WAKES[@]}" of an empty array as unbound under set -u
# (macOS /bin/bash 3.2): the loop must expand the array with the +-guard.
grep -qF 'for d in ${WAKES[@]+"${WAKES[@]}"}' "$GATE" && ok || bad "6g: the wake loop must guard an empty WAKES for bash < 4.4 under set -u"

echo "cadence-backstop.c2: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
