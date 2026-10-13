#!/bin/bash
# tests/alert-triage-spool-age.bh-979-test.sh — STEP 0 of the alert-triage tick:
# the harness retires what a clock and one REST read can settle, for $0, BEFORE
# any family reaches the session cap.
#
# WHAT IS AT STAKE. On 2026-09-19 the deferral spool held 2019 lines that had
# been growing for 2.5 days (median 24.5h, max 55h) and 93% of what a session
# then looked at was noise it confirmed in its own step 0 — a PR already
# CLOSED/MERGED, a heartbeat already recovered — at 60K-900K input tokens a
# time. So "N lines were removed" proves nothing on its own. The load-bearing
# assertions are the three that separate a RETIREMENT from a DROP:
#   * every removed line is in state/alert-triage-expired-<date>.tsv with the
#     reason it went (the spool exists because a silent drop is a loss),
#   * a line UNDER the ceilings behaves exactly as it did before this change,
#   * and every doubt keeps the line: one OPEN PR among two, a read that cannot
#     answer, a line with no epoch, the kill switch.
#
# This runs the REAL bin/alert-triage.sh and the REAL bin/triage-spool-retire.sh
# end to end (the CI precedent: only the harness ROOT is rewritten). agent-call,
# gh-pr-state, ssh, flock and timeout are stubbed because they are the only
# things that would leave this machine or cost money; what they RECEIVE is the
# assertion.
#   bash tests/alert-triage-spool-age.bh-979-test.sh     exit 0 = all pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/triage-tick.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" || exit 1  # BH-1510.2: lanes read models from model_routes
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/env" "$T/stub" "$T/calls"
: > "$H/env/global.env"

# the scripts under test, with only their harness root repointed
for s in alert-triage.sh triage-spool-retire.sh; do
  sed "s|/root/harness|$H|g" "$DIR/bin/$s" > "$H/bin/$s"; chmod +x "$H/bin/$s"
done
for s in triage-map.sh fleet-conf.sh box-for.sh alert_family.py; do ln -sf "$DIR/bin/$s" "$H/bin/$s"; done
export FLEET_CONF="$DIR/fleet.conf"
triage_tick_setup "$H" || exit 1

# --- stubs: the only things that would leave this machine or spend money ------
# agent-call also writes the cost row a real call would, so the in_toks= field
# the lane now logs is read out of the REAL ledger shape (bin/lib/cost-row.sh's
# COST_ROW_HDR, columns 9 and 11) rather than out of a number the test handed it.
cat > "$H/bin/agent-call.sh" <<STUB
#!/bin/bash
N=\$(ls "\$CALLDIR"/prompt-* 2>/dev/null | wc -l | tr -d ' ')
printf '%s' "\$6" > "\$CALLDIR/prompt-\$N.txt"
printf '%s\t%s\n' "\$3" "\${CONTEXT_KILL_TOKENS:-unset}" >> "\$CALLDIR/env.tsv"
# logs/cost.csv is ONE ledger per box: on the hub the last 300 rows interleave
# medic (99), responder (8) and review (20) rows with this lane's. A row from
# another project lands INSIDE this session's window, exactly as it does in
# production, so block 8 measures the filter and not the arithmetic.
printf 'ts,host,medic,triage,runner,model,0,9,999000,40,888000,0,0.50,api,fp,acct,sid,transcript,0.50,-,-,-,-,-\n' >> "$H/logs/cost.csv"
printf 'ts,host,alert-triage,triage,runner,model,0,12,%s,40,%s,0,0.10,api,fp,acct,sid,transcript,0.10,-,-,-,-,-\n' \\
  "\${STUB_IN_TOKS:-1000}" "\${STUB_CACHE_READ:-500}" >> "$H/logs/cost.csv"
echo "handled=1 escalated=0 noise=0" > "\$5"
STUB
chmod +x "$H/bin/agent-call.sh"

# gh-pr-state.sh IS the REST boundary. The stub records every argv (so the
# per-tick cache is observable) and answers from PRMAP; an unlisted PR exits 75,
# which is the "unverifiable" the lane must fail open on.
cat > "$H/bin/gh-pr-state.sh" <<STUB
#!/bin/bash
echo "\$1" >> "$T/prstate.calls"
# STUB_PR_DELAY is how block 12 makes GitHub stall: the real read has no request
# timeout of its own (bin/lib/gh-rest.sh runs \`gh api\` unbounded), so a slow
# answer is the shape the lane's own clock has to survive.
[ -n "\${STUB_PR_DELAY:-}" ] && sleep "\$STUB_PR_DELAY"
grep -F "\$1 " "$T/prmap" 2>/dev/null | head -1 | awk '{print \$2}' | grep . || exit 75
STUB
chmod +x "$H/bin/gh-pr-state.sh"
: > "$T/prmap"

printf '#!/bin/sh\nexit 0\n' > "$T/stub/ssh";   chmod +x "$T/stub/ssh"
printf '#!/bin/sh\nexit 0\n' > "$T/stub/flock"; chmod +x "$T/stub/flock"
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$T/stub/timeout"; chmod +x "$T/stub/timeout"

# --- fixtures ----------------------------------------------------------------
# 2026-09-19T16:40:00Z — the day the spool this ticket is about was measured. It
# is a real 2026 instant on purpose: the `|| echo` fallback below only fires on a
# date(1) without -d, and a fixture epoch from the wrong YEAR would make the two
# disagree silently (round 1, N2).
NOW=1789836000
DAY=$(date -u -d "@$NOW" +%Y%m%d 2>/dev/null || echo 20260919)
ARCH="$H/state/alert-triage-expired-$DAY.tsv"
SPOOL="$H/state/alert-triage-deferred.tsv"

# spool <hours-old> <text> — one line in the collector's own format.
# The akey counter is a monotonic sequence, not $RANDOM: this suite asserts
# exact counts, and a fixture that differs between runs is a flake nobody can
# reproduce.
SEQ=0
spool() {
  SEQ=$((SEQ + 1))
  printf 'hub\t%s\t{"kind":"fleet_alert","project":"fleet","akey":"orclane:a%s","line":"%s"}\n' \
    "$((NOW - ${1} * 3600))" "$SEQ" "$2" >> "$SPOOL"
}

# spool_akey <hours-old> <akey> <text> — the same, with the RAISING LANE'S OWN
# machine key. Block 14 needs it: `migration:example-org/project-4#1677` is an
# owner-qualified PR reference sitting in a routing field, and it is how a line
# whose human text names no PR was being judged on one.
spool_akey() {
  SEQ=$((SEQ + 1))
  printf 'hub\t%s\t{"kind":"fleet_alert","project":"fleet","akey":"%s","line":"%s"}\n' \
    "$((NOW - ${1} * 3600))" "$2" "$3" >> "$SPOOL"
}

