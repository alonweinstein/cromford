#!/bin/bash
# tests/fly-lane-db-test.sh — the fly lane's two ssh hops, driven.
#
# WHAT IS ACTUALLY BEING REMOVED. The hub needs ssh into every box for one
# reason: bin/fly-dispatch.sh lists, scp's and rm's each watcher's
# state/build-queue/<project>/ every two minutes, because a queue that lives on
# a box can only be read by reaching into the box. And a finished fly build
# hands its RESULT back the other way — an ssh push into the owning box's
# state/remote-results/ — which strands the whole close-out when it fails
# (TK-124 sat a day until a medic hand-delivered it).
#
# WHY DRIVEN AND NOT GREPPED. The load-bearing claims are about what does NOT
# happen: a stale box file is not pulled, and a result this box built is not
# staged a second time. Neither is visible in a grep, and both fail silently —
# the first as a duplicate build, the second as a client seeing us answer the
# same ticket twice. So ssh and scp are stubs that RECORD and also EMULATE the
# box's queue directory, and the assertions are about what they were asked to do.
#
# curl, ssh, scp, flock and timeout are all stubbed (no network, and macOS has
# neither flock nor timeout). The worker's own behaviour is proven by
# worker/jobs/test/index.test.js.
# Run from anywhere: tests/fly-lane-db-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/h/bin" "$T/h/logs" "$T/h/flags" "$T/h/locks" "$T/h/builds" \
         "$T/h/state/fly-pool/project-3" "$T/h/env" "$T/h/prompts" \
         "$T/h/catalog/agent-contracts" "$T/fakebin" "$T/boxq"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T/h" project-3 || exit 1  # BH-1510.2: lanes read models from model_routes
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/triage-contract.sh" "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
mkdir -p "$T/h/bin/lib/rt" && cp "$DIR"/bin/lib/rt/*.sh "$T/h/bin/lib/rt/"
# bin/fly-dispatch.sh resolves the owning box's address through the REGISTRY
# since 2026-09-11, so the scratch tree needs one. The live fleet.conf is
# copied rather than faked: the ssh-drain assertions below only reach the hop
# for a project that really has an address, and a fixture registry would let
# them pass by never getting there.
cp "$DIR/fleet.conf" "$T/h/fleet.conf"
cp "$DIR/catalog/agent-contracts/triage-system-append.txt" "$T/h/catalog/agent-contracts/"
: > "$T/h/env/global.env"
: > "$T/h/env/fly.env"                    # marks this tree as "the hub"
touch "$T/h/flags/builder-fly-project-3"
BOXQ="$T/boxq"

# THE PROJECT IS A REAL ONE, deliberately. bin/fly-dispatch.sh's ssh drain only
# runs for a project in its owner table, so a made-up fixture name would make
# every "the drain still runs" assertion pass vacuously by never reaching the
# hop it claims is there.

# Stubs that RECORD and EMULATE. $BOXQ is the watcher box's queue directory:
# `ssh ls` lists it, `ssh rm -f` removes from it, `scp` copies out of it. Every
# invocation is still appended to $SSH_SINK, so an assertion can be about a hop
# that happened, one that did not, or which file it named.
cat > "$T/fakebin/ssh" <<'STUB'
#!/bin/bash
echo "ssh $*" >> "$SSH_SINK"
CMD="${!#}"
case "$CMD" in
  "ls "*)    ls "${BOXQ:-/nonexistent}" 2>/dev/null ;;
  *"rm -f"*) rm -f "${BOXQ:-/nonexistent}/${CMD##*/}" ;;
esac
exit 0
STUB
cat > "$T/fakebin/scp" <<'STUB'
#!/bin/bash
echo "scp $*" >> "$SSH_SINK"
SRC=""; DST=""
for a in "$@"; do
  case "$a" in -*) ;; *:*) SRC="${a#*:}" ;; *) DST="$a" ;; esac
done
[ -n "$SRC" ] && [ -n "$DST" ] && cp "${BOXQ:-/nonexistent}/$(basename "$SRC")" "$DST" 2>/dev/null
STUB
printf '#!/bin/bash\nshift\nexec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/tailscale"

cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in --data-binary) BODY="$2"; shift 2 ;; -X) M="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
QROW='{"queue":[{"project":"project-3","ticket_key":"TK-9","ticket_id":"9","status":"queued","target":"fly","attempt":2,"claimed_by":null,"enqueued_at":"2026-09-10T01:00:00Z"}]}'
case "${CURL_MODE:-rows}" in
  down) exit 7 ;;
  norows)
    case "$URL" in
      */api/queue\?*) printf '{"queue":[]}\n200\n' ;;
      # TEST-CHANGE BH-4153: paused-*/automerge-disabled* are now harness_flags rows read DB-first; a 200 with no .flag row is UNREADABLE and fails closed (paused), so the flag GET must answer the worker's real no-row 404.
      */api/flags/*)   printf '{"error":"not found"}\n404\n' ;;
      *)              printf '{"ok":true}\n200\n' ;;
    esac ;;
  claimedrow)
    case "$URL" in
      */api/queue\?*key=*) printf '{"queue":[{"project":"project-3","ticket_key":"TK-42","status":"claimed","target":"fly","attempt":0}]}\n200\n' ;;
      */api/queue\?*)      printf '{"queue":[]}\n200\n' ;;
      # TEST-CHANGE BH-4153: same no-row 404 for the flag GET (see norows)
      */api/flags/*)        printf '{"error":"not found"}\n404\n' ;;
      *)                   printf '{"ok":true}\n200\n' ;;
    esac ;;
  norow)
    case "$URL" in
      */api/queue\?*) printf '{"queue":[]}\n200\n' ;;
      # TEST-CHANGE BH-4153: same no-row 404 for the flag GET (see norows)
      */api/flags/*)   printf '{"error":"not found"}\n404\n' ;;
      *)              printf '{"ok":true}\n200\n' ;;
    esac ;;
  refuse)
    case "$URL" in
      */api/queue/claim) printf '{"refused":true,"scope":"queue","reason":"taken"}\n409\n' ;;
      */api/queue\?*)    printf '%s\n200\n' "$QROW" ;;
      # TEST-CHANGE BH-4153: same no-row 404 for the flag GET (see norows)
      */api/flags/*)      printf '{"error":"not found"}\n404\n' ;;
      *)                 printf '{"ok":true}\n200\n' ;;
    esac ;;
  arts)
    case "$URL" in
      */api/artifacts\?*)
        # HONOURS ?since=, because the watermark is the thing under test. A stub
        # that returned the fixture regardless would pass on a worker that
        # ignored the parameter entirely — and the bug that hides is a rebuilt
        # box replaying fifty close-outs onto a client's tickets.
        SINCE=""
        case "$URL" in *since=*) SINCE="${URL##*since=}"; SINCE="${SINCE%%&*}" ;; esac
        printf '%s\n200\n' "$(jq -c --arg s "$SINCE" \
          '{artifacts: [ .artifacts[] | select($s == "" or .updated_at > $s) ]}' \
          "${ARTS_FIXTURE:-/dev/null}" 2>/dev/null || echo '{"artifacts":[]}')" ;;
      */api/queue\?*)     printf '{"queue":[]}\n200\n' ;;
      # TEST-CHANGE BH-4153: same no-row 404 for the flag GET (see norows)
      */api/flags/*)       printf '{"error":"not found"}\n404\n' ;;
      *)                  printf '{"ok":true}\n200\n' ;;
    esac ;;
  *)
    case "$URL" in
      */api/queue/claim) printf '{"queued":{"project":"project-3","ticket_key":"TK-9","ticket_id":"9","target":"fly","attempt":2,"status":"claimed"},"claimed":true}\n200\n' ;;
      */api/queue\?*)    printf '%s\n200\n' "$QROW" ;;
      # TEST-CHANGE BH-4153: same no-row 404 for the flag GET (see norows)
      */api/flags/*)      printf '{"error":"not found"}\n404\n' ;;
      *)                 printf '{"ok":true}\n200\n' ;;
    esac ;;
esac
STUB
chmod +x "$T/fakebin"/*

dispatch() { # dispatch <curl-mode>
  : > "$T/req.txt"; : > "$T/ssh.txt"; : > "$T/h/logs/fly-dispatch.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 \
           CURL_MODE="$1" REQ_SINK="$T/req.txt" SSH_SINK="$T/ssh.txt" BOXQ="$BOXQ" \
           FLEET_CONF="$T/h/fleet.conf"
    bash "$DIR/bin/fly-dispatch.sh" >/dev/null 2>&1 )
}
qfile="$T/h/state/build-queue/project-3/TK-9.json"

# THE REGISTRY MUST ANSWER BEFORE ANY OF THIS MEANS ANYTHING. Every ssh-drain
# assertion below depends on bin/fly-dispatch.sh resolving project-3 to an address;
# with the column missing it would resolve to nothing, skip the hop, and each
# "the drain still runs" check would fail for a reason that has nothing to do
# with the drain — while "no ssh happened" would pass VACUOUSLY. Assert the
# precondition so a lost column value is named as itself.
TNIP=$(FLEET_CONF="$T/h/fleet.conf" "$DIR/bin/fleet-conf.sh" --tailnet-ip project-3 2>/dev/null); TNRC=$?
[ "$TNRC" = 0 ] && [ -n "$TNIP" ] \
  && ok || bad "precondition: project-3 must resolve to a tailnet_ip (rc=$TNRC out='$TNIP') — without it every drain assertion below is vacuous"

# ══ 1. THE QUEUE COMES FROM THE ROWS ════════════════════════════════════════
dispatch rows
[ -f "$qfile" ] && ok || bad "a queued row must materialise the queue file the dispatcher reads"
[ "$(jq -r .key "$qfile" 2>/dev/null)" = TK-9 ] && ok || bad "the materialised file must carry the key: $(cat "$qfile" 2>/dev/null)"
[ "$(jq -r .ticket_id "$qfile" 2>/dev/null)" = 9 ] && ok || bad "the ticket_id must survive the trip — the launch needs it"
[ "$(jq -r .attempt "$qfile" 2>/dev/null)" = 2 ] && ok || bad "the attempt count must survive, or a re-queued build looks brand new"
grep -q 'POST https://jobs.invalid/api/queue/claim' "$T/req.txt" \
  && ok || bad "the hub must CLAIM the row it materialises — a row left queued is materialised again next tick and built twice"
grep -q '^scp ' "$T/ssh.txt" && bad "a row that answered must not ALSO be scp'd — that is a double pull" || ok

# THE DRAIN STILL RUNS. It used to be skipped entirely whenever any row was
# queued, and that was a double-build bug: bin/run-build.sh on a watcher still
# writes the box file and this drain is the ONLY thing that removes it. Skipping
# it on a busy project let those files pile up, and the first quiet tick pulled
# them all after their builds had been reaped — no hub file, nothing live in the
# pool, so the pool spawned a second machine per key.
grep -q '^ssh ' "$T/ssh.txt" \
  && ok || bad "THE FIX: the ssh drain must run even when rows answered, or box files accumulate and are pulled stale"
rm -f "$qfile"

# ══ 2. FAIL OPEN — no rows, or no worker, and the drain runs as today ═══════
dispatch norows
grep -q '^ssh ' "$T/ssh.txt" && ok || bad "with an EMPTY table the ssh drain must still run — the file queue is still the queue"
dispatch down
grep -q '^ssh ' "$T/ssh.txt" && ok || bad "with the worker DOWN the ssh drain must still run"
[ ! -f "$qfile" ] && ok || bad "the fallback path must not invent a queue file"

# ══ 3. THE GUARDS SURVIVE THE MOVE ══════════════════════════════════════════
# A key already live on a pool machine is not re-queued. This is the TK-70
# shape (2026-08-13): a re-queue mid-build spawned a second build after the reap.
printf '{"machine":"m1","key":"TK-9"}\n' > "$T/h/state/fly-pool/project-3/m1.json"
dispatch rows
[ ! -f "$qfile" ] && ok || bad "a key already live in the pool must not be re-materialised"
grep -q '/api/queue/claim' "$T/req.txt" && bad "a key live in the pool must not even be claimed" || ok
rm -f "$T/h/state/fly-pool/project-3/m1.json"

# A refused claim writes no file: the row belongs to someone else.
dispatch refuse
[ ! -f "$qfile" ] && ok || bad "a REFUSED claim must not leave a queue file behind — that is the double build"

# An entry already on disk is left alone and not re-claimed.
printf '{"key":"TK-9","ticket_id":"9","attempt":0}\n' > "$qfile"
dispatch rows
[ "$(jq -r .attempt "$qfile")" = 0 ] && ok || bad "an existing queue file must not be overwritten from a row"
grep -q '/api/queue/claim' "$T/req.txt" && bad "an existing queue file must not trigger a second claim" || ok
rm -f "$qfile"

# ══ 3b. THE DRAIN DROPS WHAT THE LEDGER SAYS IS NO LONGER QUEUED ═══════════
# The bug: a watcher's run-build.sh writes the box file, the hub takes custody
# through the ROW, the build runs and is reaped — and the box file is still
# sitting there. Pulled later it matches no hub file and nothing live in the
# pool, so the pool spawns a SECOND machine for a finished key.
printf '{"key":"TK-42","ticket_id":"42","attempt":0}\n' > "$BOXQ/TK-42.json"
dispatch claimedrow
[ ! -f "$T/h/state/build-queue/project-3/TK-42.json" ] \
  && ok || bad "a box file whose row is CLAIMED must not be pulled — its build is already in flight or done"
[ ! -f "$BOXQ/TK-42.json" ] && ok || bad "and it must be REMOVED from the box, or it is re-offered every tick forever"
grep -q '^scp ' "$T/ssh.txt" && bad "a stale box file must not be scp'd at all" || ok
grep -q 'is claimed, not queued' "$T/h/logs/fly-dispatch.log" \
  && ok || bad "the drop must say WHY, naming the ledger status: $(cat "$T/h/logs/fly-dispatch.log")"

# ...and a box file the DB has never heard of is REAL WORK: pulled exactly as
# today. This is the fail-open half, and it is what stops an older producer (or
# a tick that failed open) from losing its build.
printf '{"key":"TK-43","ticket_id":"43","attempt":0}\n' > "$BOXQ/TK-43.json"
dispatch norow
[ -f "$T/h/state/build-queue/project-3/TK-43.json" ] \
  && ok || bad "a box file with NO row must still be pulled — nothing in the DB claims to own it"
[ "$(jq -r .key "$T/h/state/build-queue/project-3/TK-43.json" 2>/dev/null)" = TK-43 ] \
  && ok || bad "the pulled file must be the box's own, not a fabrication"
[ ! -f "$BOXQ/TK-43.json" ] && ok || bad "a pulled file must be cleared from the box, as today"
rm -f "$T/h/state/build-queue/project-3/TK-43.json"

# An OUTAGE reaches the same conclusion by a different route and must never
# silently drop a build: nothing in the DB is answering, so the file is work.
printf '{"key":"TK-44","ticket_id":"44","attempt":0}\n' > "$BOXQ/TK-44.json"
dispatch down
[ -f "$T/h/state/build-queue/project-3/TK-44.json" ] \
  && ok || bad "with the worker down a box file must still be pulled — an outage must not eat a build"
rm -f "$T/h/state/build-queue/project-3/TK-44.json"
rm -f "$BOXQ"/*.json 2>/dev/null

# ══ 4. RESULTS COME BACK AS ROWS, PULLED — not pushed over scp ══════════════
printf 'SOP BODY\n' > "$T/h/prompts/project-3.md"
printf '#!/bin/bash\n[ "${2:-}" = "--pending" ] && exit 0\necho "RUN results-sweep"\n' > "$T/h/bin/triage-gate.sh"
printf '#!/bin/bash\nexit 2\n' > "$T/h/bin/gate-diff.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/decision-log.sh"
printf '#!/bin/bash\nprintf "tickets=0\\n" > "${5:-/dev/null}"\nexit 0\n' > "$T/h/bin/agent-call.sh"
chmod +x "$T/h/bin/triage-gate.sh" "$T/h/bin/gate-diff.sh" "$T/h/bin/beat.sh" \
         "$T/h/bin/decision-log.sh" "$T/h/bin/agent-call.sh" "$T/h/bin/triage-contract.sh"

cat > "$T/arts.json" <<'FIXTURE'
{"artifacts":[
 {"job_id":"build-project-3-TK-77-1","artifact_kind":"result","artifact_ref":"PR_CREATED https://github.com/o/r/pull/12","box":"pool-machine-1","ticket_id":"77","updated_at":"2026-09-10T02:00:00Z","detail":"{\"build_dir\":\"project-3-TK-77-2609100200\",\"key\":\"TK-77\",\"job_status\":\"done\"}"},
 {"job_id":"build-project-3-TK-88-1","artifact_kind":"result","artifact_ref":"PR_CREATED https://github.com/o/r/pull/13","box":"test-box","ticket_id":"88","updated_at":"2026-09-10T02:01:00Z","detail":"{\"build_dir\":\"project-3-TK-88-2609100201\",\"key\":\"TK-88\",\"job_status\":\"done\"}"}
]}
FIXTURE

triage() { # triage <curl-mode>
  : > "$T/req.txt"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=test-box JOBS_RETRIES=0 \
           JOBS_BEAT_SECS=3600 CURL_MODE="$1" REQ_SINK="$T/req.txt" \
           SSH_SINK="$T/ssh.txt" ARTS_FIXTURE="$T/arts.json" BOXQ="$BOXQ"
    bash "$DIR/bin/run-triage.sh" project-3 >/dev/null 2>&1 )
}
staged() { ls -d "$T/h/builds/project-3-$1-remote"* 2>/dev/null | head -1; }

triage arts
D=$(staged TK-77)
[ -n "$D" ] && ok || bad "a result row from ANOTHER box must be staged as a build dir for the sweep"
[ "$(head -1 "$D/RESULT" 2>/dev/null)" = "PR_CREATED https://github.com/o/r/pull/12" ] \
  && ok || bad "the staged RESULT must be the row's own line: $(head -1 "$D/RESULT" 2>/dev/null)"
grep -q 'TICKET_ID: 77' "$D/RESULT" && ok || bad "the close-out needs the ticket id"
grep -q 'built on pool-machine-1' "$D/RESULT" && ok || bad "the record must say where it was built"

# THE GUARD THAT MATTERS: a result THIS box produced is already sitting in
# builds/ waiting for the sweep. Staging it again would post a SECOND close-out
# on a client's ticket.
[ -z "$(staged TK-88)" ] && ok || bad "a result from THIS box must never be staged — that is a duplicate close-out to a client"

# Idempotent: the feed is a window, not a queue, so the same row arrives every
# tick and must be staged exactly once.
BEFORE=$(ls -d "$T/h/builds/project-3-TK-77-remote"* 2>/dev/null | wc -l | tr -d ' ')
triage arts
AFTER=$(ls -d "$T/h/builds/project-3-TK-77-remote"* 2>/dev/null | wc -l | tr -d ' ')
[ "$BEFORE" = "$AFTER" ] && ok || bad "a row must be staged once, not once per tick ($BEFORE -> $AFTER)"

# THE WATERMARK, which is the half a box-local marker cannot do. The feed is the
# newest 50 rows; the .handled markers that stop a re-stage live on THIS box, so
# a rebuilt or restored box has none and its first tick would re-stage up to
# fifty close-outs — fifty comments landing on a client's tickets at once.
[ -s "$T/h/state/remote-results/project-3/.since" ] \
  && ok || bad "the tick must persist a watermark after reading the feed"
grep -q 'since=2026-09-10T02%3A01%3A00Z\|since=2026-09-10T02:01:00Z' "$T/req.txt" \
  && ok || bad "the second tick must ASK for rows newer than the watermark: $(grep artifacts "$T/req.txt" | head -1)"
# The watermark advances past a row this box deliberately SKIPS (its own build),
# or that row is re-read on every tick for ever.
[ "$(cat "$T/h/state/remote-results/project-3/.since")" = "2026-09-10T02:01:00Z" ] \
  && ok || bad "the watermark must advance past skipped rows too, got $(cat "$T/h/state/remote-results/project-3/.since")"

# A rebuilt box — markers gone, watermark kept — replays NOTHING.
rm -rf "$T/h/state/remote-results/project-3/.handled" "$T/h/builds"/*
triage arts
[ -z "$(staged TK-77)" ] \
  && ok || bad "with the watermark past it, a rebuilt box must not replay an old close-out"

# Fail open: no worker, nothing staged, no error.
rm -rf "$T/h/builds"/* "$T/h/state/remote-results"
triage down
[ -z "$(staged TK-77)" ] && ok || bad "with the worker down nothing may be staged from the ledger"

# ══ 4b. THE RELAY JSON AND THE LEDGER MUST NOT BOTH STAGE ══════════════════
# The artifact row lands when the build ends; the scp'd relay json arrives a
# tick later. The ledger loop already skips a key the file loop staged; without
# the SAME test in the file loop the race runs the other way and one build gets
# two dirs — and a client's ticket gets two close-out comments.
rm -rf "$T/h/builds"/* "$T/h/state/remote-results"
triage arts
[ -n "$(staged TK-77)" ] && ok || bad "precondition: the ledger result must be staged first"
# TWO TICKS, TWO NAMES (BH-1284). A staged dir is named `<project>-<key>-remote
# <YYYYmmddHHMMSS>`, so two stagings inside ONE second resolve to one `mkdir -p`
# into the same directory — and for as long as this assertion has existed that is
# the only reason it passed: the duplicate it exists to catch landed on top of
# the original and the count stayed at 1. In production the two paths are a cron
# tick apart and the masking never applied, so the defect posted a second
# close-out comment on real client tickets (prod evidence in the PR). Giving the
# first staging a stamp of its own restores production's spacing without a sleep;
# the guards below glob on `-remote*` so they still find it. Same move
# tests/remote-result-relay-once.bh-1041-test.sh makes with `s_settle`.
mv "$(staged TK-77)" "$T/h/builds/project-3-TK-77-remote20260910020000"
mkdir -p "$T/h/state/remote-results/project-3" "$T/h/builds/pool-project-3-TK-77-orig"
printf '{"key":"TK-77","ticket_id":"77","result":"PR_CREATED https://github.com/o/r/pull/12","build_dir":"%s"}\n' \
  "$T/h/builds/pool-project-3-TK-77-orig" > "$T/h/state/remote-results/project-3/TK-77.json"
triage arts
N=$(ls -d "$T/h/builds/project-3-TK-77-remote"* 2>/dev/null | wc -l | tr -d ' ')
[ "$N" = 1 ] && ok || bad "a relay json for an already-staged key must not stage a SECOND dir (got $N) — that is two close-outs on one ticket"
[ ! -f "$T/h/state/remote-results/project-3/TK-77.json" ] \
  && ok || bad "the superseded relay json must be CONSUMED, or it is retried every tick for ever"
[ -f "$T/h/builds/pool-project-3-TK-77-orig/COMMENTED" ] \
  && ok || bad "the relay's own build dir must be marked COMMENTED so the custody checks see it as handled"

# ══ 4c. A FAILED STAGING IS RETRIED, NOT MARKED DONE ═══════════════════════
# The close-out only reaches the client because a build dir gets staged. If that
# write fails — a full disk is the ordinary way — marking the row `.handled` or
# advancing the watermark past it would drop the close-out silently and for
# good. So a staging failure must leave the row exactly as it found it.
rm -rf "$T/h/builds" "$T/h/state/remote-results"
# Root ignores mode bits, so chmod 500 cannot make mkdir fail; a regular FILE
# where the dir should be fails mkdir with ENOTDIR for every uid.
break_builds() {
  rm -rf "$T/h/builds"; : > "$T/h/builds"
  mkdir -p "$T/h/builds/probe" 2>/dev/null \
    && bad "failure injection is a no-op for uid $(id -u)" || ok
}
fix_builds() { rm -rf "$T/h/builds"; mkdir -p "$T/h/builds"; }
break_builds                     # writable directory removed: mkdir will fail
triage arts
fix_builds
[ -z "$(ls -A "$T/h/state/remote-results/project-3/.handled" 2>/dev/null)" ] \
  && ok || bad "a row whose staging FAILED must not be marked handled: $(ls -A "$T/h/state/remote-results/project-3/.handled" 2>/dev/null)"
[ ! -s "$T/h/state/remote-results/project-3/.since" ] \
  && ok || bad "the watermark must not advance past a row that failed to stage, got $(cat "$T/h/state/remote-results/project-3/.since" 2>/dev/null)"
grep -q 'left unstaged for the next tick' "$T/h/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "a staging failure must ALERT rather than pass in silence: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null)"

# ...and the retry works: with the directory writable again the SAME row stages.
triage arts
[ -n "$(staged TK-77)" ] \
  && ok || bad "the row must still be there to stage on the next tick — that is the point of not advancing"

# ══ 4d. A STUCK ROW PAGES ONCE A DAY, NOT ONCE A TICK ══════════════════════
# The freeze is what makes the row retry, so the SAME failure comes back every
# tick — six an hour, 144 a day of one identical sentence. That is how a channel
# stops being read. The per-row detail still lands in the project log every tick;
# only the paging is bounded.
rm -rf "$T/h/builds" "$T/h/state/remote-results" "$T/h/flags"/alerted-ledger-stage-* "$T/h/logs"/*
break_builds
triage arts
triage arts
triage arts
fix_builds
N=$(grep -c 'left unstaged for the next tick' "$T/h/logs/ALERTS.log" 2>/dev/null || echo 0)
[ "$N" = 1 ] \
  && ok || bad "three failing ticks must page ONCE, got $N alert line(s)"
NL=$(grep -c 'left unstaged for the next tick' "$T/h/logs/project-3.log" 2>/dev/null || echo 0)
[ "$NL" -ge 3 ] \
  && ok || bad "every failing tick must still be in the project log — the detail is not what is being suppressed (got $NL)"
ls "$T/h/flags"/alerted-ledger-stage-project-3-* >/dev/null 2>&1 \
  && ok || bad "the dedupe must be a per-day flag, like every other daily alert here"
# A NEW day pages again: the flag is dated, so a failure that outlives it is not
# silenced for ever.
rm -f "$T/h/flags"/alerted-ledger-stage-project-3-*
break_builds
triage arts
fix_builds
N=$(grep -c 'left unstaged for the next tick' "$T/h/logs/ALERTS.log" 2>/dev/null || echo 0)
[ "$N" = 2 ] && ok || bad "a new day (a fresh flag) must page again, got $N"
rm -rf "$T/h/builds"; mkdir -p "$T/h/builds"

# ══ 4e. A DIFFERENT BUILD OF THE SAME TICKET IS NOT THE SAME WORK ══════════
# project-3 TK-139, 2026-09-11. The two "already staged" guards asked "is there ANY
# builds/<project>-<KEY>-remote* dir" — a test on the TICKET. But a ticket is
# built more than once as a matter of course: a deferral, a fix round, a
# re-queue. TK-139 had an earlier attempt that day whose dir (BUILD_DEFERRED,
# COMMENTED weeks of ticks ago) still sat in builds/, so when the real build
# finished, its result row was marked `.handled` and skipped — for ever. The PR
# was open; the client's ticket never heard about it. The identity has to be the
# BUILD, and both halves of it are asserted here because they fail in opposite
# directions: too coarse loses a close-out, too fine posts two.
rm -rf "$T/h/builds" "$T/h/state/remote-results" "$T/h/state/project-3.result-rows"
mkdir -p "$T/h/builds/project-3-TK-77-remote20260911000000"
{ printf 'BUILD_DEFERRED conflict with #11\n'; printf 'JOB_ID: build-project-3-TK-77-0\n'
  printf 'BUILD_DIR: project-3-TK-77-2609110000\n'; } > "$T/h/builds/project-3-TK-77-remote20260911000000/RESULT"
touch "$T/h/builds/project-3-TK-77-remote20260911000000/COMMENTED"
triage arts
N=$(ls -d "$T/h/builds/project-3-TK-77-remote"* 2>/dev/null | wc -l | tr -d ' ')
[ "$N" = 2 ] \
  && ok || bad "a result row for a DIFFERENT job of an already-built ticket must still be staged (dirs=$N) — this is project-3 TK-139: an open PR whose ticket was never told"
grep -rqxF 'JOB_ID: build-project-3-TK-77-1' "$T/h/builds/project-3-TK-77-remote"*/RESULT 2>/dev/null \
  && ok || bad "the newly staged RESULT must carry the row's own job id, or nothing can tell the two builds apart next tick"

