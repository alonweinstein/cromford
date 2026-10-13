#!/usr/bin/env bash
# BH-1325: the never-shipped mc_pr_read reader and the vacuous mirror suite stay retired.
set -u
. "$(dirname "$0")/lib/scratch.sh" || exit 1
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel) || exit 1
cd "$root" || exit 1
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
for d in bin tests; do
  [ -d "$d" ] || { echo "FAIL missing dir $d (wrong cwd?)"; exit 1; }
done
hits=$(git grep -l mc_pr_read -- bin/)
[ -z "$hits" ] && ok "(a) no mc_pr_read in bin/" || bad "(a) mc_pr_read in bin/: $hits"
hits=$(git grep -l mc_pr_read -- tests/ ':!tests/mc-pr-read-retired.bh-1325-test.sh')
[ -z "$hits" ] && ok "(b) no test fixture names mc_pr_read" || bad "(b) mc_pr_read in tests/: $(echo $hits)"
[ ! -e tests/mc-module-mirror-test.sh ] && ok "(c) mirror suite retired" || bad "(c) tests/mc-module-mirror-test.sh still exists"
# SHARE MIRROR: .harness/ (build records) is not published, so (d) skips.
if [ ! -f .harness/specs/BH-597/plan.md ]; then echo "SKIP (d): no .harness/specs/BH-597/plan.md in this copy"
elif grep -q '^## AS-BUILT' .harness/specs/BH-597/plan.md; then ok "(d) BH-597 plan has AS-BUILT"
else bad "(d) BH-597 plan lacks ## AS-BUILT"; fi
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
