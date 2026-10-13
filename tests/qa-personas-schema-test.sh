#!/bin/bash
# tests/qa-personas-schema-test.sh — bin/lib/qa-personas.sh is the one reader of
# qa/personas.json and qa/apps.json (docs/E2E-POLICY.md § Personas). Four lanes
# code against it before any of them exists, so every rule of schema v1, every
# scope decision and every printed line is pinned here against the real
# functions: the suite sources the lib and calls it, it never greps the source.
#
# Mutations are made with jq on tests/fixtures/qa-personas/valid.json, never by
# hand-editing a copy, so a fixture change cannot leave a negative case testing
# a document the positive case no longer matches.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

LIB="$DIR/bin/lib/qa-personas.sh"
V="$DIR/tests/fixtures/qa-personas/valid.json"
A="$DIR/tests/fixtures/qa-personas/apps.json"
# shellcheck source=../bin/lib/qa-personas.sh
. "$LIB" || { echo "FAIL: lib missing"; exit 1; }

W="$T/qap"; mkdir -p "$W"
M="$W/m.json"      # the mutated personas file
C="$W/changed.txt" # the changed-files list
E="$W/err.txt"     # captured stderr

mut()     { jq "$1" "$V" > "$M"; }
changed() { printf '%s\n' "$@" > "$C"; }

# rc 1, exactly one line, `personas.json: ` prefix, and every wanted substring.
refused() { # refused <label> <apps-file-or-empty> <substring...>
  local label="$1" appsf="$2"; shift 2
  local out rc lines want
  if [ -n "$appsf" ]; then out=$(qa_personas_validate "$M" "$appsf" 2>&1); rc=$?
  else                     out=$(qa_personas_validate "$M" 2>&1); rc=$?; fi
  [ "$rc" = 1 ] || { bad "$label: rc $rc, want 1 (output: $out)"; return; }
  lines=$(printf '%s\n' "$out" | wc -l)
  [ "$lines" = 1 ] || { bad "$label: $lines output lines, want exactly 1: $out"; return; }
  case "$out" in "personas.json: "*) ;; *) bad "$label: no 'personas.json: ' prefix: $out"; return ;; esac
  for want in "$@"; do
    case "$out" in *"$want"*) ;; *) bad "$label: want '$want' in: $out"; return ;; esac
  done
  ok
}

accepted() { # accepted <label> <personas> [apps]
  local label="$1" p="$2" appsf="${3:-}" out rc
  if [ -n "$appsf" ]; then out=$(qa_personas_validate "$p" "$appsf" 2>&1); rc=$?
  else                     out=$(qa_personas_validate "$p" 2>&1); rc=$?; fi
  [ "$rc" = 0 ] || { bad "$label: rc $rc, want 0 (output: $out)"; return; }
  [ -z "$out" ] || { bad "$label: expected silence, got: $out"; return; }
  ok
}

# ── A1 the lib is a library: syntax clean, silent at source time ─────────────
bash -n "$LIB" 2>"$E" && ok || bad "bash -n on the lib: $(cat "$E")"
SRC_OUT=$(bash -c '. "$1"' _ "$LIB" 2>&1); SRC_RC=$?
[ "$SRC_RC" = 0 ] || bad "sourcing the lib returned $SRC_RC"
[ -z "$SRC_OUT" ] && ok || bad "sourcing the lib printed: $SRC_OUT"

# ── A2 the fixture validates, with and without the app map ──────────────────
accepted "valid fixture, no apps.json" "$V"
accepted "valid fixture with apps.json" "$V" "$A"

# ── A3 every required key, removed or mistyped ──────────────────────────────
while IFS='|' read -r flt want; do
  [ -n "$flt" ] || continue
  mut "$flt"; refused "$flt" "$A" "$want"
