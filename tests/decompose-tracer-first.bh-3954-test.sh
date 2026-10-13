#!/bin/bash
# tests/decompose-tracer-first.bh-3954-test.sh — tracer-first decomposition
# (BH-3954, the operator, 2026-10-03). Child 1 of a split is no longer a stub contract:
# it is the TRACER, the thinnest path from a real trigger to a persisted result
# to an outcome someone can observe. Siblings slice by user capability, not by
# layer, and every child body names its observable outcome. A spec where any
# child has none is refused before anything is filed.
#
# WHAT IS UNDER TEST. The real bin/run-decompose.sh, driven with a handed-in
# children.json (DECOMPOSE_DRY_RUN=1: gh commands are printed, no Fable call is
# bought), plus the prompt text both lanes hand the model, the filed contract
# child body, and the two docs the ticket names.
#
# No network, no model call, no secrets. Run from anywhere:
#   tests/decompose-tracer-first.bh-3954-test.sh     (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export GH_CLI_REST_ADAPTER="$DIR/tests/lib/gh-cli-rest-adapter.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

DEC="$DIR/bin/run-decompose.sh"
[ -x "$DEC" ] && ok || bad "bin/run-decompose.sh is missing or not executable"

mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/env" "$T/h/prompts"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T/h" scoutish || exit 1
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/planned-files.sh" "$T/h/bin/"
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset> [box] [ip]
scoutish      example-org/scoutish   https://scoutish.example  -           9 box-1 10.0.0.9
CONF
export FLEET_CONF="$T/h/fleet.conf"
# agent-call must never be reached: every drive below hands in a spec.
printf '#!/bin/bash\necho "AGENT CALL: $*" >> "$AGENT_LOG"\nexit 0\n' > "$T/h/bin/agent-call.sh"
chmod +x "$T/h/bin/agent-call.sh"

# drive <spec-json> [keep] — prints the script's output and exits with its rc.
# With "keep" the build dir is not wiped, so a pre-seeded children.txt stays.
drive() {
  [ "${2:-}" = keep ] || { rm -rf "$T/b"; mkdir -p "$T/b"; }
  printf '%s\n' "$1" > "$T/b/children.json"
  printf 'SIZE_DECLARED: files=18 lines=1900\nSIZE_OVER: lines=1900>300; files=18>12\nSIZE_VERDICT: over\n' > "$T/b/size-gate.txt"
  : > "$T/agent.log"
  env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" AGENT_LOG="$T/agent.log" \
      DECOMPOSE_DRY_RUN=1 "$DEC" scoutish 552 TK-552 "$T/b" 300 12 2>&1
}

# ===========================================================================
# A. the prompts
# ===========================================================================
ISSUES_PROMPT=$(sed -n '/SPEC="\$BUILD\/children.json"/,/DECOMPOSE_SPEC_READY/p' "$DEC")
BOARD_PROMPT=$(sed -n '/# -* board lane/,$p' "$DEC")
[ -n "$ISSUES_PROMPT" ] && ok || bad "A1: could not extract the issues-lane prompt"
[ -n "$BOARD_PROMPT" ] && ok || bad "A3: could not extract the board-lane prompt"
for P in 'TRACER FIRST' 'observable outcome' '## Observable outcome' 'one capability end to end' \
         'LAYER SPLIT IS A DECOMPOSITION FAILURE' '$CONTRACT_MAXL'; do
  grep -qiF -- "$P" <<<"$ISSUES_PROMPT" && ok || bad "A1: the issues-lane prompt must say '$P'"
  grep -qiF -- "$P" <<<"$BOARD_PROMPT" && ok || bad "A3: the board-lane prompt must say '$P'"
done
for N in 'do nothing useful' 'stubs that compile'; do
  [ "$(grep -c -- "$N" "$DEC")" -eq 0 ] && ok || bad "A2: bin/run-decompose.sh still says '$N'"
  grep -q -- "$N" <<<"$BOARD_PROMPT" && bad "A3: the board-lane prompt still says '$N'" || ok
