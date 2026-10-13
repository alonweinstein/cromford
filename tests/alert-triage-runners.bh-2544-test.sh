#!/bin/bash
# tests/alert-triage-runners.bh-2544-test.sh — the RUNNER ALLOWLIST slice of
# BH-2544 (BH-2570): the TRIAGE_RUNNERS knob reaches every agent-call the
# alert-triage lane makes as a per-command AGENT_CALL_RUNNERS, the floor calls
# intersect it with FLOOR_RUNNERS_ONLY, and an empty intersection buys nothing.
#
#   R1   strong call, RUNNER_TRIAGE=grok, knob claude,fireworks -> the call
#        sees AGENT_CALL_RUNNERS=claude,fireworks.
#   R1b  a knob spelled " claude , fireworks" is normalised, never word-split.
#   R2   the REAL bin/agent-call.sh with that list never runs grok.
#   R3   knob unset -> no AGENT_CALL_RUNNERS on the strong or the floor call.
#   R4   one-rung floor (fireworks) and knob claude,fireworks -> the floor call
#        and the cliff floor retry both see AGENT_CALL_RUNNERS=fireworks.
#   R5   one-rung floor (fireworks) and knob claude -> no call, the family is
#        re-spooled at its pre-tick stamp, one `no floor runner allowed` line.
#   R5b  the same on the cliff retry: the retry is skipped and the family goes
#        down the cliff deferral path.
#   R6   no model id is added under bin/, catalog/ or worker/.
#
# Runs the REAL bin/alert-triage.sh in a scratch harness, the way
# tests/alert-triage-hooks.bh-2544-test.sh does; agent-call is a recording stub
# except in R2.
#   bash tests/alert-triage-runners.bh-2544-test.sh     exit 0 = all pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/triage-tick.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" || exit 1
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/env" "$T/stub" "$T/calls" "$T/tmp"
: > "$H/env/global.env"
LOGF="$H/logs/alert-triage.log"
FAMF="$H/state/alert-families.json"
SPOOL="$H/state/alert-triage-deferred.tsv"
# BH-5942: project "fleet" is not in fleet.conf, so the cromford run owns
# the line. The shared files above are what reset seeds (the dispatch routes the
# legacy spool; the run seeds its brake file by copy); the run writes these.
HP="$H/state/alert-triage/cromford"
PFAMF="$HP/alert-families.json"
PSPOOL="$HP/deferred.tsv"
FLOORTSV="$H/state/model-routes/housekeeping.floor.tsv"
cp "$FLOORTSV" "$T/floor-two-rung.tsv"
# A one-rung floor: the rung-0 row the fixture seeded, alone. Its runner is what
# lane_housekeeping_floor puts in FLOOR_RUNNERS_ONLY.
head -1 "$T/floor-two-rung.tsv" > "$T/floor-one-rung.tsv"
[ "$(cut -f3 "$T/floor-one-rung.tsv")" = fireworks ] || { echo "FAIL: the seeded floor rung 0 is no longer fireworks — fix the fixture"; exit 1; }

for s in alert-triage.sh triage-spool-retire.sh; do
  sed "s|/root/harness|$H|g" "$DIR/bin/$s" > "$H/bin/$s"; chmod +x "$H/bin/$s"
done
cp "$DIR/bin/lib/triage-close.sh" "$H/bin/lib/triage-close.sh"
for s in triage-map.sh fleet-conf.sh box-for.sh alert_family.py triage-family-scripts.sh; do ln -sf "$DIR/bin/$s" "$H/bin/$s"; done
export FLEET_CONF="$DIR/fleet.conf"
triage_tick_setup "$H" || exit 1

# agent-call.sh: one line per call — the model arg, RUNNER_TRIAGE and
# AGENT_CALL_RUNNERS (or `unset`). STUB_CLIFF=1 refuses the FIRST call with
# agent-call's own cliff marker, the way the strong tier does past its cliff.
cat > "$H/bin/agent-call.sh" <<'STUB'
#!/bin/bash
N=$(cat "$CALLDIR/env" 2>/dev/null | wc -l | tr -d ' ')
printf 'model=%s runner=%s allow=%s\n' "$3" "${RUNNER_TRIAGE:-unset}" "${AGENT_CALL_RUNNERS-unset}" >> "$CALLDIR/env"
if [ "${STUB_CLIFF:-0}" = 1 ] && [ "$N" = 0 ]; then
  printf 'AGENT_CALL_CLIFF_ROUTED grok projected 1408081 > cliff 200000\n' > "$5"; exit 79
