#!/bin/bash
# bin/eject-clash-report.sh <owner/repo> [N=50] — which files do merge-queue
# ejections collide on? (BH-1679, BH-1669.3)
#
# Reads the last N ejections of <owner/repo> from logs/merge-conductor.log,
# pairs each ejected PR with the PR whose merge ejected it, and prints the
# files both changed, ranked by how many pairs share them:
#
#   path<TAB>pairs                     header
#   <path><TAB><count>                 count desc, then path asc
#   n/a<TAB><key>~#<culprit>           a pair whose file list could not be read
#   # repo=… ejections=E of_requested=N pairs=P unresolved=U unreadable=X log=…
#
# WHY. Before a file is declared generated (a repo's `## Generated files`
# table), measure which files the ejected→culprit pairs really share. Guessing
# declares the wrong ones.
#
# WHAT COUNTS AS AN EJECTION. The two lines merge-conductor.sh's settle pass
# logs, `<key> ejected from the merge queue on <head8> …` and
# `<key> EJECTED from the merge queue again on <head8> …`, plus the
# contract line `EJECTED_CONFLICT <key> <head>` (docs/MERGE-CONDUCTOR.md).
# One (PR, head8) is one ejection however many of those lines name it.
# The bare `ejected`/`reejected` marks in state/merge-conductor/attempts.txt
# are the same events with no order or time, so they are not read.
#
# THE CULPRIT. The newest mergify[bot] comment on the ejected PR that says
# "after #N merged" names it. Without one (or when the comments can't be read)
# it is the latest `MERGED <owner/repo>#M` logged before the ejection. With
# neither, the ejection is counted as unresolved and costs no file read.
#
# File lists come from REST pulls/<n>/files through gh_rest (up to 30 pages of
# 100, GitHub's cap), read once per PR per run. An unreadable list gives an
# n/a row, never a crash. Read-only: it keeps no state of its own.
#
# Env: HARNESS (default /root/harness), EJECT_CLASH_LOG (default
# $HARNESS/logs/merge-conductor.log).
# rc: 0 the log was read (zero ejections and n/a rows included), 1 the log is
# unreadable, 2 bad arguments, 75 the gh_rest library could not load.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
LIB="$HARNESS/bin/lib"
[ -r "$LIB/gh-rest.sh" ] || LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
. "$LIB/gh-rest.sh" || exit 75
. "$LIB/gh-rest-list.sh" || exit 75

usage() { echo "usage: eject-clash-report.sh <owner/repo> [N=50]" >&2; exit 2; }
SLUG="${1:-}"
N="${2:-50}"
[[ "$SLUG" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || usage
[[ "$N" =~ ^[0-9]+$ ]] && [ "$N" -gt 0 ] || usage

LOG="${EJECT_CLASH_LOG:-$HARNESS/logs/merge-conductor.log}"
[ -r "$LOG" ] && [ -f "$LOG" ] || { echo "eject-clash-report: cannot read $LOG" >&2; exit 1; }

W=$(mktemp -d "${TMPDIR:-/tmp}/eject-clash.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT

# One pass: "<n> <head8> <fallback culprit or ->", one line per distinct
# ejection, in log order; the last N kept.
awk -v k="$SLUG#" '
  function num(s) { if (index(s, k) != 1) return ""; s = substr(s, length(k) + 1); return (s ~ /^[0-9]+$/) ? s : "" }
  function add(n, h) {
    if (n == "" || h == "") return
    h = substr(h, 1, 8)
    if ((n SUBSEP h) in seen) return
    seen[n, h] = 1
    print n, h, (last == "" ? "-" : last)
  }
  {
    for (i = 1; i < NF; i++) {
      if ($i == "MERGED") { m = num($(i + 1)); if (m != "") last = m }
      else if ($i == "EJECTED_CONFLICT") add(num($(i + 1)), $(i + 2))
    }
    if (($4 == "ejected" || $4 == "EJECTED") && $5 == "from" && $6 == "the" && $7 == "merge" && $8 == "queue") {
      if ($9 == "on") add(num($3), $10)
      else if ($9 == "again" && $10 == "on") add(num($3), $11)
    }
  }' "$LOG" | tail -n "$N" > "$W/ejections"

# culprit <n> <fallback>: Mergify's "after #M merged" on the newest comment
# that says it, else the log fallback. Prints nothing when there is neither.
culprit() {
  local c=""
  gh_rest_issue_comments "$SLUG" "$1" 1000 > "$W/comments" || : > "$W/comments"
  [ -s "$W/comments" ] && c=$(jq -r '[.[]? | select((.user.login // "") == "mergify[bot]")
      | (.body // "") | capture("after #(?<n>[0-9]+) (was |has been |is )?merged"; "i") | .n] | last // empty' "$W/comments" 2>/dev/null)
  [ -n "$c" ] || c="$2"
  [ "$c" = "-" ] && c=""
  printf '%s' "$c"
}

# pr_files <n>: its changed paths, sorted, into $W/f.<n>; rc 1 when unreadable.
# Memoized, failure included, so a culprit shared by several pairs is read once.
pr_files() {
  local n="$1" p=1 c
  [ -e "$W/bad.$n" ] && return 1
  [ -e "$W/f.$n" ] && return 0
  : > "$W/raw.$n"
  while [ "$p" -le 30 ]; do
    gh_rest GET "repos/$SLUG/pulls/$n/files" -F per_page=100 -F "page=$p" > "$W/page" || { : > "$W/bad.$n"; return 1; }
    c=$(jq -r 'if type == "array" then length else error("not a list") end' "$W/page" 2>/dev/null) || { : > "$W/bad.$n"; return 1; }
    jq -r '.[].filename' "$W/page" >> "$W/raw.$n" || { : > "$W/bad.$n"; return 1; }
    [ "$c" -lt 100 ] && break
    p=$((p + 1))
  done
  LC_ALL=C sort -u "$W/raw.$n" > "$W/f.$n"
}

E=0; P=0; U=0; X=0
: > "$W/hits"; : > "$W/na"; : > "$W/pairs"
while read -r n _h fb; do
  E=$((E + 1))
  c=$(culprit "$n" "$fb")
  if [ -z "$c" ] || [ "$c" = "$n" ]; then U=$((U + 1)); continue; fi
  grep -qxF "$n~$c" "$W/pairs" && continue
  echo "$n~$c" >> "$W/pairs"
  P=$((P + 1))
  if pr_files "$n" && pr_files "$c"; then
    LC_ALL=C comm -12 "$W/f.$n" "$W/f.$c" >> "$W/hits"
  else
    X=$((X + 1))
    printf 'n/a\t%s#%s~#%s\n' "$SLUG" "$n" "$c" >> "$W/na"
  fi
done < "$W/ejections"

printf 'path\tpairs\n'
LC_ALL=C sort "$W/hits" | LC_ALL=C uniq -c | awk '{ c = $1; sub(/^ *[0-9]+ /, ""); printf "%s\t%s\n", $0, c }' \
  | LC_ALL=C sort -t "$(printf '\t')" -k2,2nr -k1,1
cat "$W/na"
printf '# repo=%s ejections=%s of_requested=%s pairs=%s unresolved=%s unreadable=%s log=%s\n' \
  "$SLUG" "$E" "$N" "$P" "$U" "$X" "$LOG"
exit 0
