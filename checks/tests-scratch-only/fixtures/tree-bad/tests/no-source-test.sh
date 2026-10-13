#!/bin/bash
# R1: a top-level test that never sources the scratch lib at all.
set -uo pipefail
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/x"
