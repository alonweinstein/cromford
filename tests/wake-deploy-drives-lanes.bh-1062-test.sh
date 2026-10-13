#!/bin/bash
# tests/wake-deploy-drives-lanes.bh-1062-test.sh — deployment_status wakes drive
# the two migration lanes and leave the deploy-train's one-shot, through the real
# bin/wake-loop.sh, the real bin/lib/wake-class-deploy.sh, and (second half) the
# real bin/apply-migrations.sh and bin/migration-autopilot.sh.
#
# Since BH-2637 the loop runs on EVERY box, claims its own wake rows from the
# stub worker (tests/lib/wake-claim-stub.sh) through the REAL jobs-client, and
# never ssh's. project-3 belongs to box-project-3-2, so ITS loop takes the
# deploy row: apply-migrations launches there, locally. migration-autopilot is
# a hub-scoped lane that box refuses, and the hub never claims a box project's
# deploy row — so for a box-owned project that shortcut is cron-only now, and
# the cases below pin exactly that.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/wake-deploy-drives-lanes.bh-1062-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

export HARNESS="$T"
mkdir -p "$T/bin" "$T/bin/lib" "$T/env" "$T/logs" "$T/locks" "$T/state" "$T/flags" "$T/calls" "$T/fakebin"
printf 'HARNESS_SECRET=s\nJOBS_URL=https://jobs.test\n' > "$T/env/global.env"
printf 'PROJECT_3_APP_BASE=https://project-3.test\nMIGRATION_TOKEN=t\nproject-3_INTERNAL_API_TOKEN=v\n' > "$T/env/project-3.env"
export WAKE_LOOP_CYCLES=1 WAKE_LOOP_INTERVAL_S=0

# Real loop, real lib, real class file. ONLY the deploy class is copied, so the
# calls/postmerge-qa counts below are the loop's own legacy launch and nothing
# else's.
cp "$DIR/bin/wake-loop.sh"      "$T/bin/wake-loop.sh"
cp "$DIR/bin/lib/wake-lanes.sh" "$T/bin/lib/wake-lanes.sh"
# BH-1511.1: the lib's default window (WAKE_BACKSTOP_S, 1800) is a registry knob
# now, read through bin/lib/lane-gate.sh's lib_env_apply — so the scratch
# harness carries the gate library and this repo's own rendered registry.
cp "$DIR/bin/lib/lane-gate.sh" "$T/bin/lib/lane-gate.sh"
. "$(dirname "$0")/lib/rendered.sh" || exit 1
export LANE_REGISTRY; LANE_REGISTRY=$(rendered_registry)
# Test-first: the class file does not exist until the feature lands.
[ -f "$DIR/bin/lib/wake-class-deploy.sh" ] && cp "$DIR/bin/lib/wake-class-deploy.sh" "$T/bin/lib/wake-class-deploy.sh"

# BH-2637: the REAL jobs-client — wakes_claim / wake_cursor_* /
# wake_cooldown_take go to the stub worker, and flag_active answers from
# flags/<name> when the flag sync gets `{}` back (the curl below serves that).
mkdir -p "$T/bin/lib/jobs"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
. "$(dirname "$0")/lib/wake-claim-stub.sh" || exit 1
wcs_install "$T/bin"

# Registry: cromford on the hub, project-3 on a remote box.
cat > "$T/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
[ "$1" = "--projects" ] && { printf 'cromford\nproject-3\n'; exit 0; }
case "$1/$2" in
  cromford/repo) echo example-org/cromford ;;
  project-3/repo)       echo example-org/project-3 ;;
  cromford/box)  echo local ;;
  project-3/box)        echo box-project-3-2 ;;
  cromford/board_prefix) echo /api/board ;;
  project-3/board_prefix)       echo /api/feature-board ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/bin/fleet-conf.sh"

# The REAL box-for.sh, box-name.sh and hub-box.sh (BH-2637); BOX_NAME picks the box.
wcs_identity "$T/bin" || { echo "wcs_identity failed"; exit 1; }
HUB=box-hub project-3BOX=box-project-3-2

# No Blocked-by expansion for these tests.
cat > "$T/bin/unblocked-children.sh" <<'SH'
#!/bin/bash
exit 1
SH
chmod +x "$T/bin/unblocked-children.sh"

