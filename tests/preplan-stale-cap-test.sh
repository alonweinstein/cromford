#!/bin/bash
# tests/preplan-stale-cap-test.sh — the pre-plan STALE re-plan cap (BH-1016).
# Run from anywhere: tests/preplan-stale-cap-test.sh   (exit 0 = all pass)
#
# WHAT THIS PINS AND WHY. A pre-plan is a paid Fable session, and until this
# change every merge that touched a file the plan named dropped the plan
# (`PREPLAN_STALE` → `rm -rf` → relaunch) and bought another one, with no
# ceiling per ticket: a queued ticket sitting behind a busy lane re-bought its
# plan every time main moved in a shared file. The 2026-09-17..19 runaway-spend
# audit measured it — project-4 bought 152 stale re-plans on 09-18 alone ($1,037
# of pre-plan spend), TK-1847 ~50 in three days — and none of it was an error:
# every script exited 0 and the bill was the only symptom.
#
# The fleet rule is ~/.claude/rules/metered-api-dedup.md: a PERSISTED "have we
# already paid for this?" check runs BEFORE the billable call, the answer is
# terminal, and terminal state is written on every non-success exit. So this
# suite drives the REAL bin/preplan-tick.sh against a real git repo with a
# recording bin/agent-call.sh, and counts the calls — because "the cap is in the
# code" and "the vendor was not called again" are two different claims, and only
# the second one is the money.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# One anchor, and every fixture stamp derived from it: this suite must not pick
# its own red day (bin/test-determinism-lint.sh).
NOW=$(date +%s)

export HARNESS="$T" FLEET_CONF="$T/fleet.conf" REPOS_ROOT="$T/repos"
mkdir -p "$T/bin/lib" "$T/env" "$T/flags" "$T/logs" "$T/locks" "$T/plans" \
         "$T/state" "$T/prompts" "$T/repos"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T" proj || exit 1  # BH-1510.2: lanes read models from model_routes
cp "$DIR/bin/lib/preplan-lib.sh" "$T/bin/lib/"
for f in preplan-tick.sh fleet-conf.sh project-of.sh fleet-projects-or-alert.sh; do
  cp "$DIR/bin/$f" "$T/bin/"
done
export PATH="$T/bin:$PATH"
. "$T/bin/lib/preplan-lib.sh"

cat > "$T/fleet.conf" <<'CONF'
proj  example-org/proj   -   -   0 local -
CONF
echo 'setsid /root/harness/bin/run-build.sh proj <issue-number> AB-<issue-number> > x' > "$T/prompts/proj.md"
printf '#!/bin/bash\necho local\n' > "$T/bin/box-name.sh"

# The candidate classifier is not what this suite is about: one queued ticket,
# every tick, so the only thing that moves is the cap.
cat > "$T/bin/preplan-candidates.sh" <<'SH'
#!/bin/bash
printf 'AB-1\t1\tqueued\n'
SH

# THE BILLABLE CALL. run-preplan.sh is the launcher; bin/agent-call.sh is what
# costs money, so that is what gets counted. The stub also leaves the record a
# real pre-plan leaves — plan.md, base-sha pinned to main AS IT IS NOW, and the
# planned-files list — because the next tick's staleness answer is computed from
# exactly those files.
cat > "$T/bin/agent-call.sh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls.txt"
SH
cat > "$T/bin/run-preplan.sh" <<'SH'
#!/bin/bash
echo "$1 $2 $3" >> "$HARNESS/launched.txt"
"$HARNESS/bin/agent-call.sh" preplan "$1" "$3" >/dev/null 2>&1
D="$HARNESS/plans/$1-$3"
mkdir -p "$D"
printf 'plan\nTouch src/lib/pay.ts\n' > "$D/plan.md"
git -C "$REPOS_ROOT/$1" rev-parse origin/main > "$D/base-sha"
echo 'src/lib/pay.ts' > "$D/planned-files.txt"
# LAST, always: the file tick() waits on. Written after every record above, so
# a tick that sees it knows the stub finished, not that it started.
echo "$1 $3" >> "$HARNESS/done.txt"
SH
chmod +x "$T/bin/box-name.sh" "$T/bin/preplan-candidates.sh" \
         "$T/bin/agent-call.sh" "$T/bin/run-preplan.sh"

