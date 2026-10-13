import test from 'node:test';
import assert from 'node:assert/strict';
import { api } from '../src/api.js';
import { backupBadge } from '../src/lib/backups.js';
import { sortRows } from '../src/lib/sort.js';
import {
  leaseView, roleView, backupEntry, backupRows, promoteTargets, promoteFormState,
  promoteBody, promoteOutcome, promoteResult, loadError, createLoader, STANDBY_NONE
} from '../src/lib/hub.js';

// BH-1945 (BH-1909.3): the pure half of the HUB screen. The fixture is the
// GET /api/hub/recovery answer exactly as worker/jobs/src/routes/hub-recovery.js
// documents it, with box_status.backup_* verbatim (TEXT columns: backup_ts ''
// means never stamped, backup_off 'off', backup_unconfigured 'unconfigured').

const NOW = Date.parse('2026-09-24T15:00:00Z');

const RECOVERY = {
  lease: { holder: 'hub-1', epoch: 7, expires_at: '2026-09-24T15:01:30Z', updated_at: '2026-09-24T14:59:30Z', live: true },
  role: { active: 'hub-1', standby: [] },
  backups: [
    { box: 'hub-1', backup_ts: '2026-09-24T14:48:00Z', backup_off: null, backup_unconfigured: null, backup_reported_at: '2026-09-24T14:50:00Z' },
    { box: 'box-off', backup_ts: '', backup_off: 'off', backup_unconfigured: null, backup_reported_at: '2026-09-24T14:50:00Z' },
    { box: 'box-unconf', backup_ts: '', backup_off: null, backup_unconfigured: 'unconfigured', backup_reported_at: '2026-09-24T14:50:00Z' },
    { box: 'box-missing', backup_ts: '', backup_off: null, backup_unconfigured: null, backup_reported_at: '2026-09-24T14:50:00Z' },
    { box: 'box-silent', backup_ts: null, backup_off: null, backup_unconfigured: null, backup_reported_at: null },
    { box: 'box-garbled', backup_ts: 'not-a-date', backup_off: null, backup_unconfigured: null, backup_reported_at: '2026-09-24T14:50:00Z' },
  ]
};

test('C3-T1 backupRows maps each stamp to the state backupBadge reads, and the badge is backupBadge\'s own', () => {
  const rows = backupRows(RECOVERY, NOW);
  assert.deepEqual(rows.map((r) => [r.box, r.state]), [
    ['hub-1', 'ok'], ['box-off', 'off'], ['box-unconf', 'unconfigured'],
    ['box-missing', 'missing'], ['box-silent', 'unknown'], ['box-garbled', 'unknown'],
  ]);
  for (const [i, r] of rows.entries()) {
    assert.deepEqual(r.badge, backupBadge(backupEntry(RECOVERY.backups[i], NOW)), r.box);
  }
  assert.equal(rows[0].ageMin, 12);
  assert.equal(rows[0].badge.text, 'backup 12m');
  // No age is invented for a row that has none (D11).
  assert.deepEqual(rows.slice(1).map((r) => r.ageMin), [null, null, null, null, null]);
  assert.equal(rows[3].badge.badge, 'NO BACKUP');
  // A box that never reported is silence, not "no backup".
  assert.equal(rows[4].badge.badge, null);
  assert.equal(rows[4].reportedMin, null);
  assert.equal(rows[1].reportedMin, 10);
});

test('backupEntry: off beats unconfigured beats a stamp; an empty stamp is only "missing" for a box that reported', () => {
  assert.deepEqual(backupEntry({ backup_ts: '2026-09-24T14:48:00Z', backup_off: 'off', backup_unconfigured: 'unconfigured' }, NOW), { state: 'off' });
  assert.deepEqual(backupEntry({ backup_ts: '2026-09-24T14:48:00Z', backup_unconfigured: 'unconfigured' }, NOW), { state: 'unconfigured' });
  assert.deepEqual(backupEntry({ backup_ts: '2026-09-24T14:48:00Z', backup_reported_at: null }, NOW), { state: 'ok', backup_age_min: 12 });
  assert.deepEqual(backupEntry({ backup_ts: '', backup_reported_at: '' }, NOW), { state: 'unknown' });
  assert.deepEqual(backupEntry(null, NOW), { state: 'unknown' });
});

test('backupRows passes the payload\'s stale threshold through, and a non-array backups is no rows', () => {
  const stale = backupRows({ ...RECOVERY, backup_stale_min: 5 }, NOW);
  assert.equal(stale[0].badge.badge, 'STALE');
  assert.equal(backupRows(RECOVERY, NOW)[0].badge.badge, null);
  assert.deepEqual(backupRows({ backups: null }, NOW), []);
  assert.deepEqual(backupRows(null, NOW), []);
});

