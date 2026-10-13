#!/bin/bash
# tests/cost-local-brake.bh-2599-test.sh — BH-2599: the cost brake reaches the
# OWNING box during a harness-jobs outage, with no ssh, and the hub never keeps
# a pause file it could not publish.
#
# WHAT IS DRIVEN.
#   H — bin/pipeline-health.sh's `cost budget` block, extracted verbatim by its
#       own markers (the routing-writers/box-head pattern), run with the REAL
#       bin/jobs-client.sh against a curl shim.
#   B — the real bin/cost-local-brake.sh, copied into a scratch HARNESS and run
#       the way cron runs it (`$HARNESS/bin/cost-local-brake.sh`, no args), with
#       the real jobs client, lane gate, hub-box, box-name, fleet-conf, box-for
#       and page-critical beside it. curl, gh, ssh and sleep are PATH shims that
#       record every call. Every assertion is on an artifact: a file under
#       flags/ or state/, a line in req.log / calls.* / ALERTS.log.
#   V — cost_local_verdict, the pure half, by sourcing the script (main guarded).
#
# CASES
#   (BH-5526: the breaker writes spend-hold-<p>, the hold of new builds, where
#   it used to write the human pause paused-<p>; every case below follows it.)
#   H1 hub, worker down, 3x budget: costhaltfail pages, NO flags/spend-hold-x left on
#      the hub; a second cost check pages costhaltfail again (not `already`)
#   H2 mutation: the rollback line stripped -> the hub file is left (H1 goes red)
#   H3 hub, worker up: file, PUT and costhalt page (not regressed)
#   B1 box-x, worker down, $300 in 24h for 1 merged PR at $10/PR: spend-hold-x on
#      box-x, PUT attempted, .pending ends "(cost autohalt)", costlocalhalt page,
#      no ssh; run-triage's own pause check does NOT skip the project
#   B2 zero-merge 7d: paused, reason ends "(zero-merge breaker)"
#   B3 worker UP (inactive row), same numbers: no file, no page, no gh call
#   B4 worker answers 404 (no row): no file
#   B5 worker down, gh fails / answers a 422 body: no file, costlocalnoeval
#   B6 all spend on stage ideate: no gh call, no file
#   B7 24h zero-merge with a merge this week: no file (a merge STOP)
#   B8 project y owned by box-y over budget, run on box-x: untouched
#   B9 flags/cost-autohalt-off: no file   B10 settings COST_AUTOHALT=0: no file
#   B11 recovery: PUT active=1 with the pending reason, .pending gone, file stays
#   B12 recovery after an operator rm: no PUT, .pending gone
#   B13 re-arm: a stamp 1h old, file removed, over budget: no new pause
#   V1-V8 cost_local_verdict pure cases
#   M1 verdict forced "ok" -> B1 red     M2 outage gate removed -> B3 red
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/cost-local-brake.bh-2599-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
export T
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
for c in jq python3 awk flock; do command -v "$c" >/dev/null || { echo "$c missing — skipping"; exit 0; }; done

NOW=$(date +%s)
iso() { date -u -d "@$(( NOW - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }   # iso <seconds-ago>
FAKE="$T/fakebin"; mkdir -p "$FAKE"

# --- curl: the jobs worker. CURL_MODE: down | up (inactive row) | norow (404)
# | putfail. PUT /api/flags answers 200 unless down/putfail.
cat > "$FAKE/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2;;
    --data-binary) BODY="$2"; case "$BODY" in @*) BODY=$(cat "${BODY#@}");; esac; shift 2;;
    *) shift;;
  esac
done
printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$T/req.log"
[ "${CURL_MODE:-up}" = down ] && exit 7
case "$METHOD $URL" in
  "GET "*/api/flags/spend-hold-*|"GET "*/api/flags/paused-*)
    [ "${CURL_MODE:-up}" = norow ] && { printf '{"error":"not found"}\n404\n'; exit 0; }
    printf '{"flag":{"name":"x","active":0,"updated_at":"2020-01-01T00:00:00Z"}}\n200\n' ;;
  "PUT "*/api/flags)
    [ "${CURL_MODE:-up}" = putfail ] && { printf '{"error":"boom"}\n500\n'; exit 0; }
    printf '{"flag":{"updated_at":"2020-01-01T00:00:02Z"}}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