# openpr <tag> <url> [<url>…] — a fixture line in a REAL open-PR-presuming shape
# (the responder's, one of the five rule 3 is allowed to judge), carrying <tag>
# so each fixture stays greppable. Before round 3 any text would do, because
# rule 3 judged every line that named a PR; it now judges only these shapes, so a
# fixture about "a PR that is stuck" has to look like one the fleet really sends.
openpr() {
  local tag="$1" first="$2" rest=""
  shift 2
  for u in "$@"; do rest="$rest and $u OPEN/CLEAN"; done
  printf 'RESPONDER: %s: parked, waiting on %s OPEN/CLEAN head=39f19d18%s' "$tag" "$first" "$rest"
}

reset() {
  triage_tick_reset "$H"
  : > "$H/logs/alert-triage.log"; : > "$H/logs/ALERTS.log"; : > "$H/logs/cost.csv"
  echo '{}' > "$H/state/alert-families.json"; : > "$SPOOL"
  : > "$H/state/alert-quarantine.jsonl"; : > "$T/prstate.calls"
  rm -f "$H"/state/alert-triage-expired-*.tsv "$H"/flags/alerted-spoolretire-*
  rm -f "$H/state/triage-prstate.json"   # each block starts with an empty reading cache
  scratch_rm "$T/calls"; mkdir -p "$T/calls"
}

run() {  # run [<epoch>] — one tick with the clock pinned
  TRIAGE_NOW="${1:-$NOW}" TRIAGE_MAX_FAMILIES=20 CALLDIR="$T/calls" PATH="$T/stub:$PATH" \
    triage_tick "$H/bin/alert-triage.sh" >/dev/null 2>&1
}
ncalls() { ls "$T/calls"/prompt-* 2>/dev/null | wc -l | tr -d ' '; }
inprompts() { grep -qF "$1" "$T"/calls/prompt-*.txt 2>/dev/null; }

# ---------- 1. aging retires and archives WITH the reason column -------------
reset
spool 55 "the ancient subsystem is unhappy"
spool 8  "[orchestrator/merge-conductor] conductor: project-5#11 HEAD_MOVED — 480m in HEAD_MOVED"
spool 1  "[orchestrator/merge-conductor] conductor: project-5#12 HEAD_MOVED — 60m in HEAD_MOVED"
spool 2  "the recent subsystem is unhappy"
run
[ "$(ncalls)" = 2 ] && ok || bad "1: only the 2 lines under the ceilings may buy a session (got $(ncalls))"
! inprompts "the ancient subsystem" && ok || bad "1: a 55h-old line must not reach a session"
inprompts "the recent subsystem" && ok || bad "1: a 2h-old line must still reach a session"
[ -s "$ARCH" ] && ok || bad "1: the retired lines must be archived to $ARCH"
[ "$(wc -l < "$ARCH" | tr -d ' ')" = 2 ] && ok || bad "1: exactly 2 lines retired (got $(wc -l < "$ARCH"))"
[ "$(cut -f2 "$ARCH" | grep -c '^EXPIRED-AGE$')" = 1 ] \
  && ok || bad "1: the >24h line is archived with reason EXPIRED-AGE in column 2 (got: $(cut -f2 "$ARCH" | tr '\n' ' '))"
[ "$(cut -f2 "$ARCH" | grep -c '^EXPIRED-CONDSTATE$')" = 1 ] \
  && ok || bad "1: the >6h conductor state note is archived with reason EXPIRED-CONDSTATE"
# the archive keeps the ORIGINAL line, or it is a receipt for something nobody
# can read back
grep -qF 'the ancient subsystem is unhappy' "$ARCH" \
  && ok || bad "1: the archive must carry the original line, not just a count"
grep -q 'STEP 0 aged=1 condstate=1 stale=0 ' "$H/logs/alert-triage.log" \
  && ok || bad "1: ONE log line per tick with the real counts (got: $(grep 'STEP 0' "$H/logs/alert-triage.log"))"

# ---------- 2. under the ceilings, nothing changes ---------------------------
# The control that keeps this from being "delete old things": a lane that
# retired everything would pass block 1 and be a catastrophe.
reset
spool 1 "the alpha subsystem is unhappy"
spool 5 "[orchestrator/merge-conductor] conductor: project-5#13 WAIT_CI — 300m in WAIT_CI"
run
[ "$(ncalls)" = 2 ] && ok || bad "2: both under-ceiling lines must still be triaged (got $(ncalls))"
[ ! -f "$ARCH" ] && ok || bad "2: nothing may be archived when nothing is over a ceiling"
grep -q 'STEP 0 aged=0 condstate=0 stale=0 kept=2' "$H/logs/alert-triage.log" \
  && ok || bad "2: a no-op STEP 0 must still declare itself (got: $(grep 'STEP 0' "$H/logs/alert-triage.log"))"
! grep -q 'SPOOL RETIREMENT' "$H/logs/ALERTS.log" \
  && ok || bad "2: an alarm that always rings is an alarm nobody reads — no ALERTS line when nothing was retired"

# ---------- 3. a CLOSED/MERGED PR is retired at $0, deterministically --------
reset
echo "https://github.com/example-org/project-5/pull/5001 MERGED" >> "$T/prmap"
echo "https://github.com/example-org/project-5/pull/5002 OPEN"   >> "$T/prmap"
echo "https://github.com/example-org/project-5/pull/5003 CLOSED" >> "$T/prmap"
spool 1 "$(openpr 'stuckpr one' https://github.com/example-org/project-5/pull/5001)"
spool 1 "$(openpr 'stuckpr two' https://github.com/example-org/project-5/pull/5002)"
spool 1 "$(openpr 'stuckpr both' example-org/project-5#5001 example-org/project-5#5003)"
spool 1 "$(openpr 'stuckpr mixed' example-org/project-5#5001 example-org/project-5#5002)"
spool 1 "$(openpr 'stuckpr unknown' https://github.com/example-org/project-5/pull/5999)"
run
! inprompts "stuckpr one:"  && ok || bad "3: a line whose only PR is MERGED must not buy a session"
inprompts "stuckpr two:"    && ok || bad "3: a line whose PR is OPEN must still buy a session"
! inprompts "stuckpr both:" && ok || bad "3: MERGED + CLOSED is terminal for every reference — retire it"
inprompts "stuckpr mixed:"  && ok || bad "3: ONE open reference keeps the line (every doubt keeps the line)"
inprompts "stuckpr unknown:" && ok || bad "3: an unverifiable read (rc 75) keeps the line, it never retires it"
[ "$(cut -f2 "$ARCH" | grep -c '^NOISE-STALE$')" = 2 ] \
  && ok || bad "3: exactly the 2 all-terminal lines are archived NOISE-STALE (got: $(cut -f2 "$ARCH" | tr '\n' ' '))"
