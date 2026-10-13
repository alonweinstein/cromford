// Headless drive of the BUILT bundle for the phone floor (BH-6001).
//
// Not a unit test. It serves dist/ over http with the fleet, jobs, kanban and
// job-detail reads stubbed (any other /api/* read answers {}, so a screen
// draws its empty state), opens /, /now, /alerts, /jobs, /kanban and one
// ticket page in chromium at 390px and 1440px, and measures what the ticket
// promised:
//   390px: every visible link, button and form control takes a tap anywhere on
//          the 44x44 square centred on it (document.elementFromPoint on a 5x5
//          grid lands on the control or inside it); no text is under 11px and
//          body text is 13px or more; --tap reads 44px.
//   1440px: the floor is off (--tap is unset, no hit-area ::after), and a
//          screenshot of each route for the comparison against main.
//   both:  the page never scrolls sideways.
//
//   node tests/drive/tap-drive.mjs [--theme mill|paper|phosphor] [--shots <dir>]
//
// Exit 0 = every check passed, 1 = a check failed, 2 = a bad argument or no dist/.

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';
import { ROUTES, jobs } from './fixtures.mjs';
import { BUILTIN_THEMES } from '../../src/theme/themes.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../..');
const dist = path.join(root, 'dist');

const args = process.argv.slice(2);
const KNOWN = new Set(['--theme', '--shots']);
for (let i = 0; i < args.length; i += 2) {
  if (!KNOWN.has(args[i]) || args[i + 1] === undefined) {
    console.error(`usage: node tests/drive/tap-drive.mjs [--theme mill|paper|phosphor] [--shots <dir>] (bad argument: ${args[i]})`);
    process.exit(2);
  }
}
const opt = (k, d) => (args.includes(k) ? args[args.indexOf(k) + 1] : d);
const shotDir = path.resolve(opt('--shots', path.join(root, 'shots')));
const themeId = opt('--theme', 'mill');
if (!BUILTIN_THEMES[themeId]) {
  console.error(`unknown --theme ${themeId} (one of ${Object.keys(BUILTIN_THEMES).join(', ')})`);
  process.exit(2);
}

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

// The kanban board and one job's detail, so /kanban and the ticket page draw
// rows (and the ticket page its station buttons) rather than empty states.
const JOB = jobs.jobs[0].id;
const card = (id, ticket, project, stage) => ({ id, project, ticket, ticket_key: ticket, bkey: ticket, stage, age_min: 12, tier: 2 });
const pipeline = {
  snapshot_age_min: 3,
  counts: { queued: 1, building: 2, merge_queue: 0, review: 1, merged_deployed: 1, dead_failed: 1 },
  columns: {
    queued: [{ project: 'project-3', queue_depth: 5, oldest_queued_min: 51, pending_commands: 2 }],
    building: [card(101, 'TK-104', 'project-3', 'executing'), card(102, 'TK-593', 'project-1', 'planning')],
    merge_queue: [],
    review: [{ ...card(105, 'TK-3', 'project-9', 'pr_created'), pr_url: 'https://github.com/example-org/project-9/pull/3' }],
    merged_deployed: [card(107, 'TK-99', 'project-3', 'merged')],
    dead_failed: [{ ...card(109, 'TK-70', 'project-3', 'failed'), verdict: 'typecheck failed three times' }]
  }
};
const detail = {
  job: { ...jobs.jobs[0], budget_usd: 150, spent_usd: 4.12, created_at: '2026-08-29T09:00:00Z', updated_at: '2026-08-29T10:05:00Z' },
  phases: [
    { id: 7, job_id: JOB, phase: 'plan', runner: 'fable', status: 'done', rc: 0, spend_usd: 0.4, started_at: '2026-08-29T09:58:00Z', finished_at: '2026-08-29T10:00:00Z' },
    { id: 8, job_id: JOB, phase: 'execute', runner: 'claude', status: 'running', spend_usd: 3.7, started_at: '2026-08-29T10:01:00Z' }
  ],
  transcripts: [], events: [], ledgers: [], artifacts: [], as_of: '2026-08-29T10:06:00Z'
};
const EXTRA = {
  '/api/dash/kanban/pipeline': pipeline,
  [`/api/coord/jobs/${JOB}`]: detail
};

