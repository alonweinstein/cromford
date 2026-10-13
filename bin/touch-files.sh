#!/bin/bash
# bin/touch-files.sh — the files a plan DECLARES it will touch, read from its
# `## Files to touch` section and nothing else.
#
# WHY. bin/planned-files.sh scans the whole plan.md for path tokens: a
# conservative superset that the size gate, the scope gate and the test-home
# check want. The overlap guard and the claim used the same superset, so a path
# a plan cites only as caller evidence, as a check, or under "Not touched" sat
# on both sides of every compare, and builds deferred on a file nobody planned
# to change. This list is what bin/plan-overlap.sh, bin/plan-sibling.sh,
# bin/conflict-check.sh and the `# >>> touch claim` region of
# bin/lib/rb/plan.sh judge and publish when the plan declares one.
#
# usage: touch-files.sh <build-dir> [project]   (always exit 0; project is
#        accepted so every caller passes the same pair, and is not read)
# writes, beside plan.md:
#   touch-files.txt  one path per line, sort -u (only when touch-source=declared)
#   touch-files.src  path<TAB>L<n><TAB>touch|excluded, one row per occurrence
#   touch-source     declared | none (no section, or no touch path in it) | off
# Anything but `declared` removes touch-files.txt, and every caller then reads
# planned-files.txt exactly as before.
#
# KILL SWITCH: PLAN_TOUCH_DECLARED=0|off|false|no, or the settings row
# switch.plan-touch-off[.<box>] (lane_switch, catalog/switches.d/plan-touch-off.json).
#
# THE SECTION. A heading whose text contains "files to touch", up to the next
# heading of the same or a higher level. Only ITEM lines claim: a table row
# (paths from its first cell) or a list item (paths from its lead segment, up
# to the first ` — `, ` – `, ` -- `, ` - ` or `: `, after a `<words>: ` label
# with no backtick and no `/`). An item is excluded when its label says "not
# touched", "read only", "do not edit" and the like, or the text after its lead
# STARTS with one, or a negative deeper heading or a negative `<label>:` line
# above it put the section in exclude mode. One path in an item is excluded
# when the note right after it starts with a negative (`x` (read only)). A prose line that
# starts with "Not touched" / "Do not" / "Never" records its paths as
# excluded. A path that is both claimed and excluded stays claimed: missing a
# file costs a merge conflict, listing one too many costs a wait.
set -uo pipefail
BUILD="${1:?build dir}"
HARNESS="${HARNESS:-/root/harness}"
export HARNESS
[ -d "$BUILD" ] || exit 0
PLAN="$BUILD/plan.md"
TXT="$BUILD/touch-files.txt"; SRC="$BUILD/touch-files.src"; WHY="$BUILD/touch-source"

put() { # put <file> <content-from-stdin> — temp file + mv, so no reader sees half a file
  local tmp
  tmp=$(mktemp "$1.XXXXXX" 2>/dev/null) || return 0
  cat > "$tmp" && mv -f "$tmp" "$1" 2>/dev/null || rm -f "$tmp"
}
verdict() { rm -f "$TXT"; [ "$1" = off ] && rm -f "$SRC"; printf '%s\n' "$1" | put "$WHY"; exit 0; }

case "$(printf '%s' "${PLAN_TOUCH_DECLARED:-1}" | tr '[:upper:]' '[:lower:]')" in
  0|off|false|no) verdict off ;;
esac
# A missing lib is not off: the declared set is the default.
# shellcheck source=lib/lane-switch.sh
if . "$(dirname "$0")/lib/lane-switch.sh" 2>/dev/null && command -v lane_switch >/dev/null 2>&1; then
  lane_switch plan-touch-off 2>/dev/null && verdict off
fi
[ -s "$PLAN" ] || verdict none

