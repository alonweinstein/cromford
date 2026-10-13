#!/bin/bash
# tests/decompose-contract-first-test.sh — interface-first decomposition
# (BH-481, 2026-09-16): a split files ONE small contract child FIRST, hangs
# every sibling off that child and nothing else, and refuses a chain deeper
# than two levels beyond it.
#
# WHY (the operator, 2026-09-16). Children arrive as 3-5 level `Blocked-by` chains and
# each level is a 50-minute build, so a four-part split spends four sequential
# hours on a pool that is otherwise idle. Worse, the parents that carry those
# chains are big enough to collide with main and get rebuilt, and every child
# behind a rebuilt parent strands. A contract chunk of twenty lines almost never
# conflicts, so the wave it carries almost never strands: "a 400-engineer org
# lands the interface in a 20-line PR and fans out behind it."
#
# WHAT IS UNDER TEST. The exact bytes again, because the pipeline reads them:
# `Blocked-by: #<n> (hard)` is what bin/lib/dep-verify-lib.sh honours as the
# author's escape hatch (so nothing second-guesses the contract), and it is the
# same line bin/unblocked-children.sh parses to launch or stack the child. Both
# of those REAL parsers are fed the bodies this filer produces, rather than a
# regex written next to the regex under test.
#
# No network, no model call, no secrets. DECOMPOSE_DRY_RUN=1 prints the gh
# commands instead of running them and reuses a handed-in children.json instead
# of buying a Fable call. Run from anywhere:
#   tests/decompose-contract-first-test.sh     (exit 0 = all pass)
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
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T/h" scoutish || exit 1  # BH-1510.2: lanes read models from model_routes
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
# The ONE extractor (BH-579.4): the filer computes contested paths by running
# the real bin/planned-files.sh, so the scratch harness carries the real one.
cp "$DIR/bin/planned-files.sh" "$T/h/bin/"
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset> [box] [ip]
scoutish      example-org/scoutish   https://scoutish.example  -           9 box-1 10.0.0.9
CONF
export FLEET_CONF="$T/h/fleet.conf"
# agent-call must never be reached: every drive below hands in a spec.
printf '#!/bin/bash\necho "AGENT CALL: $*" >> "$AGENT_LOG"\nexit 0\n' > "$T/h/bin/agent-call.sh"
chmod +x "$T/h/bin/agent-call.sh"

# Prints the script's output and EXITS WITH ITS RC, so a caller reads the rc
# from the command substitution: `OUT=$(drive "$SPEC"); RC=$?`. Everything it
# writes lands in $T/b, which survives the subshell.
drive() { # drive <spec-json>
  rm -rf "$T/b"; mkdir -p "$T/b"
  printf '%s\n' "$1" > "$T/b/children.json"
  printf 'SIZE_DECLARED: files=18 lines=1900\nSIZE_OVER: lines=1900>300; files=18>12\nSIZE_VERDICT: over\n' > "$T/b/size-gate.txt"
  : > "$T/agent.log"
  env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" AGENT_LOG="$T/agent.log" \
      DECOMPOSE_DRY_RUN=1 "$DEC" scoutish 552 TK-552 "$T/b" 300 12 2>&1
}

