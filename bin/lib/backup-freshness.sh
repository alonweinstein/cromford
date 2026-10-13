#!/bin/bash
# bin/lib/backup-freshness.sh — the one reader of "when did this box last get a
# VERIFIED off-box copy".
#
# WHY (#399, after the hub wipe #388). `bin/state-backup.sh` stamps
# state/backup-last.json only after head-object confirms the remote size, so
# that file's ts is the only honest answer to "what would come back". A backup
# that stops is the quietest failure in the fleet: nothing errors, nothing is
# late, and the only symptom is the day you need it. So its AGE is a fleet
# signal — pushed per box in the fleet_status snapshot, alerted on by
# bin/pipeline-health.sh, and rendered on the console's Fleet screen.
#
# WHY ONE LIBRARY. Two consumers on the hub (the push and the health lane) plus
# the probe the heartbeat runs on the box. Three copies of "what counts as
# stale" would disagree the first time one of them changed, and the disagreement
# would read as a healthy fleet.
#
# FOUR STATES, NEVER TWO. The trap here is the same one metered-API dedupe hits:
# "nothing there" is not "broken", and treating it as broken pages forever.
#
#   off           flags/state-backup-off, or STATE_BACKUP=0 in env/global.env.
#                 Deliberate. Checked FIRST, so switching the lane off also
#                 silences the stale stamp it leaves behind. Never pages.
#   ok            a parseable ts in state/backup-last.json. Age = now - ts.
#   unconfigured  a CURRENT state/state-backup-unconfigured-<DAY> exists: the
#                 BACKUP_* keys are still a handoff. bin/state-backup.sh ALREADY
#                 writes one ALERTS line per UTC day for this, so a second
#                 hourly page per box here is pure page-fatigue. Never pages.
#                 CURRENT is the whole word: the marker is evidence only while
#                 the lane is still refreshing it (BF_UNCONF_FRESH_MIN below).
#                 Every box in the fleet has run unconfigured for days, so every
#                 box carries old markers; a reader that accepted any of them
#                 could never leave this state, `missing` would be unreachable
#                 fleet-wide, and the console would tell an operator that a
#                 freshly-configured, FAILING box is "not configured".
#   missing       none of the above. The lane should be stamping and never has.
#                 THIS is what pages.
#   unknown       a ts that will not parse. The field says so and one line goes
#                 to the log; it never pages and it never reads as fresh.
#
# The hub's own row is read straight off local disk — #388 IS the hub, so it is
# the row that matters most. Every remote box's row comes from
# state/fleet-heartbeat/backup-<box>. Nothing here dials out: the fleet-status
# push is the watchdog's layer-2 dead-man signal, and an ssh of its own would
# let a slow box stop it.
#
# WHO WRITES THOSE RECORDS CHANGED IN BH-1031, AND THIS FILE DID NOT. They used
# to be COLLECTED: the probe below was spliced into the 15-minute ssh hop
# bin/fleet-heartbeat.sh already made to every box. That lane answered "can the
# hub REACH the box", not "is the lane alive", and state→DB slice 6 deletes it.
# The fact now travels the other way — bin/state-backup.sh states this box's
# three facts on the tick that produced them, and bin/backup-records-sync.sh
# (hub, */5) writes every box's answer into the same file, with the same three
# fields, dated by the same mtime convention. One collector, and it is the
# machine that owns the fact. Everything below is unchanged by that move, which
# is the point: the record's SHAPE is a published contract with three consumers
# and a console screen.
#
#   bf_remote_probe            the sh one-liner the hub runs ON a box
#   bf_facts_local <H>         its local twin: "<ts>\t<off>\t<unconfigured>"
#   bf_epoch <ts>              epoch seconds, or rc 1
#   bf_state_age <facts> <now> "<state>\t<age_min>"  (age empty unless ok)
#   bf_rows <H> <now>          "<box>\t<state>\t<age_min>" per box we can answer for
#   bf_stale_min               the threshold: setting_get -> env -> 30
#
# Sourced, never executed.

# The default is two missed cycles: bin/state-backup.sh runs at 5,20,35,50.
# BH-4080: HARNESS_HUB_BOX, the hub's fleet name when HUB_BOX_NAME is unset.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$(dirname "${BASH_SOURCE[0]}")/deployment.sh}" || return 1
BF_DEFAULT_STALE_MIN=30

