#!/bin/bash
# tests/blocked-resolver.bh-1122-test.sh — BH-1122: a park that cannot be
# resolved stops spending rungs, the oldest hand-off goes first, and a lane with
# more parks than budget says so once.
#
# THE BUG THIS PINS (hub, 2026-09-20). br_rebuild_settle's rc-1 arm recorded the
# failure, bumped a counter and logged "retried next tick, no counter spent" —
# for ever. project-4 TK-1674 produced 25 of those lines in a row, each one of the
# four rungs a ten-minute tick has. br_adjudicate's no-verdict arm has the same
# shape and the same absence of a terminal. Meanwhile every one of the last 40
# hub ticks ended `rungs=4/4 reason=budget`, #679 sat 434 minutes past its TTL
# and was never reached, and nothing anywhere said the lane was saturated.
#
# WHAT IS DRIVEN. Sections 1-5 and 7 run bin/blocked-resolver.sh end to end
# against a scratch $HARNESS: real conductor rows, a real state tree, a recorded
# jobs client, a recorded bin/lane-alert.sh and a recorded agent-call. Section 6
# drives mc_stuck_check out of the real bin/lib/merge-conductor-lib.sh and reads
# the page back from the recorded bin/lane-alert.sh, then extracts stuck_rekick
# VERBATIM from bin/merge-conductor.sh, the way
# tests/mc-rebase-consume-test.sh does, and drives it. Nothing here greps the
# source of either script: every assertion is a queue row, a state json field, a
# log line, or the arguments a run handed bin/lane-alert.sh.
#
# Run from anywhere: tests/blocked-resolver.bh-1122-test.sh   (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh): every fixture
# age below is derived from it, so a row that is "8000 seconds stale" is stale by
# construction whatever the wall clock says. The three sections that assert an
# EXACT minute count on the tick line re-anchor immediately before their own run
# (ANCHOR below) — the elapsed cost of the sections before them must not move a
# `67m` to a `68m`.
NOW=$(date -u +%s)
ISO() { date -u -d "@$((NOW - ${1:-0}))" '+%Y-%m-%dT%H:%M:%SZ'; }
# ANCHOR — a clock read taken right before a tick whose oldest_untouched is
# compared exactly. determinism: ok — the fixture is anchored to the tick it
# drives, never to a fixed date, so this file can never pick its own red day.
ANCHOR() { date -u +%s; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$T/fakebin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$H/bin/"
# BH-1176: the lane sources bin/lib/br/ and REFUSES the tick when a module is
# missing, so the modules travel with the copy. One helper, one edit when the
# split moves again.
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/rebuild-ledger.sh" "$DIR/bin/lib/hold.sh" "$H/bin/lib/"
# bin/blocked-resolver.sh now REQUIRES the REST contract (#783): without it the
# lane refuses to start rather than deciding on undefined reads.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
# BH-680 (#929): merge-conductor-lib.sh is a shim that sources bin/lib/mc/*.sh and
# exits on a missing module — the fixture must carry the modules too.
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
chmod +x "$H/bin/"*.sh
# Three pool projects plus the GitHub-Issues lane the enqueue sections drive.
{ for I in 1 2 3; do printf 'p%s o/p%s - - 2 box-p%s 192.0.2.%s\n' "$I" "$I" "$I" "$I"; done
  printf 'tproj o/tproj - - 2 box-tproj 192.0.2.9\n'; } > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
# BH-1510.1: the resolver's models are model_routes rows; this worker-less box carries the resolver's cache of #1507's table.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" p1 p2 p3 tproj
: > "$H/env/global.env"
for f in beat.sh deploy-request.sh checks-run.sh pool-cap.sh run-build.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
# THE ADJUDICATION CALL IS RECORDED, and its answer is the fixture's to choose:
# $ADJ_VERDICT rides in on the run's environment and is written into the OUT file
# agent-call.sh is handed ($5). Empty = a session that came back with no verdict,
# which is the silence section 2 is about.
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf 'call %s %s %s\n' "\$1" "\$2" "\$5" >> "$T/agent.txt"
printf 'the reasoning, such as it was\n%s\n' "\${ADJ_VERDICT:-}" > "\$5"
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"
: > "$T/agent.txt"
# THE ALERT IS RECORDED, not swallowed: "exactly ONE line" is only provable if
# the arguments of every call are on disk.
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
  *"pr comment"*|*"issue comment"*) printf '%s\n' "\$*" >> "$T/comments.txt"; exit 0 ;;
  *"pr diff"*) : ;;
  *"--json state"*) cat "$T/prstate" 2>/dev/null || echo OPEN ;;
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
: > "$T/gh.txt"; : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/comments.txt"
: > "$T/ssh.txt"; : > "$T/run.log"
echo OPEN > "$T/prstate"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ssh.txt"\nexit 0\n' "$T" > "$T/fakebin/br-ssh"
chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
# NO REAL CREDENTIAL REACHES THIS RUN (the rule tests/blocked-resolver-test.sh holds).
export GH_TOKEN=""

# The three jobs clients. OK takes the row; FAIL takes nothing (queue_put prints
# nothing and answers rc 1 — "the jobs queue took no row"); GONE is a box with no
# jobs client at all, which is a DIFFERENT why and therefore a different streak.
JOBS_OK() { cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
}
JOBS_FAIL() { cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf 'REFUSED %s\n' "\$*" >> "$T/queue-attempts.txt"; return 1; }
queue_done() { return 0; }
queue_list() { return 1; }
EOF
}
JOBS_GONE() { rm -f "$H/bin/jobs-client.sh"; }
for I in 1 2 3; do touch "$H/flags/fly-pool-p$I"; done
touch "$H/flags/fly-pool-tproj"
JOBS_OK

