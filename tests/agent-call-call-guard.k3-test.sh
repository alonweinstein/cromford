#!/bin/bash
# tests/agent-call-call-guard.k3-test.sh — K3, THE PRE-CALL GUARD.
#
# bin/agent-call.sh claims a slot for (project, guard stage, fingerprint) on the
# harness-jobs call_guard counter BEFORE the first rung runs. At the stage's
# ceiling K of paid calls in the window the call is refused rc 74 and nothing is
# called. Metered runners fail CLOSED when the counter cannot be read;
# subscription runners fail open. This is repeat prevention, not a budget.
#
# Everything here DRIVES the real bin/agent-call.sh against fake vendor CLIs
# and a fake `curl` that plays the worker (the worker's own SQL is proven by
# worker/jobs/test/call-guard.k3.test.js against node:sqlite). The fake curl
# answers /api/call-guard/* only; every other worker path is a transport
# failure, i.e. the fail-open world every existing agent-call suite runs in.
# Assertions are on artifacts — the vendor ORDER sink, $OUT, the fake worker's
# rows, ALERTS.log — never on the script's source text.
#
# Run from anywhere: tests/agent-call-call-guard.k3-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/bin/lib/jobs" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state"
mrs_fixture "$T" testproj otherproj

# The REAL client and its modules, so the transport the guard rides is the one
# that ships (a fixture that copies the client must copy the modules too).
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
cp "$DIR/bin/lib/jobs/"*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/lib/env-path.sh" "$T/bin/lib/env-path.sh"
# The REAL billing-mode answer: metered vs subscription is the fail-closed axis.
cp "$DIR/bin/billing-mode.sh" "$T/bin/billing-mode.sh"

cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
echo claude >> "$ORDER_SINK"
env | grep -E '^AGENT_CALL_(FP|GUARD_STAGE|TICKET|GUARD_FORCE)=' >> "$LEAK_SINK"
case "${CLAUDE_RESULT:-ok}" in
  empty) echo '{"result":"","usage":{"input_tokens":10,"output_tokens":0},"total_cost_usd":0.01}'; exit 0 ;;
  fail)  echo "vendor error" >&2; exit 1 ;;
  # A subscription account out of its window: the CLI's 429 envelope, rc 1.
  limit) echo '{"is_error":true,"api_error_status":429,"result":"You have hit your session limit - resets 8am"}'; exit 1 ;;
  *)     echo '{"result":"the review text","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}'; exit 0 ;;
esac
EOF
cat > "$T/fakebin/grok" <<'EOF'
#!/bin/bash
echo grok >> "$ORDER_SINK"
env | grep -E '^AGENT_CALL_(FP|GUARD_STAGE|TICKET|GUARD_FORCE)=' >> "$LEAK_SINK"
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
env | grep -E '^AGENT_CALL_(FP|GUARD_STAGE|TICKET|GUARD_FORCE)=' >> "$LEAK_SINK"
echo "$provider answered"
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
# THE FAKE WORKER. Rows in $CG_ROWS: call_id<TAB>project<TAB>stage<TAB>fp<TAB>status.
# CG_FAKE=down -> transport failure (curl rc 7); CG_FAKE=500 -> an HTTP 500.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
url="" data="" method=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data-binary) data="$2"; shift 2 ;;
    -m|--connect-timeout|-w|-H) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$data" in @*) data=$(cat "${data#@}") ;; esac
case "$url" in */api/call-guard/*|*/api/call-guard\?*) ;; *) exit 7 ;; esac
case "${CG_FAKE:-up}" in
  down) exit 7 ;;
  500)  printf '{"error":"boom"}\n500'; exit 0 ;;
  404)  printf '{"error":"unknown endpoint","worker":"harness-jobs"}\n404'; exit 0 ;;