grep -q 'STEP 0 aged=0 condstate=0 stale=2 ' "$H/logs/alert-triage.log" \
  && ok || bad "3: the stale count must be declared (got: $(grep 'STEP 0' "$H/logs/alert-triage.log"))"

# ---------- 4. ONE REST read per PR per tick ---------------------------------
# The whole point of doing this in the harness is that it is cheap. A lookup per
# LINE would put the lane back on a GitHub rate limit at the spool depths that
# produced this ticket.
[ "$(sort -u "$T/prstate.calls" | wc -l | tr -d ' ')" = 4 ] \
  && ok || bad "4: 4 distinct PRs were named (got $(sort -u "$T/prstate.calls" | wc -l))"
[ "$(wc -l < "$T/prstate.calls" | tr -d ' ')" = 4 ] \
  && ok || bad "4: each distinct PR is looked up exactly ONCE per tick (got $(wc -l < "$T/prstate.calls") reads for 4 PRs)"
# and the read went through bin/gh-pr-state.sh — REST, App token, never GraphQL
grep -q 'gh-pr-state.sh' "$DIR/bin/triage-spool-retire.sh" \
  && ok || bad "4: the PR state read must go through bin/gh-pr-state.sh"
RAWGH=$(grep -vE '^[[:space:]]*#' "$DIR/bin/triage-spool-retire.sh" \
  | grep -cE '(^|[^A-Za-z0-9_-])gh (pr|api|issue|repo|run|workflow)([^A-Za-z0-9_-]|$)')
[ "$RAWGH" = 0 ] \
  && ok || bad "4: no raw gh call may appear in the retirement script (got $RAWGH)"

# ---------- 5. the daily ALERTS declaration is deduped -----------------------
reset
spool 55 "the ancient subsystem is unhappy"
spool 1  "the recent subsystem is unhappy"
run
[ "$(grep -c 'SPOOL RETIREMENT' "$H/logs/ALERTS.log")" = 1 ] \
  && ok || bad "5: the first retirement of a UTC day declares itself once in ALERTS.log"
grep -q "alert-triage-expired-$DAY.tsv" "$H/logs/ALERTS.log" \
  && ok || bad "5: the declaration must name the archive a human would go and read"
spool 55 "another ancient subsystem is unhappy"
run
[ "$(grep -c 'SPOOL RETIREMENT' "$H/logs/ALERTS.log")" = 1 ] \
  && ok || bad "5: a second tick on the same UTC day must NOT declare again (got $(grep -c 'SPOOL RETIREMENT' "$H/logs/ALERTS.log"))"
[ "$(grep -c 'STEP 0 ' "$H/logs/alert-triage.log")" -ge 2 ] \
  && ok || bad "5: every tick still logs its own counts in the lane log"
# the NEXT UTC day speaks again, or a backlog that never ends becomes invisible
spool 55 "a third ancient subsystem is unhappy"
run $((NOW + 86400))
[ "$(grep -c 'SPOOL RETIREMENT' "$H/logs/ALERTS.log")" = 2 ] \
  && ok || bad "5: a new UTC day declares again (got $(grep -c 'SPOOL RETIREMENT' "$H/logs/ALERTS.log"))"

# ---------- 6. every doubt keeps the line ------------------------------------
reset
printf 'hub\tnot-an-epoch\t{"kind":"fleet_alert","line":"the undated subsystem is unhappy"}\n' >> "$SPOOL"
run
inprompts "the undated subsystem" \
  && ok || bad "6: a line with no readable epoch is kept, never aged out on a guess"
[ ! -f "$ARCH" ] && ok || bad "6: an unparseable line is not archived"

# AND THE PROMISE IS UNCONDITIONAL, not "unconditional for the shapes rule 3
# never judges" (round 4). The fixture above names no PR, so it never reached
# rule 3 at all; a no-epoch line in an ALLOWLISTED shape whose PR reads terminal
# did reach it and was archived NOISE-STALE with age -1 — a receipt whose age
# column says the line was never dated. The header and the lane doc both say a
# missing epoch leaves the line exactly as it arrived; rule 3 is not an
# exception to that.
reset
echo "https://github.com/example-org/project-5/pull/4242 MERGED" >> "$T/prmap"
printf 'hub\tnot-an-epoch\t{"kind":"fleet_alert","line":"RESPONDER: undated-allowlisted waits on https://github.com/example-org/project-5/pull/4242: OPEN/CLEAN"}\n' >> "$SPOOL"
run
inprompts "undated-allowlisted" \
  && ok || bad "6: a no-epoch line in an allowlisted shape is kept too, however its PR reads"
[ ! -f "$ARCH" ] && ok || bad "6: and nothing is archived carrying a fabricated age (got: $(cat "$ARCH" 2>/dev/null))"

reset
touch "$H/flags/triage-spool-age-off"
spool 55 "the ancient subsystem is unhappy"
run
inprompts "the ancient subsystem" \
  && ok || bad "7: flags/triage-spool-age-off must restore the old behaviour verbatim"
[ ! -f "$ARCH" ] && ok || bad "7: the kill switch archives nothing"
[ "$(wc -l < "$T/prstate.calls" | tr -d ' ')" = 0 ] \
  && ok || bad "7: the kill switch must not even spend the REST reads"
rm -f "$H/flags/triage-spool-age-off"

# ---------- 8. the per-session ceiling and the token readout -----------------
# "93% noise at 400K-900K tokens a session" took a join across two files to see,
# because handled/escalated/noise landed in the lane log and the tokens landed
# in cost.csv. The number goes where the outcome is.
reset
spool 1 "the alpha subsystem is unhappy"
STUB_IN_TOKS=123000 STUB_CACHE_READ=4000 TRIAGE_NOW="$NOW" TRIAGE_MAX_FAMILIES=20 \
  CALLDIR="$T/calls" PATH="$T/stub:$PATH" triage_tick "$H/bin/alert-triage.sh" >/dev/null 2>&1
grep -q 'in_toks=127000' "$H/logs/alert-triage.log" \
  && ok || bad "8: the session's input_toks+cache_read must be logged beside its outcome (got: $(grep 'triage session' "$H/logs/alert-triage.log"))"
# THE FILTER, not the sum: the medic row the stub wrote between the pre-mark and
# the read carries 1,887,000 tokens. A number that includes another lane's rows
# is not this session's cost, and an operator tuning context_kill_tokens off it
# tunes off noise.
! grep -qE 'in_toks=(2014000|1887000)' "$H/logs/alert-triage.log" \
  && ok || bad "8: in_toks= must count only this lane's own cost rows (got: $(grep 'triage session' "$H/logs/alert-triage.log"))"
