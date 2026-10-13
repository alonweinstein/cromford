#!/bin/bash
# tests/trap-eval.bh-128-test.sh — BH-128.1 (#1962): the trap-eval runner.
#
# Drives the real bin/trap-eval.sh against a scratch harness, synthetic fixtures
# (TRAP_EVAL_FIXTURES) and a recording fake agent-call (TRAP_EVAL_AGENT_CALL),
# so nothing here reaches /root/harness, a model or the network. Every assertion
# reads what the runner produced (exit code, stderr, the fake's recorded argv,
# env and cwd, cells.jsonl), never the runner's source.
#   R1  refuses-no-model          R8  sandbox-cwd-and-origin
#   R2  list-prints-scenarios     R9  no-tools-set-for-trap2
#   R3  no-fixtures-rc2           R10 grok-on-trap2-not-called
#   R4  jq-missing-rc2            R11 judge-rc0-pass / rc1-fail / rc2-null-not-pass
#   R5  refuses-on-hub-with-tools R12 no-model-judge
#   R6  lock-held-skips-rc2       R13 guard-denied-counted
#   R7  dry-run-spends-nothing    R14 cells-shape / stale-out-truncated / partial
#       + the real run's argv     R15 env-scrubbed
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

unset HUB_BOX_NAME COST_KEY HARNESS_TICKET RUNNER_TRAPEVAL RUNNER_TRAPEVAL_FALLBACK \
      AGENT_CALL_NO_TOOLS IRON_LAW_LANES TRAP_EVAL_JUDGE_TIMEOUT
mkdir -p "$T/tmp" "$T/empty"
export TMPDIR="$T/tmp"
# THE OOB SCAN MUST SEE ONLY THIS SANDBOX. Every real run ends in
# trap_eval_oob_scan, whose default roots are the invoking user's $HOME plus
# /root/repos, /root/worktrees and friends. On a CI runner $HOME is
# /home/runner, which holds the live checkout and the runner's own step-log
# pages; on a test host /root/* is shared with every other gate run. Any write
# there inside a cell's window read as an out-of-bounds write: rc 3, the main
# red of 2026-09-25 (R17, run 36089250534). The default roots and exclusions are
# pinned by tests/trap-eval-cells.bh-128-test.sh against its own sandbox; here
# they point at the scratch harness and a scratch HOME.
export HOME="$T/home"
mkdir -p "$HOME"
export TRAP_EVAL_OOB_ROOTS="$T/h/state $T/h/builds $HOME"
unset TRAP_EVAL_OOB_EXCLUDE

# ---- synthetic fixtures: trap1 (tools) and trap2 (no tools)
FX="$T/fx"
mkdir -p "$FX/trap1-x/s1/repo" "$FX/trap2-x/s2"
echo '{"trap":1,"name":"s1","tools":true,"timeout_s":60,"story":"t"}' > "$FX/trap1-x/s1/meta.json"
echo '{"trap":2,"name":"s2","tools":false,"story":"t"}'               > "$FX/trap2-x/s2/meta.json"
echo "ticket one" > "$FX/trap1-x/s1/ticket.md"
echo "ticket two" > "$FX/trap2-x/s2/ticket.md"
echo "a" > "$FX/trap1-x/s1/repo/a.txt"
for s in trap1-x/s1 trap2-x/s2; do
  cat > "$FX/$s/judge.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$T/judge.argv.\$(basename "\$2" | tr -c 'a-z0-9' _)\$\$"
echo judged >> "$T/judges"
exit "\$(cat "$T/judge-rc")"
EOF
done
echo 0 > "$T/judge-rc"

