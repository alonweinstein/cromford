#!/bin/bash
# tests/mc/queue-test.sh — the merge-queue half of tests/merge-conductor-test.sh,
# split out of it verbatim by BH-684 when bin/lib/merge-conductor-lib.sh became a
# shim over bin/lib/mc/. Every case here exercises bin/lib/mc/queue.sh: the
# isInMergeQueue read (asked once, remembered, and read only where it can
# matter) and the main-red freeze that holds every merge on a red main.
#
# It drives the real bin/merge-conductor.sh against a stubbed gh, the same
# fixture the parent suite builds; the gh stub FAILS the run on a write verb the
# tick is not meant to make.
# Run from anywhere: tests/mc/queue-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
# BH-3223: scratch.sh blanks JOBS_URL; this suite's fake curl answers a worker URL.
export JOBS_URL=https://jobs.invalid
# BH-1939: the scratch tree below carries no lane registry, and mc/queue.sh and
# main-red-gate.sh no longer have literal defaults; these are the values a box
# resolves from catalog/lanes.d/_lib.mc-queue.json and _lib.main-red-gate.json.
export MC_QUEUE_TTL=300 MC_MAIN_RED_LABEL=fix-main-red MC_MAIN_RED_TEST_PATHS='tests/* worker/*/test/*'
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
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n'; exit 0 ;;  # BH-1668: the PR's own thread (no HOLD), read over REST by to_merge_hold
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
  # BH-1606: the seeded lead_pr_authors row. The conductor's lead fence fails
  # CLOSED on an unreadable row (#1603), so a fixture that 404s it merges nothing.
  "GET "*/api/settings/lead_pr_authors) printf '{"setting":{"key":"lead_pr_authors","value":"operator"}}\n200\n' ;;
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
# 8. isInMergeQueue: ASKED ONCE, REMEMBERED, AND READ ONLY WHERE IT CAN MATTER
#    (2026-09-15)
#
#    mergeStateStatus has no QUEUED value, so isInMergeQueue is the only witness
#    of GitHub's native queue — and this gh's --json allowlist refuses it in LIST
#    mode. The conductor asked anyway, on every repo, on every tick: 411 lines of
#    "gh refused --json isInMergeQueue — reading it per PR this tick" in 24
#    hours, a wasted list call behind each one, and then one API call per open PR
#    to learn `false` about a PR nothing was going to merge.
#
#    The refusal is a fact about gh, so it is REMEMBERED. What is driven here is
#    that the second tick asks nothing, says nothing, and still gets the answer
#    for the only PR whose state can mean "queued".
# ============================================================================
printf 'qproj example-org/q-os - - 2 box-q\n' > "$T/h/fleet.conf"
rm -f "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge" \
      "$T/h/flags/merge-conductor-observe" "$T/h/flags/automerge-disabled"
rm -rf "$T/h/state/merge-conductor"; mkdir -p "$T/h/state/merge-conductor" "$T/h/tmp"
echo github > "$T/h/tmp/merge-queue-example-org_q-os.provider"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n'; exit 0 ;;  # BH-1668: the PR's own thread (no HOLD), read over REST by to_merge_hold
  *"auth token"*) echo faketoken ;;
  # BH-1585 review Q2: \$T/mq-502 makes the mergeQueue read a TRANSPORT failure.
  # Otherwise the arm answers nothing and tests/lib/gh-list-bridge.sh builds the
  # answer from the 'pr list' arms (the refusal below is a GraphQL errors answer).
  *graphql*mergeQueue*) [ -f "$T/mq-502" ] && { printf 'HTTP/2.0 502\r\n\r\n{"message":"Server Error"}\n'; exit 1; }; echo "" ;;
  # THE REFUSAL, in gh's own shape: a nonzero exit and nothing on stdout.
  *"pr list"*isInMergeQueue*) echo 'gh: unknown JSON field: "isInMergeQueue"' >&2; exit 1 ;;
  *"pr list -R example-org/q-os --state open"*)
    cat <<J
