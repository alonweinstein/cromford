#!/bin/bash
# tests/blocked-resolver-prepass.bh-1457-test.sh — BH-1457: the deterministic
# pre-pass that runs before any rung, the cheapest-rung-first order, the
# per-tick rebuild cap, and the bounded tick with a carried rung budget.
#
# THE CENSUS THIS PINS (hub, 2026-09-22 14:1xZ). bin/blocked-resolver.sh
# reported candidates=785 on every tick and ended every one of them on
# reason=budget. state/blocked-resolver held 586 records, and 90 rebuild-landed
# + 98 RESOLVED_MERGED + 79 ABANDONED of them were FINISHED rows still being
# offered — a merged park still costs a PER_TICK slot and a handful of REST
# reads before br_already_merged answers. One PR per rung, in source order, so
# the most expensive rung on the board (REBUILD FRESH: plan + execute + review,
# a whole pool build) was as likely to go first as a one-call adjudication. And
# the 14:04Z tick ran 12 rungs in 53 MINUTES, during which every ten-minute
# cron was skipped as "previous run still active" — so raising BR_PER_TICK
# traded tick length for throughput instead of buying any.
#
# WHAT IS DRIVEN. Every section runs the real bin/blocked-resolver.sh end to end
# against a scratch $HARNESS: real conductor rows, a real state tree, a recorded
# jobs client, a recorded bin/agent-call.sh and a recorded bin/lane-alert.sh.
# Nothing here greps the source of the lane. Every assertion is a queue row, a
# state json field, a recorded call, or a line the run wrote to its own log —
# and the rung ORDER is read off the `-> <action>` dispatch lines the run
# printed, which is an artifact of the run and not of anybody's typing.
#
# Run from anywhere: tests/blocked-resolver-prepass.bh-1457-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh): every fixture
# age below is derived from it, so a row that is "an hour old" is an hour old by
# construction whatever the wall clock says.
NOW=$(date -u +%s)

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$T/fakebin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$H/bin/"
# BH-1176: the lane sources bin/lib/br/ and REFUSES the tick when a module is
# missing, so the modules travel with the copy.
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/rebuild-ledger.sh" "$DIR/bin/lib/hold.sh" "$DIR/bin/lib/gh-rest.sh" "$H/bin/lib/"
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
chmod +x "$H/bin/"*.sh
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
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf 'call %s %s %s\n' "\$1" "\$2" "\$5" >> "$T/agent.txt"
printf 'the reasoning, such as it was\n%s\n' "\${ADJ_VERDICT:-REJECT}" > "\$5"
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"
: > "$T/agent.txt"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
: > "$T/alerts.txt"

# The gh stub. $T/slowgh makes DISCOVERY expensive on purpose: section 5 needs a
# tick whose wall budget is already gone before the FIRST rung is dispatched,
# which is the only way to prove "a tick always takes at least one rung".
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
[ -e "$T/slowgh" ] && sleep 1
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pull|pulls|issues)/([0-9]+).*#\2#p' | head -1)
case "\$*" in
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
  *"--json state"*) cat "$T/prstate" 2>/dev/null || echo OPEN ;;
  *"/pulls/"*)             echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/ts-\$N" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
: > "$T/gh.txt"; : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/comments.txt"
: > "$T/queue-attempts.txt"
: > "$T/ssh.txt"; : > "$T/run.log"
echo OPEN > "$T/prstate"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ssh.txt"\nexit 0\n' "$T" > "$T/fakebin/br-ssh"
chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
# NO REAL CREDENTIAL REACHES THIS RUN (the rule tests/blocked-resolver-test.sh holds).
export GH_TOKEN=""

# The jobs client. SLOW is the same client with a one-second enqueue, so a
# REBUILD rung costs measurable wall clock and section 5 can bound a tick
# between rungs without reading a clock into any assertion.
JOBS_OK() { cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
}
# The queue answers, and refuses. A REFUSED enqueue runs the rung and buys no
# pool build, which is the difference section 9 is about.
JOBS_FAIL() { cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf 'REFUSED %s\n' "\$*" >> "$T/queue-attempts.txt"; return 1; }
queue_done() { return 0; }
queue_list() { return 1; }
EOF
}
JOBS_SLOW() { cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { sleep 1; printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
}
# A QUEUE-SOURCE candidate: br_from_queue reads `queue_list "" failed` and turns
# a "died twice" row into pool-died-twice. It is the shape that matters here —
# the queue, build, rebuild and reviews sources all emit a row with no url and
# no park age, and until BH-1457's review none of them filled the eighth field.
QUEUE_ROWS=""
JOBS_QUEUE() { cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { printf '%s\n' "$1"; }
EOF
}
# CMT/CMTS: one REST comment array, the shape bin/lib/hold.sh classifies.
CMT() { jq -nc --arg b "$1" --arg c "$(date -u -d "@$((NOW - ${2:-3600}))" '+%Y-%m-%dT%H:%M:%SZ')" \
          '{body:$b,created_at:$c,user:{type:"User"}}'; }
HOLDCMT() { printf '[%s]' "$(CMT 'HOLD — the operator: do not rebuild this.' 3600)" > "$T/comments-$1.json"; }
for I in 1 2 3; do touch "$H/flags/fly-pool-p$I"; done
touch "$H/flags/fly-pool-tproj"
JOBS_OK

ROWS="$H/state/merge-conductor/pr-state.tsv"
ST="$H/state/blocked-resolver"
BRENV=()
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH="$T/fakebin/br-ssh" env ${BRENV[*]:+"${BRENV[@]}"} \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || true; }
# ROWADD <key> <since> <why> <url> [state] [head] — one conductor hand-off row.
ROWADD() { printf '%s\t%s\t%s\t%s\t%s\t-\t%s\t%s\n' \
             "$1" "${5:-BLOCKED_HUMAN}" "$2" "${6:-abc123}" "${6:-abc123}" "$3" "$4" >> "$ROWS"; }