# ---- the fake agent-call: records, writes one line to $5, spends nothing
cat > "$T/fake.sh" <<EOF
#!/bin/bash
n=\$(( \$(cat "$T/n" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$T/n"
printf '%s\n' "\$*" >> "$T/calls"
printf '%s\n' "\$@" > "$T/argv.\$n"
env > "$T/env.\$n"
{ pwd; git remote get-url origin 2>/dev/null || echo NOREMOTE
  git --git-dir="\$(git remote get-url origin 2>/dev/null || echo /nonexistent)" rev-parse --is-bare-repository 2>/dev/null || echo NOTBARE
  git rev-list --count HEAD 2>/dev/null || echo NOREPO; } > "$T/wt.\$n"
{ [ -e "\$5" ] && echo exists || echo absent; stat -c %s "\$5" 2>/dev/null
  [ -e "\$(dirname "\$5")/.t0" ] && echo t0 || echo no-t0; } > "$T/outstate.\$n"
[ -e "$T/fake-deny" ] && echo "BLOCKED by the harness act-time iron-law guard: git push" >> "\$5"
git rev-parse --git-dir >/dev/null 2>&1 && echo new > new.txt
echo "session output" >> "\$5"
exit 0
EOF
chmod +x "$T/fake.sh"

reset() { rm -rf "$T/h" "$T/calls" "$T/n" "$T"/argv.* "$T"/env.* "$T"/wt.* "$T"/outstate.* \
                 "$T/judges" "$T"/judge.argv.* "$T/fake-deny"; mkdir -p "$T/h"; }
run() { # run <args...>  -> $T/o, $T/e, $RC
  env HARNESS="$T/h" BOX_NAME=box-test TRAP_EVAL_FIXTURES="$FX" TRAP_EVAL_AGENT_CALL="$T/fake.sh" \
      "$DIR/bin/trap-eval.sh" "$@" >"$T/o" 2>"$T/e"; RC=$?
}
calls() { [ -f "$T/calls" ] && wc -l < "$T/calls" | tr -d ' ' || echo 0; }
lines() { grep -c . "$1" 2>/dev/null || echo 0; }
rundir() { ls -d "$T"/h/state/trap-evals/*/ 2>/dev/null | head -1; }
cells() { cat "$(rundir)cells.jsonl" 2>/dev/null; }
cell() { cells | jq -c --argjson t "$1" 'select(.trap==$t)' 2>/dev/null; }

# ---- R1: refuses-no-model (and every other argv refusal) spends nothing
reset; run
[ "$RC" -eq 2 ] && ok || bad "R1 no args rc=$RC, want 2"
[ "$(lines "$T/e")" = 1 ] && grep -qF -- '--model is required' "$T/e" && ok || bad "R1 stderr not one '--model is required' line: $(cat "$T/e")"
[ "$(calls)" = 0 ] && ok || bad "R1 no-model run invoked the agent-call seam"
r1() { reset; run "$@"; [ "$RC" -eq 2 ] && [ "$(calls)" = 0 ] && ok || bad "R1 '$*' rc=$RC calls=$(calls), want rc 2 and 0 calls"; }
r1 --model ""; r1 --model @claude; r1 --model m --trap 5; r1 --model m --trap x; r1 --model m --bogus

# ---- R2: --list needs no model, prints both scenarios, calls nothing
reset; run --list
[ "$RC" -eq 0 ] && ok || bad "R2 --list rc=$RC: $(cat "$T/e")"
grep -qE '^trap1 +s1 +tools=true$' "$T/o" && grep -qE '^trap2 +s2 +tools=false$' "$T/o" && ok || bad "R2 --list output: $(cat "$T/o")"
[ "$(calls)" = 0 ] && [ ! -e "$T/h/locks/trap-eval.lock" ] && ok || bad "R2 --list called or took the lock"

# ---- R3: no fixtures (empty root, or a filter that selects nothing)
reset; env HARNESS="$T/h" BOX_NAME=box-test TRAP_EVAL_FIXTURES="$T/empty" TRAP_EVAL_AGENT_CALL="$T/fake.sh" \
  "$DIR/bin/trap-eval.sh" --model m >"$T/o" 2>"$T/e"; RC=$?
[ "$RC" -eq 2 ] && [ "$(lines "$T/e")" = 1 ] && grep -q 'no trap-eval scenarios' "$T/e" && ok || bad "R3 empty root rc=$RC err=$(cat "$T/e")"
reset; run --model m --scenario nosuch
[ "$RC" -eq 2 ] && [ "$(lines "$T/e")" = 1 ] && [ "$(calls)" = 0 ] && ok || bad "R3 --scenario nosuch rc=$RC err=$(cat "$T/e")"

# ---- R4: jq missing — a PATH with everything but jq
mkdir -p "$T/nojq"
for f in /usr/local/bin/* /usr/bin/* /bin/*; do
  b=$(basename "$f"); [ "$b" = jq ] && continue; [ -e "$T/nojq/$b" ] || ln -s "$f" "$T/nojq/$b" 2>/dev/null
done
reset; env PATH="$T/nojq" HARNESS="$T/h" BOX_NAME=box-test TRAP_EVAL_FIXTURES="$FX" TRAP_EVAL_AGENT_CALL="$T/fake.sh" \
  "$DIR/bin/trap-eval.sh" --model m >"$T/o" 2>"$T/e"; RC=$?
[ "$RC" -eq 2 ] && [ "$(lines "$T/e")" = 1 ] && grep -q 'jq' "$T/e" && [ "$(calls)" = 0 ] && ok || bad "R4 jq missing rc=$RC err=$(cat "$T/e")"

# ---- R5: the hub refuses a tools scenario, runs a tools:false-only selection
reset; env HARNESS="$T/h" BOX_NAME=box-hub TRAP_EVAL_FIXTURES="$FX" TRAP_EVAL_AGENT_CALL="$T/fake.sh" \
  "$DIR/bin/trap-eval.sh" --model m >"$T/o" 2>"$T/e"; RC=$?
[ "$RC" -eq 2 ] && [ "$(lines "$T/e")" = 1 ] && grep -q 'hub' "$T/e" && [ "$(calls)" = 0 ] && ok || bad "R5 hub+tools rc=$RC calls=$(calls) err=$(cat "$T/e")"
reset; env HARNESS="$T/h" BOX_NAME=box-hub TRAP_EVAL_FIXTURES="$FX" TRAP_EVAL_AGENT_CALL="$T/fake.sh" \
  "$DIR/bin/trap-eval.sh" --model m --trap 2 >"$T/o" 2>"$T/e"; RC=$?
[ "$RC" -eq 0 ] && [ "$(calls)" = 1 ] && ok || bad "R5 hub --trap 2 rc=$RC calls=$(calls) err=$(cat "$T/e")"

# ---- R6: a held lock is a skip, never a wait
reset; mkdir -p "$T/h/locks"
flock -n "$T/h/locks/trap-eval.lock" -c "touch '$T/held'; sleep 30" & LOCKPID=$!
for _ in $(seq 50); do [ -e "$T/held" ] && break; sleep 0.1; done
t0=$(date +%s); run --model m; t1=$(date +%s)
[ "$RC" -eq 2 ] && [ "$(lines "$T/e")" = 1 ] && grep -q 'lock' "$T/e" && ok || bad "R6 held lock rc=$RC err=$(cat "$T/e")"
[ $((t1 - t0)) -lt 5 ] && [ "$(calls)" = 0 ] && ok || bad "R6 held lock took $((t1 - t0))s, calls=$(calls)"
pkill -P "$LOCKPID" 2>/dev/null; kill "$LOCKPID" 2>/dev/null; wait "$LOCKPID" 2>/dev/null; rm -f "$T/held"

# ---- R7: dry run spends nothing and prints the worst-case bill; the real run's argv
reset; run --dry-run --model m
[ "$RC" -eq 0 ] && [ "$(calls)" = 0 ] && [ ! -e "$T/h/state/trap-evals" ] && ok || bad "R7 dry run rc=$RC calls=$(calls) err=$(cat "$T/e")"
grep -qF '2 cells × 200000' "$T/o" && grep -qE '^m@claude trap1/s1 tools=true$' "$T/o" && ok || bad "R7 dry-run output: $(cat "$T/o")"
reset; run --model m
[ "$RC" -eq 0 ] && [ "$(calls)" = 2 ] && ok || bad "R7 real run rc=$RC calls=$(calls) err=$(cat "$T/e")"
RD=$(rundir); C1="${RD}m@claude--trap1-s1"; C2="${RD}m@claude--trap2-s2"
[ "$(tr '\n' ' ' < "$T/argv.1")" = "trapeval trap-eval m 60 $C1/out.txt @$C1/prompt.md " ] && ok || bad "R7 argv.1: $(tr '\n' ' ' < "$T/argv.1")"
[ "$(tr '\n' ' ' < "$T/argv.2")" = "trapeval trap-eval m 900 $C2/out.txt @$C2/prompt.md " ] && ok || bad "R7 argv.2 (default timeout 900): $(tr '\n' ' ' < "$T/argv.2")"
[ "$(cat "$C1/prompt.md" 2>/dev/null)" = "ticket one" ] && ok || bad "R7 prompt.md is not ticket.md"

# ---- R8: sandbox — cwd in a scratch root under TMPDIR, bare origin beside it, one commit, removed after
W1=$(sed -n 1p "$T/wt.1"); O1=$(sed -n 2p "$T/wt.1"); ROOT1=${W1%/wt}
case "$W1" in "$T/tmp/trap-eval."*/wt) ok ;; *) bad "R8 tools cwd '$W1' not <\$TMPDIR>/trap-eval.*/wt" ;; esac
[ "$O1" = "$ROOT1/origin.git" ] && [ "$(sed -n 3p "$T/wt.1")" = true ] && ok || bad "R8 origin '$O1' bare=$(sed -n 3p "$T/wt.1"), want $ROOT1/origin.git bare"
[ "$(sed -n 4p "$T/wt.1")" = 1 ] && ok || bad "R8 rev-list --count HEAD = $(sed -n 4p "$T/wt.1"), want 1"
[ ! -e "$ROOT1" ] && ! ls -d "$T"/tmp/trap-eval.* >/dev/null 2>&1 && ok || bad "R8 scratch root left behind: $(ls "$T/tmp")"
W2=$(sed -n 1p "$T/wt.2")
case "$W2" in "$T/tmp/trap-eval."*) [ "$(sed -n 2p "$T/wt.2")" = NOREMOTE ] && ok || bad "R8 no-tools cell has a remote" ;; *) bad "R8 no-tools cwd '$W2'" ;; esac
grep -q 'new.txt' "$C1/diff.patch" 2>/dev/null && ok || bad "R8 diff.patch lacks the untracked file the session wrote"
for f in prompt.md out.txt diff.patch judge.out env-scrub.txt; do [ -f "$C1/$f" ] || bad "R8 cell dir lacks $f"; done; ok

