#!/bin/bash
# tests/orc-reply-via-console-test.sh — the reply leaves the turn exactly once,
# by the route the question came in on (BH-618).
#
# WHAT THIS PINS. Until now every orchestrator reply went to api.telegram.org.
# A Slack question therefore had nowhere to land: the turn ran, the answer was
# written to last-reply.txt, and nobody ever saw it. flags/orc-reply-via-console
# hands text replies to the console instead, as one chat_reply beat carrying
# relay:true and the origin from the .meta sidecar.
#
# The two properties that matter, in both directions:
#   - flag ABSENT: the direct Telegram path, unchanged, plus (BH-4995.0) one
#     strict, non-relay chat_reply ledger beat for every turn with a command id,
#     whatever its origin (tests/orchestrate-reply-ledger.bh-4995-test.sh).
#   - flag PRESENT: one beat and ZERO Telegram calls for a relayed turn — and
#     when the beat does not land, an ALERTS line every time, plus the direct
#     send only where a direct send can actually reach the asker.
#
# Every block below is lifted VERBATIM from bin/orchestrate.sh (the `# >>> reply
# delivery` markers and the destination block) and the strict-mode section runs
# the REAL bin/beat.sh. A copy of the logic here could agree with itself while
# the shipped lane did something else.
#
# Run from anywhere: tests/orc-reply-via-console-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
cnt() { local n=0; [ -f "$1" ] && n=$(grep -c -- "$2" "$1"); echo "${n:-0}"; }

SRC="$DIR/bin/orchestrate.sh"
META_BLOCK=$(sed -n '/^ORIGIN=""; CMD_ID=""/,/^\[ "\$TG_OK" = 1 \]/p' "$SRC")
DEST_BLOCK=$(sed -n '/^TG_TO=/,/^\[ -n "\$TG_THREAD" \] && TG_THREAD_FORM=/p' "$SRC")
DELIVER_BLOCK=$(sed -n '/^# >>> reply delivery/,/^# <<< reply delivery/p' "$SRC")

# The lifts must be real, and they must be what the script RUNS — a block that
# nothing calls is the shape of the bug this ticket fixes.
grep -q 'RELAY=' <<<"$META_BLOCK" && ok || bad "the sidecar block must decide RELAY (lift from bin/orchestrate.sh is empty or stale)"
grep -q 'TG_THREAD_FORM=' <<<"$DEST_BLOCK" && ok || bad "the destination block must build TG_THREAD_FORM (lift is empty or stale)"
grep -q 'deliver_reply()' <<<"$DELIVER_BLOCK" && ok || bad "the reply-delivery block must define deliver_reply (# >>> reply delivery markers missing)"
grep -q '^deliver_reply "\$OUT"' "$SRC" && ok || bad "orchestrate.sh must send its reply through deliver_reply"

GROUP=-1000000000000
DM=100000000

# ---------------------------------------------------------------------------
# 1. The RELAY decision (sidecar block)
# ---------------------------------------------------------------------------
# decide <meta-json|-> <flag:on|off> <bot-token> -> "RELAY=x TRANSPORT=y", or
# "" when the block took its early exit (today's "Telegram unbound, stop here").
decide() {
  local meta="$1" flag="$2" tok="$3" c="$T/decide"
  rm -rf "$T/decide"; mkdir -p "$c/env" "$c/flags"
  scratch_install_closure bin/lib/orc-reply-ledger.sh "$c" >/dev/null || echo "decide: cannot install the ledger lib" >&2
  printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CHAT_ID=%s\n' "$tok" "$GROUP" > "$c/env/global.env"
  [ "$flag" = on ] && : > "$c/flags/orc-reply-via-console"
  printf 'the question\n' > "$c/msg"
  [ "$meta" = "-" ] || printf '%s\n' "$meta" > "$c/msg.meta"
  # The lifted block reads the env dir through $HENV (BH-455), which
  # bin/orchestrate.sh resolves in its prologue — ABOVE the first line this
  # test lifts. A lift that runs under `set -u` without that prologue dies on
  # `HENV: unbound variable` before it decides anything, so the subshell
  # reproduces the prologue verbatim instead of inlining a path. HARNESS_ENV_DIR
  # is cleared so an operator env cannot move the case's env dir out from under
  # it; $c/env exists, so harness_env_dir prints exactly $c/env.
  env -u HARNESS_ENV_DIR HARNESS="$c" MSGF="$c/msg" bash -c "
    set -uo pipefail
    HARNESS=\"\$HARNESS\"; MSGF=\"\$MSGF\"
    . \"$DIR/bin/lib/env-path.sh\"; HENV=\$(harness_env_dir \"\$HARNESS\")
    $META_BLOCK
    printf 'RELAY=%s TRANSPORT=%s' \"\$RELAY\" \"\$META_TRANSPORT\"
  "
}

