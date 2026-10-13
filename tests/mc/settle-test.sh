#!/bin/bash
# tests/mc/settle-test.sh — the settle half of tests/merge-conductor-test.sh,
# split out of it verbatim by BH-684 when bin/lib/merge-conductor-lib.sh became a
# shim over bin/lib/mc/. The cases here exercise the closed-list settle pass that
# bin/lib/mc/settle.sh owns, and the GitHub API rate-limit budget that decides
# whether the tick buys it at all: a low budget must skip the pass and say so,
# a healthy one must make it, and neither may change how an OPEN PR classifies.
#
# It drives the real bin/merge-conductor.sh against a stubbed gh, the same
# fixture the parent suite builds.
# Run from anywhere: tests/mc/settle-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/../lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
# fixture: tests/lib/fixture-harness.sh (BH-1196) — what is copied into the
# scratch harness, and why each file is there, is documented in the lib.
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
export HARNESS="$T/h"; fx_mc_harness "$DIR" "$T" || exit 1
[ -d "$DIR/bin/lib/mc" ] || exit 1   # impact: this suite runs when bin/lib/mc/ changes (bin/test-impact.sh reads rooted tokens)
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
H1=aaaaaaaa1111; H2=bbbbbbbb2222
c() { mc_classify "$@" | cut -f1; }
H3=cccccccc3333   # carried from section 1 of the parent suite: the sections below use it

fx_conductor_tick "$DIR" "$T" || exit 1
[ -f "$DIR/bin/merge-conductor.sh" ] || exit 1   # impact: this suite drives the whole tick
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\nissuer example-org/issuer - - 3 box-issuer\n' > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
: # flock is NOT stubbed: the per-PR lock shard is the thing under test
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
# A build record for PR 11 (APPROVE bound to head H1) and PR 12 (APPROVE bound to
# H1 while its head is H2 = moved). PR 13 has no record but a ticket/ branch.
mkdir -p "$T/h/builds/demo-os-TK-11-202609120001" "$T/h/builds/pool-demo-os-TK-12-202609120002"
echo "PR_CREATED https://github.com/example-org/demo-os/pull/11" > "$T/h/builds/demo-os-TK-11-202609120001/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$T/h/builds/demo-os-TK-11-202609120001/review.md"
echo "$H1" > "$T/h/builds/demo-os-TK-11-202609120001/reviewed-sha"
echo "PR_CREATED https://github.com/example-org/demo-os/pull/12" > "$T/h/builds/pool-demo-os-TK-12-202609120002/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$T/h/builds/pool-demo-os-TK-12-202609120002/review.md"
echo "$H1" > "$T/h/builds/pool-demo-os-TK-12-202609120002/reviewed-sha"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
# Both list branches answer --json arrays: since #329 the conductor asks
# bin/lib/gh-pr-list.sh for the list (once per HARNESS_PR_AUTHORS login) and
# does its own jq, so a stub that pre-extracted TSV would be answering a
# question the conductor no longer asks.
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"pr merge"*|*"push"*|*"pr comment"*|*"issue close"*|*"issue comment"*|*"pr review"*|*"pr edit"*)
    echo "WRITE VERB IN OBSERVE MODE: \$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"pr list -R example-org/demo-os --state open"*)
    cat <<'J'
[{"number":11,"url":"https://github.com/example-org/demo-os/pull/11","headRefOid":"$H1","headRefName":"ticket/TK-11","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"},
 {"number":12,"url":"https://github.com/example-org/demo-os/pull/12","headRefOid":"$H2","headRefName":"ticket/TK-12","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"},
 {"number":13,"url":"https://github.com/example-org/demo-os/pull/13","headRefOid":"$H1","headRefName":"ticket/TK-13","isDraft":false,"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","state":"OPEN"},
 {"number":14,"url":"https://github.com/example-org/demo-os/pull/14","headRefOid":"$H1","headRefName":"fix/by-hand","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"}]
J
    ;;
  # TEST-CHANGE (BH-782): the CLOSED list is all-mappable, so it is a REST read
  # (bin/lib/gh-rest.sh) and a REST failure is no longer retried over
  # a GraphQL pr list. The shim answers the REST path with a status line and a
  # REST-shaped body; the open list still carries GraphQL-only fields
  # (mergeStateStatus/mergeable/isInMergeQueue) and is unchanged.
  *"repos/example-org/demo-os/pulls?state=closed"*)
    printf 'HTTP/2.0 200\r\n\r\n'
    cat <<'JR'
