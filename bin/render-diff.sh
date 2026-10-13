#!/bin/bash
# bin/render-diff.sh [<base-ref>] [--root <dir>]
#
# Print what this tree changes about the files a box will ACTUALLY run: the ten
# rendered crontabs, the lane registry and the env template, rendered at
# <base-ref> and rendered here, diffed.
#
# WHY THIS EXISTS (BH-1247). Until this ticket those twelve renders were
# committed, so a PR that touched a lane showed the resulting crontab line in
# its own diff and a reviewer could read it. Uncommitting them removes the
# contested cell — the whole point — but it also removes that diff, and "what
# will this box run" is the question a lane review is actually asking. This
# script is the answer: CI runs it on every pull request and the output is the
# diff the reviewer used to get, computed rather than committed.
#
# THE TWO SIDES ARE NOT SYMMETRIC, on purpose. The BASE side is rendered from
# `git archive <base-ref>` — the base's own fragments AND its own renderer
# scripts, so a change to a renderer shows up as the crontab change it causes.
# The CURRENT side is rendered from the WORKING TREE, not from HEAD, so a
# builder can see the effect of an edit before committing it. In CI the two are
# the same thing.
#
# rc 0 whether or not anything changed — this is a REPORT, and a reviewer's
# information is not a build failure. rc 2 is "could not compute it", which is
# worth failing a CI step over: a render diff that silently prints nothing is
# indistinguishable from a change with no effect.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    -h|--help) awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0"; exit 0 ;;
    --*) echo "render-diff.sh: unknown flag $1" >&2; exit 2 ;;
    *) [ -z "$BASE" ] && BASE="$1" || { echo "render-diff.sh: unexpected argument $1" >&2; exit 2; }; shift ;;
  esac
done
BASE="${BASE:-origin/main}"

command -v git >/dev/null 2>&1 || { echo "render-diff.sh: git is required" >&2; exit 2; }
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || { echo "render-diff.sh: $ROOT is not a git repo" >&2; exit 2; }
git -C "$ROOT" rev-parse --verify --quiet "$BASE" >/dev/null 2>&1 \
  || { echo "render-diff.sh: no such ref: $BASE" >&2; exit 2; }

TMP=$(mktemp -d) || { echo "render-diff.sh: cannot create a temp dir" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT INT TERM
OLD="$TMP/old"; NEW="$TMP/new"; BTREE="$TMP/base-tree"
mkdir -p "$OLD" "$NEW" "$BTREE"

# ---- the base side: its own fragments, rendered by its own renderers --------
git -C "$ROOT" archive "$BASE" 2>/dev/null | tar -x -C "$BTREE" 2>/dev/null \
  || { echo "render-diff.sh: could not export $BASE" >&2; exit 2; }

# render_into <tree> <outdir> — the three renderers, into one flat directory.
# A renderer that fails leaves its side EMPTY rather than half-written, and the
# diff then shows the whole file as added or removed, which is the honest
# picture of "this side cannot render".
#
# A BASE THAT PREDATES THIS TICKET STILL RENDERS. `--out-dir` and `--to` are
# BH-1247's own flags, so the base of the PR that introduces them does not have
# them — and without a fallback that PR's diff would read as "all twelve files
# newly added", which tells a reviewer nothing. The older spelling writes into
# the tree's own paths, so each renderer is tried with the new flag first and
# the old one second, and the result is copied out of the tree either way.
render_into() {
  local tree="$1" out="$2" rc=0 b
  mkdir -p "$out"
  if [ -x "$tree/bin/render-cron.sh" ]; then
    if ! "$tree/bin/render-cron.sh" --root "$tree" --out-dir "$out" >/dev/null 2>&1; then
      if "$tree/bin/render-cron.sh" --root "$tree" --all >/dev/null 2>&1; then
        for b in "$tree"/cron/*.cron; do [ -f "$b" ] && cp "$b" "$out/$(basename "$b")"; done
      else rc=1; fi
    fi
  else rc=1; fi
  if [ -x "$tree/bin/lanes-build.sh" ]; then
    "$tree/bin/lanes-build.sh" --root "$tree" --to "$out/lanes.json" >/dev/null 2>&1 \
      || { "$tree/bin/lanes-build.sh" --root "$tree" >"$out/lanes.json" 2>/dev/null \
           && [ -s "$out/lanes.json" ]; } || { rm -f "$out/lanes.json"; rc=1; }
  else rc=1; fi
  if [ -x "$tree/bin/render-env-example.sh" ]; then
    "$tree/bin/render-env-example.sh" --root "$tree" --to "$out/global.env.example" >/dev/null 2>&1 \
      || { "$tree/bin/render-env-example.sh" --root "$tree" >"$out/global.env.example" 2>/dev/null \
           && [ -s "$out/global.env.example" ]; } || { rm -f "$out/global.env.example"; rc=1; }
  else rc=1; fi
  return $rc
}
render_into "$BTREE" "$OLD" || echo "render-diff.sh: NOTE — the base ($BASE) did not render completely; anything missing below reads as newly added." >&2
render_into "$ROOT"  "$NEW" || { echo "render-diff.sh: THIS TREE does not render — fix that before reading a diff of it." >&2; exit 2; }

# ---- the report -------------------------------------------------------------
# Repo-relative names, so a line in this output is a path a reader can act on.
repo_path() {
  case "$1" in
    lanes.json)        printf 'catalog/lanes.json' ;;
    global.env.example) printf 'env-templates/global.env.example' ;;
    *)                 printf 'cron/%s' "$1" ;;
  esac
}

NAMES=$( { ls -1 "$OLD" 2>/dev/null; ls -1 "$NEW" 2>/dev/null; } | LC_ALL=C sort -u )
[ -n "$NAMES" ] || { echo "render-diff.sh: neither side rendered anything — there is nothing to compare." >&2; exit 2; }

CHANGED=0
BODY=""
while IFS= read -r N; do
  [ -n "$N" ] || continue
  A="$OLD/$N"; B="$NEW/$N"
  [ -f "$A" ] || A=/dev/null
  [ -f "$B" ] || B=/dev/null
  cmp -s "$A" "$B" && continue
  CHANGED=$((CHANGED + 1))
  P=$(repo_path "$N")
  BODY="$BODY$(printf '===== %s =====\n' "$P")"$'\n'
  BODY="$BODY$(diff -u --label "a/$P" "$A" --label "b/$P" "$B" 2>/dev/null | tail -n +1)"$'\n\n'
done <<<"$NAMES"

echo "render-diff: what this tree changes about the files a box installs, against $BASE"
echo
if [ "$CHANGED" = 0 ]; then
  echo "No change: every rendered crontab, the lane registry and the env template are identical to $BASE."
  echo "($(printf '%s\n' "$NAMES" | grep -c .) rendered files compared.)"
  exit 0
fi
printf '%s' "$BODY"
echo "render-diff: $CHANGED of $(printf '%s\n' "$NAMES" | grep -c .) rendered files change."
echo "These files are GENERATED and not committed (BH-1247) — this diff is how they are reviewed."
exit 0
