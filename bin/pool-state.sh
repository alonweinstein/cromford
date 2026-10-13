#!/bin/bash
# bin/pool-state.sh — BH-5001 (BH-4951.2): the operator's side of the Fly pool's
# pool_* rows (worker/jobs/src/routes/pool-state.js). Hub only, no cron line.
#
#   bin/pool-state.sh backfill [--dry-run] [project...]
#       Copies this hub's state/pool/<p>/ files into the rows, for every
#       project directory there (or the named ones). Idempotent: a re-run
#       inserts nothing.
#         <KEY>.spawns    one row per line, box=$JOBS_BOX; the k-th repeat of
#                         one ts in one file is box=$JOBS_BOX#k, so the keys are
#                         deterministic and a line this hub already recorded
#                         live collides instead of counting twice. 500 rows a call.
#         <KEY>.terminal  if_absent: a newer verdict in the DB is never overwritten.
#         <KEY>.held      a ticket hold, if_absent.
#         _spawn-hold     the project hold, if_absent; an expired one is skipped.
#       Prints `<p> <spawns|terminals|holds> files=<n> sent=<n> inserted=<n>`
#       per project and kind, then `TOTAL spawns=<n> terminals=<n> holds=<n>`
#       read back from the worker. --dry-run sends nothing and prints what
#       it would send. Works with the pool_state_rows knob on or off.
#   bin/pool-state.sh lift-hold <project>
#       Lifts the lane-failure spawn hold early: removes state/pool/<p>/_spawn-hold
#       AND the spawn row (with the knob on, deleting the file alone leaves the
#       row holding every hub).
#   bin/pool-state.sh show <project>
#       The rows as TSV: `spawn key ts box machine`, `terminal key branch
#       head_sha created_at cleared_at`, `hold kind key until_at why`.
#
# Exit: 0 done; 1 the worker is unreachable, answered something that is not the
# contract (nothing is written), or refused a write; 2 usage.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HARNESS/bin/jobs-client.sh" 2>/dev/null || . "$HERE/jobs-client.sh" 2>/dev/null || true
command -v _jobs_req >/dev/null 2>&1 || { echo "pool-state: no jobs client (bin/jobs-client.sh)"; exit 1; }
NAME_RE='^[A-Za-z0-9._-]{1,64}$'
CHUNK=500

