#!/bin/bash
# tests/hotfix-dispatch-order-test.sh — the hotfix lane's ORDERING half and its
# BLOCKER half, in bin/preplan-candidates.sh (#368 / BH-416).
#
# WHAT THIS PINS AND WHY. One label on one issue is supposed to reorder the
# whole pre-plan list, and every part of that is silent when it breaks: a hotfix
# that sorts second still gets built, just an hour late, and nothing logs a word
# about it. So the order is asserted as OUTPUT LINES of the real
# bin/preplan-candidates.sh driven against a stubbed gh, never as the shape of
# the source.
#
# The other half is the thing a label must NOT do. A hotfix whose author wrote a
# Blocked-by (or Needs:) line naming code that has not landed is not ready,
# whatever its label says — so it is not emitted at all, and that is driven under
# both spellings of the dep-verify kill flag, because "the emergency ticket
# jumped a live blocker" is the one failure this lane could cause that is worse
# than being slow. When it is held, the project log has to say so: a hotfix that
# silently never appears is indistinguishable from a hotfix nobody filed.
#
# The lib vocabulary (bin/lib/hotfix-lib.sh) is tests/hotfix-lib-test.sh's and
# the announcement lane is tests/hotfix-seen-test.sh's; neither is re-asserted
# here.
#
# Run from anywhere: tests/hotfix-dispatch-order-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

export HARNESS="$T" FLEET_CONF="$T/fleet.conf" REPOS_ROOT="$T/repos"
mkdir -p "$T/bin/lib" "$T/env" "$T/flags" "$T/logs" "$T/locks" "$T/state" \
         "$T/prompts" "$T/repos" "$T/tmp"
# TEST-CHANGE (BH-782): gh-rest.sh joins the copied libs — bin/preplan-candidates.sh
# reads GitHub through the REST contract now, and without it every tick answers
# "launch gate UNKNOWN" and emits no candidate rows at all.
cp "$DIR/bin/lib/hotfix-lib.sh" "$DIR/bin/lib/preplan-lib.sh" \
   "$DIR/bin/lib/dep-verify-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/bin/lib/" 2>/dev/null
for f in preplan-candidates.sh fleet-conf.sh project-of.sh; do
  cp "$DIR/bin/$f" "$T/bin/" 2>/dev/null
done
export PATH="$T/bin:$PATH"
cat > "$T/fleet.conf" <<'CONF'
proj  example-org/proj   -                 -           0 local -
bproj example-org/bproj  https://b.example /api/board  0 local -
CONF
echo 'setsid /root/harness/bin/run-build.sh proj <issue-number> AB-<issue-number> > x' > "$T/prompts/proj.md"
echo 'setsid /root/harness/bin/run-build.sh bproj <ticket> TK-<issue-number> > x' > "$T/prompts/bproj.md"
: > "$T/env/global.env"

# The stub gh: one fixture file per call the script makes, and GH_FAIL=1 is a
# dead token. Nothing here reaches GitHub.
#
# IT HONOURS --json, which is the point: a real `gh issue list` returns only the
# fields it was asked for, so a script that forgets to ask for `labels` gets a
# payload with no labels in it. Echoing the fixture back whole would let every
# ordering assertion below pass against a call that never requested the field.
# TEST-CHANGE (BH-782): `gh api -i` shim. GH_FAIL=1 is a real 401 (an unreadable
# answer, which the lane now answers with queued lines and no candidates) and
# GH_EMPTY=1 is a real 200 with `[]` (a genuinely empty board, which is a fact
# and is acted on). Those two were indistinguishable before this ticket, which
# is the whole point of it.
cat > "$T/bin/gh" <<'SH'
#!/bin/bash
[ "${1:-}" = api ] || exit 1
shift
# The query args come AFTER the path (gh api -i -X GET <path> -f k=v), so the
# loop keeps going once the path is taken rather than breaking out of it.
INC=0; P=""; ARGS=""
while [ $# -gt 0 ]; do
  case "$1" in
    -i) INC=1; shift ;;
    -X|-H) shift 2 ;;
    -f|-F) ARGS="$ARGS $2"; shift 2 ;;
    -*) shift ;;
    *) [ -n "$P" ] || P="$1"; shift ;;
  esac