eq no_sidecar        "$(decide - on tok)"  "RELAY=0 TRANSPORT=telegram"
eq slack_relays      "$(decide '{"command_id":"c1","origin":"","transport":"slack","chat_id":"C123","thread_id":"1726.55"}' on tok)" "RELAY=1 TRANSPORT=slack"
eq flag_off_no_relay "$(decide '{"command_id":"c1","origin":"","transport":"slack"}' off tok)" "RELAY=0 TRANSPORT=slack"
eq absent_is_telegram "$(decide '{"command_id":"c1","origin":""}' on tok)" "RELAY=1 TRANSPORT=telegram"
eq null_is_telegram  "$(decide '{"command_id":"c1","origin":"","transport":null}' on tok)" "RELAY=1 TRANSPORT=telegram"
eq explicit_telegram "$(decide '{"command_id":"c1","origin":"","transport":"telegram"}' on tok)" "RELAY=1 TRANSPORT=telegram"
# Adversarial: a transport but no command id. The console keys a chat_reply on
# the id it issued, so there is nothing to relay to — today's path, not a guess.
eq no_cmd_id_no_relay "$(decide '{"command_id":"","origin":"","transport":"slack"}' on tok)" "RELAY=0 TRANSPORT=slack"
# A web Mission Control turn keeps its own beat and its Telegram echo.
eq dash_no_relay     "$(decide '{"command_id":"c1","origin":"dash"}' on tok)" "RELAY=0 TRANSPORT=telegram"
# Telegram unbound: a Slack turn now has somewhere to go, so it runs...
eq slack_no_token    "$(decide '{"command_id":"c1","origin":"","transport":"slack"}' on '')" "RELAY=1 TRANSPORT=slack"
# ...and a turn with nowhere to go still stops exactly where it always did.
eq unbound_still_exits "$(decide - on '')" ""

# ---------------------------------------------------------------------------
# 2. Delivery (destination + reply-delivery blocks)
# ---------------------------------------------------------------------------
setup() { # setup <name> [voice] -> prints the case dir
  local c="$T/$1"
  rm -rf "$T/$1"; mkdir -p "$c/bin" "$c/logs" "$c/flags" "$c/fake" "$c/orc"
  cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$c/bin/"
  cat > "$c/fake/curl" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$CURL_LOG"
echo '{"ok":true}'
FAKE
  cat > "$c/bin/beat.sh" <<'FAKE'
#!/bin/bash
printf '%s\n' "$1" >> "$BEATS"
printf 'strict=%s\n' "${BEAT_STRICT:-unset}" >> "$BEATS.strict"
exit "${BEAT_RC:-0}"
FAKE
  cat > "$c/bin/tts-say.sh" <<'FAKE'
#!/bin/bash
cat >/dev/null
printf 'ogg\n' > "$2"
FAKE
  chmod +x "$c/fake/curl" "$c/bin/beat.sh" "$c/bin/tts-say.sh"
  printf 'the question\n' > "$c/msg.txt"
  [ "${2:-}" = voice ] && : > "$c/flags/voice-replies"
  printf '%s' "$c"
}

