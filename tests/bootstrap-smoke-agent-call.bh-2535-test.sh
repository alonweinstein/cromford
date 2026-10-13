#!/bin/bash
# tests/bootstrap-smoke-agent-call.bh-2535-test.sh — the bootstrap smoke turn
# goes through bin/agent-call.sh (stage probe, lane claude-auth-check, pinned
# to the claude runner) so it writes a priced cost row, instead of a bare
# `claude -p` that wrote none (BH-2535).
#
# The `# >>> smoke model` / `# <<< smoke model` block is extracted VERBATIM from
# bin/bootstrap-machine.sh and run under `set -euo pipefail`, with HERE pointing
# at a scratch bin/ holding a lib/model-route.sh stub and an agent-call.sh stub
# that logs its argv and env, and a PATH `claude` stub that must never run.
#
#   B1  a route: exactly one agent-call, argv `probe fleet <routed> 90 <out>
#       Reply exactly: OK`, AGENT_CALL_RUNNERS=claude, AGENT_CALL_LANE=
#       claude-auth-check; bootstrap goes on;
#   B2  the PATH `claude` is never invoked, in any case;
#   B3  agent-call rc 1: FATAL `claude session failed`, rc 1, bootstrap stops;
#   B4  agent-call rc 74 with a refusal line in the outfile: FATAL rc 1 quoting it;
#   B5  agent-call rc 0 with an empty outfile: FATAL rc 1;
#   B6  the census row says through agent-call / priced / probe / claude-auth-check,
#       and neither raw-call allowlist still names bin/bootstrap-machine.sh;
#   B7  no route: agent-call never runs, the FATAL names bootstrap.smoke.
# Run from anywhere: tests/bootstrap-smoke-agent-call.bh-2535-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2' want '$3'"; fi; }

awk '/^# >>> smoke model/{f=1;next} /^# <<< smoke model/{exit} f' \
  "$DIR/bin/bootstrap-machine.sh" > "$T/smoke.sh"
[ -s "$T/smoke.sh" ] && ok \
  || bad "could not extract the smoke model block from bin/bootstrap-machine.sh — markers missing?"

mkdir -p "$T/bin/lib" "$T/path"
cat > "$T/bin/lib/model-route.sh" <<'SH'
model_for() {
  [ "$1" = bootstrap.smoke ] || { echo "wrong role $1" >&2; return 1; }
  cat "$ROUTE"; return "$(cat "$ROUTE_RC")"
}
SH
# agent-call stub: one line per call — argc, then each argv word on its own
# line, then the two env knobs. Writes $AC_ANSWER to argv[5], exits $AC_RC.
cat > "$T/bin/agent-call.sh" <<'SH'
#!/bin/bash
{ echo "CALL $#"; for a in "$@"; do printf 'ARG %s\n' "$a"; done
  echo "RUNNERS ${AGENT_CALL_RUNNERS-<unset>}"; echo "LANE ${AGENT_CALL_LANE-<unset>}"; } >> "$AC_LOG"
printf '%s' "$AC_ANSWER" > "$5"
echo '{}' > "$5.json"   # agent-call leaves sidecars next to the outfile
exit "$AC_RC"
SH
chmod +x "$T/bin/agent-call.sh"
cat > "$T/path/claude" <<'SH'
#!/bin/bash
echo "$*" >> "$CLAUDE_LOG"
exit 99
SH
chmod +x "$T/path/claude"
export AC_LOG="$T/ac.log" CLAUDE_LOG="$T/claude.log" ROUTE="$T/route" ROUTE_RC="$T/route-rc"

# run_block <model> <route rc> <agent-call rc> <answer> -> rc; output in $T/out
run_block() {
  printf '%s' "$1" > "$ROUTE"; echo "$2" > "$ROUTE_RC"; rm -f "$AC_LOG" "$CLAUDE_LOG"
  (
    cd "$T" || exit 1
    PATH="$T/path:$PATH" HERE="$T/bin" TMPDIR="$T" AC_RC="$3" AC_ANSWER="$4" \
      bash -c 'set -euo pipefail; . ./smoke.sh; echo AFTER-SMOKE'
  ) >"$T/out" 2>&1
  echo $?
}
claude_ran() { [ -s "$CLAUDE_LOG" ]; }

