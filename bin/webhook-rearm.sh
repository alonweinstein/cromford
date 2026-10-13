#!/bin/bash
# bin/webhook-rearm.sh — add the canonical doorbell events to every fleet repo's
# EXISTING webhook (BH-4058). An operator tool, run by hand on the hub; not a
# cron lane.
#
#   bin/webhook-rearm.sh [--dry-run|--apply] [--repo <owner/repo>] [--print-events]
#
# --dry-run (the default) reads each repo's hooks and prints what it WOULD
# patch. --apply is the only path that writes. --print-events prints the
# canonical list, one per line, and is the list bin/load-project.sh's arming
# banner and docs/EVENTS.md 4.3 are pinned to.
#
# WHAT IT TOUCHES. Only hooks whose config.url is the receiver
# ($JOBS_URL/webhooks/github). The PATCH body is {"events":[...]}: the union of
# what the hook already has and the canonical list, so it never removes an
# event, and it carries NO config key, so the URL, the content type and the
# secret are left exactly as they are. The secret is never read (jq keeps only
# id, active, events and config.url) and never sent. A repo with no receiver
# hook is reported, never armed: creating a hook needs the secret, which an
# operator pastes (docs/EVENTS.md 4.3). An inactive hook is reported, never
# patched or re-activated.
#
# WHY PAT ONLY. The App installation tokens have no Webhooks permission, so
# they cannot list or patch a repo's hooks. The token ladder here is
# gh_repo_use_pat (default PAT, then admin PAT, which holds admin:repo_hook).
# The App's OWN webhook is read once (bin/gh-token.sh --app-hook) and only
# REPORTED: its event list is changed on the App settings page, by a human.
#
# Budget: gh_budget_low is asked before the first call (low = exit 3, no
# calls), and again between repos on --apply. Worst case 2 calls per repo.
#
# Output: one line per hook (OK / WOULD PATCH / PATCHED / PATCH_FAILED /
# INACTIVE) or repo (NO_REPO_HOOK / UNREADABLE), then one summary line. --apply
# appends that summary to logs/webhook-rearm.log. Exit 0, 1 if any PATCH
# failed, 2 usage, 3 budget low.
set -uo pipefail
H="${HARNESS:-/root/harness}"
HERE="$(cd "$(dirname "$0")" && pwd)"
GH="${WEBHOOK_REARM_GH:-gh}"
APPHOOK="${WEBHOOK_REARM_APP_HOOK:-$HERE/gh-token.sh --app-hook}"
LOG="$H/logs/webhook-rearm.log"
STAMP() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# The events wakeOf (worker/jobs/src/lib/core.js) understands. Defined once.
WR_EVENTS="pull_request pull_request_review check_suite check_run push deployment_status issues issue_comment status workflow_run merge_group"

usage() { echo "usage: webhook-rearm.sh [--dry-run|--apply] [--repo <owner/repo>] [--print-events]" >&2; exit 2; }
MODE=dry-run ONE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) MODE=dry-run ;;
    --apply) MODE=apply ;;
    --repo) [ $# -ge 2 ] || usage; ONE="$2"; shift ;;
    --print-events) printf '%s\n' $WR_EVENTS; exit 0 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
  shift
done
if [ -n "$ONE" ] && ! [[ "$ONE" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  echo "webhook-rearm: --repo must be owner/repo, got '$ONE'" >&2; exit 2
fi
command -v jq >/dev/null 2>&1 || { echo "webhook-rearm: jq is required" >&2; exit 2; }
CANON=$(printf '%s\n' $WR_EVENTS | jq -Rsc 'split("\n") | map(select(length > 0))')

# shellcheck source=/dev/null
[ -r "$HERE/jobs-client.sh" ] && . "$HERE/jobs-client.sh" >/dev/null 2>&1
# BH-4080: the fallback worker host is built from HARNESS_WORKERS_SUBDOMAIN.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$HERE/lib/deployment.sh}" || exit 1
RECEIVER="${JOBS_URL:-https://harness-jobs.$HARNESS_WORKERS_SUBDOMAIN.workers.dev}/webhooks/github"
# shellcheck source=bin/lib/gh-repo-token.sh
[ -r "$HERE/lib/gh-repo-token.sh" ] && . "$HERE/lib/gh-repo-token.sh" 2>/dev/null
# shellcheck source=bin/lib/gh-budget.sh
[ -r "$HERE/lib/gh-budget.sh" ] && . "$HERE/lib/gh-budget.sh" 2>/dev/null

wr_budget_low() { # rc 0 = low; healthy, unknown or no lib = proceed
  command -v gh_budget_low >/dev/null 2>&1 || return 1
  gh_budget_low webhook-rearm; [ "$?" -eq 0 ]
}
if wr_budget_low; then echo "webhook-rearm: GitHub API budget low — no calls made, re-run later"; exit 3; fi

if [ -n "$ONE" ]; then
  TARGETS="$ONE"
else
  TARGETS=""
  for P in $("$HERE/fleet-conf.sh" --projects 2>/dev/null); do
    R=$("$HERE/fleet-conf.sh" "$P" repo 2>/dev/null) || continue
    case "$R" in ''|'-') continue ;; esac
    case " $TARGETS " in *" $R "*) continue ;; esac
    TARGETS="${TARGETS:+$TARGETS }$R"
  done
fi

