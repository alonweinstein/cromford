#!/bin/bash
# shellcheck shell=bash
# bin/lib/br/opt/parentprio.sh — BH-5741: a BLOCKed parent PR with approved
# stacked children gets the next fix round, and pages once when none starts.
#
# WHY. On 2026-10-09, 16 approved PRs waited outside the merge queue because
# they were stacked on 9 parents that had not merged, and 4 of those parents
# carried a lead BLOCK that no fix round picked up (#4942 with 4 children,
# #4908 with 2, #4761, #4332). Every child of a parent waits on the parent, so
# that parent's fix round is worth more than an ordinary one.
#
# TWO HOOKS (bin/lib/br/opt/README.md):
#   br_opt_parent_children  called by br_rank_rows for each rank-4 row. Prints
#                           "<n>\t<#a #b ...>": n > 0 promotes the row to rank 3
#                           (below main-red, above ordinary rows).
#   br_opt_parent_wait      called once per tick after the dispatch loop. Keeps
#                           $ST/.parent-wait.tsv and writes ONE lane-alert line
#                           per parent episode after BR_PARENT_WAIT_ALERT_MIN
#                           with no fix round started.
#
# A "standing BLOCK" is the reason review-changes-requested or
# head-not-reapproved: the two reasons br_action sends to a fix round because a
# reviewer refused the head. A "child" is an open, non-draft PR in the same repo
# whose base is the parent's head branch (the conductor's STACKED_WAIT test). It
# is "approved" when mc_verdict answers APPROVE bound to the child's current
# head, to "-" (a ledger row from before reviewed_sha), or to the sha the
# conductor's pr-state.tsv row records as reviewed for that same head.
#
# Defines functions only. Nothing runs on source.

# _br_pp_once <tag> <line> — say <line> once per tick. The tick file carries a
# "#<tag>" marker; with no tick file the line is said every time.
_br_pp_once() {
  local tf="${BR_PARENT_TICK:-}"
  if [ -n "$tf" ] && [ -w "$tf" ]; then
    grep -qxF "#$1" "$tf" 2>/dev/null && return 0
    printf '#%s\n' "$1" >> "$tf"
  fi
  say "$2"
}

# _br_pp_approved <slug> <num> <url> <head> — rc 0 when the child's approval is
# one the conductor merges on. Memoised per url for the life of the caller's
# shell (one br_rank_rows pass), because one parent can come from two sources.
_br_pp_approved() {
  local slug="$1" num="$2" url="$3" head="$4" v vv vsha rows rc=1
  [ "${_BR_PP_MEMO_INIT:-}" = 1 ] || { declare -gA _BR_PP_MEMO=(); _BR_PP_MEMO_INIT=1; }
  if [ -n "${_BR_PP_MEMO[$url]+x}" ]; then return "${_BR_PP_MEMO[$url]}"; fi
  v=$(mc_verdict "$url" "" 2>/dev/null)
  IFS=$'\t' read -r vv _ vsha _ _ <<<"$v"
  if [ "${vv:-}" = APPROVE ]; then
    case "${vsha:--}" in
      "$head"|-) rc=0 ;;
      *) rows="${MC_ROWS:-$H/state/merge-conductor/pr-state.tsv}"
         awk -F'\t' -v k="$slug#$num" -v h="$head" -v s="$vsha" \
           '$1 == k && $4 == h && $5 == s { f = 1; exit } END { exit !f }' "$rows" 2>/dev/null && rc=0 ;;
    esac
  fi
  _BR_PP_MEMO[$url]=$rc
  return "$rc"
}