esac
echo "$method ${url##*/api/call-guard/}" >> "$CG_REQS"
touch "$CG_ROWS"
case "$url" in
  */claim)
    id=$(jq -r .call_id <<<"$data"); p=$(jq -r .project <<<"$data"); s=$(jq -r .stage <<<"$data")
    f=$(jq -r .fp <<<"$data"); m=$(jq -r .max <<<"$data")
    n=$(awk -F'\t' -v p="$p" -v s="$s" -v f="$f" '$2==p && $3==s && $4==f && ($5=="claimed"||$5=="ok"||$5=="empty"||$5=="failed"){c++} END{print c+0}' "$CG_ROWS")
    fo=$(jq -r '.force // false' <<<"$data")
    if [ "$n" -lt "$m" ] || [ "$fo" = true ]; then
      printf '%s\t%s\t%s\t%s\tclaimed\n' "$id" "$p" "$s" "$f" >> "$CG_ROWS"
      printf '{"allowed":true,"count":%s,"max":%s,"call_id":"%s"}\n200' "$((n+1))" "$m" "$id"
    else
      printf '%s\t%s\t%s\t%s\trefused\n' "$id" "$p" "$s" "$f" >> "$CG_ROWS"
      r=$(awk -F'\t' -v f="$f" '$4==f && $5=="refused"{c++} END{print c+0}' "$CG_ROWS")
      printf '{"allowed":false,"count":%s,"max":%s,"call_id":"%s","top":[{"fp":"%s","paid":%s,"refused":%s}]}\n200' "$n" "$m" "$id" "$f" "$n" "$r"
    fi ;;
  */settle)
    id=$(jq -r .call_id <<<"$data"); o=$(jq -r .outcome <<<"$data")
    awk -F'\t' -v OFS='\t' -v id="$id" -v o="$o" '$1==id && $5=="claimed"{$5=o} {print}' "$CG_ROWS" > "$CG_ROWS.tmp" && mv "$CG_ROWS.tmp" "$CG_ROWS"
    printf '{"settled":true}\n200' ;;
  *"/api/call-guard?"*)
    printf '%s %s\n' "$method" "${url#*/api/call-guard}" >> "$CG_REQS.reset"
    printf '{"reset":2}\n200' ;;
  *) printf '{"error":"unknown endpoint","worker":"harness-jobs"}\n404' ;;
esac
EOF
cat > "$T/bin/beat.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$T/bin/sync-agent-rules.sh" <<'EOF'
#!/bin/bash
echo "test rules"
EOF
chmod +x "$T/fakebin/"* "$T/bin/"*.sh

ROWS="$T/cg.rows"
reset() {
  : > "$T/order"; : > "$T/leak"; : > "$T/logs/ALERTS.log"; : > "$T/logs/failovers.log"; : > "$ROWS"; : > "$T/cg.reqs"
  rm -f "$T/logs/cost.csv" "$T/logs/call-guard.log" "$T"/flags/alerted-call-guard-* "$T/state/agent-call-ledger" -r
}

# call <out-name> <stage> <prompt> [VAR=VAL ...] -> prints the rc.
# Safe defaults: a SUBSCRIPTION claude box (OAuth token, no API key), no
# survival keys, no grok rung, a live fake worker. Per-case overrides win.
call() {
  local out="$1" stage="$2" prompt="$3"; shift 3
  ( unset AGENT_CALL_FP AGENT_CALL_GUARD_STAGE AGENT_CALL_TICKET AGENT_CALL_GUARD_FORCE HARNESS_TICKET \
          CALL_GUARD CALL_GUARD_STAGES CALL_GUARD_MAX_MAP CALL_GUARD_FAIL_CLOSED_METERED
    export ORDER_SINK="$T/order" LEAK_SINK="$T/leak" CG_ROWS="$ROWS" CG_REQS="$T/cg.reqs" CG_FAKE=up \
           PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           JOBS_URL="https://jobs.test" HARNESS_SECRET="test-secret" JOBS_RETRIES=0 JOBS_BOX=testbox \
           CLAUDE_CODE_OAUTH_TOKEN=tok ANTHROPIC_API_KEY= \
           OPENROUTER_API_KEY= FIREWORKS_API_KEY= CODEX_API_KEY= OPENAI_API_KEY= ACCOUNT_ROUTING=0 \
           LADDER_TIER2_GROK=0 LADDER_BACKOFF_SECS=0 LADDER_SAME_RETRIES=0 CLAUDE_RESULT=ok \
           AGENT_CALL_RUNNERS= AGENT_CALL_LEDGER=0 RUNNER_REVIEW=claude RUNNER_REVIEW_FALLBACK= \
           RUNNER_TRIAGE=claude RUNNER_TRIAGE_FALLBACK= LANE_GATE_DISABLE=1 LLM_GATE_DISABLE=1 \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" "$@"
    cd "$T" && bash "$DIR/bin/agent-call.sh" "$stage" testproj claude-fable-5-1 60 "$T/$out" "$prompt" \
      >/dev/null 2>&1 )
  echo $?
}
vendor_calls() { grep -c . "$T/order" 2>/dev/null || true; }
rows_with()   { awk -F'\t' -v s="$1" '$5==s{c++} END{print c+0}' "$ROWS"; }

