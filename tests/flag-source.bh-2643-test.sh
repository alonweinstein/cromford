#!/bin/bash
# tests/flag-source.bh-2643-test.sh — BH-2643: `jobs-client.sh flag-active`
# answers from the flags/ file, a builder's claim answers from the pause_flags
# row, and until now nothing said which one an operator was reading. On
# 2026-09-26 the hub's `flag-set … off` removed its file, failed to write the
# row, and `flag-active` then read rc=1 from the file while every builder kept
# getting REFUSED pause from the row. The CLI now names its source on stderr;
# stdout and rc are unchanged (tests/flag-authority.bh-1370-test.sh pins those).
#
# Driven, not grepped: the real bin/jobs-client.sh against the BH-1370 stubbed
# worker. One clock read (NOW, below).
#
# TEST-CHANGE BH-4153: paused-p is a ported name now (FLAG_PORTED_RE in
# bin/lib/jobs/flags.sh), answered from its harness_flags row, the last-good
# cache or a local hold, and named by _flag_cli_source_row. Cases a-d2 keep
# every old line on alerts-db, which is not ported. Cases p1-p6 pin the new
# lines for paused-p.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

NOW=$(date -u +%s)
T1=2026-09-19T01:00:00Z; E1=1789779600
T2=2026-09-19T02:00:00Z

mkdir -p "$T/fakebin"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; METHOD=GET; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
case "${CURL_MODE:-ok}" in down) exit 7 ;; esac
case "$METHOD $URL" in
  # TEST-CHANGE BH-4153: the PUT answers (and stores, under $ROWS) the name and
  # active it was sent. The ported read-back requires .flag.name == the name
  # written, and case p6's lazy import re-reads the row it just PUT. The old
  # fixed {"name":"x","active":0} only served the file path, which reads
  # neither; a PUT with no active in its body still answers active 0.
  "PUT "*/api/flags)
    n=$(printf '%s' "$BODY" | jq -r '.name // "x"'); a=$(printf '%s' "$BODY" | jq -r '.active // 0')
    r=$(printf '{"flag":{"name":"%s","active":%s,"updated_at":"2026-09-19T03:00:00Z"}}' "$n" "$a")
    case "$n" in *[!A-Za-z0-9._-]*) ;; *) [ -d "${ROWS:-/nonexistent}" ] && printf '%s' "$r" > "$ROWS/$n.json" ;; esac
    printf '%s\n200\n' "$r" ;;
  "GET "*/api/flags/*)
    n="${URL##*/}"
    if [ -s "${ROWS:-/nonexistent}/$n.json" ]; then cat "$ROWS/$n.json"; printf '\n200\n'
    else printf '{"error":"not found"}\n404\n'; fi ;;
  *) printf '{}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/flags" "$H/state" "$H/logs" "$H/env" "$H/rows"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || { echo "closure install failed for bin/jobs-client.sh"; exit 1; }
echo "HARNESS_SECRET=test-secret" > "$H/env/global.env"
# TEST-CHANGE BH-4153: the import publishes only a flag this box owns, so the
# fixture carries a registry that puts p on this box (boxa), as p6 assumes.
for s in bin/fleet-conf.sh bin/box-for.sh; do scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install failed for $s"; exit 1; }; done
printf 'p org/p https://p.example /api/board 2 boxa\n' > "$H/fleet.conf"
# TEST-CHANGE BH-4153: FLAG is alerts-db's file (cases a-d2); row takes the
# name, default alerts-db. PFLAG is the ported paused-p (cases p1-p6).
FLAG="$H/flags/alerts-db"
PFLAG="$H/flags/paused-p"; PCACHE="$H/state/flags-cache/fleet/paused-p"
row() { printf '{"flag":{"name":"%s","active":%s,"updated_at":"%s"}}' "${3:-alerts-db}" "$1" "$2" > "$H/rows/${3:-alerts-db}.json"; }
client() { # client <verb> [args...] -> stdout to $T/out, stderr to $T/err, rc returned
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_RETRIES=0 \
           JOBS_URL=https://jobs.invalid ROWS="$H/rows" JOBS_BOX=boxa FLEET_CONF="$H/fleet.conf" ${EXTRA_ENV:-}
    bash "$H/bin/jobs-client.sh" "$@" >"$T/out" 2>"$T/err" )
}

echo "== a. row off, a local file NEWER than the row: the file answers, and says so =="
row 0 "$T1"; touch -d "@$NOW" "$FLAG"
client flag-active alerts-db; RC=$?
[ "$RC" = 0 ] && ok || bad "a: rc $RC (flag_active's answer is the file, rc 0)"
grep -q 'source: flags/alerts-db file, newer than the row (active=0' "$T/err" && ok || bad "a: source not named: $(cat "$T/err")"
grep -q 'NOT paused' "$T/err" && ok || bad "a: does not say builders are not paused: $(cat "$T/err")"
[ -s "$T/out" ] && bad "a: stdout changed: $(cat "$T/out")" || ok

echo "== b. row off @T2, stale file @T1: reconciled away, the row answers =="
row 0 "$T2"; touch -d "@$E1" "$FLAG"
client flag-active alerts-db; RC=$?
[ "$RC" = 1 ] && ok || bad "b: rc $RC"
[ -e "$FLAG" ] && bad "b: stale file survived" || ok
grep -q "source: pause_flags row (active=0, updated_at $T2)" "$T/err" && ok || bad "b: row not named: $(cat "$T/err")"

