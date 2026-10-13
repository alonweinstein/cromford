#!/bin/bash
# tests/llm-gate-test.sh — BH-1141 phase 2. ONE gate, and it runs BEFORE the
# vendor call, not after it.
#
# WHY DRIVEN AND NOT GREPPED. The bug class this ticket exists to close is a
# guard that is in the file, reads correctly in review, and never fires: the
# project-4 Deepgram dedup ran 136 lines after the charge. So nothing below greps
# bin/agent-call.sh for a string. The real script runs against a scratch
# $HARNESS with fake CLIs on PATH, and what is asserted is whether the fake
# vendor process EXECUTED — the file it would have left behind — and what
# landed in logs/cost.csv.
#
# THE FIVE PROPERTIES:
#   1. unset is unlimited: with no knob anywhere, the lane runs exactly as it
#      runs today. A spend control that changes fleet behaviour the day it lands
#      is a fleet-wide behaviour change nobody decided on.
#   2. a disabled lane calls nothing and says so in the ledger.
#   3. a rung outside `runner_allowed` is never reached, so a cliff or a failure
#      on the standing lane cannot descend into a 100x one.
#   4. the daily USD cap is read from D1, not from the box's own cost.csv — a
#      local file is one box's share of a fleet-wide bill.
#   5. FAIL OPEN: an unreachable worker must not stop the fleet. Every lane runs
#      today with no gate at all, and that is what a failure degrades to.
#
# WHAT THIS DOES NOT PROVE: that the D1 aggregate is right. That is
# worker/jobs/test/llm-spend.test.js and, in the end, the deploy's own smoke run.
#
# Run from anywhere:  bash tests/llm-gate-test.sh   (exit 0 = all pass)
# As root next to a live harness: HARNESS_TEST_SANDBOX=1 bash tests/…
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1510.1: agent-call reads its ladders from model_routes; this worker-less box carries the resolver's cache of #1507's table.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$T" gateproj gatefilt otherproj
# BH-1247: catalog/lanes.json and cron/<box>.cron are GENERATED and not
# committed. rendered_registry / rendered_cron render this repo's own into $T.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
# The REAL registry, rendered once: the two probes below run in subshells, and
# a $(rendered_registry) inside each would render it again per invocation.
REAL_REG=$(rendered_registry)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/logs" "$T/locks" "$T/flags" "$T/state" "$T/fakebin" "$T/bin" "$T/catalog"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T" || exit 1  # BH-1510.2: lanes read models from model_routes

# ── the fakes ────────────────────────────────────────────────────────────────
# Each vendor CLI leaves a file behind when it runs. That file — not a log line,
# not a grep of the source — is the evidence for "was the money spent".
for R in claude codex grok gemini; do
  cat > "$T/fakebin/$R" <<EOF
#!/bin/bash
touch "\$SENTINEL_DIR/$R-ran"
if [ -n "\${FAKE_CLI_FAIL:-}" ]; then echo "boom" >&2; exit 1; fi
printf '{"result":"ok","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}\n'
EOF
  chmod +x "$T/fakebin/$R"
done
printf '#!/bin/bash\necho subscription\n' > "$T/fakebin/billing-mode.sh"; chmod +x "$T/fakebin/billing-mode.sh"
# GNU timeout does not exist on macOS and agent-call wraps every runner in it.
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
chmod +x "$T/fakebin/timeout"
cp "$T/fakebin/billing-mode.sh" "$T/bin/billing-mode.sh"

# The coordination client, faked at the seam agent-call already sources. Every
# request is logged so a test can assert WHICH question the gate asked, and the
# llm-spend answer is a file so a test can make the worker unreachable by
# removing it — the fail-open case.
cat > "$T/bin/jobs-client.sh" <<'EOF'
#!/bin/bash
_jobs_req() { # _jobs_req <method> <path> [body]
  printf '%s %s\n' "$1" "$2" >> "${JOBS_REQ_LOG:-/dev/null}"
  case "$2" in
    /api/metrics/llm-spend*)
      [ -r "${SPEND_REPLY:-/nonexistent}" ] || return 1
      cat "$SPEND_REPLY"; return 0 ;;
  esac
  return 1
}
EOF

# A registry with one lane whose cost signature is (triage, gateproj), so the
# lane resolver has something real to resolve and the spend query has a filter.
cat > "$T/catalog/lanes.json" <<'EOF'
{
  "version": 1,
  "lanes": [
    { "id": "gate-lane", "name": "Gate lane", "scope": "project", "script": "bin/none.sh",
      "cadence": "*/5 * * * *", "boxes": ["hub"],
      "switch": { "kind": "flag", "name": "lane-off-gate-lane", "aliases": [] },
      "wired": true, "knobs": [],
      "stats": { "cost_stage": "triage", "cost_project_filter": "gateproj",
                 "lanes_row": false, "log": "logs/none.log" } }
  ]
}
EOF

