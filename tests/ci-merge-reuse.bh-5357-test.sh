#!/bin/bash
# tests/ci-merge-reuse.bh-5357-test.sh — BH-5357 (Part E): a PR push whose new
# commits only merge the base branch reuses the previous head's green run for
# the lint job's tree checks its change cannot reach, and a push with anything
# else in it runs every step as before.
#
# Real git fixture repos, bin/lib/merge-push.sh sourced directly for the
# classifier, and the production entry point bin/ci-merge-reuse.sh run from a
# scratch install of its closure (scratch_install_closure) with GITHUB_OUTPUT
# set and a stub gh that prints canned run JSON and records its argv.
#
#   C1-C9  mp_classify: clean; resolved (conflict path); an evil merge's hand
#          edit is resolved, never clean; octopus, sibling-branch merge,
#          non-merge, all-zero before, before not an ancestor, unknown sha are
#          all full. F1: mp_main_files / mp_pr_files.
#   A1     clean merge, main touches cron/x, the PR docs/verification-map:
#          mode=reuse and vmap/renders/render-diff skipped, one reused line each.
#   A1b    main also touches a vmap entry: vmap runs (intersection).
#   A2     a hand-resolved conflict in catalog/lanes.d/x.json: renders run.
#   A2b    a clean merge carrying a hand edit to cron/y: renders run.
#   A3     a real commit after the merge: mode=full, every run_*=1.
#   N1-N14 the adversarial negatives: each mode=full, every run_*=1.
#   K1-K5  the knob: off, garbled, 0 are full; unset reads the registry default.
#   E1-E2  bad args and an unreadable catalog: rc 2, mode=full.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/ci-merge-reuse.bh-5357-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
ENTRY="$DIR/bin/ci-merge-reuse.sh"
LIB="$DIR/bin/lib/merge-push.sh"
CAT="$DIR/catalog/ci-merge-reuse.tsv"
KREG="$DIR/catalog/lanes.d/_lib.ci-merge-reuse.json"
for f in "$ENTRY" "$LIB" "$CAT" "$KREG"; do
  [ -f "$f" ] || { echo "FAIL: ${f#"$DIR"/} does not exist"; exit 1; }
done
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset PR_CI_MERGE_REUSE GITHUB_OUTPUT GITHUB_STEP_SUMMARY

# ─────────────────────────── the fixture repo ────────────────────────────────
WK="$T/repo"; git init -q -b main "$WK"
g() { git -C "$WK" "$@"; }
w() { mkdir -p "$WK/$(dirname "$1")"; printf '%s\n' "$2" > "$WK/$1"; }
sha() { g rev-parse HEAD; }
w cron/x c0; w cron/y y0; w src/code.txt code0
w docs/verification-map/entries/a.md a0; w docs/verification-map/entries/b.md b0
w catalog/lanes.d/x.json "$(printf 'l1\nl2\nl3')"
g add -A; g commit -qm base; B0=$(sha)

g checkout -qb pr "$B0"; w docs/verification-map/entries/a.md a1; g commit -qam "the pr"; P1=$(sha)
g checkout -qb m1 "$B0"; w cron/x c1; g commit -qam "main: cron"; M1=$(sha)
g checkout -qb m1b "$B0"; w cron/x c1; w docs/verification-map/entries/b.md b1; g commit -qam "main: cron + vmap"; M1b=$(sha)
g checkout -qb sib "$B0"; w src/s.txt s1; g add -A; g commit -qm "a sibling"; SIB=$(sha)
g checkout -qb m3 "$B0"; w .github/workflows/x.yml 'on: push'; g add -A; g commit -qm "main: ci"; M3=$(sha)
g checkout -qb m4 "$B0"; w src/main.txt m4; g add -A; g commit -qm "main: src only"; M4=$(sha)

