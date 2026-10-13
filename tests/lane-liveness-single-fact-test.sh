#!/bin/bash
# tests/lane-liveness-single-fact-test.sh — ONE answer to "is that lane alive".
#
# THE FAILURE THIS PINS (BH-1031, state→DB slice 6). A lane PROCESS dies on a
# box whose cron is ticking perfectly. Before this slice the fleet had three
# detectors and none of them could see it:
#
#   state/heartbeat/<lane>.<pid>.json — the box-local file. Legible ONLY on the
#     machine that wrote it, so it goes silent at exactly the moment the failure
#     is largest: the box itself is gone, and there is no file left to read.
#   bin/fleet-heartbeat.sh            — ssh'd every box every 15 minutes to stat
#     a log file. That answers "can the HUB REACH it", which is not the same
#     question — its own comments said so, out loud — and it is deleted here.
#   the `lanes` row                   — answered a third thing again: did the
#     CRON fire. A box whose crontab is healthy and whose merge-conductor died
#     reads perfectly alive.
#
# So the beats are written THROUGH to the lanes row, the worker computes stale
# from them on the rhythm the lane itself declared, and bin/heartbeat-reaper.sh
# reads that verdict back for every box at once.
#
# The four claims that decide whether this is machinery or decoration:
#   1. THE BEAT REACHES THE ROW — and carries the pid and the note, or the page
#      cannot name what to go look for.
#   2. IT IS DARK UNTIL THE FLAG IS ON, and the flag is a DB row cached as a
#      file, so turning it on is an edit and not a deploy.
#   3. THE LEDGER IS NEVER THE REASON A LANE DIES. A missing, hanging or broken
#      client must not fail a beat, slow a loop, or lose the file write.
#   4. THE ROW PAGES ONCE, for a lane no file on this box could speak for, and
#      again only to say it came back.
#
# Run from anywhere: tests/lane-liveness-single-fact-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-3223: scratch.sh blanks JOBS_URL; this suite's fake curl answers a worker URL.
export JOBS_URL=https://jobs.invalid
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
# BH-1247: catalog/lanes.json and cron/<box>.cron are GENERATED and not
# committed. rendered_registry / rendered_cron render this repo's own into $T.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
command -v jq >/dev/null 2>&1 || { echo "lane-liveness-single-fact-test: SKIPPED — jq is not installed"; exit 0; }
BASE="$T"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# A scratch $HARNESS with a curl that records every request and answers per
# path, the bin/jobs-client.sh fake the rest of this suite uses. CURL_MODE=down
# models an unreachable worker.
new_harness() {
  local H; H=$(mktemp -d "$BASE/h-XXXXXX")
  mkdir -p "$H/bin/lib" "$H/logs" "$H/state/heartbeat" "$H/flags" "$H/env" "$H/locks" "$H/fakebin"
  cp "$DIR/bin/jobs-client.sh" "$DIR/bin/heartbeat-reaper.sh" "$H/bin/"
  # The client is a SHIM over bin/lib/jobs/ since BH-1194 and refuses to
  # half-load, so a fixture that copies it copies the modules beside it too.
  mkdir -p "$H/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
  cp "$DIR"/bin/lib/heartbeat.sh "$DIR"/bin/lib/alert-state.sh "$DIR"/bin/lib/env-path.sh "$H/bin/lib/"
  printf 'HARNESS_SECRET=test-secret\n' > "$H/env/global.env"
  printf 'box-hub\n' > "$H/state/box-name"
  # lane-alert.sh IS the pager (log + beat). Stubbed to a ledger so "paged
  # once" and "resolved once" are countable facts rather than log archaeology.
  cat > "$H/bin/lane-alert.sh" <<'STUB'
#!/bin/bash
ID=""; RES=0
while [ $# -gt 0 ]; do
  case "$1" in --id) ID="$2"; shift 2 ;; --resolve) RES=1; shift ;; *) break ;; esac
done
shift 2>/dev/null
printf '%s\t%s\t%s\n' "$([ "$RES" = 1 ] && echo resolve || echo page)" "$ID" "$*" >> "$HARNESS/pages.tsv"
STUB
  chmod +x "$H/bin/lane-alert.sh"
  cat > "$H/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in --data-binary) BODY="$2"; shift 2 ;; -X) M="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
