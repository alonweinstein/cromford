// Headless drive of the KEYBOARD on /world, against the built bundle.
//
// tests/drive/world-drive.mjs proves the scene draws and a thumb can open
// things. This one proves the other input: real key events, dispatched by the
// browser into the real page, at 1280px and at 375px, in BOTH renderers — the
// three.js planet and the flat hex map a browser without WebGL gets.
//
// The planet is driven with prefers-reduced-motion on. That is not a dodge: it
// is what makes a before/after pixel count of the selection ring mean
// something, because a globe that is turning changes every pixel between two
// screenshots whether or not anything was selected. The key handling is
// identical either way — the frame loop is decoration.
//
//   node tests/drive/world-keys.mjs [--shots <dir>] [--scale 1|2]
//
// Exit code is the verdict. Screenshots land in --shots (default ./shots).

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';
import { ROUTES } from './fixtures.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../..');
const dist = path.join(root, 'dist');

const args = process.argv.slice(2);
const shotDir = path.resolve(args.includes('--shots') ? args[args.indexOf('--shots') + 1] : path.join(root, 'shots'));
const scale = args.includes('--scale') ? Number(args[args.indexOf('--scale') + 1]) : 2;

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

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  if (url.pathname.startsWith('/api/')) {
    res.writeHead(200, { 'content-type': 'application/json' });
    return res.end(JSON.stringify(ROUTES[url.pathname] || {}));
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

// What the screen says is selected, read the way a person reads it: the card in
// the corner of the scene and the live region the screen reader hears.
const selected = (page) => page.evaluate(() => {
  const card = document.querySelector('.worldpick');
  const live = document.querySelector('.worldsr');
  return {
    label: card ? (card.querySelector('.worldpick__name') || {}).textContent || null : null,
    keyed: card ? card.classList.contains('worldpick--keyed') : false,
    live: live ? live.textContent.trim() : ''
  };
});

// Cursor pixels inside the scene box. The selection ring is the only thing in
// this black world drawn in pure white at any thickness, so counting them is
// how a canvas answers "is the ring visible".
const inkPixels = async (page, sel) => {
  const clip = await page.locator(sel).boundingBox();
  const shot = (await page.screenshot({ clip })).toString('base64');
  return page.evaluate(async (b64) => {
    const img = new Image();
    await new Promise((res, rej) => { img.onload = res; img.onerror = rej; img.src = 'data:image/png;base64,' + b64; });
    const c = document.createElement('canvas');
    c.width = img.width; c.height = img.height;
    const ctx = c.getContext('2d');
    ctx.drawImage(img, 0, 0);
    const px = ctx.getImageData(0, 0, c.width, c.height).data;
    let ink = 0;
    for (let i = 0; i < px.length; i += 4) {
      // #FFFFFF and its antialiased neighbours. The threshold sits above the
      // console's brightest ordinary ink (labels at #C9DCC9, phosphor green at
      // #4AF37A), so only the cursor itself is counted.
      if (px[i] > 235 && px[i + 1] > 235 && px[i + 2] > 235) ink++;
    }
    return ink;
  }, shot);
};

async function open(browser, { width, height, webgl = true }) {
  const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: scale });
  const errors = [];
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  page.on('pageerror', (e) => errors.push(String(e)));
  // The cursor-ink count above is calibrated on Phosphor's palette (its
  // brightest ordinary ink sits under the #FFFFFF threshold). Mill's chalk
  // text does not, so the drive pins Phosphor rather than move the threshold
  // (BH-4844 made Mill the default).
  await page.addInitScript(() => { try { localStorage.setItem('ui.theme', 'phosphor'); } catch { /* none */ } });
  if (!webgl) {
    await page.addInitScript(() => {
      const orig = HTMLCanvasElement.prototype.getContext;
      HTMLCanvasElement.prototype.getContext = function (kind, ...rest) {
        if (String(kind).includes('webgl')) return null;
        return orig.call(this, kind, ...rest);
      };
    });
  }
  await page.emulateMedia({ reducedMotion: 'reduce' });
  page.errors = errors;
  return page;
}

