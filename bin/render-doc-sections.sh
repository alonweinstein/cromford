#!/bin/bash
# bin/render-doc-sections.sh [--root <dir>] [--write|--check] [<doc>.md ...]
#
# Print a doc that lives as section files. EDIT <doc>.d/, NEVER <doc>.md: the
# committed doc is an artifact, and the next --write overwrites anything typed
# into it by hand. With no <doc> argument it renders docs/PR-OWNERSHIP.md.
#
#   docs/PR-OWNERSHIP.d/00-intro.md     the preamble (first file in C order)
#   docs/PR-OWNERSHIP.d/NN-<slug>.md    one section each
#
# Two PRs that each add a section add two files, so they never conflict on a
# hunk; only the render does, and a train regenerates it (BH-5235.2).
#
# THE OUTPUT: the fragments concatenated in LC_ALL=C name order, verbatim. No
# header, no table of contents, no trimming, so a fragment carries its own
# trailing blank line and the render is exactly the bytes the files hold.
#
# MODES: default prints to stdout and writes nothing. --write renders to a temp
# file and moves it onto <doc>.md (bin/lib/render-fragments.sh's
# rf_write_atomic), silently. --check compares and prints the drift.
#
# EXIT CODES, from the contract this sources (bin/lib/render-fragments.sh), the
# worst over every doc named:
#   0  rendered, or --check found no drift
#   1  --check found drift: `DRIFT <doc>.md` plus the first 25 diff lines
#   2  cannot render — missing or empty <doc>.d/, bad root, bad arguments, a
#      <doc> not ending in .md — and --check maps ANY render failure to 2,
#      never to 0: a renderer that did not run never reports "no drift"
#   3  a fragment was refused, with the file on stderr: a CR byte, an empty
#      file, a last byte that is not a newline (plain concatenation would glue
#      two sections into one line), or a name that is not NN-<slug>.md with
#      <slug> in [a-z0-9-]. A file not ending in .md is not a fragment and is
#      ignored.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/render-fragments.sh
. "$HERE/lib/render-fragments.sh"

ROOT="$(cd "$HERE/.." && pwd)"
MODE=print
DOCS=()
usage() { echo "usage: render-doc-sections.sh [--root <dir>] [--write|--check] [<doc>.md ...]" >&2; exit 2; }
setmode() { [ "$MODE" = print ] || usage; MODE="$1"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --root)    ROOT="${2:-}"; [ -n "$ROOT" ] || usage; shift 2 ;;
    --write)   setmode write; shift ;;
    --check)   setmode check; shift ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    -*)        echo "render-doc-sections.sh: unknown argument $1" >&2; usage ;;
    *)         DOCS+=("$1"); shift ;;
  esac
done
[ "${#DOCS[@]}" -gt 0 ] || DOCS=(docs/PR-OWNERSHIP.md)
for doc in "${DOCS[@]}"; do
  case "$doc" in
    *.md) ;;
    *) echo "render-doc-sections.sh: $doc does not end in .md" >&2; usage ;;
  esac
done

cd "$ROOT" 2>/dev/null || { echo "render-doc-sections.sh: cannot enter root $ROOT" >&2; exit 2; }
TMPS=()
trap 'rm -f "${TMPS[@]}"' EXIT

# render <doc> <tmp>. Callers guard with `|| rc=$?`, which turns errexit off in
# here, so every step that can fail says so explicitly.
render() {
  local doc="$1" tmp="$2" frags f
  local -a files=()
  frags=$(rf_fragments "${doc%.md}.d" '*.md') || return $?
  while IFS= read -r f; do [ -n "$f" ] || continue; files+=("$f"); done <<< "$frags"
  for f in "${files[@]}"; do
    [[ "${f##*/}" =~ ^[0-9]{2}-[a-z0-9-]+\.md$ ]] || { rf_fail "$f: name is not NN-<slug>.md"; return 3; }
    [ -s "$f" ] || { rf_fail "$f: empty fragment"; return 3; }
    # $(...) strips a trailing newline, so an empty answer means the last byte IS one.
    [ -z "$(tail -c1 -- "$f")" ] || { rf_fail "$f: does not end in a newline"; return 3; }
  done
  cat -- "${files[@]}" > "$tmp" || { echo "render-doc-sections.sh: render of $doc failed" >&2; return 2; }
}

worst=0
for doc in "${DOCS[@]}"; do
  tmp=$(mktemp); TMPS+=("$tmp")
  rc=0
  render "$doc" "$tmp" || rc=$?
  case "$MODE" in
    print)
      [ "$rc" -eq 0 ] || exit "$rc"
      cat "$tmp"
      ;;
    write)
      [ "$rc" -eq 0 ] || exit "$rc"
      rf_write_atomic "$doc" "$tmp"
      ;;
    check)
      if [ "$rc" -ne 0 ]; then rc=2; else rf_check "$doc" "$tmp" || rc=$?; fi
      [ "$rc" -le "$worst" ] || worst=$rc
      ;;
  esac
done
exit "$worst"
