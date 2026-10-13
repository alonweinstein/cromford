#!/bin/bash
# tests/switch-legacy-sighting.bh-2412-test.sh — bin/lib/lane-switch.sh's
# no-row fallback (BH-2412): with no `switch.*` settings row, the file and any
# pause_flags row are READ, never reconciled, and a file that decides a switch
# on its own is reported through the existing flag-seen sighting.
#
# What is proved here:
#   L1 no rows, flags row absent (404), file present -> on, src=legacy-file
#   L2 no rows, no file -> off
#   L3 pause_flags row active=1, no file -> on, src=legacy-row, NO file created
#   L4 flags GET outage: the file decides, both ways
#   L5 row active=0 newer than the file -> off and the file left exactly as it
#      was; row active=0 older than the file -> on (a later local touch wins);
#      flags/ is byte-identical (names and mtimes) across every L case
#   L6 no jobs client at all -> the file decides, both ways
#   L7 cost-autohalt-off: a row-less file still stops (the operator's switch)
#   L8 an unreadable flags row never reads as off with a file, nor on without
#   S1 L1's case posts exactly one flag-seen {name, box, active:1} + a marker
#   S2 a second read inside the throttle posts nothing
#   S3 an outage + file posts nothing and writes no marker
#   S4 a settings row 0 + file posts no active:1; with a marker, one active:0
#      post clears it
#   S5 a flag-seen POST answering 500 leaves no marker and the answer stands
#   S6 a pause_flags active=1 row deciding posts no active:1
# Run from anywhere: tests/switch-legacy-sighting.bh-2412-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

NOW=1758300000   # 2025-09-19T16:40:00Z
FILE_T=1758290000
OLD_ROW=2025-09-19T00:00:00Z   # older than FILE_T
NEW_ROW=2025-09-19T16:00:00Z   # newer than FILE_T, older than NOW
mkdir -p "$T/h/bin/lib" "$T/h/flags" "$T/h/state" "$T/h/logs" "$T/h/catalog"
cp "$DIR/bin/lib/lane-gate.sh" "$T/h/bin/lib/"
cp "$DIR/bin/lib/lane-switch.sh" "$T/h/bin/lib/"
cp "$(rendered_registry)" "$T/h/catalog/lanes.json"
FLAGS_LIB="$DIR/bin/lib/jobs/flags.sh"

# The stub worker, at the path _lg_ensure_client sources. It loads the REAL
# bin/lib/jobs/flags.sh (so _flag_epoch, flag_sync and flag_active are the
# shipped ones) and answers:
#   GET /api/settings          -> $ROWS_FILE
#   GET /api/flags/<name>      -> FLAG_MODE none = 404 (rc 2), down = rc 1,
#                                 else the body in $FLAG_ROW
#   POST /api/lanes/flag-seen  -> body appended to $POSTS; POST_FAIL=1 is a 500
# Every request is appended to $CALLS.
cat > "$T/stub-jobs-client.sh" <<'SH'
JOBS_HARNESS="$HARNESS"; JOBS_BOX="${JOBS_BOX:-hub-1}"
_jobs_log() { :; }
. "$FLAGS_LIB"
_jobs_req() {
  JOBS_HTTP=""
  echo "$1 $2" >> "$CALLS"
  case "$1 $2" in
    "GET /api/settings") JOBS_HTTP=200; printf '{"settings":%s}' "$(cat "$ROWS_FILE" 2>/dev/null || echo '[]')" ;;
    "GET /api/flags/"*)
      case "${FLAG_MODE:-none}" in
        none) JOBS_HTTP=404; return 2 ;;
        down) return 1 ;;
      esac
      JOBS_HTTP=200; cat "$FLAG_ROW" ;;
    "POST /api/lanes/flag-seen")
      printf '%s\n' "$3" >> "$POSTS"
      [ -n "${POST_FAIL:-}" ] && { JOBS_HTTP=500; return 1; }
      JOBS_HTTP=200; printf '{"ok":true}' ;;
    *) return 1 ;;
  esac
}
SH
install_client() { cp "$T/stub-jobs-client.sh" "$T/h/bin/jobs-client.sh"; }

