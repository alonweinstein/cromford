#!/bin/bash
# tests/claude-cost-followups.bh-2603-test.sh — the three follow-ups the review
# of #2597 (BH-2534) left on bin/claude-cost.sh's callers (BH-2603):
#
#   1. every claude-cost call site names its work (AGENT_CALL_FP) and its guard
#      family (AGENT_CALL_GUARD_STAGE), and K3 enforces those families by
#      default: orchestrator, box-chat, greenfield. The orchestrator's fresh
#      turn has its prompt on stdin, so without an fp it was never claimed.
#   2. box-chat and greenfield are REAL registry lanes with the three LLM_*
#      knobs, so harness-ctl and the Settings page can gate them. Before, their
#      calls resolved to a synthetic stage-<stage> lane nothing could set.
#   3. a refused orchestrator turn leaves ONE refused row, not one per model.
#   4. product-cmd's chat calls keep the lane they had (stage-chat): switching
#      the box-chat pane off must not stop proposal chats.
#
# Every case drives the REAL scripts: bin/box-chat.sh end to end, and the
# orchestrate.sh / greenfield.sh / product-cmd.sh blocks lifted verbatim, each
# through the REAL bin/claude-cost.sh (or bin/agent-call.sh) and the REAL gate
# libraries. Only the vendor CLI, the jobs worker and beat.sh are fakes.
#
# Run from anywhere: tests/claude-cost-followups.bh-2603-test.sh  (exit 0 = pass)
# As root next to a live harness: HARNESS_TEST_SANDBOX=1 bash tests/…
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/rendered.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
REAL_REG=$(rendered_registry)
PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); }
bad()   { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()    { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
has()   { case "$2" in *"$3"*) ok ;; *) bad "$1: [$2] does not contain [$3]" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: [$2] must NOT contain [$3]" ;; *) ok ;; esac; }

unset AGENT_CALL_LANE AGENT_CALL_FP AGENT_CALL_GUARD_STAGE AGENT_CALL_TICKET AGENT_CALL_GUARD_FORCE \
      CALL_GUARD CALL_GUARD_STAGES CALL_GUARD_MAX_MAP LLM_LANE_ENABLED LLM_RUNNER_ALLOWED \
      LLM_USD_CAP_DAY LLM_GATE_DISABLE LANE_GATE_DISABLE JOBS_URL COST_STAGE COST_PROJECT \
      HARNESS_TICKET JOB_ID IS_SANDBOX RUNNER_CHAT_FALLBACK RUNNER_TRIAGE_FALLBACK BOX_CHAT_MODEL

# The sources this suite drives, by rooted path.
BOXCHAT="$DIR/bin/box-chat.sh"
GREENFIELD="$DIR/bin/greenfield.sh"
PRODUCTCMD="$DIR/bin/product-cmd.sh"
ORCH="$DIR/bin/orchestrate.sh"
LANE_BOXCHAT="$DIR/catalog/lanes.d/box-chat.json"
LANE_GREENFIELD="$DIR/catalog/lanes.d/greenfield.json"

mkdir -p "$T/fakebin" "$T/home"

# A fake claude: logs `<model> cont=<0|1>` per run, can fail one model, can say
# "no conversation" on a -c run, echoes stdin when asked, else answers.
cat > "$T/fakebin/claude" <<'FAKE'
#!/bin/bash
touch "$CLAUDE_RAN"
m=""; prev=""; cont=0
for a in "$@"; do
  [ "$prev" = --model ] && m="$a"
  [ "$a" = -c ] && cont=1
  prev="$a"
done
echo "$m cont=$cont" >> "$CLAUDE_LOG"
[ "${FAKE_ECHO_STDIN:-0}" = 1 ] && { printf 'STDIN:'; cat; echo; }
if [ "$cont" = 1 ] && [ "${FAKE_NOCONV:-0}" = 1 ]; then echo "No conversation found to continue"; exit 1; fi
if [ -n "${FAKE_FAIL_MODEL:-}" ] && [ "$m" = "$FAKE_FAIL_MODEL" ]; then echo "${FAKE_FAIL_TEXT:-failed}"; exit "${FAKE_FAIL_RC:-1}"; fi
echo ANSWER
exit 0
FAKE
chmod +x "$T/fakebin/claude"

# The worker, at the seam both gate libs reach it through. Every claim is
# recorded as `<project> <stage> <fp> <id> <max> <win> <runner> <force>`.
cat > "$T/fake-jobs-client.sh" <<'JC'
_jobs_req() { echo "$*" >> "$FAKE_LOG/req.log"; return 1; }
call_guard_claim() {
  printf '%s\n' "$*" >> "$FAKE_LOG/claim.log"
  printf '%s' "${FAKE_CLAIM:-{\"allowed\":true,\"count\":1}}"
  return 0
}
call_guard_settle() { printf '%s\n' "$*" >> "$FAKE_LOG/settle.log"; return 0; }
JC

# scen — a fresh harness tree holding the REAL wrapper, the REAL gate libs and
# the REAL box-chat.sh, with fakes for beat.sh and agent-call.sh.
scen() {
  rm -rf "$T/h" "$T/log" "$T/orc"
  mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/log" "$T/orc"
  cp "$DIR/bin/claude-cost.sh" "$DIR/bin/transcript-cost.sh" "$BOXCHAT" "$T/h/bin/"
  cp "$DIR/bin/lib/cost-row.sh" "$DIR/bin/lib/llm-gate.sh" "$DIR/bin/lib/lane-gate.sh" \
     "$DIR/bin/lib/call-guard.sh" "$DIR/bin/lib/lane-model.sh" "$DIR/bin/lib/env-path.sh" "$T/h/bin/lib/"
  cp "$T/fake-jobs-client.sh" "$T/h/bin/jobs-client.sh"
  printf '#!/bin/bash\necho subscription\n' > "$T/h/bin/billing-mode.sh"
  printf 'auth_fp_for_runner() { echo fp-test; }\nauth_account_for_fp() { echo acct-test; }\n' \
    > "$T/h/bin/auth-fingerprint.sh"
  printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "$FAKE_LOG/beats.log"\n' > "$T/h/bin/beat.sh"
  # agent-call.sh: records its argv and the per-call env, answers.
  cat > "$T/h/bin/agent-call.sh" <<'AC'
#!/bin/bash
printf '%s|lane=%s|fp=%s|gs=%s\n' "$*" "${AGENT_CALL_LANE-}" "${AGENT_CALL_FP-}" "${AGENT_CALL_GUARD_STAGE-}" >> "$FAKE_LOG/agent-call.log"
printf 'SURVIVED\n' > "$5"
exit 0
AC
  chmod +x "$T/h/bin/"*.sh
  rm -f "$T/claude.ran"
  : > "$T/log/claim.log"; : > "$T/log/settle.log"; : > "$T/log/req.log"; : > "$T/log/beats.log"
  : > "$T/log/claude.log"; : > "$T/log/agent-call.log"
}
setting() {
  local f="$T/h/state/settings-cache.json"
  [ -s "$f" ] || printf '{"fetched_at":%s,"values":{},"seeded":{}}' "$(date -u +%s)" > "$f"
  jq --arg k "$1" --arg v "$2" '.values[$k]=$v' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
rows()     { tail -n +2 "$T/h/logs/cost.csv" 2>/dev/null; }
refused()  { rows | awk -F, '$18=="refused"'; }
nrefused() { refused | grep -c .; }
ran()      { [ -e "$T/claude.ran" ] && echo yes || echo no; }
claims()   { grep -c . "$T/log/claim.log"; }
claim_col(){ awk -v c="$1" '{print $c}' "$T/log/claim.log" | sort -u | tr '\n' ' ' | sed 's/ $//'; }
BENV=(PATH="$T/fakebin:$PATH" HOME="$T/home" HARNESS="$T/h" LANE_REGISTRY="$REAL_REG"
      CLAUDE_RAN="$T/claude.ran" CLAUDE_LOG="$T/log/claude.log" FAKE_LOG="$T/log")

# boxchat <cid> [KEY=VAL ...] — run the REAL bin/box-chat.sh the way the ssh hop does.
boxchat() {
  local cid="$1"; shift
  local b64; b64=$(jq -nc --arg t "why is the queue stuck" --arg p bproj --arg c "$cid" \
    '{text:$t,project:$p,command_id:$c,origin:"dash"}' | base64 -w0)
  ( cd "$T" && env "${BENV[@]}" JOBS_URL=http://fake BOX_CHAT_MODEL=m-chat "$@" \
      timeout 60 bash "$T/h/bin/box-chat.sh" --b64 "$b64" "$cid" ) > "$T/boxchat.log" 2>&1
}
beats()      { grep -c . "$T/log/beats.log"; }
beat_field() { jq -r ".$1 // \"\"" "$T/log/beats.log" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }

# ---------------------------------------------------------------------------
# The orchestrator: the turn-fp block, run_turn(), run_survival() and the claude
# ladder, lifted verbatim, driving the real claude-cost.sh.
# ---------------------------------------------------------------------------
sed -n '/^# >>> turn fp/,/^# <<< turn fp/p' "$ORCH" > "$T/turnfp.sh"
awk '/^run_turn\(\) \{/,/^}/' "$ORCH" > "$T/runturn.sh"
awk '/^run_survival\(\) \{/,/^}/' "$ORCH" > "$T/survival.sh"
sed -n '/^# >>> claude ladder/,/^# <<< claude ladder/p' "$ORCH" > "$T/ladder.sh"
grep -q 'ORC_TURN_FP=' "$T/turnfp.sh"   && ok || bad "0 the '# >>> turn fp' block is missing from bin/orchestrate.sh"
grep -q 'ORC_CLAUDE' "$T/runturn.sh"    && ok || bad "0 the run_turn() lift is empty or stale"
grep -q 'agent-call.sh' "$T/survival.sh" && ok || bad "0 the run_survival() lift is empty or stale"
grep -q 'CANDIDATES=(' "$T/ladder.sh"   && ok || bad "0 the claude-ladder lift is empty or stale"
cat > "$T/drive.sh" <<'DRIVE'
#!/bin/bash
set -uo pipefail
. "$LIB"
orc_fresh() { [ "${FRESH:-1}" = 1 ]; }
compose_v2_prompt() { printf 'the message\n'; }
budget_check() { :; }
survival_ready() { return 0; }
note() { echo "$1" >> "$HARNESS/logs/failovers.log"; }
IRON_LAW_ARM=()
RC=0; OUT=""; SERVED_BY=""; SURVIVAL_BRIEF="brief"
. "$BLOCK_TURNFP"
. "$BLOCK_RUNTURN"
. "$BLOCK_SURVIVAL"
. "$BLOCK_LADDER"
printf '%s' "$OUT" > "$OUTF"
{ echo "RC=$RC"; echo "FP=${ORC_TURN_FP:-}"; } > "$STATEF"
DRIVE
orc() {
  ( cd "$T" && env "${BENV[@]}" ORC="$T/orc" JOBS_URL=http://fake \
      LIB="$DIR/bin/lib/orc-account.sh" BLOCK_TURNFP="$T/turnfp.sh" BLOCK_RUNTURN="$T/runturn.sh" \
      BLOCK_SURVIVAL="$T/survival.sh" BLOCK_LADDER="$T/ladder.sh" \
      OUTF="$T/orc.out" STATEF="$T/orc.state" \
      ORC_MODEL=model-a ORC_FALLBACK=model-b ORC_SURVIVAL="" ORC_BUDGET=2 TEXT=hi META_CHAT=c1 \
      _DKEY=fixture-dkey CMD_ID=42 \
      ORC_CLAUDE="$T/h/bin/claude-cost.sh" ORC_TOKEN="" ORC_TOKEN_DEFAULT="" \
      ORC_ACCOUNT=default ORC_ACCOUNT_REASON=test COST_PROJECT=fleet COST_STAGE=orchestrator \
      "$@" timeout 60 bash "$T/drive.sh" ) > "$T/drive.log" 2>&1
}
orc_rc()  { sed -n 's/^RC=//p' "$T/orc.state" 2>/dev/null; }
orc_fp()  { sed -n 's/^FP=//p' "$T/orc.state" 2>/dev/null; }

# 1a. The fresh turn (prompt on stdin) and the -c turn are CLAIMED, fp orc:c<id>.
for fresh in 1 0; do
  scen
  orc FRESH=$fresh FAKE_ECHO_STDIN=$fresh
  eq  "1a[$fresh] turn rc 0"            "$(orc_rc)" 0
  eq  "1a[$fresh] one claim"            "$(claims)" 1
  eq  "1a[$fresh] claim fp"             "$(claim_col 3)" "orc:c42"
  eq  "1a[$fresh] guard stage"          "$(claim_col 2)" orchestrator
  eq  "1a[$fresh] claim runner"         "$(claim_col 7)" claude
  [ "$fresh" = 1 ] && has "1a[1] stdin still reached claude" "$(cat "$T/orc.out")" "STDIN:the message"
done
# Two deliveries with two command ids are two pieces of work (the operator repeats
# "status" on purpose).
scen; orc CMD_ID=43
eq  "1a cmd 43 fp"                      "$(claim_col 3)" "orc:c43"
# No command id: per-delivery, never the bare text (a text hash would refuse the Nth "status").
scen; orc CMD_ID=
case "$(claim_col 3)" in orc:dfixture-dkey:[0-9]*) ok ;; *) bad "1a no cmd id: fp [$(claim_col 3)] is not orc:d<dkey>:<epoch>" ;; esac

