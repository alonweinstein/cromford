#!/bin/bash
# tests/blocked-resolver.bh-980-test.sh — BH-870 spread the tick ACROSS the
# projects that have candidates. It did nothing about the tick AFTER this one.
#
# The project order inside br_round_robin was first-appearance in the candidate
# stream, and that stream is deterministic (pr-state.tsv rows, the builds glob,
# the queue). So every tick offered the same first BR_PER_TICK projects, the
# fifth project on a box with more parks than rungs was never reached, and
# nothing anywhere said so — on the hub that was project-5 with 14 hand-offs and
# zero resolver lines for seven hours.
#
# This file pins the four things BH-980 asks for, all on what the run DID:
#   - FAIRNESS. Six projects with one park each and a budget of two: all six are
#     visited within three ticks, because the visit ledger puts the projects this
#     lane has not looked at first (section 1).
#   - THE TICK LINE. One line per tick naming visited, skipped, rungs and why the
#     tick stopped (section 2).
#   - NO BROKEN PIPE. The drain reads an array, not a live pipe, so a tick that
#     breaks on its budget leaves no writer holding a closed fd (section 3), and
#     an ordering failure emits the stream exactly once (section 0c).
#   - THE STARVATION ALERT. A project with candidates that this lane has not
#     looked at for more than an hour gets ONE line, once per episode (section 4).
# Section 5 is the BH-870 contract: with no ledger the first tick is unchanged.
#
# Nothing here greps the source of bin/blocked-resolver.sh. The assertions are
# the queue rows the run wrote, the lines in logs/blocked-resolver.log, the rows
# in the visit ledger and the arguments the run handed bin/lane-alert.sh.
# Run from anywhere: tests/blocked-resolver.bh-980-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh): every
# timestamp below is derived from it, so a fixture that is "4000 seconds stale"
# is stale by construction whatever the wall clock says.
NOW=$(date -u +%s)
ISO() { date -u -d "@$((NOW - ${1:-0}))" '+%Y-%m-%dT%H:%M:%SZ'; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$T/fakebin" "$T/badbin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
# BH-1176: the lane sources bin/lib/br/ and REFUSES the tick when a module is
# missing, so the modules travel with the copy. One helper, one edit when the
# split moves again.
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/rebuild-ledger.sh" "$H/bin/lib/"
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
cp "$DIR/bin/lib/hold.sh" "$H/bin/lib/" 2>/dev/null || true
# bin/blocked-resolver.sh now REQUIRES the REST contract (#783): without it the
# lane refuses to start rather than deciding on undefined reads.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
chmod +x "$H/bin/"*.sh
# SIX projects with one park each — the shape the ticket describes — plus the
# two BH-870 used, so section 5 can drive that file's fixture unchanged.
{ for I in 1 2 3 4 5 6; do printf 'p%s o/p%s - - 2 box-p%s 192.0.2.%s\n' "$I" "$I" "$I" "$I"; done
  printf 'tproj o/tproj - - 2 box-tproj 192.0.2.9\n'
  printf 'uproj o/uproj - - 2 box-uproj 192.0.2.7\n'; } > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
: > "$H/env/global.env"
for f in beat.sh deploy-request.sh checks-run.sh pool-cap.sh run-build.sh agent-call.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
# THE ALERT IS RECORDED, not swallowed: "exactly one STARVED line per episode" is
# only provable if the arguments of every call are on disk.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
: > "$T/alerts.txt"

# Every gh call is recorded, so "which PRs did this tick act on" is a fact about
# the run rather than a reading of the log.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pull|pulls|issues)/([0-9]+).*#\2#p' | head -1)
case "\$*" in
  # bin/blocked-resolver.sh decides over REST now (#783). This fixture names its
  # PR fields off the NUMBER in the path, so they are written where the shared
  # REST stub reads them and the envelope is answered there.
  *"-i -X "*)
    GHT="$T"
    printf 'ticket/ts-%s' "\$N" > "$T/prbranch"
    printf 'TK-%s: a thing' "\$N" > "$T/prtitle"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$T/prhead"
    . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"issues/"*"/comments"*) cat "$T/comments-\$N.json" 2>/dev/null || echo '[]' ;;
  *"repos/"*"/issues/"*)
    cat "$T/issue-\$N.json" 2>/dev/null || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; } ;;
  *"pr close"*)   printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"pr comment"*|*"issue comment"*) exit 0 ;;
  *"--json state"*)        echo OPEN ;;
  *"/pulls/"*)             echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/ts-\$N" ;;
  *"--json headRefOid,headRefName"*) echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/ts-\$N" ;;
  *"--json headRefName"*)  echo "ticket/ts-\$N" ;;
  *"--json headRefOid"*)   echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ;;
  *"pr list"*"--state merged"*) : ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
