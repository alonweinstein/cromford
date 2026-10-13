#!/bin/bash
# bin/lib/reconcile-read.sh — BH-1583: how bin/reconcile-prs.sh learns what
# GitHub says about the PRs the console still calls unmerged, for ~1 call per
# repo per tick instead of one per PR per box. Sourced, never executed. No side
# effect at source time.
#
# WHY (gh-reads audit, 2026-09-23). The hub App bucket (installation 161623167)
# ran ~5,300 core calls/h of 6,600 and reconcile-prs was its biggest reader:
# the lane ran on the hub AND all 8 boxes, every copy read the same fleet-wide
# /api/builds/unmerged list (~46 PRs) and then made one GET pulls/<n> per PR,
# plus a second one for each merged PR's merge sha — 46 x 6 ticks x 9 copies.
#
# THE THREE CHANGES.
#   1. ONE BOX. rcr_owner_skip: the lane runs only on the box the settings row
#      lane.reconcile-prs.reconcile_prs_owner names (registry default `hub`,
#      resolved through bin/lib/hub-box.sh, never `hostname`). Every other box
#      exits before it reads the console or GitHub, saying so ONCE per owner
#      value in logs/reconcile.log.
#   2. ONE LIST PER REPO. rcr_fetch_pages reads
#      pulls?state=closed&sort=updated&direction=desc&per_page=<page> once per
#      repo through gh_rest (ledgered, ETag-conditional). A tracked PR on that
#      page is answered from it — merge fact, closed_at and merge sha included,
#      so the merged arm's second read is gone too.
#   3. A 404 REPO IS BACKED OFF (rcr_gone_*): recorded once, not read again for
#      RECONCILE_PRS_GONE_BACKOFF_S, and none of its PRs is read either.
#
# A TRACKED PR THAT IS NOT ON THE PAGE is OPEN or closed LONG ago. Which one is
# proved, not guessed, from GitHub's own clock:
#   - a page SHORTER than per_page holds every closed PR in the repo, so absent
#     means open;
#   - closing a PR bumps its updated_at, so a PR known open as of T that closes
#     later has updated_at > T. If the page's oldest updated_at (the cutoff) is
#     < T, such a PR would be ON the page — so absent means still open.
#   The "open as of" watermark lives in state/reconcile-prs/open/<pr> and only
#   ever moves to a timestamp GitHub printed (a PR's updated_at, the page's
#   newest), both of which are <= the moment of the read that proved it.
# Anything still unproved gets ONE per-PR read (mc_pr_view, the lane's old
# read), at most RECONCILE_PRS_FALLBACK_CAP of them per tick; the rest wait for
# the next tick and the tick says how many. A read that FAILS is backed off for
# RECONCILE_PRS_READ_FAIL_BACKOFF_S, so a PR that keeps failing cannot hold a
# cap slot every tick and starve the others. A settled CLOSED or MERGED answer
# is remembered in state/reconcile-prs/terminal/<pr> so a closed-unmerged row
# the console keeps listing does not cost a read every tick once it falls off
# the page — but it NEVER outranks this tick's page (rcr_pr_state's order):
# MERGED is final, CLOSED is honoured only while the page agrees with it.
#
# THE KNOBS are registry knobs of the reconcile-prs lane (catalog/lanes.d,
# `required: true`), put into the environment by lane_env_apply: settings row >
# cached row > env > registry default. There is no literal for any of them
# here; a value that is missing or not a number stops the tick (rcr_knobs_ok),
# the same fail-closed answer lane-gate gives a required knob with no default.