# Recorders: the legacy lanes the loop already drives, plus the two lanes the
# deploy class drives when it runs them locally.
# Each also notes its WAKE_LAUNCH in calls/<lane>.env.
for s in merge-conductor deploy-train postmerge-qa run-triage rebase-train migration-autopilot apply-migrations; do
  cat > "$T/bin/$s.sh" <<SH
#!/bin/bash
echo "\$*" >> "\$HARNESS/calls/$s"
echo "WAKE_LAUNCH=\${WAKE_LAUNCH:-}" >> "\$HARNESS/calls/$s.env"
SH
  chmod +x "$T/bin/$s.sh"
done

# curl records every URL it is asked for (the second half asserts on
# /api/internal/migrations), hands the wake routes to the stub worker (BH-2637),
# and serves the migrations status.
cat > "$T/bin/curl" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls/curl"
"$(dirname "$0")/wcs-routes" "$@" && exit 0
case "$*" in
  *"/api/internal/migrations/status"*) printf '{"pending":[],"applied":[]}'; exit 0 ;;
  # TEST-CHANGE BH-4153: paused-*/automerge-disabled* are rows read DB-first now,
  # and the `{}` 200 below is an unreadable flag answer that fails closed (the
  # lane stands down on a pause nobody set). No such row exists here: 404 = off.
  *"/api/flags/"*) printf '{"error":"not found"}\n404'; exit 0 ;;
esac
printf '{}\n200'
SH
chmod +x "$T/bin/curl"

# ssh records its argv — nothing may call it any more (BH-2637).
cat > "$T/bin/ssh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls/ssh"
SH
chmod +x "$T/bin/ssh"

# lane_runs_here's real dependency is `crontab -l` (the root user crontab).
cat > "$T/bin/crontab" <<'SH'
#!/bin/bash
[ "${1:-}" = "-l" ] || exit 1
[ -r "$HARNESS/crontab.out" ] || exit 1
cat "$HARNESS/crontab.out"
SH
chmod +x "$T/bin/crontab"

# gh: the loop's closed_diff may call it, and the real migration-autopilot asks
# it for merged PRs. An empty list ends that lane's discovery immediately.
cat > "$T/bin/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls/gh"
echo '[]'
SH
chmod +x "$T/bin/gh"

# setsid makes launches synchronous so the test can assert immediately.
cat > "$T/bin/setsid" <<'SH'
#!/bin/bash
exec "$@"
SH
chmod +x "$T/bin/setsid"

cat > "$T/bin/beat.sh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls/beat"
SH
chmod +x "$T/bin/beat.sh"

W() { printf '{"id":%s,"repo":"%s","kind":"%s","key":"%s","event":"%s","at":"2026-09-19T11:39:04Z"}' "$1" "${2:-example-org/project-3}" "$3" "${4:-key}" "${5:-deployment_status.created}"; }
wakes() { printf '{"wakes":[%s]}' "$(printf '%s,' "$@" | sed 's/,$//')" > "$T/wakes.json"; }
reset() {
  rm -rf "$T/calls" "$T/state" "$T/flags" "$T/logs"
  mkdir -p "$T/calls" "$T/state" "$T/flags" "$T/logs" "$T/locks"
}
settle() {
  local prev="" cur i
  for i in $(seq 1 12); do
    sleep 0.25
    cur=$(cat "$T/calls/"* 2>/dev/null | wc -c | tr -d ' ')
    [ "$cur" = "$prev" ] && [ "$i" -ge 2 ] && return 0
    prev="$cur"
  done
  return 0
}
# run [box] — the loop as <box> (default: project-3's owning box).
run() { BOX_NAME="${1:-$project-3BOX}" PATH="$T/fakebin:$T/bin:$PATH" "$T/bin/wake-loop.sh"; RC=$?; settle; return "$RC"; }
# run_hub_misfiltered — the hub, against a worker that hands it EVERY row
# (CLAIM_ALL), so the loop's own ownership guard is what is exercised.
run_hub_misfiltered() { rm -rf "$T/calls" "$T/logs"; mkdir -p "$T/calls" "$T/logs"; CLAIM_ALL=1 run "$HUB"; }
LOG() { cat "$T/logs/wake-loop.log" 2>/dev/null; }
REFUSED='migration-autopilot\[project-3\]: hub lane — the hub.s loop takes it'
hub_claim_repos() { wcs_log | awk '$1=="POST" && $2=="/api/wakes/claim" { $1=""; $2=""; print }' | jq -c 'select(.box=="box-hub") | .repos' | head -1; }
calls() { [ -f "$T/calls/$1" ] && wc -l < "$T/calls/$1" | tr -d ' ' || echo 0; }
CRON_AUTOPILOT='* * * * * /root/harness/bin/migration-autopilot.sh project-3'
CRON_OTHER='* * * * * /root/harness/bin/something-else.sh project-3'