# 1b. box-chat end to end: the -c rung says "no conversation", the retry
# answers. Both claims carry ONE fp and the box-chat family; one reply.
scen
boxchat cid-7 FAKE_NOCONV=1
eq  "1b two claims (-c, then the retry)" "$(claims)" 2
eq  "1b claim fp"                       "$(claim_col 3)" "chat:bproj:ccid-7"
eq  "1b guard stage"                    "$(claim_col 2)" box-chat
eq  "1b claim project"                  "$(claim_col 1)" bproj
eq  "1b exactly one reply"              "$(beats)" 1
eq  "1b the reply is the answer"        "$(beat_field text)" ANSWER
eq  "1b priced rows carry lane box-chat" "$(rows | awk -F, '{print $25}' | sort -u)" box-chat
# ...and rung 2, when claude fails for real, carries the same fp, family and lane.
scen
boxchat cid-8 FAKE_FAIL_MODEL=m-chat FAKE_FAIL_TEXT="529 overloaded" RUNNER_CHAT_FALLBACK=codex
eq  "1b rung 2 ran once"                "$(grep -c . "$T/log/agent-call.log")" 1
has "1b rung 2 lane"                    "$(cat "$T/log/agent-call.log")" "|lane=box-chat|"
has "1b rung 2 fp"                      "$(cat "$T/log/agent-call.log")" "|fp=chat:bproj:ccid-8|"
has "1b rung 2 guard stage"             "$(cat "$T/log/agent-call.log")" "|gs=box-chat"
eq  "1b rung 2: exactly one reply"      "$(beats)" 1

