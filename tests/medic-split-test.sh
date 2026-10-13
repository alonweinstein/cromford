#!/bin/bash
# tests/medic-split-test.sh — alerts-medic dispatches ONE session per root-cause
# family, and its cap defers rather than drops.
#
# Runs the REAL bin/alerts-medic.sh end to end. Only the harness ROOT is
# rewritten (the CI precedent). agent-call.sh, curl, flock, jq's network — the
# things that would leave the machine or spend money — are stubbed; what they
# RECEIVE is the assertion.
#
# MEDIC IS NOT ALERT-TRIAGE, and the differences are where the bugs live:
#   * its queue is the console API, not a file it drains. So there is no spool:
#     a deferred family survives by NOT being consumed. That means TWO trapdoors
#     must both stay shut — the family stamp AND the medic-seen id list. Either
#     one closing on a deferred alert turns the deferral into a silent loss, and
#     a lane that quietly stops examining alerts looks exactly like a quiet one.
#   * its escalation akey used to be `medic:<utc-hour>` — one key for the whole
#     pass. Split into N sessions, that key is the SAME for every family, so the
#     console would dedupe N escalations into one and N-1 real problems would
#     vanish. The akey must carry the family key.
#   * ...and then the HOUR had to come back OUT of it (2026-08-31). Carrying the
#     family key fixed cross-family collision; the hour suffix that rode along
#     caused the opposite failure — the same unfixed problem minted a new key,
#     and so a new console row and a new page, every single hour. Escalations
#     re-entered the medic's own queue, hashed to a new family (the prose is
#     LLM-written and differs each pass), dodged the 6h brake, and bought another
#     session to re-verify the lane's own words. One project-2 condition was
#     observed wearing two family keys and paging into its "6th session".
#     The key is now the family's permanent address: `medic:<fkey>`, no suffix.
# Run from anywhere: tests/medic-split-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" || exit 1  # BH-1510.2: lanes read models from model_routes
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/locks" "$H/env" "$T/stub" "$T/calls"
printf 'CONSOLE_URL=https://console.invalid\nHARNESS_SECRET=testsecret\n' > "$H/env/global.env"

sed "s|/root/harness|$H|g" "$DIR/bin/alerts-medic.sh" > "$H/bin/alerts-medic.sh"
chmod +x "$H/bin/alerts-medic.sh"
for s in triage-map.sh fleet-conf.sh box-for.sh alert_family.py; do ln -sf "$DIR/bin/$s" "$H/bin/$s"; done
# BH-5942: the lane runs per project; rows with no project are the cromford run's.
( cd "$DIR" && scratch_install_closure bin/lib/llm-lane-project.sh "$H" ) >/dev/null || exit 1
MS="$H/state/alerts-medic/cromford"
export FLEET_CONF="$DIR/fleet.conf"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/alerts-groom.sh"; chmod +x "$H/bin/alerts-groom.sh"

# --- stubs -------------------------------------------------------------------
cat > "$H/bin/agent-call.sh" <<'STUB'
#!/bin/bash
N=$(ls "$CALLDIR"/prompt-* 2>/dev/null | wc -l | tr -d ' ')
printf '%s' "$6" > "$CALLDIR/prompt-$N.txt"
echo "medic done" > "$5"
STUB
chmod +x "$H/bin/agent-call.sh"
# curl returns the fixture alert payload — the console API is this lane's queue,
# so the fixture IS the queue and re-offering is just returning it again.
cat > "$T/stub/curl" <<STUB
#!/bin/sh
cat "$T/alerts.json"
STUB
chmod +x "$T/stub/curl"
printf '#!/bin/sh\nexit 0\n' > "$T/stub/flock"; chmod +x "$T/stub/flock"
# `date -u -d '20 minutes ago'` is GNU-only; BSD date exits nonzero, CUTOFF comes
# back empty, and jq's `.createdAt < ""` then selects NOTHING — the lane would
# silently do nothing on a Mac and everything in CI. Pin the one relative form
# the medic uses so the cutoff behaves identically on both, and leave every
# other date invocation (STAMP) untouched.
cat > "$T/stub/date" <<'STUB'
#!/bin/sh
if [ "$1" = "-u" ] && [ "$2" = "-d" ]; then shift 3; exec /bin/date -u "$@"; fi
exec /bin/date "$@"
STUB
chmod +x "$T/stub/date"