grep -q 'handled=1 escalated=0 noise=0' "$H/logs/alert-triage.log" \
  && ok || bad "8: the outcome summary must still be there"

reset
spool 1 "the alpha subsystem is unhappy"
TRIAGE_CONTEXT_KILL_TOKENS=250000 TRIAGE_NOW="$NOW" TRIAGE_MAX_FAMILIES=20 \
  CALLDIR="$T/calls" PATH="$T/stub:$PATH" triage_tick "$H/bin/alert-triage.sh" >/dev/null 2>&1
grep -q '250000' "$T/calls/env.tsv" \
  && ok || bad "8: TRIAGE_CONTEXT_KILL_TOKENS must reach agent-call as CONTEXT_KILL_TOKENS (got: $(cat "$T/calls/env.tsv"))"
reset
spool 1 "the alpha subsystem is unhappy"
run
grep -q 'unset' "$T/calls/env.tsv" \
  && ok || bad "8: unset, the lane exports nothing and the manifest stays the single source (got: $(cat "$T/calls/env.tsv"))"
# and the manifest ceiling this lane actually runs under is the lowered one
CK=$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(next(l["context_kill_tokens"] for l in d["lanes"] if l.get("lane")=="alert-triage"))' \
  "$DIR/catalog/context-budgets.json")
[ "${CK:-0}" -le 500000 ] && [ "${CK:-0}" -gt 0 ] \
  && ok || bad "8: catalog/context-budgets.json must cap the alert-triage session (got $CK)"

# ---------- 9. EXPIRED-CONDSTATE is a BUDGET NOTE, not every conductor line ---
# Round 1 measured the first cut of this rule retiring 771 lines on the 09-19
# archive where the orchestrator's hand drain retired 329: `[merge-conductor]`
# alone also matches the stuck detector's critical lines and the one-shot
# criticals (CLOSED, "production is unverified", DEPLOY_VERIFY), none of which
# the conductor re-decides every tick and none of which this ticket asked to age
# faster than 24h. The rule is the budget-note SHAPE: `— <N>m in <STATE>:`.
#
# AND THE ONE-SHOTS SURVIVE RULE 3 TOO (round 2, BLOCK 1). Every one of them
# names a PR that really is MERGED or CLOSED — that is WHY they were raised — so
# "every named PR reads terminal" retires them on their first tick, at age 0,
# before any session or escalation. These four are the exact texts of
# merge-conductor-lib.sh:5252, merge-conductor.sh:314, merge-conductor.sh:2880
# and blocked-resolver.sh:711, each with the url it really carries and each PR
# answering terminal, which is the condition round 1's fixture (no url) never
# reached. The GUARD-CONTROL line is the counter-assertion: an ordinary alert
# about an OPEN-PR condition whose PR has since merged must still retire, or the
# fix is a blanket disable of rule 3.
reset
echo "https://github.com/example-org/project-3/pull/7341 MERGED" >> "$T/prmap"
echo "https://github.com/example-org/project-3/pull/7343 MERGED" >> "$T/prmap"
echo "https://github.com/example-org/project-3/pull/7344 CLOSED" >> "$T/prmap"
echo "https://github.com/example-org/project-3/pull/7345 CLOSED" >> "$T/prmap"
spool 7 "[orchestrator/merge-conductor] conductor: example-org/project-3#7340 HEAD_MOVED — STUCK: 91m in one state (TTL 90m) on 23065ede — waiting on a head-bound review of this head"
spool 7 "[orchestrator/merge-conductor] conductor: example-org/project-3#7341 MERGED — merged 23065ede but the deploy-verify lane could not be spawned — production is unverified for this sha: https://github.com/example-org/project-3/pull/7341"
spool 7 "[orchestrator/merge-conductor] conductor: example-org/project-3#7343 MERGED — landed (merge queue) while the conductor's merge flag was off: the issue was NOT closed and NO deploy was requested — turn flags/merge-conductor-merge on and the next tick settles both, or run bin/deploy-request.sh for this sha: https://github.com/example-org/project-3/pull/7343"
spool 7 "[orchestrator/merge-conductor] conductor: example-org/project-3#7344 CLOSED — closed 41m ago without merging and its issue is still open — rebuild or close the issue: https://github.com/example-org/project-3/pull/7344"
spool 7 "[blocked-resolver] project-3/BH-77: a fresh rebuild was refused because NO ticket key could be derived — not from the PR branch, not from its title, not from the build record. The stale PR (https://github.com/example-org/project-3/pull/7345) is already closed, so nothing owns this ticket until somebody names it. Record: none. Fix: re-enqueue the ticket by key."
spool 7 "$(openpr 'guard-control' https://github.com/example-org/project-3/pull/7341)"
spool 7 "[orchestrator/merge-conductor] conductor: example-org/project-3#7342 HEAD_MOVED — 480m in HEAD_MOVED: reviewed 46f07059 head 3629fea8 (verdict=APPROVE ci=green mergeState=DIRTY mode=merge)"
run
inprompts "STUCK: 91m in one state" \
  && ok || bad "9: a 7h-old conductor STUCK critical is NOT a per-PR budget note — it must be kept"
inprompts "production is unverified" \
  && ok || bad "9: the deploy-verify one-shot says the PR MERGED — reading it MERGED confirms the alert, it does not moot it"
inprompts "merge flag was off" \
  && ok || bad "9: 'landed while the merge flag was off: issue NOT closed, NO deploy' must survive its own MERGED read"
inprompts "issue is still open" \
  && ok || bad "9: 'CLOSED without merging, issue still open' must survive its own CLOSED read"
inprompts "already closed, so nothing owns this ticket" \
  && ok || bad "9: the resolver's no-ticket-key alert rests on the PR being closed — a CLOSED read is its premise, not its answer"
! inprompts "guard-control:" \
  && ok || bad "9: GUARD-CONTROL — an ordinary alert whose only PR has merged must STILL retire NOISE-STALE"
! inprompts "480m in HEAD_MOVED" \
  && ok || bad "9: the 7h-old budget note IS the rule's target and must be retired"
[ "$(cut -f2 "$ARCH" | grep -c '^EXPIRED-CONDSTATE$')" = 1 ] \
  && ok || bad "9: exactly one line retired EXPIRED-CONDSTATE (got: $(cut -f2 "$ARCH" | tr '\n' ' '))"
[ "$(cut -f2 "$ARCH" | grep -c '^NOISE-STALE$')" = 1 ] \
  && ok || bad "9: exactly the guard-control line retired NOISE-STALE (got: $(cut -f2 "$ARCH" | tr '\n' ' '))"