# The (stage, project) every run_call makes its call as, and the registry it
# resolves against. Both are variables rather than literals because case 9 has
# to drive a SECOND signature against a SECOND registry to prove the resolver
# picks the right lane — and a resolver that picks the wrong lane is a cap
# nobody can set.
CALL_STAGE=triage; CALL_PROJECT=gateproj; CALL_REGISTRY="$T/catalog/lanes.json"
# The fleet pager, stubbed at the path agent-call calls it by. A survival-lane
# beat is a Telegram page, so "was beat.sh called" is the assertion for "did a
# rung nobody engaged wake somebody up".
cat > "$T/bin/beat.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "${1:-}" >> "$BEAT_LOG"
EOF
chmod +x "$T/bin/beat.sh"

run_call() { # run_call <env assignments...> ; echoes rc. Clears every sentinel.
  rm -f "$T"/*-ran "$T/out.txt" "$T/out.txt.err" "$T/jobs-req.log" "$T/beat.log"
  : > "$T/logs/ALERTS.log"; : > "$T/logs/failovers.log"
  : > "$T/logs/cost.csv.new" 2>/dev/null; rm -f "$T/logs/cost.csv"
  rm -rf "$T/state/lane-gate"
  ( export SENTINEL_DIR="$T" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           JOBS_REQ_LOG="$T/jobs-req.log" BEAT_LOG="$T/beat.log" \
           LANE_REGISTRY="$CALL_REGISTRY" \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json"
    "$@" bash "$DIR/bin/agent-call.sh" "$CALL_STAGE" "$CALL_PROJECT" claude-fable-5 60 "$T/out.txt" "hello" \
      >/dev/null 2>&1 )
  echo $?
}

ran() { [ -f "$T/$1-ran" ]; }
# `grep -c` prints 0 AND exits 1 on no match, so a `|| echo 0` fall-through
# would print TWO lines and every numeric comparison after it would be a syntax
# error rather than a verdict.
refused_rows() {
  if [ -r "$T/logs/cost.csv" ]; then grep -c ',refused,' "$T/logs/cost.csv" 2>/dev/null || true
  else echo 0; fi
}

# ── 1. unset is unlimited ────────────────────────────────────────────────────
RC=$(run_call env)
ran claude && ok || bad "1: with no knob set the claude lane did not run (rc=$RC) — the gate is not additive"
[ "$RC" = 0 ] && ok || bad "1: an ungated call exited $RC"
[ "$(refused_rows)" = 0 ] && ok || bad "1: an ungated call wrote a refused row"

# ── 2. a disabled lane calls nothing ─────────────────────────────────────────
RC=$(run_call env LLM_LANE_ENABLED=0)
ran claude && bad "2: LLM_LANE_ENABLED=0 still executed the claude CLI — the refusal is decorative and the money is spent" || ok
[ "$RC" = 74 ] && ok || bad "2: a disabled lane exited $RC, not 74 — rc 74 is agent-call's before-billing family, and a caller that reads rc 2 as a billed death charges its cap for a call that never happened"
grep -q 'AGENT_CALL_REFUSED' "$T/out.txt" 2>/dev/null && ok \
  || bad "2: \$OUT carries no refusal marker — a caller reading it on a nonzero rc reads whatever was there before"
# ...and $OUT.err too. The per-rung refusal tees to both; a caller that reads the
# error file on a nonzero rc must not be handed the previous attempt's text.
grep -q 'AGENT_CALL_REFUSED' "$T/out.txt.err" 2>/dev/null && ok \
  || bad "2: \$OUT.err carries no refusal marker — the two refusal paths are not symmetric"
[ "$(refused_rows)" -ge 1 ] && ok \
  || bad "2: no refused cost row — a refusal that leaves no row is indistinguishable from a lane nobody asked to run"
# ...and the row costs exactly 0, never blank: a blank cost_usd is what the
# pricing-parity lane pages on, and a refusal has nothing to price.
awk -F, '$18=="refused"{ if ($13 != "0" && $13 != "0.00") bad=1 } END{exit bad?1:0}' "$T/logs/cost.csv" \
  && ok || bad "2: the refused row's cost_usd is not 0: $(grep ',refused,' "$T/logs/cost.csv" | head -1)"
grep -q 'refused:lane-disabled' "$T/logs/cost.csv" 2>/dev/null && ok \
  || bad "2: the refused row does not carry the reason: $(grep ',refused,' "$T/logs/cost.csv" | head -1)"

# ── 3. a rung outside runner_allowed is never reached ────────────────────────
# The claude lane FAILS, so today's ladder would descend to grok tier-2 and then
# to the survival lanes. With the lane's allowed list naming claude only, none
# of them may be called — and each refusal is a row, so the descent that did not
# happen is visible rather than inferred from an absence.
mkdir -p "$T/.grok/bin"; cp "$T/fakebin/grok" "$T/.grok/bin/grok"
RC=$(run_call env FAKE_CLI_FAIL=1 LLM_RUNNER_ALLOWED=claude \
      XAI_API_KEY=x OPENROUTER_API_KEY=x FIREWORKS_API_KEY=x)
ran claude && ok || bad "3: the allowed runner was not even tried"
ran grok  && bad "3: grok ran although the lane's runner_allowed is 'claude' — the 100x descent this ticket exists to stop" || ok
ran codex && bad "3: codex ran although the lane's runner_allowed is 'claude'" || ok
[ "$RC" != 0 ] && ok || bad "3: a call whose only allowed rung failed reported success"
grep -q 'refused:runner-not-allowed' "$T/logs/cost.csv" 2>/dev/null && ok \
  || bad "3: no refused row names the rung that was refused; rows: $(cat "$T/logs/cost.csv" 2>/dev/null | tail -3)"

# ── 3b. A BILLED PRIMARY FOLLOWED BY REFUSED DESCENTS (round-2 review, B1) ───
# The case above is green whichever way this goes, because it only asks whether
# the lower rungs RAN. This one asks what the CALL then reports, and it is the
# shape the fix round created: claude ran, failed and was BILLED; grok,
# OpenRouter and Fireworks were refused. If the script exits 74 — the
# before-billing code — then bin/alert-triage.sh re-spools and re-buys the same
# billed failure every tick, bin/review-autopilot.sh charges no cap and buys the
# same review every tick, and preplan does not count the attempt. An unbounded
# billed retry loop, built by the spend guard.
#
# The same run is asserted three ways because it broke three ways: the rc, the
# output file, and the pager.
[ "$RC" = 1 ] && ok \
  || bad "3b: a ladder whose PRIMARY ran, failed and was billed exited $RC — 74 means 'nothing was called and nothing was billed', so every caller taught that family retries a billed failure at full price, every tick"
grep -q 'boom' "$T/out.txt" 2>/dev/null && ok \
  || bad "3b: \$OUT no longer holds the primary's error text — a refusal of a rung that never ran overwrote the only evidence of why the billed call died: $(head -1 "$T/out.txt" 2>/dev/null)"
! grep -qE 'tier-3|SURVIVAL LANE|LAST RESORT' "$T/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "3b: the survival lanes paged for rungs the gate then refused: $(grep -E 'tier-3|SURVIVAL|LAST RESORT' "$T/logs/ALERTS.log" | head -2)"
[ ! -s "$T/beat.log" ] && ok \
  || bad "3b: beat.sh was called ('check account credits/limits' to Telegram) for a rung the lane's own control refuses: $(head -1 "$T/beat.log")"
# ...and the refusals are still in the ledger and the log. Not paging is not the
# same as not recording: the descent that did not happen stays a fact.
[ "$(refused_rows)" -ge 2 ] && ok \
  || bad "3b: the refused descents left no rows — the exit rc is right but the record is gone"
grep -q 'GATE REFUSED rung' "$T/logs/failovers.log" 2>/dev/null && ok \
  || bad "3b: no GATE REFUSED line in failovers.log for the refused rungs"
grep -q 'RAN and was billed' "$T/logs/failovers.log" 2>/dev/null && ok \
  || bad "3b: failovers.log does not say that the exit rc came from the billed attempt rather than the refusal"

# ...and the negative: when NOTHING ran, 74 still reaches the caller and the
# marker is still what $OUT holds. Case 2 pins the disabled lane; this pins the
# same rule for a runner list that refuses the FIRST rung, which is the only
# state in which "nothing was called and nothing was billed" is true.
RC=$(run_call env LLM_RUNNER_ALLOWED=nothing-at-all \
      XAI_API_KEY=x OPENROUTER_API_KEY=x FIREWORKS_API_KEY=x)
ran claude && bad "3c: the primary ran although no rung is allowed" || ok
[ "$RC" = 74 ] && ok \
  || bad "3c: a ladder on which nothing ran exited $RC, not 74 — the callers cannot tell a free refusal from a billed death"
grep -q 'AGENT_CALL_REFUSED' "$T/out.txt" 2>/dev/null && ok \
  || bad "3c: \$OUT carries no refusal marker although nothing ever wrote to it"

# ...and the SAME failure with no allowed-list set still descends, exactly as
# it does today. The negative is what proves the control is a control and not a
# blanket stop.
RC=$(run_call env FAKE_CLI_FAIL=1 XAI_API_KEY=x OPENROUTER_API_KEY=x FIREWORKS_API_KEY=x)
ran grok && ok || bad "3d: with no runner_allowed set the ladder stopped descending — the gate changed default behaviour"

# ── 4. the daily cap is read from D1, and refuses BEFORE the call ────────────
printf '{"usd":5.2,"calls":9,"refused":0}\n' > "$T/spend.json"
RC=$(run_call env LLM_USD_CAP_DAY=1 SPEND_REPLY="$T/spend.json")
ran claude && bad "4: the cap did not stop the call — the money is spent and the guard ran after it" || ok
[ "$RC" = 74 ] && ok || bad "4: a capped call exited $RC, not 74"
grep -q 'refused:usd-cap-day' "$T/logs/cost.csv" 2>/dev/null && ok \
  || bad "4: no refused row for the cap: $(cat "$T/logs/cost.csv" 2>/dev/null | tail -2)"
grep -qE '/api/metrics/llm-spend\?[^ ]*stage=triage' "$T/jobs-req.log" 2>/dev/null && ok \
  || bad "4: the gate never asked D1 for the day's spend: $(cat "$T/jobs-req.log" 2>/dev/null)"
grep -qE '/api/metrics/llm-spend\?[^ ]*since=[0-9]{4}-[0-9]{2}-[0-9]{2}T00:00:00Z' "$T/jobs-req.log" 2>/dev/null && ok \
  || bad "4: the spend window is not this UTC day: $(cat "$T/jobs-req.log" 2>/dev/null)"

# ...and a cap ABOVE the day's spend lets the call through.
printf '{"usd":0.20,"calls":2,"refused":0}\n' > "$T/spend-low.json"
RC=$(run_call env LLM_USD_CAP_DAY=10 SPEND_REPLY="$T/spend-low.json")
ran claude && ok || bad "4b: a cap the lane is nowhere near still refused the call"

# ── 4c. the (LANE, PROJECT) ceiling is a SECOND cap, from a settings row ─────
# The issue asks for a cap "per lane and per (lane, project)". lane_knob walks
# up from the project key to the lane key, which is right for a knob and wrong
# for a second ceiling: inheriting the lane's $10 as the project's would mean
# "$10 per project" without anybody writing that row. So the project scope reads
# its OWN key and nothing else — and this case is what proves the key it reads
# is the one bin/harness-ctl.sh and the console write (BH-1132's lesson: one
# knob, two spellings, and nothing errored anywhere).
#
# The clock is pinned on BOTH libraries so the settings cache reads as fresh
# without this suite ever asking the wall what time it is.
PINNED=1789000000   # determinism: ok a fixed epoch, the only time this file knows
jq -nc --arg k "lane.gate-lane.gateproj.llm_usd_cap_day" --argjson f "$PINNED" \
  '{fetched_at:$f, values:{($k):"1"}}' > "$T/state/settings-cache.json"
RC=$(run_call env SPEND_REPLY="$T/spend.json" LANE_GATE_NOW="$PINNED" LLM_GATE_NOW="$PINNED")
ran claude && bad "4c: the (lane, project) cap did not stop the call" || ok
grep -q 'lane+project' "$T/logs/cost.csv" 2>/dev/null && ok \
  || bad "4c: the refusal does not name the (lane, project) scope: $(grep ',refused,' "$T/logs/cost.csv" 2>/dev/null | head -1)"
grep -qE 'llm-spend\?project=gateproj' "$T/jobs-req.log" 2>/dev/null && ok \
  || bad "4c: the project-scope cap did not ask D1 for THIS project's spend: $(cat "$T/jobs-req.log" 2>/dev/null)"
# ...and a LANE row is never read as the project's ceiling.
jq -nc --arg k "lane.gate-lane.llm_usd_cap_day" --argjson f "$PINNED" \
  '{fetched_at:$f, values:{($k):"1000"}}' > "$T/state/settings-cache.json"
RC=$(run_call env SPEND_REPLY="$T/spend.json" LANE_GATE_NOW="$PINNED" LLM_GATE_NOW="$PINNED")
ran claude && ok \
  || bad "4d: a lane cap of \$1000 refused a \$5.20 day — the lane row is being read as the project's ceiling too"
rm -f "$T/state/settings-cache.json"

# ── 5. the cap reads D1, never the box's own cost.csv ────────────────────────
# A local csv holding $900 with the worker answering $0.20 must NOT refuse: one
# box's file is one box's share of a fleet-wide bill, and a cap that reads it
# stops the wrong lane on the wrong box.
cat > "$T/seed-cost.csv" <<'EOF'
ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note
2026-09-20T01:00:00Z,box,gateproj,triage,claude,claude-fable-5,0,10,1,1,0,0,900.00,metered,none,unknown,,result,900.00,,,,,
EOF
rm -f "$T"/*-ran "$T/jobs-req.log"
( export SENTINEL_DIR="$T" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
         JOBS_REQ_LOG="$T/jobs-req.log" LANE_REGISTRY="$T/catalog/lanes.json" \
         CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" \
         LLM_USD_CAP_DAY=10 SPEND_REPLY="$T/spend-low.json"
  cp "$T/seed-cost.csv" "$T/logs/cost.csv"
  bash "$DIR/bin/agent-call.sh" triage gateproj claude-fable-5 60 "$T/out.txt" "hello" >/dev/null 2>&1 )
ran claude && ok \
  || bad "5: a \$900 row in the box's own logs/cost.csv refused a call the fleet ledger says cost \$0.20 — the cap is reading the local file"

# ── 6. FAIL OPEN when D1 cannot answer ───────────────────────────────────────
RC=$(run_call env LLM_USD_CAP_DAY=1 SPEND_REPLY="$T/nonexistent.json")
ran claude && ok \
  || bad "6: an unreachable worker stopped the lane. Every lane in this fleet runs today with no gate at all; that is what a failure has to degrade to."
[ "$RC" = 0 ] && ok || bad "6: the fail-open call exited $RC"
grep -q 'llm-gate' "$T/logs/lane-gate.log" 2>/dev/null && ok \
  || bad "6: failing open is silent — nothing in logs/lane-gate.log says the cap could not be read"

# ── 7. the escape hatch ──────────────────────────────────────────────────────
# LLM_GATE_DISABLE=1 restores the previous invocation verbatim. If this file is
# ever the thing that is wrong, an operator needs one line that turns it off.
RC=$(run_call env LLM_LANE_ENABLED=0 LLM_GATE_DISABLE=1)
ran claude && ok || bad "7: LLM_GATE_DISABLE=1 did not turn the gate off"

# ── 8. the library is fail-open by construction ──────────────────────────────
# Sourced with no worker, no registry and no lane-gate, every entry point must
# still answer "allow" rather than error under `set -u`.
( set -u
  HARNESS="$T/empty"; export HARNESS
  # shellcheck source=/dev/null
  . "$DIR/bin/lib/llm-gate.sh" 2>/dev/null || exit 3
  llm_gate_precall triage someproj || exit 4
  llm_gate_runner_ok triage someproj grok || exit 5
) && ok || bad "8: bin/lib/llm-gate.sh does not fail open when sourced with nothing around it (rc=$?)"

# ── 9. the lane resolver: a FILTERED lane wins over the null-filter one ──────
# THE BUG THIS CASE EXISTS FOR (round-1 review, B1). The first draft matched
# `cost_stage == stage AND (filter == null OR filter == project)`, so
# `run-triage` (stage=triage, no filter) collided with every filtered triage
# lane and `(triage, alert-triage)` resolved to a synthetic `stage-triage` id
# nobody can address. A `lane.alert-triage.llm_usd_cap_day` row was never read,
# nothing was logged, and the lane the $793 was spent on could not be capped.
# The suite was green because its registry held ONE lane.
cat > "$T/catalog/lanes-two.json" <<'EOF'
{
  "version": 1,
  "lanes": [
    { "id": "gate-null", "name": "Stage lane", "scope": "project", "script": "bin/none.sh",
      "cadence": "*/5 * * * *", "boxes": ["hub"],
      "switch": { "kind": "flag", "name": "lane-off-gate-null", "aliases": [] },
      "wired": true, "knobs": [],
      "stats": { "cost_stage": "triage", "cost_project_filter": null,
                 "lanes_row": false, "log": "logs/none.log" } },
    { "id": "gate-filt", "name": "Filtered lane", "scope": "hub", "script": "bin/none.sh",
      "cadence": "*/5 * * * *", "boxes": ["hub"],
      "switch": { "kind": "flag", "name": "lane-off-gate-filt", "aliases": [] },
      "wired": true, "knobs": [],
      "stats": { "cost_stage": "triage", "cost_project_filter": "gatefilt",
                 "lanes_row": false, "log": "logs/none.log" } }
  ]
}
EOF
PINNED9=1789000000
CALL_REGISTRY="$T/catalog/lanes-two.json"
jq -nc --arg k "lane.gate-filt.llm_usd_cap_day" --argjson f "$PINNED9" \
  '{fetched_at:$f, values:{($k):"1"}}' > "$T/state/settings-cache.json"
