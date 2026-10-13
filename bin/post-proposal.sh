#!/bin/bash
# post-proposal.sh <project> <slug> — deterministic (no LLM) posting of an
# approved proposal to the client's board: create ticket, upload mockup +
# screenshots as attachments, inject the mockup block into the description,
# flip the turn to the client. Invoked by product-cmd.sh on the operator's approve,
# or directly by run-product.sh when flags/product-autonomy-<project> exists.
set -uo pipefail
PROJECT="${1:?usage: post-proposal.sh <project> <slug>}"
SLUG="${2:?slug}"
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
ALERTS="$HARNESS/logs/ALERTS.log"
LEDGER="$HARNESS/state/product-$PROJECT.ledger.json"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

set -a
[ -f "$HENV/global.env" ] && . "$HENV/global.env"
[ -f "$HENV/$PROJECT.env" ] && . "$HENV/$PROJECT.env"
set +a

# Main's line for a project this script does not post for, from either path
# below: no board arm, or a GitHub-Issues repo off the approve allowlist.
unknown_project() { echo "$(STAMP) [$PROJECT] post-proposal: unknown project" >> "$ALERTS"; exit 1; }

# Per-board API surface — same case block as triage-gate.sh.
case "$PROJECT" in
  project-1)   BASE="${PROJECT_1_API_BASE:-}"; TOKEN="${PROJECT_1_INTERNAL_API_TOKEN:-}"; BP="/api/board"; SIDE="client"; KEYPFX="PB"; UIP="/board" ;;
  project-2) BASE="${PROJECT_2_APP_BASE:-}";       TOKEN="${PROJECT_2_INTERNAL_API_TOKEN:-}";       BP="/api/board"; SIDE="client"; KEYPFX="PB"; UIP="/board" ;;
  project-3)       BASE="${PROJECT_3_APP_BASE:-}";     TOKEN="${PROJECT_3_INTERNAL_API_TOKEN:-}";     BP="/api/feature-board"; SIDE="client"; KEYPFX="FR"; UIP="/feature-board" ;;
  project-4)       BASE="${PROJECT_4_API_BASE:-}";     TOKEN="${PROJECT_4_INTERNAL_API_TOKEN:-}";     BP="/api/accounting/requests-board"; SIDE="requester"; KEYPFX="AR"; UIP="/accounting/requests-board" ;;
  *)
    # A GitHub-Issues board (BH-4065): a fleet.conf project whose board prefix
    # is "-", the same test triage-gate.sh's generic arm uses. Its [Proposal]
    # is an issue on the project's repo, labelled ai-build so triage sees it,
    # and only when that repo is on the approve allowlist (checked below).
    GH_CANDIDATE=""
    if [ "$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null)" = "-" ]; then
      GH_CANDIDATE=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null)
    fi
    [[ ${GH_CANDIDATE:-} =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || unknown_project ;;
esac
GH_CANDIDATE="${GH_CANDIDATE:-}"; GH_REPO=""
[ -n "$GH_CANDIDATE" ] || { [ -n "${BASE:-}" ] && [ -n "${TOKEN:-}" ]; } || { echo "$(STAMP) [$PROJECT] post-proposal: missing board env" >> "$ALERTS"; exit 1; }

API() { curl -sf --max-time 30 -H "Authorization: Bearer $TOKEN" -H "User-Agent: curl/8" "$@"; }
PKEY="prop:$PROJECT:$SLUG"
NOWISO() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# Proposal rows (BH-2719). The ledger file dies with the box, so it cannot be
# the record of what reached the client's board. The product_proposals row is.
# Bring the file up to the rows, then ask THIS slug's row before any board call:
#   posted (row or file) -> nothing to send, exit 0
#   posting              -> an earlier post died between claim and stamp, and
#                           the ticket may exist: a human looks, exit 1
#   unreadable (rc 1)    -> a configured worker that cannot answer: exit 1
#   no row (rc 2)        -> post, claiming the row `posting` first
#   no worker (rc 3)     -> JOBS_URL empty on purpose: the file alone
# shellcheck source=bin/jobs-client.sh
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"
# shellcheck source=bin/lib/proposal-rows.sh
[ -r "$HARNESS/bin/lib/proposal-rows.sh" ] && . "$HARNESS/bin/lib/proposal-rows.sh"

# The approve allowlist (BH-4065, the operator 2026-10-04): an Approve files an
# ai-build issue only on a repo the settings row
# lane.archie-research.approve_files_issue_repos names (comma or whitespace
# separated, exact owner/repo). Before any row read or claim, so a repo off the
# list leaves the Ideas row exactly as the console set it.
#   row (rc 0)                     -> that list
#   no row (rc 2), or JOBS_URL
#   empty (no worker on purpose)   -> the documented default below
#   unreadable with a worker set   -> fail closed: nothing filed, one alert
# The default is the harness's own repo, from the deployment defaults home
# (BH-4080, bin/lib/deployment.sh; no literal slug here).
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$(dirname "${BASH_SOURCE[0]}")/lib/deployment.sh}" || exit 1
APPROVE_REPOS_DEFAULT="$HARNESS_REPO"
if [ -n "$GH_CANDIDATE" ]; then
  ALLOW="$APPROVE_REPOS_DEFAULT"
  if [ -n "${JOBS_URL:-}" ]; then
    _AV=""; _ARC=1
    command -v setting_get >/dev/null 2>&1 && { _AV=$(setting_get lane.archie-research.approve_files_issue_repos); _ARC=$?; }
    case "$_ARC" in
      0) ALLOW="$_AV" ;;
      2) ;;
      *) HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$PROJECT] post-proposal: $SLUG approve allowlist unreadable (settings row lane.archie-research.approve_files_issue_repos, harness-jobs /api/settings), not posting. Approve again once harness-jobs answers"
         exit 1 ;;
    esac
  fi
  # Split on commas and whitespace with no pathname expansion: a row of
  # `example-org/*` is an entry that matches nothing, never a glob over CWD.
  IFS=$', \t\n' read -rd '' -a _AL <<< "$ALLOW" || true
  for _R in "${_AL[@]}"; do
    [ "$_R" = "$GH_CANDIDATE" ] && GH_REPO="$GH_CANDIDATE" && break
  done
  [ -n "$GH_REPO" ] || unknown_project
