#!/bin/bash
# tests/planned-files-cheap.bh-580-test.sh — the per-ticket test-file reroute
# (#580/#586) inside bin/planned-files-cheap.sh, and the labels hand-off from
# bin/preplan-candidates.sh that tells it which tickets are BUGS.
#
# WHAT THIS PINS AND WHY. Test files are the fleet's largest merge-conflict
# surface — 20 of 24 unresolvable conductor cases were siblings appending cases
# to one shared tests/<area> file. The pre-plan list is the first place the
# harness can say "not that file, YOUR file", because it is the list the
# executor is later handed. So every assertion here is on the LIST the script
# wrote (plans/proj-<KEY>/planned-files.txt) and on the RECORD the lib wrote
# (state/preplan-files/proj-<KEY>) — never on the script's source text (D3).
#
# The three things that must never regress, in the order they cost the most:
#   1. a rerouted path ALWAYS has a record line. The record is what #584 and
#      #585 read to tell the executor where to write; a list that points at a
#      file nothing recorded is a build writing into the dark.
#   2. a BUG ticket is left alone. A bug's reproduction belongs next to the case
#      it fixes, so the kind decides before anything is rewritten.
#   3. the pass costs nothing new: no model call, no second GitHub request, and
#      the existing SOURCE:/dedup/model-floor behaviour byte-for-byte.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/planned-files-cheap.bh-580-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HARNESS="$T" FLEET_CONF="$T/fleet.conf"
mkdir -p "$T/bin/lib" "$T/env" "$T/flags" "$T/logs" "$T/plans" "$T/state" "$T/prompts" "$T/catalog"
cp "$DIR/bin/planned-files-cheap.sh" "$T/bin/" 2>/dev/null || { echo "FAIL: bin/planned-files-cheap.sh does not exist"; exit 1; }
cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$T/bin/lib/"
cp "$DIR/bin/kind-gate.sh" "$T/bin/" 2>/dev/null || { echo "FAIL: bin/kind-gate.sh does not exist"; exit 1; }
cp "$DIR/bin/lib/preplan-lib.sh" "$DIR/bin/lib/dep-verify-lib.sh" "$T/bin/lib/"
cp "$DIR/bin/lib/test-home-lib.sh" "$T/bin/lib/" 2>/dev/null || { echo "FAIL: bin/lib/test-home-lib.sh does not exist (#583 is this slice's hard blocker)"; exit 1; }
cp "$DIR/bin/fleet-conf.sh" "$T/bin/"
cp "$DIR/catalog/model-prices.json" "$T/catalog/"
cat > "$T/fleet.conf" <<'CONF'
proj  example-org/proj   -                 -           0 local -
CONF
echo 'setsid /root/harness/bin/run-build.sh proj <issue-number> AB-<issue-number> > x' > "$T/prompts/proj.md"

# ---- the repo the paths are checked against --------------------------------
# Three REAL files (a shared vitest suite, a shared shell suite, a source file)
# and one real directory. The reroute only ever touches a path that is a regular
# FILE here: a new test file is per-ticket by intent already, and a bare
# directory scope is not a file anyone writes cases into.
REPO="$T/repos/proj"
mkdir -p "$REPO/src/lib" "$REPO/tests/level2-unit/sub"
: > "$REPO/tests/level2-unit/org-report.test.ts"
: > "$REPO/tests/foo-test.sh"
: > "$REPO/src/lib/a.ts"
export REPOS_ROOT="$T/repos"

# ---- the stubs -------------------------------------------------------------
CALLDIR="$T/calls"; mkdir -p "$CALLDIR"; export CALLDIR
cat > "$T/bin/agent-call.sh" <<'STUB'
#!/bin/bash
# agent-call.sh <stage> <project> <model> <timeout> <outfile> <prompt|@file>
D="${CALLDIR:?}"
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$D/calls.tsv"
printf '%s\n' "${STUB_ANSWER:-src/lib/a.ts}" > "$5"
exit "${STUB_RC:-0}"
STUB
chmod +x "$T/bin/agent-call.sh"
export PATH="$T/bin:$PATH"

