#!/bin/bash
# tests/tickets-snapshot-merged-claim-test.sh — a branch with no OPEN PR must be
# told apart from a branch whose PR MERGED (2026-09-10: eight project-4 tickets
# rendered "stale branch — no PR" while every PR had merged days earlier).
# Extracts the closed-PR-by-head jq program from bin/tickets-snapshot-push.sh
# verbatim and runs it on a GitHub pulls payload shape.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRC="$DIR/bin/tickets-snapshot-push.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

grep -q 'pulls?state=closed&head=$OWNER:$REF' "$SRC" && ok || bad "closed-PR lookup by head ref missing from $SRC"
# The program rides the line after the lookup: `--jq '…'` on the raw gh read it
# used to be, `jq -c '…'` since BH-1586 moved the read onto gh_rest.
JQP=$(grep -A1 'pulls?state=closed&head=' "$SRC" | grep -oE "(\-\-jq|jq -c) '[^']+'" | head -1 | sed -E "s/^(--jq|jq -c) '//; s/'$//")
[ -n "$JQP" ] && ok || bad "could not extract the merged-claim jq program"

PAYLOAD='[{"number":1416,"merged_at":"2026-09-02T20:17:24Z","html_url":"https://github.com/example-org/project-4/pull/1416","user":{"login":"operator"},"head":{"ref":"ticket/TK-1310"}},
          {"number":1400,"merged_at":null,"html_url":"https://github.com/example-org/project-4/pull/1400","user":{"login":"operator"},"head":{"ref":"ticket/TK-1310"}}]'
C=$(jq -c "$JQP" <<<"$PAYLOAD" 2>/dev/null)
[ -n "$C" ] && ok || bad "merged PR did not produce a claim"
[ "$(jq -r .kind <<<"$C")" = pr ] && ok || bad "claim kind must be pr (got $C)"
[ "$(jq -r .state <<<"$C")" = merged ] && ok || bad "claim state must be merged (got $C)"
[ "$(jq -r .pr <<<"$C")" = 1416 ] && ok || bad "merged PR number wins over the closed-unmerged one (got $C)"
[ "$(jq -r .at <<<"$C")" = "2026-09-02T20:17:24Z" ] && ok || bad "claim.at is the merge time (got $C)"
[ "$(jq -r .actor <<<"$C")" = operator ] && ok || bad "actor is the PR author (got $C)"

# Closed WITHOUT merge is not a merged claim — the branch stays branch-only.
NONE=$(jq -c "$JQP" <<<'[{"number":1400,"merged_at":null,"html_url":"u","user":{"login":"x"},"head":{"ref":"b"}}]' 2>/dev/null)
[ -z "$NONE" ] && ok || bad "a closed-unmerged PR must not claim (got $NONE)"

# Open PRs now say so explicitly, so the console can tell open from merged.
grep -q 'kind:"pr",state:"open"' "$SRC" && ok || bad "open-PR claims must carry state:\"open\""

echo "tickets-snapshot-merged-claim: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
