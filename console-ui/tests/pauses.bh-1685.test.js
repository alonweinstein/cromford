import test from 'node:test';
import assert from 'node:assert/strict';
import {
  shapePauses, pausesForProject, endCommandFor, pauseCommandFor, PAUSE_WHATS
} from '../src/lib/pauses.js';

// BH-1685 (BH-1672.4). The pause rows the console reads from
// GET /api/coord/pauses?active=1, shaped for the Fleet banner and FLAGS tags.
// The worker filters on active=1, but a row it lists can still be past its
// expires_at by the time the page renders it, and the box lib
// (bin/lib/pause.sh) says an unparseable expiry is not live — so the shaper
// says the same thing, against a clock the test fixes.

const now = Date.parse('2026-09-24T12:00:00Z');
const iso = (minFromNow) => new Date(now + minFromNow * 60000).toISOString();

const row = (over = {}) => ({
  id: 1, scope: 'project-3', what: 'merges', reason: 'release freeze', actor: 'console',
  created_at: iso(-90), expires_at: iso(30), ended_at: null, end_reason: null, ...over
});

test('a live row gains ageMin, expiresInMin and scopeLabel', () => {
  const { rows, truncated } = shapePauses({ pauses: [row()], truncated: false }, now);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].ageMin, 90);
  assert.equal(rows[0].expiresInMin, 30);
  assert.equal(rows[0].scopeLabel, 'project-3');
  assert.equal(rows[0].reasonText, 'release freeze');
  assert.equal(truncated, false);
});

test('a row the worker listed but whose expiry has passed is dropped', () => {
  const { rows } = shapePauses({ pauses: [row({ expires_at: iso(-1) }), row({ id: 2 })] }, now);
  assert.deepEqual(rows.map((r) => r.id), [2]);
});

test('an expiry exactly at now is not live', () => {
  const { rows } = shapePauses({ pauses: [row({ expires_at: iso(0) })] }, now);
  assert.equal(rows.length, 0);
});

test('an ended row is dropped', () => {
  const { rows } = shapePauses({ pauses: [row({ ended_at: iso(-5) })] }, now);
  assert.equal(rows.length, 0);
});

test('an unparseable or missing expiry is not live', () => {
  const { rows } = shapePauses({ pauses: [row({ expires_at: 'soon' }), row({ expires_at: null })] }, now);
  assert.equal(rows.length, 0);
});

test('a null or garbage payload is no rows, never a crash', () => {
  assert.deepEqual(shapePauses(null, now), { rows: [], truncated: false });
  assert.deepEqual(shapePauses({ pauses: 'x' }, now), { rows: [], truncated: false });
  assert.deepEqual(shapePauses(undefined, now), { rows: [], truncated: false });
});

test('truncated is only true when the worker said so', () => {
  assert.equal(shapePauses({ pauses: [row()], truncated: true }, now).truncated, true);
  assert.equal(shapePauses({ pauses: [row()] }, now).truncated, false);
});

test('a missing, empty or blank reason reads "no reason given"', () => {
  for (const reason of [null, '', '  ', undefined]) {
    const { rows } = shapePauses({ pauses: [row({ reason })] }, now);
    assert.equal(rows[0].reasonText, 'no reason given', `reason=${JSON.stringify(reason)}`);
  }
  assert.equal(shapePauses({ pauses: [row({ reason: '  spaced  ' })] }, now).rows[0].reasonText, 'spaced');
});

test('an unparseable created_at is an unknown age, never zero', () => {
  const { rows } = shapePauses({ pauses: [row({ created_at: 'nope' })] }, now);
  assert.equal(rows[0].ageMin, null);
});

test('expiresInMin rounds up, so a live row never reads as expiring now', () => {
  const r = row({ expires_at: new Date(now + 10 * 1000).toISOString() });
  assert.equal(shapePauses({ pauses: [r] }, now).rows[0].expiresInMin, 1);
});

test('fleet scope is labelled as covering every project', () => {
  const { rows } = shapePauses({ pauses: [row({ scope: 'fleet' })] }, now);
  assert.equal(rows[0].scopeLabel, 'FLEET (all projects)');
});

