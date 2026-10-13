#!/bin/bash
# gh-identity: app-token
# bin/lib/issue-comment-cmd.sh — the hub side of the console's comment_issue
# command (BH-5820). Sourced, never executed; bin/poll-commands.sh runs it from
# its `# >>> comment_issue handler` arm.
#
#   icc_run <project> <payload-json> <command-id>
#     payload {issue:<n>, body, actor}. Prints ONE result line.
#     rc 0 OK, 1 failed and retryable, 3 refused (the line starts `refused:`).
#
# ONLY AS THE APP. A comment posted on the PAT is a human comment to
# hold_classify (bin/lib/hold.sh), so a body with HOLD in it would hold or lift
# a ticket by accident. A box with no App token answers rc 1 and posts nothing.
#
# EXACTLY ONCE PER COMMAND ID. The comment ends with `<!-- mc-command:<id> -->`.
# Before it posts, the lib reads every comment on the issue; a comment that
# carries the marker means a lost ack or an expired lease ran this command
# before, and nothing is posted again. A failed read posts nothing (rc 1).

# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "${BASH_SOURCE[0]%/*}/gh-app-auth.sh" ] && . "${BASH_SOURCE[0]%/*}/gh-app-auth.sh"

ICC_BODY_MAX=20000

icc_run() {
  local rc
  icc__run "$@"; rc=$?
  command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
  return "$rc"
}

# icc__err <file> — the first line of gh's stderr, one line, 200 chars.
icc__err() { head -n 1 "$1" 2>/dev/null | tr -d '\r\t' | cut -c1-200; }

icc__run() {
  local project="${1:-}" payload="${2:-}" id="${3:-}"
  local pjs slug bp n body blen errf ij cj marker
  local root="${HARNESS:-${H:-}}"

  # Project: in fleet.conf, and a GitHub-issues board (no board-API prefix).
  # A read that failed is retryable, never `refused:` (BH-2009).
  [[ "$project" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "refused: $project is not a GitHub-issues board"; return 3; }
  [ -n "$root" ] || { echo "comment not posted: no harness root; retry"; return 1; }
  if ! pjs=$("$root/bin/fleet-conf.sh" --projects 2>/dev/null) || [ -z "${pjs//[[:space:]]/}" ]; then
    echo "comment not posted: fleet-conf --projects could not be read; retry"; return 1
  fi
  grep -qxF -- "$project" <<<"$pjs" || { echo "refused: $project is not a GitHub-issues board"; return 3; }
  if ! slug=$("$root/bin/fleet-conf.sh" "$project" repo 2>/dev/null) \
     || ! bp=$("$root/bin/fleet-conf.sh" "$project" board_prefix 2>/dev/null); then
    echo "comment not posted: fleet-conf $project could not be read; retry"; return 1
  fi
  if [ "$bp" != "-" ] || [ "$slug" = "-" ] || ! [[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    echo "refused: $project is not a GitHub-issues board"; return 3
  fi

  # Payload. The issue number reaches a URL only through this regex.
  jq -e 'type=="object"' >/dev/null 2>&1 <<<"$payload" || { echo "refused: bad payload"; return 3; }
  n=$(jq -r '.issue | if type=="number" and . == floor and . > 0 then tostring else "" end' <<<"$payload")
  [[ "$n" =~ ^[1-9][0-9]{0,9}$ ]] || { echo "refused: bad issue"; return 3; }
  body=$(jq -r 'if (.body|type)=="string" then .body else "" end' <<<"$payload")
  [ -n "${body//[[:space:]]/}" ] || { echo "refused: empty body"; return 3; }
  blen=$(jq -r 'if (.body|type)=="string" then (.body|length) else 0 end' <<<"$payload")
  [ "$blen" -le "$ICC_BODY_MAX" ] || { echo "refused: body too long"; return 3; }
  [[ "$id" =~ ^[1-9][0-9]*$ ]] || { echo "refused: bad command id"; return 3; }
  marker="<!-- mc-command:$id -->"

  command -v gh_auth_for >/dev/null 2>&1 && { gh_auth_for "$slug" || true; }
  case "${GH_TOKEN:-}" in ghs_*) ;; *) echo "comment not posted: no App token on this box; retry"; return 1 ;; esac

  errf=$(mktemp) || { echo "comment not posted: no temp file"; return 1; }
  if ! ij=$(gh api "repos/$slug/issues/$n" 2>"$errf") || [ -z "$ij" ]; then
    echo "comment not posted: issue read failed ($(icc__err "$errf"))"; rm -f "$errf"; return 1
  fi
  if ! jq -e 'type=="object" and has("state")' >/dev/null 2>&1 <<<"$ij"; then
    echo "comment not posted: issue read unparseable"; rm -f "$errf"; return 1
  fi
  if [ "$(jq -r 'has("pull_request")' <<<"$ij")" = true ]; then echo "refused: #$n is a pull request"; rm -f "$errf"; return 3; fi

  # Every page of comments, merged into one array. Never post blind.
  # gh's own exit code is read before jq sees the pages, so a failed read is
  # never an empty list, with or without pipefail.
  if ! cj=$(gh api --paginate "repos/$slug/issues/$n/comments?per_page=100" 2>"$errf") \
     || ! cj=$(jq -cs 'add // []' 2>/dev/null <<<"$cj") || ! jq -e 'type=="array"' >/dev/null 2>&1 <<<"$cj"; then
    echo "comment not posted: comments read failed on #$n ($(icc__err "$errf")); retry"; rm -f "$errf"; return 1
  fi
  if jq -e --arg m "$marker" 'any(.[]; (.body // "") | type=="string" and contains($m))' >/dev/null 2>&1 <<<"$cj"; then
    echo "comment already posted on #$n (command $id)"; rm -f "$errf"; return 0
  fi

  # The body goes by stdin, never argv.
  if ! jq -c --arg m "$marker" '{body: (.body + "\n\n" + $m)}' <<<"$payload" \
       | gh api -X POST "repos/$slug/issues/$n/comments" --input - >/dev/null 2>"$errf"; then
    echo "comment not posted on #$n ($(icc__err "$errf"))"; rm -f "$errf"; return 1
  fi
  rm -f "$errf"
  echo "commented on #$n as the App (command $id)"
  return 0
}
