#!/bin/bash
# tests/pipeline-health-reopen.bh-1643-test.sh — BH-1643: a PR batch-resolve
# closed against a train (url in state/batch-closed.txt, ledger `pr_merged
# merged`, url in merge-sweep-done.txt) that is later REOPENED must be read
# again by the "sweep should have landed" block and page when it stalls, while
# a non-batched merged PR keeps today's no-read skip. Block extracted verbatim.
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
[ -s "$T/c1.sh" ] && ok || bad "c1 block not extracted"
cp "$DIR/bin/lib/gh-repo-token.sh" "$T/bin/lib/"
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
  : > "$T/alerts.txt"; : > "$T/gh.txt"
( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt" GH_BUDGET_TTL_S=0; unset GH_TOKEN
    env "$@" bash -c '
      set -uo pipefail
      H="$T"; NOW=$(date +%s); PROJECTS="ts bd"
      STAMP() { echo TS; }
      alert() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/alerts.txt"; }
      job_verdict() { [ -f "$T/ledger-verdict" ] && { cat "$T/ledger-verdict"; return 0; }; return 2; }
      _jobs_req() { [ -f "$T/jobs.json" ] || return 1; cat "$T/jobs.json"; }
      merge_ledger_has() { grep -qxF "$1" "$T/ledger-merged" 2>/dev/null; }
      queue_list() { [ -f "$T/queue.tsv" ] || return 1; cat "$T/queue.tsv"; }
      . "$T/bin/lib/gh-repo-token.sh"
      . "$T/bin/lib/gh-pr-list.sh"
      . "$T/bin/lib/gh-budget.sh"
      . "$T/bin/lib/gh-rest-list.sh"
      . "$T/bin/lib/pr-terminal.sh"
      . "$0"' "$T/$blk.sh" 2>"$T/err.txt" )
}

PR=https://github.com/o/r/pull/7
REC="$T/builds/pool-ts-TK-1-202609230001"; mkdir -p "$REC"
echo "PR_CREATED $PR" > "$REC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
reset() { # the state batch-resolve leaves behind after settling #7
  echo "$PR" > "$T/state/merge-sweep-done.txt"; echo "$PR" > "$T/ledger-merged"
  : > "$T/logs/merge-sweep.log"; rm -f "$REC/pr-terminal"
  printf 'merged %s %s\n' "$(date +%s)" "$PR" > "$REC/pr-terminal"
  echo "$PR headsha $(( $(date +%s) - 9000 ))" > "$T/state/sweep-clean-seen.txt"
}

# 1. reopened batch-closed PR, OPEN+CLEAN+APPROVE, stamp old: THE page
reset; echo "$PR" > "$T/state/batch-closed.txt"; rm -f "$REC/pr-terminal"
echo "OPEN CLEAN headsha" > "$T/prstate"
drive c1
grep -q "^3600|sweepstall:o/r#7|" "$T/alerts.txt" && grep -qE "pulls/7" "$T/gh.txt" \
  && ! grep -q '^merged' "$REC/pr-terminal" 2>/dev/null \
  && ok || bad "reopened batch-closed PR pages: alerts=$(cat "$T/alerts.txt") gh=$(grep -c pulls "$T/gh.txt") term=$(cat "$REC/pr-terminal" 2>/dev/null) err=$(cat "$T/err.txt")"
# 1b. even with a stale `merged` marker on the record (stamped before reopen)
reset; echo "$PR" > "$T/state/batch-closed.txt"
drive c1
grep -q "^3600|sweepstall:o/r#7|" "$T/alerts.txt" \
  && ok || bad "a stale merged marker must not hide a reopened batch-closed PR: $(cat "$T/alerts.txt")"

# 2. batch-closed, still closed: no page, marker `closed`
reset; echo "$PR" > "$T/state/batch-closed.txt"
echo "CLOSED UNKNOWN headsha" > "$T/prstate"
drive c1
[ ! -s "$T/alerts.txt" ] && grep -q '^closed' "$REC/pr-terminal" \
  && ok || bad "still-closed batch PR must not page: alerts=$(cat "$T/alerts.txt") term=$(cat "$REC/pr-terminal" 2>/dev/null)"
# 2b. the fresh closed marker is honoured: no read on the next tick
drive c1 PR_TERMINAL_CLOSED_RECHECK_S=3600
! grep -qE "pulls/7" "$T/gh.txt" && [ ! -s "$T/alerts.txt" ] \
  && ok || bad "a fresh closed marker must spare the read: gh=$(cat "$T/gh.txt")"

# 3. reopened but dirty: no page
reset; echo "$PR" > "$T/state/batch-closed.txt"
echo "OPEN DIRTY headsha" > "$T/prstate"
drive c1
[ ! -s "$T/alerts.txt" ] && ok || bad "reopened dirty PR must not page: $(cat "$T/alerts.txt")"

# 4. non-batched, in merge-sweep-done: no read, no page (today's path)
reset; : > "$T/state/batch-closed.txt"
echo "OPEN CLEAN headsha" > "$T/prstate"
drive c1
[ ! -s "$T/alerts.txt" ] && ! grep -qE "pulls/7" "$T/gh.txt" \
  && ok || bad "non-batched handled PR must take the no-read skip: alerts=$(cat "$T/alerts.txt") gh=$(cat "$T/gh.txt")"

echo "pipeline-health-reopen.bh-1643: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
