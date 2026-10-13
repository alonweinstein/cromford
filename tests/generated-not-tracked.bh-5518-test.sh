#!/bin/bash
# tests/generated-not-tracked.bh-5518-test.sh — BH-5518 C2: a file the repo
# declares it does not want is never tracked.
#
# THE DEFECT. On main 5ff45352 two such files were tracked. The routes table
# render under worker/jobs/src/ says on line 2 that it is git-ignored and must
# not be committed, and a merge brought it in anyway. locks-worker's wrangler
# cache sits under the `.wrangler/` ignore rule and was tracked all the same:
# gitignore cannot act on a path that is already tracked, so nothing said so.
# Two cases make it mechanical, so the next leak is red here, not in a merge
# train:
#
#   G1  no tracked path is matched by an ignore rule
#       (`git ls-files -ci --exclude-per-directory=.gitignore` is empty: the
#       repo's own .gitignore files, never a box-local exclude)
#   G2  no tracked file other than *.md carries, in its first 5 lines, both a
#       GENERATED line and a "do not commit" line
#
#   G3  mutation: a force-added ignored file makes the suite rc 1 and names it
#   G4  mutation: a tracked file with that header makes it rc 1 and names it
#   G5  four realistic negatives keep it rc 0 (a markdown heading, a "secrets"
#       comment, a committed render's header, the phrase past line 5)
#   G6  this checkout passes G1 and G2
#   G7  bin/test-impact.sh always lists this suite, so it runs on every PR
#   G8  a box-local exclude (.git/info/exclude, core.excludesFile) never counts
#
# GNT_ROOT=<dir> runs only G1 and G2 against <dir>; G3-G5 drive the suite that
# way. A <dir> with no .git (a `git archive` export) is indexed into a
# throwaway repo, so its contents are the tracked set. An unreadable tree is a
# FAIL, never a pass.
#
# Run from anywhere: tests/generated-not-tracked.bh-5518-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SELF="$DIR/tests/generated-not-tracked.bh-5518-test.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