fi
echo "handled=1 escalated=0 noise=0" > "$5"
STUB
chmod +x "$H/bin/agent-call.sh"
printf '#!/bin/sh\nexit 75\n' > "$H/bin/gh-pr-state.sh"; chmod +x "$H/bin/gh-pr-state.sh"
printf '#!/bin/sh\nexit 0\n' > "$T/stub/ssh";   chmod +x "$T/stub/ssh"
printf '#!/bin/sh\nexit 0\n' > "$T/stub/flock"; chmod +x "$T/stub/flock"
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$T/stub/timeout"; chmod +x "$T/stub/timeout"

NOW=1790467200
RAW=$(printf 'hub\t%s\t{"kind":"fleet_alert","project":"fleet","akey":"orclane:bh2570","line":"the widget subsystem is unhappy"}' "$((NOW - 600))")
FKEY=$(cd "$DIR/bin" && python3 -c 'import sys; from alert_family import family; print(family(sys.argv[1]))' "$RAW")
[ -n "$FKEY" ] || { echo "FAIL: could not compute the fixture's family key"; exit 1; }
PRE=$((NOW - 7 * 3600))   # seen 7h ago: past the 6h brake, so the family is FLOOR tier

reset() { # reset <strong|floor> <one-rung|two-rung>
  triage_tick_reset "$H"; : > "$LOGF"; : > "$H/logs/ALERTS.log"; : > "$H/logs/cost.csv"
  if [ "$1" = floor ]; then jq -n --arg k "$FKEY" --argjson s "$PRE" '{($k): $s}' > "$FAMF"; else echo '{}' > "$FAMF"; fi
  cp "$T/floor-$2.tsv" "$FLOORTSV"
  printf '%s\n' "$RAW" > "$SPOOL"
  : > "$H/state/alert-quarantine.jsonl"
  rm -f "$H"/state/alert-triage-expired-*.tsv "$H"/state/alert-triage-cliff*.json "$H"/state/alert-triage-cliff-parked.tsv "$H"/flags/alerted-*
  scratch_rm "$T/calls"; mkdir -p "$T/calls"
}
# HERMETIC: the worker env this shell may carry is cut, so no live settings row
# (lane_env_apply) or model route can reach the fixture.
run() { # run [VAR=value ...] — the tick, with those extra env settings
  ( unset HARNESS_SECRET JOBS_URL CONSOLE_URL
    [ "$#" -gt 0 ] && export "$@"
    export TMPDIR="$T/tmp" TRIAGE_NOW="$NOW" TRIAGE_MAX_FAMILIES=20 CALLDIR="$T/calls" PATH="$T/stub:$PATH"
    triage_tick "$H/bin/alert-triage.sh" >/dev/null 2>&1 )
  RC=$?
}
calls() { cat "$T/calls/env" 2>/dev/null; }
ncalls() { calls | wc -l | tr -d ' '; }
stamp_of() { jq -r --arg k "$FKEY" 'if .[$k] == null then "absent" else (.[$k] | floor | tostring) end' "$PFAMF"; }

# ---------- R1 — the strong call gets the knob --------------------------------
reset strong two-rung; run RUNNER_TRIAGE=grok TRIAGE_RUNNERS=claude,fireworks
[ "$(ncalls)" = 1 ] && ok || bad "R1: one strong call (got $(ncalls): $(calls))"
calls | grep -q ' runner=grok allow=claude,fireworks$' && ok \
  || bad "R1: the strong call sees AGENT_CALL_RUNNERS=claude,fireworks beside RUNNER_TRIAGE=grok (got: $(calls))"
[ "$RC" = 0 ] && ok || bad "R1: the tick exits 0 (got $RC)"

# ---------- R1b — normalised, never word-split --------------------------------
reset strong two-rung; run TRIAGE_RUNNERS=" claude , fireworks "
calls | grep -q ' allow=claude,fireworks$' && [ "$(ncalls)" = 1 ] && ok \
  || bad "R1b: a spaced knob reaches the call as claude,fireworks, and the call is made (got: $(calls))"

