#!/bin/bash
# greenfield.sh <workspace-dir> [--refresh-map] — fabricate an OS proposal pack
# for a NEW organization from discovery materials. Runs on the operator's Mac (not the
# boxes): uses the local `claude` CLI directly.
#
# Workspace layout (create the dir, drop materials in, run):
#   <ws>/materials/          transcripts, org docs, questionnaires (.md/.txt/.pdf-as-text)
#   <ws>/company-map.md      generated (editable — edits survive; --refresh-map to rebuild)
#   <ws>/runs/<date>/        signals.json, ideas-*.json, ideas.json, mockups/, deck.html
#   <ws>/ledger.json         cross-run idea dedup
#
# Pipeline: MAP -> SIGNALS -> per-department IDEATE (parallel) -> SYNTH ->
# MOCKUPS (top GF_TOP ideas) -> DECK (self-contained HTML, opens when done).
set -uo pipefail
WS="${1:?usage: greenfield.sh <workspace-dir> [--refresh-map]}"
REFRESH="${2:-}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# HARNESS defaults to this checkout (state/ and logs/ are gitignored): this runs
# on a Mac, not a box.
HARNESS="${HARNESS:-$HERE}"
# LANE greenfield (BH-2603): the switch and the LLM_* knobs, before anything is
# ingested or bought. A Mac with no worker and no flags/ fails open.
. "$HARNESS/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit greenfield
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply greenfield
GP="$HERE/prompts/greenfield"
STAGES="$HERE/prompts/product-stages"
CATALOG="$HERE/catalog/feature-catalog.md"
WS="$(cd "$WS" && pwd)" || exit 1
MAP="$WS/company-map.md"
LEDGER="$WS/ledger.json"
RUN="$WS/runs/$(date +%Y-%m-%d)"
MOCKS="$RUN/mockups"
mkdir -p "$RUN" "$MOCKS"
[ -f "$LEDGER" ] || echo '[]' > "$LEDGER"
# Pull in client-provided assets each run (sources.txt lists their folders) —
# new files the client emails flow into materials/ automatically, idempotently.
[ -f "$WS/sources.txt" ] && "$HERE/bin/greenfield-ingest.sh" "$WS"
[ -d "$WS/materials" ] && [ -n "$(ls -A "$WS/materials" 2>/dev/null)" ] || { echo "FATAL: $WS/materials is empty — drop discovery transcripts/docs there (or create sources.txt) first"; exit 1; }

# >>> model-route (BH-1510.2): one model_routes role per stage — greenfield (the
# MAP stage), greenfield.signals, .ideate, .synth, .mockup, .deck — each with its
# GF_*_MODEL env var still winning when set. This runs on a Mac, not a box, so
# HARNESS defaults to this checkout (state/ and logs/ are gitignored) and the
# worker is reached with HARNESS_SECRET/JOBS_URL from the environment or
# env/global.env. No route for a stage = rc 75 before anything is bought.
. "$HERE/bin/lib/lane-model.sh"
if ! { GF_MAP_MODEL=$(lane_model GF_MAP_MODEL greenfield) \
    && GF_SIGNALS_MODEL=$(lane_model GF_SIGNALS_MODEL greenfield.signals) \
    && GF_IDEATE_MODEL=$(lane_model GF_IDEATE_MODEL greenfield.ideate) \
    && GF_SYNTH_MODEL=$(lane_model GF_SYNTH_MODEL greenfield.synth) \
    && GF_MOCKUP_MODEL=$(lane_model GF_MOCKUP_MODEL greenfield.mockup) \
    && GF_DECK_MODEL=$(lane_model GF_DECK_MODEL greenfield.deck); }; then
  echo "FATAL: no model route for a greenfield stage (see $HARNESS/logs/ALERTS.log) — export HARNESS_SECRET so the worker can answer, or set the GF_*_MODEL env vars"; exit 75
fi
# <<< model-route
GF_TOP="${GF_TOP:-3}"
GF_CONC="${GF_CONC:-3}"

say() { printf '\033[1m== %s ==\033[0m\n' "$*"; }

# BILLED (2026-09-14). Every stage below is a full claude turn on opus/fable
# models and none of them left a cost row: this script runs the CLI directly, so
# bin/agent-call.sh never saw it and a proposal pack cost whatever it cost with
# nothing in the ledger to say so. bin/claude-cost.sh is the same argv, the same
# stdout, the same exit code, plus a row priced from the run's own transcript.
# Resolved once: the checkout's copy (this file runs from a checkout on the operator's
# Mac), then the deployed one, then bare `claude` so a machine without the
# harness still produces a proposal — unbilled, which is what it does today.
CLAUDE_BIN="claude"
for _c in "$HERE/bin/claude-cost.sh" "${HARNESS:-/root/harness}/bin/claude-cost.sh"; do
  [ -x "$_c" ] && { CLAUDE_BIN="$_c"; break; }
