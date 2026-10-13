#!/bin/bash
# tests/agent-call-choke-guard.bh-1037-test.sh — THE CHOKE POINT (BH-1037).
#
# THE LEDGER. Before the first runner is invoked, the assembled prompt's sha is
# looked up in a persisted row keyed (project, stage, promptsha). Inside the
# TTL, a recorded `ok`/`empty` answer is REPLAYED — the body, the runner/model
# markers, one log line, no vendor call, no cost row. The conductor re-spawns
# the same head-bound re-review on the same unchanged head, and until now every
# re-spawn bought the read again. That is money already out of the building by
# the time anything downstream can have an opinion.
#
# BH-1037'S OTHER HALF — AGENT_CALL_RUNNERS, the caller's list of lanes it will
# accept — LANDED FIRST, as BH-1019 (#1074), so this build does not implement
# it. Section 7 still pins the behaviour the ledger sits next to (and the
# consumer in case 10), against the shipped BH-1019 implementation.
#
# Everything here DRIVES bin/agent-call.sh for real against fake CLIs and
# asserts on artifacts ($T/order, $OUT, $OUT.replay, the row JSON, the logs) —
# never on the script's source text. Case 10 drives the production consumer,
# mc_rereview in bin/lib/merge-conductor-lib.sh.
#
# Run from anywhere: tests/agent-call-choke-guard.bh-1037-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
# BH-1510.1: agent-call reads its ladders from model_routes; this worker-less box carries the resolver's cache of #1507's table.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$T" testproj otherproj
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# The clock is read ONCE. Every fixture age below is derived from it, so this
# suite cannot pick its own red day (docs/TEST-DETERMINISM.md).
NOW=$(date +%s)

mkdir -p "$T/bin" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state"

# --- the fake vendor CLIs --------------------------------------------------
# Each appends its own name to $ORDER_SINK, so the ORDER of the ladder's calls
# is an artifact rather than an inference.
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
echo claude >> "$ORDER_SINK"
case "${CLAUDE_RESULT:-ok}" in
  empty) echo '{"result":"","usage":{"input_tokens":10,"output_tokens":0},"total_cost_usd":0.01}'; exit 0 ;;
  fail)  echo "usage limit" >&2; exit 1 ;;
  # THE SHAPE THAT COSTS MONEY AND IS NOT AN ANSWER: the CLI wraps a vendor
  # error in its own envelope and exits 0. `.result` is the error TEXT, so
  # every rc-based reading downstream calls this a successful review.
  envelope) echo '{"is_error":true,"api_error_status":429,"result":"session limit reached, resets 8am"}'; exit 0 ;;
  # the same envelope, but the CLI also exits non-zero, so the ladder descends
  # and a LATER rung's answer is what $OUT ends up holding.
  envelope_rc) echo '{"is_error":true,"api_error_status":429,"result":"session limit reached, resets 8am"}'; exit 1 ;;
  *)     echo '{"result":"the review text","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}'; exit 0 ;;
esac
EOF
cat > "$T/fakebin/grok" <<'EOF'
#!/bin/bash
echo grok >> "$ORDER_SINK"
case "${GROK_RESULT:-success}" in
  fail) echo "grok unavailable" >&2; exit 1 ;;
esac
echo "grok answered"
EOF
cat > "$T/fakebin/codex" <<'EOF'
#!/bin/bash
provider=codex
for arg in "$@"; do
  case "$arg" in
    *model_provider*openrouter*) provider=openrouter ;;
    *model_provider*fireworks*) provider=fireworks ;;
  esac
done
echo "$provider" >> "$ORDER_SINK"
echo "$provider answered"
EOF
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

LEDGER="$T/state/agent-call-ledger"

reset() { # a clean slate for one case: logs, order sink, cost ledger
  : > "$T/order"; : > "$T/logs/ALERTS.log"; : > "$T/logs/failovers.log"
  rm -f "$T/logs/cost.csv" "$T/logs/agent-call-ledger.log"
}

