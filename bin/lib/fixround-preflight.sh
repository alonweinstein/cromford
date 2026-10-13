#!/bin/bash
# bin/lib/fixround-preflight.sh — BH-1794: before any fix round spends a model
# call, rebuild what it knows about the PR from the PR as it is NOW.
# Sourced, never executed. No output and no file write at source time. Safe
# under `set -uo pipefail`. NO MODEL CALL anywhere in this file, and every
# GitHub read is REST (`gh api repos/...`), never GraphQL.
#
# THE INCIDENT (project-3 #378, TK-202, 2026-09-23). Fix round 1 fixed the code:
# unit 4848/4848, CI green on b8e228d3. The Fable re-review 23 minutes later was
# still REQUEST_CHANGES, and its BLOCKER was paperwork: the PR body's Evidence
# block still said HARNESS_EXIT 1 / head-red from the first build, and the
# reviewer's token 403s on check-runs, so it could not see the green CI. A
# second paid fix round and a second re-review were bought only to refresh that
# block. The fix round was briefed from the review record it was queued from,
# not from the PR.
#
# WHAT THIS FILE ANSWERS, in the order a fix-round entry point asks:
#   frp_ci <slug> <sha>        the CI of THAT sha, as one JSON object:
#       {"sha","state","actions":"read|unreadable","checks":"read|unreadable",
#        "runs":[{"name","kind":"workflow|check","status","conclusion","url"}]}
#     state is green | red | pending | none | unreadable. A refused read (the
#     403 that started this) is `unreadable` — NEVER red, and never none: a
#     read nobody got is not a fact about the head. When ONE of the two
#     endpoints answers, its answer stands and the other is named unreadable.
#     Latest run per name wins; cancelled / timed_out / skipped / neutral /
#     stale runs prove nothing either way and are set aside, the same reduction
#     bin/lib/mc/classify.sh:mc_ci_state makes.
#   frp_ci_text <ci-json>      the same facts as lines a person or a model reads.
#   frp_findings_head <text>   the sha the posted findings were written against
#                              (the review footers end `… of <40-hex sha>`).
#   frp_stale_evidence_only <text>  rc 0 when every BLOCKING numbered finding is
#                              about the PR body's evidence / CI reading and
#                              none names a source file — the paperwork blocker.
#   frp_decide <reason> <head> <findings-head> <ci-state> <findings>
#                              one line `<action>\t<why>`:
#       rereview  findings on an older sha, head moved, CI green at head
#       wait      head moved and its CI has not finished — nothing to fix yet
#       skip      a red-CI park whose current head is green
#       evidence  the only blocker is stale evidence and CI is green at head
#       fix       everything else: the round runs, briefed from live data
#   frp_brief <ci-json> <head> <findings-head>   the live-state header of a brief.
#   frp_block <ci-json> [rereview-sha]           the PR-body block (markers).
#   frp_body_refresh <slug> <num> <ci-json> [rereview-sha]
#       rewrites that block in the PR body over REST. rc 0 written, 3 already
#       current (no PATCH sent), 2 body unreadable, 1 PATCH refused, 4 the
#       body's markers are malformed (a begin with no end) — no PATCH sent and
#       the body left exactly as it was (BH-1992: that splice used to drop
#       every line after the open begin marker, `## Evidence` included).
#   frp_rereview_requested <text> <sha>  rc 0 when the text asks for a re-review
#                              of exactly that head. Since BH-1992 the text the
#                              review lane reads is a PR COMMENT from a verdict
#                              author (bin/review-prs.sh); the marker in the
#                              body is for people and triggers nothing.
#
# WHO SOURCES THIS FILE (BH-1992 item 6). bin/blocked-resolver.sh (br_preflight,
# br_preflight_after_push), bin/review-prs.sh (live CI in the reviewer prompt,
# the re-review request) and bin/lib/mc/rebase.sh (mc_rereview's live CI). There
# is no other fix-round entry point in this repo: a lead's hand-run fix brief
# lives outside it. Such a caller wires in the same way br_fix_round does —
# source this file, then before the round spends:
#   ci=$(frp_ci <slug> <head>)                     the live CI of the PR head
#   frp_brief "$ci" <head> "$(frp_findings_head "$findings")"
#                                                  leads the agent's prompt
#   frp_body_refresh <slug> <num> "$ci"            refreshes the PR body block
#                                                  (rc 4: leave the body alone
#                                                  and tell a person, once)
# and after it pushes, frp_body_refresh again with frp_ci of the pushed head.
#
# THE BLOCK IS NOT THE BUILD'S EVIDENCE BLOCK. bin/evidence-summary.sh renders
# `## Evidence` from the build record's own files, and that is history worth
# keeping. This block sits directly above it (or at the end of a body that has
# none) and says what GitHub reports for the head the PR carries now. It holds
# no timestamp on purpose: the same head in the same CI state renders the same
# bytes, so a second refresh sends no PATCH at all.
[ -n "${FRP_LIB:-}" ] && return 0 2>/dev/null
FRP_LIB=1
FRP_BEGIN='<!-- harness:live-ci:begin -->'
FRP_END='<!-- harness:live-ci:end -->'
FRP_RR_TAG='harness:rereview-requested'

