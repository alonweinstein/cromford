#!/bin/bash
# A mktemp-owned working dir: nothing here is $HARNESS-derived.
set -uo pipefail
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