# 1c. greenfield's run_llm, lifted: fp gf:<ws 12hex>:<stage>:p<prompt 16hex>.
awk '/^run_llm\(\) \{/,/^}/' "$GREENFIELD" > "$T/runllm.sh"
grep -q 'CLAUDE_BIN' "$T/runllm.sh" && ok || bad "1c the run_llm() lift is empty or stale"
cat > "$T/gf.sh" <<'GF'
#!/bin/bash
set -uo pipefail
IRON_LAW_ARM=()
. "$BLOCK_RUNLLM"
run_llm m-gf "$RUNDIR/$GF_STAGE.out.txt" "$GF_PROMPT"
echo "RC=$?" > "$STATEF"
GF
gf() {
  mkdir -p "$T/ws/runs"
  ( cd "$T" && env "${BENV[@]}" JOBS_URL=http://fake BLOCK_RUNLLM="$T/runllm.sh" CLAUDE_BIN="$T/h/bin/claude-cost.sh" \
      WS="$T/ws" RUNDIR="$T/ws/runs" STATEF="$T/gf.state" COST_PROJECT=greenfield \
      GF_STAGE=map GF_PROMPT="build the map" "$@" timeout 60 bash "$T/gf.sh" ) > "$T/gf.log" 2>&1
}
WSH=$(printf '%s' "$T/ws" | sha256sum | cut -c1-12)
PH=$(printf '%s' "build the map" | sha256sum | cut -c1-16)
scen; gf; gf
eq  "1c two claims"                     "$(claims)" 2
eq  "1c the same prompt is the same work" "$(claim_col 3)" "gf:$WSH:map:p$PH"
eq  "1c guard stage"                    "$(claim_col 2)" greenfield
eq  "1c claude ran"                     "$(ran)" yes
scen; gf GF_STAGE=signals
eq  "1c another stage is other work"    "$(claim_col 3)" "gf:$WSH:signals:p$PH"