# ---------- R3 — no knob, no prefix -------------------------------------------
reset strong two-rung; run
calls | grep -q ' allow=unset$' && [ "$(ncalls)" = 1 ] && ok \
  || bad "R3: with no knob the strong call has no AGENT_CALL_RUNNERS (got: $(calls))"
reset floor two-rung; run
calls | grep -q ' runner=fireworks allow=unset$' && [ "$(ncalls)" = 1 ] && ok \
  || bad "R3: with no knob and a two-rung floor the floor call has no AGENT_CALL_RUNNERS (got: $(calls))"

# ---------- R3b — two-rung floor: the knob alone ------------------------------
reset floor two-rung; run TRIAGE_RUNNERS=claude,fireworks
calls | grep -q ' runner=fireworks allow=claude,fireworks$' && ok \
  || bad "R3b: a two-rung floor (FLOOR_RUNNERS_ONLY empty) gets the knob unchanged (got: $(calls))"

# ---------- R4 — one-rung floor: the intersection -----------------------------
reset floor one-rung; run TRIAGE_RUNNERS=claude,fireworks
[ "$(ncalls)" = 1 ] && calls | grep -q ' runner=fireworks allow=fireworks$' && ok \
  || bad "R4: the floor call sees AGENT_CALL_RUNNERS=fireworks (got: $(calls))"
reset strong one-rung; run TRIAGE_RUNNERS=claude,fireworks STUB_CLIFF=1
[ "$(ncalls)" = 2 ] && ok || bad "R4: a cliffed strong call is retried once on the floor (got $(ncalls): $(calls))"
[ "$(calls | sed -n 1p | sed 's/.* allow=//')" = claude,fireworks ] && [ "$(calls | sed -n 2p | sed 's/.* allow=//')" = fireworks ] && ok \
  || bad "R4: strong sees the knob, the cliff floor retry sees the intersection (got: $(calls))"
reset floor one-rung; run
calls | grep -q ' allow=fireworks$' && ok \
  || bad "R4: no knob and a one-rung floor keep today's FLOOR_RUNNERS_ONLY prefix (got: $(calls))"

# ---------- R5 — empty intersection: no call, re-spooled, stamp restored ------
reset floor one-rung; run TRIAGE_RUNNERS=claude
[ "$(ncalls)" = 0 ] && ok || bad "R5: an empty intersection makes no call (got: $(calls))"
[ "$(cat "$PSPOOL" 2>/dev/null)" = "$RAW" ] && ok || bad "R5: the family's line is back on the spool (spool: $(cat "$PSPOOL" 2>/dev/null))"
[ "$(stamp_of)" = "$PRE" ] && ok || bad "R5: the family's stamp is its pre-tick $PRE (got $(stamp_of))"
[ "$(grep -c 'no floor runner allowed' "$LOGF")" = 1 ] && ok \
  || bad "R5: exactly one 'no floor runner allowed' line (got $(grep -c 'no floor runner allowed' "$LOGF"))"
grep -q 'FLOOR_RUNNERS_ONLY=fireworks ∩ TRIAGE_RUNNERS=claude is empty' "$LOGF" && ok \
  || bad "R5: the line names both lists (log: $(grep 'no floor runner' "$LOGF"))"
[ "$RC" = 0 ] && ok || bad "R5: the tick exits 0 (got $RC)"

# ---------- R5b — empty intersection on the cliff retry -----------------------
reset strong one-rung; run TRIAGE_RUNNERS=claude STUB_CLIFF=1
[ "$(ncalls)" = 1 ] && ok || bad "R5b: only the strong call is made, the floor retry is skipped (got: $(calls))"
[ "$(grep -c 'no floor runner allowed' "$LOGF")" = 1 ] && ok \
  || bad "R5b: exactly one 'no floor runner allowed' line (got $(grep -c 'no floor runner allowed' "$LOGF"))"
grep -q 'CLIFF REFUSED (attempt 1 of' "$LOGF" && [ "$(cat "$PSPOOL" 2>/dev/null)" = "$RAW" ] && ok \
  || bad "R5b: the family goes down the cliff deferral path and is re-spooled (log: $(grep CLIFF "$LOGF"))"

