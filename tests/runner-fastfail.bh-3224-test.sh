#!/bin/bash
# tests/runner-fastfail.bh-3224-test.sh — BH-3224: a runner that fails at once
# with no usage is skipped until its cooldown ends, and the first real call
# after that is the reprobe.
#
# The L cases drive bin/lib/runner-fastfail.sh directly in a scratch HARNESS:
#   L1  grok rc 1 in 0 s, no tokens -> live
#   L2  a slow failure, or a fast one that reported tokens -> not live
#   L3  rc 0 -> marker removed (the reprobe passing)
#   L4  rc 79 / 74 (nothing was called) -> no marker
#   L5  claude with the default list -> no marker; COOLDOWN_S=0 -> no marker
#   L6  RUNNER_FASTFAIL_S=abc -> default 5, a 9 s failure does not arm; an
#       expired marker is not live; a re-mark keeps `since`
# The A cases run the REAL bin/agent-call.sh with stub CLIs that append their
# name to an order file (the tests/alert-triage-runners.bh-2544-test.sh R2
# scaffold):
#   A1  RUNNER_TRIAGE=grok, grok exits 1 at once: call 1 runs grok then claude,
#       call 2 runs claude only; failovers.log says `cooling down until`, and
#       ALERTS.log has no "not installed/authed" line for grok
#   A1c RUNNER_FASTFAIL_COOLDOWN_S=0: call 2 runs grok again (A1 is not vacuous)
#   A2  grok fails after 2 s with RUNNER_FASTFAIL_S=1: call 2 still runs grok
#   A3  tier-2: RUNNER_TRIAGE=claude, claude fails, grok cooling -> no grok
#   A4  expired marker, grok answers -> grok runs, marker removed
#   A5  expired marker, grok fails at once -> re-armed, same `since`
#   A6  AGENT_CALL_RUNNERS=grok with grok cooling -> rc 2, `cooling down`
#   A7  grok killed (rc 143, fast) -> no marker
#   A8  a lib.runner-fastfail.runner_fastfail_cooldown_s=0 settings row reaches
#       agent-call through lib_env_apply and turns the cooldown off
#   bash tests/runner-fastfail.bh-3224-test.sh     exit 0 = all pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/bin/lib/runner-fastfail.sh"
[ -r "$LIB" ] || bad "the lib $LIB is missing"

# ---------- L — the lib alone --------------------------------------------------
L="$T/l"; mkdir -p "$L/state"
MK="$L/state/runner-fastfail/grok"
lib() { # lib <shell snippet> — a fresh shell with the lib and a clean knob env
  ( unset RUNNER_FASTFAIL_RUNNERS RUNNER_FASTFAIL_S RUNNER_FASTFAIL_COOLDOWN_S
    for kv in "${LENV[@]}"; do export "${kv?}"; done
    . "$LIB" || exit 99
    eval "$1" )
}
lreset() { scratch_rm "$L/state"; mkdir -p "$L/state"; LENV=(); }
field() { tr ' ' '\n' < "$1" 2>/dev/null | sed -n "s/^$2=//p"; }
NOW=$(date +%s)

lreset
lib 'rff_note "'"$L"'" grok 1 0 "" ""; rff_live "'"$L"'" grok' && ok || bad "L1: an instant no-usage grok failure arms the cooldown"
[ -f "$MK" ] && [ "$(field "$MK" rc)" = 1 ] && [ "$(field "$MK" until)" -gt "$NOW" ] && ok \
  || bad "L1: the marker names rc=1 and an until in the future (got: $(cat "$MK" 2>/dev/null))"
lib 'rff_until "'"$L"'" grok' | grep -Eq '^[0-9]{2}:[0-9]{2}Z$' && ok || bad "L1: rff_until prints HH:MMZ (got: $(lib 'rff_until "'"$L"'" grok'))"

lreset
lib 'rff_note "'"$L"'" grok 1 9 "" ""'
! lib 'rff_live "'"$L"'" grok' && [ ! -f "$MK" ] && ok || bad "L2: a 9 s failure is not instant evidence"
lib 'rff_note "'"$L"'" grok 1 0 1200 0'
! lib 'rff_live "'"$L"'" grok' && ok || bad "L2: a fast failure that reported input tokens is a real vendor answer"
lib 'rff_note "'"$L"'" grok 1 0 0 35'
! lib 'rff_live "'"$L"'" grok' && ok || bad "L2: a fast failure that reported output tokens is a real vendor answer"

