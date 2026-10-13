#!/bin/bash
# tests/chat-usage-capture-test.sh — claude-usage.sh and the box-chat cost row.
#
# THE GAP. box-chat.sh rung 1 called the claude CLI directly, so agent-call.sh
# never saw it and no cost row was ever written. Every per-box chat turn was
# spend nobody could see — the same class the orchestrator was in before it was
# instrumented, and the class $18,863 hid in: not a lane reporting wrong
# numbers, a lane reporting nothing at all.
#
# Sections 1-5 are bin/claude-usage.sh, which bin/orchestrate.sh still reads for
# its per-turn budget check. Section 6 is the box-chat row, and it moved on
# 2026-09-14: rung 1 now runs through bin/claude-cost.sh instead of hand-rolling
# a row here. See the note there.
#
# THE ONE THING THAT MUST NOT BE COPIED FROM codex-usage.sh: codex writes a
# CUMULATIVE total per session, so max() is right there. Claude writes PER-TURN
# usage on every assistant message, so the answer here is a SUM. Taking the max
# would report one turn and undercount a long chat by however many turns it
# ran — silently, in the direction that always looks fine.
#
# The fixture shape is COPIED FROM A REAL Claude Code session file (.message.usage
# on type=assistant, with input_tokens / output_tokens /
# cache_creation_input_tokens / cache_read_input_tokens), not invented from
# memory of the schema. Hand-written fixtures in a format the producer never
# emits is what let the tz crash through nineteen green assertions.
# Run from anywhere: tests/chat-usage-capture-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
CU="$DIR/bin/claude-usage.sh"
BC="$DIR/bin/box-chat.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/sessions/proj"
NOWTS=$(python3 -c "
import datetime
print(datetime.datetime.now(datetime.timezone.utc).isoformat())")
T0=$(python3 -c "import time; print(int(time.time()) - 60)")

turn() {  # <in> <out> <cache_read> <cache_write> <timestamp>
  printf '{"type":"assistant","timestamp":"%s","message":{"usage":{"input_tokens":%s,"output_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s}}}\n' \
    "$5" "$1" "$2" "$3" "$4"
}

# --- 1. IT SUMS TURNS, it does not take the largest ---------------------------
# Three turns. max(output) is 500; the sum is 800. A max-based reader returns
# 500 and looks entirely plausible.
{ turn 10 100 1000 50 "$NOWTS"
  turn 20 500 2000 60 "$NOWTS"
  turn 30 200 3000 70 "$NOWTS"; } > "$T/sessions/proj/s.jsonl"
OUT=$(bash "$CU" "$T0" "$T/sessions")
[ "$OUT" = "60|800|6000|180" ] \
  && ok || bad "must SUM per-turn usage across the call (got: '$OUT', expected 60|800|6000|180)"
[ "${OUT#*|}" != "500|6000|180" ] \
  && ok || bad "it took the max output instead of the sum — that is the codex semantics, wrong here"

# --- 2. a CONTINUED session must contribute only this call's turns -----------
# `claude -c` appends to an existing session file, so the file holds the whole
# conversation. Summing all of it would bill this turn for the entire history —
# and unlike an undercount, that error grows with every question asked.
OLDTS=$(python3 -c "
import datetime
print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=3)).isoformat())")
{ turn 9999 9999 9999 9999 "$OLDTS"
  turn 9999 9999 9999 9999 "$OLDTS"
  turn 10 100 1000 50 "$NOWTS"; } > "$T/sessions/proj/s.jsonl"
OUT=$(bash "$CU" "$T0" "$T/sessions")
[ "$OUT" = "10|100|1000|50" ] \
  && ok || bad "a continued session must contribute only turns at/after T0 (got: '$OUT')"

# --- 2b. THE SCOPE IS THE ANSWER: a concurrent session must not answer for us -
# THE BUG THIS EXISTS FOR, measured on the hub 2026-08-25. The reader walked
# ALL of ~/.claude/projects, sorted by mtime, and stopped at the FIRST file
# holding any usage — so on a box running several claude processes it answered
# with whichever session was written last. An orchestrator turn that really
# consumed 1,087,133 cache_read and 14,098 output reported `4|28|70548|0`: the
# tokens of an unrelated `-tmp` session, ~15x low, and as easily 15x high.
#
# Everything in tests/turn-budget-test.sh was green throughout, because every
# assertion there STUBS this script. The detector's logic was tested; its input
# never was — so the numbers were fiction and the tests agreed with them.
#
# The fixture is the real shape: the caller's own tree holding a MULTI-CALL
# turn, and a competing tree, written LATER, holding one small call.
mkdir -p "$T/projects/-root-orchestrator" "$T/projects/-tmp"
: > "$T/projects/-root-orchestrator/session.jsonl"
: > "$T/projects/-root-orchestrator/session-rotated.jsonl"
# SPLIT ACROSS TWO FILES ON PURPOSE. With the turn in a single file, "sum every
# file in scope" and "stop at the first file that parses" return the same
# answer, so the fixture cannot tell a fixed reader from the broken one — the
# same non-discriminating-fixture trap that has cost this wave a re-do at least
# eight times. A caller's scope legitimately holds more than one file (a
# rotated or resumed session), and the totals below are identical either way.
i=0; while [ "$i" -lt 18 ]; do
  if [ "$i" -lt 12 ]; then F=session.jsonl; else F=session-rotated.jsonl; fi
  turn 2 783 60396 8946 "$NOWTS" >> "$T/projects/-root-orchestrator/$F"
  i=$((i+1))
