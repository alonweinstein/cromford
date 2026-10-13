#!/bin/bash
# tests/blocked-resolver-ci-repair-cap-test.sh — Lane D (2026-09-24): a red CI
# gets at most BR_CI_REPAIR_ROUNDS (default 2) repair rounds per PR head
# lineage; the next red park is PARKED with one decision request instead of a
# third round or a rebuild (bin/lib/br/opt/cirepair.sh, hook
# br_opt_ci_cap_rung in br_one).
#
# Drives the REAL bin/blocked-resolver.sh against the shared scratch fixture
# (tests/lib/fixture-harness.sh) with the real module installed, and asserts on
# what the run did: comments posted, PRs closed, builds enqueued, the `-> rung`
# dispatch lines, the record's outcome and ALERTS.log.
#
#   CR-1 two pushed repair rounds, red again: parked — one PR comment, outcome
#        CI_PARKED, one ALERTS line, no rung dispatched, nothing closed/enqueued
#   CR-2 the same park on the next tick: terminal, no second comment, no rung
#   CR-3 one round so far: the lane's own ladder runs, no park
#   CR-4 rounds from BEFORE the last rebuild-fresh do not count (new lineage)
#   CR-5 a round that pushed nothing (regen-noop, fix round without a commit)
#        does not count
#   CR-6 BR_CI_REPAIR_ROUNDS=0 is the old ladder; BR_OPT_OFF=cirepair too
#   CR-7 a non-CI park with two rounds is not this module's
#   CR-8 the knob is registered on the blocked-resolver lane, default 2
#   CR-9 the lineage is the PR: another PR of the same ticket starts at zero
#   CR-10 only rounds that pushed a sha count (not a CI re-run, not a pool queue)
#   CR-11 the comment lists this lineage only
#   CR-12 a comment refused three times is capped: parked anyway, beat says so
# Run from anywhere: tests/blocked-resolver-ci-repair-cap-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq  >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -r "$DIR/bin/lib/br/opt/cirepair.sh" ] || { echo "FAIL: bin/lib/br/opt/cirepair.sh does not exist"; exit 1; }

# The pipeline as one text (CR-20/CR-21 read bin/run-build.sh's carried-note block).
# shellcheck source=tests/lib/rb-all.sh
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
# Clear the TK-9 pool build dirs through scratch_rm, which proves each path
# lives under $T at run time (checks/tests-scratch-only R2).
RM_POOL() { local p; for p in "$H/builds/pool-tproj-TK-9-"*; do [ -e "$p" ] && scratch_rm "$p"; done; return 0; }
mkdir -p "$H/bin"
# The scripts this suite drives. The copy stays HERE, in the suite's own text,
# so bin/test-impact.sh selects this suite when one of them changes.
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
fx_br_harness "$DIR" "$T" || exit 1
mkdir -p "$H/bin/lib/br/opt" && cp "$DIR/bin/lib/br/opt/cirepair.sh" "$H/bin/lib/br/opt/" || exit 1
cat > "$H/bin/lib/hold.sh" <<'EOF'
hold_check() { printf 'clear\tno hold on this ticket\n'; return 0; }
hold_check_thread() { printf 'clear\tno-hold\n'; return 0; }
hold_is_pause()   { return 1; }
hold_is_abandon() { return 1; }
EOF
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
touch "$H/flags/fly-pool-tproj"

