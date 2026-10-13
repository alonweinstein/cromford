#!/bin/bash
# R3: deletes a textual $HARNESS path.
set -uo pipefail
X="$1"
rm -rf "$HARNESS/builds/$X"
