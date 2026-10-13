#!/bin/bash
# tests/sweep-wedge.pool-doctor-test.sh — the cromford triage wedge of
# 2026-09-23/24, driven through the real bin/lib/rt/staging.sh (via
# bin/run-triage.sh) and the real bin/triage-gate.sh.
#
# THE BUG. The pool's account-exhaustion loop parked ~250 `BUILD_DEFERRED`
# results in the ledger. The watcher box staged every one as a
# builds/<p>-<KEY>-remote<ts>/ dir, and the SOP's answer to BUILD_DEFERRED is
# "nothing", so no session ever COMMENTED-marked one. Each pool handoff also
# leaves a local `QUEUED_FLY <KEY>` stub, and once the real result arrives by
# the LEDGER (not as a RELAYED pool-* dir) nothing discharged the stub either.
# Two consumers read "RESULT without COMMENTED" as "close-out owed":
#   * bin/triage-gate.sh step 3 exited on it — RUN results-sweep, or SKIP
#     sweep-unchanged — so the daily safety net and the board diff never ran;
#   * bin/orphan-reconcile.sh skipped every such ticket as awaiting-closeout.
# 16 hours of no board-changed session and 21 tickets nobody re-offered.
#
# THE FIX, pinned here:
#   A. a ledger/relay BUILD_DEFERRED is staged DEFERRED + COMMENTED — it owes
#      the board nothing, exactly like the pool's own deferral dir;
#   B. staging any result for KEY discharges the older QUEUED_FLY stubs of KEY
#      (never another key's, never a newer stub, never the result itself);
#   C. the sweep brake holds the SWEEP, not the board: an unchanged sweep set
#      falls through to the daily net and the board diff.
# Run from anywhere: tests/sweep-wedge.pool-doctor-test.sh (exit 0 = pass)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "ledger-blocked-artifact.bh-531-test: SKIPPED — jq is not installed"; exit 0; }