# ...and the same row, next tick, is still staged exactly once. The guard was
# made finer, not removed: a re-read of the SAME job must find itself.
triage arts
N2=$(ls -d "$T/h/builds/project-3-TK-77-remote"* 2>/dev/null | wc -l | tr -d ' ')
[ "$N2" = 2 ] && ok || bad "the same job must still be staged once, not once per tick (dirs=$N2) — two close-outs on one client ticket"

# The ledger guard must NOT fall back to the relay path's .handled/<key>.json
# markers: those are keyed on the ticket, and reading them here would put the
# ticket-keyed blocking straight back.
rm -rf "$T/h/builds" "$T/h/state/remote-results"
mkdir -p "$T/h/state/remote-results/project-3/.handled"
: > "$T/h/state/remote-results/project-3/.handled/TK-77.json"
triage arts
[ -n "$(staged TK-77)" ] \
  && ok || bad "a consumed relay marker for the KEY must not block a result row for a job that marker never described"

# ══ 4f. THE RELAY JSON IS KEYED ON ITS BUILD TOO ═══════════════════════════
# The reciprocal guard had the same flaw in the other direction: a relay json
# arriving for a NEW build was swallowed by any older dir for the ticket and
# consumed as a duplicate, so the result went nowhere at all. Both producers
# name the build dir (bin/fly-pool.sh's payload, bin/run-build.sh's row), so
# that name is the identity a staged RESULT has to carry.
rm -rf "$T/h/builds" "$T/h/state/remote-results"
mkdir -p "$T/h/builds/project-3-TK-90-remote20260911000000" "$T/h/state/remote-results/project-3" \
         "$T/h/builds/pool-project-3-TK-90-new"
{ printf 'PR_CREATED https://github.com/o/r/pull/1\n'; printf 'BUILD_DIR: pool-project-3-TK-90-old\n'; } \
  > "$T/h/builds/project-3-TK-90-remote20260911000000/RESULT"
