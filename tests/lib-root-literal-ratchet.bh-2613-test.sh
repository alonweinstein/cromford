#!/bin/bash
# tests/lib-root-literal-ratchet.bh-2613-test.sh — BH-2613.0 (#2648). The
# ratchet that stops a bin/lib file from falling back to the literal
# /root/harness. A sourced lib resolves its root as HARNESS, then the caller's
# H, else no root (docs/notes/2026-09-26-BH-2613-lib-root-resolution.md); the
# entry point in bin/ owns the literal default, and bin/ is outside this scan.
#
# WHAT IS A SITE. In bin/lib/**/*.sh, after full comment lines, trailing ` #`
# comments (quote-aware) and heredoc bodies are dropped, each occurrence of the
# token /root/harness (next char not [A-Za-z0-9_], so /root/harness/state and
# /root/harness-checkout count and /root/harnessX does not) counts once when it
# sits in either shape:
#   (a) the default word of ${NAME:-...} / ${NAME:=...} / ${1:-...}, nested
#       defaults included (${HARNESS:-${H:-/root/harness}} is one site);
#   (b) `(local )?NAME=["']?/root/harness...` at a statement start (line start,
#       or after ; && ||).
# Anywhere else (echo "/root/harness", [ -d /root/harness ]) is not a site.
# NOT counted, said plainly so nobody reads green as proof: export/readonly
# assignments, colon-less ${X-/root/harness}, and a path built at runtime.
#
# THE RATCHET HAS TWO MODES (RATCHET_MODE, default delta).
#
# delta — every PR and merge-queue run. Count per lib at the base and at HEAD
# (the working tree) and go red only when THIS diff raises a lib's count or
# adds a lib with sites. The base is the merge-base of HEAD with RATCHET_BASE
# (else TI_BASE; CI passes pull_request.base.sha: the PR's base, main's tip on
# a Mergify batch draft) or with origin/main, whichever is newer. A base that
# does not resolve, or no base at all, is RED, never a skip. Sites main lands
# in other libs sit on both sides and cancel, so they cannot dequeue a batch,
# and a push to main (HEAD is its own base) cannot go red on them either.
# The absolute baseline went stale on every main move and dequeued #2772
# twice; that is why this is the default. Known blind spot: a lib renamed
# with its sites reads as a new lib (red).
#
# strict — RATCHET_MODE=strict or --strict, for a scheduled or post-merge
# check. tests/fixtures/root-fallback-baseline/ holds one
# <relpath with / -> __>.count.txt per lib with sites (.txt so the public
# mirror's leakcheck can audit it): a lib with no baseline must have 0 sites,
# a lib with one must have exactly its count, and a baseline with no lib, a
# non-positive count, or a lib now at 0 sites is an error. Red here means main
# drifted from the inventory: regenerate it (below) in its own PR. The files
# are the burn-down record #2613's children delete as they convert libs.
#
#   bash tests/lib-root-literal-ratchet.bh-2613-test.sh           checks, delta mode
#   bash tests/lib-root-literal-ratchet.bh-2613-test.sh --strict  checks, strict mode
#   bash tests/lib-root-literal-ratchet.bh-2613-test.sh --print   print <relpath>\t<n>
#
# The strict baseline is regenerated from --print, never by hand (clear the
# old files first so a converted lib's file goes too):
#   rm -f tests/fixtures/root-fallback-baseline/*.count.txt
#   bash tests/lib-root-literal-ratchet.bh-2613-test.sh --print |
#     while IFS=$'\t' read -r p n; do
#       printf '%s\n' "$n" > "tests/fixtures/root-fallback-baseline/${p//\//__}.count.txt"
#     done
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# Sourced before any function that makes scratch dirs (tests-scratch-only R1).
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# The shared delta helper: rd_base picks the base, rd_tree reads it, rd_delta judges.
. "$(dirname "$0")/lib/ratchet-delta.sh" || exit 1
NOTE="docs/notes/2026-09-26-BH-2613-lib-root-resolution.md"

