#!/bin/bash
# bin/lib/test-select.sh <repo-dir> <base> <head>
#
# WHICH TESTS DOES THIS DIFF ACTUALLY NEED?
#
# Changed files in, test files out — and every doubt answered with "run the
# whole suite". A selector that narrows a run by mistake produces a green build
# that never executed the test which would have been red, and nothing downstream
# can tell that from a real pass. So every external thing this file touches
# (jq, codegraph, a repo's map, a package.json) fails to FULL, never to a
# shorter list, and NOTHING is written to stdout until every FULL branch has
# been passed: a narrowed list next to a reason string is impossible here by
# construction, not by care.
#
# CONTRACT (the real selector replaces the BODY below, never this interface):
#   args    <repo-dir>  the checkout to inspect; must be a git work tree
#           <base>      the ref the diff is taken FROM
#           <head>      the ref the diff is taken TO
#   exit 0  stdout is ONLY the selected list: one repo-relative test path per
#           line, each existing at <head>, sorted, de-duplicated. Nothing else
#           goes to stdout, ever — the caller reads it as an argv list.
#   exit 2  a deliberate "run everything": empty stdout, one line
#           `FULL: <reason>` on stderr.
#   exit 3  could not run at all (bad arguments, not a git repo, missing data):
#           empty stdout, one line `UNAVAILABLE: <reason>` on stderr.
#   Any other exit code, and any rc 0 with empty stdout, is read by the caller
#   as FULL too — this side fails safe by construction, never by promise.
#   stderr NEVER carries env values, tokens, or paths outside the repo: it is
#   copied verbatim into $BUILD/test-select-<phase>.err and into the mode string
#   that lands in the PR's evidence block.
#
# Paths reach this script from a diff, so they are hostile input: NUL-delimited
# reads, argv arrays and `case` globbing throughout. No eval, no `bash -c`, no
# command built out of a string — the rule bin/repro-gate.sh states in its own
# header, for the same reason.
set -u

[ $# -eq 3 ] || { echo 'UNAVAILABLE: usage: test-select.sh <repo-dir> <base> <head>' >&2; exit 3; }
git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo 'UNAVAILABLE: not a git repo' >&2; exit 3; }

REPO=$1; BASE=$2; HEADR=$3
cd -- "$REPO" || { echo 'UNAVAILABLE: cannot enter the repo directory' >&2; exit 3; }
git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null \
  || { echo "UNAVAILABLE: base does not resolve: $BASE" >&2; exit 3; }
git rev-parse --verify --quiet "$HEADR^{commit}" >/dev/null \
  || { echo "UNAVAILABLE: head does not resolve: $HEADR" >&2; exit 3; }

FULL() { echo "FULL: $1" >&2; exit 2; }        # every caller of this exits before stdout

# NUL-delimited git output cannot survive $( ), which strips it, so the two list
# reads land in a temp file OUTSIDE the repo — "never writes into the repo" is
# an acceptance test (tests/test-select-test.sh case 12), not a preference.
TMP=$(mktemp) || { echo 'UNAVAILABLE: no writable temp directory' >&2; exit 3; }
trap 'rm -f "$TMP"' EXIT

CHANGED=()
git diff -z --name-only --diff-filter=ACMRD "$BASE...$HEADR" > "$TMP" 2>/dev/null \
  || { echo "UNAVAILABLE: cannot diff $BASE...$HEADR" >&2; exit 3; }
while IFS= read -r -d '' f; do CHANGED+=("$f"); done < "$TMP"

# "Exists at head" is the tree, never the filesystem: an untracked file on disk
# must never reach an argv list the caller hands to npm.
declare -A ATHEAD=()
UNIVERSE=()
git ls-tree -r -z --name-only "$HEADR" > "$TMP" 2>/dev/null \
  || { echo "UNAVAILABLE: cannot list the tree at $HEADR" >&2; exit 3; }
