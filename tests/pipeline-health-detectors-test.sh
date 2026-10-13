#!/bin/bash
# tests/pipeline-health-detectors-test.sh — the two 2026-09-12 detectors in
# bin/pipeline-health.sh, extracted VERBATIM by their markers and driven with a
# gh shim, a stub ledger and a recording alert().
#
#   sweep should have landed: an APPROVE'd, OPEN, CLEAN PR that has sat that
#     way >30m pages, naming the record and the sweep's last log line about it
#     (or that the sweep never logged it — the silence that cost 10 hours).
#   starved project: an issue-driven project with launchable ai-build issues,
#     nothing running, nothing queued, no build row in >2h pages once.
#
# Run from anywhere: tests/pipeline-health-detectors-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/fakebin" "$T/builds"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }

awk '/^# >>> sweep should have landed/{f=1;next} /^# <<< sweep should have landed/{exit} f' "$DIR/bin/pipeline-health.sh" > "$T/c1.sh"
awk '/^# >>> starved project/{f=1;next} /^# <<< starved project/{exit} f' "$DIR/bin/pipeline-health.sh" > "$T/c2.sh"
awk '/^# >>> stalepr detector/{f=1;next} /^# <<< stalepr detector/{exit} f' "$DIR/bin/pipeline-health.sh" > "$T/c3.sh"
[ -s "$T/c1.sh" ] && [ -s "$T/c2.sh" ] && [ -s "$T/c3.sh" ] && ok
cp "$DIR/bin/lib/gh-repo-token.sh" "$T/bin/lib/"
cp "$DIR/bin/alert-line.sh" "$T/bin/"  # TEST-CHANGE: BH-2365 — converted writers call bin/alert-line.sh
cp "$DIR/bin/lib/gh-budget.sh" "$T/bin/lib/"
# TEST-CHANGE (BH-782): bin/lib/gh-pr-list.sh reads REST through the contract
# lib now. Without gh-rest.sh beside it every REST list answers 75 "no contract
# lib on this box" and the all-mappable closed-PR list never happens.
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/bin/lib/"
# TEST-CHANGE (BH-1585): the sweep-landed check reads the record's PR through
# bin/lib/pr-terminal.sh and the starved check lists over bin/lib/gh-rest-list.sh;
# bin/pipeline-health.sh sources both, so the driver below does too.
cp "$DIR/bin/lib/pr-terminal.sh" "$DIR/bin/lib/gh-rest-list.sh" "$T/bin/lib/"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
# fleet-conf stub: ts is issue-driven (prefix "-"), bd is an in-app board.
cat > "$T/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1 $2" in
  "ts board_prefix") echo "-" ;;  "ts repo") echo "o/r" ;;
  "bd board_prefix") echo "/api/board" ;; "bd repo") echo "o/b" ;;
esac
SH
chmod +x "$T/bin/fleet-conf.sh"
# gh shim driven by files under $T: repo visibility, PR state, issue + PR lists.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
case "$*" in
  "api repos/o/r -q .id") [ -f "$T/blind" ] && exit 1; exit 0 ;;
  # TEST-CHANGE (BH-782): the stale-PR detector's list is all-mappable, so it is
  # a REST read through bin/lib/gh-rest.sh (`gh api -i`) and a REST failure is no
  # longer retried over `gh pr list`. $T/prs-rest.json is that answer, in REST
  # shape; $T/prs.json still feeds the GraphQL lists the other detectors make.
  *"/pulls?state="*)
    printf 'HTTP/2.0 200\r\n\r\n'
    cat "$T/prs-rest.json" 2>/dev/null || echo '[]' ;;
  # TEST-CHANGE (BH-1585): the per-record PR read (sweep landed) and the two
  # starved-project lists are REST now. Same fixture files — $T/prstate,
  # $T/issues.json, $T/prs.json — answered in the REST shape the lanes read.
  *"repos/o/r/pulls/"[0-9]*)
    read -r s m h < "$T/prstate"
    printf 'HTTP/2.0 200\r\n\r\n'
    jq -nc --arg s "$s" --arg m "$m" --arg h "$h" '{state: (if $s == "OPEN" then "open" else "closed" end),
      merged: ($s == "MERGED"), merged_at: (if $s == "MERGED" then "2026-01-01T00:00:00Z" else null end),
      mergeable_state: ($m | ascii_downcase), user: {login: "operator"}, head: {ref: "b", sha: $h}}' ;;
  *"repos/o/r/issues "*)
    printf 'HTTP/2.0 200\r\n\r\n'
    jq -c 'map(. + {state: (.state | ascii_downcase)})' "$T/issues.json" ;;
  *"repos/o/r/pulls -f"*)
    printf 'HTTP/2.0 200\r\n\r\n'
    jq -c 'map({number, title, body, head: {ref: .headRefName}})' "$T/prs.json" ;;
  "api repos/"*|*"api -i"*) exit 1 ;;
  *"api rate_limit"*)
    now=$(date +%s)
    printf '{"resources":{"core":{"remaining":%s,"limit":5000,"reset":%s},"graphql":{"remaining":5000,"limit":5000,"reset":%s}}}' "${GH_BUDGET_CORE_REMAINING:-4000}" "$((now + 3600))" "$((now + 3600))"
    ;;
  *"pr view"*)            cat "$T/prstate" ;;
  *"issue list"*)         cat "$T/issues.json" ;;
  *"pr list"*)            cat "$T/prs.json" ;;
  *) echo "" ;;