fi
# A configured box without the lib cannot read its rows: that refuses (rc 1),
# it does not post from the file alone.
ROW_ST=""; ROW_RC=3; [ -n "${JOBS_URL:-}" ] && ROW_RC=1
if command -v prow_get >/dev/null 2>&1; then
  prow_restore "$PROJECT" "$LEDGER"
  ROW_ST=$(prow_get "$PROJECT" "$SLUG"); ROW_RC=$?
fi
FILE_ST=$(jq -r --arg s "$SLUG" '[.[] | select(.slug == $s)] | last | .status // empty' "$LEDGER" 2>/dev/null)
if [ "$FILE_ST" = posted ] || { [ "$ROW_RC" = 0 ] && [ "$ROW_ST" = posted ]; }; then
  echo "$(STAMP) [$PROJECT] post-proposal: $SLUG already posted, nothing sent"; exit 0
fi
case "$ROW_RC" in
  0) if [ "$ROW_ST" = posting ]; then
       echo "$(STAMP) [$PROJECT] post-proposal: $SLUG has a posting row with no ticket recorded, not posting. Check the board for its [Proposal] ticket; if there is none, PUT its row status gate_pending and approve again" >> "$ALERTS"; exit 1
     fi ;;
  2|3) ;;
  *) echo "$(STAMP) [$PROJECT] post-proposal: $SLUG proposal row unreadable, not posting (harness-jobs /api/product-proposals; see logs/jobs-client.log). Approve again once it answers" >> "$ALERTS"; exit 1 ;;
esac
PRE_ST="${ROW_ST:-${FILE_ST:-gate_pending}}"

