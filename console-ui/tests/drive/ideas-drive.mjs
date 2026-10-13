// Headless drive of the BUILT bundle's /ideas screen at 1280px and 375px.
//
// Not a unit test. It serves dist/ over http with /api/ideas/proposals stubbed,
// opens the real page in chromium and measures the thing the width pass is
// about: how much of the page the proposals table occupies, how wide the IDEA
// column ends up, and how many titles are still cut off. The 375px half
// re-checks the standing mobile rule — the body never scrolls sideways, the
// wide table scrolls inside its own box — and /jobs is visited at the end to
// prove the OTHER tables still hug their content.
//
//   npm run build && npm run drive:ideas [--shots <dir>] [--tag before|after]
//
// Exit code is the verdict. `--tag before` only collects screenshots, so the
// floors below do not fail the run against the old stylesheet.
//
// The fixture is where the honesty is: this box cannot reach the live console's
// authed D1 reads, so the drive proves the SCREEN, not the board. The exact
// percentages move with the row mix — the live board's rows are sparser than
// these, so it has MORE free space to hand the title column, not less.

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
const tag = args.includes('--tag') ? args[args.indexOf('--tag') + 1] : 'after';
const strict = tag !== 'before';

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

// determinism: ok-file clock-now-js clock-new-date fixtures are offsets from now through iso(), and
// generated_at is only rendered — no assertion here compares against a calendar literal.
const iso = (minsAgo) => new Date(Date.now() - minsAgo * 60000).toISOString();

// A weekly product run as it actually lands: the ledger's own status vocabulary
// (src/lib/ideas.js), titles that are SENTENCES rather than labels, and the
// sparse tail that is most of the table — most candidates never get a PRD, a
// mockup or a ticket, so those columns are mostly an em dash. One row carries
// each of the MOCKUP column's three states: a board link, shots only, nothing. That sparseness
// is the whole reason the table had free space to leave unused.
const IDEA = (i, over) => ({
  pkey: `prop:${over.project}:idea-${i}`,
  slug: `idea-${i}`,
  impact: 4, effort: 2, confidence: 3,
  dus_why: 'the bucket SYNTH argued for',
  mockup_url: null, rev: 1, department: null,
  has_prd: 0, shots: 0, chat_turns: 0, ticket_key: null,
  created_at: iso(60 * 24 * (i + 3)),
  updated_at: iso(60 * (i + 1) * 9),
  summary: `${over.title} — the product stage's one-paragraph read on why this is worth a build wave.`,
  ...over
});

const IDEAS = {
  proposals: [
    IDEA(0, {
      project: 'project-3', status: 'gate_pending', score: 74, department: 'ops', dus: 'unclog',
      title: 'Let a rep resend a client invitation without re-creating the membership',
      has_prd: 1, shots: 1
    }),
    IDEA(1, {
      project: 'project-1', status: 'candidate', score: 71, dus: 'derisk',
      title: 'Offboarding checklist that blocks the final invoice until it is done'
    }),
    IDEA(2, {
      project: 'project-2', status: 'candidate', score: 63, dus: 'scale',
      title: 'Surface the project-2 projection assumptions a client edited since the last review'
    }),
    IDEA(3, {
      project: 'project-4', status: 'candidate', score: 58, dus: 'unclog',
      title: 'One-click revert for a build wave that regressed prod'
    }),
    IDEA(4, {
      project: 'project-3', status: 'candidate', score: 55, dus: 'scale',
      title: 'A single place to see which boxes are idle and why'
    }),
    IDEA(5, {
      project: 'project-1', status: 'posted', score: 52, dus: 'derisk',
      title: 'Weekly digest of every engagement that lost a renewal signal', ticket_key: 'TK-593',
      // The one row that reached the client's board: post-proposal.sh writes the
      // viewer link back, so this is the shape the MOCKUP column's OPEN link is
      // rendered from. Only a posted proposal has one.
      mockup_url: 'https://example.invalid/board/mockups/TK-593', shots: 2
    }),
    IDEA(6, {
      project: 'project-2', status: 'candidate', score: 49, dus: 'unclog',
      title: 'Show the cost of a PR next to the PR, not in a separate dashboard'
    }),
    IDEA(7, {
      project: 'project-4', status: 'candidate', score: 31, dus: 'scale',
      title: 'Retire the manual spreadsheet the ops team keeps for lead tier bands'
    })
  ],
  truncated: false,
  generated_at: new Date().toISOString()
};

const EXTRA = { '/api/ideas/proposals': IDEAS };

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

// The wrap measured against the width the page actually has for it.
const geometry = (page) => page.evaluate(() => {
  const wrap = document.querySelector('.tablewrap');
  const pg = document.querySelector('.page');
  const cs = getComputedStyle(pg);
  const avail = pg.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight);
  return { table: Math.round(wrap.getBoundingClientRect().width), avail: Math.round(avail) };
});