mkdir -p "$T/repos/proj"
( cd "$T/repos/proj" && git init -q -b main && git config user.email t@t \
  && git config user.name t && mkdir -p src/lib src/ui \
  && echo x > src/lib/pay.ts && echo y > src/ui/card.tsx \
  && git add -A && git commit -qm base && git update-ref refs/remotes/origin/main HEAD \
) >/dev/null 2>&1

QLINE='AB-1 1 — ready project=proj  Re-checked 2026-09-19T04:15:00Z'
printf '%s\n' "$QLINE" > "$T/logs/READY-QUEUE.log"

REPLANS="$T/state/preplan/proj-AB-1.replans"
DEFER="$T/state/preplan/proj-AB-1.defer"

# main moves in a file the plan named -> the plan is stale on the next tick.
move_planned() {
  ( cd "$T/repos/proj" && echo more >> src/lib/pay.ts && git add -A \
    && git commit -qm "moved planned" && git update-ref refs/remotes/origin/main HEAD ) >/dev/null 2>&1
}
# ...and a merge that touches nothing the plan named must change no answer.
move_unplanned() {
  ( cd "$T/repos/proj" && echo more >> src/ui/card.tsx && git add -A \
    && git commit -qm "moved elsewhere" && git update-ref refs/remotes/origin/main HEAD ) >/dev/null 2>&1
}
seed_plan() {  # a FRESH pre-plan for AB-1, pinned to main as it stands now
  local d="$T/plans/proj-AB-1"
  mkdir -p "$d"
  printf 'plan\nTouch src/lib/pay.ts\n' > "$d/plan.md"
  git -C "$T/repos/proj" rev-parse origin/main > "$d/base-sha"
  echo 'src/lib/pay.ts' > "$d/planned-files.txt"
}
reset_state() {
  rm -rf "$T/plans/proj-AB-1" "$T/state/preplan"
  : > "$T/launched.txt"; : > "$T/calls.txt"; : > "$T/logs/preplan.log"
  : > "$T/done.txt"
}
# THE TICK'S CHILD IS DETACHED (`setsid … &` in bin/preplan-tick.sh), so the
# tick returns before the pre-plan it launched has recorded its call. This used
# to be a flat `sleep 0.5` — a guess that is too short on a loaded CI runner (a
# flake nobody can reproduce) and wasted time on an idle one. Wait on the
# stub's done-file instead, bounded, and only when this tick actually launched
# something: most ticks in this suite launch nothing and have nothing to wait
# for. Both counters are truncated together by reset_state, so they compare.
launched_n() { local n; n=$(grep -c 'pre-plan launch' "$T/logs/preplan.log" 2>/dev/null); printf '%s\n' "${n:-0}"; }
done_n()     { local n; n=$(grep -c . "$T/done.txt" 2>/dev/null); printf '%s\n' "${n:-0}"; }
tick() {
  local after i
  PREPLAN_PARALLEL=1 "$T/bin/preplan-tick.sh" >/dev/null 2>&1
  after=$(launched_n)
  [ "$after" -gt "$(done_n)" ] || return 0
  for i in $(seq 1 600); do
    [ "$(done_n)" -ge "$after" ] && return 0
    sleep 0.05
  done
  echo "WARN: tick: a launched pre-plan never finished (launched $after, done $(done_n))" >&2
  return 0
}
calls() { local n; n=$(grep -c . "$T/calls.txt" 2>/dev/null); printf '%s\n' "${n:-0}"; }

# ---------- 1. the knob ------------------------------------------------------
[ "$(preplan_stale_max "$T")" = 2 ] && ok \
  || bad "PREPLAN_STALE_MAX defaults to 2 (got: $(preplan_stale_max "$T"))"
[ "$(PREPLAN_STALE_MAX=1 preplan_stale_max "$T")" = 1 ] && ok \
  || bad "the env var must move the stale cap"
