#!/bin/bash
# bin/prebuild-repro.sh <project> <ticket-id> <key> <build-dir> — the pre-build
# bug reproduction gate (BH-2004; this skeleton is BH-2039). bin/run-build.sh
# runs it once per build, before the plan, when $BUILD/prebuild-repro.txt is
# absent. Every stage is still a stub, so today a bug build records
# cannot-drive fetch-not-wired and builds as before. docs/repro-gate.md.
#
# exit 0  proceed with the build (every skip, every cannot-drive, every error)
# exit 10 stopped: the stop stage commented on the ticket
# exit 11 a stop was wanted but the board comment failed
#
# FAILS OPEN. No `set -e` and no ERR trap: kind-gate's rc 3 is expected, and
# every stage rc is branched on explicitly. Nothing here maps to a stop except
# the stop stage's own rc 10.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
PROJECT="${1:-}"; TICKET="${2:-}"; KEY="${3:-}"; BUILD="${4:-}"
if [ -z "$PROJECT" ] || [ -z "$KEY" ] || [ ! -d "$BUILD" ]; then
  echo "usage: bin/prebuild-repro.sh <project> <ticket-id> <key> <build-dir>" >&2
  exit 0
fi
# Lane gate: `bin/harness-ctl.sh off prebuild-repro <project>` stops it with no
# record, and the build proceeds. Registry: catalog/lanes.d/prebuild-repro.json.
# shellcheck disable=SC1091
. "${HARNESS}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit prebuild-repro "$PROJECT"
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    prebuild-repro "$PROJECT"
# shellcheck disable=SC1091
. "${HARNESS}/bin/lib/prebuild-repro.sh" 2>/dev/null || exit 0

rec() { pr_record "$BUILD" "$PROJECT" "$KEY" "$@"; }
# knob <ENV> <default> — the lane_knob answer; the registry default when the
# lane gate library is missing.
knob() {
  if command -v lane_knob >/dev/null 2>&1; then lane_knob prebuild-repro "$1" "$PROJECT"; else printf '%s' "$2"; fi
}

# 1. The switch.
[ "$(knob REPRO_GATE 1)" = 0 ] && { rec skip knob-off -; exit 0; }
# The drive stage's spend cap, resolved once here and read from the env there.
REPRO_GATE_MAX_USD="$(knob REPRO_GATE_MAX_USD 3)"
export REPRO_GATE_MAX_USD

# 2. Bugs only, decided before any thread fetch. A missing or crashed kind-gate
# reads as not-bug, which is the build as it runs today.
hint=$("$HARNESS/bin/kind-gate.sh" "$BUILD" 2>/dev/null | sed -n 's/^KIND_HINT:[[:space:]]*//p' | tail -1)
[ "$hint" = bug ] || { rec skip not-bug -; exit 0; }

for f in pr_fetch_thread pr_skip_classify pr_drive pr_stop; do
  command -v "$f" >/dev/null 2>&1 || { rec cannot-drive stage-missing "$f"; exit 0; }
done

# 3. The thread.
thread=$(pr_fetch_thread "$PROJECT" "$TICKET" "$KEY"); rc=$?
case "$rc" in
  0) ;;
  3) rec cannot-drive fetch-not-wired -; exit 0 ;;
  *) rec cannot-drive thread-unreadable -; exit 0 ;;
esac

# 4. A skip marker or cause-proven evidence. Exact field match: `skipper` runs.
IFS=$'\t' read -r c1 c2 c3 <<< "$(pr_skip_classify "$thread" | head -1)"
[ "${c1:-}" = skip ] && { rec skip "${c2:--}" "${c3:--}"; exit 0; }

# 5. Drive it. An unrecognized verdict is cannot-drive, never a stop.
IFS=$'\t' read -r verdict reason <<< "$(pr_drive "$PROJECT" "$KEY" "$BUILD" "$thread" | head -1)"
case "${verdict:-}" in
  REPRODUCED)     gate=reproduced ;;
  CANNOT_DRIVE)   gate=cannot-drive ;;
  NOT_REPRODUCED) gate=not-reproduced ;;
  ALREADY_FIXED)  gate=already-fixed ;;
  *) rec cannot-drive drive-bad-verdict "${verdict:-}"; exit 0 ;;
esac
rec "$gate" "${reason:--}" -

# 6. Only a bug we could not see asks the stop stage. A subshell, so a stage
# that calls `exit` cannot end the runner with its own code.
case "$gate" in not-reproduced|already-fixed) ;; *) exit 0 ;; esac
( pr_stop "$PROJECT" "$TICKET" "$KEY" "$BUILD" "$thread" "$verdict" ); rc=$?
case "$rc" in
  10) rec stop "$gate" "${reason:--}"; exit 10 ;;
  11) exit 11 ;;
  *)  exit 0 ;;
esac