[{"number":41,"url":"https://github.com/example-org/q-os/pull/41","headRefOid":"$H1","headRefName":"ticket/qp-41","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"main"},
 {"number":42,"url":"https://github.com/example-org/q-os/pull/42","headRefOid":"$H1","headRefName":"ticket/qp-42","isDraft":false,"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","state":"OPEN","labels":[],"baseRefName":"main"}]
J
    ;;
  *"pr list"*) echo "[]" ;;
  # THE PER-PR QUEUE READ IS REST NOW (BH-784). isInMergeQueue is GraphQL-only
  # and has no REST field, so mc_queue_state reads the pull object itself. The
  # claim under test is unchanged: the CLEAN PR's queue state is still asked for
  # per PR, and the DIRTY one -- which can never be in a queue -- still is not.
  *"api -i -X GET repos/example-org/q-os/pulls/41") printf '%s\n' "\$*" >> "$T/inq-reads.txt"; restpr OPEN "$H1" ticket/qp-41 main "" ;;
  *"api -i -X GET repos/example-org/q-os/pulls/42") printf '%s\n' "\$*" >> "$T/inq-reads.txt"; restpr OPEN "$H1" ticket/qp-42 main "" CONFLICTING DIRTY ;;
  *"actions/runs?head_sha="*) printf 'completed|success\n' ;;
  *"v3.diff"*) restpr --diff ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
: > "$T/gh-calls.txt"; : > "$T/inq-reads.txt"
run_tick env MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0
[ "$(grep -c 'gh refused --json isInMergeQueue' "$T/h/logs/merge-conductor.log")" = 1 ] \
  && ok || bad "the first tick must say ONCE that gh refused the field (got $(grep -c 'gh refused --json isInMergeQueue' "$T/h/logs/merge-conductor.log"))"
# ASSERTION CHANGED (BH-1585 review Q2): the memory is PER REPO now — one repo
# refusing the read must not switch the native-queue witness off for every repo.
[ -f "$T/h/state/merge-conductor/gh-no-inqueue-example-org_q-os" ] && [ ! -e "$T/h/state/merge-conductor/gh-no-inqueue" ] \
  && ok || bad "the refusal must be REMEMBERED, per repo, or every later tick rediscovers it"
[ "$(grep -c 'pr list.*isInMergeQueue' "$T/gh-calls.txt")" -ge 1 ] \
  && ok || bad "the first tick must actually have asked (this test would otherwise prove nothing)"
# BH-1585: on a native-queue repo that ask is EXACTLY ONE GraphQL read per tick
# (repository.mergeQueue), never one per author or per PR.
[ "$(grep -cE '(^| )graphql( |$)' "$T/gh-calls.txt")" = 1 ] \
  && ok || bad "a queue repo's tick must make exactly one GraphQL call (got $(grep -cE '(^| )graphql( |$)' "$T/gh-calls.txt"))"
grep -q 'pulls/41' "$T/inq-reads.txt" \
  && ok || bad "a CLEAN PR on a queue repo must still have its queue state read per PR (got: $(cat "$T/inq-reads.txt"))"
grep -q 'pulls/42' "$T/inq-reads.txt" \
  && bad "a DIRTY PR can never be in the merge queue — reading it is one API call per PR per tick for nothing" || ok
# The second tick is the one that mattered: 411 lines a day came from here.
LISTQ=$(grep -c 'pr list.*isInMergeQueue' "$T/gh-calls.txt")
run_tick env MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0
[ "$(grep -c 'gh refused --json isInMergeQueue' "$T/h/logs/merge-conductor.log")" = 1 ] \
  && ok || bad "a normal tick must log NO refusal line (got $(grep -c 'gh refused --json isInMergeQueue' "$T/h/logs/merge-conductor.log"))"