# call <out-name> <project> <stage> <prompt> [VAR=VAL ...] -> prints the rc.
# The defaults are the SAFE ones: no survival keys, no grok rung, no runner
# intent — so a box's real OPENROUTER_API_KEY can never rescue a dead primary
# and hide a red. Per-case overrides come last and win.
#
# `call` is a caller that OPTED IN (AGENT_CALL_LEDGER=1), because that is what
# the ledger now needs: the default is off, and only a caller whose prompt is
# keyed to the thing it is asking about may replay. `call_default` is the same
# drive with the variable UNSET — the fleet default every other review caller
# (run-build's lenses, review-rescue) runs under.
_call() {
  local ledger="$1" out="$2" proj="$3" stage="$4" prompt="$5"; shift 5
  ( unset AGENT_CALL_LEDGER
    [ -n "$ledger" ] && export AGENT_CALL_LEDGER="$ledger"
    export ORDER_SINK="$T/order" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           OPENROUTER_API_KEY= FIREWORKS_API_KEY= CODEX_API_KEY= ACCOUNT_ROUTING=0 \
           LADDER_TIER2_GROK=0 LADDER_BACKOFF_SECS=0 CLAUDE_RESULT=ok GROK_RESULT=success \
           AGENT_CALL_RUNNERS= RUNNER_REVIEW=claude RUNNER_REVIEW_FALLBACK= \
           RUNNER_FASTFAIL_COOLDOWN_S=0 \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" "$@"
    # RUNNER_FASTFAIL_COOLDOWN_S=0 (BH-3224): every case shares one HARNESS, and
    # case 7b's instant grok rc 1 would arm the fast-fail cooldown and skip grok
    # in case 11b. This suite is about the ledger, not the cooldown
    # (tests/runner-fastfail.bh-3224-test.sh pins that), so it runs with it off.
    # TEST-CHANGE (BH-1510.1): the argv model was claude-fable-5, which no route
    # names. The fable->opus pair case 6 counts is claude.ladder's now, and
    # claude.ladder starts at claude-fable-5-1; a model the table does not know
    # gets no in-lane failover rung (nothing is guessed). Same pair, real id.
    bash "$DIR/bin/agent-call.sh" "$stage" "$proj" claude-fable-5-1 60 "$T/$out" "$prompt" \
      >/dev/null 2>&1 )
  echo $?
}
call()         { _call 1  "$@"; }
call_default() { _call '' "$@"; }

row_for() { # row_for <out-name> <project> <stage> -> the ledger row path
  printf '%s/%s/%s/%s.json' "$LEDGER" "$2" "$3" "$(cat "$T/$1.promptsha" 2>/dev/null)"
}
# `grep -c` prints 0 AND exits 1 when it matches nothing, so a `|| echo 0`
# fallback yields the two-line string "0\n0" and every numeric test after it
# dies on "integer expression expected". The count is the stdout; the rc is
# not part of it.
countl() { # countl <pattern> <file>
  local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); printf '%s' "${n:-0}"
}
vendor_calls() { countl '^claude$' "$T/order"; }
cost_rows()    { countl ',testproj,' "$T/logs/cost.csv"; }

# ===========================================================================
# 1. THE HIT: two calls, one purchase.
# ===========================================================================
reset
RC=$(call a.txt testproj review "the same review prompt")
[ "$RC" -eq 0 ] && ok || bad "case 1: the first call must succeed (rc=$RC)"
cp "$T/a.txt" "$T/a1.body" 2>/dev/null
rm -f "$T/a.txt" "$T/a.txt.runner" "$T/a.txt.model" "$T/a.txt.replay"
RC=$(call a.txt testproj review "the same review prompt")
[ "$RC" -eq 0 ] && ok || bad "case 1: the replay must exit with the row's rc (rc=$RC)"
[ "$(vendor_calls)" -eq 1 ] \
  && ok || bad "case 1: the same prompt inside the TTL must buy ONE vendor call, got $(vendor_calls) ($(paste -sd, "$T/order"))"