grep -q 'STEP 0 aged=0 condstate=1 stale=1 ' "$H/logs/alert-triage.log" \
  && ok || bad "9: four post-terminal criticals kept, one budget note and one stale line retired (got: $(grep 'STEP 0' "$H/logs/alert-triage.log"))"

# ---------- 10. the PR-state cache persists, and starvation is declared -------
# Round 1: `_state_cache` was per PROCESS and lines are walked oldest-first, so
# with 105 distinct PRs in today's spool and a cap of 40 the same 40 were re-read
# every tick and the other 65 were never checked until the 24h ceiling. The cache
# is now a file with a TTL, so a PR already read costs no lookup and the next
# tick's budget reaches the ones the cap starved — and the summary says how many
# went unchecked instead of only how many were read.
reset
echo "https://github.com/example-org/project-5/pull/6001 MERGED" >> "$T/prmap"
echo "https://github.com/example-org/project-5/pull/6002 MERGED" >> "$T/prmap"
WF="$T/work.tsv"
printf 'hub\t%s\t{"kind":"fleet_alert","line":"RESPONDER: both waits on https://github.com/example-org/project-5/pull/6001: OPEN/CLEAN and https://github.com/example-org/project-5/pull/6002 OPEN/CLEAN"}\n' \
  "$((NOW - 3600))" > "$WF"
OUT1=$(HARNESS="$H" TRIAGE_NOW="$NOW" TRIAGE_PRSTATE_MAX_LOOKUPS=1 "$H/bin/triage-spool-retire.sh" "$WF")
case "$OUT1" in *"lookups=1"*) ok ;; *) bad "10: tick 1 spends exactly its one-lookup budget (got: $OUT1)" ;; esac
case "$OUT1" in *"unchecked=1"*) ok ;; *) bad "10: the PRs the cap never reached must be declared (got: $OUT1)" ;; esac
[ "$(wc -l < "$WF" | tr -d ' ')" = 1 ] \
  && ok || bad "10: one unread reference keeps the line (every doubt keeps the line)"
[ -s "$H/state/triage-prstate.json" ] \
  && ok || bad "10: the reading must be persisted, or the next tick re-reads the same PR"
OUT2=$(HARNESS="$H" TRIAGE_NOW="$((NOW + 600))" TRIAGE_PRSTATE_MAX_LOOKUPS=1 "$H/bin/triage-spool-retire.sh" "$WF")
[ "$(sort -u "$T/prstate.calls" | wc -l | tr -d ' ')" = 2 ] \
  && ok || bad "10: tick 2 must spend its lookup on the PR tick 1 never reached (read: $(sort -u "$T/prstate.calls" | tr '\n' ' '))"
[ "$(wc -l < "$T/prstate.calls" | tr -d ' ')" = 2 ] \
  && ok || bad "10: a PR read last tick costs NO lookup this tick (got $(wc -l < "$T/prstate.calls") reads)"
[ "$(wc -l < "$WF" | tr -d ' ')" = 0 ] \
  && ok || bad "10: with both references read terminal the line retires (got: $(cat "$WF"))"
case "$OUT2" in *"stale=1"*) ok ;; *) bad "10: and it retires as NOISE-STALE (got: $OUT2)" ;; esac
# a cache file that cannot be parsed is EMPTY, never fatal: the lane reads PRs
# again and pays, which is the failing-open side of this guard.
printf 'not json at all\n' > "$H/state/triage-prstate.json"
printf 'hub\t%s\t{"kind":"fleet_alert","line":"RESPONDER: one waits on https://github.com/example-org/project-5/pull/6001: OPEN/CLEAN"}\n' \
  "$((NOW - 3600))" > "$WF"
: > "$T/prstate.calls"
OUT3=$(HARNESS="$H" TRIAGE_NOW="$((NOW + 1200))" "$H/bin/triage-spool-retire.sh" "$WF")
case "$OUT3" in *"stale=1"*) ok ;; *) bad "10: a corrupt cache must fail open, not fail the tick (got: $OUT3)" ;; esac
[ "$(wc -l < "$T/prstate.calls" | tr -d ' ')" = 1 ] \
  && ok || bad "10: and it must re-read rather than trust an unreadable file"

# an unreadable workfile answers in the SAME field set as every other tick, or a
# parser (or a human's grep) sees two shapes for one line.
OUTX=$(HARNESS="$H" TRIAGE_NOW="$NOW" "$H/bin/triage-spool-retire.sh" "$T/definitely-not-here.tsv" 2>/dev/null; echo "rc=$?")
case "$OUTX" in *"rc=2"*) ok ;; *) bad "10: a missing workfile is a usage error (got: $OUTX)" ;; esac
printf '' > "$T/empty.tsv"
OUTY=$(HARNESS="$H" TRIAGE_NOW="$NOW" "$H/bin/triage-spool-retire.sh" "$T/empty.tsv")
case "$OUTY" in *"unchecked=0"*) ok ;; *) bad "10: every summary carries the same fields (got: $OUTY)" ;; esac

# ---------- 11. a STEP 0 that breaks is LOUD, and its flag does not pile up ---
# Round 1: the call discarded stderr and the script ends `exit 0`, so a python
# traceback vanished and the tick ran with no STEP 0 line at all — the silent
# failure mode of a step whose whole job is to be auditable.
reset
mkdir -p "$ARCH"                     # the archive path is a DIRECTORY: every write fails
spool 55 "the ancient subsystem is unhappy"
run
inprompts "the ancient subsystem" \
  && ok || bad "11: an archive it cannot write is a drop it cannot audit — the line stays"
grep -q 'archive unwritable' "$H/logs/alert-triage.log" \
  && ok || bad "11: and STEP 0's stderr must land in the lane log (got: $(cat "$H/logs/alert-triage.log"))"
rmdir "$ARCH" 2>/dev/null

reset
touch "$H/flags/alerted-spoolretire-20260101"
spool 55 "the ancient subsystem is unhappy"
run
[ ! -f "$H/flags/alerted-spoolretire-20260101" ] \
  && ok || bad "11: yesterday's declaration flag must be pruned, not kept forever"
# BH-5942: the flag is per project; "fleet" is not in fleet.conf, so the home
# project cromford owns these lines.
[ -f "$H/flags/alerted-spoolretire-cromford-$DAY" ] \
  && ok || bad "11: today's flag is what dedupes today (got: $(ls "$H/flags"))"