# A1: P1 + a clean merge of m1
g checkout -qb a1 "$P1"; g merge -q --no-edit m1; HA1=$(sha)
# A1b: P1 + a clean merge of m1b
g checkout -qb a1b "$P1"; g merge -q --no-edit m1b; HA1b=$(sha)
# A2: a conflict on catalog/lanes.d/x.json, resolved by hand
g checkout -qb p2 "$B0"; w catalog/lanes.d/x.json "$(printf 'l1\npr\nl3')"; g commit -qam "pr: lane"; P2=$(sha)
g checkout -qb m2 "$B0"; w catalog/lanes.d/x.json "$(printf 'l1\nmain\nl3')"; g commit -qam "main: lane"; M2=$(sha)
g checkout -q p2; g merge -q --no-edit m2 >/dev/null 2>&1
w catalog/lanes.d/x.json "$(printf 'l1\npr+main\nl3')"; g add -A; g commit -q --no-edit; HA2=$(sha)
# A2b: a merge of m4 (which reaches no render) that conflicts nowhere but
# carries a hand edit to cron/y, so only the resolution rule can run renders
g checkout -qb a2b "$P1"; g merge -q --no-commit --no-ff m4 >/dev/null 2>&1
w cron/y y-evil; g add -A; g commit -q --no-edit; HA2b=$(sha)
# A3 / N1: a real commit after the merge
g checkout -qb a3 "$HA1"; w src/code.txt code1; g commit -qam "real work"; HA3=$(sha)
# N2: a real commit before the merge, in the same push
g checkout -qb n2 "$P1"; w src/code.txt code2; g commit -qam "real work first"; g merge -q --no-edit m1; HN2=$(sha)
# N3: a merge of a sibling feature branch
g checkout -qb n3 "$P1"; g merge -q --no-edit sib; HN3=$(sha)
# N4: an octopus merge of main and the sibling
g checkout -qb n4 "$P1"; g merge -q --no-edit m1 sib >/dev/null 2>&1; HN4=$(sha)
# N5: a rebase onto m1 (identical patch, before not an ancestor)
g checkout -qb n5 "$M1"; g cherry-pick "$P1" >/dev/null; HN5=$(sha); [ "$HN5" != "$M1" ] || { echo "FAIL: the N5 rebase fixture did not commit"; exit 1; }
# N11: the PR edits the decider's own catalog
g checkout -qb p11 "$B0"; w catalog/ci-merge-reuse.tsv 'x'; g add -A; g commit -qm "pr: catalog"; P11=$(sha)
g merge -q --no-edit m1; HN11=$(sha)
# N12: main's incoming change edits a workflow
g checkout -qb n12 "$P1"; g merge -q --no-edit m3; HN12=$(sha)
g checkout -q main
for b in m1 m1b m2 m3 m4; do g update-ref "refs/remotes/origin/$b" "$b"; done
Z=0000000000000000000000000000000000000000

# ─────────────────────── part 1: the classifier (lib) ────────────────────────
# shellcheck source=/dev/null
. "$DIR/bin/lib/merge-push.sh" || { echo "FAIL: bin/lib/merge-push.sh does not source"; exit 1; }
cls() { mp_classify "$WK" "$1" "$2" "$3"; }
chk_cls() { # <id> <want-prefix> <got>
  case "$3" in "$2"*) ok ;; *) bad "$1: mp_classify said '$3', want '$2…'" ;; esac
}
r=$(cls origin/m1 "$P1" "$HA1");   [ "$r" = clean ] && ok || bad "C1 clean main merge: got '$r'"
r=$(cls origin/m2 "$P2" "$HA2");   [ "$r" = resolved ] && ok || bad "C2 conflict merge: got '$r'"
r=$(mp_resolved "$WK" origin/m2 "$P2" "$HA2")
[ "$r" = catalog/lanes.d/x.json ] && ok || bad "C2 resolution paths: got '$r'"
r=$(cls origin/m4 "$P1" "$HA2b");  [ "$r" = resolved ] && ok || bad "C3 evil merge is resolved, never clean: got '$r'"
r=$(mp_resolved "$WK" origin/m4 "$P1" "$HA2b")
[ "$r" = cron/y ] && ok || bad "C3 evil merge's hand edit is its resolution path: got '$r'"
chk_cls "C4 octopus"        full "$(cls origin/m1 "$P1" "$HN4")"
chk_cls "C5 sibling merge"  full "$(cls origin/m1 "$P1" "$HN3")"
chk_cls "C6 non-merge"      full "$(cls origin/m1 "$P1" "$HA3")"
chk_cls "C7 all-zero before" full "$(cls origin/m1 "$Z" "$HA1")"
chk_cls "C8 rebase"         full "$(cls origin/m1 "$P1" "$HN5")"
chk_cls "C9 unknown sha"    full "$(cls origin/m1 deadbeefdeadbeefdeadbeefdeadbeefdeadbeef "$HA1")"
chk_cls "C9b no base"       full "$(cls origin/nope "$P1" "$HA1")"
r=$(mp_main_files "$WK" origin/m1b "$P1" "$HA1b" | sort | tr '\n' ' ')
[ "$r" = "cron/x docs/verification-map/entries/b.md " ] && ok || bad "F1 main's incoming files: got '$r'"
r=$(mp_pr_files "$WK" origin/m1b "$HA1b" | tr '\n' ' ')
[ "$r" = "docs/verification-map/entries/a.md " ] && ok || bad "F1 the PR's own files: got '$r'"
mp_main_files "$WK" origin/m1 "$Z" "$HA1" >/dev/null 2>&1 && bad "F2 main files on a bad before must be rc 1" || ok

