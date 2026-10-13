#!/bin/bash
# tests/orchestrate-no-reply.bh-5028-test.sh — an orchestrator turn that has a
# console command id never ends silently (BH-5028 / BH-4995.1). An empty or
# whitespace-only answer, a turn that dies before answering, a duplicate
# delivery and an empty message each post exactly one chat_reply beat with an
# `error` field, and the command row is acked with what happened.
#
# bin/orchestrate.sh pins HARNESS=/root/harness and ORC=/root/orchestrator, so
# the whole script cannot run in a scratch tree. The turn below is assembled
# from the production blocks lifted VERBATIM, in the order the script runs
# them: the sidecar block (which sources bin/lib/orc-reply-ledger.sh),
# `# >>> turn exit`, the destination block, `# >>> reply delivery`,
# `# >>> turn text`, a stub claude step, `# >>> no reply`, the script's
# `trap - EXIT`, the `deliver_reply "$OUT" "$REPLY_ERR"` call and
# `# >>> reply status`. curl and beat.sh are stubs that log what they get.
#
# L4/L4b/L8/L9/L9b/E1 are the acceptance cases; M3 deletes the trap install
# from the lifted text and requires L9 to go red.
#
# Run from anywhere: tests/orchestrate-no-reply.bh-5028-test.sh (exit 0 = all pass)
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
EXIT_BLOCK=$(sed -n '/^# >>> turn exit/,/^# <<< turn exit/p' "$SRC")
DEST_BLOCK=$(sed -n '/^TG_TO=/,/^\[ -n "\$TG_THREAD" \] && TG_THREAD_FORM=/p' "$SRC")
DELIVER_BLOCK=$(sed -n '/^# >>> reply delivery/,/^# <<< reply delivery/p' "$SRC")
TEXT_BLOCK=$(sed -n '/^# >>> turn text/,/^# <<< turn text/p' "$SRC")
NOREPLY_BLOCK=$(sed -n '/^# >>> no reply/,/^# <<< no reply/p' "$SRC")
STATUS_BLOCK=$(sed -n '/^# >>> reply status/,/^# <<< reply status/p' "$SRC")
GROUP=-1000000000000

# --- L0: the lifts are real, and the script runs them in this order ---------
grep -q 'trap orc_on_exit EXIT' <<<"$EXIT_BLOCK" && ok || bad "L0 the turn-exit block must install trap orc_on_exit EXIT"
grep -q 'orc_dedupe_seen' <<<"$TEXT_BLOCK" && ok || bad "L0 the turn-text block must hold the duplicate guard"
grep -q 'REPLY_ERR=no_reply' <<<"$NOREPLY_BLOCK" && ok || bad "L0 the no-reply block must set REPLY_ERR=no_reply"
eq L0_deliver_passes_err "$(grep -c '^deliver_reply "\$OUT" "\$REPLY_ERR"$' "$SRC")" 1
eq L0_old_typer_trap_gone "$(grep -c "trap 'kill \$TYPER" "$SRC")" 0
_ln() { grep -n -m1 -- "$1" "$SRC" | cut -d: -f1; }
L_META=$(_ln '^\[ "\$TG_OK" = 1 \]'); L_EXIT=$(_ln '^# >>> turn exit'); L_TEXT=$(_ln '^# >>> turn text')
L_LOCK=$(_ln '^# >>> turn queue status'); L_NR=$(_ln '^# >>> no reply'); L_LADDER=$(_ln '^# <<< claude ladder')
[ -n "$L_EXIT" ] && [ "${L_META:-0}" -lt "$L_EXIT" ] && [ "$L_EXIT" -lt "${L_TEXT:-0}" ] && [ "$L_TEXT" -lt "${L_LOCK:-0}" ] \
  && [ "${L_LADDER:-0}" -lt "${L_NR:-0}" ] && ok || bad "L0 block order: sidecar < turn exit < turn text < turn queue status; claude ladder < no reply"