const TITLE_CELLS = 'table.tbl tbody tr td.col-flex .cell-wrap, table.tbl tbody tr td:nth-child(2) .cell-wrap';
const TITLE_CELL = 'table.tbl tbody tr td.col-flex, table.tbl tbody tr td:nth-child(2)';

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
    const errors = [];
    page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
    page.on('pageerror', (e) => errors.push(String(e)));

    await page.goto(`${base}/ideas`, { waitUntil: 'networkidle' });
    await page.waitForSelector('table.tbl td', { timeout: 15000 });
    await page.waitForTimeout(200);
    await page.screenshot({ path: path.join(shotDir, `${tag}-ideas-${name}.png`), fullPage: true });

    const geom = await geometry(page);
    const pct = Math.round((geom.table / geom.avail) * 100);
    const cols = await page.$$eval('table.tbl thead th',
      (els) => els.map((el) => `${el.textContent.trim().replace(/[↑↓]/g, '')}:${Math.round(el.getBoundingClientRect().width)}`));
    console.log(`     ${name}: table ${geom.table}px of ${geom.avail}px available (${pct}%) — ${cols.join(' ')}`);

    // scrollWidth > clientWidth is the honest read of "this cell is truncating".
    const titles = await page.$$eval(TITLE_CELLS, (els) => els.map((el) => ({
      len: el.textContent.trim().length,
      w: Math.round(el.getBoundingClientRect().width),
      clipped: el.scrollWidth > el.clientWidth + 1
    })));
    const ideaW = Math.max(...titles.map((c) => c.w));
    const clipped = titles.filter((c) => c.clipped).length;
    console.log(`     ${name}: IDEA column ${ideaW}px, ${clipped}/${titles.length} titles truncating`);

    if (name === 'desktop') {
      // The ask: the free space goes to the table instead of sitting in the margin.
      check(pct >= 99, `1280px: the proposals table uses the page width (${pct}% of ${geom.avail}px)`);
      // ...and specifically to the IDEA column, which must end up the widest one.
      const widest = await page.$$eval('table.tbl thead th',
        (els) => els.map((el) => [el.textContent.trim(), el.getBoundingClientRect().width])
          .sort((a, b) => b[1] - a[1])[0][0]);
      check(widest.startsWith('IDEA'), `1280px: IDEA is the widest column (${widest.replace(/\s+/g, ' ')})`);
      // The old 44ch cap pinned this cell at 352px whatever the page had spare.
      // With all nine columns carrying content there is not much spare at
      // 1280px — the filtered pass below is where the slack actually shows.
      check(ideaW > 352, `1280px: the IDEA column clears the old 44ch/352px cap (${ideaW}px)`);
      // The flex column is the one that gives way; nothing else may clip.
      const otherClipped = await page.$$eval('table.tbl tbody td:not(.col-flex)',
        (els) => els.filter((el) => el.scrollWidth > el.clientWidth + 1).length);
      check(otherClipped === 0, `1280px: only the IDEA column truncates (${otherClipped} other cells clipped)`);
      // ...and nothing else is squeezed to its minimum either: a pill or a
      // project name broken over two lines is the failure mode of handing one
      // column the leftover space. More than one client rect = it wrapped.
      // (:nth-child(2) is the IDEA column itself — excluded by position as well
      // as by class, so this reads the same against the pre-change bundle.)
      const wrapped = await page.$$eval('table.tbl tbody td:not(.col-flex):not(:nth-child(2)) *',
        (els) => els.filter((el) => el.getClientRects().length > 1)
          .map((el) => el.textContent.trim().slice(0, 14)));
      check(wrapped.length === 0, `1280px: no other column is squeezed into wrapping (${wrapped.slice(0, 4).join(', ') || 'none'})`);
      // Same failure by another route: a squeezed cell whose tag GROUP stacks
      // instead of wrapping its text. Uniform row heights is the honest tell.
      const heights = await page.$$eval('table.tbl tbody tr', (els) => els.map((el) => Math.round(el.getBoundingClientRect().height)));
      const spread = Math.max(...heights) - Math.min(...heights);
      check(spread <= 2, `1280px: every row stays one line tall (${Math.min(...heights)}–${Math.max(...heights)}px)`);
      // Everything fits: the columns were handed the width, not overflowed into a scroll.
      const wrapScrolls = await page.$eval('.tablewrap', (el) => el.scrollWidth > el.clientWidth + 1);
      check(!wrapScrolls, '1280px: the table fits its wrap (no inner scroll at desktop width)');
    }

    // The sparse view is the one the operator is looking at: filter to CANDIDATE and
    // most columns collapse to an em dash, which is exactly when the old
    // fit-content wrap left half the page empty while the titles were cut.
    if (name === 'desktop') {
      await page.goto(`${base}/ideas?status=candidate`, { waitUntil: 'networkidle' });
      await page.waitForSelector('table.tbl td', { timeout: 15000 });
      await page.waitForTimeout(200);
      await page.screenshot({ path: path.join(shotDir, `${tag}-ideas-candidates-desktop.png`), fullPage: true });
      const fg = await geometry(page);
      const fpct = Math.round((fg.table / fg.avail) * 100);
      const ftitles = await page.$$eval(TITLE_CELLS, (els) => els.map((el) => ({
        w: Math.round(el.getBoundingClientRect().width),
        clipped: el.scrollWidth > el.clientWidth + 1
      })));
      const fIdeaW = Math.max(...ftitles.map((c) => c.w));
      const fClipped = ftitles.filter((c) => c.clipped).length;
      console.log(`     filtered: table ${fg.table}px of ${fg.avail}px (${fpct}%), IDEA ${fIdeaW}px, ${fClipped}/${ftitles.length} truncating`);
      check(fpct >= 99, `1280px/candidates: the sparse view fills the page too (${fpct}%)`);
      check(fIdeaW >= 480, `1280px/candidates: the IDEA column takes the slack (${fIdeaW}px vs the old 352px)`);
      // The column heads themselves (DRAFTED, BUCKET, TICKET) hold a floor under
      // the em-dash columns, so 1280px cannot give a 76-char title the ~800px it
      // wants. What it CAN do is stop cutting every single one of them.
      check(fClipped < ftitles.length,
        `1280px/candidates: titles are no longer cut across the board (${fClipped}/${ftitles.length} still truncating)`);
      await page.goto(`${base}/ideas`, { waitUntil: 'networkidle' });
      await page.waitForSelector('table.tbl td', { timeout: 15000 });
    }

    if (name === 'mobile') {
      // 375px policy is unchanged: the wide table scrolls inside its own box.
      const wrapScrolls = await page.$eval('.tablewrap', (el) => el.scrollWidth > el.clientWidth + 1);
      check(wrapScrolls, '375px: the wide table scrolls inside its own container');
      check(geom.table <= 375, `375px: the wrap itself stays inside the viewport (${geom.table}px)`);
      // Inside that scrolling box the title column still has to be readable —
      // the flex column must not be the one that collapses when the table is
      // already at its 720px minimum.
      check(ideaW >= 300, `375px: the IDEA column keeps a readable floor (${ideaW}px)`);
    }

    // html/body carry overflow-x: hidden, so documentElement.scrollWidth reads
    // clean whatever happens. The honest measure is the widest laid-out box.
    const over = await page.evaluate((vw) => {
      let worst = 0;
      for (const el of document.querySelectorAll('body *')) {
        if (el.closest('.tablewrap, .topbar__nav, .bottomnav, .term')) continue;
        worst = Math.max(worst, Math.round(el.getBoundingClientRect().right) - vw);
      }
      return worst;
    }, width);
    check(over <= 1, `${width}px/ideas: nothing is laid out past the viewport (${over}px over)`);

    // Sorting is the shared table's contract; a width change must not cost it.
    const head = page.locator('table.tbl th button', { hasText: 'IDEA' }).first();
    await head.click();
    await page.waitForTimeout(120);
    const asc = await page.$eval(TITLE_CELL, (el) => el.textContent.trim());
    await head.click();
    await page.waitForTimeout(120);
    const desc = await page.$eval(TITLE_CELL, (el) => el.textContent.trim());
    check(asc !== desc, `${name}: the IDEA header still sorts both ways (${asc.slice(0, 16)}… / ${desc.slice(0, 16)}…)`);

    // The narrowing the density pass bought is opted OUT of here, not undone:
    // /jobs still hugs its content on the same viewport.
    if (name === 'desktop') {
      await page.goto(`${base}/jobs`, { waitUntil: 'networkidle' });
      await page.waitForSelector('table.tbl td', { timeout: 15000 });
      const jobsWide = await page.$eval('.tablewrap', (el) => el.classList.contains('tablewrap--wide'));
      check(!jobsWide, '1280px/jobs: the jobs table did NOT opt into the wide rule');
      const flexCells = await page.$$eval('td.col-flex', (els) => els.length);
      check(flexCells === 0, `1280px/jobs: no column flexes there either (${flexCells} flex cells)`);
      // Informational: what the jobs table does at this width is whatever the
      // density pass left it doing. This drive only proves we did not change it.
      const jg = await geometry(page);
      console.log(`     jobs: table ${jg.table}px of ${jg.avail}px available (${Math.round((jg.table / jg.avail) * 100)}%)`);
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
