import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { sortRows } from '../src/lib/sort.js';
import { capRows, validateCapInput, editFormState, makeEditAction } from '../src/lib/cost-caps.js';
import {
  CostCapsSection, CostCapsView, EditForm, capColumns, loadSettings
} from '../src/screens/CostCaps.js';

// BH-2566 (BH-2511.3): the CAPS table on /costs. One row per conf.cost-caps.* /
// conf.lane-caps.* settings row, and an audited EDIT through the in-app modal
// that PUTs {key,value,reason} to the coord proxy (the proxy stamps the actor).

const seed = (key, value, extra = {}) =>
  ({ key, value, actor: 'registry-seed', note: null, updated_at: '2026-09-26T10:00:00Z', ...extra });
const op = (key, value, extra = {}) =>
  ({ key, value, actor: 'console', note: 'raise', updated_at: '2026-09-27T01:00:00Z', ...extra });

const byKey = (rows) => Object.fromEntries(rows.map((r) => [r.key, r]));

// ------------------------------------------------------------ L. capRows

test('L1: a registry-seed row is CATALOG, no OVERRIDE, APPLIES = catalog', () => {
  const { rows, unreadable } = capRows([seed('conf.cost-caps.default', '100 5')]);
  assert.equal(unreadable, false);
  assert.equal(rows.length, 1);
  const r = rows[0];
  assert.equal(r.key, 'conf.cost-caps.default');
  assert.equal(r.file, 'cost-caps');
  assert.equal(r.kind, 'cost-caps.default');
  assert.equal(r.scope, 'fleet');
  assert.equal(r.catalog, '100 5');
  assert.equal(r.override, null);
  assert.equal(r.applies, '100 5');
  assert.equal(r.actor, 'registry-seed');
  assert.equal(r.updatedAt, '2026-09-26T10:00:00Z');
  assert.equal(r.box, null);
  assert.equal(r.editable, true);
});

test('L2: an operator row is OVERRIDE, no CATALOG, APPLIES = override; every directive parses', () => {
  const { rows } = capRows([
    op('conf.cost-caps.budget.acme', '120 3'),
    seed('conf.cost-caps.ceiling', '4000'),
    seed('conf.lane-caps.lane.alert-triage', '2.5 1048576'),
    seed('conf.lane-caps.noise.medic', '3'),
    seed('conf.lane-caps.noise.default', '10'),
    seed('conf.lane-caps.default', 'off'),
  ]);
  const m = byKey(rows);
  const b = m['conf.cost-caps.budget.acme'];
  assert.deepEqual([b.kind, b.scope, b.subject, b.catalog, b.override, b.applies, b.actor],
    ['cost-caps.budget', 'project', 'acme', null, '120 3', '120 3', 'console']);
  assert.deepEqual([m['conf.cost-caps.ceiling'].kind, m['conf.cost-caps.ceiling'].scope], ['cost-caps.ceiling', 'fleet']);
  const l = m['conf.lane-caps.lane.alert-triage'];
  assert.deepEqual([l.file, l.kind, l.scope, l.subject], ['lane-caps', 'lane-caps.lane', 'lane', 'alert-triage']);
  assert.deepEqual([m['conf.lane-caps.noise.medic'].kind, m['conf.lane-caps.noise.medic'].scope], ['lane-caps.noise', 'lane']);
  const nd = m['conf.lane-caps.noise.default'];
  assert.deepEqual([nd.kind, nd.scope, nd.subject], ['lane-caps.noise', 'fleet', 'default'], 'noise.default is fleet, not a lane');
  assert.deepEqual([m['conf.lane-caps.default'].kind, m['conf.lane-caps.default'].scope], ['lane-caps.default', 'fleet']);
  for (const r of rows) assert.equal(r.editable, true, r.key);
});

