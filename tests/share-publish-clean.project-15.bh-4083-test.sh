#!/bin/bash
# tests/share-publish-clean.project-15.bh-4083-test.sh — the project-15 names and every
# client project name are rewritten by the publisher's sanitizer, refused by its
# guard when they are not, and nothing innocent is caught on the way (BH-4083).
#
# The public copy (cromford-ai/cromford) is built by the same three gates as the
# share mirror: bin/share/sanitize.py, then bin/share/leakcheck.py, then
# bin/share/gitleaks-gate.py. This suite drives those three scripts over a
# scratch source tree with the names planted in it, the way bin/publish-share.sh
# drives them over a checkout.
#
# NO NAME IS SPELLED IN THIS FILE. It ships in the mirror (sanitized), and a
# literal here would be a hit for the guard it tests. The project-15 forms are glued
# together at run time, and the per-project names are read out of
# bin/share/mapping.py, so a project added there is planted here without an
# edit.
#
# Run from anywhere: tests/share-publish-clean.project-15.bh-4083-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0; SKIP=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
SHARE="$DIR/bin/share"

if [ ! -f "$SHARE/sanitize.py" ]; then
  # The mirror does not carry bin/share: the publisher is upstream-only.
  echo "SKIP share-publish-clean.project-15: no bin/share in this copy"
  exit 0
fi
if [ -n "${GITLEAKS_REQUIRED:-}" ] && ! command -v gitleaks >/dev/null 2>&1; then
  echo "FAIL: GITLEAKS_REQUIRED is set but gitleaks is not on PATH (BH-2059)"
  echo "share-publish-clean.project-15.bh-4083-test: 0 pass, 1 fail, 0 skip"
  exit 1
fi

# ── the planted forms ───────────────────────────────────────────────────────
R="r""ri"; RB="rob""bins"; ORG="Fortu""nian"
declare -a PLANT_NAME PLANT_TEXT
plant() { PLANT_NAME+=("$1"); PLANT_TEXT+=("$2"); }
plant "project-15-backstage repo"   "${R}-backstage"
plant "org/project-15-backstage"    "${ORG}/${R}-backstage"
plant "project-15 in prose"         "$(printf '%s' "$R" | tr a-z A-Z)"
plant "project-15"     "$(printf '%s' "${RB^}") Research"
plant "project-15"      "${RB}research"
plant "project-15"          "collaborator-4${RB}"
# One plant per row of PROJECTS and BOUNDED_PROJECTS, read from the table.
while IFS= read -r p; do
  [ -n "$p" ] && plant "project row $p" "$p"
