#!/bin/bash
# tests/tg-reply-origin-test.sh — a reply goes back where the question came from.
#
# THE INCIDENT THIS PINS (2026-09-01). After the fleet moved to a Telegram forum
# group, the operator asked the orchestrator a question in his DM and the answer appeared
# in the group's General topic — addressed to a chat he was not looking at, in
# front of a room, and with no error anywhere.
#
# poll-commands.sh had been writing chat_id/thread_id into the turn's `.meta`
# sidecar all along. This lane simply never read them: every reply went to the
# single configured TELEGRAM_CHAT_ID. The bug was not a missing capability, it
# was a capability nobody connected.
#
# The rule: the destination is a property of the QUESTION, never of the config.
#
# Run from anywhere: tests/tg-reply-origin-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# Run the lane's REAL destination-resolution lines, extracted verbatim, rather
# than a paraphrase of them — a copy here could agree with itself while the
# shipped script did something else entirely.
BLOCK=$(sed -n '/^TG_TO=/,/^\[ -n "\$TG_THREAD" \] && TG_THREAD_ARG=/p' "$DIR/bin/orchestrate.sh")
[ -n "$BLOCK" ] && ok || bad "could not extract the destination block from orchestrate.sh"

# THE BLOCK IS RUN, NOT READ — so it must be run against nothing real. Since
# BH-437 the lifted lines source "${HARNESS:-}/bin/jobs-client.sh" whenever that
# file is readable, and `bash -c` inherits this process's whole environment. On
# every box the harness itself drives (run-build.sh validate, cron, a session)
# HARNESS=/root/harness is exported, so without a pin this unit test would load
# the REAL coordination client and call it with the box's real secret against
# the production worker. HARNESS points at an empty dir, which makes the block's
# own `[ ! -r "$HARNESS/bin/jobs-client.sh" ]` guard true by construction, and
# TG_TOPICS_FILE points into the same dir so no run can read the box's real
# state file either. tests/telegram-topics-sync-test.sh (C7) pins this.
SANDBOX="$T"

resolve() { # resolve <meta_chat> <meta_thread> <configured_chat> -> "<to>|<thread>"
  META_CHAT="$1" META_THREAD="$2" TELEGRAM_CHAT_ID="$3" \
  HARNESS="$SANDBOX" TG_TOPICS_FILE="$SANDBOX/topics.json" bash -c "
    set -uo pipefail
    META_CHAT=\"\$META_CHAT\"; META_THREAD=\"\$META_THREAD\"
    $BLOCK
    printf '%s|%s' \"\$TG_TO\" \"\$TG_THREAD\"
  "
}

GROUP=-1000000000000
DM=100000000

# 1. THE BUG. A DM question must be answered in the DM.
R=$(resolve "$DM" "" "$GROUP")
[ "$R" = "$DM|" ] && ok || bad "a DM question must be answered in the DM, not the configured group (got '$R')"

# 2. A topic question is answered in that topic.
R=$(resolve "$GROUP" "6" "$GROUP")
[ "$R" = "$GROUP|6" ] && ok || bad "a topic question must be answered in its topic (got '$R')"

# 3. General (no thread) stays General — the path that already worked must not move.
R=$(resolve "$GROUP" "" "$GROUP")
[ "$R" = "$GROUP|" ] && ok || bad "a General question must stay in General (got '$R')"

# 4. No sidecar at all (a cron beat, an older poller) falls back to the config.
R=$(resolve "" "" "$GROUP")
[ "$R" = "$GROUP|" ] && ok || bad "with no origin the configured chat is still the destination (got '$R')"

# 5. jq writes the string "null" for a missing field, and Telegram rejects that
#    as a thread id. It must read as "no thread", not as a literal.
R=$(resolve "$GROUP" "null" "$GROUP")
[ "$R" = "$GROUP|" ] && ok || bad "a literal 'null' thread id must be treated as absent (got '$R')"

# 6. A thread id is meaningless outside the chat it came from. Carrying the
#    group's topic id into a DM reply is a Telegram error, and the honest
#    failure mode is to drop the thread rather than the answer.
R=$(resolve "$DM" "6" "$GROUP")
[ "$R" = "$DM|" ] && ok || bad "a thread id must not survive into a different chat (got '$R')"