# 1d. K3 enforces box-chat BY DEFAULT: a refused claim runs no claude and the
# pane still gets exactly one (rung 3) reply.
scen
boxchat cid-9 'FAKE_CLAIM={"allowed":false,"count":3}'
eq  "1d claude never ran"               "$(ran)" no
eq  "1d exactly one reply"              "$(beats)" 1
eq  "1d it is the bash rung"            "$(beat_field error)" runner_unavailable
eq  "1d one refused row"                "$(nrefused)" 1
# ...the same default reaches the orchestrator and greenfield.
scen; orc 'FAKE_CLAIM={"allowed":false,"count":6}'
eq  "1d orchestrator refused by default" "$(orc_rc)" 74
eq  "1d orchestrator: claude never ran" "$(ran)" no
scen; gf 'FAKE_CLAIM={"allowed":false,"count":2}'
eq  "1d greenfield refused by default"  "$(sed -n 's/^RC=//p' "$T/gf.state")" 74

# ---------------------------------------------------------------------------
# 2. Real lanes for box-chat and greenfield
# ---------------------------------------------------------------------------
[ -f "$LANE_BOXCHAT" ] && ok || bad "2a $LANE_BOXCHAT does not exist"
[ -f "$LANE_GREENFIELD" ] && ok || bad "2a $LANE_GREENFIELD does not exist"
eq  "2a box-chat lane" "$(jq -r '.lanes[]|select(.id=="box-chat")|"\(.scope) \(.wired) \(.stats.cost_stage) \(.script)"' "$REAL_REG")" \
    "project true chat bin/box-chat.sh"
