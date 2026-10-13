#!/bin/bash
# product-cmd.sh <project> <type> <slug> [notes-b64] — execute a gate decision
# from the console/Telegram command queue (via poll-commands.sh).
#   post_proposal   -> post to the client board (post-proposal.sh)
#   kill_proposal   -> ledger status=vetoed (+notes), beat
#   revise_proposal -> one LLM pass applying the operator's notes to PRD+mockup, re-shot, re-gate
set -uo pipefail
PROJECT="${1:?usage: product-cmd.sh <project> <type> <slug> [notes-b64]}"
TYPE="${2:?type}"
SLUG="${3:?slug}"
NOTES_B64="${4:-}"
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
ALERTS="$HARNESS/logs/ALERTS.log"
LEDGER="$HARNESS/state/product-$PROJECT.ledger.json"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

set -a
[ -f "$HENV/global.env" ] && . "$HENV/global.env"
[ -f "$HENV/$PROJECT.env" ] && . "$HENV/$PROJECT.env"
set +a

# >>> proposal rows (BH-2531): the ledger file is this box's working copy;
# harness-jobs product_proposals rows are the record that outlives it. Restored
# before the ledger is read, written through after each ledger write. Fail-open:
# no worker, or one that does not answer, leaves the file exactly as before.
# shellcheck source=bin/jobs-client.sh
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"
# shellcheck source=bin/lib/proposal-rows.sh
[ -r "$HARNESS/bin/lib/proposal-rows.sh" ] && . "$HARNESS/bin/lib/proposal-rows.sh"
command -v prow_put >/dev/null 2>&1 || { prow_put() { return 1; }; prow_restore() { return 1; }; }
# <<< proposal rows
# The map write-back never reads the ledger; everything else restores first,
# so a wiped box answers kill/revise/chat from the rows, not "no ledger".
[ "$TYPE" = update_company_map ] || prow_restore "$PROJECT" "$LEDGER" || true

