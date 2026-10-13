#!/bin/bash
# tests/merge-queue-conductor-verdict.bh-5914-test.sh — BH-5914: the per-box
# merge queue honours the merge conductor's per-PR, per-head verdict.
#
# THE INCIDENT (example-org/project-6 PR #27, 2026-10-10). The conductor on the
# hub logged at 08:06:01Z "not merged this tick: the diff read was
# UNVERIFIABLE so the iron-law scan NOT run" for head 1d1e4640. At 08:06:21Z
# bin/merge-queue.sh on box-project-6-os-1 merged the same head over REST
# ("[merge-queue #27] rung rest: merged"). Nothing on the box could see the
# conductor's refusal: it lived in the hub's state dir and log.
#
# The fix: the conductor writes its verdict for each READY head it scanned to
# the jobs ledger (kind mc-merge-verdict, key <slug>#<n>, status hold|clear,
# detail "<head> <reason>"), and mq_land asks it before every landing.
#
# Driven, not grepped: mq_land and the gate are extracted VERBATIM by their
# `# >>>` markers and run against stubs. The assertions are on the merge sink
# and the lane log.
#   V1 hold on THIS head (the #27 replay)  -> no merge, MERGE_REFUSED logged
#   V2 hold on ANOTHER head                -> merges
#   V3 clear on this head                  -> merges
#   V4 no row (404)                        -> merges (the conductor never judged it)
#   V5 the row cannot be read (worker down)-> merges, logged (the lane fails
#      open on a worker outage, as main-red-box-freeze Q3 pins)
#   V6 no pin and the head cannot be read  -> no merge, logged
#   V7 no ledger client on the box         -> merges (fail-open on absence)
#   V8 a short head in the row matches the full head (prefix, 7-char floor)
# Run from anywhere: tests/merge-queue-conductor-verdict.bh-5914-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }

MQ="$DIR/bin/merge-queue.sh"
awk '/^# >>> mq_land/{f=1;next} /^# <<< mq_land/{exit} f' "$MQ" > "$T/mqland.sh"
awk '/^# >>> conductor verdict gate/{f=1;next} /^# <<< conductor verdict gate/{exit} f' "$MQ" > "$T/gate.sh"
[ -s "$T/mqland.sh" ] && ok || bad "could not extract mq_land from bin/merge-queue.sh"
[ -s "$T/gate.sh" ] && ok || bad "could not extract the conductor verdict gate (# >>> conductor verdict gate) from bin/merge-queue.sh"

# The gate sources the shared rule from $HARNESS/bin/lib, as on a box. It
# sources nothing itself, so its closure is the one file.
( cd "$DIR" && scratch_install_closure bin/lib/conductor-verdict.sh "$T" ) >/dev/null \
  || { echo "FAIL: cannot install the closure of bin/lib/conductor-verdict.sh"; exit 1; }
SLUG=example-org/project-6
H27=1d1e4640426951a7912dd3089416843c2b41bb59
HOTHER=ffffeeee426951a7912dd3089416843c2b41bb59

