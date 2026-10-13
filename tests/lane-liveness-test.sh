#!/bin/bash
# tests/lane-liveness-test.sh — the fleet knows what is SUPPOSED to be ticking,
# and says so when it stops.
#
# THE INCIDENT THIS PINS. On 2026-08-30 project `project-7` lost every one of its
# crons on box-project-6-1 at 05:17 (a daily crontab re-apply from a
# stale repo file) and the lane was silent for TEN HOURS with nothing alerting.
# Every detector we had was looking at work that HAPPENED: the box kept pinging
# (it still ran its other lane), the hub kept pushing fleet status, and a lane
# that never ticks claims no job, so bin/jobs-watchdog.sh had no row to age.
# Nothing in the system held the fact that this lane was expected at all.
#
# Three claims decide whether the fix is machinery or decoration, and all three
# are about behaviour under failure, so all three are DRIVEN here:
#
#   1. THE EXPECTED SET COMES FROM fleet.conf, keyed on the box's REAL name.
#      The expectation and the heartbeat must land on the same row: fleet.conf
#      carries hostnames (box-project-6-1) while cron files are keyed by
#      short id (project-6), and "local" means the hub, which reports itself as
#      box-hub. Any of those three mapped wrong and every lane in the
#      fleet reads permanently dead.
#   2. A SKIP TICK IS A HEARTBEAT. Most ticks on a quiet board are the gate
#      finding nothing changed — no job claimed, no dollar spent. If only the
#      expensive ticks counted as life, every healthy quiet lane would page.
#   3. IT PAGES ONCE, AND AGAIN ONLY TO SAY IT CAME BACK. A silent lane alerts
#      on the first pass and is then latched; recovery clears the latch and says
#      so. A page every five minutes for ten hours is a channel nobody reads.
#
# Run from anywhere: tests/lane-liveness-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json and cron/<box>.cron are GENERATED and not
# committed. rendered_registry / rendered_cron render this repo's own into $T.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
# TEST-CHANGE (BH-5651): the fleet is read from a registry cache in db mode,
# through bin/lib/registry.sh, the reader every box uses after the switch.
. "$DIR/tests/lib/registry-cache.bh-5651.sh" || exit 1
command -v jq >/dev/null 2>&1 || { echo "lane-liveness-test: SKIPPED — jq is not installed"; exit 0; }
BASE="$T"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# A scratch $HARNESS per case, with a curl that records every request and
# answers per path. CURL_MODE=down models an unreachable worker, because
# "the ledger can never be the reason a lane does less work" is the property
# that matters most and cannot be grepped for.
new_harness() {
  local T; T=$(mktemp -d "$BASE/h-XXXXXX")
  mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/flags" "$T/env" "$T/locks" \
           "$T/prompts" "$T/builds" "$T/fakebin"
  . "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T" alpha-os || exit 1  # BH-1510.2: lanes read models from model_routes
  cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" \
     "$DIR/bin/fleet-fly-block.sh" "$DIR/bin/triage-contract.sh" "$T/bin/"
  mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
  mkdir -p "$T/bin/lib/rt" && cp "$DIR"/bin/lib/rt/*.sh "$T/bin/lib/rt/"
  # TEST-CHANGE (BH-5651): fleet-conf.sh in db mode sources bin/lib/registry.sh
  # and what it sources; the closure copies them, never a hand list.
  scratch_install_closure bin/fleet-conf.sh "$T" >/dev/null || exit 1
  # run-triage.sh refuses a tick whose system-append contract will not resolve,
  # rather than shipping a tick with no BUILD DEDUPE and no DECISION LOG rule. A
  # sandbox therefore needs the contract the way a real box gets it — via
  # harness-sync's `rsync catalog/` — or every tick here dies before agent-call
  # and this file's liveness claims measure the missing fixture instead.
  mkdir -p "$T/catalog/agent-contracts"
  cp "$DIR/catalog/agent-contracts/triage-system-append.txt" "$T/catalog/agent-contracts/"
  printf 'HARNESS_SECRET=test-secret\n' > "$T/env/global.env"
  printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
  cat > "$T/fakebin/curl" <<'STUB'
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
  */api/lanes*)
    if [ "$M" = GET ]; then
      printf '%s\n200\n' "$(cat "${LANES_FIXTURE:-/dev/null}" 2>/dev/null || echo '{"lanes":[]}')"
    else printf '{"expected":0,"retired":0}\n200\n'; fi ;;
  */api/jobs*)   printf '{"jobs":[]}\n200\n' ;;
  */api/flags/*) printf '{"error":"not found"}\n404\n' ;;
  *)             printf '{"ok":1}\n200\n' ;;
esac
STUB
  chmod +x "$T/fakebin/curl"
  # macOS has no flock(1), and both scripts under test take a lock before doing
  # anything. Without this the whole suite would pass vacuously on a laptop by
  # exiting at the lock and never reaching the behaviour it claims to test. CI
  # is Linux and uses the REAL flock, so the shim is a laptop affordance only —
  # never a substitute for the guard.
  command -v flock >/dev/null 2>&1 \
    || { printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"; }
  printf '%s' "$T"
}

# The PUT body the hub sent, or nothing.
expected_put() { grep -m1 'PUT .*/api/lanes ' "$1/req.txt" 2>/dev/null | sed -E 's|^PUT [^ ]+ ||'; }
# The `kind` values of every lane tick recorded, in order.
tick_kinds() {
  grep 'POST .*/api/lanes/tick ' "$1/req.txt" 2>/dev/null \
    | sed -E 's|^POST [^ ]+ ||' | jq -r '.kind' 2>/dev/null
}

