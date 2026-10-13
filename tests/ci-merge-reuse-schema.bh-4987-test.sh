#!/bin/bash
# tests/ci-merge-reuse-schema.bh-4987-test.sh — BH-4987 lead review r3: the
# `bin/schema-build.sh --check` line sits in harness-ci.yml's renders step,
# which a merge-from-main push skips when steps.reuse.outputs.run_renders is 0.
# The renders row of catalog/ci-merge-reuse.tsv had no schema glob, so a merge
# whose conflict was on worker/jobs/schema.sql (both sides added a fragment and
# the union was hand-resolved) skipped the check and went green.
#
#   S1  a hand-resolved conflict on worker/jobs/schema.sql: run_renders=1
#   S2  a hand-resolved conflict on a worker/jobs/schema.d/ fragment: run_renders=1
#   S3  main and the PR both touch bin/schema-build.sh: run_renders=1
#   S4  main and the PR both touch bin/lib/d1-schema.sh: run_renders=1
#   S5  the control: main's change reaches no schema path: run_renders=0
#   W1  the renders step in harness-ci.yml still runs `bin/schema-build.sh --check`
#
# The production entry point bin/ci-merge-reuse.sh runs from a scratch install
# of its closure with the REAL catalog and a stub gh that reports a green run.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/ci-merge-reuse-schema.bh-4987-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
CAT="$DIR/catalog/ci-merge-reuse.tsv"
KREG="$DIR/catalog/lanes.d/_lib.ci-merge-reuse.json"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset PR_CI_MERGE_REUSE GITHUB_OUTPUT GITHUB_STEP_SUMMARY

# ─────────────────────────── the fixture repo ────────────────────────────────
WK="$T/repo"; git init -q -b main "$WK"
g() { git -C "$WK" "$@"; }
w() { mkdir -p "$WK/$(dirname "$1")"; printf '%s\n' "$2" > "$WK/$1"; }
sha() { g rev-parse HEAD; }
w worker/jobs/schema.sql "$(printf 'CREATE TABLE a (id INTEGER);\nCREATE TABLE z (id INTEGER);')"
w worker/jobs/schema.d/0000-base.sql "$(printf 'CREATE TABLE a (id INTEGER);\nCREATE TABLE z (id INTEGER);')"
w bin/schema-build.sh 'echo build0'; w bin/lib/d1-schema.sh 'echo split0'
w docs/verification-map/entries/a.md a0; w src/code.txt code0
g add -A; g commit -qm base; B0=$(sha)
g checkout -qb pr "$B0"; w docs/verification-map/entries/a.md a1; g commit -qam "the pr"; P0=$(sha)

# conflict <id> <path> <pr text> <main text> <resolved text> — a PR side and a
# main side that both change <path>, merged and hand-resolved. Sets P_<id>, H_<id>.
conflict() {
  local id="$1" p="$2"
  g checkout -qb "p-$id" "$B0"; w "$p" "$3"; g add -A; g commit -qm "pr: $id"; eval "P_$id=\$(sha)"
  g checkout -qb "m-$id" "$B0"; w "$p" "$4"; g add -A; g commit -qm "main: $id"
  g checkout -q "p-$id"; g merge -q --no-edit "m-$id" >/dev/null 2>&1
  w "$p" "$5"; g add -A; g commit -q --no-edit; eval "H_$id=\$(sha)"
  g update-ref "refs/remotes/origin/m-$id" "m-$id"
}
conflict s1 worker/jobs/schema.sql \
  "$(printf 'CREATE TABLE a (id INTEGER);\nCREATE TABLE pr (id INTEGER);')" \
  "$(printf 'CREATE TABLE a (id INTEGER);\nCREATE TABLE main (id INTEGER);')" \
  "$(printf 'CREATE TABLE a (id INTEGER);\nCREATE TABLE pr (id INTEGER);\nCREATE TABLE main (id INTEGER);')"
conflict s2 worker/jobs/schema.d/0000-base.sql \
  "$(printf 'CREATE TABLE a (id INTEGER, p TEXT);\nCREATE TABLE z (id INTEGER);')" \
  "$(printf 'CREATE TABLE a (id INTEGER, m TEXT);\nCREATE TABLE z (id INTEGER);')" \
  "$(printf 'CREATE TABLE a (id INTEGER, p TEXT, m TEXT);\nCREATE TABLE z (id INTEGER);')"