eq  "2a greenfield lane" "$(jq -r '.lanes[]|select(.id=="greenfield")|"\(.wired) \(.script)"' "$REAL_REG")" \
    "true bin/greenfield.sh"
for l in box-chat greenfield; do
  eq "2a $l LLM_* knobs" "$(jq -r --arg l "$l" '.lanes[]|select(.id==$l)|.knobs[]|select(.env|startswith("LLM_"))|"\(.env)@\(.read_in)"' "$REAL_REG" | sort | tr '\n' ' ')" \
     "LLM_LANE_ENABLED@bin/lib/llm-gate.sh LLM_RUNNER_ALLOWED@bin/lib/llm-gate.sh LLM_USD_CAP_DAY@bin/lib/llm-gate.sh "
done
for s in box-chat greenfield; do
  eq "2a llm-sites $s names its lane" "$(jq -r --arg s "$s" '.sites[]|select(.id==$s)|.lane' "$DIR/catalog/llm-sites.json")" "$s"
done

# 2b. LLM_LANE_ENABLED=0 on box-chat: the real call is refused under lane_id
# box-chat, rung 2 is not tried (it would be refused on the same lane), and the
# pane still gets exactly one reply.
scen
setting lane.box-chat.llm_lane_enabled 0
boxchat cid-10 RUNNER_CHAT_FALLBACK=codex
eq  "2b claude never ran"               "$(ran)" no
eq  "2b exactly one refused row"        "$(nrefused)" 1
eq  "2b refused row lane_id"            "$(refused | awk -F, '{print $25}')" box-chat
has "2b refusal note"                   "$(refused | awk -F, '{print $24}')" "refused:lane-disabled box-chat"
eq  "2b rung 2 not tried"               "$(grep -c . "$T/log/agent-call.log")" 0
eq  "2b exactly one reply"              "$(beats)" 1

