#!/bin/bash
# tests/jobs-client-test.sh — the coordination client is FAIL-OPEN, and this
# drives bin/agent-call.sh + bin/jobs-client.sh for real to prove it.
#
# WHY DRIVEN AND NOT GREPPED. The whole value of phase 1 (docs/DB-COORDINATION-
# SPEC.md) rests on one property: when harness-jobs is unreachable, slow, or
# wrong, every box keeps building exactly as it does today. That is a claim
# about control flow under failure, and the only honest way to check it is to
# make the calls fail and read back what the runner was actually handed. A
# `grep -q job_cap bin/agent-call.sh` would pass just as happily on a version
# that hard-fails the build when the worker 500s.
#
# curl is stubbed (no network in tests), so what is proven is the SHELL side:
# rc mapping, the 409 double-build signal, the DB-first budget, and the
# fall-through. The worker's own behaviour is proven by its smoke run, not here.
# Run from anywhere: tests/jobs-client-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/logs" "$T/locks" "$T/flags" "$T/fakebin" "$T/bin" "$T/state"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# Fake curl: answers per CURL_MODE and records the request body it was given.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; BODY=""
# Real curl reads `--data-binary @file` from the file; the client sends every
# body that way (argv bodies hit E2BIG on batch endpoints), so the stub does too.
while [ $# -gt 0 ]; do case "$1" in --data-binary) BODY="$2"; case "$BODY" in @*) BODY=$(cat "${BODY#@}");; esac; shift 2;; *) shift;; esac; done
[ -n "${REQ_SINK:-}" ] && printf '%s\n' "$URL $BODY" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in
  down)   exit 7 ;;                                   # transport failure
  err500) printf 'boom\n500\n'; exit 0 ;;
  conflict)
    printf '{"error":"already in flight on another box","job":{"id":"build-p-T1-1","box":"other-box"}}\n409\n'; exit 0 ;;
  # The misc-family tier the worker returns since 2026-08-30 ($10, raised from
  # $3). As above, a tier answer is a miss whatever number rides with it.
  tier)   printf '{"lane":"x","matched":null,"budget_usd":10,"source":"tier"}\n200\n'; exit 0 ;;
  miss)   printf '{"error":"not found"}\n404\n'; exit 0 ;;
  *)
    case "$URL" in
      */api/ledger*)   printf '{"ledger":{"kind":"merge","key":"k","status":"merged"}}\n200\n' ;;
      */api/catalog/*) printf '{"lane":"x","matched":"eval/*/*","budget_usd":77.77,"source":"catalog"}\n200\n' ;;
      */api/jobs/*/events) printf '{"event_id":1}\n201\n' ;;
      */api/jobs/*)    printf '{"job":{"id":"build-p-T1-1","spent_usd":1.5}}\n200\n' ;;
      */api/jobs)      printf '{"job":{"id":"build-p-T1-1","budget_usd":7.77}}\n201\n' ;;
      *)               printf '{}\n404\n' ;;
    esac ;;
esac
EOF
chmod +x "$T/fakebin/curl"
# Fake claude + timeout + billing-mode, same shape as agent-call-notools-test.
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$ARGV_SINK"
printf '{"result":"ok","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}\n'
EOF
chmod +x "$T/fakebin/claude"
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
chmod +x "$T/fakebin/timeout"
printf '#!/bin/bash\necho subscription\n' > "$T/fakebin/billing-mode.sh"; chmod +x "$T/fakebin/billing-mode.sh"

budget_of() { awk '/^--max-budget-usd$/{getline v; print v}' "$T/argv.txt"; }
run_call() { # run_call <extra-env...>
  rm -f "$T/argv.txt"
  ( export ARGV_SINK="$T/argv.txt" PATH="$T/fakebin:$PATH" HARNESS="$T" \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" HOME="$T" \
           HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid
    "$@" bash "$DIR/bin/agent-call.sh" eval testproj claude-fable-5 60 "$T/out.txt" "hello" \
      >/dev/null 2>&1 )
  echo $?
}