cmp -s "$T/a1.body" "$T/a.txt" \
  && ok || bad "case 1: the replayed body must be byte-identical to the one that was bought"
[ "$(cut -d' ' -f1 "$T/a.txt.replay" 2>/dev/null)" = ok ] \
  && ok || bad "case 1: \$OUT.replay must name the outcome it replayed (got '$(cat "$T/a.txt.replay" 2>/dev/null)')"
[ "$(cat "$T/a.txt.runner" 2>/dev/null)" = claude ] \
  && ok || bad "case 1: the replay must re-write the runner marker (got '$(cat "$T/a.txt.runner" 2>/dev/null)')"
[ "$(cat "$T/a.txt.model" 2>/dev/null)" = claude-fable-5-1 ] \
  && ok || bad "case 1: the replay must re-write the model marker (got '$(cat "$T/a.txt.model" 2>/dev/null)')"
[ "$(countl 'LEDGER HIT' "$T/logs/agent-call-ledger.log")" -eq 1 ] \
  && ok || bad "case 1: exactly ONE log line for the replay"
# THE ACCOUNT SIDECAR DESCRIBES A RUN THAT DID NOT HAPPEN (BH-1090 review).
# $OUT.account names the claude account that PAID for an attempt; a replay
# invoked none, so the file the live call above left behind must not survive
# into it. A caller that reads it beside a replayed body (the conductor's
# per-account lane-down marker does) would mark an account this run never
# touched.
[ ! -e "$T/a.txt.account" ] \
  && ok || bad "case 1: a replay pays no account, so \$OUT.account must not survive the live attempt (got '$(cat "$T/a.txt.account" 2>/dev/null)')"
[ "$(cost_rows)" -eq 1 ] \
  && ok || bad "case 1: a replay bills nothing, so cost.csv must hold ONE row, got $(cost_rows)"
[ "$(jq -r '.outcome' "$(row_for a.txt testproj review)" 2>/dev/null)" = ok ] \
  && ok || bad "case 1: the row must record outcome=ok"
[ "$(jq -r '.promptsha' "$(row_for a.txt testproj review)" 2>/dev/null)" = "$(cat "$T/a.txt.promptsha")" ] \
  && ok || bad "case 1: the row must carry the promptsha it is keyed on"

# ===========================================================================
# 2. A DIFFERENT PROMPT IS A DIFFERENT KEY.
# ===========================================================================
reset
call b.txt testproj review "prompt two, first wording" >/dev/null
call b.txt testproj review "prompt two, SECOND wording" >/dev/null
[ "$(vendor_calls)" -eq 2 ] \
  && ok || bad "case 2: a different prompt must buy its own call, got $(vendor_calls)"

# ===========================================================================
# 3. THE KEY IS (project, stage, promptsha) — all three.
# ===========================================================================
reset
call c.txt testproj  review "shared wording across projects" >/dev/null
call c.txt otherproj review "shared wording across projects" >/dev/null
[ "$(vendor_calls)" -eq 2 ] \
  && ok || bad "case 3: another project must not read this project's row, got $(vendor_calls)"

# 3b. A stage outside AGENT_CALL_LEDGER_STAGES neither reads nor writes.
#     An `eval` replay would return a transcript while performing none of the
#     work; only a review's deliverable IS its text.
reset
call d.txt testproj eval "an eval stage prompt" >/dev/null
call d.txt testproj eval "an eval stage prompt" >/dev/null
[ "$(vendor_calls)" -eq 2 ] \
  && ok || bad "case 3b: the eval stage is not in the ledger's stage list — it must buy twice, got $(vendor_calls)"
[ ! -d "$LEDGER/testproj/eval" ] \
  && ok || bad "case 3b: a stage outside the list must write NO row ($LEDGER/testproj/eval exists)"