LOGF="$H/logs/blocked-resolver.log"
URL="https://github.com/o/tproj/pull/9"
REDWHY="red-twice: still red on aaaaaaaa after its failed jobs were re-run once"
# SEED <attempts-json-array> — the TK-9 record with this history, already
# stamped to THIS PR's lineage from attempt 0 (a record the module has seen).
# TEST-CHANGE (review round 2 of #2222): SEED used to write an UNSTAMPED record,
# and an unstamped record now counts only attempts whose own `url` is this PR
# (CR-13), so the cases that assert on counting, pushed-only and the lineage cut
# seed the stamp they were implicitly relying on. What each asserts is unchanged.
# SEED_UNSTAMPED is the rollout shape: no stamp at all.
SEED_UNSTAMPED() {
  mkdir -p "$H/state/blocked-resolver/tproj"
  jq -nc --argjson a "$1" '{project:"tproj",rkey:"tproj-TK-9",mechanicals:1,fixrounds:0,regens:1,rebuilds:0,outcome:"",attempts:$a}' \
    > "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
}
SEED() {
  SEED_UNSTAMPED "$1"
  jq -c --arg u "$URL" '.ci_lineage_url = $u | .ci_lineage_from = "0"' "$H/state/blocked-resolver/tproj/tproj-TK-9.json" > "$T/rec.json" \
    && mv "$T/rec.json" "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
}
A() { jq -nc --arg a "$1" --arg r "$2" --arg d "$3" '{at:"2026-09-24 10:00:00Z",action:$a,reason:$r,detail:$d}'; }
# AU <action> <reason> <detail> <url> — an attempt that records its PR (fix rounds do).
AU() { jq -nc --arg a "$1" --arg r "$2" --arg d "$3" --arg u "$4" '{at:"2026-09-24 10:00:00Z",action:$a,reason:$r,detail:$d,url:$u}'; }
# The details are the lane's own sentences (bin/blocked-resolver.sh br_record
# call sites): a round that PUSHED names the sha it pushed.
MECH_PUSHED="merged origin/main into ticket/TK-9 and pushed bbbbbbbb (mc_rebase rc=0)"
REGEN_PUSHED="regenerated ticket/TK-9: pushed cccccccc over head8=bbbbbbbb (mc_rebase rc=0)"
TWO_ROUNDS="[$(A mechanical "$REDWHY" "$MECH_PUSHED"),$(A regen "$REDWHY" "$REGEN_PUSHED")]"
# beat.sh RECORDS here: CI_PARKED is an UNTRIAGED severity-warn beat, which the
# real beat.sh spools for the warn digest (no page, no LLM).
# TEST-CHANGE (review round 2 of #2222): CR-1 asserted triaged:true. A triaged
# beat skips beat.sh's severity routing and pages, which is the bug; the
# assertion now pins the opposite.
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/beats.txt"\nexit 0\n' "$T" > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
PARKBEATS() { grep -c 'CI_PARKED' "$T/beats.txt" 2>/dev/null || true; }
FRESH() {
  scratch_rm "$H/state/blocked-resolver"
  : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/comment-bodies.txt"; : > "$T/comments.txt"; : > "$LOGF"
  : > "$T/lane-alert.txt"; rm -f "$H/logs/ALERTS.log" "$T/st-comment"; : > "$T/beats.txt"
  scratch_rm "$H/state/merge-conductor/handoff"
  scratch_rm "$H/state/merge-conductor/handoff-released"
  printf 'ticket/TK-9' > "$T/prbranch"; printf 'TK-9: a thing' > "$T/prtitle"
  # TEST-CHANGE (review of #2222, the supersede guard): the PR's head is the one
  # the harness's last repair round pushed (REGEN_PUSHED "pushed cccccccc"), as
  # it is in production when a park fires. The fixture default (aaaa…) is a
  # head no recorded round pushed, which CR-26b now pins as NOT harness-authored.
  printf 'cccccccccccccccccccccccccccccccccccccccc' > "$T/prhead"
  echo OPEN > "$T/prstate"
  ROWST "o/tproj#9" RED_TWICE "$REDWHY" "$URL"
}
NCOMMENTS() { grep -c "issues/9/comments" "$T/comments.txt" 2>/dev/null || true; }
RUNG() { grep -oE '\-> (mechanical|regen|fix-round|rebuild-fresh|rebuild-retry|abandon-rebuild)' "$LOGF" 2>/dev/null | head -1; }
OUTCOME() { STATEJSON tproj-TK-9 | jq -r '.outcome // ""'; }
BRENV=(BR_SUPERSEDE_SETTLE_SECS=0 BR_SUPERSEDE_DECLINE_ALERT_SECS=3600)

# CR-1
FRESH; SEED "$TWO_ROUNDS"; RUN
[ "$(NCOMMENTS)" = 1 ] && ok || bad "CR-1 one park comment on the PR (comments: $(cat "$T/comments.txt"); log: $(tail -5 "$LOGF"))"
grep -q "after 2 repair round(s) that each pushed a new commit, and 2 is the cap" "$T/comment-bodies.txt" && ok || bad "CR-1 the comment names the rounds and the cap (bodies: $(head -c 400 "$T/comment-bodies.txt"))"
[ "$(OUTCOME)" = CI_PARKED ] && ok || bad "CR-1 outcome CI_PARKED (record: $(STATEJSON tproj-TK-9))"
[ "$(PARKBEATS)" = 1 ] && grep 'CI_PARKED' "$T/beats.txt" | jq -e '(has("triaged") | not) and .severity == "warn"' >/dev/null \
  && ok || bad "CR-1 one untriaged warn beat for the digest, never triaged:true (beats: $(cat "$T/beats.txt"))"