# --- 1. DB-first: a catalog answer becomes the per-call dollar bound ----------
RC=$(run_call env CURL_MODE=ok)
[ -s "$T/argv.txt" ] || bad "the claude lane was never invoked (rc=$RC)"
[ "$(budget_of)" = "77.77" ] \
  && ok || bad "the DB lane cap did not reach --max-budget-usd (got '$(budget_of)')"

# --- 2. FAIL-OPEN: the API being down changes NOTHING ------------------------
# eval is prompt-eval in the manifest (120K ceiling) -> $3.15 derived, floored
# to the misc-stage $25 max-cost failsafe (ae3e20a: caps are runaway tripwires,
# so every resolved number below the family floor rises to it — the DB's 77.77
# above stays observable because it exceeds the floor). Any other number here
# means the coordination layer moved a live budget.
RC=$(run_call env CURL_MODE=down)
[ "$(budget_of)" = "25.00" ] \
  && ok || bad "with harness-jobs down the eval lane budget changed to '$(budget_of)' (expected the floored file chain's 25.00)"
[ "$RC" = 0 ] && ok || bad "a call with harness-jobs down exited $RC — an outage in a side channel must never fail a stage"
RC=$(run_call env CURL_MODE=err500)
[ "$(budget_of)" = "25.00" ] \
  && ok || bad "a 500 from harness-jobs changed the budget to '$(budget_of)'"

# --- 3. a TIER answer must not mask an unbudgeted lane -----------------------
# The DB replying "no lane, here is the tier" is the same fact as the file
# saying it. It has to fall through, or the UNBUDGETED LANE alert never fires
# again fleet-wide and lane gaps become invisible.
rm -f "$T/flags/alerted-unbudgeted-lane-"*
RC=$(run_call env CURL_MODE=tier)
[ "$(budget_of)" = "25.00" ] \
  && ok || bad "a tier answer from the DB short-circuited the file chain (got '$(budget_of)')"

# --- 4. the client's own rc contract ----------------------------------------
probe() { # probe <curl-mode> <shell-snippet>
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=test-box CURL_MODE="$1" REQ_SINK="$T/req.txt"
    # shellcheck source=/dev/null
    . "$T/bin/jobs-client.sh"; eval "$2" )
}
OUT=$(probe conflict 'job_open p T1 build plan; echo " rc=$?"')
case "$OUT" in
  "IN_FLIGHT other-box build-p-T1-1 rc=9") ok ;;
  *) bad "a 409 must surface as rc=9 plus the holding box, got: $OUT" ;;
esac
OUT=$(probe down 'job_open p T1 build plan; echo "rc=$?"')
[ "$OUT" = "rc=1" ] && ok || bad "an unreachable API must fail QUIETLY with rc=1, got: $OUT"
OUT=$(probe ok 'job_cap eval/testproj/claude; echo " rc=$?"')
[ "$OUT" = "77.77 rc=0" ] && ok || bad "job_cap on a catalog hit, got: $OUT"
OUT=$(probe tier 'job_cap eval/testproj/claude; echo "rc=$?"')
[ "$OUT" = "rc=1" ] && ok || bad "job_cap must return nonzero on a tier fallback, got: $OUT"
OUT=$( ( export PATH="$T/fakebin:$PATH" HARNESS="$T" JOBS_URL=https://jobs.invalid
         unset HARNESS_SECRET
         # shellcheck source=/dev/null
         . "$T/bin/jobs-client.sh"; job_cap eval/testproj/claude; echo "rc=$?" ) )
[ "$OUT" = "rc=1" ] && ok || bad "a box with no HARNESS_SECRET must degrade, not error out, got: $OUT"

# --- 5. spend goes as a DELTA, and it is a NUMBER ----------------------------
# A string "1.5" would land in a REAL column as text and quietly poison every
# rollup that sums it; a total instead of a delta loses one of two concurrent
# stages' dollars.
: > "$T/req.txt"
probe ok 'job_update build-p-T1-1 stage=execute spend_delta=1.5' >/dev/null
grep -q '"spend_delta":1.5' "$T/req.txt" \
  && ok || bad "spend was not sent as a numeric delta: $(cat "$T/req.txt")"
: > "$T/req.txt"
probe ok 'job_update build-p-T1-1 spend_delta=nonsense' >/dev/null
grep -q 'nonsense' "$T/req.txt" \
  && bad "a non-numeric spend was forwarded to the DB: $(cat "$T/req.txt")" || ok

