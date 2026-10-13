#!/bin/bash
# tests/triage-split-test.sh — alert-triage dispatches ONE session per root-cause
# family, and the session cap defers rather than drops.
#
# This runs the REAL bin/alert-triage.sh end to end. Only the harness ROOT is
# rewritten (the CI precedent: `sed "s|HARNESS=/root/harness|...|"` for
# triage-gate and merge-sweep) — every decision is made by the shipped code:
# the collector, the python family brake, the grouping, the cap, the deferral
# spool and the dispatch loop. agent-call.sh, ssh, flock and timeout are stubbed
# because they are the only things that would leave this machine or cost money;
# what they RECEIVE is the assertion.
#
# What is at stake. The split's whole value is that a session sees one unit and
# nothing else, so "3 dispatches happened" proves almost nothing on its own —
# the load-bearing assertion is that each prompt does NOT contain the other
# families' text. And the cap may reduce spend but may never reduce coverage: a
# deferred family that gets stamped by the 6h brake is silently swallowed on the
# next tick, which would look exactly like a working cap right up until the
# alert nobody triaged turned out to matter.
# Run from anywhere: tests/triage-split-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/triage-tick.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" || exit 1  # BH-1510.2: lanes read models from model_routes
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/locks" "$H/env" "$T/stub" "$T/calls"
: > "$H/env/global.env"

# the script under test, with only its harness root repointed
sed "s|/root/harness|$H|g" "$DIR/bin/alert-triage.sh" > "$H/bin/alert-triage.sh"
chmod +x "$H/bin/alert-triage.sh"
triage_tick_setup "$H" || exit 1
# BH-5942: a line whose project is not in fleet.conf belongs to the home
# project's run; its spool and brake files live here.
HP="$H/state/alert-triage/cromford"

# the real orientation renderer, so the prompt the lane builds is the real one
for s in triage-map.sh fleet-conf.sh box-for.sh alert_family.py; do ln -sf "$DIR/bin/$s" "$H/bin/$s"; done
export FLEET_CONF="$DIR/fleet.conf"

# --- stubs: the only things that would leave this machine or spend money ------
cat > "$H/bin/agent-call.sh" <<'STUB'
#!/bin/bash
# agent-call.sh <stage> <lane> <model> <turns> <outfile> <prompt>
N=$(ls "$CALLDIR"/prompt-* 2>/dev/null | wc -l | tr -d ' ')
printf '%s' "$6" > "$CALLDIR/prompt-$N.txt"
printf '%s\t%s\n' "$3" "${RUNNER_TRIAGE:-default}" >> "$CALLDIR/models.tsv"
echo "handled=1 escalated=0 noise=0" > "$5"
STUB
chmod +x "$H/bin/agent-call.sh"
printf '#!/bin/sh\nexit 0\n' > "$T/stub/ssh";   chmod +x "$T/stub/ssh"
printf '#!/bin/sh\nexit 0\n' > "$T/stub/flock"; chmod +x "$T/stub/flock"
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$T/stub/timeout"; chmod +x "$T/stub/timeout"

# --- fixture: quarantine lines in the real format (epoch<TAB>beat-json) ------
# beat.sh writes exactly this; the collector prefixes the source box.
q() { printf '%s\t{"kind":"fleet_alert","project":"%s","akey":"%s","line":"%s"}\n' \
        "$(date -u +%s)" "$2" "$3" "$4" >> "$1"; }

seed() {  # seed <marker> [<marker> ...] — one distinct family per marker
  : > "$H/state/alert-quarantine.jsonl"
  for m in "$@"; do
    q "$H/state/alert-quarantine.jsonl" "proj-$m" "akey-$m" "the $m subsystem is unhappy"
  done
}

run() {
  rm -rf "$T/calls"; mkdir -p "$T/calls"
  CALLDIR="$T/calls" PATH="$T/stub:$PATH" triage_tick "$H/bin/alert-triage.sh" >/dev/null 2>&1
}
ncalls() { ls "$T/calls"/prompt-* 2>/dev/null | wc -l | tr -d ' '; }

reset_state() { triage_tick_reset "$H"; : > "$H/logs/alert-triage.log"; echo '{}' > "$H/state/alert-families.json"; : > "$H/state/alert-triage-deferred.tsv"; }

# ---------- 1. one dispatch per family, and each sees ONLY its own ------------
reset_state
seed alpha bravo charlie
run
[ "$(ncalls)" = 3 ] && ok || bad "3 distinct families must produce 3 dispatches (got $(ncalls))"

# the isolation control: presence alone would pass even if every prompt held
# every alert, which is exactly the bug this change is undoing.
ISO_OK=1
for f in "$T"/calls/prompt-*.txt; do
  MINE=""; OTHERS=""
  for m in alpha bravo charlie; do
    if grep -q "the $m subsystem" "$f"; then MINE="$MINE $m"; else OTHERS="$OTHERS $m"; fi
  done
  [ "$(wc -w <<<"$MINE")" -eq 1 ] || { ISO_OK=0; echo "  (prompt $(basename "$f") carries families:$MINE)"; }