_rcr_h()    { printf '%s' "${HARNESS:-/root/harness}"; }
rcr_dir()   { printf '%s/state/reconcile-prs' "$(_rcr_h)"; }
_rcr_name() { printf '%s' "${1:-}" | tr -c 'A-Za-z0-9._-' '_'; }
_rcr_log()  { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') $*" >> "$(_rcr_h)/logs/reconcile.log"; }
_rcr_int()  { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; }
# _rcr_slug_of / _rcr_num_of <pr-url> — the same parse the lane has always used.
_rcr_slug_of() { sed -nE 's|^https://github.com/([^/]+/[^/]+)/pull/[0-9]+.*$|\1|p' <<<"${1:-}"; }
_rcr_num_of()  { sed -nE 's|^https://github.com/[^/]+/[^/]+/pull/([0-9]+).*$|\1|p' <<<"${1:-}"; }

# rcr_knobs_ok — rc 0 when every knob this file reads is a usable value.
rcr_knobs_ok() {
  local bad=""
  [ -n "$(_rcr_clean "${RECONCILE_PRS_OWNER:-}")" ] || bad="$bad RECONCILE_PRS_OWNER"
  _rcr_int "${RECONCILE_PRS_PAGE:-}" && [ "$RECONCILE_PRS_PAGE" -ge 1 ] || bad="$bad RECONCILE_PRS_PAGE"
  _rcr_int "${RECONCILE_PRS_FALLBACK_CAP:-}" || bad="$bad RECONCILE_PRS_FALLBACK_CAP"
  _rcr_int "${RECONCILE_PRS_GONE_BACKOFF_S:-}" || bad="$bad RECONCILE_PRS_GONE_BACKOFF_S"
  _rcr_int "${RECONCILE_PRS_READ_FAIL_BACKOFF_S:-}" || bad="$bad RECONCILE_PRS_READ_FAIL_BACKOFF_S"
  [ -z "$bad" ] && { rm -f "$(rcr_dir)/knobs-bad" 2>/dev/null; return 0; }
  # ONCE per set of bad knobs, not once per tick: this runs on every box.
  [ "$(cat "$(rcr_dir)/knobs-bad" 2>/dev/null)" = "$bad" ] && return 1
  mkdir -p "$(rcr_dir)" "$(_rcr_h)/logs" 2>/dev/null
  printf '%s' "$bad" > "$(rcr_dir)/knobs-bad" 2>/dev/null
  _rcr_log "reconcile-prs: tick NOT run — knob(s)$bad have no usable value (no settings row, env or registry default reached this lane; catalog/lanes.d/reconcile-prs.json) — said once until the value changes"
  return 1
}
_rcr_clean() { printf '%s' "${1:-}" | tr -dc 'A-Za-z0-9._-'; }

# rcr_owner_skip — rc 0 when THIS box must not run the lane, rc 1 when it owns it.
# `hub` means whichever box bin/lib/hub-box.sh calls the hub; any other value is
# one fleet box name. A box that cannot name itself, or has no hub-box lib, is
# not the owner: running everywhere is the cost this ticket exists to remove.
rcr_owner_skip() {
  local owner box=""
  owner=$(_rcr_clean "${RECONCILE_PRS_OWNER:-}")
  command -v local_box_name >/dev/null 2>&1 && box=$(local_box_name)
  if command -v is_hub_box >/dev/null 2>&1; then
    if [ "$owner" = hub ]; then is_hub_box "$box" && { rm -f "$(rcr_dir)/not-owner"; return 1; }
    elif [ -n "$box" ] && [ "$box" = "$owner" ]; then rm -f "$(rcr_dir)/not-owner"; return 1; fi
  fi
  _rcr_say_not_owner "$owner" "${box:-unnamed}"
  return 0
}

# _rcr_say_not_owner <owner> <box> — ONE line per owner value, not one per tick.
_rcr_say_not_owner() {
  local f line="owner=$1 box=$2"
  f="$(rcr_dir)/not-owner"
  [ "$(cat "$f" 2>/dev/null)" = "$line" ] && return 0
  mkdir -p "$(rcr_dir)" "$(_rcr_h)/logs" 2>/dev/null
  printf '%s' "$line" > "$f" 2>/dev/null
  _rcr_log "reconcile-prs: this box ($2) is not the reconcile owner ($1, settings lane.reconcile-prs.reconcile_prs_owner) — every tick here exits before any console or GitHub read (said once per owner value)"
}

# rcr_tick_begin — a per-tick scratch dir for the pages; rcr_tick_end removes it.
# Called under the lane's own flock, so any tick.* already here belongs to a
# tick that was SIGKILLed before its EXIT trap ran, and is swept.
# BH-1610: once the dir exists, the files are hydrated from the D1 copy
# (rcr_memory_hydrate), so a box that never ran the lane starts from what the
# last owner learned.
rcr_tick_begin() {
  mkdir -p "$(rcr_dir)/open" "$(rcr_dir)/terminal" "$(rcr_dir)/gone" "$(rcr_dir)/failed" 2>/dev/null
  rm -rf "$(rcr_dir)"/tick.* 2>/dev/null
  RCR_TICK=$(mktemp -d "$(rcr_dir)/tick.XXXXXX" 2>/dev/null) || RCR_TICK=""
  RCR_READS=0; RCR_DEFERRED=0; RCR_BACKED=0; RCR_J=""
  [ -n "$RCR_TICK" ] && rcr_memory_hydrate
  [ -n "$RCR_TICK" ]
}
rcr_tick_end() { [ -n "${RCR_TICK:-}" ] && rm -rf "$RCR_TICK"; RCR_TICK=""; }

# _rcr_auth <slug> — the CALLER decides which identity a read goes out on: the
# lane defines rcr_auth (bin/reconcile-prs.sh, #469) and this file only asks it,
# before every read, for the repo that read is about.
_rcr_auth() { command -v rcr_auth >/dev/null 2>&1 && rcr_auth "$1"; return 0; }

# rcr_fetch_pages <unmerged-json> — one list read per distinct repo in the list.
rcr_fetch_pages() {
  local slug
  while read -r slug; do
    [ -n "$slug" ] || continue
    rcr_page "$slug"
  done < <(jq -r '.builds[]?.pr_url // empty' <<<"${1:-}" 2>/dev/null \
             | sed -nE 's|^https://github.com/([^/]+/[^/]+)/pull/[0-9]+.*$|\1|p' | sort -u)
}

# rcr_page <slug> — writes the page and its rc (0 page, 44 gone, 75 unreadable,
# 2 inside a 404 backoff) under $RCR_TICK.
rcr_page() {
  local slug="$1" base rc=0
  base="$RCR_TICK/$(_rcr_name "$slug")"
  if rcr_gone_backoff "$slug"; then echo 2 > "$base.rc"; return 0; fi
  if command -v gh_rest >/dev/null 2>&1; then
    _rcr_auth "$slug"
    gh_rest GET "repos/$slug/pulls" -f state=closed -f sort=updated -f direction=desc \
      -F "per_page=$RECONCILE_PRS_PAGE" > "$base.json" || rc=$?
    [ "$rc" = 0 ] && ! jq -e 'type == "array"' "$base.json" >/dev/null 2>&1 && rc=75
  else rc=75; fi
  case "$rc" in 0) rcr_gone_clear "$slug" ;; 44) rcr_gone_record "$slug" ;; *) rc=75 ;; esac
  echo "$rc" > "$base.rc"
}