rows() {
  local out='[]' kv
  for kv in "$@"; do
    out=$(printf '%s' "$out" | jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + [{key:$k,value:$v,actor:"api"}]')
  done
  printf '%s' "$out" > "$T/rows.json"
}
# flagrow <active> <updated_at> — the pause_flags row GET /api/flags answers.
flagrow() {
  FLAG_MODE=row
  jq -nc --arg a "$1" --arg u "$2" '{flag:{name:"x",active:($a|tonumber? // $a),updated_at:$u}}' > "$T/flagrow.json"
}
reset() {
  scratch_rm "$T/h/state/lane-gate"
  rm -f "$T/h/logs/lane-gate.log" "$T/h/state/settings-cache.json" "$T/h/flags"/* "$T/rows.json" "$T/posts"
  : > "$T/calls"; : > "$T/posts"; printf '[]' > "$T/rows.json"
  FLAG_MODE=none; POST_FAIL=""; AT="$NOW"
  install_client
}
file() { touch -d "@$FILE_T" "$T/h/flags/$1"; }
snap() { (cd "$T/h/flags" && find . -mindepth 1 -printf '%P %T@\n' | sort); }

# ask <name> — one read in a cold child shell; prints `rc=<n> src=<where>`. The
# settings cache is dropped first so every read loads the client, as a read
# whose cache has expired does.
ask() {
  rm -f "$T/h/state/settings-cache.json" "$T/h/state/lane-gate/.settings-miss"
  env HARNESS="$T/h" LANE_GATE_NOW="$AT" CALLS="$T/calls" ROWS_FILE="$T/rows.json" \
      FLAG_MODE="$FLAG_MODE" FLAG_ROW="$T/flagrow.json" POSTS="$T/posts" POST_FAIL="$POST_FAIL" \
      FLAGS_LIB="$FLAGS_LIB" JOBS_BOX=hub-1 \
      bash -c '
        set -uo pipefail
        . "$HARNESS/bin/lib/lane-switch.sh" || exit 9
        lane_switch "$1"; rc=$?
        echo "rc=$rc src=${LANE_SWITCH_SRC:-unset}"' _ "$1" 2>/dev/null
}
# L5's invariant: every L case leaves flags/ exactly as it found it.
same() { # same <label> <before>
  local after; after=$(snap)
  if [ "$2" = "$after" ]; then ok; else bad "$1: flags/ changed: before='$2' after='$after'"; fi
}
posts_on()  { grep -c '"active":1' "$T/posts"; }
posts_off() { grep -c '"active":0' "$T/posts"; }
marker() { [ -f "$T/h/state/lane-gate/.seen-$1" ] && echo yes || echo no; }

# L1 / S1 — no row anywhere, file present.
reset; file x-off; B=$(snap)
eq "L1 no rows + file" "$(ask x-off)" "rc=0 src=legacy-file"
same "L1" "$B"
eq "S1 one flag-seen post" "$(wc -l < "$T/posts" | tr -d ' ')" "1"
eq "S1 the post names the switch, the box, active 1" \
  "$(jq -c '{name,box,active}' "$T/posts" 2>/dev/null)" '{"name":"x-off","box":"hub-1","active":1}'
eq "S1 marker written" "$(marker x-off)" "yes"
eq "S1 marker holds the time" "$(tr -dc '0-9' 2>/dev/null < "$T/h/state/lane-gate/.seen-x-off")" "$NOW"

# S2 — a second read inside the hourly throttle: asked, but nothing posted.
AT=$((NOW+120))
eq "S2 still on" "$(ask x-off)" "rc=0 src=legacy-file"
eq "S2 the flags row was asked twice" "$(grep -c '^GET /api/flags/x-off$' "$T/calls")" "2"
eq "S2 no second post" "$(wc -l < "$T/posts" | tr -d ' ')" "1"

# L2 — nothing anywhere.
reset; B=$(snap)
eq "L2 no rows, no file" "$(ask x-off)" "rc=1 src=legacy-file"
same "L2" "$B"
eq "L2 no post" "$(wc -l < "$T/posts" | tr -d ' ')" "0"

# L3 / S6 — a pause_flags row active=1 with no file: on, and the file is NOT made.
reset; flagrow 1 "$NEW_ROW"; B=$(snap)
eq "L3 flags row 1, no file" "$(ask x-off)" "rc=0 src=legacy-row"
[ ! -e "$T/h/flags/x-off" ] && ok || bad "L3 the resolver created flags/x-off (it must never write flags/)"
same "L3" "$B"
eq "S6 a pause_flags row deciding posts no active:1" "$(posts_on)" "0"
reset; flagrow 1 "$NEW_ROW"; file x-off; B=$(snap)
eq "L3b flags row 1 + file" "$(ask x-off)" "rc=0 src=legacy-row"
same "L3b" "$B"
eq "S6b row 1 + file posts no active:1" "$(posts_on)" "0"

# L4 / S3 — outage: the file decides, and nobody is told anything.
reset; FLAG_MODE=down; file x-off; B=$(snap)
eq "L4 outage + file" "$(ask x-off)" "rc=0 src=legacy-file"
same "L4" "$B"
eq "S3 outage posts nothing" "$(wc -l < "$T/posts" | tr -d ' ')" "0"
eq "S3 outage writes no marker" "$(marker x-off)" "no"
rm -f "$T/h/flags/x-off"
eq "L4 outage, no file" "$(ask x-off)" "rc=1 src=legacy-file"

# L5 — row 0 newer than the file: off, file untouched. Row 0 older: on + sighting.
reset; flagrow 0 "$NEW_ROW"; file x-off; B=$(snap)
eq "L5 row 0 newer than the file" "$(ask x-off)" "rc=1 src=legacy-row"
[ -f "$T/h/flags/x-off" ] && ok || bad "L5 the resolver deleted flags/x-off (it must never write flags/)"
same "L5 newer row" "$B"
eq "L5 newer row posts no active:1" "$(posts_on)" "0"
reset; flagrow 0 "$OLD_ROW"; file x-off; B=$(snap)
eq "L5 row 0 older than the file" "$(ask x-off)" "rc=0 src=legacy-file"
same "L5 older row" "$B"
eq "L5 older row: the file decided, one sighting" "$(posts_on)" "1"
reset; flagrow 0 "$NEW_ROW"
eq "L5 row 0, no file" "$(ask x-off)" "rc=1 src=legacy-row"

# L6 — no jobs client: the file decides, both ways, and nothing is posted.
reset; rm -f "$T/h/bin/jobs-client.sh"; file x-off; B=$(snap)
eq "L6 no client + file" "$(ask x-off)" "rc=0 src=legacy-file"
same "L6" "$B"
rm -f "$T/h/flags/x-off"
eq "L6 no client, no file" "$(ask x-off)" "rc=1 src=legacy-file"

# L7 — the operator's cost-autohalt-off keeps its meaning with no row behind it.
reset; file cost-autohalt-off
eq "L7 cost-autohalt-off file, no rows" "$(ask cost-autohalt-off)" "rc=0 src=legacy-file"

# L8 — a flags row nobody can read is a non-action: the file decides, no post.
reset; flagrow null "$NEW_ROW"
eq "L8 unreadable active, no file" "$(ask x-off)" "rc=1 src=legacy-file"
file x-off; B=$(snap)
eq "L8 unreadable active + file" "$(ask x-off)" "rc=0 src=legacy-file"
same "L8" "$B"
reset; flagrow 1 "yesterday"
eq "L8 unreadable updated_at, no file" "$(ask x-off)" "rc=1 src=legacy-file"
eq "L8 unreadable rows post nothing" "$(wc -l < "$T/posts" | tr -d ' ')" "0"

# S4 — a settings row answering is not a sighting; it clears an old one.
reset; rows switch.x-off=0; file x-off
eq "S4 settings row 0 + file" "$(ask x-off)" "rc=1 src=fleet-row"
eq "S4 no active:1 post" "$(posts_on)" "0"
eq "S4 no marker, no request" "$(wc -l < "$T/posts" | tr -d ' ')" "0"
mkdir -p "$T/h/state/lane-gate"; echo "$NOW" > "$T/h/state/lane-gate/.seen-x-off"
ask x-off >/dev/null
eq "S4 an old sighting is cleared with one active:0 post" "$(posts_off)" "1"
eq "S4 the marker is gone" "$(marker x-off)" "no"
# The same clear once the file stops deciding (no rows, no file).
reset; mkdir -p "$T/h/state/lane-gate"; echo "$NOW" > "$T/h/state/lane-gate/.seen-x-off"
eq "S4b no rows, no file" "$(ask x-off)" "rc=1 src=legacy-file"
eq "S4b the stale sighting is cleared" "$(posts_off)/$(marker x-off)" "1/no"

# S5 — the worker refuses the sighting: no marker, the switch still answers on.
reset; POST_FAIL=1; file x-off
eq "S5 POST 500, answer unchanged" "$(ask x-off)" "rc=0 src=legacy-file"
eq "S5 the post was attempted" "$(wc -l < "$T/posts" | tr -d ' ')" "1"
eq "S5 no marker for a post that did not land" "$(marker x-off)" "no"

echo "switch-legacy-sighting.bh-2412: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
