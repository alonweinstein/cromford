#!/bin/bash
# bin/lib/inapp-deps/release.sh — BH-3946: waking the tick when a text
# dependency merges, and handing the released tickets to its scope. Sourced by
# bin/lib/inapp-deps.sh, never executed.
#
# Filled by BH-3964 (slice 3 of 4). The gate half walks the `<id>.held` markers
# core.sh's buildable arm writes, re-judges each ticket against one board
# listing and one PR list, and stamps the releasable ones into the ready file;
# the take half consumes that file and re-verifies before it prints a line. The
# only writes are box-local watermarks and log lines: no board or GitHub write,
# no model call. A read that fails stamps nothing (D9/D11), and a capped walk
# defers the rest to the next pass (D12).
#
# STATE under inapp_deps_state_dir:
#   <id>.held       core.sh writes it; retired here on a CLEAR offer, on a
#                   ticket that moved (in_progress/review/done/closed or its own
#                   open/merged PR) and on a text that no longer declares a
#                   dependency. A marker visited and kept is touched, so the
#                   oldest-first walk rotates instead of starving new markers.
#   offered/<id>    epoch, written BEFORE the ready line; no re-offer inside
#                   INAPP_DEPS_REMIND_S. The take clears it for an id it did not
#                   hand over, so the gate offers that id again next pass.
#   heldlog/<id>    epoch, rate-limits the INAPP_DEP_HELD line only.
# shellcheck shell=bash

# _id_log <harness> <project> <text> — one line in logs/<p>.log (_sc_log shape)
_id_log() {
  mkdir -p "$1/logs" 2>/dev/null
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$2] $3" >> "$1/logs/$2.log" 2>/dev/null
  return 0
}

# _id_fetch <harness> <id> <out> — the ticket with its whole thread; rc 1 when
# the answer is not a ticket object.
_id_fetch() {
  INTERNAL_TOKEN="$TOKEN" "$1/bin/board-fetch.sh" "$BASE$BP/tickets/$2" --full > "$3" 2>/dev/null \
    && jq -e 'type == "object" and ((.id // .ticket.id?) != null)' "$3" >/dev/null 2>&1
}

# _id_creds <harness> <project> — fills the caller's BASE/BP/TOKEN when any is
# empty: the board prefix from fleet-conf, the base and token variables through
# bin/lib/board-creds.sh (which alerts on a missing or ambiguous one), the way
# bin/triage-gate.sh's generic arm does. bin/run-triage.sh, where the take half
# runs, sets none of them. rc 1 = not configured.
_id_creds() {
  local h="$1" p="$2" envf tv bv
  [ -n "${BASE:-}" ] && [ -n "${BP:-}" ] && [ -n "${TOKEN:-}" ] && return 0
  BP=$("$h/bin/fleet-conf.sh" "$p" board_prefix 2>/dev/null) || BP=""
  case "$BP" in ''|-) return 1 ;; esac
  # shellcheck source=bin/lib/env-path.sh
  declare -F harness_env_dir >/dev/null 2>&1 || . "$_ID_LIBDIR/env-path.sh" 2>/dev/null || return 1
  # shellcheck source=bin/lib/board-creds.sh
  declare -F board_token_var >/dev/null 2>&1 || . "$_ID_LIBDIR/board-creds.sh" 2>/dev/null
  declare -F board_env_value >/dev/null 2>&1 || return 1
  envf="$(harness_env_dir "$h")/$p.env"
  tv=$(HARNESS="$h" board_token_var "$p" "$envf" inapp-deps) || return 1
  bv=$(HARNESS="$h" board_base_var "$p" "$envf" inapp-deps) || return 1
  TOKEN=$(board_env_value "$tv" "$envf"); BASE=$(board_env_value "$bv" "$envf")
  [ -n "$BASE" ] && [ -n "$TOKEN" ]
}