grep -q "CI_PARKED" "$H/logs/ALERTS.log" 2>/dev/null && bad "CR-1 CI_PARKED is not an ALERTS.log line (the LLM triage spool reads that file)" || ok
[ -z "$(RUNG)" ] && ok || bad "CR-1 no further rung may be dispatched (got '$(RUNG)')"
[ -s "$T/closed.txt" ] && bad "CR-1 nothing closed ($(cat "$T/closed.txt"))" || ok
# TEST-CHANGE (policy, the operator 2026-09-24 "park, then auto re-plan"): CR-1 used to
# assert that NOTHING was enqueued. The park now enqueues exactly one narrower
# re-plan of the ticket (CR-17 pins its shape); the old PR is still not closed.
[ "$(grep -c '^tproj TK-9 ' "$T/queue.txt")" = 1 ] && ok || bad "CR-1 exactly one re-plan enqueued ($(cat "$T/queue.txt"))"
# CR-2
: > "$T/comments.txt"; : > "$LOGF"; RUN
[ "$(NCOMMENTS)" = 0 ] && ok || bad "CR-2 a parked PR is not commented twice (comments: $(cat "$T/comments.txt"))"
[ -z "$(RUNG)" ] && ok || bad "CR-2 no rung on an already-parked PR (got '$(RUNG)')"
[ "$(PARKBEATS)" = 1 ] && ok || bad "CR-2 still exactly one beat (beats: $(cat "$T/beats.txt"))"
# CR-3
FRESH; SEED "[$(A mechanical "$REDWHY" "$MECH_PUSHED")]"; RUN
[ "$(OUTCOME)" != CI_PARKED ] && [ "$(NCOMMENTS)" = 0 ] && ok || bad "CR-3 one round is under the cap: no park (outcome $(OUTCOME))"
[ -n "$(RUNG)" ] && ok || bad "CR-3 the lane's own ladder runs (log: $(tail -4 "$LOGF"))"
# CR-4
FRESH; SEED "[$(A mechanical "$REDWHY" "$MECH_PUSHED"),$(A regen "$REDWHY" "$REGEN_PUSHED"),$(A rebuild-fresh "$REDWHY" "fresh build enqueued against current main")]"; RUN
[ "$(OUTCOME)" != CI_PARKED ] && ok || bad "CR-4 rounds before the last rebuild-fresh belong to the old lineage"
# CR-5
FRESH; SEED "[$(A mechanical "$REDWHY" "$MECH_PUSHED"),$(A regen-noop "$REDWHY" "nothing to merge"),$(A fix-round "$REDWHY" "agent rc=1, verify rc=1 — no verified commit")]"; RUN
[ "$(OUTCOME)" != CI_PARKED ] && ok || bad "CR-5 rounds that pushed nothing do not count"
FRESH; SEED "[$(A mechanical "$REDWHY" "$MECH_PUSHED"),$(A fix-round "$REDWHY" "pushed 1234abc to ticket/TK-9, typecheck+unit green")]"; RUN
[ "$(OUTCOME)" = CI_PARKED ] && ok || bad "CR-5 a fix round that pushed DOES count (record: $(STATEJSON tproj-TK-9))"
# CR-6
FRESH; SEED "$TWO_ROUNDS"; BRENV+=(BR_CI_REPAIR_ROUNDS=0); RUN; BRENV=("${BRENV[@]:0:2}")
[ "$(OUTCOME)" != CI_PARKED ] && [ -n "$(RUNG)" ] && ok || bad "CR-6 BR_CI_REPAIR_ROUNDS=0 is the old ladder (outcome $(OUTCOME), rung '$(RUNG)')"
FRESH; SEED "$TWO_ROUNDS"; BRENV+=(BR_OPT_OFF=cirepair); RUN; BRENV=("${BRENV[@]:0:2}")
[ "$(OUTCOME)" != CI_PARKED ] && ok || bad "CR-6 BR_OPT_OFF=cirepair turns the module off"
# CR-7
FRESH; SEED "[$(A mechanical "conflict-unresolvable: x" "$MECH_PUSHED"),$(A regen "conflict-unresolvable: x" "$REGEN_PUSHED")]"
ROWST "o/tproj#9" BLOCKED_HUMAN "conflict-unresolvable: CONFLICT (content): Merge conflict in src/a.ts" "$URL"; RUN
[ "$(OUTCOME)" != CI_PARKED ] && ok || bad "CR-7 a conflict park is not the CI cap's"
# CR-8
[ "$(jq -r '.knobs[] | select(.env=="BR_CI_REPAIR_ROUNDS") | .default' "$DIR/catalog/lanes.d/blocked-resolver.json")" = 2 ] \
  && ok || bad "CR-8 BR_CI_REPAIR_ROUNDS registered on the blocked-resolver lane with default 2"

# CR-9 THE LINEAGE IS THIS PR (review of #2222, nit 1). The record is the
# ticket's; a new PR for the same ticket opened any way but rebuild-fresh (by
# hand, a retry) must not inherit the old PR's rounds. The module stamps the PR
# it counted for; a different PR starts from zero.
FRESH; SEED "$TWO_ROUNDS"
jq -c '.ci_lineage_url = "https://github.com/o/tproj/pull/8" | .ci_lineage_from = "0"' "$H/state/blocked-resolver/tproj/tproj-TK-9.json" > "$T/rec.json" \
  && mv "$T/rec.json" "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
RUN
[ "$(OUTCOME)" != CI_PARKED ] && [ "$(NCOMMENTS)" = 0 ] && ok || bad "CR-9 rounds spent on PR #8 do not park PR #9 (outcome $(OUTCOME))"
[ "$(STATEJSON tproj-TK-9 | jq -r .ci_lineage_url)" = "$URL" ] && ok || bad "CR-9 the lineage is now stamped to #9 (record: $(STATEJSON tproj-TK-9))"
# CR-10 ONLY ROUNDS THAT PUSHED (nit 2): a mechanical rung that re-ran CI or
# queued a pool rebase pushed nothing the lane saw.
FRESH; SEED "[$(A mechanical "$REDWHY" "nothing to merge from main; re-ran the failed CI runs on aaaaaaaa"),$(A mechanical "$REDWHY" "queued a pool rebase of ticket/TK-9 at aaaaaaaa (k); the conductor reads the pool's result"),$(A regen "$REDWHY" "$REGEN_PUSHED")]"; RUN
[ "$(OUTCOME)" != CI_PARKED ] && ok || bad "CR-10 a CI re-run and a queued pool rebase are not pushed rounds (outcome $(OUTCOME))"
# CR-11 the comment lists THIS lineage only (nit 3)
FRESH; SEED "[$(A mechanical "$REDWHY" "an OLD-LINEAGE round, pushed dddddddd"),$(A rebuild-fresh "$REDWHY" "fresh build enqueued against current main"),$(A mechanical "$REDWHY" "$MECH_PUSHED"),$(A regen "$REDWHY" "$REGEN_PUSHED")]"; RUN
[ "$(OUTCOME)" = CI_PARKED ] && grep -q "pushed cccccccc" "$T/comment-bodies.txt" && ! grep -q "OLD-LINEAGE" "$T/comment-bodies.txt" \
  && ok || bad "CR-11 the park comment lists this lineage's rounds only (bodies: $(head -c 600 "$T/comment-bodies.txt"))"
