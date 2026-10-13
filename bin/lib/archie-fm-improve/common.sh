#!/bin/bash
# shellcheck shell=bash
# bin/lib/archie-fm-improve/common.sh — BH-4587 (BH-4574.5): what Archie's
# self-improvement loop shares. Sourced by bin/archie-fm-improve.sh, never run:
# no `set -e`, no `exit`, nothing at source time.
#
# A CAUSE is derived at read time from a row waves 1-4 already wrote to
# archie_actions (afi_cause); no writer stamps it. The fingerprint is the first
# 12 hex of sha1(cause) (afi_fp). One OCCURRENCE is one distinct dedupe_key
# with its trailing :on / :observe removed, so one incident seen in both modes
# counts once. Rows that are not occurrences (AFI_SKIP_PLAYBOOKS, outcome
# skipped, a data-lane apply that closed done) never count.
#
# Files the caller sets: AFI_ROWS (every row read, JSONL), AFI_IMP (the improve
# rows read, JSONL), AFI_OCC (afi_occurrences writes it: one JSON object per
# occurrence, {fp, c, t, k, pb, row}, oldest first).
# Globals the caller sets: AFM_LOG, NOW, DAY, AFQ_RETRY_S, AFQ_ACTOR.
# The root is ${HARNESS:-${H:-}}; an empty root refuses (D43).
# gh-rest: no-graphql

# Not occurrences: Archie's own improve rows; watch-ticket (the escalation of an
# incident its watch-<class> row already counted); watch-session (a model
# session, not a cause); queue-solo (the solo run under a queue-culprit row).
AFI_SKIP_PLAYBOOKS='["improve", "watch-ticket", "watch-session", "queue-solo"]'
AFI_LABEL=archie-fm-improve
AFI_N_FPS=0; AFI_N_RECUR=0; AFI_N_FILED=0; AFI_N_COMMENTED=0; AFI_N_REOPENED=0; AFI_N_TRACKED=0
AFI_N_VERIFIED=0; AFI_N_WOULD=0; AFI_N_CAPPED=0; AFI_N_SKIPPED=0; AFI_N_FAILED=0; AFI_INCOMPLETE=0
# The UTC days (YYYY-MM-DD) whose read failed or came back truncated, space
# separated; AFI_COVER_START is 00:00Z of the oldest day read.
AFI_DAY_BAD=" "; AFI_COVER_START=0
# Today's improve rows were read in full: AFI_W_USED (GitHub writes today) and
# AFI_T_USED (new issues today) are known. Empty = unknown, and no write.
AFI_W_USED=""; AFI_T_USED=""

afi_root() { printf '%s' "${HARNESS:-${H:-}}"; }
afi_log() { afm_log "$@"; }

# afi_alert_once <tag> <text> — ONE ALERTS line per tag per UTC day (afq_alert,
#   marker state/archie-fm-improve.<tag>-<DAY>). The line goes first, the
#   marker after it, so a crash between the two costs a duplicate, not silence.
afi_alert_once() {
  local r m; r=$(afq_root); [ -n "$r" ] || return 0
  m="$r/state/archie-fm-improve.$1-$DAY"
  [ -e "$m" ] && return 0
  afq_alert "$2"
  mkdir -p "$r/state" 2>/dev/null; : > "$m" 2>/dev/null || true
}

# The jq library every reader shares. norm is the park_reason normalisation:
# lowercase; #<digits> -> #N; a hex run of 7-40 chars with a digit in it ->
# <sha>; other digits -> N; spaces collapsed; the first 80 chars.
AFI_JQ_DEFS='
def nowould: (.action // "") | sub("^would_"; "");
def norm: ascii_downcase | gsub("#[0-9]+"; "#N") | gsub("\\b(?=[a-f]*[0-9])[0-9a-f]{7,40}\\b"; "<sha>")
  | gsub("[0-9]+"; "N") | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "") | .[0:80];
def cause:
  (.playbook // "") as $pb | (.repo // "") as $r
  | if ($pb | startswith("watch-")) then "watch|\($pb | ltrimstr("watch-"))|\(.project // "")|\(nowould)"
    elif $pb == "stacked-parent-merged" then "stacked-parent-merged|\($r)"
    elif $pb == "rebase-repair" then "rebase-repair|\($r)|\((.evidence.park_reason // "") | tostring | norm)"
    elif $pb == "queue-culprit" then
      "queue-culprit|\($r)|\((.evidence.suites // []) | (if type == "string" then split(",") else . end)
        | map(tostring) | sort | join(","))"
    elif $pb == "queue-enqueue" then "queue-enqueue|\($r)"
    else "\($pb)|\($r)|\(nowould)" end;
