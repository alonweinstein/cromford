#!/bin/bash
# tests/trigger-actor-retry.bh-5021-test.sh — a transient rc=75 on the
# trigger-actor events read is retried with backoff before the build defers
# (BH-5021 item 4).
#
# BH-4973 deferred once on `trigger-actor unverifiable (events page 1 rc=75)`
# with an EMPTY reason: a 5xx, not a rate limit, and a few seconds would have
# fixed it. The REAL bin/lib/trigger-actor.sh is sourced; only gh_rest (the
# wire) is a stub, answering from a per-call script.
#   R1  one transient 75 -> retried, read, rc 0, two calls
#   R2  75 network, 75 "", then ok -> rc 0, three calls
#   R3  three transients -> rc 2, PROJECT_2_NOTE says rc=75 and after 2 retries
#   R4  rate-limit / quota-reserve -> never retried (a drained bucket)
#   R5  bad-args -> rc 3 as before, one call
#   R6  PROJECT_2_EVENTS_RETRIES=0 -> the single read of before
#   R7  through the real `# >>> trigger actor gate (BH-4490)` block: R1's wire
#       builds, and the pipeline.log allow line says it retried
#   R8  the backoff is honoured
# Run from anywhere: bash tests/trigger-actor-retry.bh-5021-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "trigger-actor-retry.bh-5021: jq absent — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/locks" "$H/logs" "$T/build"
for s in bin/lib/trigger-actor.sh bin/lib/harness-self.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done
export HARNESS="$H" WIRE="$T/wire" CALLS="$T/calls"
jq -nc '[{id:1001, event:"labeled", label:{name:"ai-build"}, actor:{login:"alice", type:"User"},
          created_at:"2026-10-04T20:00:00Z", performed_via_github_app:null}]' > "$T/page.json"
export PAGE="$T/page.json"

# The wire. Line n of $WIRE answers call n: `ok`, or `75|<reason>`.
cat > "$T/wire.sh" <<'SH'
gh() { :; }
gh_rest_comment() { return 0; }
gh_rest() {
  echo "$1 $2" >> "$CALLS"
  local n line rc reason
  n=$(wc -l < "$CALLS" | tr -d ' ')
  line=$(sed -n "${n}p" "$WIRE")
  case "$line" in
    ok|'') cat "$PAGE"; return 0 ;;
  esac
  IFS='|' read -r rc reason <<<"$line"
  GH_REST_REASON="$reason"
  return "$rc"
}
SH
export WIRE_SH="$T/wire.sh"

