#!/bin/bash
# tests/dequeue-watch.bh-3719-test.sh — BH-3730 (BH-3719.4): the dequeue-watch
# lane end to end. Every case runs the SHIPPED bin/dequeue-watch.sh from a
# `cp -rs` scratch harness, with the fixture seam
# (tests/fixtures/dequeue-watch/fixture.sh) standing in for GitHub REST and the
# jobs worker, a gh shim on PATH, and stub lane-alert / lead-verdict /
# needs-human-hold / box-for / agent-call scripts in the scratch bin/. The libs
# under test are the real ones: attribute, classify, act, llm, gather, the
# dqw_* ledger verbs, verdicts, mc-stale-dequeue and the conductor lib.
# Every call lands in one ordered log, $F/requests.log (see the fixture header).
#
#   L0 switch off         L1 event record fails     L2 lock held
#   L3 GitHub budget low  L4 bounded tick runs      L5 seam is sandbox-only
#   L6 a lib is missing   L7 list unread            L8 PR cap
#   A1 batch-of-one rule break -> one fix round, tick 2 nothing (A1-count)
#   A2 bystander requeue (bisect, diff-touch, A2b no verdict, A2c mark present,
#      A2-unknown member files unread, A2-vd verdicts unread)
#   A3 scanner-fp brief   A4 unclassified hold      A5 LLM stamp before call
#   A6 unowned page (A6b owned, A6c left the list)  A7 flake
#   A8 main red wait, then requeue                  A9 stale event
#   A10 no GraphQL across every run
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/dequeue-watch.bh-3719-test.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
FX="$DIR/tests/fixtures/dequeue-watch"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $CASE: $1"; }

NOW=$(date -u +%s)   # the one clock read; payload ages are offsets from it
SLUG=example-org/cromford
HEAD=b49a1b832b0d294ee7a46325ac2ace79dc50d235
H12=${HEAD:0:12}
H="$T/h"; F="$T/fix"; LOG="$H/logs/dequeue-watch.log"; REQ="$F/requests.log"; ALL="$T/all-requests.log"
: > "$ALL"
CASE=setup

mkdir -p "$H" "$T/shim"
cp -rs "$DIR/bin" "$H/bin"
cp -rs "$DIR/catalog" "$H/catalog"
for s in lane-alert lead-verdict needs-human-hold box-for agent-call; do
  rm -f "$H/bin/$s.sh"
  {
    echo '#!/bin/bash'
    echo 'printf "SCRIPT %s %s\n" "$(basename "$0")" "$*" >> "$DQW_FIX_DIR/requests.log"'
  } > "$H/bin/$s.sh"
done
echo 'echo box-2' >> "$H/bin/box-for.sh"
echo 'printf "%s\n" "${AGENT_ANSWER:-semantic-test}" > "$5"' >> "$H/bin/agent-call.sh"
cat > "$T/shim/gh" <<'EOF'
#!/bin/bash
printf 'gh %s\n' "$*" >> "$DQW_FIX_DIR/requests.log"
case "$1 $2" in
  "api --paginate")
    n=$(printf '%s' "$3" | sed -n 's#.*/issues/\([0-9]*\)/comments.*#\1#p')
    [ -r "$DQW_FIX_DIR/comments-$n.json" ] && exec cat "$DQW_FIX_DIR/comments-$n.json" ;;
  "run view") [ -r "$DQW_FIX_DIR/log-$3.txt" ] && exec cat "$DQW_FIX_DIR/log-$3.txt" ;;
esac
exit 1
EOF
chmod +x "$T/shim/gh" "$H/bin/"{lane-alert,lead-verdict,needs-human-hold,box-for,agent-call}.sh

