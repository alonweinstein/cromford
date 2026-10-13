#!/bin/bash
# tg-media.sh <payload-json-file> — the Telegram entry point, kept as a name.
# The downloader itself is bin/chat-media.sh since BH-618, when Slack files
# joined the same payload shape; it still handles a Telegram item exactly as
# this file did. bin/poll-commands.sh calls this name, and docs point at it, so
# it stays and forwards verbatim.
exec "$(dirname "${BASH_SOURCE[0]}")/chat-media.sh" "$@"