_rcr_page_rc() { cat "$RCR_TICK/$(_rcr_name "$1").rc" 2>/dev/null; }

# --- the 404 backoff ------------------------------------------------------
_rcr_gone_file() { printf '%s/gone/%s' "$(rcr_dir)" "$(_rcr_name "$1")"; }
rcr_gone_backoff() { # rc 0 while <slug> is inside its backoff window
  local at
  at=$(tr -dc '0-9' < "$(_rcr_gone_file "$1")" 2>/dev/null)
  [ -n "$at" ] || return 1
  [ $(( $(date +%s) - at )) -lt "$RECONCILE_PRS_GONE_BACKOFF_S" ]
}
rcr_gone_record() {
  local now; now=$(date +%s)
  echo "$now" > "$(_rcr_gone_file "$1")" 2>/dev/null
  _rcr_journal up gone "$(_rcr_name "$1")" "$now"
  _rcr_log "reconcile-prs: repos/$1 answered 404 (renamed, deleted, or not visible to this identity) — its tracked PRs are not read again for ${RECONCILE_PRS_GONE_BACKOFF_S}s"
}
# Called on every good page: only a backoff that EXISTED is a change to send.
rcr_gone_clear() {
  [ -e "$(_rcr_gone_file "$1")" ] || return 0
  rm -f "$(_rcr_gone_file "$1")" 2>/dev/null
  _rcr_journal del gone "$(_rcr_name "$1")"
}

