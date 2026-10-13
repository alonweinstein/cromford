#!/bin/bash
# tests/wake-cursor-writethrough.bh-1034-test.sh — the wake watermark is this
# box's wake_cursors ROW, written through PUT /api/wakes/cursor after every
# drain, and a box with no row seeds itself from the hub's row (BH-1034.4,
# audit #15; re-pointed by BH-2637).
#
# TEST-CHANGE BH-2637: this file used to pin state/wake-cursor (the local
# TEST-CHANGE BH-2637: watermark file) plus its `wake-cursor.<box>` settings
# TEST-CHANGE BH-2637: mirror and the seed from that mirror. BH-2637 deleted all
# TEST-CHANGE BH-2637: three: the watermark is the worker's wake_cursors row and
# TEST-CHANGE BH-2637: the claim rows (not the cursor) are the dedupe guard. Every
# TEST-CHANGE BH-2637: case below is the same property on the replacement, and
# TEST-CHANGE BH-2637: each also asserts the ABSENCE of the file and the mirror key.
#
# WHAT IS AND IS NOT THE GUARD. The claim rows stop a redelivered wake from
# re-launching a paid lane; the cursor only bounds how far each claim scans. So
# the cursor PUT lands before the ack, a failed PUT degrades to a log line and
# still acks, and a box that cannot READ its cursor claims nothing that cycle
# (an unreadable cursor is never read as "no cursor"). A box restored with no
# row adopts the hub's watermark once, before its first claim, instead of
# scanning the whole table from 0.
#
# So the assertions are about ORDER and about degradation:
#   * one cursor PUT per drain that moved, carrying scanned_top, before the ack;
#   * a 500 on the PUT still acks and says "cursor put failed";
#   * no request ever names a `wake-cursor.` settings key; no state/wake-cursor;
#   * no own row -> seed from the hub's row (PUT before the first claim);
#     an own row wins over the hub's; a GET 500 means no claim that cycle.
#
# Drives the REAL bin/wake-loop.sh and the REAL jobs-client against the stub
# worker in tests/lib/wake-claim-stub.sh. The box is box-project-3-1 and owns
# project-3; the hub is box-hub.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/wake-cursor-writethrough.bh-1034-test.sh  (0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/wake-claim-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

H="$T/h"
export HARNESS="$H" WAKE_LOOP_CYCLES=1 WAKE_LOOP_INTERVAL_S=0 JOBS_RETRIES=0
export WCS_WAKES="$T/wakes.json" BOX_NAME=box-project-3-1
unset WAKE_CLAIM_LIMIT HUB_BOX_NAME CLAIM_ALL COOL_MODE CLAIM_MODE CURSOR_PUT_MODE CURSOR_GET_MODE JOBS_BOX
LANES="merge-conductor deploy-train postmerge-qa run-triage review-prs rebase-train apply-migrations"

# reset — a new harness tree and a new stub worker. The REAL client and the
# REAL loop: the cursor calls live in one and the seed in the other, and
# stubbing either would test the stub.
reset() {
  scratch_rm "$H"
  mkdir -p "$H/bin/lib/jobs" "$H/env" "$H/logs" "$H/locks" "$H/state/wcs" "$H/flags" "$H/calls"
  printf 'HARNESS_SECRET=s\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
  cp "$DIR/bin/wake-loop.sh" "$DIR/bin/jobs-client.sh" "$H/bin/"
  cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
  cp "$DIR/bin/lib/wake-lanes.sh" "$DIR"/bin/lib/wake-class-*.sh "$H/bin/lib/"
  wcs_install "$H/bin"
  wcs_identity "$H/bin" || { echo "wcs_identity failed"; exit 1; }
  # curl: the stub worker's wake routes, and EVERY other request recorded, so
  # "no request names a wake-cursor. settings key" is checked on the wire.
  cat > "$H/bin/curl" <<'SH'
#!/bin/bash
"$(dirname "$0")/wcs-routes" "$@" && exit 0
echo "$*" >> "$HARNESS/calls/other-requests"
printf '{}\n200'
SH
  cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
[ "$1" = "--projects" ] && { printf 'project-3\n'; exit 0; }
case "$1/$2" in
  project-3/repo) echo example-org/project-3 ;;
  project-3/box)  echo box-project-3-1 ;;
  project-3/board_prefix) echo /api/feature-board ;;
  *) exit 1 ;;
