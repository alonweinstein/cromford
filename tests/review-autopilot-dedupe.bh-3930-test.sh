#!/bin/bash
# tests/review-autopilot-dedupe.bh-3930-test.sh — BH-3930 (slice BH-3939): the
# >12h review autopilot stands down on ANY verdict already bound to this head
# except the builder's own, and names its paid call to the guard as the shared
# per-head fingerprint, so two lanes on one head buy one review.
#
# WHAT IS ASSERTED, on what a RUN DID: the real bin/review-autopilot.sh tick
# against a scratch $HARNESS with gh, agent-call and beat stubbed, and (B4/B5)
# the real bin/agent-call.sh against a fake worker `curl` and fake `claude`.
# bin/lib/review-bought.sh in the scratch tree is the REAL lib with only
# review_bought overridden by a stub that answers from $T/rb-answer
# (`hit <source> <WORD>` | `miss` | `unreadable`) and records its argv, so no
# case here ever makes the real ledger reads.
#
#   B1  hit mc-rereview APPROVE, VERDICT_SINGLE_HOME unset -> no call, a
#       `(ledger)` skip key, the review_skip_unchanged line, cap unchanged
#   B2  hit lead MERGE -> the same, naming lead
#   B3  miss (only the builder's round) -> exactly one call, a `reviewed` key
#   S   review_bought was asked with the FULL 40-hex sha and --except-builder
#   R1  unreadable (rc 1) -> logged, falls through, one call
#   D0  REVIEW_DEDUPE=0 with a would-be hit -> the read is skipped, one call
#   P   miss + state/<p>.pr-reviews.json holds the sha -> the file fallback
#   L   no lib at all -> one call, the inline review_fp fallback, review-head
#   F   the paid call carries AGENT_CALL_GUARD_STAGE=review-head and
#       AGENT_CALL_FP=review:<slug>#<n>@<40-hex>
#   B4  two lanes on one head through the real agent-call: 0 then 74, one vendor call
#   B5  counter unreachable: metered refused (74), subscription runs; and the
#       autopilot treats that refusal as "nothing billed"
#
# Run from anywhere: bash tests/review-autopilot-dedupe.bh-3930-test.sh  (0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset VERDICT_SINGLE_HOME REVIEW_DEDUPE AGENT_CALL_GUARD_STAGE AGENT_CALL_FP

# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
CREATED=$(date -u -d "@$((NOW - 46800))" '+%Y-%m-%dT%H:%M:%SZ')
DAY=$(date -u -d "@$NOW" '+%Y%m%d')

H="$T/h"
mkdir -p "$H/bin/lib/mc" "$H/logs" "$H/locks" "$H/env" "$H/state" "$T/fakebin"
cp "$DIR/bin/review-autopilot.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/review-model.sh" "$H/bin/lib/"
cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
cp "$DIR/bin/lib/review-bought.sh" "$H/bin/lib/review-bought.real.sh"
printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n' > "$H/fleet.conf"
: > "$H/env/global.env"
mrs_fixture "$H" p1

SHA=0123456789abcdef0123456789abcdef01234567
HEAD12=${SHA:0:12}
KEY="$H/state/review-autopilot/o-p1-7-$HEAD12"
CNTF="$H/state/review-autopilot/count-p1-$DAY"
LOG="$H/logs/review-autopilot.log"

jq -n --arg sha "$SHA" --arg c "$CREATED" \
  '[{number:7,html_url:"https://github.com/o/p1/pull/7",title:"BH-x: a thing",
     body:"Closes #7",head:{sha:$sha,ref:"ticket/x"},base:{ref:"main"},
     draft:false,user:{login:"operator",type:"User"},created_at:$c,updated_at:$c,
     merged_at:null,closed_at:null,labels:[],state:"open"}]' > "$T/pulls.json"

{ printf '#!/bin/bash\nT=%q\n' "$T"; cat <<'EOF'
if [ "${1:-}" = pr ] && [ "${2:-}" = comment ]; then echo post >> "$T/post-count.txt"; exit 0; fi
case "$*" in
  api\ repos/o/p1/pulls*|*repos/o/p1/pulls\?*)
    case "$*" in *" -i "*) printf 'HTTP/2.0 200 OK\r\n\r\n' ;; esac
    cat "$T/pulls.json" ;;
  *"pr diff"*--name-only*)  printf 'bin/x.sh\n' ;;
  *"pr diff"*)              printf 'diff --git a/bin/x.sh b/bin/x.sh\n+echo hi\n' ;;
  *"pr view"*--json\ body*) printf 'Closes #7\n' ;;
  *"pr view"*)              printf 'mergeable=MERGEABLE mergeState=CLEAN checks=ci=SUCCESS\n' ;;
  *)                        : ;;
