#!/bin/bash
# tests/main-red-queue-arm-test.sh — bin/main-red-detector.sh's QUEUE arm: main
# is red when the merge queue keeps failing on INDEPENDENT batches (2026-09-24).
#
# WHY. Each tree is now tested exactly once, in the Mergify merge-queue batch
# (a pull_request whose head is mergify/merge-queue/*). A push to main runs the
# fast checks only, so the runs on main no longer carry a test corpus, and a
# main that breaks BY ITSELF — the 2026-09-15 clock bomb, a tool that drifted —
# shows up in exactly one place: every batch goes red, whatever it carries.
# Nothing merges, so no push arrives, so the streak/tip/burst arms that read
# main's own runs see nothing. The queue arm reads the batches.
#
# THE RULE. For a repo in MAIN_RED_QUEUE_REPOS (default: the harness repo),
# read the newest pull_request runs, keep the REQUIRED ones on a
# mergify/merge-queue/* head, and walk them newest first until one is green. A
# batch STACKED on others ("... stacked on 8 pull requests ahead") never counts:
# it carries every PR ahead of it, so one bad head batch reddens the whole stack
# (2026-09-24 19:08-19:17Z: exactly that, with main green). A batch tested
# directly on main counts when its PR numbers share none with a batch already
# counted. MAIN_RED_QUEUE_STREAK (3) of them red, no green batch since: freeze
# (reason=queue). The titles below are Mergify's real ones, from that day.
#
#   Q1  three unstacked red batches, disjoint PRs, main's own runs green: FREEZE
#   Q2  one red head batch and a red STACK behind it: no freeze
#   Q3  a green batch newer than the reds: no freeze
#   Q4  the flag is up; a green batch newer than the freeze: CLEAR
#   Q4b the flag is up; main green but the queue unreadable: flag stays
#   Q4c the flag is up; the reds scrolled off the page, no green batch: stays
#   Q5  MAIN_RED_QUEUE=0: no queue read at all, no freeze
#   Q6  a repo not in MAIN_RED_QUEUE_REPOS: no queue read
#   Q7  the queue read fails: that arm decides nothing
#   Q8  titles with no PR number are not evidence; unstacked batches sharing a
#       PR (the same PR retried) count once
#   Q9  a skip-listed workflow's reds and ordinary PRs' reds are not evidence
#   Q10 a NEW raise re-reads the queue (BH-1927) and confirms
#
# Time is pinned to ONE clock read, like tests/main-red-tip-red-test.sh.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/env" "$T/fakebin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v python3 >/dev/null || {
  [ -n "${CI:-}" ] && { echo "FAIL: jq/python3 missing on a CI runner"; exit 1; }
  echo "jq/python3 missing — skipping"; exit 0; }

NOW=$(date +%s)                     # the ONLY clock read in this file
ago() { date -u -d "@$((NOW - $1 * 60))" +%FT%TZ; }

cp "$DIR/bin/main-red-detector.sh" "$T/bin/"
cp "$DIR/bin/lib/gh-repo-token.sh" "$T/bin/lib/"
: > "$T/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
cat > "$T/bin/lane-alert.sh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_SINK"
exit 0
SHIM
chmod +x "$T/bin/lane-alert.sh"
# The gh fake: the main page from $T/runs.json, the queue page (the read with
# event=pull_request) from $T/queue.json — absent or empty = the API failed.
cat > "$T/fakebin/gh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
case "$*" in
  "api repos/"*" -q .id")   exit 0 ;;
  *"/actions/runs/"*"/jobs"*) printf '%s\n' "${JOBS_ANSWER:-}" ;;
  *"actions/runs"*"event=pull_request"*)
                            [ -s "$T/queue.json" ] || exit 1
                            jq -c '[.workflow_runs[]? | {n:.name, p:.path, s:.status, c:.conclusion, sha:.head_sha, hb:.head_branch, dt:.display_title, t:.created_at, u:.html_url, id:.id}]' "$T/queue.json" ;;
  *"actions/runs"*)         [ -s "$T/runs.json" ] || exit 1
                            jq -c '[.workflow_runs[]? | {n:.name, p:.path, s:.status, c:.conclusion, sha:.head_sha, t:.created_at, u:.html_url, id:.id, e:.event}]' "$T/runs.json" ;;
  *) echo "" ;;
esac
SHIM
chmod +x "$T/fakebin/gh"

