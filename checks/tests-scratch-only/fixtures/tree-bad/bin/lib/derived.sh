#!/bin/bash
# R3: the target comes back from a function the file hands $HARNESS to.
set -uo pipefail
D=$(preplan_dir "$HARNESS" "$1" "$2")
rm -rf "$D"