esac
SH
  for s in $LANES; do
    printf '#!/bin/bash\necho "$*" >> "$HARNESS/calls/%s"\n' "$s" > "$H/bin/$s.sh"
  done
  printf '#!/bin/bash\nexit 1\n' > "$H/bin/unblocked-children.sh"
  printf '#!/bin/bash\necho "[]"\n' > "$H/bin/gh"
  printf '#!/bin/bash\nexec "$@"\n' > "$H/bin/setsid"
  chmod +x "$H/bin/"*.sh "$H/bin/curl" "$H/bin/gh" "$H/bin/setsid"
  for c in push deploy; do touch "$H/flags/wake-lanes-$c"; done
  wakes
}
export PATH="$H/bin:$PATH"

wakes() { printf '{"wakes":[%s]}' "$(printf '%s,' "$@" | sed 's/,$//')" > "$T/wakes.json"; }
W() { # W <id> <kind> <key>
  printf '{"id":%s,"repo":"example-org/project-3","kind":"%s","key":"%s","event":"ev","at":"2026-09-12T11:39:04Z"}' \
    "$1" "$2" "$3"
}
# Quiesce rather than sleep a fixed amount: the loop launches lanes detached, so
# the recorders finish after it exits and a fixed sleep is a race with the box.
settle() {
  local prev="" cur i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    sleep 0.25
    cur=$(cat "$H/calls/"* 2>/dev/null | wc -c | tr -d " ")
    [ "$cur" = "$prev" ] && [ "$i" -ge 2 ] && return 0
    prev="$cur"
  done
  return 0
}
run() { "$H/bin/wake-loop.sh"; RC=$?; settle; return "$RC"; }
REQ() { wcs_log; }
LOG() { cat "$H/logs/wake-loop.log" 2>/dev/null; }
line_of() { REQ | grep -n -m1 -F -- "$1" | cut -d: -f1; }
row() { cat "$H/state/wcs/cursor.$1" 2>/dev/null; }
puts() { REQ | grep -c '^PUT /api/wakes/cursor'; }
calls() { if [ -f "$H/calls/$1" ]; then wc -l < "$H/calls/$1" | tr -d " "; else echo 0; fi; }
# no_legacy — the two things BH-2637 deleted, checked after every run.
no_legacy() {
  [ ! -e "$H/state/wake-cursor" ] || { echo "state/wake-cursor exists: $(cat "$H/state/wake-cursor")"; return 1; }
  ! { REQ; cat "$H/calls/other-requests" 2>/dev/null; } | grep -q 'wake-cursor\.' \
    || { echo "a wake-cursor. settings key was requested: $(grep 'wake-cursor\.' "$H/calls/other-requests" 2>/dev/null)"; return 1; }
}

# ---------------------------------------------------------------------------
# 1. a non-empty drain PUTs the cursor row — once, with scanned_top, before the ack
# ---------------------------------------------------------------------------
# TEST-CHANGE BH-2637: was "the cursor file holds 24" + "one settings PUT keyed
# wake-cursor.testbox with value 24"; now the one cursor-row PUT carries
# scanned_top for this box and lands before the ack, and no file/mirror exists.
reset; echo 5 > "$H/state/wcs/cursor.box-project-3-1"; wakes "$(W 20 push s1)" "$(W 24 deploy d1)"
run
[ "$(row box-project-3-1)" = 24 ] && ok || bad "the cursor row must hold scanned_top 24 (got $(row box-project-3-1))"
[ "$(puts)" = 1 ] && ok || bad "expected exactly 1 cursor PUT per drain, got $(puts): $(REQ)"
REQ | grep -qxF 'PUT /api/wakes/cursor {"box":"box-project-3-1","cursor":24}' && ok \
  || bad "the cursor PUT is not this box's row at scanned_top: $(REQ | grep cursor)"
P=$(line_of 'PUT /api/wakes/cursor'); A=$(line_of 'POST /api/wakes/ack')
[ -n "$P" ] && [ -n "$A" ] && [ "$P" -lt "$A" ] && ok \
  || bad "the cursor PUT must land before the ack (put=$P ack=$A): $(REQ)"
