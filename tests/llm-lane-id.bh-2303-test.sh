#!/bin/bash
# tests/llm-lane-id.bh-2303-test.sh — BH-2303: a cost row carries the LANE it
# was spent by, every LLM lane says which lane it is, and a lane's daily cap
# binds that lane and no other.
#
# WHY. The BH-1141 gate inferred the lane from (stage, project). review-prs,
# review-autopilot and merge-conductor all price as stage=review, so each lane's
# LLM_USD_CAP_DAY summed all three — or resolved to the synthetic stage-review —
# and the knobs on the Settings page for those lanes bound nothing (the LLM
# cost/pathway audit, 2026-09-25, gap 1). Driven, not grepped, like
# tests/llm-gate-test.sh: the real bin/agent-call.sh runs against a scratch
# $HARNESS, and what is asserted is whether the fake vendor RAN, what landed in
# logs/cost.csv, and which question the gate asked the worker.
#
#   1  a lane's cap binds only that lane: review-prs over its cap is refused
#      while review-autopilot, on the SAME stage, still runs
#   2  the spend question names the lane (llm-spend?lane=<id>)
#   3  every cost row carries lane_id (column 25): AGENT_CALL_LANE when set,
#      else the lane the gate resolved; a refused row carries it too
#   4  the push to D1 carries lane_id
#   5  every LLM site catalog/llm-sites.json names a lane for sets
#      AGENT_CALL_LANE=<that lane> in the script that runs the call, and that
#      lane is a registry lane
#   6  the lane never leaks into a CHILD (review of #2462, blocking 2): a build
#      a triage session starts is not gated by, or stamped to, run-triage —
#      agent-call keeps AGENT_CALL_LANE out of every vendor CLI's env, and
#      bin/run-build.sh drops an inherited one at entry
# Run from anywhere: tests/llm-lane-id.bh-2303-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
. "$DIR/tests/lib/rendered.sh" || exit 1
mrs_fixture "$T" lproj
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/logs" "$T/locks" "$T/flags" "$T/state" "$T/fakebin" "$T/bin" "$T/catalog"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T" || exit 1

# The vendor CLIs leave a file behind when they RUN — the evidence for "was the money spent".
for R in claude codex grok gemini; do
  cat > "$T/fakebin/$R" <<EOF
#!/bin/bash
touch "\$SENTINEL_DIR/$R-ran"
printf '%s\n' "\${AGENT_CALL_LANE-<unset>}" >> "\$SENTINEL_DIR/vendor-env-lane"
# CHILD_BUILD=1: this "session" starts a build's own model call, the way a
# triage session's \`setsid run-build.sh\` does — inheriting THIS process's env.
if [ "\${CHILD_BUILD:-}" = 1 ]; then
  env -u CHILD_BUILD -u LLM_GATE_DISABLE LLM_USD_CAP_DAY=1 \\
    bash "\$DIR_UNDER_TEST/bin/agent-call.sh" plan lproj claude-fable-5 60 "\$SENTINEL_DIR/child.txt" "build step" >/dev/null 2>&1
  echo "\$?" > "\$SENTINEL_DIR/child-rc"
fi
printf '{"result":"ok","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}\n'
EOF
  chmod +x "$T/fakebin/$R"
done
printf '#!/bin/bash\necho subscription\n' > "$T/fakebin/billing-mode.sh"; chmod +x "$T/fakebin/billing-mode.sh"
cp "$T/fakebin/billing-mode.sh" "$T/bin/billing-mode.sh"
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
chmod +x "$T/fakebin/timeout"

