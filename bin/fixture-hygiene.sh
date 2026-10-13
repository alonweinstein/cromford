#!/bin/bash
# bin/fixture-hygiene.sh check [--tree <dir>] [--base <ref>]
#   BH-5789: the lines a diff ADDS to test files carry no real-looking address
#   or secret. Fixtures use RFC 5737 addresses (192.0.2.x, 198.51.100.x,
#   203.0.113.x) and tokens with the word "fixture" in them
#   (prompts/build-discipline.md D64).
#
#   WHY. #5700 shipped 11 tailnet addresses in test fixtures, #5282 one, and
#   #4967's `TOKEN=tok-SECRET-…` broke merge batch #5770 for 3 PRs. The builder
#   had no gitleaks, so each leak showed up only in CI or the queue.
#
#   WHAT IT READS. Every line ADDED since `git merge-base <base> HEAD` (default
#   base origin/main) in a test file (tests/**, worker/*/test/**), plus every
#   line of an untracked test file. Lines already on the base are not judged.
#   A line carrying `fixture-hygiene-allow: <reason>` is skipped.
#
#   RULES, one finding each:
#     tailnet-ip   an address in 100.64/10 (an address followed by /<bits> is a CIDR, which names a
#                  range, not an address, and is not flagged; RFC1918 the same)
#     private-ip   an RFC1918 address: 10/8, 172.16/12, 192.168/16
#     secret       a token holding SECRET (e.g. `tok-SECRET-1`), or a
#                  `…TOKEN=<value>` / `…SECRET=<value>` whose literal value has no
#                  "fixture" in it (a `$variable` value is not a literal). A
#                  value under 8 chars, or one holding a placeholder word (x…,
#                  dummy, stub, test, fake, example, placeholder, changeme), is
#                  a stub, not a secret: `GH_TOKEN=x` passes.
#
#   OUTPUT: `<file>:<line>: <rule>: <text>` per finding, then one summary line.
#   rc 0 clean | 1 findings | 2 could not run (no tree, a base that does not
#   resolve, a diff that will not read). Never a pass on a run that read nothing.
set -uo pipefail
[ "${1:-}" = check ] || { echo "usage: bin/fixture-hygiene.sh check [--tree <dir>] [--base <ref>]" >&2; exit 2; }
shift
TREE="."; BASE="origin/main"
while [ $# -gt 0 ]; do
  case "$1" in
    --tree) TREE="${2:-}"; shift ;;
    --base) BASE="${2:-}"; shift ;;
    *) echo "fixture-hygiene: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
git -C "$TREE" rev-parse --git-dir >/dev/null 2>&1 || { echo "fixture-hygiene: $TREE is not a git tree" >&2; exit 2; }
MB=$(git -C "$TREE" merge-base "$BASE" HEAD 2>/dev/null) || { echo "fixture-hygiene: no merge base with '$BASE' in $TREE" >&2; exit 2; }

is_test() { case "$1" in tests/*|worker/*/test/*) return 0 ;; esac; return 1; }

# The added lines, as "<file>\t<line>\t<text>": the committed diff, the working
# tree's diff, and untracked test files.
ADDED=$(mktemp "${TMPDIR:-/tmp}/fixture-hygiene.XXXXXX") || exit 2
trap 'rm -f "$ADDED"' EXIT
git -C "$TREE" diff --no-renames -U0 "$MB" -- 'tests' 'worker/*/test' 2>/dev/null | awk '
  /^\+\+\+ / { f = substr($0, 7); next }
  /^@@ / { split($3, a, ","); n = substr(a[1], 2) + 0; next }
  /^\+/ { if (f != "") printf "%s\t%d\t%s\n", f, n, substr($0, 2); n++ }' > "$ADDED" \
  || { echo "fixture-hygiene: the diff against ${MB:0:12} did not read" >&2; exit 2; }
while IFS= read -r f; do
  is_test "$f" || continue
  awk -v f="$f" '{printf "%s\t%d\t%s\n", f, NR, $0}' "$TREE/$f" >> "$ADDED" 2>/dev/null
done < <(git -C "$TREE" ls-files --others --exclude-standard -- 'tests' 'worker/*/test' 2>/dev/null)

# No regex intervals ({1,3}) below: mawk 1.3.4-20240123, the awk on the boxes,
# panics on them ("REcompile() - panic"), and the lint then exits 2 on every input.
N=$(awk -F'\t' '
  BEGIN { IGNORECASE = 0; n = 0 }
  {
    f = $1; ln = $2; t = $0; sub(/^[^\t]*\t[^\t]*\t/, "", t)
    if (t ~ /fixture-hygiene-allow:[ \t]*[^ \t]/) next
    o = t
    # tailnet 100.64/10
    if (o ~ /(^|[^0-9.])100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9][0-9]?[0-9]?\.[0-9][0-9]?[0-9]?([^0-9./]|$)/) {
      printf "%s:%s: tailnet-ip: %s\n", f, ln, substr(o, 1, 160); n++ }
    # RFC1918
    if (o ~ /(^|[^0-9.])10\.[0-9][0-9]?[0-9]?\.[0-9][0-9]?[0-9]?\.[0-9][0-9]?[0-9]?([^0-9./]|$)/ \
     || o ~ /(^|[^0-9.])172\.(1[6-9]|2[0-9]|3[01])\.[0-9][0-9]?[0-9]?\.[0-9][0-9]?[0-9]?([^0-9./]|$)/ \
     || o ~ /(^|[^0-9.])192\.168\.[0-9][0-9]?[0-9]?\.[0-9][0-9]?[0-9]?([^0-9./]|$)/) {
      printf "%s:%s: private-ip: %s\n", f, ln, substr(o, 1, 160); n++ }
    # secrets: a SECRET-bearing token, or a TOKEN=/SECRET= literal value, with no "fixture"
    low = tolower(o); hit = 0
    if (low !~ /fixture/) {
      if (o ~ /[A-Za-z0-9]-SECRET-|SECRET-[A-Za-z0-9]|[a-z0-9]SECRET[a-z0-9-]/) hit = 1
      # A TOKEN=/SECRET= value counts only when it looks real: 8 chars or more,
      # and not a placeholder word (GH_TOKEN=x in a stub is not a leak).
      if (match(o, /[A-Za-z0-9_]*(TOKEN|SECRET)=["'\'']?[^"'\''$ \t;)]+/)) {
        v = substr(o, RSTART, RLENGTH); sub(/^[^=]*=["'\'']?/, "", v); lv = tolower(v)
        if (length(v) >= 8 && lv !~ /^x+$|dummy|stub|test|fake|fixture|example|placeholder|changeme/) hit = 1
      }
    }
    if (hit) { printf "%s:%s: secret: %s\n", f, ln, substr(o, 1, 160); n++ }
  }
  END { print n > "/dev/stderr" }' "$ADDED" 2>"$ADDED.n")
rc_n=$(cat "$ADDED.n" 2>/dev/null); rm -f "$ADDED.n"
[ -n "$N" ] && printf '%s\n' "$N"
LINES=$(grep -c . "$ADDED")
case "$rc_n" in ''|*[!0-9]*) echo "fixture-hygiene: the scan did not finish" >&2; exit 2 ;; esac
if [ "$rc_n" -gt 0 ]; then
  echo "fixture-hygiene: $rc_n finding(s) in $LINES added test line(s) since ${MB:0:12}: use RFC 5737 addresses (192.0.2.x, 198.51.100.x, 203.0.113.x) and put the word fixture in every fake token (D64)"
  exit 1
fi
echo "fixture-hygiene: clean ($LINES added test line(s) since ${MB:0:12})"
exit 0