# trig <wire lines...> [env via the caller] -> RC, NOTE (PROJECT_2_NOTE), RNOTE (PROJECT_2_READ_NOTE), N (calls)
trig() {
  printf '%s\n' "$@" > "$WIRE"; : > "$CALLS"; rm -f "$T/out.tsv"
  local r
  r=$( bash -c '. "$WIRE_SH"; . "$HARNESS/bin/lib/trigger-actor.sh"
                rc=0; ta_gh_trigger example-org/tproj 77 "$0" || rc=$?
                printf "%s\n%s\n%s\n" "$rc" "$PROJECT_2_NOTE" "${PROJECT_2_READ_NOTE:-}"' "$T/out.tsv" 2>/dev/null )
  RC=$(sed -n 1p <<<"$r"); NOTE=$(sed -n 2p <<<"$r"); RNOTE=$(sed -n 3p <<<"$r")
  N=$(wc -l < "$CALLS" | tr -d ' ')
}
export PROJECT_2_EVENTS_RETRY_BACKOFF_S="0 0"

trig '75|' ok
[ "$RC" = 0 ] && ok || bad "R1: one transient 75 must retry and read (rc=$RC note=$NOTE)"
[ "$N" = 2 ] && ok || bad "R1: expected 2 calls, got $N"
grep -q $'^1001\talice\tUser' "$T/out.tsv" 2>/dev/null && ok || bad "R1: the event was not read: $(cat "$T/out.tsv" 2>/dev/null)"
[[ "$RNOTE" == "events page 1 retried 1" ]] && ok || bad "R1: PROJECT_2_READ_NOTE must say it retried once, got '$RNOTE'"
[ -z "$NOTE" ] && ok || bad "R1: a read that worked must leave PROJECT_2_NOTE alone (ta_gate's ignore line reads it), got '$NOTE'"

trig '75|network' '75|' ok
[ "$RC" = 0 ] && [ "$N" = 3 ] && ok || bad "R2: two transients then ok must read on call 3 (rc=$RC calls=$N note=$NOTE)"

trig '75|' '75|network' '75|cache-miss' ok
[ "$RC" = 2 ] && ok || bad "R3: three transients must defer rc 2 (rc=$RC)"
[ "$N" = 3 ] && ok || bad "R3: exactly 3 calls (1 + 2 retries), got $N"
[[ "$NOTE" == *"rc=75"* && "$NOTE" == *"after 2 retries"* ]] && ok || bad "R3: PROJECT_2_NOTE must say rc=75 and after 2 retries, got '$NOTE'"

trig '75|rate-limit' ok
[ "$RC" = 2 ] && [ "$N" = 1 ] && ok || bad "R4: a rate limit must not be retried (rc=$RC calls=$N)"
trig '75|quota-reserve' ok
[ "$RC" = 2 ] && [ "$N" = 1 ] && ok || bad "R4b: quota-reserve must not be retried (rc=$RC calls=$N)"

trig '75|bad-args' ok
[ "$RC" = 3 ] && [ "$N" = 1 ] && ok || bad "R5: bad-args must stay rc 3 after one call (rc=$RC calls=$N)"

PROJECT_2_EVENTS_RETRIES=0 trig '75|' ok
[ "$RC" = 2 ] && [ "$N" = 1 ] && ok || bad "R6: PROJECT_2_EVENTS_RETRIES=0 must read once (rc=$RC calls=$N)"
PROJECT_2_EVENTS_RETRIES=junk trig '75|' '75|' ok
[ "$RC" = 0 ] && [ "$N" = 3 ] && ok || bad "R6b: a junk PROJECT_2_EVENTS_RETRIES must fall back to 2 retries (rc=$RC calls=$N)"

# ── R7 through the real gate block ───────────────────────────────────────────
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB=$(rb_all "$DIR" "$T/run-build.all.sh") || { echo "could not flatten the pipeline"; exit 1; }
awk '/^# >>> trigger actor gate/{f=1} f{print} /^# <<< trigger actor gate/{exit}' "$RB" > "$T/block.sh"
[ -s "$T/block.sh" ] && ok || bad "R7: could not lift the trigger actor gate block"
cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$2" in board_prefix) echo - ;; repo) echo example-org/tproj ;; *) exit 1 ;; esac
SH
chmod +x "$H/bin/fleet-conf.sh"
cat > "$T/stubs.sh" <<'SH'
STAMP() { echo 2026-10-07T00:00:00Z; }
RESULT() { echo "$*" > "$SINK"; }
. "$REPO_DIR/bin/jobs-client.sh"
_jobs_req() {
  case "$1 $2" in
    "GET /api/settings/trigger.actors.tproj") jq -nc '{setting:{key:"trigger.actors.tproj",value:"alice"}}'; return 0 ;;
    "GET /api/ledger?"*) return 2 ;;
    "PUT /api/ledger") return 0 ;;
  esac
  return 1
}
lane_switch() { return 1; }
SH
printf '%s\n' '75|' ok > "$WIRE"; : > "$CALLS"; : > "$T/sink"; rm -f "$T/build/pipeline.log"
OUT=$( env REPO_DIR="$DIR" SINK="$T/sink" BUILD="$T/build" PROJECT=tproj KEY=BH-77 TICKET=77 \
       HARNESS_SELF_APPS="cromford cromford-board cromford-builders" \
       HARNESS_SECRET=fixture-secret JOBS_URL=http://jobs.example.test STUBS="$T/stubs.sh" \
       bash -c '. "$STUBS"; . "$WIRE_SH"; . "$0"; echo CONTINUED' "$T/block.sh" 2>/dev/null ); RC=$?
grep -q CONTINUED <<<"$OUT" && [ ! -s "$T/sink" ] && ok || bad "R7: one transient 75 must not defer the build (rc=$RC result=$(cat "$T/sink"))"
grep -q 'TRIGGER-ACTOR allow listed actor=alice event=1001' "$T/build/pipeline.log" 2>/dev/null && ok \
  || bad "R7: no TRIGGER-ACTOR allow line: $(cat "$T/build/pipeline.log" 2>/dev/null)"
grep -q 'TRIGGER-ACTOR allow.*retried 1' "$T/build/pipeline.log" 2>/dev/null && ok \
  || bad "R7: the allow line must say the read was retried: $(cat "$T/build/pipeline.log" 2>/dev/null)"
[ "$(wc -l < "$CALLS" | tr -d ' ')" = 2 ] && ok || bad "R7: expected 2 events reads, got $(wc -l < "$CALLS")"

# ── R8 the backoff is honoured ───────────────────────────────────────────────
NOW=$(date +%s)
T0=$NOW
PROJECT_2_EVENTS_RETRY_BACKOFF_S="1 1" trig '75|network' '75|' ok
T1=$(date +%s)
[ "$RC" = 0 ] && [ "$N" = 3 ] && ok || bad "R8: rc=$RC calls=$N"
[ "$((T1 - T0))" -ge 2 ] && ok || bad "R8: two 1s backoffs must take at least 2s, took $((T1 - T0))s"

echo "trigger-actor-retry.bh-5021: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
