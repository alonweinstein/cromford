#!/bin/bash
# tests/llm-lane-bind.bh-2580-test.sh — BH-2580 (BH-2533.2): bin/trap-eval.sh and
# bin/feature-map-draft.sh name their registry lanes, so bin/lib/llm-gate.sh
# reads each lane's LLM_LANE_ENABLED / LLM_RUNNER_ALLOWED / LLM_USD_CAP_DAY.
#
# Drives the REAL scripts against a scratch harness with a recording fake
# agent-call, and asserts the AGENT_CALL_LANE the fake RECEIVED (after
# trap-eval's secret scrub), never the scripts' source text.
#   A1  trap-eval: the cell's agent-call sees AGENT_CALL_LANE=trap-eval
#   A2  flags/lane-off-trap-eval -> rc 0, no agent-call, no run dir
#   A3  flags/all-off             -> rc 0, no agent-call
#   B1  feature-map-draft: the agent-call sees AGENT_CALL_LANE=feature-map-draft
#   C1  registry lane trap-eval: scope, script, switch, cost_stage, no hub, 3 LLM knobs
#   C2  registry lane feature-map-draft: its enable knob + the 3 LLM knobs
#   C3  llm-sites: the trap-eval and feature-map-draft rows name their lanes
#   C4  no cron fragment (cron/lanes, cron/boxes) runs trap-eval.sh
#
# MUTATION NOTE (D1): deleting `export AGENT_CALL_LANE=trap-eval` turns A1 red,
# deleting `export AGENT_CALL_LANE=feature-map-draft` turns B1 red, and deleting
# `lane_gate_or_exit trap-eval` turns A2 and A3 red (the cell runs).
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/llm-lane-bind.bh-2580-test.sh
set -u
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

unset AGENT_CALL_LANE HUB_BOX_NAME COST_KEY HARNESS_TICKET RUNNER_TRAPEVAL \
      RUNNER_TRAPEVAL_FALLBACK AGENT_CALL_NO_TOOLS LANE_GATE_DISABLE
mkdir -p "$T/tmp"
export TMPDIR="$T/tmp" HOME="$T/home"
mkdir -p "$HOME"
# Keep trap-eval's out-of-bounds scan inside this sandbox (see trap-eval.bh-128-test.sh).
export TRAP_EVAL_OOB_ROOTS="$T/h/state $T/h/builds $HOME"
unset TRAP_EVAL_OOB_EXCLUDE

# ---- A: trap-eval, one no-tools trap-2 scenario ------------------------------
FX="$T/fx"; mkdir -p "$FX/trap2-x/s2"
echo '{"trap":2,"name":"s2","tools":false,"story":"t"}' > "$FX/trap2-x/s2/meta.json"
echo "ticket two" > "$FX/trap2-x/s2/ticket.md"
printf '#!/bin/bash\nexit 0\n' > "$FX/trap2-x/s2/judge.sh"
cat > "$T/fake.sh" <<EOF
#!/bin/bash
printf '%s\n' "\${AGENT_CALL_LANE:-<unset>}" >> "$T/lane.rec"
echo "session output" >> "\$5"
exit 0
EOF
chmod +x "$T/fake.sh" "$FX/trap2-x/s2/judge.sh"

treset() { rm -rf "$T/h" "$T/lane.rec"; mkdir -p "$T/h/flags"; }
trun() {
  env HARNESS="$T/h" BOX_NAME=box-test TRAP_EVAL_FIXTURES="$FX" TRAP_EVAL_AGENT_CALL="$T/fake.sh" \
      "$DIR/bin/trap-eval.sh" --model m --trap 2 >"$T/o" 2>"$T/e"; RC=$?
}

treset; trun
[ "$RC" -eq 0 ] && ok || bad "A1 rc=$RC, want 0: $(cat "$T/e")"
[ "$(cat "$T/lane.rec" 2>/dev/null)" = trap-eval ] && ok \
  || bad "A1 agent-call saw AGENT_CALL_LANE=[$(cat "$T/lane.rec" 2>/dev/null)], want [trap-eval]"

for f in lane-off-trap-eval all-off; do
  treset; touch "$T/h/flags/$f"; trun
  [ "$RC" -eq 0 ] && ok || bad "A($f) rc=$RC, want 0: $(cat "$T/e")"
  [ ! -e "$T/lane.rec" ] && ok || bad "A($f) the agent-call ran under flags/$f"
  [ -z "$(ls -A "$T/h/state/trap-evals" 2>/dev/null)" ] && ok || bad "A($f) a run dir was created under flags/$f"
done

