#!/bin/bash
# tests/test-select-test.sh — bin/lib/test-select.sh against real git repos.
#
# The property that matters: THE SELECTOR MAY NEVER QUIETLY NARROW A RUN. Every
# way it can fail — a broken map, a compound test script, a source file nothing
# tests, a deleted test file, a missing tool — has to come out as exit 2 with a
# reason on stderr and NOTHING on stdout, because the caller
# (bin/run-build.sh: HARNESS_SUITE_RUN) reads a non-empty stdout as "these are
# the tests this diff needs" and skips the rest of the suite.
#
# So the negatives carry the weight here. A list that is one test short looks
# exactly like a list that is right, and the build that misses it is green.
#
# Real git repos under $T, real diffs, the real script: no mocks, and the
# assertions are on stdout/stderr/exit code — never on the script's source text
# (docs/verification-map/README.md, "assert on artifacts").
# Run from anywhere: tests/test-select-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
SEL="$DIR/bin/lib/test-select.sh"
# Case 13 lifts the harness-suite block out of the pipeline by its markers, so
# it reads the FLATTEN and not the driver file: bin/run-build.sh's stage bodies
# are moving into bin/lib/rb/ one part at a time (BH-478), and the flatten puts
# each moved body back at its call site — the same text in the same order at
# every state of the split. Read raw, this case would extract a block with a
# hole in it the day HARNESS_SUITE_RUN's stage moves out.
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# One clock read for the whole suite (bin/test-determinism-lint.sh): every
# fixture commit is stamped from it, so two runs of this file produce the same
# commits and a fixture can never age into a red day.
NOW=$(date +%s)
export GIT_AUTHOR_DATE="@$NOW +0000" GIT_COMMITTER_DATE="@$NOW +0000"

# The ticket's fixture repo: three modules, four tests, a static guard, a
# verification-map entry naming src/lib/a.ts, and a package.json.
newrepo() { # newrepo <name>
  R="$T/$1"; mkdir -p "$R/src/lib" "$R/tests/guards" "$R/docs/verification-map"
  cd "$R" || exit 1
  git init -q .; git config user.email t@t; git config user.name t
  printf 'export const a = 1;\n' > src/lib/a.ts
  printf 'export const b = 2;\n' > src/lib/b.ts
  printf "import { a } from './a';\nexport const c = a;\n" > src/lib/c.ts
  printf 'test("a", () => {});\n'     > tests/a.test.ts
  printf 'test("b", () => {});\n'     > tests/b.test.ts
  printf 'test("c", () => {});\n'     > tests/c.test.ts
  printf 'test("amap", () => {});\n'  > tests/a-map.test.ts
  printf 'test("guard", () => {});\n' > tests/guards/no-secrets.test.ts
  printf 'tests/guards/no-secrets.test.ts\n' > tests/static-guards.txt
  printf '{"scripts":{"test":"vitest run"}}\n' > package.json
  printf '# a\n\nDrive src/lib/a.ts with tests/a-map.test.ts.\n' > docs/verification-map/a.md
  printf 'placeholder\n' > README.md
  git add -A; git commit -qm init
  BASE=$(git rev-parse HEAD)
}
commit() { git add -A; git commit -qm "$1"; }
# The real CLI, unpiped, with the three streams kept apart — stdout is the
# selection, stderr is the reason, and rc is the verdict.
run() { # run [<base>]
  OUT=$("$SEL" "$R" "${1:-$BASE}" HEAD 2>"$T/stderr"); RC=$?
  ERR=$(cat "$T/stderr")
}
lines() { printf '%s\n' "$@"; }          # expected stdout, already in sort order
has()  { grep -qF -- "$1" <<<"$OUT"; }

[ -x "$SEL" ] && ok || bad "bin/lib/test-select.sh is missing or not executable"

