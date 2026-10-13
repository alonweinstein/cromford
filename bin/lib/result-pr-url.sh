#!/bin/bash
# bin/lib/result-pr-url.sh — WHICH URL ON A BUILD RECORD IS THIS RECORD'S OWN PR.
# Sourced, never executed.
#
#   result_own_pr_url <RESULT file>    -> the PR THIS build opened: line 1's
#                                        `PR_CREATED <url>`, else the first
#                                        `PR: <url>` line. Never a PARENT_PR:
#                                        line, never a url that merely appears
#                                        in a note. Nothing + rc 1 when there is
#                                        no such PR.
#   result_parent_pr_url <RESULT file> -> the PARENT's PR for a stacked build:
#                                        a `PARENT_PR: <url>` line, else the
#                                        `STACKED on <branch> (<parent>)` note on
#                                        line 1, in either its raw form or the
#                                        redacted `(owner/repo PR N)` form the
#                                        RESULT ratchet writes.
#
# WHY (BH-848, 2026-09-18). Three readers of a multi-line pool record —
# fly/builder-runner.sh, bin/fly-results-ingest.sh and bin/fly-pool.sh — each ran
#   grep -oE 'https://github.com/[^ ]+/pull/[0-9]+' RESULT | head -1
# THE FIRST URL ON THE RECORD IS NOT THE RECORD'S PR. When `gh pr create` died on
# the App GraphQL cap, bin/run-build.sh's ratchet folded the caller's notes into
# the failed line, and for a stacked child those notes carry the PARENT's URL:
#   PR_CREATE_FAILED: … carrying ' | STACKED on ticket/bh-776 (…/pull/803)'
# so the record was published as `PR: …/pull/803` and the merge sweep evaluated
# somebody else's PR. Two records did exactly this (BH-776 -> #803, BH-550 ->
# #754). A mislink is worse than a missing link: it looks answered.
#
# The ratchet now redacts pull URLs out of the failed line, so the raw shape
# should not be written again — but records already on disk carry it, and an
# older builder on a box mid-propagation still writes it. Both shapes are
# handled here, and NEITHER is ever read as the record's own PR.
[ -n "${_RPU_LOADED:-}" ] && return 0
_RPU_LOADED=1

result_own_pr_url() { # result_own_pr_url <RESULT file>
  local f="${1:-}" url
  [ -r "$f" ] || return 1
  # Line 1 is the claim every single-line reader in the fleet keys on, and a
  # reconciled record's line 1 is `PR_CREATED <url> | RECONCILED …`.
  url=$(head -n 1 "$f" | sed -nE 's#^PR_CREATED (https://github\.com/[^ ]+/pull/[0-9]+).*#\1#p' | head -n 1)
  [ -n "$url" ] || url=$(sed -nE 's#^PR: (https://github\.com/[^ ]+/pull/[0-9]+).*#\1#p' "$f" | head -n 1)
  [ -n "$url" ] || return 1
  printf '%s\n' "$url"
}

result_parent_pr_url() { # result_parent_pr_url <RESULT file>
  local f="${1:-}" url l1 owner num
  [ -r "$f" ] || return 1
  l1=$(head -n 1 "$f")
  url=$(sed -nE 's#^PARENT_PR: (https://github\.com/[^ ]+/pull/[0-9]+).*#\1#p' "$f" | head -n 1)
  [ -n "$url" ] || \
    url=$(sed -nE 's#.*STACKED on [^ ]+ \((https://github\.com/[^ ]+/pull/[0-9]+)\).*#\1#p' <<<"$l1" | head -n 1)
  if [ -z "$url" ]; then
    # The redacted form the ratchet writes: `STACKED on ticket/x (owner/repo PR 803)`.
    owner=$(sed -nE 's#.*STACKED on [^ ]+ \(([^/ ]+/[^/ ]+) PR ([0-9]+)\).*#\1#p' <<<"$l1" | head -n 1)
    num=$(sed -nE 's#.*STACKED on [^ ]+ \(([^/ ]+/[^/ ]+) PR ([0-9]+)\).*#\2#p' <<<"$l1" | head -n 1)
    [ -n "$owner" ] && [ -n "$num" ] && url="https://github.com/$owner/pull/$num"
  fi
  [ -n "$url" ] || return 1
  printf '%s\n' "$url"
}