# Locate the idea dir + metadata from the ledger.
IDIR=$(jq -r --arg s "$SLUG" '[.[] | select(.slug == $s)] | last | .dir // empty' "$LEDGER" 2>/dev/null)
TITLE=$(jq -r --arg s "$SLUG" '[.[] | select(.slug == $s)] | last | .title // empty' "$LEDGER" 2>/dev/null)
# An entry written on ANOTHER box (BH-4065: Archie's research lane runs on the
# hub, approve runs on the project's owning box) names a dir that does not
# exist here. When its record carries the artifact bodies, they are written
# out under this box's state and that is the dir posted from.
if { [ -z "$IDIR" ] || [ ! -s "$IDIR/ticket.html" ] || [ ! -s "$IDIR/mockup.html" ]; } \
   && [[ $SLUG =~ ^[A-Za-z0-9_-]+$ ]] \
   && jq -e --arg s "$SLUG" '[.[] | select(.slug == $s)] | last | .artifacts
        | (.ticket_html | type == "string" and length > 0) and (.mockup_html | type == "string" and length > 0)' \
        "$LEDGER" >/dev/null 2>&1; then
  ADIR="$HARNESS/state/proposal-artifacts/$PROJECT/$SLUG"
  if mkdir -p "$ADIR" \
     && jq -j --arg s "$SLUG" '[.[] | select(.slug == $s)] | last | .artifacts.ticket_html' "$LEDGER" > "$ADIR/ticket.html" \
     && jq -j --arg s "$SLUG" '[.[] | select(.slug == $s)] | last | .artifacts.mockup_html' "$LEDGER" > "$ADIR/mockup.html"; then
    IDIR="$ADIR"
  fi
fi
if [ -z "$IDIR" ] || [ ! -s "$IDIR/ticket.html" ] || [ ! -s "$IDIR/mockup.html" ]; then
  echo "$(STAMP) [$PROJECT] post-proposal: $SLUG not found or artifacts missing (dir=$IDIR)" >> "$ALERTS"; exit 1
fi

# GitHub-Issues board (BH-4065): one issue, the mockup inlined in its body
# (there is no attachment store), then the same claim, stamp and beat as below.
if [ -n "$GH_REPO" ]; then
  for _P in "$HARNESS/bin/lib/gh-rest.sh" "$HARNESS/bin/lib/gh-app-auth.sh"; do
    # shellcheck source=/dev/null
    [ -r "$_P" ] && . "$_P"
  done
  command -v gh_rest >/dev/null 2>&1 || { HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$PROJECT] post-proposal: $SLUG not posted, bin/lib/gh-rest.sh is missing on this box"; exit 1; }
  command -v gh_auth_for >/dev/null 2>&1 && { gh_auth_for "$GH_REPO" || true; }
  GHW=$(mktemp -d "${TMPDIR:-/tmp}/post-proposal.XXXXXX") || exit 1
  trap 'rm -rf "$GHW"' EXIT
  awk -v mf="$IDIR/mockup.html" 'BEGIN { while ((getline l < mf) > 0) m = m l "\n" }
    { i = index($0, "{{MOCKUP_BLOCK}}"); if (i) print substr($0, 1, i - 1) m substr($0, i + 16); else print }' \
    "$IDIR/ticket.html" > "$GHW/body"
  if [ "$ROW_RC" != 3 ] && ! prow_put "$PROJECT" "$SLUG" "$LEDGER" posting; then
    HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$PROJECT] post-proposal: $SLUG posting claim did not land in harness-jobs, not posting. Approve again once it answers"; exit 1
  fi
  CREATE_RC=0
  gh_rest POST "repos/$GH_REPO/issues" -f "title=[Proposal] $TITLE" -F "body=@$GHW/body" -f 'labels[]=ai-build' > "$GHW/resp" || CREATE_RC=$?
  TICKET_ID=""; TICKET_URL=""
  if [ "$CREATE_RC" = 0 ]; then
    TICKET_ID=$(jq -r '.number // empty | tostring' "$GHW/resp" 2>/dev/null)
    TICKET_URL=$(jq -r '.html_url // empty' "$GHW/resp" 2>/dev/null)
  fi
  if ! [[ $TICKET_ID =~ ^[0-9]+$ ]]; then
    # Only a 4xx answer proves nothing was created; a lost answer may sit on an issue.
    case "$GH_REST_STATUS" in
      4??) [ "$ROW_RC" != 3 ] && { prow_put "$PROJECT" "$SLUG" "$LEDGER" "$PRE_ST" \
             || HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$PROJECT] post-proposal: $SLUG row left at posting after a refused create. PUT its row status $PRE_ST to approve again"; }
           HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$PROJECT] post-proposal: issue create failed for $SLUG on $GH_REPO (HTTP $GH_REST_STATUS; refused, nothing created)"; exit 1 ;;
      *)   HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$PROJECT] post-proposal: issue create for $SLUG on $GH_REPO has an unknown outcome (HTTP $GH_REST_STATUS ${GH_REST_REASON:-}) and it may exist: check $GH_REPO for its [Proposal] issue before approving again; the row stays posting (clear it with PUT status $PRE_ST)"; exit 1 ;;
    esac
  fi
  [ -n "$TICKET_URL" ] || TICKET_URL="https://github.com/$GH_REPO/issues/$TICKET_ID"
  jq --arg s "$SLUG" --arg now "$(NOWISO)" --arg tid "$TICKET_ID" --arg tkey "#$TICKET_ID" --arg turl "$TICKET_URL" '
    (.[] | select(.slug == $s)) |= (.status = "posted" | .updated_at = $now
      | .ticket_id = $tid | .ticket_key = $tkey | .ticket_url = $turl)' \
    "$LEDGER" > "$LEDGER.tmp" && mv "$LEDGER.tmp" "$LEDGER"
  [ "$ROW_RC" != 3 ] && { prow_put "$PROJECT" "$SLUG" "$LEDGER" \
    || HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$PROJECT] post-proposal: $SLUG posted as #$TICKET_ID but its row is still posting. PUT its row status posted"; }
  "$HARNESS/bin/beat.sh" "$(jq -nc --arg pkey "$PKEY" --arg p "$PROJECT" --arg slug "$SLUG" \
    --arg tkey "#$TICKET_ID" --arg turl "$TICKET_URL" \
    '{kind:"proposal",pkey:$pkey,project:$p,slug:$slug,status:"posted",ticket_key:$tkey,ticket_url:$turl}')"
  echo "$(STAMP) [$PROJECT] posted proposal $SLUG as $GH_REPO#$TICKET_ID"
  exit 0