# ---------- 1. the honest mapping: every source, and nothing else -----------
# src/lib/a.ts is reached four ways at once: the verification-map entry names it
# (a-map), the filename convention (a.test), the importer src/lib/c.ts one hop
# out (c.test), and the always-on static guard. tests/b.test.ts is the precision
# assertion: a selector that returns the whole tests/ directory would "pass"
# every positive here and be worth nothing.
newrepo one
printf 'export const a = 2;\n' > src/lib/a.ts
commit "change a"
run
[ "$RC" = 0 ] && ok || bad "case 1: a mappable change must exit 0 (rc=$RC, err=$ERR)"
[ "$OUT" = "$(lines tests/a-map.test.ts tests/a.test.ts tests/c.test.ts tests/guards/no-secrets.test.ts)" ] \
  && ok || bad "case 1: exact selection expected, got: $(tr '\n' ' ' <<<"$OUT")"
has tests/b.test.ts && bad "case 1: an unrelated test was selected — the selection is not precise" || ok
[ -z "$ERR" ] && ok || bad "case 1: exit 0 must write nothing to stderr (got: $ERR)"

# ---------- 2. always-full: the paths no map can be trusted about -----------
newrepo two
mkdir -p prisma; printf 'model X {}\n' > prisma/schema.prisma
commit "schema"
run
[ "$RC" = 2 ] && ok || bad "case 2: an always-full path must exit 2 (rc=$RC)"
[ "$ERR" = 'FULL: always-full path prisma/schema.prisma' ] \
  && ok || bad "case 2: the reason must name the path (got: $ERR)"
[ -z "$OUT" ] && ok || bad "case 2: a FULL answer must leave stdout EMPTY (got: $OUT)"

# ---------- 3. unmappable: a source file nothing tests ----------------------
# The single most dangerous input. Zero candidates must read as "I do not know
# what covers this", never as an empty list.
newrepo three
printf 'export const orphan = 1;\n' > src/lib/orphan.ts
commit "orphan"
run
[ "$RC" = 2 ] && ok || bad "case 3: an unmappable source file must exit 2 (rc=$RC)"
[ "$ERR" = 'FULL: unmappable change src/lib/orphan.ts' ] \
  && ok || bad "case 3: the reason must name the file (got: $ERR)"
[ -z "$OUT" ] && ok || bad "case 3: stdout must be empty (got: $OUT)"

# ---------- 4. source (a): the repo's own impact map ------------------------
# tests/extra-map.test.ts is reachable ONLY through the map — no filename
# convention and no importer leads to it — so its presence proves the map was
# read rather than guessed at. The map is committed at BASE: it is itself an
# always-full path, so a diff containing it never gets this far.
newrepo four
printf 'test("extra", () => {});\n' > tests/extra-map.test.ts
printf '{"src/lib/b*": ["tests/extra-map.test.ts", "tests/b.test.ts"]}\n' > tests/impact-map.json
commit "map"; BASE=$(git rev-parse HEAD)
printf 'export const b = 3;\n' > src/lib/b.ts
commit "change b"
run
[ "$RC" = 0 ] && ok || bad "case 4: a mapped change must exit 0 (rc=$RC, err=$ERR)"
has tests/extra-map.test.ts && ok || bad "case 4: the map's own entry must be selected (got: $(tr '\n' ' ' <<<"$OUT"))"
has tests/b.test.ts && ok || bad "case 4: the module's test must be selected"
has tests/guards/no-secrets.test.ts && ok || bad "case 4: the static guard must always be selected"
has tests/a.test.ts && bad "case 4: an unrelated module's test was selected" || ok

# ---------- 5. a deleted test is MAPPED but never SELECTED ------------------
# Deleting tests/b.test.ts and changing src/lib/b.ts in one diff. The deleted
# file must not reach the npm argv list (it does not exist at head), and the
# change must still not read as unmappable — the module WAS covered.
newrepo five
git rm -q tests/b.test.ts
printf 'export const b = 4;\n' > src/lib/b.ts
commit "delete b's test, change b"
run
[ "$RC" = 0 ] && ok || bad "case 5: a module whose test was deleted is still mapped — exit 0 expected (rc=$RC, err=$ERR)"
has tests/b.test.ts && bad "case 5: a test that does not exist at head must never be selected" || ok
has tests/guards/no-secrets.test.ts && ok || bad "case 5: the static guard must still be selected"

