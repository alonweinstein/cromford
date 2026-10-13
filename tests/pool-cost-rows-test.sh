#!/bin/bash
# tests/pool-cost-rows-test.sh — a Fly pool machine's cost rows reach the DB
# while it runs, and reach it anyway when the machine dies mid-flight.
#
# DRIVEN, NOT GREPPED, wherever behaviour is the claim. The cost-rows block of
# fly/builder-runner.sh, the identity line of fly/entrypoint.sh and
# push_pool_cost_rows from bin/fly-pool.sh are EXTRACTED from the real files and
# executed against a stub worker, so a version that gets any of this wrong fails
# here rather than passing a grep:
#
#   1. identity — fly/entrypoint.sh's COST_ROWS_BOX is pool-<project>-<mid> on a
#      pool machine and builder-<project> on a volume builder, and the runner
#      picks it up.
#   2. the machine's loop — a push every COST_ROWS_PUSH_S, under that box id,
#      started only after the hub's env+job push has landed.
#   3. the final flush — EVERY terminal path of a job (RESULT written, deferral,
#      BUILD_ERROR, adopted PR, SMOKE) pushes once, with the RESULT already on
#      disk; EXIT/TERM/INT traps push on the crash path.
#   4. fail-open — a push that fails, times out or is switched off never changes
#      the job's return code.
#   5. the hub reap — pushes the reaped cost.csv under the MACHINE's box id,
#      logs "cost rows: pushed N (M dup) for pool-<p>-<mid>", is idempotent
#      across re-reaps, and never touches the hub's own logs/cost.csv.
#   6. no double identity — no path anywhere re-labels pool rows as the hub's.
#   7. --verify — rows still owed, reconciled, and a DB that cannot be read
#      reported as unknown rather than as zero.
#   8. kill switches — COST_ROWS_PUSH=0 and flags/cost-rows-push-off stop the
#      machine loop AND the hub reap, because both run the same file.
# Run from anywhere: tests/pool-cost-rows-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/wait-for.sh" || exit 1  # BH-6049: TERM only once the traps are armed
# BH-3223: this suite asserts the POST to its own stub; the sandbox flag would refuse it.
unset HARNESS_TEST_SANDBOX
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin" "$T/env" "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/builds" "$T/fakebin" "$T/drv"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

HDR16="ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account"
ROW="2026-09-14T10:00:00Z,pool-project-5-9080ee,project-5,execute,claude,claude-opus-5,0,600,10,20,0,0"

# ---------------------------------------------------------------------------
# stub worker: records every request, answers per CURL_* env. No network.
# ---------------------------------------------------------------------------
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}") ;; esac
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in down) exit 7 ;; err500) printf 'boom\n500\n'; exit 0 ;; esac
if [ "$METHOD" = GET ]; then
  N="${CURL_DBROWS:-0}"; R=""
  for i in $(seq 1 "$N" 2>/dev/null); do R="$R{\"row_hash\":\"h$i\"},"; done
  printf '{"cost_rows":[%s]}\n200\n' "${R%,}"; exit 0
fi
ACC=$(printf '%s' "$BODY" | jq '.rows | length' 2>/dev/null || echo 1)
INS="${CURL_INSERTED:-$ACC}"
printf '{"accepted":%s,"inserted":%s}\n200\n' "$ACC" "$INS"
CURL
chmod +x "$T/fakebin/curl"

# the real pusher + client, in a real harness tree
cp "$DIR/bin/cost-rows-push.sh" "$DIR/bin/jobs-client.sh" "$T/bin/"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
echo "HARNESS_SECRET=test-secret" > "$T/env/global.env"

# ===========================================================================
# 1. identity — the ONE expression that names a pool machine's cost rows
# ===========================================================================
# Extracted from fly/entrypoint.sh so a change to that line changes this answer.
sed -n '/^if \[ "\${POOL_MODE:-}" = "1" \]; then HOST=/,/^export COST_ROWS_BOX=/p' \
  "$DIR/fly/entrypoint.sh" > "$T/drv/ident.sh"
[ -s "$T/drv/ident.sh" ] && grep -q 'export COST_ROWS_BOX' "$T/drv/ident.sh" \
  && ok || bad "could not extract the identity lines from fly/entrypoint.sh — did the HOST/COST_ROWS_BOX block move?"
