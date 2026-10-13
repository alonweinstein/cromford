import test from 'node:test';
import assert from 'node:assert/strict';
import { h } from 'preact';

// BH-3569 (BH-3558.2): /kanban, /merge-queue and the /runs, /builds, /pr
// drill-downs read in words. Every screen render goes through both legibility
// helpers, and a Legend term is checked as visible text (attributes stripped),
// so a word that only lives in a title= tooltip does not count.

globalThis.window = globalThis.window || {
  location: { pathname: '/kanban', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {} }
};

const { render } = await import('preact-render-to-string');
const { assertNoRawHeaders, assertUsdLabelled } = await import('./legibility.bh-3558.js');
const { PipelineList, PipelineBoard } = await import('../src/screens/Kanban.js');
const { filterPipeline, shippedCaveat, pipelineRows } = await import('../src/lib/kanban.js');
const { ticketClaim } = await import('../src/lib/lanes.js');
const { MergeQueueView } = await import('../src/screens/MergeQueue.js');
const Run = await import('../src/screens/Run.js');
const Build = await import('../src/screens/Build.js');
const PR = await import('../src/screens/PR.js');

const NOW = Date.UTC(2026, 8, 29, 22, 4);
const ago = (ms) => new Date(NOW - ms).toISOString();
const H = 3600 * 1000;
const D = 24 * H;

// Visible text: every tag keeps its name but loses its attributes, so a word
// inside title="..." cannot satisfy a visible-text assertion.
const visible = (html) => String(html).replace(/<([a-zA-Z0-9-]+)\b[^>]*?(\/?)>/g, '<$1$2>');
const checked = (html) => { assertNoRawHeaders(html); assertUsdLabelled(html); return html; };
const bodyRows = (html) => html.split('<tr').slice(1).filter((t) => t.includes('<td'));
const cells = (tr) => (tr.match(/<td\b[\s\S]*?<\/td>/g) || []);

// ------------------------------------------------------------------ kanban

const payload = {
  columns: {
    queued: [{ project: 'project-3', queue_depth: 3, oldest_queued_min: 42, pending_commands: 0 }],
    building: [{ id: 11, project: 'project-1', ticket: 'TK-1', stage: 'executing', tier: null, verdict: null, pr_url: null, age_min: 4 }],
    merge_queue: [{ id: 12, project: 'project-1', ticket: 'TK-2', stage: 'pr_created', tier: 1, verdict: 'APPROVE', pr_url: 'https://github.com/example-org/project-1/pull/593', age_min: 9 }],
    review: [{ id: 13, project: 'project-3', ticket: 'TK-5', stage: 'pr_created', tier: 2, verdict: null, pr_url: 'https://github.com/example-org/x/pull/5', age_min: 30 }],
    merged_deployed: [{ id: 14, project: 'project-3', ticket: 'TK-9', stage: 'tier2_sweep_merged', tier: 2, verdict: 'APPROVE', pr_url: 'https://github.com/example-org/project-3/pull/8', age_min: 1440 }],
    dead_failed: []
  },
  counts: { queued: 3, building: 1, merge_queue: 1, review: 1, merged_deployed: 1, dead_failed: 0 },
  building_stale: 0
};

const external = {
  project: 'project-4', ticket: 'TK-9', title: 'a thing',
  ...ticketClaim({ claim: {
    actor: 'someRandomDev', fleet: false, kind: 'pr', state: 'open', pr: 1421,
    pr_url: 'https://github.com/example-org/project-4/pull/1421', at: '2026-09-29T20:00:00Z'
  } })
};

const board = () => filterPipeline(payload, null);
const renderList = (ext = []) => checked(render(h(PipelineList, {
  board: board(), external: ext, shipped: shippedCaveat(board()), emptyNote: 'empty', onToggleAudit: () => {}
})));
const renderBoard = (ext = []) => checked(render(h(PipelineBoard, {
  board: board(), external: ext, shipped: shippedCaveat(board()), showEmpty: false, emptyNote: '', onToggleAudit: () => {}
})));
const rowFor = (html, label) => {
  const tr = bodyRows(html).find((t) => t.includes(`>${label}<`));
  assert.ok(tr, `a row for ${label}`);
  return tr;
};
const cardFor = (html, label) => {
  const i = html.indexOf(`>${label}<`);
  assert.notEqual(i, -1, `no card for ${label}`);
  const start = html.lastIndexOf('<a', i);
  return html.slice(start, html.indexOf('</a>', i) + 4);
};
// Column order in the list: COLUMN, TICKET, PROJECT, STAGE, TIER, VERDICT, PR, AGE.
const VERDICT_CELL = 5;
const TIER_CELL = 4;
const STAGE_CELL = 3;

