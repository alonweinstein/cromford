#!/bin/bash
# tests/mc/rebase-test.sh — the rebase/re-review half of
# tests/merge-conductor-test.sh, split out of it verbatim by BH-684 when
# bin/lib/merge-conductor-lib.sh became a shim over bin/lib/mc/. Every case here
# exercises bin/lib/mc/rebase.sh: the detached re-review and rebase lanes, the
# provenance hold that is a review request, stacked children and their retarget,
# the restack, and the one CI kick a head with no workflow run gets.
#
# It drives the real bin/merge-conductor.sh against a stubbed gh, the same
# fixture the parent suite builds, because these claims are about what the TICK
# does — spawns a lane, reads its result on a later tick, never runs one inline.
# The gh stub FAILS the run on any write verb it is not meant to make.
#
# THE FD DISCIPLINE. bin/lib/mc/rebase.sh spawns its lanes with `9>&- 8>&- 7>&-`
# because a lane started while the parent holds the PR lock would inherit that
# fd and keep the lock alive after the parent exits. Section 4's PR-lock shard
# below exercises the other half of that rule — a PR whose lock IS held is
# skipped by name, and the rest of its project still ticks, with a holder that
# keeps one pid and the fd itself so an orphan cannot hold the lock instead. The
# "the lane does not inherit fd 9" probe proper lives in
# tests/conductor-detached-lanes-test.sh section 1, which is where it has always
# been; BH-684 is the PR that made it deterministic (it names the stub PATH so
# the lane really sleeps instead of racing a network-less `gh pr diff`).
# Run from anywhere: tests/mc/rebase-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
. "$(dirname "$0")/../lib/wait-for.sh" || exit 1  # BH-6049: wait_holder, not a fixed sleep
# BH-3223: scratch.sh blanks JOBS_URL; this suite's fake curl answers a worker URL.
export JOBS_URL=https://jobs.invalid
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
  *"actions/runs?head_sha=$H1"*) restpr --runs 'completed|success' 'completed|success' ;;
  *"actions/runs?head_sha=$H2"*) restpr --runs 'in_progress|' ;;
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
# 4. Detached re-reviews and the patch-id approval rebind (2026-09-14)
#
# The tick must never RUN a re-review again: it spawns one and reads the result
# on a later tick. And a head that moved because of a rebase — same patch-id —
# must rebind the approval and merge without buying any review at all. Both are
# driven here end to end: the agent-call stub SLEEPS, so a tick that still ran
# the review inline would take half a minute and fail the elapsed assertion.
# ============================================================================
RRDIR="$T/h/state/merge-conductor/rereview"
H4=dddddddd4444; H5=eeeeeeee5555
# git, stubbed the same way gh is: patch-id is md5 of whatever `git diff`
# printed for that sha, so "same patch" and "different patch" are one file each.
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
A="\$*"
case "\$A" in
  *ls-remote*|*"remote set-url"*|*clone*) exit 0 ;;
  *fetch*)    exit 0 ;;
  *merge-base*) echo base0000base0000; exit 0 ;;
  *patch-id*) md5sum | cut -d' ' -f1; exit 0 ;;
  *" diff "*) SHA="\${A##* }"; cat "$T/patch.\$SHA" 2>/dev/null || printf 'diff-%s\n' "\$SHA"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/git"
# gh for this section: PR 12 on demo-os at whatever head the case sets, green
# CI on every head, and a merge that only lands with --match-head-commit.
mk_gh() { # mk_gh <head-of-12>
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
  *"auth token"*) echo faketoken ;;
  *"pr merge https://github.com/example-org/demo-os/pull/12 --squash --match-head-commit $1"*) touch "$T/merged12"; exit 0 ;;
  *"pr merge"*) echo "wrong merge form: \$*" >> "$T/gh-writes.txt"; exit 1 ;;
  # The comment is a REST POST whose BODY goes by file, never on argv (BH-784),
  # so what lands in comments.txt is the endpoint, not the text.
  *"api -i -X POST repos/example-org/demo-os/issues/12/comments"*) printf '%s\n' "\$*" >> "$T/comments.txt"; restpr --raw 201 '{"id":1}' ;;
  # …and state, headRefOid, mergeCommit and body are all one pull object now.
  *"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/12")
    if [ -f "$T/merged12" ]; then restpr MERGED "$1" ticket/TK-12 main "" MERGEABLE CLEAN app/cromford ccccmergecommit "plain body"
    else restpr OPEN "$1" ticket/TK-12 main "" MERGEABLE CLEAN app/cromford "" "plain body"; fi ;;
  *"pr list -R example-org/demo-os --state open"*)
    cat <<'J'
[{"number":12,"url":"https://github.com/example-org/demo-os/pull/12","headRefOid":"$1","headRefName":"ticket/TK-12","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"}]
J
    ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha=$1"*) restpr --runs '${2:-completed|success}' ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
  chmod +x "$T/fakebin/gh"
}
REC12="$T/h/builds/pool-demo-os-TK-12-202609120002"
tick4() { run_tick env MC_MERGE_SETTLE=0 MC_REPOS="$T/repos" MC_RR_PATH="$T/fakebin:$PATH"; }
reset12() { echo "$H1" > "$REC12/reviewed-sha"; rm -f "$T/merged12" "$T/gh-writes.txt" "$REC12"/patch-id.* "$REC12/rebind.log"
            awk -F'\t' '$1!="example-org/demo-os#12"' "$T/h/state/merge-conductor/pr-state.tsv" > "$T/rows.tmp" 2>/dev/null
            mv -f "$T/rows.tmp" "$T/h/state/merge-conductor/pr-state.tsv"
            grep -v 'example-org/demo-os#12' "$T/h/state/merge-conductor/attempts.txt" > "$T/att.tmp" 2>/dev/null
            mv -f "$T/att.tmp" "$T/h/state/merge-conductor/attempts.txt"; }
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
rm -f "$T/h/flags/automerge-disabled" "$T/h/flags/merge-conductor-observe"

# 4a. the head moved and the PATCH DID NOT: rebind, merge, no review bought
printf 'the same patch\n' > "$T/patch.$H1"; printf 'the same patch\n' > "$T/patch.$H2"
reset12; mk_gh "$H2"; tick4
grep -q "demo-os#12 REBOUND ${H1:0:8} -> ${H2:0:8}" "$T/h/logs/merge-conductor.log" && ok || bad "an identical patch-id on a moved head must log REBOUND"
grep -q "approval rebound $H1 -> $H2 patch-id .* unchanged (rebase only, no content change)" "$REC12/rebind.log" 2>/dev/null && ok || bad "the rebind must be written to the build record's rebind.log"
[ -s "$REC12/patch-id.$H2" ] && ok || bad "the rebound head's patch-id must be stored beside the record"
[ "$(head -1 "$REC12/reviewed-sha")" = "$H2" ] && ok || bad "a rebind must move reviewed-sha onto the new head"
[ -f "$T/merged12" ] && ok || bad "a rebound PR must merge, head-bound to the NEW sha"
[ -z "$(ls "$RRDIR"/*.json 2>/dev/null)" ] && ok || bad "a rebind must spawn NO re-review job (got $(ls "$RRDIR"))"
[ -s "$T/comments.txt" ] && bad "a rebind must post no re-review comment" || ok

