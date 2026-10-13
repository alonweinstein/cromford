#!/bin/bash
# tests/fix-round-queue-idempotent.bh-2992-test.sh — BH-2997 (BH-2992.3): a
# retried fix_round_finish / fix_round_adopt whose first answer was lost gets a
# 409 carrying the row it already moved. bin/lib/fix-round-queue.sh reads that
# row and answers rc 0 only when the row proves the replay; every other 409
# stays rc 9.
#
# Same rig as tests/fix-round-queue.bh-2668-test.sh: the checkout's
# bin/jobs-client.sh and bin/lib/jobs/*.sh in a scratch harness, the real lib
# sourced after them, and a curl shim first on PATH answering from
# $T/ans/<n> (body) and $T/ans/<n>.code (HTTP status). 409 bodies are the
# worker's shape (worker/jobs/src/routes/fix-rounds.js finish/adopt).
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/fix-round-queue-idempotent.bh-2992-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/fix-round-queue.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/h/bin/lib/jobs" "$T/fakebin" "$T/ans"
cp "$DIR/bin/jobs-client.sh" "$T/h/bin/jobs-client.sh"
cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
T="$T"
EOF
cat >> "$T/fakebin/curl" <<'EOF'
method=GET body="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data-binary) body="$2"; shift 2 ;;
    -m|--connect-timeout|-w|-H) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
