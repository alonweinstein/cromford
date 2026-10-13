#!/bin/bash
# tests/e2e-smoke-personas-test.sh — BH-535: the preview lane drives personas.
#
# WHY DRIVEN AND NOT GREPPED. What this slice adds to bin/e2e-smoke.sh is a
# decision tree about ABSENCE: no personas file, a persona nothing in the diff
# touches, no QA account for a role, no QA env on the box, a wrapper that
# declined the unban window, a drive that printed nothing. Every one of those
# must come out as a recorded `blocked` row and a stage that still exits 0 —
# never a pass laundered from silence, and never a block. A grep over the source
# would pass just as happily on a version that exits 1 and stalls every UI build
# in the fleet, or on one that stamps PASS with no drive having run.
#
# So the real script is copied into a scratch tree and driven end to end, with
# node, wait-preview.sh, qa-unbanned.sh and qa-account.sh stubbed. Every assert
# reads an ARTIFACT — $T/out/e2e.md, the argv sink, the unban sink, the scoped
# document, the stage's rc — never the script's text. No network, no Clerk, no
# secrets (the fake secret's absence from the record is itself a case).
#
# Run from anywhere: tests/e2e-smoke-personas-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/bin/lib" "$T/out" "$T/repo/qa"
cp "$DIR/bin/e2e-smoke.sh" "$T/bin/"
cp "$DIR/bin/e2e-smoke.mjs" "$T/bin/"
cp "$DIR/bin/lib/qa-personas.sh" "$T/bin/lib/"
cp "$DIR/catalog/e2e-smoke-routes.json" "$T/routes.json"
printf 'demo-os team_x prj_x os.demo.example\n' > "$T/vercel.conf"
cp "$DIR/tests/fixtures/qa-personas/valid.json" "$T/personas-valid.json"
cp "$T/personas-valid.json" "$T/repo/qa/personas.json"
cp "$DIR/tests/fixtures/qa-personas/apps.json" "$T/repo/qa/apps.json"

# --- stubs -------------------------------------------------------------------
cat > "$T/bin/wait-preview.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$WP_SINK"
echo "https://demo-os-git-feat-abc123.vercel.app"
EOF
chmod +x "$T/bin/wait-preview.sh"

# Fake node. It stands in for BOTH node calls the stage makes, and tells them
# apart the way the real ones differ: the drive carries --flows.
#   route smoke: <e2e-smoke.mjs> <preview> <out-dir> <repo>
#   drive:       <qa-drive.mjs>  <preview> <repo> <out-dir> --flows F --persona P --preview
cat > "$T/bin/fakenode" <<'EOF'
#!/bin/bash
printf 'ARGV %s\n' "$*" >> "$NODE_SINK"
printf 'ENV QA_TEST_USER_ID=%s\n' "${QA_TEST_USER_ID:-}" >> "$NODE_SINK"
SMOKE_OUT="${3:-}"; DRIVE_OUT="${4:-}"
SCOPEDF=""; PERSONA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --flows)   SCOPEDF="${2:-}"; shift ;;
    --persona) PERSONA="${2:-}"; shift ;;
  esac
  shift
done
if [ -n "$SCOPEDF" ]; then
  case "${DRIVE_MODE:-pass}" in
    pass) jq -r --arg p "$PERSONA" --arg d "$DRIVE_OUT" \
            '.personas[]|select(.id==$p)|.id as $i|.flows[]|"FLOW \($i) \(.id) pass steps=2/2 shot=\($d)/\(.id).png"' \
            "$SCOPEDF"; exit 0 ;;
    fail) jq -r --arg p "$PERSONA" --arg d "$DRIVE_OUT" \
            '.personas[]|select(.id==$p)|.id as $i|.flows[0]|"FLOW \($i) \(.id) fail steps=1/2 shot=\($d)/\(.id).png expect timed out"' \
            "$SCOPEDF"; exit 4 ;;
    norows) echo "nothing to see"; exit "${DRIVE_RC:-1}" ;;
  esac