# --- 1. PARITY: a first guarded call is the call it always was ---------------
reset
rc_off=$(call out1 review "review PR #7 at abc" CALL_GUARD=0)
order_off=$(cat "$T/order"); body_off=$(cat "$T/out1")
[ -s "$T/cg.reqs" ] && bad "1a CALL_GUARD=0 still asked the worker: $(cat "$T/cg.reqs")" || ok
reset
rc_on=$(call out1 review "review PR #7 at abc")
[ "$rc_on" = "$rc_off" ] && [ "$(cat "$T/order")" = "$order_off" ] && [ "$(cat "$T/out1")" = "$body_off" ] \
  && ok || bad "1b a first guarded call differs from the unguarded one: rc $rc_on vs $rc_off, order '$(cat "$T/order")' vs '$order_off'"
[ "$(rows_with ok)" = 1 ] && ok || bad "1c the call was not claimed and settled ok: $(cat "$ROWS")"
grep -q '\[call-guard\]' "$T/logs/ALERTS.log" && bad "1d a paid first call wrote a call-guard ALERTS line: $(cat "$T/logs/ALERTS.log")" || ok

# --- 2. the SECOND identical call does not reach the vendor (K=1) ------------
reset
FP="review-prs:acme/app#229@553a9e0"
r1=$(call o2 review "review 229" AGENT_CALL_FP="$FP" CALL_GUARD_MAX_MAP="review=1")
r2=$(call o2b review "review 229, reworded prompt" AGENT_CALL_FP="$FP" CALL_GUARD_MAX_MAP="review=1")
[ "$r1" = 0 ] && ok || bad "2a first call rc=$r1"
[ "$r2" = 74 ] && ok || bad "2b second identical-work call rc=$r2, want 74 (refused, nothing billed)"
[ "$(vendor_calls)" = 1 ] && ok || bad "2c the vendor was reached $(vendor_calls) times, want 1"
head -1 "$T/o2b" | grep -q '^AGENT_CALL_REFUSED call-guard repeat ' && ok || bad "2d refusal marker missing: $(head -1 "$T/o2b")"
grep -q 'refused:call-guard:repeat' "$T/logs/cost.csv" && ok || bad "2e no zero-cost refused row in cost.csv"
awk -F, '$13!="0" && /call-guard/{b=1} END{exit b}' "$T/logs/cost.csv" && ok || bad "2f the refused row carries a cost"

# --- 3. a DIFFERENT head sha is different work -------------------------------
r3=$(call o3 review "review 229" AGENT_CALL_FP="review-prs:acme/app#229@0000new" CALL_GUARD_MAX_MAP="review=1")
[ "$r3" = 0 ] && [ "$(vendor_calls)" = 2 ] && ok || bad "3 a new head was refused (rc=$r3, vendor calls $(vendor_calls))"

# --- 4. the DEFAULTS: review K=2, the third identical call is refused --------
reset
for i in 1 2 3; do rr[$i]=$(call "d$i" review "same prompt"); done
[ "${rr[1]}" = 0 ] && [ "${rr[2]}" = 0 ] && [ "${rr[3]}" = 74 ] && ok \
  || bad "4a default review ceiling: rcs ${rr[1]} ${rr[2]} ${rr[3]}, want 0 0 74"
[ "$(vendor_calls)" = 2 ] && ok || bad "4b vendor reached $(vendor_calls) times, want 2"
# the fallback fingerprint is the PROMPT: a different prompt is different work
r4=$(call d4 review "a different prompt")
[ "$r4" = 0 ] && ok || bad "4c a different prompt shared the fallback fingerprint (rc=$r4)"

