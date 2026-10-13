import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/cockpit/[[path]].js';

// BH-389. A PR the blocked-resolver closed unmerged moves its build row to
// `superseded` or `abandoned`. Both are terminal: the row must leave "building
// now" (the `stage NOT IN` exclude list) and must not ask for a human on NEEDS
// (the `stage IN` list). The D1 is stubbed the same way cockpit-fn.test.js
// does it, and the assertion is on the values the queries actually bind.
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
        method: 'GET', headers: { cookie: 'dash=bh389' }
      }),
      env: { CONSOLE_DB: db },
      params: { path: ['now'] }
    });
  } finally {
    globalThis.fetch = real;
  }
}

test('superseded and abandoned builds are not "building now"', async () => {
  const db = stubDb();
  const res = await callNow(db);
  assert.equal(res.status, 200);
  const active = db.seen.find((s) => /FROM builds/.test(s.sql) && /stage NOT IN/.test(s.sql));
  assert.ok(active, 'the /now activeBuilds query must run');
  assert.ok(active.binds.includes('superseded'), `exclude list: ${active.binds}`);
  assert.ok(active.binds.includes('abandoned'), `exclude list: ${active.binds}`);
  // The guard: the list still carries the stages it had.
  assert.ok(active.binds.includes('pr_merged'));
});

test('and they do not ask for a human on NEEDS', async () => {
  const db = stubDb();
  await callNow(db);
  const needs = db.seen.filter((s) => /FROM builds WHERE merged = 0 AND stage IN/.test(s.sql));
  for (const q of needs) {
    assert.ok(!q.binds.includes('superseded') && !q.binds.includes('abandoned'), `needs binds: ${q.binds}`);
  }
});
