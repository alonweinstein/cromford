#!/bin/bash
# tests/patch-same.bh-2310-test.sh — bin/lib/patch-same.sh against REAL git
# histories (BH-2310): when does a moved PR head carry exactly the reviewed patch?
#
#   S1  the same sha                                        -> identical
#   S2  a clean main merge, main edited a line NEXT TO a PR hunk
#       (the whole-diff patch-id differs: the #2131 shape)  -> main-merge
#   S3  a clean main merge far from the PR's lines          -> main-merge
#   S4  a pure rebase onto a newer main                     -> patch-id
#   S5  a rebase with context drift (patch-id differs)      -> rc 1 (no range-diff rung)
#   W1-W4, M1, L1 (the #2386 review): whitespace in Python, YAML, a shell path and a
#       string; a 644 -> 755 mode change; a file -> symlink swap; each in place and
#       after a rebase                                      -> rc 1
#   N1  a new commit on top of the reviewed head            -> rc 1
#   N2  a main merge with a HAND-RESOLVED conflict          -> rc 1
#   N3  a clean-looking merge amended with an extra edit    -> rc 1
#   N4  a merge of a NON-main branch                        -> rc 1
#   N5  a rebase that also changed a line                   -> rc 1
#   N6  a git that answers nothing useful (stubbed)         -> rc 1
#   N7  an octopus merge of main and another branch         -> rc 1
# Run from anywhere: tests/patch-same.bh-2310-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
. "$DIR/bin/lib/patch-same.sh" || { echo "FAIL: cannot source bin/lib/patch-same.sh"; exit 1; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
G="$T/repo"
g() { git -C "$G" "$@"; }

# A file of 30 numbered lines, so hunks and their context are easy to place.
seed() {
  scratch_rm "$G" 2>/dev/null; mkdir -p "$G"
  g init -q -b main
  seq 1 30 | sed 's/^/line /' > "$G/f.txt"
  printf 'other\n' > "$G/o.txt"
  g add -A; g commit -qm base
}
edit() { # edit <line-no> <text>  — replace one line of f.txt
  sed -i.bak "${1}s/.*/$2/" "$G/f.txt" && rm -f "$G/f.txt.bak"
}
commit() { g add -A; g commit -qm "$1"; g rev-parse HEAD; }
same() { patch_same "$G" main "$1" "$2"; }

# ---- the PR: one commit changing line 10, reviewed at R
pr_branch() {
  seed
  g checkout -qb pr
  edit 10 'line 10 CHANGED BY PR'; R=$(commit pr-change)
}

# S1
pr_branch
out=$(same "$R" "$R"); rc=$?
[ "$rc" = 0 ] && [ "$out" = identical ] && ok || bad "S1 same sha: rc=$rc out='$out'"

# S2: main edits line 13 (inside the PR hunk's 3-line context, not adjacent: adjacent is a conflict), the PR merges main.
pr_branch
g checkout -q main; edit 13 'line 13 EDITED ON MAIN'; commit main-adjacent >/dev/null
g checkout -q pr; g merge -q --no-edit main; H=$(g rev-parse HEAD)
pid_r=$(_ps_patch_id "$G" "$(g rev-parse main)" "$R"); pid_h=$(_ps_patch_id "$G" "$(g rev-parse main)" "$H")
[ -n "$pid_r" ] && [ -n "$pid_h" ] && [ "$pid_r" != "$pid_h" ] && ok \
  || bad "S2 precondition: the whole-diff patch-id must DIFFER across this main merge (the #2131 shape): '$pid_r' '$pid_h'"
out=$(same "$R" "$H"); rc=$?
[ "$rc" = 0 ] && [ "$out" = main-merge ] && ok || bad "S2 clean main merge next to the PR hunk: rc=$rc out='$out', want main-merge"

# S3: main edits a far line; two main merges in a row.
pr_branch
g checkout -q main; edit 25 'line 25 far away'; commit m1 >/dev/null
g checkout -q pr; g merge -q --no-edit main
g checkout -q main; printf 'new file\n' > "$G/n.txt"; commit m2 >/dev/null
g checkout -q pr; g merge -q --no-edit main; H=$(g rev-parse HEAD)
out=$(same "$R" "$H"); rc=$?
[ "$rc" = 0 ] && [ "$out" = main-merge ] && ok || bad "S3 two clean main merges: rc=$rc out='$out'"

# S4: pure rebase onto a newer main that touched another file.
pr_branch
g checkout -q main; printf 'x\n' >> "$G/o.txt"; commit m >/dev/null
g checkout -q pr; g rebase -q main; H=$(g rev-parse HEAD)
out=$(same "$R" "$H"); rc=$?
[ "$rc" = 0 ] && [ "$out" = patch-id ] && ok || bad "S4 pure rebase: rc=$rc out='$out', want patch-id"

# S5: a rebase where main edited the adjacent line: context drift.
pr_branch
g checkout -q main; edit 13 'line 13 EDITED ON MAIN'; commit m >/dev/null
g checkout -q pr; g rebase -q main; H=$(g rev-parse HEAD)
out=$(same "$R" "$H"); rc=$?
[ "$rc" = 1 ] && ok || bad "S5 a context-drift rebase is refused (there is no range-diff rung), got '$out' (rc=$rc)"

# N1: a new commit after the review.
pr_branch
edit 20 'line 20 FIX ROUND'; H=$(commit fix)
same "$R" "$H" >/dev/null && bad "N1 a new commit must not read as the same patch" || ok
# ...and a new commit hidden behind a later main merge.
g checkout -q main; edit 28 'line 28 main'; commit m >/dev/null
g checkout -q pr; g merge -q --no-edit main; H=$(g rev-parse HEAD)
same "$R" "$H" >/dev/null && bad "N1b a new commit before a main merge must not read as the same patch" || ok

# N2: a main merge whose conflict was resolved by hand.
pr_branch
g checkout -q main; edit 10 'line 10 MAIN SIDE'; commit m >/dev/null
g checkout -q pr
g merge -q --no-edit main >/dev/null 2>&1
edit 10 'line 10 HAND RESOLVED'; g add -A; g commit -qm 'Merge main (resolved)'; H=$(g rev-parse HEAD)
same "$R" "$H" >/dev/null && bad "N2 a hand-resolved conflict must not read as the same patch" || ok

# N3: a clean merge amended with an extra edit.
pr_branch
g checkout -q main; edit 25 'line 25 far'; commit m >/dev/null
g checkout -q pr; g merge -q --no-edit main
edit 5 'line 5 SNUCK INTO THE MERGE'; g add -A; g commit -q --amend --no-edit; H=$(g rev-parse HEAD)
same "$R" "$H" >/dev/null && bad "N3 an edit amended into a merge commit must not read as the same patch" || ok

# N4: a merge of another (non-main) branch.
pr_branch
g checkout -q -b side main; printf 'side\n' > "$G/side.txt"; commit side >/dev/null
g checkout -q pr; g merge -q --no-edit side; H=$(g rev-parse HEAD)
same "$R" "$H" >/dev/null && bad "N4 a merged non-main branch must not read as the same patch" || ok

# N5: a rebase that also changed the PR's own line.
pr_branch
g checkout -q main; printf 'x\n' >> "$G/o.txt"; commit m >/dev/null
g checkout -q pr; g rebase -q main; edit 10 'line 10 CHANGED AGAIN'; g add -A; g commit -q --amend --no-edit; H=$(g rev-parse HEAD)
same "$R" "$H" >/dev/null && bad "N5 a rebase with a content change must not read as the same patch" || ok

# N6: a stubbed git that answers every command with rc 0 and no output.
pr_branch
g checkout -q main; edit 25 'x'; commit m >/dev/null; g checkout -q pr; g merge -q --no-edit main; H=$(g rev-parse HEAD)
mkdir -p "$T/stub"; printf '#!/bin/bash\nexit 0\n' > "$T/stub/git"; chmod +x "$T/stub/git"
out=$(PATH="$T/stub:$PATH" patch_same "$G" main "$R" "$H"); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "N6 a stubbed git must never read as the same patch: rc=$rc out='$out'"
# ...and one whose patch-id is an md5 of the diff (the conductor tests' stub).
printf '#!/bin/bash\ncase "$*" in *patch-id*) md5sum | cut -d" " -f1 ;; *) exit 0 ;; esac\n' > "$T/stub/git"
out=$(PATH="$T/stub:$PATH" patch_same "$G" main "$R" "$H"); rc=$?
[ "$rc" = 1 ] && ok || bad "N6b an md5 patch-id stub must not read as the same patch: rc=$rc out='$out'"

# N7: an octopus merge of main and a side branch.
pr_branch
g checkout -q main; edit 25 'm'; commit m >/dev/null
g checkout -q -b side2 main; printf 's\n' > "$G/s2.txt"; commit s >/dev/null
g checkout -q pr; g merge -q --no-edit main side2 >/dev/null 2>&1; H=$(g rev-parse HEAD)
same "$R" "$H" >/dev/null && bad "N7 an octopus merge must not read as the same patch" || ok

# ---- W/M/L: the #2386 review's probes. A PR head whose code CHANGED must never
# read as the same patch: not through whitespace (`patch-id --stable` strips it,
# and indentation is semantics in Python and YAML), not through a file's mode or
# type (range-diff pairs those as `=`). Each is tried in place (the branch
# rewritten on the same base) and after a rebase onto a moved main.
changed_case() { # changed_case <label> <rebase|same> <setup-R-cmd> <setup-H-cmd>
  seed
  # ONE commit message for both heads: range-diff compares messages too, and a
  # probe that differs there would be refused for the wrong reason.
  g checkout -qb pr; eval "$3"; R=$(commit pr-change)
  if [ "$2" = rebase ]; then g checkout -q main; printf 'x\n' >> "$G/o.txt"; commit m >/dev/null; fi
  g checkout -q -b pr2 main; eval "$4"; H=$(commit pr-change)
  out=$(same "$R" "$H"); rc=$?
  [ "$rc" = 1 ] && ok || bad "$1 ($2): a head whose code changed read as the same patch ($out)"
}
PY_R='printf "def f(x):\n    if x:\n        os.remove(x)\n    return 1\n" > "$G/a.py"'
PY_H='printf "def f(x):\n    if x:\n        pass\n    os.remove(x)\n    return 1\n" > "$G/a.py"'
PY_H2='printf "def f(x):\n    if x:\n    os.remove(x)\n    return 1\n" > "$G/a.py"'
YM_R='printf "jobs:\n  a:\n    if: false\n    run: x\n" > "$G/c.yml"'
YM_H='printf "jobs:\n  a:\n  if: false\n    run: x\n" > "$G/c.yml"'
SH_R='printf "rm -rf \$D/cache\n" > "$G/c.sh"'
SH_H='printf "rm -rf \$D/ cache\n" > "$G/c.sh"'
ST_R='printf "X=\"a b\"\n" > "$G/s.sh"'
ST_H='printf "X=\"ab\"\n" > "$G/s.sh"'
MO_R='printf "echo hi\n" > "$G/m.sh"; chmod 644 "$G/m.sh"'
MO_H='printf "echo hi\n" > "$G/m.sh"; chmod 755 "$G/m.sh"'
LN_R='printf "/etc/passwd" > "$G/p"'
LN_H='ln -s /etc/passwd "$G/p"'
for how in same rebase; do
  changed_case "W1 python indentation (statement leaves its block)" "$how" "$PY_R" "$PY_H2"
  changed_case "W1b python indentation (pass added, statement dedented)" "$how" "$PY_R" "$PY_H"
  changed_case "W2 yaml indentation (key changes scope)" "$how" "$YM_R" "$YM_H"
  changed_case "W3 shell path split by a space" "$how" "$SH_R" "$SH_H"
  changed_case "W4 string literal loses its space" "$how" "$ST_R" "$ST_H"
  changed_case "M1 file mode 644 -> 755" "$how" "$MO_R" "$MO_H"
  changed_case "L1 regular file -> symlink, same bytes" "$how" "$LN_R" "$LN_H"
done

echo "patch-same.bh-2310: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
