#!/bin/bash
# tests/orchestrate-reply-spool.bh-4995-test.sh — the orchestrator's reply
# ledger survives a console outage (BH-4995.2 / BH-5030).
#
# bin/lib/orc-reply-ledger.sh: a chat_reply beat that fails every try is
# spooled to $ORC/state/chat-reply-spool/<id>.json with ONE ALERTS line naming
# the file; the next ledger_reply drains the spool (oldest first, 20 a call,
# one strict try each, never alerting); a reply over ORC_REPLY_LEDGER_MAX_CHARS
# is cut in characters and ends with a cut marker.
#
# L5a-L5s and L6-L12 source the lib installed into a scratch HARNESS; L5t runs
# the production turn tail lifted VERBATIM from bin/orchestrate.sh (sidecar
# block, destination block, `# >>> reply delivery`), as
# tests/orchestrate-reply-ledger.bh-4995-test.sh does. M1-M4 mutate the
# installed lib and require the case that pins the behavior to go red.
#
# Run from anywhere: tests/orchestrate-reply-spool.bh-4995-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
NOW=2026-10-07T00:00:00Z
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
cnt() { local n=0; [ -f "$1" ] && n=$(grep -c -F -- "$2" "$1"); echo "${n:-0}"; }
export LC_ALL=C.UTF-8

SRC="$DIR/bin/orchestrate.sh"
META_BLOCK=$(sed -n '/^ORIGIN=""; CMD_ID=""/,/^\[ "\$TG_OK" = 1 \]/p' "$SRC")
DEST_BLOCK=$(sed -n '/^TG_TO=/,/^\[ -n "\$TG_THREAD" \] && TG_THREAD_FORM=/p' "$SRC")
DELIVER_BLOCK=$(sed -n '/^# >>> reply delivery/,/^# <<< reply delivery/p' "$SRC")
GROUP=-1000000000000
SECRET=s3cret-BH5030-value
MARK='[reply cut at 13880 chars here; the full text went to Telegram and is in last-reply.txt]'

grep -q 'orc-reply-ledger.sh' <<<"$META_BLOCK" && ok || bad "L0 the sidecar block must source bin/lib/orc-reply-ledger.sh"
grep -q 'TG_THREAD_FORM=' <<<"$DEST_BLOCK" && ok || bad "L0 destination lift is empty or stale"
grep -q 'deliver_reply()' <<<"$DELIVER_BLOCK" && ok || bad "L0 the reply-delivery block must define deliver_reply"

# setup <name> -> prints the case dir (a scratch HARNESS with the lib installed)
setup() {
  local c="$T/$1"
  scratch_rm "$c" || return 1; mkdir -p "$c/bin" "$c/logs" "$c/flags" "$c/fake" "$c/orc" "$c/env"
  cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$c/bin/"
  printf 'TELEGRAM_BOT_TOKEN=tok\nTELEGRAM_CHAT_ID=%s\nCONSOLE_URL=https://console.example\nHARNESS_SECRET=%s\n' "$GROUP" "$SECRET" > "$c/env/global.env"
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
exit "${BEAT_RC:-0}"
FAKE
  chmod +x "$c/fake/curl" "$c/bin/beat.sh"
  scratch_install_closure bin/lib/orc-reply-ledger.sh "$c" >/dev/null || echo "setup: cannot install the ledger lib" >&2
  printf 'hello there' > "$c/reply"
  printf '%s' "$c"
}