ncalls() { [ -s "$CALLDIR/calls.tsv" ] && grep -c . "$CALLDIR/calls.tsv" || echo 0; }
reset_calls() { scratch_rm "$CALLDIR"; mkdir -p "$CALLDIR"; }
run() { "$T/bin/planned-files-cheap.sh" proj "$@" >/dev/null 2>&1; }
list_of() { printf '%s\n' "$T/plans/proj-$1/planned-files.txt"; }
rec_of()  { printf '%s\n' "$T/state/preplan-files/proj-$1"; }
src_of()  { sed -n '1s/^SOURCE:[[:space:]]*//p' "$1"; }
nlines()  { grep -c . "$1" 2>/dev/null || echo 0; }
# "this key's list keeps the SHARED path and nothing was recorded" — the shape
# every not-a-reroute case has to prove, stated once.
kept() { # kept <KEY> <why>
  local L; L=$(list_of "$1")
  grep -qx 'tests/level2-unit/org-report.test.ts' "$L" && grep -qx 'tests/foo-test.sh' "$L" \
    && ok || bad "$2: the shared test paths must stay in the list (got: $(tr '\n' ' ' < "$L"))"
  grep -q "\.$(printf '%s' "$1" | tr 'A-Z' 'a-z')\." "$L" \
    && bad "$2: nothing may be rerouted to a per-ticket name" || ok
  [ -e "$(rec_of "$1")" ] && bad "$2: no reroute record may be written ($(rec_of "$1"))" || ok
}

# The body every case below uses: two shared test files and one source file,
# all three real in the scratch checkout.
BODY="$T/body.md"
cat > "$BODY" <<'MD'
## Scope
Extend the org report in `src/lib/a.ts`, and cover it in
`tests/level2-unit/org-report.test.ts` and `tests/foo-test.sh`.
MD

# ---------- 1. a feature ticket: the shared test files become this ticket's --
reset_calls
PLANNED_FILES_BODY_FILE="$BODY" run AB-40
L=$(list_of AB-40); R=$(rec_of AB-40)
[ -s "$L" ] && ok || bad "a body naming three paths must produce a list at $L"
[ "$(src_of "$L")" = "ticket-body" ] && ok \
  || bad "the reroute must not change which tier answered (got: $(src_of "$L"))"
grep -qx 'tests/level2-unit/org-report.ab-40.test.ts' "$L" && ok \
  || bad "the shared vitest suite must be rerouted to this ticket's own file (got: $(tr '\n' ' ' < "$L"))"
grep -qx 'tests/foo.ab-40-test.sh' "$L" && ok \
  || bad "the shared shell suite must be rerouted to this ticket's own file (got: $(tr '\n' ' ' < "$L"))"
grep -qx 'tests/level2-unit/org-report.test.ts' "$L" \
  && bad "the SHARED path must be gone from the list — leaving it is the merge conflict this exists to stop" || ok
grep -qx 'tests/foo-test.sh' "$L" \
  && bad "the shared shell suite must be gone from the list" || ok
grep -qx 'src/lib/a.ts' "$L" && ok || bad "a non-test path must be untouched"
grep -q 'REROUTE' "$L" \
  && bad "a REROUTE line must never reach the planned-files list — dep-verify reads every line as a path" || ok
# THE LOAD-BEARING HALF: a rerouted path that nothing recorded is a build
# writing into the dark, because #584/#585 read only the record.
[ "$(nlines "$R")" = 2 ] && ok || bad "the record must carry exactly one line per rerouted file (got: $(nlines "$R"))"
[ "$(grep -c '^REROUTE tests: ' "$R" 2>/dev/null || echo 0)" = 2 ] && ok \
  || bad "every record line must be in the lib's REROUTE format (got: $(tr '\n' '|' < "$R"))"
grep -qxF 'REROUTE tests: tests/level2-unit/org-report.test.ts -> tests/level2-unit/org-report.ab-40.test.ts' "$R" && ok \
  || bad "the record must name the shared file and its target (got: $(tr '\n' '|' < "$R"))"
grep -qxF 'REROUTE tests: tests/foo-test.sh -> tests/foo.ab-40-test.sh' "$R" && ok \
  || bad "the shell suite's record line is missing (got: $(tr '\n' '|' < "$R"))"
[ "$(ncalls)" = 0 ] && ok || bad "the reroute must not cost a model call (calls: $(ncalls))"

# ---------- 2. a second tick is idempotent ----------------------------------
# Two ticks on one key are normal (the candidates pass runs every 2 minutes) and
# there is no lock here by design, so the record has to be append-once.
cp "$L" "$T/list-before"
reset_calls
PLANNED_FILES_BODY_FILE="$BODY" run AB-40
[ "$(nlines "$R")" = 2 ] && ok || bad "a second run must not duplicate record lines (got: $(nlines "$R"))"
cmp -s "$T/list-before" "$L" && ok || bad "a second run must write the same list"

