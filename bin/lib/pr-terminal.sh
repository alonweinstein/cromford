#!/bin/bash
# bin/lib/pr-terminal.sh — read a build record's PR over REST, once it can
# matter, and never again once it is merged. Sourced, never executed.
#
# THE SPEND THIS ENDS (BH-1585, the gh-reads audit of 2026-09-23). The GraphQL
# bucket — a separate 6,600/h budget from REST, and one nothing watched — ran at
# ~4,700/h. bin/rebase-train.sh asked `gh pr view` about EVERY approved record
# under builds/, PRs merged weeks ago included, six runs an hour (~880/h), and
# bin/pipeline-health.sh's sweep-should-have-landed check did the same every
# ten minutes (~510/h). A record's PR that has merged stays merged, so the
# answer was known and the call bought nothing.
#
# TWO RULES:
#   * THE TERMINAL STATE IS PERSISTED ON THE RECORD ($D/pr-terminal, one line:
#     `merged <epoch> <pr-url>` or `closed <epoch> <pr-url>`). `merged` is terminal for ever.
#     `closed` is terminal for PR_TERMINAL_CLOSED_RECHECK_S and then read again,
#     because a closed PR can be reopened and a lane that stopped looking would
#     never see it. With no value for the knob a closed PR is simply re-read —
#     a call we did not need, never a PR we stopped seeing.
#   * THE LIVE READ IS REST (bin/lib/gh-rest.sh: the 0/44/75 contract and the
#     ETag cache, so an unchanged open PR answers 304 and costs no quota), under
#     `timeout` when PR_READ_TIMEOUT_S is set. GNU timeout runs the read in its
#     own process group and signals the whole group, so a hung `gh` is killed
#     with its children rather than outliving the tick — the audit found ~700/h
#     of orphaned `gh pr view` children from exactly these two lanes.
#
# A READ WE COULD NOT MAKE IS NOT A STATE: a 403/429, a timeout or a body with
# no recognisable state is rc 75 and writes nothing, so the next tick asks again.
#
#   prt_known_terminal <record-dir> [url]    rc 0 = skip, no read needed
#   prt_read <record-dir> <pr-url> <outfile> rc 0 OPEN (the REST pull JSON is in
#                                            <outfile>), 3 merged/closed (now
#                                            persisted), 44 no such PR, 75 unreadable
#   prt_fields <json-file>                   "STATE MERGESTATE AUTHOR HEADREF HEADSHA",
#                                            GraphQL's words (OPEN, DIRTY, …)
#
# Knobs (catalog/lanes.d/_lib.json, lib id `pr-terminal`, both required: this
# file carries no literal for either; bin/lib/lane-gate.sh's lib_env_apply sets
# them from a settings row, the box cache, the env or the registry default):
#   PR_TERMINAL_CLOSED_RECHECK_S   how long a closed PR stays terminal
#   PR_READ_TIMEOUT_S              seconds one PR read may take
#
# gh-rest: no-graphql
#
# No `set -e`, no `exit`, no side effect at source time.
if [ -n "${PR_TERMINAL_LIB:-}" ]; then return 0 2>/dev/null; fi
PR_TERMINAL_LIB=1
_PRT_H="${HARNESS:-/root/harness}"
_PRT_REST=""
for _P in "${BASH_SOURCE[0]%/*}/gh-rest.sh" "$_PRT_H/bin/lib/gh-rest.sh"; do
  # shellcheck source=bin/lib/gh-rest.sh
  [ -r "$_P" ] && { _PRT_REST="$_P"; . "$_P"; break; }
done
unset _P
_PRT_KNOBS=0

# The two knobs, resolved once per process. lane-gate.sh is sourced lazily, the
# way bin/lib/wake-lanes.sh does it: a lane that already has it pays nothing.
_prt_knobs() {
  [ "$_PRT_KNOBS" = 1 ] && return 0
  _PRT_KNOBS=1
  if ! command -v lib_env_apply >/dev/null 2>&1; then
    local g
    for g in "${BASH_SOURCE[0]%/*}/lane-gate.sh" "$_PRT_H/bin/lib/lane-gate.sh"; do
      # shellcheck source=bin/lib/lane-gate.sh
      [ -r "$g" ] && { . "$g" 2>/dev/null; break; }
    done
  fi
  command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply pr-terminal
  return 0
}

