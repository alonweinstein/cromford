#!/bin/bash
# tests/agent-call-openrouter-kill-row.bh-3999-test.sh — a TERM/HUP/INT that
# lands while codex is talking to OpenRouter still writes that rung's cost row
# (BH-3999, split child of BH-3983).
#
# bin/agent-call.sh had no TERM/HUP/INT disposition, so an outer timeout, the
# lane reaper or a Fly stop killed bash before RC=$? and before
# ac_cost_row_write: the tokens codex had already bought from OpenRouter were in
# codex's session ledger and nowhere in logs/cost.csv. Driven through the real
# bin/agent-call.sh with a fake codex (the agent-call-openrouter-gate-test.sh
# shape):
#   K1  TERM to the process group mid-codex: exit 143, ONE priced openrouter
#       row, rc 143, the banner session's tokens, note killed:sig=term
#   K2  the same with HUP: exit 129, rc 129, killed:sig=hup
#   K3  no kill: exit 0, one row, no killed note (no double write)
#   K4  first model fails, floor killed: two rows in order, only the floor's is
#       the killed one
#   K5  the claude lane is never armed: no killed:sig row
#   K6  TERM to agent-call's own pid only: it still exits 143 within 5 s (no
#       foreground-trap stall) and writes the killed row
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$T" testproj
mkdir -p "$T/bin" "$T/bin/lib" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v setsid >/dev/null 2>&1 || { echo "setsid missing — skipping"; exit 0; }

SID=00000000-0000-0000-0000-00000000000c
cat > "$T/fakebin/codex" <<EOF
#!/bin/bash
m=""; prev=""
for a in "\$@"; do [ "\$prev" = -m ] && m="\$a"; prev="\$a"; done
echo "session id: $SID" >&2
echo "provider: openrouter" >&2
[ -n "\${CODEX_FAIL_MODEL:-}" ] && [ "\$m" = "\$CODEX_FAIL_MODEL" ] && { echo "upstream error" >&2; exit 1; }
if [ -n "\${CODEX_SLEEP:-}" ]; then
  echo \$\$ > "$T/child.pid"; touch "$T/marker"
  exec sleep "\$CODEX_SLEEP"
fi
echo "openrouter answered"; exit 0
EOF
cat > "$T/fakebin/claude" <<EOF
#!/bin/bash
case " \$* " in *" --help "*) printf -- '  --resume <sessionId>\n'; exit 0 ;; esac
echo \$\$ > "$T/child.pid"; touch "$T/marker"
exec sleep 30  # determinism: ok the fake CLI holding an in-flight call until the test signals it, not synchronisation
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
cat > "$T/bin/codex-usage.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$T/cu.args"
echo "1200 300 0 0"
EOF
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
printf '#!/bin/bash\necho "test rules"\n' > "$T/bin/sync-agent-rules.sh"
chmod +x "$T/fakebin/"* "$T/bin/"*.sh
cat > "$T/prices.json" <<'EOF'
{"per_token": {
  "anthropic/claude-opus-5": {"prompt": 0.000005, "completion": 0.000025,
                              "cache_read": 5e-7, "cache_write": 0.00000625},
  "deepseek/deepseek-v4-flash": {"prompt": 1e-7, "completion": 4e-7,
                                 "cache_read": 1e-8, "cache_write": null}
}}
EOF

# launch <signal|none> <target:group|pid> <env...> — runs agent-call in its own
# session, waits for the fake CLI's marker, signals, and leaves the exit status
# in $RCX and the wall seconds from signal to exit in $DT.
launch() {
  local sig="$1" target="$2" pid i
  shift 2
  rm -f "$T/marker" "$T/cu.args" "$T/logs/cost.csv" "$T/child.pid"
  ( exec env -u ACCOUNT_ROUTING -u RUNNER_EVAL_FALLBACK -u FIREWORKS_API_KEY -u XAI_API_KEY \
      -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY -u CODEX_API_KEY -u OPENAI_API_KEY \
      -u CODEX_SLEEP -u CODEX_FAIL_MODEL \
      PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" LADDER_BACKOFF_SECS=0 \
      MODEL_PRICES="$T/prices.json" CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" \
      RUNNER_EVAL=openrouter AGENT_CALL_RUNNERS=openrouter OPENROUTER_API_KEY=sk-or-test \
      OPENROUTER_FALLBACK=always "$@" \
      setsid bash "$DIR/bin/agent-call.sh" eval testproj claude-opus-5 600 "$T/out.txt" hello \
      >/dev/null 2>&1 ) &
  pid=$!
  DT=""
  if [ "$sig" != none ]; then
    for i in $(seq 1 100); do [ -e "$T/marker" ] && break; sleep 0.1; done
    [ -e "$T/marker" ] || echo "note: marker never appeared"
    sleep 0.3
    local s0=$SECONDS
    if [ "$target" = group ]; then kill -"$sig" -- "-$pid" 2>/dev/null; else kill -"$sig" "$pid" 2>/dev/null; fi
    # bounded: a stalled agent-call is killed after 20 s so the suite ends
    for i in $(seq 1 200); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    DT=$((SECONDS - s0))
    kill -0 "$pid" 2>/dev/null && kill -KILL -- "-$pid" 2>/dev/null
  fi
  wait "$pid"; RCX=$?
  # the fake CLI's sleep may outlive a killed parent: reap it by its own pid
  [ -s "$T/child.pid" ] && kill -KILL "$(cat "$T/child.pid")" 2>/dev/null
  rm -f "$T/child.pid"
}
# rows: cost.csv data rows; c <row#> <header-name> reads one field by name.
nrows() { if [ -s "$T/logs/cost.csv" ]; then tail -n +2 "$T/logs/cost.csv" | grep -c . ; else echo 0; fi; }
c() {
  awk -F, -v r="$1" -v name="$2" 'NR==1{for(i=1;i<=NF;i++) if($i==name) k=i; next}
    NR==r+1{print $k}' "$T/logs/cost.csv" 2>/dev/null
}
numgt0() { awk -v v="${1:-}" 'BEGIN{exit !(v ~ /^[0-9.]+$/ && v+0 > 0)}'; }

