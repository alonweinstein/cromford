#!/bin/bash
# tests/wake-pr-ci-suite-only.bh-1292-test.sh — BH-1292 I3: the `pr-ci` wake
# class counts only `check_suite.completed` among `checks` rows, so a CI run
# that finishes N jobs in N different minutes (N `check_run.completed` rows,
# one per run, deduped by the worker only per (repo,kind,key,minute)) no longer
# launches bin/review-prs.sh once per 120s cooldown for one sha.
# Driven through the REAL bin/wake-loop.sh + bin/lib/wake-class-pr-ci.sh.
# Since BH-2637 the loop runs on EVERY box and claims its own rows from the stub
# worker (tests/lib/wake-claim-stub.sh) through the REAL jobs-client, with the
# REAL box-name.sh / box-for.sh. project-5's review-prs is launched LOCALLY by
# box-project-5-1's own loop; nothing ssh's any more. project-3 is
# `local` (the hub, box-hub), which also runs the conductor.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/wake-pr-ci-suite-only.bh-1292-test.sh
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
cp "$DIR/bin/lib/wake-class-pr-ci.sh" "$T/bin/lib/wake-class-pr-ci.sh"

# BH-2637: the REAL jobs-client — wakes_claim / wake_cursor_* /
# wake_cooldown_take go to the stub worker, and flag_active answers from
# flags/<name> when the flag sync gets `{}` back (the curl below serves that).
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
# hub-box.sh, plus the rendered lane registry off-hub launches are checked against.
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
# Each also notes its WAKE_LAUNCH in calls/<lane>.env.
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
calls() { [ -f "$T/calls/$1" ] && wc -l < "$T/calls/$1" | tr -d ' ' || echo 0; }

# ---------------------------------------------------------------------------
# 1. a per-JOB check_run.completed row drives no review lane at all
# ---------------------------------------------------------------------------
reset; touch "$T/flags/wake-lanes-pr-ci"
wakes "$(W 1 checks abc1234 example-org/project-5 check_run.completed)"
# BH-2637: the owning box (which would launch review-prs locally) AND the hub.
run "$TSBOX"
run "$HUB"
[ ! -f "$T/calls/ssh" ] && ok || bad "check_run row: must not ssh review-prs to the owning box (got $(calls ssh))"
[ ! -f "$T/calls/review-prs" ] && ok || bad "check_run row: must not run review-prs (got $(calls review-prs))"
[ ! -f "$T/calls/review-autopilot" ] && ok || bad "check_run row: must not launch review-autopilot (got $(calls review-autopilot))"

# ---------------------------------------------------------------------------
# 2. a completed check SUITE still launches review-prs — on the owning box,
#    by that box's own loop (BH-2637: no longer an ssh from the hub)
# ---------------------------------------------------------------------------
reset; touch "$T/flags/wake-lanes-pr-ci"
wakes "$(W 2 checks abc1234 example-org/project-5 check_suite.completed)"
run "$TSBOX"
# TEST-CHANGE BH-2637: one LOCAL review-prs on the owning box and no ssh (was: exactly one ssh call).
[ "$(calls review-prs)" = 1 ] && [ ! -f "$T/calls/ssh" ] && ok \
  || bad "check_suite row: one local review-prs on the owning box, no ssh (got review-prs=$(calls review-prs) ssh=$(calls ssh))"
# TEST-CHANGE BH-2637: WAKE_LAUNCH=1 rides the local launch's environment, not an ssh argv.
grep -qx 'WAKE_LAUNCH=1' "$T/calls/review-prs.env" 2>/dev/null && ok || bad "check_suite row: the local review-prs must run with WAKE_LAUNCH=1"
# TEST-CHANGE BH-2637: the project is review-prs.sh's own argv on the owning box.
grep -qx 'project-5' "$T/calls/review-prs" 2>/dev/null && ok || bad "check_suite row: the owning box must launch review-prs.sh project-5"

