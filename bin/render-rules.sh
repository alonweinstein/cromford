#!/bin/bash
# bin/render-rules.sh [--root <dir>] [--write|--check]
#
# Print the fleet rules file that rules/topics/ describes. EDIT rules/topics/,
# NEVER rules/CLAUDE.md: the committed file is an artifact, and the next
# --write overwrites anything typed into it by hand.
#
#   rules/topics/00-intro.md   the preamble, verbatim (first file in C order)
#   rules/topics/NN-<topic>.md one `## ` topic each, verbatim
#
# THE OUTPUT:
#
#   <the first topic file, verbatim>
#
#   ## Contents
#
#   - [<heading text>](#<anchor>)     one per `## ` line of the remaining topics,
#   ...                               in file order
#
#   <each remaining topic, verbatim, separated by one blank line>
#
# The anchor is the heading text lowercased with every character outside
# [a-z0-9 -] stripped and spaces turned into `-`, which is what GitHub
# generates for the same heading. Trailing blank lines are trimmed off every
# fragment, so "separated by one blank line" holds whatever an editor left
# behind and `--write` twice is a no-op.
#
# MODES: default prints to stdout and writes nothing. --write renders to a temp
# file and moves it onto rules/CLAUDE.md (bin/lib/render-fragments.sh's
# rf_write_atomic), silently. --check compares and prints the drift.
#
# EXIT CODES, from the contract this sources (bin/lib/render-fragments.sh):
#   0  rendered, or --check found no drift
#   1  --check found drift: `DRIFT rules/CLAUDE.md` plus the first 25 diff lines
#   2  cannot render — missing or empty rules/topics/, bad root, bad arguments —
#      and --check maps ANY render failure to 2, never to 0: a renderer that did
#      not run never reports "no drift"
#   3  a topic was refused, with file and line on stderr: a CR byte, a topic
#      after the first whose first line is not a `## ` heading, or a `## `
#      heading text that a second topic repeats. A table of contents that lies
#      about the document is worse than no table of contents.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/render-fragments.sh
. "$HERE/lib/render-fragments.sh"

ROOT="$(cd "$HERE/.." && pwd)"
MODE=print
usage() { echo "usage: render-rules.sh [--root <dir>] [--write|--check]" >&2; exit 2; }
setmode() { [ "$MODE" = print ] || usage; MODE="$1"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --root)    ROOT="${2:-}"; [ -n "$ROOT" ] || usage; shift 2 ;;
    --write)   setmode write; shift ;;
    --check)   setmode check; shift ;;
    -h|--help) sed -n '2,41p' "$0"; exit 0 ;;
    *)         echo "render-rules.sh: unknown argument $1" >&2; usage ;;
  esac
done

cd "$ROOT" 2>/dev/null || { echo "render-rules.sh: cannot enter root $ROOT" >&2; exit 2; }
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

# The heading text a `## ` line carries, turned into the anchor GitHub would mint.
anchor() {
  printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -cd 'a-z0-9 -' | tr ' ' '-'
}

# Everything but the trailing blank lines, with a final newline guaranteed.
trim_tail() {
  awk '{ l[NR] = $0 } END { n = NR; while (n > 0 && l[n] ~ /^[[:space:]]*$/) n--; for (i = 1; i <= n; i++) print l[i] }'
}

# Renders into $TMP. Callers guard with `|| rc=$?`, which turns errexit off in
# here, so every step that can fail says so explicitly.
render() {
  local frags first f line heads dup dupfirst dupsecond text
  local -a files=()

  frags=$(rf_fragments rules/topics '*.md') || return $?
  while IFS= read -r f; do [ -n "$f" ] || continue; files+=("$f"); done <<< "$frags"
  first="${files[0]}"

  for f in "${files[@]:1}"; do
    IFS= read -r line < "$f" || line=""
    case "$line" in
      '## '*) ;;
      *) rf_fail "$f:1: a topic after the first must begin with a '## ' heading" || return $? ;;
    esac
  done

  # <file> TAB <heading text>, in render order. A `## ` line in the preamble is
  # part of the preamble's own text and is deliberately not collected.
  heads=$(for f in "${files[@]:1}"; do
            grep -a '^## ' -- "$f" | awk -v f="$f" '{ print f "\t" substr($0, 4) }' || :
          done)
  dup=$(cut -f2 <<< "$heads" | sort | uniq -d)
  dup=${dup%%$'\n'*}
  if [ -n "$dup" ]; then
    dupfirst=$(awk -F'\t' -v d="$dup" '$2 == d { print $1; exit }' <<< "$heads")
    dupsecond=$(awk -F'\t' -v d="$dup" '$2 == d { c++; if (c == 2) { print $1; exit } }' <<< "$heads")
    rf_fail "$dupsecond: duplicate heading '## $dup' (also in $dupfirst)" || return $?
  fi

  {
    trim_tail < "$first"
    printf '\n## Contents\n\n'
    while IFS=$'\t' read -r f text; do
      [ -n "$text" ] || continue
      printf -- '- [%s](#%s)\n' "$text" "$(anchor "$text")"
    done <<< "$heads"
    for f in "${files[@]:1}"; do
      printf '\n'
      trim_tail < "$f"
    done
  } | trim_tail > "$TMP" || { echo "render-rules.sh: render failed" >&2; return 2; }
}

rc=0
render || rc=$?

case "$MODE" in
  print)
    [ "$rc" -eq 0 ] || exit "$rc"
    cat "$TMP"
    ;;
  write)
    [ "$rc" -eq 0 ] || exit "$rc"
    rf_write_atomic rules/CLAUDE.md "$TMP"
    ;;
  check)
    [ "$rc" -eq 0 ] || exit 2
    rf_check rules/CLAUDE.md "$TMP" || exit $?
    ;;
esac
