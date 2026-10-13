import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import {
  onRequest, markHeld, heldTicketKeys, _resetHeldCache, _resetClosedCache
} from '../functions/api/dash/kanban/pipeline.js';
import { pipelineRows } from '../src/lib/kanban.js';
import { sortRows } from '../src/lib/sort.js';
import { PipelineBoard, PipelineList } from '../src/screens/Kanban.js';

// BH-3148 (BH-2326.2). The hub writes ledgers(kind=ticket_hold) rows; the
// pipeline function joins the held ones onto build cards at read time, and the
// Kanban card and list row show the contract's HELD tag. These pin the join,
// its fail-open read, and the rendered chip.

const JOBS = 'https://harness-jobs.operator.workers.dev';
const isHold = (u) => u.startsWith(`${JOBS}/api/ledger?kind=ticket_hold`);
const isClosed = (u) => u.startsWith(`${JOBS}/api/ledger?kind=issue_state`);
const ENV = { HARNESS_SECRET: 's' };

const jsonRes = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

function withFetch(route, fn) {
  const real = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), init });
    const a = route(String(url));
    if (a instanceof Error) throw a;
    return a;
  };
  _resetHeldCache();
  _resetClosedCache();
  return Promise.resolve(fn(calls)).finally(() => {
    globalThis.fetch = real;
    _resetHeldCache();
    _resetClosedCache();
  });
}

// Ledger rows as the jobs worker lists them: newest updated_at first, detail
// in the contract's '<verb> by <actor> at <iso>: <reason> | <why>' shape.
const holdRow = (key, status, updated_at, detail) => ({ kind: 'ticket_hold', key, status, updated_at, detail });
const HELD_PB1 = holdRow('project-1#1', 'held', '2026-09-28T12:00:00Z',
  'hold by operator at 2026-09-28T11:59:58Z: waiting on the client | asked in thread');
const HELD_VALUE = { by: 'operator', at: '2026-09-28T11:59:58Z', why: 'waiting on the client | asked in thread' };

const build = (id, ticket, stage, extra = {}) => ({ id, project: 'project-1', ticket, stage, age_min: 5, ...extra });
const payload = () => ({
  columns: {
    queued: [{ project: 'project-1', queue_depth: 2, oldest_queued_min: 3 }],
    building: [build(11, 'TK-1', 'executing'), build(12, 'TK-2', 'executing')],
    merge_queue: [],
    review: [{ command_id: 7, project: 'project-1', ticket: 'TK-1', ckey: 'retry TK-1', status: 'pending', age_min: 2 }],
    merged_deployed: [],
    dead_failed: [build(13, 'TK-1', 'plan_blocked')]
  },
  counts: { queued: 2, building: 2, merge_queue: 0, review: 1, merged_deployed: 0, dead_failed: 1 },
  building_stale: 0
});

// --- markHeld, pure ---------------------------------------------------------

test('A1. markHeld marks the held build cards in every column, and only those', () => {
  const out = markHeld(payload(), new Map([['project-1#1', HELD_VALUE]]));
  assert.deepEqual(out.columns.building[0].held, HELD_VALUE);
  assert.deepEqual(out.columns.dead_failed[0].held, HELD_VALUE);
  assert.equal('held' in out.columns.building[1], false);
  assert.equal(out.held_known, true);
  assert.equal('held_complete' in out, false);
  // A hold hides nothing: counts pass through untouched.
  assert.deepEqual(out.counts, payload().counts);
});

test('A2. command and queue cards are never marked', () => {
  const out = markHeld(payload(), new Map([['project-1#1', HELD_VALUE]]));
  assert.equal('held' in out.columns.review[0], false);
  assert.equal('held' in out.columns.queued[0], false);
});

test('A3. a null map changes no card and says the hold state is unknown', () => {
  const p = payload();
  const out = markHeld(p, null);
  assert.deepEqual(out.columns, payload().columns);
  assert.equal(out.held_known, false);
  for (const col of Object.values(out.columns)) {
    for (const c of col) assert.equal('held' in c, false);
  }
});

// --- heldTicketKeys, the ledger read -----------------------------------------

