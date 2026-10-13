#!/bin/bash
# bin/always-eject-report.sh — BH-3865 (BH-3860.4): batch ejections per UTC day
# caused by an always-suite, read from the dequeue-watch event rows.
#
# Why: four Mergify batches on 2026-10-01/02 were ejected by always-suites that
# take seconds but only ran in the batch (#3860). BH-3860 moves the fast ones
# into the PR lint job; this report is the before/after number. It is a
# read-only operator CLI: no cron line, no write anywhere.
#
# Usage: bin/always-eject-report.sh [--since YYYY-MM-DD] [--until YYYY-MM-DD]
#                                   [--repo example-org/cromford]
#   --until defaults to today (UTC), --since to six days before it. Both are
#   inclusive UTC days of the row's created_at. The worker filters since; until
#   is applied here, because the route has no until filter.
#
# stdout: TSV `day dequeues by_always_suite by_fast_suite prs`, one row per day.
#   dequeues counts every event; the two by_ columns count events whose class is
#   rule-break or semantic-test and whose suites name a suite in the current
#   `bin/test-impact.sh always` / `bin/fast-lints.sh --list` set; prs lists the
#   by_always events' PRs, or `-`.
#
# rc:
#   0  report printed
#   1  the jobs client, the always or fast set, or the dequeue-watch rows
#      unreadable; stdout empty
#   2  bad arguments (usage on stderr)
#   3  the read worked and no row is in the window; stdout empty
#   4  the worker capped the list: rows printed, then `# truncated` (partial is
#      not a number; narrow the window)
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }

usage() {
  echo "usage: always-eject-report.sh [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--repo OWNER/NAME]" >&2
  exit "${1:-2}"
}
die() { echo "always-eject-report: $1" >&2; exit "${2:-1}"; }
# day <value>: a real calendar date in YYYY-MM-DD form.
day() { [ -n "$1" ] && [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [ "$(date -u -d "$1" +%F 2>/dev/null)" = "$1" ]; }

# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$SELF/lib/deployment.sh}" || die "bin/lib/deployment.sh unavailable" 2  # BH-4080: HARNESS_REPO
since="" until="" repo="$HARNESS_REPO"
while [ $# -gt 0 ]; do
  case "$1" in
    --since) [ $# -ge 2 ] || usage; since=$2; shift 2 ;;
    --until) [ $# -ge 2 ] || usage; until=$2; shift 2 ;;
    --repo)  [ $# -ge 2 ] && [ -n "$2" ] || usage; repo=$2; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "always-eject-report: unknown argument '$1'" >&2; usage ;;
  esac
done
[ -n "$until" ] || until=$(date -u +%F)
day "$until" || { echo "always-eject-report: bad --until '$until'" >&2; usage; }
[ -n "$since" ] || since=$(date -u -d "$until -6 days" +%F)
day "$since" || { echo "always-eject-report: bad --since '$since'" >&2; usage; }
[[ "$since" > "$until" ]] && { echo "always-eject-report: --since $since is after --until $until" >&2; usage; }

# shellcheck disable=SC1091
. "$SELF/jobs-client.sh" 2>/dev/null || die "jobs client unavailable"

TMP=$(mktemp -d) || die "mktemp failed"
trap 'rm -rf "$TMP"' EXIT

# Both sets are read before the network call: an unreadable set is rc 1, never
# a column of zeros.
{ "$SELF/test-impact.sh" always > "$TMP/always" 2>/dev/null && [ -s "$TMP/always" ]; } \
  || die "always-suite set unavailable"
# An empty fast list with rc 0 is a real answer (no always-suite is fast).
"$SELF/fast-lints.sh" --list > "$TMP/fast" 2>/dev/null || die "fast-lint set unavailable"

if ! dqw_events_list "$repo" "" "${since}T00:00:00Z" > "$TMP/rows.json" \
  || ! jq -e '(.rows|type) == "array" and (.truncated|type) == "boolean"' "$TMP/rows.json" >/dev/null 2>&1; then
  die "dequeue-watch rows unreadable"
fi

jq -r --arg until "$until" --rawfile always "$TMP/always" --rawfile fast "$TMP/fast" '
  def set($s): $s | split("\n") | map(select(. != ""));
  def toks: (.suites // "") as $s
    | (try ($s | fromjson) catch null) as $j
    | (if ($j|type) == "array" then $j | map(tostring) else ($s | tostring | [splits("[\\s,]+")]) end)
    | map(select(. != ""));
  def hits($set): (.class == "rule-break" or .class == "semantic-test")
    and (toks | any(. as $t | $set | index([$t]) != null));
  set($always) as $A | set($fast) as $F
  | [.rows[] | select((.created_at // "")[0:10] as $d | $d != "" and $d <= $until)]
  | group_by(.created_at[0:10])[]
  | [ .[0].created_at[0:10], length,
      (map(select(hits($A))) | length),
      (map(select(hits($F))) | length),
      (map(select(hits($A)) | .pr) | unique | map("#\(.)") | join(",") | if . == "" then "-" else . end) ]
  | @tsv' "$TMP/rows.json" > "$TMP/days" || die "dequeue-watch rows unreadable"

truncated=$(jq -r '.truncated' "$TMP/rows.json")
if [ ! -s "$TMP/days" ] && [ "$truncated" != true ]; then
  echo "no dequeue-watch rows in $since..$until (the dequeue-watch lane may not be writing yet, PR #3833)" >&2
  exit 3
fi
printf 'day\tdequeues\tby_always_suite\tby_fast_suite\tprs\n'
cat "$TMP/days"
[ "$truncated" = true ] && { echo "# truncated"; exit 4; }
exit 0