# CR-12 A COMMENT REFUSED FOR EVER IS CAPPED (nit 3): three refused posts, then
# the park is recorded anyway and says the PR could not be told.
FRESH; SEED "$TWO_ROUNDS"; echo 500 > "$T/st-comment"
RUN; [ "$(OUTCOME)" != CI_PARKED ] && ok || bad "CR-12 a refused comment records nothing on the first try"
RUN; RUN
[ "$(OUTCOME)" = CI_PARKED ] && ok || bad "CR-12 after three refused comments the park is recorded (record: $(STATEJSON tproj-TK-9))"
grep 'CI_PARKED' "$T/beats.txt" | grep -q "could not be commented" && ok || bad "CR-12 the beat says the PR was not told (beats: $(cat "$T/beats.txt"))"
: > "$T/comments.txt"; RUN
[ "$(NCOMMENTS)" = 0 ] && ok || bad "CR-12 no fourth post after the cap"
rm -f "$T/st-comment"

# CR-13 ROLLOUT: AN UNSTAMPED RECORD COUNTS ONLY ATTEMPTS OF THIS PR (review
# round 2 of #2222). The record is the ticket's and an old record carries no
# lineage stamp, so two pushed rounds an EARLIER PR of the ticket ran (opened
# again by hand or a retry, no rebuild-fresh between) must not park this PR on
# the first tick the module sees it. Only attempts whose own `url` is this PR
# count; once stamped, the lineage starts after what was already there.
PR8="https://github.com/o/tproj/pull/8"
FRESH; SEED_UNSTAMPED "[$(A mechanical "$REDWHY" "$MECH_PUSHED"),$(A regen "$REDWHY" "$REGEN_PUSHED"),$(AU fix-round "$REDWHY" "pushed 1234abc to ticket/TK-8, typecheck+unit green" "$PR8")]"; RUN
[ "$(OUTCOME)" != CI_PARKED ] && [ "$(NCOMMENTS)" = 0 ] && ok || bad "CR-13 an unstamped record's rounds of another PR do not park this one at rollout (outcome $(OUTCOME); record: $(STATEJSON tproj-TK-9))"
[ "$(STATEJSON tproj-TK-9 | jq -r .ci_lineage_url)" = "$URL" ] && [ "$(STATEJSON tproj-TK-9 | jq -r .ci_lineage_from)" = 3 ] \
  && ok || bad "CR-13 the first sight stamps this PR's lineage after the old attempts (record: $(STATEJSON tproj-TK-9))"
: > "$LOGF"; : > "$T/comments.txt"; RUN
[ "$(OUTCOME)" != CI_PARKED ] && [ "$(NCOMMENTS)" = 0 ] && ok || bad "CR-13 and the second tick does not park on them either (outcome $(OUTCOME))"
# CR-13b an unstamped record whose pushed rounds carry THIS PR's url still parks
FRESH; SEED_UNSTAMPED "[$(AU fix-round "$REDWHY" "pushed 1234abc to ticket/TK-9, typecheck+unit green" "$URL"),$(AU fix-round "$REDWHY" "pushed 5678def to ticket/TK-9, typecheck+unit green" "$URL")]"; RUN
[ "$(OUTCOME)" = CI_PARKED ] && ok || bad "CR-13b two pushed rounds recorded against this PR park it on an unstamped record (record: $(STATEJSON tproj-TK-9))"
# CR-13c a fix round's attempt records its PR url (the field CR-13 reads)
FRESH; SEED_UNSTAMPED "[]"
( ST="$H/state/blocked-resolver"; STAMP() { echo T; }; . "$DIR/bin/lib/br/record.sh"
  br_record tproj tproj-TK-9 fix-round "$REDWHY" "pushed 1234abc to ticket/TK-9" fixrounds "$URL" aaaaaaaa
  br_record tproj tproj-TK-9 mechanical "$REDWHY" "no url given" mechanicals )
[ "$(STATEJSON tproj-TK-9 | jq -r '.attempts[0].url // ""')" = "$URL" ] && [ "$(STATEJSON tproj-TK-9 | jq -r '.attempts[1] | has("url")')" = false ] \
  && ok || bad "CR-13c br_record stores the PR url on the attempt when given, and only then (record: $(STATEJSON tproj-TK-9))"

# CR-14 A POSTED PARK WHOSE OUTCOME WRITE FAILED IS NOT COMMENTED AGAIN (lead
# MEDIUM 3 on #2222). The comment went out before br_set_outcome; a failed write
# left nothing to stop the next tick commenting again, every tick. A pending
# marker (ci_park_pending=<rkey>) is written BEFORE the post; a tick that finds
# it retries only the outcome write. Seeded here as "the last tick posted and
# its outcome write failed".
FRESH; SEED "$TWO_ROUNDS"
jq -c '.ci_park_pending = "o-tproj-9"' "$H/state/blocked-resolver/tproj/tproj-TK-9.json" > "$T/rec.json" \
  && mv "$T/rec.json" "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