# count_sites <repo_root>: <relpath>\t<n> for every <root>/bin/lib/**/*.sh with
# n > 0, sorted by relpath.
count_sites() {
  python3 - "$1" <<'PY'
import os, re, sys
root = sys.argv[1]
LIT = re.compile(r'/root/harness(?![A-Za-z0-9_])')
DEF = re.compile(r'\$\{(?:[A-Za-z_]\w*|\d+):[-=]')
ASSIGN = re.compile(r'''(?:^|;|&&|\|\|)\s*(?:local\s+)?[A-Za-z_]\w*=["']?(/root/harness)(?![A-Za-z0-9_])''')
HEREDOC = re.compile(r'''(?<!<)<<(?!<)(-?)\s*(['"]?)([A-Za-z_]\w*)\2''')

def strip_comment(line):
    q = None
    for i, c in enumerate(line):
        if q:
            if c == '\\' and q == '"':
                continue
            if c == q:
                q = None
        elif c in '\'"':
            q = c
        elif c == '#' and (i == 0 or line[i - 1] in ' \t'):
            return line[:i]
    return line

def default_spans(line):
    spans = []
    for m in DEF.finditer(line):
        depth, i = 1, m.end()
        while i < len(line) and depth:
            if line.startswith('${', i):
                depth += 1
                i += 2
                continue
            if line[i] == '}':
                depth -= 1
            i += 1
        spans.append((m.end(), i))
    return spans

def count(path):
    n, end = 0, None
    with open(path, errors='replace') as f:
        for raw in f:
            line = raw.rstrip('\n')
            if end is not None:
                if line.strip() == end:
                    end = None
                continue
            if re.match(r'\s*#', line):
                continue
            code = strip_comment(line)
            spans = default_spans(code)
            hits = {m.start() for m in LIT.finditer(code)
                    if any(a <= m.start() < b for a, b in spans)}
            hits |= {m.start(1) for m in ASSIGN.finditer(code)}
            n += len(hits)
            h = HEREDOC.search(code)
            if h:
                end = h.group(3)
    return n

lib = os.path.join(root, 'bin', 'lib')
out = []
for d, _, files in os.walk(lib):
    for fn in files:
        if fn.endswith('.sh'):
            p = os.path.join(d, fn)
            n = count(p)
            if n:
                out.append((os.path.relpath(p, root), n))
for p, n in sorted(out):
    print(f'{p}\t{n}')
PY
}

