#!/bin/bash
# tests/routing-writers.bh-1373-test.sh — BH-1373 (BH-1027.4): the routing and
# pause-flag WRITERS. Enrollment, trial kill, pool halt, the deploy's halt
# clear and the cost autohalt each keep their file write and then ask the row
# (routing_set / flag_set) to follow it: file first, row second, only when
# bin/jobs-client.sh is beside them and, for routing, only when the
# `routing_rows` knob is on.
#
# WHAT IS DRIVEN. The real bin/fly-pool-rollout.sh, bin/fly-trial-kill.sh,
# bin/harness-sync.sh and bin/fly-onboard.sh, whole, against scratch harnesses;
# bin/pipeline-health.sh's `pool refusal halt`, `cost budget` and `hung machine
# liveness` blocks extracted verbatim between their own markers (the same way
# the other pipeline-health suites drive it). curl, ssh, flyctl and sleep are
# PATH shims in $T/fakebin that record every call to a sink. Every assertion is
# on an artifact: a file under flags/, a line in req.log / calls.* / a log, or
# the captured stdout of the real script.
#
# CASES (the ticket's acceptance list, plus R1/R2 from the plan):
#   1 one write, not two boxes      6 ordering (PUT fails, files stand)
#   2 the trial-kill negative       7 dark default (knob off, no request)
#   3 halt round-trip + .keep       8 no-client fallback (modules absent)
#   3a pool halt row write          9 traversal
#   4 cost autohalt via flag_set   10 mutation (row-clear deleted -> red)
#   5 autohalt, worker down        R1 hung-machine read   R2 onboard honors the row
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/routing-writers.bh-1373-test.sh
# (the sandbox variable is only needed as root next to a live /root/harness).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# The shims below are quoted heredocs that read $T when they run.
export T
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
for c in jq git flock rsync; do command -v "$c" >/dev/null || { echo "$c missing — skipping"; exit 0; }; done
# pipeline-health's liveness probe prepends /root/.fly/bin to PATH; a real
# flyctl there would shadow the shim and drive Fly for real.
[ -x /root/.fly/bin/flyctl ] && { echo "refusing to run: a real flyctl at /root/.fly/bin would shadow the shim"; exit 1; }

NOW=$(date +%s)
STAMP_AT() { date -u -d "@$(( NOW - $1 ))" '+%Y-%m-%d %H:%M:%SZ'; }
FAKE="$T/fakebin"; ROWS="$T/rows"
mkdir -p "$FAKE" "$ROWS"

# --- fake curl: the 1369 fake, with PUT /api/routing PERSISTING the row (so a
# later routing-sync sees what harness-sync wrote) and a PUT /api/flags arm.
# CURL_MODE: ok|down|putfail. The knob is $SETTING_JSON.
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
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "$METHOD $URL" in
  "GET "*/api/settings/*)
    if [ -s "${SETTING_JSON:-/nonexistent}" ]; then cat "$SETTING_JSON"; printf '\n200\n'
    else printf '{"error":"not found"}\n404\n'; fi; exit 0 ;;
esac
[ "${CURL_MODE:-ok}" = down ] && exit 7
case "$METHOD $URL" in
  "PUT "*/api/routing)
    [ "${CURL_MODE:-ok}" = putfail ] && { printf '{"error":"boom"}\n500\n'; exit 0; }
    p=$(printf '%s' "$BODY" | jq -r .project)
    printf '%s' "$BODY" | jq -c '. + {updated_at:"2026-09-23T00:00:01Z"}' > "$ROWS/$p.json"
    printf '{"routing":%s}\n200\n' "$(cat "$ROWS/$p.json")" ;;
  "GET "*/api/routing/*)
    p="${URL##*/api/routing/}"
    if [ -f "$ROWS/$p.json" ]; then printf '{"routing":%s}\n200\n' "$(cat "$ROWS/$p.json")"
    else printf '{"error":"not found"}\n404\n'; fi ;;
  "PUT "*/api/flags)
    [ "${CURL_MODE:-ok}" = putfail ] && { printf '{"error":"boom"}\n500\n'; exit 0; }
    # TEST-CHANGE BH-4153: flag_set reads the answer back through _flag_norm,
    # which needs .flag.name to be the name written; an answer without it reads
    # as "not written" (costhaltfail). Echo the row it was sent (as
    # tests/cost-local-brake.bh-2599-test.sh does). A non-ported name's flag_set
    # (BH-5004) reads .flag.active and .flag.updated_at from the same answer.
    printf '%s' "$BODY" | jq -c '{flag:{name, scope:(.scope // "fleet"), active, value:(.value // null),
      set_at:"2026-09-23T00:00:02Z", cleared_at:(if .active == 1 then null else "2026-09-23T00:00:02Z" end),
      updated_at:"2026-09-23T00:00:02Z"}}'
    printf '200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
CURL
cat > "$FAKE/ssh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$T/calls.ssh"
exit 0
SH
cat > "$FAKE/flyctl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$T/calls.fly"
case "$1" in
  machine) case "$2" in run) echo "Machine ID: 0123456789abcd" ;; esac; exit 0 ;;
  machines) printf '[{"id":"0123456789abcd","state":"started"}]\n'; exit 0 ;;
  ssh) case "$*" in
         *"/run/harness/RESULT"*) cat "$T/result.txt" 2>/dev/null ;;
         *"-newermt"*) echo /data/harness/builds/moved ;;
       esac; exit 0 ;;
