#!/bin/bash
# tests/attempt-kinds-classify-rows.bh-2358-test.sh — BH-2358 (BH-2311.2, task
# 2.1): the `cirerun`, `requeued`, `apread` and `mergetree` call sites in
# bin/lib/mc/classify.sh and bin/lib/mc/rebase.sh go through the BH-2354
# contract verbs instead of reading and appending $MC_ATTEMPTS by hand.
#
# WHAT IT PINS.
#   A. flag DOWN: every call site writes exactly the lines it wrote before
#      (attempts.txt byte-compared against literal lines), reads back the same
#      answers (the FIRST cirerun/requeued epoch, the LAST apread epoch, the
#      mergetree count 1,2,3 and GitHub trusted at MC_MERGE_TREE_MAX), and no
#      pr-attempts request is made.
#   B. flag UP: the same lines, and each one is ALSO a PUT to /api/pr-attempts
#      (the row twin), so a wiped ledger no longer forgets them.
#   C. static guard: neither file appends to, greps -c or awks $MC_ATTEMPTS by
#      hand any more. A missing file FAILS the guard, it does not pass it.
#
# HOW. The REAL functions, loaded through the REAL bin/lib/merge-conductor-lib.sh
# plus the real jobs client, one fresh process per step (drv). mc_now is pinned
# per step so "first" and "last" are observable. A curl shim is the worker: it
# keeps a row store and records every request in a sink.
#
# Run from anywhere: tests/attempt-kinds-classify-rows.bh-2358-test.sh (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

CLASSIFY="$DIR/bin/lib/mc/classify.sh"
REBASE="$DIR/bin/lib/mc/rebase.sh"
H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/bin/lib/mc" "$H/env" "$H/flags" "$H/logs" \
         "$H/state/merge-conductor" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$H/bin/" || exit 1
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/" || exit 1
cp "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$H/bin/lib/" || exit 1
cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/" || exit 1

ATT="$H/state/merge-conductor/attempts.txt"
MCLOG="$H/logs/merge-conductor.log"
REQ="$T/req.log"
ROWS="$T/rows.tsv"
ERR="$T/err.log"

# The worker: a row store in $ROWS_FILE keyed (repo, number, kind, sha).
# /api/flags/* answers 404 so flag_active falls back to the flag FILE.
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL=""; METHOD=GET; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2 ;;
    --data-binary) BODY="$2"; shift 2 ;;
    -H|-m|--connect-timeout|-w) shift 2 ;;
    -*) shift ;;
    *) URL="$1"; shift ;;
  esac
done
case "$URL" in */api/flags/*) printf '{"error":"no such flag"}\n404\n'; exit 0 ;; esac
case "$URL" in */api/pr-attempts*) ;; *) printf '{"error":"not found"}\n404\n'; exit 0 ;; esac
dec() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }
repo=""; num=""; kind=""; sha=""
if [ -n "$BODY" ]; then
  repo=$(jq -r .repo <<<"$BODY"); num=$(jq -r .number <<<"$BODY")
  kind=$(jq -r .kind <<<"$BODY"); sha=$(jq -r .sha <<<"$BODY")
else
  q="${URL#*\?}"; [ "$q" = "$URL" ] && q=""
  IFS='&' read -r -a kv <<<"$q"
  for p in "${kv[@]}"; do
    v=$(dec "${p#*=}")
    case "${p%%=*}" in repo) repo="$v" ;; number) num="$v" ;; kind) kind="$v" ;; sha) sha="$v" ;; esac
  done