# _id_pass <harness> <project> <tmpdir> <ids...>
#   Judges at most INAPP_DEPS_MAX_LOOKUPS of the ids, in the order given (one
#   by-id fetch each), against ONE PR list and one listing per board (one in
#   practice). OUT: per visited id one \x1f-separated record
#     <id> <state> <verdict> <keys> <base> <pr> <bid> <KEY> <title>
#   state: moving | ok | held <why> | unreadable. The hold check runs only for
#   a CLEAR or STACKABLE verdict. A PR list that fails while fleet-conf names a
#   repo prints nothing at all: "already has its own PR" cannot be answered.
_id_pass() {
  local h="$1" p="$2" td="$3"; shift 3
  local cap="${INAPP_DEPS_MAX_LOOKUPS:-10}" n=0 id visit="" slug tf bid rows code v vt vk vb vu
  local st info key title keys hc moving
  for id in "$@"; do
    [ "$n" -lt "$cap" ] || break
    n=$((n + 1)); visit="$visit $id"
  done
  [ "$#" -gt "$n" ] && _id_log "$h" "$p" "inapp-deps: lookup cap hit ($cap by-id reads) — $(( $# - n )) deferred to the next pass"
  [ -n "$visit" ] || return 0
  printf '[]' > "$td/prs.json"
  slug=$("$h/bin/fleet-conf.sh" "$p" repo 2>/dev/null) || slug=""
  if [ -n "$slug" ]; then
    # shellcheck source=bin/lib/gh-rest.sh
    declare -F gh_rest_pr_list >/dev/null 2>&1 || . "$_ID_LIBDIR/gh-rest.sh" 2>/dev/null
    declare -F gh_rest_pr_list >/dev/null 2>&1 \
      && gh_rest_pr_list "$slug" all "" 100 > "$td/prs.json" 2>/dev/null \
      && jq -e 'type == "array"' "$td/prs.json" >/dev/null 2>&1 || return 0
  fi
  for id in $visit; do
    tf="$td/t-$id.json"
    if ! _id_fetch "$h" "$id" "$tf"; then
      printf '%s\x1funreadable\x1f\x1f\x1f\x1f\x1f\x1f\x1f\n' "$id"; continue
    fi
    info=$(jq -r --slurpfile km <(cat "$h/state/$p.keymap.json" 2>/dev/null || echo '{}') --arg id "$id" '
      (if (.ticket | type) == "object" then .ticket else . end) as $t
      | ((.comments // $t.comments // []) | if type == "array" then . else [] end) as $c
      | ((($t.status // "") | tostring | ascii_downcase)) as $st
      | ($t.key // (if $t.keyPrefix and $t.number != null then "\($t.keyPrefix)-\($t.number)" else null end)
          // (($km[0] // {}) | if type == "object" then .[$id] else null end) // $id) as $k
      | [ $st, ($k | tostring),
          (($t.title // "") | tostring | gsub("[\t\n\r\"\u001f]"; " ")) ] | join("\u001f")' "$tf" 2>/dev/null) \
      || { printf '%s\x1funreadable\x1f\x1f\x1f\x1f\x1f\x1f\x1f\n' "$id"; continue; }
    IFS=$'\x1f' read -r st key title <<<"$info"
    moving=0
    case "$st" in in_progress|review|done|closed) moving=1 ;; esac
    [ "$moving" = 0 ] && jq -e --arg re "^ticket/$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]' | sed 's/[.]/\\./g')(-r[0-9]+)?$" \
        'any(.[]; type == "object" and ((.head.ref? // "") | test($re))
                  and (.state == "open" or .merged_at != null))' "$td/prs.json" >/dev/null 2>&1 && moving=1
    if [ "$moving" = 1 ]; then
      printf '%s\x1fmoving\x1f\x1f\x1f\x1f\x1f\x1f%s\x1f%s\n' "$id" "$key" "$title"; continue
    fi
    bid=$(_id_board_id "$h" "$p" "$tf" "$id")
    case "$bid" in ''|*[!A-Za-z0-9_.-]*)
      printf '%s\x1funreadable\x1f\x1f\x1f\x1f\x1f\x1f%s\x1f%s\n' "$id" "$key" "$title"; continue ;;
    esac
    rows="$td/rows-$bid.json"
    if [ ! -e "$rows" ] && [ ! -e "$rows.bad" ]; then
      code=$(curl -sS -m 20 -o "$rows" -w '%{http_code}' -H "Authorization: Bearer $TOKEN" \
             -H 'User-Agent: curl/8' "$BASE$BP/boards/$bid/tickets" 2>/dev/null) || code=000
      case "$code" in 2??) jq -e . "$rows" >/dev/null 2>&1 || code=bad ;; esac
      case "$code" in 2??) ;; *) rm -f "$rows"; : > "$rows.bad" ;; esac
    fi
    if [ -e "$rows.bad" ]; then
      printf '%s\x1funreadable\x1f\x1f\x1f\x1f\x1f%s\x1f%s\x1f%s\n' "$id" "$bid" "$key" "$title"; continue
    fi
    v=$(HARNESS="$h" inapp_deps_eval "$p" "$tf" "$rows" "$td/prs.json")
    IFS=$'\t' read -r _ vt vk vb vu <<<"${v##*$'\n'}"
    keys="$vk"; st=ok
    case "$vt" in
      CLEAR)
        keys=$(printf '%s\n' "$v" | awk -F'\t' '$2 == "SATISFIED" { print ($3 != "" ? $3 : $1) }' | paste -sd, - | sed 's/,/, /g')
        [ -n "$keys" ] || keys=$(printf '%s\n' "$v" | awk -F'\t' '$1 != "VERDICT" { print ($3 != "" ? $3 : $1) }' | paste -sd, - | sed 's/,/, /g') ;;
    esac
    case "$vt" in
      CLEAR|STACKABLE)
        hc=$(inapp_deps_hold_check "$tf" "${SELF_ACTORS:-}")
        case "$hc" in clear) st=ok ;; held\ *) st="$hc" ;; *) st=unreadable ;; esac ;;
    esac
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
      "$id" "$st" "$vt" "$keys" "$vb" "$vu" "$bid" "$key" "$title"
  done
  return 0
}