: > "$T/gh.txt"; : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/ssh.txt"; : > "$T/run.log"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ssh.txt"\nexit 0\n' "$T" > "$T/fakebin/br-ssh"
chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
# NO REAL CREDENTIAL REACHES THIS RUN (same rule as tests/blocked-resolver-test.sh).
export GH_TOKEN=""
# A jobs client whose queue_put is recorded rather than sent. Every project here
# is a pool project, so every rung this file counts lands as one queue row.
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
for I in 1 2 3 4 5 6; do touch "$H/flags/fly-pool-p$I"; done
touch "$H/flags/fly-pool-tproj" "$H/flags/fly-pool-uproj"

LEDGER="$H/state/blocked-resolver/.last-visited.tsv"
BRENV=()
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH="$T/fakebin/br-ssh" env ${BRENV[*]:+"${BRENV[@]}"} \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || true; }
# The conductor hand-off row this lane drains: key, state, since, head, rev,
# alerted, why, url.
ROWADD() { printf '%s\tBLOCKED_HUMAN\t%s\t%s\t%s\t-\t%s\t%s\n' "$1" "$NOW" abc123 abc123 "$2" "$3" \
          >> "$H/state/merge-conductor/pr-state.tsv"; }
CLEAN() { scratch_rm "$H/state/blocked-resolver"
          scratch_rm "$H/state/merge-conductor/handoff-released"
          : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/gh.txt"; : > "$T/ssh.txt"
          : > "$T/alerts.txt"
          : > "$H/logs/blocked-resolver.log"; rm -f "$H/logs/ALERTS.log"
          : > "$H/state/merge-conductor/pr-state.tsv"; }

WHY="merge-failed-twice: gh pr merge refused"
# --- the fixture issues -------------------------------------------------------
# Every candidate must be CLEAR (unheld), or the hold gate would refuse the rung
# and the budget this file measures would never be spent at all.
ISSUE() {  # ISSUE <number> <labels-csv>
  local labels="[]"
  [ -n "${2:-}" ] && labels=$(printf '%s' "$2" | jq -Rc 'split(",")|map({name:.})')
  jq -nc --argjson n "$1" --argjson l "$labels" --arg t "TK-$1: a parked ticket" \
         --arg c "$(ISO 604800)" \
         '{number:$n,state:"open",labels:$l,title:$t,body:"## Scope",created_at:$c}'
}
for N in 1 2 3 4 5 6; do
  ISSUE "$N" ai-build > "$T/issue-$N.json"
  echo '[]' > "$T/comments-$N.json"
done
# One park per project, p1 first: in first-appearance order a budget of two is
# spent on p1 and p2 every single tick.
SEED6() { for I in 1 2 3 4 5 6; do
            ROWADD "o/p$I#$I" "$WHY" "https://github.com/o/p$I/pull/$I"; done; }
# ACTED <project> <ticket-number> — did some tick spend a rung on that ticket?
ACTED() { grep -q "^$1 TK-$2 $2 fly " "$T/queue.txt"; }
NACTED() { grep -c '^[a-z0-9]* TK-[0-9]* [0-9]* fly ' "$T/queue.txt"; }
# TICKLINE <n> — the nth `tick:` line of logs/blocked-resolver.log, stamp stripped.
TICKLINE() { grep 'tick: candidates=' "$H/logs/blocked-resolver.log" \
             | sed -n "${1}p" | sed -E 's/^[0-9-]+ [0-9:]+Z //'; }