lreset
lib 'rff_note "'"$L"'" grok 1 0 "" ""'
lib 'rff_note "'"$L"'" grok 0 4 100 20'
[ ! -f "$MK" ] && ok || bad "L3: rc 0 removes the marker (got: $(cat "$MK" 2>/dev/null))"

lreset
lib 'rff_note "'"$L"'" grok 79 0 "" ""; rff_note "'"$L"'" grok 74 0 "" ""'
[ ! -f "$MK" ] && ok || bad "L4: rc 79 / 74 called nothing, so nothing is marked"
lib 'rff_note "'"$L"'" grok 1 0 "" ""'
lib 'rff_note "'"$L"'" grok 76 0 "" ""'
[ -f "$MK" ] && ok || bad "L4: rc 76 neither marks nor clears"

lreset
lib 'rff_note "'"$L"'" claude 1 0 "" ""'
[ ! -e "$L/state/runner-fastfail/claude" ] && ok || bad "L5: claude is not in the default list"
! lib 'rff_enabled claude' && lib 'rff_enabled grok' && ok || bad "L5: rff_enabled answers grok yes, claude no by default"
LENV=(RUNNER_FASTFAIL_COOLDOWN_S=0)
lib 'rff_note "'"$L"'" grok 1 0 "" ""'
[ ! -f "$MK" ] && ! lib 'rff_enabled grok' && ok || bad "L5: RUNNER_FASTFAIL_COOLDOWN_S=0 is off"
LENV=(RUNNER_FASTFAIL_RUNNERS=" grok , codex ")
lib 'rff_note "'"$L"'" codex 1 0 "" ""'
[ -f "$L/state/runner-fastfail/codex" ] && ok || bad "L5: a spaced list ' grok , codex ' is normalised and names codex"
LENV=()
! lib 'rff_note "'"$L"'" "../x" 1 0 "" ""; rff_live "'"$L"'" "../x"' && [ ! -e "$L/state/x" ] && ok \
  || bad "L5: a runner name that is not ^[a-z0-9_-]+\$ builds no path"

lreset
LENV=(RUNNER_FASTFAIL_S=abc RUNNER_FASTFAIL_COOLDOWN_S=xyz)
lib 'rff_note "'"$L"'" grok 1 9 "" ""'
[ ! -f "$MK" ] && ok || bad "L6: RUNNER_FASTFAIL_S=abc falls back to 5, so a 9 s failure does not arm"
lib 'rff_note "'"$L"'" grok 1 3 "" ""'
U=$(field "$MK" until)
[ -n "$U" ] && [ "$U" -ge $((NOW + 1700)) ] && ok || bad "L6: COOLDOWN_S=xyz falls back to 1800, never 0 (until=$U now=$NOW)"
LENV=()
mkdir -p "$L/state/runner-fastfail"
printf 'until=%s since=1000 rc=1 elapsed=1\n' "$((NOW - 60))" > "$MK"
! lib 'rff_live "'"$L"'" grok' && [ -f "$MK" ] && ok || bad "L6: an expired marker is not live and is left in place"
printf 'garbage\n' > "$MK"
! lib 'rff_live "'"$L"'" grok' && ok || bad "L6: an unparseable marker is not live"
printf 'until=%s since=1000 rc=1 elapsed=1\n' "$((NOW - 60))" > "$MK"
lib 'rff_note "'"$L"'" grok 1 1 "" ""'
[ "$(field "$MK" since)" = 1000 ] && lib 'rff_live "'"$L"'" grok' && ok \
  || bad "L6: a re-mark keeps since=1000 and is live again (got: $(cat "$MK" 2>/dev/null))"

# ---------- A — the REAL agent-call ---------------------------------------------
A="$T/ac"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$A"
mkdir -p "$A/bin" "$A/fakebin" "$A/flags" "$A/locks" "$A/logs" "$A/state"
# grok: GROK_MODE fail (rc 1 at once, no output), slow (2 s then rc 1), kill
# (SIGTERM itself: rc 143 well inside the window), anything else answers.
cat > "$A/fakebin/grok" <<'EOF'
#!/bin/bash
echo grok >> "$ORDER_SINK"
case "${GROK_MODE:-ok}" in
  fail) exit 1 ;;
  slow) sleep 2; exit 1 ;;  # determinism: ok the stub IS the slow vendor under test; elapsed >= 2 s holds under any load
  kill) kill -TERM $$ ;;