CALL_PROJECT=gatefilt
RC=$(run_call env SPEND_REPLY="$T/spend.json" LANE_GATE_NOW="$PINNED9" LLM_GATE_NOW="$PINNED9")
ran claude && bad "9: a cap row written on the FILTERED lane did not stop its own call — the call resolved to some other lane's id, which is the \$793 lane's cap silently never firing" || ok
grep -q 'lane=gate-filt' "$T/logs/cost.csv" 2>/dev/null && ok \
  || bad "9: the refusal does not name the filtered lane: $(grep ',refused,' "$T/logs/cost.csv" 2>/dev/null | head -1)"
# ...and the NEGATIVE: the null-filter lane of the same stage is a different
# lane and its call must go through. A resolver that fixed the first assertion
# by handing every triage call to the filtered lane would be worse.
CALL_PROJECT=otherproj
jq -nc --arg k "lane.gate-filt.llm_usd_cap_day" --argjson f "$PINNED9" \
  '{fetched_at:$f, values:{($k):"1"}}' > "$T/state/settings-cache.json"
RC=$(run_call env SPEND_REPLY="$T/spend.json" LANE_GATE_NOW="$PINNED9" LLM_GATE_NOW="$PINNED9")
ran claude && ok \
  || bad "9b: the filtered lane's cap refused a call that belongs to the null-filter lane of the same stage"
