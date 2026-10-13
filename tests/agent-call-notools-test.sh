#!/bin/bash
# tests/agent-call-notools-test.sh — AGENT_CALL_NO_TOOLS=1 is a CONTRACT, and
# this drives bin/agent-call.sh for real to prove it.
#
# WHY DRIVEN AND NOT GREPPED. The prompt-eval lane replays recorded board states
# through the same runner that builds and comments on real client boards, with
# the hub's real credentials on the box. Its only protection against a session
# taking the SOP literally is that the tools are not there. A guard whose only
# evidence is `grep -q -- --tools bin/agent-call.sh` is the exact shape of guard
# this repo keeps discovering was inert all along — so agent-call.sh is run
# against a temp HARNESS with fake CLIs on PATH, and what it actually passed is
# read back off disk.
#
# WHAT THIS DOES NOT PROVE: that `--tools ""` makes the model toolless. That is
# a claim about the CLI, not about this script, and it stays UNVERIFIED until
# the first live eval run (recorded as such in catalog/context-budgets.json).
# What is proven here is that the flag is passed, that the permission bypass is
# not, and that no other runner can be reached.
# Run from anywhere: tests/agent-call-notools-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/logs" "$T/locks" "$T/flags" "$T/fakebin" "$T/state"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# Fake claude: records its argv, then answers like the real CLI's json envelope.
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$ARGV_SINK"
printf '{"result":"DECISION: TK-1 :: skip :: fake","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}\n'
EOF
# Fake grok/codex: must NEVER be reached under the contract. If one runs, it
# leaves a file behind and the test says so.
for R in grok codex; do
  cat > "$T/fakebin/$R" <<EOF
#!/bin/bash
touch "\$T_SENTINEL_DIR/$R-was-called"
echo "DECISION: TK-1 :: skip :: fake"
EOF
  chmod +x "$T/fakebin/$R"
done
chmod +x "$T/fakebin/claude"
# billing-mode.sh + beat.sh are called on the cost path; stub them so the run
# does not reach the real ones.
mkdir -p "$T/bin"
printf '#!/bin/bash\necho subscription\n' > "$T/fakebin/billing-mode.sh"; chmod +x "$T/fakebin/billing-mode.sh"

# GNU `timeout` does not exist on macOS, and agent-call.sh wraps every runner in
# it — without a shim this suite could not drive the claude lane at all on a
# dev box. Shimmed unconditionally so the test behaves identically here and in
# CI: strip `--kill-after=N` and the duration, run the rest.
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift    # the duration
exec "$@"
EOF
chmod +x "$T/fakebin/timeout"

run_call() { # run_call <extra-env...> ; writes $T/argv.txt, echoes the rc
  rm -f "$T/argv.txt" "$T/grok-was-called" "$T/codex-was-called"
  ( export ARGV_SINK="$T/argv.txt" T_SENTINEL_DIR="$T" \
           PATH="$T/fakebin:$PATH" HARNESS="$T" \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" \
           HOME="$T"
    "$@" bash "$DIR/bin/agent-call.sh" eval testproj claude-fable-5 60 "$T/out.txt" "hello" \
      >/dev/null 2>&1 )
  echo $?
}

# --- 1. NO_TOOLS=1 on claude: the ban is passed, the bypass is not ------------
RC=$(run_call env AGENT_CALL_NO_TOOLS=1)
[ -s "$T/argv.txt" ] && ok || bad "the claude lane was never invoked (rc=$RC)"
grep -qx -- '--tools' "$T/argv.txt" \
  && ok || bad "AGENT_CALL_NO_TOOLS=1 did not pass --tools (argv: $(tr '\n' ' ' < "$T/argv.txt"))"
# the value after --tools must be the empty string (the CLI's "disable all")
awk '/^--tools$/{getline v; if (v == "") found=1} END{exit found?0:1}' "$T/argv.txt" \
  && ok || bad "--tools was passed a non-empty value; only \"\" disables all tools"
grep -qx -- '--dangerously-skip-permissions' "$T/argv.txt" \
  && bad "a no-tools call still passed --dangerously-skip-permissions: if the tool ban is ever inert, that combination acts silently instead of stalling" || ok

# --- 2. the DEFAULT path is untouched ----------------------------------------
# This flag is additive. Every other lane in the fleet must behave exactly as it
# did before, or a safety feature has become a fleet-wide behaviour change.
RC=$(run_call env)
grep -qx -- '--dangerously-skip-permissions' "$T/argv.txt" \
  && ok || bad "a normal call lost --dangerously-skip-permissions — the flag is not additive"
grep -qx -- '--tools' "$T/argv.txt" \
  && bad "a normal call now disables tools — every build lane would be inert" || ok

# --- 3. a non-claude runner REFUSES, loudly, without calling anything --------
: > "$T/logs/ALERTS.log"
RC=$(run_call env AGENT_CALL_NO_TOOLS=1 RUNNER_EVAL=grok)
[ "$RC" != 0 ] && ok || bad "a no-tools call on grok exited 0 — the caller would treat an unguarded run as fine"
[ -f "$T/grok-was-called" ] \
  && bad "grok was actually invoked under the no-tools contract — the refusal is decorative" || ok