ROWS="$H/state/merge-conductor/pr-state.tsv"
SATF="$H/state/blocked-resolver/.saturation.tsv"
SATMARK="$H/state/blocked-resolver/.saturated"
BRENV=()
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH="$T/fakebin/br-ssh" env ${BRENV[*]:+"${BRENV[@]}"} \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || true; }
# ROWADD <key> <since> <why> <url> [state] [head] — one conductor hand-off row,
# appended. Columns: key state since head rev alerted reason url.
ROWADD() { printf '%s\t%s\t%s\t%s\t%s\t-\t%s\t%s\n' \
             "$1" "${5:-BLOCKED_HUMAN}" "$2" "${6:-abc123}" "${6:-abc123}" "$3" "$4" >> "$ROWS"; }
ROWDROP() { grep -v "^$1	" "$ROWS" > "$T/rows.tmp" 2>/dev/null; mv -f "$T/rows.tmp" "$ROWS"; }
STATEJSON() { cat "$H/state/blocked-resolver/$1/$2.json" 2>/dev/null; }
LOG() { cat "$H/logs/blocked-resolver.log" 2>/dev/null; }
TICKLINE() { grep 'tick: candidates=' "$H/logs/blocked-resolver.log" \
             | sed -n "${1}p" | sed -E 's/^[0-9-]+ [0-9:]+Z //'; }
LASTTICK() { grep 'tick: candidates=' "$H/logs/blocked-resolver.log" \
             | tail -1 | sed -E 's/^[0-9-]+ [0-9:]+Z //'; }
NTICKS() { grep -c 'tick: candidates=' "$H/logs/blocked-resolver.log" 2>/dev/null; }
# ACTED <project> <ticket-number> — did some tick spend a rung on that ticket?
ACTED() { grep -q "^$1 TK-$2 $2 fly " "$T/queue.txt"; }
NACTED() { grep -c '^[a-z0-9]* TK-[0-9]* [0-9]* fly ' "$T/queue.txt"; }
NALERT() { grep -c "$1" "$T/alerts.txt" 2>/dev/null; }
NLINES() { grep -c "$1" "$H/logs/blocked-resolver.log" 2>/dev/null; }
STREAK() { awk -F'\t' '$1=="streak"{print $2; exit}' "$SATF" 2>/dev/null; }
NAGENT() { grep -c . "$T/agent.txt" 2>/dev/null; }
CLEAN() { scratch_rm "$H/state/blocked-resolver" 2>/dev/null
          scratch_rm "$H/state/merge-conductor/handoff" 2>/dev/null
          scratch_rm "$H/state/merge-conductor/handoff-released" 2>/dev/null
          : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/queue-attempts.txt"
          : > "$T/gh.txt"; : > "$T/ssh.txt"; : > "$T/alerts.txt"; : > "$T/agent.txt"
          : > "$T/comments.txt"
          : > "$H/logs/blocked-resolver.log"; rm -f "$H/logs/ALERTS.log"
          echo OPEN > "$T/prstate"
          : > "$ROWS"; }

# The fixture issues. Every candidate must be CLEAR (unheld) or the hold gate
# would refuse the rung and none of the budgets below would ever be spent.
ISSUE() {  # ISSUE <number> <labels-csv>
  local labels="[]"
  [ -n "${2:-}" ] && labels=$(printf '%s' "$2" | jq -Rc 'split(",")|map({name:.})')
  jq -nc --argjson n "$1" --argjson l "$labels" --arg t "TK-$1: a parked ticket" \
         --arg c "$(ISO 604800)" \
         '{number:$n,state:"open",labels:$l,title:$t,body:"## Scope",created_at:$c}'
}
for N in $(seq 1 40); do
  ISSUE "$N" ai-build > "$T/issue-$N.json"
  echo '[]' > "$T/comments-$N.json"
done

MFT="merge-failed-twice: gh pr merge refused"

# ============================================================================
# 1. A REBUILD ENQUEUE THAT FAILS IDENTICALLY N TIMES STALLS. Three failures
#    with the same reason, one alert, and then the park leaves the candidate
#    list entirely until somebody clears its outcome.
# ============================================================================
CLEAN; JOBS_FAIL
ROWADD "o/tproj#9" "$NOW" "$MFT" "https://github.com/o/tproj/pull/9"
RUN                                   # tick 1: rung 3 closes the PR, enqueue fails
# The conductor re-classifies the closed PR on its own next tick, so from here
# the retry row in state/ is the only thing that can re-offer this ticket.
: > "$ROWS"
ROWADD "o/tproj#9" "$NOW" "$MFT" "https://github.com/o/tproj/pull/9" CLOSED
echo CLOSED > "$T/prstate"
[ "$(STATEJSON tproj tproj-TK-9 | jq -r .enqueue_failures)" = 1 ] && ok \
  || bad "failure 1 must be counted (got '$(STATEJSON tproj tproj-TK-9 | jq -r .enqueue_failures)')"
[ "$(STATEJSON tproj tproj-TK-9 | jq -r .outcome)" = "" ] && ok \
  || bad "one failure is not a terminal (outcome '$(STATEJSON tproj tproj-TK-9 | jq -r .outcome)')"
[ ! -s "$T/alerts.txt" ] && ok || bad "one failure is not a page: $(cat "$T/alerts.txt")"
RUN                                   # tick 2: failure 2
[ "$(STATEJSON tproj tproj-TK-9 | jq -r .enqueue_failures)" = 2 ] && ok \
  || bad "failure 2 must be counted (got '$(STATEJSON tproj tproj-TK-9 | jq -r .enqueue_failures)')"
[ "$(STATEJSON tproj tproj-TK-9 | jq -r .outcome)" = "" ] && ok \
  || bad "two failures are not a terminal either (outcome '$(STATEJSON tproj tproj-TK-9 | jq -r .outcome)')"
[ ! -s "$T/alerts.txt" ] && ok || bad "two failures must not page: $(cat "$T/alerts.txt")"
RUN                                   # tick 3: failure 3 — the stall
[ "$(STATEJSON tproj tproj-TK-9 | jq -r .outcome)" = STALLED ] && ok \
  || bad "THE BUG: three identical failures must stall (outcome '$(STATEJSON tproj tproj-TK-9 | jq -r .outcome)'; log: $(LOG | tail -4))"
