#!/bin/bash
# shellcheck shell=bash
# bin/lib/review-env-fail.sh — BH-5793: is a review finding an ENVIRONMENT
# failure? Sourced by bin/lead-review.sh, bin/lead-review-env-sweep.sh and the
# tests; never run.
#
# WHY. A review lane that could not do its work is not a reviewer that found a
# fault. On 2026-10-07 the rules pack BLOCKed PRs whose head simply did not
# carry a suite the pack names (48 findings in the 300-PR analysis), and others
# on "repo setup failed" in a suite's own scratch repo (13). No model read the
# code, the PR sat blocked, and a fix round had nothing to fix. An environment
# failure is review-failed and retried, never a BLOCK.
#
# A line is an environment failure when it says the review could not set up or
# run, not that the code is wrong:
#   repo setup failed            a suite's scratch git repo could not be built
#   suite missing at the PR head the pack names a suite the head does not carry
#   tests/<x>: No such file      the same, as bash reports it
#   base <ref> does not resolve  a base or snapshot ref the runner cannot read
#                                (bin/rules-pack.sh's own wording; a bare
#                                "does not resolve" can end a real finding)
#   cannot make a work dir       mktemp refused
#   refusing … SCRATCH / live harness   a scratch guard refused the runner
# Anything else is a real finding. A timeout, a model error and an empty model
# answer never reach a finding line: the rules pack marks a timed-out component
# could-not-run (rc 124), and bin/lead-review.sh handles a model that gave no
# verdict on its own path (review-failed, never BLOCK). The list is short on
# purpose: a pattern that matched a real failure would hide a bug, so a new
# shape is added here with a test, never guessed.

REV_ENV_RE='repo setup failed|suite missing at the PR head|(^|[ :])(bash: )?tests/[^ :]+: No such file or directory|base [^ ]+ does not resolve|cannot make a work dir|refusing (path|dest) outside SCRATCH|refusing to run as root next to live harness'

# rev_env_line <line> — rc 0 when the line is an environment failure.
rev_env_line() { [[ "${1:-}" =~ $REV_ENV_RE ]]; }

# rev_env_split <in> <real-out> <env-out> — every non-blank line of <in> goes to
# <env-out> when it is an environment failure, else to <real-out>.
# rc 0 written | 1 <in> unreadable.
rev_env_split() {
  local line
  [ -r "${1:-}" ] || return 1
  : > "$2"; : > "$3"
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ [^[:space:]] ]] || continue
    if rev_env_line "$line"; then printf '%s\n' "$line" >> "$3"; else printf '%s\n' "$line" >> "$2"; fi
  done < "$1"
  return 0
}

# rev_env_only <file> — rc 0 when the file has at least one non-blank line and
# every non-blank line is an environment failure. rc 1 otherwise (a real
# finding, an empty file, or an unreadable one).
rev_env_only() {
  local line n=0
  [ -r "${1:-}" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ [^[:space:]] ]] || continue
    rev_env_line "$line" || return 1
    n=$((n + 1))
  done < "$1"
  [ "$n" -gt 0 ]
}
