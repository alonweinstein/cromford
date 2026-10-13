#!/bin/bash
# tests/agent-call-session-sidecar.bh-6090-test.sh — BH-6090: bin/agent-call.sh
# writes $OUT.session (`<session-id><TAB><config-dir>`) after a claude attempt
# that has a session id, so a caller can read every assistant message of the
# session: the envelope's `.result`, which is what $OUT holds, is the LAST
# message only. The reader is lr_pick_review in bin/lead-review.sh.
#
#   S1  the real bin/agent-call.sh with a fake claude CLI that writes its
#       session transcript (a review, then a postscript) under the config dir:
#       $OUT is the postscript, $OUT.session names the session and the dir,
#       and lr_pick_review (lifted from bin/lead-review.sh) turns $OUT into the
#       review message. Once with the default dir ($HOME/.claude), once with
#       CLAUDE_CONFIG_DIR set.
#   S2  no session id known (COST_TRANSCRIPT_ROWS=0, and a CLI whose envelope
#       has no session_id): no $OUT.session
#   S3  a stale $OUT.session from an earlier run is gone after a run whose
#       rung is not claude
#   S4  no token value from the env reaches $OUT.session or any log
#
# DRIVEN, NOT GREPPED: bin/agent-call.sh runs for real against a scratch HARNESS
# with fake CLIs; what it wrote is read back off disk.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/agent-call-session-sidecar.bh-6090-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$T" demo-os
mkdir -p "$T/bin" "$T/bin/lib" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

TOK="sk-ant-oat01-FIXTURE-session-sidecar-token"

# The fake claude: --session-id <sid> -> the transcript at
# <config-dir>/projects/-scratch/<sid>.jsonl in the CLI's own shape (one line per
# content block), then an envelope whose .result is the LAST message only.
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
case " $* " in *" --help "*) printf -- '  --session-id <uuid>\n'; exit 0 ;; esac
sid=""; prev=""
for a in "$@"; do [ "$prev" = --session-id ] && sid="$a"; prev="$a"; done
echo "claude sid=$sid" >> "$ORDER_SINK"
post='The monitor expired after it delivered all 10 results. The review above is final.

VERDICT: BLOCK'
if [ -n "$sid" ]; then
  d="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/-scratch"; mkdir -p "$d"
  {
    jq -nc --arg t $'Findings\n- [BLOCK] a.sh:3 the guard is inverted' '{type:"assistant",isSidechain:false,message:{id:"msg_fixture_1",role:"assistant",content:[{type:"text",text:$t}]}}'
    jq -nc --arg t $'\nVERDICT: BLOCK' '{type:"assistant",isSidechain:false,message:{id:"msg_fixture_1",role:"assistant",content:[{type:"text",text:$t}]}}'
    jq -nc '{type:"assistant",isSidechain:false,message:{id:"msg_fixture_2",role:"assistant",content:[{type:"tool_use",id:"toolu_fixture",name:"Bash",input:{}}]}}'
    jq -nc --arg t "$post" '{type:"assistant",isSidechain:false,message:{id:"msg_fixture_3",role:"assistant",content:[{type:"text",text:$t}]}}'
  } > "$d/$sid.jsonl"
fi
jq -nc --arg r "$post" --arg s "$sid" '{result:$r,usage:{input_tokens:5,output_tokens:1},total_cost_usd:0.01}
  + (if $s == "" then {} else {session_id:$s} end)'
exit 0
EOF
cat > "$T/fakebin/codex" <<'EOF'
#!/bin/bash
echo "codex" >> "$ORDER_SINK"; echo "codex answered"; exit 0
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
printf '#!/bin/bash\necho "test rules"\n' > "$T/bin/sync-agent-rules.sh"
printf '#!/bin/bash\necho "1 2 3 4"\n' > "$T/bin/codex-usage.sh"
chmod +x "$T/fakebin/"* "$T/bin/"*.sh

OUT="$T/out.txt"
# run_call [ENV=...] — drives bin/agent-call.sh for real.
run_call() {
  : > "$T/order"; rm -rf "$T/.claude" "$T/cfg"
  ( export ORDER_SINK="$T/order" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           LADDER_BACKOFF_SECS=0 RUNNER_EVAL="${RUNNER_EVAL:-claude}" CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" JOBS_URL=
    env -u ACCOUNT_ROUTING -u RUNNER_EVAL_FALLBACK -u OPENROUTER_API_KEY -u FIREWORKS_API_KEY -u ANTHROPIC_API_KEY \
      -u ACCOUNT_OWN_PROJECTS -u CLAUDE_CONFIG_DIR -u COST_TRANSCRIPT_ROWS -u LADDER_RESUME_SID \
      CLAUDE_CODE_OAUTH_TOKEN="$TOK" "$@" bash "$DIR/bin/agent-call.sh" eval demo-os claude-opus-5 600 "$OUT" "hello" \
      >/dev/null 2>&1 )
  echo $?
}
sid_of() { sed -n 's/^claude sid=//p' "$T/order" | tail -1; }

