#!/bin/bash
# bin/iron-law-arm.sh <lane> — print the path of a Claude Code settings file that
# wires bin/iron-law-guard.sh as a Bash PreToolUse hook, so a conversational
# launcher can hand it to the CLI as `--settings <path>`. Prints NOTHING when the
# guard cannot be armed, and always exits 0.
#
# WHY THIS EXISTS AS A SEPARATE SCRIPT. bin/agent-call.sh already writes exactly
# this file for the pipeline stages (plan/execute/review/fix/qa/triage) — it is
# the other writer of $HARNESS/state/iron-law-guard-settings.json, using the same
# jq expression and the same tmp+mv publish, so two concurrent writers produce
# byte-identical content and neither needs a lock. But three sessions on a box
# never come through agent-call.sh at all: bin/orchestrate.sh, bin/box-chat.sh
# and bin/greenfield.sh are conversational turns with their own model ladders and
# their own `-c` continuation, not pipeline stages with an outfile and a runner
# choice. Routing them through agent-call.sh would mean giving it a second shape;
# giving them this helper instead is one line each.
#
# WHAT ARMING BUYS, TODAY. The family 6 classifier (destructive filesystem verbs)
# merged in #595 and bin/iron-law-guard.sh judges it on EVERY marked lane, not
# only the guarded build stages — lanes outside IRON_LAW_LANES keep their
# merge/deploy authority (families 1-5) and are still refused an `rm -rf` at a
# protected root. So a launcher that carries HARNESS_LANE plus this --settings
# file is fenced for family 6 from the moment it ships. It is a tripwire, not a
# sandbox: the turn still runs as root with the full tool set.
#
# ARMING NEVER REFUSES A TURN. Every failure here is "print nothing, say so in
# ALERTS, exit 0" — the caller runs its turn unfenced rather than not at all. A
# guard that fails closed takes the orchestrator down with it.
set -uo pipefail

LANE="${1:-unknown}"
HARNESS="${HARNESS:-/root/harness}"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

# EVERY PATH THIS SCRIPT PRINTS OR WRITES IS ABSOLUTE, and that is not tidiness.
# The hook command goes into a settings file the CLI reads from whatever working
# directory the session has — bin/box-chat.sh runs its turn from $SESS, several
# directories away — so a relative command is a hook that resolves to nothing and
# a lane that believes it is fenced. Invoked as `bash bin/iron-law-arm.sh` from a
# checkout, $(dirname "$0") is the relative `bin`, which is exactly how that
# happens.
abspath() { # abspath <path> -> <path> with its directory resolved; fails if it has none
  local d b
  d=$(dirname "$1"); b=$(basename "$1")
  d=$(cd "$d" 2>/dev/null && pwd) || return 1
  printf '%s/%s\n' "$d" "$b"
}
_h=$(cd "$HARNESS" 2>/dev/null && pwd) && HARNESS="$_h"

# Sibling first so a checkout drives its own copy, then the deployed one — the
# same resolution order every launcher uses for claude-cost.sh.
GUARD="$HARNESS/bin/iron-law-guard.sh"
_sib=$(abspath "$(dirname "$0")/iron-law-guard.sh" 2>/dev/null) || _sib=""
[ -n "$_sib" ] && [ -x "$_sib" ] && GUARD="$_sib"

# Unarmed is a REPORTED state, never a silent one — and never a settings path
# pointing at something that was not written. Only when the harness log tree
# already exists: on a Mac running greenfield there is none, and inventing one is
# not this script's business.
unarmed() {
  [ -d "$HARNESS/logs" ] || exit 0
  echo "$(STAMP) [$LANE] act-time iron-law guard MISSING: $1 — this $LANE session is running UNFENCED (the destructive-filesystem family is prompt-only here). Deploy the harness: bin/harness-sync.sh." \
    >> "$HARNESS/logs/ALERTS.log" 2>/dev/null
  exit 0
}

[ -x "$GUARD" ] || unarmed "no guard script at $GUARD"
command -v jq >/dev/null 2>&1 || unarmed "jq is not on PATH, so the hook settings cannot be written"

# The SHARED name only when the guard is the deployed one, because that is the
# file bin/agent-call.sh writes with the same command inside it. A checkout
# driving its own guard gets its own file keyed on that guard's path, so it can
# never overwrite the shared one with a command pointing somewhere else.
NAME="iron-law-guard-settings-$(printf %s "$GUARD" | cksum | cut -d' ' -f1).json"
[ "$GUARD" = "$HARNESS/bin/iron-law-guard.sh" ] && NAME="iron-law-guard-settings.json"

DEST="$HARNESS/state/$NAME"
# TMPDIR is the fallback for a machine whose harness state dir is not usable —
# greenfield runs from a checkout on the operator's Mac. Always the keyed name there,
# since /tmp is shared by everything on the box.
if ! mkdir -p "$HARNESS/state" 2>/dev/null || [ ! -w "$HARNESS/state" ]; then
  DEST="${TMPDIR:-/tmp}/iron-law-guard-settings-$(printf %s "$GUARD" | cksum | cut -d' ' -f1).json"
fi

# 30s, not 10, for the same reason agent-call.sh uses 30: a hook the CLI KILLS on
# its timeout runs the command UNGUARDED.
jq -n --arg c "$GUARD" \
  '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:$c,timeout:30}]}]}}' \
  > "$DEST.tmp.$$" 2>/dev/null \
  && mv -f "$DEST.tmp.$$" "$DEST" 2>/dev/null \
  || { rm -f "$DEST.tmp.$$" 2>/dev/null; unarmed "could not write the hook settings to $DEST"; }

echo "$DEST"
exit 0
