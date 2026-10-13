#!/bin/bash
# tests/state-paths-guard.bh-5005-test.sh — bin/state-paths-guard.sh and
# catalog/state-paths.json (BH-5005, wave 6 of #4951).
#
# A script ADDED by a PR that writes a state/<path> the catalog classifies as
# `rows` fails CI; cache and box-local paths pass. Every case drives the real
# script as a process and asserts its exact rc (1 fired, 0 clean, 2 could not
# check), so a missing script's 127 never reads as "fired".
#   AT1  a new bin/ script redirecting into state/pool -> rc 1, file:line named.
#   AT2  mkdir / tee -a / a `local D=` assignment, one fixture each -> rc 1.
#   AT3  a new scripts/x.py open(..., "w") on state/daily-digest -> rc 1.
#   AT4  git mode, the way CI calls it: an ADDED writer -> rc 1; a branch that
#        only MODIFIES an existing writer -> rc 0.
#   AT5  a cache path (settings-cache.json) and a box-local path (box-id) -> rc 0.
#   AT6  missing / malformed catalog, an unknown class, a duplicate path -> rc 2.
#   AT7  the shipped catalog loads clean and carries all three classes.
#   AT8  adversarial negatives, one fixture each -> rc 0.
#   AT9  escape hatch: label + justification -> rc 0; label alone -> rc 1.
#   AT10 no SPG_FILES and an unknown base ref -> rc 2.
#
# Run from anywhere: tests/state-paths-guard.bh-5005-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
GUARD="$DIR/bin/state-paths-guard.sh"
CATALOG="$DIR/catalog/state-paths.json"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
unset PR_LABELS GUARDRAIL_JUSTIFICATION SPG_FILES SPG_ROOT SPG_CATALOG

[ -x "$GUARD" ] || { echo "FAIL: $GUARD missing or not executable"; exit 1; }

# fx <name> <relpath> <content> [ENV=VAL...] -> $OUT, $RC
# One fixture root per case, holding one ADDED file at <relpath>, checked
# through SPG_FILES against the shipped catalog unless SPG_CATALOG is given.
fx() {
  local name="$1" rel="$2" body="$3"; shift 3
  local R="$T/fx/$name"
  mkdir -p "$R/$(dirname "$rel")"
  printf '%s\n' "$body" > "$R/$rel"
  printf '%s\n' "$rel" > "$T/fx/$name.list"
  OUT=$(env SPG_ROOT="$R" SPG_FILES="$T/fx/$name.list" SPG_CATALOG="$CATALOG" "$@" "$GUARD" 2>&1); RC=$?
}
expect() { # expect <case> <rc> [<substring in OUT>...]
  local c="$1" want="$2"; shift 2
  if [ "$RC" != "$want" ]; then bad "$c: rc=$RC want $want :: $OUT"; return; fi
  local s
  for s in "$@"; do
    case "$OUT" in *"$s"*) ;; *) bad "$c: output lacks '$s' :: $OUT"; return ;; esac
  done
  ok
}

# --- AT1 ---------------------------------------------------------------------
fx at1 bin/new-writer.sh '#!/bin/bash
P=x; KEY=y
echo 1 > "$H/state/pool/$P/$KEY.spawns"'
expect AT1 1 "bin/new-writer.sh:3" "state/pool" "class rows"

# --- AT2 ---------------------------------------------------------------------
fx at2-mkdir bin/a.sh 'mkdir -p "$H/state/claims/$P"'
expect AT2-mkdir 1 "bin/a.sh:1" "state/claims"
fx at2-tee bin/b.sh 'printf x | tee -a "$H/state/build-notes/$P/$K.md"'
expect AT2-tee 1 "bin/b.sh:1" "state/build-notes"
fx at2-local bin/c.sh 'f() {
  local D="$H/state/pr-owners"
}'
expect AT2-local 1 "bin/c.sh:2" "state/pr-owners"

# --- AT3 ---------------------------------------------------------------------
fx at3 scripts/x.py 'import os
H = os.environ["HARNESS"]
with open(H + "/state/daily-digest/sent-" + d, "w") as fh:
    fh.write("1")'
expect AT3 1 "scripts/x.py:3" "state/daily-digest"

# --- AT4: git mode -----------------------------------------------------------
G="$T/git"; mkdir -p "$G/bin" "$G/catalog"
cp "$CATALOG" "$G/catalog/state-paths.json"
printf '#!/bin/bash\necho 1 > "$H/state/pool/$P/old"\n' > "$G/bin/old-writer.sh"
(
  cd "$G" || exit 1
  git init -q -b base . && git config user.email t@t && git config user.name t \
    && git add -A && git commit -qm base \
    && git checkout -qb added \
    && printf '#!/bin/bash\nP=x; KEY=y\necho 1 > "$H/state/pool/$P/$KEY.spawns"\n' > bin/new-writer.sh \
    && git add -A && git commit -qm added \
    && git checkout -q base && git checkout -qb modified \
    && printf 'touch "$H/state/pool/$P/also"\n' >> bin/old-writer.sh \
    && git commit -qam modified
) >/dev/null 2>&1 || bad "AT4: could not build the scratch repo"
git -C "$G" checkout -q added
OUT=$(cd "$G" && SPG_CATALOG="$G/catalog/state-paths.json" "$GUARD" base 2>&1); RC=$?
expect AT4-added 1 "bin/new-writer.sh:3" "state/pool"
git -C "$G" checkout -q modified
OUT=$(cd "$G" && SPG_CATALOG="$G/catalog/state-paths.json" "$GUARD" base 2>&1); RC=$?
expect AT4-modified 0 "clean (0 new scripts checked)"
# The default catalog is the one beside the script, not one in the cwd.
OUT=$(cd "$G" && "$GUARD" base 2>&1); RC=$?
expect AT4-default-catalog 0 "clean"

