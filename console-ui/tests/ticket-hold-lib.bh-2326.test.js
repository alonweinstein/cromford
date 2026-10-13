import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';

// BH-2326.0: the ticket-hold CONTRACT every sibling of #2326 imports. The pure
// lib is driven with the shapes the worker actually answers (GET /api/ledger
// gives `{ledger: row}` for a present row and 404 `{error:'not found'}` for an
// absent one), the tag is rendered server-side, api.ticketHold is driven
// against a stubbed fetch, and commandTarget is the real /history/commands one.

// The router reads window.location at first render; give SSR one.
globalThis.window = globalThis.window || {
  location: { pathname: '/', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};

const { HOLD_LEDGER_KIND, HOLD_REASON_MAX, holdKey, holdTarget, holdCommand, holdFromLedger } =
  await import('../src/lib/ticket-hold.js');
const { HeldTag } = await import('../src/ui/HeldTag.js');
const { api } = await import('../src/api.js');
const { commandRows, commandTarget } = await import('../src/lib/commands.js');

// ---------------------------------------------------------------- lib -----

test('constants', () => {
  assert.equal(HOLD_LEDGER_KIND, 'ticket_hold');
  assert.equal(HOLD_REASON_MAX, 500);
});

test('holdKey is the pipeline.js closed-issue key shape', () => {
  assert.equal(holdKey('cromford', 2326), 'cromford#2326');
});

test('holdTarget accepts PREFIX-<n>', () => {
  assert.deepEqual(holdTarget('cromford', 'BH-2326'), { project: 'cromford', ticket: 'BH-2326', issue: 2326 });
  assert.deepEqual(holdTarget('project-4', 'TK-1'), { project: 'project-4', ticket: 'TK-1', issue: 1 });
});

test('holdTarget refuses everything else', () => {
  for (const key of ['BH-2326a', '2326', 'BH-0', 'BH-01', '../2326', '', ' BH-1', 'BH-1 ']) {
    assert.equal(holdTarget('cromford', key), null, JSON.stringify(key));
  }
  assert.equal(holdTarget('cromford', undefined), null, 'ticketKey undefined');
  assert.equal(holdTarget('cromford', 2326), null, 'ticketKey number');
  assert.equal(holdTarget('', 'BH-2326'), null, 'project blank');
  assert.equal(holdTarget('   ', 'BH-2326'), null, 'project whitespace');
  assert.equal(holdTarget(undefined, 'BH-2326'), null, 'project undefined');
});

test('holdCommand: hold and unhold bodies', () => {
  const t = holdTarget('cromford', 'BH-2326');
  assert.deepEqual(holdCommand('hold', t, 'waiting on spec'),
    { type: 'hold_ticket', project: 'cromford', ticket: 'BH-2326', reason: 'waiting on spec' });
  assert.deepEqual(holdCommand('unhold', t, ' spec landed '),
    { type: 'unhold_ticket', project: 'cromford', ticket: 'BH-2326', reason: 'spec landed' });
});

test('holdCommand: reason trimmed before it is capped at HOLD_REASON_MAX', () => {
  const t = holdTarget('cromford', 'BH-2326');
  const long = holdCommand('hold', t, ' ' + 'a'.repeat(600) + ' ');
  assert.equal(long.reason.length, 500);
  assert.equal(long.reason, 'a'.repeat(500));
  assert.equal(holdCommand('hold', t, '   ').reason, '');
  assert.equal(holdCommand('hold', t, undefined).reason, '');
  assert.equal(holdCommand('hold', null, 'x'), null, 'a refused target never becomes a command');
});

test('holdFromLedger: held parses by/at/why from detail', () => {
  const row = { kind: 'ticket_hold', key: 'cromford#2326', status: 'held',
    detail: 'hold by operator at 2026-09-28T10:00:00Z: waiting on spec | operator request' };
  assert.deepEqual(holdFromLedger(row),
    { held: true, by: 'operator', at: '2026-09-28T10:00:00Z', why: 'waiting on spec | operator request' });
  assert.deepEqual(holdFromLedger({ ledger: row }),
    { held: true, by: 'operator', at: '2026-09-28T10:00:00Z', why: 'waiting on spec | operator request' },
    'the raw {ledger: row} body reads the same');
});

test('holdFromLedger: an unparseable held detail is still held, with nothing guessed', () => {
  assert.deepEqual(holdFromLedger({ kind: 'ticket_hold', status: 'held', detail: 'freeform' }),
    { held: true, by: null, at: null, why: null });
  assert.deepEqual(holdFromLedger({ status: 'held' }), { held: true, by: null, at: null, why: null });
});

test('holdFromLedger: clear and absent are not held', () => {
  assert.deepEqual(holdFromLedger({ kind: 'ticket_hold', status: 'clear' }), { held: false });
  assert.deepEqual(holdFromLedger(null), { held: false });
  assert.deepEqual(holdFromLedger({ ledger: null }), { held: false }, 'the 404 answer api.ticketHold resolves to');
});

test('holdFromLedger: unknown, garbage and load failure are unknown, never not-held', () => {
  const cases = [{ kind: 'ticket_hold', status: 'unknown' }, undefined, 'x', [], new Error('http_500'),
    { status: 'bogus' }, { kind: 'merge', status: 'held' }, {}, 42];
  for (const c of cases) assert.deepEqual(holdFromLedger(c), { unknown: true }, String(c && c.status || c));
});

// ---------------------------------------------------------------- tag -----

test('HeldTag renders HELD with the recorded title only when held', () => {
  const out = render(h(HeldTag, { held: true, by: 'operator', at: '2026-09-28T10:00:00Z', why: 'waiting on spec' }));
  assert.match(out, /^<span class="tag tag--warn"[^>]*>HELD<\/span>$/);
  assert.ok(out.includes('title="Held by operator at 2026-09-28T10:00:00Z: waiting on spec (as recorded by Mission Control)"'), out);
  const bare = render(h(HeldTag, { held: true }));
  assert.ok(bare.includes('title="Held by unknown at unknown: no reason recorded (as recorded by Mission Control)"'), bare);
  for (const props of [{ held: false }, { unknown: true }, {}]) {
    assert.equal(render(h(HeldTag, props)), '', JSON.stringify(props));
  }
});

// ---------------------------------------------------------------- api -----

function stubFetch(status, body) {
  const calls = [];
  globalThis.fetch = async (url) => {
    calls.push(String(url));
    return { ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(body) };
  };
  return calls;
}

test('api.ticketHold reads the ledger row through the coord proxy', async () => {
  const row = { kind: 'ticket_hold', key: 'cromford#2326', status: 'held', detail: 'hold by a at b: c' };
  const calls = stubFetch(200, { ledger: row });
  assert.deepEqual(await api.ticketHold('cromford', 2326), { ledger: row });
  assert.deepEqual(calls, ['/api/coord/ledger?kind=ticket_hold&key=cromford%232326']);
});

test('api.ticketHold: the worker 404 for an absent row is an answer, not an error', async () => {
  stubFetch(404, { error: 'not found' });
  const body = await api.ticketHold('cromford', 2326);
  assert.deepEqual(body, { ledger: null });
  assert.deepEqual(holdFromLedger(body), { held: false });
});

test('api.ticketHold: any other failure rejects, and reads as unknown', async () => {
  stubFetch(500, { error: 'db down' });
  let err = null;
  try { await api.ticketHold('cromford', 2326); } catch (e) { err = e; }
  assert.ok(err, 'a 500 rejects');
  assert.deepEqual(holdFromLedger(err), { unknown: true });
  stubFetch(404, { error: 'no route' });
  await assert.rejects(api.ticketHold('cromford', 2326), 'a 404 that is not the absent-row answer rejects');
});

// ----------------------------------------------------- command history -----

test('commandTarget: hold_ticket / unhold_ticket rows link to /p/<project>', () => {
  for (const type of ['hold_ticket', 'unhold_ticket']) {
    const row = commandRows([{ id: 9, type, project: 'cromford',
      payload: JSON.stringify({ type, project: 'cromford', ticket: 'BH-2326', reason: 'x' }) }]).rows[0];
    assert.deepEqual(commandTarget(row), { to: '/p/cromford', label: 'cromford board' }, type);
    const bare = commandRows([{ id: 10, type, payload: '{}' }]).rows[0];
    assert.equal(commandTarget(bare), null, `${type} with no project`);
    const fleet = commandRows([{ id: 11, type, payload: '{"scope":"fleet"}' }]).rows[0];
    assert.equal(commandTarget(fleet), null, `${type} is not a fleet pause`);
  }
});