done
# ACT-TIME IRON-LAW GUARD ON THIS LANE TOO (2026-09-17). This one runs on the operator's
# Mac against a workspace full of a client's discovery materials, as a full agent
# session — the marker plus the hook mean a `rm -rf` at a protected root is
# refused rather than reasoned about. This script has no HARNESS of its own (it
# inlines the default above), so name it once here for the block below.
# bin/iron-law-arm.sh always exits 0 and prints nothing when it cannot arm — a
# Mac with no harness deployed runs the stage unfenced rather than not at all.
HARNESS="${HARNESS:-/root/harness}"
# >>> iron-law arm
IRON_LAW_ARM=()
for _a in "$(dirname "$0")/iron-law-arm.sh" "$HARNESS/bin/iron-law-arm.sh"; do
  [ -x "$_a" ] && { _gs=$("$_a" greenfield 2>/dev/null); [ -n "$_gs" ] && IRON_LAW_ARM=(--settings "$_gs"); break; }
done
# <<< iron-law arm
export COST_PROJECT="${COST_PROJECT:-greenfield}"

run_llm() { # run_llm <model> <outlog> <prompt>
  local MODEL="$1" OUT="$2" PROMPT="$3"
  # COST_STAGE is the pipeline step, taken from the log file this stage writes
  # (map.out.txt -> map), so the ledger splits a pack into its stages rather
  # than reporting one undifferentiated blob.
  #
  # K3 (BH-2603): the same prompt on the same workspace at the same stage is the
  # same work, family greenfield, and the call is lane greenfield.
  local st; st=$(basename "$OUT" | sed 's/\.out\.txt$//')
  COST_STAGE="gf-$st" \
    env HARNESS="$HARNESS" HARNESS_LANE=greenfield HARNESS_LANE_PROJECT=greenfield \
    AGENT_CALL_LANE=greenfield AGENT_CALL_GUARD_STAGE=greenfield \
    AGENT_CALL_FP="gf:$(printf '%s' "$WS" | sha256sum | cut -c1-12):$st:p$(printf '%s' "$PROMPT" | sha256sum | cut -c1-16)" \
    "$CLAUDE_BIN" -p --dangerously-skip-permissions --model "$MODEL" "${IRON_LAW_ARM[@]}" "$PROMPT" > "$OUT" 2>"$OUT.err"
}

# ---------- 1. MAP ----------
if [ ! -s "$MAP" ] || [ "$REFRESH" = "--refresh-map" ]; then
  say "MAP: building company map from materials/"
  RT="RUNTIME CONTEXT
WORKSPACE=$WS
MATERIALS=$WS/materials   (read everything here)
MAP_OUT=$MAP   (write the map HERE)"
  [ -s "$MAP" ] && RT="$RT