def skip($sk): (.playbook as $pb | $sk | index($pb)) != null
  or .outcome == "skipped" or (.playbook == "data-lane" and .outcome == "done");
def occkey: (.dedupe_key // "") | sub(":(on|observe)$"; "");
def epoch: (.created_at // "") | sub("\\.[0-9]+Z$"; "Z") | (try fromdateiso8601 catch null);
'

# afi_cause <row-json> -> the cause text of one archie_actions row.
afi_cause() { jq -r "$AFI_JQ_DEFS cause" <<<"$1"; }

# afi_fp <cause> -> the first 12 hex of sha1(cause).
afi_fp() { printf '%s' "$1" | sha1sum | cut -c1-12; }

# afi_iso <epoch> / afi_epoch <iso> -> the other form; afi_epoch is rc 1 on junk.
afi_iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
afi_epoch() { local e; [ -n "$1" ] || return 1; e=$(date -u -d "$1" +%s 2>/dev/null) && [[ $e =~ ^[0-9]+$ ]] && printf '%s' "$e"; }

# afi_setting <key> <default> <min> <max> -> a whole number. An absent row is
#   the default; an unreadable, junk or out-of-range row is rc 1 and one log
#   line, and the caller takes no action on it (D11).
afi_setting() {
  local k="$1" v rc
  v=$(setting_get "$k"); rc=$?
  case "$rc" in
    0) v=$(printf '%s' "$v" | tr -d '[:space:]') ;;
    2) v=$2 ;;
    *) afi_log "$k unreadable (rc=$rc); nothing done this tick"; return 1 ;;
  esac
  if ! [[ $v =~ ^[0-9]{1,9}$ ]] || [ "$((10#$v))" -lt "$3" ] || [ "$((10#$v))" -gt "$4" ]; then
    afi_log "$k='$v' is not a whole number in $3..$4; nothing done this tick"; return 1
  fi
  printf '%s' "$((10#$v))"
}

# afi_settings_load -> rc 0 with AFI_RECUR_N, AFI_WINDOW_D, AFI_TICKETS_DAY,
#   AFI_VERIFY_D, AFI_GRACE_S and AFI_CAP set; rc 1 when any one is junk.
afi_settings_load() {
  AFI_RECUR_N=$(afi_setting archie.improve.recur_n 3 1 1000) || return 1
  AFI_WINDOW_D=$(afi_setting archie.improve.window_days 7 1 30) || return 1
  AFI_TICKETS_DAY=$(afi_setting archie.improve.tickets_per_day 3 0 100) || return 1
  AFI_VERIFY_D=$(afi_setting archie.improve.verify_days 7 1 14) || return 1
  AFI_GRACE_S=$(afi_setting archie.improve.verify_grace_s 3600 0 604800) || return 1
  AFI_CAP=$(afi_setting archie.cap.improve 10 0 1000) || return 1
  return 0
}

# afi_day_ok <day> -> rc 0 when that day was read in full.
afi_day_ok() { [[ $AFI_DAY_BAD != *" $1 "* ]]; }

# afi_complete_since <epoch> -> rc 0 when every day from <epoch>'s day to today
#   was read in full and <epoch> is inside what was read.
afi_complete_since() {
  local e="$1" d
  [ "$e" -ge "$AFI_COVER_START" ] || return 1
  d=$(( e - e % 86400 ))
  while [ "$d" -le "$NOW" ]; do
    afi_day_ok "$(date -u -d "@$d" +%F)" || return 1
    d=$(( d + 86400 ))
  done
  return 0
}

# afi_read_days <first-epoch> <ndays> — every archie_actions row of <ndays> UTC
#   days from <first-epoch>'s day, appended to AFI_ROWS, and the improve rows
#   of the same days to AFI_IMP. A read that fails, or a day that answers
#   truncated:true, puts the day in AFI_DAY_BAD and sets AFI_INCOMPLETE=1.
#   rc 2: the route is absent (HTTP 404); the caller stops. rc 1 (only with
#   AFI_READ_STOP=1, the section's setting): the first read that failed.
afi_read_days() {
  local first="$1" n="$2" i d resp rc pb q
  AFI_COVER_START=$(( first - first % 86400 ))
  for ((i = 0; i < n; i++)); do
    d=$(date -u -d "@$(( AFI_COVER_START + i * 86400 ))" +%F)
    for pb in all improve; do
      q="day=$d&limit=500"; [ "$pb" = improve ] && q+="&playbook=improve"
      resp=$(_afm_req GET "/api/archie/actions?$q"); rc=$?
      if [ "$rc" = 2 ]; then AFM_ROUTE_ABSENT=1; return 2; fi
      if [ "$rc" != 0 ] || ! jq -e '.actions | type == "array"' <<<"$resp" >/dev/null 2>&1; then
        afi_log "the $pb rows of $d could not be read (rc=$rc http=${JOBS_HTTP:-none}); that day is incomplete"
        AFI_DAY_BAD+="$d "; AFI_INCOMPLETE=1
        [ "${AFI_READ_STOP:-0}" = 1 ] && return 1
        continue
      fi
      if [ "$(jq -r '.truncated == true' <<<"$resp")" = true ]; then
        afi_log "the $pb rows of $d are a full page (500); that day is incomplete"
        AFI_DAY_BAD+="$d "; AFI_INCOMPLETE=1
      fi
      if [ "$pb" = all ]; then jq -c '.actions[]' <<<"$resp" >> "$AFI_ROWS"
      else jq -c '.actions[]' <<<"$resp" >> "$AFI_IMP"; fi
    done
  done
  return 0
}