# --- 5. ONE digest line per (project, stage) per day, WARN, naming the fp ----
n=$(grep -c '\[call-guard\] REPEAT CALLS REFUSED \[testproj\] review' "$T/logs/ALERTS.log")
[ "$n" = 1 ] && ok || bad "5a want exactly 1 ALERTS line, got $n"
r5=$(call d5 review "same prompt")
[ "$r5" = 74 ] && ok || bad "5b rc=$r5"
n=$(grep -c '\[call-guard\]' "$T/logs/ALERTS.log")
[ "$n" = 1 ] && ok || bad "5c a second refusal the same day added a line ($n)"
grep -q ':p[0-9a-f]\{16\}' "$T/logs/ALERTS.log" && ok || bad "5d the line does not name the fingerprint"
[ "$(grep -c REFUSED "$T/logs/call-guard.log")" -ge 2 ] && ok || bad "5e per-refusal lines missing from logs/call-guard.log"
( export HARNESS="$T"; . "$DIR/bin/lib/alert-state.sh" 2>/dev/null || exit 3
  alert_state_route "$(grep '\[call-guard\]' "$T/logs/ALERTS.log" | tail -1)" critical ) > "$T/sev" 2>/dev/null
[ "$(cat "$T/sev")" = warn ] && ok || bad "5f the digest line routes to '$(cat "$T/sev")', want warn (never an immediate page)"
MCRE=$(sed -n "s/^_MC_LANE_EXHAUST_BUILTIN='\(.*\)'$/\1/p" "$DIR/bin/lib/mc/locks.sh")
[ -n "$MCRE" ] && ! grep -qiE "$MCRE" <<<"$(head -1 "$T/d5")" && ok \
  || bad "5g the refusal marker reads as an ACCOUNT fact to the merge conductor (it would mark the lane down)"

# --- 6. an EMPTY result is a paid call (terminal), not a free retry ---------
reset
e1=$(call e1 review "empty one" CLAUDE_RESULT=empty)
e2=$(call e2 review "empty one" CLAUDE_RESULT=empty)
e3=$(call e3 review "empty one" CLAUDE_RESULT=empty)
[ "$(rows_with empty)" = 2 ] && [ "$e3" = 74 ] && [ "$(vendor_calls)" = 2 ] && ok \
  || bad "6 empty results: rows '$(cat "$ROWS" | cut -f5 | tr '\n' ' ')' rcs $e1 $e2 $e3 vendor $(vendor_calls)"

# --- 7. a call where NO rung ran settles unbilled and frees its slot ---------
reset
u1=$(call u1 review "no tools" CALL_GUARD_MAX_MAP="review=1" RUNNER_REVIEW=grok AGENT_CALL_NO_TOOLS=1)
[ "$(rows_with unbilled)" = 1 ] && ok || bad "7a a refused-at-the-rung call was not settled unbilled (rc=$u1): $(cat "$ROWS")"
u2=$(call u2 review "no tools" CALL_GUARD_MAX_MAP="review=1")
[ "$u2" = 0 ] && ok || bad "7b the unbilled call held the only slot (rc=$u2)"

# --- 8. METERED + unreadable counter -> refused; SUBSCRIPTION -> passes -------
for mode in down 500; do
  reset
  m=$(call m1 review "metered $mode" CG_FAKE=$mode ANTHROPIC_API_KEY=sk-ant-test CLAUDE_CODE_OAUTH_TOKEN=)
  [ "$m" = 74 ] && [ "$(vendor_calls)" = 0 ] && ok || bad "8a[$mode] metered + unreadable: rc=$m vendor=$(vendor_calls), want 74 and 0"
  head -1 "$T/m1" | grep -q '^AGENT_CALL_REFUSED call-guard counter-unreadable' && ok || bad "8b[$mode] marker: $(head -1 "$T/m1")"
  grep -q '\[call-guard\] COUNTER UNREADABLE \[testproj\] review' "$T/logs/ALERTS.log" && ok || bad "8c[$mode] no COUNTER UNREADABLE line"
  ( export HARNESS="$T"; . "$DIR/bin/lib/alert-state.sh" 2>/dev/null || exit 3
    alert_state_route "$(grep '\[call-guard\] COUNTER' "$T/logs/ALERTS.log" | tail -1)" critical ) > "$T/sev" 2>/dev/null
  [ "$(cat "$T/sev")" = warn ] && ok || bad "8f[$mode] the unreadable line routes to '$(cat "$T/sev")', want warn"
  s=$(call s1 review "subscription $mode" CG_FAKE=$mode)
  [ "$s" = 0 ] && [ "$(vendor_calls)" = 1 ] && ok || bad "8d[$mode] subscription + unreadable: rc=$s vendor=$(vendor_calls), want 0 and 1 (fail-open)"
