#!/bin/bash
# tests/blocked-resolver.bh-1047-test.sh — BH-1047: the adjudication of a
# contract-first child runs, and says which cases it is ruling on.
#
# Five project-4 fillers sat REVIEW_BLOCKED test-tamper for a day or two each and
# were ruled on by hand. Three things have to be true for that to stop:
#
#   1. a record whose report says CONTRACT_CHILD: is offered after the 90-minute
#      floor the other lanes own, not after the 6-hour rescue backstop — the
#      rescue lane cannot help a record whose scan is correct about the diff;
#   2. the ruling that gets posted NAMES the deleted cases, so a reader can
#      check it without opening the box;
#   3. an adjudication that produces no verdict pages a person with that list,
#      once, instead of parking silently — which is what the ticket calls the
#      rung that "cannot decide".
#
# The real bin/blocked-resolver.sh is driven end to end; gh, agent-call and
# lane-alert are RECORDED, never stubbed silent, because "it went quiet instead
# of paging" is exactly the failure this pins.
# Run from anywhere: tests/blocked-resolver.bh-1047-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$T/fakebin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$DIR/bin/merge-sweep.sh" "$DIR/bin/merge-conductor.sh" \
   "$DIR/bin/fly-pool.sh" "$H/bin/"
# BH-1176: the lane sources bin/lib/br/ and REFUSES the tick when a module is
# missing, so the modules travel with the copy. One helper, one edit when the
# split moves again.
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/rebuild-ledger.sh" "$H/bin/lib/"
# bin/blocked-resolver.sh now REQUIRES the REST contract (#783): without it the
# lane refuses to start rather than deciding on undefined reads.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
# BH-680 (#929): merge-conductor-lib.sh is a shim that sources bin/lib/mc/*.sh and
# exits on a missing module — the fixture must carry the modules too.
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
chmod +x "$H/bin/"*.sh
printf 'tproj o/tproj - - 2 box-tproj 100.0.0.9\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
# BH-1510.1: the resolver's models are model_routes rows; this worker-less box carries the resolver's cache of #1507's table.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
: > "$H/env/global.env"
for f in beat.sh run-build.sh deploy-request.sh checks-run.sh pool-cap.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
# The adjudicator writes its answer to its OUT file ($5), exactly as
# bin/agent-call.sh does. The answer for this run is whatever is in adj-answer;
# an EMPTY file is the dead-session case the no-verdict arm exists for.
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/agent-call.txt"
cat "$T/adj-answer" > "\$5" 2>/dev/null || true
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alert.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
case "\$*" in
  # bin/blocked-resolver.sh reads, comments and closes over REST (#783): the
  # gh-api-dash-i envelope is answered once, in tests/lib/gh-rest-stub.sh, which
  # records the POST route in \$T/comments.txt and the body — which never reaches
  # argv — in \$T/comment-bodies.txt.
  *"-i -X "*) GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"pr list"*"--state merged"*) cat "$T/mergedprs" 2>/dev/null ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
: > "$T/mergedprs"; : > "$T/comments.txt"; : > "$T/comment-bodies.txt"; : > "$T/closed.txt"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/br-ssh"; chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
export GH_TOKEN=""

RLOG="$H/logs/blocked-resolver.log"
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH="$T/fakebin/br-ssh" \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$RLOG" 2>&1 ) || true; }