# ---------------------------------------------------------------------------
# 3. a whole CI run: three per-job rows + one suite row -> still one launch
# ---------------------------------------------------------------------------
reset; touch "$T/flags/wake-lanes-pr-ci"
wakes "$(W 10 checks abc1234 example-org/project-5 check_run.completed)" \
      "$(W 11 checks def5678 example-org/project-5 check_run.completed)" \
      "$(W 12 checks 9990000 example-org/project-5 check_run.completed)" \
      "$(W 13 checks abc1234 example-org/project-5 check_suite.completed)"
run "$TSBOX"
# TEST-CHANGE BH-2637: the one launch is local on the owning box, and nothing ssh's (was: exactly one ssh call).
[ "$(calls review-prs)" = 1 ] && [ ! -f "$T/calls/ssh" ] && ok \
  || bad "CI run drain: exactly one local review-prs, no ssh (got review-prs=$(calls review-prs) ssh=$(calls ssh))"
# TEST-CHANGE BH-2637: that launch is review-prs.sh project-5, by argv rather than an ssh command line.
grep -qx 'project-5' "$T/calls/review-prs" 2>/dev/null && ok || bad "CI run drain: the one launch must be review-prs for project-5"

# ---------------------------------------------------------------------------
# 4. the pr rows are untouched: a synchronize row still drives review-prs
# ---------------------------------------------------------------------------
reset; touch "$T/flags/wake-lanes-pr-ci"
wakes "$(W 20 checks abc1234 example-org/project-3 check_run.completed)" \
      "$(W 21 pr 272 example-org/project-3 pull_request.synchronize)"
run "$HUB"
[ "$(calls review-prs)" = 1 ] && ok || bad "check_run + synchronize: review-prs once (got $(calls review-prs))"
grep -qx 'project-3' "$T/calls/review-prs" 2>/dev/null && ok || bad "check_run + synchronize: review-prs must get the project"

# ---------------------------------------------------------------------------
# 5. the legacy conductor launch on `checks` rows is NOT narrowed by this
#    change, and a checks row still never sets the snapshot bit
# ---------------------------------------------------------------------------
reset; touch "$T/flags/wake-lanes-pr-ci"
wakes "$(W 30 checks abc1234 example-org/project-5 check_run.completed)"
run "$HUB"
[ "$(calls merge-conductor)" = 1 ] && ok || bad "check_run row: conductor still once (got $(calls merge-conductor))"
[ ! -f "$T/calls/tickets-snapshot-push" ] && ok || bad "check_run row: a checks row must not set the snapshot bit"

# ---------------------------------------------------------------------------
# 6. sourced unit: every checks event that is not check_suite.completed is inert
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
  i=0
  for ev in check_run.completed check_run.created check_suite.requested check_suite.rerequested check_suite -; do
    i=$((i+1))
    wc_pr_ci_row project-5 checks abc1234 "$ev" example-org/project-5 "$i"
  done
  printf '[%s] snapshot=%s\n' "$WC_CI_PROJECTS" "$WC_SNAPSHOT" > "$T/calls/unit-inert"
  wc_pr_ci_row project-5 checks abc1234 check_suite.completed example-org/project-5 99
  printf '[%s] snapshot=%s\n' "$WC_CI_PROJECTS" "$WC_SNAPSHOT" > "$T/calls/unit-suite"
)
grep -qx '\[\] snapshot=0' "$T/calls/unit-inert" 2>/dev/null && ok \
  || bad "unit: non-suite checks events must leave WC_CI_PROJECTS empty (got '$(cat "$T/calls/unit-inert" 2>/dev/null)')"
grep -qx '\[ project-5\] snapshot=0' "$T/calls/unit-suite" 2>/dev/null && ok \
  || bad "unit: check_suite.completed must add the project (got '$(cat "$T/calls/unit-suite" 2>/dev/null)')"

# ---------------------------------------------------------------------------
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
