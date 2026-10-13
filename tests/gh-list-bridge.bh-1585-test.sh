#!/bin/bash
# tests/gh-list-bridge.bh-1585-test.sh — tests/lib/gh-list-bridge.sh answers
# only through the suite's OWN stub (BH-1585 review round 2, B1).
#
# THE CI RED THIS PINS. The bridge is an exported function, so it rides into
# merge-conductor's DETACHED lanes, which run with PATH="$MC_RR_PATH" and no
# fixture bin. There it found no stub, synthesized a list it could not read and
# answered HTTP 500 — slow enough on the GitHub runner that lead-verdicts C-D's
# control-tick lane landed in the next case. The rule now: no stub on PATH is
# "gh: command not found" (127, nothing on stdout, exactly a box with no gh),
# and a `gh` outside the suite's scratch tree is never called.
#
#   1. stub on PATH: the stub's own answer passes through, and the list's lazy
#      read (HPL_READ_ROLE=list-lazy) is served from the list;
#   2. no gh on PATH (a detached lane): 127, empty stdout, fast;
#   3. a gh outside GH_LIST_BRIDGE_ROOT (a runner's real gh): 127, never run.
#
# Run from anywhere: tests/gh-list-bridge.bh-1585-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/fakebin" "$T/nogh"
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
case "$*" in
  *v3.diff*) printf 'HTTP/1.1 200 OK\r\n\r\n+++ b/src/x.ts\n' ;;
  *"pr list -R o/r --state open --author operator"*)
    echo '[{"number":41,"url":"https://github.com/o/r/pull/41","headRefOid":"h41","headRefName":"b","isDraft":false,"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","state":"OPEN","baseRefName":"main"}]' ;;
  *"pr list"*) echo '[]' ;;
  *) echo "" ;;
esac
SH
chmod +x "$T/fakebin/gh"
# The "real gh" a runner may have: outside the scratch root the bridge trusts.
FOREIGN="$T/foreign"; mkdir -p "$FOREIGN"
printf '#!/bin/bash\necho ran >> "%s/foreign-ran"\nprintf "HTTP/1.1 200 OK\\r\\n\\r\\nREAL\\n"\n' "$T" > "$FOREIGN/gh"; chmod +x "$FOREIGN/gh"

diffread() { gh api -i -X GET repos/o/r/pulls/41 -H 'Accept: application/vnd.github.v3.diff'; }

# 1. the stub on PATH
OUT=$(PATH="$T/fakebin:$PATH" diffread); RC=$?
[ "$RC" = 0 ] && grep -q '^+++ b/src/x.ts' <<<"$OUT" && ok || bad "1a the stub's own answer must pass through (rc $RC): $OUT"
OUT=$(PATH="$T/fakebin:$PATH" HPL_READ_ROLE=list-lazy gh api -i -X GET repos/o/r/pulls/41); RC=$?
[ "$RC" = 0 ] && [ "$(sed -n '/^\r\?$/,$p' <<<"$OUT" | tail -1 | jq -r .mergeable_state)" = dirty ] \
  && ok || bad "1b the list's lazy read is served from the list row (rc $RC): $OUT"

# 2. no gh on PATH — what a detached lane sees
OUT=$(env PATH="$T/nogh:/usr/bin:/bin" bash -c "$(declare -f diffread); diffread" 2>"$T/err"); RC=$?
[ "$RC" = 127 ] && [ -z "$OUT" ] && ok || bad "2a no stub on PATH must be 'gh: command not found' (127, empty stdout), never a synthesized answer (rc $RC, out: $OUT)"
grep -q 'command not found' "$T/err" && ok || bad "2b and say so on stderr: $(cat "$T/err")"

# 3. a gh outside the suite's scratch tree
OUT=$(GH_LIST_BRIDGE_ROOT="$T/fakebin" PATH="$FOREIGN:/usr/bin:/bin" bash -c "$(declare -f diffread); diffread" 2>/dev/null); RC=$?
[ "$RC" = 127 ] && [ -z "$OUT" ] && [ ! -e "$T/foreign-ran" ] \
  && ok || bad "3a a gh outside the suite's tree must never be run (rc $RC, out: $OUT, ran: $(cat "$T/foreign-ran" 2>/dev/null))"

echo "gh-list-bridge.bh-1585: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
