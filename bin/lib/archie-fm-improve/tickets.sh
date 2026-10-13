#!/bin/bash
# shellcheck shell=bash
# bin/lib/archie-fm-improve/tickets.sh — BH-4587 (BH-4574.5): the GitHub half of
# Archie's self-improvement loop. Sourced by bin/archie-fm-improve.sh, never
# run: no `set -e`, no `exit`, nothing at source time.
#
# One fingerprint, one issue, for its whole life. The issue carries the marker
# <!-- archie-fm-improve:fp=<fp> --> and the labels ai-build and
# archie-fm-improve. The label list (state=all) is the record of every filing,
# so the dedupe never trusts the ledger read alone (its rows age out):
#   no issue          count >= recur_n in the window  -> afi_file (one issue)
#   open              new occurrences since the filing or the last comment
#                                                     -> afi_comment (one per UTC day)
#   closed completed  afi_track (one track_merged row per close), then
#                     a recurrence past the grace     -> afi_reopen (comment, then PATCH)
#                     verify_days of silence          -> afi_verify (one row + one comment)
#   closed otherwise  (not_planned: a person chose it) -> nothing
#
# Every GitHub write is claim (started) -> write -> close done|failed, with
# afq_claim's key. Done only on a 201/200 with the expected field. Observe mode
# writes the would_* row and nothing else.
# Globals the caller sets: AFI_REPO, AFI_MODE, AFI_LBL, AFI_OPEN (the lists
# afi_issue_lists wrote), and everything common.sh reads.
# gh-rest: no-graphql

AFI_LBL_PAGES=5; AFI_OPEN_PAGES=10; AFI_TIMELINE_MAX=30; AFI_N_TIMELINE=0

# afi_marker <fp> -> the marker line an issue body carries.
afi_marker() { printf '<!-- archie-fm-improve:fp=%s -->' "$1"; }