async function driveRenderer(browser, { name, width, height, webgl, base }) {
  const page = await open(browser, { width, height, webgl });
  await page.goto(`${base}/world`, { waitUntil: 'networkidle' });
  if (webgl) await page.waitForSelector('canvas.world3d', { timeout: 15000 });
  else await page.waitForSelector('svg.world', { timeout: 15000 });
  await page.waitForTimeout(1200);
  await page.evaluate(() => document.querySelector('.worldwrap').scrollIntoView({ block: 'center' }));
  await page.waitForTimeout(200);

  const tag = `${webgl ? '3d' : '2d'}-${name}`;

  check((await selected(page)).label === null, `${tag}: nothing is selected before a key is pressed`);
  const bare = await inkPixels(page, '.worldwrap');

  // The first press, with nothing selected, lands on something near the middle.
  await page.keyboard.press('ArrowRight');
  await page.waitForTimeout(250);
  const first = await selected(page);
  check(Boolean(first.label), `${tag}: the first arrow press selects something ("${first.label}")`);
  check(first.keyed, `${tag}: the card says the selection came from the keyboard`);
  check(first.live.includes(String(first.label)) && first.live.includes('selected'),
    `${tag}: the live region announces it ("${first.live.slice(0, 70)}…")`);

  const ringed = await inkPixels(page, '.worldwrap');
  check(ringed > bare, `${tag}: the selection ring is actually drawn (${bare} -> ${ringed} cursor pixels)`);
  await page.screenshot({ path: path.join(shotDir, `keys-${tag}-selected.png`) });
  await page.locator('.worldwrap').screenshot({ path: path.join(shotDir, `keys-${tag}-scene.png`) });

  // Movement is spatial, and it MOVES: walking the four directions has to land
  // on more than one body, or the arrows are decoration.
  const walk = [first.label];
  const keys = ['ArrowRight', 'ArrowDown', 'ArrowLeft', 'ArrowUp', 'd', 's', 'a', 'w'];
  for (let i = 0; i < keys.length; i++) {
    await page.keyboard.press(keys[i]);
    await page.waitForTimeout(160);
    walk.push((await selected(page)).label);
    // Mid-walk, not end-of-walk: eight symmetric presses can land you back
    // where you started, and a screenshot of that proves nothing.
    if (i === 2) await page.locator('.worldwrap').screenshot({ path: path.join(shotDir, `keys-${tag}-moved.png`) });
  }
  const distinct = [...new Set(walk)];
  check(distinct.length >= 3, `${tag}: the arrows walk the scene (${distinct.length} distinct: ${distinct.slice(0, 4).join(' | ')})`);

  // Bodies, not just islands. A body's label is "box · stage" or "box · idle",
  // which is how this tells the two populations apart without reaching inside
  // the app for its own state.
  let body = null;
  for (let i = 0; i < 14 && !body; i++) {
    await page.keyboard.press(['ArrowDown', 'ArrowRight', 'ArrowUp', 'ArrowLeft'][i % 4]);
    await page.waitForTimeout(140);
    const cur = await selected(page);
    if (cur.label && cur.label.includes('·')) body = cur.label;
  }
  check(Boolean(body), `${tag}: the arrows reach the bodies too, not only the territories ("${body}")`);
  if (body) await page.locator('.worldwrap').screenshot({ path: path.join(shotDir, `keys-${tag}-body.png`) });

  // WASD is the same four directions, not a second scheme. Note what is NOT
  // claimed here: that left undoes right. Spatial movement picks the nearest
  // thing in a direction, and on a scene where bodies stand in rings around
  // their own territory the nearest thing back is often a different body — the
  // reversible case is asserted on a clean grid in tests/worldnav.test.js.
  await page.keyboard.press('Escape');
  await page.waitForTimeout(150);
  check((await selected(page)).label === null, `${tag}: Escape clears the selection`);
  await page.keyboard.press('ArrowRight');
  await page.waitForTimeout(200);
  const home = (await selected(page)).label;
  await page.keyboard.press('d');
  await page.waitForTimeout(200);
  const east = (await selected(page)).label;
  await page.keyboard.press('a');
  await page.waitForTimeout(200);
  const back = (await selected(page)).label;
  check(Boolean(east) && east !== home, `${tag}: "d" moves right like ArrowRight ("${home}" -> "${east}")`);
  check(Boolean(back) && back !== east, `${tag}: "a" moves back left ("${east}" -> "${back}")`);

  // The guard: a key typed into an input is the input's.
  await page.evaluate(() => {
    const i = document.createElement('input');
    i.id = 'guard';
    i.style.cssText = 'position:fixed;top:0;left:0;z-index:99';
    document.body.appendChild(i);
    i.focus();
  });
  const beforeType = (await selected(page)).label;
  await page.keyboard.type('was');
  await page.keyboard.press('ArrowRight');
  await page.keyboard.press('ArrowDown');
  await page.waitForTimeout(200);
  const afterType = (await selected(page)).label;
  check(afterType === beforeType, `${tag}: typing in an input never moves the selection ("${beforeType}")`);
  check(await page.inputValue('#guard') === 'was', `${tag}: the input got the letters it was typed`);
  await page.evaluate(() => document.getElementById('guard').remove());

  // Focus somewhere else on the page and the arrows go back to being the
  // page's: this is the check that /world has not broken scrolling. The link
  // has to be one that is actually RENDERED at this width — the top bar's nav
  // is display:none on a phone, and focusing a hidden element is a no-op that
  // would quietly turn this into a test of nothing.
  const focused = await page.evaluate(() => {
    window.scrollTo(0, 0);
    const wrap = document.querySelector('.worldwrap');
    const a = [...document.querySelectorAll('a[href]')]
      .find((el) => el.offsetParent !== null && !wrap.contains(el));
    if (a) a.focus();
    return Boolean(a) && document.activeElement === a;
  });
  check(focused, `${tag}: a link outside the scene can take the focus`);
  const beforeScroll = await page.evaluate(() => window.scrollY);
  const beforeSel = (await selected(page)).label;
  for (let i = 0; i < 8; i++) await page.keyboard.press('ArrowDown');
  await page.waitForTimeout(250);
  const afterScroll = await page.evaluate(() => window.scrollY);
  check((await selected(page)).label === beforeSel, `${tag}: focus outside the scene leaves the selection alone`);
  check(afterScroll > beforeScroll, `${tag}: and the page still scrolls with the arrow keys (${beforeScroll} -> ${afterScroll})`);

  // Enter opens exactly what a click would.
  await page.evaluate(() => { document.activeElement.blur(); document.querySelector('.worldwrap').scrollIntoView({ block: 'center' }); });
  await page.waitForTimeout(150);
  const target = await selected(page);
  const href = await page.locator('.worldpick').getAttribute('href');
  await page.keyboard.press('Enter');
  await page.waitForTimeout(400);
  const landed = new URL(page.url()).pathname;
  check(landed === href, `${tag}: Enter opened ${landed}, which is where "${target.label}" links (${href})`);
  check(landed.startsWith('/jobs/') || landed.startsWith('/p/') || landed === '/machines',
    `${tag}: and that is a real detail screen`);
  await page.screenshot({ path: path.join(shotDir, `keys-${tag}-opened.png`) });

  // No horizontal body scroll, still — the selection ring must not widen the page.
  await page.goBack();
  await page.waitForTimeout(600);
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  check(overflow <= 0, `${tag}: no horizontal body scroll (${overflow}px)`);

  check(page.errors.length === 0, `${tag}: no console errors${page.errors.length ? ` — ${page.errors.slice(0, 3).join(' | ')}` : ''}`);
  await page.close();
}