# ── fixture writers ───────────────────────────────────────────────────────────
rest() { mkdir -p "$F/rest"; cat > "$F/rest/$(printf '%s' "$1" | tr '/?&=' '____')"; }   # rest <path> < body
unrest() { rm -f "$F/rest/$(printf '%s' "$1" | tr '/?&=' '____')"; }
list_prs() {   # list_prs <num>... — both label lists carry these PRs
  local l
  for l in merge-queue dequeued; do
    printf '%s\n' "$@" | jq -sc 'map({number: ., pull_request: {url: "x"}, labels: [{name: "merge-queue"}, {name: "dequeued"}]})' \
      | rest "repos/$SLUG/issues?labels=$l&state=open&per_page=100"
  done
}
payload() {    # payload <num> <payload-file> <age_s>
  local at; at=$(date -u -d "@$((NOW - $3))" +%FT%TZ)
  jq -n --rawfile b "$2" --arg at "$at" --argjson n "$1" \
    '[{id: (9000 + $n), user: {login: "mergify[bot]"}, body: $b, created_at: $at, updated_at: $at}]' > "$F/comments-$1.json"
  jq -n --rawfile b "$2" '{body: $b}' | rest "repos/$SLUG/issues/comments/$((9000 + $1))"
}
pull() { jq -nc --arg h "$2" --arg r "ticket/bh-9$1" '{head: {sha: $h, ref: $r}, mergeable_state: "clean"}' | rest "repos/$SLUG/pulls/$1"; }
files() { rest "repos/$SLUG/pulls/$1/files?per_page=100" < "$2"; }
runs() { rest "repos/$SLUG/actions/runs?event=push&per_page=100" < "$FX/$1"; }
cilog() { cp "$1" "$F/log-$2.txt"; }

base() {       # base <case> — PR 101 of a batch of one, failing tests/lib-root-literal-ratchet on run 5001
  CASE="$1"
  local d
  for d in "$F" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/tmp"; do scratch_rm "$d" || exit 1; done
  mkdir -p "$F/rest" "$H/state/merge-conductor" "$H/logs"
  : > "$REQ"
  printf 'proj %s https://example.invalid - 5 box-2\n' "$SLUG" > "$H/fleet.conf"
  list_prs 101
  payload 101 "$FX/payload-dequeued-batch1.md" 120
  pull 101 "$HEAD"
  runs runs-batch1.json
  cilog "$FX/log-rule-break.txt" 5001
  jq -n --arg c "$(base64 -w0 < "$FX/sources-lib-root.txt")" '{content: $c, encoding: "base64"}' \
    | rest "repos/$SLUG/contents/tests/lib-root-literal-ratchet.bh-2613-test.sh?ref=main"
  files 101 "$FX/pr-files-101.json"
  echo MERGE > "$F/verdict"
  echo '{"statuses":[{"context":"lead-verdict","state":"success"}]}' | rest "repos/$SLUG/commits/$HEAD/status"
}
batch3() {     # batch3 <runs-file> — PR 101 dequeued from the #101+#102+#103 batch, run 5003
  payload 101 "$FX/payload-dequeued-batch3.md" 120
  runs "$1"
  cilog "$FX/log-rule-break.txt" 5003
}