printf '{"key":"TK-90","ticket_id":"90","result":"PR_CREATED https://github.com/o/r/pull/2","build_dir":"pool-project-3-TK-90-new"}\n' \
  > "$T/h/state/remote-results/project-3/TK-90.json"
triage down
N=$(ls -d "$T/h/builds/project-3-TK-90-remote"* 2>/dev/null | wc -l | tr -d ' ')
[ "$N" = 2 ] \
  && ok || bad "a relay json for a DIFFERENT build of the same ticket must be staged, not eaten as a duplicate (dirs=$N)"
grep -rqxF 'BUILD_DIR: pool-project-3-TK-90-new' "$T/h/builds/project-3-TK-90-remote"*/RESULT 2>/dev/null \
  && ok || bad "the staged RESULT must name the build it came from"
# ...and the SAME build's json, arriving again, is still consumed once.
printf '{"key":"TK-90","ticket_id":"90","result":"PR_CREATED https://github.com/o/r/pull/2","build_dir":"pool-project-3-TK-90-new"}\n' \
  > "$T/h/state/remote-results/project-3/TK-90.json"
triage down
N2=$(ls -d "$T/h/builds/project-3-TK-90-remote"* 2>/dev/null | wc -l | tr -d ' ')
[ "$N2" = 2 ] && ok || bad "the same build's json must not stage a second dir (dirs=$N2)"
[ ! -f "$T/h/state/remote-results/project-3/TK-90.json" ] \
  && ok || bad "the superseded json must still be consumed"