# 7. The extracted block must actually be WIRED to the sends. Resolution that
#    nothing uses is precisely the shape of the original bug: poll-commands
#    supplied the fields, and the sends ignored them.
SENDS=$(grep -c 'sendMessage" "${TG_THREAD_ARG\[@\]}" --data-urlencode "chat_id=$TG_TO"' "$DIR/bin/orchestrate.sh")
[ "${SENDS:-0}" -ge 2 ] && ok || bad "both sendMessage paths (HTML and the plain-text retry) must address the resolved destination (found $SENDS)"
! grep -q 'chat_id=\$TELEGRAM_CHAT_ID' "$DIR/bin/orchestrate.sh" \
  && ok || bad "no send may still address the configured chat directly"
# The typing indicator and voice notes are outbound too — they belong in the
# same conversation, or the DM shows an answer with no sign it was working.
grep -q 'sendChatAction" -d "chat_id=$TG_TO"' "$DIR/bin/orchestrate.sh" \
  && ok || bad "the typing indicator must go to the originating chat"
grep -q 'sendVoice" -F "chat_id=$TG_TO"' "$DIR/bin/orchestrate.sh" \
  && ok || bad "a voice reply must go to the originating chat"

# ---------------------------------------------------------------------------
# BH-618: the thread travels with EVERY outbound call, not just sendMessage.
# sendVoice and sendChatAction carried no message_thread_id, so a question asked
# in a topic got its typing indicator and its spoken answer in General — a
# different room from the one the asker was looking at. Same rule as above: the
# destination is a property of the question, and that has to hold for all three
# kinds of send, not only the one that was fixed first.
# ---------------------------------------------------------------------------
DEST=$(sed -n '/^TG_TO=/,/^\[ -n "\$TG_THREAD" \] && TG_THREAD_FORM=/p' "$DIR/bin/orchestrate.sh")
VOICE=$(sed -n '/^say_voice() {/,/^}/p' "$DIR/bin/orchestrate.sh")
TYPING=$(sed -n '/^tg_typing_once() {/,/^}/p' "$DIR/bin/orchestrate.sh")
{ [ -n "$DEST" ] && [ -n "$VOICE" ] && [ -n "$TYPING" ]; } && ok \
  || bad "could not lift the destination block, say_voice and tg_typing_once from orchestrate.sh"

outbound() { # outbound <meta_chat> <meta_thread> -> the fake curl log
  local c="$T/out-$1-${2:-none}"
  rm -rf "$T/out-$1-${2:-none}"
  mkdir -p "$c/bin" "$c/logs" "$c/fake"
  cat > "$c/fake/curl" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$CURL_LOG"
echo '{"ok":true}'
FAKE
  cat > "$c/bin/tts-say.sh" <<'FAKE'
#!/bin/bash
cat >/dev/null
printf 'ogg\n' > "$2"
FAKE
  chmod +x "$c/fake/curl" "$c/bin/tts-say.sh"
  META_CHAT="$1" META_THREAD="$2" TELEGRAM_CHAT_ID="$GROUP" HARNESS="$c" \
  PATH="$c/fake:$PATH" CURL_LOG="$c/curl.log" TG_TOPICS_FILE="$c/topics.json" \
  bash -c "
    set -uo pipefail
    META_CHAT=\"\$META_CHAT\"; META_THREAD=\"\$META_THREAD\"
    $DEST
    TG=https://api.telegram.org/botTESTTOKEN
    TG_OK=1
    $VOICE
    $TYPING
    say_voice 'spoken answer'
    tg_typing_once
  " >/dev/null 2>&1
  cat "$c/curl.log" 2>/dev/null
}

LOG=$(outbound "$GROUP" 6)
[ "$(grep -c 'sendVoice.*message_thread_id=6' <<<"$LOG")" = 1 ] && ok \
  || bad "a voice reply must be sent into the topic that asked (log: $LOG)"
[ "$(grep -c 'sendChatAction.*message_thread_id=6' <<<"$LOG")" = 1 ] && ok \
  || bad "the typing indicator must be shown in the topic that asked (log: $LOG)"

LOG=$(outbound "$DM" "")
[ "$(grep -c 'message_thread_id' <<<"$LOG")" = 0 ] && ok \
  || bad "a DM has no topics, so no send may carry a thread id (log: $LOG)"
[ "$(grep -c 'sendVoice' <<<"$LOG")" = 1 ] && ok \
  || bad "the DM voice reply must still be sent (log: $LOG)"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