async function run() {
  if (!fs.existsSync(path.join(dist, 'index.html'))) {
    console.error('dist/ is not built — run `npm run build` first');
    process.exit(2);
  }
  fs.mkdirSync(shotDir, { recursive: true });
  await new Promise((r) => server.listen(0, r));
  const base = `http://127.0.0.1:${server.address().port}`;

  const browser = await chromium.launch({
    args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--disable-gpu-sandbox']
  });

  for (const [name, width, height] of [['desktop', 1280, 900], ['mobile', 375, 780]]) {
    for (const webgl of [true, false]) {
      await driveRenderer(browser, { name, width, height, webgl, base });
    }
  }

  // And once with the frame loop actually RUNNING. The pixel checks above need
  // a still planet to mean anything, but the keys must work on a turning one —
  // a globe that has rotated between two presses is the normal case, not an
  // edge case.
  const spinning = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  await spinning.goto(`${base}/world`, { waitUntil: 'networkidle' });
  await spinning.waitForSelector('canvas.world3d', { timeout: 15000 });
  await spinning.waitForTimeout(1500);
  const seen = [];
  for (const k of ['ArrowRight', 'ArrowDown', 'ArrowLeft', 'ArrowUp', 'ArrowRight']) {
    await spinning.keyboard.press(k);
    // Long enough that the planet has visibly turned between presses.
    await spinning.waitForTimeout(700);
    seen.push((await selected(spinning)).label);
  }
  check(seen.every(Boolean), `a turning planet still answers the arrows (${seen.filter(Boolean).length}/5 presses selected something)`);
  check(new Set(seen).size >= 2, `and the selection moves while it turns (${[...new Set(seen)].slice(0, 3).join(' | ')})`);
  await spinning.screenshot({ path: path.join(shotDir, 'keys-3d-desktop-spinning.png') });
  await spinning.close();

  // The scene box is a tab stop, so a keyboard reader can find it at all.
  const page = await open(browser, { width: 1280, height: 900 });
  await page.goto(`${base}/world`, { waitUntil: 'networkidle' });
  await page.waitForSelector('canvas.world3d', { timeout: 15000 });
  const aria = await page.evaluate(() => {
    const w = document.querySelector('.worldwrap');
    return { tabindex: w.getAttribute('tabindex'), label: w.getAttribute('aria-label'), keys: w.getAttribute('aria-keyshortcuts') };
  });
  check(aria.tabindex === '0', 'the world box is focusable');
  check(/arrow/i.test(aria.label || ''), `its label says how to drive it ("${aria.label}")`);
  check(/ArrowUp/.test(aria.keys || ''), 'and declares its shortcuts');
  await page.close();

  await browser.close();
  server.close();
  console.log(fail.length ? `\n${fail.length} FAILED` : '\nall checks passed');
  process.exit(fail.length ? 1 : 0);
}

run().catch((e) => { console.error(e); process.exit(1); });