# ===========================================================================
# 1. The expected set: derived from fleet.conf, keyed on the box's REAL name
# ===========================================================================
push_lanes() { # push_lanes <harness> [curl-mode]
  local T="$1" mode="${2:-ok}"
  : > "$T/req.txt"
  sed "s|^H=/root/harness|H=$T|" "$DIR/bin/fleet-status-push.sh" > "$T/fsp.sh"
  # A stub worker, because scratch.sh exports JOBS_URL empty (BH-3223), and its
  # own registry, because bin/fleet-conf.sh reads /root/harness/fleet.conf first.
  # TEST-CHANGE (BH-5651): the registry is a cache under $T/state/registry,
  # built from the fixture rows in $T/rows.conf, read in db mode with
  # HARNESS=$T. With no rows file there is no cache: the ladder fetches from the
  # stub worker, which answers no registry, and fleet-conf.sh falls back to
  # FLEET_CONF.
  ( if [ -f "$T/rows.conf" ]; then rcache_install "$T" "$T/rows.conf" || exit 1; fi
    export PATH="$T/fakebin:$PATH" REQ_SINK="$T/req.txt" CURL_MODE="$mode" \
      JOBS_URL=https://jobs.invalid FLEET_CONF="$T/fleet.conf" HARNESS="$T" \
      REGISTRY_SOURCE=db REGISTRY_CACHE_TTL_S=86400
    bash "$T/fsp.sh" >/dev/null 2>&1 )
}

T=$(new_harness)
# TEST-CHANGE (BH-5651): the fixture rows become the registry, not $T/fleet.conf.
cat > "$T/rows.conf" <<'EOF'
# fixture registry — every box-column shape the real one carries
alpha-os    Org/alpha  https://a.example /api/board 2 box-alpha
project-7    Org/project-7 https://t.example -        1 box-project-6-1
project-6   Org/mk     -                  -        3 box-project-6-1
legacy-os   Org/legacy -                  -        7
project-1 Org/mom    -                  -        2
EOF
push_lanes "$T"
PUT=$(expected_put "$T")
[ -n "$PUT" ] && jq -e . >/dev/null 2>&1 <<<"$PUT" \
  && ok || bad "the hub must push an expected-lanes set (got: ${PUT:-nothing})"
[ "$(jq -r '.lanes | length' <<<"$PUT")" = 5 ] \
  && ok || bad "one lane per fleet.conf row (got $(jq -r '.lanes | length' <<<"$PUT"))"

# THE KEY MUST MATCH WHAT THE BOX REPORTS. fleet.conf's box column holds the
# hostname; cron files are named by the short box-id (cron/project-6.cron), and
# bin/box-name.sh resolves the hostname out of that file's ping line. Keying the
# expectation on the short form would mean the heartbeat and the expectation
# never meet, and every lane in the fleet would read permanently dead.
[ "$(jq -r '.lanes[] | select(.project=="project-7") | .box' <<<"$PUT")" = box-project-6-1 ] \
  && ok || bad "project-7 must be keyed on the box hostname, not the box id"
