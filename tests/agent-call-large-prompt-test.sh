#!/bin/bash
# tests/agent-call-large-prompt-test.sh — A REVIEW-SIZED PROMPT MUST REACH THE
# LANE, OR SAY SO (BH-495).
#
# Linux caps ONE argv element at MAX_ARG_STRLEN = 32 pages = 131072 bytes. Every
# lane that hands the prompt over as `cli ... "$P"` therefore dies with
# "Argument list too long" (rc 126) before a model runs, and the ladder reads
# that as "the vendor answered and the answer failed" — a real-failure that
# descends a rung and spends the PR's strikes on our own transport.
#
# PR #502 fixed the openrouter and fireworks lanes. The CODEX PRIMARY lane (the
# execute runner on project-4/project-1, and any RUNNER_<STAGE>=codex) still passed
# argv, and so did grok and gemini. This file drives the real bin/agent-call.sh
# with fake CLIs and pins, per lane:
#   codex  — the whole prompt arrives on stdin, rc 0, no rc=126 in failovers.log
#   claude — unchanged since 2026-08-05 (a pin, not a fix)
#   grok/gemini — neither CLI is installed anywhere on this fleet's build boxes,
#                 so their stdin semantics are unverified: over the ceiling they
#                 REFUSE with PROMPT_TOO_LARGE and rc 79, nothing is truncated,
#                 and the ladder descends to a lane that takes stdin.
#   mc_rereview — the inlined diff is capped at MC_RR_DIFF_INLINE_BYTES and the
#                 prompt names the complete diff file for the rest.
# Under the ceiling every lane is byte-for-byte what it was (section 6).
#
# Run from anywhere: tests/agent-call-large-prompt-test.sh   (exit 0 = all pass)
set -uo pipefail
# tests/lib/scratch.sh is not on main yet (open PR #609) and it refuses to run
# as root beside a live /root/harness, which is exactly where the reproduction
# gate re-runs this file at the merge base. The fallback is one mktemp -d.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/scratch.sh" 2>/dev/null || {
  T=$(mktemp -d "${TMPDIR:-/tmp}/scratch.XXXXXX"); trap 'rm -rf "$T"' EXIT; }
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
# BH-1510.1: agent-call reads its ladders from model_routes; this worker-less box carries the resolver's cache of #1507's table.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$T" testproj
mkdir -p "$T/bin" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# --- the fake CLIs -----------------------------------------------------------
# codex: the ONE thing under test is how many prompt bytes arrived, whether they
# came as an argv element or on stdin through `-`.
cat > "$T/fakebin/codex" <<'EOF'
#!/bin/bash
prompt=""
while [ $# -gt 0 ]; do
  case "$1" in
    -) prompt=$(cat); shift ;;
    -m|-c|--output-last-message) shift 2 ;;
    exec|--*) shift ;;
    *) prompt="$1"; shift ;;
  esac
done
printf '%s' "${#prompt}" > "${PROMPT_BYTES_SINK:-/dev/null}"
echo "codex answered"
EOF
# claude: reports the byte count it read on STDIN as its result, so the assertion
# is on what the lane delivered rather than on what the script intended.
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
case " $* " in *" --help "*) echo "  --resume"; exit 0 ;; esac
echo claude >> "${CLAUDE_SINK:-/dev/null}"
n=$(wc -c | tr -d ' ')
printf '{"result":"%s","is_error":false}\n' "$n"
EOF
# grok / gemini: existence of the sink file IS the claim that the CLI was
# invoked. Over the ceiling agent-call must never reach them.
cat > "$T/fakebin/grok" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" > "${GROK_SINK:-/dev/null}"
echo "grok answered"
EOF
cat > "$T/fakebin/gemini" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" > "${GEMINI_SINK:-/dev/null}"
echo "gemini answered"
EOF
# execs its arguments for real, so an execve that would fail in production fails
# here too — that is what makes this driven rather than grepped.
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
cat > "$T/bin/billing-mode.sh" <<'EOF'
#!/bin/bash
echo subscription
EOF
cat > "$T/bin/beat.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$T/bin/sync-agent-rules.sh" <<'EOF'
#!/bin/bash
echo "test rules"
EOF
chmod +x "$T/fakebin/"* "$T/bin/"*

