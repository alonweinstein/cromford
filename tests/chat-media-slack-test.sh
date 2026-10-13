#!/bin/bash
# tests/chat-media-slack-test.sh — chat attachments arrive from either transport
# and a failed download says what went wrong (BH-618).
#
# This runs the REAL bin/chat-media.sh and the REAL bin/tg-media.sh wrapper
# against a fake curl, a scratch $HARNESS and a scratch media dir. The rules it
# pins, each of them a way this lane can lie:
#   - a Slack file is fetched with the bot token in the Authorization header and
#     lands in the same inbox/media path the Telegram branch has always used;
#   - never `curl -sf`: the HTTP status and a body excerpt reach ALERTS.log, so
#     a 403 is a readable failure instead of a silent empty note;
#   - the 20MB cap refuses the download rather than filling the disk;
#   - a 2xx page of HTML is Slack's login screen, not a file — a bad token must
#     not "succeed" with a web page saved as the attachment;
#   - the token never appears in stdout, in a note, or in any log;
#   - the Telegram branch still works, through the tg-media.sh name the poller
#     calls, and a mixed payload sends each item to its own API.
#
# Run from anywhere: tests/chat-media-slack-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: [$2] does not contain [$3]" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: [$2] must not contain [$3]" ;; *) ok ;; esac; }
cnt() { local n=0; [ -f "$1" ] && n=$(grep -c -- "$2" "$1"); echo "${n:-0}"; }

# The value says fixture so the mirror's leak guard reads it as one (mapping.
# FIXTURE_MARKERS). Every assertion below goes through $TOKEN, never a literal.
TOKEN=xoxb-fixture-testtoken-1234567890
URLP=https://files.slack.com/files-pri/T01-F02/screenshot.png

setup() { # setup <name> [token] -> prints the case dir
  local c="$T/$1"
  rm -rf "$T/$1"; mkdir -p "$c/bin" "$c/env" "$c/logs" "$c/media" "$c/fake"
  printf 'TELEGRAM_BOT_TOKEN=tgtest\nTELEGRAM_CHAT_ID=-100123\nSLACK_BOT_TOKEN=%s\n' "${2-$TOKEN}" > "$c/env/global.env"
  cat > "$c/fake/curl" <<'FAKE'
#!/bin/bash
# fake curl: records argv, honours -o/-D/-w/--max-filesize, answers the Bot API
# and Slack from FAKE_* env.
printf '%s\n' "$*" >> "$CURL_LOG"
OUTF=""; HDRF=""; WFMT=""; MAXSZ=""; URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o|-D|-w|--max-filesize|-H|-d|-F|--data-urlencode|--max-time)
      case "$1" in
        -o) OUTF="$2" ;;
        -D) HDRF="$2" ;;
        -w) WFMT="$2" ;;
        --max-filesize) MAXSZ="$2" ;;
      esac
      shift 2 ;;
    -*) shift ;;
    *) URL="$1"; shift ;;
  esac
