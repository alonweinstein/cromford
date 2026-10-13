#!/bin/bash
# bin/fly-trial-kill.sh [project|all] — the trial KILL lever (task brief
# deliverable 5; plan "Phase 2 > Verify > Kill test" and "Phase 4 > Rollback").
# Runs on the HUB. Stops builder machines and drops the flags so builds route
# LOCALLY again immediately. Idempotent, does NOT destroy apps/volumes/tokens
# (that is the full teardown, below — kept as an explicit --destroy opt-in so a
# fat-finger can't nuke the trial footprint).
#
# Default (no --destroy):
#   - turn fly-disabled on: touch flags/fly-disabled AND PUT the box row
#     switch.fly-disabled.<box>=1 (BH-2435), then re-read the switch the way
#     bin/fly-dispatch.sh does. "inert" is printed only when that re-read says
#     ON; otherwise it says what is still in the way and the run exits 1 at the
#     end (after the machines are stopped and the routing dropped regardless)
#   - stop every (or the named) builder machine (fly-api.sh stop)
#   - drop the routing: with the routing_rows knob on, `routing-set <p> local`
#     (the hub's flags removed first, then the row PUT). With
#     the knob off or no jobs client, rm flags/builder-fly-<project> ON THE HUB
#     only, exactly as before (BH-1373: no two-box instruction either way)
#   - leave queued jobs in place and print them as run-build invocations so the
#     operator can drain them locally on the watcher (fly-dispatch.sh --drain)
#
# --destroy (full teardown, per phase-4 rollback — asks for explicit confirm):
#   fly apps destroy builder-<project> (machines + volumes + secrets), then the
#   operator revokes TS keys + deploy tokens and shreds env/fly.env by hand.
set -uo pipefail

TARGET="${1:-all}"
DESTROY=""
[ "${2:-}" = "--destroy" ] && DESTROY=1
[ "$TARGET" = "--destroy" ] && { DESTROY=1; TARGET="all"; }

HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
FLYENV="$HENV/fly.env"
STATE_DIR="$HARNESS/state/fly"
BIN="$HARNESS/bin"
# From $HARNESS only, never script-relative: the real lib would source this
# harness's jobs client into THIS shell, and a client that exits when sourced
# (modules absent) must not take the kill down with it.
# shellcheck disable=SC1091
. "$HARNESS/bin/lib/lane-switch.sh" 2>/dev/null || true
command -v ls_isolated >/dev/null 2>&1 || ls_isolated() { [ -f "$HARNESS/flags/$2" ]; }
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
say() { echo "$(STAMP) [fly-kill] $*"; }

[ -f "$FLYENV" ] || { echo "$FLYENV missing — hub-only"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }
FLY=$(command -v fly || command -v flyctl || true)
set -a; . "$FLYENV"; set +a