test('L3: box-suffixed keys are their own display-only rows labelled with the box; odd keys are unknown', () => {
  const { rows } = capRows([
    seed('conf.cost-caps.budget.acme', '100'),
    op('conf.cost-caps.budget.acme.hub', '90'),
    op('conf.cost-caps.default.hub', '80 2'),
    op('conf.lane-caps.lane.medic.box3', 'off'),
    op('conf.cost-caps.budget.a.b.c', '1'),
    op('conf.lane-caps.budget.acme', '1'),
    op('conf.cost-caps.bogus', '1'),
  ]);
  assert.equal(rows.length, 7);
  const m = byKey(rows);
  const bb = m['conf.cost-caps.budget.acme.hub'];
  assert.deepEqual([bb.kind, bb.subject, bb.box, bb.editable], ['cost-caps.budget', 'acme', 'hub', false]);
  const db = m['conf.cost-caps.default.hub'];
  assert.deepEqual([db.kind, db.scope, db.box, db.editable], ['cost-caps.default', 'fleet', 'hub', false]);
  assert.deepEqual([m['conf.lane-caps.lane.medic.box3'].box, m['conf.lane-caps.lane.medic.box3'].editable], ['box3', false]);
  assert.equal(m['conf.cost-caps.budget.acme'].box, null);
  assert.equal(m['conf.cost-caps.budget.acme'].editable, true);
  for (const k of ['conf.cost-caps.budget.a.b.c', 'conf.lane-caps.budget.acme', 'conf.cost-caps.bogus']) {
    assert.deepEqual([m[k].kind, m[k].scope, m[k].editable], ['unknown', '?', false], k);
  }
});

test('L4: a non-array read is unreadable (never "no caps"); non-cap keys are excluded; keys normalise', () => {
  for (const bad of [null, undefined, {}, { settings: [] }, 'x']) {
    const r = capRows(bad);
    assert.equal(r.unreadable, true, JSON.stringify(bad));
    assert.deepEqual(r.rows, []);
  }
  const { rows, unreadable } = capRows([
    seed('lane.x.y', '1'), seed('conf.scheduler.overlap_threshold', '3'), null,
    seed('CONF.Cost-Caps.Ceiling', '500'),
  ]);
  assert.equal(unreadable, false);
  assert.deepEqual(rows.map((r) => r.key), ['conf.cost-caps.ceiling']);
});

// ------------------------------------------------------------ V. grammar

test('V1: validateCapInput mirrors the readers\' grammar', () => {
  const accept = [
    ['cost-caps.budget', '100'], ['cost-caps.budget', '100 5'], ['cost-caps.budget', '0.5'],
    ['cost-caps.default', ' 90.5  2 '], ['cost-caps.ceiling', '4000'],
    ['lane-caps.lane', 'off'], ['lane-caps.lane', '2.5 1048576'], ['lane-caps.lane', '0'],
    ['lane-caps.default', 'off 40000'], ['lane-caps.noise', 'off'], ['lane-caps.noise', '3'], ['lane-caps.noise', '0'],
  ];
  for (const [k, v] of accept) assert.deepEqual(validateCapInput(k, v), { ok: true, error: '' }, `${k} ${JSON.stringify(v)}`);
  const refuse = [
    ['cost-caps.budget', ''], ['cost-caps.budget', '   '], ['cost-caps.budget', '.'], ['cost-caps.budget', '0'],
    ['cost-caps.budget', '-1'], ['cost-caps.budget', '100 5 7'], ['cost-caps.budget', '100 x'],
    ['cost-caps.budget', 'off'], ['cost-caps.ceiling', '4000 2'], ['cost-caps.default', '100\t5'],
    ['cost-caps.default', '100\n5'], ['lane-caps.noise', '1.5'], ['lane-caps.noise', '3 4'],
    ['lane-caps.lane', '2 0'], ['lane-caps.lane', '2 1.5'], ['lane-caps.lane', '.'], ['lane-caps.lane', '1 2 3'],
    ['unknown', '1'], ['cost-caps.bogus', '1'], ['cost-caps.budget', null],
  ];
  for (const [k, v] of refuse) {
    const r = validateCapInput(k, v);
    assert.equal(r.ok, false, `${k} ${JSON.stringify(v)} must be refused`);
    assert.ok(r.error.length > 0, 'a refusal says why');
  }
});

test('V2: a blank or whitespace reason blocks with the reason hint', () => {
  for (const reason of ['', '   ', null, undefined]) {
    assert.deepEqual(editFormState('100 5', reason, 'cost-caps.default'),
      { blocked: true, hint: 'say why this cap changes' }, JSON.stringify(reason));
  }
});

