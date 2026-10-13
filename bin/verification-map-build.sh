#!/bin/bash
# bin/verification-map-build.sh — docs/verification-map/README.md is an artifact,
# and since BH-1175 it is not committed.
#
#   verification-map-build.sh [--repo <path>]          regenerate the README
#   verification-map-build.sh --check [--repo …]       validate the committed SOURCES
#   verification-map-build.sh --check-committed [--repo …]
#                                                      the OLD byte comparison,
#                                                      for a repo that still
#                                                      COMMITS its index
#
# WHY IT IS NO LONGER COMMITTED (BH-1175). A generated file that is committed is
# a shared mutable cell that every build writes. This one was in 105 of the last
# 200 merges to main; it conflicted on every rebase of the 2026-09-20 drain; and
# it turned main RED three times in one day, because the `merge=union` driver
# glued one squash merge's table onto another's, produced a duplicated row, and
# the drift check then refused the result (e71b2de1, dd2cee5a, 855c0b42). The
# union attribute was the best available answer while the file had to be in git.
# Taking the file OUT of git removes the contested cell instead of resolving it.
#
# So the path is git-ignored, this script still writes it (CI, the share mirror
# and every box regenerate it), and `--check` stops comparing bytes — there is
# nothing committed to compare against. It validates what IS committed:
#
#   * every entry file parses (each non-blank line is one complete table row),
#   * no two entry files produce the SAME row (the main-red shape above — a
#     byte comparison could never see it, because a duplicated row regenerates
#     to itself),
#   * every entry's document link resolves to a file that exists,
#   * no README is TRACKED in git — whether or not .gitignore still covers it,
#     because a PR that drops the ignore line and forces the file in must not be
#     able to switch its own gate off.
#
# tests/verification-map-no-commit-test.sh drives all four against real git.
#
# WHY. Until BH-798 every build that added a feature entry hand-edited the same
# table in the same file. Two of those in flight at once conflict on a file
# neither ticket is about, and the committed table had already picked up a stray
# blank line in the middle of it — which splits a markdown table in two, so the
# last rows stopped rendering as a table at all. Nobody noticed, because nothing
# could.
#
# So the README stops being a source. The sources are:
#
#   docs/verification-map/index/head.md          the title and the intro
#   docs/verification-map/entries/<KEY>.md       one file per TICKET, holding
#                                                that ticket's table row(s)
#   docs/verification-map/index/tail.md          the ## Driving conventions
#
# and this script concatenates them: banner, head, the table with every entry
# file's rows in natural key order, tail. A build writes its own entry file and
# re-runs this; two builds touch two different new files and never conflict.
#
# WHY THE SOURCES LIVE IN SUBDIRECTORIES. bin/verification-map.sh counts the
# map's feature entries with `find … -maxdepth 1 -type f -name '*.md'` and lists
# them in every project primer. A head.md or an entries/ file sitting at the map
# root would be counted and listed as if it were a feature, making the entry
# count quoted downstream wrong by the number of sources. -maxdepth 1 -type f
# never descends, so index/ and entries/ are invisible to it — that is the whole
# reason for the extra directory level, and moving them up breaks a neighbour.
#
# WHY THE BANNER IS A BLOCKQUOTE AND NOT A HEADING. bin/batch-resolve.sh finds a
# repo's regenerate table by matching `^#+ …generated files` headings, and a repo
# that declares one has its batch merge train switched ON. Since BH-865 this repo
# declares exactly one such table, and it is a SOURCE line in index/tail.md that
# this script carries into the README — so the banner must still never be a
# heading, or "GENERATED — do not edit by hand" would be read by that lane as the
# start of the table and the row list would be whatever followed it.
# tests/verification-map-build-test.sh pins both halves: blockquote banner,
# declared table.
#
# THREE OUTCOMES, NEVER TWO:
#   rc 0  generated (or, with --check, the sources are valid)
#   rc 1  --check only: the sources are readable but WRONG — a duplicated row, a
#         document link that resolves to nothing, or a README that is tracked in
#         git. Each one names the file it is about.
#   rc 2  a source is missing, or an entry file holds a line that is not a table
#         row. The README is NEVER written on this path — the file is composed
#         into a temp file in the same directory and moved into place only after
#         every source validated, so a refused run leaves the old index intact
#         rather than a half-written one.
set -uo pipefail