# --- one PR's state ---------------------------------------------------------
# _rcr_norm — a pull object (list item or single read) -> the fields the lane uses.
# A handed-in .STATE is honoured unless it says MERGED without the merge fact
# (BH-3971): `merged_at` is the only field that says a merge happened, so a
# MERGED word with no `merged_at` is re-derived from `.state` like any item.
_rcr_norm() {
  jq -c '{STATE: (if .STATE and (.STATE != "MERGED" or (.merged_at // "") != "") then .STATE
                   elif (.merged_at // "") != "" then "MERGED"
                   elif .state == "open" then "OPEN" else "CLOSED" end),
          closed_at, merged_at, merge_commit_sha, updated_at}' 2>/dev/null
}

# rcr_pr_state <pr-url> — sets RCR_STATE RCR_CLOSED_AT RCR_MERGED_AT RCR_MSHA;
# all empty when nothing answered this tick (absent is not an outcome).
#
# THE ORDER IS THE CONTRACT (review of #1593). What GitHub says THIS tick wins:
#   1. the PR is on this tick's page           -> the page's answer;
#   2. a remembered answer the page still agrees with (_rcr_cached): MERGED
#      always (a merged PR cannot reopen), CLOSED only while the page is
#      consistent with it — close/reopen is the documented unstick, and a
#      remembered CLOSED that outranked the page hid a later merge for good;
#   3. proved open from the page (_rcr_proved_open);
#   4. one capped single read (_rcr_fallback).
rcr_pr_state() {
  local url="$1" slug num name
  RCR_STATE=""; RCR_CLOSED_AT=""; RCR_MERGED_AT=""; RCR_MSHA=""; RCR_J=""
  slug=$(_rcr_slug_of "$url"); num=$(_rcr_num_of "$url")
  [ -n "$slug" ] && [ -n "$num" ] || return 0
  name=$(_rcr_name "$slug#$num")
  echo "$name" >> "$RCR_TICK/seen"
  _rcr_on_page "$slug" "$num" || _rcr_cached "$url" "$slug" "$name" || _rcr_proved_open "$slug" "$name" \
    || _rcr_fallback "$url" "$slug" "$name" || return 0
  read -r RCR_STATE RCR_CLOSED_AT RCR_MERGED_AT RCR_MSHA < <(jq -r \
    '"\(.STATE // "") \(.closed_at // "-") \(.merged_at // "-") \(.merge_commit_sha // "-")"' <<<"$RCR_J" 2>/dev/null)
  [ "$RCR_CLOSED_AT" = - ] && RCR_CLOSED_AT=""; [ "$RCR_MERGED_AT" = - ] && RCR_MERGED_AT=""
  [ "$RCR_MSHA" = - ] && RCR_MSHA=""
  return 0
}

_rcr_page_file() { printf '%s/%s.json' "$RCR_TICK" "$(_rcr_name "$1")"; }

# _rcr_page_shape <slug> — RCR_PN (items), RCR_CUTOFF (oldest updated_at) and
# RCR_NEWEST (newest updated_at) of this tick's page; `-` when there is none.
_rcr_page_shape() {
  read -r RCR_PN RCR_CUTOFF RCR_NEWEST < <(jq -r \
    '"\(length) \(.[-1].updated_at // "-") \(.[0].updated_at // "-")"' "$(_rcr_page_file "$1")" 2>/dev/null)
}

# _rcr_on_page <slug> <num> — rc 0 with RCR_J set when this tick's page has it.
_rcr_on_page() {
  [ "$(_rcr_page_rc "$1")" = 0 ] || return 1
  RCR_J=$(jq -c --argjson n "$2" '.[] | select(.number == $n)' "$(_rcr_page_file "$1")" 2>/dev/null | head -1 | _rcr_norm)
  [ -n "$RCR_J" ]
}

