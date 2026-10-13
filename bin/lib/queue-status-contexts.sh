#!/bin/bash
# bin/lib/queue-status-contexts.sh — the commit STATUS contexts the queue
# readers skip (BH-5441). Sourced, never executed.
#
# A `check-success=<name>` condition in .mergify.yml matches a commit status on
# the PR head as well as a check run. The harness publishes two such statuses:
# `lead-verdict` (bin/lib/verdict-status.sh, LEAD_VERDICT_CONTEXT overrides it)
# and `prequeue-verdict` (bin/lib/mc-prequeue.d/status.sh). Neither is a check
# run, so autoenqueue G4 (_ae_required_checks) and the stuck-batch pass
# (mc_mergify_required_checks) must not wait for one. Both read this list.

# qsc_list — one context per line: the lead-verdict context in force, then
#   prequeue-verdict unless it is the same name.
qsc_list() {
  local lv
  lv=$(command -v vs_context >/dev/null 2>&1 && vs_context || echo "${LEAD_VERDICT_CONTEXT:-lead-verdict}")
  printf '%s\n' "$lv"
  [ "$lv" = prequeue-verdict ] || printf '%s\n' prequeue-verdict
}
