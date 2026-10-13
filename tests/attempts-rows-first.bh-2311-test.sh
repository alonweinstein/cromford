#!/bin/bash
# tests/attempts-rows-first.bh-2311-test.sh — BH-2357 (BH-2311.1): the attempt
# ledger in bin/lib/mc/locks.sh answers from the `pr_attempts` ROWS first, and
# $MC_ATTEMPTS is a warm cache.
#
# WHAT IT PINS.
#   a. the file is gone and the row is there: mc_attempted is rc 0, the file is
#      warmed with exactly one line, and no new attempt is PUT.
#   b/c. an outage answers from the FILE (a hit is rc 0, a miss rc 1), latches
#      the tick, and a tick pays for at most one GET.
#   d. flag down: zero requests, the file answers.
#   backfill: a measured miss plus a file hit back-fills the row once.
#   non-PR lines never reach the worker.
#   put order: the row is PUT before the file line exists; a failed PUT is
#      logged once per tick and the file line is still written.
#   e. mc_attempt_put_n suffixes the row sha ` #n`, the file stays byte-identical,
#      and mc_attempt_count counts the rows with the file removed.
#   f/g. count on an outage is the file's; a measured none is 0 despite a stale
#      file line.
#   tail/lines strip the ` #n` suffix.
#   h. read_memo_fp totals rows across kinds for (KEY, HEAD).
#   lanefail: the note/count pair goes through the verbs and keeps its epoch.
#   negatives: head, repo, kind, kind prefix, key case, number prefix, a literal
#      ` #n` head.
#
# HOW IT MEASURES. A curl shim that IS a tiny pr_attempts store (a TSV of
# repo, number, kind, sha with the route's semantics: GET with a sha is 200 or
# 404, GET without one lists newest first, PUT dedupes on all four columns), its
# request log, the attempts file and the conductor log. The functions are the
# REAL ones, loaded through the REAL bin/lib/merge-conductor-lib.sh. Nothing
# outside $T is written.
#
# Run from anywhere: tests/attempts-rows-first.bh-2311-test.sh  (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/bin/lib/mc" "$H/env" "$H/flags" "$H/logs" \
         "$H/state/merge-conductor" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$H/bin/" || exit 1
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/" || exit 1
cp "$DIR/bin/lib/env-path.sh" "$H/bin/lib/" || exit 1
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$H/bin/lib/" || exit 1
cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/" || exit 1

ATT="$H/state/merge-conductor/attempts.txt"
TICKS="$H/state/merge-conductor/tick"
MCLOG="$H/logs/merge-conductor.log"
REQ="$T/req.log"
ROWS="$T/rows.tsv"
ORDER="$T/put-order.log"
ERR="$T/err.log"

# The fake worker. /api/flags/* is a 404 (flag_active falls to the flag FILE).
# CURL_MODE=down fails every /api/pr-attempts call at the transport (exit 7,
# rc 1 from _jobs_req). PUT_STATUS=500 fails every PUT with that status. A PUT
# that lands while the attempts file ALREADY holds its line is noted in $ORDER.
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL=""; METHOD=GET; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2;;
    --data-binary) BODY="$2"; shift 2;;
    -H|-m|--connect-timeout|-w) shift 2;;
    -*) shift;;
    *) URL="$1"; shift;;
  esac
done
printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_LOG"
case "$URL" in */api/flags/*) printf '{"error":"no such flag"}\n404\n'; exit 0 ;; esac
case "$URL" in */api/pr-attempts*) : ;; *) printf '{"error":"no route"}\n404\n'; exit 0 ;; esac
[ "${CURL_MODE:-ok}" = down ] && exit 7
touch "$ROWS"
qp() { local v; v=$(printf '%s' "${URL#*\?}" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1); printf '%b' "${v//%/\\x}"; }
if [ "$METHOD" = PUT ]; then
  [ -n "${PUT_STATUS:-}" ] && { printf '{"error":"boom"}\n%s\n' "$PUT_STATUS"; exit 0; }
  IFS=$'\t' read -r r n k s < <(printf '%s' "$BODY" | jq -r '[.repo, (.number|tostring), .kind, .sha] | @tsv')
  plain=$(printf '%s' "$s" | sed -E 's/ #[0-9]+$//')
  grep -qxF "$k $r#$n $plain" "$ATT_FILE" 2>/dev/null && echo "FILE-BEFORE-PUT $k $r#$n $s" >> "$ORDER_LOG"
  if awk -F'\t' -v r="$r" -v n="$n" -v k="$k" -v s="$s" '$1==r && $2==n && $3==k && $4==s {f=1} END {exit !f}' "$ROWS"; then
    printf '{"recorded":false,"duplicate":true}\n200\n'
  else
    printf '%s\t%s\t%s\t%s\n' "$r" "$n" "$k" "$s" >> "$ROWS"
    printf '{"recorded":true,"duplicate":false}\n201\n'
  fi
  exit 0