done
ST=200; BODY=""
if [ "${GH_FAIL:-}" = 1 ]; then
  ST=401; BODY='{"message":"Bad credentials"}'
else
  case "$P" in
    */issues*)
      case "$ARGS" in *labels*) ;; *) exit 1 ;; esac
      if [ "${GH_EMPTY:-}" = 1 ]; then BODY='[]'
      else BODY=$(cat "$HARNESS/issues.json"); fi ;;
    */pulls*) BODY=$(cat "$HARNESS/prs.json") ;;
    *) exit 1 ;;
  esac
fi
[ "$INC" = 1 ] && printf 'HTTP/2.0 %s\r\n\r\n' "$ST"
[ -n "$BODY" ] && printf '%s\n' "$BODY"
case "$ST" in 2*) exit 0 ;; *) exit 1 ;; esac
SH
chmod +x "$T/bin/gh"
echo '[]' > "$T/prs.json"

# ════════════════════════════════════════════════════════════════════════════
# 2. THE ORDER — a hotfix sorts ahead of everything in every class
# ════════════════════════════════════════════════════════════════════════════
cat > "$T/issues.json" <<'JSON'
[
 {"number":10,"state":"CLOSED","title":"parent merged","body":"","labels":[]},
 {"number":20,"state":"OPEN","title":"child of a merged parent","body":"Blocked-by: #10","labels":[{"name":"ai-build"}]},
 {"number":30,"state":"OPEN","title":"older plain ready one","body":"","labels":[{"name":"ai-build"}]},
 {"number":50,"state":"OPEN","title":"the roof is on fire","body":"","labels":[{"name":"ai-build"},{"name":"hotfix"}]}
]
JSON
: > "$T/logs/READY-QUEUE.log"
CAND=$("$T/bin/preplan-candidates.sh" proj 2>/dev/null)
[ "$(sed -n 1p <<<"$CAND")" = "$(printf 'AB-50\t50\tahead')" ] && ok \
  || bad "the hotfix must be line 1 of the candidate list (got: $(sed -n 1p <<<"$CAND"))"
# ...and the rest is untouched: today's classes in today's order, after it.
[ "$(sed -n 2p <<<"$CAND")" = "$(printf 'AB-20\t20\tchild')" ] && ok \
  || bad "the child must still be emitted, right after the hotfix (got: $CAND)"
[ "$(sed -n 3p <<<"$CAND")" = "$(printf 'AB-30\t30\tahead')" ] && ok \
  || bad "the plain ready ticket must still be emitted after the child (got: $CAND)"

# THE READY-QUEUE CLASS IS NOT AN EXCEPTION. A queued line has had priority
# since 2026-07-23 and keeps it against everything except an emergency.
printf 'AB-7 tkt-7 — something ready project=proj\n' > "$T/logs/READY-QUEUE.log"
CAND=$("$T/bin/preplan-candidates.sh" proj 2>/dev/null)
[ "$(sed -n 1p <<<"$CAND")" = "$(printf 'AB-50\t50\tahead')" ] && ok \
  || bad "the hotfix must sort ahead of the READY-QUEUE class too (got: $(sed -n 1p <<<"$CAND"))"
[ "$(sed -n 2p <<<"$CAND")" = "$(printf 'AB-7\ttkt-7\tqueued')" ] && ok \
  || bad "the queued line must be second, not dropped (got: $CAND)"
# ...and the plain queued line still outranks every speculative class, which is
# the half of 2026-07-23 that must survive this change untouched.
[ "$(sed -n 3p <<<"$CAND")" = "$(printf 'AB-20\t20\tchild')" ] && ok \
  || bad "a plain queued line must stay above the speculative classes (got: $CAND)"
# A hotfix that is ALREADY on the queue moves to the front ONCE — a duplicate
# row would have the tick spend two pre-plan slots on one ticket.
printf 'AB-50 tkt-50 — the roof is on fire project=proj\n' > "$T/logs/READY-QUEUE.log"
CAND=$("$T/bin/preplan-candidates.sh" proj 2>/dev/null)
[ "$(sed -n 1p <<<"$CAND")" = "$(printf 'AB-50\ttkt-50\tqueued')" ] && ok \
  || bad "a queued hotfix must move to the front (got: $(sed -n 1p <<<"$CAND"))"