ident() { # ident <pool-mode> <machine-id>
  ( export PROJECT=project-5 POOL_MODE="$1" FLY_MACHINE_ID="$2"
    log() { :; }; hostname() { :; }
    # shellcheck source=/dev/null
    . "$T/drv/ident.sh" >/dev/null 2>&1
    echo "$COST_ROWS_BOX" )
}
[ "$(ident 1 9080ee2f34d786)" = "pool-project-5-9080ee2f34d786" ] \
  && ok || bad "a pool machine must own box pool-<project>-<machine-id>, got '$(ident 1 9080ee2f34d786)'"
[ "$(ident "" "")" = "builder-project-5" ] \
  && ok || bad "a volume builder keeps builder-<project>, got '$(ident "" "")'"
[ "$(ident 1 9080ee2f34d786)" != "project-5" ] \
  && ok || bad "a pool machine must NEVER report the owning box's id — that is the double-count"

# ===========================================================================
# 2-4. the machine's loop, the final flush, fail-open
# ===========================================================================
# The cost-rows block and the run_job wrapper, lifted verbatim out of the runner.
sed -n '/^# --- cost rows: the machine pushes its OWN bill while it runs/,/^load_env() {/p' \
  "$DIR/fly/builder-runner.sh" | sed '$d' > "$T/drv/costblock.sh"
awk '/^run_job\(\) \{/,/^\}/' "$DIR/fly/builder-runner.sh" > "$T/drv/runjob.sh"
grep -E "^trap '.*cost_rows_flush" "$DIR/fly/builder-runner.sh" > "$T/drv/traps.sh"
grep -q 'cost_rows_flush' "$T/drv/costblock.sh" && grep -q '_run_job' "$T/drv/runjob.sh" \
  && [ "$(grep -c '' "$T/drv/traps.sh")" -ge 3 ] \
  && ok || bad "could not extract the cost-rows block / run_job wrapper / traps from fly/builder-runner.sh"

# A recorder in place of the real pusher: it writes what box it was asked for,
# and whether the job's RESULT was already on disk when it ran.
mkdir -p "$T/mach/bin" "$T/mach/flags" "$T/mach/logs"
cat > "$T/mach/bin/cost-rows-push.sh" <<'REC'
#!/bin/bash
printf '%s result=%s\n' "${1:-NOBOX}" "$([ -f "$RESULT_PROBE" ] && echo present || echo absent)" >> "$PUSH_SINK"
[ "${PUSH_RC:-0}" = 0 ] || exit "${PUSH_RC}"
REC
chmod +x "$T/mach/bin/cost-rows-push.sh"

# driver: the runner's own code, a fake job, nothing else
cat > "$T/drv/run.sh" <<'DRV'
#!/bin/bash
set -uo pipefail
HARNESS="$MACH"; PROJECT=project-5
log() { :; }
# shellcheck source=/dev/null
. "$COSTBLOCK"
_run_job() { [ -n "${RESULT_TEXT:-}" ] && echo "$RESULT_TEXT" > "$RESULT_PROBE"; return "${JOB_RC:-0}"; }
# shellcheck source=/dev/null
. "$RUNJOB"
[ "${WITH_TRAPS:-0}" = 1 ] && { . "$TRAPS"; }
case "${DRIVE:-job}" in
  job)   run_job; echo "run_job rc=$?" ;;
  loop)  COST_ROWS_PUSH_S="${LOOP_S:-1}"; start_cost_rows_loop; sleep "${LOOP_FOR:-3}"
         # never `kill ${CR_PID:-0}`: with the loop switched off CR_PID is unset
         # and pid 0 is the whole process group, test runner included.
         [ -n "${CR_PID:-}" ] && kill "$CR_PID" 2>/dev/null; true ;;
  crash) exit 0 ;;
  # short sleeps, like the runner's own idle loop: bash defers a trap until the
  # foreground command returns, so a single long sleep would swallow the TERM.
  # ARMED (BH-6049): the traps are installed above, so a TERM from now on is
  # handled. The test waits for this file instead of a fixed sleep.
  hang)  [ -n "${ARMED:-}" ] && : > "$ARMED"; while :; do sleep 0.2; done ;;
esac
DRV
chmod +x "$T/drv/run.sh"