setup() { # setup <name> [token] -> prints the case dir (a scratch HARNESS)
  local c="$T/$1" tok="${2-tok}"
  scratch_rm "$c" || return 1; mkdir -p "$c/bin" "$c/logs" "$c/flags" "$c/fake" "$c/orc/state" "$c/env"
  cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$c/bin/"
  printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CHAT_ID=%s\nCONSOLE_URL=https://console.example\nHARNESS_SECRET=s3cret\n' "$tok" "$GROUP" > "$c/env/global.env"
  cat > "$c/fake/curl" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$CURL_LOG"
case " $* " in *" @- "*) printf 'BODY %s\n' "$(cat)" >> "$CURL_LOG" ;; esac
case " $* " in *" -o /dev/null "*) ;; *) echo '{"ok":true}' ;; esac
FAKE
  printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "$BEATS"\n' > "$c/bin/beat.sh"
  chmod +x "$c/fake/curl" "$c/bin/beat.sh"
  scratch_install_closure bin/lib/orc-reply-ledger.sh "$c" >/dev/null || echo "setup: cannot install the ledger lib" >&2
  scratch_install_closure bin/lib/orc-dedupe.sh "$c" >/dev/null || echo "setup: cannot install the dedupe lib" >&2
  printf 'hello there' > "$c/reply"
  printf '%s' "$c"
}