# br_opt_parent_children <p> <rkey> <reason> <url> <tkey>
#   -> "<n>\t<#a #b ...>", rc 0. "0\t" on every "not a promoted parent" path,
#   which is today's rank. Appends "<p>\t<ck>\t<url>\t<n>\t<nums>\t<reason>" to
#   $BR_PARENT_TICK when the parent has children (n may be 0 when none of them
#   is approved, so the wait pass keeps the row instead of pruning it).
br_opt_parent_children() {
  local p="${1:-}" rkey="${2:-}" reason="${3:-}" url="${4:-}" tkey="${5:--}"
  local slug num list kids cn curl chead n=0 nkids=0 nums="" ck
  case "$reason" in review-changes-requested|head-not-reapproved) ;; *) printf '0\t\n'; return 0 ;; esac
  [ -n "$p" ] && [ "$p" != - ] || { printf '0\t\n'; return 0; }
  command -v mc_verdict >/dev/null 2>&1 && command -v br_open_prs >/dev/null 2>&1 \
    || { printf '0\t\n'; return 0; }
  slug=$(br_slug_of_url "$url") || { printf '0\t\n'; return 0; }
  num=$(mc_num_of_url "$url")
  [ -n "$num" ] || { printf '0\t\n'; return 0; }
  if command -v gh_budget_low >/dev/null 2>&1 && gh_budget_low blocked-resolver >/dev/null 2>&1; then
    _br_pp_once budget-low "parent ranking skipped this tick — the GitHub API budget is low; every BLOCKed parent keeps its rank"
    printf '0\t\n'; return 0
  fi
  br_use_token "$slug"
  list=$(br_open_prs "$slug") || list=""
  br_reset_token
  if [ -z "$list" ]; then
    _br_pp_once "list-$slug" "parent ranking skipped for $slug this tick — the open-PR list did not read; its BLOCKed PRs keep their rank"
    printf '0\t\n'; return 0
  fi
  kids=$(printf '%s' "$list" | jq -r --argjson n "$num" '
      (map(select(.number == $n)) | .[0].headRefName // "") as $b
      | if $b == "" then empty else
          .[] | select(.baseRefName == $b and (.isDraft != true) and .number != $n)
          | [(.number | tostring), (.url // ""), (.headRefOid // "")] | @tsv
        end' 2>/dev/null)
  while IFS=$'\t' read -r cn curl chead; do
    [ -n "${cn:-}" ] && [ -n "${chead:-}" ] || continue
    [ -n "$curl" ] || curl="https://github.com/$slug/pull/$cn"
    nkids=$((nkids + 1))
    _br_pp_approved "$slug" "$cn" "$curl" "$chead" || continue
    n=$((n + 1)); nums="${nums:+$nums }#$cn"
  done <<<"$kids"
  if [ "$nkids" -gt 0 ] && [ -n "${BR_PARENT_TICK:-}" ] && [ -w "$BR_PARENT_TICK" ]; then
    ck=$(br_cap_key "$p" "$rkey" "$tkey")
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$p" "$ck" "$url" "$n" "${nums:--}" "$reason" >> "$BR_PARENT_TICK"
  fi
  printf '%s\t%s\n' "$n" "$nums"
}

# _br_pp_nums <nums> — the first 5 children, then "+N more".
_br_pp_nums() {
  local -a a
  read -r -a a <<<"$1"
  if [ "${#a[@]}" -le 5 ]; then printf '%s' "${a[*]}"
  else printf '%s +%s more' "${a[*]:0:5}" "$(( ${#a[@]} - 5 ))"; fi
}

# _br_pp_alert <p> <ck> <url> <reason> <n> <nums> <age-s> <first_seen> <queue-note>
_br_pp_alert() {
  local p="$1" ck="$2" url="$3" reason="$4" n="$5" nums="$6" age="$7" fs="$8" qn="$9" since line
  since=$(date -u -d "@$fs" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || since="epoch $fs"
  line="[blocked-resolver] PARENT BLOCKED $p: $url has a standing BLOCK ($reason). $n approved child PR(s) wait on it ($(_br_pp_nums "$nums")). No fix round started in $((age / 60)) min (since $since).${qn:+ $qn} Check logs/blocked-resolver.log for this PR and the fix-round queue."
  if [ -x "$H/bin/lane-alert.sh" ]; then
    "$H/bin/lane-alert.sh" --id "parent-blocked-children-$p-$ck" blocked-resolver "$line" >/dev/null 2>&1 || true
  else
    HARNESS="$H" "$H/bin/alert-line.sh" "$line"
    "$H/bin/beat.sh" "$(jq -nc --arg p "$p" --arg akey "parent-blocked-children-$p-$ck" --arg l "$line" \
      '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1 || true
  fi
  say "$p/$ck: PARENT BLOCKED — $n approved child PR(s) wait, no fix round for $((age / 60)) min; one ALERTS line written"
}

# _br_pp_row <p> <ck> <url> <fs> <fix0> <alerted> — decide one ledger row and
# append it to the caller's out[]. Reads the caller's tn treason tnums now knob
# (bash dynamic scope); only br_opt_parent_wait calls it.
_br_pp_row() {
  local p="$1" ck="$2" url="$3" fs="$4" fix0="$5" al="$6" k="$1/$2" fr age frow frc fst qn
  fr=$(br_num "$(br_load "$p" "$ck")" fixrounds)
  if [ "$fr" -gt "$fix0" ]; then
    say "$p/$ck: parent wait clock restarted — a fix round started (fixrounds $fix0 -> $fr)"
    out+=("$p"$'\t'"$ck"$'\t'"$url"$'\t'"$now"$'\t'"$fr"$'\t'0); return 0
  fi
  [ "$fr" -ge "$fix0" ] || fix0="$fr"
  age=$((now - fs)); [ "$age" -ge 0 ] || age=0
  if [ "$knob" = 0 ] || [ "$al" != 0 ] || [ "$age" -lt $((knob * 60)) ] \
     || { command -v lane_project_held >/dev/null 2>&1 && lane_project_held blocked-resolver "$p"; }; then
    out+=("$p"$'\t'"$ck"$'\t'"$url"$'\t'"$fs"$'\t'"$fix0"$'\t'"$al"); return 0
  fi
  qn=""
  if command -v fix_round_get >/dev/null 2>&1; then
    frc=0; frow=$(fix_round_get "$p" "$ck" 2>/dev/null) || frc=$?
    case "$frc" in
      0) fst=$(printf '%s' "$frow" | jq -r '.status // ""' 2>/dev/null)
         case "$fst" in
           queued|claimed|done)
             say "$p/$ck: parent waits ${age}s, but a fix round is $fst on the queue — no parent alert"
             out+=("$p"$'\t'"$ck"$'\t'"$url"$'\t'"$fs"$'\t'"$fix0"$'\t'"$al"); return 0 ;;
         esac ;;
      2) ;;
      *) qn="The fix-round queue was unreadable this tick." ;;
    esac
  fi
  _br_pp_alert "$p" "$ck" "$url" "${treason[$k]:--}" "${tn[$k]}" "${tnums[$k]:-}" "$age" "$fs" "$qn"
  # The stamp is written whatever the send answered (the STARVED rule).
  out+=("$p"$'\t'"$ck"$'\t'"$url"$'\t'"$fs"$'\t'"$fix0"$'\t'"$now")
}

