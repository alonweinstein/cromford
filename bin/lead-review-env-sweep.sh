#!/bin/bash
# bin/lead-review-env-sweep.sh [--apply] [--repo <owner/name>] — BH-5793: the
# one-time sweep that supersedes lead BLOCKs whose findings are environment
# failures only, and asks for a re-review of each.
#
# WHY. Before BH-5793 a rules pack that failed on its own environment (a suite
# the PR head did not carry, a suite's scratch repo that would not set up)
# landed as a BLOCK with no model call. Those BLOCKs still stand on open PRs.
# From BH-5793 on, the review lane fails such a request instead
# (bin/lead-review.sh) and bin/lead-review-land.sh requeues it; this script
# clears the ones written before the fix.
#
# WHAT IT DOES, per lead review request that is `done` with verdict BLOCK:
#   1. reads the report (the lead_review_report artifact of the request's job)
#      and its `- [BLOCK]` findings;
#   2. keeps it when any finding is real (bin/lib/review-env-fail.sh decides);
#   3. skips it when the report cannot be read, the PR is no longer open at
#      that head (a BLOCK on a dead head blocks nothing), or the ledger already
#      holds lead_block_env_superseded for it;
#   4. with --apply: the ledger row lead_block_env_superseded
#      "<repo>#<pr>@<head>" = superseded <request-id> FIRST, then
#      POST /api/lead-reviews/<id>/reset (lead token), which sends the request
#      back to `requested`. The lead-review lane then reviews that head again,
#      and lead-review-land lands the new verdict over the BLOCK.
# Without --apply nothing is written; each candidate prints would-supersede.
#
# OUTPUT, one line per BLOCK request:
#   superseded|would-supersede <id> <repo>#<pr> <head12>
#   kept <id> <repo>#<pr> <head12> (a real finding)
#   skipped <id> <repo>#<pr> <head12> (<why>)
# exit 0 done (whatever the lines say) | 1 the request list could not be read
#   | 2 usage. Run on the hub: the reset needs the lead token.
set -uo pipefail
H="${HARNESS:-$(cd "$(dirname "$0")/.." && pwd)}"
APPLY=0 REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --repo) [ $# -ge 2 ] || { echo "usage: $0 [--apply] [--repo owner/name]" >&2; exit 2; }; REPO="$2"; shift ;;
    *) echo "usage: $0 [--apply] [--repo owner/name]" >&2; exit 2 ;;
  esac
  shift
done
[ -z "$REPO" ] || [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "--repo must be owner/name" >&2; exit 2; }

# shellcheck source=bin/jobs-client.sh
. "$H/bin/jobs-client.sh" || { echo "lead-review-env-sweep: bin/jobs-client.sh did not load" >&2; exit 1; }
# shellcheck source=bin/lib/lead-reviews.sh
. "$H/bin/lib/lead-reviews.sh" || { echo "lead-review-env-sweep: bin/lib/lead-reviews.sh did not load" >&2; exit 1; }
# shellcheck source=bin/lib/review-env-fail.sh
. "$H/bin/lib/review-env-fail.sh" || { echo "lead-review-env-sweep: bin/lib/review-env-fail.sh did not load" >&2; exit 1; }
# shellcheck source=bin/lib/gh-rest.sh
. "$H/bin/lib/gh-rest.sh" 2>/dev/null || true

W=$(mktemp -d "${TMPDIR:-/tmp}/lead-review-env-sweep.XXXXXX") || { echo "lead-review-env-sweep: cannot make a work dir" >&2; exit 1; }
trap 'rm -rf "$W"' EXIT

lr_get "?status=done${REPO:+&repo=$REPO}" > "$W/list.json" 2>/dev/null \
  || { echo "lead-review-env-sweep: the lead review list could not be read" >&2; exit 1; }
[ "$(jq -r '.truncated // false' "$W/list.json" 2>/dev/null)" = true ] \
  && echo "lead-review-env-sweep: the list is truncated; run again with --repo to reach the rest" >&2

while IFS=$'\t' read -r id repo pr head job; do
  [ -n "$id" ] || continue
  at="$id $repo#$pr ${head:0:12}"
  # 3. the report
  if [ -z "$job" ] || ! job_artifact_detail lead_review_report "$job" > "$W/art.json" 2>/dev/null; then
    echo "skipped $at (the report could not be read)"; continue
  fi
  jq -r 'if (.body | type) == "string" then .body else empty end' "$W/art.json" 2>/dev/null \
    | sed -n 's/^- \[BLOCK\][[:space:]]*//p' > "$W/findings"
  if ! grep -q '[^[:space:]]' "$W/findings"; then echo "skipped $at (the report has no BLOCK finding line)"; continue; fi
  # 2. a real finding keeps the BLOCK
  if ! rev_env_only "$W/findings"; then echo "kept $at (a real finding)"; continue; fi
  key="$repo#$pr@$head"
  rc=0; job_ledger_row lead_block_env_superseded "$key" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) echo "skipped $at (already superseded)"; continue ;;
    2) ;;
    *) echo "skipped $at (the ledger could not be read)"; continue ;;
  esac
  # A BLOCK on a head the PR has left, or on a closed PR, blocks nothing. With
  # no gh-rest.sh that cannot be checked, so nothing is superseded on a guess.
  # gh_rest_var, not $(gh_rest …): a subshell loses the quota ledger and the
  # status the helper records (tests/gh-rest-no-subshell-lint.sh).
  command -v gh_rest_var >/dev/null 2>&1 || { echo "skipped $at (bin/lib/gh-rest.sh not loaded: the PR state cannot be checked)"; continue; }
  pj=""; gh_rest_var pj GET "repos/$repo/pulls/$pr" 2>/dev/null || { echo "skipped $at (the PR could not be read)"; continue; }
  [ "$(jq -r '.state // ""' <<<"$pj")" = open ] || { echo "skipped $at (the PR is not open)"; continue; }
  [ "$(jq -r '.head.sha // ""' <<<"$pj")" = "$head" ] || { echo "skipped $at (the PR head moved)"; continue; }
  if [ "$APPLY" != 1 ]; then echo "would-supersede $at"; continue; fi
  # 4. ledger row first, then the re-review
  job_ledger_put lead_block_env_superseded "$key" superseded "$id" >/dev/null 2>&1 \
    || { echo "skipped $at (the ledger row could not be written)"; continue; }
  if lr_post_lead "/$id/reset" '{}' >/dev/null 2>&1; then echo "superseded $at"
  else echo "skipped $at (superseded in the ledger, but the reset was refused: bin/lead-verdict.sh reset $id)"; fi
done < <(jq -r '.requests[]? | select(.status == "done" and .verdict == "BLOCK")
                | [.id, .repo, (.pr|tostring), .head_sha, (.job_id // "")] | @tsv' "$W/list.json" 2>/dev/null)
exit 0
