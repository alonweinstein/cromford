#!/bin/bash
# bin/lib/mc-batch-reset.sh — WHICH MERGIFY BATCH RESETS WERE AVOIDABLE (BH-5372).
# Sourced by bin/merge-conductor.sh, never executed. OBSERVE ONLY: every GitHub
# call here is a GET, and the only writes are one log line and one attempt mark.
#
#   bres_drafts <slug>          the batch drafts that closed in the lookback, as
#                               TSV draft outcome(merged|closed) head_sha
#                               created_at closed_at members(comma-joined).
#                               A failed read is rc != 0 and prints nothing.
#                               The queue-waste ledger reads this: keep it stable.
#   bres_classify <merged-json> <draft-json>
#                               overlap|disjoint|unknown over two qp_scopes_json
#                               payloads. Unknown is never disjoint.
#   bres_tick <slug>            one `BATCH_RESET draft=<n> cause=<sha12>
#                               verdict=<v>` line per reset draft, once per
#                               (draft, cause) through the attempt marks.
#
# A RESET is a draft that closed with none of its members merged while some
# other PR's merge landed on the base between the draft's creation and its
# close (the cause). Merges are read from the base's history as
# `Merge pull request #N` commits (.mergify.yml merges with merge_method merge),
# so a direct push is not seen as a cause. Both sides' scopes come from
# qp_impact / qp_scopes_json, the same map the partitioned queue uses, so the
# verdict says whether partitioning would have kept the batch alive.
#
# Knobs (settings rows; the code default is the fallback):
#   batch_reset.lookback_s  how far back a closed draft is read (3600)
#   batch_reset.max_drafts  drafts classified per tick, oldest first (10)
# The root is ${HARNESS:-${H:-}} and nothing else (D43): empty is not opted in.
[ -n "${_BRES_LOADED:-}" ] && return 0
_BRES_LOADED=1
command -v qp_impact >/dev/null 2>&1 \
  || { [ -r "${BASH_SOURCE[0]%/*}/queue-partition.sh" ] && . "${BASH_SOURCE[0]%/*}/queue-partition.sh"; }

_bres_knob() { # _bres_knob <name> <default> — a positive integer
  local v=""
  command -v setting_get >/dev/null 2>&1 && v=$(setting_get "$1" 2>/dev/null)
  case "$v" in ''|*[!0-9]*|0) v="$2" ;; esac
  printf '%s' "$v"
}