SUMRE='^[0-9-]+T[0-9:]+Z (tick |off$|disabled$|locked$|gh-budget$|lib-missing )'
sums() { grep -cE "$SUMRE" "$LOG" 2>/dev/null || true; }
lastsum() { grep -E "$SUMRE" "$LOG" 2>/dev/null | tail -1; }
fixrounds() { local r; r=$(grep -F 'JOBS POST /api/fix-rounds' "$REQ"); printf '%s\n' "$r"; }
cnt() { grep -cF -- "$1" "$REQ" 2>/dev/null || true; }
# run_lane [VAR=val...] — the shipped entry in a clean environment, sandboxed,
# with the fixture seam. Every run must write exactly one summary line. The lane
# ships observe-only (BH-3859), so these cases set DEQUEUE_WATCH_ACT=1 BEFORE
# "$@" (a case can still pass DEQUEUE_WATCH_ACT=0); the dark default is pinned
# by tests/dequeue-watch-ship-dark.bh-3859-test.sh.
run_lane() {
  local b; b=$(sums)
  env -i PATH="$T/shim:$PATH" HOME="$T" HARNESS="$H" JOBS_URL= HARNESS_SECRET=test-secret \
    HARNESS_TEST_SANDBOX=1 DEQUEUE_WATCH_FIXTURE="$FX/fixture.sh" DQW_FIX_DIR="$F" DEQUEUE_WATCH_ACT=1 "$@" \
    bash "$H/bin/dequeue-watch.sh" > "$T/lane.out" 2> "$T/lane.err"
  RC=$?
  [ "$(( $(sums) - b ))" = 1 ] && ok || bad "wanted exactly one summary line, got $(( $(sums) - b )); log: $(tail -5 "$LOG" 2>/dev/null | tr '\n' '|') err: $(head -c 600 "$T/lane.err")"
  [ "$RC" = 0 ] && ok || bad "the lane exited $RC"
  cat "$REQ" >> "$ALL" 2>/dev/null
}
eq() { [ "$2" = "$3" ] && ok || bad "$1: got '$2', wanted '$3'"; }
has() { grep -qF -- "$2" "$LOG" 2>/dev/null && ok || bad "$1: no '$2' in the lane log: $(tail -5 "$LOG" 2>/dev/null | tr '\n' '|')"; }
ev() { jq -r "$1" "$F/db/events.jsonl" 2>/dev/null | head -1; }

# ── L0: the switch, before any read ──────────────────────────────────────────
base L0; mkdir -p "$H/flags"; touch "$H/flags/dequeue-watch-off"
run_lane
eq "request lines" "$(wc -l < "$REQ")" 0
lastsum | grep -qE ' off$' && ok || bad "last summary is '$(lastsum)', wanted ' off'"

# ── L1: the event record fails -> no comment, no fix round ───────────────────
base L1
run_lane EVENTS_FAIL=1
has "event-record-failed" event-record-failed
eq "fix-round POSTs" "$(cnt 'JOBS POST /api/fix-rounds')" 0
eq "requeues" "$(cnt 'FN mc_requeue_mergify')" 0
eq "lead requests" "$(cnt 'SCRIPT lead-verdict.sh')" 0
eq "claims" "$(cnt 'actions/claim')" 0
lastsum | grep -q ' recorded=0 ' && ok || bad "summary '$(lastsum)' should say recorded=0"

# ── L2: the lock is held -> ` locked`, no read ────────────────────────────────
base L2; mkdir -p "$H/locks"
exec 8>"$H/locks/dequeue-watch.lock"
flock -n 8 || bad "the test could not take the lock itself"
run_lane
exec 8>&-
lastsum | grep -qE ' locked$' && ok || bad "last summary is '$(lastsum)', wanted ' locked'"
eq "request lines under a held lock" "$(wc -l < "$REQ")" 0

# ── L3: GitHub budget low -> ` gh-budget`, no read ─────────────────────────────
base L3
run_lane GH_BUDGET_LOW=1
lastsum | grep -qE ' gh-budget$' && ok || bad "last summary is '$(lastsum)', wanted ' gh-budget'"
eq "request lines on a low budget" "$(wc -l < "$REQ")" 0

# ── L4: the bounded tick ──────────────────────────────────────────────────────
# The timeout itself is pinned by behaviour in
# tests/dequeue-watch-ship-dark.bh-3859-test.sh T1 (a slow tick yields exactly
# one ` tick timed-out` line); here the bounded wrapper still runs a full tick.
CASE=L4
bash -n "$DIR/bin/lib/dequeue-watch/gather.sh" && ok || bad "bin/lib/dequeue-watch/gather.sh does not parse"
base L4
run_lane
lastsum | grep -q ' tick projects=1 ' && ok || bad "summary '$(lastsum)' should be a tick over one project"