RUN
[ "$(NCOMMENTS)" = 0 ] && ok || bad "CR-14 a pending park is not commented again (comments: $(cat "$T/comments.txt"))"
[ "$(OUTCOME)" = CI_PARKED ] && ok || bad "CR-14 the pending park's outcome is written this tick (record: $(STATEJSON tproj-TK-9))"
case "$(STATEJSON tproj-TK-9 | jq -r '.ci_park_pending // ""')" in ''|-) ok ;; *) bad "CR-14 the pending marker is cleared once the outcome is written" ;; esac
# ...and a fresh park leaves no marker behind
FRESH; SEED "$TWO_ROUNDS"; RUN
[ "$(OUTCOME)" = CI_PARKED ] && case "$(STATEJSON tproj-TK-9 | jq -r '.ci_park_pending // ""')" in ''|-) true ;; *) false ;; esac && ok \
  || bad "CR-14 a completed park clears its pending marker (record: $(STATEJSON tproj-TK-9))"
# CR-15 RAISING THE CAP RELEASES A PARKED PR (lead LOW 4 on #2222). The terminal
# check returned 3 before comparing the rounds to the cap, so 2 -> 3 left every
# parked PR stuck. Now a park whose rounds are under the current cap is lifted
# and the lane's own ladder runs; no second comment.
FRESH; SEED "$TWO_ROUNDS"; RUN
[ "$(OUTCOME)" = CI_PARKED ] || bad "CR-15 setup: parked at cap 2"
: > "$T/comments.txt"; : > "$LOGF"
BRENV+=(BR_CI_REPAIR_ROUNDS=3); RUN; BRENV=("${BRENV[@]:0:2}")
[ "$(OUTCOME)" != CI_PARKED ] && ok || bad "CR-15 a cap raised above the rounds lifts the park (record: $(STATEJSON tproj-TK-9))"
[ -n "$(RUNG)" ] && ok || bad "CR-15 the lane's own ladder runs once the park is lifted (log: $(tail -4 "$LOGF"))"
[ "$(NCOMMENTS)" = 0 ] && ok || bad "CR-15 lifting a park posts nothing (comments: $(cat "$T/comments.txt"))"
# CR-16 THE PARK NAMES ITS WAY OUT (lead LOW 5 on #2222): the record path, the
# edit that re-offers it, and the knob.
FRESH; SEED "$TWO_ROUNDS"; RUN
grep 'CI_PARKED' "$T/beats.txt" | grep -q 'state/blocked-resolver/tproj/tproj-TK-9.json' \
  && grep 'CI_PARKED' "$T/beats.txt" | grep -q 'set .outcome to \\"\\"' \
  && grep 'CI_PARKED' "$T/beats.txt" | grep -q 'BR_CI_REPAIR_ROUNDS' \
  && ok || bad "CR-16 the park beat names the record, the .outcome edit and the knob (beats: $(cat "$T/beats.txt"))"

# CR-17 PARK, THEN AUTO RE-PLAN (policy, the operator 2026-09-24). CI-repair
# exhaustion is a PARK: the PR stays open, a warn digest note, and the harness
# enqueues ONE narrower re-plan of the ticket with the failing-CI evidence
# carried to the next build's plan stage (state/build-notes/<p>/<key>.md, the
# resolver's existing carried-note channel, KIND: ci-replan). Exactly once:
# later ticks on the parked PR enqueue nothing more.
FRESH; SEED "$TWO_ROUNDS"; RUN; : > "$LOGF"; RUN; RUN
[ "$(grep -c '^tproj TK-9 ' "$T/queue.txt")" = 1 ] && ok || bad "CR-17 the park enqueues exactly one re-plan over three ticks (queue: $(cat "$T/queue.txt"))"
NOTEF="$H/state/build-notes/tproj/TK-9.md"
head -1 "$NOTEF" 2>/dev/null | grep -qx 'KIND: ci-replan' && grep -q "pushed cccccccc" "$NOTEF" && grep -q "$URL" "$NOTEF" \
  && ok || bad "CR-17 the re-plan carries the failing-CI evidence in a KIND: ci-replan note (note: $(cat "$NOTEF" 2>/dev/null | head -c 400))"
[ "$(STATEJSON tproj-TK-9 | jq -r '.ci_replans // 0')" = 1 ] && ok || bad "CR-17 one re-plan counted on the ticket (record: $(STATEJSON tproj-TK-9))"
[ -s "$T/closed.txt" ] && bad "CR-17 the parked PR stays open ($(cat "$T/closed.txt"))" || ok
grep 'CI_PARKED' "$T/beats.txt" | jq -e '(has("triaged") | not) and .severity == "warn"' >/dev/null && grep 'CI_PARKED' "$T/beats.txt" | grep -q 'narrower re-plan enqueued automatically' \
  && ok || bad "CR-17 one warn digest beat that names the re-plan (beats: $(cat "$T/beats.txt"))"