# ---------- 3. a BUG ticket is left alone ------------------------------------
# A bug's proof is a reproduction NEXT TO the case it fixes, so the reroute has
# to know the kind before it rewrites anything. Three sources, in the order the
# ticket gives them: the env override, the ticket META, the body's own line.
reset_calls
PLANNED_FILES_KIND=bug PLANNED_FILES_BODY_FILE="$BODY" run AB-41
kept AB-41 "PLANNED_FILES_KIND=bug"
PLANNED_FILES_KIND=Bug PLANNED_FILES_BODY_FILE="$BODY" run AB-51
kept AB-51 "PLANNED_FILES_KIND=Bug (any case)"

if command -v jq >/dev/null 2>&1; then
  cat > "$T/meta-bug.json" <<'JSON'
{"title":"the org report double-counts","labels":[{"name":"ai-build"},{"name":"bug"}]}
JSON
  PLANNED_FILES_META_FILE="$T/meta-bug.json" PLANNED_FILES_BODY_FILE="$BODY" run AB-42
  kept AB-42 "a bug LABEL on the ticket meta"
  cat > "$T/meta-feature.json" <<'JSON'
{"title":"org report: add the rollup","labels":[{"name":"ai-build"}]}
JSON
  PLANNED_FILES_META_FILE="$T/meta-feature.json" PLANNED_FILES_BODY_FILE="$BODY" run AB-43
  grep -qx 'tests/foo.ab-43-test.sh' "$(list_of AB-43)" && ok \
    || bad "a meta with no bug label must still reroute (got: $(tr '\n' ' ' < "$(list_of AB-43)"))"
else
  echo "planned-files-cheap.bh-580: SKIPPING the META cases — jq is not installed, and bin/kind-gate.sh reads labels through it"
fi

cat > "$T/body-bug.md" <<'MD'
## Scope
KIND: bug
The org report double-counts. Fix it in `src/lib/a.ts`; the failing case is in
`tests/level2-unit/org-report.test.ts` and `tests/foo-test.sh`.
MD
PLANNED_FILES_BODY_FILE="$T/body-bug.md" run AB-44
kept AB-44 "a KIND: bug line in the ticket body"
[ "$(ncalls)" = 0 ] && ok || bad "none of the kind cases may call a model (calls: $(ncalls))"

# ---------- 4. the paths that must NOT move ----------------------------------
# A file that does not exist yet is already per-ticket by intent, and rewriting
# it would invent a second new file nobody named.
cat > "$T/body-absent.md" <<'MD'
Add `tests/level2-unit/new.test.ts` and touch `src/lib/a.ts`.
MD
PLANNED_FILES_BODY_FILE="$T/body-absent.md" run AB-45
LA=$(list_of AB-45)
grep -qx 'tests/level2-unit/new.test.ts' "$LA" && ok \
  || bad "a test file that does not exist yet must be left exactly as the body named it (got: $(tr '\n' ' ' < "$LA"))"
[ -e "$(rec_of AB-45)" ] && bad "an absent file is not a reroute and must not be recorded" || ok

# A bare directory scope: it EXISTS, and it matches the test-path matcher, and
# it is nobody's test file. `tests/level2-unit/sub.ab-46` would be a path that
# cannot be written to.
cat > "$T/body-dir.md" <<'MD'
Work across `tests/level2-unit/sub/` and `src/lib/a.ts`.
MD
PLANNED_FILES_BODY_FILE="$T/body-dir.md" run AB-46
LD=$(list_of AB-46)
grep -qx 'tests/level2-unit/sub' "$LD" && ok \
  || bad "a bare directory scope must survive the pass unchanged (got: $(tr '\n' ' ' < "$LD"))"
grep -q 'sub\.ab-46' "$LD" && bad "a DIRECTORY must never be rewritten to a per-ticket file name" || ok
[ -e "$(rec_of AB-46)" ] && bad "a directory is not a reroute and must not be recorded" || ok