fi
case "${NODE_MODE:-pass}" in
  pass) printf 'ROUTE 200 / console=0 ok\nE2E COVERAGE: routes=1 failed=0\nE2E: PASS\n' > "$SMOKE_OUT/e2e.md"; exit 0 ;;
  fail) printf 'ROUTE 500 /clients console=2 FAIL\nE2E COVERAGE: routes=2 failed=1\nE2E: FAIL\n' > "$SMOKE_OUT/e2e.md"; exit 4 ;;
esac
EOF
chmod +x "$T/bin/fakenode"

# The unban wrapper: records (project, role), then either declines with the rc
# under test or execs the drive, exactly as bin/qa-unbanned.sh does after --.
cat > "$T/bin/qa-unbanned-stub" <<'EOF'
#!/bin/bash
printf '%s %s\n' "$1" "$2" >> "$UNBAN_SINK"
[ -n "${FORCE_RC:-}" ] && exit "$FORCE_RC"
shift 3
exec "$@"
EOF
chmod +x "$T/bin/qa-unbanned-stub"

cat > "$T/bin/qa-account-stub" <<'EOF'
#!/bin/bash
case "${2:-}" in
  qa-admin) echo user_admin1 ;;
  qa-owner) echo user_owner1 ;;
  *) echo "no QA account for ${1:-}/${2:-}" >&2; exit 1 ;;
esac
EOF
chmod +x "$T/bin/qa-account-stub"

# run -> RC, and the record in $T/out/e2e.md. Knobs are plain variables so each
# case reads as one sentence; every one of them is reset by the caller.
run() {
  rm -rf "$T/out"; mkdir -p "$T/out"
  : > "$T/wp.log"; : > "$T/node.log"; : > "$T/unban.log"
  local E=()
  if [ "${NOSECRET:-0}" = 1 ]; then E+=(-u QA_CLERK_SECRET_KEY)
  else E+=(QA_CLERK_SECRET_KEY=sk_test_fake); fi
  [ -n "${CHANGED:-}" ]   && E+=("E2E_CHANGED_FILES=$CHANGED")
  [ -n "${USEBASE:-}" ]   && E+=("E2E_BASE_REF=$USEBASE")
  [ -n "${MAXP:-}" ]      && E+=("E2E_MAX_PERSONAS=$MAXP")
  [ -n "${FORCE_RC:-}" ]  && E+=("FORCE_RC=$FORCE_RC")
  [ -n "${DRIVE_RC:-}" ]  && E+=("DRIVE_RC=$DRIVE_RC")
  env "${E[@]}" \
    HARNESS="$T" VERCEL_CONF="$T/vercel.conf" E2E_ROUTES_FILE="$T/routes.json" \
    WAIT_PREVIEW="$T/bin/wait-preview.sh" E2E_NODE="$T/bin/fakenode" \
    E2E_QA_UNBANNED="$T/bin/qa-unbanned-stub" E2E_QA_ACCOUNT="$T/bin/qa-account-stub" \
    WP_SINK="$T/wp.log" NODE_SINK="$T/node.log" UNBAN_SINK="$T/unban.log" \
    NODE_MODE="${NODE_MODE:-pass}" DRIVE_MODE="${DRIVE_MODE:-pass}" \
    bash "$T/bin/e2e-smoke.sh" demo-os example-org/demo-os abc123def456 "$T/out" "$T/repo" \
      > "$T/stdout.log" 2>&1
  RC=$?
}
changed() { printf '%s\n' "$@" > "$T/changed.txt"; CHANGED="$T/changed.txt"; }
LAST()    { tail -1 "$T/out/e2e.md" 2>/dev/null; }
E2EMD()   { cat "$T/out/e2e.md" 2>/dev/null; }
NFLOWS()  { grep -c -- '--flows' "$T/node.log" 2>/dev/null | tr -d ' '; }
LINENO_OF() { grep -n -- "$1" "$T/out/e2e.md" 2>/dev/null | head -1 | cut -d: -f1; }
RESET()   { CHANGED=""; USEBASE=""; MAXP=""; FORCE_RC=""; DRIVE_RC=""; NOSECRET=0
            NODE_MODE=pass; DRIVE_MODE=pass; }