done
reset
m=$(call m2 review "metered but knob off" CG_FAKE=down ANTHROPIC_API_KEY=sk-ant-test CLAUDE_CODE_OAUTH_TOKEN= CALL_GUARD_FAIL_CLOSED_METERED=0)
[ "$m" = 0 ] && ok || bad "8e CALL_GUARD_FAIL_CLOSED_METERED=0 still refused (rc=$m)"

# --- 9. a subscription primary that fails cannot DESCEND into unguarded cash --
reset
d=$(call dd review "descend" CG_FAKE=down CLAUDE_RESULT=fail OPENROUTER_API_KEY=sk-test OPENROUTER_FALLBACK=always)
grep -qx openrouter "$T/order" && bad "9a the metered OpenRouter rung ran with the counter unreadable (order: $(tr '\n' ' ' < "$T/order"))" || ok
grep -qx claude "$T/order" && ok || bad "9b the subscription primary did not run"
# ...and with the counter READABLE the same descent is one call, allowed once
reset
d=$(call dd2 review "descend readable" CLAUDE_RESULT=fail OPENROUTER_API_KEY=sk-test OPENROUTER_FALLBACK=always)
grep -qx openrouter "$T/order" && ok || bad "9c with a live counter the ladder no longer descends (order: $(tr '\n' ' ' < "$T/order"))"
[ "$(awk -F'\t' '$5!="refused"' "$ROWS" | grep -c .)" = 1 ] && ok || bad "9d one call claimed more than one slot: $(cat "$ROWS")"

# --- 10. knob = 0 disables, and so do the kill switches ----------------------
reset
for i in 1 2 3; do k[$i]=$(call "k$i" review "same" CALL_GUARD_MAX_MAP="review=0"); done
[ "${k[3]}" = 0 ] && [ "$(vendor_calls)" = 3 ] && [ ! -s "$T/cg.reqs" ] && ok \
  || bad "10a review=0 still guarded (rcs ${k[*]}, vendor $(vendor_calls), worker asked: $(wc -l < "$T/cg.reqs"))"
reset
touch "$T/flags/call-guard-off"
for i in 1 2 3; do k[$i]=$(call "k$i" review "same"); done
rm -f "$T/flags/call-guard-off"
[ "${k[3]}" = 0 ] && [ ! -s "$T/cg.reqs" ] && ok || bad "10b flags/call-guard-off did not disable it"
reset
for i in 1 2 3; do k[$i]=$(call "k$i" review "same" CALL_GUARD_STAGES=none); done
[ "${k[3]}" = 0 ] && [ ! -s "$T/cg.reqs" ] && ok || bad "10c CALL_GUARD_STAGES=none did not disable it"

# --- 11. the GUARD stage: triage and triage-shard are separate stages -------
# Plain triage is on by default since BH-2305 (K=2, keyed on `triage`); it is
# shared by alert-triage, the medic and the responder, and its fallback
# fingerprint only ever matches an identical prompt.
reset
for i in 1 2 3; do t[$i]=$(call "t$i" triage "triage TK-1673"); done
[ "${t[2]}" = 0 ] && [ "${t[3]}" = 74 ] && [ "$(awk -F'\t' '$3=="triage"' "$ROWS" | grep -c .)" = 3 ] && ok \
  || bad "11a plain triage default K=2 on its own guard stage: rcs ${t[*]}, rows $(cut -f3,5 "$ROWS" | tr '\n' ' ')"
reset
for i in 1 2 3; do t[$i]=$(call "t$i" triage "triage TK-1673 tick $i" AGENT_CALL_GUARD_STAGE=triage-shard AGENT_CALL_FP="TK-1673:0123456789abcdef"); done
[ "${t[1]}" = 0 ] && [ "${t[2]}" = 0 ] && [ "${t[3]}" = 74 ] && ok \
  || bad "11b triage-shard default K=2 on one board-state digest: rcs ${t[*]}"
awk -F'\t' '$3=="triage-shard"' "$ROWS" | grep -q . && ok || bad "11c rows are not keyed on the guard stage"