STATEJSON() { cat "$ST/$1/$2.json" 2>/dev/null; }
# SEED <project> <key> <json> — a state record as an earlier tick left it.
SEED() { mkdir -p "$ST/$1"; printf '%s\n' "$3" | jq -c \
           --arg p "$1" --arg k "$2" '.project=$p | .rkey=$k' > "$ST/$1/$2.json"; }
LOG() { cat "$H/logs/blocked-resolver.log" 2>/dev/null; }
LASTTICK() { grep 'tick: candidates=' "$H/logs/blocked-resolver.log" \
             | tail -1 | sed -E 's/^[0-9-]+ [0-9:]+Z //'; }
TICKLINE() { grep 'tick: candidates=' "$H/logs/blocked-resolver.log" \
             | sed -n "${1}p" | sed -E 's/^[0-9-]+ [0-9:]+Z //'; }
# FIELD <n> <name> — one `name=value` field of the nth tick line.
FIELD() { TICKLINE "$1" | sed -nE "s/.*(^| )$2=([^ ]*).*/\2/p"; }
LFIELD() { LASTTICK | sed -nE "s/.*(^| )$1=([^ ]*).*/\2/p"; }
# ORDER — the rungs this run DISPATCHED, in the order it dispatched them.
ORDER() { grep -oE '\-> (mechanical|regen|fix-round|rebuild-fresh|rebuild-retry|adjudicate|re-review|abandon-rebuild)' \
            "$H/logs/blocked-resolver.log" 2>/dev/null | sed 's/-> //' | tr '\n' ' '; }
NQUEUED() { grep -c '^[a-z0-9]* TK-[0-9]* [0-9]* fly ' "$T/queue.txt" 2>/dev/null; }
NAGENT() { grep -c . "$T/agent.txt" 2>/dev/null; }
NLINES() { grep -c "$1" "$H/logs/blocked-resolver.log" 2>/dev/null; }
CLEAN() { scratch_rm "$ST" 2>/dev/null
          scratch_rm "$H/state/merge-conductor/handoff" 2>/dev/null
          scratch_rm "$H/state/merge-conductor/handoff-released" 2>/dev/null
          : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/gh.txt"; : > "$T/ssh.txt"
          : > "$T/queue-attempts.txt"
          : > "$T/alerts.txt"; : > "$T/agent.txt"; : > "$T/comments.txt"
          : > "$H/logs/blocked-resolver.log"; rm -f "$H/logs/ALERTS.log"
          rm -f "$T/slowgh"; echo OPEN > "$T/prstate"; JOBS_OK
          : > "$ROWS"; }

ISSUE() {  # ISSUE <number> <labels-csv>
  local labels="[]"
  [ -n "${2:-}" ] && labels=$(printf '%s' "$2" | jq -Rc 'split(",")|map({name:.})')
  jq -nc --argjson n "$1" --argjson l "$labels" --arg t "TK-$1: a parked ticket" \
         --arg c "$(date -u -d "@$((NOW - 604800))" '+%Y-%m-%dT%H:%M:%SZ')" \
         '{number:$n,state:"open",labels:$l,title:$t,body:"## Scope",created_at:$c}'
}
for N in $(seq 1 40); do
  ISSUE "$N" ai-build > "$T/issue-$N.json"
  echo '[]' > "$T/comments-$N.json"
done

# The four reasons this file drives, one per cost band, chosen because each
# dispatches a DIFFERENT rung out of br_action/br_ladder_rung with no record
# pre-seeded:
#   conflict-unresolvable  -> ladder/rebase-conflict -> mechanical   (free)
#   iron-law               -> adjudicate                             (one call)
#   head-not-reapproved    -> ladder/review-blocked  -> fix-round    (an agent round)
#   merge-failed-twice     -> rebuild-fresh                          (a pool build)
CONFLICT="conflict-unresolvable: CONFLICT (content): Merge conflict in src/a.ts"
IRONLAW="iron-law: hardcoded claude-opus-5 in src/agent.ts"
NOREAPPROVE="head-not-reapproved: the head moved after the approval"
MFT="merge-failed-twice: gh pr merge refused"

# ============================================================================
# 1. A FINISHED ROW IS RETIRED BEFORE ANYTHING IS SPENT. An ABANDONED record is
#    already terminal inside br_one (rc 3, no rung) — but the row is still
#    discovered, still counted, still read, and still offered on every tick for
#    ever. The pre-pass drops it from the list and says so ONCE.
# ============================================================================
CLEAN
SEED tproj tproj-TK-9 '{"outcome":"ABANDONED","rebuilds":3,"fixrounds":1,"mechanicals":1,"attempts":[]}'
ROWADD "o/tproj#9" "$NOW" "$MFT" "https://github.com/o/tproj/pull/9"
RUN
[ "$(LFIELD retired)" = 1 ] && ok \
  || bad "1: an ABANDONED row must be retired before any rung (tick: $(LASTTICK))"
[ "$(NQUEUED)" = 0 ] && ok || bad "1: a retired row buys nothing (queue: $(cat "$T/queue.txt"))"
[ "$(NLINES 'EVENT resolver_retired')" = 1 ] && ok \
  || bad "1: the retirement is one event line (log: $(LOG | tail -5))"
[ "$(STATEJSON tproj tproj-TK-9 | jq -r '.retired // false')" = true ] && ok \
  || bad "1: the record must remember it was retired (got '$(STATEJSON tproj tproj-TK-9 | jq -c .)')"

# 1b. AND IT SAYS SO ONCE. The row is still discovered next tick and still
#     retired; a line per row per tick would be 270 lines every ten minutes.
RUN
[ "$(LFIELD retired)" = 1 ] && ok \
  || bad "1b: the row stays retired on the next tick (tick: $(LASTTICK))"
[ "$(NLINES 'EVENT resolver_retired')" = 1 ] && ok \
  || bad "1b: and it is not re-announced (retired events: $(NLINES 'EVENT resolver_retired'))"

