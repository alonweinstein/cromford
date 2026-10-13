// Headless drive of the BUILT bundle's job drill-down at 375px and 1280px,
// focused on the TRANSCRIPT section.
//
// Not a unit test. It serves dist/ over http with the job detail and one
// transcript body stubbed, opens the real page in chromium, and asserts what a
// person would check by hand: the section renders collapsed, opening a row
// actually fetches ONE body (and only then), the text lands in a monospace
// pane, the honest empty state appears when there is nothing on file, and at
// 375px the page has no horizontal body scroll.
//
// The fixtures are the point of honesty: this box cannot reach the live
// console's authed reads, so the drive proves the SCREEN, not the data.
//
//   node tests/drive/job-drive.mjs [--shots <dir>] [--scale 1|2]
//
// Exit code is the verdict. Screenshots land in --shots (default ./shots).

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
const scale = args.includes('--scale') ? Number(args[args.indexOf('--scale') + 1]) : 1;

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

const JOB_WITH = 'build-project-3-TK-1-1';
const JOB_WITHOUT = 'merge-sweep-1';

// A body long enough to scroll, with a shell command long enough to test the
// 375px overflow rule — a real transcript is full of both.
const BODY = [
  '── transcript · execute · attempt 2 ──',
  'runner: claude   model: claude-opus-5   source: session_jsonl',
  'redactions: 2 (bin/transcript-scrub.sh)',
  '────────────────────────────────────────────────',
  '',
  '[10:00:01] USER',
  'Execute the plan for TK-1 on the current branch. Do not merge.',
  '',
  '[10:00:02] ASSISTANT (claude-opus-5)',
  '  · [thinking]',
  '  → Bash: cd /root/repos/project-3 && npm run build -- --mode production --no-cache && npx tsc -p tsconfig.build.json --noEmit',
  '  ← built in 12.4s ⏎ no type errors',
  '  → Read: /root/repos/project-3/src/app/(app)/finance/page.tsx',
  '',
  '[10:00:44] ASSISTANT (claude-opus-5)',
  'The header token was [REDACTED], so I read it from the env file instead.',
  ...Array.from({ length: 60 }, (_, i) => `  → Bash: git log --oneline -${i + 1}`),
  '',
  '[10:03:10] ASSISTANT (claude-opus-5)',
  'Done. Build is green and the suite passes.'
].join('\n');

const DETAIL = {
  job: {
    id: JOB_WITH, project: 'project-3', kind: 'build', stage: 'execute', box: 'box-project-3-2',
    ticket_id: 'TK-1', status: 'done', budget_usd: 150, spent_usd: 4.12,
    created_at: '2026-08-29T09:00:00Z', updated_at: '2026-08-29T10:05:00Z',
    heartbeating: true, beat_age_s: 40, activity_age_s: 40
  },
  phases: [
    { id: 7, job_id: JOB_WITH, phase: 'execute', runner: 'claude', model: 'claude-opus-5', status: 'failed', rc: 1, spend_usd: 0.4, started_at: '2026-08-29T09:58:00Z', finished_at: '2026-08-29T10:00:00Z' },
    { id: 8, job_id: JOB_WITH, phase: 'review', runner: 'claude', model: 'claude-opus-5', status: 'done', rc: 0, spend_usd: 1.2, started_at: '2026-08-29T10:01:00Z', finished_at: '2026-08-29T10:05:00Z' }
  ],
  transcripts: [
    { job_id: JOB_WITH, phase_id: 7, attempt: 1, stage: 'execute', runner: 'claude', model: 'claude-opus-5', source: 'session_jsonl', bytes: 48000, truncated: 0, redactions: 2, created_at: '2026-08-29T10:00:00Z' },
    { job_id: JOB_WITH, phase_id: 7, attempt: 2, stage: 'execute', runner: 'codex', model: 'gpt-x', source: 'stage_output', bytes: 900, truncated: 0, redactions: 0, created_at: '2026-08-29T10:00:30Z' },
    { job_id: JOB_WITH, phase_id: 8, attempt: 1, stage: 'review', runner: 'claude', model: 'claude-opus-5', source: 'session_jsonl', bytes: 150000, truncated: 1, redactions: 0, created_at: '2026-08-29T10:05:00Z' }
  ],
  events: [], ledgers: [], artifacts: [], as_of: '2026-08-29T10:06:00Z'
};

const EMPTY_DETAIL = {
  job: { id: JOB_WITHOUT, project: 'orchestrator', kind: 'merge', stage: 'sweep', box: 'hub', status: 'done', created_at: '2026-08-29T09:00:00Z', updated_at: '2026-08-29T09:01:00Z' },
  phases: [], transcripts: [], events: [], ledgers: [], artifacts: [], as_of: '2026-08-29T10:06:00Z'
};

