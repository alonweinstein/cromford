#!/bin/bash
# Turn a chat command payload (text + optional media[]) into the final
# orchestrator message text. Downloads each attachment into
# /root/orchestrator/inbox/media/ and transcribes anything with audio.
# usage: chat-media.sh <payload-json-file>   — prints composed message to stdout.
#
# TWO TRANSPORTS, ONE INBOX (BH-618). This was tg-media.sh, Telegram only;
# bin/tg-media.sh is now a wrapper on this file and is still what the poller
# calls. The branch is chosen PER ITEM by the item's own shape, never by the
# payload's transport: `url_private` is a Slack file (fetched with the bot token
# in an Authorization header), `file_id` is a Telegram file (fetched through the
# Bot API). A mixed or older payload therefore cannot end up at the wrong API.
#
# Payload contract (worker side): {"text":"caption or message",
#   "media":[{"kind":"photo|document|voice|audio|video|video_note",
#             "file_id":"...",          # telegram
#             "url_private":"https://files.slack.com/...",   # slack
#             "file_name":"...","mime":"...","size":N,"duration":N}]}
#
# A download that fails is never silent: the HTTP status and a body excerpt go
# to logs/ALERTS.log and a note goes into the message, so the orchestrator says
# out loud that it could not read the file. No download here uses curl's --fail
# (or its -f short form), which would throw the status away and leave us with
# nothing to report; and the Slack token appears only in curl's argv — never in
# a note, a log line or stdout.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
PAYLOAD="${1:?payload file}"
# shellcheck source=bin/lib/env-path.sh
. "$HARNESS/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "$HARNESS/env"; }
HENV=$(harness_env_dir)
set -a; . "$HENV/global.env" 2>/dev/null; set +a
TG="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN:-}"
MEDIA_DIR="${ORC_MEDIA_DIR:-/root/orchestrator/inbox/media}"
# Telegram's Bot API caps a download at 20MB and Slack does not, so the cap is
# ours to hold. Editable per box; the constant is the documented fallback.
MAX_BYTES="${CHAT_MEDIA_MAX_BYTES:-20971520}"
mkdir -p "$MEDIA_DIR"

alert() { # one ALERTS line — what failed, on which file, with the real status
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [chat-media] $1" >> "$HARNESS/logs/ALERTS.log" 2>/dev/null || true
}
is2xx() { case "$1" in 2[0-9][0-9]) return 0 ;; *) return 1 ;; esac; }

TEXT=$(jq -r '.text // ""' "$PAYLOAD")
N=$(jq -r '.media | length' "$PAYLOAD" 2>/dev/null || echo 0)
[ "$N" = "null" ] && N=0

# Per-item state, set by the loop and read by the two fetchers.
KIND=""; NAME=""; MIME=""; DUR=""; SIZE=""; FID=""; URL=""; DEST=""; FAILNOTE=""; TS=""

slack_fetch() { # slack_fetch <index> — sets DEST; rc 1 = FAILNOTE says why
  local i="$1" hdr http crc ctype body ext
  if [ -z "${SLACK_BOT_TOKEN:-}" ]; then
    alert "SLACK_BOT_TOKEN is not set on this box — cannot download ${NAME:-$KIND}"
    FAILNOTE="[${KIND} attachment${NAME:+ $NAME}: not downloaded — SLACK_BOT_TOKEN is not set on this box]"
    return 1
  fi
  # A size the payload already declares costs nothing to refuse, and refusing it
  # here means no request at all for a file we would drop anyway.
  case "$SIZE" in
    ''|*[!0-9]*) ;;
    *) if [ "$SIZE" -gt "$MAX_BYTES" ]; then
         alert "slack download skipped: declared size $SIZE is over the $MAX_BYTES byte cap file=${NAME:-$KIND}"
         FAILNOTE="[${KIND} attachment${NAME:+ $NAME}: skipped, it is larger than the $MAX_BYTES byte cap — ask the operator to resend it smaller]"
         return 1
       fi ;;
  esac
  ext="${URL##*.}"; case "$ext" in */*|"$URL") ext=bin ;; esac
  DEST="$MEDIA_DIR/$TS-$i-${NAME:-$KIND.$ext}"
  hdr=$(mktemp)
  http=$(curl -s --max-time 120 --max-filesize "$MAX_BYTES" -D "$hdr" -o "$DEST" \
    -w '%{http_code}' -H "Authorization: Bearer $SLACK_BOT_TOKEN" "$URL")
  crc=$?
  ctype=$(grep -i '^content-type:' "$hdr" 2>/dev/null | tail -1 | cut -d: -f2- | tr -d '\r' | sed 's/^ *//')
  # curl printed no status at all (it died before a response). Saying "HTTP "
  # would read as a blank status rather than as no answer, so name it.
  [ -n "$http" ] || http=none
  # 63 is curl's own "the file is bigger than you allowed" — a different fact
  # from a transport failure and from an HTTP error, so it is said differently.
  if [ "$crc" = 63 ]; then
    local clen
    clen=$(grep -i '^content-length:' "$hdr" 2>/dev/null | tail -1 | tr -cd '0-9')
    alert "slack download skipped: over the $MAX_BYTES byte cap (Content-Length ${clen:-unknown}) file=${NAME:-$KIND}"
    FAILNOTE="[${KIND} attachment${NAME:+ $NAME}: skipped, it is larger than the $MAX_BYTES byte cap — ask the operator to resend it smaller]"
    rm -f "$DEST" "$hdr"; DEST=""; return 1
  fi
  if [ "$crc" != 0 ] || ! is2xx "$http"; then
    body=$(head -c 200 "$DEST" 2>/dev/null | tr '\n\r\t' '   ')
    alert "slack download failed http=$http curl_rc=$crc body=$body file=${NAME:-$KIND}"
    FAILNOTE="[${KIND} attachment${NAME:+ $NAME}: download from Slack failed (HTTP $http) — say so in the reply]"
    rm -f "$DEST" "$hdr"; DEST=""; return 1
  fi
  # A 200 of HTML is Slack's sign-in page, which is what a missing or wrong
  # token gets you. Saving it would put a web page in the inbox and call it an
  # attachment.
  case "$ctype" in
    text/html*)
      alert "slack download failed http=$http content-type=$ctype — that is Slack's sign-in page, so SLACK_BOT_TOKEN is missing or not valid for this file=${NAME:-$KIND}"
      FAILNOTE="[${KIND} attachment${NAME:+ $NAME}: Slack answered its sign-in page instead of the file, so the bot token is wrong — say so in the reply]"
      rm -f "$DEST" "$hdr"; DEST=""; return 1 ;;
  esac
  if [ ! -s "$DEST" ]; then
    alert "slack download failed http=$http: the file came back empty file=${NAME:-$KIND}"
    FAILNOTE="[${KIND} attachment${NAME:+ $NAME}: downloaded empty from Slack — say so in the reply]"
    rm -f "$DEST" "$hdr"; DEST=""; return 1
  fi
  rm -f "$hdr"
  return 0
}