# ---------------------------------------------------------------------------
# 1. flag on, one deploy row, run as the OWNING box: the one-shot file carries
#    the sha and apply-migrations launches LOCALLY with WAKE_LAUNCH=1. Then the
#    hub, whose crontab names migration-autopilot for project-3: it never takes
#    project-3's deploy row, so that lane is left to cron (BH-2637).
# ---------------------------------------------------------------------------
reset
touch "$T/flags/wake-lanes-deploy"
printf '%s\n' "$CRON_AUTOPILOT" > "$T/crontab.out"
wakes "$(W 1 example-org/project-3 deploy abc1234)"
run "$project-3BOX"
[ "$(cat "$T/state/deploy-wake-project-3" 2>/dev/null)" = "abc1234" ] && ok \
  || bad "state/deploy-wake-project-3 must hold the deployment sha (got '$(cat "$T/state/deploy-wake-project-3" 2>/dev/null)')"
# TEST-CHANGE BH-2637: the owning box refuses the hub-scoped migration-autopilot (was: the hub ran it locally off its crontab).
[ "$(calls migration-autopilot)" = 0 ] && LOG | grep -q "$REFUSED" && ok \
  || bad "the owning box must refuse migration-autopilot with the hub-lane line (got $(calls migration-autopilot)): $(LOG | tail -5)"
# TEST-CHANGE BH-2637: apply-migrations runs on the owning box itself, no ssh (was: exactly one ssh).
[ "$(calls apply-migrations)" = 1 ] && [ "$(calls ssh)" = 0 ] && ok \
  || bad "apply-migrations must launch once locally on the owning box, no ssh (got apply=$(calls apply-migrations) ssh=$(calls ssh))"
# TEST-CHANGE BH-2637: WAKE_LAUNCH=1 rides the local launch's environment, not an ssh argv.
grep -qx 'WAKE_LAUNCH=1' "$T/calls/apply-migrations.env" 2>/dev/null && ok || bad "the local apply-migrations must run with WAKE_LAUNCH=1"
# TEST-CHANGE BH-2637: the project is apply-migrations.sh's own argv, not part of an ssh command.
grep -qx 'project-3' "$T/calls/apply-migrations" 2>/dev/null && ok || bad "apply-migrations argv must be 'project-3'"
[ "$(calls postmerge-qa)" = 1 ] && ok || bad "the loop's own deploy -> postmerge-qa launch must be untouched (got $(calls postmerge-qa))"
run_hub_misfiltered
# TEST-CHANGE BH-2637: the hub's claim never asks for project-3's repo (was: the hub ran migration-autopilot project-3 itself).
[ "$(hub_claim_repos)" = '["example-org/cromford"]' ] && ok \
  || bad "the hub's claim must name only its own repo (got $(hub_claim_repos))"
# TEST-CHANGE BH-2637: handed the row anyway, the hub drops it and launches nothing for project-3, over ssh or here, crontab or not.
LOG | grep -q 'another box owns the repo — example-org/project-3' && [ "$(calls migration-autopilot)" = 0 ] \
  && [ "$(calls apply-migrations)" = 0 ] && [ "$(calls ssh)" = 0 ] && ok \
  || bad "the hub must drop project-3's deploy row and launch nothing (ma=$(calls migration-autopilot) apply=$(calls apply-migrations) ssh=$(calls ssh)): $(LOG | tail -5)"
grep -q 'migration-autopilot' "$T/calls/ssh" 2>/dev/null && bad "migration-autopilot must not also travel by ssh" || ok

# ---------------------------------------------------------------------------
# 2. flag on, crontab does NOT name migration-autopilot: the owning box
#    launches apply-migrations locally and refuses the hub lane; nothing
#    travels anywhere (BH-2637: no ssh).
# ---------------------------------------------------------------------------
reset
touch "$T/flags/wake-lanes-deploy"
printf '%s\n' "$CRON_OTHER" > "$T/crontab.out"
wakes "$(W 2 example-org/project-3 deploy abc2222)"
run "$project-3BOX"
[ "$(calls migration-autopilot)" = 0 ] && ok || bad "migration-autopilot must not run locally when cron does not name it (got $(calls migration-autopilot))"
# TEST-CHANGE BH-2637: neither lane travels; apply-migrations runs here once (was: both lanes ssh).
[ "$(calls ssh)" = 0 ] && [ "$(calls apply-migrations)" = 1 ] && ok \
  || bad "no ssh, one local apply-migrations (got ssh=$(calls ssh) apply=$(calls apply-migrations))"