grep -q "narrower re-plan of the ticket automatically" "$T/comment-bodies.txt" && ok || bad "CR-17 the PR comment says the ticket is re-planned automatically (bodies: $(head -c 400 "$T/comment-bodies.txt"))"
# CR-18 A SECOND EXHAUSTION IS ABANDONED (the old rule). The re-plan's own PR
# (#10, a new lineage) runs out of CI rounds too: the ticket already spent its
# one re-plan, so this one is ABANDONED — closed, nothing enqueued.
FRESH; SEED "$TWO_ROUNDS"
# The lineage stamp is #10's from attempt 2, as the module writes it the first
# time it sees #10 (before #10's own rounds were recorded).
jq -c --arg u "https://github.com/o/tproj/pull/10" '.ci_replans = "1" | .outcome = "CI_PARKED" | .ci_parked_rkey = "o-tproj-9" | .ci_parked_url = "https://github.com/o/tproj/pull/9" | .ci_lineage_url = $u | .ci_lineage_from = "2"' \
  "$H/state/blocked-resolver/tproj/tproj-TK-9.json" > "$T/rec.json" && mv "$T/rec.json" "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
URL10="https://github.com/o/tproj/pull/10"
jq -c --argjson a "[$(AU mechanical "$REDWHY" "$MECH_PUSHED" "$URL10"),$(AU regen "$REDWHY" "$REGEN_PUSHED" "$URL10")]" '.attempts += $a' \
  "$H/state/blocked-resolver/tproj/tproj-TK-9.json" > "$T/rec.json" && mv "$T/rec.json" "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
ROWST "o/tproj#10" RED_TWICE "$REDWHY" "$URL10"; printf 'ticket/TK-9-r1' > "$T/prbranch"
RUN
[ "$(OUTCOME)" = ABANDONED ] && ok || bad "CR-18 a second CI exhaustion after the one re-plan is ABANDONED (record: $(STATEJSON tproj-TK-9); log: $(tail -4 "$LOGF"))"
grep -q '^tproj TK-9 ' "$T/queue.txt" && bad "CR-18 no second re-plan ($(cat "$T/queue.txt"))" || ok
grep -q 'pulls/10' "$T/closed.txt" && grep -q 'pulls/9' "$T/closed.txt" && ok \
  || bad "CR-18 the abandoned PR (#10) and the first parked PR (#9) are both closed (closed: $(cat "$T/closed.txt"))"
# CR-19 BR_CI_REPLAN_MAX=0 is the old rule: CI exhaustion is ABANDONED at once.
FRESH; SEED "$TWO_ROUNDS"; BRENV+=(BR_CI_REPLAN_MAX=0); RUN; BRENV=("${BRENV[@]:0:2}")
[ "$(OUTCOME)" = ABANDONED ] && ok || bad "CR-19 BR_CI_REPLAN_MAX=0 abandons at the cap (record: $(STATEJSON tproj-TK-9))"
grep -q '^tproj TK-9 ' "$T/queue.txt" && bad "CR-19 nothing enqueued with re-plan off ($(cat "$T/queue.txt"))" || ok
[ "$(jq -r '.knobs[] | select(.env=="BR_CI_REPLAN_MAX") | .default' "$DIR/catalog/lanes.d/blocked-resolver.json")" = 1 ] \
  && ok || bad "CR-19 BR_CI_REPLAN_MAX registered on the blocked-resolver lane, default 1"
# CR-20 the plan stage reads a KIND: ci-replan note as a NARROWER re-plan brief
# (bin/run-build.sh's carried-note block, extracted verbatim), not as an
# adjudication ruling.
awk '/^# >>> carried note/{f=1;next} /^# <<< carried note/{exit} f' "$RB_ALL" > "$T/cn.sh"
mkdir -p "$T/cnb" "$T/cnh/state/build-notes/tproj"
printf 'KIND: ci-replan\nPR https://x/pull/9 stayed CI-red after 2 rounds.\n' > "$T/cnh/state/build-notes/tproj/TK-9.md"
CNL=$( HARNESS="$T/cnh" BUILD="$T/cnb" PROJECT=tproj KEY=TK-9; STAMP() { echo T; }; . "$T/cn.sh"; printf '%s' "$CARRIED_NOTE_LINE" )
case "$CNL" in *ADJUDICATED*) CNADJ=1 ;; *) CNADJ=0 ;; esac
case "$CNL" in *NARROWER*) [ "$CNADJ" = 0 ] ;; *) false ;; esac && ok \
  || bad "CR-20 a ci-replan note becomes a narrower re-plan brief (line: $(printf '%.300s' "$CNL"))"
# CR-21 a pool build gets the note too: bin/fly-pool.sh relays it beside the
# job (push_build_note, extracted) and bin/run-build.sh reads the relay path.
awk '/^# >>> build-note relay/{f=1;next} /^# <<< build-note relay/{exit} f' "$DIR/bin/fly-pool.sh" > "$T/bn.sh"
if [ -s "$T/bn.sh" ]; then
  mkdir -p "$T/bnh/state/build-notes/tproj"; printf 'KIND: ci-replan\nx\n' > "$T/bnh/state/build-notes/tproj/TK-9.md"
  ( HARNESS="$T/bnh"; P=tproj; say() { :; }; mput() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$T/mput.txt"; cp "$2" "$T/mput-copy"; }
    . "$T/bn.sh"; push_build_note m1 TK-9 )
  grep -q "^m1 .* /run/harness/build-note-tproj-TK-9.md$" "$T/mput.txt" 2>/dev/null && grep -q 'ci-replan' "$T/mput-copy" \
    && [ ! -e "$T/bnh/state/build-notes/tproj/TK-9.md" ] && ok \
    || bad "CR-21 the hub note is relayed to the machine once (mput: $(cat "$T/mput.txt" 2>/dev/null))"