# --- AT5 ---------------------------------------------------------------------
fx at5-cache bin/d.sh 'jq . > "$H/state/settings-cache.json"'
expect AT5-cache 0 "clean (1 new scripts checked)"
fx at5-boxlocal bin/e.sh 'echo "$ID" > "$H/state/box-id"'
expect AT5-boxlocal 0 "clean (1 new scripts checked)"

# --- AT6: catalog failures ---------------------------------------------------
fx at6-missing bin/f.sh 'echo hi' SPG_CATALOG="$T/nope.json"
expect AT6-missing 2 "STATE-PATHS-GUARD:"
printf '{"version":1,"paths":[' > "$T/bad.json"
fx at6-malformed bin/f.sh 'echo hi' SPG_CATALOG="$T/bad.json"
expect AT6-malformed 2 "STATE-PATHS-GUARD:"
printf '{"version":1,"paths":[{"path":"pool","class":"queue"}]}' > "$T/class.json"
fx at6-class bin/f.sh 'echo hi' SPG_CATALOG="$T/class.json"
expect AT6-class 2 "STATE-PATHS-GUARD:" "queue"
printf '{"version":1,"paths":[{"path":"pool","class":"rows"},{"path":"pool","class":"cache"}]}' > "$T/dup.json"
fx at6-dup bin/f.sh 'echo hi' SPG_CATALOG="$T/dup.json"
expect AT6-dup 2 "STATE-PATHS-GUARD:" "pool"
printf '{"version":1,"paths":[{"path":"","class":"rows"}]}' > "$T/empty.json"
fx at6-empty bin/f.sh 'echo hi' SPG_CATALOG="$T/empty.json"
expect AT6-empty-path 2 "STATE-PATHS-GUARD:"

# --- AT7: the shipped catalog ------------------------------------------------
fx at7 bin/g.sh 'echo hi'
expect AT7-loads 0 "clean (1 new scripts checked)"
for c in rows cache box-local; do
  n=$(jq --arg c "$c" '[.paths[] | select(.class == $c)] | length' "$CATALOG" 2>/dev/null)
  [ "${n:-0}" -ge 1 ] && ok || bad "AT7: no '$c' entry in $CATALOG"
done

# --- AT8: adversarial negatives ----------------------------------------------
fx at8-devnull bin/h.sh 'ls "$H/state/pool/$P" 2>/dev/null'
expect AT8-devnull 0 clean
fx at8-test bin/h.sh '[ -f "$H/state/pool/x" ] && echo yes'
expect AT8-test 0 clean
fx at8-stderr bin/h.sh 'echo "reading state/pool" >&2'
expect AT8-stderr 0 clean
fx at8-2to1 bin/h.sh 'cat "$H/state/claims/x" 2>&1'
expect AT8-2to1 0 clean
fx at8-comment bin/h.sh '  # writes state/pool/<p> > x via mkdir'
expect AT8-comment 0 clean
fx at8-jscomment bin/h.js '// fs.writeFileSync(H + "/state/pool/x")'
expect AT8-jscomment 0 clean
fx at8-prefix bin/h.sh 'echo 1 > "$H/state/pool-stats/x"'
expect AT8-prefix 0 clean
fx at8-suffix bin/h.sh 'touch "$H/state/pool.lock"'
expect AT8-suffix 0 clean
fx at8-fly bin/h.sh 'mkdir -p "$H/state/fly/x"'
expect AT8-fly 0 clean
fx at8-claims-index bin/h.sh 'touch "$H/state/claims-index"'
expect AT8-claims-index 0 clean
fx at8-tests tests/new.bh-1-test.sh 'mkdir -p "$T/h/state/pool/x"'
expect AT8-tests 0 "clean (0 new scripts checked)"
fx at8-fixture guardrails/x/fixtures/w.sh 'mkdir -p "$H/state/pool/x"'
expect AT8-fixture 0 "clean (0 new scripts checked)"
fx at8-unclassified bin/h.sh 'touch "$H/state/main-red"'
expect AT8-unclassified 0 clean
fx at8-md bin/README.md 'echo 1 > state/pool/x'
expect AT8-md 0 "clean (0 new scripts checked)"
# CRLF: the \r must not hide the boundary of a real write.
fx at8-crlf bin/i.sh $'touch "$H/state/pool"\r'
expect CRLF-write 1 "bin/i.sh:1" "state/pool"

# --- AT9: escape hatch -------------------------------------------------------
fx at9-skip bin/new-writer.sh 'echo 1 > "$H/state/pool/$P/$KEY.spawns"' \
  PR_LABELS=skip-guardrail \
  GUARDRAIL_JUSTIFICATION='Guardrail-Justification: a fixture writer proven harmless in this test'
expect AT9-skip 0 "SKIPPED"
fx at9-label bin/new-writer.sh 'echo 1 > "$H/state/pool/$P/$KEY.spawns"' PR_LABELS=skip-guardrail
expect AT9-label-only 1 "bin/new-writer.sh:1"

# --- AT10: git failure -------------------------------------------------------
OUT=$(cd "$G" && SPG_CATALOG="$G/catalog/state-paths.json" "$GUARD" no-such-ref 2>&1); RC=$?
expect AT10 2 "could not diff against no-such-ref"

# A listed file that is not on disk is named, not silently counted clean.
printf 'bin/gone.sh\n' > "$T/gone.list"
OUT=$(SPG_ROOT="$T/fx/at7" SPG_FILES="$T/gone.list" "$GUARD" 2>&1); RC=$?
expect missing-file 0 "bin/gone.sh" "clean (0 new scripts checked)"

echo "state-paths-guard: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