# The reader, lifted from bin/lead-review.sh with the lib it calls.
. "$DIR/bin/lib/verdict-parse.sh" || exit 1
for fn in lr_verdict lr_has_findings lr_pick_review; do
  sed -n "/^$fn() {/,/^}/p" "$DIR/bin/lead-review.sh" > "$T/$fn.sh"
  if [ -s "$T/$fn.sh" ]; then ok; . "$T/$fn.sh"; else bad "$fn is not in bin/lead-review.sh"; fi
done
log() { printf '%s\n' "$*" >> "$T/reader.log"; }
POSTSCRIPT_LAST='VERDICT: BLOCK'

# ── S1: default config dir ($HOME/.claude) ──
RC=$(run_call)
[ "$RC" = 0 ] && ok || bad "S1 rc=$RC"
SID=$(sid_of)
[ -n "$SID" ] && ok || bad "S1 the CLI got no --session-id: $(cat "$T/order")"
grep -qF 'The monitor expired' "$OUT" && ! grep -qF -- '- [BLOCK]' "$OUT" && ok || bad "S1 \$OUT is not the envelope's last message: $(cat "$OUT")"
[ "$(cat "$OUT.session" 2>/dev/null)" = "$SID"$'\t'"$T/.claude" ] && ok || bad "S1 \$OUT.session='$(cat "$OUT.session" 2>/dev/null)' (want '$SID<TAB>$T/.claude')"
[ "$(wc -l < "$OUT.session" 2>/dev/null)" = 1 ] && ok || bad "S1 \$OUT.session is not one line"
if command -v lr_pick_review >/dev/null 2>&1; then
  lr_pick_review "$OUT" lr-test; prc=$?
  [ "$prc" = 0 ] && ok || bad "S1 lr_pick_review rc=$prc: $(cat "$T/reader.log" 2>/dev/null)"
  grep -qxF -- '- [BLOCK] a.sh:3 the guard is inverted' "$OUT" && ok || bad "S1 the round trip did not recover the review: $(cat "$OUT")"
  [ "$(tail -n 1 "$OUT")" = "$POSTSCRIPT_LAST" ] && [ "$(lr_verdict "$OUT")" = BLOCK ] && ok || bad "S1 the recovered review has no verdict: $(cat "$OUT")"
fi

# ── S1b: CLAUDE_CONFIG_DIR set (an account dir) ──
RC=$(run_call CLAUDE_CONFIG_DIR="$T/cfg")
SID=$(sid_of)
[ "$(cat "$OUT.session" 2>/dev/null)" = "$SID"$'\t'"$T/cfg" ] && ok || bad "S1b \$OUT.session='$(cat "$OUT.session" 2>/dev/null)' (want '$SID<TAB>$T/cfg')"
if command -v lr_pick_review >/dev/null 2>&1; then
  lr_pick_review "$OUT" lr-test && grep -qF -- '- [BLOCK] a.sh:3' "$OUT" && ok || bad "S1b the round trip failed: $(cat "$OUT")"
fi

# ── S2: no session id known -> no sidecar ──
RC=$(run_call COST_TRANSCRIPT_ROWS=0)
[ "$RC" = 0 ] && ok || bad "S2 rc=$RC"
[ -z "$(sid_of)" ] && ok || bad "S2 a session id was passed with transcript rows off"
[ -e "$OUT.session" ] && bad "S2 \$OUT.session written with no session id: $(cat "$OUT.session")" || ok

# ── S3: a stale sidecar is removed by a run whose rung is not claude ──
mkdir -p "$T/.codex"; echo '{}' > "$T/.codex/auth.json"
printf 'stale-fixture-sid\t/nowhere\n' > "$OUT.session"
RC=$(RUNNER_EVAL=codex run_call)
grep -qx codex "$T/order" && ok || bad "S3 the codex rung did not serve: $(cat "$T/order")"
[ -e "$OUT.session" ] && bad "S3 the stale \$OUT.session survived a codex answer: $(cat "$OUT.session")" || ok
rm -rf "$T/.codex"

# ── S4: no token value in the sidecar or any log ──
RC=$(run_call)
hits=$(grep -rlF "$TOK" "$T/logs" "$OUT.session" 2>/dev/null)
[ -z "$hits" ] && ok || bad "S4 the token leaked into: $hits"

echo "agent-call-session-sidecar.bh-6090: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
