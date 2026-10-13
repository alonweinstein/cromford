#!/bin/bash
# tests/run-decompose-issues-test.sh — bin/run-decompose.sh on a GitHub-Issues
# project, driven through its dry-run mode.
#
# WHY (the operator, 2026-09-14). The decomposer could only file children through an
# in-app board's ticket-create endpoint, so on project-5 — whose board IS the
# repo's issues — it asked a model to POST to an API that project does not have.
# TK-552 built 1,900 product lines across 18 files in one 33-minute execute and
# TK-556 was flagged decomposable the same night; both shipped whole.
#
# WHAT IS UNDER TEST, and why the exact bytes matter. The children are only
# useful if the REST OF THE PIPELINE can read them: the `ai-build` label is the
# handoff (prompts/project-5.md — an unlabelled issue is invisible to every
# watcher), and `Blocked-by: #<n>` is the line bin/unblocked-children.sh parses
# to launch a child the moment its sibling closes. A child filed without the
# label never builds; a child whose ordering line is phrased differently
# launches immediately and collides with the sibling it was meant to follow. So
# this drives the real script with DECOMPOSE_DRY_RUN=1 (which prints the gh
# commands instead of running them and reuses a handed-in children.json instead
# of buying a Fable call) and asserts the bodies byte by byte — including
# feeding the produced Blocked-by line to the REAL bin/unblocked-children.sh.
#
# No network, no model call, no secrets. Run from anywhere:
#   tests/run-decompose-issues-test.sh      (exit 0 = all pass)
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
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T/h" scoutish widget-os || exit 1  # BH-1510.2: lanes read models from model_routes
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
# A fleet.conf with both lanes in it: a "-" board prefix is the GitHub-Issues
# lane, anything else is an in-app board. Same column the rest of the fleet
# reads, so this cannot pass against a project shape that does not exist.
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset> [box] [ip]
scoutish      example-org/scoutish   https://scoutish.example  -           9 box-1 10.0.0.9
widget-os     example-org/widget-os  https://widget.example    /api/board  2 box-1 10.0.0.2
CONF
export FLEET_CONF="$T/h/fleet.conf"
# agent-call must never be reached in these runs: every drive hands in a spec.
cat > "$T/h/bin/agent-call.sh" <<'SH'
#!/bin/bash
echo "AGENT CALL: $*" >> "$AGENT_LOG"
exit 0
SH
chmod +x "$T/h/bin/agent-call.sh"

# CONTRACT FIRST (BH-481): object 1 carries `contract` and is filed as the
# `.0` child every sibling is blocked on. The shape the prompt now asks for.
SPEC='[
 {"title":"metrics table + read API","contract":"src/db/metrics.ts: MetricRow; src/api/metrics.ts: GET /api/metrics","after":[],"body":"Create the table and the read endpoint.\n\nFiles: src/db/metrics.ts, src/api/metrics.ts\nTests: tests/metrics.test.ts\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"dashboard tile","after":[1],"body":"Render the tile against the read API.\n\nFiles: src/app/dashboard/MetricTile.tsx\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"weekly digest email","after":[],"body":"Send the digest.\n\nFiles: src/jobs/digest.ts\n\n## Observable outcome\nThe slice acceptance test passes end to end."}
]'

