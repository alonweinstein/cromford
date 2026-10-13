#!/bin/bash
# bin/pr-attribution.sh — who built each merged PR of a repo: the harness, a
# merge train, an operator, or a human (BH-4016, child of BH-3987).
#
#   usage:  pr-attribution.sh <owner/repo|project> [YYYY-MM-DD] [--json]
#
# <repo> with a `/` is the slug; anything else is a fleet project, resolved by
# bin/fleet-conf.sh <project> repo. [since] defaults to 30 days before now (UTC)
# and keeps PRs whose merged_at is on or after it. Closed-unmerged PRs are never
# listed.
#
# THE TRAILER FIRST, THE OLD GUESS AS A FLAGGED FALLBACK. Since BH-4014 every
# box and pool build PR carries a Harness-Job / Harness-Ticket (/ Harness-Train)
# block at the foot of its body. bin/lib/pr-trailers.sh's pr_trailers_read is
# the ONLY parser of it here, so the last occurrence wins and a line typed
# higher up in a ticket body never counts. First match wins:
#
#   class      basis      when
#   train      trailer    Harness-Train present
#   harness    trailer    Harness-Job or Harness-Ticket present
#   train?     heuristic  head branch batch/*
#   harness?   heuristic  head branch ticket/*, or the author is in harness_pr_authors
#   operator?  heuristic  head branch lead/*
#   human      heuristic  anything else
#
# A `?` class is a guess off the branch or author, not a fact: PRs older than
# the trailer, or opened by hand, land there.
#
# OUTPUT. TSV: a header, one row per PR (merged_at desc), and a last line
# `# totals harness=N harness?=N train=N train?=N operator?=N human=N`. --json:
# the same rows as a JSON array of objects, `-` as null, no totals line. Both
# are built from one temp file and printed only after every row is classified,
# so a run that fails part way prints nothing.
#
# THE 1000-ROW CAP. The REST list stops at 10 pages of 100, newest-created
# first. When it comes back full and its oldest PR was created on or after
# [since], merges inside the window may be missing: the totals line then ends
# ` truncated=1` and stderr says so. rc stays 0, because every row printed is
# still true.
#
# rc 0   the table (possibly flagged truncated=1)
# rc 2   bad arguments: unknown flag, wrong positional count, a since that is
#        not a real YYYY-MM-DD date, a malformed slug, or an unknown project
# rc 75  the REST read failed (rate limit, 404, network, malformed JSON): one
#        stderr line, empty stdout. A partial list is never printed as the list.
#
# READ-ONLY. It reads the PR list through gh_rest (bin/lib/gh-rest-list.sh) and
# writes nothing of its own: no comment, label, ALERTS line, log line or state
# file. (gh_rest's shared quota ledger and ETag cache record the read, as they
# do for every caller.) The only clock is one `date -u +%s`;
# PR_ATTRIBUTION_NOW (epoch digits) replaces it only under HARNESS_TEST_SANDBOX=1.
set -uo pipefail
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
H="${HARNESS:-/root/harness}"

usage() { echo "usage: pr-attribution.sh <owner/repo|project> [YYYY-MM-DD] [--json]"; }
JSON=0; POS=()
for a in "$@"; do
  case "$a" in
    -h|--help) usage; exit 0 ;;
    --json) JSON=1 ;;
    -?*) usage >&2; exit 2 ;;
    *) POS+=("$a") ;;
  esac
done
if [ "${#POS[@]}" -lt 1 ] || [ "${#POS[@]}" -gt 2 ] || [ -z "${POS[0]}" ]; then usage >&2; exit 2; fi
REPO=${POS[0]}

. "$SELF/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
for l in gh-rest-list gh-app-auth gh-pr-list pr-trailers; do
  # shellcheck source=/dev/null
  . "$SELF/lib/$l.sh" || { echo "pr-attribution: cannot load bin/lib/$l.sh" >&2; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "pr-attribution: jq is required" >&2; exit 1; }

