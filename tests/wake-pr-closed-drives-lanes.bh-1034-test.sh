#!/bin/bash
# tests/wake-pr-closed-drives-lanes.bh-1034-test.sh — the `pr-closed` wake class
# (bin/lib/wake-class-pr-closed.sh) driven through the REAL bin/wake-loop.sh,
# plus the backstop paste in the REAL bin/reconcile-prs.sh.
#
# reconcile-prs, check-migration-prs and alerts-groom are fleet lanes (the
# hub's), so the loop runs as the hub (box-hub), which claims every
# repo's pr rows (BH-2637). The worker is tests/lib/wake-claim-stub.sh.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/wake-pr-closed-drives-lanes.bh-1034-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/wake-claim-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HARNESS="$T"
mkdir -p "$T/bin" "$T/bin/lib" "$T/env" "$T/logs" "$T/locks" "$T/state" "$T/flags" "$T/calls"
printf 'HARNESS_SECRET=s\nJOBS_URL=https://jobs.test\n' > "$T/env/global.env"
export WAKE_LOOP_CYCLES=1 WAKE_LOOP_INTERVAL_S=0
unset WAKE_CLAIM_LIMIT HUB_BOX_NAME CLAIM_ALL COOL_MODE CLAIM_MODE CURSOR_PUT_MODE CURSOR_GET_MODE
export BOX_NAME=box-hub

# The real loop, the real lib, and the real class file under test.
cp "$DIR/bin/wake-loop.sh"      "$T/bin/wake-loop.sh"
cp "$DIR/bin/lib/wake-lanes.sh" "$T/bin/lib/wake-lanes.sh"
cp "$DIR/bin/lib/wake-class-pr-closed.sh" "$T/bin/lib/wake-class-pr-closed.sh"

# The REAL jobs-client: the wake routes go to the stub worker, and flag_active
# reads flags/<name> (the flag sync's `{}` answer leaves the files alone).
mkdir -p "$T/bin/lib/jobs"
cp "$DIR/bin/jobs-client.sh" "$T/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
wcs_install "$T/bin"
wcs_identity "$T/bin" || { echo "wcs_identity failed"; exit 1; }

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

# bin/box-for.sh is the REAL one (wcs_identity), answering the box column above.

cat > "$T/bin/unblocked-children.sh" <<'SH'
#!/bin/bash
exit 1
SH
chmod +x "$T/bin/unblocked-children.sh"

# Recorders: the legacy lanes, plus the three lanes this class launches.
for s in merge-conductor deploy-train postmerge-qa run-triage \
         reconcile-prs check-migration-prs alerts-groom alerts-resolve-closed-prs; do
  cat > "$T/bin/$s.sh" <<SH
#!/bin/bash
echo "\$*" >> "\$HARNESS/calls/$s"
SH
  chmod +x "$T/bin/$s.sh"
done

# curl: record every call; every wake route is the stub worker's.
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
run() { "$T/bin/wake-loop.sh"; RC=$?; settle; return "$RC"; }
calls() { [ -f "$T/calls/$1" ] && wc -l < "$T/calls/$1" | tr -d ' ' || echo 0; }

# ---------------------------------------------------------------------------
# 1. flag on + one pull_request.closed row -> each of the three lanes once
# ---------------------------------------------------------------------------
reset; touch "$T/flags/wake-lanes-pr-closed"
wakes "$(W 1 pr 272 example-org/project-3 pull_request.closed)"
run
[ "$(calls reconcile-prs)" = 1 ]       && ok || bad "closed row: reconcile-prs once (got $(calls reconcile-prs))"
[ "$(calls check-migration-prs)" = 1 ] && ok || bad "closed row: check-migration-prs once (got $(calls check-migration-prs))"
[ "$(calls alerts-groom)" = 1 ]        && ok || bad "closed row: alerts-groom once (got $(calls alerts-groom))"
[ "$(calls merge-conductor)" = 1 ]     && ok || bad "closed row: conductor still once (got $(calls merge-conductor))"
# 1b (V1 alert hygiene): the closed PR itself is handed to the resolver, so the
# alerts about it being stuck close in this drain, not on the groomer's 2h cron.
[ "$(cat "$T/calls/alerts-resolve-closed-prs" 2>/dev/null)" = "example-org/project-3#272" ] \
  && ok || bad "1b: alerts-resolve-closed-prs must get the closed PR (got '$(cat "$T/calls/alerts-resolve-closed-prs" 2>/dev/null)')"

# ---------------------------------------------------------------------------
# 2. three closed rows across two projects in one drain -> still one each
# ---------------------------------------------------------------------------
reset; touch "$T/flags/wake-lanes-pr-closed"
wakes "$(W 10 pr 272 example-org/project-3 pull_request.closed)" \
      "$(W 11 pr 273 example-org/project-3 pull_request.closed)" \
      "$(W 12 pr 44 example-org/project-5 pull_request.closed)"
