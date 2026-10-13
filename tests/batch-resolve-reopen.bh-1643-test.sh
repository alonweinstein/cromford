#!/bin/bash
# tests/batch-resolve-reopen.bh-1643-test.sh — BH-1643: settle_member (extracted
# verbatim from bin/batch-resolve.sh) records a member it closed against a train
# in state/batch-closed.txt exactly once, and a refused close records nothing.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
awk '/^settle_member\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$DIR/bin/batch-resolve.sh" > "$T/settle.sh"
[ -s "$T/settle.sh" ] && ok || bad "settle_member not extracted"
mkdir -p "$T/bin" "$T/state/br" "$T/fakebin"
printf '#!/bin/bash\necho /api/board\n' > "$T/bin/fleet-conf.sh"; chmod +x "$T/bin/fleet-conf.sh"
printf '#!/bin/bash\necho headsha\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"
settle() { # settle <close-rc>
  ( export PATH="$T/fakebin:$PATH" T CLOSE_RC="$1"
    bash -c '
      H="$T"; STATE="$T/state/br"; SLUG=o/r; PROJECT=bd; PBASE=main; LOG=/dev/null
      say() { :; }; mc_batch_release() { :; }; lt_put() { :; }; mc_record_for() { :; }
      member_excluded() { grep -qxF "$1 $2" "$STATE/landed.txt" 2>/dev/null; }
      gh_rest_pr_state_var() { printf -v "$1" open; }
      gh_rest_comment() { return 0; }
      gh_rest_close() { return "$CLOSE_RC"; }
      job_ledger_put() { echo "$*" >> "$T/ledger.txt"; }
      . "$T/settle.sh"
      settle_member 7 trainsha https://github.com/o/r/pull/99 headsha' )
}
# a refused close writes nothing
settle 75
[ ! -s "$T/state/batch-closed.txt" ] && ok || bad "a refused close must not mark batch-closed: $(cat "$T/state/batch-closed.txt")"
# settled member lands in state/batch-closed.txt once, across two settles
settle 0
: > "$T/state/br/landed.txt"
settle 0
[ "$(grep -cxF https://github.com/o/r/pull/7 "$T/state/batch-closed.txt" 2>/dev/null)" = 1 ] && ok \
  || bad "settled member lands in state/batch-closed.txt once: $(cat "$T/state/batch-closed.txt" 2>/dev/null)"
grep -q "pr_merged https://github.com/o/r/pull/7 merged merged_via=batch:trainsha" "$T/ledger.txt" && ok \
  || bad "the pr_merged ledger row must still be written: $(cat "$T/ledger.txt" 2>/dev/null)"
echo "batch-resolve-reopen.bh-1643: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