[ -n "$A" ] && ok || bad "the ack must still be sent after the cursor PUT"
MSG=$(no_legacy) && ok || bad "1: $MSG"

# ---------------------------------------------------------------------------
# 2. no own row, a numeric HUB row: the box seeds itself before its first claim
# ---------------------------------------------------------------------------
# This is the whole point. Without it a restored (or brand-new) box scans the
# whole table from 0 and launches every lane in it.
# TEST-CHANGE BH-2637: was "seeded from the settings mirror, first poll since=42";
# now the seed source is the hub's wake_cursors row and the seed is a PUT of this
# box's row that precedes the first claim.
reset; echo 41 > "$H/state/wcs/cursor.box-hub"
wakes "$(W 30 deploy old)" "$(W 50 push new)"
run
[ "$(row box-project-3-1)" = 50 ] && ok || bad "the seeded row did not then advance to 50 (got $(row box-project-3-1))"
P=$(line_of 'PUT /api/wakes/cursor {"box":"box-project-3-1","cursor":41}'); C=$(line_of 'POST /api/wakes/claim')
[ -n "$P" ] && [ -n "$C" ] && [ "$P" -lt "$C" ] && ok \
  || bad "the seed PUT (41) must precede the first claim (put=$P claim=$C): $(REQ)"
grep -q "cursor seeded from the hub's: 41" "$H/logs/wake-loop.log" && ok \
  || bad "a seed that is not logged is a seed nobody can explain: $(LOG)"
[ "$(calls postmerge-qa)" = 0 ] && [ "$(calls deploy-train)" = 1 ] && ok \
  || bad "row 30 sits below the adopted cursor and must not launch; row 50 must (postmerge-qa=$(calls postmerge-qa) deploy-train=$(calls deploy-train))"
MSG=$(no_legacy) && ok || bad "2: $MSG"

# ---------------------------------------------------------------------------
# 3. no own row, NO hub row: claim from 0, and nothing is seeded
# ---------------------------------------------------------------------------
# TEST-CHANGE BH-2637: was "a settings miss leaves the since=0 poll byte-identical";
# now: both GETs answer null, the claim goes out with no seed PUT ahead of it.
reset
run
C=$(line_of 'POST /api/wakes/claim')
[ -n "$C" ] && [ "$(REQ | head -n "$C" | grep -c '^PUT /api/wakes/cursor')" = 0 ] && ok \
  || bad "nothing to seed from, but a cursor PUT preceded the claim: $(REQ)"
[ -z "$(row box-project-3-1)" ] && ok || bad "nothing to seed from, but a cursor row appeared: $(row box-project-3-1)"
grep -q 'cursor seeded' "$H/logs/wake-loop.log" 2>/dev/null && bad "logged a seed that never happened" || ok
grep -q 'no cursor row for box-project-3-1 or the hub — claiming from 0' "$H/logs/wake-loop.log" && ok \
  || bad "claiming from 0 must be said once: $(LOG)"

# ---------------------------------------------------------------------------
# 4. an OWN row wins over the hub's — no seed PUT, the claim scans from it
# ---------------------------------------------------------------------------
# TEST-CHANGE BH-2637: was "a corrupt cursor FILE is seeded over"; there is no
# file. The replacement property is precedence: a readable own row is never
# overwritten by the hub's, even when the hub's is higher.
reset; echo 10 > "$H/state/wcs/cursor.box-project-3-1"; echo 41 > "$H/state/wcs/cursor.box-hub"
wakes "$(W 30 deploy mid)"
run
! grep -qF '"cursor":41' <<<"$(REQ)" && ok || bad "an own row was seeded over with the hub's: $(REQ | grep cursor)"
[ "$(calls postmerge-qa)" = 1 ] && ok \
  || bad "row 30 is above the own row (10) and must launch: postmerge-qa=$(calls postmerge-qa) $(LOG)"
! grep -q 'cursor?box=box-hub' <<<"$(REQ)" && ok || bad "the hub's row was read although this box has its own: $(REQ)"
grep -q 'cursor seeded' "$H/logs/wake-loop.log" 2>/dev/null && bad "logged a seed over an own row" || ok

