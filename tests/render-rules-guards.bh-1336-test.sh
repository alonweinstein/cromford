#!/bin/bash
# tests/render-rules-guards.bh-1336-test.sh — BH-1336 (BH-561 follow-ups 1 and 2).
#
# WHAT WAS MISSING. BH-561 made rules/CLAUDE.md a RENDER of rules/topics/*.md,
# and left it committed, because five scripts copy it verbatim onto every box.
# A committed render needs the two guards main's other renders already have,
# and it had neither:
#
#   1. CI never ran `bin/render-rules.sh --check` directly. The only reader was
#      tests/render-rules-test.sh B6, which runs when test-impact SELECTS it —
#      so a topic edit committed without `--write` could reach main behind a
#      selection that never picked that suite up.
#   2. rules/CLAUDE.md was in no `## Generated files` row, so a train or a
#      rebase that conflicted in it HAND-MERGED a generated file: two siblings'
#      renders glued together, which is a file nobody wrote. #853 needed a hand
#      commit for exactly that drift.
#
# WHAT THIS SUITE IS WORTH. Every case drives production code or real git:
#
#   R1 the REAL regen_table/regen_cmd_for/path_allowed, extracted from
#      bin/batch-resolve.sh by function name, and the REAL mc_regen_table from
#      bin/lib/mc/rebase.sh — both over a scratch repo carrying THIS branch's
#      docs/verification-map/index/tail.md. An extraction that comes back empty
#      FAILS rather than silently testing nothing.
#   R2 the conflict story on REAL git: two siblings that each ADD a topic and
#      re-render collide in the generated table of contents, so they conflict
#      in rules/CLAUDE.md and in neither topic file — and only there. The
#      union resolution (take one side, regenerate) is drift-free and keeps both
#      edits, and the REAL mc_regen_generated does that regenerate by itself.
#   R3 the workflow file's lane-renders step, located by its `name:` — absent
#      step is a FAIL, never a pass — plus the mutated fixture that proves the
#      assertion can go red.
#   R4 the drift the new CI line turns red on, from the REAL renderer.
#   R5 the shipped rules file is the render of its topics and carries the banner
#      clause that says so.
#
# No network, no clock, no gh: scratch trees under $T and nothing else.
# Run from anywhere:  bash tests/render-rules-guards.bh-1336-test.sh
# As root next to a live harness:
#   HARNESS_TEST_SANDBOX=1 bash tests/render-rules-guards.bh-1336-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
BR="$DIR/bin/batch-resolve.sh"
MCL="$DIR/bin/lib/merge-conductor-lib.sh"
RR="$DIR/bin/render-rules.sh"
RF="$DIR/bin/lib/render-fragments.sh"
WF="${BH1336_WORKFLOW:-$DIR/.github/workflows/harness-ci.yml}"
ROW=$'rules/CLAUDE.md\tbin/render-rules.sh --write'
STEP='lane renders generate and their sources validate'

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
done_() { echo "render-rules-guards.bh-1336: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]; }

command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
[ -r "$BR" ]  || { echo "FAIL: bin/batch-resolve.sh is missing"; exit 1; }
[ -r "$MCL" ] || { echo "FAIL: bin/lib/merge-conductor-lib.sh is missing"; exit 1; }
[ -x "$RR" ]  || { echo "FAIL: bin/render-rules.sh is missing or not executable"; exit 1; }
[ -r "$WF" ]  || { echo "FAIL: $WF is missing"; exit 1; }

export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false

# ============================================================================
# R1 both production parsers print the row, and nothing else claims it
# ============================================================================
SR="$T/declared"
mkdir -p "$SR/docs/verification-map/index"
cp "$DIR/docs/verification-map/index/tail.md" "$SR/docs/verification-map/index/tail.md"
cp "$DIR/.gitattributes" "$SR/.gitattributes" 2>/dev/null || :
git init -q -b main "$SR"
git -C "$SR" add -A
git -C "$SR" commit -qm "this branch's table, as it ships"
git -C "$SR" update-ref refs/remotes/origin/main "$(git -C "$SR" rev-parse HEAD)"

# The batch-resolve half, extracted by name. show_base is what the lane reads
# the repo's own claims through; bound here to the scratch repo's origin/main.
SRC=""
for fn in regen_table regen_cmd_for path_allowed; do
  b=$(sed -n "/^$fn()/,/^}/p" "$BR")
  if [ -z "$b" ]; then bad "R1: could not extract $fn() from bin/batch-resolve.sh — the suite would test nothing"; done_; exit 1; fi
  SRC="$SRC$b"$'\n'
done
b=$(grep -m1 '^union_paths() {.*}$' "$BR")
if [ -z "$b" ]; then bad "R1: could not extract union_paths() from bin/batch-resolve.sh — the suite would test nothing"; done_; exit 1; fi
SRC="$SRC$b"$'\n'
show_base() { git -C "$SR" show "origin/main:$1" 2>/dev/null; }
# shellcheck disable=SC1090
eval "$SRC"
ok

BR_TABLE=$(regen_table)
UNION_PATHS=$(union_paths)
REGEN_TABLE="$BR_TABLE"
N=$(printf '%s\n' "$BR_TABLE" | grep -cx -F "$ROW")
[ "$N" = 1 ] && ok || bad "R1: regen_table must print exactly one 'rules/CLAUDE.md<TAB>bin/render-rules.sh --write' row (got $N). Table:
$(printf '%s' "$BR_TABLE" | cat -A | head -20)"

# The mc half — the same table through the parser the conductor and the pool
# rebases use (BH-968). mc_log writes under $HARNESS, so it gets a scratch one.
MC_TABLE=$(
  export HARNESS="$T/h"; mkdir -p "$HARNESS/logs" "$HARNESS/state" "$HARNESS/bin"
  # shellcheck source=/dev/null
  . "$MCL" >/dev/null 2>&1 && mc_init >/dev/null 2>&1
  command -v mc_regen_table >/dev/null 2>&1 || exit 9
  mc_regen_table "$SR" HEAD
)
[ -n "$MC_TABLE" ] && ok || bad "R1: mc_regen_table could not be sourced or printed nothing — the suite would test nothing"
N=$(printf '%s\n' "$MC_TABLE" | grep -cx -F "$ROW")
[ "$N" = 1 ] && ok || bad "R1: mc_regen_table must print the same single row (got $N)"
[ "$MC_TABLE" = "$BR_TABLE" ] && ok \
  || bad "R1: the two parsers must read the same table (mc/br differ):
$(diff <(printf '%s\n' "$BR_TABLE") <(printf '%s\n' "$MC_TABLE") | head -10)"

# The classifier: the rendered file is regenerable, its INPUTS are not, and the
# renderer itself is not. A glob row would claim the topics the file is built
# FROM, and a conflicted path with a regenerate command is resolved by taking
# one side — one sibling's topic edit would vanish with every check green.
[ "$(regen_cmd_for rules/CLAUDE.md)" = 'bin/render-rules.sh --write' ] && ok \
  || bad "R1: regen_cmd_for rules/CLAUDE.md must print the render command (got '$(regen_cmd_for rules/CLAUDE.md)')"
for p in rules/topics/04-building-software.md rules/topics/00-intro.md bin/render-rules.sh; do
  [ -z "$(regen_cmd_for "$p")" ] && ok \
    || bad "R1: regen_cmd_for must claim NOTHING for $p (got '$(regen_cmd_for "$p")') — a rendered file's inputs are hand-written"
  if path_allowed "$p"; then bad "R1: path_allowed accepted $p — a source conflict must take today's path"; else ok; fi
done
path_allowed rules/CLAUDE.md && ok || bad "R1: path_allowed must accept the declared rules/CLAUDE.md"
# …and the row must not have arrived by way of a new union attribute: a
# union-concatenated markdown with a TOC is a file nobody wrote.
ATTR=$(git -C "$DIR" check-attr merge -- rules/CLAUDE.md 2>/dev/null | sed 's/.*: merge: //')
[ "$ATTR" = unspecified ] && ok \
  || bad "R1: rules/CLAUDE.md must carry NO merge attribute (got $ATTR) — it is resolved by regenerating, not by concatenating"

# ============================================================================
# R2 the conflict story, on real git
# ============================================================================
# A miniature of this repo: rules/topics/, the REAL renderer and its REAL
# fragment library, a committed render, and a table declaring that one row.
SR2="$T/rules-repo"
mkdir -p "$SR2/rules/topics" "$SR2/bin/lib" "$SR2/docs/verification-map/index"
cp "$RR" "$SR2/bin/render-rules.sh"; chmod +x "$SR2/bin/render-rules.sh"
cp "$RF" "$SR2/bin/lib/render-fragments.sh"
printf '# Miniature rules\nthe preamble\n' > "$SR2/rules/topics/00-intro.md"
printf '## One\nalpha base\n'             > "$SR2/rules/topics/10-a.md"
printf '## Two\nbeta base\n'              > "$SR2/rules/topics/20-b.md"
cat > "$SR2/docs/verification-map/index/tail.md" <<'EOF'
## Generated files

| path | regenerate with |
| --- | --- |
| `rules/CLAUDE.md` | `bin/render-rules.sh --write` |
EOF
git init -q -b main "$SR2"
( cd "$SR2" && bash bin/render-rules.sh --write ) >/dev/null 2>&1
git -C "$SR2" add -A
git -C "$SR2" commit -qm "the committed render"
git -C "$SR2" update-ref refs/remotes/origin/main "$(git -C "$SR2" rev-parse HEAD)"
[ -s "$SR2/rules/CLAUDE.md" ] && ok || bad "R2: the fixture must start with a rendered rules/CLAUDE.md"

# Each sibling adds a topic of its own and re-renders — the shape #853 hit. The
# topic FILES cannot conflict (one file each), and the generated `## Contents`
# list is where they collide: both insert a line at the same place, which is
# what a hand merge of a rendered TOC is asked to resolve.
sib2() { # sib2 <branch> <topic file> <heading> <body>
  git -C "$SR2" checkout -q -b "$1" main
  printf '## %s\n%s\n' "$3" "$4" > "$SR2/rules/topics/$2"
  ( cd "$SR2" && bash bin/render-rules.sh --write ) >/dev/null 2>&1
  git -C "$SR2" add -A
  git -C "$SR2" commit -qm "$1"
}
sib2 sib-a 30-a.md 'Three A' 'alpha SIDE A'
sib2 sib-b 40-b.md 'Four B'  'beta SIDE B'
git -C "$SR2" checkout -q main

MT=$(git -C "$SR2" merge-tree --write-tree --name-only sib-a sib-b 2>&1); MTRC=$?
[ "$MTRC" != 0 ] && ok \
  || bad "R2: two siblings editing different topics and re-rendering MUST conflict in the render — the fixture proves nothing otherwise (rc=$MTRC)"
CONF=$(printf '%s\n' "$MT" | awk 'NR>1 { if (NF == 0) exit; print }')
[ "$CONF" = 'rules/CLAUDE.md' ] && ok \
  || bad "R2: the conflict must be the render and ONLY the render (got: $(printf '%s' "$CONF" | tr '\n' ' '))"

# The union resolution, exactly as build_union performs it: take one side on a
# path that has a regenerate command, then run the command over the merged tree.
WT="$T/union"
git clone -q "$SR2" "$WT" >/dev/null 2>&1
git -C "$WT" checkout -q -B union origin/sib-a
git -C "$WT" merge -q --no-edit origin/sib-b >/dev/null 2>&1
U=$(git -C "$WT" diff --name-only --diff-filter=U)
[ "$U" = 'rules/CLAUDE.md' ] && ok || bad "R2: the merge must leave rules/CLAUDE.md unmerged and nothing else (got '$U')"
git -C "$WT" checkout -q --theirs -- rules/CLAUDE.md
git -C "$WT" add -- rules/CLAUDE.md
bash "$RR" --root "$WT" --check >/dev/null 2>&1; RC=$?
[ "$RC" != 0 ] && ok \
  || bad "R2: taking one side alone must LEAVE the render drifted — otherwise the regenerate step is proving nothing (rc=$RC)"
bash "$RR" --root "$WT" --write >/dev/null 2>&1
bash "$RR" --root "$WT" --check >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "R2: the regenerate over the union must leave no drift (rc=$RC)"
A=$(grep -c '^alpha SIDE A$' "$WT/rules/CLAUDE.md"); B=$(grep -c '^beta SIDE B$' "$WT/rules/CLAUDE.md")
[ "$A" = 1 ] && [ "$B" = 1 ] && ok \
  || bad "R2: the regenerated render must carry each sibling's edit exactly once (a=$A b=$B)"

# …and the REAL mc_regen_generated does that second step by itself, which is
# what the table row buys on the rebase paths.
WT2="$T/rebase"
git clone -q "$SR2" "$WT2" >/dev/null 2>&1
git -C "$WT2" checkout -q -B rebased origin/sib-a
git -C "$WT2" merge -q --no-edit origin/sib-b >/dev/null 2>&1
git -C "$WT2" checkout -q --theirs -- rules/CLAUDE.md
git -C "$WT2" add -- rules/CLAUDE.md
git -C "$WT2" commit -qm "merge sib-b, render taken from one side" >/dev/null 2>&1
BEFORE=$(git -C "$WT2" rev-parse HEAD)
(
  export HARNESS="$T/h2"; mkdir -p "$HARNESS/logs" "$HARNESS/state" "$HARNESS/bin"
  # shellcheck source=/dev/null
  . "$MCL" >/dev/null 2>&1
  command -v mc_regen_generated >/dev/null 2>&1 || exit 9
  mc_regen_generated "$WT2" origin/main "bh-1336 test"
) >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "R2: mc_regen_generated must be reachable and return 0 (got $RC)"
EXTRA=$(git -C "$WT2" rev-list --count "$BEFORE..HEAD")
[ "$EXTRA" = 1 ] && ok || bad "R2: the rebase regenerate must add exactly ONE commit (got $EXTRA)"
SUBJ=$(git -C "$WT2" log -1 --format=%s)
case "$SUBJ" in
  "regenerate rules/CLAUDE.md"*) ok ;;
  *) bad "R2: the regenerate commit must name the path it regenerated (got '$SUBJ')" ;;
