#!/bin/bash
# tests/lib/gh-list-bridge.sh — BH-1585: let a suite whose stub `gh` still speaks
# the GraphQL `gh pr list --json …` of the open-PR list answer the REST reads
# bin/lib/gh-pr-list.sh makes for it now. Sourced by a suite, once, after it has
# set up its stub; it defines and EXPORTS a shell function `gh`, so every lane
# the suite runs (a child bash inherits exported functions) calls the bridge,
# and the bridge calls the suite's own stub with `command gh`.
#
# WHAT CHANGED UNDER THESE SUITES. Asking harness_pr_list for mergeStateStatus,
# mergeable, isCrossRepository or files used to be one GraphQL `gh pr list
# --author <a>` per author. It is now a REST page (`pulls?state=open…`) plus one
# REST GET per PR (`pulls/<n>`, `pulls/<n>/files`). The suites' fixtures DESCRIBE
# the open PRs as a GraphQL list; this file answers the REST reads FROM THAT
# DESCRIPTION, so the lane under test sees the same PRs in the same states and
# the suite keeps asserting what it asserted. The mapping itself (mergeable_state
# -> mergeStateStatus, drafts, a failed per-PR read) is pinned against a real
# REST-shaped stub in tests/graphql-cuts.bh-1585-test.sh, not here.
#
# THE STUB ALWAYS GOES FIRST. A REST read is handed to the suite's stub; only an
# answer with NO HTTP status line (the stub has no arm for it) is synthesized:
#   pulls?state=open…      the stub's `pr list -R <slug> --state open --author <a>`
#                          for each HARNESS_PR_AUTHORS login, unioned by number,
#                          reshaped to REST; every author silent = HTTP 500
#   pulls/<n>              the row from that list (mergeable_state from
#                          mergeStateStatus, mergeable, head, base, draft)
#   pulls/<n>/files        the row's `files`, as REST `filename`
# Every other call is the stub's, untouched.
#
# THE LIST'S OWN PER-PR READS COME FROM THE LIST, AND ONLY THEY. bin/lib/gh-pr-list.sh
# tags its lazy per-PR reads (`pulls/<n>`, `pulls/<n>/files`) with
# HPL_READ_ROLE=list-lazy in the environment of that one call. Those, and only
# those, are answered from the list row. Every other read of the same path — a
# lane's decision read, a detached re-review's diff read, whenever it runs — goes
# to the stub as before. (Review round 1, B1: this used to be inferred from
# ORDER — "the next pulls/<n> after a page" — and a detached re-review lane that
# read pulls/<n> between a page and the list's own read took the list's slot:
# lead-verdicts C-D flaked red in CI on exactly that.)
#
# ONLY THE SUITE'S OWN STUB IS EVER CALLED (review round 2, B1 — the root cause).
# The exported `gh` function survives `env PATH=…`, so it is also what a
# DETACHED lane calls: merge-conductor starts its re-review, rebase and verify
# lanes with PATH="$MC_RR_PATH" (default /root/.fly/bin:/usr/local/bin:…),
# which has no fixture bin on it. There the bridge found no stub, synthesized an
# answer from a list it could not read, and served HTTP 500 — slowly enough
# (a bash, a jq, a failed list per author) that on the GitHub runner the
# control tick's lane in lead-verdicts C-D finished AFTER the next case had
# reset the state dir, and the next tick consumed that stale LANE FAILED
# instead of the case under test. Without the bridge the same lane finds no
# `gh` and fails at once. So: when the `gh` on PATH is not a stub inside this
# suite's scratch tree (GH_LIST_BRIDGE_ROOT), the bridge answers exactly what a
# box with no gh answers — 127, nothing on stdout — and never reaches a real
# `gh` that a runner may have installed.
_ghlb_self="${BASH_SOURCE[0]}"
export GH_LIST_BRIDGE="$_ghlb_self"
[ -n "${GH_LIST_BRIDGE_ROOT:-}" ] || export GH_LIST_BRIDGE_ROOT="${T:-}"
gh() { bash "$GH_LIST_BRIDGE" --run "$@"; }
export -f gh

[ "${1:-}" = --run ] || return 0 2>/dev/null
shift

# `type -P`, not `command -v`: the exported function `gh` is visible in this
# child too, and `command -v` would name the function, not the file.
_ghlb_stub=$(type -P gh 2>/dev/null || true)
case "$_ghlb_stub" in
  "") echo "gh: command not found" >&2; exit 127 ;;
esac
if [ -n "${GH_LIST_BRIDGE_ROOT:-}" ]; then
  case "$(cd "$(dirname "$_ghlb_stub")" 2>/dev/null && pwd -P)/" in
    "$(cd "$GH_LIST_BRIDGE_ROOT" 2>/dev/null && pwd -P)/"*) ;;
    *) echo "gh: command not found (gh-list-bridge: $_ghlb_stub is not this suite's stub)" >&2; exit 127 ;;
  esac
