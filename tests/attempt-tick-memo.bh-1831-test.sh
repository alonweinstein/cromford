#!/bin/bash
# tests/attempt-tick-memo.bh-1831-test.sh — BH-1831 item 4: mc_attempt_has pays
# for a pr_attempts GET at most once per (tick, line), and an outage latches the
# row twin off for the WHOLE tick, not just the worker subshell that saw it.
#
# WHY. bin/merge-conductor.sh runs `pr_worker "$ROW" &` per PR, so every worker
# is its own subshell. pr_rows_trip sets a shell variable, which dies with the
# worker that set it: on a worker outage every other worker paid its own GET
# (and its own connect timeout) before tripping its own copy of the latch. And a
# file miss cost one GET every time it was asked, even for a line this tick had
# already been told is absent.
#
# WHAT IT PINS.
#   A. one tick, the same missing line asked twice -> exactly 1 GET.
#   B. the pr_worker & shape: a first background worker sees an outage, a
#      second worker (its own subshell) then makes 0 GETs and 0 PUTs, the parent
#      shell makes 0 GETs, and exactly ONE "latched off" line is logged — also
#      when five workers hit the outage at the same time.
#   C. a new MC_TICK_ID asks again: the memo and the latch are per tick.
#   D. a memoised miss never hides a fresh write: put, then has, is rc 0.
#   E. an outage is never "already attempted": rc 1 and no file line.
#   F. with MC_TICK_ID unset (blocked-resolver and other non-conductor callers)
#      two asks are two GETs, exactly as before.
#
# HOW IT MEASURES. The request sink a curl shim writes, the rc of the call, the
# attempts file and the conductor log. mc_attempt_has / mc_attempt_put are the
# REAL functions, loaded through the REAL bin/lib/merge-conductor-lib.sh, the
# library bin/merge-conductor.sh sources. No clock, no network: tick ids are
# literals and the shim answers from env vars. Nothing outside $T is written.
#
# Run from anywhere: tests/attempt-tick-memo.bh-1831-test.sh  (exit 0 = all pass)
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
ERR="$T/err.log"

# The curl shim: records METHOD URL, answers /api/flags/* with a 404 (so
# flag_active falls to the flag FILE), everything else with $CURL_STATUS.
# CURL_MODE=down is a transport failure (exit 7), i.e. rc 1 from _jobs_req.
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2;;
    --data-binary|-H|-m|--connect-timeout|-w) shift 2;;
    -*) shift;;
    *) URL="$1"; shift;;
  esac