esac
bash "$RR" --root "$WT2" --check >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "R2: after mc_regen_generated the head must be drift-free (rc=$RC)"
A=$(grep -c '^alpha SIDE A$' "$WT2/rules/CLAUDE.md"); B=$(grep -c '^beta SIDE B$' "$WT2/rules/CLAUDE.md")
[ "$A" = 1 ] && [ "$B" = 1 ] && ok \
  || bad "R2: the rebase regenerate must keep each sibling's edit exactly once (a=$A b=$B)"

# ============================================================================
# R3 the CI wiring: the belt is BESIDE the other renders, and it never writes
# ============================================================================
# The step is located by its name. A step that is not there is a FAIL: a grep
# over the whole file would pass on the line living in some other job.
ci_block() { # ci_block <workflow> — the body of the named step, or nothing
  awk -v n="- name: $STEP" '
    index($0, n) { inb = 1; next }
    inb && /^[[:space:]]*- name:/ { exit }
    inb { print }
  ' "$1"
}
BLOCK=$(ci_block "$WF")
if [ -z "$BLOCK" ]; then
  bad "R3: no step named '$STEP' in $WF — the belt has nowhere to be, and every assertion below would pass on an empty block"
else
  ok
  N=$(printf '%s\n' "$BLOCK" | grep -c '^ *bin/render-rules\.sh --check$')
  [ "$N" = 1 ] && ok || bad "R3: the lane-renders step must run 'bin/render-rules.sh --check' exactly once (got $N)"
  N=$(printf '%s\n' "$BLOCK" | grep -c 'render-rules\.sh --write')
  [ "$N" = 0 ] && ok \
    || bad "R3: the step must NOT --write the committed render before checking it — a write erases the drift the step exists to catch (got $N)"
  for c in lanes-build render-cron render-env-example; do
    N=$(printf '%s\n' "$BLOCK" | grep -c "^ *bin/$c\.sh --check.*$")
    [ "$N" -ge 1 ] && ok || bad "R3: the three sibling --check lines must survive; bin/$c.sh --check is gone"
  done
