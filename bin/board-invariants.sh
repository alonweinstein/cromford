#!/bin/bash
# bin/board-invariants.sh — cron-able mechanical board↔GitHub consistency sweep
# (2026-08-14, after project-1 #678 sat `done` while its PR was still OPEN — the
# board told the client the work shipped; GitHub said it never landed).
#
# The board and GitHub each tell a story; this sweep flags the places where the
# stories disagree. Mechanical only (no AI, no auto-fix in v1 — a wrong auto-fix
# on a client-facing board costs more than a human glance at an alert):
#   (a) DONE-WITH-OPEN-PR: a ticket moved to done in the last 72h while a PR on
#       its branches (ticket/<key>* or agent/<KEY>*) is still OPEN. Done means
#       merged; an open PR means it is not.
#   (b) MERGED-NO-CLOSEOUT: a review/team-turn ticket whose PR merged >6h ago
#       with the board's last activity PREDATING the merge — the what-shipped
#       close-out comment never posted; the client is watching a stale thread.
#
# One ALERTS line per violation, deduped 24h via state (a violation that
# persists re-alerts daily, not per cron tick). DRY=1 prints the would-be
# lines to stdout and writes nothing — the sanity-check mode.
# usage: board-invariants.sh  (cron)   |   DRY=1 board-invariants.sh [project]
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
DRY="${DRY:-0}"
STATE="$H/state/board-invariants-alerted.json"
ALERTS="$H/logs/ALERTS.log"
LOG="$H/logs/board-invariants.log"
NOW=$(date +%s)
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
[ -s "$STATE" ] || { [ "$DRY" = 1 ] || echo '{}' > "$STATE"; }

# Empty input must yield 0: `date -d ''` "succeeds" with today's midnight.
iso2epoch() { [ -n "${1:-}" ] && date -d "$1" +%s 2>/dev/null || echo 0; }

# App token per repo (#425): armed where the repo becomes known; an unarmed box runs as today.
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$H/bin/lib/gh-app-auth.sh" ] && . "$H/bin/lib/gh-app-auth.sh"

alert() { # alert <dedup-key> <line>
  local akey="$1" line="$2" last
  last=$(jq -r --arg k "$akey" '.[$k] // 0' "$STATE" 2>/dev/null || echo 0)
  [ $((NOW - ${last:-0})) -lt 86400 ] && return 0
  if [ "$DRY" = 1 ]; then echo "DRY: $line"; return 0; fi
  echo "$(STAMP) [board-invariants] $line" >> "$ALERTS"
  jq --arg k "$akey" --argjson t "$NOW" '.[$k]=$t' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}

# Board projects only: fleet.conf rows with a real board prefix (JIRA-driven
# rows carry "-" and have no board API for this sweep to compare against).
# >>> board projects
# An empty list means zero invariant violations found, which reads identically
# to a clean fleet — the one answer this sweep must never give by accident.
PROJECTS=$("$H/bin/fleet-projects-or-alert.sh" board-invariants --with-board) || {
  echo "$(STAMP) FATAL: fleet.conf unreadable — no projects to sweep, exiting" >> "$LOG"; exit 1; }
