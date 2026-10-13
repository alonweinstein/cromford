#!/bin/bash
# tests/lanes-build-lib-files.bh-1937-test.sh — ONE FILE PER LIB (BH-1937).
#
# WHY. bin/lanes-build.sh read lib knobs from one file, catalog/lanes.d/_lib.json,
# so every lib-level conversion of BH-1511 would hand-append to it: a shared
# index, a guaranteed conflict between siblings. A lib now lands as its own
# catalog/lanes.d/_lib.<id>.json, composed into `.libs` next to `_lib.json`.
#
# What is proved here, over a scratch repo with the real bin/lanes-build.sh:
#   A1 `_lib.json` alone composes byte-identically to origin/main's lanes-build.sh;
#   A2 a `_lib.x.json` shows up in `.libs`, sorted, and is NOT read as a lane;
#   A3 a lib id in `_lib.json` and a `_lib.y.json` exits 1 naming both files;
#   A4 the same across two `_lib.*.json` files;
#   A5 a malformed `_lib.z.json` exits 1 naming it;
#   A6 `_lib.*.json` with no `_lib.json` composes, and `--check` is rc 0.
# Run from anywhere: tests/lanes-build-lib-files.bh-1937-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

R="$T/repo"
mkdir -p "$R/bin/lib" "$R/catalog/lanes.d"
cp "$DIR/bin/lanes-build.sh" "$R/bin/"
L="$R/catalog/lanes.d"
cat > "$L/_registry.json" <<'JSON'
{ "version": 1, "note": "fixture" }
JSON
cat > "$L/lane-a.json" <<'JSON'
{ "id": "lane-a", "script": "bin/a.sh", "knobs": [] }
JSON
cat > "$L/lane-b.json" <<'JSON'
{ "id": "lane-b", "script": "bin/b.sh", "knobs": [] }
JSON
cat > "$L/_lib.json" <<'JSON'
{ "libs": [
  { "id": "b-lib", "file": "bin/lib/b.sh", "knobs": [] },
  { "id": "a-lib", "file": "bin/lib/a.sh", "knobs": [ { "env": "A_LIB_N", "type": "int", "default": 3 } ] }
] }
JSON

RC=0
build() { # build [args] -> stdout in $T/out, stderr in $T/err, rc in $RC
  bash "$R/bin/lanes-build.sh" --root "$R" "$@" > "$T/out" 2> "$T/err"; RC=$?
}
libids() { jq -c '.libs|map(.id)' "$T/out" 2>/dev/null; }

# A1 — `_lib.json` alone: same libs, and the same BYTES as main's composer.
build
[ "$RC" = 0 ] && ok || bad "A1 rc=$RC: $(cat "$T/err")"
[ "$(libids)" = '["a-lib","b-lib"]' ] && ok || bad "A1 libs: $(libids)"
if git -C "$DIR" show origin/main:bin/lanes-build.sh > "$T/lb-main.sh" 2>/dev/null; then
  bash "$T/lb-main.sh" --root "$R" > "$T/before.json" 2>/dev/null
else
  # No origin/main here: the composition main's jq expression produces.
  jq -s --slurpfile hdr "$L/_registry.json" \
    --argjson libs "$(jq -c '.libs|sort_by(.id)' "$L/_lib.json")" \
    '{version: $hdr[0].version, note: $hdr[0].note, lanes: sort_by(.id), libs: $libs}' \
    "$L/lane-a.json" "$L/lane-b.json" > "$T/before.json"
fi
cmp -s "$T/before.json" "$T/out" && ok || bad "A1 not byte-identical to main: $(diff "$T/before.json" "$T/out" | head -5)"

# A2 — a per-lib file is composed into .libs and is not a lane.
cat > "$L/_lib.x.json" <<'JSON'
{"libs":[{"id":"x-lib","file":"bin/lib/x.sh","knobs":[]}]}
JSON
build
[ "$RC" = 0 ] && ok || bad "A2 rc=$RC: $(cat "$T/err")"
[ "$(libids)" = '["a-lib","b-lib","x-lib"]' ] && ok || bad "A2 libs: $(libids)"
[ "$(jq '.lanes|length' "$T/out" 2>/dev/null)" = 2 ] && ok || bad "A2 lane count: $(jq '.lanes|map(.id)' "$T/out" 2>/dev/null)"

# A3 — `_lib.json` and `_lib.y.json` both define a-lib.
cat > "$L/_lib.y.json" <<'JSON'
{"libs":[{"id":"a-lib","file":"bin/lib/other.sh","knobs":[]}]}
JSON
build
[ "$RC" = 1 ] && ok || bad "A3 duplicate across _lib.json/_lib.y.json: want rc 1, got $RC"
grep -q "a-lib" "$T/err" && grep -q "_lib\.json" "$T/err" && grep -q "_lib\.y\.json" "$T/err" && ok \
  || bad "A3 stderr must name a-lib, _lib.json and _lib.y.json: $(cat "$T/err")"
[ -s "$T/out" ] && bad "A3 a refused composition must print nothing on stdout" || ok
rm -f "$L/_lib.y.json"

# A4 — the same id in two per-lib files, _lib.json not involved.
cat > "$L/_lib.p.json" <<'JSON'
{"libs":[{"id":"dup-lib","file":"bin/lib/p.sh","knobs":[]}]}
JSON
cat > "$L/_lib.q.json" <<'JSON'
{"libs":[{"id":"dup-lib","file":"bin/lib/q.sh","knobs":[]}]}
JSON
build
[ "$RC" = 1 ] && ok || bad "A4 duplicate across _lib.p/_lib.q: want rc 1, got $RC"
grep -q "dup-lib" "$T/err" && grep -q "_lib\.p\.json" "$T/err" && grep -q "_lib\.q\.json" "$T/err" && ok \
  || bad "A4 stderr must name dup-lib, _lib.p.json and _lib.q.json: $(cat "$T/err")"
grep -q "_lib\.json" "$T/err" && bad "A4 stderr must not blame _lib.json: $(cat "$T/err")" || ok
rm -f "$L/_lib.p.json" "$L/_lib.q.json"

# A5 — a malformed per-lib file (a lib with no `file`).
cat > "$L/_lib.z.json" <<'JSON'
{"libs":[{"id":"z-lib","knobs":[]}]}
JSON
build
[ "$RC" = 1 ] && ok || bad "A5 malformed _lib.z.json: want rc 1, got $RC"
grep -q "_lib\.z\.json" "$T/err" && ok || bad "A5 stderr must name _lib.z.json: $(cat "$T/err")"
rm -f "$L/_lib.z.json"

# A6 — per-lib files only; and --check over them.
mv "$L/_lib.json" "$T/_lib.json.aside"
cat > "$L/_lib.a.json" <<'JSON'
{"libs":[{"id":"a-lib","file":"bin/lib/a.sh","knobs":[]}]}
JSON
build
[ "$RC" = 0 ] && ok || bad "A6 per-lib files only: rc=$RC: $(cat "$T/err")"
[ "$(libids)" = '["a-lib","x-lib"]' ] && ok || bad "A6 libs: $(libids)"
mv "$T/_lib.json.aside" "$L/_lib.json"; rm -f "$L/_lib.a.json"
build --check
[ "$RC" = 0 ] && ok || bad "A6 --check over _lib.json + _lib.x.json: rc=$RC: $(cat "$T/err")"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
