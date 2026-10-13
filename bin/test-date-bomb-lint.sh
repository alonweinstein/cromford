#!/bin/bash
# bin/test-date-bomb-lint.sh [--base <ref>] [--all] [root]
#
# The fixture time-bomb lint (BH-3477, built in BH-3512): added test-file lines
# that put a hard-coded date on a deadline-shaped key, so the test goes red on
# its own once the real clock passes that date.
#
# WHY: #3414. tests/triage-state-client-test.sh carried
# next_recheck_at:"2026-09-29T10:00:00Z". At 10:00Z that day the real clock
# passed it, the case went red ON MAIN and every open PR inherited the red
# until 35657019b moved it to 2099. The rule: a fixed date on a deadline key is
# fine only as an input to the code under test, or at a year that never comes.
#
#   --base <ref>  judge the lines added since the merge-base of <ref> and HEAD,
#                 working-tree edits included (default: origin/main).
#   --all         judge every line of every selected file (an inventory; no git).
#   root          the checkout to scan (default: the current directory).
#   rc 0 clean
#   rc 1 findings, one per stdout line: `<path>:<line>: fixture-timebomb: ...`
#        (the count goes to stderr)
#   rc 2 bad args, no conf, not a git work tree, or unresolvable base
#
# WHAT IT FLAGS: `<deadline key><sep><ISO date>` (conf `key_re` + `date_re`)
# whose year is in [floor_year, max_safe_year). Each date on a line is judged
# on its own.
# WHAT MAKES IT QUIET:
#   - a year >= max_safe_year (2099), or before floor_year (2025): "already due"
#   - the line matches `input_re` (--now, --at, now=, NOW=, as_of ...): the date
#     is the code's clock, not a deadline the real clock will reach
#   - the file pins the clock at HEAD (a `pin` line of determinism-lint.conf)
#   - the line carries `# determinism: ok <reason>` (or `//`), reason of 3+
#     chars. A waiver with no reason is ignored and the line is still reported.
#
# BLIND SPOTS (not caught, by design of a line lint):
#   - a date reaching the clock through a variable (D=2026-...; ... "$D")
#   - `new Date('...')` or any date with no deadline key right before it
#   - key and date on different lines
#   - camelCase keys (nextRecheckAt): key_re is lower-snake only
#   - non-ISO dates (epoch seconds, 09/29/2026)
#   - in diff mode, a bomb that was already there before the fork (use --all)
#
# Patterns and thresholds live in catalog/date-bomb-lint.conf:
#   $DATE_BOMB_LINT_CONF > $HARNESS/flags/date-bomb-lint.conf
#   > <checkout>/catalog/date-bomb-lint.conf > $HARNESS/catalog/date-bomb-lint.conf
# Which files are test files (`file`, `skip`) and what pins the clock (`pin`)
# come from catalog/determinism-lint.conf, resolved the same way with
# $DETERMINISM_LINT_CONF. One source; not repeated in this lint's conf.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKOUT="$(cd "$SELF_DIR/.." && pwd)"

die2() { echo "test-date-bomb-lint: $*" >&2; exit 2; }

BASE=origin/main; ALL=0; ROOT_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0"; exit 0 ;;
    --base) [ $# -ge 2 ] && [ -n "$2" ] || die2 "--base needs a ref"; BASE=$2; shift 2 ;;
    --all) ALL=1; shift ;;
    -*) die2 "unexpected argument $1" ;;
    *)
      [ -z "$ROOT_ARG" ] || die2 "unexpected argument $1"
      [ -d "$1" ] || die2 "root $1 is not a directory"
      ROOT_ARG=$1; shift ;;
  esac
done
ROOT=$(cd "${ROOT_ARG:-.}" && pwd) || die2 "cannot enter root ${ROOT_ARG:-.}"

# ── the confs, or nothing ────────────────────────────────────────────────────
CONF=""
for C in "${DATE_BOMB_LINT_CONF:-}" "$H/flags/date-bomb-lint.conf" \
         "$CHECKOUT/catalog/date-bomb-lint.conf" "$H/catalog/date-bomb-lint.conf"; do
  [ -n "$C" ] && [ -r "$C" ] && { CONF="$C"; break; }
