#!/bin/bash
# tests/blocked-resolver-dispatch.bh-5913-test.sh — BH-5913: the cron entry
# dispatches one run per project; no project's run waits on another's.
#
# THE CENSUS (hub logs/blocked-resolver.log, 2026-10-09 18:44Z..22:26Z). Four
# ticks in a row ran 55-58 minutes and logged `visited=[cromford]
# skipped=[project-9 project-8 project-4 project-2 project-7
# project-1 harness-console project-5 project-6-os] reason=tick-budget`,
# oldest_untouched=3903m. One scan walked every project's parks, so
# cromford's 600+ candidates spent the whole tick, and
# `blocked-resolver.sh project-6-os` could not start: the scan held the lock.
#
#   D1  project A's run is stuck inside its rung; project B's run, started by
#       the same dispatch, finishes its rung while A is still stuck
#   D2  20 projects, one dispatch, no cap: all 20 runs reach their rung at the
#       same time (a barrier no serial run could pass), while this suite holds
#       the fleet scan lock; each run has its own lock file
#   D3  a one-project run proceeds while another project's run holds its lock;
#       a second run of the SAME project is turned away; a bad name is refused;
#       a project run keeps its own budget carry
#   D4  the start offsets are stable, inside the window, never within 5 s of a
#       whole minute, and spread over the window
#   D5  a park untouched for more than BR_UNTOUCHED_ALERT_MIN (120) pages ONCE,
#       naming its project; the next run says nothing; 0 = off
#   D6  every gh call of a project run carries that project's App token
#
# The rig is tests/blocked-resolver-prepass.bh-1457-test.sh's: the real
# bin/blocked-resolver.sh end to end against a scratch $HARNESS, a recorded
# jobs client, a recorded bin/lane-alert.sh. Dispatched runs are detached, so
# each case waits (bounded) for the runs it started to write their tick lines.
# Run from anywhere: tests/blocked-resolver-dispatch.bh-5913-test.sh (exit 0 = pass)
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
# The module under test (BH-5913) and the libs the lane reads through, each
# with whatever it sources itself. br_modules_install copies only the required
# bin/lib/br/ loop; an optional module travels by name.
for L in bin/lib/br/opt/untouched.sh bin/lib/gh-app-auth.sh bin/project-lane-run.sh bin/lib/gh-pr-list.sh bin/lib/merge-conductor-lib.sh \
         bin/lib/rebuild-ledger.sh bin/lib/hold.sh bin/lib/gh-rest.sh $(cd "$DIR" && printf "%s " bin/lib/mc/*.sh); do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
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
printf '%s\t%s\n' "\${GH_TOKEN:-none}" "\$*" >> "$T/ghtok.txt"
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
for N in $(seq 1 50); do
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
MFT="merge-failed-twice: gh pr merge refused"

# DISPATCH — run the dispatcher the way cron does. Its runs are detached; the
# caller waits for them with WAITFOR.
DISPATCH() { RUN --dispatch; }
# WAITFOR <shell-test> — up to 60 s for a condition the detached runs make true.
WAITFOR() { local i; for i in $(seq 1 300); do eval "$1" && return 0; sleep 0.2; done; return 1; }
NTICKS() { grep -c 'tick: candidates=' "$H/logs/blocked-resolver.log" 2>/dev/null; }
# FLEET <n> — fleet.conf with projects p1..p<n>, each with a fly pool.
FLEET() { local i
  for i in $(seq 1 "$1"); do printf 'p%s o/p%s - - 2 box-p%s 192.0.2.%s\n' "$i" "$i" "$i" "$i"; touch "$H/flags/fly-pool-p$i"; done > "$H/fleet.conf"; }
cp "$H/fleet.conf" "$T/fleet.conf.orig"

# ============================================================================
# D1. A LONG RUN DOES NOT DELAY ANOTHER PROJECT. p1's enqueue blocks until this
#     suite releases it; p2's run, from the same dispatch, still enqueues.
# ============================================================================
CLEAN; FLEET 2; rm -f "$T/release"
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { if [ "\$1" = p1 ]; then for i in \$(seq 1 300); do [ -e "$T/release" ] && break; sleep 0.2; done; fi; printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
ROWADD "o/p1#31" "$NOW" "$MFT" "https://github.com/o/p1/pull/31"
ROWADD "o/p2#41" "$NOW" "$MFT" "https://github.com/o/p2/pull/41"
BRENV=(BR_DISPATCH_SPREAD_SECS=0)
DISPATCH
BRENV=()
WAITFOR 'grep -q "^p2 " "$T/queue.txt"' && ok || bad "D1: p2's run must enqueue while p1's run is stuck (queue: $(cat "$T/queue.txt"); log: $(tail -3 "$H/logs/blocked-resolver.log"))"
grep -q '^p1 ' "$T/queue.txt" && bad "D1: p1 was meant to be still stuck when p2 finished (queue: $(cat "$T/queue.txt"))" || ok
touch "$T/release"
WAITFOR '[ "$(NTICKS)" -ge 2 ]' && ok || bad "D1: both runs end (ticks: $(NTICKS))"
grep -q 'blocked-resolver dispatch: started 2 project run(s)' "$H/logs/blocked-resolver.log" && ok \
  || bad "D1: the dispatcher says what it started: $(grep dispatch: "$H/logs/blocked-resolver.log")"
grep -q 'another tick is live' "$H/logs/blocked-resolver-cron.log" 2>/dev/null && bad "D1: no run was turned away: $(grep 'another tick' "$H/logs/blocked-resolver-cron.log")" || ok

# ============================================================================
# D2. NO CAP: 20 PROJECTS, ONE DISPATCH, ALL AT ONCE. Every enqueue waits at a
#     barrier until all 20 have arrived: runs that waited on one another could
#     never all arrive, and the barrier would time out. The suite holds the
#     fleet scan lock the whole time: no project run needs it.
# ============================================================================
CLEAN; FLEET 20; : > "$T/barrier.txt"; rm -f "$H/logs/blocked-resolver-cron.log"
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; for i in \$(seq 1 300); do [ "\$(grep -c . "$T/queue.txt")" -ge 20 ] && break; sleep 0.2; done; [ "\$(grep -c . "$T/queue.txt")" -ge 20 ] || echo "timeout \$1" >> "$T/barrier.txt"; echo queued; }
queue_done() { return 0; }
queue_list() { return 1; }
EOF
for I in $(seq 1 20); do ROWADD "o/p$I#$((30 + I))" "$NOW" "$MFT" "https://github.com/o/p$I/pull/$((30 + I))"; done
exec 7>"$H/locks/blocked-resolver-cron.lock"
flock -n 7 || bad "D2 setup: could not take the fleet scan lock"
BRENV=(BR_DISPATCH_SPREAD_SECS=0)
DISPATCH
BRENV=()
WAITFOR '[ "$(NTICKS)" -ge 20 ]' && ok || bad "D2: all 20 runs end (ticks: $(NTICKS); cron log: $(tail -3 "$H/logs/blocked-resolver-cron.log" 2>/dev/null))"
exec 7>&-
[ "$(NQUEUED)" = 20 ] && ok || bad "D2: one rung per project (queued: $(NQUEUED))"
[ ! -s "$T/barrier.txt" ] && ok || bad "D2: THE BUG: a run waited on another — barrier timeouts: $(tr '\n' ' ' < "$T/barrier.txt")"
grep -q 'blocked-resolver dispatch: started 20 project run(s) (period 0s, no cap)' "$H/logs/blocked-resolver.log" && ok \
  || bad "D2: the dispatcher started 20 runs: $(grep dispatch: "$H/logs/blocked-resolver.log")"
NL=0; for I in $(seq 1 20); do [ -e "$H/locks/blocked-resolver-p$I.lock" ] && NL=$((NL + 1)); done
[ "$NL" = 20 ] && ok || bad "D2: each run takes its own project lock ($NL of 20 lock files)"
grep -q 'another tick is live' "$H/logs/blocked-resolver-cron.log" 2>/dev/null && bad "D2: no run waited on the fleet scan lock: $(grep 'another tick' "$H/logs/blocked-resolver-cron.log")" || ok
cp "$T/fleet.conf.orig" "$H/fleet.conf"

# ============================================================================
# D3. A ONE-PROJECT RUN TAKES ITS OWN LOCK, locks/blocked-resolver-<p>.lock. p1's run holds its lock; p2 runs.
# ============================================================================
CLEAN
ROWADD "o/p2#42" "$NOW" "$MFT" "https://github.com/o/p2/pull/42"
ROWADD "o/p1#33" "$NOW" "$MFT" "https://github.com/o/p1/pull/33"
exec 7>"$H/locks/blocked-resolver-p1.lock"
flock -n 7 || bad "D3 setup: could not take p1's lock"
RUN p2
[ "$(NQUEUED)" = 1 ] && grep -q '^p2 ' "$T/queue.txt" && ok \
  || bad "D3: p2's run must proceed while p1's run holds its lock, and move only p2's park (queue: $(cat "$T/queue.txt"); run.log: $(tail -2 "$T/run.log"))"
[ -e "$ST/.tick-budget-p2" ] && [ ! -e "$ST/.tick-budget" ] && ok \
  || bad "D3: a project run keeps its own budget carry: $(ls -a "$ST" | tr '\n' ' ')"
: > "$T/run.log"
RUN p1
grep -q 'another tick is live (locks/blocked-resolver-p1.lock held)' "$T/run.log" && ok \
  || bad "D3: a second run of the same project is turned away: $(tail -2 "$T/run.log")"
exec 7>&-
: > "$T/run.log"
RUN '../p1'
grep -q 'not a project name' "$T/run.log" && ok || bad "D3: a project argument that is not a name is refused: $(tail -2 "$T/run.log")"

# ============================================================================
# D4. THE OFFSETS ARE STABLE AND SPREAD. Read straight from the runner's lib,
#     with the lane name the dispatcher passes.
# ============================================================================
# shellcheck source=bin/lib/project-lanes.sh
. "$DIR/bin/lib/project-lanes.sh" || exit 1
NAMES="cromford project-9 project-8 project-4 project-2 project-7 project-1 harness-console project-5 project-6-os project-3 cromford p1 p2 p3 p4 p5 p6 p7 p8"
A=""; B=""; BADOFF=""
for N in $NAMES; do
  O=$(pl_offset blocked-resolver "$N" 540); A="$A $O"; B="$B $(pl_offset blocked-resolver "$N" 540)"
  if [ "$O" -lt 0 ] || [ "$O" -ge 540 ] || [ $((O % 60)) -lt 5 ] || [ $((O % 60)) -gt 55 ]; then BADOFF="$BADOFF $N=$O"; fi
done
[ "$A" = "$B" ] && ok || bad "D4: the same name gets the same offset (first:$A second:$B)"
[ -z "$BADOFF" ] && ok || bad "D4: offsets inside [0,540) and 5-55 s past a minute:$BADOFF"
MINS=$(for O in $A; do echo $((O / 60)); done | sort | uniq -c | sort -rn)
[ "$(printf '%s\n' "$MINS" | grep -c .)" -ge 6 ] && ok || bad "D4: 20 projects spread over at least 6 of the 9 minutes: $(printf '%s' "$MINS" | tr '\n' ' ')"
[ "$(printf '%s\n' "$MINS" | awk 'NR == 1 {print $1}')" -le 5 ] && ok || bad "D4: no minute starts more than 5 of the 20: $(printf '%s' "$MINS" | tr '\n' ' ')"

# ============================================================================
# D5. A PARK UNTOUCHED PAST BR_UNTOUCHED_ALERT_MIN PAGES ONCE. p3 has two
#     three-hour-old parks and a share of one rung, so one waits untouched.
# ============================================================================
CLEAN
ROWADD "o/p3#44" "$((NOW - 10800))" "$MFT" "https://github.com/o/p3/pull/44"
ROWADD "o/p3#45" "$((NOW - 10800))" "$MFT" "https://github.com/o/p3/pull/45"
BRENV=(BR_PER_TICK=4 BR_PER_TICK_P3=1)
RUN p3
[ "$(grep -c 'UNTOUCHED' "$T/alerts.txt")" = 1 ] && grep 'UNTOUCHED' "$T/alerts.txt" | grep -q 'p3' && ok \
  || bad "D5: one alert names p3's untouched park (alerts: $(cat "$T/alerts.txt"); tick: $(LASTTICK))"
grep 'UNTOUCHED' "$T/alerts.txt" | grep -q -- '--id br-untouched-p3' && ok \
  || bad "D5: the alert carries a stable id: $(grep UNTOUCHED "$T/alerts.txt")"
: > "$T/alerts.txt"
RUN p3
[ "$(grep -c 'UNTOUCHED' "$T/alerts.txt")" = 0 ] && ok || bad "D5: the same park pages once, not every run (alerts: $(cat "$T/alerts.txt"))"
CLEAN
ROWADD "o/p3#44" "$((NOW - 10800))" "$MFT" "https://github.com/o/p3/pull/44"
ROWADD "o/p3#45" "$((NOW - 10800))" "$MFT" "https://github.com/o/p3/pull/45"
BRENV=(BR_PER_TICK=4 BR_PER_TICK_P3=1 BR_UNTOUCHED_ALERT_MIN=0)
RUN p3
BRENV=()
[ "$(grep -c 'UNTOUCHED' "$T/alerts.txt")" = 0 ] && ok || bad "D5: BR_UNTOUCHED_ALERT_MIN=0 is off (alerts: $(cat "$T/alerts.txt"))"

# ============================================================================
# D6. A PROJECT RUN READS GITHUB AS ITS PROJECT. The box mints App tokens (a
#     recorded gh-token.sh); every gh call p2's run makes carries p2's token,
#     never the default one.
# ============================================================================
CLEAN; : > "$T/ghtok.txt"
printf '# fixture: no real App key\n' > "$H/env/github-app.env"
printf '#!/bin/bash\nprintf "ghs_fixture_%%s" "$(printf "%%s" "$1" | tr / _)"\n' > "$H/bin/gh-token.sh"
chmod +x "$H/bin/gh-token.sh"
ROWADD "o/p2#46" "$NOW" "$MFT" "https://github.com/o/p2/pull/46"
RUN p2
[ "$(NQUEUED)" = 1 ] && ok || bad "D6 setup: p2's park moves (queued: $(NQUEUED); log: $(tail -3 "$H/logs/blocked-resolver.log"))"
[ -s "$T/ghtok.txt" ] && ok || bad "D6 setup: the run made no gh call to check"
OTHER=$(awk -F'\t' '$1 != "ghs_fixture_o_p2"' "$T/ghtok.txt" | cut -c1-160)
[ -z "$OTHER" ] && ok || bad "D6: THE BUG: gh calls in p2's run on another credential: $OTHER"
rm -f "$H/env/github-app.env" "$H/bin/gh-token.sh"

echo "blocked-resolver-dispatch.bh-5913: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
