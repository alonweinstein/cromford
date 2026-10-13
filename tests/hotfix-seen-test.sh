#!/bin/bash
# tests/hotfix-seen-test.sh — the first-seen ANNOUNCEMENT and the paused
# waiting line (#368 hotfix lane, slice BH-415).
#
# WHAT THIS PINS AND WHY. bin/hotfix-seen.sh is the only part of the hotfix
# lane a human ever sees directly: everything else makes an emergency ticket
# plan first, build first and exceed a cap by one, and all of that is
# invisible. So what is asserted here is the ARTIFACTS — the lines in
# logs/ALERTS.log, the beats in $BEAT_SINK, the marker under
# state/hotfix-announced/ and the waiting line in logs/<project>.log — never
# the shape of the source.
#
# THE NEGATIVES CARRY THE WEIGHT. This script is hooked to a */10 cron tick, so
# the failure that costs money is not a missed announcement, it is a tick this
# script kills: a dead gh, an unparseable listing, a project with no prompt
# file, a board-prefix project. Each of those is driven and each must exit 0
# having said nothing.
#
# The wiring half is driven too, not grepped: the paused early-exit block is
# extracted VERBATIM from bin/run-triage.sh and executed with a recording stub,
# because "run-triage.sh mentions hotfix-seen.sh" passes just as happily on a
# version that calls it after the cost gate, or one where a failing call kills
# the paused tick.
#
# Run from anywhere: tests/hotfix-seen-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

export HARNESS="$T" FLEET_CONF="$T/fleet.conf" REPOS_ROOT="$T/repos"
mkdir -p "$T/bin/lib" "$T/env" "$T/flags" "$T/logs" "$T/state" "$T/prompts" "$T/repos"
cp "$DIR/bin/lib/hotfix-lib.sh" "$DIR/bin/lib/preplan-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/bin/lib/" 2>/dev/null
for f in hotfix-seen.sh fleet-conf.sh; do cp "$DIR/bin/$f" "$T/bin/" 2>/dev/null; done
export PATH="$T/bin:$PATH"

# The beat sink: bin/lib/hotfix-lib.sh:hotfix_announce calls $HARNESS/bin/beat.sh
# with one JSON argument, so one line here is one console alert.
export BEAT_SINK="$T/beat.txt"; : > "$BEAT_SINK"
cat > "$T/bin/beat.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$BEAT_SINK"
exit 0
SH
chmod +x "$T/bin/beat.sh"

# The gh stub records its argv, because WHICH LABELS the listing filters on is
# the prime rule of this lane and is invisible in the output.
#
# (BH-781) The listing is GET /repos/{slug}/issues?labels=ai-build,<hotfix>
# through bin/lib/gh-rest.sh, so the stub answers in the wire shape that library
# reads: a status line, a blank line, then the body. GH_FAIL=1 is a 401 with no
# body; GH_FAIL=2 is the 403 that carries a payload AND is still a refusal —
# reading that payload as an answer is the #768 defect.
export GH_ARGS="$T/gh-args.txt"; : > "$GH_ARGS"
cat > "$T/bin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_ARGS"
[ "${GH_FAIL:-}" = 1 ] && { printf 'HTTP/2.0 401 Unauthorized\nx-stub: 1\n\n{"message":"Bad credentials"}\n'; exit 1; }
[ "${GH_FAIL:-}" = 2 ] && { printf 'HTTP/2.0 403 Forbidden\nx-stub: 1\n\n'; cat "$HARNESS/issues.json"; exit 1; }
case "$*" in
  *"/issues"*) printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n'; cat "$HARNESS/issues.json" ;;
esac
SH
chmod +x "$T/bin/gh"

cat > "$T/fleet.conf" <<'CONF'
proj  example-org/proj   -                 -           0 local -
bproj example-org/bproj  https://b.example /api/board  0 local -
CONF
echo 'setsid /root/harness/bin/run-build.sh proj <issue-number> AB-<issue-number> > x' > "$T/prompts/proj.md"
echo 'setsid /root/harness/bin/run-build.sh bproj <ticket> TK-<issue-number> > x' > "$T/prompts/bproj.md"
: > "$T/env/global.env"

reset_all() { : > "$T/logs/ALERTS.log"; : > "$BEAT_SINK"; : > "$GH_ARGS"; : > "$T/logs/proj.log"; }