fi
printf '%s\t%s\t%s\t%s\t%s\n' "$METHOD" "$repo" "$num" "$kind" "$sha" >> "$REQ_LOG"
[ -f "$ROWS_DOWN" ] && exit 7
touch "$ROWS_FILE"
row=$(printf '%s\t%s\t%s\t%s' "$repo" "$num" "$kind" "$sha")
case "$METHOD" in
  PUT) grep -qxF "$row" "$ROWS_FILE" || printf '%s\n' "$row" >> "$ROWS_FILE"
       printf '{"ok":true}\n200\n' ;;
  DELETE) if grep -qxF "$row" "$ROWS_FILE"; then
            grep -vxF "$row" "$ROWS_FILE" > "$ROWS_FILE.t"; mv -f "$ROWS_FILE.t" "$ROWS_FILE"
            printf '{"ok":true}\n200\n'
          else printf '{"error":"no row"}\n404\n'; fi ;;
  GET) if [ -n "$sha" ]; then
         if grep -qxF "$row" "$ROWS_FILE"; then printf '{"ok":true}\n200\n'; else printf '{"error":"no row"}\n404\n'; fi
       else
         # Newest first, as the real route's ORDER BY at DESC lists them.
         awk -F'\t' -v r="$repo" -v n="$num" -v k="$kind" '$1==r && $2==n && $3==k {print $4}' "$ROWS_FILE" \
           | tac | jq -Rsc 'split("\n") | map(select(. != "")) | {attempts: map({sha: .}), count: length}'
         printf '200\n'
       fi ;;
esac
CURL
chmod +x "$T/fakebin/curl"
# Nothing here may reach GitHub; a gh call answers nothing, rc 1.
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"

cat > "$T/drive.sh" <<'DRV'
#!/bin/bash
set -uo pipefail
# shellcheck source=/dev/null
. "$HARNESS/bin/jobs-client.sh" >/dev/null 2>&1 || exit 90
# shellcheck source=/dev/null
. "$HARNESS/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1 || exit 91
eval "$DRIVE_CODE"
DRV
drv() {
  env DRIVE_CODE="$1" PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=x JOBS_BOX=testbox \
    JOBS_RETRIES=0 JOBS_ALERT=0 JOBS_URL=http://jobs.test REQ_LOG="$REQ" ROWS_FILE="$ROWS" \
    ROWS_DOWN="$T/rows-down" MC_REHYDRATE=0 bash "$T/drive.sh" 2>>"$ERR"
}
flag() { if [ "$1" = up ]; then : > "$H/flags/pr-state-rows"; else rm -f "$H/flags/pr-state-rows"; fi; }
reset() { : > "$REQ"; : > "$ERR"; : > "$ATT"; : > "$MCLOG"; : > "$ROWS"; rm -f "$T/rows-down"; }
nreq()  { local n; n=$(grep -c "^$1	" "$REQ" 2>/dev/null) || n=0; printf '%s' "${n:-0}"; }
has_put() { grep -qxF "$(printf 'PUT\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4")" "$REQ"; }
K='o/r#5'
HD=1111111111111111111111111111111111111111

# One pass over all four call sites, the way the conductor drives them.
run_sites() {
  # cirerun + requeued: two records at different epochs, the mark is the FIRST.
  drv "mc_now() { echo 100; }; mc_rerun_record '$K' $HD; mc_requeued_record '$K' $HD
       mc_now() { echo 200; }; mc_rerun_record '$K' $HD; mc_requeued_record '$K' $HD
       echo rerun=\$(mc_rerun_mark '$K' $HD); echo requeued=\$(mc_requeued_mark '$K' $HD)"
  # apread: the production writer is mc_autopilot_verdict (its hourly comment
  # read). 100, then 200 inside the recheck window (no line), then 5000 past it.
  drv "harness_verdict_authors_json() { echo '[\"x\"]'; }
       mc_now() { echo 100; };  mc_autopilot_verdict o/r 5 '$K' $HD >/dev/null
       mc_now() { echo 200; };  mc_autopilot_verdict o/r 5 '$K' $HD >/dev/null
       mc_now() { echo 5000; }; mc_autopilot_verdict o/r 5 '$K' $HD >/dev/null
       echo apread=\$(mc_ap_read_mark '$K' $HD)"
  # mergetree: git says clean three ticks running; the third trusts GitHub.
  drv "mc_merge_tree() { return 0; }
       for i in 1 2 3; do merge_tree_clean '$K' o/r demo $HD 5; echo mt\$i=\$?; done"
}
WANT_OUT=$(printf 'rerun=100\nrequeued=100\napread=5000\nmt1=0\nmt2=0\nmt3=1')
WANT_ATT=$(printf '%s\n' "cirerun $K $HD 100" "requeued $K $HD 100" "cirerun $K $HD 200" "requeued $K $HD 200" \
  "apread $K $HD 100" "apread $K $HD 5000" "mergetree $K $HD" "mergetree $K $HD" "mergetree $K $HD")

