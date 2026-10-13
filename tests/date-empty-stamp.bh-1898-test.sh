#!/bin/bash
# determinism: ok-file a PATH `date` shim pins the clock to 00:01Z on purpose: the defect only shows in the first hours of a UTC day
# tests/date-empty-stamp.bh-1898-test.sh — AN EMPTY STAMP IS NOT A FRESH ONE.
#
# BH-1898 (BH-1816.1). GNU `date -u -d ""` exits 0 and answers today's 00:00Z
# (#1815), so a `$(date -d "$x") || fallback` never takes the fallback when $x
# is empty. bin/account-pick.sh's _acct_epoch did exactly that: an `ok` quota
# poll with `polled_at: null` got age = seconds since midnight, and
# account_reading_class read it FRESH for the first ACCOUNT_POLL_STALE_SECS of
# every UTC day. The fix is an empty guard answering 0, the function's own
# "unparseable" value, so the age is always past the stale window.
#
# bin/lib/jobs/flags.sh's _flag_epoch shares the pattern but not the defect:
# its `case` admits only the worker's ISO shape. It gets a waiver only, and B/B2
# pin that already-safe behavior; they are not a red.
#
#   A   status ok, polled_at null, at 00:01Z  -> account_reading_class stale||
#   A2  control: polled 00:59 the day before  -> NOT stale (the shim is honest)
#   A3  _acct_epoch ""                        -> 0
#   B   flag_sync with updated_at ""          -> rc 1, flag file untouched,
#                                                one `unreadable` log line
#   B2  _flag_epoch ""                        -> rc 1, prints nothing
#   C   _acct_epoch <real ISO stamp>          -> that stamp's epoch
#   L   the determinism lint reports no date-empty-stamp on either file
#
# Run from anywhere: tests/date-empty-stamp.bh-1898-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

REAL_DATE=$(command -v date)
MIDNIGHT=$("$REAL_DATE" -u -d "" +%s)
iso() { "$REAL_DATE" -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }

# The clock the classifier reads (`date -u +%s`) is pinned to 00:01Z; every
# other date call goes to the real binary.
mkdir -p "$T/shimbin" "$T/bin/lib" "$T/state/quota" "$T/logs"
cat > "$T/shimbin/date" <<SHIM
#!/bin/bash
[ "\$#" -eq 2 ] && [ "\$1" = -u ] && [ "\$2" = +%s ] && { echo $(( MIDNIGHT + 60 )); exit 0; }
exec "$REAL_DATE" "\$@"
SHIM
chmod +x "$T/shimbin/date"
cp "$DIR/bin/account-pick.sh" "$T/bin/account-pick.sh"
PICK="$T/bin/account-pick.sh"

quota() { # <account> <polled_at json: null or a quoted ISO string>
  jq -n --arg a "$1" --argjson t "$2" \
    '{account:$a,vendor:"claude",status:"ok",source:"oauth-usage",polled_at:$t,
      five_hour:{pct:5},seven_day:{pct:5},per_model:{},extra_usage:null}' \
    > "$T/state/quota/$1.json"
}
cls() { # <account> -> the classifier's raw line, under the pinned clock
  env PATH="$T/shimbin:$PATH" HARNESS="$T" \
    bash -c '. "$1"; account_reading_class "$2" claude-fable-5-1' x "$PICK" "$1"
}
epoch() { # <stamp> -> _acct_epoch's answer
  env HARNESS="$T" bash -c '. "$1"; _acct_epoch "$2"' x "$PICK" "$1"
}

# A. a null polled_at is stale at 00:01Z, not a poll from 60s ago
quota nullacct null
C=$(cls nullacct)
[ "$C" = "stale||" ] && ok || bad "A: polled_at null at 00:01Z classed '$C', expected stale||"

# A2. the control: a real poll 120s before the pinned clock is not stale
quota freshacct "\"$(iso $(( MIDNIGHT - 60 )))\""
C=$(cls freshacct)
case "$C" in stale*|'') bad "A2: a poll 120s old classed '$C', expected a non-stale class" ;; *) ok ;; esac

# A3. the empty stamp answers the documented "unparseable" value
E=$(epoch "")
[ "$E" = 0 ] && ok || bad "A3: _acct_epoch \"\" printed '$E', expected 0"

# C. a real stamp still parses
E=$(epoch "$(iso $(( MIDNIGHT - 60 )))")
[ "$E" = "$(( MIDNIGHT - 60 ))" ] && ok || bad "C: _acct_epoch of a real stamp printed '$E', expected $(( MIDNIGHT - 60 ))"

# B / B2. flags.sh: pins the already-safe behavior through the real client
H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags"
cp "$DIR/bin/jobs-client.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR"/bin/lib/env-path.sh "$H/bin/lib/" 2>/dev/null
touch -d '2026-01-02 03:04:05Z' "$H/flags/demo"
OUT=$(env HARNESS="$H" bash -c '
  . "$1/bin/jobs-client.sh" || exit 9
  _jobs_req() { printf "%s\n" "{\"flag\":{\"active\":0,\"updated_at\":\"\"}}"; }
  flag_sync demo; echo "rc=$?"' x "$H" 2>&1)
case "$OUT" in *rc=1) ok ;; *) bad "B: flag_sync with an empty updated_at answered '$OUT', expected rc=1" ;; esac
[ -e "$H/flags/demo" ] && [ "$(stat -c %Y "$H/flags/demo")" = "$("$REAL_DATE" -u -d '2026-01-02 03:04:05Z' +%s)" ] \
  && ok || bad "B: flag_sync touched the flag file on an unreadable row"
N=$(grep -c "flag demo: updated_at '' unreadable" "$H/logs/jobs-client.log" 2>/dev/null)
[ "${N:-0}" = 1 ] && ok || bad "B: expected exactly one 'unreadable' log line, got '${N:-0}'"
OUT=$(env HARNESS="$H" bash -c '. "$1/bin/jobs-client.sh" || exit 9; _flag_epoch ""; echo "rc=$?"' x "$H" 2>&1)
[ "$OUT" = "rc=1" ] && ok || bad "B2: _flag_epoch \"\" answered '$OUT', expected rc=1 and no output"

# L. the lint agrees both date lines are handled
LINT=$(cd "$DIR" && bin/test-determinism-lint.sh bin/account-pick.sh bin/lib/jobs/flags.sh 2>&1)
case "$LINT" in *date-empty-stamp*) bad "L: the lint still reports date-empty-stamp: $(printf '%s' "$LINT" | grep date-empty-stamp)" ;; *) ok ;; esac

echo "date-empty-stamp.bh-1898: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