esac
exit 0
SH
printf '#!/bin/sh\nexit 0\n' > "$FAKE/sleep"
chmod +x "$FAKE"/*
printf 'SMOKE_OK claude reachable\n' > "$T/result.txt"

export PATH="$FAKE:$PATH" JOBS_URL=https://jobs.invalid SETTING_JSON="$T/setting.json" \
       ROWS REQ_SINK="$T/req.log" JOBS_RETRIES=0 HARNESS_SECRET=test-secret
unset ROUTING_ROWS CURL_MODE
knob() { printf '{"key":"routing_rows","setting":{"key":"routing_rows","value":"%s"}}' "$1" > "$T/setting.json"; }
row() { # row <project> <builder> <pool_app|null> <halted>
  local app='null'; [ "$3" = null ] || app="\"$3\""
  printf '{"project":"%s","builder":"%s","pool_app":%s,"halted":%s,"updated_at":"2026-09-23T00:00:00Z"}' "$1" "$2" "$app" "$4" > "$ROWS/$1.json"
}
sinks_reset() { rm -f "$T/req.log" "$T/calls.ssh" "$T/calls.fly" "$ROWS"/*.json; }
routing_reqs() { if [ -f "$T/req.log" ]; then grep -c '/api/routing' "$T/req.log"; else echo 0; fi; }
# jobs_into <harness> [nomods] — the client beside a harness's bin/. `nomods`
# copies the client WITHOUT bin/lib/jobs/: the "moved aside" state, in which
# the client refuses to load and exits 1.
jobs_into() {
  mkdir -p "$1/bin/lib/jobs" "$1/env" "$1/logs" "$1/flags" "$1/state"
  cp "$DIR/bin/jobs-client.sh" "$1/bin/"
  cp "$DIR/bin/lib/env-path.sh" "$1/bin/lib/"
  if [ "${2:-}" = nomods ]; then scratch_rm "$1/bin/lib/jobs"; else cp "$DIR"/bin/lib/jobs/*.sh "$1/bin/lib/jobs/"; fi
  echo "HARNESS_SECRET=test-secret" > "$1/env/global.env"
}
# flagsnap <harness> — every file under flags/ with its content, jobs-client's
# own daily outage marker excluded (existing _jobs_log behaviour, not ours).
flagsnap() { ( cd "$1/flags" 2>/dev/null || exit 0
  for f in *; do [ -f "$f" ] || continue; case "$f" in alerted-*) continue ;; esac; printf '%s=%s\n' "$f" "$(cat "$f")"; done ); }

# ════════════════════════════════════════════════════════════════════════════
# The rollout fixture: the tests/fly-pool-rollout-probe-test.sh shape.
# ════════════════════════════════════════════════════════════════════════════
rollout_fixture() { # rollout_fixture <harness> [jobs|nomods|none]
  local R="$1"
  scratch_rm "$R"; mkdir -p "$R/bin" "$R/logs" "$R/flags" "$R/locks" "$R/env" "$R/state/fly"
  printf 'p Acme/p - - 1 box-x 10.9.9.9\n' > "$R/fleet.conf"
  printf 'FLY_ORG=o\nFLY_API_TOKEN_P=t\nFLY_REGION=iad\n' > "$R/env/fly.env"
  cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$DIR/bin/pool-cap.sh" "$DIR/bin/result-prefix-ok.sh" "$R/bin/"
  printf '#!/bin/bash\necho "image: registry.fly.io/builder-$1:deployment-1"\n' > "$R/bin/fly-image-build.sh"
  printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"\n' > "$R/bin/fly-envbundle.sh"
  printf '#!/bin/sh\nexit 0\n' > "$R/bin/beat.sh"
  printf '#!/bin/sh\nexit 0\n' > "$R/bin/harden-state.sh"
  chmod +x "$R/bin"/*.sh
  case "${2:-jobs}" in jobs) jobs_into "$R" ;; nomods) jobs_into "$R" nomods ;; esac
  # BH-2523: a hub's bin/lib holds the fly_images row seam whatever the client's
  # state, and the rollout loads it from the harness root.
  mkdir -p "$R/bin/lib"; cp "$DIR/bin/lib/fly-image-row.sh" "$R/bin/lib/"
}
# nonfir_reqs — the request sink without the fly_images row traffic (BH-2523),
# which has its own kill switch (FLY_IMAGES_DB) and is not the routing knob's.
nonfir_reqs() { [ -f "$T/req.log" ] && grep -v ' https://jobs.invalid/api/fly-images' "$T/req.log"; }
run_rollout() { # run_rollout <harness> <project>
  HARNESS="$1" FLEET_CONF="$1/fleet.conf" FLYCTL_DIR="$FAKE" bash "$DIR/bin/fly-pool-rollout.sh" "$2" >/dev/null 2>&1
}
RL="$T/r"

# --- 1. one write, not two boxes (knob on) ---------------------------------
sinks_reset; knob on; rollout_fixture "$RL"
run_rollout "$RL" p
[ ! -e "$T/calls.ssh" ] && ok || bad "1: knob on, the rollout must not ssh the owning box (calls.ssh: $(cat "$T/calls.ssh" 2>/dev/null))"
[ "$(cat "$RL/flags/fly-pool-app-p" 2>/dev/null)" = pool-p ] && [ -e "$RL/flags/fly-pool-p" ] && [ -e "$RL/flags/builder-fly-p" ] \
  && ok || bad "1: the three hub flags must be written (got: $(flagsnap "$RL" | tr '\n' ' '))"
grep -qF 'PUT https://jobs.invalid/api/routing {"project":"p","builder":"pool","halted":0,"pool_app":"pool-p"}' "$T/req.log" 2>/dev/null \
  && ok || bad "1: the rollout must PUT the pool row (req.log: $(cat "$T/req.log" 2>/dev/null))"
grep -q '\[p\] routing row set: builder=pool app=pool-p' "$RL/logs/fly-pool-rollout.log" \
  && ok || bad "1: the rollout log must say the row was set"
grep -q 'WAVE3 ENABLED' "$RL/logs/fly-pool-rollout.log" && ok || bad "1: the wave must still be enabled"

# cap content survives, and a halted project stays halted on re-enrollment
sinks_reset; rollout_fixture "$RL"; touch "$RL/flags/pool-halt-p"
HARNESS="$RL" FLEET_CONF="$RL/fleet.conf" FLYCTL_DIR="$FAKE" POOL_CAP=3 bash "$DIR/bin/fly-pool-rollout.sh" p >/dev/null 2>&1
[ "$(cat "$RL/flags/fly-pool-p" 2>/dev/null)" = 3 ] && ok || bad "1: the row write must not rewrite the pool cap in fly-pool-p (got '$(cat "$RL/flags/fly-pool-p" 2>/dev/null)')"
[ -e "$RL/flags/pool-halt-p" ] && grep -q '"halted":1' "$T/req.log" 2>/dev/null \
  && ok || bad "1: re-enrolling a halted project must not lift its halt (file or row)"

# --- 6. ordering: PUT fails, the files stand, the caller says so ------------
sinks_reset; rollout_fixture "$RL"
CURL_MODE=putfail run_rollout "$RL" p
[ "$(cat "$RL/flags/fly-pool-app-p" 2>/dev/null)" = pool-p ] && [ -e "$RL/flags/fly-pool-p" ] && [ -e "$RL/flags/builder-fly-p" ] \
  && ok || bad "6: a failed PUT must leave all three files written"
grep -q '\[p\] WARNING: routing row for p not written' "$RL/logs/fly-pool-rollout.log" \
  && ok || bad "6: a failed PUT must log the WARNING line"
grep -q 'routing row set' "$RL/logs/fly-pool-rollout.log" && bad "6: a failed PUT must never log 'routing row set'" || ok
[ ! -e "$T/calls.ssh" ] && ok || bad "6: knob on + PUT failure must not fall back to ssh"

# --- 7 / 8. dark default and no client: today's files and today's ssh -------
sinks_reset; rollout_fixture "$RL" none
run_rollout "$RL" p
BASE_FLAGS=$(flagsnap "$RL"); BASE_SSH=$(cat "$T/calls.ssh" 2>/dev/null)
grep -q 'touch /root/harness/flags/builder-fly-p' "$T/calls.ssh" 2>/dev/null \
  && ok || bad "7/8 baseline: with no client the rollout must ssh the owning box as before"
[ -n "$BASE_FLAGS" ] && ok || bad "7/8 baseline: with no client the rollout must write its flags"
sinks_reset; rollout_fixture "$RL"
ROUTING_ROWS=off run_rollout "$RL" p
[ "$(flagsnap "$RL")" = "$BASE_FLAGS" ] && [ "$(cat "$T/calls.ssh" 2>/dev/null)" = "$BASE_SSH" ] \
  && ok || bad "7: ROUTING_ROWS=off must write exactly today's files and ssh exactly as today"
# The routing knob owns routing traffic only: the fly_images row (BH-2523) is
# governed by FLY_IMAGES_DB, so with ROUTING_ROWS=off alone nothing but
# /api/fly-images may reach the worker, and with both switches off nothing may.
[ -z "$(nonfir_reqs)" ] && ok || bad "7: ROUTING_ROWS=off: only fly_images row traffic may reach the worker (got: $(nonfir_reqs))"
sinks_reset; rollout_fixture "$RL"
ROUTING_ROWS=off FLY_IMAGES_DB=0 run_rollout "$RL" p
[ "$(flagsnap "$RL")" = "$BASE_FLAGS" ] && [ "$(cat "$T/calls.ssh" 2>/dev/null)" = "$BASE_SSH" ] \
  && ok || bad "7: ROUTING_ROWS=off FLY_IMAGES_DB=0 must write exactly today's files and ssh exactly as today"
[ ! -e "$T/req.log" ] && ok || bad "7: ROUTING_ROWS=off FLY_IMAGES_DB=0: the request sink must be EMPTY (got: $(cat "$T/req.log"))"
sinks_reset; rollout_fixture "$RL"; knob off
run_rollout "$RL" p
[ "$(flagsnap "$RL")" = "$BASE_FLAGS" ] && [ "$(cat "$T/calls.ssh" 2>/dev/null)" = "$BASE_SSH" ] \
  && ok || bad "7: settings row off must behave as today"
[ "$(routing_reqs)" = 0 ] && ok || bad "7: settings row off must make ZERO /api/routing requests"
sinks_reset; rollout_fixture "$RL" nomods; knob on
run_rollout "$RL" p
[ "$(flagsnap "$RL")" = "$BASE_FLAGS" ] && [ "$(cat "$T/calls.ssh" 2>/dev/null)" = "$BASE_SSH" ] \
  && ok || bad "8: bin/lib/jobs absent must behave exactly as the pre-change rollout (ssh path included)"
[ ! -e "$T/req.log" ] && ok || bad "8: bin/lib/jobs absent must make no request"

# --- 9. traversal through the rollout ---------------------------------------
sinks_reset; rollout_fixture "$RL"; knob on
( cd "$RL" && find . -path ./logs -prune -o -type f -print | sort ) > "$T/before.txt"
run_rollout "$RL" '../p'
( cd "$RL" && find . -path ./logs -prune -o -type f -print | sort ) > "$T/after.txt"
cmp -s "$T/before.txt" "$T/after.txt" && ok || bad "9: '../p' through the rollout created files: $(diff "$T/before.txt" "$T/after.txt" | tr '\n' ' ')"
[ ! -e "$T/p" ] && [ ! -e "$T/flags" ] && [ "$(routing_reqs)" = 0 ] && ok || bad "9: '../p' must write nothing outside the harness and PUT nothing"

# ════════════════════════════════════════════════════════════════════════════
# 2. bin/fly-trial-kill.sh — the ticket's negative, in every knob state
# ════════════════════════════════════════════════════════════════════════════
KL="$T/k"
# SAFETY, not an assertion: the script touches $HARNESS/flags/fly-disabled
# first thing, so a copy that ignores $HARNESS would kill the LIVE trial.
# Such a copy is never run; every case 2 assertion then fails instead.
KILL_SAFE=0
grep -q '^HARNESS="\${HARNESS:-/root/harness}"' "$DIR/bin/fly-trial-kill.sh" && KILL_SAFE=1
[ "$KILL_SAFE" = 1 ] || bad "2: bin/fly-trial-kill.sh does not honour \$HARNESS — not driven next to a live harness"
kill_fixture() { # kill_fixture [jobs|nomods|none]
  scratch_rm "$KL"; mkdir -p "$KL/bin" "$KL/env" "$KL/flags" "$KL/state/fly" "$KL/logs"
  printf 'FLY_ORG=o\n' > "$KL/env/fly.env"
  printf '{"app":"pool-p"}\n' > "$KL/state/fly/p.json"
  printf '#!/bin/sh\necho stopped\n' > "$KL/bin/fly-api.sh"
  printf '#!/bin/sh\nexit 0\n' > "$KL/bin/fly-dispatch.sh"
  chmod +x "$KL/bin"/*.sh
  : > "$KL/flags/builder-fly-p"; : > "$KL/flags/fly-pool-p"; echo pool-p > "$KL/flags/fly-pool-app-p"
  case "${1:-jobs}" in jobs) jobs_into "$KL" ;; nomods) jobs_into "$KL" nomods ;; esac
}
run_kill() {
  [ "$KILL_SAFE" = 1 ] || { : > "$T/kill.out"; KRC=99; return; }
  HARNESS="$KL" bash "$DIR/bin/fly-trial-kill.sh" "$@" > "$T/kill.out" 2>&1; KRC=$?
}
kill_negative() { # kill_negative <label>
  [ "$KRC" = 0 ] && ok || bad "2 ($1): fly-trial-kill must exit 0 (got $KRC: $(cat "$T/kill.out"))"
  [ -e "$KL/flags/fly-disabled" ] && ok || bad "2 ($1): flags/fly-disabled must be set"
  [ ! -e "$KL/flags/builder-fly-p" ] && ok || bad "2 ($1): flags/builder-fly-p must be gone"
  grep -q 'ssh root@' "$T/kill.out" && bad "2 ($1): output must not match 'ssh root@': $(cat "$T/kill.out")" || ok
  grep -q 'drop the flag on the owning box' "$T/kill.out" && bad "2 ($1): output must not match 'drop the flag on the owning box'" || ok
  grep -q 'owning box' "$T/kill.out" && grep -q 're-touch' "$T/kill.out" && bad "2 ($1): the resume recipe must not tell the operator to re-touch two boxes" || ok
}
sinks_reset; knob on; kill_fixture
run_kill p
kill_negative "knob on"
grep -qF 'PUT https://jobs.invalid/api/routing {"project":"p","builder":"local","halted":0}' "$T/req.log" 2>/dev/null \
  && ok || bad "2 (knob on): trial-kill must PUT builder=local (req.log: $(cat "$T/req.log" 2>/dev/null))"
grep -q 'p: routing row set to local' "$T/kill.out" && ok || bad "2 (knob on): the output must say the row was set to local"
[ ! -e "$KL/flags/fly-pool-p" ] && [ ! -e "$KL/flags/fly-pool-app-p" ] && ok || bad "2 (knob on): a local row drops the pool files as well"
sinks_reset; kill_fixture
CURL_MODE=putfail run_kill p
kill_negative "putfail"
grep -q 'routing row PUT failed' "$T/kill.out" && ! grep -q 'routing row set to local' "$T/kill.out" \
  && ok || bad "2 (putfail): a failed PUT must be said, never reported as set"
sinks_reset; kill_fixture
ROUTING_ROWS=off run_kill p
kill_negative "ROUTING_ROWS=off"
[ ! -e "$T/req.log" ] && ok || bad "7 (trial-kill): ROUTING_ROWS=off must make no request"
[ -e "$KL/flags/fly-pool-p" ] && ok || bad "7 (trial-kill): knob off keeps today's single rm (fly-pool-p untouched)"
KILL_OFF=$(flagsnap "$KL")
sinks_reset; kill_fixture nomods; knob on
run_kill p
kill_negative "modules absent"
[ ! -e "$T/req.log" ] && ok || bad "8 (trial-kill): modules absent must make no request"
[ "$(flagsnap "$KL")" = "$KILL_OFF" ] && ok || bad "7/8 (trial-kill): knob off and no-client must leave the same files"
# 9. traversal
sinks_reset; kill_fixture; knob on
( cd "$KL" && find . -path ./logs -prune -o -type f -print | sort ) > "$T/before.txt"
run_kill '../p'
( cd "$KL" && find . -path ./logs -prune -o -type f -print | grep -v '^./flags/fly-disabled$' | sort ) > "$T/after.txt"
grep -q 'no state file — skipping' "$T/kill.out" && ok || bad "9 (trial-kill): '../p' must be skipped"
cmp -s "$T/before.txt" "$T/after.txt" && [ "$(routing_reqs)" = 0 ] && ok || bad "9 (trial-kill): '../p' created or requested something"

# ════════════════════════════════════════════════════════════════════════════
# 3 / 3a / 10. The halt round-trip: pipeline-health halts (file + row),
# harness-sync clears (file + row), and a following sync does not undo it.
# ════════════════════════════════════════════════════════════════════════════
PH="$DIR/bin/pipeline-health.sh"
block() { # block <marker> <out>
  [ "$(grep -c "^# >>> $1" "$PH")" = 1 ] && [ "$(grep -c "^# <<< $1" "$PH")" = 1 ] \
    || { bad "bin/pipeline-health.sh must carry exactly one '# >>> $1' / '# <<< $1' pair"; : > "$2"; return; }
  awk -v m="$1" 'index($0, "# >>> " m) == 1 {f=1; next} index($0, "# <<< " m) == 1 {exit} f' "$PH" > "$2"
  [ -s "$2" ] || bad "the '$1' block extracted empty"
}
block "pool refusal halt" "$T/halt.sh"
block "cost budget" "$T/cost.sh"
block "hung machine liveness" "$T/hung.sh"

HS="$T/hs"
# drive_block <harness> <block-file> <client: yes|no> [projects] — run a block
# the way pipeline-health runs it: H set, NOW pinned, alert() writing the
# alert line into ALERTS.log, the jobs client sourced when it is there.
drive_block() {
  ( cd "$T" && export H="$1" HARNESS="$1" PROJECTS="${4:-x}" NOW="$NOW" HENV="$1/env" FLEET_CONF="$1/fleet.conf"
    bash -c 'STAMP() { date -u "+%Y-%m-%d %H:%M:%SZ"; }
             alert() { printf "%s\n" "$*" >> "$H/logs/ALERTS.log"; }
             if [ "$2" = yes ]; then . "$H/bin/jobs-client.sh" || exit 1; fi
             # pipeline-health.sh sources the flag reader in its header (BH-5642),
             # outside every block; the extracted block needs it the same way.
             . "$3/bin/lib/flag-on.sh" || exit 1
             . "$1"' _ "$2" "$3" "$DIR" ) >/dev/null 2>&1
}
refusals() { # two fresh BUILD_REFUSED reaps for x
  mkdir -p "$1/logs"
  { printf '%s [pool/x] reaped pool-x-TK-1-a BUILD_REFUSED context drift\n' "$(STAMP_AT 300)"
    printf '%s [pool/x] reaped pool-x-TK-2-a BUILD_REFUSED context drift\n' "$(STAMP_AT 200)"; } > "$1/logs/fly-pool.log"
}
x_files() { : > "$1/flags/builder-fly-x"; : > "$1/flags/fly-pool-x"; echo pool-x > "$1/flags/fly-pool-app-x"; }

# 3a. the pool halt writes the row, after the file
sinks_reset; knob on; scratch_rm "$HS"; jobs_into "$HS"; x_files "$HS"; refusals "$HS"
drive_block "$HS" "$T/halt.sh" yes
[ -e "$HS/flags/pool-halt-x" ] && ok || bad "3a: the pool halt must write flags/pool-halt-x"
grep -qF 'PUT https://jobs.invalid/api/routing {"project":"x","builder":"pool","halted":1,"pool_app":"pool-x"}' "$T/req.log" 2>/dev/null \
  && ok || bad "3a: the pool halt must PUT halted=1 (req.log: $(cat "$T/req.log" 2>/dev/null))"
grep -q 'poolhalt:x' "$HS/logs/ALERTS.log" 2>/dev/null && ok || bad "3a: the poolhalt alert must still land"
[ "$(jq -r .halted "$ROWS/x.json" 2>/dev/null)" = 1 ] && ok || bad "3a: the row store must say halted=1"
# 3a putfail: file and alert stand, the log line says the row did not follow
scratch_rm "$HS"; jobs_into "$HS"; x_files "$HS"; refusals "$HS"; rm -f "$T/req.log"
CURL_MODE=putfail drive_block "$HS" "$T/halt.sh" yes
[ -e "$HS/flags/pool-halt-x" ] && grep -q 'poolhalt:x' "$HS/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "3a putfail: the file and the alert must still land"
grep -q 'x: pool halt written to flags/ but the routing row PUT failed' "$HS/logs/pipeline-health.log" 2>/dev/null \
  && ok || bad "3a putfail: logs/pipeline-health.log must say the row PUT failed"
# 7 / 8 for the halt block
for mode in off noclient; do
  sinks_reset; scratch_rm "$HS"; jobs_into "$HS"; x_files "$HS"; refusals "$HS"
  if [ "$mode" = off ]; then ROUTING_ROWS=off drive_block "$HS" "$T/halt.sh" yes; else drive_block "$HS" "$T/halt.sh" no; fi
  [ -e "$HS/flags/pool-halt-x" ] && grep -q 'poolhalt:x' "$HS/logs/ALERTS.log" 2>/dev/null \
    && ok || bad "7/8 halt ($mode): the file and the alert must land as today"
  [ ! -e "$T/req.log" ] && ok || bad "7/8 halt ($mode): no request (got: $(cat "$T/req.log"))"
done

# 3. the round-trip through the REAL harness-sync
git init -q --bare "$T/origin"
git clone -q "$T/origin" "$T/ck" 2>/dev/null
git -C "$T/ck" config user.email t@t; git -C "$T/ck" config user.name t
mkdir -p "$T/ck/bin" "$T/ck/prompts" "$T/ck/fly" "$T/ck/catalog"
printf '#!/bin/bash\n:\n' > "$T/ck/bin/x.sh"; printf 'p\n' > "$T/ck/prompts/p.md"
printf 'f\n' > "$T/ck/fly/f.txt"; printf '{}\n' > "$T/ck/catalog/c.json"; printf 'fleet\n' > "$T/ck/fleet.conf"
git -C "$T/ck" add -A >/dev/null; git -C "$T/ck" commit -qm seed
git -C "$T/ck" branch -M main 2>/dev/null; git -C "$T/ck" push -q origin main
git -C "$T/ck" branch --set-upstream-to=origin/main main >/dev/null 2>&1
hs_fixture() { # halted x (file + row, via the real halt block) and a .keep'd y
  sinks_reset; knob on; scratch_rm "$HS"; jobs_into "$HS"; x_files "$HS"; refusals "$HS"
  mkdir -p "$HS/bin" "$HS/prompts" "$HS/fly" "$HS/catalog" "$HS/locks" "$HS/checks" "$HS/guardrails" "$HS/config"
  drive_block "$HS" "$T/halt.sh" yes
  : > "$HS/flags/pool-halt-y"; : > "$HS/flags/pool-halt-y.keep"; row y pool pool-y 1
  rm -f "$T/req.log"
}
run_sync() { # run_sync <script>
  ( export HARNESS="$HS" HARNESS_CHECKOUT="$T/ck"; bash "$1" ) > "$T/sync.out" 2>&1; SRC=$?
}
hs_fixture
[ -e "$HS/flags/pool-halt-x" ] && [ "$(jq -r .halted "$ROWS/x.json" 2>/dev/null)" = 1 ] \
  && ok || bad "3: fixture — the halt block must leave x halted on file and row"
run_sync "$DIR/bin/harness-sync.sh"
[ "$SRC" = 0 ] && ok || bad "3: harness-sync must deploy (rc $SRC: $(cat "$T/sync.out"))"
[ ! -e "$HS/flags/pool-halt-x" ] && ok || bad "3: the deploy must clear flags/pool-halt-x"
[ "$(jq -r .halted "$ROWS/x.json" 2>/dev/null)" = 0 ] && ok || bad "3: the deploy must clear the ROW (row: $(cat "$ROWS/x.json" 2>/dev/null))"
[ "$(jq -r '.builder + " " + .pool_app' "$ROWS/x.json" 2>/dev/null)" = "pool pool-x" ] && ok || bad "3: the clear must keep builder/app"
( export HARNESS="$HS"; bash "$HS/bin/jobs-client.sh" routing-sync x ); SYRC=$?
[ "$SYRC" = 0 ] && [ ! -e "$HS/flags/pool-halt-x" ] && ok || bad "3: a following routing-sync must NOT put the halt back (rc $SYRC)"
[ -e "$HS/flags/pool-halt-y" ] && [ -e "$HS/flags/pool-halt-y.keep" ] && ok || bad "3: a .keep'd halt must survive the deploy"
grep -q '"project":"y"' "$T/req.log" 2>/dev/null && bad "3: a .keep'd halt must not be PUT" || ok
# row-clear PUT fails: the file is still cleared and the log says what comes next
hs_fixture
CURL_MODE=putfail run_sync "$DIR/bin/harness-sync.sh"
[ ! -e "$HS/flags/pool-halt-x" ] && grep -q 'pool-halt-x cleared on disk but the routing row could not be cleared' "$HS/logs/update-runners.log" \
  && ok || bad "3: a failed row clear must be logged in update-runners.log"
# 7 (BH-2010): knob OFF, the deploy clears the ROW too whenever one exists —
# TEST-CHANGE: this used to assert "no request at all". A stale halted=1 row left
# behind by a knob-off deploy re-halts the project the moment the knob is
# flipped (#2010 item 2), so the row is cleared knob on or off. With no row
# there is still no write.
hs_fixture
ROUTING_ROWS=off run_sync "$DIR/bin/harness-sync.sh"
[ ! -e "$HS/flags/pool-halt-x" ] && ok || bad "7 (harness-sync): knob off must still clear the file"
[ "$(jq -r .halted "$ROWS/x.json" 2>/dev/null)" = 0 ] && ok || bad "7 (harness-sync): knob off must clear the halted ROW too (row: $(cat "$ROWS/x.json" 2>/dev/null))"
grep -q '"actor":"harness-sync"' <<<"$(grep '^PUT .*/api/routing ' "$T/req.log" 2>/dev/null)" \
  && ok || bad "7 (harness-sync): the row clear must be audited as actor harness-sync: $(cat "$T/req.log" 2>/dev/null)"