# _rcr_cached <url> <slug> <name> — rc 0 with RCR_J = a remembered answer the
# page still agrees with. A still-CLOSED PR is absent from this closed page only
# when the page is FULL and its cutoff is at or after the PR's own updated_at
# (it fell off). Absent from a short page, or absent while the cutoff is older
# than its updated_at, it is not closed any more: the entry is dropped and the
# state re-derived. With no readable page nothing can agree: kept, not used.
_rcr_cached() {
  local f j u
  f="$(rcr_dir)/terminal/$3"
  j=$(cat "$f" 2>/dev/null); [ -n "$j" ] || return 1
  # A remembered MERGED is final only when it carries the merge fact (BH-3971).
  # One with no `merged_at` is the word without the fact: dropped and re-derived
  # from GitHub, never handed to the lane as a merge.
  if [ "$(jq -r '.STATE // ""' <<<"$j" 2>/dev/null)" = MERGED ]; then
    if [ -n "$(jq -r '.merged_at // ""' <<<"$j" 2>/dev/null)" ]; then RCR_J="$j"; return 0; fi
    rm -f "$f"
    _rcr_journal del terminal "$3"
    _rcr_log "reconcile-prs: $1 was remembered MERGED with no merged_at — not a merge fact, dropped and re-derived"
    return 1
  fi
  [ "$(_rcr_page_rc "$2")" = 0 ] || return 1
  u=$(jq -r '.updated_at // ""' <<<"$j" 2>/dev/null); _rcr_page_shape "$2"
  if [ -n "$u" ] && [ "${RCR_PN:-0}" -ge "$RECONCILE_PRS_PAGE" ] && ! [[ "$RCR_CUTOFF" < "$u" ]]; then
    RCR_J="$j"; return 0
  fi
  rm -f "$f"
  _rcr_journal del terminal "$3"
  _rcr_log "reconcile-prs: $1 was remembered CLOSED but its repo's closed page no longer agrees (reopened?) — re-deriving it"
  return 1
}

# _rcr_proved_open <slug> <name> — rc 0 (RCR_J = OPEN) when the page proves it.
_rcr_proved_open() {
  local asof
  [ "$(_rcr_page_rc "$1")" = 0 ] || return 1
  _rcr_page_shape "$1"
  asof=$(cat "$(rcr_dir)/open/$2" 2>/dev/null)
  if [ "${RCR_PN:-0}" -lt "$RECONCILE_PRS_PAGE" ] || { [ -n "$asof" ] && [[ "$RCR_CUTOFF" < "$asof" ]]; }; then
    RCR_J='{"STATE":"OPEN"}'; _rcr_open_mark "$2" "$RCR_NEWEST"; return 0
  fi
  return 1
}

# _rcr_read_backed_off <name> — rc 0 while this PR's last single read FAILED
# less than RECONCILE_PRS_READ_FAIL_BACKOFF_S ago. A read that keeps failing
# must not take a cap slot every tick and starve the PRs behind it.
_rcr_read_backed_off() {
  local at
  at=$(tr -dc '0-9' < "$(rcr_dir)/failed/$1" 2>/dev/null)
  [ -n "$at" ] || return 1
  [ $(( $(date +%s) - at )) -lt "$RECONCILE_PRS_READ_FAIL_BACKOFF_S" ]
}

# _rcr_fallback <url> <slug> <name> — the capped single read. A failure is
# stamped (state/reconcile-prs/failed/<pr>) and backed off; a success clears it.
_rcr_fallback() {
  local rc
  rc=$(_rcr_page_rc "$2")
  [ "$rc" = 44 ] || [ "$rc" = 2 ] && return 1
  _rcr_read_backed_off "$3" && { RCR_BACKED=$((RCR_BACKED + 1)); return 1; }
  if [ "$RCR_READS" -ge "$RECONCILE_PRS_FALLBACK_CAP" ]; then RCR_DEFERRED=$((RCR_DEFERRED + 1)); return 1; fi
  RCR_READS=$((RCR_READS + 1))
  _rcr_auth "$2"
  RCR_J=$(mc_pr_view "$1" 'tojson' 2>/dev/null | _rcr_norm)
  [ -n "$RCR_J" ] || { date +%s > "$(rcr_dir)/failed/$3" 2>/dev/null; return 1; }
  rm -f "$(rcr_dir)/failed/$3" 2>/dev/null
  [ "$(jq -r '.STATE' <<<"$RCR_J")" = OPEN ] \
    && _rcr_open_mark "$3" "$(jq -r '.updated_at // "-"' <<<"$RCR_J")" "$(_rcr_page_newest "$2")"
  return 0
}

