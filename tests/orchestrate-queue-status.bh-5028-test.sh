#!/bin/bash
# tests/orchestrate-queue-status.bh-5028-test.sh — a console chat's command row
# says where its turn is (BH-5028 / BH-4995.1): queued_behind:<running id> while
# every turn slot is taken (BH-5336: ORC_TURN_CONCURRENCY, here 1), running:<iso>
# once the gate admits it, then answered:<iso>. And the poller acks `handed to orchestrator` BEFORE it spawns
# the turn, so that ack can never land on top of the turn's own status.
#
# bin/orchestrate.sh pins HARNESS=/root/harness and ORC=/root/orchestrator, so
# the turn is assembled from production blocks lifted VERBATIM: the real
# bin/lib/orc-reply-ledger.sh, bin/lib/orc-turns.sh, `# >>> turn queue status`,
# `# >>> reply status` and `# >>> turn done`. Q4 lifts bin/poll-commands.sh's `# >>> chat handler`, `# >>> command
# ack` and `# >>> chat spawn after ack` in the order the loop runs them.
#
# M1/M2 mutate the lifted text and require the case that pins it to go red.
#
# TEST-CHANGE (BH-5336): L0/Q1/Q3/Q5/M1 pinned `flock 6` and .turn.running,
# which BH-5336 removed. The holder is now a live seeded claim in
# $ORC/state/turns/ with the cap at 1; Q5 pins that a stale claim is never
# reported and that a stale claim for the same command is reclaimed.
#
# Run from anywhere: tests/orchestrate-queue-status.bh-5028-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

SRC="$DIR/bin/orchestrate.sh"
POLL="$DIR/bin/poll-commands.sh"
QUEUE_BLOCK=$(sed -n '/^# >>> turn queue status/,/^# <<< turn queue status/p' "$SRC")
STATUS_BLOCK=$(sed -n '/^# >>> reply status/,/^# <<< reply status/p' "$SRC")
DONE_BLOCK=$(sed -n '/^# >>> turn done/,/^# <<< turn done/p' "$SRC")
HANDLER_BLOCK=$(sed -n '/^    # >>> chat handler/,/^    # <<< chat handler/p' "$POLL")
ACK_BLOCK=$(sed -n '/^    # >>> command ack/,/^    # <<< command ack/p' "$POLL")
SPAWN_BLOCK=$(sed -n '/^    # >>> chat spawn after ack/,/^    # <<< chat spawn after ack/p' "$POLL")
iso='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z'

# --- L0: the lifts are real and sit where the scripts run them --------------
grep -q '^orct_claim ' <<<"$QUEUE_BLOCK" && grep -q '^ *orct_gate ' <<<"$QUEUE_BLOCK" && grep -q 'cmd_status "running:' <<<"$QUEUE_BLOCK" \
  && ok || bad "L0 the queue-status block must claim, wait at the gate, then post running"
eq L0_no_turn_lock "$(grep -c 'flock 6\|\.turn\.lock' <<<"$QUEUE_BLOCK")" 0
grep -q 'cmd_status' <<<"$STATUS_BLOCK" && ok || bad "L0 the reply-status block is missing"
grep -q 'ORC_SPAWN="\$MSGF"' <<<"$HANDLER_BLOCK" && ok || bad "L0 the plain-text chat handler must defer its spawn to ORC_SPAWN"
grep -q 'orchestrate.sh' <<<"$SPAWN_BLOCK" && ok || bad "L0 the spawn-after-ack block is missing"
# The spawn runs after the ack: main's merge_pr key release (BH-4917) holds the
# slot right after the ack, so the spawn block follows that block directly.
eq L0_spawn_follows_ack "$(grep -A1 '^    # <<< merge_pr key release' "$POLL" | sed -n 2p)" "    # >>> chat spawn after ack (tests/orchestrate-queue-status.bh-5028-test.sh runs this block)"
L0_AL=$(grep -n '^    # <<< command ack' "$POLL" | cut -d: -f1); L0_SL=$(grep -n '^    # >>> chat spawn after ack' "$POLL" | cut -d: -f1)
[ -n "$L0_AL" ] && [ -n "$L0_SL" ] && [ "$L0_AL" -lt "$L0_SL" ] && ok || bad "L0 the spawn block must run after the ack (ack line $L0_AL, spawn line $L0_SL)"
eq L0_spawn_reset_at_loop_top "$(grep -A1 '^  OK=false; RESULT=""; OUTCOME=""$' "$POLL" | sed -n 2p)" '  ORC_SPAWN=""'