esac
exit 0
EOF
} > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"

# THE BILLABLE CALL: argv, the guard stage and the guard fp, one line each per call.
write_agent_stub() { # write_agent_stub ok|refuse
  { printf '#!/bin/bash\nT=%q\nMODE=%q\n' "$T" "$1"; cat <<'EOF'
printf '%s\n' "$*" >> "$T/agent-calls.txt"
printf '%s\n' "${AGENT_CALL_GUARD_STAGE:-}" >> "$T/agent-call-stages.txt"
printf '%s\n' "${AGENT_CALL_FP:-}" >> "$T/agent-call-fps.txt"
if [ "$MODE" = refuse ]; then
  printf 'AGENT_CALL_REFUSED call-guard counter-unreadable metered claude\n' > "$5"; exit 74
fi
printf 'Nothing deferred.\n\nVERDICT: MERGE — reads fine\n' > "$5"
exit 0
EOF
  } > "$H/bin/agent-call.sh"
  chmod +x "$H/bin/agent-call.sh"
}
write_agent_stub ok
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"

# The lib under test: the real one, review_bought swapped for the answer file.
write_rb_stub() {
  { printf '#!/bin/bash\n_RBT=%q\n' "$T"; cat <<'EOF'
. "$(dirname "${BASH_SOURCE[0]}")/review-bought.real.sh" || return 1
review_bought() {
  RB_SOURCE=""; RB_WORD=""; RB_CLASS=""
  printf '%s\n' "$*" >> "$_RBT/rb-args"
  local a s w; read -r a s w < "$_RBT/rb-answer"
  case "$a" in
    hit) RB_SOURCE=$s; RB_WORD=$w; RB_CLASS=approve; printf '%s\t%s\n' "$s" "$w"; return 0 ;;
    unreadable) return 1 ;;
    *) return 2 ;;
  esac
}
EOF
  } > "$H/bin/lib/review-bought.sh"
}
write_rb_stub

