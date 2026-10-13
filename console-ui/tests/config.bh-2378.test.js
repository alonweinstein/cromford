import test from 'node:test';
import assert from 'node:assert/strict';

// BH-2378 (BH-2330.3): the /config list screen's pure half. Rows for the
// SETTINGS, FLAGS and RECENT CHANGES tables, the modal validators and the PUT
// bodies. Fixtures are the shapes GET /api/settings, GET /api/flags and GET
// /api/config-changes answer (worker/jobs/src/routes/settings.js, flags.js,
// config-changes.js).

const {
  settingRows, flagRows, recentChangeRows, validateValue, validateReason,
  settingPutBody, isLaneKey, laneKeyHref, RECENT_CHANGES_LIMIT
} = await import('../src/lib/config.js');

const s = (key, value = '1') => ({ key, value, note: null, actor: 'seed', updated_at: '2026-09-27T20:00:00Z' });
const SETTINGS = [
  s('routing_rows'), s('lib.call-guard.call_guard_stages'), s('merge-conductor.mode', 'auto'),
  s('lane.merge-conductor.mc_max_prs', '12'), s('hub.promote_enabled'), s('gh.quota.reserve', '600')
];
const NAMED = ['gh.quota.reserve', 'hub.promote_enabled', 'merge-conductor.mode', 'routing_rows'];

test('C1: settingRows sorts by key, hides lane/lib unless showLane, and a non-array is null', () => {
  const rows = settingRows(SETTINGS, '', false);
  assert.deepEqual(rows.map((r) => r.key), NAMED);
  assert.ok(rows.every((r) => r.editableHere === true));

  const all = settingRows(SETTINGS, '', true);
  assert.deepEqual(all.map((r) => r.key), [
    'gh.quota.reserve', 'hub.promote_enabled', 'lane.merge-conductor.mc_max_prs',
    'lib.call-guard.call_guard_stages', 'merge-conductor.mode', 'routing_rows'
  ]);
  const lane = all.find((r) => r.key === 'lane.merge-conductor.mc_max_prs');
  assert.equal(lane.editableHere, false);
  assert.equal(lane.href, '/settings/merge-conductor');
  const lib = all.find((r) => r.key === 'lib.call-guard.call_guard_stages');
  assert.equal(lib.editableHere, false);
  assert.equal(lib.href, '/settings');
  for (const k of NAMED) assert.equal(all.find((r) => r.key === k).editableHere, true, k);
  // merge-conductor.mode has no lane. prefix, so it stays editable here.
  assert.equal(isLaneKey('merge-conductor.mode'), false);
  assert.equal(isLaneKey('lane.merge-conductor.mode'), true);
  assert.equal(laneKeyHref('lane.a b.x'), '/settings/a%20b');

  assert.equal(settingRows(undefined, '', false), null);
  assert.equal(settingRows({ error: 'x' }, '', false), null);
  // The input is not mutated or re-ordered.
  assert.equal(SETTINGS[0].key, 'routing_rows');
});

test('C2: the filter is a case-insensitive substring on key', () => {
  assert.deepEqual(settingRows(SETTINGS, 'QUOTA', false).map((r) => r.key), ['gh.quota.reserve']);
  assert.deepEqual(settingRows(SETTINGS, '', false).map((r) => r.key), NAMED);
  assert.deepEqual(settingRows(SETTINGS, '  ', false).map((r) => r.key), NAMED);
  assert.deepEqual(settingRows(SETTINGS, 'nomatch', true), []);
});

test('C3: flagRows sorts by name, on = active 1, filters, and a non-array is null', () => {
  const f = (name, active) => ({ name, active, actor: 'console', reason: 'r', updated_at: '2026-09-27T20:00:00Z' });
  const rows = flagRows([f('pause-all', 0), f('all-off', 1), f('paused-project-3', '1')], '');
  assert.deepEqual(rows.map((r) => [r.name, r.on]), [['all-off', true], ['pause-all', false], ['paused-project-3', true]]);
  assert.deepEqual(flagRows([f('pause-all', 0), f('Paused-project-3', 1)], 'project-3').map((r) => r.name), ['Paused-project-3']);
  assert.equal(flagRows(null, ''), null);
  assert.equal(flagRows({ flags: [] }, ''), null);
});

test('C4: recentChangeRows keeps the newest 50, each linking to its history; a body without changes is null', () => {
  assert.equal(RECENT_CHANGES_LIMIT, 50);
  const changes = Array.from({ length: 60 }, (_, i) => ({ id: 60 - i, kind: i % 2 ? 'cost_cap' : 'setting', name: `n/${i}`, at: '2026-09-27T20:00:00Z' }));
  const out = recentChangeRows({ changes, truncated: false });
  assert.equal(out.rows.length, 50);
  assert.equal(out.truncated, true);
  assert.equal(out.rows[0].href, '/config/setting/n%2F0');
  assert.equal(out.rows[1].href, '/config/cost_cap/n%2F1');
  const small = recentChangeRows({ changes: changes.slice(0, 3), truncated: 'yes' });
  assert.equal(small.rows.length, 3);
  assert.equal(small.truncated, false, 'truthy-only is not truncated');
  assert.equal(recentChangeRows({ changes: changes.slice(0, 3), truncated: true }).truncated, true);
  assert.equal(recentChangeRows({ error: 'x' }), null);
  assert.equal(recentChangeRows(null), null);
});

test('C5: the validators refuse blank, multi-line and over-long input; the bodies carry no note', () => {
  for (const bad of ['', '   ', '\n', 'a\nb', 'a\rb', 'x'.repeat(257), undefined, null]) {
    const v = validateValue(bad);
    assert.equal(v.ok, false, JSON.stringify(bad));
    assert.ok(v.message, 'a refused value says why');
  }
  assert.deepEqual(validateValue(' 700 '), { ok: true, value: '700' });
  assert.equal(validateValue('x'.repeat(256)).ok, true);

  for (const bad of ['', '  ', 'x'.repeat(513), undefined]) {
    const r = validateReason(bad);
    assert.equal(r.ok, false, JSON.stringify(bad));
    assert.ok(r.message);
  }
  assert.deepEqual(validateReason(' raise it '), { ok: true, value: 'raise it' });

  const body = settingPutBody('k', 'v', 'r');
  assert.deepEqual(body, { key: 'k', value: 'v', reason: 'r', actor: 'console' });
  assert.equal('note' in body, false);
});