# A path that already carries a ticket key is somebody's own file — this
# ticket's, or (the safe direction) a sibling's.
cat > "$T/body-own.md" <<'MD'
Cover it in `tests/foo.ab-47-test.sh` and `src/lib/a.ts`.
MD
PLANNED_FILES_BODY_FILE="$T/body-own.md" run AB-47
grep -qx 'tests/foo.ab-47-test.sh' "$(list_of AB-47)" && ok \
  || bad "an already-per-ticket path must pass through unchanged (got: $(tr '\n' ' ' < "$(list_of AB-47)"))"
[ -e "$(rec_of AB-47)" ] && bad "a path that was already per-ticket is not a reroute" || ok

# ---------- 5. the model-floor tier is rerouted too --------------------------
# The floor model answers with the shared file just like a body does, and the
# executor is handed that list the same way — so the pass sits before BOTH
# write_list calls, not just the cheap one.
cat > "$T/body-nofiles.md" <<'MD'
## Scope
Make the weekly digest read better. No file names here on purpose.
MD
reset_calls
STUB_ANSWER=$'tests/level2-unit/org-report.test.ts\ntests/foo-test.sh' \
  PLANNED_FILES_BODY_FILE="$T/body-nofiles.md" run AB-48
LM=$(list_of AB-48)
[ "$(src_of "$LM")" = "model-floor" ] && ok || bad "this case must exercise tier 3 (got: $(src_of "$LM"))"
grep -qx 'tests/level2-unit/org-report.ab-48.test.ts' "$LM" && ok \
  || bad "the floor model's shared test path must be rerouted too (got: $(tr '\n' ' ' < "$LM"))"
grep -qx 'tests/foo.ab-48-test.sh' "$LM" && ok \
  || bad "the floor model's shared shell suite must be rerouted too"
[ "$(nlines "$(rec_of AB-48)")" = 2 ] && ok \
  || bad "the tier-3 reroute must be recorded like any other (got: $(nlines "$(rec_of AB-48)"))"
[ "$(ncalls)" = 1 ] && ok || bad "the floor model must still be called exactly once (calls: $(ncalls))"

# ---------- 6. the kill switch -----------------------------------------------
reset_calls
TEST_REROUTE=0 PLANNED_FILES_BODY_FILE="$BODY" run AB-49
kept AB-49 "TEST_REROUTE=0"
touch "$T/flags/test-reroute-off"
PLANNED_FILES_BODY_FILE="$BODY" run AB-52
kept AB-52 "flags/test-reroute-off"
rm -f "$T/flags/test-reroute-off"

# ---------- 7. an unwritable record means NOT REROUTED -----------------------
# rc 1 from th_record_add is a refusal, and the only safe reading of a refusal
# is "this path was not rerouted": the shared path stays, the list is still
# written, and the lane exits 0. A file where the directory should be, not a
# chmod — the fleet runs as root and root writes through a mode bit.
rm -rf "$T/state/preplan-files"; : > "$T/state/preplan-files"
PLANNED_FILES_BODY_FILE="$BODY" run AB-50; RC=$?
[ "$RC" = 0 ] && ok || bad "an unwritable record must not fail the lane (rc: $RC)"
L50=$(list_of AB-50)
[ -s "$L50" ] && ok || bad "an unwritable record must still leave a planned-files list"
grep -qx 'tests/level2-unit/org-report.test.ts' "$L50" && grep -qx 'tests/foo-test.sh' "$L50" && ok \
  || bad "with no record possible, the SHARED paths must stay in the list (got: $(tr '\n' ' ' < "$L50"))"
rm -f "$T/state/preplan-files"; mkdir -p "$T/state/preplan-files"

# ---------- 8. the lib missing altogether ------------------------------------
# A partially synced box. The pass must vanish, not break: the list is exactly
# what main writes today.
mv "$T/bin/lib/test-home-lib.sh" "$T/lib-parked.sh"
PLANNED_FILES_BODY_FILE="$BODY" run AB-53
kept AB-53 "bin/lib/test-home-lib.sh absent (a partially synced box)"
mv "$T/lib-parked.sh" "$T/bin/lib/test-home-lib.sh"