done

# ===========================================================================
# B. a child with no observable outcome is refused before anything is filed
# ===========================================================================
OC='\n\n## Observable outcome\nGET /scan returns the stored rows.'
refuse() { # refuse <spec-json> <why> <reason-substring>
  local out rc
  out=$(drive "$1"); rc=$?
  [ "$rc" -ne 0 ] || { bad "$2 must not exit 0: $out"; return; }
  [ -e "$T/b/children.txt" ] && { bad "$2 must file nothing (children.txt exists)"; return; }
  [ "$(grep -c '^DRYRUN gh issue create ' <<<"$out")" -eq 0 ] || { bad "$2 must refuse BEFORE it files a child: $out"; return; }
  grep -q "DECOMPOSE_FAILED" "$T/b/decompose-run.txt" 2>/dev/null \
    || { bad "$2 must write DECOMPOSE_FAILED to decompose-run.txt"; return; }
  grep -q "Observable outcome" "$T/b/decompose-run.txt" \
    || { bad "$2 must be refused on the outcome check, not another one: $(cat "$T/b/decompose-run.txt")"; return; }
  grep -qF -- "$3" "$T/b/decompose-run.txt" \
    && ok || bad "$2 must name the position(s) '$3': $(cat "$T/b/decompose-run.txt")"
  grep -q 'decompose FAILED' "$T/b/pipeline.log" 2>/dev/null \
    && ok || bad "$2 must also land in pipeline.log"
}
# B1: child 2 has no outcome section at all.
refuse '[
 {"title":"scan tracer","contract":"src/api/scan.ts: GET /scan; src/lib/scan/store.ts: readScan(), writeScan()","after":[],"body":"Tracer.\n\nFiles: src/api/scan.ts'"$OC"'"},
 {"title":"scan list","after":[],"body":"List scans.\n\nFiles: src/app/scans/page.tsx"},
 {"title":"scan export","after":[],"body":"Export.\n\nFiles: src/api/export.ts'"$OC"'"}
]' "B1: a sibling with no outcome section" "child 2 "
# B2: a mid-sentence mention is not a section.
refuse '[
 {"title":"scan tracer","contract":"src/api/scan.ts: GET /scan","after":[],"body":"Tracer.'"$OC"'"},
 {"title":"scan list","after":[],"body":"List scans, there is no observable outcome yet.\n\nFiles: src/app/scans/page.tsx"}
]' "B2: a mid-sentence mention" "child 2 "
# B3: the tracer is not exempt.
refuse '[
 {"title":"scan tracer","contract":"src/api/scan.ts: GET /scan","after":[],"body":"Tracer.\n\nFiles: src/api/scan.ts"},
 {"title":"scan list","after":[],"body":"List.'"$OC"'"}
]' "B3: a tracer with no outcome section" "child 1 "
# B4: a heading with an empty section is not an outcome.
refuse '[
 {"title":"scan tracer","contract":"src/api/scan.ts: GET /scan","after":[],"body":"Tracer.'"$OC"'"},
 {"title":"scan list","after":[],"body":"List.\n\n## Observable outcome\n\n## Files\nsrc/a.ts"}
]' "B4: an empty outcome section" "child 2 "
# B5: "Outcome:" without "Observable" is not the section.
refuse '[
 {"title":"scan tracer","contract":"src/api/scan.ts: GET /scan","after":[],"body":"Tracer.'"$OC"'"},
 {"title":"scan list","after":[],"body":"List.\n\nOutcome: GET /scan returns rows"}
]' "B5: a bare Outcome: line" "child 2 "
# B6: several missing, one refusal naming every position.
refuse '[
 {"title":"scan tracer","contract":"src/api/scan.ts: GET /scan","after":[],"body":"Tracer.'"$OC"'"},
 {"title":"scan list","after":[],"body":"List."},
 {"title":"scan export","after":[],"body":"Export."}
]' "B6: two siblings with no outcome" "2, 3"
[ "$(grep -c DECOMPOSE_FAILED "$T/b/decompose-run.txt" 2>/dev/null)" = 1 ] \
  && ok || bad "B6: one refusal, not one per child: $(cat "$T/b/decompose-run.txt")"

