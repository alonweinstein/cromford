#!/bin/bash
# The bin/run-build.sh:1177 shape — a prefix guard on the same line.
set -uo pipefail
PLANDIR="$HARNESS/plans/$PROJECT-$KEY"
case "$PLANDIR" in "$HARNESS/plans/"*) rm -rf "$PLANDIR" ;; esac
