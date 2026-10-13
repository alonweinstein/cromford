#!/bin/bash
# tests/event-wake-scope-test.sh — the deterministic pass runs on the tick that
# actually fires, AND a wake tick is scoped to the object the wake was about.
#
# THE SECOND HALF (2026-09-14, the shard storm). #333 gave the wake the SAME
# scope a board-changed tick takes: the whole fingerprint diff. On project-5 that
# meant ~13 doorbell presses an hour each adopting a dozen moved tickets and the
# dispatcher buying a session for every one — 190 sessions in the 19Z hour,
# against 4-7 in every hour before it, 129 of them concluding buildable=0. The
# contract now: state/wake-keys-<project> names the changed object(s), those
# lines and only those lines are the scope, and a wake that names nothing runs
# the deterministic pass alone and buys no board enumeration at all.
#
# WHAT WENT WRONG. bin/triage-gate.sh answers `RUN event-wake` for a webhook
# delivery (docs/EVENTS.md §2), and since the wake loop was armed that is the
# DOMINANT gate reason on a live box: the project-5 watcher logged 17 of them in
# one afternoon and zero `board-changed` ticks. bin/run-triage.sh's scope `case`
# had no `event-wake` arm, so every one of those ticks built the plain full-SOP
# prompt and bin/unblocked-children.sh was never called — 0 DEP_ lines, 0
# STACKABLE launches, while a hand run of the same script on the same box
# printed 9 STACKABLE lines. The second half of the same bug: the pass only ran
# when the board diff was NON-EMPTY, and the STACKABLE / dep-verified-soft /
# de-labelled-release classes have no board trigger by design — so a quiet board
# meant they never ran at all.
#
# This drives the REAL bin/run-triage.sh, roots rewritten (the CI precedent), and
# asserts on what the agent call RECEIVES. Shards are disarmed so one tick is one
# prompt; tests/triage-shards-test.sh owns the split.
# Run from anywhere: tests/event-wake-scope-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" project-5 || exit 1  # BH-1510.2: lanes read models from model_routes
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/locks" "$H/env" "$H/flags" "$H/prompts" \
         "$H/builds" "$H/fixture" "$T/calls" "$T/repos"
: > "$H/env/global.env"
P=project-5
echo "SOP for $P. Fetch the thread. Do the work." > "$H/prompts/$P.md"
export FLEET_CONF="$DIR/fleet.conf"

sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$DIR/bin/run-triage.sh" > "$H/bin/run-triage.sh"
chmod +x "$H/bin/run-triage.sh"
mkdir -p "$H/bin/lib/rt"; for s in "$DIR"/bin/lib/rt/*.sh; do sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$s" > "$H/bin/lib/rt/$(basename "$s")"; done
for s in fleet-conf.sh project-of.sh decision-log.sh; do ln -sf "$DIR/bin/$s" "$H/bin/$s"; done
# The REAL key vocabulary: the wake-key filter canonicalises both sides through
# it (`TK-667` and `667` are one ticket on a GitHub-Issues board), so stubbing it
# would test the stub.
cp "$DIR/bin/lib/triage-shards-lib.sh" "$H/bin/lib/triage-shards-lib.sh"
printf '#!/bin/sh\necho box-project-5-1\n' > "$H/bin/box-name.sh"; chmod +x "$H/bin/box-name.sh"

# --- stubs -------------------------------------------------------------------
# The gate: records every invocation (the --pending fetch is a load-bearing step
# of the new arm — the wake exits the real gate BEFORE any fingerprint is
# fetched, so without it gate-diff.sh would diff a stale file), writes the
# pending fingerprint where the real one does, and prints the fixture's verdict.
cat > "$H/bin/triage-gate.sh" <<STUB
#!/bin/bash
PRJ="\$1"; MODE="\${2:-}"
printf '%s %s\n' "\$PRJ" "\$MODE" >> "$H/gate-calls.log"
if [ "\$MODE" = "--pending" ]; then
  [ -e "$H/fixture/pending-fail" ] && exit 1
  cp "$H/fixture/pending.json" "$H/state/\$PRJ.gate.pending"; exit 0
fi
cp "$H/fixture/pending.json" "$H/state/\$PRJ.gate.pending"
cat "$H/fixture/gate-decision"
exit 0
STUB
chmod +x "$H/bin/triage-gate.sh"
# gate-diff's three answers, verbatim from its header: 0 with a diff, 2 for
# "fingerprints identical — nothing moved", 1 for anything unusable.
cat > "$H/bin/gate-diff.sh" <<STUB
#!/bin/bash
[ "\$(cat "$H/fixture/diff" 2>/dev/null)" = UNUSABLE ] && exit 1
[ -s "$H/fixture/diff" ] || exit 2
cat "$H/fixture/diff"
STUB
chmod +x "$H/bin/gate-diff.sh"
# unblocked-children: prints the fixture's lines and records the scope it was
# handed on stdin, so "was the closure trigger still passed through" is provable.
cat > "$H/bin/unblocked-children.sh" <<STUB
#!/bin/bash
cat >> "$H/unblocked-stdin.log"
echo "--" >> "$H/unblocked-stdin.log"
echo call >> "$H/unblocked-calls.log"
cat "$H/fixture/unblocked" 2>/dev/null
exit 0
STUB
chmod +x "$H/bin/unblocked-children.sh"
printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$H/bin/triage-contract.sh"; chmod +x "$H/bin/triage-contract.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
cat > "$H/bin/agent-call.sh" <<'STUB'
#!/bin/bash
D="${CALLDIR:?}"
# mktemp, NOT a count. `prompt-$(ls | wc -l).txt` is read-then-write with no lock,
# and three shards launched in the same instant all read 0 and all wrote
# prompt-0.txt: two of the three prompts vanished, ncalls never reached 3, and
# settle() reported "the 3 shards did not land" — the CI flake of 2026-09-14.
# The race is in the FIXTURE, not in the dispatcher, which is why it moved.
PR="$6"; case "$PR" in @/*) PR=$(cat "${PR#@}") ;; esac
F=$(mktemp "$D/prompt-XXXXXXXX.txt")
printf '%s' "$PR" > "$F"
echo "tickets=1 done" > "$5"
exit 0
STUB
chmod +x "$H/bin/agent-call.sh"

FP='{"issues":[{"number":667,"state":"OPEN","title":"parent"},{"number":669,"state":"OPEN","title":"child"}],"prs":[]}'
STACK='board issues: STACKABLE 710 "TK-710 first slice" base=ticket/TK-709 parent-pr=https://gh/900 (Blocked-by #709 is still open but its PR is open too — launchable NOW on top of that branch, same queue rules as UNBLOCKED, if no PR or build already covers it)'
SOFT='board issues: UNBLOCKED 669 "TK-669 hat merge knobs" (dep-verified soft: #667 — those blockers are still open, but this slice'"'"'s planned files are disjoint from theirs)'

reset() { # reset <gate-decision> <diff-text> <unblocked-text> [wake-keys]
  rm -rf "$T/calls" "$H/state" "$H/locks" "$H/logs" "$H/builds"
  model_routes_fixture "$H" project-5 || exit 1   # the reset above took the model-routes cache with it
  mkdir -p "$T/calls" "$H/state" "$H/locks" "$H/logs" "$H/builds"
  rm -f "$H/gate-calls.log" "$H/unblocked-calls.log" "$H/unblocked-stdin.log" "$H/fixture/pending-fail"
  printf '%s' "$FP" > "$H/fixture/pending.json"
  printf '%s' "$FP" > "$H/state/$P.gate.json"
  echo "$1" > "$H/fixture/gate-decision"
  printf '%s' "$2" > "$H/fixture/diff"
  printf '%s' "$3" > "$H/fixture/unblocked"
  : > "$H/logs/READY-QUEUE.log"
  [ -n "${4:-}" ] && printf '%s\n' $4 > "$H/state/wake-keys-$P"
  return 0
}
run() { CALLDIR="$T/calls" TRIAGE_SHARDS=0 "$H/bin/run-triage.sh" "$P" >/dev/null 2>&1; }
prompt() { cat "$(ls "$T/calls"/prompt-*.txt 2>/dev/null | head -1)" 2>/dev/null; }
ncalls() { ls "$T/calls"/prompt-* 2>/dev/null | wc -l | tr -d ' '; }
nunblocked() { grep -c . "$H/unblocked-calls.log" 2>/dev/null || echo 0; }

DIFF1='board issues: CHANGED 667 "parent" (state: OPEN -> CLOSED; activity)'
# Two tickets moved since the last consumed tick, which is the normal shape of a
# busy board — and the shape that made one webhook buy a dozen sessions.
DIFF2='board issues: CHANGED 667 "parent" (state: OPEN -> CLOSED; activity)
board issues: CHANGED 668 "another ticket entirely" (comments: 1 -> 2)'

# ---------- 1. an event-wake tick on an UNCHANGED board still runs the pass --
# The whole point: a wake whose board diff is empty is not an empty tick. The
# classes that have no board trigger are the tick's work, and their lines are
# the scope.
reset "RUN event-wake" "" "$STACK"
run
[ "$(ncalls)" = 1 ] && ok || bad "one tick must buy exactly one agent call (got $(ncalls))"
[ "$(nunblocked)" -ge 1 ] && ok || bad "an event-wake tick must call bin/unblocked-children.sh (it did not)"
grep -q 'TICK SCOPE (deterministic' <<<"$(prompt)" && ok || bad "an event-wake tick with launchable children must carry a TICK SCOPE, not the full SOP"
grep -q 'the board itself did not move this tick' <<<"$(prompt)" && ok || bad "a scope built only from the dependency pass must SAY the board did not move"
grep -q 'STACKABLE 710 ' <<<"$(prompt)" && ok || bad "the STACKABLE line must be in the tick scope"
# the wording that tells the session what to DO with the line survives
grep -q 'STACK_BASE=<the line'"'"'s base= value>' <<<"$(prompt)" && ok || bad "the STACKABLE launch instruction must be preserved in the scoped prompt"
grep -q 'dep-verified soft' <<<"$(prompt)" && ok || bad "the UNBLOCKED/soft explanation must be preserved in the scoped prompt"
# the fingerprint the gate never fetched for a wake
grep -q -- "$P --pending" "$H/gate-calls.log" && ok || bad "an event-wake tick must fetch the live fingerprint itself (the gate exits before doing it)"

# ---------- 2. a KEYED wake carries its own object, and only its own ---------
# The storm in one assertion. Two tickets moved; the webhook was about 667; the
# tick must read 667 and leave 668 to the tick whose reason it is.
reset "RUN event-wake" "$DIFF2" "$SOFT" "667"
run
grep -q 'CHANGED 667 ' <<<"$(prompt)" && ok || bad "the wake's own object must be in the scope"
grep -q 'CHANGED 668 ' <<<"$(prompt)" && bad "a wake must NOT drag in every other ticket that moved since the last consumed tick" || ok
grep -q 'UNBLOCKED 669 ' <<<"$(prompt)" && ok || bad "the dependency pass's lines must still be appended to a keyed scope"
grep -q 'the object(s) this webhook named (667)' <<<"$(prompt)" && ok || bad "a keyed scope must say which object the webhook named: $(prompt | head -1)"
grep -q 'CHANGED 667 ' "$H/unblocked-stdin.log" && ok || bad "the filtered diff must be handed to unblocked-children on stdin (it is the closure trigger)"
grep -q 'CHANGED 668 ' "$H/unblocked-stdin.log" && bad "the sibling's line must not reach the dependency pass either" || ok
grep -q 'event-wake scope=2 keys=667' "$H/logs/$P.log" && ok || bad "every wake tick must log 'event-wake scope=N keys=...': $(grep event-wake "$H/logs/$P.log" | head -1)"
# …and the keys file is ONE-SHOT: a key that outlived its wake would scope some
# later tick to a ticket nobody rang about.
[ ! -f "$H/state/wake-keys-$P" ] && ok || bad "state/wake-keys-<project> must be consumed by the tick that reads it"

# ---------- 2b. a GitHub board spells one ticket two ways -------------------
# The wake may carry TK-667 where the diff says 667. One ticket, one scope line.
reset "RUN event-wake" "$DIFF2" "" "TK-667"
run
grep -q 'CHANGED 667 ' <<<"$(prompt)" && ok || bad "a wake key in <PREFIX>-<n> form must match the diff's bare number"
grep -q 'CHANGED 668 ' <<<"$(prompt)" && bad "canonicalising the key must not widen the scope" || ok

# ---------- 2c. a key the board diff does not carry buys no enumeration ------
# The wake named something, the board verified it did not move: there is nothing
# to work, and the old behaviour (fall through to the full SOP) meant a doorbell
# press bought a whole board read.
reset "RUN event-wake" "$DIFF2" "" "999"
run
[ "$(ncalls)" = 0 ] && ok || bad "a wake naming an object the diff does not carry must buy no session (got $(ncalls))"
grep -q 'rc=skip :: event-wake named no board object' "$H/logs/$P.log" && ok || bad "…and must say so: $(tail -1 "$H/logs/$P.log")"

# ---------- 3. no usable diff = today's full SOP, unchanged -----------------
# rc 1 is "no scope hint" (a near-full-board diff, unreadable state). Scoping the
# tick to the dependency lines alone would silently drop whatever the gate fired
# on, so this case must fall through exactly as it always has.
reset "RUN event-wake" "UNUSABLE" "$STACK"
run
grep -q 'TICK SCOPE' <<<"$(prompt)" && bad "an unusable diff must not be narrowed to the dependency lines" || ok
grep -q 'SOP for project-5' <<<"$(prompt)" && ok || bad "the full SOP must still be the prompt when no scope is adopted"
[ "$(nunblocked)" = 0 ] && ok || bad "a tick that cannot adopt a scope must not pay for the pass (called $(nunblocked)x)"

# ---------- 4. a keyless wake with an empty pass buys NOTHING ----------------
# It used to fall through to the full SOP — a whole board enumeration, on a
# doorbell press, at the most expensive tick shape there is. The pass is free and
# still runs; when it finds nothing, the tick is a skip and the cron tick keeps
# the sweep.
reset "RUN event-wake" "" ""
run
[ "$(nunblocked)" -ge 1 ] && ok || bad "the pass must still be asked on a quiet board"
[ "$(ncalls)" = 0 ] && ok || bad "a wake with no key and nothing deterministic must buy no session (got $(ncalls))"
grep -q 'event-wake scope=0 keys=none' "$H/logs/$P.log" && ok || bad "the tick must log its empty scope"

# ---------- 4b. a KEYLESS wake never inherits the board diff -----------------
# The storm's other half: a push wake carries a head sha, so there is no key, and
# the diff beside it belongs to whatever moved since the last consumed tick.
reset "RUN event-wake" "$DIFF2" "$SOFT"
run
grep -q 'CHANGED 66[78] ' <<<"$(prompt)" && bad "a keyless wake must not adopt the board diff as its scope" || ok
grep -q 'UNBLOCKED 669 ' <<<"$(prompt)" && ok || bad "a keyless wake must still run the deterministic pass and act on its lines"
[ "$(ncalls)" = 1 ] && ok || bad "…in exactly one session (got $(ncalls))"

# ---------- 5. a failed fingerprint fetch falls through, it does not guess ---
reset "RUN event-wake" "$DIFF1" "$STACK"
touch "$H/fixture/pending-fail"
run
grep -q 'TICK SCOPE' <<<"$(prompt)" && bad "a fingerprint fetch that failed must not scope the tick off a stale diff" || ok
rm -f "$H/fixture/pending-fail"

# ---------- 6. board-changed keeps its own path, byte for byte --------------
reset "RUN board-changed" "$DIFF1" "$SOFT"
run
grep -q 'CHANGED 667 ' <<<"$(prompt)" && ok || bad "a board-changed tick must still scope on its diff"
grep -q 'UNBLOCKED 669 ' <<<"$(prompt)" && ok || bad "a board-changed tick must still append the dependency pass's lines"
grep -q -- "$P --pending" "$H/gate-calls.log" && bad "board-changed must NOT buy a second fingerprint fetch — the gate already made one" || ok

# ---------- 7. a results-sweep tick on an unchanged board ------------------
# board_section's rc=2 arm: "the board is verified unchanged" answers a question
# about the BOARD, and these classes are not about the board. The sweep keeps its
# own scope and the launchable children ride along in the ALSO section.
reset "RUN results-sweep" "" "$STACK"
mkdir -p "$H/builds/$P-TK-700-20260914"
echo "PR_CREATED https://gh/1" > "$H/builds/$P-TK-700-20260914/RESULT"
run
grep -q 'TICK SCOPE (results sweep' <<<"$(prompt)" && ok || bad "the sweep scope must survive (got: $(prompt | head -3))"
grep -q 'ALSO launchable right now' <<<"$(prompt)" && ok || bad "an unchanged board must still carry the launchable children into a sweep tick"
grep -q 'STACKABLE 710 ' <<<"$(prompt)" && ok || bad "the STACKABLE line must reach a sweep tick's prompt"

# ---------- 8. ...and a sweep on an unchanged board with nothing launchable --
reset "RUN results-sweep" "" ""
mkdir -p "$H/builds/$P-TK-700-20260914"
echo "PR_CREATED https://gh/1" > "$H/builds/$P-TK-700-20260914/RESULT"
run
grep -q 'TICK SCOPE (results sweep' <<<"$(prompt)" && ok || bad "the sweep scope must still be adopted when the pass finds nothing"
grep -q 'ALSO' <<<"$(prompt)" && bad "nothing launchable must add no ALSO section" || ok

echo "event-wake-scope: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