printf 'PREPLAN_STALE_MAX=4\n' > "$T/env/global.env"
[ "$(preplan_stale_max "$T")" = 4 ] && ok \
  || bad "env/global.env must set PREPLAN_STALE_MAX (got: $(preplan_stale_max "$T"))"
printf 'PREPLAN_STALE_MAX=nonsense\n' > "$T/env/global.env"
[ "$(preplan_stale_max "$T")" = 2 ] && ok \
  || bad "an unreadable cap falls back to 2, never to unlimited"
: > "$T/env/global.env"

# ---------- 2. the fingerprint ----------------------------------------------
FP0=$(preplan_replan_fp "$T" AB-1)
[ -n "$FP0" ] && ok || bad "the queue-line fingerprint must never be empty"
[ "$(preplan_replan_fp "$T" AB-1)" = "$FP0" ] && ok \
  || bad "the same queue line must fingerprint the same twice"
# A session restamps `Re-checked <ts>` into the queue on every no-action tick.
# If that read as a changed ticket every marker would clear every hour and the
# cap would never bite — the exact trap bin/triage-gate.sh's queue hash fell in.
printf 'AB-1 1 — ready project=proj  Re-checked 2026-09-19T21:40:11Z\n' > "$T/logs/READY-QUEUE.log"
[ "$(preplan_replan_fp "$T" AB-1)" = "$FP0" ] && ok \
  || bad "a restamped timestamp is not a changed ticket (bin/triage-gate.sh's rule)"
printf 'AB-1 1 — ready project=proj  waiting on PR #9  Re-checked 2026-09-19T04:15:00Z\n' > "$T/logs/READY-QUEUE.log"
[ "$(preplan_replan_fp "$T" AB-1)" != "$FP0" ] && ok \
  || bad "a REAL change to the queue line must change the fingerprint"
printf '%s\n' "$QLINE" > "$T/logs/READY-QUEUE.log"

# ---------- 3. (a) three merges in a planned file buy exactly two re-plans ---
reset_state; seed_plan
for _ in 1 2 3 4; do move_planned; tick; done
[ "$(calls)" = 2 ] && ok \
  || bad "(a) three stale rounds must buy exactly 2 pre-plan sessions (got $(calls): $(cat "$T/calls.txt"))"
[ -s "$DEFER" ] && ok || bad "(a) the cap must leave a terminal marker at $DEFER"
grep -q 'PREPLAN_DEFER_TO_BUILD' "$DEFER" 2>/dev/null && ok \
  || bad "(a) the marker must say PREPLAN_DEFER_TO_BUILD (got: $(cat "$DEFER" 2>/dev/null))"
[ "$(grep -c PREPLAN_SKIP "$T/logs/preplan.log")" = 1 ] && ok \
  || bad "(a) exactly ONE PREPLAN_SKIP line per key, not one per tick (got: $(grep -c PREPLAN_SKIP "$T/logs/preplan.log"))"
[ "$(grep -c PREPLAN_STALE "$T/logs/preplan.log")" = 2 ] && ok \
  || bad "(a) only the re-plans that happened may log PREPLAN_STALE (got: $(grep -c PREPLAN_STALE "$T/logs/preplan.log"))"
[ -s "$REPLANS" ] && [ "$(grep -c . "$REPLANS")" = 2 ] && ok \
  || bad "(a) the counter must persist one stamp per re-plan (got: $(cat "$REPLANS" 2>/dev/null))"

# ...and the ticket still has a plan dir on disk: the BUILD stage discards it as
# stale and plans from scratch, which is exactly the behaviour being deferred to.
[ -s "$T/plans/proj-AB-1/plan.md" ] && ok \
  || bad "(a) the deferred key keeps its last plan; the build stage judges it"
BEFORE=$(calls)
move_planned; tick; move_planned; tick
[ "$(calls)" = "$BEFORE" ] && ok \
  || bad "(a) a terminal key must stay terminal on later ticks (got $(calls), was $BEFORE)"
[ "$(grep -c PREPLAN_SKIP "$T/logs/preplan.log")" = 1 ] && ok \
  || bad "(a) later ticks on a terminal key must say nothing at all"

