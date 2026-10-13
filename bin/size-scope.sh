#!/bin/bash
# bin/size-scope.sh — the ONE definition of "product code" in this harness.
#
#   size-scope.sh --rules                 print the exclusion list (it is the doc)
#   size-scope.sh --is-product <path>     exit 0 if that path counts, 1 if not
#   size-scope.sh --filter                stdin paths -> the product ones, in order
#   size-scope.sh --diff <base> [repo]    git diff <base>...HEAD, product only:
#                                         SIZE_PRODUCT_FILES / SIZE_PRODUCT_LINES
#                                         / SIZE_EXCLUDED_FILES / SIZE_EXCLUDED_LINES
#
# WHY IT IS ONE FILE (the operator, 2026-09-12). The size gate measures a plan's
# estimate; the post-hoc guard measures the diff that actually shipped. If those
# two carry their own idea of what counts, they disagree — the plan is sized
# against source-only and the PR is judged on a diff that includes a
# regenerated lockfile, and the gate starts demoting builds for `npm install`.
# One list, called from both sides, and tests/size-gate-test.sh pins it.
#
# WHY THESE EXCLUSIONS. The threshold is about REVIEW COST, and review cost is
# carried by product source. A wave that ships 250 lines of source, 400 lines of
# tests and a 3,000-line lockfile churn is a well-tested small change; counting
# the tests would punish exactly the discipline the rest of this pipeline
# spends money enforcing (red-first, acceptance tests per task, reproduction
# files for bugs), and counting the lockfile would make `npm install` a
# decomposable event.
#
# WHAT IS DELIBERATELY *NOT* EXCLUDED, because it is real risk a reviewer reads:
#   - scripts/migrations/*.sql — hand-written, and the migration gate already
#     treats them as the expensive kind of change. Only prisma/migrations/**
#     (Prisma's own generated snapshot dirs) is dropped.
#   - config: package.json, vercel.json, .github/workflows/** — small, and the
#     tier heuristic in run-build.sh already calls several of them tier-2 risk.
#   - .sh, .sql, .prisma: the harness is bash and the apps are Prisma. Excluding
#     "not real code" would exclude most of this repo.
#
# No network, no repo access for --filter/--is-product (pure string work), so an
# operator can re-run it against an archived file list and get the same answer.
set -uo pipefail

# The list. Kept as one case statement so there is exactly one place to edit,
# and printed verbatim by --rules so documentation cannot drift from behaviour.
RULES='tests/**            test/**             **/__tests__/**     **/__mocks__/**
*.test.*            *.spec.*            *_test.*            *Test.java
e2e/**              **/fixtures/**      **/testdata/**
**/__snapshots__/** *.snap
*.md                docs/**             tasks/**            .harness/specs/**
package-lock.json   yarn.lock           pnpm-lock.yaml      bun.lockb
Cargo.lock          poetry.lock         composer.lock       Gemfile.lock
go.sum              requirements.lock
prisma/migrations/**  **/generated/**   *.generated.*
dist/**             build/**            .next/**            out/**
*.min.js            *.min.css           *.map               vendor/**'

_excluded() { # _excluded <path>  -> 0 when the path is NOT product code
  local p="${1#./}" b
  b="${p##*/}"
  case "$p" in
    tests/*|test/*|e2e/*|vendor/*|dist/*|build/*|out/*|.next/*|docs/*|tasks/*) return 0 ;;
    */tests/*|*/test/*|*/__tests__/*|*/__mocks__/*|*/fixtures/*|*/testdata/*) return 0 ;;
    */__snapshots__/*|*/generated/*|*/vendor/*|*/dist/*|*/node_modules/*) return 0 ;;
    generated/*|.harness/specs/*|prisma/migrations/*) return 0 ;;
  esac
  case "$b" in
    *.test.*|*.spec.*|*_test.*|*Test.java|*.snap|*.generated.*) return 0 ;;
    *.md|*.mdx|*.snap) return 0 ;;
    *.min.js|*.min.css|*.map) return 0 ;;
    package-lock.json|yarn.lock|pnpm-lock.yaml|bun.lockb|Cargo.lock) return 0 ;;
    poetry.lock|composer.lock|Gemfile.lock|go.sum|requirements.lock) return 0 ;;
  esac
  return 1
}

MODE="${1:-}"
case "$MODE" in
  --rules)
    printf '%s\n' "$RULES"
    exit 0 ;;
  --is-product)
    P="${2:?path}"
    _excluded "$P" && exit 1 || exit 0 ;;
  --filter)
    # A filter, not a sorter: order in is order out, nothing invented, blank
    # lines dropped. Callers pass a plan's file list and a git file list through
    # the same code path.
    while IFS= read -r L || [ -n "$L" ]; do
      [ -n "$L" ] || continue
      _excluded "$L" || printf '%s\n' "$L"
    done
    exit 0 ;;
  --diff) ;;
  *) echo "usage: size-scope.sh --rules | --is-product <path> | --filter | --diff <base> [repo]" >&2
     exit 64 ;;
esac

BASE="${2:?base ref}"
REPO="${3:-.}"
cd "$REPO" 2>/dev/null || { echo "SIZE_SCOPE_UNAVAILABLE no repo at $REPO"; exit 3; }
git rev-parse -q --verify "$BASE" >/dev/null 2>&1 || {
  # NOT zero. A base that will not resolve is unmeasured, and printing 0 here
  # would read to the post-hoc guard as a tiny, safe diff — the exact shape of
  # a guard that never fires.
  echo "SIZE_SCOPE_UNAVAILABLE base '$BASE' does not resolve"; exit 3; }

NUM=$(git diff --numstat "$BASE"...HEAD 2>/dev/null) || {
  echo "SIZE_SCOPE_UNAVAILABLE git diff against '$BASE' failed"; exit 3; }

# numstat: "<added>\t<deleted>\t<path>", with renames as "old => new" or
# "dir/{old => new}/file", and "-" for binary. Binary files count as files and
# contribute no lines — a 2MB png is not 2MB of review.
printf '%s\n' "$NUM" | awk -F'\t' -v scope="$0" '
  NF < 3 { next }
  {
    path = $3
    if (path ~ / => /) {
      gsub(/\{[^{}]* => /, "{", path)   # dir/{old => new}/file -> dir/{new}/file
      gsub(/[{}]/, "", path)
      sub(/^.* => /, "", path)          # plain "old => new"
    }
    add = ($1 == "-") ? 0 : $1 + 0
    del = ($2 == "-") ? 0 : $2 + 0
    printf "%d\t%s\n", add + del, path
  }
' | {
  PF=0; PL=0; XF=0; XL=0
  while IFS=$'\t' read -r N P; do
    [ -n "$P" ] || continue
    case "$N" in ''|*[!0-9]*) N=0 ;; esac
    if _excluded "$P"; then XF=$((XF+1)); XL=$((XL+N))
    else PF=$((PF+1)); PL=$((PL+N)); fi
  done
  printf 'SIZE_PRODUCT_FILES: %d\nSIZE_PRODUCT_LINES: %d\nSIZE_EXCLUDED_FILES: %d\nSIZE_EXCLUDED_LINES: %d\n' \
    "$PF" "$PL" "$XF" "$XL"
}
exit 0