[ "$(grep -c '^AB-50' <<<"$CAND")" = 1 ] && ok \
  || bad "a queued hotfix must be emitted ONCE, not twice (got: $CAND)"
: > "$T/logs/READY-QUEUE.log"

# TWO HOTFIXES ARE STILL ORDERED AMONG THEMSELVES. Being first is not the same
# as being unordered: inside the hotfix half the ordinary class order holds
# (a child whose parent is clearing outranks an untouched ready ticket), and
# two rows of one class come out oldest-number first — the same rule the rest of
# the list has always followed.
cat > "$T/issues.json" <<'JSON'
[
 {"number":10,"state":"CLOSED","title":"parent merged","body":"","labels":[]},
 {"number":60,"state":"OPEN","title":"emergency, no blockers","body":"","labels":[{"name":"hotfix"}]},
 {"number":65,"state":"OPEN","title":"another emergency, no blockers","body":"","labels":[{"name":"hotfix"}]},
 {"number":70,"state":"OPEN","title":"emergency whose parent has merged","body":"Blocked-by: #10","labels":[{"name":"hotfix"}]}
]
JSON
CAND=$("$T/bin/preplan-candidates.sh" proj 2>/dev/null)
[ "$(sed -n 1p <<<"$CAND")" = "$(printf 'AB-70\t70\tchild')" ] && ok \
  || bad "inside the hotfix half a child must still outrank an ahead row (got: $CAND)"
[ "$(sed -n 2p <<<"$CAND")" = "$(printf 'AB-60\t60\tahead')" ] && ok \
  || bad "two hotfixes of one class must come out oldest-number first (got: $CAND)"
[ "$(sed -n 3p <<<"$CAND")" = "$(printf 'AB-65\t65\tahead')" ] && ok \
  || bad "the second hotfix ahead row must follow the first (got: $CAND)"
# ...and PREPLAN_AHEAD does not drop either of them: the cap bounds speculation,
# and an emergency is not a guess about what might be worth planning.
[ "$(PREPLAN_AHEAD=1 "$T/bin/preplan-candidates.sh" proj 2>/dev/null | grep -c .)" = 3 ] && ok \
  || bad "PREPLAN_AHEAD must not drop a hotfix (got: $(PREPLAN_AHEAD=1 "$T/bin/preplan-candidates.sh" proj 2>/dev/null))"

cat > "$T/issues.json" <<'JSON'
[
 {"number":10,"state":"CLOSED","title":"parent merged","body":"","labels":[]},
 {"number":20,"state":"OPEN","title":"child of a merged parent","body":"Blocked-by: #10","labels":[{"name":"ai-build"}]},
 {"number":30,"state":"OPEN","title":"older plain ready one","body":"","labels":[{"name":"ai-build"}]},
 {"number":50,"state":"OPEN","title":"the roof is on fire","body":"","labels":[{"name":"ai-build"},{"name":"hotfix"}]}
]
JSON
# The kill flag puts the ordering back to what it was before #368, under both
# spellings.
CAND=$(HOTFIX_LANE=0 "$T/bin/preplan-candidates.sh" proj 2>/dev/null)
[ "$(sed -n 1p <<<"$CAND" | cut -f3)" = child ] && ok \
  || bad "HOTFIX_LANE=0 must restore the pre-#368 order (got: $CAND)"
touch "$T/flags/hotfix-lane-off"
CAND=$("$T/bin/preplan-candidates.sh" proj 2>/dev/null)
[ "$(sed -n 1p <<<"$CAND" | cut -f3)" = child ] && ok \
  || bad "flags/hotfix-lane-off must restore the pre-#368 order (got: $CAND)"
rm -f "$T/flags/hotfix-lane-off"

