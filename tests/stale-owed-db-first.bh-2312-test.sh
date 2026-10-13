#!/bin/bash
# tests/stale-owed-db-first.bh-2312-test.sh — THE ORPHAN SCAN READS THE LEDGER
# (BH-2350, slice 4 of BH-2312).
#
# bin/stale-owed-tickets.sh section 4 finds REVIEW_BLOCKED builds whose review
# died, but only by `find` over this box's builds/. A build recorded in the jobs
# ledger with no dir here was invisible. The ledger pass alerts on it when the
# job has no `verdict` artifact, once per build ever.
#
# Driven, not grepped: the REAL lane script over the REAL bin/jobs-client.sh,
# bin/lib/jobs/*.sh and bin/lib/builds-of-record.sh. The only stub on the ledger
# side is `curl` (the worker), shaped like tests/builds-of-record.bh-2312-test.sh.
#
#   S1 ledger-only orphan: one line across two runs, key stamped
#   S2 verdict artifact present -> none
#   S3 30 min old -> none; 10 days old (past the lookback) -> none
#   S4 feed at BOR_LIMIT -> "ledger read capped" in the lane log
#   S5 outage -> today's find line and .stale-flagged; worker up -> still one line
#   S6 PLAN_BLOCKED / staged -remote copy / verdict read outage -> none, no stamp
#   S7 read-only state file -> the line is written and written again next run
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/stale-owed-db-first.bh-2312-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$*"; }

H="$T/h"; FIX="$T/fix"
mkdir -p "$T/fakebin" "$H/bin/lib/jobs" "$H/builds" "$H/state" "$H/logs" "$H/flags" "$H/env" "$FIX"
cp "$DIR/bin/stale-owed-tickets.sh" "$H/bin/"
cp "$DIR/bin/alert-line.sh" "$H/bin/"  # TEST-CHANGE: BH-2365 — converted writers call bin/alert-line.sh
cp "$DIR/bin/jobs-client.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/builds-of-record.sh" "$DIR/bin/lib/verdict-parse.sh" "$H/bin/lib/"
# Sections 1-3: one board project with no token, so it is skipped before any
# board read. Only section 4 runs.
printf '#!/bin/sh\necho p\n' > "$H/bin/fleet-projects-or-alert.sh"
printf '#!/bin/sh\necho -\n' > "$H/bin/fleet-conf.sh"
printf '#!/bin/sh\nexit 1\n' > "$H/bin/internal-token-for.sh"
printf '#!/bin/sh\necho local\n' > "$H/bin/box-for.sh"
chmod +x "$H/bin/"*.sh

