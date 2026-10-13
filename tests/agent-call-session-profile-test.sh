#!/bin/bash
# tests/agent-call-session-profile-test.sh — the headless SESSION PROFILE (P1)
# is driven through bin/agent-call.sh for real, against a temp HARNESS with a
# fake claude on PATH, and what the CLI was actually handed is read back off
# disk: argv, the env it ran under, and the files --settings / --mcp-config
# pointed at.
#
# WHAT IS PROVEN HERE
#   A  parity: with SESSION_PROFILE_STAGES unset the argv and env are exactly
#      what they were before this shipped (no new flag, no TTL env).
#   B  a profiled short lane (triage): strict MCP with an EMPTY server set,
#      plugins forced off in the merged settings file WITHOUT losing the
#      iron-law guard, dynamic sections excluded, TTL env 5m, one --model, no
#      --effort, no --setting-sources.
#   C  a profiled long lane (execute): TTL 1h, and the MCP config keeps the
#      codegraph server copied verbatim from the user config — and nothing else.
#   D  a stage NOT in the list is untouched.
#   E  a bad TTL value is not passed (the CLI would ignore it) and is logged.
#   F  an effort row puts exactly one --effort on the session.
#   G  PLUGINS_OFF=0 leaves enabledPlugins alone.
#   H  the cost row's note names the TTL the envelope SAYS was used.
#   I  a setting-sources row is validated before it is passed.
# WHAT IS NOT PROVEN HERE: that the real CLI honours the flags. That was probed
# by hand on claude 2.1.280 (--help lists every flag) and 2.1.282 (a live run:
# the TTL env moved the writes from ephemeral_1h to ephemeral_5m) — see
# docs/SESSION-PROFILE.md.
# Run from anywhere: tests/agent-call-session-profile-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/logs" "$T/locks" "$T/flags" "$T/fakebin" "$T/state" "$T/bin" "$T/.claude" "$T/wt"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The fake CLI: argv one per line, the cache env, and a copy of every file a
# --settings / --mcp-config flag named, then an envelope whose cache split is
# FAKE_TTL's.
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$ARGV_SINK"
env | grep -E '^CLAUDE_CODE_(SUBAGENT_)?PROMPT_CACHE_TTL=' > "$ENV_SINK"
prev=""
for a in "$@"; do
  case "$prev" in
    --settings)   cp "$a" "$ARGV_SINK.settings" 2>/dev/null ;;
    --mcp-config) cp "$a" "$ARGV_SINK.mcp" 2>/dev/null ;;
  esac
  prev="$a"
done
case "${FAKE_TTL:-}" in
  5m) cc='"cache_creation":{"ephemeral_5m_input_tokens":1000,"ephemeral_1h_input_tokens":0},' ;;
  1h) cc='"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":1000},' ;;
  *)  cc='' ;;
esac
printf '{"result":"ok","usage":{"input_tokens":10,"output_tokens":2,"cache_read_input_tokens":0,"cache_creation_input_tokens":1000,%s"x":0},"total_cost_usd":0.01}\n' "$cc"
EOF
chmod +x "$T/fakebin/claude"
printf '#!/bin/bash\necho subscription\n' > "$T/fakebin/billing-mode.sh"; chmod +x "$T/fakebin/billing-mode.sh"
# GNU timeout is absent on macOS; the same shim tests/agent-call-notools-test.sh uses.
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
chmod +x "$T/fakebin/timeout"
# A stand-in iron-law guard, so the settings merge has the guard to keep.
printf '#!/bin/bash\nexit 0\n' > "$T/bin/iron-law-guard.sh"; chmod +x "$T/bin/iron-law-guard.sh"