const TICKET = jobs.jobs[0].ticket_id;
const PAGES = [['/', 'fleet'], ['/now', 'now'], ['/alerts', 'alerts'], ['/jobs', 'jobs'], ['/kanban', 'kanban'], [`/t/${TICKET}`, 'ticket']];
const WIDTHS = [[390, 844], [1440, 900]];

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  if (url.pathname.startsWith('/api/')) {
    const body = EXTRA[url.pathname] || ROUTES[url.pathname] || {};
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

// In the page: every visible control, scrolled to the middle of the viewport
// one at a time, sampled on a 5x5 grid over the 44x44 square centred on its
// box. A sample outside the viewport is skipped; any other sample
// that lands on something else is a miss.
function measureTargets(tap) {
  const SEL = 'a, button, summary, [role="button"], input:not([type="hidden"]), select, textarea';
  const visible = (el) => {
    const r = el.getClientRects()[0];
    if (!r || r.width < 2 || r.height < 2) return false;
    const cs = getComputedStyle(el);
    return cs.visibility !== 'hidden' && cs.pointerEvents !== 'none' && !el.closest('[hidden], [aria-hidden="true"]');
  };
  const name = (el) => `${el.tagName.toLowerCase()}${[...el.classList].map((c) => `.${c}`).join('')}${el.textContent.trim() ? ` "${el.textContent.trim().slice(0, 24)}"` : ''}`;
  // A checkbox or radio inside a label is tapped through its label.
  const target = (el) => (el.matches('input[type="checkbox"], input[type="radio"]') && el.closest('label')) || el;
  const els = [...new Set([...document.querySelectorAll(SEL)].map(target))].filter(visible);
  const misses = [];
  for (const el of els) {
    el.scrollIntoView({ block: 'center', inline: 'nearest' });
    // html and body clip sideways but still scroll by script: put them back.
    document.documentElement.scrollLeft = 0; document.body.scrollLeft = 0;
    // The ::after centres on the whole box, so a link that wraps to two lines
    // is measured on its bounding box, not its first line.
    const r = el.getBoundingClientRect();
    const cx = r.left + r.width / 2;
    const cy = r.top + r.height / 2;
    // Whole pixels: the first and last pixel column (row) of the square, so a
    // half-pixel sample is never snapped onto the neighbour's first pixel.
    const at = (c, k) => { const lo = Math.ceil(c - tap / 2); const hi = Math.floor(c + tap / 2) - 1; return lo + Math.round(((hi - lo) * k) / 4); };
    let bad = null; let sampled = 0;
    for (let i = 0; i < 5 && !bad; i++) {
      for (let j = 0; j < 5 && !bad; j++) {
        const x = at(cx, i);
        const y = at(cy, j);
        if (x < 0 || y < 0 || x >= innerWidth || y >= innerHeight) continue;
        sampled++;
        const hit = document.elementFromPoint(x, y);
        if (!hit || !(hit === el || el.contains(hit))) bad = { x: Math.round(x - cx), y: Math.round(y - cy), hit: hit ? name(hit) : 'nothing' };
      }
    }
    if (bad) misses.push(`${name(el)} (${Math.round(r.width)}x${Math.round(r.height)}) at ${bad.x},${bad.y} -> ${bad.hit}`);
    else if (!sampled) misses.push(`${name(el)}: no sample inside the viewport`);
  }
  window.scrollTo(0, 0);
  return { total: els.length, misses };
}

function smallestText() {
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  let min = Infinity; let at = '';
  for (let n; (n = walker.nextNode());) {
    if (!n.data.trim()) continue;
    const el = n.parentElement;
    const r = el.getClientRects()[0];
    if (!r || r.width < 2 || r.height < 2) continue;
    if (getComputedStyle(el).visibility === 'hidden') continue;
    const fs = parseFloat(getComputedStyle(el).fontSize);
    if (fs < min) { min = fs; at = `${el.tagName.toLowerCase()}${[...el.classList].map((c) => `.${c}`).join('')} "${n.data.trim().slice(0, 20)}"`; }
  }
  return { min, at, body: parseFloat(getComputedStyle(document.body).fontSize) };
}

async function run() {
  if (!fs.existsSync(path.join(dist, 'index.html'))) {
    console.error('dist/ is not built — run `npm run build` first');
    process.exit(2);
  }
  fs.mkdirSync(shotDir, { recursive: true });
  await new Promise((r) => server.listen(0, r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch();

  for (const [width, height] of WIDTHS) {
    const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1 });
    await page.addInitScript((id) => { window.localStorage.setItem('ui.theme', id); }, themeId);
    const errors = [];
    page.on('pageerror', (e) => errors.push(String(e)));

    for (const [route, what] of PAGES) {
      const at = `${width}px${route}`;
      await page.goto(`${base}${route}`, { waitUntil: 'networkidle' });
      await page.waitForSelector('.topbar', { timeout: 15000 });
      await page.evaluate(() => document.fonts.ready);
      await page.waitForTimeout(400);

      const tapVar = await page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue('--tap').trim());
      const after = await page.evaluate(() => {
        const a = document.querySelector('.topbar__brand');
        return a ? getComputedStyle(a, '::after').content : 'no .topbar__brand';
      });

      if (width < 600) {
        check(tapVar === '44px', `${at}: --tap is 44px (${tapVar || 'unset'})`);
        const { total, misses } = await page.evaluate(measureTargets, 44);
        console.log(`${at}: hit<44: ${misses.length} of ${total}`);
        for (const m of misses.slice(0, 12)) console.log(`       miss ${m}`);
        check(total > 0 && misses.length === 0, `${at}: every control takes a tap on its 44x44 square (${misses.length} of ${total} miss)`);
        const t = await page.evaluate(smallestText);
        check(t.min >= 11, `${at}: no text under 11px (smallest ${t.min}px, ${t.at})`);
        check(t.body >= 13, `${at}: body text is 13px or more (${t.body}px)`);
      } else {
        check(tapVar === '', `${at}: --tap is unset above 600px (${tapVar || 'unset'})`);
        check(after === 'none', `${at}: no hit-area ::after above 600px (${after})`);
        await page.screenshot({ path: path.join(shotDir, `tap-${what}-${width}.png`), fullPage: true });
      }

      const sw = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
      check(sw <= 0, `${at}: the page does not scroll sideways (scrollWidth is ${sw}px past innerWidth)`);
      // html/body clip with overflow-x: hidden, so scrollWidth alone reads clean;
      // the widest box laid out outside an inner scroller is the honest measure.
      const over = await page.evaluate((vw) => {
        let worst = 0;
        for (const el of document.querySelectorAll('body *')) {
          if (el.closest('.tablewrap, .topbar__nav, .bottomnav, .term, .track-scroll, .card__track')) continue;
          worst = Math.max(worst, Math.round(el.getBoundingClientRect().right) - vw);
        }
        return worst;
      }, width);
      check(over <= 1, `${at}: nothing is laid out past the viewport (${over}px over)`);
    }

    check(errors.length === 0, `${width}px: no page error (${errors.slice(0, 2).join(' | ') || 'clean'})`);
    await page.close();
  }

  await browser.close();
  server.close();
  console.log(`\nshots -> ${shotDir}`);
  if (fail.length) {
    console.error(`\n${fail.length} failed:\n  ${fail.join('\n  ')}`);
    process.exit(1);
  }
  console.log('all checks passed');
}

run().catch((e) => { console.error(e); process.exit(1); });