# The worker, faked at the seam agent-call sources. llm-spend answers PER LANE
# when the question names one ($T/spend-<lane>.json), and the stage's shared
# total ($T/spend-stage.json) when it does not — which is exactly what the
# gate asked before BH-2303.
cat > "$T/bin/jobs-client.sh" <<'EOF'
#!/bin/bash
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "${JOBS_REQ_LOG:-/dev/null}"
  case "$2" in
    /api/metrics/llm-spend*)
      local lane; lane=$(printf '%s' "$2" | sed -nE 's/.*[?&]lane=([^&]*).*/\1/p')
      if [ -n "$lane" ]; then cat "$SPEND_DIR/spend-$lane.json" 2>/dev/null || printf '{"usd":0,"calls":0,"refused":0}\n'
      else cat "$SPEND_DIR/spend-stage.json" 2>/dev/null || printf '{"usd":0,"calls":0,"refused":0}\n'; fi
      return 0 ;;
  esac
  return 1
}
EOF

# Two lanes on ONE stage — the shape that made the per-lane knobs dead.
cat > "$T/catalog/lanes.json" <<'EOF'
{ "version": 1, "lanes": [
  { "id": "review-prs", "name": "Review PRs", "scope": "project", "script": "bin/none.sh",
    "cadence": "*/5 * * * *", "boxes": ["hub"], "switch": { "kind": "flag", "name": "lane-off-review-prs", "aliases": [] },
    "wired": true, "knobs": [], "stats": { "cost_stage": "review", "lanes_row": false, "log": "logs/none.log" } },
  { "id": "review-autopilot", "name": "Review autopilot", "scope": "project", "script": "bin/none.sh",
    "cadence": "*/5 * * * *", "boxes": ["hub"], "switch": { "kind": "flag", "name": "lane-off-review-autopilot", "aliases": [] },
    "wired": true, "knobs": [], "stats": { "cost_stage": "review", "lanes_row": false, "log": "logs/none.log" } }
] }
EOF

