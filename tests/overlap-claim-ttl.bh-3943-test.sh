#!/bin/bash
# tests/overlap-claim-ttl.bh-3943-test.sh — BH-3951 (slice 4 of BH-3943).
# A `claimed` jobs-ledger row from another harness whose build is dead used to
# keep its ticket out of every overlap schedule forever: bin/overlap-schedule.sh
# source 3 put it in INFLIGHT and the candidate loop skipped it. This pins
# bin/lib/claim-age.sh and the conservative LOCAL release in source 3:
# released only when the claim AND its heartbeat are older than
# OVERLAP_CLAIM_TTL_MIN, the claim is another box's, and a clean PR read says
# there is no open PR. Every unreadable answer keeps today's output.
#
# Runs the REAL bin/overlap-schedule.sh in a scratch $HARNESS. Stubbed edges
# only: bin/jobs-client.sh (queue_list + _jobs_req serving $T/queue.json),
# bin/lib/open-pr-precheck.sh (open_pr_for_key returns $T/pr.rc) and
# bin/lane-alert.sh (records argv). No network, a fixed clock (CLAIM_AGE_NOW).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/bin/lib/claim-age.sh"
SCHED="$DIR/bin/overlap-schedule.sh"

NOW=$(date -u -d '2026-10-03T12:00:00Z' +%s)
export CLAIM_AGE_NOW="$NOW"
T400='2026-10-03T05:20:00.123Z'   # 400 minutes before NOW
T5='2026-10-03T11:55:00Z'         # 5 minutes before NOW

# ---------- A1. claim_ages from fixture JSON ------------------------------
A1=$(
  # shellcheck source=bin/lib/claim-age.sh
  . "$LIB" || exit 9
  _jobs_req() { printf '%s\n' "$1 $2" >> "$T/a1.req"; cat "$T/a1.json"; }
  cat > "$T/a1.json" <<JSON
{"queue":[
 {"project":"proj","ticket_key":"AB-7","status":"claimed","claimed_by":"otherbox","claimed_at":"$T400","updated_at":"$T5"},
 {"project":"proj","ticket_key":"AB-8","status":"claimed","claimed_by":"b2","claimed_at":null,"updated_at":"$T5"},
 {"project":"proj","ticket_key":"AB-9","status":"claimed","claimed_by":"b3","claimed_at":"2026-10-03T11:00:00Z","updated_at":"2026-10-03T11:00:00Z"},
 {"project":"proj","ticket_key":"AB-7","status":"claimed","claimed_by":"dupe","claimed_at":"$T5","updated_at":"$T5"}
]}
JSON
  claim_ages proj; echo "rc=$?"
  echo '{}' > "$T/a1.json"
  claim_ages proj; echo "rc_empty=$?"
  _jobs_req() { return 1; }
  claim_ages proj; echo "rc_fail=$?"
  claim_age_min "$T400"; echo "rc_min=$?"
  claim_age_min 'not-a-date'; echo "rc_bad=$?"
  claim_age_min '2026-10-03T13:00:00Z'; echo "rc_future=$?"
)
TAB=$'\t'
grep -qxF "AB-7${TAB}otherbox${TAB}${T400}${TAB}${T5}${TAB}400" <<<"$A1" && ok \
  || bad "A1: AB-7 row must be five columns with age 400 (got: $A1)"
grep -qxF "AB-8${TAB}b2${TAB}-${TAB}${T5}${TAB}-" <<<"$A1" && ok \
  || bad "A1: a missing claimed_at must give age - (got: $A1)"
grep -qxF "AB-9${TAB}b3${TAB}2026-10-03T11:00:00Z${TAB}2026-10-03T11:00:00Z${TAB}60" <<<"$A1" && ok \
  || bad "A1: AB-9 must be 60 minutes old (got: $A1)"