esac
SH
chmod +x "$T/fakebin/gh"
echo '[]' > "$T/prs-rest.json"

# The driver: the block runs with the real lib, a recording alert(), and a
# stub ledger whose answers come from files.
drive() { # drive <block> [env...]
  local blk="$1"; shift
  : > "$T/alerts.txt"; : > "$T/gh.txt"; : > "$T/digest.txt"
( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt" GH_BUDGET_TTL_S=0; unset GH_TOKEN
    env "$@" bash -c '
      set -uo pipefail
      H="$T"; NOW=$(date +%s); PROJECTS="ts bd"
      STAMP() { echo TS; }
      alert() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/alerts.txt"; }
      alert_digest() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/digest.txt"; }
      # The registry reader, stubbed: the conductor cadence row (1n) is the only knob read here.
      # Keyed on the PROJECT that owns o/r (ts, per the fleet-conf.sh stub): the
      # slug resolves to its project through bin/fleet-conf.sh, and a lookup that
      # lands on no project reads no cadence (review round 2 of #2215).
      lane_knob() { [ "$1 $2 ${3:-}" = "merge-conductor MC_TICK_SECS ts" ] && printf "%s" "${FIX_MC_TICK_SECS:-}"; return 0; }
      job_verdict() { [ -f "$T/ledger-verdict" ] && { cat "$T/ledger-verdict"; return 0; }; return 2; }
      _jobs_req() { [ -f "$T/jobs.json" ] || return 1; cat "$T/jobs.json"; }
      queue_list() { [ -f "$T/queue.tsv" ] || return 1; cat "$T/queue.tsv"; }
      . "$T/bin/lib/gh-repo-token.sh"
      . "$T/bin/lib/gh-pr-list.sh"
      . "$T/bin/lib/gh-budget.sh"
      . "$T/bin/lib/gh-rest-list.sh"
      . "$T/bin/lib/pr-terminal.sh"
      . "$0"' "$T/$blk.sh" 2>"$T/err.txt" )
}

# ============================================================================
# c1. sweep should have landed
# ============================================================================
REC="$T/builds/pool-ts-TK-269-202609120001"; mkdir -p "$REC"
echo "PR_CREATED https://github.com/o/r/pull/7" > "$REC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
echo "OPEN CLEAN headsha" > "$T/prstate"
: > "$T/state/merge-sweep-done.txt"; : > "$T/logs/merge-sweep.log"; rm -f "$T/state/sweep-clean-seen.txt" "$T/blind"

# 1a. first sighting: no page, the (PR, head) stamp is written
drive c1
[ ! -s "$T/alerts.txt" ] && grep -q "pull/7 headsha" "$T/state/sweep-clean-seen.txt" \
  && ok || bad "first CLEAN sighting must stamp, not page: alerts=$(cat "$T/alerts.txt") seen=$(cat "$T/state/sweep-clean-seen.txt" 2>/dev/null) err=$(cat "$T/err.txt")"
# 1b. still there 30m later, and nothing ever mentioned it: THE page
# TEST-CHANGE (2026-09-27, sweepstall reads the conductor): the silence is now
# the MERGE CONDUCTOR's — no pr-state.tsv row — not logs/merge-sweep.log, which
# nothing has written since the sweep's cron line went (~09-23). Same page, same
# record, same akey; only the named silence moved to the lane that merges.
# tests/sweepstall-conductor-test.sh pins the full state table.
sed -i -E "s/ [0-9]+$/ $(( $(date +%s) - 1900 ))/" "$T/state/sweep-clean-seen.txt"
drive c1
grep -q "^3600|sweepstall:o/r#7|" "$T/alerts.txt" && grep -q "no conductor row for this PR — the silent-skip shape" "$T/alerts.txt" \
  && grep -q "the conductor logged no reason for this PR" "$T/alerts.txt" \
  && grep -q "record pool-ts-TK-269-202609120001" "$T/alerts.txt" \
  && ok || bad "30m-old CLEAN APPROVE did not page with the record and the silence: $(cat "$T/alerts.txt")"
# 1c. the conductor DID log something about it: that line is quoted
# TEST-CHANGE (2026-09-27): the quoted line is the conductor's last line about
# the PR (logs/merge-conductor.log), never the retired sweep's — a sweep line
# for the PR is present and must NOT be quoted.
echo "2026-09-12 15:16:46Z https://github.com/o/r/pull/7 skipped: mergeState=UNSTABLE (will retry)" >> "$T/logs/merge-sweep.log"
echo "2026-09-12 15:16:46Z o/r#7 skipped: mergeState=UNSTABLE (will retry)" >> "$T/logs/merge-conductor.log"
drive c1
grep -q "last merge-conductor.log line: 2026-09-12 15:16:46Z o/r#7 skipped: mergeState=UNSTABLE" "$T/alerts.txt" \
  && ! grep -q "merge-sweep.log" "$T/alerts.txt" \
  && ok || bad "the conductor's last line about the PR was not quoted (or the sweep's was): $(cat "$T/alerts.txt")"
: > "$T/logs/merge-conductor.log"; : > "$T/logs/merge-sweep.log"
# 1d. the ledger's verdict wins when it has one: BLOCK there means no page
printf 'BLOCK\t2\tclaude\t-\tj1\t-' > "$T/ledger-verdict"
drive c1
[ ! -s "$T/alerts.txt" ] && ok || bad "a ledger BLOCK must not page: $(cat "$T/alerts.txt")"
rm -f "$T/ledger-verdict"
# 1e. not CLEAN any more: no page, and the stamp is forgotten so a later CLEAN restarts the clock
echo "OPEN BLOCKED headsha" > "$T/prstate"
drive c1
[ ! -s "$T/alerts.txt" ] && ! grep -q "pull/7" "$T/state/sweep-clean-seen.txt" \
  && ok || bad "a non-CLEAN PR must clear its stamp: alerts=$(cat "$T/alerts.txt") seen=$(cat "$T/state/sweep-clean-seen.txt")"
echo "OPEN CLEAN headsha" > "$T/prstate"
# 1f. a new head restarts the clock
echo "https://github.com/o/r/pull/7 oldhead $(( $(date +%s) - 9000 ))" > "$T/state/sweep-clean-seen.txt"
drive c1
[ ! -s "$T/alerts.txt" ] && grep -q "pull/7 headsha" "$T/state/sweep-clean-seen.txt" \
  && ok || bad "a moved head must restamp, not page on the old head's age: $(cat "$T/alerts.txt")"
# 1g. ledgered by the sweep = handled, whatever gh says
echo "https://github.com/o/r/pull/7" > "$T/state/merge-sweep-done.txt"
sed -i -E "s/ [0-9]+$/ $(( $(date +%s) - 9000 ))/" "$T/state/sweep-clean-seen.txt"
drive c1
[ ! -s "$T/alerts.txt" ] && ok || bad "a sweep-ledgered PR must not page: $(cat "$T/alerts.txt")"
: > "$T/state/merge-sweep-done.txt"
# 1h. a record without APPROVE is not the sweep's to land
printf 'findings\nVERDICT: BLOCK\n' > "$REC/review.md"
drive c1
[ ! -s "$T/alerts.txt" ] && ok || bad "a BLOCK record must not page: $(cat "$T/alerts.txt")"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
# 1i. the repo is invisible to every token: the invisible-repo ALERT, not a
#     sweepstall guess, and no gh pr view is attempted
touch "$T/blind"; : > "$T/logs/ALERTS.log"; rm -f "$T"/flags/alerted-repo-invisible-*
drive c1
grep -q "\[pipeline-health\] repo o/r is INVISIBLE to the default gh token" "$T/logs/ALERTS.log" \
  && ! grep -q "pr view" "$T/gh.txt" && ! grep -qE "pulls/[0-9]" "$T/gh.txt" && [ ! -s "$T/alerts.txt" ] \
  && ok || bad "invisible repo must page as such: ALERTS=$(cat "$T/logs/ALERTS.log") gh=$(cat "$T/gh.txt") alerts=$(cat "$T/alerts.txt")"
rm -f "$T/blind"
# 1j. A ROW IN ANY STATE BUT READY IS THE CONDUCTOR'S (2026-09-27).
# TEST-CHANGE: Lane D (2026-09-24) paged this HEAD_MOVED row, naming it. The
# 09-26 flood (816 pages over 69 PRs) was exactly that shape: PRs the conductor
# was holding on purpose, re-paged by a second lane. The conductor's own STUCK
# TTL owns every non-READY state now, so this block stays quiet; 1j2 still pins
# that a stall it DOES report names the conductor's row and last line.
mkdir -p "$T/state/merge-conductor"
printf 'o/r#7\tHEAD_MOVED\t2026-09-24T18:40:00Z\theadsha\toldsha\t-\tre-review deferred — CI none\thttps://github.com/o/r/pull/7\n' > "$T/state/merge-conductor/pr-state.tsv"
echo "2026-09-24 18:41:00Z o/r#7 re-review deferred — CI none on headsha" > "$T/logs/merge-conductor.log"
echo "https://github.com/o/r/pull/7 headsha $(( $(date +%s) - 1900 ))" > "$T/state/sweep-clean-seen.txt"
drive c1
[ ! -s "$T/alerts.txt" ] && [ ! -s "$T/digest.txt" ] \
  && ok || bad "a HEAD_MOVED row is the conductor's (its STUCK TTL pages), not a sweepstall: alerts=$(cat "$T/alerts.txt") digest=$(cat "$T/digest.txt" 2>/dev/null)"
# 1j2. A READY row with nothing holding it is "READY, no reason logged": the
#      conductor's own READY TTL owns it, so this goes to the warn digest (an
#      untriaged severity-warn beat, 1o) and never to a page (review of #2215).
printf 'o/r#7\tREADY\t2026-09-24T18:40:00Z\theadsha\theadsha\t-\tclean, approved, checks green\thttps://github.com/o/r/pull/7\n' > "$T/state/merge-conductor/pr-state.tsv"
echo "2026-09-24 18:41:00Z o/r#7 not enqueued this tick: another PR of ts held the project merge lock for 120s" > "$T/logs/merge-conductor.log"
drive c1
[ ! -s "$T/alerts.txt" ] && grep -q "^3600|sweepstall:o/r#7|.*conductor row READY since 2026-09-24T18:40:00Z (clean, approved, checks green).*last merge-conductor.log line: 2026-09-24 18:41:00Z o/r#7 not enqueued this tick" "$T/digest.txt" \
  && ok || bad "a READY row goes to the digest, not a page: alerts=$(cat "$T/alerts.txt") digest=$(cat "$T/digest.txt")"
# 1k. no conductor row at all IS the silent-skip shape, and it says so
: > "$T/state/merge-conductor/pr-state.tsv"; : > "$T/logs/merge-conductor.log"
drive c1
grep -q "no conductor row for this PR — the silent-skip shape" "$T/alerts.txt" \
  && ok || bad "a PR the conductor has no row for must be named the silent-skip shape: $(cat "$T/alerts.txt")"
# 1l. a STACKED_WAIT row is owned (the parent has not merged): no page
printf 'o/r#7\tSTACKED_WAIT\t2026-09-24T18:40:00Z\theadsha\theadsha\t-\tbased on ticket/x\thttps://github.com/o/r/pull/7\n' > "$T/state/merge-conductor/pr-state.tsv"
drive c1
[ ! -s "$T/alerts.txt" ] && ok || bad "a STACKED_WAIT PR is waiting on its parent, not stalled: $(cat "$T/alerts.txt")"
# 1l2. a STACKED_WAIT row left over from an OLDER head does not hide a stall on
#      the current head (lead MINOR 3 on #2215): the skip matches the head too
printf 'o/r#7\tSTACKED_WAIT\t2026-09-24T18:40:00Z\toldsha\toldsha\t-\tbased on ticket/x\thttps://github.com/o/r/pull/7\n' > "$T/state/merge-conductor/pr-state.tsv"
drive c1
grep -q "^3600|sweepstall:o/r#7|" "$T/alerts.txt" && ok || bad "a STACKED_WAIT row for an older head must not hide a stall on this head: $(cat "$T/alerts.txt")"
# 1m. the threshold is ten minutes now, not thirty
: > "$T/state/merge-conductor/pr-state.tsv"
echo "https://github.com/o/r/pull/7 headsha $(( $(date +%s) - 700 ))" > "$T/state/sweep-clean-seen.txt"
drive c1
grep -q "^3600|sweepstall:o/r#7|" "$T/alerts.txt" && ok || bad "a CLEAN APPROVE unqueued for >10m must page: $(cat "$T/alerts.txt")"
# 1n. the threshold is max(SWEEPSTALL_SECS, 2 x the conductor's mc_tick_secs):
#     a project ticking every 10 min is not stalled after 11 (review nit 3)
drive c1 FIX_MC_TICK_SECS=600
[ ! -s "$T/alerts.txt" ] && ok || bad "700s under a 600s conductor cadence must not page: $(cat "$T/alerts.txt")"
echo "https://github.com/o/r/pull/7 headsha $(( $(date +%s) - 1300 ))" > "$T/state/sweep-clean-seen.txt"
drive c1 FIX_MC_TICK_SECS=600
grep -q "^3600|sweepstall:o/r#7|" "$T/alerts.txt" && ok || bad "1300s past 2 x 600s must page: $(cat "$T/alerts.txt")"
[ "$(jq -r '.knobs[] | select(.env=="SWEEPSTALL_SECS") | .default' "$DIR/catalog/lanes.d/pipeline-health.json")" = 600 ] \
  && ok || bad "SWEEPSTALL_SECS registry default must be 600"
# 1o. THE DIGEST BEAT REALLY LANDS IN THE WARN DIGEST (review round 2 of #2215).
#     alert_digest, extracted verbatim, driven through the REAL bin/beat.sh and
#     bin/lib/alert-state.sh with a recording curl. A beat stamped triaged:true
#     skips beat.sh's severity routing (it only runs for untriaged beats) and the
#     console ignores severity, so it paged at once. Untriaged + severity warn is
#     spooled to state/alert-warn-batch.jsonl: nothing sent, nothing parked in the
#     LLM triage quarantine.
BD="$T/bd"; mkdir -p "$BD/bin/lib" "$BD/logs" "$BD/state" "$BD/locks" "$BD/flags" "$BD/env" "$BD/stub"
for s in beat.sh alert-digest.sh; do ln -sf "$DIR/bin/$s" "$BD/bin/$s"; done
ln -sf "$DIR/bin/lib/alert-state.sh" "$BD/bin/lib/alert-state.sh"
touch "$BD/flags/remediation-disabled"
printf 'CONSOLE_URL=https://console.invalid\nHARNESS_SECRET=testsecret\n' > "$BD/env/global.env"
printf '#!/bin/bash\nprev=""; for a in "$@"; do [ "$prev" = "-d" ] && { printf "%%s\\n" "$a" >> "%s/sent.jsonl"; break; }; prev="$a"; done\necho '"'"'{"ok":true}'"'"'\n' "$BD" > "$BD/stub/curl"
chmod +x "$BD/stub/curl"
awk '/^alert_digest\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$DIR/bin/pipeline-health.sh" > "$BD/digest-fn.sh"
if [ -s "$BD/digest-fn.sh" ]; then
  ( export PATH="$BD/stub:$PATH" HARNESS="$BD"
    H="$BD"; NOW=$(date +%s); FIRED="$BD/fired"; DEDUP="$BD/dedup.json"; echo '{}' > "$DEDUP"
    STAMP() { echo TS; }
    . "$BD/digest-fn.sh"
    alert_digest 3600 "sweepstall:o/r#7" "o/r#7 READY, digest-only line" ) >/dev/null 2>&1
  [ ! -s "$BD/sent.jsonl" ] && ok || bad "the sweepstall digest beat must not page (sent: $(cat "$BD/sent.jsonl"))"
  grep -q "o/r#7 READY, digest-only line" "$BD/state/alert-warn-batch.jsonl" 2>/dev/null \
    && ok || bad "the sweepstall digest beat must be spooled to the warn digest (batch: $(cat "$BD/state/alert-warn-batch.jsonl" 2>/dev/null); log: $(cat "$BD/logs/alerts-state.log" 2>/dev/null))"
  grep -qs "digest-only line" "$BD/state/alert-quarantine.jsonl" \
    && bad "the sweepstall digest beat must never reach the LLM triage quarantine" || ok
else
  bad "alert_digest() not found in bin/pipeline-health.sh"
fi
rm -rf "$T/state/merge-conductor"; : > "$T/logs/merge-conductor.log"

# ============================================================================
# c2. starved project
# ============================================================================
cat > "$T/issues.json" <<'JSON'
[
 {"number":9,"state":"CLOSED","title":"done","body":""},
 {"number":10,"state":"OPEN","title":"TK-10 free","body":"no blockers"},
 {"number":11,"state":"OPEN","title":"TK-11 waits","body":"Blocked-by: #10"},
 {"number":12,"state":"OPEN","title":"TK-12 released","body":"**Blocked-by: #9**"},
 {"number":13,"state":"OPEN","title":"TK-13 has a PR","body":""},
 {"number":14,"state":"OPEN","title":"TK-14 body-covered","body":""}
]
JSON
cat > "$T/prs.json" <<'JSON'
[{"number":40,"title":"TK-13: sort the list","headRefName":"TK-13-sort","body":"x"},
 {"number":41,"title":"misc","headRefName":"fix","body":"Closes #14"}]
JSON
echo '{"jobs":[]}' > "$T/jobs.json"; : > "$T/queue.tsv"
# 2a. launchable work, nothing running or queued, no build row ever: the page,
#     listing #10 and #12 only (11 is blocked, 13/14 are covered by open PRs)
drive c2
grep -q "^7200|starved:ts|" "$T/alerts.txt" && grep -q "2 launchable ai-build issue(s) (#10 #12 " "$T/alerts.txt" \
  && grep -q "no build row in the ledger at all" "$T/alerts.txt" \
  && ok || bad "starved project did not page as expected: $(cat "$T/alerts.txt") err=$(cat "$T/err.txt")"
grep -q "starved:bd" "$T/alerts.txt" && bad "a board project was judged by the issue rule" || ok
# 2b. a running build row: fed, no page
jq -nc --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{jobs:[{kind:"build",status:"running",created_at:$t}]}' > "$T/jobs.json"
drive c2; [ ! -s "$T/alerts.txt" ] && ok || bad "a running build must not read as starved: $(cat "$T/alerts.txt")"
# 2c. a queued (DB queue) row: fed
echo '{"jobs":[]}' > "$T/jobs.json"; printf 'ts\tTS-10\t10\tqueued\tfly\t0\t-\t-\t-\t-\n' > "$T/queue.tsv"
drive c2; [ ! -s "$T/alerts.txt" ] && ok || bad "a queued row must not read as starved: $(cat "$T/alerts.txt")"
: > "$T/queue.tsv"
# 2d. a build row from an hour ago: too recent to call starved
jq -nc --arg t "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" '{jobs:[{kind:"build",status:"done",created_at:$t}]}' > "$T/jobs.json"
drive c2; [ ! -s "$T/alerts.txt" ] && ok || bad "a 1h-old build row must not read as starved: $(cat "$T/alerts.txt")"
# 2e. a build row from 3h ago: starved, and the age is named
jq -nc --arg t "$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ)" '{jobs:[{kind:"build",status:"done",created_at:$t}]}' > "$T/jobs.json"
drive c2; grep -q "3h since the last build row" "$T/alerts.txt" && ok || bad "3h-old row should page with the age: $(cat "$T/alerts.txt")"
# 2f. nothing launchable (every issue blocked or covered): no page
echo '[{"number":10,"state":"OPEN","title":"x","body":"Blocked-by: #11"},{"number":11,"state":"OPEN","title":"y","body":""}]' > "$T/issues.json"
echo '[{"number":41,"title":"TK-11: y","headRefName":"b","body":""}]' > "$T/prs.json"
drive c2; [ ! -s "$T/alerts.txt" ] && ok || bad "no launchable work must not page: $(cat "$T/alerts.txt")"
# 2g. ledger outage: a transport failure is not starvation
rm -f "$T/jobs.json"
drive c2; [ ! -s "$T/alerts.txt" ] && ok || bad "a ledger outage must not page: $(cat "$T/alerts.txt")"


# ============================================================================
# c3. GitHub API budget guard: stalepr and starved skip when low, others run
# ============================================================================
printf 'ts\to/r\nbd\to/b\n' > "$T/fleet.conf"
# REST shape (BH-782): created_at, draft, user — the library maps them to the
# createdAt/isDraft names the detector reads.
cat > "$T/prs-stale.json" <<'JSON'
[{"number":50,"created_at":"2026-09-10T00:00:00Z","updated_at":"2026-09-10T00:00:00Z","title":"TK-50 old","draft":false,"state":"open","merged_at":null,"closed_at":null,"body":"","labels":[],"html_url":"https://github.com/o/r/pull/50","head":{"ref":"b","sha":"s50"},"base":{"ref":"main"},"user":{"login":"operator","type":"User"}}]
JSON

# 3a. healthy budget (core 4000): stalepr detector is unchanged
cp "$T/prs-stale.json" "$T/prs-rest.json"
drive c3 GH_BUDGET_CORE_REMAINING=4000
grep -q "^21600|stalepr:ts|" "$T/alerts.txt" && grep -q "#50" "$T/alerts.txt"   && ok || bad "healthy budget must let stalepr page: $(cat "$T/alerts.txt")"

# 3b. low budget (core 100): stalepr is skipped, no pr list call, budget check logged
drive c3 GH_BUDGET_CORE_REMAINING=100
[ ! -s "$T/alerts.txt" ] && ! grep -qE "pr list|/pulls\\?" "$T/gh.txt" && grep -q "api rate_limit" "$T/gh.txt"   && ok || bad "low budget must suppress stalepr pr list: alerts=$(cat "$T/alerts.txt") gh=$(cat "$T/gh.txt")"

# 3c. low budget: starved is skipped, no issue list / pr list calls
cat > "$T/issues.json" <<'JSON'
[{"number":10,"state":"OPEN","title":"TK-10 free","body":"no blockers"}]
JSON
echo '[{"number":41,"title":"misc","headRefName":"fix","body":"x"}]' > "$T/prs.json"
echo '{"jobs":[]}' > "$T/jobs.json"; : > "$T/queue.tsv"
drive c2 GH_BUDGET_CORE_REMAINING=100
# TEST-CHANGE (BH-1585): the lists are REST now, so the REST shapes are refused too.
[ ! -s "$T/alerts.txt" ] && ! grep -q "issue list" "$T/gh.txt" && ! grep -qE "pr list|/pulls\\?|repos/o/r/issues|repos/o/r/pulls " "$T/gh.txt" && grep -q "api rate_limit" "$T/gh.txt"   && ok || bad "low budget must suppress starved issue/pr lists: alerts=$(cat "$T/alerts.txt") gh=$(cat "$T/gh.txt")"

# 3d. healthy budget (core 4000): starved behavior is unchanged
drive c2 GH_BUDGET_CORE_REMAINING=4000
grep -q "^7200|starved:ts|" "$T/alerts.txt"   && ok || bad "healthy budget must leave starved detector unchanged: $(cat "$T/alerts.txt")"

# 3e. low budget: an unguarded detector (sweep) still fires
REC2="$T/builds/pool-ts-TK-270-202609120001"; mkdir -p "$REC2"
echo "PR_CREATED https://github.com/o/r/pull/8" > "$REC2/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC2/review.md"
echo "OPEN CLEAN headsha8" > "$T/prstate"
echo "https://github.com/o/r/pull/8 headsha8 $(( $(date +%s) - 1900 ))" > "$T/state/sweep-clean-seen.txt"
: > "$T/state/merge-sweep-done.txt"; : > "$T/logs/merge-sweep.log"
drive c1 GH_BUDGET_CORE_REMAINING=100
grep -q "^3600|sweepstall:o/r#8|" "$T/alerts.txt"   && ok || bad "low budget must not stop unguarded sweep detector: $(cat "$T/alerts.txt") err=$(cat "$T/err.txt")"
echo "pipeline-health-detectors: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