done
[ -n "$CONF" ] || die2 "no conf found (tried \$DATE_BOMB_LINT_CONF, $H/flags/date-bomb-lint.conf, $CHECKOUT/catalog/date-bomb-lint.conf, $H/catalog/date-bomb-lint.conf); refusing to scan for nothing and report green"
DCONF=""
for C in "${DETERMINISM_LINT_CONF:-}" "$H/flags/determinism-lint.conf" \
         "$CHECKOUT/catalog/determinism-lint.conf" "$H/catalog/determinism-lint.conf"; do
  [ -n "$C" ] && [ -r "$C" ] && { DCONF="$C"; break; }
done
[ -n "$DCONF" ] || die2 "no determinism-lint.conf found for the file selectors and pins"

# opt <key>: the rest of the line after `opt <key>`, spaces kept.
opt() {
  awk -v k="$1" '$1 == "opt" && $2 == k {
    sub(/^[ \t]*[^ \t]+[ \t]+[^ \t]+[ \t]+/, ""); sub(/[ \t\r]+$/, ""); v = $0; f = 1 }
    END { if (f) print v }' "$CONF"
}
DATE_RE=$(opt date_re); KEY_RE=$(opt key_re); INPUT_RE=$(opt input_re)
MAX_SAFE=$(opt max_safe_year); FLOOR=$(opt floor_year)
for k in date_re key_re input_re max_safe_year floor_year; do
  [ -n "$(opt "$k")" ] || die2 "$CONF has no 'opt $k'"
done
[[ $MAX_SAFE =~ ^[0-9]{4}$ ]] || die2 "max_safe_year '$MAX_SAFE' is not a year"
[[ $FLOOR =~ ^[0-9]{4}$ ]] || die2 "floor_year '$FLOOR' is not a year"
[ "$FLOOR" -lt "$MAX_SAFE" ] || die2 "floor_year $FLOOR is not below max_safe_year $MAX_SAFE"

FILE_RE=$(awk '$1=="file"{ $1=""; sub(/^[ \t]+/,""); printf "%s%s", (n++?"|":""), $0 }' "$DCONF")
SKIP_RE=$(awk '$1=="skip"{ $1=""; sub(/^[ \t]+/,""); printf "%s%s", (n++?"|":""), $0 }' "$DCONF")
[ -n "$FILE_RE" ] || die2 "$DCONF has no 'file' selectors"

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
awk '$1=="pin"{ $1=""; sub(/^[ \t]+/,""); print }' "$DCONF" > "$TMP/pins"

# select: paths on stdin -> the test files among them
select_files() {
  grep -E "$FILE_RE" | { if [ -n "$SKIP_RE" ]; then grep -vE "$SKIP_RE"; else cat; fi; }
}

# ── the line set: path<TAB>line<TAB>text ─────────────────────────────────────
: > "$TMP/lines"
if [ "$ALL" -eq 1 ]; then
  find "$ROOT" \( -name .git -o -name node_modules -o -name dist -o -name .wrangler \) -prune -o -type f -print \
    | sed "s|^$ROOT/||" | select_files | sort -u > "$TMP/files"
  while IFS= read -r F; do
    [ -n "$F" ] || continue
    awk -v P="$F" '{ print P "\t" FNR "\t" $0 }' "$ROOT/$F" >> "$TMP/lines"
  done < "$TMP/files"
