#!/bin/bash
# tests/staging-identity.bh-1301-test.sh — the staging dedup's fallback, the one
# that runs when neither side carries the cross-path identity (BH-1301).
#
# WHY. BH-1284 taught the two loops in bin/lib/rt/staging.sh to read each other's
# markers: a staged dir with `BUILD_DIR:` came from the relay, one with `JOB_ID:`
# came from the ledger, and a result with no `machine_build_dir` /
# `detail.build_dir` of its own is the OTHER path's copy of a build already
# staged. It asked the wrong question to decide that. The condition was "does
# this ticket have ANY staged dir, and does none of them carry MY marker", which
# is also true when no dir carries EITHER marker — and the hub makes exactly such
# dirs: bin/review-rescue.sh rewrote a rescued RESULT down to three lines and
# dropped every provenance line it had. So a ticket whose only history was a
# rescued dir consumed the next result it saw, marked it `.handled` and posted no
# close-out at all. That result is LOST: nothing retries a `.handled` json.
#
# The second half is the case nobody could decide: a ticket staged by BOTH paths
# before, and an identity-less result arriving now. It is either a genuinely new
# build or the other path's copy of one of them, and the markers cannot tell.
# Staging is the reversible outcome (a duplicate dir is visible on disk; a
# consumed result is not), so it stages — and now says so, every time, in the
# project log, and pages once a day under its own `relay-bypass` tag.
#
# This file drives the REAL rt_stage against synthetic histories on a scratch
# $HARNESS: the relay loop through real jsons in state/remote-results, the ledger
# loop through a stub job_artifact_feed that prints the rows the worker would.
#
# Run from anywhere: tests/staging-identity.bh-1301-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2' want '$3'"; fi; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; P=project-3
RR="$H/state/remote-results/$P"

reset() {
  scratch_rm "$H"; mkdir -p "$H/builds" "$H/logs" "$H/flags" "$H/state" "$RR"
  : > "$T/feed.tsv"; : > "$T/tick.log"
}

# hist <dir-name> <RESULT line>...  — a staged dir this box already has.
hist() { local d="$H/builds/$1"; shift; mkdir -p "$d"; printf '%s\n' "$@" > "$d/RESULT"; }

# json <file-name> <json>  — a relay result parked by the ingest/pool sender.
json() { printf '%s\n' "$2" > "$RR/$1"; }

# row <job> <ref> <box> <ticket> <ts> <detail-json>  — one ledger artifact row.
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$T/feed.tsv"; }

# One tick of the staging stage, exactly as bin/run-triage.sh runs it: the stage
# file is sourced and rt_stage is called, with nothing else of the driver.
tick() {
  ( export HARNESS="$H" PROJECT="$P" LOG="$H/logs/$P.log" ALERTS="$H/logs/ALERTS.log" \
           STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)" JOBS_BOX=box-hub
    if [ -s "$T/feed.tsv" ]; then
      job_artifact_feed() { cat "$T/feed.tsv"; }
    fi
    . "$DIR/bin/lib/rt/staging.sh" || exit 1
    rt_stage ) >>"$T/tick.log" 2>&1
}

dirs()  { ls -d "$H/builds/$P-$1-remote"* 2>/dev/null | wc -l | tr -d ' '; }
# `grep -c` prints 0 and EXITS 1 when it matches nothing, so a `|| echo 0` here
# would print the count twice on the very case these helpers exist to count.
plog()  { local n; n=$(grep -c -- "$1" "$H/logs/$P.log" 2>/dev/null); echo "${n:-0}"; }
alog()  { local n; n=$(grep -c -- "$1" "$H/logs/ALERTS.log" 2>/dev/null); echo "${n:-0}"; }
# The dir that is NOT the fixture history — by name, not by mtime: the two are
# made in the same second and `ls -t` cannot order them.
other() { ls -d "$H/builds/$P-$1-remote"* 2>/dev/null | grep -v "/$2\$" | head -1; }

RESCUED_RESULT=(
  'PR_CREATED https://github.com/o/r/pull/1'
  'TIER: 1'
  'RESCUED: review re-run 2026-09-17T22:10:00Z after died-mid-review orphan'
)

# ══ E1. MARKER-LESS HISTORY + AN IDENTITY-LESS JSON MUST STAGE ══════════════
# The reproduction. The only dir for TK-1 is a rescued one, so it carries neither
# `BUILD_DIR:` nor `JOB_ID:` — nothing on disk says the ledger ever staged this
# ticket. Consuming the json here throws the close-out away.
reset
hist "$P-TK-1-remote20260911000000" "${RESCUED_RESULT[@]}"
json TK-1.json '{"key":"TK-1","ticket_id":"1","result":"PR_CREATED https://github.com/o/r/pull/2","build_dir":"pool-project-3-TK-1-b"}'
tick
eq "E1: an identity-less json with marker-less history is STAGED, not consumed" "$(dirs TK-1)" "2"
D=$(other TK-1 "$P-TK-1-remote20260911000000")
eq "E1: the staged dir carries the json's own result line" \
   "$(head -1 "$D/RESULT" 2>/dev/null)" "PR_CREATED https://github.com/o/r/pull/2"
