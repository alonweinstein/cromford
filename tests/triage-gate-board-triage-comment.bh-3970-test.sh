#!/bin/bash
# tests/triage-gate-board-triage-comment.bh-3970-test.sh — BH-3970 item 2: the
# board's own `[AI Triage]` verdict never starves a ready ticket.
#
# An in-app board OS writes an ACK and then an `[AI Triage] … ready` comment on
# each new ticket, as its internal-token system actor. That actor is the same
# one the harness writes with, so `bin/triage-gate.sh --buildable` read the
# board's verdict as our own write and answered `BLOCKED newest-comment-system`.
# The shards client-court guard dropped every decompose child on that answer,
# the gate fingerprint was consumed, and nothing re-offered them
# (project-8 TK-25..TK-56, 2026-10-03).
#
# The exemption is narrow ON PURPOSE. It applies only when the newest comment's
# first non-blank line starts with `[AI Triage]` AND triageVerdict=ready AND
# waitingOn=team. A harness close-out by the same actor must still block: that
# is the self-write guard (tests/client-court-gate-test.sh TK-220/TK-222).
#
# Drives the REAL bin/triage-gate.sh CLI and the real bin/board-fetch.sh against
# a scratch $HARNESS with a stubbed curl, and the REAL shards client-court guard
# block, extracted by its markers. Whole-stdout compares. No network, no clock.
#
# Run from anywhere: tests/triage-gate-board-triage-comment.bh-3970-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1

DIR=$(cd "$(dirname "$0")/.." && pwd)
GATE_SRC="${TRIAGE_GATE_UNDER_TEST:-$DIR/bin/triage-gate.sh}"
SHARDS_SRC="$DIR/bin/lib/rt/shards.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null 2>&1 || { echo "triage-gate-board-triage-comment: jq missing, cannot run" >&2; exit 1; }

mkdir -p "$T/bin/lib" "$T/env" "$T/state" "$T/logs" "$T/flags" "$T/fixture"
cp "$GATE_SRC" "$T/bin/triage-gate.sh"
cp "$DIR/bin/lib/board-creds.sh" "$DIR/bin/lib/internal-token.sh" "$T/bin/lib/"
cp "$DIR/bin/board-fetch.sh" "$T/bin/board-fetch.sh"
chmod +x "$T/bin/triage-gate.sh" "$T/bin/board-fetch.sh"

cat > "$T/bin/fleet-conf.sh" <<'EOC'
#!/bin/bash
case "${1:-}" in
  x-os) case "${2:-}" in repo) echo "" ;; board_prefix|*) echo "/api/board" ;; esac ;;
  *) echo "" ;;
esac
EOC
chmod +x "$T/bin/fleet-conf.sh"

cat > "$T/env/x-os.env" <<'EOC'
XOS_API_BASE=https://board.example
XOS_INTERNAL_API_TOKEN=tok
EOC

# curl stand-in honouring -o and -w (board-fetch.sh reads both).
cat > "$T/bin/curl" <<EOC
#!/bin/bash
OUT=""; FMT=""; URL=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) shift; OUT="\${1:-}" ;;
    -w) shift; FMT="\${1:-}" ;;
    -H|-m) shift; : ;;
    -*) : ;;
    *) URL="\$1" ;;
  esac
  shift || true
done
BODY="no route for \$URL"; HTTP="404"
case "\$URL" in
  */tickets/*)
    F="$T/fixture/ticket-\${URL##*/tickets/}.json"
    if [ -f "\$F" ]; then HTTP="200"; BODY=\$(cat "\$F"); fi ;;
esac
if [ -n "\$OUT" ]; then printf '%s' "\$BODY" > "\$OUT"; else printf '%s' "\$BODY"; fi
printf '%s' "\$FMT" | sed "s/%{http_code}/\$HTTP/g"
EOC
chmod +x "$T/bin/curl"

export HARNESS="$T"
export PATH="$T/bin:$PATH"

TRIAGE_NOTE='[AI Triage] Looks ready to build. Scope is clear and the acceptance criteria are concrete.'
CLOSEOUT='We shipped this in PR #812. It is on the review screen now.'

# ticket <id> <verdict|-> <waitingOn|-> <comments-json-array>
ticket() {
  jq -nc --argjson id "$1" --arg v "$2" --arg w "$3" --argjson c "$4" '
    {id:$id, key:("TK-"+($id|tostring)), status:"todo", title:"child", comments:$c}
    | if $v == "-" then . else .triageVerdict = $v end
    | if $w == "-" then . else .waitingOn = $w end' > "$T/fixture/ticket-$1.json" \
    || bad "fixture $1"
}
# cmt <field> <text> <createdAt> <isInternal|-> [author-name]
cmt() {
  jq -nc --arg f "$1" --arg b "$2" --arg at "$3" --arg in "$4" --arg n "${5:-System}" '
    {createdAt:$at, author:{name:$n, userId:"sys-1"}} + {($f):$b}
    | if $in == "-" then . else .isInternal = ($in == "true") end'
}
ack=$(cmt body "Thanks, we got this ticket." 2026-10-03T15:39:00Z true)

