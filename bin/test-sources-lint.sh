#!/bin/bash
# bin/test-sources-lint.sh — a tests/*.sh must source its tests/lib/ helper in a
# way that cannot fail silently.
#
# The prevention half of the 2026-09-17 incident (bin/test-suite-run.sh is the
# diagnosis half): tests/checks-suite-test.sh sourced a tests/lib/ file that did
# not exist on main. The source failed, nothing handled it, `set -u` killed the
# script on the next $T, and CI reported an ordinary test failure.
#
# Two rules, both narrow on purpose:
#   1. the path must not be CWD-relative — a bare tests/lib/x.sh only resolves
#      when the suite happens to run from the repo root;
#   2. the source line must carry a same-line failure handler. ANY `||` counts:
#      about 28 suites deliberately degrade instead of exiting, and a handled
#      failure is not this incident's shape. A line continued with a trailing
#      `\` has no same-line handler by definition, so it is flagged.
#
# What it deliberately does NOT look at: sources of bin/lib/ helpers, sources of
# a variable it cannot resolve (`. "$1"`), and anything inside a heredoc body —
# several suites WRITE a broken source line into a fixture on purpose. A rule
# that drags two dozen unrelated suites into a diff is the wrong rule.
#
# Scanned: <root>/tests/*.sh and <root>/tests/mc/*.sh — the two suite dirs CI
# runs (#929). tests/lib/ itself is a helper dir, never a suite, and is not
# scanned.
#
# Usage:  bash bin/test-sources-lint.sh [root]     (default: this repo)
#
# Output: <file>:<line>: <reason>, one per offending line, sorted.
# Exit codes:
#   0  clean (silent)
#   1  offenders printed
#   2  could not scan — no tests/ dir, no suite in it, the awk pass died, or a
#      heredoc opened and never closed so the tail of a file was never read.
#      An empty answer from a scan that never happened is not a clean tree.
set -uo pipefail

# Defaults to the repo this script lives in, never to $PWD: the lint practices
# the rule it enforces.
ROOT=${1:-$(cd "$(dirname "$0")/.." && pwd)}
ROOT=${ROOT%/}

if [ ! -d "$ROOT/tests" ]; then
  echo "test-sources-lint: could not scan — no tests/ directory under $ROOT" >&2
  exit 2
fi

# The helpers that actually exist decide what "a path under tests/lib/" means,
# so `. "$(dirname "$0")/lib/scratch.sh"` is recognised and
# `. "$T/h/bin/lib/whatever.sh"` is not.
LIBS=
for l in "$ROOT"/tests/lib/*.sh; do
  [ -f "$l" ] || continue
  LIBS="$LIBS ${l##*/}"
done