_prt_num_ok() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

prt_known_terminal() { # prt_known_terminal <record-dir> [pr-url]
  local f="${1:-}/pr-terminal" kind ts url ttl now
  [ -r "$f" ] || return 1
  read -r kind ts url < "$f" || true
  # The marker belongs to ONE PR (review round 1): a record whose RESULT now
  # names a different PR does not inherit it. A marker without a url (written
  # before this line) is honoured only when no url is asked about.
  if [ -n "${2:-}" ] && [ "${url:-}" != "$2" ]; then return 1; fi
  case "${kind:-}" in merged) return 0 ;; closed) ;; *) return 1 ;; esac
  _prt_knobs
  ttl="${PR_TERMINAL_CLOSED_RECHECK_S:-}"
  _prt_num_ok "$ttl" && _prt_num_ok "${ts:-}" || return 1
  now=$(date +%s)
  [ $(( now - ts )) -ge 0 ] && [ $(( now - ts )) -lt "$ttl" ]
}

# The GET, bounded. `bash -c` because a shell function cannot run under
# timeout; the child re-sources the contract lib and inherits the exported
# identity. 124/137 (timed out, killed) are 75: we do not know the answer.
_prt_get() { # _prt_get <slug> <num> <outfile>
  local t rc=0
  _prt_knobs
  t="${PR_READ_TIMEOUT_S:-}"
  if _prt_num_ok "$t" && [ "$t" -gt 0 ] && [ -n "$_PRT_REST" ] && command -v timeout >/dev/null 2>&1; then
    timeout -s KILL "$t" bash -c '. "$1" && gh_rest GET "$2"' _ "$_PRT_REST" "repos/$1/pulls/$2" > "$3" || rc=$?
    case "$rc" in 124|137) rc=75 ;; esac
  else
    gh_rest GET "repos/$1/pulls/$2" > "$3" || rc=$?
  fi
  return "$rc"
}

prt_read() { # prt_read <record-dir> <pr-url> <outfile>
  local d="${1:-}" url="${2:-}" out="${3:-}" slug num st rc=0
  slug=$(printf '%s' "$url" | sed -nE 's#^https://github\.com/([^/]+/[^/]+)/pull/[0-9]+.*#\1#p')
  num=$(printf '%s' "$url" | sed -nE 's#^https://github\.com/[^/]+/[^/]+/pull/([0-9]+).*#\1#p')
  [ -n "$d" ] && [ -n "$out" ] || return 75
  command -v gh_rest >/dev/null 2>&1 || return 75
  _gh_rest_args_ok "$slug" "$num" || return 75
  _prt_get "$slug" "$num" "$out" || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  st=$(jq -r 'if (.merged == true) or (.merged_at != null) then "merged"
              elif .state == "closed" then "closed"
              elif .state == "open" then "open" else "" end' "$out" 2>/dev/null) || st=""
  case "$st" in
    merged|closed)
      printf '%s %s %s\n' "$st" "$(date +%s)" "$url" > "$d/pr-terminal.tmp" 2>/dev/null \
        && mv -f "$d/pr-terminal.tmp" "$d/pr-terminal" 2>/dev/null
      return 3 ;;
    open) rm -f "$d/pr-terminal" 2>/dev/null; return 0 ;;
    *) return 75 ;;
  esac
}

# GraphQL's words from a REST pull: mergeable_state is lower-case REST for the
# same enum (clean, dirty, blocked, behind, unstable, has_hooks, draft,
# unknown), and a missing one is UNKNOWN — GitHub has not computed it yet.
prt_fields() { # prt_fields <json-file>
  jq -r '[(if (.merged == true) or (.merged_at != null) then "MERGED" else (.state // "" | ascii_upcase) end),
          ((.mergeable_state // "unknown") | ascii_upcase),
          (.user.login // "-"), (.head.ref // "-"), (.head.sha // "-")] | join(" ")' "$1" 2>/dev/null
}