# How recently the unconfigured marker must have been written to still count as
# this lane SAYING so. bin/state-backup.sh touches one per UTC day (and, since
# #399 round 1, removes all of them the moment the keys are present), so 48h is
# a full day of slack around the midnight tick and around a box whose clock
# drifts — while still expiring a marker left behind by a lane that has stopped
# running. The number is hardcoded in two places on purpose: bf_remote_probe is
# TEXT shipped to a box, and tests/backup-freshness-test.sh requires the probe
# and the twin below to agree field for field on the same tree.
BF_UNCONF_FRESH_MIN=2880

# How recently a box's record must have been COLLECTED for it to still be an
# answer about that box. bin/state-backup.sh reports at 5,20,35,50 and
# bin/backup-records-sync.sh dates the file from the report itself, so the
# file's mtime IS the moment the box spoke; 35 minutes is two missed cycles plus
# slack, the same shape as the 30-minute default below. (Before BH-1031 the
# collection was an ssh hop at 9,24,39,54 — same cadence, opposite direction,
# same number.)
#
# WHY A BOUND AT ALL. An unreachable box deliberately KEEPS whatever it last
# said (bin/fleet-heartbeat.sh:94 continues before the write) — inventing
# `missing` out of a failed ssh would page twice for one fault. The other half
# of that promise is this one: the kept record must then stop AGEING. Without
# it the hub re-reads a frozen ts every 10 minutes as if the box had just
# answered, so from minute 30 of any ssh outage `backupstale:<box>` pages every
# hour with the text "uploads are failing, not just slow" — which is false; the
# box is very likely still uploading and the hub simply cannot see it.
# box-project-1-1 was off the tailnet for 2+ days in 2026-08 with its own
# cron running fine, which is ~48 false pages, and the heartbeat skips its own
# watcher-stale check for that box for exactly this reason. The same bound
# covers the heartbeat lane dying on the hub (every record freezes at once) and
# a retired box whose file nothing will ever rewrite.
BF_RECORD_FRESH_MIN=35

# bf_remote_probe — the box-side snippet, emitted as TEXT for a caller that has
# an ssh command to splice it into. KEPT AFTER BH-1031 deleted the hop that used
# it: it is the executable statement of the box-side rule in a form no bash
# library can be, it is what an operator runs by hand over ssh to ask one box
# directly, and tests/backup-freshness-test.sh runs it against the same fixture
# tree as bf_facts_local and requires the two to agree field for field — which
# is what keeps the twin below honest now that it is the production path.
#
# Three raw FACTS, never a verdict: the hub decides what they mean (bf_state_age),
# so a box running an older bin/ cannot answer with a vocabulary the hub has
# moved on from. Always three tab-separated fields, so "reachable and empty" and
# "no answer at all" can never look alike.
#
# TAGGED, NOT POSITIONAL. The line is prefixed `BF<TAB>` and the hub finds it by
# that tag. It rides a command whose earlier parts emit a VARIABLE number of
# lines — `stat -c %Y logs/<project>.log` on a box that has not written that log
# yet prints nothing at all, not even a newline — so a line-number read would
# store someone else's line, or nothing, for a box that answered in full. The
# tag is stripped by bin/fleet-heartbeat.sh before the record is written, so
# what lands on disk is the same three fields bf_facts_local produces.
bf_remote_probe() {
  cat <<'BF_PROBE'
B=/root/harness; BT=$(sed -n 's/.*"ts":"\([^"]*\)".*/\1/p' "$B/state/backup-last.json" 2>/dev/null | head -1); BO=; { [ -f "$B/flags/state-backup-off" ] || grep -qs '^STATE_BACKUP=0' "$B/env/global.env"; } && BO=off; BU=; [ -n "$(find "$B/state" -maxdepth 1 -name 'state-backup-unconfigured-*' -mmin -2880 2>/dev/null | head -1)" ] && BU=unconfigured; printf 'BF\t%s\t%s\t%s\n' "$BT" "$BO" "$BU"
BF_PROBE
}

