import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { HubView } from '../src/screens/Hub.js';
import { StandbyPanel, StandbyView, STANDBY_COLUMNS } from '../src/screens/hub/Standby.js';
import { StandbyVerifyCell, StandbyVerifyDetail } from '../src/screens/hub/StandbyVerify.js';
import { standbyRows, snapshotAgeMin, reportAgeMin, STANDBY_CONTRACT_ERROR } from '../src/lib/standby.js';
import { snapshotAgeMin as watchdogSnapshotAgeMin } from '../../worker/watchdog/src/standby.js';
import { sortRows } from '../src/lib/sort.js';

// BH-2641 (BH-2519.3): the STANDBY panel on /hub. standbyRows is driven with
// fixture recovery payloads; the panel is rendered to a string, and its pure
// view (StandbyView calls no hooks) is walked as a vnode tree where the verify
// stubs render nothing.

const NOW = Date.parse('2026-09-24T15:00:00Z');
const noop = () => {};

const SB1 = { box: 'sb-1', of_hub: 'hub-1', snapshot: '20260924T140000Z', ok: 1, reported_at: '2026-09-24T14:58:00Z' };
const SB2 = { box: 'sb-2', of_hub: 'hub-1', snapshot: 'latest', ok: 0, reported_at: 'garbage' };
const RECOVERY = {
  lease: { holder: 'hub-1', epoch: 7, expires_at: '2026-09-24T15:01:30Z', updated_at: '2026-09-24T14:59:30Z', live: true },
  role: { active: 'hub-1', standby: [] },
  backups: [
    { box: 'hub-1', backup_ts: '2026-09-24T14:48:00Z', backup_off: null, backup_unconfigured: null, backup_reported_at: '2026-09-24T14:50:00Z' },
  ]
};
const WITH_STANDBYS = { ...RECOVERY, role: { active: 'hub-1', standby: ['sb-1', 'sb-2'] }, standbys: [SB2, SB1] };

const viewProps = (rows, extra = {}) => ({
  rows, openBox: null, onToggle: noop, runs: [], lastByBox: {}, verifyError: null, reload: noop, ...extra
});
const col = (key, lastByBox = {}) => STANDBY_COLUMNS(lastByBox, null, noop, noop).find((c) => c.key === key);

function findVnodes(node, type, out = []) {
  if (Array.isArray(node)) { node.forEach((n) => findVnodes(n, type, out)); return out; }
  if (!node || typeof node !== 'object') return out;
  if (node.type === type) out.push(node);
  findVnodes(node.props && node.props.children, type, out);
  return out;
}

test('P1 standbyRows maps each heartbeat row', () => {
  const rows = standbyRows(WITH_STANDBYS, NOW);
  assert.equal(rows.length, 2);
  const sb1 = rows.find((r) => r.box === 'sb-1');
  assert.deepEqual(sb1, {
    box: 'sb-1', ofHub: 'hub-1', snapshot: '20260924T140000Z', ok: true,
    reportedAt: '2026-09-24T14:58:00Z', reportAgeMin: 2, streamAgeMin: 60
  });
  assert.equal(rows.find((r) => r.box === 'sb-2').ok, false);
  // non-object entries are dropped
  assert.equal(standbyRows({ ...WITH_STANDBYS, standbys: [SB1, null, 'x', 3] }, NOW).length, 1);
});

test('P1 empty vs error marker: an absent standbys array is [] only when role.standby is empty', () => {
  assert.deepEqual(standbyRows({ role: { standby: [] } }, NOW), []);
  assert.deepEqual(standbyRows({ role: {} }, NOW), []);
  assert.deepEqual(standbyRows({ standbys: [] }, NOW), []);
  assert.deepEqual(standbyRows({ standbys: [], role: { standby: ['sb-1'] } }, NOW), []);
  for (const standbys of [undefined, null, {}]) {
    assert.deepEqual(standbyRows({ standbys, role: { standby: ['sb-1'] } }, NOW),
      { error: STANDBY_CONTRACT_ERROR, standby: ['sb-1'] }, `standbys=${JSON.stringify(standbys)}`);
  }
  assert.equal(STANDBY_CONTRACT_ERROR, 'standbys_missing');
});