RUN() { ( PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" GH_TOKEN="" \
          bash "$H/bin/review-autopilot.sh" >>"$T/run.log" 2>&1 ) || true; }
CALLS() { wc -l < "$T/agent-calls.txt" 2>/dev/null | tr -d ' '; }
CAP()   { cat "$CNTF" 2>/dev/null || echo 0; }
RESET() { scratch_rm "$H/state/review-autopilot"
          rm -f "$H/state/p1.pr-reviews.json" "$T/rb-args"
          : > "$T/agent-calls.txt"; : > "$T/agent-call-stages.txt"; : > "$T/agent-call-fps.txt"
          : > "$T/post-count.txt"; : > "$LOG"; printf '%s\n' "${1:-miss}" > "$T/rb-answer"; }

# --- B1: a reviewer's verdict on this head stands the lane down -------------
RESET "hit mc-rereview APPROVE"
RUN
[ "$(CALLS)" = 0 ] && ok || bad "B1 an mc-rereview verdict on this head must buy nothing (calls=$(CALLS))"
head -1 "$KEY" 2>/dev/null | grep -qE '^skipped .*mc-rereview verdict APPROVE bound to this head \(ledger\)$' && ok \
  || bad "B1 key: '$(head -1 "$KEY" 2>/dev/null)'"
grep -qF "review_skip_unchanged o/p1#7@$HEAD12 lane=review-autopilot by=mc-rereview/APPROVE" "$LOG" && ok \
  || bad "B1 no review_skip_unchanged line: $(cat "$LOG")"
grep -q 'ledger verdict bound to this head' "$LOG" && ok || bad "B1 the stand-down line is missing: $(cat "$LOG")"
[ "$(CAP)" = 0 ] && ok || bad "B1 a skip must not charge the cap (cap=$(CAP))"
cp "$T/rb-args" "$T/rb-args-b1" 2>/dev/null
# A settled skip is never asked again.
RUN
[ "$(CALLS)" = 0 ] && ok || bad "B1 the second tick re-bought a skipped head (calls=$(CALLS))"

# --- S: the full 40-hex head and --except-builder ---------------------------
[ "$(head -1 "$T/rb-args-b1" 2>/dev/null)" = "o/p1 7 $SHA --except-builder" ] && ok \
  || bad "S review_bought argv: '$(head -1 "$T/rb-args-b1" 2>/dev/null)', want 'o/p1 7 $SHA --except-builder'"
s3=$(head -1 "$T/rb-args-b1" 2>/dev/null | cut -d' ' -f3)
[ "${#s3}" = 40 ] && ok || bad "S the sha arg is ${#s3} chars, want 40"

# --- B2: the lead's verdict counts too --------------------------------------
RESET "hit lead MERGE"
RUN
[ "$(CALLS)" = 0 ] && ok || bad "B2 a lead verdict on this head must buy nothing (calls=$(CALLS))"
head -1 "$KEY" 2>/dev/null | grep -qE '^skipped .*lead verdict MERGE bound to this head \(ledger\)$' && ok \
  || bad "B2 key: '$(head -1 "$KEY" 2>/dev/null)'"
grep -qF "review_skip_unchanged o/p1#7@$HEAD12 lane=review-autopilot by=lead/MERGE" "$LOG" && ok \
  || bad "B2 no review_skip_unchanged line: $(cat "$LOG")"
[ "$(CAP)" = 0 ] && ok || bad "B2 cap=$(CAP)"

# --- B3 + F: a miss buys exactly one review, named to the guard per head ----
RESET miss
RUN
[ "$(CALLS)" = 1 ] && ok || bad "B3 a builder-only round must still buy the review (calls=$(CALLS))"
head -1 "$KEY" 2>/dev/null | grep -q '^reviewed ' && ok || bad "B3 key: '$(head -1 "$KEY" 2>/dev/null)'"
[ "$(cat "$T/agent-call-stages.txt")" = review-head ] && ok \
  || bad "F guard stage '$(cat "$T/agent-call-stages.txt")', want review-head"
[ "$(cat "$T/agent-call-fps.txt")" = "review:o/p1#7@$SHA" ] && ok \
  || bad "F guard fp '$(cat "$T/agent-call-fps.txt")', want review:o/p1#7@$SHA"
[ "$(cut -d' ' -f1 "$T/agent-calls.txt")" = review ] && ok \
  || bad "F the positional stage must stay review (the cost row / route): $(cat "$T/agent-calls.txt")"

# --- R1: an unreadable ledger falls through ---------------------------------
RESET unreadable
RUN
grep -q 'review_dedupe unreadable' "$LOG" && ok || bad "R1 no unreadable line: $(cat "$LOG")"
[ "$(CALLS)" = 1 ] && ok || bad "R1 rc 1 must fall through to the review (calls=$(CALLS))"

# --- D0: the kill switch skips the read -------------------------------------
RESET "hit mc-rereview APPROVE"
( export REVIEW_DEDUPE=0; RUN )
[ "$(CALLS)" = 1 ] && ok || bad "D0 REVIEW_DEDUPE=0 must not stand down (calls=$(CALLS))"
grep -q '(ledger)' "$KEY" 2>/dev/null && bad "D0 a (ledger) key was written with the read off" || ok
[ -s "$T/rb-args" ] && bad "D0 review_bought was asked with REVIEW_DEDUPE=0" || ok

# --- P: the pr-reviews.json fallback is intact -------------------------------
RESET miss
printf '{"7":{"sha":"%s","verdict":"APPROVE"}}' "$SHA" > "$H/state/p1.pr-reviews.json"
RUN
[ "$(CALLS)" = 0 ] && ok || bad "P the file fallback must still stand down (calls=$(CALLS))"
grep -q 'already reviewed by review-prs — standing down' "$LOG" && ok || bad "P log: $(cat "$LOG")"

# --- L: no lib on the box (mid-sync) ----------------------------------------
mv "$H/bin/lib/review-bought.sh" "$T/rb-stub.away"
RESET "hit mc-rereview APPROVE"
RUN
[ "$(CALLS)" = 1 ] && ok || bad "L with no lib the lane must review as before (calls=$(CALLS)): $(tail -3 "$T/run.log")"
[ "$(cat "$T/agent-call-fps.txt")" = "review:o/p1#7@$SHA" ] && ok \
  || bad "L fallback fp '$(cat "$T/agent-call-fps.txt")', want review:o/p1#7@$SHA"
[ "$(cat "$T/agent-call-stages.txt")" = review-head ] && ok || bad "L stage '$(cat "$T/agent-call-stages.txt")'"
mv "$T/rb-stub.away" "$H/bin/lib/review-bought.sh"

# --- B5 (autopilot half): a guard refusal is "nothing billed" ---------------
write_agent_stub refuse
RESET miss
RUN
grep -q 'returned before billing (rc=74' "$LOG" && ok || bad "B5 the refusal was not read as before-billing: $(cat "$LOG")"
[ -e "$KEY" ] && bad "B5 a refused call wrote a key: $(head -1 "$KEY")" || ok
[ "$(CAP)" = 0 ] && ok || bad "B5 a refused call charged the cap (cap=$(CAP))"
write_agent_stub ok

# --- B4/B5: the real bin/agent-call.sh with the shared fp --------------------
A="$T/ac"
mkdir -p "$A/bin/lib/jobs" "$A/fakebin" "$A/flags" "$A/locks" "$A/logs" "$A/state"
mrs_fixture "$A" testproj
cp "$DIR/bin/jobs-client.sh" "$A/bin/jobs-client.sh"
cp "$DIR/bin/lib/jobs/"*.sh "$A/bin/lib/jobs/"
cp "$DIR/bin/lib/env-path.sh" "$A/bin/lib/env-path.sh"
cat > "$A/fakebin/claude" <<'EOF'
#!/bin/bash
echo claude >> "$ORDER_SINK"
echo '{"result":"the answer","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}'
EOF
cat > "$A/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
# The fake worker: claim/settle over a rows file (bh-2305's shape); CG_DOWN=1 is unreachable.
cat > "$A/fakebin/curl" <<'EOF'
#!/bin/bash
url="" data=""
while [ $# -gt 0 ]; do
  case "$1" in
    --data-binary) data="$2"; shift 2 ;;
    -X|-m|--connect-timeout|-w|-H) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
[ "${CG_DOWN:-0}" = 1 ] && exit 7
case "$data" in @*) data=$(cat "${data#@}") ;; esac
case "$url" in */api/call-guard/*) ;; *) exit 7 ;; esac
touch "$CG_ROWS"
case "$url" in
  */claim)
    id=$(jq -r .call_id <<<"$data"); p=$(jq -r .project <<<"$data"); s=$(jq -r .stage <<<"$data")
    f=$(jq -r .fp <<<"$data"); m=$(jq -r .max <<<"$data")
    n=$(awk -F'\t' -v p="$p" -v s="$s" -v f="$f" '$2==p && $3==s && $4==f && ($5=="claimed"||$5=="ok"||$5=="empty"||$5=="failed"){c++} END{print c+0}' "$CG_ROWS")
    if [ "$n" -lt "$m" ]; then
      printf '%s\t%s\t%s\t%s\tclaimed\n' "$id" "$p" "$s" "$f" >> "$CG_ROWS"
      printf '{"allowed":true,"count":%s,"max":%s,"call_id":"%s"}\n200' "$((n+1))" "$m" "$id"
    else
      printf '{"allowed":false,"count":%s,"max":%s,"call_id":"%s","top":[{"fp":"%s","paid":%s,"refused":1}]}\n200' "$n" "$m" "$id" "$f" "$n"
    fi ;;
  */settle)
    id=$(jq -r .call_id <<<"$data"); o=$(jq -r .outcome <<<"$data")
    awk -F'\t' -v OFS='\t' -v id="$id" -v o="$o" '$1==id && $5=="claimed"{$5=o} {print}' "$CG_ROWS" > "$CG_ROWS.tmp" && mv "$CG_ROWS.tmp" "$CG_ROWS"
    printf '{"settled":true}\n200' ;;
  *) printf '{"error":"unknown endpoint"}\n404' ;;
