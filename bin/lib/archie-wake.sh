#!/bin/bash
# shellcheck shell=bash
# bin/lib/archie-wake.sh — BH-4063 (BH-3966.2): Archie's proactive wake-ups.
# Sourced by bin/archie.sh (the tick) and bin/archie-followup.sh (the CLI),
# never run. Needs bin/jobs-client.sh loaded (job_ledger_get / job_ledger_put /
# job_ledger_list / ledger_page / job_pr_facts / _jobs_req).
#
# A WAKE marks an initiative due NOW through wave 1's own check path and leaves
# the event in state/archie/wake-context/<id>.txt, which bin/archie.sh appends
# to that initiative's next check prompt and deletes once the check has run.
# One check path, one model route (stage.archie), one send path
# (bin/archie-tg-send.sh, BH-4779).
#
#   archie_wake_init       reads the knobs and the clock (NOW, set by the
#                          caller; ARCHIE_NOW only under HARNESS_TEST_SANDBOX=1)
#   archie_wake_collect    the event collectors, then the mark-due. Skipped
#                          whole under the archie-wake-off switch.
#   archie_wake_context <id> / archie_wake_done <id>
#   archie_links <text>    the ticket numbers a text names, one per line:
#                          #N, BH-N, /issues/N, /pull/N and ranges #A–#B /
#                          #A-#B (capped at 50 numbers)
#   archie_followup_add <3d|YYYY-MM-DD> <note> [initiative]
#   archie_followup_parse <check answer> <initiative id>
#   archie_followup_strip <check answer>
#   archie_beat_gate <{akey, line} JSON>
#   archie_digest_flush
#
# EVENT SOURCES (cursor in state/archie/cursors/<name>; fingerprint = the
# archie_wake ledger key):
#   merge    job_ledger_list merge 200, status merged, updated_at >= cursor;
#            merge:<pr url>, linked by job_pr_facts' ticket
#   replan   logs/decisions.log `gate=replan scope=child <KEY> :: replan-escalate
#            :: <decision>`; replan:<KEY>:<cksum(decision)>; linked, else
#            factory-watch
#   outcome  logs/outcome-metrics.csv rows; outcome:<pr>:<outcome>; linked by the
#            PR's ticket, and a `reworked` row also wakes every initiative whose
#            text mentions rework
#   alerts   logs/ALERTS.log (cursor `alerts`). `[<lane>] DAILY SPEND CAP:` is
#            budget:<lane>:<day> on factory-watch; any other line is
#            alert:<cksum(line minus stamp)>:<day>, linked at
#            ARCHIE_WAKE_ALERT_SCOPE=1, linked or factory-watch at 2, off at 0.
#            Archie's own lines (`archie: …`) never wake him.
#   followup due `pending` archie_followup rows; followup:<key>. A row with a
#            blank note wakes nothing (BH-4779): its archie_wake row is put
#            `empty` and the follow-up `fired`, so no model call and no send.
# A missing cursor is a BASELINE: it is set to EOF (the newest merge row) and
# nothing wakes. A file shorter than its cursor (rotated) is read from 0.
#
# DEDUP. job_ledger_get archie_wake <fp> BEFORE anything: rc 0 = already
# recorded, skipped; rc 2 = new: put `claimed`, write the context, and after
# the mark-due put `woken <ids>`; rc 1 = outage: nothing is woken and the
# cursor stops before that event, so the next tick retries it. An event with no
# active target is put `nolink` (a followup whose initiative is gone:
# `skipped`); an unlinked alert line writes nothing. The tick's flock makes
# get-then-put single-writer.
#
# MARK DUE. wave 1 has no "due now" verb, and next_check_at moves only when a
# check slot closes (POST /api/initiatives/check with advance_to, a CAS on the
# stored next_check_at). So a woken initiative whose next slot is still in the
# future has that slot closed `silent` (nothing was said for it) with
# advance_to=NOW, and only when the slot has no event yet; a slot already in
# flight is left to run at its own time with the context waiting for it.
#
# BEAT GATE. Outside quiet hours (ARCHIE_QUIET_FROM_H..ARCHIE_QUIET_TO_H UTC,
# equal = none) and under ARCHIE_BEAT_CAP_DAY (ledger archie_beatday <day>,
# status = the count) a message is sent and counted; otherwise it is held as
# archie_digest dg-<sha8(line)> `queued`. The first allowed tick sends every
# held row as ONE digest message (counted as one; at cap 0 one digest a day),
# and a row is put `sent` only after that send succeeded. Every send is ONE
# Telegram message through bin/archie-tg-send.sh <akey> <line> (BH-4779), to
# the lane.archie.archie_telegram_target chat, else the operator's DM; never a
# fleet_alert beat.
#
# Root: ${HARNESS:-${H:-}} only (D43). An empty root collects nothing.

AW_KIND_WAKE=archie_wake
AW_FW_GOAL="Factory watch"
AW_FW_SLUG=factory-watch
AW_CTX_MAX=2048
AW_LINES_MAX=500
AW_PAGES_MAX=5
AW_DIGEST_MAX=3500

_aw_root() { printf '%s' "${HARNESS:-${H:-}}"; }