# ---------- 4. (b) a changed queue line clears the marker -------------------
printf 'AB-1 1 — ready project=proj  scope changed, see comment 4\n' > "$T/logs/READY-QUEUE.log"
BEFORE=$(calls)
move_planned; tick
[ "$(calls)" = "$((BEFORE+1))" ] && ok \
  || bad "(b) a changed queue line must buy exactly one more plan (got $(calls), was $BEFORE)"
[ ! -e "$DEFER" ] && ok || bad "(b) a changed queue line must clear the terminal marker"
# and the cap re-arms behind it: the budget is the full PREPLAN_STALE_MAX again,
# not one free pass and then silence.
move_planned; tick
[ "$(calls)" = "$((BEFORE+2))" ] && ok \
  || bad "(b) the cap must re-arm at the full budget after a real change (got $(calls))"
move_planned; tick
[ "$(calls)" = "$((BEFORE+2))" ] && ok \
  || bad "(b) ...and then terminalize again (got $(calls))"
[ -s "$DEFER" ] && ok || bad "(b) the second cap must leave a marker too"
grep -q "$(preplan_replan_fp "$T" AB-1)" "$DEFER" 2>/dev/null && ok \
  || bad "(b) the marker must carry the fingerprint it is terminal FOR"
printf '%s\n' "$QLINE" > "$T/logs/READY-QUEUE.log"

# ---------- 5. (c) a merge outside the planned files costs nothing ----------
reset_state; seed_plan
move_unplanned; tick
move_unplanned; tick
move_unplanned; tick
[ "$(calls)" = 0 ] && ok \
  || bad "(c) a merge that touches no planned file must launch nothing (got $(calls): $(cat "$T/calls.txt"))"
grep -q PREPLAN_STALE "$T/logs/preplan.log" && bad "(c) an unmoved plan is not stale" || ok
[ ! -e "$REPLANS" ] && ok || bad "(c) a plan that never went stale must not be counted against the cap"
[ ! -e "$DEFER" ] && ok || bad "(c) ...and must never be terminalized"

# ---------- 6. (d) a corrupt counter fails OPEN ------------------------------
reset_state; seed_plan
mkdir -p "$T/state/preplan"
printf 'not-a-stamp\n\n???\n' > "$REPLANS"
move_planned; tick
[ "$(calls)" = 1 ] && ok \
  || bad "(d) an unreadable counter must fail OPEN — one re-plan, not zero (got $(calls))"
[ "$(grep -c PREPLAN_STALE "$T/logs/preplan.log")" = 1 ] && ok \
  || bad "(d) ...with its one log line"
[ ! -e "$DEFER" ] && ok || bad "(d) a corrupt counter must not terminalize the key"
grep -qx '[0-9][0-9]*' "$REPLANS" && ok \
  || bad "(d) the counter must be REPAIRED to real stamps (got: $(cat "$REPLANS"))"
[ "$(grep -c . "$REPLANS")" = 1 ] && ok \
  || bad "(d) the garbage lines must not survive as phantom attempts (got: $(cat "$REPLANS"))"

# ---------- 7. the window: stamps and markers age out -----------------------
# Both are 24h facts, so both are driven off the anchor rather than the clock.
reset_state; seed_plan
mkdir -p "$T/state/preplan"
printf '%s\n%s\n' "$((NOW - 90000))" "$((NOW - 172800))" > "$REPLANS"
move_planned; tick
[ "$(calls)" = 1 ] && ok \
  || bad "(window) attempts older than 24h must not count against the cap (got $(calls))"
[ "$(grep -c . "$REPLANS")" = 1 ] && ok \
  || bad "(window) ...and must be pruned out of the ledger (got: $(cat "$REPLANS"))"

reset_state
mkdir -p "$T/state/preplan"
printf 'PREPLAN_DEFER_TO_BUILD %s %s\n' "$(preplan_replan_fp "$T" AB-1)" "$((NOW - 172800))" > "$DEFER"
preplan_deferred "$T" proj AB-1 "$(preplan_replan_fp "$T" AB-1)" \
  && bad "(window) a marker older than 24h must expire, not hold forever" || ok
[ ! -e "$DEFER" ] && ok || bad "(window) an expired marker must be removed"

