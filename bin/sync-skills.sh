#!/bin/bash
# bin/sync-skills.sh — deploy the repo's Claude Code skills onto this box.
#
# Why (SDLC item 6, 2026-08-29): the procedures a harness session performs over
# and over — applying a judged migration, driving prod as a real user, deploying
# Mission Control — lived as prose inside prompt blobs and inside one operator's
# head. A prompt blob costs tokens on every run whether or not the run needs it,
# drifts from the scripts it describes, and cannot be tested. A skill is loaded
# ON DEMAND by its description, ships in the repo next to the scripts it
# documents, and moves through the same review + sync path as bin/ and prompts/.
#
# Claude Code discovers skills at ~/.claude/skills/<name>/SKILL.md, so that is
# where these are deployed. Same rsync discipline as harness-sync.sh: temp file
# + rename, so a running session never reads a half-written file.
#
# NEVER --delete the destination: it also holds skills this repo does not own
# (the plugin symlinks Claude Code installs there). We add and update ours; we
# do not curate someone else's directory. A destination entry that is a SYMLINK
# is left alone entirely — following it would write through into a directory
# this repo has no claim on.
#
# Env overrides exist for TESTS only, except the last two, which are also a
# production knob (BH-4064): bin/harness-sync.sh runs this a second time with
# SKILLS_SUBDIR=orchestrator/skills and CLAUDE_SKILLS_DIR under
# /root/orchestrator/.claude/skills, so Archie's own skills reach the hub
# orchestrator's Claude session.
#   HARNESS_CHECKOUT   where to read skills from    (default /root/harness-checkout)
#   SKILLS_SUBDIR      which dir of the checkout    (default skills)
#   CLAUDE_SKILLS_DIR  where to write them          (default /root/.claude/skills)
#
# A skill's replays/ dir (orchestrator/skills/<name>/replays, the recorded
# cases bin/archie-skill-replay.sh checks) is test data and is never deployed.
#
# A destination skill dir holding `.archie-learned` (BH-4066) is skipped: Archie
# changed it on this box through bin/archie-learn.sh after its replays passed,
# and the learned copy lives in /root/orchestrator/learned/skills/. Getting the
# edit into the repo is a normal PR; the weekly learning report lists such
# skills. When that PR lands (the repo SKILL.md equals the live one byte for
# byte) the marker is removed and the skill deploys normally again. Nothing
# writes that marker under /root/.claude/skills.
#
# usage: sync-skills.sh [--check]
#   --check   report what would deploy; no writes. Exit 0 always (nothing to
#             deploy is a normal state, not a failure).
set -uo pipefail
CHECKOUT="${HARNESS_CHECKOUT:-/root/harness-checkout}"
DEST="${CLAUDE_SKILLS_DIR:-/root/.claude/skills}"
LOG="${HARNESS_LOG_DIR:-/root/harness/logs}/agent-rules.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
MODE="${1:-deploy}"

SUBDIR="${SKILLS_SUBDIR:-skills}"
SRC="$CHECKOUT/$SUBDIR"
[ -d "$SRC" ] || { echo "no $SUBDIR/ in $CHECKOUT"; exit 0; }

DEPLOYED=0 SKIPPED=0
for D in "$SRC"/*/; do
  [ -f "$D/SKILL.md" ] || continue
  NAME=$(basename "$D")
  # Frontmatter is the contract Claude Code reads to decide relevance. A file
  # without a name: line would install as a skill that can never be selected,
  # which is worse than not installing it — it looks deployed.
  if ! head -20 "$D/SKILL.md" | grep -qE '^name: *[a-z0-9-]+ *$'; then
    echo "$(STAMP) SKIP skill $NAME — SKILL.md has no 'name:' frontmatter" >> "$LOG" 2>/dev/null
    echo "skip (no name: frontmatter): $NAME"; SKIPPED=$((SKIPPED+1)); continue
  fi
  if [ -L "$DEST/$NAME" ]; then
    echo "$(STAMP) SKIP skill $NAME — destination is a symlink this repo does not own" >> "$LOG" 2>/dev/null
    echo "skip (symlink, not ours): $NAME"; SKIPPED=$((SKIPPED+1)); continue
  fi
  # >>> archie learned
  # BH-4066: a skill Archie changed on this box through bin/archie-learn.sh
  # (replays passed, then promoted) carries .archie-learned. A deploy must not
  # silently put the repo's older copy back over a replay-proven edit. Once
  # the repo carries the learned SKILL.md byte for byte (someone upstreamed it)
  # the marker is dropped and the skill takes repo deploys again.
  if [ -f "$DEST/$NAME/.archie-learned" ] && cmp -s "$D/SKILL.md" "$DEST/$NAME/SKILL.md"; then
    if [ "$MODE" = "--check" ]; then
      echo "would deploy (upstreamed, learned marker cleared): $NAME"; DEPLOYED=$((DEPLOYED+1)); continue
    elif rm -f "$DEST/$NAME/.archie-learned"; then
      echo "$(STAMP) skill $NAME upstreamed — repo matches the learned copy, marker cleared" >> "$LOG" 2>/dev/null
      echo "upstreamed: $NAME"
    fi
  fi
  if [ -f "$DEST/$NAME/.archie-learned" ]; then
    echo "$(STAMP) SKIP skill $NAME — learned on this box (replay-gated edit)" >> "$LOG" 2>/dev/null
    echo "skip (learned here): $NAME"; SKIPPED=$((SKIPPED+1)); continue
  fi
  # <<< archie learned
  if [ "$MODE" = "--check" ]; then
    echo "would deploy: $NAME"; DEPLOYED=$((DEPLOYED+1)); continue
  fi
  mkdir -p "$DEST/$NAME" || { echo "skip (cannot mkdir): $NAME"; SKIPPED=$((SKIPPED+1)); continue; }
  if rsync -a --exclude=replays/ "$D" "$DEST/$NAME/" 2>>"$LOG"; then
    echo "deployed: $NAME"; DEPLOYED=$((DEPLOYED+1))
  else
    echo "FAILED: $NAME"; SKIPPED=$((SKIPPED+1))
  fi
done

[ "$MODE" = "--check" ] || echo "$(STAMP) skills synced: $DEPLOYED deployed, $SKIPPED skipped -> $DEST" >> "$LOG" 2>/dev/null
echo "skills: $DEPLOYED $([ "$MODE" = "--check" ] && echo pending || echo deployed), $SKIPPED skipped ($DEST)"
exit 0
