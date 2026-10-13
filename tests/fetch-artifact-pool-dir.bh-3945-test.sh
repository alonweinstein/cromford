#!/bin/bash
# tests/fetch-artifact-pool-dir.bh-3945-test.sh — BH-3945: a pool build leaves
# two dirs for one ticket, the local QUEUED_FLY stub (RESULT, job.json,
# COMMENTED; written last, so newest) and the staged `-remote<ts>` dir that
# actually holds review.md. bin/fetch-artifact.sh must answer from the newest
# dir that HOLDS the requested file, and fall back to the newest dir only when
# none does, so `missing` stays honest. Drives the real script.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export HARNESS="$T"
cat > "$T/fleet.conf" <<'CONF'
alpha-os  Org/alpha  https://alpha.example  /api/board  2 box-alpha
CONF
export FLEET_CONF="$T/fleet.conf"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
ap() { "$DIR/bin/fetch-artifact.sh" --path "$@" 2>/dev/null; }
aj() { "$DIR/bin/fetch-artifact.sh" "$@" 2>/dev/null; }

STUB="$T/builds/alpha-os-TK-88-202610031233"
REMOTE="$T/builds/alpha-os-TK-88-remote20261003153308"
mkdir -p "$STUB" "$REMOTE"
echo QUEUED_FLY > "$STUB/RESULT"; echo '{}' > "$STUB/job.json"; : > "$STUB/COMMENTED"
printf 'VERDICT: APPROVE\nthe remote review\n' > "$REMOTE/review.md"
touch -t 202610031530 "$REMOTE"
touch -t 202610031600 "$STUB"

# --- A1: the main call answers from the dir that holds review.md ------------
OUT=$(aj alpha-os TK-88 review cid-1); RC=$?
[ "$RC" = 0 ] && [ "$(jq -r .missing <<<"$OUT")" = false ] \
  && [ "$(jq -r .content <<<"$OUT")" = "$(cat "$REMOTE/review.md")" ] \
  && [ "$(jq -r .build_dir <<<"$OUT")" = "$REMOTE" ] \
  && ok || bad "A1 newest dir holding review.md should answer (rc=$RC out=$OUT)"

# --- A2: --path resolves to the same file, rc 0 -----------------------------
OUT=$(ap alpha-os TK-88 review); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "$REMOTE/review.md" ] \
  && ok || bad "A2 --path should print the remote review.md (rc=$RC out=$OUT)"

# --- A3: nobody has qa.md -> newest dir, missing:true; --path rc 2 ----------
OUT=$(aj alpha-os TK-88 qa cid-3); RC=$?
[ "$RC" = 0 ] && [ "$(jq -r .missing <<<"$OUT")" = true ] && [ "$(jq -r .content <<<"$OUT")" = "" ] \
  && [ "$(jq -r .build_dir <<<"$OUT")" = "$STUB" ] \
  && ok || bad "A3 absent everywhere -> missing:true, build_dir=newest (rc=$RC out=$OUT)"
OUT=$(ap alpha-os TK-88 qa); RC=$?
[ "$RC" = 2 ] && [ -z "$OUT" ] && ok || bad "A3 --path for an absent artifact should exit 2 (rc=$RC out=$OUT)"

# --- A4: both dirs hold plan.md -> the newest one wins ----------------------
echo "stub plan" > "$STUB/plan.md"; echo "remote plan" > "$REMOTE/plan.md"
touch -t 202610031530 "$REMOTE"; touch -t 202610031600 "$STUB"
OUT=$(aj alpha-os TK-88 plan cid-4)
[ "$(jq -r .content <<<"$OUT")" = "stub plan" ] && [ "$(jq -r .build_dir <<<"$OUT")" = "$STUB" ] \
  && [ "$(ap alpha-os TK-88 plan)" = "$STUB/plan.md" ] \
  && ok || bad "A4 both hold plan.md, newest should win (out=$OUT)"

# --- A5: TK-8 never reads TK-88's review ------------------------------------
OUT=$(aj alpha-os TK-8 review cid-5); RC=$?
[ "$RC" = 0 ] && [ "$(jq -r .missing <<<"$OUT")" = true ] && [ "$(jq -r .build_dir <<<"$OUT")" = "" ] \
  && ok || bad "A5 TK-8 must not match TK-88 dirs (rc=$RC out=$OUT)"
OUT=$(ap alpha-os TK-8 review); RC=$?
[ "$RC" = 2 ] && [ -z "$OUT" ] && ok || bad "A5 --path TK-8 should exit 2 (rc=$RC out=$OUT)"

# --- A6: a glob key is still refused rc 1 -----------------------------------
OUT=$(ap alpha-os 'TK-88*' review); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "A6 key 'TK-88*' should be refused rc=1 (rc=$RC out=$OUT)"
OUT=$(aj alpha-os 'TK-88*' review cid-6); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "A6 main path should refuse 'TK-88*' rc=1 (rc=$RC out=$OUT)"

# --- A7: a glob match that is a FILE is skipped, not returned ---------------
echo "not a dir" > "$T/builds/alpha-os-TK-88-zzfile"
touch -t 202610031700 "$T/builds/alpha-os-TK-88-zzfile"
OUT=$(aj alpha-os TK-88 qa cid-7)
[ "$(jq -r .build_dir <<<"$OUT")" = "$STUB" ] && [ "$(ap alpha-os TK-88 review)" = "$REMOTE/review.md" ] \
  && ok || bad "A7 a newer plain file must not be taken for a build dir (out=$OUT)"

echo "fetch-artifact pool dir: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