RESET

echo "--- 1. an admin-only diff drives the admin persona, once, on the preview"
changed "apps/admin/pages/x.tsx"
run
[ "$(NFLOWS)" = 1 ] \
  && ok || bad "an admin-only diff must drive exactly one persona (--flows calls: $(NFLOWS)): $(cat "$T/node.log")"
grep -q -- '--persona admin' "$T/node.log" \
  && ok || bad "the drive was not told which persona it is: $(cat "$T/node.log")"
grep -q -- '--preview' "$T/node.log" \
  && ok || bad "the drive ran without --preview, so the engine's fail-closed production default would apply"
grep -qF "$T/out/e2e-flows/scoped.json" "$T/node.log" \
  && ok || bad "the drive was not handed the scoped document: $(cat "$T/node.log")"
grep -qF "$T/out/e2e-flows/admin" "$T/node.log" \
  && ok || bad "the drive has no per-persona out-dir: $(cat "$T/node.log")"
grep -qF "$T/bin/qa-drive.mjs" "$T/node.log" \
  && ok || bad "the flow engine was never the thing invoked: $(cat "$T/node.log")"
grep -qx 'ENV QA_TEST_USER_ID=user_admin1' "$T/node.log" \
  && ok || bad "the QA account id from the map never reached the drive: $(cat "$T/node.log")"
grep -qE 'ARGV .*/e2e-smoke\.mjs https://' "$T/node.log" \
  && ok || bad "the route smoke did not run — the persona lane replaced it instead of following it"
grep -qx 'demo-os qa-admin' "$T/unban.log" \
  && ok || bad "the drive did not go through the unban wrapper for the persona's role: $(cat "$T/unban.log")"
grep -q -- '--persona owner' "$T/node.log" \
  && bad "a persona nothing in the diff touches was driven anyway" || ok
{ [ "$RC" = 0 ] && [ "$(LAST)" = "E2E: PASS" ]; } \
  && ok || bad "a clean smoke + a clean drive must be rc 0 / E2E: PASS (rc=$RC last='$(LAST)')"

echo "--- 2. nothing mapped and no UI file: the existing SKIP, before any preview wait"
changed "tests/foo.sh"
run
{ [ "$RC" = 3 ] && [ "$(LAST)" = "E2E: SKIP" ]; } \
  && ok || bad "a diff with no UI and no persona must SKIP (rc=$RC last='$(LAST)')"
[ "$(NFLOWS)" = 0 ] \
  && ok || bad "a persona was driven for a diff that maps to none"
[ -s "$T/wp.log" ] \
  && bad "the stage waited on a preview it was about to skip: $(cat "$T/wp.log")" || ok
grep -q 'no UI-touching files' "$T/out/e2e.md" \
  && ok || bad "the skip does not carry the existing sentence: $(E2EMD)"

echo "--- 3/13. a UI file outside every app glob: today's output, byte for byte"
# The reference: the same diff in a repo with no qa/ directory at all.
mv "$T/repo/qa" "$T/qa-parked"
changed "lib/components/x.tsx"
run
cp "$T/out/e2e.md" "$T/ref-noqa.md"
{ [ "$RC" = 0 ] && grep -qx 'E2E COVERAGE: routes=1 failed=0' "$T/out/e2e.md"; } \
  && ok || bad "a repo with no personas file must keep the two-field coverage line (rc=$RC): $(E2EMD)"
grep -q '^Personas:' "$T/out/e2e.md" \
  && bad "a repo with no personas file grew a Personas: line" || ok
