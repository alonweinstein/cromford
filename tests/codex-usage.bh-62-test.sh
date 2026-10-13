#!/bin/bash
# tests/codex-usage.bh-62-test.sh — a metered codex call reads ITS OWN session.
#
# THE FAILURE (issue #62). bin/codex-usage.sh picked the NEWEST session file
# touched since the call started. Two metered calls on one box race: call A
# finishes, B's session is newer, and A's cost row carries B's tokens while B's
# spend is counted twice. openrouter and fireworks are the tier-3/3b survival
# lanes, and those lanes fail together, so concurrent calls are the normal
# shape of an outage.
#
# The fix: each lane reads the `session id:` codex prints in its own stderr
# banner and passes it as codex-usage.sh's third argument, which then reads
# only the session file carrying that id.
#
# Sections:
#   1. bin/codex-usage.sh with and without a session id
#   2. codex_session_id, extracted from bin/agent-call.sh by its markers
#   3. bin/agent-call.sh DRIVEN on the openrouter lane, plus a mutation guard
#      that proves the row goes back to the foreign count without the wiring
#
# Run from anywhere: tests/codex-usage.bh-62-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
export HOME="$T"          # keep the real ~/.codex out of this entirely
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing — skipping"; exit 0; }

# Session ids with the all-zero prefix bin/share/leakcheck.py exempts from its
# account-uuid shape: the tree is mirrored publicly, and these are provably not
# anyone's session. The banner regex and the file-name match take them as-is.
A=00000000-0000-0000-0000-00000000000a
B=00000000-0000-0000-0000-00000000000b
C=00000000-0000-0000-0000-00000000000c

# The REAL captured codex ledger shape (tests/codex-usage-test.sh section 0):
# counts nested at .payload.info.total_token_usage inside an event_msg line.
ledger() { # ledger <input> <output>
  printf '{"timestamp":"2026-09-23T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":%s,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":%s,"reasoning_output_tokens":0,"total_tokens":0}}}}\n' "$1" "$2"
}

# ── 1. bin/codex-usage.sh ────────────────────────────────────────────────────
echo "--- 1. bin/codex-usage.sh"
S="$T/.codex/sessions/2026/09/23"
mkdir -p "$S"
ledger 111 11 > "$S/rollout-2026-09-23T10-00-00-$A.jsonl"
ledger 999 99 > "$S/rollout-2026-09-23T10-00-05-$B.jsonl"
touch -d '2026-09-23 10:00:00' "$S/rollout-2026-09-23T10-00-00-$A.jsonl"
touch -d '2026-09-23 10:00:30' "$S/rollout-2026-09-23T10-00-05-$B.jsonl"
cu() { bash "$DIR/bin/codex-usage.sh" "$@" 2>/dev/null; }

G=$(cu 0 "" "$A")
[ "$G" = "111 11 0 0" ] && ok \
  || bad "1a call A must read its OWN session even when B's is newer: got '$G' (want '111 11 0 0')"
G=$(cu 0 "" "$B")
[ "$G" = "999 99 0 0" ] && ok || bad "1b call B must read its own session: got '$G'"
G=$(cu 0 "" "$C")
[ "$G" = "   " ] && ok \
  || bad "1c an id with no session file must print blank fields, never borrow another call's: got '$G'"
G=$(cu 0)
[ "$G" = "999 99 0 0" ] && ok \
  || bad "1d no id must keep today's newest-session fallback unchanged: got '$G'"
# A session whose FILE NAME does not carry the id, but whose first line is the
# session_meta record naming it, is still ours.
S2="$T/meta/.codex/sessions/x"; mkdir -p "$S2"
{ printf '{"type":"session_meta","payload":{"id":"%s","cwd":"/x"}}\n' "$A"; ledger 222 22; } > "$S2/rollout-old.jsonl"
ledger 999 99 > "$S2/rollout-newer.jsonl"
touch -d '2026-09-23 10:00:00' "$S2/rollout-old.jsonl"
touch -d '2026-09-23 10:00:30' "$S2/rollout-newer.jsonl"
G=$(CODEX_HOME="$T/meta/.codex" cu 0 "" "$A")
[ "$G" = "222 22 0 0" ] && ok \
  || bad "1e a session_meta payload.id match must identify the session: got '$G'"
