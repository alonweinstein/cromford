#!/bin/bash
# bin/caller-check.sh — list every caller of each interface a diff changes, as
# ported or left alone, with a reason (BH-5791). The logic is in
# bin/lib/caller-check.sh; the `caller check` block in bin/lib/rb/pr.sh runs
# this after the rebase verify and puts the section into the PR body.
#
# usage: caller-check.sh --repo D --base SHA --head REF --plan F --out F
#
# Writes <out>:
#   CALLERS: interfaces=<n> ported=<p> left=<l> noreason=<r> gone=<g>
#   INTERFACE<TAB><name><TAB><kind><TAB>listed|diff<TAB>changed|gone<TAB><reason>
#   CALLER<TAB><name><TAB><file>:<line><TAB>ported|left alone<TAB><reason>
#   SKIPPED<TAB><name><TAB>skipped (name too short)
# or, on rc 3, the one line `CALLERS: could-not-run <why>`. Prints the CALLERS
# line. left counts left-alone callers, noreason the left-alone callers with
# no reason in the plan, gone the callers that still name a definition the
# diff removed. rc 0 = ran, 3 = could not run.
set -uo pipefail
REPO="" BASE="" HEAD="" PLAN="" OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --base) BASE="${2:-}"; shift 2 ;;
    --head) HEAD="${2:-}"; shift 2 ;;
    --plan) PLAN="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    *) echo "CALLERS: could-not-run unknown argument $1"; exit 3 ;;
  esac
done
fail() {
  [ -z "$OUT" ] || printf 'CALLERS: could-not-run %s\n' "$1" > "$OUT"
  echo "CALLERS: could-not-run $1"; exit 3
}
[ -n "$OUT" ] || fail "no --out"
[ -n "$REPO" ] && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || fail "not a git repo"
[ -n "$BASE" ] && git -C "$REPO" cat-file -e "$BASE^{commit}" 2>/dev/null || fail "the base ${BASE:0:12} does not resolve"
[ -n "$HEAD" ] && git -C "$REPO" rev-parse -q --verify "$HEAD^{commit}" >/dev/null 2>&1 || fail "the head ${HEAD:0:40} does not resolve"
# shellcheck source=bin/lib/caller-check.sh
. "$(dirname "$0")/lib/caller-check.sh" || fail "lib missing"
command -v cc_callers >/dev/null 2>&1 || fail "lib missing"
IFS_TSV=$(mktemp "${TMPDIR:-/tmp}/cc-ifs.XXXXXX") || fail "no temp file"
ROWS=$(mktemp "${TMPDIR:-/tmp}/cc-rows.XXXXXX") || { rm -f "$IFS_TSV"; fail "no temp file"; }
trap 'rm -f "$IFS_TSV" "$ROWS"' EXIT
cc_interfaces "$REPO" "$BASE" "$HEAD" "$PLAN" > "$IFS_TSV"
cc_callers "$REPO" "$BASE" "$HEAD" "$IFS_TSV" > "$ROWS"
SUM=$(awk -F'\t' '
  FILENAME == ARGV[1] { ni++; next }
  $1 == "CALLER" && $4 == "ported" { p++ }
  $1 == "CALLER" && $4 == "left alone" { l++; if ($5 == "no reason in the plan") r++; if ($5 ~ /^definition gone/) g++ }
  END { printf "interfaces=%d ported=%d left=%d noreason=%d gone=%d", ni, p, l, r, g }' "$IFS_TSV" "$ROWS")
{
  printf 'CALLERS: %s\n' "$SUM"
  awk -F'\t' '{ printf "INTERFACE\t%s\n", $0 }' "$IFS_TSV"
  cat "$ROWS"
} > "$OUT" || fail "cannot write --out"
echo "CALLERS: $SUM"
exit 0
