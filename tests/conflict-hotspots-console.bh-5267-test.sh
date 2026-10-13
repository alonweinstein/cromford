#!/bin/bash
# tests/conflict-hotspots-console.bh-5267-test.sh — the console CONFLICT
# HOTSPOTS section on /p/<project> (BH-5267).
#
# WHY A SHELL SUITE AS WELL. The screen's behaviour is proved by node --test in
# console-ui/tests/conflict-hotspots-panel.bh-5267.test.js (reached through the
# console-ui job). What this file adds is the part the impact lane and the
# orphan ratchet can SEE: it names the two new sources by path, drives the pure
# half for real, and runs the node suite (the cost-breaker-console.bh-2331
# pattern).
#
#   1. lib/conflict-hotspots-panel.js, DRIVEN: only #<digits> becomes a PR
#      link, names stay text, blanks drop; the file links to GitHub history
#      only when the run has a repo AND a sha (never a made-up URL); the run
#      note says never measured / last measured / latest run failed, each only
#      when it is true.
#   2. the node suite console-ui/tests/conflict-hotspots-panel.bh-5267.test.js,
#      run for real when the console-ui dependencies are installed.
# Run from anywhere: tests/conflict-hotspots-console.bh-5267-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/conflict-hotspots-panel.js"
SCREEN="$DIR/console-ui/src/screens/ConflictHotspotsPanel.js"

for f in "$LIB" "$SCREEN"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "conflict-hotspots-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { hotspotCells, panelNote, HOTSPOTS_SHOWN } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const SHA = 'abcdef0123456789abcdef0123456789abcdef01';
const NOW = Date.parse('2026-10-07T12:00:00Z');
const run = (o) => ({ repo: 'example-org/cromford', status: 'ok', detail: null, window_days: 14,
  ref_sha: SHA, run_at: '2026-10-07T09:00:00Z', last_ok_at: '2026-10-07T09:00:00Z', ...o });

eq('shown',          HOTSPOTS_SHOWN, 50);
eq('prs-mixed',      hotspotCells({ prs: '#12,#7,ticket/x' }, 'cromford', run()).prs, [
  { label: '#12', href: '/pr/cromford/12' }, { label: '#7', href: '/pr/cromford/7' },
  { label: 'ticket/x', href: null }]);
eq('prs-trim',       hotspotCells({ prs: '  #9 ,, ' }, 'p', null).prs, [{ label: '#9', href: '/pr/p/9' }]);
eq('prs-null',       hotspotCells({ prs: null }, 'p', null).prs, []);
eq('prs-not-a-pr',   hotspotCells({ prs: '12,#0,#1x' }, 'p', null).prs.map((x) => x.href), [null, null, null]);
eq('file-href',      hotspotCells({ file: 'bin/a b.sh', ref_sha: SHA }, 'p', run()).fileHref,
  'https://github.com/example-org/cromford/commits/' + SHA + '/bin/a%20b.sh');
eq('file-run-sha',   hotspotCells({ file: 'bin/x.sh' }, 'p', run()).fileHref,
  'https://github.com/example-org/cromford/commits/' + SHA + '/bin/x.sh');
eq('file-no-repo',   hotspotCells({ file: 'bin/x.sh', ref_sha: SHA }, 'p', run({ repo: null })).fileHref, null);
eq('file-no-sha',    hotspotCells({ file: 'bin/x.sh' }, 'p', run({ ref_sha: null })).fileHref, null);
eq('file-no-run',    hotspotCells({ file: 'bin/x.sh', ref_sha: SHA }, 'p', null).fileHref, null);

eq('note-never',     panelNote(null, NOW), 'never measured');
eq('note-ok',        panelNote(run(), NOW), 'last measured 3h ago, 14-day window');
eq('note-kept',      panelNote(run({ status: 'shallow', run_at: '2026-10-07T11:00:00Z' }), NOW),
  'latest run failed: shallow — showing the window from 3h ago');
eq('note-none',      panelNote(run({ status: 'no-checkout', last_ok_at: null, detail: 'no /root/repos/p' }), NOW),
  'latest run failed: no-checkout (no /root/repos/p) — no successful run yet');
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the node suite, driven -----------------------------------------------
# console-ui/tests/conflict-hotspots-panel.bh-5267.test.js mounts the real panel
# and the real Project page. Run here too, so this suite is its door as well as
# the console-ui CI job's; without the console deps it says so and skips.
if [ ! -d "$DIR/console-ui/node_modules/preact" ]; then
  echo "conflict-hotspots-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/conflict-hotspots-panel.bh-5267.test.js 2>&1); then ok
  else bad "console-ui/tests/conflict-hotspots-panel.bh-5267.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "conflict-hotspots-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
