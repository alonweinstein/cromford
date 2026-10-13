#!/bin/bash
# tests/preplan-delta.bh-3495-test.sh — a split child's pre-plan starts warm
# (BH-3478.3, AC1; the ticket body calls this suite preplan-delta.bh-3478-test.sh,
# it is named for its own key).
#
# D: the REAL bin/run-preplan.sh, end to end, against a scratch $HARNESS (the
#    pattern of tests/run-preplan-prompt.bh-580-test.sh). The real jobs client,
#    context-pack lib, child-plan lib and model-route resolver all run; only
#    curl is fake (it answers /api/context-packs, /api/settings and
#    /api/model-routes) and bin/agent-call.sh is a stub that records the model,
#    the prompt and the two env knobs it was handed.
# N: the REAL bin/agent-call.sh preplan with a stub claude on PATH (the pattern
#    of tests/context-kill-lanes.bh-2309-test.sh), for the `delta` note tag.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/preplan-delta.bh-3495-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/model-route-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# =============================================================================
# D. bin/run-preplan.sh
# =============================================================================
mkdir -p "$T/bin/lib/jobs" "$T/env" "$T/flags" "$T/logs" "$T/plans" "$T/locks" "$T/repos/proj" "$T/fakebin" "$T/mrsbin" "$T/rec"
cp "$DIR/bin/run-preplan.sh" "$T/bin/"
cp "$DIR/bin/lib/preplan-lib.sh" "$DIR/bin/lib/test-home-lib.sh" "$DIR/bin/lib/lane-model.sh" \
   "$DIR/bin/lib/model-route.sh" "$T/bin/lib/"
cp "$DIR/bin/lib/context-pack.sh" "$T/bin/lib/context-pack.sh" || { echo "FAIL: bin/lib/context-pack.sh missing"; exit 1; }
cp "$DIR/bin/lib/child-plan.sh" "$T/bin/lib/child-plan.sh" 2>/dev/null || echo "FAIL: bin/lib/child-plan.sh missing"
cp "$DIR/bin/jobs-client.sh" "$T/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.invalid\nJOBS_RETRY_SLEEP=0\n' > "$T/env/global.env"

# The routes the worker answers: fake model names only.
mrs_install "$T/mrsbin"
mrs_route "$T/routes" plan model-plan-a:claude
mrs_route "$T/routes" stage.plan.child model-child-a:claude

# One fake curl for the three endpoints this lane reads. CP_FIX: `404`, `down`
# (transport failure) or a file whose JSON is a 200 answer. SET_FIX: empty = 404,
# anything else is the setting's value.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"
case "$URL" in
  */api/context-packs*)
    printf '%s\n' "$URL" >> "$T/rec/cp-urls"
    case "${CP_FIX:-404}" in
      404)  printf '{"error":"not found"}\n404\n' ;;
      down) exit 7 ;;
      *)    cat "$CP_FIX"; printf '\n200\n' ;;
    esac ;;
  */api/settings/child_preplan_delta_tokens)
    if [ -n "${SET_FIX:-}" ]; then
      printf '{"setting":{"key":"child_preplan_delta_tokens","value":"%s"}}\n200\n' "$SET_FIX"
    else printf '{"error":"not found"}\n404\n'; fi ;;
  *) exec "$T/mrsbin/curl" "$@" ;;
esac
EOF
chmod +x "$T/fakebin/curl"

cat > "$T/bin/agent-call.sh" <<'STUB'
#!/bin/bash
# agent-call.sh <stage> <project> <model> <timeout> <outfile> <prompt>
printf '%s' "$3" > "$T/rec/model"
printf '%s' "$6" > "$T/rec/prompt"
env | grep -E '^(AGENT_CALL_ROW_NOTE|CONTEXT_KILL_TOKENS)=' | sort > "$T/rec/env"
exit 0
STUB
chmod +x "$T/bin/agent-call.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/git"; chmod +x "$T/bin/git"
export PATH="$T/fakebin:$T/bin:$PATH" T MRS_ROUTES="$T/routes"

