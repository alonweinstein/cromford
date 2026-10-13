#!/bin/bash
# tests/fleet-slo-test.sh — the fleet SLO detectors fire ONCE on the way in and
# ONCE on the way out, and measure only what is inside the window.
#
# The case (2026-09-15 12:27Z): a bin hot-patch made context-gate refuse every
# box-side build fleet-wide for 77 minutes. Every layer was working — queues,
# heartbeats, ledger rows — and none of them watched the RATE, so the outage
# read as four unrelated refusal lines in four project logs and no incident.
#
# What this pins, per SLO: the breach, the sample-size floor under it, the
# window that excludes old evidence, exactly one alert while it stays breached,
# and a resolve that names the SAME incident id.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/builds" "$H/state/remote-results/demo" "$H/state/fleet-heartbeat"
cp "$DIR/bin/fleet-slo.sh" "$DIR/bin/result-prefix-ok.sh" "$H/bin/"
# flags/ is gitignored (machine-local), so CI never has flags/slo.conf. Recreate
# the one key test 14 mutates; every other SLO uses the script fallbacks, which
# are the documented defaults.
printf 'SLO_REFUSAL_MIN_LAUNCHES 4\n' > "$H/flags/slo.conf"
# The box list fleet-slo measures against. A box NOT in here is retired, and its
# leftover heartbeat file must not page anyone (2026-09-15: the hub still
# carried files for box-project-3-1 and box-project-10-1).
{ echo "demo-os example-org/demo-os https://x - 2 box-gone"
  echo "other-os example-org/other-os https://y - 3 box-fine"; } > "$H/fleet.conf"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin"/*.sh
: > "$T/alerts.txt"
# The ledger is read GET-only through _jobs_req; the fixture answers with a file.
# lanes_list is the BOX-liveness evidence since BH-1031 (nothing writes
# state/fleet-heartbeat any more), and it answers in bin/jobs-client.sh's TSV
# shape: project, box, state, silence_s, tick_age_s, ... A MISSING fixture is
# the outage case — rc 1, which must read `unknown` and page nobody.
{ printf '_jobs_req() { cat "${JOBS_FIXTURE:-/dev/null}" 2>/dev/null; }\n'
  printf 'lanes_list() { [ -s "${LANES_FIXTURE:-}" ] || return 1; cat "$LANES_FIXTURE"; }\n'
} > "$H/bin/jobs-client.sh"
echo '{"jobs":[]}' > "$T/jobs.json"
lane_row() { # lane_row <project> <box> <state> <tick_age_s>
  printf '%s\t%s\t%s\t-1\t%s\t-\t0\t1800\t-\t1\n' "$1" "$2" "$3" "$4"
}