# ---------- 6. a broken map is FULL, never "no mappings" (D9/D11) ----------
newrepo six
printf '{\n' > tests/impact-map.json
commit "broken map"; BASE=$(git rev-parse HEAD)
printf 'export const a = 5;\n' > src/lib/a.ts
commit "change a"
run
[ "$RC" = 2 ] && ok || bad "case 6: an unparseable map must exit 2, not fall through to the other sources (rc=$RC)"
grep -q '^FULL: map unreadable' <<<"$ERR" \
  && ok || bad "case 6: the reason must say the map is unreadable (got: $ERR)"
[ -z "$OUT" ] && ok || bad "case 6: stdout must be empty (got: $OUT)"

# ---------- 7. docs-only: the static guards, and only those -----------------
# docs/a.md is the sharp edge here, and the reason a README-only fixture is not
# enough: its stem ("a") matches tests/a.test.ts AND tests/a-map.test.ts, so a
# selector that runs the filename convention over every changed path answers
# with two unrelated suites and calls it a selection. Prose covers no code — a
# markdown file must never be the thing that decides a narrowed run.
newrepo seven
printf '# a\n\nHow the a module works.\n' > docs/a.md
printf 'placeholder\nmore words\n' > README.md
commit "docs"
run
[ "$RC" = 0 ] && ok || bad "case 7: a docs-only diff must exit 0 (rc=$RC, err=$ERR)"
[ "$OUT" = 'tests/guards/no-secrets.test.ts' ] \
  && ok || bad "case 7: a docs-only diff selects exactly the static guards (got: $(tr '\n' ' ' <<<"$OUT"))"
# ...and with no guards declared, the union is empty: that is FULL, not "run
# nothing". An empty selection handed to npm would run the WHOLE suite anyway,
# but the mode string would claim a selection happened.
newrepo sevenb
git rm -q tests/static-guards.txt
commit "no guards"; BASE=$(git rev-parse HEAD)
printf 'placeholder\nmore words\n' > README.md
commit "docs"
run
[ "$RC" = 2 ] && ok || bad "case 7b: an empty union must exit 2 (rc=$RC)"
[ "$ERR" = 'FULL: no test files found' ] && ok || bad "case 7b: wrong reason (got: $ERR)"
# ...and the rule is per path, not per diff: a doc riding along with a real code
# change still contributes nothing. Otherwise the doc widens the run by
# coincidence today and narrows it by coincidence tomorrow.
newrepo sevenc
printf 'export const b = 11;\n' > src/lib/b.ts
printf '# a\n\nHow the a module works.\n' > docs/a.md
commit "code plus a doc"
run
[ "$RC" = 0 ] && ok || bad "case 7c: rc=$RC (err=$ERR)"
[ "$OUT" = "$(lines tests/b.test.ts tests/guards/no-secrets.test.ts)" ] \
  && ok || bad "case 7c: the doc contributed tests of its own (got: $(tr '\n' ' ' <<<"$OUT"))"

# ---------- 8. a compound test script cannot take an argv list --------------
# `npm run x -- files` appends to the LAST command of "a && b", so the file list
# would silently apply to the wrong command (bin/repro-gate.sh:75-83, the
# project-4 false-fail). Refuse rather than split.
newrepo eight
printf '{"scripts":{"test":"a && b"}}\n' > package.json
commit "compound script"; BASE=$(git rev-parse HEAD)
printf 'export const a = 6;\n' > src/lib/a.ts
commit "change a"
run
[ "$RC" = 2 ] && ok || bad "case 8: a compound test script must exit 2 (rc=$RC)"
[ "$ERR" = 'FULL: compound test script' ] && ok || bad "case 8: wrong reason (got: $ERR)"
[ -z "$OUT" ] && ok || bad "case 8: stdout must be empty (got: $OUT)"

