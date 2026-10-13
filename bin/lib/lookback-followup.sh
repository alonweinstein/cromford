# shellcheck shell=bash
# bin/lib/lookback-followup.sh — BH-1795.4: lookback_followup_run, the 30-day
# check the weekly `lookback` lane (bin/lookback.sh) runs first. Sourced, never
# executed; no output on source. Shapes and rc convention: lookback-common.sh.
#
#   lookback_followup_run <run_dir> — prints summary lines; 0, or 75 deferred.
#
# A ledger row (kind lookback_cluster) with status `filed` whose detail.filed_at
# is at least LOOKBACK_FOLLOWUP_DAYS (30) old is due. For the due rows the
# collector runs ONCE (--days <n> --out <run_dir>/followup-bundle.json), and
# each row is matched with the shared item_matches from lookback_item_match_jq
# against the items newer than its filed_at:
#   N >= 1                 comment `recurred: N new since <date>` + the items,
#                          then status followed_up_recurred
#   N = 0, bundle complete comment `stopped: no new occurrences in <n> days`,
#                          then status followed_up_stopped
#   N = 0, not complete    nothing written; `follow-up deferred: incomplete sources`
# "Complete" means every source ok and not truncated, and .incomplete != true:
# a capped bundle cannot prove zero.
#
# The comment goes first and the status only after it posted, so a row is never
# stamped without its comment. A row with detail.repo/.issue is commented through
# gh_rest_comment, one with detail.board/.ticket_id through lookback_board_comment;
# the issue or ticket state is not read, so a closed one is still told.
# LOOKBACK_DRY=1 prints `would comment ...` and writes nothing.
#
# FIX MERGED (BH-3691). Before the comment, a row on the harness repo
# (${LOOKBACK_HARNESS_REPO:-example-org/cromford}) with a numeric issue is
# checked for a merged PR on its build branch ticket/bh-<issue>: one
# gh_rest GET pulls?state=closed&head=<owner>:ticket/bh-<issue>. The comment
# gains a last line and the ledger detail gains fix_merged:
#   yes      (+ fix_pr, the lowest merged number)  `Fix: merged in PR #<n>.`
#   none     only from a 200 list with no merged PR on exactly that head.ref
#   unknown  anything else: no gh_rest, a non-200, an unparseable body, a board
#            row or another repo                    `Fix: not checked.`
# Returns 75 when the ledger cannot be listed, or the collector is missing or fails.

_LBF_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/lib/lookback-common.sh
declare -F lookback_item_match_jq >/dev/null || . "$_LBF_LIB/lookback-common.sh" 2>/dev/null
# shellcheck source=bin/lib/lookback-board.sh
{ declare -F lookback_board_comment >/dev/null && declare -F _lbb_clean >/dev/null; } \
  || . "$_LBF_LIB/lookback-board.sh" 2>/dev/null
# shellcheck source=bin/lib/gh-rest.sh
declare -F gh_rest_comment >/dev/null || . "$_LBF_LIB/gh-rest.sh" 2>/dev/null
# BH-4080: HARNESS_REPO's default lives in the deployment defaults home.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$_LBF_LIB/deployment.sh}" || return 1

