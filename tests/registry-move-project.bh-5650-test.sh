#!/bin/bash
# tests/registry-move-project.bh-5650-test.sh — BH-5650: bin/registry.sh
# move-project through the REAL harness-jobs worker
# (tests/lib/registry-fixture-curl.bh-5650.mjs over SQLite, seeded from this
# tree's files), read back through bin/box-for.sh in db mode.
#
#   M1 box-for.sh <p> prints the seeded box; after move-project --box
#      box-small it prints box-small
#   M2 the newest audit row is entity project, key <p>, old box -> new box,
#      actor from --actor; the offset is kept
#   M3 a move to a box with no boxes row is rc 1 (400) and writes nothing
# Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
. "$DIR/tests/lib/registry-fixture.bh-5650.sh" || exit 1
CLI="$DIR/bin/registry.sh"
BF="$DIR/bin/box-for.sh"
FC="$DIR/bin/fleet-conf.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

rfx_setup; R=$?
[ "$R" -ne 3 ] || { echo "SKIP: node:sqlite is not available"; exit 0; }
[ "$R" -eq 0 ] || { echo "FAIL: the fixture registry could not be seeded"; exit 1; }
audit_n() { rfx_q 'SELECT COUNT(*) AS n FROM registry_audit' | jq '.[0].n'; }

# The first seeded active project that is NOT on box-small.
P=$(jq -r '[.projects[] | select(.status == "active" and .box != null and .box != "box-small")][0].project' "$T/seed.json")
OLD=$(jq -r --arg p "$P" '.projects[] | select(.project == $p) | .box' "$T/seed.json")
OFF=$(jq -r --arg p "$P" '.projects[] | select(.project == $p) | .cron_offset' "$T/seed.json")
[ -n "$P" ] && [ "$P" != null ] && ok || bad "precondition: no seeded project off box-small"

# ---- M1 ----------------------------------------------------------------------
OUT=$(REGISTRY_CACHE_TTL_S=0 rfx_db "$BF" "$P" 2>/dev/null)
[ "$OUT" = "$OLD" ] && ok || bad "M1 before: box-for.sh $P = '$OUT', want $OLD"
V0=$(rfx_q 'SELECT version FROM registry_meta' | jq '.[0].version')
OUT=$(rfx_db "$CLI" move-project "$P" --box box-small --actor m1-fixture 2>"$T/m1.err"); R=$?
[ "$R" = 0 ] && [ "$OUT" = "registry: move-project changed=1 version=$((V0+1))" ] && ok || bad "M1 move rc $R '$OUT' $(cat "$T/m1.err")"
OUT=$(REGISTRY_CACHE_TTL_S=0 rfx_db "$BF" "$P" 2>/dev/null)
[ "$OUT" = box-small ] && ok || bad "M1 after: box-for.sh $P = '$OUT'"
OUT=$(REGISTRY_CACHE_TTL_S=0 rfx_db "$FC" "$P" offset 2>/dev/null)
[ "$OUT" = "$OFF" ] && ok || bad "M1 the offset changed: $OUT, was $OFF"

# ---- M2 ----------------------------------------------------------------------
rfx_q 'SELECT entity, key, old_value, new_value, actor, version FROM registry_audit ORDER BY id DESC LIMIT 1' > "$T/m2.json"
[ "$(jq -r '.[0] | "\(.entity) \(.key) \(.actor) \(.version)"' "$T/m2.json")" = "project $P m1-fixture $((V0+1))" ] && ok \
  || bad "M2 newest audit row: $(cat "$T/m2.json")"
[ "$(jq -r '.[0].old_value | fromjson | .box' "$T/m2.json")" = "$OLD" ] && ok || bad "M2 old_value.box"
[ "$(jq -r '.[0].new_value | fromjson | .box' "$T/m2.json")" = box-small ] && ok || bad "M2 new_value.box"

# ---- M3 ----------------------------------------------------------------------
A0=$(audit_n)
ERR=$(rfx_db "$CLI" move-project "$P" --box box-nowhere 2>&1 >/dev/null); R=$?
[ "$R" = 1 ] && [[ "$ERR" == *http=400* && "$ERR" == *"has no boxes row"* ]] && ok || bad "M3 rc $R '$ERR'"
[ "$(audit_n)" = "$A0" ] && ok || bad "M3 the refused move wrote audit rows"
OUT=$(REGISTRY_CACHE_TTL_S=0 rfx_db "$BF" "$P" 2>/dev/null)
[ "$OUT" = box-small ] && ok || bad "M3 the refused move changed the box: $OUT"

echo "registry-move-project: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