[ -f "$T/h/builds/pool-project-3-TK-90-new/COMMENTED" ] \
  && ok || bad "the relay's own build dir must be marked COMMENTED — the producers send a basename, so this only works if the reference is resolved against builds/"

# ...and the CROSS-PATH case, deterministically. 4b above asserts the same
# invariant but stages its first dir through a live tick, so both dirs would be
# named for the same second and a broken guard hides inside one `mkdir -p`.
# Here the already-staged dir has a fixed past name, so a second staging would
# be a second directory and impossible to miss. The two paths do NOT share a
# build-dir name — the hub keeps pool-<project>-<key>-<ts>, the machine's row
# carries <project>-<key>-<ts> — so what matches here is the MACHINE's build
# dir, which the ledger-staged dir records as its own `BUILT_AS:` line and the
# relay json carries as `machine_build_dir`.
# TEST-CHANGE (BH-1041): this case used to pin the RESULT LINE as the cross-path
# identity. The line is not one — the hub json truncates it at 200 bytes, the
# pool's pr-verify gate rewrites its first word and a builder's own close-out
# appends to it — so the fixture now carries the identity that survives all
# three. The assertions are unchanged.
rm -rf "$T/h/builds" "$T/h/state/remote-results"
mkdir -p "$T/h/builds/project-3-TK-91-remote20260911000000" "$T/h/state/remote-results/project-3"
{ printf 'PR_CREATED https://github.com/o/r/pull/3\n'; printf 'JOB_ID: build-project-3-TK-91-1\n'
  printf 'BUILD_DIR: project-3-TK-91-2609110001\n'
  printf 'BUILT_AS: project-3-TK-91-2609110001\n'; } > "$T/h/builds/project-3-TK-91-remote20260911000000/RESULT"