rm -f "$T/state/settings-cache.json"
CALL_PROJECT=gateproj; CALL_REGISTRY="$T/catalog/lanes.json"

# ...and against the REAL registry, which is the key production actually uses.
probe_lane() { ( export HARNESS="$T" LANE_REGISTRY="$REAL_REG"
  # shellcheck source=/dev/null
  . "$DIR/bin/lib/llm-gate.sh" 2>/dev/null || exit 1
  llm_gate_lane_id "$1" "$2" ); }
while IFS='|' read -r st pj want; do
  [ -n "$st" ] || continue
  got=$(probe_lane "$st" "$pj")
  [ "$got" = "$want" ] && ok \
    || bad "9c: ($st, $pj) resolves to '$got', not '$want' — a knob set on '$want' is read from '$got'"
done <<'EOF'
triage|alert-triage|alert-triage
triage|medic|alerts-medic
triage|responder|watchdog-responder
triage|project-1|run-triage
review|cromford|stage-review
EOF

# ── 10. the knob is settable through the DOCUMENTED surface ─────────────────
# `bin/harness-ctl.sh set <lane> LLM_USD_CAP_DAY <n>` is what the lane doc, the
# GATE REFUSED line in logs/failovers.log and the PR body all tell an operator
# to run. It is refused with `no knob` unless the lane declares it in
# catalog/lanes.json — so the registry, not the gate, is where a cap that cannot
# be set dies.
cat >> "$T/bin/jobs-client.sh" <<'EOF'
JOBS_BOX=test
_setting_key_ok() { case "${1:-}" in ''|*[!a-z0-9_.-]*) return 1 ;; esac; [ "${#1}" -le 64 ]; }
setting_set() { _setting_key_ok "${1:-}" || return 1; printf 'SET %s = %s\n' "$1" "$2" >> "${SETTING_LOG:-/dev/null}"; }
EOF
# `set … <project>` refuses a project fleet.conf does not list (BH-1985); the
# fixture is outside $T, through FLEET_CONF, which only `set` reads.
printf 'project-1 example-org/project-1 x\n' > "$T/fleet-set.conf"
ctl() { ( export HARNESS="$T" LANE_REGISTRY="$REAL_REG" FLEET_CONF="$T/fleet-set.conf" \
                 SETTING_LOG="$T/settings.log" PATH="$T/fakebin:$PATH"
  bash "$DIR/bin/harness-ctl.sh" "$@" 2>&1 ); }