# _id_epoch_age <file> — seconds since the epoch the file holds; a large number
# when it is absent or not an epoch.
_id_epoch_age() {
  local t
  t=$(cat "$1" 2>/dev/null); case "$t" in ''|*[!0-9]*) t=0 ;; esac
  echo $(( $(date +%s) - t ))
}

# inapp_deps_gate <harness> <project>
#   OUT: the ids it stamped into the ready file (inapp_deps_ready_file, which
#        bin/lib/rt/scope.sh consumes through inapp_deps_take_lines), one per
#        line, or nothing. Printing anything makes bin/triage-gate.sh step 1e
#        answer `RUN inapp-deps-ready`.
#   Reads the calling gate's BASE, BP, TOKEN and SELF_ACTORS; with any of the
#   first three unset it prints nothing. Markers are walked oldest first.
#   A releasable ticket (CLEAR or STACKABLE, not offered inside
#   INAPP_DEPS_REMIND_S, hold check `clear`) gets, in this order and stopping at
#   the first failure: offered/<id>, the ready line `<id>\t<verdict>\t<base>\t<pr>`,
#   INAPP_DEP_READY in logs/<p>.log, the id on stdout, and on CLEAR the marker
#   removed. A held one logs INAPP_DEP_HELD once per window and stamps nothing.
#   An unreadable one, or a BLOCKED one, stamps nothing.
inapp_deps_gate() {
  local h="${1:-${HARNESS:-${H:-}}}" p="${2:-}" sd rf td ids id st vt keys base pr bid key title now
  [ -n "$h" ] && [ -n "$p" ] || return 0
  [ "$(inapp_deps_on "$h")" = 1 ] || return 0
  [ -n "${BASE:-}" ] && [ -n "${BP:-}" ] && [ -n "${TOKEN:-}" ] || return 0
  sd=$(inapp_deps_state_dir "$h" "$p") && rf=$(inapp_deps_ready_file "$h" "$p") || return 0
  ids=$(cd "$sd" 2>/dev/null && ls -tr -- *.held 2>/dev/null | sed -n 's/\.held$//p' | grep -E '^[A-Za-z0-9_.-]+$')
  [ -n "$ids" ] || return 0
  _inapp_deps_knobs
  td=$(mktemp -d "${TMPDIR:-/tmp}/inapp-deps-wake.XXXXXX") || return 0
  # shellcheck disable=SC2086 # ids are [A-Za-z0-9_.-]+ by the grep above
  _id_pass "$h" "$p" "$td" $ids > "$td/recs"
  now=$(date +%s)
  while IFS=$'\x1f' read -r id st vt keys base pr bid key title; do
    [ -n "$id" ] || continue
    if [ "$st" = moving ]; then
      rm -f "$sd/$id.held" "$sd/offered/$id"; continue
    fi
    case "$st:$vt" in
      ok:NONE|ok:PRIMITIVE) rm -f "$sd/$id.held"; continue ;;
      ok:CLEAR|ok:STACKABLE|held\ *:CLEAR|held\ *:STACKABLE) ;;
      *) [ -e "$sd/$id.held" ] && touch "$sd/$id.held"; continue ;;
    esac
    if [ "$(_id_epoch_age "$sd/offered/$id")" -lt "$INAPP_DEPS_REMIND_S" ]; then
      [ -e "$sd/$id.held" ] && touch "$sd/$id.held"; continue
    fi
    if [ "$st" != ok ]; then
      if [ "$(_id_epoch_age "$sd/heldlog/$id")" -ge "$INAPP_DEPS_REMIND_S" ] \
         && mkdir -p "$sd/heldlog" && printf '%s\n' "$now" > "$sd/heldlog/$id"; then
        _id_log "$h" "$p" "INAPP_DEP_HELD $key — automatic release suppressed: ${st#held }"
      fi
      [ -e "$sd/$id.held" ] && touch "$sd/$id.held"; continue
    fi
    mkdir -p "$sd/offered" && printf '%s\n' "$now" > "$sd/offered/$id" || continue
    printf '%s\t%s\t%s\t%s\n' "$id" "$vt" "$base" "$pr" >> "$rf" || continue
    if [ "$vt" = CLEAR ]; then
      _id_log "$h" "$p" "INAPP_DEP_READY $key ($keys satisfied)"
    else
      _id_log "$h" "$p" "INAPP_DEP_READY $key (stackable on $base)"
    fi
    printf '%s\n' "$id"
    [ "$vt" = CLEAR ] && rm -f "$sd/$id.held"
  done < "$td/recs"
  rm -rf "$td"
  return 0
}

