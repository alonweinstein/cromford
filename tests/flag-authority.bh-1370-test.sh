#!/bin/bash
# tests/flag-authority.bh-1370-test.sh — BH-1370: the pause_flags row is the
# truth and flags/<name> is its derived cache, reconciled LAST-WRITER-WINS on the
# row's updated_at against the file's mtime (the row wins ties).
#
# THE DEFECT THIS PINS (docs/audit-sources/audit-cron-vs-db.md §2.3 row 7): the
# console sets paused-project-3 (row @T1), the box applies it and records T1 in a
# watermark, an operator `rm`s the file, and because the row still reads
# active@T1 it is never applied again — the console shows paused and the box
# builds. Case 3 is that sentence, driven.
#
# Driven, not grepped: every case runs the real bin/jobs-client.sh (and, in
# case 10, the REAL bin/lander.sh) against a stubbed
# worker and asserts on the flag file, its mtime, the rc and the request sink.
#
# No network, no model call, one clock read (NOW, below). Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 tests/flag-authority.bh-1370-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

NOW=$(date -u +%s)
T1=2026-09-19T01:00:00Z; E1=1789779600
T2=2026-09-19T02:00:00Z; E2=1789783200
EPUT=1789786800            # the stub PUT's updated_at, 2026-09-19T03:00:00Z

# The stub answers GET /api/flags/<name> from $ROWS/<name>.json (404 when there
# is no such file), PUT /api/flags with a FIXED updated_at, and records every
# request. CURL_MODE=down|500|empty are the outage arms.
mkdir -p "$T/fakebin"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in
  down)  exit 7 ;;
  500)   printf '{}\n500\n'; exit 0 ;;
  empty) printf '\n200\n'; exit 0 ;;
esac
case "$METHOD $URL" in
  "PUT "*/api/flags) printf '{"flag":{"name":"x","active":1,"updated_at":"2026-09-19T03:00:00Z"}}\n200\n' ;;
  "GET "*/api/flags/*)
    n="${URL##*/}"
    if [ -s "${ROWS:-/nonexistent}/$n.json" ]; then cat "$ROWS/$n.json"; printf '\n200\n'
    else printf '{"error":"not found"}\n404\n'; fi ;;
  *) printf '{}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

mt() { stat -c %Y "$1" 2>/dev/null; }