[ -n "$(STATEJSON tproj tproj-TK-9 | jq -r '.stalled_fp // ""')" ] && ok \
  || bad "the stall must record the row it stalled on (state: $(STATEJSON tproj tproj-TK-9))"
[ "$(STATEJSON tproj tproj-TK-9 | jq -r '.attempts[-1].action')" = stalled ] && ok \
  || bad "the stall is an attempt on the record (attempts: $(STATEJSON tproj tproj-TK-9 | jq -c '[.attempts[].action]'))"
[ "$(NALERT 'STALLED')" = 1 ] && ok \
  || bad "a stall pages exactly once (alerts: $(cat "$T/alerts.txt"))"
grep -q 'tproj/TK-9' "$T/alerts.txt" && ok \
  || bad "the page must name the project and the ticket: $(cat "$T/alerts.txt")"
grep -q 'took no row' "$T/alerts.txt" && ok \
  || bad "the page must name what could not be resolved: $(cat "$T/alerts.txt")"
grep -q 'tproj-TK-9.json' "$T/alerts.txt" && ok \
  || bad "the page must name the file an operator clears to resume: $(cat "$T/alerts.txt")"
grep -iE 'BLOCKED_HUMAN|by hand|for the operator|needs a human' "$T/alerts.txt" >/dev/null 2>&1 \
  && bad "nothing in this lane parks a ticket on a person: $(cat "$T/alerts.txt")" || ok
grep -iE 'BLOCKED_HUMAN|by hand|for the operator|needs a human' "$H/logs/ALERTS.log" >/dev/null 2>&1 \
  && bad "no ALERTS line may ask for a human either: $(cat "$H/logs/ALERTS.log")" || ok
# Ticks 4-6: the park is gone from the candidate list. No rung, no attempt, no
# second page, and not one more `rebuild enqueue FAILED` line.
ATT3=$(STATEJSON tproj tproj-TK-9 | jq -r '[.attempts[]] | length')
FAILED3=$(NLINES 'rebuild enqueue FAILED')
for _ in 4 5 6; do RUN; done
[ "$(STATEJSON tproj tproj-TK-9 | jq -r '[.attempts[]] | length')" = "$ATT3" ] && ok \
  || bad "a stalled park adds no attempts (attempts: $(STATEJSON tproj tproj-TK-9 | jq -c '[.attempts[].action]'))"
[ "$(NLINES 'rebuild enqueue FAILED')" = "$FAILED3" ] && ok \
  || bad "a stalled park makes no more enqueue attempts ($(NLINES 'rebuild enqueue FAILED') FAILED lines, was $FAILED3)"
[ "$(NALERT 'STALLED')" = 1 ] && ok \
  || bad "a stalled park pages once, not once per tick: $(cat "$T/alerts.txt")"
[ ! -s "$T/queue.txt" ] && ok || bad "a stalled park enqueues nothing: $(cat "$T/queue.txt")"
[ "$(STATEJSON tproj tproj-TK-9 | jq -r .enqueue_failures)" = 3 ] && ok \
  || bad "the counter stops where the stall did (got '$(STATEJSON tproj tproj-TK-9 | jq -r .enqueue_failures)')"
# RE-ARM: clearing the outcome puts the park back in the stream. The alert says
# to clear it, never to delete it.
JOBS_OK
jq '.outcome=""' "$H/state/blocked-resolver/tproj/tproj-TK-9.json" > "$T/re.json" \
  && mv -f "$T/re.json" "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
RUN
grep -q '^tproj TK-9 9 fly 0 ' "$T/queue.txt" && ok \
  || bad "a cleared outcome must put the park back in the stream (queue: $(cat "$T/queue.txt"); log: $(LOG | tail -4))"
[ "$(STATEJSON tproj tproj-TK-9 | jq -r .enqueue_failures)" = 0 ] && ok \
  || bad "an enqueue that lands resets the streak (got '$(STATEJSON tproj tproj-TK-9 | jq -r .enqueue_failures)')"
[ "$(STATEJSON tproj tproj-TK-9 | jq -r '.enqueue_why // "-"')" = "-" ] && ok \
  || bad "an enqueue that lands clears the why too (got '$(STATEJSON tproj tproj-TK-9 | jq -r '.enqueue_why // "-"')')"
# ...and DELETING the file is what the alert warns against: nothing re-offers it.
scratch_rm "$H/state/blocked-resolver/tproj" 2>/dev/null
: > "$T/queue.txt"; : > "$H/logs/blocked-resolver.log"
RUN
[ ! -s "$T/queue.txt" ] && ok || bad "a deleted record must not resurrect the park: $(cat "$T/queue.txt")"
[ "$(NTICKS)" = 0 ] && ok || bad "a deleted record leaves no candidate at all: $(LOG)"

# 1b. NOT IDENTICAL, NOT A STREAK. Two "took no row" failures then a box with no
#     jobs client at all is a different reason, and the streak restarts at 1.
CLEAN; JOBS_FAIL
ROWADD "o/tproj#9" "$NOW" "$MFT" "https://github.com/o/tproj/pull/9"
RUN
: > "$ROWS"
ROWADD "o/tproj#9" "$NOW" "$MFT" "https://github.com/o/tproj/pull/9" CLOSED
echo CLOSED > "$T/prstate"
RUN
[ "$(STATEJSON tproj tproj-TK-9 | jq -r .enqueue_failures)" = 2 ] && ok \
  || bad "two identical failures must count 2 (got '$(STATEJSON tproj tproj-TK-9 | jq -r .enqueue_failures)')"
JOBS_GONE
RUN
[ "$(STATEJSON tproj tproj-TK-9 | jq -r .enqueue_failures)" = 1 ] && ok \
  || bad "a failure for a DIFFERENT reason restarts the streak (got '$(STATEJSON tproj tproj-TK-9 | jq -r .enqueue_failures)')"