while IFS= read -r -d '' f; do ATHEAD["$f"]=1; UNIVERSE+=("$f"); done < "$TMP"
# The candidate universe is head PLUS the paths this diff deleted: a deleted
# test still proves its module was covered (so the change is not "unmappable"),
# it is simply filtered out again at emit time.
for f in "${CHANGED[@]}"; do [ -n "${ATHEAD[$f]:-}" ] || UNIVERSE+=("$f"); done

SEL=()                 # candidates, including ones that no longer exist at head
declare -A MAPPED=()   # changed path -> some rule found a test for it
add() { # add <candidate> <owning changed path, or empty for the always-on ones>
  [ -n "$1" ] || return 0
  SEL+=("$1")
  [ -n "${2:-}" ] && MAPPED["$2"]=1
  return 0
}
is_test() { case "${1##*/}" in *.test.*|*.spec.*|*_test.*|*-test.sh) return 0 ;; esac; return 1; }
# A path lifted out of prose carries the sentence's punctuation with it —
# "driven by tests/x.test.ts." tokenises with the full stop attached, and the
# entry then contributes nothing while looking like it contributed. Walk the
# trailing dots and slashes off until something that exists at head appears.
add_token() { # add_token <token from prose> <owning changed path, or empty>
  local t=$1
  while [ -n "$t" ] && [ -z "${ATHEAD[$t]:-}" ]; do
    case "$t" in *[./]) t=${t%?} ;; *) return 0 ;; esac
  done
  [ -n "$t" ] && add "$t" "${2:-}"
  return 0
}
in_test_dir() { case "/$1" in */tests/*|*/test/*|*/__tests__/*|*/spec/*) return 0 ;; esac; return 1; }
# Not source = nothing a test could cover. Only source files can be unmappable;
# a README that maps to nothing is a docs diff, not a hole in the selection.
# "docs" here is the repo's own prose tree at the ROOT, never any directory
# named docs at any depth: `app/docs/page.tsx` is a Next.js route and
# `src/components/docs/Viewer.tsx` is a component, and reading either as prose
# would let a source file nothing covers ship under a narrowed run — the
# false-"covered" direction, the one that cannot be undone by a later build. A
# nested docs/ directory full of markdown is still prose by extension; one
# holding an odd extension widens to FULL, which is the safe direction.
is_nonsource() {
  case "$1" in docs/*) return 0 ;; esac
  case "${1##*/}" in package-lock.json|pnpm-lock.yaml|yarn.lock|*.lock|LICENSE*) return 0 ;; esac
  case "${1##*/}" in *.*) ;; *) return 1 ;; esac
  case "${1##*.}" in md|markdown|mdx|txt|rst|png|jpg|jpeg|gif|svg|ico|webp|pdf|csv|snap) return 0 ;; esac
  return 1
}

# ── always-full: the changes no map can be trusted about ─────────────────────
# A repo's own tests/always-full.txt wins; the built-in below is the documented
# fallback for a repo that ships none, and the only hardcoded policy in here.
AF_DEFAULT='(^|/)(prisma/|schema\.prisma|migrations?/|.*\.sql$|package\.json|package-lock\.json|pnpm-lock\.yaml|yarn\.lock|tsconfig[^/]*\.json|vitest\.config\.[^/]+|jest\.config\.[^/]+|next\.config\.[^/]+|\.github/workflows/|\.env[^/]*|tests/(setup|helpers|fixtures)/|tests/impact-map\.json|tests/static-guards)'
AF=()
if AF_TXT=$(git show "$HEADR:tests/always-full.txt" 2>/dev/null); then
  while IFS= read -r line; do
    line=${line%$'\r'}
    case "$line" in ''|'#'*) continue ;; esac
    AF+=("$line")
  done <<< "$AF_TXT"