# 2c. LLM_LANE_ENABLED=0 on greenfield refuses run_llm under lane_id greenfield.
scen
setting lane.greenfield.llm_lane_enabled 0
gf
eq  "2c rc 74"                          "$(sed -n 's/^RC=//p' "$T/gf.state")" 74
eq  "2c claude never ran"               "$(ran)" no
eq  "2c refused row lane_id"            "$(refused | awk -F, '{print $25}')" greenfield
eq  "2c refused row stage"              "$(refused | awk -F, '{print $4}')" gf-map

# 2d. The lane switch: flags/lane-off-box-chat answers the pane once, lane_off,
# and calls nothing.
scen
: > "$T/h/flags/lane-off-box-chat"
boxchat cid-11
eq  "2d claude never ran"               "$(ran)" no
eq  "2d exactly one reply"              "$(beats)" 1
eq  "2d the reply says lane_off"        "$(beat_field error)" lane_off
eq  "2d the reply is keyed"             "$(beat_field command_id)" cid-11
eq  "2d no claim"                       "$(claims)" 0
# ...and a malformed hand-off under the switch is still one reply, not two.
scen
: > "$T/h/flags/lane-off-box-chat"
( cd "$T" && env "${BENV[@]}" bash "$T/h/bin/box-chat.sh" --b64 "$(printf '{"text":"hi"}' | base64 -w0)" cid-12 ) > /dev/null 2>&1
eq  "2d malformed + off: one reply"     "$(beats)" 1

# 2e. harness-ctl can set both lanes' knobs (it refused an unknown id before).
cat > "$T/ctl-jobs-client.sh" <<'EOF'
JOBS_BOX=test
_setting_key_ok() { case "${1:-}" in ''|*[!a-z0-9_.-]*) return 1 ;; esac; [ "${#1}" -le 64 ]; }
setting_set() { _setting_key_ok "${1:-}" || return 1; printf 'SET %s = %s\n' "$1" "$2" >> "$SETTING_LOG"; }
EOF
mkdir -p "$T/ctl/bin"; cp "$T/ctl-jobs-client.sh" "$T/ctl/bin/jobs-client.sh"
for l in box-chat greenfield; do
  : > "$T/settings.log"
  OUT=$( export HARNESS="$T/ctl" LANE_REGISTRY="$REAL_REG" SETTING_LOG="$T/settings.log"
         bash "$DIR/bin/harness-ctl.sh" set "$l" LLM_LANE_ENABLED 0 2>&1 ); RC=$?
  eq  "2e harness-ctl set $l rc"        "$RC" 0
  has "2e harness-ctl set $l row"       "$(cat "$T/settings.log")" "SET lane.$l.llm_lane_enabled = 0"
done

