import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/cockpit/[[path]].js';

// BH-3971. `pr_closed` is reconcile's closed-unmerged terminal (HC-36/BH-866).
// It is finished, so it must leave the "moving" query (`stage NOT IN`), and it
// asks nothing of a human, so it stays off NEEDS (`stage IN`). Same D1 stub as
// cockpit-fn.bh-389.test.js; the assertion is on the values the queries bind.
function stubDb() {
  const seen = [];
  return {
    seen,
    prepare(sql) {
      const stmt = { binds: [] };
      stmt.bind = (...b) => { stmt.binds = b; return stmt; };
      stmt.all = async () => { seen.push({ sql, binds: stmt.binds }); return { results: [] }; };
      stmt.first = async () => { seen.push({ sql, binds: stmt.binds }); return null; };
      return stmt;
    }
  };
}

async function callNow(db) {
  const real = globalThis.fetch;
  globalThis.fetch = async () => new Response('', { status: 200 });
  try {
    return await onRequest({
      request: new Request('https://console.example.pages.dev/api/cockpit/now', {
        method: 'GET', headers: { cookie: 'dash=bh3971' }
      }),
      env: { CONSOLE_DB: db },
      params: { path: ['now'] }
    });
  } finally {
    globalThis.fetch = real;
  }
}

test('a pr_closed build is not counted as moving', async () => {
  const db = stubDb();
  const res = await callNow(db);
  assert.equal(res.status, 200);
  const active = db.seen.find((s) => /FROM builds/.test(s.sql) && /stage NOT IN/.test(s.sql));
  assert.ok(active, 'the /now activeBuilds query must run');
  assert.ok(active.binds.includes('pr_closed'), `exclude list: ${active.binds}`);
  assert.ok(active.binds.includes('pr_merged'));
});

test('and it does not ask for a human on NEEDS', async () => {
  const db = stubDb();
  await callNow(db);
  const needs = db.seen.filter((s) => /FROM builds WHERE merged = 0 AND stage IN/.test(s.sql));
  assert.ok(needs.length > 0, 'the NEEDS queries must run');
  for (const q of needs) assert.ok(!q.binds.includes('pr_closed'), `needs binds: ${q.binds}`);
});