[ "$(grep -c 'pr list.*isInMergeQueue' "$T/gh-calls.txt")" = "$LISTQ" ] \
  && ok || bad "a normal tick must not ask for the field the marker says gh refuses"
grep -q 'pulls/41' "$T/inq-reads.txt" \
  && ok || bad "and it must still know whether the CLEAN PR is queued"
# The memory EXPIRES, so a gh that learns the field is picked up on its own.
: > "$T/gh-calls.txt"
run_tick env MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_INQUEUE_PROBE_TTL_SECS=0
[ "$(grep -c 'pr list.*isInMergeQueue' "$T/gh-calls.txt")" -ge 1 ] \
  && ok || bad "past MC_INQUEUE_PROBE_TTL_SECS the conductor must re-probe — a capability cache that never expires is wrong after the next npm i -g"
# And the operator can pin it off entirely.
: > "$T/gh-calls.txt"; rm -f "$T/h/state/merge-conductor/gh-no-inqueue-example-org_q-os"
run_tick env MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_LIST_INQUEUE=0
[ "$(grep -c 'pr list.*isInMergeQueue' "$T/gh-calls.txt")" = 0 ] \
  && ok || bad "MC_LIST_INQUEUE=0 must never ask for the field, marker or no marker"
# A repo with NO queue must never ask the question at all, in the list or per PR.
rm -f "$T/h/tmp/merge-queue-example-org_q-os.provider"
: > "$T/gh-calls.txt"; : > "$T/inq-reads.txt"
run_tick env MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0
[ "$(grep -c 'pr list.*isInMergeQueue' "$T/gh-calls.txt")" = 0 ] && [ ! -s "$T/inq-reads.txt" ] \
  && ok || bad "a repo with no merge queue must not be asked about the merge queue"
# BH-1585: and it makes no GraphQL call at all (the mergeQueue read is for
# native-queue repos only).
! grep -qE '(^| )graphql( |$)' "$T/gh-calls.txt" \
  && ok || bad "a no-queue repo's tick must make 0 GraphQL calls: $(grep -E '(^| )graphql( |$)' "$T/gh-calls.txt")"
# BH-1585 review Q2: a TRANSPORT failure of the mergeQueue read is not a
# refusal. It is never remembered (the witness is off for THIS tick only), the
# log says so in its own words, and the repo's list still reads.
echo github > "$T/h/tmp/merge-queue-example-org_q-os.provider"
rm -f "$T/h/state/merge-conductor"/gh-no-inqueue*; touch "$T/mq-502"
: > "$T/gh-calls.txt"; M=$(wc -l < "$T/h/logs/merge-conductor.log")
run_tick env MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0
rm -f "$T/mq-502"
grep -qE 'graphql.*mergeQueue|mergeQueue.*graphql' "$T/gh-calls.txt" \
  && ok || bad "the transport-failure tick must actually have asked (this case would otherwise prove nothing)"
ls "$T/h/state/merge-conductor"/gh-no-inqueue* >/dev/null 2>&1 \
  && bad "a transport failure must never be remembered as a refusal: $(ls "$T/h/state/merge-conductor"/gh-no-inqueue*)" || ok
tail -n +"$((M+1))" "$T/h/logs/merge-conductor.log" | grep -q 'mergeQueue read unverifiable' \
  && ok || bad "the tick must say the mergeQueue read was unverifiable, not that gh refused the field"
[ -n "$(state_of 'example-org/q-os#41')" ] && ok || bad "the repo's list must still read after a failed mergeQueue read"


