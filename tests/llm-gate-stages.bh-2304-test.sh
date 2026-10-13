#!/bin/bash
# tests/llm-gate-stages.bh-2304-test.sh — BH-2304. The LLM gate resolves a
# call's lane from the REAL composed registry (catalog/lanes.d rendered by
# bin/lanes-build.sh), and a lane registered with several stages is one budget.
#
# WHY. postmerge-qa registered cost_stage=fix but calls agent-call.sh with
# `prodqa`; run-product registered `plan` but calls map/signals/ideate/synth.
# So `lane.postmerge-qa.llm_usd_cap_day` never applied to a postmerge-qa call,
# and the same row (and LLM_LANE_ENABLED=0) was read for every run-build `fix`
# round instead. This suite drives llm_gate_precall — the function
# bin/agent-call.sh calls before every rung — against the registry the fleet
# actually renders, with the worker's spend endpoint stubbed at `_jobs_req`.
#
#   bash tests/llm-gate-stages.bh-2304-test.sh          exit 0 = pass
# As root next to a live harness: HARNESS_TEST_SANDBOX=1 bash tests/…
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# The registry the fleet renders, not a hand-made one.
cp -r "$DIR/catalog" "$T/"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$T" --write >/dev/null 2>&1 \
  || { echo "FAIL: bin/lanes-build.sh could not render the registry into $T"; exit 1; }
REG="$T/catalog/lanes.json"
mkdir -p "$T/h/state" "$T/h/logs" "$T/spend"

PINNED=1789000000   # determinism: ok a fixed epoch, the only time this file knows

# gate <stage> <project> [NAME=value ...] — runs llm_gate_precall in a clean
# shell against $REG and prints "<rc>|<LLM_GATE_REASON>". The stub answers
# /api/metrics/llm-spend from $T/spend/<stage>.json (missing file = the worker
# did not answer) and logs every request path to $T/req.log.
gate() {
  local st="$1" pj="$2"; shift 2
  env -i PATH="$PATH" HOME="$T" HARNESS="$T/h" LANE_REGISTRY="$REG" \
      LANE_GATE_NOW="$PINNED" LLM_GATE_NOW="$PINNED" SPEND_DIR="$T/spend" \
      REQ_LOG="$T/req.log" LIB="$DIR/bin/lib/llm-gate.sh" "$@" \
    bash -c '
      _jobs_req() {
        printf "%s %s\n" "$1" "$2" >> "$REQ_LOG"
        case "$2" in
          /api/metrics/llm-spend*)
            s=${2#*stage=}; s=${s%%&*}
            [ -r "$SPEND_DIR/$s.json" ] || return 1
            cat "$SPEND_DIR/$s.json"; return 0 ;;
        esac
        return 1
      }
      . "$LIB"
      llm_gate_precall "$0" "$1"; rc=$?
      printf "%s|%s" "$rc" "$LLM_GATE_REASON"' "$st" "$pj"
}
lane_id() {
  env -i PATH="$PATH" HOME="$T" HARNESS="$T/h" LANE_REGISTRY="$REG" LIB="$DIR/bin/lib/llm-gate.sh" \
    bash -c '. "$LIB"; llm_gate_lane_id "$0" "$1"' "$1" "$2"
}
settings() { # settings <key> <value> ... — a fresh settings cache holding exactly these rows
  local args=() k
  while [ $# -ge 2 ]; do args+=(--arg "k$#" "$1" --arg "v$#" "$2"); shift 2; done
  jq -nc --argjson f "$PINNED" "${args[@]}" \
    '{fetched_at:$f, values:($ARGS.named | to_entries | map(select(.key|startswith("k")))
       | map({key:.value, value:($ARGS.named["v" + (.key|ltrimstr("k"))])}) | from_entries)}' \
    > "$T/h/state/settings-cache.json"
}
spend() { printf '{"usd":%s}' "$2" > "$T/spend/$1.json"; }
nospend() { rm -f "$T/spend/"*.json "$T/req.log"; }