# The id proves ownership, so the T0 window does not apply to it — but a
# foreign session inside the window must still never be read.
G=$(cu 9999999999 "" "$A")
[ "$G" = "111 11 0 0" ] && ok \
  || bad "1f an id-matched session is ours regardless of mtime: got '$G'"

# ── 2. codex_session_id ──────────────────────────────────────────────────────
echo "--- 2. codex_session_id"
sed -n '/^# >>> codex_session_id/,/^# <<< codex_session_id/p' "$DIR/bin/agent-call.sh" > "$T/sid.sh"
grep -q 'codex_session_id()' "$T/sid.sh" && ok \
  || bad "2 could not extract codex_session_id from bin/agent-call.sh — markers missing?"
# shellcheck source=/dev/null
. "$T/sid.sh"
sid() { local g rc; g=$(codex_session_id "$1"); rc=$?; printf '%s|%s' "$g" "$rc"; }
printf 'OpenAI Codex v0.156.1 (research preview)\n--------\nworkdir: /x\nmodel: gpt-5.6-sol\nsession id: %s\n--------\nuser\nhello\n' "$A" > "$T/err1"
G=$(sid "$T/err1"); [ "$G" = "$A|0" ] && ok || bad "2a the banner id must resolve: got '$G'"
printf 'OpenAI Codex v0.156.1\nmodel: gpt-5.6-sol\n' > "$T/err2"
G=$(sid "$T/err2"); [ "$G" = "|1" ] && ok || bad "2b no banner must print nothing and rc 1: got '$G'"
printf 'user\n  session id: %s\n' "$B" > "$T/err3"
G=$(sid "$T/err3"); [ "$G" = "|1" ] && ok || bad "2c an indented line must not match: got '$G'"
printf 'session id: not-a-uuid!\n' > "$T/err4"
G=$(sid "$T/err4"); [ "$G" = "|1" ] && ok || bad "2d a non-uuid value must not match: got '$G'"
printf 'session id: %s\n--------\nuser\nsession id: %s\n' "$A" "$B" > "$T/err5"
G=$(sid "$T/err5"); [ "$G" = "$A|0" ] && ok \
  || bad "2e the FIRST (banner) id wins over a later prompt echo: got '$G'"
G=$(sid "$T/no-such-file"); [ "$G" = "|1" ] && ok || bad "2f a missing file must print nothing and rc 1: got '$G'"

# ── 3. bin/agent-call.sh, driven ─────────────────────────────────────────────
echo "--- 3. bin/agent-call.sh (driven, openrouter lane)"
mrs_fixture "$T/h" testproj
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/flags" "$T/h/locks" "$T/fakebin"
cp "$DIR/bin/codex-usage.sh" "$T/h/bin/"
printf '#!/bin/bash\necho subscription\n' > "$T/h/bin/billing-mode.sh"; chmod +x "$T/h/bin/billing-mode.sh"
printf '{"per_token": {"anthropic/claude-fable-5.1": {"prompt": 0.00001, "completion": 0.00005, "cache_read": 2.5e-7, "cache_write": 0.0000125}}}\n' > "$T/prices.json"

# Fake codex: writes its OWN session, then a concurrent call's NEWER session,
# then prints the banner the real CLI prints on stderr.
cat > "$T/fakebin/codex" <<EOF
#!/bin/bash
OUTF=""
while [ \$# -gt 0 ]; do
  case "\$1" in --output-last-message) OUTF="\${2:-}"; shift 2 ;; *) shift ;; esac
done
D="\$HOME/.codex/sessions/2026/09/23"; mkdir -p "\$D"
printf '%s\n' '$(ledger 111 11)' > "\$D/rollout-2026-09-23T10-00-00-$A.jsonl"
sleep 1
printf '%s\n' '$(ledger 999 99)' > "\$D/rollout-2026-09-23T10-00-01-$B.jsonl"
printf 'OpenAI Codex v0.156.1 (research preview)\n--------\nmodel: gpt-5.6-sol\nsession id: $A\n--------\n' >&2
[ -n "\$OUTF" ] && echo "DECISION: BH-62 :: skip :: fake" > "\$OUTF"
echo "fake codex done"
exit 0
EOF
chmod +x "$T/fakebin/codex"
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
chmod +x "$T/fakebin/timeout"

