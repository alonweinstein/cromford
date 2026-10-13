#!/bin/bash
# bin/lib/mc-prequeue.d/invariants.sh — THE HUB CARRIES THE INVARIANT OVERRIDE
# ROWS TO THE PRE-QUEUE GATE (BH-5440, #5429 child 2). Sourced by
# bin/lib/mc-prequeue.sh's hook loop, never executed; no side effect at source time.
#
# pq_invariants_args prints `-f invariants=<id=off|n,...>` from the hub's
# `conf.prequeue-invariants.*` settings rows (bin/prequeue-invariants.sh
# --overrides --harness $MC_H), or nothing. pq_dispatch calls it only when
# suites is empty and word-splits the output into the gh argv. No script in
# MC_H, no row, a failure, or output that is not the strict list: nothing, so
# the dispatch goes out exactly as before and no path or space reaches the argv.
pq_invariants_args() {
  local s="${MC_H:-}/bin/prequeue-invariants.sh" v
  [ -n "${MC_H:-}" ] && [ -r "$s" ] || return 0
  v=$(bash "$s" --overrides --harness "$MC_H" 2>/dev/null) || return 0
  [[ $v =~ ^[a-z0-9-]+=(off|[0-9]+)(,[a-z0-9-]+=(off|[0-9]+))*$ ]] || return 0
  printf '%s %s\n' -f "invariants=$v"
}