# ── L5: the seam is read only in the sandbox ──────────────────────────────────
base L5; : > "$H/fleet.conf"
b=$(sums)
env -i PATH="$T/shim:$PATH" HOME="$T" HARNESS="$H" JOBS_URL= DEQUEUE_WATCH_FIXTURE="$FX/fixture.sh" DQW_FIX_DIR="$F" \
  bash "$H/bin/dequeue-watch.sh" > "$T/lane.out" 2> "$T/lane.err"; rc=$?
eq "rc without the sandbox" "$rc" 0
[ -e "$F/fixture-sourced" ] && bad "the fixture was sourced without HARNESS_TEST_SANDBOX=1" || ok
eq "summary lines" "$(( $(sums) - b ))" 1
lastsum | grep -q ' tick projects=0 ' && ok || bad "summary '$(lastsum)' should be a tick over no project"

# ── L6: a lib is missing -> one warn, ` lib-missing`, rc 0 ─────────────────────
base L6
rm -f "$H/bin/lib/dequeue-watch/act.sh"
run_lane
ln -s "$DIR/bin/lib/dequeue-watch/act.sh" "$H/bin/lib/dequeue-watch/act.sh"
eq "lib-missing warns" "$(cnt 'SCRIPT lane-alert.sh --severity warn --id dqw-lib-missing dequeue-watch')" 1
lastsum | grep -qE ' lib-missing .*dqw_act' && ok || bad "last summary is '$(lastsum)', wanted ' lib-missing … dqw_act'"
eq "REST reads with a lib missing" "$(cnt 'REST ')" 0

# ── L7: the list is unread -> skip the project, never "no PRs" ───────────────
base L7
unrest "repos/$SLUG/issues?labels=merge-queue&state=open&per_page=100"
run_lane
lastsum | grep -q 'skip-project' && ok || bad "summary '$(lastsum)' should name skip-project"
eq "per-PR comment reads" "$(cnt 'gh api --paginate')" 0
eq "per-PR pull reads" "$(cnt "REST GET repos/$SLUG/pulls/")" 0

# ── L8: the cap -> one PR, one page-cut warn ──────────────────────────────────
base L8
list_prs 101 102
payload 102 "$FX/payload-dequeued-batch1.md" 120
pull 102 "$HEAD"
run_lane DEQUEUE_WATCH_PR_CAP=1
eq "PR payload reads" "$(cnt 'gh api --paginate')" 1
eq "page-cut warns" "$(cnt 'SCRIPT lane-alert.sh --severity warn --id dqw-page-cut:proj')" 1
lastsum | grep -q ' page-cut' && ok || bad "summary '$(lastsum)' should say page-cut"

# ── A1: batch of one, rule break -> exactly one fix round; tick 2 nothing ─────
base A1
run_lane
eq "fix-round POSTs" "$(cnt 'JOBS POST /api/fix-rounds')" 1
fixrounds | grep -qF 'FAIL: bin/lib/root-resolve.sh raised its root-literal count' && ok \
  || bad "the fix round's record_in does not carry the FAIL line"
fixrounds | grep -qF 'queue-dequeued' && ok || bad "the fix round's reason is not queue-dequeued"
eq "event attribution" "$(ev .attribution)" culprit
eq "event class" "$(ev .class)" rule-break
eq "requeues" "$(cnt 'FN mc_requeue_mergify')" 0
lastsum | grep -qE ' recorded=1 acted=1 ' && ok || bad "summary '$(lastsum)' should say recorded=1 acted=1"
: > "$REQ"
run_lane
eq "tick 2 fix-round POSTs" "$(cnt 'JOBS POST /api/fix-rounds')" 0
eq "tick 2 claims" "$(cnt 'actions/claim')" 0
has "tick 2" already-owned

base A1-count
run_lane ROUNDS_FAIL=1
eq "fix-round POSTs with the count unread" "$(cnt 'JOBS POST /api/fix-rounds')" 0
has "count unread" rounds-unreadable

