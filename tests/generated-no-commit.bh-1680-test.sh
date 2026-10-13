#!/bin/bash
# tests/generated-no-commit.bh-1680-test.sh — BH-1680: a build does not commit
# the files its target repo declares in its `## Generated files` table. The
# conductor regenerates them on merge, so a builder that also commits one only
# buys a merge conflict on a hunk no ticket is about.
#
# What this pins, against real git repos built in the scratch tree:
#   A  bin/lib/generated-table.sh reads the table the way mc_regen_table does
#      (three homes, deduped, separator rows skipped), and a row flagged
#      `committed` in a later cell is kept out of the no-commit set.
#   B  gen_nocommit_strip resets exactly the declared paths to the merge-base
#      and commits that once; a diff touching nothing declared, a diff that is
#      ONLY declared files, and a commit that fails all leave HEAD alone. Paths
#      that merely look like a declared one are never stripped.
#   C  the `# >>> generated no-commit` block of bin/run-build.sh, lifted from the
#      flattened driver, strips in place and the PR body rendered by the lifted
#      evidence block carries the one line, once, and only when it is true.
#   D  this repo's own table: rules/CLAUDE.md is declared and COMMITTED, so it is
#      never stripped.
#
# No network, no clock. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/generated-no-commit.bh-1680-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/bin/lib/generated-table.sh"
# shellcheck disable=SC1090
. "$LIB" 2>/dev/null || bad "bin/lib/generated-table.sh does not source"
for fn in gen_table_paths gen_nocommit_paths gen_path_matches gen_nocommit_strip gen_nocommit_line; do
  type "$fn" >/dev/null 2>&1 && ok || bad "bin/lib/generated-table.sh does not define $fn"
done
bash -n "$LIB" 2>/dev/null && ok || bad "bash -n bin/lib/generated-table.sh"
# Sourcing is side-effect free: a lib that ran a command at source time would
# run it inside every build.
( cd "$T" && out=$(bash -c '. "$1"' _ "$LIB" 2>&1) && [ -z "$out" ] ) \
  && ok || bad "sourcing bin/lib/generated-table.sh must print nothing"

TABLE_AA='# Architecture

## Generated files

| path | regenerate with | committed |
| --- | --- | --- |
| `scripts/worker-import-set.json` | `node scripts/gen-imports.js` |
| `rules/CLAUDE.md` | `bin/render-rules.sh --write` | committed |

## Something else
| `not/a-row.json` | `nope` |
'

# mkfix <name> <table-file-or-"none"> [table-text] — a repo at the moment the
# stage runs: base commit on main (origin/main points at it), then a ticket branch.
mkfix() {
  local r="$T/$1" home="$2" text="${3:-$TABLE_AA}"
  scratch_rm "$r"; mkdir -p "$r/scripts" "$r/src/scripts" "$r/rules/topics"
  git -C "$r" init -q -b main
  git -C "$r" config user.email harness@example.invalid
  git -C "$r" config user.name harness-test
  git -C "$r" config commit.gpgsign false
  echo '{"v":1}' > "$r/scripts/worker-import-set.json"
  echo 'bak 1'   > "$r/scripts/worker-import-set.json.bak"
  echo 'nested 1' > "$r/src/scripts/worker-import-set.json"
  echo 'export const a = 1' > "$r/src/a.js"
  echo 'topic 1' > "$r/rules/topics/10-x.md"
  echo 'render 1' > "$r/rules/CLAUDE.md"
  if [ "$home" != none ]; then
    mkdir -p "$r/$(dirname "$home")"
    printf '%s' "$text" > "$r/$home"
  fi
  git -C "$r" add -A && git -C "$r" commit -qm base
  git -C "$r" update-ref refs/remotes/origin/main HEAD
  git -C "$r" checkout -qb ticket/bh-9
}
edit() { # edit <repo> <msg> <path>... — change each path on the branch, one commit
  local r="$1" m="$2" p; shift 2
  for p in "$@"; do mkdir -p "$r/$(dirname "$p")"; echo "edited $p" >> "$r/$p"; done
  git -C "$r" add -A && git -C "$r" commit -qm "$m"
}
mb()      { git -C "$1" merge-base origin/main HEAD; }
changed() { git -C "$1" diff --name-only --no-renames "$(mb "$1")" HEAD | sort | tr '\n' ' '; }
strip()   { # strip <repo> <list> -> runs gen_nocommit_strip in the repo; stdout to $T/strip.out
  type gen_nocommit_strip >/dev/null 2>&1 || { echo 127; return; }
  ( cd "$1" && gen_nocommit_strip origin/main "$2" BH-9 ) > "$T/strip.out" 2>&1
  echo "$?"
}