# turn <dir> <meta-json|-> [text] — one turn. M_EXIT lets a mutant replace the
# turn-exit block. The stub claude appends the text to claude.calls; with
# $c/hang present it writes its pid to turn.pid and waits to be killed.
turn() {
  local c="$1" text="${3-the question}"
  printf '%s' "$text" > "$c/msg"
  [ "$2" = "-" ] || printf '%s\n' "$2" > "$c/msg.meta"
  env -u HARNESS_ENV_DIR -u CONSOLE_URL -u HARNESS_SECRET -u CMD_ID -u ORC_DEDUPE_SECS \
  PATH="$c/fake:$PATH" CURL_LOG="$c/curl.log" BEATS="$c/beats.jsonl" \
  HARNESS="$c" ORC="$c/orc" MSGF="$c/msg" TG_TOPICS_FILE="$c/topics.json" \
  ORC_REPLY_LEDGER_BACKOFF_S=0 \
  bash -c "
    set -uo pipefail
    HARNESS=\"\$HARNESS\"; ORC=\"\$ORC\"; MSGF=\"\$MSGF\"
    . \"$DIR/bin/lib/env-path.sh\"; HENV=\$(harness_env_dir \"\$HARNESS\")
    $META_BLOCK
    ${M_EXIT-$EXIT_BLOCK}
    $DEST_BLOCK
    TG=https://api.telegram.org/botTESTTOKEN
    $DELIVER_BLOCK
    $TEXT_BLOCK
    printf '%s\n' \"\$TEXT\" >> \"\$HARNESS/claude.calls\"
    if [ -f \"\$HARNESS/hang\" ]; then echo \$\$ > \"\$HARNESS/turn.pid\"; while :; do sleep 0.05; done; fi
    OUT=\$(cat \"\$HARNESS/reply\" 2>/dev/null)
    $NOREPLY_BLOCK
    trap - EXIT
    deliver_reply \"\$OUT\" \"\$REPLY_ERR\"
    $STATUS_BLOCK
    exit 0
  " _ "$c/msg" 2>>"$c/stderr.log"
}
# hang_turn <dir> <meta> — run a turn that the stub holds, then SIGTERM it.
hang_turn() {
  local c="$1" i=0
  : > "$c/hang"
  turn "$c" "$2" & local tp=$!
  while [ ! -s "$c/turn.pid" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
  [ -s "$c/turn.pid" ] && kill -TERM "$(cat "$c/turn.pid")"
  wait "$tp" 2>/dev/null
}
beats()  { cnt "$1/beats.jsonl" '"kind":"chat_reply"'; }
bodies() { sed -n 's/^BODY //p' "$1/curl.log" 2>/dev/null | jq -r .result; }
iso='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z'

# --- L4: claude printed nothing — one no_reply beat quoting the last error ---
C=$(setup l4); : > "$C/reply"; printf 'earlier line\nboom: probe pending\n\n' > "$C/orc/last-error.txt"
turn "$C" '{"command_id":"21101","origin":"dash"}'
eq L4_one_beat   "$(beats "$C")" 1
eq L4_error      "$(jq -r '.error // ""' "$C/beats.jsonl")" no_reply
jq -r .text "$C/beats.jsonl" | grep -q 'boom: probe pending' && ok || bad "L4 the beat text must quote the last error line: $(jq -r .text "$C/beats.jsonl")"
grep -q 'earlier line' <<<"$(jq -r .text "$C/beats.jsonl")" && bad "L4 only the LAST error line is quoted" || ok
bodies "$C" | grep -Eq "^no_reply:$iso\$" && ok || bad "L4 the ack must be no_reply:<iso>, got [$(bodies "$C")]"
eq L4_no_answered "$(bodies "$C" | grep -c '^answered:')" 0

# --- L4b: whitespace-only OUT is no answer; no last-error.txt says so -------
C=$(setup l4b); printf '  \n\t\n' > "$C/reply"
turn "$C" '{"command_id":"21102","origin":"dash"}'
eq L4b_one_beat  "$(beats "$C")" 1
eq L4b_error     "$(jq -r '.error // ""' "$C/beats.jsonl")" no_reply
jq -r .text "$C/beats.jsonl" | grep -q 'no error recorded' && ok || bad "L4b a missing last-error.txt must read 'no error recorded': $(jq -r .text "$C/beats.jsonl")"
bodies "$C" | grep -Eq "^no_reply:$iso\$" && ok || bad "L4b the ack must be no_reply:<iso>"
# The error line is cut to 300 characters.
C=$(setup l4c); : > "$C/reply"; head -c 900 /dev/zero | tr '\0' 'e' > "$C/orc/last-error.txt"
turn "$C" '{"command_id":"21103","origin":"dash"}'
eq L4c_cut_300   "$(jq -r .text "$C/beats.jsonl" | grep -o 'ee*' | awk '{print length}' | sort -n | tail -n1)" 300
# A reply that is only "0" is an answer, not a no_reply.
C=$(setup l4d); printf '0' > "$C/reply"
turn "$C" '{"command_id":"21104","origin":"dash"}'
eq L4d_answered  "$(jq -r '[.text, (has("error")|tostring)]|join("|")' "$C/beats.jsonl")" "0|false"
eq L4d_ack       "$(bodies "$C" | cut -d: -f1)" answered

# --- L8: same text twice inside the window — answered once, duplicate beat ---
C=$(setup l8)
turn "$C" "{\"command_id\":\"21095\",\"origin\":\"\",\"chat_id\":\"$GROUP\"}" "status please"
eq L8_first_beat "$(jq -r '"\(.command_id)|\(has("error"))"' "$C/beats.jsonl")" "21095|false"
bodies "$C" | grep -Eq "^answered:$iso\$" && ok || bad "L8 21095 must be acked answered:<iso>"
: > "$C/beats.jsonl"; mv "$C/curl.log" "$C/curl.first.log"
turn "$C" "{\"command_id\":\"21099\",\"origin\":\"\",\"chat_id\":\"$GROUP\"}" "status please"
eq L8_dup_beat   "$(beats "$C")" 1
eq L8_dup_shape  "$(jq -r '[.command_id, .error, (has("relay")|tostring)]|join("|")' "$C/beats.jsonl")" "21099|duplicate|false"
bodies "$C" | grep -Eq "^duplicate:$iso\$" && ok || bad "L8 21099 must be acked duplicate:<iso>, got [$(bodies "$C")]"
eq L8_claude_once "$(cnt "$C/claude.calls" .)" 1
eq L8_tg_dup     "$(cnt "$C/curl.log" sendMessage)" 0
eq L8_tg_total   "$(( $(cnt "$C/curl.first.log" sendMessage) + $(cnt "$C/curl.log" sendMessage) ))" 1
# Relay on: the duplicate beat still carries no relay, so the console sends nothing.
C=$(setup l8r); : > "$C/flags/orc-reply-via-console"
turn "$C" "{\"command_id\":\"21095\",\"origin\":\"\",\"chat_id\":\"$GROUP\"}" "again"
: > "$C/beats.jsonl"
turn "$C" "{\"command_id\":\"21099\",\"origin\":\"\",\"chat_id\":\"$GROUP\"}" "again"
eq L8r_no_relay  "$(jq -r '[.error, (has("relay")|tostring)]|join("|")' "$C/beats.jsonl")" "duplicate|false"

# --- L9: the turn is SIGTERMed mid-flight — one no_reply beat from the trap --
C=$(setup l9); printf 'claude: rate limited\n' > "$C/orc/last-error.txt"
hang_turn "$C" '{"command_id":"21106","origin":"dash"}'
eq L9_one_beat   "$(beats "$C")" 1
eq L9_error      "$(jq -r '.error // ""' "$C/beats.jsonl")" no_reply
jq -r .text "$C/beats.jsonl" | grep -q '^(the turn stopped before answering) claude: rate limited' && ok \
  || bad "L9 the beat text must start '(the turn stopped before answering)' and quote the error: $(jq -r .text "$C/beats.jsonl" 2>/dev/null)"
bodies "$C" | grep -Eq "^no_reply:$iso\$" && ok || bad "L9 the ack must be no_reply:<iso>, got [$(bodies "$C")]"
eq L9_one_ack    "$(cnt "$C/curl.log" '/ack')" 1
# A set -u crash before the answer: the same one beat, from the same trap.
C=$(setup l9u)
M_EXIT="$EXIT_BLOCK"$'\n''echo "$NOT_SET_ANYWHERE"' turn "$C" '{"command_id":"21107","origin":"dash"}'
eq L9u_one_beat  "$(jq -r '.error // ""' "$C/beats.jsonl")" no_reply

# --- L9b: an answered turn never adds a trap beat; no command id, no beat ---
C=$(setup l9b); turn "$C" '{"command_id":"21108","origin":"dash"}'
eq L9b_one_beat  "$(beats "$C")" 1
eq L9b_no_error  "$(jq -r 'has("error")' "$C/beats.jsonl")" false
eq L9b_no_noreply "$(bodies "$C" | grep -c '^no_reply:')" 0
C=$(setup l9c); hang_turn "$C" -
eq L9c_no_beat   "$(beats "$C")" 0
eq L9c_no_ack    "$(cnt "$C/curl.log" '/ack')" 0

# --- E1: an empty message with a command id — one empty_message beat --------
C=$(setup e1); turn "$C" '{"command_id":"21109","origin":"dash"}' ""
eq E1_one_beat   "$(beats "$C")" 1
eq E1_error      "$(jq -r '[.error, (has("relay")|tostring)]|join("|")' "$C/beats.jsonl")" "empty_message|false"
eq E1_no_claude  "$(cnt "$C/claude.calls" .)" 0
eq E1_no_tg      "$(cnt "$C/curl.log" sendMessage)" 0
C=$(setup e1b); turn "$C" - ""
eq E1b_no_beat   "$(beats "$C")" 0

# --- M3: no trap install — L9 goes red ---------------------------------------
C=$(setup m3); printf 'x\n' > "$C/orc/last-error.txt"
M_EXIT=$(sed '/^trap orc_on_exit EXIT/d' <<<"$EXIT_BLOCK") hang_turn "$C" '{"command_id":"21110","origin":"dash"}'
[ "$(beats "$C")" != 1 ] && ok || bad "M3 deleting the trap install must turn L9 red"

echo "orchestrate-no-reply (BH-5028): $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