# LROW <project> <column> — one field of the project's visit-ledger row.
LROW() { awk -F'\t' -v p="$2" -v c="$3" '$1 == p { print $c; exit }' "$1" 2>/dev/null; }
STARVED() { grep -c "STARVED $1:" "$T/alerts.txt"; }

# ============================================================================
# 0. br_round_robin, extracted verbatim and driven as the pure function it is.
#    Lifted out of the script rather than re-typed here, so a body that drifts
#    is a red test rather than a test that quietly checks a copy.
# ============================================================================
say() { printf '%s\n' "$*" >> "$T/say.txt"; }
: > "$T/say.txt"
RRSRC=$(sed -n '/^br_round_robin() {/,/^}/p' "$H/bin/blocked-resolver.sh")
[ -n "$RRSRC" ] && ok || bad "br_round_robin is not defined in bin/blocked-resolver.sh"
eval "$RRSRC" 2>/dev/null || bad "br_round_robin does not eval"
if ! command -v br_round_robin >/dev/null 2>&1; then br_round_robin() { cat; }; fi
RR() { printf '%s' "$1" | br_round_robin | cut -f3 | tr '\n' ' '; }

# --- 0a. the ledger decides the project order -------------------------------
# a was visited 10 seconds ago, b 100 seconds ago, c has no row at all. The
# project this lane has not looked at goes first, then the stalest, and the
# order WITHIN a project is still preserved.
ST="$T/st0"; mkdir -p "$ST"
{ printf 'a\t%s\t%s\t0\n' "$((NOW - 10))"  "$((NOW - 10))"
  printf 'b\t%s\t%s\t0\n' "$((NOW - 100))" "$((NOW - 100))"; } > "$ST/.last-visited.tsv"
RRIN=$(printf 'conductor\ta\ta1\tr\t-\t-\t-\nconductor\ta\ta2\tr\t-\t-\t-\nconductor\tb\tb1\tr\t-\t-\t-\nconductor\tc\tc1\tr\t-\t-\t-\n')
RROUT=$(RR "$RRIN")
[ "$RROUT" = "c1 b1 a1 a2 " ] && ok \
  || bad "with a ledger stamping a newest and c never, a a b c must come out c b a a, got '$RROUT'"
[ "$(printf '%s' "$RRIN" | br_round_robin | wc -l)" = 4 ] && ok \
  || bad "the ordering must print every line it read"

# --- 0b. no ledger = BH-870's order, byte for byte --------------------------
# These are tests/resolver-per-project-budget.bh-870-test.sh section 0's own
# vectors. A box that has never run this code has no ledger file, and its first
# tick has to behave exactly as it does today.
ST="$T/st-absent"
RRIN2=$(printf 'conductor\ta\ta1\tr\t-\t-\t-\nconductor\ta\ta2\tr\t-\t-\t-\nconductor\ta\ta3\tr\t-\t-\t-\nconductor\tb\tb1\tr\t-\t-\t-\nconductor\tc\tc1\tr\t-\t-\t-\n')
RROUT2=$(RR "$RRIN2")
[ "$RROUT2" = "a1 b1 c1 a2 a3 " ] && ok \
  || bad "with no ledger, a a a b c must still be a b c a a, got '$RROUT2'"
[ "$(printf '%s' "$RRIN2" | br_round_robin | wc -l)" = 5 ] && ok \
  || bad "with no ledger the ordering must still print every line it read"
RRIN3=$(printf 'conductor\ta\ta1\tr\t-\t-\t-\nconductor\t\tz1\tr\t-\t-\t-\nconductor\ta\ta2\tr\t-\t-\t-\n')
RROUT3=$(RR "$RRIN3")
[ "$RROUT3" = "a1 z1 a2 " ] && ok \
  || bad "an empty project field keeps its own bucket, got '$RROUT3'"
[ -z "$(printf '' | br_round_robin)" ] && ok || bad "empty input must produce empty output"