# ---------- 12. the lookup pass is bounded in time, not only in count --------
# `gh-pr-state.sh` goes through bin/lib/gh-rest.sh, which runs `gh api` with NO
# request timeout, and this whole tick holds the lane's `flock -n` (cron/hub.cron)
# with the drained spool in a mktemp that is not written back until the end. A
# GitHub stall with the default cap of 40 was therefore a 40-minute silent tick,
# and a reboot inside that window loses the spool. Two clocks bound it: one per
# call, and one for the whole pass.
reset
WF="$T/work12.tsv"
printf 'hub\t%s\t{"kind":"fleet_alert","line":"RESPONDER: slow waits on https://github.com/example-org/project-5/pull/6001: OPEN/CLEAN"}\n' \
  "$((NOW - 3600))" > "$WF"
OUT12=$(STUB_PR_DELAY=3 HARNESS="$H" TRIAGE_NOW="$NOW" TRIAGE_PRSTATE_TIMEOUT_S=1 \
  "$H/bin/triage-spool-retire.sh" "$WF")
case "$OUT12" in *"stale=0"*) ok ;; *) bad "12: a read that outlasts TRIAGE_PRSTATE_TIMEOUT_S is UNKNOWN, never a terminal (got: $OUT12)" ;; esac
[ "$(wc -l < "$WF" | tr -d ' ')" = 1 ] \
  && ok || bad "12: and the line it could not read stays (every doubt keeps the line)"
[ ! -s "$H/state/triage-prstate.json" ] \
  && ok || bad "12: a timed-out read must not be cached as a reading (got: $(cat "$H/state/triage-prstate.json"))"

# the per-tick deadline: the first lookup is inside it, the second is not.
: > "$T/prstate.calls"; rm -f "$H/state/triage-prstate.json"
printf 'hub\t%s\t{"kind":"fleet_alert","line":"RESPONDER: a waits on https://github.com/example-org/project-5/pull/6001: OPEN/CLEAN"}\nhub\t%s\t{"kind":"fleet_alert","line":"RESPONDER: b waits on https://github.com/example-org/project-5/pull/6002: OPEN/CLEAN"}\n' \
  "$((NOW - 3600))" "$((NOW - 3600))" > "$WF"
OUT12B=$(STUB_PR_DELAY=1 HARNESS="$H" TRIAGE_NOW="$NOW" TRIAGE_PRSTATE_DEADLINE_S=1 \
  "$H/bin/triage-spool-retire.sh" "$WF")
case "$OUT12B" in *"lookups=1"*) ok ;; *) bad "12: past TRIAGE_PRSTATE_DEADLINE_S the pass buys no more reads (got: $OUT12B)" ;; esac
case "$OUT12B" in *"unchecked=1"*) ok ;; *) bad "12: and what it never read is declared, exactly like the lookup cap (got: $OUT12B)" ;; esac
case "$OUT12B" in *"stale=1"*) ok ;; *) bad "12: the reference it DID read still settles its own line (got: $OUT12B)" ;; esac
[ "$(wc -l < "$WF" | tr -d ' ')" = 1 ] \
  && ok || bad "12: the line behind the deadline is kept, not retired unread (got: $(cat "$WF"))"
[ "$(wc -l < "$T/prstate.calls" | tr -d ' ')" = 1 ] \
  && ok || bad "12: exactly one read was issued before the deadline (got $(wc -l < "$T/prstate.calls"))"

# ---------- 13. a persisted reading expires on ITS OWN age -------------------
# Round 1 wrote `"at": now` for every entry in the cache, including the ones
# LOADED from the file, so any tick that bought one new reading re-stamped every
# other one. On the hub, where nearly every tick reads something new, an OPEN
# reading would then never expire: the PR merges, the lane never re-reads it, and
# its lines keep buying sessions until the 24h ceiling — the cost this ticket
# exists to stop, and the opposite of the page's "reused for TRIAGE_PRSTATE_TTL_H".
reset
echo "https://github.com/example-org/project-5/pull/8001 OPEN" >> "$T/prmap"
echo "https://github.com/example-org/project-5/pull/8002 OPEN" >> "$T/prmap"
WF="$T/work13.tsv"
w13() { printf 'hub\t%s\t{"kind":"fleet_alert","line":"RESPONDER: %s waits on %s: OPEN/CLEAN"}\n' \
  "$((NOW - 3600))" "$1" "$2" > "$WF"; }
w13 one https://github.com/example-org/project-5/pull/8001
HARNESS="$H" TRIAGE_NOW="$NOW" "$H/bin/triage-spool-retire.sh" "$WF" >/dev/null
# T+5h: an UNRELATED PR is read, which rewrites the whole cache file
w13 two https://github.com/example-org/project-5/pull/8002
HARNESS="$H" TRIAGE_NOW="$((NOW + 18000))" "$H/bin/triage-spool-retire.sh" "$WF" >/dev/null
# T+7h, past TRIAGE_PRSTATE_TTL_H=6 for the reading bought at T — and #8001 has
# merged in the meantime.
grep -v 'pull/8001 ' "$T/prmap" > "$T/prmap.new" && mv "$T/prmap.new" "$T/prmap"
echo "https://github.com/example-org/project-5/pull/8001 MERGED" >> "$T/prmap"
w13 one https://github.com/example-org/project-5/pull/8001
: > "$T/prstate.calls"
OUT13=$(HARNESS="$H" TRIAGE_NOW="$((NOW + 25200))" "$H/bin/triage-spool-retire.sh" "$WF")
case "$OUT13" in *"lookups=1"*) ok ;; *) bad "13: a reading older than the TTL is re-read even after an intervening cache rewrite (got: $OUT13)" ;; esac
case "$OUT13" in *"stale=1"*) ok ;; *) bad "13: and the line whose PR has since merged retires (got: $OUT13)" ;; esac
[ "$(wc -l < "$WF" | tr -d ' ')" = 0 ] \
  && ok || bad "13: the retired line must leave the workfile (got: $(cat "$WF"))"
# the other half of the same rule: INSIDE the TTL a reading is still free
w13 one https://github.com/example-org/project-5/pull/8001
: > "$T/prstate.calls"
OUT13B=$(HARNESS="$H" TRIAGE_NOW="$((NOW + 25800))" "$H/bin/triage-spool-retire.sh" "$WF")
case "$OUT13B" in *"lookups=0"*) ok ;; *) bad "13: a reading bought 10m ago must still cost no lookup (got: $OUT13B)" ;; esac
case "$OUT13B" in *"stale=1"*) ok ;; *) bad "13: and it still answers MERGED from the cache (got: $OUT13B)" ;; esac