else
  bad "CR-21 bin/fly-pool.sh has no build-note relay block"
fi
grep -q 'build-note-\$PROJECT-\$KEY.md' "$RB_ALL" && ok || bad "CR-21 bin/run-build.sh reads the relayed note"

# CR-23 THE RE-PLAN'S PR SUPERSEDES THE PARKED ONE (the gap closed in this PR).
# Once the automatic re-plan's NEW PR for the ticket exists (its build record's
# RESULT names it), the parked PR is closed with ONE "superseded by #NEW
# (narrower re-plan)" comment through the lane's own close path, its build row
# beat `superseded`, its conductor row CLOSED, and the ticket never has two live
# PRs. Exactly once: later ticks close nothing more.
URL10="https://github.com/o/tproj/pull/10"
newrec() { # newrec — the re-plan's build record, as the pool relays it home
  local d="$H/builds/pool-tproj-TK-9-202609250101"; mkdir -p "$d"
  printf 'PR_CREATED %s\n' "$URL10" > "$d/RESULT"; }
FRESH; RM_POOL; SEED "$TWO_ROUNDS"; RUN
[ "$(OUTCOME)" = CI_PARKED ] || bad "CR-23 setup: parked"
: > "$T/closed.txt"; : > "$T/comment-bodies.txt"; : > "$T/beats.txt"
newrec; RUN
[ "$(grep -c 'pulls/9' "$T/closed.txt")" = 1 ] && ok || bad "CR-23 the parked PR is closed once the re-plan's PR opens (closed: $(cat "$T/closed.txt"); log: $(tail -3 "$LOGF"))"
grep -q "Superseded by #10 (narrower re-plan)" "$T/comment-bodies.txt" "$T/closed.txt" 2>/dev/null && ok \
  || bad "CR-23 the close says 'Superseded by #10 (narrower re-plan)' (bodies: $(head -c 300 "$T/comment-bodies.txt"); closed: $(head -c 300 "$T/closed.txt"))"
grep '"kind":"build"' "$T/beats.txt" | jq -e 'select(.stage == "superseded" and .pr_url == "https://github.com/o/tproj/pull/9")' >/dev/null \
  && ok || bad "CR-23 the parked PR's build row is beat superseded (beats: $(cat "$T/beats.txt"))"
[ "$(OUTCOME)" = CI_SUPERSEDED ] && [ "$(STATEJSON tproj-TK-9 | jq -r .ci_superseded_by)" = "$URL10" ] && ok \
  || bad "CR-23 the park records its successor (record: $(STATEJSON tproj-TK-9))"
: > "$T/closed.txt"; RUN; RUN
[ -s "$T/closed.txt" ] && bad "CR-23 superseded exactly once ($(cat "$T/closed.txt"))" || ok
grep -q 'pulls/10' "$T/closed.txt" && bad "CR-23 the re-plan's PR is never closed" || ok
# CR-24 THE RACE: the re-plan's PR MERGED before this lane saw it, while the
# parked PR is still open. Same answer: the old PR is closed (never merged).
FRESH; RM_POOL; SEED "$TWO_ROUNDS"; RUN
: > "$T/closed.txt"; newrec; printf 'merged-10\n' > "$T/mergedprs"; RUN
[ "$(grep -c 'pulls/9' "$T/closed.txt")" = 1 ] && ok || bad "CR-24 the parked PR is closed when the re-plan's PR already merged (closed: $(cat "$T/closed.txt"))"
grep -qE 'merge.*pull/9|pulls/9/merge' "$T/gh.txt" && bad "CR-24 the parked PR is never merged ($(grep -E 'pull/9|pulls/9' "$T/gh.txt" | tail -3))" || ok
: > "$T/mergedprs"; RM_POOL
# CR-25 knob 0 is unchanged: abandoned at once, no park, so nothing to supersede
FRESH; SEED "$TWO_ROUNDS"; BRENV+=(BR_CI_REPLAN_MAX=0); RUN; BRENV=("${BRENV[@]:0:2}")
[ "$(OUTCOME)" = ABANDONED ] && [ "$(STATEJSON tproj-TK-9 | jq -r '.ci_superseded_by // ""')" = "" ] && ok \
  || bad "CR-25 BR_CI_REPLAN_MAX=0 still abandons at once (record: $(STATEJSON tproj-TK-9))"

# CR-26 A HUMAN FIX ON THE PARKED PR IS NEVER CLOSED BY THE SUPERSEDE (review
# BLOCKER on #2222). The park comment invites a push on the branch; the head is
# stored at park time (ci_parked_head) and re-read before the close. A head that
# moved, or one no recorded repair round of this lane pushed, is left open with
# a log line.
FRESH; RM_POOL; SEED "$TWO_ROUNDS"; RUN
[ "$(STATEJSON tproj-TK-9 | jq -r '.ci_parked_head // ""')" = cccccccccccccccccccccccccccccccccccccccc ] && ok \
  || bad "CR-26 the park stores the head it parked (record: $(STATEJSON tproj-TK-9))"