[ "${CURL_MODE:-ok}" = down ] && exit 7
case "$URL" in
  */api/lanes/tick*)  printf '{"lane":{}}\n200\n' ;;
  */api/lanes/alert*) printf '{"lane":{}}\n200\n' ;;
  */api/lanes*)       printf '%s\n200\n' "$(cat "${LANES_FIXTURE:-/dev/null}" 2>/dev/null || echo '{"lanes":[]}')" ;;
  */api/flags/*)      printf '{"error":"not found"}\n404\n' ;;
  *)                  printf '{"ok":1}\n200\n' ;;
esac
STUB
  chmod +x "$H/fakebin/curl"
  printf '%s' "$H"
}

# Every POST body sent to the tick route, in order.
ticks() { grep 'POST .*/api/lanes/tick ' "$1/req.txt" 2>/dev/null | sed -E 's|^POST [^ ]+ ||'; }
# The alert latch writes: `<project> <box> <alerted>` per PATCH.
latches() {
  grep 'PATCH .*/api/lanes/alert ' "$1/req.txt" 2>/dev/null | sed -E 's|^PATCH [^ ]+ ||' \
    | jq -r '[.project,.box,(.alerted|tostring)]|join(" ")' 2>/dev/null
}
beat() { # beat <harness> <shell-snippet> — source the lib and run it, with the fake curl on PATH
  local H="$1"; shift
  ( export PATH="$H/fakebin:$PATH" HARNESS="$H" REQ_SINK="$H/req.txt" \
           HB_DIR="$H/state/heartbeat" HB_DB_CMD="$H/bin/jobs-client.sh"
    # shellcheck disable=SC1090
    . "$H/bin/lib/heartbeat.sh"; eval "$@" )
  # The write-through is detached on purpose (a slow worker must not stretch a
  # lane's rhythm), so the request lands a beat after the call returns.
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$H/req.txt" ] && break; sleep 0.2
  done
}
reap() { # reap <harness> [curl-mode]
  local H="$1" mode="${2:-ok}"
  ( export PATH="$H/fakebin:$PATH" HARNESS="$H" REQ_SINK="$H/req.txt" CURL_MODE="$mode" \
           HB_DIR="$H/state/heartbeat" HB_NOW="${HB_NOW:-$(date +%s)}" HB_BOOT_AT=1
    bash "$H/bin/heartbeat-reaper.sh" >/dev/null 2>&1 )
}
# A decorated lanes payload as the worker hands one back.
lanes_json() { # lanes_json <lane> <box> <proc_state> <age_s> <alerted 0|1> [pid]
  jq -nc --arg p "hb.$1" --arg b "$2" --arg s "$3" --argjson a "$4" \
     --argjson al "$5" --argjson pid "${6:-4242}" \
     '{lanes:[{project:$p,box:$b,state:"unexpected",stale:false,
               proc_state:$s,proc_age_s:$a,proc_pid:$pid,proc_stale_after_s:900,
               proc_stale:($s=="silent" or $s=="overdue"),
               proc_started_at:"2026-09-19T09:00:00Z",proc_note:"waiting on CI",
               alerted_at:(if $al==1 then "2026-09-19T11:00:00Z" else null end)}]}'
}

# ===========================================================================
# 1. The beat reaches the ROW, carrying what a page needs to name the process
# ===========================================================================
H=$(new_harness); : > "$H/req.txt"
touch "$H/flags/lane-liveness-db"
beat "$H" 'HB_PID=4242 hb_start merge-conductor 300 3600 "merges" ""'
B=$(ticks "$H" | head -1)
[ -n "$B" ] && ok || bad "hb_start must write through to the lanes row (nothing was sent)"
[ "$(jq -r '.project' <<<"$B" 2>/dev/null)" = "hb.merge-conductor" ] \
  && ok || bad "a process row is keyed hb.<lane>, out of fleet.conf's namespace (got $(jq -r '.project' <<<"$B" 2>/dev/null))"
[ "$(jq -r '.event' <<<"$B" 2>/dev/null)" = start ] \
  && ok || bad "a launch must be a start event, not a bare tick"
[ "$(jq -r '.pid' <<<"$B" 2>/dev/null)" = 4242 ] \
  && ok || bad "the pid must ride along, or the page cannot name what to look for"