[ "$(STATEJSON tproj tproj-TK-9 | jq -r .outcome)" = "" ] && ok \
  || bad "and it must not stall (outcome '$(STATEJSON tproj tproj-TK-9 | jq -r .outcome)')"
case "$(STATEJSON tproj tproj-TK-9 | jq -r '.enqueue_why // ""')" in
  *"no jobs client"*) ok ;;
  *) bad "the record must carry the reason the streak is counting (got '$(STATEJSON tproj tproj-TK-9 | jq -r '.enqueue_why // ""')')" ;;
esac
[ ! -s "$T/alerts.txt" ] && ok || bad "a restarted streak pages nothing: $(cat "$T/alerts.txt")"

# 1c. THE KNOB. BR_ENQUEUE_FAIL_MAX=5 and three failures is not a stall.
CLEAN; JOBS_FAIL
BRENV=(BR_ENQUEUE_FAIL_MAX=5)
ROWADD "o/tproj#9" "$NOW" "$MFT" "https://github.com/o/tproj/pull/9"
RUN
: > "$ROWS"
ROWADD "o/tproj#9" "$NOW" "$MFT" "https://github.com/o/tproj/pull/9" CLOSED
echo CLOSED > "$T/prstate"
RUN; RUN
BRENV=()
[ "$(STATEJSON tproj tproj-TK-9 | jq -r .enqueue_failures)" = 3 ] && ok \
  || bad "three failures under a cap of 5 must still count (got '$(STATEJSON tproj tproj-TK-9 | jq -r .enqueue_failures)')"
[ "$(STATEJSON tproj tproj-TK-9 | jq -r .outcome)" = "" ] && ok \
  || bad "BR_ENQUEUE_FAIL_MAX must be the bound, not a constant (outcome '$(STATEJSON tproj tproj-TK-9 | jq -r .outcome)')"
[ ! -s "$T/alerts.txt" ] && ok || bad "under the cap nothing pages: $(cat "$T/alerts.txt")"

# 1d. TWO FAILURES THEN A SUCCESS is the ordinary path and must be untouched.
CLEAN; JOBS_FAIL
ROWADD "o/tproj#9" "$NOW" "$MFT" "https://github.com/o/tproj/pull/9"
RUN
: > "$ROWS"
ROWADD "o/tproj#9" "$NOW" "$MFT" "https://github.com/o/tproj/pull/9" CLOSED
echo CLOSED > "$T/prstate"
RUN
JOBS_OK
RUN
grep -q '^tproj TK-9 9 fly 0 ' "$T/queue.txt" && ok \
  || bad "the retry must land when the queue answers again (queue: $(cat "$T/queue.txt"))"
[ "$(STATEJSON tproj tproj-TK-9 | jq -r .outcome)" = "" ] && ok \
  || bad "a landed retry is no terminal (outcome '$(STATEJSON tproj tproj-TK-9 | jq -r .outcome)')"
[ ! -s "$T/alerts.txt" ] && ok || bad "a landed retry pages nothing: $(cat "$T/alerts.txt")"

# ============================================================================
# 2. AN ADJUDICATION THAT NEVER ANSWERS STALLS TOO. Same sentence in the ticket,
#    same shape in the code: a rung that is bought every tick and discarded.
# ============================================================================
CLEAN; JOBS_OK
BRENV=(ADJ_VERDICT=)
ROWADD "o/tproj#7" "$NOW" "iron-law: hardcoded claude-opus-5 in src/agent.ts" \
       "https://github.com/o/tproj/pull/7"
RUN; RUN; RUN
BRENV=()
[ "$(NAGENT)" = 3 ] && ok \
  || bad "three ticks must buy three reads (agent calls: $(NAGENT))"
[ "$(STATEJSON tproj tproj-TK-7 | jq -r .outcome)" = STALLED ] && ok \
  || bad "THE BUG: three silent adjudications must stall (outcome '$(STATEJSON tproj tproj-TK-7 | jq -r .outcome)'; log: $(LOG | tail -4))"
[ "$(STATEJSON tproj o-tproj-7 | jq -r '[.attempts[] | select(.action=="adjudicate-noverdict")] | length')" = 3 ] && ok \
  || bad "the silent reads stay on the attempt trail (attempts: $(STATEJSON tproj o-tproj-7 | jq -c '[.attempts[].action]'))"
[ "$(NALERT 'STALLED')" = 1 ] && ok \
  || bad "the adjudication stall pages exactly once: $(cat "$T/alerts.txt")"
grep -q 'adjudication' "$T/alerts.txt" && ok \
  || bad "the page must say which rung stalled: $(cat "$T/alerts.txt")"
grep -q 'no ACCEPT/REJECT' "$T/alerts.txt" && ok \
  || bad "the page must say what the rung could not produce: $(cat "$T/alerts.txt")"
BRENV=(ADJ_VERDICT=)
RUN; RUN
BRENV=()
[ "$(NAGENT)" = 3 ] && ok \
  || bad "a stalled adjudication buys no more reads (agent calls: $(NAGENT))"
[ "$(NALERT 'STALLED')" = 1 ] && ok \
  || bad "and pages no more: $(cat "$T/alerts.txt")"
# RE-ARM on a new head: the row changed, so the ladder resumes.
: > "$ROWS"
ROWADD "o/tproj#7" "$NOW" "iron-law: hardcoded claude-opus-5 in src/agent.ts" \
       "https://github.com/o/tproj/pull/7" BLOCKED_HUMAN deadbeef
BRENV=(ADJ_VERDICT=)
RUN
BRENV=()
[ "$(NAGENT)" = 4 ] && ok \
  || bad "a changed head must re-arm the park (agent calls: $(NAGENT); log: $(LOG | tail -4))"
grep -q 'stall-cleared' <<<"$(STATEJSON tproj tproj-TK-7 | jq -c '[.attempts[].action]')" && ok \
  || bad "the clearing must be on the record (attempts: $(STATEJSON tproj tproj-TK-7 | jq -c '[.attempts[].action]'))"
