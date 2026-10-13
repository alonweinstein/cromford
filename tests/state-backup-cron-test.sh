#!/bin/bash
# tests/state-backup-cron-test.sh — the state-backup lane exists on EVERY box
# (BH-448, #396.3), in all three places that decide a box's crontab:
#
#   1. cron/<box>.cron          — the ten checked-in artifacts update-runners.sh
#                                 and fleet-propagate.sh lay down on a live box
#   2. cron_box_lines()         — what bin/bootstrap-machine.sh seeds a NEW box
#                                 with, per BOX and not per project
#   3. the singleton filter     — the `| grep -v state-backup` that keeps a
#                                 re-bootstrap from carrying two copies
#
# THE PROPERTY: exactly ONE line, everywhere, never zero and never two. Zero is
# a box with no off-box copy of its state, which is #388 all over again; two is
# a doubled 15-minute lane racing itself on one bucket. Every count below is an
# equality, so a line that vanished and a line that doubled both fail here.
#
# WHAT IS DRIVEN vs WHAT IS PINNED:
#   - cases 1a/2 drive real artifacts and the REAL renderer (bin/render-crontab.sh,
#     the production entry point): the operator line has to survive a render, which
#     is also how we know it sits OUTSIDE every # BEGIN/END fleet-managed block.
#   - case 1b sources the real bin/lib/cron-lines.sh and calls cron_box_lines.
#   - case 1c/3 are a SOURCE PIN and say so: bin/bootstrap-machine.sh apt-gets,
#     clones repos and opens a paid claude session, so it cannot be executed in a
#     fixture, and the filter is an inline pipeline with no marker to extract.
#     Both pins assert a count, so a filter that vanished fails here rather than
#     matching nothing quietly.
#
# MUTATION CHECK (D1): cases 4-7 are not commentary, they run on every pass —
# each one copies the tree, breaks ONE of the three places, and requires
# check_tree to go red and to name what broke.
#
# Run from anywhere: tests/state-backup-cron-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json and cron/<box>.cron are GENERATED and not
# committed. rendered_registry / rendered_cron render this repo's own into $T.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The line, exactly as the ticket fixes it. Anchored at both ends: a line that
# lost its redirect, or gained a trailing argument, is not this lane.
LINE_RE='^5,20,35,50 \* \* \* \* /root/harness/bin/state-backup\.sh >/dev/null 2>&1$'

