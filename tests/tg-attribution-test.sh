#!/usr/bin/env bash
# Telegram sender/topic attribution (2026-08-31): the chat handler's ATTRIB
# header + meta sidecar must carry who sent a group message and which topic it
# landed in, and must stay EMPTY for the old payload shape (dash/web chat).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok(){ [ "$2" = "$3" ] && { PASS=$((PASS+1)); } || { FAIL=$((FAIL+1)); echo "FAIL $1: want [$3] got [$2]"; }; }
SRC=$(dirname "$0")/../bin/poll-commands.sh
# the block under test, lifted verbatim from the handler
BLOCK=$(awk '/# Telegram group attribution \(2026-08-31\)/,/^        ATTRIB=/' "$SRC")
BLOCK="$BLOCK
fi"
[ -n "$BLOCK" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: attribution block not found"; }
TOPICS=$(mktemp); printf '%s' '{"project-1":4,"project-2":5,"project-3":6,"project-4":7,"Alerts":8,"Fleet":9}' > "$TOPICS"
run(){ PAYLOAD="$1" bash -c "$(printf %s "$BLOCK" | sed "s#/root/harness/state/telegram-topics.json#$TOPICS#g"); printf %s \"\$ATTRIB\""; }
GROUP='{"text":"fix it","chat_id":"-1000000000000","thread_id":"6","chat_type":"supergroup","from_id":1,"from_name":"collaborator-1","from_username":"collaborator-1"}'
ok topic_named "$(run "$GROUP")" '[telegram: from collaborator-1 (@collaborator-1), topic project-3 — a full-authority principal of the the operator Harness group]'
NOTHREAD='{"text":"hi","chat_id":"-1000000000000","thread_id":null,"from_name":"the operator","from_username":"operator"}'
ok general_no_topic "$(run "$NOTHREAD")" '[telegram: from the operator (@operator) — a full-authority principal of the the operator Harness group]'
ok old_shape_empty "$(run '{"text":"hi","origin":"dash"}')" ''
ok unknown_thread "$(run '{"text":"x","thread_id":"99","from_name":"reviewer-1"}')" '[telegram: from reviewer-1 — a full-authority principal of the the operator Harness group]'
# --- BH-618: the header and the sidecar both carry the transport -------------
# A WIDER lift of the same handler — through the sidecar write — so the header
# string and the .meta transport field are both the shipped code, not a copy.
BLOCK2=$(awk '/# Telegram group attribution \(2026-08-31\)/,/> "\$MSGF\.meta"/' "$SRC")
BLOCK2="$BLOCK2
fi"
grep -q 'MSGF.meta' <<<"$BLOCK2" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: wider attribution+sidecar block not found"; }
run2(){ # run2 <payload> <msgfile> -> ATTRIB   (and writes <msgfile>.meta)
  PAYLOAD="$1" MSGF="$2" ID=cmd-9 bash -c "$(printf %s "$BLOCK2" | sed "s#/root/harness/state/telegram-topics.json#$TOPICS#g"); printf %s \"\$ATTRIB\""
}
SLCH='{"text":"ship it","transport":"slack","chat_id":"C09ABC","thread_id":"1726512345.001","from_name":"the operator","channel_name":"harness"}'
SLDM='{"text":"ship it","transport":"slack","chat_id":"D09XYZ","from_name":"the operator"}'
ok slack_channel "$(run2 "$SLCH" "$T/m1")" '[slack: from the operator, #harness — a full-authority principal of the the operator Harness group]'
ok slack_dm      "$(run2 "$SLDM" "$T/m2")" '[slack: from the operator — a full-authority principal of the the operator Harness group]'
# The Telegram header is not disturbed by the wider lift...
ok telegram_wide "$(run2 "$GROUP" "$T/m3")" '[telegram: from collaborator-1 (@collaborator-1), topic project-3 — a full-authority principal of the the operator Harness group]'
# ...and the sidecar now says which front door the question came through. A
# payload with no transport is a Telegram payload, which is every payload the
# console has ever sent.
ok meta_slack    "$(jq -r .transport "$T/m1.meta")" slack
ok meta_telegram "$(jq -r .transport "$T/m3.meta")" telegram
ok meta_chat     "$(jq -r .chat_id "$T/m1.meta")" C09ABC
ok meta_thread   "$(jq -r .thread_id "$T/m1.meta")" 1726512345.001

rm -f "$TOPICS"
echo "tg-attribution-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
