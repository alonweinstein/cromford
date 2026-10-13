#!/bin/bash
# How many builds this box can START right now — for one project, or box-wide.
#
#   usage: free-slots.sh [project] [ticket-id] [key]
#   stdout: "<n> (<why>)"  or  "unlimited (fly-routed: ...)"
#
# WHY THIS EXISTS AS A SCRIPT. The arithmetic used to live in prose, in nine
# prompt files and four scripts — "slots = cat flags/build-slots minus builds
# currently running (count-builds.sh <project>)" — and every copy of it was
# wrong in the same two ways (project-5, 2026-09-11):
#
#   * It subtracted a PER-PROJECT count from a BOX-WIDE limit. run-build.sh
#     flocks one of N locks/build-slot-<n>.lock, which every project on the box
#     shares, so another lane's build was invisible and the number promised a
#     slot that run-build.sh would then refuse with BUILD_DEFERRED.
#   * It ignored Fly routing entirely. With flags/builder-fly-<project> set,
#     bin/run-build.sh enqueues to the pool and returns QUEUED_FLY *above* the
#     slot flock — a fly launch consumes no local slot at all — so a local
#     number is not conservative there, it is simply the wrong question, and it
#     held three ready project-5 builds back from an idle pool.
#
# The answer also respects flags/wip-limit-<project>, because that is the OTHER
# gate run-build.sh applies; a number that does not predict a BUILD_DEFERRED is
# not worth printing. Always exits 0: a launch rule that cannot read this must
# fall back to its own judgement, never to a stack trace.
#
# "unlimited" NOW HAS A SECOND CAUSE (2026-09-13, "we never lock and serialize").
# BUILD_SLOTS defaults to 0 = no box slot lock at all, so a local project on an
# uncapped box is not slot-gated either, and this prints `unlimited` for it. The
# first token means the same thing it always did — "the slot gate will not refuse
# this launch" — and the parenthetical says which of the two reasons applies.
#
# The first token is the machine-readable half ("unlimited" or an integer) and
# the parenthetical says which cap bound it — a bare number no one can explain
# is how this drifted for a year.
H="${HARNESS:-/root/harness}"
# shellcheck source=bin/lib/flag-on.sh
. "$H/bin/lib/flag-on.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/flag-on.sh" 2>/dev/null || { flag_on() { [ -f "$H/flags/$1-$2" ]; }; flag_value() { cat "$H/flags/$1-$2" 2>/dev/null; }; }
P="${1:-}"
TID="${2:-}"
TKEY="${3:-}"

# ONE IDENTITY PER TICKET (BH-866). With a ticket id AND a key, the first
# question is not "has this box got room" but "is this ticket already being
# built under another key" — a decomposed child launched under its
# `<PARENT>.<n>` title label is a second identity for one board ticket, and
# every other guard in the fleet dedupes on the key and cannot see it.
#
# ABOVE the fly early return, deliberately: a fly-routed project is enqueued to
# the pool and would duplicate there just as well, and most of the fleet is
# fly-routed. bin/run-build.sh carries the same refusal mechanically — this is
# the half a triage prompt can ask before it launches anything.
# No ticket args, or no lib on this box yet, and everything below is untouched.
if [ -n "$P" ] && [ -n "$TID" ] && [ -n "$TKEY" ] && [ -r "$H/bin/lib/ticket-identity.sh" ]; then
  # shellcheck source=bin/jobs-client.sh
  [ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh" 2>/dev/null
  # shellcheck source=bin/lib/ticket-identity.sh
  . "$H/bin/lib/ticket-identity.sh" 2>/dev/null
  if command -v ticket_identity_conflict >/dev/null 2>&1 \
     && IDLINE=$(ticket_identity_conflict "$H" "$P" "$TID" "$TKEY" 2>/dev/null); then
    IFS=$'\t' read -r IKEY ISRC ISTATE <<<"$IDLINE"
    echo "0 (identity: $(ticket_identity_say "$TID" "$IKEY" "$ISRC" "$ISTATE") — one identity per ticket, launch nothing under $TKEY)"
    exit 0
  fi
fi

# FLY IS A PROPERTY OF THE PROJECT, NOT OF THE BOX. There is no such thing as an
# unlimited box, so the box-wide question never answers this way.
# shellcheck source=bin/jobs-client.sh
[ -n "$P" ] && ! command -v routing_builder >/dev/null 2>&1 && [ -r "$H/bin/jobs-client.sh" ] && [ -d "$H/bin/lib/jobs" ] \
  && . "$H/bin/jobs-client.sh" 2>/dev/null
if [ -n "$P" ] && command -v routing_builder >/dev/null 2>&1 && [ "$H" = "${JOBS_HARNESS:-}" ]; then
  FS_ROUTE=$(routing_builder "$P" 2>/dev/null) || FS_ROUTE=""
else FS_ROUTE=""; fi
if [ -n "$P" ] && { [ -n "$FS_ROUTE" ] && [ "$FS_ROUTE" != local ] || { [ -z "$FS_ROUTE" ] && flag_on builder-fly "$P"; }; }; then
  echo "unlimited (fly-routed: $P builds are enqueued to the Fly pool and take no local slot)"
  exit 0
fi

num() { case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }

# The slot count comes from the one place that resolves it (BUILD_SLOTS in
# env/global.env, the legacy flag only when that is unset), so this script and
# bin/run-build.sh's gate cannot come to disagree about whether a launch fits.
# shellcheck source=bin/lib/build-caps.sh
[ -r "$H/bin/lib/build-caps.sh" ] && . "$H/bin/lib/build-caps.sh" 2>/dev/null
if command -v build_slots >/dev/null 2>&1; then SLOTS=$(build_slots "$H")
else SLOTS=$(num "${BUILD_SLOTS:-}" 0); fi
BOXRUN=$(num "$("$H/bin/count-builds.sh" 2>/dev/null)" 0)
if [ "$SLOTS" -eq 0 ]; then
  FREE=unlimited
  WHY="BUILD_SLOTS=0: this box takes no slot lock, so a build is never held behind another build ($BOXRUN running)"
else
  FREE=$(( SLOTS - BOXRUN ))
  [ "$FREE" -lt 0 ] && FREE=0
  WHY="$BOXRUN build(s) running, $SLOTS box slot(s)"
fi

if [ -n "$P" ]; then
  WIP=$(flag_value wip-limit "$P" 2>/dev/null || true)
  case "$WIP" in ''|*[!0-9]*) WIP="" ;; esac
  if [ -n "$WIP" ]; then
    PRUN=$(num "$("$H/bin/count-builds.sh" "$P" 2>/dev/null)" 0)
    WFREE=$(( WIP - PRUN ))
    [ "$WFREE" -lt 0 ] && WFREE=0
    # An uncapped box is still wip-capped per project: the wip limit is a number,
    # so it BINDS against "unlimited" every time.
    if [ "$FREE" = unlimited ]; then
      FREE=$WFREE
      WHY="$PRUN of wip-limit-$P $WIP already building for $P; the box itself is uncapped (BUILD_SLOTS=0)"
    elif [ "$WFREE" -lt "$FREE" ]; then
      FREE=$WFREE
      WHY="$PRUN of wip-limit-$P $WIP already building for $P; $BOXRUN of $SLOTS box slot(s) in use"
    else
      WHY="$WHY; $PRUN for $P under wip-limit-$P $WIP"
    fi
  fi
fi
echo "$FREE ($WHY)"