let bodyCalls = 0;
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const p = url.pathname;
  if (p.startsWith('/api/')) {
    let body = {};
    if (p === `/api/coord/jobs/${JOB_WITH}/transcript`) {
      bodyCalls += 1;
      body = { transcript: { ...DETAIL.transcripts[0], body: BODY } };
    } else if (p === `/api/coord/jobs/${JOB_WITH}`) body = DETAIL;
    else if (p === `/api/coord/jobs/${JOB_WITHOUT}`) body = EMPTY_DETAIL;
    res.writeHead(200, { 'content-type': 'application/json' });
    return res.end(JSON.stringify(body));
  }
  let file = path.join(dist, p === '/' ? 'index.html' : p.slice(1));
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

  for (const [name, width, height] of [['mobile', 375, 780], ['desktop', 1280, 900]]) {
    bodyCalls = 0;
    const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: scale });
    const errors = [];
    page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
    page.on('pageerror', (e) => errors.push(String(e)));
    // A drill-down is a READ. If it ever POSTs, that is a contract break.
    const writes = [];
    page.on('request', (r) => {
      const u = new URL(r.url());
      if (r.method() !== 'GET' && u.pathname.startsWith('/api/')) writes.push(`${r.method()} ${u.pathname}`);
    });

    await page.goto(`${base}/jobs/${JOB_WITH}`, { waitUntil: 'networkidle' });
    await page.waitForSelector('.tr__head', { timeout: 15000 });

    check(await page.locator('.tr').count() === 3, `${name}: one row per attempt on file`);
    check(bodyCalls === 0, `${name}: nothing is fetched until a row is opened (${bodyCalls} body calls)`);
    check(await page.locator('.term--transcript').count() === 0, `${name}: every row starts collapsed`);
    check((await page.locator('.tr__head').first().getAttribute('aria-expanded')) === 'false',
      `${name}: the collapsed state is announced, not just drawn`);

    const heads = await page.locator('.tr__title').allTextContents();
    check(heads.join('|').includes('EXECUTE · attempt 1') && heads.join('|').includes('EXECUTE · attempt 2'),
      `${name}: a failed-over stage names each attempt (${heads.join(' / ')})`);
    check(heads.includes('REVIEW'), `${name}: a stage that ran once does not advertise "attempt 1"`);
    const metas = (await page.locator('.tr__meta').allTextContents()).join(' | ');
    check(metas.includes('TAIL ONLY'), `${name}: a tailed transcript says so before you open it`);
    check(metas.includes('final output only'), `${name}: a non-claude attempt does not pose as a full session`);
    check(metas.includes('2 values redacted'), `${name}: the redaction count is on the row`);

    await page.locator('.tr__head').first().click();
    await page.waitForSelector('.term--transcript', { timeout: 10000 });
    check(bodyCalls === 1, `${name}: opening ONE row fetched exactly one body (${bodyCalls})`);
    const text = await page.locator('.term--transcript').first().innerText();
    check(text.includes('Execute the plan for TK-1'), `${name}: the conversation renders`);
    check(text.includes('→ Bash:'), `${name}: tool calls render as one line each`);
    check(text.includes('[REDACTED]'), `${name}: the scrubber's marker survives to the screen`);
    const mono = await page.locator('.term--transcript').first()
      .evaluate((el) => getComputedStyle(el).fontFamily.toLowerCase());
    check(/mono/.test(mono), `${name}: the pane is monospace (${mono.slice(0, 40)})`);
    check(await page.locator('.tr__note').first().innerText()
      .then((t) => t.includes('turn by turn')), `${name}: the pane says what kind of record it is`);

    // NO HORIZONTAL BODY SCROLL. The long shell command lives inside the <pre>,
    // which has its own overflow — the page itself must not move sideways.
    const overflow = await page.evaluate(() => ({
      doc: document.documentElement.scrollWidth - document.documentElement.clientWidth,
      pre: (() => { const p = document.querySelector('.term--transcript'); return p ? p.scrollWidth - p.clientWidth : 0; })()
    }));
    check(overflow.doc <= 1, `${name}: no horizontal body scroll (${overflow.doc}px)`);

    await page.screenshot({ path: path.join(shotDir, `job-transcript-${name}-open.png`), fullPage: false });

    await page.locator('.tr__head').first().click();
    await page.waitForTimeout(150);
    check(await page.locator('.term--transcript').count() === 0, `${name}: a row collapses again`);
    await page.locator('.tr__head').first().click();
    await page.waitForSelector('.term--transcript', { timeout: 10000 });
    check(bodyCalls === 1, `${name}: re-opening a row does not re-fetch it (${bodyCalls})`);

    // The honest empty state, on a coordination claim that was never going to
    // have a transcript.
    await page.goto(`${base}/jobs/${JOB_WITHOUT}`, { waitUntil: 'networkidle' });
    await page.waitForSelector('.empty__title', { timeout: 15000 });
    const empty = await page.locator('.empty').filter({ hasText: 'NO TRANSCRIPT PUSHED' }).first().innerText();
    check(/never call a model|no model session/i.test(empty), `${name}: the empty state says WHY, not just "none"`);
    check(/merge-sweep/.test(empty), `${name}: the empty state names the coordination lanes`);
    await page.screenshot({ path: path.join(shotDir, `job-transcript-${name}-empty.png`), fullPage: false });

    check(writes.length === 0, `${name}: writes nothing${writes.length ? ` — ${writes.join(', ')}` : ''}`);
    check(errors.length === 0, `${name}: console stays clean${errors.length ? ` — ${errors.slice(0, 2).join(' | ')}` : ''}`);
    await page.close();
  }

  await browser.close();
  server.close();
  console.log(fail.length ? `\n${fail.length} FAILED` : '\nall checks passed');
  process.exit(fail.length ? 1 : 0);
}

run().catch((e) => { console.error(e); process.exit(2); });