# scan <dir> — G1 and G2 against one tree. Prints one line per finding.
# rc 0 clean, 1 findings, 2 the tree could not be read.
scan() {
  local root="$1" g=() list rc=0 ign hdr
  [ -d "$root" ] || { echo "cannot read $root: not a directory"; return 2; }
  if ! git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # Archive mode: index the tree as it stands, ignored files included.
    git init -q --bare "$T/archive.git" >/dev/null 2>&1 \
      && git --git-dir="$T/archive.git" --work-tree="$root" add -A -f >/dev/null 2>&1 \
      || { echo "cannot index $root"; return 2; }
    g=(--git-dir="$T/archive.git" --work-tree="$root")
  else
    g=(-C "$root")
  fi
  list=$(git "${g[@]}" ls-files) || { echo "cannot list the files of $root"; return 2; }
  [ -n "$list" ] || { echo "no tracked files in $root"; return 2; }

  # The repo's OWN rules only (lead review lr-5735-86ad2af7): every .gitignore
  # in the tree, never .git/info/exclude or core.excludesFile, which belong to
  # one box and would make a clean tree red there.
  ign=$(cd "$root" && git -c core.excludesFile=/dev/null "${g[@]}" ls-files -ci --exclude-per-directory=.gitignore) \
    || { echo "cannot ask git which tracked files $root ignores"; return 2; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    echo "G1: $f is tracked and git-ignored (git rm --cached it)"; rc=1
  done <<< "$ign"

  hdr=$(cd "$root" && printf '%s\n' "$list" | while IFS= read -r f; do
          case "$f" in *.md) continue ;; esac
          [ -f "$f" ] && printf '%s\0' "$f"
        done | xargs -0 -r awk '
          FNR == 1 { g = 0; d = 0; r = 0 }
          FNR > 5  { nextfile }
          /GENERATED/          { if (!g) g = FNR }
          /[Dd]o not commit/   { if (!d) d = FNR }
          g && d && !r { print FILENAME " (GENERATED line " g ", do-not-commit line " d ")"; r = 1 }') \
    || { echo "cannot read the headers of the files in $root"; return 2; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    echo "G2: $f says it is generated and must not be committed (git rm --cached it)"; rc=1
  done <<< "$hdr"
  return "$rc"
}

if [ -n "${GNT_ROOT:-}" ]; then
  echo "generated-not-tracked: scanning $GNT_ROOT"
  scan "$GNT_ROOT"; rc=$?
  [ "$rc" = 0 ] && ok "G1+G2: $GNT_ROOT tracks no ignored or do-not-commit file" \
    || bad "G1+G2: $GNT_ROOT (rc $rc, see the lines above)"
  echo "generated-not-tracked: $PASS passed, $FAIL failed"
  [ "$FAIL" = 0 ]; exit
fi

# fixture <name> — a scratch repo at $S with a `*.log` ignore rule.
fixture() {
  S="$T/$1"; mkdir -p "$S"
  git init -q "$S" >/dev/null 2>&1
  printf '*.log\n' > "$S/.gitignore"
  echo keep > "$S/keep.txt"
}
# run_suite <root> — the suite as a child, the way CI would see it.
run_suite() { GNT_ROOT="$1" bash "$SELF" > "$T/out" 2>&1; RC=$?; }

echo "G3: a force-added ignored file is red and named"
fixture g3
echo x > "$S/a.log"
git -C "$S" add -A >/dev/null 2>&1 && git -C "$S" add -f a.log >/dev/null 2>&1
run_suite "$S"
[ "$RC" = 1 ] && ok "G3: rc 1" || bad "G3: rc $RC, want 1: $(cat "$T/out")"
grep -q 'G1: a.log is tracked and git-ignored' "$T/out" && ok "G3: names a.log" \
  || bad "G3: a.log not named: $(cat "$T/out")"

echo "G3b: the same tree with no .git (archive mode) is red and named"
mkdir -p "$T/g3b"; cp "$S/.gitignore" "$S/keep.txt" "$S/a.log" "$T/g3b/"
run_suite "$T/g3b"
[ "$RC" = 1 ] && grep -q 'G1: a.log' "$T/out" && ok "G3b: rc 1, names a.log" \
  || bad "G3b: rc $RC: $(cat "$T/out")"

echo "G3c: an unreadable tree is a FAIL, not a pass"
run_suite "$T/no-such-dir"
[ "$RC" = 1 ] && grep -q 'cannot read' "$T/out" && ok "G3c: rc 1, says why" \
  || bad "G3c: rc $RC: $(cat "$T/out")"

echo "G4: a tracked file with a GENERATED do-not-commit header is red and named"
fixture g4
printf '%s\n' '// GENERATED by y. Do not commit.' 'export const a = 1;' > "$S/x.js"
git -C "$S" add -A >/dev/null 2>&1
run_suite "$S"
[ "$RC" = 1 ] && ok "G4: rc 1" || bad "G4: rc $RC, want 1: $(cat "$T/out")"
grep -q 'G2: x.js (GENERATED line 1, do-not-commit line 1)' "$T/out" && ok "G4: names x.js" \
  || bad "G4: x.js not named: $(cat "$T/out")"

echo "G5: realistic negatives stay green"
fixture g5
printf '%s\n' '# GENERATED files' '' 'builders do not commit declared generated files' > "$S/p.md"
printf '%s\n' '#!/bin/bash' '# Do not commit secrets here' 'echo hi' > "$S/s.sh"
printf '%s\n' '<!-- GENERATED by render; edit topics -->' 'body' > "$S/r.md"
printf '%s\n' '<!-- GENERATED by render; edit topics -->' 'body' > "$S/r.html"
{ echo '// GENERATED'; for i in 2 3 4 5 6 7 8; do echo "// line $i"; done
  echo '// do not commit'; } > "$S/z.js"
git -C "$S" add -A >/dev/null 2>&1
[ "$(git -C "$S" ls-files | wc -l)" -eq 7 ] && ok "G5: all seven fixtures are tracked" \
  || bad "G5: fixture not tracked: $(git -C "$S" ls-files | tr '\n' ' ')"
run_suite "$S"
[ "$RC" = 0 ] && ok "G5: rc 0" || bad "G5: a negative was flagged: $(cat "$T/out")"

echo "G8: only the repo's own .gitignore rules count, never a box-local exclude"
# Lead review lr-5735-86ad2af7: a box whose .git/info/exclude (or global
# core.excludesFile) names a tracked file made G6 red on a clean tree, a false
# main-red on every box-side run there. Those rules are the box's, not the repo's.
fixture g8
echo a > "$S/a.txt"
git -C "$S" add -A >/dev/null 2>&1
mkdir -p "$S/.git/info"; printf 'a.txt\n' >> "$S/.git/info/exclude"
printf 'keep.txt\n' > "$T/g8-global-excludes"
printf '[core]\n\texcludesFile = %s\n' "$T/g8-global-excludes" > "$T/g8-gitconfig"
GIT_CONFIG_GLOBAL="$T/g8-gitconfig" GNT_ROOT="$S" bash "$SELF" > "$T/out" 2>&1; RC=$?
[ "$RC" = 0 ] && ok "G8: rc 0 with box-local excludes naming tracked files" \
  || bad "G8: a box-local exclude made the suite red (rc $RC): $(cat "$T/out")"
echo x > "$S/b.log"; git -C "$S" add -f b.log >/dev/null 2>&1
GIT_CONFIG_GLOBAL="$T/g8-gitconfig" GNT_ROOT="$S" bash "$SELF" > "$T/out" 2>&1; RC=$?
[ "$RC" = 1 ] && grep -q 'G1: b.log is tracked and git-ignored' "$T/out" && ok "G8: the repo's own *.log rule still catches b.log" \
  || bad "G8: the repo's own rule was lost (rc $RC): $(cat "$T/out")"

echo "G6: this checkout is clean"
if out=$(scan "$DIR"); then ok "G6: no tracked ignored or do-not-commit file"
else bad "G6: $(printf '%s' "$out" | tr '\n' ';')"; fi

echo "G7: the always-run set lists this suite"
if always=$("$DIR/bin/test-impact.sh" --root "$DIR" always 2>"$T/always.err"); then
  grep -qxF 'tests/generated-not-tracked.bh-5518-test.sh' <<< "$always" \
    && ok "G7: listed" || bad "G7: not in bin/test-impact.sh always"
else
  bad "G7: bin/test-impact.sh always failed: $(cat "$T/always.err")"
fi

echo "generated-not-tracked: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