NOW=""
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${PR_ATTRIBUTION_NOW:-} =~ ^[0-9]+$ ]]; then NOW=$PR_ATTRIBUTION_NOW; fi
[ -n "$NOW" ] || NOW=$(date -u +%s)
SINCE=${POS[1]:-$(date -u -d "@$((NOW - 30*86400))" +%F)}
if ! { [ -n "$SINCE" ] && [[ $SINCE =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [ "$(date -u -d "$SINCE" +%F 2>/dev/null)" = "$SINCE" ]; }; then
  echo "pr-attribution: since must be a real YYYY-MM-DD date, got '$SINCE'" >&2; exit 2
fi

case "$REPO" in
  */*) SLUG=$REPO ;;
  *) SLUG=$("$H/bin/fleet-conf.sh" "$REPO" repo 2>/dev/null) || SLUG="" ;;
esac
if [ -z "$SLUG" ] || [ "$SLUG" = - ]; then echo "pr-attribution: unknown project '$REPO'" >&2; exit 2; fi
if ! [[ $SLUG =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then echo "pr-attribution: not an owner/repo slug: '$SLUG'" >&2; exit 2; fi
# Best effort: no App token leaves the ambient credential, and the read decides.
gh_default_auth_for_slug "$SLUG" >/dev/null 2>&1 || true

RAW=$(mktemp "${TMPDIR:-/tmp}/pr-attr.XXXXXX") || exit 1
ROWS=$(mktemp "${TMPDIR:-/tmp}/pr-attr.XXXXXX") || { rm -f "$RAW"; exit 1; }
OUT=$(mktemp "${TMPDIR:-/tmp}/pr-attr.XXXXXX") || { rm -f "$RAW" "$ROWS"; exit 1; }
trap 'rm -f "$RAW" "$ROWS" "$OUT"' EXIT

read_failed() { # read_failed <why>
  echo "pr-attribution: REST read of $SLUG failed (HTTP ${GH_REST_STATUS:-000}, $1); no table printed" >&2
  exit 75 # read-failed
}

RC=0
gh_rest_pr_list_all "$SLUG" closed 1000 > "$RAW" || RC=$?
[ "$RC" = 0 ] || read_failed "${GH_REST_REASON:-rc $RC}"

# One row per kept PR, fields joined by \037 (not a whitespace IFS character,
# so an empty field never collapses into its neighbour on `read`).
jq -r --arg since "$SINCE" '
  map(select(.merged_at != null and .merged_at >= ($since + "T00:00:00Z")))
  | sort_by(.merged_at, .number) | reverse | .[]
  | [(.number | tostring), (.merged_at // "-"), (.user.login // "-"), (.head.ref // "-"), (.html_url // "-"),
     ((.body // "") | @base64)]
  | map(gsub("[\t\n\r\u001f]"; " ")) | join("\u001f")' "$RAW" > "$ROWS" 2>/dev/null \
  || read_failed "malformed JSON"
TRUNC=$(jq -r --arg since "$SINCE" \
  'if length >= 1000 and ((map(.created_at // "") | min) >= ($since + "T00:00:00Z")) then 1 else 0 end' "$RAW" 2>/dev/null) \
  || read_failed "malformed JSON"

printf 'number\tmerged_at\tclass\tbasis\tjob\tticket\tauthor\thead\turl\n' > "$OUT"
while IFS=$'\037' read -r num merged author head url b64; do
  tr=$(printf '%s' "$b64" | base64 -d 2>/dev/null | pr_trailers_read -)
  IFS=$'\037' read -r job ticket train <<< "$(printf '%s' "$tr" | tr '\t' '\037')"
  basis=trailer
  if [ -n "$train" ]; then class=train
  elif [ -n "$job" ] || [ -n "$ticket" ]; then class=harness
  else
    basis=heuristic; job=""; ticket=""
    case "$head" in
      batch/*) class='train?' ;;
      ticket/*) class='harness?' ;;
      *) if harness_pr_author_match "$author"; then class='harness?'
         else case "$head" in lead/*) class='operator?' ;; *) class=human ;; esac; fi ;;
    esac
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$num" "$merged" "$class" "$basis" \
    "${job:--}" "${ticket:--}" "${author:--}" "${head:--}" "${url:--}" >> "$OUT"
done < "$ROWS"

if [ "$JSON" = 1 ]; then
  sed 1d "$OUT" | jq -R 'split("\t") | map(if . == "-" then null else . end)
    | {number: (.[0] | tonumber), merged_at: .[1], class: .[2], basis: .[3], job: .[4],
       ticket: .[5], author: .[6], head: .[7], url: .[8]}' | jq -s . > "$OUT.json" \
    || { rm -f "$OUT.json"; echo "pr-attribution: could not build the JSON output" >&2; exit 1; }
  cat "$OUT.json"; rm -f "$OUT.json"
  exit 0
fi
TOT=$(awk -F'\t' 'NR > 1 { c[$3]++ }
  END { printf "# totals harness=%d harness?=%d train=%d train?=%d operator?=%d human=%d",
        c["harness"], c["harness?"], c["train"], c["train?"], c["operator?"], c["human"] }' "$OUT")
if [ "$TRUNC" = 1 ]; then
  TOT="$TOT truncated=1"
  echo "pr-attribution: the list hit the 1000-PR cap inside the window; older merges since $SINCE may be missing" >&2
fi
printf '%s\n' "$TOT" >> "$OUT"
cat "$OUT"