_aw_log() {
  local root; root=$(_aw_root); [ -n "$root" ] || return 0
  mkdir -p "$root/logs" 2>/dev/null
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$root/logs/archie.log"
}
# At most one line per tick for an outage, whatever tripped it, and not the
# same line again on the next tick (state/archie/wake-down holds the last one;
# a tick with no outage clears it).
_aw_down() {
  [ "${AW_DOWN:-0}" = 1 ] && return 0
  AW_DOWN=1
  local root msg f
  root=$(_aw_root); f="$root/state/archie/wake-down"
  msg="wake: the jobs ledger did not answer ($1); nothing woken past that event, retried next tick"
  [ "$(cat "$f" 2>/dev/null)" = "$msg" ] && return 0
  mkdir -p "${f%/*}" 2>/dev/null && printf '%s\n' "$msg" > "$f"
  _aw_log "$msg"
}

# _aw_int <name> <value> <default> <min> <max>: out of range is one warn line
# and the default, never a silent clamp (D11).
_aw_int() {
  local v=$2
  if [[ $v =~ ^[0-9]+$ ]] && [ "$((10#$v))" -ge "$4" ] && [ "$((10#$v))" -le "$5" ]; then
    printf '%s' "$((10#$v))"
  else
    _aw_log "warn: $1=$v is outside $4..$5; using the default $3"
    printf '%s' "$3"
  fi
}

_aw_now() {
  if [[ ${NOW:-} =~ ^[0-9]+$ ]]; then printf '%s' "$NOW"
  elif [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${ARCHIE_NOW:-} =~ ^[0-9]+$ ]]; then printf '%s' "$ARCHIE_NOW"
  else date -u +%s; fi
}
_aw_iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
_aw_sha8() { printf '%s' "$1" | sha256sum | cut -c1-8; }