done
[ "$ISO_OK" = 1 ] && ok || bad "each prompt must carry exactly ONE family's lines, not the batch"
# every family got covered — isolation without coverage is just dropping alerts
COVERED=$(cat "$T"/calls/prompt-*.txt | grep -o 'the [a-z]* subsystem' | sort -u | wc -l | tr -d ' ')
[ "$COVERED" = 3 ] && ok || bad "all 3 families must be covered across the dispatches (got $COVERED)"
# the scope sentence tells the session the boundary is the harness's, not its own
grep -q 'SCOPE: this session is ONE root-cause family' "$T/calls/prompt-0.txt" \
  && ok || bad "the per-family prompt must state its scope"
# and the orientation map still rides along (PR A must survive the split)
grep -q '=== HARNESS ORIENTATION' "$T/calls/prompt-0.txt" \
  && ok || bad "the orientation map must still be in each family prompt"

# ---------- 2. lines of the SAME family share one session --------------------
# The two alpha lines differ only in a COUNT — which is exactly what the family
# normalization erases and a raw hash of the line would not. That difference is
# the point: it is what distinguishes "grouped by root cause" from "grouped by
# byte equality", and it is how a second, divergent key would be caught.
reset_state
: > "$H/state/alert-quarantine.jsonl"
q "$H/state/alert-quarantine.jsonl" proj-x akey-x "the alpha subsystem is unhappy: 3 builds stuck"
q "$H/state/alert-quarantine.jsonl" proj-x akey-x "the alpha subsystem is unhappy: 17 builds stuck"
q "$H/state/alert-quarantine.jsonl" proj-y akey-y "the bravo subsystem is unhappy"
run
[ "$(ncalls)" = 2 ] && ok || bad "two lines of one family + one other = 2 sessions (got $(ncalls))"

# ---------- 3. the cap defers, and the deferred family SURVIVES --------------
reset_state
seed a1 b2 c3 d4 e5
scratch_rm "$T/calls"; mkdir -p "$T/calls"; TRIAGE_MAX_FAMILIES=4 CALLDIR="$T/calls" PATH="$T/stub:$PATH" triage_tick "$H/bin/alert-triage.sh" >/dev/null 2>&1
[ "$(ncalls)" = 4 ] && ok || bad "5 families under a cap of 4 must dispatch 4 (got $(ncalls))"
grep -q 'deferred 1 families to next tick — session cap' "$H/logs/alert-triage.log" \
  && ok || bad "the deferral must be DECLARED in the log (got: $(tail -2 "$H/logs/alert-triage.log"))"
[ -s "$HP/deferred.tsv" ] \
  && ok || bad "the deferred family's lines must be spooled, not dropped"
DEFERRED_MARK=$(grep -o 'the [a-z0-9]* subsystem' "$HP/deferred.tsv" | sort -u)
[ "$(wc -l <<<"$DEFERRED_MARK" | tr -d ' ')" = 1 ] && ok || bad "exactly one family should be spooled (got: $DEFERRED_MARK)"
# it must NOT have been triaged this pass
! grep -qF "$DEFERRED_MARK" "$T"/calls/prompt-*.txt \
  && ok || bad "a deferred family must not also have been dispatched"
# processed families ARE consumed: the quarantine is drained
[ ! -s "$H/state/alert-quarantine.jsonl" ] \
  && ok || bad "the quarantine must be consumed for the families that ran"

# ---------- 4. the deferred family is picked up by the NEXT tick -------------
# The trap: the 6h brake stamps a family when it is triaged. Stamping a DEFERRED
# family would make the next tick see a "repeat" and drop it — the deferral
# would silently become a loss. So the stamp must follow the dispatch, not the
# grouping.
FAMCOUNT=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$HP/alert-families.json")
[ "$FAMCOUNT" = 4 ] && ok || bad "only the 4 DISPATCHED families may be stamped in the 6h brake (got $FAMCOUNT)"
run   # next tick: nothing new in quarantine, only the spool
[ "$(ncalls)" = 1 ] && ok || bad "the next tick must triage the deferred family (got $(ncalls) dispatches)"
grep -qF "$DEFERRED_MARK" "$T/calls/prompt-0.txt" \
  && ok || bad "the next tick's session must be the family that was deferred"
[ ! -s "$HP/deferred.tsv" ] \
  && ok || bad "the spool must be drained once its families are triaged"