# NEGATIVE: two silent reads then a REJECT is a verdict, not a stall.
CLEAN; JOBS_OK
ROWADD "o/tproj#7" "$NOW" "iron-law: hardcoded claude-opus-5 in src/agent.ts" \
       "https://github.com/o/tproj/pull/7"
BRENV=(ADJ_VERDICT=)
RUN; RUN
BRENV=(ADJ_VERDICT=REJECT)
RUN
BRENV=()
[ "$(STATEJSON tproj tproj-TK-7 | jq -r .outcome)" != STALLED ] && ok \
  || bad "a verdict on the third read must not stall (outcome '$(STATEJSON tproj tproj-TK-7 | jq -r .outcome)')"
[ "$(STATEJSON tproj o-tproj-7 | jq -r .adjudications)" = 1 ] && ok \
  || bad "the verdict spends its counter (adjudications=$(STATEJSON tproj o-tproj-7 | jq -r .adjudications))"
[ "$(NALERT 'STALLED')" = 0 ] && ok \
  || bad "and nothing pages a stall: $(cat "$T/alerts.txt")"

# ============================================================================
# 3. OLDEST HAND-OFF FIRST. pr-state.tsv is read in FILE order, so the row that
#    has been parked longest was whichever one happened to be written first.
# ============================================================================
CLEAN; JOBS_OK
# File order: young, breached, old-but-not-breached. BLOCKED_HUMAN's TTL is 7200.
ROWADD "o/p1#11" "$((NOW - 600))"  "$MFT" "https://github.com/o/p1/pull/11"
ROWADD "o/p1#12" "$((NOW - 8000))" "$MFT" "https://github.com/o/p1/pull/12"
ROWADD "o/p1#13" "$((NOW - 3000))" "$MFT" "https://github.com/o/p1/pull/13"
BRENV=(BR_PER_TICK=1)
RUN
ACTED p1 12 && ok \
  || bad "THE BUG: the TTL-breached hand-off must go first (queue: $(cat "$T/queue.txt"))"
[ "$(NACTED)" = 1 ] && ok || bad "one rung, one row (queue: $(cat "$T/queue.txt"))"
ROWDROP "o/p1#12"
RUN
ACTED p1 13 && ok \
  || bad "then the older of the two unbreached rows (queue: $(cat "$T/queue.txt"))"
ROWDROP "o/p1#13"
RUN
ACTED p1 11 && ok \
  || bad "and the youngest last (queue: $(cat "$T/queue.txt"))"
BRENV=()
# 3b. AN UNREADABLE PARK AGE SORTS LAST, never first: absent is not oldest.
CLEAN; JOBS_OK
ROWADD "o/p1#14" "-"              "$MFT" "https://github.com/o/p1/pull/14"
ROWADD "o/p1#15" "$((NOW - 100))" "$MFT" "https://github.com/o/p1/pull/15"
BRENV=(BR_PER_TICK=1)
RUN
BRENV=()
ACTED p1 15 && ok \
  || bad "a row with no readable park age must not outrank a real one (queue: $(cat "$T/queue.txt"))"
# 3c. THE TTL IS READ THROUGH mc_ttl, so MC_TTL_BLOCKED_HUMAN moves the line.
CLEAN; JOBS_OK
ROWADD "o/p1#17" "$((NOW - 10))"  "$MFT" "https://github.com/o/p1/pull/17"
ROWADD "o/p1#16" "$((NOW - 600))" "$MFT" "https://github.com/o/p1/pull/16"
BRENV=(BR_PER_TICK=1 MC_TTL_BLOCKED_HUMAN=100)
RUN
BRENV=()
ACTED p1 16 && ok \
  || bad "an MC_TTL override must move the breached line (queue: $(cat "$T/queue.txt"))"

# ============================================================================
# 4. THE TICK LINE SAYS HOW OLD THE OLDEST THING IT DID NOT TOUCH IS. Without
#    it, "rungs=4/4 reason=budget" is the same line whether the lane is one
#    rung behind or four hundred minutes behind.
# BH-1457 added `retired=` beside the count and `rebuilds=` / `budget_carry=`
# beside the reason; the four lines below are compared whole, so they carry the
# new fields at the values a tick with nothing finished and no carry produces.
# ============================================================================
CLEAN; JOBS_OK
A4=$(ANCHOR)
ROWADD "o/p1#31" "$((A4 - 8000))" "$MFT" "https://github.com/o/p1/pull/31"
ROWADD "o/p2#32" "$((A4 - 4020))" "$MFT" "https://github.com/o/p2/pull/32"
BRENV=(BR_PER_TICK=1)
RUN
BRENV=()
case "$(LASTTICK)" in
  "tick: candidates=2 retired=0 carried=0 mechanical=0 families=0 llm_rungs=0 projects=2 visited=[p1] skipped=[p2] rungs=1/1 reason=budget secs="[0-9]*" rebuilds=1/4 budget_carry=0 oldest_untouched=67m") ok ;;
  *) bad "the budget tick must name the age of what it did not reach: '$(LASTTICK)'" ;;
esac
# A tick that reached everything has nothing untouched, and says so as "-" —
# never as 0m, which would read as "nothing is waiting".
CLEAN; JOBS_OK
A4=$(ANCHOR)
ROWADD "o/p1#31" "$((A4 - 8000))" "$MFT" "https://github.com/o/p1/pull/31"
ROWADD "o/p2#32" "$((A4 - 4020))" "$MFT" "https://github.com/o/p2/pull/32"
BRENV=(BR_PER_TICK=8)
RUN
BRENV=()
case "$(LASTTICK)" in
  "tick: candidates=2 retired=0 carried=0 mechanical=0 families=0 llm_rungs=0 projects=2 visited=[p1 p2] skipped=[] rungs=2/8 reason=drained secs="[0-9]*" rebuilds=2/4 budget_carry=0 oldest_untouched=-") ok ;;
  *) bad "a drained tick must print oldest_untouched=-: '$(LASTTICK)'" ;;