CI=".github/workflows/harness-ci.yml"
# main <spec>... — spec: conclusion|minutes-ago|sha[|event] (Harness CI runs on main; push by default)
main() {
  local out='{"workflow_runs":[' first=1 spec c m sha ev t
  for spec in "$@"; do
    IFS='|' read -r c m sha ev <<<"$spec"; t=$(ago "$m"); ev=${ev:-push}
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --arg p "$CI" --arg t "$t" --arg sha "$sha" --arg c "$c" --arg ev "$ev" \
      '{name:"Harness CI", path:$p, status:"completed", conclusion:$c, created_at:$t, head_sha:$sha, event:$ev,
        html_url:("https://github.com/o/r/actions/runs/1" + ($t|gsub("[^0-9]";""))),
        id:(("1" + ($t|gsub("[^0-9]";"")))|tonumber)}')
  done
  printf '%s]}' "$out" > "$T/runs.json"
}
# queue <spec>... — spec: conclusion|minutes-ago|title[|head_branch[|workflow name]]
queue() {
  local out='{"workflow_runs":[' first=1 spec c m dt hb n t
  for spec in "$@"; do
    IFS='|' read -r c m dt hb n <<<"$spec"; t=$(ago "$m")
    hb=${hb:-mergify/merge-queue/q$m}; n=${n:-Harness CI}
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --arg p "$CI" --arg t "$t" --arg c "$c" --arg dt "$dt" --arg hb "$hb" --arg n "$n" \
      '{name:$n, path:$p, status:"completed", conclusion:$c, created_at:$t, head_sha:("q" + ($t|gsub("[^0-9]";""))),
        head_branch:$hb, display_title:$dt,
        html_url:("https://github.com/o/r/actions/runs/2" + ($t|gsub("[^0-9]";""))),
        id:(("2" + ($t|gsub("[^0-9]";"")))|tonumber)}')
  done
  printf '%s]}' "$out" > "$T/queue.json"
}
drive() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt" \
           ALERT_SINK="$T/alerts.txt" JOBS_ANSWER="${JOBS_ANSWER:-}" MAIN_RED_QUEUE_REPOS="${QREPOS:-o/r}"; unset GH_TOKEN
    bash "$T/bin/main-red-detector.sh" "$@" >/dev/null 2>"$T/err.txt" )
}
alerts()  { awk 'END{print NR+0}' "$T/alerts.txt" 2>/dev/null; }
qreads()  { grep -c 'event=pull_request' "$T/gh.txt" 2>/dev/null; }
FLAG="$T/flags/main-red-o-r"
reset_all() { : > "$T/alerts.txt"; : > "$T/gh.txt"; : > "$T/logs/main-red.log"; rm -f "$T"/flags/main-red-* "$T/queue.json"; }
GREEN_MAIN() { main "success|30|m2m2m2m2" "success|90|m1m1m1m1"; }

T1="merge queue: checking #2141 on main (11b8d1e)"
T2="merge queue: checking #2023 + #2124 together on main (11b8d1e)"
T3="merge queue: checking #2153 + #2148 together on main (0d937a1)"
S1="merge queue: checking #2141 on main (11b8d1e), stacked on 10 pull requests ahead"
S2="merge queue: checking #2023 + #2124 together on main (11b8d1e), stacked on 11 pull requests ahead"
S3="merge queue: checking #2153 + #2148 together on main (11b8d1e), stacked on 8 pull requests ahead"

# ── Q1. the clock-bomb shape: three batches tested directly on main, no PR in
#    common, all red; main's own (fast-check) runs green. Freeze, page once.
reset_all; GREEN_MAIN
JOBS_ANSWER="Pure-logic gate fixtures, Tests, traced (shard 2/8)"
queue "failure|10|$T1" "failure|25|$T2" "failure|40|$T3" \
      "success|120|merge queue: checking #2100 on main (aaaaaaa)"
drive o/r
[ -f "$FLAG" ] && ok || bad "Q1: three independent red batches must freeze merges (err=$(cat "$T/err.txt"); log=$(tail -3 "$T/logs/main-red.log"))"
grep -q '^reason=queue$' "$FLAG" 2>/dev/null && ok || bad "Q1: the flag must say the queue arm fired: $(cat "$FLAG" 2>/dev/null)"
grep -q '^job=Pure-logic gate fixtures' "$FLAG" 2>/dev/null && ok || bad "Q1: the flag must name the failing job: $(cat "$FLAG" 2>/dev/null)"
grep -q '^streak=3$' "$FLAG" 2>/dev/null && ok || bad "Q1: the streak is three independent batches: $(cat "$FLAG" 2>/dev/null)"
[ "$(alerts)" = 1 ] && ok || bad "Q1: exactly one alert: $(cat "$T/alerts.txt")"
grep -q '^--critical main-red o/r main is RED' "$T/alerts.txt" && ok || bad "Q1: the page is critical and says main is RED: $(cat "$T/alerts.txt")"
grep -q 'merge queue' "$T/alerts.txt" && ok || bad "Q1: the page must say the evidence is the merge queue: $(cat "$T/alerts.txt")"