run_call() { # run_call <env...> — the real agent-call, stage review; echoes rc
  rm -f "$T"/*-ran "$T/out.txt" "$T/jobs-req.log" "$T/vendor-env-lane" "$T/child-rc" "$T/child.txt"; : > "$T/logs/ALERTS.log"; rm -f "$T/logs/cost.csv"
  rm -rf "$T/state/lane-gate"
  ( export SENTINEL_DIR="$T" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" DIR_UNDER_TEST="$DIR" \
           JOBS_REQ_LOG="$T/jobs-req.log" SPEND_DIR="$T" LANE_REGISTRY="$T/catalog/lanes.json" \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" BEAT_LOG=/dev/null
    "$@" bash "$DIR/bin/agent-call.sh" review lproj claude-fable-5 60 "$T/out.txt" "hello" >/dev/null 2>&1 )
  echo $?
}
ran() { [ -f "$T/$1-ran" ]; }
lane_col() { awk -F, 'NR>1 && NF>=25 {print $25}' "$T/logs/cost.csv" 2>/dev/null | tail -1; }

# ── 1 + 2: review-prs is over its $1 cap; review-autopilot, same stage, spent nothing ──
printf '{"usd":7.5,"calls":30,"refused":0}\n' > "$T/spend-review-prs.json"
printf '{"usd":0,"calls":0,"refused":0}\n' > "$T/spend-review-autopilot.json"
printf '{"usd":7.5,"calls":30,"refused":0}\n' > "$T/spend-stage.json"
RC=$(run_call env AGENT_CALL_LANE=review-autopilot LLM_USD_CAP_DAY=1)
ran claude && ok || bad "1: review-autopilot was refused on review-prs's spend (rc $RC) — the cap bound the wrong lane"
grep -qE '/api/metrics/llm-spend\?[^ ]*lane=review-autopilot' "$T/jobs-req.log" 2>/dev/null && ok \
  || bad "2: the spend question does not name the lane: $(cat "$T/jobs-req.log" 2>/dev/null)"
[ "$(lane_col)" = review-autopilot ] && ok || bad "3: the row does not carry lane_id=review-autopilot: $(tail -1 "$T/logs/cost.csv" 2>/dev/null)"
RC=$(run_call env AGENT_CALL_LANE=review-prs LLM_USD_CAP_DAY=1)
ran claude && bad "1: review-prs ran past its own cap" || ok
[ "$RC" = 74 ] && ok || bad "1: the capped lane exited $RC, not 74"
grep -q 'refused:usd-cap-day' "$T/logs/cost.csv" 2>/dev/null && ok || bad "1: no refused row for review-prs's cap"
[ "$(lane_col)" = review-prs ] && ok || bad "3: the REFUSED row does not carry lane_id=review-prs: $(tail -1 "$T/logs/cost.csv" 2>/dev/null)"

# ── 3: no AGENT_CALL_LANE — the row carries the lane the gate resolved ──────
RC=$(run_call env)
ran claude && ok || bad "3: an unnamed call did not run (rc $RC)"
[ "$(lane_col)" = stage-review ] && ok || bad "3: an unnamed call on a shared stage must record the resolved lane stage-review: $(tail -1 "$T/logs/cost.csv" 2>/dev/null)"
[ "$(head -1 "$T/logs/cost.csv" | awk -F, '{print $25}')" = lane_id ] && ok \
  || bad "3: the cost.csv header does not name column 25 lane_id: $(head -1 "$T/logs/cost.csv")"

# A 24-column file (written before BH-2303) gets lane_id appended to its HEADER only.
# TEST-CHANGE BH-2537: 25 -> 26 (the upgrade now also appends guard_fp).
OLDHDR="ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note"
( export HARNESS="$T" COST="$T/logs/up.csv"; printf '%s\nold,row\n' "$OLDHDR" > "$COST"
  . "$DIR/bin/lib/cost-row.sh"; cost_append "new,row" )
[ "$(head -1 "$T/logs/up.csv")" = "$OLDHDR,lane_id,guard_fp" ] && [ "$(sed -n 2p "$T/logs/up.csv")" = "old,row" ] \
  && ok || bad "3: a 24-column cost.csv must gain lane_id on its header only: $(head -2 "$T/logs/up.csv")"

# ── 4: the push carries lane_id ────────────────────────────────────────────────
printf '%s,lane_id\n2026-09-25T00:00:00Z,h,lproj,review,claude,m,0,1,1,1,0,0,0.5,subscription,fp,acct,sid,transcript,,,,,,,review-prs\n' "$OLDHDR" > "$T/push.csv"
( . "$DIR/bin/lib/jobs/cost.sh" 2>/dev/null; _metric_cost_rows_chunk "$T/push.csv" 0 10 hub "$T/push.json" ) >/dev/null 2>&1
[ "$(jq -r '.rows[0].lane_id // empty' "$T/push.json" 2>/dev/null)" = review-prs ] && ok \
  || bad "4: the pushed row does not carry lane_id: $(cat "$T/push.json" 2>/dev/null | head -c 300)"

# ── 5: every lane-named LLM site sets AGENT_CALL_LANE in the script that runs it ──
# The script that RUNS the call is the site's own script, or — for a library
# (bin/lib/...) sourced into a lane — the lane's registry script.
REG=$(rendered_registry)
MISS=""
while IFS=$'\t' read -r id lane script; do
  [ -n "$lane" ] || continue
  runner="$script"
  case "$script" in bin/lib/*)
    runner=$(jq -r --arg l "$lane" '.lanes[]? | select(.id == $l) | .script // empty' "$REG" 2>/dev/null) ;;
  esac
  # A call that names its lane AT the call (`env AGENT_CALL_LANE=<lane> ...` in the
  # site's own script, as bin/lib/prebuild-repro/drive.sh does) counts too.
  grep -qE "(^|[[:space:]])AGENT_CALL_LANE=\"?$lane\"?([[:space:]]|$)" "$DIR/$script" 2>/dev/null && continue
  [ -n "$runner" ] && [ -f "$DIR/$runner" ] || { MISS="$MISS $id(no script)"; continue; }
  grep -qE "^[[:space:]]*export AGENT_CALL_LANE=\"?$lane\"?([[:space:]]|$)" "$DIR/$runner" \
    || MISS="$MISS $id($runner)"
done < <(jq -r '.sites[] | select((.through_agent_call // false) == true) | select((.lane // "") != "")
                  | [.id, .lane, (.script // "")] | @tsv' "$DIR/catalog/llm-sites.json")
[ -z "$MISS" ] && ok || bad "5: LLM sites whose lane never says its name (AGENT_CALL_LANE):$MISS"
# ...and every lane a site names is a REGISTRY lane: a name the registry does not
# carry has no knobs to bind (review of #2462: trap-eval).
UNREG=""
for l in $(jq -r '.sites[] | select((.lane // "") != "") | .lane' "$DIR/catalog/llm-sites.json" | sort -u); do
  jq -e --arg l "$l" '.lanes[]? | select(.id == $l)' "$REG" >/dev/null 2>&1 || UNREG="$UNREG $l"
done
[ -z "$UNREG" ] && ok || bad "5: catalog/llm-sites.json names lanes the registry does not carry:$UNREG"

# ── 6: the lane is this call's, never a child's ──────────────────────────────
# run-triage is over its $1 cap; the parent triage call runs ungated
# (LLM_GATE_DISABLE) and its "session" starts a build's plan call that inherits
# its environment, with the cap knob set for the build.
printf '{"usd":9,"calls":40,"refused":0}\n' > "$T/spend-run-triage.json"
printf '{"usd":0,"calls":0,"refused":0}\n' > "$T/spend-stage-plan.json"
RC=$(run_call env AGENT_CALL_LANE=run-triage LLM_GATE_DISABLE=1 CHILD_BUILD=1)
[ "$(head -1 "$T/vendor-env-lane" 2>/dev/null)" = "<unset>" ] && ok \
  || bad "6: the vendor CLI inherited AGENT_CALL_LANE='$(head -1 "$T/vendor-env-lane" 2>/dev/null)' — a session's children would all be that lane"
[ "$(cat "$T/child-rc" 2>/dev/null)" = 0 ] && ok \
  || bad "6: the build a triage session started was refused (rc $(cat "$T/child-rc" 2>/dev/null)) — run-triage's cap bound a build"
CHILD_LANE=$(awk -F, 'NR>1 && $4=="plan" {print $25}' "$T/logs/cost.csv" 2>/dev/null | tail -1)
[ -n "$CHILD_LANE" ] && [ "$CHILD_LANE" != run-triage ] && ok \
  || bad "6: the build's row must carry its own lane, never run-triage (got '$CHILD_LANE'): $(grep ',plan,' "$T/logs/cost.csv" 2>/dev/null | tail -1)"
PARENT_LANE=$(awk -F, 'NR>1 && $4=="review" {print $25}' "$T/logs/cost.csv" 2>/dev/null | tail -1)
[ "$PARENT_LANE" = run-triage ] && ok || bad "6: the parent's own row must still carry its lane run-triage (got '$PARENT_LANE')"
# bin/run-build.sh drops an inherited lane before anything else runs. The
# pipeline is read as ONE text through tests/lib/rb-all.sh (the rule every
# suite that reads run-build obeys, tests/rb-modules-source-test.sh).
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
RB_LANE=$(AGENT_CALL_LANE=run-triage bash -c 'eval "$(sed -n "1,/^unset AGENT_CALL_LANE\$/p" "$1" | grep -v "^set -")"; printf "%s" "${AGENT_CALL_LANE-<unset>}"' _ "$RB_ALL")
[ "$RB_LANE" = "<unset>" ] && ok || bad "6: bin/run-build.sh does not drop an inherited AGENT_CALL_LANE at entry (got '$RB_LANE')"

echo "llm-lane-id.bh-2303: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