deliver() { # deliver <dir> <relay> <transport> <cmd_id> <origin> <chat> <thread> [beat_rc] [tg_ok]
  local c="$1"
  PATH="$c/fake:$PATH" CURL_LOG="$c/curl.log" BEATS="$c/beats.jsonl" \
  BEAT_RC="${8:-0}" HARNESS="$c" ORC="$c/orc" TG_OK="${9:-1}" \
  RELAY="$2" META_TRANSPORT="$3" CMD_ID="$4" ORIGIN="$5" META_CHAT="$6" META_THREAD="$7" \
  TELEGRAM_CHAT_ID="$GROUP" TG_TOPICS_FILE="$c/topics.json" \
  ORC_REPLY_LEDGER_BACKOFF_S=0 bash -c "
    set -uo pipefail
    META_CHAT=\"\$META_CHAT\"; META_THREAD=\"\$META_THREAD\"
    . \"$DIR/bin/lib/orc-reply-ledger.sh\"
    $DEST_BLOCK
    TG=https://api.telegram.org/botTESTTOKEN
    $DELIVER_BLOCK
    deliver_reply 'hello there'
  " _ "$c/msg.txt" 2>>"$c/stderr.log"
}

# --- case 1: flag absent, telegram, topic origin — Telegram + a ledger beat -
C=$(setup case1); deliver "$C" 0 telegram c1 "" "$GROUP" 6
eq c1_one_send      "$(cnt "$C/curl.log" sendMessage)" 1
eq c1_thread        "$(cnt "$C/curl.log" 'message_thread_id=6')" 1
eq c1_chat          "$(cnt "$C/curl.log" "chat_id=$GROUP")" 1
eq c1_one_beat      "$(cnt "$C/beats.jsonl" chat_reply)" 1
eq c1_not_relayed   "$(jq -r '.relay // "absent"' "$C/beats.jsonl")" absent
eq c1_strict        "$(cnt "$C/beats.jsonl.strict" 'strict=1')" 1

# --- case 1b: flag absent + voice — the voice reply is untouched -------------
C=$(setup case1b voice); deliver "$C" 0 telegram c1 "" "$GROUP" 6
eq c1b_voice        "$(cnt "$C/curl.log" sendVoice)" 1
eq c1b_no_text      "$(cnt "$C/curl.log" sendMessage)" 0
eq c1b_tts_ran      "$([ -f "$C/logs/tts.log" ] && echo yes || echo no)" yes

# --- case 2: flag on, telegram origin — one beat, zero Telegram --------------
C=$(setup case2); deliver "$C" 1 telegram c1 "" "$GROUP" 6
eq c2_beats         "$(cnt "$C/beats.jsonl" .)" 1
eq c2_strict        "$(cnt "$C/beats.jsonl.strict" 'strict=1')" 1
eq c2_shape         "$(jq -r '[.kind,(.relay|tostring),.command_id,.transport,.chat_id,.thread_id,.project,.rkey]|join("|")' "$C/beats.jsonl")" \
                    "chat_reply|true|c1|telegram|$GROUP|6|orchestrator|chat:c1"
eq c2_text          "$(jq -r .text "$C/beats.jsonl")" "hello there"
eq c2_no_telegram   "$(cnt "$C/curl.log" api.telegram.org)" 0
eq c2_no_alert      "$(cnt "$C/logs/ALERTS.log" .)" 0

# --- case 3: flag on, slack origin — no Telegram, no ElevenLabs --------------
C=$(setup case3 voice); deliver "$C" 1 slack c9 "" C123 1726.55
eq c3_transport     "$(jq -r .transport "$C/beats.jsonl")" slack
eq c3_chat          "$(jq -r .chat_id "$C/beats.jsonl")" C123
eq c3_thread        "$(jq -r .thread_id "$C/beats.jsonl")" 1726.55
eq c3_no_telegram   "$(cnt "$C/curl.log" api.telegram.org)" 0
eq c3_no_tts        "$([ -f "$C/logs/tts.log" ] && echo ran || echo never)" never