hs_fixture; rm -f "$ROWS/x.json"
ROUTING_ROWS=off run_sync "$DIR/bin/harness-sync.sh"
[ ! -e "$HS/flags/pool-halt-x" ] && ! grep -q '^PUT .*/api/routing ' "$T/req.log" 2>/dev/null \
  && ok || bad "7 (harness-sync): with no row, the deploy clears the file and writes no row: $(cat "$T/req.log" 2>/dev/null)"

# 10. mutation: delete the row-clear and case 3's last assertion must go red
MUT="$T/harness-sync.mut.sh"
grep -v 'routing-set "\$_hp"' "$DIR/bin/harness-sync.sh" > "$MUT"
if cmp -s "$MUT" "$DIR/bin/harness-sync.sh" || ! bash -n "$MUT"; then
  bad "10: the mutant is identical or does not parse — the row-clear line was not found as one line"
else
  hs_fixture
  run_sync "$MUT"
  ( export HARNESS="$HS"; bash "$HS/bin/jobs-client.sh" routing-sync x )
  [ -e "$HS/flags/pool-halt-x" ] && ok || bad "10: without the row-clear, routing-sync must put the halt back (case 3 would stay green: vacuous)"
fi

# ════════════════════════════════════════════════════════════════════════════
# 4 / 5. The cost autohalt writes through flag_set (BH-5526: its flag is the
#        hold spend-hold-<p>, not the human pause paused-<p>)
# ════════════════════════════════════════════════════════════════════════════
CH="$T/c"
cost_fixture() { # cost_fixture [jobs|none]
  scratch_rm "$CH"; mkdir -p "$CH/bin/lib" "$CH/logs" "$CH/flags" "$CH/state/cost" "$CH/env"
  printf '{"projects":{"x":{"delivery_cost_24h":30,"merged_prs_24h":1,"cost_7d":30,"product_7d":0,"merged_prs_7d":1,"merged_prs_status":"ok"}}}\n' > "$CH/state/cost/summary.json"
  printf 'cost_budget_for() { echo "10 1"; }\ncost_budget_source() { echo fixture; }\n' > "$CH/bin/lib/cost-budget.sh"
  : > "$CH/flags/cost-autohalt-optin"; echo 0 > "$CH/state/costbreaker.stamp"
  printf 'x Acme/x - - 1 box-x 10.8.8.8\n' > "$CH/fleet.conf"
  cp "$DIR/bin/fleet-conf.sh" "$CH/bin/"
  [ "${1:-jobs}" = jobs ] && jobs_into "$CH"
}
sinks_reset; cost_fixture
drive_block "$CH" "$T/cost.sh" yes
[ -e "$CH/flags/spend-hold-x" ] && ok || bad "4: the autohalt must write flags/spend-hold-x"
grep -q 'PUT https://jobs.invalid/api/flags {"name":"spend-hold-x","active":1,' "$T/req.log" 2>/dev/null \
  && ok || bad "4: the autohalt must PUT the flag row active=1 (req.log: $(cat "$T/req.log" 2>/dev/null))"
