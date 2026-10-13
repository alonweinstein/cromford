// Headless drive of the BUILT bundle for the TYPE + DENSITY pass.
//
// Not a unit test. It serves dist/ over http with the jobs, pipeline and job
// detail reads stubbed, opens the real pages in chromium at 1280px and 375px,
// and asserts what the readability pass actually promised: body type is at
// least 15px, the small print (card meta, table cells, column heads) is no
// longer 9-11px, no card or row clips its own text, and 375px still has no
// horizontal body scroll.
//
// BH-4845: it runs in one theme per invocation (default mill, the fleet's code
// default), seeded through localStorage['ui.theme'] before the boot script
// reads it, and checks that theme's form on the rendered page: the title and
// body faces, panel and button radii, label case, and the running step's fill.
//
//   node tests/drive/density-drive.mjs [--theme mill|paper|phosphor] [--shots <dir>] [--tag before|after]
//
// Exit code is the verdict. Screenshots land in --shots (default ./shots).

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';
import { ROUTES } from './fixtures.mjs';
import { BUILTIN_THEMES } from '../../src/theme/themes.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../..');
const dist = path.join(root, 'dist');

const args = process.argv.slice(2);
const shotDir = path.resolve(args.includes('--shots') ? args[args.indexOf('--shots') + 1] : path.join(root, 'shots'));
const tag = args.includes('--tag') ? args[args.indexOf('--tag') + 1] : 'after';
// `before` runs against the OLD stylesheet on purpose: it only collects
// screenshots, so the size floors below must not fail it.
const strict = tag !== 'before';
const themeId = args.includes('--theme') ? args[args.indexOf('--theme') + 1] : 'mill';
const theme = BUILTIN_THEMES[themeId];
if (!theme) {
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

const JOB = 'build-project-3-TK-104-1';

const card = (id, ticket, project, stage, extra = {}) =>
  ({ id, project, ticket, ticket_key: ticket, bkey: ticket, stage, age_min: 12, tier: 2, ...extra });

const pipeline = {
  snapshot_age_min: 3,
  building_stale: 4,
  counts: { queued: 7, building: 3, merge_queue: 1, review: 2, merged_deployed: 5, dead_failed: 3 },
  columns: {
    queued: [
      { project: 'project-3', queue_depth: 5, oldest_queued_min: 51, pending_commands: 2 },
      { project: 'project-1', queue_depth: 2, oldest_queued_min: 12 }
    ],
    building: [
      card(101, 'TK-104', 'project-3', 'executing'),
      card(102, 'TK-593', 'project-1', 'planning'),
      card(103, 'AC-12', 'project-4', 'reviewing')
    ],
    merge_queue: [card(104, 'TK-9', 'project-5', 'merge_queued', { pr_url: 'https://github.com/example-org/project-5/pull/9' })],
    review: [
      card(105, 'TK-3', 'project-9', 'pr_created', { verdict: 'needs a human', pr_url: 'https://github.com/example-org/project-9/pull/3' }),
      card(106, 'BH-7', 'cromford', 'pr_created', { pr_url: 'https://github.com/example-org/cromford/pull/7' })
    ],
    merged_deployed: [
      card(107, 'TK-99', 'project-3', 'merged'),
      card(108, 'TK-580', 'project-1', 'deployed')
    ],
    dead_failed: [
      card(109, 'TK-70', 'project-3', 'failed', { verdict: 'typecheck failed three times in a row on the same file' }),
      { command_id: 44, ckey: 'project-4-AC-12-build', project: 'project-4', stage: 'dead_letter', age_min: 90 },
      card(110, 'TK-44', 'project-1', 'failed', { verdict: 'route answered 404 in prod' })
    ]
  }
};

// determinism: ok-file clock-now-js every fixture below is an offset from this one captured read, so the
// screenshot is the same picture on any day; nothing here is compared to a calendar literal.
const now = Math.floor(Date.now() / 1000);
const detail = {
  job: {
    id: JOB, project: 'project-3', kind: 'build', stage: 'execute', box: 'box-project-3-2',
    ticket_id: 'TK-104', status: 'running', budget_usd: 150, spent_usd: 4.12,
    created_at: '2026-08-29T09:00:00Z', updated_at: '2026-08-29T10:05:00Z',
    heartbeating: 1, beat_age_s: 40, activity_age_s: 40, started_at: now - 900
  },
  phases: [
    { id: 7, job_id: JOB, phase: 'plan', runner: 'fable', model: 'claude-fable-5', status: 'done', rc: 0, spend_usd: 0.4, started_at: '2026-08-29T09:58:00Z', finished_at: '2026-08-29T10:00:00Z' },
    { id: 8, job_id: JOB, phase: 'execute', runner: 'claude', model: 'claude-opus-5', status: 'running', spend_usd: 3.7, started_at: '2026-08-29T10:01:00Z' }
  ],
  transcripts: [
    { job_id: JOB, phase_id: 7, attempt: 1, stage: 'plan', runner: 'fable', model: 'claude-fable-5', source: 'session_jsonl', bytes: 48000, truncated: 0, redactions: 2, created_at: '2026-08-29T10:00:00Z' }
  ],
  events: [], ledgers: [], artifacts: [], as_of: '2026-08-29T10:06:00Z'
};

// /builds/:id: a build mid-pipeline whose ticket matches no job, so the stage
// strip follows the row (plan done, execute running) and no live feed is read.
const BUILD_ID = 101;
const buildDetail = {
  build: { id: BUILD_ID, project: 'project-3', ticket_key: 'QQ-1', bkey: 'QQ-1', stage: 'executing', tier: 2, merged: 0, verdict: null, pr_url: null, age_min: 12, detail: null },
  timeline: []
};

const EXTRA = {
  [`/api/dash/builds/${BUILD_ID}`]: buildDetail,
  '/api/dash/kanban/pipeline': pipeline,
  '/api/dash/tickets-snapshot': { projects: {}, generated_at: now },
  '/api/coord/burn': { days: [], projects: [], total_usd: 0 },
  '/api/coord/flags': { flags: [] },
  [`/api/coord/jobs/${JOB}`]: detail
};

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
  if (!ok && strict) fail.push(what);
};

