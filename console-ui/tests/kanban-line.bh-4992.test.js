// BH-4992 (BH-4947 wave 3): Kanban columns are the stations.
//
// The headline derives from the board counts; each column head names its
// station ("03 Build"); each build card carries its compact station track; the
// list view links every ticket key to /t/<KEY>. The card links that
// kanban-list-render and kanban.test pin (PR or build) stay.
// (File name: console-ui runs tests/*.test.js.)
import test from 'node:test';
import assert from 'node:assert/strict';
import { h } from 'preact';

globalThis.window = globalThis.window || {
  location: { pathname: '/kanban', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};
const { render } = await import('preact-render-to-string');
const { PipelineBoard, PipelineList, KanbanHeadline } = await import('../src/screens/Kanban.js');
const { kanbanHeadline, KANBAN_STATION } = await import('../src/lib/line-screens.js');

const card = (id, ticket, stage, over = {}) => ({ id, project: 'project-3', ticket, ticket_key: ticket, bkey: ticket, stage, age_min: 5, tier: 2, ...over });
const BOARD = {
  columns: {
    queued: [], building: [card(1, 'TK-1', 'executing'), card(2, 'TK-2', 'planning')], merge_queue: [card(3, 'TK-3', 'queued', { pr_url: 'https://github.com/example-org/project-3/pull/30' })],
    review: [card(4, 'TK-4', 'reviewing')], merged_deployed: [card(5, 'TK-5', 'merged')], dead_failed: [card(6, 'TK-6', 'failed')]
  },
  counts: { queued: 7, building: 2, merge_queue: 1, review: 1, merged_deployed: 1, dead_failed: 1 },
  building_stale: 0, snapshot_age_min: 1
};

test('K1 the headline derives from the board counts', () => {
  assert.deepEqual(kanbanHeadline(BOARD.counts), {
    line1: '2 building. 1 in review. 1 in the merge queue.',
    line2: '1 shipped. 1 failed.',
    lede: '7 queued to build.'
  });
  const out = render(h(KanbanHeadline, { board: BOARD }));
  assert.match(out, /<h1 class="line-headline">2 building\. 1 in review\. 1 in the merge queue\.<br\/>/);
});

test('K2 every column head names its station; failed sits off the line', () => {
  assert.deepEqual(KANBAN_STATION, { queued: 1, building: 2, review: 3, merge_queue: 4, merged_deployed: 5, dead_failed: null });
  const out = render(h(PipelineBoard, { board: BOARD, external: [], shipped: null, showEmpty: false, emptyNote: '', onToggleAudit() {} }));
  for (const s of ['02 Plan', '03 Build', '04 Review', '05 Merge', '06 Deploy']) assert.ok(out.includes(`<span class="kb__station">${s}</span>`), `station ${s}`);
  assert.ok(out.includes('<span class="kb__station kb__station--off">off the line</span>'), 'the failed column is off the line');
});

test('K3 each build card carries its stations; the list links every key', () => {
  const out = render(h(PipelineBoard, { board: BOARD, external: [], shipped: null, showEmpty: false, emptyNote: '', onToggleAudit() {} }));
  assert.match(out, /aria-label="TK-1 at Build \(now\)"/);
  assert.match(out, /aria-label="TK-2 at Build \(now\)"/); // TEST-CHANGE (BH-4992 lead BLOCK): a planning card in the building column sits at its column, Build.
  assert.match(out, /aria-label="TK-4 at Review \(now\)"/);
  const list = render(h(PipelineList, { board: BOARD, external: [], shipped: null, emptyNote: '', onToggleAudit() {} }));
  for (const k of ['TK-1', 'TK-2', 'TK-3', 'TK-4', 'TK-5', 'TK-6']) assert.ok(list.includes(`href="/t/${k}"`), `${k} links in the list`);
});

// Lead BLOCK on fd3f36a23: a card's station never sits behind its column, and
// a shipped card is drawn done, not now. The merge-queue card at a review stage
// is the kanban-mq-legibility.bh-3569 shape.
test('K4 a card never sits behind its column; shipped cards are done', async () => {
  const { cardStation } = await import('../src/lib/line-screens.js');
  assert.equal(cardStation({ stage: 'reviewing' }, 'merge_queue'), 4);
  assert.equal(cardStation({ stage: 'reviewing' }, 'merged_deployed'), 5);
  assert.equal(cardStation({ stage: 'planning' }, 'building'), 2);
  assert.equal(cardStation({ stage: 'reviewing' }, 'building'), 3, 'a stage ahead of its column keeps its own station');
  assert.equal(cardStation({ stage: 'reviewing' }, 'dead_failed'), null);
  assert.equal(cardStation({ stage: 'no-such-stage' }, 'review'), 3);
  const b = { ...BOARD, columns: { ...BOARD.columns, merge_queue: [card(7, 'TK-7', 'reviewing', { pr_url: 'https://github.com/example-org/project-3/pull/31' })] } };
  const out = render(h(PipelineBoard, { board: b, external: [], shipped: null, showEmpty: false, emptyNote: '', onToggleAudit() {} }));
  assert.match(out, /aria-label="TK-7 at Merge \(now\)"/);
  assert.match(out, /aria-label="TK-5 at Deploy \(done\)"/);
  assert.doesNotMatch(out, /at Review \(now\)"[^>]*>[^]*?TK-7/, 'TK-7 is not drawn at Review');
});

// Lead NOTE on fd3f36a23: a count the worker did not send is never shown as 0.
test('K5 a missing count says it was not read', () => {
  const k = kanbanHeadline({ building: 2, review: 1, merge_queue: 0, merged_deployed: 3, dead_failed: 0 });
  assert.equal(k.lede, 'Queued count not read.');
  assert.equal(k.line1, '2 building. 1 in review. 0 in the merge queue.');
  const m = kanbanHeadline({ review: 1 });
  assert.match(m.line1, /Building count not read\./);
  assert.match(m.line2, /Shipped count not read\. Failed count not read\./);
});