# ===========================================================================
# 4. THE TTL. An aged row is not an answer.
# ===========================================================================
reset
call e.txt testproj review "a prompt that will age out" >/dev/null
ROW=$(row_for e.txt testproj review)
jq --argjson t "$((NOW - 3600))" '.ts=$t' "$ROW" > "$ROW.aged" && mv -f "$ROW.aged" "$ROW"
call e.txt testproj review "a prompt that will age out" >/dev/null
[ "$(vendor_calls)" -eq 2 ] \
  && ok || bad "case 4: a row older than the TTL must be re-bought, got $(vendor_calls)"

# 4b. A non-numeric ts is garbage, not an eternally fresh row.
reset
call e2.txt testproj review "a prompt whose row gets corrupted" >/dev/null
ROW=$(row_for e2.txt testproj review)
jq '.ts="not-a-number"' "$ROW" > "$ROW.bad" && mv -f "$ROW.bad" "$ROW"
call e2.txt testproj review "a prompt whose row gets corrupted" >/dev/null
[ "$(vendor_calls)" -eq 2 ] \
  && ok || bad "case 4b: a row with a non-numeric ts must MISS, got $(vendor_calls)"

# ===========================================================================
# 5. AN EMPTY COMPLETION IS `empty`, AND IS NEVER REPLAYED AS `ok`.
# ===========================================================================
reset
RC=$(call f.txt testproj review "a prompt the model answers blank" CLAUDE_RESULT=empty)
[ "$RC" -eq 0 ] && ok || bad "case 5: a blank completion still exits 0 (rc=$RC)"
rm -f "$T/f.txt.replay"
call f.txt testproj review "a prompt the model answers blank" CLAUDE_RESULT=empty >/dev/null
[ "$(vendor_calls)" -eq 1 ] \
  && ok || bad "case 5: an empty answer is billed and terminal inside the TTL, got $(vendor_calls) calls"
[ "$(jq -r '.outcome' "$(row_for f.txt testproj review)" 2>/dev/null)" = empty ] \
  && ok || bad "case 5: the row must record outcome=empty, got '$(jq -r '.outcome' "$(row_for f.txt testproj review)" 2>/dev/null)'"
[ "$(cut -d' ' -f1 "$T/f.txt.replay" 2>/dev/null)" = empty ] \
  && ok || bad "case 5: the replay must be LABELLED empty, never ok (got '$(cat "$T/f.txt.replay" 2>/dev/null)')"
grep -q 'LEDGER HIT empty' "$T/logs/agent-call-ledger.log" \
  && ok || bad "case 5: the log line must say which outcome it replayed"

# ===========================================================================
# 6. A FAILURE IS RECORDED AND NEVER REPLAYED.
# ===========================================================================
reset
RC=$(call g.txt testproj review "a prompt every lane fails on" CLAUDE_RESULT=fail)
[ "$RC" -ne 0 ] && ok || bad "case 6: a dead ladder must not exit 0"
[ "$(jq -r '.outcome' "$(row_for g.txt testproj review)" 2>/dev/null)" = failed ] \
  && ok || bad "case 6: the row must record outcome=failed, got '$(jq -r '.outcome' "$(row_for g.txt testproj review)" 2>/dev/null)'"
RC=$(call g.txt testproj review "a prompt every lane fails on" CLAUDE_RESULT=fail)
[ "$RC" -ne 0 ] && ok || bad "case 6: the second call must fail too (rc=$RC)"
[ "$(vendor_calls)" -eq 4 ] \
  && ok || bad "case 6: a failed row is never replayed — both calls run the fable+opus pair, got $(vendor_calls)"
[ ! -e "$(row_for g.txt testproj review | sed 's/\.json$/.out/')" ] \
  && ok || bad "case 6: a failed row must carry no cached body"