# ~200KB of prompt, over MAX_ARG_STRLEN and over the 96000-byte AGENT_ARGV_MAX.
# Passed as @file, the way bin/review-prs.sh and mc_rereview pass it — a prompt
# this size cannot be an argv element of agent-call.sh either.
yes x | head -200000 | tr -d '\n' > "$T/big.prompt"

# run_call <out-name> <prompt-arg> <extra env...> — one whole agent-call run with
# NO survival keys: the box's real OPENROUTER_API_KEY must never be able to
# rescue a dead primary and hide the red.
run_call() {
  # AGENT_CALL_LEDGER=0 (BH-1037): the big prompt is replayed across cases on the
  # same (project, stage), so the prompt ledger would answer the second call from
  # the first one's body and every lane assertion below would pass without a lane
  # running. This suite is about the lanes, not the cache.
  local out="$1" prompt="$2"; shift 2
  : > "$T/logs/ALERTS.log"; : > "$T/logs/failovers.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           OPENROUTER_API_KEY= FIREWORKS_API_KEY= ACCOUNT_ROUTING=0 \
           LADDER_BACKOFF_SECS=0 LADDER_TIER2_GROK=0 AGENT_CALL_LEDGER=0 \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" "$@"
    bash "$DIR/bin/agent-call.sh" review testproj claude-fable-5 60 "$T/$out" "$prompt" \
      >/dev/null 2>&1 )
  echo $?
}

# ============================================================================
# 1. THE CODEX PRIMARY LANE, 200KB — the defect BH-495 was filed for.
# ============================================================================
RC=$(run_call c1.txt "@$T/big.prompt" RUNNER_REVIEW=codex RUNNER_REVIEW_FALLBACK=claude \
        CODEX_API_KEY=test PROMPT_BYTES_SINK="$T/c1.bytes" CLAUDE_SINK="$T/c1.claude")
[ "$RC" -eq 0 ] && ok || bad "codex primary: a 200KB prompt must still run (exit $RC) — this is the E2BIG"
[ "$(cat "$T/c1.bytes" 2>/dev/null || echo 0)" -ge 200000 ] \
  && ok || bad "codex primary: the whole prompt must reach codex (got $(cat "$T/c1.bytes" 2>/dev/null) bytes)"
grep -qi "Argument list too long" "$T/c1.txt" "$T/c1.txt.err" 2>/dev/null \
  && bad "codex primary: the lane still E2BIGs on a review-sized prompt" || ok
grep -q 'rc=126' "$T/logs/failovers.log" \
  && bad "codex primary: the ladder recorded an rc=126 attempt: $(grep -m1 'rc=126' "$T/logs/failovers.log")" || ok
[ -e "$T/c1.claude" ] \
  && bad "codex primary: the stage descended to claude, so codex did not serve it" || ok
[ "$(cat "$T/c1.txt.runner" 2>/dev/null)" = codex ] \
  && ok || bad "codex primary: the runner marker must name codex (got $(cat "$T/c1.txt.runner" 2>/dev/null))"

# ============================================================================
# 2. THE CLAUDE LANE, 200KB — a PIN, not a fix (stdin since 2026-08-05).
# ============================================================================
RC=$(run_call c2.txt "@$T/big.prompt" RUNNER_REVIEW=claude RUNNER_REVIEW_FALLBACK=)
[ "$RC" -eq 0 ] && ok || bad "claude: a 200KB prompt must still run (exit $RC)"
[ "$(cat "$T/c2.txt" 2>/dev/null || echo 0)" -ge 200000 ] \
  && ok || bad "claude: the whole prompt must arrive on stdin (got $(cat "$T/c2.txt" 2>/dev/null) bytes)"

# ============================================================================
# 3. GROK OVER THE CEILING REFUSES, AND THE LADDER DESCENDS TO A LANE THAT CAN
#    TAKE THE PROMPT. Nothing is truncated and no doomed execve is attempted.
# ============================================================================
RC=$(run_call c3.txt "@$T/big.prompt" RUNNER_REVIEW=grok RUNNER_REVIEW_FALLBACK=claude \
        GROK_SINK="$T/c3.grok" CLAUDE_SINK="$T/c3.claude")
[ -e "$T/c3.grok" ] \
  && bad "grok: the CLI was invoked with a $(wc -c < "$T/big.prompt")-byte argv — that execve cannot succeed" || ok
