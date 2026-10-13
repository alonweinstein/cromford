#!/bin/bash
# tests/pipeline-health-preplan-hitrate.bh-3437-test.sh — the pre-plan hit rate
# line and the 0%-hit alert in bin/pipeline-health.sh (BH-3437).
# Run from anywhere: tests/pipeline-health-preplan-hitrate.bh-3437-test.sh  (exit 0 = pass)
#
# Hit rate is adopted / (adopted + stale + miss) from GET /api/preplans/adoption.
# OFF is not a build that missed, it is one that was told not to look. A project
# with at least PREPLAN_HIT_ZERO_MIN_BUILDS builds and no hit at all fires a
# warn-digest alert keyed preplanzero:<p>, retractable. An answer that will not
# parse, or no answer, is unknown: no line, no alert, and no retraction either.
#
# Driven two ways: bin/lib/preplan-hitrate.sh's preplan_hitrate_eval directly,
# and the `# >>> preplan hit rate (BH-3437)` block extracted verbatim from
# bin/pipeline-health.sh with a stub _jobs_req and a stub alert_digest.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
mkdir -p "$T/logs" "$T/state" "$T/bin/lib"
cp "$DIR/bin/lib/preplan-hitrate.sh" "$T/bin/lib/" 2>/dev/null

awk '/^# >>> preplan hit rate \(BH-3437\)/{f=1;next} /^# <<< preplan hit rate/{exit} f' "$DIR/bin/pipeline-health.sh" > "$T/blk.sh"
[ -s "$T/blk.sh" ] && ok || bad "could not extract the preplan hit rate block from bin/pipeline-health.sh"

