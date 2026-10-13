#!/bin/bash
# shellcheck shell=bash
# bin/lib/proposal-rows.sh — BH-2531: the product lane's proposal ledger as
# harness-jobs rows (table product_proposals), keyed (project, proposal_id).
# Sourced, never run.
#
# state/product-<project>.ledger.json is the only record of which proposals a
# box has gated, vetoed or posted to the client's board, and it dies with the
# box. This file is the shell client for the row copy that outlives it:
# proposal_id is the ledger slug, record is the ledger entry. It speaks
# GET/PUT /api/product-proposals. bin/run-product.sh and bin/product-cmd.sh
# source it (BH-2720), and so does bin/post-proposal.sh, which asks the row
# before it posts (BH-2719); the worker route is a sibling slice of BH-2531,
# and until it deploys every verb here answers 1.
#
# The jobs client (bin/jobs-client.sh: _jobs_req, jobs_configured) is the
# CALLER's to load. Without it a configured box answers "unusable".
#
# rc contract, shared by the verbs:
#   0  the worker answered (prow_put: the row landed)
#   1  a configured worker could not be used (outage, 503, a 404 that is not the
#      route's own, a refused or unparseable answer, no client loaded)
#   2  (prow_get) the worker answered: no such row
#   3  JOBS_URL is empty: no worker here on purpose (BH-1957). This is
#      jobs_configured's own test, done inline and first so it holds even with
#      no client loaded.

# prow_get <project> <slug> — prints the row's status.
prow_get() {
  local p="$1" s="$2" q resp rc tmp
  [ -n "${JOBS_URL:-}" ] || return 3
  command -v _jobs_req >/dev/null 2>&1 || return 1
  q=$(jq -nr --arg p "$p" --arg s "$s" '"project="+($p|@uri)+"&proposal_id="+($s|@uri)') || return 1
  # Called in THIS shell, not in $(...): the 404's body (JOBS_BODY) is what
  # tells "no row" from "no route", and a subshell would drop it.
  tmp=$(mktemp "${TMPDIR:-/tmp}/prow.XXXXXX") || return 1
  _jobs_req GET "/api/product-proposals?$q" > "$tmp"; rc=$?
  resp=$(cat "$tmp"); rm -f "$tmp"
  case "$rc" in
    0) printf '%s' "$resp" | jq -re '.proposal.status | select(type == "string" and . != "")' 2>/dev/null || return 1 ;;
    # Only the route's own 404 is "no row". The router's "unknown endpoint" is a
    # worker that predates the route, and reading that as "never posted" is the
    # re-post this file exists to stop.
    2) [ "$(printf '%s' "$JOBS_BODY" | jq -r '.error // ""' 2>/dev/null)" = "proposal not found" ] && return 2
       return 1 ;;
    *) return 1 ;;
  esac
}

