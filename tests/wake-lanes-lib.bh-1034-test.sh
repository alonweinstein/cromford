#!/bin/bash
# tests/wake-lanes-lib.bh-1034-test.sh — the BH-1034 contract for
# bin/lib/wake-lanes.sh: the LANE→class map, the stamp under state/wake-ran/,
# and the backstop's truth table. Every assertion here is a line four sibling
# tickets paste into a lane script, so it is pinned to the contract's spelling —
# the flag name, the stamp path, the window default, the log file — not to
# whatever the library happens to do.
#
# BH-1511.1 made WAKE_BACKSTOP_S the settings contract's worked example: the
# library holds no literal for it any more; lib_env_apply (bin/lib/lane-gate.sh)
# sets it from a `lib.wake-lanes.wake_backstop_s` row, else the env, else the
# registry's `libs` default (1800). Section 12 proves the literal is gone and a
# row moves the window; sections 5 and 6 are unchanged and prove the default
# and the env override still behave exactly as before.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/wake-lanes-lib.bh-1034-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json is GENERATED; rendered_registry renders this
# repo's own into $T. The library's default window now lives there.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
export LANE_REGISTRY; LANE_REGISTRY=$(rendered_registry)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HARNESS="$T"
mkdir -p "$T/bin/lib" "$T/state/wake-ran" "$T/flags" "$T/logs"
# ONE clock for the whole run: every stamp below is written relative to NOW, so
# a slow box cannot turn a "fresh" stamp stale between two cases.
NOW=$(date +%s)

# Minimal flag_active: a flag is ON when its file exists in $HARNESS/flags.
# This is jobs-client.sh's file side; the DB side is out of scope here.
# _jobs_req answers GET /api/settings from ROWS (`key=value` words), or fails
# when WORKER_DOWN is set — the settings half the library now reads through
# bin/lib/lane-gate.sh (BH-1511.1).
cat > "$T/bin/jobs-client.sh" <<'SH'
#!/bin/bash
flag_active() { [ -f "${HARNESS:-/root/harness}/flags/${1:-}" ]; }
_jobs_req() {
  [ -n "${WORKER_DOWN:-}" ] && return 1
  local out="[]" kv
  for kv in ${ROWS:-}; do
    out=$(printf '%s' "$out" | jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + [{key:$k,value:$v,actor:"console"}]')
  done
  printf '{"settings":%s}' "$out"
}
SH
chmod +x "$T/bin/jobs-client.sh"
cp "$DIR/bin/lib/wake-lanes.sh" "$T/bin/lib/wake-lanes.sh"
cp "$DIR/bin/lib/lane-gate.sh" "$T/bin/lib/lane-gate.sh"

# ---------------------------------------------------------------------------
# 0. No side effects when sourced. A lane script pastes the source line at the
#    top of its own body; it must not silently inherit jobs-client.sh's
#    `set -uo pipefail` or its env read.
# ---------------------------------------------------------------------------
(
  set +u
  . "$T/bin/lib/wake-lanes.sh"
  case "$-" in *u*) exit 1 ;; esac
  command -v flag_active >/dev/null 2>&1 && exit 1
  exit 0
) && ok || bad "sourcing the lib must not set -u or source jobs-client.sh"

. "$T/bin/lib/wake-lanes.sh"

# ---------------------------------------------------------------------------
# 1. wake_class_of maps LANES (not events) to the five classes
# ---------------------------------------------------------------------------
for lane in reconcile-prs check-migration-prs alerts-groom; do
  [ "$(wake_class_of "$lane")" = 'pr-closed' ] && ok || bad "$lane -> pr-closed"
done
for lane in review-prs review-autopilot tickets-snapshot-push; do
  [ "$(wake_class_of "$lane")" = 'pr-ci' ] && ok || bad "$lane -> pr-ci"
done
for lane in rebase-train fleet-propagate prompt-eval; do
  [ "$(wake_class_of "$lane")" = 'push' ] && ok || bad "$lane -> push"
done
for lane in deploy-train migration-autopilot apply-migrations; do
  [ "$(wake_class_of "$lane")" = 'deploy' ] && ok || bad "$lane -> deploy"