# check_tree <root> — the three greps of the acceptance criteria, against any
# checkout-shaped tree. Prints one MISSING line per miss (naming the box or the
# file, so a mutation says what it broke) and returns non-zero if there was one.
# BH-1247: cron/<box>.cron is GENERATED and not committed, so the directory of
# rendered crontabs is passed in rather than assumed to sit at <root>/cron. The
# mutants below still carry theirs at that path (mutant() renders into it), so
# the default keeps every mutation case spelled exactly as it was.
check_tree() {
  local root="$1" crondir="${2:-$1/cron}" miss=0 f id n
  for f in "$crondir"/*.cron; do
    id=$(basename "$f" .cron)
    n=$(grep -cE -- "$LINE_RE" "$f")
    [ "$n" = 1 ] || { echo "MISSING cron line in $id: expected 1 hit, got $n"; miss=1; }
  done
  for mode in "" fly; do
    n=$(bash -c '. "$1"/bin/lib/cron-lines.sh; cron_box_lines "$2"' _ "$root" "$mode" \
        | grep -cE -- "$LINE_RE")
    [ "$n" = 1 ] || { echo "MISSING cron_box_lines ${mode:-plain}: expected 1 hit, got $n"; miss=1; }
  done
  n=$(grep -cF -- 'grep -v state-backup' "$root/bin/bootstrap-machine.sh")
  [ "$n" = 1 ] || { echo "MISSING bootstrap singleton filter: expected 1 hit, got $n"; miss=1; }
  return "$miss"
}

# mutant <name> — a fresh copy of the three places, for one mutation each.
mutant() {
  local m="$T/$1"
  rm -rf "$T/$1"
  mkdir -p "$m/bin/lib"
  cp -r "$DIR/cron" "$m/cron"
  # ...plus the RENDERED crontabs, which are generated and not committed
  # (BH-1247) so `cp -r cron` does not bring them. Cases 4 and 7 mutate one of
  # these files by name, so a mutant without them mutates nothing and passes.
  cp "$(rendered_cron_dir)"/*.cron "$m/cron/"
  cp "$DIR/bin/lib/cron-lines.sh" "$m/bin/lib/"
  cp "$DIR/bin/bootstrap-machine.sh" "$m/bin/"
  printf '%s\n' "$m"
}

# lineno / before — the order pin, same shape as tests/harden-state-lanes-test.sh.
lineno() { grep -nF -- "$1" "$2" | cut -d: -f1 | sed -n 1p; }
before() {
  local label="$1" a b
  a=$(lineno "$2" "$4"); b=$(lineno "$3" "$4")
  if [ -z "$a" ] || [ -z "$b" ]; then
    bad "$label: one of the two anchors is missing ([$2]=${a:-none} [$3]=${b:-none})"
  elif [ "$a" -lt "$b" ]; then ok
  else bad "$label: [$2] is at line $a, expected above [$3] at line $b"
  fi
}

# ---------- 1: the repo itself is green ----------
OUT=$(check_tree "$DIR" "$(rendered_cron_dir)"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "1 the branch must carry the lane in all three places:
$OUT"

# ---------- 2: the REAL renderer preserves the operator line ----------
# render-crontab.sh owns the per-project managed blocks and nothing else, so a
# line it re-emits exactly once is a line outside every block. This is the path
# update-runners.sh and fleet-propagate.sh actually run on a live box.
for F in "$(rendered_cron_dir)"/*.cron; do
  ID=$(basename "$F" .cron)
  # The LANE line, not every mention: the 3-line operator comment above it names
  # bin/state-backup.sh too, and a comment is not a schedule.
  N=$("$DIR/bin/render-crontab.sh" "$ID" 2>/dev/null | grep -cE -- "$LINE_RE")
  [ "$N" = 1 ] && ok || bad "2 render-crontab.sh $ID must emit the lane exactly once, got $N"
done

# ---------- 3: the filter runs BEFORE the box lines are re-emitted ----------
# (SOURCE PIN.) The other order drops the line the filter just re-added, or
# keeps the stale one — either way a re-bootstrap stops being idempotent.
before "3 the filter reads the live crontab first" \
  'crontab -l' 'grep -v state-backup' "$DIR/bin/bootstrap-machine.sh"
before "3 the filter runs before the box lines are re-emitted" \
  'grep -v state-backup' 'cron_box_lines "$FLY_CRON"' "$DIR/bin/bootstrap-machine.sh"

# ---------- 4: MUTATION — the line deleted from one cron file ----------
M=$(mutant mut-cron)
sed -i '/state-backup\.sh/d' "$M/cron/project-3.cron"
OUT=$(check_tree "$M"); RC=$?
[ "$RC" -ne 0 ] && ok || bad "4 a cron file without the lane must be red"
grep -qF -- 'project-3' <<<"$OUT" && ok || bad "4 the failure must name the box that lost it (got: $OUT)"

# ---------- 5: MUTATION — the printf deleted from cron_box_lines ----------
M=$(mutant mut-lib)
sed -i '/state-backup\.sh/d' "$M/bin/lib/cron-lines.sh"
OUT=$(check_tree "$M"); RC=$?
[ "$RC" -ne 0 ] && ok || bad "5 a cron_box_lines without the lane must be red"
grep -qF -- 'cron_box_lines' <<<"$OUT" && ok || bad "5 the failure must name cron_box_lines (got: $OUT)"

# ---------- 6: MUTATION — the bootstrap filter removed ----------
M=$(mutant mut-boot)
sed -i 's/ | grep -v state-backup//' "$M/bin/bootstrap-machine.sh"
OUT=$(check_tree "$M"); RC=$?
[ "$RC" -ne 0 ] && ok || bad "6 a bootstrap without the singleton filter must be red"
grep -qF -- 'singleton filter' <<<"$OUT" && ok || bad "6 the failure must name the filter (got: $OUT)"

# ---------- 7: MUTATION — the line doubled in one cron file ----------
# Exactly one, not at-least-one: the doubled line is the re-bootstrap failure
# the filter in case 3 exists to prevent, so the check has to see it.
M=$(mutant mut-double)
grep -E -- "$LINE_RE" "$(rendered_cron project-4)" >> "$M/cron/project-4.cron"
OUT=$(check_tree "$M"); RC=$?
[ "$RC" -ne 0 ] && ok || bad "7 a doubled lane must be red, not tolerated"
grep -qF -- 'project-4' <<<"$OUT" && ok || bad "7 the failure must name the box that doubled it (got: $OUT)"

echo "state-backup-cron-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