# ...and the incident's own shape: TWO lanes on ONE box, one of which died while
# the other kept ticking. A per-box signal could not have caught it; a per-lane
# one can only catch it if both lanes are declared separately.
[ "$(jq -r '[.lanes[] | select(.box=="box-project-6-1")] | length' <<<"$PUT")" = 2 ] \
  && ok || bad "two projects sharing one box must be two lanes, not one"
# A legacy row with no box column resolves by the naming convention...
[ "$(jq -r '.lanes[] | select(.project=="legacy-os") | .box' <<<"$PUT")" = box-legacy ] \
  && ok || bad "a row with no box column must resolve through bin/box-for.sh"
# ...and "local" — the hub running a lane itself — must become the name the hub
# actually reports (its own crontab pings as box-hub), never the literal
# string "local", which no box would ever tick under.
[ "$(jq -r '.lanes[] | select(.project=="project-1") | .box' <<<"$PUT")" = box-hub ] \
  && ok || bad "a 'local' lane must be keyed on the hub's real box name (got $(jq -r '.lanes[]|select(.project=="project-1")|.box' <<<"$PUT"))"
# The cadence rides ON the row, so the staleness threshold is a DB fact every
# reader shares rather than a constant re-decided in each of them.
[ "$(jq -r '.lanes[] | select(.project=="project-7") | .cadence_min' <<<"$PUT")" = 10 ] \
  && ok || bad "each lane must carry its expected cadence"
[ "$(jq -r '.lanes[] | select(.project=="project-7") | .offset_min' <<<"$PUT")" = 1 ] \
  && ok || bad "the fleet.conf offset must ride along (it is what staggers the fleet)"

# A row added to the registry appears with no code change — that IS the fix.
# TEST-CHANGE (BH-5651): the row is added to the registry (push_lanes rebuilds
# the cache from the rows), not to a fleet.conf file.
echo 'brand-new Org/new - - 8 box-small' >> "$T/rows.conf"
push_lanes "$T"
[ "$(jq -r '[.lanes[] | select(.project=="brand-new")] | length' <<<"$(expected_put "$T")")" = 1 ] \
  && ok || bad "a new registry row must be declared without a code change"
grep -q '^brand-new ' "$T/state/registry/fleet.conf" \
  && ok || bad "the new row did not reach the registry cache, so the push above did not read the registry"

# An unusable registry with no cache and no usable fleet.conf must push
# NOTHING. Declaring an empty expected set would retire every lane in the
# fleet — silently un-watching it, which is the most reassuring possible shape
# for a total outage.
# TEST-CHANGE (BH-5651): was "an empty fleet.conf". Now the cache is gone, the
# stub worker answers no registry, and FLEET_CONF is an empty file (a missing
# one would fall through to /root/harness/fleet.conf on a live box, so the
# empty file is the hermetic form of "no fleet.conf").
rm -f "$T/rows.conf"; rm -rf "$T/state/registry"; : > "$T/fleet.conf"
push_lanes "$T"
[ -z "$(expected_put "$T")" ] \
  && ok || bad "an unusable registry with no cache declared an expected set: $(expected_put "$T")"
[ ! -s "$T/state/registry/registry.json" ] \
  && ok || bad "the stub's non-registry answer was cached as a registry"

# ===========================================================================
# 2. Every path out of run-triage.sh is a live lane
# ===========================================================================
seed_triage() { # seed_triage <harness> <gate-decision>
  local T="$1" gate="$2"
  printf 'the SOP\n' > "$T/prompts/alpha-os.md"
  printf '#!/bin/bash\necho "%s"\n' "$gate" > "$T/bin/triage-gate.sh"
  chmod +x "$T/bin/triage-gate.sh"
  # agent-call.sh records that it was reached. A skip tick that still called the
  # model would make the whole point of this test vacuous.
  printf '#!/bin/bash\ntouch "%s/AGENT_CALLED"\nexit 0\n' "$T" > "$T/bin/agent-call.sh"
  chmod +x "$T/bin/agent-call.sh"
  printf '#!/bin/bash\nexit 0\n' > "$T/bin/decision-log.sh"; chmod +x "$T/bin/decision-log.sh"
}
run_triage() { # run_triage <harness> [curl-mode]
  local T="$1" mode="${2:-ok}"
  : > "$T/req.txt"; rm -f "$T/AGENT_CALLED"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" REQ_SINK="$T/req.txt" CURL_MODE="$mode" \
           JOBS_URL=https://jobs.invalid JOBS_BOX=box-alpha
    bash "$DIR/bin/run-triage.sh" alpha-os >/dev/null 2>&1 )
  echo $?
}