# Idea chat: one conversational turn about a proposal. 4th arg = b64 of
# JSON {message, origin}. Full-context session on the owning box; reply beats
# back to the cockpit (kind=proposal_chat); an IDEA_UPDATE line evolves the
# ledger record + re-beats the proposal.
if [ "$TYPE" = "chat_proposal" ]; then
  MSG_JSON=$(base64 -d <<<"${4:-}" 2>/dev/null || echo '{}')
  MESSAGE=$(jq -r '.message // ""' <<<"$MSG_JSON")
  ORIGIN=$(jq -r '.origin // "dash"' <<<"$MSG_JSON")
  [ -n "$MESSAGE" ] || { echo "$(STAMP) [$PROJECT] product-cmd: chat with empty message" >> "$ALERTS"; exit 1; }
  [ -f "$LEDGER" ] || { echo "$(STAMP) [$PROJECT] product-cmd: chat but no ledger" >> "$ALERTS"; exit 1; }
  ROW=$(jq -c --arg s "$SLUG" '[.[] | select(.slug == $s)] | last // empty' "$LEDGER")
  [ -n "$ROW" ] || { echo "$(STAMP) [$PROJECT] product-cmd: chat unknown slug $SLUG" >> "$ALERTS"; exit 1; }
  PKEY="prop:$PROJECT:$SLUG"
  CHATDIR="$HARNESS/state/product-$PROJECT.chats"; mkdir -p "$CHATDIR"
  HISTORY="$CHATDIR/$SLUG.jsonl"
  jq -nc --arg r user --arg b "$MESSAGE" --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{role:$r,body:$b,ts:$ts}' >> "$HISTORY"

  IDIR=$(jq -r '.dir // empty' <<<"$ROW")
  PRD_PATH=""; [ -n "$IDIR" ] && [ -s "$IDIR/prd.md" ] && PRD_PATH="$IDIR/prd.md"
  # Latest cycle's signals, if any exist.
  SIG_PATH=$(ls -t "$HARNESS/products/$PROJECT"/*/signals.json 2>/dev/null | head -1)
  ROW_FILE="$CHATDIR/$SLUG.idea.json"; printf '%s' "$ROW" > "$ROW_FILE"

  # >>> model-route (BH-1510.2): model_routes role `product` (IDEA_CHAT_MODEL
  # still wins when set). No route = rc 75, no session bought; the role is
  # alerted by bin/lib/model-route.sh, this line names the idea.
  . "$HARNESS/bin/lib/lane-model.sh"
  CHAT_MODEL=$(lane_model IDEA_CHAT_MODEL product "$PROJECT") \
    || { echo "$(STAMP) [$PROJECT] product-cmd: no model route for role product — chat for $SLUG not answered" >> "$ALERTS"; exit 75; }
  # <<< model-route
  REPLY_OUT="$CHATDIR/$SLUG.reply.md"
  RT="RUNTIME CONTEXT
IDEA_JSON=$ROW_FILE
HISTORY=$HISTORY   (last user line is the message to answer)
REPLY_OUT=$REPLY_OUT   (write the reply HERE)
MAP=$HARNESS/state/$PROJECT.company-map.md
SIGNALS=${SIG_PATH:-none}
CATALOG=$HARNESS/catalog/feature-catalog.md
PRD=${PRD_PATH:-none}
REPO=/root/repos/$PROJECT"
  PROMPT="$(cat "$HARNESS/prompts/product-stages/chat.md")

$(cat "$HARNESS/prompts/product-$PROJECT.md")

$RT"
  # Lane stage-chat, the lane this call has always resolved to (BH-2603): the
  # registry lane box-chat carries stage chat too, and switching the chat pane
  # off must not stop proposal chats.
  AGENT_CALL_LANE=stage-chat "$HARNESS/bin/agent-call.sh" chat "$PROJECT" "$CHAT_MODEL" 1800 "$CHATDIR/$SLUG.out.txt" "$PROMPT"
  RC=$?
  if [ $RC -ne 0 ] || [ ! -s "$REPLY_OUT" ]; then
    echo "$(STAMP) [$PROJECT] product-cmd: chat session failed for $SLUG rc=$RC" >> "$ALERTS"; exit 1
  fi

  REPLY=$(cat "$REPLY_OUT")
  jq -nc --arg r assistant --arg b "$REPLY" --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{role:$r,body:$b,ts:$ts}' >> "$HISTORY"

  # Apply an IDEA_UPDATE patch, if the session emitted one (allowlisted fields only).
  PATCH=$(grep '^IDEA_UPDATE: ' "$CHATDIR/$SLUG.out.txt" | tail -1 | sed 's/^IDEA_UPDATE: //')
  UPDATED=false
  if [ -n "$PATCH" ] && jq -e . >/dev/null 2>&1 <<<"$PATCH"; then
    SAFE=$(jq -c '{title,summary,impact,effort,confidence,dus,dus_why,aaa,prd_notes} | with_entries(select(.value != null))' <<<"$PATCH")
    if [ "$(jq 'length' <<<"$SAFE")" -gt 0 ]; then
      jq --arg s "$SLUG" --argjson p "$SAFE" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
        (.[] | select(.slug == $s)) |= (. + $p
          | .score = ((.impact * .confidence / (if (.effort // 1) < 0.5 then 0.5 else .effort end)) * 10 | round / 10)
          | .updated_at = $now)' \
        "$LEDGER" > "$LEDGER.tmp" && mv "$LEDGER.tmp" "$LEDGER"
      prow_put "$PROJECT" "$SLUG" "$LEDGER" || true
      UPDATED=true
      NEWROW=$(jq -c --arg s "$SLUG" '[.[] | select(.slug == $s)] | last' "$LEDGER")
      "$HARNESS/bin/beat.sh" "$(jq -nc --arg pkey "$PKEY" --arg p "$PROJECT" --argjson i "$NEWROW" \
        '{kind:"proposal",pkey:$pkey,project:$p,slug:$i.slug,title:$i.title,summary:$i.summary,
          impact:$i.impact,effort:$i.effort,confidence:$i.confidence,score:$i.score,
          dus:($i.dus // ""),dus_why:($i.dus_why // ""),aaa:($i.aaa // ""),
          department:($i.department // ""),status:$i.status,rev:($i.rev // 1)}')"
    fi
  fi

  # Reply beat -> cockpit thread (temp-file transport; replies can be sizable).
  head -c 12000 "$REPLY_OUT" > "$REPLY_OUT.trunc"
  jq -nc --arg pkey "$PKEY" --arg p "$PROJECT" --arg slug "$SLUG" --arg o "$ORIGIN" \
     --argjson u "$UPDATED" --rawfile b "$REPLY_OUT.trunc" \
     '{kind:"proposal_chat",pkey:$pkey,project:$p,slug:$slug,role:"assistant",body:$b,origin:$o,idea_updated:$u}' \
     > "$REPLY_OUT.payload"
  "$HARNESS/bin/beat.sh" "$(cat "$REPLY_OUT.payload")"
  rm -f "$REPLY_OUT.trunc" "$REPLY_OUT.payload" "$ROW_FILE"
  echo "chat reply sent for $SLUG${UPDATED:+ (idea updated)}"
  exit 0
fi

# Company-map write-back arrives with a FILE PATH as the 4th arg (not notes-b64):
# the payload rides a temp file end-to-end to dodge the 128KB argv limit.
if [ "$TYPE" = "update_company_map" ]; then
  SRC="${NOTES_B64:-}"
  MAPF="$HARNESS/state/$PROJECT.company-map.md"
  [ -s "$SRC" ] || { echo "$(STAMP) [$PROJECT] product-cmd: map update but no source file" >> "$ALERTS"; exit 1; }
  grep -q '^departments:' "$SRC" || { echo "$(STAMP) [$PROJECT] product-cmd: map update rejected (no departments frontmatter)" >> "$ALERTS"; exit 1; }
  mv "$SRC" "$MAPF"
  head -c 65536 "$MAPF" > "$MAPF.beat.tmp"
  jq -nc --arg p "$PROJECT" --rawfile m "$MAPF.beat.tmp" '{kind:"company_map",project:$p,content:$m}' > "$MAPF.payload.tmp"
  "$HARNESS/bin/beat.sh" "$(cat "$MAPF.payload.tmp")"
  rm -f "$MAPF.beat.tmp" "$MAPF.payload.tmp"
  echo "company map updated ($(wc -c < "$MAPF") bytes)"
  exit 0
fi

[ -f "$LEDGER" ] || { echo "$(STAMP) [$PROJECT] product-cmd: no ledger" >> "$ALERTS"; exit 1; }
NOTES=""
[ -n "$NOTES_B64" ] && NOTES=$(base64 -d <<<"$NOTES_B64" 2>/dev/null || true)
PKEY="prop:$PROJECT:$SLUG"

ROW=$(jq -c --arg s "$SLUG" '[.[] | select(.slug == $s)] | last // empty' "$LEDGER")
[ -n "$ROW" ] || { echo "$(STAMP) [$PROJECT] product-cmd: unknown slug $SLUG" >> "$ALERTS"; exit 1; }
IDIR=$(jq -r '.dir // empty' <<<"$ROW")
REV=$(jq -r '.rev // 1' <<<"$ROW")

ledger_update() { # ledger_update <status> [notes]
  jq --arg s "$SLUG" --arg st "$1" --arg n "${2:-}" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
    (.[] | select(.slug == $s)) |= (.status = $st | .updated_at = $now
      | (if $n != "" then .notes = $n else . end))' \
    "$LEDGER" > "$LEDGER.tmp" && mv "$LEDGER.tmp" "$LEDGER"
  prow_put "$PROJECT" "$SLUG" "$LEDGER" || true
}

case "$TYPE" in
  post_proposal)
    exec "$HARNESS/bin/post-proposal.sh" "$PROJECT" "$SLUG"
    ;;
  kill_proposal)
    ledger_update vetoed "$NOTES"
    "$HARNESS/bin/beat.sh" "$(jq -nc --arg pkey "$PKEY" --arg p "$PROJECT" --arg slug "$SLUG" --arg n "$NOTES" \
      '{kind:"proposal",pkey:$pkey,project:$p,slug:$slug,status:"vetoed",notes:$n}')"
    echo "vetoed $SLUG"
    ;;
  revise_proposal)
    NEWREV=$((REV + 1))
    # A resurrected CANDIDATE was never drafted (its ledger dir is the cycle dir,
    # no prd.md). Draft it fresh from the ledger row via the shared script.
    if [ ! -s "$IDIR/prd.md" ]; then
      NDIR="$IDIR/$SLUG"; mkdir -p "$NDIR"
      jq -c --arg s "$SLUG" '[.[] | select(.slug == $s)] | last' "$LEDGER" > "$NDIR/idea.json"
      [ -n "$NOTES" ] && jq --arg n "$NOTES" '. + {owner_notes: $n}' "$NDIR/idea.json" > "$NDIR/idea.json.tmp" \
        && mv "$NDIR/idea.json.tmp" "$NDIR/idea.json"
      if ! "$HARNESS/bin/draft-proposal.sh" "$PROJECT" "$NDIR"; then
        echo "$(STAMP) [$PROJECT] product-cmd: fresh draft failed for $SLUG" >> "$ALERTS"; exit 1
      fi
      IDIR="$NDIR"
      jq --arg s "$SLUG" --arg d "$NDIR" '(.[] | select(.slug == $s)) |= (.dir = $d)' \
        "$LEDGER" > "$LEDGER.tmp" && mv "$LEDGER.tmp" "$LEDGER"
      prow_put "$PROJECT" "$SLUG" "$LEDGER" || true
    else
      # >>> model-route (BH-1510.2): model_routes role `product.revise`
      # (REVISE_MODEL still wins when set); no route = rc 75, nothing bought.
      . "$HARNESS/bin/lib/lane-model.sh"
      REVISE_MODEL=$(lane_model REVISE_MODEL product.revise "$PROJECT") \
        || { echo "$(STAMP) [$PROJECT] product-cmd: no model route for role product.revise — $SLUG not revised" >> "$ALERTS"; exit 75; }
      # <<< model-route
      REVISE_PROMPT="Revise a feature-proposal package per the owner's notes. Idea: $(cat "$IDIR/idea.json")
OWNER'S NOTES (apply these — they override anything in the current draft): $NOTES
Files to revise IN PLACE under $IDIR: prd.md (internal PRD), ticket.html (client-facing description; keep the literal {{MOCKUP_BLOCK}} token intact on its own line; sanitized-HTML-safe tags only; De-AI voice, under 6000 chars), mockup.html (self-contained, themed from the app repo at /root/repos/$PROJECT, responsive 1280+375, MOCKUP banner, fake data, no external assets).
Only change what the notes require; keep everything else stable. Do not modify any repo files. Final line: REVISE_DONE or REVISE_FAILED <reason>."
      "$HARNESS/bin/agent-call.sh" revise "$PROJECT" "$REVISE_MODEL" 2400 "$IDIR/revise-r$NEWREV.out.txt" "$REVISE_PROMPT"
      RC=$?
      [ $RC -eq 0 ] || { echo "$(STAMP) [$PROJECT] product-cmd: revise LLM failed for $SLUG rc=$RC" >> "$ALERTS"; exit 1; }
      "$HARNESS/bin/mockup-shot.sh" "$IDIR" 2>>"$ALERTS" || true
      "$HARNESS/bin/push-proposal-assets.sh" "$PKEY" "$IDIR" 2>>"$ALERTS" || true
    fi
    jq --arg s "$SLUG" --arg n "$NOTES" --argjson r "$NEWREV" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
      (.[] | select(.slug == $s)) |= (.status = "gate_pending" | .rev = $r | .notes = $n | .updated_at = $now)' \
      "$LEDGER" > "$LEDGER.tmp" && mv "$LEDGER.tmp" "$LEDGER"
    prow_put "$PROJECT" "$SLUG" "$LEDGER" || true
    "$HARNESS/bin/beat.sh" "$(jq -nc --arg pkey "$PKEY" --arg p "$PROJECT" --arg slug "$SLUG" --argjson r "$NEWREV" \
      --arg detail "$(head -c 7000 "$IDIR/prd.md")" \
      '{kind:"proposal",pkey:$pkey,project:$p,slug:$slug,status:"gate_pending",rev:$r,detail:$detail}')"
    echo "revised $SLUG -> rev $NEWREV"
    ;;
  *)
    echo "$(STAMP) [$PROJECT] product-cmd: unknown type $TYPE" >> "$ALERTS"; exit 1 ;;
esac
exit 0
