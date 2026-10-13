#!/bin/bash
# tests/prequeue-invariants-render-race.bh-5775-test.sh — BH-5775: the pre-queue
# gate failed good PRs with "share-mirror-clean: this suite rendered into the
# checkout it was handed: catalog/lanes.json".
#
# The gate runs every invariant row in ONE fresh checkout, four at a time
# (bin/prequeue-invariants.sh --jobs 4). catalog/lanes.json is git-ignored, so it
# is absent there. While share-mirror-clean held its before/after window open,
# another row reached bin/lib/lanes-registry.sh lanes_json_path with the
# checkout as root and rendered it. share-mirror-clean saw the new file and
# blamed itself (gate run 37977020453, PR #5659).
#
#   R1  two rows at once, ordered by FIFOs (no sleep): row A takes the
#       share-mirror-clean snapshot, row B runs the loader, row A takes the
#       second snapshot. No catalog/lanes.json appears inside the window.
#   R2  after the run the checkout holds a current, non-empty JSON render
#   R3  --jobs 1 with one row that never loads lanes: the render is still there
#       (only the runner's warm-up can have made it)
#   R4  a tree with no catalog/lanes.d: rows run, rc 0, nothing rendered
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prequeue-invariants-render-race.bh-5775-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v timeout >/dev/null || { echo "timeout missing — skipping"; exit 0; }

# The stamp directory lives under TMPDIR; keep it in scratch.
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"
unset LANE_REGISTRY

# mktree <dir> [nolanes] — the REAL runner and the REAL loader, the real lane
# sources unless nolanes, committed so `git status --ignored` reads like a checkout.
mktree() {
  local r="$1"
  mkdir -p "$r/tests" "$r/catalog"
  scratch_install_closure bin/prequeue-invariants.sh "$r" >/dev/null || bad "setup: could not install bin/prequeue-invariants.sh"
  scratch_install_closure bin/test-suite-run.sh "$r" >/dev/null || bad "setup: could not install bin/test-suite-run.sh"
  scratch_install_closure bin/lib/lanes-registry.sh "$r" >/dev/null || bad "setup: could not install bin/lib/lanes-registry.sh"
  scratch_install_closure bin/lanes-build.sh "$r" >/dev/null || bad "setup: could not install bin/lanes-build.sh"
  [ "${2:-}" = nolanes ] || cp -R "$DIR/catalog/lanes.d" "$r/catalog/lanes.d"
  printf 'catalog/lanes.json\n' > "$r/.gitignore"
  # Row A: share-mirror-clean's dir_renders window, opened and closed around row B.
  cat > "$r/tests/fx-window.sh" <<'SH'
snap() { git status --porcelain --ignored 2>/dev/null | awk '{print $2}' | grep -E '^catalog/lanes\.json$'; }
B=$(snap)
printf 'go\n' > "$FX_READY"
read -r _ < "$FX_DONE"
A=$(snap)
LEFT=$(comm -13 <(printf '%s\n' "$B") <(printf '%s\n' "$A") | grep -v '^$')
[ -z "$LEFT" ] || { echo "FAIL: rendered into the checkout inside the window: $LEFT"; exit 1; }
echo "fx-window: clean"
SH
  # Row B: any row that reads the lane registry with the checkout as root.
  cat > "$r/tests/fx-loader.sh" <<'SH'
read -r _ < "$FX_READY"
. bin/lib/lanes-registry.sh && lanes_json_path "$PWD" >/dev/null
printf 'done\n' > "$FX_DONE"
SH
  printf 'echo quiet\n' > "$r/tests/fx-quiet.sh"
  ( cd "$r" && git init -q && git add -A \
      && git -c user.email=fixture@example.invalid -c user.name=fixture commit -qm fixture ) \
    || bad "setup: could not commit the fixture tree $r"
}
row() { printf '%s\tcmd\t%s\t30\t%s\n' "$@"; }

# ============================================================================
# R1, R2. Two rows at once.
# ============================================================================
R="$T/r1"; mktree "$R"
[ ! -e "$R/catalog/lanes.json" ] && ok || bad "setup: the fixture tree already holds catalog/lanes.json"
mkfifo "$T/ready" "$T/done"
{ row window tests/fx-window.sh "the window row"; row loader tests/fx-loader.sh "the loader row"; } > "$T/r1.tsv"
( cd "$R" && FX_READY="$T/ready" FX_DONE="$T/done" timeout 120 bash bin/prequeue-invariants.sh \
    --run --catalog "$T/r1.tsv" --out "$T/r1.d" --jobs 2 ) > "$T/r1.out" 2>&1
RC=$?
[ "$RC" = 0 ] && ok || bad "R1: the runner is rc 0 with two rows at once (rc=$RC):
$(cat "$T/r1.out") $(cat "$T/r1.d/log/window.log" 2>/dev/null)"
grep -q '^fx-window: clean' "$T/r1.d/log/window.log" 2>/dev/null && ok \
  || bad "R1: no catalog/lanes.json appears in the checkout while another row's window is open: $(cat "$T/r1.d/log/window.log" 2>/dev/null)"
[ -s "$R/catalog/lanes.json" ] && jq -e . "$R/catalog/lanes.json" >/dev/null 2>&1 && ok \
  || bad "R2: the checkout holds a non-empty JSON catalog/lanes.json after the run"

# ============================================================================
# R3. One row that never loads lanes: the render is the runner's own.
# ============================================================================
R="$T/r3"; mktree "$R"
row quiet tests/fx-quiet.sh "a row that reads no lanes" > "$T/r3.tsv"
( cd "$R" && timeout 60 bash bin/prequeue-invariants.sh --run --catalog "$T/r3.tsv" --out "$T/r3.d" --jobs 1 ) > "$T/r3.out" 2>&1
RC=$?
[ "$RC" = 0 ] && ok || bad "R3: rc 0 (rc=$RC): $(cat "$T/r3.out")"
[ -s "$R/catalog/lanes.json" ] && ok \
  || bad "R3: the runner renders catalog/lanes.json once before any row starts"
OUT=$( cd "$R" && unset LANE_REGISTRY && . bin/lib/lanes-registry.sh && lanes_json_path "$R" )
[ "$OUT" = "$R/catalog/lanes.json" ] && ok || bad "R3: the loader serves the warm render as current (got '$OUT')"

# ============================================================================
# R4. No lane sources: nothing to warm, the rows still run.
# ============================================================================
R="$T/r4"; mktree "$R" nolanes
row quiet tests/fx-quiet.sh "a row that reads no lanes" > "$T/r4.tsv"
( cd "$R" && timeout 60 bash bin/prequeue-invariants.sh --run --catalog "$T/r4.tsv" --out "$T/r4.d" --jobs 1 ) > "$T/r4.out" 2>&1
RC=$?
[ "$RC" = 0 ] && ok || bad "R4: rc 0 with no catalog/lanes.d (rc=$RC): $(cat "$T/r4.out")"
[ ! -e "$R/catalog/lanes.json" ] && ok || bad "R4: nothing is rendered when there are no lane sources"

echo "prequeue-invariants-render-race.bh-5775: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