# inapp_deps_take_lines <harness> <project>
#   OUT: one `board <bid>: UNBLOCKED|STACKABLE …` line per released ticket,
#        appended last by bin/lib/rt/scope.sh inapp_released_lines, or nothing.
#   Consumes the ready file (deleted once read; one older than
#   INAPP_DEPS_REMIND_S is deleted unread), then re-judges each id with the
#   same pass the gate uses: a line only for a ticket that is still CLEAR or
#   STACKABLE with its hold check `clear`. An id it does not hand over has its
#   offered/<id> cleared, so the gate re-evaluates it next pass instead of
#   waiting out the window. Board credentials come from _id_creds.
inapp_deps_take_lines() {
  local h="${1:-${HARNESS:-${H:-}}}" p="${2:-}" rf sd td ids id st vt keys base pr bid key title
  local BASE="${BASE:-}" BP="${BP:-}" TOKEN="${TOKEN:-}"
  local SELF_ACTORS="${SELF_ACTORS:-${BOARD_SELF_ACTORS:-System} Harness}"
  [ -n "$h" ] && [ -n "$p" ] || return 0
  rf=$(inapp_deps_ready_file "$h" "$p") && sd=$(inapp_deps_state_dir "$h" "$p") || return 0
  [ -e "$rf" ] || return 0
  _inapp_deps_knobs
  if [ $(( $(date +%s) - $(stat -c %Y "$rf" 2>/dev/null || echo 0) )) -gt "$INAPP_DEPS_REMIND_S" ]; then
    rm -f "$rf"; return 0
  fi
  ids=$(grep -P '^[A-Za-z0-9_.-]+\t(CLEAR|STACKABLE)\t' "$rf" 2>/dev/null | cut -f1 | awk '!seen[$0]++')
  rm -f "$rf"
  [ -n "$ids" ] || return 0
  if ! _id_creds "$h" "$p" || ! td=$(mktemp -d "${TMPDIR:-/tmp}/inapp-deps-take.XXXXXX"); then
    for id in $ids; do rm -f "$sd/offered/$id"; done
    return 0
  fi
  # shellcheck disable=SC2086 # ids are [A-Za-z0-9_.-]+ by the grep above
  _id_pass "$h" "$p" "$td" $ids > "$td/recs"
  for id in $ids; do
    IFS=$'\x1f' read -r _ st vt keys base pr bid key title \
      < <(awk -F'\x1f' -v i="$id" '$1 == i' "$td/recs")
    case "$st:$vt" in
      ok:CLEAR)
        printf 'board %s: UNBLOCKED %s "%s" (%s — text dependency %s satisfied (done or PR merged); fetch it and launch per the queue rules if no PR or build already covers it)\n' \
          "$bid" "$id" "$title" "$key" "$keys" ;;
      ok:STACKABLE)
        printf 'board %s: STACKABLE %s "%s" base=%s parent-pr=%s (%s — Blocked-by %s is still open but its PR is open too — launchable NOW on top of that branch, same queue rules as UNBLOCKED, if no PR or build already covers it)\n' \
          "$bid" "$id" "$title" "$base" "$pr" "$key" "$keys" ;;
      *) rm -f "$sd/offered/$id" ;;
    esac
  done
  rm -rf "$td"
  return 0
}