# lr <dir> <cmd-id> [text-file] — ledger_reply from the installed lib; prints its rc.
# Extra env (BEAT_RC, RELAY, ...) rides in from the caller.
lr() {
  local c="$1" id="$2" f="${3:-$1/reply}"
  env -u CONSOLE_URL -u HARNESS_ENV_DIR CMD_ID="$id" HARNESS="$c" ORC="$c/orc" BEATS="$c/beats.jsonl" \
    HARNESS_SECRET="$SECRET" ORC_REPLY_LEDGER_BACKOFF_S=0 \
    bash -c 'set -u; . "$1"; ledger_reply "$(cat "$2")"; echo "$?"' _ "$c/bin/lib/orc-reply-ledger.sh" "$f" 2>>"$c/stderr.log"
}
# turn <dir> <meta-json> — the lifted production turn tail (sidecar + destination + delivery)
turn() {
  local c="$1"
  printf 'the question\n' > "$c/msg"
  printf '%s\n' "$2" > "$c/msg.meta"
  env -u HARNESS_ENV_DIR -u CONSOLE_URL -u HARNESS_SECRET -u CMD_ID \
  PATH="$c/fake:$PATH" CURL_LOG="$c/curl.log" BEATS="$c/beats.jsonl" \
  HARNESS="$c" ORC="$c/orc" MSGF="$c/msg" TG_TOPICS_FILE="$c/topics.json" ORC_REPLY_LEDGER_BACKOFF_S=0 \
  bash -c "
    set -uo pipefail
    HARNESS=\"\$HARNESS\"; ORC=\"\$ORC\"; MSGF=\"\$MSGF\"
    . \"$DIR/bin/lib/env-path.sh\"; HENV=\$(harness_env_dir \"\$HARNESS\")
    $META_BLOCK
    $DEST_BLOCK
    TG=https://api.telegram.org/botTESTTOKEN
    $DELIVER_BLOCK
    OUT=\$(cat \"\$HARNESS/reply\")
    deliver_reply \"\$OUT\"; echo \$? > \"\$HARNESS/deliver.rc\"
    exit 0
  " _ "$c/msg" 2>>"$c/stderr.log"
}
# chat_ids <dir> — command_id of every chat_reply beat, in post order
chat_ids() { [ -f "$1/beats.jsonl" ] && jq -r 'select(.kind=="chat_reply")|.command_id' "$1/beats.jsonl" | paste -sd, -; }
nspool() { find "$1/orc/state/chat-reply-spool" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l; }
nalerts() { cnt "$1/logs/ALERTS.log" '[orchestrator]'; }
# spool_file <dir> <name> <command_id> <mtime>
spool_file() {
  mkdir -p "$1/orc/state/chat-reply-spool"
  jq -nc --arg id "$3" '{kind:"chat_reply",rkey:("chat:"+$id),command_id:$id,project:"orchestrator",text:"old"}' > "$1/orc/state/chat-reply-spool/$2"
  touch -d "$4" "$1/orc/state/chat-reply-spool/$2"
}

# --- L5a/L5b: down for 3 tries -> spool + ONE alert; next turn drains it -----
# case_l5ab <dir> — runs both halves; prints nothing, leaves the evidence in <dir>
case_l5ab() {
  local c="$1"
  BEAT_RC=1 ORC_REPLY_LEDGER_TRIES=3 lr "$c" 21082 > "$c/a.rc"
  cp "$c/beats.jsonl" "$c/a.beats" 2>/dev/null; cp "$c/logs/ALERTS.log" "$c/a.alerts" 2>/dev/null
  cp "$c/orc/state/chat-reply-spool/21082.json" "$c/a.spool" 2>/dev/null
  BEAT_RC=0 lr "$c" 21095 > "$c/b.rc"
}
C=$(setup l5a); case_l5ab "$C"; SP="$C/orc/state/chat-reply-spool/21082.json"
eq L5a_rc        "$(cat "$C/a.rc")" 1
eq L5a_tries     "$(cnt "$C/a.beats" '"kind":"chat_reply"')" 3
eq L5a_spooled   "$(jq -r '[.kind,.command_id,.rkey]|join("|")' "$C/a.spool" 2>/dev/null)" "chat_reply|21082|chat:21082"
eq L5a_one_alert "$(cnt "$C/a.alerts" '[orchestrator]')" 1
eq L5a_alert_txt "$(cnt "$C/a.alerts" "[orchestrator] chat_reply for command 21082 did not reach the console after 3 tries — spooled at $SP, next turn retries it")" 1
eq L5b_rc        "$(cat "$C/b.rc")" 0
eq L5b_drained   "$(nspool "$C")" 0
eq L5b_order     "$(chat_ids "$C")" "21082,21082,21082,21082,21095"
eq L5b_alerts    "$(nalerts "$C")" 1
eq L5b_strict    "$(grep -vc 'strict=1' "$C/beats.jsonl.strict")" 0

# --- L12: the secret never reaches the spool or ALERTS ---------------------
grep -rl -- "$SECRET" "$C/a.spool" "$C/logs/ALERTS.log" >/dev/null 2>&1 && bad "L12 the secret leaked into the spool or ALERTS" || ok
[ -s "$C/a.spool" ] && ok || bad "L12 vacuous: nothing was spooled to scan"

# --- L5c: 25 spooled -> the 20 oldest by mtime post, 5 remain -----------------
# Names run opposite to mtime, so a name sort would pick the wrong 20.
C=$(setup l5c)
for i in $(seq 1 25); do spool_file "$C" "$(printf 'f%02d.json' $((26 - i)))" "o$i" "2026-10-01 00:00:$(printf %02d "$i")"; done
eq L5c_rc        "$(BEAT_RC=0 lr "$C" 30000)" 0
eq L5c_posted    "$(chat_ids "$C")" "$(seq -f 'o%g' 1 20 | paste -sd, -),30000"
eq L5c_left      "$(nspool "$C")" 5
eq L5c_left_new  "$(cd "$C/orc/state/chat-reply-spool" && ls -1 ./*.json | paste -sd, -)" "./f01.json,./f02.json,./f03.json,./f04.json,./f05.json"

# --- L5d: console still down -> drained file kept, alert for the NEW id only -
C=$(setup l5d); spool_file "$C" 21082.json 21082 "2026-10-01 00:00:00"
eq L5d_rc        "$(BEAT_RC=1 lr "$C" 21095)" 1
[ -f "$C/orc/state/chat-reply-spool/21082.json" ] && ok || bad "L5d a failed drain must keep the file"
eq L5d_new_spool "$(jq -r .command_id "$C/orc/state/chat-reply-spool/21095.json" 2>/dev/null)" 21095
eq L5d_alerts    "$(nalerts "$C")" 1
eq L5d_new_only  "$(cnt "$C/logs/ALERTS.log" 21082)" 0
eq L5d_one_try   "$(chat_ids "$C")" "21082,21095,21095,21095"

# --- L5g: console still down, 3 spooled -> ONE drain try, then the fresh post -
# The drain runs inside orchestrate.sh's turn lock: a hanging console must not
# cost a 15 s beat per spooled file. The untried files stay for the next turn.
C=$(setup l5g)
for i in 1 2 3; do spool_file "$C" "s$i.json" "4100$i" "2026-10-01 00:00:0$i"; done
eq L5g_rc        "$(BEAT_RC=1 lr "$C" 21095)" 1
eq L5g_one_drain "$(chat_ids "$C")" "41001,21095,21095,21095"
eq L5g_kept      "$(nspool "$C")" 4

# --- L5e: a corrupt spool file is set aside, never posted -------------------
C=$(setup l5e); mkdir -p "$C/orc/state/chat-reply-spool"
printf 'not json at all' > "$C/orc/state/chat-reply-spool/junk.json"
printf '{"kind":"chat_reply"}' > "$C/orc/state/chat-reply-spool/noid.json"
eq L5e_rc        "$(BEAT_RC=0 lr "$C" 21095)" 0
[ -f "$C/orc/state/chat-reply-spool/junk.json.bad" ] && [ -f "$C/orc/state/chat-reply-spool/noid.json.bad" ] && ok || bad "L5e corrupt files must be renamed .bad"
eq L5e_not_posted "$(chat_ids "$C")" 21095
eq L5e_no_junk   "$(cnt "$C/beats.jsonl" 'not json')" 0

# --- L5f: no command id -> no drain, no post ---------------------------------
C=$(setup l5f); spool_file "$C" 21082.json 21082 "2026-10-01 00:00:00"
eq L5f_rc        "$(BEAT_RC=0 lr "$C" '')" 0
eq L5f_no_beats  "$(cnt "$C/beats.jsonl" chat_reply)" 0
eq L5f_kept      "$(nspool "$C")" 1

# --- L5p: a hostile command id stays inside the spool dir --------------------
C=$(setup l5p)
eq L5p_rc        "$(BEAT_RC=1 lr "$C" '../evil')" 1
eq L5p_state     "$(ls -A "$C/orc/state" | paste -sd, -)" chat-reply-spool
eq L5p_file      "$(ls -A "$C/orc/state/chat-reply-spool" | paste -sd, -)" ___evil.json
eq L5p_payload   "$(jq -r .command_id "$C/orc/state/chat-reply-spool/___evil.json" 2>/dev/null)" ../evil

# --- L5r: RELAY=1 -> spooled without relay keys, no ALERTS line -------------
C=$(setup l5r)
eq L5r_rc        "$(BEAT_RC=1 RELAY=1 META_CHAT="$GROUP" META_THREAD=7 lr "$C" 21082)" 1
eq L5r_relayed   "$(jq -r 'select(.kind=="chat_reply")|.relay' "$C/beats.jsonl" | sort -u)" true
eq L5r_spool     "$(jq -r '[.command_id,has("relay"),has("chat_id"),has("thread_id")]|join("|")' "$C/orc/state/chat-reply-spool/21082.json" 2>/dev/null)" "21082|false|false|false"
eq L5r_quiet     "$(nalerts "$C")" 0

# --- L5s: the spool cannot be written -> the alert never claims it was ------
C=$(setup l5s); mkdir -p "$C/orc/state"; : > "$C/orc/state/chat-reply-spool"
eq L5s_rc        "$(BEAT_RC=1 lr "$C" 21082)" 1
eq L5s_alerts    "$(nalerts "$C")" 1
eq L5s_names     "$(cnt "$C/logs/ALERTS.log" "did not reach the console after 3 tries and could not be spooled — the reply is in $C/orc/last-reply.txt")" 1
eq L5s_no_claim  "$(cnt "$C/logs/ALERTS.log" 'spooled at')" 0
eq L5s_no_tmp    "$(find "$C/orc" -name '*.tmp.*' | wc -l)" 0

# --- L5t: the production turn — Telegram first, spool + alert, next turn drains
C=$(setup l5t)
BEAT_RC=1 turn "$C" "{\"command_id\":\"21082\",\"origin\":\"\",\"chat_id\":\"$GROUP\"}"
eq L5t_telegram  "$(cnt "$C/curl.log" sendMessage)" 1
eq L5t_deliver   "$(cat "$C/deliver.rc" 2>/dev/null)" 0
eq L5t_spool     "$(jq -r .command_id "$C/orc/state/chat-reply-spool/21082.json" 2>/dev/null)" 21082
eq L5t_alerts    "$(nalerts "$C")" 1
eq L5t_alert_id  "$(cnt "$C/logs/ALERTS.log" 'chat_reply for command 21082 did not reach the console after 3 tries — spooled at')" 1
: > "$C/beats.jsonl"
BEAT_RC=0 turn "$C" "{\"command_id\":\"21095\",\"origin\":\"\",\"chat_id\":\"$GROUP\"}"
eq L5t_drained   "$(nspool "$C")" 0
eq L5t_order     "$(chat_ids "$C")" "21082,21095"
eq L5t_alerts2   "$(nalerts "$C")" 1

# --- L6: a 200 000-char reply is cut in characters, with the marker ---------
# Two-byte characters: a byte cut would land at 7000 characters with no marker.
C=$(setup l6)
head -c 200000 /dev/zero | tr '\0' 'x' | sed 's/x/é/g' > "$C/big"
eq L6_rc         "$(lr "$C" 21087 "$C/big")" 0
jq -j 'select(.kind=="chat_reply")|.text' "$C/beats.jsonl" > "$C/big.text"
N=$(wc -m < "$C/big.text")
[ "$N" -le 14000 ] && ok || bad "L6 the beat text must be <= 14000 chars, got $N"
eq L6_marker     "$(tail -c "$(printf '%s' "$MARK" | wc -c)" "$C/big.text")" "$MARK"
eq L6_kept       "$(head -c $((13880 * 2)) "$C/big.text" | tr -d 'é' | wc -c)" 0
eq L6_join       "$(head -c $((13880 * 2 + 3)) "$C/big.text" | tail -c 3 | od -An -c | tr -s " ")" " \n \n ["
# L6b: exactly MAX four-byte emoji is not over the cap and round-trips unchanged.
C=$(setup l6b)
head -c 14000 /dev/zero | tr '\0' 'x' | sed 's/x/\xf0\x9f\x9a\x80/g' | tr -d '\n' > "$C/emoji"
eq L6b_rc        "$(lr "$C" 21088 "$C/emoji")" 0
jq -j 'select(.kind=="chat_reply")|.text' "$C/beats.jsonl" > "$C/emoji.out"
cmp -s "$C/emoji.out" "$C/emoji" && ok || bad "L6b 14000 emoji must round-trip byte for byte"

# --- L11: hostile text round-trips byte-exact and stays a chat_reply ---------
C=$(setup l11)
printf 'he said "hi"\n{"kind":"alert"}\n\xf0\x9f\x9a\x80' > "$C/reply"
eq L11_rc        "$(lr "$C" 21086)" 0
jq -j 'select(.kind=="chat_reply")|.text' "$C/beats.jsonl" > "$C/text.out"
cmp -s "$C/text.out" "$C/reply" && ok || bad "L11 quotes/newlines/emoji/\"kind\":\"alert\" must round-trip byte for byte"
eq L11_kind      "$(jq -r .kind "$C/beats.jsonl" | sort -u)" chat_reply

# --- M1-M4: break the shipped behavior, the pinning case must go red --------
# mutate <dir> <sed-expr> — edits the installed lib; red if the edit changed nothing
mutate() {
  local f="$1/bin/lib/orc-reply-ledger.sh"
  cp "$f" "$f.orig"; sed -i "$2" "$f"
  cmp -s "$f" "$f.orig" && bad "mutant [$2] matched nothing in the lib"
  rm -f "$f.orig"
}
C=$(setup m1); mutate "$C" '/^  ledger_drain$/d'; case_l5ab "$C"
[ "$(nspool "$C")" != 0 ] && ok || bad "M1 dropping the ledger_drain call must turn L5b red"
C=$(setup m2); mutate "$C" '/_orl_spool "\$payload"/d'; case_l5ab "$C"
[ ! -s "$C/a.spool" ] && ok || bad "M2 dropping the _orl_spool call must turn L5a red"
C=$(setup m4); mutate "$C" 's/>\/dev\/null 2>&1 || break$/>\/dev\/null 2>\&1 \&\& rm -f "$f"/'
spool_file "$C" s1.json 41001 "2026-10-01 00:00:01"; spool_file "$C" s2.json 41002 "2026-10-01 00:00:02"
BEAT_RC=1 lr "$C" 21095 >/dev/null
[ "$(chat_ids "$C")" != "41001,21095,21095,21095" ] && ok || bad "M4 a drain that keeps going after a failed try must turn L5g red"
C=$(setup m3); mutate "$C" 's/(\$raw | if length > \$max then .*end) as \$t/$raw as $t/'
head -c 200000 /dev/zero | tr '\0' 'x' | sed 's/x/é/g' > "$C/big"; lr "$C" 21087 "$C/big" >/dev/null
[ "$(cnt "$C/beats.jsonl" 'reply cut at 13880 chars')" = 0 ] && ok || bad "M3 replacing the jq cut must turn L6 red"

echo "orchestrate-reply-spool (BH-4995.2) [$NOW]: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