esac
EOF
printf '#!/bin/bash\nexit 0\n' > "$A/bin/beat.sh"
printf '#!/bin/bash\necho "test rules"\n' > "$A/bin/sync-agent-rules.sh"
chmod +x "$A/fakebin/"* "$A/bin/"*.sh

ROWS="$A/cg.rows"
acreset() { : > "$A/order"; : > "$ROWS"; rm -f "$A/logs/"* "$A"/flags/alerted-* 2>/dev/null; }
# accall <out> <billing metered|subscription> [VAR=VAL ...] -> prints the rc
accall() {
  local out="$1" bm="$2"; shift 2
  printf '#!/bin/bash\necho %s\n' "$bm" > "$A/bin/billing-mode.sh"; chmod +x "$A/bin/billing-mode.sh"
  ( unset AGENT_CALL_GUARD_STAGE AGENT_CALL_FP AGENT_CALL_TICKET AGENT_CALL_GUARD_FORCE HARNESS_TICKET \
          CALL_GUARD CALL_GUARD_STAGES CALL_GUARD_MAX_MAP CALL_GUARD_FAIL_CLOSED_METERED
    export ORDER_SINK="$A/order" CG_ROWS="$ROWS" \
           PATH="$A/fakebin:$PATH" HARNESS="$A" HOME="$A" \
           JOBS_URL="https://jobs.test" HARNESS_SECRET="test-secret" JOBS_RETRIES=0 JOBS_BOX=testbox \
           CLAUDE_CODE_OAUTH_TOKEN=tok ANTHROPIC_API_KEY= \
           OPENROUTER_API_KEY= FIREWORKS_API_KEY= CODEX_API_KEY= OPENAI_API_KEY= ACCOUNT_ROUTING=0 \
           LADDER_TIER2_GROK=0 LADDER_BACKOFF_SECS=0 LADDER_SAME_RETRIES=0 \
           AGENT_CALL_RUNNERS= AGENT_CALL_LEDGER=0 RUNNER_REVIEW=claude RUNNER_REVIEW_FALLBACK= \
           LANE_GATE_DISABLE=1 LLM_GATE_DISABLE=1 \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" "$@"
    cd "$A" && bash "$DIR/bin/agent-call.sh" review testproj claude-fable-5-1 60 "$A/$out" "the review prompt" \
      >/dev/null 2>&1 )
  echo $?
}
vendor() { grep -c . "$A/order" 2>/dev/null || true; }
FP=$( . "$DIR/bin/lib/review-bought.sh" && review_fp o/r 7 "$SHA" )
[ "$FP" = "review:o/r#7@$SHA" ] && ok || bad "B4 review_fp printed '$FP'"

