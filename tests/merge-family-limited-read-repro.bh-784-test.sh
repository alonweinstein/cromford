#!/bin/bash
# tests/merge-family-limited-read-repro.bh-784-test.sh — BH-784 reproduction.
#
# THE DEFECT. `ST=$(gh pr view … 2>/dev/null)` leaves STATE empty on ANY
# failure, and the very next line reads `"" != OPEN` as a permanent fact about
# the PR: `rm -f "$Q/$F"` drops the queue row and the ledger records
# "dequeued: PR state=". A rate-limited or 403'd read is not an answer, and a
# queue that deletes rows on silence loses approved work with one log line.
# Same class in bin/merge-sweep.sh, where a failed issue close still appends the
# PR to state/merge-sweep-done.txt so the issue stays open for ever.
#
# WHY DRIVEN AND NOT GREPPED. The claim is about which branch a failed read
# takes inside a live loop — the row file's existence after the run and what the
# log says about it. A regex over the source cannot see either.
#
# Self-contained on purpose: it sources only tests/lib/scratch.sh, so it runs
# unchanged at the merge base (bin/repro-gate.sh overlays *-test.sh files only).
# The stub gh answers BOTH argv shapes — the old `pr view` one and the REST
# `api -i -X GET repos/<slug>/pulls/<n>` one — so the SAME file is the red proof
# before the fix and the green proof after it.
# Run from anywhere: tests/merge-family-limited-read-repro.bh-784-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/h/logs" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" \
         "$T/h/state/merge-queue/demo-os" "$T/fakebin"
