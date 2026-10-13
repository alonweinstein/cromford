// Headless drive of the BUILT bundle's /outcomes screen at 375px and 1280px.
//
// Not a unit test: this serves dist/ over http with /api/outcomes/summary
// stubbed, opens the real page in chromium, and asserts what a person would
// check by hand and what no unit test can see — that a phone-width viewport
// does not scroll sideways, that every wide table scrolls inside its own box
// instead of dragging the body with it, that the headers actually sort, and
// that the screen writes nothing.
//
// The fixture is the point of honesty: this box cannot reach the live console's
// authed reads, so the drive proves the SCREEN, not the data.
//
//   npm run build && npm run drive:outcomes
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';

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

// determinism: ok-file clock-now-js clock-new-date every row is an offset from now (iso(), burnDays)
// and as_of is only rendered — the drive asserts shapes, never a date.
const iso = (daysAgo) => new Date(Date.now() - daysAgo * 86400000).toISOString();
const PR = (repo, n) => `https://github.com/${repo}/pull/${n}`;
const REPOS = ['example-org/project-3', 'example-org/project-2', 'example-org/project-4'];

const merges = [];
const prCosts = [];
REPOS.forEach((repo, ri) => {
  for (let n = 1; n <= 9; n++) {
    merges.push({ kind: 'merge', key: PR(repo, n), status: 'merged', job_id: `build-${ri}-${n}`, created_at: iso(n % 12), updated_at: iso(n % 12) });
    prCosts.push({ pr_url: PR(repo, n), cost_usd: 3 + n * 1.7 + ri * 4, stage_breakdown: 'plan:1.20;execute:8.40;review:1.10' });
  }
});
const burnDays = Array.from({ length: 40 }, (_, i) => {
  const d = new Date(Date.now() - i * 86400000).toISOString().slice(0, 10);
  return { day: d, usd_equiv: 80 + (i % 9) * 12, output: 400000, api_calls: 420, peak_cache_read: 65858, cache_read: 1, cache_write: 1 };
});

const SUMMARY = {
  as_of: new Date().toISOString(),
  degraded: [],
  outcomes: [
    { repo: REPOS[0], pr: PR(REPOS[0], 1), outcome: 'reverted', day: iso(2).slice(0, 10), evidence: 'merged and then reverted on main by 9f2c1ab0d3e1 — the revert names this PR (#1)' },
    { repo: REPOS[0], pr: PR(REPOS[0], 1), outcome: 'reopened', day: iso(1).slice(0, 10), evidence: 'ticket TK-118 regressed from "done" to "in progress"' },
    { repo: REPOS[0], pr: PR(REPOS[0], 4), outcome: 'reverted', day: iso(3).slice(0, 10), evidence: 'the revert touches files this PR changed (src/app/page.tsx)' },
    { repo: REPOS[1], pr: PR(REPOS[1], 2), outcome: 'merged_then_red', day: iso(4).slice(0, 10), evidence: 'merged green and main went red: aa11bb22cc33 failed Typecheck' }
  ],
  merges,
  pr_costs: prCosts,
  burn_days: burnDays,
  gates: [
    { repo: REPOS[0], tightened: 1, rate: 0.2222, bad: 2, merges: 9, window_days: 14, tighten_rate: 0.2, clear_rate: 0.1, min_merges: 5, threshold_scope: '*', decision: 'tighten', evidence: '2 of 9 PRs merged in the last 14d were reverted or reopened (22%); 0 also turned main red', updated_at: iso(0.2) },
    { repo: REPOS[1], tightened: 0, rate: 0, bad: 0, merges: 9, window_days: 14, tighten_rate: 0.2, clear_rate: 0.1, min_merges: 5, threshold_scope: '*', decision: 'clear', evidence: '0 of 9 PRs merged in the last 14d were reverted or reopened (0%)', updated_at: iso(0.2) }
  ],
  thresholds: [{ scope: '*', window_days: 14, min_merges: 5, tighten_rate: 0.2, clear_rate: 0.1 }]
};

