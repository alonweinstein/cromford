#!/bin/bash
# tests/wake-ci-drives-review.bh-1034-test.sh — the `pr-ci` wake class
# (bin/lib/wake-class-pr-ci.sh) driven through the REAL bin/wake-loop.sh, plus
# the backstop paste in the REAL bin/tickets-snapshot-push.sh.
# Since BH-2637 the loop runs on EVERY box and claims its own wake rows through
# the stub worker (tests/lib/wake-claim-stub.sh), with the REAL jobs-client,
# box-name.sh and box-for.sh. project-3 is `local` (the hub, box-hub);
# project-5 is box-project-5-1's. Another box's project is never
# reached over ssh: its OWN loop launches review-prs locally, and the hub only
# logs that the project is owned elsewhere.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/wake-ci-drives-review.bh-1034-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HARNESS="$T"
mkdir -p "$T/bin" "$T/bin/lib" "$T/env" "$T/logs" "$T/locks" "$T/state" "$T/flags" "$T/calls"
printf 'HARNESS_SECRET=s\nJOBS_URL=https://jobs.test\n' > "$T/env/global.env"
export WAKE_LOOP_CYCLES=1 WAKE_LOOP_INTERVAL_S=0

# The real loop, the real lib, and the real class file under test.
cp "$DIR/bin/wake-loop.sh"      "$T/bin/wake-loop.sh"
cp "$DIR/bin/lib/wake-lanes.sh" "$T/bin/lib/wake-lanes.sh"
# BH-1511.1: the lib's default window (WAKE_BACKSTOP_S, 1800) is a registry knob
# now, read through bin/lib/lane-gate.sh's lib_env_apply — so the scratch
# harness carries the gate library and this repo's own rendered registry.
cp "$DIR/bin/lib/lane-gate.sh" "$T/bin/lib/lane-gate.sh"
. "$(dirname "$0")/lib/rendered.sh" || exit 1
export LANE_REGISTRY; LANE_REGISTRY=$(rendered_registry)
cp "$DIR/bin/lib/wake-class-pr-ci.sh" "$T/bin/lib/wake-class-pr-ci.sh"

# BH-2637: the REAL jobs-client (wakes_claim / wake_cursor_* / wake_cooldown_take
# go to the stub worker below). Its flag_active answers from flags/<name> when
# the flag sync gets `{}` back, which the curl below serves.
mkdir -p "$T/bin/lib/jobs"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
. "$(dirname "$0")/lib/wake-claim-stub.sh" || exit 1
wcs_install "$T/bin"

# Fleet registry: one local-box project and one remote-box project.
cat > "$T/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
[ "$1" = "--projects" ] && { printf 'project-3\nproject-5\n'; exit 0; }
case "$1/$2" in
  project-3/repo)   echo example-org/project-3 ;;
  project-5/repo) echo example-org/project-5 ;;
  project-3/box)    echo local ;;
  project-5/box)  echo box-project-5-1 ;;
  project-3/board_prefix)   echo /api/feature-board ;;
  project-5/board_prefix) echo - ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/bin/fleet-conf.sh"

# BH-2637: the REAL box-for.sh (reads the box column above), box-name.sh and
# hub-box.sh; LANE_REGISTRY stays the rendered registry set above.
wcs_identity "$T/bin" || { echo "wcs_identity failed"; exit 1; }
HUB=box-hub TSBOX=box-project-5-1

cat > "$T/bin/unblocked-children.sh" <<'SH'
#!/bin/bash
exit 1
SH
chmod +x "$T/bin/unblocked-children.sh"

# A registry reader for tickets-snapshot-push.sh: no board projects in scratch.
cat > "$T/bin/fleet-projects-or-alert.sh" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$T/bin/fleet-projects-or-alert.sh"

# Recorders: the legacy lanes, plus the three lanes this class launches.
# Each also notes the WAKE_LAUNCH it was started with, in calls/<lane>.env.
for s in merge-conductor deploy-train postmerge-qa run-triage \
         review-prs review-autopilot tickets-snapshot-push; do
  cat > "$T/bin/$s.sh" <<SH
#!/bin/bash
echo "\$*" >> "\$HARNESS/calls/$s"
echo "WAKE_LAUNCH=\${WAKE_LAUNCH:-}" >> "\$HARNESS/calls/$s.env"
SH
  chmod +x "$T/bin/$s.sh"
done