# br_opt_parent_wait <tick-file> — the wait clock and the one alert per episode.
#
# Ledger $ST/.parent-wait.tsv, one row per parent:
#   <p>\t<ck>\t<url>\t<first_seen>\t<fixrounds_at_first_seen>\t<alerted>
# A dotfile, like .last-visited.tsv: br_record_index globs "$ST"/*/*.json.
# A row is pruned when its parent left the stream of a project this tick saw
# ($ALLSEEN), so a single-project run never drops another project's rows. A
# parent seen with 0 approved children (a verdict outage) keeps its row as is.
# THE LEDGER IS SHARED BY CONCURRENT PROJECT RUNS (BH-5913): the dispatcher
# starts one run per project and their ticks end at once. Each rewrite keeps the
# other projects' rows, so the read-modify-write takes a short lock. A lock not
# taken in 5 seconds is not worth a lost tick: the rewrite goes ahead, the
# br_visited_put precedent.
br_opt_parent_wait() {
  (
    exec 9>"$H/locks/blocked-resolver-parent-wait.lock" || exit 0
    flock -w 5 9 2>/dev/null || true
    _br_opt_parent_wait_locked "$@"
  )
  return 0
}
_br_opt_parent_wait_locked() {
  local tf="${1:-}" knob now led tmp a b c d e f key
  local -A tn=() turl=() tnums=() treason=() done_k=()
  local -a out=()
  [ -n "$tf" ] && [ -r "$tf" ] || return 0
  knob="${BR_PARENT_WAIT_ALERT_MIN:-120}"
  case "$knob" in
    ''|*[!0-9]*) say "BR_PARENT_WAIT_ALERT_MIN='$knob' is not a number of minutes — the parent wait alert uses 120"
                 knob=120 ;;
  esac
  now=$(date -u +%s)
  led="$ST/.parent-wait.tsv"
  # The tick's parents. Two sources can name one parent: keep the higher count.
  while IFS=$'\t' read -r a b c d e f; do
    case "${a:-}" in ''|'#'*) continue ;; esac
    case "${d:-}" in ''|*[!0-9]*) continue ;; esac
    key="$a/$b"
    if [ -z "${tn[$key]+x}" ] || [ "$d" -gt "${tn[$key]}" ]; then
      tn[$key]="$d"; turl[$key]="$c"; tnums[$key]="$e"; treason[$key]="$f"
    fi
  done < "$tf"
  if [ -r "$led" ]; then
    while IFS=$'\t' read -r a b c d e f; do
      [ -n "${a:-}" ] && [ -n "${b:-}" ] || continue
      key="$a/$b"
      [ -z "${done_k[$key]+x}" ] || continue
      done_k[$key]=1
      d=$(br_epoch_or_zero "${d:-}"); e=$(br_epoch_or_zero "${e:-}"); f=$(br_epoch_or_zero "${f:-}")
      if [ -n "${tn[$key]+x}" ]; then
        if [ "${tn[$key]}" -gt 0 ]; then _br_pp_row "$a" "$b" "${turl[$key]:-$c}" "$d" "$e" "$f"
        else out+=("$a"$'\t'"$b"$'\t'"$c"$'\t'"$d"$'\t'"$e"$'\t'"$f"); fi
      elif [[ " ${ALLSEEN:-} " == *" $a "* ]]; then
        say "$a/$b: parent wait row dropped — the parent left the candidate stream"
      else
        out+=("$a"$'\t'"$b"$'\t'"$c"$'\t'"$d"$'\t'"$e"$'\t'"$f")
      fi
    done < "$led"
  fi
  for key in "${!tn[@]}"; do
    [ -z "${done_k[$key]+x}" ] || continue
    [ "${tn[$key]}" -gt 0 ] || continue
    a="${key%%/*}"; b="${key#*/}"
    out+=("$a"$'\t'"$b"$'\t'"${turl[$key]}"$'\t'"$now"$'\t'"$(br_num "$(br_load "$a" "$b")" fixrounds)"$'\t'0)
  done
  [ -r "$led" ] || [ "${#out[@]}" -gt 0 ] || return 0
  mkdir -p "$ST" 2>/dev/null
  tmp="$led.tmp.$$"
  if { [ "${#out[@]}" = 0 ] || printf '%s\n' "${out[@]}"; } > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$led"
  else
    rm -f "$tmp"
    say "could not rewrite $led — the parent wait clocks are unchanged this tick"
  fi
  return 0
}