# ---------- 14. RULE 3 IS AN ALLOWLIST, not a denylist of known-bad lanes -----
# Round 2 closed the four conductor/resolver shapes that are raised BECAUSE a PR
# reached a terminal. Round 3 measured the CLASS still open on the hub's live
# 1010-line spool: with every read answering MERGED (which is what those PRs
# really are — the alerts say so), rule 3 retired, at age 0 and for $0, the
# fleet's post-merge criticals from three other lanes:
#   bin/postmerge-qa.sh:388          PROD QA FAILED after merge … ($PR_URL)
#   bin/check-migration-prs.sh:94    PR #N shipped migration SQL — confirm it is
#                                    applied to prod   (judged on its AKEY:
#                                    "migration:example-org/project-4#1677" is an
#                                    owner-qualified reference in a ROUTING key,
#                                    while the human text has only "#1677")
#   merge-conductor-lib.sh:5163      conductor: <slug> READY — … merged directly
#                                    (degraded) …   (a NON-terminal state word,
#                                    so round 2's denylist never saw it)
#   hb-alert relays of a MERGED PR line
# A denylist can only name the lanes that exist today. So the default is KEEP and
# rule 3 judges only the five open-PR-presuming shapes — and the assertions below
# are BOTH halves: the post-merge criticals survive, and the five shapes that
# really are moot once their PRs are terminal still retire, or this is a blanket
# disable of rule 3 rather than a fix to it.
#
# AND AN ALLOWLIST ENTRY IS A SHAPE, NEVER A LANE TAG (round 4). Round 3's entry
# 5 was `[pr-url-reconcile]` — the whole lane, by tag — but that lane raises
# THREE shapes and only one of them presumes an open PR:
#   bin/pr-url-reconcile.sh:342  `<url> owes a verdict and nothing can produce
#                                one — the merge conductor is not armed`  (open)
#   bin/pr-url-reconcile.sh:492  `review says APPROVE but the only PR on
#                                <branch> (<url>) is CLOSED without merging —
#                                reopen it, or open a new one`  (the premise IS
#                                the terminal: a CLOSED read CONFIRMS it)
#   bin/pr-url-reconcile.sh:527  `record <bd> carries PR: <a> but <branch>
#                                resolves to <b> — mislinked, left untouched`
#                                (the condition is a wrong record on DISK, which
#                                no PR state can moot: both urls read terminal
#                                and the record is still wrong)
# The five fixtures below are the REAL emitter texts of those three plus the
# responder's, not a paraphrase: the round-3 fixture for this entry
# (`… resolves to no open PR`) is a sentence no script in bin/ writes, which is
# how a tag-wide entry passed a suite that thought it was testing a shape.
reset
for n in 695 1677 1689 2606 2607 2608 2609 2610 2611 2612 2613 2614 2615 2616 2617 2618 2619; do
  case $n in
    695)  echo "https://github.com/example-org/project-1/pull/$n MERGED" >> "$T/prmap" ;;
    1677|1689) echo "https://github.com/example-org/project-4/pull/$n MERGED" >> "$T/prmap" ;;
    2613|2616|2619) echo "https://github.com/example-org/project-5/pull/$n CLOSED" >> "$T/prmap" ;;
    *)    echo "https://github.com/example-org/project-5/pull/$n MERGED" >> "$T/prmap" ;;
  esac
done
# --- the five that must be KEPT (their premise IS the merge) ---
spool_akey 1 "prodqa:project-1:c70132c3" "PROD QA FAILED after merge: TK-316-remote20260919180102 is live at https://os.project-1.example and a real signed-in drive found defects (https://github.com/example-org/project-1/pull/695)"
spool_akey 1 "migration:example-org/project-4#1677" "PR #1677 shipped migration SQL — confirm it is applied to prod (TK-1934: the plan this build was executed from)"
spool 1 "[orchestrator/merge-conductor] conductor: example-org/project-5 READY — mergify queue not answering for example-org/project-5 — merged directly (degraded). The queue was asked and acknowledged nothing, so the conductor bypassed it to keep the lane draining; activate the Merge Queue product or check the app install: https://github.com/example-org/project-5/pull/2606"
spool_akey 1 "hb-alert:box-project-4-1:697" "box-project-4-1 ALERTS: 2026-09-19T22:13:41Z project-4 TK-1874 (TK-1531.3): PR https://github.com/example-org/project-4/pull/1689 merged at 2026-09-19T22:06:19Z and the deploy was never requested"
spool 1 "unknown-lane-control: the shipping lane is unhappy about https://github.com/example-org/project-5/pull/2607 and nobody has taught this script its shape yet"
# --- and the three the round-3 allowlist admitted by lane tag / by one word ---
spool 1 "[pr-url-reconcile] project-5/TK-2633: review says APPROVE but the only PR on ticket/TK-2633 (https://github.com/example-org/project-5/pull/2613) is CLOSED without merging (record pool-project-5-TK-2633-202609180708) — reopen it, or open a new one: gh pr create --head ticket/TK-2633 --base main -R example-org/project-5"
spool 1 "[pr-url-reconcile] project-5/TK-2634: record pool-project-5-TK-2634-202609180708 carries PR: https://github.com/example-org/project-5/pull/2614 but ticket/TK-2634 resolves to https://github.com/example-org/project-5/pull/2615 — mislinked, left untouched; fix the PR: line by hand, then rm /root/harness/pool/project-5-TK-2634/.pr-url-reconcile-mislinked to re-arm"
spool 1 "RESPONDER: TK-2635: PR https://github.com/example-org/project-5/pull/2616 was CLOSED without merging and the ticket is still OPEN on the board — decide: rebuild or close TK-2635"
# --- and the second lock, on a line that IS allowlisted: the responder writes
#     free prose and quotes other lanes' findings in it, so an OPEN/CLEAN pair
#     (entry 4) and a "was CLOSED without merging" premise can share one line.
spool 1 "RESPONDER: TK-2636 waits on https://github.com/example-org/project-5/pull/2618 OPEN/CLEAN, but its predecessor https://github.com/example-org/project-5/pull/2619 was CLOSED without merging and nobody reopened it — decide: rebuild or close TK-2636"
# --- the five allowlisted shapes, which must still retire ---
spool 1 "[orchestrator/merge-conductor] conductor: example-org/project-5#2608 HEAD_MOVED — 60m in HEAD_MOVED: reviewed 46f07059 head 3629fea8 (verdict=APPROVE ci=green mergeState=DIRTY mode=merge) — https://github.com/example-org/project-5/pull/2608"
spool 1 "[pipeline-health] https://github.com/example-org/project-5/pull/2609 is APPROVE (record pool-project-5-TK-2631-202609191032), OPEN and CLEAN for 30m and the merge sweep has not landed it."
spool 1 "Merge queue: #2610 has a semantic conflict with main (lander attempted and declined) — needs a hand: https://github.com/example-org/project-5/pull/2610"
spool 1 "RESPONDER: TK-2631 waits on https://github.com/example-org/project-5/pull/2611: OPEN/BLOCKED CHANGES_REQUESTED at ed21bcf3"
spool 1 "[pr-url-reconcile] project-5/TK-2631: https://github.com/example-org/project-5/pull/2612 owes a verdict and nothing can produce one — the merge conductor is not armed (flags/merge-conductor-actions absent, or MC_REREVIEW_ON_MOVE=0), so no lane will re-review it. Record pool-project-5-TK-2631-202609180708, job none, branch ticket/TK-2631-r2. Arm the conductor, or review the PR by hand."
run
inprompts "PROD QA FAILED after merge" \
  && ok || bad "14: 'PROD QA FAILED after merge' is raised BECAUSE the PR merged — a MERGED read confirms it, it never retires it"