done
[ "$(wake_class_of flaky-detect)" = 'flaky' ] && ok || bad "flaky-detect -> flaky"
wake_class_of merge-conductor >/dev/null 2>&1 && bad "merge-conductor (no class) must return rc 1" || ok
[ -z "$(wake_class_of merge-conductor 2>/dev/null)" ] && ok || bad "an unclassified lane must print nothing"
# The argument is a lane. An EVENT name is not one, and answering a class for it
# is what makes the backstop read a flag nobody sets.
wake_class_of pull_request.closed >/dev/null 2>&1 && bad "pull_request.closed is an event, not a lane — rc 1" || ok
wake_class_of check_suite.completed >/dev/null 2>&1 && bad "check_suite.completed is an event, not a lane — rc 1" || ok

# ---------------------------------------------------------------------------
# 2. wake_stamp writes state/wake-ran/<lane>[-<project>] and never fails
# ---------------------------------------------------------------------------
wake_stamp rebase-train project-5 && ok || bad "wake_stamp must return 0"
[ -f "$T/state/wake-ran/rebase-train-project-5" ] && ok || bad "stamp path must be state/wake-ran/<lane>-<project>"
[ "$(tr -dc '0-9' < "$T/state/wake-ran/rebase-train-project-5")" -gt 1600000000 ] && ok || bad "stamp must hold a recent epoch"
# A hub-level lane has no project, and must still be stampable.
wake_stamp alerts-groom && ok || bad "wake_stamp with no project must return 0"
[ -f "$T/state/wake-ran/alerts-groom" ] && ok || bad "project is optional: state/wake-ran/<lane>"

# ---------------------------------------------------------------------------
# 3. flag off -> caller runs (rc 1), even with a fresh stamp
# ---------------------------------------------------------------------------
rm -f "$T/flags/wake-lanes-pr-closed"
printf '%s\n' "$(( NOW - 30 ))" > "$T/state/wake-ran/reconcile-prs-project-3"
wake_backstop_skip reconcile-prs project-3 && bad "flag off must return rc 1" || ok

# ---------------------------------------------------------------------------
# 4. class flag on + fresh stamp -> skip, with ONE line in logs/wake-backstop.log
#    and nothing on stdout. The flag is keyed on the CLASS of the lane.
# ---------------------------------------------------------------------------
touch "$T/flags/wake-lanes-pr-closed"
rm -f "$T/logs/wake-backstop.log"
out=$(wake_backstop_skip reconcile-prs project-3); rc=$?
[ "$rc" -eq 0 ] && ok || bad "class flag on + fresh stamp must skip (rc 0, got $rc)"
[ -z "$out" ] && ok || bad "the skip line must not go to stdout (got: $out)"
[ -f "$T/logs/wake-backstop.log" ] && ok || bad "skip must write logs/wake-backstop.log"
[ "$(wc -l < "$T/logs/wake-backstop.log" | tr -d ' ')" = 1 ] && ok || bad "skip must write exactly one line"
grep -qE '^reconcile-prs\[project-3\]: cron tick skipped — wake-driven run [0-9]+s ago \(backstop 1800s\)$' \
  "$T/logs/wake-backstop.log" && ok || bad "skip line format (got: $(cat "$T/logs/wake-backstop.log"))"
# A lane-keyed flag is NOT the contract: flipping one must change nothing.
rm -f "$T/flags/wake-lanes-pr-closed"; touch "$T/flags/wake-lanes-reconcile-prs"
wake_backstop_skip reconcile-prs project-3 >/dev/null 2>&1 && bad "a lane-keyed flag must not arm the backstop" || ok
rm -f "$T/flags/wake-lanes-reconcile-prs"; touch "$T/flags/wake-lanes-pr-closed"

