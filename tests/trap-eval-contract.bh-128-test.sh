#!/bin/bash
# tests/trap-eval-contract.bh-128-test.sh — BH-128.0 (#1961): the shared
# contract the trap-eval split builds on.
#
# Sources the real bin/lib/trap-eval-cells.sh and runs the real bin/trap-eval.sh
# against a scratch harness, so nothing here can reach /root/harness or spend.
#   V1-V4  trap_eval_verdict: 0 -> pass, 1 -> fail, anything else -> null
#   V5     classify / oob_scan / report answer absent inputs as null / rc!=0
#   S1     the CLI with no --model exits 2 with its one refusal line (BH-128.1)
#   S2     the no-model CLI never invokes the agent-call seam and writes no cost row
#   C1-C2  the context-budgets lane and the llm-sites row, marker findable
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ---- V1-V5: the sourced cell API
. "$DIR/bin/lib/trap-eval-cells.sh" || { echo "FAIL: cannot source bin/lib/trap-eval-cells.sh"; exit 1; }
[ "$(trap_eval_verdict 0)" = pass ] && ok || bad "V1 verdict 0 = '$(trap_eval_verdict 0)', want pass"
[ "$(trap_eval_verdict 1)" = fail ] && ok || bad "V2 verdict 1 = '$(trap_eval_verdict 1)', want fail"
[ "$(trap_eval_verdict 2)" = null ] && ok || bad "V3 verdict 2 = '$(trap_eval_verdict 2)', want null"
[ "$(trap_eval_verdict 127)" = null ] && ok || bad "V4 verdict 127 = '$(trap_eval_verdict 127)', want null"
[ "$(trap_eval_verdict '')" = null ] && ok || bad "V4 verdict '' = '$(trap_eval_verdict '')', want null"
[ "$(trap_eval_verdict)" = null ] && ok || bad "V4 verdict (no arg) = '$(trap_eval_verdict)', want null"

case "$(trap_eval_classify "$T/none" "$T/none.csv" X claude)" in
  null:*) ok ;; *) bad "V5 classify on a missing out file did not print null:" ;; esac
out=$(trap_eval_oob_scan "$T/no-sentinel" "$T" 2>/dev/null); rc=$?
[ "$rc" -ne 0 ] && [ -z "$out" ] && ok || bad "V5 oob_scan rc=$rc out='$out', want rc!=0 and empty on a missing sentinel"
trap_eval_report "$T/none.jsonl" "$T/s.json" "$T/r.json" '' >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$T/s.json" ] && ok || bad "V5 report rc=$rc on missing cells, or it wrote $T/s.json"

# ---- S1: no --model is a refusal, rc 2 and one stderr line (BH-128.1 replaced the stub)
mkdir -p "$T/h"
HARNESS="$T/h" "$DIR/bin/trap-eval.sh" >"$T/s1.out" 2>"$T/s1.err"; rc=$?
[ "$rc" -eq 2 ] && ok || bad "S1 bin/trap-eval.sh rc=$rc, want 2"
grep -qF -- '--model is required' "$T/s1.err" && [ "$(grep -c . "$T/s1.err")" = 1 ] && ok || bad "S1 stderr is not one '--model is required' line: $(cat "$T/s1.err")"

# ---- S2: nothing spends — the agent-call seam is never invoked, no cost row
printf '#!/bin/bash\ntouch "%s/spied"\n' "$T" > "$T/spy.sh"; chmod +x "$T/spy.sh"
TRAP_EVAL_AGENT_CALL="$T/spy.sh" HARNESS="$T/h" "$DIR/bin/trap-eval.sh" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok || bad "S2 bin/trap-eval.sh rc=$rc with the spy seam, want 2"
[ ! -e "$T/spied" ] && ok || bad "S2 the stub invoked TRAP_EVAL_AGENT_CALL"
[ ! -e "$T/h/state/cost" ] && ok || bad "S2 the stub wrote under \$HARNESS/state/cost"

# ---- C1: exactly one trap-eval lane with the contract numbers
CB="$DIR/catalog/context-budgets.json"
n=$(jq '[.lanes[] | select(.lane=="trap-eval" and .stage=="trapeval" and .target_tokens==60000 and .ceiling_tokens==200000)] | length' "$CB" 2>/dev/null)
[ "$n" = 1 ] && ok || bad "C1 want exactly 1 trap-eval/trapeval lane at 60000/200000, got '${n:-jq failed}'"

# ---- C2: exactly one trap-eval site, and its marker is in bin/trap-eval.sh
LS="$DIR/catalog/llm-sites.json"
n=$(jq '[.sites[] | select(.id=="trap-eval")] | length' "$LS" 2>/dev/null)
[ "$n" = 1 ] && ok || bad "C2 want exactly 1 trap-eval site, got '${n:-jq failed}'"
marker=$(jq -r '.sites[] | select(.id=="trap-eval") | .marker' "$LS" 2>/dev/null)
[ -n "$marker" ] && [ -r "$DIR/bin/trap-eval.sh" ] && grep -qF -- "$marker" "$DIR/bin/trap-eval.sh" && ok \
  || bad "C2 marker '$marker' not found in bin/trap-eval.sh"

echo "trap-eval-contract: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