# TEST-CHANGE BH-2637: migration-autopilot is refused on the owning box with the hub-lane line (was: its ssh line targeted project-3-2).
LOG | grep -q "$REFUSED" && ok || bad "the owning box must log the migration-autopilot refusal: $(LOG | tail -5)"
run_hub_misfiltered
# TEST-CHANGE BH-2637: the hub does not carry migration-autopilot to project-3 either — no launch, no ssh.
[ "$(calls migration-autopilot)" = 0 ] && [ "$(calls ssh)" = 0 ] && ok \
  || bad "the hub must launch no migration-autopilot for project-3 and ssh nowhere (ma=$(calls migration-autopilot) ssh=$(calls ssh))"

# ---------------------------------------------------------------------------
# 3. two deploy rows for one project in one drain: last sha wins, one launch each.
# ---------------------------------------------------------------------------
reset
touch "$T/flags/wake-lanes-deploy"
printf '%s\n' "$CRON_AUTOPILOT" > "$T/crontab.out"
wakes "$(W 3 example-org/project-3 deploy aaaa111)" "$(W 4 example-org/project-3 deploy bbbb222)"
run "$project-3BOX"
[ "$(cat "$T/state/deploy-wake-project-3" 2>/dev/null)" = "bbbb222" ] && ok \
  || bad "the last deploy row's sha must win (got '$(cat "$T/state/deploy-wake-project-3" 2>/dev/null)')"
# TEST-CHANGE BH-2637: two rows still collapse — onto ONE refusal line, since the owning box never launches the hub lane.
[ "$(calls migration-autopilot)" = 0 ] && [ "$(LOG | grep -c "$REFUSED")" = 1 ] && ok \
  || bad "two rows: no migration-autopilot, one refusal line (got $(calls migration-autopilot), $(LOG | grep -c "$REFUSED") lines)"
# TEST-CHANGE BH-2637: two rows still launch apply-migrations once — locally, no ssh.
[ "$(calls apply-migrations)" = 1 ] && [ "$(calls ssh)" = 0 ] && ok \
  || bad "two rows must still launch apply-migrations once, locally (got apply=$(calls apply-migrations) ssh=$(calls ssh))"
[ "$(calls postmerge-qa)" = 1 ] && ok || bad "two rows must still launch postmerge-qa once (got $(calls postmerge-qa))"

# ---------------------------------------------------------------------------
# 4. flag OFF -> nothing new, and the legacy deploy launch is untouched.
# ---------------------------------------------------------------------------
reset
printf '%s\n' "$CRON_AUTOPILOT" > "$T/crontab.out"
wakes "$(W 5 example-org/project-3 deploy cccc333)"
run "$project-3BOX"
[ -e "$T/state/deploy-wake-project-3" ] && bad "flag off: no deploy-wake file" || ok
[ "$(calls migration-autopilot)" = 0 ] && ok || bad "flag off: no migration-autopilot (got $(calls migration-autopilot))"
[ "$(calls ssh)" = 0 ] && ok || bad "flag off: no ssh (got $(calls ssh))"
[ "$(calls postmerge-qa)" = 1 ] && ok || bad "flag off: postmerge-qa still launched once (got $(calls postmerge-qa))"

# ---------------------------------------------------------------------------
# 5. kill switch flags/wake-lanes-off outranks the class flag.
# ---------------------------------------------------------------------------
reset
touch "$T/flags/wake-lanes-deploy" "$T/flags/wake-lanes-off"
printf '%s\n' "$CRON_AUTOPILOT" > "$T/crontab.out"
wakes "$(W 6 example-org/project-3 deploy dddd444)"
run "$project-3BOX"
[ -e "$T/state/deploy-wake-project-3" ] && bad "wake-lanes-off: no deploy-wake file" || ok
[ "$(calls migration-autopilot)" = 0 ] && ok || bad "wake-lanes-off: no migration-autopilot (got $(calls migration-autopilot))"
[ "$(calls ssh)" = 0 ] && ok || bad "wake-lanes-off: no ssh (got $(calls ssh))"
[ "$(calls postmerge-qa)" = 1 ] && ok || bad "wake-lanes-off: postmerge-qa still launched once (got $(calls postmerge-qa))"

