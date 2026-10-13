#!/bin/bash
# tests/pycache-untracked.bh-1138-test.sh — a build never re-commits python bytecode.
#
# THE RECURRENCE (BH-1138). `bin/__pycache__/gate-selfwrite.cpython-312.pyc` is a
# tracked build artifact that keeps coming back. `.gitignore` has listed
# `__pycache__/` since before any of it, but gitignore cannot act on an
# ALREADY-TRACKED path: `git add -A` stages a tracked file whatever the ignore
# rules say. So main re-committed the same byte-compiled artifact at least twice
# (c4c147a8 / #1125 and once before), each time as a stray hunk in a PR about
# something else, each time caught — if at all — by a reviewer reading a diff.
#
# It is not the .pyc that matters. It is that a build can commit a file the repo
# has declared it does not want and nothing mechanical says so. Three assertions,
# in the order they should have existed:
#
#   1. ROOT CAUSE — the bytecode is never written. Every shell script in bin/
#      that runs a harness python module (or puts bin/ on sys.path) exports
#      PYTHONDONTWRITEBYTECODE=1, and tests/lib/scratch.sh exports it once for
#      every test — which is where the committed artifact actually came from:
#      tests/gate-selfwrite-test.sh loads bin/gate-selfwrite.py through
#      importlib.exec_module, writing bin/__pycache__/gate-selfwrite.cpython-3XX.pyc
#      into the CHECKOUT. The scan is mechanical: a new python call site that
#      forgets it is red here, not two PRs later.
#   2. BELT — the builder's whole-tree staging step (bin/lane-checkpoint.sh) and
#      the merge-resolution committer (bin/lander.sh) exclude __pycache__/*.pyc/
#      *.pyo by pathspec, UNCONDITIONALLY — not through CHECKPOINT_EXCLUDE,
#      which an operator can narrow to node_modules and silently lose this.
#      Cases 4-7 drive the real script against a real git repo where the .pyc is
#      already tracked, because that is the case gitignore cannot reach and the
#      only one that reproduced the bug.
#   3. THE TRIPWIRE — nothing matching __pycache__/, *.pyc or *.pyo is tracked
#      in this repo. A third reappearance is a red build.
#
# Run from anywhere: tests/pycache-untracked.bh-1138-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LC="$DIR/bin/lane-checkpoint.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ---------- 1. nothing byte-compiled is tracked ------------------------------
# A git checkout is asked git; a `git archive` export (how the gates run this)
# has no .git, and its contents ARE the tracked set, so the filesystem answers
# the same question there. Neither path may quietly answer "clean" because it
# could not look — an unreadable tree is a failure, not a pass.
MODE=git
tracked_paths() {
  if git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$DIR" ls-files
  else
    MODE=tree
    ( cd "$DIR" && find . -path ./.git -prune -o -type f -print | sed 's#^\./##' )
  fi
}
ALL=$(tracked_paths)
[ -n "$ALL" ] && ok || bad "1: could not list the repo's files at all — this suite proved nothing"

# In tree mode the finding is BROADER than "tracked", and saying so is the
# difference between a fixable message and a confusing one: an export holds only
# tracked files, so a .pyc in it is either committed OR was just written by an
# earlier test in the same run — the second is how the committed one was born,
# and it is a finding either way.
if [ "$MODE" = git ]; then WHY="is tracked in this repo (git rm -r --cached it)"
else WHY="is in this tree — either committed, or written during this run by something without PYTHONDONTWRITEBYTECODE=1"; fi
BYTECODE=$(printf '%s\n' "$ALL" | grep -E '(^|/)__pycache__/|\.py[co]$' || true)
[ -z "$BYTECODE" ] && ok \
  || bad "1: python bytecode $WHY: $(printf '%s' "$BYTECODE" | tr '\n' ' ')"

# ---------- 2. .gitignore still declares all three ---------------------------
# The ignore rules are what keep an UNtracked artifact out; they are necessary
# and, on their own, provably not sufficient (case 1 is what happens when they
# are all that is there). *.pyo is listed too: it is the same artifact under
# python's optimised-bytecode name.
GI="$DIR/.gitignore"
for pat in '__pycache__/' '*.pyc' '*.pyo'; do
  grep -qxF "$pat" "$GI" 2>/dev/null && ok || bad "2: .gitignore does not carry '$pat'"