test('P2 ages are null, never 0 or NaN, for unparseable stamps; the parse mirrors the watchdog', () => {
  const inputs = ['latest', '', 123, '20261340T000000Z', '20260231T000000Z', '20261301T000000Z', '20260924T140000Z'];
  for (const snapshot of inputs.slice(0, 6)) {
    const [r] = standbyRows({ standbys: [{ ...SB1, snapshot }] }, NOW);
    assert.equal(r.streamAgeMin, null, `snapshot=${JSON.stringify(snapshot)}`);
  }
  for (const id of inputs) assert.equal(snapshotAgeMin(id, NOW), watchdogSnapshotAgeMin(id, NOW), `id=${JSON.stringify(id)}`);
  for (const reported_at of ['garbage', '', null, 5]) {
    const [r] = standbyRows({ standbys: [{ ...SB1, reported_at }] }, NOW);
    assert.equal(r.reportAgeMin, null, `reported_at=${JSON.stringify(reported_at)}`);
  }
  assert.equal(reportAgeMin('2026-09-24T15:05:00Z', NOW), 0);
});

test('P3 seven headers in order; STREAM is an ok / FAILING pill, and only 1/true reads ok', () => {
  const out = render(h(StandbyView, viewProps(standbyRows(WITH_STANDBYS, NOW))));
  const labels = ['BOX', 'HUB', 'LAST SNAPSHOT', 'STREAM AGE', 'LAST REPORT', 'STREAM', 'LAST VERIFY'];
  const heads = [...out.matchAll(/<th(?:\s[^>]*)?>[\s\S]*?<\/th>/g)].map((m) => m[0].replace(/<[^>]+>/g, '').replace(/[↑↓]/g, '').trim());
  assert.deepEqual(heads, labels);
  assert.match(out, /<span class="pill pill--dead">FAILING<\/span>/);
  assert.match(out, /<span class="pill">ok<\/span>/);
  for (const ok of ['1', null, undefined, 2]) {
    const [r] = standbyRows({ standbys: [{ ...SB1, ok }] }, NOW);
    assert.equal(r.ok, false, `ok=${JSON.stringify(ok)}`);
    assert.match(render(h(StandbyView, viewProps([r]))), />FAILING</);
  }
});

test('P4 empty state for [], error line (not the empty state) for the contract-break marker', () => {
  const empty = render(h(StandbyView, viewProps(standbyRows({ role: { standby: [] } }, NOW))));
  assert.match(empty, /No standby has reported a heartbeat yet\./);
  assert.doesNotMatch(empty, /role="alert"/);
  const broken = render(h(StandbyView, viewProps(standbyRows({ role: { standby: ['sb-1'] } }, NOW))));
  assert.match(broken, /role="alert"[^>]*>[^<]*sb-1/);
  assert.doesNotMatch(broken, /No standby has reported/);
  assert.doesNotMatch(broken, /<table/);
});

test('P5 a wide SortableTable in its own overflow-x:auto wrapper; every header has aria-sort, BOX ascending', () => {
  const out = render(h(StandbyView, viewProps(standbyRows(WITH_STANDBYS, NOW))));
  assert.match(out, /<div style="overflow-x:auto;max-width:100%"><div class="tablewrap tablewrap--wide">/);
  const ths = [...out.matchAll(/<th(?:\s[^>]*)?>/g)].map((m) => m[0]);
  assert.equal(ths.length, 7);
  for (const th of ths) assert.match(th, /aria-sort="(ascending|descending|none)"/);
  assert.match(out, /<th aria-sort="ascending"[^>]*><button[^>]*>\s*BOX/);
  // default sort BOX: sb-1 renders before sb-2 although the payload lists sb-2 first
  assert.ok(out.indexOf('>sb-1<') < out.indexOf('>sb-2<'));
});

test('P6 a null age sorts last both ways and reads —', () => {
  const rows = standbyRows({ standbys: [SB2, SB1, { ...SB1, box: 'sb-3', snapshot: '20260924T145000Z' }] }, NOW);
  for (const key of ['stream', 'reported']) {
    const c = col(key);
    assert.equal(sortRows(rows, c.sort, 'asc').at(-1).box, 'sb-2', `${key} asc`);
    assert.equal(sortRows(rows, c.sort, 'desc').at(-1).box, 'sb-2', `${key} desc`);
  }
  assert.deepEqual(sortRows(rows, col('stream').sort, 'asc').map((r) => r.box), ['sb-3', 'sb-1', 'sb-2']);
  const sb2 = rows.find((r) => r.box === 'sb-2');
  assert.match(render(col('stream').cell(sb2)), /<span class="na">—<\/span>/);
  assert.match(render(col('reported').cell(sb2)), /<span class="na">—<\/span>/);
  const sb1 = rows.find((r) => r.box === 'sb-1');
  assert.equal(render(col('stream').cell(sb1)), '1h');
  assert.match(render(col('reported').cell(sb1)), /title="2026-09-24T14:58:00Z"[^>]*>2m ago/);
});

