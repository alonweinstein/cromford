#!/bin/bash
# bin/mergify-queue-time.sh — how long the last N merged PRs of a repo sat in the
# merge queue, read over GitHub REST (BH-1673.3). Operator-invoked; no cron lane.
#
#   bin/mergify-queue-time.sh <owner/repo> [--last N]      N defaults to 20
#
# stdout, one TSV row per merged PR, newest merged_at first:
#   pr  queued_at  merged_at  minutes  source
# source is `queued` (Mergify's own label), `merge-queue` (ours, the fallback),
# `none` (never queued: queued_at and minutes are `-`) or `error` (its events
# read failed: `-` too, and it counts as neither measured nor unqueued).
# Then one summary line:
#   median_minutes=<x|none> measured=<k> unqueued=<u> wanted=<N> incomplete=<0|1>
# incomplete=1 means do not trust the median as final: fewer than N merged PRs
# were on the one pulls page read, an events read failed, or a PR's events page
# was full (100) and may be truncated.
#
#   rc 0   a completed run, including incomplete=1
#   rc 75  UNVERIFIABLE — the pulls read failed or was unparseable, or any read
#          was rate limited. Prints nothing at all.
#   rc 2   usage
#
# queued_at is the LAST `labeled` event at or before merged_at whose label is
# exactly `queued`; only when there is none, the last such `merge-queue` event.
# The harness holds no Mergify credential, so this never calls Mergify's API.
#
# A FAILED READ IS NEVER "NO LABEL". An events read that failed returned no
# labeled events, which is exactly what a never-queued PR looks like; counting
# it as unqueued would move the median and the unqueued count on a read we
# never got (#768). Driven by tests/mergify-queue-time.bh-1700-test.sh.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
LIB="$HARNESS/bin/lib"
[ -r "$LIB/gh-rest.sh" ] || LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
. "$LIB/gh-rest.sh" || exit 75
. "$LIB/gh-app-auth.sh" 2>/dev/null || true

# Protocol names, not business parameters: Mergify's queue label and the label
# this harness put on queued PRs before Mergify.
LABEL_QUEUED=queued
LABEL_FALLBACK=merge-queue
PER_PAGE=100

usage() { echo "usage: $0 <owner/repo> [--last N]" >&2; exit 2; }

SLUG=""; LASTN=20
while [ $# -gt 0 ]; do
  case "$1" in
    --last) [ $# -ge 2 ] || usage; LASTN="$2"; shift 2 ;;
    -*) usage ;;
    *) [ -z "$SLUG" ] || usage; SLUG="$1"; shift ;;
  esac
done
[[ "$SLUG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage
[[ "$LASTN" =~ ^[1-9][0-9]*$ ]] || usage

command -v gh_default_auth_for_slug >/dev/null 2>&1 && gh_default_auth_for_slug "$SLUG" || true

W=$(mktemp -d "${TMPDIR:-/tmp}/mergify-queue-time.XXXXXX") || exit 75
trap 'rm -rf "$W"' EXIT

# Through a FILE and never `$( )`, so GH_REST_REASON survives into this shell.
rc=0
gh_rest GET "repos/$SLUG/pulls?state=closed&sort=updated&direction=desc&per_page=$PER_PAGE" > "$W/pulls" || rc=$?
[ "$rc" = 0 ] || exit 75
jq -r --argjson n "$LASTN" \
  'if type != "array" then error("not a list") else . end
   | [.[] | select(.merged_at != null)] | sort_by(.merged_at | fromdateiso8601) | reverse | .[:$n][]
   | "\(.number)\t\(.merged_at)"' "$W/pulls" > "$W/merged" 2>/dev/null || exit 75

incomplete=0; measured=0; unqueued=0
[ "$(grep -c . "$W/merged")" -lt "$LASTN" ] && incomplete=1
: > "$W/rows"; : > "$W/minutes"
while IFS=$'\t' read -r num merged; do
  erc=0
  gh_rest GET "repos/$SLUG/issues/$num/events?per_page=$PER_PAGE" > "$W/ev" < /dev/null || erc=$?
  if [ "$erc" != 0 ] && [ "$GH_REST_REASON" = rate-limit ]; then exit 75; fi
  ans=""
  [ "$erc" = 0 ] && ans=$(jq -r --arg m "$merged" --arg q "$LABEL_QUEUED" --arg f "$LABEL_FALLBACK" --argjson pp "$PER_PAGE" '
      if type != "array" then error("not a list") else . end
      | (length >= $pp) as $full
      | ($m | fromdateiso8601) as $mt
      | [.[] | select(.event == "labeled" and .created_at != null)
             | select((.created_at | fromdateiso8601) <= $mt)]
      | sort_by(.created_at | fromdateiso8601) as $l
      | (([$l[] | select(.label.name == $q)] | last | if . then {s: $q, e: .} else null end)
         // ([$l[] | select(.label.name == $f)] | last | if . then {s: $f, e: .} else null end)) as $hit
      | (if $full then "full" else "ok" end) + "\t"
        + (if $hit then "\($hit.s)\t\($hit.e.created_at)\t\(($mt - ($hit.e.created_at | fromdateiso8601)) / 60)"
           else "none\t-\t-" end)' "$W/ev" 2>/dev/null) || ans=""
  if [ -z "$ans" ]; then
    # The failed-read arm: flag it, name the PR, count it as nothing.
    incomplete=1
    printf '%s\t-\t%s\t-\terror\n' "$num" "$merged" >> "$W/rows"
    continue
  fi
  IFS=$'\t' read -r page src qat mins <<<"$ans"
  [ "$page" = full ] && incomplete=1
  if [ "$src" = none ]; then
    unqueued=$((unqueued+1))
    printf '%s\t-\t%s\t-\tnone\n' "$num" "$merged" >> "$W/rows"
  else
    measured=$((measured+1))
    printf '%s\n' "$mins" >> "$W/minutes"
    printf '%s\t%s\t%s\t%s\t%s\n' "$num" "$qat" "$merged" "$(jq -n --argjson x "$mins" '($x * 10 | round) / 10')" "$src" >> "$W/rows"
  fi
done < "$W/merged"

median=$(jq -s -r 'sort | length as $k
  | if $k == 0 then "none"
    else (if $k % 2 == 1 then .[($k - 1) / 2] else (.[$k / 2 - 1] + .[$k / 2]) / 2 end)
         | (. * 10 | round) / 10 | tostring end' "$W/minutes") || exit 75
cat "$W/rows"
echo "median_minutes=$median measured=$measured unqueued=$unqueued wanted=$LASTN incomplete=$incomplete"
exit 0