_rcr_page_newest() {
  [ "$(_rcr_page_rc "$1")" = 0 ] || return 0
  jq -r '.[0].updated_at // empty' "$RCR_TICK/$(_rcr_name "$1").json" 2>/dev/null
}

# _rcr_open_mark <name> <iso>... — move the watermark to the latest GitHub time
# given (never backwards; `-`/empty ignored). ISO-8601 Z stamps sort as strings.
_rcr_open_mark() {
  local name="$1" f t best prior
  f="$(rcr_dir)/open/$name"; shift
  prior=$(cat "$f" 2>/dev/null); best="$prior"
  for t in "$@"; do
    case "$t" in ''|-|null) continue ;; esac
    [ -z "$best" ] || [[ "$best" < "$t" ]] && best="$t"
  done
  [ -n "$best" ] && [ "$best" != "$prior" ] || return 0
  printf '%s' "$best" > "$f" 2>/dev/null
  _rcr_journal up open "$name" "$best"
  return 0
}

# rcr_forget_terminal <pr-url> — drop a remembered answer the lane will not
# trust (BH-3971: MERGED with no merged_at), so the next pass re-derives it.
rcr_forget_terminal() {
  local slug num name
  slug=$(_rcr_slug_of "$1"); num=$(_rcr_num_of "$1")
  [ -n "$slug" ] && [ -n "$num" ] || return 0
  name=$(_rcr_name "$slug#$num")
  [ -e "$(rcr_dir)/terminal/$name" ] || return 0
  rm -f "$(rcr_dir)/terminal/$name" 2>/dev/null
  _rcr_journal del terminal "$name"
}

# rcr_remember_terminal <pr-url> — keep the settled answer in RCR_J for good.
rcr_remember_terminal() {
  local slug num name
  slug=$(_rcr_slug_of "$1"); num=$(_rcr_num_of "$1")
  [ -n "$slug" ] && [ -n "$num" ] && [ -n "$RCR_J" ] || return 0
  name=$(_rcr_name "$slug#$num")
  if [ "$(cat "$(rcr_dir)/terminal/$name" 2>/dev/null)" != "$RCR_J" ]; then
    printf '%s' "$RCR_J" > "$(rcr_dir)/terminal/$name" 2>/dev/null
    _rcr_journal up terminal "$name" "$RCR_J"
  fi
  if [ -e "$(rcr_dir)/open/$name" ]; then
    rm -f "$(rcr_dir)/open/$name" 2>/dev/null
    _rcr_journal del open "$name"
  fi
}