inprompts "shipped migration SQL" \
  && ok || bad "14: 'shipped migration SQL — confirm it is applied to prod' must survive its own MERGED read"
! grep -q 'project-4/pull/1677' "$T/prstate.calls" \
  && ok || bad "14: and no lookup may be spent on it at all — an akey is a routing key, not something the alert SAYS"
inprompts "merged directly (degraded)" \
  && ok || bad "14: the conductor's READY 'merged directly (degraded)' has a NON-terminal state word and must still be kept"
inprompts "merged at 2026-09-19T22:06:19Z" \
  && ok || bad "14: an hb-alert relay of a merged-PR line is not a lane this script judges — keep it"
inprompts "unknown-lane-control" \
  && ok || bad "14: a shape no rule claims KEEPS its line — the default is keep, so a new lane is born safe"
! inprompts "60m in HEAD_MOVED" \
  && ok || bad "14: ALLOWLIST CONTROL — the conductor's own in-flight state line must still retire when its PR is terminal"
! inprompts "OPEN and CLEAN for 30m" \
  && ok || bad "14: ALLOWLIST CONTROL — pipeline-health's un-landed-approval line must still retire"
! inprompts "Merge queue: #2610" \
  && ok || bad "14: ALLOWLIST CONTROL — a merge-queue conflict on a merged PR must still retire"
! inprompts "OPEN/BLOCKED CHANGES_REQUESTED" \
  && ok || bad "14: ALLOWLIST CONTROL — a RESPONDER line waiting on an OPEN pr must still retire"
! inprompts "owes a verdict" \
  && ok || bad "14: ALLOWLIST CONTROL — the one pr-url-reconcile shape that presumes an open PR must still retire"
# --- and the four the tag-wide / one-word entries were admitting ---
inprompts "is CLOSED without merging (record" \
  && ok || bad "14: 'APPROVE but the only PR is CLOSED without merging — reopen it' is raised BECAUSE the PR is closed: a CLOSED read confirms it"
inprompts "mislinked, left untouched" \
  && ok || bad "14: a mislinked RECORD is wrong whatever the two PRs read — no PR state moots it"
inprompts "still OPEN on the board" \
  && ok || bad "14: 'the PR was CLOSED and the TICKET is still OPEN' — the word OPEN names the ticket, not the PR"
inprompts "but its predecessor" \
  && ok || bad "14: SECOND LOCK — an allowlisted OPEN/CLEAN responder line whose premise is a closed PR is still vetoed by post_terminal()"
grep -q 'STEP 0 aged=0 condstate=0 stale=5 kept=9 ' "$H/logs/alert-triage.log" \
  && ok || bad "14: exactly the five allowlisted shapes retire and the nine post-terminal/unclaimed lines stay (got: $(grep 'STEP 0' "$H/logs/alert-triage.log"))"
[ "$(cut -f2 "$ARCH" | grep -c '^NOISE-STALE$')" = 5 ] \
  && ok || bad "14: and the archive holds exactly those five (got: $(cut -f2 "$ARCH" | tr '\n' ' '))"

# ---------- 15. rule 1 is the MACHINERY-WAIT note, never a park critical -----
# mc_budget is 0 for BLOCKED_HUMAN and RED_TWICE, so a park the resolver does
# not own pages `conductor: <key> BLOCKED_HUMAN — 0m in BLOCKED_HUMAN: <why>`
# WITH --critical (tests/merge-conductor-state-notes.bh-979-test.sh block 11
# pins that it still pages) — and that text is the budget-note shape, so rule 1
# was retiring the conductor's loudest page at 6h. The rule's own header says it
# targets "waiting on this lane's own machinery", which a park is the opposite
# of: `mc_budget_check` routes parks AWAY from the state-note path on purpose.
# The three fixtures name PRs the stub does not know (rc 75 = unverifiable), so
# rule 3 cannot be what keeps or retires any of them — this block is rule 1.
reset
spool 7 "[orchestrator/merge-conductor] conductor: example-org/project-5#3301 BLOCKED_HUMAN — 0m in BLOCKED_HUMAN: tightened — https://github.com/example-org/project-5/pull/3301"
spool 7 "[orchestrator/merge-conductor] conductor: example-org/project-5#3302 RED_TWICE — 0m in RED_TWICE: ci red twice on one head — https://github.com/example-org/project-5/pull/3302"
spool 7 "[orchestrator/merge-conductor] conductor: example-org/project-5#3303 STACKED_WAIT — 420m in STACKED_WAIT: waiting on the parent to merge — https://github.com/example-org/project-5/pull/3303"
run
inprompts "0m in BLOCKED_HUMAN" \
  && ok || bad "15: a 7h-old BLOCKED_HUMAN park is a --critical page a person acts on, not a machinery wait — keep it"
inprompts "0m in RED_TWICE" \
  && ok || bad "15: and so is RED_TWICE, which ages and pages exactly like it"
! inprompts "420m in STACKED_WAIT" \
  && ok || bad "15: CONTROL — a real machinery-wait note at the same age must still retire, or this is a blanket disable of rule 1"
[ "$(cut -f2 "$ARCH" | grep -c '^EXPIRED-CONDSTATE$')" = 1 ] \
  && ok || bad "15: exactly the one machinery-wait note is retired EXPIRED-CONDSTATE (got: $(cut -f2 "$ARCH" | tr '\n' ' '))"
# and the exclusion is a RULE-1 scope statement, not an exemption from the
# ceiling: at 25h the same park line goes, on rule 2, like everything else.
reset
spool 25 "[orchestrator/merge-conductor] conductor: example-org/project-5#3304 BLOCKED_HUMAN — 0m in BLOCKED_HUMAN: tightened — https://github.com/example-org/project-5/pull/3304"
run
! inprompts "0m in BLOCKED_HUMAN" \
  && ok || bad "15: past the 24h ceiling a park note retires like any other line"
[ "$(cut -f2 "$ARCH" | grep -c '^EXPIRED-AGE$')" = 1 ] \
  && ok || bad "15: and it is archived EXPIRED-AGE, not EXPIRED-CONDSTATE (got: $(cut -f2 "$ARCH" | tr '\n' ' '))"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