SELF_NAME=verification-map-build
REL=docs/verification-map

usage() {
  echo "usage: $SELF_NAME.sh [--check|--check-committed] [--repo <path>]" >&2
  exit 2
}
die2() { echo "$SELF_NAME: $1" >&2; exit 2; }

SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
REPO_DEFAULT=$(cd "$(dirname "$SELF")/.." 2>/dev/null && pwd)

CHECK=0
CHECK_COMMITTED=0
REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    --check-committed) CHECK=1; CHECK_COMMITTED=1; shift ;;
    --repo)
      [ $# -ge 2 ] || { echo "$SELF_NAME: --repo needs a path" >&2; usage; }
      REPO="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "$SELF_NAME: unknown argument $1" >&2; usage ;;
  esac
done
REPO="${REPO:-$REPO_DEFAULT}"
[ -n "$REPO" ] || die2 "cannot resolve a repo root (pass --repo <path>)"
MAP="$REPO/$REL"

# ── preconditions: a missing source is rc 2, never a README with a hole in it ─
[ -d "$MAP" ]                || die2 "$REL is missing under $REPO"
[ -r "$MAP/index/head.md" ]  || die2 "$REL/index/head.md is missing or unreadable"
[ -r "$MAP/index/tail.md" ]  || die2 "$REL/index/tail.md is missing or unreadable"
[ -d "$MAP/entries" ]        || die2 "$REL/entries is missing — each build writes its own $REL/entries/<TICKET-KEY>.md"

# Natural sort, not lexical: the keys are BH-<n>, and a lexical sort puts BH-1000
# above BH-999 forever. LC_ALL=C so a box's locale cannot reorder the table.
ENTRY_FILES=$(find "$MAP/entries" -maxdepth 1 -type f -name '*.md' 2>/dev/null \
  | sed 's|.*/||' | LC_ALL=C sort -V)
[ -n "$ENTRY_FILES" ] || die2 "$REL/entries holds no *.md entry files"

# ── collect and validate the rows ────────────────────────────────────────────
# Every non-blank line of an entry file is one complete markdown table row. A
# line that is not one is a mistake that would silently deform the table, so it
# is named by file:line and refused.
#
# ROWMAP carries "<entry file>\t<row>" for every row, and exists only so the
# --check verdicts below can NAME the file a bad row came from. A refusal that
# says "a duplicate row" without saying which of 112 files holds it is a refusal
# somebody has to bisect by hand.
ROWS=""
ROWMAP=""
NFILES=0
NROWS=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  NFILES=$((NFILES + 1))
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [ -z "${line//[[:space:]]/}" ] && continue
    case "$line" in
      '|'*) ROWS="$ROWS$line"$'\n'; ROWMAP="$ROWMAP$f"$'\t'"$line"$'\n'; NROWS=$((NROWS + 1)) ;;
      *) die2 "$REL/entries/$f:$n is not a table row (every non-blank line in an entry file is one complete | … | row)" ;;
    esac
  done < "$MAP/entries/$f"
done <<< "$ENTRY_FILES"
[ "$NROWS" -gt 0 ] || die2 "$REL/entries holds no table rows"

# ── compose ──────────────────────────────────────────────────────────────────
# WRITE mode keeps its scratch file beside the target, because the publish at
# the bottom is a same-filesystem `mv` and that is what makes it atomic; on that
# path the rename consumes the file and the trap is cleared, so nothing is ever
# deleted inside the tree. CHECK mode never renames — it composes, compares and
# exits through the trap — so its scratch file has no reason to sit in the repo
# at all. It used to, and the `rm -f` of `docs/verification-map/.vmap-build.*`
# was reported by bin/test-trace-safety.sh as a deletion outside the allowed
# temp roots (3 hits, #463's own CI job). A temp root is where a temp file goes.
if [ "$CHECK" = 1 ]; then
  TMP=$(mktemp "${TMPDIR:-/tmp}/vmap-build.XXXXXX") || die2 "cannot create a temp file in ${TMPDIR:-/tmp}"