else
  git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die2 "$ROOT is not a git work tree (use --all to scan without git)"
  ROOT=$(git -C "$ROOT" rev-parse --show-toplevel) || die2 "cannot find the top of $ROOT"
  git -C "$ROOT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || die2 "cannot resolve base $BASE"
  FORK=$(git -C "$ROOT" merge-base "$BASE" HEAD 2>/dev/null)
  [ -n "$FORK" ] || die2 "no merge-base between $BASE and HEAD (shallow clone?)"
  git -C "$ROOT" -c core.quotepath=off diff --name-only --diff-filter=AMR "$FORK" -- > "$TMP/changed" \
    || die2 "git diff against $FORK failed"
  select_files < "$TMP/changed" | sort -u > "$TMP/files"
  if [ -s "$TMP/files" ]; then
    mapfile -t FILES < "$TMP/files"
    git -C "$ROOT" -c core.quotepath=off diff -U0 --no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/ \
      "$FORK" -- "${FILES[@]}" > "$TMP/diff" || die2 "git diff -U0 against $FORK failed"
    # A `+++ b/<path>` is a header only between `diff --git` and the first
    # `@@`; inside a hunk the same bytes are an added line that begins `++ `.
    awk '
      /^diff --git / { hdr = 1; f = ""; next }
      hdr && /^\+\+\+ b\// { f = substr($0, 7); next }
      /^@@ / { hdr = 0; split($3, a, ","); n = substr(a[1], 2) + 0; next }
      !hdr && /^\+/ { if (f != "") print f "\t" n "\t" substr($0, 2); n++ }
    ' "$TMP/diff" > "$TMP/lines"
  fi
fi
[ -s "$TMP/lines" ] || exit 0

# ── the pins: a file whose HEAD version matches any `pin` is skipped whole ───
: > "$TMP/pinned"
if [ -s "$TMP/pins" ]; then
  cut -f1 "$TMP/lines" | sort -u > "$TMP/judged"
  while IFS= read -r F; do
    if [ "$ALL" -eq 1 ] || ! git -C "$ROOT" show "HEAD:$F" > "$TMP/src" 2>/dev/null; then
      cat "$ROOT/$F" > "$TMP/src" 2>/dev/null || : > "$TMP/src"
    fi
    if grep -qE -f "$TMP/pins" "$TMP/src"; then printf '%s\n' "$F" >> "$TMP/pinned"; fi
  done < "$TMP/judged"
fi

# ── the judgement ────────────────────────────────────────────────────────────
# Regexes go through ENVIRON, not -v, so awk does no escape processing on them.
DBL_KEY_DATE="$KEY_RE$DATE_RE" DBL_INPUT="$INPUT_RE" \
awk -F'\t' -v MAX="$MAX_SAFE" -v FLOOR="$FLOOR" '
  BEGIN { KD = ENVIRON["DBL_KEY_DATE"]; IN = ENVIRON["DBL_INPUT"]
          WV = "(#|//)[[:space:]]*determinism:[[:space:]]*ok([[:space:]]|$)" }
  FILENAME == ARGV[1] { pinned[$0] = 1; next }
  {
    path = $1; line = $2
    text = $0; sub(/^[^\t]*\t[^\t]*\t/, "", text)
    if (path in pinned) next
    if (text ~ IN) next
    if (match(text, WV)) {
      reason = substr(text, RSTART + RLENGTH)
      sub(/^[ \t]+/, "", reason); sub(/[ \t\r]+$/, "", reason)
      if (length(reason) >= 3) next
    }
    s = text
    while (match(s, KD)) {
      m = substr(s, RSTART, RLENGTH)
      date = substr(m, length(m) - 9)
      key = substr(m, 1, length(m) - 10)
      sub(/["\047 \t]*[:=][ \t]*["\047]?$/, "", key)
      year = substr(date, 1, 4) + 0
      if (year >= FLOOR && year < MAX) {
        printf "%s:%s: fixture-timebomb: %s is a hard-coded %s, it expires against the real clock; use a year >= %s, a pre-%s date for \"already due\", pin NOW, or pass the date as an input\n", path, line, key, date, MAX, FLOOR
        found++
      }
      s = substr(s, RSTART + RLENGTH)
    }
  }
  END { exit (found ? 1 : 0) }
' "$TMP/pinned" "$TMP/lines" > "$TMP/out"
RC=$?
cat "$TMP/out"
if [ "$RC" -eq 1 ]; then
  echo "test-date-bomb-lint: $(grep -c . "$TMP/out") fixture time bomb(s)" >&2
  exit 1
fi
[ "$RC" -eq 0 ] || die2 "the judging awk failed (rc $RC)"
exit 0
