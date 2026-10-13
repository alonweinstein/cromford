#!/bin/bash
# bin/secret-read-guard-install.sh [--settings <file>] [--no-backup] — merge the BH-3689
# secret-read tripwire into a Claude Code settings.json.
#
# Boxes don't need this: rules/settings.json already carries the entry with the
# /root/harness path and update-runners.sh copies it verbatim. This is for the
# places whose harness lives elsewhere: fly/builder-runner.sh runs it after its
# per-job settings copy (HARNESS=/data/harness), and a Mac runs it once by hand
# from its checkout (re-run after moving the checkout).
#
# It points ONE PreToolUse entry {matcher "Read|Grep|Bash"} at the
# secret-read-guard.py beside this script. Any existing hook whose command ends
# in /bin/secret-read-guard.py is dropped first, so a re-run replaces instead of
# duplicating; every other key and hook is kept. Default target is
# $HOME/.claude/settings.json; an absent file is created. An existing file is
# backed up to <file>.bak-<UTC stamp> and replaced via temp file + mv.
# --no-backup skips that copy: fly/builder-runner.sh passes it because the file
# it rewrites is a fresh copy of canon, and a long-lived builder would otherwise
# gain one .bak per job forever.
#
# rc 0 installed; rc 1 jq missing or the file is not a JSON object (untouched);
# rc 2 usage.
set -uo pipefail
SETTINGS="$HOME/.claude/settings.json"
BACKUP=1
while [ $# -gt 0 ]; do
  case "$1" in
    --settings) SETTINGS="${2:-}"; shift 2 ;;
    --no-backup) BACKUP=0; shift ;;
    *) echo "usage: $0 [--settings <file>] [--no-backup]" >&2; exit 2 ;;
  esac
done
[ -n "$SETTINGS" ] || { echo "usage: $0 [--settings <file>] [--no-backup]" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "secret-read-guard-install: jq not found" >&2; exit 1; }
GUARD="$(cd "$(dirname "$0")" && pwd)/secret-read-guard.py"

mkdir -p "$(dirname "$SETTINGS")" || exit 1
SRC="$SETTINGS"; [ -f "$SETTINGS" ] || SRC=/dev/null
TMP=$(mktemp "$SETTINGS.tmp.XXXXXX") || exit 1
if ! { if [ "$SRC" = /dev/null ]; then echo '{}'; else cat "$SRC"; fi; } | jq --arg cmd "$GUARD" '
  def isg: ((.command // "") | endswith("/bin/secret-read-guard.py"));
  if type != "object" then error("settings is not a JSON object") else . end
  | .hooks = (.hooks // {})
  | .hooks.PreToolUse = (
      [ (.hooks.PreToolUse // [])[]
        | if any(.hooks[]?; isg) then (.hooks |= map(select(isg | not))) | select(.hooks | length > 0) else . end ]
      + [ { matcher: "Read|Grep|Bash", hooks: [ { type: "command", command: $cmd, timeout: 10 } ] } ])
' > "$TMP"; then
  rm -f "$TMP"
  echo "secret-read-guard-install: $SETTINGS is not a JSON object; left untouched" >&2
  exit 1
fi
[ "$SRC" = /dev/null ] || [ "$BACKUP" = 0 ] || cp -p "$SETTINGS" "$SETTINGS.bak-$(date -u +%Y%m%d%H%M%S)" || { rm -f "$TMP"; exit 1; }
chmod 644 "$TMP" && mv "$TMP" "$SETTINGS" || { rm -f "$TMP"; exit 1; }
echo "secret-read-guard-install: $SETTINGS -> $GUARD"
