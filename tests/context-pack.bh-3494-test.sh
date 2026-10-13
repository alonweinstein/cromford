#!/bin/bash
# tests/context-pack.bh-3494-test.sh — decompose composes and publishes one
# context pack per split child. Implements the BH-3478.2 acceptance (the ticket
# body calls this suite context-pack.bh-3478-test.sh; it is named for its own
# ticket key).
#
# C-cases source bin/lib/context-pack-compose.sh and drive cp_compose on fixture
# plans. D-cases drive the REAL bin/run-decompose.sh (the tests/run-decompose-
# issues-test.sh and run-decompose-board-keys-test.sh recipes): the dry run, a
# real run whose `curl` is a fakebin stub under the real jobs client, the board
# lane, and the fail-open paths. No network, no model call, no secrets.
#
# Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/context-pack.bh-3494-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/context-pack-compose.sh"
DEC="$DIR/bin/run-decompose.sh"
export GH_CLI_REST_ADAPTER="$DIR/tests/lib/gh-cli-rest-adapter.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: expected [$3] got [$2]"; }
has() { grep -qF -- "$2" <<<"$3" && ok || bad "$1: missing [$2]"; }
hasnt() { grep -qF -- "$2" <<<"$3" && bad "$1: must not contain [$2]" || ok; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

# compose <plan> <pf> <body> [child] [parent] [n] [N] -> stdout in $T/out, rc in CRC
compose() {
  ( . "$LIB"; cp_compose "$1" "$2" "$3" "${4-AB-3}" "${5-AB-1}" "${6-2}" "${7-3}" ) > "$T/out" 2>/dev/null
  CRC=$?
  OUT=$(cat "$T/out")
}

# ============================================================================
# fixtures
# ============================================================================
cat > "$T/plan.md" <<'MD'
# AB-1 — a parent plan

## Scope
SCOPETOKEN the scope body.

## Tasks
TASKTOKEN do the things.

## System invariants
INVTOKEN state lives in one table.

### (a) cross-run state
INVSUB nested stays inside.

## ASSUMPTIONS
ASMTOKEN the worker is up.

## Files to touch
FILESTOKEN bin/thing.sh

## Edge cases
EDGETOKEN an empty list.

## Regression risk (existing suites)
REGTOKEN tests/old-test.sh
MD
printf 'Build the one slice.\nFiles: tests/one.test.sh, docs/one.md\n' > "$T/body.md"
printf 'tests/one.test.sh\ndocs/one.md\ntests/two.test.sh\ndocs/two.md\n' > "$T/pf.txt"

# ============================================================================
# C1. the named sections, in the fixed order, header, scope, deterministic
# ============================================================================
compose "$T/plan.md" "$T/pf.txt" "$T/body.md"
eq C1.rc "$CRC" 0
eq C1.header "$(head -n1 "$T/out")" "# Context pack: AB-3 (2 of 3), split from AB-1"
eq C1.scope "$(awk '/^## Child scope$/{getline; print; getline; print; exit}' "$T/out")" "$(cat "$T/body.md")"
for tok in '## System invariants' INVTOKEN '### (a) cross-run state' INVSUB '## ASSUMPTIONS' ASMTOKEN \
           '## Files to touch' FILESTOKEN '## Edge cases' EDGETOKEN '## Regression risk (existing suites)' REGTOKEN; do
  has "C1.section" "$tok" "$OUT"
done
hasnt C1.scope-section SCOPETOKEN "$OUT"
hasnt C1.tasks-section TASKTOKEN "$OUT"
hasnt C1.plan-title '# AB-1 — a parent plan' "$OUT"
# fixed order: invariants < assumptions < files < edge < regression
ORDER=$(grep -nE '^## (System invariants|ASSUMPTIONS|Files to touch|Edge cases|Regression)' "$T/out" | cut -d: -f2- | paste -sd'|')
eq C1.order "$ORDER" "## System invariants|## ASSUMPTIONS|## Files to touch|## Edge cases|## Regression risk (existing suites)"
cp "$T/out" "$T/out.1"; compose "$T/plan.md" "$T/pf.txt" "$T/body.md"
cmp -s "$T/out" "$T/out.1" && ok || bad "C1: two runs must give byte-identical packs"
# a plan whose sections come in another order gives the same layout
awk '/^## Regression/{r=1} r{print}' "$T/plan.md" > "$T/plan-rev.md"
awk '/^## Regression/{exit} {print}' "$T/plan.md" >> "$T/plan-rev.md"
compose "$T/plan-rev.md" "$T/pf.txt" "$T/body.md"
cmp -s "$T/out" "$T/out.1" && ok || bad "C1: the pack layout must not follow the parent plan's section order"

# ============================================================================
# C2. Sibling claims (top-level and nested), a fenced heading, a case variant
# ============================================================================
cat > "$T/plan2.md" <<'MD'
# AB-1

## Scope
Some scope.
```
## Regressions are fine here
FENCETOKEN
```

## Files to touch
FILESTOKEN bin/thing.sh

### Sibling claims
SIBTOKEN2 bin/sibling.sh

## edge CASES
EDGETOKEN after the nested claims.

```bash
## not a heading inside a fence
FENCEINSIDE kept because the section is on
```

## Sibling claims (not touched)
SIBTOKEN1 bin/other.sh
MD
compose "$T/plan2.md" "$T/pf.txt" "$T/body.md"
eq C2.rc "$CRC" 0
hasnt C2.top-claims SIBTOKEN1 "$OUT"
hasnt C2.nested-claims SIBTOKEN2 "$OUT"
hasnt C2.fenced-heading FENCETOKEN "$OUT"
has C2.files FILESTOKEN "$OUT"
has C2.edge-after-claims EDGETOKEN "$OUT"
has C2.case-variant '## edge CASES' "$OUT"
has C2.fence-inside-section FENCEINSIDE "$OUT"

# ============================================================================
# C3/C4. the inventory: filtered, unfiltered, empty
# ============================================================================
compose "$T/plan.md" "$T/pf.txt" "$T/body.md"
INV=$(awk '/^## Parent file inventory$/{on=1; next} on && /^$/{exit} on{print}' "$T/out")
eq C3.filtered "$INV" "$(printf 'tests/one.test.sh\ndocs/one.md\nfiltered: 2 of 4')"
printf 'A body that names no path at all.\n' > "$T/body-none.md"
compose "$T/plan.md" "$T/pf.txt" "$T/body-none.md"
INV=$(awk '/^## Parent file inventory$/{on=1; next} on && /^$/{exit} on{print}' "$T/out")
eq C4.unfiltered "$INV" "$(printf 'tests/one.test.sh\ndocs/one.md\ntests/two.test.sh\ndocs/two.md\nunfiltered')"
: > "$T/pf-empty.txt"
compose "$T/plan.md" "$T/pf-empty.txt" "$T/body.md"
eq C4.empty-rc "$CRC" 0
has C4.empty "unfiltered (0 paths)" "$OUT"
compose "$T/plan.md" "$T/no-such-pf.txt" "$T/body.md"
eq C4.missing-rc "$CRC" 0
has C4.missing "unfiltered (0 paths)" "$OUT"

# ============================================================================
# C5. the cap ladder
# ============================================================================
# Pad each droppable section so every drop step is a measurable size.
{ echo '# AB-1'; echo; echo '## System invariants'; echo INVTOKEN
  for s in 'ASSUMPTIONS:ASMTOKEN' 'Files to touch:FILESTOKEN' 'Edge cases:EDGETOKEN' 'Regression risk:REGTOKEN'; do
    echo; echo "## ${s%%:*}"; echo "${s#*:}"; head -c 2000 /dev/zero | tr '\0' x; echo
  done; } > "$T/plan-big.md"
compose "$T/plan-big.md" "$T/pf.txt" "$T/body.md"
FULL=$(wc -c < "$T/out" | tr -d ' ')
bytes() { LC_ALL=C wc -c < "$T/out" | tr -d ' '; }
# step 1: only Regression must go
CP_MAX_BYTES=$((FULL - 100)) compose "$T/plan-big.md" "$T/pf.txt" "$T/body.md"
eq C5.1.rc "$CRC" 0
has C5.1.omitted "omitted: Regression (pack cap)" "$OUT"
hasnt C5.1.regression-body REGTOKEN "$OUT"
has C5.1.edge-kept EDGETOKEN "$OUT"
[ "$(bytes)" -le $((FULL - 100)) ] && ok || bad "C5.1: pack is over its cap ($(bytes))"
# step 2: Regression and Edge cases go, Files to touch stays
CP_MAX_BYTES=$((FULL - 2100)) compose "$T/plan-big.md" "$T/pf.txt" "$T/body.md"
has C5.2.omit-reg "omitted: Regression (pack cap)" "$OUT"
has C5.2.omit-edge "omitted: Edge cases (pack cap)" "$OUT"
has C5.2.files-kept FILESTOKEN "$OUT"
has C5.2.asm-kept ASMTOKEN "$OUT"
# step 3: all four droppable sections go, in place, invariants stay
CP_MAX_BYTES=1200 compose "$T/plan-big.md" "$T/pf.txt" "$T/body.md"
eq C5.3.rc "$CRC" 0
OM=$(grep '^omitted:' "$T/out" | paste -sd'|')
eq C5.3.omitted "$OM" "omitted: ASSUMPTIONS (pack cap)|omitted: Files to touch (pack cap)|omitted: Edge cases (pack cap)|omitted: Regression (pack cap)"
has C5.3.invariants INVTOKEN "$OUT"
for tok in ASMTOKEN FILESTOKEN EDGETOKEN REGTOKEN; do hasnt "C5.3.dropped" "$tok" "$OUT"; done
[ "$(bytes)" -le 1200 ] && ok || bad "C5.3: pack is over its cap ($(bytes))"
# step 4: under scope+inventory+invariants -> rc 3, nothing printed
CP_MAX_BYTES=100 compose "$T/plan-big.md" "$T/pf.txt" "$T/body.md"
eq C5.4.rc "$CRC" 3
[ -z "$OUT" ] && ok || bad "C5.4: an over-cap pack must print nothing, got $(wc -c < "$T/out") bytes"

# ============================================================================
# C6. board lane: no body file
# ============================================================================
compose "$T/plan.md" "$T/pf.txt" ""
eq C6.rc "$CRC" 0
eq C6.scope "$(awk '/^## Child scope$/{getline; print; getline; print; exit}' "$T/out")" "$(printf 'read the ticket thread\n')"
has C6.unfiltered "unfiltered" "$OUT"
hasnt C6.not-filtered "filtered:" "$OUT"

# ============================================================================
# C7. a plan with none of the five sections
# ============================================================================
printf '# AB-1\n\n## Scope\nOnly scope.\n\n## Tasks\nOnly tasks.\n' > "$T/plan-none.md"
compose "$T/plan-none.md" "$T/pf.txt" "$T/body.md"
eq C7.rc "$CRC" 0
eq C7.headings "$(grep -E '^#' "$T/out" | paste -sd'|')" "# Context pack: AB-3 (2 of 3), split from AB-1|## Child scope|## Parent file inventory"
eq C7.last-line "$(tail -n1 "$T/out")" "filtered: 2 of 4"

# ============================================================================
# C8. bad args, and no root needed
# ============================================================================
compose "$T/no-such-plan.md" "$T/pf.txt" "$T/body.md"
eq C8.missing-plan "$CRC/$OUT" "1/"
: > "$T/plan-empty.md"
compose "$T/plan-empty.md" "$T/pf.txt" "$T/body.md"
eq C8.empty-plan "$CRC/$OUT" "1/"
compose "$T/plan.md" "$T/pf.txt" "$T/body.md" "../x"
eq C8.bad-child "$CRC/$OUT" "1/"
compose "$T/plan.md" "$T/pf.txt" "$T/body.md" AB-3 AB-1 a 3
eq C8.bad-n "$CRC/$OUT" "1/"
( export HARNESS='' H=''; . "$LIB"; cp_compose "$T/plan.md" "$T/pf.txt" "$T/body.md" AB-3 AB-1 2 3 ) > "$T/out" 2>/dev/null
eq C8.no-root-rc "$?" 0
cmp -s "$T/out" "$T/out.1" && ok || bad "C8: an empty root must not change the pack"

# ============================================================================
# D. the real bin/run-decompose.sh
# ============================================================================
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/env" "$H/prompts" "$T/fakebin"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" scoutish widget-os || exit 1
cp "$DIR/bin/fleet-conf.sh" "$H/bin/"
cat > "$H/fleet.conf" <<'CONF'
scoutish      example-org/scoutish   https://scoutish.example  -           9 box-1 10.0.0.9
widget-os     example-org/widget-os  https://widget.example    /api/board  2 box-1 10.0.0.2
CONF
export FLEET_CONF="$H/fleet.conf"
: > "$H/env/global.env"
printf 'WIDGET_INTERNAL_API_TOKEN=tok-abc\nWIDGET_API_BASE=https://widget.example\n' > "$H/env/widget-os.env"
# The issues lane hands in a spec and must never reach the agent; the board
# lane's agent writes the fixture children.txt.
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
echo "call" >> "$AGENT_LOG"
[ -n "${CHILDREN_FIXTURE:-}" ] && cat "$CHILDREN_FIXTURE" > "$(dirname "$5")/children.txt"
exit 0
SH
chmod +x "$H/bin/agent-call.sh"
printf '#!/bin/bash\necho ghs_fresh\n' > "$H/bin/gh-token.sh"; chmod +x "$H/bin/gh-token.sh"

SPEC='[
 {"title":"contract","contract":"tests/one.test.sh: stub","after":[],"body":"BODYTOKEN_1 the contract.\nFiles: tests/one.test.sh\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"sibling two","after":[],"body":"BODYTOKEN_2 the second slice.\nFiles: tests/two.test.sh\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"sibling three","after":[],"body":"BODYTOKEN_3 the third slice.\nFiles: tests/three.test.sh\n\n## Observable outcome\nThe slice acceptance test passes end to end."}
]'
{ cat "$T/plan.md"; printf '\n## Sibling claims (not touched)\nSIBTOKEN1 bin/other.sh\n'; } > "$T/parent-plan.md"