# --- 0c. a broken awk emits the stream ONCE, says so, and answers rc 2 ------
# The old fail-open printed the whole stream AFTER awk may already have printed
# part of it, so a mid-stream awk failure offered the head of the list twice.
: > "$T/say.txt"
printf '#!/bin/bash\nexit 1\n' > "$T/badbin/awk"; chmod +x "$T/badbin/awk"
OLDPATH="$PATH"; PATH="$T/badbin:$PATH"
RROUT4=$(printf '%s' "$RRIN2" | br_round_robin); RRRC=$?
PATH="$OLDPATH"
[ "$RROUT4" = "$RRIN2" ] && ok \
  || bad "a failed ordering must emit the stream it read, unchanged: '$RROUT4'"
[ "$(printf '%s\n' "$RROUT4" | wc -l)" = 5 ] && ok \
  || bad "a failed ordering must emit each line exactly once, got $(printf '%s\n' "$RROUT4" | wc -l) lines"
[ "$RRRC" = 2 ] && ok || bad "a failed ordering must answer rc 2, got $RRRC"
grep -q 'ordering fell back' "$T/say.txt" && ok \
  || bad "a failed ordering must say so: $(cat "$T/say.txt")"
# THE FAIL-OPEN'S OWN DEFECT: an awk that dies PART WAY THROUGH has already
# printed some of the stream, and the old fallback then printed all of it again.
# Seven lines out of a five-line stream means the head of the candidate list is
# offered — and acted on — twice.
: > "$T/say.txt"
printf '#!/bin/bash\nhead -2\nexit 1\n' > "$T/badbin/awk"; chmod +x "$T/badbin/awk"
PATH="$T/badbin:$PATH"
RROUT5=$(printf '%s' "$RRIN2" | br_round_robin); RRRC5=$?
PATH="$OLDPATH"
[ "$(printf '%s\n' "$RROUT5" | wc -l)" = 5 ] && ok \
  || bad "an awk that failed after a partial write must not re-emit the stream, got $(printf '%s\n' "$RROUT5" | wc -l) lines for 5 in"
[ "$RROUT5" = "$RRIN2" ] && ok \
  || bad "a partial ordering must fall back to the stream it read, once: '$RROUT5'"
[ "$RRRC5" = 2 ] && ok || bad "a partial ordering must answer rc 2, got $RRRC5"
unset ST

# ============================================================================
# 1. THE TICKET'S OWN TEST. Six projects with one park each, two rungs per
#    tick, three ticks. Before BH-980 every tick spent both rungs on p1 and p2
#    and p3..p6 were never offered a rung, in three ticks or in three hundred.
# ============================================================================
CLEAN
SEED6
BRENV=(BR_PER_TICK=2)
RUN
[ "$(NACTED)" = 2 ] && ok || bad "tick 1 must spend exactly 2 rungs, spent $(NACTED) (queue: $(cat "$T/queue.txt"))"
ACTED p1 1 && ACTED p2 2 && ok \
  || bad "tick 1 must visit p1 and p2 (queue: $(cat "$T/queue.txt"))"
[ "$(awk 'END{print NR}' "$LEDGER" 2>/dev/null)" = 6 ] && ok \
  || bad "tick 1 must leave a ledger row for every project in the stream, got $(cat "$LEDGER" 2>/dev/null)"
[ -n "$(LROW "$LEDGER" p1 2)" ] && [ "$(LROW "$LEDGER" p1 2)" -ge "$NOW" ] && ok \
  || bad "p1's last_visited must be stamped at this tick, got '$(LROW "$LEDGER" p1 2)'"
[ "$(LROW "$LEDGER" p3 2)" = 0 ] && ok \
  || bad "a project that was never looked at must not be stamped as visited, got '$(LROW "$LEDGER" p3 2)'"
RUN
[ "$(NACTED)" = 4 ] && ok || bad "tick 2 must spend 2 more rungs, total $(NACTED) (queue: $(cat "$T/queue.txt"))"
ACTED p3 3 && ACTED p4 4 && ok \
  || bad "tick 2 must move on to p3 and p4 (queue: $(cat "$T/queue.txt"))"
RUN
BRENV=()
[ "$(NACTED)" = 6 ] && ok || bad "tick 3 must spend 2 more rungs, total $(NACTED) (queue: $(cat "$T/queue.txt"))"
for I in 1 2 3 4 5 6; do
  ACTED "p$I" "$I" && ok \
    || bad "p$I must have been visited within three ticks (queue: $(cat "$T/queue.txt"))"