# THE ADVERSARIAL LABELS. Each of these is a label a human would plausibly type
# on a ticket that is NOT the emergency one, and each of them reading as a
# hotfix is a queue jumped for a ticket nobody declared urgent. The word
# "hotfix" in a TITLE is not a label either.
cat > "$T/issues.json" <<'JSON'
[
 {"number":10,"state":"CLOSED","title":"parent merged","body":"","labels":[]},
 {"number":20,"state":"OPEN","title":"child of a merged parent","body":"Blocked-by: #10","labels":[{"name":"ai-build"}]},
 {"number":41,"state":"OPEN","title":"is this urgent?","body":"","labels":[{"name":"hotfix-candidate"}]},
 {"number":42,"state":"OPEN","title":"explicitly not one","body":"","labels":[{"name":"not-hotfix"}]},
 {"number":43,"state":"OPEN","title":"hotfix for the login loop","body":"","labels":[{"name":"ai-build"}]}
]
JSON
CAND=$("$T/bin/preplan-candidates.sh" proj 2>/dev/null)
[ "$(sed -n 1p <<<"$CAND")" = "$(printf 'AB-20\t20\tchild')" ] && ok \
  || bad "'hotfix-candidate' / 'not-hotfix' / the word in a title must not promote anything (got: $CAND)"

# FAIL-OPEN: with no bin/lib/hotfix-lib.sh at all the lane is simply off and the
# output is today's, rc 0. An absent lib must never be a dead tick.
cat > "$T/issues.json" <<'JSON'
[
 {"number":10,"state":"CLOSED","title":"parent merged","body":"","labels":[]},
 {"number":20,"state":"OPEN","title":"child of a merged parent","body":"Blocked-by: #10","labels":[{"name":"ai-build"}]},
 {"number":30,"state":"OPEN","title":"older plain ready one","body":"","labels":[{"name":"ai-build"}]},
 {"number":50,"state":"OPEN","title":"the roof is on fire","body":"","labels":[{"name":"ai-build"},{"name":"hotfix"}]}
]
JSON
mv "$T/bin/lib/hotfix-lib.sh" "$T/hotfix-lib.sh.away"
CAND=$("$T/bin/preplan-candidates.sh" proj 2>/dev/null); RC=$?
[ "$RC" -eq 0 ] && ok || bad "an absent hotfix lib must still exit 0 (rc=$RC)"
[ "$(sed -n 1p <<<"$CAND")" = "$(printf 'AB-20\t20\tchild')" ] && ok \
  || bad "an absent hotfix lib must fall back to today's plain order (got: $CAND)"
mv "$T/hotfix-lib.sh.away" "$T/bin/lib/hotfix-lib.sh"

# ════════════════════════════════════════════════════════════════════════════
# 3. A HOTFIX THAT DECLARES A LIVE BLOCKER IS NOT READY, LABEL OR NO LABEL
# ════════════════════════════════════════════════════════════════════════════
cat > "$T/issues.json" <<'JSON'
[
 {"number":11,"state":"OPEN","title":"parent with an open PR","body":"","labels":[]},
 {"number":12,"state":"OPEN","title":"parent nobody started","body":"","labels":[]},
 {"number":30,"state":"OPEN","title":"plain ready","body":"Needs: #12","labels":[{"name":"ai-build"}]},
 {"number":51,"state":"OPEN","title":"hotfix needing code that has not landed","body":"Blocked-by: #12 (hard)","labels":[{"name":"hotfix"}]},
 {"number":52,"state":"OPEN","title":"hotfix whose parent PR is open","body":"Blocked-by: #11","labels":[{"name":"hotfix"}]}
]
JSON
echo '[{"number":99,"title":"fix #11 parent","head":{"ref":"ticket/pr-11","sha":"s99"},"body":"","state":"open","merged_at":null,"user":{"login":"operator","type":"User"}}]' > "$T/prs.json"
: > "$T/logs/proj.log"
CAND=$("$T/bin/preplan-candidates.sh" proj 2>/dev/null)
grep -q '^AB-51' <<<"$CAND" \
  && bad "a hotfix blocked by a not-started issue must NOT be emitted at all (got: $CAND)" || ok
CAND0=$(DEP_VERIFY=0 "$T/bin/preplan-candidates.sh" proj 2>/dev/null)
grep -q '^AB-51' <<<"$CAND0" \
  && bad "DEP_VERIFY=0 must not resurrect a blocked hotfix (got: $CAND0)" || ok
touch "$T/flags/dep-verify-off"
CANDF=$("$T/bin/preplan-candidates.sh" proj 2>/dev/null)
grep -q '^AB-51' <<<"$CANDF" \
  && bad "flags/dep-verify-off must not resurrect a blocked hotfix (got: $CANDF)" || ok
