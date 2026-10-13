#!/bin/bash
# gh-identity: app-token
# bin/lib/ticket-hold-cmd.sh — the hub side of the console's hold_ticket /
# unhold_ticket commands (BH-2326.1). Sourced, never executed; bin/poll-commands.sh
# runs it from its `# >>> ticket hold handler` arm.
#
#   thc_run <hold|unhold> <project> <payload-json>
#     payload {ticket:'PREFIX-<n>' | issue:<n>, reason, actor}. `issue` counts
#     only when `ticket` is absent or null. Prints ONE result line.
#     rc 0 OK, 1 failed and retryable, 3 refused (the line starts `refused:`).
#
# A LABEL, NOT A HOLD COMMENT. hold_classify (bin/lib/hold.sh) drops Bot
# comments, so a HOLD comment posted as the App would hold nothing. The `hold`
# label is read before any thread (BH-2504) by fly-pool, run-build,
# blocked-resolver and orphan-reconcile, so adding or removing it is the whole
# effect. The comment only tells a human what happened and why.
#
# THE COMMENT GOES OUT ONLY AS THE APP. On a box that cannot mint an App token
# the label write still runs on the PAT, but the comment is skipped: a PAT
# comment is a human comment to hold_classify, and "Hold lifted ..." matches its
# lift vocabulary, so it would silently lift a person's earlier HOLD comment.
#
# ORDER: issue read, label write, comment, re-read, ledger. The ledger row
# (ledgers kind=ticket_hold key=<project>#<n>, the card's copy) is written only
# once the label is in the target state; every rc-1 path returns before it.

# shellcheck source=bin/lib/hold.sh
[ -r "${BASH_SOURCE[0]%/*}/hold.sh" ] && . "${BASH_SOURCE[0]%/*}/hold.sh"
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "${BASH_SOURCE[0]%/*}/gh-app-auth.sh" ] && . "${BASH_SOURCE[0]%/*}/gh-app-auth.sh"

thc_run() {
  local rc
  thc__run "$@"; rc=$?
  command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
  return "$rc"
}

# thc__err <file> — the first line of gh's stderr, one line, 200 chars.
thc__err() { head -n 1 "$1" 2>/dev/null | tr -d '\r\t' | cut -c1-200; }

