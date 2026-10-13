#!/bin/bash
# bin/lib/alert-verify.sh — what the ten bin/alert-verify/<id>.sh scripts share
# (BH-2577). Sourced, never executed.
#
# The protocol is the header of bin/triage-family-scripts.sh: stdin is the
# family's quarantine lines (source<TAB>epoch<TAB>beat-json); exit 0 with a
# non-empty first line is cleared, 1 still reproduces, anything else is doubt.
# Every helper here returns 75 on doubt, so a script can write `|| exit 75`.
#
# The scripts leave nothing behind: av_gh_get's temp file goes on exit.
# GH_ETAG=0 keeps gh_rest off its ETag cache (the quota ledger line gh_rest
# appends is the library's accounting, as for every other caller), and
# GH_REST_OPTIONAL=1 makes a verify the first read the quota reserve refuses
# (rc 75, the family is kept for a session).
GH_ETAG=0; GH_REST_OPTIONAL=1; export GH_ETAG GH_REST_OPTIONAL
AV_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The root is HARNESS, then the caller's H, else none (BH-2613,
# docs/notes/2026-09-26-BH-2613-lib-root-resolution.md). Every
# bin/alert-verify/<id>.sh sets HARNESS before its source line, so the entry
# point owns the /root/harness default. With no root, av_pr_verdict is doubt.
AV_HARNESS="${HARNESS:-${H:-}}"
AV_SLUG='[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+'
. "$AV_LIB/gh-rest.sh" || return 75

# av_gh_get <api path> — one gh_rest GET into $AV_BODY, a temp file removed on
# exit. Through a FILE and never `$( )`, the rule of bin/lib/gh-rest.sh (the
# caller keeps GH_REST_STATUS). Returns gh_rest's own rc: 0, 44 or 75.
av_gh_get() {
  local rc=0
  AV_BODY=$(mktemp "${TMPDIR:-/tmp}/alert-verify.XXXXXX") || return 75
  trap 'rm -f "$AV_BODY"' EXIT
  gh_rest GET "$1" > "$AV_BODY" || rc=$?
  return "$rc"
}

# av_field <line|akey> — stdin: quarantine lines. Prints that string field of
# every beat. rc 75 when any payload is not a beat carrying it, or on no input.
av_field() {
  local src ep payload v n=0
  while IFS=$'\t' read -r src ep payload || [ -n "${src:-}" ]; do
    [ -n "$src$ep$payload" ] || continue
    v=$(printf '%s' "$payload" | jq -er --arg f "$1" '.[$f] | strings' 2>/dev/null) || return 75
    printf '%s\n' "$v"; n=$((n+1))
  done
  [ "$n" -gt 0 ] || return 75
}

# av_one <ERE> — stdin: text. Prints the one DISTINCT match. None, or two
# different subjects in one family, is 75: never a verdict for half a family.
av_one() {
  local m
  m=$(grep -oE -- "$1" | sort -u) || return 75
  [ -n "$m" ] && [ "$(printf '%s\n' "$m" | wc -l)" -eq 1 ] || return 75
  printf '%s\n' "$m"
}

# av_pr_verdict <row-id> <pr-url> — the PR-state rows. Reads through
# bin/gh-pr-state.sh (which honours the quota reserve). MERGED/CLOSED prints the
# proof and returns 0, OPEN returns 1, and everything else (44 no such PR, 75,
# an unknown word) returns 75.
av_pr_verdict() {
  local st
  [ -n "$AV_HARNESS" ] || return 75
  st=$("$AV_HARNESS/bin/gh-pr-state.sh" "$2" 2>/dev/null) || return 75
  case "$st" in
    OPEN) return 1 ;;
    MERGED|CLOSED) printf '%s: %s is %s\n' "$1" "$2" "$st" ;;
    *) return 75 ;;
  esac
}