test('pausesForProject includes fleet rows and excludes another project', () => {
  const { rows } = shapePauses({
    pauses: [
      row({ id: 1, scope: 'project-3', what: 'merges' }),
      row({ id: 2, scope: 'fleet', what: 'builds' }),
      row({ id: 3, scope: 'project-5', what: 'reviews' })
    ]
  }, now);
  assert.deepEqual(pausesForProject(rows, 'project-3').map((r) => r.id), [2, 1], 'sorted by what');
  assert.deepEqual(pausesForProject(rows, 'project-5').map((r) => r.id), [2, 3]);
  assert.deepEqual(pausesForProject(rows, 'other').map((r) => r.id), [2]);
  assert.deepEqual(pausesForProject(undefined, 'other'), []);
});

test('endCommandFor: a project triage row resumes the board, so flag and row clear together', () => {
  assert.deepEqual(endCommandFor(row({ id: 7, what: 'triage' })), { type: 'resume_board', project: 'project-3' });
});

test('endCommandFor: any other project row ends that row by id', () => {
  assert.deepEqual(endCommandFor(row({ id: 8, what: 'merges' })), { type: 'pause_end', id: 8, project: 'project-3' });
});

// A fleet row has no project to key the command on, so it names its scope and
// the console's action endpoint routes it to the hub (cromford-console,
// applyAction). A bare {type, id} reached that endpoint with no project at all.
test('endCommandFor: a fleet row ends by id and names the fleet scope, never a project', () => {
  assert.deepEqual(endCommandFor(row({ id: 9, scope: 'fleet', what: 'triage' })), { type: 'pause_end', id: 9, scope: 'fleet' });
});

test('pauseCommandFor: triage with a blank ttl is today\'s pause_board, worker default ttl', () => {
  assert.deepEqual(pauseCommandFor('project-3', { what: 'triage', reason: 'deploy', ttlS: '' }),
    { type: 'pause_board', project: 'project-3', reason: 'deploy' });
});

test('pauseCommandFor: merges with a ttl is pause_set carrying ttl_s as a number', () => {
  assert.deepEqual(pauseCommandFor('project-3', { what: 'merges', reason: 'x', ttlS: '3600' }),
    { type: 'pause_set', project: 'project-3', what: 'merges', reason: 'x', ttl_s: 3600 });
});

// The worker 400s a blank reason (#1874, PUT /api/pauses "reason required"),
// so the form must not send one: the PAUSE button stays disabled until a
// reason is typed, and this is the backstop behind it.
test('pauseCommandFor: a missing or blank reason is refused, for every what', () => {
  for (const what of PAUSE_WHATS) {
    for (const reason of [undefined, null, '', '   ', '\n\t']) {
      const out = pauseCommandFor('project-3', { what, reason, ttlS: '' });
      assert.equal(out.error, 'reason required', `what=${what} reason=${JSON.stringify(reason)}`);
      assert.equal(out.type, undefined);
    }
  }
});

test('pauseCommandFor: a supplied reason is sent trimmed', () => {
  assert.deepEqual(pauseCommandFor('project-3', { what: 'reviews', reason: '  freeze  ', ttlS: '' }),
    { type: 'pause_set', project: 'project-3', what: 'reviews', reason: 'freeze' });
});

test('pauseCommandFor: a bad ttl is refused, never clamped', () => {
  for (const ttlS of ['-5', '1.5', 'abc', '0', '1e3', '3600 x']) {
    const out = pauseCommandFor('project-3', { what: 'merges', reason: 'x', ttlS });
    assert.ok(out.error, `ttlS=${ttlS} must be refused, got ${JSON.stringify(out)}`);
    assert.equal(out.type, undefined);
  }
});

test('pauseCommandFor: an unknown what is refused', () => {
  for (const what of ['bogus', 'all', '', 'MERGES']) {
    const out = pauseCommandFor('project-3', { what, reason: '', ttlS: '' });
    assert.ok(out.error, `what=${what}`);
  }
});

test('PAUSE_WHATS mirrors the contract enum', () => {
  assert.deepEqual([...PAUSE_WHATS].sort(), ['builds', 'merges', 'reviews', 'triage']);
});
