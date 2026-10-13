#!/bin/bash
# BH-977 — the review ledger must survive being empty.
#
# bin/review-prs.sh dedupes paid reviews on state/<project>.pr-reviews.json.
# A 0-byte (or garbage, or non-object) file reads as "nothing reviewed" AND
# every `jq … "$STATE" > tmp && mv` on it writes 0 bytes back with rc 0, so the
# file can never heal itself: every open head is re-reviewed on every tick
# (project-5, 2026-09-19: 304 reviews, USD 328 in a day on unchanged shas).
#
# This suite drives the REAL script with gh and agent-call stubbed, so what is
# under test is the spend boundary itself, not a helper in isolation.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
RP="$DIR/bin/review-prs.sh"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# Captured BEFORE anything is prepended to PATH: the write-refusal cases put a
# jq wrapper in front of the real one and it has to be able to reach it.
REAL_JQ=$(command -v jq)
export REAL_JQ TEST_ROOT="$T"
STATE="$T/h/state/project-1.pr-reviews.json"

mkdir -p "$T/fakebin" "$T/jqbin"

# Two open, non-draft PRs by an external author on distinct heads. `api` prints
# nothing, so a PR with no record reviews immediately (the CI debounce only
# applies to a head that already has a verdict) and the gate is not in play.
cat > "$T/fakebin/gh" <<'STUB'
#!/bin/bash
if [ "${1:-}" = pr ] && [ "${2:-}" = list ]; then
  printf '7\thead7aaaaaaa\texternaldev\tA\n8\thead8bbbbbbb\texternaldev\tB\n'
elif [ "${1:-}" = api ]; then
  :
elif [ "${1:-}" = pr ] && [ "${2:-}" = diff ]; then
  if [[ "$*" == *--name-only* ]]; then
    printf 'lib/pricing.ts\n'
  else
    printf 'diff --git a/a.ts b/a.ts\n+const changed = true\n'
  fi
