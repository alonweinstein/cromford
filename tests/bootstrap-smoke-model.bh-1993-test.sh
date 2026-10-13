#!/bin/bash
# tests/bootstrap-smoke-model.bh-1993-test.sh — the bootstrap claude smoke test
# takes its model from model_routes, never from a literal (BH-1993, the #1979
# review: a hardcoded id breaks the day it retires).
#
# The `# >>> smoke model` / `# <<< smoke model` block (BH-1510.4, which landed
# the same fix on main first: role bootstrap.smoke, no route is FATAL) is
# extracted VERBATIM from bin/bootstrap-machine.sh and run under
# `set -euo pipefail`, with HERE pointing at a scratch lib/model-route.sh stub
# and a scratch bin/agent-call.sh stub that logs its argv (since BH-2535 the
# smoke goes through agent-call, not a bare `claude -p`).
#
#   S1  a route for bootstrap.smoke: agent-call gets the routed model as argv[3],
#       bootstrap goes on;
#   S2  no route (rc 75): FATAL rc 1 naming the role, agent-call never runs;
#   S4  a DB value with shell characters reaches agent-call as ONE argv word;
#   S5  model-route.sh missing: FATAL rc 1, agent-call never runs;
#   S6  the smoke call failing is still FATAL, rc 1;
#   S7  bin/bootstrap-machine.sh holds no claude model literal.
# (S3, "a non-claude rung 0 runs no --model", pinned the triage.light fallback
# this branch shipped before main's block replaced it; bootstrap.smoke is a
# dedicated role, so its runner is not the block's to second-guess.)
# Run from anywhere: tests/bootstrap-smoke-model.bh-1993-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2' want '$3'"; fi; }

awk '/^# >>> smoke model/{f=1;next} /^# <<< smoke model/{exit} f' \
  "$DIR/bin/bootstrap-machine.sh" > "$T/smoke.sh"
[ -s "$T/smoke.sh" ] && ok \
  || bad "could not extract the smoke model block from bin/bootstrap-machine.sh — markers missing?"

mkdir -p "$T/bin/lib" "$T/path"
cat > "$T/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$#:$1 $2 $3 $4 $6" > "$ARGV_LOG"
printf '%s\n' "$3" > "$ARGV_LOG.model"
[ -f "$CLAUDE_FAIL" ] && exit 1
echo OK > "$5"
SH
chmod +x "$T/bin/agent-call.sh"
# A bare `claude` on PATH is a trap: the smoke must never reach it directly.
printf '#!/bin/bash\necho "$*" >> "$ARGV_LOG.claude"\nexit 99\n' > "$T/path/claude"
chmod +x "$T/path/claude"
export ARGV_LOG="$T/argv" CLAUDE_FAIL="$T/claude-fail" ROUTE="$T/route" ROUTE_RC="$T/route-rc"

# stub_lib — a model_for that prints $ROUTE and exits with $ROUTE_RC.
stub_lib() {
  cat > "$T/bin/lib/model-route.sh" <<'SH'
model_for() {
  [ "$1" = bootstrap.smoke ] || { echo "wrong role $1" >&2; return 1; }
  cat "$ROUTE"; return "$(cat "$ROUTE_RC")"
}
SH
}
# run_block <model text> <rc> -> rc; output in $T/out, argv in $ARGV_LOG
run_block() {
  printf '%s' "$1" > "$ROUTE"; echo "$2" > "$ROUTE_RC"; rm -f "$ARGV_LOG" "$ARGV_LOG.model"
  (
    cd "$T" || exit 1
    PATH="$T/path:$PATH" HERE="$T/bin" bash -c 'set -euo pipefail; . ./smoke.sh; echo AFTER-SMOKE'
  ) >"$T/out" 2>&1
  echo $?
}
argv() { cat "$ARGV_LOG" 2>/dev/null; }

stub_lib
# ── S1
RC=$(run_block 'model-x' 0)
eq "S1 rc" "$RC" 0
eq "S1 argv" "$(argv)" "6:probe fleet model-x 90 Reply exactly: OK"
grep -q 'AFTER-SMOKE' "$T/out" && ok || bad "S1: bootstrap must continue past the smoke: $(cat "$T/out")"
# ── S2
RC=$(run_block '' 75)
eq "S2 rc" "$RC" 1
eq "S2 argv" "$(argv)" ""
grep -q 'no model route for bootstrap.smoke' "$T/out" && ok || bad "S2: the FATAL must name the role: $(cat "$T/out")"
grep -q 'AFTER-SMOKE' "$T/out" && bad "S2: no route must stop bootstrap" || ok
# ── S4
RC=$(run_block 'x;rm -rf /' 0)
eq "S4 rc" "$RC" 0
eq "S4 argv" "$(argv)" "6:probe fleet x;rm -rf / 90 Reply exactly: OK"
eq "S4 model word" "$(cat "$ARGV_LOG.model" 2>/dev/null)" "x;rm -rf /"
# ── S5
rm -f "$T/bin/lib/model-route.sh"
RC=$(run_block 'model-x' 0)
eq "S5 rc" "$RC" 1
eq "S5 argv" "$(argv)" ""
grep -q 'AFTER-SMOKE' "$T/out" && bad "S5: a missing lib must stop bootstrap" || ok
stub_lib
# ── S6
touch "$CLAUDE_FAIL"
RC=$(run_block 'model-x' 0)
eq "S6 rc" "$RC" 1
grep -q 'FATAL: claude session failed' "$T/out" && ok || bad "S6: a failing smoke call must be FATAL: $(cat "$T/out")"
grep -q 'AFTER-SMOKE' "$T/out" && bad "S6: bootstrap must stop on a failing smoke call" || ok
rm -f "$CLAUDE_FAIL"
[ -s "$ARGV_LOG.claude" ] && bad "the bare claude CLI ran: $(cat "$ARGV_LOG.claude")" || ok
# ── S7
N=$(grep -cE 'claude-(haiku|sonnet|opus|fable)-[0-9]' "$DIR/bin/bootstrap-machine.sh")
eq "S7 model literals in bin/bootstrap-machine.sh" "$N" 0

echo "bootstrap-smoke-model.bh-1993: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