done
case "$URL" in
  *getFile*) printf '%s' '{"ok":true,"result":{"file_path":"photos/file_7.jpg"}}'; exit 0 ;;
  *api.telegram.org/file/*) [ -n "$OUTF" ] && printf 'telegram-bytes' > "$OUTF"; exit 0 ;;
esac
CLEN="${FAKE_CONTENT_LENGTH:-14}"
[ -n "$HDRF" ] && printf 'HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %s\r\n\r\n' \
  "${FAKE_HTTP:-200}" "${FAKE_CT:-image/png}" "$CLEN" > "$HDRF"
# the connection died: no body, no status written, curl's own rc
[ "${FAKE_CURL_RC:-0}" = 0 ] || exit "$FAKE_CURL_RC"
if [ -n "$MAXSZ" ] && [ "$CLEN" -gt "$MAXSZ" ]; then
  [ -n "$WFMT" ] && printf '%s' "${FAKE_HTTP:-200}"
  exit 63
fi
[ -n "$OUTF" ] && printf '%s' "${FAKE_BODY:-slack-bytes}" > "$OUTF"
[ -n "$WFMT" ] && printf '%s' "${FAKE_HTTP:-200}"
exit 0
FAKE
  cat > "$c/bin/transcribe.sh" <<'FAKE'
#!/bin/bash
printf 'this is what he said\n'
FAKE
  chmod +x "$c/fake/curl" "$c/bin/transcribe.sh"
  printf '%s' "$c"
}

run_media() { # run_media <dir> <payload-json> [script] -> stdout of the composer
  local c="$1" p="$2" s="${3:-chat-media.sh}"
  printf '%s\n' "$p" > "$c/payload.json"
  PATH="$c/fake:$PATH" CURL_LOG="$c/curl.log" HARNESS="$c" ORC_MEDIA_DIR="$c/media" \
    FAKE_HTTP="${FAKE_HTTP:-200}" FAKE_CT="${FAKE_CT:-image/png}" \
    FAKE_BODY="${FAKE_BODY:-slack-bytes}" FAKE_CONTENT_LENGTH="${FAKE_CONTENT_LENGTH:-14}" \
    FAKE_CURL_RC="${FAKE_CURL_RC:-0}" \
    "$DIR/bin/$s" "$c/payload.json" 2>"$c/stderr.log"
}

files_in() { find "$1" -type f 2>/dev/null | wc -l | tr -d ' '; }

SLACK_IMG='{"text":"look at this","media":[{"kind":"photo","url_private":"'"$URLP"'","file_name":"screenshot.png","mime":"image/png"}]}'

# --- 1. a Slack image downloads with the bearer token and is saved -----------
C=$(setup img); OUT=$(run_media "$C" "$SLACK_IMG")
has  c1_bearer "$(cat "$C/curl.log")" "Authorization: Bearer $TOKEN"
has  c1_url    "$(cat "$C/curl.log")" "$URLP"
eq   c1_saved  "$(files_in "$C/media")" 1
has  c1_named  "$OUT" "$C/media/"
has  c1_name   "$OUT" "screenshot.png"
has  c1_text   "$OUT" "look at this"
eq   c1_quiet  "$(cnt "$C/logs/ALERTS.log" .)" 0
# No --fail on any curl: it swallows the status, and the status is the whole
# point of the ALERTS line below. Pinned as source text because the absence of a
# flag is not observable from the outside — a `curl -sf` that 403s and one that
# is simply blocked look identical from here.
eq   c1_no_sf   "$(grep -c -- 'curl -sf' "$DIR/bin/chat-media.sh")" 0
eq   c1_no_fail "$(grep -cE 'curl .*(--fail|[[:space:]]-[a-zA-Z]*f[a-zA-Z]*[[:space:]])' "$DIR/bin/chat-media.sh")" 0
# and the guard itself must be able to fail: the same pattern over a fixture
[ "$(printf 'curl -sf "$URL"\n' | grep -c -- 'curl -sf')" = 1 ] && ok || bad "the curl -sf guard matches nothing, so it proves nothing"

# --- 2. over the cap: refused before the bytes land --------------------------
C=$(setup big); OUT=$(FAKE_CONTENT_LENGTH=30000000 run_media "$C" "$SLACK_IMG")
eq   c2_no_file "$(files_in "$C/media")" 0
eq   c2_alert   "$(cnt "$C/logs/ALERTS.log" .)" 1
has  c2_says_cap "$(cat "$C/logs/ALERTS.log")" "20971520"
has  c2_note    "$OUT" "20971520"
has  c2_clen    "$(cat "$C/logs/ALERTS.log")" "30000000"

# --- 3. HTTP 403: status AND body excerpt in the ALERTS line -----------------
C=$(setup forbidden)
OUT=$(FAKE_HTTP=403 FAKE_BODY='{"ok":false,"error":"not_allowed"}' run_media "$C" "$SLACK_IMG")
eq   c3_no_file "$(files_in "$C/media")" 0
eq   c3_alert   "$(cnt "$C/logs/ALERTS.log" .)" 1
has  c3_status  "$(cat "$C/logs/ALERTS.log")" "http=403"
has  c3_body    "$(cat "$C/logs/ALERTS.log")" "not_allowed"
has  c3_note    "$OUT" "download"

# --- 4. the token never leaks -----------------------------------------------
hasnt c4_stdout "$OUT" "$TOKEN"
eq    c4_logs   "$(grep -rl "$TOKEN" "$C/logs" 2>/dev/null | wc -l | tr -d ' ')" 0
hasnt c4_stderr "$(cat "$C/stderr.log")" "$TOKEN"

# --- 5. Telegram still works, through the name the poller calls --------------
C=$(setup tg)
TG_ITEM='{"text":"a photo","media":[{"kind":"photo","file_id":"AgACAg","file_name":"shot.jpg","mime":"image/jpeg"}]}'
OUT=$(run_media "$C" "$TG_ITEM" tg-media.sh)
eq   c5_getfile "$(cnt "$C/curl.log" getFile)" 1
eq   c5_download "$(cnt "$C/curl.log" 'api.telegram.org/file/bottgtest')" 1
eq   c5_no_bearer "$(cnt "$C/curl.log" Authorization)" 0
eq   c5_saved   "$(files_in "$C/media")" 1
has  c5_named   "$OUT" "shot.jpg"

# --- 6. a Slack voice note goes through the existing transcribe.sh -----------
C=$(setup voice)
SL_AUDIO='{"text":"","media":[{"kind":"voice","url_private":"https://files.slack.com/files-pri/T01-F03/audio.m4a","file_name":"audio.m4a","mime":"audio/mp4","duration":7}]}'
OUT=$(FAKE_CT=audio/mp4 run_media "$C" "$SL_AUDIO")
has  c6_transcript "$OUT" "this is what he said"
has  c6_duration   "$OUT" "7s"
eq   c6_saved      "$(files_in "$C/media")" 1

# --- 7. no token: the item is refused, and no request is made ----------------
C=$(setup notoken "")
OUT=$(run_media "$C" "$SLACK_IMG")
eq   c7_no_curl "$(cnt "$C/curl.log" .)" 0
eq   c7_alert   "$(cnt "$C/logs/ALERTS.log" .)" 1
has  c7_says    "$(cat "$C/logs/ALERTS.log")" "SLACK_BOT_TOKEN"
has  c7_note    "$OUT" "SLACK_BOT_TOKEN"
eq   c7_no_file "$(files_in "$C/media")" 0

# --- 8. a 200 of HTML is Slack's login page, not a file ---------------------
C=$(setup html)
OUT=$(FAKE_CT="text/html; charset=utf-8" FAKE_BODY='<html>sign in</html>' run_media "$C" "$SLACK_IMG")
eq   c8_no_file "$(files_in "$C/media")" 0
eq   c8_alert   "$(cnt "$C/logs/ALERTS.log" .)" 1
has  c8_says    "$(cat "$C/logs/ALERTS.log")" "text/html"
hasnt c8_token  "$(cat "$C/logs/ALERTS.log")" "$TOKEN"

# --- 9. a mixed payload: each item takes its own branch ----------------------
C=$(setup mixed)
MIX='{"text":"both","media":[{"kind":"photo","url_private":"'"$URLP"'","file_name":"a.png","mime":"image/png"},{"kind":"photo","file_id":"AgACAg","file_name":"b.jpg","mime":"image/jpeg"}]}'
OUT=$(run_media "$C" "$MIX")
eq   c9_saved    "$(files_in "$C/media")" 2
eq   c9_slack    "$(cnt "$C/curl.log" "$URLP")" 1
eq   c9_telegram "$(cnt "$C/curl.log" getFile)" 1
has  c9_a        "$OUT" "a.png"
has  c9_b        "$OUT" "b.jpg"

# --- 10. an item with neither a url nor a file id is skipped silently --------
C=$(setup empty)
OUT=$(run_media "$C" '{"text":"hm","media":[{"kind":"photo","url_private":"","file_name":"x.png"}]}')
eq   c10_no_curl "$(cnt "$C/curl.log" .)" 0
eq   c10_no_file "$(files_in "$C/media")" 0
has  c10_text    "$OUT" "hm"

# --- 11. the connection died: a transport failure is not an HTTP failure -----
C=$(setup down)
OUT=$(FAKE_CURL_RC=7 run_media "$C" "$SLACK_IMG")
eq   c11_no_file "$(files_in "$C/media")" 0
eq   c11_alert   "$(cnt "$C/logs/ALERTS.log" .)" 1
has  c11_rc      "$(cat "$C/logs/ALERTS.log")" "curl_rc=7"
# no status came back at all, and a blank one would read as an empty answer
has  c11_status  "$(cat "$C/logs/ALERTS.log")" "http=none"

echo "chat-media-slack-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