# B7: heading, bold and inline forms all pass, case-insensitive, and the spec files.
GOOD='[
 {"title":"scan tracer","contract":"src/api/scan.ts: GET /scan; src/lib/scan/store.ts: readScan(), writeScan()","after":[],"body":"Tracer.\n\n## Observable outcome\nPOST /scan then GET /scan returns the row.\n\n## Files\nsrc/api/scan.ts"},
 {"title":"scan list","after":[],"body":"List.\n\n**Observable outcome**\n\nThe /scans page lists two seeded rows."},
 {"title":"scan export","after":[],"body":"Export.\n\nobservable outcome: GET /scan/export returns a CSV."},
 {"title":"scan digest","after":[],"body":"Digest.\n\n### Observable Outcome\n- the cron tick writes one digest row"}
]'
OUT=$(drive "$GOOD"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "B7: a spec where every child names its outcome must file (rc=$RC): $OUT"
[ "$(grep -c '^DRYRUN gh issue create ' <<<"$OUT")" -eq 4 ] \
  && ok || bad "B7: four children = four create commands (got: $OUT)"
[ -s "$T/agent.log" ] && bad "B7: a dry run with a spec in hand must not buy a Fable call" || ok

# C1: the filed tracer body tells its builder to build a tracer, not stubs.
C0="$T/b/children/child-1.md"
grep -q 'thinnest end-to-end path' "$C0" && ok || bad "C1: the tracer child must say 'thinnest end-to-end path': $(cat "$C0" 2>/dev/null)"
grep -q '60 lines of product code' "$C0" && ok || bad "C1: the tracer keeps its small budget: $(cat "$C0" 2>/dev/null)"
grep -q 'stubs that compile' "$C0" && bad "C1: the tracer child still asks for stubs: $(cat "$C0")" || ok
grep -q '^CONTRACT: .*readScan()' "$C0" && ok || bad "C1: the tracer keeps its CONTRACT: line: $(cat "$C0" 2>/dev/null)"

# B7 (resume): a split whose filing already started is not re-validated, or a
# half-filed pre-deploy split could never finish.
rm -rf "$T/b"; mkdir -p "$T/b"; printf 'TK-553\n' > "$T/b/children.txt"
OLD='[
 {"title":"types","contract":"src/lib/t.ts: T","after":[],"body":"x"},
 {"title":"A","after":[],"body":"x"}
]'
OUT=$(drive "$OLD" keep); RC=$?
grep -q 'observable-outcome check skipped' "$T/b/pipeline.log" 2>/dev/null \
  && ok || bad "B7: a resumed split logs that the outcome check was skipped: $(cat "$T/b/pipeline.log" 2>/dev/null)"
grep -q 'Observable outcome' "$T/b/decompose-run.txt" 2>/dev/null \
  && bad "B7: a resumed split must not be refused on the outcome check: $(cat "$T/b/decompose-run.txt")" || ok

# ===========================================================================
# D. the docs
# ===========================================================================
grep -q 'Tracer first' "$DIR/prompts/plan-contract.md" && ok || bad "D1: plan-contract.md §2 must say 'Tracer first'"
grep -q 'Contracts as code: unit 0 commits shared types/interfaces/skeletons' "$DIR/prompts/plan-contract.md" \
  && bad "D1: plan-contract.md still describes unit 0 as skeletons" || ok
grep -qi 'wave 1 the end-to-end tracer' "$DIR/skills/harness/SKILL.md" && ok || bad "D1: SKILL.md Rollout must make wave 1 the end-to-end tracer"

echo "decompose-tracer-first: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