# ────────────────── part 2: the entry point, as CI runs it ───────────────────
H="$T/h"; mkdir -p "$H/catalog/lanes.d" "$T/out" "$T/stub"
scratch_install_closure bin/ci-merge-reuse.sh "$H" >/dev/null || { echo "FAIL: closure install"; exit 1; }
cp "$CAT" "$H/catalog/ci-merge-reuse.tsv"; cp "$KREG" "$H/catalog/lanes.d/"
IDS=$(awk -F'\t' '!/^#/ && NF >= 2 { print $1 }' "$CAT")
[ -n "$IDS" ] && ok || bad "the catalog names no step"
for want in vmap derived renders render-diff; do
  grep -qx "$want" <<<"$IDS" && ok || bad "the catalog has no '$want' row"
done
cat > "$T/stub/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/out/gh.argv"
cat "$T/gh.json"
exit "\$(cat "$T/gh.rc")"
EOF
chmod +x "$T/stub/gh"
runs() { # <conclusion> [branch] [name]
  jq -nc --arg c "$1" --arg b "${2:-ticket/x}" --arg n "${3:-Harness CI}" \
    '{workflow_runs: [{id: 111, name: $n, head_branch: $b, status: "completed",
      conclusion: (if $c == "null" then null else $c end)}]}' > "$T/gh.json"
}
runs success; echo 0 > "$T/gh.rc"