drive() { # drive <project> <ticket> <key> [env...]
  local p="$1" t="$2" k="$3"; shift 3
  rm -rf "$T/b"; mkdir -p "$T/b"
  printf '%s\n' "$SPEC" > "$T/b/children.json"
  printf 'SIZE_DECLARED: files=18 lines=1900\nSIZE_OVER: lines=1900>300; files=18>12\nSIZE_VERDICT: over\n' > "$T/b/size-gate.txt"
  : > "$T/agent.log"
  ( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" AGENT_LOG="$T/agent.log" \
        DECOMPOSE_DRY_RUN=1 "$@" "$DEC" "$p" "$t" "$k" "$T/b" 300 12 2>&1 )
}

# ===========================================================================
# 1. the dry run prints the gh commands instead of running them
# ===========================================================================
OUT=$(drive scoutish 552 TK-552); RC=$?
[ "$RC" -eq 0 ] && ok || bad "a clean dry run must exit 0 (rc=$RC): $OUT"
[ "$(grep -c '^DRYRUN gh issue create ' <<<"$OUT")" -eq 3 ] \
  && ok || bad "three children = three create commands (got: $OUT)"
grep -q '^DRYRUN gh api -X POST repos/example-org/scoutish/issues/552/comments' <<<"$OUT" \
  && ok || bad "the parent must get exactly one comment command (got: $OUT)"
grep -q '^DRYRUN gh api -X DELETE repos/example-org/scoutish/issues/552/labels/ai-build' <<<"$OUT" \
  && ok || bad "the parent must be parked by losing the ai-build label (got: $OUT)"
# NOTHING ran. The dry run is only worth having if it is airtight.
[ -s "$T/agent.log" ] && bad "a dry run with a spec in hand must not buy a Fable call" || ok
grep -qE '^(gh|DRYRUN gh) issue (close|delete)' <<<"$OUT" \
  && bad "a split must never close the parent (got: $OUT)" || ok

# 2. every child carries the label, in landing order, with the parent's key
[ "$(grep -c -- '--label ai-build' <<<"$OUT")" -eq 3 ] \
  && ok || bad "all three children must carry ai-build, the label IS the handoff (got: $OUT)"
grep -q "TK-552.0: contract — metrics table + read API'" <<<"$OUT" \
  && ok || bad "the contract is filed as '<PARENT KEY>.0: contract — <slice>' (got: $OUT)"
grep -q "TK-552.2: weekly digest email'" <<<"$OUT" \
  && ok || bad "the third child must keep its position in the title (got: $OUT)"
# children.txt is the file run-build.sh reads for the DECOMPOSED RESULT line.
[ "$(paste -sd, "$T/b/children.txt")" = "TK-553,TK-554,TK-555" ] \
  && ok || bad "children.txt must list the child KEYS in landing order (got: $(cat "$T/b/children.txt" 2>/dev/null))"

# ===========================================================================
# 3. the body conventions the pipeline parses
# ===========================================================================
C1="$T/b/children/child-1.md"; C2="$T/b/children/child-2.md"; C3="$T/b/children/child-3.md"
for F in "$C1" "$C2" "$C3"; do
  [ -s "$F" ] || bad "missing body file $F"
done
ok
grep -q '^Part of #552$' "$C1" && ok || bad "every child says which parent it is part of: $(cat "$C1")"
grep -q '^Order: 1 of 3$' "$C1" && ok || bad "child 1 must carry 'Order: 1 of 3': $(cat "$C1")"
grep -q '^Order: 3 of 3$' "$C3" && ok || bad "child 3 must carry 'Order: 3 of 3': $(cat "$C3")"
# THE ORDERING LINE, in the exact shape bin/unblocked-children.sh parses, with
# the `(hard)` suffix bin/lib/dep-verify-lib.sh honours: every sibling imports
# the contract, so that one link is real and nothing may second-guess it.
grep -q '^Blocked-by: #553 (hard)$' "$C2" \
  && ok || bad "a sibling must be blocked by the contract's REAL issue number: $(cat "$C2")"
# ...the contract itself waits on nobody, and no sibling waits on another one:
# a parallel wave on top of the contract is the whole point (BH-481).
grep -qi 'blocked-by' "$C1" && bad "the contract waits on nobody: $(cat "$C1")" || ok
{ [ "$(grep -c '^Blocked-by' "$C3")" -eq 1 ] && grep -q '^Blocked-by: #553 (hard)$' "$C3"; } \
  && ok || bad "child 3 is blocked by the contract and by nothing else: $(cat "$C3")"
# The per-child budget rides in the body, or a child comes back parent-sized.
grep -q 'at most 300 lines of product code across 12 files' "$C1" \
  && ok || bad "the child's own size budget must be in its body: $(cat "$C1")"
grep -qi 'depth 1' "$C1" && ok || bad "the child must be told it is never split again: $(cat "$C1")"
# The model's own text survives verbatim — the filer appends, it does not rewrite.
grep -q 'src/db/metrics.ts' "$C1" && ok || bad "the model's file list must survive into the issue body"

# ===========================================================================
# 4. the REAL parser reads the REAL line
# ===========================================================================
# An assertion about a regex I wrote next to the regex I wrote proves nothing.
# bin/unblocked-children.sh is what actually launches a child when its blocker
# closes, so the produced body goes through IT.
mkdir -p "$T/gh"
cat > "$T/gh/gh" <<'SH'
#!/bin/bash
. "${GH_CLI_REST_ADAPTER:?}" || exit 1; gh_cli_rest "$0" "$@" && exit 0
cat "$ISSUES_JSON"
SH
chmod +x "$T/gh/gh"
mkdir -p "$T/h/bin/lib"; cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" "$T/h/bin/lib/"
B2=$(jq -Rs . < "$C2")
jq -nc --argjson b2 "$B2" '[
  {"number":553,"state":"CLOSED","title":"TK-552.1: metrics table + read API","body":"Part of #552"},
  {"number":554,"state":"OPEN","title":"TK-552.2: dashboard tile","body":$b2}
]' > "$T/issues.json"
UNB=$(PATH="$T/gh:$PATH" ISSUES_JSON="$T/issues.json" HARNESS="$T/h" GH_ISSUES_REPO="example-org/scoutish" \
      "$DIR/bin/unblocked-children.sh" scoutish <<<'board issues: CHANGED 553 "TK-552.1" (state: OPEN -> CLOSED)' 2>/dev/null)