# ---------------------------------------------------------------------------
# 6. adversarial negative: a push row with the deploy flag on drives nothing here.
# ---------------------------------------------------------------------------
reset
touch "$T/flags/wake-lanes-deploy"
printf '%s\n' "$CRON_AUTOPILOT" > "$T/crontab.out"
wakes "$(W 7 example-org/project-3 push eeee555 push)"
run "$project-3BOX"
[ -e "$T/state/deploy-wake-project-3" ] && bad "a push row must not write a deploy-wake file" || ok
[ "$(calls migration-autopilot)" = 0 ] && ok || bad "a push row must not launch migration-autopilot (got $(calls migration-autopilot))"
grep -q 'apply-migrations' "$T/calls/ssh" 2>/dev/null && bad "a push row must not launch apply-migrations" || ok

# ---------------------------------------------------------------------------
# 7. accumulators reset after dispatch. drain() calls EVERY armed class's
#    dispatch on every non-empty poll, so a class that keeps its list re-fires
#    every stale project forever. Exercised directly with cooled()/
#    remote_launch() stubbed, so the assertion is not masked by cooled's own
#    window the way a second real drain would be.
# ---------------------------------------------------------------------------
reset
H="$T"; SELF="$T/bin"
# shellcheck source=/dev/null
. "$DIR/bin/lib/wake-class-deploy.sh" 2>/dev/null || true
if command -v wc_deploy_row >/dev/null 2>&1; then
  cooled() { return 0; }
  remote_launch() { echo "$*" >> "$T/calls/dispatch-remote"; }
  wc_deploy_row project-3 deploy k1 deployment_status.created example-org/project-3 1
  wc_deploy_dispatch
  [ "$(calls dispatch-remote)" = 2 ] && ok || bad "first dispatch must remote_launch both lanes (got $(calls dispatch-remote))"
  [ "$(cat "$T/state/deploy-wake-project-3" 2>/dev/null)" = "k1" ] && ok || bad "first dispatch must write the one-shot"
  rm -f "$T/state/deploy-wake-project-3"
  before_remote=$(calls dispatch-remote)
  wc_deploy_dispatch
  [ "$(calls dispatch-remote)" = "$before_remote" ] && ok || bad "empty dispatch must not re-fire (got $(calls dispatch-remote), was $before_remote)"
  [ -e "$T/state/deploy-wake-project-3" ] && bad "empty dispatch must not re-write the one-shot" || ok
  unset -f cooled remote_launch
else
  bad "bin/lib/wake-class-deploy.sh must define wc_deploy_row/wc_deploy_dispatch"
  bad "bin/lib/wake-class-deploy.sh must define wc_deploy_row/wc_deploy_dispatch (one-shot)"
  bad "bin/lib/wake-class-deploy.sh must define wc_deploy_row/wc_deploy_dispatch (reset)"
  bad "bin/lib/wake-class-deploy.sh must define wc_deploy_row/wc_deploy_dispatch (no re-write)"
fi

