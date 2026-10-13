import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';

// BH-4995.3 (BH-5031): the orchestrator queue strip on /chat. The pure half
// (parseCmdStatus, orcQueue) is fed rows in the GET /api/dash/commands shape;
// the render half drives ChatQueueStrip, ChatMessage and the real ChatScreen
// through SSR, which runs no effects, so the queue poll itself never fires.

globalThis.window = globalThis.window || {
  location: { pathname: '/chat', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};
globalThis.document = globalThis.document || {
  hidden: false, addEventListener() {}, removeEventListener() {}, getElementById() { return null; }
};

const { parseCmdStatus, orcQueue, ORC_RUNNING_STALE_MIN } = await import('../src/lib/chat.js');
const { ChatQueueStrip, ChatMessage, ChatScreen } = await import('../src/screens/Chat.js');
const { FleetContext } = await import('../src/app.js');

const NOW = Date.parse('2026-10-06T22:34:12Z');
const row = (id, result, extra = {}) => ({
  id, type: 'chat', project: 'orchestrator', status: 'done', result,
  created_at: '2026-10-06T22:29:00Z', ...extra
});
const body = (...rows) => ({ commands: rows });
const iso = (ms) => new Date(ms).toISOString();

// ------------------------------------------------------- parseCmdStatus ---

test('P1 queued_behind:<id> carries the id it waits behind', () => {
  assert.deepEqual(parseCmdStatus('queued_behind:21105'), { state: 'queued_behind', behind: '21105' });
});

test('P2 running:<iso> carries its start', () => {
  assert.deepEqual(parseCmdStatus('running:2026-10-06T22:30:00Z'), { state: 'running', at: '2026-10-06T22:30:00Z' });
});

test('P3 answered / no_reply / duplicate carry their stamp', () => {
  for (const s of ['answered', 'no_reply', 'duplicate']) {
    assert.deepEqual(parseCmdStatus(`${s}:2026-10-06T22:31:00Z`), { state: s, at: '2026-10-06T22:31:00Z' }, s);
  }
});

test('P4 anything else is not a queue state', () => {
  for (const v of ['handed to orchestrator', null, undefined, '', 'queued_behind:', 'queued_behind:abc',
    'running:not-a-date', 'refused: x', 42]) {
    assert.deepEqual(parseCmdStatus(v), { state: null }, String(v));
  }
});

// -------------------------------------------------------------- orcQueue ---

test('Q1 the running turn and its age', () => {
  const q = orcQueue(body(row(21105, 'running:2026-10-06T22:30:00Z')), NOW);
  assert.deepEqual(q.running, {
    id: '21105', startedMs: Date.parse('2026-10-06T22:30:00Z'), ageMs: 252000, stale: false
  });
  assert.deepEqual(q.waiting, []);
});

test('Q2 waiting turns, oldest first, with the id they wait behind', () => {
  const q = orcQueue(body(
    row(21120, 'queued_behind:21105', { created_at: '2026-10-06T22:33:00Z' }),
    row(21118, 'queued_behind:21105', { created_at: '2026-10-06T22:32:00Z' })
  ), NOW);
  assert.deepEqual(q.waiting, [
    { id: '21118', behind: '21105', ageMs: 132000 },
    { id: '21120', behind: '21105', ageMs: 72000 }
  ]);
});

test('Q2b waiting order is by created_at, not id; an unparseable date sorts last with no age', () => {
  const q = orcQueue(body(
    row(31, 'queued_behind:1', { created_at: 'garbage' }),
    row(30, 'queued_behind:1', { created_at: '2026-10-06T22:33:00Z' }),
    row(29, 'queued_behind:1', { created_at: '2026-10-06T22:33:30Z' }),
    row(32, 'queued_behind:1', { created_at: '2026-10-06T22:32:00Z' })
  ), NOW);
  assert.deepEqual(q.waiting.map((w) => w.id), ['32', '30', '29', '31']);
  assert.equal(q.waiting[3].ageMs, null);
});

test('Q3 finished and acked turns never show', () => {
  const q = orcQueue(body(
    row(1, 'answered:2026-10-06T22:31:00Z'), row(2, 'no_reply:2026-10-06T22:31:00Z'),
    row(3, 'duplicate:2026-10-06T22:31:00Z'), row(4, 'handed to orchestrator')
  ), NOW);
  assert.deepEqual(q, { running: null, waiting: [] });
});

test('Q4 non-chat, other-target and not-done rows are excluded', () => {
  const q = orcQueue(body(
    row(1, 'running:2026-10-06T22:30:00Z', { type: 'run_triage' }),
    row(2, 'queued_behind:1', { project: 'project-3' }),
    row(3, 'running:2026-10-06T22:30:00Z', { status: 'failed' })
  ), NOW);
  assert.deepEqual(q, { running: null, waiting: [] });
});

test('Q5 a chat row with no project (console-sent orchestrator turn) counts', () => {
  const noKey = { id: 7, type: 'chat', status: 'done', result: 'running:2026-10-06T22:30:00Z',
    payload: '{"text":"hi"}', created_at: '2026-10-06T22:29:00Z' };
  assert.equal(orcQueue(body(noKey), NOW).running?.id, '7');
  const q = orcQueue(body(row(8, 'queued_behind:7', { project: null })), NOW);
  assert.deepEqual(q.waiting.map((w) => w.id), ['8']);
});

test('Q6 two running rows: the newest start wins', () => {
  const q = orcQueue(body(
    row(10, 'running:2026-10-06T22:31:00Z'),
    row(9, 'running:2026-10-06T20:00:00Z')
  ), NOW);
  assert.equal(q.running.id, '10');
});

test('Q7 stale at exactly 60 min, not at 59m59s', () => {
  assert.equal(ORC_RUNNING_STALE_MIN, 60);
  assert.equal(orcQueue(body(row(1, `running:${iso(NOW - 60 * 60000)}`)), NOW).running.stale, true);
  assert.equal(orcQueue(body(row(1, `running:${iso(NOW - 60 * 60000 + 1000)}`)), NOW).running.stale, false);
});

test('Q8 a malformed body is an empty queue, an array body is a body', () => {
  for (const b of [{}, null, 'x']) assert.deepEqual(orcQueue(b, NOW), { running: null, waiting: [] });
  assert.equal(orcQueue([row(5, 'running:2026-10-06T22:30:00Z')], NOW).running.id, '5');
});

test('Q9 a future stamp is age 0, never negative', () => {
  const q = orcQueue(body(
    row(1, 'running:2026-10-06T23:00:00Z'),
    row(2, 'queued_behind:1', { created_at: '2026-10-06T23:00:00Z' })
  ), NOW);
  assert.equal(q.running.ageMs, 0);
  assert.equal(q.waiting[0].ageMs, 0);
});

// ---------------------------------------------------------------- render ---

test('R1 running and waiting turns render as linked ids in one status list', () => {
  const q = orcQueue(body(
    row(21105, 'running:2026-10-06T22:30:00Z'),
    row(21118, 'queued_behind:21105', { created_at: '2026-10-06T22:32:00Z' }),
    row(21120, 'queued_behind:21105', { created_at: '2026-10-06T22:33:00Z' })
  ), NOW);
  const out = render(h(ChatQueueStrip, { queue: q, outIds: new Set(['21118']) }));
  assert.equal(out.match(/<ul class="chatqueue" role="status" aria-live="polite"/g)?.length, 1, out);
  assert.match(out, /Running now: <a [^>]*>#21105<\/a> · 4m 12s/);
  assert.match(out, /Waiting: <a href="#turn-21118"[^>]*>#21118<\/a>/);
  assert.match(out, /Waiting: <a href="\/history\/commands\?id=21120"[^>]*>#21120<\/a>/);
  assert.match(out, /behind <a [^>]*>#21105<\/a>/);
  assert.ok(!out.includes('—'), 'no em dash');
});

test('R2 an empty queue renders no strip', () => {
  assert.equal(render(h(ChatQueueStrip, { queue: { running: null, waiting: [] } })), '');
});

test('R3 a running turn past the threshold is flagged', () => {
  const q = orcQueue(body(row(1, `running:${iso(NOW - 61 * 60000)}`)), NOW);
  assert.match(render(h(ChatQueueStrip, { queue: q })), /no update in 60m\+/);
});

test('R4 a failed read says so, faintly, with no status list', () => {
  const out = render(h(ChatQueueStrip, { failed: true }));
  assert.match(out, /class="chatqueue chatqueue--err"[^>]*>queue unavailable/);
  assert.ok(!out.includes('role="status"'));
});

test('R5 the chat screen renders its thread and form without the queue', () => {
  const out = render(h(FleetContext.Provider, { value: { data: null } }, h(ChatScreen, {})));
  assert.ok(out.includes('class="chat__thread"'));
  assert.ok(out.includes('<textarea'));
  assert.ok(!out.includes('chatqueue'));
});

test('R6 an out bubble is anchored by its command id, a reply is not', () => {
  const out = render(h(ChatMessage, { m: { id: 3, command_id: '21118', direction: 'out', text: 'hi' }, thread: [] }));
  assert.match(out, /id="turn-21118"/);
  const reply = render(h(ChatMessage, { m: { id: 4, command_id: '21118', direction: 'reply', text: 'ok' }, thread: [] }));
  assert.ok(!reply.includes('id="turn-'));
});

test('R7 ChatScreen puts the strip above the thread on the orchestrator tab', () => {
  const seeded = body(row(21105, 'running:2026-10-06T22:30:00Z'));
  const out = render(h(FleetContext.Provider, { value: { data: null } }, h(ChatScreen, { initialQueue: seeded })));
  const strip = out.indexOf('<ul class="chatqueue"');
  assert.ok(strip >= 0, 'strip rendered');
  assert.match(out, /Running now: <a href="\/history\/commands\?id=21105"[^>]*>#21105<\/a>/);
  assert.ok(strip < out.indexOf('class="chat"'), 'strip sits above the thread');
});
