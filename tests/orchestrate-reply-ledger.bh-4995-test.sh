#!/bin/bash
# tests/orchestrate-reply-ledger.bh-4995-test.sh — every orchestrator turn that
# carries a console command id ends in exactly one strict chat_reply beat
# (rkey chat:<id>) and one answered:<iso> command ack (BH-4995.0 / BH-5027).
#
# bin/orchestrate.sh pins HARNESS=/root/harness and ORC=/root/orchestrator, so
# the whole script cannot run in a scratch tree. The turn below is assembled
# from the production blocks lifted VERBATIM: the sidecar block (which sources
# bin/lib/orc-reply-ledger.sh), the destination block, `# >>> reply delivery`
# and `# >>> reply status`, with the same `deliver_reply "$OUT"` call the script
# ends on. curl and beat.sh are stubs that log what they were handed.
#
# L0-L12 are the acceptance cases; M1-M3 mutate the lifted text and require the
# case that pins it to go red, so a suite that cannot see the behavior fails.
#
# Run from anywhere: tests/orchestrate-reply-ledger.bh-4995-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
NOW=2026-10-07T00:00:00Z
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
cnt() { local n=0; [ -f "$1" ] && n=$(grep -c -- "$2" "$1"); echo "${n:-0}"; }

SRC="$DIR/bin/orchestrate.sh"
LIB="$DIR/bin/lib/orc-reply-ledger.sh"
META_BLOCK=$(sed -n '/^ORIGIN=""; CMD_ID=""/,/^\[ "\$TG_OK" = 1 \]/p' "$SRC")
DEST_BLOCK=$(sed -n '/^TG_TO=/,/^\[ -n "\$TG_THREAD" \] && TG_THREAD_FORM=/p' "$SRC")
DELIVER_BLOCK=$(sed -n '/^# >>> reply delivery/,/^# <<< reply delivery/p' "$SRC")
STATUS_BLOCK=$(sed -n '/^# >>> reply status/,/^# <<< reply status/p' "$SRC")
GROUP=-1000000000000
SECRET=s3cret-BH4995-value

# --- L0: the lifts are real, and they are what the script runs ---------------
grep -q 'orc-reply-ledger.sh' <<<"$META_BLOCK" && ok || bad "L0 the sidecar block must source bin/lib/orc-reply-ledger.sh"
grep -q 'TG_THREAD_FORM=' <<<"$DEST_BLOCK" && ok || bad "L0 destination lift is empty or stale"
grep -q 'deliver_reply()' <<<"$DELIVER_BLOCK" && ok || bad "L0 the reply-delivery block must define deliver_reply"
grep -q 'cmd_status "answered:' <<<"$STATUS_BLOCK" && ok || bad "L0 the reply-status block must call cmd_status answered:"
eq L0_status_follows_deliver "$(grep -A1 '^deliver_reply "\$OUT"' "$SRC" | sed -n 2p | cut -c1-21)" "# >>> reply status (t"
[ -f "$LIB" ] && ok || bad "L0 bin/lib/orc-reply-ledger.sh is missing"

# setup <name> [token] [secret] -> prints the case dir (a scratch HARNESS)
setup() {
  local c="$T/$1" tok="${2-tok}" sec="${3-$SECRET}"
  scratch_rm "$c" || return 1; mkdir -p "$c/bin" "$c/logs" "$c/flags" "$c/fake" "$c/orc" "$c/env"
  cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$c/bin/"
  {
    printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CHAT_ID=%s\nCONSOLE_URL=https://console.example\n' "$tok" "$GROUP"
    [ -n "$sec" ] && printf 'HARNESS_SECRET=%s\n' "$sec"
  } > "$c/env/global.env"
  cat > "$c/fake/curl" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$CURL_LOG"
case " $* " in *" @- "*) printf 'BODY %s\n' "$(cat)" >> "$CURL_LOG" ;; esac
case " $* " in *" -o /dev/null "*) ;; *) echo '{"ok":true}' ;; esac
FAKE
  cat > "$c/bin/beat.sh" <<'FAKE'
#!/bin/bash
printf '%s\n' "$1" >> "$BEATS"
printf 'strict=%s\n' "${BEAT_STRICT:-unset}" >> "$BEATS.strict"
if [ -n "${BEAT_FAIL_N:-}" ]; then
  [ "$(grep -c chat_reply "$BEATS")" -le "$BEAT_FAIL_N" ] && exit 1
  exit 0
fi
exit "${BEAT_RC:-0}"
FAKE
  cat > "$c/bin/tts-say.sh" <<'FAKE'