esac
# A row the PER-PROJECT share turned away was not touched either.
CLEAN; JOBS_OK
A4=$(ANCHOR)
ROWADD "o/p1#33" "$((A4 - 2400))" "$MFT" "https://github.com/o/p1/pull/33"
ROWADD "o/p1#34" "$((A4 - 1200))" "$MFT" "https://github.com/o/p1/pull/34"
BRENV=(BR_PER_TICK=4 BR_PER_TICK_P1=1)
RUN
BRENV=()
case "$(LASTTICK)" in
  "tick: candidates=2 retired=0 carried=0 mechanical=0 families=0 llm_rungs=0 projects=1 visited=[p1] skipped=[] rungs=1/4 reason=drained secs="[0-9]*" rebuilds=1/4 budget_carry=0 oldest_untouched=20m") ok ;;
  *) bad "a share-capped row counts as untouched: '$(LASTTICK)'" ;;
esac
# A SECOND COPY OF A TICKET THIS TICK ACTED ON IS NOT UNTOUCHED. Two rows for one
# PR key on two heads reach the drain as two candidates with ONE rkey: the first
# spends the rung, the second sits past the break, and counting its park age
# would age the lane by the very park it just worked on (140m, the second copy).
# The answer is the p2 row nobody reached.
CLEAN; JOBS_OK
A4=$(ANCHOR)
ROWADD "o/p1#35" "$((A4 - 9000))" "$MFT" "https://github.com/o/p1/pull/35" BLOCKED_HUMAN dead100
ROWADD "o/p1#35" "$((A4 - 8400))" "$MFT" "https://github.com/o/p1/pull/35" BLOCKED_HUMAN beef200
ROWADD "o/p2#36" "$((A4 - 600))" "$MFT" "https://github.com/o/p2/pull/36"
BRENV=(BR_PER_TICK=1)
RUN
BRENV=()
case "$(LASTTICK)" in
  "tick: candidates=3 retired=0 carried=0 mechanical=0 families=0 llm_rungs=0 projects=2 visited=[p1] skipped=[p2] rungs=1/1 reason=budget secs="[0-9]*" rebuilds=1/4 budget_carry=0 oldest_untouched=10m") ok ;;
  *) bad "a duplicate of a ticket this tick acted on must not be read as untouched: '$(LASTTICK)'" ;;
esac

# ============================================================================
# 5. SATURATION IS AN ALERT. K consecutive ticks that ended on the budget is a
#    lane that will never reach the back of its own list, and before this it was
#    indistinguishable in the log from a lane that is merely busy.
# ============================================================================
CLEAN; JOBS_OK
ROWADD "o/p1#1" "$((NOW - 3000))" "$MFT" "https://github.com/o/p1/pull/1"
ROWADD "o/p2#2" "$((NOW - 2000))" "$MFT" "https://github.com/o/p2/pull/2"
ROWADD "o/p3#3" "$((NOW - 1000))" "$MFT" "https://github.com/o/p3/pull/3"
BRENV=(BR_PER_TICK=0 BR_SATURATED_TICKS=3)
RUN
[ "$(NALERT 'SATURATED')" = 0 ] && ok || bad "one budget tick is not saturation: $(cat "$T/alerts.txt")"
RUN
[ "$(NALERT 'SATURATED')" = 0 ] && ok || bad "two budget ticks are not saturation either: $(cat "$T/alerts.txt")"
[ "$(STREAK)" = 2 ] && ok || bad "the streak must be counted on disk (got '$(STREAK)'; file: $(cat "$SATF" 2>/dev/null))"
RUN
[ "$(NALERT 'SATURATED')" = 1 ] && ok \
  || bad "THE BUG: K consecutive budget ticks must page once: $(cat "$T/alerts.txt")"
grep -q '3 consecutive' "$T/alerts.txt" && ok \
  || bad "the page must say how long it has been saturated: $(cat "$T/alerts.txt")"
grep -q 'candidates=3' "$T/alerts.txt" && ok \
  || bad "the page must name the candidate count: $(cat "$T/alerts.txt")"
grep -q 'BR_PER_TICK=0' "$T/alerts.txt" && ok \
  || bad "the page must name the budget: $(cat "$T/alerts.txt")"
grep -q 'nothing is ever touched' "$T/alerts.txt" && ok \
  || bad "with a budget of 0 the page must say so instead of dividing by it: $(cat "$T/alerts.txt")"
grep -q 'skipped=\[p1 p2 p3\]' "$T/alerts.txt" && ok \
  || bad "the page must name what it skipped: $(cat "$T/alerts.txt")"
[ -e "$SATMARK" ] && ok || bad "the marker the conductor reads must exist while saturated"
RUN; RUN
[ "$(NALERT 'SATURATED')" = 1 ] && ok \
  || bad "a streak already paged must not page again: $(cat "$T/alerts.txt")"
# A tick that ends for any other reason ends the episode.
BRENV=(BR_PER_TICK=8 BR_SATURATED_TICKS=3)
RUN
[ ! -e "$SATMARK" ] && ok || bad "a drained tick must remove the marker"
[ "$(STREAK)" = 0 ] && ok || bad "a drained tick resets the streak (got '$(STREAK)')"
# ...and the NEXT streak pages again.
BRENV=(BR_PER_TICK=0 BR_SATURATED_TICKS=3)
RUN; RUN; RUN
[ "$(NALERT 'SATURATED')" = 2 ] && ok \
  || bad "a second streak must page again: $(cat "$T/alerts.txt")"