# ===========================================================================
# 1. one contract child, four siblings, one parallel wave
# ===========================================================================
# The shape the decompose prompt asks for: the first object carries `contract`
# (the exported names and paths every sibling imports) and the rest are the
# siblings. Sibling 3 declares a real code dependency on sibling 2 and names
# the symbol, which is allowed — it is level 2, and the cap is 2.
WAVE='[
 {"title":"scan result types + empty store","contract":"src/lib/scan/types.ts: ScanRow, ScanStore; src/lib/scan/store.ts: readScan(), writeScan()","after":[],"body":"Types and a store that compiles and returns nothing yet.\n\nFiles: src/lib/scan/types.ts, src/lib/scan/store.ts\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"scan ingest","after":[],"body":"Fill the store from the queue.\n\nFiles: src/jobs/scan-ingest.ts\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"scan read API","after":[],"body":"Serve the store over HTTP.\n\nFiles: src/api/scan.ts\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"scan dashboard tile","after":["3: readScan()"],"body":"Render the tile.\n\nFiles: src/app/dashboard/ScanTile.tsx\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"weekly scan digest","after":[],"body":"Mail the digest.\n\nFiles: src/jobs/scan-digest.ts\n\n## Observable outcome\nThe slice acceptance test passes end to end."}
]'
OUT=$(drive "$WAVE"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "a contract-first split must exit 0 (rc=$RC): $OUT"
[ "$(grep -c '^DRYRUN gh issue create ' <<<"$OUT")" -eq 5 ] \
  && ok || bad "five children = five create commands (got: $OUT)"
[ -s "$T/agent.log" ] && bad "a dry run with a spec in hand must not buy a Fable call" || ok

# THE CONTRACT IS CHILD .0, and it is the only one.
[ "$(grep -c "TK-552\.0: contract — " <<<"$OUT")" -eq 1 ] \
  && ok || bad "exactly one child is the contract, titled 'TK-552.0: contract — <slice>' (got: $OUT)"
grep -q "TK-552.0: contract — scan result types + empty store'" <<<"$OUT" \
  && ok || bad "the contract keeps the model's own slice name after the prefix (got: $OUT)"
for n in 1 2 3 4; do
  grep -q "TK-552\.$n: " <<<"$OUT" && ok || bad "sibling .$n must be filed as 'TK-552.$n: <slice>' (got: $OUT)"
done

C0="$T/b/children/child-1.md"   # the contract, filed first
S1="$T/b/children/child-2.md"
S2="$T/b/children/child-3.md"
S3="$T/b/children/child-4.md"
S4="$T/b/children/child-5.md"
for F in "$C0" "$S1" "$S2" "$S3" "$S4"; do [ -s "$F" ] || bad "missing body file $F"; done
ok

# The contract names what it exports, or a sibling cannot know what to import.
grep -q '^CONTRACT: .*ScanRow' "$C0" && grep -q 'readScan()' "$C0" \
  && ok || bad "the contract child must carry a CONTRACT: line listing the exported names/paths: $(cat "$C0")"
grep -qi '^Blocked-by' "$C0" \
  && bad "the contract waits on nobody, it is what everything else waits on: $(cat "$C0")" || ok
# Small on purpose: this is the child every sibling is blocked on.
grep -qiE '60 lines of product code' "$C0" \
  && ok || bad "the contract child must carry its own (much smaller) budget: $(cat "$C0")"

# ===========================================================================
# 2. the contract blocks every sibling, and it is the ONLY blocker unless the
#    spec declared an import from a sibling
# ===========================================================================
# The dry run numbers children from the parent: 552 + position, so the contract
# is #553. A sibling blocked on anything the spec did not declare is a chain,
# which is the whole thing this change exists to stop.
for F in "$S1" "$S2" "$S4"; do
  N=$(grep -c '^Blocked-by' "$F")
  [ "$N" -eq 1 ] || bad "a sibling carries exactly one Blocked-by line, got $N: $(cat "$F")"
  grep -q '^Blocked-by: #553 (hard)$' "$F" \
    || bad "a sibling that declared no import must be blocked by the contract and NOTHING else: $(cat "$F")"
done
ok
# THE ONE EXCEPTION, and it is not an exception to the wave: a spec that says
# this slice imports sibling .2's readScan() is saying it needs that chunk's
# CODE, which is what Blocked-by means here. Declared as a comment only, the
# launcher would start it alongside the sibling it imports from and the build
# could not compile. So the sibling's number rides the SAME line, contract first.
grep -q '^Blocked-by: #553 (hard), #555 (hard)$' "$S3" \
  && ok || bad "a declared import from a sibling is a hard blocker on the same line, contract first: $(cat "$S3")"
[ "$(grep -c '^Blocked-by' "$S3")" -eq 1 ] \
  && ok || bad "it stays ONE Blocked-by line, the shape every parser reads: $(cat "$S3")"
grep -qE '^DEPENDS: #555 hard — .*readScan' "$S3" \
  && ok || bad "a hard sibling dependency is declared with the symbol that makes it one: $(cat "$S3")"
grep -qE '^DEPENDS: #553 hard' "$S1" \
  && ok || bad "the contract dependency is declared for the child's own plan (plan-contract §7): $(cat "$S1")"
grep -qE '^DEPENDS: #554 soft' "$S2" \
  && ok || bad "an independent sibling is declared soft, not left unsaid: $(cat "$S2")"

# ===========================================================================
# 3. the REAL parsers read the REAL lines
# ===========================================================================
# (a) the escape hatch. `(hard)` is what bin/lib/dep-verify-lib.sh honours with
# no verification at all, and the contract IS hard: every sibling imports it.
# shellcheck source=bin/lib/dep-verify-lib.sh
. "$DIR/bin/lib/dep-verify-lib.sh" 2>/dev/null
if command -v dep_declared_hard >/dev/null 2>&1; then
  dep_declared_hard 553 "$S1" \
    && ok || bad "dep-verify must read this Blocked-by line as the author's hard declaration: $(cat "$S1")"
else
  bad "bin/lib/dep-verify-lib.sh did not load — the escape hatch is unproven"
fi

# (b) the launcher. bin/unblocked-children.sh is what actually launches the wave
# when the contract closes, so the produced bodies go through IT: all four
# siblings must come out unblocked on the one closure.
mkdir -p "$T/gh"
printf '#!/bin/bash\n. "${GH_CLI_REST_ADAPTER:?}" || exit 1; gh_cli_rest "$0" "$@" && exit 0\ncat "$ISSUES_JSON"\n' > "$T/gh/gh"; chmod +x "$T/gh/gh"
mkdir -p "$T/h/bin/lib"; cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" "$T/h/bin/lib/"
B1=$(jq -Rs . < "$S1"); B2=$(jq -Rs . < "$S2"); B3=$(jq -Rs . < "$S3"); B4=$(jq -Rs . < "$S4")
jq -nc --argjson b1 "$B1" --argjson b2 "$B2" --argjson b3 "$B3" --argjson b4 "$B4" '[
  {"number":553,"state":"CLOSED","title":"TK-552.0: contract — scan result types + empty store","body":"Part of #552"},
  {"number":554,"state":"OPEN","title":"TK-552.1: scan ingest","body":$b1},
  {"number":555,"state":"OPEN","title":"TK-552.2: scan read API","body":$b2},
  {"number":556,"state":"OPEN","title":"TK-552.3: scan dashboard tile","body":$b3},
  {"number":557,"state":"OPEN","title":"TK-552.4: weekly scan digest","body":$b4}
]' > "$T/issues.json"
UNB=$(PATH="$T/gh:$PATH" ISSUES_JSON="$T/issues.json" HARNESS="$T/h" GH_ISSUES_REPO="example-org/scoutish" \
      "$DIR/bin/unblocked-children.sh" scoutish <<<'board issues: CHANGED 553 "TK-552.0" (state: OPEN -> CLOSED)' 2>/dev/null)