[ -f "$RR/.handled/TK-1.json" ] && ok || bad "E1: the json must be archived after it is staged"
[ "$(plog 'no staged dir for this ticket carries either')" -ge 1 ] && ok \
  || bad "E1: the project log must say no dir carried a marker (log: $(cat "$H/logs/$P.log" 2>/dev/null))"
[ "$(plog 'already staged from the ledger')" = 0 ] && ok \
  || bad "E1: nothing may claim the ledger staged this ticket — no dir carries JOB_ID:"

# ══ E2. ...AND THE SAME HISTORY WITH AN IDENTITY-LESS LEDGER ROW ════════════
reset
hist "$P-TK-2-remote20260911000000" "${RESCUED_RESULT[@]}"
row build-project-3-TK-2-1 'PR_CREATED https://github.com/o/r/pull/9' pool-machine-1 2 \
    '2026-09-11T02:00:00Z' '{"key":"TK-2","job_status":"done"}'
tick
eq "E2: an identity-less ledger row with marker-less history is STAGED" "$(dirs TK-2)" "2"
[ -f "$RR/.handled/build-project-3-TK-2-1.job" ] && ok \
  || bad "E2: a staged row must be marked handled so the window does not restage it"
D=$(other TK-2 "$P-TK-2-remote20260911000000")
grep -qx 'JOB_ID: build-project-3-TK-2-1' "$D/RESULT" 2>/dev/null && ok \
  || bad "E2: the newly staged dir must carry the ledger's own marker ($(cat "$D/RESULT" 2>/dev/null))"
[ "$(plog 'no staged dir for this ticket carries either')" -ge 1 ] && ok \
  || bad "E2: the project log must say no dir carried a marker"
[ "$(plog 'already staged from the relay')" = 0 ] && ok \
  || bad "E2: nothing may claim the relay staged this ticket — no dir carries BUILD_DIR:"

# ══ E3. BOTH PATHS HAVE STAGED THIS TICKET: STAGE, AND SAY SO ═══════════════
# Undecidable: the identity-less json is either a third build or the relay copy
# of one of the two dirs already here. Staging is the reversible half, so it
# stages — and the bypass is logged every tick and paged once a day, because a
# silent bypass is how the second close-out happened in the first place.
reset
hist "$P-TK-3-remote20260911000000" 'PR_CREATED https://github.com/o/r/pull/3' 'JOB_ID: build-project-3-TK-3-1'
hist "$P-TK-3-remote20260911000100" 'PR_CREATED https://github.com/o/r/pull/3' 'BUILD_DIR: pool-project-3-TK-3-a'
json TK-3.json '{"key":"TK-3","ticket_id":"3","result":"PR_CREATED https://github.com/o/r/pull/4","build_dir":"pool-project-3-TK-3-b"}'
tick
eq "E3: an identity-less json is staged when BOTH paths have staged the ticket" "$(dirs TK-3)" "3"
eq "E3: the bypass is in the project log" "$(plog 'staged by BOTH paths')" "1"
eq "E3: the bypass pages once" "$(alog 'staged by BOTH paths')" "1"
grep -q 'second close-out (BH-1301)' "$H/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "E3: the alert must name what it is warning about (alerts: $(cat "$H/logs/ALERTS.log" 2>/dev/null))"
ls "$H/flags"/alerted-relay-bypass-$P-* >/dev/null 2>&1 && ok \
  || bad "E3: the bypass must page under its OWN flag tag, or it silences the consume alert"
# A second bypass logs again and pages no more: the per-day flag is the bound.
# A different relay build dir on purpose — re-parking the SAME json is caught by
# the loop's own `BUILD_DIR:` re-entry guard before any of this is reached, which
# is correct and would prove nothing about the bypass.
json TK-3-c.json '{"key":"TK-3","ticket_id":"3","result":"PR_CREATED https://github.com/o/r/pull/4","build_dir":"pool-project-3-TK-3-c"}'
tick
eq "E3: every bypass is in the project log" "$(plog 'staged by BOTH paths')" "2"
eq "E3: but it still pages only once a day" "$(alog 'staged by BOTH paths')" "1"