done
turn 4 28 70548 0 "$NOWTS" > "$T/projects/-tmp/other.jsonl"   # newer, and not ours
touch "$T/projects/-tmp/other.jsonl"
SCOPED=$(bash "$CU" "$T0" "$T/projects/-root-orchestrator")
[ "$SCOPED" = "36|14094|1087128|161028" ] \
  && ok || bad "a scoped read must sum the caller's whole turn, not one call of it (got: '$SCOPED')"
[ "$SCOPED" != "4|28|70548|0" ] \
  && ok || bad "the reader answered with the concurrent session — the exact hub failure"
# --cwd= is the call-site form: the directory the caller ran in, converted by
# Claude Code's own rule (every "/" becomes "-"), so a call site reads as a path
# instead of a slug nobody can check by eye.
CWD_OUT=$(HOME="$T/home" bash -c 'mkdir -p "$1/.claude/projects"; cp -r "$2" "$1/.claude/projects/-root-orchestrator"; bash "$3" "$4" --cwd=/root/orchestrator' _ "$T/home" "$T/projects/-root-orchestrator" "$CU" "$T0")
[ "$CWD_OUT" = "36|14094|1087128|161028" ] \
  && ok || bad "--cwd= does not resolve to the session dir Claude Code writes (got: '$CWD_OUT')"

# --- 2c. THE FILE CAP DECLARES ITSELF ----------------------------------------
# The reader sums at most CLAUDE_USAGE_MAX_FILES files in a scope. A scope with
# more (a long-lived or often-rotated session) would otherwise sum a prefix and
# print a total that LOOKS complete — a cheap-looking turn, which is exactly the
# failure that made this read wrong to begin with, just at a bigger number. So
# the cap announces itself: partial totals still go out for bookkeeping, and
# exit 3 tells a caller that cannot afford a partial. turn_cost_usd treats a
# failed read as "unchecked" rather than "under budget", so a truncated turn
# lands on the honest path instead of being priced low.
mkdir -p "$T/capped" "$T/logs" "$T/flags"
for f in a b c; do turn 1 10 100 5 "$NOWTS" > "$T/capped/$f.jsonl"; done
CAPOUT=$(HARNESS="$T" CLAUDE_USAGE_MAX_FILES=2 bash "$CU" "$T0" "$T/capped" 2>"$T/cap.err")
CAPRC=$?
[ "$CAPRC" = 3 ] \
  && ok || bad "a truncated read must exit nonzero so a safety-critical caller can refuse it (rc=$CAPRC)"
grep -q 'TURN UNDERCOUNTED' "$T/cap.err" \
  && ok || bad "the cap engaged silently — a truncation that reads as a complete total"
grep -q '1 file(s) beyond the 2-file cap' "$T/cap.err" \
  && ok || bad "the declaration must say HOW MANY files were dropped, not just that some were"
[ "$CAPOUT" = "2|20|200|10" ] \
  && ok || bad "the partial total must still be emitted for bookkeeping callers (got: '$CAPOUT')"
grep -q 'TURN UNDERCOUNTED' "$T/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "callers redirect stderr to /dev/null by design, so the declaration must also reach ALERTS.log"
# Under the cap, nothing is announced — a valve that always trips is not a valve.
rm -f "$T/logs/ALERTS.log"
QOUT=$(HARNESS="$T" CLAUDE_USAGE_MAX_FILES=5 bash "$CU" "$T0" "$T/capped" 2>"$T/quiet.err")
QRC=$?
[ "$QRC" = 0 ] && [ ! -s "$T/quiet.err" ] && [ ! -s "$T/logs/ALERTS.log" ] \
  && ok || bad "an untruncated read must stay silent (rc=$QRC)"
[ "$QOUT" = "3|30|300|15" ] \
  && ok || bad "under the cap every file in scope must be summed (got: '$QOUT')"