pack() { # pack <parent> <file> -> a 200 context-pack answer for proj/AB-1
  jq -n --arg p "$1" '{context_pack:{project:"proj",ticket_key:"AB-1",parent_key:$p,pack_md:"## parent map\nbin/x.sh does the thing\n",bytes:40}}' > "$2"
}
lane() { # lane [VAR=val ...] -> rc of the real bin/run-preplan.sh for proj AB-1
  rm -rf "$T/plans" "$T/rec"; mkdir -p "$T/plans" "$T/rec"
  : > "$T/logs/preplan.log"; : > "$T/logs/ALERTS.log"
  env -u PLAN_MODEL -u PLAN_MODEL_CHILD -u CONTEXT_KILL_TOKENS -u AGENT_CALL_ROW_NOTE \
    HARNESS="$T" REPOS_ROOT="$T/repos" "$@" bash "$T/bin/run-preplan.sh" proj 1 AB-1 >/dev/null 2>&1
}
has_log() { grep -qF -- "$1" "$T/logs/preplan.log"; }

# --- baseline: a box with no context-pack lib at all (today's lane) ----------
mv "$T/bin/lib/context-pack.sh" "$T/cp-parked.sh"
lane; RC=$?
[ "$RC" = 0 ] && ok || bad "baseline: lane rc $RC"
cp "$T/rec/prompt" "$T/baseline.prompt" 2>/dev/null
[ -s "$T/baseline.prompt" ] && ok || bad "baseline: the lane never reached agent-call.sh"
[ "$(cat "$T/rec/model" 2>/dev/null)" = model-plan-a ] && ok || bad "baseline: model $(cat "$T/rec/model" 2>/dev/null), want model-plan-a"
mv "$T/cp-parked.sh" "$T/bin/lib/context-pack.sh"

# --- D1: a child, setting 120000 ---------------------------------------------
pack BH-9000 "$T/pack.json"
lane CP_FIX="$T/pack.json" SET_FIX=120000; RC=$?
[ "$RC" = 0 ] && ok || bad "D1: lane rc $RC"
P=$(cat "$T/rec/prompt" 2>/dev/null)
case "$P" in "WARM START"*) ok ;; *) bad "D1: prompt does not start with WARM START: $(head -c 80 <<<"$P")" ;; esac
grep -qF 'split child of BH-9000' <<<"$P" && ok || bad "D1: prompt does not name the parent BH-9000"
grep -qF 'bin/x.sh does the thing' <<<"$P" && ok || bad "D1: prompt does not embed the pack"
grep -qF "$(cat "$T/baseline.prompt")" <<<"$P" && ok || bad "D1: the baseline prompt does not follow the preamble intact"
[ "$(cat "$T/rec/model")" = model-child-a ] && ok || bad "D1: model $(cat "$T/rec/model"), want model-child-a"
grep -qx 'AGENT_CALL_ROW_NOTE=delta' "$T/rec/env" && ok || bad "D1: env lacks AGENT_CALL_ROW_NOTE=delta: $(tr '\n' ' ' < "$T/rec/env")"
grep -qx 'CONTEXT_KILL_TOKENS=120000' "$T/rec/env" && ok || bad "D1: env lacks CONTEXT_KILL_TOKENS=120000: $(tr '\n' ' ' < "$T/rec/env")"
has_log 'pre-plan delta: parent=BH-9000 model=model-child-a token cap=120000 (setting child_preplan_delta_tokens)' && ok \
  || bad "D1: preplan.log lacks the delta line: $(cat "$T/logs/preplan.log")"
grep -qF 'key=AB-1' "$T/rec/cp-urls" 2>/dev/null && grep -qF 'project=proj' "$T/rec/cp-urls" && ok \
  || bad "D1: the pack was not fetched for proj/AB-1: $(cat "$T/rec/cp-urls" 2>/dev/null)"

