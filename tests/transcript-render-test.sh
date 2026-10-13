#!/bin/bash
# tests/transcript-render-test.sh — bin/transcript-render.sh, driven with
# session-jsonl fixtures.
#
# WHAT IS ACTUALLY UNDER TEST: the contract that the console NEVER parses raw
# jsonl. The box renders once and the ledger stores prose, which means this
# script is the only thing standing between a CLI format we do not own and a
# transcript pane on the far side of an ocean. So the fixtures are shaped like
# the real file (worker/jobs — a session's record types are user / assistant /
# system plus a pile of CLI bookkeeping) and the assertions are about what
# SURVIVES the render and what does not.
#
# The fixtures are hand-written rather than copied from a live session on
# purpose: a session file on this box would carry that session's real paths and
# possibly its real secrets, and committing one to a public-ish repo to test the
# scrubber's neighbour would be a poor joke.
# Run from anywhere: tests/transcript-render-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "transcript-render-test: SKIPPED — jq is not installed on this box"; exit 0; }

F="$T/session.jsonl"
cat > "$F" <<'EOF'
{"type":"queue-operation","operation":"enqueue","timestamp":"2026-08-29T10:00:00.000Z","content":"internal bookkeeping nobody should read"}
{"type":"user","timestamp":"2026-08-29T10:00:01.000Z","message":{"role":"user","content":"Execute the plan for TK-1 and do not merge."}}
{"type":"assistant","timestamp":"2026-08-29T10:00:02.000Z","message":{"role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"Reading the plan first."}]}}
{"type":"assistant","timestamp":"2026-08-29T10:00:03.000Z","message":{"role":"assistant","model":"claude-opus-5","content":[{"type":"thinking","thinking":"twelve chars","signature":"sig"}]}}
{"type":"assistant","timestamp":"2026-08-29T10:00:04.000Z","message":{"role":"assistant","model":"claude-opus-5","content":[{"type":"tool_use","name":"Bash","input":{"command":"npm run build","description":"build it"}}]}}
{"type":"user","timestamp":"2026-08-29T10:00:05.000Z","message":{"role":"user","content":[{"type":"tool_result","content":"built in 2.1s\nno errors"}]}}
{"type":"assistant","timestamp":"2026-08-29T10:00:06.000Z","message":{"role":"assistant","model":"claude-opus-5","content":[{"type":"tool_use","name":"Read","input":{"file_path":"/root/repos/x/src/a.ts"}}]}}
{"type":"user","timestamp":"2026-08-29T10:00:07.000Z","message":{"role":"user","content":[{"type":"tool_result","is_error":true,"content":[{"type":"text","text":"ENOENT: no such file"}]}]}}
{"type":"ai-title","timestamp":"2026-08-29T10:00:08.000Z","title":"more bookkeeping"}
{"type":"assistant","timestamp":"2026-08-29T10:00:09.000Z","message":{"role":"assistant","model":"claude-opus-5","content":[{"type":"tool_use","name":"MysteryTool","input":{"weird":"argument","other":1}}]}}
{"type":"system","timestamp":"2026-08-29T10:00:10.000Z","subtype":"compact_boundary"}
{"type":"assistant","timestamp":"2026-08-29T10:00:11.000Z","message":{"role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"Done. Build is green."}]}}
this line is not json at all
EOF

OUT=$(bash "$DIR/bin/transcript-render.sh" "$F" 2>"$T/err")

has()  { case "$OUT" in *"$1"*) ok ;; *) bad "$2"$'\n'"--- got ---"$'\n'"$OUT" ;; esac; }
lacks(){ case "$OUT" in *"$1"*) bad "$2"$'\n'"--- got ---"$'\n'"$OUT" ;; *) ok ;; esac; }

# --- 1. the conversation survives -------------------------------------------
has 'Execute the plan for TK-1' "the user turn was dropped"
has 'Done. Build is green.' "the assistant's final text was dropped"
has '[10:00:01] USER' "a turn has no timestamp/role header"
has '[10:00:02] ASSISTANT (claude-opus-5)' "an assistant turn does not name its model"

# --- 2. tool calls are one line each, with their most telling argument -------
# Not the whole input object: a build session runs hundreds of these and
# rendering their full JSON buries the reasoning under its own scaffolding.
has '→ Bash: npm run build' "a Bash tool call did not render as its command"
has '→ Read: /root/repos/x/src/a.ts' "a Read tool call did not render as its path"
lacks '"description":"build it"' "the whole tool input was dumped instead of one telling argument"
# An unknown tool still renders SOMETHING — a future tool name must not make a
# turn silently vanish.
has '→ MysteryTool:' "an unrecognised tool rendered nothing at all"

# --- 3. tool results are summarised, and errors are marked ------------------
has '← built in 2.1s' "a tool result was dropped"
has '⏎' "a multi-line tool result was not folded onto one line"
has '← ERROR: ENOENT' "a FAILED tool result was not marked as an error"

# --- 4. what must NOT survive -----------------------------------------------
lacks 'internal bookkeeping nobody should read' "a queue-operation record leaked into the transcript"
lacks 'more bookkeeping' "an ai-title record leaked into the transcript"
# Thinking is a length marker, never text: it is the model's scratch space, it
# is enormous, and it is not what a reader clicking a job came for.
has '[thinking, 12 chars]' "a thinking block did not render as a length marker"
lacks 'twelve chars' "thinking TEXT leaked into the transcript"

# --- 5. a malformed line is dropped and COUNTED, never fatal ----------------
# A session file is appended to while the CLI runs and can end mid-write. The
# render must survive that, and the loss must be visible rather than silent.
grep -q '12 of 13 lines parsed' "$T/err" \
  && ok || bad "the unparseable line was not reported on stderr: $(cat "$T/err")"
has 'Done. Build is green.' "one bad line threw away the rest of the session"

# --- 6. an empty or absent file ---------------------------------------------
: > "$T/empty.jsonl"
E=$(bash "$DIR/bin/transcript-render.sh" "$T/empty.jsonl" 2>/dev/null); RC=$?
[ "$RC" = 0 ] && [ -z "$E" ] && ok || bad "an empty session rendered '$E' at rc=$RC instead of nothing at rc=0"
bash "$DIR/bin/transcript-render.sh" "$T/does-not-exist.jsonl" >/dev/null 2>&1
[ $? -ne 0 ] && ok || bad "an absent session file exited 0, which would push an empty transcript as though it were real"

# --- 7. ordering ------------------------------------------------------------
# A transcript that shuffles turns is worse than no transcript: it invents a
# conversation nobody had.
FIRST=$(printf '%s\n' "$OUT" | grep -n 'Execute the plan' | head -1 | cut -d: -f1)
LAST=$(printf '%s\n' "$OUT" | grep -n 'Build is green' | head -1 | cut -d: -f1)
[ -n "$FIRST" ] && [ -n "$LAST" ] && [ "$FIRST" -lt "$LAST" ] \
  && ok || bad "turns came out of order (first=$FIRST last=$LAST)"

echo "transcript-render-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
