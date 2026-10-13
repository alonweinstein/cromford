#!/bin/bash
# R2: sources the lib first, then wipes a path the lib never handed out.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh"
H="${HARNESS_FIXTURE:-/dev/null/no-such-harness}"
mkdir -p "$H/state"
trap 'rm -rf "$H"' EXIT
# INERT, two ways: the stub lib above exits on source, so nothing below it runs;
# and the default target sits under /dev/null, which is not a directory, so even
# a bypassed stub cannot mkdir or delete a real harness. This is the #388 SHAPE
# and R2 keys on the NAME $H on line 7, never on the value, so the seeded hit is
# byte-identical to the one this fixture shipped with.
