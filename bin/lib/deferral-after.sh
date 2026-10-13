# shellcheck shell=bash
# bin/lib/deferral-after.sh — BH-5967: a deferral on an open build is never
# terminal, and it is released by the blocker, not by a count.
#
# WHY. On 2026-10-10, 39 of 95 open cromford tickets sat with no open PR,
# no blocker and no hold, and nothing built them. A pool build that overlapped
# an open PR on a non-splittable file stood down with `BUILD_DEFERRED ...
# After: <KEY> ...`. After JOBS_QUEUE_DEFER_MAX stand-downs the row turned
# FAILED "parked for the blocked-resolver", and the resolver reached about one
# project per 100 minutes (#5913). So the ticket waited after its blocker had
# merged: #5521 and #5888 waited on #5890 (merged 15:19Z), #5788 on #5937
# (merged 17:32Z).
#
# THE RULE. A stand-down that names the build it waits for (`After: <KEY>`) is a
# WAIT, not a failure. bin/fly-pool.sh and bin/jobs-watchdog.sh keep its row
# queued with `after` in the meta, whatever the count. The pool's spawn gate
# then holds the row with no machine until <KEY> has no open PR and nothing in
# flight, and on that tick it re-offers the row with its count reset. A wait on
# the same blocker past DEFER_AFTER_LOOP_ALERT stand-downs pages once.
#
# Defines functions only. Nothing runs on source.

# defer_after_key <text> — print the ticket key a deferral waits for. rc 1 when
# the text names none. Reads `After: <KEY>` anywhere in the text: run-build's
# two shapes are `BUILD_DEFERRED After: <KEY> <why> — ...` and
# `BUILD_DEFERRED <overlap line>; After: <KEY> — ...` (bin/lib/rb/gates.sh).
defer_after_key() {
  local t="${1:-}" k
  k=$(printf '%s' "$t" | grep -oE 'After: [A-Z][A-Z0-9]*-[0-9]+(\.[0-9]+)*' | head -n 1)
  k="${k#After: }"
  [ -n "$k" ] || return 1
  printf '%s' "$k"
}

# defer_after_loop_n — DEFER_AFTER_LOOP_ALERT, validated (default 12, 0 = off).
defer_after_loop_n() {
  local v="${DEFER_AFTER_LOOP_ALERT:-12}"
  case "$v" in ''|*[!0-9]*) v=12 ;; esac
  printf '%s' "$v"
}