echo "== A. flag down: today's lines, today's answers, no row traffic =="
reset; flag down
OUT=$(run_sites)
[ "$OUT" = "$WANT_OUT" ] && ok || bad "A: answers differ from today's: $(printf '%s' "$OUT" | tr '\n' ' ')"
[ "$(cat "$ATT")" = "$WANT_ATT" ] && ok || bad "A: attempts.txt is not byte-identical to today's lines:
$(cat "$ATT")"
[ "$(grep -c "pr-attempts\|	o/r	" "$REQ")" = 0 ] && ok || bad "A: flag down must make no pr-attempts request: $(cat "$REQ")"
grep -q "observation 1 of 3" "$MCLOG" && grep -q "observation 2 of 3" "$MCLOG" && ok \
  || bad "A: merge_tree_clean must count its observations 1 and 2: $(cat "$MCLOG")"
grep -q "for the 3th tick while GitHub still says DIRTY" "$MCLOG" && ok \
  || bad "A: the third observation must trust GitHub: $(cat "$MCLOG")"

echo "== B. flag up: the same lines, each one also a row =="
reset; flag up
OUT=$(run_sites)
[ "$OUT" = "$WANT_OUT" ] && ok || bad "B: answers differ with the flag up: $(printf '%s' "$OUT" | tr '\n' ' ')"
[ "$(cat "$ATT")" = "$WANT_ATT" ] && ok || bad "B: attempts.txt lines differ with the flag up:
$(cat "$ATT")"
for e in 100 200; do
  has_put o/r 5 cirerun "$HD $e" && ok || bad "B: mc_rerun_record at $e must PUT a cirerun row: $(cat "$REQ")"
  has_put o/r 5 requeued "$HD $e" && ok || bad "B: mc_requeued_record at $e must PUT a requeued row: $(cat "$REQ")"
done
has_put o/r 5 apread "$HD 100" && has_put o/r 5 apread "$HD 5000" && ok \
  || bad "B: both apread marks must be rows: $(cat "$REQ")"
has_put o/r 5 apread "$HD 200" && bad "B: a read inside the recheck window must write no apread row" || ok
# The row's sha carries mc_attempt_put_n's ` #<n>` counter (the route dedupes
# on sha), so the three observations are three distinct rows #1, #2, #3.
has_put o/r 5 mergetree "$HD #1" && has_put o/r 5 mergetree "$HD #2" && has_put o/r 5 mergetree "$HD #3" \
  && [ "$(grep -c "^PUT	o/r	5	mergetree	" "$REQ")" = 3 ] && ok \
  || bad "B: every mergetree observation must PUT through mc_attempt_put_n: $(cat "$REQ")"

echo "== C. static guard: no hand-rolled \$MC_ATTEMPTS access left =="
for f in "$CLASSIFY" "$REBASE"; do
  if [ ! -s "$f" ]; then bad "C: $f is missing — the guard cannot pass on an absent file"; continue; fi
  hits=$(grep -nE '>> "\$MC_ATTEMPTS"|grep -c[^|]*"\$MC_ATTEMPTS"|awk [^|]*"\$MC_ATTEMPTS"' "$f")
  [ -z "$hits" ] && ok || bad "C: $(basename "$f") still touches \$MC_ATTEMPTS by hand:
$hits"
done
# The guard's own pattern must bite: a line of the old shape is caught.
printf 'echo "x" >> "$MC_ATTEMPTS"\n' > "$T/probe.sh"
grep -qE '>> "\$MC_ATTEMPTS"|grep -c[^|]*"\$MC_ATTEMPTS"|awk [^|]*"\$MC_ATTEMPTS"' "$T/probe.sh" && ok \
  || bad "C: the guard pattern does not catch the shape it bans"

[ -s "$ERR" ] && grep -qE 'exit 9[01]|command not found|unbound variable' "$ERR" && bad "driver errors: $(cat "$ERR")"
echo "attempt-kinds-classify-rows.bh-2358: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