while IFS='|' read -r lane knob val proj want; do
  [ -n "$lane" ] || continue
  : > "$T/settings.log"
  OUT=$(ctl set "$lane" "$knob" "$val" $proj); RC=$?
  if [ "$RC" = 0 ] && grep -qF "SET $want = $val" "$T/settings.log"; then ok
  else bad "10: harness-ctl.sh set $lane $knob $val $proj -> rc=$RC ${OUT:-no output}; expected the row $want"
  fi
done <<'EOF'
alert-triage|LLM_USD_CAP_DAY|25||lane.alert-triage.llm_usd_cap_day
alert-triage|LLM_LANE_ENABLED|0||lane.alert-triage.llm_lane_enabled
alert-triage|LLM_RUNNER_ALLOWED|claude||lane.alert-triage.llm_runner_allowed
alerts-medic|LLM_USD_CAP_DAY|10||lane.alerts-medic.llm_usd_cap_day
watchdog-responder|LLM_USD_CAP_DAY|10||lane.watchdog-responder.llm_usd_cap_day
review-autopilot|LLM_USD_CAP_DAY|10||lane.review-autopilot.llm_usd_cap_day
run-triage|LLM_USD_CAP_DAY|5|project-1|lane.run-triage.project-1.llm_usd_cap_day
EOF