# The box's user config, as rules/settings.json + codegraph's global install
# leave it: the Vercel plugin on, one plugin off, and two user MCP servers.
cat > "$T/.claude/settings.json" <<'EOF'
{"enabledPlugins":{"vercel@claude-plugins-official":true,"dormant@x":false},"permissions":{"allow":["mcp__codegraph__*"]}}
EOF
cat > "$T/.claude.json" <<'EOF'
{"mcpServers":{"codegraph":{"type":"stdio","command":"codegraph","args":["serve","--mcp"]},"vercel":{"type":"http","url":"https://mcp.vercel.test"}}}
EOF

run_call() { # run_call <stage> <extra env...>
  local st="$1"; shift
  rm -f "$T/argv.txt" "$T/argv.txt.settings" "$T/argv.txt.mcp" "$T/env.txt"
  ( cd "$T/wt" || exit 1
    export ARGV_SINK="$T/argv.txt" ENV_SINK="$T/env.txt" \
           PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" LANE_GATE_DISABLE=1
    unset CLAUDE_CONFIG_DIR CLAUDE_CODE_PROMPT_CACHE_TTL SESSION_PROFILE_STAGES \
          SESSION_PROFILE_TTL_MAP SESSION_PROFILE_MCP_MAP SESSION_PROFILE_EFFORT_MAP \
          SESSION_PROFILE_PLUGINS_OFF SESSION_PROFILE_EXCLUDE_DYNAMIC SESSION_PROFILE_SETTING_SOURCES
    env "$@" bash "$DIR/bin/agent-call.sh" "$st" testproj claude-opus-5-5 60 "$T/out.txt" "hello" >/dev/null 2>&1 )
}
has()   { grep -qx -- "$1" "$T/argv.txt"; }
count() { grep -cx -- "$1" "$T/argv.txt"; }
after() { awk -v f="$1" 'p{print; exit} $0==f{p=1}' "$T/argv.txt"; }

NEWFLAGS='--strict-mcp-config --mcp-config --exclude-dynamic-system-prompt-sections --effort --setting-sources'
none_new() { local f hit=""; for f in $NEWFLAGS; do has "$f" && hit="$hit $f"; done; [ -z "$hit" ] && ok || bad "$1 passed$hit"; }

# --- A. parity: unset = byte-identical to before ------------------------------
run_call triage FAKE_TTL=1h
[ -s "$T/argv.txt" ] && ok || bad "A the claude lane was never invoked"
none_new "A unprofiled call"
[ -s "$T/env.txt" ] && bad "A unprofiled call set $(cat "$T/env.txt")" || ok
if [ -f "$T/argv.txt.settings" ] && grep -q enabledPlugins "$T/argv.txt.settings"; then
  bad "A unprofiled call overrode enabledPlugins"; else ok; fi

# --- B. triage profiled -------------------------------------------------------
run_call triage SESSION_PROFILE_STAGES=triage FAKE_TTL=5m
has --strict-mcp-config && ok || bad "B triage: no --strict-mcp-config (argv: $(tr '\n' ' ' < "$T/argv.txt"))"
[ -f "$T/argv.txt.mcp" ] && [ "$(jq -c '.mcpServers' "$T/argv.txt.mcp" 2>/dev/null)" = '{}' ] \
  && ok || bad "B triage: --mcp-config is not an empty server set: $(cat "$T/argv.txt.mcp" 2>/dev/null)"
has --exclude-dynamic-system-prompt-sections && ok || bad "B triage: dynamic sections not excluded"
grep -qx 'CLAUDE_CODE_PROMPT_CACHE_TTL=5m' "$T/env.txt" && ok || bad "B triage: TTL env not 5m ($(cat "$T/env.txt" 2>/dev/null))"
[ "$(count --model)" = 1 ] && ok || bad "B triage: --model passed $(count --model) times"
has --effort && bad "B triage: --effort passed with no effort row" || ok
has --setting-sources && bad "B triage: --setting-sources passed with no row — the fleet rules live in the user source" || ok
[ "$(jq -r '.enabledPlugins["vercel@claude-plugins-official"]' "$T/argv.txt.settings" 2>/dev/null)" = false ] \
  && ok || bad "B triage: the Vercel plugin was not forced off: $(cat "$T/argv.txt.settings" 2>/dev/null)"
