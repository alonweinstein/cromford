import test from 'node:test';
import assert from 'node:assert/strict';
import { h } from 'preact';
import { render } from 'preact-render-to-string';

// BH-5000 (BH-4951.1): the STATE PATHS panel on /settings — which store each
// coordination path decides from (file, rows, shadow), read-only. The pure
// table is driven directly, the view is rendered server-side for each state,
// and the hub tab of the real SettingsView is rendered to prove the mount.

globalThis.window = globalThis.window || { dispatchEvent() {}, addEventListener() {}, removeEventListener() {} };

const { STATE_PATHS, STATE_PATH_KNOBS, pathModes } = await import('../src/lib/state-path-modes.js');
const { StatePathModesView } = await import('../src/ui/StatePathModes.js');
const { SettingsView } = await import('../src/screens/Settings.js');

const T = '2026-10-07T00:00:00Z';
const okRes = (data) => ({ data, error: null, loading: false, reload() {} });
const errRes = (msg = 'boom') => ({ data: null, error: new Error(msg), loading: false, reload() {} });
const flagsRes = (flags) => okRes({ flags, as_of: T });
const flag = (name, active) => ({ name, active, reason: null, actor: 'hub', updated_at: T });
const setting = (value) => okRes({ setting: value === undefined ? null : { key: 'k', value, updated_at: T }, source: value === undefined ? 'none' : 'settings' });
const knobs = (values = {}) => Object.fromEntries(STATE_PATH_KNOBS.map((k) => [k, setting(k in values ? values[k] : '0')]));
const modeOf = (r, name) => r.rows.find((x) => x.name === name);

test('M6 the order and names are the ticket\'s list; flags and knobs are split right', () => {
  assert.deepEqual(STATE_PATHS.map((p) => p.name), [
    'pr-state-rows', 'no-twin-ledgers',
    'build_queue_rows_only', 'merge_queue_rows_only', 'deploy_queue_rows', 'ready_queue_rows',
    'alerts-db', 'closeout_aged_table'
  ]);
  assert.deepEqual(STATE_PATHS.filter((p) => p.kind === 'flag').map((p) => p.name), ['pr-state-rows', 'no-twin-ledgers', 'alerts-db']);
  assert.deepEqual(STATE_PATH_KNOBS, ['build_queue_rows_only', 'merge_queue_rows_only', 'deploy_queue_rows', 'ready_queue_rows', 'closeout_aged_table']);
  assert.ok(Object.isFrozen(STATE_PATHS));
  assert.match(modeOf({ rows: STATE_PATHS }, 'alerts-db').note, /ALERTS_DB_ENABLED/);
});

test('M1 everything off is file on every path', () => {
  const r = pathModes(flagsRes([flag('pr-state-rows', 0), flag('alerts-db', 0)]), knobs());
  assert.equal(r.rows.length, STATE_PATHS.length);
  assert.deepEqual(r.rows.map((x) => x.mode), Array(STATE_PATHS.length).fill('file'));
  assert.deepEqual(r.failed, []);
  assert.equal(modeOf(r, 'pr-state-rows').source, 'row active=0');
  assert.equal(modeOf(r, 'no-twin-ledgers').source, 'no row');
  assert.equal(modeOf(r, 'build_queue_rows_only').source, 'setting=0');
});

test('M2 pr-state-rows active=1 is rows, with the row\'s time', () => {
  const r = pathModes(flagsRes([flag('pr-state-rows', 1)]), knobs());
  assert.equal(modeOf(r, 'pr-state-rows').mode, 'rows');
  assert.equal(modeOf(r, 'pr-state-rows').source, 'row active=1');
  assert.equal(modeOf(r, 'pr-state-rows').updated_at, T);
  // a string "1" from the worker reads the same
  assert.equal(modeOf(pathModes(flagsRes([flag('pr-state-rows', '1')]), knobs()), 'pr-state-rows').mode, 'rows');
});

test('M3 no-twin-ledgers active=1 is shadow: the file is still read first', () => {
  const r = pathModes(flagsRes([flag('no-twin-ledgers', 1), flag('alerts-db', 1)]), knobs());
  assert.equal(modeOf(r, 'no-twin-ledgers').mode, 'shadow');
  assert.equal(modeOf(r, 'alerts-db').mode, 'rows');
});

test('M4 a failed flags read is unread on the three flags, never file; the knobs are untouched', () => {
  const r = pathModes(errRes('worker down'), knobs({ merge_queue_rows_only: '1' }));
  for (const p of STATE_PATHS.filter((x) => x.kind === 'flag')) {
    assert.equal(modeOf(r, p.name).mode, 'unread', p.name);
    assert.equal(modeOf(r, p.name).source, 'read failed: worker down');
  }
  assert.equal(modeOf(r, 'merge_queue_rows_only').mode, 'rows');
  assert.equal(modeOf(r, 'build_queue_rows_only').mode, 'file');
  assert.deepEqual(r.failed, ['flags']);
  // an answer with no flags array is a failed read too, and so is a flag row with no readable active
  assert.equal(modeOf(pathModes(okRes({}), knobs()), 'pr-state-rows').mode, 'unread');
  assert.equal(modeOf(pathModes(flagsRes([flag('pr-state-rows', null)]), knobs()), 'pr-state-rows').mode, 'unread');
});