test('P7 LAST VERIFY mounts the contract cell and sorts on requested_at; BOX opens the drill-down', () => {
  const rows = standbyRows(WITH_STANDBYS, NOW);
  const last = { 'sb-2': { id: 4, box: 'sb-2', requested_at: '2026-09-24T14:00:00Z' } };
  const reload = () => 'reloaded';
  const verify = STANDBY_COLUMNS(last, null, noop, reload).find((c) => c.key === 'verify');
  assert.equal(verify.label, 'LAST VERIFY');
  assert.equal(verify.sort(rows.find((r) => r.box === 'sb-2')), '2026-09-24T14:00:00Z');
  assert.equal(verify.sort(rows.find((r) => r.box === 'sb-1')), undefined);
  assert.deepEqual(sortRows(rows, verify.sort, 'desc').map((r) => r.box), ['sb-2', 'sb-1']);
  const cell = verify.cell(rows.find((r) => r.box === 'sb-2'));
  assert.equal(cell.type, StandbyVerifyCell);
  assert.equal(cell.props.last, last['sb-2']);
  assert.equal(cell.props.row.box, 'sb-2');
  assert.equal(cell.props.onQueued, reload);

  const runs = [{ id: 1, box: 'sb-1' }, { id: 2, box: 'sb-2' }, { id: 3, box: 'sb-1' }];
  const err = new Error('x');
  const props = viewProps(rows, { openBox: 'sb-1', runs, verifyError: err, reload });
  const out = render(h(StandbyView, props));
  assert.match(out, /aria-expanded="true"[^>]*>sb-1</);
  assert.match(out, /aria-expanded="false"[^>]*>sb-2</);
  assert.match(out, /<dl[^>]*>[\s\S]*of_hub[\s\S]*hub-1[\s\S]*reported_at[\s\S]*2026-09-24T14:58:00Z[\s\S]*<\/dl>/);
  const details = findVnodes(StandbyView(props), StandbyVerifyDetail);
  assert.equal(details.length, 1);
  assert.equal(details[0].props.box, 'sb-1');
  assert.deepEqual(details[0].props.runs.map((r) => r.id), [1, 3]);
  assert.equal(details[0].props.error, err);
  assert.equal(details[0].props.onRetry, reload);
  // closed: no detail at all
  assert.equal(findVnodes(StandbyView(viewProps(rows)), StandbyVerifyDetail).length, 0);
  assert.doesNotMatch(render(h(StandbyView, viewProps(rows))), /<dl/);
});

const hubView = (data) => render(h(HubView, {
  state: { data, error: null, loading: false, fetchedAt: NOW }, now: NOW, onReload: noop, onPromote: noop, promoteMsg: null
}));

test('P8 HubView mounts STANDBY between ROLE and BACKUPS, fed data and the reload key', () => {
  const out = hubView(WITH_STANDBYS);
  const role = out.indexOf('>ROLE<');
  const standby = out.indexOf('>STANDBY<');
  const backups = out.indexOf('>BACKUPS<');
  assert.ok(role > -1 && standby > role && backups > standby, `ROLE ${role} STANDBY ${standby} BACKUPS ${backups}`);
  assert.match(out, /aria-expanded="false"[^>]*>sb-1</);
  const panels = findVnodes(HubView({
    state: { data: WITH_STANDBYS, error: null, loading: false, fetchedAt: NOW }, now: NOW, onReload: noop, onPromote: noop, promoteMsg: null
  }), StandbyPanel);
  assert.equal(panels.length, 1);
  assert.equal(panels[0].props.data, WITH_STANDBYS);
  assert.equal(panels[0].props.reloadKey, NOW);
});

test('P9 the pre-worker payload renders the empty state, the ROLE line is unchanged, and nothing is fetched', () => {
  const saved = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async () => { calls++; throw new Error('no fetch expected'); };
  try {
    const out = hubView(RECOVERY);
    assert.match(out, /No standby has reported a heartbeat yet\./);
    assert.match(out, /Standby: none recorded \(#401\)/);
    assert.doesNotMatch(out, /standbys_missing|carries no standby rows/);
    render(h(StandbyPanel, { data: WITH_STANDBYS, reloadKey: NOW }));
    assert.equal(calls, 0);
  } finally {
    globalThis.fetch = saved;
  }
});
