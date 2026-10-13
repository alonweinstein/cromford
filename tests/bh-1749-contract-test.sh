#!/bin/bash
# tests/bh-1749-contract-test.sh — BH-1749.0 (#1762): the shared contract the
# rule-miner split builds on.
#
# Runs the real CLI (bin/rule-miner-digest.sh) and the real sourced functions
# (bin/lib/model-route.sh), against a scratch harness, so nothing here can reach
# /root/harness or the network.
#   C1-C3  the digest CLI shape: header, one "Other incidents" line per
#          inventory row (id + summary) with its bundle excerpt, ids-out, and a
#          non-zero exit with a stderr line on unreadable input
#   C4     stage_route_role lowercases and spells stage.<stage>
#   C5-C6  stage_runner_for is a stub: rc 75, empty stdout, no ALERTS line
#   C7     the context-budgets row exists and bin/rule-miner.sh is the one call
#          site that passes stage mine (BH-1764 made the lane live)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

D="$DIR/bin/rule-miner-digest.sh"
F="$T/fx"; mkdir -p "$F/bundles" "$T/h/logs"
echo "SECRET-BUNDLE-BODY do not copy me" > "$F/bundles/one.txt"
echo "family: stale-review x4" > "$F/findings.log"
# The shape bin/rule-miner.sh add_incident writes: nn \t id \t bundle-path \t summary
printf '01\tBH-11\t%s\tfirst summary here\n02\tfinding-fam-a\t%s\tsecond one\n03\tproject-3-TK-9\t%s\tthird, with commas\n' \
  "$F/bundles/one.txt" "$F/bundles/one.txt" "$F/bundles/one.txt" > "$F/inventory.tsv"

# ---- C1: header + one incident line per row, id and summary, bundle excerpt
# (BH-1763 amended this case: the real body writes a 400-byte excerpt of each
# bundle, which the stub's "no bundle contents" assertion forbade)
"$D" "$F/findings.log" "$F/inventory.tsv" "$F/out.md" "$F/ids"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "C1 digest rc=$rc, want 0"
[ "$(head -n1 "$F/out.md" 2>/dev/null)" = "# Rule-miner digest" ] && ok || bad "C1 line 1 is not '# Rule-miner digest'"
n=$(awk '/^## Other incidents/ { on = 1; next } on && /^- /' "$F/out.md" 2>/dev/null | grep -c .)
[ "$n" = 3 ] && ok || bad "C1 want 3 incident lines under '## Other incidents', got $n"
while IFS=$'\t' read -r _ id _ sum; do
  grep -qF -- "$sum" <<<"$(grep -F -- "$id" "$F/out.md" 2>/dev/null)" && ok || bad "C1 no line carries both '$id' and '$sum'"
done < "$F/inventory.tsv"
n=$(grep -c '^  excerpt: SECRET-BUNDLE-BODY do not copy me' "$F/out.md" 2>/dev/null)
[ "$n" = 3 ] && ok || bad "C1 want 3 excerpt lines carrying the bundle text, got $n"

# ---- C2: ids-out is exactly the inventory ids
cmp -s <(cut -f2 "$F/inventory.tsv") "$F/ids" && ok || bad "C2 ids-out differs from cut -f2 inventory.tsv"

# ---- C3: unreadable input -> non-zero + stderr, no out.md; wrong argc -> non-zero
"$D" "$F/findings.log" "$F/nope.tsv" "$F/out3.md" "$F/ids3" 2>"$F/err"; rc=$?
[ "$rc" -ne 0 ] && ok || bad "C3 missing inventory gave rc 0"
[ -s "$F/err" ] && ok || bad "C3 missing inventory wrote nothing to stderr"
[ ! -e "$F/out3.md" ] && ok || bad "C3 out.md created on a failed run"
# A missing findings.log is refused by the up-front check, before any output.
"$D" "$F/nope.log" "$F/inventory.tsv" "$F/out3.md" "$F/ids3" 2>"$F/err"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'cannot read' "$F/err" && [ ! -e "$F/out3.md" ] && ok || bad "C3 missing findings.log gave rc=$rc err='$(cat "$F/err")'"
"$D" "$F/findings.log" "$F/inventory.tsv" 2>/dev/null; rc=$?
[ "$rc" -ne 0 ] && ok || bad "C3 wrong argc gave rc 0"

# ---- C4..C6: the sourced functions, against the scratch harness
export HARNESS="$T/h"
unset HARNESS_SECRET JOBS_URL
. "$DIR/bin/lib/model-route.sh" || { echo "FAIL: cannot source model-route.sh"; exit 1; }
out=$(stage_route_role PREPLAN); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = stage.preplan ] && ok || bad "C4 stage_route_role PREPLAN -> '$out' rc=$rc, want stage.preplan"
out=$(stage_route_role preplan-files)
[ "$out" = stage.preplan-files ] && ok || bad "C4 stage_route_role preplan-files -> '$out'"
stage_route_role "" >/dev/null 2>&1 && bad "C4 empty stage accepted" || ok

out=$(stage_runner_for triage); rc=$?
[ "$rc" -eq 75 ] && ok || bad "C5 stage_runner_for triage rc=$rc, want 75"
[ -z "$out" ] && ok || bad "C5 stage_runner_for printed '$out'"
out=$(stage_runner_for triage buildy); rc=$?
[ "$rc" -eq 75 ] && [ -z "$out" ] && ok || bad "C5 stage_runner_for triage buildy rc=$rc out='$out'"
stage_runner_for 'tri age' >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok || bad "C5 malformed stage rc=$rc, want 1"

[ ! -s "$T/h/logs/ALERTS.log" ] && ok || bad "C6 stage_runner_for wrote ALERTS.log: $(cat "$T/h/logs/ALERTS.log")"
[ -z "$(ls -A "$T/h/state/model-routes" 2>/dev/null)" ] && ok || bad "C6 stage_runner_for wrote a model-routes cache"
[ -z "$(ls -A "$T/h/flags" 2>/dev/null)" ] && ok || bad "C6 stage_runner_for set an alert flag"

# ---- C7: the budget row, and the rule-miner is the only stage-mine call site
jq -e '.lanes[]|select(.lane=="rule-miner" and .stage=="mine" and .project=="rule-miner" and .runner==null and .ceiling_tokens<200000 and .context_kill_tokens==1500000 and .cliff_refuse==true)' \
  "$DIR/catalog/context-budgets.json" >/dev/null && ok || bad "C7 no rule-miner/mine row with the contract fields"
n=$(cat "$DIR"/bin/*.sh | grep -c 'agent-call.sh"* mine')
[ "$n" = 1 ] && ok || bad "C7 $n call site(s) pass stage mine, want exactly 1 (bin/rule-miner.sh)"
grep -q 'agent-call.sh" mine rule-miner ' "$DIR/bin/rule-miner.sh" && ok || bad "C7 bin/rule-miner.sh does not call agent-call.sh mine rule-miner"

echo "bh-1749-contract: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