# ---------- 9. the caller: preplan-candidates hands over the labels ----------
# THE LEG THAT MAKES ANY OF THIS REACH A BOX (D2/D27). The kind only reaches the
# reroute if bin/preplan-candidates.sh writes the labels it ALREADY fetched next
# to the body it already had — so this drives the real per-child loop, with a
# fake `gh` that answers one `issue list` and fails anything else. Two children
# of one parent: 90 is labelled `bug` and must keep its shared file, 92 is not
# and must get its own.
#
# PLATFORM GATE, stated rather than silently passing: bin/preplan-candidates.sh
# sources bin/lib/preplan-lib.sh, which does not PARSE under bash 3.2. Probed
# with /bin/bash because that is the shebang every script in bin/ carries.
if ! /bin/bash -n "$T/bin/lib/preplan-lib.sh" 2>/dev/null; then
  echo "planned-files-cheap.bh-580: SKIPPING section 9 — this shell cannot parse bin/lib/preplan-lib.sh (bash 3.2); run it in the container"
  echo "planned-files-cheap.bh-580: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi
cp "$DIR/bin/preplan-candidates.sh" "$T/bin/"
# TEST-CHANGE (BH-782): bin/preplan-candidates.sh reads GitHub through the REST
# contract now; without gh-rest.sh beside it the tick answers "launch gate
# UNKNOWN" and never reaches the per-child loop this section is about.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/bin/lib/"
touch "$T/flags/preplan-speculative-off"
# TEST-CHANGE (BH-782): `gh api -i` shim — status line, blank line, body. Same
# two fixtures the GraphQL shim answered.
cat > "$T/bin/gh" <<'SH'
#!/bin/bash
[ "${1:-}" = api ] || exit 1
shift
INC=0; P=""
while [ $# -gt 0 ]; do
  case "$1" in
    -i) INC=1; shift ;;
    -X|-f|-F|-H) shift 2 ;;
    -*) shift ;;
    *) [ -n "$P" ] || P="$1"; shift ;;
  esac
done
case "$P" in
  */issues*) BODY=$(cat "$HARNESS/issues.json" 2>/dev/null || echo '[]') ;;
  */pulls*)  BODY='[]' ;;
  *)         exit 1 ;;
esac
[ "$INC" = 1 ] && printf 'HTTP/2.0 200\r\n\r\n'
printf '%s\n' "$BODY"
SH
chmod +x "$T/bin/gh"
cat > "$T/issues.json" <<'JSON'
[{"number":91,"state":"OPEN","title":"parent","body":"## Scope\nthe parent\n","labels":[]},
 {"number":90,"state":"OPEN","title":"child one","labels":[{"name":"ai-build"},{"name":"bug"}],
  "body":"## Scope\nThe report double-counts; the case is in `tests/foo-test.sh` and the cause in `src/lib/a.ts`.\nBlocked-by: #91\n"},
 {"number":92,"state":"OPEN","title":"child two","labels":[{"name":"ai-build"}],
  "body":"## Scope\nAdd the rollup in `src/lib/a.ts` and cover it in `tests/foo-test.sh`.\nBlocked-by: #91\n"}]
JSON
reset_calls
ROWS=$("$T/bin/preplan-candidates.sh" proj 2>/dev/null)
grep -q 'AB-90' <<<"$ROWS" && grep -q 'AB-92' <<<"$ROWS" && ok \
  || bad "both children must still be printed as rows (got: $ROWS)"
L92=$(list_of AB-92)
[ -s "$L92" ] && ok || bad "the unlabelled child must get a cheap list at $L92"
grep -qx 'tests/foo.ab-92-test.sh' "$L92" && ok \
  || bad "the unlabelled child's shared test file must be rerouted through the real candidates loop (got: $(tr '\n' ' ' < "$L92"))"
[ "$(nlines "$(rec_of AB-92)")" = 1 ] && ok \
  || bad "the unlabelled child must have exactly one record line (got: $(nlines "$(rec_of AB-92)"))"
if command -v jq >/dev/null 2>&1; then
  L90=$(list_of AB-90)
  [ -s "$L90" ] && ok || bad "the bug-labelled child must still get a list at $L90"
  grep -qx 'tests/foo-test.sh' "$L90" && ok \
    || bad "the bug LABEL must reach the reroute through \$BD/meta and keep the shared path (got: $(tr '\n' ' ' < "$L90"))"
  [ -e "$(rec_of AB-90)" ] && bad "a bug-labelled child must write no reroute record" || ok
else
  echo "planned-files-cheap.bh-580: SKIPPING the bug-label half of section 9 — no jq"
fi
[ "$(ncalls)" = 0 ] && ok || bad "the candidates pass must not have cost a model call (calls: $(ncalls))"

echo "planned-files-cheap.bh-580: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