[{"number":15,"html_url":"https://github.com/example-org/demo-os/pull/15","title":"TK-15","body":"","state":"closed","merged_at":null,"closed_at":"2026-09-12T01:00:00Z","created_at":"2026-09-11T00:00:00Z","updated_at":"2026-09-12T01:00:00Z","draft":false,"labels":[],"user":{"login":"operator","type":"User"},"head":{"ref":"ticket/TK-15","sha":"deadbee"},"base":{"ref":"main"}}]
JR
    ;;
  *"pr list -R example-org/issuer --state open"*) echo "[]" ;;
  # TEST-CHANGE (BH-782): the CLOSED list is all-mappable, so it is a REST read
  # (bin/lib/gh-rest.sh) and a REST failure is no longer retried over
  # a GraphQL pr list. The shim answers the REST path with a status line and a
  # REST-shaped body; the open list still carries GraphQL-only fields
  # (mergeStateStatus/mergeable/isInMergeQueue) and is unchanged.
  *"repos/example-org/issuer/pulls?state=closed"*)
    printf 'HTTP/2.0 200\r\n\r\n'
    cat <<'JR'
[{"number":7,"html_url":"https://github.com/example-org/issuer/pull/7","title":"IS-7","body":"","state":"closed","merged_at":null,"closed_at":"2026-09-12T01:00:00Z","created_at":"2026-09-11T00:00:00Z","updated_at":"2026-09-12T01:00:00Z","draft":false,"labels":[],"user":{"login":"operator","type":"User"},"head":{"ref":"ticket/is-7","sha":"deadbe7"},"base":{"ref":"main"}}]
JR
    ;;
  *"issue view 7"*) echo "OPEN" ;;
  *"actions/runs?head_sha=$H1"*) printf 'completed|success\ncompleted|success\n' ;;
  *"actions/runs?head_sha=$H2"*) printf 'in_progress|\n' ;;
  *"pr view"*"--json body"*) echo "plain body" ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET; BODY=""
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; --data-binary) BODY="$2"; shift 2 ;; *) shift ;; esac; done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
case "$M $URL" in
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  # The jobs ledger's answer for one PR. A 404 (no job recorded this PR) is the
  # default and is what every case below 4j runs on; 4j drops a row in the file
  # to drive mc_job_running through the real client.
  "GET "*/api/verdict*) if [ -s "${JOBROW:-/nonexistent}" ]; then printf '%s\n200\n' "$(cat "$JOBROW")"
                        else printf '{"error":"not found"}\n404\n'; fi ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x REQ_SINK="$T/req.txt" JOBROW="$T/ledger-job.json" "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
: > "$T/gh-calls.txt"; : > "$T/req.txt"
run_tick
state_of() { awk -F'\t' -v k="$1" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv"; }

# ============================================================================
# 10. GitHub API rate-limit budget: low budget skips the non-essential closed-list pass
# ============================================================================
# One project, one READY PR, one closed-unmerged PR. The gh stub records every
# argv and answers rate_limit with core remaining from GH_BUDGET_CORE_REMAINING.
printf 'bproj example-org/b-os https://demo.example /api/board 2 box-b\n' > "$T/h/fleet.conf"
mkdir -p "$T/h/builds/pool-bproj-TK-1-202609160001"
echo "PR_CREATED https://github.com/example-org/b-os/pull/1" > "$T/h/builds/pool-bproj-TK-1-202609160001/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$T/h/builds/pool-bproj-TK-1-202609160001/review.md"
echo "$H1" > "$T/h/builds/pool-bproj-TK-1-202609160001/reviewed-sha"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
CORE_REM="\${GH_BUDGET_CORE_REMAINING:-800}"
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"auth token"*) echo faketoken ;;
  *"api rate_limit"*) printf '{"resources":{"core":{"remaining":%s,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}\n' "\$CORE_REM" ;;
  *"pr list -R example-org/b-os --state open"*)
    echo '[{"number":1,"url":"https://github.com/example-org/b-os/pull/1","headRefOid":"$H1","headRefName":"ticket/TK-1","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"}]' ;;
  # TEST-CHANGE (BH-782): the CLOSED list is all-mappable, so it is a REST read
  # (bin/lib/gh-rest.sh) and a REST failure is no longer retried over
  # a GraphQL pr list. The shim answers the REST path with a status line and a
  # REST-shaped body; the open list still carries GraphQL-only fields
  # (mergeStateStatus/mergeable/isInMergeQueue) and is unchanged.
  *"repos/example-org/b-os/pulls?state=closed"*)
    printf 'HTTP/2.0 200\r\n\r\n'
    cat <<'JR'