# --- 13. B1: the guard's per-call env NEVER reaches the vendor session ------
# The shard sets AGENT_CALL_FP / _GUARD_STAGE / _TICKET for agent-call.sh; a
# triage session that inherited them would hand them to every build it
# setsid-launches, and plan/execute would share the triage shard's slots.
for rn in claude grok codex; do
  reset
  r=$(call "lk-$rn" review "leak $rn" RUNNER_REVIEW=$rn CODEX_API_KEY=x AGENT_CALL_FP="TK-9:feedface" \
      AGENT_CALL_GUARD_STAGE=review AGENT_CALL_TICKET=TK-9 AGENT_CALL_GUARD_FORCE=0)
  grep -qx "$rn" "$T/order" && ok || bad "13a[$rn] the $rn lane did not run (rc=$r, order: $(tr '\n' ' ' < "$T/order"))"
  [ -s "$T/leak" ] && bad "13b[$rn] the vendor session inherited the guard's env: $(tr '\n' ' ' < "$T/leak")" || ok
done

# --- 14. a worker with NO call-guard route (404) is `unconfigured`: fail open --
# Deploy order: a box that syncs before the worker deploys must not refuse its
# metered lanes fleet-wide. 404 = the route is not there = one alert, run.
reset
m=$(call nr1 review "no route" CG_FAKE=404 ANTHROPIC_API_KEY=sk-ant-test CLAUDE_CODE_OAUTH_TOKEN=)
[ "$m" = 0 ] && [ "$(vendor_calls)" = 1 ] && ok || bad "14a metered + 404 refused (rc=$m vendor=$(vendor_calls)); a missing route is not an outage"
grep -q '\[call-guard\] ROUTE MISSING \[testproj\] review' "$T/logs/ALERTS.log" && ok || bad "14b no ROUTE MISSING line"
m=$(call nr2 review "no route 2" CG_FAKE=404 ANTHROPIC_API_KEY=sk-ant-test CLAUDE_CODE_OAUTH_TOKEN=)
[ "$(grep -c '\[call-guard\]' "$T/logs/ALERTS.log")" = 1 ] && ok || bad "14c ROUTE MISSING paged more than once a day"
( export HARNESS="$T"; . "$DIR/bin/lib/alert-state.sh" 2>/dev/null || exit 3
  alert_state_route "$(grep '\[call-guard\]' "$T/logs/ALERTS.log" | tail -1)" critical ) > "$T/sev" 2>/dev/null
[ "$(cat "$T/sev")" = warn ] && ok || bad "14d ROUTE MISSING routes to '$(cat "$T/sev")', want warn"

# --- 15. AGENT_CALL_GUARD_FORCE=1: a hand-run path gets its call, and it COUNTS -
reset
for i in 1 2; do call "f$i" review "forced" CALL_GUARD_MAX_MAP="review=1" >/dev/null; done
f=$(call f3 review "forced" CALL_GUARD_MAX_MAP="review=1" AGENT_CALL_GUARD_FORCE=1)
[ "$f" = 0 ] && [ "$(vendor_calls)" = 2 ] && ok || bad "15a FORCE did not override the ceiling (rc=$f vendor=$(vendor_calls))"
[ "$(awk -F'\t' '$5=="ok"' "$ROWS" | grep -c .)" = 2 ] && ok || bad "15b the forced call was not recorded as paid: $(cut -f5 "$ROWS" | tr '\n' ' ')"
grep -q 'FORCED' "$T/logs/call-guard.log" && ok || bad "15c a forced call left no call-guard.log line"

# --- 16. the operator's reset verb: DELETE /api/call-guard for ONE piece of work
: > "$T/cg.reqs.reset"
( export PATH="$T/fakebin:$PATH" HARNESS="$T" CG_ROWS="$ROWS" CG_REQS="$T/cg.reqs" CG_FAKE=up \
         JOBS_URL="https://jobs.test" HARNESS_SECRET="test-secret" JOBS_RETRIES=0 JOBS_BOX=testbox
  bash "$T/bin/jobs-client.sh" call-guard-reset testproj review "review-prs:acme/app#229@553a9e0" "hand retry" ) > "$T/reset.out" 2>&1
grep -q '"reset":2' "$T/reset.out" && ok || bad "16a call-guard-reset did not return the worker's answer: $(cat "$T/reset.out")"
grep -qx 'DELETE ?project=testproj&stage=review&fp=review-prs%3Aacme%2Fapp%23229%40553a9e0&actor=testbox&reason=hand%20retry' "$T/cg.reqs.reset" \
  && ok || bad "16b the reset was not a DELETE naming project, stage, fp, actor and reason: $(cat "$T/cg.reqs.reset")"