test('K1 an own PR with no verdict reads "not reviewed yet"; an external row keeps its owner label', () => {
  const list = renderList([external]);
  const own = cells(rowFor(list, 'TK-5'))[VERDICT_CELL];
  assert.match(visible(own), /not reviewed yet/);
  assert.ok(!visible(own).includes('—'), `no dash in the VERDICT cell: ${own}`);

  // No PR and no verdict is still a plain dash: nothing is waiting on a review.
  assert.ok(visible(cells(rowFor(list, 'TK-1'))[VERDICT_CELL]).includes('—'));
  // A reviewed row reads its verdict in words.
  assert.match(visible(cells(rowFor(list, 'TK-2'))[VERDICT_CELL]), /approved/);

  const extLabel = pipelineRows(board(), [external]).find((r) => r.external).externalLabel;
  assert.ok(extLabel, 'the fixture has an owner label');
  const ext = cells(rowFor(list, 'TK-9'))[VERDICT_CELL];
  assert.ok(ext.includes(extLabel), `the external row keeps ${extLabel}`);
  assert.ok(!ext.includes('not reviewed yet'), 'somebody else\'s PR is not ours to review');

  const card = cardFor(renderBoard(), 'TK-5');
  assert.match(visible(card), /not reviewed yet/, 'the card follows the same rule');
  assert.ok(!visible(cardFor(renderBoard(), 'TK-1')).includes('not reviewed yet'), 'no PR, no claim of a pending review');
});

test('K2 TIER reads auto-merge / reviewed merge in the list and on the cards, never TIER 1 / TIER 2', () => {
  const list = renderList();
  assert.match(visible(cells(rowFor(list, 'TK-2'))[TIER_CELL]), /auto-merge/);
  assert.match(visible(cells(rowFor(list, 'TK-5'))[TIER_CELL]), /reviewed merge/);
  const cards = renderBoard();
  assert.match(visible(cardFor(cards, 'TK-2')), /auto-merge/);
  assert.match(visible(cardFor(cards, 'TK-5')), /reviewed merge/);
  for (const out of [list, cards]) {
    assert.doesNotMatch(out, /TIER 1|TIER 2/);
  }
  // The TIER sort stays numeric: the row value is the number, not the words.
  const rows = pipelineRows(board());
  assert.equal(rows.find((r) => r.label === 'TK-5').tier, 2);
});

test('K3 MERGE QUEUE is spelled out in the list and the board head, with a visible column Legend', () => {
  const list = renderList();
  assert.match(visible(cells(rowFor(list, 'TK-2'))[0]), />MERGE QUEUE</);
  const cards = renderBoard();
  assert.match(visible(cards), /<span>\s*MERGE QUEUE\s*<\/span>/, 'the board column head');
  for (const out of [list, cards]) {
    const v = visible(out);
    for (const term of ['QUEUED', 'BUILDING', 'MERGE QUEUE', 'REVIEW', 'SHIPPED', 'DEAD']) {
      assert.ok(v.includes(`<dt>${term}</dt>`), `Legend term ${term} is visible text`);
    }
  }
});

test('K4 a build at tier2_sweep_merged reads in words on the card and in the list', () => {
  const cards = renderBoard();
  assert.match(visible(cardFor(cards, 'TK-9')), /merged by the reviewed-merge sweep/);
  assert.ok(!visible(cards).includes('tier2_sweep_merged'), 'the raw stage is never visible text');
  const list = renderList();
  assert.match(visible(cells(rowFor(list, 'TK-9'))[STAGE_CELL]), /merged by the reviewed-merge sweep/);
  assert.ok(!visible(list).includes('tier2_sweep_merged'));
  // The free-text queue detail passes through untouched.
  assert.match(list, /3 tickets waiting/);
});

// ------------------------------------------------------------- merge queue

const mq = (pr, status, enqueued_at) =>
  ({ project: 'project-3', pr, status, repo: 'example-org/project-3', reason: `r${pr}`, enqueued_by: 'conductor', enqueued_at, updated_at: enqueued_at });
const okRes = (data) => ({ data, error: null, reload() {} });
const mqRes = (rows) => okRes({ merge_queue: rows, as_of: ago(0) });