# --- a gate SKIP is a heartbeat --------------------------------------------
T=$(new_harness); seed_triage "$T" "SKIP no-change"
RC=$(run_triage "$T")
[ "$RC" = 0 ] && ok || bad "a skipped tick must exit 0, got $RC"
[ ! -f "$T/AGENT_CALLED" ] \
  && ok || bad "the fixture did not actually take the skip path — nothing below proves anything"
KINDS=$(tick_kinds "$T")
grep -qx skip <<<"$KINDS" \
  && ok || bad "a gate SKIP must heartbeat its lane (kinds seen: ${KINDS//$'\n'/,})"
grep -qx start <<<"$KINDS" \
  && ok || bad "the tick must be recorded BEFORE any early exit can swallow it"
# ...and it must still claim nothing. A row per skip tick would be hundreds of
# empty coordination rows a day, which is the cost the lazy-claim rule exists to
# avoid; the lane tick is deliberately NOT a job.
[ "$(grep -c 'POST .*/api/jobs ' "$T/req.txt")" = 0 ] \
  && ok || bad "a skip tick opened a job row — the lane tick must not become a claim"
[ "$(jq -r .box <<<"$(grep -m1 'POST .*/api/lanes/tick ' "$T/req.txt" | sed -E 's|^POST [^ ]+ ||')")" = box-alpha ] \
  && ok || bad "the tick must name the box the expectation is keyed on"

# --- a paused lane is alive; only a LOST CRON is silence --------------------
T=$(new_harness); seed_triage "$T" "SKIP no-change"; touch "$T/flags/paused-alpha-os"
run_triage "$T" >/dev/null
grep -qx paused <<<"$(tick_kinds "$T")" \
  && ok || bad "a console-paused lane still ticks — pausing work is not the cron dying"

# --- a run that reaches the model ticks with its outcome --------------------
T=$(new_harness); seed_triage "$T" "RUN board-changed"
run_triage "$T" >/dev/null
[ -f "$T/AGENT_CALLED" ] && ok || bad "the RUN fixture never reached agent-call.sh"
grep -qx run <<<"$(tick_kinds "$T")" \
  && ok || bad "a completed tick must record its outcome on the lane"

# --- FAIL OPEN: an unreachable worker costs the lane nothing ----------------
# TEST-CHANGE BH-4153: paused-<project> is a harness_flags row read DB-first, and
# with the worker down and NOTHING cached it is unknown, read as ON (a stop
# switch fails closed, plan Decision 7). A box that has read its pause once keeps
# running through an outage: seed the last-good "not paused" answer it would hold.
T=$(new_harness); seed_triage "$T" "RUN board-changed"
mkdir -p "$T/state/flags-cache/fleet"
printf '{"on":false,"value":null,"set_at":null,"cleared_at":null,"src":"db","stamp":1700000000}\n' \
  > "$T/state/flags-cache/fleet/paused-alpha-os"
RC=$(run_triage "$T" down)
[ "$RC" = 0 ] && [ -f "$T/AGENT_CALLED" ] \
  && ok || bad "with the worker down the tick did not run (rc=$RC) — the ledger became a gate"
# TEST-CHANGE BH-4153: the fail-closed half. Worker down and no cache entry: the
# pause cannot be read, so the tick is a paused tick and never reaches the agent.
T=$(new_harness); seed_triage "$T" "RUN board-changed"
RC=$(run_triage "$T" down)
[ "$RC" = 0 ] && [ ! -f "$T/AGENT_CALLED" ] && grep -q 'paused via console, skipping' "$T/logs/alpha-os.log" 2>/dev/null \
  && ok || bad "worker down with no cached pause answer must be a paused tick, not reach the agent (rc=$RC, agent=$([ -f "$T/AGENT_CALLED" ] && echo called || echo not))"