NOW=$(date +%s)
ago() { date -u -d "@$(( NOW - $1 ))" '+%Y-%m-%d %H:%M:%SZ'; }
run() { ( HARNESS="$H" JOBS_FIXTURE="$T/jobs.json" LANES_FIXTURE="${LANES_FIXTURE:-}" bash "$H/bin/fleet-slo.sh" ); }
alerts() { cat "$T/alerts.txt" 2>/dev/null; }
nfire()  { grep -c "SLO BREACH" "$T/alerts.txt" 2>/dev/null || true; }
nres()   { grep -c "SLO RESOLVED" "$T/alerts.txt" 2>/dev/null || true; }
reset()  { : > "$T/alerts.txt"; : > "$H/logs/ALERTS.log"; scratch_rm "$H/state/slo"; for p in "$H/builds"/*; do scratch_rm "$p"; done; }
# A launch is the context.json every context-gate run writes into the build dir.
launch() { # launch <name> <age-secs> [RESULT first line]
  local d="$H/builds/$1"; mkdir -p "$d"; echo '{}' > "$d/context.json"
  [ -n "${3:-}" ] && printf '%s\n' "$3" > "$d/RESULT"
  touch -d "@$(( NOW - $2 ))" "$d/context.json" "$d/RESULT" 2>/dev/null
}
refuse() { # refuse <n> <age-secs>
  local i; for i in $(seq 1 "$1"); do
    echo "$(ago "$2") [demo-os] BUILD REFUSED — context drift: harness bin disagree with this box's checkout" >> "$H/logs/ALERTS.log"
  done
}

# ── 1. a quiet fleet says nothing ─────────────────────────────────────────
reset
OUT=$(run); RC=$?
[ "$RC" -eq 0 ] && ok || bad "a quiet fleet must exit 0 (rc=$RC out=$OUT)"
[ "$(nfire)" = 0 ] && ok || bad "a quiet fleet must not alert (got: $(alerts))"
[ -s "$H/state/slo/status.json" ] && ok || bad "status.json must be written every run"
[ "$(jq -r '.slos | length' "$H/state/slo/status.json")" = 5 ] \
  && ok || bad "status.json must carry all five SLOs (got: $(cat "$H/state/slo/status.json"))"
[ "$(jq -r '.open_incidents' "$H/state/slo/status.json")" = 0 ] \
  && ok || bad "a quiet fleet has no open incidents"

# ── 2. the refusal storm: every build turned away ─────────────────────────
reset
refuse 8 300
for i in 1 2 3 4 5 6 7 8; do launch "b$i" 300 "PR_CREATED https://x/pull/$i"; done
OUT=$(run); RC=$?
[ "$RC" -eq 1 ] && ok || bad "a breach must exit 1 (rc=$RC out=$OUT)"
[ "$(nfire)" = 1 ] && ok || bad "the breach must fire exactly ONE alert (got $(nfire): $(alerts))"
grep -q -- '--critical' <<<"$(alerts)" && ok || bad "an SLO incident is --critical (got: $(alerts))"
grep -qE 'SLO BREACH \[slo-build_refusal-[0-9]{8}T[0-9]{4}Z\]' <<<"$(alerts)" \
  && ok || bad "the alert must carry a stable incident id (got: $(alerts))"
grep -q '1.00' <<<"$(alerts)" && ok || bad "the alert must carry the measured rate (got: $(alerts))"
ID=$(jq -r .incident "$H/state/slo/build_refusal.open" 2>/dev/null)
[ -n "$ID" ] && ok || bad "the open marker must record the incident id"
[ "$(jq -r '.slos[] | select(.slo=="build_refusal") | .breached' "$H/state/slo/status.json")" = true \
  ] && ok || bad "status.json must mark the breached SLO"

# ── 3. still breached is still ONE incident, not a page per tick ──────────
run >/dev/null; run >/dev/null
[ "$(nfire)" = 1 ] && ok || bad "an open incident must not re-fire (got $(nfire): $(alerts))"
[ "$(jq -r .incident "$H/state/slo/build_refusal.open")" = "$ID" ] \
  && ok || bad "the incident id must stay stable while the incident is open"

# ── 4. it clears itself, once, naming the same incident ──────────────────
: > "$H/logs/ALERTS.log"
run >/dev/null
[ "$(nres)" = 1 ] && ok || bad "clearing must write exactly ONE resolve (got $(nres): $(alerts))"
grep -qF "SLO RESOLVED [$ID]" <<<"$(alerts)" \
  && ok || bad "the resolve must name the incident that was opened (got: $(alerts))"
[ ! -f "$H/state/slo/build_refusal.open" ] && ok || bad "the open marker must be removed once it clears"
run >/dev/null
[ "$(nres)" = 1 ] && ok || bad "a resolved SLO must stay quiet afterwards (got: $(alerts))"

# ── 5. the window: evidence older than it does not count ─────────────────
reset
refuse 8 10800   # 3h ago, window is 60m
for i in 1 2 3 4 5 6 7 8; do launch "b$i" 300 "PR_CREATED https://x/pull/$i"; done
run >/dev/null
[ "$(nfire)" = 0 ] && ok || bad "refusals outside the window must not breach (got: $(alerts))"

# ── 5b. prose that MENTIONS a refusal is not a refusal ───────────────────
# The retraction line an operator wrote on 2026-09-15 quoted the refusal shape,
# and a bare "BUILD REFUSED" match counted the quote as another outage.
reset
for i in $(seq 1 8); do
  echo "$(ago 300) [demo-os] POSTMORTEM — yesterday's build was REFUSED for context drift" >> "$H/logs/ALERTS.log"
done
for i in 1 2 3 4 5 6 7 8; do launch "b$i" 300 "PR_CREATED https://x/pull/$i"; done
run >/dev/null
[ "$(nfire)" = 0 ] && ok || bad "prose about a refusal must not count as one (got: $(alerts))"

# ── 6. the sample-size floor: one bad build is not an outage ─────────────
reset
refuse 2 300
launch b1 300 "PR_CREATED https://x/pull/1"; launch b2 300 "PR_CREATED https://x/pull/2"
run >/dev/null
[ "$(nfire)" = 0 ] && ok || bad "a 2-of-2 sample is under the floor and must not breach (got: $(alerts))"

# ── 7. lane deaths: no RESULT is a max-turns kill ────────────────────────
# Also pins that a REFUSED build is NOT counted as a death — SLO 1 owns it, and
# paging twice for one cause is how an operator learns to skim.
reset
launch d1 7200                                     # died: no RESULT at all
launch d2 7200                                     # died: no RESULT at all
launch d3 7200 "EXECUTE_EMPTY nothing was written" # died: failed outcome
launch d4 7200 "Oops, something went wrong"        # died: not a canonical RESULT
launch a1 7200 "PR_CREATED https://x/pull/9"       # alive
launch a2 7200 "BUILD_REFUSED context drift"       # refused, not dead
launch a3 7200 "PLAN_BLOCKED the thread is ambiguous"  # a real outcome, not dead
run >/dev/null
grep -q 'SLO BREACH \[slo-lane_death-' <<<"$(alerts)" \
  && ok || bad "4 of 7 lanes dead must breach the lane-death SLO (got: $(alerts))"
V=$(jq -r '.slos[] | select(.slo=="lane_death") | .value' "$H/state/slo/status.json")
[ "$V" = "0.57" ] && ok || bad "lane_death must count 4 deaths of 7 lanes, got $V"

# ── 8. a lane that has not settled yet is working, not dead ─────────────
reset
for i in 1 2 3 4 5 6; do launch "n$i" 60; done   # 1 minute old, no RESULT yet
run >/dev/null
[ "$(nfire)" = 0 ] && ok || bad "lanes younger than the settle window are not deaths (got: $(alerts))"

# ── 9. stale running rows come from the ledger, read-only ──────────────
reset
jq -nc '{jobs:[{id:"build-a",age_s:99999},{id:"build-b",age_s:99999},
               {id:"build-c",age_s:99999},{id:"build-d",age_s:60}]}' > "$T/jobs.json"
run >/dev/null
grep -q 'SLO BREACH \[slo-stale_running-' <<<"$(alerts)" \
  && ok || bad "3 rows past the TTL must breach (got: $(alerts))"
[ "$(jq -r '.slos[] | select(.slo=="stale_running") | .value' "$H/state/slo/status.json")" = 3 ] \
  && ok || bad "stale_running must count only rows past the TTL"
grep -q 'build-a' <<<"$(alerts)" && ok || bad "the alert must name the stuck rows (got: $(alerts))"

# ── 10. an unreadable ledger is unknown, and unknown never pages ────────
reset
echo 'not json' > "$T/jobs.json"
run >/dev/null
[ "$(nfire)" = 0 ] && ok || bad "an unreadable ledger must not page (got: $(alerts))"
[ "$(jq -r '.slos[] | select(.slo=="stale_running") | .value' "$H/state/slo/status.json")" = unknown ] \
  && ok || bad "an unreadable ledger reports unknown, never 0"
echo '{"jobs":[]}' > "$T/jobs.json"

# ── 11. boxes whose every lane has gone silent ─────────────────────────
# THE EVIDENCE IS THE ROW (BH-1031). bin/fleet-heartbeat.sh is deleted, so
# state/fleet-heartbeat is written by nothing: reading its mtimes would report a
# permanently silent fleet off files that stopped moving for a reason that has
# nothing to do with the boxes. A box is lost when EVERY lane fleet.conf routes
# to it is stale — one dead lane is a lane problem, and jobs-watchdog names it.
reset
{ lane_row demo-os box-gone stale 7200
  lane_row other-os box-fine live 120; } > "$T/lanes.tsv"
LANES_FIXTURE="$T/lanes.tsv" run >/dev/null
grep -q 'SLO BREACH \[slo-box_silent-' <<<"$(alerts)" \
  && ok || bad "a box whose every lane is stale must breach (got: $(alerts))"
grep -q 'box-gone' <<<"$(alerts)" && ok || bad "the alert must name the silent box"
grep -q 'box-fine' <<<"$(alerts)" && bad "a box with a live lane must not be named" || ok
[ "$(jq -r '.slos[] | select(.slo=="box_silent") | .value' "$H/state/slo/status.json")" = 1 ] \
  && ok || bad "box_silent must count exactly the one silent box"

# A MIXED BOX IS NOT A SILENT BOX. One lane dying on a box whose other lanes are
# ticking is a lane incident with its own detector; calling the machine silent
# would page the wrong thing and hide the right one.
reset
{ lane_row demo-os box-gone stale 7200
  lane_row demo2-os box-gone live 120
  lane_row other-os box-fine live 120; } > "$T/lanes.tsv"
LANES_FIXTURE="$T/lanes.tsv" run >/dev/null
[ "$(nfire)" = 0 ] && ok || bad "a box with one live lane must not page as silent (got: $(alerts))"
[ "$(jq -r '.slos[] | select(.slo=="box_silent") | .value' "$H/state/slo/status.json")" = 0 ] \
  && ok || bad "a mixed box counts as 0 silent, not unknown"

# ...and a box every lane of which is stale but only BRIEFLY is below the box
# threshold: SLO_BOX_SILENT_MIN is a longer bar than the per-lane one on
# purpose, so the box SLO can never fire before the lane detector does.
reset
{ lane_row demo-os box-gone stale 600
  lane_row other-os box-fine live 120; } > "$T/lanes.tsv"
LANES_FIXTURE="$T/lanes.tsv" run >/dev/null
[ "$(nfire)" = 0 ] && ok || bad "a lane stale for 10m must not yet make the BOX silent (got: $(alerts))"

# A RETIRED box leaves rows behind. Paging about a machine that no longer
# exists, every ten minutes, is how a channel gets muted.
reset
{ lane_row demo-os box-retired stale 7200
  lane_row other-os box-fine live 120; } > "$T/lanes.tsv"
LANES_FIXTURE="$T/lanes.tsv" run >/dev/null
[ "$(nfire)" = 0 ] && ok || bad "a box fleet.conf no longer names must not page (got: $(alerts))"

# THE LEDGER COULD NOT ANSWER -> unknown, and unknown fires nothing. There is no
# file fallback any more: state/fleet-heartbeat is stale evidence nothing
# rewrites, and a detector that reports from it looks like evidence while saying
# something that has not been true since the lane was deleted.
reset
touch -d "@$(( NOW - 7200 ))" "$H/state/fleet-heartbeat/alerts-box-gone" 2>/dev/null
LANES_FIXTURE="" run >/dev/null
[ "$(nfire)" = 0 ] && ok || bad "an unreadable lanes ledger must not page (got: $(alerts))"
[ "$(jq -r '.slos[] | select(.slo=="box_silent") | .value' "$H/state/slo/status.json")" = unknown ] \
  && ok || bad "an unreadable lanes ledger reports unknown, never 0"
rm -f "$H/state/fleet-heartbeat"/alerts-*
! grep -q 'state/fleet-heartbeat' <<<"$(sed -n '/SLO 4/,/SLO 5/p' "$H/bin/fleet-slo.sh" | grep -v '^#')" \
  && ok || bad "box_silent must not read state/fleet-heartbeat: nothing writes it since BH-1031"

# No readable fleet.conf: we cannot tell a ghost from a box, so say so.
reset
{ lane_row demo-os box-gone stale 7200; } > "$T/lanes.tsv"
mv "$H/fleet.conf" "$T/fleet.conf.hidden"
LANES_FIXTURE="$T/lanes.tsv" run >/dev/null
[ "$(nfire)" = 0 ] && ok || bad "no fleet.conf must not page (got: $(alerts))"
[ "$(jq -r '.slos[] | select(.slo=="box_silent") | .value' "$H/state/slo/status.json")" = unknown ] \
  && ok || bad "no fleet.conf reports unknown, never 0"
mv "$T/fleet.conf.hidden" "$H/fleet.conf"

# ── 12. main-red markers are READ, never written ──────────────────────
reset
touch "$H/flags/main-red-project-5"
run >/dev/null
grep -q 'SLO BREACH \[slo-main_red-' <<<"$(alerts)" \
  && ok || bad "a main-red marker must breach (got: $(alerts))"
grep -q 'project-5' <<<"$(alerts)" && ok || bad "the alert must name the red branch"
[ "$(ls -1 "$H/flags"/main-red-* | wc -l)" = 1 ] \
  && ok || bad "fleet-slo must never create a main-red marker of its own"
rm -f "$H/flags/main-red-project-5"
run >/dev/null
[ ! -f "$H/state/slo/main_red.open" ] && ok || bad "removing the marker must resolve the incident"

# ── 13. the kill flag stops it dead ───────────────────────────────────
reset
refuse 8 300
for i in 1 2 3 4; do launch "b$i" 300; done
touch "$H/flags/fleet-slo-off"
OUT=$(run); RC=$?
[ "$RC" -eq 0 ] && [ "$(nfire)" = 0 ] && ok || bad "flags/fleet-slo-off must stop every detector (rc=$RC out=$OUT)"
rm -f "$H/flags/fleet-slo-off"

# ── 14. thresholds come from flags/slo.conf, not from the script ──────
reset
refuse 2 300
launch b1 300; launch b2 300
sed -i 's/^SLO_REFUSAL_MIN_LAUNCHES .*/SLO_REFUSAL_MIN_LAUNCHES 2/' "$H/flags/slo.conf"
run >/dev/null
[ "$(nfire)" = 1 ] && ok || bad "lowering the floor in flags/slo.conf must change the verdict (got: $(alerts))"
printf 'SLO_REFUSAL_MIN_LAUNCHES 4\n' > "$H/flags/slo.conf"

echo "fleet-slo-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
