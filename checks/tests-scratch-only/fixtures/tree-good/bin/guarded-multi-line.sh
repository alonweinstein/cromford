#!/bin/bash
# The same guard written across lines, keyed on $H instead of $HARNESS.
set -uo pipefail
D="$H/plans/$1"
case "$D" in
  "$H"/plans/*) rm -rf "$D" ;;
  *) exit 1 ;;
esac