thc__run() {
  local verb="${1:-}" project="${2:-}" payload="${3:-}"
  local pjs slug bp ticket n reason actor app=0 errf ij had changed=0 note="" res
  local text cbody hc verdict why status detail
  case "$verb" in hold|unhold) ;; *) echo "refused: bad verb"; return 3 ;; esac

  # Project: in fleet.conf, and a GitHub-issues board (no board-API prefix).
  # A read that failed is retryable, never `refused:` (BH-2009).
  [[ "$project" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "refused: $project is not a GitHub-issues board"; return 3; }
  if ! pjs=$("$HARNESS/bin/fleet-conf.sh" --projects 2>/dev/null) || [ -z "${pjs//[[:space:]]/}" ]; then
    echo "ticket hold not changed: fleet-conf --projects could not be read; retry"; return 1
  fi
  grep -qxF -- "$project" <<<"$pjs" || { echo "refused: $project is not a GitHub-issues board"; return 3; }
  if ! slug=$("$HARNESS/bin/fleet-conf.sh" "$project" repo 2>/dev/null) \
     || ! bp=$("$HARNESS/bin/fleet-conf.sh" "$project" board_prefix 2>/dev/null); then
    echo "ticket hold not changed: fleet-conf $project could not be read; retry"; return 1
  fi
  if [ "$bp" != "-" ] || [ "$slug" = "-" ] || ! [[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    echo "refused: $project is not a GitHub-issues board"; return 3
  fi

  # Payload. The issue number reaches a URL only through this regex.
  jq -e 'type=="object"' >/dev/null 2>&1 <<<"$payload" || { echo "refused: bad payload"; return 3; }
  # A string ticket is matched as before; with no ticket, a positive integer
  # `issue` (the MCP hold_issue shape) is the number. The t:/i: tag keeps the
  # two apart, so a ticket string can never pass as an issue.
  ticket=$(jq -r 'if (.ticket|type)=="string" then "t:" + .ticket
    elif .ticket == null and (.issue|type)=="number" and .issue == (.issue|floor) and .issue > 0 then "i:\(.issue)"
    else "" end' <<<"$payload")
  if [[ "$ticket" =~ ^t:[A-Za-z][A-Za-z0-9]*-([1-9][0-9]*)$ ]] || [[ "$ticket" =~ ^i:([1-9][0-9]{0,9})$ ]]; then
    n="${BASH_REMATCH[1]}"
  else echo "refused: bad ticket"; return 3; fi
  reason=$(jq -r '.reason // "" | tostring | sub("^\\s+"; "") | sub("\\s+$"; "") | .[0:500]' <<<"$payload")
  [ -n "$reason" ] || reason="no reason given"
  actor=$(jq -r 'if (.actor|type)=="string" then .actor else "" end' <<<"$payload")
  [[ "$actor" =~ ^[A-Za-z0-9._@-]{1,96}$ ]] || actor="console"

  command -v gh_auth_for >/dev/null 2>&1 && { gh_auth_for "$slug" || true; }
  case "${GH_TOKEN:-}" in ghs_*) app=1 ;; esac

  errf=$(mktemp) || { echo "ticket hold not changed: no temp file"; return 1; }
  if ! ij=$(gh api "repos/$slug/issues/$n" 2>"$errf") || [ -z "$ij" ]; then
    echo "ticket hold not changed: issue read failed ($(thc__err "$errf"))"; rm -f "$errf"; return 1
  fi
  if ! jq -e 'type=="object" and has("state")' >/dev/null 2>&1 <<<"$ij"; then
    echo "ticket hold not changed: issue read unparseable"; rm -f "$errf"; return 1
  fi
  if [ "$(jq -r 'has("pull_request")' <<<"$ij")" = true ]; then echo "refused: #$n is a pull request"; rm -f "$errf"; return 3; fi
  if [ "$(jq -r '.state' <<<"$ij")" != open ]; then echo "refused: #$n is closed"; rm -f "$errf"; return 3; fi
  had=$(jq -r '[(.labels // [])[] | if type=="object" then (.name // "") else tostring end] | index("hold") != null' <<<"$ij")

  if [ "$verb" = hold ] && [ "$had" != true ]; then
    if ! jq -nc '{labels:["hold"]}' | gh api -X POST "repos/$slug/issues/$n/labels" --input - >/dev/null 2>"$errf"; then
      echo "hold not set: label add failed ($(thc__err "$errf"))"; rm -f "$errf"; return 1
    fi
    changed=1
  elif [ "$verb" = unhold ] && [ "$had" = true ]; then
    if gh api -X DELETE "repos/$slug/issues/$n/labels/hold" >/dev/null 2>"$errf"; then changed=1
    elif ! grep -q 'HTTP 404' "$errf"; then
      echo "hold not lifted: label remove failed ($(thc__err "$errf"))"; rm -f "$errf"; return 1
    fi
  fi

  if [ "$changed" = 1 ]; then
    if [ "$verb" = hold ]; then
      text="Held from Mission Control by $actor: $reason. The \`hold\` label stops every build, rebuild and requeue of this ticket. Remove the label, or UNHOLD it from the console, to lift it."
    else
      text="Hold lifted from Mission Control by $actor: $reason."
    fi
    if [ "$app" != 1 ]; then note="$note; comment not posted (no App token)"
    else
      cbody=$(jq -nc --arg b "$text" '{body:$b}')
      gh api -X POST "repos/$slug/issues/$n/comments" --input - >/dev/null 2>"$errf" <<<"$cbody" \
        || note="$note; comment not posted ($(thc__err "$errf"))"
    fi
  fi
  rm -f "$errf"

  if command -v hold_check >/dev/null 2>&1; then hc=$(hold_check "$slug" "$n")
  else hc=$'unreadable\thold lib not loaded'; fi
  verdict="${hc%%$'\t'*}"; why="${hc#*$'\t'}"; why=$(printf '%s' "$why" | tr '\t\n' '  ')
  if [ "$verb" = hold ]; then
    status=held; [ "$verdict" = unreadable ] && why="re-read unreadable: $why"
    if [ "$changed" = 1 ]; then res="held #$n (label added)"; else res="already held #$n (label was on)"; fi
  else
    case "$verdict" in held) status=held ;; clear) status=clear ;; *) status=unknown ;; esac
    if [ "$changed" = 1 ]; then
      case "$status" in
        clear) res="hold lifted on #$n" ;;
        held) res="hold label removed from #$n; still held: $why" ;;
        *) res="hold label removed from #$n; hold state unknown: $why" ;;
      esac
    else
      case "$status" in
        clear) res="hold label was not on #$n; not held" ;;
        held) res="hold label was not on #$n; still held: $why" ;;
        *) res="hold label was not on #$n; hold state unknown: $why" ;;
      esac
    fi
  fi

  detail="$verb by $actor at $(date -u +%Y-%m-%dT%H:%M:%SZ): $reason | $why"
  if ! command -v job_ledger_put >/dev/null 2>&1; then note="$note; card not updated (no jobs client)"
  elif ! job_ledger_put ticket_hold "$project#$n" "$status" "$detail"; then
    note="$note; card not updated (ledger http=${JOBS_HTTP:-unreachable})"
  fi
  printf '%s\n' "$(printf '%s' "$res$note" | tr '\t\n' '  ')"
  return 0
}