fi
# The negative: the same reader over a workflow with the line taken out must
# report it missing. Without this, an awk that matched nothing would look green.
sed '/^ *bin\/render-rules\.sh --check$/d' "$WF" > "$T/wf-nocheck.yml"
N=$(ci_block "$T/wf-nocheck.yml" | grep -c '^ *bin/render-rules\.sh --check$')
[ "$N" = 0 ] && ok || bad "R3: the mutated fixture still shows the line — the reader is not reading this step"
# …and a workflow with no such step at all must come back EMPTY, never partial.
sed "s/- name: $STEP/- name: something else entirely/" "$WF" > "$T/wf-nostep.yml"
[ -z "$(ci_block "$T/wf-nostep.yml")" ] && ok \
  || bad "R3: a workflow with no lane-renders step must read as an absent step, not as a block"

# ============================================================================
# R4 the drift the new CI line turns red on
# ============================================================================
S="$T/drift"
mkdir -p "$S"
cp -r "$DIR/rules" "$S/rules"
bash "$RR" --root "$S" --check >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "R4: the copied checkout must start clean (rc=$RC)"
printf '\na line the render never saw\n' >> "$S/rules/topics/05-board-voice.md"
bash "$RR" --root "$S" --check > "$T/drift.out" 2>"$T/drift.err"; RC=$?
[ "$RC" = 1 ] && ok || bad "R4: a topic edited without --write must be drift rc 1 (got $RC)"
[ "$(head -1 "$T/drift.out")" = 'DRIFT rules/CLAUDE.md' ] && ok \
  || bad "R4: the drift must name the path first (got '$(head -1 "$T/drift.out")')"