[ "$(jq -r '.interval_s' <<<"$B" 2>/dev/null)" = 300 ] \
  && ok || bad "the declared rhythm must ride along — the worker's threshold derives from it"
[ "$(jq -r '.expect_s' <<<"$B" 2>/dev/null)" = 3600 ] \
  && ok || bad "the expected-by must ride along, or an alive-but-wedged lane can never be overdue"
# A KIND IS NOT AN EVENT. The cron half of the row must be untouched by a
# process beat, or a box whose crontab died reads alive because a loop is
# breathing — the 2026-08-30 failure, reintroduced by its own fix.
[ "$(jq -r '.kind // "absent"' <<<"$B" 2>/dev/null)" = absent ] \
  && ok || bad "a process beat must not send a cron tick kind"

: > "$H/req.txt"
beat "$H" 'HB_PID=4242 HB_LANE=merge-conductor hb_tick merge-conductor "waiting on CI"'
B=$(ticks "$H" | head -1)
[ "$(jq -r '.event' <<<"$B" 2>/dev/null)" = beat ] \
  && ok || bad "hb_tick must beat the row (got event $(jq -r '.event' <<<"$B" 2>/dev/null))"
[ "$(jq -r '.note' <<<"$B" 2>/dev/null)" = "waiting on CI" ] \
  && ok || bad "the lane's own last words must reach the row"

# A BEAT MUST NOT REWRITE THE LAUNCH'S DECLARED RHYTHM. hb_start above declared
# 300, but blocked-resolver declares 1800 (FIX_LANE_TIMEOUT/3) and its fix
# rounds legitimately run to 5400s — if every beat sent 300 the row's threshold
# would collapse to 900 and a healthy fix round would page `silent` while the
# FILE said fresh. Two detectors disagreeing is the thing this slice ends.
: > "$H/req.txt"
beat "$H" 'HB_PID=4243 hb_start blocked-resolver 1800 5400 "retries" ""'
B=$(ticks "$H" | head -1)
[ "$(jq -r '.interval_s' <<<"$B" 2>/dev/null)" = 1800 ] \
  && ok || bad "a launch declares its own rhythm (got $(jq -r '.interval_s' <<<"$B" 2>/dev/null))"
: > "$H/req.txt"
beat "$H" 'HB_PID=4243 HB_LANE=blocked-resolver hb_tick blocked-resolver "TK-1"'
B=$(ticks "$H" | head -1)
[ "$(jq -r '.interval_s // "absent"' <<<"$B" 2>/dev/null)" = absent ] \
  && ok || bad "a beat must send NO rhythm — the launch's number is the row's (got $(jq -r '.interval_s' <<<"$B" 2>/dev/null))"

# ...AND THE WRITE-THROUGH IS RATE-LIMITED AT THE WRITER. wake-loop beats four
# times a minute against a stale floor of 600s: one detached client spawn + one
# D1 write per beat is ~8.6k writes a day for a fact that changes every ten
# minutes. A beat inside half the rhythm (HB_INTERVAL_S, 300s by default, and
# always well under the row's own stale threshold) updates the FILE and sends
# nothing.
: > "$H/req.txt"
beat "$H" 'HB_PID=4243 HB_LANE=blocked-resolver hb_tick blocked-resolver "TK-2"'
[ -z "$(ticks "$H")" ] \
  && ok || bad "a second beat inside the window must not spend a DB write: $(ticks "$H")"
[ "$(jq -r '.note' "$H/state/heartbeat/blocked-resolver.4243.json" 2>/dev/null)" = "TK-2" ] \
  && ok || bad "the FILE is the write-ahead and is always written, rate limit or not"
# ...and once the window is past, the next beat lands.
: > "$H/req.txt"
beat "$H" 'HB_PID=4243 HB_LANE=blocked-resolver HB_DB_MIN_GAP_S=0 hb_tick blocked-resolver "TK-3"'
[ "$(jq -r '.event' <<<"$(ticks "$H" | head -1)" 2>/dev/null)" = beat ] \
  && ok || bad "a beat past the window must reach the row"

: > "$H/req.txt"
beat "$H" 'HB_PID=4242 hb_done merge-conductor'
B=$(ticks "$H" | head -1)
[ "$(jq -r '.event' <<<"$B" 2>/dev/null)" = done ] \
  && ok || bad "a clean exit must be recorded, or every finished lane pages when its beats age out"