grep -q 'REFUSED' "$T/logs/ALERTS.log" \
  && ok || bad "the refusal is silent (nothing in ALERTS.log)"
# and nothing was billed for a call that never happened
[ ! -s "$T/logs/cost.csv" ] || ! grep -q ',grok,' "$T/logs/cost.csv" \
  && ok || bad "a cost row was written for a refused call"

# --- 4. the survival ladder cannot smuggle the prompt to an unguarded lane ---
# The tier-3/3b/4 blocks fire on rc!=0 for ANY stage. Under the contract they
# must not fire at all: a failing claude call must NOT become a grok call with
# working tools and live credentials. Driven by making the fake claude fail.
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$ARGV_SINK"
echo "boom" >&2
exit 1
EOF
chmod +x "$T/fakebin/claude"
mkdir -p "$T/.grok/bin"; cp "$T/fakebin/grok" "$T/.grok/bin/grok"
RC=$(run_call env AGENT_CALL_NO_TOOLS=1 XAI_API_KEY=x OPENROUTER_API_KEY=x FIREWORKS_API_KEY=x)
[ "$RC" != 0 ] && ok || bad "a failed no-tools call reported success"
[ -f "$T/grok-was-called" ] \
  && bad "the tier-4 grok survival lane ran a no-tools prompt with tools available" || ok
[ -f "$T/codex-was-called" ] \
  && bad "an openrouter/fireworks survival lane (codex CLI) ran a no-tools prompt with tools available" || ok

# --- 4b. the TOOL ALLOWLIST (AGENT_CALL_TOOLS, BH-4065) ----------------------
# The same contract applied to a list: only the named built-ins, no MCP server,
# no other runner, no ladder, and a malformed list refuses rather than falling
# back to the full tool set. The fake claude still fails here, which is what
# drives the ladder check.
RC=$(run_call env AGENT_CALL_TOOLS=WebSearch XAI_API_KEY=x OPENROUTER_API_KEY=x FIREWORKS_API_KEY=x)
awk '/^--tools$/{getline v; if (v == "WebSearch") found=1} END{exit found?0:1}' "$T/argv.txt" \
  && ok || bad "AGENT_CALL_TOOLS=WebSearch did not pass --tools WebSearch (argv: $(tr '\n' ' ' < "$T/argv.txt"))"
grep -qx -- '--strict-mcp-config' "$T/argv.txt" \
  && ok || bad "an allowlisted call did not pass --strict-mcp-config, so the box's MCP servers ride along"
awk '/^--mcp-config$/{getline v; if (v == "{\"mcpServers\":{}}") found=1} END{exit found?0:1}' "$T/argv.txt" \
  && ok || bad "an allowlisted call's --mcp-config is not the empty server set"
[ -f "$T/grok-was-called" ] || [ -f "$T/codex-was-called" ] \
  && bad "the survival ladder ran an allowlisted prompt on a runner with no allowlist" || ok
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$ARGV_SINK"
printf '{"result":"ok","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}\n'
EOF
chmod +x "$T/fakebin/claude"
# The REFUSED lines go through bin/alert-line.sh, which appends to
# $T/logs/ALERTS.log on every path (its beat may fail here).
ln -sf "$DIR/bin/alert-line.sh" "$T/bin/alert-line.sh"
: > "$T/logs/ALERTS.log"
RC=$(run_call env AGENT_CALL_TOOLS=WebSearch RUNNER_EVAL=grok)
[ "$RC" != 0 ] && [ ! -f "$T/grok-was-called" ] && grep -q 'AGENT_CALL_TOOLS' "$T/logs/ALERTS.log" \
  && ok || bad "an allowlisted call on grok was not refused loudly (rc=$RC)"
for badlist in 'WebSearch Read' 'WebSearch,' 'Bash(rm:*)' ','; do
  : > "$T/logs/ALERTS.log"
  RC=$(run_call env AGENT_CALL_TOOLS="$badlist")
  [ "$RC" != 0 ] && [ ! -s "$T/argv.txt" ] && grep -q 'REFUSED' "$T/logs/ALERTS.log" \
    && ok || bad "AGENT_CALL_TOOLS='$badlist' must refuse with no call (rc=$RC, argv: $(tr '\n' ' ' < "$T/argv.txt" 2>/dev/null))"
done

# --- 5. HARNESS stays overridable -------------------------------------------
# The override is what makes every assertion above possible. If it regresses to
# a hard-coded absolute, this file silently starts testing /root/harness.
grep -q 'HARNESS="${HARNESS:-/root/harness}"' "$DIR/bin/agent-call.sh" \
  && ok || bad "agent-call.sh's HARNESS is no longer overridable — this suite would write to the real hub paths"

echo "agent-call-notools-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
