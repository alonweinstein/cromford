#!/bin/bash
# R1: sources the lib, but only AFTER it has already made its own scratch dir.
set -uo pipefail
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
. "$(dirname "$0")/lib/scratch.sh"
mkdir -p "$T/y"