printf 'PREPLAN_DEFER_TO_BUILD %s %s\n' "$(preplan_replan_fp "$T" AB-1)" "$NOW" > "$DEFER"
preplan_deferred "$T" proj AB-1 "$(preplan_replan_fp "$T" AB-1)" \
  && ok || bad "(window) a fresh marker whose fingerprint matches IS terminal"
preplan_deferred "$T" proj AB-1 other-fingerprint \
  && bad "(window) a marker for another fingerprint must not be terminal" || ok

# ---------- 8. PREPLAN_STALE_MAX=0 is the kill switch -----------------------
reset_state; seed_plan
move_planned
export PREPLAN_STALE_MAX=0; tick; unset PREPLAN_STALE_MAX
[ "$(calls)" = 0 ] && ok \
  || bad "PREPLAN_STALE_MAX=0 must buy no re-plan at all (got $(calls))"
[ -s "$DEFER" ] && ok || bad "PREPLAN_STALE_MAX=0 must still write terminal state"

# ---------- 9. the guard is in the tick, before the launch ------------------
# The one that cannot be driven: the ORDER. A cap that is consulted after the
# session has been launched reviews as correct and costs the money anyway.
grep -q 'preplan_deferred' "$DIR/bin/preplan-tick.sh" && ok \
  || bad "bin/preplan-tick.sh must ask preplan_deferred before it launches"
awk '/preplan_replan_allow/{a=NR} /run-preplan.sh/{if(a && NR>a){print "ok"; exit}}' \
  "$DIR/bin/preplan-tick.sh" | grep -q ok && ok \
  || bad "the cap must be consulted BEFORE bin/run-preplan.sh is launched"

# ---------- 10. the cap is OFF: SAY SO (BH-1053 I-1) ------------------------
# preplan_replan_allow fails OPEN when the ledger directory cannot exist
# (`d=$(_preplan_state "$h") || return 0`) — which is right, and was invisible:
# with state/ unwritable every stale answer was allowed and logs/preplan.log
# carried no trace at all. That is the 152-re-plans-a-day runaway running with
# nothing to find it by. The fail-open stays (failing closed is a lane that
# silently stops pre-planning); the silence does not.
reset_state; seed_plan
scratch_rm "$T/state"; : > "$T/state"      # state/ is a FILE: no ledger can exist
move_planned; tick
[ "$(calls)" = 1 ] && ok \
  || bad "(cap-off) an unwritable state/ must still ALLOW the re-plan (got $(calls))"
[ "$(grep -c PREPLAN_CAP_OFF "$T/logs/preplan.log")" = 1 ] && ok \
  || bad "(cap-off) ...and must log PREPLAN_CAP_OFF once (got: $(cat "$T/logs/preplan.log"))"
grep -q 'PREPLAN_CAP_OFF.*state/preplan' "$T/logs/preplan.log" && ok \
  || bad "(cap-off) the line must name WHY the cap is off (got: $(grep PREPLAN_CAP_OFF "$T/logs/preplan.log"))"
move_planned; tick
[ "$(calls)" = 2 ] && ok \
  || bad "(cap-off) the cap is genuinely off — every tick keeps failing open (got $(calls))"
[ "$(grep -c PREPLAN_CAP_OFF "$T/logs/preplan.log")" = 2 ] && ok \
  || bad "(cap-off) one line PER TICK, so the trace lasts as long as the fault does"
# ...but a box with nothing to judge says nothing: this is a trace on the cap
# being consulted, not a heartbeat.
: > "$T/logs/preplan.log"
cat > "$T/bin/preplan-candidates.sh" <<'SH'
#!/bin/bash
exit 0
SH
tick
[ "$(grep -c PREPLAN_CAP_OFF "$T/logs/preplan.log")" = 0 ] && ok \
  || bad "(cap-off) a tick with no candidates must log nothing (got: $(cat "$T/logs/preplan.log"))"
cat > "$T/bin/preplan-candidates.sh" <<'SH'
#!/bin/bash
printf 'AB-1\t1\tqueued\n'
SH
rm -f "$T/state"; mkdir -p "$T/state"