# inapp_deps_hold_check <ticket-file> <self-actors>
#   OUT: exactly one of `clear`, `held <why>` (what still holds the ticket) or
#        `unreadable` (the ticket could not be read).
#   The in-app thread in bin/lib/hold.sh hold_classify's shape: an open issue
#   carrying `ai-build` (so only the thread, title and body decide), the
#   description as text, each comment a Bot when it is internal or its author's
#   name/userId is a self actor (the whole string or one of its words, the rule
#   core.sh's reader uses), else a User.
inapp_deps_hold_check() {
  local f="${1:-}" self="${2:-}" docs ij cj out
  # shellcheck source=bin/lib/hold.sh
  declare -F hold_classify >/dev/null 2>&1 || . "$_ID_LIBDIR/hold.sh" 2>/dev/null
  declare -F hold_classify >/dev/null 2>&1 || { echo unreadable; return 0; }
  docs=$(jq -c --arg self "$self" '
    def text: tostring
      | gsub("(?i)<br\\s*/?>|</p>|</li>|</div>"; "\n") | gsub("<[^>]+>"; "")
      | gsub("&lt;"; "<") | gsub("&gt;"; ">") | gsub("&quot;"; "\"") | gsub("&#0?39;"; "\u0027")
      | gsub("&nbsp;"; " ") | gsub("&amp;"; "&");
    if type != "object" then error("not a ticket") else . end
    | (if (.ticket | type) == "object" then .ticket else . end) as $t
    | ((.comments // $t.comments // []) | if type == "array" then . else [] end) as $c
    | ($self | ascii_downcase | gsub("^\\s+|\\s+$"; "")) as $me
    | ([$me | splits("\\s+")] + [$me] | map(select(. != ""))) as $selves
    | { state: "open", title: (($t.title // "") | tostring),
        body: (($t.description // $t.body // $t.content // "") | text),
        labels: [{name: "ai-build"}] },
      [ $c[] | select(type == "object")
        | (.author | if type == "object" then [.name, .userId] else [.] end
            | map(select(type == "string") | ascii_downcase | gsub("^\\s+|\\s+$"; ""))) as $who
        | { id, body: ((.body // "") | text), created_at: (.createdAt // .created_at),
            user: { type: (if .isInternal == true or any($who[]; . as $w | $selves | index($w) != null)
                           then "Bot" else "User" end) } } ]' "$f" 2>/dev/null) \
    || { echo unreadable; return 0; }
  { IFS= read -r ij; IFS= read -r cj; } <<<"$docs"
  out=$(hold_classify "$ij" "$cj")
  case "$out" in
    held*)  printf 'held %s\n' "$(printf '%s' "${out#held}" | sed 's/^\t//' | tr '\t' ' ')" ;;
    clear*) echo clear ;;
    *)      echo unreadable ;;
  esac
  return 0
}