# ════════════════════════════════════════════════════════════════════════════
# 1. THE SCRIPT ITSELF. Absent is a failure, never a skip — a suite that goes
#    quiet when the thing under test is missing reports green on nothing.
# ════════════════════════════════════════════════════════════════════════════
if [ ! -x "$T/bin/hotfix-seen.sh" ]; then
  bad "bin/hotfix-seen.sh does not exist or is not executable — every assertion in sections 2-9 depends on it"
else

cat > "$T/issues.json" <<'JSON'
[
 {"number":60,"title":"payments are down"},
 {"number":61,"title":"login loop"}
]
JSON

# ════════════════════════════════════════════════════════════════════════════
# 2. FIRST SEEN — one line and one beat per hotfix issue
# ════════════════════════════════════════════════════════════════════════════
reset_all; rm -rf "$T/state/hotfix-announced"
"$T/bin/hotfix-seen.sh" proj; RC=$?
[ "$RC" = 0 ] && ok || bad "hotfix-seen.sh must exit 0 (rc=$RC)"
[ "$(grep -c 'HOTFIX seen' "$T/logs/ALERTS.log")" = 2 ] && ok \
  || bad "two hotfix issues must produce two ALERTS lines (got: $(cat "$T/logs/ALERTS.log"))"
# BH-2337: `seen` is a notice — the ALERTS lines are the record, no alert row.
[ "$(grep -c . "$BEAT_SINK")" = 0 ] && ok || bad "HOTFIX seen must not beat (got: $(cat "$BEAT_SINK"))"
grep -q '\[proj/AB-60\] HOTFIX seen: AB-60 — payments are down' "$T/logs/ALERTS.log" \
  && ok || bad "the line must name project, key and title: $(cat "$T/logs/ALERTS.log")"
grep -q '\[proj/AB-61\] HOTFIX seen: AB-61 — login loop' "$T/logs/ALERTS.log" \
  && ok || bad "the second issue must be announced too: $(cat "$T/logs/ALERTS.log")"

# ════════════════════════════════════════════════════════════════════════════
# 3. ONCE PER ISSUE, FOR LIFE — the marker is what makes a */10 tick safe
# ════════════════════════════════════════════════════════════════════════════
"$T/bin/hotfix-seen.sh" proj
[ "$(grep -c 'HOTFIX seen' "$T/logs/ALERTS.log")" = 2 ] && ok \
  || bad "a second tick must announce nothing (got: $(cat "$T/logs/ALERTS.log"))"
[ "$(grep -c . "$BEAT_SINK")" = 0 ] && ok || bad "a second tick must not beat either (got: $(cat "$BEAT_SINK"))"
[ -f "$T/state/hotfix-announced/proj/AB-60.seen" ] && ok || bad "the dedupe marker for AB-60 was not written"
[ -f "$T/state/hotfix-announced/proj/AB-61.seen" ] && ok || bad "the dedupe marker for AB-61 was not written"

# ════════════════════════════════════════════════════════════════════════════
# 4. PAUSED — a pause is a HUMAN decision and is never overridden. One line per
#    tick to the project log so the wait is visible, and NO page: alerting every
#    ten minutes about a pause somebody set on purpose is how a channel stops
#    being read.
# ════════════════════════════════════════════════════════════════════════════
reset_all; touch "$T/flags/paused-proj"
"$T/bin/hotfix-seen.sh" proj --paused; RC=$?
[ "$RC" = 0 ] && ok || bad "--paused must exit 0 (rc=$RC)"
[ "$(grep -c 'is waiting on flags/paused-proj' "$T/logs/proj.log")" = 2 ] && ok \
  || bad "each held hotfix must log one waiting line per tick (got: $(cat "$T/logs/proj.log"))"
[ ! -s "$T/logs/ALERTS.log" ] && ok || bad "--paused must not page: $(cat "$T/logs/ALERTS.log")"
[ ! -s "$BEAT_SINK" ] && ok || bad "--paused must not beat: $(cat "$BEAT_SINK")"
# NOT deduped across ticks, by design: the line says "still waiting", and a
# marker would make a pause that outlives one tick look resolved.
"$T/bin/hotfix-seen.sh" proj --paused
[ "$(grep -c 'is waiting on flags/paused-proj' "$T/logs/proj.log")" = 4 ] && ok \
  || bad "a second paused tick must add its own lines (got: $(cat "$T/logs/proj.log"))"
[ ! -s "$T/logs/ALERTS.log" ] && ok || bad "a second paused tick must still not page: $(cat "$T/logs/ALERTS.log")"
rm -f "$T/flags/paused-proj"