setup() { # setup <name> -> prints the case dir
  local c="$T/$1"
  scratch_rm "$c" || return 1; mkdir -p "$c/bin" "$c/logs" "$c/fake" "$c/orc"
  cat > "$c/fake/curl" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$CURL_LOG"
case " $* " in *" @- "*) printf 'BODY %s\n' "$(cat)" >> "$CURL_LOG" ;; esac
FAKE
  printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "$BEATS"\n' > "$c/bin/beat.sh"
  chmod +x "$c/fake/curl" "$c/bin/beat.sh"
  scratch_install_closure bin/lib/orc-reply-ledger.sh "$c" >/dev/null || echo "setup: cannot install the ledger lib" >&2
  scratch_install_closure bin/lib/orc-turns.sh "$c" >/dev/null || echo "setup: cannot install the turns lib" >&2
  printf '%s' "$c"
}

# turn <dir> <cmd-id> — the gate section and the reply tail of one turn.
# M_QUEUE lets a mutant replace the queue-status block.
turn() {
  local c="$1"
  env -u HARNESS_ENV_DIR \
  PATH="$c/fake:$PATH" CURL_LOG="$c/curl.log" BEATS="$c/beats.jsonl" \
  HARNESS="$c" ORC="$c/orc" CMD_ID="$2" CONSOLE_URL=https://console.example HARNESS_SECRET=s3cret \
  ORC_REPLY_LEDGER_BACKOFF_S=0 ORC_TURN_CONCURRENCY=1 ORC_TURN_POLL_S=0.2 \
  bash -c "
    set -uo pipefail
    . \"\$HARNESS/bin/lib/orc-reply-ledger.sh\"
    TEXT='the question'
    ${M_QUEUE-$QUEUE_BLOCK}
    echo \"\$CMD_ID\" >> \"\$HARNESS/ran\"
    ledger_reply 'the answer'
    $STATUS_BLOCK
    $DONE_BLOCK
    exit 0
  " 2>>"$c/stderr.log"
}
acks() { sed -n 's/^BODY //p' "$1/curl.log" 2>/dev/null | jq -r 'select(.result != null) | .result'; }
# holder <dir> <id> — another turn RUNNING (a live claim, touched like the
# heartbeat touches it) until $c/release exists; then it ends like orct_done.
holder() {
  local c="$1" f="$1/orc/state/turns/c$2.json"
  mkdir -p "$c/orc/state/turns"
  jq -nc --arg id "$2" --argjson at "$(( $(date +%s%3N) - 5000 ))" \
    '{key:("c"+$id), command_id:$id, state:"running", arrived_at:$at, chat_id:"", thread_id:"", message_id:"", message_ts:"", reply_to:"", head:"a long turn"}' > "$f"
  ( : > "$c/held"; until [ -f "$c/release" ]; do touch "$f"; sleep 0.05; done; rm -f "$f" ) &
  HOLDER=$!
  local i=0; while [ ! -f "$c/held" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
}
waitfor() { local i=0; while [ "$i" -lt 100 ]; do grep -q -- "$2" "$1" 2>/dev/null && return 0; sleep 0.05; i=$((i+1)); done; return 1; }

# q1 <dir> — the Q1 scenario; leaves $c/seen-while-held = yes|no
q1() {
  local c="$1"
  holder "$c" 21105
  turn "$c" 21118 & local tp=$!
  if waitfor "$c/curl.log" 'queued_behind:21105'; then
    # The other turn still runs at the moment the status is visible.
    if [ -f "$c/orc/state/turns/c21105.json" ] && [ ! -f "$c/release" ]; then echo yes > "$c/seen-while-held"; else echo no > "$c/seen-while-held"; fi
  else echo no > "$c/seen-while-held"; fi
  [ -f "$c/ran" ] && echo early > "$c/ran-before-release"
  : > "$c/release"; wait "$HOLDER" 2>/dev/null; wait "$tp" 2>/dev/null
}

# --- Q1: queued behind 21105 — queued_behind, then running, then answered ---
C=$(setup q1); q1 "$C"
eq Q1_seen_while_held "$(cat "$C/seen-while-held")" yes
eq Q1_waited_for_slot "$(cat "$C/ran-before-release" 2>/dev/null)" ""
eq Q1_count     "$(acks "$C" | wc -l)" 3
eq Q1_first     "$(acks "$C" | sed -n 1p)" "queued_behind:21105"
acks "$C" | sed -n 2p | grep -Eq "^running:$iso\$" && ok || bad "Q1 second ack must be running:<iso>, got [$(acks "$C" | sed -n 2p)]"
acks "$C" | sed -n 3p | grep -Eq "^answered:$iso\$" && ok || bad "Q1 third ack must be answered:<iso>, got [$(acks "$C" | sed -n 3p)]"
grep -c 'https://console.example/api/commands/21118/ack' "$C/curl.log" | grep -qx 3 && ok || bad "Q1 every ack must go to command 21118"

# --- Q2: a slot is free — running then answered, no queued_behind -----------
C=$(setup q2); turn "$C" 21118
eq Q2_count     "$(acks "$C" | wc -l)" 2
acks "$C" | sed -n 1p | grep -Eq "^running:$iso\$" && ok || bad "Q2 first ack must be running:<iso>"
acks "$C" | sed -n 2p | grep -Eq "^answered:$iso\$" && ok || bad "Q2 second ack must be answered:<iso>"

# --- Q3: ORC_CMD_STATUS=0 — no ack at all, the beat still lands -------------
C=$(setup q3); holder "$C" 21105
ORC_CMD_STATUS=0 turn "$C" 21118 & TP=$!
sleep 0.3; : > "$C/release"; wait "$HOLDER" 2>/dev/null; wait "$TP" 2>/dev/null
eq Q3_no_ack    "$(cat "$C/curl.log" 2>/dev/null | grep -c /ack)" 0
eq Q3_beat      "$(grep -c '"kind":"chat_reply"' "$C/beats.jsonl")" 1

# --- Q5: a stale claim is never reported, and is reclaimed ------------------
# Another command's claim with no heartbeat for 10 minutes takes no slot.
C=$(setup q5); mkdir -p "$C/orc/state/turns"
printf '{"key":"c21000","command_id":"21000","state":"running","arrived_at":1}' > "$C/orc/state/turns/c21000.json"
touch -d '-10 min' "$C/orc/state/turns/c21000.json"
turn "$C" 21118
eq Q5_no_queued "$(acks "$C" | grep -c '^queued_behind')" 0
eq Q5_ran       "$(cat "$C/ran" 2>/dev/null)" 21118
eq Q5_answered  "$(acks "$C" | grep -c '^answered:')" 1
# A stale claim for THIS command (its turn died) is taken over: the turn runs.
C=$(setup q5b); mkdir -p "$C/orc/state/turns"
printf '{"key":"c21118","command_id":"21118","state":"running","arrived_at":1}' > "$C/orc/state/turns/c21118.json"
touch -d '-10 min' "$C/orc/state/turns/c21118.json"
turn "$C" 21118
eq Q5b_reclaimed "$(cat "$C/ran" 2>/dev/null)" 21118
eq Q5b_done      "$( [ -f "$C/orc/state/turns/c21118.done" ] && echo yes)" yes

# --- Q4: the poller acks the chat command BEFORE it spawns the turn ---------
# The stub ack takes 0.3 s and the stub orchestrator logs at once, so a spawn
# launched before the ack shows up first in the order log.
pollrun() { # pollrun <dir> <handler-block>
  local c="$1"
  mkdir -p "$c/orchestrator/inbox"
  printf '#!/bin/bash\necho spawn >> "%s/order"\n' "$c" > "$c/bin/orchestrate.sh"; chmod +x "$c/bin/orchestrate.sh"
  printf '%s\n' "$2" | sed "s|/root/orchestrator|$c/orchestrator|g" > "$c/handler.sh"
  printf '%s\n' "$ACK_BLOCK" > "$c/ack.sh"; printf '%s\n' "$SPAWN_BLOCK" > "$c/spawn.sh"
  HARNESS="$c" BEAT="$c/bin/beat.sh" BEATS="$c/beats.jsonl" CONSOLE_URL=https://console.example C="$c" \
  bash -c 'set -uo pipefail
    API() { sleep 0.3; echo ack >> "$C/order"; }
    ID=21118; TYPE=chat; PROJECT=orchestrator; PAYLOAD="{\"text\":\"hi\",\"origin\":\"dash\"}"
    OK=false; RESULT=""; OUTCOME=""
    ORC_SPAWN=""
    eval "case \"\$TYPE\" in $(cat "$C/handler.sh")
    esac"
    . "$C/ack.sh"
    . "$C/spawn.sh"
    echo "$RESULT" > "$C/result"' 2>>"$c/stderr.log"
  waitfor "$c/order" spawn
}
C=$(setup q4); pollrun "$C" "$HANDLER_BLOCK"
eq Q4_order     "$(cat "$C/order" 2>/dev/null | tr '\n' ' ')" "ack spawn "
eq Q4_result    "$(cat "$C/result" 2>/dev/null)" "handed to orchestrator"

# --- M1: no gate — Q1 goes red ----------------------------------------------
C=$(setup m1)
M_QUEUE=$(sed '/^ *orct_gate /d' <<<"$QUEUE_BLOCK") q1 "$C"
[ "$(acks "$C" | sed -n 1p)" != "queued_behind:21105" ] && ok || bad "M1 removing the gate must turn Q1 red"

# --- M2: the spawn back inside the handler — Q4 goes red --------------------
C=$(setup m2)
pollrun "$C" "$(sed 's|ORC_SPAWN="\$MSGF"|(setsid "$HARNESS/bin/orchestrate.sh" "$MSGF" </dev/null >/dev/null 2>\&1 \&)|' <<<"$HANDLER_BLOCK")"
sleep 0.4
[ "$(cat "$C/order" 2>/dev/null | tr '\n' ' ')" != "ack spawn " ] && ok || bad "M2 spawning inside the handler must turn Q4 red"

echo "orchestrate-queue-status (BH-5028): $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