# ---- R9: AGENT_CALL_NO_TOOLS=1 on the tools:false cell only — set by the runner, and
# stripped from the tools cell even when inherited
reset; run --model m
grep -qx 'AGENT_CALL_NO_TOOLS=1' "$T/env.2" && ok || bad "R9 the runner did not set AGENT_CALL_NO_TOOLS=1 on the tools:false cell"
reset; AGENT_CALL_NO_TOOLS=1 run --model m
grep -qx 'AGENT_CALL_NO_TOOLS=1' "$T/env.2" && ok || bad "R9 tools:false cell lacks AGENT_CALL_NO_TOOLS=1"
! grep -q '^AGENT_CALL_NO_TOOLS=' "$T/env.1" && ok || bad "R9 tools:true cell carries AGENT_CALL_NO_TOOLS"

# ---- R10: a non-claude runner on a tools:false scenario is never called
reset; run --model m@grok --trap 2
[ "$RC" -eq 0 ] && [ "$(calls)" = 0 ] && ok || bad "R10 grok trap2 rc=$RC calls=$(calls)"
[ "$(cell 2 | jq -r '"\(.verdict)|\(.reason)|\(.runner)"')" = "null|runner cannot enforce no-tools|grok" ] && ok || bad "R10 cell: $(cells)"
[ ! -e "$T/judges" ] && ok || bad "R10 an uncalled cell was judged"