# 1c. A RESOLVED_MERGED RECORD WHOSE resolved_url IS THIS CANDIDATE'S is retired.
CLEAN
SEED tproj tproj-TK-8 '{"outcome":"RESOLVED_MERGED","resolved_url":"https://github.com/o/tproj/pull/8","attempts":[]}'
ROWADD "o/tproj#8" "$NOW" "$MFT" "https://github.com/o/tproj/pull/8"
RUN
[ "$(LFIELD retired)" = 1 ] && ok \
  || bad "1c: a resolved park whose url matches must be retired (tick: $(LASTTICK))"
[ "$(NQUEUED)" = 0 ] && ok || bad "1c: and buys nothing (queue: $(cat "$T/queue.txt"))"

# 1d. A DIFFERENT URL UNDER A RESOLVED TICKET IS A NEW PR, NOT A FINISHED ROW.
#     The rebuild a merged ticket does not need is br_already_merged's call to
#     refuse, on the repo's own answer — never this pre-pass's, on a url that
#     does not match.
CLEAN
SEED tproj tproj-TK-7 '{"outcome":"RESOLVED_MERGED","resolved_url":"https://github.com/o/tproj/pull/700","attempts":[]}'
ROWADD "o/tproj#7" "$NOW" "$MFT" "https://github.com/o/tproj/pull/7"
RUN
[ "$(LFIELD retired)" = 0 ] && ok \
  || bad "1d: a NEW PR under a resolved ticket must not be retired (tick: $(LASTTICK))"
[ "$(LFIELD rungs)" = "1/4" ] && ok \
  || bad "1d: and it must still be dispatched, so br_already_merged decides it (tick: $(LASTTICK))"

# 1e. A RECORD WRITTEN BEFORE THIS CHANGE carries no resolved_url. A candidate
#     with a url is NOT retired off it — absent is not "the same PR" (D11).
CLEAN
SEED tproj tproj-TK-6 '{"outcome":"RESOLVED_MERGED","attempts":[]}'
ROWADD "o/tproj#6" "$NOW" "$MFT" "https://github.com/o/tproj/pull/6"
RUN
[ "$(LFIELD retired)" = 0 ] && ok \
  || bad "1e: an old resolved record must not retire a url-carrying candidate (tick: $(LASTTICK))"

# 1f. THE RETIRED ROW FREES ITS SLOT. One abandoned row in front of one live row
#     and a budget of one: the LIVE row gets the rung.
CLEAN
SEED p1 p1-TK-11 '{"outcome":"ABANDONED","attempts":[]}'
ROWADD "o/p1#11" "$((NOW - 8000))" "$MFT" "https://github.com/o/p1/pull/11"
ROWADD "o/p1#12" "$((NOW - 7000))" "$MFT" "https://github.com/o/p1/pull/12"
BRENV=(BR_PER_TICK=1)
RUN
BRENV=()
grep -q '^p1 TK-12 12 fly ' "$T/queue.txt" && ok \
  || bad "1f: the live row must get the tick's only rung (queue: $(cat "$T/queue.txt"))"

# 1g. THE RESOLVE WRITES THE URL IT RESOLVED. Without it the retire above can
#     never become true for a park this lane resolves from here on.
CLEAN
echo MERGED > "$T/prstate"
ROWADD "o/tproj#5" "$NOW" "$MFT" "https://github.com/o/tproj/pull/5"
RUN
echo OPEN > "$T/prstate"
[ "$(STATEJSON tproj tproj-TK-5 | jq -r '.outcome // ""')" = RESOLVED_MERGED ] && ok \
  || bad "1g: a merged park must still resolve (record: $(STATEJSON tproj tproj-TK-5 | jq -c '{outcome}'))"
[ "$(STATEJSON tproj tproj-TK-5 | jq -r '.resolved_url // ""')" = "https://github.com/o/tproj/pull/5" ] && ok \
  || bad "1g: and record WHICH url it resolved (got '$(STATEJSON tproj tproj-TK-5 | jq -r '.resolved_url // ""')')"

# ============================================================================
# 2. THE CHEAPEST RUNG GOES FIRST. Source order used to decide, so a pool build
#    was as likely to go first as a one-call adjudication.
# ============================================================================
CLEAN
# Offered in the WORST order: the pool build first, the free rung last.
ROWADD "o/p1#21" "$NOW" "$MFT"         "https://github.com/o/p1/pull/21"
ROWADD "o/p1#22" "$NOW" "$NOREAPPROVE" "https://github.com/o/p1/pull/22"
ROWADD "o/p1#23" "$NOW" "$IRONLAW"     "https://github.com/o/p1/pull/23"
ROWADD "o/p1#24" "$NOW" "$CONFLICT"    "https://github.com/o/p1/pull/24"
BRENV=(BR_PER_TICK=1)
RUN
BRENV=()
[ "$(ORDER)" = "mechanical " ] && ok \
  || bad "2: the free rung must go first (order: '$(ORDER)'; tick: $(LASTTICK))"

# 2b. THEN THE ONE-CALL RUNG, THEN THE AGENT ROUND, THEN THE POOL BUILD.
CLEAN
ROWADD "o/p1#21" "$NOW" "$MFT"         "https://github.com/o/p1/pull/21"
ROWADD "o/p1#22" "$NOW" "$NOREAPPROVE" "https://github.com/o/p1/pull/22"
ROWADD "o/p1#23" "$NOW" "$IRONLAW"     "https://github.com/o/p1/pull/23"
ROWADD "o/p1#24" "$NOW" "$CONFLICT"    "https://github.com/o/p1/pull/24"
BRENV=(BR_PER_TICK=4 BR_PER_TICK_P1=4)
RUN
BRENV=()
[ "$(ORDER)" = "mechanical adjudicate fix-round rebuild-fresh " ] && ok \
  || bad "2b: THE BUG: rungs must run cheapest first (order: '$(ORDER)')"

# 2c. THE COST IS READ OFF THE TICKET'S OWN COUNTERS, not off the reason word: a
#     conflict whose mechanical rung is already spent IS a fix round and must
#     sort as one, behind the adjudication.
CLEAN
SEED p1 p1-TK-25 '{"outcome":"","mechanicals":1,"fixrounds":0,"attempts":[]}'
ROWADD "o/p1#25" "$NOW" "$CONFLICT" "https://github.com/o/p1/pull/25"
ROWADD "o/p1#23" "$NOW" "$IRONLAW"  "https://github.com/o/p1/pull/23"
BRENV=(BR_PER_TICK=1)
RUN
BRENV=()
[ "$(ORDER)" = "adjudicate " ] && ok \
  || bad "2c: a spent mechanical rung must sort as the fix round it is (order: '$(ORDER)')"

