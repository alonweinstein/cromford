import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { render } from 'preact-render-to-string';
import { api } from '../src/api.js';
import { h } from 'preact';
import { SettingsView, LaneDetailView, BoxStateCell } from '../src/screens/Settings.js';
import { laneRows, boxLaneRows, boxFlagName, settingsRows, findLaneRow, tabsFrom, makeLaneActions } from '../src/lib/settings.js';

// THE PER-BOX LANE SWITCH (BH-2327).
//
// A box-scope lane (disk-clean, watchdog-ping, cost-local-brake, trap-eval, …) runs on every box,
// and until now appeared on no Settings tab at all. The hub tab gets a BOX
// LANES section, and each box lane's page a BOXES table with one toggle per
// box, writing `lane-off-<id>.box.<box>` through PUT /api/flags.
//
// Assertions are on rows, writes and rendered HTML — never on module source (D3).

// determinism: ok-file clock-now-js every timestamp is an OFFSET from one
// captured read; no case asserts a calendar date.
const NOW = Date.now();
const iso = (minutesAgo) => new Date(NOW - minutesAgo * 60000).toISOString();

// The committed declarations (D4): every catalog/lanes.d/<id>.json lane file.
const DIR = fileURLToPath(new URL('../../catalog/lanes.d/', import.meta.url));
const DECLS = readdirSync(DIR).filter((f) => /^[a-z0-9-]+\.json$/.test(f))
  .map((f) => JSON.parse(readFileSync(DIR + f, 'utf8')));
const registry = { lanes: DECLS };
const BOX_IDS = DECLS.filter((l) => l.scope === 'box').map((l) => l.id).sort();
const HUB_IDS = DECLS.filter((l) => (l.scope || 'hub') === 'hub').map((l) => l.id).sort();

// The switch name every layer agrees on — the same literal is pinned in
// tests/lane-gate-box-switch.bh-2327-test.sh and
// worker/jobs/test/lanes-box-switch.bh-2327.test.js.
const SW = 'lane-off-disk-clean.box.b';

// GET /api/lanes/status as worker/jobs/src/routes/lanes.js builds it: box lanes
// carry `boxes`/`boxes_off`/`boxes_complete`, other lanes carry none of them.
const boxEntry = (box, off, extra = {}) => ({
  box, switch_name: `lane-off-disk-clean.box.${box}`, off,
  off_source: off ? 'db' : null, paused_since: off ? iso(5) : null,
  paused_by: off ? 'console' : null, paused_reason: off ? `turned off on ${box} from Mission Control` : null,
  last_tick_at: iso(2), last_outcome: 'ran', ...extra
});
const status = {
  as_of: iso(1), project: null, projects: ['project-3'], all_off: false, all_off_flag_boxes: [],
  lanes: DECLS.map((l) => ({
    id: l.id, name: l.name || l.id, scope: l.scope, off: false, off_source: null,
    knobs: {}, flag_boxes: [], held_by: [],
    ...(l.id === 'disk-clean'
      ? { boxes: [boxEntry('a', false), boxEntry('b', true)], boxes_off: 1, boxes_complete: true }
      : l.scope === 'box' ? { boxes: [], boxes_off: 0, boxes_complete: true } : {})
  }))
};

const noop = async () => ({ status: 'written' });
const ACTIONS = { toggleLane: noop, toggleBox: noop, setKnob: noop, allOff: noop, allOn: noop };