test('M5 a knob goes through rowsOnlyState: " Yes " is rows, no row is file (box env), a failed read is unread', () => {
  const s = knobs({ merge_queue_rows_only: ' Yes ' });
  s.deploy_queue_rows = setting(undefined);
  s.ready_queue_rows = errRes('502');
  const r = pathModes(flagsRes([]), s);
  assert.equal(modeOf(r, 'merge_queue_rows_only').mode, 'rows');
  assert.equal(modeOf(r, 'merge_queue_rows_only').source, 'setting= Yes ');
  assert.equal(modeOf(r, 'deploy_queue_rows').mode, 'file');
  assert.equal(modeOf(r, 'deploy_queue_rows').source, 'no row (box env decides)');
  assert.equal(modeOf(r, 'ready_queue_rows').mode, 'unread');
  assert.equal(modeOf(r, 'ready_queue_rows').source, 'read failed: 502');
  assert.deepEqual(r.failed, ['ready_queue_rows']);
  // a knob nobody fetched is unread, never file
  assert.equal(modeOf(pathModes(flagsRes([]), {}), 'closeout_aged_table').mode, 'unread');
});

test('V1 the view links every path to its config page and shows the mode', () => {
  const out = render(h(StatePathModesView, { flags: flagsRes([flag('pr-state-rows', 1)]), settings: knobs() }));
  assert.ok(out.includes('href="/config/flag/pr-state-rows"'));
  assert.ok(out.includes('href="/config/setting/merge_queue_rows_only"'));
  for (const p of STATE_PATHS) assert.ok(out.includes(`href="/config/${p.kind}/${p.name}"`), p.name);
  assert.match(out, />rows</);
  // read-only: no button other than the sort headers
  const buttons = out.match(/<button[^>]*>/g) || [];
  assert.ok(buttons.length > 0);
  assert.equal(buttons.length, (out.match(/<th /g) || []).length);
});

test('V2 every header is a sortable button with aria-sort', () => {
  const out = render(h(StatePathModesView, { flags: flagsRes([]), settings: knobs() }));
  const ths = out.match(/<th [^>]*>/g) || [];
  assert.equal(ths.length, 7);
  for (const th of ths) assert.match(th, /aria-sort="/);
  for (const label of ['#', 'PATH', 'KIND', 'MODE', 'SOURCE', 'UPDATED', 'NOTE']) assert.ok(out.includes(label), label);
  // the default sort is the ticket's flip order, not the alphabet
  const order = [...out.matchAll(/href="\/config\/[a-z]+\/([^"]+)"/g)].map((m) => m[1]);
  assert.deepEqual(order, STATE_PATHS.map((p) => p.name));
});

test('V3 a failed flags read names the failure and still renders the knob rows; unread is a warn tag', () => {
  const out = render(h(StatePathModesView, { flags: errRes('worker down'), settings: knobs() }));
  assert.ok(out.includes('could not read: flags'));
  for (const k of STATE_PATH_KNOBS) assert.ok(out.includes(`href="/config/setting/${k}"`), k);
  assert.match(out, /tag--warn[^>]*>unread</);
  // still loading → a skeleton, never an empty table
  const loading = render(h(StatePathModesView, { flags: { data: null, error: null, loading: true }, settings: knobs() }));
  assert.ok(!loading.includes('<table'));
});

test('V4 the hub tab of Settings mounts STATE PATHS; a project tab does not', () => {
  const base = { tabs: [{ id: 'hub', label: 'HUB' }], rows: [], boxRows: [], status: null, error: null, loading: false,
    busy: null, setBusy() {}, note: null, onDismissNote() {}, actions: {}, accountActions: null, dialog: null, onTab() {}, onReload() {}, controlKinds: [] };
  const hub = render(h(SettingsView, { ...base, activeTab: 'hub' }));
  assert.ok(hub.includes('STATE PATHS'));
  assert.ok(hub.indexOf('STATE PATHS') > hub.indexOf('PROTECTED PATHS'));
  // the panel itself is mounted under it: its first render is the loading skeleton
  const after = hub.slice(hub.indexOf('STATE PATHS'));
  assert.equal((after.match(/class="skel"[^>]*height:20px/g) || []).length, 4);
  const proj = render(h(SettingsView, { ...base, activeTab: 'project-3' }));
  assert.ok(!proj.includes('STATE PATHS'));
});