# 2d. RANK BEATS COST. A hotfix-ranked park still goes first even when it is the
#     most expensive rung on the board — the priority contract (#643) is a
#     separate question from what a rung costs.
CLEAN
ISSUE 26 ai-build,hotfix > "$T/issue-26.json"
ROWADD "o/p1#26" "$NOW" "$MFT"     "https://github.com/o/p1/pull/26"
ROWADD "o/p1#23" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/23"
BRENV=(BR_PER_TICK=1)
RUN
BRENV=()
ISSUE 26 ai-build > "$T/issue-26.json"
if [ "$(ORDER)" = "rebuild-fresh " ]; then ok
elif [ "$(NLINES 'hotfix')" = 0 ] && [ "$(ORDER)" = "adjudicate " ]; then ok   # no hotfix-lib on this box
else bad "2d: a hotfix park must outrank a cheaper one (order: '$(ORDER)')"; fi

# ============================================================================
# 3. A TICK'S RUNG BUDGET IS NOT A POOL-BUILD BUDGET. BR_PER_TICK was raised to
#    50 on the hub, and 50 rungs could mean 50 fresh pool builds.
# ============================================================================
CLEAN
for N in 31 32 33 34 35 36; do
  ROWADD "o/p1#$N" "$NOW" "$MFT" "https://github.com/o/p1/pull/$N"
done
BRENV=(BR_PER_TICK=6 BR_PER_TICK_P1=6 BR_REBUILDS_PER_TICK=2)
RUN
BRENV=()
[ "$(NQUEUED)" = 2 ] && ok \
  || bad "3: THE BUG: BR_REBUILDS_PER_TICK must bound the pool builds (queued: $(NQUEUED); queue: $(cat "$T/queue.txt"))"
[ "$(LFIELD rebuilds)" = "2/2" ] && ok \
  || bad "3: and the tick line must say so (tick: $(LASTTICK))"

# 3b. A CAPPED PARK COSTS NO SLOT AND IS NOT TOUCHED. The cheap rung behind it
#     still runs in the same tick, and nothing was closed or recorded for the
#     parks the cap turned away.
CLEAN
for N in 31 32 33; do
  ROWADD "o/p1#$N" "$NOW" "$MFT" "https://github.com/o/p1/pull/$N"
done
ROWADD "o/p1#23" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/23"
BRENV=(BR_PER_TICK=2 BR_PER_TICK_P1=2 BR_REBUILDS_PER_TICK=1)
RUN
BRENV=()
[ "$(NQUEUED)" = 1 ] && ok || bad "3b: one rebuild only (queue: $(cat "$T/queue.txt"))"
[ "$(NAGENT)" = 1 ] && ok \
  || bad "3b: the adjudication behind it must still get its rung (agent calls: $(NAGENT))"
[ "$(grep -c . "$T/closed.txt")" = 1 ] && ok \
  || bad "3b: only the rebuild that RAN may close a PR (closed: $(cat "$T/closed.txt"))"
[ -z "$(STATEJSON p1 p1-TK-33)" ] && ok \
  || bad "3b: a capped park writes no record (got: $(STATEJSON p1 p1-TK-33 | jq -c .))"

# 3c. AND ITS HAND-OFF IS NOT RELEASED. A released hand-off hands the PR back to
#     the conductor to classify and re-park over a question no rung ever asked.
[ ! -e "$H/state/merge-conductor/handoff-released/o-p1-33" ] && ok \
  || bad "3c: a capped park must keep its hand-off (released: $(ls "$H/state/merge-conductor/handoff-released" 2>/dev/null))"

# 3d. ZERO IS OFF: no rebuild rung fires at all, and the cheap rungs still run.
CLEAN
ROWADD "o/p1#31" "$NOW" "$MFT"     "https://github.com/o/p1/pull/31"
ROWADD "o/p1#23" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/23"
BRENV=(BR_PER_TICK=4 BR_PER_TICK_P1=4 BR_REBUILDS_PER_TICK=0)
RUN
BRENV=()
[ "$(NQUEUED)" = 0 ] && ok || bad "3d: 0 must buy no pool build (queue: $(cat "$T/queue.txt"))"
[ "$(NAGENT)" = 1 ] && ok || bad "3d: and must not stop the cheap rungs (agent calls: $(NAGENT))"

# 3e. THE DEFAULT IS TODAY'S DEFAULT BUDGET, so a hub at defaults is unchanged:
#     four rebuild parks, BR_PER_TICK=4, no knob set — four pool builds.
CLEAN
for N in 31 32 33 34; do
  ROWADD "o/p1#$N" "$NOW" "$MFT" "https://github.com/o/p1/pull/$N"
done
BRENV=(BR_PER_TICK=4 BR_PER_TICK_P1=4)
RUN
BRENV=()
[ "$(NQUEUED)" = 4 ] && ok \
  || bad "3e: the default cap must not bite a hub at default budget (queued: $(NQUEUED))"

# ============================================================================
# 4. THE TICK IS BOUNDED IN WALL CLOCK, and the rung budget it did not spend is
#    carried. The 14:04Z hub tick ran 12 rungs in 53 minutes and every cron in
#    between was skipped as "previous run still active".
# ============================================================================
CLEAN; JOBS_SLOW
for N in 31 32 33; do
  ROWADD "o/p1#$N" "$NOW" "$MFT" "https://github.com/o/p1/pull/$N"
done
BRENV=(BR_PER_TICK=3 BR_PER_TICK_P1=3 BR_TICK_MAX_SECS=1)
RUN
BRENV=(); JOBS_OK
[ "$(LFIELD reason)" = tick-budget ] && ok \
  || bad "4: THE BUG: a tick must end on its wall budget (tick: $(LASTTICK))"