fi
r=$(qp repo); n=$(qp number); k=$(qp kind); s=$(qp sha)
if [ -n "$s" ]; then
  if awk -F'\t' -v r="$r" -v n="$n" -v k="$k" -v s="$s" '$1==r && $2==n && $3==k && $4==s {f=1} END {exit !f}' "$ROWS"; then
    printf '{"attempt":{}}\n200\n'
  else printf '{"error":"not found"}\n404\n'; fi
  exit 0
fi
# The list: newest first, as the route's ORDER BY at DESC, rowid DESC.
awk -F'\t' -v r="$r" -v n="$n" -v k="$k" '$1==r && $2==n && (k=="" || $3==k)' "$ROWS" | tac \
  | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {kind: .[2], sha: .[3]})
                 | {attempts: ., count: length}'
printf '200\n'
CURL
chmod +x "$T/fakebin/curl"

cat > "$T/drive.sh" <<'DRV'
#!/bin/bash
set -uo pipefail
# shellcheck source=/dev/null
. "$HARNESS/bin/jobs-client.sh" >/dev/null 2>&1 || exit 90
# shellcheck source=/dev/null
. "$HARNESS/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1 || exit 91
eval "$DRIVE_CODE"
DRV

# drv <tick-id|""> <snippet> — one fresh process, MC_TICK_ID exported as the
# conductor exports it, or unset when empty.
drv() {
  local tick="$1"
  env ${tick:+MC_TICK_ID="$tick"} DRIVE_CODE="$2" \
    PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=x JOBS_BOX=testbox \
    JOBS_RETRIES=0 JOBS_ALERT=0 JOBS_URL=http://jobs.test REQ_LOG="$REQ" \
    ROWS="$ROWS" ATT_FILE="$ATT" ORDER_LOG="$ORDER" \
    CURL_MODE="${CURL_MODE:-ok}" PUT_STATUS="${PUT_STATUS:-}" \
    bash "$T/drive.sh" 2>>"$ERR"
}
reset() {
  : > "$REQ"; : > "$ERR"; : > "$ATT"; : > "$MCLOG"; : > "$ROWS"; : > "$ORDER"
  scratch_rm "$TICKS" || exit 1; : > "$H/flags/pr-state-rows"
}
row()   { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$ROWS"; }
nreq()  { grep -c "^$1 http://jobs.test/api/pr-attempts" "$REQ" 2>/dev/null || true; }
nall()  { grep -c "http://jobs.test/api/pr-attempts" "$REQ" 2>/dev/null || true; }

echo "== a. the file is gone, the row is there: attempted, warmed once, nothing PUT =="
reset; rm -f "$ATT"; row o/r 1 rebase abc
OUT=$(drv ta "mc_attempted rebase o/r#1 abc; echo one=\$?; mc_attempt_has 'rebase o/r#1 abc'; echo two=\$?")
[ "$OUT" = "$(printf 'one=0\ntwo=0')" ] && ok || bad "a: want rc 0 twice, got [$OUT] $(cat "$ERR")"
[ "$(cat "$ATT" 2>/dev/null)" = "rebase o/r#1 abc" ] && ok || bad "a: the file must hold the line exactly once: [$(cat "$ATT" 2>/dev/null)]"
[ "$(nreq PUT)" = 0 ] && ok || bad "a: a row hit is no new attempt, want 0 PUT: $(cat "$REQ")"
# The same holds with the FILE still present and holding the line: rows first,
# no duplicate warm.
reset; row o/r 1 rebase abc; echo "rebase o/r#1 abc" > "$ATT"
OUT=$(drv ta2 "mc_attempt_has 'rebase o/r#1 abc'; echo rc=\$?")
[ "$OUT" = rc=0 ] && [ "$(wc -l < "$ATT")" = 1 ] && ok || bad "a: a hit must not duplicate a present file line: [$OUT] $(cat "$ATT")"
[ "$(nreq GET)" = 1 ] && ok || bad "a: rows are asked FIRST, even with the file line present: $(cat "$REQ")"

echo "== b. outage + file line: rc 0 =="
reset; echo "rebase o/r#1 abc" > "$ATT"
OUT=$(CURL_MODE=down drv tb "mc_attempt_has 'rebase o/r#1 abc'; echo rc=\$?")
[ "$OUT" = rc=0 ] && ok || bad "b: an outage must answer from the file (hit), got [$OUT]"
[ -e "$TICKS/tb.pr-rows-down" ] && ok || bad "b: the outage must latch the tick"

echo "== c. outage + no file line: rc 1, one GET a tick, the latch =="
reset
OUT=$(CURL_MODE=down drv tc "mc_attempt_has 'rebase o/r#1 abc'; echo one=\$?; mc_attempt_has 'rebase o/r#2 def'; echo two=\$?")
[ "$OUT" = "$(printf 'one=1\ntwo=1')" ] && ok || bad "c: want rc 1 twice, got [$OUT]"
[ "$(nreq GET)" = 1 ] && ok || bad "c: want 1 GET for the tick, got $(nreq GET): $(cat "$REQ")"
[ -e "$TICKS/tc.pr-rows-down" ] && ok || bad "c: the latch file must exist"
# A second worker of the same tick answers from the file with no request.
echo "rebase o/r#3 ghi" >> "$ATT"
OUT=$(CURL_MODE=down drv tc "mc_attempt_has 'rebase o/r#3 ghi'; echo rc=\$?")
[ "$OUT" = rc=0 ] && [ "$(nall)" = 1 ] && ok || bad "c: a latched tick answers from the file with 0 requests: [$OUT] $(cat "$REQ")"

echo "== d. flag down: zero requests, the file answers =="
reset; rm -f "$H/flags/pr-state-rows"; row o/r 1 rebase abc; echo "rebase o/r#2 def" > "$ATT"
OUT=$(drv td "mc_attempt_has 'rebase o/r#1 abc'; echo miss=\$?; mc_attempt_has 'rebase o/r#2 def'; echo hit=\$?
  mc_attempt_put 'rebase o/r#4 x'; mc_attempt_put_n mergefail o/r#2 h1; mc_attempt_count mergefail o/r#2 h1
  read_memo_fp o/r#2 def; echo")
[ "$OUT" = "$(printf 'miss=1\nhit=0\n1\n1')" ] && ok || bad "d: flag down must be the file's answers, got [$OUT]"
[ "$(nall)" = 0 ] && ok || bad "d: flag down must make 0 pr-attempts requests: $(cat "$REQ")"

echo "== backfill: a measured miss + a file hit back-fills the row once =="
reset; echo "rebase o/r#1 abc" > "$ATT"
OUT=$(drv tf "mc_attempt_has 'rebase o/r#1 abc'; echo one=\$?; mc_attempt_has 'rebase o/r#1 abc'; echo two=\$?")
[ "$OUT" = "$(printf 'one=0\ntwo=0')" ] && ok || bad "backfill: want rc 0 twice, got [$OUT]"
[ "$(nreq PUT)" = 1 ] && ok || bad "backfill: want exactly 1 PUT, got $(nreq PUT): $(cat "$REQ")"
grep -q '"repo":"o/r","number":1,"kind":"rebase","sha":"abc"' "$REQ" && ok || bad "backfill: the PUT must carry the line's key: $(cat "$REQ")"
[ "$(cat "$ROWS")" = "$(printf 'o/r\t1\trebase\tabc')" ] && ok || bad "backfill: the store must hold the row: $(cat "$ROWS")"

echo "== non-PR lines never reach the worker =="
reset
OUT=$(drv tn "mc_attempt_has 'identityalert hub gh-app 20260922'; echo miss=\$?; mc_attempt_put 'identityalert hub gh-app 20260922'
  mc_attempt_has 'identityalert hub gh-app 20260922'; echo hit=\$?")
[ "$OUT" = "$(printf 'miss=1\nhit=0')" ] && ok || bad "non-PR: want the file's answers, got [$OUT]"
[ "$(nall)" = 0 ] && ok || bad "non-PR: want 0 requests: $(cat "$REQ")"

echo "== put order: the row first, then the file =="
reset
drv tp "mc_attempt_put 'rebase o/r#1 abc'; mc_attempt_put_n mergefail o/r#2 h1" >/dev/null
[ "$(nreq PUT)" = 2 ] && ok || bad "put order: want 2 PUTs: $(cat "$REQ")"
[ ! -s "$ORDER" ] && ok || bad "put order: a PUT landed AFTER its file line: $(cat "$ORDER")"
[ "$(cat "$ATT")" = "$(printf 'rebase o/r#1 abc\nmergefail o/r#2 h1')" ] && ok || bad "put order: file lines: $(cat "$ATT")"

echo "== putfail: logged once a tick, the file line still written =="
reset
PUT_STATUS=500 drv tq "mc_attempt_put 'rebase o/r#1 abc'; mc_attempt_put 'rebase o/r#2 def'" >/dev/null
PUT_STATUS=500 drv tq "mc_attempt_put 'rebase o/r#3 ghi'" >/dev/null
[ "$(cat "$ATT")" = "$(printf 'rebase o/r#1 abc\nrebase o/r#2 def\nrebase o/r#3 ghi')" ] && ok || bad "putfail: every file line must be written: $(cat "$ATT")"
[ "$(grep -c 'row write failed' "$MCLOG")" = 1 ] && ok || bad "putfail: want exactly 1 'row write failed' line for the tick: $(cat "$MCLOG")"
[ "$(nreq PUT)" = 3 ] && ok || bad "putfail: a failed PUT must not latch writes off: $(cat "$REQ")"
PUT_STATUS=500 drv tq2 "mc_attempt_put 'rebase o/r#4 jkl'" >/dev/null
[ "$(grep -c 'row write failed' "$MCLOG")" = 2 ] && ok || bad "putfail: a new tick logs again: $(cat "$MCLOG")"
PUT_STATUS=500 drv "" "mc_attempt_put 'rebase o/r#5 a'; mc_attempt_put 'rebase o/r#6 b'" >/dev/null
[ "$(grep -c 'row write failed' "$MCLOG")" = 3 ] && ok || bad "putfail: no tick logs once per process: $(cat "$MCLOG")"

echo "== e. put_n: row sha #n, file byte-identical, count from rows =="
reset
drv te "mc_attempt_put_n mergefail o/r#2 h1; mc_attempt_put_n mergefail o/r#2 h1; mc_attempt_put_n mergefail o/r#2 h1" >/dev/null
for n in 1 2 3; do
  grep -q "\"kind\":\"mergefail\",\"sha\":\"h1 #$n\"" "$REQ" && ok || bad "e: want a PUT with sha 'h1 #$n': $(cat "$REQ")"
done
printf 'mergefail o/r#2 h1\nmergefail o/r#2 h1\nmergefail o/r#2 h1\n' > "$T/want"
cmp -s "$ATT" "$T/want" && ok || bad "e: the file must hold three identical plain lines: $(cat "$ATT")"
rm -f "$ATT"
OUT=$(drv te2 "mc_attempt_count mergefail o/r#2 h1")
[ "$OUT" = 3 ] && ok || bad "e: count from rows with the file removed want 3, got [$OUT]"
OUT=$(drv te3 "mc_attempt_lines mergefail o/r#2 '$T/lines'; echo rc=\$?")
[ "$OUT" = rc=0 ] && cmp -s "$T/lines" "$T/want" && ok || bad "e: lines from rows must be the plain lines: [$OUT] $(cat "$T/lines")"

echo "== f. an outage counts the file =="
reset; printf 'mergefail o/r#2 h1\nmergefail o/r#2 h1\nmergefail o/r#2 h2\n' > "$ATT"; row o/r 2 mergefail 'h1 #1'
OUT=$(CURL_MODE=down drv tg "mc_attempt_count mergefail o/r#2 h1")
[ "$OUT" = 2 ] && ok || bad "f: want the file's 2, got [$OUT]"

echo "== g. a measured none is 0 despite a stale file line =="
reset; echo "mergefail o/r#2 h9" > "$ATT"
OUT=$(drv th "mc_attempt_count mergefail o/r#2 h1; mc_attempt_count mergefail o/r#2 h9
  mc_attempt_lines mergefail o/r#2 '$T/lines'; echo rc=\$?; mc_attempt_tail mergefail o/r#2 h9; echo tail")
[ "$OUT" = "$(printf '0\n0\nrc=2\ntail')" ] && ok || bad "g: want 0, 0, rc=2 and no tail, got [$OUT]"

echo "== tail/lines strip the #n suffix =="
reset; row o/r 3 lanedown 'h1 100 #1'; row o/r 3 lanedown 'h1 200 #2'; row o/r 3 lanedown 'h2 300 #1'
OUT=$(drv tt "mc_attempt_tail lanedown o/r#3 h1 first; mc_attempt_tail lanedown o/r#3 h1 last; mc_attempt_count lanedown o/r#3 h1")
[ "$OUT" = "$(printf '100\n200\n2')" ] && ok || bad "tail: want first 100, last 200, count 2, got [$OUT]"
drv tt "mc_attempt_lines 'lanedown|red' o/r#3 '$T/lines'" >/dev/null
[ "$(cat "$T/lines")" = "$(printf 'lanedown o/r#3 h1 100\nlanedown o/r#3 h1 200\nlanedown o/r#3 h2 300')" ] && ok || bad "lines: oldest first, suffix stripped: $(cat "$T/lines")"

echo "== h. read_memo_fp totals rows across kinds =="
reset; rm -f "$ATT"; row o/r 1 cikick h1; row o/r 1 red 'h1 #1'; row o/r 1 rebase h2
OUT=$(drv tm "read_memo_fp o/r#1 h1")
[ "$OUT" = 2 ] && ok || bad "h: want 2 rows for h1, got [$OUT]"
grep -q 'GET http://jobs.test/api/pr-attempts?repo=o%2Fr&number=1 ' "$REQ" && ok || bad "h: want ONE list GET without a kind: $(cat "$REQ")"
printf 'cikick o/r#1 h1\nred o/r#1 h1\ncirerun o/r#1 h1\n' > "$ATT"
OUT=$(CURL_MODE=down drv tm2 "read_memo_fp o/r#1 h1")
[ "$OUT" = 3 ] && ok || bad "h: an outage counts the file's 3, got [$OUT]"
# Rows up and a file-only touch (cirerun has no row yet): the touch still moves it.
printf 'cirerun o/r#1 h1\n' > "$ATT"
OUT=$(drv tm3 "read_memo_fp o/r#1 h1")
[ "$OUT" = 3 ] && ok || bad "h: rows 2 + a file-only touch want 3, got [$OUT]"

echo "== lanefail: through the verbs, keyed by epoch =="
LF="lanefail o/r#4 hh 5"
NOTE="mc_rr_lanefail_note o/r#4 hh 5; mc_rr_lanefail_note o/r#4 hh 5; mc_rr_lanefail_note o/r#4 hh 6"
COUNT="mc_rr_lanefail_count o/r#4 hh 5; echo; mc_rr_lanefail_count o/r#4 hh 6; echo; mc_rr_lanefail_count o/r#4 hh 7"
reset
drv tl "$NOTE" >/dev/null
[ "$(cat "$ATT")" = "$(printf '%s\n%s\nlanefail o/r#4 hh 6' "$LF" "$LF")" ] && ok || bad "lanefail: file lines: $(cat "$ATT")"
grep -q '"kind":"lanefail","sha":"hh 5 #2"' "$REQ" && ok || bad "lanefail: the second epoch-5 note must be row #2: $(cat "$REQ")"
rm -f "$ATT"
OUT=$(drv tl2 "$COUNT")
[ "$OUT" = "$(printf '2\n1\n0')" ] && ok || bad "lanefail: from rows want 2/1/0, got [$OUT]"
reset; rm -f "$H/flags/pr-state-rows"
drv tl3 "$NOTE" >/dev/null
OUT=$(drv tl3 "$COUNT")
[ "$OUT" = "$(printf '2\n1\n0')" ] && [ "$(nall)" = 0 ] && ok || bad "lanefail: flag down from the file want 2/1/0 and 0 requests, got [$OUT]"

echo "== negatives: every near miss is a miss =="
reset; rm -f "$ATT"
row o/r 1 rebase abc; row o/r 1 requeued2 'h1 #1'; row o/r 123 mergefail 'h1 #1'; row o/r 2 mergefail 'h1 #3'
OUT=$(drv tx "
  mc_attempt_has 'rebase o/r#1 def'; echo head=\$?
  mc_attempt_has 'rebase o/x#1 abc'; echo repo=\$?
  mc_attempt_has 'rereview o/r#1 abc'; echo kind=\$?
  mc_attempt_has 'rebase O/R#1 abc'; echo case=\$?
  mc_attempt_has 'mergefail o/r#2 h1 #3'; echo literal=\$?
  mc_attempt_count requeued o/r#1 h1
  mc_attempt_count mergefail o/r#12 h1
  mc_attempt_count rebase O/R#1 abc
  mc_attempt_count rebase o/r#1 ab")
[ "$OUT" = "$(printf 'head=1\nrepo=1\nkind=1\ncase=1\nliteral=1\n0\n0\n0\n0')" ] && ok || bad "negatives: want every ask a miss, got [$OUT]"
[ ! -s "$ATT" ] && ok || bad "negatives: a miss must warm nothing: $(cat "$ATT")"

echo "attempts-rows-first.bh-2311: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