done
printf '%s %s\n' "$METHOD" "$URL" >> "$REQ_LOG"
case "$URL" in */api/flags/*) printf '{"error":"no such flag"}\n404\n'; exit 0 ;; esac
[ "${CURL_MODE:-ok}" = down ] && exit 7
if [ "${CURL_STATUS:-200}" = 404 ]; then printf '{"error":"no row"}\n404\n'
else printf '{"ok":true}\n%s\n' "${CURL_STATUS:-200}"; fi
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

# drv <tick-id|""> <snippet> — one fresh process; MC_TICK_ID exported as the
# conductor exports it (bin/merge-conductor.sh), or unset when empty.
drv() {
  local tick="$1"
  env ${tick:+MC_TICK_ID="$tick"} DRIVE_CODE="$2" \
    PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=x JOBS_BOX=testbox \
    JOBS_RETRIES=0 JOBS_ALERT=0 JOBS_URL=http://jobs.test REQ_LOG="$REQ" \
    CURL_MODE="${CURL_MODE:-ok}" CURL_STATUS="${CURL_STATUS:-}" \
    bash "$T/drive.sh" 2>>"$ERR"
}
reset() { : > "$REQ"; : > "$ERR"; : > "$ATT"; : > "$MCLOG"; scratch_rm "$TICKS" || exit 1; : > "$H/flags/pr-state-rows"; }
ngets() { grep -c '^GET http://jobs.test/api/pr-attempts' "$REQ" 2>/dev/null || true; }
nputs() { grep -c '^PUT http://jobs.test/api/pr-attempts' "$REQ" 2>/dev/null || true; }
nlatch() { grep -c 'latched off for tick' "$MCLOG" 2>/dev/null || true; }
L='rebase example-org/x#12 abc'

echo "== A. one tick: the same missing line asked twice is ONE GET =="
reset
OUT=$(CURL_STATUS=404 drv t1 "mc_attempt_has '$L'; echo one=\$?; mc_attempt_has '$L'; echo two=\$?")
[ "$OUT" = "$(printf 'one=1\ntwo=1')" ] && ok || bad "A: both asks must be rc 1: $OUT"
[ "$(ngets)" = 1 ] && ok || bad "A: want 1 GET, got $(ngets): $(cat "$REQ")"
# ...and the memo is shared by a SECOND worker process in the same tick.
OUT=$(CURL_STATUS=404 drv t1 "mc_attempt_has '$L'; echo three=\$?")
[ "$OUT" = three=1 ] && ok || bad "A: a later worker's ask must be rc 1: $OUT"
[ "$(ngets)" = 1 ] && ok || bad "A: a later worker in the same tick must not GET again, got $(ngets)"
[ ! -s "$ATT" ] && ok || bad "A: a miss must write no file line: $(cat "$ATT")"

echo "== B. the pr_worker & shape: one outage latches the whole tick =="
reset
CURL_MODE=down drv t2 "
  ( mc_attempt_has '$L'; echo w1=\$? ) & wait
  ( mc_attempt_put 'rebase example-org/x#13 def'; mc_attempt_has 'rebase example-org/x#16 jkl'; echo w2=\$? ) & wait
  mc_attempt_has 'rebase example-org/x#14 ghi'; echo parent=\$?
" > "$T/oB"
[ "$(tr '\n' ' ' < "$T/oB")" = "w1=1 w2=1 parent=1 " ] && ok || bad "B: every ask must be rc 1: $(cat "$T/oB")"
[ "$(ngets)" = 1 ] && ok || bad "B: only the first worker may GET, got $(ngets): $(cat "$REQ")"
[ "$(nputs)" = 0 ] && ok || bad "B: a latched tick must not PUT, got $(nputs): $(cat "$REQ")"
grep -qxF 'rebase example-org/x#13 def' "$ATT" && ok || bad "B: the latched put must still write the FILE line: $(cat "$ATT")"
[ "$(nlatch)" = 1 ] && ok || bad "B: want exactly 1 'latched off' log line, got $(nlatch): $(cat "$MCLOG")"
grep -q 'latched off for tick t2' "$MCLOG" && ok || bad "B: the log line must name the tick: $(cat "$MCLOG")"
# Five workers hitting the outage at once still log it once.
reset
CURL_MODE=down drv t2b "
  for n in 21 22 23 24 25; do ( mc_attempt_has \"rebase example-org/x#\$n abc\" ) & done; wait
" >/dev/null
[ "$(nlatch)" = 1 ] && ok || bad "B: 5 concurrent outages must log once, got $(nlatch): $(cat "$MCLOG")"

echo "== C. a new tick asks again =="
reset
CURL_STATUS=404 drv t3 "mc_attempt_has '$L'" >/dev/null
CURL_STATUS=404 drv t4 "mc_attempt_has '$L'" >/dev/null
[ "$(ngets)" = 2 ] && ok || bad "C: a memoised miss must not survive into the next tick, got $(ngets) GETs"
reset
CURL_MODE=down drv t5 "mc_attempt_has '$L'" >/dev/null
OUT=$(CURL_STATUS=200 drv t6 "mc_attempt_has '$L'; echo rc=\$?")
[ "$(ngets)" = 2 ] && ok || bad "C: the latch must not survive into the next tick, got $(ngets) GETs"
[ "$OUT" = rc=0 ] && ok || bad "C: the next tick must read the row again: $OUT"

echo "== D. a memoised miss never hides a fresh write =="
reset
OUT=$(CURL_STATUS=404 drv t7 "mc_attempt_has '$L'; echo miss=\$?; mc_attempt_put '$L'; mc_attempt_has '$L'; echo hit=\$?")
[ "$OUT" = "$(printf 'miss=1\nhit=0')" ] && ok || bad "D: put after a memoised miss must read as attempted: $OUT"
OUT=$(CURL_STATUS=404 drv t8 "mc_attempted rebase example-org/x#15 abc; echo one=\$?; mc_attempted rebase example-org/x#15 abc; echo two=\$?")
[ "$OUT" = "$(printf 'one=1\ntwo=0')" ] && ok || bad "D: mc_attempted must be rc 1 then rc 0: $OUT"

echo "== E. an outage is never 'already attempted' =="
reset
OUT=$(CURL_MODE=down drv t9 "mc_attempt_has '$L'; echo rc=\$?")
[ "$OUT" = rc=1 ] && ok || bad "E: an outage must be rc 1: $OUT"
[ ! -s "$ATT" ] && ok || bad "E: an outage must write no file line: $(cat "$ATT")"
[ ! -s "$TICKS/t9.attempt-miss" ] && ok || bad "E: an outage must not be memoised as a miss: $(cat "$TICKS/t9.attempt-miss")"
# A hit is not memoised either: it warms the file, as before.
reset
OUT=$(CURL_STATUS=200 drv t10 "mc_attempt_has '$L'; echo rc=\$?")
[ "$OUT" = rc=0 ] && ok || bad "E: a row hit must be rc 0: $OUT"
grep -qxF "$L" "$ATT" && ok || bad "E: a row hit must warm the file: $(cat "$ATT")"

echo "== F. no MC_TICK_ID: today's behaviour =="
reset
OUT=$(CURL_STATUS=404 drv "" "mc_attempt_has '$L'; echo one=\$?; mc_attempt_has '$L'; echo two=\$?")
[ "$OUT" = "$(printf 'one=1\ntwo=1')" ] && ok || bad "F: both asks must be rc 1: $OUT"
[ "$(ngets)" = 2 ] && ok || bad "F: with no tick every ask is a GET, got $(ngets)"
[ ! -d "$TICKS" ] || [ -z "$(ls -A "$TICKS")" ] && ok || bad "F: no tick files without a tick: $(ls "$TICKS")"
[ "$(nlatch)" = 0 ] && ok || bad "F: no latch log without a tick: $(cat "$MCLOG")"

echo "attempt-tick-memo: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