# ---------- 11. ...and the same line from the missing-lib shim -------------
# The tick defines no-op fallbacks so a box whose lib has not synced behaves
# exactly as it did before the cap existed. Same fail-open, same silence, same
# fix: the shim says the cap is off.
reset_state; seed_plan
cp "$T/bin/lib/preplan-lib.sh" "$T/preplan-lib.real.sh"
cat > "$T/bin/lib/preplan-lib.sh" <<'SH'
# A PARTIALLY SYNCED BOX: everything the speculative path needs except the cap.
. "$HARNESS/preplan-lib.real.sh"
unset -f preplan_replan_allow preplan_deferred preplan_replan_fp preplan_stale_max _preplan_state
SH
move_planned; tick
[ "$(calls)" = 1 ] && ok \
  || bad "(shim) a lib with no cap must fail OPEN — the re-plan still happens (got $(calls))"
[ "$(grep -c PREPLAN_CAP_OFF "$T/logs/preplan.log")" = 1 ] && ok \
  || bad "(shim) ...and the shim must say the cap is off (got: $(cat "$T/logs/preplan.log"))"
cp "$T/preplan-lib.real.sh" "$T/bin/lib/preplan-lib.sh"

# ---------- 12. a marker write that FAILS must not shout every tick --------
# The terminal marker is what stops the PREPLAN_SKIP line repeating. When the
# write cannot land (a full disk, a path that is not a file) there is no memory
# at all, so the line came back every two minutes — 720 identical lines a day in
# the one file an operator reads to find out why a ticket stopped being planned.
# The fixture is a self-referencing symlink: writing it is ELOOP for root too,
# and it leaves nothing behind, which is exactly the shape of a failed write.
reset_state; seed_plan
mkdir -p "$T/state/preplan"
printf '%s\n%s\n' "$NOW" "$NOW" > "$REPLANS"     # the budget is already spent
ln -s proj-AB-1.defer "$DEFER"
move_planned; tick
[ "$(calls)" = 0 ] && ok \
  || bad "(marker) an unwritable marker must not un-cap the key (got $(calls))"
[ "$(grep -c PREPLAN_SKIP "$T/logs/preplan.log")" = 1 ] && ok \
  || bad "(marker) the cap must still say why, once (got: $(cat "$T/logs/preplan.log"))"
[ ! -s "$DEFER" ] && ok || bad "(marker) fixture: the marker must genuinely not exist"
move_planned; tick; move_planned; tick
[ "$(grep -c PREPLAN_SKIP "$T/logs/preplan.log")" = 1 ] && ok \
  || bad "(marker) ...and must not repeat it every tick (got: $(grep -c PREPLAN_SKIP "$T/logs/preplan.log") lines)"
[ "$(calls)" = 0 ] && ok \
  || bad "(marker) ...while still buying nothing (got $(calls))"
# ONCE PER ARMING, not once per key forever: the line carries the fingerprint it
# is terminal FOR, so a ticket that really moved gets its own line when it
# spends its new budget.
grep -qF "PREPLAN_SKIP stale re-plan cap reached (fp $(preplan_replan_fp "$T" AB-1)" "$T/logs/preplan.log" && ok \
  || bad "(marker) the line must carry the fingerprint (got: $(grep PREPLAN_SKIP "$T/logs/preplan.log"))"
printf 'AB-1 1 — ready project=proj  re-scoped, see comment 7\n' > "$T/logs/READY-QUEUE.log"
move_planned; tick
[ "$(grep -c PREPLAN_SKIP "$T/logs/preplan.log")" = 2 ] && ok \
  || bad "(marker) a changed ticket must get its own line, not be swallowed (got: $(grep -c PREPLAN_SKIP "$T/logs/preplan.log"))"
printf '%s\n' "$QLINE" > "$T/logs/READY-QUEUE.log"
rm -f "$DEFER"