# ===========================================================================
# 7. CLAUDE-ONLY INTENT (BH-1019, already in main): no descent nobody will
#    accept, and the ledger records the dead call as `failed` rather than as
#    an answer. The rc/marker shape of the refusal is BH-1019's own contract
#    and is pinned by tests/agent-call-provider-order-test.sh; what this file
#    owns is the LEDGER's reading of it.
# ===========================================================================
reset
RC=$(call h.txt testproj review "a claude-only review prompt" \
       CLAUDE_RESULT=fail GROK_RESULT=fail LADDER_TIER2_GROK=1 \
       RUNNER_REVIEW_FALLBACK=codex CODEX_API_KEY=test \
       OPENROUTER_API_KEY=test FIREWORKS_API_KEY=test AGENT_CALL_RUNNERS=claude)
[ "$RC" -ne 0 ] && ok || bad "case 7: claude-only with a dead primary must fail, got $RC"
[ "$(wc -l < "$T/order")" -eq "$(vendor_calls)" ] \
  && ok || bad "case 7: NOTHING below claude may be called, got $(paste -sd, "$T/order")"
grep -q 'usage limit' "$T/h.txt" \
  && ok || bad "case 7: the lane's own failure text must reach \$OUT (got '$(head -1 "$T/h.txt")')"
[ "$(jq -r '.outcome' "$(row_for h.txt testproj review)" 2>/dev/null)" = failed ] \
  && ok || bad "case 7: a dead lane is recorded failed, so it is never replayed as an answer"
[ ! -e "$(row_for h.txt testproj review | sed 's/\.json$/.out/')" ] \
  && ok || bad "case 7: a failed row keeps NO body — there is nothing to replay"

# 7b. THE NEGATIVE: with the knob unset the ladder is exactly what it was.
reset
RC=$(call i.txt testproj review "the same shape of prompt, no intent" \
       CLAUDE_RESULT=fail GROK_RESULT=fail LADDER_TIER2_GROK=1 \
       RUNNER_REVIEW_FALLBACK=codex CODEX_API_KEY=test \
       OPENROUTER_API_KEY=test FIREWORKS_API_KEY=test)
[ "$RC" -eq 0 ] && ok || bad "case 7b: without the knob the configured fallback still answers (rc=$RC)"
grep -q '^grok$' "$T/order" \
  && ok || bad "case 7b: the grok rung must still be reached (got $(paste -sd, "$T/order"))"
grep -q '^codex$' "$T/order" \
  && ok || bad "case 7b: the configured fallback must still be reached (got $(paste -sd, "$T/order"))"

# 7c. The PRIMARY itself refused: nothing is bought at all.
reset
RC=$(call j.txt testproj review "a prompt whose primary is not allowed" AGENT_CALL_RUNNERS=codex)
[ "$RC" -eq 2 ] && ok || bad "case 7c: a disallowed primary is rc 2, got $RC"
[ ! -s "$T/order" ] \
  && ok || bad "case 7c: a disallowed primary calls NOTHING, got $(paste -sd, "$T/order")"
head -1 "$T/j.txt" | grep -q '^AGENT_CALL_REFUSED runners-restricted codex' \
  && ok || bad "case 7c: \$OUT must carry the refusal marker (got '$(head -1 "$T/j.txt")')"

# ===========================================================================
# 8. THE KILL SWITCHES restore today's behaviour exactly.
# ===========================================================================
reset
call k.txt testproj review "a prompt with the ledger off" AGENT_CALL_LEDGER=0 >/dev/null
call k.txt testproj review "a prompt with the ledger off" AGENT_CALL_LEDGER=0 >/dev/null
[ "$(vendor_calls)" -eq 2 ] \
  && ok || bad "case 8: AGENT_CALL_LEDGER=0 must read nothing, got $(vendor_calls) calls"
[ ! -e "$LEDGER/testproj/review/$(cat "$T/k.txt.promptsha")".json ] \
  && ok || bad "case 8: AGENT_CALL_LEDGER=0 must write nothing either"

reset
touch "$T/flags/agent-call-ledger-off"
call l.txt testproj review "a prompt with the flag file set" >/dev/null
call l.txt testproj review "a prompt with the flag file set" >/dev/null
rm -f "$T/flags/agent-call-ledger-off"
[ "$(vendor_calls)" -eq 2 ] \
  && ok || bad "case 8: flags/agent-call-ledger-off must disable the read, got $(vendor_calls) calls"