fi

hdr() { printf 'HTTP/2.0 %s\r\ncontent-type: application/json\r\n\r\n' "$1"; }

# isInMergeQueue: ONE GraphQL repository.mergeQueue read (bin/lib/gh-pr-list.sh).
# The stub describes it the way it always did — `pr list --json …isInMergeQueue`
# — so the entries are that list's rows with isInMergeQueue true, and a stub
# that REFUSES the field (every author fails) is a GraphQL error answer.
if [ "${1:-}" = api ] && [[ " $* " == *" graphql "* ]] && [[ "$*" == *mergeQueue* ]]; then
  out=$(command gh "$@" 2>/dev/null); rc=$?
  if printf '%s' "$out" | head -n 1 | grep -qE '^HTTP/[0-9.]+ [0-9]{3}' \
     && ! printf '%s' "$out" | grep -q 'gh-rest-fx: no route'; then printf '%s\n' "$out"; exit "$rc"; fi
  owner=""; name=""
  for a in "$@"; do case "$a" in owner=*) owner=${a#owner=} ;; name=*) name=${a#name=} ;; esac; done
  acc=""; ok=0
  for au in ${HARNESS_PR_AUTHORS:-operator app/cromford}; do
    if o=$(command gh pr list -R "$owner/$name" --state open --author "$au" --limit 100 --json number,baseRefName,isInMergeQueue 2>/dev/null) \
       && [ -n "$o" ] && printf '%s' "$o" | jq -e 'type == "array"' >/dev/null 2>&1; then
      ok=1; acc="$acc$o"$'\n'
    fi
  done
  hdr 200
  if [ "$ok" = 1 ]; then
    printf '%s' "$acc" | jq -sc '{data: {repository: {mergeQueue: {entries: {nodes:
      ([.[][] | select(.isInMergeQueue == true) | {pullRequest: {number}}] | unique)}}}}}'
  else
    echo '{"errors":[{"message":"stub: the list refused isInMergeQueue"}]}'
  fi
  exit 0
fi
path=""; for a in "$@"; do case "$a" in repos/*) path="$a" ;; esac; done
is_rest_get=0
[ "${1:-}" = api ] && [ "${2:-}" = -i ] && [ -n "$path" ] && is_rest_get=1

# Not a REST read the bridge knows: the stub, byte for byte.
if [ "$is_rest_get" = 0 ]; then command gh "$@"; exit $?; fi
case "$path" in
  */pulls\?*state=open*|*/pulls/[0-9]*) ;;
  repos/*/*/pulls) [[ " $* " == *" state=open "* ]] || { command gh "$@"; exit $?; } ;;
  *) command gh "$@"; exit $? ;;
esac

# The stub first. A status line means it answered this read itself — except
# tests/lib/gh-rest-fx.sh's UNROUTED answer (a 404 whose body says "gh-rest-fx:
# no route"), which is that stub saying it has no arm, not a PR that is gone.
slug=$(printf '%s' "$path" | sed -nE 's#^repos/([^/]+/[^/?]+).*#\1#p')
key=$(printf '%s' "$slug" | tr '/' '_')
lazy=0
case "$path" in */pulls/[0-9]*) [ "${HPL_READ_ROLE:-}" = list-lazy ] && lazy=1 ;; esac
# GH_LIST_BRIDGE_FAIL_LAZY=<file of PR numbers>: the list's own per-PR read of
# those PRs answers 502 (one PR's fault, not a rate limit), so a suite can drive
# the UNVERIFIABLE row a degraded read produces (BH-1585 review round 2, B3).
if [ "$lazy" = 1 ] && [ -n "${GH_LIST_BRIDGE_FAIL_LAZY:-}" ]; then
  fn=$(printf '%s' "$path" | sed -nE 's#.*/pulls/([0-9]+).*#\1#p')
  if grep -qx "$fn" "$GH_LIST_BRIDGE_FAIL_LAZY" 2>/dev/null; then
    hdr 502; echo '{"message":"Server Error (gh-list-bridge: GH_LIST_BRIDGE_FAIL_LAZY)"}'; exit 1
  fi
fi

out=""; rc=0
if [ "$lazy" = 0 ]; then
  out=$(command gh "$@" 2>/dev/null); rc=$?
  if printf '%s' "$out" | head -n 1 | grep -qE '^HTTP/[0-9.]+ [0-9]{3}' \
     && ! printf '%s' "$out" | grep -q 'gh-rest-fx: no route'; then
    printf '%s\n' "$out"; exit "$rc"
  fi