# ---- R11: judge rc -> verdict; a judge error is never a pass
for pair in 0:pass 1:fail 2:null; do
  reset; echo "${pair%%:*}" > "$T/judge-rc"; run --model m
  v=$(cells | jq -r '.verdict' | sort -u | tr '\n' ' ')
  [ "$RC" -eq 0 ] && [ "$v" = "${pair#*:} " ] && ok || bad "R11 judge rc ${pair%%:*}: run rc=$RC verdicts='$v', want '${pair#*:}'"
done
echo 0 > "$T/judge-rc"

# ---- R12: the judge is code, not a model: one agent call per cell, judge argv is <wt> <out> <base>
reset; run --model m --model n
[ "$(calls)" = 4 ] && [ "$(lines "$T/judges")" = 4 ] && ok || bad "R12 calls=$(calls) judges=$(lines "$T/judges"), want 4 and 4"
ja=$(cat "$T"/judge.argv.* | grep -c "^$T/tmp/trap-eval")
[ "$ja" = 4 ] && ok || bad "R12 judge argv[1] not the scratch worktree in all 4 judges ($ja)"

# ---- R13: guard_denied from the iron-law guard's deny line
reset; touch "$T/fake-deny"; run --model m --trap 1
[ "$(cell 1 | jq -r .guard_denied)" = true ] && [ "$(cat "$(rundir)m@claude--trap1-s1/guard-denied.txt")" = 1 ] && ok || bad "R13 denied: $(cells)"
reset; run --model m --trap 1
[ "$(cell 1 | jq -r .guard_denied)" = false ] && ok || bad "R13 not denied: $(cells)"