done <<'CASES'
del(.version)|.version
.version=2|.version
del(.personas)|.personas
.personas=[]|.personas
del(.personas[0].id)|.personas[0].id
.personas[0].id="Admin User"|.personas[0].id
del(.personas[0].role)|.personas[0].role
.personas[0].role=""|.personas[0].role
del(.personas[0].sign_in)|.personas[0].sign_in
del(.personas[0].flows)|.personas[0].flows
.personas[0].flows=[]|.personas[0].flows
del(.personas[0].flows[0].id)|.personas[0].flows[0].id
del(.personas[0].flows[0].route)|.personas[0].flows[0].route
del(.personas[0].flows[0].observable)|.personas[0].flows[0].observable
del(.personas[1].flows[1].production_safe)|.personas[1].flows[1].production_safe
del(.personas[0].flows[0].steps)|.personas[0].flows[0].steps
.personas[0].flows[0].steps=[]|.personas[0].flows[0].steps
CASES

# ── A4 production_safe is a JSON boolean or nothing ─────────────────────────
for bad_val in '"true"' '1' 'null'; do
  mut ".personas[1].flows[1].production_safe=$bad_val"
  refused "production_safe=$bad_val" "$A" ".personas[1].flows[1].production_safe" "must be a JSON boolean"
done

# ── A5 the value rules ──────────────────────────────────────────────────────
mut '.personas[0].sign_in="password"';                    refused 'sign_in="password"' "$A" ".personas[0].sign_in"
mut '.personas[0].flows[0].route="https://x/y"';          refused 'route=https://x/y' "$A" ".personas[0].flows[0].route"
mut '.personas[0].flows[0].route="dashboard"';            refused 'route without a slash' "$A" ".personas[0].flows[0].route"
mut '.personas[0].flows[0].steps[0]={"press":"Enter"}';   refused 'step {press}' "$A" ".personas[0].flows[0].steps[0]" "press"
mut '.personas[0].flows[0].steps[0]={"goto":"/a","click":"b"}'; refused 'two-key step' "$A" ".personas[0].flows[0].steps[0]" "exactly one"
mut '.personas[0].flows[0].steps[0]={}';                  refused 'zero-key step' "$A" ".personas[0].flows[0].steps[0]" "exactly one"
mut '.personas[0].flows[0].steps[0]={"goto":"admin/users"}'; refused 'goto without a slash' "$A" ".personas[0].flows[0].steps[0]"
mut '.personas[1].flows[1].steps[1]={"fill":{"selector":"x"}}'; refused 'fill without a value' "$A" ".personas[1].flows[1].steps[1]"
mut 'del(.personas[1].flows[1].cleanup)';                 refused 'write flow without cleanup' "$A" ".personas[1].flows[1].cleanup"
mut '.personas[0].apps=["billing"]';                      refused 'apps names an unknown app' "$A" ".personas[0].apps[0]" "billing"
accepted "unknown app name is fine with no apps.json" "$M"

# ── A6 duplicates, reported at the second occurrence ────────────────────────
mut '.personas[1].id="admin"';            refused 'duplicate persona id' "$A" ".personas[1].id"
mut '.personas[1].flows[1].id="dashboard"'; refused 'duplicate flow id' "$A" ".personas[1].flows[1].id"
mut '.personas[1].flows[1].id="users"'
accepted "the same flow id in two personas is fine" "$M" "$A"

# ── A7/A8 scope: who a diff belongs to ──────────────────────────────────────
scope_ids_is() { # scope_ids_is <label> <personas> <apps-arg> <mode> <expected>
  local label="$1" p="$2" appsarg="$3" mode="$4" want="$5" out rc got
  out=$(qa_personas_scope "$p" "$appsarg" "$C" "$mode" 2>"$E"); rc=$?
  [ "$rc" = 0 ] || { bad "$label: rc $rc (stderr: $(cat "$E"))"; return; }
  if [ "$out" = NONE ]; then got=NONE
  else got=$(printf '%s' "$out" | jq -r '[.personas[].id]|join(",")' 2>/dev/null); fi
  [ "$got" = "$want" ] || { bad "$label: got '$got', want '$want'"; return; }
  ok
}