test('V3: a valid value with a reason passes; an invalid value blocks with the validator error', () => {
  assert.deepEqual(editFormState('120 5', 'demo week', 'cost-caps.default'), { blocked: false, hint: '' });
  const bad = editFormState('off', 'demo week', 'cost-caps.budget');
  assert.equal(bad.blocked, true);
  assert.equal(bad.hint, validateCapInput('cost-caps.budget', 'off').error);
});

// ------------------------------------------------------------ E. the EDIT action

const fleetRow = capRows([seed('conf.cost-caps.default', '100 5')]).rows[0];

function harness({ value = '120 5', reason = 'r', answer = true, put } = {}) {
  const sent = []; const msgs = []; const pend = []; const confirms = []; let reloads = 0;
  const act = makeEditAction({
    confirm: async (o) => { confirms.push(o); o.form.value = value; o.form.reason = reason; return answer; },
    put: put || (async (b) => { sent.push(b); return { ok: true }; }),
    reload: () => { reloads++; },
    onMsg: (m) => msgs.push(m),
    onPending: (p) => pend.push(p),
    renderForm: () => 'form'
  });
  return { act, sent, msgs, pend, confirms, reloads: () => reloads };
}

test('E1: SAVE sends exactly {key,value,reason} with no actor, then the success banner and a reload', async () => {
  const t = harness({ value: ' 120 5 ', reason: ' demo ' });
  await t.act(fleetRow);
  assert.equal(t.confirms.length, 1);
  assert.equal(t.confirms[0].title, 'EDIT CAP');
  assert.equal(t.confirms[0].confirmLabel, 'SAVE');
  assert.equal(t.confirms[0].confirmBlocked, true, 'SAVE starts blocked (no reason yet)');
  assert.equal(typeof t.confirms[0].body, 'function');
  assert.equal(t.sent.length, 1);
  assert.deepEqual(Object.keys(t.sent[0]), ['key', 'value', 'reason']);
  assert.deepEqual(t.sent[0], { key: 'conf.cost-caps.default', value: '120 5', reason: 'demo' });
  assert.deepEqual(t.msgs, [{ ok: true, text: 'cap conf.cost-caps.default set to 120 5' }]);
  assert.equal(t.reloads(), 1);
  assert.deepEqual(t.pend, ['conf.cost-caps.default', null]);
});

test('E1b: the modal opens on the value that applies now', async () => {
  let form = null;
  const act = makeEditAction({
    confirm: async (o) => { form = { ...o.form }; return false; },
    put: async () => {}, reload: () => {}, onMsg: () => {}
  });
  await act(fleetRow);
  assert.deepEqual(form, { value: '100 5', reason: '' });
});

test('E2: a worker failure (the 501 stub) is the failure banner with its text, never "set", no reload', async () => {
  const t = harness({ put: async () => { throw new Error('not implemented'); } });
  await t.act(fleetRow);
  assert.deepEqual(t.msgs, [{ ok: false, text: 'EDIT failed — not implemented' }]);
  assert.equal(t.reloads(), 0);
  assert.deepEqual(t.pend, ['conf.cost-caps.default', null], 'pending clears in finally');
});

test('E3: cancel (Escape) sends nothing and says nothing', async () => {
  const t = harness({ answer: false });
  await t.act(fleetRow);
  assert.equal(t.sent.length, 0);
  assert.equal(t.msgs.length, 0);
});

test('E3b: a confirm that slips past the gate with a bad value or no reason sends nothing', async () => {
  const noReason = harness({ reason: '  ' });
  await noReason.act(fleetRow);
  assert.equal(noReason.sent.length, 0);
  assert.deepEqual(noReason.msgs, [{ ok: false, text: 'EDIT refused — say why this cap changes' }]);
  const badValue = harness({ value: '100 5 7' });
  await badValue.act(fleetRow);
  assert.equal(badValue.sent.length, 0);
  assert.equal(badValue.msgs[0].ok, false);
  assert.match(badValue.msgs[0].text, /^EDIT refused — /);
});

test('E4: box rows and unknown rows never open the editor', async () => {
  const { rows } = capRows([op('conf.cost-caps.default.hub', '80'), op('conf.cost-caps.bogus', '1')]);
  for (const r of rows) {
    const t = harness();
    await t.act(r);
    assert.equal(t.confirms.length, 0, r.key);
    assert.equal(t.sent.length, 0, r.key);
  }
});