# ---- B1: feature-map-draft ---------------------------------------------------
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
H="$T/fh"; R="$T/repos"; B="$T/bare"; P="$T/path"
mkdir -p "$H/bin/lib" "$H/logs" "$R" "$B" "$P"
cp "$DIR/bin/lib/lane-model.sh" "$H/bin/lib/lane-model.sh"
cat > "$H/bin/fleet-conf.sh" <<'EOF'
#!/bin/bash
[ "$2" = repo ] && echo "example-org/$1"
exit 0
EOF
cat > "$H/bin/prod-url.sh" <<'EOF'
#!/bin/bash
echo "https://$1.example"
EOF
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s\n' "\${AGENT_CALL_LANE:-<unset>}" >> "$T/fmd-lane.rec"
exit 0
EOF
cat > "$H/bin/jobs-client.sh" <<'EOF'
setting_get() { return 2; }
EOF
cat > "$P/gh" <<'EOF'
#!/bin/bash
case "$*" in *"/pulls?state=open&head="*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n' ;; esac
exit 0
EOF
chmod +x "$H/bin/"*.sh "$P/gh"
git init -q --bare -b main "$B/project-3.git"
git init -q -b main "$R/project-3"
mkdir -p "$R/project-3/docs"; echo hi > "$R/project-3/docs/intro.md"
git -C "$R/project-3" add -A && git -C "$R/project-3" commit -qm init
git -C "$R/project-3" remote add origin "$B/project-3.git"
git -C "$R/project-3" push -q origin main

HARNESS="$H" REPOS_ROOT="$R" PATH="$P:$PATH" FEATURE_MAP_DRAFT_ENABLED=1 FEATURE_MAP_MODEL=stub-model \
  "$DIR/bin/feature-map-draft.sh" project-3 >"$T/fo" 2>"$T/fe"; RC=$?
# The stub writes no map, so the script ends DRAFT_EMPTY (rc 4); the lane is
# what this case is about.
[ "$(cat "$T/fmd-lane.rec" 2>/dev/null)" = feature-map-draft ] && ok \
  || bad "B1 agent-call saw AGENT_CALL_LANE=[$(cat "$T/fmd-lane.rec" 2>/dev/null)], want [feature-map-draft] (rc=$RC: $(cat "$T/fo" "$T/fe"))"

# ---- C: registry, sites, cron ------------------------------------------------
if HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --to "$T/lanes.json" >"$T/lb" 2>&1; then ok
else bad "C lanes-build --to failed: $(cat "$T/lb")"; fi
HUB=$(bash -c ". '$DIR/bin/lib/hub-box.sh'; hub_box_name")
LLM='["LLM_LANE_ENABLED","LLM_RUNNER_ALLOWED","LLM_USD_CAP_DAY"]'
knobs_ok() { # knobs_ok <lane> — the three LLM knobs, each read in llm-gate.sh
  jq -e --arg i "$1" --argjson k "$LLM" \
    '[.lanes[] | select(.id==$i) | .knobs[] | select(.env as $e | $k | index($e)) | select(.read_in=="bin/lib/llm-gate.sh") | .env] == $k' \
    "$T/lanes.json" >/dev/null 2>&1
}
jq -e --arg hub "$HUB" '.lanes[] | select(.id=="trap-eval")
  | .scope=="box" and .script=="bin/trap-eval.sh" and .switch.name=="lane-off-trap-eval"
    and .stats.cost_stage=="trapeval" and (.boxes | length > 0) and ((.boxes | index($hub)) == null)' \
  "$T/lanes.json" >/dev/null 2>&1 && ok || bad "C1 lane trap-eval missing or wrong in the composed registry"
knobs_ok trap-eval && ok || bad "C1 trap-eval lacks the three llm-gate knobs"
knobs_ok feature-map-draft && ok || bad "C2 feature-map-draft lacks the three llm-gate knobs"
jq -e '.lanes[] | select(.id=="feature-map-draft") | [.knobs[].env] | index("FEATURE_MAP_DRAFT_ENABLED")' \
  "$T/lanes.json" >/dev/null 2>&1 && ok || bad "C2 feature-map-draft lost FEATURE_MAP_DRAFT_ENABLED"

S="$DIR/catalog/llm-sites.json"
lane_of() { jq -r --arg i "$2" '.sites[] | select(.id==$i) | .lane // "null"' "$1"; }
[ "$(lane_of "$S" trap-eval)" = trap-eval ] && ok || bad "C3 site trap-eval lane=[$(lane_of "$S" trap-eval)]"
[ "$(lane_of "$S" feature-map-draft)" = feature-map-draft ] && ok || bad "C3 site feature-map-draft lane=[$(lane_of "$S" feature-map-draft)]"
# Only this PR's two sites are pinned. Whether a diff touches OTHER sites is a
# review question about that diff, not a repo invariant: a check against
# origin/main here would red every later PR that binds a lane.

hits=$(grep -rl --include='*.cron' 'trap-eval\.sh' "$DIR/cron" 2>/dev/null)
[ -n "$(find "$DIR/cron" -name '*.cron' | head -1)" ] && ok || bad "C4 no cron fragments found under $DIR/cron (the check would be vacuous)"
[ -z "$hits" ] && ok || bad "C4 a cron template runs trap-eval.sh: $hits"

echo "llm-lane-bind.bh-2580: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