done
[ "$(cut -f1 "$LEDGER" | sort -u | wc -l)" = 6 ] && ok \
  || bad "the ledger must hold one row per project, got $(cat "$LEDGER")"
[ "$(awk 'END{print NR}' "$LEDGER")" = 6 ] && ok \
  || bad "the ledger must never grow a duplicate key: $(cat "$LEDGER")"

# ============================================================================
# 2. ONE LINE PER TICK. An operator reading logs/blocked-resolver.log has to be
#    able to answer "did this tick look at project-5, and if not why not"
#    without re-deriving the candidate list by hand.
# ============================================================================
# BH-1122 added a trailing `oldest_untouched=` field; BH-1457 added `retired=`
# beside the count, and `rebuilds=` and `budget_carry=` beside the reason. The
# fixed half of the line is still compared exactly; the age is a pattern because
# the rows are seeded at this file's own NOW and a tick that takes a second to
# run is not a red test.
case "$(TICKLINE 1)" in
  "tick: candidates=6 retired=0 carried=0 mechanical=0 families=0 llm_rungs=0 projects=6 visited=[p1 p2] skipped=[p3 p4 p5 p6] rungs=2/2 reason=budget secs="[0-9]*" rebuilds=2/4 budget_carry=0 oldest_untouched="[0-9]*m) ok ;;
  *) bad "tick 1's line is wrong: '$(TICKLINE 1)'" ;;
esac
case "$(TICKLINE 3)" in
  *"visited=[p5 p6]"*) ok ;;
  *) bad "tick 3 must record visiting p5 and p6: '$(TICKLINE 3)'" ;;
esac
case "$(TICKLINE 3)" in
  *"reason=budget"*) ok ;;
  *) bad "tick 3 stopped on its budget and must say so: '$(TICKLINE 3)'" ;;
esac
# A tick that ran off the end of its candidates did NOT stop on the budget, and
# a reason= that is wrong in one exit path is worse than no reason at all.
CLEAN
SEED6
# BR_REBUILDS_PER_TICK is raised past this section's six rebuild parks (BH-1457):
# this case is about the drain ledger and the skip list, and the pool-build cap
# is a different bound whose own suite proves it. Left at its default it would
# stop the sixth park here and make this line read `rungs=4/8`, which would say
# nothing about what this case is for.
BRENV=(BR_PER_TICK=8 BR_REBUILDS_PER_TICK=9)
RUN
BRENV=()
# ...and a tick that reached every candidate has nothing untouched, which reads
# as `-` rather than as 0m: "nothing is waiting" is not "we cannot tell".
case "$(TICKLINE 1)" in
  "tick: candidates=6 retired=0 carried=0 mechanical=0 families=0 llm_rungs=0 projects=6 visited=[p1 p2 p3 p4 p5 p6] skipped=[] rungs=6/8 reason=drained secs="[0-9]*" rebuilds=6/9 budget_carry=0 oldest_untouched=-") ok ;;
  *) bad "a tick with budget to spare must say drained with nothing skipped: '$(TICKLINE 1)'" ;;
esac
# An idle tick stays quiet (CLAUDE.md: "If a run finds nothing new, exit
# quietly"), and tests/rebuild-ledger.bh-946-test.sh reads an empty log as proof
# a refused run took no tick.
CLEAN
RUN
[ "$(grep -c 'tick:' "$H/logs/blocked-resolver.log")" = 0 ] && ok \
  || bad "an empty candidate stream must write no tick line: $(cat "$H/logs/blocked-resolver.log")"

# ============================================================================
# 3. NEVER A BROKEN PIPE. Every tick above broke on its budget with candidates
#    still unread; the old drain read through a process substitution, so that
#    break closed the reader under br_round_robin's fail-open printf.
# ============================================================================
[ "$(grep -c 'Broken pipe' "$T/run.log")" = 0 ] && ok \
  || bad "the run logged $(grep -c 'Broken pipe' "$T/run.log") Broken pipe line(s): $(grep -n 'Broken pipe' "$T/run.log" | head -3)"