# _bres_read <slug> — sets BRES_PULLS (the closed batch drafts, minimal fields)
# and BRES_COMMITS (the base's `Merge pull request #N` commits since the oldest
# draft opened). Runs in the caller's shell. Any failed or incomplete read
# returns its rc (75 stays 75) with both empty: never "no drafts".
_bres_read() {
  local slug="$1" cut p=1 page rc n rows="" since pre="${MC_MERGIFY_BATCH_PREFIX:-mergify/merge-queue/}"
  BRES_PULLS=""; BRES_COMMITS=""
  cut=$(( $(date -u +%s) - $(_bres_knob batch_reset.lookback_s 3600) ))
  # Newest-updated first; stop at the first page that reaches past the window.
  # Five full pages still inside it is an incomplete read, not a short list.
  while :; do
    [ "$p" -le 5 ] || return 75
    rc=0
    mc_rest_var page gh_rest GET "repos/$slug/pulls" -f state=closed -f sort=updated -f direction=desc \
      -F per_page=100 -F "page=$p" || rc=$?
    [ "$rc" = 0 ] || return "$rc"
    n=$(jq 'if type=="array" then length else -1 end' <<<"$page" 2>/dev/null)
    case "$n" in ''|-1) return 75 ;; esac
    rows+=$(jq -c --arg pre "$pre" --argjson cut "$cut" '.[]
      | select(((.head.ref // "") | startswith($pre)) and .closed_at != null
               and (.closed_at | fromdateiso8601) >= $cut)
      | {number, head_sha: .head.sha, created_at, closed_at, title: (.title // "")}' <<<"$page" 2>/dev/null) || return 75
    rows+=$'\n'
    [ "$n" -lt 100 ] && break
    [ "$(jq --argjson cut "$cut" '.[-1].updated_at | fromdateiso8601 < $cut' <<<"$page" 2>/dev/null)" = true ] && break
    p=$((p+1))
  done
  rows=$(jq -sc 'sort_by(.closed_at)' <<<"$rows" 2>/dev/null) || return 75
  [ "$rows" = '[]' ] && { BRES_PULLS='[]'; BRES_COMMITS='[]'; return 0; }
  since=$(jq -r 'map(.created_at) | min' <<<"$rows")
  # mc_rest_pages answers 75 when it runs out of pages: a cut history is a failed read.
  command -v mc_rest_pages >/dev/null 2>&1 || return 75
  rc=0
  mc_rest_var page mc_rest_pages "repos/$slug/commits?sha=${PBASE:-main}&since=$since" 10 || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  page=$(jq -c '[.[] | select((.parents | length) >= 2)
    | ((.commit.message // "") | split("\n")[0] | capture("^Merge pull request #(?<n>[0-9]+) ")) as $m
    | {sha, pr: ($m.n | tonumber), at: .commit.committer.date, head: .parents[1].sha}]' <<<"$page" 2>/dev/null)
  [ -n "$page" ] || return 75
  BRES_PULLS=$rows; BRES_COMMITS=$page
}

# _bres_rows — BRES_PULLS x BRES_COMMITS as one JSON row per draft: members,
# outcome (merged when a member's merge landed in [created, closed + 300 s];
# Mergify merges members around closing the draft) and the causes (non-member
# merges strictly inside the draft's life), oldest first.
_bres_rows() {
  printf '%s\n%s\n' "$BRES_PULLS" "$BRES_COMMITS" | jq -c -s '.[1] as $c | .[0][]
    | (.created_at | fromdateiso8601) as $o | (.closed_at | fromdateiso8601) as $x
    | ((.title | split(", stacked on")[0]) | [scan("#([0-9]+)")[0] | tonumber] | unique) as $m
    | [$c[] | . + {t: (.at | fromdateiso8601), mem: ((.pr as $p | $m | index($p)) != null)}] as $cc
    | . + {members: $m,
           outcome: (if any($cc[]; .mem and .t >= $o and .t <= $x + 300) then "merged" else "closed" end),
           causes: ([$cc[] | select((.mem | not) and .t > $o and .t < $x) | del(.t, .mem)] | sort_by(.at))}'
}

bres_drafts() {
  local rc=0
  _bres_read "${1:-}" || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  _bres_rows | jq -r '[.number, .outcome, .head_sha, .created_at, .closed_at, (.members | map(tostring) | join(","))] | @tsv'
}

bres_classify() {
  local v
  v=$(jq -rn --argjson a "${1:-}" --argjson b "${2:-}" '
    def ok: type == "object" and (.scopes | type) == "array" and (.all_scopes | type) == "boolean";
    if ($a | ok | not) or ($b | ok | not) then "unknown"
    elif $a.all_scopes or $b.all_scopes then "overlap"
    elif ($a.scopes | length) == 0 or ($b.scopes | length) == 0 then "unknown"
    elif any($a.scopes[]; . as $s | any($b.scopes[]; . == $s)) then "overlap"
    else "disjoint" end' 2>/dev/null) || v=unknown
  case "$v" in overlap|disjoint) ;; *) v=unknown ;; esac
  printf '%s\n' "$v"
}

# _bres_side <slug> <pr:head>... — the union of the PRs' scopes, or rc 1 when
# any file list is unreadable. qp_impact is never handed an empty list: it would
# call that the serial barrier, and an unread side is unknown, not overlap.
_bres_side() {
  local slug="$1" f imp ph out="" rc=0
  shift
  [ $# -gt 0 ] && command -v mc_pr_files >/dev/null 2>&1 || return 1
  f=$(mktemp "${TMPDIR:-/tmp}/bres-files.XXXXXX") || return 1
  imp=$(mktemp "${TMPDIR:-/tmp}/bres-impact.XXXXXX") || { rm -f "$f"; return 1; }
  for ph in "$@"; do
    mc_pr_files "$slug" "${ph%%:*}" "" "${ph#*:}" > "$f" 2>/dev/null && [ -s "$f" ] || { rc=1; break; }
    # shellcheck disable=SC2034  # qp_impact reads them: no train/label context here
    ( QP_TITLE="" QP_HEAD_REF="" QP_LABELS=""; qp_impact "$f" ) > "$imp"
    out+="$(qp_scopes_json "$imp")"$'\n'
  done
  rm -f "$f" "$imp"
  [ "$rc" = 0 ] || return 1
  jq -c -s '{scopes: ([.[].scopes[]] | unique), all_scopes: any(.[]; .all_scopes)}' <<<"$out"
}

bres_tick() {
  local slug="${1:-}" root conf rc=0 max done_n=0 row draft c12 key pr hd mside cside v
  local -a heads causes
  root="${HARNESS:-${H:-}}"
  [ -n "$root" ] && command -v qp_impact >/dev/null 2>&1 || return 0
  # Opted in the way qp_enqueue_step is: the impact map is the harness's own tree.
  conf="$root/config/mergify/repos/${slug#*/}.conf"
  [ -r "$conf" ] && grep -qx "slug=$slug" "$conf" 2>/dev/null && grep -q '^queue_mode=' "$conf" || return 0
  _bres_read "$slug" || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  max=$(_bres_knob batch_reset.max_drafts 10)
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    [ "$done_n" -lt "$max" ] || break
    draft=$(jq -r .number <<<"$row"); c12=$(jq -r '.causes[0].sha[0:12]' <<<"$row")
    key="bres $slug#$draft $c12"
    mc_attempt_has "$key" && continue
    done_n=$((done_n+1))
    mapfile -t causes < <(jq -r '.causes[] | "\(.pr):\(.head)"' <<<"$row")
    heads=()
    for pr in $(jq -r '.members[]' <<<"$row"); do
      hd=""; mc_rest_var hd gh_rest GET "repos/$slug/pulls/$pr"
      hd=$(jq -r '.head.sha // empty' <<<"${hd:-}" 2>/dev/null)
      [ -n "$hd" ] || { heads=(); break; }
      heads+=("$pr:$hd")
    done
    cside=$(_bres_side "$slug" "${causes[@]}") || cside=""
    mside=""; [ "${#heads[@]}" -gt 0 ] && { mside=$(_bres_side "$slug" "${heads[@]}") || mside=""; }
    v=$(bres_classify "$cside" "$mside")
    mc_log "$slug BATCH_RESET draft=$draft cause=$c12 verdict=$v"
    mc_attempt_put "$key"
  done < <(_bres_rows | jq -c 'select(.outcome == "closed" and (.causes | length) > 0)')
  return 0
}