check() { # check <label> <mode> <id> <expected>
  local out rc
  out=$(bash "$T/bin/triage-gate.sh" x-os "$2" "$3" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || { bad "$1: exit $rc"; return; }
  [ "$out" = "$4" ] || { bad "$1: got [$out], want [$4]"; return; }
  ok
}

# B1: the board's own verdict, system actor + isInternal, ready/team -> OK.
ticket 301 ready team "[$ack,$(cmt body "$TRIAGE_NOTE" 2026-10-03T15:40:00Z true)]"
check "B1 [AI Triage] internal ready/team" --buildable 301 "OK"

# B2: author-name match only (no isInternal field).
ticket 302 ready team "[$ack,$(cmt body "$TRIAGE_NOTE" 2026-10-03T15:40:00Z -)]"
check "B2 [AI Triage] by name only" --buildable 302 "OK"

# B3: a harness close-out by the same actor still blocks (self-write guard).
ticket 303 ready team "[$ack,$(cmt body "$CLOSEOUT" 2026-10-03T15:40:00Z true)]"
check "B3 harness close-out still blocked" --buildable 303 "BLOCKED newest-comment-system"
ticket 313 ready team "[$ack,$(cmt body "$CLOSEOUT" 2026-10-03T15:40:00Z -)]"
check "B3b harness close-out by name still blocked" --buildable 313 "BLOCKED newest-comment-system"

# B4/B5: the earlier checks still win.
ticket 304 needs_clarification team "[$(cmt body "$TRIAGE_NOTE" 2026-10-03T15:40:00Z true)]"
check "B4 verdict needs_clarification" --buildable 304 "BLOCKED triageVerdict=needs_clarification"
ticket 305 ready client "[$(cmt body "$TRIAGE_NOTE" 2026-10-03T15:40:00Z true)]"
check "B5 waitingOn=client" --buildable 305 "BLOCKED waitingOn=client"

# B6: waitingOn absent is not team -> the exemption does not apply.
ticket 306 ready - "[$(cmt body "$TRIAGE_NOTE" 2026-10-03T15:40:00Z true)]"
check "B6 waitingOn absent" --buildable 306 "BLOCKED newest-comment-system"

# B7: [AI Triage] only mid-body.
ticket 307 ready team "[$(cmt body "Note from the team.
[AI Triage] Looks ready." 2026-10-03T15:40:00Z true)]"
check "B7 [AI Triage] mid-body" --buildable 307 "BLOCKED newest-comment-system"

# B8: leading blank line and indentation, then [AI Triage].
ticket 308 ready team "[$(cmt body "

   $TRIAGE_NOTE" 2026-10-03T15:40:00Z true)]"
check "B8 leading blank line" --buildable 308 "OK"

# B9: the body is served under `content`.
ticket 309 ready team "[$ack,$(cmt content "$TRIAGE_NOTE" 2026-10-03T15:40:00Z true)]"
check "B9 body under content" --buildable 309 "OK"

# B10: an older [AI Triage] and a newer harness note -> the newest decides.
ticket 310 ready team "[$(cmt body "$CLOSEOUT" 2026-10-03T16:10:00Z true),$(cmt body "$TRIAGE_NOTE" 2026-10-03T15:40:00Z true)]"
check "B10 newer harness note wins" --buildable 310 "BLOCKED newest-comment-system"

# B11: the launch-side strict mode answers the same on B1.
check "B11 strict on B1" --buildable-strict 301 "OK"

# B12: the REAL shards client-court guard over two board units.
GUARD=$(sed -n '/^  # >>> client-court guard$/,/^  # <<< client-court guard$/p' "$SHARDS_SRC")
if [ "$(printf '%s\n' "$GUARD" | wc -l)" -lt 10 ]; then
  bad "B12: could not extract the client-court guard block from $SHARDS_SRC"
else
  SHARD_UNITS="$T/units.tsv"; PROJECT=x-os; STAMP="2026-10-03T15:51:00Z"; LOG="$T/logs/x-os.log"; SHARD_ON=1
  printf '301\tboard\tPB-301 child\n303\tboard\tPB-303 child\n' > "$SHARD_UNITS"
  eval "$GUARD"
  kept=$(cut -f1 "$SHARD_UNITS" | tr '\n' ' ')
  [ "$kept" = "301 " ] && ok || bad "B12: kept units [$kept], want [301 ]"
  if grep -qF " 303 (BLOCKED newest-comment-system)" "$LOG" 2>/dev/null; then ok
  else bad "B12: close-out unit not listed as skipped: $(cat "$LOG" 2>/dev/null)"; fi
  if grep -q "client-court skipped.* 301 " "$LOG" 2>/dev/null; then bad "B12: [AI Triage] unit was skipped"; else ok; fi
  [ "$SHARD_ON" = 1 ] && ok || bad "B12: SHARD_ON dropped to $SHARD_ON"
fi

echo "triage-gate-board-triage-comment.bh-3970: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