grep -q '"reason":"\$30.00/PR over 24h (cost autohalt)"' "$T/req.log" 2>/dev/null && ok || bad "4: the flag row must carry the rate and window"
grep -q 'costhalt:x' "$CH/logs/ALERTS.log" && ! grep -q 'costhaltfail:x' "$CH/logs/ALERTS.log" \
  && ok || bad "4: a landed halt must alert costhalt, not costhaltfail ($(cat "$CH/logs/ALERTS.log"))"
# K1: the fleet-ceiling sweep in the same block now reaches every fleet.conf box
# (this fixture's 10.8.8.8 among them) when cost_rows cannot answer, so an ssh
# CALL is no longer evidence about the halt. The halt's own ssh is the touch of
# the pause flag; that is what must be absent.
! grep -q 'spend-hold-x' "$T/calls.ssh" 2>/dev/null && ok || bad "4: with the client present the halt must not ssh ($(cat "$T/calls.ssh" 2>/dev/null))"
# 5. worker down: NO file, and the costhaltfail page. SPEC CHANGE (BH-2599):
# this case used to require flags/spend-hold-x on the hub after a failed PUT. That
# file paused nothing (the hub owns no project) and made the next check read
# `already` and stop paging, so the halt now removes it when the row fails.
sinks_reset; cost_fixture
CURL_MODE=down drive_block "$CH" "$T/cost.sh" yes
[ ! -e "$CH/flags/spend-hold-x" ] && ok || bad "5: worker down, a halt whose row failed must not leave flags/spend-hold-x on the hub"
grep -q 'costhaltfail:x' "$CH/logs/ALERTS.log" && ! grep -q 'costhalt:x' "$CH/logs/ALERTS.log" \
  && ok || bad "5: worker down must page costhaltfail and not costhalt ($(cat "$CH/logs/ALERTS.log"))"
