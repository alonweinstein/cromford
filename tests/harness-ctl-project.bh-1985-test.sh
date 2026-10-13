#!/bin/bash
# tests/harness-ctl-project.bh-1985-test.sh — `harness-ctl set … <project>`
# refuses a project fleet.conf does not list (BH-1985 item 3).
#
# THE DEFECT. `set <lane> <ENV> <value> <project>` took the project argument
# verbatim. A typo (`project-4s`) was written as `lane.<id>.project-4s.<env>`, a row
# no lane ever reads, and the CLI printed "SET …" as if the knob had moved.
#
# THE CONTRACT pinned here, through the real bin/harness-ctl.sh:
#   P1 a fleet.conf project is accepted and the per-project key is written;
#   P2 a typo is refused, rc 2, the message names the project and fleet.conf,
#      and nothing is written;
#   P3 near-misses are refused too: a prefix, another case, a trailing space,
#      a commented-out project, a path;
#   P4 a lane-wide set (no project) never reads fleet.conf;
#   P5 a project with fleet.conf unreadable is REFUSED (fail closed): nothing
#      can be checked, so nothing is written;
#   P6 a project lane (review-prs) takes a listed project as before.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/harness-ctl-project.bh-1985-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/h/bin/lib" "$T/h/catalog" "$T/h/env"
cp "$DIR/bin/harness-ctl.sh" "$T/h/bin/"
cp "$DIR/bin/lib/env-path.sh" "$T/h/bin/lib/" 2>/dev/null || true
cp "$(rendered_registry)" "$T/h/catalog/lanes.json"
cat > "$T/h/bin/jobs-client.sh" <<'SH'
JOBS_BOX=testbox
flag_set()    { echo "flag_set $1 $2 $3" >> "$OPS"; }
setting_set() { echo "setting_set $1 $2" >> "$OPS"; }
_jobs_req()   { echo "req $1 $2 ${3:-}" >> "$OPS"; return 1; }
SH
FC="$T/h/fleet.conf"
fleet() { printf '%s\n' '# project  repo  board' 'project-4  example-org/project-4  x' \
  '# ghost-os  example-org/ghost-os  x' '' 'project-3  example-org/project-3  y' > "$FC"; }
ctl() { env -u FLEET_CONF HARNESS="$T/h" OPS="$T/ops" bash "$T/h/bin/harness-ctl.sh" "$@"; }
fleet

# ---------- P1 a listed project is accepted -----------------------------------
: > "$T/ops"; OUT=$(ctl set lane-reaper LANE_REAP_DEADLINE_SECS 43200 project-4 2>&1); RC=$?
{ [ "$RC" = 0 ] && grep -qx 'setting_set lane.lane-reaper.project-4.lane_reap_deadline_secs 43200' "$T/ops"; } && ok \
  || bad "P1 a fleet.conf project was not written: rc=$RC out=$OUT ops=$(cat "$T/ops")"

# ---------- P2 a typo is refused, and says why --------------------------------
: > "$T/ops"; ERR=$(ctl set lane-reaper LANE_REAP_DEADLINE_SECS 43200 project-4s 2>&1 >/dev/null); RC=$?
{ [ "$RC" = 2 ] && [ ! -s "$T/ops" ]; } && ok \
  || bad "P2 a typo'd project was not refused cleanly: rc=$RC err=$ERR ops=$(cat "$T/ops")"
case "$ERR" in *"'project-4s'"*"fleet.conf"*) ok ;; *) bad "P2 the refusal must name the project and fleet.conf: $ERR" ;; esac
case "$ERR" in *"project-4, project-3"*) ok ;; *) bad "P2 the refusal must list the real projects: $ERR" ;; esac

# ---------- P3 near-misses ----------------------------------------------------
for P in project-4 project-4 'project-4 ' '#project-4' ghost-os '# ghost-os' ../x; do
  : > "$T/ops"; OUT=$(ctl set lane-reaper LANE_REAP_DEADLINE_SECS 43200 "$P" 2>&1); RC=$?
  { [ "$RC" -ne 0 ] && [ ! -s "$T/ops" ]; } && ok \
    || bad "P3 project '$P' was accepted: rc=$RC out=$OUT ops=$(cat "$T/ops")"
done

# ---------- P4 a lane-wide set never reads fleet.conf -------------------------
rm -f "$FC"
: > "$T/ops"; OUT=$(ctl set alert-triage TRIAGE_MAX_FAMILIES 2 2>&1); RC=$?
{ [ "$RC" = 0 ] && grep -qx 'setting_set lane.alert-triage.triage_max_families 2' "$T/ops"; } && ok \
  || bad "P4 a lane-wide set failed with no fleet.conf: rc=$RC out=$OUT ops=$(cat "$T/ops")"

# ---------- P5 no fleet.conf + a project: fail closed -------------------------
: > "$T/ops"; ERR=$(ctl set lane-reaper LANE_REAP_DEADLINE_SECS 43200 project-4 2>&1 >/dev/null); RC=$?
{ [ "$RC" -ne 0 ] && [ ! -s "$T/ops" ]; } && ok \
  || bad "P5 a project was written with no fleet.conf to check it against: rc=$RC ops=$(cat "$T/ops")"
case "$ERR" in *"not readable"*) ok ;; *) bad "P5 the refusal must say fleet.conf is not readable: $ERR" ;; esac
# FLEET_CONF moves the file, as bin/fleet-conf.sh reads it.
fleet; mv "$FC" "$T/elsewhere.conf"
: > "$T/ops"; OUT=$(env HARNESS="$T/h" OPS="$T/ops" FLEET_CONF="$T/elsewhere.conf" \
  bash "$T/h/bin/harness-ctl.sh" set lane-reaper LANE_REAP_DEADLINE_SECS 43200 project-3 2>&1); RC=$?
{ [ "$RC" = 0 ] && grep -qx 'setting_set lane.lane-reaper.project-3.lane_reap_deadline_secs 43200' "$T/ops"; } && ok \
  || bad "P5 FLEET_CONF must be the file checked: rc=$RC out=$OUT ops=$(cat "$T/ops")"
mv "$T/elsewhere.conf" "$FC"

# ---------- P6 a project lane, a listed project -------------------------------
: > "$T/ops"; OUT=$(ctl set review-prs REVIEW_CI_STALE_SECS 900 project-3 2>&1); RC=$?
{ [ "$RC" = 0 ] && grep -qx 'setting_set lane.review-prs.project-3.review_ci_stale_secs 900' "$T/ops"; } && ok \
  || bad "P6 review-prs project-3 was not written: rc=$RC out=$OUT ops=$(cat "$T/ops")"
: > "$T/ops"; OUT=$(ctl set review-prs REVIEW_CI_STALE_SECS 900 project-3 2>&1); RC=$?
{ [ "$RC" -ne 0 ] && [ ! -s "$T/ops" ]; } && ok \
  || bad "P6 review-prs with an unlisted project was accepted: rc=$RC out=$OUT"

echo "harness-ctl-project.bh-1985: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