# bf_facts_local <H> — the same three facts for a tree on THIS machine.
# NOTE the one deliberate asymmetry with the probe: this reader honours
# harness_env_dir (HARNESS_ENV_DIR, then env/, then /etc/harness/env) because on
# the hub that helper is loaded; the probe is a bare sh one-liner on a remote box
# and reads $B/env/global.env, the path bootstrap-machine.sh creates. A box whose
# env lived ONLY at /etc/harness/env would hide STATE_BACKUP=0 from the hop — it
# would read `missing` and page rather than go quiet, which is the safe direction
# to be wrong in. The switch is checked first, and here it is read through
# lane_switch (BH-2438): a settings row switch.state-backup-off[.<box>] settles
# it, and with no row flags/state-backup-off does, as before. The probe reads
# ONLY the file, so flags/state-backup-off is the one form both sides honour.
bf_facts_local() {
  local h="${1:-${HARNESS:-${H:-}}}" envdir ts="" off="" unc=""
  # No root reads as a tree with no stamp, no switch and no marker: `missing`
  # to bf_state_age, never `ok`.
  [ -n "$h" ] || { printf '\t\t\n'; return 0; }
  if command -v harness_env_dir >/dev/null 2>&1; then
    envdir=$(harness_env_dir "$h" 2>/dev/null) || envdir="$h/env"
  else
    envdir="$h/env"
  fi
  [ -n "$envdir" ] || envdir="$h/env"
  ts=$(sed -n 's/.*"ts":"\([^"]*\)".*/\1/p' "$h/state/backup-last.json" 2>/dev/null | head -1)
  command -v lane_switch >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/lane-switch.sh" 2>/dev/null || lane_switch() { local r="${HARNESS:-${H:-}}"; [ -n "$r" ] && [ -f "$r/flags/$1" ]; }
  if HARNESS="$h" lane_switch state-backup-off || grep -qs '^STATE_BACKUP=0' "$envdir/global.env"; then
    off=off
  fi
  # Only a CURRENT marker — the same window and the same expression as the
  # probe. See BF_UNCONF_FRESH_MIN.
  [ -n "$(find "$h/state" -maxdepth 1 -name 'state-backup-unconfigured-*' -mmin "-$BF_UNCONF_FRESH_MIN" 2>/dev/null | head -1)" ] \
    && unc=unconfigured
  printf '%s\t%s\t%s\n' "$ts" "$off" "$unc"
}

# bf_epoch <ts> — bin/state-backup.sh writes compact basic ISO-8601
# (20260920T101500Z). Expanded to the extended form BEFORE date sees it: GNU
# date's tolerance for the basic form is not something to bet a liveness signal
# on, and a date that silently substitutes "now" would make every stale backup
# read as fresh. Extended input is accepted too, so a future writer is free.
bf_epoch() {
  local ts="${1:-}" iso="" e=""
  case "$ts" in
    ????????T??????Z)     iso="${ts:0:4}-${ts:4:2}-${ts:6:2}T${ts:9:2}:${ts:11:2}:${ts:13:2}Z" ;;
    ????-??-??T??:??:??Z) iso="$ts" ;;
    *) return 1 ;;
  esac
  e=$(date -u -d "$iso" +%s 2>/dev/null) ||  # determinism: ok date-empty-stamp the case above only ever puts one of two non-empty shapes in iso
    e=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null) \
    || return 1
  case "$e" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$e"
}

# bf_state_age "<ts>\t<off>\t<unc>" <now> -> "<state>\t<age_min>"
# The age field is EMPTY for every state but ok. Absent means not pushed: a
# fabricated 0 reads as "backed up just now" forever, which is the healthy value
# for the very number the fleet alerts on.
bf_state_age() {
  local line="${1:-}" now="${2:-0}" ts="" off="" unc="" rest e age
  # NOT `IFS=$'\t' read`: tab is IFS WHITESPACE, so read collapses a run of them
  # and drops the leading ones — "\t\tunconfigured" would arrive as ts=
  # "unconfigured" and a box with the backup keys still unset would read as one
  # with a corrupt stamp. Positions are load-bearing here, so they are cut by
  # position.
  # A line with fewer than three fields is not an answer this lane produced —
  # a torn write, or a record from before the probe existed. It is `unknown`,
  # never `missing`: `missing` pages, and a malformed file must not be able to.
  case "$line" in
    *$'\t'*$'\t'*)
      ts=${line%%$'\t'*}; rest=${line#*$'\t'}
      off=${rest%%$'\t'*}; unc=${rest#*$'\t'} ;;
    *) printf 'unknown\t\n'; return 0 ;;
  esac
  if [ -n "${off:-}" ]; then printf 'off\t\n'; return 0; fi
  if [ -n "${ts:-}" ]; then
    if e=$(bf_epoch "$ts"); then
      age=$(( (now - e) / 60 ))
      # A ts in the future is clock skew, not a fresher backup; 0 is the closest
      # true statement and it never hides a stale one.
      [ "$age" -lt 0 ] && age=0
      printf 'ok\t%s\n' "$age"
    else
      printf 'unknown\t\n'
    fi
    return 0
  fi
  if [ -n "${unc:-}" ]; then printf 'unconfigured\t\n'; return 0; fi
  printf 'missing\t\n'
}