# 8. client absent: no row can be written, so the halt FAILS CLOSED to the
# costhaltfail page (BH-2529). The ssh-touch of the owning box this case used to
# pin is gone: the autohalt writes pause rows only.
sinks_reset; cost_fixture none
drive_block "$CH" "$T/cost.sh" no
! grep -q 'spend-hold-x' "$T/calls.ssh" 2>/dev/null \
  && ok || bad "8 (autohalt): with no client the halt must not ssh the owning box (calls.ssh: $(cat "$T/calls.ssh" 2>/dev/null))"
[ ! -e "$CH/flags/spend-hold-x" ] && ok || bad "8 (autohalt): with no client no pause file may be written"
grep -q 'costhaltfail:x' "$CH/logs/ALERTS.log" && ! grep -q 'costhalt:x' "$CH/logs/ALERTS.log" && [ ! -e "$T/req.log" ] \
  && ok || bad "8 (autohalt): no-client path alerts costhaltfail, not costhalt, and makes no request ($(cat "$CH/logs/ALERTS.log"))"

# ════════════════════════════════════════════════════════════════════════════
# R1. The hung-machine liveness probe reads the pool app through the accessor
# ════════════════════════════════════════════════════════════════════════════
HM="$T/hm"
hung_fixture() { # hung_fixture [jobs|none]
  scratch_rm "$HM"; mkdir -p "$HM/bin" "$HM/logs" "$HM/flags" "$HM/env"
  printf '%s [pool/x] spawned 0123456789abcd for x TK-1\n' "$(STAMP_AT 14400)" > "$HM/logs/fly-pool.log"
  printf '#!/bin/sh\necho started\n' > "$HM/bin/fly-machine-state.sh"; chmod +x "$HM/bin/fly-machine-state.sh"
  [ "${1:-jobs}" = jobs ] && jobs_into "$HM"
}
sinks_reset; knob on; hung_fixture; row x pool rowapp 0
drive_block "$HM" "$T/hung.sh" yes
grep -q -- '-a rowapp --machine 0123456789abcd' "$T/calls.fly" 2>/dev/null && ok || bad "R1: knob on, the probe must reach the row's app (calls.fly: $(cat "$T/calls.fly" 2>/dev/null))"
grep -q 'ALIVE (artifacts moving)' "$HM/logs/agent-rules.log" 2>/dev/null && ok || bad "R1: a moving machine must be logged alive"
sinks_reset; hung_fixture; echo fileapp > "$HM/flags/fly-pool-app-x"; row x pool rowapp 0
ROUTING_ROWS=off drive_block "$HM" "$T/hung.sh" yes
grep -q -- '-a fileapp ' "$T/calls.fly" 2>/dev/null && [ "$(routing_reqs)" = 0 ] && ok || bad "R1: knob off, the probe must read the file app"
sinks_reset; hung_fixture none; echo fileapp > "$HM/flags/fly-pool-app-x"
drive_block "$HM" "$T/hung.sh" no
grep -q -- '-a fileapp ' "$T/calls.fly" 2>/dev/null && ok || bad "R1: no client, the probe must read the file app"
sinks_reset; hung_fixture none
drive_block "$HM" "$T/hung.sh" no
[ ! -e "$T/calls.fly" ] && grep -q 'hungmachine:0123456789abcd' "$HM/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "R1: no app anywhere means no probe and a hungmachine alert, as today"