fi
FIELDS="number,url,title,body,headRefOid,headRefName,baseRefName,isDraft,state,labels,author,createdAt,updatedAt,mergeStateStatus,mergeable,isCrossRepository,files"
list_rows() { # the stub's GraphQL list for every author, unioned, as JSON
  local a acc="" o ok=0
  for a in ${HARNESS_PR_AUTHORS:-operator app/cromford}; do
    if o=$(command gh pr list -R "$slug" --state open --author "$a" --limit 100 --json "$FIELDS" 2>/dev/null) \
       && [ -n "$o" ] && printf '%s' "$o" | jq -e 'type == "array"' >/dev/null 2>&1; then
      ok=1
      acc="$acc$(printf '%s' "$o" | jq -c --arg a "$a" 'map(. + {author: (.author // {login: $a})})')"$'\n'
    fi
  done
  [ "$ok" = 1 ] || return 1
  printf '%s' "$acc" | jq -sc 'reduce (.[] | .[]) as $p ({seen: {}, out: []};
    ($p.number | tostring) as $k | if .seen[$k] then . else .seen[$k] = true | .out += [$p] end) | .out'
}
to_rest='def login: (.author.login // "operator") | if startswith("app/") then (sub("^app/"; "") + "[bot]") else . end;
  def ms: ((.mergeStateStatus // "UNKNOWN") | ascii_downcase);
  {number, html_url: (.url // ("https://github.com/" + $s + "/pull/" + (.number | tostring))),
   title: (.title // ""), body: (.body // ""), draft: (.isDraft // false),
   state: "open", merged_at: null, closed_at: null, labels: (.labels // []),
   user: {login: login, type: (if (.author.login // "") | startswith("app/") then "Bot" else "User" end)},
   created_at: (.createdAt // null), updated_at: (.updatedAt // null),
   head: {ref: (.headRefName // ""), sha: (.headRefOid // ""),
          repo: {full_name: (if .isCrossRepository == true then "fork/fork" else $s end)}},
   base: {ref: (.baseRefName // "main"), repo: {full_name: $s}},
   mergeable_state: ms,
   mergeable: (if .mergeable == "MERGEABLE" then true elif .mergeable == "CONFLICTING" then false else null end)}'

# bin/review-prs.sh's open list (every author, bin/lib/gh-rest-list.sh's paged
# `repos/<slug>/pulls -f state=open`). It used to be ONE `gh pr list --json
# number,author,headRefOid,title,isDraft -q <tsv>` — so the stub is asked
# exactly that, and its answer (the TSV that -q produced, or a JSON array) is
# reshaped to REST. Drafts were already dropped by that -q.
case "$path" in repos/*/*/pulls)
  RPQ='.[] | select(.isDraft | not) | [.number, .headRefOid, .author.login, .title] | @tsv'
  o=$(command gh pr list -R "$slug" --state open --json number,author,headRefOid,title,isDraft -q "$RPQ" 2>/dev/null) \
    || { hdr 500; echo '{"message":"stub: pr list failed"}'; exit 1; }
  if printf '%s' "$o" | jq -e 'type == "array"' >/dev/null 2>&1; then
    o=$(printf '%s' "$o" | jq -r "$RPQ")
  fi
  hdr 200
  printf '%s\n' "$o" | jq -Rsc --arg s "$slug" '[split("\n")[] | select(length > 0) | split("\t")
    | {number: (.[0] | tonumber), head: {sha: .[1], ref: "", repo: {full_name: $s}}, user: {login: .[2], type: "User"},
       title: (.[3] // ""), draft: false, state: "open", body: "", labels: [], html_url: ("https://github.com/" + $s + "/pull/" + .[0])}]'
  exit 0 ;;
esac

rows=$(list_rows) || { hdr 500; echo '{"message":"stub: every author silent"}'; exit 1; }
case "$path" in
  */pulls\?*)
    hdr 200; printf '%s' "$rows" | jq -c --arg s "$slug" "[.[] | $to_rest]"; exit 0 ;;
  */pulls/[0-9]*/files*)
    n=$(printf '%s' "$path" | sed -nE 's#.*/pulls/([0-9]+)/files.*#\1#p')
    row=$(printf '%s' "$rows" | jq -c --argjson n "$n" '.[] | select(.number == $n)')
    [ -n "$row" ] || { command gh "$@"; exit $?; }
    hdr 200; printf '%s' "$row" | jq -c '[(.files // [])[] | {filename: .path, additions: (.additions // 0), deletions: (.deletions // 0)}]'; exit 0 ;;
  */pulls/[0-9]*)
    n=$(printf '%s' "$path" | sed -nE 's#.*/pulls/([0-9]+).*#\1#p')
    row=$(printf '%s' "$rows" | jq -c --argjson n "$n" '.[] | select(.number == $n)')
    [ -n "$row" ] || { command gh "$@"; exit $?; }
    hdr 200; printf '%s' "$row" | jq -c --arg s "$slug" "$to_rest"; exit 0 ;;
esac
command gh "$@"; exit $?