# --- 3. fail-soft: every miss is empty, never a zero -------------------------
# A zero is a claim that the call was free. Empty is a claim that we do not
# know. Those are different and must not print the same.
rm -f "$T/sessions/proj/s.jsonl"
OUT=$(bash "$CU" "$T0" "$T/sessions")
[ "$OUT" = "|||" ] && ok || bad "no session must yield empty fields, not zeros (got: '$OUT')"
OUT=$(bash "$CU" "$T0" "$T/nonexistent-dir")
[ "$OUT" = "|||" ] && ok || bad "a missing session dir must fail soft (got: '$OUT')"
printf 'not json at all\n{"broken":\n' > "$T/sessions/proj/s.jsonl"
OUT=$(bash "$CU" "$T0" "$T/sessions")
[ "$OUT" = "|||" ] && ok || bad "unparseable lines must fail soft, not crash (got: '$OUT')"

# --- 4. an OLD session file is not borrowed ----------------------------------
# Same guard codex-usage.sh carries: a session older than the call belongs to a
# different call, and borrowing its tokens INVENTS spend.
turn 500 500 500 500 "$NOWTS" > "$T/sessions/proj/s.jsonl"
touch -t 202001010000 "$T/sessions/proj/s.jsonl"
OUT=$(bash "$CU" "$(date +%s)" "$T/sessions")
[ "$OUT" = "|||" ] \
  && ok || bad "a session predating the call must not be attributed to it (got: '$OUT')"

# --- 5. the output is consumable by the caller's split -----------------------
turn 1 2 3 4 "$NOWTS" > "$T/sessions/proj/s.jsonl"
IFS='|' read -r I O CR CW <<<"$(bash "$CU" "$T0" "$T/sessions")"
[ "$I" = 1 ] && [ "$O" = 2 ] && [ "$CR" = 3 ] && [ "$CW" = 4 ] \
  && ok || bad "the four fields must bind (got '$I' '$O' '$CR' '$CW')"

# --- 6. box-chat rung 1 is BILLED ------------------------------------------
# The capture existing is not the same as the row landing; that gap is the
# entire bug this file was written for. What CHANGED on 2026-09-14 is who
# writes the row, not whether one is written: box-chat used to hand-roll its own
# cost.csv line here (tokens from claude-usage.sh, cost_usd left EMPTY because
# that reader does not price, and a private copy of agent-call's lock to append
# it with). It now runs rung 1 through bin/claude-cost.sh, which writes the row
# through the SAME cost_append every other lane uses, priced from the turn's own
# transcript. So the assertions below moved from "box-chat writes a row that
# looks like this" to "box-chat calls the thing that writes the row, and that
# thing still writes it" — the property is the same, the second copy is gone.
grep -q 'claude-cost.sh' "$BC" \
  && ok || bad "box-chat.sh no longer routes rung 1 through claude-cost.sh — rung 1 is untracked again"
grep -qE 'COST_STAGE=chat' "$BC" \
  && ok || bad "the chat row must be tagged stage=chat, or the ledger cannot tell a chat turn from a build"
grep -qE 'COST_PROJECT=' "$BC" \
  && ok || bad "the chat row must carry the project it answered for"
# The bare CLI stays reachable when the wrapper is not on the box: instrumentation
# must never be the reason a chat pane goes quiet.
grep -q 'command -v claude' "$BC" \
  && ok || bad "box-chat must still answer when claude-cost.sh is missing (mid-sync box)"
# ...and the row-writing side really does write one.
grep -q 'cost_append' "$DIR/bin/claude-cost.sh" \
  && ok || bad "bin/claude-cost.sh does not append a cost row — rung 1 would be silent"
grep -q 'billing-mode.sh' "$DIR/bin/claude-cost.sh" \
  && ok || bad "the chat row does not resolve billing_mode — it would land unclassifiable"
# The append still goes through the SAME lock agent-call.sh uses, now via the
# shared writer, or a chat turn landing mid-build interleaves two half lines.
grep -q 'cost-header.lock' "$DIR/bin/lib/cost-row.sh" \
  && ok || bad "the shared row writer no longer takes the cost lock"
# The reply path must not depend on any of it.
grep -q 'cost_append "$ROW" 2>/dev/null || true' "$DIR/bin/claude-cost.sh" \
  && ok || bad "the row write is not fail-soft — instrumentation must never break the chat it measures"
# ...and the transcript it prices must be SCOPED to the directory this turn ran
# in. Unscoped, the discovery path answers with whichever session on the box was
# written last: another project's chat, or a pipeline stage's, filed here.
grep -q 'projects/$(printf .%s. "$CC_CWD"' "$DIR/bin/claude-cost.sh" \
  && ok || bad "claude-cost.sh discovers the transcript unscoped — the row can carry another session's tokens"

echo "chat-usage-capture-test: $PASS pass, $FAIL fail"
echo "NOTE: fixture shape copied from a REAL Claude Code session file (2026-08-24)."
[ "$FAIL" -eq 0 ]