fi

# 1. Board id (first board; override with <PREFIX>_PRODUCT_BOARD_ID if ever needed).
BOARD_ID=$(API "$BASE$BP/boards" | jq -r '(.boards? // .) | .[0].id // empty')
[ -n "$BOARD_ID" ] || { echo "$(STAMP) [$PROJECT] post-proposal: no board id" >> "$ALERTS"; exit 1; }

# 2. Create the ticket with the pre-mockup description ({{MOCKUP_BLOCK}} → placeholder).
DESC=$(sed 's/{{MOCKUP_BLOCK}}/<p><em>Mockup preview attached below.<\/em><\/p>/' "$IDIR/ticket.html")
# The claim, before the one call the client sees. Not landed = not sent.
if [ "$ROW_RC" != 3 ] && ! prow_put "$PROJECT" "$SLUG" "$LEDGER" posting; then
  echo "$(STAMP) [$PROJECT] post-proposal: $SLUG posting claim did not land in harness-jobs, not posting. Approve again once it answers" >> "$ALERTS"; exit 1
fi
# No -f here: the HTTP code is what tells a refusal from a lost answer.
CREATE_RAW=$(curl -s --max-time 30 -w '\n%{http_code}' -H "Authorization: Bearer $TOKEN" -H "User-Agent: curl/8" \
  -X POST -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg t "[Proposal] $TITLE" --arg d "$DESC" '{title:$t,description:$d,priority:"medium"}')" \
  "$BASE$BP/boards/$BOARD_ID/tickets"); CREATE_RC=$?