done

# ---------- 3. every python call site refuses to write bytecode --------------
# THE RULE, stated once so a reviewer and this test read the same sentence: a
# shell script under bin/ that runs a .py file or inserts a path into
# sys.path can cause __pycache__ to be written next to that module, so it must
# export PYTHONDONTWRITEBYTECODE=1. Files are found by that property, never
# from a hand-kept list — a list is what stops covering the next call site.
carries_export() { grep -qE '^[[:space:]]*export PYTHONDONTWRITEBYTECODE=1' "$1"; }
PY_CALLERS=$( ( cd "$DIR" && find bin tests -type f -name '*.sh' -print ) | sort | while IFS= read -r f; do
  grep -qE 'sys\.path\.insert|spec_from_file_location|python3[^|;&]*[A-Za-z0-9_/$-]+\.py\b' "$DIR/$f" && echo "$f"
done )
[ -n "$PY_CALLERS" ] && ok || bad "3: the scan found no python call sites at all — the rule is scanning nothing"
# tests/lib/scratch.sh is the choke point every test sources before it runs
# anything, so a test is covered by it; a bin/ script has no such prelude and
# carries the export itself.
SCRATCH_LIB="$DIR/tests/lib/scratch.sh"
carries_export "$SCRATCH_LIB" && ok \
  || bad "3: tests/lib/scratch.sh does not export PYTHONDONTWRITEBYTECODE=1 — no test is covered"