# ===========================================================================
# 2. Dark until the flag says otherwise — and the flag is a row, cached as a file
# ===========================================================================
H=$(new_harness); : > "$H/req.txt"     # no flags/lane-liveness-db
beat "$H" 'HB_PID=1 hb_start merge-conductor 300 3600 "" ""'
[ -z "$(ticks "$H")" ] && ok || bad "with the flag off nothing may be sent: this lands dark"
[ -s "$(HB_DIR="$H/state/heartbeat" ; echo "$H/state/heartbeat/merge-conductor.1.json")" ] \
  && ok || bad "the FILE is still the write-ahead and must be written whatever the flag says"
grep -q 'flags/lane-liveness-db' "$DIR/bin/lib/heartbeat.sh" \
  && ok || bad "the writer must gate on the flag FILE (a beat may not pay a round trip to ask)"
grep -q 'flag_active lane-liveness-db' "$DIR/bin/heartbeat-reaper.sh" \
  && ok || bad "the reader must reconcile the flag from its DB row (flag_active), not test a file nobody syncs"

# ===========================================================================
# 3. The ledger is never the reason a lane dies
# ===========================================================================
H=$(new_harness); touch "$H/flags/lane-liveness-db"
rm -f "$H/bin/jobs-client.sh"          # no client on this box at all
beat "$H" 'HB_PID=7 hb_start orphan-lane 300 0 "" ""'
[ -s "$H/state/heartbeat/orphan-lane.7.json" ] \
  && ok || bad "a missing client must not cost the file write"
( export PATH="$H/fakebin:$PATH" HARNESS="$H" HB_DIR="$H/state/heartbeat" HB_DB_CMD="$H/bin/jobs-client.sh"
  # shellcheck disable=SC1090
  . "$H/bin/lib/heartbeat.sh"; HB_PID=7 hb_tick orphan-lane "x" ) ; RC=$?
[ "$RC" = 0 ] && ok || bad "a beat must return 0 whatever the ledger does (rc $RC)"

# A HANGING WORKER MUST NOT STRETCH A LANE'S RHYTHM. The write-through is
# detached for exactly this: a lane that beats every 300s and waits on a wedged
# socket is a lane that has stopped, which is the condition being detected.
H=$(new_harness); touch "$H/flags/lane-liveness-db"
cat > "$H/bin/jobs-client.sh" <<'SLOW'
#!/bin/bash
sleep 30  # determinism: ok — the STUB's body, modelling a worker that hangs; the test below waits on the CLOCK it must not have paid, not on this
SLOW
chmod +x "$H/bin/jobs-client.sh"
S=$(date +%s)
( export PATH="$H/fakebin:$PATH" HARNESS="$H" HB_DIR="$H/state/heartbeat" HB_DB_CMD="$H/bin/jobs-client.sh"
  # shellcheck disable=SC1090
  . "$H/bin/lib/heartbeat.sh"; HB_PID=8 hb_tick slow-lane "x" )
E=$(( $(date +%s) - S ))
[ "$E" -lt 5 ] && ok || bad "a hanging worker blocked the beat for ${E}s — the lane's rhythm is its own"

# ===========================================================================
# 4. The row pages for what no file here could speak for — once, then recovery
# ===========================================================================
# THE CASE: merge-conductor died on box-project-3-2. Nothing on THIS box
# ever wrote a file for it, and that box's cron keeps ticking, so every other
# detector we have reads healthy.
H=$(new_harness); touch "$H/flags/lane-liveness-db"; : > "$H/req.txt"
lanes_json merge-conductor box-project-3-2 silent 1800 0 > "$H/lanes.json"
LANES_FIXTURE="$H/lanes.json" reap "$H"
P=$(grep -c '^page' "$H/pages.tsv" 2>/dev/null || echo 0)
[ "${P:-0}" -ge 1 ] && ok || bad "a lane process the row calls stale must page (pages: $(cat "$H/pages.tsv" 2>/dev/null))"
grep -q 'box-project-3-2' "$H/pages.tsv" 2>/dev/null \
  && ok || bad "the page must name the box the process died on"
grep -qE 'pid 4242|pid ?4242' "$H/pages.tsv" 2>/dev/null \
  && ok || bad "the page must carry the pid from the row"
