# tests/lib/verdict-fixture.sh — the shared verdict reader for a suite that runs
# a lane from a SCRATCH harness or runs an extracted block on its own (BH-1625).
# Sourced, never run. Not a suite: tests/*.sh does not glob tests/lib/.
#
# WHY. Every verdict reader in bin/ now goes through bin/lib/verdict-parse.sh
# (verdict_parse / verdict_is), and a reader that cannot find it reads every
# verdict as unknown — BLOCK, never APPROVE. That is the production contract,
# and it is exactly what a suite that copies a handful of bin/lib files into
# $T/h, or that sources a `# >>> block` of bin/run-build.sh under a bare
# `bash -c`, now sees: every APPROVE fixture reads as a BLOCK. The suite is not
# testing the reader's absence; it is testing the lane.
#
#   vpf_export   source the REAL reader from this checkout into the calling
#                shell, export its functions (export -f) so every child bash —
#                a `bash -c` block runner, a lane script launched from $T/h —
#                inherits them, and export VERDICT_WINDOW_LINES from THIS
#                checkout's registry row (catalog/lanes.d/_lib.json). No
#                literal: the window a scratch harness has no catalog to
#                resolve is the one the fleet's registry declares.
#   vpf_install <harness-root>
#                vpf_export, and also copy the reader into <root>/bin/lib, for
#                a suite whose lane sources it from $HARNESS/bin/lib by path.
# shellcheck shell=bash

VPF_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

vpf_export() {
  local w
  # shellcheck source=bin/lib/verdict-parse.sh
  . "$VPF_REPO/bin/lib/verdict-parse.sh" || return 1
  w=$(jq -r '.libs[]? | select(.id == "verdict-parse") | .knobs[]?
             | select(.env == "VERDICT_WINDOW_LINES") | .default // empty' \
        "$VPF_REPO/catalog/lanes.d/_lib.json" 2>/dev/null)
  [ -n "$w" ] || { echo "verdict-fixture: no VERDICT_WINDOW_LINES row in catalog/lanes.d/_lib.json" >&2; return 1; }
  export VERDICT_WINDOW_LINES="$w" _VP_ROOT
  export -f _vp_is_pos_int verdict_window verdict_parse verdict_is
}

vpf_install() {
  local root="${1:-}"
  [ -n "$root" ] || { echo "verdict-fixture: vpf_install needs a harness root" >&2; return 1; }
  mkdir -p "$root/bin/lib" && cp "$VPF_REPO/bin/lib/verdict-parse.sh" "$root/bin/lib/" || return 1
  vpf_export
}