const px = (page, sel, prop = 'fontSize') => page.locator(sel).first()
  .evaluate((el, p) => parseFloat(getComputedStyle(el)[p]), prop);
const css = (page, sel, prop) => page.locator(sel).first()
  .evaluate((el, p) => getComputedStyle(el)[p], prop);
const rgb = (hex) => {
  const h = hex.replace('#', '');
  return `rgb(${[0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16)).join(', ')})`;
};
const firstFace = (stack) => stack.split(',')[0].trim().replace(/^['"]|['"]$/g, '');

async function run() {
  if (!fs.existsSync(path.join(dist, 'index.html'))) {
    console.error('dist/ is not built — run `npm run build` first');
    process.exit(2);
  }
  fs.mkdirSync(shotDir, { recursive: true });
  await new Promise((r) => server.listen(0, r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch();

  for (const [name, width, height] of [['desktop', 1280, 900], ['mobile', 375, 780]]) {
    const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1 });
    await page.addInitScript((id) => { window.localStorage.setItem('ui.theme', id); }, themeId);
    const errors = [];
    page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
    page.on('pageerror', (e) => errors.push(String(e)));

    // ---- jobs (table + stat tiles) ----
    await page.goto(`${base}/jobs`, { waitUntil: 'networkidle' });
    await page.waitForSelector('table.tbl td', { timeout: 15000 });
    await page.screenshot({ path: path.join(shotDir, `${tag}-jobs-${name}.png`), fullPage: true });

    const body = await px(page, 'body');
    check(body >= 15, `${name}/jobs: body type is at least 15px (${body})`);
    const td = await px(page, 'table.tbl td');
    check(td >= 13, `${name}/jobs: table cells are at least 13px (${td})`);
    const th = await px(page, 'table.tbl th');
    check(th >= 12, `${name}/jobs: column heads are at least 12px (${th})`);
    const label = await px(page, '.stat__label');
    check(label >= 11, `${name}/jobs: stat labels are at least 11px (${label})`);
    // BH-4990: the fixture rows carry ticket_id, so "The line" draws rows and
    // the 375px check below measures a filled board, not its empty state.
    const lineRows = await page.locator('.board__list > li.ticketrow').count();
    check(lineRows > 0, `${name}/jobs: "The line" draws a row per ticket in flight (${lineRows})`);

    // ---- kanban (cards, incl. the DEAD column) ----
    await page.goto(`${base}/kanban`, { waitUntil: 'networkidle' });
    await page.waitForSelector('.card', { timeout: 15000 });
    await page.evaluate(() => document.fonts.ready);
    await page.screenshot({ path: path.join(shotDir, `${tag}-kanban-${name}.png`), fullPage: true });

    const key = await px(page, '.card__key');
    check(key >= 13, `${name}/kanban: card keys are at least 13px (${key})`);
    const cbody = await px(page, '.card__body');
    check(cbody >= 12, `${name}/kanban: card body text is at least 12px (${cbody})`);
    const foot = await px(page, '.card__foot');
    check(foot >= 11, `${name}/kanban: card footers are at least 11px (${foot})`);
    const title = await px(page, '.kb__title');
    check(title >= 12, `${name}/kanban: column heads are at least 12px (${title})`);
    check(await page.locator('.kb__title--red').innerText().then((t) => t.includes('DEAD')),
      `${name}/kanban: the DEAD column still renders`);

    // Bigger text inside a tighter box is only a win if nothing clips.
    const clipped = await page.$$eval('.card, .kb__head, .stat, .tile',
      (els) => els.filter((el) => el.scrollHeight > el.clientHeight + 1)
        .map((el) => el.className).slice(0, 5));
    check(clipped.length === 0, `${name}/kanban: no card or head clips its own text (${clipped.join(', ') || 'none'})`);

    // ---- job detail ----
    await page.goto(`${base}/jobs/${JOB}`, { waitUntil: 'networkidle' });
    await page.waitForSelector('.tr__head', { timeout: 15000 });
    await page.screenshot({ path: path.join(shotDir, `${tag}-job-${name}.png`), fullPage: true });
    const trTitle = await px(page, '.tr__title');
    check(trTitle >= 13, `${name}/job: transcript row titles are at least 13px (${trTitle})`);
    const meta = await px(page, '.tr__meta');
    check(meta >= 11, `${name}/job: the transcript meta line is at least 11px (${meta})`);
    const sect = await px(page, '.section__title');
    check(sect >= 12, `${name}/job: section headings are at least 12px (${sect})`);

    // ---- the theme's form (BH-4845) ----
    await page.goto(`${base}/builds/${BUILD_ID}`, { waitUntil: 'networkidle' });
    await page.waitForSelector('.build__bar span', { timeout: 15000 });
    await page.evaluate(() => document.fonts.ready);
    await page.screenshot({ path: path.join(shotDir, `${tag}-${themeId}-build-${name}.png`), fullPage: true });
    const S = theme.shape;
    const at = `${name}/${themeId}`;
    check(await page.evaluate(() => document.documentElement.getAttribute('data-theme')) === themeId,
      `${at}: the page is painted ${themeId}`);
    const titleFace = await css(page, '.page-title', 'fontFamily');
    check(firstFace(titleFace) === firstFace(S['--font-display']), `${at}: .page-title is ${firstFace(S['--font-display'])} (${titleFace})`);
    const stretch = await css(page, '.page-title', 'fontStretch');
    check(stretch === (S['--display-stretch'] === 'normal' ? '100%' : S['--display-stretch']), `${at}: .page-title stretch ${stretch}`);
    const bodyFace = await css(page, 'body', 'fontFamily');
    check(firstFace(bodyFace) === firstFace(S['--font-body']), `${at}: body is ${firstFace(S['--font-body'])} (${bodyFace})`);
    // A face counts once its own @font-face has loaded, not when check() finds nothing to load.
    const loaded = await page.evaluate((faces) => faces.map((f) => [...document.fonts]
      .some((ff) => ff.family.replace(/["']/g, '') === f && ff.status === 'loaded')),
      [S['--font-display'], S['--font-body'], S['--font-mono']].map(firstFace));
    check(loaded.every(Boolean), `${at}: the display, body and mono faces are loaded (${loaded.join(',')})`);
    const panelR = await px(page, '.panel', 'borderTopLeftRadius');
    check(panelR === parseFloat(S['--radius-md']), `${at}: .panel radius ${panelR}px = ${S['--radius-md']}`);
    if (themeId !== 'phosphor') check(panelR >= 10 && panelR <= 14, `${at}: .panel radius is within 10..14px`);
    const pillCase = await css(page, '.pill', 'textTransform');
    check(pillCase === S['--label-case'], `${at}: .pill text-transform ${pillCase}`);
    const pillFace = await css(page, '.pill', 'fontFamily');
    check(firstFace(pillFace) === firstFace(S['--font-mono']), `${at}: .pill is ${firstFace(S['--font-mono'])} (${pillFace})`);
    const btnR = await px(page, '.btn', 'borderTopLeftRadius');
    check(btnR === parseFloat(S['--radius-pill']), `${at}: .btn radius ${btnR}px = ${S['--radius-pill']}`);
    if (themeId !== 'phosphor') check(btnR >= 999, `${at}: .btn is a pill`);
    const shadow = await css(page, '.page-title', 'textShadow');
    check((S['--title-shadow'] === 'none') === (shadow === 'none'), `${at}: .page-title shadow ${shadow}`);
    const fills = await page.$$eval('.build__bar span', (els) => els.map((el) => getComputedStyle(el).backgroundColor));
    check(fills[1] === rgb(theme.tokens['--live']), `${at}: the running step is --live ${theme.tokens['--live']} (${fills[1]})`);
    check(fills[0] !== fills[1], `${at}: the done step is not the running colour (${fills[0]})`);
    const onInk = await css(page, '.build__stages .on', 'color');
    check(onInk === rgb(theme.tokens['--live-text']), `${at}: the running step label is --live-text (${onInk})`);

    // html/body carry overflow-x: hidden, so documentElement.scrollWidth always
    // reads clean — it CLIPS an overflow rather than reporting it. The honest
    // measure is the widest box actually laid out.
    for (const [route, what] of [['/jobs', 'jobs'], ['/kanban', 'kanban'], [`/jobs/${JOB}`, 'job'], [`/builds/${BUILD_ID}`, 'build']]) {
      await page.goto(`${base}${route}`, { waitUntil: 'networkidle' });
      await page.evaluate(() => document.fonts.ready);
      await page.waitForTimeout(300);
      const over = await page.evaluate((vw) => {
        let worst = 0;
        for (const el of document.querySelectorAll('body *')) {
          // .tablewrap and .topbar__nav scroll INSIDE their own box on purpose,
          // and so does .track-scroll (BH-4990: a compact station track is
          // 520px wide and scrolls inside its line row on a phone).
          if (el.closest('.tablewrap, .topbar__nav, .bottomnav, .term, .track-scroll')) continue;
          worst = Math.max(worst, Math.round(el.getBoundingClientRect().right) - vw);
        }
        return worst;
      }, width);
      check(over <= 1, `${width}px/${what}: nothing is laid out past the viewport (${over}px over)`);
      // The exclusions above trust each inner scroller to clip its content.
      // This proves it: the page itself never scrolls sideways.
      const sw = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
      check(sw <= 0, `${width}px/${what}: the page does not scroll sideways (scrollWidth is ${sw}px past innerWidth)`);
    }

    check(errors.length === 0, `${name}: console stays clean (${errors.slice(0, 2).join(' | ') || 'clean'})`);
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