run
[ "$(calls reconcile-prs)" = 1 ]       && ok || bad "three closed rows: reconcile-prs once (got $(calls reconcile-prs))"
[ "$(calls check-migration-prs)" = 1 ] && ok || bad "three closed rows: check-migration-prs once (got $(calls check-migration-prs))"
[ "$(calls alerts-groom)" = 1 ]        && ok || bad "three closed rows: alerts-groom once (got $(calls alerts-groom))"
# 2b: ONE resolver launch per drain, carrying every closed PR.
[ "$(calls alerts-resolve-closed-prs)" = 1 ] && [ "$(cat "$T/calls/alerts-resolve-closed-prs")" = "example-org/project-3#272 example-org/project-3#273 example-org/project-5#44" ] \
  && ok || bad "2b: one resolver launch with all three PRs (got '$(cat "$T/calls/alerts-resolve-closed-prs" 2>/dev/null)')"

# ---------------------------------------------------------------------------
# 3. a pull_request.synchronize row is not a closure
# ---------------------------------------------------------------------------
reset; touch "$T/flags/wake-lanes-pr-closed"
wakes "$(W 20 pr 272 example-org/project-3 pull_request.synchronize)"
run
[ ! -f "$T/calls/reconcile-prs" ] && [ ! -f "$T/calls/check-migration-prs" ] && [ ! -f "$T/calls/alerts-groom" ] \
  && ok || bad "synchronize row must launch none of the pr-closed lanes"
[ ! -f "$T/calls/alerts-resolve-closed-prs" ] && ok || bad "3b: a synchronize row must not resolve anything"

# ---------------------------------------------------------------------------
# 4. a bare pull_request row (no action suffix) is not a closure
# ---------------------------------------------------------------------------
reset; touch "$T/flags/wake-lanes-pr-closed"
wakes "$(W 30 pr 272 example-org/project-3 pull_request)"
run
[ ! -f "$T/calls/reconcile-prs" ] && [ ! -f "$T/calls/check-migration-prs" ] && [ ! -f "$T/calls/alerts-groom" ] \
  && ok || bad "bare pull_request row must launch none of the pr-closed lanes"

# ---------------------------------------------------------------------------
# 5. flag off -> nothing new, and the legacy conductor count is unchanged
# ---------------------------------------------------------------------------
reset
wakes "$(W 40 pr 272 example-org/project-3 pull_request.closed)"
run
[ ! -f "$T/calls/reconcile-prs" ] && [ ! -f "$T/calls/check-migration-prs" ] && [ ! -f "$T/calls/alerts-groom" ] \
  && ok || bad "flag off must launch none of the pr-closed lanes"
[ "$(calls merge-conductor)" = 1 ] && ok || bad "flag off: conductor still once (got $(calls merge-conductor))"