# ════════════════════════════════════════════════════════════════════════════
# R2. bin/fly-onboard.sh answers ALREADY for a project a row enrolled
# ════════════════════════════════════════════════════════════════════════════
. "$(dirname "$0")/lib/fly-onboard-fixture.sh" || exit 1
unset HARNESS_TICKET HUB_BUILD_OK HUB_NO_BUILD_LANES HUB_BOX_NAME BOX_NAME
sinks_reset; knob on
( fly_onboard_fixture "$T/ob1"; jobs_into "$T/ob1"; row alpha pool pool-alpha 0
  BOX_NAME=box-hub bash "$T/ob1/bin/fly-onboard.sh" alpha > "$T/ob.out" 2>&1; echo "$?" > "$T/ob.rc" )
[ "$(cat "$T/ob.rc")" = 0 ] && grep -q '^FLY_ONBOARD alpha ALREADY:' "$T/ob.out" \
  && ok || bad "R2: a row-enrolled project must read ALREADY (rc $(cat "$T/ob.rc"): $(cat "$T/ob.out"))"
[ ! -e "$T/ob1/logs/flyctl-calls.log" ] && ok || bad "R2: ALREADY must spend no flyctl call"
[ -e "$T/ob1/flags/builder-fly-alpha" ] && [ "$(cat "$T/ob1/flags/fly-pool-app-alpha" 2>/dev/null)" = pool-alpha ] \
  && ok || bad "R2: the row's files must now be on disk"
sinks_reset
( fly_onboard_fixture "$T/ob2"; jobs_into "$T/ob2"; row alpha pool pool-alpha 0
  ROUTING_ROWS=off BOX_NAME=box-hub bash "$T/ob2/bin/fly-onboard.sh" alpha > "$T/ob.out" 2>&1 )
[ "$(grep -c 'machine run' "$T/ob2/logs/flyctl-calls.log" 2>/dev/null)" = 1 ] \
  && ok || bad "R2: knob off, no flags -> the normal onboard (one probe machine) must run"
[ "$(routing_reqs)" = 0 ] && ok || bad "R2: knob off must make no /api/routing request"

echo "routing-writers.bh-1373: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