[ "$(grep -c '^AB-7' <<<"$A1")" = 1 ] && ok || bad "A1: a duplicated key must print once, first row wins (got: $A1)"
grep -qxF 'rc=0' <<<"$A1" && ok || bad "A1: an answered read must be rc 0 (got: $A1)"
grep -qxF 'rc_empty=2' <<<"$A1" && ok || bad "A1: a {} body must be rc 2 (got: $A1)"
grep -qxF 'rc_fail=2' <<<"$A1" && ok || bad "A1: a failing _jobs_req must be rc 2 (got: $A1)"
[ "$(grep -c "${TAB}" <<<"$A1")" = 3 ] && ok || bad "A1: rc 2 reads must print no rows (got: $A1)"
grep -qxF 'GET /api/queue?project=proj&status=claimed' "$T/a1.req" && ok \
  || bad "A1: claim_ages must GET the claimed rows of the project (got: $(cat "$T/a1.req" 2>/dev/null))"
grep -qx '400' <<<"$A1" && grep -qxF 'rc_min=0' <<<"$A1" && ok || bad "A1: claim_age_min must print 400 (got: $A1)"
grep -qxF 'rc_bad=1' <<<"$A1" && ok || bad "A1: an unparseable stamp must be rc 1 (got: $A1)"
grep -qx '0' <<<"$A1" && grep -qxF 'rc_future=0' <<<"$A1" && ok || bad "A1: a future stamp must clamp to 0 (got: $A1)"
# no _jobs_req at all is unreadable too
A1b=$( . "$LIB" || exit 9; unset -f _jobs_req; claim_ages proj; echo "rc=$?" )
[ "$A1b" = 'rc=2' ] && ok || bad "A1: no _jobs_req must be rc 2 with no output (got: $A1b)"

# ---------- the fixture harness -------------------------------------------
H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$H/flags" "$H/logs" "$H/plans" "$H/builds" \
         "$H/locks" "$H/state/claims/proj" "$H/state/preplan-candidates"
cp "$DIR/bin/lib/preplan-lib.sh" "$DIR/bin/lib/dep-verify-lib.sh" \
   "$DIR/bin/lib/scheduler-conf.sh" "$DIR/bin/lib/lane-switch.sh" "$H/bin/lib/" 2>/dev/null
[ -f "$LIB" ] && cp "$LIB" "$H/bin/lib/claim-age.sh"
cp "$SCHED" "$H/bin/overlap-schedule.sh"
cp "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"
cat > "$H/fleet.conf" <<'CONF'
proj  example-org/proj   -  -  0 local -
CONF
export FLEET_CONF="$H/fleet.conf"
export JOBS_BOX=hubbox
unset OVERLAP_CLAIM_TTL_MIN

mkdir -p "$H/plans/proj-AB-1"; echo 'code/a.ts' > "$H/plans/proj-AB-1/planned-files.txt"
cat > "$H/state/preplan-candidates/proj.tsv" <<'TSV'
AB-1	1	ahead
AB-7	7	ahead
TSV

cat > "$T/jobs-client.full.sh" <<SH
#!/bin/bash
_jobs_req() { printf '%s\n' "\$1 \$2" >> "$T/req.log"; cat "$T/queue.json"; }
queue_list() {
  local resp; resp=\$(_jobs_req GET "/api/queue?project=\$1&status=\$2") || return \$?
  printf '%s' "\$resp" | jq -r '.queue[]? | [.project, .ticket_key, "-", .status, "t", 0, (.claimed_by // "-")] | @tsv'
}
SH
cp "$T/jobs-client.full.sh" "$H/bin/jobs-client.sh"
cat > "$H/bin/lib/open-pr-precheck.sh" <<SH
#!/bin/bash
open_pr_for_key() { printf '%s\n' "\$*" >> "$T/pr.calls"; local rc; rc=\$(cat "$T/pr.rc"); [ "\$rc" = 0 ] && echo '#5'; return "\$rc"; }
SH
cat > "$H/bin/lane-alert.sh" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$T/alerts"
SH
chmod +x "$H/bin/"*.sh