CREATE_CODE=$(printf '%s' "$CREATE_RAW" | tail -n 1)
CREATE=$(printf '%s' "$CREATE_RAW" | sed '$d')
TICKET_ID=""
[ "$CREATE_RC" = 0 ] && case "$CREATE_CODE" in 2??) TICKET_ID=$(jq -r '.id // empty' <<<"$CREATE" 2>/dev/null) ;; esac
if [ -z "$TICKET_ID" ]; then
  # The claim goes back ONLY when the board provably wrote nothing: curl never
  # reached it (rc 6 no DNS, rc 7 no connect) or it answered a 4xx. A timeout,
  # a 5xx or a 2xx with no id may sit on a ticket that was created, so the row
  # stays `posting` and the next approve alerts instead of posting again.
  REFUSED=false
  case "$CREATE_RC" in
    6|7) REFUSED=true ;;
    0) case "$CREATE_CODE" in 4??) REFUSED=true ;; esac ;;
  esac
  if [ "$REFUSED" = true ]; then
    [ "$ROW_RC" != 3 ] && { prow_put "$PROJECT" "$SLUG" "$LEDGER" "$PRE_ST" \
      || echo "$(STAMP) [$PROJECT] post-proposal: $SLUG row left at posting after a refused create. PUT its row status $PRE_ST to approve again" >> "$ALERTS"; }
    echo "$(STAMP) [$PROJECT] post-proposal: ticket create failed for $SLUG (curl rc $CREATE_RC, HTTP $CREATE_CODE; refused, nothing created)" >> "$ALERTS"; exit 1
  fi
  HOLD="the row stays posting (clear it with PUT status $PRE_ST)"
  [ "$ROW_RC" = 3 ] && HOLD="no proposal row here (JOBS_URL empty), so nothing holds a re-approve back"
  echo "$(STAMP) [$PROJECT] post-proposal: ticket create for $SLUG has an unknown outcome (curl rc $CREATE_RC, HTTP $CREATE_CODE) and it may exist: check the board for its [Proposal] ticket before approving again; $HOLD" >> "$ALERTS"; exit 1
fi
# The ticket exists: stamp that before anything below can fail. Attachments,
# the description update and the turn are best-effort.
TICKET_URL="$BASE$UIP?ticket=$TICKET_ID"
jq --arg s "$SLUG" --arg now "$(NOWISO)" --arg tid "$TICKET_ID" --arg turl "$TICKET_URL" '
  (.[] | select(.slug == $s)) |= (.status = "posted" | .updated_at = $now | .ticket_id = $tid | .ticket_url = $turl)' \
  "$LEDGER" > "$LEDGER.tmp" && mv "$LEDGER.tmp" "$LEDGER"
[ "$ROW_RC" != 3 ] && { prow_put "$PROJECT" "$SLUG" "$LEDGER" \
  || echo "$(STAMP) [$PROJECT] post-proposal: $SLUG posted as $TICKET_ID but its row is still posting. PUT its row status posted" >> "$ALERTS"; }
# Create-response shapes differ per app (project-2/project-1: {id,tickets}; project-3/project-4
# have leaner shapes) — fall back to fetching the ticket detail for the number.
TICKET_NUM=$(jq -r --arg id "$TICKET_ID" '(.tickets? // []) | .[]? | select(.id == $id) | .number // empty' <<<"$CREATE" 2>/dev/null)
[ -n "$TICKET_NUM" ] || TICKET_NUM=$(API "$BASE$BP/tickets/$TICKET_ID" | jq -r '.number // .ticket.number // empty' 2>/dev/null)
TICKET_KEY=""; [ -n "$TICKET_NUM" ] && TICKET_KEY="$KEYPFX-$TICKET_NUM"

# 3. Upload attachments (sign → PUT direct-to-storage → finalize) and collect ids.
upload() { # upload <file> <mime> -> attachment id on stdout
  local FILE="$1" MIME="$2" NAME SIGN URL FIN
  NAME=$(basename "$FILE")
  SIGN=$(API -X POST -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg f "$NAME" --arg ct "$MIME" --argjson sz "$(stat -c%s "$FILE")" '{fileName:$f,contentType:$ct,sizeBytes:$sz}')" \
    "$BASE$BP/tickets/$TICKET_ID/attachments/sign") || return 1
  URL=$(jq -r '.signedUrl // empty' <<<"$SIGN"); local SPATH; SPATH=$(jq -r '.path // empty' <<<"$SIGN")
  [ -n "$URL" ] && [ -n "$SPATH" ] || return 1
  curl -sf --max-time 60 -X PUT -H "Content-Type: $MIME" --data-binary @"$FILE" "$URL" >/dev/null || return 1
  FIN=$(API -X POST -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg p "$SPATH" --arg f "$NAME" --arg m "$MIME" --argjson sz "$(stat -c%s "$FILE")" '{path:$p,fileName:$f,mimeType:$m,sizeBytes:$sz}')" \
    "$BASE$BP/tickets/$TICKET_ID/attachments") || return 1
  jq -r --arg f "$NAME" '(.attachments // []) | map(select(.fileName == $f)) | last | .id // empty' <<<"$FIN"
}

