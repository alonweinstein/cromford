#!/bin/bash
# tests/rules-pack-pool-tmp.bh-5284-test.sh — the lead review pool (BH-5284,
# PR #5296) gives every worker TMPDIR=$RPOOL_DIR/tmp.<id>, under the box's
# /root/harness/tmp, and /root is mode 700. The rules pack built its isolated
# snapshot under that TMPDIR and ran each component as nobody, who cannot
# reach it: every RATCHET_BASE-reading suite said `base '<sha>' does not
# resolve to a commit in .../repo` and the lead review posted it as a BLOCK
# (9 of 22 pooled reviews on 2026-10-07). Drives the REAL bin/rules-pack.sh
# (--runner isolated, real setpriv) through the REAL bin/lib/review-pool.sh
# workers, against a fixture repo, with the pool dir under a root-only dir:
#   P1. two concurrent pool workers each run the pack: both rc 0, state clean,
#       no finding, no `does not resolve` anywhere; the snapshot moved out of
#       the unreachable TMPDIR (stderr says so).
#   P2. when no reachable place is left for the snapshot
#       (RULES_PACK_SNAPSHOT_TMP is unreachable too): rc 125, state
#       could-not-run, every selected component could-not-run, stdout (the
#       findings the lead review turns into BLOCK lines) empty.
# Needs root, setpriv and jq (the isolated runner is root-only); skips without.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/rules-pack-pool-tmp.bh-5284-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/ratchet-delta.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

if [ "$(id -u)" -ne 0 ] || ! command -v setpriv >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "skipping: needs root, setpriv and jq (the isolated runner)"; exit 0
fi
setpriv --reuid nobody --regid nogroup --clear-groups true 2>/dev/null \
  || { echo "skipping: setpriv cannot switch to nobody here"; exit 0; }
[ -n "${T:-}" ] && [ -d "$T" ] || { echo "FAIL: no scratch dir"; exit 1; }
cd "$T" || exit 1
unset RULES_PACK_BUDGET_S RULES_PACK_JOBS PROJECT RULES_PACK_SNAPSHOT_TMP

# --- the fixture: this checkout at B, one harmless commit on `work` ----------
R="$T/r"
mkdir -p "$R"
git -C "$DIR" archive HEAD | tar -x -C "$R" || { echo "FAIL: cannot archive HEAD"; exit 1; }
rd_fixture_repo "$R" || { echo "FAIL: cannot build the fixture repo"; exit 1; }
rd_git "$R" config gc.auto 0
echo note > "$R/docs-note.txt"
rd_git "$R" add -A && rd_git "$R" commit -qm "a harmless change" || { echo "FAIL: fixture commit"; exit 1; }

# /root on the box: a root-only dir holding the pool dir.
LOCK="$T/rootonly"
mkdir -p "$LOCK" && chmod 700 "$LOCK"
setpriv --reuid nobody --regid nogroup --clear-groups test -x "$LOCK/." 2>/dev/null \
  && { echo "FAIL: fixture: nobody can enter $LOCK"; exit 1; }
mkdir -p "$T/nolg"

# shellcheck source=bin/lib/review-pool.sh
. "$DIR/bin/lib/review-pool.sh" || { echo "FAIL: cannot source review-pool.sh"; exit 1; }

# pack_worker <tag> — one pool worker's rules pack, as bin/lead-review.sh runs it.
# The fixture's own copy of bin/rules-pack.sh (this checkout's, archived), so
# the judged tree is the fixture: the pack's default tree is its own repo.
pack_worker() {
  local tag="$1"
  env HARNESS="$T/nolg" bash "$R/bin/rules-pack.sh" --base origin/main \
    --runner isolated --only lib-root,switch --out "$T/$tag.out" \
    > "$T/$tag.stdout" 2> "$T/$tag.stderr"
  echo "$?" > "$T/$tag.rc"
  # What TMPDIR the worker had, to prove the fixture is the pool's shape.
  printf '%s\n' "${TMPDIR:-}" > "$T/$tag.tmpdir"
}
js() { jq -r "$2" "$T/$1.out/summary.json" 2>/dev/null; }

# --- P1: two concurrent pool workers -----------------------------------------
REVIEW_POOL_TMP_PATH="$T" LEAD_REVIEW_BOX_MAX=2 rpool_init lead-review LEAD_REVIEW 2 "$LOCK/lead-review-queue-1.pool"
rpool_start r1 pack_worker p1a
rpool_start r2 pack_worker p1b
rpool_wait_all
for tag in p1a p1b; do
  case "$(cat "$T/$tag.tmpdir" 2>/dev/null)" in
    "$LOCK/lead-review-queue-1.pool/tmp."*) ok ;;
    *) bad "P1 $tag: worker TMPDIR $(cat "$T/$tag.tmpdir" 2>/dev/null) is not the pool's per-worker dir" ;;
  esac
  rc=$(cat "$T/$tag.rc" 2>/dev/null)
  [ "$rc" = 0 ] && ok || bad "P1 $tag rc $rc (want 0); stdout: $(head -n 5 "$T/$tag.stdout"); stderr: $(tail -n 5 "$T/$tag.stderr")"
  [ "$(js "$tag" .state)" = clean ] && ok || bad "P1 $tag summary state $(js "$tag" .state) (want clean)"
  [ -s "$T/$tag.stdout" ] && bad "P1 $tag wrote findings: $(head -n 3 "$T/$tag.stdout")" || ok
  if grep -q 'does not resolve' "$T/$tag.stdout" "$T/$tag.stderr" "$T/$tag.out/"*.log 2>/dev/null; then
    bad "P1 $tag: a component could not resolve the snapshot base"
  else ok; fi
  grep -q 'not reachable by nobody' "$T/$tag.stderr" && ok || bad "P1 $tag stderr does not say the snapshot moved: $(tail -n 3 "$T/$tag.stderr")"
done

# --- P2: nowhere reachable left: could-not-run, never findings ---------------
RULES_PACK_SNAPSHOT_TMP="$LOCK" TMPDIR="$LOCK" pack_worker p2
rc=$(cat "$T/p2.rc" 2>/dev/null)
[ "$rc" = 125 ] && ok || bad "P2 rc $rc (want 125); stdout: $(head -n 5 "$T/p2.stdout")"
[ "$(js p2 .state)" = could-not-run ] && ok || bad "P2 summary state $(js p2 .state) (want could-not-run)"
[ "$(js p2 '.could_not_run | sort | join(",")')" = lib-root,switch ] && ok || bad "P2 could_not_run $(js p2 '.could_not_run')"
[ -s "$T/p2.stdout" ] && bad "P2 wrote findings (a BLOCK to the lead review): $(head -n 3 "$T/p2.stdout")" || ok
grep -q 'could-not-run: lib-root: .*nobody' "$T/p2.stderr" && ok || bad "P2 stderr does not name the reason: $(tail -n 4 "$T/p2.stderr")"

echo "rules-pack-pool-tmp.bh-5284: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