jq -e '.enabledPlugins | has("dormant@x") | not' "$T/argv.txt.settings" >/dev/null 2>&1 \
  && ok || bad "B triage: a plugin that was already off was listed"
jq -e '.hooks.PreToolUse[0].hooks[0].command | endswith("iron-law-guard.sh")' "$T/argv.txt.settings" >/dev/null 2>&1 \
  && ok || bad "B triage: the iron-law guard was lost from the merged settings: $(cat "$T/argv.txt.settings" 2>/dev/null)"
[ "$(count --settings)" = 1 ] && ok || bad "B triage: --settings passed $(count --settings) times (a second one REPLACES the first)"

# --- C. execute profiled: 1h, codegraph kept verbatim, nothing else -----------
run_call execute SESSION_PROFILE_STAGES=all FAKE_TTL=1h
grep -qx 'CLAUDE_CODE_PROMPT_CACHE_TTL=1h' "$T/env.txt" && ok || bad "C execute: TTL env not 1h ($(cat "$T/env.txt" 2>/dev/null))"
[ "$(jq -c '.mcpServers | keys' "$T/argv.txt.mcp" 2>/dev/null)" = '["codegraph"]' ] \
  && ok || bad "C execute: MCP config should keep only codegraph: $(cat "$T/argv.txt.mcp" 2>/dev/null)"
[ "$(jq -c '.mcpServers.codegraph' "$T/argv.txt.mcp" 2>/dev/null)" = "$(jq -c '.mcpServers.codegraph' "$T/.claude.json")" ] \
  && ok || bad "C execute: the codegraph entry was not copied verbatim"

# --- D. a stage not in the list is untouched ----------------------------------
run_call review SESSION_PROFILE_STAGES="triage preplan" FAKE_TTL=1h
none_new "D review (not listed)"
[ -s "$T/env.txt" ] && bad "D review (not listed) set $(cat "$T/env.txt")" || ok

# --- E. a TTL the CLI would ignore is not passed, and is said -----------------
: > "$T/logs/session-profile.log"
run_call triage SESSION_PROFILE_STAGES=triage SESSION_PROFILE_TTL_MAP="triage=10m default=5m"
[ -s "$T/env.txt" ] && bad "E an invalid TTL was exported: $(cat "$T/env.txt")" || ok
grep -q "TTL '10m'" "$T/logs/session-profile.log" && ok || bad "E the invalid TTL was not logged"
has --strict-mcp-config && ok || bad "E one bad knob dropped the rest of the profile"

# --- F. effort row: exactly one --effort --------------------------------------
run_call triage SESSION_PROFILE_STAGES=triage SESSION_PROFILE_EFFORT_MAP="triage=high"
[ "$(count --effort)" = 1 ] && [ "$(after --effort)" = high ] && ok \
  || bad "F effort: expected one --effort high (argv: $(tr '\n' ' ' < "$T/argv.txt"))"
run_call triage SESSION_PROFILE_STAGES=triage SESSION_PROFILE_EFFORT_MAP="triage=turbo"
has --effort && bad "F an unknown effort level was passed" || ok

# --- G. PLUGINS_OFF=0 --------------------------------------------------------
run_call triage SESSION_PROFILE_STAGES=triage SESSION_PROFILE_PLUGINS_OFF=0
if [ -f "$T/argv.txt.settings" ] && grep -q enabledPlugins "$T/argv.txt.settings"; then
  bad "G PLUGINS_OFF=0 still overrode enabledPlugins"; else ok; fi