printf '{"key":"TK-91","ticket_id":"91","result":"PR_CREATED https://github.com/o/r/pull/3","build_dir":"pool-project-3-TK-91-1","machine_build_dir":"project-3-TK-91-2609110001"}\n' \
  > "$T/h/state/remote-results/project-3/TK-91.json"
triage down
N=$(ls -d "$T/h/builds/project-3-TK-91-remote"* 2>/dev/null | wc -l | tr -d ' ')
[ "$N" = 1 ] \
  && ok || bad "a relay json for a build the LEDGER already staged must not stage a second dir (dirs=$N) — two close-out comments on one client ticket"
[ ! -f "$T/h/state/remote-results/project-3/TK-91.json" ] \
  && ok || bad "the cross-path duplicate must be consumed, not retried every tick"

# ══ 4i. NEITHER SIDE CARRIES THE CROSS-PATH NAME (BH-1284) ═════════════════
# The shape the hub actually produced. `machine_build_dir` on the json and
# detail.build_dir on the row are both written by code newer than BH-1041, so
# every build from a builder or sender older than that carries NEITHER, the
# cross-path guard cannot fire on either side, and both paths stage — the same
# ticket, the same PR, seconds apart, and two close-out comments on a client.
# What is still decidable is which path staged what, because each stamps its own
# marker: a dir with `BUILD_DIR:` came from the relay, one with `JOB_ID:` from
# the ledger. §4b is this case with the relay json arriving second; here the
# LEDGER row arrives second, which is the order the hub's 2026-09-17 pairs
# landed in.
rm -rf "$T/h/builds" "$T/h/state/remote-results" "$T/h/state/project-3.result-rows"
cp "$T/arts.json" "$T/arts.keep.json"
cat > "$T/arts.json" <<'FIXTURE'
{"artifacts":[
 {"job_id":"build-project-3-TK-92-1","artifact_kind":"result","artifact_ref":"PR_CREATED https://github.com/o/r/pull/20","box":"pool-machine-1","ticket_id":"92","updated_at":"2026-09-10T02:00:00Z","detail":"{\"key\":\"TK-92\",\"job_status\":\"done\"}"}
]}
FIXTURE
mkdir -p "$T/h/builds/project-3-TK-92-remote20260911000000"
{ printf 'PR_CREATED https://github.com/o/r/pull/20\n'
  printf 'BUILD_DIR: pool-project-3-TK-92-202609110000\n'; } \
  > "$T/h/builds/project-3-TK-92-remote20260911000000/RESULT"