# ── 11. a refusal is rc 74, and no call site reads it as a billed death ──────
# #1141's own words: "refusals … indistinguishable from billed failures at some
# call sites (#1046, #1066)". A gate that adds a NEW refusal and leaves it
# looking like a death charges a daily cap for a call nobody made and never
# retries the work once the lane is turned back on. Each assertion below runs
# the SHIPPED lines, not a copy of them.
( # shellcheck source=/dev/null
  . "$DIR/bin/lib/preplan-lib.sh" 2>/dev/null || exit 3
  preplan_rc_billed 74 && exit 4          # rc 0 from the predicate = "billed"
  preplan_rc_billed 1  || exit 5 ) && ok \
  || bad "11: bin/lib/preplan-lib.sh counts a gated refusal (rc 74) as a billed attempt — three refused ticks and every pre-plan key is terminal for the day"

# bin/review-autopilot.sh's own case block, lifted verbatim and driven with
# AC_RC=74. The before-billing branch `continue`s before it touches either file;
# the billed branch writes both.
{
  echo '#!/bin/bash'
  echo 'set -uo pipefail'
  echo 'STAMP(){ printf T; }; ap_attempts(){ echo 0; }'
  echo 'LOG=/dev/null; P=p; NUM=1; HEAD12=hhhhhhhhhhhh; AC_MARK=marker; CAP=9; FAIL_TRIES=2; CNT=0'
  printf 'CNTF="%s"; KEY="%s"\n' "$T/ap-cnt" "$T/ap-key"
  echo 'for AC_RC in 74; do'
  sed -n '/^    case "\$AC_RC" in$/,/^    esac$/p' "$DIR/bin/review-autopilot.sh"
  echo 'done'
} > "$T/ap-probe.sh"
rm -f "$T/ap-cnt" "$T/ap-key"
bash "$T/ap-probe.sh" >/dev/null 2>&1
{ [ ! -s "$T/ap-cnt" ] && [ ! -s "$T/ap-key" ]; } && ok \
  || bad "11b: review-autopilot charges its daily cap and writes a terminal key for a call the gate refused (cap=$(cat "$T/ap-cnt" 2>/dev/null) key=$(cat "$T/ap-key" 2>/dev/null))"

