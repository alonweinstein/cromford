#!/bin/bash
# tests/file-claims-contract.bh-2627-test.sh — the fleet file-claims CONTRACT
# slice (BH-2627, slice 1 of BH-2524).
#
# The slice ships an interface and no behaviour, so what this pins is that the
# interface exists and is inert:
#   S1. sourcing bin/lib/file-claims.sh prints nothing and changes nothing
#       (shell options, variables, traps, cwd); it only defines the four fclaim_*.
#   S2. fclaim_put, fclaim_not_before_put, fclaim_list_dir, fclaim_not_before_left are defined.
#   S3. each stub fails open: rc != 0, no stdout, no stderr, under set -u, with
#       FILE_CLAIM_TTL_S unset and set; fclaim_list_dir writes nothing to its outdir.
#   S4. the composed lanes registry carries lib file-claims and its knob.
#   S5. the node suite worker/jobs/test/file-claims-contract.bh-2627.test.js
#       (schema.sql + ADDED_COLUMNS + ensureColumns + the bounds), when this
#       node has node:sqlite.
# Run from anywhere: tests/file-claims-contract.bh-2627-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/bin/lib/file-claims.sh"
FNS="fclaim_put fclaim_not_before_put fclaim_list_dir fclaim_not_before_left"

[ -f "$LIB" ] && ok || bad "missing $LIB"

# --- S1: sourcing has no side effect -----------------------------------------
# Snapshot everything a sourced file could change, source it, snapshot again.
# BASH_* / FUNCNAME / PIPESTATUS / _ move on their own and are not the lib's.
# The snapshot is redirected to a file, never taken inside $(...): bash drops
# errexit in a command substitution, so a lib that ran `set -e` would hide there.
_snap() {
  echo "flags=$-"
  set +o
  shopt -p
  trap -p
  pwd
  compgen -v | grep -vE '^(BASH_.*|FUNCNAME|PIPESTATUS|_|LINENO|RANDOM|SECONDS|SRANDOM|EPOCH.*|__snap_.*)$'
  compgen -A function | grep -v '^fclaim_'
}
( cd "$T" || exit 9
  set -u
  _snap >"$T/snap.before"
  . "$LIB" >"$T/src.out" 2>"$T/src.err"; echo "$?" >"$T/src.rc"
  _snap >"$T/snap.after"
  diff "$T/snap.before" "$T/snap.after" >"$T/src.diff"
  exit 0
) || bad "S1 sourcing subshell failed"
[ "$(cat "$T/src.rc" 2>/dev/null)" = 0 ] && ok || bad "S1 source rc=$(cat "$T/src.rc" 2>/dev/null)"
[ ! -s "$T/src.out" ] && [ ! -s "$T/src.err" ] && ok \
  || bad "S1 sourcing printed: out=[$(cat "$T/src.out")] err=[$(cat "$T/src.err")]"
[ ! -s "$T/src.diff" ] && ok || bad "S1 sourcing changed shell state: $(cat "$T/src.diff" 2>/dev/null)"

# --- S2: the four functions exist --------------------------------------------
for fn in $FNS; do
  ( . "$LIB"; declare -F "$fn" >/dev/null ) && ok || bad "S2 $fn not defined after sourcing"
done

# --- S3: each stub fails open, silently --------------------------------------
printf 'bin/run-build.sh\nworker/jobs/schema.sql\n' > "$T/planned-files.txt"
_call() {  # <fn> -> prints rc; writes $T/c.out $T/c.err
  local fn=$1
  ( set -u
    . "$LIB"
    case "$fn" in
      fclaim_put)             fclaim_put "$T/planned-files.txt" ;;
      fclaim_not_before_put)  fclaim_not_before_put 300 ;;
      fclaim_list_dir)        fclaim_list_dir cromford "$T/out" ;;
      fclaim_not_before_left) fclaim_not_before_left cromford BH-1 ;;
    esac
  ) >"$T/c.out" 2>"$T/c.err"
  echo "$?"
}
for ttl in unset 14400; do
  for fn in $FNS; do
    rm -rf "$T/out"; mkdir -p "$T/out"
    if [ "$ttl" = unset ]; then rc=$(unset FILE_CLAIM_TTL_S JOB_ID; _call "$fn")
    else rc=$(export FILE_CLAIM_TTL_S=$ttl JOB_ID=job-1; _call "$fn"); fi
    [ "$rc" != 0 ] && ok || bad "S3 $fn (ttl=$ttl) returned 0; a stub must fail open with rc != 0"
    [ ! -s "$T/c.out" ] && [ ! -s "$T/c.err" ] && ok \
      || bad "S3 $fn (ttl=$ttl) printed: out=[$(cat "$T/c.out")] err=[$(cat "$T/c.err")]"
    [ -z "$(ls -A "$T/out")" ] && ok || bad "S3 $fn (ttl=$ttl) wrote into the outdir: $(ls -A "$T/out")"
  done
done

# --- S4: the registry row ----------------------------------------------------
if HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >"$T/lb.out" 2>&1; then
  ok
  jq -e '.libs[] | select(.id=="file-claims" and .file=="bin/lib/file-claims.sh")
         | .knobs | length==1 and (.[0] | .env=="FILE_CLAIM_TTL_S" and .type=="int" and .default==14400
           and .min==60 and .max==86400 and .unit=="seconds" and .required==true)' "$T/lanes.json" >/dev/null \
    && ok || bad "S4 lanes registry has no lib file-claims with knob FILE_CLAIM_TTL_S {int,14400,60..86400,seconds,required}"
else
  bad "S4 bin/lanes-build.sh failed: $(cat "$T/lb.out")"
fi

# --- S5: the node suite ------------------------------------------------------
NODE_SUITE="$DIR/worker/jobs/test/file-claims-contract.bh-2627.test.js"
if command -v node >/dev/null 2>&1 && node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  # core.js imports the GENERATED, git-ignored catalog/lanes.json statically,
  # so it is rendered into the checkout first (as controls-contract.bh-2513 does).
  HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null 2>&1 \
    || bad "S5 catalog/lanes.json could not be composed from catalog/lanes.d"
  if (cd "$DIR/worker/jobs" && node --test "$NODE_SUITE") >"$T/node.out" 2>&1; then ok
  else bad "S5 node suite failed:"; grep -E '^not ok|AssertionError|Error' "$T/node.out" | head -20; fi
else
  echo "file-claims-contract: S5 SKIPPED, this node has no node:sqlite (CI's worker/jobs job runs it)"
fi

echo "file-claims-contract: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