[ ! -e "$LEDGER/testproj/review/$(cat "$T/l.txt.promptsha")".json ] \
  && ok || bad "case 8: flags/agent-call-ledger-off must disable the write too"

# ===========================================================================
# 9. A ROW WHOSE BODY IS GONE IS A MISS. Fail open toward one more purchase,
#    never toward a phantom answer.
# ===========================================================================
reset
call m.txt testproj review "a prompt whose body gets pruned" >/dev/null
rm -f "$(row_for m.txt testproj review | sed 's/\.json$/.out/')"
call m.txt testproj review "a prompt whose body gets pruned" >/dev/null
[ "$(vendor_calls)" -eq 2 ] \
  && ok || bad "case 9: a row with no body must MISS, got $(vendor_calls)"

# ===========================================================================
# 10. THE PRODUCTION CONSUMER: the conductor's head-bound re-review.
#     mc_review_lane_failure REJECTS a non-Claude read, so the re-review is
#     exactly the caller that must not buy one (D27: the real call site).
# ===========================================================================
H="$T/h"
mkdir -p "$H/bin/lib/mc" "$H/logs" "$H/state" "$H/flags" "$H/locks"
cp "$DIR/bin/lib/review-provenance.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
# BH-680: the lib is a shim over bin/lib/mc/*.sh, so a fixture that sources it
# copies the modules too or mc_init dies on the first missing one.
cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
cat > "$H/bin/agent-call.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "${AGENT_CALL_RUNNERS:-unset}" > "$RUNNERS_SINK"
printf '%s\n' "${AGENT_CALL_LEDGER:-unset}" > "$LEDGER_SINK"
OUT="$5"
printf 'VERDICT: APPROVE\n' > "$OUT"
printf 'claude\n' > "$OUT.runner"
printf 'claude-fable-5-1\n' > "$OUT.model"
# STUB_REPLAY=1 stands in for a ledger HIT: agent-call.sh writes $OUT.replay
# and calls no vendor, so nothing on this box answered.
[ -n "${STUB_REPLAY:-}" ] && printf 'ok /some/row.json\n' > "$OUT.replay"
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"
# THE RE-REVIEW'S OWN READS ARE REST (BH-784). mc_pr_diff and mc_pr_view go
# through bin/lib/gh-rest.sh, which judges the HTTP STATUS LINE and not gh's
# exit code, so the stub answers with FULL HTTP responses from restpr
# (tests/lib/rest-emit.sh). Without this the diff read fails, mc_rereview
# returns rc 2 from its lane-failure arm, and case 10 would be asserting on a
# consumer that never reached bin/agent-call.sh at all — green on nothing.
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
# The diff and the PR object share the pulls/1 path and differ only by the
# v3.diff media type, so the diff arm is matched FIRST.
case "$*" in
  *"v3.diff"*) restpr --diff '--- a/x.ts
+++ b/x.ts
+const a = 1;
' ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/1"*)
    restpr OPEN deadbeef ticket/x main "" MERGEABLE CLEAN operator "" 'a PR body' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
rm -f "$T/runners.sink" "$T/ledger.sink"
rr() { # rr [VAR=VAL ...] -> the verdict mc_rereview printed
  ( export MC_H="$H" HARNESS="$H" PATH="$T/fakebin:$PATH" \
           RUNNERS_SINK="$T/runners.sink" LEDGER_SINK="$T/ledger.sink" "$@"
    # shellcheck source=/dev/null
    . "$H/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1; mc_init >/dev/null 2>&1
    mc_rereview example-org/demo-os 1 demo-os https://github.com/example-org/demo-os/pull/1 \
      - deadbeef "" "$T/rr.out" 2>/dev/null )
}
V=$(rr)
[ "$V" = APPROVE ] \
  && ok || bad "case 10: the stubbed re-review must still come back APPROVE (got '$V') — the fixture is wired wrong otherwise"