elif [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
  printf '\n'
elif [ "${1:-}" = pr ] && { [ "${2:-}" = review ] || [ "${2:-}" = comment ]; }; then
  :
fi
STUB

cat > "$T/fakebin/agent-call" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_ROOT/agent-calls.log"
printf 'Static review.\nTIER: 2\nVERDICT: REQUEST_CHANGES\n' > "$5"
printf 'claude\n' > "$5.runner"
STUB

# The exact production failure shape: on the verdict-record filter jq either
# prints NOTHING and exits 0 (what jq 1.7 does with an empty input file) or
# fails outright. Everything else goes to the real jq untouched.
cat > "$T/jqbin/jq" <<'STUB'
#!/bin/bash
if [[ "$*" == *'.[$n] = {sha:$s, verdict:$v'* ]]; then
  [ "${JQ_EMPTY_WRITE:-0}" = 1 ] && exit 0
  [ "${JQ_FAIL_WRITE:-0}" = 1 ] && exit 1
fi
exec "$REAL_JQ" "$@"
STUB
chmod +x "$T/fakebin/gh" "$T/fakebin/agent-call" "$T/jqbin/jq"

. "$DIR/tests/lib/model-route-stub.sh" || exit 1
fresh_harness() {
  scratch_rm "$T/h" || return 1
  rm -f "$T/agent-calls.log"
  mkdir -p "$T/h/bin/lib" "$T/h/state" "$T/h/logs" "$T/h/locks" "$T/h/env" "$T/h/builds"
  cp "$T/fakebin/agent-call" "$T/h/bin/agent-call.sh"
  cp "$DIR/bin/alert-line.sh" "$T/h/bin/"
  # BH-1510.1: the reviewer's model is a model_routes row, read through review_model;
  # this worker-less box carries the resolver's cache of #1507's table.
  cp "$DIR/bin/lib/review-model.sh" "$T/h/bin/lib/"
  mrs_fixture "$T/h" project-1
  cp "$DIR/bin/lib/e2e-paths.sh" "$T/h/bin/lib/"
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"
  chmod +x "$T/h/bin/beat.sh"
}

RC=0
# Set by the write-refusal cases, cleared by plain_jq. Globals rather than
# call-prefix assignments: bash's rule for assignments in front of a FUNCTION
# call differs between posix and default mode, and a knob that silently leaks
# into the next case is how a suite lies about the case after it.
LANE_PATH_PREFIX=""
JQ_EMPTY_WRITE=0
JQ_FAIL_WRITE=0
plain_jq() { LANE_PATH_PREFIX=""; JQ_EMPTY_WRITE=0; JQ_FAIL_WRITE=0; }
wrapped_jq() { LANE_PATH_PREFIX="$T/jqbin:"; JQ_EMPTY_WRITE="${1:-0}"; JQ_FAIL_WRITE="${2:-0}"; }

run_lane() { # run_lane [script]   — sets RC
  PATH="$LANE_PATH_PREFIX$T/fakebin:$PATH" HARNESS="$T/h" FLEET_CONF="$DIR/fleet.conf" \
    JQ_EMPTY_WRITE="$JQ_EMPTY_WRITE" JQ_FAIL_WRITE="$JQ_FAIL_WRITE" \
    bash "${1:-$RP}" project-1 >/dev/null 2>&1
  RC=$?
}

calls() {
  if [ -f "$T/agent-calls.log" ]; then wc -l < "$T/agent-calls.log"; else echo 0; fi
}
alerts() {
  if [ -f "$T/h/logs/ALERTS.log" ]; then wc -l < "$T/h/logs/ALERTS.log"; else echo 0; fi
}
log_count() { # log_count <pattern>  — grep -c prints 0 and exits 1 on no match
  local n
  n=$(grep -c "$1" "$T/h/logs/pr-reviews.log" 2>/dev/null)
  echo "${n:-0}"
}
both_heads_recorded() {
  [ "$("$REAL_JQ" -r '."7".sha // ""' "$STATE" 2>/dev/null)" = head7aaaaaaa ] \
    && [ "$("$REAL_JQ" -r '."8".sha // ""' "$STATE" 2>/dev/null)" = head8bbbbbbb ]
}
is_object() { "$REAL_JQ" -e 'type == "object"' "$STATE" >/dev/null 2>&1; }
# BH-1017 moved the in-flight marker AHEAD of the paid call, so a tick that
# spends now writes `reviewing_sha`/`reviewing_attempts` into the ledger before
# agent-call runs. S6 and S7 used to assert "the ledger is still literally `{}`"
# as shorthand for "the refused write landed nothing"; that shorthand stopped
# being true when the marker landed, while the PROPERTY it stood for did not.
# So the property is asserted directly: a refused verdict write leaves no `sha`
# and no `verdict` on any record, which is what makes the next tick re-review.
no_verdict_landed() {
  "$REAL_JQ" -e '[.[] | (has("sha") or has("verdict"))] | any | not' "$STATE" >/dev/null 2>&1
}

# A copy of the script with one marked block removed or defanged, so the suite
# can prove each guard is load-bearing rather than decorative. The copy needs
# the registry reader and the PR-list lib beside it, exactly as
# tests/review-prs-coverage-test.sh builds its `lonebin`.
mutant() { # mutant <dir> <noload|naivewrite>
  local d="$1" mode="$2"
  mkdir -p "$d/lib"
  cp "$DIR/bin/fleet-conf.sh" "$d/fleet-conf.sh"
  cp "$DIR/bin/lib/gh-pr-list.sh" "$d/lib/gh-pr-list.sh"
  # TEST-CHANGE (BH-1585): the open list is REST now; the contract lib rides beside gh-pr-list.sh.
  cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" "$d/lib/"
  case "$mode" in
    noload)
      awk '/^# >>> review-prs state load/ {skip=1}
           skip==0 {print}
           /^# <<< review-prs state load/ {skip=0}' "$RP" > "$d/review-prs.sh" ;;
    naivewrite)
      awk '/^# >>> review-prs state write/ {skip=1; print "rp_state_write() { jq \"$@\" \"$STATE\" > \"$STATE.tmp\" && mv \"$STATE.tmp\" \"$STATE\"; }"; next}
           /^# <<< review-prs state write/ {skip=0; next}
           skip==0 {print}' "$RP" > "$d/review-prs.sh" ;;
  esac
  chmod +x "$d/review-prs.sh"
}