test('A4. heldTicketKeys keeps the newest row per key, and only held ones', () =>
  withFetch(() => jsonRes({ ledgers: [
    HELD_PB1,
    holdRow('project-1#1', 'clear', '2026-09-28T10:00:00Z', 'unhold by operator at 2026-09-28T10:00:00Z: ok | ok'),
    holdRow('project-1#3', 'clear', '2026-09-28T09:00:00Z', 'unhold by x at 2026-09-28T09:00:00Z: a | b'),
    holdRow('project-3#9', 'held', '2026-09-28T08:00:00Z', 'garbled')
  ] }), async (calls) => {
    const r = await heldTicketKeys(ENV);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].url, `${JOBS}/api/ledger?kind=ticket_hold&limit=1000`);
    assert.equal(calls[0].init.headers.authorization, 'Bearer s');
    assert.deepEqual([...r.held.keys()].sort(), ['project-1#1', 'project-3#9']);
    assert.deepEqual(r.held.get('project-1#1'), HELD_VALUE);
    // An unparseable detail is still held; the row's own time and text stand in.
    assert.deepEqual(r.held.get('project-3#9'), { by: null, at: '2026-09-28T08:00:00Z', why: 'garbled' });
    assert.equal(r.complete, true);
  }));

test('A4b. a clear row newer than a held one wins', () =>
  withFetch(() => jsonRes({ ledgers: [
    holdRow('project-1#1', 'clear', '2026-09-28T13:00:00Z', 'unhold by operator at 2026-09-28T13:00:00Z: go | go'),
    HELD_PB1
  ] }), async () => {
    const r = await heldTicketKeys(ENV);
    assert.equal(r.held.size, 0);
  }));

for (const [name, answer] of [
  ['500', () => new Response('boom', { status: 500 })],
  ['{} body', () => jsonRes({})],
  ['non-JSON', () => new Response('<html>', { status: 200 })],
  ['throw', () => new Error('down')]
]) {
  test(`A5. heldTicketKeys fails open to null on ${name}, and caches nothing`, () =>
    withFetch(() => answer(), async (calls) => {
      assert.equal(await heldTicketKeys(ENV), null);
      assert.equal(await heldTicketKeys(ENV), null);
      assert.equal(calls.length, 2);
    }));
}

test('A5b. no HARNESS_SECRET is null with no fetch', () =>
  withFetch(() => jsonRes({ ledgers: [HELD_PB1] }), async (calls) => {
    assert.equal(await heldTicketKeys({}), null);
    assert.equal(await heldTicketKeys(undefined), null);
    assert.equal(calls.length, 0);
  }));

test('A6. two reads inside the TTL make one fetch', () =>
  withFetch(() => jsonRes({ ledgers: [HELD_PB1] }), async (calls) => {
    const a = await heldTicketKeys(ENV);
    const b = await heldTicketKeys(ENV);
    assert.equal(calls.length, 1);
    assert.equal(a, b);
  }));

test('A7. a full 1000-row page is incomplete, and markHeld says so', () => {
  const rows = Array.from({ length: 1000 }, (_, i) =>
    holdRow(`project-1#${i + 100}`, 'clear', '2026-09-28T09:00:00Z', 'unhold by x at 2026-09-28T09:00:00Z: a | b'));
  rows[0] = HELD_PB1;
  return withFetch(() => jsonRes({ ledgers: rows }), async () => {
    const r = await heldTicketKeys(ENV);
    assert.equal(r.complete, false);
    const out = markHeld(payload(), r.held, { complete: r.complete });
    assert.equal(out.held_complete, false);
    assert.equal(out.held_known, true);
    assert.deepEqual(out.columns.building[0].held, HELD_VALUE);
  });
});

// --- onRequest, the production entry point -----------------------------------

const req = () => new Request('https://console.example/api/dash/kanban/pipeline', { headers: { cookie: 'dash=tok' } });

test('A8. onRequest marks the held card after the closed-issue join', () =>
  withFetch((u) => (isHold(u) ? jsonRes({ ledgers: [HELD_PB1] })
    : isClosed(u) ? jsonRes({ ledgers: [] })
      : jsonRes(payload())), async (calls) => {
    const res = await onRequest({ request: req(), env: ENV });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.held_known, true);
    assert.deepEqual(body.columns.building[0].held, HELD_VALUE);
    assert.deepEqual(body.columns.dead_failed[0].held, HELD_VALUE);
    assert.equal('held' in body.columns.building[1], false);
    assert.equal(body.dead_closed_known, true);
    assert.equal(calls.filter((c) => isHold(c.url)).length, 1);
  }));