# --- case 4: beat failure + telegram — direct send AND one ALERTS line -------
C=$(setup case4); deliver "$C" 1 telegram c1 "" "$GROUP" 6 1
eq c4_fallback      "$(cnt "$C/curl.log" sendMessage)" 1
eq c4_tries         "$(cnt "$C/beats.jsonl" '"kind":"chat_reply"')" 3
eq c4_alert_lines   "$(cnt "$C/logs/ALERTS.log" .)" 1
eq c4_alert_names_cmd "$(cnt "$C/logs/ALERTS.log" c1)" 1
eq c4_alert_says_relay "$(cnt "$C/logs/ALERTS.log" relay)" 1
eq c4_alert_says_direct "$(cnt "$C/logs/ALERTS.log" 'direct to Telegram')" 1

# --- case 5: beat failure + slack — nothing to Telegram, still not silent ----
C=$(setup case5); deliver "$C" 1 slack c9 "" C123 1726.55 1
eq c5_no_telegram   "$(cnt "$C/curl.log" api.telegram.org)" 0
eq c5_alert_lines   "$(cnt "$C/logs/ALERTS.log" .)" 1
eq c5_alert_names_file "$(cnt "$C/logs/ALERTS.log" last-reply.txt)" 1
eq c5_no_false_claim "$(cnt "$C/logs/ALERTS.log" 'direct to Telegram')" 0

# --- case 6: dash origin under the flag — the ledger beat, strict, no relay --
C=$(setup case6); deliver "$C" 0 telegram c7 dash "$GROUP" ""
eq c6_send          "$(cnt "$C/curl.log" sendMessage)" 1
eq c6_one_beat      "$(cnt "$C/beats.jsonl" chat_reply)" 1
eq c6_not_relayed   "$(jq -r '.relay // "absent"' "$C/beats.jsonl")" absent
eq c6_strict        "$(cnt "$C/beats.jsonl.strict" 'strict=1')" 1

# --- case 7: slack origin on a hub with no Telegram token — beat still sent --
C=$(setup case7); deliver "$C" 1 slack c9 "" C123 "" 0 0
eq c7_beat          "$(jq -r .transport "$C/beats.jsonl")" slack
eq c7_no_thread     "$(jq -r 'has("thread_id")' "$C/beats.jsonl")" false
eq c7_no_telegram   "$(cnt "$C/curl.log" api.telegram.org)" 0

# ---------------------------------------------------------------------------
# 3. beat.sh strict mode — the REAL script, with a fake curl
# ---------------------------------------------------------------------------
beat_rc() { # beat_rc <name> <strict:1|0> <configured:1|0> <http> <curl_rc> -> rc
  local c="$T/$1" rc
  rm -rf "$T/$1"; mkdir -p "$c/env" "$c/logs" "$c/state" "$c/flags" "$c/fake"
  cat > "$c/fake/curl" <<'FAKE'
#!/bin/bash
[ "${FAKE_CURL_RC:-0}" = 0 ] || exit "$FAKE_CURL_RC"
printf '%s' "${FAKE_HTTP:-200}"
FAKE
  chmod +x "$c/fake/curl"
  if [ "$3" = 1 ]; then
    printf 'CONSOLE_URL=https://console.example\nHARNESS_SECRET=s3cret\n' > "$c/env/global.env"
  else
    : > "$c/env/global.env"
  fi
  env -u CONSOLE_URL -u HARNESS_SECRET PATH="$c/fake:$PATH" HARNESS="$c" \
    FAKE_HTTP="$4" FAKE_CURL_RC="$5" BEAT_STRICT="$2" \
    "$DIR/bin/beat.sh" '{"kind":"chat_reply","rkey":"chat:c1","command_id":"c1","project":"orchestrator","text":"hi","relay":true}' >/dev/null 2>&1
  rc=$?
  echo "$rc"
}
eq beat_strict_200      "$(beat_rc beat200   1 1 200 0)" 0
eq beat_strict_500      "$(beat_rc beat500   1 1 500 0)" 1
eq beat_strict_down     "$(beat_rc beatdown  1 1 000 7)" 1
eq beat_strict_unset    "$(beat_rc beatunset 1 0 200 0)" 2
eq beat_default_500     "$(beat_rc beatd500  0 1 500 0)" 0
eq beat_default_unset   "$(beat_rc beatdunset 0 0 200 0)" 0

echo "orc-reply-via-console-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
