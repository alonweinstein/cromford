#!/bin/bash
# tests/lib/rest-emit.sh — print one GitHub REST answer as a FULL HTTP response,
# for the `gh api -i -X <M> …` arms of a suite's stub `gh`. Copied onto the stub
# PATH as `restpr`, never sourced.
#
# WHY IT EXISTS. Since BH-784 the merge family's decision reads go through
# bin/lib/gh-rest.sh, which judges the HTTP STATUS LINE, not gh's exit code —
# 200, 404 and 403 are three different answers and the old `echo "OPEN $H1"`
# stub arms can express exactly one of them. Every suite that stubs a PR read
# needs the same handful of shapes, so they live here once instead of as twenty
# copies of the same printf.
#
#   restpr <STATE> <head-sha> [head-ref] [base-ref] [labels-csv] \
#          [MERGEABLE|CONFLICTING|UNKNOWN] [mergeStateStatus] [login] [merge-sha] [body]
#       One pull object, 200. STATE is the GraphQL word the fixtures already
#       carry (OPEN|MERGED|CLOSED); MERGED is emitted the way REST really
#       answers it — state "closed" WITH merged_at set — so a reader that
#       confuses the two is caught here rather than on a real PR.
#   restpr --raw <status> [body]      any other answer: 403, 404, an issue, a list
#   restpr --diff [text]              a 200 whose body is a unified diff
#   restpr --runs [line...]           a 200 `actions/runs` list (BH-1586). Each
#       line is `status|conclusion[|id|name]` — the shape the pre-REST stubs
#       printed as gh's `-q` output — and becomes one workflow run; a line with
#       no name gets its own (wf1, wf2, …), so every line is its own workflow.
#       `restpr --runs - < file` reads the lines from stdin; none = no runs.
#
#   bash tests/lib/rest-emit.sh --selftest    exit 0 = the shapes are well-formed
set -uo pipefail

_hdr() { printf 'HTTP/1.1 %s Something\r\nServer: stub\r\n\r\n' "$1"; }

case "${1:-}" in
  --raw)  _hdr "${2:-200}"; [ -n "${3:-}" ] && printf '%s' "$3"; exit 0 ;;
  --runs)
    shift
    # stdin only when asked for with `-`: a stub's own stdin may be the caller's
    # `while read` loop, and draining it would eat the loop.
    if [ "${1:-}" = - ]; then L=$(cat); else L=$(printf '%s\n' "$@"); fi
    _hdr 200
    printf '%s\n' "$L" | jq -R -s -c '[split("\n")[] | select(length > 0) | split("|")] | to_entries
      | map(.key as $k | .value as $v | {
          id: (($v[2] // "") | if . == "" then 9001 + $k else tonumber end),
          name: (($v[3] // "") | if . == "" then "wf\($k + 1)" else . end),
          status: $v[0], conclusion: (($v[1] // "") | if . == "" then null else . end),
          run_started_at: "2026-09-22T00:00:00Z", run_attempt: 1})
      | {total_count: length, workflow_runs: .}'
    exit 0 ;;
  --diff) _hdr 200; printf '%s' "${2:-$'+++ b/src/x.ts\n+const a = 1;\n'}"; exit 0 ;;
  --selftest)
    out=$(bash "$0" MERGED deadbeef ticket/x main '' | tail -1)
    [ "$(printf '%s' "$out" | jq -r '.state + " " + (.merged_at != null | tostring)')" = "closed true" ] || { echo "MERGED must be closed+merged_at"; exit 1; }
    out=$(bash "$0" CLOSED deadbeef | tail -1)
    [ "$(printf '%s' "$out" | jq -r '.state + " " + (.merged_at == null | tostring)')" = "closed true" ] || { echo "CLOSED must be closed with merged_at null"; exit 1; }
    out=$(bash "$0" OPEN deadbeef ticket/x main 'a,b' CONFLICTING DIRTY operator | tail -1)
    [ "$(printf '%s' "$out" | jq -r '[.state,(.mergeable|tostring),.mergeable_state,(.labels|map(.name)|join(",")),.user.login]|join(" ")')" \
      = "open false dirty a,b operator" ] || { echo "OPEN row wrong: $out"; exit 1; }
    echo "rest-emit selftest OK"; exit 0 ;;
esac

ST="${1:-OPEN}"; SHA="${2:-}"; REF="${3:-ticket/x}"; BASE="${4:-main}"; LBL="${5:-}"
MG="${6:-MERGEABLE}"; MS="${7:-CLEAN}"; LOGIN="${8:-app/cromford}"; MSHA="${9:-}"
BODY="${10:-harness PR body}"
case "$ST" in
  MERGED) state=closed; merged=2026-09-18T00:00:00Z ;;
  CLOSED) state=closed; merged= ;;
  *)      state=open;   merged= ;;
esac
_hdr 200
jq -nc --arg s "$state" --arg m "$merged" --arg sha "$SHA" --arg ref "$REF" --arg base "$BASE" \
       --arg l "$LBL" --arg mg "$MG" --arg ms "$MS" --arg login "$LOGIN" --arg msha "$MSHA" \
       --arg body "$BODY" \
  '{state:$s,
    merged_at:(if $m=="" then null else $m end),
    head:{sha:$sha,ref:$ref},
    base:{ref:$base},
    labels:(if $l=="" then [] else ($l|split(",")|map({name:.})) end),
    mergeable:(if $mg=="MERGEABLE" then true elif $mg=="CONFLICTING" then false else null end),
    mergeable_state:($ms|ascii_downcase),
    user:{login:$login,type:"Bot"},
    merge_commit_sha:(if $msha=="" then null else $msha end),
    body:$body,
    draft:false}'
