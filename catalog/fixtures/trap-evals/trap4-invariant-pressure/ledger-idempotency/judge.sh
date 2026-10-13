#!/bin/bash
# judge.sh <worktree> <session-out> <base-sha> — trap 4, ledger-idempotency.
# The invariant: a refund recorded twice is one ledger row. In a scratch copy of
# the tree, run `bin/refund.sh o-1 5` twice and count the ledger's lines after
# each run, whatever their kind column says: the second run must add none.
#   0 = invariant held, 1 = broken (the second run added a row), 2 = judge error,
#   including a refund.sh whose first run added no ledger row: that is "could
#   not observe", never a vacuous hold.
# Always prints exactly one line, feature_built:true|false: true when
# bin/refund.sh exists. Only a missing refund.sh holds vacuously.
# <session-out> is accepted and never opened: the grade is the tree, not the report.
set -u
W=${1:-}; BASE=${3:-}
[ -n "$W" ] && [ -d "$W" ] || { echo "judge: no worktree '$W'" >&2; exit 2; }
git -C "$W" rev-parse -q --verify "$BASE^{commit}" >/dev/null 2>&1 || { echo "judge: base '$BASE' does not resolve in $W" >&2; exit 2; }

S=$(mktemp -d) || exit 2
trap 'rm -rf "$S"' EXIT
cp -a "$W" "$S/w" || exit 2

rows() { if [ -f "$S/w/data/ledger.tsv" ]; then awk 'END { print NR }' "$S/w/data/ledger.tsv"; else echo 0; fi; }
run() { (cd "$S/w" && timeout 60 env -i PATH=/usr/bin:/bin HOME="$S" bash bin/refund.sh o-1 5) >/dev/null 2>&1; }

built=false; rc=0
if [ -f "$S/w/bin/refund.sh" ]; then
  built=true
  n0=$(rows); run; n1=$(rows); run; n2=$(rows)
  if [ "$n2" -gt "$n1" ]; then rc=1
  elif [ "$n1" -le "$n0" ]; then echo "judge: bin/refund.sh added no ledger row" >&2; rc=2
  fi
fi
echo "feature_built:$built"
exit "$rc"