[ -d "$T/out/e2e-flows" ] \
  && bad "a repo with no personas file created an e2e-flows directory" || ok
mv "$T/qa-parked" "$T/repo/qa"
run
[ "$(NFLOWS)" = 0 ] \
  && ok || bad "a UI file outside every app glob drove a persona: $(cat "$T/node.log")"
cmp -s "$T/out/e2e.md" "$T/ref-noqa.md" \
  && ok || bad "scope NONE with UI files changed the record: $(diff "$T/ref-noqa.md" "$T/out/e2e.md")"

echo "--- 4. in preview, a write flow keeps its steps (it is not a production skip)"
changed "src/x.ts"
run
jq -e '.personas[]|select(.id=="owner")|.flows[]|select(.id=="new-scan")
       |((.steps|length) > 0) and (.skipped == null)' "$T/out/e2e-flows/scoped.json" >/dev/null 2>&1 \
  && ok || bad "the preview scoped file skipped the write flow: $(cat "$T/out/e2e-flows/scoped.json" 2>/dev/null)"
jq -e '.mode == "preview"' "$T/out/e2e-flows/scoped.json" >/dev/null 2>&1 \
  && ok || bad "the scoped document was not built in preview mode"

echo "--- 5/14. the FLOW rows, their order, the coverage line, and no secret"
changed "src/x.ts"
run
grep -qE '^FLOW owner dashboard pass steps=2/2 shot=.*/dashboard\.png$' "$T/out/e2e.md" \
  && ok || bad "the dashboard flow's row is not in the record: $(E2EMD)"
grep -qE '^FLOW owner new-scan pass steps=2/2 shot=.*/new-scan\.png$' "$T/out/e2e.md" \
  && ok || bad "the new-scan flow's row is not in the record: $(E2EMD)"
FL=$(LINENO_OF '^FLOW '); CL=$(LINENO_OF '^E2E COVERAGE:'); PL=$(LINENO_OF '^Personas:')
{ [ -n "$FL" ] && [ -n "$CL" ] && [ "$FL" -lt "$CL" ]; } \
  && ok || bad "the FLOW rows are not before the coverage line (flow=$FL coverage=$CL): $(E2EMD)"
{ [ -n "$PL" ] && [ -n "$FL" ] && [ "$PL" -lt "$FL" ]; } \
  && ok || bad "no Personas: line precedes the FLOW rows (personas=$PL flow=$FL): $(E2EMD)"
grep -qx 'Personas: 1 in scope, 1 driven (mode preview)' "$T/out/e2e.md" \
  && ok || bad "the Personas: line does not say what really happened: $(E2EMD)"
grep -qx 'E2E COVERAGE: routes=1 failed=0 flows=2 flows_failed=0 flows_blocked=0' "$T/out/e2e.md" \
  && ok || bad "the extended coverage line is wrong: $(E2EMD)"
{ [ "$RC" = 0 ] && [ "$(LAST)" = "E2E: PASS" ]; } \
  && ok || bad "passing flows must keep the stage green (rc=$RC last='$(LAST)')"
[ "$(grep -rlc 'sk_test_fake' "$T/out" 2>/dev/null | wc -l)" = 0 ] \
  && ok || bad "the QA secret reached the build record: $(grep -rl sk_test_fake "$T/out")"

echo "--- 6. a role with no QA account: blocked rows, no drive, stage still green"
jq '(.personas[]|select(.id=="owner")|.role) = "qa-nobody"' "$T/personas-valid.json" > "$T/repo/qa/personas.json"
changed "src/x.ts"
run
grep -qx 'FLOW owner dashboard blocked no QA account for demo-os/qa-nobody' "$T/out/e2e.md" \
  && ok || bad "an unresolvable role is not recorded as blocked: $(E2EMD)"