queue() { # queue <claimed_by> <claimed_at> <updated_at>
  cat > "$T/queue.json" <<JSON
{"queue":[{"project":"proj","ticket_key":"AB-7","status":"claimed","claimed_by":"$1","claimed_at":"$2","updated_at":"$3"}]}
JSON
}
fresh() { rm -f "$T/alerts" "$T/pr.calls" "$T/req.log"; echo 1 > "$T/pr.rc"; }
run2() { HARNESS="$H" "$H/bin/overlap-schedule.sh" "$@" 2>"$T/err.txt"; }
alerts() { [ -f "$T/alerts" ] && wc -l < "$T/alerts" | tr -d ' ' || echo 0; }
MARK="$H/state/overlap-released/proj/AB-7.20261003T052000123Z"

# ---------- R1. a dead foreign claim is released --------------------------
fresh; queue otherbox "$T400" "$T400"
LOCKS_BEFORE=$(ls -A "$H/locks")
OUT=$(run2 proj)
grep -qxF 'OVERLAP_RELEASED AB-7 claim by otherbox 400m, no PR, no heartbeat' "$T/err.txt" && ok \
  || bad "R1: stderr must carry the OVERLAP_RELEASED line (got: $(cat "$T/err.txt"))"
grep -qF 'OVERLAP_UNJUDGED AB-7' "$T/err.txt" && bad "R1: a released key must not be UNJUDGED (got: $(cat "$T/err.txt"))" || ok
grep -qE '^(WAVE [0-9]+|UNPLANNED):.* AB-7( |$)' <<<"$OUT" && ok \
  || bad "R1: a released key must be placed in the schedule (got: $OUT)"
[ "$(alerts)" = 1 ] && ok || bad "R1: exactly one alert (got: $(cat "$T/alerts" 2>/dev/null))"
grep -qF -- '--id overlap-released-proj-AB-7 --severity warn overlap-schedule' "$T/alerts" 2>/dev/null && ok \
  || bad "R1: the alert must carry its stable id (got: $(cat "$T/alerts" 2>/dev/null))"
[ -f "$MARK" ] && ok || bad "R1: the dedupe marker must exist ($(ls -R "$H/state/overlap-released" 2>&1))"
grep -qvE '^GET ' "$T/req.log" && bad "R1: the release must only read the ledger (got: $(cat "$T/req.log"))" || ok
grep -qxF 'example-org/proj AB-7' "$T/pr.calls" 2>/dev/null && ok \
  || bad "R1: the PR read must ask the project's repo for the key (got: $(cat "$T/pr.calls" 2>/dev/null))"
[ "$(ls -A "$H/locks")" = "$LOCKS_BEFORE" ] && ok || bad "R1: no lock may be taken (got: $(ls -A "$H/locks"))"

# ---------- R2. the second run releases again but does not alert again ----
rm -f "$T/pr.calls"
OUT=$(run2 proj)
grep -qxF 'OVERLAP_RELEASED AB-7 claim by otherbox 400m, no PR, no heartbeat' "$T/err.txt" && ok \
  || bad "R2: the second run must still release (got: $(cat "$T/err.txt"))"
[ "$(alerts)" = 1 ] && ok || bad "R2: a second run must not alert again (got: $(cat "$T/alerts" 2>/dev/null))"
grep -qE '^(WAVE [0-9]+|UNPLANNED):.* AB-7( |$)' <<<"$OUT" && ok || bad "R2: AB-7 still placed (got: $OUT)"

# ---------- N1. a recent heartbeat keeps the claim ------------------------
fresh; queue otherbox "$T400" "$T5"
OUT=$(run2 proj)
grep -qxF 'OVERLAP_UNJUDGED AB-7 — claimed on another box for proj (age 400m by otherbox), no plan file list here; it is not judged and never HELD' "$T/err.txt" && ok \
  || bad "N1: a live heartbeat keeps AB-7 UNJUDGED with the age suffix (got: $(cat "$T/err.txt"))"
grep -qw 'AB-7' <<<"$OUT" && bad "N1: a kept claim stays out of the schedule (got: $OUT)" || ok
[ "$(alerts)" = 0 ] && ok || bad "N1: no alert (got: $(cat "$T/alerts" 2>/dev/null))"