# both <id> <path> — the PR and main each change <path> in a different place,
# so the merge is clean and only the "both sides" rule can select a step.
both() {
  local id="$1" p="$2"
  g checkout -qb "p-$id" "$B0"; printf 'pr\n' >> "$WK/$p"; g commit -qam "pr: $id"; eval "P_$id=\$(sha)"
  g checkout -qb "m-$id" "$B0"; { printf 'main\n'; cat "$WK/$p"; } > "$WK/$p.n"; mv "$WK/$p.n" "$WK/$p"; g commit -qam "main: $id"
  g checkout -q "p-$id"; g merge -q --no-edit "m-$id" >/dev/null 2>&1 || { echo "FAIL: setup: $id merge conflicted"; exit 1; }
  eval "H_$id=\$(sha)"
  g update-ref "refs/remotes/origin/m-$id" "m-$id"
}
both s3 bin/schema-build.sh
both s4 bin/lib/d1-schema.sh
# S5: main changes only src/, the PR only a docs entry
g checkout -qb m-s5 "$B0"; w src/code.txt code5; g commit -qam "main: src"; g update-ref refs/remotes/origin/m-s5 m-s5
g checkout -qb h-s5 "$P0"; g merge -q --no-edit m-s5; H_s5=$(sha); P_s5=$P0
g checkout -q main

# ───────────────────────────── the entry point ───────────────────────────────
H="$T/h"; mkdir -p "$H/catalog/lanes.d" "$T/out" "$T/stub"
scratch_install_closure bin/ci-merge-reuse.sh "$H" >/dev/null || { echo "FAIL: closure install"; exit 1; }
cp "$CAT" "$H/catalog/ci-merge-reuse.tsv"; cp "$KREG" "$H/catalog/lanes.d/"
printf '%s\n' '#!/bin/bash' \
  "jq -nc '{workflow_runs: [{id: 111, name: \"Harness CI\", head_branch: \"ticket/x\", status: \"completed\", conclusion: \"success\"}]}'" \
  > "$T/stub/gh"
chmod +x "$T/stub/gh"
run_mr() { # <case> <main branch> <before> <head>
  : > "$T/out/$1.gho"
  env MR_ACTION=synchronize "MR_BASE_REF=$2" "MR_BEFORE=$3" "MR_HEAD=$4" MR_HEAD_REF=ticket/x \
      CI_REPO=o/r GH_TOKEN=x "MR_GH=$T/stub/gh" "MR_GIT_DIR=$WK" PR_CI_MERGE_REUSE=on \
      "GITHUB_OUTPUT=$T/out/$1.gho" "GITHUB_STEP_SUMMARY=$T/out/$1.sum" \
      bash "$H/bin/ci-merge-reuse.sh" > "$T/out/$1.out" 2>&1
}
outv() { awk -v k="$2" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { print v }' "$T/out/$1.gho"; }
want() { # <case> <key> <value> <why>
  local got; got=$(outv "$1" "$2")
  [ "$got" = "$3" ] && ok || bad "$1: $2='$got', want '$3' — $4 (reason: $(outv "$1" reason))"
}

for c in s1 s2 s3 s4 s5; do
  p="P_$c"; h="H_$c"
  run_mr "$c" "m-$c" "${!p}" "${!h}"
  want "$c" mode reuse "the fixture must be a merge-only push the reuse step decides"
done
want s1 run_renders 1 "a conflict on worker/jobs/schema.sql must run schema-build --check"
want s2 run_renders 1 "a conflict on a schema.d/ fragment must run schema-build --check"
want s3 run_renders 1 "main and the PR both changing bin/schema-build.sh must run its check"
want s4 run_renders 1 "main and the PR both changing bin/lib/d1-schema.sh must run its check"
want s5 run_renders 0 "a merge that reaches no render or schema path still reuses"

# W1: the check the row protects is still in the step the row gates.
awk '/- name: lane renders generate and their sources validate/ { f = 1 } f && /^      - name: / && !/lane renders/ { exit } f' \
  "$DIR/.github/workflows/harness-ci.yml" > "$T/step"
grep -q "steps.reuse.outputs.run_renders != '0'" "$T/step" && grep -q 'bin/schema-build.sh --check' "$T/step" && ok \
  || bad "W1 the renders step must be gated on run_renders and run bin/schema-build.sh --check"

echo "ci-merge-reuse-schema.bh-4987: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