drive() { # drive <env-assignments...>  -> prints run_job's rc line
  rm -f "$T/push.log" "$T/result"
  env MACH="$T/mach" COSTBLOCK="$T/drv/costblock.sh" RUNJOB="$T/drv/runjob.sh" \
      TRAPS="$T/drv/traps.sh" PUSH_SINK="$T/push.log" RESULT_PROBE="$T/result" \
      COST_ROWS_BOX=pool-project-5-9080ee "$@" \
      bash "$T/drv/run.sh" 2>/dev/null
}
pushes() { grep -c '' "$T/push.log" 2>/dev/null || echo 0; }

# --- every terminal path of a job flushes exactly once, RESULT already written
for CASE in "PR_CREATED https://github.com/x/y/pull/1|0" \
            "BUILD_DEFERRED disk 94% used on /data|1" \
            "BUILD_DEFERRED warm-up failed|1" \
            "BUILD_ERROR malformed job.json|1" \
            "BUILD_ERROR no build dir/RESULT produced for TK-1|0" \
            "SMOKE_OK claude reachable|0" \
            "PR_CREATED https://github.com/x/y/pull/2 (adopted on retry)|0"; do
  RT="${CASE%|*}"; RC="${CASE##*|}"
  OUT=$(drive RESULT_TEXT="$RT" JOB_RC="$RC")
  [ "$(pushes)" = 1 ] \
    || bad "terminal path '$RT' pushed $(pushes) times, expected exactly 1"
  grep -q 'result=present' "$T/push.log" \
    || bad "terminal path '$RT' flushed BEFORE the RESULT was on disk: $(cat "$T/push.log")"
  [ "$OUT" = "run_job rc=$RC" ] \
    || bad "terminal path '$RT' changed the job's rc: $OUT"
done
ok
grep -q '^pool-project-5-9080ee ' "$T/push.log" \
  && ok || bad "the flush must push under the machine's box id: $(cat "$T/push.log")"

# --- fail-open: a pusher that fails, or times out, never fails the job -------
OUT=$(drive RESULT_TEXT="PR_CREATED x" JOB_RC=0 PUSH_RC=7)
[ "$OUT" = "run_job rc=0" ] && [ "$(pushes)" = 1 ] \
  && ok || bad "a failed push must not change the job's rc: $OUT"
OUT=$(drive RESULT_TEXT="BUILD_DEFERRED x" JOB_RC=1 PUSH_RC=124)
[ "$OUT" = "run_job rc=1" ] && ok || bad "a timed-out push must not change a deferral's rc: $OUT"

# --- the periodic loop pushes on its own cadence ----------------------------
drive DRIVE=loop LOOP_S=1 LOOP_FOR=3 >/dev/null
[ "$(pushes)" -ge 2 ] \
  && ok || bad "the periodic loop pushed $(pushes) times in 3s at a 1s cadence, expected >=2"

# --- the crash path: EXIT and TERM both flush -------------------------------
drive DRIVE=crash WITH_TRAPS=1 >/dev/null
[ "$(pushes)" = 1 ] && ok || bad "the EXIT trap must flush once on an abnormal/idle exit, got $(pushes)"
rm -f "$T/push.log" "$T/result"
# `env ... bash`, NOT `( export ...; bash ) &`: a subshell with more than one
# command in it is a process of its OWN, so $! is the subshell and the TERM goes
# to the wrapper while the runner underneath never sees it — the trap would look
# broken here while working perfectly on a real machine, which is the wrong way
# round for a test. `env` makes the runner itself the background job, the same
# way `fly machine stop` signals the runner itself.
env MACH="$T/mach" COSTBLOCK="$T/drv/costblock.sh" RUNJOB="$T/drv/runjob.sh" \
    TRAPS="$T/drv/traps.sh" PUSH_SINK="$T/push.log" RESULT_PROBE="$T/result" \
    COST_ROWS_BOX=pool-project-5-9080ee DRIVE=hang WITH_TRAPS=1 ARMED="$T/armed" \
    bash "$T/drv/run.sh" 2>/dev/null & DPID=$!
wait_file "$T/armed"; kill -TERM "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null
# EXACTLY one: the TERM handler clears the EXIT trap, so a machine being stopped
# does not spend its shutdown grace period on a second push with nothing to send.
[ "$(pushes)" = 1 ] \
  && ok || bad "a TERM (fly machine stop) must flush exactly once before dying, got $(pushes) pushes"