# ---------------------------------------------------------------------------
# 5. stale stamp -> caller runs. The default window is WAKE_BACKSTOP_S:-1800,
#    so a stamp 2000s old is stale and a stamp 300s old is not.
# ---------------------------------------------------------------------------
printf '%s\n' "$(( NOW - 2000 ))" > "$T/state/wake-ran/reconcile-prs-project-3"
wake_backstop_skip reconcile-prs project-3 >/dev/null 2>&1 && bad "a 2000s-old stamp must be stale at the 1800s default" || ok
printf '%s\n' "$(( NOW - 300 ))" > "$T/state/wake-ran/reconcile-prs-project-3"
wake_backstop_skip reconcile-prs project-3 >/dev/null 2>&1 && ok || bad "a 300s-old stamp must be fresh at the 1800s default"
# No stamp at all -> run.
rm -f "$T/state/wake-ran/reconcile-prs-project-3"
wake_backstop_skip reconcile-prs project-3 >/dev/null 2>&1 && bad "no stamp must return rc 1" || ok

# ---------------------------------------------------------------------------
# 6. WAKE_BACKSTOP_S and the third positional both move the window
# ---------------------------------------------------------------------------
printf '%s\n' "$(( NOW - 2000 ))" > "$T/state/wake-ran/reconcile-prs-project-3"
WAKE_BACKSTOP_S=3600 wake_backstop_skip reconcile-prs project-3 >/dev/null 2>&1 && ok || bad "WAKE_BACKSTOP_S=3600 must widen the window"
wake_backstop_skip reconcile-prs project-3 3600 >/dev/null 2>&1 && ok || bad "an explicit window arg must widen the window"
wake_backstop_skip reconcile-prs project-3 600 >/dev/null 2>&1 && bad "an explicit window arg must be able to narrow it" || ok

# ---------------------------------------------------------------------------
# 7. WAKE_LAUNCH=1 -> caller runs and the stamp is refreshed
# ---------------------------------------------------------------------------
printf '%s\n' "$(( NOW - 2000 ))" > "$T/state/wake-ran/reconcile-prs-project-3"
WAKE_LAUNCH=1 wake_backstop_skip reconcile-prs project-3 >/dev/null 2>&1 && bad "WAKE_LAUNCH=1 must return rc 1 (run)" || ok
[ "$(tr -dc '0-9' < "$T/state/wake-ran/reconcile-prs-project-3")" -gt "$(( NOW - 2000 ))" ] && ok \
  || bad "WAKE_LAUNCH=1 must refresh the stamp"

# ---------------------------------------------------------------------------
# 8. A lane with no class -> caller runs, whatever the flags say
# ---------------------------------------------------------------------------
printf '%s\n' "$(( NOW - 30 ))" > "$T/state/wake-ran/merge-conductor-project-3"
wake_backstop_skip merge-conductor project-3 >/dev/null 2>&1 && bad "an unclassified lane must return rc 1" || ok

# ---------------------------------------------------------------------------
# 9. A hub-level lane (no project) skips on its own stamp
# ---------------------------------------------------------------------------
touch "$T/flags/wake-lanes-pr-closed"
printf '%s\n' "$(( NOW - 30 ))" > "$T/state/wake-ran/alerts-groom"
rm -f "$T/logs/wake-backstop.log"
wake_backstop_skip alerts-groom >/dev/null 2>&1 && ok || bad "a hub lane with no project must be skippable"
grep -q '^alerts-groom\[\]: cron tick skipped' "$T/logs/wake-backstop.log" && ok || bad "hub-lane skip line"

# ---------------------------------------------------------------------------
# 10. no flag_active available -> caller runs (fail open)
# ---------------------------------------------------------------------------
mkdir -p "$T/alt/flags" "$T/alt/state/wake-ran" "$T/alt/logs"
touch "$T/alt/flags/wake-lanes-pr-closed"
printf '%s\n' "$(( NOW - 30 ))" > "$T/alt/state/wake-ran/reconcile-prs-project-3"
(
  export HARNESS="$T/alt"     # no bin/jobs-client.sh under this harness
  unset -f flag_active 2>/dev/null || true
  wake_backstop_skip reconcile-prs project-3 >/dev/null 2>&1 && exit 1
  exit 0
) && ok || bad "missing flag_active must fail open (rc 1)"