// ── C1 ──────────────────────────────────────────────────────────────────────
test('C1: boxLaneRows returns exactly the box lanes; the hub tab rows are unchanged', () => {
  // BOX_IDS is derived from the committed lane files (D4), so a new box lane
  // needs no pin bump. This guards the read itself: known box lanes, one per
  // era of the catalog, must be in the derived set.
  for (const id of ['disk-clean', 'watchdog-ping', 'cost-local-brake', 'trap-eval']) {
    assert.ok(BOX_IDS.includes(id), `the committed catalog no longer declares box lane ${id}`);
  }
  const rows = boxLaneRows(registry, status);
  assert.deepEqual(rows.map((r) => r.id).sort(), BOX_IDS);
  for (const r of rows) {
    assert.equal(r.scope, 'box');
    assert.equal(r.switchName, `lane-off-${r.id}`);
    assert.equal(r.href, `/settings/${r.id}`);
  }
  // The hub tab's main table: laneRows() minus the box lanes (drawn once, in
  // BOX LANES, not again as live-only rows); every other row is unchanged.
  const all = laneRows(registry, status, 'hub');
  const tab = settingsRows(registry, status, 'hub');
  assert.deepEqual(tab.rows, all.filter((r) => !BOX_IDS.includes(r.id)));
  assert.ok(!tab.rows.some((r) => BOX_IDS.includes(r.id)), 'a box lane is drawn twice on the hub tab');
  for (const id of HUB_IDS) assert.ok(tab.rows.some((r) => r.id === id && !r.unregistered), `${id} lost from HUB LANES`);
  assert.deepEqual(tab.boxRows.map((r) => r.id).sort(), BOX_IDS);
  // A project tab is laneRows() exactly, with no box section.
  const proj = settingsRows(registry, status, 'project-3');
  assert.deepEqual(proj, { rows: laneRows(registry, status, 'project-3'), boxRows: [] });
});

// ── C2 ──────────────────────────────────────────────────────────────────────
test('C2: the hub tab renders BOX LANES, linked rows and a BOXES OFF count', () => {
  const html = render(h(SettingsView, {
    tabs: tabsFrom(status), activeTab: 'hub', ...settingsRows(registry, status, 'hub'), status, error: null, loading: false,
    busy: null, note: null, actions: ACTIONS, dialog: null, onTab: noop, onReload: noop
  }));
  const at = html.indexOf('BOX LANES');
  assert.ok(at > html.indexOf('HUB LANES'), 'no BOX LANES section under HUB LANES');
  const box = html.slice(at);
  // each box lane is linked once on the page, in BOX LANES
  assert.equal(html.split('href="/settings/disk-clean"').length - 1, 1, 'disk-clean drawn twice');
  for (const id of BOX_IDS) assert.ok(box.includes(`href="/settings/${id}"`), `${id} has no linked row`);
  assert.ok(box.includes('BOXES OFF'));
  assert.match(box, />1\/2</, 'disk-clean does not show 1 of 2 boxes off');

  // a project tab gets no BOX LANES section
  const proj = render(h(SettingsView, {
    tabs: tabsFrom(status), activeTab: 'project-3', rows: laneRows(registry, status, 'project-3'),
    boxRows: [], status, error: null, loading: false,
    busy: null, note: null, actions: ACTIONS, dialog: null, onTab: noop, onReload: noop
  }));
  assert.ok(!proj.includes('BOX LANES'));
});