[ "$(NQUEUED)" = 1 ] && ok \
  || bad "4: and stop starting rungs (queued: $(NQUEUED); tick: $(LASTTICK))"

# 4b. A TICK ALWAYS TAKES AT LEAST ONE RUNG. With discovery alone over the
#     budget, a cap read before the guard would make this lane do nothing, for
#     ever, and look exactly like a quiet tick.
CLEAN
touch "$T/slowgh"
ROWADD "o/p1#31" "$NOW" "$MFT" "https://github.com/o/p1/pull/31"
ROWADD "o/p1#32" "$NOW" "$MFT" "https://github.com/o/p1/pull/32"
BRENV=(BR_PER_TICK=3 BR_PER_TICK_P1=3 BR_TICK_MAX_SECS=1)
RUN
BRENV=(); rm -f "$T/slowgh"
[ "$(NQUEUED)" -ge 1 ] && ok \
  || bad "4b: a tick over budget before its first rung must still take one (queued: $(NQUEUED); tick: $(LASTTICK))"

# 4c. THE UNSPENT BUDGET IS CARRIED. Tick 1 ends on the wall budget with two of
#     its three rungs unspent; tick 2 runs with a budget of five.
CLEAN; JOBS_SLOW
for N in 31 32 33 34 35; do
  ROWADD "o/p1#$N" "$NOW" "$MFT" "https://github.com/o/p1/pull/$N"
done
BRENV=(BR_PER_TICK=3 BR_PER_TICK_P1=9 BR_TICK_MAX_SECS=1)
RUN
[ "$(FIELD 1 budget_carry)" = 2 ] && ok \
  || bad "4c: the unspent budget must be carried (tick 1: $(TICKLINE 1))"
JOBS_OK
# Tick 2 is an ordinary tick — the wall cap is the default again, so what it
# proves is the BUDGET it inherited and not the bound that produced it.
BRENV=(BR_PER_TICK=3 BR_PER_TICK_P1=9)
RUN
BRENV=()
[ "$(LFIELD rungs)" = "4/5" ] && ok \
  || bad "4c: and raise the next tick's budget (tick 2: $(LASTTICK))"

# 4d. THE CARRY IS CLAMPED: the budget can at most double, so an outage cannot
#     produce one enormous tick.
CLEAN; JOBS_SLOW
for N in $(seq 11 20); do ROWADD "o/p1#$N" "$NOW" "$MFT" "https://github.com/o/p1/pull/$N"; done
BRENV=(BR_PER_TICK=2 BR_PER_TICK_P1=9 BR_TICK_MAX_SECS=1)
RUN
BRENV=(); JOBS_OK
[ "$(LFIELD budget_carry)" -le 2 ] && ok \
  || bad "4d: the carry must be clamped to BR_PER_TICK (tick: $(LASTTICK))"

# 4e. A DRAINED TICK, AND A TICK THAT SPENT ITS WHOLE RUNG BUDGET, CARRY NOTHING.
CLEAN
ROWADD "o/p1#31" "$NOW" "$MFT" "https://github.com/o/p1/pull/31"
BRENV=(BR_PER_TICK=4 BR_PER_TICK_P1=4 BR_TICK_MAX_SECS=600)
RUN
BRENV=()
[ "$(LFIELD reason)" = drained ] && ok || bad "4e: this tick drains (tick: $(LASTTICK))"
[ "$(LFIELD budget_carry)" = 0 ] && ok \
  || bad "4e: a drained tick is owed nothing (tick: $(LASTTICK))"
CLEAN
ROWADD "o/p1#31" "$NOW" "$MFT" "https://github.com/o/p1/pull/31"
ROWADD "o/p1#32" "$NOW" "$MFT" "https://github.com/o/p1/pull/32"
BRENV=(BR_PER_TICK=1 BR_PER_TICK_P1=1 BR_TICK_MAX_SECS=600)
RUN
BRENV=()
[ "$(LFIELD reason)" = budget ] && ok || bad "4e: this tick ends on its rungs (tick: $(LASTTICK))"
[ "$(LFIELD budget_carry)" = 0 ] && ok \
  || bad "4e: a tick that spent every rung is owed nothing (tick: $(LASTTICK))"

# 4f. A WALL-BUDGET TICK IS A SATURATED TICK. Both endings mean the same thing —
#     this lane cannot reach the back of its own list — so the new reason must
#     not reset the streak and silence the SATURATED alert.
CLEAN; JOBS_SLOW
for N in 31 32 33; do ROWADD "o/p1#$N" "$NOW" "$MFT" "https://github.com/o/p1/pull/$N"; done
BRENV=(BR_PER_TICK=3 BR_PER_TICK_P1=3 BR_TICK_MAX_SECS=1 BR_SATURATED_TICKS=2)
RUN; RUN
BRENV=(); JOBS_OK
[ "$(grep -c 'SATURATED' "$T/alerts.txt" 2>/dev/null)" = 1 ] && ok \
  || bad "4f: two wall-budget ticks must page once (alerts: $(cat "$T/alerts.txt"))"

# 4g. ZERO IS OFF: no wall cap, and the tick ends exactly where its rungs do.
CLEAN; JOBS_SLOW
for N in 31 32; do ROWADD "o/p1#$N" "$NOW" "$MFT" "https://github.com/o/p1/pull/$N"; done
BRENV=(BR_PER_TICK=4 BR_PER_TICK_P1=4 BR_TICK_MAX_SECS=0)
RUN
BRENV=(); JOBS_OK
[ "$(LFIELD reason)" = drained ] && ok \
  || bad "4g: 0 must be no cap at all (tick: $(LASTTICK))"
[ "$(NQUEUED)" = 2 ] && ok || bad "4g: and every rung runs (queued: $(NQUEUED))"