rm -f "$T/flags/dep-verify-off"
# ...but a hotfix whose blocker is already CLEARING is emitted, first, in its
# own class. "Clearing" is the same fact the rest of the fleet reads: closed,
# carried by an open PR, or mid-build.
[ "$(sed -n 1p <<<"$CAND")" = "$(printf 'AB-52\t52\tchild')" ] && ok \
  || bad "a hotfix whose parent PR is open must be emitted first, as a child (got: $CAND)"
# `Needs: #n` is a HOTFIX-ONLY widening: plain #30 names #12 the same way and
# must keep today's grammar, which does not read that line as a blocker at all.
grep -qP '^AB-30\t30\tahead$' <<<"$CAND" && ok \
  || bad "'Needs:' must NOT become a blocker for a plain issue (got: $CAND)"

# ---- F5: the held hotfix says why, in the project log ----------------------
[ "$(grep -c 'not planned: waiting on #12' "$T/logs/proj.log")" -ge 1 ] && ok \
  || bad "a held hotfix must write one line to logs/<project>.log (got: $(cat "$T/logs/proj.log"))"
grep -q '\[proj/AB-51\] hotfix AB-51 not planned: waiting on #12 (open, no PR)' "$T/logs/proj.log" \
  && ok || bad "the held-hotfix line must name project, key and the live blockers (got: $(cat "$T/logs/proj.log"))"
# exactly one line per held hotfix per run, and nothing at all about the one
# that WAS emitted
: > "$T/logs/proj.log"
"$T/bin/preplan-candidates.sh" proj >/dev/null 2>&1
[ "$(grep -c 'not planned: waiting on #12' "$T/logs/proj.log")" = 1 ] && ok \
  || bad "exactly one held-hotfix line per run (got: $(cat "$T/logs/proj.log"))"
[ "$(grep -c 'AB-52' "$T/logs/proj.log")" = 0 ] && ok \
  || bad "an EMITTED hotfix must not be logged as held (got: $(cat "$T/logs/proj.log"))"
# an unwritable log is swallowed: the candidate list is what it was, rc 0
mv "$T/logs" "$T/logs.away"
OUTNOLOG=$("$T/bin/preplan-candidates.sh" proj 2>/dev/null); RC=$?
mv "$T/logs.away" "$T/logs"
[ "$RC" -eq 0 ] && [ "$OUTNOLOG" = "$CAND" ] && ok \
  || bad "an unwritable project log must change nothing (rc=$RC out=$OUTNOLOG)"

# `Needs: #n` on a HOTFIX is the other documented spelling of a hard blocker and
# has to bite exactly like Blocked-by. The positive control comes first, so the
# assertion below cannot pass just because the row fell off the end of some
# budget: with its Needs: blocker already carried by an open PR, the same hotfix
# IS emitted.
jq '(.[] | select(.number==51) | .body) = "Needs: #11"' "$T/issues.json" > "$T/i2.json" && mv "$T/i2.json" "$T/issues.json"
CAND=$("$T/bin/preplan-candidates.sh" proj 2>/dev/null)
grep -q '^AB-51' <<<"$CAND" && ok \
  || bad "a hotfix whose Needs: blocker is already clearing must be emitted (got: $CAND)"
jq '(.[] | select(.number==51) | .body) = "Needs: #12"' "$T/issues.json" > "$T/i2.json" && mv "$T/i2.json" "$T/issues.json"
CAND=$("$T/bin/preplan-candidates.sh" proj 2>/dev/null)
grep -q '^AB-51' <<<"$CAND" \
  && bad "'Needs: #12' on a hotfix must hold it exactly like Blocked-by (got: $CAND)" || ok
grep -q '^AB-52' <<<"$CAND" && ok \
  || bad "the run that drops the blocked hotfix must still emit the clearing one (got: $CAND)"
# "Needs" with no number is a sentence, not a blocker declaration.
jq '(.[] | select(.number==51) | .body) = "Needs the lib slice before this makes sense"' "$T/issues.json" > "$T/i2.json" && mv "$T/i2.json" "$T/issues.json"
CAND=$("$T/bin/preplan-candidates.sh" proj 2>/dev/null)
grep -q '^AB-51' <<<"$CAND" && ok \
  || bad "a 'Needs' line naming no issue must not hold a hotfix (got: $CAND)"