triage arts
N=$(ls -d "$T/h/builds/project-3-TK-92-remote"* 2>/dev/null | wc -l | tr -d ' ')
[ "$N" = 1 ] \
  && ok || bad "a ledger row with no cross-path name, for a ticket the RELAY already staged, must not stage a second dir (dirs=$N) — that is the hub's 2026-09-17 double close-out"
grep -q 'ledger result TK-92 .* no cross-path identity' "$T/h/logs/project-3.log" 2>/dev/null \
  && ok || bad "a result consumed without proof it is a duplicate must say so in the project log, or a genuinely stranded close-out is invisible"
# ...and the ledger row is still staged when the ledger is the path that staged
# the ticket before: those are two different jobs, which is project-3 TK-139.
rm -rf "$T/h/builds"/* "$T/h/state/remote-results"
mkdir -p "$T/h/builds/project-3-TK-92-remote20260911000000"
{ printf 'BUILD_DEFERRED conflict with #11\n'
  printf 'JOB_ID: build-project-3-TK-92-0\n'; } > "$T/h/builds/project-3-TK-92-remote20260911000000/RESULT"
triage arts
N=$(ls -d "$T/h/builds/project-3-TK-92-remote"* 2>/dev/null | wc -l | tr -d ' ')
[ "$N" = 2 ] \
  && ok || bad "a DIFFERENT job of a ticket the ledger built before must still be staged (dirs=$N) — this is project-3 TK-139, an open PR whose ticket was never told"
mv -f "$T/arts.keep.json" "$T/arts.json"

# ══ 4j. TWO STAGINGS IN ONE SECOND ARE TWO DIRECTORIES ═════════════════════
# The staged dir is named with a second-resolution UTC stamp, so two stagings
# that share a second used to resolve to one `mkdir -p` into the SAME directory
# and the second RESULT overwrote the first. Two different builds, one close-out
# — and it is also what hid §4b's duplicate for as long as that assertion has
# existed. The timestamp stays (a staged dir is this box's record of when work
# arrived); the collision does not.
rm -rf "$T/h/builds" "$T/h/state/remote-results"
mkdir -p "$T/h/state/remote-results/project-3" "$T/h/builds/pool-project-3-TK-93-a" \
         "$T/h/builds/pool-project-3-TK-93-b"
printf '{"key":"TK-93","ticket_id":"93","result":"PR_CREATED https://github.com/o/r/pull/30","build_dir":"pool-project-3-TK-93-a","machine_build_dir":"project-3-TK-93-a"}\n' \
  > "$T/h/state/remote-results/project-3/TK-93.json"
printf '{"key":"TK-93","ticket_id":"93","result":"PR_CREATED https://github.com/o/r/pull/31","build_dir":"pool-project-3-TK-93-b","machine_build_dir":"project-3-TK-93-b"}\n' \
  > "$T/h/state/remote-results/project-3/TK-93-b.json"
triage down
N=$(ls -d "$T/h/builds/project-3-TK-93-remote"* 2>/dev/null | wc -l | tr -d ' ')
[ "$N" = 2 ] \
  && ok || bad "two different builds staged in the same second must be two directories (dirs=$N) — one of the two close-outs was overwritten"
grep -rqxF 'BUILD_DIR: pool-project-3-TK-93-a' "$T/h/builds/project-3-TK-93-remote"*/RESULT 2>/dev/null \
  && ok || bad "the first build's staged RESULT must survive the second staging"