# ---------------------------------------------------------------------------
# --- second half: the REAL lane scripts, run against this scratch $HARNESS ---
# Copied into $T/bin so their own sibling sourcing ($BIN/jobs-client.sh,
# $BIN/fleet-conf.sh) resolves to the stubs above rather than to the live box.
# ---------------------------------------------------------------------------
cp "$DIR/bin/apply-migrations.sh"    "$T/bin/real-apply-migrations.sh"
cp "$DIR/bin/migration-autopilot.sh" "$T/bin/real-migration-autopilot.sh"
chmod +x "$T/bin/real-apply-migrations.sh" "$T/bin/real-migration-autopilot.sh"
real_apply() { ( PATH="$T/bin:$PATH" HARNESS="$T" "$@" ) >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# 8. cron tick + flag on + fresh stamp -> skipped before the API is asked, and
#    ONE line in logs/wake-backstop.log naming the 3600s window.
# ---------------------------------------------------------------------------
reset
touch "$T/flags/wake-lanes-deploy"
mkdir -p "$T/state/wake-ran"
date +%s > "$T/state/wake-ran/apply-migrations-project-3"
real_apply "$T/bin/real-apply-migrations.sh" project-3
RC_SKIP=$?
[ "$RC_SKIP" = 0 ] && ok || bad "a skipped cron tick must exit 0 (got $RC_SKIP)"
grep -q '/api/internal/migrations' "$T/calls/curl" 2>/dev/null && bad "a skipped cron tick must not call the migrations API" || ok
[ "$(grep -c '^apply-migrations\[project-3\]: cron tick skipped .*(backstop 3600s)$' "$T/logs/wake-backstop.log" 2>/dev/null)" = 1 ] && ok \
  || bad "exactly one wake-backstop.log line with the 3600s window (got: $(cat "$T/logs/wake-backstop.log" 2>/dev/null))"

# ---------------------------------------------------------------------------
# 9. the same fresh stamp, but a --files caller: NEVER skipped (BH-375 hotfix lane).
# ---------------------------------------------------------------------------
reset
touch "$T/flags/wake-lanes-deploy"
mkdir -p "$T/state/wake-ran"
date +%s > "$T/state/wake-ran/apply-migrations-project-3"
real_apply "$T/bin/real-apply-migrations.sh" project-3 --files x.sql
grep -q '/api/internal/migrations' "$T/calls/curl" 2>/dev/null && ok || bad "a --files caller must still reach the migrations API"

# ---------------------------------------------------------------------------
# 10. WAKE_LAUNCH=1 is never skipped, and it is the run that stamps.
# ---------------------------------------------------------------------------
reset
touch "$T/flags/wake-lanes-deploy"
mkdir -p "$T/state/wake-ran"
NOW=$(date +%s)
printf '%s' "$(( NOW - 1000 ))" > "$T/state/wake-ran/apply-migrations-project-3"
( PATH="$T/bin:$PATH" HARNESS="$T" WAKE_LAUNCH=1 "$T/bin/real-apply-migrations.sh" project-3 ) >/dev/null 2>&1
grep -q '/api/internal/migrations' "$T/calls/curl" 2>/dev/null && ok || bad "WAKE_LAUNCH=1 must run the lane"
NEW_STAMP=$(tr -dc '0-9' < "$T/state/wake-ran/apply-migrations-project-3" 2>/dev/null); NEW_STAMP="${NEW_STAMP:-0}"
[ "$NEW_STAMP" -ge "$NOW" ] && ok || bad "WAKE_LAUNCH=1 must refresh the apply-migrations stamp (was $(( NOW - 1000 )), now $NEW_STAMP)"

# ---------------------------------------------------------------------------
# 11. the real migration-autopilot: fresh stamp -> skipped before `gh pr list`;
#     WAKE_LAUNCH=1 -> the lane runs and re-stamps.
# ---------------------------------------------------------------------------
reset
touch "$T/flags/wake-lanes-deploy"
mkdir -p "$T/state/wake-ran"
date +%s > "$T/state/wake-ran/migration-autopilot-project-3"
real_apply "$T/bin/real-migration-autopilot.sh" project-3
RC_MA=$?
[ "$RC_MA" = 0 ] && ok || bad "a skipped migration-autopilot tick must exit 0 (got $RC_MA)"
[ "$(calls gh)" = 0 ] && ok || bad "a skipped migration-autopilot tick must not reach gh (got $(calls gh))"

reset
touch "$T/flags/wake-lanes-deploy"
mkdir -p "$T/state/wake-ran"
NOW2=$(date +%s)
printf '%s' "$(( NOW2 - 1000 ))" > "$T/state/wake-ran/migration-autopilot-project-3"
( PATH="$T/bin:$PATH" HARNESS="$T" WAKE_LAUNCH=1 "$T/bin/real-migration-autopilot.sh" project-3 ) >/dev/null 2>&1
[ "$(calls gh)" -ge 1 ] && ok || bad "WAKE_LAUNCH=1 must let migration-autopilot reach gh (got $(calls gh))"
MA_STAMP=$(tr -dc '0-9' < "$T/state/wake-ran/migration-autopilot-project-3" 2>/dev/null); MA_STAMP="${MA_STAMP:-0}"
[ "$MA_STAMP" -ge "$NOW2" ] && ok || bad "WAKE_LAUNCH=1 must refresh the migration-autopilot stamp (was $(( NOW2 - 1000 )), now $MA_STAMP)"

# ---------------------------------------------------------------------------
echo "wake-deploy-drives-lanes.bh-1062-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