W=0
for n in 554 555 557; do grep -q "UNBLOCKED $n " <<<"$UNB" || W=1; done
[ "$W" -eq 0 ] && ok || bad "the wave must come out unblocked on the contract's closure (got: '$UNB')"
# ...and the one child that declared an import from #555 must NOT, because #555
# is still open. A blocker that the launcher ignores is a blocker that is not
# one, and this is the assertion that proves the second number is real.
grep -q 'UNBLOCKED 556 ' <<<"$UNB" \
  && bad "the child that imports #555 must wait for it, not ride the contract's closure (got: '$UNB')" || ok

# (c) the expected path is not waiting for the contract to MERGE. Stacked
# builds put the siblings on the contract's branch the minute its PR opens, and
# the prompt has to say so or the model writes chains to avoid the wait.
grep -q 'STACK_BASE' "$DEC" \
  && ok || bad "the decompose prompt must document the stacked path on the contract branch"

# (d) TRACER FIRST (BH-3954, an intentional change to this suite): child 1 is
# the thinnest end-to-end path, not a stub contract, and every child names its
# observable outcome. The bodies above carry that section for the same reason.
grep -q 'TRACER FIRST' "$DEC" \
  && ok || bad "the decompose prompt must put the tracer first (BH-3954)"
grep -q 'Observable outcome' "$DEC" \
  && ok || bad "the decompose prompt must require an Observable outcome section in every child (BH-3954)"
grep -q 'stubs that compile and do nothing useful' "$DEC" \
  && bad "the decompose prompt must no longer ask for stubs that compile and do nothing useful (BH-3954)" || ok

