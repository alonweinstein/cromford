#!/bin/bash
# bin/marker-reason-lint.sh [--base <ref>] [root]
#
# A lint-silencing marker this diff adds must carry its reason on the same
# line (BH-5797). The markers are the `lead` rules of catalog/silence-markers.tsv
# that match an added line (scratch-closure, gh-guard, determinism): the lead
# review sees each one in its request notes, and a marker with no reason gives
# it nothing to judge. A rules-pack component, so the builder verify step, the
# PR lint job and every fix round run it before a push.
#
#   --base <ref>  judge the lines added since the merge-base of <ref> and HEAD
#                 (default: origin/main).
#   root          the checkout to scan (default: the current directory).
#   rc 0 clean
#   rc 1 findings, one per stdout line:
#        `<path>: <marker> with no reason on the line: <line>`
#   rc 2 bad args, no rules file, not a git work tree, or unresolvable base
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
BASE=origin/main; ROOT=.
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:-}"; [ -n "$BASE" ] || { echo "marker-reason-lint: --base needs a ref" >&2; exit 2; }; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    -*) echo "marker-reason-lint: unknown argument $1" >&2; exit 2 ;;
    *) ROOT="$1"; shift ;;
  esac
done
. "$HERE/lib/silence-scan.sh" || { echo "marker-reason-lint: cannot load bin/lib/silence-scan.sh" >&2; exit 2; }
RULES="$ROOT/catalog/silence-markers.tsv"
[ -r "$RULES" ] || { echo "marker-reason-lint: no $RULES" >&2; exit 2; }
ROWS=$(ss_rows_git "$ROOT" "$BASE") || { echo "marker-reason-lint: cannot diff $BASE...HEAD in $ROOT" >&2; exit 2; }
[ -n "$ROWS" ] || exit 0
OUT=$(ss_match "$RULES" reasonless <<<"$ROWS"); rc=$?
case "$rc" in
  0) printf '%s\n' "$OUT"; echo "marker-reason-lint: $(grep -c . <<<"$OUT") marker(s) with no reason" >&2; exit 1 ;;
  1) exit 0 ;;
  *) echo "marker-reason-lint: the rules file could not be read" >&2; exit 2 ;;
esac
