// Headless drive of the BUILT bundle for /settings/appearance (BH-4846).
//
// Not a unit test. It serves dist/ over http with the three reads the screen
// makes stubbed (the fleet row, the settings list holding one custom theme,
// whoami), opens /settings/appearance in chromium at 1280px and 375px, opens
// the theme editor through NEW THEME FROM, and asserts the T8 promise: at
// 375px, with the editor open, the body does not scroll sideways.
//
//   node tests/drive/appearance-drive.mjs [--shots <dir>]
//
// Exit code is the verdict. Screenshots land in --shots (default ./shots).

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';
import { BUILTIN_THEMES } from '../../src/theme/themes.js';
import { CUSTOM_PREFIX, docFromTheme, exportTheme } from '../../src/theme/custom.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../..');
const dist = path.join(root, 'dist');

const args = process.argv.slice(2);
const shotDir = path.resolve(args.includes('--shots') ? args[args.indexOf('--shots') + 1] : path.join(root, 'shots'));

const require = createRequire(import.meta.url);
let chromium;
try {
  ({ chromium } = require('playwright'));
} catch {
  process.env.NODE_PATH = execSync('npm root -g').toString().trim();
  require('node:module').Module._initPaths();
  ({ chromium } = require('playwright'));
}

const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.woff2': 'font/woff2', '.svg': 'image/svg+xml', '.png': 'image/png', '.json': 'application/json' };

// A long name on purpose: the card and the editor's name field are where a
// 375px layout would first push past the viewport.
const custom = docFromTheme(BUILTIN_THEMES.mill, 'Night shift with a very long theme name');
const ROUTES = {
  '/api/coord/settings/ui.theme.default': { setting: { key: 'ui.theme.default', value: 'mill' } },
  '/api/coord/settings': { settings: [{ key: `${CUSTOM_PREFIX}night-shift`, value: exportTheme(custom), actor: 'operator@example.com', updated_at: '2026-10-06T20:00:00Z' }] },
  '/api/coord/whoami': { access: 'on', email: 'operator@example.com' }
};

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  if (url.pathname.startsWith('/api/')) {
    const body = ROUTES[decodeURIComponent(url.pathname)] || {};
    res.writeHead(200, { 'content-type': 'application/json' });
    return res.end(JSON.stringify(body));
  }
  let file = path.join(dist, url.pathname === '/' ? 'index.html' : url.pathname.slice(1));
  if (!fs.existsSync(file) || fs.statSync(file).isDirectory()) file = path.join(dist, 'index.html');
  res.writeHead(200, { 'content-type': MIME[path.extname(file)] || 'application/octet-stream' });
  return res.end(fs.readFileSync(file));
});

const fail = [];
const check = (ok, what) => {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${what}`);
  if (!ok) fail.push(what);
};

async function run() {
  if (!fs.existsSync(path.join(dist, 'index.html'))) {
    console.error('dist/ is not built — run `npm run build` first');
    process.exit(2);
  }
  fs.mkdirSync(shotDir, { recursive: true });
  await new Promise((r) => server.listen(0, r));
  const base = `http://127.0.0.1:${server.address().port}`;
  // CHROMIUM_PATH: a box whose playwright and browser builds have drifted apart.
  const browser = await chromium.launch(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {});

  for (const [name, width, height] of [['desktop', 1280, 900], ['mobile', 375, 780]]) {
    const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1 });
    await page.goto(`${base}/settings/appearance`, { waitUntil: 'networkidle' });
    await page.waitForSelector('[data-theme-id="custom.night-shift"]', { timeout: 15000 });
    check(true, `${name}: the saved custom theme renders as a card`);

    await page.selectOption('select[data-new-from]', 'mill');
    await page.waitForSelector('[data-theme-editor="open"]', { timeout: 15000 });
    check(await page.locator('[data-theme-editor="open"] input[type=color][data-token]').count() > 0,
      `${name}: NEW THEME FROM opens the editor with its colour inputs`);
    await page.evaluate(() => document.fonts.ready);
    await page.screenshot({ path: path.join(shotDir, `appearance-editor-${name}.png`), fullPage: true });

    const sw = await page.evaluate(() => document.documentElement.scrollWidth);
    check(sw <= width, `${name}: documentElement.scrollWidth ${sw} <= ${width} with the editor open`);
    // Wide content may scroll inside its own overflow container; anything
    // outside one must fit the viewport.
    const over = await page.evaluate((w) => {
      const clipped = (el) => {
        for (let p = el.parentElement; p && p !== document.body; p = p.parentElement) {
          if (['auto', 'scroll', 'hidden', 'clip'].includes(getComputedStyle(p).overflowX)) return true;
        }
        return false;
      };
      return Math.max(0, ...[...document.querySelectorAll('body *')]
        .filter((el) => !clipped(el))
        .map((el) => Math.ceil(el.getBoundingClientRect().right) - w));
    }, width);
    check(over <= 1, `${name}: nothing is laid out past the viewport (${over}px over)`);
    await page.close();
  }

  await browser.close();
  server.close();
  if (fail.length) {
    console.log(`\n${fail.length} check(s) failed`);
    process.exit(1);
  }
  console.log('\nall checks passed');
}

run().catch((e) => { console.error(e); server.close(); process.exit(1); });