# --- D2: no pack (404) -> byte-identical to the baseline ---------------------
lane CP_FIX=404 SET_FIX=120000; RC=$?
[ "$RC" = 0 ] && ok || bad "D2: lane rc $RC"
cmp -s "$T/rec/prompt" "$T/baseline.prompt" && ok || bad "D2: prompt differs from the no-lib baseline"
[ -s "$T/rec/env" ] && bad "D2: env carries $(tr '\n' ' ' < "$T/rec/env")" || ok
[ "$(cat "$T/rec/model")" = model-plan-a ] && ok || bad "D2: model $(cat "$T/rec/model"), want model-plan-a"
has_log '[proj/AB-1] no context pack' && ok || bad "D2: preplan.log lacks 'no context pack': $(cat "$T/logs/preplan.log")"
has_log 'pre-plan delta' && bad "D2: a delta line was logged with no pack" || ok

# --- D3: the pack GET is down -> today's path, one line, no page --------------
lane CP_FIX=down SET_FIX=120000; RC=$?
[ "$RC" = 0 ] && ok || bad "D3: lane rc $RC"
cmp -s "$T/rec/prompt" "$T/baseline.prompt" && ok || bad "D3: prompt differs from the no-lib baseline"
[ -s "$T/rec/env" ] && bad "D3: env carries $(tr '\n' ' ' < "$T/rec/env")" || ok
[ "$(cat "$T/rec/model")" = model-plan-a ] && ok || bad "D3: model $(cat "$T/rec/model"), want model-plan-a"
has_log 'context pack unreachable — full pre-plan' && ok || bad "D3: preplan.log lacks the unreachable line: $(cat "$T/logs/preplan.log")"
[ -s "$T/logs/ALERTS.log" ] && bad "D3: ALERTS.log written: $(cat "$T/logs/ALERTS.log")" || ok

# --- D4: pack present, no setting row -> 150000 and the log says why ----------
lane CP_FIX="$T/pack.json"; RC=$?
[ "$RC" = 0 ] && ok || bad "D4: lane rc $RC"
grep -qx 'CONTEXT_KILL_TOKENS=150000' "$T/rec/env" && ok || bad "D4: env lacks CONTEXT_KILL_TOKENS=150000: $(tr '\n' ' ' < "$T/rec/env")"
has_log 'token cap=150000 (fallback 150000 (no row))' && ok || bad "D4: log does not name the no-row fallback: $(cat "$T/logs/preplan.log")"
# D4b: a value that is not a positive integer
for v in abc 0 -5 1e5; do
  lane CP_FIX="$T/pack.json" SET_FIX="$v"
  grep -qx 'CONTEXT_KILL_TOKENS=150000' "$T/rec/env" && ok || bad "D4b[$v]: env lacks CONTEXT_KILL_TOKENS=150000: $(tr '\n' ' ' < "$T/rec/env")"
  has_log 'token cap=150000 (fallback 150000 (not a positive integer))' && ok || bad "D4b[$v]: log does not name the bad value: $(cat "$T/logs/preplan.log")"
done
lane CP_FIX="$T/pack.json" SET_FIX=0090000
grep -qx 'CONTEXT_KILL_TOKENS=90000' "$T/rec/env" && ok || bad "D4c: leading zeros not normalized: $(tr '\n' ' ' < "$T/rec/env")"

# --- D5: a self-parent row is not a child ------------------------------------
pack AB-1 "$T/self.json"
lane CP_FIX="$T/self.json" SET_FIX=120000
cmp -s "$T/rec/prompt" "$T/baseline.prompt" && ok || bad "D5: self-parent row changed the prompt"
[ -s "$T/rec/env" ] && bad "D5: self-parent row set $(tr '\n' ' ' < "$T/rec/env")" || ok
has_log 'no context pack' && ok || bad "D5: self-parent row not logged as 'no context pack'"

# --- D6: PLAN_MODEL_CHILD pins the child model -------------------------------
lane CP_FIX="$T/pack.json" SET_FIX=120000 PLAN_MODEL_CHILD=model-env-z
[ "$(cat "$T/rec/model")" = model-env-z ] && ok || bad "D6: model $(cat "$T/rec/model"), want model-env-z"

# =============================================================================
# N. the REAL bin/agent-call.sh: the `delta` tag on the cost row
# =============================================================================
N="$T/n"; mkdir -p "$N/logs" "$N/locks" "$N/flags" "$N/state/model-routes" "$N/bin" "$N/fakebin" "$N/noenv" "$N/.claude/projects/-work"
cat > "$N/fakebin/claude" <<'EOF'
#!/bin/bash
sid=""; prev=""
for a in "$@"; do
  case "$prev" in --session-id|--resume) sid="$a" ;; esac
  prev="$a"