# ---------- 5. tiering is PER FAMILY, not per pass ---------------------------
# A never-seen family buys the strong investigator; a re-occurrence whose TTL
# expired runs on the housekeeping floor. Per-pass tiering meant one new family
# bought the flagship for every stale one riding along with it.
reset_state
seed newone oldone
OLDSIG=$(python3 - "$H" <<'PY'
import hashlib, re, sys, json, time
h = sys.argv[1]
# same normalization the script uses, applied to the line the collector will build
line = [l.rstrip("\n") for l in open(f"{h}/state/alert-quarantine.jsonl") if "oldone" in l][0]
line = "hub\t" + line
s = re.sub(r'[0-9a-f]{8,}', 'H', line); s = re.sub(r'\d+', 'N', s)
sig = hashlib.sha1(s.encode()).hexdigest()[:12]
json.dump({sig: time.time() - 7 * 3600}, open(f"{h}/state/alert-families.json", "w"))
print(sig)
PY
)
run
[ "$(ncalls)" = 2 ] && ok || bad "both families should run (old one's TTL is expired) (got $(ncalls))"
grep -q 'claude-fable-5' "$T/calls/models.tsv" \
  && ok || bad "the never-seen family must get the strong investigator (models: $(cat "$T/calls/models.tsv"))"
grep -q 'claude-sonnet-5	fireworks' "$T/calls/models.tsv" \
  && ok || bad "the re-occurring family must get the housekeeping floor (models: $(cat "$T/calls/models.tsv"))"
[ "$(sort -u "$T/calls/models.tsv" | wc -l | tr -d ' ')" = 2 ] \
  && ok || bad "the two families must be tiered DIFFERENTLY in one pass (models: $(cat "$T/calls/models.tsv"))"

# ---------- 6. the backlog DEPTH is declared, not just the rate --------------
# The per-tick "deferred N families" line is a RATE. Throughput is cap x 6 =
# 24 families/hour; past that the spool grows while every tick logs the same
# shape, so tick 3 and tick 60 read identically and the oldest alert ages with
# no trace — the dead-feed shape, as a queue. Depth goes to ALERTS.log because
# that is what a human reads.
reset_state
: > "$H/logs/ALERTS.log"
seed dalpha dbravo dcharlie ddelta decho
scratch_rm "$T/calls"; mkdir -p "$T/calls"
TRIAGE_MAX_FAMILIES=1 TRIAGE_SPOOL_ALERT=2 CALLDIR="$T/calls" PATH="$T/stub:$PATH" \
  triage_tick "$H/bin/alert-triage.sh" >/dev/null 2>&1
grep -q 'DEFERRAL BACKLOG' "$H/logs/ALERTS.log" \
  && ok || bad "a spool over the threshold must declare the backlog in ALERTS.log (got: $(cat "$H/logs/ALERTS.log"))"
# the DEPTH must be the real one, not a canned string — a wrong number is worse
# than none, because it is what a human would size the response against
SPOOL_LINES=$(wc -l < "$HP/deferred.tsv" | tr -d ' ')
grep -q "DEFERRAL BACKLOG: $SPOOL_LINES lines spooled" "$H/logs/ALERTS.log" \
  && ok || bad "the declared depth must match the real spool ($SPOOL_LINES lines): $(grep BACKLOG "$H/logs/ALERTS.log")"
grep -q "exceed 1 families/tick" "$H/logs/ALERTS.log" \
  && ok || bad "the backlog line must name the cap that is being exceeded"

# the negative direction, and it is the one that matters most: an alarm that
# always rings is an alarm nobody reads. Under the threshold, ALERTS.log stays
# clean even though a deferral definitely happened.
reset_state
: > "$H/logs/ALERTS.log"
seed qalpha qbravo qcharlie qdelta qecho
scratch_rm "$T/calls"; mkdir -p "$T/calls"
TRIAGE_MAX_FAMILIES=1 CALLDIR="$T/calls" PATH="$T/stub:$PATH" \
  triage_tick "$H/bin/alert-triage.sh" >/dev/null 2>&1
[ -s "$HP/deferred.tsv" ] \
  && ok || bad "the under-threshold case must still have deferred something (otherwise it proves nothing)"
! grep -q 'DEFERRAL BACKLOG' "$H/logs/ALERTS.log" \
  && ok || bad "a spool under the threshold must stay silent (got: $(cat "$H/logs/ALERTS.log"))"

# ---------- 7. ONE family key, across every lane that has one ---------------
# Two implementations of one rule is this repo's known failure shape, and this
# rule had two for months: alert-triage normalized 8+ hex then digits in two
# case-sensitive passes, alerts-medic lowercased and did 7+ hex and digits in
# one — while its comment claimed they were "the same normalization". The same
# incident could therefore be one family to one lane and two to the other.
# The assertion is now the stronger property: NO lane defines it locally, every
# lane imports the shared module, and the module defines it once.
[ "$(grep -c 'def family(' "$DIR/bin/alert_family.py")" = 1 ] \
  && ok || bad "bin/alert_family.py must define family() exactly once"
for LANE in alert-triage alerts-medic; do
  [ "$(grep -c 'def family(' "$DIR/bin/$LANE.sh")" = 0 ] \
    && ok || bad "$LANE.sh must not define its own family() — import the shared one"
  [ "$(grep -c 'hashlib.sha1' "$DIR/bin/$LANE.sh")" = 0 ] \
    && ok || bad "$LANE.sh must not compute a family signature of its own"
  grep -q 'from alert_family import family' "$DIR/bin/$LANE.sh" \
    && ok || bad "$LANE.sh must import the shared family key"
done

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
