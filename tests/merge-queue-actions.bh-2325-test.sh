#!/bin/bash
# tests/merge-queue-actions.bh-2325-test.sh — the merge-queue HOLD / RESUME /
# DROP actions and the held-page RELEASE button (BH-3159, BH-2325.4).
#
# WHY A SHELL SUITE AS WELL. The cells are proved by node --test in
# console-ui/tests/merge-queue-actions.bh-2325.test.js (reached through the
# console-ui job). This file names the two sources by path for the impact lane
# and the orphan ratchet (D41), drives the pure half for real, and holds the
# screen to the no-native-dialog rule (the cost-breaker-console.bh-2331 pattern).
#
#   1. lib/merge-queue-actions.js, DRIVEN: the offered actions per status, the
#      null bodies on a blank reason, and the load-bearing clause of each
#      per-mode effect sentence.
#   2. screens/merge-queue-actions.js confirms through the in-app useConfirm
#      modal and never calls a native dialog.
#   3. the node suite, run for real when the console-ui dependencies are installed.
# Run from anywhere: tests/merge-queue-actions.bh-2325-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/merge-queue-actions.js"
SCREEN="$DIR/console-ui/src/screens/merge-queue-actions.js"

for f in "$LIB" "$SCREEN"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "merge-queue-actions: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { ACTION_STATUS, mqActions, mqActionBody, heldReleaseBody, releasable, effectText }
  from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const has = (name, s, re) => console.log((re.test(s) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(s));

eq('status-map',     ACTION_STATUS, { HOLD: 'blocked', RESUME: 'queued', DROP: 'dropped' });
eq('offer-queued',   mqActions('queued'), ['HOLD', 'DROP']);
eq('offer-blocked',  mqActions('blocked'), ['RESUME', 'DROP']);
eq('offer-dropped',  mqActions('dropped'), ['RESUME']);
eq('offer-dead',     ['landed', 'weird', '', null, undefined].map(mqActions), [[], [], [], [], []]);

const row = { project: 'project-3', pr: 12 };
eq('body-hold',      mqActionBody(row, 'HOLD', ' why '), { project: 'project-3', pr: 12, status: 'blocked', reason: 'why' });
eq('body-blank',     ['', '   ', null, undefined].map((r) => mqActionBody(row, 'RESUME', r)), [null, null, null, null]);
const held = { repo: 'o/r', number: 4, state: 'aged', head: 'h', kind: 'stuck' };
eq('release-body',   heldReleaseBody(held, ' x '), { ...held, why: 'x' });
eq('release-blank',  heldReleaseBody(held, '  '), null);
eq('releasable',     [releasable(held), releasable({ ...held, head: '' }), releasable({})], [true, false, false]);

has('hold-off',      effectText('HOLD', 'off'), /already materialised as a file is still merged/);
for (const m of ['on', 'off', 'unread']) {
  has('drop-' + m,   effectText('DROP', m), /does not remove a file on a box/);
  has('resume-' + m, effectText('RESUME', m), /\.blocked/);
}
has('hold-unread',   effectText('HOLD', 'unread'), /could not be read/);
eq('unknown-mode',   effectText('HOLD', undefined), effectText('HOLD', 'unread'));
has('release',       effectText('RELEASE'), /page it owes is not sent.*hold it again/);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the screen's shape --------------------------------------------------
grep -q "useConfirm" "$SCREEN" && ok || bad "merge-queue-actions.js must confirm through the in-app useConfirm modal"
grep -q "api.setMergeQueue" "$SCREEN" && ok || bad "merge-queue-actions.js must send HOLD/RESUME/DROP through api.setMergeQueue"
grep -q "api.releaseHeldPage" "$SCREEN" && ok || bad "merge-queue-actions.js must send RELEASE through api.releaseHeldPage"
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN" "$LIB")
if [[ "$CODE" =~ (^|[^A-Za-z_.])(window\.)?(confirm|alert|prompt)[[:space:]]*\( ]]; then
  bad "a native dialog in the merge-queue actions"
else
  ok
fi

# --- 3: the node suite, driven -----------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "merge-queue-actions: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/merge-queue-actions.bh-2325.test.js tests/merge-queue-contract.bh-3155.test.js 2>&1); then ok
  else bad "the merge-queue actions node suite failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "merge-queue-actions: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