done
printf '{"result":"PLAN","usage":{"input_tokens":50,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"session_id":"%s","total_cost_usd":0.01}\n' "$sid"
EOF
cat > "$N/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
chmod +x "$N/fakebin/claude" "$N/fakebin/timeout"
printf '#!/bin/bash\necho subscription\n' > "$N/bin/billing-mode.sh"; chmod +x "$N/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$N/bin/beat.sh"; chmod +x "$N/bin/beat.sh"
for key in claude.ladder claude.ladder@proj; do
  printf '0\tmodel-x\tclaude\n' > "$N/state/model-routes/$key.tsv"
done
call() { # call [VAR=val ...] -> the last preplan cost row
  ( export PATH="$N/fakebin:$PATH" HARNESS="$N" HOME="$N" HARNESS_ENV_DIR="$N/noenv"
    unset HARNESS_SECRET JOBS_URL CONTEXT_KILL CONTEXT_KILL_TOKENS AGENT_CALL_ROW_NOTE AGENT_CALL_TICKET
    env "$@" bash "$DIR/bin/agent-call.sh" preplan proj model-x 60 "$N/out.txt" "hello" >/dev/null 2>&1 )
  grep ',preplan,claude,' "$N/logs/cost.csv" 2>/dev/null | tail -1
}
col() { python3 -c 'import csv,sys; r=list(csv.reader([sys.argv[1]]))[0]; print(r[int(sys.argv[2])] if len(r)>int(sys.argv[2]) else "")' "$1" "$2"; }
# The note minus the tag, and the row minus ts/duration/session: what must not move.
strip() { python3 -c '
import csv,sys,io
r=list(csv.reader([sys.argv[1]]))[0]
if len(r)>23: r[23]=";".join(t for t in r[23].split(";") if t and t!="delta")
for i in (0,7,16): r[i]=""
o=io.StringIO(); csv.writer(o,lineterminator="").writerow(r); print(o.getvalue())' "$1"; }

R1=$(call AGENT_CALL_ROW_NOTE=delta AGENT_CALL_TICKET=BH-9001)
[ -n "$R1" ] && ok || bad "N1: agent-call wrote no preplan cost row ($(tail -3 "$N/logs/cost.csv" 2>/dev/null))"
tr ';' '\n' <<<"$(col "$R1" 23)" | grep -qx delta && ok || bad "N1: note [$(col "$R1" 23)] has no delta token"
[ "$(col "$R1" 19)" = BH-9001 ] && ok || bad "N1: ticket column [$(col "$R1" 19)], want BH-9001"
[ "$(col "$R1" 3)" = preplan ] && ok || bad "N1: stage column [$(col "$R1" 3)], want preplan"
R2=$(call AGENT_CALL_TICKET=BH-9001)
grep -qx delta <<<"$(tr ';' '\n' <<<"$(col "$R2" 23)")" && bad "N2: unset tag still wrote delta: [$(col "$R2" 23)]" || ok
[ -n "$R2" ] && [ "$(strip "$R1")" = "$(strip "$R2")" ] && ok \
  || bad "N2: rows differ beyond the tag:
  $(strip "$R1")
  $(strip "$R2")"
R3=$(call AGENT_CALL_ROW_NOTE="Delta X;$(printf 'a%.0s' $(seq 1 70))")
T3=$(tr ';' '\n' <<<"$(col "$R3" 23)" | grep '^elta' | head -1)
[[ "$T3" =~ ^[a-z0-9=:._-]{1,64}$ ]] && [ "${#T3}" = 64 ] && ok || bad "N3: tag [$T3] not sanitized and capped at 64"
R4=$(call 'AGENT_CALL_ROW_NOTE=;;;')
[ "$(col "$R4" 23)" = "$(col "$R2" 23)" ] && ok || bad "N4: a tag that sanitizes to nothing changed the note: [$(col "$R4" 23)]"

echo "preplan-delta.bh-3495: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
