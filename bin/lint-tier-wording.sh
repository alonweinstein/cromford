#!/bin/bash
# bin/lint-tier-wording.sh [--base <ref>] [--all] [root]
#
# The human-seat tier wording lint (BH-4582, BH-4572.3): added rule and prompt
# lines that say a person merges or holds tier-2 work.
#
# WHY: BH-4579 made the tier a recorded risk class, never a merge gate; the
# merge conductor and merge queue land every reviewed tier on the same gates.
# Guardrail 1 and five prompts still told every session "the operator merges tier-2",
# and a box reads its rules and prompts as policy. This lint stops a diff from
# adding that wording back.
#
#   --base <ref>  judge the lines added since the merge-base of <ref> and HEAD,
#                 working-tree edits included (default: origin/main).
#   --all         judge every line of every file in the scan set (an inventory;
#                 no git).
#   root          the checkout to scan (default: the current directory).
#   rc 0 clean
#   rc 1 findings, one per stdout line: `<path>:<line>: tier-wording: <text>`
#        (the count goes to stderr)
#   rc 2 bad args, not a git work tree (delta mode), unresolvable base, or a
#        scan file that exists but cannot be read
#
# SCAN SET: rules/topics/*.md, rules/CLAUDE.md, top-level prompts/*.md and
# skills/*/SKILL.md (prompts/greenfield/, prompts/product-stages/ and other
# files under skills/ are not in it).
# PATTERNS (case-insensitive, one line at a time):
#   tier[- ]?2 (waits|needs|is for) (for )?(operator|a person|a human)
#   human seat
#   awaiting operator
#   operator merges tier[- ]?2
#
# BLIND SPOTS (not caught, by design of a line lint):
#   - a phrase wrapped across two lines ("the operator merges\n  tier-2")
#   - the same wording anywhere outside the scan set (docs/, bin/, a skill's
#     non-SKILL.md files)
#   - in delta mode, wording that was already there before the fork (use --all)
set -uo pipefail

die2() { echo "lint-tier-wording: $*" >&2; exit 2; }

BASE=origin/main; ALL=0; ROOT_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0"; exit 0 ;;
    --base) [ $# -ge 2 ] && [ -n "$2" ] || die2 "--base needs a ref"; BASE=$2; shift 2 ;;
    --all) ALL=1; shift ;;
    -*) die2 "unexpected argument $1" ;;
    *)
      [ -z "$ROOT_ARG" ] || die2 "unexpected argument $1"
      [ -d "$1" ] || die2 "root $1 is not a directory"
      ROOT_ARG=$1; shift ;;
  esac
done
ROOT=$(cd "${ROOT_ARG:-.}" && pwd) || die2 "cannot enter root ${ROOT_ARG:-.}"

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT

# ── the line set: path<TAB>line<TAB>text ─────────────────────────────────────
: > "$TMP/lines"
if [ "$ALL" -eq 1 ]; then
  for P in "$ROOT"/rules/topics/*.md "$ROOT/rules/CLAUDE.md" "$ROOT"/prompts/*.md "$ROOT"/skills/*/SKILL.md; do
    [ -e "$P" ] || continue
    [ -r "$P" ] || die2 "cannot read $P"
    awk -v P="${P#"$ROOT"/}" '{ print P "\t" FNR "\t" $0 }' "$P" >> "$TMP/lines" || die2 "cannot read $P"
  done
else
  git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die2 "$ROOT is not a git work tree (use --all to scan without git)"
  ROOT=$(git -C "$ROOT" rev-parse --show-toplevel) || die2 "cannot find the top of $ROOT"
  git -C "$ROOT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || die2 "cannot resolve base $BASE"
  FORK=$(git -C "$ROOT" merge-base "$BASE" HEAD 2>/dev/null)
  [ -n "$FORK" ] || die2 "no merge-base between $BASE and HEAD (shallow clone?)"
  git -C "$ROOT" -c core.quotepath=off diff -U0 --no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/ \
    --diff-filter=AMR "$FORK" -- ':(glob)rules/topics/*.md' rules/CLAUDE.md ':(glob)prompts/*.md' ':(glob)skills/*/SKILL.md' \
    > "$TMP/diff" || die2 "git diff -U0 against $FORK failed"
  # A `+++ b/<path>` is a header only between `diff --git` and the first
  # `@@`; inside a hunk the same bytes are an added line that begins `++ `.
  awk '
    /^diff --git / { hdr = 1; f = ""; next }
    hdr && /^\+\+\+ b\// { f = substr($0, 7); next }
    /^@@ / { hdr = 0; split($3, a, ","); n = substr(a[1], 2) + 0; next }
    !hdr && /^\+/ { if (f != "") print f "\t" n "\t" substr($0, 2); n++ }
  ' "$TMP/diff" > "$TMP/lines"
fi
[ -s "$TMP/lines" ] || exit 0

# ── the judgement ────────────────────────────────────────────────────────────
awk -F'\t' '
  BEGIN { RE = "tier[- ]?2 (waits|needs|is for) (for )?(operator|a person|a human)|human seat|awaiting operator|operator merges tier[- ]?2" }
  {
    text = $0; sub(/^[^\t]*\t[^\t]*\t/, "", text)
    if (tolower(text) !~ RE) next
    t = text; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t)
    printf "%s:%s: tier-wording: %s\n", $1, $2, substr(t, 1, 160)
    found++
  }
  END { exit (found ? 1 : 0) }
' "$TMP/lines" > "$TMP/out"
RC=$?
cat "$TMP/out"
if [ "$RC" -eq 1 ]; then
  echo "lint-tier-wording: $(grep -c . "$TMP/out") human-seat tier line(s); the tier is a recorded risk class, never a merge gate" >&2
  exit 1
fi
[ "$RC" -eq 0 ] || die2 "the judging awk failed (rc $RC)"
exit 0