# ============================================================================
# 9. THE MAIN-RED FREEZE (2026-09-15)
#
#    bin/main-red-detector.sh raises flags/main-red-<slug> when the repo's own
#    main is red. Merging into a red main is merging on a CI signal that is
#    worthless — and on a queue repo it ejects everything behind it too — so
#    while the flag is up this conductor merges NOTHING in that repo, with two
#    exceptions that are the way out of it: the PR carrying the fix label, and a
#    PR whose whole diff is test files.
# ============================================================================
printf 'fproj example-org/f-os - - 2 box-f\n' > "$T/h/fleet.conf"
rm -rf "$T/h/state/merge-conductor"; mkdir -p "$T/h/state/merge-conductor"
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
for N in 51 52 53; do
  D9="$T/h/builds/pool-fproj-FP-$N-20260915010$N"; mkdir -p "$D9"
  echo "PR_CREATED https://github.com/example-org/f-os/pull/$N" > "$D9/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$D9/review.md"
  echo "$H1" > "$D9/reviewed-sha"
done
# Each PR's file list is a FILE, so "GitHub would not tell us" is one `: >` away.
printf 'src/app.ts\ntests/app-test.sh\n' > "$T/files-51"
printf 'src/broken.ts\n' > "$T/files-52"
printf 'tests/rate-test.sh\nworker/jobs/src/test/rate.test.ts\n' > "$T/files-53"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
# The PR number now comes off either spelling: pull/<n> in a gh pr merge URL,
# pulls/<n> in a REST path (BH-784).
N=\$(sed -nE 's#.*/pulls?/([0-9]+).*#\1#p' <<<"\$*")
LBL9=""; [ "\$N" = 52 ] && LBL9=fix-main-red
case "\$*" in
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n'; exit 0 ;;  # BH-1668: the PR's own thread (no HOLD), read over REST by to_merge_hold
  *"auth token"*) echo faketoken ;;
  *"pr merge https://github.com/example-org/f-os/pull/"*)
    touch "$T/merged9-\$N"; printf '%s\n' "\$*" >> "$T/merges9.txt"; exit 0 ;;
  # The post-merge issue comment and close are REST now, and gh_rest_close only
  # answers success after a FRESH read says the issue really is closed.
  *"api -i -X POST repos/example-org/f-os/issues/"*"/comments"*) restpr --raw 201 '{"id":1}' ;;
  *"api -i -X PATCH repos/example-org/f-os/issues/"*) restpr --raw 200 '{"state":"closed"}' ;;
  *"api -i -X GET repos/example-org/f-os/issues/"*) restpr --raw 200 '{"state":"closed"}' ;;
  # BH-1526: the merge-time HOLD reads each ticket through bin/lib/hold.sh
  # (plain REST). Every f-os ticket is open, labelled and unheld, so the gate
  # answers "merge as today" and only the main-red freeze decides below.
  *"repos/example-org/f-os/issues/"*"/comments?per_page"*) echo '[]' ;;
  "api repos/example-org/f-os/issues/"*) echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"FP","body":"scope"}' ;;
  # The file list is a PAGINATED REST read, matched before the plain pull arm
  # because it shares the path. An empty fixture file is "GitHub would not tell
  # us", which must NOT read as tests-only.
  *"/pulls/"*"/files?per_page="*)
    restpr --raw 200 "\$(jq -R -s -c 'split("\n")|map(select(length>0))|map({filename:.})' < "$T/files-\$N" 2>/dev/null)" ;;
  *"v3.diff"*) restpr --diff ;;
  # state, headRefOid and mergeCommit are all one pull object now.
  *"api -i -X GET repos/example-org/f-os/pulls/"*)
    if [ -f "$T/merged9-\$N" ]; then restpr MERGED "$H1" "ticket/fp-\$N" main "\$LBL9" MERGEABLE CLEAN app/cromford cccccccc3333
    else restpr OPEN "$H1" "ticket/fp-\$N" main "\$LBL9" MERGEABLE CLEAN app/cromford ""; fi ;;
  *"pr list -R example-org/f-os --state open"*)
    cat <<J
