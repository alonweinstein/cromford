#!/bin/bash
# tests/merge-pr-rekey.bh-4439-test.sh — a head-moved merge_pr refusal no
# longer holds the console command key for a new head (BH-4439).
#
# The behaviour is proved by node --test in
# console-ui/tests/merge-pr-retry.bh-4439.test.js, through the real Pages
# onRequest against a real SQLite commands table. This suite names the new
# source by path (the orphan check), drives the helper's skip reasons with
# node, and runs the node suite when the console-ui dependencies are installed.
# Run from anywhere: tests/merge-pr-rekey.bh-4439-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/functions/_lib/merge-pr-rekey.js"
PROXY="$DIR/console-ui/functions/api/[[path]].js"
SCREEN="$DIR/console-ui/src/screens/PR.js"

for f in "$LIB" "$PROXY" "$SCREEN"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "merge-pr-rekey: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the helper's guards, driven (no sqlite, no deps) -----------------------
OUT=$(node --input-type=module -e "
import { rekeyHeadMovedRefusal } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const H = 'c'.repeat(40);
const body = { type: 'merge_pr', project: 'p', ticket: 'T-1', verdict_sha: H };
let bound = null;
const db = { prepare: () => ({ bind: (...a) => { bound = a; return { run: async () => ({ meta: { changes: 1 } }) }; } }) };
eq('no-db',    await rekeyHeadMovedRefusal(null, body), { skipped: 'no-db' });
eq('no-verdict',  await rekeyHeadMovedRefusal(db, { ...body, verdict_sha: '' }), { skipped: 'no-verdict' });
eq('bad-verdict', await rekeyHeadMovedRefusal(db, { ...body, verdict_sha: 'c'.repeat(39) }), { skipped: 'bad-verdict' });
eq('no-key',   await rekeyHeadMovedRefusal(db, { ...body, project: '' }), { skipped: 'no-key' });
eq('rekeyed',  await rekeyHeadMovedRefusal(db, { ...body, verdict_sha: H.toUpperCase() }), { rekeyed: 1 });
eq('bound',    bound, ['p:T-1:merge_pr', H]);
const err = console.error; console.error = () => {};
eq('d1-error', await rekeyHeadMovedRefusal({ prepare: () => { throw new Error('x'); } }, body), { skipped: 'd1-error' });
console.error = err;
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the node suite, driven -----------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact" ]; then
  echo "merge-pr-rekey: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/merge-pr-retry.bh-4439.test.js 2>&1); then ok
  else bad "console-ui/tests/merge-pr-retry.bh-4439.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "merge-pr-rekey: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