changed 'apps/admin/pages/x.tsx';  scope_ids_is "apps/admin/** hits admin"        "$V" "$A" preview 'admin'
changed 'apps/admin/a/b/c.ts';     scope_ids_is "** is any depth"                 "$V" "$A" preview 'admin'
changed 'apps/admin-tools/x.ts';   scope_ids_is "a sibling segment does not hit"   "$V" "$A" preview 'NONE'
changed 'docs/apps/admin/README.md'; scope_ids_is "globs are root anchored"        "$V" "$A" preview 'NONE'
changed 'tests/foo.sh';            scope_ids_is "an unowned path hits nobody"      "$V" "$A" preview 'NONE'
changed 'src/lib/a.ts';            scope_ids_is "src/** hits owner"                "$V" "$A" preview 'owner'
changed 'apps/web/app/page.tsx';   scope_ids_is "apps/web/** hits owner"           "$V" "$A" preview 'owner'
changed 'apps/admin/a.ts' 'src/b.ts'; scope_ids_is "two files hit both personas"   "$V" "$A" preview 'admin,owner'
: > "$C";                          scope_ids_is "an empty diff hits nobody"        "$V" "$A" preview 'NONE'
printf '\n\napps/admin/a.ts\n\n' > "$C"; scope_ids_is "blank lines are ignored"    "$V" "$A" preview 'admin'
changed 'tests/foo.sh';            scope_ids_is "no app map means everyone"        "$V" ""   preview 'admin,owner'
mut '.personas[0].apps=[]'
changed 'tests/foo.sh';            scope_ids_is "apps: [] is in scope for any diff" "$M" "$A" preview 'admin'
# a single * is one segment and never crosses a /
jq '.apps.admin=["apps/*/x.ts"]' "$A" > "$W/apps2.json"
changed 'apps/a/x.ts';             scope_ids_is "* matches one segment"            "$V" "$W/apps2.json" preview 'admin'
changed 'apps/a/b/x.ts';           scope_ids_is "* does not cross a slash"         "$V" "$W/apps2.json" preview 'NONE'
# brackets are not character classes in v1: the glob compiler escapes them
jq '.apps.admin=["apps/[id]/**"]' "$A" > "$W/apps3.json"
changed 'apps/[id]/page.tsx';      scope_ids_is "a bracket glob matches literally" "$V" "$W/apps3.json" preview 'admin'
changed 'apps/i/page.tsx';         scope_ids_is "a bracket is not a class"         "$V" "$W/apps3.json" preview 'NONE'

# ── A9 the preview/production transform ─────────────────────────────────────
changed 'src/lib/a.ts'
qa_personas_scope "$V" "$A" "$C" production > "$W/prod.json" 2>"$E" \
  || bad "scope production: rc $? (stderr: $(cat "$E"))"
jq -e '.version==1 and .mode=="production"
       and .personas[0].id=="owner"
       and (.personas[0].flows[0].steps|length)==2
       and (.personas[0].flows[0]|has("skipped"))==false
       and .personas[0].flows[1].skipped=="write flow, production"
       and (.personas[0].flows[1]|has("steps"))==false
       and .personas[0].flows[1].route=="/scans/new"' "$W/prod.json" >/dev/null \
  && ok || bad "production document: $(cat "$W/prod.json")"
qa_personas_scope "$V" "$A" "$C" preview > "$W/prev.json" 2>"$E" \
  || bad "scope preview: rc $? (stderr: $(cat "$E"))"
jq -e '.mode=="preview"
       and (.personas[0].flows|map(has("steps"))|all)
       and (.personas[0].flows|map(has("skipped"))|any)==false
       and (.personas[0].flows[1].steps|length)==4' "$W/prev.json" >/dev/null \
  && ok || bad "preview document: $(cat "$W/prev.json")"
# a file with no write flow in scope is the same document in both modes but for .mode
changed 'apps/admin/a.ts'
P1=$(qa_personas_scope "$V" "$A" "$C" preview | jq -S 'del(.mode)')
P2=$(qa_personas_scope "$V" "$A" "$C" production | jq -S 'del(.mode)')
[ "$P1" = "$P2" ] && ok || bad "a safe-only persona differs between modes"