# mawk-safe: no IGNORECASE, no gensub, no \s.
ROWS=$(awk '
function neg(s,  t) {
  t = tolower(s)
  return (t ~ /not touched|untouched|do not (edit|touch)|don.t (edit|touch)|never (edit|touch)|no change|unchanged|read[- ]only|reference only|not edited|not modified/)
}
# negstart <text> — rc-true when the text STARTS with a negative, after leading
# punctuation: "not touched; read only", "(read only)", "| unchanged |". A
# negative later in a note ("keep helper() unchanged") is about something else.
function negstart(s,  t) {
  t = tolower(s)
  sub(/^[^a-z0-9]+/, "", t)
  return (t ~ /^(not touched|untouched|do not (edit|touch)|don.t (edit|touch)|never (edit|touch)|no change|unchanged|read[- ]only|reference only|not edited|not modified)/)
}
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function norm(t) {
  t = trim(t)
  sub(/^\.\//, "", t)
  sub(/:[0-9]+(-[0-9]+)?$/, "", t)
  sub(/\/\*\*$/, "", t)
  sub(/\/+$/, "", t)
  return t
}
function valid(t,  n, i, seg, last) {
  if (t == "" || index(t, "://") || t ~ /[<>*{} ]/ || t ~ /^\//) return 0
  n = split(t, seg, "/")
  for (i = 1; i <= n; i++) if (seg[i] == "..") return 0
  last = seg[n]
  return (n > 1 || last ~ /[^.]\.[A-Za-z0-9]+$/)
}
function emit(t, x,  kind) {
  kind = x ? "excluded" : "touch"
  t = norm(t)
  if (valid(t)) printf "%s\tL%d\t%s\n", t, NR, kind
}
# paths <segment> <x> — every path in the segment; x=1 excludes them all. With
# x=0 a path is excluded when the segment starts with a negative, or when the
# note right after that path (up to the next backtick span) does.
function paths(seg, x,  n, i, a, t) {
  if (index(seg, "`")) {
    n = split(seg, a, "`")
    if (negstart(a[1])) x = 1
    for (i = 2; i <= n; i += 2) emit(a[i], x || negstart(a[i + 1]))
    return
  }
  while (match(seg, /[A-Za-z0-9_@().\/+-]+/)) {
    t = substr(seg, RSTART, RLENGTH)
    seg = substr(seg, RSTART + RLENGTH)
    sub(/[.]+$/, "", t)
    if (t ~ /^\(/ && t !~ /\)/) t = substr(t, 2)
    if (t ~ /\)$/ && t !~ /\(/) t = substr(t, 1, length(t) - 1)
    emit(t, x || negstart(seg))
  }
}
# lead <text> — sets LEAD and AFTER at the first lead separator.
function lead(s,  seps, n, i, p, best, bl) {
  n = split(" — | – | -- | - |: ", seps, "|")
  best = 0
  for (i = 1; i <= n; i++) {
    p = index(s, seps[i])
    if (p && (!best || p < best)) { best = p; bl = length(seps[i]) }
  }
  if (best) { LEAD = substr(s, 1, best - 1); AFTER = substr(s, best + bl) }
  else { LEAD = s; AFTER = "" }
}
/^[ \t]*(```|~~~)/ { fence = !fence; next }
fence { next }
/^#+[ \t]/ {
  match($0, /^#+/); lvl = RLENGTH; t = tolower($0)
  if (insec && lvl > seclvl) { excl = neg(t); next }
  insec = 0
  if (t ~ /files to touch/) { insec = 1; seclvl = lvl; excl = 0 }
  next
}
!insec { next }
/^[ \t]*\|/ {
  n = split($0, c, "|")
  cell = trim(c[2])
  if (cell ~ /^[ \t:-]*$/) next
  h = tolower(cell)
  if (h == "file" || h == "files" || h == "path" || h == "paths") next
  rest = ""
  for (i = 3; i <= n; i++) rest = rest c[i] " "
  paths(cell, excl || negstart(rest))
  next
}
/^[ \t]*([-*+]|[0-9]+[.)])[ \t]+/ {
  s = $0
  sub(/^[ \t]*([-*+]|[0-9]+[.)])[ \t]+/, "", s)
  label = ""
  p = index(s, ": ")
  if (p && substr(s, 1, p - 1) !~ /[`\/]/) { label = substr(s, 1, p - 1); s = substr(s, p + 2) }
  lead(s)
  paths(LEAD, excl || neg(label) || negstart(AFTER))
  next
}
{
  s = tolower($0); sub(/^[ \t*_]+/, "", s)
  if (s ~ /^(not touched|confirmed, not touched|untouched|do not|don.t|never)/ && neg(s)) {
    paths($0, 1)
  }
  e = $0; sub(/[ \t*_]+$/, "", e)
  if (e ~ /:$/) excl = neg(e)
}
' "$PLAN" 2>/dev/null)

printf '%s\n' "$ROWS" | grep -v '^$' | put "$SRC"
TOUCH=$(printf '%s\n' "$ROWS" | awk -F'\t' '$3=="touch"{print $1}' | sort -u | awk -F/ '/\./ || NF>=3')
[ -n "$TOUCH" ] || verdict none
printf '%s\n' "$TOUCH" | put "$TXT"
printf 'declared\n' | put "$WHY"
exit 0