# ===========================================================================
# 4. a chain deeper than the contract + 2 is refused, loudly
# ===========================================================================
refuse() { # refuse <spec-json> <why> <reason-substring>
  local out rc
  out=$(drive "$1"); rc=$?
  [ "$rc" -ne 0 ] || { bad "$2 must not exit 0: $out"; return; }
  [ -s "$T/b/children.txt" ] && { bad "$2 must file nothing"; return; }
  grep -q '^DRYRUN gh issue create ' <<<"$out" && { bad "$2 must refuse BEFORE it files a child"; return; }
  grep -qi "DECOMPOSE_FAILED" "$T/b/decompose-run.txt" 2>/dev/null \
    || { bad "$2 must write DECOMPOSE_FAILED to decompose-run.txt (the artifact the sweep reads)"; return; }
  grep -qi "$3" "$T/b/decompose-run.txt" 2>/dev/null \
    && ok || bad "$2 must say why: $(cat "$T/b/decompose-run.txt" 2>/dev/null)"
  grep -qi 'decompose FAILED' "$T/b/pipeline.log" 2>/dev/null \
    && ok || bad "$2 must also land in pipeline.log: $(cat "$T/b/pipeline.log" 2>/dev/null)"
}
# contract -> A -> B -> C is three levels past the contract. That is a
# decomposition failure, not a dependency: whatever C waits on belongs in the
# contract.
refuse '[
 {"title":"types","contract":"src/lib/t.ts: T","after":[],"body":"x"},
 {"title":"A","after":[],"body":"x"},
 {"title":"B","after":["2: a()"],"body":"x"},
 {"title":"C","after":["3: b()"],"body":"x"}
]' "a three-level chain beyond the contract" "chain levels beyond the contract"

# ...and exactly two levels is fine, or the cap is off by one.
TWO='[
 {"title":"types","contract":"src/lib/t.ts: T","after":[],"body":"x\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"A","after":[],"body":"x\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"B","after":["2: a()"],"body":"x\n\n## Observable outcome\nThe slice acceptance test passes end to end."}
]'
OUT=$(drive "$TWO"); RC=$?
[ "$RC" -eq 0 ] && [ "$(grep -c '^DRYRUN gh issue create ' <<<"$OUT")" -eq 3 ] \
  && ok || bad "two levels beyond the contract is the cap, not one over it (rc=$RC): $OUT"

# ===========================================================================
# 5. a split with no contract at all is refused
# ===========================================================================
# Without it there is nothing for the wave to hang off, and the children come
# back as the chain this change exists to stop.
refuse '[
 {"title":"A","after":[],"body":"x"},
 {"title":"B","after":[1],"body":"x"}
]' "a split with no contract child" "contract"

