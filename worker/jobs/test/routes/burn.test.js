import test from 'node:test';
import assert from 'node:assert/strict';
import { call, iso } from '../lib/harness.js';

// THE FIXTURES ARE RELATIVE TO NOW, NEVER A CALENDAR DATE (#360, BH-1261).
// These tests ask for a ROLLING window (?days=7) and then assert on the rows
// that come back. A fixture frozen at 2026-08-27 falls out of that window the
// moment the clock passes 2026-09-03, and the suite goes red on a date nobody
// chose — that is the #360 failure verbatim, and catalog/determinism-lint.conf
// names it. `iso` is the harness's single anchored clock read, the same one
// worker/jobs/test/dora.test.js builds its fixtures off.
const DAYS = 86400e3;
const dayAgo = (n) => iso(n * DAYS).slice(0, 10);   // the YYYY-MM-DD n days back

test('burn clamps its window and reports the window it actually used', async () => {
  const state = { burn: [{ day: dayAgo(2), project: 'project-3', kind: 'build', jobs: 2, spent_usd: 10 }] };
  const wide = await call('/api/burn?days=9999', { state });
  assert.equal(wide.body.days, 90);
  const narrow = await call('/api/burn?days=0', { state });
  assert.equal(narrow.body.days, 14);          // 0 is not a window, it is a missing one
  const ok = await call('/api/burn?days=7', { state });
  assert.equal(ok.body.days, 7);
  assert.equal(ok.body.burn.length, 1);
  assert.match(ok.body.since, /^\d{4}-\d{2}-\d{2}T/);
});

test('GET /api/burn and GET /api/metrics/burn are different questions', async () => {
  // /api/burn is the coordination DB's view of CLAIMED job spend; burn_days is
  // the orchestrator's whole API-equivalent burn. Two different numbers sharing
  // one route is how a reader concludes the ledger is wrong.
  const claimed = await call('/api/burn?days=7', { state: { burn: [{ day: dayAgo(2), spent_usd: 12 }] } });
  assert.equal(claimed.status, 200);
  assert.ok(Array.isArray(claimed.body.burn));
  const daily = await call('/api/metrics/burn?days=7', { state: { burnDays: [{ day: dayAgo(2), usd_equiv: 134.62 }] } });
  assert.equal(daily.status, 200);
  assert.equal(daily.body.burn_days[0].usd_equiv, 134.62);
});
