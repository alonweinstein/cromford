#!/bin/bash
# tests/participant-cost-row.bh-5352-test.sh — BH-5352: a participant machine's
# cost rows name the machine and its enrollment's billing account.
#   C1  HARNESS_PARTICIPANT_TOKEN_FILE readable, whoami + the approved list
#       answer: cost.csv field 16 (auth_account) is the billing_account, field 13
#       (usd) is set, field 6 is the model the route cache served (the same as a
#       non-participant call), and the note carries participant=<name>.
#   C1b the list has no billing_account for this machine: the account is
#       today's, the note says participant_billing=unresolved.
#   C2  whoami answers 403: today's account, note participant=unresolved, the
#       call's rc unchanged.
#   C3  _cost_row_emit_body with COST_ROW_PARTICIPANT carries `participant`, and
#       that body applied through POST /api/metrics/cost-rows lands it in
#       cost_rows; a junk name is left out; the mirror-first fill adds it.
#   C4  no token file: no participant call is made and the row is today's.
#   S   the token never reaches curl's argv nor cost.csv; no merge call.
# Drives the real bin/agent-call.sh against a fake claude CLI and the model
# route box cache (tests/lib/model-route-stub.sh).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/participant-cost-row.bh-5352-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset HARNESS_ENV_DIR ACCOUNTS_DIR COST_ROW_PARTICIPANT HARNESS_PARTICIPANT_TOKEN_FILE

PTOK=participant-secret-5352
mkdir -p "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state" "$T/env/accounts.d" "$T/tok" "$T/tmp"
scratch_install_closure bin/agent-call.sh "$T" >/dev/null || { echo "FAIL: closure of bin/agent-call.sh"; exit 1; }
scratch_install_closure bin/jobs-client.sh "$T" >/dev/null || { echo "FAIL: closure of bin/jobs-client.sh"; exit 1; }
mrs_fixture "$T" testproj
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
printf '#!/bin/bash\necho "test rules"\n' > "$T/bin/sync-agent-rules.sh"
echo '{}' > "$T/empty-catalog.json"
printf '%s\n' "$PTOK" > "$T/tok/participant"; chmod 600 "$T/tok/participant"

cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
echo '{"result":"the text","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}'
exit 0
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
# The stub worker: whoami and the approved list, shaped by $PC_WHOAMI
# (ok | 403) and $PC_LIST (ok | nobilling). Every other URL is a transport
# failure, so the model-route resolver answers from the box cache.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$PC_ARGV"
url="" hdr=""
while [ $# -gt 0 ]; do
  case "$1" in
    -H) case "$2" in @*) hdr="${2#@}" ;; esac; shift 2 ;;
    --data-binary|-X|-m|--connect-timeout|-w) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in */api/participants*) ;; *) exit 7 ;; esac
printf '%s\n' "$url" >> "$PC_CALLS"
[ -n "$hdr" ] && grep -q '^x-participant-token: participant-secret-5352$' "$hdr" && echo tokhdr >> "$PC_CALLS"
case "$url" in
  */api/participants/whoami)
    if [ "${PC_WHOAMI:-ok}" = ok ]; then printf '{"id":"p1","name":"mac-test-1","status":"approved","granted_roles":["lead-review"],"knobs":{}}\n200'
    else printf '{"error":"unknown participant token"}\n403'; fi ;;
  */api/participants\?status=approved)
    if [ "${PC_LIST:-ok}" = ok ]; then printf '{"participants":[{"id":"p0","billing_account":"acct-z"},{"id":"p1","billing_account":"acct-a"}],"truncated":false}\n200'
    else printf '{"participants":[{"id":"p1","billing_account":null}],"truncated":false}\n200'; fi ;;
  *) printf '{"error":"unknown endpoint"}\n404' ;;
esac
EOF
chmod +x "$T/fakebin/"* "$T/bin/"*.sh