# An IDLE tick has no candidates at all, so it is not a saturated one.
: > "$ROWS"
RUN
[ "$(STREAK)" = 0 ] && ok || bad "an idle tick resets the streak (got '$(STREAK)')"
[ ! -e "$SATMARK" ] && ok || bad "an idle tick removes the marker"
BRENV=()
# 5b. THE PAGE NAMES WHERE THE RUNGS WENT. Two p1 rows and one p2 row, one rung
#     a tick: over a two-tick streak both projects have spent one.
CLEAN; JOBS_OK
ROWADD "o/p1#1"  "$((NOW - 3000))" "$MFT" "https://github.com/o/p1/pull/1"
ROWADD "o/p1#11" "$((NOW - 2500))" "$MFT" "https://github.com/o/p1/pull/11"
ROWADD "o/p2#2"  "$((NOW - 2000))" "$MFT" "https://github.com/o/p2/pull/2"
BRENV=(BR_PER_TICK=1 BR_SATURATED_TICKS=2)
RUN; RUN
BRENV=()
[ "$(NALERT 'SATURATED')" = 1 ] && ok || bad "the consumers case must page once: $(cat "$T/alerts.txt")"
grep -q 'p1:1' "$T/alerts.txt" && ok \
  || bad "the page must name p1 as a rung consumer: $(cat "$T/alerts.txt")"
grep -q 'p2:1' "$T/alerts.txt" && ok \
  || bad "the page must name p2 as a rung consumer: $(cat "$T/alerts.txt")"

# ============================================================================
# 7. A TERMINAL COSTS NO RUNG. The budget counts rungs, and a row that answers
#    "there is nothing to do here" took none — a park at a terminal at the top
#    of the list must not be a project's whole tick.
# ============================================================================
CLEAN; JOBS_OK
mkdir -p "$H/state/blocked-resolver/p1"
jq -nc --arg fp "merge-failed-twice|https://github.com/o/p1/pull/21|-|abc123" \
  '{project:"p1",rkey:"p1-TK-21",rebuilds:0,fixrounds:0,mechanicals:0,
    outcome:"STALLED",stalled_fp:$fp,attempts:[]}' \
  > "$H/state/blocked-resolver/p1/p1-TK-21.json"
ROWADD "o/p1#21" "$((NOW - 3000))" "$MFT" "https://github.com/o/p1/pull/21"
ROWADD "o/p2#22" "$((NOW - 2000))" "$MFT" "https://github.com/o/p2/pull/22"
BRENV=(BR_PER_TICK=4)
RUN
BRENV=()
case "$(LASTTICK)" in
  *"rungs=1/4"*) ok ;;
  *) bad "THE BUG: a stalled park must cost no rung: '$(LASTTICK)'" ;;
esac
case "$(LASTTICK)" in
  *"visited=[p1 p2]"*) ok ;;
  *) bad "a stalled project was still looked at, so it is not starved: '$(LASTTICK)'" ;;
esac
ACTED p1 21 && bad "a stalled park must enqueue nothing: $(cat "$T/queue.txt")" || ok
ACTED p2 22 && ok || bad "the live row must still get its rung (queue: $(cat "$T/queue.txt"))"
# An ABANDONED record is a terminal too, and it used to cost a rung.
CLEAN; JOBS_OK
mkdir -p "$H/state/blocked-resolver/p3"
jq -nc '{project:"p3",rkey:"p3-TK-23",rebuilds:3,outcome:"ABANDONED",attempts:[]}' \
  > "$H/state/blocked-resolver/p3/p3-TK-23.json"
ROWADD "o/p3#23" "$((NOW - 3000))" "$MFT" "https://github.com/o/p3/pull/23"
ROWADD "o/p2#22" "$((NOW - 2000))" "$MFT" "https://github.com/o/p2/pull/22"
BRENV=(BR_PER_TICK=4)
RUN
BRENV=()
case "$(LASTTICK)" in
  *"rungs=1/4"*) ok ;;
  *) bad "an ABANDONED record must cost no rung either: '$(LASTTICK)'" ;;
esac
# ...and a stalled park whose ROW CHANGES comes straight back.
CLEAN; JOBS_OK
mkdir -p "$H/state/blocked-resolver/p1"
jq -nc --arg fp "merge-failed-twice|https://github.com/o/p1/pull/21|-|abc123" \
  '{project:"p1",rkey:"p1-TK-21",rebuilds:0,fixrounds:0,mechanicals:0,
    outcome:"STALLED",stalled_fp:$fp,attempts:[]}' \
  > "$H/state/blocked-resolver/p1/p1-TK-21.json"
ROWADD "o/p1#21" "$((NOW - 3000))" "$MFT" "https://github.com/o/p1/pull/21" BLOCKED_HUMAN feed1ce
BRENV=(BR_PER_TICK=4)
RUN
BRENV=()
ACTED p1 21 && ok \
  || bad "a stalled park whose head moved must run again (queue: $(cat "$T/queue.txt"); log: $(LOG | tail -4))"
grep -q 'stall-cleared' <<<"$(STATEJSON p1 p1-TK-21 | jq -c '[.attempts[].action]')" && ok \
  || bad "and the clearing must be recorded (attempts: $(STATEJSON p1 p1-TK-21 | jq -c '[.attempts[].action]'))"