let authed = true;
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  if (url.pathname.startsWith('/api/')) {
    if (!authed) {
      res.writeHead(403, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ error: 'unauthorized' }));
    }
    const body = url.pathname === '/api/outcomes/summary' ? SUMMARY : {};
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
  const browser = await chromium.launch();

  for (const [name, width, height] of [['mobile', 375, 820], ['desktop', 1280, 900]]) {
    const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1 });
    const errors = [];
    const writes = [];
    page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
    page.on('pageerror', (e) => errors.push(String(e)));
    page.on('request', (r) => {
      if (r.method() !== 'GET' && new URL(r.url()).pathname.startsWith('/api/')) {
        writes.push(`${r.method()} ${new URL(r.url()).pathname}`);
      }
    });

    await page.goto(`${base}/outcomes`, { waitUntil: 'networkidle' });
    await page.waitForSelector('table.tbl', { timeout: 15000 });

    // ONE call. The whole reason the Pages Function fans out server-side is
    // that five browser polls can land in five different seconds.
    const reads = await page.evaluate(() => performance.getEntriesByType('resource')
      .map((e) => new URL(e.name).pathname).filter((p) => p.startsWith('/api/')));
    const extra = [...new Set(reads)].filter((p) => p !== '/api/outcomes/summary' && p !== '/api/dash/fleet');
    check(extra.length === 0, `${name}: reads only its own summary${extra.length ? ` — also called ${extra.join(', ')}` : ''}`);
    check(writes.length === 0, `${name}: writes nothing${writes.length ? ` — ${writes.join(', ')}` : ''}`);

    // The body must not scroll sideways. A wide table is allowed to scroll —
    // INSIDE its own .tablewrap, which is the rule the whole console holds to.
    const overflow = await page.evaluate(() => ({
      body: document.documentElement.scrollWidth - document.documentElement.clientWidth,
      loose: [...document.querySelectorAll('table.tbl')].filter((t) => !t.closest('.tablewrap')).length,
      wraps: document.querySelectorAll('.tablewrap').length
    }));
    check(overflow.body <= 0, `${name}: no horizontal body scroll (overflow ${overflow.body}px)`);
    check(overflow.loose === 0, `${name}: every table sits inside a .tablewrap that scrolls on its own`);
    check(overflow.wraps >= 5, `${name}: all five tables rendered (${overflow.wraps})`);

    // Every header sorts, and says so to a screen reader.
    const sort = await page.evaluate(() => {
      const th = [...document.querySelectorAll('table.tbl thead th')];
      return {
        total: th.length,
        sortable: th.filter((h) => h.querySelector('button')).length,
        aria: th.filter((h) => h.getAttribute('aria-sort')).length
      };
    });
    check(sort.sortable >= sort.total - 6, `${name}: ${sort.sortable} of ${sort.total} headers sort (the rest are free text, deliberately)`);
    check(sort.aria >= sort.sortable, `${name}: sortable headers carry aria-sort`);

    const before = await page.$eval('table.tbl tbody tr td', (td) => td.textContent.trim());
    await page.click('table.tbl thead th button');
    await page.waitForTimeout(120);
    const dir = await page.$eval('table.tbl thead th', (th) => th.getAttribute('aria-sort'));
    await page.click('table.tbl thead th button');
    await page.waitForTimeout(120);
    const dir2 = await page.$eval('table.tbl thead th', (th) => th.getAttribute('aria-sort'));
    check(dir !== dir2 && ['ascending', 'descending'].includes(dir2),
      `${name}: a second click flips the direction (${dir} -> ${dir2})`);
    const after = await page.$eval('table.tbl tbody tr td', (td) => td.textContent.trim());
    check(typeof before === 'string' && typeof after === 'string', `${name}: rows survive a sort`);

    // Every identity cell goes somewhere: no dead rows. `.na` is an honest
    // "we do not know", and `[data-flat]` is a cell the screen deliberately
    // does not link and says why in the attribute — anything else that is text
    // with nowhere to go is the oversight this check exists to catch.
    const dead = await page.evaluate(() => {
      const cells = [...document.querySelectorAll('table.tbl tbody tr td:first-child')];
      return cells
        .filter((c) => c.textContent.trim())
        .filter((c) => !c.querySelector('a, .na, [data-flat]'))
        .length;
    });
    check(dead === 0, `${name}: no dead identity cells (${dead})`);

    // Touch targets. A 44px minimum is the rule the rest of this UI holds to.
    if (name === 'mobile') {
      const small = await page.evaluate(() => [...document.querySelectorAll('.bottomnav a')]
        .filter((a) => a.getBoundingClientRect().height < 44).length);
      check(small === 0, `${name}: every bottom-nav tab is at least 44px tall (${small} short)`);
      const navRows = await page.evaluate(() => {
        const tops = new Set([...document.querySelectorAll('.bottomnav a')].map((a) => Math.round(a.getBoundingClientRect().top)));
        return tops.size;
      });
      check(navRows === 1, `${name}: the bottom nav stays ONE row with the tenth tab (${navRows})`);
    }

    check(errors.length === 0, `${name}: console is clean${errors.length ? ` — ${errors.slice(0, 2).join(' | ')}` : ''}`);
    await page.screenshot({ path: path.join(shotDir, `outcomes-${name}.png`), fullPage: true });
    await page.close();
  }

  // Signed out is a refusal that says what to do, not a blank screen.
  authed = false;
  const out = await browser.newPage({ viewport: { width: 375, height: 820 } });
  await out.goto(`${base}/outcomes`, { waitUntil: 'networkidle' });
  await out.waitForTimeout(400);
  const text = await out.evaluate(() => document.body.innerText);
  check(/NOT SIGNED IN/i.test(text), 'signed out: the 403 renders the login instruction, not an empty table');
  await out.close();

  await browser.close();
  server.close();
  console.log(fail.length ? `\nFAILED: ${fail.length}` : `\nall good — shots in ${shotDir}`);
  process.exit(fail.length ? 1 : 0);
}

run().catch((e) => { console.error(e); process.exit(1); });