# --- 6. an outage is logged, once, and never on the build's critical path ----
: > "$T/logs/ALERTS.log"; rm -f "$T/flags/alerted-jobs-client-"*
probe down 'job_cap eval/x/claude; job_cap eval/x/claude; job_cap eval/x/claude' >/dev/null
[ "$(grep -c 'jobs-client' "$T/logs/ALERTS.log")" = 1 ] \
  && ok || bad "an outage alerted $(grep -c 'jobs-client' "$T/logs/ALERTS.log") times — one a day is the contract"
[ -s "$T/logs/jobs-client.log" ] \
  && ok || bad "an outage left no trace in logs/jobs-client.log"

# --- 7. the ledger contract (phase 2): a MISS is an answer, an OUTAGE is not -
# merge-sweep and migration-autopilot key their double-merge / double-apply
# guard on these rcs. rc=2 (worker reachable, row absent) may proceed; rc=1
# (outage) must fall back to the FILE ledger. And a 404 is the ledger's normal
# answer for new work, so a miss must never burn the daily outage alert.
OUT=$(probe ok 'job_ledger_get merge https://github.com/x/pull/1; echo " rc=$?"')
[ "$OUT" = "merged rc=0" ] && ok || bad "a ledger hit must print the status with rc=0, got: $OUT"
OUT=$(probe miss 'job_ledger_get merge https://github.com/x/pull/1; echo "rc=$?"')
[ "$OUT" = "rc=2" ] && ok || bad "a 404 miss must be rc=2 (a real answer), got: $OUT"
OUT=$(probe down 'job_ledger_get merge https://github.com/x/pull/1; echo "rc=$?"')
[ "$OUT" = "rc=1" ] && ok || bad "an outage on a ledger read must be rc=1, got: $OUT"
: > "$T/logs/ALERTS.log"; rm -f "$T/flags/alerted-jobs-client-"*
probe miss 'job_ledger_get merge X; job_ledger_get migration "p f.sql"' >/dev/null
[ "$(grep -c 'jobs-client' "$T/logs/ALERTS.log")" = 0 ] \
  && ok || bad "a ledger MISS burned the daily outage alert: $(cat "$T/logs/ALERTS.log")"
: > "$T/req.txt"
probe ok 'job_ledger_put merge https://github.com/x/pull/1 merged "tier-2 sweep"' >/dev/null
grep -q '"kind":"merge".*"status":"merged".*"actor":"test-box"' "$T/req.txt" \
  && ok || bad "ledger put body malformed: $(cat "$T/req.txt")"
OUT=$(probe down 'job_ledger_put merge X merged; echo "rc=$?"')
[ "$OUT" = "rc=1" ] && ok || bad "a ledger put under outage must be rc=1 (caller keeps the file append), got: $OUT"

# --- 8. heartbeats (phase 3): the beater dies with the job it describes -------
# THE PROPERTY THAT MATTERS. A beat loop that outlives a SIGKILLed parent would
# keep a dead job's row fresh forever — a watchdog lied to by the very failure it
# exists to catch. The loop watches the pid that started it, so killing that pid
# stops the beats within one interval.
: > "$T/req.txt"
( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
         JOBS_URL=https://jobs.invalid JOBS_BOX=test-box REQ_SINK="$T/req.txt" JOBS_BEAT_SECS=1
  # shellcheck source=/dev/null
  . "$T/bin/jobs-client.sh"
  job_heartbeat job-1 start >/dev/null
  PARENT=$(bash -c 'export PATH="'"$T"'/fakebin:$PATH" HARNESS="'"$T"'" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid REQ_SINK="'"$T"'/req.txt" JOBS_BEAT_SECS=1
     . "'"$T"'/bin/jobs-client.sh"; job_beat_start job-1 >/dev/null; echo $$; sleep 30' &
    echo $!)
  sleep 3   # determinism: ok two JOBS_BEAT_SECS=1 intervals of a real beater; elapsed time is the assertion
  kill -9 "$PARENT" 2>/dev/null
  BEFORE=$(grep -c '/heartbeat' "$T/req.txt")
  sleep 3   # determinism: ok the absence of beats after a kill can only be observed by waiting
  AFTER=$(grep -c '/heartbeat' "$T/req.txt")
  printf '%s %s\n' "$BEFORE" "$AFTER" > "$T/beats.txt" )
