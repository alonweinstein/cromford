#!/bin/bash
# tests/trap-eval-e2e.bh-128-test.sh — BH-128.4 (#1965): trap evals end to end.
#
# Drives the real bin/trap-eval.sh over the REAL fixtures in
# catalog/fixtures/trap-evals, with a fake agent-call (TRAP_EVAL_AGENT_CALL)
# that plays a session by applying the scenario's committed known answer:
# judge/{pass,fail}.patch for a tools scenario, judge/{pass,fail}.txt for
# trap 2. The model name picks the answer (fake-pass / fake-fail). Nothing
# here reaches /root/harness, a model or the network; every assertion reads what
# the runner produced (rc, stdout, cells.jsonl, state/trap-evals.json, ALERTS).
#   table-and-json      env-scrubbed        oob-write-detected   failover-row-null
#   fixtures-shape      fixtures-no-secrets no-routing-writes / no-vendored-harness
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
FX="$DIR/catalog/fixtures/trap-evals"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The trap 1 and trap 4 judges run node; the runner and this suite read JSON.
for b in node jq; do
  command -v "$b" >/dev/null 2>&1 || { echo "FAIL: $b is required (the real judges and the state file need it)"; exit 1; }
done

unset HUB_BOX_NAME COST_KEY HARNESS_TICKET RUNNER_TRAPEVAL RUNNER_TRAPEVAL_FALLBACK \
      AGENT_CALL_NO_TOOLS IRON_LAW_LANES TRAP_EVAL_JUDGE_TIMEOUT TRAP_EVAL_OOB_EXCLUDE
mkdir -p "$T/tmp"
export TMPDIR="$T/tmp"
# The OOB scan must see only this sandbox (the R17 red of 2026-09-25, see
# tests/trap-eval.bh-128-test.sh): scratch harness state/builds and a scratch HOME.
export HOME="$T/home"
mkdir -p "$HOME"
export TRAP_EVAL_OOB_ROOTS="$T/h/state $T/h/builds $HOME"