# afi_occurrences — AFI_ROWS -> AFI_OCC: one line per occurrence, oldest first,
#   {fp, c (cause), t (epoch of its first row), k (key without the mode), pb,
#   row (its first row)}.
afi_occurrences() {
  local occ0 map c
  occ0="$AFI_OCC.0"; map="$AFI_OCC.map"
  jq -sc --argjson sk "$AFI_SKIP_PLAYBOOKS" "$AFI_JQ_DEFS"'
    [.[] | select(type == "object") | select(skip($sk) | not) | select(epoch != null)]
    | group_by(occkey) | map(sort_by(epoch) | .[0] | {c: cause, t: epoch, k: occkey, pb: .playbook, row: .})
    | sort_by(.t, .k) | .[]' "$AFI_ROWS" > "$occ0" 2>/dev/null || : > "$occ0"
  jq -r '.c' "$occ0" | LC_ALL=C sort -u | while IFS= read -r c; do
    printf '%s\t%s\n' "$(afi_fp "$c")" "$c"
  done | jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {(.[1]): .[0]}) | add // {}' > "$map"
  jq -c --slurpfile m "$map" '. + {fp: $m[0][.c]}' "$occ0" > "$AFI_OCC"
  rm -f "$occ0" "$map"
}

# afi_occ_of <fp> [since-epoch] [until-epoch] -> the occurrences of <fp> with
#   since < t <= until (both optional), as a JSON array, oldest first.
afi_occ_of() {
  jq -sc --arg fp "$1" --argjson a "${2:--1}" --argjson b "${3:-99999999999}" \
    '[.[] | select(.fp == $fp and .t > $a and .t <= $b)]' "$AFI_OCC"
}