fi
[ "${#AF[@]}" -gt 0 ] || AF=("$AF_DEFAULT")
# A line is a regex or a glob, and an unparseable regex is simply not a match
# (rc 2 from [[ =~ ]]) rather than an error on the stderr the caller quotes.
af_match() {
  [[ "$1" =~ $2 ]] 2>/dev/null && return 0
  case "$1" in $2) return 0 ;; esac
  return 1
}
for p in "${CHANGED[@]}"; do
  for pat in "${AF[@]}"; do
    af_match "$p" "$pat" && FULL "always-full path $p"
  done
done

# ── source (a) part 1: the repo's own map ────────────────────────────────────
# Absent map != empty map != broken map (D9/D11). A map that is there and does
# not parse is the strongest possible signal that this repo's idea of coverage
# is not readable right now, so it is FULL — never "zero mappings".
MAPKEYS=()
if MAPJSON=$(git show "$HEADR:tests/impact-map.json" 2>/dev/null); then
  command -v jq >/dev/null 2>&1 || FULL 'map unreadable tests/impact-map.json'
  printf '%s' "$MAPJSON" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || FULL 'map unreadable tests/impact-map.json'
  # Keys and values are read one line at a time. A JSON key or value carrying a
  # newline could never name a file, and `read -r` splits it into two candidates
  # rather than refusing it: each half then has to exist at <head> to survive the
  # emit filter, so the worst case is one extra REAL test file in the run — the
  # widening direction. (The emit guard further down catches a newline in a
  # candidate, but only git-sourced paths can ever reach it carrying one.) The
  # map is the repo's own file, not hostile diff input, so a garbage map buys a
  # wider run, not a narrower one.
  while IFS= read -r k; do [ -n "$k" ] && MAPKEYS+=("$k"); done \
    < <(printf '%s' "$MAPJSON" | jq -r 'keys[]' 2>/dev/null)
fi
map_candidates() { # map_candidates <changed path>  — keys are fnmatch, hence `case`
  local p=$1 k v
  for k in "${MAPKEYS[@]}"; do
    case "$p" in $k) ;; *) continue ;; esac
    while IFS= read -r v; do add "$v" "$p"; done \
      < <(printf '%s' "$MAPJSON" | jq -r --arg k "$k" '(.[$k] // [])[] | tostring' 2>/dev/null)
  done
}

# ── source (a) part 2: the verification map ──────────────────────────────────
# An entry that names a changed path contributes the tests it names. Read once
# each: this loop is O(entries x changed files) and a git show per pair would be
# the whole cost of the script on a wide diff.
VM_TXT=(); VM_TOK=()
while IFS= read -r -d '' d; do
  case "$d" in *.md) ;; *) continue ;; esac
  # The index and the template are NOT entries (docs/verification-map/README.md
  # says so, and tests/verification-map-test.sh asserts it). Reading them as one
  # is what a first run here showed: the index names every feature's tests, so a
  # single mapped change dragged in a test from an unrelated row.
  case "${d##*/}" in README.md|TEMPLATE.md) continue ;; esac
  body=$(git show "$HEADR:$d" 2>/dev/null) || continue
  VM_TXT+=("$body")
  VM_TOK+=("$(grep -oE 'tests?/[A-Za-z0-9_./-]+' <<< "$body" | LC_ALL=C sort -u)")
done < <(git ls-tree -r -z --name-only "$HEADR" -- docs/verification-map 2>/dev/null)
vmap_candidates() { # vmap_candidates <changed path>
  local p=$1 i t
  for i in "${!VM_TXT[@]}"; do
    case "${VM_TXT[$i]}" in *"$p"*) ;; *) continue ;; esac
    while IFS= read -r t; do add_token "$t" "$p"; done <<< "${VM_TOK[$i]}"
  done
}