# --- kill switches stop the machine loop ------------------------------------
drive RESULT_TEXT="PR_CREATED x" JOB_RC=0 COST_ROWS_PUSH=0 >/dev/null
[ "$(pushes)" = 0 ] && ok || bad "COST_ROWS_PUSH=0 must stop the machine's push"
touch "$T/mach/flags/cost-rows-push-off"
drive RESULT_TEXT="PR_CREATED x" JOB_RC=0 >/dev/null
[ "$(pushes)" = 0 ] && ok || bad "flags/cost-rows-push-off must stop the machine's push"
drive DRIVE=loop LOOP_S=1 LOOP_FOR=2 >/dev/null
[ "$(pushes)" = 0 ] && ok || bad "the flag must stop the periodic loop too"
rm -f "$T/mach/flags/cost-rows-push-off"
drive RESULT_TEXT="PR_CREATED x" JOB_RC=0 >/dev/null
[ "$(pushes)" = 1 ] && ok || bad "clearing the flag must restore the push"

# --- the loop starts only AFTER the hub's env+job push has landed -----------
# (a pusher started before global.env arrives has no secret to authenticate with)
python3 - "$DIR/fly/builder-runner.sh" <<'PYEOF' && ok || bad "start_cost_rows_loop must be called after the first-job wait loop, not before"
import sys
src = open(sys.argv[1]).read().splitlines()
wait  = next(i for i, l in enumerate(src) if 'no job pushed within' in l)
start = next(i for i, l in enumerate(src) if l.strip() == 'start_cost_rows_loop')
sys.exit(0 if start > wait else 1)
PYEOF

# ===========================================================================
# 5. the hub reap — the backstop for a machine that died mid-push
# ===========================================================================
sed -n '/^# >>> pool cost rows/,/^# <<< pool cost rows/p' "$DIR/bin/fly-pool.sh" > "$T/drv/reap.sh"
grep -q 'push_pool_cost_rows()' "$T/drv/reap.sh" \
  && ok || bad "could not extract push_pool_cost_rows from bin/fly-pool.sh (are the >>> / <<< markers still there?)"

BD="$T/builds/pool-project-5-TK-701-202609141000"
mkdir -p "$BD"
{ echo "$HDR16"
  echo "$ROW,110.77,subscription,fp1,client-project-5"
  echo "$ROW,10.72,subscription,fp1,client-project-5"
  echo "$ROW,3.10,subscription,fp1,client-project-5"; } > "$BD/cost.csv"
cp "$BD/cost.csv" "$T/cost.before"
# the hub's OWN cost.csv, which must never gain a pool row
printf '%s\n%s,1.00,subscription,fp0,ops-hub\n' "$HDR16" \
  "2026-09-14T09:00:00Z,hub,project-5,triage,claude,claude-fable-5-1,0,30,1,1,0,0" > "$T/logs/cost.csv"
cp "$T/logs/cost.csv" "$T/hub-cost.before"

reap() { # reap <build-dir> <box> [env...]
  rm -f "$T/req.log" "$T/logs/fly-pool.log"
  local d="$1" b="$2"; shift 2
  # `export "$@"` and not `env ... "$@" cmd`: this subshell has to define say()
  # and STAMP() and source the extracted reap block into ITSELF, so there is no
  # child command for env to wrap. "$@" is VAR=val assignments by construction
  # (every caller passes only those), which is exactly what SC2163 cannot see.
  # shellcheck disable=SC2163
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" JOBS_URL=https://jobs.invalid \
           REQ_SINK="$T/req.log" P=project-5 LOG="$T/logs/fly-pool.log" "$@"
    STAMP() { echo TS; }
    say() { echo "$(STAMP) [pool/$P] $*" >> "$LOG"; }
    # shellcheck source=/dev/null
    . "$T/drv/reap.sh"
    push_pool_cost_rows "$d" "$b"; echo "rc=$?" )
}
[ "$(reap "$BD" pool-project-5-9080ee)" = "rc=0" ] && ok || bad "push_pool_cost_rows must always return 0 (fail-open)"
B=$(sed -E 's|^POST [^ ]+ ||' "$T/req.log")
[ "$(jq -r .box <<<"$B")" = pool-project-5-9080ee ] \
  && ok || bad "the reap must push under the MACHINE's box id, got $(jq -c .box <<<"$B" 2>/dev/null)"