[ $# -ge 1 ] && PROJECTS="$1"
# <<< board projects

# Ticket-key fallback: project-4's board API returns no .key field (only .number),
# so the branch-matchable key is derived <prefix>-<number>. Boards that DO
# serve .key (project-1 TK-*) are read as-is and never touch this map, and a
# board that serves keyPrefix is used before it (KP, below).
declare -A KEYPFX=( [project-1]=PB [project-2]=PB [project-3]=FR [project-4]=AR [project-9]=SO )

for P in $PROJECTS; do
  set -a; . "$HENV/global.env" 2>/dev/null; . "$HENV/$P.env" 2>/dev/null; set +a
  REPO=$("$H/bin/fleet-conf.sh" "$P" repo); BASEURL=$("$H/bin/fleet-conf.sh" "$P" prod)
  PREFIX=$("$H/bin/fleet-conf.sh" "$P" board_prefix)
  # Exactly one *_INTERNAL_API_TOKEN, or the project is skipped LOUDLY. The
  # `head -1` this replaces would authenticate with whichever token happened to
  # be first the day an env file carried two.
  TOKEN=$("$H/bin/internal-token-for.sh" "$P") || TOKEN=""
  [ -n "$TOKEN" ] && [ -n "$BASEURL" ] || { echo "$(STAMP) $P: no token/base — skipped" >> "$LOG"; continue; }
  BOARDS=$(curl -s -m 20 -H "Authorization: Bearer $TOKEN" -H "User-Agent: curl/8" "$BASEURL$PREFIX/boards")
  BID=$(echo "$BOARDS" | jq -r 'if type=="array" then .[0].id else (.boards[0].id // empty) end' 2>/dev/null)
  [ -n "$BID" ] || { echo "$(STAMP) $P: board list failed" >> "$LOG"; continue; }
  # A board that serves its keyPrefix (same board [0] BID came from) is the
  # source; the KEYPFX map above is the fallback for boards that do not (BH-1956).
  KP=$(echo "$BOARDS" | jq -r 'if type=="array" then (.[0].keyPrefix // empty) else (.boards[0].keyPrefix // empty) end' 2>/dev/null)
  KP="${KP:-${KEYPFX[$P]:-}}"
  TICKETS=$(curl -s -m 30 -H "Authorization: Bearer $TOKEN" -H "User-Agent: curl/8" "$BASEURL$PREFIX/boards/$BID/tickets" \
    | jq -c '(if type=="array" then . else (.tickets // []) end)' 2>/dev/null)
  [ -n "$TICKETS" ] && [ "$TICKETS" != "null" ] || { echo "$(STAMP) $P: ticket list failed" >> "$LOG"; continue; }

  # One GitHub round-trip per state, matched locally per ticket.
  command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$REPO" || true
  OPEN_PRS=$(gh pr list -R "$REPO" --state open --limit 100 --json number,url,headRefName 2>/dev/null || echo '[]')
  MERGED_PRS=$(gh pr list -R "$REPO" --state merged --limit 100 --json number,url,headRefName,mergedAt 2>/dev/null || echo '[]')

  # (a) done in the last 72h, but a ticket/agent branch PR is still open (#678)
  echo "$TICKETS" | jq -r --argjson now "$NOW" '
    .[] | select((.status // "") == "done")
    | (.lastActivityAt // .updatedAt // .createdAt // "") as $t
    | select($t != "")
    | select(($now - (($t | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601?) // 0)) <= 259200)
    | "\(.key // "-")\t\(.number // "-")"' 2>/dev/null | while IFS=$'\t' read -r KEY NUM; do
      # "-" is the no-key sentinel: tab is IFS whitespace, so a genuinely empty
      # first field would be swallowed and every field would shift left.
      [ "$KEY" != "-" ] || { KEY=""; [ "$NUM" != "-" ] && [ -n "$KP" ] && KEY="$KP-$NUM"; }
      [ -n "$KEY" ] || continue
      KL=$(echo "$KEY" | tr '[:upper:]' '[:lower:]')
      # Boundary-anchored: bare key or a -suffix (ticket/TK-662-r2), never a
      # longer number — startswith("ticket/TK-6") would claim ticket/TK-678.
      echo "$OPEN_PRS" | jq -r --arg re "^(ticket/$KL|agent/$KEY)(-|$)" \
        '.[] | select(.headRefName | test($re)) | "\(.number)\t\(.url)"' \
        | while IFS=$'\t' read -r NUM URL; do
          alert "done-open-pr:$P:$KEY:$NUM" "$P $KEY is DONE on the board but PR #$NUM is still OPEN ($URL) — done means merged; either merge/close the PR or move the ticket back. (#678 class)"
        done
    done

  # (b) review/team-turn tickets whose PR merged >6h ago with no board activity
  # since the merge — the close-out comment never happened. lastActivityAt is
  # the mechanical proxy for "last comment": any later board touch (comment or
  # move) counts as a close-out attempt and suppresses the alert, so this only
  # fires on genuinely silent threads.
  echo "$TICKETS" | jq -r '
    .[] | select(((.status // "") == "review") or ((.waitingOn // "") == "team"))
    | select((.status // "") != "done" and (.status // "") != "closed")
    | "\(.key // "-")\t\(.number // "-")\t\(.lastActivityAt // .updatedAt // .createdAt // "-")"' 2>/dev/null \
    | while IFS=$'\t' read -r KEY NUM LASTACT; do
      # "-" sentinels, same reason as above (tab-IFS swallows empty fields).
      [ "$KEY" != "-" ] || { KEY=""; [ "$NUM" != "-" ] && [ -n "$KP" ] && KEY="$KP-$NUM"; }
      [ -n "$KEY" ] || continue
      [ "$LASTACT" != "-" ] || LASTACT=""
      KL=$(echo "$KEY" | tr '[:upper:]' '[:lower:]')
      LA=$(iso2epoch "$LASTACT")
      # Same boundary-anchored branch match as invariant (a).
      echo "$MERGED_PRS" | jq -r --arg re "^(ticket/$KL|agent/$KEY)(-|$)" \
        '.[] | select(.headRefName | test($re)) | "\(.number)\t\(.url)\t\(.mergedAt)"' \
        | while IFS=$'\t' read -r NUM URL MERGEDAT; do
          MA=$(iso2epoch "$MERGEDAT")
          [ "$MA" -gt 0 ] || continue
          [ $((NOW - MA)) -gt 21600 ] || continue
          [ "$LA" -lt "$MA" ] || continue
          alert "merged-no-closeout:$P:$KEY:$NUM" "$P $KEY: PR #$NUM merged $(( (NOW - MA) / 3600 ))h ago ($URL) but the board's last activity predates the merge — the what-shipped close-out never posted; the client is watching a silent thread."
        done
    done
  command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
done
[ "$DRY" = 1 ] || echo "$(STAMP) sweep done" >> "$LOG"
exit 0