# --- H. the row names the TTL the envelope reports ----------------------------
: > "$T/logs/cost.csv"; rm -f "$T/logs/cost.csv"
run_call triage SESSION_PROFILE_STAGES=triage FAKE_TTL=5m
tail -1 "$T/logs/cost.csv" | grep -q 'cache_ttl=5m' && ok || bad "H 5m row lacks cache_ttl=5m: $(tail -1 "$T/logs/cost.csv")"
run_call review FAKE_TTL=1h
tail -1 "$T/logs/cost.csv" | grep -q 'cache_ttl=1h' && ok || bad "H an unprofiled 1h row lacks cache_ttl=1h (observed, not requested): $(tail -1 "$T/logs/cost.csv")"
run_call review
grep -q 'cache_ttl=' <<<"$(tail -1 "$T/logs/cost.csv")" && bad "H a row whose envelope carries no split claimed a TTL" || ok

# --- I. setting sources validated ---------------------------------------------
run_call triage SESSION_PROFILE_STAGES=triage SESSION_PROFILE_SETTING_SOURCES="project,local"
[ "$(after --setting-sources)" = "project,local" ] && ok || bad "I a valid setting-sources row was not passed"
run_call triage SESSION_PROFILE_STAGES=triage SESSION_PROFILE_SETTING_SOURCES="everything"
has --setting-sources && bad "I an invalid setting-sources value was passed" || ok

# --- J. an ACCOUNT-ROUTED call reads the ROUTED account's config dir ----------
# ACCT_EXPORTS (account-pick / accounts.d) is eval'd only inside the claude
# subshell, so a profile built from the parent's CLAUDE_CONFIG_DIR would force
# off the DEFAULT account's plugins and copy its MCP servers — while the CLI
# loads the routed account's. The routed dir must be the one read.
mkdir -p "$T/acct"
cat > "$T/acct/settings.json" <<'EOF'
{"enabledPlugins":{"acctonly@x":true}}
EOF
cat > "$T/acct/.claude.json" <<'EOF'
{"mcpServers":{"codegraph":{"type":"stdio","command":"acct-codegraph","args":["serve"]}}}
EOF
cat > "$T/bin/account-pick.sh" <<EOF
#!/bin/bash
echo name=acct-a
echo reason=test
echo "export CLAUDE_CONFIG_DIR=$T/acct"
EOF
chmod +x "$T/bin/account-pick.sh"
run_call execute SESSION_PROFILE_STAGES=all ACCOUNT_ROUTING=1
[ "$(jq -r '.enabledPlugins["acctonly@x"]' "$T/argv.txt.settings" 2>/dev/null)" = false ] \
  && ok || bad "J a plugin enabled in the ROUTED account's settings.json was not forced off: $(cat "$T/argv.txt.settings" 2>/dev/null)"
[ "$(jq -r '.mcpServers.codegraph.command' "$T/argv.txt.mcp" 2>/dev/null)" = acct-codegraph ] \
  && ok || bad "J the MCP set did not come from the routed account's .claude.json: $(cat "$T/argv.txt.mcp" 2>/dev/null)"
rm -f "$T/bin/account-pick.sh"

# --- K. a glob character in a settings row never expands ----------------------
# The maps are word-split; an unquoted split would glob `*` against the cwd.
touch "$T/wt/triage=1h"
: > "$T/logs/session-profile.log"
run_call triage SESSION_PROFILE_STAGES=triage SESSION_PROFILE_TTL_MAP="triage*" SESSION_PROFILE_MCP_MAP="triage=*"
[ -s "$T/env.txt" ] && bad "K a glob in the TTL map expanded into a TTL: $(cat "$T/env.txt")" || ok
[ "$(jq -c '.mcpServers' "$T/argv.txt.mcp" 2>/dev/null)" = '{}' ] \
  && ok || bad "K a glob in the MCP map selected servers: $(cat "$T/argv.txt.mcp" 2>/dev/null)"
grep -q 'triage=1h' "$T/logs/session-profile.log" \
  && bad "K the MCP server-name loop globbed against the cwd: $(cat "$T/logs/session-profile.log")" || ok
rm -f "$T/wt/triage=1h"

echo "agent-call-session-profile-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