telegram_fetch() { # telegram_fetch <index> — sets DEST; rc 1 = FAILNOTE says why
  local i="$1" fp ext
  fp=$(curl -s --max-time 20 "$TG/getFile" -d "file_id=$FID" | jq -r '.result.file_path // ""')
  if [ -z "$fp" ]; then
    # Bot API caps downloads at 20MB; also covers expired/broken ids.
    FAILNOTE="[${KIND} attachment: download failed (likely >20MB or expired) — ask the operator to resend smaller]"
    return 1
  fi
  ext="${fp##*.}"; [ "$ext" = "$fp" ] && ext=bin
  DEST="$MEDIA_DIR/$TS-$i-${NAME:-$KIND.$ext}"
  if ! curl -s --max-time 120 -o "$DEST" "https://api.telegram.org/file/bot${TELEGRAM_BOT_TOKEN:-}/$fp" || [ ! -s "$DEST" ]; then
    FAILNOTE="[${KIND} attachment: download failed]"
    rm -f "$DEST"; DEST=""; return 1
  fi
  return 0
}

OUT="$TEXT"
if [ "$N" -gt 0 ]; then
  TS=$(date -u +%Y%m%d-%H%M%S)
  NOTES=""
  for i in $(seq 0 $((N - 1))); do
    ITEM=$(jq -c ".media[$i]" "$PAYLOAD")
    KIND=$(jq -r '.kind // "document"' <<<"$ITEM")
    FID=$(jq -r '.file_id // ""' <<<"$ITEM")
    URL=$(jq -r '.url_private // ""' <<<"$ITEM")
    NAME=$(jq -r '.file_name // ""' <<<"$ITEM" | tr -cd 'A-Za-z0-9._-')
    MIME=$(jq -r '.mime // ""' <<<"$ITEM")
    DUR=$(jq -r '.duration // ""' <<<"$ITEM")
    SIZE=$(jq -r '.size // ""' <<<"$ITEM")
    DEST=""; FAILNOTE=""

    if [ -n "$URL" ]; then
      slack_fetch "$i" || { NOTES+=$'\n'"$FAILNOTE"; continue; }
    elif [ -n "$FID" ]; then
      telegram_fetch "$i" || { NOTES+=$'\n'"$FAILNOTE"; continue; }
    else
      continue
    fi

    case "$KIND" in
      voice|audio|video_note|video)
        TR=$("$HARNESS/bin/transcribe.sh" "$DEST" 2>/dev/null)
        if [ -n "$TR" ]; then
          NOTES+=$'\n'"[${KIND}${DUR:+ ${DUR}s} from the operator — transcript]: $TR"
          NOTES+=$'\n'"(audio file: $DEST)"
        else
          NOTES+=$'\n'"[${KIND} attachment at $DEST — transcription FAILED, say so in the reply]"
        fi ;;
      *)
        NOTES+=$'\n'"[attachment${MIME:+ ($MIME)}: $DEST]" ;;
    esac
  done
  if [ -n "$NOTES" ]; then
    OUT+=$'\n'"$NOTES"
    OUT+=$'\n\n'"(Attachments above are saved locally. Read image/PDF files with the Read tool before answering; treat transcripts as the operator's spoken words.)"
  fi
fi
printf '%s\n' "$OUT"