# fakebin gh: the bh-637 case 6 recipe (issues 901..903)
export GH_CALLS="$T/gh.calls"
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_CALLS"
. "${GH_CLI_REST_ADAPTER:?}" || exit 1; gh_cli_rest "$0" post "$@" && exit 0
case "$1 $2" in
  "issue create") n=$(grep -c '^issue create' "$GH_CALLS"); echo "https://github.com/example-org/scoutish/issues/$((900+n))" ;;
  "issue view")   printf '{"labels":[{"name":"ai-build"}]}' ;;
  *)              echo '{}' ;;
esac
exit 0
SH
chmod +x "$T/fakebin/gh"
# fakebin curl: records the URL and --data-binary body of each call, answers the
# way bin/lib/jobs/req.sh reads it (body, newline, %{http_code}) with CURL_CODE,
# or exits CURL_EXIT with no output. It drains stdin on a context-pack POST, as
# any child process that reads stdin would, so a publish loop that iterates on
# stdin instead of its own fd loses children. The board-lane URLs follow the
# run-decompose-board-keys recipe.
export CURL_CALLS="$T/curl.calls"
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"; BODY=""
while [ $# -gt 0 ]; do case "$1" in --data-binary|--data|-d) BODY="$2"; shift 2 ;; *) shift ;; esac; done
case "$BODY" in @*) BODY=$(cat "${BODY#@}") ;; esac
printf '%s\t%s\n' "$URL" "$(printf '%s' "$BODY" | base64 -w0)" >> "$CURL_CALLS"
[ "${CURL_EXIT:-0}" = 0 ] || exit "$CURL_EXIT"
case "$URL" in
  *"/api/context-packs")               cat >/dev/null; printf '{}\n%s' "${CURL_CODE:-200}" ;;
  *"/api/board/tickets/1766/move")     printf '{"status":"in_progress"}\n' ;;
  *"/api/board/tickets/1766")          printf '{"ticket":{"id":"1766","key":"WO-1766","boardId":"bd-1"}}\n' ;;
  *"/api/board/boards/bd-1/tickets")   printf '{"tickets":[{"key":"WO-1784","id":"9001","title":"WO-1766.0: contract","createdAt":"2026-09-18T10:00:00Z"},{"key":"WO-1785","id":"9002","title":"WO-1766.1: slice","createdAt":"2026-09-18T10:01:00Z"}]}\n' ;;
  *)                                   printf '{}\n' ;;
