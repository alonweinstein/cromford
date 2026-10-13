#!/bin/bash
# tests/ticket-detail-console.bh-4991-test.sh — the Mission Control ticket page
# (BH-4991, wave 2 of BH-4947).
#
# The behaviour is proved by node --test in console-ui/tests/*.bh-4991.test.js.
# This file is the part the impact lane and the orphan ratchet can SEE: it
# names the new sources by path, drives the pure derivations with plain node
# (no dependencies needed), and runs the node suites when the console-ui
# dependencies are installed.
#
#   1. the new sources and suites exist.
#   2. console-ui/src/lib/ticket-detail.js, DRIVEN: the cost total is the sum of
#      the stage rows, a station targets its first event, a transcript parses
#      into turns in order, and the live marker needs an open phase.
#   3. the node suites (ticket-detail, agent-session, ticket-links), run for
#      real when node_modules is present; they cover
#      console-ui/src/ui/AgentSession.js and console-ui/src/ui/TicketKey.js.
# Run from anywhere: tests/ticket-detail-console.bh-4991-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

DETAIL_LIB="$DIR/console-ui/src/lib/ticket-detail.js"
SESSION_UI="$DIR/console-ui/src/ui/AgentSession.js"
KEY_UI="$DIR/console-ui/src/ui/TicketKey.js"
TICKET="$DIR/console-ui/src/screens/Ticket.js"
SUITES="tests/ticket-detail.bh-4991.test.js tests/agent-session.bh-4991.test.js tests/ticket-links.bh-4991.test.js"

# --- 1: the sources and suites exist ------------------------------------------
for f in "$DETAIL_LIB" "$SESSION_UI" "$KEY_UI" "$TICKET"; do
  [ -s "$f" ] && ok || bad "missing $f"
done
for t in $SUITES; do [ -s "$DIR/console-ui/$t" ] && ok || bad "missing console-ui/$t"; done

command -v node >/dev/null 2>&1 || { echo "ticket-detail-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 2: the pure derivations, driven --------------------------------------------
OUT=$(node --input-type=module -e "
import { stageCosts, eventTimeline, firstEventOf, parseTranscript, sessionLive } from '$DETAIL_LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const c = stageCosts([
  { id: 1, phase: 'plan', model: 'm', spend_usd: 3.1 },
  { id: 2, phase: 'execute', model: 'm', spend_usd: 6.4 },
  { id: 3, phase: 'review', model: 'm', spend_usd: null }
]);
eq('C1 total is the sum of the rows', c.total, c.rows.reduce((n, r) => n + (r.cost ?? 0), 0));
eq('C2 a stage with no spend is null, not zero', c.rows[2].cost, null);
const tl = eventTimeline([
  { id: 11, stage: 'plan', detail: 'p' }, { id: 12, stage: 'execute', detail: 'a' }, { id: 13, stage: 'execute', detail: 'b' }
]);
eq('S1 a station targets its first event', firstEventOf(tl, 2), 12);
eq('S2 a station with no event targets nothing', firstEventOf(tl, 6), null);
const turns = parseTranscript('# header\n[20:01:02] USER\nGo.\n\n[20:01:10] ASSISTANT (m)\nReading.\n  → Bash: ls\n  ← a b');
eq('T1 the turns, in order', turns.map((t) => t.who), ['human', 'agent', 'tool', 'result']);
eq('L1 live while a phase is open', sessionLive({ status: 'running' }, [{ finished_at: null }]), true);
eq('L2 idle when no phase is open', sessionLive({ status: 'running' }, [{ finished_at: 'x' }]), false);
" 2>&1)
while IFS= read -r l; do
  case "$l" in "ok "*) ok ;; "no "*) bad "${l#no }" ;; *) [ -n "$l" ] && bad "node: $l" ;; esac
done <<<"$OUT"

# --- 3: the node suites, when the dependencies are installed ---------------------
if [ ! -d "$DIR/console-ui/node_modules/preact" ] || [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "ticket-detail-console: node suites SKIPPED — console-ui/node_modules is not installed (CI's console-ui job runs them)"
else
  for t in $SUITES; do
    if NOUT=$(cd "$DIR/console-ui" && node --test "$t" 2>&1); then ok
    else bad "node --test $t failed: $(grep -E '^(not ok|✖)' <<<"$NOUT" | head -5)"; fi
  done
fi

echo "ticket-detail-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