test('E5: a second click while a save is in flight is ignored', async () => {
  let release;
  const sent = [];
  const act = makeEditAction({
    confirm: async (o) => { o.form.value = '1'; o.form.reason = 'r'; return true; },
    put: (b) => { sent.push(b); return new Promise((r) => { release = r; }); },
    reload: () => {}, onMsg: () => {}
  });
  const first = act(fleetRow);
  await new Promise((r) => setImmediate(r));
  await act(fleetRow);
  release({});
  await first;
  assert.equal(sent.length, 1);
});

// ------------------------------------------------------------ R. the view

const loaded = (list) => ({ data: { settings: list }, error: null, loading: false, reload: () => {} });
const view = (settings, extra = {}) =>
  render(h(CostCapsView, { settings, onEdit: () => {}, pending: null, msg: null, ...extra }));
const SEED_COPY = 'no cap rows yet — run bin/cost-caps-seed.sh on the hub';
const FOOT = 'a box-local flags/cost-caps.conf or flags/lane-caps.conf is not visible here; an override row beats it';

const LIST = [
  seed('conf.cost-caps.budget.acme', '100 5'),
  op('conf.lane-caps.lane.lane-x', '2.5'),
  seed('conf.cost-caps.default', '90'),
  op('conf.cost-caps.budget.acme.hub', '70'),
  seed('conf.scheduler.overlap_threshold', '3'),
];

test('R1: loaded renders a sortable table with all nine headers', () => {
  const out = view(loaded(LIST));
  assert.ok(out.includes('CAPS'));
  assert.ok(out.includes('<table'));
  assert.ok(out.includes('tablewrap--wide'), 'the wide table scrolls inside its own container at 375px');
  for (const label of ['SCOPE', 'SUBJECT', 'KIND', 'CATALOG', 'OVERRIDE', 'APPLIES', 'BY', 'UPDATED', 'EDIT']) {
    assert.ok(out.includes(`>${label}`) || out.includes(`${label}<`), label);
  }
  assert.ok(out.includes('aria-sort="ascending"'), 'SCOPE sorts ascending by default');
  assert.ok(!out.includes('overlap_threshold'), 'non-cap rows are not listed');
  assert.ok(!out.includes(SEED_COPY));
});

test('R2: project and lane subjects are links', () => {
  const out = view(loaded(LIST));
  assert.ok(out.includes('href="/p/acme"'), 'budget subject links to the project');
  assert.ok(out.includes('href="/settings/lane-x"'), 'lane subject links to the lane settings');
});

test('R3: an empty readable list is the seed copy and no table', () => {
  const out = view(loaded([seed('lane.x.y', '1')]));
  assert.ok(out.includes(SEED_COPY));
  assert.ok(!out.includes('<table'));
  assert.ok(out.includes(FOOT));
});

test('R4: a failed read is the ErrorBox with the error, never the seed copy', () => {
  const out = view({ data: null, error: new Error('boom'), loading: false, reload: () => {} });
  assert.ok(out.includes('boom'));
  assert.ok(out.includes('could not load'));
  assert.ok(!out.includes(SEED_COPY));
  assert.ok(!out.includes('<table'));
  const shapeless = view({ data: { nope: 1 }, error: null, loading: false, reload: () => {} });
  assert.ok(shapeless.includes('the settings read returned no list'));
  assert.ok(!shapeless.includes(SEED_COPY));
});

test('R4b: loading with no data is the skeleton, not the seed copy or an error', () => {
  const out = view({ data: null, error: null, loading: true, reload: () => {} });
  assert.ok(out.includes('class="skel"'));
  assert.ok(!out.includes(SEED_COPY));
  assert.ok(!out.includes('could not load'));
});

test('R5: a box row renders its box, is display only, and has no EDIT button', () => {
  const out = view(loaded([op('conf.cost-caps.budget.acme.hub', '70')]));
  assert.ok(out.includes('box hub'));
  assert.ok(out.includes('display only'));
  assert.ok(!/<button[^>]*>EDIT<\/button>/.test(out), 'no EDIT button on a box row');
  const fleet = view(loaded([seed('conf.cost-caps.default', '90')]));
  assert.ok(/<button[^>]*>EDIT<\/button>/.test(fleet), 'a fleet row has one');
});

test('R5b: the EDIT button is disabled while that key is saving', () => {
  const out = view(loaded([seed('conf.cost-caps.default', '90')]), { pending: 'conf.cost-caps.default' });
  assert.ok(/<button[^>]*disabled[^>]*>EDIT<\/button>/.test(out));
});