[{"number":2,"html_url":"https://github.com/example-org/b-os/pull/2","title":"TK-2","body":"","state":"closed","merged_at":null,"closed_at":"2026-09-15T01:00:00Z","created_at":"2026-09-14T00:00:00Z","updated_at":"2026-09-15T01:00:00Z","draft":false,"labels":[],"user":{"login":"operator","type":"User"},"head":{"ref":"ticket/TK-2","sha":"deadbe2"},"base":{"ref":"main"}}]
JR
    ;;
  *"actions/runs?head_sha=$H1"*) printf 'completed|success\n' ;;
  *"v3.diff"*) restpr --diff ;;
  # TEST-CHANGE (BH-1592): the closed-unmerged pass reads its candidates by
  # number instead of walking pulls?state=closed, so #2 is answered here.
  *"api -i -X GET repos/example-org/b-os/pulls/2") restpr CLOSED deadbe2 ticket/TK-2 main "" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
rm -rf "$T/h/state/merge-conductor" "$T/h/state/gh-budget"
mkdir -p "$T/h/state/merge-conductor" "$T/h/state/gh-budget" "$T/h/logs"
# TEST-CHANGE (BH-1592): #2 is a candidate of the closed pass because an earlier
# tick saw it open (its pr-state row), which is how the pass finds PRs now.
printf 'example-org/b-os#2\tWAIT_CI\t1\t-\t-\t-\t-\thttps://github.com/example-org/b-os/pull/2\n' > "$T/h/state/merge-conductor/pr-state.tsv"
: > "$T/gh-calls.txt"; : > "$T/gh-writes.txt"
run_tick env GH_BUDGET_TTL_S=0 GH_BUDGET_CORE_REMAINING=500 MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_REPOS="$T/repos" MC_RR_PATH="$T/fakebin:$PATH"
grep -q 'pr list -R example-org/b-os --state open' "$T/gh-calls.txt" && ok || bad "low budget: open PR list must still be requested"
# TEST-CHANGE (BH-1592): the closed pass's read is pulls/<n> now, not the raw list.
grep -q 'repos/example-org/b-os/pulls/2' "$T/gh-calls.txt" && bad "low budget: the closed pass must NOT read its candidate" || ok
[ -s "$T/gh-writes.txt" ] && bad "low budget observe-only tick wrote to gh: $(cat "$T/gh-writes.txt")" || ok
grep -q 'budget low — closed-list settle pass skipped this tick' "$T/h/logs/merge-conductor.log" && ok || bad "low budget must log that the closed-list pass was skipped"
[ "$(state_of 'example-org/b-os#1')" = READY ] && ok || bad "low budget: open PR must still be classified normally (got $(state_of 'example-org/b-os#1'))"
: > "$T/gh-calls.txt"; : > "$T/gh-writes.txt"
rm -rf "$T/h/state/gh-budget"
: > "$T/h/logs/merge-conductor.log"
run_tick env GH_BUDGET_TTL_S=0 GH_BUDGET_CORE_REMAINING=4500 MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_REPOS="$T/repos" MC_RR_PATH="$T/fakebin:$PATH"
grep -q 'pr list -R example-org/b-os --state open' "$T/gh-calls.txt" && ok || bad "healthy budget: open PR list must be requested"
# TEST-CHANGE (BH-1592): same claim, the pass's read is pulls/<n> now.
grep -q 'repos/example-org/b-os/pulls/2' "$T/gh-calls.txt" && ok || bad "healthy budget: the closed pass MUST read its candidate"
[ "$(state_of 'example-org/b-os#2')" = CLOSED ] && ok || bad "healthy budget: the closed-unmerged candidate must settle CLOSED (got $(state_of 'example-org/b-os#2'))"
grep -q 'budget low' "$T/h/logs/merge-conductor.log" && bad "healthy budget must not log a low-budget skip" || ok
[ "$(state_of 'example-org/b-os#1')" = READY ] && ok || bad "healthy budget: open PR must still be classified normally (got $(state_of 'example-org/b-os#1'))"


echo "mc/settle-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