grep -rqxF 'BUILD_DIR: pool-project-3-TK-93-b' "$T/h/builds/project-3-TK-93-remote"*/RESULT 2>/dev/null \
  && ok || bad "the second build's staged RESULT must be there too"

# ══ 4g. STAGING RUNS BEFORE THE COST GATE ══════════════════════════════════
# The whole staging block used to sit AFTER the gate's SKIP exit, so a finished
# build could only be brought onto the box on a tick the gate had already
# decided to pay for on other grounds. On project-3, 2026-09-11, the pool result
# landed at 01:40Z and the 01:16/01:26/01:36/01:46 ticks each exited
# `rc=skip :: gate queue-unchanged` without ever looking at it. Staging is
# deterministic and free; a COST gate has no business in front of it.
rm -rf "$T/h/builds" "$T/h/state/remote-results" "$T/h/logs"/*.log "$T/h/state/project-3.result-rows"
# last-run.txt too, or the "no agent call" assertion below reads a PREVIOUS
# tick's transcript and passes without the gate ever having been consulted.
rm -f "$T/h/logs/project-3.last-run.txt"
mkdir -p "$T/h/builds"
printf '#!/bin/bash\n[ "${2:-}" = "--pending" ] && exit 0\necho "SKIP queue-unchanged"\n' > "$T/h/bin/triage-gate.sh"
chmod +x "$T/h/bin/triage-gate.sh"
triage arts
[ -n "$(staged TK-77)" ] \
  && ok || bad "a result row must be staged on a SKIP tick — this is the project-3 TK-139 stall: four ticks skipped while an open PR waited for its close-out"
grep -q 'rc=skip' "$T/h/logs/project-3.log" 2>/dev/null \
  && ok || bad "the tick must still SKIP the paid session — staging first must not turn a quiet tick into a spending one"
grep -q 'tickets=0' "$T/h/logs/project-3.last-run.txt" 2>/dev/null \
  && bad "a SKIP tick must not have called the agent" || ok

# ══ 4h. A RESULT ROW IS SOMETHING THE GATE CAN SEE ═════════════════════════
# Why 4g alone is not enough. The gate's queue brake hashes FILES — the queue
# dir, READY-QUEUE.log, the build dirs — and holds a 45-minute skip window over
# them. Under the old scp push a finished build changed one of those files by
# accident. As a ROW it changes none of them, so the window never breaks and the
# close-out waits for the clock. The newest row's timestamp is published as a
# file precisely so the gate has a row-shaped thing to notice.
#
# Driven against the REAL gate, not the stub: the claim is about what
# bin/triage-gate.sh hashes, and a grep for a filename would pass on a gate that
# read the file and ignored it.
realgate() { ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h"; bash "$DIR/bin/triage-gate.sh" project-3 2>/dev/null ); }
rm -rf "$T/h/builds" "$T/h/state/remote-results" "$T/h/state/project-3.queuefp" \
       "$T/h/state/project-3.result-rows"
mkdir -p "$T/h/builds"
printf 'TK-139 queued :: waiting on PR #21\n' > "$T/h/logs/READY-QUEUE.log"
G1=$(realgate); G2=$(realgate)
[ "${G1%% *}" = RUN ] && ok || bad "precondition: a fresh queue fingerprint must RUN, got $G1"
[ "${G2%% *}" = SKIP ] && ok || bad "precondition: an unchanged queue must hold the skip window, got $G2"
printf '2026-09-11T01:40:00Z\n' > "$T/h/state/project-3.result-rows"
G3=$(realgate)
[ "${G3%% *}" = RUN ] \
  && ok || bad "a NEW result row must break the queue skip window (got $G3) — a row is new-world exactly like a new queue line, and project-3 TK-139 is what happens when it is not"
G4=$(realgate)
[ "${G4%% *}" = SKIP ] \
  && ok || bad "an UNCHANGED row must not re-open the gate every tick (got $G4) — that would be a paid session every 10 minutes for the life of the row"
# And the tick itself publishes it: the file is not a test fixture.
rm -rf "$T/h/builds"/* "$T/h/state/remote-results" "$T/h/state/project-3.result-rows"
triage arts
[ "$(cat "$T/h/state/project-3.result-rows" 2>/dev/null)" = "2026-09-10T02:01:00Z" ] \
  && ok || bad "the tick must publish the NEWEST result row it saw, including rows it skipped as its own — got '$(cat "$T/h/state/project-3.result-rows" 2>/dev/null)'"
rm -f "$T/h/logs/READY-QUEUE.log"
printf '#!/bin/bash\n[ "${2:-}" = "--pending" ] && exit 0\necho "RUN results-sweep"\n' > "$T/h/bin/triage-gate.sh"
chmod +x "$T/h/bin/triage-gate.sh"
rm -rf "$T/h/builds"; mkdir -p "$T/h/builds"

# ══ 5. NO SECRETS ═══════════════════════════════════════════════════════════
grep -rq test-secret "$T/h/logs" 2>/dev/null && bad "HARNESS_SECRET leaked into a log" || ok
grep -rq test-secret "$T/h/builds" 2>/dev/null && bad "HARNESS_SECRET leaked into a build record" || ok

echo "fly-lane-db-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
