#!/bin/bash
# bin/lib/box-id.sh — THIS box's identity, asserted at lane start (BH-1043).
#
#   . "$HARNESS/bin/lib/box-id.sh"
#   BOX=$(box_id_require cost-rows-push) || exit 0   # no identity: write nothing
#   BOX=$(box_id_get)                                # the id, or empty. No alert.
#
# WHY THIS IS NOT box-name.sh. bin/box-name.sh answers "what is this box CALLED"
# for a crontab and a console column, and it deliberately falls through to
# `hostname` so an unprovisioned checkout still has a label. This answers a
# different question — "may this lane write a row keyed on a box" — and for that
# question the hostname is not an answer at all.
#
# THE INCIDENT (audit of 2026-09-19, §2.4). `box` is half the primary key of
# every row the fleet writes. Every Orgo box boots the image default
# "orgo-desktop", so a box whose state/box-id had not landed yet — a machine
# mid-bootstrap, a restored tree, a checkout with no cron wiring — wrote its
# rows under that string. A PHANTOM box then appears in every metrics table
# beside the real ones, silently merging however many machines were in that
# state, and NOTHING says a word: the push reports success and the rows are
# there. A wrong row filed confidently is worse than a missing one, because
# only the missing one gets investigated.
#
# SO: two sources, both DECLARED, and no guessing.
#   1. $BOX_ID          — a lane declaring its own identity. This is how a Fly
#                         pool machine (`pool-<project>-<machine-id>`) and any
#                         caller with an explicit --box argument are identified;
#                         they have no state/box-id and never will.
#   2. state/box-id     — what bin/bootstrap-machine.sh writes, before it wires
#                         any cron lane that could write a row.
# Nothing else. A box with neither is UNPROVISIONED, and the honest thing for a
# lane to do is write nothing and say so.
#
# SAYING SO IS ONCE PER LANE PER DAY, not once per tick. A */10 lane would
# otherwise put 144 identical lines a day in ALERTS.log and drown the channel it
# is trying to use — the same dedupe shape bin/jobs-client.sh's outage line uses.
# The line names state/box-id, because writing that file is the whole fix, and
# it never quotes the hostname: printing "orgo-desktop" next to the word box is
# exactly the confusion this file exists to end.
#
# FAIL-CLOSED ON PURPOSE, and it is the only place in this library set that is.
# Everywhere else a coordination failure must not stop work. Here the "work" is
# writing a row under a name that is not a box, and not doing that IS the
# correct outcome — the rows stay in the local file (cost.csv is the truth; the
# DB is a mirror) and the next tick after an operator writes state/box-id sends
# every one of them.

_bid_h() { printf '%s' "${HARNESS:-/root/harness}"; }

# The character class bin/box-name.sh and bin/watchdog-ping.sh already sanitise
# with, so an id that identifies here is an id that identifies everywhere.
_bid_clean() { printf '%s' "${1:-}" | tr -dc 'A-Za-z0-9._-'; }

# box_id_get — print the id, or nothing. Never alerts, never guesses. rc 0 when
# there is an id, 1 when there is not, so a caller can branch without parsing.
box_id_get() {
  local v
  v=$(_bid_clean "${BOX_ID:-}")
  if [ -z "$v" ]; then
    v=$(_bid_clean "$(cat "$(_bid_h)/state/box-id" 2>/dev/null)")
  fi
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

# box_id_require <lane> — print the id and rc 0, or alert ONCE per lane per day
# and rc 1 having printed nothing. The caller writes no row on rc 1.
box_id_require() {
  local lane h flag id ts
  lane=$(_bid_clean "${1:-unknown}"); [ -n "$lane" ] || lane=unknown
  if id=$(box_id_get); then printf '%s\n' "$id"; return 0; fi
  h=$(_bid_h)
  ts=$(date -u '+%Y-%m-%d %H:%M:%SZ')
  flag="$h/flags/alerted-box-id-$lane-$(date -u +%Y%m%d)"
  if [ ! -f "$flag" ]; then
    mkdir -p "$h/flags" "$h/logs" 2>/dev/null || true
    : > "$flag" 2>/dev/null || true
    echo "$ts [$lane] no box identity: \$BOX_ID is unset and $h/state/box-id is missing or empty, so this lane wrote NO rows. Every row is keyed on the box, and a guessed identity files several machines under one name. Write the box's fleet name to state/box-id (bin/bootstrap-machine.sh does this) and the next tick sends everything it held back." \
      >> "$h/logs/ALERTS.log" 2>/dev/null || true
  fi
  return 1
}
