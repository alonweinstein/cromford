# tests/lib/br-modules.sh — install bin/lib/br/ into a fixture's scratch harness.
# Sourced by the suites that put a copy of bin/blocked-resolver.sh in a scratch
# tree and run it, never executed. Not a suite: tests/*.sh does not glob
# tests/lib/.
#
# WHY IT IS A LIB AND NOT A LINE PER FIXTURE (BH-1176). The lane sources its
# modules out of $HARNESS/bin/lib/br and REFUSES the tick when one is missing,
# which is the whole point of the loop — so a fixture that copies the script without the
# modules gets rc 1 and an ALERTS line instead of the behaviour it is asserting
# on. Twelve suites do that copy. The split has four more slices to land and the
# layout will move again; when it does, this is the one edit rather than twelve.
# shellcheck shell=bash

br_modules_install() { # br_modules_install <repo-dir> <scratch-harness-root>
  mkdir -p "$2/bin/lib/br" || return 1
  cp "$1"/bin/lib/br/*.sh "$2/bin/lib/br/" || return 1
  # THE PUSH TRAVELS WITH THE LANE (BH-2504): the fix round pushes only through
  # bin/lib/hold-push.sh, which reads the ticket through bin/lib/hold.sh, and a
  # copy without them can never push. The ticket read is answered by
  # tests/lib/gh-rest-stub.sh (an unheld FIXTURE issue unless the suite writes
  # $GHT/issue-<n>.json / comments-<n>.json).
  # A suite that STUBS hold.sh keeps its stub: only an absent one is filled in.
  cp "$1/bin/lib/hold-push.sh" "$2/bin/lib/" || return 1
  [ -e "$2/bin/lib/hold.sh" ] || cp "$1/bin/lib/hold.sh" "$2/bin/lib/" || return 1
}
