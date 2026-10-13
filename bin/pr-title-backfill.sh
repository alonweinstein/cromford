#!/bin/bash
# bin/pr-title-backfill.sh — retitle the OPEN PRs still carrying the BH-1415
# defect shape, one REST PATCH each.
#
# WHAT THE SHAPE IS. Until BH-1415 the PR-open step took its title from
# `git log -1 --format=%s`, and the spec artifact stage commits
# `spec(<KEY>): the plan this build was executed from` after execute — so HEAD
# was that commit and the PR was opened as
# `BH-<n>: spec(BH-<n>): the plan this build was executed from`. The 2026-09-22
# pool wave produced 33 of them; the review and merge lanes list PRs by title and
# every one of them read the same. bin/run-build.sh no longer composes that
# title. This script is the one-off half: it fixes the PRs already open.
#
#   pr-title-backfill.sh [--apply] <slug> <pr-number>...
#   pr-title-backfill.sh [--apply] --all-open <slug>
#
# DRY RUN IS THE DEFAULT. Without --apply it performs the two reads per PR and
# prints what it WOULD write; it never issues a PATCH. It is operator-invoked —
# no cron line, no lane, no lock, no state — and its own matcher is the
# idempotency key: a PR it has retitled no longer matches the shape, so a second
# run over the same list writes nothing.
#
# THE ORDER IS READ-THEN-WRITE, NEVER THE REVERSE. The issue title is fetched
# BEFORE the PATCH, and a failed or empty issue read skips the PR with no write,
# so a title derived from a failure is impossible by construction. Success is
# claimed only when the PATCH's own response body reads back the exact title
# that was sent.
#
# WHAT IT REFUSES TO TOUCH (every one of these is a PR somebody may be reading):
#   * anything whose state is not `open`;
#   * a title that does not carry the same key on both sides of `: spec(…): `,
#     so an ordinary `BH-<n>: <subject>` title, a subject that merely contains
#     the word "spec", a bare `spec(BH-<n>): …` with no key prefix, and a
#     `BH-1400: spec(BH-1399): …` whose two keys disagree are all left alone;
#   * a PR whose issue cannot be read, or whose issue title is empty;
#   * an issue title that is ITSELF the spec shape — the rule would otherwise
#     produce the defect it exists to remove.
#
# Exit codes: 0 = every PR handled (retitled, would-retitle, or deliberately
# skipped), 1 = at least one PATCH failed or did not read back, 3 = unusable
# arguments, no `gh`, or an unreadable open-PR list — nothing was requested.
#
# IRON GUARDRAIL 1: this script never merges, never pushes, never closes. The
# only write it makes is a PR title.
set -uo pipefail

SELF=$(basename "$0")
BIN=$(cd "$(dirname "$0")" && pwd)
# The entry point owns the root default (BH-2613 rule 4): the libs below have none.
H="${HARNESS:-${H:-/root/harness}}"
# shellcheck source=lib/gh-rest.sh
. "$BIN/lib/gh-rest.sh" || { printf '%s: cannot source %s/lib/gh-rest.sh\n' "$SELF" "$BIN" >&2; exit 3; }

usage() {
  {
    printf 'usage: %s [--apply] <slug> <pr-number>...\n' "$SELF"
    printf '       %s [--apply] --all-open <slug>\n' "$SELF"
    printf 'dry run is the default; --apply is what writes.\n'
  } >&2
  exit 3
}

APPLY=0; ALL_OPEN=0; SLUG=""; NUMS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --apply)    APPLY=1 ;;
    --all-open) ALL_OPEN=1 ;;
    -h|--help)  usage ;;
    -*)         printf '%s: unknown flag %s\n' "$SELF" "$1" >&2; usage ;;
    *)          if [ -z "$SLUG" ]; then SLUG="$1"; else NUMS+=("$1"); fi ;;
  esac
  shift
done