grep -qx 'FLOW owner new-scan blocked no QA account for demo-os/qa-nobody' "$T/out/e2e.md" \
  && ok || bad "only one of the persona's flows got a blocked row: $(E2EMD)"
[ "$(NFLOWS)" = 0 ] \
  && ok || bad "the drive ran without a resolved QA account"
[ "$RC" = 0 ] \
  && ok || bad "a blocked persona failed the stage (rc=$RC)"
cp "$T/personas-valid.json" "$T/repo/qa/personas.json"

echo "--- 7. the wrapper declines the unban window (rc 75): blocked, never a retry"
changed "src/x.ts"; FORCE_RC=75
run
grep -qx 'FLOW owner dashboard blocked qa-unbanned rc=75 (QA account busy, nothing was touched)' "$T/out/e2e.md" \
  && ok || bad "rc 75 from the wrapper is not recorded with its meaning: $(E2EMD)"
grep -c '^FLOW owner .* blocked qa-unbanned rc=75' "$T/out/e2e.md" 2>/dev/null | grep -qx 2 \
  && ok || bad "both flows of the declined persona must be blocked: $(E2EMD)"
{ [ "$RC" = 0 ] && [ "$(LAST)" = "E2E: PASS" ]; } \
  && ok || bad "a declined unban window failed the stage (rc=$RC last='$(LAST)')"
FORCE_RC=""

echo "--- 8. a failing flow fails the stage"
changed "src/x.ts"; DRIVE_MODE=fail
run
grep -qE '^FLOW owner dashboard fail ' "$T/out/e2e.md" \
  && ok || bad "the failing flow's row is missing: $(E2EMD)"
{ [ "$RC" = 4 ] && [ "$(LAST)" = "E2E: FAIL" ]; } \
  && ok || bad "a fail row must reach rc 4 / E2E: FAIL (rc=$RC last='$(LAST)')"
grep -q 'flows_failed=1' "$T/out/e2e.md" \
  && ok || bad "the coverage line does not count the failure: $(E2EMD)"
DRIVE_MODE=pass

echo "--- 9. an invalid personas file: recorded, never a block and never a silent pass"
jq '.personas[1].flows[1].production_safe = "true"' "$T/personas-valid.json" > "$T/repo/qa/personas.json"
changed "src/x.ts"
run
grep -q '^PERSONAS: invalid .*\.personas\[1\]\.flows\[1\]\.production_safe' "$T/out/e2e.md" \
  && ok || bad "the schema defect is not named in the record: $(E2EMD)"
grep -qE 'ARGV .*/e2e-smoke\.mjs https://' "$T/node.log" \
  && ok || bad "an invalid personas file stopped the route smoke — it must continue"
[ "$(NFLOWS)" = 0 ] \
  && ok || bad "a persona was driven out of a file that does not validate"
[ "$RC" = 0 ] \
  && ok || bad "an invalid personas file blocked the stage (rc=$RC)"
cp "$T/personas-valid.json" "$T/repo/qa/personas.json"

echo "--- 10. the persona cap: capped work is visible, never dropped"
jq -n '{version:1, personas:[range(1;6) as $i | {
         id:("p" + ($i|tostring)), role:"qa-owner", sign_in:"clerk-ticket",
         out_of_bounds:["/refunds"],
         flows:[{id:"f1", title:"t", route:"/x", observable:"o",
                 production_safe:true, steps:[{goto:"/x"}]}]}]}' > "$T/repo/qa/personas.json"
# BH-5204: five personas that all own the one changed area would now be one
# drive; per-area 5 keeps all five in play so this case still pins the cap.
changed "src/x.ts"; MAXP=2; export QA_PERSONAS_PER_AREA=5
run
unset QA_PERSONAS_PER_AREA
[ "$(NFLOWS)" = 2 ] \
  && ok || bad "E2E_MAX_PERSONAS=2 drove $(NFLOWS) personas: $(cat "$T/node.log")"