# ============================================================================
# 6. THE CONDUCTOR REFERENCES THE ALERT INSTEAD OF RE-HANDING OFF — on the page
#    a person receives (mc_stuck_check, read back from the arguments it handed
#    bin/lane-alert.sh) as well as in the re-kick's log line. Run LAST and in a
#    subshell: it sources bin/lib/merge-conductor-lib.sh into the shell, which
#    would otherwise shadow helpers the sections above rely on.
# ============================================================================
(
  PASS=0; FAIL=0
  export HARNESS="$H"
  # shellcheck source=/dev/null
  . "$H/bin/lib/merge-conductor-lib.sh"
  mc_init
  ACTIONS=1; MERGES=0
  eval "$(sed -n '/^stuck_rekick() {/,/^}/p' "$H/bin/lib/mc/classify.sh")"
  type stuck_rekick >/dev/null 2>&1 && ok \
    || bad "stuck_rekick did not extract from bin/lib/mc/classify.sh — the rest of section 6 proves nothing"
  SLUG=o/p1; NUM=41; KEY="$SLUG#$NUM"; URL="https://github.com/$SLUG/pull/$NUM"
  OLD=1111111111111111111111111111111111111111
  mc_row_put "$KEY" BLOCKED_HUMAN "$((NOW - 9000))" "$OLD" "$OLD" - merge-failed-twice "$URL"
  HF=$(mc_handoff_file "$KEY"); mkdir -p "$(dirname "$HF")"
  HANDOFF_SEED() { printf '12345\t%s\t%s\t%s\n' "$OLD" merge-failed-twice "$URL" > "$HF"; }
  HFIRST() { cut -f1 "$HF" 2>/dev/null; }
  LASTLOG() { tail -1 "$MC_LOG" 2>/dev/null; }

  mkdir -p "$H/state/blocked-resolver"
  : > "$H/state/blocked-resolver/.saturated"
  HANDOFF_SEED
  stuck_rekick "$KEY" BLOCKED_HUMAN merge-failed-twice "$SLUG" "$NUM" "$URL" "$OLD" CLEAN MERGEABLE main main none
  [ "$(HFIRST)" = 12345 ] && ok \
    || bad "THE BUG: while the resolver is saturated the hand-off record must stand (first field '$(HFIRST)')"
  case "$(LASTLOG)" in
    *SATURATED*"not re-handed off"*) ok ;;
    *) bad "the re-kick line must say why it stood down: '$(LASTLOG)'" ;;
  esac
  # Marker gone: today's branch, byte for byte.
  rm -f "$H/state/blocked-resolver/.saturated"
  HANDOFF_SEED
  stuck_rekick "$KEY" BLOCKED_HUMAN merge-failed-twice "$SLUG" "$NUM" "$URL" "$OLD" CLEAN MERGEABLE main main none
  [ "$(HFIRST)" != 12345 ] && ok \
    || bad "with no marker the park must be offered fresh (first field '$(HFIRST)')"
  case "$(LASTLOG)" in
    *"offered fresh"*) ok ;;
    *) bad "and the log must say so: '$(LASTLOG)'" ;;
  esac
  # THE PAGE ITSELF, not the log next to it. The ask is that the per-PR STUCK
  # PAGE reference the saturation alert, and the page is what mc_stuck_check
  # hands bin/lane-alert.sh — a line in logs/merge-conductor.log is the durable
  # record, not the thing a person receives. One (PR, state, head) pages once, so
  # each case below uses its own key.
  PAGES() { grep -c 'STUCK: ' "$T/alerts.txt" 2>/dev/null; }
  LASTPAGE() { grep 'STUCK: ' "$T/alerts.txt" 2>/dev/null | tail -1; }
  : > "$T/alerts.txt"
  : > "$H/state/blocked-resolver/.saturated"
  mc_stuck_check "$SLUG#71" BLOCKED_HUMAN "$((NOW - 9000))" "$OLD" "$URL" merge-failed-twice \
    && ok || bad "a park 150m past its 120m TTL must page"
  [ "$(PAGES)" = 1 ] && ok || bad "the stuck page must reach bin/lane-alert.sh once: $(cat "$T/alerts.txt")"
  case "$(LASTPAGE)" in
    *"waiting on bin/blocked-resolver.sh to drain the park"*"is SATURATED"*"logs/ALERTS.log"*) ok ;;
    *) bad "THE PAGE must point at the SATURATED alert, not only the log: '$(LASTPAGE)'" ;;
  esac
  # Same park, no marker: the page is the one it has always been.
  rm -f "$H/state/blocked-resolver/.saturated"
  : > "$T/alerts.txt"
  mc_stuck_check "$SLUG#72" BLOCKED_HUMAN "$((NOW - 9000))" "$OLD" "$URL" merge-failed-twice \
    && ok || bad "the same park must still page with no marker"
  case "$(LASTPAGE)" in
    *SATURATED*) bad "with no marker the page must carry nothing extra: '$(LASTPAGE)'" ;;
    *"waiting on bin/blocked-resolver.sh to drain the park"*) ok ;;
    *) bad "and it must still name what the park is waiting on: '$(LASTPAGE)'" ;;
  esac
  # A state the resolver does not own is not about this lane's budget at all.
  : > "$H/state/blocked-resolver/.saturated"
  : > "$T/alerts.txt"
  mc_stuck_check "$SLUG#73" WAIT_CI "$((NOW - 9000))" "$OLD" "$URL" "checks pending" \
    && ok || bad "a WAIT_CI row past its TTL must page"
  case "$(LASTPAGE)" in
    *SATURATED*) bad "only a resolver park takes the clause: '$(LASTPAGE)'" ;;
    *) ok ;;
  esac
  rm -f "$H/state/blocked-resolver/.saturated"
  # A reason no lane owns takes neither branch, marker or no marker.
  : > "$H/state/blocked-resolver/.saturated"
  HANDOFF_SEED
  stuck_rekick "$KEY" BLOCKED_HUMAN tightened "$SLUG" "$NUM" "$URL" "$OLD" CLEAN MERGEABLE main main none
  case "$(LASTLOG)" in
    *"no lane owns this reason"*) ok ;;
    *) bad "an unowned reason must keep its own line: '$(LASTLOG)'" ;;
  esac
  [ "$(HFIRST)" = 12345 ] && ok \
    || bad "and must rewrite nothing (first field '$(HFIRST)')"
  rm -f "$H/state/blocked-resolver/.saturated"
  printf '%s %s\n' "$PASS" "$FAIL" > "$T/s6.counts"
)
if [ -s "$T/s6.counts" ]; then
  read -r P6 F6 < "$T/s6.counts"
  PASS=$((PASS + P6)); FAIL=$((FAIL + F6))
else
  bad "section 6 did not run to completion"
fi

[ "$(grep -c 'Broken pipe' "$T/run.log")" = 0 ] && ok \
  || bad "no tick in this file may log a Broken pipe: $(grep -n 'Broken pipe' "$T/run.log" | head -3)"

echo "blocked-resolver.bh-1122: PASS $PASS FAIL $FAIL"
[ "$FAIL" -eq 0 ]