[{"number":51,"url":"https://github.com/example-org/f-os/pull/51","headRefOid":"$H1","headRefName":"ticket/fp-51","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"main"},
 {"number":52,"url":"https://github.com/example-org/f-os/pull/52","headRefOid":"$H1","headRefName":"ticket/fp-52","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[{"name":"fix-main-red"}],"baseRefName":"main"},
 {"number":53,"url":"https://github.com/example-org/f-os/pull/53","headRefOid":"$H1","headRefName":"ticket/fp-53","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"main"}]
J
    ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) printf 'completed|success\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
rm -f "$T"/merged9-* ; : > "$T/merges9.txt"; : > "$T/gh-calls.txt"
printf 'sha=deadbeefdeadbeef workflow=CI since=2026-09-15T09:00:00Z\n' > "$T/h/flags/main-red-fproj"
run_tick env MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0
[ "$(grep -c 'MAIN_RED_FREEZE in force' "$T/h/logs/merge-conductor.log")" = 1 ] \
  && ok || bad "a frozen repo must log exactly ONE MAIN_RED_FREEZE line per tick (got $(grep -c 'MAIN_RED_FREEZE in force' "$T/h/logs/merge-conductor.log"))"
grep -q 'workflow=CI' "$T/h/logs/merge-conductor.log" \
  && ok || bad "the freeze line must carry what the detector wrote in the flag (the sha, the workflow, since when)"
grep -q 'pull/51' "$T/merges9.txt" && bad "an ordinary READY PR must not merge while main is red (got: $(cat "$T/merges9.txt"))" || ok
grep -q 'pull/52' "$T/merges9.txt" \
  && ok || bad "the PR labelled fix-main-red is the way OUT of a red main and must still merge (got: $(cat "$T/merges9.txt"))"
grep -q 'pull/53' "$T/merges9.txt" \
  && ok || bad "a PR whose whole diff is test files must still merge under the freeze (got: $(cat "$T/merges9.txt"))"
grep -q 'f-os#51 READY and HELD by the main-red freeze' "$T/h/logs/merge-conductor.log" \
  && ok || bad "the held PR must say what is holding it and that nothing about it needs doing"
[ "$(state_of 'example-org/f-os#51')" = READY ] \
  && ok || bad "a held PR stays READY — the freeze is not a park, it merges the moment the flag goes (got $(state_of 'example-org/f-os#51'))"
# The second tick: one more freeze line, and NOT one more held line.
run_tick env MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0
[ "$(grep -c 'MAIN_RED_FREEZE in force' "$T/h/logs/merge-conductor.log")" = 2 ] \
  && ok || bad "the freeze line is one PER TICK, so the operator can see it is still on"
[ "$(grep -c 'f-os#51 READY and HELD' "$T/h/logs/merge-conductor.log")" = 1 ] \
  && ok || bad "the per-PR held line must be one per (PR, head), not one every five minutes"
grep -q 'pull/51' "$T/merges9.txt" && bad "still frozen: PR 51 must still not merge" || ok
# And it RESUMES. Nothing else has to happen — no re-review, no rebase, no park.
rm -f "$T/h/flags/main-red-fproj"
run_tick env MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0
grep -q 'pull/51' "$T/merges9.txt" \
  && ok || bad "with the flag gone the held PR must merge on the very next tick (got: $(cat "$T/merges9.txt"))"
[ "$(grep -c 'MAIN_RED_FREEZE in force' "$T/h/logs/merge-conductor.log")" = 2 ] \
  && ok || bad "an unfrozen repo must stop logging the freeze"
# A diff GitHub will not give us is NOT exempt: fail closed.
printf 'sha=deadbeefdeadbeef workflow=CI since=2026-09-15T09:00:00Z\n' > "$T/h/flags/main-red-fproj"
rm -rf "$T/h/state/merge-conductor/pr-files"; rm -f "$T"/merged9-*; : > "$T/merges9.txt"
: > "$T/files-53"
run_tick env MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0
grep -q 'pull/53' "$T/merges9.txt" \
  && bad "a PR whose file list GitHub would not give us must not be treated as tests-only — that is a merge into a red main on a guess" || ok
rm -f "$T/h/flags/main-red-fproj"


echo "mc/queue-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