test('K5 MergeQueueView: statuses and held fields in words, dated stamps, a Legend, both helpers', () => {
  const held = { repo: 'example-org/project-3', number: 41, state: 'held_open', kind: 'lead_review', mode: 'page_once', text: 't', first_held_at: ago(3 * D), last_seen_at: ago(2 * H) };
  const out = checked(render(h(MergeQueueView, {
    project: null,
    mq: [mqRes([mq(41, 'queued', ago(3 * D))]), mqRes([mq(42, 'blocked', ago(3 * H))]), mqRes([mq(43, 'dropped', ago(30 * 60 * 1000))])],
    held: okRes({ rows: [held], n_total: 1 }),
    mqChanges: okRes({ changes: [] }), heldChanges: okRes({ changes: [] }),
    setting: okRes({ key: 'merge_queue_rows_only', setting: null, source: 'none' }),
    reload() {}, nowMs: NOW
  })));
  const v = visible(out);
  assert.match(v, />blocked, needs a look</);
  assert.match(v, />dropped from the queue</);
  assert.match(v, /Sep 26 22:04Z/, 'a 3-day-old enqueued_at is a dated stamp');
  assert.match(v, /3h ago/);
  assert.match(v, />held open</);
  assert.match(v, />lead review</);
  assert.match(v, />page once</);
  for (const term of ['queued', 'blocked', 'dropped']) {
    assert.ok(v.includes(`<dt>${term}</dt>`), `Legend term ${term} is visible text`);
  }
  // Default sort is still oldest enqueued first.
  assert.ok(out.indexOf('href="/pr/project-3/41"') < out.indexOf('href="/pr/project-3/42"'));
});

// --------------------------------------------------------- run / build / pr

test('K6 RunView: exit code in words, no rc=, dated stamps, KIND in words', () => {
  assert.equal(typeof Run.RunView, 'function', 'Run.js exports RunView');
  const out = checked(render(h(Run.RunView, {
    run: { id: 1, project: 'p', kind: 'lead_review', rc: 137, started_at: ago(4 * D), finished_at: ago(4 * D - 60000), duration_s: 60, age_min: 5760 },
    nowMs: NOW
  })));
  const v = visible(out);
  assert.match(v, /exit code 137 · killed/);
  assert.ok(!v.includes('rc='), 'no raw rc= anywhere');
  assert.match(v, /Sep 25 22:04Z/, 'a 4-day-old start is dated, not a bare clock time');
  assert.match(v, /lead review/);
  assert.ok(!v.includes('lead_review'));
});

test('K6 BuildStats and BuildMission: stage, tier and verdict in words; $ carries its basis', () => {
  assert.equal(typeof Build.BuildStats, 'function', 'Build.js exports BuildStats');
  const stats = checked(render(h(Build.BuildStats, {
    build: { id: 5, stage: 'reviewing', tier: 1, verdict: 'APPROVE', merged: 0, age_min: 5 }, lane: 'building'
  })));
  const v = visible(stats);
  assert.match(v, /in review/);
  assert.match(v, /auto-merge/);
  assert.ok(!v.includes('reviewing'), 'the raw stage is not visible');

  const build = { id: 5, project: 'p', ticket_key: 'BH-1', bkey: 'b', stage: 'reviewing', tier: 1, merged: 0, verdict: 'APPROVE', pr_url: null, age_min: 5, detail: null };
  const live = {
    job: { id: 'j', status: 'running', stage: 'review' },
    phases: [{ id: 1, phase: 'review', runner: 'claude', model: 'm', status: 'running', started_at: ago(H), finished_at: null, rc: null, spend_usd: 1.5 }],
    events: [], spend_usd: 1.5, cursor: 0, capped: false
  };
  const mission = checked(render(h(Build.BuildMission, {
    build, live, liveError: null, jobNote: null, nowMs: NOW,
    timeline: [{ id: 1, ts: ago(4 * D), type: 'stage', detail: 'x' }], artifactAction: async () => ({})
  })));
  assert.match(mission, /data-usd-basis="api"[^>]*>\$1\.50/, 'the $ figures carry their basis');
  assert.match(visible(mission), /Sep 25 22:04Z/, 'the timeline stamp is dated');
});

test('K6 PRStats: verdict and tier in words; BUILD COST carries its basis', () => {
  assert.equal(typeof PR.PRStats, 'function', 'PR.js exports PRStats');
  const builds = [{ id: 1, bkey: 'b', stage: 'reviewing', tier: 2, verdict: 'BLOCK' }];
  const out = checked(render(h(PR.PRStats, {
    builds, data: { cost: { available: true, total: 4.25 } }, gh: null, checks: null
  })));
  const v = visible(out);
  assert.match(v, /reviewed merge/);
  assert.match(v, /blocked/);
  assert.ok(!v.includes('BLOCK<'), 'the raw verdict is not visible');
  assert.match(out, /data-usd-basis="api"[^>]*>\$4\.25/);
  // A preformatted $ string is labelled too, never bare.
  checked(render(h(PR.PRStats, { builds, data: { cost: { available: true, total: '$4.25' } }, gh: null, checks: null })));
});