esac
exit 0
SH
chmod +x "$T/fakebin/curl"

B="$T/b"
# prep: a fresh build dir with the parent plan, its planned-files and the spec
prep() {
  scratch_rm "$B"; mkdir -p "$B"
  printf '%s\n' "$SPEC" > "$B/children.json"
  cp "$T/parent-plan.md" "$B/plan.md"
  printf 'tests/one.test.sh\ntests/two.test.sh\ntests/three.test.sh\n' > "$B/planned-files.txt"
  : > "$T/agent.log"; : > "$GH_CALLS"; : > "$CURL_CALLS"
}
# drive <cwd> <script> <project> <ticket> <key> [env...] -> stdout $T/dec.out, rc DRC
drive() {
  local cwd="$1" dec="$2" p="$3" t="$4" k="$5"; shift 5
  ( cd "$cwd" && env HARNESS="$H" FLEET_CONF="$H/fleet.conf" AGENT_LOG="$T/agent.log" \
      PATH="$T/fakebin:$PATH" JOBS_RETRIES=0 "$@" "$dec" "$p" "$t" "$k" "$B" 300 12 ) > "$T/dec.out" 2>&1 </dev/null
  DRC=$?
}
plog() { cat "$B/pipeline.log" 2>/dev/null; }
count() { grep -cE -- "$1" "$2" 2>/dev/null; }
mkdir -p "$T/nogit"