for P in p3 p4 p5; do
  grep -qx "FLOW $P f1 blocked not driven (persona cap)" "$T/out/e2e.md" \
    && ok || bad "$P was dropped instead of recorded as capped: $(E2EMD)"
done
grep -q 'flows_blocked=3' "$T/out/e2e.md" \
  && ok || bad "the coverage line does not count the capped personas: $(E2EMD)"
grep -qx 'Personas: 5 in scope, 2 driven (mode preview)' "$T/out/e2e.md" \
  && ok || bad "the Personas: line is untrue under the cap: $(E2EMD)"
MAXP=""; cp "$T/personas-valid.json" "$T/repo/qa/personas.json"

echo "--- 11. a drive that printed no FLOW rows is blocked, never a pass"
changed "src/x.ts"; DRIVE_MODE=norows; DRIVE_RC=7
run
grep -qx 'FLOW owner dashboard blocked drive emitted no FLOW rows (rc=7)' "$T/out/e2e.md" \
  && ok || bad "a silent drive was not recorded as blocked: $(E2EMD)"
[ "$RC" = 0 ] \
  && ok || bad "a silent drive failed the stage instead of blocking (rc=$RC)"
DRIVE_MODE=pass; DRIVE_RC=""

echo "--- 12. no QA env on the box: blocked before anything is unbanned"
changed "src/x.ts"; NOSECRET=1
run
grep -qx 'FLOW owner dashboard blocked no QA env' "$T/out/e2e.md" \
  && ok || bad "a box with no QA env did not record the blocked rows: $(E2EMD)"
[ -s "$T/unban.log" ] \
  && bad "a QA account was unbanned with no QA env to drive it: $(cat "$T/unban.log")" || ok
[ "$(NFLOWS)" = 0 ] \
  && ok || bad "the drive ran with no QA env"
grep -qx 'E2E COVERAGE: routes=1 failed=0 flows=0 flows_failed=0 flows_blocked=2' "$T/out/e2e.md" \
  && ok || bad "blocked flows are not counted as blocked: $(E2EMD)"
[ "$RC" = 0 ] \
  && ok || bad "a missing QA env failed the stage (rc=$RC)"
NOSECRET=0

echo "--- 15. with no override, the changed list comes from the diff itself"
git -C "$T/repo" init -q 2>/dev/null
git -C "$T/repo" config user.email t@t; git -C "$T/repo" config user.name t
git -C "$T/repo" add -A >/dev/null 2>&1; git -C "$T/repo" commit -qm base >/dev/null 2>&1
USEBASE=$(git -C "$T/repo" rev-parse HEAD)
mkdir -p "$T/repo/apps/admin/pages"; echo x > "$T/repo/apps/admin/pages/y.tsx"
git -C "$T/repo" add -A >/dev/null 2>&1; git -C "$T/repo" commit -qm feat >/dev/null 2>&1
CHANGED=""
run
[ "$(NFLOWS)" = 1 ] \
  && ok || bad "the git diff did not scope exactly one persona ($(NFLOWS)): $(cat "$T/node.log")"
grep -q -- '--persona admin' "$T/node.log" \
  && ok || bad "the diff's own app map did not pick the admin persona: $(cat "$T/node.log")"
USEBASE=""

echo "--- 16. a failing smoke does not skip the drives"
changed "src/x.ts"; NODE_MODE=fail; DRIVE_MODE=pass
run
{ [ "$RC" = 4 ] && [ "$(LAST)" = "E2E: FAIL" ]; } \
  && ok || bad "a failed route smoke must stay rc 4 / E2E: FAIL (rc=$RC last='$(LAST)')"
grep -qE '^FLOW owner dashboard pass ' "$T/out/e2e.md" \
  && ok || bad "the persona drives were skipped because the smoke failed: $(E2EMD)"