[ "$(cat "$T/runners.sink" 2>/dev/null)" = claude ] \
  && ok || bad "case 10: mc_rereview must ask for a claude-only ladder (got '$(cat "$T/runners.sink" 2>/dev/null)')"
# 10b. THE OPT-IN IS THE CALLER'S, and mc_rereview is the caller that may hold
#      it: its prompt names the head, inlines the diff of that head and reads
#      its deliverable back out of $OUT. No other review caller can say that.
[ "$(cat "$T/ledger.sink" 2>/dev/null)" = 1 ] \
  && ok || bad "case 10b: mc_rereview must opt IN to the ledger (AGENT_CALL_LEDGER, got '$(cat "$T/ledger.sink" 2>/dev/null)')"

# 10c. A REPLAY IS NOT "A CLAUDE MODEL ANSWERED ON THIS BOX". mc_lane_up clears
#      the conductor's lane-down marker, and clearing it re-arms every parked
#      head-bound re-review. A cached body proves nothing about the account.
MARKER="$H/state/merge-conductor/lane-down"
mkdir -p "$(dirname "$MARKER")"; printf 'the claude review lane errored (HTTP 429)\n' > "$MARKER"
V=$(rr STUB_REPLAY=1)
[ "$V" = APPROVE ] \
  && ok || bad "case 10c: a replayed hit still carries its verdict (got '$V')"
[ -f "$MARKER" ] \
  && ok || bad "case 10c: a REPLAY must not clear the lane-down marker — nothing answered on this box"
# and the live answer still does clear it, or the marker would never lift
V=$(rr)
[ ! -f "$MARKER" ] \
  && ok || bad "case 10c: a LIVE claude answer must still clear the lane-down marker"

# ===========================================================================
# 11. AN rc-0 ERROR ENVELOPE IS A LANE FAILURE, NOT AN ANSWER (round-1 #2).
#     The claude CLI wraps a 429 in {"is_error":true,"api_error_status":429,
#     "result":"<the vendor's words>"} and exits 0, so $OUT holds the error
#     TEXT and rc says success. Recorded `ok`, it would be replayed for the
#     whole TTL with $OUT.json deleted — and $OUT.json is the ONE file
#     mc_review_lane_failure reads to tell a dead lane from a real review.
#     Every replay would then parse as "a real review with no verdict": a
#     strike, a park, and blocked-resolver closing a finished PR (project-5
#     #1621 with a cache in front of it).
# ===========================================================================
reset
RC=$(call n.txt testproj review "a prompt the lane 429s on" CLAUDE_RESULT=envelope)
grep -q 'session limit reached' "$T/n.txt" \
  && ok || bad "case 11: the fixture must reproduce the shape — the error text lands in \$OUT as if it were a review (got '$(head -1 "$T/n.txt")', rc=$RC)"
[ "$(jq -r '.outcome' "$(row_for n.txt testproj review)" 2>/dev/null)" = failed ] \
  && ok || bad "case 11: an rc-0 error envelope must be recorded failed, got '$(jq -r '.outcome' "$(row_for n.txt testproj review)" 2>/dev/null)'"
[ ! -e "$(row_for n.txt testproj review | sed 's/\.json$/.out/')" ] \
  && ok || bad "case 11: an error envelope keeps NO body — there is nothing faithful to replay"
call n.txt testproj review "a prompt the lane 429s on" CLAUDE_RESULT=envelope >/dev/null
[ "$(vendor_calls)" -eq 2 ] \
  && ok || bad "case 11: the next call must ask the lane again, not replay the 429, got $(vendor_calls)"
[ ! -e "$T/n.txt.replay" ] \
  && ok || bad "case 11: nothing may be replayed from an error envelope"

# 11b. THE NEGATIVE, and it is the reason the runner marker gates the read:
#      $OUT.json is written by the claude branch and by nothing else, so a
#      429 envelope claude left behind must NOT condemn the answer a later
#      rung actually gave. Same danger the consumer's own envelope check was
#      written for (bin/lib/mc/rebase.sh, project-5 #1621).
reset
RC=$(call n2.txt testproj review "a prompt claude 429s and grok answers" \
       CLAUDE_RESULT=envelope_rc LADDER_TIER2_GROK=1)