# ── S1 — the ticket's acceptance line: a 0-byte ledger ───────────────────────
fresh_harness
: > "$STATE"
run_lane
[ "$(calls)" -eq 2 ] && ok || bad "S1 tick 1 made $(calls) review calls, expected 2"
is_object && ok || bad "S1 left the state file a non-object: $(cat "$STATE")"
both_heads_recorded && ok || bad "S1 did not record both heads: $(cat "$STATE")"
[ "$(alerts)" -eq 1 ] && ok || bad "S1 wrote $(alerts) ALERTS line(s), expected exactly 1"
grep -q 'project-1.pr-reviews.json' "$T/h/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "S1 ALERTS line does not name the file: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null)"
grep -q '0 bytes' "$T/h/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "S1 ALERTS line does not give the size: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null)"
[ ! -e "$STATE.bad" ] && ok || bad "S1 kept a .bad copy of a 0-byte file"
run_lane
[ "$(calls)" -eq 2 ] && ok || bad "S1 tick 2 re-reviewed: $(calls) total calls, expected 2"
[ "$(alerts)" -eq 1 ] && ok || bad "S1 tick 2 alerted again: $(alerts) lines, expected 1"
[ "$(log_count 'verdict=')" -eq 2 ] \
  && ok || bad "S1 tick 2 logged a fresh verdict ($(log_count 'verdict=') verdict lines, expected 2)"

# ── S2 — garbage ledger, evidence kept ───────────────────────────────────────
fresh_harness
printf 'not json' > "$STATE"
run_lane
[ "$(calls)" -eq 2 ] && ok || bad "S2 tick 1 made $(calls) review calls, expected 2"
both_heads_recorded && ok || bad "S2 did not record both heads: $(cat "$STATE")"
[ "$(alerts)" -eq 1 ] && ok || bad "S2 wrote $(alerts) ALERTS line(s), expected exactly 1"
grep -q '8 bytes' "$T/h/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "S2 ALERTS line does not give the size: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null)"
[ "$(cat "$STATE.bad" 2>/dev/null)" = 'not json' ] \
  && ok || bad "S2 did not keep the bad bytes at $STATE.bad"
run_lane
[ "$(calls)" -eq 2 ] && ok || bad "S2 tick 2 re-reviewed: $(calls) total calls, expected 2"
[ "$(alerts)" -eq 1 ] && ok || bad "S2 tick 2 alerted again: $(alerts) lines, expected 1"

# ── S3 — valid JSON of the wrong type ────────────────────────────────────────
fresh_harness
printf '[]' > "$STATE"
run_lane
[ "$(calls)" -eq 2 ] && ok || bad "S3 tick 1 made $(calls) review calls, expected 2"
is_object && ok || bad "S3 left the state file a non-object: $(cat "$STATE")"
both_heads_recorded && ok || bad "S3 did not record both heads: $(cat "$STATE")"
[ "$(alerts)" -eq 1 ] && ok || bad "S3 wrote $(alerts) ALERTS line(s), expected exactly 1"
run_lane
[ "$(calls)" -eq 2 ] && ok || bad "S3 tick 2 re-reviewed: $(calls) total calls, expected 2"

# ── S4 — a healthy ledger is not rewritten and not alerted ───────────────────
fresh_harness
printf '%s\n' '{"7":{"sha":"head7aaaaaaa","verdict":"REQUEST_CHANGES","tier":"2"},"8":{"sha":"head8bbbbbbb","verdict":"REQUEST_CHANGES","tier":"2"}}' \
  > "$T/seed4.json"
cp "$T/seed4.json" "$STATE"
run_lane
[ "$(calls)" -eq 0 ] && ok || bad "S4 re-reviewed a recorded head: $(calls) calls, expected 0"
[ "$(alerts)" -eq 0 ] && ok || bad "S4 alerted on a healthy file: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null)"
cmp -s "$T/seed4.json" "$STATE" && ok || bad "S4 rewrote a healthy state file"
[ ! -e "$STATE.bad" ] && ok || bad "S4 wrote a .bad copy of a healthy file"