lookback_followup_run() {
  # The root is HARNESS, then H (BH-2613); with none the collector cannot be
  # found, which is the collector-missing answer (75), before any ledger read.
  local run="${1:-}" h="${HARNESS:-${H:-}}" days now rows list_rc nrows fp status row detail
  local fe bundle crc complete fu key text tmp target first rc put new_status n
  local repo issue fix fixpr fixline hrepo="${LOOKBACK_HARNESS_REPO:-$HARNESS_REPO}"
  local due=() dued=() dfe=()
  [ -n "$h" ] || { echo "follow-up skipped: no HARNESS/H root"; return 75; }
  days="${LOOKBACK_FOLLOWUP_DAYS:-30}"
  case "$days" in ''|*[!0-9]*) echo "follow-up skipped: LOOKBACK_FOLLOWUP_DAYS invalid"; return 75 ;; esac
  now=$(date -u +%s)

  declare -F job_ledger_list >/dev/null || { echo "follow-up skipped: ledger unreadable"; return 75; }
  rows=$(job_ledger_list lookback_cluster 1000); list_rc=$?
  [ "$list_rc" = 0 ] || { echo "follow-up skipped: ledger unreadable"; return 75; }
  nrows=$(printf '%s' "$rows" | grep -c . || true)
  [ "${nrows:-0}" -ge 1000 ] && echo "follow-up incomplete: ledger page full (1000 rows)"

  while IFS=$'\t' read -r fp status _ _; do
    [ -n "$fp" ] && [ "$status" = filed ] || continue
    if ! row=$(job_ledger_row lookback_cluster "$fp" </dev/null); then
      echo "follow-up skipped $fp: row unreadable"; continue
    fi
    detail=$(jq -c '.detail | if type == "string" then (try fromjson catch null) else . end
                    | select(type == "object")' <<<"$row" 2>/dev/null)
    fe=$(jq -r 'select((.key_kind // "") != "" and (.key_value // "") != "")
                | .filed_at // empty | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch empty' \
           <<<"${detail:-null}" 2>/dev/null)
    case "$fe" in ''|*[!0-9]*) echo "follow-up skipped $fp: detail incomplete"; continue ;; esac
    [ "$fe" -le $((now - days * 86400)) ] || continue
    due+=("$fp"); dued+=("$detail"); dfe+=("$fe")
  done <<<"$rows"
  [ "${#due[@]}" -gt 0 ] || return 0

  local collect="$h/bin/lookback-collect.sh"
  [ -x "$collect" ] || { echo "follow-up deferred: collector not installed"; return 75; }
  bundle="$run/followup-bundle.json"
  "$collect" --days "$days" --out "$bundle"; crc=$?
  if [ "$crc" = 0 ] && ! jq -e '.items | type == "array"' "$bundle" >/dev/null 2>&1; then crc=unparseable; fi
  [ "$crc" = 0 ] || { echo "follow-up deferred: collector rc=$crc"; return 75; }
  complete=$(jq -r '(.sources // {}) as $s
    | ($s | length) > 0 and all($s[]; .ok == true and .truncated != true) and .incomplete != true' "$bundle")

  for key in "${!due[@]}"; do
    fp="${due[$key]}"; detail="${dued[$key]}"; fe="${dfe[$key]}"
    fu=$(jq -c --argjson d "$detail" --argjson fe "$fe" "$(lookback_item_match_jq)"'
      [.items[] | select(((.at // "") | tostring | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch null) as $t
                         | $t != null and $t > $fe)
                | select(item_matches($d.key_kind; $d.key_value; ($d.project // "")))]' "$bundle" 2>/dev/null) \
      || { echo "follow-up skipped $fp: match failed"; continue; }
    n=$(jq 'length' <<<"$fu")
    if [ "$n" -gt 0 ]; then
      new_status=followed_up_recurred
      text=$(printf 'recurred: %s new since %s\n' "$n" "$(jq -r '.filed_at | .[0:10]' <<<"$detail")"
             jq -r '.[] | "- \(.id): \(.project // "?")"
                     + (if .ticket then ", ticket \(.ticket)" else "" end)
                     + (if .pr then ", PR #\(.pr)" else "" end)
                     + (if .lane then ", lane \(.lane)" else "" end)
                     + (if .reason then ": \(.reason)" else "" end)' <<<"$fu")
    elif [ "$complete" = true ]; then
      new_status=followed_up_stopped
      text="stopped: no new occurrences in $days days"
    else
      echo "follow-up deferred: incomplete sources ($fp)"; continue
    fi

    target=$(jq -r 'if (.repo // "") != "" and .issue != null then "\(.repo)#\(.issue)"
                    elif (.board // "") != "" and .ticket_id != null then "\(.board) ticket \(.ticket_id)"
                    else empty end' <<<"$detail")
    [ -n "$target" ] || { echo "follow-up skipped $fp: no issue or ticket in the row"; continue; }
    if [ "${LOOKBACK_DRY:-0}" = 1 ]; then
      first="${text%%$'\n'*}"
      echo "would comment $target $fp: $first"; continue
    fi

    tmp=$(mktemp "${TMPDIR:-/tmp}/lookback-followup.XXXXXX") || { echo "follow-up comment failed $fp"; continue; }
    # the fix check: a read, and only a 200 list can say `none`
    fix=unknown; fixpr=""
    repo=$(jq -r '.repo // ""' <<<"$detail"); issue=$(jq -r '.issue | numbers' <<<"$detail" 2>/dev/null)
    if [ "$repo" = "$hrepo" ] && [ -n "$issue" ] && [ "$(type -t gh_rest)" = function ]; then
      rc=0
      gh_rest GET "repos/$repo/pulls?state=closed&head=${repo%%/*}:ticket/bh-$issue&per_page=100" > "$tmp.pulls" || rc=$?
      if [ "$rc" = 0 ] && [ "${GH_REST_STATUS:-}" = 200 ] && jq -e 'type == "array"' "$tmp.pulls" >/dev/null 2>&1; then
        fixpr=$(jq -r --arg ref "ticket/bh-$issue" '[.[] | select(.head.ref == $ref and .merged_at != null) | .number]
                                                    | min // empty' "$tmp.pulls")
        if [ -n "$fixpr" ]; then fix=yes; else fix=none; fi
      fi
      rm -f "$tmp.pulls"
    fi
    case "$fix" in
      yes)  fixline="Fix: merged in PR #$fixpr." ;;
      none) fixline="Fix: no merged PR on ticket/bh-$issue." ;;
      *)    fixline="Fix: not checked." ;;
    esac
    printf '%s\n\n%s\n' "$text" "$fixline" | _lbb_clean > "$tmp"
    if [ "$(jq -r '(.repo // "") != "" and .issue != null' <<<"$detail")" = true ]; then
      gh_rest_comment "$(jq -r .repo <<<"$detail")" "$(jq -r .issue <<<"$detail")" "$tmp"; rc=$?
    else
      lookback_board_comment "$(jq -r .board <<<"$detail")" "$(jq -r .ticket_id <<<"$detail")" "$tmp"; rc=$?
    fi
    rm -f "$tmp"
    [ "$rc" = 0 ] || { echo "follow-up comment failed $fp"; continue; }

    put=""
    job_ledger_put lookback_cluster "$fp" "$new_status" \
      "$(jq -c --arg at "$(jq -rn --argjson t "$now" '$t | todate')" --argjson n "$n" --arg fix "$fix" --arg pr "$fixpr" \
          '. + {followed_up_at:$at, followup_new:$n, fix_merged:$fix}
             + (if $pr == "" then {} else {fix_pr: ($pr | tonumber)} end)' <<<"$detail")" \
      || put="; ledger write failed"
    fix="fix $fix${fixpr:+ #$fixpr}"
    if [ "$n" -gt 0 ]; then echo "followed up $fp: recurred $n, $fix$put"; else echo "followed up $fp: stopped, $fix$put"; fi
  done
  return 0
}