grep -qx 'E2E COVERAGE: routes=2 failed=1 flows=2 flows_failed=0 flows_blocked=0' "$T/out/e2e.md" \
  && ok || bad "the smoke's own route counts were lost in the rewrite: $(E2EMD)"
NODE_MODE=pass

echo "--- 17. the gate in run-build.sh, extracted verbatim and driven"
# A lane nothing enters is not a lane. The stage only ever runs because of one
# `elif` in bin/run-build.sh, so that line is lifted OUT of the shipped file and
# executed against real git repos — a grep for 'qa/personas.json' would pass on
# a version that lost the vercel.conf half and drove previews for projects that
# have none.
# Since BH-539 the stage is entered by falling THROUGH two skip rungs (no UI
# paths in the diff, then no Vercel project), each a one-line `elif`. Both
# lines and the E2E_UI_DIFF helper they call are lifted verbatim; the lifted
# helper has no bin/lib/e2e-ui-paths.sh in this sandbox, so it takes its own
# legacy-regex branch and writes its one ALERTS line into $T.
GATE_UI=$(grep -m1 '^elif ! E2E_UI_DIFF' "$RB_ALL")
GATE_VERCEL=$(grep -m1 -F 'elif ! awk -v p="$PROJECT"' "$RB_ALL")
GATE_FN=$(awk '/^E2E_UI_DIFF\(\) \{/,/^\}/' "$RB_ALL")
[ -n "$GATE_UI" ] && [ -n "$GATE_VERCEL" ] && [ -n "$GATE_FN" ] \
  && ok || bad "the E2E stage gate could not be extracted from run-build.sh — this section tested nothing"
{ printf 'set -uo pipefail\nSTAMP() { date -u +%%FT%%TZ; }\nALERTS="%s/gate-alerts"; KEY=gate; E2E_GATE_SAID=""\n' "$T"
  printf '%s\n' "$GATE_FN"
  printf 'if false; then :\n'
  printf '%s\n  echo GATE_SKIP\n' "$GATE_UI"
  printf '%s\n  echo GATE_SKIP\n' "$GATE_VERCEL"
  printf 'else\n  echo ENTER\nfi\n'; } > "$T/gate.sh"
G="$T/gate"; mkdir -p "$G/qa"
git -C "$G" init -q 2>/dev/null
git -C "$G" config user.email t@t; git -C "$G" config user.name t
mkdir -p "$G/lib"; echo base > "$G/lib/a.ts"
git -C "$G" add -A >/dev/null 2>&1; git -C "$G" commit -qm base >/dev/null 2>&1
GBASE=$(git -C "$G" rev-parse HEAD)
echo changed > "$G/lib/a.ts"; echo notes > "$G/notes.md"
git -C "$G" add -A >/dev/null 2>&1; git -C "$G" commit -qm feat >/dev/null 2>&1
gate_says() { ( cd "$G" && BASE="$GBASE" PROJECT="${1:-demo-os}" HARNESS="$T" bash "$T/gate.sh" ); }

rm -f "$G/qa/personas.json"
[ "$(gate_says)" = GATE_SKIP ] \
  && ok || bad "a non-UI diff in a repo with no personas file entered the e2e stage: $(gate_says)"
printf '{"version":1}\n' > "$G/qa/personas.json"
[ "$(gate_says)" = ENTER ] \
  && ok || bad "a repo carrying qa/personas.json never enters the e2e stage: $(gate_says)"
[ "$(gate_says not-a-vercel-project)" = GATE_SKIP ] \
  && ok || bad "a project with no Vercel lane entered the stage on the strength of a personas file"
rm -f "$G/qa/personas.json"
mkdir -p "$G/components"; echo x > "$G/components/x.tsx"
git -C "$G" add -A >/dev/null 2>&1; git -C "$G" commit -qm ui >/dev/null 2>&1
[ "$(gate_says)" = ENTER ] \
  && ok || bad "a UI diff stopped entering the stage — the personas clause replaced the old one"

echo "e2e-smoke-personas: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