# ---------- 13. the choke point: the LANE itself honours the cap -----------
# (BH-1053 I-2.) bin/preplan-tick.sh asking preplan_deferred saves the
# PREPLAN_PARALLEL slot; it does not save the money, because a lane launched any
# other way — an operator by hand, the legacy path, a launcher written next
# month — walked straight past the cap and re-bought a terminalized key. The
# question belongs where the money is spent, so this drives the REAL
# bin/run-preplan.sh with a recording agent-call.sh and counts the calls.
RP="$T/rp"
mkdir -p "$RP/bin/lib" "$RP/env" "$RP/flags" "$RP/logs" "$RP/plans" "$RP/locks" \
         "$RP/state/preplan" "$RP/repos/proj"
model_routes_fixture "$RP" proj || exit 1  # BH-1510.2: this root runs a converted lane too
cp "$DIR/bin/run-preplan.sh" "$RP/bin/"
cp "$DIR/bin/lib/preplan-lib.sh" "$RP/bin/lib/"
: > "$RP/env/global.env"
cat > "$RP/bin/agent-call.sh" <<'STUB'
#!/bin/bash
echo "$2 $1" >> "$HARNESS/calls.txt"
printf 'answer\n' > "$5"
exit 0
STUB
cat > "$RP/bin/git" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$RP/bin/agent-call.sh" "$RP/bin/git"
lane() { # lane <KEY> -> the lane's own rc, from one real run against the scratch tree
  ( export PATH="$RP/bin:$PATH" HARNESS="$RP" REPOS_ROOT="$RP/repos"
    bash "$RP/bin/run-preplan.sh" proj 1 "$1" >/dev/null 2>&1 )
}
rp_calls() { local n; n=$(grep -c . "$RP/calls.txt" 2>/dev/null); printf '%s\n' "${n:-0}"; }

: > "$RP/calls.txt"; : > "$RP/logs/preplan.log"
lane AB-90
[ "$(rp_calls)" = 1 ] && ok \
  || bad "(choke) fixture: a key with no marker must actually run (got $(rp_calls))"

# a DEFERRED key, run by hand: no session, one line, rc 0, no adoptable dir
: > "$RP/calls.txt"; : > "$RP/logs/preplan.log"
printf 'PREPLAN_DEFER_TO_BUILD %s %s\n' "$(preplan_replan_fp "$RP" AB-91)" "$NOW" \
  > "$RP/state/preplan/proj-AB-91.defer"
lane AB-91; LRC=$?
[ "$(rp_calls)" = 0 ] && ok \
  || bad "(choke) a deferred key must buy NO pre-plan session (got $(rp_calls))"
[ "$LRC" = 0 ] && ok || bad "(choke) a deferred key is a decision, not a failure (rc=$LRC)"
[ "$(grep -c 'PREPLAN_SKIP deferred' "$RP/logs/preplan.log")" = 1 ] && ok \
  || bad "(choke) ...and must say so once (got: $(cat "$RP/logs/preplan.log"))"
[ ! -e "$RP/plans/proj-AB-91" ] && ok \
  || bad "(choke) a refused pre-plan must leave no directory a build could adopt"
# ...and the guard is asked BEFORE the billable call, not after it
awk '/preplan_deferred/{a=NR} /agent-call.sh" preplan/{if(a && NR>a){print "ok"; exit}}' \
  "$DIR/bin/run-preplan.sh" | grep -q ok && ok \
  || bad "(choke) preplan_deferred must be consulted BEFORE bin/agent-call.sh"

# an expired marker is not terminal: the lane runs and the marker is cleared
: > "$RP/calls.txt"
printf 'PREPLAN_DEFER_TO_BUILD %s %s\n' "$(preplan_replan_fp "$RP" AB-92)" "$((NOW - 172800))" \
  > "$RP/state/preplan/proj-AB-92.defer"
lane AB-92
[ "$(rp_calls)" = 1 ] && ok \
  || bad "(choke) a marker older than the window must not hold the lane (got $(rp_calls))"
# ...and neither is a marker for a different fingerprint
: > "$RP/calls.txt"
printf 'PREPLAN_DEFER_TO_BUILD %s %s\n' other-fingerprint "$NOW" \
  > "$RP/state/preplan/proj-AB-93.defer"
lane AB-93
[ "$(rp_calls)" = 1 ] && ok \
  || bad "(choke) a marker for another ticket state must not hold the lane (got $(rp_calls))"

echo "preplan-stale-cap: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