# The stub worker. kind=result / kind=pr_url answer from $FIX/result|pr_url;
# /api/jobs/<id>/artifacts from $FIX/art-<id> (absent = no artifacts).
# WORKER_DOWN=1 takes everything down, ARTS_DOWN=1 only the per-job read.
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"
printf 'GET %s\n' "$URL" >> "$REQ_SINK"
[ "${WORKER_DOWN:-0}" = 1 ] && exit 7
case "$URL" in
  */api/jobs/*/artifacts*)
    [ "${ARTS_DOWN:-0}" = 1 ] && exit 7
    J="${URL##*/api/jobs/}"; J="${J%%/*}"
    if [ -f "$FIX/art-$J" ]; then printf '%s\n200\n' "$(cat "$FIX/art-$J")"; else printf '{"artifacts":[]}\n200\n'; fi
    exit 0 ;;
  *kind=result\&*) F="$FIX/result" ;;
  *kind=pr_url\&*) F="$FIX/pr_url" ;;
  *) F="" ;;
esac
if [ -n "$F" ] && [ -f "$F" ]; then printf '%s\n200\n' "$(cat "$F")"; exit 0; fi
printf '{"artifacts":[]}\n200\n'
STUB
chmod +x "$T/fakebin/curl"

ago() { date -u -d "@$(( $(date +%s) - $1 ))" +%Y-%m-%dT%H:%M:%S.000Z; }
# res_row <job> <ref> <box> <updated_at> <build_dir> <key>
res_row() {
  jq -cn --arg j "$1" --arg r "$2" --arg b "$3" --arg u "$4" --arg d "$5" --arg k "$6" \
    '{job_id:$j, artifact_ref:$r, box:$b, ticket_id:$k, updated_at:$u,
      detail:({build_dir:$d, job_status:"done", key:$k} | tojson)}'
}
feed() { local f="$1"; shift; printf '%s\n' "$@" | jq -cs '{artifacts: .}' > "$FIX/$f"; }
verdict_for() { # verdict_for <job> — the job has a settled verdict artifact
  jq -cn '{artifacts:[{artifact_kind:"verdict", artifact_ref:"BLOCK", detail:"{\"settled\":true}"}]}' > "$FIX/art-$1"
}
reset() {
  chmod -R u+w "$H/state" 2>/dev/null
  rm -f "$FIX"/* "$T/req.txt" "$H/logs/"* "$H/state/"*
  scratch_rm "$H/builds"; mkdir -p "$H/builds"
}
run() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub FIX="$FIX" JOBS_RETRIES=0 \
           REQ_SINK="$T/req.txt" LANE_GATE_DISABLE=1 \
           WORKER_DOWN="${WORKER_DOWN:-0}" ARTS_DOWN="${ARTS_DOWN:-0}"
    [ -n "${BOR_LIMIT:-}" ] && export BOR_LIMIT
    unset JOB_ID STALE_ORPHAN_LOOKBACK_H
    bash "$H/bin/stale-owed-tickets.sh" ) >>"$T/out.txt" 2>&1
}
orphans() { [ -f "$H/logs/ALERTS.log" ] || { echo 0; return; }; grep -c 'ORPHANED BUILD' "$H/logs/ALERTS.log"; }
stamped() { jq -e --arg k "$1" 'has($k)' "$H/state/stale-owed-orphans.json" >/dev/null 2>&1; }

# ═════════════════════════════════════════════════════════════════════════════
# S1 — a ledger-only orphan alerts once, ever
# ═════════════════════════════════════════════════════════════════════════════
reset
feed result "$(res_row J1 'REVIEW_BLOCKED tier 3' w2 "$(ago 7200)" p-BH-1-20260925 BH-1)"
run
[ "$(orphans)" = 1 ] && ok || bad "S1: run 1 must write exactly one ORPHANED BUILD line, got $(orphans): $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
L=$(grep 'ORPHANED BUILD' "$H/logs/ALERTS.log" 2>/dev/null)
case "$L" in *"ORPHANED BUILD: p-BH-1-20260925 (p BH-1, box w2, job J1)"*"no verdict artifact"*"no local dir"*) ok ;;
  *) bad "S1: the line must name build_dir, key, box and job and say no verdict artifact / no local dir: '$L'" ;; esac
stamped "p:p-BH-1-20260925" && ok || bad "S1: key p:p-BH-1-20260925 not in state/stale-owed-orphans.json: $(cat "$H/state/stale-owed-orphans.json" 2>/dev/null)"
grep -q '/api/jobs/J1/artifacts' "$T/req.txt" 2>/dev/null && ok || bad "S1: the job's artifacts were never read"
run
[ "$(orphans)" = 1 ] && ok || bad "S1: run 2 must add nothing, got $(orphans) lines"

# ═════════════════════════════════════════════════════════════════════════════
# S2 — the job has a verdict artifact
# ═════════════════════════════════════════════════════════════════════════════
reset
feed result "$(res_row J1 'REVIEW_BLOCKED tier 3' w2 "$(ago 7200)" p-BH-1-20260925 BH-1)"
verdict_for J1
run
[ "$(orphans)" = 0 ] && ok || bad "S2: a job with a verdict artifact must not alert, got $(orphans)"
stamped "p:p-BH-1-20260925" && bad "S2: a judged build must not be stamped" || ok

# ═════════════════════════════════════════════════════════════════════════════
# S3 — too young, and past the lookback
# ═════════════════════════════════════════════════════════════════════════════
reset
feed result "$(res_row J1 'REVIEW_BLOCKED tier 3' w2 "$(ago 1800)" p-BH-1-a BH-1)" \
            "$(res_row J2 'REVIEW_BLOCKED tier 3' w2 "$(ago 864000)" p-BH-2-a BH-2)" \
            "$(res_row J3 'REVIEW_BLOCKED tier 3' w2 'not-a-date' p-BH-3-a BH-3)"
run
[ "$(orphans)" = 0 ] && ok || bad "S3: 30-min, 10-day and unparseable rows must not alert, got: $(grep 'ORPHANED' "$H/logs/ALERTS.log" 2>/dev/null)"
grep -q '/api/jobs/J' "$T/req.txt" 2>/dev/null && bad "S3: no verdict read for a row outside the window" || ok

# ═════════════════════════════════════════════════════════════════════════════
# S4 — a capped ledger read is logged as capped
# ═════════════════════════════════════════════════════════════════════════════
reset
feed result "$(res_row J1 'PR_CREATED x' w2 "$(ago 7200)" p-BH-1-a BH-1)" \
            "$(res_row J2 'PR_CREATED y' w2 "$(ago 7300)" p-BH-2-a BH-2)"
BOR_LIMIT=2 run
grep -q 'p: ledger read capped at 2 rows' "$H/logs/stale-owed.log" 2>/dev/null && ok \
  || bad "S4: 'ledger read capped' missing from stale-owed.log: $(cat "$H/logs/stale-owed.log" 2>/dev/null)"
reset
feed result "$(res_row J1 'PR_CREATED x' w2 "$(ago 7200)" p-BH-1-a BH-1)"
run
grep -q 'ledger read capped' "$H/logs/stale-owed.log" 2>/dev/null && bad "S4: an uncapped read must not log capped" || ok

# ═════════════════════════════════════════════════════════════════════════════
# S5 — outage parity with today's find, and no double alert when the worker is up
# ═════════════════════════════════════════════════════════════════════════════
local_orphan() {
  mkdir -p "$H/builds/p-BH-5-x"
  printf 'REVIEW_BLOCKED tier 3\n' > "$H/builds/p-BH-5-x/RESULT"
  printf 'the reviewer died here\n' > "$H/builds/p-BH-5-x/review.md"
  touch -d '2 hours ago' "$H/builds/p-BH-5-x/RESULT"
}
reset; local_orphan
feed result "$(res_row J5 'REVIEW_BLOCKED tier 3' w2 "$(ago 7200)" p-BH-5-x BH-5)"
WORKER_DOWN=1 run
L=$(grep 'ORPHANED BUILD' "$H/logs/ALERTS.log" 2>/dev/null)
[ "$(orphans)" = 1 ] && ok || bad "S5: outage must still give the find's one line, got $(orphans)"
case "$L" in *"[stale-sweep] ORPHANED BUILD: p-BH-5-x — RESULT=REVIEW_BLOCKED but review.md has no VERDICT (review died mid-run). Hub: re-run the review stage or close it out; nothing else will.") ok ;;
  *) bad "S5: the find's line changed form: '$L'" ;; esac
[ -f "$H/builds/p-BH-5-x/.stale-flagged" ] && ok || bad "S5: .stale-flagged not written"
grep -q 'p: ledger read failed' "$H/logs/stale-owed.log" 2>/dev/null && ok || bad "S5: outage not logged: $(cat "$H/logs/stale-owed.log" 2>/dev/null)"
[ -s "$H/state/stale-owed-orphans.json" ] && [ "$(jq -c . "$H/state/stale-owed-orphans.json")" != '{}' ] \
  && bad "S5: an outage must stamp nothing" || ok
reset; local_orphan
feed result "$(res_row J5 'REVIEW_BLOCKED tier 3' w2 "$(ago 7200)" p-BH-5-x BH-5)"
run
[ "$(orphans)" = 1 ] && ok || bad "S5: worker up with a local dir must still be one line, got $(orphans)"
grep -q '/api/jobs/J5/artifacts' "$T/req.txt" 2>/dev/null && bad "S5: a row with a local dir must not reach the verdict read" || ok

# ═════════════════════════════════════════════════════════════════════════════
# S6 — PLAN_BLOCKED, a staged -remote copy, a verdict-read outage
# ═════════════════════════════════════════════════════════════════════════════
reset
mkdir -p "$H/builds/p-BH-7-remote1758800000"
printf 'REVIEW_BLOCKED tier 3\nJOB_ID: J7\n' > "$H/builds/p-BH-7-remote1758800000/RESULT"
touch "$H/builds/p-BH-7-remote1758800000/COMMENTED"
feed result "$(res_row J6 'PLAN_BLOCKED ambiguous' w2 "$(ago 7200)" p-BH-6-a BH-6)" \
            "$(res_row J7 'REVIEW_BLOCKED tier 3' w2 "$(ago 7200)" p-BH-7-a BH-7)"
run
[ "$(orphans)" = 0 ] && ok || bad "S6: PLAN_BLOCKED and a staged job must not alert from the ledger pass, got: $(grep 'ORPHANED' "$H/logs/ALERTS.log" 2>/dev/null)"
reset
feed result "$(res_row J1 'REVIEW_BLOCKED tier 3' w2 "$(ago 7200)" p-BH-1-a BH-1)"
ARTS_DOWN=1 run
[ "$(orphans)" = 0 ] && ok || bad "S6: a verdict-read outage must not alert, got $(orphans)"
stamped "p:p-BH-1-a" && bad "S6: a verdict-read outage must not stamp" || ok

# ═════════════════════════════════════════════════════════════════════════════
# S7 — the stamp cannot be written: loud every run, never silent
# ═════════════════════════════════════════════════════════════════════════════
reset
feed result "$(res_row J1 'REVIEW_BLOCKED tier 3' w2 "$(ago 7200)" p-BH-1-a BH-1)"
echo '{}' > "$H/state/stale-owed-orphans.json"
chmod a-w "$H/state/stale-owed-orphans.json" "$H/state"
if [ -w "$H/state/stale-owed-orphans.json" ]; then
  # root ignores the mode bits: stand the store on a path that cannot be a file.
  chmod u+w "$H/state" "$H/state/stale-owed-orphans.json"; rm -f "$H/state/stale-owed-orphans.json"
  mkdir -p "$H/state/stale-owed-orphans.json.tmp/x"
fi
run
[ "$(orphans)" = 1 ] && ok || bad "S7: the ALERTS line must be written before the stamp, got $(orphans)"
run
[ "$(orphans)" = 2 ] && ok || bad "S7: a failed stamp must re-alert next run, got $(orphans)"
chmod -R u+w "$H/state"; scratch_rm "$H/state/stale-owed-orphans.json.tmp"

echo "stale-owed-db-first: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