echo "== c. worker unreachable, no file: the file alone answered =="
rm -f "$FLAG"
EXTRA_ENV="CURL_MODE=down" client flag-active alerts-db; RC=$?
[ "$RC" = 1 ] && ok || bad "c: rc $RC"
grep -q 'source: flags/alerts-db file ONLY: the pause_flags row could not be read (rc 1)' "$T/err" && ok || bad "c: outage not named: $(cat "$T/err")"

echo "== c2. no row at all: said as such =="
rm -f "$H/rows/alerts-db.json"
client flag-active alerts-db; RC=$?
[ "$RC" = 1 ] && ok || bad "c2: rc $RC"
grep -q 'there is no pause_flags row (rc 2)' "$T/err" && ok || bad "c2: no-row not named: $(cat "$T/err")"

echo "== d. flag-set off with the PUT failing: the row was NOT written, said loudly =="
row 1 "$T1"; touch "$FLAG"
EXTRA_ENV="CURL_MODE=down" client flag-set alerts-db off; RC=$?
[ "$RC" != 0 ] && ok || bad "d: rc $RC"
[ -e "$FLAG" ] && bad "d: the file was not removed (flag_set's order changed)" || ok
grep -q 'pause_flags row was NOT written; builders still see the old row' "$T/err" && ok || bad "d: failed write silent: $(cat "$T/err")"

echo "== d2. flag-set that succeeds says nothing; a bad state is not 'file changed' =="
client flag-set alerts-db off; RC=$?
[ "$RC" = 0 ] && ok || bad "d2: rc $RC"
[ -s "$T/err" ] && bad "d2: a successful set printed: $(cat "$T/err")" || ok
client flag-set alerts-db maybe; RC=$?
[ "$RC" != 0 ] && ok || bad "d2: a bad state answered 0"
grep -q 'NOT written' "$T/err" && bad "d2: claimed a file change for a refused state" || ok

echo "== p1. TEST-CHANGE BH-4153: ported, row active: the harness_flags row answers, no file =="
rm -f "$PFLAG" "$PCACHE"; row 1 "$T1" paused-p
client flag-active paused-p; RC=$?
[ "$RC" = 0 ] && ok || bad "p1: rc $RC"
grep -qF "source: harness_flags row (scope fleet, set_at $T1, cleared_at -)" "$T/err" && ok || bad "p1: row not named: $(cat "$T/err")"
[ -e "$PFLAG" ] && bad "p1: a ported row wrote flags/paused-p" || ok
[ -s "$T/out" ] && bad "p1: stdout changed: $(cat "$T/out")" || ok

echo "== p2. TEST-CHANGE BH-4153: ported, row cleared @T2: the row answers off =="
row 0 "$T2" paused-p
client flag-active paused-p; RC=$?
[ "$RC" = 1 ] && ok || bad "p2: rc $RC"
grep -qF "source: harness_flags row (scope fleet, set_at $T2, cleared_at $T2)" "$T/err" && ok || bad "p2: row not named: $(cat "$T/err")"

echo "== p3. TEST-CHANGE BH-4153: ported, worker unreachable: the cache answers, and says so =="
EXTRA_ENV="CURL_MODE=down" client flag-active paused-p; RC=$?
[ "$RC" = 1 ] && ok || bad "p3: rc $RC (the cached answer is off)"
grep -q 'source: cache (age [0-9]*s): the worker did not answer; this is the last good row' "$T/err" && ok || bad "p3: cache not named: $(cat "$T/err")"

echo "== p4. TEST-CHANGE BH-4153: ported, unreachable, no cache, no file: unknown, read as ON =="
rm -f "$PCACHE" "$PFLAG"
EXTRA_ENV="CURL_MODE=down" client flag-active paused-p; RC=$?
[ "$RC" = 0 ] && ok || bad "p4: rc $RC (a stop switch must fail closed)"
grep -qF 'source: unknown → read as ON' "$T/err" && ok || bad "p4: unknown not named: $(cat "$T/err")"
[ -e "$PFLAG" ] && bad "p4: an unknown answer wrote flags/paused-p" || ok

echo "== p5. TEST-CHANGE BH-4153: ported, legacy file, worker unreachable: a local hold =="
# The lazy import cannot reach the worker (rc 75), so the file is kept and
# seeds a src:local entry stamped with its mtime.
rm -f "$PCACHE"; touch -d "@$NOW" "$PFLAG"
EXTRA_ENV="CURL_MODE=down" client flag-active paused-p; RC=$?
[ "$RC" = 0 ] && ok || bad "p5: rc $RC"
grep -qF 'source: local hold' "$T/err" && ok || bad "p5: local hold not named: $(cat "$T/err")"
[ -e "$PFLAG" ] && ok || bad "p5: an import that could not run removed the legacy file"
jq -e --argjson st "$NOW" '.src == "local" and .on == true and .stamp == $st' "$PCACHE" >/dev/null 2>&1 && ok \
  || bad "p5: the hold is not the file's mtime: $(cat "$PCACHE" 2>&1)"

echo "== p6. TEST-CHANGE BH-4153: ported, legacy file NEWER than a cleared row, worker up: imported =="
# The stub answers the GET with the cleared row @T2 (older than the file), takes
# the import's PUT and stores it; the fetch then reads the imported row back.
rm -f "$PCACHE"; row 0 "$T2" paused-p; touch -d "@$NOW" "$PFLAG"
client flag-active paused-p; RC=$?
[ "$RC" = 0 ] && ok || bad "p6: rc $RC (the newer file is a pause, imported)"
[ -e "$PFLAG" ] && bad "p6: the imported file was not removed" || ok
grep -qF "source: harness_flags row (scope fleet, set_at 2026-09-19T03:00:00Z, cleared_at -)" "$T/err" && ok || bad "p6: imported row not named: $(cat "$T/err")"

echo "flag-source: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