# prow_put <project> <slug> <ledger-file> [status] [if_absent] — write the slug's
#   LAST file entry through to its row; the row's status is [status] when given,
#   else the entry's own. With a 5th arg `if_absent` the row is only created,
#   never changed when it exists (the backfill below). rc 0 landed, 1 not
#   (outage, no entry, 404, 409, an answer that is not a JSON object), 3 no
#   worker. _jobs_req's own 2 and 9 are folded into 1: a put either landed or
#   it did not.
prow_put() {
  local p="$1" s="$2" f="$3" st="${4:-}" ia="${5:-}" body resp
  [ -n "${JOBS_URL:-}" ] || return 3
  command -v _jobs_req >/dev/null 2>&1 || return 1
  body=$(jq -c --arg p "$p" --arg s "$s" --arg st "$st" --arg a "${JOBS_BOX:-}" --arg ia "$ia" '
    (if type == "array" then . else error("not a ledger") end)
    | ([.[] | select(.slug == $s)] | last) as $r
    | if $r == null then error("no entry") else
        {project: $p, proposal_id: $s, status: (if $st != "" then $st else ($r.status // "") end), record: $r}
        + (if $a != "" then {actor: $a} else {} end)
        + (if $ia == "if_absent" then {if_absent: true} else {} end)
      end' "$f" 2>/dev/null) || return 1
  resp=$(_jobs_req PUT /api/product-proposals "$body") || return 1
  printf '%s' "$resp" | jq -e 'type == "object"' >/dev/null 2>&1 || return 1
  return 0
}

# prow_restore <project> <ledger-file> — bring the file up to the rows.
#   A slug the file does not have is appended (the row's record, with the row's
#   status). A slug whose row record is NEWER (updated_at, compared as text:
#   both are the lane's own %Y-%m-%dT%H:%M:%SZ) replaces that slug's entries.
#   Nothing else is touched: no entry is deleted for want of a row, and a file
#   entry newer than its row wins (the next prow_put carries it up). The file is
#   created as [] only when the rows answered. On rc 1/3 it is left exactly as
#   it was, and so is a file that exists but is not a JSON array.
#   Then the backfill: every file slug the rows did not answer is put up
#   `if_absent`, so a proposal gated, posted or vetoed before the table existed
#   gets its row on the first run after deploy, not only when it is next touched.
#   if_absent is what makes that safe: a slug past the list cap, or one another
#   run claimed since the GET, keeps its row as it is. A put that does not land
#   is tried again next run.
prow_restore() {
  local p="$1" f="$2" q resp rc out n_add n_upd log bslug n_bf=0
  [ -n "${JOBS_URL:-}" ] || return 3
  command -v _jobs_req >/dev/null 2>&1 || return 1
  q=$(jq -nr --arg p "$p" '"project="+($p|@uri)') || return 1
  resp=$(_jobs_req GET "/api/product-proposals?$q"); rc=$?
  [ "$rc" = 0 ] || return 1
  printf '%s' "$resp" | jq -e '.proposals | type == "array"' >/dev/null 2>&1 || return 1
  if [ -e "$f" ]; then jq -e 'type == "array"' "$f" >/dev/null 2>&1 || return 1; fi
  [ -f "$f" ] || echo '[]' > "$f" || return 1
  # The rows ride stdin, the file --slurpfile: a thousand records is far past
  # the 128KB one argv string can carry.
  out=$(printf '%s' "$resp" | jq -c --slurpfile file "$f" '
    reduce (.proposals[]
            | select((.record | type) == "object")
            | .record + {slug: .proposal_id, status: .status}) as $rec
      ({l: $file[0], add: 0, upd: 0};
       ([.l[] | select(.slug == $rec.slug)] | last) as $cur
       | if $cur == null then .l += [$rec] | .add += 1
         elif (($rec.updated_at // "") > ($cur.updated_at // "")) then
           .l = [.l[] | select(.slug != $rec.slug)] + [$rec] | .upd += 1
         else . end)' 2>/dev/null) || return 1
  n_add=$(jq -r .add <<<"$out"); n_upd=$(jq -r .upd <<<"$out")
  log="${HARNESS:-/root/harness}/logs/$p.log"
  if [ "$n_add" != 0 ] || [ "$n_upd" != 0 ]; then
    jq '.l' <<<"$out" > "$f.tmp" && mv "$f.tmp" "$f" || return 1
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$p] proposal rows: restored $n_add, updated $n_upd in $(basename "$f")" >> "$log" 2>/dev/null
  fi
  if [ "$(printf '%s' "$resp" | jq -r '.truncated // false')" = true ]; then
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$p] proposal rows: the list was capped; restored from the first page only (post-proposal still reads its own row)" >> "$log" 2>/dev/null
  fi
  while IFS= read -r bslug; do
    [ -n "$bslug" ] || continue
    prow_put "$p" "$bslug" "$f" "" if_absent && n_bf=$((n_bf + 1))
  done < <(printf '%s' "$resp" | jq -r --slurpfile file "$f" '
    [.proposals[].proposal_id] as $have
    | $file[0] | map(select((.slug | type) == "string" and (.status // "") != "") | .slug) | unique[]
    | select(. as $s | $have | index($s) | not)' 2>/dev/null)
  [ "$n_bf" = 0 ] || echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$p] proposal rows: backfilled $n_bf file entr$([ "$n_bf" = 1 ] && echo y || echo ies) with no row" >> "$log" 2>/dev/null
  return 0
}