# --- 17. a SUBSCRIPTION failure that billed nothing does not count ---------
# The re-review's #1621 repro: two 429/session-limit failures on a subscription
# account cost nothing, so they must not use up the head's slots — the third
# call, once the account is back, RUNS.
reset
l1=$(call l1 review "limited head" CALL_GUARD_MAX_MAP="review=2" CLAUDE_RESULT=limit)
l2=$(call l2 review "limited head" CALL_GUARD_MAX_MAP="review=2" CLAUDE_RESULT=limit)
l3=$(call l3 review "limited head" CALL_GUARD_MAX_MAP="review=2")
[ "$l1" != 0 ] && [ "$l2" != 0 ] && ok || bad "17a precondition: the limited calls must fail (rc $l1 $l2)"
[ "$(rows_with unbilled)" = 2 ] && ok || bad "17b a subscription quota failure was settled as paid: $(cut -f5 "$ROWS" | tr '\n' ' ')"
[ "$l3" = 0 ] && [ "$(tail -1 "$T/order")" = claude ] && ok || bad "17c the recovered third call was refused (rc=$l3)"
# ...but a REAL failure (the vendor ran and failed) still counts
reset
call rf1 review "real fail" CALL_GUARD_MAX_MAP="review=2" CLAUDE_RESULT=fail >/dev/null
call rf2 review "real fail" CALL_GUARD_MAX_MAP="review=2" CLAUDE_RESULT=fail >/dev/null
rf3=$(call rf3 review "real fail" CALL_GUARD_MAX_MAP="review=2")
[ "$(rows_with failed)" = 2 ] && [ "$rf3" = 74 ] && ok || bad "17d real failures must still count (rows $(cut -f5 "$ROWS" | tr '\n' ' '), rc=$rf3)"
# ...and a METERED quota failure is not assumed free
reset
call ml1 review "metered limit" CALL_GUARD_MAX_MAP="review=1" CLAUDE_RESULT=limit ANTHROPIC_API_KEY=sk-ant-test CLAUDE_CODE_OAUTH_TOKEN= >/dev/null
[ "$(rows_with failed)" = 1 ] && ok || bad "17e a METERED failure was settled unbilled: $(cut -f5 "$ROWS" | tr '\n' ' ')"

# --- 18. the conductor's own guard stage: mc-rereview, K=5 by default --------
reset
for i in 1 2 3 4 5 6; do mr[$i]=$(call "mr$i" review "mc head" AGENT_CALL_GUARD_STAGE=mc-rereview AGENT_CALL_FP="mc-rereview:o/r#1@abc1234"); done
[ "${mr[5]}" = 0 ] && [ "${mr[6]}" = 74 ] && ok || bad "18a mc-rereview default K=5: rcs ${mr[*]}"
awk -F'\t' '$3=="mc-rereview"' "$ROWS" | grep -q . && ok || bad "18b rows not keyed on mc-rereview"

# --- 19. an LLM session cannot FORCE its own calls through (IS_SANDBOX=1) -----
reset
call sb1 review "sandbox force" CALL_GUARD_MAX_MAP="review=1" >/dev/null
sb=$(call sb2 review "sandbox force" CALL_GUARD_MAX_MAP="review=1" AGENT_CALL_GUARD_FORCE=1 IS_SANDBOX=1)
[ "$sb" = 74 ] && [ "$(vendor_calls)" = 1 ] && ok || bad "19a FORCE was honoured inside a sandboxed session (rc=$sb vendor=$(vendor_calls))"
grep -q 'FORCE ignored' "$T/logs/call-guard.log" && ok || bad "19b the ignored FORCE left no call-guard.log line"