# ── Q2. 2026-09-24 19:08-19:17Z: ONE red head batch and a red stack behind it.
#    Every stacked batch carries the head's PRs — one culprit, main green.
reset_all; GREEN_MAIN
queue "failure|8|$S3" "failure|9|$S2" "failure|10|$S1" \
      "failure|11|merge queue: checking #2135 + #2136 together on main (11b8d1e), stacked on 3 pull requests ahead" \
      "failure|12|merge queue: checking #2099 on main (11b8d1e), stacked on 1 pull request ahead" \
      "failure|15|merge queue: checking #2104 + #2105 together on main (11b8d1e)"
drive o/r
{ [ ! -f "$FLAG" ] && [ "$(alerts)" = 0 ]; } && ok || bad "Q2: a red head batch and its red stack are one culprit, not a red main"

# ── Q3. a green batch newer than the reds: main was fine a moment ago.
reset_all; GREEN_MAIN
queue "success|5|merge queue: checking #2160 on main (bbbbbbb)" \
      "failure|10|$T1" "failure|25|$T2" "failure|40|$T3"
drive o/r
{ [ ! -f "$FLAG" ] && [ "$(alerts)" = 0 ]; } && ok || bad "Q3: a newer green batch must hold the arm down"

# ── Q4. the flag is up; a green batch newer than the freeze: CLEAR.
reset_all; GREEN_MAIN
queue "failure|10|$T1" "failure|25|$T2" "failure|40|$T3"
drive o/r
[ -f "$FLAG" ] && ok || bad "Q4 setup: the freeze must go up"
FLAG_AT="$(sed -n 's/^detected=//p' "$FLAG" | head -1)"
: > "$T/alerts.txt"
# Q4b: main green, the queue unreadable — a failed read is not a fix.
rm -f "$T/queue.json"
drive o/r
{ [ -f "$FLAG" ] && [ "$(alerts)" = 0 ]; } && ok || bad "Q4b: an unreadable queue must not clear a queue freeze (alerts=$(cat "$T/alerts.txt"))"
# Q4c: the reds scrolled off the page and no green batch is in it.
queue "failure|3|merge queue: checking #2170 on main (ccccccc), stacked on 2 pull requests ahead"
drive o/r
{ [ -f "$FLAG" ] && [ "$(alerts)" = 0 ]; } && ok || bad "Q4c: reds that scrolled away are not a green batch — the freeze must stay"
# Q4: a green batch created after the freeze. The fixture's clock is minutes
# ago, so a batch at "-1 minutes" (the future) is certainly newer than detected=.
queue "success|-1|merge queue: checking #2180 on main (ddddddd)" \
      "failure|10|$T1" "failure|25|$T2" "failure|40|$T3"
main "success|-1|m3m3m3m3" "success|30|m2m2m2m2"
drive o/r
[ ! -f "$FLAG" ] && ok || bad "Q4: a green batch newer than the freeze ($FLAG_AT) must clear it (log=$(tail -2 "$T/logs/main-red.log"))"
grep -q -- '^--resolve --log-only main-red o/r main is GREEN again' "$T/alerts.txt" && ok || bad "Q4: one resolve alert: $(cat "$T/alerts.txt")"

# ── Q5. the kill switch: no queue read at all.
reset_all; GREEN_MAIN
queue "failure|10|$T1" "failure|25|$T2" "failure|40|$T3"
( export MAIN_RED_QUEUE=0; drive o/r )
{ [ ! -f "$FLAG" ] && [ "$(qreads)" = 0 ]; } && ok || bad "Q5: MAIN_RED_QUEUE=0 must not read the queue (reads=$(qreads))"

# ── Q6. a repo the arm is not armed for is never read.
reset_all; GREEN_MAIN
queue "failure|10|$T1" "failure|25|$T2" "failure|40|$T3"
QREPOS="example-org/cromford" drive o/r
{ [ ! -f "$FLAG" ] && [ "$(qreads)" = 0 ]; } && ok || bad "Q6: o/r is not in MAIN_RED_QUEUE_REPOS — no queue read (reads=$(qreads))"