# ---------------------------------------------------------------------------
# 3. ONE refused row per refused orchestrator turn
# ---------------------------------------------------------------------------
scen
setting lane.orc-monitor.llm_lane_enabled 0
orc ORC_SURVIVAL=codex
eq  "3 turn rc 74"                      "$(orc_rc)" 74
eq  "3 claude never ran"                "$(ran)" no
eq  "3 exactly one refused row"         "$(nrefused)" 1
eq  "3 it is model-a's"                 "$(refused | awk -F, '{print $6}')" model-a
eq  "3 survival not tried (same lane, same refusal)" "$(grep -c . "$T/log/agent-call.log")" 0
hasnt "3 the floor does not say every lane failed" "$(cat "$T/orc.out")" "Every lane failed"
has "3 the floor names the refusal"     "$(cat "$T/orc.out")" "AGENT_CALL_REFUSED llm-gate lane-disabled orc-monitor"
# NEGATIVES that must still descend or reach survival.
scen; orc FAKE_FAIL_MODEL=model-a FAKE_FAIL_RC=74 FAKE_FAIL_TEXT="cli exit 74"
eq  "3n rc 74 without the marker descends" "$(cut -d' ' -f1 "$T/log/claude.log" | tr '\n' ' ')" "model-a model-b "
eq  "3n ...and model-b answered"        "$(orc_rc)" 0
scen; orc FAKE_FAIL_MODEL=model-a FAKE_FAIL_TEXT="529 overloaded"
eq  "3n a 529 descends"                 "$(cut -d' ' -f1 "$T/log/claude.log" | tr '\n' ' ')" "model-a model-b "
scen
setting lane.orc-monitor.llm_runner_allowed codex
orc ORC_SURVIVAL=codex
eq  "3n runner-not-allowed: one refused row" "$(nrefused)" 1
eq  "3n runner-not-allowed: survival called once" "$(grep -c . "$T/log/agent-call.log")" 1
eq  "3n runner-not-allowed: survival answered" "$(orc_rc)" 0
scen; orc ORC_SURVIVAL=codex 'FAKE_CLAIM={"allowed":false,"count":6}'
eq  "3n K3 refusal: one refused row"    "$(nrefused)" 1
eq  "3n K3 refusal: survival called once" "$(grep -c . "$T/log/agent-call.log")" 1

# ---------------------------------------------------------------------------
# 4. product-cmd keeps lane stage-chat when box-chat is switched off
# ---------------------------------------------------------------------------
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
A="$T/ac"; mkdir -p "$A/logs" "$A/locks" "$A/flags" "$A/state" "$A/bin" "$A/catalog" "$A/fakebin"
model_routes_fixture "$A" || exit 1
cat > "$A/fakebin/claude" <<'EOF'
#!/bin/bash
touch "$SENTINEL_DIR/claude-ran"
printf '{"result":"ok","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}\n'
EOF
cat > "$A/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
printf '#!/bin/bash\necho subscription\n' > "$A/bin/billing-mode.sh"
chmod +x "$A/fakebin/"* "$A/bin/billing-mode.sh"
printf '_jobs_req() { return 1; }\n' > "$A/bin/jobs-client.sh"
printf '{"fetched_at":%s,"values":{"lane.box-chat.llm_lane_enabled":"0"},"seeded":{}}' "$(date -u +%s)" > "$A/state/settings-cache.json"
PCLINE=$(grep -E '^[[:space:]]*[^#]*agent-call\.sh" chat "\$PROJECT"' "$PRODUCTCMD" | head -1 \
         | sed 's#"\$HARNESS/bin/agent-call.sh"#bash "$AC"#')
case "$PCLINE" in *'bash "$AC" chat'*) ok ;; *) bad "4 could not lift product-cmd's chat call: [$PCLINE]" ;; esac
( export SENTINEL_DIR="$A" PATH="$A/fakebin:$PATH" HARNESS="$A" HOME="$A" LANE_REGISTRY="$REAL_REG" \
         CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" BEAT_LOG=/dev/null
  AC="$DIR/bin/agent-call.sh" PROJECT=lproj CHAT_MODEL=claude-fable-5 CHATDIR="$A" SLUG=s PROMPT=hello
  eval "$PCLINE" ) >/dev/null 2>&1
eq  "4 product-cmd chat ran with box-chat off" "$([ -f "$A/claude-ran" ] && echo yes || echo no)" yes
eq  "4 its row keeps lane stage-chat"   "$(awk -F, 'NR>1 && NF>=25 {print $25}' "$A/logs/cost.csv" 2>/dev/null | tail -1)" stage-chat

echo "claude-cost-followups.bh-2603: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
