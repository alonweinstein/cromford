#!/usr/bin/env bash
# Duplicate-delivery guard for chat intake (2026-09-14).
#
# the operator's Telegram messages reached orchestrate.sh two or three times on
# 2026-09-13/14 ("lock and serialization" x2, "change all these definitions" x2,
# "anything sequential" x3 — the copies 16-45s apart, all from one send). The
# console hands each copy to the poller as its own command, the poller writes
# an inbox file per copy, and orchestrate.sh ran a turn for each — so the operator got
# the same long answer twice, each a full-price turn.
#
# orc_dedupe_seen <seen-file> <key> <window-secs>
#   exit 0  = this key was already seen within the window (a duplicate: skip)
#   exit 1  = first sighting; recorded now (so a copy arriving one second later
#             sees it, even if this turn is still queued behind the lock).
# The check+record is one critical section under a flock so two copies landing
# in the same second cannot both pass. Entries older than one hour are pruned.
orc_dedupe_seen() {
  local seen="$1" key="$2" win="${3:-120}" now
  now=$(date +%s)
  mkdir -p "$(dirname "$seen")"
  (
    flock 9
    if [ -f "$seen" ] && awk -v h="$key" -v now="$now" -v w="$win" '$2==h && (now-$1)<w {f=1} END{exit !f}' "$seen"; then
      exit 0
    fi
    { [ -f "$seen" ] && awk -v now="$now" '(now-$1)<3600' "$seen"; echo "$now $key"; } > "$seen.tmp"
    mv -f "$seen.tmp" "$seen"
    exit 1
  ) 9>"$seen.lock"
}