# ── Q7. the queue read fails: that arm decides nothing (main is green).
reset_all; GREEN_MAIN
drive o/r
{ [ ! -f "$FLAG" ] && [ "$(alerts)" = 0 ]; } && ok || bad "Q7: an unreadable queue is not a red main"

# ── Q8. no PR number proves nothing; the same PR retried counts once.
reset_all; GREEN_MAIN
queue "failure|10|merge queue batch" "failure|25|merge queue batch" "failure|40|merge queue batch"
drive o/r
[ ! -f "$FLAG" ] && ok || bad "Q8: batches with no PR number in the title must not count"
reset_all; GREEN_MAIN
queue "failure|10|$T1" "failure|25|$T1" "failure|40|$T2"
drive o/r
[ ! -f "$FLAG" ] && ok || bad "Q8: #2141 retried is one culprit — two independent batches, not three"

# ── Q9. a skip-listed workflow's red batches are not evidence; nor is a PR
#    that is not a queue head.
reset_all; GREEN_MAIN
queue "failure|10|$T1||E2E nightly" "failure|25|$T2||E2E nightly" "failure|40|$T3||E2E nightly"
drive o/r
[ ! -f "$FLAG" ] && ok || bad "Q9: a MAIN_RED_SKIP_RE workflow's red batches must not freeze"
reset_all; GREEN_MAIN
queue "failure|10|#501|ticket/bh-1" "failure|25|#503|ticket/bh-2" "failure|40|#504|ticket/bh-3"
drive o/r
[ ! -f "$FLAG" ] && ok || bad "Q9: red ordinary PRs are pr-pair's business, not the queue arm's"

# ── Q10. a NEW raise re-reads (BH-1927): the queue is read twice.
reset_all; GREEN_MAIN
queue "failure|10|$T1" "failure|25|$T2" "failure|40|$T3"
drive o/r
{ [ -f "$FLAG" ] && [ "$(qreads)" = 2 ]; } && ok || bad "Q10: a new queue freeze must be confirmed on a second queue read (reads=$(qreads))"

# ── Q11. timed_out / startup_failure are infrastructure, not red code: three
#    of them never freeze, and they do not end the walk either.
reset_all; GREEN_MAIN
queue "timed_out|10|$T1" "startup_failure|25|$T2" "timed_out|40|$T3"
drive o/r
[ ! -f "$FLAG" ] && ok || bad "Q11: infra failures (timed_out/startup_failure) must not freeze merges"
reset_all; GREEN_MAIN
queue "failure|10|$T1" "timed_out|15|merge queue: checking #2190 on main (eeeeeee)" "failure|25|$T2" "failure|40|$T3"
drive o/r
[ -f "$FLAG" ] && ok || bad "Q11: an infra failure between real reds is skipped, not a green that ends the walk"

# ── Q12. the queue is EMPTY (no batch will ever run): a green full-corpus
#    workflow_dispatch run on main, newer than the freeze, clears it.
reset_all; GREEN_MAIN
queue "failure|10|$T1" "failure|25|$T2" "failure|40|$T3"
drive o/r
[ -f "$FLAG" ] && ok || bad "Q12 setup: the freeze must go up"
: > "$T/alerts.txt"
main "success|-1|m9m9m9m9|workflow_dispatch" "success|30|m2m2m2m2"
drive o/r
[ ! -f "$FLAG" ] && ok || bad "Q12: a green dispatch run on main newer than the freeze must clear it (log: $(tail -2 "$T/logs/main-red.log"))"
grep -q -- '^--resolve --log-only main-red o/r main is GREEN again' "$T/alerts.txt" && ok || bad "Q12: one resolve alert: $(cat "$T/alerts.txt")"
# ...but a dispatch run OLDER than the freeze clears nothing.
reset_all; GREEN_MAIN
queue "failure|10|$T1" "failure|25|$T2" "failure|40|$T3"
drive o/r
main "success|60|m8m8m8m8|workflow_dispatch" "success|-1|m2m2m2m2"
: > "$T/alerts.txt"
drive o/r
[ -f "$FLAG" ] && ok || bad "Q12: a dispatch run older than the freeze is no evidence"

# ── Q13. the queue read asks for GitHub's maximum page, so a busy PR stream
#    does not scroll the batches away.
grep -q 'event=pull_request -f per_page=100' "$T/gh.txt" && ok || bad "Q13: the queue read must ask for per_page=100 (got: $(grep event=pull_request "$T/gh.txt" | head -1))"

echo "main-red-queue-arm: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