#!/bin/bash
cat >/dev/null
printf 'ogg\n' > "$2"
FAKE
  chmod +x "$c/fake/curl" "$c/bin/beat.sh" "$c/bin/tts-say.sh"
  scratch_install_closure bin/lib/orc-reply-ledger.sh "$c" >/dev/null || echo "setup: cannot install the ledger lib (L0 names it)" >&2
  printf 'hello there' > "$c/reply"
  printf '%s' "$c"
}

# turn <dir> <meta-json|-> — one turn tail. M_META / M_DELIVER / M_STATUS let a
# mutant replace a lifted block. Leaves marker (past the early exit), deliver.rc.
turn() {
  local c="$1"
  printf 'the question\n' > "$c/msg"
  [ "$2" = "-" ] || printf '%s\n' "$2" > "$c/msg.meta"
  env -u HARNESS_ENV_DIR -u CONSOLE_URL -u HARNESS_SECRET -u CMD_ID \
  PATH="$c/fake:$PATH" CURL_LOG="$c/curl.log" BEATS="$c/beats.jsonl" \
  HARNESS="$c" ORC="$c/orc" MSGF="$c/msg" TG_TOPICS_FILE="$c/topics.json" \
  ORC_REPLY_LEDGER_BACKOFF_S="${ORC_REPLY_LEDGER_BACKOFF_S:-0}" \
  bash -c "
    set -uo pipefail
    HARNESS=\"\$HARNESS\"; ORC=\"\$ORC\"; MSGF=\"\$MSGF\"
    . \"$DIR/bin/lib/env-path.sh\"; HENV=\$(harness_env_dir \"\$HARNESS\")
    ${M_META-$META_BLOCK}
    echo past-exit > \"\$HARNESS/marker\"
    $DEST_BLOCK
    TG=https://api.telegram.org/botTESTTOKEN
    ${M_DELIVER-$DELIVER_BLOCK}
    OUT=\$(cat \"\$HARNESS/reply\")
    deliver_reply \"\$OUT\"; echo \$? > \"\$HARNESS/deliver.rc\"
    ${M_STATUS-$STATUS_BLOCK}
    exit 0
  " _ "$c/msg" 2>>"$c/stderr.log"
}
beats() { cnt "$1/beats.jsonl" '"kind":"chat_reply"'; }
acks()  { cnt "$1/curl.log" '/ack'; }

# --- L1: dash turn — one strict beat, Telegram still sent --------------------
C=$(setup l1); turn "$C" '{"command_id":"21082","origin":"dash"}'
eq L1_one_beat  "$(beats "$C")" 1
eq L1_shape     "$(jq -r '[.kind,.command_id,.rkey,.project,.text,(has("error")|tostring),.origin]|join("|")' "$C/beats.jsonl")" \
                "chat_reply|21082|chat:21082|orchestrator|hello there|false|dash"
eq L1_strict    "$(cnt "$C/beats.jsonl.strict" 'strict=1')" 1
eq L1_telegram  "$(cnt "$C/curl.log" sendMessage)" 1

# --- L2: telegram-origin turn, flag absent — beat, never relayed -------------
C=$(setup l2); turn "$C" "{\"command_id\":\"21083\",\"origin\":\"\",\"chat_id\":\"$GROUP\"}"
eq L2_one_beat  "$(beats "$C")" 1
eq L2_no_relay  "$(jq -r 'has("relay")' "$C/beats.jsonl")" false
eq L2_transport "$(jq -r .transport "$C/beats.jsonl")" telegram
eq L2_telegram  "$(cnt "$C/curl.log" sendMessage)" 1

# --- L3: a 5000-char reply — chunked to Telegram, ONE beat with all of it ----
C=$(setup l3)
head -c 5000 /dev/zero | tr '\0' 'x' > "$C/reply"
turn "$C" '{"command_id":"21085","origin":"dash"}'
[ "$(cnt "$C/curl.log" sendMessage)" -ge 2 ] && ok || bad "L3 a 5000-char reply must go to Telegram in >=2 chunks"
eq L3_one_beat  "$(beats "$C")" 1
jq -j .text "$C/beats.jsonl" > "$C/text.out"
cmp -s "$C/text.out" "$C/reply" && ok || bad "L3 the beat text must be the full 5000 chars byte for byte"

# --- L4: flag on + voice — the voice goes direct, the beat is not relayed ----
C=$(setup l4); : > "$C/flags/orc-reply-via-console"; : > "$C/flags/voice-replies"
turn "$C" "{\"command_id\":\"21084\",\"origin\":\"\",\"chat_id\":\"$GROUP\"}"
eq L4_voice     "$(cnt "$C/curl.log" sendVoice)" 1
eq L4_no_text   "$(cnt "$C/curl.log" sendMessage)" 0
eq L4_one_beat  "$(beats "$C")" 1
eq L4_no_relay  "$(jq -r 'has("relay")' "$C/beats.jsonl")" false

# --- L5: hostile text round-trips byte-exact; 200 KB is capped, still posts --
C=$(setup l5)
printf 'he said "hi"\n{"kind":"alert"}\n\xf0\x9f\x9a\x80' > "$C/reply"
turn "$C" '{"command_id":"21086","origin":"dash"}'
eq L5_one_beat  "$(beats "$C")" 1
jq -j .text "$C/beats.jsonl" > "$C/text.out"
cmp -s "$C/text.out" "$C/reply" && ok || bad "L5 quotes/newlines/emoji must round-trip byte for byte"
eq L5_kind_kept "$(jq -r .kind "$C/beats.jsonl")" chat_reply
head -c 200000 /dev/zero | tr '\0' 'y' > "$C/big"
CMD_ID=21087 HARNESS="$C" ORC="$C/orc" BEATS="$C/big-beats.jsonl" ORC_REPLY_LEDGER_BACKOFF_S=0 \
  bash -c 'set -u; . "$1"; ledger_reply "$(cat "$2")"; echo "rc=$?"' _ "$LIB" "$C/big" > "$C/big.rc"
eq L5_big_rc    "$(cat "$C/big.rc")" rc=0
eq L5_big_beat  "$(cnt "$C/big-beats.jsonl" chat_reply)" 1
# BH-4995.2: cut in characters at MAX-120, ending with the cut marker.
[ "$(jq -j 'select(.kind=="chat_reply")|.text' "$C/big-beats.jsonl" | LC_ALL=C.UTF-8 wc -m)" -le 14000 ] && ok || bad "L5_big_cap the beat text must be <= 14000 chars"
eq L5_big_cap   "$(jq -j 'select(.kind=="chat_reply")|.text' "$C/big-beats.jsonl" | tail -c 18)" "in last-reply.txt]"

# --- L6: knob garbage is the default, never a set -u death ------------------
# 18446744073709551621 is 2^64+5: it wraps to 5 in bash arithmetic, inside 1..10.
for v in abc -1 0 99 '' 999999999999999999999 18446744073709551621; do
  out=$(bash -c 'set -u; . "$1"; _orl_int "$2" 1 10 3' _ "$LIB" "$v"); rc=$?
  eq "L6_tries[$v]" "$out:$rc" "3:0"
done
eq L6_in_range "$(bash -c 'set -u; . "$1"; _orl_int 7 1 10 3' _ "$LIB")" 7

# --- L7: no sidecar / empty command id — no beat, no ack, Telegram as before -
C=$(setup l7); turn "$C" -
eq L7_no_beat   "$(beats "$C")" 0
eq L7_no_ack    "$(acks "$C")" 0
eq L7_telegram  "$(cnt "$C/curl.log" sendMessage)" 1
C=$(setup l7b); turn "$C" '{"command_id":"","origin":""}'
eq L7b_no_beat  "$(beats "$C")" 0
eq L7b_no_ack   "$(acks "$C")" 0
eq L7b_telegram "$(cnt "$C/curl.log" sendMessage)" 1

# --- L8: the console is down — 3 tries, ONE alert, Telegram already sent -----
C=$(setup l8); BEAT_RC=1 turn "$C" '{"command_id":"21082","origin":""}'
eq L8_tries     "$(beats "$C")" 3
eq L8_alerts    "$(cnt "$C/logs/ALERTS.log" .)" 1
eq L8_names_id  "$(cnt "$C/logs/ALERTS.log" 21082)" 1
eq L8_telegram  "$(cnt "$C/curl.log" sendMessage)" 1
eq L8_rc        "$(cat "$C/deliver.rc")" 0
grep -rl "$SECRET" "$C/logs" "$C/beats.jsonl" >/dev/null 2>&1 && bad "L8 the secret leaked into ALERTS or a beat" || ok
C=$(setup l8b); BEAT_FAIL_N=1 turn "$C" '{"command_id":"21082","origin":""}'
eq L8b_tries    "$(beats "$C")" 2
eq L8b_alerts   "$(cnt "$C/logs/ALERTS.log" .)" 0

# --- L9: no secret — no ack curl, no alert ----------------------------------
C=$(setup l9 tok ''); turn "$C" '{"command_id":"21082","origin":"dash"}'
eq L9_no_ack    "$(acks "$C")" 0
eq L9_no_alert  "$(cnt "$C/logs/ALERTS.log" .)" 0
eq L9_beat      "$(beats "$C")" 1
# Set but EMPTY is not unset: under set -u only the guard keeps this from a
# curl that carries a blank bearer.
C=$(setup l9b tok ''); printf 'HARNESS_SECRET=\n' >> "$C/env/global.env"
turn "$C" '{"command_id":"21082","origin":"dash"}'
eq L9b_no_ack   "$(acks "$C")" 0

# --- L10: one answered:<iso> ack after the reply; ORC_CMD_STATUS=0 is none ---
C=$(setup l10); turn "$C" '{"command_id":"21082","origin":"dash"}'
eq L10_one_ack  "$(cnt "$C/curl.log" 'https://console.example/api/commands/21082/ack')" 1
BODY=$(sed -n 's/^BODY //p' "$C/curl.log")
eq L10_ok       "$(jq -r .ok <<<"$BODY")" true
jq -r .result <<<"$BODY" | grep -Eq '^answered:[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' && ok || bad "L10 result must be answered:<iso>, got [$BODY]"
# The stub curl logs argv (the bearer header); nothing else may hold the secret.
grep -rl --exclude=curl.log --exclude=global.env "$SECRET" "$C" >/dev/null 2>&1 && bad "L10 the secret was written outside the request" || ok
C=$(setup l10b); ORC_CMD_STATUS=0 turn "$C" '{"command_id":"21082","origin":"dash"}'
eq L10b_no_ack  "$(acks "$C")" 0
eq L10b_beat    "$(beats "$C")" 1

# --- L11: no Telegram token, a command id — the turn no longer exits early ---
C=$(setup l11 ''); turn "$C" '{"command_id":"c1","origin":""}'
eq L11_runs     "$(cat "$C/marker" 2>/dev/null)" past-exit
eq L11_beat     "$(beats "$C")" 1
C=$(setup l11b ''); turn "$C" -
eq L11b_exits   "$(cat "$C/marker" 2>/dev/null)" ""

# --- L12: _LEDGER_DONE is set even when the post fails; REPLY_SPOOL declared -
C=$(setup l12)
out=$(CMD_ID=x HARNESS="$C" ORC="$C/orc" BEATS="$C/beats.jsonl" BEAT_RC=1 ORC_REPLY_LEDGER_BACKOFF_S=0 \
  bash -c 'set -u; . "$1"; ledger_reply hi; echo "$?|$_LEDGER_DONE|$REPLY_SPOOL"' _ "$LIB")
eq L12_done     "$out" "1|1|$C/orc/state/chat-reply-spool"

# --- L13: the knobs are settings rows — lane.orc-monitor.<env> is obeyed ----
# The row is read through bin/lib/lane-gate.sh's lane_knob from the box's
# settings cache, pinned fresh at LANE_GATE_NOW so no refresh is attempted.
EPOCH=1791331200   # $NOW as epoch seconds
C=$(setup l13); mkdir -p "$C/state"
printf '{"fetched_at":%s,"values":{"lane.orc-monitor.orc_cmd_status":"0","lane.orc-monitor.orc_reply_ledger_tries":"2"}}\n' "$EPOCH" > "$C/state/settings-cache.json"
LANE_GATE_NOW=$EPOCH BEAT_RC=1 turn "$C" '{"command_id":"21082","origin":"dash"}'
eq L13_row_tries  "$(beats "$C")" 2
eq L13_row_no_ack "$(acks "$C")" 0
eq L13_alert_says "$(cnt "$C/logs/ALERTS.log" 'after 2 tries')" 1

# --- M1-M3: break the shipped behavior, the pinning case must go red --------
C=$(setup m1)
M_DELIVER=$(sed '/^  ledger_reply /d' <<<"$DELIVER_BLOCK") turn "$C" '{"command_id":"21082","origin":"dash"}'
[ "$(beats "$C")" != 1 ] && ok || bad "M1 dropping the ledger_reply call must turn L1 red"
C=$(setup m2 '')
M_META=$(sed 's/ || \[ -n "\$CMD_ID" \]//' <<<"$META_BLOCK") turn "$C" '{"command_id":"c1","origin":""}'
[ "$(cat "$C/marker" 2>/dev/null)" != past-exit ] && ok || bad "M2 dropping the CMD_ID early-exit pass must turn L11 red"
C=$(setup m3)
M_STATUS="" turn "$C" '{"command_id":"21082","origin":"dash"}'
[ "$(acks "$C")" != 1 ] && ok || bad "M3 deleting the reply-status block must turn L10 red"

echo "orchestrate-reply-ledger (BH-4995) [$NOW]: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
