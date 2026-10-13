#!/bin/bash
# bin/concurrency-ceiling-watch.sh — alert when a pool project's effective build
# ceiling DROPS with no rule-set behind it (BH-1300, the deferred half of
# BH-1279). Run by bin/fleet-status-push.sh on the hub's */10 lane; takes no
# arguments and always exits 0.
#
# WHY. On 2026-09-20 and again on 2026-09-21 ~20:40Z the jobs worker's schema
# re-apply resurrected the deleted `repo/*/build = 1` row. Every pool-routed
# project dropped from unlimited to ONE build at a time, project-5 sat at queue
# depth 5 with 13 ai-build tickets waiting for an hour and twenty minutes, and
# nobody was told: the ceiling was rediscovered by a human reading
# `fleet_status.rules`. The number was visible the whole time. Nothing compared
# it to the number from ten minutes earlier, and that comparison is this file.
#
# WHAT "A RULE-SET SINCE THE PREVIOUS SNAPSHOT" MEANS HERE. There is no ledger
# row for a rule-set. `bin/jobs-client.sh rule-set` PUTs /api/rules and the
# worker stamps `concurrency_rules.updated_at` (worker/jobs/src/routes/rules.js)
# — that stamp is the only durable trace a cap change leaves anywhere. So the
# evidence read is the `updated_at` of the row that BINDS for that project
# (bin/lib/build-caps.sh caps_rule_at, walking caps_rule's own ladder), against
# the as_of of the previous observation. A stamp inside the window is an
# operator; the seed's own 2026-08-29 stamp on a row whose number moved this
# morning is the incident. A MISSING stamp alerts: absence of evidence is not
# approval, and the silence is the thing this exists to end.
#
# POOL ONLY. `route == "pool"` rows from bin/concurrency-plan.sh --json. On that
# route the only caps that bind are the fleet-wide pool cap and the repo rule,
# both of which read correctly from the hub. A local or fly1 project's binding
# numbers are flags on ITS box, so from here they are unverified — alerting on
# the hub's view of another box's BUILD_SLOTS would be a page about nothing.
#
# THE STORE. state/concurrency-ceiling.json on the hub:
#
#   { "<project>": {"effective":"unlimited"|"<n>", "bound_by":"…", "as_of":"<ISO Z>"} }
#
# A two-observation watermark, not a ledger of record: losing it costs one
# silent tick (the next run rebuilds the baseline) and never a false alert.
# Written tmp+mv, AFTER every alert decision for the tick — a crash between the
# send and the write re-evaluates next tick, and the --id absorbs the duplicate,
# so "stamped but never delivered" cannot happen. Rows the plan could not read
# (`effective` = `?`) keep their previous entry: a value this machine failed to
# read is never a drop and never a new baseline.
#
# ONCE PER CHANGE, NOT PER TICK. The store makes a re-observed ceiling not a
# drop at all, and the alert id carries old and new, so a SECOND distinct drop
# is a distinct condition with its own line while a repeat of the same one is
# suppressed by bin/lib/alert-state.sh on top.
#
# NEVER FAILS ITS CALLER. Every external read is guarded and the exit is 0 on
# every path — bin/concurrency-plan.sh's own contract, and fleet-status-push.sh
# is the fleet's dead-man signal.
set -uo pipefail
H="${HARNESS:-/root/harness}"
STORE="$H/state/concurrency-ceiling.json"
command -v jq >/dev/null 2>&1 || exit 0

# --- this tick's pool rows ----------------------------------------------------
PLAN=$("$H/bin/concurrency-plan.sh" --json 2>/dev/null) || PLAN=""
CUR=$(printf '%s' "$PLAN" | jq -c '[ .[] | select(.route == "pool") ]' 2>/dev/null) || CUR=""
# No answer is not "no pool projects": an unreadable plan must leave the
# baseline exactly where it was, or the next tick compares against a snapshot
# this one invented. Same for an empty pool set — there is nothing to watch and
# nothing to rewrite.
[ -n "$CUR" ] || exit 0
N=$(printf '%s' "$CUR" | jq -r 'length' 2>/dev/null)
case "$N" in ''|0|*[!0-9]*) exit 0 ;; esac

# --- the previous observation -------------------------------------------------
# A corrupt or absent store reads as {} — no previous entry for anything, so no
# comparison, and the file is rebuilt below.
PREV='{}'
if [ -r "$STORE" ]; then
  P=$(jq -c 'if type == "object" then . else {} end' "$STORE" 2>/dev/null) || P=""
  [ -n "$P" ] && PREV="$P"