: > "$T/closed.txt"; printf 'dddddddddddddddddddddddddddddddddddddddd' > "$T/prhead"; newrec; : > "$LOGF"; RUN
grep -q 'pulls/9' "$T/closed.txt" && bad "CR-26 a parked PR someone pushed to is not closed ($(cat "$T/closed.txt"))" || ok
grep -q "NOT superseded: its head moved" "$LOGF" && ok || bad "CR-26 the leave is logged (log: $(tail -3 "$LOGF"))"
RM_POOL
# CR-26b the parked head is one no recorded round pushed (not harness-authored)
FRESH; RM_POOL; SEED "$TWO_ROUNDS"
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$T/prhead"; RUN
: > "$T/closed.txt"; newrec; : > "$LOGF"; RUN
grep -q 'pulls/9' "$T/closed.txt" && bad "CR-26b a parked head this lane did not push is not closed ($(cat "$T/closed.txt"))" || ok
grep -q "NOT superseded: its head .* is not one this lane pushed" "$LOGF" && ok || bad "CR-26b the leave is logged (log: $(tail -3 "$LOGF"))"
RM_POOL
# CR-27 NO TICKET KEY = A PARK WITHOUT A RE-PLAN, not "retried next tick" for
# ever (review of #2222): the record is PR-keyed, the park is written, nothing
# is enqueued, and the beat says why.
FRESH; printf 'hotfix-thing' > "$T/prbranch"; printf 'a thing with no key' > "$T/prtitle"
mkdir -p "$H/state/blocked-resolver/tproj"
jq -nc --argjson a "$TWO_ROUNDS" --arg u "$URL" '{project:"tproj",rkey:"o-tproj-9",mechanicals:1,fixrounds:0,regens:1,rebuilds:0,outcome:"",attempts:$a,ci_lineage_url:$u,ci_lineage_from:"0"}' \
  > "$H/state/blocked-resolver/tproj/o-tproj-9.json"
RUN; RUN
[ "$(STATEJSON o-tproj-9 | jq -r '.outcome // ""')" = CI_PARKED ] && ok || bad "CR-27 a keyless park is still a park (record: $(STATEJSON o-tproj-9); log: $(tail -3 "$LOGF"))"
[ -s "$T/queue.txt" ] && bad "CR-27 nothing enqueued without a key ($(cat "$T/queue.txt"))" || ok
grep 'CI_PARKED' "$T/beats.txt" | grep -q 'No re-plan' && ok || bad "CR-27 the beat says there is no re-plan (beats: $(cat "$T/beats.txt"))"
grep -q "retried next tick" "$LOGF" && bad "CR-27 no 'retried next tick' loop (log: $(grep 'retried next tick' "$LOGF" | head -2))" || ok
# CR-28 THE RE-PLAN CAP SURVIVES A WIPED RECORD (review nit): a relayed
# KIND: ci-replan note for the ticket is a floor under ci_replans, so a record
# reset does not buy a second automatic re-plan.
FRESH; SEED "$TWO_ROUNDS"; mkdir -p "$H/state/build-notes/tproj"
printf 'KIND: ci-replan\nPRIOR PR: x\n' > "$H/state/build-notes/tproj/TK-9.md.relayed-1790000000"
RUN
[ "$(OUTCOME)" = ABANDONED ] && ok || bad "CR-28 a relayed re-plan note counts toward BR_CI_REPLAN_MAX (record: $(STATEJSON tproj-TK-9))"
rm -f "$H/state/build-notes/tproj/TK-9.md.relayed-"*
# CR-29 THE PARK TERMINAL MATCHES THE EXACT PR (review nit): a CI_PARKED record
# whose ci_parked_rkey is `-` is not this PR's terminal.
FRESH; SEED "$TWO_ROUNDS"
jq -c '.outcome = "CI_PARKED" | .ci_parked_rkey = "-"' "$H/state/blocked-resolver/tproj/tproj-TK-9.json" > "$T/rec.json" \
  && mv "$T/rec.json" "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
RUN
[ "$(NCOMMENTS)" = 1 ] && [ "$(STATEJSON tproj-TK-9 | jq -r .ci_parked_rkey)" = o-tproj-9 ] && ok \
  || bad "CR-29 a park stamped '-' does not silence this PR (comments $(NCOMMENTS); record: $(STATEJSON tproj-TK-9))"

# CR-22 THE FLEET RULE SAYS SO, AND ITS RENDER IS CURRENT (Generated-files
# contract): rules/topics/01-iron-guardrails.md names the CI-repair park and the
# automatic re-plan, and bin/render-rules.sh --check passes.
grep -q 'it is PARKED, not abandoned' "$DIR/rules/topics/01-iron-guardrails.md" && grep -q 'BR_CI_REPLAN_MAX' "$DIR/rules/CLAUDE.md" \
  && ok || bad "CR-22 the guardrail names the CI-repair park + auto re-plan in the topic and the render"
( cd "$DIR" && HARNESS_TEST_SANDBOX=1 bin/render-rules.sh --check >/dev/null 2>&1 ) && ok || bad "CR-22 bin/render-rules.sh --check passes"

echo "blocked-resolver-ci-repair-cap: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