# THE FENCE: every vendor key dropped but a fake OPENROUTER one, and the fake
# codex on PATH is what the openrouter lane resolves. No real spend.
drive() { # drive <harness-root> <script>
  rm -rf "${T:?}/.codex"; mkdir -p "$T/.codex/sessions"
  ( unset XAI_API_KEY GROK_CODE_XAI_API_KEY OPENAI_API_KEY CODEX_API_KEY \
          GEMINI_API_KEY ANTHROPIC_API_KEY FIREWORKS_API_KEY OPENROUTER_API_KEY CODEX_HOME
    export HOME="$T" HARNESS="$1" PATH="$T/fakebin:$PATH" OPENROUTER_API_KEY=fake \
           MODEL_PRICES="$T/prices.json" \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" \
           RUNNER_TRIAGE=openrouter RUNNER_TRIAGE_FALLBACK=openrouter
    bash "$2" triage testproj claude-fable-5-1 60 "$T/out.txt" "hello" >/dev/null 2>&1 )
  echo $?
}
col() { tail -1 "$1/logs/cost.csv" 2>/dev/null | awk -F, -v c="$2" '{print $c}'; }

RC=$(drive "$T/h" "$DIR/bin/agent-call.sh")
[ "$RC" = 0 ] && ok || bad "3a the driven call failed (rc=$RC): $(tail -3 "$T/h/logs/ALERTS.log" 2>/dev/null)"
[ "$(col "$T/h" 5)" = openrouter ] && ok || bad "3a the row must be an openrouter row (got '$(col "$T/h" 5)')"
[ "$(col "$T/h" 9)" = 111 ] && ok \
  || bad "3a input_toks must be THIS call's session (111), not the newer concurrent one: got '$(col "$T/h" 9)'"
[ "$(col "$T/h" 10)" = 11 ] && ok || bad "3a output_toks must be 11: got '$(col "$T/h" 10)'"

# 3b. MUTATION GUARD (D1): the same script with the session id cut out of every
# codex-usage.sh call site must fall back to the newest file and read 999. This
# proves 3a observes the wiring, not a coincidence of file order.
mrs_fixture "$T/mut" testproj
mkdir -p "$T/mut/bin/lib" "$T/mut/logs" "$T/mut/flags" "$T/mut/locks"
cp "$DIR/bin/codex-usage.sh" "$DIR/bin/grok-usage.sh" "$DIR/bin/auth-fingerprint.sh" \
   "$T/h/bin/billing-mode.sh" "$T/mut/bin/"
cp "$DIR"/bin/lib/*.sh "$T/mut/bin/lib/"
sed 's|"\$HARNESS/bin/codex-usage.sh" "\$T0" "" "\$(codex_session_id "\$OUT.err")"|"$HARNESS/bin/codex-usage.sh" "$T0"|' \
  "$DIR/bin/agent-call.sh" > "$T/mut/bin/agent-call.sh"
if cmp -s "$DIR/bin/agent-call.sh" "$T/mut/bin/agent-call.sh"; then
  bad "3b the mutation changed nothing — agent-call.sh does not pass codex_session_id to codex-usage.sh"
else
  ok
  RC=$(drive "$T/mut" "$T/mut/bin/agent-call.sh")
  [ "$RC" = 0 ] && ok || bad "3b the mutated drive failed (rc=$RC)"
  [ "$(col "$T/mut" 9)" = 999 ] && ok \
    || bad "3b without the id the row must carry the foreign 999 — 3a's green comes from the fix: got '$(col "$T/mut" 9)'"
fi

# Parity: all three codex-driven lanes (codex, openrouter, fireworks) pass it.
N=$(grep -c '"\$HARNESS/bin/codex-usage.sh" "\$T0" "" "\$(codex_session_id "\$OUT.err")"' "$DIR/bin/agent-call.sh")
[ "$N" = 3 ] && ok || bad "3c codex, openrouter and fireworks must each pass the session id: $N call site(s)"

echo "codex-usage.bh-62-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