# ===========================================================================
# 6. siblings that name a path the contract also names carry CONTESTED lines
# ===========================================================================
# BH-579.4. The contract owns the paths it moves, so a sibling that names one of
# them is working on a file that is about to change under it. The filer says so
# in the sibling's own body, directly after the Blocked-by line, and repeats the
# deduped set in the split comment. The paths come from bin/planned-files.sh —
# the ONE extractor every other reader of a planned-files list runs — over the
# CONTRACT: string and child 1's body together, so "the paths the contract
# names" cannot mean two different sets.
SHARE='[
 {"title":"config types","contract":"src/x.ts: Config, loadConfig()","after":[],"body":"Extract the loader.\n\nFiles: src/x.ts, src/loader.ts\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"untouched","after":[],"body":"Own file only.\n\nFiles: src/jobs/a.ts\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"shares x","after":[],"body":"Reads the loader in place.\n\nFiles: src/x.ts, src/jobs/b.ts. Also touches src/x.ts once more.\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"shares a body-only path","after":[],"body":"Files: src/loader.ts, src/x.ts, src/jobs/c.ts\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"near miss","after":[],"body":"Files: src/x.tsx\n\n## Observable outcome\nThe slice acceptance test passes end to end."}
]'
OUT=$(drive "$SHARE"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "a split with shared paths still exits 0 (rc=$RC): $OUT"
[ "$(grep -c '^DRYRUN gh issue create ' <<<"$OUT")" -eq 5 ] \
  && ok || bad "five children = five create commands (got: $OUT)"
[ -s "$T/agent.log" ] && bad "computing contested paths must not buy a Fable call" || ok

K1="$T/b/children/child-2.md"   # untouched          -> #554
K2="$T/b/children/child-3.md"   # shares src/x.ts    -> #555
K3="$T/b/children/child-4.md"   # shares src/loader.ts and src/x.ts -> #556
K4="$T/b/children/child-5.md"   # src/x.tsx, near miss -> #557

# The line sits directly after Blocked-by, which is where a builder reading the
# issue meets the ordering it already has to obey.
[ "$(grep -A1 '^Blocked-by: #553 (hard)$' "$K2" | tail -1)" = 'CONTESTED: src/x.ts -> #553' ] \
  && ok || bad "the contested path is named directly after the Blocked-by line: $(cat "$K2")"
# Its body names src/x.ts twice; the extractor's list is deduped, so is this.
[ "$(grep -c '^CONTESTED:' "$K2")" -eq 1 ] \
  && ok || bad "one line per shared path, deduped: $(cat "$K2")"
# ...and it gets the paths IT names, not every path the contract owns.
[ "$(grep -c '^CONTESTED: src/loader.ts' "$K2")" -eq 0 ] \
  && ok || bad "a sibling is only told about the contract paths it names itself: $(cat "$K2")"
[ "$(grep -c '^Blocked-by' "$K2")" -eq 1 ] && grep -q '^Blocked-by: #553 (hard)$' "$K2" \
  && ok || bad "the contested line must not disturb the Blocked-by line: $(cat "$K2")"

# A sibling that shares nothing is untouched: no line, and it stays in the wave
# on the contract's hard blocker alone (BH-481).
[ "$(grep -c '^CONTESTED:' "$K1")" -eq 0 ] \
  && ok || bad "a sibling with no shared path gets no contested line: $(cat "$K1")"
[ "$(grep -c '^Blocked-by' "$K1")" -eq 1 ] && grep -q '^Blocked-by: #553 (hard)$' "$K1" \
  && ok || bad "a sibling with no shared path keeps exactly its contract blocker: $(cat "$K1")"
[ "$(grep -c '^DEPENDS' "$K1")" -eq 1 ] && grep -qE '^DEPENDS: #553 hard' "$K1" \
  && ok || bad "a sibling with no shared path keeps exactly its contract DEPENDS line: $(cat "$K1")"

# THE UNION RULE: src/loader.ts is named by child 1's BODY and not by the
# CONTRACT: string, and it still counts as the contract's path.
grep -q '^CONTESTED: src/loader.ts -> #553$' "$K3" \
  && ok || bad "the contract's paths are its CONTRACT: string AND its body: $(cat "$K3")"
# This one shares two paths, so it carries two lines, sorted.
[ "$(grep -c '^CONTESTED:' "$K3")" -eq 2 ] \
  && ok || bad "a sibling gets one line per shared path: $(cat "$K3")"
[ "$(grep '^CONTESTED:' "$K3" | tail -1)" = 'CONTESTED: src/x.ts -> #553' ] \
  && ok || bad "the lines are sorted by path, the order the extractor hands them over: $(cat "$K3")"

# Exact string match: src/x.tsx is not src/x.ts.
[ "$(grep -c '^CONTESTED:' "$K4")" -eq 0 ] \
  && ok || bad "a near-miss path is not a shared path: $(cat "$K4")"

# The same set, deduped, in the comment the parent thread gets: two siblings
# name src/x.ts and the thread hears about it once.
CM="$T/b/decompose-comment.md"
[ "$(grep -c '^CONTESTED: src/x.ts -> #553$' "$CM")" -eq 1 ] \
  && ok || bad "the split comment lists the contested path once: $(cat "$CM")"
[ "$(grep -c '^CONTESTED: src/loader.ts -> #553$' "$CM")" -eq 1 ] \
  && ok || bad "the split comment lists every contested path: $(cat "$CM")"
[ "$(grep -c '—' "$CM")" -le 1 ] \
  && ok || bad "the comment stays in the project's voice, near-zero em dashes: $(cat "$CM")"

# NEGATIVE: nothing shared, nothing said. No copy about contested paths over an
# empty list.
OUT=$(drive "$TWO"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "a split with no shared path still exits 0 (rc=$RC): $OUT"
[ "$(grep -c 'CONTESTED' "$T/b/decompose-comment.md")" -eq 0 ] \
  && ok || bad "no contested copy when nothing is shared: $(cat "$T/b/decompose-comment.md")"
# The SENTENCE goes too, not just the list under it: copy that promises a list
# and then shows nothing is copy that is false in the state it renders in.
[ "$(grep -c "the contract's to move" "$T/b/decompose-comment.md")" -eq 0 ] \
  && ok || bad "the contested sentence must not render over an empty list: $(cat "$T/b/decompose-comment.md")"
[ -z "$(grep -l 'CONTESTED' "$T/b"/children/*.md 2>/dev/null)" ] \
  && ok || bad "no contested line in any child when nothing is shared"

# ===========================================================================
# 7. the extractor running and failing on ONE body is not silent (D11 rule,
#    checked per call): a swallowed mid-run failure must not read as "nothing
#    shared" for that sibling, and must not stop the siblings around it.
# ===========================================================================
cp "$T/h/bin/planned-files.sh" "$T/h/bin/planned-files-real.sh"
cat > "$T/h/bin/planned-files.sh" <<'WRAP'
#!/bin/bash
# test double: fails only for child-3's body (the "shares x" sibling), so the
# test proves the failure is caught per call, not a global outage.
#
# It dies the way the REAL extractor would (BH-1343): bin/planned-files.sh
# writes planned-files.txt progressively (`>` at line 13, `>>` at 16, a rewrite
# at 19-20), so a mid-run death leaves a PARTIAL list on disk, not no file at
# all. That distinction is the whole point of the double: with no file, the
# `|| return 2` arm and a plain `sort` of a missing file are indistinguishable
# (both yield nothing), so the assertions below could not tell them apart. With
# a partial list that names a path the contract owns, deleting `|| return 2`
# produces a CONTESTED line and the assertion goes red.
case "$1" in
  */child-3)
    printf 'src/x.ts\n' > "$1/planned-files.txt"
    echo 'boom: test double died mid-run' >&2
    exit 1 ;;
esac
exec "$(dirname "$0")/planned-files-real.sh" "$@"
WRAP
chmod +x "$T/h/bin/planned-files.sh"

OUT=$(drive "$SHARE"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "one sibling's extractor failure must not fail the whole split (rc=$RC): $OUT"
[ "$(grep -c '^DRYRUN gh issue create ' <<<"$OUT")" -eq 5 ] \
  && ok || bad "the other four siblings still file (got: $OUT)"

grep -qE "WARN:.*failed on child 3's body" "$T/b/pipeline.log" 2>/dev/null \
  && ok || bad "a mid-run extractor failure logs a WARN naming the sibling: $(cat "$T/b/pipeline.log" 2>/dev/null)"

# The partial list the extractor left is EVIDENCE, so the driver leaves it
# exactly as it found it. Nothing truncates or deletes it.
[ "$(cat "$T/b/decompose-paths/child-3/planned-files.txt" 2>/dev/null)" = 'src/x.ts' ] \
  && ok || bad "the partial list the dying extractor wrote stays on disk untouched: $(cat "$T/b/decompose-paths/child-3/planned-files.txt" 2>/dev/null)"
# ...and the WARN names both halves of what happened: WHY it failed (the rc and
# the extractor's own first stderr line) and WHAT it had written when it died.
# A WARN that says only "it failed" leaves the next reader running the extractor
# by hand to find out.
grep -qE "WARN:.*failed on child 3's body \(rc=1: boom.*\).*partial list.*src/x\.ts" "$T/b/pipeline.log" 2>/dev/null \
  && ok || bad "the WARN carries the failure reason and the partial list: $(cat "$T/b/pipeline.log" 2>/dev/null)"

K3F="$T/b/children/child-3.md"   # "shares x" — its own extractor call failed
# MUTATION GUARD (D1): child-3's partial list names src/x.ts, which the contract
# owns, so this count is 1 the moment `|| return 2` stops firing. The old
# no-file double could not catch that deletion.
[ "$(grep -c '^CONTESTED:' "$K3F")" -eq 0 ] \
  && ok || bad "a sibling whose extractor call failed gets no contested line (silent false-negative, not a guess): $(cat "$K3F")"
[ "$(grep -c '^Blocked-by' "$K3F")" -eq 1 ] && grep -q '^Blocked-by: #553 (hard)$' "$K3F" \
  && ok || bad "the failed sibling keeps its contract blocker untouched: $(cat "$K3F")"

# The sibling AFTER the failed one still gets its own contested lines: one
# body's extractor failure does not poison CONTRACT_PATHS or later siblings.
K4F="$T/b/children/child-4.md"   # "shares a body-only path" -> src/loader.ts, src/x.ts
grep -q '^CONTESTED: src/loader.ts -> #553$' "$K4F" \
  && ok || bad "a later sibling's contested lines survive an earlier sibling's extractor failure: $(cat "$K4F")"
[ "$(grep -c '^CONTESTED:' "$K4F")" -eq 2 ] \
  && ok || bad "the later sibling still gets both its contested lines: $(cat "$K4F")"

rm -f "$T/h/bin/planned-files-real.sh"
cp "$DIR/bin/planned-files.sh" "$T/h/bin/planned-files.sh"

echo "decompose-contract-first: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
