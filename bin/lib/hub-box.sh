#!/bin/bash
# bin/lib/hub-box.sh — "is this box the hub, and may it run agent BUILD work?"
# Sourced, never executed. No side effects except the one ALERTS line a refusal
# writes.
#
# WHY A SHARED LIB AND NOT THREE COPIES. The policy is one sentence — the hub
# coordinates, boxes work (docs/HUB-THINNING-PLAN.md, the operator 2026-08-24) — and it
# is now enforced in three entry points (bin/agent-call.sh, bin/run-build.sh,
# bin/run-preplan.sh) plus bin/up10-lane.sh. Three copies of "what counts as the
# hub" is three chances for one of them to start disagreeing, and the one that
# disagrees is the one that keeps building on the hub.
#
# IDENTITY COMES FROM box-name.sh, NEVER FROM `hostname`. The hub's hostname is
# box-hub; its FLEET name — the one its cron ping,
# bin/lib/cron-lines.sh and the watchdog worker all use — is box-hub.
#
# Knobs (env/global.env on the box, or the environment):
#   HUB_BUILD_OK=1        this box may run build lanes even though it is the hub
#   HUB_NO_BUILD_LANES    the refused stage list (default below)
#   HUB_BOX_NAME          the hub's fleet name (default HARNESS_HUB_BOX, bin/lib/deployment.sh)
#
# `review` is deliberately NOT in the default refused list: cron/hub.cron still
# runs review-autopilot, review-rescue, the merge conductor's head-bound
# re-review, blocked-resolver's adjudication and the cost read-out through
# agent-call on the hub as `review`, and moving those is hub-thinning proper
# (out of scope for BH-393). Refusing `review` today would stop every PR
# review in the fleet the minute it deployed. The knob is what makes that a
# one-line env change the day those lanes move.

# The stamp is internal so this file can be sourced by a script that has no
# STAMP() of its own (bin/up10-lane.sh's fallback path, a test harness) without
# either side clobbering the other's definition.
_hub_stamp() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
# Same character class bin/box-name.sh sanitises with, so a name that pings is a
# name that compares.
_hub_clean() { printf %s "${1:-}" | tr -dc 'A-Za-z0-9._-'; }
_hub_harness() { printf %s "${HARNESS:-/root/harness}"; }

# hub_box_name — the hub's fleet name.
# BH-4080: the default is HARNESS_HUB_BOX, from the deployment defaults home,
# beside this file or in the harness copy.
for _hb_d in "${HARNESS_DEPLOYMENT_FILE-}" "$(dirname "${BASH_SOURCE[0]}")/deployment.sh" "$(_hub_harness)/bin/lib/deployment.sh"; do
  # shellcheck source=bin/lib/deployment.sh
  [ -r "$_hb_d" ] && . "$_hb_d" && break
done
unset _hb_d
hub_box_name() { printf %s "${HUB_BOX_NAME:-${HARNESS_HUB_BOX:-}}"; }

# is_hub_box <name> — 0 if <name> is the hub. An EMPTY name is not the hub: a
# box that cannot name itself must keep working, not refuse everything.
is_hub_box() {
  local n="${1:-}"
  [ -n "$n" ] || return 1
  [ "$n" = local ] && return 0
  [ "$n" = "$(hub_box_name)" ] && return 0
  return 1
}

# local_box_name — THIS box's fleet name, by bin/box-name.sh's own resolution
# order, with the two cheap fallbacks for a tree that has no bin/ yet.
local_box_name() {
  local h n=""
  h=$(_hub_harness)
  if [ -x "$h/bin/box-name.sh" ]; then n=$("$h/bin/box-name.sh" 2>/dev/null); fi
  [ -n "$n" ] || n=$(cat "$h/state/box-name" 2>/dev/null)
  [ -n "$n" ] || n="${BOX_NAME:-}"
  _hub_clean "$n"
}

# hub_no_build_lanes — the agent stages the hub does not run. `build` is not an
# agent-call stage: it is the name bin/run-build.sh refuses under, so the whole
# pipeline and the individual lanes inside it answer to one knob.
hub_no_build_lanes() {
  printf %s "${HUB_NO_BUILD_LANES:-build plan preplan preplan-files execute fix qa}"
}

# _hub_no_build_alert <lane> <ticket> <box> <override-note> — ONE line, deduped
# per (lane, ticket) per UTC day. The dedupe is not cosmetic: bin/preplan-tick.sh
# fires every 2 minutes on the hub, so an undeduped refusal would write 720 lines
# a day into the log an operator is supposed to read.
#
# The override note is an ARGUMENT, not a constant, because it is not true of
# every lane: up10 has no override, and a line telling an operator to set
# HUB_BUILD_OK=1 when that will not help is a line that wastes their afternoon.
_hub_no_build_alert() {
  local lane="${1:-}" ticket="${2:-}" box="${3:-}" note="${4:-}" h flag
  h=$(_hub_harness)
  flag="$h/flags/alerted-hub-no-build-$(_hub_clean "$lane")-$(_hub_clean "$ticket")-$(date -u '+%Y%m%d')"
  mkdir -p "$h/flags" "$h/logs" 2>/dev/null
  [ -e "$flag" ] && return 0
  : > "$flag" 2>/dev/null
  echo "$(_hub_stamp) [hub-no-build] refused $lane $ticket on $box — the hub runs no agent build work ($note, docs/HUB-THINNING-PLAN.md)" \
    >> "$h/logs/ALERTS.log"
}

# hub_no_build_refuse <lane> <ticket> — 0 means REFUSE, 1 means proceed.
# Callers pass a ticket that is never empty (${HARNESS_TICKET:-$PROJECT}).
hub_no_build_refuse() {
  local lane="${1:-}" ticket="${2:-}" box
  [ -n "$lane" ] || return 1
  case " $(hub_no_build_lanes) " in *" $lane "*) ;; *) return 1 ;; esac
  [ "${HUB_BUILD_OK:-}" = 1 ] && return 1
  box=$(local_box_name)
  is_hub_box "$box" || return 1
  _hub_no_build_alert "$lane" "${ticket:-unknown}" "$box" "HUB_BUILD_OK=1 overrides"
  return 0
}

# hub_box_builds_here — 0 when THIS box may run agent build work itself, 1 when
# it is the hub and must send that work to the owning box instead (BH-594). The
# same two checks hub_no_build_refuse makes, and deliberately NOT its ALERTS
# line: a caller that hops the work elsewhere is routing, not refusing.
# HUB_NO_BUILD_LANES is not read here: the question is who this box is.
hub_box_builds_here() {
  [ "${HUB_BUILD_OK:-}" = 1 ] && return 0
  is_hub_box "$(local_box_name)" && return 1
  return 0
}

# hub_no_build_up10_refuse <slug> — the up10 local path on the hub, which is
# what BH-393 exists to stop (ten lanes were running in /root/harness/tmp/
# wt-up10-* when the hub was wiped on 2026-09-15). NO override: HUB_BUILD_OK
# lets an operator build a ticket here, it does not re-open the lane that
# caused the incident.
hub_no_build_up10_refuse() {
  local slug="${1:-unknown}" box
  box=$(local_box_name)
  is_hub_box "$box" || return 1
  _hub_no_build_alert up10 "$slug" "$box" "there is no override for the up10 local path; run it from the hub as bin/up10-lane.sh <slug> <brief-file> and it hops to the owning box"
  return 0
}