# --- 12. bin/triage-shard.sh hands agent-call its family and its key --------
# The REAL shard script, with agent-call stubbed to record what it was handed.
# The key is the ticket plus the board-state digest the dispatcher stamped
# (BH-1015's state/triage-shards/<p>/<KEY>.fp), and a call-guard refusal is the
# guard working: no per-tick ALERTS line, and the stamp stays.
S="$T/shard"; mkdir -p "$S/bin/lib" "$S/logs" "$S/locks" "$S/state/triage-shards/testproj" "$S/env"
cp "$DIR/bin/triage-shard.sh" "$S/bin/triage-shard.sh"
cp "$DIR/bin/lib/triage-shards-lib.sh" "$DIR/bin/lib/lock-hygiene.sh" "$DIR/bin/lib/env-path.sh" "$S/bin/lib/"
printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$S/bin/triage-contract.sh"
printf '#!/bin/sh\nexit 0\n' > "$S/bin/decision-log.sh"
printf '#!/bin/sh\nexit 0\n' > "$S/bin/beat.sh"
cat > "$S/bin/agent-call.sh" <<'STUB'
#!/bin/bash
printf 'fp=%s stage=%s ticket=%s\n' "${AGENT_CALL_FP:-}" "${AGENT_CALL_GUARD_STAGE:-}" "${AGENT_CALL_TICKET:-}" >> "$SHARD_SINK"
case "${SHARD_AC:-ok}" in
  refused) printf 'AGENT_CALL_REFUSED call-guard repeat triage-shard paid=2/2 fp=%s\n' "${AGENT_CALL_FP:-}" > "$5"; exit 74 ;;
  unreadable) printf 'AGENT_CALL_REFUSED call-guard counter-unreadable metered claude\n' > "$5"; exit 74 ;;
  fail)    echo "vendor died" > "$5"; exit 1 ;;
esac
echo "tickets=1 done" > "$5"
STUB
chmod +x "$S/bin/"*.sh
printf 'dummy prompt' > "$S/prompt.txt"
FPF="$S/state/triage-shards/testproj/TK-1.fp"
shard() { # shard <mode>
  printf '0123456789abcdef\n1\n' > "$FPF"; : > "$S/logs/ALERTS.log"; : > "$S/logs/testproj.log"; : > "$T/shard.sink"
  ( export HARNESS="$S" SHARD_SINK="$T/shard.sink" SHARD_AC="$1" TSH_MODEL=claude-fable-5-1 TSH_RUNNER=claude PATH="$T/fakebin:$PATH"
    bash "$S/bin/triage-shard.sh" testproj TK-1 "$S/prompt.txt" >/dev/null 2>&1 )
}
shard ok
[ "$(cat "$T/shard.sink")" = "fp=TK-1:0123456789abcdef stage=triage-shard ticket=TK-1" ] && ok \
  || bad "12a the shard handed agent-call '$(cat "$T/shard.sink")'"
shard refused
grep -q 'triage shard exited rc=74' "$S/logs/ALERTS.log" && bad "12b a call-guard refusal paged as a dead shard" || ok
[ -s "$FPF" ] && ok || bad "12c a REPEAT refusal took the stamp back — this world was already bought today, and clearing the stamp re-offers the ticket every tick for 24h"
grep -q 'call-guard refused before the call' "$S/logs/testproj.log" && ok || bad "12d the refusal left no line in the project log"
shard unreadable
grep -q 'triage shard exited rc=74' "$S/logs/ALERTS.log" && bad "12h a counter-unreadable refusal paged per shard per tick" || ok
[ -e "$FPF" ] && bad "12i a counter-unreadable refusal kept the stamp" || ok
grep -q 'call-guard refused before the call' "$S/logs/testproj.log" && ok || bad "12j the unreadable refusal left no project-log line"
shard fail
grep -q 'triage shard exited rc=1' "$S/logs/ALERTS.log" && ok || bad "12e a REAL shard failure no longer pages (the refusal arm is too wide)"
[ -e "$FPF" ] && bad "12f a real failure kept the stamp" || ok
rm -f "$FPF"; : > "$T/shard.sink"
( export HARNESS="$S" SHARD_SINK="$T/shard.sink" SHARD_AC=ok TSH_MODEL=claude-fable-5-1 TSH_RUNNER=claude PATH="$T/fakebin:$PATH"
  bash "$S/bin/triage-shard.sh" testproj TK-1 "$S/prompt.txt" >/dev/null 2>&1 )
[ "$(cat "$T/shard.sink")" = "fp= stage=triage-shard ticket=TK-1" ] && ok \
  || bad "12g a hand-launched shard (no stamp) must fall back to agent-call's own key: '$(cat "$T/shard.sink")'"

echo "agent-call-call-guard: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