# ratchet_check <repo_root> <baseline_dir>: one line per violation, rc 1 if any.
ratchet_check() {
  local root="$1" base="$2" sites site_keys p n key b f bad=0 libs
  sites=$(count_sites "$root") || { echo "counter failed on $root"; return 1; }
  site_keys=$(cut -f1 <<< "$sites" | sed 's|/|__|g; s|$|.count.txt|')
  while IFS=$'\t' read -r p n; do
    [ -n "$p" ] || continue
    key="${p//\//__}.count.txt"
    if [ ! -f "$base/$key" ]; then
      echo "new literal fallback in $p: $n sites; resolve via \${HARNESS:-\${H:-}}, see $NOTE"; bad=1; continue
    fi
    b=$(cat "$base/$key")
    case "$b" in ''|*[!0-9]*|0*) continue ;; esac   # reported by the baseline loop
    if [ "$n" -lt "$b" ]; then
      echo "$p dropped to $n sites (baseline $b): lower or delete your baseline $key"; bad=1
    elif [ "$n" -gt "$b" ]; then
      echo "new literal fallback in $p: $n sites, baseline $b; resolve via \${HARNESS:-\${H:-}}, see $NOTE"; bad=1
    fi
  done <<< "$sites"
  libs=$(cd "$root" && find bin/lib -name '*.sh' 2>/dev/null | sed 's|/|__|g; s|$|.count.txt|')
  for f in "$base"/*.count.txt; do
    [ -e "$f" ] || continue
    key=$(basename "$f")
    b=$(cat "$f")
    case "$b" in ''|*[!0-9]*|0*) echo "baseline $key is not a positive integer ('$b'); a converted lib deletes its baseline"; bad=1; continue ;; esac
    if ! grep -qxF "$key" <<< "$libs"; then
      echo "baseline $key has no lib file"; bad=1
    elif ! grep -qxF "$key" <<< "$site_keys"; then
      echo "${key%.count.txt} has 0 sites (baseline $b): delete your baseline $key"; bad=1
    fi
  done
  return "$bad"
}

# The base is rd_base (tests/lib/ratchet-delta.sh): the newest point of main
# that HEAD already contains. RATCHET_BASE (else TI_BASE; CI sets RATCHET_BASE
# to pull_request.base.sha: the PR's base, or main's tip on a Mergify batch
# draft) must resolve when it is set; origin/main (else main) wins when HEAD has
# merged past it. main commits the branch has merged sit on both sides and
# cancel. No resolvable base is rc 1: "this diff adds no site" is a claim a run
# with nothing to diff has not made.

# delta_check <repo> <base-commit> — red when THIS diff adds a site: a lib whose
# count at HEAD (the working tree) is above its count at the base, a lib new
# since the base included. A lib that drops or converts is fine and owes no
# file edit. The base tree is read with `git archive`, never checked out.
delta_check() {
  local repo="$1" ref="$2" w p n b bad=0
  w=$(mktemp -d "$T/delta-base.XXXXXX") || return 1
  rd_tree "$repo" "$ref" "$w" bin/lib || { echo "cannot read bin/lib at base $ref"; return 1; }
  count_sites "$w" > "$w.base" || { echo "counter failed on base $ref"; return 1; }
  count_sites "$repo" > "$w.head" || { echo "counter failed on $repo"; return 1; }
  while IFS=$'\t' read -r p n b; do
    echo "new literal fallback in $p: $n sites, $b at base ${ref:0:12}; resolve via \${HARNESS:-\${H:-}}, see $NOTE"; bad=1
  done < <(rd_delta "$w.head" "$w.base")
  return "$bad"
}

# ratchet_real <repo> — the real run's check. RATCHET_MODE=delta (the default,
# every PR and merge-queue run) diffs against rd_base; RATCHET_MODE=strict
# (or --strict) is the absolute check against the committed baseline, for a
# scheduled or post-merge run that wants the whole inventory to match.
ratchet_real() {
  local repo="$1" base
  case "${RATCHET_MODE:-delta}" in
    delta)
      base=$(rd_base "$repo") || { echo "$base"; return 1; }
      delta_check "$repo" "$base" ;;
    strict) ratchet_check "$repo" "$repo/tests/fixtures/root-fallback-baseline" ;;
    *) echo "RATCHET_MODE='$RATCHET_MODE': want delta or strict"; return 1 ;;
  esac
}

if [ "${1:-}" = "--print" ]; then
  count_sites "$DIR"
  exit $?
fi
if [ "${1:-}" = "--strict" ]; then RATCHET_MODE=strict; fi


PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

# --- 1. self-test: the counter refuses exactly the positive shapes -----------
S="$T/self"; mkdir -p "$S/bin/lib"
lib() { cat > "$S/bin/lib/$1.sh"; }
lib pos-default     <<'EOF'
h="${HARNESS:-/root/harness}"
EOF
lib pos-assign-default <<'EOF'
: "${X:=/root/harness/state}"
EOF
lib pos-positional  <<'EOF'
r="${1:-/root/harness}"
EOF
lib pos-nested      <<'EOF'
_h() { printf '%s' "${HARNESS:-${H:-/root/harness}}"; }
EOF
lib pos-checkout    <<'EOF'
  co="${HARNESS_CHECKOUT:-/root/harness-checkout}"
EOF
lib pos-bare        <<'EOF'
VAR=/root/harness
EOF
lib pos-local       <<'EOF'
f() { :; }
  local VAR="/root/harness/state"
EOF
lib pos-single      <<'EOF'
VAR='/root/harness'
EOF
lib neg-comment     <<'EOF'
# falls back to /root/harness
EOF
lib neg-trailing    <<'EOF'
x=1  # /root/harness-checkout
y=2 # was ${HARNESS:-/root/harness}; VAR=/root/harness
EOF
lib neg-heredoc     <<'EOF'
usage() {
  cat <<USAGE
  default root: ${HARNESS:-/root/harness}
  VAR=/root/harness
USAGE
}
EOF
lib neg-empty-default <<'EOF'
h="${HARNESS:-}"
EOF
lib neg-var-path    <<'EOF'
s="$HARNESS/state"
EOF
lib neg-string      <<'EOF'
echo "/root/harnessX"
x="${HARNESS:-/root/harnessX}"
EOF
lib neg-assign-x    <<'EOF'
VAR=/root/harnessX
EOF
lib neg-echo        <<'EOF'
echo "/root/harness"; [ -d /root/harness ] && :
EOF
want=$(printf 'bin/lib/%s.sh\t1\n' pos-assign-default pos-bare pos-checkout pos-default pos-local pos-nested pos-positional pos-single)
got=$(count_sites "$S")
if [ "$got" = "$want" ]; then ok; else bad "self: counter output"$'\n'"want:"$'\n'"$want"$'\n'"got:"$'\n'"$got"; fi
mkdir -p "$S/base"
got=$(ratchet_check "$S" "$S/base"); rc=$?
refused=$(sed -n 's|^new literal fallback in bin/lib/\([^:]*\)\.sh:.*|\1|p' <<< "$got" | tr '\n' ' ')
if [ "$rc" = 1 ] && [ "$refused" = "pos-assign-default pos-bare pos-checkout pos-default pos-local pos-nested pos-positional pos-single " ]; then ok
else bad "self: ratchet refused [$refused] rc=$rc"; fi

# --- 2. comparator cases on a scratch tree ------------------------------------
eq_case() {  # <name> <want_rc> <setup...>
  local name="$1" want="$2"; shift 2
  local E="$T/eq-$name"; scratch_rm "$E" || { bad "eq($name): scratch_rm refused $E"; return; }; mkdir -p "$E/bin/lib" "$E/base"
  printf 'a="${HARNESS:-/root/harness}"\nb="${H:-/root/harness/state}"\n' > "$E/bin/lib/two.sh"
  printf 'c="${HARNESS:-}"\n' > "$E/bin/lib/clean.sh"
  "$@" "$E"
  local out rc; out=$(ratchet_check "$E" "$E/base"); rc=$?
  if [ "$rc" = "$want" ]; then ok; else bad "eq($name) rc=$rc want $want: $out"; fi
}
base_n()   { printf '%s\n' "$1" > "$2/base/bin__lib__two.sh.count.txt"; }
exact()    { base_n 2 "$1"; }
missing()  { :; }
wrong()    { base_n 3 "$1"; }
orphan()   { base_n 2 "$1"; echo 1 > "$1/base/bin__lib__gone.sh.count.txt"; }
zero()     { base_n 2 "$1"; echo 0 > "$1/base/bin__lib__clean.sh.count.txt"; }
cleanbase(){ base_n 2 "$1"; echo 1 > "$1/base/bin__lib__clean.sh.count.txt"; }
eq_case i-exact    0 exact
eq_case ii-missing 1 missing
eq_case iii-wrong  1 wrong
eq_case iv-orphan  1 orphan
eq_case v-clean    0 exact      # clean.sh has 0 sites and no baseline
eq_case vi-zero    1 zero
eq_case vii-stale  1 cleanbase  # a baseline for a lib that now has 0 sites

# --- 3. the real tree ---------------------------------------------------------
# THE DRIFT CASES (PR #2772 was dequeued twice). A hermetic git repo per case:
# commit B is the branch point with a.sh at 2 sites and a committed baseline
# that says so; main then moves. ratchet_real is the check the real run makes.
# git runs as a scratch identity, never the caller's config.
g() { git -C "$1" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "${@:2}"; }
mk_repo() {  # <dir> — B on branch `work`, refs/remotes/origin/main = B
  local R="$1"; scratch_rm "$R" || return 1; mkdir -p "$R/bin/lib" "$R/tests/fixtures/root-fallback-baseline"
  g "$R" init -q -b work . || return 1
  printf 'a="${HARNESS:-/root/harness}"\nb="${H:-/root/harness/state}"\n' > "$R/bin/lib/a.sh"
  printf 'c="${HARNESS:-}"\n' > "$R/bin/lib/b.sh"
  echo 2 > "$R/tests/fixtures/root-fallback-baseline/bin__lib__a.sh.count.txt"
  echo readme > "$R/README"
  g "$R" add -A && g "$R" commit -qm B && g "$R" update-ref refs/remotes/origin/main HEAD
}
main_adds_site() {  # main lands a site in b.sh, a lib the PR never touches
  local R="$1"
  g "$R" checkout -q -b m refs/remotes/origin/main
  printf 'c="${HARNESS:-/root/harness}"\n' > "$R/bin/lib/b.sh"
  g "$R" commit -qam 'main: b.sh gains a site' && g "$R" update-ref refs/remotes/origin/main HEAD
  g "$R" checkout -q work && g "$R" branch -qD m
}
pr_touches_nothing() { echo more >> "$1/README"; g "$1" commit -qam 'pr: docs only'; }
pr_adds_site()       { echo 'd="${H:-/root/harness}"' >> "$1/bin/lib/a.sh"; g "$1" commit -qam 'pr: a.sh gains a site'; }
pr_adds_lib()        { echo 'e="${H:-/root/harness}"' > "$1/bin/lib/new.sh"; g "$1" add -A; g "$1" commit -qm 'pr: new lib with a site'; }
pr_drops_site()      { printf 'a="${HARNESS:-${H:-}}"\nb="${H:-/root/harness/state}"\n' > "$1/bin/lib/a.sh"; g "$1" commit -qam 'pr: a.sh converts one site'; }
merge_main()         { g "$1" merge -q --no-edit refs/remotes/origin/main; }

drift_case() {  # <name> <want_rc> <RATCHET_BASE: B|main|none|bogus> <mode> <steps...>
  local name="$1" want="$2" tib="$3" mode="$4"; shift 4
  local R="$T/drift-$name" step b out rc
  mk_repo "$R" || { bad "drift($name): repo setup failed"; return; }
  b=$(g "$R" rev-parse HEAD)
  for step in "$@"; do "$step" "$R" >/dev/null || { bad "drift($name): step $step failed"; return; }; done
  case "$tib" in
    B) tib="$b" ;; main) tib=$(g "$R" rev-parse refs/remotes/origin/main) ;;
    none) tib="" ;; bogus) tib=0123456789abcdef0123456789abcdef01234567 ;;
  esac
  out=$(RATCHET_BASE="$tib" TI_BASE= RATCHET_MODE="$mode" ratchet_real "$R" 2>&1); rc=$?
  if [ "$rc" = "$want" ]; then ok; else bad "drift($name) rc=$rc want $want:"$'\n'"$out"; fi
}
# (1) main drift the PR never touched: green in delta mode, whichever base CI hands over
drift_case main-drift-pr-base          0 main  delta main_adds_site pr_touches_nothing merge_main
drift_case main-drift-queue-draft      0 main  delta pr_touches_nothing main_adds_site merge_main
drift_case main-drift-stale-base       0 B     delta main_adds_site pr_touches_nothing merge_main
drift_case main-drift-local            0 none  delta main_adds_site pr_touches_nothing merge_main
drift_case default-mode-is-delta       0 main  ''    main_adds_site pr_touches_nothing merge_main
# (2) the PR adds a site: red, drift or no drift
drift_case pr-adds-site                1 main  delta pr_adds_site
drift_case pr-adds-site-after-drift    1 main  delta main_adds_site pr_adds_site merge_main
drift_case pr-adds-new-lib             1 main  delta main_adds_site pr_adds_lib merge_main
drift_case pr-drops-site               0 main  delta pr_drops_site
# (3) no base is red, never a skip
drift_case bogus-base                  1 bogus delta pr_touches_nothing
nomain() { g "$1" update-ref -d refs/remotes/origin/main; }
drift_case no-base-at-all              1 none  delta pr_touches_nothing nomain
# (4) strict mode stays absolute: the same drift is red against the baseline
drift_case strict-sees-drift           1 main  strict main_adds_site pr_touches_nothing merge_main
drift_case strict-clean                0 main  strict pr_touches_nothing
drift_case unknown-mode                1 main  loose  pr_touches_nothing

real=$(count_sites "$DIR")
if [ "$(grep -c . <<< "$real")" -gt 0 ]; then ok; else bad "real: counter found no sites in $DIR/bin/lib (vacuous scan)"; fi
if [ -f "$DIR/bin/lib/fleet-cooldown.sh" ] && ! grep -q '^bin/lib/fleet-cooldown\.sh'$'\t' <<< "$real"; then ok
else bad "real: bin/lib/fleet-cooldown.sh (the idiom lib) must exist and have 0 sites"; fi
mode="${RATCHET_MODE:-delta}"
out=$(ratchet_real "$DIR"); rc=$?
if [ "$rc" = 0 ]; then ok; else bad "real ($mode): ratchet over bin/lib"$'\n'"$out"; fi

echo "lib-root-literal-ratchet: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