# ══ E4. THE SAME, FROM THE LEDGER SIDE ══════════════════════════════════════
reset
hist "$P-TK-4-remote20260911000000" 'PR_CREATED https://github.com/o/r/pull/5' 'JOB_ID: build-project-3-TK-4-0'
hist "$P-TK-4-remote20260911000100" 'PR_CREATED https://github.com/o/r/pull/5' 'BUILD_DIR: pool-project-3-TK-4-a'
row build-project-3-TK-4-1 'PR_CREATED https://github.com/o/r/pull/6' pool-machine-1 4 \
    '2026-09-11T02:00:00Z' '{"key":"TK-4","job_status":"done"}'
tick
eq "E4: an identity-less row is staged when BOTH paths have staged the ticket" "$(dirs TK-4)" "3"
eq "E4: the bypass is in the project log" "$(plog 'staged by BOTH paths')" "1"
eq "E4: the bypass pages once" "$(alog 'staged by BOTH paths')" "1"
[ -f "$RR/.handled/build-project-3-TK-4-1.job" ] && ok \
  || bad "E4: a row that WAS staged is still marked handled"

# ══ C. THE BH-1284 CONSUME STILL FIRES ON POSITIVE PROOF ════════════════════
# The narrowing must not remove the protection it narrows. One dir, carrying the
# OTHER path's marker and only that: the arriving result is that build's copy.
reset
hist "$P-TK-5-remote20260911000000" 'PR_CREATED https://github.com/o/r/pull/7' 'BUILD_DIR: pool-project-3-TK-5-a'
row build-project-3-TK-5-1 'PR_CREATED https://github.com/o/r/pull/7' pool-machine-1 5 \
    '2026-09-11T02:00:00Z' '{"key":"TK-5","job_status":"done"}'
tick
eq "C: a ledger row for a ticket only the RELAY staged is still consumed" "$(dirs TK-5)" "1"
[ -f "$RR/.handled/build-project-3-TK-5-1.job" ] && ok \
  || bad "C: the consumed row must be marked handled or it is re-read for ever"
[ "$(plog 'already staged from the relay')" -ge 1 ] && ok \
  || bad "C: a result consumed without proof of its own identity must still say so in the log"

reset
hist "$P-TK-6-remote20260911000000" 'PR_CREATED https://github.com/o/r/pull/8' 'JOB_ID: build-project-3-TK-6-1'
json TK-6.json '{"key":"TK-6","ticket_id":"6","result":"PR_CREATED https://github.com/o/r/pull/8","build_dir":"pool-project-3-TK-6-a"}'
tick
eq "C: a relay json for a ticket only the LEDGER staged is still consumed" "$(dirs TK-6)" "1"
[ -f "$RR/.handled/TK-6.json" ] && ok || bad "C: the consumed json must be archived"
[ "$(plog 'already staged from the ledger')" -ge 1 ] && ok \
  || bad "C: the consume must still name the ticket in the project log"

# ...and TK-139: a dir carrying only the SAME path's marker is a different build
# of the same ticket, and the arriving result still stages.
reset
hist "$P-TK-7-remote20260911000000" 'BUILD_DEFERRED conflict with #11' 'JOB_ID: build-project-3-TK-7-0'
row build-project-3-TK-7-1 'PR_CREATED https://github.com/o/r/pull/10' pool-machine-1 7 \
    '2026-09-11T02:00:00Z' '{"key":"TK-7","job_status":"done"}'
tick
eq "C: a DIFFERENT job of a ticket the ledger built before still stages (TK-139)" "$(dirs TK-7)" "2"

# ══ I. THE CROSS-PATH IDENTITY STILL SHORT-CIRCUITS ALL OF IT ═══════════════
# What T1 buys: a rescued dir that KEPT its `BUILT_AS:` line is matched by exact
# identity, so the relay copy of that same build is consumed on proof rather than
# on inference — no marker reading, no bypass, no log line about markers.
reset
hist "$P-TK-8-remote20260911000000" "${RESCUED_RESULT[@]}" 'BUILT_AS: project-3-TK-8-2609172200' \
     'JOB_ID: build-project-3-TK-8-1' 'TICKET_ID: 8'
json TK-8.json '{"key":"TK-8","ticket_id":"8","result":"PR_CREATED https://github.com/o/r/pull/1","build_dir":"pool-project-3-TK-8-a","machine_build_dir":"project-3-TK-8-2609172200"}'
tick
eq "I: a json whose machine_build_dir matches a staged BUILT_AS is consumed" "$(dirs TK-8)" "1"
[ -f "$RR/.handled/TK-8.json" ] && ok || bad "I: the matched json must be archived"
[ "$(plog 'no staged dir for this ticket carries either')" = 0 ] && ok \
  || bad "I: an exact identity match must not reach the marker fallback at all"
[ "$(alog 'staged by BOTH paths')" = 0 ] && ok \
  || bad "I: an exact identity match must not page the bypass"

echo "staging-identity.bh-1301: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