# --- fixture -----------------------------------------------------------------
# Markers must vary along an axis the normalizer PRESERVES. This suite has been
# bitten twice by fixtures that collapse: `d1..d5` all normalize to `dN`, one
# family, assertions meaningless. Letters survive; digits do not. Verified with
# the real family() below before any assertion runs.
seed() {  # seed <marker> [<marker> ...] — one family per marker, oldest first
  local i=0 m
  { echo '{"alerts":['
    for m in "$@"; do
      [ "$i" -gt 0 ] && echo ','
      printf '{"id":"alert-%s","createdAt":"2026-08-25T0%d:00:00Z","line":"the %s subsystem is unhappy"}' "$m" "$i" "$m"
      i=$((i+1))
    done
    echo ']}'
  } > "$T/alerts.json"
}
reset_state() { : > "$H/logs/medic.log"; : > "$H/logs/ALERTS.log"; echo '{}' > "$H/state/medic-families.json"; : > "$H/state/medic-seen.txt"; scratch_rm "$MS"; for f in "$H/flags/alerted-medic-backlog-"*; do scratch_rm "$f"; done; }
run() {
  rm -rf "$T/calls"; mkdir -p "$T/calls"
  CALLDIR="$T/calls" PATH="$T/stub:$PATH" bash "$H/bin/alerts-medic.sh" cromford >/dev/null 2>&1
}
ncalls() { ls "$T/calls"/prompt-* 2>/dev/null | wc -l | tr -d ' '; }