# ---------------------------------------------------------------------------
# The REAL bin/reconcile-prs.sh and its backstop paste.
# ---------------------------------------------------------------------------
cp "$DIR/bin/reconcile-prs.sh" "$T/bin/reconcile-prs.sh"
chmod +x "$T/bin/reconcile-prs.sh"
# BH-1583: the lane runs only on the reconcile owner and reads its knobs with no
# literal; this fixture box is armed as the owner (tests/lib/reconcile-fixture.sh).
. "$(dirname "$0")/lib/reconcile-fixture.sh" || exit 1
rcfx_arm "$T" "$DIR" || exit 1
printf 'CONSOLE_URL=https://console.test\nHARNESS_SECRET=s\n' >> "$T/env/global.env"
NOW=$(date +%s)
unmerged() {
  local n
  n=$(grep -c '/api/builds/unmerged' "$T/calls/curl" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# 6. the class flag on + a fresh stamp + no WAKE_LAUNCH -> skip, rc 0, no console read.
# 120s is fresh under the lane's own 300s override (BH-1292) and stale under
# the 60s a project lane would use.
reset; mkdir -p "$T/state/wake-ran"
touch "$T/flags/wake-lanes-pr-closed"
echo $((NOW-120)) > "$T/state/wake-ran/reconcile-prs-fleet"
( unset WAKE_LAUNCH; "$T/bin/reconcile-prs.sh" >/dev/null 2>&1 ); RC=$?
[ "$RC" = 0 ] && ok || bad "fresh stamp: reconcile-prs must exit 0 (got $RC)"
[ "$(unmerged)" = 0 ] && ok || bad "fresh stamp: reconcile-prs must not read the console (got $(unmerged))"

# 7. a stamp older than the 1800s default window -> the lane runs
reset; mkdir -p "$T/state/wake-ran"
touch "$T/flags/wake-lanes-pr-closed"
echo $((NOW-1801)) > "$T/state/wake-ran/reconcile-prs-fleet"
( unset WAKE_LAUNCH; "$T/bin/reconcile-prs.sh" >/dev/null 2>&1 )
[ "$(unmerged)" -ge 1 ] && ok || bad "stale stamp: reconcile-prs must read the console"

# 8. the class flag absent -> the paste falls open even with a fresh stamp
reset; mkdir -p "$T/state/wake-ran"
echo $((NOW-60)) > "$T/state/wake-ran/reconcile-prs-fleet"
( unset WAKE_LAUNCH; "$T/bin/reconcile-prs.sh" >/dev/null 2>&1 )
[ "$(unmerged)" -ge 1 ] && ok || bad "flag off: reconcile-prs must read the console"

# 9. WAKE_LAUNCH=1 always runs and re-stamps
reset; mkdir -p "$T/state/wake-ran"
touch "$T/flags/wake-lanes-pr-closed"
echo $((NOW-60)) > "$T/state/wake-ran/reconcile-prs-fleet"
WAKE_LAUNCH=1 "$T/bin/reconcile-prs.sh" >/dev/null 2>&1
[ "$(unmerged)" -ge 1 ] && ok || bad "WAKE_LAUNCH=1: reconcile-prs must read the console"
STAMPED=$(tr -dc '0-9' < "$T/state/wake-ran/reconcile-prs-fleet" 2>/dev/null)
[ -n "$STAMPED" ] && [ "$STAMPED" -ge "$NOW" ] && ok \
  || bad "WAKE_LAUNCH=1 must re-stamp state/wake-ran/reconcile-prs-fleet (got '${STAMPED:-}')"

# 10. WAKE_BACKSTOP_S from the environment still overrides the paste
reset; mkdir -p "$T/state/wake-ran"
touch "$T/flags/wake-lanes-pr-closed"
echo $((NOW-300)) > "$T/state/wake-ran/reconcile-prs-fleet"
( unset WAKE_LAUNCH; WAKE_BACKSTOP_S=60 "$T/bin/reconcile-prs.sh" >/dev/null 2>&1 )
[ "$(unmerged)" -ge 1 ] && ok || bad "env WAKE_BACKSTOP_S=60 must shrink the window and let the lane run"

# ---------------------------------------------------------------------------
# 11. the class resets its accumulator: a second dispatch launches nothing
# ---------------------------------------------------------------------------
reset
(
  SELF="$T/bin"
  cooled() { return 0; }
  launch() { echo "$*" >> "$T/calls/unit-launch"; }
  say()    { :; }
  # shellcheck source=bin/lib/wake-class-pr-closed.sh
  . "$DIR/bin/lib/wake-class-pr-closed.sh" 2>/dev/null || exit 0
  wc_pr_closed_row project-3 pr 272 pull_request.closed example-org/project-3 1
  wc_pr_closed_dispatch
  mv "$T/calls/unit-launch" "$T/calls/unit-launch-1" 2>/dev/null
  wc_pr_closed_dispatch
)
# Three lanes plus (V1 alert hygiene) the closed-PR resolver; the second dispatch
# below proves BOTH accumulators reset.
# TEST-CHANGE (BH-3997): 4 -> 5. A closed PR also launches the merge-alerts
# resolver (bin/alerts-merge-resolve.sh --closed …), so pipeline-health's
# awaiting-merge rows naming it settle in the same drain.
# TEST-CHANGE (BH-4055): 5 -> 6. A closed PR also launches pipeline-health's
# PR sections (pipeline-health.sh --sections stalepr,leadunqueued), last, so its
# ph-stalepr / ph-leadunqueued rows retract in the same drain.
[ "$(calls unit-launch-1)" = 6 ] && ok || bad "first dispatch must launch three lanes + the two resolvers + the pipeline-health sections run (got $(calls unit-launch-1))"
tail -1 "$T/calls/unit-launch-1" 2>/dev/null | grep -q 'pipeline-health.sh --sections stalepr,leadunqueued$' \
  && ok || bad "the last launch must be the pipeline-health sections run: $(cat "$T/calls/unit-launch-1" 2>/dev/null)"
grep -q 'alerts-resolve-closed-prs.sh example-org/project-3#272$' "$T/calls/unit-launch-1" 2>/dev/null \
  && ok || bad "the resolver launch must carry the closed PR: $(cat "$T/calls/unit-launch-1" 2>/dev/null)"
[ ! -f "$T/calls/unit-launch" ] && ok || bad "second dispatch must launch nothing — the accumulator is not reset"

# ---------------------------------------------------------------------------
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