[[ "$SLUG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { printf '%s: need a <owner>/<repo> slug\n' "$SELF" >&2; usage; }
command -v gh >/dev/null 2>&1 || { printf '%s: no gh on PATH — nothing requested\n' "$SELF" >&2; exit 3; }
if [ "$ALL_OPEN" = 1 ]; then
  [ "${#NUMS[@]}" -eq 0 ] || { printf '%s: --all-open takes no PR numbers\n' "$SELF" >&2; usage; }
else
  [ "${#NUMS[@]}" -gt 0 ] || { printf '%s: no PR numbers and no --all-open\n' "$SELF" >&2; usage; }
  for n in "${NUMS[@]}"; do
    [[ "$n" =~ ^[0-9]+$ ]] || { printf '%s: %s is not a PR number\n' "$SELF" "$n" >&2; usage; }
  done
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/pr-title-backfill.XXXXXX") || exit 3
trap 'rm -rf "$TMP"' EXIT

# The shape, as one matcher with no backreference: bash's =~ is POSIX ERE, so the
# two keys are captured and compared instead.
SHAPE='^(BH-[0-9][0-9.]*): spec\((BH-[0-9][0-9.]*)\): '
is_defect_shape() { # is_defect_shape <title> -> 0 and sets SHAPE_KEY
  SHAPE_KEY=""
  [[ "$1" =~ $SHAPE ]] || return 1
  [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ] || return 1
  SHAPE_KEY="${BASH_REMATCH[1]}"
  return 0
}

# The list, when asked for one. An unreadable list is exit 3, not an empty run:
# "GitHub said nothing" must never read as "no PRs are affected" (#768).
if [ "$ALL_OPEN" = 1 ]; then
  if ! gh_rest_pr_list "$SLUG" open > "$TMP/list.json"; then
    printf '%s: could not list open PRs of %s (HTTP %s%s) — nothing read, nothing written\n' \
      "$SELF" "$SLUG" "$GH_REST_STATUS" "${GH_REST_REASON:+ $GH_REST_REASON}" >&2
    exit 3
  fi
  while IFS= read -r n; do
    [[ "$n" =~ ^[0-9]+$ ]] && NUMS+=("$n")
  done < <(jq -r '.[].number // empty' "$TMP/list.json" 2>/dev/null)
  [ "${#NUMS[@]}" -gt 0 ] || { printf '%s: %s has no open PRs\n' "$SELF" "$SLUG"; exit 0; }
fi

RETITLED=0; WOULD=0; SKIPPED=0; FAILED=0

for N in "${NUMS[@]}"; do
  # 1. the PR itself. Unreadable is a skip with its status on the line, never a
  #    write and never a claim about a PR nobody read.
  if ! gh_rest GET "repos/$SLUG/pulls/$N" > "$TMP/pr.json"; then
    printf 'SKIP #%s pr unreadable status=%s%s\n' "$N" "$GH_REST_STATUS" "${GH_REST_REASON:+ ($GH_REST_REASON)}"
    SKIPPED=$((SKIPPED+1)); continue
  fi
  STATE=$(jq -r '.state // ""' "$TMP/pr.json" 2>/dev/null)
  OLD=$(jq -r '.title // ""' "$TMP/pr.json" 2>/dev/null)
  if [ "$STATE" != open ]; then
    printf 'SKIP #%s state=%s\n' "$N" "${STATE:-unknown}"
    SKIPPED=$((SKIPPED+1)); continue
  fi
  if ! is_defect_shape "$OLD"; then
    printf 'SKIP #%s title is not the defect shape: %s\n' "$N" "$OLD"
    SKIPPED=$((SKIPPED+1)); continue
  fi
  KEY="$SHAPE_KEY"
  # A decomposed key (BH-1510.0) is a child of issue 1510; the issue number is
  # the leading integer of the key.
  ISSUE=${KEY#BH-}; ISSUE=${ISSUE%%.*}

  # 2. the ticket title — BEFORE any write.
  if ! gh_rest GET "repos/$SLUG/issues/$ISSUE" > "$TMP/issue.json"; then
    printf 'SKIP #%s issue title unreadable (issue #%s, status=%s%s)\n' \
      "$N" "$ISSUE" "$GH_REST_STATUS" "${GH_REST_REASON:+ $GH_REST_REASON}"
    SKIPPED=$((SKIPPED+1)); continue
  fi
  IT=$(jq -r '.title // ""' "$TMP/issue.json" 2>/dev/null)
  if [ -z "${IT//[[:space:]]/}" ]; then
    printf 'SKIP #%s issue #%s has no title\n' "$N" "$ISSUE"
    SKIPPED=$((SKIPPED+1)); continue
  fi
  case "$IT" in "$KEY: "*) IT=${IT#"$KEY: "} ;; esac
  NEW="$KEY: ${IT:0:80}"
  if is_defect_shape "$NEW"; then
    printf 'SKIP #%s the issue title is itself the spec shape\n' "$N"
    SKIPPED=$((SKIPPED+1)); continue
  fi
  if [ "$NEW" = "$OLD" ]; then
    printf 'SKIP #%s already titled from the ticket\n' "$N"
    SKIPPED=$((SKIPPED+1)); continue
  fi

  if [ "$APPLY" != 1 ]; then
    printf 'WOULD RETITLE #%s: %s -> %s\n' "$N" "$OLD" "$NEW"
    WOULD=$((WOULD+1)); continue
  fi

  # 3. the write, and then the response's own read-back. A 2xx that came back
  #    with a different title is a FAILURE, not a success (D9).
  if ! gh_rest PATCH "repos/$SLUG/pulls/$N" -f "title=$NEW" > "$TMP/patch.json"; then
    printf 'FAILED #%s status=%s%s\n' "$N" "$GH_REST_STATUS" "${GH_REST_REASON:+ ($GH_REST_REASON)}"
    FAILED=$((FAILED+1)); continue
  fi
  SEEN=$(jq -r '.title // ""' "$TMP/patch.json" 2>/dev/null)
  if [ "$SEEN" != "$NEW" ]; then
    printf 'FAILED #%s status=%s but the title read back as: %s\n' "$N" "$GH_REST_STATUS" "$SEEN"
    FAILED=$((FAILED+1)); continue
  fi
  printf 'RETITLED #%s: %s\n' "$N" "$NEW"
  RETITLED=$((RETITLED+1))
done

printf '%s: %s retitled, %s would-retitle, %s skipped, %s failed%s\n' \
  "$SELF" "$RETITLED" "$WOULD" "$SKIPPED" "$FAILED" \
  "$([ "$APPLY" = 1 ] || printf ' (dry run — nothing was written)')"
[ "$FAILED" -eq 0 ]