# ════════════════════════════════════════════════════════════════════════════
# 5. A BOARD-PREFIX PROJECT has no GitHub labels, so the lane is silent there.
# ════════════════════════════════════════════════════════════════════════════
reset_all; rm -rf "$T/state/hotfix-announced"
"$T/bin/hotfix-seen.sh" bproj; RC=$?
[ "$RC" = 0 ] && [ ! -s "$T/logs/ALERTS.log" ] && [ ! -s "$BEAT_SINK" ] && ok \
  || bad "a board-prefix project must produce nothing (rc=$RC alerts=$(cat "$T/logs/ALERTS.log"))"
[ ! -s "$GH_ARGS" ] && ok || bad "a board-prefix project must not even call gh: $(cat "$GH_ARGS")"

# ════════════════════════════════════════════════════════════════════════════
# 6. A DEAD gh is silent, rc 0, and writes NO marker — the next tick retries
#    for free. This is an announcement, never a tick killer.
# ════════════════════════════════════════════════════════════════════════════
reset_all; rm -rf "$T/state/hotfix-announced"
OUT=$(GH_FAIL=1 "$T/bin/hotfix-seen.sh" proj 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "a dead gh must still exit 0 (rc=$RC)"
[ -z "$OUT" ] && ok || bad "a dead gh must print nothing to a cron tick's stdout/stderr (got: $OUT)"
[ ! -s "$T/logs/ALERTS.log" ] && [ ! -s "$BEAT_SINK" ] && ok || bad "a dead gh must announce nothing"
[ ! -e "$T/state/hotfix-announced/proj/AB-60.seen" ] && ok \
  || bad "a failed listing must NOT write a marker, or the announcement is lost for life"

# ...and a call that exits nonzero having already PRINTED a payload is still a
# failure, not data. Announcing off a body a failed call happened to emit burns
# the once-per-life marker on a read nobody can vouch for (D9).
reset_all; rm -rf "$T/state/hotfix-announced"
OUT=$(GH_FAIL=2 "$T/bin/hotfix-seen.sh" proj 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "a failed-but-chatty gh must still exit 0 (rc=$RC)"
[ ! -s "$T/logs/ALERTS.log" ] && [ ! -s "$BEAT_SINK" ] && ok \
  || bad "a nonzero gh must not be announced off its own output (alerts=$(cat "$T/logs/ALERTS.log"))"
[ ! -e "$T/state/hotfix-announced/proj/AB-60.seen" ] && ok \
  || bad "a nonzero gh must not burn the once-per-life marker"
[ -z "$OUT" ] && ok || bad "a failed-but-chatty gh must print nothing to the tick (got: $OUT)"

# ════════════════════════════════════════════════════════════════════════════
# 7. THE KILL FLAG, both spellings.
# ════════════════════════════════════════════════════════════════════════════
reset_all; rm -rf "$T/state/hotfix-announced"
HOTFIX_LANE=0 "$T/bin/hotfix-seen.sh" proj
[ ! -s "$T/logs/ALERTS.log" ] && [ ! -s "$BEAT_SINK" ] && ok || bad "HOTFIX_LANE=0 must silence hotfix-seen.sh"
reset_all; touch "$T/flags/hotfix-lane-off"
"$T/bin/hotfix-seen.sh" proj
[ ! -s "$T/logs/ALERTS.log" ] && [ ! -s "$BEAT_SINK" ] && ok || bad "flags/hotfix-lane-off must silence hotfix-seen.sh"
rm -f "$T/flags/hotfix-lane-off"

# ════════════════════════════════════════════════════════════════════════════
# 8. AN EMPTY OR BROKEN LISTING is not an announcement and not a crash.
# ════════════════════════════════════════════════════════════════════════════
reset_all; rm -rf "$T/state/hotfix-announced"
echo '[]' > "$T/issues.json"
"$T/bin/hotfix-seen.sh" proj; RC=$?
[ "$RC" = 0 ] && [ ! -s "$T/logs/ALERTS.log" ] && [ ! -s "$BEAT_SINK" ] && ok \
  || bad "an empty listing must produce nothing (rc=$RC)"
reset_all
echo 'not json' > "$T/issues.json"
OUT=$("$T/bin/hotfix-seen.sh" proj 2>&1); RC=$?
[ "$RC" = 0 ] && [ ! -s "$T/logs/ALERTS.log" ] && [ ! -s "$BEAT_SINK" ] && ok \
  || bad "an unparseable listing must produce nothing (rc=$RC out=$OUT)"

# ════════════════════════════════════════════════════════════════════════════
# 9. THE LABEL FILTER IS AN AND. A `hotfix` label on an issue without
#    `ai-build` is invisible everywhere else in the fleet, so it must be
#    invisible here: two --label flags, which GitHub ANDs.
# ════════════════════════════════════════════════════════════════════════════
cat > "$T/issues.json" <<'JSON'
[
 {"number":60,"title":"payments are down"},
 {"number":61,"title":"login loop"}
]
JSON
reset_all; rm -rf "$T/state/hotfix-announced"
"$T/bin/hotfix-seen.sh" proj
LIST=$(grep '/issues' "$GH_ARGS" | head -1)
[ -n "$LIST" ] && ok || bad "hotfix-seen.sh never listed the issues (argv: $(cat "$GH_ARGS"))"
# A COMMA LIST IS GITHUB'S AND, the same semantics two --label flags had.
case "$LIST" in *"labels=ai-build,hotfix"*) ok ;; *) bad "the listing must AND ai-build with the hotfix label (got: $LIST)" ;; esac
case "$LIST" in *"state=open"*) ok ;; *) bad "the listing must ask for open issues only (got: $LIST)" ;; esac
reset_all; rm -rf "$T/state/hotfix-announced"
HOTFIX_LABEL=urgent "$T/bin/hotfix-seen.sh" proj
LIST=$(grep '/issues' "$GH_ARGS" | head -1)
case "$LIST" in *"labels=ai-build,urgent"*) ok ;; *) bad "HOTFIX_LABEL must move the listing's label (got: $LIST)" ;; esac
case "$LIST" in *hotfix*) bad "with HOTFIX_LABEL=urgent the word hotfix must not be filtered on (got: $LIST)" ;; *) ok ;; esac