# ============================================================================
# 4. THE STARVATION ALERT. ONE line for a project with candidates this lane has
#    not looked at for more than BR_STARVE_ALERT_SECS — and, just as important,
#    no line in the four states that look similar and are not.
# ============================================================================
CLEAN
SEED6
# BR_PER_TICK=0: nothing can be visited, so all six projects are skipped and the
# only variable left is each project's own ledger row.
#   p6  stale, never alerted            -> ALERT
#   p5  stale, last alerted BEFORE the visit that re-armed it  -> ALERT
#   p4  visited 30 minutes ago          -> no alert (under the hour)
#   p2  stale, already alerted since    -> no alert (one line per episode)
#   p1  p3  no row at all               -> no alert, first_seen written
mkdir -p "$H/state/blocked-resolver"
{ printf 'p6\t%s\t%s\t0\n'  "$((NOW - 4000))" "$((NOW - 9000))"
  printf 'p5\t%s\t%s\t%s\n' "$((NOW - 4000))" "$((NOW - 9000))" "$((NOW - 8000))"
  printf 'p4\t%s\t%s\t0\n'  "$((NOW - 1800))" "$((NOW - 9000))"
  printf 'p2\t%s\t%s\t%s\n' "$((NOW - 4000))" "$((NOW - 9000))" "$((NOW - 2000))"; } > "$LEDGER"
BRENV=(BR_PER_TICK=0)
RUN
[ "$(STARVED p6)" = 1 ] && ok || bad "a stale project with candidates must page once: $(cat "$T/alerts.txt")"
[ "$(STARVED p5)" = 1 ] && ok || bad "an episode re-armed by a later visit must page again: $(cat "$T/alerts.txt")"
[ "$(STARVED p4)" = 0 ] && ok || bad "a project visited 30 minutes ago must NOT page: $(cat "$T/alerts.txt")"
[ "$(STARVED p2)" = 0 ] && ok || bad "a project already alerted this episode must NOT page again: $(cat "$T/alerts.txt")"
[ "$(STARVED p1)" = 0 ] && ok || bad "a project seen for the first time must NOT page: $(cat "$T/alerts.txt")"
[ "$(STARVED p3)" = 0 ] && ok || bad "a project seen for the first time must NOT page: $(cat "$T/alerts.txt")"
[ -n "$(LROW "$LEDGER" p3 3)" ] && [ "$(LROW "$LEDGER" p3 3)" -ge "$NOW" ] && ok \
  || bad "a project seen for the first time gets first_seen, got '$(LROW "$LEDGER" p3 3)'"
grep "STARVED p6:" "$T/alerts.txt" | grep -q '1 parked candidate' && ok \
  || bad "the alert must count the candidates it saw: $(grep 'STARVED p6' "$T/alerts.txt")"
grep "STARVED p6:" "$T/alerts.txt" | grep -q "$(date -u -d "@$((NOW - 4000))" '+%Y-%m-%dT%H:%M')" && ok \
  || bad "the alert must name when the project was last looked at: $(grep 'STARVED p6' "$T/alerts.txt")"
# ONE PER EPISODE. The next tick changes nothing, so it must say nothing.
RUN
[ "$(STARVED p6)" = 1 ] && ok || bad "the second tick must not page again: $(cat "$T/alerts.txt")"
[ "$(STARVED p5)" = 1 ] && ok || bad "the second tick must not page again for p5: $(cat "$T/alerts.txt")"
# A project whose first_seen is now an hour old starts its own episode.
awk -F'\t' -v OFS='\t' -v s="$((NOW - 4000))" '$1 == "p3" { $3 = s } { print }' "$LEDGER" > "$LEDGER.new"
mv "$LEDGER.new" "$LEDGER"
RUN
[ "$(STARVED p3)" = 1 ] && ok || bad "a never-visited project an hour old must page once: $(cat "$T/alerts.txt")"
grep "STARVED p3:" "$T/alerts.txt" | grep -q 'first appeared' && ok \
  || bad "a never-visited project's line must say so rather than invent a last visit: $(grep 'STARVED p3' "$T/alerts.txt")"