# ...and with no client on the box at all.
T=$(new_harness); seed_triage "$T" "RUN board-changed"; rm -f "$T/bin/jobs-client.sh"
RC=$(run_triage "$T")
[ "$RC" = 0 ] && [ -f "$T/AGENT_CALLED" ] \
  && ok || bad "with bin/jobs-client.sh absent the tick stopped working (rc=$RC)"

# ===========================================================================
# 3. The watchdog: page once, recover once
# ===========================================================================
# lane_json <project> <box> <state> <tick_age|null> <alerted_at|null> [kind] [ticked_since_declared]
# The last field defaults to 1 — the ordinary lane, which HAS ticked under the
# expectation in force. 0 is the re-declared shape: a lane just added back to
# fleet.conf, carrying a real tick from a previous enrolment.
lane_json() {
  jq -nc --arg p "$1" --arg b "$2" --arg s "$3" --arg k "${6:-skip}" \
     --argjson t "$4" --argjson a "$5" --argjson d "${7:-1}" \
    '{project:$p,box:$b,state:$s,stale:($s=="stale"),silence_s:36000,
      tick_age_s:$t,last_tick_kind:$k,alerted_at:$a,stale_after_s:1800,
      last_tick_at:"2026-08-30T05:17:00Z",ticked_since_declared:($d==1)}'
}
run_watchdog() { # run_watchdog <harness> <lanes-json>
  local T="$1"
  : > "$T/req.txt"; : > "$T/logs/ALERTS.log"
  printf '{"lanes":[%s]}' "$2" > "$T/lanes.json"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" REQ_SINK="$T/req.txt" \
           JOBS_URL=https://jobs.invalid JOBS_BOX=box-hub \
           LANES_FIXTURE="$T/lanes.json"
    bash "$DIR/bin/jobs-watchdog.sh" >/dev/null 2>&1 )
}
alerts()  { grep -c 'LANE SILENT' "$1/logs/ALERTS.log" 2>/dev/null || true; }
resumes() { grep -c 'LANE RESUMED' "$1/logs/ALERTS.log" 2>/dev/null || true; }
latched() { grep 'PATCH .*/api/lanes/alert ' "$1/req.txt" 2>/dev/null | sed -E 's|^PATCH [^ ]+ ||'; }

# --- a silent lane pages once, and says what to go look at ------------------
T=$(new_harness)
run_watchdog "$T" "$(lane_json project-7 box-project-6-1 stale 36000 null)"
[ "$(alerts "$T")" = 1 ] \
  && ok || bad "a stale lane must produce exactly one alert (got $(alerts "$T"))"
grep -q 'project-7@box-project-6-1' "$T/logs/ALERTS.log" \
  && ok || bad "the alert must name the lane, not just the project"
grep -q 'crontab' "$T/logs/ALERTS.log" \
  && ok || bad "the alert must name the thing to go check — a page with no next step is noise"
[ "$(jq -r .alerted <<<"$(latched "$T")")" = true ] \
  && ok || bad "the alert must latch, or it repeats every five minutes: $(latched "$T")"

# --- a lane already paged says nothing -------------------------------------
T=$(new_harness)
run_watchdog "$T" "$(lane_json project-7 box-project-6-1 stale 36000 '"2026-08-30T06:00:00Z"')"
[ "$(alerts "$T")" = 0 ] \
  && ok || bad "an already-latched lane re-paged — ten hours of that is 120 identical alerts"
[ -z "$(latched "$T")" ] \
  && ok || bad "an already-latched lane should not rewrite its latch"

# --- THE NEVER-TICKED TWIN --------------------------------------------------
# A lane enrolled in fleet.conf whose box never got the crons at all. There is
# no last tick to age, so the DECLARATION is aged instead — and the alert has to
# say which of the two shapes it is, because the fix is a different one.
T=$(new_harness)
run_watchdog "$T" "$(lane_json brand-new box-small stale null null null)"
[ "$(alerts "$T")" = 1 ] \
  && ok || bad "a lane that has never ticked since it was declared must page"
grep -qi 'never' "$T/logs/ALERTS.log" \
  && ok || bad "the never-ticked case must READ as never-ticked, not as a lane that stopped"