MOCKUP_ATT=$(upload "$IDIR/mockup.html" "text/html") || MOCKUP_ATT=""
DESK_ATT=""; MOB_ATT=""
[ -s "$IDIR/desktop.png" ] && DESK_ATT=$(upload "$IDIR/desktop.png" "image/png") || true
[ -s "$IDIR/mobile.png" ] && MOB_ATT=$(upload "$IDIR/mobile.png" "image/png") || true

# 4. Inject the real mockup block (live viewer link + inline previews) and update.
MOCKUP_URL=""
if [ -n "$MOCKUP_ATT" ]; then
  MOCKUP_URL="$BASE$UIP/mockups/$MOCKUP_ATT"
  BLOCK="<h3>See it before we build it</h3><p><a href=\"$MOCKUP_URL\"><strong>Open the interactive mockup</strong></a> (opens in the app, sign-in required).</p>"
  [ -n "$DESK_ATT" ] && BLOCK="$BLOCK<p><img src=\"$BASE$UIP/mockups/$DESK_ATT/raw\" alt=\"Desktop preview\" /></p>"
  [ -n "$MOB_ATT" ] && BLOCK="$BLOCK<p><img src=\"$BASE$UIP/mockups/$MOB_ATT/raw\" alt=\"Mobile preview\" /></p>"
  DESC2=$(sed "s|{{MOCKUP_BLOCK}}|$(printf '%s' "$BLOCK" | sed 's/[&|\\]/\\&/g')|" "$IDIR/ticket.html")
  API -X PATCH -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg d "$DESC2" '{description:$d}')" "$BASE$BP/tickets/$TICKET_ID" >/dev/null \
    || echo "$(STAMP) [$PROJECT] post-proposal: description update failed for $SLUG (placeholder remains)" >> "$ALERTS"
else
  echo "$(STAMP) [$PROJECT] post-proposal: mockup upload failed for $SLUG — posted without live link" >> "$ALERTS"
fi

# 5. Ball to the client.
API -X POST -H 'Content-Type: application/json' -d "{\"to\":\"$SIDE\"}" "$BASE$BP/tickets/$TICKET_ID/turn" >/dev/null || true

# 6. Ledger + beat.
jq --arg s "$SLUG" --arg now "$(NOWISO)" --arg tid "$TICKET_ID" \
   --arg tkey "${TICKET_KEY:-}" --arg turl "$TICKET_URL" --arg murl "$MOCKUP_URL" '
  (.[] | select(.slug == $s)) |= (.status = "posted" | .updated_at = $now
    | .ticket_id = $tid | .ticket_key = $tkey | .ticket_url = $turl | .mockup_url = $murl)' \
  "$LEDGER" > "$LEDGER.tmp" && mv "$LEDGER.tmp" "$LEDGER"
[ "$ROW_RC" != 3 ] && { prow_put "$PROJECT" "$SLUG" "$LEDGER" || true; }

"$HARNESS/bin/beat.sh" "$(jq -nc --arg pkey "$PKEY" --arg p "$PROJECT" --arg slug "$SLUG" \
  --arg tkey "${TICKET_KEY:-}" --arg turl "$TICKET_URL" --arg murl "$MOCKUP_URL" \
  '{kind:"proposal",pkey:$pkey,project:$p,slug:$slug,status:"posted",ticket_key:$tkey,ticket_url:$turl,mockup_url:$murl}')"
echo "$(STAMP) [$PROJECT] posted proposal $SLUG as ${TICKET_KEY:-$TICKET_ID}"
exit 0