else
  TMP=$(mktemp "$MAP/.vmap-build.XXXXXX") || die2 "cannot create a temp file in $REL"
fi
trap 'rm -f "$TMP"' EXIT INT TERM

{
  printf '%s\n' \
    '> **GENERATED — do not edit by hand, and do not commit.** `bin/verification-map-build.sh` builds this file from' \
    "> \`$REL/index/head.md\`, \`$REL/index/tail.md\` and \`$REL/entries/<TICKET-KEY>.md\`." \
    '> A build writes its own `entries/<TICKET-KEY>.md` and commits THAT; this index is git-ignored (BH-1175).'
  echo
  cat "$MAP/index/head.md"
  echo
  echo '| feature | entry | primary lane |'
  echo '|---|---|---|'
  printf '%s' "$ROWS"
  echo
  cat "$MAP/index/tail.md"
} > "$TMP" || die2 "could not compose $REL/README.md"
[ -s "$TMP" ] || die2 "composed an empty $REL/README.md — refusing to write it"

# ── check mode: validate the SOURCES, report, never repair ───────────────────
# A check that fixes what it was asked to report makes the problem invisible,
# which is the one thing CI's step must not do — so nothing below writes.
#
# There is deliberately no byte comparison against a committed README any more.
# Since BH-1175 the index is not committed, so "the file on disk differs from
# its sources" is not a defect, it is a tree that has not been regenerated yet —
# and every reader regenerates before it reads. What IS a defect is a source
# that would generate a WRONG index, and that is what these four verdicts are.
if [ "$CHECK" = 1 ] && [ "$CHECK_COMMITTED" = 1 ]; then
  # --check-committed: the OLD byte comparison, kept for the repos and the lanes
  # that still have a committed index to compare against.
  #
  # WHO NEEDS IT. mc_resolve_vmap_clean_merge and bin/verification-map-retrofit.sh
  # repair a README that git's union driver glued together on a repo that COMMITS
  # its index. Their trigger is "this file does not rebuild to itself" — a
  # statement about bytes. Plain --check stopped answering that with BH-1175, so
  # pointing those two at it would have left them permanently answering "nothing
  # to repair" on the repos that still need the repair: a lane switched off by a
  # change to a neighbour, which is the failure mode this repo keeps meeting.
  # cromford itself reaches neither path (no committed index, no union
  # attribute), so this mode exists for target repos, not for here.
  if [ -f "$MAP/README.md" ] && cmp -s "$MAP/README.md" "$TMP"; then
    echo "$SELF_NAME: $REL/README.md is in sync ($NFILES entry files, $NROWS rows)"
    exit 0
  fi
  if [ -f "$MAP/README.md" ]; then
    echo "$SELF_NAME: $REL/README.md does not match its sources (committed vs generated):" >&2
    diff -u "$MAP/README.md" "$TMP" 2>/dev/null | head -80 >&2
  else
    echo "$SELF_NAME: $REL/README.md does not exist, and --check-committed was asked for the committed copy." >&2
  fi
  echo "$SELF_NAME: run bin/verification-map-build.sh and commit the result." >&2
  exit 1
fi