# D1. dry run, issues lane. The worker URL and secret are set, so a dry run
# that published anyway would show up as a POST in curl.calls.
prep
drive "$T/nogit" "$DEC" scoutish 552 TK-552 DECOMPOSE_DRY_RUN=1 JOBS_URL=http://jobs.stub HARNESS_SECRET=fixture
eq D1.rc "$DRC" 0
for c in TK-553 TK-554 TK-555; do
  [ -s "$B/context-packs/$c.md" ] && ok || bad "D1: $B/context-packs/$c.md missing ($(ls "$B/context-packs" 2>&1))"
done
eq D1.would-post "$(count '^would POST /api/context-packs TK-55[345]$' "$T/dec.out")" 3
eq D1.dry-log "$(count 'context pack dry-run for TK-55[345]$' "$B/pipeline.log")" 3
eq D1.filing "$(count '^DRYRUN gh issue create' "$T/dec.out")" 3
[ -s "$CURL_CALLS" ] && bad "D1: a dry run must make no call: $(cat "$CURL_CALLS")" || ok
eq D1.no-outcome "$(count 'context pack (published|REFUSED|unreachable)' "$B/pipeline.log")" 0
[ -s "$T/agent.log" ] && bad "D1: a dry run with a spec must not reach the agent" || ok
eq D1.header "$(head -n1 "$B/context-packs/TK-554.md" 2>/dev/null)" "# Context pack: TK-554 (2 of 3), split from TK-552"
hasnt D1.no-sibling-claims SIBTOKEN1 "$(cat "$B/context-packs/"*.md 2>/dev/null)"