esac
echo "grok answered"
EOF
cat > "$A/fakebin/claude" <<'EOF'
#!/bin/bash
echo claude >> "$ORDER_SINK"
[ "${CLAUDE_MODE:-ok}" = fail ] && { echo "Error: internal server error" >&2; exit 1; }
echo "handled=1 escalated=0 noise=0"
EOF
printf '#!/bin/bash\necho codex >> "$ORDER_SINK"\nexit 1\n' > "$A/fakebin/codex"
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
AMK="$A/state/runner-fastfail/grok"
areset() { scratch_rm "$A/state/runner-fastfail"; rm -f "$A"/flags/alerted-* "$A"/flags/noted-*; : > "$A/logs/failovers.log"; : > "$A/logs/ALERTS.log"; }
# ac [VAR=value ...] — one call; ORDER is the runners it ran, comma-joined.
ac() {
  : > "$A/order"
  # GROK_MODEL is pinned and the worker env cut, so no live settings row, model
  # route or grok.default answer can reach the fixture. The fallback is pinned
  # to claude: the fixture's route rung 1 would be codex, which has no auth here.
  ( unset HARNESS_SECRET JOBS_URL CONSOLE_URL RUNNER_FASTFAIL_RUNNERS RUNNER_FASTFAIL_S RUNNER_FASTFAIL_COOLDOWN_S AGENT_CALL_RUNNERS
    export ORDER_SINK="$A/order" PATH="$A/fakebin:$PATH" HARNESS="$A" HOME="$A" \
           LADDER_BACKOFF_SECS=0 AGENT_CALL_LEDGER=0 RUNNER_TRIAGE=grok RUNNER_TRIAGE_FALLBACK=claude \
           GROK_MODEL=grok-test-fixture CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json"
    for kv in "$@"; do export "${kv?}"; done
    bash "$DIR/bin/agent-call.sh" triage bh3224 claude-fable-5-1 60 "$A/out.txt" "hello" >/dev/null 2>&1 )
  RC=$?
  ORDER=$(paste -sd, "$A/order")
}

# A1 — the ticket's test
areset
ac GROK_MODE=fail; O1="$ORDER"
ac GROK_MODE=fail; O2="$ORDER"
[ "${O1%%,*}" = grok ] && [[ ",$O1," == *,claude,* ]] && ok || bad "A1: call 1 runs grok first, then claude (order: $O1)"
[ "$O2" = claude ] && ok || bad "A1: call 2 inside the window skips grok (order: $O2)"
[ "$RC" = 0 ] && ok || bad "A1: call 2 succeeds on claude (rc $RC)"
grep -q 'grok skipped: failed instantly (rc=1, [0-9]*s, no usage) .* cooling down until [0-9][0-9]:[0-9][0-9]Z, using claude' "$A/logs/failovers.log" && ok \
  || bad "A1: failovers.log names the skip (log: $(grep -i grok "$A/logs/failovers.log" | tail -3))"
! grep -q "runner 'grok' .*not installed/authed" "$A/logs/ALERTS.log" && ok \
  || bad "A1: a cooldown skip never writes the not-installed ALERTS line (ALERTS: $(cat "$A/logs/ALERTS.log"))"
[ -f "$AMK" ] && ok || bad "A1: the marker is on disk after call 1"

# A1c — the control
areset
ac GROK_MODE=fail RUNNER_FASTFAIL_COOLDOWN_S=0
ac GROK_MODE=fail RUNNER_FASTFAIL_COOLDOWN_S=0
[ "${ORDER%%,*}" = grok ] && ok || bad "A1c: with the cooldown off, call 2 runs grok again (order: $ORDER)"

# A2 — a slow failure is not instant evidence
areset
ac GROK_MODE=slow RUNNER_FASTFAIL_S=1
ac GROK_MODE=slow RUNNER_FASTFAIL_S=1
[ "${ORDER%%,*}" = grok ] && [ ! -f "$AMK" ] && ok || bad "A2: a 2 s failure with RUNNER_FASTFAIL_S=1 does not arm (order: $ORDER, marker: $(cat "$AMK" 2>/dev/null))"

