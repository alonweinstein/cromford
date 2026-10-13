#!/bin/bash
# tests/main-red-banner-console.bh-2374-test.sh — the main-red banner on
# /p/<project> with its audited CLEAR (BH-2374, BH-2329.3).
#
# WHY A SHELL SUITE AS WELL. The behaviour is proved by node --test in
# console-ui/tests/main-red-banner.bh-2329.test.js and
# console-ui/tests/main-red-proxy.bh-2329.test.js (reached through the
# console-ui job). What this file adds is the part the impact lane and the
# orphan ratchet can SEE: it names the new source by path, drives its pure half
# for real, and holds the screen and the proxy to the rules a reviewer would
# otherwise check by eye (the cost-breaker-console.bh-2331 pattern).
#
#   1. MainRedBanner.js, DRIVEN (when the console-ui dependencies are
#      installed, since it imports preact): the row shapes it reads, which rows
#      belong to a project, a blank reason blocks CLEAR, and runClear sends only
#      name, reason and sha and reports a worker refusal as a failure.
#   2. the banner asks through the in-app useConfirm, is mounted on Project.js,
#      never calls a native dialog, and the coord proxy forwards the CLEAR as an
#      allowlist of fields rather than the browser's body.
#   3. both node suites, run for real when the console-ui dependencies are
#      installed.
# Run from anywhere: tests/main-red-banner-console.bh-2374-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

UI="$DIR/console-ui/src/ui/MainRedBanner.js"
PROJECT="$DIR/console-ui/src/screens/Project.js"
PROXY="$DIR/console-ui/functions/api/coord/[[path]].js"

for f in "$UI" "$PROJECT" "$PROXY"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

# --- 2: the screen's and the proxy's shape -----------------------------------
grep -q "useConfirm\|confirm({" "$UI" && ok || bad "MainRedBanner.js must ask through the in-app confirm modal"
grep -q "confirmBlocked: true" "$UI" && ok || bad "the CLEAR dialog must open blocked until a reason is typed"
grep -q "from '../ui/MainRedBanner.js'" "$PROJECT" && grep -q '<\${MainRedBanner}' "$PROJECT" \
  && ok || bad "Project.js must mount MainRedBanner"
CODE=$(grep -hvE '^[[:space:]]*//' "$UI")
if [[ "$CODE" =~ (window\.|globalThis\.|[^.a-zA-Z_])(confirm|alert|prompt)[[:space:]]*\([[:space:]]*[\'\"\`] ]]; then
  bad "a native dialog in the main-red banner"
else
  ok
fi
# BH-2405: the CLEAR is a WRITES row; its allowlist is the row's body list,
# string-only (isStr), in the row's order with the actor last (rowOrder).
grep -qF "{ method: 'POST', path: 'main-red/clear', body: ['name', 'reason', 'sha'], ok: isStr, rowOrder: true }" "$PROXY" \
  && ok || bad "the coord proxy must forward the CLEAR as the name/reason/sha allowlist"
grep -qF "} else init.body = JSON.stringify(pickBody(sent, row, actor));" "$PROXY" \
  && ok || bad "the coord proxy must build the CLEAR body from the allowlist, not the browser's body"

command -v node >/dev/null 2>&1 || { echo "main-red-banner-console: node parts SKIPPED — node is not installed on this box ($PASS passed, $FAIL failed)"; [ "$FAIL" -eq 0 ]; exit; }
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "main-red-banner-console: node parts SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs them)"
  echo "main-red-banner-console: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi

# --- 1: the banner's pure half, driven ---------------------------------------
OUT=$(cd "$DIR/console-ui" && node --input-type=module -e "
import { mainRedRows, mainRedForProject, clearFormState, runClear } from '$UI';
import { api } from '$DIR/console-ui/src/api.js';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));

eq('rows-main_red',  mainRedRows({ main_red: [{ name: 'a' }] }), [{ name: 'a' }]);
eq('rows-array',     mainRedRows([{ name: 'b' }]), [{ name: 'b' }]);
eq('rows-rows',      mainRedRows({ rows: [{ name: 'c' }] }), [{ name: 'c' }]);
eq('rows-junk',      mainRedRows(null), []);
const rows = [
  { name: 'main-red-project-3', project: 'project-3' },
  { name: 'main-red-other' },
  { name: 'main-red-project-3-pr', project: 'project-3' },
  { name: 'main-red-example-org-x-pair' },
  null ];
eq('for-project',    mainRedForProject(rows, 'project-3').map((r) => r.name), ['main-red-project-3', 'main-red-project-3-pr']);
eq('for-name',       mainRedForProject(rows, 'other').map((r) => r.name), ['main-red-other']);
eq('for-none',       mainRedForProject(rows, 'nope'), []);
eq('form-blank',     clearFormState({ reason: '   ' }).blocked, true);
eq('form-missing',   clearFormState(null).blocked, true);
eq('form-reason',    clearFormState({ reason: 'flaky runner' }), { blocked: false, hint: null });

const sent = [];
api.clearMainRed = async (b) => { sent.push(b); return { cleared: true }; };
const row = { name: 'main-red-project-3', sha: 'abc123', slug: 'example-org/project-3', actor: 'mallory', workflow: 'ci' };
eq('clear-ok',       await runClear(row, { reason: '  flaky  ' }), { ok: true, text: 'cleared' });
eq('clear-body',     sent, [{ name: 'main-red-project-3', reason: 'flaky', sha: 'abc123' }]);
api.clearMainRed = async () => { throw new Error('moved to a new sha'); };
eq('clear-409',      await runClear(row, { reason: 'r' }), { ok: false, text: 'moved to a new sha' });
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "banner: ${line#no }" ;;
    *) [ -n "$line" ] && bad "banner: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 3: the node suites, driven ----------------------------------------------
if NOUT=$(cd "$DIR/console-ui" && node --test tests/main-red-banner.bh-2329.test.js tests/main-red-proxy.bh-2329.test.js 2>&1); then ok
else bad "console-ui main-red node suites failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
fi

echo "main-red-banner-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