done < <(cd "$SHARE" && python3 -c '
from mapping import PROJECTS, BOUNDED_PROJECTS
for a, _ in PROJECTS + BOUNDED_PROJECTS: print(a)')
[ "${#PLANT_TEXT[@]}" -gt 10 ] && ok || bad "planted only ${#PLANT_TEXT[@]} forms — could not read mapping.py"

# The negative list: ordinary words that contain a name's letters, our own
# sandbox Jira key, and the public repo's own name. None may be rewritten or
# flagged.
NEG=(carrier worried terrier Ferris backstage CROM cromford)

# ── a scratch source tree the sanitizer will accept ─────────────────────────
# sanitize.py applies its PATCHES after the rewrite and fails if a target is
# missing, so the patched files are copied in from this checkout. The rest of
# the tree is the planted files only.
SRC="$T/src"; mkdir -p "$SRC/notes"
while IFS= read -r rel; do
  mkdir -p "$SRC/$(dirname "$rel")"
  cp "$DIR/$rel" "$SRC/$rel"
done < <(cd "$SHARE" && python3 -c '
import sanitize
for rel, _, _ in sanitize.PATCHES: print(rel)' | sort -u)
for i in "${!PLANT_TEXT[@]}"; do
  printf 'line one\nsee the %s board for the history\nend\n' "${PLANT_TEXT[$i]}" > "$SRC/notes/plant-$i.md"
done
printf '%s\n' "${NEG[@]}" > "$SRC/notes/negatives.md"

# ── 1. sanitize rewrites every planted form ─────────────────────────────────
python3 "$SHARE/sanitize.py" "$SRC" "$T/mirror" > "$T/sanitize.out" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  bad "sanitize.py exited $rc"; sed -n '1,20p' "$T/sanitize.out"
  echo "share-publish-clean.project-15.bh-4083-test: $PASS pass, $FAIL fail, $SKIP skip"; exit 1
fi
ok
for i in "${!PLANT_TEXT[@]}"; do
  f="$T/mirror/notes/plant-$i.md"
  if [ ! -f "$f" ]; then bad "1 ${PLANT_NAME[$i]}: the planted file did not reach the mirror"; continue; fi
  if grep -qiF -- "${PLANT_TEXT[$i]}" "$f"; then
    bad "1 ${PLANT_NAME[$i]}: survived sanitize: $(sed -n 2p "$f")"
  else ok; fi
done
# The exact rewrites the project-15 rows exist for. A leftover fragment ("…-research",
# "collaborator-4…") is a half-rewritten name, which the guard would refuse.
expect() { # <plant index> <expected line 2>
  local got; got=$(sed -n 2p "$T/mirror/notes/plant-$1.md" 2>/dev/null)
  if [ "$got" = "see the $2 board for the history" ]; then ok
  else bad "1 ${PLANT_NAME[$1]}: rewrote to '$got', expected 'see the $2 board for the history'"; fi
}
expect 0 "project-15-backstage"
expect 1 "example-org/project-15"
expect 2 "project-15"
expect 3 "project-15"
expect 4 "project-15"
expect 5 "project-15"

# ── 2. the sanitized tree passes the publisher's guard ──────────────────────
python3 "$SHARE/leakcheck.py" "$T/mirror" > "$T/leak-clean.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then ok; else
  bad "2 leakcheck refused the sanitized tree (rc=$rc):"; sed -n '1,30p' "$T/leak-clean.out"
fi

# ── 3. the negative list is untouched and unflagged ─────────────────────────
if cmp -s "$SRC/notes/negatives.md" "$T/mirror/notes/negatives.md"; then ok
else bad "3 sanitize rewrote an innocent word: $(diff "$SRC/notes/negatives.md" "$T/mirror/notes/negatives.md" | tr '\n' ' ')"; fi
mkdir -p "$T/negonly"; cp "$SRC/notes/negatives.md" "$T/negonly/"
python3 "$SHARE/leakcheck.py" "$T/negonly" > "$T/leak-neg.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then ok; else bad "3 leakcheck flagged an innocent word:"; cat "$T/leak-neg.out"; fi

# ── 4. an UNSANITIZED copy is refused, naming every planted file ────────────
mkdir -p "$T/raw"; cp -r "$SRC/notes" "$T/raw/"
python3 "$SHARE/leakcheck.py" "$T/raw" > "$T/leak-raw.out" 2>&1
rc=$?
if [ "$rc" -eq 1 ]; then ok; else bad "4 leakcheck exited $rc on the unsanitized copy, expected 1"; fi
for i in "${!PLANT_TEXT[@]}"; do
  if grep -q "^notes/plant-$i\.md:" "$T/leak-raw.out"; then ok
  else bad "4 ${PLANT_NAME[$i]}: leakcheck did not name notes/plant-$i.md"; fi
done
if grep -q '^notes/negatives\.md:' "$T/leak-raw.out"; then
  bad "4 leakcheck named the negative-list file: $(grep '^notes/negatives\.md:' "$T/leak-raw.out" | head -3 | tr '\n' ' ')"
else ok; fi

# ── 5. the second opinion over the sanitized tree ───────────────────────────
if command -v gitleaks >/dev/null 2>&1; then
  python3 "$SHARE/gitleaks-gate.py" "$T/mirror" > "$T/gitleaks.out" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then ok; else bad "5 gitleaks-gate refused the sanitized tree (rc=$rc):"; cat "$T/gitleaks.out"; fi
else
  SKIP=$((SKIP+1))
  echo "SKIP 5 gitleaks-gate: gitleaks not on PATH (CI sets GITLEAKS_REQUIRED)"
fi

echo "share-publish-clean.project-15.bh-4083-test: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