bash "$RR" --root "$S" --write >/dev/null 2>&1
bash "$RR" --root "$S" --check >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "R4: --write must clear the drift (rc=$RC)"
# A renderer that CANNOT run never reports "no drift": rc 2 under --check, so a
# broken topic fails the CI step as loudly as drift does.
printf 'not a heading at all\nbody\n' > "$S/rules/topics/99-refused.md"
bash "$RR" --root "$S" --check > "$T/ref.out" 2>"$T/ref.err"; RC=$?
[ "$RC" = 2 ] && ok || bad "R4: a refused topic under --check must be rc 2, never 0 (got $RC)"
[ -z "$(cat "$T/ref.out")" ] && ok || bad "R4: a refused render must print no DRIFT line"

# ============================================================================
# R5 the banner the shipped file carries
# ============================================================================
C="$DIR/rules/CLAUDE.md"
( cd "$DIR" && bash "$RR" ) > "$T/print" 2>"$T/print.err"; RC=$?
[ "$RC" = 0 ] && ok || bad "R5: the renderer must print this checkout's topics rc 0 (got $RC)"
cmp -s "$T/print" "$C" && ok || bad "R5: rules/CLAUDE.md must BE the render of its topics: $(diff "$C" "$T/print" | head -6 | tr '\n' '|')"
grep '^> ' "$C" > "$T/banner"
grep -q 'bin/render-rules.sh --check' "$T/banner" && ok \
  || bad "R5: the banner must say CI runs bin/render-rules.sh --check"
grep -q 'rendered-file-freshness' "$T/banner" && ok \
  || bad "R5: the banner must say the rendered-file-freshness guardrail rejects a hand edit"
for f in rules/CLAUDE.md rules/topics/00-intro.md docs/verification-map/render-rules.md; do
  N=$(grep -c 'not yet wired' "$DIR/$f" 2>/dev/null)
  [ "$N" = 0 ] && ok || bad "R5: $f still says the CI check is 'not yet wired' ($N times) — item 1 makes that false"
done

done_