[ "$RC" -eq 0 ] \
  && ok || bad "case 11b: the fixture must end on a lane that answered (rc=$RC, order=$(paste -sd, "$T/order"))"
[ "$(head -1 "$T/n2.txt.runner" 2>/dev/null)" = grok ] \
  && ok || bad "case 11b: the fixture must descend past claude (runner='$(head -1 "$T/n2.txt.runner" 2>/dev/null)', order=$(paste -sd, "$T/order"))"
jq -e '.is_error == true' "$T/n2.txt.json" >/dev/null 2>&1 \
  && ok || bad "case 11b: the fixture must leave claude's envelope beside grok's answer — otherwise it pins nothing"
[ "$(jq -r '.outcome' "$(row_for n2.txt testproj review)" 2>/dev/null)" = ok ] \
  && ok || bad "case 11b: a grok answer IS an answer — the stale claude envelope is not evidence about it (got '$(jq -r '.outcome' "$(row_for n2.txt testproj review)" 2>/dev/null)')"

# ===========================================================================
# 12. THE LEDGER IS OPT-IN PER CALLER, NOT BOX-WIDE (round-1 Important-2).
#     `review` is not only mc_rereview: bin/run-build.sh's review lenses and
#     bin/review-rescue.sh run on the same stage with prompts that carry NO
#     head sha, and whose deliverable is a FILE the agentic session writes
#     ($BUILD/review.md), not the transcript. A resume inside the TTL would
#     replay the pre-fix verdict onto a fixed head and never rewrite that file.
# ===========================================================================
reset
call_default o.txt testproj review "a review prompt from a caller that never opted in" >/dev/null
call_default o.txt testproj review "a review prompt from a caller that never opted in" >/dev/null
[ "$(vendor_calls)" -eq 2 ] \
  && ok || bad "case 12: with AGENT_CALL_LEDGER unset nothing is replayed, got $(vendor_calls)"
[ ! -e "$LEDGER/testproj/review/$(cat "$T/o.txt.promptsha")".json ] \
  && ok || bad "case 12: a caller that did not opt in must leave NO row behind"

# ===========================================================================
# 13. A HIT THE CALLER WOULD NOT ACCEPT IS A MISS (round-1 Important-3).
#     AGENT_CALL_RUNNERS is the caller saying which lanes it will take. A row
#     bought while the ladder was wide open is not an answer to a claude-only
#     ask — mc_review_lane_failure rejects it on provenance, rc 2, no
#     progress, and the ledger would hand back the same rejected read until
#     the TTL lapsed.
# ===========================================================================
reset
call p.txt testproj review "a prompt whose row was served by another lane" >/dev/null
ROW=$(row_for p.txt testproj review)
jq '.runner="grok"' "$ROW" > "$ROW.re" && mv -f "$ROW.re" "$ROW"
call p.txt testproj review "a prompt whose row was served by another lane" AGENT_CALL_RUNNERS=claude >/dev/null
[ "$(vendor_calls)" -eq 2 ] \
  && ok || bad "case 13: a row served by a runner the caller disallows must MISS, got $(vendor_calls)"

# 13b. THE NEGATIVE: with no intent declared, the same row still replays.
reset
call q.txt testproj review "the same shape of row, no intent declared" >/dev/null
ROW=$(row_for q.txt testproj review)
jq '.runner="grok"' "$ROW" > "$ROW.re" && mv -f "$ROW.re" "$ROW"
call q.txt testproj review "the same shape of row, no intent declared" >/dev/null
[ "$(vendor_calls)" -eq 1 ] \
  && ok || bad "case 13b: without AGENT_CALL_RUNNERS every runner is acceptable — the row must still replay, got $(vendor_calls)"

echo "agent-call-choke-guard.bh-1037-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
