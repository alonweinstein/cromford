#!/bin/bash
# tests/ci-merge-reuse-opened.bh-6310-test.sh — BH-6310: GitHub sends no
# before sha on a PR's opened/reopened event, so bin/ci-merge-reuse.sh sees an
# empty MR_BEFORE. That is full mode with rc 0, not a usage error. Every other
# empty argument stays rc 2, after writing mode=full.
#
# Drives the production entry point from a scratch install of its closure,
# with GITHUB_OUTPUT set. The argument check runs before any git read, so no
# fixture repo is needed.
#
#   O1  opened, empty before: rc 0, mode=full, every run_*=1, the reason line.
#   O2  synchronize, empty before: rc 2, mode=full.
#   O3  reopened, empty before: rc 0, mode=full, every run_*=1.
#   O4  opened, empty before and empty MR_HEAD: rc 2.
#   O5  no action, empty before: rc 2.
#   O6  edited, empty before: rc 2.
#   O7  opened, empty before and empty MR_BASE_REF: rc 2.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/ci-merge-reuse-opened.bh-6310-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
CAT="$DIR/catalog/ci-merge-reuse.tsv"
KREG="$DIR/catalog/lanes.d/_lib.ci-merge-reuse.json"
for f in "$DIR/bin/ci-merge-reuse.sh" "$CAT" "$KREG"; do
  [ -f "$f" ] || { echo "FAIL: ${f#"$DIR"/} does not exist"; exit 1; }
done
unset PR_CI_MERGE_REUSE GITHUB_OUTPUT GITHUB_STEP_SUMMARY

H="$T/h"; mkdir -p "$H/catalog/lanes.d" "$T/out"
scratch_install_closure bin/ci-merge-reuse.sh "$H" >/dev/null || { echo "FAIL: closure install"; exit 1; }
cp "$CAT" "$H/catalog/ci-merge-reuse.tsv"; cp "$KREG" "$H/catalog/lanes.d/"
IDS=$(awk -F'\t' '!/^#/ && NF >= 2 { print $1 }' "$CAT")
[ -n "$IDS" ] && ok || bad "the catalog names no step"

HEADSHA=0123456789abcdef0123456789abcdef01234567
run_mr() { # run_mr <name> [VAR=val ...] — a trailing UNSET=<NAME> removes it
  local n="$1" a; shift
  local -a pre=() vars=(MR_BEFORE= "MR_HEAD=$HEADSHA" MR_BASE_REF=main MR_HEAD_REF=fix/x
    PR_CI_MERGE_REUSE=on "GITHUB_OUTPUT=$T/out/$n.gho" "GITHUB_STEP_SUMMARY=$T/out/$n.sum")
  for a in "$@"; do
    case "$a" in UNSET=*) pre+=(-u "${a#UNSET=}") ;; *) vars+=("$a") ;; esac
  done
  : > "$T/out/$n.gho"; : > "$T/out/$n.sum"
  env -u MR_ACTION "${pre[@]}" "${vars[@]}" bash "$H/bin/ci-merge-reuse.sh" > "$T/out/$n.out" 2> "$T/out/$n.err"
  echo $? > "$T/out/$n.rc"
}
outv() { awk -v k="$2" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { print v }' "$T/out/$1.gho"; }
want() { # <case> <key> <value>
  local got; got=$(outv "$1" "$2")
  [ "$got" = "$3" ] && ok || bad "$1: $2='$got', want '$3' ($(outv "$1" reason))"
}
want_rc() { # <case> <rc>
  local got; got=$(cat "$T/out/$1.rc")
  [ "$got" = "$2" ] && ok || bad "$1: rc $got, want $2 ($(outv "$1" reason))"
}
all_run() { # <case> — every catalog step runs
  local id; for id in $IDS; do want "$1" "run_$id" 1; done
}

# O1: opened, no before sha — full mode, rc 0, the reason line as before
run_mr O1 MR_ACTION=opened
want_rc O1 0; want O1 mode full; all_run O1
want O1 reason "bad args: MR_BEFORE is empty"
grep -qx 'merge-reuse: mode=full reason=bad args: MR_BEFORE is empty' "$T/out/O1.out" \
  && ok || bad "O1: stdout has no reason line: $(cat "$T/out/O1.out")"

# O2: synchronize always carries a before sha, so an empty one is bad args
run_mr O2 MR_ACTION=synchronize
want_rc O2 2; want O2 mode full; all_run O2

# O3: reopened, no before sha — same as opened
run_mr O3 MR_ACTION=reopened
want_rc O3 0; want O3 mode full; all_run O3

# O4-O7: a real bad argument stays rc 2, still after writing mode=full
run_mr O4 MR_ACTION=opened MR_HEAD=
want_rc O4 2; want O4 mode full
run_mr O5
want_rc O5 2; want O5 mode full
run_mr O6 MR_ACTION=edited
want_rc O6 2; want O6 mode full
run_mr O7 MR_ACTION=opened MR_BASE_REF=
want_rc O7 2; want O7 mode full

echo "ci-merge-reuse opened (BH-6310): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