# ── G1: each lane's own stages resolve to that lane ──────────────────────────
for pair in prodqa:postmerge-qa map:run-product signals:run-product ideate:run-product \
            synth:run-product mine:rule-miner eval:prompt-eval; do
  st=${pair%%:*}; want=${pair#*:}
  got=$(lane_id "$st" project-4)
  [ "$got" = "$want" ] && ok || bad "G1: stage $st resolved to '$got', want $want"
done

# ── G2: negatives — the build pipeline's stages are NOT these lanes ──────────
for pair in plan:stage-plan fix:stage-fix execute:stage-execute review:stage-review; do
  st=${pair%%:*}; want=${pair#*:}
  got=$(lane_id "$st" project-4)
  [ "$got" = "$want" ] && ok || bad "G2: stage $st resolved to '$got', want $want"
done

# ── G3: the filtered/unfiltered triage split is unchanged ─────────────────────
[ "$(lane_id triage alert-triage)" = alert-triage ] && ok || bad "G3: triage|alert-triage -> $(lane_id triage alert-triage)"
[ "$(lane_id triage project-1)" = run-triage ] && ok || bad "G3: triage|project-1 -> $(lane_id triage project-1)"

# ── G4: postmerge-qa's cap applies to its own prodqa call ────────────────────
nospend; settings lane.postmerge-qa.llm_usd_cap_day 1; spend prodqa 2
R=$(gate prodqa project-4)
case "$R" in 2\|*lane=postmerge-qa*) ok ;; *) bad "G4: prodqa with postmerge-qa cap \$1 and \$2 spent was not refused by postmerge-qa: '$R'" ;; esac
# ...and the same row no longer lands on a build's fix round.
nospend; settings lane.postmerge-qa.llm_usd_cap_day 1; spend fix 50
R=$(gate fix project-4)
[ "${R%%|*}" = 0 ] && ok || bad "G4: a build fix round was refused by postmerge-qa's cap: '$R'"
nospend; settings lane.run-product.llm_lane_enabled 0
R=$(gate plan project-4)
[ "${R%%|*}" = 0 ] && ok || bad "G4: run-product switched off refused a build plan stage: '$R'"
R=$(gate map project-4)
case "$R" in "2|lane-disabled run-product") ok ;; *) bad "G4: run-product switched off did not refuse its own map stage: '$R'" ;; esac

# ── G5: run-product's one cap covers all six of its stages ───────────────────
# (four from bin/run-product.sh, prd/mockup from its declared helper
# bin/draft-proposal.sh since BH-2489)
nospend; settings lane.run-product.llm_usd_cap_day 10
spend map 4; spend signals 0; spend ideate 0; spend synth 7; spend prd 0; spend mockup 0
R=$(gate ideate project-4)
case "$R" in 2\|*spent=\$11*cap=\$10*lane=run-product*) ok ;; *) bad "G5: run-product spent 4+7=\$11 over six stages against a \$10 cap and was not refused: '$R'" ;; esac
N=$(grep -c 'llm-spend?stage=' "$T/req.log" 2>/dev/null); N=${N:-0}
[ "$N" = 6 ] && ok || bad "G5: expected 6 lane-scope spend GETs (one per stage), saw $N: $(cat "$T/req.log" 2>/dev/null)"
for s in map signals ideate synth prd mockup; do
  grep -q "llm-spend?stage=$s&" "$T/req.log" 2>/dev/null && ok || bad "G5: no spend GET for stage $s"
done
rm -f "$T/req.log"; settings lane.run-product.llm_usd_cap_day 12
R=$(gate ideate project-4)
[ "${R%%|*}" = 0 ] && ok || bad "G5: \$11 against a \$12 cap was refused: '$R'"
# The (lane, project) scope sums the same six stages, for that project.
nospend; settings lane.run-product.project-4.llm_usd_cap_day 5
spend map 3; spend signals 3; spend ideate 0; spend synth 0; spend prd 0; spend mockup 0
R=$(gate synth project-4)
case "$R" in 2\|*lane+project*spent=\$6*project=project-4*) ok ;; *) bad "G5: (lane, project) cap \$5 vs \$6 over run-product's stages not refused: '$R'" ;; esac
N=$(grep -c 'llm-spend?project=project-4&stage=' "$T/req.log" 2>/dev/null); N=${N:-0}
[ "$N" = 6 ] && ok || bad "G5: expected 6 project-scope spend GETs, saw $N"

# ── G6: one failed per-stage read is UNKNOWN, never a partial sum ────────────
nospend; settings lane.run-product.llm_usd_cap_day 10
spend map 40; spend ideate 0; spend synth 0; spend prd 0; spend mockup 0   # signals: the worker does not answer
R=$(gate ideate project-4)
[ "${R%%|*}" = 0 ] && ok || bad "G6: a failed signals read with map=\$40 refused the call (partial sum compared to the cap): '$R'"
grep -q 'could not be read' "$T/h/logs/lane-gate.log" 2>/dev/null && ok \
  || bad "G6: the fail-open line was not logged"

echo "llm-gate-stages: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