# ── A10 scope fails closed ──────────────────────────────────────────────────
scope_refused() { # scope_refused <label> <personas> <apps-arg> <changed> <mode> [substring]
  local label="$1" p="$2" appsarg="$3" cf="$4" mode="$5" want="${6:-}" out rc lines
  out=$(qa_personas_scope "$p" "$appsarg" "$cf" "$mode" 2>"$E"); rc=$?
  [ "$rc" = 1 ] || { bad "$label: rc $rc, want 1"; return; }
  [ -z "$out" ] || { bad "$label: stdout must be empty, got: $out"; return; }
  lines=$(wc -l < "$E")
  [ "$lines" = 1 ] || { bad "$label: $lines stderr lines, want 1: $(cat "$E")"; return; }
  if [ -n "$want" ]; then
    grep -qF "$want" "$E" || { bad "$label: want '$want' in stderr: $(cat "$E")"; return; }
  fi
  ok
}
changed 'src/lib/a.ts'
mut 'del(.personas[0].role)'
scope_refused "an invalid file never scopes" "$M" "$A" "$C" preview "personas.json: .personas[0].role"
scope_refused "an unknown mode is refused"   "$V" "$A" "$C" staging
scope_refused "a missing diff file is refused" "$V" "$A" "$W/does-not-exist.txt" preview

# ── A10b the app map is validated too, before any persona is read ───────────
# A malformed map must be an `apps.json: <path>: <problem>` line and rc 1, not a
# raw jq error out of the glob compiler (which sibling lanes checking rc 1 would
# misread).
apps_refused() { # apps_refused <label> <apps-file> <substring>
  local label="$1" appsf="$2" want="$3" out rc lines
  out=$(qa_personas_validate "$V" "$appsf" 2>&1); rc=$?
  [ "$rc" = 1 ] || { bad "$label: rc $rc, want 1 (output: $out)"; return; }
  lines=$(printf '%s\n' "$out" | wc -l)
  [ "$lines" = 1 ] || { bad "$label: $lines output lines, want exactly 1: $out"; return; }
  case "$out" in *"$want"*) ok ;; *) bad "$label: want '$want' in: $out" ;; esac
}
jq '.apps.admin="apps/admin/**"' "$A" > "$W/appsbad1.json"
apps_refused "an app whose globs are a string" "$W/appsbad1.json" 'apps.json: .apps["admin"]: must be an array of strings'
jq '.apps.admin=[5]' "$A" > "$W/appsbad2.json"
apps_refused "an app whose globs are not strings" "$W/appsbad2.json" 'apps.json: .apps["admin"]: must be an array of strings'
jq '.apps=5' "$A" > "$W/appsbad3.json"
apps_refused "an .apps that is not an object" "$W/appsbad3.json" 'apps.json: .apps: must be an object'
printf 'not json at all\n' > "$W/appsbad4.json"
apps_refused "an apps.json that is not JSON" "$W/appsbad4.json" 'apps.json: .apps: must be an object'
apps_refused "an apps.json that does not exist" "$W/no-such-apps.json" 'apps.json: .apps: must be an object'
# document 0 is the one the glob compiler reads, so document 0 is the one checked
{ echo '{"version":1}'; cat "$A"; } > "$W/appsbad5.json"
apps_refused "a second document does not smuggle a map in" "$W/appsbad5.json" 'apps.json: .apps: must be an object'
# and the refusal reaches scope, which prints no document and no NONE
changed 'src/lib/a.ts'
scope_refused "a malformed app map never scopes" "$V" "$W/appsbad1.json" "$C" preview 'apps.json: .apps["admin"]'
# an app that owns nothing yet is a legal map, not a defect
jq '.apps.admin=[]' "$A" > "$W/appsok.json"
accepted "an app with no globs is legal" "$V" "$W/appsok.json"
scope_ids_is "an app with no globs matches nothing" "$V" "$W/appsok.json" preview 'owner'