read -r BEFORE AFTER < "$T/beats.txt"
[ "${BEFORE:-0}" -ge 1 ] && ok || bad "no heartbeat was ever sent (before=$BEFORE)"
[ "${AFTER:-9}" -le $(( ${BEFORE:-0} + 1 )) ] \
  && ok || bad "the beater outlived its killed parent ($BEFORE -> $AFTER beats after kill -9) — a dead job would look alive forever"
OUT=$(probe down 'job_heartbeat job-1; echo "rc=$?"')
[ "$OUT" = "rc=1" ] && ok || bad "a heartbeat under outage must be rc=1 and silent, got: $OUT"

# --- 9. the box column is IDENTITY, not `hostname` ---------------------------
# Every Orgo box boots the image default "orgo-desktop", so before this the
# whole fleet wrote ONE name into the jobs ledger's box column — the console
# could not tell two boxes apart, one paused-box-<box> flag paused all of them,
# and a scope=box build slot was shared fleet-wide instead of per box. These
# drive the resolution for real and read back the name the worker was HANDED,
# because that is the only thing the box column can be checked against.
box_of() { # box_of <extra-env...> -> the actor/box the client sent
  : > "$T/req.txt"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid CURL_MODE=ok REQ_SINK="$T/req.txt"
    unset JOBS_BOX BOX_NAME
    # shellcheck source=/dev/null
    "$@" bash -c '. "'"$T"'/bin/jobs-client.sh"; job_heartbeat job-1 start' >/dev/null 2>&1 )
  sed -n 's/.*"box":"\([^"]*\)".*/\1/p' "$T/req.txt" | head -1
}
HOSTN=$(hostname)

# 9a. no identity file anywhere -> the OLD behaviour, byte for byte. An
# unprovisioned box and the hub must not break on a file that is not there yet.
rm -f "$T/state/box-name"
OUT=$(box_of env)
[ "$OUT" = "$HOSTN" ] && ok || bad "with no state/box-name the client must fall back to the hostname, got: '$OUT'"

# 9b. the identity file wins over the hostname — the actual fix.
printf 'box-project-3-2\n' > "$T/state/box-name"
OUT=$(box_of env)
[ "$OUT" = "box-project-3-2" ] && ok || bad "state/box-name did not reach the box column, got: '$OUT'"
[ "$OUT" != "orgo-desktop" ] && ok || bad "the box column is still the Orgo image default"

# 9c. $BOX_NAME beats the file (a fly builder / a box with no cron wiring).
OUT=$(box_of env BOX_NAME=pool-project-3)
[ "$OUT" = "pool-project-3" ] && ok || bad "BOX_NAME must win over state/box-name, got: '$OUT'"

# 9d. an explicit $JOBS_BOX still beats everything. Every other test in this
# repo sets it, and the fly lanes export it — this must stay the top override.
: > "$T/req.txt"
( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
         JOBS_URL=https://jobs.invalid CURL_MODE=ok REQ_SINK="$T/req.txt" \
         JOBS_BOX=test-box BOX_NAME=should-lose
  # shellcheck source=/dev/null
  . "$T/bin/jobs-client.sh"; job_heartbeat job-1 start ) >/dev/null 2>&1
OUT=$(sed -n 's/.*"box":"\([^"]*\)".*/\1/p' "$T/req.txt" | head -1)
[ "$OUT" = "test-box" ] && ok || bad "an explicit JOBS_BOX must stay the top override, got: '$OUT'"

# 9e. a junk identity file must not become a junk box name. The column is
# slugged into a flag name by the worker, so it may only carry the same
# characters bin/watchdog-ping.sh accepts.
printf 'bad name/../$(id)\n' > "$T/state/box-name"
OUT=$(box_of env)
case "$OUT" in
  *[!A-Za-z0-9._-]*) bad "an unsanitised box name reached the wire: '$OUT'" ;;
  "") bad "a junk identity file left the box column EMPTY — the worker would key a flag on nothing" ;;
  *) ok ;;
