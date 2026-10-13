#!/bin/bash
# gh-identity: app-token
# bin/lib/steer-deliver.sh — BH-5839: the hub delivers the ticket page's
# "Add to the ticket" and "Hold, then tell it" notes. Sourced by
# bin/poll-commands.sh (its `# >>> steer outbox (BH-5839)` block, every tick on
# the box that holds the hub lease); defines functions only.
#
#   steer_deliver_tick
#     Reads GET /api/steer/outbox. Per note it claims the note first
#     (POST /api/steer/<id>/claim; a 409 means another box has it, so skip),
#     delivers it, then reports it with POST /api/steer/<id>/delivered
#     {ok, detail}. The worker owns the page size (settings row
#     steer.outbox_limit). rc 0 always: an outbox that cannot be read is tried
#     again next tick, and the worker counts a not-ok report toward its attempt
#     cap (settings row steer.attempts_max, then the note is failed).
#
#   ticket  ONE issue comment, as the App, naming who sent it. The plan stage
#           reads the whole thread, so later stages see it.
#   hold    bin/lib/ticket-hold-cmd.sh's thc_run hold with the note as the
#           reason: the hold label plus one App comment that carries the note.
#           When the label was already on, thc_run posts nothing, so the note is
#           posted here. A hold whose comment was not posted is a not-ok report:
#           the label alone does not show the note to anyone. The build the note
#           was sent to stops at its own next step boundary (bin/lib/steer.sh).
#
# ONE COMMENT PER NOTE. Each comment this file posts ends with the marker
# <!-- steer-note:<id> -->. Before a post, the issue's comments are read: a
# comment with the marker (or thc_run's "Held from Mission Control by <actor>:
# <note>." for a hold) means the note is already there, so a re-delivery after
# a lost report posts nothing. If the comments cannot be read, nothing is
# posted and the report is not ok.
#
# NEVER ON THE PAT. A PAT comment is a person's comment to hold_classify, and an
# operator's note can carry hold or lift words. No App token is a not-ok report.

_sd_log() {
  local root="${HARNESS:-${H:-}}"
  [ -n "$root" ] || return 0
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [steer-deliver] $*" >> "$root/logs/steer.log" 2>/dev/null
}

# _sd_target <project> <ticket> — prints "<slug> <n>" for a GitHub-issues board.
# rc 0 ok, 1 a read failed (retry), 3 refused.
_sd_target() {
  local project="$1" ticket="$2" pjs slug bp root="${HARNESS:-${H:-}}"
  [ -n "$root" ] || return 1
  [[ "$project" =~ ^[A-Za-z0-9._-]+$ ]] || return 3
  [[ "$ticket" =~ ^[A-Za-z][A-Za-z0-9]*-([1-9][0-9]*)$ ]] || return 3
  local n="${BASH_REMATCH[1]}"
  pjs=$("$root/bin/fleet-conf.sh" --projects 2>/dev/null) && [ -n "${pjs//[[:space:]]/}" ] || return 1
  grep -qxF -- "$project" <<<"$pjs" || return 3
  slug=$("$root/bin/fleet-conf.sh" "$project" repo 2>/dev/null) || return 1
  bp=$("$root/bin/fleet-conf.sh" "$project" board_prefix 2>/dev/null) || return 1
  [ "$bp" = "-" ] && [[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 3
  printf '%s %s\n' "$slug" "$n"
}

# _sd_comment <slug> <n> <text> — one comment as the App. Prints the reason on
# failure. rc 0 posted, 1 not. Only a token gh_auth_for just minted for this
# repo counts: an App token already in the environment is not this repo's.
_sd_comment() {
  local slug="$1" n="$2" text="$3" errf rc=1 minted=0
  command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$slug" && minted=1
  case "$minted:${GH_TOKEN:-}" in
    1:ghs_*)
      errf=$(mktemp) || { echo "no temp file"; command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset; return 1; }
      if jq -nc --arg b "$text" '{body:$b}' | gh api -X POST "repos/$slug/issues/$n/comments" --input - >/dev/null 2>"$errf"; then
        rc=0
      else
        echo "comment not posted: $(head -n 1 "$errf" | tr -d '\r\t' | cut -c1-200)"
      fi
      rm -f "$errf" ;;
    *) echo "comment not posted: no App token for $slug" ;;
  esac
  command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
  return "$rc"
}

# _sd_posted <slug> <n> <id> [prefix] — rc 0 when a comment on the issue
# carries the note's marker or starts with prefix, 1 when none does, 2 when the
# comments could not be read.
_sd_posted() {
  local slug="$1" n="$2" id="$3" prefix="${4:-}" pages
  pages=$(gh api --paginate "repos/$slug/issues/$n/comments?per_page=100" 2>/dev/null) || return 2
  jq -se --arg m "<!-- steer-note:$id -->" --arg p "$prefix" \
    '[.[] | if type == "array" then .[] else empty end | (.body // "")
      | select(contains($m) or ($p != "" and startswith($p)))] | length > 0' >/dev/null 2>&1 <<<"$pages"
  case $? in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}