test('A8b. onRequest with the hold read answering 500 marks nothing and says unknown', () =>
  withFetch((u) => (isHold(u) ? new Response('boom', { status: 500 })
    : isClosed(u) ? jsonRes({ ledgers: [] })
      : jsonRes(payload())), async () => {
    const body = await (await onRequest({ request: req(), env: ENV })).json();
    assert.equal(body.held_known, false);
    for (const col of Object.values(body.columns)) {
      for (const c of col) assert.equal('held' in c, false);
    }
  }));

test('A8c. an upstream 403 makes no hold read', () =>
  withFetch((u) => (u.startsWith(JOBS) ? jsonRes({ ledgers: [HELD_PB1] }) : new Response('no', { status: 403 })),
    async (calls) => {
      const res = await onRequest({ request: req(), env: ENV });
      assert.equal(res.status, 403);
      assert.equal(calls.filter((c) => isHold(c.url)).length, 0);
    }));

// --- the rows and the screen ---------------------------------------------------

const marked = () => markHeld(payload(), new Map([['project-1#1', HELD_VALUE]]));

test('A9. pipelineRows carries held from the card, null elsewhere', () => {
  const rows = pipelineRows(marked());
  const heldRows = rows.filter((r) => r.held);
  assert.deepEqual(heldRows.map((r) => r.card.id), [11, 13]);
  for (const r of heldRows) assert.deepEqual(r.held, HELD_VALUE);
  for (const r of rows.filter((x) => !x.held)) assert.equal(r.held, null);
});

// The card's markup: the <a> that holds `>label<`, up to its closing tag.
const cardHtml = (html, label) => {
  const i = html.indexOf(`>${label}<`);
  assert.notEqual(i, -1, `no card for ${label}`);
  const start = html.lastIndexOf('<a', i);
  return html.slice(start, html.indexOf('</a>', i) + 4);
};

test('A10. a held build card renders HELD; an un-held one does not; no button inside', () => {
  const out = render(h(PipelineBoard, { board: marked(), external: [], onToggleAudit: () => {} }));
  const held = cardHtml(out, 'TK-1');
  assert.match(held, /<span class="tag tag--warn"[^>]*>HELD<\/span>/);
  assert.match(held, /title="Held by operator at 2026-09-28T11:59:58Z: waiting on the client \| asked in thread/);
  assert.doesNotMatch(held, /<button/);
  assert.doesNotMatch(cardHtml(out, 'TK-2'), /HELD/);
  // The command card for the same ticket is not a build: no chip.
  assert.doesNotMatch(cardHtml(out, 'retry TK-1'), /HELD/);
});

test('A10b. with no hold map the board renders no HELD anywhere', () => {
  const out = render(h(PipelineBoard, { board: markHeld(payload(), null), external: [], onToggleAudit: () => {} }));
  assert.doesNotMatch(out, />HELD</);
});

test('A11. the list TICKET cell shows HELD, and the TICKET sort still orders by label', () => {
  const out = render(h(PipelineList, { board: marked(), external: [], onToggleAudit: () => {} }));
  const trs = out.split('<tr').slice(1).filter((t) => t.includes('<td'));
  const heldTrs = trs.filter((t) => />HELD</.test(t));
  // TK-1 building + TK-1 dead are held; TK-2, the command and the queue are not.
  assert.equal(heldTrs.length, 2);
  for (const t of heldTrs) assert.match(t, />TK-1</);
  assert.ok(trs.some((t) => />TK-2</.test(t) && !/>HELD</.test(t)));

  // The TICKET column still sorts on the plain label: a held row's label is its
  // ticket, not the chip, so it sorts beside its un-held namesakes.
  const rows = pipelineRows(marked());
  for (const r of rows.filter((x) => x.held)) assert.equal(r.label, 'TK-1');
  const asc = sortRows(rows, (r) => r.label, 'asc').map((r) => r.label);
  const i = asc.indexOf('TK-1');
  assert.deepEqual(asc.slice(i, i + 3), ['TK-1', 'TK-1', 'TK-2']);
  const desc = sortRows(rows, (r) => r.label, 'desc').map((r) => r.label);
  assert.deepEqual(desc, asc.slice().reverse());
  assert.match(out, /TICKET/);
});