# ---- the fake agent-call. argv: <stage> <project> <model> <timeout> <out> @<prompt>
# The cell dir is <model>@<runner>--trap<N>-<scenario>, so $5 names the scenario.
cat > "$T/fake.sh" <<EOF
#!/bin/bash
n=\$(( \$(cat "$T/n" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$T/n"
env > "$T/env.\$n"
cell=\$(basename "\$(dirname "\$5")")
case "\${cell%%@*}" in fake-pass) k=pass ;; *) k=fail ;; esac
rest=\${cell#*--trap}; trap_n=\${rest%%-*}; scen=\${rest#*-}
sd=\$(ls -d "$FX"/trap"\$trap_n"-*/"\$scen" 2>/dev/null | head -1)
if git rev-parse --git-dir >/dev/null 2>&1; then
  git apply "\$sd/judge/\$k.patch" && git add -A && git commit -qm "session" >/dev/null
else
  cat "\$sd/judge/\$k.txt" >> "\$5"
fi
[ -e "$T/fake-stray" ] && echo stray > "\$HOME/stray"
if [ -e "$T/fake-failover" ]; then
  csv="$T/h/logs/cost.csv"; mkdir -p "\$(dirname "\$csv")"
  [ -s "\$csv" ] || echo "ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note,lane_id" > "\$csv"
  echo "2026-09-26T00:00:00Z,box-test,trap-eval,trapeval,codex,gpt-x,0,3,10,10,0,0,0.01,api,,,,agent-call,,\$HARNESS_TICKET,,,,,trap-eval" >> "\$csv"
fi
echo "session output" >> "\$5"
exit 0
EOF
chmod +x "$T/fake.sh"

reset() { rm -rf "$T/h" "$T/n" "$T"/env.* "$T/fake-stray" "$T/fake-failover" "$HOME/stray"; mkdir -p "$T/h"; }
run() { # run <args...> -> $T/o, $T/e, $RC
  env HARNESS="$T/h" BOX_NAME=box-test TRAP_EVAL_FIXTURES="$FX" TRAP_EVAL_AGENT_CALL="$T/fake.sh" \
      "$DIR/bin/trap-eval.sh" "$@" >"$T/o" 2>"$T/e"; RC=$?
}
rundir() { ls -d "$T"/h/state/trap-evals/*/ 2>/dev/null | head -1; }
cells() { cat "$(rundir)cells.jsonl" 2>/dev/null; }
STATE="$T/h/state/trap-evals.json"

# ---- table-and-json: 16 real scenarios x a passing and a failing fake
reset; run --model fake-pass@claude --model fake-fail@claude
[ "$RC" -eq 0 ] && ok || bad "table-and-json rc=$RC, want 0: $(cat "$T/e")"
[ "$(cells | grep -c .)" = 32 ] && ok || bad "table-and-json cells.jsonl has $(cells | grep -c .) lines, want 32"
[ "$(jq '.table|length' "$STATE" 2>/dev/null)" = 8 ] && ok || bad "table-and-json .table|length=$(jq '.table|length' "$STATE" 2>&1), want 8"
for t in 1 2 3 4; do
  r=$(jq -c --argjson t "$t" '.table[] | select(.model=="fake-pass" and .trap==$t) | [.passed,.graded,.nulls]' "$STATE" 2>/dev/null)
  [ "$r" = "[4,4,0]" ] && ok || bad "table-and-json fake-pass trap $t row=$r, want [4,4,0]: $(cells | jq -c --argjson t "$t" 'select(.model=="fake-pass" and .trap==$t) | [.scenario,.verdict,.reason]')"
  r=$(jq -c --argjson t "$t" '.table[] | select(.model=="fake-fail" and .trap==$t) | [.passed,.graded,.nulls]' "$STATE" 2>/dev/null)
  [ "$r" = "[0,4,0]" ] && ok || bad "table-and-json fake-fail trap $t row=$r, want [0,4,0]: $(cells | jq -c --argjson t "$t" 'select(.model=="fake-fail" and .trap==$t) | [.scenario,.verdict,.reason]')"
done
grep -qx 'GAP: trap 1, trap 2, trap 3, trap 4' "$T/o" && ok || bad "table-and-json no 'GAP: trap 1, trap 2, trap 3, trap 4' line: $(cat "$T/o")"
[ "$(cells | jq -r 'select(.verdict=="null" or .verdict=="violation") | .scenario' | grep -c .)" = 0 ] && ok \
  || bad "table-and-json null/violation cells: $(cells | jq -c 'select(.verdict=="null" or .verdict=="violation") | [.model,.scenario,.verdict,.reason]')"

# ---- env-scrubbed: credentials exported to the runner never reach the session
reset
env GH_TOKEN=fixture-gh FOO_SECRET=fixture-secret DATABASE_URL=fixture-db \
    HARNESS="$T/h" BOX_NAME=box-test TRAP_EVAL_FIXTURES="$FX" TRAP_EVAL_AGENT_CALL="$T/fake.sh" \
    "$DIR/bin/trap-eval.sh" --model fake-pass@claude --trap 2 --scenario cron-tsc-only >"$T/o" 2>"$T/e"; RC=$?
[ "$RC" -eq 0 ] && [ -f "$T/env.1" ] && ok || bad "env-scrubbed rc=$RC, fake env recorded=$([ -f "$T/env.1" ] && echo y || echo n): $(cat "$T/e")"
for v in GH_TOKEN FOO_SECRET DATABASE_URL; do
  grep -q "^$v=" "$T/env.1" 2>/dev/null && bad "env-scrubbed $v reached the session" || ok
done
ed=$(sed -n 's/^HARNESS_ENV_DIR=//p' "$T/env.1" 2>/dev/null)
case "$ed" in "$T/tmp"/*) ok ;; *) bad "env-scrubbed HARNESS_ENV_DIR='$ed' not under $T/tmp" ;; esac
[ -n "$ed" ] && [ ! -e "$ed/global.env" ] && ok || bad "env-scrubbed HARNESS_ENV_DIR='$ed' holds a global.env"
for v in GH_CONFIG_DIR GIT_CONFIG_GLOBAL; do
  p=$(sed -n "s/^$v=//p" "$T/env.1" 2>/dev/null)
  case "$p" in "$T/tmp"/*) ok ;; *) bad "env-scrubbed $v='$p' not under $T/tmp" ;; esac
done

# ---- oob-write-detected: a session that writes $HOME/stray is a violation, rc 3
reset; touch "$T/fake-stray"
run --model fake-pass@claude --trap 3 --scenario apply-prod
[ "$RC" -eq 3 ] && ok || bad "oob-write-detected rc=$RC, want 3: $(cat "$T/e")"
c=$(cells | jq -c '[.verdict,.reason]')
case "$c" in '["violation",'*stray*) ok ;; *) bad "oob-write-detected cell=$c, want violation naming stray" ;; esac
[ "$(grep -c 'trap-eval:' "$T/h/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok || bad "oob-write-detected ALERTS.log: $(cat "$T/h/logs/ALERTS.log" 2>&1)"

# ---- failover-row-null: another runner answered, so the cell is never graded
reset; touch "$T/fake-failover"
run --model fake-pass@claude --trap 2 --scenario cron-tsc-only
[ "$RC" -eq 0 ] && ok || bad "failover-row-null rc=$RC, want 0: $(cat "$T/e")"
c=$(cells | jq -c '[.verdict,.reason]')
case "$c" in '["null","answered by codex/'*) ok ;; *) bad "failover-row-null cell=$c, want null 'answered by codex/...'" ;; esac
r=$(jq -c '.table[0] | [.graded,.nulls]' "$STATE" 2>/dev/null)
[ "$r" = "[0,1]" ] && ok || bad "failover-row-null table [graded,nulls]=$r, want [0,1]"

# ---- fixtures-shape: the real fixture tree, and the runner's view of it
n=$(ls -d "$FX"/trap*/ 2>/dev/null | grep -c .)
[ "$n" = 4 ] && ok || bad "fixtures-shape $n trap dirs, want 4"
for td in "$FX"/trap*/; do
  tn=$(basename "$td"); tn=${tn#trap}; tn=${tn%%-*}
  s=$(ls -d "$td"*/ 2>/dev/null | grep -c .)
  [ "$s" -ge 4 ] && ok || bad "fixtures-shape $(basename "$td") has $s scenarios, want >=4"
  for sd in "$td"*/; do
    for f in meta.json ticket.md judge.sh; do [ -s "$sd$f" ] || bad "fixtures-shape $sd lacks $f"; done
    jq -e '.story|length>0' "$sd/meta.json" >/dev/null 2>&1 && ok || bad "fixtures-shape $sd story empty"
    [ "$(jq -r .trap "$sd/meta.json" 2>/dev/null)" = "$tn" ] && ok || bad "fixtures-shape $sd .trap != $tn"
  done
done
reset; run --list
[ "$RC" -eq 0 ] && [ "$(grep -c . "$T/o")" = 16 ] && ok || bad "fixtures-shape --list rc=$RC lines=$(grep -c . "$T/o"), want 16"

# ---- fixtures-no-secrets: no credential shape and no model literal anywhere
grep -rnE 'sk-ant-|ghp_|github_pat_|AKIA[0-9A-Z]{16}|xox[bp]-|-----BEGIN .*PRIVATE KEY|claude-[a-z]+-[0-9]' "$FX" > "$T/lit" 2>&1; rc=$?
[ "$rc" -eq 1 ] && [ ! -s "$T/lit" ] && ok || bad "fixtures-no-secrets grep rc=$rc, want 1 and no hits: $(cat "$T/lit")"

# ---- no-routing-writes / no-vendored-harness: this branch's diff vs its main merge-base
# BH-1965's scope rule, so it binds a branch that touches the trap-eval code
# (runner, cells lib, fixtures, lane json); an unrelated branch (a new cron lane) is not trap-eval work (BH-2655).
if base=$(git -C "$DIR" merge-base origin/main HEAD 2>/dev/null) && [ -n "$base" ]; then
  git -C "$DIR" diff --name-only "$base" > "$T/diff" 2>&1; rc=$?
fi
if [ -n "$base" ] && [ "$rc" -eq 0 ] && ! grep -qE '^bin/(lib/)?trap-eval|^catalog/fixtures/trap-evals/|^catalog/lanes\.d/trap-eval\.json$' "$T/diff"; then
  echo "SKIP: branch diff touches no trap-eval code (no-routing-writes / no-vendored-harness not checked)"
elif [ -n "$base" ]; then
  hits=$(grep -E 'model_routes|routing\.json|AgentConfig|^bin/prompt-eval\.sh$|^bin/agent-call\.sh$|^catalog/fixtures/golden/|^cron/|fable-method' "$T/diff")
  [ "$rc" -eq 0 ] && [ -z "$hits" ] && ok || bad "no-routing-writes / no-vendored-harness rc=$rc, forbidden paths: $hits"
else
  echo "SKIP: no origin/main (no-routing-writes / no-vendored-harness not checked)"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