grep -q 'UNBLOCKED 554 ' <<<"$UNB" \
  && ok || bad "the Blocked-by line this script writes must be one unblocked-children.sh can read (got: '$UNB')"

# ===========================================================================
# 5. the parent comment: links, numbers, and what happened to the label
# ===========================================================================
CM="$T/b/decompose-comment.md"
[ -s "$CM" ] && ok || bad "the split comment must be written to the build dir"
grep -q '#553' "$CM" && grep -q '#554' "$CM" && grep -q '#555' "$CM" \
  && ok || bad "the comment must link every child: $(cat "$CM" 2>/dev/null)"
grep -q 'files=18 lines=1900' "$CM" \
  && ok || bad "the comment must carry the size numbers that caused the split: $(cat "$CM")"
grep -q 'lines=1900>300' "$CM" \
  && ok || bad "the comment must name the limit it crossed: $(cat "$CM")"
grep -q 'ai-build' "$CM" \
  && ok || bad "the comment must say the master was unlabelled, or the operator sees a stalled ticket: $(cat "$CM")"
# De-AI voice: the comment a client reads is not allowed to be em-dash soup.
[ "$(grep -c '—' "$CM")" -le 1 ] && ok || bad "near-zero em dashes in a client-facing comment: $(cat "$CM")"