if [ "$CHECK" = 1 ]; then
  BAD=0

  # 1. a TRACKED README, full stop. The .gitignore is the fence; this is the
  #    gate. A stale branch or a `git add -f` puts the contested cell back, and
  #    the ticket that removed it is named so the next reader does not have to
  #    go looking for why.
  #
  #    IT DOES NOT ALSO REQUIRE THE IGNORE RULE, and that is deliberate. The
  #    first cut refused only "tracked AND ignored", which left the obvious way
  #    back in wide open: a PR that DELETES the .gitignore line and `git add -f`s
  #    the index passes, and main is quietly committing the file again with
  #    every lane built around it still assuming otherwise. A gate whose subject
  #    can delete the gate is not a gate.
  #
  #    The cost is that a repo which deliberately COMMITS its generated index
  #    (the pre-BH-1175 layout, which no repo in this fleet ships today — none
  #    of them carries this script at all) is refused by --check. That repo's
  #    mode is --check-committed, which answers the question it is actually
  #    asking: do the committed bytes match the sources. The two modes disagree
  #    on such a repo ON PURPOSE.
  if command -v git >/dev/null 2>&1 && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    if [ -n "$(git -C "$REPO" ls-files -- "$REL/README.md" 2>/dev/null)" ]; then
      echo "$SELF_NAME: $REL/README.md is TRACKED in git. It is GENERATED and must not be committed (BH-1175):" >&2
      echo "$SELF_NAME:   git rm --cached $REL/README.md   — the sources are $REL/entries/ and $REL/index/" >&2
      if ! git -C "$REPO" check-ignore -q --no-index -- "$REL/README.md" 2>/dev/null; then
        echo "$SELF_NAME:   and .gitignore no longer covers it — restore that line too, or the next build commits it again" >&2
      fi
      BAD=1
    fi
  fi

  # 2. duplicate rows. This is the shape of the three main-red freezes of
  #    2026-09-20: the union merge driver glued two generated tables together
  #    and a row appeared twice. A duplicated row regenerates to itself, so the
  #    old byte comparison could not see it even while the README was committed.
  DUPES=$(printf '%s' "$ROWMAP" | awk -F'\t' 'NF>=2 {
      row = $0; sub(/^[^\t]*\t/, "", row)
      if (row in seen) { if (!(row in said)) { print seen[row] "\t" $1 "\t" row; said[row] = 1 } }
      else seen[row] = $1
    }')
  if [ -n "$DUPES" ]; then
    echo "$SELF_NAME: the same table row is produced by more than one entry file (duplicate rows, BH-1175):" >&2
    printf '%s\n' "$DUPES" | while IFS=$'\t' read -r a b row; do
      echo "$SELF_NAME:   $REL/entries/$a and $REL/entries/$b both produce: $row" >&2
    done
    BAD=1
  fi

  # 3. every entry's document link resolves. The index is a table of links; a
  #    link to a file that is not there is a dead end a reader finds and a byte
  #    comparison never did. Only repo-local links are checked — an http link is
  #    not this script's business, and an anchor-only link has no file.
  DEAD=$(printf '%s' "$ROWMAP" | awk -F'\t' 'NF>=2 {
      file = $1; row = $0; sub(/^[^\t]*\t/, "", row)
      while (match(row, /\]\([^)]+\)/)) {
        t = substr(row, RSTART + 2, RLENGTH - 3)
        row = substr(row, RSTART + RLENGTH)
        if (t ~ /^[a-zA-Z][a-zA-Z0-9+.-]*:/) continue
        if (t ~ /^#/) continue
        sub(/#.*$/, "", t)
        if (t == "") continue
        print file "\t" t
      }
    }' | sort -u)
  if [ -n "$DEAD" ]; then
    MISSING=""
    while IFS=$'\t' read -r file target; do
      [ -n "$target" ] || continue
      [ -e "$MAP/$target" ] && continue
      MISSING="$MISSING$file"$'\t'"$target"$'\n'
    done <<< "$DEAD"
    if [ -n "$MISSING" ]; then
      echo "$SELF_NAME: an entry links a document that does not exist under $REL/:" >&2
      printf '%s' "$MISSING" | while IFS=$'\t' read -r file target; do
        [ -n "$target" ] || continue
        echo "$SELF_NAME:   $REL/entries/$file links $target — no such file" >&2
      done
      BAD=1
    fi
  fi

  if [ "$BAD" != 0 ]; then
    echo "$SELF_NAME: the sources are what is committed, so fix them — the index itself is generated and ignored." >&2
    exit 1
  fi
  echo "$SELF_NAME: $REL sources are valid ($NFILES entry files, $NROWS rows); $REL/README.md is generated, not committed"
  exit 0
fi

mv "$TMP" "$MAP/README.md" || die2 "could not write $REL/README.md"
trap - EXIT INT TERM
echo "$SELF_NAME: wrote $REL/README.md ($NFILES entry files, $NROWS rows)"
exit 0