# D2. each pack carries its own body, never a sibling's
for i in 1 2 3; do
  c="TK-55$((2 + i))"; P=$(cat "$B/context-packs/$c.md" 2>/dev/null)
  words=(x one two three)
  has "D2.$c.body" "BODYTOKEN_$i" "$P"
  has "D2.$c.path" "tests/${words[$i]}.test.sh" "$P"
  has "D2.$c.filtered" "filtered: 1 of 3" "$P"
  for j in 1 2 3; do
    [ "$j" = "$i" ] || hasnt "D2.$c.sibling-$j" "BODYTOKEN_$j" "$P"
  done
done

# D3. a real run publishes each pack through the real cp_put
prep
drive "$T/nogit" "$DEC" scoutish 552 TK-552 JOBS_URL=http://jobs.stub HARNESS_SECRET=fixture
eq D3.rc "$DRC" 0
eq D3.posts "$(count '^http://jobs.stub/api/context-packs	' "$CURL_CALLS")" 3
n=0
while IFS=$'\t' read -r url b64; do
  case "$url" in */api/context-packs) : ;; *) continue ;; esac
  n=$((n + 1)); printf '%s' "$b64" | base64 -d > "$T/post.json"
  c=$(jq -r .ticket_key "$T/post.json")
  eq "D3.$n.key" "$c" "TK-90$n"
  eq "D3.$n.parent" "$(jq -r .parent_key "$T/post.json")" TK-552
  eq "D3.$n.project" "$(jq -r .project "$T/post.json")" scoutish
  jq -j .pack_md "$T/post.json" > "$T/sent.md"
  cmp -s "$T/sent.md" "$B/context-packs/$c.md" && ok || bad "D3: $c pack_md is not byte-equal to its local copy"
  jq -e 'has("base_sha")' "$T/post.json" >/dev/null && bad "D3: base_sha sent from a non-git cwd" || ok