# ---------- 0. the fixture actually produces distinct families ---------------
# Assert this FIRST. Everything below is meaningless if the markers collapse,
# and a collapsed fixture fails for a reason that looks like a code bug.
DISTINCT=$(PYTHONPATH="$DIR/bin" python3 -c '
from alert_family import family
ms = ["alpha","bravo","charlie","delta","echo"]
print(len({family("alert-%s\tthe %s subsystem is unhappy" % (m, m)) for m in ms}))')
[ "$DISTINCT" = 5 ] && ok || bad "the fixture markers must be 5 DISTINCT families under the real family() (got $DISTINCT)"

# ---------- 1. one dispatch per family, each seeing ONLY its own -------------
reset_state
seed alpha bravo charlie
run
[ "$(ncalls)" = 3 ] && ok || bad "3 families must produce 3 dispatches (got $(ncalls))"

# isolation is the control: counting dispatches would pass even if every prompt
# carried the whole batch, which is precisely the behaviour being removed.
ISO_OK=1
for f in "$T"/calls/prompt-*.txt; do
  MINE=""
  for m in alpha bravo charlie; do
    grep -q "the $m subsystem" "$f" && MINE="$MINE $m"
  done
  [ "$(wc -w <<<"$MINE")" -eq 1 ] || { ISO_OK=0; echo "  (prompt $(basename "$f") carries:$MINE)"; }
done
[ "$ISO_OK" = 1 ] && ok || bad "each medic prompt must carry exactly ONE family, not the batch"
COVERED=$(cat "$T"/calls/prompt-*.txt | grep -o 'the [a-z]* subsystem' | sort -u | wc -l | tr -d ' ')
[ "$COVERED" = 3 ] && ok || bad "all 3 families must be covered (got $COVERED) — isolation without coverage is just dropping alerts"
grep -q 'SCOPE: this session is ONE root-cause family' "$T/calls/prompt-0.txt" \
  && ok || bad "the per-family prompt must state its scope"
grep -q '=== HARNESS ORIENTATION' "$T/calls/prompt-0.txt" \
  && ok || bad "the orientation map must still ride in each family prompt"
# the medic SOP must have survived the restructure intact
grep -q 'FORBIDDEN: merging or closing PRs' "$T/calls/prompt-0.txt" \
  && ok || bad "the medic's bounds must still be in the prompt"

# ---------- 2. the escalation akey is per FAMILY, and ONLY the family --------
# Two failures bracket this one assertion. Too coarse (`medic:<utc-hour>`, one
# key per pass) and N escalations dedupe into one, losing N-1 real problems.
# Too fine (`medic:<fkey>:<utc-hour>`) and the SAME problem mints a fresh key
# every hour, which is a new console row and a new page forever. The key must be
# exactly the family: distinct across families, identical across time.
AKEY_OK=1
for f in "$T"/calls/prompt-*.txt; do
  grep -q '"akey":"medic:[0-9a-f]\{12\}"' "$f" || AKEY_OK=0
done
[ "$AKEY_OK" = 1 ] && ok || bad "each family's prompt must carry its own akey (got: $(grep -o '"akey":"medic:[^"]*"' "$T/calls/prompt-0.txt" | head -1))"
UNIQ_AKEYS=$(grep -ho '"akey":"medic:[0-9a-f]\{12\}"' "$T"/calls/prompt-*.txt | sort -u | wc -l | tr -d ' ')
[ "$UNIQ_AKEYS" = 3 ] && ok || bad "the 3 families must carry 3 DIFFERENT akeys (got $UNIQ_AKEYS)"
# The time-varying suffix must be gone from the contract, not merely unmentioned:
# a prompt that still shows the model an hour placeholder will get an hourly key.
! grep -q 'utc-hour' "$T/calls/prompt-0.txt" \
  && ok || bad "the escalation akey must carry NO time component — an hourly key re-pages the same problem forever"
# An escalation is a finished investigation addressed to a human. Without
# triaged:true beat.sh quarantines it, and alert-triage spends a SECOND LLM
# session forming an opinion about the medic's own conclusion.
grep -q '"triaged":true' "$T/calls/prompt-0.txt" \
  && ok || bad "the escalation beat must be marked triaged:true so it goes to the human, not back through the triage lane"

# ---------- 3. lines of one family share a session --------------------------
reset_state
cat > "$T/alerts.json" <<'EOF'
{"alerts":[
{"id":"a1","createdAt":"2026-08-25T01:00:00Z","line":"the alpha subsystem is unhappy: 3 builds stuck"},
{"id":"a2","createdAt":"2026-08-25T02:00:00Z","line":"the alpha subsystem is unhappy: 17 builds stuck"},
{"id":"b1","createdAt":"2026-08-25T03:00:00Z","line":"the bravo subsystem is unhappy"}]}
EOF
run
[ "$(ncalls)" = 2 ] && ok || bad "two lines of one family + one other = 2 sessions (got $(ncalls))"

# ---------- 4. the cap defers; BOTH trapdoors stay shut ---------------------
reset_state
seed alpha bravo charlie delta echo
scratch_rm "$T/calls"; mkdir -p "$T/calls"
MEDIC_MAX_FAMILIES=4 CALLDIR="$T/calls" PATH="$T/stub:$PATH" \
  bash "$H/bin/alerts-medic.sh" cromford >/dev/null 2>&1
[ "$(ncalls)" = 4 ] && ok || bad "5 families under a cap of 4 must dispatch 4 (got $(ncalls))"
grep -q 'deferred 1 famil.*session cap (4)' "$H/logs/medic.log" \
  && ok || bad "the deferral must be DECLARED (got: $(tail -2 "$H/logs/medic.log"))"
# which marker was deferred? the one absent from every prompt
DEFERRED_M=""
for m in alpha bravo charlie delta echo; do
  grep -ql "the $m subsystem" "$T"/calls/prompt-*.txt || DEFERRED_M="$m"
done
[ -n "$DEFERRED_M" ] && ok || bad "exactly one marker should have gone undispatched"
# trapdoor 1: its ids must NOT be in medic-seen
! grep -q "alert-$DEFERRED_M" "$MS/medic-seen.txt" \
  && ok || bad "a deferred alert must NOT be marked seen (it would never be re-offered)"
# the dispatched ones MUST be, or every pass re-pays for them
grep -q "alert-alpha" "$MS/medic-seen.txt" \
  && ok || bad "a dispatched alert must be marked seen"
# trapdoor 2: only the 4 dispatched families may be stamped in the 6h brake
FAMCOUNT=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$MS/medic-families.json")
[ "$FAMCOUNT" = 4 ] && ok || bad "only the 4 DISPATCHED families may be stamped (got $FAMCOUNT)"

# ---------- 5. the deferred family is picked up next pass -------------------
# The console still holds it, it is unseen and unstamped, and being older it
# sorts first — so the very next pass triages it and nothing else.
run
[ "$(ncalls)" = 1 ] && ok || bad "the next pass must triage the deferred family (got $(ncalls))"
grep -q "the $DEFERRED_M subsystem" "$T/calls/prompt-0.txt" \
  && ok || bad "the next pass's session must be the family that was deferred"

# ---------- 6. the backlog DEPTH is declared past a threshold ---------------
# A per-pass "deferred N" line is a RATE. This lane runs every 30 min, so a
# reader cannot tell pass 3 from pass 60 while the oldest alert ages.
reset_state
seed alpha bravo charlie delta echo
scratch_rm "$T/calls"; mkdir -p "$T/calls"
MEDIC_MAX_FAMILIES=1 MEDIC_BACKLOG_ALERT=2 CALLDIR="$T/calls" PATH="$T/stub:$PATH" \
  bash "$H/bin/alerts-medic.sh" cromford >/dev/null 2>&1
grep -q 'DEFERRAL BACKLOG: 4 families still open and unexamined' "$H/logs/ALERTS.log" \
  && ok || bad "past the threshold the depth must reach ALERTS.log (got: $(cat "$H/logs/ALERTS.log"))"
# the negative direction — an alarm that always rings is one nobody reads
reset_state
seed alpha bravo charlie delta echo
scratch_rm "$T/calls"; mkdir -p "$T/calls"
MEDIC_MAX_FAMILIES=1 CALLDIR="$T/calls" PATH="$T/stub:$PATH" \
  bash "$H/bin/alerts-medic.sh" cromford >/dev/null 2>&1
grep -q 'deferred 4 famil' "$H/logs/medic.log" \
  && ok || bad "the under-threshold case must still have deferred something, or it proves nothing"
! grep -q 'DEFERRAL BACKLOG' "$H/logs/ALERTS.log" \
  && ok || bad "under the threshold ALERTS.log must stay clean (got: $(cat "$H/logs/ALERTS.log"))"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