[ "$(jq '.rows | length' <<<"$B")" = 3 ] && ok || bad "all 3 reaped rows should go, got $(jq '.rows|length' <<<"$B")"
grep -q 'cost rows: pushed 3 (0 dup) for pool-project-5-9080ee' "$T/logs/fly-pool.log" \
  && ok || bad "the reap must log one 'cost rows: pushed N (M dup) for <box>' line, got: $(cat "$T/logs/fly-pool.log")"
[ -s "$BD/.cost-rows.cursor" ] && ok || bad "the reap must leave a cursor in the build dir"
cmp -s "$BD/cost.csv" "$T/cost.before" && ok || bad "the reap modified the reaped cost.csv"
cmp -s "$T/logs/cost.csv" "$T/hub-cost.before" \
  && ok || bad "the reap appended pool rows into the HUB's own logs/cost.csv — that is the double count"

# --- a second reap of the same dir sends nothing (cursor) -------------------
reap "$BD" pool-project-5-9080ee >/dev/null
[ ! -s "$T/req.log" ] && ok || bad "a re-reap of the same build dir must send nothing: $(cat "$T/req.log")"
grep -q 'cost rows: pushed 0 (0 dup)' "$T/logs/fly-pool.log" \
  && ok || bad "a re-reap should still say what it did: $(cat "$T/logs/fly-pool.log")"

# --- the machine already pushed these rows: the PK absorbs them, and the log
#     says so — a full dup count IS the evidence the machine's loop worked ----
rm -f "$BD/.cost-rows.cursor"
reap "$BD" pool-project-5-9080ee CURL_INSERTED=0 >/dev/null
grep -q 'cost rows: pushed 3 (3 dup) for pool-project-5-9080ee' "$T/logs/fly-pool.log" \
  && ok || bad "rows the machine already landed must be reported as dup: $(cat "$T/logs/fly-pool.log")"

# --- a machine that died with rows the loop never sent: they land here -------
rm -f "$BD/.cost-rows.cursor"
echo "$ROW,42.00,subscription,fp1,client-project-5" >> "$BD/cost.csv"
reap "$BD" pool-project-5-9080ee CURL_INSERTED=1 >/dev/null
B=$(sed -E 's|^POST [^ ]+ ||' "$T/req.log")
[ "$(jq '[.rows[].cost_usd] | index("42.00")' <<<"$B")" != null ] \
  && ok || bad "the row the dying machine never pushed must land on the reap: $(jq -c '[.rows[].cost_usd]' <<<"$B")"
grep -q 'cost rows: pushed 4 (3 dup)' "$T/logs/fly-pool.log" \
  && ok || bad "the reap should report 4 pushed, 3 of them dup: $(cat "$T/logs/fly-pool.log")"

# --- a build dir with no cost.csv, and the kill switches --------------------
mkdir -p "$T/builds/empty"
reap "$T/builds/empty" pool-project-5-dead >/dev/null
[ ! -s "$T/req.log" ] && ok || bad "a build dir with no cost.csv must push nothing"
rm -f "$BD/.cost-rows.cursor"
reap "$BD" pool-project-5-9080ee COST_ROWS_PUSH=0 >/dev/null
[ ! -s "$T/req.log" ] && grep -q 'cost-rows-push is off' "$T/logs/fly-pool.log" \
  && ok || bad "COST_ROWS_PUSH=0 must stop the hub reap push and say so: $(cat "$T/logs/fly-pool.log")"
touch "$T/flags/cost-rows-push-off"
reap "$BD" pool-project-5-9080ee >/dev/null
[ ! -s "$T/req.log" ] && ok || bad "flags/cost-rows-push-off must stop the hub reap push"
rm -f "$T/flags/cost-rows-push-off"

# --- a worker outage on the reap path is fail-open and does NOT alert --------
rm -f "$T/logs/ALERTS.log" "$BD/.cost-rows.cursor"
[ "$(reap "$BD" pool-project-5-9080ee CURL_MODE=err500)" = "rc=0" ] \
  && ok || bad "a 500 on the reap push must still return 0"