# K1 — TERM to the group
launch TERM group CODEX_SLEEP=30
[ "$RCX" = 143 ] && ok || bad "K1: exit status $RCX, want 143"
[ "$(nrows)" = 1 ] && ok || bad "K1: $(nrows) cost rows, want exactly 1"
[ "$(c 1 runner)" = openrouter ] && ok || bad "K1: runner '$(c 1 runner)'"
[ "$(c 1 rc)" = 143 ] && ok || bad "K1: row rc '$(c 1 rc)', want 143"
[ "$(c 1 input_toks)" = 1200 ] && ok || bad "K1: input_toks '$(c 1 input_toks)', want 1200"
[ "$(c 1 output_toks)" = 300 ] && ok || bad "K1: output_toks '$(c 1 output_toks)', want 300"
numgt0 "$(c 1 cost_usd)" && ok || bad "K1: cost_usd '$(c 1 cost_usd)' is not a positive number"
case "$(c 1 note)" in *killed:sig=term*) ok ;; *) bad "K1: note '$(c 1 note)' lacks killed:sig=term" ;; esac
[ "$(sed -n 3p "$T/cu.args" 2>/dev/null)" = "$SID" ] && ok \
  || bad "K1: codex-usage was not asked for the banner session (args: $(tr '\n' ' ' 2>/dev/null < "$T/cu.args"))"

# K2 — HUP to the group
launch HUP group CODEX_SLEEP=30
[ "$RCX" = 129 ] && ok || bad "K2: exit status $RCX, want 129"
[ "$(nrows)" = 1 ] && ok || bad "K2: $(nrows) cost rows, want exactly 1"
[ "$(c 1 rc)" = 129 ] && ok || bad "K2: row rc '$(c 1 rc)', want 129"
case "$(c 1 note)" in *killed:sig=hup*) ok ;; *) bad "K2: note '$(c 1 note)' lacks killed:sig=hup" ;; esac

# K3 — no kill: one row, no killed note
launch none group
[ "$RCX" = 0 ] && ok || bad "K3: exit status $RCX, want 0"
[ "$(nrows)" = 1 ] && ok || bad "K3: $(nrows) cost rows, want exactly 1"
[ "$(c 1 rc)" = 0 ] && ok || bad "K3: row rc '$(c 1 rc)'"
case "$(c 1 note)" in *killed*) bad "K3: a clean call carries a killed note: '$(c 1 note)'" ;; *) ok ;; esac

# K4 — first model fails, the floor is killed
launch TERM group CODEX_FAIL_MODEL=anthropic/claude-opus-5 CODEX_SLEEP=30
[ "$RCX" = 143 ] && ok || bad "K4: exit status $RCX, want 143"
[ "$(nrows)" = 2 ] && ok || bad "K4: $(nrows) cost rows, want exactly 2"
[ "$(c 1 model)" = anthropic/claude-opus-5 ] && [ "$(c 1 rc)" = 1 ] && ok \
  || bad "K4: row 1 is '$(c 1 model)' rc '$(c 1 rc)', want anthropic/claude-opus-5 rc 1"
case "$(c 1 note)" in *killed*) bad "K4: the failed first model's row says killed: '$(c 1 note)'" ;; *) ok ;; esac
[ "$(c 2 model)" = deepseek/deepseek-v4-flash ] && [ "$(c 2 rc)" = 143 ] && ok \
  || bad "K4: row 2 is '$(c 2 model)' rc '$(c 2 rc)', want deepseek/deepseek-v4-flash rc 143"
case "$(c 2 note)" in *killed:sig=term*) ok ;; *) bad "K4: floor row note '$(c 2 note)' lacks killed:sig=term" ;; esac

# K5 — the claude lane is never armed
launch TERM group RUNNER_EVAL=claude AGENT_CALL_RUNNERS=claude
grep -q 'killed:sig' "$T/logs/cost.csv" 2>/dev/null \
  && bad "K5: a claude-lane kill wrote a killed:sig row: $(grep killed:sig "$T/logs/cost.csv")" || ok

# K6 — TERM to agent-call's pid alone: prompt exit AND the row
launch TERM pid CODEX_SLEEP=30
[ "$RCX" = 143 ] && ok || bad "K6: exit status $RCX, want 143"
[ -n "$DT" ] && [ "$DT" -le 5 ] && ok || bad "K6: agent-call took ${DT:-?} s to die on a direct TERM (want <= 5)"
[ "$(nrows)" = 1 ] && ok || bad "K6: $(nrows) cost rows, want exactly 1"
case "$(c 1 note)" in *killed:sig=term*) ok ;; *) bad "K6: note '$(c 1 note)' lacks killed:sig=term" ;; esac

echo "agent-call-openrouter-kill-row: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