done < "$CURL_CALLS"
eq D3.published "$(count 'context pack published for TK-90[123]$' "$B/pipeline.log")" 3
eq D3.filed "$(count '^issue create' "$GH_CALLS")" 3

# D4. unreachable worker: rc unchanged, children still filed, no secret logged
prep
drive "$T/nogit" "$DEC" scoutish 552 TK-552 JOBS_URL=http://jobs.stub HARNESS_SECRET=fixture CURL_EXIT=7
eq D4.rc "$DRC" 0
eq D4.unreachable "$(count 'context pack unreachable for TK-90[123]$' "$B/pipeline.log")" 3
eq D4.no-published "$(count 'context pack published' "$B/pipeline.log")" 0
eq D4.filed "$(count '^issue create' "$GH_CALLS")" 3
grep -qE 'HARNESS_SECRET|fixture' "$B/pipeline.log" && bad "D4: a secret reached pipeline.log" || ok
[ -s "$H/logs/ALERTS.log" ] && bad "D4: publishing must not page: $(cat "$H/logs/ALERTS.log")" || ok

# D5. a 4xx is REFUSED; a git cwd sends its HEAD as base_sha
mkdir -p "$T/repo"
( cd "$T/repo" && git init -q . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m one )
SHA=$(git -C "$T/repo" rev-parse HEAD)
prep
drive "$T/repo" "$DEC" scoutish 552 TK-552 JOBS_URL=http://jobs.stub HARNESS_SECRET=fixture CURL_CODE=413
eq D5.rc "$DRC" 0
eq D5.refused "$(count 'context pack REFUSED for TK-90[123]$' "$B/pipeline.log")" 3
grep -m1 '/api/context-packs	' "$CURL_CALLS" | cut -f2 | base64 -d > "$T/post.json" 2>/dev/null
eq D5.base-sha "$(jq -r '.base_sha // "absent"' "$T/post.json" 2>/dev/null)" "$SHA"

# D6. board lane: after the re-map, before parking
# D6 and D7 pin the model-filed path, behind this switch since BH-3965.
mkdir -p "$H/flags" && : > "$H/flags/decompose-board-filer-off"
prep; rm -f "$B/children.json"
printf 'WO-1766.0\nWO-1766.1\n' > "$T/children-fixture.txt"
drive "$T/nogit" "$DEC" widget-os 1766 WO-1766 CHILDREN_FIXTURE="$T/children-fixture.txt"
eq D6.rc "$DRC" 0
for c in WO-1784 WO-1785; do
  eq "D6.$c.scope" "$(awk '/^## Child scope$/{getline; print; exit}' "$B/context-packs/$c.md" 2>/dev/null)" "read the ticket thread"