# ...and bin/alert-triage.sh's refusal block, lifted the same way. A gated
# family must go back on the spool with its pre-tick stamp: the lane is off, the
# alerts are not triaged, and consuming them would lose them silently.
{
  echo '#!/bin/bash'
  echo 'set -uo pipefail'
  echo 'STAMP(){ printf T; }'
  printf 'DEFER_SPOOL="%s"; LOG=/dev/null; OUT="%s"; FKEY=fam; FCOUNT=2\n' "$T/at-spool" "$T/at-out"
  printf 'triage_restore_stamp(){ printf %%s "$1" > "%s"; }\n' "$T/at-stamp"
  echo "FROWS=\$'a\tb\tkept-line\n'"
  echo 'for ARC in 74; do'
  sed -n '/^  # >>> llm-gate-refusal$/,/^  # <<< llm-gate-refusal$/p' "$DIR/bin/alert-triage.sh"
  echo 'echo REACHED_THE_SESSION_BODY; done'
} > "$T/at-probe.sh"
rm -f "$T/at-spool" "$T/at-stamp"; : > "$T/at-out"
AT=$(bash "$T/at-probe.sh" 2>/dev/null)
case "$AT" in *REACHED_THE_SESSION_BODY*)
  bad "11c: bin/alert-triage.sh treats a gated refusal as a triaged session — the family's stamp is consumed and its alert lines are gone" ;;
  *) ok ;;
esac
grep -q 'kept-line' "$T/at-spool" 2>/dev/null && ok \
  || bad "11c: the refused family was not re-spooled — its alert lines are lost until somebody reads the log"
[ -s "$T/at-stamp" ] && ok \
  || bad "11c: the refused family's pre-tick stamp was not restored, so the next tick will skip it"


