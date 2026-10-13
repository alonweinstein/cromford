#!/bin/bash
# tests/run-preplan-prompt.bh-580-test.sh — the per-ticket test-file rule
# (#580/#586) reaches the PLANNER, in the prompt bin/run-preplan.sh actually
# sends.
#
# WHY THE PROMPT AND NOT THE LIST. The pre-plan list rewrite
# (bin/planned-files-cheap.sh) only fires for tickets that named a test file in
# their body; the planner is where the OTHER tickets get the rule, and a plan
# whose files-to-touch names the shared suite is how a sibling ends up appending
# to it three hours later. So this drives the REAL lane — lock, env, guards,
# worktree lines and all — against a scratch $HARNESS with a stubbed
# agent-call.sh that keeps the prompt argument, and asserts on that captured
# prompt. Deleting the interpolation must turn this red (D2).
#
# The second case is the one that keeps the fleet running: a box whose sync has
# not landed bin/lib/test-home-lib.sh yet must pre-plan EXACTLY as it does
# today, not fail.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/run-preplan-prompt.bh-580-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin/lib" "$T/env" "$T/flags" "$T/logs" "$T/plans" "$T/locks" "$T/repos/proj"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T" proj || exit 1  # BH-1510.2: lanes read models from model_routes
cp "$DIR/bin/run-preplan.sh" "$T/bin/" 2>/dev/null || { echo "FAIL: bin/run-preplan.sh does not exist"; exit 1; }
cp "$DIR/bin/lib/preplan-lib.sh" "$T/bin/lib/"
cp "$DIR/bin/lib/test-home-lib.sh" "$T/bin/lib/" 2>/dev/null || { echo "FAIL: bin/lib/test-home-lib.sh does not exist (#583 is this slice's hard blocker)"; exit 1; }
: > "$T/env/global.env"

# The stub keeps the PROMPT, which is the artifact under test, and writes no
# plan.md — the lane's own "produced no plan" path, which is the cheapest way to
# run it end to end without a model.
cat > "$T/bin/agent-call.sh" <<'STUB'
#!/bin/bash
# agent-call.sh <stage> <project> <model> <timeout> <outfile> <prompt>
printf '%s\n' "$1" >> "${PROMPT_DIR:?}/stages.txt"
printf '%s' "$6" > "${PROMPT_DIR:?}/prompt.txt"
exit 0
STUB
chmod +x "$T/bin/agent-call.sh"

# A git that agrees with everything: the lane's read-only worktree is not what
# this suite is about, and a real `git worktree add` would need a real repo.
cat > "$T/bin/git" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$T/bin/git"
export PATH="$T/bin:$PATH"
export PROMPT_DIR="$T"

lane() { # lane <KEY> -> rc of the real bin/run-preplan.sh
  rm -f "$T/prompt.txt"
  HARNESS="$T" REPOS_ROOT="$T/repos" bash "$T/bin/run-preplan.sh" proj 1 "$1" >/dev/null 2>&1
}

# ---------- 1. the rule is in the prompt the planner is sent ----------------
lane AB-1; RC=$?
[ "$RC" = 0 ] && ok || bad "the pre-plan lane must exit 0 against the scratch tree (rc: $RC)"
[ -s "$T/prompt.txt" ] && ok || bad "the lane must have reached agent-call.sh with a prompt"
P=$(cat "$T/prompt.txt" 2>/dev/null)
grep -qF 'TEST FILES ARE PER-TICKET' <<<"$P" && ok \
  || bad "the preplan prompt must carry the per-ticket test-file rule"
grep -qF 'tests/<tier>/<area>.ab-1.test.ts' <<<"$P" && ok \
  || bad "the rule must name THIS ticket's key, lower-cased, in the vitest example"
grep -qF 'tests/<area>.ab-1-test.sh' <<<"$P" && ok \
  || bad "the rule must name THIS ticket's key in the shell-suite example"
grep -qF 'never appended to an existing shared test file' <<<"$P" && ok \
  || bad "the rule must say what is forbidden, not only what is preferred"
grep -qF 'List the per-ticket file in the plan' <<<"$P" && ok \
  || bad "the rule must tell the planner to put the file in files-to-touch — that list is what the next stage reads"
# ...and nothing the lane already said may have moved.
grep -qF 'Read ticket AB-1 (id 1)' <<<"$P" && ok \
  || bad "the ticket line must be unchanged"
grep -qF 'Write a precise implementation plan' <<<"$P" && ok \
  || bad "the plan instruction must be unchanged"
grep -qx 'preplan' "$T/stages.txt" 2>/dev/null && ok \
  || bad "the call must still be billed to the preplan stage (got: $(cat "$T/stages.txt" 2>/dev/null))"

# ---------- 2. a box whose sync has not landed the lib ----------------------
# Fail-open is the property under test: no lib, no rule, and the lane runs
# exactly as it does on main today.
mv "$T/bin/lib/test-home-lib.sh" "$T/lib-parked.sh"
rm -f "$T/stages.txt"
lane AB-2; RC=$?
[ "$RC" = 0 ] && ok || bad "with the lib absent the lane must still exit 0 (rc: $RC)"
P2=$(cat "$T/prompt.txt" 2>/dev/null)
grep -qF 'TEST FILES ARE PER-TICKET' <<<"$P2" \
  && bad "with no lib there is no rule to interpolate — the prompt must not carry one" || ok
grep -qF 'Write a precise implementation plan' <<<"$P2" && ok \
  || bad "with the lib absent the rest of the prompt must be intact"
grep -qF 'Read ticket AB-2 (id 1)' <<<"$P2" && ok \
  || bad "with the lib absent the ticket line must be intact"
mv "$T/lib-parked.sh" "$T/bin/lib/test-home-lib.sh"

echo "run-preplan-prompt.bh-580: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