# --- THE RE-DECLARED SHAPE --------------------------------------------------
# A project added back to fleet.conf after a retirement carries a real tick from
# its previous enrolment, so it is neither "never ticked" nor "ticked and
# stopped". Calling it either sends someone to the wrong box: the crontab on
# board X is not lost, it simply has not picked the lane up yet.
T=$(new_harness)
run_watchdog "$T" "$(lane_json back-os box-small stale 10500000 null skip 0)"
[ "$(alerts "$T")" = 1 ] \
  && ok || bad "a lane re-declared but not yet ticking must page"
grep -q 're-declared' "$T/logs/ALERTS.log" \
  && ok || bad "the re-declared case must say so: $(grep 'LANE SILENT' "$T/logs/ALERTS.log")"
grep -qi 'never' "$T/logs/ALERTS.log" \
  && bad "a lane WITH a previous tick was reported as never having ticked" || ok
# The old tick's real age is reported, not the silence — they are different
# numbers here, and printing one as the other is a lie the reader acts on.
grep -q '175000m ago, in a previous enrolment' "$T/logs/ALERTS.log" \
  && ok || bad "the previous tick's real age must be named: $(grep 'LANE SILENT' "$T/logs/ALERTS.log")"

# --- recovery clears the latch and says so ----------------------------------
T=$(new_harness)
run_watchdog "$T" "$(lane_json project-7 box-project-6-1 live 120 '"2026-08-30T06:00:00Z"')"
[ "$(resumes "$T")" = 1 ] \
  && ok || bad "a lane that came back must say so once (got $(resumes "$T"))"
[ "$(jq -r .alerted <<<"$(latched "$T")")" = false ] \
  && ok || bad "recovery must clear the latch, or the lane can never page again: $(latched "$T")"

# --- a healthy lane is silent in both directions ----------------------------
T=$(new_harness)
run_watchdog "$T" "$(lane_json project-7 box-project-6-1 live 120 null)"
[ "$(alerts "$T")" = 0 ] && [ "$(resumes "$T")" = 0 ] && [ -z "$(latched "$T")" ] \
  && ok || bad "a healthy lane produced output"

# --- a lane that has not ticked YET is not an incident ----------------------
T=$(new_harness)
run_watchdog "$T" "$(lane_json brand-new box-small pending null null null)"
[ "$(alerts "$T")" = 0 ] \
  && ok || bad "a freshly declared lane paged before its first tick was even due"

# --- retiring a lane RESOLVES its alert rather than stranding the latch -----
T=$(new_harness)
run_watchdog "$T" "$(lane_json gone-os box-gone retired 36000 '"2026-08-30T06:00:00Z"')"
[ "$(resumes "$T")" = 1 ] && [ "$(jq -r .alerted <<<"$(latched "$T")")" = false ] \
  && ok || bad "a retired lane must clear its latch, or a later re-enrolment could never page"
grep -q 'retired from fleet.conf' "$T/logs/ALERTS.log" \
  && ok || bad "a retirement must not be reported as a recovery — it is a different fact"

# --- an unexpected lane is visible but never alertable ----------------------
T=$(new_harness)
run_watchdog "$T" "$(lane_json rogue box-x unexpected 36000 null)"
[ "$(alerts "$T")" = 0 ] \
  && ok || bad "a lane nobody declared was judged against an expectation nobody made"

# --- the worker being down must not break the watchdog ----------------------
T=$(new_harness)
: > "$T/req.txt"; : > "$T/logs/ALERTS.log"; echo '{"lanes":[]}' > "$T/lanes.json"
( export PATH="$T/fakebin:$PATH" HARNESS="$T" REQ_SINK="$T/req.txt" CURL_MODE=down \
         JOBS_URL=https://jobs.invalid LANES_FIXTURE="$T/lanes.json"
  bash "$DIR/bin/jobs-watchdog.sh" >/dev/null 2>&1 )
RC=$?
[ "$RC" = 0 ] && [ "$(alerts "$T")" = 0 ] \
  && ok || bad "an unreachable worker made the watchdog itself fail or invent lane alerts (rc=$RC)"

# --- no secret ever reaches a log this pass writes --------------------------
T=$(new_harness)
run_watchdog "$T" "$(lane_json project-7 box-project-6-1 stale 36000 null)"
grep -rq test-secret "$T/logs" 2>/dev/null \
  && bad "HARNESS_SECRET leaked into a log" || ok