// ── C3 ──────────────────────────────────────────────────────────────────────
test('C3: a box lane page renders one toggle per box; unknown state is disabled', () => {
  const st = JSON.parse(JSON.stringify(status));
  st.lanes.find((l) => l.id === 'disk-clean').boxes.push(boxEntry('c', null));
  // /settings/disk-clean finds the BOX LANES row, not a live-only duplicate.
  const lane = findLaneRow(registry, st, 'hub', 'disk-clean');
  assert.equal(lane.unregistered, false);
  assert.equal(lane.boxes.length, 3);
  const html = render(h(LaneDetailView, {
    lane, laneId: 'disk-clean', project: null, error: null, loading: false, costRows: [],
    actions: ACTIONS, busy: null, setBusy: () => {}
  }));
  const at = html.indexOf('>BOXES<');
  assert.ok(at > 0, 'no BOXES section');
  const sec = html.slice(at);
  const toggles = sec.match(/<button[^>]*class="toggle[^"]*"[^>]*>/g) || [];
  assert.equal(toggles.length, 3, `want 3 box toggles, got ${toggles.length}`);
  const tog = (box) => toggles.find((t) => t.includes(`aria-label="disk-clean on ${box}`)
    || t.includes(`aria-label="${lane.name} on ${box}`));
  assert.match(tog('a'), /aria-pressed="true"/);
  assert.match(tog('b'), /aria-pressed="false"/);
  assert.match(tog('c'), /disabled/);
  assert.ok(!/disabled/.test(tog('a')));
  assert.ok(sec.includes(`flags/${SW}`), 'the switch name is not shown');

  // the empty state
  const empty = boxLaneRows(registry, status).find((r) => r.id === 'watchdog-ping');
  const eh = render(h(LaneDetailView, {
    lane: empty, laneId: 'watchdog-ping', project: null, error: null, loading: false, costRows: [],
    actions: ACTIONS, busy: null, setBusy: () => {}
  }));
  assert.ok(eh.includes('No box has ticked this lane or been switched yet'));

  // a capped read says so
  const st2 = JSON.parse(JSON.stringify(status));
  st2.lanes.find((l) => l.id === 'disk-clean').boxes_complete = false;
  const capped = render(h(LaneDetailView, {
    lane: boxLaneRows(registry, st2).find((r) => r.id === 'disk-clean'), laneId: 'disk-clean',
    project: null, error: null, loading: false, costRows: [], actions: ACTIONS, busy: null, setBusy: () => {}
  }));
  assert.ok(capped.includes('a box may be missing'));
});

// The box toggle's own click handler, fired: the button the page draws is the
// one that calls toggleBox for THAT lane and box, through the busy latch.
test('C3b: clicking a box toggle calls toggleBox for that lane and box', async () => {
  const lane = findLaneRow(registry, status, 'hub', 'disk-clean');
  const box = lane.boxes.find((b) => b.box === 'b');
  const calls = []; const latched = [];
  const vnode = BoxStateCell({
    lane, box, busy: null,
    guard: (key, fn) => { latched.push(key); return fn(); },
    actions: { toggleBox: async (l, b) => { calls.push([l.id, b.box]); return { status: 'written' }; } }
  });
  const find = (v) => {
    if (!v || typeof v !== 'object') return null;
    if (Array.isArray(v)) { for (const c of v) { const f = find(c); if (f) return f; } return null; }
    if (v.type === 'button') return v;
    return find(v.props && v.props.children);
  };
  const btn = find(vnode);
  assert.ok(btn, 'no button drawn');
  assert.equal(btn.props.disabled, false);
  await btn.props.onClick();
  assert.deepEqual(calls, [['disk-clean', 'b']]);
  assert.deepEqual(latched, ['box:disk-clean:b']);
});

// ── C4 / C5 / C7 ────────────────────────────────────────────────────────────
function harness({ confirmAnswer = true, fail = false } = {}) {
  const writes = []; const notes = []; const asked = [];
  const actions = makeLaneActions({
    confirm: async (o) => { asked.push(o); return confirmAnswer; },
    writeFlag: async (b) => { if (fail) throw new Error('HTTP 500'); writes.push(b); },
    writeSetting: async () => {}, writeAll: async () => {}, refresh: () => {},
    onNote: (n) => notes.push(n)
  });
  return { actions, writes, notes, asked };
}
const diskRow = () => boxLaneRows(registry, status).find((r) => r.id === 'disk-clean');