# ── A2: bystander -> one requeue, no fix round ────────────────────────────────
base A2; batch3 runs-batch3-bisect-green.json
run_lane
eq "requeues" "$(cnt 'FN mc_requeue_mergify')" 1
eq "fix-round POSTs" "$(cnt 'JOBS POST /api/fix-rounds')" 0
eq "event attribution" "$(ev '.attribution + "/" + .attribution_how')" bystander/bisect

base A2-diff; batch3 runs-batch3.json
files 101 "$FX/pr-files-101-none.json"; files 102 "$FX/pr-files-102.json"; files 103 "$FX/pr-files-103.json"
run_lane
eq "requeues" "$(cnt 'FN mc_requeue_mergify')" 1
eq "event attribution" "$(ev '.attribution + "/" + .attribution_how')" bystander/diff-touch
eq "member file reads" "$(cnt "/files?per_page=100")" 3

base A2b; batch3 runs-batch3-bisect-green.json; rm -f "$F/verdict"
run_lane
eq "lead requests" "$(cnt 'SCRIPT lead-verdict.sh request')" 1
eq "requeues with no verdict" "$(cnt 'FN mc_requeue_mergify')" 0

base A2c; batch3 runs-batch3-bisect-green.json
printf 'requeued %s#101 %s %s\n' "$SLUG" "$HEAD" "$NOW" > "$H/state/merge-conductor/attempts.txt"
run_lane
eq "requeues with the mark present" "$(cnt 'FN mc_requeue_mergify')" 0

base A2-unknown; batch3 runs-batch3.json
files 101 "$FX/pr-files-101-none.json"   # 102 and 103 unread
run_lane
eq "requeues with member files unread" "$(cnt 'FN mc_requeue_mergify')" 0
eq "event attribution" "$(ev .attribution)" unknown

base A2-vd; batch3 runs-batch3-bisect-green.json
run_lane VERDICTS_FAIL=1
eq "claims with the verdicts unread" "$(cnt 'actions/claim')" 0
has "verdicts unread" verdict-unread

# ── A3: gitleaks -> scanner-fp brief ──────────────────────────────────────────
base A3; cilog "$FX/log-gitleaks.txt" 5001
run_lane
grep -F 'JOBS POST /api/fix-rounds' "$REQ" > "$T/a3.txt"
eq "fix-round POSTs" "$(wc -l < "$T/a3.txt")" 1
grep -qF 'Class: scanner-fp' "$T/a3.txt" && ok || bad "the brief does not say Class: scanner-fp"
grep -qF 'Never add an allowlist entry' "$T/a3.txt" && ok || bad "the brief does not carry the no-allowlist hint"

# ── A4: unclassified, no LLM -> hold + one critical line; tick 2 nothing ──────
base A4; cilog "$FX/log-empty.txt" 5001
run_lane DEQUEUE_WATCH_LLM=0
eq "holds" "$(cnt 'SCRIPT needs-human-hold.sh')" 1
eq "critical hold lines" "$(cnt 'SCRIPT lane-alert.sh --severity critical --id dqw-hold:proj:101:unclassified')" 1
eq "agent calls with the LLM off" "$(cnt 'SCRIPT agent-call.sh')" 0
: > "$REQ"
run_lane DEQUEUE_WATCH_LLM=0
eq "tick 2 holds" "$(cnt 'SCRIPT needs-human-hold.sh')" 0
eq "tick 2 critical lines" "$(cnt '--severity critical --id dqw-hold:')" 0

# ── A5: the rules leave it unclassified with FAIL lines -> stamp, then call ───
base A5
printf 'Build\tCompile\t2026-09-29T02:10:01.1000000Z FAIL: tsc found 3 errors in console-ui/src/lib/y.js\n' > "$T/log-unparsed.txt"
cilog "$T/log-unparsed.txt" 5001
run_lane AGENT_ANSWER=semantic-test
stamp=$(grep -nE '^JOBS PUT /api/dequeue-watch/events/state .*llm_attempted_at' "$REQ" | head -1 | cut -d: -f1)
call=$(grep -n '^SCRIPT agent-call.sh' "$REQ" | head -1 | cut -d: -f1)
eq "agent calls" "$(cnt 'SCRIPT agent-call.sh')" 1
[ -n "$stamp" ] && [ -n "$call" ] && [ "$stamp" -lt "$call" ] && ok \
  || bad "the llm_attempted_at stamp (line ${stamp:-none}) must come before the agent call (line ${call:-none})"