# bf_rows <H> <now> -> "<box>\t<state>\t<age_min>", one line per box we have a
# CURRENT answer about. A box that has never been heard from produces NO line at
# all — silence from a box is not evidence about its backups, and the
# heartbeat's own UNREACHABLE alert already owns that story. A box that has
# STOPPED being heard from is the same silence arriving late, so it produces no
# line either; three things can make a record stop being an answer, and all
# three have been seen on this fleet:
#
#   the box stopped reporting      mtime freezes (BF_RECORD_FRESH_MIN). A
#                                  leftover state/fleet-heartbeat/unreachable-<box>
#                                  drops the row too; nothing writes that marker
#                                  since BH-1031, and bin/backup-records-sync.sh
#                                  clears a stale one the moment its box answers
#                                  again, so it can no longer latch a box off
#   the sync lane is dead          every mtime freezes at once; lane-liveness
#                                  pages about that lane, and this one adds
#                                  no N hourly duplicates on top of it
#   the box is retired             fleet.conf no longer names it. bin/fleet-slo.sh
#                                  SLO 4 measured exactly this on the hub on
#                                  2026-09-15 — box-project-3-1 and
#                                  box-project-10-1 both still had
#                                  files here, and an unfiltered read would have
#                                  paged about two machines that do not exist,
#                                  forever, with no retraction possible.
#
# The hub's OWN row is read straight off local disk every tick, so no collection
# window applies to it — #388 is the hub, and it is the row that matters most.
bf_rows() {
  local h="${1:-${HARNESS:-${H:-}}}" now="${2:-0}" hub f box conf boxes mt
  hub="${HUB_BOX_NAME:-$HARNESS_HUB_BOX}"
  printf '%s\t%s\n' "$hub" "$(bf_state_age "$(bf_facts_local "$h")" "$now")"
  # No root: the hub row above (missing) and no heartbeat records to read.
  [ -n "$h" ] || return 0
  # The registry's box column, the bin/fleet-slo.sh idiom. An unreadable or
  # mid-rsync fleet.conf yields an EMPTY list, and an empty list is not "no box
  # is real" — membership is skipped rather than dropping the whole fleet, and
  # the freshness bound below still holds (a retired box's file is one nothing
  # rewrites, so it ages out of the window on its own).
  conf="${FLEET_CONF:-$h/fleet.conf}"
  boxes=$(awk '!/^[[:space:]]*(#|$)/ && NF>=6 {print $6}' "$conf" 2>/dev/null | sort -u | tr '\n' ' ')
  for f in "$h/state/fleet-heartbeat/backup-"*; do
    [ -f "$f" ] || continue
    box=$(basename "$f"); box=${box#backup-}
    [ -n "$box" ] || continue
    # The hub reads its own tree; a heartbeat record of the same name would be
    # the same box twice, once through a stale hop.
    [ "$box" = "$hub" ] && continue
    if [ -n "$boxes" ]; then
      case " $boxes " in *" $box "*) ;; *) continue ;; esac
    fi
    # The heartbeat's own "I could not reach it this tick" marker.
    [ -f "$h/state/fleet-heartbeat/unreachable-$box" ] && continue
    mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)
    # No readable mtime is no collection time, so there is nothing to date the
    # record by — the safe direction is the silent one, as above.
    case "${mt:-}" in ''|*[!0-9]*) continue ;; esac
    [ $(( now - mt )) -gt $(( BF_RECORD_FRESH_MIN * 60 )) ] && continue
    printf '%s\t%s\n' "$box" "$(bf_state_age "$(head -1 "$f" 2>/dev/null)" "$now")"
  done
}

# bf_stale_min — the threshold, DB first. Resolution order:
#   setting_get backup_stale_min  (bin/jobs-client.sh; an absent row answers
#                                  "no row, use your fallback", never a 404)
#   BACKUP_STALE_MIN              (box-local escape hatch, no deploy)
#   BF_DEFAULT_STALE_MIN          (30 — the documented code fallback)
# A non-numeric value is refused rather than clamped: an operator typo must not
# quietly change when the fleet pages.
bf_stale_min() {
  local v=""
  if command -v setting_get >/dev/null 2>&1; then
    v=$(setting_get backup_stale_min 2>/dev/null) || v=""
    case "${v:-}" in
      ''|*[!0-9]*) ;;
      *) printf '%s\n' "$v"; return 0 ;;
    esac
  fi
  case "${BACKUP_STALE_MIN:-}" in
    ''|*[!0-9]*) ;;
    *) printf '%s\n' "$BACKUP_STALE_MIN"; return 0 ;;
  esac
  printf '%s\n' "$BF_DEFAULT_STALE_MIN"
}
