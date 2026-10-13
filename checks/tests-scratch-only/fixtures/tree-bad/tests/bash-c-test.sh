#!/bin/bash
# R2: sources the lib first, then shells out to delete a positional argument.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh"
mkdir -p "$T/calls"
bash -c 'rm -rf "$1/calls"' _ "$T"
# INERT: the stub lib exits on source, so nothing below line 4 runs; and under
# set -u a bypassed stub leaves $T unbound, which stops the shell before the rm.