# wr_hooks_get <repo> — the hooks as [{id,active,events,url}], nothing else.
wr_hooks_get() {
  "$GH" api "/repos/$1/hooks?per_page=100" 2>/dev/null \
    | jq -c 'if type == "array" then map({id, active, events, url: .config.url}) else error("not a hook list") end' 2>/dev/null
}
# wr_hooks_read <repo> — sets HOOKS; rc 1 = no PAT rung here could read them.
wr_hooks_read() {
  local r="$1"
  command -v gh_repo_use_pat >/dev/null 2>&1 && gh_repo_use_pat "$r" >/dev/null 2>&1
  HOOKS=$(wr_hooks_get "$r") && return 0
  if [ "${GH_REPO_PAT_RUNG:-}" = default ] && command -v gh_repo_next_rung >/dev/null 2>&1 \
     && gh_repo_next_rung "$r" >/dev/null 2>&1; then
    HOOKS=$(wr_hooks_get "$r") && return 0
  fi
  return 1
}
# wr_missing <events-json> — the canonical events the hook lacks, space-separated.
wr_missing() {
  jq -rn --argjson have "$1" --argjson want "$CANON" \
    'if ($have | index("*")) then "" else ($want - $have | sort | join(" ")) end'
}

N=0 OK=0 WP=0 FAILED=0 UNARMED=0 UNREADABLE=0 INACTIVE=0 NOT_REACHED=""
FIRST=1
for R in $TARGETS; do
  if [ "$MODE" = apply ] && [ "$FIRST" = 0 ] && wr_budget_low; then
    NOT_REACHED="${NOT_REACHED:+$NOT_REACHED,}$R"; continue
  fi
  FIRST=0
  N=$((N+1))
  HOOKS=""
  if ! wr_hooks_read "$R"; then
    command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
    UNREADABLE=$((UNREADABLE+1))
    echo "UNREADABLE $R — no PAT here holds admin:repo_hook (env/github-admin.env)"
    continue
  fi
  MINE=$(jq -c --arg u "$RECEIVER" '[.[] | select(.url == $u)]' <<<"$HOOKS")
  if [ "$(jq 'length' <<<"$MINE")" = 0 ]; then
    UNARMED=$((UNARMED+1))
    echo "NO_REPO_HOOK $R — arm per docs/EVENTS.md 4.3 (operator pastes the secret), or the App webhook covers it"
  fi
  while IFS=$'\t' read -r ID ACTIVE EVENTS; do
    [ -n "$ID" ] || continue
    if [ "$ACTIVE" != true ]; then
      INACTIVE=$((INACTIVE+1))
      echo "INACTIVE $R hook $ID — not patched; re-activating it is an operator decision"
      continue
    fi
    MISS=$(wr_missing "$EVENTS")
    if [ -z "$MISS" ]; then
      OK=$((OK+1))
      echo "OK $R hook $ID — all $(jq 'length' <<<"$CANON") events"
      continue
    fi
    BODY=$(jq -cn --argjson have "$EVENTS" --argjson want "$CANON" '{events: ($have + $want | unique)}')
    if [ "$MODE" = dry-run ]; then
      WP=$((WP+1))
      echo "WOULD PATCH $R hook $ID add: $MISS"
      echo "  body: $BODY"
      continue
    fi
    RESP=$(printf '%s' "$BODY" | "$GH" api -X PATCH "/repos/$R/hooks/$ID" --input - 2>&1); PRC=$?
    if [ "$PRC" -eq 0 ] && [ -z "$(wr_missing "$(jq -c '.events // []' <<<"$RESP" 2>/dev/null || echo '[]')")" ]; then
      WP=$((WP+1))
      echo "PATCHED $R hook $ID added: $MISS"
    else
      FAILED=$((FAILED+1))
      ERR=$(printf '%s' "$RESP" | grep -o 'HTTP [0-9]*' | tail -n1)
      echo "PATCH_FAILED $R hook $ID ${ERR:-rc=$PRC}"
    fi
  done < <(jq -r '.[] | [.id, (.active | tostring), (.events // [] | tojson)] | @tsv' <<<"$MINE")
  command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
done

# The App's own webhook: report only.
if [ -z "$NOT_REACHED" ] && APPOUT=$($APPHOOK 2>/dev/null); then
  IFS=$'\t' read -r APP_URL APP_EVENTS <<<"$APPOUT"
  if [ "$APP_URL" = "$RECEIVER" ]; then
    APP_MISS=$(wr_missing "$(printf '%s' "$APP_EVENTS" | jq -Rc 'split(",") | map(select(length > 0))')")
    [ -n "$APP_MISS" ] && echo "APP_HOOK missing: $APP_MISS — add them on the GitHub App settings page (needs App permissions: Commit statuses, Actions, Merge queues: read)"
  fi
fi

WORD=would_patch; [ "$MODE" = apply ] && WORD=patched
SUM="webhook-rearm mode=$MODE repos=$N ok=$OK $WORD=$WP failed=$FAILED unarmed=$UNARMED unreadable=$UNREADABLE inactive=$INACTIVE"
[ -n "$NOT_REACHED" ] && SUM="$SUM budget-low not_reached=$NOT_REACHED"
echo "$SUM"
if [ "$MODE" = apply ]; then
  mkdir -p "$H/logs" 2>/dev/null
  echo "$(STAMP) $SUM" >> "$LOG"
fi
[ -n "$NOT_REACHED" ] && exit 3
[ "$FAILED" -eq 0 ] || exit 1
exit 0