test('sorting backupRows by AGE sinks the rows with no age in both directions', () => {
  const rows = backupRows({ backups: [
    RECOVERY.backups[4],
    { ...RECOVERY.backups[0], box: 'a', backup_ts: '2026-09-24T14:00:00Z' },
    RECOVERY.backups[1],
    { ...RECOVERY.backups[0], box: 'b', backup_ts: '2026-09-24T14:55:00Z' },
  ] }, NOW);
  const asc = sortRows(rows, (r) => r.ageMin, 'asc').map((r) => r.box);
  const desc = sortRows(rows, (r) => r.ageMin, 'desc').map((r) => r.box);
  assert.deepEqual(asc, ['b', 'a', 'box-silent', 'box-off']);
  assert.deepEqual(desc, ['a', 'b', 'box-silent', 'box-off']);
});

test('C3-T1 roleView: standby null and [] both say none recorded; a lease that is not live names its holder as expired', () => {
  assert.equal(STANDBY_NONE, 'Standby: none recorded (#401)');
  const empty = roleView(RECOVERY, NOW);
  assert.equal(empty.active, 'hub-1');
  assert.equal(empty.standbyNote, STANDBY_NONE);
  assert.equal(empty.expiredHolder, null);
  assert.equal(roleView({ ...RECOVERY, role: { active: 'hub-1', standby: null } }, NOW).standbyNote, STANDBY_NONE);
  assert.equal(roleView({ ...RECOVERY, role: { active: 'hub-1' } }, NOW).standbyNote, STANDBY_NONE);
  const two = roleView({ ...RECOVERY, role: { active: 'hub-1', standby: ['hub-2', 'hub-3'] } }, NOW);
  assert.deepEqual(two.standby, ['hub-2', 'hub-3']);
  assert.equal(two.standbyNote, null);
  const dead = roleView({ ...RECOVERY, lease: { ...RECOVERY.lease, live: false }, role: { active: null, standby: [] } }, NOW);
  assert.equal(dead.expiredHolder, 'hub-1');
  assert.equal(dead.active, null);
});

test('leaseView: remaining seconds from expires_at, expired when not live or run out, null for no lease', () => {
  assert.deepEqual(leaseView(RECOVERY.lease, NOW), { holder: 'hub-1', epoch: 7, expiresAt: '2026-09-24T15:01:30Z', remainingS: 90, expired: false });
  assert.equal(leaseView({ ...RECOVERY.lease, live: false }, NOW).expired, true);
  const out = leaseView({ ...RECOVERY.lease, expires_at: '2026-09-24T14:00:00Z' }, NOW);
  assert.equal(out.remainingS, 0);
  assert.equal(out.expired, true);
  // An unparseable expiry is unknown, never 0 by coercion (D11).
  const bad = leaseView({ ...RECOVERY.lease, expires_at: '' }, NOW);
  assert.equal(bad.remainingS, null);
  assert.equal(bad.expired, false);
  assert.equal(leaseView(null, NOW), null);
});

test('promoteTargets: every reported box except the current holder', () => {
  assert.deepEqual(promoteTargets(RECOVERY), ['box-off', 'box-unconf', 'box-missing', 'box-silent', 'box-garbled']);
  assert.deepEqual(promoteTargets({ lease: null, backups: [] }), []);
});

test('C3-T2 the typed-confirm gate refuses every near miss and opens only on the exact name with a reason', () => {
  const targets = ['hub-1', 'hub-2', 'hub-22'];
  const blocked = [
    { target: 'hub-2', typed: 'hub-2 ', reason: 'drill' },
    { target: 'hub-2', typed: ' hub-2', reason: 'drill' },
    { target: 'hub-2', typed: 'HUB-2', reason: 'drill' },
    { target: 'hub-2', typed: 'hub-', reason: 'drill' },
    { target: 'hub-2', typed: 'hub-22', reason: 'drill' },
    { target: 'hub-2', typed: 'hub-1', reason: 'drill' },
    { target: '', typed: '', reason: 'drill' },
    { target: 'hub-2', typed: 'hub-2', reason: '' },
    { target: 'hub-2', typed: 'hub-2', reason: '   ' },
    { target: 'hub-9', typed: 'hub-9', reason: 'drill' },
  ];
  for (const f of blocked) {
    const s = promoteFormState(f, targets);
    assert.equal(s.blocked, true, JSON.stringify(f));
    assert.ok(s.hint, `no hint for ${JSON.stringify(f)}`);
  }
  assert.deepEqual(promoteFormState({ target: 'hub-2', typed: 'hub-2', reason: 'drill' }, targets), { blocked: false, hint: null });
});

