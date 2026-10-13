#!/bin/bash
# bin/lib/mc/snapshot-refs.sh — BH-4659 (BH-4656.1): loads prs_branch_tip
# (bin/lib/pr-snapshot-refs.sh) for head_lag_tip and mc_branch_exists in
# mc/rebase.sh. Sourced by bin/lib/merge-conductor-lib.sh, never executed.
#
# Sourced AFTER the shim's $MC_H lines, not in the module loop: the refs lib
# pulls in pr-snapshot.sh and gh-rest-list.sh, and loading them first would
# define gh_rest from this checkout before the shim's $MC_H gh-rest.sh guard
# runs. Optional: every caller checks `command -v prs_branch_tip`, and a miss
# probes live.
command -v prs_branch_tip >/dev/null 2>&1 \
  || { [ -r "${BASH_SOURCE[0]%/*}/../pr-snapshot-refs.sh" ] && . "${BASH_SOURCE[0]%/*}/../pr-snapshot-refs.sh"; }
return 0