[ "$(latches "$H" | head -1)" = "hb.merge-conductor box-project-3-2 true" ] \
  && ok || bad "the stale latch must be set on the row (got: $(latches "$H" | head -1))"

# Second pass, row now latched: silence. A page every five minutes is how a
# channel stops being read.
: > "$H/pages.tsv"; : > "$H/req.txt"
lanes_json merge-conductor box-project-3-2 silent 2100 1 > "$H/lanes.json"
LANES_FIXTURE="$H/lanes.json" reap "$H"
[ ! -s "$H/pages.tsv" ] && ok || bad "an already-latched lane must page again: $(cat "$H/pages.tsv")"

# It comes back: one resolve, and the latch is cleared so the NEXT death pages.
: > "$H/pages.tsv"; : > "$H/req.txt"
lanes_json merge-conductor box-project-3-2 fresh 60 1 > "$H/lanes.json"
LANES_FIXTURE="$H/lanes.json" reap "$H"
grep -q '^resolve' "$H/pages.tsv" 2>/dev/null \
  && ok || bad "recovery must be said out loud (pages: $(cat "$H/pages.tsv" 2>/dev/null))"
[ "$(latches "$H" | head -1)" = "hb.merge-conductor box-project-3-2 false" ] \
  && ok || bad "recovery must clear the latch, or the next real death is swallowed"

# A lane that finished on purpose is NOT a death.
H=$(new_harness); touch "$H/flags/lane-liveness-db"; : > "$H/req.txt"
lanes_json wake-loop box-hub ended 7200 0 > "$H/lanes.json"
LANES_FIXTURE="$H/lanes.json" reap "$H"
[ ! -s "$H/pages.tsv" ] && ok || bad "a clean exit must never page: $(cat "$H/pages.tsv")"

# ===========================================================================
# 5. ONE finding per lane: the file pass owns this box, the row covers the rest
# ===========================================================================
H=$(new_harness); touch "$H/flags/lane-liveness-db"; : > "$H/req.txt"
NOW=$(date +%s)
printf '{"lane":"merge-conductor","pid":999999,"box":"box-hub","started_at":%s,"last_tick":%s,"interval":300,"deadline":0,"note":"","blocks":"merges","restart":"","stale":false,"stale_at":0}\n' \
  "$(( NOW - 7200 ))" "$(( NOW - 3600 ))" > "$H/state/heartbeat/merge-conductor.999999.json"
lanes_json merge-conductor box-hub silent 3600 0 > "$H/lanes.json"
LANES_FIXTURE="$H/lanes.json" reap "$H"
P=$(grep -c . "$H/pages.tsv" 2>/dev/null || echo 0)
[ "${P:-0}" = 1 ] && ok || bad "one dead lane, one finding — the file pass and the row must not both report it (got ${P:-0}: $(cat "$H/pages.tsv" 2>/dev/null))"

# ...but ONE FINDING PER LANE IS ONE FINDING PER LANE **ON A BOX**. The same
# lane name runs on several boxes (hub-lease failover moves merge-conductor), and
# a stale file here must not silence the row's finding for the same lane
# somewhere else — that is the exact case the DB pass exists to cover, and the
# latch would be set for a page nobody ever saw.
H=$(new_harness); touch "$H/flags/lane-liveness-db"; : > "$H/req.txt"
NOW=$(date +%s)
printf '{"lane":"merge-conductor","pid":999997,"box":"box-hub","started_at":%s,"last_tick":%s,"interval":300,"deadline":0,"note":"","blocks":"merges","restart":"","stale":false,"stale_at":0}\n' \
  "$(( NOW - 7200 ))" "$(( NOW - 3600 ))" > "$H/state/heartbeat/merge-conductor.999997.json"
lanes_json merge-conductor box-project-3-2 silent 3600 0 > "$H/lanes.json"
LANES_FIXTURE="$H/lanes.json" reap "$H"
grep -q 'box-project-3-2' "$H/pages.tsv" 2>/dev/null \
  && ok || bad "a stale file for this box must not swallow the same lane's death on ANOTHER box: $(cat "$H/pages.tsv" 2>/dev/null)"
[ "$(grep -c . "$H/pages.tsv" 2>/dev/null || echo 0)" = 2 ] \
  && ok || bad "two boxes, two findings (got: $(cat "$H/pages.tsv" 2>/dev/null))"

