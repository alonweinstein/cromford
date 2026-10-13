#!/bin/bash
# tests/flag-writethrough-test.sh — pause flags in the DB, driven for real.
#
# THE PROPERTY UNDER TEST: the FILE is still the flag. Phase 3 lets the operator pause a
# project from the console instead of ssh-ing to a box, but every existing reader
# still tests flags/<name>, and a worker outage must leave a box behaving exactly
# as it does today — never un-pausing a board because a fetch failed, and never
# inventing a pause because one did.
#
# Driven, not grepped: it runs bin/jobs-client.sh's helpers and the REAL
# bin/run-triage.sh against a stubbed worker, and reads back the files and the
# request bodies. A grep would pass on a version that reads the DB and forgets
# to write the file.
#
# TEST-CHANGE BH-4153: "the FILE is still the flag" now holds only for names
# outside the ported families (FLAG_PORTED_RE in bin/lib/jobs/flags.sh). Cases
# 1-8 keep every file assertion on alerts-db, which is not ported. paused-* IS
# ported: on a configured box (JOBS_URL + HARNESS_SECRET, as here) its row is
# the truth and no flags/ file is written; cases 11-14 and 10 pin that.
# Run from anywhere: tests/flag-writethrough-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/logs" "$T/locks" "$T/state" "$T/flags" "$T/bin" "$T/env" "$T/prompts" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/run-triage.sh"  "$T/bin/run-triage.sh"
mkdir -p "$T/bin/lib/rt" && cp "$DIR"/bin/lib/rt/*.sh "$T/bin/lib/rt/"
echo "HARNESS_SECRET=test-secret" > "$T/env/global.env"
echo "# test prompt" > "$T/prompts/testproj.md"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The stub answers GET /api/flags/<name> from $FLAG_JSON (or 404 when it is
# unset/empty) and records every request so PUT bodies can be read back.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in down) exit 7 ;; esac
case "$METHOD $URL" in
  # TEST-CHANGE BH-4153: the PUT answers the name and active it was sent (the
  # client's ported read-back requires .flag.name == the name written; the old
  # fixed "x" only ever served the file path, which ignores the name), and a
  # DELETE arm answers the cleared row the way the worker now does.
  "PUT "*/api/flags)
    n=$(printf '%s' "$BODY" | jq -r '.name // "x"'); a=$(printf '%s' "$BODY" | jq -r '.active // 1')
    printf '{"flag":{"name":"%s","active":%s,"updated_at":"2026-08-27T12:00:00Z"}}\n200\n' "$n" "$a" ;;
  "DELETE "*/api/flags\?*)
    n=${URL#*name=}; n=${n%%&*}
    printf '{"flag":{"name":"%s","active":0,"updated_at":"2026-08-27T12:00:00Z"}}\n200\n' "$n" ;;
  "GET "*/api/flags/*)
    if [ -s "${FLAG_JSON:-/nonexistent}" ]; then cat "$FLAG_JSON"; printf '\n200\n'
    else printf '{"error":"not found"}\n404\n'; fi ;;
  *) printf '{}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

# TEST-CHANGE BH-4153: row takes the name (default alerts-db, the non-ported
# name cases 1-8 now drive); FLAG is alerts-db's file, PFLAG paused-testproj's.
row() { # row <active> <updated_at> [name]
  printf '{"flag":{"name":"%s","active":%s,"updated_at":"%s"}}' "${3:-alerts-db}" "$1" "$2" > "$T/flag.json"
}
client() { # client <verb> [args...]
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid FLAG_JSON="$T/flag.json" REQ_SINK="$T/req.log" ${EXTRA_ENV:-}
    bash "$T/bin/jobs-client.sh" "$@" >/dev/null 2>&1 )
}
FLAG="$T/flags/alerts-db"
PFLAG="$T/flags/paused-testproj"

# --- 1. the console pauses: a row lands as a file on the box -----------------
row 1 "2026-08-27T10:00:00Z"; rm -f "$FLAG"
client flag-active alerts-db; RC=$?
[ -f "$FLAG" ] && ok || bad "an active row did not create the flag file"
[ "$RC" = 0 ] && ok || bad "flag_active returned $RC for an active flag"

# --- 2. the console resumes: a NEWER inactive row removes it -----------------
row 0 "2026-08-27T11:00:00Z"
client flag-active alerts-db; RC=$?
[ ! -f "$FLAG" ] && ok || bad "a newer inactive row did not clear the flag file"
[ "$RC" = 1 ] && ok || bad "flag_active returned $RC for a cleared flag"

# --- 3. a local touch newer than the row survives ---------------------------
# pipeline-health's autohalt and an operator's `touch` both write this file. The
# touch (mtime now) is newer than the row's updated_at, so the row must not undo
# it — last-writer-wins on mtime (BH-1370).
touch "$FLAG"
client flag-active alerts-db
[ -f "$FLAG" ] && ok || bad "an already-applied row re-cleared a locally set flag — the box can never pause itself"

# --- 4. worker down + file present = still paused, file untouched ------------
EXTRA_ENV="CURL_MODE=down" client flag-active alerts-db; RC=$?
[ -f "$FLAG" ] && [ "$RC" = 0 ] \
  && ok || bad "an outage changed a paused box (file exists: $([ -f "$FLAG" ] && echo yes || echo no), rc=$RC)"

# --- 5. worker down + no file = not paused (a pause is never invented) -------
rm -f "$FLAG"
EXTRA_ENV="CURL_MODE=down" client flag-active alerts-db; RC=$?
[ "$RC" = 1 ] && [ ! -f "$FLAG" ] && ok || bad "an outage invented a pause (rc=$RC)"

# --- 6. no row at all (404) is a real answer: leave the box alone ------------
rm -f "$T/flag.json"; touch "$FLAG"
client flag-active alerts-db; RC=$?
[ -f "$FLAG" ] && [ "$RC" = 0 ] && ok || bad "a 404 (no row) cleared a local flag"

# --- 7. flag_set writes the FILE first, then the row ------------------------
rm -f "$FLAG" "$T/req.log"
client flag-set alerts-db on "pausing for a deploy"
[ -f "$FLAG" ] && ok || bad "flag_set on did not create the file"
grep -q 'PUT .*/api/flags .*"active":1' "$T/req.log" \
  && ok || bad "flag_set on did not write the row: $(cat "$T/req.log" | head -2)"
rm -f "$T/req.log"
client flag-set alerts-db off
[ ! -f "$FLAG" ] && ok || bad "flag_set off did not remove the file"
grep -q 'PUT .*/api/flags .*"active":0' "$T/req.log" \
  && ok || bad "flag_set off did not write the row"

# --- 8. ...and the file still wins when the row write fails ------------------
rm -f "$FLAG"
EXTRA_ENV="CURL_MODE=down" client flag-set alerts-db on
[ -f "$FLAG" ] \
  && ok || bad "a failed DB write lost the pause — the file must be written first, so the box is right either way"

# --- 9. a flag name is a file name: nothing may escape flags/ ---------------
client flag-set ../../etc/passwd on; RC=$?
[ "$RC" != 0 ] && [ ! -e "$T/etc/passwd" ] && ok || bad "a traversing flag name was accepted"

# --- 10. THE END-TO-END CASE: the real run-triage.sh honours a console pause -
# No file on the box, the row says paused, and the tick must stop before doing
# anything — which is the whole point of pausing from the console.
# TEST-CHANGE BH-4153: run-triage reads paused-testproj through flag_active,
# which for a ported name answers from the row. The tick must stop on the row
# alone and leave NO flags/ file behind (it used to back-fill one).
rm -f "$PFLAG" "$T/logs/testproj.log" "$T/state/flags-cache/fleet/paused-testproj"
row 1 "2026-08-27T13:00:00Z" paused-testproj
( export PATH="$T/fakebin:$PATH" HARNESS="$T" JOBS_URL=https://jobs.invalid \
         FLAG_JSON="$T/flag.json" REQ_SINK="$T/req.log"
  bash "$T/bin/run-triage.sh" testproj >/dev/null 2>&1 ); RC=$?
[ "$RC" = 0 ] && ok || bad "run-triage exited $RC on a paused board"
grep -q "paused via console, skipping" "$T/logs/testproj.log" 2>/dev/null \
  && ok || bad "run-triage did not stop on a pause set only in the DB: $(cat "$T/logs/testproj.log" 2>/dev/null | head -2)"
[ ! -e "$PFLAG" ] && ok || bad "run-triage wrote flags/paused-testproj for a ported name"

# --- 11-14. TEST-CHANGE BH-4153: the ported name, row first, no file ---------
rm -f "$PFLAG" "$T/req.log" "$T/state/flags-cache/fleet/paused-testproj"
row 1 "2026-08-27T10:00:00Z" paused-testproj
client flag-active paused-testproj; RC=$?
[ "$RC" = 0 ] && ok || bad "11: flag_active rc $RC for an active paused-testproj row"
[ ! -e "$PFLAG" ] && ok || bad "11: an active ported row created flags/paused-testproj"
row 0 "2026-08-27T11:00:00Z" paused-testproj
client flag-active paused-testproj; RC=$?
[ "$RC" = 1 ] && ok || bad "11: flag_active rc $RC for a cleared paused-testproj row"
[ ! -e "$PFLAG" ] && ok || bad "11: a cleared ported row created flags/paused-testproj"

# 12. the worker goes down: the last good answer (cleared) stands, no file.
EXTRA_ENV="CURL_MODE=down" client flag-active paused-testproj; RC=$?
[ "$RC" = 1 ] && [ ! -e "$PFLAG" ] && ok || bad "12: an outage changed a cached answer (rc=$RC)"

# 13. flag_set on/off writes the ROW and no file.
rm -f "$T/req.log"
client flag-set paused-testproj on "pausing for a deploy"; RC=$?
[ "$RC" = 0 ] && ok || bad "13: flag_set on rc $RC with the worker up"
grep -q 'PUT .*/api/flags .*"name":"paused-testproj".*"active":1' "$T/req.log" \
  && ok || bad "13: flag_set on did not write the row: $(head -2 "$T/req.log")"
[ ! -e "$PFLAG" ] && ok || bad "13: flag_set on wrote flags/paused-testproj"
rm -f "$T/req.log"
client flag-set paused-testproj off; RC=$?
[ "$RC" = 0 ] && ok || bad "13: flag_set off rc $RC with the worker up"
grep -q 'DELETE .*/api/flags?name=paused-testproj' "$T/req.log" \
  && ok || bad "13: flag_set off did not clear the row: $(head -2 "$T/req.log")"
[ ! -e "$PFLAG" ] && ok || bad "13: flag_set off left flags/paused-testproj"

# 14. a failed write is rc 1 and leaves nothing: no file, no local hold.
EXTRA_ENV="CURL_MODE=down" client flag-set paused-testproj on; RC=$?
[ "$RC" = 1 ] && ok || bad "14: a failed ported write answered rc $RC"
[ ! -e "$PFLAG" ] && ok || bad "14: a failed ported write left flags/paused-testproj"
jq -e '.src == "local"' "$T/state/flags-cache/fleet/paused-testproj" >/dev/null 2>&1 \
  && bad "14: a failed write without --hold-local left a local hold" || ok

echo "flag-writethrough-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