archie_wake_init() {
  AW_NOW=$(_aw_now)
  AW_NOWISO=$(_aw_iso "$AW_NOW")
  AW_DAY=${AW_NOWISO%%T*}
  AW_HOUR=$((10#$(date -u -d "@$AW_NOW" +%H)))
  AW_CAP=$(_aw_int ARCHIE_BEAT_CAP_DAY "${ARCHIE_BEAT_CAP_DAY:-5}" 5 0 100)
  AW_QFROM=$(_aw_int ARCHIE_QUIET_FROM_H "${ARCHIE_QUIET_FROM_H:-0}" 0 0 23)
  AW_QTO=$(_aw_int ARCHIE_QUIET_TO_H "${ARCHIE_QUIET_TO_H:-0}" 0 0 23)
  AW_ALERTS=$(_aw_int ARCHIE_WAKE_ALERT_SCOPE "${ARCHIE_WAKE_ALERT_SCOPE:-1}" 1 0 2)
  AW_DOWN=0
  AW_COUNT=""
}

# ═════ links ═════════════════════════════════════════════════════════════════
archie_links() {
  printf '%s' "${1:-}" | python3 -c '
import re, sys
t = sys.stdin.buffer.read().decode("utf-8", "replace")
seen, out = set(), []
def add(n):
    if n not in seen:
        seen.add(n); out.append(n)
pat = re.compile(r"#(\d{1,7})\s*[–-]\s*#?(\d{1,7})(?!\d)|(?:#|\bBH-|/issues/|/pull/)(\d{1,7})(?!\d)", re.I)
for m in pat.finditer(t):
    if m.group(3):
        add(int(m.group(3)))
        continue
    a, b = int(m.group(1)), int(m.group(2))
    if b < a:
        add(a); add(b)
        continue
    for n in range(a, min(b, a + 49) + 1):
        add(n)
print("\n".join(str(n) for n in out))
' 2>/dev/null | sed '/^$/d'
}

# The numbers a job_pr_facts ticket names: BH-N, #N or a bare N. Another
# project's prefix (TK-12) names no cromford issue.
_aw_ticket_nums() {
  local t="${1:-}"
  [[ $t =~ ^#?[0-9]+$ ]] && { printf '%s\n' "$((10#${t#\#}))"; return 0; }
  [[ $t =~ ^[Bb][Hh]-[0-9]+$ ]] && archie_links "$t"
  return 0
}

# ═════ the active list (read once per tick, and only when an event needs it) ═
_aw_list_load() {
  [ "${AW_LIST_OK:-0}" = 1 ] && return 0
  local resp rc id slug next text
  resp=$(_jobs_req GET "/api/initiatives?status=active&limit=100" 2>/dev/null); rc=$?
  if [ "$rc" != 0 ] || ! jq -e '.initiatives | type == "array"' <<<"$resp" >/dev/null 2>&1; then
    _aw_down "the active initiatives (rc=$rc)"; return 1
  fi
  [ "$(jq -r '.truncated == true' <<<"$resp")" = true ] \
    && _aw_log "warn: more than 100 active initiatives; wakes only see the first 100"
  declare -gA AW_NUMS=() AW_REWORK=() AW_NEXT=()
  AW_FW=""
  while IFS=$'\t' read -r id slug next text; do
    [[ $id =~ ^[0-9]+$ ]] || continue
    AW_NEXT[$id]=$next
    AW_NUMS[$id]=" $(archie_links "$text" | tr '\n' ' ')"
    [[ ${text,,} == *rework* ]] && AW_REWORK[$id]=1
    [ "$slug" = "$AW_FW_SLUG" ] && AW_FW=$id
  done < <(jq -r '.initiatives[] | [.id, .slug, .next_check_at,
      ([.goal, .metric_query, .escalation_rule] + (.links // []) | map(tostring) | join(" ") | gsub("[\t\n]"; " "))] | @tsv' <<<"$resp")
  AW_LIST_OK=1
}

_aw_active() { [ -n "${AW_NEXT[$1]+x}" ]; }

# _aw_ids_for <numbers...>: the active initiatives linked to any of them.
_aw_ids_for() {
  local id n out=""
  for id in "${!AW_NUMS[@]}"; do
    for n in "$@"; do
      [[ ${AW_NUMS[$id]} == *" $n "* ]] && { out="$out $id"; break; }
    done
  done
  printf '%s' "${out# }"
}
_aw_rework_ids() { local id; for id in "${!AW_REWORK[@]}"; do printf '%s ' "$id"; done; }

# _aw_fw: sets AW_FW to the factory-watch id, created through wave 1's own
# idempotent POST /api/initiatives (the slug is the identity) the first time
# an event needs it. A dropped factory-watch stays dropped: AW_FW stays empty,
# rc 0. rc 1 = outage. Never call it in $( ): it registers the row here.
_aw_fw() {
  [ -n "${AW_FW:-}" ] && return 0
  local body resp rc st id
  body=$(jq -nc --arg g "$AW_FW_GOAL" --arg n "$(_aw_iso $((AW_NOW + 2160 * 3600)))" \
    '{goal: $g, metric_query: "none", cadence_hours: 2160, escalation_rule: "change",
      next_check_at: $n, links: [], created_by: "archie-wake"}')
  resp=$(_jobs_req POST /api/initiatives "$body" 2>/dev/null); rc=$?
  [ "$rc" = 9 ] && resp=${JOBS_BODY:-}
  if [ "$rc" != 0 ] && [ "$rc" != 9 ]; then _aw_down "factory-watch create (rc=$rc)"; return 1; fi
  id=$(jq -r '.initiative.id // empty' <<<"$resp" 2>/dev/null)
  st=$(jq -r '.initiative.status // empty' <<<"$resp" 2>/dev/null)
  [[ $id =~ ^[0-9]+$ ]] || { _aw_down "factory-watch create answered no id"; return 1; }
  if [ "$st" = active ]; then
    AW_FW=$id
    AW_NEXT[$id]=$(jq -r .initiative.next_check_at <<<"$resp")
    AW_NUMS[$id]=" "
  else
    _aw_log "wake: factory-watch (I$id) is $st; events for it are recorded skipped"
  fi
  return 0
}

# ═════ dedup + record ════════════════════════════════════════════════════════
# _aw_seen <fp>: rc 0 already recorded, rc 2 new, rc 1 outage.
_aw_seen() {
  local rc
  # >>> wake dedup
  job_ledger_get "$AW_KIND_WAKE" "$1" >/dev/null 2>&1; rc=$?
  case "$rc" in
    0) return 0 ;;
    2) ;;
    1) _aw_down "archie_wake read"; return 1 ;;
    *) _aw_down "archie_wake read rc=$rc"; return 1 ;;
  esac
  # <<< wake dedup
  return 2
}

# _aw_record <source> <fp> <text> <target...>: a target is an id or FW.
# rc 0 recorded, rc 1 outage (nothing written that would hide the event).
_aw_record() {
  local src=$1 fp=$2 text=$3 t id ids="" dir f
  shift 3
  for t in "$@"; do
    if [ "$t" = FW ]; then
      _aw_fw || return 1
      [ -n "$AW_FW" ] && t=$AW_FW || continue
    fi
    _aw_active "$t" || continue
    [[ " $ids " == *" $t "* ]] || ids="$ids $t"
  done
  ids=${ids# }
  if [ -z "$ids" ]; then
    job_ledger_put "$AW_KIND_WAKE" "$fp" "${AW_NOTARGET:-nolink}" "$src" >/dev/null 2>&1 \
      || { _aw_down "archie_wake write"; return 1; }
    return 0
  fi
  job_ledger_put "$AW_KIND_WAKE" "$fp" claimed "$src" >/dev/null 2>&1 || { _aw_down "archie_wake write"; return 1; }
  dir="$(_aw_root)/state/archie/wake-context"
  mkdir -p "$dir" 2>/dev/null
  text=$(printf '%s' "$text" | tr '\t\n\r' '   ' | cut -c1-400)
  for id in $ids; do
    f="$dir/$id.txt"
    # Bounded on disk too; the prompt reads at most AW_CTX_MAX of it.
    [ "$(stat -c %s "$f" 2>/dev/null || echo 0)" -lt 8192 ] && printf -- '- %s: %s\n' "$src" "$text" >> "$f"
  done
  AW_PENDING+=("$fp"$'\t'"$ids")
  AW_EVENTS=$((AW_EVENTS + 1))
  return 0
}

# _aw_event <source> <fp> <text> <target...>: dedup, then record.
_aw_event() {
  local rc
  _aw_seen "$2"; rc=$?
  [ "$rc" = 0 ] && return 0
  [ "$rc" = 1 ] && return 1
  _aw_record "$@"
}

# ═════ cursors ═══════════════════════════════════════════════════════════════
_aw_cur_file() { printf '%s/state/archie/cursors/%s' "$(_aw_root)" "$1"; }
_aw_cur_get() { local f; f=$(_aw_cur_file "$1"); [ -f "$f" ] || return 1; head -1 "$f"; }
_aw_cur_set() {
  local f; f=$(_aw_cur_file "$1")
  mkdir -p "${f%/*}" 2>/dev/null
  printf '%s\n' "$2" > "$f.tmp" && mv "$f.tmp" "$f"
}

# _aw_file <cursor> <path> <handler>: every complete new line of <path>, the
# handler's rc 1 (outage) stops the pass with the cursor before that line.
_aw_file() {
  local LC_ALL=C name=$1 path=$2 handler=$3 cur size line n=0
  size=$(stat -c %s "$path" 2>/dev/null || echo 0)
  if ! cur=$(_aw_cur_get "$name"); then
    _aw_cur_set "$name" "$size"; return 0
  fi
  [[ $cur =~ ^[0-9]+$ ]] || cur=0
  [ "$size" -lt "$cur" ] && cur=0
  [ "$size" -gt "$cur" ] || { _aw_cur_set "$name" "$cur"; return 0; }
  while IFS= read -r line; do
    n=$((n + 1))
    if [ "$n" -gt "$AW_LINES_MAX" ]; then
      _aw_log "wake: more than $AW_LINES_MAX new lines in ${path##*/}; the rest are read next tick"
      break
    fi
    "$handler" "$line" </dev/null || break
    cur=$((cur + ${#line} + 1))
  done < <(tail -c +"$((cur + 1))" "$path")
  _aw_cur_set "$name" "$cur"
}

# ═════ collectors ════════════════════════════════════════════════════════════
_aw_on_alert() {
  local line=$1 day=$AW_DAY body lane ids
  if [[ $line =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}Z[[:space:]](.*)$ ]]; then
    day=${BASH_REMATCH[1]}; body=${BASH_REMATCH[2]}
  else
    body=$line
  fi
  case "$body" in archie:*|'[archie]'*|'') return 0 ;; esac
  if [[ $body =~ \[([^]]+)\]\ DAILY\ SPEND\ CAP: ]]; then
    lane=$(printf '%s' "${BASH_REMATCH[1]}" | tr -c 'A-Za-z0-9._-' '_')
    _aw_list_load || return 1
    _aw_event budget "budget:$lane:$day" "$body" FW
    return
  fi
  [ "$AW_ALERTS" = 0 ] && return 0
  _aw_list_load || return 1
  # shellcheck disable=SC2046
  ids=$(_aw_ids_for $(archie_links "$body"))
  if [ -z "$ids" ]; then
    [ "$AW_ALERTS" = 2 ] || return 0
    ids=FW
  fi
  # shellcheck disable=SC2086
  _aw_event alert "alert:$(printf '%s' "$body" | cksum | cut -d' ' -f1):$day" "$body" $ids
}

_aw_on_replan() {
  local line=$1 key dec ids
  [[ $line =~ gate=replan\ scope=child\ ([A-Za-z]+-[0-9]+|#?[0-9]+)\ ::\ replan-escalate\ ::\ (.*)$ ]] || return 0
  key=${BASH_REMATCH[1]}; dec=${BASH_REMATCH[2]}
  _aw_list_load || return 1
  # shellcheck disable=SC2046
  ids=$(_aw_ids_for $(_aw_ticket_nums "$key"))
  # shellcheck disable=SC2086
  _aw_event replan "replan:$key:$(printf '%s' "$dec" | cksum | cut -d' ' -f1)" \
    "replan-escalate on $key: $dec" ${ids:-FW}
}

_aw_on_outcome() {
  local line=$1 f repo pr outcome evidence url facts rc ticket ids fp rc2
  f=$(printf '%s\n' "$line" | python3 -c '
import csv, sys
r = next(csv.reader(sys.stdin), [])
if len(r) >= 5:
    print("\t".join(c.replace("\t", " ") for c in r[1:5]))
' 2>/dev/null) || return 0
  IFS=$'\t' read -r repo pr outcome evidence <<<"$f"
  [ -n "$pr" ] && [ -n "$outcome" ] && [ "$outcome" != outcome ] || return 0
  fp="outcome:$pr:$outcome"
  _aw_seen "$fp"; rc2=$?
  [ "$rc2" = 0 ] && return 0
  [ "$rc2" = 1 ] && return 1
  url=$pr
  [[ $pr =~ ^[0-9]+$ ]] && [ -n "$repo" ] && url="https://github.com/$repo/pull/$pr"
  ticket=""
  facts=$(job_pr_facts "$url" 2>/dev/null); rc=$?
  case "$rc" in
    0) ticket=$(cut -f3 <<<"$facts") ;;
    2) ;;
    *) _aw_down "pr facts for $url"; return 1 ;;
  esac
  _aw_list_load || return 1
  # shellcheck disable=SC2046
  ids=$(_aw_ids_for $(_aw_ticket_nums "$ticket"))
  [ "$outcome" = reworked ] && ids="$ids $(_aw_rework_ids)"
  # shellcheck disable=SC2086
  _aw_record outcome "$fp" "outcome $outcome on $url${ticket:+ ($ticket)}: $evidence" $ids
}

_aw_collect_merge() {
  local rows rc cur last key st upd facts ticket ids rc2
  rows=$(job_ledger_list merge 200 2>/dev/null); rc=$?
  [ "$rc" = 0 ] || { _aw_down "merge ledger list"; return 0; }
  # The cursor is the (updated_at, key) of the last row handled, so a row that
  # shares the cursor's second is neither skipped nor read twice.
  rows=$(printf '%s\n' "$rows" | sed '/^$/d' | LC_ALL=C sort -t $'\t' -k4,4 -k1,1)
  if ! cur=$(_aw_cur_get merge); then
    last=$(printf '%s\n' "$rows" | tail -1 | awk -F'\t' '{ print $4 "\t" $1 }')
    [ -n "${last//[[:space:]]/}" ] || last=0
    _aw_cur_set merge "$last"; return 0
  fi
  local cupd=${cur%%$'\t'*} ckey=""
  [[ $cur == *$'\t'* ]] && ckey=${cur#*$'\t'}
  last=$cur
  while IFS=$'\t' read -r -u 3 key st _ upd; do
    [ -n "$key" ] && [ -n "$upd" ] || continue
    [[ $upd < $cupd ]] && continue
    [ "$upd" = "$cupd" ] && ! [[ $key > $ckey ]] && continue
    if [ "$st" = merged ]; then
      _aw_seen "merge:$key"; rc2=$?
      [ "$rc2" = 1 ] && break
      if [ "$rc2" = 2 ]; then
        ticket=""
        facts=$(job_pr_facts "$key" 2>/dev/null </dev/null); rc=$?
        case "$rc" in
          0) ticket=$(cut -f3 <<<"$facts") ;;
          2) ;;
          *) _aw_down "pr facts for $key"; break ;;
        esac
        _aw_list_load || break
        # shellcheck disable=SC2046
        ids=$(_aw_ids_for $(_aw_ticket_nums "$ticket"))
        # shellcheck disable=SC2086
        _aw_record merge "merge:$key" "merged $key${ticket:+ ($ticket)}" $ids </dev/null || break
      fi
    fi
    last="$upd"$'\t'"$key"
  done 3<<<"$rows"
  _aw_cur_set merge "$last"
}

_aw_collect_followups() {
  local before="" bk="" page=0 resp rc n key due ini note fp rc2 tgt
  while [ "$page" -lt "$AW_PAGES_MAX" ]; do
    page=$((page + 1))
    resp=$(ledger_page archie_followup 100 "$before" "$bk" 2>/dev/null); rc=$?
    [ "$rc" = 2 ] && return 0
    if [ "$rc" != 0 ] || ! jq -e '.ledgers | type == "array"' <<<"$resp" >/dev/null 2>&1; then
      _aw_down "follow-up list"; return 0
    fi
    while IFS=$'\t' read -r -u 3 key due ini note; do
      [ -n "$key" ] || continue
      fp="followup:$key"
      _aw_seen "$fp"; rc2=$?
      [ "$rc2" = 1 ] && return 0
      if [ "$rc2" = 2 ]; then
        _aw_list_load || return 0
        if [ -z "${note//[[:space:]]/}" ]; then
          # BH-4779: a follow-up with nothing to check wakes nothing.
          job_ledger_put "$AW_KIND_WAKE" "$fp" empty followup >/dev/null 2>&1 \
            || { _aw_down "archie_wake write"; return 0; }
          _aw_log "follow-up $key fired with no note; closed silently"
        else
          tgt=FW
          [[ $ini =~ ^[0-9]+$ ]] && tgt=$ini
          AW_NOTARGET=skipped _aw_record followup "$fp" "follow-up you set for $due: $note" "$tgt" || return 0
        fi
      fi
      job_ledger_put archie_followup "$key" fired >/dev/null 2>&1 \
        || _aw_log "warn: follow-up $key woke but could not be marked fired; repaired next tick"
    done 3< <(jq -r --arg n "$AW_NOWISO" '.ledgers[] | select(.status == "pending")
        | (.detail // "" | try fromjson catch null) as $d | select($d != null and ($d.due_at | type) == "string" and $d.due_at <= $n)
        | [.key, $d.due_at, ($d.initiative_id // "" | tostring), ($d.note // "" | gsub("[\t\n]"; " "))] | @tsv' <<<"$resp")
    n=$(jq '.ledgers | length' <<<"$resp")
    [ "$n" -ge 100 ] || return 0
    before=$(jq -r '.ledgers[-1].updated_at' <<<"$resp"); bk=$(jq -r '.ledgers[-1].key' <<<"$resp")
  done
  _aw_log "warn: more than $((AW_PAGES_MAX * 100)) follow-up rows; older pending ones are not read this tick"
}

# The mark-due: every initiative that has a wake context and a future slot.
_aw_mark_due() {
  local dir f id next rc body
  dir="$(_aw_root)/state/archie/wake-context"
  for f in "$dir"/*.txt; do
    [ -f "$f" ] || continue
    id=${f##*/}; id=${id%.txt}
    [[ $id =~ ^[0-9]+$ ]] || continue
    _aw_list_load || return 0
    if ! _aw_active "$id"; then
      _aw_log "wake: I$id is not active; its wake context is dropped"
      rm -f "$f"; continue
    fi
    next=${AW_NEXT[$id]}
    [[ $next > $AW_NOWISO ]] || continue
    _jobs_req GET "/api/initiatives/events?key=check:$id:$next" >/dev/null 2>&1; rc=$?
    case "$rc" in
      2) body=$(jq -nc --argjson i "$id" --arg d "$next" --arg n "$AW_NOWISO" \
           '{id: $i, due_at: $d, status: "silent", value: null, actor: "archie-wake", advance_to: $n}')
         if _jobs_req POST /api/initiatives/check "$body" >/dev/null 2>&1; then
           AW_NEXT[$id]=$AW_NOWISO
         else
           _aw_log "wake: I$id could not be marked due (http=${JOBS_HTTP:-none}); retried next tick"
         fi ;;
      0) _aw_log "wake: I$id slot $next is already in flight; the events wait for it" ;;
      *) _aw_down "the slot ledger for I$id" ;;
    esac
  done
}

archie_wake_collect() {
  local root p fp ids woke=""
  root=$(_aw_root); [ -n "$root" ] || return 0
  AW_LIST_OK=0; AW_EVENTS=0; AW_PENDING=()
  declare -gA AW_NUMS=() AW_REWORK=() AW_NEXT=()
  command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "$(_aw_root)/flags/$1" ]; }
  if lane_switch archie-wake-off file; then
    return 0
  fi
  _aw_collect_merge
  _aw_file replan "$root/logs/decisions.log" _aw_on_replan
  _aw_file outcome "$root/logs/outcome-metrics.csv" _aw_on_outcome
  _aw_file alerts "$root/logs/ALERTS.log" _aw_on_alert
  _aw_collect_followups
  _aw_mark_due
  for p in "${AW_PENDING[@]}"; do
    fp=${p%%$'\t'*}; ids=${p#*$'\t'}
    job_ledger_put "$AW_KIND_WAKE" "$fp" woken "$ids" >/dev/null 2>&1 \
      || _aw_log "warn: wake $fp stays claimed (the woken write failed); it still dedups"
    woke="$woke $ids"
  done
  [ "$AW_DOWN" = 1 ] || rm -f "$root/state/archie/wake-down"
  [ "$AW_EVENTS" -gt 0 ] && _aw_log "wake: events=$AW_EVENTS initiatives=$(printf '%s\n' $woke | sort -un | sed 's/^/I/' | paste -sd, -)"
  return 0
}

# ═════ wake context ══════════════════════════════════════════════════════════
archie_wake_context() {
  local f; f="$(_aw_root)/state/archie/wake-context/${1:-x}.txt"
  [ -s "$f" ] || return 1
  if [ "$(stat -c %s "$f")" -le "$AW_CTX_MAX" ]; then
    cat "$f"
  else
    head -c "$AW_CTX_MAX" "$f" | sed '$d'
    printf '(more events than fit here)\n'
  fi
}
archie_wake_done() { rm -f "$(_aw_root)/state/archie/wake-context/${1:-x}.txt"; }

# ═════ follow-ups ════════════════════════════════════════════════════════════
# archie_followup_add <3d|YYYY-MM-DD> <note> [initiative]
#   rc 0 and `<key><TAB><due_at>` (a new row, or the one already there); rc 2 a
#   bad date, note or initiative (nothing written); rc 1 the ledger is down.
#   The key hashes the initiative, the due DAY and the note, so asking twice
#   for the same thing on the same day writes one row.
archie_followup_add() {
  local when="${1:-}" note="${2:-}" ini="${3:-}" now due iso key rc detail
  now=$(_aw_now)
  if [[ $when =~ ^([0-9]{1,3})d$ ]] && [ "$((10#${BASH_REMATCH[1]}))" -ge 1 ] && [ "$((10#${BASH_REMATCH[1]}))" -le 365 ]; then
    due=$((now + 10#${BASH_REMATCH[1]} * 86400))
  elif [[ $when =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [ -n "$when" ] && aw_d=$(date -u -d "$when" +%F 2>/dev/null) && [ "$aw_d" = "$when" ]; then
    due=$(date -u -d "${when}T00:00:00Z" +%s)
  else
    echo "follow-up: '$when' is not <n>d (1-365) or YYYY-MM-DD" >&2; return 2
  fi
  note=$(printf '%s' "$note" | tr '\t\n\r' '   ')
  note="${note#"${note%%[![:space:]]*}"}"; note="${note%"${note##*[![:space:]]}"}"
  [ -n "$note" ] && [ "${#note}" -le 300 ] || { echo "follow-up: the note must be 1-300 characters" >&2; return 2; }
  if [ -n "$ini" ]; then
    [[ $ini =~ ^[Ii]?([0-9]{1,9})$ ]] && [ "$((10#${BASH_REMATCH[1]}))" -ge 1 ] \
      || { echo "follow-up: '$ini' is not an initiative (I<n>)" >&2; return 2; }
    ini=$((10#${BASH_REMATCH[1]}))
  fi
  iso=$(_aw_iso "$due")
  key="fu-$(_aw_sha8 "$ini|${iso%%T*}|$note")"
  job_ledger_get archie_followup "$key" >/dev/null 2>&1; rc=$?
  case "$rc" in
    0) printf '%s\t%s\n' "$key" "$iso"; return 0 ;;
    2) ;;
    *) return 1 ;;
  esac
  detail=$(jq -nc --arg d "$iso" --arg i "$ini" --arg n "$note" \
    '{due_at: $d, initiative_id: (if $i == "" then null else ($i | tonumber) end), note: $n}')
  job_ledger_put archie_followup "$key" pending "$detail" >/dev/null 2>&1 || return 1
  printf '%s\t%s\n' "$key" "$iso"
}

# archie_followup_parse <answer> <initiative id>: each `FOLLOWUP: <when> :: <note>`
# line (at most 3) becomes a row on that initiative.
archie_followup_parse() {
  local text="${1:-}" id="${2:-}" l n=0 out rc
  while IFS= read -r l; do
    [[ $l =~ ^[[:space:]]*FOLLOWUP:[[:space:]]*([^[:space:]]+)[[:space:]]*::[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]] || continue
    n=$((n + 1))
    if [ "$n" -gt 3 ]; then _aw_log "warn: I$id asked for more than 3 follow-ups in one check; the rest were not set"; break; fi
    out=$(archie_followup_add "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$id" 2>&1); rc=$?
    case "$rc" in
      0) _aw_log "follow-up set by I$id: $(cut -f1 <<<"$out") due $(cut -f2 <<<"$out")" ;;
      2) _aw_log "warn: I$id asked for a follow-up that was refused: $out" ;;
      *) _aw_log "warn: I$id asked for a follow-up the ledger did not take; not set" ;;
    esac
  done <<<"$text"
  return 0
}
archie_followup_strip() { printf '%s\n' "${1:-}" | grep -v '^[[:space:]]*FOLLOWUP:'; return 0; }

# ═════ beat gate + digest ════════════════════════════════════════════════════
_aw_quiet() {
  [ "$AW_QFROM" = "$AW_QTO" ] && return 1
  if [ "$AW_QFROM" -lt "$AW_QTO" ]; then
    [ "$AW_HOUR" -ge "$AW_QFROM" ] && [ "$AW_HOUR" -lt "$AW_QTO" ]
  else
    [ "$AW_HOUR" -ge "$AW_QFROM" ] || [ "$AW_HOUR" -lt "$AW_QTO" ]
  fi
}
# Today's beat count; rc 1 when the ledger cannot say.
_aw_count() {
  local st rc
  [ -n "${AW_COUNT:-}" ] && { printf '%s' "$AW_COUNT"; return 0; }
  st=$(job_ledger_get archie_beatday "$AW_DAY" 2>/dev/null); rc=$?
  case "$rc" in
    0) [[ $st =~ ^[0-9]+$ ]] || st=0 ;;
    2) st=0 ;;
    *) return 1 ;;
  esac
  AW_COUNT=$st; printf '%s' "$st"
}
_aw_count_bump() {
  AW_COUNT=$(( ${AW_COUNT:-0} + 1 ))
  job_ledger_put archie_beatday "$AW_DAY" "$AW_COUNT" >/dev/null 2>&1 \
    || _aw_log "warn: today's beat count could not be written (now $AW_COUNT)"
}
# _aw_beat_allowed [digest]: rc 0 send now. AW_GATE_RC 0 allowed, 2 held
# (quiet hours or the cap), 1 the count is unreadable.
_aw_beat_allowed() {
  local cap=$AW_CAP cnt
  if _aw_quiet; then AW_GATE_RC=2; return 1; fi
  cnt=$(_aw_count) || { AW_GATE_RC=1; return 1; }
  [ "${1:-}" = digest ] && [ "$cap" -lt 1 ] && cap=1
  if [ "$cnt" -lt "$cap" ]; then AW_GATE_RC=0; return 0; fi
  AW_GATE_RC=2; return 1
}

# archie_beat_gate <payload {akey, line}>: rc 0 sent (AW_GATE_LAST=sent) or
# held for the digest (=queued); rc 1 neither, so the caller keeps the body to
# resend.
archie_beat_gate() {
  local payload="${1:-}" line key detail
  AW_GATE_LAST=""
  if _aw_beat_allowed; then
    # >>> archie send (BH-4779)
    "$(_aw_root)/bin/archie-tg-send.sh" "$(jq -r '.akey // ""' <<<"$payload")" "$(jq -r '.line // ""' <<<"$payload")" >/dev/null 2>&1 || return 1
    # <<< archie send
    _aw_count_bump
    AW_GATE_LAST=sent; return 0
  fi
  [ "${AW_GATE_RC:-1}" = 2 ] || { _aw_log "beat: today's count is unreadable; not sent, retried next tick"; return 1; }
  line=$(jq -r '.line // empty' <<<"$payload" 2>/dev/null)
  [ -n "$line" ] || return 1
  key="dg-$(_aw_sha8 "$line")"
  detail=$(jq -nc --arg l "$line" --arg a "$(jq -r '.akey // ""' <<<"$payload")" --arg t "$AW_NOWISO" \
    '{line: $l[0:3500], akey: $a, queued_at: $t}')
  job_ledger_put archie_digest "$key" queued "$detail" >/dev/null 2>&1 || return 1
  _aw_held_mark
  _aw_log "beat: held $key for the digest ($(_aw_quiet && echo 'quiet hours' || echo "today's cap $AW_CAP"))"
  AW_GATE_LAST=queued
  return 0
}

# The digest ledger is read only while state/archie/digest-queued says this
# box held something, so a tick with nothing held costs no request. The marker
# goes once a digest left nothing queued; a lost marker (a wiped state/) defers
# the held rows to the next digest, it never drops them.
_aw_held_file() { printf '%s/state/archie/digest-queued' "$(_aw_root)"; }
_aw_held_mark() { local f; f=$(_aw_held_file); mkdir -p "${f%/*}" 2>/dev/null && : > "$f"; }

archie_digest_flush() {
  local before="" bk="" page=0 resp rc all="[]" n plan text keys k left=0
  [ -n "$(_aw_root)" ] && [ -f "$(_aw_held_file)" ] || return 0
  _aw_quiet && return 0
  while [ "$page" -lt "$AW_PAGES_MAX" ]; do
    page=$((page + 1))
    resp=$(ledger_page archie_digest 100 "$before" "$bk" 2>/dev/null); rc=$?
    [ "$rc" = 2 ] && break
    if [ "$rc" != 0 ] || ! jq -e '.ledgers | type == "array"' <<<"$resp" >/dev/null 2>&1; then
      _aw_down "digest list"; return 0
    fi
    all=$(jq -c --argjson a "$all" '$a + [.ledgers[] | select(.status == "queued")]' <<<"$resp")
    n=$(jq '.ledgers | length' <<<"$resp")
    [ "$n" -ge 100 ] || break
    before=$(jq -r '.ledgers[-1].updated_at' <<<"$resp"); bk=$(jq -r '.ledgers[-1].key' <<<"$resp")
  done
  [ "$(jq length <<<"$all")" -gt 0 ] || { [ "$page" -ge "$AW_PAGES_MAX" ] || rm -f "$(_aw_held_file)"; return 0; }
  _aw_beat_allowed digest || return 0
  # Oldest first; whole updates only, the rest stay queued for the next one.
  plan=$(jq -c --argjson max "$AW_DIGEST_MAX" '
    [sort_by(.updated_at, .key)[] | {key, body: ((.detail // "" | try fromjson catch {}).line // "" | sub("\\s*\\n\\s*Archie\\s*$"; ""))}
      | select(.body != "")]
    | reduce .[] as $r ({inc: [], len: 0, rest: 0};
        if .rest == 0 and (.inc == [] or .len + ($r.body | length) + 2 <= $max)
        then .inc += [$r] | .len += ($r.body | length) + 2 else .rest += 1 end)' <<<"$all")
  [ "$(jq '.inc | length' <<<"$plan")" -gt 0 ] || return 0
  text=$(jq -r '"Held \(.inc | length) update\(if (.inc | length) == 1 then "" else "s" end) (quiet hours / today'"'"'s cap). Here they are.\n\n"
    + ([.inc[].body] | join("\n\n"))
    + (if .rest > 0 then "\n\n+\(.rest) more held for the next digest." else "" end)' <<<"$plan")
  command -v archie_sign >/dev/null 2>&1 && text=$(archie_sign "$text")
  keys=$(jq -r '.inc[].key' <<<"$plan")
  if ! "$(_aw_root)/bin/archie-tg-send.sh" "archie:digest:$(_aw_sha8 "$keys")" "$text" >/dev/null 2>&1; then
    _aw_log "digest: not delivered; $(jq '.inc | length' <<<"$plan") held updates stay queued"
    return 0
  fi
  _aw_count_bump
  while IFS= read -r k; do
    job_ledger_put archie_digest "$k" sent >/dev/null 2>&1 && continue
    _aw_log "warn: digest row $k was sent but could not be marked sent"; left=1
  done <<<"$keys"
  [ "$left" = 0 ] && [ "$(jq .rest <<<"$plan")" = 0 ] && [ "$page" -lt "$AW_PAGES_MAX" ] && rm -f "$(_aw_held_file)"
  _aw_log "digest: sent $(jq '.inc | length' <<<"$plan") held updates in one message"
}