EXISTING MAP (refresh — preserve the operator's manual edits unless the materials prove them wrong):
$(cat "$MAP")"
  run_llm "$GF_MAP_MODEL" "$RUN/map.out.txt" "$(cat "$GP/map.md")

$RT"
  grep -q '^departments:' "$MAP" || { echo "FATAL: map generation failed (no departments frontmatter) — see $RUN/map.out.txt"; exit 1; }
else
  say "MAP: using existing $MAP (pass --refresh-map to rebuild)"
fi

# ---------- 2. SIGNALS ----------
SIGNALS="$RUN/signals.json"
say "SIGNALS: harvesting evidence"
run_llm "$GF_SIGNALS_MODEL" "$RUN/signals.out.txt" "$(cat "$GP/signals.md")

RUNTIME CONTEXT
MATERIALS=$WS/materials
MAP=$MAP
SIGNALS_OUT=$SIGNALS   (write signals HERE)"
jq -e '.signals | length > 0' "$SIGNALS" >/dev/null 2>&1 || { echo "FATAL: signals failed — see $RUN/signals.out.txt"; exit 1; }

# ---------- 3. IDEATE fan-out ----------
DEPTS=$(sed -n 's/^departments:[[:space:]]*\[\(.*\)\].*/\1/p' "$MAP" | tr ',' '\n' | tr -d ' "' | grep . || true)
[ -n "$DEPTS" ] || { echo "FATAL: no departments parsed from map"; exit 1; }
say "IDEATE: $(wc -w <<<"$DEPTS" | tr -d ' ') departments (concurrency $GF_CONC)"
ideate_one() {
  local DEPT="$1" OUT="$RUN/ideas-$1.json"
  run_llm "$GF_IDEATE_MODEL" "$RUN/ideate-$DEPT.out.txt" "$(cat "$GP/ideate.md")

RUNTIME CONTEXT
DEPT=$DEPT
IDEAS_OUT=$OUT   (write ideas HERE)
MAP=$MAP
SIGNALS=$SIGNALS
CATALOG=$CATALOG
LEDGER=$LEDGER"
  jq -e '.ideas | length > 0' "$OUT" >/dev/null 2>&1 || { echo "  dept $DEPT: FAILED (skipped)"; rm -f "$OUT"; }
}
for DEPT in $DEPTS; do
  while [ "$(jobs -rp | wc -l)" -ge "$GF_CONC" ]; do wait -n || true; done
  ( ideate_one "$DEPT" && echo "  dept $DEPT: done" ) &
done
wait
ls "$RUN"/ideas-*.json >/dev/null 2>&1 || { echo "FATAL: no department produced ideas"; exit 1; }

# ---------- 4. SYNTH + deterministic DUS-first ordering ----------
IDEAS="$RUN/ideas.json"
say "SYNTH: merge + dedup + classify-check"
run_llm "$GF_SYNTH_MODEL" "$RUN/synth.out.txt" "$(cat "$STAGES/synth.md")

RUNTIME CONTEXT
CYCLE_DIR=$RUN   (read ideas-*.json here)
IDEAS_OUT=$IDEAS   (write the merged file HERE)
SIGNALS=$SIGNALS
LEDGER=$LEDGER"
jq -e '.ideas | length > 0' "$IDEAS" >/dev/null 2>&1 || { echo "  synth failed — mechanical merge"; jq -s '{ideas: map(.ideas) | add}' "$RUN"/ideas-*.json > "$IDEAS"; }
jq '
  def num: if type=="number" then . elif type=="string" then (([scan("[0-9]+[.]?[0-9]*")] | first // "1") | tonumber) else 1 end;
  .ideas |= ([ .[]
    | .impact = (.impact | num) | .confidence = (.confidence | num)
    | .effort = ((.effort | num) | if . < 0.5 then 0.5 else . end)
    | .score = ((.impact * .confidence / .effort) * 10 | round / 10)
    | .dusrank = (if .dus == "derisk" then 0 elif .dus == "unclog" then 1 else 2 end) ]
    | sort_by([.dusrank, -.score]))
' "$IDEAS" > "$IDEAS.tmp" && mv "$IDEAS.tmp" "$IDEAS"
NOW="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
jq --slurpfile new "$IDEAS" --arg now "$NOW" --arg dir "$RUN" '
  . as $L | $L + [ $new[0].ideas[]
    | select(.slug as $s | ($L | map(.slug == $s) | any | not))
    | {slug, title, summary, department, dus, score, status: "candidate", dir: $dir, created_at: $now} ]
' "$LEDGER" > "$LEDGER.tmp" && mv "$LEDGER.tmp" "$LEDGER"

# ---------- 5. MOCKUPS for the top ideas ----------
say "MOCKUPS: top $GF_TOP ideas"
for i in $(seq 0 $((GF_TOP - 1))); do
  IDEA=$(jq -c ".ideas[$i] // empty" "$IDEAS"); [ -n "$IDEA" ] || break
  SLUG=$(jq -r '.slug' <<<"$IDEA")
  echo "  mockup: $SLUG"
  run_llm "$GF_MOCKUP_MODEL" "$RUN/mockup-$SLUG.out.txt" "$(cat "$GP/mockup.md")

RUNTIME CONTEXT
IDEA=$IDEA
MAP=$MAP
SIGNALS=$SIGNALS
MOCKUP_OUT=$MOCKS/$SLUG.html   (write the mockup HERE)"
  [ -s "$MOCKS/$SLUG.html" ] || echo "  mockup $SLUG: FAILED"
done

# ---------- 6. DECK ----------
DECK="$RUN/deck.html"
say "DECK: assembling the proposal pack"
run_llm "$GF_DECK_MODEL" "$RUN/deck.out.txt" "$(cat "$GP/deck.md")

RUNTIME CONTEXT
MAP=$MAP
SIGNALS=$SIGNALS
IDEAS=$IDEAS   (already DUS-ordered)
MOCKUP_DIR=$MOCKS   (embed each .html inline via iframe srcdoc)
DECK_OUT=$DECK   (write the deck HERE)"
if [ -s "$DECK" ]; then
  say "DONE: $DECK"
  echo "ideas: $(jq '.ideas | length' "$IDEAS") ($(jq '[.ideas[] | select(.dus=="derisk")] | length' "$IDEAS") derisk / $(jq '[.ideas[] | select(.dus=="unclog")] | length' "$IDEAS") unclog / $(jq '[.ideas[] | select(.dus=="scale")] | length' "$IDEAS") scale)"
  command -v open >/dev/null && open "$DECK"
else
  echo "FATAL: deck generation failed — see $RUN/deck.out.txt"; exit 1
fi