# ---------- R2 — the real agent-call never runs grok on that list -------------
A="$T/ac"
mrs_fixture "$A"
mkdir -p "$A/bin" "$A/fakebin" "$A/flags" "$A/locks" "$A/logs" "$A/state"
printf '#!/bin/bash\necho grok >> "$ORDER_SINK"\necho "grok answered"\n' > "$A/fakebin/grok"
printf '#!/bin/bash\necho claude >> "$ORDER_SINK"\necho "handled=1 escalated=0 noise=0"\n' > "$A/fakebin/claude"
printf '#!/bin/bash\necho codex >> "$ORDER_SINK"\necho "codex answered"\n' > "$A/fakebin/codex"
cat > "$A/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
printf '#!/bin/bash\necho subscription\n' > "$A/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$A/bin/beat.sh"
printf '#!/bin/bash\necho "test rules"\n' > "$A/bin/sync-agent-rules.sh"
chmod +x "$A/fakebin/"* "$A/bin/"*
r2() { # r2 [AGENT_CALL_RUNNERS value, empty = unset]
  : > "$A/order"
  # GROK_MODEL is pinned and the worker env cut: with HARNESS_SECRET in the
  # environment agent-call asked the LIVE worker for grok.default, and without
  # it grok had no model and was skipped, so the control flipped by host.
  ( unset HARNESS_SECRET JOBS_URL CONSOLE_URL
    export ORDER_SINK="$A/order" PATH="$A/fakebin:$PATH" HARNESS="$A" HOME="$A" \
           OPENROUTER_API_KEY=test FIREWORKS_API_KEY=test LADDER_BACKOFF_SECS=0 AGENT_CALL_LEDGER=0 \
           RUNNER_TRIAGE=grok GROK_MODEL=grok-test-fixture CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" AGENT_CALL_LANE=alert-triage
    [ -n "${1:-}" ] && export AGENT_CALL_RUNNERS="$1"
    bash "$DIR/bin/agent-call.sh" triage alert-triage claude-fable-5-1 60 "$A/out.txt" "hello" >/dev/null 2>&1 )
}
r2
grep -qx grok "$A/order" && ok || bad "R2 control: without a list, RUNNER_TRIAGE=grok runs grok (order: $(paste -sd, "$A/order")) — the check below would be vacuous"
r2 claude,fireworks
! grep -qx grok "$A/order" && ok || bad "R2: AGENT_CALL_RUNNERS=claude,fireworks must never run grok (order: $(paste -sd, "$A/order"))"
grep -qx claude "$A/order" && ok || bad "R2: claude runs instead (order: $(paste -sd, "$A/order"))"

# ---------- R6 — runner names only, never a model id --------------------------
# R6 SCOPE (2026-09-29, Sonnet 5.5): catalog/model-prices.json and
# catalog/model-slugs.json are the fleet's one sanctioned list of model ids
# (PUT /api/model-routes refuses a model with no price row), so a new vendor
# model has to land there. They are excluded; every other path under bin/,
# catalog/ and worker/ is still scanned exactly as before.
# BH-4987: worker/*/schema.d/ fragments are the bytes of worker/*/schema.sql
# (bin/schema-build.sh --check keeps them equal), so a literal is judged once,
# on schema.sql, and a seed row moved between fragments is not an addition.
BASE=$(git -C "$DIR" merge-base HEAD origin/main 2>/dev/null) || BASE=""
if [ -n "$BASE" ]; then
  HITS=$(git -C "$DIR" diff "$BASE" -- bin catalog worker ':(exclude)catalog/model-prices.json' ':(exclude)catalog/model-slugs.json' ':(exclude,glob)worker/*/schema.d/**' | grep -E '^\+.*(claude-[a-z]+-[0-9]|gpt-|accounts/fireworks/models)')
  [ -z "$HITS" ] && ok || bad "R6: a model id was added under bin/catalog/worker: $HITS"
else
  echo "R6: skipped (no origin/main in this checkout)"
fi
! grep -nE 'export +(AGENT_CALL_RUNNERS|TRIAGE_ALLOW|FLOOR_ALLOW)' "$DIR/bin/alert-triage.sh" && ok \
  || bad "R6: the allowlist is a per-command env prefix, never an export"

echo "alert-triage-runners.bh-2544: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
