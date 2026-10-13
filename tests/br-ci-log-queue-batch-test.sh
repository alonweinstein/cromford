#!/bin/bash
# tests/br-ci-log-queue-batch-test.sh — a fix round on a PR that failed in the
# merge queue gets the BATCH's failing log (2026-09-24).
#
# WHY. On a repo that tests only in its queue the PR's own head runs the fast
# checks and reads green through any test failure; its only red is on the
# Mergify batch draft. bin/blocked-resolver.sh's br_ci_log read the PR head
# only, so the fix brief came back empty and the round ended "nothing to brief a
# fix round with". The functions are EXTRACTED from the script and driven
# against a fake gh.
#
#   L1  a red head: the head's own failing runs, exactly as before
#   L2  a green head + a PR number: the newest RED batch naming #N is the log
#   L3  the batch match is on the whole number: #19 is not #1
#   L4  the newest batch naming #N is green: no log (nothing failed)
#   L5  no PR number: no batch read at all (old callers unchanged)
#   L6  the batch read fails: empty, never an error
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
command -v jq >/dev/null || { [ -n "${CI:-}" ] && { echo "FAIL: jq missing on CI"; exit 1; }; echo "jq missing — skipping"; exit 0; }

SRC="$DIR/bin/blocked-resolver.sh"
for f in br_failed_runs br_queue_batch br_queue_red_batch br_ci_log; do
  awk -v f="$f" '$0 ~ "^" f "\\(\\) \\{" {on = 1} on {print} on && /^}/ {exit}' "$SRC"
done > "$T/fns.sh"
grep -q '^br_ci_log()' "$T/fns.sh" && ok || bad "setup: br_ci_log not found in $SRC"
grep -q '^br_queue_batch()' "$T/fns.sh" && ok || bad "L0: bin/blocked-resolver.sh has no br_queue_batch — the batch is never read"

mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GHLOG"
case "$*" in
  *"actions/runs?head_sha="*)
    [ -f "$FX/head.json" ] || exit 1
    q=""; while [ $# -gt 0 ]; do [ "$1" = -q ] && q="$2"; shift; done
    jq -r "$q" "$FX/head.json" ;;
  *"actions/runs?event=pull_request"*) [ -f "$FX/queue.json" ] || exit 1; cat "$FX/queue.json" ;;
  "run view "*) echo "LOG OF RUN $3: assertion X failed" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/gh"

drive() { # drive <head> [num] -> stdout of br_ci_log
  ( export PATH="$T/bin:$PATH" GHLOG="$T/gh.log" FX="$T/fx"
    # shellcheck source=/dev/null
    . "$T/fns.sh"; br_ci_log o/r "$@" )
}
reset() { rm -rf "$T/fx"; mkdir -p "$T/fx"; : > "$T/gh.log"; }
H=cccccccccccccccccccccccccccccccccccccccc
QUEUE() { # QUEUE <conclusion-newest-#9> — two batches naming #9, one naming #19
  jq -n --arg c "$1" '{workflow_runs:[
    {id:900, head_branch:"mergify/merge-queue/x", status:"completed", conclusion:"failure", created_at:"2026-09-24T13:00:00Z",
     display_title:"merge queue: checking #19 on main (1111111)"},
    {id:901, head_branch:"mergify/merge-queue/y", status:"completed", conclusion:$c, created_at:"2026-09-24T12:00:00Z",
     display_title:"merge queue: checking #9 + #12 together on main (1111111)"},
    {id:902, head_branch:"mergify/merge-queue/z", status:"completed", conclusion:"success", created_at:"2026-09-24T10:00:00Z",
     display_title:"merge queue: checking #9 on main (0000000)"},
    {id:903, head_branch:"ticket/bh-9", status:"completed", conclusion:"failure", created_at:"2026-09-24T14:00:00Z",
     display_title:"#9 the PR itself"}]}' > "$T/fx/queue.json"
}

# L1
reset; echo '{"workflow_runs":[{"id":555,"conclusion":"failure"}]}' > "$T/fx/head.json"; QUEUE failure
OUT=$(drive "$H" 9)
has "failing run 555" "$OUT" && ok || bad "L1: a red head must brief its own failing run: $OUT"
has "MERGE-QUEUE" "$OUT" && bad "L1: a head with its own red needs no batch log: $OUT" || ok
# L2
reset; echo '{"workflow_runs":[{"id":556,"conclusion":"success"}]}' > "$T/fx/head.json"; QUEUE failure
OUT=$(drive "$H" 9)
has "MERGE-QUEUE batch run 901" "$OUT" && ok || bad "L2: a green head must fall back to the newest red batch naming #9 (901): $OUT"
has "LOG OF RUN 901" "$OUT" && ok || bad "L2: the batch's failed-job log must be in the brief: $OUT"
# L3 is inside L2: 900 names #19 and is newer — it must not be taken.
has "run 900" "$OUT" && bad "L3: #19 is not #9: $OUT" || ok
has "run 903" "$OUT" && bad "L3: the PR's own branch is not a batch: $OUT" || ok
# L4
reset; echo '{"workflow_runs":[]}' > "$T/fx/head.json"; QUEUE success
OUT=$(drive "$H" 9)
[ -z "$OUT" ] && ok || bad "L4: the newest batch naming #9 is green — nothing to brief: $OUT"
# L5
reset; echo '{"workflow_runs":[]}' > "$T/fx/head.json"; QUEUE failure
OUT=$(drive "$H")
{ [ -z "$OUT" ] && ! grep -q 'event=pull_request' "$T/gh.log"; } && ok || bad "L5: no PR number means no batch read: $OUT / $(cat "$T/gh.log")"
# L6
reset; echo '{"workflow_runs":[]}' > "$T/fx/head.json"
OUT=$(drive "$H" 9); RC=$?
{ [ "$RC" = 0 ] && [ -z "$OUT" ]; } && ok || bad "L6: an unreadable queue is an empty brief, rc 0 (rc=$RC): $OUT"