# ── A11 the persona list ────────────────────────────────────────────────────
changed 'tests/foo.sh'
qa_personas_scope "$V" "" "$C" preview > "$W/all.json"
LIST=$(qa_personas_list "$W/all.json")
WANT_LIST=$(printf 'admin\tqa-admin\nowner\tqa-owner')
[ "$LIST" = "$WANT_LIST" ] && ok || bad "qa_personas_list printed: $LIST"

# ── A12 blocked rows ────────────────────────────────────────────────────────
ROWS=$(qa_personas_blocked_rows "$W/all.json" '*' 'no QA account')
WANT_ROWS=$(printf 'FLOW admin users blocked no QA account\nFLOW owner dashboard blocked no QA account\nFLOW owner new-scan blocked no QA account')
[ "$ROWS" = "$WANT_ROWS" ] && ok || bad "blocked rows for '*': $ROWS"
ROWS=$(qa_personas_blocked_rows "$W/all.json" owner 'no QA account')
WANT_ROWS=$(printf 'FLOW owner dashboard blocked no QA account\nFLOW owner new-scan blocked no QA account')
[ "$ROWS" = "$WANT_ROWS" ] && ok || bad "blocked rows for 'owner': $ROWS"
ROWS=$(qa_personas_blocked_rows "$W/all.json" nobody 'no QA account'); RC=$?
[ "$RC" = 0 ] && [ -z "$ROWS" ] && ok || bad "blocked rows for an unknown persona: rc $RC, out: $ROWS"
# a production document still reports its skipped write flow as blocked
ROWS=$(qa_personas_blocked_rows "$W/prod.json" '*' 'not driven (persona cap)')
WANT_ROWS=$(printf 'FLOW owner dashboard blocked not driven (persona cap)\nFLOW owner new-scan blocked not driven (persona cap)')
[ "$ROWS" = "$WANT_ROWS" ] && ok || bad "blocked rows on a production document: $ROWS"

# ── A13 unknown keys are carried, not dropped ───────────────────────────────
mut '.generated_by="qa-personas-gen" | .personas[0].notes="y"'
accepted "unknown keys are ignored by the validator" "$M" "$A"
changed 'apps/admin/a.ts'
qa_personas_scope "$M" "$A" "$C" preview > "$W/keys.json" 2>"$E" || bad "scope with unknown keys: $(cat "$E")"
jq -e '.personas[0].notes=="y" and .personas[0].apps==["admin"]' "$W/keys.json" >/dev/null \
  && ok || bad "scope dropped persona keys: $(cat "$W/keys.json")"
# out_of_bounds rides through untouched
qa_personas_scope "$V" "" "$C" preview | jq -e '.personas[1].out_of_bounds==["/billing","/settings/danger"]' >/dev/null \
  && ok || bad "scope dropped out_of_bounds"

# ── A14 no jq, no silent pass ───────────────────────────────────────────────
mkdir -p "$W/nojq"
for b in bash grep cat sed mktemp; do
  p=$(command -v "$b") && ln -sf "$p" "$W/nojq/$b"
done
nojq_is_refused() { # nojq_is_refused <fn> <args...>
  local label="$1" out rc
  out=$( PATH="$W/nojq"; hash -r; "$@" 2>&1 ); rc=$?
  [ "$rc" = 1 ] || { bad "$label without jq: rc $rc, want 1 (output: $out)"; return; }
  [ "$out" = "personas.json: jq missing" ] || { bad "$label without jq printed: $out"; return; }
  ok
}
nojq_is_refused qa_personas_validate "$V"
nojq_is_refused qa_personas_scope "$V" "$A" "$C" preview
nojq_is_refused qa_personas_list "$W/all.json"
nojq_is_refused qa_personas_blocked_rows "$W/all.json" '*' 'no QA account'

# ── A15 the contract section exists exactly once ────────────────────────────
SECTIONS=$(grep -c '^## Personas' "$DIR/docs/E2E-POLICY.md")
[ "$SECTIONS" = 1 ] && ok || bad "docs/E2E-POLICY.md has $SECTIONS '## Personas' sections, want 1"

echo "qa-personas-schema: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