# ---------- N2. an open PR keeps the claim --------------------------------
fresh; echo 0 > "$T/pr.rc"; queue otherbox "$T400" "$T400"
OUT=$(run2 proj)
grep -qF 'OVERLAP_UNJUDGED AB-7 — claimed on another box for proj (age 400m by otherbox)' "$T/err.txt" && ok \
  || bad "N2: an open PR keeps AB-7 UNJUDGED (got: $(cat "$T/err.txt"))"
grep -qF 'OVERLAP_RELEASED' "$T/err.txt" && bad "N2: no release (got: $(cat "$T/err.txt"))" || ok
grep -qw 'AB-7' <<<"$OUT" && bad "N2: AB-7 stays out (got: $OUT)" || ok
[ "$(alerts)" = 0 ] && ok || bad "N2: no alert"

# ---------- N3. an unreadable PR read keeps the claim ---------------------
fresh; echo 2 > "$T/pr.rc"; queue otherbox "$T400" "$T400"
OUT=$(run2 proj)
grep -qF 'OVERLAP_UNJUDGED AB-7 — claimed on another box for proj (age 400m by otherbox)' "$T/err.txt" && ok \
  || bad "N3: an unreadable PR read keeps AB-7 UNJUDGED (got: $(cat "$T/err.txt"))"
grep -qw 'AB-7' <<<"$OUT" && bad "N3: AB-7 stays out (got: $OUT)" || ok
[ "$(alerts)" = 0 ] && ok || bad "N3: no alert"

# ---------- N4. this box's own claim is never released here ---------------
fresh; queue hubbox "$T400" "$T400"
OUT=$(run2 proj)
grep -qF 'OVERLAP_UNJUDGED AB-7 — claimed on another box for proj (age 400m by hubbox)' "$T/err.txt" && ok \
  || bad "N4: an own-box claim stays UNJUDGED (got: $(cat "$T/err.txt"))"
[ ! -s "$T/pr.calls" ] && ok || bad "N4: the PR read must not run for an own-box claim (got: $(cat "$T/pr.calls"))"
grep -qw 'AB-7' <<<"$OUT" && bad "N4: AB-7 stays out (got: $OUT)" || ok

# ---------- N4b. an unparseable heartbeat keeps the claim -----------------
fresh; queue otherbox "$T400" "garbage"
OUT=$(run2 proj)
grep -qF 'OVERLAP_UNJUDGED AB-7' "$T/err.txt" && ok || bad "N4b: no heartbeat proof keeps AB-7 (got: $(cat "$T/err.txt"))"
grep -qw 'AB-7' <<<"$OUT" && bad "N4b: AB-7 stays out (got: $OUT)" || ok

# ---------- N4c. a slug that does not resolve keeps the claim -------------
fresh; queue otherbox "$T400" "$T400"
echo 'other  example-org/other  -  -  0 local -' > "$T/none.conf"
OUT=$(FLEET_CONF="$T/none.conf" run2 proj)
grep -qF 'OVERLAP_UNJUDGED AB-7' "$T/err.txt" && ok || bad "N4c: an empty slug keeps AB-7 (got: $(cat "$T/err.txt"))"
[ ! -s "$T/pr.calls" ] && ok || bad "N4c: no PR read without a slug (got: $(cat "$T/pr.calls"))"
grep -qw 'AB-7' <<<"$OUT" && bad "N4c: AB-7 stays out (got: $OUT)" || ok

# ---------- N5. claim_ages unreadable: today's line, byte for byte --------
fresh; queue otherbox "$T400" "$T400"
cat > "$H/bin/jobs-client.sh" <<'SH'
#!/bin/bash
queue_list() { printf 'proj\tAB-7\t7\tclaimed\tbox\t0\totherbox\t-\t-\t-\n'; }
SH
OUT=$(run2 proj)
[ "$(cat "$T/err.txt")" = 'OVERLAP_UNJUDGED AB-7 — claimed on another box for proj, no plan file list here; it is not judged and never HELD' ] && ok \
  || bad "N5: with no age read the line is today's exactly (got: $(cat "$T/err.txt"))"