run_mr() { # run_mr <name> <base> <before> <head> [VAR=val ...]
  # A trailing UNSET=<NAME> removes that variable instead of setting it.
  local n="$1" base="$2" before="$3" head="$4" a d; shift 4
  local -a pre=() vars=() defs=(MR_ACTION=synchronize "MR_BASE_REF=$base" "MR_BEFORE=$before"
    "MR_HEAD=$head" MR_HEAD_REF=ticket/x CI_REPO=o/r GH_TOKEN=x "MR_GH=$T/stub/gh" "MR_GIT_DIR=$WK"
    PR_CI_MERGE_REUSE=on "GITHUB_OUTPUT=$T/out/$n.gho" "GITHUB_STEP_SUMMARY=$T/out/$n.sum")
  for a in "$@"; do case "$a" in UNSET=*) pre+=(-u "${a#UNSET=}") ;; esac; done
  for d in "${defs[@]}"; do
    case " ${pre[*]} " in *" ${d%%=*} "*) ;; *) vars+=("$d") ;; esac
  done
  for a in "$@"; do case "$a" in UNSET=*) ;; *) vars+=("$a") ;; esac; done
  : > "$T/out/$n.gho"; : > "$T/out/$n.sum"; : > "$T/out/gh.argv"
  env "${pre[@]}" "${vars[@]}" bash "$H/bin/ci-merge-reuse.sh" > "$T/out/$n.out" 2> "$T/out/$n.err"
  echo $? > "$T/out/$n.rc"
}
outv() { awk -v k="$2" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { print v }' "$T/out/$1.gho"; }
want() { # <case> <key> <value>
  local got; got=$(outv "$1" "$2")
  [ "$got" = "$3" ] && ok || bad "$1: $2='$got', want '$3' ($(outv "$1" reason))"
}
all_full() { # <case> — mode=full and every catalog step runs
  want "$1" mode full
  local id; for id in $IDS; do want "$1" "run_$id" 1; done
  [ "$(cat "$T/out/$1.rc")" = 0 ] && ok || bad "$1: rc $(cat "$T/out/$1.rc"), want 0"
}

# A1: clean merge, only cron/x from main, only a vmap entry in the PR
run_mr A1 m1 "$P1" "$HA1"
want A1 mode reuse; want A1 run_vmap 0; want A1 run_renders 0; want A1 run_render-diff 0
want A1 run_derived 0; want A1 prev_run 111
[ "$(cat "$T/out/A1.rc")" = 0 ] && ok || bad "A1 rc $(cat "$T/out/A1.rc")"
for s in vmap renders render-diff derived; do
  grep -qxF "merge-reuse: reused $s green on run 111 (${P1:0:8})" "$T/out/A1.out" && ok || bad "A1: no reused line for $s"
done
grep -q '^::notice title=merge-reuse::' "$T/out/A1.out" && ok || bad "A1: no ::notice line"
grep -q 'merge-reuse: mode=reuse' "$T/out/A1.sum" && ok || bad "A1: nothing in GITHUB_STEP_SUMMARY"
grep -qxF "api repos/o/r/actions/runs?head_sha=$P1&event=pull_request" "$T/out/gh.argv" && ok \
  || bad "A1: gh was not asked for the previous head's runs: $(cat "$T/out/gh.argv")"

# A1b: main also touches a vmap entry, so main's change and the PR meet there
run_mr A1b m1b "$P1" "$HA1b"
want A1b mode reuse; want A1b run_vmap 1; want A1b run_renders 0; want A1b run_render-diff 0

# A2: the hand-resolved conflict reaches the lane renders
run_mr A2 m2 "$P2" "$HA2"
want A2 mode reuse; want A2 run_renders 1; want A2 run_render-diff 1; want A2 run_vmap 0; want A2 run_derived 1
# A2b: the resolution path alone (neither side touched cron/y) makes renders run
run_mr A2b m4 "$P1" "$HA2b"
grep -qxF 'merge-reuse: run renders (a conflict resolution reaches it)' "$T/out/A2b.out" && ok || bad "A2b: renders did not run on the resolution"
want A2b mode reuse; want A2b run_renders 1; want A2b run_render-diff 1; want A2b run_vmap 0

# A3 / N1: a real commit after the merge
run_mr A3 m1 "$P1" "$HA3"; all_full A3
[ -s "$T/out/gh.argv" ] && bad "A3: a full push must not ask gh for anything" || ok
run_mr N2 m1 "$P1" "$HN2"; all_full N2
run_mr N3 m1 "$P1" "$HN3"; all_full N3
run_mr N4 m1 "$P1" "$HN4"; all_full N4
run_mr N5 m1 "$P1" "$HN5"; all_full N5
runs cancelled;          run_mr N6 m1 "$P1" "$HA1"; all_full N6
runs failure;            run_mr N7 m1 "$P1" "$HA1"; all_full N7
runs null;               run_mr N8 m1 "$P1" "$HA1"; all_full N8
runs success other/br;   run_mr N9 m1 "$P1" "$HA1"; all_full N9
runs success ticket/x "Other CI"; run_mr N9b m1 "$P1" "$HA1"; all_full N9b
# A green run on the queue head's own branch, so only the queue rule says full.
runs success mergify/merge-queue/main/x
run_mr N10 m1 "$P1" "$HA1" MR_HEAD_REF=mergify/merge-queue/main/x; all_full N10
runs success
run_mr N11 m1 "$P11" "$HN11"; all_full N11
run_mr N12 m3 "$P1" "$HN12"; all_full N12
run_mr N13 m1 "$P1" "$HA1" MR_ACTION=opened; all_full N13
run_mr N14 m1 "$Z" "$HA1"; all_full N14
echo 1 > "$T/gh.rc"
run_mr Nrate m1 "$P1" "$HA1"; all_full Nrate
grep -q '^::warning' "$T/out/Nrate.out" && ok || bad "Nrate: a failed run read gives no ::warning::"
echo 0 > "$T/gh.rc"; echo 'not json' > "$T/gh.json"
run_mr Njson m1 "$P1" "$HA1"; all_full Njson
runs success
run_mr Nnogh m1 "$P1" "$HA1" MR_GH="$T/stub/no-such-gh"; all_full Nnogh

# K: the knob
run_mr K1 m1 "$P1" "$HA1" PR_CI_MERGE_REUSE=off; all_full K1
run_mr K2 m1 "$P1" "$HA1" 'PR_CI_MERGE_REUSE=OFF?'; all_full K2
grep -q 'PR_CI_MERGE_REUSE' "$T/out/K2.err" && ok || bad "K2: a garbled knob gets no stderr note"
run_mr K3 m1 "$P1" "$HA1" UNSET=PR_CI_MERGE_REUSE; want K3 mode reuse
run_mr K3b m1 "$P1" "$HA1" PR_CI_MERGE_REUSE=; want K3b mode reuse
run_mr K4 m1 "$P1" "$HA1" PR_CI_MERGE_REUSE=0; all_full K4
def=$(jq -r '.libs[] | select(.id == "ci-merge-reuse") | .knobs[] | select(.env == "PR_CI_MERGE_REUSE") | .default' "$KREG")
r=$(unset PR_CI_MERGE_REUSE; mp_knob)
[ "$def" = on ] && [ "$r" = "$def" ] && ok || bad "K5 registry default '$def' vs mp_knob with no env '$r'"
r=$(PR_CI_MERGE_REUSE=off mp_knob); [ "$r" = off ] && ok || bad "K5 env off read as '$r'"

# E: bad args and an unreadable catalog answer full, rc 2
run_mr E1 m1 "$P1" ""
want E1 mode full; [ "$(cat "$T/out/E1.rc")" = 2 ] && ok || bad "E1 rc $(cat "$T/out/E1.rc"), want 2"
for id in $IDS; do want E1 "run_$id" 1; done
run_mr E2 m1 "$P1" "$HA1" MR_CATALOG="$T/no-catalog.tsv"
want E2 mode full; [ "$(cat "$T/out/E2.rc")" = 2 ] && ok || bad "E2 rc $(cat "$T/out/E2.rc"), want 2"

echo "ci-merge-reuse (BH-5357): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