# ============================================================================
# 5. NOTHING ELSE MOVED. With no finished row on the list and no new knob set,
#    the tick line is the one main writes today plus the new fields at their
#    zero values, and the denominator is still BR_PER_TICK.
# ============================================================================
CLEAN
ROWADD "o/p1#31" "$NOW" "$MFT" "https://github.com/o/p1/pull/31"
ROWADD "o/p1#32" "$NOW" "$MFT" "https://github.com/o/p1/pull/32"
BRENV=(BR_PER_TICK=1 BR_PER_TICK_P1=1)
RUN
BRENV=()
case "$(LASTTICK)" in
  "tick: candidates=2 retired=0 carried=0 mechanical=0 families=0 llm_rungs=0 projects=1 visited=[p1] skipped=[] rungs=1/1 reason=budget secs="[0-9]*" rebuilds=1/4 budget_carry=0 oldest_untouched="*) ok ;;
  *) bad "5: the tick line must keep its shape (got: $(LASTTICK))" ;;
esac

# 5b. THE COUNT IS WHAT THE SOURCES FOUND, and `retired` is what the pre-pass
#     dropped: `candidates - retired` is what the loop could reach. Reading the
#     785 the operator measured as a post-filter number would hide the drop.
CLEAN
SEED p1 p1-TK-31 '{"outcome":"ABANDONED","attempts":[]}'
ROWADD "o/p1#31" "$NOW" "$MFT" "https://github.com/o/p1/pull/31"
ROWADD "o/p1#32" "$NOW" "$MFT" "https://github.com/o/p1/pull/32"
RUN
[ "$(LFIELD candidates)" = 2 ] && ok \
  || bad "5b: candidates counts what discovery found (tick: $(LASTTICK))"
[ "$(LFIELD retired)" = 1 ] && ok \
  || bad "5b: retired counts what the pre-pass dropped (tick: $(LASTTICK))"

# 5c. A TICK THAT FOUND NOTHING STAYS QUIET (CLAUDE.md: "if a run finds nothing
#     new, exit quietly"; tests/rebuild-ledger.bh-946-test.sh reads an empty log
#     as proof a refused run took no tick at all).
CLEAN
RUN
[ "$(grep -c 'tick: candidates=' "$H/logs/blocked-resolver.log" 2>/dev/null)" = 0 ] && ok \
  || bad "5c: an idle tick must write no tick line (log: $(LOG))"

# 5d. A TICK WHOSE WHOLE LIST WAS RETIRED DOES speak — that is not an idle tick,
#     it is 270 finished rows being dropped, which is the number the ticket is
#     about.
CLEAN
SEED p1 p1-TK-31 '{"outcome":"ABANDONED","attempts":[]}'
ROWADD "o/p1#31" "$NOW" "$MFT" "https://github.com/o/p1/pull/31"
RUN
[ "$(LFIELD retired)" = 1 ] && ok \
  || bad "5d: a wholly-retired tick must still report (tick: '$(LASTTICK)')"

# ============================================================================
# 6. A ROW FROM A NON-CONDUCTOR SOURCE KEEPS ITS OWN SHAPE (review B1). Only
#    br_conductor_emit ever filled the eighth field; queue, builds, rebuilds and
#    reviews emitted seven, so a ninth column appended to them landed in PARKED.
#    br_note_untouched reads any all-digit string as an epoch, and a cost of 3
#    became a park from 1970.
# ============================================================================
# TWO rows and a budget of one, so the SECOND is left past the break and its
# eighth field is read as a park age by br_note_untouched. With the cost in that
# field the lane reports a park from 1970 — on the tick line and on the
# SATURATED page — and calls it oldest_untouched.
CLEAN
JOBS_QUEUE "$(printf 'p1\tTS-41\tj1\tfailed\t-\t2\t-\t-\tpool died twice\t-\np1\tTS-42\tj2\tfailed\t-\t2\t-\t-\tpool died twice\t-\n')"
BRENV=(BR_PER_TICK=1 BR_PER_TICK_P1=1)
RUN
BRENV=(); JOBS_OK
[ "$(LFIELD oldest_untouched)" = "-" ] && ok \
  || bad "6: THE BUG: a queue-source row must not put its cost in PARKED (tick: $(LASTTICK))"

# 6b. AND ITS COST IS STILL READ. A queue row is a rebuild (the dearest rung);
#     an iron-law conductor row in the SAME project is one call. With a budget of
#     one the adjudication must go first — on the broken shape the queue row's
#     missing ninth field sorted it to 0 and it went first instead.
CLEAN
JOBS_QUEUE "$(printf 'p1\tTS-41\tj1\tfailed\t-\t2\t-\t-\tpool died twice\t-\n')"
ROWADD "o/p1#23" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/23"
BRENV=(BR_PER_TICK=1 BR_PER_TICK_P1=1)
RUN
BRENV=(); JOBS_OK
[ "$(ORDER)" = "adjudicate " ] && ok \
  || bad "6b: THE BUG: the queue row's rebuild must sort behind the adjudication (order: '$(ORDER)')"

# ============================================================================
# 7. RESOLVED_MERGED RETIRES ONE THING: the park on the PR the resolve was
#    about. A ticket can always acquire a new pull request, and the queue and
#    build sources ALWAYS emit url `-`.
# ============================================================================
# 7. A url-less candidate under a RESOLVED_MERGED record is NOT retired.
CLEAN
SEED p1 p1-TK-41 '{"outcome":"RESOLVED_MERGED","resolved_url":"https://github.com/o/p1/pull/900","attempts":[]}'
JOBS_QUEUE "$(printf 'p1\tTS-41\tj1\tfailed\t-\t2\t-\t-\tpool died twice\t-\n')"
RUN
JOBS_OK
[ "$(LFIELD retired)" = 0 ] && ok \
  || bad "7: THE BUG: a url-less park must not be retired by a merged ticket (tick: $(LASTTICK))"

