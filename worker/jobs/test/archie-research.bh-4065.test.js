// BH-4065 (BH-3966.4): Archie's research ledger, driven through the REAL
// worker.fetch against the REAL schema.sql (the node:sqlite D1 shim), the way
// initiatives.bh-4062.test.js does it. Pinned here: the claim's one
// conditional upsert (new / retry / terminal / attempt cap), the settle's
// transitions (only from claimed, ok fill-in, a terminal never rewritten, the
// refund only for a call that billed nothing), the day's spend with every
// unpriced attempt counted at the reserve, and the exact 404 body.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
const call = (DB, path, { method = 'GET', body, secret = SECRET } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: secret === null ? {} : { authorization: `Bearer ${secret}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};
const claim = (DB, body) => call(DB, '/api/archie-research/claim', { method: 'POST', body });
const settle = (DB, body) => call(DB, '/api/archie-research/settle', { method: 'POST', body });
const get = (DB, qs) => call(DB, `/api/archie-research?${qs}`);
const spend = (DB, qs) => call(DB, `/api/archie-research/spend?${qs}`);

const DAY = '2026-10-04';
const XQ = `xq:agent-harnesses:${DAY}`;
const xq = (extra = {}) => ({ key: XQ, kind: 'xquery', source: 'x', day: DAY, max_attempts: 3, ...extra });

test('BH-4065 archie research ledger', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('R1 every route is bearer-gated', async () => {
    const { DB } = await openDb();
    for (const [method, path] of [
      ['POST', '/api/archie-research/claim'], ['POST', '/api/archie-research/settle'],
      ['GET', `/api/archie-research/spend?day=${DAY}&reserve_usd=0.1`], ['GET', `/api/archie-research?key=${XQ}`],
    ]) {
      const r = await call(DB, path, { method, body: method === 'POST' ? {} : undefined, secret: null });
      assert.equal(r.status, 401, `${method} ${path}`);
    }
  });

  await t.test('R2 claim: new 201, again 200 with attempts 2, at the cap 409', async () => {
    const { DB } = await openDb();
    const a = await claim(DB, xq());
    assert.equal(a.status, 201);
    assert.equal(a.body.row.status, 'claimed');
    assert.equal(a.body.row.attempts, 1);
    const b = await claim(DB, xq());
    assert.equal(b.status, 200, 'a crashed claimed row is re-claimable and counts');
    assert.equal(b.body.row.attempts, 2);
    assert.equal((await settle(DB, { key: XQ, status: 'failed', note: 'http 500' })).status, 200);
    const c = await claim(DB, xq());
    assert.equal(c.status, 200);
    assert.equal(c.body.row.attempts, 3);
    assert.equal((await settle(DB, { key: XQ, status: 'failed' })).status, 200);
    const d = await claim(DB, xq());
    assert.equal(d.status, 409);
    assert.equal(d.body.error, 'attempt cap');
    assert.equal(d.body.row.attempts, 3, 'a refused claim writes nothing');
  });

  await t.test('R3 ok and empty are terminal: a claim on either is 409 terminal', async () => {
    const { DB } = await openDb();
    for (const st of ['ok', 'empty']) {
      const key = `xq:t-${st}:${DAY}`;
      assert.equal((await claim(DB, xq({ key }))).status, 201);
      assert.equal((await settle(DB, { key, status: st, input_toks: 10, output_toks: 2, cost_usd: 0.01 })).status, 200);
      const again = await claim(DB, xq({ key, max_attempts: 10 }));
      assert.equal(again.status, 409, `claim on ${st}`);
      assert.equal(again.body.error, 'terminal');
      assert.equal(again.body.status, st);
      assert.equal(again.body.row.attempts, 1);
    }
  });

  await t.test('R4 settle: only from claimed; ok fill-in; a different terminal is 409; a replay is 200', async () => {
    const { DB } = await openDb();
    await claim(DB, xq());
    const s = await settle(DB, { key: XQ, status: 'ok', input_toks: 1200, output_toks: 340, tool_calls: 2, cost_usd: 0.0123 });
    assert.equal(s.status, 200);
    assert.equal(s.body.row.status, 'ok');
    assert.equal(s.body.row.priced, 1);
    assert.equal(s.body.row.cost_usd, 0.0123);
    const f = await settle(DB, { key: XQ, status: 'failed' });
    assert.equal(f.status, 409, 'ok then failed is refused');
    const r = await settle(DB, { key: XQ, status: 'ok', cost_usd: 0.0123 });
    assert.equal(r.status, 200, 'a replay of ok is 200');
    assert.equal(r.body.row.cost_usd, 0.0123, 'a replay never adds the cost twice');
    assert.equal(r.body.row.priced, 1);
    const fill = await settle(DB, { key: XQ, status: 'ok', proposal_slug: 'archie-abc123' });
    assert.equal(fill.status, 200);
    assert.equal(fill.body.row.proposal_slug, 'archie-abc123');
    assert.equal(fill.body.row.input_toks, 1200, 'a fill-in keeps the usage');
    // failed (not claimed) -> ok is refused: a new attempt must claim first.
    const k2 = `xq:other:${DAY}`;
    await claim(DB, xq({ key: k2 }));
    await settle(DB, { key: k2, status: 'failed' });
    assert.equal((await settle(DB, { key: k2, status: 'ok' })).status, 409);
    // empty is terminal: an ok onto it is 409.
    const k3 = `xq:third:${DAY}`;
    await claim(DB, xq({ key: k3 }));
    await settle(DB, { key: k3, status: 'empty' });
    assert.equal((await settle(DB, { key: k3, status: 'ok' })).status, 409);
    assert.equal((await settle(DB, { key: k3, status: 'empty' })).status, 200);
  });

  await t.test('R5 refund hands the attempt back only for a call that billed nothing', async () => {
    const { DB } = await openDb();
    await claim(DB, xq());
    const r = await settle(DB, { key: XQ, status: 'failed', note: 'refused', refund: true });
    assert.equal(r.status, 200);
    assert.equal(r.body.row.attempts, 0);
    await claim(DB, xq());
    const bad = await settle(DB, { key: XQ, status: 'failed', note: 'http 500', refund: true });
    assert.equal(bad.status, 400, 'refund with any other note is refused');
    assert.equal(bad.body.error, 'refund');
    assert.equal((await settle(DB, { key: XQ, status: 'ok', refund: true, note: 'refused' })).status, 400);
  });

  await t.test('R6 spend: priced cost plus every unpriced attempt at the reserve', async () => {
    const { DB } = await openDb();
    const k1 = `xq:a:${DAY}`; const k2 = `xq:b:${DAY}`; const k3 = `wq:${DAY}`;
    await claim(DB, xq({ key: k1 }));
    await settle(DB, { key: k1, status: 'ok', cost_usd: 0.1 });
    await claim(DB, xq({ key: k2 }));
    await settle(DB, { key: k2, status: 'failed', note: 'transport' });   // unpriced
    await claim(DB, { key: k3, kind: 'webscan', source: 'web', day: DAY, max_attempts: 3 });  // in flight
    // an item row is not billable on its own: it never counts.
    await claim(DB, { key: 'x:111', kind: 'item', source: 'x', day: DAY, max_attempts: 3, url: 'https://x.com/u/status/111' });
    const s = await spend(DB, `day=${DAY}&reserve_usd=0.05`);
    assert.equal(s.status, 200);
    assert.equal(s.body.unpriced_attempts, 2);
    assert.equal(s.body.usd, 0.2);
    assert.equal(s.body.priced_usd, 0.1);
    const two = await spend(DB, `day=2026-10-05&reserve_usd=0.05`);
    assert.equal(two.body.usd, 0, 'another day is its own');
    assert.equal((await spend(DB, `day=${DAY}`)).status, 400, 'reserve_usd is required');
    assert.equal((await spend(DB, `day=${DAY}&reserve_usd=abc`)).status, 400);
    assert.equal((await spend(DB, `day=2026-13-40&reserve_usd=0.1`)).status, 400);
  });

  await t.test('R7 the exact 404 body, a 400 naming the field', async () => {
    const { DB } = await openDb();
    const r = await get(DB, `key=${encodeURIComponent('x:999')}`);
    assert.equal(r.status, 404);
    assert.deepEqual(r.body, { error: 'research item not found' });
    assert.equal((await settle(DB, { key: 'x:999', status: 'ok' })).status, 404);
    assert.equal((await claim(DB, { ...xq(), key: 'x:abc' })).body.error, 'key');
    assert.equal((await claim(DB, { ...xq(), kind: 'item' })).body.error, 'kind', 'kind must match the key prefix');
    assert.equal((await claim(DB, { ...xq(), day: '2026-02-30' })).body.error, 'day');
    assert.equal((await claim(DB, { ...xq(), max_attempts: 0 })).body.error, 'max_attempts');
    assert.equal((await settle(DB, { key: XQ, status: 'done' })).body.error, 'status');
    assert.equal((await settle(DB, { key: XQ, status: 'ok', cost_usd: -1 })).body.error, 'cost_usd');
    assert.equal((await settle(DB, { key: XQ, status: 'ok', score: 11 })).body.error, 'score');
  });

  await t.test('R8 list: a day range, filters, raw left out, truncated past 500', async () => {
    const { DB, db } = await openDb();
    await claim(DB, { key: 'x:1', kind: 'item', source: 'x', day: DAY, max_attempts: 3, url: 'https://x.com/a/status/1', title: 't1' });
    await settle(DB, { key: 'x:1', status: 'ok', applies: true, score: 8, why: 'fits', raw: '{"big":1}' });
    await claim(DB, { key: 'x:2', kind: 'item', source: 'x', day: '2026-09-20', max_attempts: 3 });
    const r = await get(DB, `from=2026-09-28&to=${DAY}&kind=item&status=ok`);
    assert.equal(r.status, 200);
    assert.equal(r.body.rows.length, 1);
    assert.equal(r.body.rows[0].dedupe_key, 'x:1');
    assert.equal(r.body.rows[0].applies, 1);
    assert.equal(r.body.rows[0].raw, undefined, 'raw stays out of the list');
    assert.equal(r.body.truncated, false);
    const ins = db.prepare(`INSERT INTO archie_research (dedupe_key, kind, source, status, attempts, day, created_at, updated_at)
                            VALUES (?, 'item', 'x', 'ok', 1, ?, 't', 't')`);
    for (let i = 100; i < 620; i++) ins.run(`x:${i}`, DAY);
    const big = await get(DB, `from=${DAY}&to=${DAY}`);
    assert.equal(big.body.rows.length, 500);
    assert.equal(big.body.truncated, true);
    assert.equal((await get(DB, `from=${DAY}`)).status, 400);
  });

  await t.test('R9 the schema: status CHECK, unique key, the seeds', async () => {
    const { db } = await openDb();
    assert.throws(() => db.prepare(`INSERT INTO archie_research (dedupe_key, kind, status, attempts, day, created_at, updated_at)
                                    VALUES ('x:5', 'item', 'done', 0, '${DAY}', 't', 't')`).run());
    db.prepare(`INSERT INTO archie_research (dedupe_key, kind, status, attempts, day, created_at, updated_at)
                VALUES ('x:6', 'item', 'ok', 0, '${DAY}', 't', 't')`).run();
    assert.throws(() => db.prepare(`INSERT INTO archie_research (dedupe_key, kind, status, attempts, day, created_at, updated_at)
                                    VALUES ('x:6', 'item', 'ok', 0, '${DAY}', 't', 't')`).run());
    const cap = db.prepare(`SELECT value FROM settings WHERE key='lane.archie-research.archie_research_usd_cap_day'`).get();
    // BH-4762 moved the seed from 1.00 to 3.00 (tests/archie-research-scout.bh-4762-test.sh C4).
    assert.equal(cap.value, '3.00');
    const att = db.prepare(`SELECT value FROM settings WHERE key='lane.archie-research.archie_research_max_attempts'`).get();
    assert.equal(att.value, '3');
    const route = (role) => db.prepare(`SELECT model, runner FROM model_routes WHERE project IS NULL AND role=? AND position=0`).get(role);
    assert.deepEqual({ ...route('stage.archie-research') }, { ...route('stage.execute') }, 'stage.archie-research copies stage.execute rung 0');
    assert.deepEqual({ ...route('archie-research.xsearch') }, { ...route('grok.default') }, 'archie-research.xsearch copies grok.default rung 0');
    assert.equal(route('archie-research.xsearch').runner, 'grok');
  });
});