# REVIEW ROUND 3. The fallback wants the batch that FAILED on this PR's code,
# not merely the newest batch that names it.
QUEUE2() { # QUEUE2 <json-array-of-runs> — the batch list, verbatim
  printf '{"workflow_runs":%s}\n' "$1" > "$T/fx/queue.json"
}
# L7. A NEWER CANCELLED batch (Mergify re-embarks after a sibling fails, and
# cancels the old draft) must not hide the red one behind it.
reset; echo '{"workflow_runs":[]}' > "$T/fx/head.json"
QUEUE2 '[
  {"id":710,"head_branch":"mergify/merge-queue/c","status":"completed","conclusion":"cancelled","created_at":"2026-09-24T15:00:00Z",
   "display_title":"merge queue: embarking #9 and #14 together, stacked on #12 (2222222)"},
  {"id":711,"head_branch":"mergify/merge-queue/r","status":"completed","conclusion":"failure","created_at":"2026-09-24T14:00:00Z",
   "display_title":"merge queue: embarking #9 together on main (1111111)"}]'
OUT=$(drive "$H" 9)
has "MERGE-QUEUE batch run 711" "$OUT" && ok || bad "L7: a newer cancelled batch must not hide the red batch 711: $OUT"
has "run 710" "$OUT" && bad "L7: a cancelled batch is not a failure log: $OUT" || ok
# L8. A red batch STACKED behind someone else's batch failed because of what it
# stood on; an unstacked red batch carrying the PR is its own log, even older.
reset; echo '{"workflow_runs":[]}' > "$T/fx/head.json"
QUEUE2 '[
  {"id":720,"head_branch":"mergify/merge-queue/s","status":"completed","conclusion":"failure","created_at":"2026-09-24T15:00:00Z",
   "display_title":"merge queue: embarking #9 together, stacked on #12 (2222222)"},
  {"id":721,"head_branch":"mergify/merge-queue/u","status":"completed","conclusion":"failure","created_at":"2026-09-24T14:00:00Z",
   "display_title":"merge queue: embarking #9 together on main (1111111)"}]'
OUT=$(drive "$H" 9)
has "MERGE-QUEUE batch run 721" "$OUT" && ok || bad "L8: the unstacked red batch 721 is the PR's own log, not the stacked 720: $OUT"
has "run 720" "$OUT" && bad "L8: a batch stacked on someone else's is not preferred: $OUT" || ok
# L9. Only stacked red batches: the newest one is still the best evidence there is.
reset; echo '{"workflow_runs":[]}' > "$T/fx/head.json"
QUEUE2 '[
  {"id":730,"head_branch":"mergify/merge-queue/s","status":"completed","conclusion":"timed_out","created_at":"2026-09-24T15:00:00Z",
   "display_title":"merge queue: embarking #9 together, stacked on #12 (2222222)"}]'
OUT=$(drive "$H" 9)
has "MERGE-QUEUE batch run 730" "$OUT" && ok || bad "L9: a stacked red batch is still briefed when it is the only red one: $OUT"
# L10. A green batch NEWER than the red one answers it: nothing to brief.
reset; echo '{"workflow_runs":[]}' > "$T/fx/head.json"
QUEUE2 '[
  {"id":740,"head_branch":"mergify/merge-queue/g","status":"completed","conclusion":"success","created_at":"2026-09-24T15:00:00Z",
   "display_title":"merge queue: embarking #9 together on main (3333333)"},
  {"id":741,"head_branch":"mergify/merge-queue/r","status":"completed","conclusion":"failure","created_at":"2026-09-24T14:00:00Z",
   "display_title":"merge queue: embarking #9 together on main (1111111)"}]'
OUT=$(drive "$H" 9)
[ -z "$OUT" ] && ok || bad "L10: a red batch a newer green batch answered is not the log: $OUT"
# L11. The green-at-head check reads br_queue_batch too, and its contract is
# unchanged: the NEWEST completed batch naming the PR, whatever it concluded.
( export PATH="$T/bin:$PATH" GHLOG="$T/gh.log" FX="$T/fx"; . "$T/fns.sh"
  [ "$(br_queue_batch o/r 9)" = "success 740" ] ) && ok \
  || bad "L11: br_queue_batch keeps answering the newest completed batch (want 'success 740')"

echo "br-ci-log-queue-batch: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