fi

# ════════════════════════════════════════════════════════════════════════════
# 10. THE TWO CALL SITES IN THE TRIAGE TICK.
#
# The paused block is EXTRACTED VERBATIM from bin/run-triage.sh and executed,
# because what matters is not that the file mentions hotfix-seen.sh — it is
# that the paused tick calls it with --paused, still logs its own line, and
# still exits 0 when the call fails.
# ════════════════════════════════════════════════════════════════════════════
PBLOCK="$T/paused-block.sh"
# TEST-CHANGE BH-4153: the paused gate now opens on flag_active (the
# paused-<project> row) and tests the file only when no client is loaded, so the
# block starts at that two-line `if`; it still ends at the first column-0 `fi`.
awk '/^if \{ command -v flag_active .*flag_active "paused-\$PROJECT"/,/^fi$/' "$DIR/bin/run-triage.sh" > "$PBLOCK"
if [ ! -s "$PBLOCK" ] || ! grep -q 'hotfix-seen.sh' "$PBLOCK"; then
  bad "the paused early-exit block of bin/run-triage.sh does not call hotfix-seen.sh (extracted: $(cat "$PBLOCK"))"
else
  mkdir -p "$T/rt/bin" "$T/rt/flags" "$T/rt/logs"
  : > "$T/seen-args"
  cat > "$T/rt/bin/hotfix-seen.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$SEEN_ARGS"
exit 0
SH
  chmod +x "$T/rt/bin/hotfix-seen.sh"
  touch "$T/rt/flags/paused-proj"
  : > "$T/rt.log"
  ( set -uo pipefail
    export SEEN_ARGS="$T/seen-args"
    HARNESS="$T/rt"; PROJECT=proj; STAMP=STAMP; LOG="$T/rt.log"
    LANE_TICK() { :; }
    # shellcheck source=/dev/null
    . "$PBLOCK"
    echo "BLOCK-FELL-THROUGH" >> "$LOG" )
  RC=$?
  [ "$RC" = 0 ] && ok || bad "the paused block must exit 0 (rc=$RC)"
  [ "$(cat "$T/seen-args")" = "proj --paused" ] && ok \
    || bad "the paused block must call hotfix-seen.sh <project> --paused (got: '$(cat "$T/seen-args")')"
  grep -q 'paused via console' "$T/rt.log" && ok \
    || bad "the paused block must still log its own line (got: $(cat "$T/rt.log"))"
  grep -q 'BLOCK-FELL-THROUGH' "$T/rt.log" && bad "the paused block must still exit the tick" || ok

  # ...and a hotfix-seen.sh that FAILS changes nothing: the call is `|| true`
  # with its output discarded, so a broken announcement never kills a tick.
  cat > "$T/rt/bin/hotfix-seen.sh" <<'SH'
