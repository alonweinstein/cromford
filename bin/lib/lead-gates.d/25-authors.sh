#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-gates.d/25-authors.sh — gate 14 of bin/lead-review-enqueue.sh
# (BH-5351), ported to the worklist as a job field: lg_field_head_authors
# prints the JSON array of who wrote this head, and lg_job_fields puts it in
# the lead_review job's meta as `head_authors` (a string holding the array).
# _lga_head_authors_json is the enqueue's head_authors_json, copied with its
# log calls on _lgt_log. The head ref comes from the PR body gate 55 cached
# this process (lgs_pr_body_file); without it only the project-wide fix-round
# read runs. No identity at all prints nothing (no key, one log line), as the
# enqueue sent its request without head_authors. It never fails: rc 1 would
# make bin/lead-review.sh skip the review. Sourced by bin/lib/lead-gates.sh,
# never run.

# shellcheck source=bin/lib/ticket-branch.sh
command -v ticket_branch_key >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../ticket-branch.sh" 2>/dev/null || true

# _lga_head_authors_json <slug> <n> <head-ref> <project> — rc 0 and one JSON
#   array: the build job's identity first (GET /api/verdict?pr= .job.box and
#   .job.participant), then the box and claimed_by of every fix round on the
#   PR (GET /api/fix-rounds?project=&cap_key=<project>-<KEY>, and ?project=
#   alone; rows whose cap_key names the ticket, starts dqw-<n>-, or whose
#   args[3] is the PR url). Trimmed, lowercased, de-duplicated, at most 16 of
#   at most 128 chars. A failed or truncated read is one log line. No identity
#   at all is rc 1 with the reason on stdout.
_lga_head_authors_json() {
  local slug="$1" n="$2" ref="$3" project="$4" url q v rc key frq ids='[]' rows='[]' f all
  url="https://github.com/$slug/pull/$n"
  q=$(jq -rn --arg u "$url" '$u | @uri')
  rc=0; v=$(JOBS_ALERT=0 _jobs_req GET "/api/verdict?pr=$q" 2>/dev/null) || rc=$?
  case "$rc" in
    0) ids=$(jq -c '[.job.box?, .job.participant?] | map(strings)' <<<"$v" 2>/dev/null) || ids='[]'
       [ "$ids" != '[]' ] || _lgt_log "$slug#$n: the build job names no box; head_authors has no build identity" ;;
    2) _lgt_log "$slug#$n: no build job recorded the PR; head_authors has no build identity" ;;
    *) _lgt_log "$slug#$n: build identity read failed (rc $rc); head_authors has no build identity" ;;
  esac
  key=""; command -v ticket_branch_key >/dev/null 2>&1 && key=$(ticket_branch_key "$ref") || key=""
  for frq in ${key:+"project=$project&cap_key=$project-$key&limit=500"} "project=$project&limit=500"; do
    rc=0; f=$(JOBS_ALERT=0 _jobs_req GET "/api/fix-rounds?$frq" 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ] || ! jq -e '.fix_round_jobs | type == "array"' <<<"$f" >/dev/null 2>&1; then
      _lgt_log "$slug#$n: fix-round lookup ($frq) failed (rc $rc); head_authors may be incomplete"; continue
    fi
    [ "$(jq -r '.truncated == true' <<<"$f")" = true ] && _lgt_log "$slug#$n: fix-round list truncated; head_authors may be incomplete"
    rows=$(jq -c --argjson a "$rows" '$a + .fix_round_jobs' <<<"$f")
  done
  # The ticket key, bounded so BH-12 never matches BH-123.
  all=$(jq -c --argjson ids "$ids" --arg k "$key" --arg n "$n" --arg u "$url" '
    def named: ($k != "" and ((.cap_key // "") | ascii_downcase
                 | test("(^|[^a-z0-9])" + ($k | ascii_downcase) + "($|[^0-9])")));
    def ours: named or ((.cap_key // "") | startswith("dqw-" + $n + "-"))
              or ((.args | if type == "array" then .[3] else null end) == $u);
    $ids + [.[] | select(ours) | .box, .claimed_by]
    | map(strings | gsub("^\\s+|\\s+$"; "") | ascii_downcase | select(. != ""))
    | reduce .[] as $a ([]; if index([$a]) then . else . + [$a] end)' <<<"$rows") \
    || { echo "head authors could not be built"; return 1; }
  [ "$(jq '[.[] | select(length > 128)] | length' <<<"$all")" = 0 ] \
    || { _lgt_log "$slug#$n: head_authors over 128 chars dropped"; all=$(jq -c 'map(select(length <= 128))' <<<"$all"); }
  [ "$(jq length <<<"$all")" -le 16 ] || { _lgt_log "$slug#$n: head_authors over 16; first 16 sent"; all=$(jq -c '.[:16]' <<<"$all"); }
  [ "$all" != '[]' ] || { echo "no build or fix-round identity was readable"; return 1; }
  printf '%s\n' "$all"
}

lg_field_head_authors() {
  local slug="$1" n="$2" h12="${3:0:12}" root="${HARNESS:-${H:-}}" project ref="" bf out
  project=$(awk -v r="$slug" '$1 !~ /^#/ && $2 == r {print $1; exit}' "${FLEET_CONF:-${root:-.}/fleet.conf}" 2>/dev/null)
  if command -v lgs_pr_body_file >/dev/null 2>&1 && bf=$(lgs_pr_body_file "$slug" "$n") && [ -n "$bf" ]; then
    ref=$(jq -r '.head.ref // empty' "$bf" 2>/dev/null)
  fi
  if out=$(_lga_head_authors_json "$slug" "$n" "$ref" "$project"); then
    printf '%s\n' "$out"
  else
    _lgt_log "$slug#$n @$h12: no head authorship ($out); the job carries no head_authors"
  fi
  return 0
}