# _sd_one <note-json> — delivers one note; prints the detail line. rc 0 ok.
_sd_one() {
  local note="$1" project ticket mode text actor tgt rc slug n res payload cr id mark held
  project=$(jq -r '.project // ""' <<<"$note"); ticket=$(jq -r '.ticket // ""' <<<"$note")
  mode=$(jq -r '.mode // ""' <<<"$note"); text=$(jq -r '.text // ""' <<<"$note")
  actor=$(jq -r '.actor // "console"' <<<"$note"); id=$(jq -r '.id // ""' <<<"$note")
  mark=$'\n\n'"<!-- steer-note:$id -->"
  tgt=$(_sd_target "$project" "$ticket"); rc=$?
  case "$rc" in
    0) ;;
    3) echo "refused: $project $ticket is not a ticket on a GitHub-issues board"; return 1 ;;
    *) echo "fleet-conf could not be read; retry"; return 1 ;;
  esac
  slug=${tgt% *}; n=${tgt#* }
  case "$mode" in
    ticket)
      _sd_posted "$slug" "$n" "$id"; rc=$?
      case "$rc" in
        0) echo "comment already on $slug#$n"; return 0 ;;
        2) echo "comment not posted: the comments on $slug#$n could not be read"; return 1 ;;
      esac
      _sd_comment "$slug" "$n" "Note from $actor, sent from Mission Control:"$'\n\n'"$text$mark" || return 1
      echo "comment posted on $slug#$n" ;;
    hold)
      command -v thc_run >/dev/null 2>&1 || { echo "hold not set: bin/lib/ticket-hold-cmd.sh not loaded"; return 1; }
      # Read before the hold: a first delivery whose report was lost already
      # left thc_run's comment (or this file's) on the issue.
      # thc_run writes "console" for an actor outside its pattern.
      local ta="$actor"; [[ "$ta" =~ ^[A-Za-z0-9._@-]{1,96}$ ]] || ta=console
      _sd_posted "$slug" "$n" "$id" "Held from Mission Control by $ta: $text. "; held=$?
      [ "$held" = 2 ] && { echo "hold not set: the comments on $slug#$n could not be read"; return 1; }
      payload=$(jq -nc --arg t "$ticket" --arg r "$text" --arg a "$actor" '{ticket:$t,reason:$r,actor:$a}')
      res=$(thc_run hold "$project" "$payload"); rc=$?
      [ "$rc" = 0 ] || { echo "hold not set: $res"; return 1; }
      if [ "$held" = 0 ]; then echo "$res; the note was already on $slug#$n"; return 0; fi
      # thc_run comments only when it added the label, and only on the App
      # token. A ticket already held still gets the note, once. A label with
      # no comment is not delivered: nobody sees the note.
      case "$res" in
        "already held"*)
          cr=$(_sd_comment "$slug" "$n" "Note from $actor while this ticket is held, sent from Mission Control:"$'\n\n'"$text$mark") \
            || { echo "$res; $cr"; return 1; } ;;
        *"comment not posted"*) echo "$res"; return 1 ;;
      esac
      echo "$res" ;;
    *) echo "refused: mode $mode is not delivered by the hub"; return 1 ;;
  esac
}

steer_deliver_tick() {
  local box note id detail ok body
  command -v _jobs_req >/dev/null 2>&1 || return 0
  if ! box=$(_jobs_req GET /api/steer/outbox 2>/dev/null) || [ -z "$box" ]; then
    _sd_log "outbox not read (http=${JOBS_HTTP:-none}); next tick"
    return 0
  fi
  while IFS= read -r note; do
    [ -n "$note" ] || continue
    id=$(jq -r '.id // ""' <<<"$note"); [[ "$id" =~ ^[0-9]+$ ]] || continue
    # The claim is the one-box guarantee: of two boxes on one outbox page, only
    # the one the worker answers 200 posts. Anything else is skipped this tick.
    if ! JOBS_RETRIES=0 _jobs_req POST "/api/steer/$id/claim" '{}' >/dev/null 2>&1; then
      _sd_log "note #$id: not claimed (http=${JOBS_HTTP:-none}); skipped"
      continue
    fi
    if detail=$(_sd_one "$note"); then ok=true; else ok=false; fi
    detail=$(printf '%s' "$detail" | tail -n 1)
    _sd_log "note #$id $(jq -r '"\(.mode) \(.project) \(.ticket)"' <<<"$note"): ok=$ok $detail"
    body=$(jq -nc --argjson ok "$ok" --arg d "$detail" '{ok:$ok,detail:$d}')
    _jobs_req POST "/api/steer/$id/delivered" "$body" >/dev/null 2>&1 \
      || _sd_log "note #$id: the delivered report was not taken (http=${JOBS_HTTP:-none})"
  done < <(jq -c '.notes[]?' <<<"$box" 2>/dev/null)
  return 0
}