mkdir -p "$T/h/bin" "$T/h/logs" "$T/h/flags" "$T/h/locks" "$T/h/builds" \
         "$T/h/state/fly-pool/project-3" "$T/h/env" "$T/h/prompts" \
         "$T/h/catalog/agent-contracts" "$T/fakebin" "$T/tr"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T/h" project-3 || exit 1  # BH-1510.2: lanes read models from model_routes
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/triage-contract.sh" "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
mkdir -p "$T/h/bin/lib/rt" && cp "$DIR"/bin/lib/rt/*.sh "$T/h/bin/lib/rt/"
cp "$DIR/fleet.conf" "$T/h/fleet.conf"
cp "$DIR/catalog/agent-contracts/triage-system-append.txt" "$T/h/catalog/agent-contracts/"
: > "$T/h/env/global.env"
printf 'SOP BODY\n' > "$T/h/prompts/project-3.md"

printf '#!/bin/bash\n[ "${2:-}" = "--pending" ] && exit 0\necho "RUN results-sweep"\n' > "$T/h/bin/triage-gate.sh"
printf '#!/bin/bash\nexit 2\n' > "$T/h/bin/gate-diff.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/decision-log.sh"
printf '#!/bin/bash\nprintf "tickets=0\\n" > "${5:-/dev/null}"\nexit 0\n' > "$T/h/bin/agent-call.sh"
chmod +x "$T/h/bin/"*.sh
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/ssh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/scp"
printf '#!/bin/bash\nshift\nexec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/tailscale"

# The transport. Artifacts honour ?since= (the watermark is load-bearing in this
# loop); transcripts are served from $TRDIR fixture files, and a job with no
# fixture 404s exactly as the worker does.
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
[ -n "${REQ_SINK:-}" ] && printf '%s %s\n' "$M" "$URL" >> "$REQ_SINK"
case "${CURL_MODE:-arts}" in down) exit 7 ;; esac
case "$URL" in
  */api/artifacts\?*)
    SINCE=""
    case "$URL" in *since=*) SINCE="${URL##*since=}"; SINCE="${SINCE%%&*}" ;; esac
    printf '%s\n200\n' "$(jq -c --arg s "$SINCE" \
      '{artifacts: [ .artifacts[] | select($s == "" or .updated_at > $s) ]}' \
      "${ARTS_FIXTURE:-/dev/null}" 2>/dev/null || echo '{"artifacts":[]}')" ;;
  */transcripts)
    J="${URL##*/api/jobs/}"; J="${J%/transcripts}"
    if [ -f "${TRDIR:-/nonexistent}/$J.index" ]; then printf '%s\n200\n' "$(cat "$TRDIR/$J.index")"
    else printf '{"transcripts":[]}\n200\n'; fi ;;
  */transcript\?*)
    Q="${URL#*\?}"; U="${URL%%\?*}"; J="${U##*/api/jobs/}"; J="${J%/transcript}"
    P="${Q#*phase_id=}"; P="${P%%&*}"; A="${Q##*attempt=}"; A="${A%%&*}"
    if [ -f "${TRDIR:-/nonexistent}/$J.$P.$A" ]; then printf '%s\n200\n' "$(cat "$TRDIR/$J.$P.$A")"
    else printf '{"error":"no transcript for this attempt"}\n404\n'; fi ;;
  */api/queue\?*) printf '{"queue":[]}\n200\n' ;;
  # TEST-CHANGE BH-4153: paused-*/automerge-disabled* are now harness_flags rows read DB-first; a 200 with no .flag row is UNREADABLE and fails closed (paused), so the flag GET must answer the worker's real no-row 404.
  */api/flags/*)  printf '{"error":"not found"}\n404\n' ;;
  *)              printf '{"ok":true}\n200\n' ;;
esac
STUB
chmod +x "$T/fakebin"/*

row() { # row <key> <job-suffix> <ts> <ref>
  jq -nc --arg j "build-project-3-$1-$2" --arg r "$4" --arg k "$1" --arg t "$3" \
    --arg tid "${1#TK-}" \
    '{job_id:$j,artifact_kind:"result",artifact_ref:$r,box:"pool-machine-1",ticket_id:$tid,updated_at:$t,
      detail:({build_dir:("project-3-"+$k+"-m"+$j),key:$k,job_status:"parked"}|tostring)}'
}
{ printf '{"artifacts":['
  row TK-90 1 2026-09-10T02:00:01Z "BUILD_DEFERRED plan session ended RUNNER_EXHAUSTED class=auth(credential) seen=account-exhausted,auth runner=openrouter rc=1"
  printf ','; row TK-91 1 2026-09-10T02:00:02Z "PR_CREATED https://github.com/o/r/pull/91"
  printf ','; row TK-92 1 2026-09-10T02:00:03Z "PLAN_BLOCKED /root/harness/builds/project-3-TK-92-x/plan.md"
  printf ']}\n'; } > "$T/arts.json"

stub() { # stub <key> <suffix> [touch-stamp]
  local d="$T/h/builds/project-3-$1-$2"
  mkdir -p "$d"; printf 'QUEUED_FLY %s\n' "$1" > "$d/RESULT"
  jq -nc --arg k "$1" '{key:$k,project:"project-3"}' > "$d/job.json"
  [ -n "${3:-}" ] && touch -t "$3" "$d/RESULT"
  printf '%s' "$d"
}
S91=$(stub TK-91 202609100100 202609100100)
S92=$(stub TK-92 202609100100 202609100100)
S93=$(stub TK-93 202609100100 202609100100)     # no row for TK-93: someone else's handoff
S91N=$(stub TK-91 209901010000 209901010000)    # a handoff made AFTER this result
S90=$(stub TK-90 202609100100 202609100100)

( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=test-secret \
         JOBS_URL=https://jobs.invalid JOBS_BOX=test-box JOBS_RETRIES=0 \
         JOBS_BEAT_SECS=3600 CURL_MODE=arts ARTS_FIXTURE="$T/arts.json" TRDIR="$T/tr"
  bash "$DIR/bin/run-triage.sh" project-3 >/dev/null 2>&1 )
staged() { ls -d "$T/h/builds/project-3-$1-remote"* 2>/dev/null | head -1; }

# ══ A. a staged deferral owes nothing ══════════════════════════════════════
D=$(staged TK-90)
[ -n "$D" ] && ok || bad "precondition: the TK-90 deferral row must be staged"
[ -f "$D/COMMENTED" ] && ok || bad "THE BUG: a ledger-staged BUILD_DEFERRED has no COMMENTED — it wedges the gate and the reconcile forever"
[ -f "$D/DEFERRED" ] && ok || bad "a staged deferral must carry the pool's DEFERRED sentinel (pipeline-health reads it)"
D=$(staged TK-91)
[ -n "$D" ] && [ ! -f "$D/COMMENTED" ] && ok || bad "a PR_CREATED result still owes its close-out and must NOT be marked"
D=$(staged TK-92)
[ -n "$D" ] && [ ! -f "$D/COMMENTED" ] && ok || bad "a PLAN_BLOCKED result still owes its questions and must NOT be marked"

# ══ B. superseded stubs are discharged, nothing else is ════════════════════
[ -f "$S91/COMMENTED" ] && ok || bad "THE BUG: the TK-91 QUEUED_FLY stub stayed open after its result was staged"
[ -f "$S92/COMMENTED" ] && ok || bad "a blocked result also discharges its own older stub"
[ -f "$S90/COMMENTED" ] && ok || bad "a deferral result discharges its own older stub"
[ ! -f "$S93/COMMENTED" ] && ok || bad "a stub for a key with no staged result must be left alone"
[ ! -f "$S91N/COMMENTED" ] && ok || bad "a stub NEWER than the result is a new handoff and must be left alone"

# ══ C. the sweep brake does not starve the board ═══════════════════════════
G="$T/g"; mkdir -p "$G/bin" "$G/state" "$G/flags" "$G/logs" "$G/env" "$G/builds/p-K-1" "$T/gfake"
cat > "$G/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1 ${2:-}" in "p board_prefix") echo "-" ;; "p repo") echo "o/r" ;; *) exit 1 ;; esac
SH
chmod +x "$G/bin/fleet-conf.sh"
cat > "$T/gfake/gh" <<'SH'
#!/bin/bash
[ "${1:-}" = api ] || exit 1
shift; P=""
while [ $# -gt 0 ]; do case "$1" in -i) shift ;; -X|-f|-F|-H) shift 2 ;; -*) shift ;; *) P="$1"; shift; break ;; esac; done
case "$P" in
  repos/o/r/issues*) BODY=$(cat "$GI") ;;
  repos/o/r/pulls*)  BODY='[]' ;;
  *) exit 1 ;;
esac
printf 'HTTP/2.0 200\r\n\r\n%s\n' "$BODY"
SH
chmod +x "$T/gfake/gh"
echo '[{"number":7,"state":"open","title":"t","comments":1,"updated_at":"x"}]' > "$T/issues.json"
gate() { ( export PATH="$T/gfake:$PATH" HARNESS="$G" GI="$T/issues.json"; "$DIR/bin/triage-gate.sh" p "$@" 2>/dev/null ); }
echo "BUILD_DEFERRED all slots busy" > "$G/builds/p-K-1/RESULT"   # owed nothing, never marked (the old shape)

OUT=$(gate); [ "$OUT" = "RUN results-sweep" ] && ok || bad "precondition: a new un-commented set buys one sweep, got '$OUT'"
# Same set, inside 45m, daily net overdue: the old gate said SKIP sweep-unchanged.
OUT=$(gate); [ "$OUT" = "RUN daily-sweep" ] && ok || bad "THE BUG: an unchanged sweep set hid the overdue daily sweep, got '$OUT'"
date +%s > "$G/state/p.gate-meta"
OUT=$(gate); [ "$OUT" = "RUN no-gate-state" ] && ok || bad "with no stored fingerprint the tick must still run, got '$OUT'"
gate --seed >/dev/null
OUT=$(gate); [ "$OUT" = "SKIP sweep-unchanged" ] && ok || bad "nothing changed anywhere: the skip must read exactly as before, got '$OUT'"
echo '[{"number":7,"state":"open","title":"t","comments":2,"updated_at":"y"}]' > "$T/issues.json"
OUT=$(gate); [ "$OUT" = "RUN board-changed" ] && ok || bad "THE BUG: a changed board behind a held sweep must wake the tick, got '$OUT'"

grep -rq test-secret "$T/h/logs" 2>/dev/null && bad "HARNESS_SECRET leaked into a log" || ok
echo "sweep-wedge.pool-doctor-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