# A3 — tier-2 grok is skipped while it cools
areset
ac RUNNER_TRIAGE=claude CLAUDE_MODE=fail
[[ ",$ORDER," == *,grok,* ]] && ok || bad "A3 control: a failing claude primary reaches tier-2 grok (order: $ORDER) — the check below would be vacuous"
areset
mkdir -p "$A/state/runner-fastfail"
printf 'until=%s since=%s rc=1 elapsed=1\n' "$(( $(date +%s) + 900 ))" "$(date +%s)" > "$AMK"
ac RUNNER_TRIAGE=claude CLAUDE_MODE=fail
[[ ",$ORDER," != *,grok,* ]] && ok || bad "A3: tier-2 grok is skipped while it cools (order: $ORDER)"

# A4 — the reprobe passing
areset
mkdir -p "$A/state/runner-fastfail"
printf 'until=%s since=1000 rc=1 elapsed=1\n' "$(( $(date +%s) - 60 ))" > "$AMK"
ac GROK_MODE=ok
[ "$ORDER" = grok ] && [ ! -f "$AMK" ] && ok || bad "A4: an expired marker lets grok run, and its success clears it (order: $ORDER, marker: $(cat "$AMK" 2>/dev/null))"

# A5 — the reprobe failing
areset
mkdir -p "$A/state/runner-fastfail"
printf 'until=%s since=1000 rc=1 elapsed=1\n' "$(( $(date +%s) - 60 ))" > "$AMK"
ac GROK_MODE=fail
U=$(field "$AMK" until)
[ "${ORDER%%,*}" = grok ] && [ "$(field "$AMK" since)" = 1000 ] && [ -n "$U" ] && [ "$U" -gt "$(date +%s)" ] && ok \
  || bad "A5: a failed reprobe re-arms with the same since (order: $ORDER, marker: $(cat "$AMK" 2>/dev/null))"

# A6 — a restricted call names the cooldown, not a missing install
areset
mkdir -p "$A/state/runner-fastfail"
printf 'until=%s since=%s rc=1 elapsed=1\n' "$(( $(date +%s) + 900 ))" "$(date +%s)" > "$AMK"
ac AGENT_CALL_RUNNERS=grok GROK_MODE=ok
[ "$RC" = 2 ] && [ -z "$ORDER" ] && ok || bad "A6: rc 2 and nothing ran (rc $RC, order: $ORDER)"
grep -q 'cooling down' "$A/out.txt" && ! grep -q 'not installed' "$A/out.txt" && ok \
  || bad "A6: \$OUT says cooling down (got: $(cat "$A/out.txt"))"
grep -q 'cooling down after instant failures' "$A/logs/failovers.log" && ! grep -q 'not installed/authed' "$A/logs/failovers.log" && ok \
  || bad "A6: the refusal line names the cooldown (log: $(tail -2 "$A/logs/failovers.log"))"

# A7 — an external kill is not vendor evidence
areset
ac GROK_MODE=kill
[ "${ORDER%%,*}" = grok ] && [ ! -f "$AMK" ] && ok || bad "A7: a fast rc 143 kill never arms (order: $ORDER, marker: $(cat "$AMK" 2>/dev/null))"

# A8 — the knob is a settings row: lib.runner-fastfail.runner_fastfail_cooldown_s=0,
# as the box settings cache carries it, reaches agent-call and turns the
# cooldown off, so call 2 runs grok again.
. "$DIR/tests/lib/rendered.sh" || exit 1
mkdir -p "$A/catalog"; cp "$(rendered_registry)" "$A/catalog/lanes.json"
areset
jq -nc --argjson fa "$(date -u +%s)" '{fetched_at:$fa,values:{"lib.runner-fastfail.runner_fastfail_cooldown_s":"0"},seeded:{}}' > "$A/state/settings-cache.json"
ac GROK_MODE=fail
ac GROK_MODE=fail
[ "${ORDER%%,*}" = grok ] && [ ! -f "$AMK" ] && ok || bad "A8: the settings row COOLDOWN_S=0 reaches agent-call (order: $ORDER)"
rm -f "$A/state/settings-cache.json" "$A/catalog/lanes.json"

echo "runner-fastfail.bh-3224: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