# 7b. A rebuild's OWN ending is still owed, whatever the ticket did. These
#     reasons ARE the rebuild reporting how it finished, and br_abandon_rebuild
#     is the only consumer that record has. br_finished is pure, so it is driven
#     directly rather than through a whole build-record fixture.
FINISHED() { # FINISHED <outcome> <resolved_url> <candidate-url> <reason> -> rc
  ( . <(sed -n '/^br_finished() {/,/^}/p' "$DIR/bin/blocked-resolver.sh")
    br_finished "$1" "$2" "$3" "$4" ) >/dev/null 2>&1
}
if FINISHED RESOLVED_MERGED https://github.com/o/p1/pull/42 - rebuild-plan-blocked
then bad "7b: THE BUG: a rebuild's own ending must never be retired"; else ok; fi
if FINISHED RESOLVED_MERGED https://github.com/o/p1/pull/42 - pool-died-twice
then bad "7b: THE BUG: a url-less park must never be retired"; else ok; fi
if FINISHED RESOLVED_MERGED https://github.com/o/p1/pull/42 https://github.com/o/p1/pull/42 merge-failed-twice
then ok; else bad "7b: the park on the PR that merged IS finished"; fi
if FINISHED ABANDONED - - pool-died-twice
then ok; else bad "7b: an ABANDONED ticket is finished whatever the row"; fi

# 7c. THE LEGACY RECORDS STILL RETIRE. Every RESOLVED_MERGED record written
#     before BH-1457 carries no resolved_url — but the `resolved-merged` ATTEMPT
#     that wrote the outcome carries the url in its own detail, which is a fact
#     on disk and not an inference. Without the fallback the 98 rows in the
#     census retire none of themselves and keep burning a slot each, every tick.
CLEAN
SEED p1 p1-TK-43 '{"outcome":"RESOLVED_MERGED","attempts":[{"at":"x","action":"resolved-merged","reason":"merge-failed-twice","detail":"https://github.com/o/p1/pull/43 is already MERGED — stale park, no rebuild"}]}'
ROWADD "o/p1#43" "$NOW" "$MFT" "https://github.com/o/p1/pull/43"
RUN
[ "$(LFIELD retired)" = 1 ] && ok \
  || bad "7c: THE BUG: a pre-BH-1457 resolved record must retire its own PR (tick: $(LASTTICK))"

# 7d. ...and only its own. A different PR under the same legacy record is a new
#     pull request and keeps today's path.
CLEAN
SEED p1 p1-TK-44 '{"outcome":"RESOLVED_MERGED","attempts":[{"at":"x","action":"resolved-merged","reason":"merge-failed-twice","detail":"https://github.com/o/p1/pull/900 is already MERGED — stale park, no rebuild"}]}'
ROWADD "o/p1#44" "$NOW" "$MFT" "https://github.com/o/p1/pull/44"
RUN
[ "$(LFIELD retired)" = 0 ] && ok \
  || bad "7d: a legacy record must not retire a DIFFERENT PR (tick: $(LASTTICK))"

# ============================================================================
# 8. A TYPO IN THE RUNG BUDGET IS A FALLBACK AND A LINE, never a dead tick.
#    BR_PER_TICK is the knob an operator hand-edits on the hub, and it was the
#    only one on its line with no numeric guard: the arithmetic this ticket adds
#    evaluated it and `$(( ))` on a non-number EXITS THE SHELL under set -u —
#    after the pre-pass had written its retire events, with no tick line at all.
# ============================================================================
CLEAN
ROWADD "o/p1#31" "$NOW" "$MFT" "https://github.com/o/p1/pull/31"
BRENV=(BR_PER_TICK=abc)
RUN
BRENV=()
[ -n "$(LASTTICK)" ] && ok \
  || bad "8: THE BUG: a non-numeric BR_PER_TICK must not kill the tick (log: $(LOG | tail -3))"
[ "$(NLINES "BR_PER_TICK='abc' is not a usable count")" = 1 ] && ok \
  || bad "8: and it must say so once (log: $(LOG | tail -3))"
[ "$(NQUEUED)" = 1 ] && ok || bad "8: and the tick still does its work (queue: $(cat "$T/queue.txt"))"

# ============================================================================
# 9. THE REBUILD CAP COUNTS POOL BUILDS BOUGHT, not rungs dispatched. Both
#    rebuild rungs return 0 on paths that enqueue nothing, so counting the
#    dispatch let four refusals exhaust the fleet's budget under a log line that
#    said "already bought 4 pool build(s)".
# ============================================================================
CLEAN; JOBS_FAIL
for N in 31 32 33; do
  ROWADD "o/p1#$N" "$NOW" "$MFT" "https://github.com/o/p1/pull/$N"
done
BRENV=(BR_PER_TICK=3 BR_PER_TICK_P1=3 BR_REBUILDS_PER_TICK=1)
RUN
BRENV=(); JOBS_OK
[ "$(LFIELD rebuilds)" = "0/1" ] && ok \
  || bad "9: THE BUG: an enqueue that never landed must not count against the cap (tick: $(LASTTICK))"
[ "$(grep -c 'REFUSED' "$T/queue-attempts.txt" 2>/dev/null)" = 3 ] && ok \
  || bad "9: and all three parks must get their rung (attempts: $(cat "$T/queue-attempts.txt" 2>/dev/null))"

# 9b. A LANDED enqueue still counts, and the cap still bites.
CLEAN
for N in 31 32 33; do
  ROWADD "o/p1#$N" "$NOW" "$MFT" "https://github.com/o/p1/pull/$N"
done
BRENV=(BR_PER_TICK=3 BR_PER_TICK_P1=3 BR_REBUILDS_PER_TICK=1)
RUN
BRENV=()
[ "$(NQUEUED)" = 1 ] && ok || bad "9b: the cap still bites on landed builds (queue: $(cat "$T/queue.txt"))"
[ "$(LFIELD rebuilds)" = "1/1" ] && ok || bad "9b: and says so (tick: $(LASTTICK))"
[ "$(NLINES 'BR_REBUILDS_PER_TICK')" = 1 ] && ok \
  || bad "9b: one line per tick, not one per refused park (lines: $(NLINES 'BR_REBUILDS_PER_TICK'))"