# ---- R14: cells shape, stale-out, .t0, partial note
reset; run --model m
n=$(cells | jq -e 'has("model") and has("runner") and has("trap") and has("scenario") and has("verdict") and has("reason") and has("cost_usd") and has("guard_denied") and has("cell_dir")' 2>/dev/null | grep -c true)
[ "$n" = 2 ] && ok || bad "R14 cells-shape: $n of 2 lines carry every contract key: $(cells)"
[ "$(cell 1 | jq -r '"\(.model)|\(.runner)|\(.scenario)|\(.cost_usd)|\(.trap|type)"')" = "m|claude|s1|null|number" ] && ok || bad "R14 cell 1 values: $(cell 1)"
[ -d "$(cell 1 | jq -r .cell_dir)" ] && ok || bad "R14 cell_dir is not a directory"
[ "$(tr '\n' ' ' < "$T/outstate.1")" = "exists 0 t0 " ] && ok || bad "R14 out/t0 at call start: $(tr '\n' ' ' < "$T/outstate.1")"
! grep -q 'partial run' "$T/o" && ok || bad "R14 a full run was labelled partial"
reset; run --model m --trap 2
grep -qF 'partial run: 1 of 2 scenarios' "$T/o" && ok || bad "R14 filtered run not labelled partial: $(cat "$T/o")"

# ---- R15: env-scrubbed — credentials gone, runner auth kept, isolation vars set
reset
env GH_TOKEN=x GITHUB_TOKEN=x FOO_DATABASE_URL=x X_SERVICE_ROLE_KEY=x SOME_API_KEY=x ANTHROPIC_API_KEY=keep \
    COST_KEY=someother RUNNER_TRAPEVAL_FALLBACK=openrouter GH_CONFIG_DIR=/root/.config/gh \
    HARNESS="$T/h" BOX_NAME=box-test TRAP_EVAL_FIXTURES="$FX" TRAP_EVAL_AGENT_CALL="$T/fake.sh" \
    "$DIR/bin/trap-eval.sh" --model m >"$T/o" 2>"$T/e"; RC=$?
[ "$RC" -eq 0 ] && [ "$(calls)" = 2 ] && ok || bad "R15 rc=$RC calls=$(calls) err=$(cat "$T/e")"
for v in GH_TOKEN GITHUB_TOKEN FOO_DATABASE_URL X_SERVICE_ROLE_KEY SOME_API_KEY; do
  grep -q "^$v=" "$T/env.1" && bad "R15 $v reached the call" || ok
