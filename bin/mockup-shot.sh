#!/bin/bash
# mockup-shot.sh <idea-dir> — screenshot mockup.html at desktop (1280) + mobile (375).
# Uses the globally-installed playwright (same install the QA stage relies on).
# Fail-soft: a missing screenshot never blocks the gate (the cockpit just shows no preview).
set -uo pipefail
IDIR="${1:?usage: mockup-shot.sh <idea-dir>}"
[ -s "$IDIR/mockup.html" ] || exit 1
export NODE_PATH="${NODE_PATH:-$(npm root -g 2>/dev/null)}"
node - "$IDIR" <<'EOF'
const path = process.argv[2];
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch();
  // Tall-but-bounded viewports instead of fullPage: keeps PNGs comfortably under
  // the console's per-asset cap while still showing the whole above-fold design.
  for (const [name, width, height] of [['desktop', 1280, 2000], ['mobile', 375, 2400]]) {
    const page = await browser.newPage({ viewport: { width, height } });
    await page.goto('file://' + path + '/mockup.html', { waitUntil: 'networkidle' });
    await page.waitForTimeout(400);
    await page.screenshot({ path: path + '/' + name + '.png' });
    await page.close();
  }
  await browser.close();
})().catch(e => { console.error(e.message); process.exit(1); });
EOF