# ── B1
RC=$(run_block 'routed-model-xyz' 0 0 'OK')
eq "B1 rc" "$RC" 0
eq "B1 agent-call calls" "$(grep -c '^CALL ' "$AC_LOG" 2>/dev/null || echo 0)" 1
eq "B1 argc" "$(grep '^CALL ' "$AC_LOG" 2>/dev/null)" "CALL 6"
ARGS=$(grep '^ARG ' "$AC_LOG" 2>/dev/null | sed 's/^ARG //')
eq "B1 stage"   "$(sed -n 1p <<<"$ARGS")" probe
eq "B1 project" "$(sed -n 2p <<<"$ARGS")" fleet
eq "B1 model"   "$(sed -n 3p <<<"$ARGS")" routed-model-xyz
eq "B1 timeout" "$(sed -n 4p <<<"$ARGS")" 90
[ -n "$(sed -n 5p <<<"$ARGS")" ] && ok || bad "B1 outfile argv[5] is empty"
eq "B1 prompt"  "$(sed -n 6p <<<"$ARGS")" "Reply exactly: OK"
eq "B1 runners" "$(grep '^RUNNERS ' "$AC_LOG" 2>/dev/null)" "RUNNERS claude"
eq "B1 lane"    "$(grep '^LANE ' "$AC_LOG" 2>/dev/null)" "LANE claude-auth-check"
grep -q 'AFTER-SMOKE' "$T/out" && ok || bad "B1: bootstrap must continue past the smoke: $(cat "$T/out")"
claude_ran && bad "B2 (route): the bare claude CLI ran: $(cat "$CLAUDE_LOG")" || ok
OUTF=$(sed -n 5p <<<"$ARGS")
[ -n "$OUTF" ] && [ ! -e "$OUTF" ] && [ ! -e "$OUTF.json" ] && ok \
  || bad "B1: the smoke outfile and its sidecars must be removed after the call ($OUTF)"

# ── B3
RC=$(run_block 'routed-model-xyz' 0 1 'boom')
eq "B3 rc" "$RC" 1
grep -q 'FATAL: claude session failed' "$T/out" && ok || bad "B3: a failing agent-call must be FATAL: $(cat "$T/out")"
grep -q 'AFTER-SMOKE' "$T/out" && bad "B3: bootstrap must stop on a failing smoke" || ok
claude_ran && bad "B2 (rc 1): the bare claude CLI ran" || ok

# ── B4
RC=$(run_block 'routed-model-xyz' 0 74 'LANE_DISABLED claude-auth-check')
eq "B4 rc" "$RC" 1
grep -q 'FATAL: claude session failed' "$T/out" && ok || bad "B4: a refused call must be FATAL: $(cat "$T/out")"
grep -q 'LANE_DISABLED claude-auth-check' "$T/out" && ok || bad "B4: the FATAL must quote the refusal: $(cat "$T/out")"
grep -q 'AFTER-SMOKE' "$T/out" && bad "B4: bootstrap must stop on a refused smoke" || ok
claude_ran && bad "B2 (rc 74): the bare claude CLI ran" || ok

# ── B5
RC=$(run_block 'routed-model-xyz' 0 0 '')
eq "B5 rc" "$RC" 1
grep -q 'FATAL: claude session failed' "$T/out" && ok || bad "B5: rc 0 with no answer must be FATAL: $(cat "$T/out")"
grep -q 'AFTER-SMOKE' "$T/out" && bad "B5: bootstrap must stop on an empty answer" || ok

# ── B7
RC=$(run_block '' 75 0 'OK')
eq "B7 rc" "$RC" 1
[ -s "$AC_LOG" ] && bad "B7: agent-call must never run without a route: $(cat "$AC_LOG")" || ok
grep -q 'no model route for bootstrap.smoke' "$T/out" && ok || bad "B7: the FATAL must name the role: $(cat "$T/out")"
claude_ran && bad "B2 (no route): the bare claude CLI ran" || ok

# ── B6
ROW=$(jq -r '.sites[]|select(.id=="bootstrap-machine")|[.through_agent_call,.priced,.stage,.lane,.kind,.gated]|@tsv' "$DIR/catalog/llm-sites.json")
eq "B6 census row" "$ROW" "$(printf 'true\tyes\tprobe\tclaude-auth-check\tagent-call\tagent-call')"
for f in tests/raw-claude-allowlist.txt tests/llm-call-ratchet-allowlist.txt; do
  grep -q '^bin/bootstrap-machine\.sh' "$DIR/$f" && bad "B6: $f still allowlists bin/bootstrap-machine.sh" || ok
done

echo "bootstrap-smoke-agent-call.bh-2535: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
