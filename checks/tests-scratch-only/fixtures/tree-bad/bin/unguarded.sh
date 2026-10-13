#!/bin/bash
# R3: deletes a $HARNESS-derived directory with no prefix guard.
set -uo pipefail
X="$1"
PLANDIR="$HARNESS/plans/$X"
[ -s "$PLANDIR/plan.md" ] || rm -rf "$PLANDIR"