# ---------------------------------------------------------------------------
# 5. a 500 on the cursor PUT changes nothing else: same launches, same ack
# ---------------------------------------------------------------------------
# TEST-CHANGE BH-2637: was "a settings outage changes nothing"; the only write
# left to fail is the cursor PUT, which degrades to one log line and still acks.
reset; echo 7 > "$H/state/wcs/cursor.box-project-3-1"; echo 500 > "$H/state/wcs/CURSOR_PUT_MODE"
wakes "$(W 20 push s1)" "$(W 24 deploy d1)"
run
REQ | grep -q '^POST /api/wakes/ack' && ok || bad "a failed cursor PUT swallowed the ack: $(REQ)"
[ "$(LOG | grep -c 'cursor put failed at 24')" = 1 ] && ok \
  || bad "a failed cursor PUT must say so once: $(LOG)"
[ "$(calls deploy-train)" = 1 ] && [ "$(calls postmerge-qa)" = 1 ] && ok \
  || bad "a failed cursor PUT changed the launches (deploy-train=$(calls deploy-train) postmerge-qa=$(calls postmerge-qa))"
[ "$(row box-project-3-1)" = 7 ] && ok || bad "a 500 PUT still moved the row (got $(row box-project-3-1))"
MSG=$(no_legacy) && ok || bad "5: $MSG"

# ---------------------------------------------------------------------------
# 6. an unreadable cursor is refused, never read as "no cursor"
# ---------------------------------------------------------------------------
# TEST-CHANGE BH-2637: was "a non-numeric settings value is refused"; the
# refusal now covers the GET: a 500 on this box's cursor means no claim that
# cycle, and a junk hub row is never written into this box's row.
reset; echo 500 > "$H/state/wcs/CURSOR_GET_MODE"; wakes "$(W 20 push s1)"
run
! grep -q '/api/wakes/claim' <<<"$(REQ)" && ok || bad "a cursor GET 500 still claimed: $(REQ)"
[ "$(puts)" = 0 ] && [ "$(calls deploy-train)" = 0 ] && ! grep -q '/api/wakes/ack' <<<"$(REQ)" && ok \
  || bad "a cursor GET 500 must PUT, launch and ack nothing: $(REQ)"
grep -q 'cursor row unreadable — nothing claimed' "$H/logs/wake-loop.log" && ok \
  || bad "an unreadable cursor must be said: $(LOG)"
reset; printf 'abc' > "$H/state/wcs/cursor.box-hub"; wakes "$(W 20 push s1)"
run
[ "$(puts)" = 0 ] && ! grep -q '/api/wakes/claim' <<<"$(REQ)" && ok \
  || bad "a junk hub row reached a PUT or a claim: $(REQ)"
[ -z "$(row box-project-3-1)" ] && ok || bad "a junk hub row was written into this box's row: $(row box-project-3-1)"

# ---------------------------------------------------------------------------
# 7. an EMPTY drain writes nothing — the PUT follows the scan, not the tick
# ---------------------------------------------------------------------------
reset; echo 5 > "$H/state/wcs/cursor.box-project-3-1"
run
[ "$(puts)" = 0 ] && ok || bad "an empty drain wrote $(puts) cursor PUT(s)"
[ "$(row box-project-3-1)" = 5 ] && ok || bad "an empty drain moved the cursor (got $(row box-project-3-1))"
! grep -q '^POST /api/wakes/ack' <<<"$(REQ)" && ok || bad "an empty drain acked"
MSG=$(no_legacy) && ok || bad "7: $MSG"

# ---------------------------------------------------------------------------
# 8. the seed is asked ONCE per invocation, not once per cycle
# ---------------------------------------------------------------------------
reset; echo 41 > "$H/state/wcs/cursor.box-hub"
WAKE_LOOP_CYCLES=3 run
[ "$(LOG | grep -c "cursor seeded from the hub's: 41")" = 1 ] && ok \
  || bad "the seed must happen once per invocation: $(LOG)"
[ "$(REQ | grep -c '^GET /api/wakes/cursor')" = 2 ] && ok \
  || bad "3 cycles must ask for cursors exactly twice (own + hub, once): $(REQ | grep cursor)"

echo "wake-cursor-writethrough-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
