#!/bin/bash
# tests/lib/switch-ratchet-tree.sh — a HERMETIC tree for driving
# tests/switch-ratchet.bh-2320-test.sh's strict-mode .drop floor from a fixture
# suite. Sourced after tests/lib/scratch.sh (needs $T) with $DIR set; never
# executed.
#
#   srt_tree <root> <k>   build <root> with the real suite and its libs, one
#                         lane_switch reader (the dora-digest pilot's registry
#                         file included) and exactly <k> bare switch reads in
#                         bin/s1.sh..s<k>.sh, one per file, plus
#                         tests/switch-ratchet.d/base.drop holding FLOOR - <k>,
#                         so the tree sits exactly AT the effective floor.
#                         Sets SRT_FLOOR to the suite's FLOOR, read out of the
#                         suite, never retyped. rc 1 on any failure.
#   srt_run <root>        the copied suite in strict mode; its output on stdout.
#
# WHY NOT A COPY OF THE LIVE TREE. lane-switch.bh-2407, switch-fixture.bh-2409
# and switch-convert-fixture.bh-2440 used to copy bin/ and fly/ and the
# committed .drop files, so "the unchanged copy is green" was
# switch-ratchet's own live-tree check run three more times, and each of them
# went red whenever switch-ratchet did (the 2026-09-25..28 batches). The .drop
# arithmetic those suites prove does not depend on the live tree at all.

srt_tree() {
  local r="$1" k="$2" i
  case "$k" in ''|*[!0-9]*) echo "srt_tree: k '$k' is not a count" >&2; return 1 ;; esac
  mkdir -p "$r/bin" "$r/fly" "$r/catalog/switches.d" "$r/tests/lib" "$r/tests/switch-ratchet.d" || return 1
  cp "$DIR/tests/switch-ratchet.bh-2320-test.sh" "$r/tests/" || return 1
  cp "$DIR/tests/lib/scratch.sh" "$DIR/tests/lib/ratchet-delta.sh" "$r/tests/lib/" || return 1
  cp "$DIR/catalog/switches.d/dora-digest-off.json" "$r/catalog/switches.d/" || return 1
  printf '#!/bin/bash\nlane_switch dora-digest-off && exit 0\n' > "$r/bin/pilot.sh" || return 1
  for ((i = 1; i <= k; i++)); do
    printf '#!/bin/bash\n[ -f "$H/flags/s%s-off" ] && exit 0\n' "$i" > "$r/bin/s$i.sh" || return 1
  done
  SRT_FLOOR=$(sed -n 's/^FLOOR=\([0-9][0-9]*\).*/\1/p' "$r/tests/switch-ratchet.bh-2320-test.sh")
  [ -n "$SRT_FLOOR" ] && [ "$SRT_FLOOR" -ge "$k" ] || { echo "srt_tree: cannot read FLOOR >= $k from the suite" >&2; return 1; }
  printf '# srt_tree: the fixture tree sits at the floor\n%s\n' "$((SRT_FLOOR - k))" > "$r/tests/switch-ratchet.d/base.drop"
}

srt_run() { RATCHET_MODE=strict HARNESS_TEST_SANDBOX=1 bash "$1/tests/switch-ratchet.bh-2320-test.sh" 2>&1; }