# ===========================================================================
# 4. THE INVARIANT THE WHOLE FEATURE RESTS ON, asserted against the REPO
# ===========================================================================
# The expectation and the heartbeat are keyed on the same string, produced by
# TWO INDEPENDENT LISTS that nothing forces to agree:
#
#   the hub declares  fleet.conf column 6            -> lanes.box
#   the box ticks     the name in its own crontab's  -> lanes.box
#                     watchdog-ping.sh argument
#                     (bin/box-name.sh reads it out of cron/<box-id>.cron)
#
# A single character of drift between them does not fail loudly. It produces a
# lane that is declared and never ticks — paging NEVER TICKED forever, for a box
# that is working perfectly — plus an UNDECLARED twin row carrying the ticks,
# which nothing alerts on. Both halves look like the feature working.
#
# Asserted against the FILES rather than against any script that writes them, so
# it holds whoever generates the crontabs (a renderer, a human, a capture).
# TEST-CHANGE (BH-5651): the fleet below is this repo's registry, as a cache
# under $BASE/rh read in db mode, and the crontabs render from it. The
# subshell keeps db mode out of the rest of the suite; rendered.sh reuses the
# files it rendered.
RH="$BASE/rh"
( rcache_install "$RH" "$DIR" && export HARNESS="$RH" && rendered_cron_dir >/dev/null && rendered_cron hub >/dev/null ) \
  && ok || bad "could not build this repo's registry cache or render the fleet from it"
CRON_PINGS=$(grep -ho 'watchdog-ping\.sh[[:space:]]\{1,\}[A-Za-z0-9._-]\{1,\}' "$(rendered_cron_dir)"/*.cron 2>/dev/null \
  | awk '{print $2}' | sort -u)
[ -n "$CRON_PINGS" ] \
  && ok || bad "no watchdog-ping lines found in cron/*.cron — this section would pass vacuously"

# The hub's own fallback in bin/fleet-status-push.sh (a "local" row in fleet.conf
# means the hub runs the lane itself, and "local" is not a name any box ticks
# under) is HARNESS_HUB_BOX since BH-4080, whose one default is in
# bin/lib/deployment.sh. It has to match what cron/hub.cron actually pings.
HUB_FALLBACK=""
grep -q 'HUB_BOX_NAME:-\$HARNESS_HUB_BOX' "$DIR/bin/fleet-status-push.sh" \
  && HUB_FALLBACK=$(env -i PATH="$PATH" bash -c '. "$1" && printf %s "$HARNESS_HUB_BOX"' _ "$DIR/bin/lib/deployment.sh")
HUB_PING=$(grep -o 'watchdog-ping\.sh[[:space:]]\{1,\}[A-Za-z0-9._-]\{1,\}' "$(rendered_cron hub)" 2>/dev/null | head -1 | awk '{print $2}')
[ -n "$HUB_FALLBACK" ] && [ "$HUB_FALLBACK" = "$HUB_PING" ] \
  && ok || bad "the hub fallback in fleet-status-push.sh ('$HUB_FALLBACK') is not what cron/hub.cron pings ('$HUB_PING')"

# Every ACTIVE fleet.conf row (commented-out rows are parked boxes by design).
# TEST-CHANGE (BH-5651): the rows come from the registry cache under $RH.
ROWS=0
while read -r P; do
  [ -n "$P" ] || continue
  ROWS=$((ROWS+1))
  BOX=$(rcache_run "$RH" "$DIR/bin/box-for.sh" "$P" 2>/dev/null)  # TEST-CHANGE (BH-5651): the registry, not $DIR/fleet.conf
  [ "$BOX" = local ] && BOX="$HUB_FALLBACK"
  if [ -z "$BOX" ]; then
    bad "$P resolves to no box at all — its lane could never be declared"
    continue
  fi
  N=$(printf '%s\n' "$CRON_PINGS" | grep -cxF "$BOX")
  if [ "${N:-0}" -eq 1 ]; then
    ok
  else
    bad "fleet.conf declares $P on '$BOX', but $N cron file(s) ping that name — the lane would page NEVER TICKED forever while an UNDECLARED twin row carried its ticks"
  fi
done <<EOF
$(rcache_run "$RH" "$DIR/bin/fleet-conf.sh" --projects 2>/dev/null)
EOF
[ "$ROWS" -gt 0 ] \
  && ok || bad "no active fleet.conf rows were checked — this section proved nothing"

echo "lane-liveness-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