[ "$(STARVED p6)" = 1 ] && ok || bad "p6 must still have paged exactly once: $(cat "$T/alerts.txt")"
# A PROJECT WITH NO CANDIDATES IS NOT STARVED, however old its row. It is not in
# the stream, so this lane has nothing to look at.
: > "$H/state/merge-conductor/pr-state.tsv"
ROWADD "o/p1#1" "$WHY" "https://github.com/o/p1/pull/1"
awk -F'\t' -v OFS='\t' -v s="$((NOW - 9000))" '$1 == "p4" { $2 = s; $4 = 0 } { print }' "$LEDGER" > "$LEDGER.new"
mv "$LEDGER.new" "$LEDGER"
: > "$T/alerts.txt"
RUN
[ "$(STARVED p4)" = 0 ] && ok \
  || bad "a project with no candidates this tick must not page: $(cat "$T/alerts.txt")"
# An empty stream alerts nothing at all.
: > "$H/state/merge-conductor/pr-state.tsv"
RUN
[ ! -s "$T/alerts.txt" ] && ok || bad "an empty tick must alert nothing: $(cat "$T/alerts.txt")"
BRENV=()
# AND THE ALERT RE-ARMS. Give every other project a fresh stamp so the stale one
# sorts first, then spend a real budget: p6 is visited, and its row now says so.
SEED6
: > "$H/state/merge-conductor/pr-state.tsv"
SEED6
{ for I in 1 2 3 4 5; do printf 'p%s\t%s\t%s\t0\n' "$I" "$NOW" "$NOW"; done
  printf 'p6\t%s\t%s\t%s\n' "$((NOW - 4000))" "$((NOW - 9000))" "$((NOW - 10))"; } > "$LEDGER"
: > "$T/queue.txt"
BRENV=(BR_PER_TICK=2)
RUN
BRENV=()
ACTED p6 6 && ok \
  || bad "the least-recently-visited project must be the one the next tick reaches (queue: $(cat "$T/queue.txt"))"
[ -n "$(LROW "$LEDGER" p6 2)" ] && [ "$(LROW "$LEDGER" p6 2)" -ge "$(LROW "$LEDGER" p6 4)" ] && ok \
  || bad "a visit must re-arm the alert (last_visited $(LROW "$LEDGER" p6 2) vs last_alerted $(LROW "$LEDGER" p6 4))"

# ============================================================================
# 5. BH-870'S FIRST TICK IS UNCHANGED. Three tproj rows above one uproj row and
#    a budget of two, on a box with no ledger: the interleave still gives each
#    project one rung, and tproj's first candidate is still the one that runs.
#    That is tests/resolver-per-project-budget.bh-870-test.sh section 1, driven
#    here to prove the ledger changes nothing on a box that has never had one.
# ============================================================================
CLEAN
ROWADD "o/tproj#1" "$WHY" "https://github.com/o/tproj/pull/1"
ROWADD "o/tproj#2" "$WHY" "https://github.com/o/tproj/pull/2"
ROWADD "o/tproj#3" "$WHY" "https://github.com/o/tproj/pull/3"
ROWADD "o/uproj#4" "$WHY" "https://github.com/o/uproj/pull/4"
BRENV=(BR_PER_TICK=2)
RUN
BRENV=()
ACTED tproj 1 && ok \
  || bad "the first candidate of the busy project is still the one that runs (queue: $(cat "$T/queue.txt"))"
ACTED uproj 4 && ok \
  || bad "with 2 rungs and tproj first, uproj must still be reached (queue: $(cat "$T/queue.txt"))"
[ "$(NACTED)" = 2 ] && ok \
  || bad "the fleet total BR_PER_TICK=2 is unchanged, got $(NACTED) rungs (queue: $(cat "$T/queue.txt"))"
[ "$(grep -c 'Broken pipe' "$T/run.log")" = 0 ] && ok \
  || bad "no tick in this file may log a Broken pipe: $(grep -n 'Broken pipe' "$T/run.log" | head -3)"

echo "blocked-resolver.bh-980: PASS $PASS FAIL $FAIL"
[ "$FAIL" -eq 0 ]
