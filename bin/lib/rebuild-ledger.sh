#!/bin/bash
# bin/lib/rebuild-ledger.sh — what the blocked-resolver's state row gains when a
# rebuild is a QUEUED JOB rather than a number. The row has always carried
# `rebuilds: N`, which answers "how many" and nothing else: not which job, not
# whether it is still running, not what to print when the ladder gives up. This
# lib adds the list (`rebuild_jobs[]{id,enqueued_at,at}`) and the two wait fields
# (`wait`, `wait_job`), and leaves the counter exactly where it is.
#
# SOURCED, NEVER EXECUTED — by bin/blocked-resolver.sh, hard. It resolves no
# harness root of its own: `br_file`, `br_load`, `STAMP` and `$ST` are the
# resolver's and bind at call time (bash late binding, the same arrangement
# bin/lib/hold.sh uses). A second `${HARNESS:-/root/harness}` in here is exactly
# what tests/no-harness-export-test.sh section D exists to catch.
#
# The `br_tkey_*` bodies at the bottom are the ticket-key cache, real since
# BH-487.2. Nothing here writes a ledger yet — the rebuild rung that fills it is
# BH-487.1.

# br_job_add <project> <cap-key> <job-id> <enqueued-at> — append
# {id,enqueued_at,at}; deduped on id. The resolver re-reads the same live row
# every ten minutes, so a job that is not deduped is a cap burned in an hour.
br_job_add() {
  local f cur; f=$(br_file "$1" "$2"); mkdir -p "$(dirname "$f")" 2>/dev/null
  cur=$(br_load "$1" "$2" | jq -c --arg i "$3" --arg e "${4:--}" --arg t "$(STAMP)" \
        '.rebuild_jobs = ((.rebuild_jobs // [])
           | if any(.[]?; (.id // "") == $i) then . else . + [{id:$i,enqueued_at:$e,at:$t}] end)
         | .updated=$t' 2>/dev/null) || return 1
  printf '%s\n' "$cur" > "$f"
}

# br_jobs_count <state-json> — `null` when the row has NO ledger (a legacy row
# keeps its counter cap), else the length. ABSENT IS NOT ZERO: jq's `//` treats
# `[]` as present, so an empty ledger counts 0 and a missing one counts null,
# which are two different instructions to the caller. Pure, writes nothing.
br_jobs_count() {
  printf '%s' "${1:-}" | jq -r '(.rebuild_jobs // null) | if . == null then "null" else (length|tostring) end' 2>/dev/null
}

# br_jobs_why <state-json> — " (jobs: a, b)" or nothing, for the ABANDONED
# alert's tail. Always rc 0: a malformed row costs the suffix, never the alert.
br_jobs_why() {
  local ids
  ids=$(printf '%s' "${1:-}" | jq -r '[(.rebuild_jobs // [])[]? | .id // empty] | join(", ")' 2>/dev/null)
  [ -n "$ids" ] && printf ' (jobs: %s)' "$ids"
  return 0
}

# br_set_wait <project> <cap-key> <job-id|-> — wait=REBUILD_WAIT / wait_job=<id>;
# "-" (or no third argument) clears both. It NEVER touches `outcome`:
# br_from_rebuilds skips a row whose outcome is set, so a wait written as an
# outcome would drop the waiting ticket out of the lane for good.
br_set_wait() {
  local f cur v="${3:--}" w=REBUILD_WAIT
  [ "$v" = "-" ] && w="-"
  f=$(br_file "$1" "$2"); mkdir -p "$(dirname "$f")" 2>/dev/null
  cur=$(br_load "$1" "$2" | jq -c --arg w "$w" --arg j "$v" --arg t "$(STAMP)" \
        '.wait=$w | .wait_job=$j | .updated=$t' 2>/dev/null) || return 1
  printf '%s\n' "$cur" > "$f"
}

# THE TICKET-KEY CACHE (BH-487.2). br_one derives the key under the repo's own
# token — the credential discovery does not have — and caches it beside the row,
# so the next tick of a park whose branch gh would not show discovery carries the
# key instead of re-deriving it (two gh reads) and saying so every ten minutes.
# A sibling of the .nokey-alerted marker, deliberately NOT a *.json:
# br_from_rebuilds globs "$ST"/*/*.json and would read it as a state row.

# br_cached_tkey <project> <rkey> — the cached key if its first line is still a
# key (br_key_shape, the guard every other source passes through); rc 1 otherwise.
br_cached_tkey() {
  local f="$ST/$1/$2.tkey" k
  [ -s "$f" ] || return 1
  k=$(br_key_shape "$(head -1 "$f" 2>/dev/null)") || return 1
  printf '%s' "$k"
}

# br_tkey_put <project> <rkey> <key> — cache a derived key. Empty or "-" writes nothing.
br_tkey_put() {
  case "${3:-}" in ''|-) return 0 ;; esac
  mkdir -p "$ST/$1" 2>/dev/null
  printf '%s\n' "$3" > "$ST/$1/$2.tkey"
}

# br_tkey_sync <project> <rkey> <derived-key> -> the key discovery carries, or "-".
# No derived key: the cache, if it is still a key. A derived key: itself — and a
# cache that DISAGREES is overwritten, because a gh answer always wins over a
# cache written from a title. Never creates the file: only the put does, so a
# park that never reached br_one keeps no cache of its own.
br_tkey_sync() {
  local f="$ST/$1/$2.tkey" k="${3:-}"
  case "$k" in ''|-) br_cached_tkey "$1" "$2" || printf '%s' "-"; return 0 ;; esac
  if [ -e "$f" ] && [ "$(cat "$f" 2>/dev/null)" != "$k" ]; then printf '%s\n' "$k" > "$f"; fi
  printf '%s' "$k"
}