reset() { rm -f "$T/logs/cost.csv" "$T/calls" "$T/argv"; rm -rf "$T/state/agent-call-ledger"; }
# call <out> [VAR=VAL ...] -> prints the rc
call() {
  local out="$1"; shift
  ( unset AGENT_CALL_FP AGENT_CALL_GUARD_STAGE AGENT_CALL_TICKET HARNESS_TICKET JOB_ID GROK_MODEL CODEX_MODEL FIREWORKS_MODEL
    export PC_ARGV="$T/argv" PC_CALLS="$T/calls" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" TMPDIR="$T/tmp" \
           JOBS_URL="https://jobs.test" HARNESS_SECRET="test-secret" JOBS_RETRIES=0 JOBS_BOX=testbox \
           CLAUDE_CODE_OAUTH_TOKEN=tok-fixture ANTHROPIC_API_KEY= \
           OPENROUTER_API_KEY= FIREWORKS_API_KEY= CODEX_API_KEY= OPENAI_API_KEY= ACCOUNT_ROUTING=0 \
           AUTH_ACCOUNTS_CATALOG="$T/empty-catalog.json" AUTH_ACCOUNTS_LOCAL="$T/state/auth-accounts.local.json" \
           LADDER_TIER2_GROK=0 LADDER_BACKOFF_SECS=0 LADDER_SAME_RETRIES=0 \
           AGENT_CALL_RUNNERS= AGENT_CALL_LEDGER=0 CALL_GUARD=0 \
           RUNNER_TRIAGE=claude RUNNER_TRIAGE_FALLBACK= LANE_GATE_DISABLE=1 LLM_GATE_DISABLE=1 \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" "$@"
    cd "$T" && bash "$T/bin/agent-call.sh" triage testproj claude-opus-5-5 60 "$out" "the prompt" >/dev/null 2>&1 )
  echo $?
}
lastrow() { awk -F, 'NR>1 && $5=="claude" {l=$0} END{print l}' "$T/logs/cost.csv" 2>/dev/null; }
fld() { printf '%s' "$1" | cut -d, -f"$2"; }

# C4 first: the baseline every other case is compared with.
reset
rc=$(call "$T/o4")
R4=$(lastrow)
[ "$rc" = 0 ] && [ -n "$R4" ] && ok || bad "C4 a plain call writes a row (rc $rc): $R4"
[ ! -s "$T/calls" ] && ok || bad "C4 no token file: no participant call is made: $(cat "$T/calls")"
case "$(fld "$R4" 24)" in *participant*) bad "C4 no participant token in the note: $(fld "$R4" 24)" ;; *) ok ;; esac
[ "$(fld "$R4" 16)" != acct-a ] && ok || bad "C4 the baseline account is not the participant's"
[ "$(printf '%s' "$R4" | awk -F, '{print NF}')" = 26 ] && ok || bad "C4 the row is 26 fields: $R4"

# C1 participant mode
reset
rc=$(call "$T/o1" HARNESS_PARTICIPANT_TOKEN_FILE="$T/tok/participant")
R1=$(lastrow)
[ "$rc" = 0 ] && ok || bad "C1 the call's rc is 0 (got $rc)"
[ "$(fld "$R1" 16)" = acct-a ] && ok || bad "C1 field 16 is the billing account acct-a: $R1"
[ -n "$(fld "$R1" 13)" ] && [ "$(fld "$R1" 13)" = "$(fld "$R4" 13)" ] && ok || bad "C1 usd is set and priced as today ('$(fld "$R1" 13)' vs '$(fld "$R4" 13)')"
[ -n "$(fld "$R1" 6)" ] && [ "$(fld "$R1" 6)" = "$(fld "$R4" 6)" ] && ok || bad "C1 the model is the route's, unchanged ('$(fld "$R1" 6)' vs '$(fld "$R4" 6)')"
case ";$(fld "$R1" 24);" in *";participant=mac-test-1;"*) ok ;; *) bad "C1 the note carries participant=mac-test-1: '$(fld "$R1" 24)'" ;; esac
case "$(fld "$R1" 24)" in *participant_billing*) bad "C1 billing resolved, no unresolved note" ;; *) ok ;; esac
grep -c 'api/participants/whoami' "$T/calls" | grep -qx 1 && ok || bad "C1 one whoami call: $(cat "$T/calls")"
grep -q 'tokhdr' "$T/calls" && ok || bad "C1 the token rode in the header file"
[ "$(printf '%s' "$R1" | awk -F, '{print NF}')" = 26 ] && ok || bad "C1 the row is still 26 fields: $R1"

# C1b no billing_account on the enrollment
reset
rc=$(call "$T/o1b" HARNESS_PARTICIPANT_TOKEN_FILE="$T/tok/participant" PC_LIST=nobilling)
R=$(lastrow)
[ "$rc" = 0 ] && [ "$(fld "$R" 16)" = "$(fld "$R4" 16)" ] && ok || bad "C1b no billing account keeps today's account (rc $rc): $R"
case ";$(fld "$R" 24);" in *";participant=mac-test-1;participant_billing=unresolved;"*) ok ;; *) bad "C1b the note says billing unresolved: '$(fld "$R" 24)'" ;; esac

