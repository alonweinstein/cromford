# Telegram media intake — console worker patch spec

> Executor: the operator's LOCAL Claude Code (has the harness-console worker source + wrangler deploy).
> The HUB SIDE IS ALREADY LIVE (2026-07-25): `bin/tg-media.sh` + `bin/transcribe.sh` +
> the media branch in `bin/poll-commands.sh` are deployed on the hub and E2E-tested with a
> real Telegram file_id. Only the worker change below is missing.

## Goal
the operator sends photos/screenshots, files, and voice notes to the bound Telegram chat; the
orchestrator receives them (images/PDFs read natively, audio transcribed on-hub).

## What the worker must do
In the webhook handler (`/api/telegram/webhook`), where a `message` update currently
enqueues a `chat` command with payload `{"text": message.text}`:

Also accept messages carrying media. Enqueue the SAME `chat` command type with payload:

```json
{
  "text": "<message.caption or message.text or ''>",
  "media": [
    {"kind": "photo|document|voice|audio|video|video_note",
     "file_id": "...", "file_name": "...", "mime": "...", "duration": 123}
  ]
}
```

Mapping rules per Telegram message field:
- `message.photo` (array of sizes) → ONE item, kind `photo`, file_id of the LARGEST size
  (last element). No file_name; mime `image/jpeg`.
- `message.document` → kind `document`, file_id, `file_name: document.file_name`,
  `mime: document.mime_type`. (Screenshots sent "as file" arrive this way.)
- `message.voice` → kind `voice`, `duration: voice.duration`, mime `audio/ogg`.
- `message.audio` → kind `audio`, `file_name: audio.file_name`, `duration`, `mime_type`.
- `message.video` → kind `video`, `duration`, `mime_type`.
- `message.video_note` → kind `video_note`, `duration`.
- Omit absent fields; `media` omitted entirely for plain text (hub branches on
  `media | length > 0`, so old-shape payloads keep working — deploy order is safe either way).
- A media message with no caption is valid: `text: ""` — the hub still composes a message
  from the attachments alone.
- Keep the existing sender/chat-id authorization check exactly as is; media from any other
  chat is dropped like text is.

That's the whole worker change. No file downloading in the worker — the hub downloads via
the Bot API with its own token (`getFile` + `/file/bot<token>/<path>`), so file bytes never
transit the console. Bot API download cap is 20MB/file; the hub already handles the
too-big/expired case with an honest note to the orchestrator.

## Hub side (already deployed — for reference/rebuild)
- `bin/tg-media.sh <payload.json>` → downloads each item to
  `/root/orchestrator/inbox/media/<utc>-<n>-<name>`, transcribes voice/audio/video via
  `bin/transcribe.sh`, prints the composed orchestrator message.
- `bin/transcribe.sh <file>` → ffmpeg → 16k mono wav → faster-whisper `small` int8 on CPU
  (~4s for a short voice note on the 4-vCPU hub).
- `bin/poll-commands.sh` chat branch: payloads with media are processed in a background
  subshell (download/transcribe never stalls the poller), then handed to `orchestrate.sh`
  as usual.
- Hub-only deps (NOT in bootstrap-machine.sh — workers don't need them):
  `apt-get install -y ffmpeg python3-pip python3-venv espeak-ng`,
  `python3 -m venv /root/harness/venv-whisper && /root/harness/venv-whisper/bin/pip install faster-whisper`,
  model pre-pull: `WhisperModel("small", device="cpu", compute_type="int8", download_root="/root/harness/models")`.

## Acceptance test
1. Deploy worker. 2. the operator sends a screenshot with a caption → orchestrator reply references
the image's actual content. 3. the operator sends a voice note → reply answers the spoken question.
4. Plain-text messages still work (regression check).