# ...and with the flag OFF the reaper asks the DB nothing at all.
H=$(new_harness); : > "$H/req.txt"
lanes_json merge-conductor box-project-3-2 silent 1800 0 > "$H/lanes.json"
LANES_FIXTURE="$H/lanes.json" reap "$H"
grep -q 'GET .*/api/lanes' "$H/req.txt" 2>/dev/null \
  && bad "with the flag off the reaper must not read the lanes route" || ok
[ ! -s "$H/pages.tsv" ] && ok || bad "with the flag off nothing may page from the row"

# ...and an unreachable worker costs nothing: the file pass still runs.
H=$(new_harness); touch "$H/flags/lane-liveness-db"; : > "$H/req.txt"
printf '{"lane":"blocked-resolver","pid":999998,"box":"box-hub","started_at":%s,"last_tick":%s,"interval":300,"deadline":0,"note":"","blocks":"retries","restart":"","stale":false,"stale_at":0}\n' \
  "$(( NOW - 7200 ))" "$(( NOW - 3600 ))" > "$H/state/heartbeat/blocked-resolver.999998.json"
LANES_FIXTURE="$H/lanes.json" reap "$H" down
grep -q 'blocked-resolver' "$H/pages.tsv" 2>/dev/null \
  && ok || bad "an unreachable worker must not cost the file pass its finding"

# ===========================================================================
# 6. ONE fact means the others are GONE, not merely unread
# ===========================================================================
[ ! -e "$DIR/bin/fleet-heartbeat.sh" ] \
  && ok || bad "bin/fleet-heartbeat.sh is the second answer this slice deletes — it is still here"
! grep -rq 'fleet-heartbeat\.sh' "$(rendered_cron_dir)"/*.cron 2>/dev/null \
  && ok || bad "a cron line still runs the deleted ssh probe"
# The remaining box-liveness reader must read the ROW, not a directory the
# deleted lane used to write.
grep -q 'lanes_list\|lane_procs' "$DIR/bin/fleet-slo.sh" \
  && ok || bad "bin/fleet-slo.sh's box_silent SLO must read the lanes row now that nothing writes state/fleet-heartbeat"

# ===========================================================================
# 7. The worker's own verdict on the exact shape: cron ticking, process dead
# ===========================================================================
if command -v node >/dev/null 2>&1; then
  # THIS CASE RENDERS WHAT IT IMPORTS (BH-1304). worker/jobs/src/index.js pulls
  # in core.js, which STATICALLY imports $DIR/catalog/lanes.json — a generated,
  # uncommitted file (BH-1247) and a path baked into the module, so rendering it
  # into $T through rendered_registry cannot satisfy the import. Until now this
  # case passed only because case 6's rendered_cron_dir happened to leave a
  # render in the checkout first: deterministic, and coupled to an order nothing
  # states. These are the same lines tests/jobs-worker-test.sh uses for the same
  # import, into the CHECKOUT because that is the only place the import looks.
  if [ -x "$DIR/bin/lanes-build.sh" ] && [ -d "$DIR/catalog/lanes.d" ]; then
    "$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null 2>&1 \
      || bad "case 7: catalog/lanes.json could not be composed from catalog/lanes.d — the worker import below cannot resolve"
  fi
  V=$(node --input-type=module -e '
    import { decorateLane } from "'"$DIR"'/worker/jobs/src/index.js";
    const t = "2026-09-19T12:00:00Z";
    const ago = (s) => new Date(Date.parse(t) - s*1000).toISOString().replace(/\.\d{3}Z$/, "Z");
    const r = decorateLane({ project: "hb.merge-conductor", box: "box-project-3-2",
      cadence_min: 10, expected_since: "2026-09-01T00:00:00Z", last_tick_at: ago(60),
      retired_at: null, alerted_at: null, updated_at: t,
      proc_pid: 4242, proc_interval_s: 300, proc_beat_at: ago(1800), proc_ended_at: null }, t);
    process.stdout.write([r.state, String(r.stale), r.proc_state, String(r.proc_stale)].join(" "));
  ' 2>/dev/null)
  [ "$V" = "live false silent true" ] \
    && ok || bad "the worker must call the PROCESS stale while the CRON reads live (got: ${V:-nothing})"
else
  echo "lane-liveness-single-fact-test: node absent — skipping the worker verdict case"
fi

echo "lane-liveness-single-fact-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