done
grep -qx 'ANTHROPIC_API_KEY=keep' "$T/env.1" && ok || bad "R15 ANTHROPIC_API_KEY was scrubbed"
g=$(sed -n 's/^GH_CONFIG_DIR=//p' "$T/env.1"); c=$(sed -n 's/^GIT_CONFIG_GLOBAL=//p' "$T/env.1")
case "$g" in "$T"/*) ok ;; *) bad "R15 GH_CONFIG_DIR='$g' not under the scratch tree" ;; esac
case "$c" in "$T"/*) ok ;; *) bad "R15 GIT_CONFIG_GLOBAL='$c' not under the scratch tree" ;; esac
grep -q '^IRON_LAW_LANES=.* trapeval$' "$T/env.1" && ok || bad "R15 IRON_LAW_LANES: $(grep IRON_LAW_LANES "$T/env.1")"
grep -qx 'RUNNER_TRAPEVAL=claude' "$T/env.1" && grep -qx 'RUNNER_TRAPEVAL_FALLBACK=' "$T/env.1" && ok || bad "R15 RUNNER_TRAPEVAL(_FALLBACK): $(grep RUNNER_TRAPEVAL "$T/env.1")"
grep -qx 'LADDER_TIER2_GROK=0' "$T/env.1" && ok || bad "R15 LADDER_TIER2_GROK not 0"
k1=$(sed -n 's/^COST_KEY=//p' "$T/env.1"); h1=$(sed -n 's/^HARNESS_TICKET=//p' "$T/env.1"); k2=$(sed -n 's/^COST_KEY=//p' "$T/env.2")
[ -n "$k1" ] && [ "$k1" = "$h1" ] && [ "$k1" != someother ] && [ -n "$k2" ] && [ "$k1" != "$k2" ] && ok || bad "R15 cell tags k1='$k1' h1='$h1' k2='$k2'"
grep -qx GH_TOKEN "$(rundir)m@claude--trap1-s1/env-scrub.txt" 2>/dev/null && ok || bad "R15 env-scrub.txt lacks GH_TOKEN"

# ---- R16: a null verdict is the contract's STRING "null", never JSON null
# (#2031 lead review: #2046's trap_eval_report counts .verdict == "null", so a
# JSON null vanished from the table). jq -e, because jq -r prints both alike.
reset; run --model m@grok --trap 2
cell 2 | jq -e '.verdict == "null"' >/dev/null && ok || bad "R16 no-tools null cell verdict is not the string \"null\": $(cell 2)"
reset; echo 2 > "$T/judge-rc"; run --model m
[ "$(cells | jq -c 'select(.verdict == "null")' | grep -c .)" = 2 ] && ok \
  || bad "R16 judge-error cells are not the string \"null\": $(cells)"
echo 0 > "$T/judge-rc"

# ---- R17: HARNESS_SECRET stays out of the eval CLI end to end. The scrub drops
# it from the runner's env, but agent-call sources bin/jobs-client.sh, which
# re-reads an empty HARNESS_SECRET from <env dir>/global.env and EXPORTS it, so
# the CLI child inherited it. This fake does what agent-call does (source the
# REAL jobs-client.sh), then records the env a child would get.
cat > "$T/fake-jc.sh" <<JCEOF
#!/bin/bash
. "$DIR/bin/jobs-client.sh" >/dev/null 2>&1
n=\$(( \$(cat "$T/n" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$T/n"
printf '%s\n' "\$*" >> "$T/calls"
env > "$T/env.\$n"
echo "session output" >> "\$5"
exit 0
JCEOF
chmod +x "$T/fake-jc.sh"
reset; mkdir -p "$T/h/env/accounts.d"
printf 'HARNESS_SECRET=FAKE-fixture-harness-secret\nJOBS_URL=http://127.0.0.1:9\n' > "$T/h/env/global.env"
env HARNESS_SECRET=FAKE-fixture-harness-secret HARNESS="$T/h" BOX_NAME=box-test TRAP_EVAL_FIXTURES="$FX" \
    TRAP_EVAL_AGENT_CALL="$T/fake-jc.sh" "$DIR/bin/trap-eval.sh" --model m >"$T/o" 2>"$T/e"; RC=$?
[ "$RC" -eq 0 ] && [ "$(calls)" = 2 ] && ok || bad "R17 rc=$RC calls=$(calls) err=$(cat "$T/e")"
for k in 1 2; do
  grep -q '^HARNESS_SECRET=' "$T/env.$k" && bad "R17 cell $k: HARNESS_SECRET reached the eval CLI through jobs-client.sh" || ok
done
grep -qx "ACCOUNTS_DIR=$T/h/env/accounts.d" "$T/env.1" && ok \
  || bad "R17 runner accounts must stay reachable: $(grep ACCOUNTS_DIR "$T/env.1")"

echo "trap-eval: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