# run_land <pin> — drive mq_land 27 <pin>. The stubs read:
#   $T/row.rc / $T/row.json   job_ledger_row's answer
#   $T/head                   mq_pr's .head.sha answer (absent = unreadable)
#   $T/noclient               present = no job_ledger_row on this box
# Merges land in $T/merges, the lane log in $T/mq.log.
run_land() {
  : > "$T/merges"; : > "$T/mq.log"; : > "$T/ledger-calls"
  ( cd "$T" && SLUG="$SLUG" PROJECT=project-6-os LOG="$T/mq.log" HARNESS="$T" T="$T" bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      hb_sha() { :; }
      mq_pr() { [ -s "$T/head" ] || return 75; cat "$T/head"; }
      mc_rest_status() { printf 403; }
      gh_pr_merge_rest() { printf "%s %s %s\n" "$1" "$2" "$3" >> "$T/merges"; printf "mergesha"; return 0; }
      if [ ! -e "$T/noclient" ]; then
        job_ledger_row() { printf "%s %s\n" "$1" "$2" >> "$T/ledger-calls"
          local rc; rc=$(cat "$T/row.rc"); [ "$rc" = 0 ] && cat "$T/row.json"; return "$rc"; }
      fi
      . "$T/gate.sh"
      . "$T/mqland.sh"
      mq_land 27 "$1"' _ "${1:-}" > "$T/land.out" 2>"$T/land.err" )
}
row() { # row <status> <detail>
  echo 0 > "$T/row.rc"; jq -nc --arg s "$1" --arg d "$2" '{status:$s, detail:$d}' > "$T/row.json"
}
rm -f "$T/noclient"; printf '%s' "$H27" > "$T/head"

# V1. the project-6 #27 replay: hold on this head
row hold "$H27 diff-unread: the diff read was UNVERIFIABLE (HTTP 406), iron-law scan NOT run"
run_land "$H27"
[ ! -s "$T/merges" ] && ok || bad "V1 a head the conductor holds must not be merged: $(cat "$T/merges")"
grep -q "MERGE_REFUSED conductor-verdict" "$T/mq.log" && grep -qF "${H27:0:8}" "$T/mq.log" && grep -q "diff-unread" "$T/mq.log" \
  && ok || bad "V1 the refusal must be logged with the head and the conductor's reason: $(cat "$T/mq.log")"
grep -qx "mc-merge-verdict $SLUG#27" "$T/ledger-calls" && ok || bad "V1 the gate must read kind mc-merge-verdict key $SLUG#27: $(cat "$T/ledger-calls")"
grep -q "^MERGED" "$T/land.out" && bad "V1 mq_land must print no MERGED line" || ok

# V2. hold on another head: this head was never refused
row hold "$HOTHER iron-law: 2 hit(s)"
run_land "$H27"
grep -q "^$SLUG 27 " "$T/merges" && ok || bad "V2 a hold on another head must not stop this head: $(cat "$T/mq.log")"

# V3. clear on this head
row clear "$H27 iron-law scan clean"
run_land "$H27"
grep -q "^$SLUG 27 $H27" "$T/merges" && ok || bad "V3 a cleared head must merge, pinned to it: $(cat "$T/merges") $(cat "$T/mq.log")"

# V4. no row: the conductor never judged this PR
echo 2 > "$T/row.rc"
run_land "$H27"
grep -q "^$SLUG 27 " "$T/merges" && ok || bad "V4 no verdict row must merge as before: $(cat "$T/mq.log")"

# V5. the row cannot be read: a worker outage. This lane fails open on one
# (main-red-box-freeze Q3), and the conductor could not have published a
# refusal through the same outage. The outage is logged.
echo 1 > "$T/row.rc"
run_land "$H27"
grep -q "^$SLUG 27 " "$T/merges" && ok || bad "V5 a worker outage must land as before: $(cat "$T/mq.log")"
grep -q "conductor verdict could not be read (ledger rc 1)" "$T/mq.log" && ok || bad "V5 the outage must be logged: $(cat "$T/mq.log")"

# V6. no pin, and the head cannot be read
row clear "$H27 iron-law scan clean"; rm -f "$T/head"
run_land ""
[ ! -s "$T/merges" ] && ok || bad "V6 an unreadable head must not merge: $(cat "$T/merges")"
grep -q "head could not be read" "$T/mq.log" && ok || bad "V6 the unreadable head must be logged: $(cat "$T/mq.log")"
# V6b. no pin, head readable, hold on it: the gate reads the head itself
printf '%s' "$H27" > "$T/head"; row hold "$H27 iron-law: 1 hit(s)"
run_land ""
[ ! -s "$T/merges" ] && ok || bad "V6b with no pin the gate must read the head and still refuse: $(cat "$T/merges")"

# V7. no ledger client on this box: fail-open on absence, as every gate here
: > "$T/noclient"
run_land "$H27"
grep -q "^$SLUG 27 " "$T/merges" && ok || bad "V7 a box with no ledger client must land as before: $(cat "$T/land.err")"
rm -f "$T/noclient"

# V8. the row carries a short head: prefix match, both ways, 7-char floor
row hold "${H27:0:8} iron-law: 1 hit(s)"
run_land "$H27"
[ ! -s "$T/merges" ] && ok || bad "V8 an 8-char head in the row must match the full head: $(cat "$T/merges")"
row hold "${H27:0:4} iron-law: 1 hit(s)"
run_land "$H27"
grep -q "^$SLUG 27 " "$T/merges" && ok || bad "V8b a 4-char stray string must not match"

echo "merge-queue-conductor-verdict.bh-5914: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