# ---------------------------------------------------------------------------
# 11. flags/wake-lanes-off -> caller runs regardless of flag/stamp
# ---------------------------------------------------------------------------
touch "$T/flags/wake-lanes-off" "$T/flags/wake-lanes-pr-closed"
printf '%s\n' "$(( NOW - 30 ))" > "$T/state/wake-ran/reconcile-prs-project-3"
wake_backstop_skip reconcile-prs project-3 >/dev/null 2>&1 && bad "wake-lanes-off must return rc 1" || ok
rm -f "$T/flags/wake-lanes-off"

# ---------------------------------------------------------------------------
# 12. BH-1511.1 — the window is a settings row, and the file holds no literal
# ---------------------------------------------------------------------------
grep -qE 'WAKE_BACKSTOP_S:-[^}]' <<<"$(grep -v '^[[:space:]]*#' "$DIR/bin/lib/wake-lanes.sh")" \
  && bad "bin/lib/wake-lanes.sh still carries a \${WAKE_BACKSTOP_S:-literal} — the registry default must be the only one" || ok
grep -qE 'window=[0-9]' <<<"$(grep -v '^[[:space:]]*#' "$DIR/bin/lib/wake-lanes.sh")" \
  && bad "bin/lib/wake-lanes.sh still hardcodes a window number" || ok
touch "$T/flags/wake-lanes-pr-closed"
printf '%s\n' "$(( NOW - 2000 ))" > "$T/state/wake-ran/reconcile-prs-project-3"
(
  unset WAKE_BACKSTOP_S; rm -f "$T/state/settings-cache.json"; rm -rf "$T/state/lane-gate"
  export ROWS="lib.wake-lanes.wake_backstop_s=3600"
  wake_backstop_skip reconcile-prs project-3 >/dev/null 2>&1
) && ok || bad "a lib.wake-lanes.wake_backstop_s=3600 row must widen the window (2000s stamp -> skip)"
(
  unset WAKE_BACKSTOP_S; rm -f "$T/state/settings-cache.json"; rm -rf "$T/state/lane-gate"
  export WORKER_DOWN=1
  wake_backstop_skip reconcile-prs project-3 >/dev/null 2>&1 && exit 1
  printf '%s\n' "$(( NOW - 300 ))" > "$T/state/wake-ran/reconcile-prs-project-3"
  wake_backstop_skip reconcile-prs project-3 >/dev/null 2>&1
) && ok || bad "worker down, no cache: the registry's 1800s default must decide (2000s runs, 300s skips)"
rm -f "$T/state/settings-cache.json"; rm -rf "$T/state/lane-gate"
# (review M1) no window at all — the registry is unreadable — means RUN, and
# says so once in logs/wake-backstop.log: a backstop that silently stops
# skipping on every lane at once must be visible.
rm -f "$T/logs/wake-backstop.log"
(
  unset WAKE_BACKSTOP_S; export LANE_REGISTRY="$T/nope.json"
  printf '%s\n' "$(( NOW - 30 ))" > "$T/state/wake-ran/reconcile-prs-project-3"
  wake_backstop_skip reconcile-prs project-3 >/dev/null 2>&1 && exit 1
  wake_backstop_skip reconcile-prs project-3 >/dev/null 2>&1 && exit 1
  exit 0
) && ok || bad "M1 no resolvable window must run (rc 1)"
[ "$(grep -c 'no backstop window' "$T/logs/wake-backstop.log" 2>/dev/null || echo 0)" = 1 ] && ok \
  || bad "M1 an unresolvable window must be logged ONCE: $(cat "$T/logs/wake-backstop.log" 2>/dev/null)"
# (review N2 of #1565) the FIRST no-window read has no stamp yet, and must say
# nothing on stderr: `tr < missing 2>/dev/null` leaks the redirect's error.
rm -f "$T/logs/wake-backstop.log" "$T/state/wake-ran/.no-window-reconcile-prs"
m1err=$(
  unset WAKE_BACKSTOP_S; export LANE_REGISTRY="$T/nope.json"
  wake_backstop_skip reconcile-prs project-3 2>&1 >/dev/null
)
[ -z "$m1err" ] && ok || bad "N2 the first no-window read printed on stderr: '$m1err'"
rm -f "$T/state/settings-cache.json"; rm -rf "$T/state/lane-gate"

# ---------------------------------------------------------------------------
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
