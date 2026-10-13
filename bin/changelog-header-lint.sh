#!/bin/bash
# bin/changelog-header-lint.sh — no per-ticket changelog bullet in a comment
# (BH-5235.0).
#
# Flags a comment line whose body is a dash bullet keyed by a ticket: a `#`,
# `//`, `--` or `*` comment leader, then `- BH-N:` or `- #N:` (letter N standing
# for the digits; a dotted BH-N.N and a parenthesised alias before the colon,
# `- BH-N (BH-N.N):`, count too). A file that grows one such line per ticket is
# a changelog, and a changelog in a comment is history written where nobody
# reads it and every build edits it. History lives in git and on the ticket;
# a note that explains code goes next to the code it explains.
#
# Not flagged: an inline citation (`// BH-N: why this line exists`, `see BH-N`)
# — only the bullet form is. Not scanned: *.md at any depth, and the top-level
# docs/, .harness/ and tests/fixtures/ trees. Binary files are skipped.
#
# Scanned: every tracked file under <root>, working-tree content (git grep).
#
# Usage:  bash bin/changelog-header-lint.sh [root]     (default: this repo)
#
# Output: <file>:<line>: <reason>, one per offending line, sorted by file and
# then by line number (git grep's own order: the index is byte-sorted by path).
# Exit codes:
#   0  clean (silent)
#   1  offenders printed
#   2  could not scan — <root> is not a git work tree, or git grep failed.
#      An empty answer from a scan that never happened is not a clean tree.
set -euo pipefail

# Defaults to the repo this script lives in, never to $PWD.
ROOT=${1:-$(cd "$(dirname "$0")/.." && pwd)}
ROOT=${ROOT%/}

# safe.directory on every git call: the rules pack's isolated runner reads a
# snapshot owned by another uid, and git's ownership refusal is not a finding.
g() { git -C "$ROOT" -c safe.directory="$ROOT" "$@"; }

if ! g rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "changelog-header-lint: could not scan — $ROOT is not a git work tree" >&2
  exit 2
fi

# Built from parts so that no line of this script is itself a finding.
lead='^[[:space:]]*(#|//|--|\*)[[:space:]]*'
dash='-[[:space:]]+'
key='(B''H-[0-9]+(\.[0-9]+)*|#[0-9]+)'
paren='([[:space:]]+\([^)]*\))?:'
PAT="$lead$dash$key$paren"

hits=$(mktemp)
trap 'rm -f "$hits"' EXIT
rc=0
g grep -n -I -z -E "$PAT" -- . ':(exclude)*.md' ':(exclude,top)docs/' \
  ':(exclude,top).harness/' ':(exclude,top)tests/fixtures/' >"$hits" || rc=$?
if [ "$rc" -gt 1 ]; then
  echo "changelog-header-lint: could not scan — git grep exited $rc in $ROOT" >&2
  exit 2
fi

# -z output is file NUL line NUL text NEWLINE, so a path with `:`, `[` or a
# space (the coord proxy is [[path]].js) parses whole. No sort pass: git grep
# already answers in path order, lines ascending, and a text sort would put
# line 101 before line 70.
out=$(while IFS= read -r -d '' f && IFS= read -r -d '' n && IFS= read -r _; do
  printf '%s:%s: per-ticket changelog bullet (history lives in git and on the ticket; put the note next to the code it explains)\n' "$f" "$n"
done <"$hits")

[ -z "$out" ] && exit 0
printf '%s\n' "$out"
exit 1