# ============================================================================
# 10. THE COST ORDER IS A WITHIN-PROJECT KEY. A global sort undoes BH-980
#     outright: a project whose parks are all rebuilds sits behind every cheaper
#     rung in every other project, tick after tick, and the visit ledger can
#     never rotate it in — then pages STARVED for a starvation the ordering
#     itself created.
# ============================================================================
CLEAN
ROWADD "o/p1#51" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/51"
ROWADD "o/p1#52" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/52"
ROWADD "o/p1#53" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/53"
ROWADD "o/p2#54" "$NOW" "$MFT"     "https://github.com/o/p2/pull/54"
BRENV=(BR_PER_TICK=1)
RUN; RUN; RUN
BRENV=()
V1=$(FIELD 1 visited); V2=$(FIELD 2 visited); V3=$(FIELD 3 visited)
case "$V1$V2$V3" in
  *"[p2]"*) ok ;;
  *) bad "10: THE BUG: the rotation must still reach p2 (visits: $V1 $V2 $V3)" ;;
esac
[ "$V1$V2$V3" != "[p1][p1][p1]" ] && ok \
  || bad "10: a global cost sort would pin the tick to p1 for ever (visits: $V1 $V2 $V3)"

# ============================================================================
# 11. THE WALL BOUND IS MEASURED ON ROWS LOOKED AT, not on rungs run. Every
#     terminal, held, stalled and cap-refused row answers rc 3, so a tick made
#     of them kept the rung counter at 0 and walked its whole list unbounded —
#     and those rows are not free: the hold gate reads GitHub for each one.
# ============================================================================
CLEAN
for N in 61 62 63; do
  ISSUE "$N" ai-build > "$T/issue-$N.json"
  HOLDCMT "$N"
  SEED p1 "p1-TK-$N" '{"outcome":"HELD","attempts":[]}'
  ROWADD "o/p1#$N" "$NOW" "$MFT" "https://github.com/o/p1/pull/$N"
done
touch "$T/slowgh"
BRENV=(BR_PER_TICK=4 BR_PER_TICK_P1=4 BR_TICK_MAX_SECS=1)
RUN
BRENV=(); rm -f "$T/slowgh"
for N in 61 62 63; do echo '[]' > "$T/comments-$N.json"; done
[ "$(LFIELD rungs)" = "0/4" ] && ok \
  || bad "11: a held row is not a rung (tick: $(LASTTICK))"
[ "$(LFIELD reason)" = tick-budget ] && ok \
  || bad "11: THE BUG: a tick of held rows must still be wall-bounded (tick: $(LASTTICK))"

# 11b. AND THE LINE CARRIES THE ELAPSED SECONDS. The whole of ask 7 was a
#      53-minute number; `reason=tick-budget` alone does not say whether the tick
#      ran 31 minutes or three hours.
CLEAN
ROWADD "o/p1#31" "$NOW" "$MFT" "https://github.com/o/p1/pull/31"
RUN
case "$(LFIELD secs)" in
  ''|*[!0-9]*) bad "11b: the tick line must carry secs= (tick: $(LASTTICK))" ;;
  *) ok ;;
esac

# ============================================================================
# 12. A RECORD THAT WILL NOT PARSE COSTS ONLY ITSELF, AND SAYS SO. The one-pass
#     index handed jq its files as ARGUMENTS, which makes them one input
#     stream: a single bad record aborted the invocation, every record after it
#     in that argv was never indexed, stderr went to /dev/null, and the only
#     symptom was `retired=` quietly reading 0 — for ever, since every record
#     write in this lane is a non-atomic `printf > "$f"`.
# ============================================================================
CLEAN
SEED p1 p1-TK-31 '{"outcome":"ABANDONED","attempts":[]}'
printf 'not json at all\n' > "$ST/p1/aaa-broken.json"
ROWADD "o/p1#31" "$NOW" "$MFT" "https://github.com/o/p1/pull/31"
ROWADD "o/p1#32" "$NOW" "$MFT" "https://github.com/o/p1/pull/32"
RUN
[ "$(LFIELD retired)" = 1 ] && ok \
  || bad "12: THE BUG: one unparseable record must not switch off retirement (tick: $(LASTTICK))"
case "$(LFIELD reason)" in
  *+index-short*) ok ;;
  *) bad "12: and the tick must be marked (tick: $(LASTTICK))" ;;
esac
[ "$(NLINES 'could not be parsed and were not indexed')" = 1 ] && ok \
  || bad "12: and one line must name the count (log: $(LOG | tail -3))"
rm -f "$ST/p1/aaa-broken.json"

# 12b. AND A CLEAN TREE IS NOT MARKED. The mark has to mean something.
CLEAN
SEED p1 p1-TK-31 '{"outcome":"ABANDONED","attempts":[]}'
ROWADD "o/p1#31" "$NOW" "$MFT" "https://github.com/o/p1/pull/31"
ROWADD "o/p1#32" "$NOW" "$MFT" "https://github.com/o/p1/pull/32"
RUN
case "$(LFIELD reason)" in
  *+index-short*) bad "12b: a clean tree must not be marked (tick: $(LASTTICK))" ;;
  *) ok ;;
esac

# ============================================================================
# 13. A WHOLLY-RETIRED TICK HAS NO PROJECTS, not one phantom. An empty list fed
#     through `printf '%s\n' ""` is one EMPTY LINE, which the ordering awk
#     re-emits as eight empty fields — so br_round_robin kept a row with no
#     project and the tick reported `projects=1 visited=[] skipped=[-]` on the
#     one line this ticket is about.
# ============================================================================
CLEAN
SEED p1 p1-TK-31 '{"outcome":"ABANDONED","attempts":[]}'
SEED p1 p1-TK-32 '{"outcome":"ABANDONED","attempts":[]}'
ROWADD "o/p1#31" "$NOW" "$MFT" "https://github.com/o/p1/pull/31"
ROWADD "o/p1#32" "$NOW" "$MFT" "https://github.com/o/p1/pull/32"
RUN
[ "$(LFIELD retired)" = 2 ] && ok || bad "13: both rows retire (tick: $(LASTTICK))"
[ "$(LFIELD projects)" = 0 ] && ok \
  || bad "13: THE BUG: a wholly-retired tick has no projects (tick: $(LASTTICK))"
[ "$(LFIELD skipped)" = "[]" ] && ok \
  || bad "13: and nothing is skipped (tick: $(LASTTICK))"

echo "blocked-resolver-prepass.bh-1457: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