esac
rm -f "$T/state/box-name"

# 9f. sourcing the client on a box with no identity file must be SILENT. This
# file is sourced by every lane; a stray "No such file" on stderr from a failed
# `<` redirection would land in each of their logs.
ERR=$( ( export PATH="$T/fakebin:$PATH" HARNESS="$T" JOBS_URL=https://jobs.invalid
         unset JOBS_BOX BOX_NAME
         # shellcheck source=/dev/null
         . "$T/bin/jobs-client.sh" ) 2>&1 >/dev/null )
[ -z "$ERR" ] && ok || bad "sourcing with no state/box-name printed to stderr: $ERR"

# --- 10. bin/box-name.sh derives the name from the REPO, never a second list -
# The fleet's box names live in the committed crontabs (the watchdog-ping
# argument) and tests/watchdog-boxes-test.sh keeps that set identical to the
# watchdog worker's BOXES. Deriving from there is what stops this becoming a
# third hand-typed registry that can disagree with both.
mkdir -p "$T/cron" "$T/state"
printf '%s\n' '*/5 * * * * /root/harness/bin/watchdog-ping.sh box-project-4-1' > "$T/cron/project-4.cron"
printf 'project-4\n' > "$T/state/box-id"
rm -f "$T/state/box-name"
name_sh() { ( export HARNESS="$T" CHECKOUT="$T"; unset BOX_NAME; "$DIR/bin/box-name.sh" "$@" ); }
OUT=$(name_sh)
[ "$OUT" = "box-project-4-1" ] && ok || bad "box-name.sh did not derive the name from cron/<box-id>.cron, got: '$OUT'"

# --write persists it, which is what bin/jobs-client.sh then reads.
name_sh --write >/dev/null
[ "$(cat "$T/state/box-name" 2>/dev/null)" = "box-project-4-1" ] \
  && ok || bad "--write did not persist the name to state/box-name"

# A PARKED box keeps its cron file but drops the ping line (cron/project-10.cron
# is exactly this). That must fall through to the hostname, NOT write a blank
# name that the worker would slug into `paused-box-`.
rm -f "$T/state/box-name"
printf '%s\n' '*/5 * * * * /root/harness/bin/beat.sh' > "$T/cron/project-4.cron"
OUT=$(name_sh --write)
[ "$OUT" = "$HOSTN" ] && ok || bad "a cron file with no ping line must fall back to the hostname, got: '$OUT'"
[ ! -e "$T/state/box-name" ] \
  && ok || bad "--write froze the hostname into state/box-name ('$(cat "$T/state/box-name")') — the file exists to REPLACE the hostname, and a later sync that could resolve the real name would find it already populated"
rm -f "$T/state/box-id" "$T/cron/project-4.cron"

# --- large bodies ride a file (E2BIG guard, 2026-09-14) -----------------------
# A ~70KB body must reach the wire intact through --data-binary @file; a small
# one must still be the literal argv string every stub in tests/ inspects.
BIG=$(head -c 70000 /dev/zero | tr '\0' 'x')
: > "$T/req.txt"
probe ok "_jobs_req POST /api/echo '{\"big\":\"$BIG\"}' >/dev/null 2>&1; true" >/dev/null 2>&1
LAST=$(tail -1 "$T/req.txt" 2>/dev/null)
case "$LAST" in *'"big":"xxxx'*) ok ;; *) bad "a 70KB body did not arrive on the wire: $(printf '%s' "$LAST" | cut -c1-80)" ;; esac
[ "${#LAST}" -gt 70000 ] && ok || bad "the 70KB body arrived truncated (${#LAST} bytes)"
ls "${TMPDIR:-/tmp}"/jobs-body.* >/dev/null 2>&1 && bad "the body temp file was not cleaned up" || ok
: > "$T/req.txt"
probe ok "_jobs_req POST /api/echo '{\"small\":1}' >/dev/null 2>&1; true" >/dev/null 2>&1
case "$(tail -1 "$T/req.txt")" in *'{"small":1}'*) ok ;; *) bad "a small body must stay a literal argv string: $(tail -1 "$T/req.txt")" ;; esac

echo "jobs-client-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