CURL
# --- gh: `gh api search/issues?q=...merged:>=<cut>`. The 24h cut carries a T,
# the 7d cut is a bare date. GH_MODE: ok | fail | 422.
cat > "$FAKE/gh" <<'GH'
#!/bin/bash
printf '%s\n' "$*" >> "$T/calls.gh"
case "${GH_MODE:-ok}" in
  fail) echo "HTTP 502" >&2; exit 1 ;;
  422)  echo '{"message":"Validation Failed","errors":[]}'; exit 0 ;;
esac
case "$*" in
  *merged:\>=*T*) echo "{\"total_count\":${GH_M24:-0}}" ;;
  *)              echo "{\"total_count\":${GH_M7:-0}}" ;;
esac
GH
cat > "$FAKE/ssh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$T/calls.ssh"
exit 0
SH
printf '#!/bin/sh\nexit 0\n' > "$FAKE/sleep"
chmod +x "$FAKE"/*
export PATH="$FAKE:$PATH"
unset BOX_NAME CURL_MODE GH_MODE GH_M24 GH_M7 NOW_OVERRIDE TELEGRAM_BOT_TOKEN COST_AUTOHALT JOBS_URL HARNESS_JOBS_URL LANE_REGISTRY
sinks_reset() { rm -f "$T/req.log" "$T/calls.gh" "$T/calls.ssh"; }

jobs_into() { # jobs_into <harness> — the real client beside a harness's bin/
  mkdir -p "$1/bin/lib/jobs" "$1/env" "$1/logs" "$1/flags" "$1/state"
  cp "$DIR/bin/jobs-client.sh" "$1/bin/"
  cp "$DIR/bin/lib/env-path.sh" "$1/bin/lib/"
  cp "$DIR"/bin/lib/jobs/*.sh "$1/bin/lib/jobs/"
  printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.invalid\nJOBS_RETRIES=0\n' > "$1/env/global.env"
}

# ════════════════════════════════════════════════════════════════════════════
# H. The hub: a failed halt leaves no pause file behind
# ════════════════════════════════════════════════════════════════════════════
PH="$DIR/bin/pipeline-health.sh"
extract_cost() { awk '/^# >>> cost budget/{f=1;next} /^# <<< cost budget/{exit} f' "$1" > "$2"; }
extract_cost "$PH" "$T/cost.sh"
[ -s "$T/cost.sh" ] && ok || bad "could not extract the cost budget block — markers missing?"

HB="$T/hub"
hub_fixture() {
  scratch_rm "$HB"; jobs_into "$HB"; mkdir -p "$HB/bin/lib" "$HB/state/cost"
  printf '{"projects":{"x":{"delivery_cost_24h":30,"merged_prs_24h":1,"cost_7d":30,"product_7d":0,"merged_prs_7d":1,"merged_prs_status":"ok"}}}\n' > "$HB/state/cost/summary.json"
  printf 'cost_budget_for() { echo "10 1"; }\ncost_budget_source() { echo fixture; }\n' > "$HB/bin/lib/cost-budget.sh"
  echo 0 > "$HB/state/costbreaker.stamp"
  printf 'x Acme/x - - 1 box-x\n' > "$HB/fleet.conf"
  cp "$DIR/bin/fleet-conf.sh" "$HB/bin/"
}
drive_hub() { # drive_hub <block-file>  (CURL_MODE from the caller)
  ( cd "$T" && export H="$HB" HARNESS="$HB" PROJECTS=x NOW="$NOW" HENV="$HB/env" FLEET_CONF="$HB/fleet.conf" \
                       JOBS_URL=https://jobs.invalid HARNESS_SECRET=test-secret JOBS_RETRIES=0
    bash -c 'STAMP() { date -u "+%Y-%m-%d %H:%M:%SZ"; }
             alert() { printf "%s\n" "$*" >> "$H/logs/ALERTS.log"; }
             . "$H/bin/jobs-client.sh" || exit 1
             . "$1"' _ "$1" ) >/dev/null 2>&1
}

# H1 worker down
sinks_reset; hub_fixture
CURL_MODE=down drive_hub "$T/cost.sh"
grep -q 'costhaltfail:x' "$HB/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "H1: worker down must page costhaltfail:x ($(cat "$HB/logs/ALERTS.log" 2>/dev/null))"
[ ! -e "$HB/flags/spend-hold-x" ] && ok \
  || bad "H1: a halt whose row could not be written must not leave flags/spend-hold-x on the hub"
[ ! -e "$HB/state/costhalt/x" ] && ok || bad "H1: a failed halt must not stamp state/costhalt/x"
# the next cost check (the 1800 s stamp reset): it must try again and page again
: > "$HB/logs/ALERTS.log"; echo 0 > "$HB/state/costbreaker.stamp"
CURL_MODE=down drive_hub "$T/cost.sh"
grep -q 'costhaltfail:x' "$HB/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "H1: the SECOND check must page costhaltfail:x again, not read its own file as 'already' ($(cat "$HB/logs/ALERTS.log"))"
[ ! -e "$HB/flags/spend-hold-x" ] && ok || bad "H1: still no hub file after the second check"
[ ! -s "$T/calls.ssh" ] && ok || bad "H1: no ssh ($(cat "$T/calls.ssh"))"

# H2 mutation: strip the rollback, H1's file assertion must go red
grep -v 'rm -f "$H/flags/$CB_HOLD_PREFIX$p"' "$PH" > "$T/ph-mut.sh"
! cmp -s "$PH" "$T/ph-mut.sh" && ok || bad "H2: pipeline-health has no rollback line to strip (rm -f \"\$H/flags/\$CB_HOLD_PREFIX\$p\")"
extract_cost "$T/ph-mut.sh" "$T/cost-mut.sh"
sinks_reset; hub_fixture
CURL_MODE=down drive_hub "$T/cost-mut.sh"
[ -e "$HB/flags/spend-hold-x" ] && ok || bad "H2: with the rollback stripped the hub file must be left (the mutation must be visible)"

# H3 worker up: the halt lands as before
sinks_reset; hub_fixture
CURL_MODE=up drive_hub "$T/cost.sh"
[ -e "$HB/flags/spend-hold-x" ] && ok || bad "H3: a landed halt keeps flags/spend-hold-x"
grep -q 'PUT https://jobs.invalid/api/flags {"name":"spend-hold-x","active":1,' "$T/req.log" 2>/dev/null && ok \
  || bad "H3: the halt must PUT spend-hold-x active=1 ($(cat "$T/req.log" 2>/dev/null))"
grep -q 'costhalt:x' "$HB/logs/ALERTS.log" && ! grep -q 'costhaltfail:x' "$HB/logs/ALERTS.log" && ok \
  || bad "H3: a landed halt pages costhalt, not costhaltfail ($(cat "$HB/logs/ALERTS.log"))"

# ════════════════════════════════════════════════════════════════════════════
# B. The owning box brakes itself
# ════════════════════════════════════════════════════════════════════════════
C="$T/box"
HDR='ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note,lane_id'
row() { # row <seconds-ago> <project> <stage> <cost_usd>  — agent-call.sh's column order
  printf '%s,box-x,%s,%s,claude,claude-opus-5-5,0,300,10,2000,90000,4000,%s,metered,abc123,a@b.c,sess-1,transcript,%s,X-1,job-1,,run-1,"cache_ttl=1h, retried",\n' \
    "$(iso "$1")" "$2" "$3" "$4" "$4" >> "$C/logs/cost.csv"
}
box_fixture() {
  scratch_rm "$C"; jobs_into "$C"
  cp "$DIR/bin/cost-local-brake.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$DIR/bin/box-name.sh" "$C/bin/"
  cp "$DIR/bin/lib/hub-box.sh" "$DIR/bin/lib/page-critical.sh" "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/lane-switch.sh" "$C/bin/lib/"
  printf 'cost_budget_for() { cat "$HARNESS/budget" 2>/dev/null || echo "10 1"; }\ncost_budget_source() { echo fixture; }\n' > "$C/bin/lib/cost-budget.sh"
  printf 'x Acme/x - - 1 box-x\ny Acme/y - - 2 box-y\n' > "$C/fleet.conf"
  echo box-x > "$C/state/box-name"
  echo "$HDR" > "$C/logs/cost.csv"
}
run_brake() { # run_brake <harness> [script]  (CURL_MODE, GH_* from the caller)
  ( cd "$T" && env -u NOW HARNESS="$1" "${2:-$1/bin/cost-local-brake.sh}" ) >"$T/brake.out" 2>&1
  echo $? > "$T/brake.rc"
}
paged() { grep -q "$1" "$C/logs/ALERTS.log" 2>/dev/null; }
# B1's numbers: $300 delivery spend in 24h (plus unpriced, product and other
# projects' rows that must not count), 1 merged PR, $10/PR budget, 2x multiple.
b1_rows() { row 3600 x execute 200.00; row 7200 x review 100.00; row 600 x execute ""; row 900 x ideate 50; row 1200 y execute 999; }

# B1
sinks_reset; box_fixture; b1_rows
CURL_MODE=down GH_M24=1 GH_M7=1 run_brake "$C"
[ "$(cat "$T/brake.rc")" = 0 ] && ok || bad "B1: the lane exits 0 ($(cat "$T/brake.out"))"
[ -e "$C/flags/spend-hold-x" ] && ok || bad "B1: box-x must pause x itself during the outage (flags: $(ls "$C/flags"); out: $(cat "$T/brake.out"))"
grep -q 'PUT https://jobs.invalid/api/flags {"name":"spend-hold-x","active":1,' "$T/req.log" 2>/dev/null && ok \
  || bad "B1: the pause must be attempted as a row (req.log: $(cat "$T/req.log" 2>/dev/null))"
PEND=$(cat "$C/state/cost-local-brake/x.pending" 2>/dev/null)
case "$PEND" in *'(cost autohalt)') ok ;; *) bad "B1: .pending must hold the reason, ending '(cost autohalt)' (got: '$PEND')" ;; esac
grep -q '300.00/PR over 24h' <<<"$PEND" && ok || bad "B1: the reason must carry the rate and window (got: '$PEND')"
paged 'costlocalhalt:x' && ok || bad "B1: the lane must page costlocalhalt:x ($(cat "$C/logs/ALERTS.log" 2>/dev/null))"
grep 'costlocalhalt:x' "$C/logs/ALERTS.log" 2>/dev/null | grep -q 'not written yet' && ok \
  || bad "B1: with the PUT failed the page must say the row is not written yet"
[ -s "$C/state/cost-local-brake/x" ] && ok || bad "B1: the local halt must stamp state/cost-local-brake/x"
[ ! -e "$C/flags/spend-hold-y" ] && ok || bad "B1: y is not box-x's project"
[ ! -s "$T/calls.ssh" ] && ok || bad "B1: no ssh ($(cat "$T/calls.ssh"))"
grep -q 'search/issues?q=repo:Acme/x+type:pr+' "$T/calls.gh" 2>/dev/null && ok || bad "B1: merged counts come from the rollup's search ($(cat "$T/calls.gh" 2>/dev/null))"
# run-triage's own pause check (bin/run-triage.sh), verbatim from the file.
# BH-5526: the brake holds new builds only, so triage keeps running on box-x
# (its results sweep closes out finished builds); the launch gate refuses the
# new build (tests/autohalt-boundary.bh-5526-test.sh A5).
awk 'index($0, "flag_active \"paused-$PROJECT\"") {f=1} f{print} f&&/^fi$/{exit}' "$DIR/bin/run-triage.sh" > "$T/rt-pause.sh"
if [ -s "$T/rt-pause.sh" ] && grep -q 'paused-\$PROJECT' "$T/rt-pause.sh"; then
  # TEST-CHANGE (BH-4153 on BH-5526, the operator 2026-10-09): paused-x is a
  # harness_flags row, and with the worker down and nothing cached it reads as
  # ON (a stop switch fails closed). The box's last good answer said paused-x
  # was cleared, so the pause check reads OFF from the cache, and the case
  # still proves what it is for: the cost hold alone does not skip triage.
  mkdir -p "$C/state/flags-cache/fleet"
  printf '%s\n' '{"on":false,"value":null,"set_at":"2026-09-19T01:00:00Z","cleared_at":"2026-09-19T01:00:00Z","src":"db","stamp":1789779600}' \
    > "$C/state/flags-cache/fleet/paused-x"
  ( export HARNESS="$C" PROJECT=x STAMP=now LOG="$T/rt.log" CURL_MODE=down
    bash -c 'LANE_TICK() { echo "tick $1" >> "$T/rt.ticks"; }
             set -a; . "$HARNESS/env/global.env"; set +a; . "$HARNESS/bin/jobs-client.sh"
             . "$1"; echo RAN_ON' _ "$T/rt-pause.sh" ) > "$T/rt.out" 2>&1
  grep -q RAN_ON "$T/rt.out" && ! grep -q 'paused via console, skipping' "$T/rt.log" 2>/dev/null && ok \
    || bad "B1: run-triage's pause check on box-x must NOT skip x under a cost hold ($(cat "$T/rt.out" "$T/rt.log" 2>/dev/null))"
else
  bad "B1: could not extract run-triage's pause check (bin/run-triage.sh)"
fi

# B2 zero-merge 7d: $450 three days ago, nothing merged
sinks_reset; box_fixture; row 259200 x execute 450
CURL_MODE=down GH_M24=0 GH_M7=0 run_brake "$C"
[ -e "$C/flags/spend-hold-x" ] && ok || bad "B2: zero-merge 7d must pause x ($(cat "$T/brake.out"))"
PEND=$(cat "$C/state/cost-local-brake/x.pending" 2>/dev/null)
case "$PEND" in *'(zero-merge breaker)') ok ;; *) bad "B2: reason must end '(zero-merge breaker)' (got: '$PEND')" ;; esac

# B3 worker up
sinks_reset; box_fixture; b1_rows
CURL_MODE=up GH_M24=1 GH_M7=1 run_brake "$C"
[ ! -e "$C/flags/spend-hold-x" ] && ok || bad "B3: worker up means the hub judges; no local pause"
! paged costlocalhalt && [ ! -e "$T/calls.gh" ] && ok || bad "B3: worker up: no page, no gh call ($(cat "$T/calls.gh" 2>/dev/null))"
grep -q 'GET https://jobs.invalid/api/flags/spend-hold-x' "$T/req.log" 2>/dev/null && ok || bad "B3: the lane must ask the worker about spend-hold-x"

# B4 no row
sinks_reset; box_fixture; b1_rows
CURL_MODE=norow GH_M24=1 GH_M7=1 run_brake "$C"
[ ! -e "$C/flags/spend-hold-x" ] && [ ! -e "$T/calls.gh" ] && ok || bad "B4: a 404 is an answer, not an outage; no local pause"

# B5 merged count unknown
for m in fail 422; do
  sinks_reset; box_fixture; b1_rows
  CURL_MODE=down GH_MODE=$m run_brake "$C"
  [ ! -e "$C/flags/spend-hold-x" ] && ok || bad "B5($m): an unknown merged count must never pause"
  paged 'costlocalnoeval:x' && ok || bad "B5($m): an unknown count alerts costlocalnoeval:x ($(cat "$C/logs/ALERTS.log" 2>/dev/null))"
  ! paged costlocalhalt && ok || bad "B5($m): no halt page"
done

# B6 product spend only
sinks_reset; box_fixture; row 3600 x ideate 900; row 3600 x prd 900
CURL_MODE=down GH_M24=0 GH_M7=0 run_brake "$C"
[ ! -e "$C/flags/spend-hold-x" ] && [ ! -e "$T/calls.gh" ] && ok || bad "B6: product-stage spend is not delivery spend; no gh call, no pause"

# B7 24h zero-merge, but merged this week: a merge STOP, never a pause
sinks_reset; box_fixture; echo "400 1" > "$C/budget"; row 3600 x execute 350
CURL_MODE=down GH_M24=0 GH_M7=1 run_brake "$C"
[ ! -e "$C/flags/spend-hold-x" ] && ok || bad "B7: 24h zero-merge with a merge this week must not pause"
[ -e "$T/calls.gh" ] && ok || bad "B7: fixture — the numbers must reach the verdict (gh asked)"

# B8 another box's project
sinks_reset; box_fixture; row 3600 y execute 999
CURL_MODE=down GH_M24=0 GH_M7=0 run_brake "$C"
[ ! -e "$C/flags/spend-hold-y" ] && [ ! -e "$T/calls.gh" ] && ok || bad "B8: y is owned by box-y; box-x must not judge it"

# B9 / B10 kill switches
sinks_reset; box_fixture; b1_rows; : > "$C/flags/cost-autohalt-off"
CURL_MODE=down GH_M24=1 GH_M7=1 run_brake "$C"
[ ! -e "$C/flags/spend-hold-x" ] && ok || bad "B9: flags/cost-autohalt-off must stop the local brake"
sinks_reset; box_fixture; b1_rows
printf '{"fetched_at":%s,"values":{"lane.pipeline-health.cost_autohalt":"0"}}\n' "$NOW" > "$C/state/settings-cache.json"
CURL_MODE=down GH_M24=1 GH_M7=1 run_brake "$C"
[ ! -e "$C/flags/spend-hold-x" ] && ok || bad "B10: the settings row lane.pipeline-health.cost_autohalt=0 must stop the local brake"
# B10 control: the same cache without the row does pause (the row, not the cache, stopped it)
sinks_reset; box_fixture; b1_rows
printf '{"fetched_at":%s,"values":{}}\n' "$NOW" > "$C/state/settings-cache.json"
CURL_MODE=down GH_M24=1 GH_M7=1 run_brake "$C"
[ -e "$C/flags/spend-hold-x" ] && ok || bad "B10 control: without the row the brake must pause"

# B11 recovery publishes the pending pause
sinks_reset; box_fixture; b1_rows
CURL_MODE=down GH_M24=1 GH_M7=1 run_brake "$C"
PEND=$(cat "$C/state/cost-local-brake/x.pending" 2>/dev/null)
sinks_reset
CURL_MODE=up run_brake "$C"
grep -F "PUT https://jobs.invalid/api/flags $(jq -nc --arg r "$PEND" '{name:"spend-hold-x",active:1,actor:"box-x",reason:$r}')" "$T/req.log" >/dev/null 2>&1 && ok \
  || bad "B11: recovery must PUT spend-hold-x active=1 with the pending reason (req.log: $(cat "$T/req.log" 2>/dev/null))"
[ ! -e "$C/state/cost-local-brake/x.pending" ] && [ -e "$C/flags/spend-hold-x" ] && ok \
  || bad "B11: after a published row the marker goes and the file stays"
[ ! -e "$T/calls.gh" ] && ok || bad "B11: recovery takes no verdict"
# B11b a refused publish keeps the marker for the next tick
sinks_reset; box_fixture; b1_rows
CURL_MODE=down GH_M24=1 GH_M7=1 run_brake "$C"
CURL_MODE=putfail run_brake "$C"
[ -s "$C/state/cost-local-brake/x.pending" ] && [ -e "$C/flags/spend-hold-x" ] && ok \
  || bad "B11b: a refused publish must keep .pending (never recorded as published)"

# B12 the operator removed the file during the outage
sinks_reset; box_fixture; b1_rows
CURL_MODE=down GH_M24=1 GH_M7=1 run_brake "$C"
rm -f "$C/flags/spend-hold-x"; sinks_reset
CURL_MODE=up run_brake "$C"
! grep -q 'PUT https://jobs.invalid/api/flags' "$T/req.log" 2>/dev/null && ok || bad "B12: a resumed box publishes nothing ($(cat "$T/req.log"))"
[ ! -e "$C/state/cost-local-brake/x.pending" ] && [ ! -e "$C/flags/spend-hold-x" ] && ok || bad "B12: the marker goes, the file stays gone"

# B13 re-arm: halted 1h ago, the operator resumed, still over budget
sinks_reset; box_fixture; b1_rows
mkdir -p "$C/state/cost-local-brake"; echo $(( NOW - 3600 )) > "$C/state/cost-local-brake/x"
CURL_MODE=down GH_M24=1 GH_M7=1 run_brake "$C"
[ ! -e "$C/flags/spend-hold-x" ] && ok || bad "B13: inside the re-arm window the brake must not pause again"

# ════════════════════════════════════════════════════════════════════════════
# V. cost_local_verdict — S24 S7 M24 M7 BUD MIN MULT Z24 Z7 ZMIN HALT_AGE
# ════════════════════════════════════════════════════════════════════════════
V() { bash -c '. "$1" || exit 9; shift; cost_local_verdict "$@"' _ "$DIR/bin/cost-local-brake.sh" "$@" 2>&1; }
v1=$(V 300 300 1 1 10 1 2 300 400 1 "");   [ "${v1%%$'\t'*}" = rate ] && grep -q $'\t24h\t' <<<"$v1" && ok || bad "V1: 24h rate trip (got: $v1)"
v2=$(V 30 300 0 2 10 1 2 300 400 1 "");    [ "${v2%%$'\t'*}" = rate ] && grep -q $'\t7d\t' <<<"$v2" && ok || bad "V2: 7d fallback when M24<MIN (got: $v2)"
v3=$(V 15 15 1 1 10 1 2 300 400 1 "");     [ "$v3" = ok ] && ok || bad "V3: \$15/PR against 2x\$10 must not trip (got: $v3)"
v4=$(V 300 300 null 1 10 1 2 300 400 1 ""); [ "$v4" = unknown ] && ok || bad "V4: an unknown count is not 0 (got: $v4)"
v5=$(V 0 450 0 0 10 1 2 300 400 1 "");     [ "${v5%%$'\t'*}" = zm ] && grep -q $'\t7d\t' <<<"$v5" && ok || bad "V5: zero-merge 7d trip (got: $v5)"
v6=$(V 350 350 0 1 400 1 2 300 400 1 "");  [ "$v6" = ok ] && ok || bad "V6: 24h zero-merge with M7>=min must not pause (got: $v6)"
v7=$(V 900 900 0 0 10 1 2 0 0 1 "");       [ "$v7" = ok ] && ok || bad "V7: Z thresholds 0 are off (got: $v7)"
v8=$(V 0 450 0 0 10 1 2 300 400 1 3600);   [ "$v8" = ok ] && ok || bad "V8: a 7d window that began before the last halt is not judged (got: $v8)"
v8b=$(V 350 350 0 0 400 1 2 300 400 1 90000); [ "${v8b%%$'\t'*}" = zm ] && grep -q $'\t24h\t' <<<"$v8b" && ok || bad "V8b: 24h is judged again a day after the halt (got: $v8b)"

# ════════════════════════════════════════════════════════════════════════════
# M. Mutations of the shipped script
# ════════════════════════════════════════════════════════════════════════════
MUT="$T/mut"; mkdir -p "$MUT"
# M1 verdict forced "ok": B1 must go red
awk '/^if \[ "\$\{BASH_SOURCE\[0\]\}" != "\$0" \]/{print "cost_local_verdict() { echo ok; }"} {print}' "$DIR/bin/cost-local-brake.sh" > "$MUT/m1.sh"
grep -q '^cost_local_verdict() { echo ok; }' "$MUT/m1.sh" && ok || bad "M1: the main guard line was not found to inject before"
sinks_reset; box_fixture; b1_rows; cp "$MUT/m1.sh" "$C/bin/cost-local-brake.sh"; chmod +x "$C/bin/cost-local-brake.sh"
CURL_MODE=down GH_M24=1 GH_M7=1 run_brake "$C"
[ ! -e "$C/flags/spend-hold-x" ] && ok || bad "M1: with the verdict forced ok, B1's pause must not happen"
# M2 outage gate removed: B3 must go red
sed 's/# <outage-gate>$/# mutated/; s/^\( *\)if \[ "\$frc" != 1 \]; then # mutated/\1if false; then/' "$DIR/bin/cost-local-brake.sh" > "$MUT/m2.sh"
grep -q '^ *if false; then' "$MUT/m2.sh" && ok || bad "M2: the outage gate line ('if [ \"\$frc\" != 1 ]; then # <outage-gate>') was not found"
sinks_reset; box_fixture; b1_rows; cp "$MUT/m2.sh" "$C/bin/cost-local-brake.sh"; chmod +x "$C/bin/cost-local-brake.sh"
CURL_MODE=up GH_M24=1 GH_M7=1 run_brake "$C"
[ -e "$C/flags/spend-hold-x" ] && ok || bad "M2: without the outage gate, B3's numbers must pause (so B3 pins the gate)"

echo "cost-local-brake: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