done
FIRST_CP=$(grep -n 'context pack' "$B/pipeline.log" | head -n1 | cut -d: -f1)
LAST_MAP=$(grep -n ' child WO-1766\.[0-9]* -> ' "$B/pipeline.log" | tail -n1 | cut -d: -f1)
PARK=$(grep -n 'parent parked in_progress' "$B/pipeline.log" | head -n1 | cut -d: -f1)
{ [ -n "$FIRST_CP" ] && [ -n "$LAST_MAP" ] && [ -n "$PARK" ] && [ "$FIRST_CP" -gt "$LAST_MAP" ] && [ "$FIRST_CP" -lt "$PARK" ]; } \
  && ok || bad "D6: the first context pack line must come after the re-map and before parking: $(plog)"
eq D6.lines "$(count 'context pack unreachable for WO-178[45]$' "$B/pipeline.log")" 2
grep -q '/api/board/tickets/1766/move' "$CURL_CALLS" && ok || bad "D6: parking POST must still be made: $(cut -f1 "$CURL_CALLS")"

# D7. board lane DEC_FAIL: no pack, no log line, rc 1 as before
prep; rm -f "$B/children.json"
printf 'WO-1766.0\nWO-1766.7\n' > "$T/children-fixture.txt"
drive "$T/nogit" "$DEC" widget-os 1766 WO-1766 CHILDREN_FIXTURE="$T/children-fixture.txt"
eq D7.rc "$DRC" 1
[ -e "$B/context-packs" ] && bad "D7: a failed re-map must write no pack" || ok
eq D7.no-line "$(count 'context pack' "$B/pipeline.log")" 0
rm -f "$H/flags/decompose-board-filer-off"

# D8. a children.txt line with no spec entry (dry-run resume path)
prep
printf 'TK-553\nTS-554\nTS-555\nTS-556\n' > "$B/children.txt"
drive "$T/nogit" "$DEC" scoutish 552 TK-552 DECOMPOSE_DRY_RUN=1
eq D8.rc "$DRC" 0
eq D8.dry "$(count 'context pack dry-run for TK-55[345]$' "$B/pipeline.log")" 3
eq D8.no-spec "$(count 'context pack not composed \(no spec entry 4\) for TK-556$' "$B/pipeline.log")" 1
[ -e "$B/context-packs/TK-556.md" ] && bad "D8: no pack for a line with no spec entry" || ok
[ -e "$B/context-packs/.body" ] && bad "D8: the scratch body file must be removed" || ok

# D8b. bad keys never become a file name
prep
printf '../x\nTS-552\nTS-554\n' > "$B/children.txt"
drive "$T/nogit" "$DEC" scoutish 552 TK-552 DECOMPOSE_DRY_RUN=1
eq D8b.rc "$DRC" 0
eq D8b.bad "$(count 'context pack not composed \(bad child key\) for (\.\./x|TK-552)$' "$B/pipeline.log")" 2
eq D8b.files "$(cd "$B/context-packs" 2>/dev/null && ls | paste -sd,)" "TK-554.md"

# D9. compose lib absent: rc and filing unaffected
H2="$T/h2"
cp -r "$H" "$H2"
cp "$DEC" "$H2/bin/run-decompose.sh"
cp "$DIR"/bin/lib/*.sh "$H2/bin/lib/"
[ -d "$DIR/bin/lib/tracker" ] && cp -r "$DIR/bin/lib/tracker" "$H2/bin/lib/"
rm -f "$H2/bin/lib/context-pack-compose.sh"
prep
( cd "$T/nogit" && env HARNESS="$H2" FLEET_CONF="$H/fleet.conf" AGENT_LOG="$T/agent.log" PATH="$T/fakebin:$PATH" \
    DECOMPOSE_DRY_RUN=1 "$H2/bin/run-decompose.sh" scoutish 552 TK-552 "$B" 300 12 ) > "$T/dec.out" 2>&1 </dev/null
eq D9.rc "$?" 0
eq D9.missing "$(count 'context pack not composed \(compose lib missing\) for TK-55[345]$' "$B/pipeline.log")" 3
eq D9.filing "$(count '^DRYRUN gh issue create' "$T/dec.out")" 3

echo "context-pack.bh-3494: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