# ---------- 9. a changed test selects itself, spaces and all ----------------
# The whole pipeline is NUL-delimited reads and argv arrays for the spaced path.
# tests/shell-test.sh is the other half: this repo's own convention, and the one
# shape the filename rule cannot reach from its own stem ("shell-test" never
# matches "shell-test*-test.sh"), so it is only ever selected by the explicit
# "a changed test is its own test" rule.
newrepo nine
printf 'test("space", () => {});\n' > "tests/my suite.test.ts"
printf '#!/bin/bash\nexit 0\n' > tests/shell-test.sh
commit "spaced test + a bash test"
run
[ "$RC" = 0 ] && ok || bad "case 9: rc=$RC (err=$ERR)"
[ "$OUT" = "$(lines tests/guards/no-secrets.test.ts 'tests/my suite.test.ts' tests/shell-test.sh)" ] \
  && ok || bad "case 9: both changed tests must come back intact, and nothing else (got: $(tr '\n' ' ' <<<"$OUT"))"

# ---------- 10. unavailable: no answer at all, and it says so ---------------
newrepo ten
run deadbeef
[ "$RC" = 3 ] && ok || bad "case 10: an unresolvable base must exit 3 (rc=$RC)"
# The reason has to name WHICH input was bad. "cannot diff" would be true too,
# and would send the reader looking at the repo instead of at the ref they
# passed — the stderr line is the only thing the caller quotes.
[ "$ERR" = 'UNAVAILABLE: base does not resolve: deadbeef' ] \
  && ok || bad "case 10: exit 3 must say which ref did not resolve (got: $ERR)"
[ -z "$OUT" ] && ok || bad "case 10: stdout must be empty (got: $OUT)"
OUT=$("$SEL" "$T/not-a-repo" HEAD HEAD 2>"$T/stderr"); RC=$?
[ "$RC" = 3 ] && ok || bad "case 10: a non-repo must exit 3 (rc=$RC)"
OUT=$("$SEL" "$R" HEAD 2>"$T/stderr"); RC=$?
[ "$RC" = 3 ] && ok || bad "case 10: wrong argument count must exit 3 (rc=$RC)"
grep -q '^UNAVAILABLE:' "$T/stderr" && ok || bad "case 10: bad usage must say UNAVAILABLE"

# ---------- 11. a path that is a shell command if anything evaluates it -----
# Nothing here may reach a shell: no eval, no bash -c, no string built into a
# command. The file is named so that a single mistake creates $R/pwned.
newrepo eleven
printf 'export const a = 1;\n' > 'src/lib/a$(touch pwned).ts'
commit "metacharacter path"
run
{ [ "$RC" = 0 ] || [ "$RC" = 2 ]; } && ok || bad "case 11: the selector must still answer (rc=$RC, err=$ERR)"
{ [ ! -e "$R/pwned" ] && [ ! -e "$T/pwned" ] && [ ! -e "$DIR/pwned" ]; } \
  && ok || bad "case 11: a path was evaluated by a shell — 'pwned' exists"
grep -q '^FULL: unmappable change' <<<"$ERR" \
  && ok || bad "case 11: the metacharacter path maps to no test, so it is FULL (got: rc=$RC err=$ERR)"

# ---------- 12. the selector never writes into the repo it inspects ---------
newrepo twelve
printf 'export const a = 7;\n' > src/lib/a.ts
commit "change a"
BEFORE=$(git -C "$R" status --porcelain; git -C "$R" rev-parse HEAD)
run
[ "$RC" = 0 ] && ok || bad "case 12: setup expected a successful run (rc=$RC, err=$ERR)"
[ -z "$(git -C "$R" status --porcelain)" ] \
  && ok || bad "case 12: the selector wrote into the repo: $(git -C "$R" status --porcelain)"
