// BH-3777: the paused hold for NEEDS_HUMAN_VERDICT, driven through the REAL
// router. In observe or kill-switch mode mc_stuck_check and mc_budget_check
// call mc_hold_page, which PUTs /api/conductor/held with the row's state. The
// route validates `state` against a literal copy of bin/lib/mc/log.sh
// MC_STATES; a state missing from that copy answers 400 and the page is neither
// held nor sent. So this suite holds a NEEDS_HUMAN_VERDICT STUCK page, and pins
// that every MC_STATES word is accepted, so the copy cannot fall behind again.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
const LOG_SH = readFileSync(
  fileURLToPath(new URL('../../../bin/lib/mc/log.sh', import.meta.url)), 'utf8');

const call = (DB, path, { method = 'GET', body } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};

const NHV = {
  repo: 'example-org/cromford',
  number: 3758,
  state: 'NEEDS_HUMAN_VERDICT',
  head: 'b'.repeat(40),
  kind: 'STUCK',
  text: 'stuck in NEEDS_HUMAN_VERDICT: bin/lead-verdict.sh post example-org/cromford 3758 '
    + 'b'.repeat(40) + ' MERGE --source human',
  mode: 'observe',
};

test('BH-3777 conductor held pages accept NEEDS_HUMAN_VERDICT', async (t) => {
  const fx = await openDb();
  if (fx === null) {
    t.skip('node:sqlite unavailable in this runtime');
    return;
  }

  await t.test('a NEEDS_HUMAN_VERDICT STUCK page is held, listed and released', async () => {
    const put = await call(fx.DB, '/api/conductor/held', { method: 'PUT', body: NHV });
    assert.equal(put.status, 200, JSON.stringify(put.body));
    const rows = fx.db.prepare(
      'SELECT state, kind, text, mode FROM conductor_held_pages WHERE repo=? AND number=?'
    ).all(NHV.repo, NHV.number);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].state, 'NEEDS_HUMAN_VERDICT');
    assert.equal(rows[0].kind, 'STUCK');
    assert.match(rows[0].text, /--source human/);

    const list = await call(fx.DB, '/api/conductor/held');
    assert.equal(list.status, 200);
    assert.ok(JSON.stringify(list.body).includes('NEEDS_HUMAN_VERDICT'),
      'the held list must carry the NEEDS_HUMAN_VERDICT hold');

    const { text, mode, ...key } = NHV;
    const rel = await call(fx.DB, '/api/conductor/held/release',
      { method: 'POST', body: { ...key, why: 'BH-3777 test release' } });
    assert.equal(rel.status, 200, JSON.stringify(rel.body));
    assert.equal(rel.body.released, 1, 'the held NEEDS_HUMAN_VERDICT row must be the one released');
  });

  await t.test('every MC_STATES word is a state the route accepts (BUDGET too)', async () => {
    const m = LOG_SH.match(/^MC_STATES="([^"]+)"/m);
    assert.ok(m, 'bin/lib/mc/log.sh must define MC_STATES');
    const states = m[1].trim().split(/\s+/);
    assert.ok(states.includes('NEEDS_HUMAN_VERDICT'));
    for (const state of states) {
      const res = await call(fx.DB, '/api/conductor/held', {
        method: 'PUT',
        body: { ...NHV, number: 9000 + states.indexOf(state), state, kind: 'BUDGET' },
      });
      assert.equal(res.status, 200, `${state}: ${JSON.stringify(res.body)}`);
    }
  });
});