proj() { # proj <name> <adopted> <stale> <miss> <off>
  jq -nc --arg p "$1" --argjson a "$2" --argjson s "$3" --argjson m "$4" --argjson o "$5" \
    '{project:$p,adopted:$a,stale:$s,miss:$m,off:$o,bought:($a+$s),rate:(if $a+$s>0 then $a/($a+$s) else null end)}'
}
answer() { # answer <project-json>... -> the fixture adoption answer
  jq -s '{window_days:7, projects:., days:[], recent:[], recent_truncated:false}' <<<"$*" > "$T/answer.json"
}
drive() { # drive [VAR=VAL ...] -> log, alerts, fired; rc in $RC
  : > "$T/logs/pipeline-health.log"; : > "$T/alerts.txt"; : > "$T/fired"; rm -f "$T/req-calls"
  ( export T="$T" "$@"
    bash -c '
      set -uo pipefail
      H="$T"; NOW=$(date +%s); FIRED="$T/fired"; ACTIVE="$T/state/active.txt"
      STAMP() { echo TS; }
      _jobs_req() { printf "%s %s\n" "$1" "$2" >> "$T/req-calls"
        [ "$(cat "$T/req-rc" 2>/dev/null || echo 0)" = 0 ] || return 1; cat "$T/answer.json"; }
      alert_digest() { echo "$2" >> "$FIRED"; printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/alerts.txt"; }
      alert() { printf "PAGE|%s\n" "$2" >> "$T/alerts.txt"; }
      . "$0"' "$T/blk.sh" 2>"$T/err.txt" )
  RC=$?
}
LOG() { cat "$T/logs/pipeline-health.log"; }
: > "$T/state/active.txt"; printf '0\n' > "$T/req-rc"

echo "--- 1. one hit-rate line per tick, a null rate is never 0%"
answer "$(proj project-5 0 0 42 0)" "$(proj cromford 3 0 10 0)" "$(proj project-4 0 0 0 5)"
drive
[ "$(grep -c 'pre-plan hit rate 7d:' "$T/logs/pipeline-health.log")" = 1 ] && ok \
  || bad "exactly one 'pre-plan hit rate 7d:' line (log: $(LOG); err: $(cat "$T/err.txt"))"
grep -q 'project-5 0/42 hit (0%)' "$T/logs/pipeline-health.log" && ok || bad "project-5 must read 0/42 hit (0%) (log: $(LOG))"
grep -q 'cromford 3/13 hit (23%)' "$T/logs/pipeline-health.log" && ok || bad "cromford must read 3/13 hit (23%) (log: $(LOG))"
grep -q 'project-4 —' "$T/logs/pipeline-health.log" && ok || bad "an OFF-only project must read — (log: $(LOG))"
grep -q 'project-4 0/0\|project-4.*(0%)' "$T/logs/pipeline-health.log" && bad "no builds must never read as 0% (log: $(LOG))" || ok
[ "$(cat "$T/req-calls")" = "GET /api/preplans/adoption?days=7" ] && ok || bad "one GET of the 7d adoption (calls: $(cat "$T/req-calls"))"

echo "--- 2. 0 hits over >= N builds -> warn digest keyed preplanzero:<p>"
grep -q '^21600|preplanzero:project-5|.*0%' "$T/alerts.txt" && ok || bad "project-5 0/42 must fire preplanzero:project-5 (alerts: $(cat "$T/alerts.txt"))"
[ "$(grep -c 'preplanzero:' "$T/alerts.txt")" = 1 ] && ok || bad "only project-5 fires (alerts: $(cat "$T/alerts.txt"))"
grep -q '^PAGE' "$T/alerts.txt" && bad "a 0% hit rate is a digest, never a page" || ok
[ "$RC" = 0 ] && ok || bad "block rc must be 0 (rc $RC)"

echo "--- 3. fewer than N builds -> no alert"
answer "$(proj project-5 0 0 9 0)"; drive
grep -q preplanzero "$T/alerts.txt" && bad "0/9 under N=10 must not fire" || ok

echo "--- 4. N=0 is off"
answer "$(proj project-5 0 0 42 0)"; drive PREPLAN_HIT_ZERO_MIN_BUILDS=0
grep -q preplanzero "$T/alerts.txt" && bad "N=0 must never fire" || ok
grep -q 'project-5 0/42' "$T/logs/pipeline-health.log" && ok || bad "N=0 still logs the rate"

echo "--- 5. one hit of 51 -> no alert"
answer "$(proj project-5 1 0 50 0)"; drive
grep -q preplanzero "$T/alerts.txt" && bad "1/51 is not 0% and must not fire" || ok

echo "--- 6. OFF-only project -> no alert"
answer "$(proj project-4 0 0 0 50)"; drive
grep -q preplanzero "$T/alerts.txt" && bad "an OFF-only project has no builds and must not fire" || ok

echo "--- 7. no answer / junk answer -> no line, no alert, rc 0"
printf '1\n' > "$T/req-rc"; drive
[ -s "$T/logs/pipeline-health.log" ] && bad "an unreachable worker must write no rate line (log: $(LOG))" || ok
[ -s "$T/alerts.txt" ] && bad "an unreachable worker must fire nothing" || ok
[ "$RC" = 0 ] && ok || bad "an outage must be rc 0 (rc $RC)"
printf '0\n' > "$T/req-rc"; printf '<html>502</html>' > "$T/answer.json"; drive
[ -s "$T/logs/pipeline-health.log" ] && bad "a non-JSON answer must write no rate line (log: $(LOG))" || ok
[ -s "$T/alerts.txt" ] && bad "a non-JSON answer must fire nothing" || ok
[ "$RC" = 0 ] && ok || bad "a junk answer must be rc 0 (rc $RC)"

echo "--- 8. unknown is not cleared: an outage keeps an active preplanzero key live"
printf 'preplanzero:project-5\nstalepr:x#1\n' > "$T/state/active.txt"; printf '1\n' > "$T/req-rc"; drive
grep -qx 'preplanzero:project-5' "$T/fired" && ok || bad "an outage must carry preplanzero:project-5 forward, or the epilogue retracts it (fired: $(cat "$T/fired"))"
grep -q 'stalepr' "$T/fired" && bad "only preplanzero keys are carried" || ok
printf '0\n' > "$T/req-rc"; answer "$(proj project-5 2 0 40 0)"; drive
grep -q preplanzero "$T/fired" && bad "a real answer with hits must NOT carry the key (so it retracts)" || ok
: > "$T/state/active.txt"

echo "--- 9. preplanzero is retractable"
RETRACT_NS=""
eval "$(grep '^RETRACT_NS=' "$DIR/bin/pipeline-health.sh")"
grep -qE "^($RETRACT_NS):" <<<"preplanzero:project-5" && ok || bad "RETRACT_NS must match preplanzero:<p> (RETRACT_NS=$RETRACT_NS)"

echo "--- 10. preplan_hitrate_eval directly"
# shellcheck source=bin/lib/preplan-hitrate.sh
. "$DIR/bin/lib/preplan-hitrate.sh" || exit 1
OUT=$(preplan_hitrate_eval "$(jq -nc --argjson a "$(proj p 0 0 12 0)" '{projects:[$a]}')" 10); R=$?
[ "$R" = 0 ] && grep -qx 'ZERO p 12' <<<"$OUT" && ok || bad "0/12 at N=10 -> ZERO p 12 (rc $R, out: $OUT)"
preplan_hitrate_eval 'not json' 10 >/dev/null && bad "unparseable input must rc 1" || ok
preplan_hitrate_eval '{"projects":[{"project":"p","adopted":"x","stale":0,"miss":3}]}' 1 >/dev/null \
  && bad "a non-number count must rc non-zero, never read as 0" || ok
OUT=$(preplan_hitrate_eval '{"projects":[]}' 10); R=$?
[ "$R" = 0 ] && [ -z "$OUT" ] && ok || bad "no projects -> rc 0, nothing printed (rc $R, out: $OUT)"

echo "pipeline-health-preplan-hitrate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