# The failovers line carries the stage's routing TOKEN between the class and
# the rc since BH-642; asserted here too, so the format cannot drift silently.
grep -q 'grok: class=real-failure(prompt_too_large) token=RUNNER_ERROR rc=79' "$T/logs/failovers.log" \
  && ok || bad "grok: the refusal must be classified prompt_too_large token=RUNNER_ERROR rc=79 (got: $(grep -m1 grok "$T/logs/failovers.log"))"
[ "$RC" -eq 0 ] && ok || bad "grok: the ladder must descend to claude and serve the stage (exit $RC)"
[ "$(cat "$T/c3.txt.runner" 2>/dev/null)" = claude ] \
  && ok || bad "grok: claude must be the lane that served (got $(cat "$T/c3.txt.runner" 2>/dev/null))"
[ "$(cat "$T/c3.txt" 2>/dev/null || echo 0)" -ge 200000 ] \
  && ok || bad "grok: the fallback lane must receive the WHOLE prompt, untruncated (got $(cat "$T/c3.txt" 2>/dev/null))"

# ============================================================================
# 4. NO LANE LEFT: the refusal is the stage's own result, readable by a human.
# ============================================================================
RC=$(run_call c4.txt "@$T/big.prompt" RUNNER_REVIEW=grok RUNNER_REVIEW_FALLBACK=grok \
        GROK_SINK="$T/c4.grok")
[ "$RC" -eq 79 ] && ok || bad "grok alone: the stage must exit 79, not 126 or 0 (exit $RC)"
head -1 "$T/c4.txt" 2>/dev/null | grep -qE '^PROMPT_TOO_LARGE 20[0-9]{4} grok' \
  && ok || bad "grok alone: \$OUT must open with the marker and the byte count (got: $(head -1 "$T/c4.txt" 2>/dev/null))"
head -1 "$T/c4.txt.err" 2>/dev/null | grep -q '^PROMPT_TOO_LARGE' \
  && ok || bad "grok alone: \$OUT.err must carry the same line (got: $(head -1 "$T/c4.txt.err" 2>/dev/null))"
grep -q 'DEAD: every available lane failed' "$T/logs/ALERTS.log" \
  && ok || bad "grok alone: a dead stage must still alert"
[ -e "$T/c4.grok" ] && bad "grok alone: the CLI was invoked anyway" || ok

RC=$(run_call c4g.txt "@$T/big.prompt" RUNNER_REVIEW=gemini RUNNER_REVIEW_FALLBACK=gemini \
        GEMINI_API_KEY=test GEMINI_SINK="$T/c4.gemini")
[ "$RC" -eq 79 ] && ok || bad "gemini alone: the stage must exit 79, not 126 or 0 (exit $RC)"
head -1 "$T/c4g.txt" 2>/dev/null | grep -qE '^PROMPT_TOO_LARGE 20[0-9]{4} gemini' \
  && ok || bad "gemini alone: \$OUT must open with the marker (got: $(head -1 "$T/c4g.txt" 2>/dev/null))"
[ -e "$T/c4.gemini" ] && bad "gemini alone: the CLI was invoked anyway" || ok

# ============================================================================
# 5. THE RE-REVIEW PROMPT CAPS ITS INLINED DIFF AND NAMES THE REST.
#    A 26-file PR must not need a 140KB argv in the first place.
# ============================================================================
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/fakebin5"
# gh-rest.sh rides along with the conductor lib (BH-784): mc_pr_diff/mc_pr_view
# are REST reads now, and without the lib the fail-closed shims answer
# "unverifiable" to every one of them.
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/review-provenance.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cat > "$T/h/bin/agent-call.sh" <<'EOF'
#!/bin/bash
# agent-call.sh <stage> <project> <model> <timeout> <out> <@prompt-file>
cp "${6#@}" "$RR_PROMPT_SINK"
printf 'VERDICT: APPROVE\n' > "$5"
echo claude > "$5.runner"; echo claude-fable-5-1 > "$5.model"
exit 0
EOF
# The REST reads mc_rereview makes (BH-784): the diff comes back as the v3.diff
# media type on the pull path, the body off the pull object itself. Both answers
# are whole HTTP responses because gh-rest.sh judges the status line — restpr
# prints the header, the diff body is cat'd rather than passed on argv (a 304KB
# argv element is the very E2BIG this file is about). The v3.diff arm is matched
# BEFORE the plain pull arm: they share the path and differ only by Accept.
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin5/restpr"
cat > "$T/fakebin5/gh" <<'EOF'
#!/bin/bash
case "$*" in
  *"v3.diff"*) restpr --raw 200; cat "$RR_DIFF" ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/21"*)
    restpr OPEN headsha0000 ticket/TK-21 main "" MERGEABLE CLEAN app/cromford "" "a plain PR body" ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/h/bin/agent-call.sh" "$T/fakebin5/gh" "$T/fakebin5/restpr"
