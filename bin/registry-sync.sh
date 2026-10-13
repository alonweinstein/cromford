#!/bin/bash
# bin/registry-sync.sh — BH-5650 (BH-5633.2): the registry sync tick, cron */5
# on every box. In db mode it re-renders and applies this box's crontab when,
# and only when, the D1 fleet registry version changed since the last apply.
#
#   REGISTRY_SOURCE   anything but `db` (from env/global.env, or the caller's
#                     environment, which wins) = exit 0 at once: no call, no
#                     state, no lock. bin/harness-sync.sh seeds db into
#                     env/global.env once the registry matches (BH-5651).
#   flags/lane-off-registry-sync   exit 0 at once. The lane gate below also
#                     honours it, all-off and the pause_flags rows.
#
# THE TICK. flock -n locks/registry-sync.lock (held = exit 0: dedupe, never a
# wait). One GET /api/registry through bin/lib/registry.sh with
# REGISTRY_CACHE_TTL_S=0: an outage serves the last good cache, and the
# library writes the one ALERTS line for the episode. V = the cache's
# .version. bin/registry-export.sh --install then rewrites $H/fleet.conf and
# the catalog/cost-accounts.json box maps from it when their bytes differ
# (BH-5651). V equal to state/registry/applied-version = exit 0, no render.
# Otherwise:
#   1. timeout 120 <checkout>/bin/render-crontab.sh --root <checkout> <box-id>,
#      the checkout being REGISTRY_SYNC_CHECKOUT (default /root/harness-checkout,
#      the root bin/update-runners.sh renders from) and the box id
#      state/box-id. rc != 0 or an empty render = no apply.
#   2. The drift guard of update-runners.sh: a live `run-triage.sh <p>` line
#      that the render drops, while the registry still puts <p> on this box,
#      refuses the whole apply. A project the registry MOVED away is allowed.
#   3. The live crontab is backed up to state/registry/crontab.bak-<stamp>
#      (newest 20 kept), the render is installed with crontab(1), and the +/-
#      diff goes to logs/registry-sync.log. A gained or a dropped lane is a log
#      line, not an ALERTS line: here it is the expected result of a registry
#      write (BH-5650 plan A9). update-runners.sh still alerts on its daily path.
#   4. state/registry/applied-version = V, written ONLY after the install
#      succeeded or the render equalled the live crontab.
# A failed step leaves the live crontab and applied-version as they were, writes
# ONE ALERTS line per version (marker state/registry/alerted-<V>) and the next
# tick retries. Every external call is bounded: the GET by
# REGISTRY_API_TIMEOUT_S, the render by 120 s, each crontab(1) call by 30 s.
#
# Exit 0 on every path (a skipped or failed tick is not a cron failure; the
# ALERTS line is the record).
set -uo pipefail
H="${HARNESS:-/root/harness}"
HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$HERE/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
# The caller's REGISTRY_SOURCE wins over the env file (a test, an operator run).
RS_CALLER="${REGISTRY_SOURCE-}"
set -a; . "$HENV/global.env" 2>/dev/null; set +a
[ -z "$RS_CALLER" ] || REGISTRY_SOURCE="$RS_CALLER"
[ "${REGISTRY_SOURCE:-file}" = db ] || exit 0
[ ! -e "$H/flags/lane-off-registry-sync" ] || exit 0

# >>> lane gate (BH-1165) — flags/all-off or flags/lane-off-registry-sync exits
# 0 here; lane_env_apply puts this lane's settings rows into the environment.
# Both fail OPEN. Registry: catalog/lanes.json.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit registry-sync
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    registry-sync

export HARNESS="$H" REGISTRY_SOURCE=db
CHECKOUT="${REGISTRY_SYNC_CHECKOUT:-/root/harness-checkout}"
SD="$H/state/registry"
LOG="$H/logs/registry-sync.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
log() { echo "$(STAMP) $*" >> "$LOG" 2>/dev/null; return 0; }
mkdir -p "$H/locks" "$H/logs" "$SD" 2>/dev/null || exit 0

exec {LOCKFD}>"$H/locks/registry-sync.lock" || exit 0
flock -n "$LOCKFD" || exit 0

BOX_ID=$(tr -dc 'a-z0-9-' < "$H/state/box-id" 2>/dev/null)

# fail_once <V> <text> — one ALERTS line per version; the next tick retries.
fail_once() {
  log "FAILED v$1: $2"
  ( set -C; : > "$SD/alerted-$1" ) 2>/dev/null || return 0
  "$HERE/alert-line.sh" "[${BOX_ID:-<no box id>}] registry-sync: $2 — registry v$1 NOT applied, the live crontab was not touched; the next tick retries. See $LOG."
}

# shellcheck source=bin/lib/registry.sh
. "$HERE/lib/registry.sh" 2>/dev/null || { log "cannot load bin/lib/registry.sh"; exit 0; }
RJ=$(REGISTRY_CACHE_TTL_S=0 registry_json_path 2>/dev/null) || { log "no registry answer and no cache; nothing to apply"; exit 0; }
# The runtime fleet.conf and cost-accounts box maps are the registry export
# (BH-5651), kept current every tick: bin/registry-export.sh writes only on a
# byte change, and this also repairs a fleet.conf that box-launch.sh or
# load-project.sh copied from a checkout. A failure is a log line; the crontab
# half still runs.
"$HERE/registry-export.sh" --install "$H" --checkout "$CHECKOUT" --registry "$RJ" 2>>"$LOG" \
  || log "registry-export --install rc $? (fleet.conf kept; see logs/registry.log)"