test('R6: the footnote and the banner render', () => {
  const out = view(loaded(LIST), { msg: { ok: false, text: 'EDIT failed — not implemented' } });
  assert.ok(out.includes(FOOT));
  assert.ok(out.includes('EDIT failed — not implemented'));
});

test('R7: CATALOG / OVERRIDE / BY show a dash when empty', () => {
  const out = view(loaded([op('conf.cost-caps.ceiling', '4000', { actor: null })]));
  assert.ok((out.match(/>—</g) || []).length >= 2);
});

test('S: the APPLIES column sorts on the value shown, numerically, missing last', () => {
  const { rows } = capRows([
    seed('conf.cost-caps.budget.a', '9'), seed('conf.cost-caps.budget.b', '100 5'),
    seed('conf.cost-caps.budget.c', '20'), seed('conf.cost-caps.budget.d', null),
  ]);
  const col = capColumns({ onEdit: () => {}, pending: null }).find((c) => c.key === 'applies');
  assert.equal(col.label, 'APPLIES');
  assert.deepEqual(sortRows(rows, col.sort, 'desc').map((r) => r.subject), ['b', 'c', 'a', 'd']);
  assert.deepEqual(sortRows(rows, col.sort, 'asc').map((r) => r.subject), ['a', 'c', 'b', 'd']);
  const edit = capColumns({ onEdit: () => {}, pending: null }).find((c) => c.key === 'edit');
  assert.equal(edit.sort, null, 'EDIT is not a sortable column');
});

test('F: EditForm puts VALUE first, then REASON, and shows the grammar', () => {
  const out = render(h(EditForm, { row: fleetRow, value: { value: '100 5', reason: '' }, onBlocked: () => {} }));
  const v = out.indexOf('VALUE');
  const r = out.indexOf('REASON');
  assert.ok(v > -1 && r > v, 'VALUE precedes REASON');
  assert.ok(out.includes('value="100 5"'));
  assert.ok(out.includes('conf.cost-caps.default'));
  assert.ok(out.includes('say why this cap changes'), 'the blocked hint shows');
  const src = readFileSync(new URL('../src/screens/CostCaps.js', import.meta.url), 'utf8');
  assert.equal(/useEffect/.test(src), false, 'no focus effect of its own (D39): the Modal owns focus');
});

// ------------------------------------------------------------ W. production wiring

test('W1: the real section renders, reads the settings list through the coord proxy, and writes through putCostCap', async () => {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), method: init.method || 'GET' });
    return { ok: true, status: 200, text: async () => JSON.stringify({ settings: LIST }) };
  };
  const out = render(h(CostCapsSection));
  assert.ok(out.includes('CAPS'));
  assert.ok(out.includes('class="skel"'), 'first paint is the skeleton');
  const data = await loadSettings();
  assert.deepEqual(calls.map((c) => [c.method, c.url]), [['GET', '/api/coord/settings']]);
  assert.equal(capRows(data.settings).rows.length, 4);
  const src = readFileSync(new URL('../src/screens/CostCaps.js', import.meta.url), 'utf8');
  assert.ok(src.includes('useApi(loadSettings,'), 'the section reads through loadSettings');
  assert.ok(src.includes('api.putCostCap('), 'the section writes through api.putCostCap');
});

test('N: no native dialog in the screen or the lib', () => {
  for (const f of ['../src/screens/CostCaps.js', '../src/lib/cost-caps.js']) {
    const code = readFileSync(new URL(f, import.meta.url), 'utf8')
      .split('\n').filter((l) => !/^\s*\/\//.test(l)).join('\n');
    assert.equal(/window\.(confirm|alert|prompt)\s*\(/.test(code), false, f);
    assert.equal(/(^|[^.\w])(alert|prompt)\s*\(/.test(code), false, f);
    assert.equal(/(^|[^.\w])confirm\s*\(/.test(code.replace(/await confirm\(/g, '')), false, f);
  }
  const src = readFileSync(new URL('../src/screens/CostCaps.js', import.meta.url), 'utf8');
  assert.ok(src.includes("from '../ui/Modal.js'"));
  assert.ok(src.includes("from '../ui/SortableTable.js'"));
});