# client_h <harness-root> — a scratch harness with the client and its modules.
client_h() {
  mkdir -p "$1/bin/lib/jobs" "$1/flags" "$1/state" "$1/logs" "$1/env" "$1/rows"
  cp "$DIR/bin/jobs-client.sh" "$1/bin/"
  cp "$DIR"/bin/lib/jobs/*.sh "$1/bin/lib/jobs/"
  # scratch-closure-allow: BH-4080 the lane under test runs under env -i or in its own harness root, so HARNESS_DEPLOYMENT_FILE does not reach it and bin/lib/deployment.sh must sit beside its copied libs
  cp "$DIR/bin/lib/deployment.sh" "$1/bin/lib/"  # BH-4080: sourced by the copied lanes
  echo "HARNESS_SECRET=test-secret" > "$1/env/global.env"
}

F1="$T/f1"; client_h "$F1"
# TEST-CHANGE BH-4153: cases 1-9 and 12 drive alerts-db, not paused-p. paused-*
# is a ported family now (FLAG_PORTED_RE, bin/lib/jobs/flags.sh): its row is the
# truth and no flags/ file is written for it on a configured box. alerts-db is
# not ported, so the row-drives-the-file reconcile below is still BH-1370's, and
# every assertion keeps its meaning. Case 13 pins the ported side.
FLAG="$F1/flags/alerts-db"
row() { # row <active-json> <updated_at|-> ; '-' leaves updated_at out
  if [ "$2" = - ]; then printf '{"flag":{"name":"alerts-db","active":%s}}' "$1" > "$F1/rows/alerts-db.json"
  else printf '{"flag":{"name":"alerts-db","active":%s,"updated_at":"%s"}}' "$1" "$2" > "$F1/rows/alerts-db.json"; fi
}
rawrow() { printf '%s' "$1" > "$F1/rows/alerts-db.json"; }
norow()  { rm -f "$F1/rows/alerts-db.json"; }
client() { # client <verb> [args...] against fixture $CH (default F1)
  local H="${CH:-$F1}"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_RETRIES=0 \
           JOBS_URL=https://jobs.invalid ROWS="$H/rows" REQ_SINK="$H/req.log" ${EXTRA_ENV:-}
    bash "$H/bin/jobs-client.sh" "$@" >/dev/null 2>&1 )
}

echo "== 1. row active @T1, file absent: created, stamped with the row's time =="
row 1 "$T1"; rm -f "$FLAG"
client flag-active alerts-db; RC=$?
[ "$RC" = 0 ] && ok || bad "1: flag_active rc $RC for an active row"
[ -f "$FLAG" ] && ok || bad "1: an active row did not create the file"
[ "$(mt "$FLAG")" = "$E1" ] && ok || bad "1: the created file's mtime is $(mt "$FLAG"), not the row's $E1"

echo "== 2. row inactive @T2 > file mtime @T1: removed =="
row 0 "$T2"
client flag-active alerts-db; RC=$?
[ "$RC" = 1 ] && ok || bad "2: flag_active rc $RC for a cleared flag"
[ ! -e "$FLAG" ] && ok || bad "2: a newer inactive row did not remove the file"

echo "== 3. §2.3 #7: row active @T1, file rm'd locally — the row puts it back =="
row 1 "$T1"; rm -f "$FLAG"
client flag-active alerts-db
rm -f "$FLAG"
client flag-active alerts-db; RC=$?
[ "$RC" = 0 ] && ok || bad "3: the console says paused and flag_active answered rc $RC — the box would build"
[ -f "$FLAG" ] && ok || bad "3: an unchanged active row did not recreate a locally removed file"
[ "$(mt "$FLAG")" = "$E1" ] && ok || bad "3: the recreated file carries mtime $(mt "$FLAG"), not the row's $E1"

echo "== 4. tie: row inactive with updated_at == file mtime — the row wins =="
touch -d "@$E2" "$FLAG"; row 0 "$T2"
client flag-active alerts-db; RC=$?
[ ! -e "$FLAG" ] && ok || bad "4: a tie must go to the row — the file survived"
[ "$RC" = 1 ] && ok || bad "4: rc $RC after the tie removed the file"

echo "== 5. a local touch newer than the row survives =="
row 0 "$T2"; touch -d "@$NOW" "$FLAG"
client flag-active alerts-db; RC=$?
[ -f "$FLAG" ] && ok || bad "5: an older inactive row removed a newer local touch — autohalt could never pause a box"
[ "$RC" = 0 ] && ok || bad "5: rc $RC for a locally paused box"
[ "$(mt "$FLAG")" = "$NOW" ] && ok || bad "5: the local touch's mtime changed ($(mt "$FLAG") != $NOW)"

echo "== 6. the non-actions: nothing is created, removed or re-stamped =="
# Each arm runs twice: file present at @E1 (must stay, mtime byte-identical) and
# file absent (must stay absent). Every inactive-looking row here is dated T2 >
# E1 where it is dated at all, so a reconcile that read it as "inactive" WOULD
# remove the file — the arm is only green if it is a non-action.
nonaction() { # nonaction <label> <setup-fn>
  local L="$1" RC
  touch -d "@$E1" "$FLAG"; "$2"
  client flag-active alerts-db; RC=$?
  { [ -f "$FLAG" ] && [ "$(mt "$FLAG")" = "$E1" ]; } && ok \
    || bad "6 $L: present file changed (exists: $([ -f "$FLAG" ] && echo yes || echo no), mtime $(mt "$FLAG"))"
  [ "$RC" = 0 ] && ok || bad "6 $L: rc $RC with the file present"
  rm -f "$FLAG"; "$2"
  client flag-active alerts-db; RC=$?
  [ ! -e "$FLAG" ] && ok || bad "6 $L: an absent file was created"
  [ "$RC" = 1 ] && ok || bad "6 $L: rc $RC with the file absent"
  EXTRA_ENV=""
}
s_down()   { row 1 "$T2"; EXTRA_ENV="CURL_MODE=down"; }
s_500()    { row 0 "$T2"; EXTRA_ENV="CURL_MODE=500"; }
s_empty()  { row 0 "$T2"; EXTRA_ENV="CURL_MODE=empty"; }
s_noflag() { rawrow '{"flag":{}}'; }
s_noact()  { rawrow "{\"flag\":{\"name\":\"alerts-db\",\"updated_at\":\"$T2\"}}"; }
s_noupd()  { row 0 -; }
s_yday()   { row 0 yesterday; }
s_u1()     { row 0 u1; }
s_blank()  { row 0 ""; }
s_true()   { rawrow "{\"flag\":{\"name\":\"alerts-db\",\"active\":true,\"updated_at\":\"$T2\"}}"; }
s_404()    { norow; }
# The present-file arm of s_true would CREATE nothing and remove nothing only if
# "true" is refused; the absent arm pins that it is not read as active either.
for a in down 500 empty noflag noact noupd yday u1 blank true 404; do nonaction "$a" "s_$a"; done
EXTRA_ENV=""
# A row the worker ANSWERED but that is malformed is not an outage: it must not
# page "harness-jobs unreachable ... double-build guard OFF" (req.sh's daily
# ALERTS line). Only the transport arms (down/500/empty) may say that.
for a in noflag noact noupd yday u1 blank true; do
  rm -f "$F1/logs/ALERTS.log" "$F1"/flags/alerted-jobs-client-*
  "s_$a"; client flag-active alerts-db
  [ ! -s "$F1/logs/ALERTS.log" ] && ok || bad "6 $a: a malformed row paged as an outage: $(cat "$F1/logs/ALERTS.log")"
done
rm -f "$F1/logs/ALERTS.log" "$F1"/flags/alerted-jobs-client-*; EXTRA_ENV=""

echo "== 7. skew: a file one hour in the future keeps its pause against an inactive row =="
touch -d "@$((NOW+3600))" "$FLAG"; row 0 "$T2"
client flag-active alerts-db; RC=$?
[ -f "$FLAG" ] && [ "$RC" = 0 ] && ok || bad "7: a skewed-ahead box lost its own pause (rc $RC)"

echo "== 8. traversal: a flag name is a file name =="
BEFORE=$(cd "$F1/flags" && ls -A | sort | tr '\n' ' ')
client flag-set ../../etc/passwd on; RC=$?
[ "$RC" != 0 ] && ok || bad "8: a traversing name was accepted (rc 0)"
[ ! -e "$F1/etc/passwd" ] && [ ! -e "$T/etc/passwd" ] && ok || bad "8: a traversing name wrote outside flags/"
AFTER=$(cd "$F1/flags" && ls -A | sort | tr '\n' ' ')
[ "$BEFORE" = "$AFTER" ] && ok || bad "8: flags/ changed under a refused name: '$BEFORE' -> '$AFTER'"

echo "== 9. the watermark is gone =="
# The name is assembled so the tree-wide "no reference to the directory" grep
# the ticket asks for stays empty while this still checks for it.
WM="flags""-db"
[ ! -e "$F1/state/$WM" ] && ok || bad "9: state/$WM still exists after cases 1-8"
grep -q "$WM" "$F1/bin/lib/jobs/flags.sh" && bad "9: flags.sh still names state/$WM" || ok

echo "== 12. flag_set stamps the PUT response's updated_at onto the file =="
norow; rm -f "$FLAG" "$F1/req.log"
client flag-set alerts-db on "pausing for a deploy"; RC=$?
[ "$RC" = 0 ] && ok || bad "12: flag-set on rc $RC"
[ -f "$FLAG" ] && ok || bad "12: flag-set on did not create the file"
[ "$(mt "$FLAG")" = "$EPUT" ] && ok || bad "12: the file carries mtime $(mt "$FLAG"), not the PUT's $EPUT"
grep -q 'PUT .*/api/flags .*"active":1' "$F1/req.log" 2>/dev/null && ok || bad "12: no active PUT recorded"
client flag-set alerts-db off
[ ! -e "$FLAG" ] && ok || bad "12: flag-set off did not remove the file"
# The file comes FIRST: with the worker down, `on` still pauses the box and says rc 1.
EXTRA_ENV="CURL_MODE=down" client flag-set alerts-db on; RC=$?
[ -f "$FLAG" ] && [ "$RC" = 1 ] && ok || bad "12: a failed PUT must leave the file written and answer rc 1 (rc $RC)"
EXTRA_ENV=""; rm -f "$FLAG"

# ---------------------------------------------------------------------------
# 10. PRODUCTION ENTRY POINTS. Only a ROW says automerge-disabled; the box has no
# file. The REAL bin/lander.sh must stand down on it. (bin/tier2-merge-sweep.sh
# was the second entry point here; BH-1366 retired it on main.) The lander is
# copied verbatim except its two hardcoded roots, which are rewritten and the
# rewrite asserted (the same idiom as tests/lander-fixture-modules.bh-1330-test.sh).
# ---------------------------------------------------------------------------
build_h() { # build_h <case-dir> <with-client 0|1>
  local C="$1" H="$1/h"
  mkdir -p "$H/bin/lib" "$H/env" "$H/flags" "$H/logs" "$H/state" "$H/locks" "$H/rows" \
           "$H/repos/project-3" "$H/builds/project-3-X" "$C/fakebin"
  sed -e 's|^HARNESS=/root/harness$|HARNESS="${HARNESS:-/root/harness}"|' \
      -e 's|^REPO_DIR="/root/repos/\$PROJECT"$|REPO_DIR="$HARNESS/repos/$PROJECT"|' \
      "$DIR/bin/lander.sh" > "$H/bin/lander.sh"
  grep -qF 'HARNESS="${HARNESS:-/root/harness}"' "$H/bin/lander.sh" && ok \
    || bad "10: the lander scratch-root rewrite did not match — the case would drive /root/harness"
  cp "$DIR/bin/fleet-conf.sh" "$H/bin/"
  cp "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/ledger-twin.sh" "$DIR/bin/lib/deployment.sh" "$H/bin/lib/"
  if [ "$2" = 1 ]; then
    mkdir -p "$H/bin/lib/jobs"
    cp "$DIR/bin/jobs-client.sh" "$H/bin/"; cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
  fi
  printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.invalid\n' > "$H/env/global.env"
  printf 'project-3 example-org/project-3 - - 2 box-project-3\n' > "$H/fleet.conf"
  echo "PR_CREATED https://github.com/example-org/project-3/pull/1" > "$H/builds/project-3-X/RESULT"
  printf 'review\nVERDICT: APPROVE\n' > "$H/builds/project-3-X/review.md"
  cp "$T/fakebin/curl" "$C/fakebin/curl"
  printf '#!/bin/bash\nprintf "GH %%s\\n" "$*" >> "$GH_SINK"\nexit 0\n' > "$C/fakebin/gh"
  printf '#!/bin/bash\nprintf "GIT %%s\\n" "$*" >> "$GH_SINK"\nexit 1\n' > "$C/fakebin/git"
  printf '#!/bin/bash\nexit 0\n' > "$C/fakebin/flock"
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
  chmod +x "$H/bin/lander.sh" "$C/fakebin/"* "$H/bin/beat.sh"
}
run_lane() { # run_lane <case-dir> <script> [args...] -> rc; gh/git calls in <dir>/gh.txt
  local C="$1" s="$2"; shift 2
  : > "$C/gh.txt"
  env -i PATH="$C/fakebin:/usr/bin:/bin" HOME="$C" HARNESS="$C/h" FLEET_CONF="$C/h/fleet.conf" \
      JOBS_BOX=testbox JOBS_RETRIES=0 ROWS="$C/h/rows" REQ_SINK="$C/h/req.log" GH_SINK="$C/gh.txt" \
      bash "$C/h/bin/$s" "$@" >"$C/out.txt" 2>"$C/err.txt"
}
lines() { [ -f "$1" ] || { echo 0; return 0; }; grep -c . "$1" 2>/dev/null || true; }
amrow() { printf '{"flag":{"name":"automerge-disabled","active":1,"updated_at":"%s"}}' "$T1" > "$1/h/rows/automerge-disabled.json"; }

echo "== 10a. the REAL lander stands down on a row alone =="
C2="$T/c2"; build_h "$C2" 1; amrow "$C2"
run_lane "$C2" lander.sh project-3 1; RC=$?
[ "$RC" = 1 ] && ok || bad "10a: lander rc $RC on a row-only automerge-disabled"
[ "$(lines "$C2/gh.txt")" = 0 ] && ok || bad "10a: lander ran past the kill switch: $(head -3 "$C2/gh.txt")"
# TEST-CHANGE BH-4153: automerge-disabled is a ported name, so the row is no
# longer materialised as flags/automerge-disabled. The row's answer lands in the
# last-good cache instead (state/flags-cache/fleet/<name>), and that is pinned.
[ ! -e "$C2/h/flags/automerge-disabled" ] && ok || bad "10a: a ported row was materialised as flags/automerge-disabled"
jq -e '.on == true and .src == "db"' "$C2/h/state/flags-cache/fleet/automerge-disabled" >/dev/null 2>&1 && ok \
  || bad "10a: the row did not reach the cache as on: $(cat "$C2/h/state/flags-cache/fleet/automerge-disabled" 2>&1)"

echo "== 10b'. control: no row, no file — the lander gets past the gate =="
# Without this the case above could pass on a fixture that never reaches
# the gate at all.
rm -f "$C2/h/flags/automerge-disabled" "$C2/h/rows/automerge-disabled.json"
run_lane "$C2" lander.sh project-3 1
grep -q 'pr view 1' "$C2/gh.txt" && ok || bad "10b': lander never reached gh pr view with nothing set: $(cat "$C2/err.txt" | head -3)"

echo "== 10c. no client on the box: the bare file is still the kill switch =="
C3="$T/c3"; build_h "$C3" 0; amrow "$C3"
[ ! -e "$C3/h/bin/jobs-client.sh" ] && ok || bad "10c: this fixture must have no client"
touch "$C3/h/flags/automerge-disabled"
run_lane "$C3" lander.sh project-3 1; RC=$?
[ "$RC" = 1 ] && [ "$(lines "$C3/gh.txt")" = 0 ] && ok || bad "10c: lander with a bare file (rc $RC, gh: $(head -1 "$C3/gh.txt"))"
rm -f "$C3/h/flags/automerge-disabled"
run_lane "$C3" lander.sh project-3 1
grep -q 'pr view 1' "$C3/gh.txt" && ok || bad "10c: with no client and no file the lander must proceed as today"
[ ! -e "$C3/h/flags/automerge-disabled" ] && ok || bad "10c: with no client, a row must not reach the box"

echo "== 10d. the conductor's provenance auto-resolve reads both switches through the row =="
# bin/lib/mc/classify.sh is sourced (the conductor's lib), not run, so the real
# function is called with the real client loaded beside it. The re-review file
# lookups are stubbed to "running": that is the arm that answers rc 0.
F5="$T/f5"; client_h "$F5"
prov() { # prov -> rc of mc_prov_autoresolving for a fresh provenance hold
  ( export PATH="$T/fakebin:$PATH" HARNESS="$F5" HARNESS_SECRET=test-secret JOBS_RETRIES=0 \
           JOBS_URL=https://jobs.invalid ROWS="$F5/rows" MC_H="$F5"
    . "$F5/bin/jobs-client.sh"
    # shellcheck source=/dev/null
    . "$DIR/bin/lib/mc/classify.sh"
    mc_rr_file() { printf x; }; mc_rr_state() { printf running; }
    mc_prov_autoresolving o/p#1 provenance abcdef0123 10 ) >/dev/null 2>&1
}
frow() { printf '{"flag":{"name":"%s","active":%s,"updated_at":"%s"}}' "$1" "$2" "$T1" > "$F5/rows/$1.json"; }
prov; [ "$?" = 1 ] && ok || bad "10d: with no row and no file the conductor's actions are not armed"
frow merge-conductor-actions 1
prov; RC=$?
[ "$RC" = 0 ] && ok || bad "10d: a merge-conductor-actions row alone did not arm the auto-resolve (rc $RC)"
[ -f "$F5/flags/merge-conductor-actions" ] && ok || bad "10d: the row was not materialised"
frow automerge-disabled 1
prov; RC=$?
[ "$RC" = 1 ] && ok || bad "10d: an automerge-disabled row alone did not disarm the auto-resolve (rc $RC)"

echo "== 11. mutation: the reconcile returning before the file write is caught by case 2 =="
# TEST-CHANGE BH-4153: the mutant is _flag_sync_file, not flag_sync. flag_sync is
# now a dispatcher and flag_active reaches a non-ported name's reconcile through
# _flag_active_file -> _flag_sync_file, so a mutant flag_sync is never called on
# this path and the check below would pass vacuously. The name is alerts-db (see F1).
F4="$T/f4"; client_h "$F4"
sed -i '/^_flag_sync_file() {/a\  return 0' "$F4/bin/lib/jobs/flags.sh"
grep -A1 '^_flag_sync_file() {' "$F4/bin/lib/jobs/flags.sh" | grep -qx '  return 0' && ok \
  || bad "11: the mutation did not apply — the check below would be vacuous"
touch -d "@$E1" "$F4/flags/alerts-db"
printf '{"flag":{"name":"alerts-db","active":0,"updated_at":"%s"}}' "$T2" > "$F4/rows/alerts-db.json"
CH="$F4" client flag-active alerts-db
[ -f "$F4/flags/alerts-db" ] && ok || bad "11: the mutant still removed the file — case 2 cannot tell a dead reconcile from a live one"

echo "== 13. a ported name answers from its row and writes no file =="
# TEST-CHANGE BH-4153: the new case. paused-p on a configured box (the stub
# worker, JOBS_URL and HARNESS_SECRET set), active row: rc 0 and no flags/ file.
printf '{"flag":{"name":"paused-p","active":1,"updated_at":"%s"}}' "$T1" > "$F1/rows/paused-p.json"
rm -f "$F1/flags/paused-p" "$F1/req.log"
client flag-active paused-p; RC=$?
[ "$RC" = 0 ] && ok || bad "13: flag_active rc $RC for an active paused-p row"
[ ! -e "$F1/flags/paused-p" ] && ok || bad "13: a ported name wrote flags/paused-p"
grep -q 'GET [^ ]*/api/flags/paused-p ' "$F1/req.log" 2>/dev/null && ok || bad "13: the row was never read: $(cat "$F1/req.log" 2>&1)"

echo
echo "flag-authority.bh-1370-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