eq "event class" "$(ev '.class + "/" + .class_how')" semantic-test/llm
fixrounds | grep -qF 'tsc found 3 errors' && ok || bad "the LLM-classed fix round does not carry the FAIL line"

# ── A6: dequeued > 30 min and unowned -> one page; idempotent ─────────────────
base A6; payload 101 "$FX/payload-dequeued-batch1.md" 3600
run_lane CLAIM_FAIL=1
eq "unowned pages" "$(cnt "SCRIPT lane-alert.sh --severity critical --id dqw-unowned:proj:101:$H12")" 1
run_lane CLAIM_FAIL=1
eq "distinct unowned page ids over two ticks" "$(grep -oE 'dqw-unowned:[^ ]+' "$REQ" | sort -u | wc -l)" 1

base A6b; payload 101 "$FX/payload-dequeued-batch1.md" 3600
run_lane
eq "resolves of an owned head" "$(cnt "SCRIPT lane-alert.sh --resolve --id dqw-unowned:proj:101:$H12")" 1
eq "unowned pages of an owned head" "$(cnt '--severity critical --id dqw-unowned:')" 0

base A6c
run_lane
list_prs
: > "$REQ"
run_lane
eq "resolves once the PR left the list" "$(cnt "SCRIPT lane-alert.sh --resolve --id dqw-unowned:proj:101:$H12")" 1
eq "payload reads of a PR no longer listed" "$(cnt 'gh api --paginate')" 0

# ── A7: a later green rerun of the same batch -> flake ────────────────────────
base A7; runs runs-batch1-rerun-green.json
run_lane
eq "event class" "$(ev .class)" flake
eq "flake metrics" "$(cnt 'JOBS PUT /api/metrics/flakes')" 1
eq "requeues" "$(cnt 'FN mc_requeue_mergify')" 1
eq "fix-round POSTs" "$(cnt 'JOBS POST /api/fix-rounds')" 0

# ── A8: main red -> wait; main green -> the requeue ───────────────────────────
base A8; touch "$F/main-red"
run_lane
eq "requeues while main is red" "$(cnt 'FN mc_requeue_mergify')" 0
eq "fix rounds while main is red" "$(cnt 'JOBS POST /api/fix-rounds')" 0
eq "waiting main-red-wait rows" "$(cat "$F/db/actions/"* | jq -s 'map(select(.action == "main-red-wait" and .status == "waiting")) | length')" 1
rm -f "$F/main-red"
: > "$REQ"
run_lane
eq "requeues once main is green" "$(cnt 'FN mc_requeue_mergify')" 1
eq "fix rounds once main is green" "$(cnt 'JOBS POST /api/fix-rounds')" 0

# ── A9: the PR moved past the dequeued sha -> stale-event ─────────────────────
base A9; pull 101 0123456789abcdef0123456789abcdef01234567
run_lane
has "moved head" stale-event
eq "event records" "$(cnt 'JOBS POST /api/dequeue-watch/events ')" 0
eq "claims" "$(cnt 'actions/claim')" 0
lastsum | grep -q ' stale=1 ' && ok || bad "summary '$(lastsum)' should say stale=1"

# ── A10: no GraphQL anywhere ─────────────────────────────────────────────────
CASE=A10
grep -q '^REST GET ' "$ALL" && ok || bad "the request log holds no REST read, so the scan proves nothing"
eq "graphql lines across every run" "$(grep -ci graphql "$ALL")" 0

echo "dequeue-watch: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