test('C3-T2 promoteBody is the contract body, and api.promoteHub POSTs it verbatim to the coord proxy', async () => {
  assert.deepEqual(promoteBody('hub-2', 7, ' drill '),
    { target: 'hub-2', expected_epoch: 7, actor: 'console', reason: 'drill', confirm: true });
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), method: init.method, body: init.body });
    return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true }) };
  };
  await api.promoteHub(promoteBody('hub-2', 7, ' drill '));
  assert.equal(calls.length, 1);
  assert.equal(calls[0].method, 'POST');
  assert.equal(calls[0].url, '/api/coord/hub/promote');
  assert.deepEqual(JSON.parse(calls[0].body), { target: 'hub-2', expected_epoch: 7, actor: 'console', reason: 'drill', confirm: true });
});

const httpErr = (status, body) => Object.assign(new Error(body && body.error ? body.error : `http_${status}`), { status, body });

test('promoteOutcome: 409 stale_epoch is the exact ticket sentence, and only stale_epoch says the lease moved', () => {
  assert.equal(promoteOutcome(httpErr(409, { error: 'stale_epoch', lease: { holder: 'hub-2', epoch: 8 } })),
    'The lease moved since you loaded this page (now epoch 8 held by hub-2). Reload and check before promoting.');
  assert.equal(promoteOutcome(httpErr(409, { error: 'stale_epoch' })),
    'The lease moved since you loaded this page. Reload and check before promoting.');
  assert.equal(promoteOutcome(httpErr(409, { error: 'stale_epoch', lease: null })),
    'The lease moved since you loaded this page. Reload and check before promoting.');
  const other = promoteOutcome(httpErr(409, { error: 'other' }));
  assert.doesNotMatch(other, /moved/);
  assert.equal(other, 'Promote refused: other (http 409). Nothing was changed.');
  assert.equal(promoteOutcome(httpErr(405, null)), 'The console proxy does not allow promote yet (405). Nothing was changed.');
  assert.equal(promoteOutcome(httpErr(501, { error: 'not_implemented' })), 'Promote is not deployed yet (501). Nothing was changed.');
  assert.equal(promoteOutcome(httpErr(400, { error: 'unknown_box' })), 'Promote refused: unknown_box (http 400). Nothing was changed.');
  // Past the refusals the contract lists, nothing is known about the write.
  assert.equal(promoteOutcome(httpErr(500, { error: 'boom' })), 'Promote failed: boom (http 500). Reload to check the lease before trying again.');
  assert.equal(promoteOutcome(new Error('network unreachable')), 'Promote result unknown: network unreachable. Reload to check the lease before trying again.');
});

test('promoteResult: success only on ok:true, and it names before and after only when the answer carries them', () => {
  assert.deepEqual(promoteResult({ ok: true, before: { holder: 'hub-1', epoch: 7 }, after: { holder: 'hub-2', epoch: 8 } }),
    { ok: true, text: 'Promoted: hub-1@7 → hub-2@8' });
  assert.deepEqual(promoteResult({ ok: true }), { ok: true, text: 'Promoted. Reload shows the new lease.' });
  assert.equal(promoteResult({ ok: false }).ok, false);
  assert.equal(promoteResult(null).ok, false);
});

test('loadError: a 501 says not deployed; anything else is its own message', () => {
  assert.equal(loadError(httpErr(501, { error: 'not_implemented' })), 'The hub recovery API is not deployed yet (501).');
  assert.equal(loadError(new Error('network unreachable')), 'network unreachable');
});

test('createLoader drops a superseded answer that lands late and aborts its signal', async () => {
  const pending = [];
  const fetcher = (signal) => new Promise((resolve) => pending.push({ resolve, signal }));
  const states = [];
  const load = createLoader(fetcher, (s) => states.push(s), () => 1000);
  const first = load();
  const second = load();
  await Promise.resolve();
  await Promise.resolve();
  assert.equal(pending.length, 2);
  assert.equal(pending[0].signal.aborted, true);
  assert.equal(pending[1].signal.aborted, false);
  pending[1].resolve({ n: 2 });
  await second;
  pending[0].resolve({ n: 1 });
  await first;
  const withData = states.filter((s) => 'data' in s && s.data);
  assert.deepEqual(withData, [{ data: { n: 2 }, error: null, loading: false, fetchedAt: 1000 }]);
});

test('createLoader reports a failure as an error, not as data', async () => {
  const states = [];
  const err = httpErr(501, { error: 'not_implemented' });
  await createLoader(async () => { throw err; }, (s) => states.push(s), () => 5)();
  assert.deepEqual(states.at(-1), { data: null, error: err, loading: false, fetchedAt: 5 });
});