# ===========================================================================
# 6. a spec that is not a split is refused, and refused LOUDLY
# ===========================================================================
refuse() { # refuse <spec-json> <why>
  rm -rf "$T/b"; mkdir -p "$T/b"
  printf '%s\n' "$1" > "$T/b/children.json"
  local out rc
  out=$( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" AGENT_LOG="$T/agent.log" DECOMPOSE_DRY_RUN=1 \
         "$DEC" scoutish 552 TK-552 "$T/b" 300 12 2>&1 ); rc=$?
  [ "$rc" -ne 0 ] || { bad "$2 must not exit 0"; return; }
  [ -s "$T/b/children.txt" ] && { bad "$2 must file nothing"; return; }
  grep -qi 'decompose FAILED' "$T/b/pipeline.log" 2>/dev/null \
    && ok || bad "$2 must say why in pipeline.log: $(cat "$T/b/pipeline.log" 2>/dev/null)"
}
refuse '[{"title":"the whole thing","after":[],"body":"x"}]' "a one-child 'split'"
refuse '[{"title":"a","after":[],"body":"x"},{"title":"b","after":[],"body":"x"},{"title":"c","after":[],"body":"x"},{"title":"d","after":[],"body":"x"},{"title":"e","after":[],"body":"x"},{"title":"f","after":[],"body":"x"}]' "six children"
refuse '[{"title":"a","after":[],"body":""},{"title":"b","after":[],"body":"x"}]' "a child with no body"
refuse 'I decided not to split this, sorry.' "prose instead of a spec"

# A FENCED array is a formatting slip, not a failed split.
rm -rf "$T/b"; mkdir -p "$T/b"
printf '```json\n%s\n```\n' "$SPEC" > "$T/b/children.json"
OUT=$( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" AGENT_LOG="$T/agent.log" DECOMPOSE_DRY_RUN=1 \
       "$DEC" scoutish 552 TK-552 "$T/b" 300 12 2>&1 )
[ "$(grep -c '^DRYRUN gh issue create ' <<<"$OUT")" -eq 3 ] \
  && ok || bad "a fenced children.json must still split (got: $OUT)"

# ===========================================================================
# 7. ordering that cannot be filed is dropped, not obeyed
# ===========================================================================
# 'after' naming a LATER sibling would point at an issue number that does not
# exist yet, so it cannot become a declaration and is dropped out loud.
rm -rf "$T/b"; mkdir -p "$T/b"
printf '%s\n' '[{"title":"types","contract":"src/t.ts: T","after":[],"body":"x\n\n## Observable outcome\nThe slice acceptance test passes end to end."},{"title":"a","after":["3: later()"],"body":"x\n\n## Observable outcome\nThe slice acceptance test passes end to end."},{"title":"b","after":[],"body":"y\n\n## Observable outcome\nThe slice acceptance test passes end to end."}]' > "$T/b/children.json"
OUT=$( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" AGENT_LOG="$T/agent.log" DECOMPOSE_DRY_RUN=1 \
       "$DEC" scoutish 552 TK-552 "$T/b" 300 12 2>&1 )
grep -q 'later()' "$T/b/children/child-2.md" \
  && bad "a forward reference must not become a declaration: $(cat "$T/b/children/child-2.md")" || ok
[ "$(grep -c '^Blocked-by' "$T/b/children/child-2.md")" -eq 1 ] \
  && ok || bad "the contract stays that sibling's only blocker: $(cat "$T/b/children/child-2.md")"
grep -qi "dropped 'after: 3" "$T/b/pipeline.log" \
  && ok || bad "dropping an ordering line must be said out loud: $(cat "$T/b/pipeline.log")"

# ===========================================================================
# 8. the board lane is NOT this path
# ===========================================================================
# widget-os has a real board prefix, so it takes the ticket-create path it took
# yesterday: the model files the children, and this script never runs gh.
rm -rf "$T/b"; mkdir -p "$T/b"
: > "$T/agent.log"
OUT=$( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" AGENT_LOG="$T/agent.log" DECOMPOSE_DRY_RUN=1 \
       "$DEC" widget-os tkt-1 WD-9 "$T/b" 300 12 2>&1 )
grep -q 'DRYRUN gh' <<<"$OUT" && bad "a board project must not be filed through gh (got: $OUT)" || ok
grep -q 'AGENT CALL: decompose widget-os' "$T/agent.log" \
  && ok || bad "the board lane still asks the model to file the children: $(cat "$T/agent.log")"

# ===========================================================================
# 9. the cost of a split is its own row
# ===========================================================================
# stage=decompose, not stage=plan: agent-call.sh writes the ledger row keyed on
# the stage it is handed, and a split priced inside planning makes "what has
# decomposition cost us" unanswerable.
grep -q 'AGENT CALL: decompose ' "$T/agent.log" \
  && ok || bad "the Fable call must be booked as stage=decompose: $(cat "$T/agent.log")"
grep -qE '^"?\$?HARNESS.*agent-call.sh" plan ' "$DEC" \
  && bad "no call in this script may still be booked as stage=plan" || ok

# ===========================================================================
# 10. an issues project this box cannot file into fails loudly, never silently
# ===========================================================================
rm -rf "$T/b"; mkdir -p "$T/b"
printf '%s\n' "$SPEC" > "$T/b/children.json"
OUT=$( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" AGENT_LOG="$T/agent.log" DECOMPOSE_DRY_RUN=1 \
       "$DEC" scoutish not-a-number BADKEY "$T/b" 300 12 2>&1 ); RC=$?
[ "$RC" -ne 0 ] && ok || bad "a key with no issue number must not exit 0"
grep -qi 'cannot derive an issue number' "$T/b/pipeline.log" \
  && ok || bad "it must name what it could not resolve: $(cat "$T/b/pipeline.log" 2>/dev/null)"

# ===========================================================================
# 11. a re-entered build does not file a second set of issues
# ===========================================================================
rm -rf "$T/b"; mkdir -p "$T/b"
printf 'TK-553\nTS-554\n' > "$T/b/children.txt"
printf '%s\n' "$SPEC" > "$T/b/children.json"
OUT=$( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" AGENT_LOG="$T/agent.log" DECOMPOSE_DRY_RUN=1 \
       "$DEC" scoutish 552 TK-552 "$T/b" 300 12 2>&1 ); RC=$?
[ "$RC" -eq 0 ] && ok || bad "an already-decomposed build must exit 0 (rc=$RC)"
grep -q 'already decomposed' "$T/b/pipeline.log" \
  && ok || bad "a resumed decompose must say it re-filed nothing: $(cat "$T/b/pipeline.log")"
[ "$(wc -l < "$T/b/children.txt")" -eq 2 ] \
  && ok || bad "the existing children list must be left alone"

echo "run-decompose-issues: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