fi

NOW_ISO=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || NOW_ISO=""
[ -n "$NOW_ISO" ] || exit 0
# An EMPTY stamp is no stamp. GNU `date -d ""` is not an error: it answers
# today's midnight, so an absent updated_at read as a midnight rule-set and hid
# every drop whose previous observation was before midnight (red on main at
# 00:00Z 2026-09-24, tests/concurrency-ceiling-watch.bh-1300-test.sh 5/5b).
epoch_of() { [ -n "${1:-}" ] || return 1; date -u -d "$1" '+%s' 2>/dev/null; }

alert() { # alert <id> <text>
  if [ -x "$H/bin/lane-alert.sh" ]; then
    HARNESS="$H" "$H/bin/lane-alert.sh" --severity warn --id "$1" \
      fleet-status "$2" >/dev/null 2>&1 || true
  else
    # The ticket asks for the ALERTS.log line; a missing helper must not swallow
    # it. lane-alert's own legacy shape, so the readers of that file (and
    # poll-commands.sh re-beating new lines) see nothing new.
    mkdir -p "$H/logs" 2>/dev/null || true
    printf '%s [orchestrator/fleet-status] %s\n' "$(date -u '+%F %TZ')" "$2" \
      >> "$H/logs/ALERTS.log" 2>/dev/null || true
  fi
}

KEEP=""   # the rows that earned a new baseline, TSV
while IFS=$'\t' read -r p eff why dbat; do
  [ -n "${p:-}" ] || continue
  # Only a number or `unlimited` is a ceiling. `?` (a cap this machine could not
  # read) and anything else is skipped whole: not compared, not stored.
  case "$eff" in
    unlimited) ;;
    ''|*[!0-9]*) continue ;;
  esac
  # bound_by carries a trailing "(route: pool, on <box>'s view of the flags)"
  # for every pool row — true, and the same sentence on every line of every
  # alert. The cap that binds is the half an operator acts on.
  why="${why%% (route:*}"
  KEEP="$KEEP$p	$eff	$why
"
  PEFF=$(printf '%s' "$PREV" | jq -r --arg p "$p" '.[$p].effective // ""' 2>/dev/null)
  PAT=$(printf '%s' "$PREV" | jq -r --arg p "$p" '.[$p].as_of // ""' 2>/dev/null)
  [ -n "$PEFF" ] || continue                       # first sight of this project
  PAT_E=$(epoch_of "$PAT"); [ -n "$PAT_E" ] || continue   # no usable window

  # A DROP: the ceiling is a number now, and it is lower than what it was (any
  # number is lower than unlimited).
  case "$eff" in unlimited) continue ;; esac
  case "$PEFF" in
    unlimited) ;;
    ''|*[!0-9]*) continue ;;
    *) [ "$eff" -lt "$PEFF" ] || continue ;;
  esac

  # Explained? Only by the binding row's own stamp, inside the window.
  AT_E=$(epoch_of "$dbat")
  if [ -n "$AT_E" ] && [ "$AT_E" -ge "$PAT_E" ]; then continue; fi

  alert "concurrency-ceiling-$p-$PEFF-to-$eff" \
    "build ceiling for $p dropped $PEFF -> $eff (bound by $why) with no rule-set since $PAT; bin/concurrency-plan.sh $p shows every cap, bin/jobs-client.sh rule-set raises it"
done <<EOF
$(printf '%s' "$CUR" | jq -r '.[] | [.project, .effective, .bound_by, (.db_rule_updated_at // "")] | @tsv' 2>/dev/null)
EOF

# --- the new watermark, after every send --------------------------------------
NEW=$(printf '%s' "$KEEP" | jq -Rn --argjson prev "$PREV" --arg now "$NOW_ISO" '
  reduce (inputs | select(length > 0) | split("\t")) as $r
    ($prev; .[$r[0]] = {effective: $r[1], bound_by: $r[2], as_of: $now})' 2>/dev/null) || NEW=""
if [ -n "$NEW" ]; then
  mkdir -p "$H/state" 2>/dev/null || true
  TMP="$STORE.tmp.$$"
  if printf '%s\n' "$NEW" > "$TMP" 2>/dev/null; then
    mv -f "$TMP" "$STORE" 2>/dev/null || rm -f "$TMP" 2>/dev/null
  else
    rm -f "$TMP" 2>/dev/null
  fi
fi
exit 0