# ============================== A. the reader ==============================
mkfix a1 AGENT_ARCHITECTURE.md
[ "$(gen_table_paths "$T/a1" HEAD 2>/dev/null | tr '\n' ' ')" = "scripts/worker-import-set.json rules/CLAUDE.md " ] \
  && ok || bad "A1 gen_table_paths should print both declared rows in order: '$(gen_table_paths "$T/a1" HEAD 2>&1 | tr '\n' ' ')'"

mkfix a2 none
out=$(gen_table_paths "$T/a2" HEAD 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "A2 no table: gen_table_paths must print nothing, rc 0 (rc=$rc out=$out)"
out=$(gen_nocommit_paths "$T/a2" HEAD 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "A2 no table: gen_nocommit_paths must print nothing, rc 0 (rc=$rc out=$out)"
out=$(gen_table_paths "$T/does-not-exist" HEAD 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "A2 missing dir: must print nothing, rc 0 (rc=$rc out=$out)"
out=$(gen_table_paths "$T/a1" no-such-ref 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "A2 missing ref: must print nothing, rc 0 (rc=$rc out=$out)"

# A3: tail.md home, separator row, backticked command, a path declared in two homes
TAIL3='# tail

## Generated files

| path | regenerate with |
|---|---|
| `scripts/worker-import-set.json` | `node scripts/gen-imports.js --write` |
| `catalog/*.json` | `bin/lanes-build.sh --write` |
'
mkfix a3 docs/verification-map/index/tail.md "$TAIL3"
printf '%s' "$TABLE_AA" > "$T/a3/AGENT_ARCHITECTURE.md"
git -C "$T/a3" add -A && git -C "$T/a3" commit -qm both-homes
[ "$(gen_table_paths "$T/a3" HEAD 2>/dev/null | tr '\n' ' ')" = "scripts/worker-import-set.json rules/CLAUDE.md catalog/*.json " ] \
  && ok || bad "A3 union of homes, deduped, separator skipped: '$(gen_table_paths "$T/a3" HEAD 2>&1 | tr '\n' ' ')'"

# A4: the committed flag
[ "$(gen_nocommit_paths "$T/a1" HEAD 2>/dev/null | tr '\n' ' ')" = "scripts/worker-import-set.json " ] \
  && ok || bad "A4 gen_nocommit_paths must drop the committed row: '$(gen_nocommit_paths "$T/a1" HEAD 2>&1 | tr '\n' ' ')'"
# case-insensitive, backticked flag cell
mkfix a4 AGENT_ARCHITECTURE.md '## Generated files
| path | regenerate with | committed |
| --- | --- | --- |
| `a/one.json` | `gen` | `Committed` |
| `a/two.json` | `gen` |  |
'
[ "$(gen_nocommit_paths "$T/a4" HEAD 2>/dev/null | tr '\n' ' ')" = "a/two.json " ] \
  && ok || bad "A4 a backticked/capitalised committed flag must still keep the row: '$(gen_nocommit_paths "$T/a4" HEAD 2>&1 | tr '\n' ' ')'"

# the matcher: literal and glob, whole-path only
gen_path_matches catalog/lanes.json 'catalog/*.json' 2>/dev/null && ok || bad "gen_path_matches: a glob row must match"
gen_path_matches scripts/worker-import-set.json scripts/worker-import-set.json 2>/dev/null && ok || bad "gen_path_matches: a literal row must match itself"
for neg in scripts/worker-import-set.json.bak scripts/worker-import-set.jsonx src/scripts/worker-import-set.json; do
  gen_path_matches "$neg" scripts/worker-import-set.json 2>/dev/null && bad "gen_path_matches: $neg must not match a literal row" || ok
done

# ============================== B. the strip ==============================
# B1: a declared file plus real code — only the code survives, one commit added
mkfix b1 AGENT_ARCHITECTURE.md
edit "$T/b1" "BH-9: code and a regenerated file" scripts/worker-import-set.json src/a.js
N0=$(git -C "$T/b1" rev-list --count HEAD)
rc=$(strip "$T/b1" "$T/b1.list")
[ "$rc" = 0 ] && ok || bad "B1 strip must return 0 (rc=$rc: $(cat "$T/strip.out"))"
[ "$(changed "$T/b1")" = "src/a.js " ] && ok || bad "B1 the diff must be src/a.js only, got '$(changed "$T/b1")'"
[ "$(cat "$T/b1.list" 2>/dev/null)" = "scripts/worker-import-set.json" ] && ok || bad "B1 the list must name the stripped path, got '$(cat "$T/b1.list" 2>/dev/null)'"
[ "$(git -C "$T/b1" rev-list --count HEAD)" = $((N0 + 1)) ] && ok || bad "B1 exactly one strip commit"
grep -q 'BH-9' <<<"$(git -C "$T/b1" log -1 --format=%s)" && ok || bad "B1 the strip commit names the ticket: $(git -C "$T/b1" log -1 --format=%s)"
[ -z "$(git -C "$T/b1" status --porcelain)" ] && ok || bad "B1 the working tree must be clean after the strip: $(git -C "$T/b1" status --porcelain)"

# B2: a declared file the branch ADDED is removed from HEAD
mkfix b2 AGENT_ARCHITECTURE.md '## Generated files
| path | regenerate with |
| --- | --- |
| `gen/new.json` | `gen` |
'
edit "$T/b2" "BH-9: add" gen/new.json src/a.js
rc=$(strip "$T/b2" "$T/b2.list")
[ "$rc" = 0 ] && ! git -C "$T/b2" cat-file -e HEAD:gen/new.json 2>/dev/null && [ "$(changed "$T/b2")" = "src/a.js " ] \
  && ok || bad "B2 an added declared file must be gone from HEAD (rc=$rc diff='$(changed "$T/b2")')"

# B3: nothing declared touched — HEAD and list untouched
mkfix b3 AGENT_ARCHITECTURE.md
edit "$T/b3" "BH-9: code" src/a.js
H0=$(git -C "$T/b3" rev-parse HEAD)
rc=$(strip "$T/b3" "$T/b3.list")
[ "$rc" = 0 ] && [ "$(git -C "$T/b3" rev-parse HEAD)" = "$H0" ] && [ ! -s "$T/b3.list" ] \
  && ok || bad "B3 a diff touching nothing declared must leave HEAD and the list alone (rc=$rc)"

# B4: ONLY the declared file (plus the spec artifact) — the ticket is about it; leave it
mkfix b4 AGENT_ARCHITECTURE.md
edit "$T/b4" "BH-9: the file itself" scripts/worker-import-set.json .harness/specs/BH-9/plan.md
H0=$(git -C "$T/b4" rev-parse HEAD)
rc=$(strip "$T/b4" "$T/b4.list")
[ "$rc" = 0 ] && [ "$(git -C "$T/b4" rev-parse HEAD)" = "$H0" ] && [ ! -s "$T/b4.list" ] \
  && ok || bad "B4 a diff that is only declared files must not be stripped (rc=$rc)"
grep -qi 'skip' "$T/strip.out" && grep -q 'scripts/worker-import-set.json' "$T/strip.out" \
  && ok || bad "B4 the skip must be said, naming the path: '$(cat "$T/strip.out")'"

# B5a: the index is locked — nothing moves, nothing claimed
mkfix b5 AGENT_ARCHITECTURE.md
edit "$T/b5" "BH-9: code and a regenerated file" scripts/worker-import-set.json src/a.js
H0=$(git -C "$T/b5" rev-parse HEAD)
: > "$T/b5/.git/index.lock"
rc=$(strip "$T/b5" "$T/b5.list")
rm -f "$T/b5/.git/index.lock"
[ "$rc" = 0 ] && [ "$(git -C "$T/b5" rev-parse HEAD)" = "$H0" ] && [ ! -s "$T/b5.list" ] \
  && [ -z "$(git -C "$T/b5" status --porcelain)" ] \
  && ok || bad "B5a locked index: HEAD, list and tree must be untouched (rc=$rc status=$(git -C "$T/b5" status --porcelain))"
# B5b: the checkout succeeds and the COMMIT fails (no committer identity) — the
# paths go back to HEAD, nothing else changes, nothing claimed.
mkfix b5b AGENT_ARCHITECTURE.md
edit "$T/b5b" "BH-9: code and a regenerated file" scripts/worker-import-set.json src/a.js
echo 'uncommitted work' >> "$T/b5b/src/a.js"
H0=$(git -C "$T/b5b" rev-parse HEAD)
git -C "$T/b5b" config --unset user.email; git -C "$T/b5b" config --unset user.name
git -C "$T/b5b" config user.useConfigOnly true
rc=$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 EMAIL='' strip "$T/b5b" "$T/b5b.list")
[ "$rc" = 0 ] && [ "$(git -C "$T/b5b" rev-parse HEAD)" = "$H0" ] && [ ! -s "$T/b5b.list" ] \
  && [ "$(git -C "$T/b5b" status --porcelain)" = " M src/a.js" ] \
  && git -C "$T/b5b" diff --quiet HEAD -- scripts/worker-import-set.json \
  && ok || bad "B5b failed commit: HEAD/list untouched, declared path back at HEAD, other edits kept (rc=$rc status=$(git -C "$T/b5b" status --porcelain | tr '\n' ';') out=$(cat "$T/strip.out"))"
grep -qi 'fail' "$T/strip.out" && ok || bad "B5b a failed commit must be said: '$(cat "$T/strip.out")'"

# B6: look-alikes and the committed row stay; only the declared literal goes
mkfix b6 AGENT_ARCHITECTURE.md
edit "$T/b6" "BH-9: many" scripts/worker-import-set.json scripts/worker-import-set.json.bak \
  src/scripts/worker-import-set.json rules/topics/10-x.md rules/CLAUDE.md
rc=$(strip "$T/b6" "$T/b6.list")
[ "$(changed "$T/b6")" = "rules/CLAUDE.md rules/topics/10-x.md scripts/worker-import-set.json.bak src/scripts/worker-import-set.json " ] \
  && ok || bad "B6 only the declared literal may be stripped (rc=$rc), diff='$(changed "$T/b6")'"

# B7: a heading with zero rows strips nothing
mkfix b7 AGENT_ARCHITECTURE.md '## Generated files

nothing here yet
'
edit "$T/b7" "BH-9: code" scripts/worker-import-set.json src/a.js
H0=$(git -C "$T/b7" rev-parse HEAD)
rc=$(strip "$T/b7" "$T/b7.list")
[ "$rc" = 0 ] && [ "$(git -C "$T/b7" rev-parse HEAD)" = "$H0" ] && ok || bad "B7 an empty table strips nothing (rc=$rc)"

# ============================== C. the driver block ==============================
awk '/^# >>> generated no-commit/{f=1;next} /^# <<< generated no-commit/{exit} f' "$RB_ALL" > "$T/gen.sh"
[ -s "$T/gen.sh" ] && grep -q gen_nocommit_strip "$T/gen.sh" && ok || bad "could not lift '# >>> generated no-commit' out of the driver"
awk '/^# >>> evidence block/{f=1;next} /^# <<< evidence block/{exit} f' "$RB_ALL" > "$T/evid.sh"
[ -s "$T/evid.sh" ] && ok || bad "could not lift the evidence block"
# It must run between the spec artifact and the first push, so gates, review and
# the head-bound approval all see the stripped head.
L_SPEC=$(grep -n '^# <<< spec artifact' "$RB_ALL" | head -1 | cut -d: -f1)
L_GEN=$(grep -n '^# >>> generated no-commit' "$RB_ALL" | head -1 | cut -d: -f1)
L_PUSH=$(grep -n '^PUSH_BRANCH execute' "$RB_ALL" | head -1 | cut -d: -f1)
[ -n "$L_GEN" ] && [ -n "$L_SPEC" ] && [ -n "$L_PUSH" ] && [ "$L_SPEC" -lt "$L_GEN" ] && [ "$L_GEN" -lt "$L_PUSH" ] \
  && ok || bad "the block must sit after '# <<< spec artifact' and before 'PUSH_BRANCH execute' (spec=$L_SPEC gen=$L_GEN push=$L_PUSH)"

mkdir -p "$T/build" "$T/nowhere"
# runblock <repo> <harness> <block> -> rc; PR body in $T/body.txt
runblock() {
  rm -f "$T/body.txt"; : > "$T/build/pipeline.log"
  ( cd "$1" && env HARNESS="$2" BUILD="$T/build" KEY=BH-9 PROJECT=demo BASE=origin/main T="$T" \
    bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      SPEC_LINE="Spec: the plan is in this PR."
      . "$0" || exit 91
      HARNESS="$T/nowhere"; SLUG=o/r; TIER=2; QA_NOTE=""; MIG_NOTE=""; ADDED_SQL=""; E2E_VERDICT=pass
      CHANGED="x"; TAMPER_RC=0; REPRO_RC=0; INTENT_RC=0; EVIDENCE_BLOCK=0
      WHAT_LIST="- did a thing"; WHY_EXCERPT="because"; VERIFY_LINE="v"
      PLAN_MODEL=pm; EXECUTE_MODEL=em; REVIEW_MODEL=rm; MIG_SECTION=""; COST_LINE="c"; MERGE_NOTE=""
      CTX_SIG=sig; CTX_COMMIT=abc; CTX_SYNC=yes; CTX_FRESH=yes; PR_SUBJECT="the subject"
      . "$1" || exit 92
      PR_BODY_FOR "$EVIDENCE_SECTION" > "$2"
    ' "$3" "$T/evid.sh" "$T/body.txt" ) > "$T/block.out" 2>&1
  echo "$?"
}
LINE='Generated files not committed: `scripts/worker-import-set.json` — regenerated on merge by the conductor.'
count_line() { [ -f "$T/body.txt" ] || { echo missing-body; return; }; grep -cF "$LINE" "$T/body.txt"; }

# C1: the real block, the real lib, the B1 shape
mkfix c1 AGENT_ARCHITECTURE.md
edit "$T/c1" "BH-9: code and a regenerated file" scripts/worker-import-set.json src/a.js
rm -f "$T/build/generated-not-committed.txt"
rc=$(runblock "$T/c1" "$DIR" "$T/gen.sh")
[ "$rc" = 0 ] && ok || bad "C1 block + body must exit 0 (rc=$rc: $(cat "$T/block.out"))"
[ "$(changed "$T/c1")" = "src/a.js " ] && ok || bad "C1 the block must strip the declared file, diff='$(changed "$T/c1")'"
[ "$(count_line)" = 1 ] && ok || bad "C1 the PR body must carry the line exactly once (got $(count_line)): $(cat "$T/body.txt" 2>/dev/null | head -20)"
grep -qF 'Spec: the plan is in this PR.' "$T/body.txt" 2>/dev/null && ok || bad "C1 the spec line must survive beside it"
grep -q 'generated no-commit' "$T/build/pipeline.log" && ok || bad "C1 one pipeline.log line: $(cat "$T/build/pipeline.log")"

# C2: resume re-entry — no second commit, still exactly one line
N1=$(git -C "$T/c1" rev-list --count HEAD)
rc=$(runblock "$T/c1" "$DIR" "$T/gen.sh")
[ "$rc" = 0 ] && [ "$(git -C "$T/c1" rev-list --count HEAD)" = "$N1" ] && [ "$(count_line)" = 1 ] \
  && ok || bad "C2 re-entry: no new commit, line once (rc=$rc commits $N1->$(git -C "$T/c1" rev-list --count HEAD) lines=$(count_line))"
# ...and if the file came BACK after the strip, the line would be false: it goes.
# (A fix round lands AFTER this block, so it is never re-stripped; the line
# builder alone decides, and it reads the committed tree, not the list.)
edit "$T/c1" "BH-9: fix round re-added it" scripts/worker-import-set.json
out=$( cd "$T/c1" && gen_nocommit_line origin/main "$T/build/generated-not-committed.txt" 2>&1 )
[ -z "$out" ] && ok || bad "C2 a path back in the diff must not be claimed as not committed: '$out'"

# C3: no table — the file ships as before, no line
mkfix c3 none
edit "$T/c3" "BH-9: code and a file" scripts/worker-import-set.json src/a.js
rm -f "$T/build/generated-not-committed.txt"
rc=$(runblock "$T/c3" "$DIR" "$T/gen.sh")
[ "$rc" = 0 ] && [ "$(changed "$T/c3")" = "scripts/worker-import-set.json src/a.js " ] && [ "$(count_line)" = 0 ] \
  && ! grep -q 'Generated files not committed' "$T/body.txt" \
  && ok || bad "C3 no table: diff unchanged, no line (rc=$rc diff='$(changed "$T/c3")')"

# C4: a box without the lib — silent no-op
mkfix c4 AGENT_ARCHITECTURE.md
edit "$T/c4" "BH-9: code and a regenerated file" scripts/worker-import-set.json src/a.js
rm -f "$T/build/generated-not-committed.txt"
rc=$(runblock "$T/c4" "$T/nowhere" "$T/gen.sh")
[ "$rc" = 0 ] && [ "$(changed "$T/c4")" = "scripts/worker-import-set.json src/a.js " ] && [ "$(count_line)" = 0 ] \
  && ok || bad "C4 no lib: no-op, rc 0, no line (rc=$rc diff='$(changed "$T/c4")': $(cat "$T/block.out"))"

# C5 (mutation, D1): the same block with its strip call deleted leaves the file
# in the diff and no line — so C1 is proving the call, not the fixture.
sed 's/gen_nocommit_strip "/: "/' "$T/gen.sh" > "$T/gen-mut.sh"
if cmp -s "$T/gen.sh" "$T/gen-mut.sh"; then
  bad "C5 mutation removed nothing — the block's call site moved?"
else
  mkfix c5 AGENT_ARCHITECTURE.md
  edit "$T/c5" "BH-9: code and a regenerated file" scripts/worker-import-set.json src/a.js
  rm -f "$T/build/generated-not-committed.txt"
  rc=$(runblock "$T/c5" "$DIR" "$T/gen-mut.sh")
  [ "$rc" = 0 ] && [ "$(changed "$T/c5")" = "scripts/worker-import-set.json src/a.js " ] && [ "$(count_line)" = 0 ] \
    && ok || bad "C5 with the call deleted nothing may be stripped or claimed"
fi

# ============================== D. this repo ==============================
D_ALL=$(gen_table_paths "$DIR" HEAD 2>/dev/null)
D_NC=$(gen_nocommit_paths "$DIR" HEAD 2>/dev/null)
grep -qx 'rules/CLAUDE.md' <<<"$D_ALL" && ok || bad "D1 this repo declares rules/CLAUDE.md in its table"
grep -qx 'catalog/lanes.json' <<<"$D_NC" && ok || bad "D1 this repo's uncommitted rows are in the no-commit set: '$D_NC'"
grep -qx 'rules/CLAUDE.md' <<<"$D_NC" && bad "D1 rules/CLAUDE.md is a COMMITTED render and must not be strip-eligible" || ok

# D2: this repo's own table text in a fixture — rules/* stay, catalog/lanes.json goes
mkfix d2 docs/verification-map/index/tail.md "$(cat "$DIR/docs/verification-map/index/tail.md")"
mkdir -p "$T/d2/catalog"; echo '[]' > "$T/d2/catalog/lanes.json"
git -C "$T/d2" add -A && git -C "$T/d2" commit -qm lanes && git -C "$T/d2" update-ref refs/remotes/origin/main HEAD
edit "$T/d2" "BH-9: a rule edit" rules/topics/10-x.md rules/CLAUDE.md catalog/lanes.json
rc=$(strip "$T/d2" "$T/d2.list")
[ "$rc" = 0 ] && [ "$(changed "$T/d2")" = "rules/CLAUDE.md rules/topics/10-x.md " ] \
  && ok || bad "D2 rules/CLAUDE.md and its topic stay, catalog/lanes.json goes (rc=$rc diff='$(changed "$T/d2")')"

echo "generated-no-commit.bh-1680: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