#!/bin/bash
echo "boom" >&2
exit 1
SH
  chmod +x "$T/rt/bin/hotfix-seen.sh"
  : > "$T/rt.log"
  OUT=$( ( set -uo pipefail
           HARNESS="$T/rt"; PROJECT=proj; STAMP=STAMP; LOG="$T/rt.log"
           LANE_TICK() { :; }
           # shellcheck source=/dev/null
           . "$PBLOCK" ) 2>&1 ); RC=$?
  [ "$RC" = 0 ] && ok || bad "a failing hotfix-seen.sh must not change the paused tick's rc (rc=$RC)"
  [ -z "$OUT" ] && ok || bad "a failing hotfix-seen.sh must have its output discarded (got: $OUT)"
  grep -q 'paused via console' "$T/rt.log" && ok \
    || bad "a failing hotfix-seen.sh must not cost the paused line (got: $(cat "$T/rt.log"))"
fi

# The plain call sits BEFORE the triage cost gate: an emergency filed on a quiet
# board would otherwise be announced only on whichever later tick the gate chose
# to pay for on other grounds. Line numbers, guarded so an absent call fails.
#
# Measured over the driver FOLLOWED BY bin/lib/rt/gate.sh (BH-479), which is the
# tick's real execution order: the paused early exit is still in the driver, and
# the plain announcement and the cost gate moved together into the gate stage the
# driver calls after it. So "paused above plain above gate" is the same sentence
# about the same tick, read in the order the tick runs.
RTALL="$T/rt-order.sh"
cat "$DIR/bin/run-triage.sh" "$DIR/bin/lib/rt/gate.sh" > "$RTALL"
N=$(grep -c 'hotfix-seen.sh' "$RTALL")
# TEST-CHANGE (BH-1684): three calls now, not two. A triage row in the pauses
# table (rt_pause_triage, bin/lib/rt/gate.sh) ends the tick the way the
# paused-<project> flag does, and makes the same fail-open --paused call so a
# held hotfix stays visible under either kind of pause.
[ "$N" = 3 ] && ok || bad "the tick must call hotfix-seen.sh three times (flag pause + row pause + plain), got $N"
grep -q 'hotfix-seen.sh" "$PROJECT" --paused' <<<"$(sed -n '/^rt_pause_triage()/,/^}/p' "$DIR/bin/lib/rt/gate.sh")" \
  && ok || bad "rt_pause_triage must make the --paused hotfix-seen call before it exits"
PLAIN=$(grep -n -F 'hotfix-seen.sh" "$PROJECT" >/dev/null' "$RTALL" | head -1 | cut -d: -f1)
PAUSED=$(grep -n -F 'hotfix-seen.sh" "$PROJECT" --paused' "$RTALL" | head -1 | cut -d: -f1)
GATE=$(grep -n -F 'GATE_DECISION=$("$HARNESS/bin/triage-gate.sh"' "$RTALL" | head -1 | cut -d: -f1)
[ -n "$PLAIN" ] && ok  || { bad "no plain hotfix-seen.sh call in the tick (bin/run-triage.sh + bin/lib/rt/gate.sh)"; PLAIN=0; }
[ -n "$PAUSED" ] && ok || { bad "no --paused hotfix-seen.sh call in the tick (bin/run-triage.sh + bin/lib/rt/gate.sh)"; PAUSED=0; }
[ -n "$GATE" ] && [ "$GATE" -gt 0 ] && ok || { bad "the triage cost gate call moved — this ordering check is now blind"; GATE=0; }
[ "$PLAIN" -gt 0 ] && [ "$GATE" -gt 0 ] && [ "$PLAIN" -lt "$GATE" ] && ok \
  || bad "the plain hotfix-seen.sh call must sit ABOVE the triage cost gate (plain=$PLAIN gate=$GATE)"
[ "$PAUSED" -gt 0 ] && [ "$PLAIN" -gt 0 ] && [ "$PAUSED" -lt "$PLAIN" ] && ok \
  || bad "the --paused call belongs in the paused early exit, above the plain call (paused=$PAUSED plain=$PLAIN)"

echo "hotfix-seen: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