# jobs-client's own once-a-day "worker unreachable" line is expected and is not
# ours; what must NOT appear is the 10-minute mirror's 3-strike cost-rows alert,
# and the reap must not touch that streak counter either.
grep -q 'cost-rows-push:' "$T/logs/ALERTS.log" 2>/dev/null \
  && bad "the reap path must not raise the cron mirror's cost-rows ALERT: $(cat "$T/logs/ALERTS.log")" || ok
[ ! -f "$T/state/cost-rows-push.fails" ] \
  && ok || bad "the reap path must not touch the box's failure streak counter"
[ "$(cat "$BD/.cost-rows.cursor" 2>/dev/null || echo 0)" = 0 ] \
  && ok || bad "a failed reap push must not advance the cursor"

# ===========================================================================
# 6. no double identity anywhere
# ===========================================================================
# The reap copies a machine's cost.csv onto the hub. Nothing may append it to
# the hub's own logs/cost.csv: those rows would then be pushed a SECOND time
# under box=hub by the hub's own 10-minute mirror, and the pool's bill would be
# counted twice under two identities.
OFF=$(grep -rn 'logs/cost\.csv"*$' "$DIR"/bin/*.sh 2>/dev/null | grep '>>' \
      | grep -v 'bin/agent-call\.sh' || true)
[ -z "$OFF" ] && ok || bad "something appends to logs/cost.csv outside agent-call.sh's cost_append:
$OFF"
# fly-pool pushes with the machine id and never with a bare project/hub id
grep -q 'push_pool_cost_rows "$LOCAL" "pool-$P-$MID"' "$DIR/bin/fly-pool.sh" \
  && ok || bad "the reap call site must name pool-\$P-\$MID — one identity, the machine's"
grep -q . <<<"$(grep -nE 'push_pool_cost_rows .*(\$BOX|hub|"\$P")\b' "$DIR/bin/fly-pool.sh" | grep -v 'pool-\$P-\$MID')" \
  && bad "a reap push under anything but the machine's box id" || ok

# ===========================================================================
# 7. --verify
# ===========================================================================
VC="$T/verify.csv"; VCUR="$T/verify.cursor"
{ echo "$HDR16"; echo "$ROW,1.00,subscription,fp1,acct"; echo ""; echo "$ROW,2.00,subscription,fp1,acct"; } > "$VC"
verify() { # verify [env...]
  local out rc
  out=$(env PATH="$T/fakebin:$PATH" HARNESS="$T" JOBS_URL=https://jobs.invalid \
            REQ_SINK="$T/req.log" "$@" \
            bash "$T/bin/cost-rows-push.sh" --verify pool-project-5-9080ee \
                 --csv "$VC" --cursor "$VCUR" 2>&1); rc=$?
  echo "$out rc=$rc"
}
rm -f "$VCUR" "$T/req.log"
V=$(verify CURL_DBROWS=0)
grep -q 'data_rows=2 cursor=0 pushed_local=0 unpushed=2' <<<"$V" \
  && ok || bad "--verify must count the two data rows and neither the header nor the blank line: $V"
grep -q 'rc=1$' <<<"$V" && ok || bad "--verify must exit 1 while rows are still owed: $V"
# push them, then verify reconciles against the DB
( export PATH="$T/fakebin:$PATH" HARNESS="$T" JOBS_URL=https://jobs.invalid REQ_SINK="$T/req.log"
  bash "$T/bin/cost-rows-push.sh" --box pool-project-5-9080ee --csv "$VC" --cursor "$VCUR" >/dev/null 2>&1 )
V=$(verify CURL_DBROWS=2)
grep -q 'pushed_local=2 unpushed=0 db_rows=2' <<<"$V" && grep -q 'rc=0$' <<<"$V" \
  && ok || bad "--verify must reconcile after a full push: $V"
V=$(verify CURL_DBROWS=1)
grep -q 'rc=1$' <<<"$V" \
  && ok || bad "--verify must fail when the DB holds fewer rows than were pushed: $V"
V=$(verify CURL_MODE=down)
grep -q 'db_rows=unknown' <<<"$V" && grep -q 'rc=2$' <<<"$V" \
  && ok || bad "a DB that cannot be read is 'unknown' and rc 2, never a silent zero: $V"

# ===========================================================================
# 8. nothing leaked
# ===========================================================================
grep -rq test-secret "$T/logs" 2>/dev/null \
  && bad "HARNESS_SECRET leaked into a log" || ok

echo "pool-cost-rows-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