# curl: record every call, then the stub worker's wake routes (BH-2637), else {}.
cat > "$T/bin/curl" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls/curl"
"$(dirname "$0")/wcs-routes" "$@" && exit 0
printf '{}\n200'
SH
cat > "$T/bin/ssh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls/ssh"
SH
cat > "$T/bin/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls/gh"
echo '[]'
SH
cat > "$T/bin/setsid" <<'SH'
#!/bin/bash
exec "$@"
SH
cat > "$T/bin/flock" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$T/bin/curl" "$T/bin/ssh" "$T/bin/gh" "$T/bin/setsid" "$T/bin/flock"
export PATH="$T/bin:$PATH"

W() { printf '{"id":%s,"repo":"%s","kind":"%s","key":"%s","event":"%s","at":"2026-09-19T11:39:04Z"}' "$1" "${4:-example-org/project-3}" "$2" "$3" "${5:-ev}"; }
wakes() { printf '{"wakes":[%s]}' "$(printf '%s,' "$@" | sed 's/,$//')" > "$T/wakes.json"; }
reset() {
  rm -rf "$T/calls" "$T/state" "$T/flags" "$T/logs"
  mkdir -p "$T/calls" "$T/state" "$T/flags" "$T/logs"
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
# run [box] — the loop as <box> (default: the hub).
run() { BOX_NAME="${1:-$HUB}" "$T/bin/wake-loop.sh"; RC=$?; settle; return "$RC"; }
LOG() { cat "$T/logs/wake-loop.log" 2>/dev/null; }
calls() { [ -f "$T/calls/$1" ] && wc -l < "$T/calls/$1" | tr -d ' ' || echo 0; }

# ---------------------------------------------------------------------------
# 1. a check_suite.completed row for another box's project: that box's OWN loop
#    launches review-prs locally; the hub only logs the owner (BH-2637: no ssh)
# ---------------------------------------------------------------------------
reset; touch "$T/flags/wake-lanes-pr-ci"
wakes "$(W 1 checks abc1234 example-org/project-5 check_suite.completed)"
run "$TSBOX"
# TEST-CHANGE BH-2637: the owning box launches review-prs itself; was "exactly one ssh call" from the hub.
[ "$(calls review-prs)" = 1 ] && [ ! -f "$T/calls/ssh" ] && ok \
  || bad "checks row: the owning box launches review-prs once, no ssh (got review-prs=$(calls review-prs) ssh=$(calls ssh))"
# TEST-CHANGE BH-2637: WAKE_LAUNCH=1 now rides the local launch's environment, not an ssh argv.
grep -qx 'WAKE_LAUNCH=1' "$T/calls/review-prs.env" 2>/dev/null && ok || bad "checks row: the local review-prs must run with WAKE_LAUNCH=1"
# TEST-CHANGE BH-2637: the project is review-prs.sh's argv on the owning box, not in an ssh command.
grep -qx 'project-5' "$T/calls/review-prs" 2>/dev/null && ok || bad "checks row: the owning box must launch review-prs.sh project-5"
reset; touch "$T/flags/wake-lanes-pr-ci"
wakes "$(W 1 checks abc1234 example-org/project-5 check_suite.completed)"
run "$HUB"
# TEST-CHANGE BH-2637: the hub names the owning box in its log and never ssh's to it.
LOG | grep -q "review-prs\[project-5\]: owned by box-project-5-1" && [ ! -f "$T/calls/ssh" ] && ok \
  || bad "checks row on the hub: must log the owning box and not ssh (ssh=$(calls ssh)): $(LOG | tail -5)"
[ ! -f "$T/calls/review-prs" ] && ok || bad "checks row: the hub must never run another box's review-prs locally"
[ ! -f "$T/calls/tickets-snapshot-push" ] && ok || bad "checks row: a checks row must not set the snapshot bit"

# ---------------------------------------------------------------------------
# 2. a pull_request.synchronize row for a local-box project runs here
# ---------------------------------------------------------------------------
reset; touch "$T/flags/wake-lanes-pr-ci"
wakes "$(W 2 pr 272 example-org/project-3 pull_request.synchronize)"
run
[ "$(calls review-prs)" = 1 ] && ok || bad "synchronize row: review-prs once (got $(calls review-prs))"
grep -qx 'project-3' "$T/calls/review-prs" 2>/dev/null && ok || bad "synchronize row: review-prs must get the project"
[ ! -f "$T/calls/ssh" ] && ok || bad "synchronize row: a local box must not ssh"

# ---------------------------------------------------------------------------
# 3. pull_request.closed is a snapshot row, never a review row
# ---------------------------------------------------------------------------
reset; touch "$T/flags/wake-lanes-pr-ci"
wakes "$(W 3 pr 272 example-org/project-3 pull_request.closed)"
run
[ ! -f "$T/calls/review-prs" ] && ok || bad "closed row: no review-prs launch"
[ ! -f "$T/calls/ssh" ] && ok || bad "closed row: no ssh"
[ ! -f "$T/calls/review-autopilot" ] && ok || bad "closed row: no review-autopilot launch"
[ "$(calls tickets-snapshot-push)" = 1 ] && ok || bad "closed row: snapshot once (got $(calls tickets-snapshot-push))"

# ---------------------------------------------------------------------------
# 4. two checks rows for one project in one drain -> one launch
# ---------------------------------------------------------------------------
reset; touch "$T/flags/wake-lanes-pr-ci"
wakes "$(W 10 checks abc1234 example-org/project-5 check_suite.completed)" \
      "$(W 11 checks def5678 example-org/project-5 check_suite.completed)"
run "$TSBOX"
# TEST-CHANGE BH-2637: one LOCAL launch on the owning box, no ssh; was "exactly one ssh call".
[ "$(calls review-prs)" = 1 ] && [ ! -f "$T/calls/ssh" ] && ok \
  || bad "two checks rows: exactly one review-prs on the owning box, no ssh (got review-prs=$(calls review-prs) ssh=$(calls ssh))"

# ---------------------------------------------------------------------------
# 5. review-autopilot fires once per drain, whatever the project mix
# ---------------------------------------------------------------------------
reset; touch "$T/flags/wake-lanes-pr-ci"
wakes "$(W 20 checks abc1234 example-org/project-5 check_suite.completed)" \
      "$(W 21 pr 272 example-org/project-3 pull_request.opened)" \
      "$(W 22 pr 273 example-org/project-3 pull_request.reopened)"
run "$HUB"
[ "$(calls review-autopilot)" = 1 ] && ok || bad "two-project drain: review-autopilot once (got $(calls review-autopilot))"
[ "$(calls review-prs)" = 1 ] && grep -qx project-3 "$T/calls/review-prs" && ok || bad "two-project drain: one local review-prs, for project-3 (got $(calls review-prs))"
# TEST-CHANGE BH-2637: project-5's half is its own box's now — the hub logs the owner, ssh's nowhere,
# and box-project-5-1's loop (same table) launches its one review-prs locally.
LOG | grep -q "review-prs\[project-5\]: owned by box-project-5-1" && [ ! -f "$T/calls/ssh" ] && ok \
  || bad "two-project drain: the hub must log project-5's owner and not ssh (ssh=$(calls ssh)): $(LOG | tail -5)"
rm -f "$T/calls/review-prs" "$T/calls/review-prs.env" "$T/calls/review-autopilot"
# Its own cursor row, at 0 — without one it would adopt the hub's (now past 22).
printf 0 > "$T/state/wcs/cursor.$TSBOX"
run "$TSBOX"
[ "$(calls review-prs)" = 1 ] && grep -qx project-5 "$T/calls/review-prs" && [ ! -f "$T/calls/ssh" ] \
  && [ ! -f "$T/calls/review-autopilot" ] && ok \
  || bad "two-project drain: box-project-5-1 launches its own review-prs once and no hub lane (review-prs=$(calls review-prs) autopilot=$(calls review-autopilot) ssh=$(calls ssh))"

# ---------------------------------------------------------------------------
# 6. the snapshot bit: pr yes, issue yes, push no
# ---------------------------------------------------------------------------
reset; touch "$T/flags/wake-lanes-pr-ci"; wakes "$(W 30 pr 272)"
run
[ "$(calls tickets-snapshot-push)" = 1 ] && ok || bad "pr row: snapshot once (got $(calls tickets-snapshot-push))"
reset; touch "$T/flags/wake-lanes-pr-ci"; wakes "$(W 31 issue 41)"
run
[ "$(calls tickets-snapshot-push)" = 1 ] && ok || bad "issue row: snapshot once (got $(calls tickets-snapshot-push))"
reset; touch "$T/flags/wake-lanes-pr-ci"; wakes "$(W 32 push aaa1111)"
run
[ ! -f "$T/calls/tickets-snapshot-push" ] && ok || bad "push row must not set the snapshot bit"

# ---------------------------------------------------------------------------
# 7. flag off -> nothing new, legacy conductor unchanged
# ---------------------------------------------------------------------------
reset
wakes "$(W 40 checks abc1234 example-org/project-5 check_suite.completed)" "$(W 41 pr 272)"
run
[ ! -f "$T/calls/ssh" ] && [ ! -f "$T/calls/review-prs" ] \
  && [ ! -f "$T/calls/review-autopilot" ] && [ ! -f "$T/calls/tickets-snapshot-push" ] \
  && ok || bad "flag off must launch none of the pr-ci lanes"
[ "$(calls merge-conductor)" = 1 ] && ok || bad "flag off: conductor still once (got $(calls merge-conductor))"

# ---------------------------------------------------------------------------
# The REAL bin/tickets-snapshot-push.sh and its backstop paste.
# ---------------------------------------------------------------------------
cp "$DIR/bin/tickets-snapshot-push.sh" "$T/bin/tickets-snapshot-push.sh"
chmod +x "$T/bin/tickets-snapshot-push.sh"
# TEST-CHANGE: BH-3321 — an unset WATCHDOG_URL (or no lib) now stops the lane
# before it pushes, so both runs below carry one.
cp "$DIR/bin/lib/watchdog-url.sh" "$T/bin/lib/watchdog-url.sh"
NOW=$(date +%s)
pushed() {
  local n
  n=$(grep -c '/api/tickets-snapshot' "$T/calls/curl" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# 8. the class flag on + a fresh stamp + no WAKE_LAUNCH -> skip, rc 0, nothing pushed.
# 300s pins the window: fresh under the lib's 1800 default, stale under the
# 120s a project lane would use.
reset; mkdir -p "$T/state/wake-ran"
touch "$T/flags/wake-lanes-pr-ci"
echo $((NOW-300)) > "$T/state/wake-ran/tickets-snapshot-push-fleet"
( unset WAKE_LAUNCH; WATCHDOG_URL=http://watchdog.invalid "$T/bin/tickets-snapshot-push.sh" >/dev/null 2>&1 ); RC=$?
[ "$RC" = 0 ] && ok || bad "fresh stamp: tickets-snapshot-push must exit 0 (got $RC)"
[ "$(pushed)" = 0 ] && ok || bad "fresh stamp: tickets-snapshot-push must not push (got $(pushed))"
[ ! -f "$T/calls/gh" ] && ok || bad "fresh stamp: tickets-snapshot-push must not call gh"

# 9. WAKE_LAUNCH=1 always runs and re-stamps
reset; mkdir -p "$T/state/wake-ran"
touch "$T/flags/wake-lanes-pr-ci"
echo $((NOW-60)) > "$T/state/wake-ran/tickets-snapshot-push-fleet"
WAKE_LAUNCH=1 WATCHDOG_URL=http://watchdog.invalid "$T/bin/tickets-snapshot-push.sh" >/dev/null 2>&1
[ "$(pushed)" -ge 1 ] && ok || bad "WAKE_LAUNCH=1: tickets-snapshot-push must push"
STAMPED=$(tr -dc '0-9' < "$T/state/wake-ran/tickets-snapshot-push-fleet" 2>/dev/null)
[ -n "$STAMPED" ] && [ "$STAMPED" -ge "$NOW" ] && ok \
  || bad "WAKE_LAUNCH=1 must re-stamp state/wake-ran/tickets-snapshot-push-fleet (got '${STAMPED:-}')"

# ---------------------------------------------------------------------------
# 10. the class resets both accumulators: a second dispatch launches nothing
# ---------------------------------------------------------------------------
reset
(
  SELF="$T/bin"
  cooled() { return 0; }
  launch()        { echo "$*" >> "$T/calls/unit-launch"; }
  remote_launch() { echo "$*" >> "$T/calls/unit-remote"; }
  say()           { :; }
  # shellcheck source=bin/lib/wake-class-pr-ci.sh
  . "$DIR/bin/lib/wake-class-pr-ci.sh" 2>/dev/null || exit 0
  wc_pr_ci_row project-5 checks abc1234 check_suite.completed example-org/project-5 1
  wc_pr_ci_row project-3 pr 272 pull_request.opened example-org/project-3 2
  wc_pr_ci_dispatch
  mv "$T/calls/unit-launch" "$T/calls/unit-launch-1" 2>/dev/null
  mv "$T/calls/unit-remote" "$T/calls/unit-remote-1" 2>/dev/null
  wc_pr_ci_dispatch
)
[ "$(calls unit-remote-1)" = 2 ] && ok || bad "first dispatch must remote_launch both projects (got $(calls unit-remote-1))"
[ "$(calls unit-launch-1)" = 2 ] && ok || bad "first dispatch must launch autopilot and snapshot (got $(calls unit-launch-1))"
[ ! -f "$T/calls/unit-remote" ] && ok || bad "second dispatch must remote_launch nothing — WC_CI_PROJECTS is not reset"
[ ! -f "$T/calls/unit-launch" ] && ok || bad "second dispatch must launch nothing — the accumulators are not reset"

# ---------------------------------------------------------------------------
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