MISSING=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  carries_export "$DIR/$f" && continue
  case "$f" in
    tests/*) grep -q 'lib/scratch.sh' "$DIR/$f" && continue ;;
  esac
  MISSING="$MISSING $f"
done <<< "$PY_CALLERS"
[ -z "$MISSING" ] && ok \
  || bad "3: these scripts run python with no PYTHONDONTWRITEBYTECODE=1 in scope:$MISSING"

# ---------- the staging fixtures ---------------------------------------------
# A REAL repo and a REAL bare origin, exactly as tests/lane-checkpoint-test.sh
# does: the thing under test is git's staging behaviour, and a stubbed git would
# have graded the control flow rather than the file that reached the commit.
export HOME="$T/home"; mkdir -p "$HOME"
git config --global user.email harness@localhost >/dev/null 2>&1
git config --global user.name  harness           >/dev/null 2>&1
git config --global init.defaultBranch main      >/dev/null 2>&1
git config --global protocol.file.allow always   >/dev/null 2>&1

N=0
fresh() { # fresh — WT/ORIGIN/BUILD set; base commit already TRACKS a .pyc
  N=$((N+1))
  ORIGIN="$T/origin$N.git"; WT="$T/wt$N"; BUILD="$T/build$N"
  git init --bare -q "$ORIGIN"
  git init -q "$WT"
  mkdir -p "$BUILD"
  printf '{"project":"cromford","ticket_id":"1138","key":"BH-1138"}\n' > "$BUILD/job.json"
  ( cd "$WT"
    echo base > base.txt
    # The reproduction, precisely: the artifact is ALREADY TRACKED and the
    # ignore rule is already there. gitignore cannot reach a tracked path, so
    # only the pathspec can — a fixture that left it untracked would grade
    # gitignore and report a pass the exclusion never earned.
    printf '__pycache__/\n*.pyc\n*.pyo\n' > .gitignore
    mkdir -p bin/__pycache__
    printf 'stale-bytecode\n' > bin/__pycache__/gate.cpython-312.pyc
    git add -A -f >/dev/null 2>&1
    git commit -qm "base (with the tracked .pyc this ticket is about)" >/dev/null 2>&1
    git remote add origin "$ORIGIN"
    git push -q -u origin main >/dev/null 2>&1
    git checkout -qb ticket/bh-1138 >/dev/null 2>&1 )
}
CK() { CHECKPOINTS=1 HARNESS="$T/h" "${1:-$LC}" "$BUILD" "$WT" ticket/bh-1138 execute >/dev/null 2>&1; }
# What the checkpoint commit actually carries. HEAD only — the base commit's
# tracked .pyc is not this script's to remove.
staged() { git -C "$WT" show --name-only --format= HEAD 2>/dev/null; }
mkdir -p "$T/h/logs" "$T/h/flags"

# ---------- 4. a MODIFIED tracked .pyc is not re-committed -------------------
# The exact recurrence: the gate reruns, rewrites the tracked artifact, and the
# next `git add -A` carries the new bytes into a commit about something else.
fresh
( cd "$WT"
  echo work > feature.txt
  printf 'rebuilt-bytecode\n' > bin/__pycache__/gate.cpython-312.pyc )
CK
grep -qx 'feature.txt' <<<"$(staged)" && ok || bad "4: the real work was not checkpointed at all: $(staged)"
grep -q '__pycache__' <<<"$(staged)" && bad "4: the checkpoint re-committed the tracked .pyc: $(staged)" || ok

# ---------- 5. a NEW .pyc in a repo whose .gitignore forgot it ---------------
# The belt without the brace: a project repo that never ignored __pycache__ at
# all. Here gitignore contributes nothing and only the pathspec can hold.
fresh
( cd "$WT"
  : > .gitignore
  echo work > feature.txt
  mkdir -p tools/__pycache__
  printf 'fresh\n' > tools/__pycache__/helper.cpython-312.pyc
  printf 'fresh\n' > tools/helper.pyo )
CK
grep -qx 'feature.txt' <<<"$(staged)" && ok || bad "5: the real work was not checkpointed at all: $(staged)"
grep -qE '__pycache__|\.py[co]$' <<<"$(staged)" && bad "5: an unignored .pyc/.pyo was checkpointed: $(staged)" || ok

# ---------- 6. CHECKPOINT_EXCLUDE cannot switch the exclusion off ------------
# The knob is an operator's list of extra directories. If the bytecode
# exclusion rode inside its default value, `CHECKPOINT_EXCLUDE=node_modules`
# would silently restore the bug — and that is a config line, not a code
# review, so nothing would ever see it.
fresh
( cd "$WT"
  echo work > feature.txt
  printf 'rebuilt\n' > bin/__pycache__/gate.cpython-312.pyc )
CHECKPOINT_EXCLUDE=node_modules CHECKPOINTS=1 HARNESS="$T/h" "$LC" "$BUILD" "$WT" ticket/bh-1138 execute >/dev/null 2>&1
grep -q '__pycache__' <<<"$(staged)" && bad "6: a narrowed CHECKPOINT_EXCLUDE re-enabled the .pyc commit: $(staged)" || ok

# ---------- 7. mutation: the pathspec is load-bearing ------------------------
# Delete the marked line from a copy and the .pyc lands again. Without this the
# four assertions above would still pass if git happened to ignore the file for
# some other reason, and would be proving nothing.
MUT="$T/lane-checkpoint-mutated.sh"
cp "$LC" "$MUT"; chmod +x "$MUT"
sed -i'' -e '/BH-1138-PYCACHE-EXCLUDE/d' "$MUT" 2>/dev/null || sed -i '' -e '/BH-1138-PYCACHE-EXCLUDE/d' "$MUT"
[ "$(grep -c 'BH-1138-PYCACHE-EXCLUDE' "$MUT")" = 0 ] && ok || bad "7: the mutation did not remove the marked line — nothing was mutated"
fresh
( cd "$WT"
  echo work > feature.txt
  printf 'rebuilt\n' > bin/__pycache__/gate.cpython-312.pyc )
CK "$MUT"
grep -q '__pycache__' <<<"$(staged)" && ok || bad "7: removing the exclusion changed nothing — the pathspec is not what holds the line"

# ---------- 8. the lander's whole-tree add carries the same exclusion --------
# bin/lander.sh commits a merge resolution with `git add -A` in a project
# worktree. Same blunt instrument, same artifact, same outcome — asserted on the
# source because the lander's own suite drives the surrounding lane.
LD="$DIR/bin/lander.sh"
ADDLINE=$(grep -n 'git add -A' "$LD" | grep -v '^[0-9]*:#' | head -1)
[ -n "$ADDLINE" ] && ok || bad "8: bin/lander.sh no longer has a whole-tree add — re-point this assertion"
grep -qF ":(exclude)*/__pycache__/*" "$LD" \
  && ok || bad "8: bin/lander.sh stages the whole tree without excluding __pycache__ ($ADDLINE)"
grep -qF ":(exclude)*.pyc" "$LD" \
  && ok || bad "8: bin/lander.sh stages the whole tree without excluding *.pyc ($ADDLINE)"

echo "pycache-untracked: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
