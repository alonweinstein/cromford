#!/bin/bash
# bin/render-env-example.sh [--root <dir>] [--write|--check]
#
# Print env-templates/global.env.example from env-templates/lanes/ — one
# file per topic, concatenated in filename order.
#
# WHY (BH-1178). The template is the one file every new knob has to append to,
# and it was touched by 25 of the last 200 merges. Two branches adding two
# unrelated knobs landed in the same trailing lines and conflicted every time.
# `merge=union` in .gitattributes kept that from stopping a merge but produced
# a file with both hunks in whatever order git chose; nothing checked the
# result. Now a knob is one file under lanes/ and the template is its
# concatenation, so two branches touch two files and the drift check is what
# says the committed template still equals its parts.
#
# WHAT IS *NOT* GENERATED HERE, and why it is honest to say so: the knob PROSE.
# catalog/lanes.json carries a lane's knobs with a one-line `note`; this
# template carries the paragraph that says what the number means, what zero
# does and which incident bought the default. The registry cannot produce that
# text, so the topic files hold it verbatim and the registry is not their
# source. Rendering the template FROM the registry's notes would silently
# replace six paragraphs of operator guidance with six sentences.
#
# AND IT IS NOT COMMITTED (BH-1247). BH-1178 left the render in git and
# `--check` compared its bytes, which made the rendered template a shared
# mutable cell again: a PR that added a knob without re-rendering turned red,
# and once such a PR merged every OTHER open PR inherited the red. Three merge
# trains died that way on 2026-09-21. Same doctrine as BH-1175's
# docs/verification-map/README.md: take the contested cell OUT of git.
#
# So the path is git-ignored, the share mirror and CI render it, and `--check`
# validates what IS committed: the topic files are readable and CR-free, the
# render is DETERMINISTIC (two runs byte-identical), and no copy is TRACKED.
#
#   --write            rewrite env-templates/global.env.example
#   --to <path>        render into <path>
#   --check            the topics are valid, the render is deterministic, and
#                      no env-templates/global.env.example is tracked in git
#   --check-committed  the OLD byte comparison, for a repo that still COMMITS it
#   (neither) print the render on stdout
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# rf_fragments is the repo's one spelling of "list a fragment directory": it
# sorts under LC_ALL=C and REFUSES a CR byte. A CRLF topic file would otherwise
# put `KNOB=1\r` in the template an operator copies into env/global.env, where
# the value carries the CR into every comparison that reads it.
# shellcheck source=bin/lib/render-fragments.sh
. "$HERE/lib/render-fragments.sh"
MODE=print
TO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root)    ROOT="$2"; shift 2 ;;
    --write)   MODE=write; shift ;;
    --to)      MODE=to; TO="$2"; shift 2 ;;
    --check)   MODE=check; shift ;;
    --check-committed) MODE=check-committed; shift ;;
    # The range is DERIVED: awk stops at the first non-comment line, so a
    # paragraph added to this header is printed rather than silently cut
    # (the literal range in render-crontab.sh grew stale twice).
    -h|--help) awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0"; exit 0 ;;
    *)         echo "render-env-example.sh: unexpected argument $1" >&2; exit 2 ;;
  esac
done

SRC="$ROOT/env-templates/lanes"
OUT="$ROOT/env-templates/global.env.example"
[ -d "$SRC" ] || { echo "render-env-example.sh: no $SRC" >&2; exit 1; }

TMP=$(mktemp "${TMPDIR:-/tmp}/env-tmpl.XXXXXX"); trap 'rm -f "$TMP" "$TMP.2"' EXIT

# render <outfile> — in a function so `--check` can run it TWICE over the same
# topic files and compare. That second run is what replaced the byte comparison
# against a committed copy (BH-1247): the property that remains provable once
# nothing is committed is that the parts render to one answer.
N=0
render() {
  local dst="$1" list f bn
  : > "$dst"
  list=$(rf_fragments "$SRC" '*.env.example') || { echo "render-env-example.sh: $SRC was refused" >&2; return 1; }
  N=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    bn=$(basename "$f" .env.example)
    case "${bn%%-*}" in ''|*[!0-9]*) echo "render-env-example.sh: $f: filename must be <NNN>-<slug>.env.example" >&2; return 1 ;; esac
    cat "$f" >> "$dst"
    N=$((N+1))
  done <<<"$list"
  [ "$N" -gt 0 ] || { echo "render-env-example.sh: $SRC holds no topic files" >&2; return 1; }
  [ -s "$dst" ] || { echo "render-env-example.sh: composed an empty template — refusing it" >&2; return 1; }
  return 0
}

render "$TMP" || exit 1

case "$MODE" in
  print) cat "$TMP" ;;
  to)    [ -n "$TO" ] || { echo "render-env-example.sh: --to needs a path" >&2; exit 2; }
         cp "$TMP" "$TO" ;;
  write) cp "$TMP" "$OUT"; echo "render-env-example.sh: wrote env-templates/global.env.example ($N topics)" ;;
  check)
    # The TOPIC FILES are what is committed, so they are what is checked, and
    # nothing here writes.
    BAD=0
    if ! render "$TMP.2"; then
      echo "render-env-example.sh: the second render of the same topics FAILED" >&2
      BAD=1
    elif ! cmp -s "$TMP" "$TMP.2"; then
      echo "render-env-example.sh: env-templates/lanes/ does not render to the same bytes twice:" >&2
      diff -u "$TMP" "$TMP.2" 2>/dev/null | head -20 >&2
      BAD=1
    fi
    # A TRACKED template, full stop — not "tracked AND ignored": a PR that drops
    # the ignore line and force-adds the render must not switch its own gate off.
    if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
      if [ -n "$(git -C "$ROOT" ls-files -- env-templates/global.env.example 2>/dev/null)" ]; then
        echo "render-env-example.sh: env-templates/global.env.example is TRACKED in git. It is GENERATED and must not be committed (BH-1247):" >&2
        echo "render-env-example.sh:   git rm --cached env-templates/global.env.example   — the source is env-templates/lanes/" >&2
        if ! git -C "$ROOT" check-ignore -q --no-index -- env-templates/global.env.example 2>/dev/null; then
          echo "render-env-example.sh:   and .gitignore no longer covers it — restore that line too, or the next build commits it again" >&2
        fi
        BAD=1
      fi
    fi
    [ "$BAD" = 0 ] || { echo "render-env-example.sh: the source is env-templates/lanes/ — the template itself is generated and ignored." >&2; exit 1; }
    echo "render-env-example.sh: env-templates/lanes/ is valid and renders deterministically ($N topics); env-templates/global.env.example is generated, not committed" ;;
  check-committed)
    if [ -f "$OUT" ] && cmp -s "$OUT" "$TMP"; then
      echo "render-env-example.sh: env-templates/global.env.example is in sync ($N topics)"
    else
      echo "render-env-example.sh: env-templates/global.env.example does not match env-templates/lanes/ (committed vs generated):" >&2
      diff -u "$OUT" "$TMP" 2>/dev/null | head -60 >&2
      echo "render-env-example.sh: run bin/render-env-example.sh --write and commit the result." >&2
      exit 1
    fi ;;
esac