yes 'a diff line that is thirty-nine bytes' | head -8000 > "$T/big.diff"    # ~304KB
yes 'a diff line that is thirty-nine bytes' | head -1300 > "$T/small.diff"  # ~49KB
rr_run() { # rr_run <diff-file> <prompt-sink> <out-file>
  ( export HARNESS="$T/h" PATH="$T/fakebin5:$T/fakebin:$PATH" RR_DIFF="$1" RR_PROMPT_SINK="$2"
    # shellcheck source=/dev/null
    . "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
    mc_rereview example-org/demo-os 21 demo-os https://github.com/example-org/demo-os/pull/21 \
      - headsha0000 "" "$3" >/dev/null 2>&1
    echo $? > "$3.rc" )
}
DFILE="$T/h/state/merge-conductor/diffs/demo-os-21.diff"

rr_run "$T/big.diff" "$T/rr.prompt" "$T/rr.out"
[ "$(cat "$T/rr.out.rc" 2>/dev/null)" = 0 ] \
  && ok || bad "re-review (big diff): mc_rereview exited $(cat "$T/rr.out.rc" 2>/dev/null)"
grep -q APPROVE "$T/rr.out" 2>/dev/null \
  && ok || bad "re-review (big diff): no verdict landed"
RRB=$(stat -c %s "$T/rr.prompt" 2>/dev/null || echo 999999)
[ "$RRB" -lt 110000 ] \
  && ok || bad "re-review (big diff): the prompt is $RRB bytes — the inlined diff is not capped"
grep -qE 'DIFF TRUNCATED: 96000 of 3[0-9]+ bytes inlined' "$T/rr.prompt" 2>/dev/null \
  && ok || bad "re-review (big diff): the prompt must SAY it was truncated, with both numbers"
grep -qF "$DFILE" "$T/rr.prompt" 2>/dev/null \
  && ok || bad "re-review (big diff): the prompt must name the complete diff file $DFILE"

rr_run "$T/small.diff" "$T/rr2.prompt" "$T/rr2.out"
grep -q 'DIFF TRUNCATED' "$T/rr2.prompt" 2>/dev/null \
  && bad "re-review (small diff): a diff under the cap must NOT be announced as truncated" || ok
[ "$(grep -c 'a diff line that is thirty-nine bytes' "$T/rr2.prompt" 2>/dev/null || echo 0)" -eq 1300 ] \
  && ok || bad "re-review (small diff): the whole diff must be inlined (got $(grep -c 'a diff line' "$T/rr2.prompt" 2>/dev/null) of 1300 lines)"

# ============================================================================
# 6. UNDER THE CEILING NOTHING CHANGED — argv, exactly as it has always been.
# ============================================================================
RC=$(run_call s1.txt "a short prompt" RUNNER_REVIEW=codex RUNNER_REVIEW_FALLBACK=claude \
        CODEX_API_KEY=test PROMPT_BYTES_SINK="$T/s1.bytes" CLAUDE_SINK="$T/s1.claude")
[ "$RC" -eq 0 ] && ok || bad "codex short prompt: exit $RC"
# "test rules" from the rules stub + a blank line + the prompt, as one argv element.
[ "$(cat "$T/s1.bytes" 2>/dev/null || echo 0)" -eq 26 ] \
  && ok || bad "codex short prompt: argv must carry the whole 26-byte prompt (got $(cat "$T/s1.bytes" 2>/dev/null))"
[ -e "$T/s1.claude" ] && bad "codex short prompt: the stage descended to claude" || ok

RC=$(run_call s2.txt "a short prompt" RUNNER_REVIEW=grok RUNNER_REVIEW_FALLBACK=claude \
        GROK_SINK="$T/s2.grok" CLAUDE_SINK="$T/s2.claude")
[ "$RC" -eq 0 ] && ok || bad "grok short prompt: exit $RC"
grep -q -- '-p a short prompt' "$T/s2.grok" 2>/dev/null \
  && ok || bad "grok short prompt: the CLI must still be called with -p and the whole prompt (got: $(tr '\n' ' ' < "$T/s2.grok" 2>/dev/null))"

echo "agent-call-large-prompt-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
