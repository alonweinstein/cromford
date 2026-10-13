#!/bin/bash
# bin/edit-feedback-hook.sh — "red squigglies for agents" (project-4 pilot, 2026-08-23).
#
# PostToolUse hook on Edit|Write|MultiEdit during execute stages. Two layers:
#   1. eslint --quiet on the file just edited, synchronously (~3s warm) — the
#      instant nudge for what lint can see.
#   2. a DEBOUNCED background `tsc --noEmit --incremental` over the project
#      (~26s warm on project-4); its errors are delivered on the NEXT edit after it
#      finishes, once per completed run. Type errors reach the model ~30s after
#      the mistake instead of at the verify step half a build later.
# prisma generate runs before each background check when a schema exists
# (prisma/schema.prisma, or the prisma/schema/ folder since BH-1171) — a
# stale generated client fakes type errors (bit project-3 AND project-4 on 2026-08-23).
#
# Exit 2 + stderr = feedback into the model's context (PostToolUse contract).
# Silent exit 0 when there is nothing to say. Enabled per-project via
# EDIT_FEEDBACK=1 in env/<project>.env, wired through agent-call.sh --settings
# (bin/edit-feedback-settings.json). Measurement: cost-per-pr.csv before/after.
set -u
IN=$(cat)
FILE=$(jq -r '.tool_input.file_path // empty' <<<"$IN" 2>/dev/null)
CWD=$(jq -r '.cwd // empty' <<<"$IN" 2>/dev/null)
case "$FILE" in *.ts|*.tsx) ;; *) exit 0 ;; esac
[ -n "$CWD" ] && [ -d "$CWD" ] && [ -f "$CWD/tsconfig.json" ] || exit 0
cd "$CWD" || exit 0
KEY=$(printf '%s' "$CWD" | md5sum | cut -c1-8)
D="/tmp/edit-feedback-$KEY"; mkdir -p "$D"
FB=""

# --- layer 1: eslint on the edited file (errors only, capped) ---------------
if [ -f "$FILE" ] && { [ -f eslint.config.mjs ] || [ -f eslint.config.js ] || [ -f .eslintrc.json ]; }; then
  L=$(timeout 25 npx eslint --no-color --quiet "$FILE" 2>/dev/null | head -20)
  [ -n "$L" ] && FB="eslint on the file you just edited:
$L"
fi

# --- layer 2: deliver the last completed background typecheck, once ---------
if [ -s "$D/diags.txt" ] && { [ ! -f "$D/reported" ] || [ "$D/diags.txt" -nt "$D/reported" ]; }; then
  TD=$(head -40 "$D/diags.txt")
  FB="$FB

tsc --noEmit over the whole project (background check, may lag your last edit by ~30s):
$TD"
  touch -r "$D/diags.txt" "$D/reported"
fi

# --- layer 3: kick a fresh background check if none is running --------------
if mkdir "$D/running" 2>/dev/null; then
  # Heap: 70% of RAM, capped at 12288MB — project-4 needs >4GB (husky's 4096 cap
  # was the historical OOM), fly builders have less RAM than the boxes.
  MEMMB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 8192)
  HEAP=$(( MEMMB * 7 / 10 )); [ "$HEAP" -gt 12288 ] && HEAP=12288
  setsid bash -c "cd '$CWD' || exit
    { [ -f prisma/schema.prisma ] || [ -d prisma/schema ]; } && npx prisma generate >/dev/null 2>&1
    NODE_OPTIONS=--max-old-space-size=$HEAP timeout 600 npx tsc --noEmit --incremental \
      --tsBuildInfoFile '$D/tsbuildinfo' 2>&1 | grep 'error TS' | head -60 > '$D/diags.next'
    mv '$D/diags.next' '$D/diags.txt'
    rm -rf '$D/running'" >/dev/null 2>&1 &
fi

if [ -n "$FB" ]; then
  printf '%s\n' "$FB" >&2
  echo "$(date -u '+%F %TZ') delivered $(printf '%s' "$FB" | wc -c)B for $FILE" >> "$D/log"
  exit 2
fi
exit 0