# afi_issue_lists — read the label list (state=all, <= AFI_LBL_PAGES pages) and
#   the open issues (<= AFI_OPEN_PAGES pages) of AFI_REPO into AFI_LBL and
#   AFI_OPEN, one JSON object per issue: {n, state, reason, created, closed,
#   url, fp, cause}. rc 1: a page could not be read or a list is longer than
#   its cap; one log line, and the caller claims nothing this tick.
afi_issue_lists() {
  local what q max f out page rc st n
  : > "$AFI_LBL"; : > "$AFI_OPEN"
  f=$(mktemp "${TMPDIR:-/tmp}/afi-issues.XXXXXX") || { afi_log "mktemp failed; no claim this tick"; return 1; }
  for what in lbl open; do
    if [ "$what" = lbl ]; then q="labels=$AFI_LABEL&state=all"; max=$AFI_LBL_PAGES; out=$AFI_LBL
    else q="state=open"; max=$AFI_OPEN_PAGES; out=$AFI_OPEN; fi
    page=1
    while :; do
      if [ "$page" -gt "$max" ]; then
        rm -f "$f"; afi_log "the $what issue list of $AFI_REPO is longer than $max pages; no claim this tick (a duplicate could not be ruled out)"
        afi_alert_once "list-cap-$what" "the $what issue list of $AFI_REPO is longer than $max pages (AFI_${what^^}_PAGES); the lane files and tracks nothing until an operator raises the cap or the list shrinks"
        return 1
      fi
      rc=0; GH_ETAG=0 gh_rest GET "repos/$AFI_REPO/issues?$q&per_page=100&page=$page" > "$f" 2>/dev/null || rc=$?
      st=${GH_REST_STATUS:-000}
      if [ "$rc" != 0 ] || ! jq -e 'type == "array"' "$f" >/dev/null 2>&1; then
        rm -f "$f"; afi_log "the $what issue list of $AFI_REPO could not be read (page $page, HTTP $st, rc=$rc); no claim this tick"
        return 1
      fi
      jq -c '.[] | select(.pull_request == null)
        | {n: .number, state: .state, reason: (.state_reason // ""), created: (.created_at // ""),
           closed: (.closed_at // ""), url: (.html_url // ""),
           fp: (((.body // "") | [scan("<!-- archie-fm-improve:fp=([0-9a-f]{12}) -->")] | .[0][0]) // null),
           cause: (((.body // "") | [scan("(?m)^Cause: `([^`\n]*)`")] | .[0][0]) // null)}' "$f" >> "$out"
      n=$(jq length "$f")
      [ "$n" -lt 100 ] && break
      page=$((page + 1))
    done
  done
  rm -f "$f"
  return 0
}

# afi_issue_of <fp> -> the newest label-list issue whose body carries the marker.
afi_issue_of() { jq -sc --arg fp "$1" '[.[] | select(.fp == $fp)] | sort_by(.n) | last // empty' "$AFI_LBL"; }

# afi_open_hit <fp> -> the url of an open issue (anyone's) carrying the marker.
afi_open_hit() { jq -sr --arg fp "$1" '[.[] | select(.fp == $fp)] | sort_by(.n) | .[0].url // empty' "$AFI_OPEN"; }

# afi_occ_lines <occ-array> [max] -> markdown lines, newest last: the time, the
#   playbook, the PR link (pr > 0), the alert id or issue url of the evidence,
#   and the fix Archie applied by hand (that row's action, outcome and why).
afi_occ_lines() {
  jq -r --argjson m "${2:-10}" '.[-$m:][] | .row as $r
    | "- \($r.created_at) \($r.playbook) `\(.k)`"
      + (if ($r.pr // 0) > 0 then " https://github.com/\($r.repo)/pull/\($r.pr)" else "" end)
      + (if ($r.evidence.alert_id // "") != "" then " alert `\($r.evidence.alert_id)`" else "" end)
      + (if ($r.evidence.issue // "") != "" then " \($r.evidence.issue)" elif ($r.evidence.lever.issue // "") != "" then " \($r.evidence.lever.issue)" else "" end)
      + "\n  The fix Archie applied by hand: \($r.action) -> \($r.outcome): \(($r.why // "") | gsub("\n"; " ") | .[0:300])"' <<<"$1"
}

# afi_claim <key> <action> <why> <evidence-json> -> afq_claim's rc, with the
#   mode word (would_<action> in observe) and the counters for rc 3 / other.
afi_claim() {
  local act="$2" rc=0
  [ "$AFI_MODE" = on ] || act="would_$2"
  afq_claim improve "$1" hub "$AFI_REPO" 0 "$AFI_MODE" "$act" "$3" "$4" || rc=$?
  case "$rc" in
    0) ;;
    3) AFI_N_SKIPPED=$((AFI_N_SKIPPED + 1)) ;;
    2) ;;
    *) AFI_N_FAILED=$((AFI_N_FAILED + 1)) ;;
  esac
  if [ "$rc" = 0 ] && [ "$AFI_MODE" != on ]; then AFI_N_WOULD=$((AFI_N_WOULD + 1)); AFM_ROW=""; fi
  return "$rc"
}

# afi_close <outcome> <why> <evidence-json> — close the claimed row.
afi_close() {
  afq_close improve "$1" "" "$2" "$3" || afi_log "$(jq -r '.dedupe_key // ""' <<<"$AFM_ROW"): the outcome $1 could not be written; the row stays started"
  [ "$1" = failed ] && AFI_N_FAILED=$((AFI_N_FAILED + 1))
  AFM_ROW=""
}

# afi_post_comment <issue-n> <body-file> -> rc 0 and AFI_URL on a 201 with an id.
afi_post_comment() {
  local f rc=0
  AFI_URL=""; AFI_ST=""
  f=$(mktemp "${TMPDIR:-/tmp}/afi-c.XXXXXX") || return 1
  gh_rest POST "repos/$AFI_REPO/issues/$1/comments" -F "body=@$2" > "$f" 2>/dev/null || rc=$?
  AFI_ST=${GH_REST_STATUS:-000}
  AFI_URL=$(jq -r 'select(.id != null) | .html_url // ("comment " + (.id | tostring))' "$f" 2>/dev/null)
  rm -f "$f"
  [ "$rc" = 0 ] && [ "$AFI_ST" = 201 ] && [ -n "$AFI_URL" ]
}

# afi_file <fp> <occ-array> — ONE issue for a recurring cause with no filing.
afi_file() {
  local fp="$1" occ="$2" c cnt key why ev url bf f rc st title pb hit n
  c=$(jq -r '.[0].c' <<<"$occ"); cnt=$(jq length <<<"$occ"); pb=$(jq -r '.[-1].pb' <<<"$occ")
  hit=$(afi_open_hit "$fp")
  if [ "$AFI_MODE" = on ] && [ -z "$hit" ] && ! afi_cap_ok ticket; then AFI_N_CAPPED=$((AFI_N_CAPPED + 1)); return 0; fi
  key="improve:ticket:$fp:$DAY:$AFI_MODE"
  why="$c recurred $cnt times in $AFI_WINDOW_D days"
  ev=$(jq -nc --arg fp "$fp" --arg c "$c" --argjson n "$cnt" --argjson w "$AFI_WINDOW_D" --argjson o "$occ" \
    '{fp: $fp, cause: $c, count: $n, window_days: $w, occurrences: [$o[-20:][].k]}')
  afi_claim "$key" file_ticket "${why:0:500}" "$ev" || return $(( $? == 2 ? 2 : 0 ))
  [ "$AFI_MODE" = on ] || return 0
  if [ -n "$hit" ]; then
    afi_close done "already filed: $hit" "$(jq -c --arg u "$hit" '. + {issue_url: $u, existing: true}' <<<"$ev")"
    AFI_N_SKIPPED=$((AFI_N_SKIPPED + 1)); afi_log "$fp: already filed: $hit"
    return 0
  fi
  title="Archie: ${c:0:120} recurred $cnt times in $AFI_WINDOW_D days"
  bf=$(mktemp "${TMPDIR:-/tmp}/afi-body.XXXXXX") || { afi_close failed "mktemp failed" "$ev"; return 0; }
  {
    printf 'We fixed the same thing by hand %s times in the last %s days. That is a factory bug, so we are filing it once.\n\n' "$cnt" "$AFI_WINDOW_D"
    printf 'Cause: `%s`\n' "$c"
    printf 'Fingerprint: `%s`\n\n' "$fp"
    printf '## What happened\n\n'
    afi_occ_lines "$occ" 10
    printf '\n## Acceptance tests\n\n'
    printf -- '- A fixture that reproduces this cause (`%s`) is handled by the owning lane, and no `archie_actions` row of playbook `%s` is written for it.\n' "$c" "$pb"
    printf -- '- After the fix merges, the recurrence count of fingerprint `%s` stays 0 for %s days. Archie checks that and reopens this issue if it comes back.\n\n' "$fp" "$AFI_VERIFY_D"
    printf 'Archie does not write the fix. He tracks this issue to its merged PR and checks the cause stopped.\n\n'
    afi_marker "$fp"; printf '\n'
  } > "$bf"
  f=$(mktemp "${TMPDIR:-/tmp}/afi-issue.XXXXXX") || { rm -f "$bf"; afi_close failed "mktemp failed" "$ev"; return 0; }
  rc=0; gh_rest POST "repos/$AFI_REPO/issues" -f "title=$title" -F "body=@$bf" \
    -f "labels[]=ai-build" -f "labels[]=$AFI_LABEL" > "$f" 2>/dev/null || rc=$?
  st=${GH_REST_STATUS:-000}
  url=$(jq -r '.html_url // empty' "$f" 2>/dev/null)
  n=$(jq -r '.number // empty' "$f" 2>/dev/null)
  rm -f "$f" "$bf"
  if [ "$rc" = 0 ] && [ "$st" = 201 ] && [ -n "$url" ]; then
    afi_close done "filed $url" "$(jq -c --arg u "$url" --arg n "$n" '. + {issue_url: $u, issue: ($n | tonumber? // null)}' <<<"$ev")"
    AFI_N_FILED=$((AFI_N_FILED + 1)); AFI_W_USED=$((AFI_W_USED + 1)); AFI_T_USED=$((AFI_T_USED + 1))
    afi_log "$fp: filed $url ($c, $cnt in $AFI_WINDOW_D days)"
  else
    afi_close failed "filing the issue on $AFI_REPO answered HTTP $st (rc=$rc)" "$ev"
    afi_log "$fp: filing answered HTTP $st (rc=$rc); retried on a later UTC day"
  fi
}

# afi_comment <fp> <issue-json> — the open tracked issue gets ONE comment per
#   UTC day listing the occurrences since the filing or the last comment.
afi_comment() {
  local fp="$1" iss="$2" n since last new cnt key ev bf c
  n=$(jq -r .n <<<"$iss")
  since=$(afi_epoch "$(jq -r .created <<<"$iss")") || since=0
  last=$(afi_imp_rows "$fp" | jq -r --arg m "$AFI_MODE" --argjson n "$n" "$AFI_JQ_DEFS"'
    [.[] | select(.mode == $m) | select(.action | sub("^would_"; "") | . == "comment" or . == "reopen")
     | select(.outcome == "done" or .outcome == "would") | select((.evidence.issue // 0) == $n) | epoch] | max // 0')
  [ "$last" -gt "$since" ] && since=$last
  new=$(afi_occ_of "$fp" "$since")
  cnt=$(jq length <<<"$new")
  [ "$cnt" -gt 0 ] || return 0
  if [ "$AFI_MODE" = on ] && ! afi_cap_ok write; then AFI_N_CAPPED=$((AFI_N_CAPPED + 1)); return 0; fi
  c=$(jq -r '.[0].c' <<<"$new")
  key="improve:comment:$fp:$n:$DAY:$AFI_MODE"
  ev=$(jq -nc --arg fp "$fp" --arg c "$c" --argjson n "$n" --argjson k "$cnt" --argjson o "$new" \
    '{fp: $fp, cause: $c, issue: $n, count: $k, occurrences: [$o[-20:][].k]}')
  afi_claim "$key" comment "$cnt new occurrences of $c since the last update" "$ev" || return $(( $? == 2 ? 2 : 0 ))
  [ "$AFI_MODE" = on ] || return 0
  bf=$(mktemp "${TMPDIR:-/tmp}/afi-body.XXXXXX") || { afi_close failed "mktemp failed" "$ev"; return 0; }
  { printf 'It happened again: %s more since our last update on this issue.\n\n' "$cnt"
    afi_occ_lines "$new" 10; printf '\n'; afi_marker "$fp"; printf '\n'; } > "$bf"
  if afi_post_comment "$n" "$bf"; then
    afi_close done "commented $AFI_URL" "$ev"
    AFI_N_COMMENTED=$((AFI_N_COMMENTED + 1)); AFI_W_USED=$((AFI_W_USED + 1))
    afi_log "$fp: commented on #$n ($cnt new)"
  else
    afi_close failed "the comment on #$n answered HTTP $AFI_ST" "$ev"
  fi
  rm -f "$bf"
}

# afi_timeline <issue-n> -> rc 0 and "<pr>\t<pr_url>\t<merged_at>" of the
#   latest merged cross-referenced PR of AFI_REPO (empty line: none); rc 1
#   unreadable. One page; at most AFI_TIMELINE_MAX reads per tick.
afi_timeline() {
  local f rc=0
  [ "$AFI_N_TIMELINE" -lt "$AFI_TIMELINE_MAX" ] || { afi_log "#$1: $AFI_TIMELINE_MAX timeline reads this tick; the rest wait"; return 1; }
  AFI_N_TIMELINE=$((AFI_N_TIMELINE + 1))
  f=$(mktemp "${TMPDIR:-/tmp}/afi-tl.XXXXXX") || return 1
  gh_rest GET "repos/$AFI_REPO/issues/$1/timeline?per_page=100" > "$f" 2>/dev/null || rc=$?
  if [ "$rc" != 0 ] || ! jq -e 'type == "array"' "$f" >/dev/null 2>&1; then
    rm -f "$f"; afi_log "#$1: the timeline could not be read (HTTP ${GH_REST_STATUS:-000}, rc=$rc); tracked on a later tick"; return 1
  fi
  jq -r --arg r "$AFI_REPO" '[.[] | select(.event == "cross-referenced") | .source.issue // empty
      | select(.pull_request.merged_at != null)
      | select((.repository.full_name // "") == $r or ((.html_url // "") | startswith("https://github.com/" + $r + "/pull/")))]
    | sort_by(.pull_request.merged_at) | last
    | if . == null then "" else "\(.number)\t\(.html_url)\t\(.pull_request.merged_at)" end' "$f"
  rm -f "$f"
}

# afi_closed <fp> <issue-json> — Archie's issue closed as completed: track the
#   merge once, then reopen on a recurrence or verify after verify_days.
afi_closed() {
  local fp="$1" iss="$2" n url cl clr imp tr c occ bef bc tl pr purl mat key ev ver base after since rc
  n=$(jq -r .n <<<"$iss"); url=$(jq -r .url <<<"$iss"); clr=$(jq -r .closed <<<"$iss")
  cl=$(afi_epoch "$clr") || { afi_log "#$n: closed_at '$clr' is unreadable; skipped"; AFI_N_SKIPPED=$((AFI_N_SKIPPED + 1)); return 0; }
  c=$(afi_occ_of "$fp" | jq -r '.[0].c // empty')
  [ -n "$c" ] || c=$(jq -r '.cause // empty' <<<"$iss")
  [ -n "$c" ] || c="fingerprint $fp"
  imp=$(afi_imp_rows "$fp" | jq -c --argjson n "$n" --argjson cl "$cl" --arg m "$AFI_MODE" \
    '[.[] | select(.mode == $m and (.evidence.issue // 0) == $n and (.evidence.closed_epoch // 0) == $cl)]')
  if [ "$cl" -lt "$AFI_COVER_START" ]; then
    # Closed before anything this tick read: settled. Only recur_n new
    # occurrences inside the window reopen it.
    base=$cl
    since=$(( NOW - AFI_WINDOW_D * 86400 )); [ "$since" -gt "$base" ] || since=$base
    occ=$(afi_occ_of "$fp" "$since")
    [ "$(jq length <<<"$occ")" -ge "$AFI_RECUR_N" ] && { afi_reopen "$fp" "$n" "$cl" "$c" "$occ" "settled"; return $?; }
    return 0
  fi
  # TRACK, once per close: reads before the claim, so an unreadable timeline
  # claims nothing and is retried next tick.
  tr=$(jq -c '[.[] | select((.action | sub("^would_"; "")) == "track_merged" and (.outcome == "done" or .outcome == "would"))] | last // empty' <<<"$imp")
  if [ -z "$tr" ] && tl=$(afi_timeline "$n"); then
    IFS=$'\t' read -r pr purl mat <<<"$tl"
    bef=$(afi_occ_of "$fp" "$(( cl - AFI_WINDOW_D * 86400 - 1 ))" "$(( cl - 1 ))" | jq length)
    bc=false; afi_complete_since "$(( cl - AFI_WINDOW_D * 86400 ))" && bc=true
    ev=$(jq -nc --arg fp "$fp" --arg c "$c" --argjson n "$n" --arg u "$url" --arg pr "$pr" --arg pu "$purl" --arg m "$mat" \
      --arg cl "$clr" --argjson ce "$cl" --argjson b "$bef" --argjson bc "$bc" \
      '{fp: $fp, cause: $c, issue: $n, issue_url: $u, pr: ($pr | tonumber? // null), pr_url: (if $pu == "" then null else $pu end),
        merged_at: (if $m == "" then null else $m end), closed_at: $cl, closed_epoch: $ce, before: $b, before_complete: $bc}')
    rc=0; afi_claim "improve:track:$fp:$n:$cl:$AFI_MODE" track_merged \
      "#$n closed as completed$([ -n "$pr" ] && printf '; fixed by #%s' "$pr")" "$ev" || rc=$?
    [ "$rc" = 2 ] && return 2
    if [ "$rc" = 0 ] && [ "$AFI_MODE" = on ]; then
      afi_close done "#$n closed $clr$([ -n "$pr" ] && printf ', fix %s merged %s' "$purl" "$mat" || printf ', no merged PR found')" "$ev"
      AFI_N_TRACKED=$((AFI_N_TRACKED + 1)); afi_log "$fp: tracked #$n (closed $clr, pr ${pr:-none}, before $bef)"
    fi
    tr=$ev
  fi
  ver=$(jq -c '[.[] | select((.action | sub("^would_"; "")) == "verified" and (.outcome == "done" or .outcome == "would"))] | last // empty' <<<"$imp")
  if [ -n "$ver" ]; then
    # After a verified row, a reopen needs recur_n new occurrences again.
    base=$(jq -r "$AFI_JQ_DEFS"' epoch' <<<"$ver")
    since=$(( NOW - AFI_WINDOW_D * 86400 )); [ "$since" -gt "$base" ] || since=$base
    occ=$(afi_occ_of "$fp" "$since")
    [ "$(jq length <<<"$occ")" -ge "$AFI_RECUR_N" ] && { afi_reopen "$fp" "$n" "$cl" "$c" "$occ" "verified"; return $?; }
    return 0
  fi
  occ=$(afi_occ_of "$fp" "$(( cl + AFI_GRACE_S ))")
  after=$(jq length <<<"$occ")
  if [ "$after" -ge 1 ]; then afi_reopen "$fp" "$n" "$cl" "$c" "$occ" "watching"; return $?; fi
  [ "$NOW" -ge "$(( cl + AFI_VERIFY_D * 86400 ))" ] || return 0
  if ! afi_complete_since "$(( cl + AFI_GRACE_S ))"; then
    afi_log "$fp: #$n is $AFI_VERIFY_D days past its close with 0 recurrences read, but a day was not read in full; not verified this tick"
    return 0
  fi
  bef=""; [ -n "$tr" ] && bef=$(jq -r '.evidence.before // .before // empty' <<<"$tr" 2>/dev/null)
  [ -n "$bef" ] || bef=$(afi_occ_of "$fp" "$(( cl - AFI_WINDOW_D * 86400 - 1 ))" "$(( cl - 1 ))" | jq length)
  afi_verify "$fp" "$n" "$cl" "$clr" "$c" "$bef"
}

# afi_reopen <fp> <n> <closed-epoch> <cause> <occ-array> <phase> — the evidence
#   comment FIRST, then PATCH state=open: a reopen without evidence cannot happen.
afi_reopen() {
  local fp="$1" n="$2" cl="$3" c="$4" occ="$5" ph="$6" cnt key ev bf f rc st
  cnt=$(jq length <<<"$occ")
  if [ "$AFI_MODE" = on ] && ! afi_cap_ok write 2; then AFI_N_CAPPED=$((AFI_N_CAPPED + 1)); return 0; fi
  key="improve:reopen:$fp:$n:$cl:$DAY:$AFI_MODE"
  ev=$(jq -nc --arg fp "$fp" --arg c "$c" --argjson n "$n" --argjson ce "$cl" --argjson k "$cnt" --arg ph "$ph" --argjson o "$occ" \
    '{fp: $fp, cause: $c, issue: $n, closed_epoch: $ce, after: $k, phase: $ph, occurrences: [$o[-20:][].k]}')
  afi_claim "$key" reopen "$c came back $cnt times after #$n closed" "$ev" || return $(( $? == 2 ? 2 : 0 ))
  [ "$AFI_MODE" = on ] || return 0
  bf=$(mktemp "${TMPDIR:-/tmp}/afi-body.XXXXXX") || { afi_close failed "mktemp failed" "$ev"; return 0; }
  { printf 'This came back after the fix closed, so we are reopening it. %s occurrence(s) since %s:\n\n' "$cnt" "$(afi_iso "$cl")"
    afi_occ_lines "$occ" 10; printf '\n'; afi_marker "$fp"; printf '\n'; } > "$bf"
  if ! afi_post_comment "$n" "$bf"; then
    rm -f "$bf"; afi_close failed "the evidence comment on #$n answered HTTP $AFI_ST; not reopened" "$ev"; return 0
  fi
  rm -f "$bf"
  f=$(mktemp "${TMPDIR:-/tmp}/afi-patch.XXXXXX") || { afi_close failed "mktemp failed after the evidence comment" "$ev"; return 0; }
  rc=0; gh_rest PATCH "repos/$AFI_REPO/issues/$n" -f state=open > "$f" 2>/dev/null || rc=$?
  st=${GH_REST_STATUS:-000}
  if [ "$rc" = 0 ] && [ "$st" = 200 ] && [ "$(jq -r '.state // ""' "$f" 2>/dev/null)" = open ]; then
    afi_close done "reopened #$n with evidence ($AFI_URL)" "$ev"
    AFI_N_REOPENED=$((AFI_N_REOPENED + 1)); AFI_W_USED=$((AFI_W_USED + 2))
    afi_log "$fp: reopened #$n ($cnt after the close, $ph)"
  else
    # The comment is a GitHub write the cap counts (evidence.comment_posted).
    afi_close failed "the evidence comment posted ($AFI_URL); PATCH state=open answered HTTP $st (rc=$rc)" \
      "$(jq -c '. + {comment_posted: true}' <<<"$ev")"
    AFI_W_USED=$((AFI_W_USED + 1))
  fi
  rm -f "$f"
}

# afi_verify <fp> <n> <closed-epoch> <closed-iso> <cause> <before> — ONE
#   verified row with {before, after: 0}, and one comment that gives both.
afi_verify() {
  local fp="$1" n="$2" cl="$3" clr="$4" c="$5" bef="$6" key ev bf
  if [ "$AFI_MODE" = on ] && ! afi_cap_ok write; then AFI_N_CAPPED=$((AFI_N_CAPPED + 1)); return 0; fi
  key="improve:verified:$fp:$n:$cl:$DAY:$AFI_MODE"
  ev=$(jq -nc --arg fp "$fp" --arg c "$c" --argjson n "$n" --argjson ce "$cl" --arg cl "$clr" --argjson b "$bef" \
    '{fp: $fp, cause: $c, issue: $n, closed_epoch: $ce, closed_at: $cl, before: $b, after: 0}')
  afi_claim "$key" verified "$c: 0 recurrences in $AFI_VERIFY_D days after #$n closed (before: $bef)" "$ev" \
    || return $(( $? == 2 ? 2 : 0 ))
  [ "$AFI_MODE" = on ] || return 0
  bf=$(mktemp "${TMPDIR:-/tmp}/afi-body.XXXXXX") || { afi_close failed "mktemp failed" "$ev"; return 0; }
  { printf 'We checked: the fix held. `%s` happened %s times in the %s days before this closed, and 0 times in the %s days since.\n\n' \
      "$c" "$bef" "$AFI_WINDOW_D" "$AFI_VERIFY_D"
    afi_marker "$fp"; printf '\n'; } > "$bf"
  if afi_post_comment "$n" "$bf"; then
    afi_close done "verified: before $bef, after 0 ($AFI_URL)" "$ev"
    AFI_N_VERIFIED=$((AFI_N_VERIFIED + 1)); AFI_W_USED=$((AFI_W_USED + 1))
    afi_log "$fp: verified #$n (before $bef, after 0)"
  else
    afi_close failed "the verify comment on #$n answered HTTP $AFI_ST" "$ev"
  fi
  rm -f "$bf"
}

# afi_handle <fp> — one fingerprint: its tracked issue's next step, or a filing.
#   rc 2: the ledger route is absent (the caller stops the tick).
afi_handle() {
  local fp="$1" iss st rs occ cnt filed
  iss=$(afi_issue_of "$fp")
  if [ -n "$iss" ]; then
    st=$(jq -r .state <<<"$iss"); rs=$(jq -r .reason <<<"$iss")
    if [ "$st" = open ]; then afi_comment "$fp" "$iss"; return $?; fi
    if [ "$rs" = completed ]; then afi_closed "$fp" "$iss"; return $?; fi
    return 0   # closed not_planned (or any other reason): a person chose it.
  fi
  occ=$(afi_occ_of "$fp" "$(( NOW - AFI_WINDOW_D * 86400 ))")
  cnt=$(jq length <<<"$occ")
  [ "$cnt" -ge "$AFI_RECUR_N" ] || return 0
  AFI_N_RECUR=$((AFI_N_RECUR + 1))
  filed=$(afi_imp_rows "$fp" | jq -r '[.[] | select(.action == "file_ticket" and .mode == "on" and .outcome == "done")] | last | .evidence.issue_url // empty')
  if [ -n "$filed" ]; then
    afi_log "$fp: filed earlier ($filed) but that issue is not in the $AFI_LABEL label list; nothing filed"
    AFI_N_SKIPPED=$((AFI_N_SKIPPED + 1)); return 0
  fi
  afi_file "$fp" "$occ"
}