[ "$BEFORE" = "$(git -C "$R" status --porcelain; git -C "$R" rev-parse HEAD)" ] \
  && ok || bad "case 12: the repo moved under the selector"

# ---------- 13. THE PRODUCTION CALLER: HARNESS_SUITE_RUN, extracted ---------
# Everything above drives the CLI directly. This drives the block in the
# pipeline that a real build runs — extracted verbatim by its markers out of
# $RB_ALL, never retyped — with the real selector under a scratch $HARNESS and
# a stub npm that records its argv. The claim being tested is the only one that
# matters to a build: the suite command npm actually receives is narrowed to
# these files.
python3 - "$RB_ALL" "$T/suite-block.sh" <<'PY'
import sys
s = open(sys.argv[1]).read()
b = s.index("# >>> harness suite run")
e = s.index("# <<< harness suite run")
open(sys.argv[2], "w").write(s[b:e])
PY
[ -s "$T/suite-block.sh" ] && ok || bad "case 13: could not extract the harness suite block from run-build.sh"
mkdir -p "$T/h/bin/lib" "$T/stub" "$T/build"
cp "$SEL" "$T/h/bin/lib/test-select.sh"; chmod +x "$T/h/bin/lib/test-select.sh"
cat > "$T/stub/npm" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$NPM_ARGV_OUT"
STUB
chmod +x "$T/stub/npm"
newrepo thirteen
printf 'export const a = 8;\n' > src/lib/a.ts
commit "change a"
suite_run() { # suite_run <outfile> <TEST_SELECT value>
  ( cd "$R" || exit 1
    PATH="$T/stub:$PATH" NPM_ARGV_OUT="$T/npm-argv.txt" HARNESS="$T/h" \
    PROJECT=demo KEY=BH-550 BUILD="$T/build" BASE="$BASE" TEST_SELECT="$2" \
    bash -c 'set -uo pipefail
             STAMP() { echo stamp; }
             . "'"$T"'/suite-block.sh"
             HARNESS_SUITE_RUN "$1" lenses' _ "$1" )
}
suite_run harness-suite.txt 1
[ "$(head -1 "$T/build/harness-suite.txt")" = 'HARNESS_SUITE: selected 4 of the suite — npm run test' ] \
  && ok || bad "case 13: the build record must say what was selected (got: $(head -1 "$T/build/harness-suite.txt"))"
grep -qx 'tests/a.test.ts' "$T/npm-argv.txt" \
  && ok || bad "case 13: npm must receive the selected files (got: $(tr '\n' ' ' <"$T/npm-argv.txt"))"
grep -qx 'tests/b.test.ts' "$T/npm-argv.txt" \
  && bad "case 13: npm received a test this diff does not need" || ok
grep -q 'HARNESS_EXIT: 0' "$T/build/harness-suite.txt" \
  && ok || bad "case 13: the suite run must record its real exit code"
# ...and the knob still turns it all the way off, with the whole suite run and
# no file list at all.
suite_run harness-suite-off.txt 0
[ "$(head -1 "$T/build/harness-suite-off.txt")" = 'HARNESS_SUITE: full (TEST_SELECT=0) — npm run test' ] \
  && ok || bad "case 13: TEST_SELECT=0 must still run the full suite (got: $(head -1 "$T/build/harness-suite-off.txt"))"
[ "$(cat "$T/npm-argv.txt")" = "$(lines run test)" ] \
  && ok || bad "case 13: a full run must pass npm no file list (got: $(tr '\n' ' ' <"$T/npm-argv.txt"))"

# ---------- 14. source (c): codegraph when it is there, grep when it is not -
# The stub answers for the range, so the bounded grep arm must NOT run: the
# proof is tests/c.test.ts (only the importer grep finds it) being absent while
# tests/b.test.ts (only codegraph named it) is present.
newrepo fourteen
mkdir -p .codegraph; printf 'index\n' > .codegraph/index
commit "codegraph index"; BASE=$(git rev-parse HEAD)
printf 'export const a = 9;\n' > src/lib/a.ts
commit "change a"
mkdir -p "$T/cg"
cat > "$T/cg/codegraph" <<'STUB'
#!/bin/bash
[ "$1" = affected ] || exit 1
echo "affected: tests/b.test.ts"
STUB
chmod +x "$T/cg/codegraph"
OUT=$(PATH="$T/cg:$PATH" "$SEL" "$R" "$BASE" HEAD 2>"$T/stderr"); RC=$?
ERR=$(cat "$T/stderr")
[ "$RC" = 0 ] && ok || bad "case 14: rc=$RC (err=$ERR)"
has tests/b.test.ts && ok || bad "case 14: codegraph's answer must be selected (got: $(tr '\n' ' ' <<<"$OUT"))"
has tests/c.test.ts && bad "case 14: the grep arm ran even though codegraph answered" || ok
# A codegraph that fails claims nothing — no reason string, no selection of its
# own — and the bounded grep arm answers instead.
cat > "$T/cg/codegraph" <<'STUB'
#!/bin/bash
echo "boom" >&2
exit 3
STUB
OUT=$(PATH="$T/cg:$PATH" "$SEL" "$R" "$BASE" HEAD 2>"$T/stderr"); RC=$?
ERR=$(cat "$T/stderr")
[ "$RC" = 0 ] && ok || bad "case 14: a failing codegraph must not fail the selector (rc=$RC, err=$ERR)"
[ -z "$ERR" ] && ok || bad "case 14: a failing codegraph must not put a reason on stderr (got: $ERR)"
has tests/c.test.ts && ok || bad "case 14: with codegraph silent the grep arm must answer (got: $(tr '\n' ' ' <<<"$OUT"))"
has tests/b.test.ts && bad "case 14: a failed codegraph run still contributed its tokens" || ok
# A change that ONLY codegraph maps is still unmappable. codegraph answers for
# the whole range, so it names tests without saying which changed file each one
# covers; inventing an owner would let a real hole in coverage read as mapped.
# Its tests join the run and the FULL still fires — wider, never narrower. This
# is pinned here because the ticket's "(a)+(b)+(c) mapped to zero tests" reads
# the other way, and a deviation nobody can see is a deviation nobody can fix.
newrepo fourteenb
mkdir -p .codegraph; printf 'index\n' > .codegraph/index
commit "codegraph index"; BASE=$(git rev-parse HEAD)
printf 'export const orphan = 1;\n' > src/lib/orphan.ts
commit "orphan"
cat > "$T/cg/codegraph" <<'STUB'
#!/bin/bash
[ "$1" = affected ] || exit 1
echo "affected: tests/b.test.ts"
STUB
OUT=$(PATH="$T/cg:$PATH" "$SEL" "$R" "$BASE" HEAD 2>"$T/stderr"); RC=$?
ERR=$(cat "$T/stderr")
[ "$RC" = 2 ] && ok || bad "case 14b: codegraph alone must not make a change mapped (rc=$RC, out=$(tr '\n' ' ' <<<"$OUT"))"
[ "$ERR" = 'FULL: unmappable change src/lib/orphan.ts' ] && ok || bad "case 14b: wrong reason (got: $ERR)"
[ -z "$OUT" ] && ok || bad "case 14b: stdout must be empty (got: $OUT)"

# ---------- 15. source (a) part 2: the verification map on its own ----------
# In case 1 the map entry and the filename convention both point at
# tests/a-map.test.ts, so deleting the map arm changes nothing there. Here the
# entry names a test NOTHING else can reach: no stem match, no importer. If this
# case passes with the verification-map arm removed, the arm is decoration.
newrepo fifteen
printf 'test("vmap", () => {});\n' > tests/vmap-only.test.ts
printf '# b\n\nsrc/lib/b.ts is driven by tests/vmap-only.test.ts.\n' > docs/verification-map/b.md
commit "a map entry for b"; BASE=$(git rev-parse HEAD)
printf 'export const b = 9;\n' > src/lib/b.ts
commit "change b"
run
[ "$RC" = 0 ] && ok || bad "case 15: rc=$RC (err=$ERR)"
has tests/vmap-only.test.ts \
  && ok || bad "case 15: a test named only by the verification-map entry must be selected (got: $(tr '\n' ' ' <<<"$OUT"))"
has tests/a.test.ts && bad "case 15: an entry for another module was read as this one's" || ok

# ---------- 16. the map INDEX is not a map entry ----------------------------
# docs/verification-map/README.md lists every feature and the tests that drive
# it. Read as an entry, it names a changed path (every row does, sooner or
# later) and then contributes EVERY test in the repo's index — which is how the
# first real run of this selector selected a test from an unrelated row.
newrepo sixteen
printf 'test("index", () => {});\n' > tests/index-only.test.ts
printf '# map\n\n| feature | entry |\n|---|---|\n| b | src/lib/b.ts, tests/index-only.test.ts |\n' \
  > docs/verification-map/README.md
commit "a map index"; BASE=$(git rev-parse HEAD)
printf 'export const b = 10;\n' > src/lib/b.ts
commit "change b"
run
[ "$RC" = 0 ] && ok || bad "case 16: rc=$RC (err=$ERR)"
has tests/index-only.test.ts \
  && bad "case 16: the map index was read as an entry — every feature's tests come along" || ok
has tests/b.test.ts && ok || bad "case 16: the real mapping must still work (got: $(tr '\n' ' ' <<<"$OUT"))"

# ---------- 17. the checkout is not the tree --------------------------------
# The importer grep walks the filesystem, and the filesystem can hold files that
# are not at head. An untracked test is dropped at emit time anyway, so if it
# were allowed to mark its module MAPPED the change would escape "unmappable"
# and the build would run the guards instead of the whole suite — narrowed on
# the strength of coverage that exists on one disk and nowhere else.
newrepo seventeen
printf 'export const orphan = 1;\n' > src/lib/orphan.ts
commit "orphan"
printf "import { orphan } from '../src/lib/orphan';\ntest('o', () => {});\n" > tests/orphan.test.ts
run
[ "$RC" = 2 ] && ok || bad "case 17: an untracked test must not map a change (rc=$RC, out=$(tr '\n' ' ' <<<"$OUT"))"
[ "$ERR" = 'FULL: unmappable change src/lib/orphan.ts' ] && ok || bad "case 17: wrong reason (got: $ERR)"
has tests/orphan.test.ts && bad "case 17: an untracked path reached the selection" || ok

# ---------- 18. "docs" is the prose tree at the root, not a route ------------
# app/docs/page.tsx is a Next.js route and src/components/docs/Viewer.tsx is a
# component. Reading either as prose would mean a source file that nothing
# covers never says "unmappable", and the build would run the guards alone and
# call itself green — the one direction that cannot be undone by a later build.
newrepo eighteen
mkdir -p app/docs src/components/docs
printf 'export default function Page() { return null; }\n' > app/docs/page.tsx
commit "a route that lives under docs/"
run
[ "$RC" = 2 ] && ok || bad "case 18: source under a nested docs/ directory must exit 2 (rc=$RC, out=$(tr '\n' ' ' <<<"$OUT"))"
[ "$ERR" = 'FULL: unmappable change app/docs/page.tsx' ] \
  && ok || bad "case 18: the reason must name the route (got: $ERR)"
[ -z "$OUT" ] && ok || bad "case 18: stdout must be empty (got: $OUT)"
newrepo eighteenb
mkdir -p src/components/docs
printf 'export const Viewer = () => null;\n' > src/components/docs/Viewer.tsx
commit "a component that lives under docs/"
run
[ "$RC" = 2 ] && ok || bad "case 18b: a component under docs/ must exit 2 (rc=$RC, out=$(tr '\n' ' ' <<<"$OUT"))"
[ "$ERR" = 'FULL: unmappable change src/components/docs/Viewer.tsx' ] \
  && ok || bad "case 18b: the reason must name the component (got: $ERR)"
# ...and the prose rule still holds where it should: markdown under a nested
# docs/ directory is prose by its extension, so it contributes nothing and the
# diff is still the guards alone. The root docs/ tree (case 7) is unchanged.
newrepo eighteenc
mkdir -p app/docs
printf '# guide\n\nHow the a module works.\n' > app/docs/guide.md
commit "prose under a nested docs/ directory"
run
[ "$RC" = 0 ] && ok || bad "case 18c: nested markdown is still prose (rc=$RC, err=$ERR)"
[ "$OUT" = 'tests/guards/no-secrets.test.ts' ] \
  && ok || bad "case 18c: nested prose must contribute nothing of its own (got: $(tr '\n' ' ' <<<"$OUT"))"

# ---------- 19. source (d): the static guards as a DIRECTORY -----------------
# Both forms are the contract — tests/static-guards.txt lists them, and
# tests/static-guards/ IS them. Every case above uses the .txt form, so without
# this one the directory arm could be deleted and the suite would stay green.
newrepo nineteen
git rm -q tests/static-guards.txt
mkdir -p tests/static-guards
printf 'test("lint", () => {});\n' > tests/static-guards/lint.test.ts
commit "guards as a directory"; BASE=$(git rev-parse HEAD)
printf 'export const a = 12;\n' > src/lib/a.ts
commit "change a"
run
[ "$RC" = 0 ] && ok || bad "case 19: rc=$RC (err=$ERR)"
has tests/static-guards/lint.test.ts \
  && ok || bad "case 19: a guard declared by directory must be selected (got: $(tr '\n' ' ' <<<"$OUT"))"
has tests/b.test.ts && bad "case 19: the guard directory dragged in an unrelated test" || ok

# ---------- 20. always-full: the repo's own list WINS over the default -------
# The built-in regex is the documented fallback, not policy. A repo that ships
# tests/always-full.txt replaces it; a repo file that merely ADDED to the default
# would pass an assertion on src/lib/a.ts alone, so the prisma half below is the
# one that proves the default was dropped.
newrepo twenty
printf '# the a module is too central to narrow around\n^src/lib/a\\.ts$\n' > tests/always-full.txt
commit "an always-full override"; BASE=$(git rev-parse HEAD)
printf 'export const a = 13;\n' > src/lib/a.ts
commit "change a"
run
[ "$RC" = 2 ] && ok || bad "case 20: a path matching the repo's own list must exit 2 (rc=$RC, out=$(tr '\n' ' ' <<<"$OUT"))"
[ "$ERR" = 'FULL: always-full path src/lib/a.ts' ] \
  && ok || bad "case 20: the reason must name the path (got: $ERR)"
[ -z "$OUT" ] && ok || bad "case 20: stdout must be empty (got: $OUT)"
newrepo twentyb
printf '^src/lib/a\\.ts$\n' > tests/always-full.txt
commit "an always-full override"; BASE=$(git rev-parse HEAD)
mkdir -p prisma; printf 'model X {}\n' > prisma/schema.prisma
commit "schema"
run
grep -q '^FULL: always-full path' <<<"$ERR" \
  && bad "case 20b: the built-in default still fired — the repo's list must REPLACE it (got: $ERR)" || ok
[ "$ERR" = 'FULL: unmappable change prisma/schema.prisma' ] \
  && ok || bad "case 20b: with the default dropped the schema is simply unmapped (got: rc=$RC err=$ERR)"

cd "$DIR" || exit 1
echo "test-select-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