# An issue list with NO labels key at all is what every pre-#368 fixture and a
# gh call without --labels produces: it must parse, not crash the lane.
cat > "$T/issues.json" <<'JSON'
[
 {"number":20,"state":"OPEN","title":"child","body":"Blocked-by: #10"},
 {"number":10,"state":"CLOSED","title":"parent","body":""},
 {"number":30,"state":"OPEN","title":"ready","body":""}
]
JSON
echo '[]' > "$T/prs.json"
CAND=$("$T/bin/preplan-candidates.sh" proj 2>/dev/null)
[ "$(sed -n 1p <<<"$CAND")" = "$(printf 'AB-20\t20\tchild')" ] && ok \
  || bad "an issue list with no labels key must still produce today's order (got: $CAND)"

# ---- F3: the queue buffer is trapped, so no early exit leaks a temp file ----
# The prompt file is moved away, so the KEY prefix is unresolvable and the
# script leaves at its earliest exit — the one furthest from any cleanup.
rm -rf "$T/tmp"; mkdir -p "$T/tmp"
mv "$T/prompts/proj.md" "$T/prompts/proj.md.off"
OUT=$(TMPDIR="$T/tmp" "$T/bin/preplan-candidates.sh" proj 2>/dev/null); RC=$?
mv "$T/prompts/proj.md.off" "$T/prompts/proj.md"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok \
  || bad "an unresolvable KEY prefix must be a silent exit 0 (rc=$RC out=$OUT)"
[ -z "$(ls -A "$T/tmp" 2>/dev/null)" ] && ok \
  || bad "an early exit must leave no temp file behind (found: $(ls -A "$T/tmp"))"

# ---- every early exit carries the queue ------------------------------------
# The queued lines are buffered now, so any path that leaves before the Python
# render has to emit them itself or a ticket that was ABOUT TO BUILD silently
# stops being pre-planned the moment gh has a bad minute.
printf 'AB-7 tkt-7 — something ready project=proj\n' > "$T/logs/READY-QUEUE.log"
OUT=$(GH_FAIL=1 "$T/bin/preplan-candidates.sh" proj 2>/dev/null); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "$(printf 'AB-7\ttkt-7\tqueued')" ] && ok \
  || bad "a dead gh must still emit the queued lines, rc 0 (rc=$RC out=$OUT)"
mv "$T/prompts/proj.md" "$T/prompts/proj.md.off"
OUT=$("$T/bin/preplan-candidates.sh" proj 2>/dev/null); RC=$?
mv "$T/prompts/proj.md.off" "$T/prompts/proj.md"
[ "$RC" -eq 0 ] && [ "$OUT" = "$(printf 'AB-7\ttkt-7\tqueued')" ] && ok \
  || bad "an unresolvable KEY prefix must still emit the queued lines (rc=$RC out=$OUT)"
# an issue list that comes back empty is the same story
OUT=$(GH_EMPTY=1 "$T/bin/preplan-candidates.sh" proj 2>/dev/null); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "$(printf 'AB-7\ttkt-7\tqueued')" ] && ok \
  || bad "an empty issue list must still emit the queued lines (rc=$RC out=$OUT)"

# ---- the in-app board lane is byte-identical to what it always was ---------
# No hotfix class there (the label lives on a GitHub issue), so the queued lines
# go out exactly where they always did — and with no token stub the lane leaves
# straight after, which is the path that would swallow them if the buffer were
# never flushed.
printf 'TK-3 i3 — a board ticket project=bproj\n' > "$T/logs/READY-QUEUE.log"
OUT=$("$T/bin/preplan-candidates.sh" bproj 2>/dev/null); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "$(printf 'TK-3\ti3\tqueued')" ] && ok \
  || bad "a board-prefix project must still print its queued lines (rc=$RC out=$OUT)"
: > "$T/logs/READY-QUEUE.log"
OUT=$("$T/bin/preplan-candidates.sh" bproj 2>/dev/null); RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok \
  || bad "a board-prefix project with an empty queue must print nothing (rc=$RC out=$OUT)"

echo "hotfix-dispatch-order: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