grep -qw 'AB-7' <<<"$OUT" && bad "N5: AB-7 stays out (got: $OUT)" || ok
[ ! -s "$T/pr.calls" ] && ok || bad "N5: no PR read without an age"
cp "$T/jobs-client.full.sh" "$H/bin/jobs-client.sh"

# ---------- K1. TTL 0 is off -----------------------------------------------
fresh; queue otherbox "$T400" "$T400"
OUT=$(OVERLAP_CLAIM_TTL_MIN=0 run2 proj)
grep -qF 'OVERLAP_UNJUDGED AB-7 — claimed on another box for proj (age 400m by otherbox)' "$T/err.txt" && ok \
  || bad "K1: TTL=0 keeps AB-7 (got: $(cat "$T/err.txt"))"
[ ! -s "$T/pr.calls" ] && ok || bad "K1: TTL=0 makes no PR read"
[ "$(alerts)" = 0 ] && ok || bad "K1: no alert"
grep -qw 'AB-7' <<<"$OUT" && bad "K1: AB-7 stays out (got: $OUT)" || ok

# ---------- K2. env/global.env fallback, then the env var -----------------
fresh; queue otherbox "$T400" "$T400"
echo 'OVERLAP_CLAIM_TTL_MIN=500' > "$H/env/global.env"
OUT=$(run2 proj)
grep -qF 'OVERLAP_UNJUDGED AB-7' "$T/err.txt" && ok || bad "K2: global.env TTL 500 keeps a 400m claim (got: $(cat "$T/err.txt"))"
grep -qw 'AB-7' <<<"$OUT" && bad "K2: AB-7 stays out at TTL 500 (got: $OUT)" || ok
OUT=$(OVERLAP_CLAIM_TTL_MIN=300 run2 proj)
grep -qF 'OVERLAP_RELEASED AB-7' "$T/err.txt" && ok || bad "K2: env TTL 300 releases a 400m claim (got: $(cat "$T/err.txt"))"
rm -f "$H/env/global.env"

# ---------- K3. --key mode ---------------------------------------------------
fresh; queue otherbox "$T400" "$T400"
OUT=$(run2 proj --key AB-7)
grep -qE '^AB-7 (UNPLANNED|WAVE)' <<<"$OUT" && ok || bad "K3: --key AB-7 gets a verdict once released (got: $OUT)"
grep -qF 'OVERLAP_RELEASED AB-7' "$T/err.txt" && ok || bad "K3: --key AB-7 releases (got: $(cat "$T/err.txt"))"
fresh
OUT=$(run2 proj --key AB-1)
[ ! -s "$T/pr.calls" ] && ok || bad "K3: --key AB-1 must not judge AB-7's release (got: $(cat "$T/pr.calls"))"
grep -qF 'OVERLAP_UNJUDGED AB-7' "$T/err.txt" && ok || bad "K3: --key AB-1 leaves AB-7 UNJUDGED (got: $(cat "$T/err.txt"))"

# ---------- P1. the marker goes when the claim row goes --------------------
[ -f "$MARK" ] && ok || bad "P1: precondition, the marker exists"
echo '{"queue":[]}' > "$T/queue.json"
fresh
OUT=$(run2 proj)
[ ! -e "$MARK" ] && ok || bad "P1: a marker whose claim left the ledger must be pruned"
# ...and with no ledger answer nothing is pruned
queue otherbox "$T400" "$T400"; run2 proj >/dev/null
[ -f "$MARK" ] && ok || bad "P1: precondition, the marker is back"
rm -f "$H/bin/jobs-client.sh"
run2 proj >/dev/null
[ -f "$MARK" ] && ok || bad "P1: with no ledger answer no marker is pruned"
cp "$T/jobs-client.full.sh" "$H/bin/jobs-client.sh"

echo "overlap-claim-ttl: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