cp -r "$DIR/bin" "$T/h/bin"
printf 'demo-os example-org/demo-os - - 2 box-demo\n' > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh";           chmod +x "$T/h/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/deploy-request.sh"; chmod +x "$T/h/bin/deploy-request.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/lander.sh";         chmod +x "$T/h/bin/lander.sh"
# No coordination worker: every jobs-client read fails open, exactly as on a box
# whose hub is unreachable. That keeps this fixture about the gh read alone.
# ONE exception (BH-1525): the verdicts read is a merge precondition that fails
# CLOSED, so it answers "nothing stands on this head" — without it the fixture
# would stop at the block gate and never reach the merge verb it is about. The
# head below is a full sha for the same reason: a verdict row binds to one, and
# a head that is not one is unverifiable, which also skips the merge.
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
case "${!#}" in */api/verdicts\?*) printf '{"standing":null,"rows":[]}\n200\n' ;;
  # BH-1606: the seeded lead row, the other fail-closed merge precondition.
  */api/settings/lead_pr_authors) printf '{"setting":{"key":"lead_pr_authors","value":"operator"}}\n200\n' ;;
  # TEST-CHANGE BH-4153: paused-*/automerge-disabled* are read DB-first now; an unreachable
  # worker (exit 7) with no cache reads a stop switch as ON, so the merge verb is never
  # reached. No row (404) is the "nobody set it" this fixture means.
  */api/flags/*) printf '{"error":"not found"}\n404\n' ;;
  *) exit 7 ;; esac
CURL
chmod +x "$T/fakebin/curl"

# The stub: demo-os is a plain repo (no merge_queue ruleset rule), and every
# read of PR 12 is RATE-LIMITED. `pr view` answers the way GraphQL answered
# during #768 — nothing on stdout, non-zero rc. The REST arm answers the 403
# the same outage produces over `gh api -i`.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-argv.log"
case "\$*" in
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n'; exit 0 ;;  # BH-1668: the PR's own thread (no HOLD), read over REST by to_merge_hold
  "api repos/example-org/demo-os/rulesets/4"*)
    echo '{"id":4,"name":"main","enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"pull_request"}]}' ;;
  "api repos/example-org/demo-os/rulesets"*) echo 4 ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/12"*|*"api -i -X GET repos/example-org/demo-os/issues/12"*)
    printf 'HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\n\r\n'
    printf '{"message":"You have exceeded a secondary rate limit. Please wait a few minutes before you try again.","documentation_url":"https://docs.github.com/rest"}\n'
    exit 1 ;;
  *"api -i"*)
    printf 'HTTP/1.1 403 Forbidden\r\n\r\n{"message":"API rate limit exceeded"}\n'; exit 1 ;;
  *"pr view"*) exit 1 ;;
  *"pr merge"*) echo "MERGE ATTEMPTED: \$*" >> "$T/gh-writes.log"; exit 0 ;;
  *"rate_limit"*) echo '{"resources":{"core":{"remaining":0}}}' ;;
  *"auth status"*) exit 0 ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

Q="$T/h/state/merge-queue/demo-os"
: > "$Q/12"
: > "$T/gh-argv.log"; : > "$T/gh-writes.log"
# FLEET_CONF is explicit: bin/fleet-conf.sh prefers /root/harness/fleet.conf
# over the one next to $HARNESS, so on the hub (which HAS a live harness) the
# fixture would otherwise be answered from the real fleet registry.
( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_TEST_SANDBOX=1 \
         FLEET_CONF="$T/h/fleet.conf"
  bash "$DIR/bin/merge-queue.sh" demo-os >/dev/null 2>&1 )
LOG="$T/h/logs/merge-queue.log"

# ── 1. THE ROW SURVIVES AN UNREADABLE PR ────────────────────────────────────
# This is the whole defect. Nothing about the PR was learned this tick, so
# nothing about the PR may be decided this tick.
[ -f "$Q/12" ] && ok \
  || bad "a queued row must SURVIVE a rate-limited read — it was deleted. log: $(cat "$LOG" 2>/dev/null)"

# ── 2. AND THE LEDGER IS NOT TOLD THE PR CLOSED ─────────────────────────────
# "dequeued: PR state=" is the lie the empty read writes down. A permanent
# record derived from a read that never answered is worse than the dropped row,
# because the next pass believes it.
! grep -q 'dequeued' "$LOG" 2>/dev/null && ok \
  || bad "an unreadable PR must not be recorded as dequeued: $(grep dequeued "$LOG" 2>/dev/null)"

# ── 3. THE TICK SAYS SO, OUT LOUD ───────────────────────────────────────────
# Silence and "handled" look identical in a log. The row was left alone; the
# line has to say that, or the next operator reads a gap.
grep -q 'left queued this tick' "$LOG" 2>/dev/null && ok \
  || bad "the tick must log that the row was left queued: $(cat "$LOG" 2>/dev/null)"

# ── 4. NOTHING WAS MERGED ON THE STRENGTH OF A FAILED READ ──────────────────
[ ! -s "$T/gh-writes.log" ] && ok \
  || bad "no merge may be attempted for a PR whose state could not be read: $(cat "$T/gh-writes.log")"

# ════════════════════════════════════════════════════════════════════════════
# CASE B — bin/merge-sweep.sh: the done-marker written BEFORE the issue close
# ════════════════════════════════════════════════════════════════════════════
# THE SECOND HALF OF THE DEFECT. `sweep_record "$PR" merged` appends the PR to
# state/merge-sweep-done.txt at the TOP of the merged branch, and the issue
# close-out runs thirty lines further down. sweep_seen reads that file for ever,
# so a close that 403s leaves the record permanently done with the issue still
# open — the sweep will never look at it again, and nothing in the fleet is left
# to notice. The order has to be: comment, close, re-read, THEN the marker.
mkdir -p "$T/h/state" "$T/h/tmp" "$T/tmp"
SREC="$T/h/builds/pool-issuer-IS-9-202609180003"; mkdir -p "$SREC"
SPR="https://github.com/example-org/issuer/pull/9"
echo "PR_CREATED $SPR" > "$SREC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$SREC/review.md"
printf 'demo-os example-org/demo-os - - 2 box-demo\nissuer example-org/issuer - - - box-issuer\n' > "$T/h/fleet.conf"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/codegraph-ensure.sh"; chmod +x "$T/h/bin/codegraph-ensure.sh"

# The stub for case B: PR 9 is an APPROVEd harness PR that MERGES, and the issue
# close FAILS on both argv shapes — `gh issue close` non-zero, PATCH /issues/9
# a 403. Everything else answers the happy path, so the only thing under test is
# what the sweep records when the close does not land.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-argv-b.log"
case "\$*" in
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n'; exit 0 ;;  # BH-1668: the PR's own thread (no HOLD), read over REST by to_merge_hold
  *"issue close"*) exit 1 ;;
  *"api -i -X PATCH repos/example-org/issuer/issues/9"*)
    printf 'HTTP/1.1 403 Forbidden\r\n\r\n{"message":"API rate limit exceeded"}\n'; exit 1 ;;
  *"api -i -X POST repos/example-org/issuer/issues/9/comments"*)
    printf 'HTTP/1.1 201 Created\r\n\r\n{"id":1}\n'; exit 0 ;;
  *"api -i -X GET repos/example-org/issuer/issues/9"*)
    printf 'HTTP/1.1 200 OK\r\n\r\n{"state":"open"}\n'; exit 0 ;;
  *v3.diff*)
    printf 'HTTP/1.1 200 OK\r\n\r\n+++ b/src/x.ts\n+const a = 1;\n'; exit 0 ;;
  # BH-2477: the merge close-out only closes an issue its PR body names with a
  # closing keyword, so the fixture PR says Closes #9 to reach the close path.
  *"api -i -X GET repos/example-org/issuer/pulls/9"*)
    printf 'HTTP/1.1 200 OK\r\n\r\n'
    if [ -e "$T/merged9" ]; then S=closed; M='"2026-09-18T00:00:00Z"'; else S=open; M=null; fi
    printf '{"state":"%s","merged_at":%s,"head":{"sha":"aaaa111122223333444455556666777788889999","ref":"ticket/is-9"},"base":{"ref":"main"},"labels":[],"mergeable":true,"mergeable_state":"clean","user":{"login":"app/cromford","type":"Bot"},"merge_commit_sha":"cccc3333","body":"harness PR body. Closes #9"}\n' "\$S" "\$M"
    exit 0 ;;
  *"pr view"*"mergeCommit"*) [ -e "$T/merged9" ] && echo cccc3333; exit 0 ;;
  # The five-field decision read and the one-field post-merge read share the
  # word "state", so the wider pattern has to be matched FIRST or the post-merge
  # read gets a five-field answer and never equals MERGED — which would make the
  # sweep take its failure branch and this case prove nothing.
  *"pr view"*"--json state,mergeStateStatus"*)
    if [ -e "$T/merged9" ]; then echo "MERGED CLEAN app/cromford aaaa111122223333444455556666777788889999 2026-09-18T00:00:00Z"
    else echo "OPEN CLEAN app/cromford aaaa111122223333444455556666777788889999 "; fi; exit 0 ;;
  *"pr view"*"--json state"*)
    if [ -e "$T/merged9" ]; then echo MERGED; else echo OPEN; fi; exit 0 ;;
  *"pr view"*"headRefOid"*) echo aaaa111122223333444455556666777788889999; exit 0 ;;
  *"pr view"*"headRefName"*) echo ticket/is-9; exit 0 ;;
  *"pr view"*) echo ""; exit 0 ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n'; exit 0 ;;
  *"pr merge"*) touch "$T/merged9"; echo "MERGE ATTEMPTED: \$*" >> "$T/gh-writes-b.log"; exit 0 ;;
  *"api repos/example-org/issuer -q .id"*) echo 1; exit 0 ;;
  # BH-1575: the same token probe through gh_rest (bin/lib/sweep-reads.sh).
  "api -i -X GET repos/example-org/issuer") printf 'HTTP/1.1 200 OK\r\n\r\n{"id":1}\n'; exit 0 ;;
  # BH-1526: the merge-time HOLD reads the ticket through bin/lib/hold.sh (plain
  # REST, like the resolver). Issue 9 is open, labelled and unheld, so the gate
  # answers "merge as today" and case B still reaches the merge verb.
  *"repos/example-org/issuer/issues/9/comments?per_page"*) echo '[]'; exit 0 ;;
  "api repos/example-org/issuer/issues/9") echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"IS-9","body":"scope"}'; exit 0 ;;
  *"actions/runs?head_sha="*) printf 'completed|success\n'; exit 0 ;;
  *"api -i"*) printf 'HTTP/1.1 404 Not Found\r\n\r\n{"message":"no route"}\n'; exit 0 ;;
  *"rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"auth token"*) echo faketoken ;;
  *"auth status"*) exit 0 ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
: > "$T/gh-argv-b.log"; : > "$T/gh-writes-b.log"; rm -f "$T/merged9"
: > "$T/h/state/merge-sweep-done.txt"
( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_TEST_SANDBOX=1 GHFX="$T" \
         TMPDIR="$T/tmp" FLEET_CONF="$T/h/fleet.conf" SWEEP_MERGE_SETTLE=0 \
         HARNESS_SECRET=s JOBS_URL=https://jobs.test   # BH-1525: the verdicts read needs a client that can ask
  bash "$DIR/bin/merge-sweep.sh" >/dev/null 2>&1 )
SLOG="$T/h/logs/merge-sweep.log"

# ── 5. THE MERGE VERB RAN AT ALL ────────────────────────────────────────────
# Without this the assertions below pass on a fixture that never reached the
# code under test, which is the failure mode that makes a red proof worthless.
[ -s "$T/gh-writes-b.log" ] && ok \
  || bad "case B fixture never reached the merge verb — nothing below is proven. log: $(cat "$SLOG" 2>/dev/null)"

# ── 6. THE RECORD IS NOT STAMPED DONE OVER AN ISSUE THAT IS STILL OPEN ──────
# This is the defect. merge-sweep-done.txt is permanent (sweep_seen reads it for
# ever), so a PR written into it before a close that failed is a ticket nothing
# in the fleet will ever close.
! grep -qxF "$SPR" "$T/h/state/merge-sweep-done.txt" 2>/dev/null && ok \
  || bad "a merge whose issue close FAILED must not be recorded done — it was. log: $(cat "$SLOG" 2>/dev/null)"

# ── 7. AND THE DEFERRAL IS LOUD ─────────────────────────────────────────────
grep -q 'close deferred to next sweep' "$SLOG" 2>/dev/null && ok \
  || bad "a deferred close must say so in the log: $(cat "$SLOG" 2>/dev/null)"

# ── 8. THE RECORD CARRIES THE DEBT, SO THE NEXT PASS CAN PAY IT ─────────────
[ -f "$SREC/issue-close-owed" ] && ok \
  || bad "the record must be marked as owing a close, or the retry has nothing to find"

# REPRO_DEBUG=1 prints case B's argv log. The scratch tree is removed on exit, so
# without this a fixture that never reached the code under test looks exactly
# like one that reached it and passed — which is how a red proof goes vacuous.
[ -n "${REPRO_DEBUG:-}" ] && { echo "=== argv-b ==="; cat "$T/gh-argv-b.log"; }
echo "merge-family-limited-read-repro: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
