#!/bin/bash
# tests/queue-claim-release-test.sh — a build_queue row claimed by a machine
# that died is handed back, so the ticket can be built again.
#
# THE GAP THIS CLOSES. A row is CLAIMED when bin/fly-dispatch.sh materialises it
# and CLOSED when bin/fly-pool.sh reaps the result or bin/run-build.sh exits —
# both of which need something to still be alive to do the closing. A machine
# lost between the two leaves the row `claimed` FOREVER, and because the enqueue
# guard treats `claimed` as "already accounted for", that ticket can never be
# queued again on the DB path. Silent, permanent, and invisible to every other
# detector: no job row ages, because the job died in the same instant.
#
# WHY DRIVEN. The claim being released is one thing; the claim NOT being
# released early, and nothing being LAUNCHED, are the two that would cost money
# if they were wrong. A grep can see none of them.
# Run from anywhere: tests/queue-claim-release-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/h/bin" "$T/h/logs" "$T/h/locks" "$T/h/flags" "$T/h/state" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
: > "$T/h/env-placeholder"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
# If the watchdog ever LAUNCHES anything, these record it. The doctrine is that
# it asks for a verdict and writes it down; it never runs work.
for W in run-build.sh run-triage.sh fly-dispatch.sh fly-pool.sh; do
  printf '#!/bin/bash\necho "LAUNCHED %s $*" >> "$LAUNCH_SINK"\nexit 0\n' "$W" > "$T/h/bin/$W"
  chmod +x "$T/h/bin/$W"
done

cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in --data-binary) BODY="$2"; shift 2 ;; -X) M="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
case "${CURL_MODE:-stale}" in
  down) exit 7 ;;
  none)
    case "$URL" in
      */api/queue\?*) printf '{"queue":[]}\n200\n' ;;
      *)              printf '{"jobs":[],"lanes":[]}\n200\n' ;;
    esac ;;
  *)
    case "$URL" in
      # The worker applies stale_min itself (server clock); the stub answers the
      # query the watchdog actually sends and nothing else, so a watchdog that
      # forgot the parameter would get no rows and the test would go red.
      */api/queue\?*stale_min=*) printf '{"queue":[{"project":"project-3","ticket_key":"TK-9","status":"claimed","claimed_by":"fly-machine-7","claimed_at":"2026-09-10T01:00:00Z","target":"fly","attempt":0}]}\n200\n' ;;
      */api/queue\?*)            printf '{"queue":[]}\n200\n' ;;
      *)                         printf '{"jobs":[],"lanes":[]}\n200\n' ;;
    esac ;;
esac
STUB
chmod +x "$T/fakebin/curl"

watchdog() { # watchdog <curl-mode>
  : > "$T/req.txt"; : > "$T/launch.txt"; : > "$T/h/logs/ALERTS.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 \
           CURL_MODE="$1" REQ_SINK="$T/req.txt" LAUNCH_SINK="$T/launch.txt"
    bash "$DIR/bin/jobs-watchdog.sh" >/dev/null 2>&1 )
}
body_of() {
  grep -m1 "^$1 https://jobs.invalid$2 " "$T/req.txt" \
    | awk '{ $1=""; $2=""; sub(/^ +/, ""); print }'
}

# ══ 1. A CLAIM NOBODY CLOSED IS HANDED BACK ═════════════════════════════════
watchdog stale
grep -q 'stale_min=' "$T/req.txt" \
  && ok || bad "the watchdog must ASK for stale claims — the threshold is its policy, the clock is the server's: $(cat "$T/req.txt")"
B=$(body_of PATCH /api/queue)
[ "$(jq -r .status <<<"$B")" = queued ] \
  && ok || bad "a stale claim must go back to QUEUED, or the ticket can never be built again. Got: $B"
[ "$(jq -r .key <<<"$B")" = TK-9 ] && ok || bad "the release must name the key, got: $B"
[ "$(jq -r .project <<<"$B")" = project-3 ] && ok || bad "the release must name the project, got: $B"
grep -q 'fly-machine-7' <<<"$B" \
  && ok || bad "the reason must name the claimant that vanished — that is what a human needs to know: $B"

# The page says what happened AND what did not, because "the watchdog released
# something" reads like "the watchdog started something" unless it is spelled out.
grep -q 'QUEUE CLAIM RELEASED' "$T/h/logs/ALERTS.log" \
  && ok || bad "a released claim must page once: $(cat "$T/h/logs/ALERTS.log")"
grep -q 'No build was started' "$T/h/logs/ALERTS.log" \
  && ok || bad "the alert must say no build was started, or it reads as a relaunch"

# ══ 2. IT STILL EXECUTES NOTHING ════════════════════════════════════════════
# The standing rule for this script since phase 3. Releasing a row is a state
# write, not a launch: the lane's own next tick picks the work up through the
# normal claim path, which is what keeps ONE place where work can start.
[ ! -s "$T/launch.txt" ] \
  && ok || bad "the watchdog must launch NOTHING: $(cat "$T/launch.txt")"

# ══ 3. FAIL OPEN ════════════════════════════════════════════════════════════
watchdog none
grep -q 'PATCH https://jobs.invalid/api/queue ' "$T/req.txt" \
  && bad "with no stale rows nothing may be released" || ok
watchdog down
grep -q 'PATCH https://jobs.invalid/api/queue ' "$T/req.txt" \
  && bad "with the worker down nothing may be released — an outage is not evidence a machine died" || ok
grep -q 'QUEUE CLAIM RELEASED' "$T/h/logs/ALERTS.log" 2>/dev/null \
  && bad "an outage must not page as a released claim" || ok

# ══ 4. THE THRESHOLD IS GENEROUS ON PURPOSE ═════════════════════════════════
# Releasing early re-queues work that is still running; releasing late only
# delays a ticket nobody is building. The default has to sit far beyond an
# honest build (~20-40m), and it is an env knob so an operator can move it.
grep -q 'JOBS_QUEUE_CLAIM_MIN:-360' "$DIR/bin/jobs-watchdog.sh" \
  && ok || bad "the stale-claim threshold must default far beyond a real build and be overridable"

# ══ 5. NO SECRETS ═══════════════════════════════════════════════════════════
grep -rq test-secret "$T/h/logs" 2>/dev/null && bad "HARNESS_SECRET leaked into a log" || ok

echo "queue-claim-release-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