usage() { sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

# snapshot <p> — the GET, rc 0 only on the contract shape for <p>.
snapshot() {
  local p="$1" resp rc=0
  resp=$(JOBS_ALERT=0 _jobs_req GET "/api/pool-state?project=$p&since=0") || rc=$?
  if [ "$rc" != 0 ]; then echo "pool-state: worker unreachable for $p (rc=$rc http=${JOBS_HTTP:-none})" >&2; return 1; fi
  printf '%s' "$resp" | jq -e --arg p "$p" 'type == "object" and .project == $p and (.spawns | type) == "array"
      and (.terminals | type) == "array" and (.holds | type) == "array"' >/dev/null 2>&1 \
    || { echo "pool-state: the worker's answer for $p is not the pool-state contract (an older worker?) — nothing written" >&2; return 1; }
  printf '%s' "$resp"
}

# send <method> <path> <body> — prints .inserted (or 1), rc 1 on any refusal.
send() {
  local resp rc=0
  resp=$(JOBS_ALERT=0 _jobs_req "$1" "$2" "$3") || rc=$?
  if [ "$rc" != 0 ]; then echo "pool-state: $1 $2 failed (rc=$rc http=${JOBS_HTTP:-none} ${JOBS_BODY:-})" >&2; return 1; fi
  printf '%s' "$resp" | jq -r '.inserted // 0' 2>/dev/null
}

backfill() {
  local dry=0 p f k n ins sent files fails=0 ts_rows chunk body now projects=() a
  for a in "$@"; do
    case "$a" in --dry-run) dry=1 ;; -*) usage ;; *) projects+=("$a") ;; esac
  done
  if [ "${#projects[@]}" = 0 ]; then
    for f in "$HARNESS/state/pool"/*/; do [ -d "$f" ] && projects+=("$(basename "$f")"); done
  fi
  [ "${#projects[@]}" -gt 0 ] || { echo "pool-state: no project directories under $HARNESS/state/pool"; echo "TOTAL spawns=0 terminals=0 holds=0"; return 0; }
  for p in "${projects[@]}"; do
    [[ "$p" =~ $NAME_RE ]] || { echo "pool-state: '$p' is not a project name" >&2; return 2; }
  done
  # One read first: an unreachable or older worker writes nothing at all.
  snapshot "${projects[0]}" >/dev/null || return 1
  now=$(date -u +%s)
  local box="${JOBS_BOX:-}"
  [[ "$box" =~ $NAME_RE ]] || { echo "pool-state: JOBS_BOX '$box' is not a box name" >&2; return 1; }
  for p in "${projects[@]}"; do
    local d="$HARNESS/state/pool/$p"
    # spawns: key<TAB>ts<TAB>box, the k-th repeat of a ts in one file as box#k.
    files=0; ts_rows=""
    for f in "$d"/*.spawns; do
      [ -f "$f" ] || continue
      k=$(basename "$f" .spawns); [[ "$k" =~ $NAME_RE ]] || continue
      files=$((files+1))
      ts_rows+=$(awk -v k="$k" -v b="$box" '
        /^[0-9]+$/ { n[$0]++; printf "%s\t%s\t%s\n", k, $0, (n[$0] == 1 ? b : b "#" n[$0]) }' "$f")
      ts_rows+=$'\n'
    done
    ts_rows=$(printf '%s' "$ts_rows" | sed '/^$/d')
    sent=0; ins=0
    [ -n "$ts_rows" ] && sent=$(printf '%s\n' "$ts_rows" | wc -l | tr -d ' ')
    if [ "$dry" = 0 ] && [ "$sent" -gt 0 ]; then
      local off=0
      while [ "$off" -lt "$sent" ]; do
        chunk=$(printf '%s\n' "$ts_rows" | sed -n "$((off+1)),$((off+CHUNK))p")
        body=$(printf '%s\n' "$chunk" | jq -Rnc --arg p "$p" \
          '{project:$p, rows:[inputs | select(length > 0) | split("\t") | {key:.[0], ts:(.[1]|tonumber), box:.[2]}]}')
        if n=$(send POST /api/pool-state/spawns "$body"); then ins=$((ins + ${n:-0})); else fails=$((fails+1)); fi
        off=$((off+CHUNK))
      done
    fi
    echo "$p spawns files=$files sent=$sent inserted=$ins$([ "$dry" = 1 ] && echo ' (dry-run)')"
    # terminals
    files=0; sent=0; ins=0
    for f in "$d"/*.terminal; do
      [ -f "$f" ] || continue
      k=$(basename "$f" .terminal); [[ "$k" =~ $NAME_RE ]] || continue
      files=$((files+1))
      body=$(jq -c --arg p "$p" --arg k "$k" --arg b "$box" \
        '{project:$p, key:$k, branch:(.branch // ""), head_sha:(.head_sha // ""), reason:(.reason // ""), box:$b, if_absent:true}
         + (if (.created_at // "") == "" then {} else {created_at:.created_at} end)' "$f" 2>/dev/null) \
        || { echo "pool-state: $f is not json — skipped" >&2; continue; }
      sent=$((sent+1))
      [ "$dry" = 1 ] && continue
      if n=$(send PUT /api/pool-state/terminal "$body"); then ins=$((ins + ${n:-0})); else fails=$((fails+1)); fi
    done
    echo "$p terminals files=$files sent=$sent inserted=$ins$([ "$dry" = 1 ] && echo ' (dry-run)')"
    # holds: <KEY>.held and an unexpired _spawn-hold
    files=0; sent=0; ins=0
    for f in "$d"/*.held; do
      [ -f "$f" ] || continue
      k=$(basename "$f" .held); [[ "$k" =~ $NAME_RE ]] || continue
      files=$((files+1))
      body=$(jq -c --arg p "$p" --arg k "$k" --arg b "$box" \
        '{project:$p, kind:"ticket", key:$k, why:(.why // ""), box:$b, if_absent:true}
         + (if (.ticket_id // "") == "" then {} else {ticket_id:(.ticket_id|tostring)} end)
         + (if (.first_seen // "") == "" then {} else {first_seen:.first_seen} end)
         + (if (.last_seen // "") == "" then {} else {last_seen:.last_seen} end)' "$f" 2>/dev/null) \
        || { echo "pool-state: $f is not json — skipped" >&2; continue; }
      sent=$((sent+1))
      [ "$dry" = 1 ] && continue
      if n=$(send PUT /api/pool-state/holds "$body"); then ins=$((ins + ${n:-0})); else fails=$((fails+1)); fi
    done
    if [ -f "$d/_spawn-hold" ]; then
      files=$((files+1))
      local at why
      read -r at why < "$d/_spawn-hold" 2>/dev/null
      case "$at" in ''|*[!0-9]*) at=0 ;; esac
      if [ "$at" -gt "$now" ]; then
        sent=$((sent+1))
        if [ "$dry" = 0 ]; then
          body=$(jq -nc --arg p "$p" --arg w "${why:-}" --argjson u "$at" --arg b "$box" \
            '{project:$p, kind:"spawn", key:"", until_at:$u, why:$w, box:$b, if_absent:true}')
          if n=$(send PUT /api/pool-state/holds "$body"); then ins=$((ins + ${n:-0})); else fails=$((fails+1)); fi
        fi
      fi
    fi
    echo "$p holds files=$files sent=$sent inserted=$ins$([ "$dry" = 1 ] && echo ' (dry-run)')"
  done
  # Read back what the worker holds now, for the projects just walked.
  local snap ts=0 tt=0 th=0 trunc=""
  for p in "${projects[@]}"; do
    snap=$(snapshot "$p") || return 1
    ts=$((ts + $(printf '%s' "$snap" | jq '.spawns | length')))
    tt=$((tt + $(printf '%s' "$snap" | jq '.terminals | length')))
    th=$((th + $(printf '%s' "$snap" | jq '.holds | length')))
    printf '%s' "$snap" | jq -e '[.truncated[]?] | any' >/dev/null 2>&1 && trunc+=" $p"
  done
  echo "TOTAL spawns=$ts terminals=$tt holds=$th"
  [ -z "$trunc" ] || echo "pool-state: a list was cut at its limit for:$trunc — TOTAL is a lower bound" >&2
  if [ "$fails" -gt 0 ]; then echo "pool-state: $fails write(s) refused — re-run backfill; it is idempotent" >&2; return 1; fi
  return 0
}

lift_hold() {
  local p="${1:-}" f had=no rc=0 resp
  [[ "$p" =~ $NAME_RE ]] || usage
  f="$HARNESS/state/pool/$p/_spawn-hold"
  [ -e "$f" ] && { rm -f "$f" && had=yes; }
  resp=$(JOBS_ALERT=0 _jobs_req PATCH /api/pool-state/holds "$(jq -nc --arg p "$p" '{project:$p, kind:"spawn", key:"", clear:true}')") || rc=$?
  if [ "$rc" != 0 ]; then
    echo "pool-state: $p file removed=$had; the spawn row was NOT lifted (rc=$rc http=${JOBS_HTTP:-none}) — every hub still reads it"
    return 1
  fi
  echo "pool-state: $p file removed=$had row removed=$(printf '%s' "$resp" | jq -r '.removed // 0')"
}

show() {
  local p="${1:-}" snap
  [[ "$p" =~ $NAME_RE ]] || usage
  snap=$(snapshot "$p") || return 1
  printf '%s' "$snap" | jq -r '
    (.spawns[] | ["spawn", .key, (.ts|tostring), .box, (.machine // "-")]),
    (.terminals[] | ["terminal", .key, (.branch // "-"), (.head_sha // "-"), .created_at, (.cleared_at // "-")]),
    (.holds[] | ["hold", .kind, (if .key == "" then "-" else .key end), ((.until_at // "-")|tostring), (.why // "")])
    | @tsv'
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  backfill)  backfill "$@" ;;
  lift-hold) lift_hold "$@" ;;
  show)      show "$@" ;;
  *)         usage ;;
esac
