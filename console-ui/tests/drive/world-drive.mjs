// Headless drive of the BUILT bundle at 375px and 1280px.
//
// Not a unit test: this serves dist/ over http with the four /world reads
// stubbed from tests/drive/fixtures.mjs, opens the real page in chromium, and
// asserts what a person would check by hand — the planet draws, a tap on a body
// opens that job, a tap on a territory opens that project, the fail-closed 403
// path still says what to do, and the console stays clean throughout.
//
// The fixtures are the point of honesty here: this box cannot reach the live
// console's authed reads, so the drive proves the SCREEN, not the data.
//
//   node tests/drive/world-drive.mjs [--shots <dir>] [--scale 1|2]
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
// 2 is what a phone actually has; 1 is for the copies that get committed.
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

// `authed` flips the whole API to the worker's documented unauthenticated
// answer, which is the only way to see what a signed-out console renders.
let authed = true;
const unknown = new Set();

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  if (url.pathname.startsWith('/api/')) {
    if (!authed) {
      res.writeHead(403, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ error: 'unauthorized' }));
    }
    const body = ROUTES[url.pathname];
    if (!body) unknown.add(url.pathname);
    // Anything the shell asks for beyond the four /world reads answers with an
    // empty envelope rather than a 404: a 404 in the console log would be the
    // drive's own noise, not the screen's.
    res.writeHead(200, { 'content-type': 'application/json' });
    return res.end(JSON.stringify(body || {}));
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

  const browser = await chromium.launch({
    // Headless chromium has no GPU: SwiftShader is what makes WebGL exist at
    // all here. A real phone has a real GPU and takes the same path.
    args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--disable-gpu-sandbox']
  });

  for (const [name, width, height] of [['mobile', 375, 780], ['desktop', 1280, 900]]) {
    const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: scale });
    const errors = [];
    page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
    // WORLD is a read. If it ever POSTs, that is a contract break, not a bug.
    const writes = [];
    page.on('request', (r) => {
      if (r.method() !== 'GET' && new URL(r.url()).pathname.startsWith('/api/')) writes.push(`${r.method()} ${new URL(r.url()).pathname}`);
    });
    page.on('pageerror', (e) => errors.push(String(e)));

    await page.goto(`${base}/world`, { waitUntil: 'networkidle' });
    await page.waitForSelector('canvas.world3d', { timeout: 15000 });
    await page.waitForTimeout(1800);
    // On a phone the scene starts below the fold; the shots are of the scene.
    await page.evaluate(() => document.querySelector('.worldwrap').scrollIntoView({ block: 'center' }));
    await page.waitForTimeout(300);

    const reads = await page.evaluate(() => performance.getEntriesByType('resource')
      .map((e) => new URL(e.name).pathname).filter((p) => p.startsWith('/api/')));
    const expected = ['/api/coord/jobs', '/api/cockpit/needs', '/api/dash/machines', '/api/dash/projects', '/api/dash/fleet'];
    const extra = [...new Set(reads)].filter((p) => !expected.includes(p));
    check(extra.length === 0, `${name}: reads only the endpoints /world already read${extra.length ? ` — also called ${extra.join(', ')}` : ''}`);
    check(writes.length === 0, `${name}: writes nothing${writes.length ? ` — ${writes.join(', ')}` : ''}`);

    // The planet is actually DRAWN, not merely present. readPixels is no good
    // here (the drawing buffer is not preserved), so the drive measures what a
    // person sees: the composited screenshot of the canvas, decoded back into
    // pixels and counted. A canvas that never got a frame is uniform black.
    const clip = await page.locator('canvas.world3d').boundingBox();
    const shot = (await page.screenshot({ clip })).toString('base64');
    const drawn = await page.evaluate(async (b64) => {
      const img = new Image();
      await new Promise((res, rej) => { img.onload = res; img.onerror = rej; img.src = 'data:image/png;base64,' + b64; });
      const c = document.createElement('canvas');
      c.width = img.width; c.height = img.height;
      c.getContext('2d').drawImage(img, 0, 0);
      const px = c.getContext('2d').getImageData(0, 0, c.width, c.height).data;
      let lit = 0, green = 0;
      for (let i = 0; i < px.length; i += 4) {
        if (px[i] + px[i + 1] + px[i + 2] > 60) lit++;
        if (px[i + 1] > px[i] + 12 && px[i + 1] > 60) green++;
      }
      return { total: px.length / 4, lit, green };
    }, shot);
    check(drawn.lit > drawn.total * 0.05 && drawn.green > drawn.total * 0.02,
      `${name}: the planet renders (${((drawn.lit / drawn.total) * 100).toFixed(1)}% lit, ${((drawn.green / drawn.total) * 100).toFixed(1)}% phosphor)`);

    check(await page.locator('.stats .stat').count() >= 4, `${name}: the four counters render`);
    const territories = await page.locator('.section:has(.section__title:text-is("TERRITORIES")) .wlist__row').count();
    check(territories >= 8, `${name}: every project has a keyboard-reachable row (${territories})`);
    const handsUp = await page.locator('.section:has(.section__title:text-is("HANDS UP")) .wlist__row').count();
    check(handsUp >= 3, `${name}: hands-up list carries the blocked rows (${handsUp})`);

    // No horizontal body scroll at any width — the whole reason the scene clips.
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    check(overflow <= 0, `${name}: no horizontal body scroll (${overflow}px)`);

    await page.screenshot({ path: path.join(shotDir, `world-3d-${name}.png`) });

    // Tap a body. The planet turns, so the drive hunts the canvas for one
    // rather than assuming a pixel: this is the same raycast a thumb uses.
    const box = await page.locator('canvas.world3d').boundingBox();
    let opened = null;
    outer:
    for (let ry = 0.28; ry <= 0.72; ry += 0.035) {
      for (let rx = 0.2; rx <= 0.8; rx += 0.035) {
        const x = box.x + box.width * rx;
        const y = box.y + box.height * ry;
        await page.mouse.move(x, y);
        await page.mouse.down();
        await page.waitForTimeout(30);
        const card = await page.locator('.worldpick').count();
        if (!card) { await page.mouse.up(); continue; }
        const label = await page.locator('.worldpick__name').innerText();
        const kind = await page.locator('.worldpick__go').count();
        if (name === 'mobile') await page.screenshot({ path: path.join(shotDir, 'world-3d-mobile-pick.png') });
        await page.mouse.up();
        await page.waitForTimeout(250);
        opened = { label, kind, url: page.url() };
        break outer;
      }
    }
    check(Boolean(opened), `${name}: a tap lands on something and names it`);
    if (opened) {
      const p = new URL(opened.url).pathname;
      check(p.startsWith('/jobs/') || p.startsWith('/p/') || p === '/machines',
        `${name}: that tap opened ${p} (touched "${opened.label}")`);
      if (p !== '/world') {
        await page.screenshot({ path: path.join(shotDir, `world-3d-${name}-opened.png`) });
      }
    }

    // Back to the world, then prove the flat map is still a real screen by
    // taking away WebGL the way a locked-down browser does.
    const flat = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: scale });
    await flat.addInitScript(() => {
      const orig = HTMLCanvasElement.prototype.getContext;
      HTMLCanvasElement.prototype.getContext = function (kind, ...rest) {
        if (String(kind).includes('webgl')) return null;
        return orig.call(this, kind, ...rest);
      };
    });
    await flat.goto(`${base}/world`, { waitUntil: 'networkidle' });
    await flat.waitForTimeout(600);
    check(await flat.locator('svg.world').count() === 1, `${name}: no WebGL falls back to the flat hex map`);
    check((await flat.locator('.worldnote').innerText()).includes('2D mode'), `${name}: the flat map says it is 2D mode`);
    check(await flat.locator('canvas.world3d').count() === 0, `${name}: no 3D canvas is created when WebGL is missing`);
    await flat.screenshot({ path: path.join(shotDir, `world-2d-${name}.png`) });
    await flat.close();

    check(errors.length === 0, `${name}: no console errors${errors.length ? ` — ${errors.slice(0, 3).join(' | ')}` : ''}`);
    await page.close();
  }

  // prefers-reduced-motion: the planet still has to be THERE, just still. A
  // reader who asked for less motion is not asking for less information.
  const still = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  await still.emulateMedia({ reducedMotion: 'reduce' });
  await still.goto(`${base}/world`, { waitUntil: 'networkidle' });
  await still.waitForSelector('canvas.world3d', { timeout: 15000 });
  await still.waitForTimeout(1200);
  const clip = await still.locator('canvas.world3d').boundingBox();
  const a = await still.screenshot({ clip });
  await still.waitForTimeout(1200);
  const b = await still.screenshot({ clip });
  check(Buffer.compare(a, b) === 0, 'prefers-reduced-motion holds the scene still');
  check(a.length > 5000, 'prefers-reduced-motion still draws the planet');
  await still.close();

  // Fail closed: every read answers 403 and the console has to say what to do.
  authed = false;
  const out = await browser.newPage({ viewport: { width: 375, height: 780 } });
  await out.goto(`${base}/world`, { waitUntil: 'networkidle' });
  await out.waitForTimeout(500);
  const text = await out.locator('body').innerText();
  check(text.includes('NOT SIGNED IN'), '403 on every read still renders the sign-in guidance');
  check(text.includes('/login/'), '403 guidance names the login path, as it did before');
  await out.screenshot({ path: path.join(shotDir, 'world-403.png') });
  await out.close();

  await browser.close();
  server.close();
  if (unknown.size) console.log(`\nnote: the shell also asked for ${[...unknown].join(', ')} — stubbed empty, they are not /world reads`);
  console.log(fail.length ? `\n${fail.length} FAILED` : '\nall checks passed');
  process.exit(fail.length ? 1 : 0);
}

run().catch((e) => { console.error(e); process.exit(1); });