# ── 12. a refused medic consumes nothing ────────────────────────────────────
# THE LOSS THIS CLOSES (round-2 review, I4). bin/alerts-medic.sh is one of the
# eleven lanes this ticket declares LLM_LANE_ENABLED / LLM_RUNNER_ALLOWED /
# LLM_USD_CAP_DAY on — and its SEEN list is a one-way door: an id written there
# is filtered out of every later pass for as long as it sits in the 500-line
# window. The file's own doctrine is "not consuming an alert is how it comes
# back", but the write ran regardless of the rc, so turning this lane off for an
# afternoon threw away every alert that arrived during it. Exactly the loss the
# fix round closed one lane over, in bin/alert-triage.sh.
#
# Driven against the REAL bin/alerts-medic.sh with its harness root rewritten,
# the way tests/lane-day-cap.bh-1039-test.sh drives it: only agent-call (the rc
# under test) and the things that leave the machine are stubbed.
HM="$T/hm"
mkdir -p "$HM/bin" "$HM/logs" "$HM/state" "$HM/locks" "$HM/env" "$HM/flags" "$T/stubm"
printf 'CONSOLE_URL=https://console.invalid\nHARNESS_SECRET=testsecret\n' > "$HM/env/global.env"
sed "s|/root/harness|$HM|g" "$DIR/bin/alerts-medic.sh" > "$HM/bin/alerts-medic.sh"
chmod +x "$HM/bin/alerts-medic.sh"
for s in triage-map.sh fleet-conf.sh box-for.sh alert_family.py; do ln -sf "$DIR/bin/$s" "$HM/bin/$s"; done
ln -sfn "$DIR/bin/lib" "$HM/bin/lib"
model_routes_fixture "$HM" || exit 1
printf '#!/bin/sh\nexit 0\n' > "$HM/bin/alerts-groom.sh"; chmod +x "$HM/bin/alerts-groom.sh"
# The rc is the whole test: 74 is agent-call's gated refusal, and this stub
# writes the same one-line marker the real refusal leaves in $OUT.
cat > "$HM/bin/agent-call.sh" <<'STUB'
#!/bin/bash
echo "AGENT_CALL_REFUSED llm-gate lane-disabled alerts-medic" > "$5"
exit "${STUB_RC:-74}"
STUB
chmod +x "$HM/bin/agent-call.sh"
cat > "$T/stubm/curl" <<STUB
#!/bin/sh
cat "$T/alerts.json"
STUB
chmod +x "$T/stubm/curl"
printf '#!/bin/sh\nexit 0\n' > "$T/stubm/flock"; chmod +x "$T/stubm/flock"
printf '{"alerts":[{"id":"alert-m1","createdAt":"2026-08-25T00:00:00Z","line":"the widget subsystem is unhappy"}]}\n' > "$T/alerts.json"
: > "$HM/state/medic-seen.txt"; echo '{}' > "$HM/state/medic-families.json"
echo '{}' > "$HM/state/medic-parked.json"; : > "$HM/logs/medic.log"
# BH-5942: the medic runs per project; a row with no project is the cromford run's.
MS="$HM/state/alerts-medic/cromford"; scratch_rm "$MS"
( export FLEET_CONF="$DIR/fleet.conf" PATH="$T/stubm:$PATH"
  bash "$HM/bin/alerts-medic.sh" cromford >/dev/null 2>&1 )
[ ! -s "$MS/medic-seen.txt" ] && ok \
  || bad "12: a medic session the gate REFUSED marked its alerts seen anyway ($(tr '\n' ' ' < "$MS/medic-seen.txt")) — the lane was off, nothing read them, and the SEEN list is a one-way door"
[ "$(jq -r 'length' "$MS/medic-families.json" 2>/dev/null)" = 0 ] && ok \
  || bad "12: the refused family kept its 6h brake stamp, so it comes back in six hours rather than next pass: $(cat "$MS/medic-families.json")"
grep -q 'NOT RUN' "$HM/logs/medic.log" 2>/dev/null && ok \
  || bad "12: the lane log does not say the pass made no call: $(cat "$HM/logs/medic.log")"
# ...and the NEGATIVE: a session that really ran still consumes its family, or
# the medic would re-investigate the same alerts for ever.
: > "$HM/state/medic-seen.txt"; echo '{}' > "$HM/state/medic-families.json"; : > "$HM/logs/medic.log"; scratch_rm "$MS"
( export FLEET_CONF="$DIR/fleet.conf" PATH="$T/stubm:$PATH" STUB_RC=0
  bash "$HM/bin/alerts-medic.sh" cromford >/dev/null 2>&1 )
grep -q 'alert-m1' "$MS/medic-seen.txt" 2>/dev/null && ok \
  || bad "12b: a session that RAN did not consume its family — the medic would re-buy the same investigation every pass"

echo "llm-gate: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