n=$(( $(cat "$T/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$T/n"
case "$body" in @*) body=$(cat "${body#@}") ;; esac
printf '%s %s\n' "$method" "$url" >> "$T/curl.log"
printf '%s' "$body" > "$T/body.$n"
[ -f "$T/ans/$n.rc" ] && exit "$(cat "$T/ans/$n.rc")"
[ -f "$T/ans/$n" ] && cat "$T/ans/$n"
printf '\n%s' "$(cat "$T/ans/$n.code" 2>/dev/null || echo 200)"
EOF
chmod +x "$T/fakebin/curl"

URL=https://jobs.invalid
run() {
  ( export HARNESS="$T/h" HARNESS_SECRET=test-secret JOBS_URL="$URL" JOBS_BOX=testbox JOBS_RETRIES=0 JOBS_RETRY_SLEEP=0
    export PATH="$T/fakebin:$PATH"
    # shellcheck source=/dev/null
    . "$T/h/bin/jobs-client.sh" >/dev/null 2>&1
    # shellcheck source=/dev/null
    . "$LIB" || exit 99
    "$@" )
}
reset() { rm -rf "$T/ans" "$T/curl.log" "$T"/body.* "$T/n" "$T/h/logs" "$T/h/flags"; mkdir -p "$T/ans"; }
ans() { printf '%s' "$2" > "$T/ans/$1"; printf '%s' "${3:-200}" > "$T/ans/$1.code"; }
# r409 <verb> <job-json> — the worker's 409 body around a row.
r409() { jq -nc --arg v "$1" --argjson j "$2" '{error:"\($v) refused: row is \($j.status)", refused:true, scope:"fix-rounds", job:$j}'; }
job() { jq -nc --arg s "$1" --arg c "$2" --arg r "$3" \
  '{id:7, project:"p", cap_key:"ck", box:"b1", status:$s,
    claimed_by:(if $c == "" then null else $c end), result:(if $r == "" then null else $r end), attempt:1}'; }
LOG="$T/h/logs/jobs-client.log"
ALERTS="$T/h/logs/ALERTS.log"

# --- F1. replayed finish, row done on this box with this result: rc 0 --------
reset; ans 1 "$(r409 finish "$(job done b1 done)")" 409
OUT=$(run fix_round_finish 7 b1 done); RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok || bad "F1: rc=$RC out='$OUT'"
[ "$(grep -c replay "$LOG" 2>/dev/null)" = 1 ] && ok || bad "F1: want one replay line in jobs-client.log, got: $(cat "$LOG" 2>/dev/null)"
[ ! -e "$ALERTS" ] && ok || bad "F1: a replay wrote ALERTS.log: $(cat "$ALERTS")"
[ "$(sed -n 1p "$T/curl.log")" = "POST $URL/api/fix-rounds/finish" ] && [ "$(wc -l < "$T/curl.log")" -eq 1 ] \
  && ok || bad "F1: requests $(cat "$T/curl.log")"

# --- F2. the same row already adopted: rc 0 ---------------------------------
reset; ans 1 "$(r409 finish "$(job adopted b1 done)")" 409
run fix_round_finish 7 b1 done >/dev/null; RC=$?
[ "$RC" -eq 0 ] && ok || bad "F2: adopted replay rc=$RC"

# --- F3. done by ANOTHER box: rc 9 ------------------------------------------
reset; ans 1 "$(r409 finish "$(job done b2 done)")" 409
run fix_round_finish 7 b1 done >/dev/null; RC=$?
[ "$RC" -eq 9 ] && ok || bad "F3: other box rc=$RC"

# --- F4. done by this box with a DIFFERENT result: rc 9 ---------------------
reset; ans 1 "$(r409 finish "$(job done b1 terminal)")" 409
run fix_round_finish 7 b1 done >/dev/null; RC=$?
[ "$RC" -eq 9 ] && ok || bad "F4: different result rc=$RC"
[ ! -e "$LOG" ] || ! grep -q replay "$LOG" && ok || bad "F4: logged a replay: $(cat "$LOG")"

# --- F5. still claimed by this box (and queued, claimed_by null): rc 9 -------
reset; ans 1 "$(r409 finish "$(job claimed b1 '')")" 409
run fix_round_finish 7 b1 done >/dev/null; RC=$?
[ "$RC" -eq 9 ] && ok || bad "F5: still claimed rc=$RC"
reset; ans 1 "$(r409 finish "$(job queued '' '')")" 409
run fix_round_finish 7 b1 done >/dev/null; RC=$?
[ "$RC" -eq 9 ] && ok || bad "F5: queued rc=$RC"

# --- F6. a 409 whose body proves nothing: rc 9 ------------------------------
for b in '{}' 'not json' '' '{"job":"done"}' '{"job":null}'; do
  reset; ans 1 "$b" 409
  run fix_round_finish 7 b1 done >/dev/null; RC=$?
  [ "$RC" -eq 9 ] && ok || bad "F6: body '$b' rc=$RC"
done

# --- F7. a result with a space, compared as one exact string ----------------
reset; ans 1 "$(r409 finish "$(job done b1 'setup-blocked tok1')")" 409
run fix_round_finish 7 b1 'setup-blocked tok1' >/dev/null; RC=$?
[ "$RC" -eq 0 ] && ok || bad "F7: exact spaced result rc=$RC"
reset; ans 1 "$(r409 finish "$(job done b1 'setup-blocked tok1')")" 409
run fix_round_finish 7 b1 'setup-blocked tok2' >/dev/null; RC=$?
[ "$RC" -eq 9 ] && ok || bad "F7: other token rc=$RC"

# --- A1. replayed adopt, row adopted: rc 0 and the job printed --------------
reset; ans 1 "$(r409 adopt "$(job adopted b1 done)")" 409
OUT=$(run fix_round_adopt 7); RC=$?
[ "$RC" -eq 0 ] && [ "$(jq -r .status <<<"$OUT" 2>/dev/null)" = adopted ] && [ "$(jq -r .id <<<"$OUT" 2>/dev/null)" = 7 ] \
  && ok || bad "A1: rc=$RC out='$OUT'"
[ "$(sed -n 1p "$T/curl.log")" = "POST $URL/api/fix-rounds/adopt" ] && ok || bad "A1: request $(cat "$T/curl.log")"

# --- A2. adopt 409 on a queued row: rc 9, nothing printed -------------------
reset; ans 1 "$(r409 adopt "$(job queued '' '')")" 409
OUT=$(run fix_round_adopt 7); RC=$?
[ "$RC" -eq 9 ] && [ -z "$OUT" ] && ok || bad "A2: queued rc=$RC out='$OUT'"

# --- A3. adopt 409 on a done or claimed row, or an unproving body: rc 9 ------
for s in done claimed; do
  reset; ans 1 "$(r409 adopt "$(job "$s" b1 done)")" 409
  OUT=$(run fix_round_adopt 7); RC=$?
  [ "$RC" -eq 9 ] && [ -z "$OUT" ] && ok || bad "A3: $s rc=$RC out='$OUT'"
done
for b in '{}' 'not json'; do
  reset; ans 1 "$b" 409
  OUT=$(run fix_round_adopt 7); RC=$?
  [ "$RC" -eq 9 ] && [ -z "$OUT" ] && ok || bad "A3: body '$b' rc=$RC out='$OUT'"
done

echo "fix-round-queue-idempotent: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