# 4b. the patch CHANGED: a detached job is spawned and the tick does not wait.
# The agent-call stub sleeps 25s; an inline re-review would take that long.
printf '#!/bin/bash\nsleep 25; printf "VERDICT: APPROVE\\n" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"
printf 'a different patch entirely\n' > "$T/patch.$H2"
reset12; mk_gh "$H2"; rm -f "$T/h/state/merge-conductor/rereview"/*.json
T0=$(date -u +%s); tick4; T1=$(date -u +%s)
JF2="$(mc_rr_file example-org/demo-os 12 $H2)"
[ $((T1-T0)) -lt 15 ] && ok || bad "the tick must not wait for the re-review (took $((T1-T0))s)"
[ -f "$JF2" ] && ok || bad "a moved head with a different patch-id must spawn a detached re-review job"
[ "$(mc_rr_state "$JF2")" = running ] && ok || bad "the spawned job must be running while the tick is already done (got $(mc_rr_state "$JF2"))"
grep -q 'demo-os#12 REREVIEW_SPAWNED' "$T/h/logs/merge-conductor.log" && ok || bad "the spawn must be logged as REREVIEW_SPAWNED"
[ -f "$T/merged12" ] && bad "a PR whose head is being re-reviewed must not merge" || ok
[ "$(state_of 'example-org/demo-os#12')" = HEAD_MOVED ] && ok || bad "a PR with a running re-review stays HEAD_MOVED (got $(state_of 'example-org/demo-os#12'))"
# a second tick over the same head reads the job and moves on, still not waiting
T0=$(date -u +%s); tick4; T1=$(date -u +%s)
[ $((T1-T0)) -lt 15 ] && ok || bad "a tick over a RUNNING job must not wait either (took $((T1-T0))s)"
grep -q "demo-os#12 REREVIEWING ${H2:0:8}" "$T/h/logs/merge-conductor.log" && ok || bad "a running job must log REREVIEWING"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"

# 4c. a FINISHED job with verdict APPROVE is consumed on the next tick
printf 'yet another patch\n' > "$T/patch.$H3"
reset12; mk_gh "$H3"; : > "$T/comments.txt"
JF3="$(mc_rr_file example-org/demo-os 12 $H3)"
printf 'findings\nVERDICT: APPROVE\n' > "$RRDIR/consumed.out"
mc_rr_write "$JF3" done 0 "$(date -u +%s)" "$(date -u +%s)" APPROVE "$H3" "$H1" "$RRDIR/consumed.out"
tick4
grep -q "demo-os#12 head-bound re-review APPROVED ${H3:0:8}" "$T/h/logs/merge-conductor.log" && ok || bad "a done job with APPROVE must be consumed"
[ "$(head -1 "$REC12/reviewed-sha")" = "$H3" ] && ok || bad "consuming an APPROVE must rebind reviewed-sha to the reviewed head"
[ "$(state_of 'example-org/demo-os#12')" = WAIT_REVIEW ] && ok || bad "after a consumed APPROVE the row is WAIT_REVIEW (got $(state_of 'example-org/demo-os#12'))"
grep -q 'api -i -X POST repos/example-org/demo-os/issues/12/comments' "$T/comments.txt" && ok || bad "a consumed APPROVE must post the re-review comment on the PR"
CN=$(grep -c 'issues/12/comments' "$T/comments.txt"); tick4
[ "$(grep -c 'issues/12/comments' "$T/comments.txt")" = "$CN" ] && ok || bad "a consumed verdict must never be consumed twice"

# 4d. a job past MC_REREVIEW_TIMEOUT_SECS is a LANE failure: retried ONCE, and
#     only the SECOND dead job takes the no-verdict park (2026-09-16, lever 2).
#     Nobody answering says something about the reviewer and nothing about the
#     diff, and both moves here are EVENTS (a dead job, then a second one) —
#     there is no clock in this path that can park or close a PR.
LOGN=0
logmark()  { LOGN=$(wc -l < "$T/h/logs/merge-conductor.log" 2>/dev/null || echo 0); }
logsince() { tail -n +$((LOGN+1)) "$T/h/logs/merge-conductor.log" 2>/dev/null; }
ATT="$T/h/state/merge-conductor/attempts.txt"
printf 'a fourth patch\n' > "$T/patch.$H4"
reset12; mk_gh "$H4"
JF4="$(mc_rr_file example-org/demo-os 12 $H4)"
mc_rr_write "$JF4" running "$$" "$(( $(date -u +%s) - 4000 ))" 0 - "$H4" "$H1" "$RRDIR/none.out"
[ "$(mc_rr_state "$JF4")" = stale ] && ok || bad "a job older than MC_REREVIEW_TIMEOUT_SECS must read as stale even with a live pid"
logmark; tick4
[ -f "$JF4" ] && bad "the first dead job must be FORGOTTEN so the next tick can buy one more read" || ok
[ "$(state_of 'example-org/demo-os#12')" = HEAD_MOVED ] && ok || bad "a lane failure must leave the PR waiting for the retry, not parked (got $(state_of 'example-org/demo-os#12'))"
logsince | grep -q 'demo-os#12 head-bound re-review LANE FAILED' && ok || bad "the lane failure must be logged as what it is"
grep -q 'demo-os#12 BLOCKED_AGENT no-verdict' <<<"$(logsince)" && bad "the FIRST dead job must not park the PR" || ok
grep -qxF "rereviewretry example-org/demo-os#12 $H4" "$ATT" && ok || bad "the one retry must be recorded per (PR, head), so it is exactly one"
# the SECOND dead job on the same head: today's no-verdict park, unchanged
mc_rr_write "$JF4" running "$$" "$(( $(date -u +%s) - 4000 ))" 0 - "$H4" "$H1" "$RRDIR/none.out"
logmark; tick4
[ "$(jq -r .status "$JF4")" = failed ] && ok || bad "a timed-out job must be marked failed (got $(jq -r .status "$JF4"))"
[ "$(state_of 'example-org/demo-os#12')" = BLOCKED_HUMAN ] && ok || bad "a SECOND timed-out re-review must take the no-verdict path (got $(state_of 'example-org/demo-os#12'))"
logsince | grep -q 'demo-os#12 BLOCKED_AGENT no-verdict' && ok || bad "the no-verdict park must name the resolver"
# MC_REREVIEW_ON_MOVE=0 is the way back: the first dead job parks on the spot
reset12; mk_gh "$H4"; rm -f "$JF4"
mc_rr_write "$JF4" running "$$" "$(( $(date -u +%s) - 4000 ))" 0 - "$H4" "$H1" "$RRDIR/none.out"
grep -v 'rereviewretry example-org/demo-os#12' "$ATT" > "$T/att.k" 2>/dev/null; mv -f "$T/att.k" "$ATT"
logmark; run_tick env MC_MERGE_SETTLE=0 MC_REPOS="$T/repos" MC_RR_PATH="$T/fakebin:$PATH" MC_REREVIEW_ON_MOVE=0
[ "$(state_of 'example-org/demo-os#12')" = BLOCKED_HUMAN ] && ok || bad "with the knob off, one dead job parks no-verdict exactly as before (got $(state_of 'example-org/demo-os#12'))"
grep -q 'demo-os#12 head-bound re-review LANE FAILED' <<<"$(logsince)" && bad "MC_REREVIEW_ON_MOVE=0 must buy no retry at all" || ok

# 4d-bis. THE TWO LANE-FAILURE ARMS ARE DIFFERENT ARMS, and this pins the seam
#     the #502/#525 merge had to resolve. #525 gives a job that NEVER CAME BACK
#     (failed/stale) exactly one retry, recorded as `rereviewretry`. #502 gives a
#     job that DID come back carrying our own outage (status `lane-failed` —
#     a 429 on the claude account, a ladder that could not carry the prompt) its
#     own bounded re-read, recorded as `lanefail`. Both are events, neither is a
#     clock, and neither may spend the other's budget: a review lane that 429s
#     must not eat the one retry a dead job is owed, and a dead job must not be
#     reported as a lane outage. The assertions below fail in BOTH directions if
#     either arm is lost or the two are collapsed back into one.
reset12; mk_gh "$H4"; rm -f "$JF4" "$RRDIR/none.out.lanefail"
mc_rr_write "$JF4" lane-failed "$$" "$(date -u +%s)" "$(date -u +%s)" - "$H4" "$H1" "$RRDIR/none.out" "the claude account answered 429"
[ "$(mc_rr_state "$JF4")" = lanefail ] && ok || bad "a job the lane died under must read as lanefail, not failed (got $(mc_rr_state "$JF4"))"
logmark; tick4
[ -f "$JF4" ] && bad "a lane-failed job must be forgotten so the next tick buys another read" || ok
[ "$(state_of 'example-org/demo-os#12')" = HEAD_MOVED ] && ok || bad "our own outage must leave the PR waiting for another read, not parked (got $(state_of 'example-org/demo-os#12'))"
logsince | grep -q "demo-os#12 re-review LANE FAILED on ${H4:0:8} (read 1 of 5 in lane epoch" && ok || bad "the lanefail arm must name which read of the cap this was, and under which lane-health epoch (BH-1019)"
logsince | grep -q 'the claude account answered 429' && ok || bad "the lane's own reason must be quoted, not swallowed"
grep -q 'demo-os#12 BLOCKED_AGENT' <<<"$(logsince)" && bad "a lane outage must not park the PR while reads are left" || ok
grep -qE "^lanefail example-org/demo-os#12 $H4 [0-9]+\$" "$ATT" && ok || bad "the read must be counted per (PR, head, lane-health epoch) — BH-1019 added the epoch so a cap cannot be spent five times against one outage"
grep -qxF "rereviewretry example-org/demo-os#12 $H4" "$ATT" && bad "a lane outage must NOT spend the one retry #525 keeps for a job that never came back" || ok
# ...so the SAME head, when a job later dies without answering at all, still has
# its #525 retry: the two budgets are independent.
mc_rr_write "$JF4" running "$$" "$(( $(date -u +%s) - 4000 ))" 0 - "$H4" "$H1" "$RRDIR/none.out"
logmark; tick4
[ "$(state_of 'example-org/demo-os#12')" = HEAD_MOVED ] && ok || bad "the dead job after a lane outage must still get its one retry (got $(state_of 'example-org/demo-os#12'))"
logsince | grep -q 'demo-os#12 head-bound re-review LANE FAILED' && ok || bad "#525's retry must survive the merge with #502's lanefail arm"
grep -qxF "rereviewretry example-org/demo-os#12 $H4" "$ATT" && ok || bad "the retry of a job that never came back is still recorded as rereviewretry"
# OUT OF READS is a park and an ALERT, and still never a close: MC_RR_LANEFAIL_MAX=1
# with one lanefail already on this head is the last read.
rm -f "$JF4"
mc_rr_write "$JF4" lane-failed "$$" "$(date -u +%s)" "$(date -u +%s)" - "$H4" "$H1" "$RRDIR/none.out" "the survival ladder could not carry a review-sized prompt"
logmark; run_tick env MC_MERGE_SETTLE=0 MC_REPOS="$T/repos" MC_RR_PATH="$T/fakebin:$PATH" MC_RR_LANEFAIL_MAX=1
[ "$(state_of 'example-org/demo-os#12')" = BLOCKED_HUMAN ] && ok || bad "out of reads, the PR parks (got $(state_of 'example-org/demo-os#12'))"
logsince | grep -q 'demo-os#12 BLOCKED_AGENT no-verdict: the review lane failed' && ok || bad "the park must be no-verdict, which the resolver owns and which never closes a PR"
grep -q 'the review lane has failed 1 times' "$T/h/logs/ALERTS.log" && ok || bad "a stopped review lane must be ONE actionable ALERTS line, not a whisper in the run log"
grep -q 'survival ladder could not carry' "$T/h/logs/ALERTS.log" && ok || bad "the alert must name what is down"
[ -f "$T/merged12" ] && bad "nothing here may merge a PR no Claude read has approved" || ok
reset12; rm -f "$JF4"

# 4e. MC_REREVIEW_DAILY_CAP unset = no cap: the 7th re-review of the day spawns
printf 'a fifth patch\n' > "$T/patch.$H5"
reset12; mk_gh "$H5"
CAP="$T/h/state/merge-conductor/rereviews-$(date -u +%Y%m%d).txt"
for i in 1 2 3 4 5 6; do echo "demo-os example-org/demo-os#$i sha$i" >> "$CAP"; done
tick4
JF5="$(mc_rr_file example-org/demo-os 12 $H5)"
[ -f "$JF5" ] && ok || bad "with no MC_REREVIEW_DAILY_CAP set, the 7th re-review of the day must still be spawned"
grep -q 'hit the operator-set daily cap' "$T/h/logs/merge-conductor.log" && bad "the daily cap must not fire when it is unset" || ok
# an operator who SETS the cap still gets it
reset12; mk_gh "$H5"; rm -f "$JF5"
run_tick env MC_MERGE_SETTLE=0 MC_REPOS="$T/repos" MC_RR_PATH="$T/fakebin:$PATH" MC_REREVIEW_DAILY_CAP=6
[ -f "$JF5" ] && bad "MC_REREVIEW_DAILY_CAP=6 must still hold the 7th re-review back" || ok
grep -q 'demo-os hit the operator-set daily cap (6)' "$T/h/logs/merge-conductor.log" && ok || bad "an operator-set cap must say so in the log"

# 4g. NO VERDICT BOUND TO THE HEAD (2026-09-14, project-5 #586/#611), driven end
# to end: the record has no review.md and no reviewed-sha, so nothing has ever
# adjudicated this head. It used to classify WAIT_REVIEW and stop there — nothing
# reviews a WAIT_REVIEW row — and #586/#611 sat in it for days. It must now buy
# the same detached head-bound review the moved-head path buys.
H6=ffffffff6666
printf 'a sixth patch\n' > "$T/patch.$H6"
reset12; mk_gh "$H6"; : > "$T/comments.txt"
mv "$REC12/review.md" "$T/review12.md"; rm -f "$REC12/reviewed-sha"
tick4
JF6="$(mc_rr_file example-org/demo-os 12 $H6)"
[ -f "$JF6" ] && ok || bad "a head with NO verdict bound to it must spawn the detached head-bound review"
[ "$(mc_rr_field "$JF6" reviewed_sha)" = "-" ] && ok || bad "the spawned job must carry the absent reviewed sha as - (got $(mc_rr_field "$JF6" reviewed_sha))"
[ "$(state_of 'example-org/demo-os#12')" = HEAD_MOVED ] && ok || bad "a no-verdict head must leave WAIT_REVIEW for HEAD_MOVED (got $(state_of 'example-org/demo-os#12'))"
[ -f "$T/merged12" ] && bad "a PR with no verdict must never merge" || ok

# 4h. the CI-green debounce still holds: a no-verdict head whose checks are
# pending buys nothing, the same way a moved head does not.
H7=999999997777
printf 'a seventh patch\n' > "$T/patch.$H7"
reset12; mk_gh "$H7" 'in_progress|'; rm -f "$REC12/reviewed-sha"
tick4
JF7="$(mc_rr_file example-org/demo-os 12 $H7)"
[ -f "$JF7" ] && bad "a no-verdict head whose CI is still running must NOT buy a review" || ok
grep -q "demo-os#12 re-review deferred — CI pending" "$T/h/logs/merge-conductor.log" && ok || bad "the CI-green debounce must say so in the log"
mv "$T/review12.md" "$REC12/review.md"

# 4f. THE LOCK SHARD: a held lock skips THAT PR, and nothing else (2026-09-15)
#
# What this replaces: the tick took ONE flock per project and skipped the whole
# project when it was held, which cost 102 project-ticks in the two hours of
# 2026-09-15 21:00-23:00Z (cromford 30, project-5 21, project-7 15, ...).
# A lock held on PR 31 must now cost PR 31 its tick and cost PR 32 and the
# other project nothing. flock is real in this file — the shard IS the subject.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
case "\$*" in
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n'; exit 0 ;;  # BH-1668: the PR's own thread (no HOLD), read over REST by to_merge_hold
  *"auth token"*) echo faketoken ;;
  *"pr list -R example-org/demo-os --state open"*)
    cat <<'J'
[{"number":31,"url":"https://github.com/example-org/demo-os/pull/31","headRefOid":"$H1","headRefName":"ticket/TK-31","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"},
 {"number":32,"url":"https://github.com/example-org/demo-os/pull/32","headRefOid":"$H2","headRefName":"ticket/TK-32","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"}]
J
    ;;
  *"pr list -R example-org/issuer --state open"*)
    cat <<'J'
[{"number":21,"url":"https://github.com/example-org/issuer/pull/21","headRefOid":"$H1","headRefName":"ticket/is-21","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"}]
J
    ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"v3.diff"*) restpr --diff ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
# The holder keeps ONE pid and holds the fd itself: `flock -x <file> sleep 12 &`
# forks, so killing $! kills flock and leaves an orphaned sleep holding the
# inherited lock — the same fd-inheritance trap the lanes close with 9>&-.
( exec 9>"$T/h/locks/merge-conductor-demo-os-31.lock"; flock -w 5 9 || exit 1; exec sleep 12 ) >/dev/null 2>&1 &
HOLDER=$!
wait_holder "$HOLDER"
tick4
grep -q "demo-os#31: an earlier conductor worker still holds this PR's lock" "$T/h/logs/merge-conductor.log" \
  && ok || bad "a held PR lock must skip that PR and say so"
[ -z "$(state_of 'example-org/demo-os#31')" ] && ok || bad "the locked PR must not be ticked (got $(state_of 'example-org/demo-os#31'))"
[ -n "$(state_of 'example-org/demo-os#32')" ] \
  && ok || bad "a lock on ONE PR must not skip the rest of its project: demo-os#32 got no row"
[ -n "$(state_of 'example-org/issuer#21')" ] && ok || bad "a lock on one project must not stop another: issuer#21 got no row"
grep -q "demo-os: an earlier conductor tick still holds this project's lock" "$T/h/logs/merge-conductor.log" \
  && bad "the whole-project skip must be gone" || ok
# The metrics line the shard exists to make readable: two PRs seen, one skipped.
grep -qE "TICK demo-os tick=[^ ]+ secs=[0-9]+ prs=2 locked=1 " "$T/h/logs/merge-conductor.log" \
  && ok || bad "the tick must log one metrics line saying prs=2 locked=1 (got: $(grep -o 'TICK demo-os .*' "$T/h/logs/merge-conductor.log" | tail -1))"
[ "$(jq -r '.prs_seen,.prs_locked,.project' "$T/h/state/merge-conductor/tick-demo-os.json" | tr '\n' ' ')" = "2 1 demo-os " ] \
  && ok || bad "tick-<project>.json must carry the same numbers (got $(cat "$T/h/state/merge-conductor/tick-demo-os.json"))"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
# MC_PR_PARALLEL caps the workers without losing one: the same two PRs, one at a
# time, still both end the tick with a row.
awk -F'\t' '$1!="example-org/demo-os#31" && $1!="example-org/demo-os#32"' "$T/h/state/merge-conductor/pr-state.tsv" > "$T/rows.tmp"
mv -f "$T/rows.tmp" "$T/h/state/merge-conductor/pr-state.tsv"
run_tick env MC_MERGE_SETTLE=0 MC_REPOS="$T/repos" MC_RR_PATH="$T/fakebin:$PATH" MC_PR_PARALLEL=1
[ -n "$(state_of 'example-org/demo-os#31')" ] && [ -n "$(state_of 'example-org/demo-os#32')" ] \
  && ok || bad "MC_PR_PARALLEL=1 must still tick every PR, one at a time (31=$(state_of 'example-org/demo-os#31') 32=$(state_of 'example-org/demo-os#32'))"
grep -qE "TICK demo-os tick=[^ ]+ secs=[0-9]+ prs=2 locked=0 " "$T/h/logs/merge-conductor.log" \
  && ok || bad "with no lock held the metrics line must say locked=0 (got: $(grep -o 'TICK demo-os .*' "$T/h/logs/merge-conductor.log" | tail -1))"
# AND THE POINT OF THE WHOLE CHANGE: the two PRs are in the tick AT THE SAME
# TIME. Two FRESH PRs (33, 34 — no rows, no parks, so both reach the classifier)
# whose CI read announces itself and then waits for the other one to arrive. Two
# workers meet in milliseconds; a tick that walked its PR list one at a time
# cannot — the first waits out the timeout and writes the word this fails on.
# Nothing here is a sleep-and-hope: the passing path never waits.
#
# `\$1` is escaped on purpose, in the code AND in this comment: the heredoc
# EXPANDS, comments included, and an unescaped positional under this file's
# `set -u` aborts the write and leaves a 0-byte gh stub that answers every
# question with silence.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
case "\$*" in
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n'; exit 0 ;;  # BH-1668: the PR's own thread (no HOLD), read over REST by to_merge_hold
  *"auth token"*) echo faketoken ;;
  *"pr list -R example-org/demo-os --state open"*)
    cat <<'J'
[{"number":33,"url":"https://github.com/example-org/demo-os/pull/33","headRefOid":"$H1","headRefName":"ticket/TK-33","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"},
 {"number":34,"url":"https://github.com/example-org/demo-os/pull/34","headRefOid":"$H2","headRefName":"ticket/TK-34","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"}]
J
    ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha=$H1"*)
    touch "$T/at33"
    timeout 10 bash -c 'until [ -f "\$1" ]; do sleep 0.1; done' _ "$T/at34" || echo serial-33 >> "$T/serial.txt"
    restpr --runs 'completed|success' ;;
  *"actions/runs?head_sha=$H2"*)
    touch "$T/at34"
    timeout 10 bash -c 'until [ -f "\$1" ]; do sleep 0.1; done' _ "$T/at33" || echo serial-34 >> "$T/serial.txt"
    restpr --runs 'completed|success' ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"v3.diff"*) restpr --diff ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
: > "$T/serial.txt"; rm -f "$T/at33" "$T/at34"
run_tick env MC_MERGE_SETTLE=0 MC_REPOS="$T/repos" MC_RR_PATH="$T/fakebin:$PATH"
[ -f "$T/at33" ] && [ -f "$T/at34" ] && ok || bad "both PR workers must have reached the rendezvous (33=$([ -f "$T/at33" ] && echo y || echo n) 34=$([ -f "$T/at34" ] && echo y || echo n))"
[ ! -s "$T/serial.txt" ] \
  && ok || bad "two PRs of one project must tick CONCURRENTLY — one waited the other out ($(cat "$T/serial.txt"))"
grep -qE "TICK demo-os tick=[^ ]+ secs=[0-9]+ prs=2 locked=0 " "$T/h/logs/merge-conductor.log" \
  && ok || bad "the concurrent tick must still log its metrics line (got: $(grep -o 'TICK demo-os .*' "$T/h/logs/merge-conductor.log" | tail -1))"


# ============================================================================
# 4i. A PROVENANCE HOLD IS A REVIEW REQUEST, NOT A PARK (project-5 #864, 2026-09-14)
#
#   20:25:41Z #864 HEAD_MOVED -> BLOCKED_HUMAN … reason=provenance
#   20:34:21Z #864 detached re-review finished: APPROVE on 71d1e161
#   20:45Z    merged by the orchestrator, by hand.
# The APPROVE was about the head that was sitting there and nothing read it: the
# done-job handling lived only in the HEAD_MOVED arm and the row was not in
# HEAD_MOVED. #867 was the same; #865 and #866 were still parked. Three cases:
# the hold BUYS the read, a returning APPROVE clears the hold for that head, and
# a returning BLOCK parks it on a reason the resolver owns instead.
# ============================================================================
reason_of() { awk -F'\t' -v k="$1" '$1==k {print $7}' "$T/h/state/merge-conductor/pr-state.tsv"; }
HP1=aaaa1111prov; HP2=bbbb2222prov; HP3=cccc3333prov
for P8 in $HP1 $HP2 $HP3; do printf 'a provenance patch %s\n' "$P8" > "$T/patch.$P8"; done
# The record: APPROVE, bound to the head, and a review the SURVIVAL lane served.
# That last line is what mc_verdict reads as provenance=fallback.
prov_rec() { printf 'judge provenance: review served by the survival lane\n' > "$REC12/pipeline.log"; echo "$1" > "$REC12/reviewed-sha"; }

# 4i-1. no job yet, CI green: the hold BUYS the claude read that answers it
reset12; mk_gh "$HP1"; prov_rec "$HP1"; rm -f "$RRDIR"/*.json; : > "$T/comments.txt"
tick4
JP1="$(mc_rr_file example-org/demo-os 12 $HP1)"
[ "$(state_of 'example-org/demo-os#12')" = BLOCKED_HUMAN ] && ok || bad "a non-claude provenance must still park the row (got $(state_of 'example-org/demo-os#12'))"
[ "$(reason_of 'example-org/demo-os#12')" = provenance ] && ok || bad "the park reason must be provenance (got $(reason_of 'example-org/demo-os#12'))"
[ -f "$JP1" ] && ok || bad "a provenance hold whose CI is green must BUY the head-bound claude review, not sit there for ever"
grep -q 'demo-os#12 provenance hold: the fix for a non-claude review' "$T/h/logs/merge-conductor.log" && ok || bad "the tick must say WHY it bought a review on a provenance hold"
[ -f "$T/merged12" ] && bad "a PR on a provenance hold must not merge before the read comes back" || ok

# 4i-2. the read comes back APPROVE on THIS head: the hold is over for it
reset12; mk_gh "$HP2"; prov_rec "$HP2"; rm -f "$RRDIR"/*.json; : > "$T/comments.txt"
JP2="$(mc_rr_file example-org/demo-os 12 $HP2)"
printf 'findings\nVERDICT: APPROVE\n' > "$RRDIR/prov-approve.out"
mc_rr_write "$JP2" done 0 "$(date -u +%s)" "$(date -u +%s)" APPROVE "$HP2" "$HP2" "$RRDIR/prov-approve.out"
tick4
grep -q 'demo-os#12 re-review APPROVE consumed on a provenance hold' "$T/h/logs/merge-conductor.log" && ok || bad "a finished APPROVE bound to the head must be CONSUMED on a provenance hold — this is the #864 line that was never written"
grep -qxF "provcleared example-org/demo-os#12 $HP2" "$T/h/state/merge-conductor/attempts.txt" && ok || bad "the clearance must be recorded per (PR, head)"
grep -q 'api -i -X POST repos/example-org/demo-os/issues/12/comments' "$T/comments.txt" && ok || bad "the consumed re-review must be posted on the PR, exactly as the moved-head path posts it"
[ "$(head -1 "$REC12/reviewed-sha")" = "$HP2" ] && ok || bad "consuming the APPROVE must bind the approval to the reviewed head"
[ "$(state_of 'example-org/demo-os#12')" = MERGED ] && ok || bad "with the hold cleared, an approved+green+CLEAN PR classifies READY on the same tick and merges (got $(state_of 'example-org/demo-os#12'))"
[ -f "$T/merged12" ] && ok || bad "the cleared PR must actually have been merged, head-bound"
CN=$(grep -c 'issues/12/comments' "$T/comments.txt"); tick4
[ "$(grep -c 'issues/12/comments' "$T/comments.txt")" = "$CN" ] && ok || bad "a consumed verdict must never be consumed twice on a provenance hold either"

# 4i-3. the read comes back BLOCK: parked on a reason the RESOLVER owns
reset12; mk_gh "$HP3"; prov_rec "$HP3"; rm -f "$RRDIR"/*.json "$T/merged12"; : > "$T/comments.txt"
JP3="$(mc_rr_file example-org/demo-os 12 $HP3)"
printf 'findings\nVERDICT: BLOCK\n' > "$RRDIR/prov-block.out"
mc_rr_write "$JP3" done 0 "$(date -u +%s)" "$(date -u +%s)" BLOCK "$HP3" "$HP3" "$RRDIR/prov-block.out"
tick4
[ "$(state_of 'example-org/demo-os#12')" = BLOCKED_HUMAN ] && ok || bad "a BLOCK on a provenance hold must still park (got $(state_of 'example-org/demo-os#12'))"
[ "$(reason_of 'example-org/demo-os#12')" = head-not-reapproved ] && ok || bad "a BLOCKED head must park on head-not-reapproved, which bin/blocked-resolver.sh owns, not on provenance, which nothing does (got $(reason_of 'example-org/demo-os#12'))"
grep -qxF "provcleared example-org/demo-os#12 $HP3" "$T/h/state/merge-conductor/attempts.txt" && bad "a BLOCK must never clear a provenance hold" || ok
[ -f "$T/merged12" ] && bad "a BLOCKED head must not merge" || ok


# ============================================================================
# 4k. A REFUSED HEAD BUYS OUR OWN READ BEFORE IT IS PARKED (2026-09-16, lever 2
#     of the operator's project-5 acceleration, "urgent").
#
#     The fixture is the shape the acceleration is about: the head MOVED off the
#     reviewed sha, the patch-id DIFFERS (so no rebind), the files OVERLAP (so no
#     no-overlap rebind either), and the BUILD's own head-bound gate wrote
#     `blocked@<this head>` into the record. That used to be an instant
#     BLOCKED_HUMAN `head-not-reapproved` and a full agent fix round for
#     bin/blocked-resolver.sh — 61 of them on project-5 on 2026-09-16. Now it
#     buys the detached head-bound Claude read first and the park waits for OUR
#     verdict. Driven end to end, because the claim is about control flow: a
#     classifier that returned the right word and a tick that parked anyway
#     would pass a pure test and fail every PR.
# ============================================================================
HR1=aa11refused1; HR2=bb22refused2; HR3=cc33refused3
# the record 4i left behind carries a non-primary provenance, which parks ahead
# of the drift branch — clear it, so what is under test here is the refusal alone
hb_rec() { printf 'blocked@%s\n' "$1" > "$REC12/headbound-outcome"; echo "$H1" > "$REC12/reviewed-sha"
           rm -f "$REC12/pipeline.log"; }

# 4k-1. the gate refused THIS head: HEAD_MOVED and a read bought, NOT a park
printf 'a refused patch\n' > "$T/patch.$HR1"
reset12; mk_gh "$HR1"; hb_rec "$HR1"; rm -f "$RRDIR"/*.json "$T/merged12"; : > "$T/comments.txt"
logmark; tick4
JR1="$(mc_rr_file example-org/demo-os 12 $HR1)"
[ "$(state_of 'example-org/demo-os#12')" = HEAD_MOVED ] && ok || bad "a blocked@<this head> must stay HEAD_MOVED while our own read is bought (got $(state_of 'example-org/demo-os#12'))"
[ -f "$JR1" ] && ok || bad "the refused head must SPAWN the detached head-bound re-review"
logsince | grep -q 'demo-os#12 REREVIEW_SPAWNED' && ok || bad "the spawn must be logged as REREVIEW_SPAWNED"
grep -q 'demo-os#12 BLOCKED_AGENT head-not-reapproved' <<<"$(logsince)" && bad "the park must NOT happen before our own read has answered" || ok
grep -qxF "hbrefused example-org/demo-os#12 $HR1" "$ATT" && bad "nothing may record a refusal the conductor has not made itself" || ok
[ -f "$T/merged12" ] && bad "a PR whose refused head is being re-read must not merge either" || ok

# 4k-2. our read comes back APPROVE: the approval is rebound and the PR merges
printf 'a second refused patch\n' > "$T/patch.$HR2"
reset12; mk_gh "$HR2"; hb_rec "$HR2"; rm -f "$RRDIR"/*.json "$T/merged12"; : > "$T/comments.txt"
JR2="$(mc_rr_file example-org/demo-os 12 $HR2)"
printf 'findings\nVERDICT: APPROVE\n' > "$RRDIR/refused-approve.out"
mc_rr_write "$JR2" done 0 "$(date -u +%s)" "$(date -u +%s)" APPROVE "$HR2" "$H1" "$RRDIR/refused-approve.out"
logmark; tick4
logsince | grep -q "demo-os#12 head-bound re-review APPROVED ${HR2:0:8}" && ok || bad "our own APPROVE must overrule the build gate's refusal of the same head"
[ "$(head -1 "$REC12/reviewed-sha")" = "$HR2" ] && ok || bad "the APPROVE must rebind the approval to the refused head"
[ "$(state_of 'example-org/demo-os#12')" = WAIT_REVIEW ] && ok || bad "a re-approved head parks one tick in WAIT_REVIEW (got $(state_of 'example-org/demo-os#12'))"
grep -qxF "hbrefused example-org/demo-os#12 $HR2" "$ATT" && bad "an APPROVE must never record a refusal" || ok
tick4
[ -f "$T/merged12" ] && ok || bad "with the approval rebound the PR must MERGE — no park and no fix round were ever owed"

# 4k-3. our read comes back BLOCK: ONLY NOW the head-not-reapproved hand-off
printf 'a third refused patch\n' > "$T/patch.$HR3"
reset12; mk_gh "$HR3"; hb_rec "$HR3"; rm -f "$RRDIR"/*.json "$T/merged12"; : > "$T/comments.txt"
JR3="$(mc_rr_file example-org/demo-os 12 $HR3)"
printf 'findings\nVERDICT: BLOCK\n' > "$RRDIR/refused-block.out"
mc_rr_write "$JR3" done 0 "$(date -u +%s)" "$(date -u +%s)" BLOCK "$HR3" "$H1" "$RRDIR/refused-block.out"
logmark; tick4
[ "$(state_of 'example-org/demo-os#12')" = BLOCKED_HUMAN ] && ok || bad "our own BLOCK must park the PR (got $(state_of 'example-org/demo-os#12'))"
[ "$(reason_of 'example-org/demo-os#12')" = head-not-reapproved ] && ok || bad "the park reason is the one bin/blocked-resolver.sh owns (got $(reason_of 'example-org/demo-os#12'))"
logsince | grep -q 'demo-os#12 BLOCKED_AGENT head-not-reapproved' && ok || bad "the hand-off line the resolver reads must be written"
grep -qxF "hbrefused example-org/demo-os#12 $HR3" "$ATT" && ok || bad "OUR refusal must be recorded per (PR, head) so the row cannot oscillate"
grep -q 'api -i -X POST repos/example-org/demo-os/issues/12/comments' "$T/comments.txt" && ok || bad "the findings must be posted on the PR, as they are today"
[ -f "$T/merged12" ] && bad "a head our own read blocked must not merge" || ok
# and the recorded refusal is what parks it from here on: drop the sticky
# hand-off row so the tick classifies again, and it must NOT buy a second read
awk -F'\t' '$1!="example-org/demo-os#12"' "$T/h/state/merge-conductor/pr-state.tsv" > "$T/rows.k" 2>/dev/null
mv -f "$T/rows.k" "$T/h/state/merge-conductor/pr-state.tsv"
rm -f "$JR3"; logmark; tick4
[ "$(state_of 'example-org/demo-os#12')" = BLOCKED_HUMAN ] && ok || bad "with hbrefused recorded, a re-classified row parks straight away (got $(state_of 'example-org/demo-os#12'))"
[ -f "$JR3" ] && bad "a head our own read already refused must never buy a second read" || ok
rm -f "$REC12/headbound-outcome"


# ============================================================================
# 4j. THE PR'S OWN BUILD IS STILL RUNNING: the tick waits instead of buying a
#     review (2026-09-14). The pool build reviews its own PR at the end of its
#     pipeline; a conductor that reviews the same head first pays twice for one
#     answer. Bounded by MC_JOB_WAIT_SECS, or a dead builder would hold the PR
#     for ever.
# ============================================================================
HJ=dddd4444job
printf 'a ledger-job patch\n' > "$T/patch.$HJ"
ledger_job() { # ledger_job <status> <age-seconds>
  jq -nc --arg s "$1" --arg t "$(date -u -d "@$(( $(date -u +%s) - $2 ))" +%Y-%m-%dT%H:%M:%SZ)" \
    '{job_id:"build-demo-os-TK-12-9", verdict:null, job:{status:$s,stage:"review",updated_at:$t}}' > "$T/ledger-job.json"
}
reset12; mk_gh "$HJ"; rm -f "$RRDIR"/*.json "$T/merged12" "$REC12/pipeline.log" "$REC12/reviewed-sha"
mv "$REC12/review.md" "$T/review12.md"      # no verdict at all: the fresh-review path
ledger_job running 120
tick4
JJ="$(mc_rr_file example-org/demo-os 12 $HJ)"
[ -f "$JJ" ] && bad "the conductor must NOT buy a review while the PR's own build is still running" || ok
grep -q 'demo-os#12 job still running, not buying a review' "$T/h/logs/merge-conductor.log" && ok || bad "the wait must say so in the log"
[ "$(state_of 'example-org/demo-os#12')" = HEAD_MOVED ] && ok || bad "waiting is not a park: the row stays where it was (got $(state_of 'example-org/demo-os#12'))"
# the same row, an hour and a half old: that builder is not coming back
ledger_job running 5400
tick4
[ -f "$JJ" ] && ok || bad "past MC_JOB_WAIT_SECS the tick must proceed exactly as it does today — a dead builder cannot hold a PR"
# and a job that FINISHED never holds anything
reset12; mk_gh "$HJ"; rm -f "$RRDIR"/*.json
ledger_job done 60
tick4
[ -f "$JJ" ] && ok || bad "a finished job must not hold the PR"
rm -f "$T/ledger-job.json"
mv "$T/review12.md" "$REC12/review.md"


# ============================================================================
# 5. STACKED CHILDREN, AND THE EMPTY TSV FIELD THAT HID THEM ALL (2026-09-14)
#
# project-5 #868: parent #831 merged 19:19Z, GitHub left the child based on
# ticket/TK-763, and the conductor's stacked block never acted — the orchestrator
# retargeted it by hand at 21:24Z. #848/#850/#852 (base ticket/TK-779) were never
# STACKED_WAIT either. The cause is not the lookup and not the flag: `IFS=$'\t'
# read` COLLAPSES a run of tabs, because tab is an IFS whitespace character, so a
# PR with no labels emitted `…\tfalse\t\tticket/TK-763` and baseRefName slid into
# the labels variable, leaving BASEREF empty on EVERY harness PR (harness PRs
# carry no labels on any repo without Mergify).
#
# The first case pins the parse itself; the rest drive the whole tick.
# ============================================================================
# The query under test is READ OUT OF THE SCRIPT, so this case can never drift
# from the jq the conductor actually runs.
TSVQ=$(grep -o "jq -r '\.\[\] | \[\.number.*@tsv' 2>/dev/null" "$T/h/bin/merge-conductor.sh" | head -1 | sed "s/^jq -r '//; s/' 2>\/dev\/null$//")
[ -n "$TSVQ" ] && ok || bad "could not find the conductor's own PR-list jq in the script"
ROW=$(printf '[{"number":41,"url":"u","headRefOid":"h","headRefName":"ticket/TK-41","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"ticket/TK-40"}]' | jq -r "$TSVQ")
# THIRTEEN NAMES since BH-1529 appended `isCrossRepository` (twelve since
# BH-1486 appended `updatedAt`): this read is pr_worker's, variable for
# variable, so it grows with it. A fixture that carries no updatedAt must land
# the documented `-` there — that placeholder is what keeps the read memo OFF
# for a PR whose updated_at is unknown — and one with no isCrossRepository a
# `-` too, which keeps the head-lag check off for a PR not known to be same-repo.
IFS=$'\t' read -r X1 X2 X3 X4 X5 X6 X7 X8 XINQ XLBL XBASE XUPD XCROSS <<<"$ROW"
[ "$XBASE" = "ticket/TK-40" ] && ok || bad "a PR with NO labels must still land baseRefName in the baseRefName variable — this is the collapse that hid every stacked child (got lbl='$XLBL' base='$XBASE')"
[ "$XINQ" = false ] && ok || bad "the fields before the empty one must not move either (got '$XINQ')"
[ "$XUPD" = - ] && ok || bad "a list row with no updatedAt must emit '-' in column 12 (got '$XUPD')"
[ "$XCROSS" = - ] && ok || bad "a list row with no isCrossRepository must emit '-' in column 13 (got '$XCROSS')"
ROW=$(printf '[{"number":41,"url":"u","headRefOid":"h","headRefName":"ticket/TK-41","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[{"name":"merge-queue"}],"baseRefName":"main","updatedAt":"2026-09-22T10:00:00Z","isCrossRepository":false}]' | jq -r "$TSVQ")
IFS=$'\t' read -r X1 X2 X3 X4 X5 X6 X7 X8 XINQ XLBL XBASE XUPD XCROSS <<<"$ROW"
[ "$XLBL" = "merge-queue" ] && [ "$XBASE" = main ] && ok || bad "a PR that DOES carry a label must be read exactly as before (lbl='$XLBL' base='$XBASE')"
[ "$XUPD" = 2026-09-22T10:00:00Z ] && ok || bad "updatedAt must land in column 12 when the list carries it (got '$XUPD')"
# `false`, not `-`: jq's `//` would turn a same-repo PR's false into the
# placeholder, and the head-lag check acts on a literal false only.
[ "$XCROSS" = false ] && ok || bad "a same-repo PR must land 'false' in column 13 (got '$XCROSS')"

# The whole tick, with no labels on any PR — the fleet's normal shape.
#   41  base ticket/TK-40, parent PR 40 still OPEN   -> STACKED_WAIT
#   42  base ticket/TK-39, parent PR 39 MERGED, head with NO runs
#                                                    -> retargeted to main AND kicked
#   43  base main                                    -> classifies normally
#   44  base ticket/TK-39, parent PR 39 MERGED, head already GREEN
#                                                    -> retargeted, NOT kicked
HK=99999999kkkk   # PR 42's head: NO workflow run has ever touched it
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n'; exit 0 ;;  # BH-1668: the PR's own thread (no HOLD), read over REST by to_merge_hold
  *"auth token"*) echo faketoken ;;
  *"api -X PATCH repos/example-org/demo-os/pulls/42 -f base="*) printf '%s\n' "\$*" >> "$T/retargets.txt"; touch "$T/retargeted42"; exit 0 ;;
  *"api -X PATCH repos/example-org/demo-os/pulls/42 -f state="*) printf '%s\n' "\$*" >> "$T/kicks.txt"; exit 0 ;;
  *"api -X PATCH repos/example-org/demo-os/pulls/44 -f base="*) printf '%s\n' "\$*" >> "$T/retargets.txt"; touch "$T/retargeted44"; exit 0 ;;
  *"api -X PATCH repos/example-org/demo-os/pulls/44 -f state="*) printf '%s\n' "\$*" >> "$T/kicks.txt"; exit 0 ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/gh-writes.txt"; exit 1 ;;
  # The stacked-parent lookup is a REST LIST now (BH-784): REST spells --head as
  # owner:branch, and the answer is a JSON array the caller reduces itself. The
  # trailing space anchors the branch name so TK-39 cannot swallow TK-39-r2.
  *"-f head=example-org:ticket/TK-40 "*) restpr --raw 200 '[{"state":"open","merged_at":null,"html_url":"https://github.com/example-org/demo-os/pull/40"}]' ;;
  *"-f head=example-org:ticket/TK-39 "*) restpr --raw 200 '[{"state":"closed","merged_at":"2026-09-12T02:00:00Z","html_url":"https://github.com/example-org/demo-os/pull/39"}]' ;;
  *"-f head=example-org:"*) restpr --raw 200 '[]' ;;
  *"pr list -R example-org/demo-os --state open"*)
    B42=ticket/TK-39; [ -f "$T/retargeted42" ] && B42=main
    B44=ticket/TK-39; [ -f "$T/retargeted44" ] && B44=main
    cat <<J
[{"number":41,"url":"https://github.com/example-org/demo-os/pull/41","headRefOid":"$H1","headRefName":"ticket/TK-41","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"ticket/TK-40"},
 {"number":42,"url":"https://github.com/example-org/demo-os/pull/42","headRefOid":"$HK","headRefName":"ticket/TK-42","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"\$B42"},
 {"number":43,"url":"https://github.com/example-org/demo-os/pull/43","headRefOid":"$H1","headRefName":"ticket/TK-43","isDraft":false,"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","state":"OPEN","labels":[],"baseRefName":"main"},
 {"number":44,"url":"https://github.com/example-org/demo-os/pull/44","headRefOid":"$H1","headRefName":"ticket/TK-44","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"\$B44"}]
J
    ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha=$HK"*) restpr --runs ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"v3.diff"*) restpr --diff ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
rm -f "$T/retargeted42" "$T/retargeted44" "$T/retargets.txt" "$T/gh-writes.txt" "$T/kicks.txt"
run_tick env MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0
[ "$(state_of 'example-org/demo-os#41')" = STACKED_WAIT ] && ok || bad "a child based on an OPEN parent's branch must be STACKED_WAIT (got $(state_of 'example-org/demo-os#41'))"
[ -f "$T/retargeted42" ] && ok || bad "a child whose parent MERGED must be retargeted to the project base — #868 waited an hour for a human to do this by hand"
grep -q 'pulls/42 -f base=main' "$T/retargets.txt" 2>/dev/null && ok || bad "the retarget must be the REST PATCH with the project base (got '$(cat "$T/retargets.txt" 2>/dev/null)')"
grep -q 'demo-os#42 parent .* merged but GitHub left this PR based on ticket/TK-39 — retargeted to main' "$T/h/logs/merge-conductor.log" && ok || bad "the retarget must be logged"
[ "$(state_of 'example-org/demo-os#42')" != STACKED_WAIT ] && ok || bad "a retargeted child must classify normally in the SAME tick, not stay parked"
# AND THE RETARGET MUST BE FOLLOWED BY A CI KICK (2026-09-15, project-5
# #913/#943/#1011/#1020/#1021). A base change fires no `pull_request` workflow —
# the default activity types are opened|synchronize|reopened — so the retargeted
# head keeps the runs it had, which for a child cut from a feature branch is
# none at all. Every one of those five PRs then sat in `WAIT_CI checks none`
# with the required check never reporting, until a human closed and reopened it.
grep -q 'pulls/42 -f state=closed' "$T/kicks.txt" 2>/dev/null \
  && ok || bad "the retarget tick must also CLOSE the PR — a base change fires no workflow and the head would keep its zero runs (got: $(cat "$T/kicks.txt" 2>/dev/null))"
grep -q 'pulls/42 -f state=open' "$T/kicks.txt" 2>/dev/null \
  && ok || bad "and reopen it — the reopen is the event that fires CI (got: $(cat "$T/kicks.txt" 2>/dev/null))"
[ "$(sed -n 1p "$T/kicks.txt" 2>/dev/null)" = "api -X PATCH repos/example-org/demo-os/pulls/42 -f state=closed" ] \
  && ok || bad "the close must come before the reopen"
grep -q 'demo-os#42 .*retargeted to main and CI kicked (close/reopen)' "$T/h/logs/merge-conductor.log" \
  && ok || bad "the kick must be logged on the same line as the retarget"
# A KICK IS FOR A HEAD WITH NO RUNS, AND ONLY THAT. project-2
# (migration-sql-gate.yml, verification-map-freshness.yml) and project-4
# (typecheck.yml) trigger on a bare `pull_request`, so a stacked child on those
# repos already HAS runs on its head when the retarget lands. Closing and
# reopening it there would cancel an in-progress run through the repo's own
# cancel-in-progress concurrency group and buy a duplicate build for nothing.
[ -f "$T/retargeted44" ] && ok || bad "PR 44's parent merged too — it must still be retargeted whatever its CI says"
grep -q 'pulls/44 -f state=' "$T/kicks.txt" 2>/dev/null \
  && bad "a retargeted head that ALREADY has a green run must NOT be closed and reopened — the kick would cancel it and buy a duplicate build (got: $(cat "$T/kicks.txt"))" || ok
grep -q 'demo-os#44 .*retargeted to main' "$T/h/logs/merge-conductor.log" \
  && ok || bad "the retarget of 44 must still be logged"

[ "$(state_of 'example-org/demo-os#43')" = NEEDS_REBASE ] && ok || bad "an unstacked DIRTY PR is unaffected (got $(state_of 'example-org/demo-os#43'))"
# the parent is still open on the next tick, so the child stays parked and the
# retarget is not attempted a second time
N=$(grep -c 'pulls/42' "$T/retargets.txt")
run_tick env MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0
[ "$(state_of 'example-org/demo-os#41')" = STACKED_WAIT ] && ok || bad "the child of an open parent stays STACKED_WAIT"
[ "$(grep -c 'pulls/42' "$T/retargets.txt")" = "$N" ] && ok || bad "a PR GitHub already reports on the project base must not be retargeted again"
[ "$(grep -c 'pulls/42 -f state=' "$T/kicks.txt")" = 2 ] \
  && ok || bad "one kick per head: a PR already on the project base must not be closed and reopened again (got $(grep -c 'pulls/42 -f state=' "$T/kicks.txt") calls)"


# ============================================================================
# 5b. THE PARENT CLOSED WITHOUT MERGING (2026-09-16)
#
# The other ending, and until today the conductor had no event for it. At 09:35Z
# on 2026-09-16 bin/blocked-resolver.sh gave up on project-5 TK-1529 and CLOSED
# #1556 to rebuild the ticket fresh. Its three children — #1586, #1585, #1587,
# all cut from ticket/TK-1529 — were left based on a branch nothing would ever
# merge, parked `parent-closed`, which is a word no lane owns. They stopped.
#
# The answer is a LOOK AT THE BRANCH, so this case is driven against a REAL
# repository with a real (local) origin: a child that carries nothing of the
# dead parent is retargeted to main exactly like the merged case, and one that
# still carries its commits goes to bin/blocked-resolver.sh as `orphaned-child`.
# NOTHING here closes a PR and nothing here is on a clock.
# ============================================================================
G5="$T/gitconfig5"; O5="$T/o5b.git"; SEED5="$T/seed5"; REPOS5="$T/repos5b"
g5() { GIT_CONFIG_GLOBAL="$G5" GIT_CONFIG_NOSYSTEM=1 git "$@"; }
g5 config --global user.email t@example.com
g5 config --global user.name t
g5 config --global init.defaultBranch main
g5 config --global commit.gpgsign false
g5 config --global protocol.file.allow always
g5 config --global "url.$O5.insteadOf" "https://x-access-token@github.com/example-org/demo-os.git"
g5 config --global "url.$O5.insteadOf" "https://github.com/example-org/demo-os.git" --add
g5 init -q --bare "$O5"
g5 clone -q "$O5" "$SEED5" 2>/dev/null
mkdir -p "$SEED5/src"; printf 'A1\n' > "$SEED5/src/a.ts"
g5 -C "$SEED5" add -A; g5 -C "$SEED5" commit -qm base; g5 -C "$SEED5" push -q origin main
B5=$(g5 -C "$SEED5" rev-parse HEAD)
# the parent, never merged
g5 -C "$SEED5" checkout -q -b ticket/TK-60 "$B5"
printf 'export const p = 1\n' > "$SEED5/src/p.ts"
g5 -C "$SEED5" add -A; g5 -C "$SEED5" commit -qm parent; g5 -C "$SEED5" push -q origin ticket/TK-60
# 61: clean of the parent — one PATCH from being an ordinary PR against main
g5 -C "$SEED5" checkout -q -b ticket/TK-61 "$B5"
printf 'export const k = 1\n' > "$SEED5/src/k.ts"
g5 -C "$SEED5" add -A; g5 -C "$SEED5" commit -qm kid-own; g5 -C "$SEED5" push -q origin ticket/TK-61
KIDOWN=$(g5 -C "$SEED5" rev-parse HEAD)
# 62: really cut from the parent, so the parent's commit is still in it
g5 -C "$SEED5" checkout -q -b ticket/TK-62 ticket/TK-60
printf 'export const k2 = 1\n' > "$SEED5/src/k2.ts"
g5 -C "$SEED5" add -A; g5 -C "$SEED5" commit -qm kid-carries; g5 -C "$SEED5" push -q origin ticket/TK-62
KIDCAR=$(g5 -C "$SEED5" rev-parse HEAD)
mkdir -p "$REPOS5"; g5 clone -q "$O5" "$REPOS5/demo-os" 2>/dev/null

for N in 61 62; do
  D5="$T/h/builds/pool-demo-os-TK-$N-2026091600$N"
  mkdir -p "$D5"
  echo "PR_CREATED https://github.com/example-org/demo-os/pull/$N" > "$D5/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$D5/review.md"
done
echo "$KIDOWN" > "$T/h/builds/pool-demo-os-TK-61-202609160061/reviewed-sha"
echo "$KIDCAR" > "$T/h/builds/pool-demo-os-TK-62-202609160062/reviewed-sha"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n'; exit 0 ;;  # BH-1668: the PR's own thread (no HOLD), read over REST by to_merge_hold
  *"auth token"*) echo faketoken ;;
  *"api -X PATCH repos/example-org/demo-os/pulls/61 -f base="*) printf '%s\n' "\$*" >> "$T/retargets5b.txt"; touch "$T/retargeted61"; exit 0 ;;
  *"api -X PATCH"*"-f state="*) printf '%s\n' "\$*" >> "$T/kicks5b.txt"; exit 0 ;;
  *"api -X PATCH"*"-f base="*) printf '%s\n' "\$*" >> "$T/retargets5b.txt"; exit 0 ;;
  *"pr merge"*|*"pr close"*|*"issue close"*) printf '%s\n' "\$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"api -i -X POST"*"/comments"*) printf '%s\n' "\$*" >> "$T/gh-writes.txt"; exit 1 ;;
  # The parent lookup is a REST LIST now (BH-784), so the answer is a JSON array
  # and the head is spelled owner:branch.
  *"-f head=example-org:ticket/TK-60 "*) restpr --raw 200 '[{"state":"closed","merged_at":null,"html_url":"https://github.com/example-org/demo-os/pull/60"}]' ;;
  # NO REBUILD ON ANY ticket/TK-60-rN: this section is the shape where nothing
  # replaced the dead parent, which is the one mc_orphan_clean answers. The
  # anchor on the trailing space matters: real GitHub matches a head branch
  # EXACTLY, and a stub that let ticket/TK-60 swallow ticket/TK-60-r6 would hand
  # mc_retry_pr the dead parent as its own rebuild.
  *"-f head=example-org:"*) restpr --raw 200 '[]' ;;
  *"pr list -R example-org/demo-os --state open"*)
    B61=ticket/TK-60; [ -f "$T/retargeted61" ] && B61=main
    cat <<J
[{"number":61,"url":"https://github.com/example-org/demo-os/pull/61","headRefOid":"$KIDOWN","headRefName":"ticket/TK-61","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"\$B61"},
 {"number":62,"url":"https://github.com/example-org/demo-os/pull/62","headRefOid":"$KIDCAR","headRefName":"ticket/TK-62","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"ticket/TK-60"}]
J
    ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha=$KIDOWN"*) restpr --runs ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"v3.diff"*) restpr --diff '+++ b/src/k.ts
+const a = 1;
' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
: > "$T/retargets5b.txt"; : > "$T/kicks5b.txt"; : > "$T/gh-writes.txt"
rm -f "$T/retargeted61"
# REAL GIT FOR THIS SECTION. Every other case in this file stubs git, because
# every other case is about a decision made from gh's words. This one is about
# what git ANSWERS — which commits a branch carries, and whether it merges into
# main — so the stub comes off and goes back on at the end. The merge flag comes
# off with it: the subject is the retarget, and merging the PR it produces would
# only add a second failure mode to read through.
mv "$T/fakebin/git" "$T/fakebin/git.off"
rm -f "$T/h/flags/merge-conductor-merge"
tick5b() { run_tick env MC_MERGE_SETTLE=0 MC_DETACHED_REBASE=0 MC_KICK_REOPEN_SLEEP=0 \
                       MC_REPOS="$REPOS5" GIT_CONFIG_GLOBAL="$G5" GIT_CONFIG_NOSYSTEM=1 "$@"; }
tick5b
[ -f "$T/retargeted61" ] \
  && ok || bad "a child that carries nothing of the CLOSED parent must be retargeted to main — this is the PATCH #1586/#1585/#1587 never got"
grep -q 'pulls/61 -f base=main' "$T/retargets5b.txt" \
  && ok || bad "the retarget must be the REST PATCH with the project base (got: $(cat "$T/retargets5b.txt"))"
grep -q 'demo-os#61 parent .* CLOSED without merging' "$T/h/logs/merge-conductor.log" \
  && ok || bad "the retarget must say the parent CLOSED, not that it merged — the two endings are different facts"
[ "$(state_of 'example-org/demo-os#61')" != BLOCKED_HUMAN ] \
  && ok || bad "a retargeted child must classify normally on the same tick, not stay parked (got $(state_of 'example-org/demo-os#61'))"
# A base change fires no `pull_request` workflow, and 61's head has no runs.
grep -q 'pulls/61 -f state=closed' "$T/kicks5b.txt" && grep -q 'pulls/61 -f state=open' "$T/kicks5b.txt" \
  && ok || bad "the retarget of a head with no runs must be followed by the CI kick, exactly like the merged case (got: $(cat "$T/kicks5b.txt"))"

# 62 still carries the dead parent's commit: retargeting it would open the
# abandoned parent's diff against main under 62's number.
grep -q 'pulls/62 -f base=' "$T/retargets5b.txt" \
  && bad "a child that still carries the closed parent's commits must NOT be retargeted (got: $(cat "$T/retargets5b.txt"))" || ok
[ "$(state_of 'example-org/demo-os#62')" = BLOCKED_HUMAN ] \
  && ok || bad "it must park (got $(state_of 'example-org/demo-os#62'))"
case "$(reason_of 'example-org/demo-os#62')" in
  orphaned-child*) ok ;;
  *) bad "the park must be on orphaned-child, which bin/blocked-resolver.sh owns — parent-closed is the word nothing came for (got '$(reason_of 'example-org/demo-os#62')')" ;;
esac
mc_resolver_owns "$(reason_of 'example-org/demo-os#62')" \
  && ok || bad "and the resolver must actually own the reason as it is STORED, detail and all"
grep -q 'demo-os#62 BLOCKED_AGENT orphaned-child' "$T/h/logs/merge-conductor.log" \
  && ok || bad "the hand-off must be logged as a hand-off (got: $(grep -o 'demo-os#62 .*' "$T/h/logs/merge-conductor.log" | tail -1))"
grep -q 'demo-os#62' "$T/gh-writes.txt" \
  && bad "NOTHING here may close a PR — a close happens on a failed fix round, never on this event (got: $(cat "$T/gh-writes.txt"))" || ok
# ...and it is said ONCE per head, not on every five-minute tick.
NL=$(grep -c 'demo-os#62 BLOCKED_AGENT orphaned-child' "$T/h/logs/merge-conductor.log")
tick5b
[ "$(grep -c 'demo-os#62 BLOCKED_AGENT orphaned-child' "$T/h/logs/merge-conductor.log")" = "$NL" ] \
  && ok || bad "the hand-off line must be written once per head, not once per tick"
[ "$(grep -c 'pulls/61 -f base=' "$T/retargets5b.txt")" = 1 ] \
  && ok || bad "a PR GitHub already reports on main must not be retargeted again"

# THE KILL FLAG: the same two PRs, and the 2026-09-14 behaviour byte for byte.
awk -F'\t' '$1!="example-org/demo-os#62"' "$T/h/state/merge-conductor/pr-state.tsv" > "$T/rows5b.tmp"
mv -f "$T/rows5b.tmp" "$T/h/state/merge-conductor/pr-state.tsv"
grep -v 'example-org/demo-os#62' "$T/h/state/merge-conductor/attempts.txt" > "$T/att5b.tmp" 2>/dev/null
mv -f "$T/att5b.tmp" "$T/h/state/merge-conductor/attempts.txt"
tick5b MC_ORPHAN_RETARGET=0
case "$(reason_of 'example-org/demo-os#62')" in
  parent-closed*) ok ;;
  *) bad "MC_ORPHAN_RETARGET=0 must park exactly as it did before this change (got '$(reason_of 'example-org/demo-os#62')')" ;;
esac

# AND A TICK THAT CANNOT READ THE BRANCH SAYS SO AND CHANGES NOTHING. No
# checkout, no token, no answer — the one thing it must never do is guess, in
# either direction: not a retarget of a branch nobody looked at, and not an
# agent fix round on a branch that is fine.
awk -F'\t' '$1!="example-org/demo-os#62"' "$T/h/state/merge-conductor/pr-state.tsv" > "$T/rows5b.tmp"
mv -f "$T/rows5b.tmp" "$T/h/state/merge-conductor/pr-state.tsv"
grep -v 'example-org/demo-os#62' "$T/h/state/merge-conductor/attempts.txt" > "$T/att5b.tmp" 2>/dev/null
mv -f "$T/att5b.tmp" "$T/h/state/merge-conductor/attempts.txt"
N5=$(grep -c 'base=' "$T/retargets5b.txt")
mv "$T/fakebin/git.off" "$T/fakebin/git"     # a box whose git cannot answer the question
tick5b
case "$(reason_of 'example-org/demo-os#62')" in
  parent-closed*) ok ;;
  *) bad "a tick that cannot read the branch must leave the row on parent-closed, not invent orphaned-child (got '$(reason_of 'example-org/demo-os#62')')" ;;
esac
[ "$(grep -c 'base=' "$T/retargets5b.txt")" = "$N5" ] \
  && ok || bad "and it must retarget nothing at all"
grep -q 'could not judge ticket/TK-62' "$T/h/logs/merge-conductor.log" \
  && ok || bad "an unreadable branch must say so in the log — a question asked into a run log nobody reads is indistinguishable from silence"

# THE REBUILD PROBE RUNS FIRST, ALWAYS. The orphan read is the SECOND answer to
# a closed parent (section 15); the first is "was this parent rebuilt, and is
# the rebuild live" (BH-458, section 14). Every retarget above therefore has to
# be downstream of a mc_retry_pr probe, or the conductor would be moving
# children to main while the branch that replaces their parent is sitting open.
grep -q -- 'head=example-org:ticket/TK-60-r' "$T/gh-calls.txt" \
  && ok || bad "the CLOSED arm must probe for a rebuild before it reads the branch — otherwise a child gets retargeted to main while its parent's -rN is still open"


# ============================================================================
# 5c. AND WHEN THERE *IS* A LIVE REBUILD, THE RESTACK WINS (2026-09-16)
#
# The seam between the two answers, driven rather than argued. #63 is clean of
# the dead parent, so the orphan read on its own would retarget it to main —
# which is the WRONG base: ticket/TK-60 was rebuilt as ticket/TK-60-r2 and that
# PR is open, so the child belongs on top of the rebuild, waiting on its new
# parent like any healthy stack. If the precedence ever inverts, this case goes
# to main and the child merges without the parent's work under it.
# ============================================================================
g5 -C "$SEED5" checkout -q -b ticket/TK-60-r2 "$B5"
printf 'export const p2 = 1\n' > "$SEED5/src/p2.ts"
g5 -C "$SEED5" add -A; g5 -C "$SEED5" commit -qm parent-rebuilt; g5 -C "$SEED5" push -q origin ticket/TK-60-r2
# Cut from the base, not from the dead parent: clean, exactly like 61 was.
g5 -C "$SEED5" checkout -q -b ticket/TK-63 "$B5"
printf 'export const k3 = 1\n' > "$SEED5/src/k3.ts"
g5 -C "$SEED5" add -A; g5 -C "$SEED5" commit -qm kid-restackable; g5 -C "$SEED5" push -q origin ticket/TK-63
KID63=$(g5 -C "$SEED5" rev-parse HEAD)
D63="$T/h/builds/pool-demo-os-TK-63-202609160063"; mkdir -p "$D63"
echo "PR_CREATED https://github.com/example-org/demo-os/pull/63" > "$D63/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$D63/review.md"
echo "$KID63" > "$D63/reviewed-sha"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n'; exit 0 ;;  # BH-1668: the PR's own thread (no HOLD), read over REST by to_merge_hold
  *"auth token"*) echo faketoken ;;
  *"api -X PATCH repos/example-org/demo-os/pulls/63 -f base="*) printf '%s\n' "\$*" >> "$T/retargets5c.txt"; touch "$T/retargeted63"; exit 0 ;;
  *"api -X PATCH"*"-f state="*) printf '%s\n' "\$*" >> "$T/kicks5c.txt"; exit 0 ;;
  *"api -X PATCH"*"-f base="*) printf '%s\n' "\$*" >> "$T/retargets5c.txt"; exit 0 ;;
  *"pr merge"*|*"pr close"*|*"issue close"*) printf '%s\n' "\$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"api -X POST"*"/comments"*|*"api -i -X POST"*"/comments"*) printf '%s\n' "\$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"-f head=example-org:ticket/TK-60-r2 "*) restpr --raw 200 '[{"state":"open","merged_at":null,"html_url":"https://github.com/example-org/demo-os/pull/64"}]' ;;
  *"-f head=example-org:ticket/TK-60 "*) restpr --raw 200 '[{"state":"closed","merged_at":null,"html_url":"https://github.com/example-org/demo-os/pull/60"}]' ;;
  *"-f head=example-org:"*) restpr --raw 200 '[]' ;;
  *"pr list -R example-org/demo-os --state open"*)
    B63=ticket/TK-60; [ -f "$T/retargeted63" ] && B63=ticket/TK-60-r2
    cat <<J
[{"number":63,"url":"https://github.com/example-org/demo-os/pull/63","headRefOid":"$KID63","headRefName":"ticket/TK-63","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"\$B63"}]
J
    ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) restpr --runs ;;
  *"v3.diff"*) restpr --diff '+++ b/src/k3.ts
+const a = 1;
' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
: > "$T/retargets5c.txt"; : > "$T/kicks5c.txt"; rm -f "$T/retargeted63"
mv "$T/fakebin/git" "$T/fakebin/git.off"      # real git again: a real rebase runs here
tick5b MC_GIT_NAME=t MC_GIT_EMAIL=t@example.com
grep -q 'pulls/63 -f base=ticket/TK-60-r2' "$T/retargets5c.txt" \
  && ok || bad "a child whose dead parent HAS a live rebuild must be restacked onto the rebuild branch, not read as an orphan (got: $(cat "$T/retargets5c.txt"))"
grep -q 'pulls/63 -f base=main' "$T/retargets5c.txt" \
  && bad "the orphan read must never win over a live rebuild — retargeting #63 to main lands it without the parent's work under it" || ok
case "$(reason_of 'example-org/demo-os#63')" in
  orphaned-child*) bad "a child with a live rebuild to move onto must not be handed to the resolver as an orphan" ;;
  *) ok ;;
esac
grep -q 'demo-os#63 restacked' "$T/h/logs/merge-conductor.log" \
  && ok || bad "the restack must be logged as a restack (got: $(grep -o 'demo-os#63 .*' "$T/h/logs/merge-conductor.log" | tail -1))"
grep -q 'demo-os#63' "$T/gh-writes.txt" \
  && bad "nothing on this path may close or comment on a PR (got: $(cat "$T/gh-writes.txt"))" || ok
# The rebase really happened: the pushed head is a NEW sha that sits on the
# rebuild branch and still carries the child's own file.
NEW63=$(g5 -C "$SEED5" ls-remote "$O5" refs/heads/ticket/TK-63 | cut -f1)
[ -n "$NEW63" ] && [ "$NEW63" != "$KID63" ] \
  && ok || bad "the restack must push a rewritten head for ticket/TK-63 (was $KID63, now ${NEW63:-nothing})"
g5 -C "$REPOS5/demo-os" fetch -q origin ticket/TK-63 ticket/TK-60-r2 2>/dev/null
[ -z "$(g5 -C "$REPOS5/demo-os" rev-list "$NEW63" --not origin/ticket/TK-60-r2 --not FETCH_HEAD 2>/dev/null | tail -n +2)" ] \
  && ok || bad "the restacked head must be the child's own commits replayed on the rebuild branch, nothing more"
mv "$T/fakebin/git.off" "$T/fakebin/git"
touch "$T/h/flags/merge-conductor-merge"


# ============================================================================
# 6. A HEAD WITH NO WORKFLOW RUN AT ALL GETS ONE KICK (2026-09-15)
#
# The generic backstop under the retarget path above: GitHub retargets a child
# BY ITSELF when the parent's branch is deleted, and that base change fires no
# `pull_request` workflow either. project-5 #913/#943/#1011/#1020/#1021 all sat
# in `WAIT_CI checks none` with zero runs on the head while siblings opened
# straight against main merged within the hour.
#
# THREE GUARDS, and each is a case here. `ci=none` is the NORMAL state of a
# CONFLICTING PR (GitHub runs nothing on a tree it cannot merge), so a
# conflicted head must never be kicked; a row that has only just entered
# WAIT_CI is a run that has not appeared YET, not one that never will; and a
# head that has been kicked once is never kicked again.
# ============================================================================
for N in 51 53; do
  D6="$T/h/builds/pool-demo-os-TK-$N-20260915000$N"
  mkdir -p "$D6"
  echo "PR_CREATED https://github.com/example-org/demo-os/pull/$N" > "$D6/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$D6/review.md"
  echo "$H1" > "$D6/reviewed-sha"
done
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n'; exit 0 ;;  # BH-1668: the PR's own thread (no HOLD), read over REST by to_merge_hold
  *"auth token"*) echo faketoken ;;
  *"api -X PATCH"*) printf '%s\n' "\$*" >> "$T/kicks6.txt"; exit 0 ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"pr list -R example-org/demo-os --state open"*)
    cat <<J
[{"number":51,"url":"https://github.com/example-org/demo-os/pull/51","headRefOid":"$H1","headRefName":"ticket/TK-51","isDraft":false,"mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"main"},
 {"number":52,"url":"https://github.com/example-org/demo-os/pull/52","headRefOid":"$H1","headRefName":"ticket/TK-52","isDraft":false,"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","state":"OPEN","labels":[],"baseRefName":"main"},
 {"number":53,"url":"https://github.com/example-org/demo-os/pull/53","headRefOid":"$H1","headRefName":"ticket/TK-53","isDraft":false,"mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"main"}]
J
    ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) restpr --runs ;;
  *"v3.diff"*) restpr --diff ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
NOW6=$(date -u +%s)
mc_row_put 'example-org/demo-os#51' WAIT_CI $((NOW6-1200)) "$H1" "$H1" - "checks none" https://github.com/example-org/demo-os/pull/51
mc_row_put 'example-org/demo-os#53' WAIT_CI $((NOW6-60))   "$H1" "$H1" - "checks none" https://github.com/example-org/demo-os/pull/53
: > "$T/kicks6.txt"; : > "$T/gh-writes.txt"
run_tick env MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_KICK_REOPEN_SLEEP=0
[ "$(state_of 'example-org/demo-os#51')" = WAIT_CI ] && ok || bad "PR 51 (approved at head, MERGEABLE, no runs on the head) must be WAIT_CI (got $(state_of 'example-org/demo-os#51'))"
grep -q 'pulls/51 -f state=closed' "$T/kicks6.txt" && grep -q 'pulls/51 -f state=open' "$T/kicks6.txt" \
  && ok || bad "a MERGEABLE PR on the project base, 20m in WAIT_CI with no workflow run at all, must be kicked (got: $(cat "$T/kicks6.txt"))"
grep -q 'demo-os#51 CI kicked' "$T/h/logs/merge-conductor.log" \
  && ok || bad "the kick must be logged against the PR, or nobody can tell a kicked head from a stranded one"
grep -q 'pulls/52' "$T/kicks6.txt" \
  && bad "a CONFLICTING PR's ci=none is the NORMAL state of a head GitHub will not build — it must never be kicked" || ok
grep -q 'pulls/53' "$T/kicks6.txt" \
  && bad "a row younger than the 10-minute window is a run that has not appeared yet, not one that never will" || ok
grep -qxF "cikick example-org/demo-os#51 $H1" "$T/h/state/merge-conductor/attempts.txt" \
  && ok || bad "the kick must be recorded per (PR, head) in the attempts ledger, beside rebase/red/ejected"
N6=$(grep -c 'pulls/51' "$T/kicks6.txt")
run_tick env MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_KICK_REOPEN_SLEEP=0
[ "$(grep -c 'pulls/51' "$T/kicks6.txt")" = "$N6" ] \
  && ok || bad "ONE kick per head: a second tick over the same head must not close and reopen it again (was $N6, now $(grep -c 'pulls/51' "$T/kicks6.txt"))"
# Observe mode writes nothing to GitHub, exactly like every other action here.
rm -f "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
grep -v 'cikick example-org/demo-os#51' "$T/h/state/merge-conductor/attempts.txt" > "$T/att6.tmp"
mv -f "$T/att6.tmp" "$T/h/state/merge-conductor/attempts.txt"
mc_row_put 'example-org/demo-os#51' WAIT_CI $((NOW6-1200)) "$H1" "$H1" - "checks none" https://github.com/example-org/demo-os/pull/51
: > "$T/kicks6.txt"
run_tick env MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0
[ -s "$T/kicks6.txt" ] && bad "an observe-only tick must not close or reopen anything: $(cat "$T/kicks6.txt")" || ok
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"

# ============================================================================
# 11. CONTESTED LOSERS (BH-589): the park, the order of checks, the release
#
# bin/blocked-resolver.sh writes a hold naming who WON a contested path
# (BH-579/#587's store). The conductor's half is two rules, and both are driven
# here through the real script rather than asserted off its text:
#
#   - a PR the hold lists as a LOSER is parked on `BLOCKED_HUMAN
#     contested:<path> (winner <key>)` BEFORE the verdict is read, so it buys no
#     re-review, no rebase and — the whole point — no merge. The flags are ON
#     for those ticks, so a missing park would reach `gh pr merge` and the stub
#     would record a write verb.
#   - when the winner lands, conductor_settle releases every hold it wins and
#     the losers go back to NEEDS_REBASE for ordinary classification.
#
# The order of the checks matters as much as the park: a member of a live batch
# train stays in its train (BH-498 runs first), and an EXPIRED hold is inert, so
# the PR is classified exactly as it is today.
# ============================================================================
printf 'tproj o/r https://demo.example /api/board 2 box-t\n' > "$T/h/fleet.conf"
mkdir -p "$T/h/builds/pool-tproj-TK-41-202609170001"
echo "PR_CREATED https://github.com/o/r/pull/41" > "$T/h/builds/pool-tproj-TK-41-202609170001/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$T/h/builds/pool-tproj-TK-41-202609170001/review.md"
echo "$H1" > "$T/h/builds/pool-tproj-TK-41-202609170001/reviewed-sha"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n'; exit 0 ;;  # BH-1668: the PR's own thread (no HOLD), read over REST by to_merge_hold
  *"auth token"*) echo faketoken ;;
  *"pr merge"*|*"push"*|*"pr comment"*|*"issue close"*|*"issue comment"*|*"pr review"*|*"pr edit"*)
    echo "WRITE VERB ON A CONTESTED LOSER: \$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"pr list -R o/r --state open"*)
    echo '[{"number":41,"url":"https://github.com/o/r/pull/41","headRefOid":"$H1","headRefName":"ticket/TK-41","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"main"}]' ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha=$H1"*) restpr --runs 'completed|success' ;;
  *"pr view"*"--json body"*) echo "plain body" ;;
  # The read the merge arm makes immediately before it writes. It answers OPEN
  # on the same head and the project base ON PURPOSE: with it, a tick that does
  # NOT park PR 41 reaches \`gh pr merge\` and the write-verb arm above fails the
  # run, so "no merge verb" below is a claim about the park and not about a stub
  # that happened to stop one line earlier.
  *"pr view https://github.com/o/r/pull/41 --json state,headRefOid,baseRefName"*) echo "OPEN $H1 main" ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
rm -rf "$T/h/state/merge-conductor" "$T/h/state/contested" "$T/h/state/gh-budget"
mkdir -p "$T/h/state/merge-conductor" "$T/h/logs"
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
ATT11="$T/h/state/merge-conductor/attempts.txt"
LOG11="$T/h/logs/merge-conductor.log"
NOW11=$(date -u +%s)
tick11() { run_tick env MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_REPOS="$T/repos" MC_RR_PATH="$T/fakebin:$PATH"; }
alerts11() { local n; n=$(grep -c "$1" "$T/h/logs/ALERTS.log" 2>/dev/null); echo "${n:-0}"; }
hold11() { # hold11 <path> <winner-key> <winner-num> — one live hold listing PR 41 as a loser
  mc_contested_write tproj o/r "$1" "$2" "https://github.com/o/r/pull/$3" \
    '[{"num":41,"url":"https://github.com/o/r/pull/41","key":"TK-41"}]' '["TK-41"]' 600 "test"
}

# 11a. THE BATCH TRAIN WINS THE ORDER OF CHECKS. PR 41 is a loser of a live hold
# AND a member of a live train: the train owns it, so nothing here parks it.
mc_row_put 'o/r#41' READY "$NOW11" "$H1" "$H1" - clean https://github.com/o/r/pull/41
hold11 src/x.ts TK-40 40 && ok || bad "fixture: the contested hold must be written (mc_contested_write rc)"
[ -s "$(mc_contested_file tproj src/x.ts)" ] && ok || bad "fixture: the hold file must exist on disk"
mc_contested_loser tproj o/r 41 >/dev/null && ok || bad "fixture: the hold must name PR 41 a loser, or every assertion below is vacuous"
mc_batch_hold o/r 41 "$H1" https://github.com/o/r/pull/99
: > "$T/gh-writes.txt"; : > "$T/gh-calls.txt"
tick11
[ "$(state_of 'o/r#41')" = READY ] \
  && ok || bad "a member of a live batch train must stay in its train, not be parked contested (got $(state_of 'o/r#41'))"
[ "$(grep -c '^contested o/r#41 ' "$ATT11")" = 0 ] \
  && ok || bad "a held train member must not record a contested attempt line"
grep -qxF "batchheld o/r#41 $H1" "$ATT11" && ok || bad "the batch hold is the one that answered (batchheld line missing)"
mc_batch_release o/r 41

# 11b. THE PARK. Same PR, same hold, no train: BLOCKED_HUMAN on the resolver's
# reason, no gh write with the merge flag ON, one attempts line per (PR, hold).
: > "$T/gh-writes.txt"; : > "$T/gh-calls.txt"
tick11
[ "$(state_of 'o/r#41')" = BLOCKED_HUMAN ] \
  && ok || bad "a loser of a live contested hold must park BLOCKED_HUMAN (got $(state_of 'o/r#41'))"
[ "$(reason_of 'o/r#41')" = "contested:src/x.ts (winner TK-40)" ] \
  && ok || bad "the park reason must name the path and the winner (got '$(reason_of 'o/r#41')')"
mc_resolver_owns "$(reason_of 'o/r#41')" \
  && ok || bad "the park reason must be one bin/blocked-resolver.sh owns, or the row pages a person"
[ -s "$T/gh-writes.txt" ] && bad "the park must buy no gh write: $(cat "$T/gh-writes.txt")" || ok
[ "$(grep -c 'pr merge' "$T/gh-calls.txt")" = 0 ] \
  && ok || bad "the conductor must not merge a contested loser even with the merge flag on"
grep -q 'o/r#41 PARKED .*contested hold on src/x.ts (winner TK-40)' "$LOG11" \
  && ok || bad "the park must be logged against the PR with the path and the winner"
HASH11=$(basename "$(mc_contested_file tproj src/x.ts)")
grep -qxF "contested o/r#41 $HASH11" "$ATT11" \
  && ok || bad "the park must be recorded once per (PR, hold) in the attempts ledger"
tick11
[ "$(grep -cxF "contested o/r#41 $HASH11" "$ATT11")" = 1 ] \
  && ok || bad "a second tick over the same hold must not add a second attempts line (got $(grep -cxF "contested o/r#41 $HASH11" "$ATT11"))"
[ "$(state_of 'o/r#41')" = BLOCKED_HUMAN ] && ok || bad "the park must survive the next tick (got $(state_of 'o/r#41'))"
[ "$(grep -c 'o/r#41 READY -> BLOCKED_HUMAN' "$LOG11")" = 1 ] \
  && ok || bad "the same-state re-park must log no second transition (got $(grep -c 'o/r#41 READY -> BLOCKED_HUMAN' "$LOG11"))"
[ "$(alerts11 'o/r#41')" = 0 ] \
  && ok || bad "a resolver-owned park must never page (ALERTS lines: $(alerts11 'o/r#41'))"

# 11c. THE RELEASE. PR 40 lands; every hold it wins is released and its losers go
# back to NEEDS_REBASE. A hold won by some OTHER PR is untouched.
hold11 src/y.ts TK-42 42 && ok || bad "fixture: the second hold (a different winner) must be written"
awk '/^conductor_settle\(\) \{/,/^\}/' "$DIR/bin/lib/mc/settle.sh" > "$T/settle.sh"
[ -s "$T/settle.sh" ] || bad "conductor_settle could not be extracted from bin/lib/mc/settle.sh"
# shellcheck source=/dev/null
. "$T/settle.sh"
declare -F conductor_settle >/dev/null && ok || bad "the extracted conductor_settle must be a complete function"
MERGES=1
mc_settle_merged() { printf '%s\n' "$*" >> "$T/settled.txt"; }
: > "$T/settled.txt"
mc_row_put 'o/r#40' READY "$NOW11" "$H1" "$H1" - clean https://github.com/o/r/pull/40
conductor_settle 'o/r#40' https://github.com/o/r/pull/40 tproj o/r ticket/TK-40 - - "$H1" "$H1" APPROVE CLEAN by:conductor
[ ! -e "$(mc_contested_file tproj src/x.ts)" ] \
  && ok || bad "the merged winner's hold must be gone after the settle"
[ -s "$(mc_contested_file tproj src/y.ts)" ] \
  && ok || bad "a hold whose winner_url is some other PR must survive this settle"
# A LOSER TWO HOLDS NAME IS NOT HANDED BACK BY THE FIRST (BH-587 fix round 2,
# inside mc_contested_release): src/y.ts still names PR 41, so the row stays
# parked and the library says which release deferred to which hold. The
# hand-back itself is asserted below, when the LAST hold goes.
[ "$(state_of 'o/r#41')" = BLOCKED_HUMAN ] \
  && ok || bad "a loser another live hold still names must stay parked (got $(state_of 'o/r#41'))"
grep -q 'contested: o/r#41 stays parked .* another live hold still names it (this release was src/x.ts)' "$LOG11" \
  && ok || bad "the deferred release must be logged with the PR and the path it was releasing"
[ "$(state_of 'o/r#40')" = MERGED ] && ok || bad "the winner's own row must be MERGED (got $(state_of 'o/r#40'))"
[ "$(wc -l < "$T/settled.txt")" = 1 ] \
  && ok || bad "the settle's own consequence block must still run exactly once (got $(wc -l < "$T/settled.txt"))"
[ "$(alerts11 contested)" = 0 ] \
  && ok || bad "the winner landing is the good outcome — releasing its holds must not page"
grep -q 'contested hold on src/x.ts released .*winner TK-40, losers 41: winner merged' "$LOG11" \
  && ok || bad "the release must be logged with the path, the winner and the losers"
# The hold that survived re-parks the same PR on the NEXT tick — one reason at a
# time, and the row is parked either way.
: > "$T/gh-writes.txt"
tick11
[ "$(reason_of 'o/r#41')" = "contested:src/y.ts (winner TK-42)" ] \
  && ok || bad "a loser of a second live hold must re-park on that hold (got '$(reason_of 'o/r#41')')"
[ -s "$T/gh-writes.txt" ] && bad "the re-park must buy no gh write: $(cat "$T/gh-writes.txt")" || ok
# …and releasing the LAST hold IS the hand-back: NEEDS_REBASE on the release
# reason, after which the row is classified from GitHub again like any other.
mc_contested_release "$(mc_contested_file tproj src/y.ts)" "winner merged"
[ "$(state_of 'o/r#41')" = NEEDS_REBASE ] \
  && ok || bad "a released loser with no hold left must go back to NEEDS_REBASE (got $(state_of 'o/r#41'))"
[ "$(reason_of 'o/r#41')" = "contested released: winner merged" ] \
  && ok || bad "the release reason must say the winner merged (got '$(reason_of 'o/r#41')')"
rm -f "$(mc_contested_file tproj src/y.ts)" "$T/h/flags/merge-conductor-merge"
tick11
[ "$(state_of 'o/r#41')" = READY ] \
  && ok || bad "with no live hold left the PR must be classified as any other (got $(state_of 'o/r#41') / '$(reason_of 'o/r#41')')"

# 11d. AN EXPIRED HOLD IS INERT. Liveness is decided per read, so a hold nobody
# deleted parks nothing once its window has passed.
hold11 src/x.ts TK-40 40 && ok || bad "fixture: the hold to expire must be written"
F11=$(mc_contested_file tproj src/x.ts)
jq --argjson c $((NOW11-100000)) '.created=$c' "$F11" > "$T/e.json" && mv -f "$T/e.json" "$F11"
mc_contested_live "$F11" && bad "fixture: the backdated hold must not be live" || ok
tick11
[ "$(state_of 'o/r#41')" = READY ] \
  && ok || bad "an expired hold must leave the PR classified as today (got $(state_of 'o/r#41'))"
case "$(reason_of 'o/r#41')" in
  contested*) bad "an expired hold must not park the PR (reason '$(reason_of 'o/r#41')')" ;;
  *) ok ;;
esac
[ "$(grep -c '^contested o/r#41 ' "$ATT11")" = 2 ] \
  && ok || bad "an expired hold must record no new contested attempt (want the 2 real parks, got $(grep -c '^contested o/r#41 ' "$ATT11"))"



echo "mc/rebase-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