# The report a post-BH-1047 scanner writes for a contract-first filler whose
# stub deletion it could NOT pair (so the build really was blocked).
REPORT='TAMPER_COUNT: 2 (deleted_files=0 deleted_cases=2 added_skips=0 stub_flips=0)
BLOCKING_COUNT: 2 (deletions only)
ASSERTION_DELTA: -2 (added=0 removed=2) — reported, not gated
REWORDED_CASES: 0 (case openers removed and re-added in the same file)
CONTRACT_CHILD: TK-1531.1 (parent TK-1531, key TK-9)
DELETED_CASES:
  tests/chan.test.ts: it("is a stub that cancels nothing yet"
  tests/chan.test.ts: it("is a stub that lists nothing yet"
STUB_FLIPS: 0
stub-flip-unpaired: tests/chan.test.ts: it("is a stub that cancels nothing yet" (no added case in a test file importing: src/chan)
JUSTIFICATION: NONE — no TEST-CHANGE: block in plan.md or any commit message in range'

# REC <minutes-old> <report-or-empty> [reason] — the blocked build record on the
# hub. The reason defaults to test-tamper; the other REVIEW_BLOCKED reasons are
# here because the scanner writes CONTRACT_CHILD: into the report of EVERY `.N`
# child, clean or not, so a contract child parked on another gate has that line
# in its record without having lost a single test case.
REC() {
  local d="$H/builds/pool-tproj-TK-9-202609190000"
  scratch_rm "$d"; mkdir -p "$d"
  printf 'REVIEW_BLOCKED %s: 2 test cases removed, see %s/test-tamper.txt\n' "${3:-test-tamper}" "$d" > "$d/RESULT"
  printf 'the plan this build executed\n' > "$d/plan.md"
  [ -n "$2" ] && printf '%s\n' "$2" > "$d/test-tamper.txt"
  touch -d "@$(( $(date -u +%s) - $1 * 60 ))" "$d/RESULT"
  printf '%s' "$d"
}
RESET() { : > "$RLOG"; : > "$T/gh.txt"; : > "$T/comments.txt"; : > "$T/comment-bodies.txt"
          : > "$T/closed.txt"; : > "$T/lane-alert.txt"
          : > "$T/agent-call.txt"; : > "$H/logs/ALERTS.log"; : > "$H/logs/blocked-resolver.log"
          scratch_rm "$H/state/blocked-resolver"; : > "$T/adj-answer"; }

# ============================================================================
# 1. THE FLOOR. A contract child is offered after 90 minutes, not after six
#    hours: bin/review-rescue.sh re-runs the same scanner, which will reach the
#    same answer, so waiting out its window buys nothing but a day of delay.
# ============================================================================
RESET; REC 100 "$REPORT" >/dev/null
printf 'ACCEPT\n' > "$T/adj-answer"
RUN
grep -q -- '-> adjudicate' "$RLOG" && ok \
  || bad "a 100-minute-old CONTRACT_CHILD record must reach the adjudicate rung: $(cat "$RLOG")"

# ...and a record with no such line keeps the 6-hour rescue floor it has today.
RESET; REC 100 "$(grep -v '^CONTRACT_CHILD:' <<<"$REPORT")" >/dev/null
printf 'ACCEPT\n' > "$T/adj-answer"
RUN
grep -q -- '-> adjudicate' "$RLOG" \
  && bad "a plain test-tamper record must still wait out the 6-hour floor: $(cat "$RLOG")" || ok

# ...and the 90-minute floor itself is untouched: nothing is offered before it.
RESET; REC 30 "$REPORT" >/dev/null
RUN
grep -q -- '-> adjudicate' "$RLOG" \
  && bad "the 90-minute floor that pr-url-reconcile owns must still hold: $(cat "$RLOG")" || ok

# ...and the skip is for TAMPER blocks only. A contract child parked on the
# reproduction gate carries the very same CONTRACT_CHILD: line in its report
# (the scanner writes it on every `.N` child's scan, clean or not) and has lost
# no test case at all, so review-rescue can still help it and it keeps the
# 6-hour backstop.
RESET; REC 100 "$REPORT" reproduction-gate >/dev/null
printf 'ACCEPT\n' > "$T/adj-answer"
RUN
grep -q 'build/reproduction-gate' "$RLOG" \
  && bad "a reproduction-gate record must keep its 6-hour floor: $(cat "$RLOG")" || ok
# ...and the same record past six hours IS offered, so the check above is not
# passing for the wrong reason.
RESET; REC 400 "$REPORT" reproduction-gate >/dev/null
printf 'ACCEPT\n' > "$T/adj-answer"
RUN
grep -q 'build/reproduction-gate' "$RLOG" && ok \
  || bad "a 400-minute-old reproduction-gate record must still be offered: $(cat "$RLOG")"

# ...and a record review-rescue has already finished with is offered as before.
RESET; D=$(REC 100 "$(grep -v '^CONTRACT_CHILD:' <<<"$REPORT")"); touch "$D/.review-rescued"
printf 'ACCEPT\n' > "$T/adj-answer"
RUN
grep -q -- '-> adjudicate' "$RLOG" && ok \
  || bad ".review-rescued must still open the gate for a plain record: $(cat "$RLOG")"

# ============================================================================
# 2. THE RULING NAMES THE CASES. A verdict a reader cannot check is the same
#    park in different words.
# ============================================================================
RESET; REC 100 "$REPORT" >/dev/null
printf 'The stubs were flipped into tests/chan.impl.test.ts.\nACCEPT\n' > "$T/adj-answer"
RUN
grep -q 'repos/o/tproj/issues/9/comments' "$T/comments.txt" && ok \
  || bad "the ruling must be posted on the ticket: $(cat "$T/comments.txt")"
grep -q 'Deleted cases under adjudication:' "$T/comment-bodies.txt" && ok \
  || bad "the comment must introduce the case list: $(cat "$T/comment-bodies.txt")"
grep -q 'is a stub that cancels nothing yet' "$T/comment-bodies.txt" && ok \
  || bad "the comment must carry the case text itself: $(cat "$T/comment-bodies.txt")"
grep -q 'is a stub that lists nothing yet' "$T/comment-bodies.txt" && ok \
  || bad "the comment must carry EVERY named case, not the first: $(cat "$T/comment-bodies.txt")"
# The adjudicator is briefed with the same list — it cannot rule on names it
# was never shown.
grep -q 'Deleted cases under adjudication:' "$T/agent-call.txt" && ok \
  || bad "the adjudication prompt must carry the case list: $(head -c 400 "$T/agent-call.txt")"

# A pre-BH-1047 report has no DELETED_CASES block. The comment says so rather
# than rendering an empty heading (D13).
RESET; REC 100 "$(grep -v '^  tests/' <<<"$REPORT" | grep -v '^DELETED_CASES:')" >/dev/null
printf 'ACCEPT\n' > "$T/adj-answer"
RUN
grep -q 'the scanner named no cases' "$T/comment-bodies.txt" && ok \
  || bad "a report with no case list must say so: $(cat "$T/comment-bodies.txt")"
grep -q 'is a stub that cancels nothing yet' "$T/comment-bodies.txt" \
  && bad "a report with no case list must not invent one: $(cat "$T/comment-bodies.txt")" || ok

# ============================================================================
# 3. NO VERDICT PAGES A PERSON, ONCE, WITH THE LIST.
# ============================================================================
RESET; D=$(REC 100 "$REPORT")
: > "$T/adj-answer"            # the adjudicator answered nothing at all
RUN
RUN
[ "$(grep -c 'is a stub that cancels nothing yet' "$T/lane-alert.txt")" = 1 ] && ok \
  || bad "a no-verdict adjudication must page exactly once with the case list (got $(cat "$T/lane-alert.txt"))"
grep -q 'A human must rule on these deleted cases' "$T/lane-alert.txt" && ok \
  || bad "the page must say what is being asked of the person: $(cat "$T/lane-alert.txt")"
[ "$(wc -l < "$T/lane-alert.txt")" = 1 ] && ok \
  || bad "the page is ONE actionable line, not a paste of the report: $(cat "$T/lane-alert.txt")"
[ -f "$D/.adjudicate-noverdict-paged" ] && ok || bad "the page must leave its own marker on the record"
[ "$(jq -r '.counters.adjudications // 0' "$H/state/blocked-resolver/tproj/tproj-TK-9.json" 2>/dev/null)" = 0 ] && ok \
  || bad "silence must not spend the adjudication counter (got $(jq -c '.counters' "$H/state/blocked-resolver/tproj/tproj-TK-9.json" 2>/dev/null))"

# The page belongs to the reasons that ARE a tamper block, and rescue-real-
# deletion is one: bin/review-rescue.sh re-scanned, found a real deletion, and
# its rescan report is where the names come from. So it pages like the original
# block does.
RESET; D=$(REC 100 "$REPORT"); printf '%s\n' "$REPORT" > "$D/test-tamper-rescan.txt"
: > "$T/adj-answer"
RUN
grep -q 'build/rescue-real-deletion' "$RLOG" && ok \
  || bad "the fixture must actually be a rescue-real-deletion record: $(cat "$RLOG")"
grep -q 'is a stub that cancels nothing yet' "$T/lane-alert.txt" && ok \
  || bad "a rescan that found a real deletion must page with the list too: $(cat "$T/lane-alert.txt")"

# A record with no CONTRACT_CHILD line is the old shape and is NOT paged: this
# alert is for the contract-first class the ticket is about, not for every
# quiet adjudication in the fleet.
RESET; D=$(REC 400 "$(grep -v '^CONTRACT_CHILD:' <<<"$REPORT")")
: > "$T/adj-answer"
RUN
grep -q -- '-> adjudicate' "$RLOG" && ok \
  || bad "a 400-minute-old plain record must still reach adjudicate: $(cat "$RLOG")"
[ -s "$T/lane-alert.txt" ] \
  && bad "a plain no-verdict adjudication must not page: $(cat "$T/lane-alert.txt")" || ok

echo "blocked-resolver.bh-1047-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