# ── S5 — a missing ledger is a first run, not corruption ─────────────────────
fresh_harness
run_lane
[ "$(calls)" -eq 2 ] && ok || bad "S5 made $(calls) review calls, expected 2"
both_heads_recorded && ok || bad "S5 did not record both heads: $(cat "$STATE" 2>/dev/null)"
[ "$(alerts)" -eq 0 ] && ok || bad "S5 alerted on a first run: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null)"

# ── S6 — a write that produces nothing is refused; the tick carries on ───────
fresh_harness
printf '{}\n' > "$STATE"
wrapped_jq 1 0
run_lane
[ "$RC" -eq 0 ] && ok || bad "S6 tick 1 exited $RC, expected 0"
[ "$(calls)" -eq 2 ] && ok || bad "S6 a refused write aborted the loop: $(calls) calls, expected 2"
[ -s "$STATE" ] && ok || bad "S6 replaced the ledger with an empty file"
is_object && ok || bad "S6 left the state file a non-object: $(cat "$STATE")"
no_verdict_landed && ok || bad "S6 landed a verdict through a refused write: $(cat "$STATE")"
[ "$(alerts)" -eq 1 ] && ok || bad "S6 wrote $(alerts) ALERTS line(s), expected exactly 1 per tick"
[ "$(log_count 'refused to write')" -eq 2 ] \
  && ok || bad "S6 logged $(log_count 'refused to write') refusals, expected 2"
plain_jq
run_lane
[ "$(calls)" -eq 4 ] && ok || bad "S6 tick 2 made $(calls) total calls, expected 4"
both_heads_recorded && ok || bad "S6 tick 2 did not record both heads: $(cat "$STATE")"

# ── S7 — jq failing outright is the same refusal ─────────────────────────────
fresh_harness
printf '{}\n' > "$STATE"
wrapped_jq 0 1
run_lane
[ "$RC" -eq 0 ] && ok || bad "S7 exited $RC, expected 0"
[ "$(calls)" -eq 2 ] && ok || bad "S7 a failed write aborted the loop: $(calls) calls, expected 2"
no_verdict_landed && ok || bad "S7 landed a verdict through a failed write: $(cat "$STATE")"
[ "$(alerts)" -eq 1 ] && ok || bad "S7 wrote $(alerts) ALERTS line(s), expected exactly 1 per tick"
[ "$(log_count 'refused to write')" -eq 2 ] \
  && ok || bad "S7 logged $(log_count 'refused to write') refusals, expected 2"

# ── S8 — static pin: exactly one writer of the ledger ────────────────────────
[ "$(grep -c 'STATE.tmp' "$RP")" -eq 1 ] \
  && ok || bad "bin/review-prs.sh has $(grep -c 'STATE.tmp' "$RP") STATE.tmp sites, expected 1 (the helper)"
[ "$(grep -c 'rp_state_write ' "$RP")" -ge 8 ] \
  && ok || bad "bin/review-prs.sh has $(grep -c 'rp_state_write ' "$RP") rp_state_write references, expected at least 8"

# ── S9 — mutation: without the load guard the loop comes back ────────────────
plain_jq
mutant "$T/mut-noload" noload
fresh_harness
: > "$STATE"
run_lane "$T/mut-noload/review-prs.sh"
run_lane "$T/mut-noload/review-prs.sh"
[ "$(calls)" -eq 4 ] \
  && ok || bad "S9 mutation: without the load guard tick 2 should re-review (got $(calls) calls, expected 4)"
[ ! -s "$STATE" ] \
  && ok || bad "S9 mutation: without the load guard the 0-byte ledger should stay empty (got: $(cat "$STATE"))"

# ── S10 — mutation: without the write guard the ledger is emptied ────────────
mutant "$T/mut-naive" naivewrite
fresh_harness
printf '{}\n' > "$STATE"
wrapped_jq 1 0
run_lane "$T/mut-naive/review-prs.sh"
[ ! -s "$STATE" ] \
  && ok || bad "S10 mutation: an unguarded tmp+mv should leave a 0-byte ledger (got: $(cat "$STATE"))"

echo "review-prs-state (BH-977): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