# C2 whoami refuses
reset
rc=$(call "$T/o2" HARNESS_PARTICIPANT_TOKEN_FILE="$T/tok/participant" PC_WHOAMI=403)
R=$(lastrow)
[ "$rc" = 0 ] && ok || bad "C2 the call's rc is unchanged (got $rc)"
[ "$(fld "$R" 16)" = "$(fld "$R4" 16)" ] && ok || bad "C2 today's account: $R"
case ";$(fld "$R" 24);" in *";participant=unresolved;"*) ok ;; *) bad "C2 the note says participant=unresolved: '$(fld "$R" 24)'" ;; esac
grep -q 'status=approved' "$T/calls" && bad "C2 no list read after a refused whoami" || ok

# S no secret anywhere it can leak
grep -qF "$PTOK" "$T/argv" 2>/dev/null && bad "S1 the token reached curl's argv" || ok
grep -qF "$PTOK" "$T/logs/cost.csv" 2>/dev/null && bad "S2 the token reached cost.csv" || ok
grep -qE '/merge' "$T/argv" 2>/dev/null && bad "S3 a merge call was made" || ok

# C3 the emitted body, and the worker route that stores it. The emitter never
# posts the testproj fixture (BH-3223), so the row is relabelled first.
R1=$(printf '%s' "$R1" | awk -F, -v OFS=, '{$3="cromford"; print}')
B=$(mktemp "$T/tmp/body.XXXXXX")
( . "$T/bin/lib/cost-row.sh"; COST_ROW_PARTICIPANT=mac-test-1 COST_ROWS_ALLOW= _cost_row_emit_body "$R1" b1 1 ) > "$B"
[ "$(jq -r '.rows[0].participant' "$B")" = mac-test-1 ] && ok || bad "C3 the body carries participant: $(cat "$B")"
[ "$(jq -r '.rows[0].auth_account' "$B")" = acct-a ] && ok || bad "C3 the body carries auth_account acct-a"
J=$(mktemp "$T/tmp/body.XXXXXX")
( . "$T/bin/lib/cost-row.sh"; COST_ROW_PARTICIPANT='Bad Name;' COST_ROWS_ALLOW= _cost_row_emit_body "$R1" b1 1 ) > "$J"
[ "$(jq -r '.rows[0] | has("participant")' "$J")" = false ] && ok || bad "C3 a junk participant name is left out"
M=$(mktemp "$T/tmp/body.XXXXXX")
( . "$T/bin/lib/cost-row.sh"; unset COST_ROW_PARTICIPANT; COST_ROWS_ALLOW= _cost_row_emit_body "$R1" b1 1 ) > "$M"
[ "$(jq -r '.rows[0] | has("participant")' "$M")" = false ] && ok || bad "C3 no COST_ROW_PARTICIPANT, no key"
OUT=$(cd "$DIR/worker/jobs" && node --no-warnings --input-type=module - "$B" "$M" <<'EOF'
import { readFileSync } from 'node:fs';
import worker from './src/index.js';
import { openDb } from './test/lib/d1-sqlite.bh-1030.js';
const o = await openDb();
if (!o) { console.log('NO-SQLITE'); process.exit(0); }
const post = (b) => worker.fetch(new Request('https://jobs.test/api/metrics/cost-rows', {
  method: 'POST', headers: { authorization: 'Bearer s', 'content-type': 'application/json' }, body: b,
}), { DB: o.DB, HARNESS_SECRET: 's' }).then((r) => r.status);
const sel = () => o.db.prepare('SELECT participant, auth_account FROM cost_rows').all().map((r) => `${r.participant}|${r.auth_account}`).join(' ');
const at = readFileSync(process.argv[2], 'utf8'), mirror = readFileSync(process.argv[3], 'utf8');
const s1 = await post(at); const a = sel();
o.db.exec('DELETE FROM cost_rows');
const s2 = await post(mirror); const b = sel(); const s3 = await post(at); const c = sel();
console.log([s1, a, s2, b, s3, c].join(' / '));
EOF
)
[ "$OUT" = "200 / mac-test-1|acct-a / 200 / null|acct-a / 200 / mac-test-1|acct-a" ] && ok \
  || bad "C3 the route stores participant, and fills it after a mirror-first row (got '$OUT')"

echo "participant-cost-row.bh-5352: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