# Both suite dirs, the explicit two-glob form the CI lint steps carry (#929):
# tests/mc/*.sh is a suite dir too, and a suite CI runs is a suite this lint
# has to have looked at.
FILES=()
for f in "$ROOT"/tests/*.sh "$ROOT"/tests/mc/*.sh; do
  [ -f "$f" ] || continue
  FILES+=("$f")
done
if [ "${#FILES[@]}" -eq 0 ]; then
  echo "test-sources-lint: could not scan — no suites matched $ROOT/tests/*.sh" >&2
  exit 2
fi

# No interval quantifiers ({n}) anywhere: /usr/bin/awk is mawk on Debian and on
# Ubuntu runners, and older mawk silently matches nothing with them — a pattern
# that quietly finds nothing is the failure this lint exists to prevent.
AWK_PROG='
function relof(f,   n) {
  n = length(rootslash)
  if (substr(f, 1, n) == rootslash) return substr(f, n + 1)
  return f
}
# A path under tests/lib/: either it says so literally, or it ends in
# /lib/<name>.sh for a helper that exists. bin/lib/ is never ours.
function is_tests_lib(p,   base) {
  if (index(p, "bin/lib/") > 0) return 0
  if (index(p, "tests/lib/") > 0) return 1
  if (p ~ /\/lib\/[^\/]+\.sh$/) {
    base = p
    sub(/^.*\//, "", base)
    if (base in LIB) return 1
  }
  return 0
}
# The first << on the line that is really an operator: one that is not inside a
# quoted string and not after a comment #. A << quoted in prose (an example in a
# header comment, a probe body printed inside a message) used to open a heredoc
# whose tag no line ever closed, and every line after it in that file was read
# as body — so the file went unscanned and the lint still said clean.
function hdopen(s,   i, n, ch, st, prev) {
  n = length(s); st = ""; prev = ""
  for (i = 1; i <= n; i++) {
    ch = substr(s, i, 1)
    if (st != "") { if (ch == st) st = ""; prev = ch; continue }
    if (ch == "\"" || ch == q) { st = ch; prev = ch; continue }
    if (ch == "#" && (i == 1 || prev == " " || prev == "\t" || prev == ";" || prev == "(" || prev == "&" || prev == "|")) return 0
    if (ch == "<" && substr(s, i + 1, 1) == "<") {
      if (substr(s, i + 2, 1) == "<") { i = i + 2; prev = "<"; continue }   # here-string
      return i
    }
    prev = ch
  }
  return 0
}
# The sourced argument: everything up to the first handler or redirect that is
# really a delimiter. A plain regex cut at the first && threw away the tail of
# `$(cd "$(dirname "$0")" && pwd)/lib/x.sh` — this repo'"'"'s standard absolute-path
# idiom — so an unguarded source written that way was never flagged. Only
# depth-0, unquoted delimiters cut.
function cutarg(s,   i, n, ch, st, depth, out) {
  n = length(s); st = ""; depth = 0; out = ""
  for (i = 1; i <= n; i++) {
    ch = substr(s, i, 1)
    if (st != "") { out = out ch; if (ch == st) st = ""; continue }
    if (ch == "\"" || ch == q) { st = ch; out = out ch; continue }
    if (ch == "$" && substr(s, i + 1, 1) == "(") { depth++; out = out "$("; i++; continue }
    if (ch == "(") { depth++; out = out ch; continue }
    if (ch == ")") { if (depth > 0) depth--; out = out ch; continue }
    if (depth == 0) {
      if (substr(s, i, 2) == "||" || substr(s, i, 2) == "&&") break
      if (ch == ";" || ch == "<" || ch == ">") break
      if (ch ~ /^[0-9]$/ && (substr(s, i + 1, 1) == "<" || substr(s, i + 1, 1) == ">")) break
    }
    out = out ch
  }
  return out
}
# A heredoc that never closes means the rest of that file was not scanned. Say
# so on stderr and make the whole pass rc 2: the same fail-closed answer a
# missing tests/ dir gets, for the same reason.
function unterm_report(f, l, t) {
  printf "%s:%d: unterminated heredoc tag %s — the rest of the file was not scanned\n", relof(f), l, t > "/dev/stderr"
  unterm = 1
}
BEGIN {
  n = split(libs, L, " ")
  for (i = 1; i <= n; i++) if (L[i] != "") LIB[L[i]] = 1
  rootslash = root "/"
  q = sprintf("%c", 39)   # a single quote, unwritable inside this program
}
FNR == 1 {
  if (hd) unterm_report(prevfile, tagline, tag)
  hd = 0; tag = ""; tagline = 0; dash = 0
}
{
  prevfile = FILENAME
  line = $0

  # ── heredoc bodies are data, not sourcing ─────────────────────────────────
  if (hd) {
    body = line
    if (dash) sub(/^\t+/, "", body)
    if (body == tag) hd = 0
    next
  }

  # ── the source line ───────────────────────────────────────────────────────
  if (line ~ /^[ \t]*(\.|source)[ \t]+/) {
    rest = line
    sub(/^[ \t]*/, "", rest)
    sub(/^(\.|source)[ \t]+/, "", rest)
    # The argument runs up to the first handler or redirect. Splitting on
    # whitespace would cut `"$(dirname "$0")/lib/x.sh"` in half at its own
    # inner quote, which is the shape almost every suite uses; a regex cut at
    # the first && or ; would cut `$(cd ... && pwd)/lib/x.sh` in half inside its
    # own command substitution. cutarg() cuts only at a depth-0 delimiter.
    arg = cutarg(rest)
    after = substr(rest, length(arg) + 1)
    sub(/[ \t]+$/, "", arg)
    # A line continued with a trailing backslash carries its handler, if any, on
    # the NEXT line, which this line-at-a-time pass never sees. Rule 2 is a
    # SAME-line handler, so a continuation counts as none. The backslash has to
    # come off the argument first: left on, it matched no tests/lib/ shape, so
    # the line was examined by neither rule and passed in silence.
    if (arg ~ /\\$/) { sub(/\\$/, "", arg); sub(/[ \t]+$/, "", arg) }
    p = arg
    if (length(p) > 1) {
      c1 = substr(p, 1, 1)
      c2 = substr(p, length(p), 1)
      if ((c1 == "\"" && c2 == "\"") || (c1 == q && c2 == q)) p = substr(p, 2, length(p) - 2)
    }
    if (is_tests_lib(p)) {
      if (p ~ /^tests\// || p ~ /^\.\// || p ~ /^\.\.\// || p ~ /^lib\//)
        printf "%s:%d: cwd-relative path: %s\n", relof(FILENAME), FNR, p
      else if (index(after, "||") == 0)
        printf "%s:%d: no failure handler (add \"|| exit 1\" or a fallback)\n", relof(FILENAME), FNR
    }
  }

  # ── does this line OPEN a heredoc? ────────────────────────────────────────
  i = hdopen(line)
  if (i > 0) {
    tail = substr(line, i + 2)
    dash = 0
    if (substr(tail, 1, 1) == "-") { dash = 1; tail = substr(tail, 2) }
    sub(/^[ \t]+/, "", tail)
    c1 = substr(tail, 1, 1)
    if (c1 == "\"" || c1 == q) tail = substr(tail, 2)
    # Any run of non-delimiter characters is a tag: the repo uses <<'"'"'@PY@'"'"'-style
    # tags, and a tag the header regex cannot see leaves a body scanned as shell.
    if (match(tail, /^[^ \t"'"'"'`;)&|<>]+/)) {
      tag = substr(tail, 1, RLENGTH)
      tagline = FNR
      hd = 1
    }
  }
}
END {
  if (hd) unterm_report(prevfile, tagline, tag)
  if (unterm) exit 3
}
'

OUT=$(awk -v root="$ROOT" -v libs="$LIBS" "$AWK_PROG" "${FILES[@]}"); ARC=$?
if [ "$ARC" -eq 3 ]; then
  # Whatever it DID find is still worth printing, but the answer is incomplete,
  # so it is never a clean tree and never a plain offender list.
  [ -n "$OUT" ] && printf '%s\n' "$OUT" | sort -t: -k1,1 -k2,2n
  echo "test-sources-lint: could not scan — an unterminated heredoc (named above) hid the rest of a file" >&2
  exit 2
fi
if [ "$ARC" -ne 0 ]; then
  echo "test-sources-lint: could not scan — the awk pass exited $ARC" >&2
  exit 2
fi

[ -n "$OUT" ] || exit 0
printf '%s\n' "$OUT" | sort -t: -k1,1 -k2,2n
exit 1