# The one CI reader that survives a token which cannot see Actions (#1085's
# lesson, bin/lib/gh-ci-read.sh). Resolved at call time: a caller may source
# this file before it sources that one.
_frp_have_ci() {
  command -v gh_ci_api >/dev/null 2>&1 && return 0
  local d="${BASH_SOURCE[0]%/*}"
  # shellcheck source=bin/lib/gh-ci-read.sh
  [ -r "$d/gh-ci-read.sh" ] && . "$d/gh-ci-read.sh"
  command -v gh_ci_api >/dev/null 2>&1
}

frp_ci() { # frp_ci <owner/repo> <sha>
  local slug="${1:-}" sha="${2:-}" runs="" checks="" ra=unreadable ca=unreadable
  if [ -n "$slug" ] && [ -n "$sha" ] && _frp_have_ci; then
    if runs=$(GH_CI_READ_WHAT=actions/runs gh_ci_api "$slug" "repos/$slug/actions/runs?head_sha=$sha&per_page=100") \
       && jq -e '.workflow_runs | type == "array"' >/dev/null 2>&1 <<<"$runs"; then
      ra=read
    else runs='{}'; fi
    if checks=$(GH_CI_READ_WHAT=check-runs gh_ci_api "$slug" "repos/$slug/commits/$sha/check-runs?per_page=100") \
       && jq -e '.check_runs | type == "array"' >/dev/null 2>&1 <<<"$checks"; then
      ca=read
    else checks='{}'; fi
  else
    runs='{}'; checks='{}'
  fi
  jq -nc --arg sha "$sha" --arg ra "$ra" --arg ca "$ca" \
     --argjson r "$runs" --argjson c "$checks" '
    def latest: group_by(.name) | map(sort_by(.t) | last);
    ( if $ra == "read" then
        [ $r.workflow_runs[]? | {name: ((.name // "?") | tostring), kind: "workflow",
            t: (((.run_started_at // .created_at) // "") + "#" + ((.run_attempt // 1) | tostring)),
            status: (.status // ""), conclusion: (.conclusion // ""), url: (.html_url // "")} ] | latest
      else [] end ) as $wf
    | ( if $ca == "read" then
        [ $c.check_runs[]? | {name: ((.name // "?") | tostring), kind: "check",
            t: ((.started_at // .completed_at) // ""),
            status: (.status // ""), conclusion: (.conclusion // ""), url: (.html_url // "")} ] | latest
      else [] end ) as $ck
    | ($wf + $ck | map(del(.t))) as $all
    | ($all | map(select((.status == "completed"
          and (.conclusion | IN("cancelled","timed_out","skipped","neutral","stale"))) | not))) as $eff
    | { sha: $sha, actions: $ra, checks: $ca, runs: $all,
        state: (
          if $ra != "read" and $ca != "read" then "unreadable"
          elif ($eff | length) == 0 then (if $ra != "read" or $ca != "read" then "unreadable" else "none" end)
          elif any($eff[]; .status != "completed") then "pending"
          elif any($eff[]; .conclusion | IN("failure","action_required","startup_failure")) then "red"
          else "green" end) }' 2>/dev/null \
  || jq -nc --arg sha "$sha" '{sha:$sha, actions:"unreadable", checks:"unreadable", runs:[], state:"unreadable"}'
}

frp_ci_text() { # frp_ci_text <ci-json>
  local ci="${1:-}"
  [ -n "$ci" ] || ci='{}'
  jq -r '
    def src(w): if w == "read" then "read" else "UNREADABLE (the token was refused — this is not a red result)" end;
    "CI on \((.sha // "?")[0:12]): \((.state // "unreadable") | ascii_upcase)  [actions/runs: \(src(.actions)); check-runs: \(src(.checks))]",
    ( if (.state // "") == "unreadable" then
        "  No CI result could be read for this head. Treat it as UNKNOWN: it is not red, and it is not green."
      else empty end ),
    ( (.runs // [])[:25][] | "  - \(.name) [\(.kind)]: \(if .status == "completed" then .conclusion else .status end)\(if (.url // "") != "" then " " + .url else "" end)" ),
    ( if ((.runs // []) | length) > 25 then "  … \(((.runs // []) | length) - 25) more run(s) not listed" else empty end )
  ' <<<"$ci" 2>/dev/null
}

frp_findings_head() { # frp_findings_head <findings-text>
  printf '%s\n' "${1:-}" | grep -oE '(^|[^0-9A-Za-z])of `?[0-9a-f]{40}([^0-9A-Za-z]|$)' 2>/dev/null \
    | grep -oE '[0-9a-f]{40}' | tail -1
}

# frp_stale_evidence_only <findings-text>
#   rc 0 only when (a) at least one numbered finding is BLOCKING — its headline
#   carries no nit/minor/low/info/suggestion/optional/advisory tag — and (b)
#   every blocking finding talks about the PR body's evidence or the CI
#   reading (an Evidence block/table/row, HARNESS_EXIT, head-red, check-runs,
#   "cannot verify CI", CI red/failing) and names no source file. The bare word
#   "evidence" is not enough: "no evidence the retry path is tested" is a real
#   finding about missing tests, not paperwork. A review with no parseable numbered
#   findings is NOT stale-evidence-only: when in doubt, the round runs.
frp_stale_evidence_only() {
  printf '%s\n' "${1:-}" | awk '
    function flush() {
      if (item == "") return
      head = tolower(substr(first, 1, 80))
      if (head ~ /(^|[^a-z])(nit|nits|nitpick|minor|low|info|suggestion|optional|advisory)([^a-z]|$)/) { item = ""; return }
      blocking++
      t = tolower(item)
      ev = (t ~ /evidence (block|table|section|row)|harness_exit|head-red|check-runs|check runs|(cannot|could not|can.t) (verify|read|see) (the )?ci|ci (is|was|shows|reads|reported|still) (red|failing)|red ci|failing ci|ci (status|state|result)/)
      src = (t ~ /[a-z0-9_\/.-]+\.(sh|ts|tsx|js|jsx|mjs|cjs|py|go|rb|sql|prisma|ya?ml|json|css|scss|html|java|kt|rs)(:[0-9]+|[^a-z0-9]|$)/)
      if (!ev || src) other++
      item = ""
    }
    /^[[:space:]]*[0-9]{1,3}[.)][[:space:]]+/ { flush(); first = $0; item = $0; next }
    /^[[:space:]]*(TIER|VERDICT):/ || /^---[[:space:]]*$/ { flush(); next }
    { if (item != "") item = item " " $0 }
    END { flush(); exit (blocking > 0 && other == 0) ? 0 : 1 }'
}

frp_decide() { # frp_decide <reason> <head> <findings-head> <ci-state> <findings>
  local reason="${1:-}" head="${2:-}" fh="${3:-}" state="${4:-unreadable}" findings="${5:-}"
  if [ -n "$fh" ] && [ -n "$head" ] && [ "$fh" != "$head" ]; then
    case "$state" in
      green) printf 'rereview\tthe findings were posted on %s and the head is now %s with green CI — they are re-judged on the new head, not fixed again\n' "${fh:0:8}" "${head:0:8}"; return 0 ;;
      pending|none) printf 'wait\tthe findings were posted on %s, the head moved to %s and its CI is %s — nothing to brief a round with until it finishes\n' "${fh:0:8}" "${head:0:8}" "$state"; return 0 ;;
    esac
  fi
  case "$reason" in
    red-ci-twice*|red-twice*)
      if [ "$state" = green ]; then
        printf 'skip\tCI is green on the current head %s — the red this park was filed for is not on it\n' "${head:0:8}"; return 0
      fi ;;
  esac
  if [ "$state" = green ] && frp_stale_evidence_only "$findings"; then
    printf 'evidence\tevery blocking finding is about the PR body evidence and CI is green on %s — the block is rewritten from GitHub and the head re-reviewed, no fix round\n' "${head:0:8}"
    return 0
  fi
  printf 'fix\tthe round runs on %s, briefed from the live head (CI %s)\n' "${head:0:8}" "$state"
}

frp_brief() { # frp_brief <ci-json> <head> <findings-head>
  local ci="${1:-}" head="${2:-}" fh="${3:-}"
  printf 'LIVE STATE OF THIS PULL REQUEST, read from GitHub by the harness immediately before this round (no model wrote it). Where anything older — the PR body, an Evidence block, a review — disagrees with it, this is the truth:\n'
  printf -- '- current head: %s\n' "${head:--}"
  if [ -n "$fh" ] && [ "$fh" != "$head" ]; then
    printf -- '- the findings below were written against %s, an OLDER head: check each one against the current code before changing anything\n' "$fh"
  elif [ -n "$fh" ]; then
    printf -- '- the findings below were written against this head\n'
  else
    printf -- '- the findings below do not name the head they were written against\n'
  fi
  frp_ci_text "$ci"
}

frp_block() { # frp_block <ci-json> [rereview-sha]
  local ci="${1:-}" rr="${2:-}"
  printf '%s\n' "$FRP_BEGIN"
  printf '## Live CI on the current head\n\n'
  printf 'Read from GitHub by `bin/lib/fixround-preflight.sh` — no model wrote this. Where it disagrees with the build-time Evidence block below, this block describes the head the PR carries now.\n\n'
  printf '```text\n'
  frp_ci_text "$ci"
  printf '```\n'
  [ -n "$rr" ] && printf '<!-- %s %s -->\n' "$FRP_RR_TAG" "$rr"
  printf '%s\n' "$FRP_END"
}

# _frp_splice <body-file> <block-file> — the new body on stdout. An existing
# block is replaced in place; otherwise it goes directly above the first
# `## Evidence` heading; otherwise at the end, after one blank line.
# rc 4 when a begin marker is still open at EOF or a second begin arrives while
# one is open (BH-1992): the lines after an unclosed begin are not ours to drop,
# so stdout is then the body EXACTLY as it came in and the caller sends nothing.
# An end marker with no begin is an ordinary line.
_frp_splice() {
  local out
  out=$(mktemp "${TMPDIR:-/tmp}/frp-splice.XXXXXX") || return 4
  if ! _frp_splice_awk "$1" "$2" > "$out"; then
    cat "$1"; rm -f "$out"; return 4
  fi
  cat "$out"; rm -f "$out"
}
_frp_splice_awk() {
  awk -v B="$FRP_BEGIN" -v E="$FRP_END" -v blk="$2" '
    function emit(   l) { while ((getline l < blk) > 0) print l; close(blk); done = 1 }
    BEGIN { done = 0; skip = 0; bad = 0 }
    index($0, B) == 1 { if (skip) { bad = 1; exit } if (!done) emit(); skip = 1; next }
    skip && index($0, E) == 1 { skip = 0; next }
    skip { next }
    !done && /^## Evidence[[:space:]]*$/ { emit(); print ""; print; next }
    { print }
    END { if (bad || skip) exit 4; if (!done) { print ""; emit() } }' "$1"
}

frp_body_refresh() { # frp_body_refresh <owner/repo> <num> <ci-json> [rereview-sha]
  local slug="${1:-}" num="${2:-}" ci="${3:-}" rr="${4:-}" body d rc=0
  [ -n "$slug" ] && [ -n "$num" ] || return 2
  body=$(gh api "repos/$slug/pulls/$num" --jq '.body // ""' 2>/dev/null) || return 2
  d=$(mktemp -d "${TMPDIR:-/tmp}/frp.XXXXXX") || return 1
  printf '%s\n' "$body" > "$d/old"
  frp_block "$ci" "$rr" > "$d/block"
  if ! _frp_splice "$d/old" "$d/block" > "$d/new"; then
    rc=4
  elif cmp -s "$d/old" "$d/new"; then
    rc=3
  elif ! gh api -X PATCH "repos/$slug/pulls/$num" -F "body=@$d/new" >/dev/null 2>&1; then
    rc=1
  fi
  rm -rf "$d"
  return "$rc"
}

frp_rereview_requested() { # frp_rereview_requested <body> <sha>
  local sha="${2:-}"
  [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]] || return 1
  # A pattern match, not `printf | grep -q`: under pipefail an early grep exit
  # can SIGPIPE the printf and turn a hit into a miss.
  [[ "${1:-}" == *"<!-- $FRP_RR_TAG $sha -->"* ]]
}