# ── source (b): the filename convention ──────────────────────────────────────
# Stem of src/lib/x.ts is "x"; a test is a candidate when its basename starts
# with the stem and it lives in a test directory or beside the file itself.
# Matched over the UNIVERSE, so a test deleted in this very diff still counts as
# the module's coverage — the head filter at the end is what drops it.
conv_candidates() { # conv_candidates <path to take the stem from> <owning changed path>
  local src=$1 owner=$2 stem dir u udir
  dir=${src%/*}; [ "$dir" = "$src" ] && dir=.
  stem=${src##*/}; stem=${stem%%.*}
  [ -n "$stem" ] || return 0
  for u in "${UNIVERSE[@]}"; do
    case "${u##*/}" in
      "$stem"*.test.*|"$stem"*.spec.*|"$stem"*_test.*|"$stem"*-test.sh) ;;
      *) continue ;;
    esac
    udir=${u%/*}; [ "$udir" = "$u" ] && udir=.
    if in_test_dir "$u" || [ "$udir" = "$dir" ]; then add "$u" "$owner"; fi
  done
}

# ── source (c): direct importers, one hop ────────────────────────────────────
# codegraph knows about dynamic dispatch and grep does not, so it wins when it
# is there. When it fails, is missing, or says nothing it contributes nothing
# and claims nothing — the grep arm then answers, and a grep that finds nothing
# pushes the file toward FULL rather than toward a shorter list.
# codegraph answers for the RANGE, so it names tests without saying which
# changed file each one covers. Its tokens therefore join the selection with no
# owner: a change codegraph alone maps still answers `FULL: unmappable`, which is
# wider than the ticket's "(a)+(b)+(c) mapped to zero tests" and never narrower.
# Inventing an owner would let a real hole in coverage read as mapped. Pinned by
# case 14b and written down in docs/verification-map/test-select.md.
cg_candidates() { # cg_candidates -> rc 0 if codegraph contributed anything
  local out t n=0 before p
  [ -d .codegraph ] || return 1
  command -v codegraph >/dev/null 2>&1 || return 1
  out=$(codegraph affected "$BASE...$HEADR" 2>/dev/null) || out=""
  # The per-file fallback is one process per changed file, so it carries the
  # same bound as the grep arm: on a diff that wide, contributing nothing and
  # letting the answer widen to FULL beats a two-minute selection.
  if [ -z "$out" ] && [ "$SRCN" -le 200 ]; then
    for p in "${CONTRIB[@]}"; do out+=$(codegraph explore "$p" 2>/dev/null)$'\n'; done
  fi
  [ -n "${out//[[:space:]]/}" ] || return 1
  while IFS= read -r t; do
    before=${#SEL[@]}
    is_test "$t" && add_token "$t" ""
    [ "${#SEL[@]}" -gt "$before" ] && n=$((n+1))
  done < <(grep -oE 'tests?/[A-Za-z0-9_./-]+' <<< "$out" | LC_ALL=C sort -u)
  [ "$n" -gt 0 ]
}
grep_candidates() { # grep_candidates <changed path>
  local p=$1 stem esc f dirs=() d
  stem=${p##*/}; stem=${stem%%.*}
  [ -n "$stem" ] || return 0
  # The stem comes out of a diff, so it goes into an ERE escaped — and never
  # into a shell: the variable is expanded by grep's argv, not re-parsed.
  esc=$(printf '%s' "$stem" | sed 's/[][(){}.*+?^$|\\]/\\&/g')
  for d in src tests test lib app; do [ -d "$d" ] && dirs+=("$d"); done
  [ "${#dirs[@]}" -gt 0 ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # This arm is the one place that reads the checkout instead of the tree, and
    # the checkout can hold files that are not at head. An untracked test is
    # dropped at emit time anyway, so letting it mark its module MAPPED would
    # only hide an unmappable change behind coverage that exists on one disk.
    [ -n "${ATHEAD[$f]:-}" ] || continue
    if is_test "$f"; then add "$f" "$p"; else conv_candidates "$f" "$p"; fi
  done < <(grep -rlE --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=dist \
             --exclude-dir=build --exclude-dir=.next \
             -- "from ['\"][^'\"]*/$esc(\.[cm]?[jt]sx?)?['\"]" "${dirs[@]}" 2>/dev/null)
}