test('C4: toggleBox writes the per-box row after confirm; cancel writes nothing', async () => {
  const row = diskRow();
  const on = row.boxes.find((b) => b.box === 'b');
  // b is OFF -> turning it on writes active 0
  const x = harness();
  const r1 = await x.actions.toggleBox(row, { ...on, off: false });
  assert.equal(r1.status, 'written');
  assert.deepEqual(x.writes, [{ name: SW, active: 1, actor: 'console', reason: 'turned off on b from Mission Control' }]);
  assert.ok(x.asked[0].body.includes(SW), 'the confirm does not name the switch');
  assert.match(x.asked[0].body, /on b only; every other box keeps running/);

  const y = harness();
  await y.actions.toggleBox(row, on);
  assert.deepEqual(y.writes, [{ name: SW, active: 0, actor: 'console', reason: 'turned on for b from Mission Control' }]);
  assert.match(y.asked[0].body, /resumes on b/);

  const z = harness({ confirmAnswer: false });
  const r3 = await z.actions.toggleBox(row, on);
  assert.equal(r3.status, 'cancelled');
  assert.deepEqual(z.writes, []);
});

test('C4b: a box stopped by a hand file is told what the row does to that file', async () => {
  const row = diskRow();
  const x = harness();
  await x.actions.toggleBox(row, { ...row.boxes[0], off: true, off_source: 'flag' });
  assert.equal(x.writes[0].active, 0);
  assert.match(x.asked[0].body, /file on a that no row wrote/);
});

test('C5: a refused write is failed, never written', async () => {
  const x = harness({ fail: true });
  const row = diskRow();
  const r = await x.actions.toggleBox(row, row.boxes[0]);
  assert.equal(r.status, 'failed');
  assert.equal(x.notes.at(-1).ok, false);
  assert.ok(!/written/.test(x.notes.at(-1).text));
});

test('C6: boxFlagName is the literal the gate and the worker use', () => {
  assert.equal(boxFlagName('disk-clean', 'b'), SW);
});

test('C7: toggleBox on a hub row or an unknown box refuses and writes nothing', async () => {
  const x = harness();
  const hub = laneRows(registry, status, 'hub').find((r) => r.id === 'merge-conductor');
  const r = await x.actions.toggleBox(hub, { box: 'b', off: false });
  assert.equal(r.status, 'invalid');
  const r2 = await x.actions.toggleBox(diskRow(), { box: 'c', off: null });
  assert.equal(r2.status, 'invalid');
  assert.deepEqual(x.writes, []);
  assert.equal(x.asked.length, 0);
});

test('C8: a status with no per-box state says so instead of an empty table', () => {
  const st = JSON.parse(JSON.stringify(status));
  delete st.lanes.find((l) => l.id === 'disk-clean').boxes;
  const lane = boxLaneRows(registry, st).find((r) => r.id === 'disk-clean');
  assert.equal(lane.boxes, null);
  const html = render(h(LaneDetailView, {
    lane, laneId: 'disk-clean', project: null, error: null, loading: false, costRows: [],
    actions: ACTIONS, busy: null, setBusy: () => {}
  }));
  assert.ok(html.includes('did not report per-box state'));
  assert.ok(!html.includes('No box has ticked this lane'));
});

// ── C9 ──────────────────────────────────────────────────────────────────────
// The registry read as the worker ANSWERS it (worker/jobs/src/routes/lanes.js:
// `json(200, { registry: LANES_REGISTRY, as_of: t })`). Handed to boxLaneRows
// unwrapped, `.lanes` was undefined and BOX LANES would never draw.
test('C9: api.lanesRegistry hands the screens the catalog, not the response envelope', async () => {
  const real = globalThis.fetch;
  globalThis.fetch = async () => ({
    ok: true, status: 200, text: async () => JSON.stringify({ registry, as_of: iso(0) })
  });
  try {
    const reg = await api.lanesRegistry();
    assert.ok(Array.isArray(reg.lanes), 'the registry payload has no lanes array');
    assert.deepEqual(boxLaneRows(reg, status).map((r) => r.id).sort(), BOX_IDS);
    assert.ok(findLaneRow(reg, status, 'hub', 'disk-clean').boxes, 'disk-clean page would draw no BOXES');
  } finally {
    globalThis.fetch = real;
  }
});