V=$(jq -r '.version // empty' "$RJ" 2>/dev/null)
case "$V" in ''|*[!0-9]*) log "the registry cache has no integer version; nothing to apply"; exit 0 ;; esac
[ "$V" != "$(cat "$SD/applied-version" 2>/dev/null)" ] || exit 0

[ -n "$BOX_ID" ] || { fail_once "$V" "no box id in $H/state/box-id"; exit 0; }
[ -x "$CHECKOUT/bin/render-crontab.sh" ] || { fail_once "$V" "no $CHECKOUT/bin/render-crontab.sh"; exit 0; }

# >>> crontab render — the exit status is captured EXPLICITLY (see update-runners.sh).
RENDER_RC=0
RENDERED=$(timeout 120 "$CHECKOUT/bin/render-crontab.sh" --root "$CHECKOUT" "$BOX_ID" 2>>"$LOG") || RENDER_RC=$?
if [ "$RENDER_RC" != 0 ] || [ -z "$RENDERED" ]; then
  fail_once "$V" "crontab render failed (rc=$RENDER_RC, $(printf '%s' "$RENDERED" | grep -c .) lines) for box $BOX_ID"
  exit 0
fi
# <<< crontab render

LIVE_RC=0
LIVE=$(timeout 30 crontab -l 2>/dev/null) || LIVE_RC=$?
# rc 1 with no output is "no crontab for <user>": an empty live crontab.
if [ "$LIVE_RC" != 0 ] && { [ "$LIVE_RC" != 1 ] || [ -n "$LIVE" ]; }; then
  fail_once "$V" "crontab -l failed (rc=$LIVE_RC)"
  exit 0
fi

# >>> crontab drift guard — keyed on the registry's own project set for this box.
BOX_PROJECTS=""
# shellcheck source=bin/lib/cron-lines.sh
. "$HERE/lib/cron-lines.sh" 2>/dev/null || { fail_once "$V" "cannot load bin/lib/cron-lines.sh"; exit 0; }
while read -r P; do
  [ -n "$P" ] || continue
  B=$("$HERE/box-for.sh" "$P" 2>/dev/null) || continue
  [ "$(cron_box_id_for "$B")" = "$BOX_ID" ] && BOX_PROJECTS="$BOX_PROJECTS $P"
done < <(timeout 60 "$HERE/fleet-conf.sh" --projects 2>/dev/null)
DROPPED=""
for P in $BOX_PROJECTS; do
  LANE="/root/harness/bin/run-triage.sh $P"
  if grep -qF "$LANE" <<<"$LIVE" && ! grep -qF "$LANE" <<<"$RENDERED"; then
    DROPPED="$DROPPED $P"
  fi
done
if [ -n "$DROPPED" ]; then
  fail_once "$V" "CRONTAB DRIFT: the render would DROP the live triage lane for${DROPPED}, which the registry still puts on $BOX_ID — REFUSING to apply"
  exit 0
fi
# <<< crontab drift guard

if [ "$LIVE" != "$RENDERED" ]; then
  printf '%s\n' "$LIVE" > "$SD/crontab.bak-$(date -u +%Y%m%d%H%M%S)" || { fail_once "$V" "cannot write the crontab backup under $SD"; exit 0; }
  # shellcheck disable=SC2012
  ls -1t "$SD"/crontab.bak-* 2>/dev/null | tail -n +21 | while read -r OLD; do rm -f "$OLD"; done
  NEWF=$(mktemp "$SD/.crontab.XXXXXX") || { fail_once "$V" "mktemp failed under $SD"; exit 0; }
  printf '%s\n' "$RENDERED" > "$NEWF"
  if ! timeout 30 crontab "$NEWF" 2>>"$LOG"; then
    rm -f "$NEWF"
    fail_once "$V" "the rendered crontab was REJECTED by crontab(1)"
    exit 0
  fi
  rm -f "$NEWF"
  log "v$V crontab applied for $BOX_ID ($(printf '%s\n' "$RENDERED" | grep -c .) lines)"
  comm -13 <(printf '%s\n' "$LIVE" | sort) <(printf '%s\n' "$RENDERED" | sort) | sed "s/^/$(STAMP) crontab + /" >> "$LOG"
  comm -23 <(printf '%s\n' "$LIVE" | sort) <(printf '%s\n' "$RENDERED" | sort) | sed "s/^/$(STAMP) crontab - /" >> "$LOG"
else
  log "v$V render equals the live crontab for $BOX_ID; nothing to install"
fi

TMPV=$(mktemp "$SD/.applied.XXXXXX") && printf '%s\n' "$V" > "$TMPV" && mv -f "$TMPV" "$SD/applied-version" \
  || { rm -f "${TMPV:-}"; log "v$V applied but applied-version could not be written; the next tick re-renders"; exit 0; }
# Markers of versions this box has now moved past.
for M in "$SD"/alerted-*; do [ -e "$M" ] && rm -f "$M"; done
exit 0