# afi_cap_load — today's GitHub writes and new issues from today's improve rows
#   (mode on, done or requested). A done reopen is two writes (the evidence
#   comment and the PATCH); a failed reopen whose comment posted is one.
#   Today's read incomplete = unknown, no write.
afi_cap_load() {
  AFI_W_USED=""; AFI_T_USED=""
  afi_day_ok "$DAY" || { afi_log "today's improve rows were not read in full; no GitHub write this tick"; return 0; }
  AFI_W_USED=$(jq -s --arg d "$DAY" '[.[] | select(.day == $d and .mode == "on")
      | if .outcome == "done" or .outcome == "requested" then
          if .action == "reopen" then 2
          elif .action == "comment" or .action == "verified"
               or (.action == "file_ticket" and (.evidence.existing // false) != true) then 1
          else 0 end
        elif .outcome == "failed" and .action == "reopen" and (.evidence.comment_posted // false) == true then 1
        else 0 end] | add // 0' "$AFI_IMP")
  AFI_T_USED=$(jq -s --arg d "$DAY" '[.[] | select(.day == $d and .mode == "on" and .outcome == "done" and .action == "file_ticket")
      | select((.evidence.existing // false) != true)] | length' "$AFI_IMP")
}

# afi_cap_ok write|ticket [writes] -> rc 0 when today's caps leave room for
#   <writes> (default 1) more GitHub writes, and for ticket one more issue.
#   rc 1 capped or unknown (one log line; the work waits for a later tick).
afi_cap_ok() {
  if [ -z "$AFI_W_USED" ] || [ -z "$AFI_T_USED" ]; then return 1; fi
  if [ "$AFI_CAP" = 0 ]; then afi_log "archie.cap.improve=0, the playbook is off"; return 1; fi
  if [ "$(( AFI_W_USED + ${2:-1} ))" -gt "$AFI_CAP" ]; then
    afi_log "cap reached ($AFI_W_USED of $AFI_CAP improve GitHub writes today); the rest wait for tomorrow"; return 1
  fi
  if [ "$1" = ticket ] && [ "$AFI_T_USED" -ge "$AFI_TICKETS_DAY" ]; then
    afi_log "cap reached ($AFI_T_USED of $AFI_TICKETS_DAY new issues today); the rest wait for tomorrow"; return 1
  fi
  return 0
}

# afi_imp_rows <fp> -> the improve rows read for <fp>, JSON array, oldest first.
afi_imp_rows() {
  jq -sc --arg fp "$1" '[.[] | select((.evidence.fp // "") == $fp)] | unique_by(.id) | sort_by(.created_at, .id)' "$AFI_IMP"
}

# afi_section <from-epoch> <to-epoch> — "Factory fixes shipped" for the week:
#   one line per track_merged row (mode on, done) created inside the week, with
#   the issue and PR links, the cause, before N and after M, and verified /
#   reopened / watching. Unreadable is ONE line, "not measured (<why>)".
#   The caller has set AFI_ROWS, AFI_IMP, AFI_OCC, NOW, DAY.
afi_section() {
  local from="$1" to="$2" n first rows k line fp c iss pr cl bef bc st aft ap grace rc
  first=$(( from - from % 86400 ))
  n=$(( (NOW - first) / 86400 + 1 ))
  if [ "$to" -lt "$from" ] || [ "$n" -lt 1 ]; then echo "Factory fixes shipped: not measured (the week ends before it starts)"; return 0; fi
  if [ "$n" -gt 45 ]; then echo "Factory fixes shipped: not measured (the week starts more than 45 days ago)"; return 0; fi
  if ! grace=$(afi_setting archie.improve.verify_grace_s 3600 0 604800); then
    echo "Factory fixes shipped: not measured (archie.improve.verify_grace_s is unreadable)"; return 0
  fi
  rc=0; AFI_READ_STOP=1 afi_read_days "$first" "$n" || rc=$?
  if [ "$rc" = 2 ]; then echo "Factory fixes shipped: not measured (the archie_actions route is absent)"; return 0; fi
  if [ "$rc" != 0 ]; then
    echo "Factory fixes shipped: not measured (the archie_actions rows of$AFI_DAY_BAD could not be read)" | tr -s ' '; return 0
  fi
  k=$first
  while [ "$k" -le "$to" ] && [ "$k" -le "$NOW" ]; do
    if ! afi_day_ok "$(date -u -d "@$k" +%F)"; then
      echo "Factory fixes shipped: not measured (the archie_actions rows of $(date -u -d "@$k" +%F) could not be read in full)"; return 0
    fi
    k=$(( k + 86400 ))
  done
  afi_occurrences
  rows=$(jq -sc --argjson a "$from" --argjson b "$to" "$AFI_JQ_DEFS"'
    [.[] | select(.action == "track_merged" and .mode == "on" and .outcome == "done")
     | select(epoch != null and epoch >= $a and epoch <= $b)] | unique_by(.id) | sort_by(.created_at, .id)' "$AFI_IMP")
  n=$(jq length <<<"$rows")
  if [ "$n" = 0 ]; then echo "Factory fixes shipped: none this week"; return 0; fi
  echo "Factory fixes shipped: $n"
  while IFS= read -r line; do
    # \x1f, not a tab: a tab is IFS whitespace, so an empty pr_url would shift every field after it.
    IFS=$'\x1f' read -r fp c iss pr cl bef bc < <(jq -r '.evidence | [.fp, .cause, (.issue_url // ""), (.pr_url // ""),
        (.closed_at // ""), (.before // 0 | tostring), (.before_complete // false | tostring)] | join("\u001f")' <<<"$line")
    cl=$(afi_epoch "$cl") || cl=0
    st=watching
    jq -se --arg fp "$fp" --argjson c "$cl" '[.[] | select(.evidence.fp == $fp and (.evidence.closed_epoch // 0) == $c
        and .mode == "on" and .outcome == "done" and .action == "verified")] | length > 0' "$AFI_IMP" >/dev/null && st=verified
    jq -se --arg fp "$fp" --argjson c "$cl" '[.[] | select(.evidence.fp == $fp and (.evidence.closed_epoch // 0) == $c
        and .mode == "on" and .outcome == "done" and .action == "reopen")] | length > 0' "$AFI_IMP" >/dev/null && st=reopened
    aft=$(afi_occ_of "$fp" "$(( cl + grace ))" | jq length)
    ap=""; afi_complete_since "$(( cl + grace ))" || ap=" (partial)"
    printf -- '- %s: issue %s, %s; before %s%s, after %s%s; %s\n' "$c" "${iss:-unknown}" \
      "$([ -n "$pr" ] && printf 'fix %s' "$pr" || printf 'closed, no merged PR found')" \
      "$bef" "$([ "$bc" = true ] || printf ' (partial)')" "$aft" "$ap" "$st"
  done < <(jq -c '.[]' <<<"$rows")
}