# ── the test script the harness will actually run ────────────────────────────
# `npm run x -- files` appends to the LAST command of "a && b", so a compound
# script would silently apply the file list to the wrong command
# (bin/repro-gate.sh:75-83, the project-4 false-fail). Refuse; never split.
if PKG=$(git show "$HEADR:package.json" 2>/dev/null); then
  command -v jq >/dev/null 2>&1 || FULL 'test script unreadable'
  printf '%s' "$PKG" | jq -e 'type == "object"' >/dev/null 2>&1 || FULL 'test script unreadable'
  SCRIPT=$(printf '%s' "$PKG" | jq -r '.scripts["test:unit"] // .scripts.test // empty' 2>/dev/null)
  case "$SCRIPT" in *'&&'*|*'||'*|*';'*) FULL 'compound test script' ;; esac
fi

# ── the sources, per changed file ────────────────────────────────────────────
# Only paths a test could cover contribute candidates. A README, an image or a
# lockfile covers nothing, so it maps to nothing: "docs-only diffs select just
# the static guards" is the rule, and without this gate a markdown file whose
# stem happens to collide with a test name decides a narrowed run by
# coincidence — plan.md pulling in three unrelated plan-* suites was exactly
# that. The gate is per path, not per diff: a doc riding along with real code
# still contributes nothing of its own.
SRCN=0
CONTRIB=()
for p in "${CHANGED[@]}"; do
  is_nonsource "$p" || SRCN=$((SRCN+1))
  if is_nonsource "$p" && ! is_test "$p"; then continue; fi
  CONTRIB+=("$p")
done
for p in "${CONTRIB[@]}"; do
  is_test "$p" && add "$p" "$p"          # a changed test selects itself
  map_candidates "$p"
  vmap_candidates "$p"
  conv_candidates "$p" "$p"
done
# The importer scan is bounded: skipped above 200 changed source files, skipped
# entirely when nothing in the diff is coverable, and never into vendored trees.
# Every bound can only REMOVE candidates, which pushes toward FULL — the safe
# direction (D12).
if [ "${#CONTRIB[@]}" -gt 0 ] && ! cg_candidates && [ "$SRCN" -le 200 ]; then
  for p in "${CONTRIB[@]}"; do grep_candidates "$p"; done
fi

# ── unmappable: zero candidates means "I do not know", not "nothing" ─────────
for p in "${CHANGED[@]}"; do
  is_test "$p" && continue
  is_nonsource "$p" && continue
  [ -n "${MAPPED[$p]:-}" ] || FULL "unmappable change $p"
done

# ── source (d): the static guards, on every answer ───────────────────────────
if G_TXT=$(git show "$HEADR:tests/static-guards.txt" 2>/dev/null); then
  while IFS= read -r line; do
    line=${line%$'\r'}
    case "$line" in ''|'#'*) continue ;; esac
    # A guard that no longer exists at head is dropped in silence: the list is a
    # declaration, and a stale line in it is not this script's error to raise.
    [ -n "${ATHEAD[$line]:-}" ] && add "$line" ""
  done <<< "$G_TXT"
fi
while IFS= read -r -d '' f; do add "$f" ""; done \
  < <(git ls-tree -r -z --name-only "$HEADR" -- tests/static-guards 2>/dev/null)

# ── emit: one sorted list, or one reason, never both ─────────────────────────
OUT=()
for c in "${SEL[@]}"; do
  # The caller reads this with `mapfile -t`, so a path carrying a newline cannot
  # be expressed in the protocol at all. Say so instead of shipping half of it.
  case "$c" in *$'\n'*) FULL 'unsupported path' ;; esac
  [ -n "${ATHEAD[$c]:-}" ] || continue
  OUT+=("$c")
done
[ "${#OUT[@]}" -gt 0 ] || FULL 'no test files found'
printf '%s\n' "${OUT[@]}" | LC_ALL=C sort -u
exit 0