projects() {
  if [ "$TARGET" != "all" ]; then echo "$TARGET"; return; fi
  for sf in "$STATE_DIR"/*.json; do
    [ -f "$sf" ] || continue
    b=$(basename "$sf" .json); case "$b" in *-active) continue;; esac; echo "$b"
  done
}

# global kill switch first — the file, so the kill holds even if nothing after
# it works; then the box row, because a row saying 0 beats the file.
touch "$HARNESS/flags/fly-disabled"
KILL_RC=0
FD_KEY=""
if ! command -v _ls_box_key >/dev/null 2>&1; then
  say "row not written (no lane-switch lib), flags/fly-disabled only"
elif ! FD_KEY=$(_ls_box_key fly-disabled); then
  FD_KEY=""
  say "row not written (box name is not a settings key: charset or >64 chars), flags/fly-disabled only"
else
  body=$(jq -nc --arg k "$FD_KEY" --arg n "fly-trial-kill on $(_lg_box)" \
    '{key:$k, value:"1", actor:"fly-trial-kill", note:$n}')
  # A subshell: the client is sourced here and nowhere else in this script.
  ( [ -r "$BIN/jobs-client.sh" ] || exit 3
    # shellcheck disable=SC1091
    . "$BIN/jobs-client.sh" >/dev/null 2>&1 || exit 3
    command -v _jobs_req >/dev/null 2>&1 || exit 3
    _jobs_req PUT /api/settings "$body" >/dev/null 2>&1 && case "${JOBS_HTTP:-}" in 2*) exit 0 ;; esac
    exit 4 ); PRC=$?
  case "$PRC" in
    0) say "wrote $FD_KEY=1" ;;
    4) say "row PUT failed ($FD_KEY), flags/fly-disabled only" ;;
    *) say "row not written (no jobs client), flags/fly-disabled only" ;;
  esac
fi
# Re-read it as the dispatcher will, with a fresh settings fetch (TTL 0) so a
# cache filled before the PUT cannot answer for it. Through ls_isolated: the
# refresh sources the jobs client, and one that exits when sourced must end a
# subshell, not the kill before a single machine is stopped.
if LANE_GATE_CACHE_S=0 ls_isolated lane_switch fly-disabled && [ "${LANE_SWITCH_SRC:-}" != noclient ]; then
  say "fly-disabled is on ($(lane_switch_src fly-disabled 2>/dev/null || echo flags/fly-disabled)) — dispatcher + ingest are inert as of now."
elif [ "${LANE_SWITCH_SRC:-}" = noclient ]; then
  say "fly-disabled is NOT confirmed: the re-read died loading bin/jobs-client.sh (bin/lib/jobs/ missing: a half-synced bin/), so the settings row could not be read. flags/fly-disabled is touched. Stopping machines and dropping routing anyway."
  KILL_RC=1
else
  say "fly-disabled is NOT in effect: $(lane_switch_src fly-disabled 2>/dev/null || echo flags/fly-disabled) — the dispatcher is NOT inert. Stopping machines and dropping routing anyway."
  KILL_RC=1
fi

for p in $(projects); do
  [ -f "$STATE_DIR/$p.json" ] || { say "$p: no state file — skipping"; continue; }
  say "=== $p ==="

  # stop the machine
  st=$("$BIN/fly-api.sh" "$p" stop 2>/dev/null || echo "?")
  say "$p: machine stop -> $st"

  # drop the routing (BH-1373). Knob on: the row, after the hub files
  # (routing_set writes the files first). Knob off or no client: today's hub rm.
  if [ -x "$BIN/jobs-client.sh" ] && HARNESS="$HARNESS" "$BIN/jobs-client.sh" routing-rows-on >/dev/null 2>&1; then
    HARNESS="$HARNESS" "$BIN/jobs-client.sh" routing-set "$p" local >/dev/null 2>&1 \
      && say "$p: routing row set to local (hub flags dropped; routing_rows is on, so the row is the routing)" \
      || say "$p: hub flags dropped but the routing row PUT failed. Re-run this once the jobs API answers"
  else
    rm -f "$HARNESS/flags/builder-fly-$p" && say "$p: removed hub flags/builder-fly-$p"
  fi

  # print any still-queued jobs as local run-build invocations (operator drains)
  qd="$HARNESS/state/build-queue/$p"
  if ls "$qd"/*.json >/dev/null 2>&1; then
    say "$p: queued jobs remaining — drain locally on the watcher with:"
    "$BIN/fly-dispatch.sh" --drain "$p" 2>/dev/null | sed 's/^/    /'
  fi

  if [ -n "$DESTROY" ]; then
    APP=$(jq -r '.app // ""' "$STATE_DIR/$p.json")
    say "$p: --destroy: this will 'fly apps destroy $APP' (machines+volume+secrets)."
    read -r -p "Type DESTROY $APP to confirm: " confirm
    if [ "$confirm" = "DESTROY $APP" ]; then
      "$FLY" apps destroy "$APP" -y || say "$p: apps destroy failed"
      rm -f "$STATE_DIR/$p.json" "$STATE_DIR/$p-active.json" "$STATE_DIR/$p.image"
      say "$p: app destroyed + hub state cleared. REMAINING BY HAND: revoke TS_AUTHKEY_$p + delete the tagged node; revoke FLY_API_TOKEN_$p; edit it out of env/fly.env."
    else
      say "$p: destroy NOT confirmed — left the app intact."
    fi
  fi
done

say "DONE. Builds route locally again where the routing is dropped. To resume the trial: set ${FD_KEY:-switch.fly-disabled.<box>}=0 (PUT /api/settings, or delete the row) AND rm flags/fly-disabled, then bin/fly-onboard.sh <project> on the hub."
exit "$KILL_RC"