# B4: two lanes, one head, default K.
acreset
r1=$(accall b4-1 subscription AGENT_CALL_GUARD_STAGE=review-head AGENT_CALL_FP="$FP")
r2=$(accall b4-2 subscription AGENT_CALL_GUARD_STAGE=review-head AGENT_CALL_FP="$FP")
[ "$r1 $r2" = "0 74" ] && ok || bad "B4 rcs '$r1 $r2', want '0 74'"
[ "$(vendor)" = 1 ] && ok || bad "B4 vendor called $(vendor) times, want 1"
n=$(awk -F'\t' -v f="$FP" '$4==f' "$ROWS" | wc -l | tr -d ' ')
[ "$n" = 1 ] && ok || bad "B4 rows for $FP: $n, want 1: $(cat "$ROWS")"
head -1 "$A/b4-2" 2>/dev/null | grep -q '^AGENT_CALL_REFUSED call-guard repeat review-head' && ok \
  || bad "B4 refusal marker: '$(head -1 "$A/b4-2" 2>/dev/null)'"

# B5: the counter is unreachable.
acreset
r=$(accall b5-m metered CG_DOWN=1 AGENT_CALL_GUARD_STAGE=review-head AGENT_CALL_FP="$FP")
[ "$r" = 74 ] && [ "$(vendor)" = 0 ] && ok || bad "B5 metered + unreachable: rc=$r vendor=$(vendor), want 74 and 0"
head -1 "$A/b5-m" 2>/dev/null | grep -q '^AGENT_CALL_REFUSED call-guard counter-unreadable metered' && ok \
  || bad "B5 marker: '$(head -1 "$A/b5-m" 2>/dev/null)'"
acreset
r=$(accall b5-s subscription CG_DOWN=1 AGENT_CALL_GUARD_STAGE=review-head AGENT_CALL_FP="$FP")
[ "$r" = 0 ] && [ "$(vendor)" = 1 ] && ok || bad "B5 subscription + unreachable: rc=$r vendor=$(vendor), want 0 and 1"

echo "review-autopilot-dedupe.bh-3930: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