# rcr_prune — forget PRs the console no longer lists (merged rows leave the
# list; their watermark and terminal answer mean nothing after that).
rcr_prune() {
  local d f
  [ -n "${RCR_TICK:-}" ] || return 0
  touch "$RCR_TICK/seen"
  for d in open terminal failed; do
    for f in "$(rcr_dir)/$d"/*; do
      [ -e "$f" ] || continue
      grep -qxF "$(basename "$f")" "$RCR_TICK/seen" && continue
      rm -f "$f"
      [ "$d" = failed ] || _rcr_journal del "$d" "$(basename "$f")"
    done
  done
}

# rcr_tick_summary — the one line a capped tick owes the operator.
rcr_tick_summary() {
  [ "${RCR_DEFERRED:-0}" -gt 0 ] || [ "${RCR_BACKED:-0}" -gt 0 ] || return 0
  _rcr_log "reconcile-prs: $RCR_READS single PR read(s) this tick (cap RECONCILE_PRS_FALLBACK_CAP=$RECONCILE_PRS_FALLBACK_CAP); $RCR_DEFERRED unproved PR(s) wait for the next tick; ${RCR_BACKED:-0} skipped inside their failed-read backoff (RECONCILE_PRS_READ_FAIL_BACKOFF_S)"
}

# --- the D1 copy (BH-1610) ------------------------------------------------
# reconcile_memory (worker/jobs, GET/PUT /api/reconcile-prs/memory) holds the
# same three kinds as the files: open/<pr> watermarks, terminal/<pr> settled
# answers, gone/<repo> 404 stamps. failed/ stays file-only. The FILES are the
# tick's truth; D1 is what a new owner box starts from:
#   - rcr_memory_hydrate (from rcr_tick_begin) writes each row to its file:
#     terminal and gone as they are, open as max(file, row). When the GET
#     answered in full (truncated:false), a local file with no row is sent up
#     too — the one-time migration, and the re-upload of anything a lost flush
#     never delivered.
#   - every change to a file in this lib is journalled (_rcr_journal) to
#     $RCR_TICK/journal.jsonl, and rcr_memory_flush sends the tick's journal as
#     one PUT (chunked at 500 entries).
# D1 never decides a classification: a GET or PUT that fails costs one log line
# and the tick runs on the files. A flush that could not be delivered is kept
# in state/reconcile-prs/journal.pending and re-sent next tick; its keys
# outrank the D1 rows at the next hydrate, because they are newer. A 400 is
# not kept: the worker refused the shape, and re-sending it would fail forever.

# _rcr_mem_name <name> — rc 0 for a name the worker accepts and a file may
# carry: the lane's charset, 1-128 chars, not dots only (no `.`/`..`).
_rcr_mem_name() { [[ "${1:-}" =~ ^[A-Za-z0-9._-]{1,128}$ ]] && ! [[ "$1" =~ ^\.+$ ]]; }

# _rcr_journal <up|del> <kind> <name> [value] — one change, for this tick's flush.
_rcr_journal() {
  [ -n "${RCR_TICK:-}" ] || return 0
  if [ "$1" = up ]; then
    jq -nc --arg k "$2" --arg n "$3" --arg v "${4:-}" '{op:"up",kind:$k,name:$n,value:$v}'
  else
    jq -nc --arg k "$2" --arg n "$3" '{op:"del",kind:$k,name:$n}'
  fi >> "$RCR_TICK/journal.jsonl" 2>/dev/null
  return 0
}

rcr_memory_hydrate() {
  local body pend kind name value f cur d rc
  [ -n "${RCR_TICK:-}" ] || return 0
  pend="$(rcr_dir)/journal.pending"
  # What the last flush could not deliver is re-sent by this tick's, whatever
  # the GET does; the pending file is rewritten or removed by that flush.
  [ -s "$pend" ] && cat "$pend" >> "$RCR_TICK/journal.jsonl" 2>/dev/null
  if ! command -v _jobs_req >/dev/null 2>&1; then
    _rcr_log "reconcile-prs: memory GET not made (no jobs client on this box) — this tick runs on the box's own files" 2>/dev/null
    return 0
  fi
  # Not in a $(...): JOBS_HTTP must survive the call for the log line.
  _jobs_req GET /api/reconcile-prs/memory > "$RCR_TICK/memory.json" 2>/dev/null; rc=$?
  body=$(cat "$RCR_TICK/memory.json" 2>/dev/null)
  # A body with no rows array (a stub's `{}`) is a failed GET, not an empty table.
  if [ "$rc" -ne 0 ] || ! jq -e '.rows | type == "array"' <<<"$body" >/dev/null 2>&1; then
    _rcr_log "reconcile-prs: memory GET failed (http=${JOBS_HTTP:-none}) — this tick runs on the box's own files" 2>/dev/null
    return 0
  fi
  : > "$RCR_TICK/mem.keys"
  while IFS= read -r -d '' kind && IFS= read -r -d '' name && IFS= read -r -d '' value; do
    case "$kind" in terminal|open|gone) ;; *) continue ;; esac
    _rcr_mem_name "$name" && [ -n "$value" ] || continue
    echo "$kind/$name" >> "$RCR_TICK/mem.keys"
    f="$(rcr_dir)/$kind/$name"
    if [ "$kind" = open ]; then
      cur=$(cat "$f" 2>/dev/null)
      if [ -z "$cur" ] || [[ "$cur" < "$value" ]]; then printf '%s' "$value" > "$f" 2>/dev/null
      elif [[ "$value" < "$cur" ]]; then _rcr_journal up open "$name" "$cur"; fi
    else
      printf '%s' "$value" > "$f" 2>/dev/null
    fi
  done < <(jq -j --slurpfile p <(cat "$pend" 2>/dev/null) '
      (reduce $p[] as $e ({}; .["\($e.kind)/\($e.name)"] = true)) as $pk
      | .rows[] | select(($pk["\(.kind)/\(.name)"] // false) | not)
      | select([.kind, .name, .value] | map(tostring | contains("\u0000")) | any | not)
      | (.kind | tostring), "\u0000", (.name | tostring), "\u0000", (.value | tostring), "\u0000"' <<<"$body" 2>/dev/null)
  if ! jq -e '.truncated == false' <<<"$body" >/dev/null 2>&1; then
    _rcr_log "reconcile-prs: memory GET was truncated — files with no D1 row are not uploaded this tick" 2>/dev/null
    return 0
  fi
  for d in open terminal gone; do
    for f in "$(rcr_dir)/$d"/*; do
      [ -f "$f" ] || continue
      grep -qxF "$d/$(basename "$f")" "$RCR_TICK/mem.keys" && continue
      _rcr_journal up "$d" "$(basename "$f")" "$(cat "$f" 2>/dev/null)"
    done
  done
  return 0
}

rcr_memory_flush() {
  local j="${RCR_TICK:-}/journal.jsonl" send pend n k total bad
  [ -n "${RCR_TICK:-}" ] && [ -s "$j" ] || return 0
  send="$RCR_TICK/flush.jsonl"; pend="$(rcr_dir)/journal.pending"
  # The LAST change per (kind, name) wins: an up then a del this tick sends the del.
  jq -sc 'to_entries | group_by([.value.kind, .value.name]) | map(max_by(.key).value) | .[]' "$j" \
    > "$RCR_TICK/reduced.jsonl" 2>/dev/null || return 0
  # Whatever the worker would refuse is dropped here, so it cannot 400 every tick.
  jq -c 'select((.kind == "open" or .kind == "terminal" or .kind == "gone")
          and (.name | type == "string" and test("^[A-Za-z0-9._-]{1,128}$") and (test("^[.]+$") | not))
          and (.op == "del" or (.op == "up" and (.value | type == "string" and length > 0 and length <= 4096))))' \
    "$RCR_TICK/reduced.jsonl" > "$send" 2>/dev/null
  total=$(grep -c . "$send"); bad=$(( $(grep -c . "$RCR_TICK/reduced.jsonl") - total ))
  [ "$bad" -gt 0 ] && _rcr_log "reconcile-prs: $bad memory change(s) not sent — a name or value the worker refuses" 2>/dev/null
  [ "$total" -gt 0 ] || { rm -f "$pend" 2>/dev/null; return 0; }
  for (( k = 0; k < total; k += 500 )); do
    if command -v _jobs_req >/dev/null 2>&1 && _jobs_req PUT /api/reconcile-prs/memory "$(sed -n "$((k + 1)),$((k + 500))p" "$send" \
         | jq -sc '{upserts: map(select(.op == "up") | {kind, name, value}), deletes: map(select(.op == "del") | {kind, name})}')" >/dev/null 2>&1; then
      continue
    fi
    n=$(( total - k < 500 ? total - k : 500 ))
    if [ "${JOBS_HTTP:-}" = 400 ]; then
      _rcr_log "reconcile-prs: memory flush refused (http=400) — $n change(s) dropped, not retried; the box's files are unchanged" 2>/dev/null
      continue
    fi
    tail -n +"$((k + 1))" "$send" > "$pend" 2>/dev/null
    _rcr_log "reconcile-prs: memory flush failed (http=${JOBS_HTTP:-none}) — $((total - k)) change(s) kept for the next tick; the box's files are unchanged" 2>/dev/null
    return 0
  done
  rm -f "$pend" 2>/dev/null
  return 0
}
