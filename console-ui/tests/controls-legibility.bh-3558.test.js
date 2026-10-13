import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { FleetContext } from '../src/app.js';
import { matchRoute } from '../src/router.js';
import * as controlsLib from '../src/lib/controls.js';
import * as controlsScreen from '../src/screens/Controls.js';
import * as chat from '../src/screens/Chat.js';
import { HexScene } from '../src/screens/WorldHex.js';
import { WorldScreen } from '../src/screens/World.js';
import { buildScene } from '../src/lib/world.js';
import { assertNoRawHeaders, assertUsdLabelled } from './legibility.bh-3558.js';

// BH-3558.1 (issue #3568): the CONTROLS screen says what each kind and field
// means in plain words, links every row to its change history, and on the
// rules kind shows what actually limits builds (the BUILD CEILINGS panel over
// the hub snapshot's `ceilings`). Chat stamps carry a date once a turn is a
// day old; World and WorldHex are audited through the same two helpers.

// Namespace imports, so a missing export fails its own case rather than the file.
const { CONTROL_KINDS, displayValue, fieldLabel } = controlsLib;
const { ControlsScreen, ControlsView, CeilingsPanel, EditForm } = controlsScreen;
const { ChatMessage, ChatScreen } = chat;
const ceilingsLib = await import('../src/lib/ceilings.js').catch(() => ({}));
const { ceilingRows, runningSummary } = ceilingsLib;

const NOW = Date.UTC(2026, 8, 29, 14, 5);
const noop = () => {};
const byKind = (k) => CONTROL_KINDS.find((d) => d.kind === k);
const RULES = byKind('rules');
const GATE = byKind('review-gate');
const RETRY = byKind('retry-policies');
const CONTRACTS = byKind('contracts');

function rowFor(desc, n) {
  const r = {};
  for (const k of desc.keyFields) r[k] = `${k}-${n}`;
  for (const { name, type } of desc.editFields) r[name] = type === 'int' ? n : type === 'num' ? n / 10 : `${name} ${n}`;
  return r;
}
const loaded = (data) => ({ data, error: null, loading: false });
const view = (desc, rows, extra = {}) =>
  render(h(ControlsView, { desc, state: loaded({ [desc.listKey]: rows }), onReload: noop, onNew: noop, onEdit: noop, nowMs: NOW, ...extra }));
const text = (markup) => markup.replace(/<[^>]+>/g, ' ').replace(/&#39;|&#x27;/g, "'").replace(/&amp;/g, '&').replace(/\s+/g, ' ');
const fields = (desc) => [...desc.keyFields, ...desc.editFields.map((e) => e.name)];

const CEILINGS = [
  { project: 'alpha', box_read: 'hub', route: 'pool', pool_cap: '0', box_slots: '-', effective: 'unlimited', bound_by: 'no numeric cap applies', applies: { pool_cap: true, box_slots: false } },
  { project: 'beta', box_read: 'hub', route: 'local', pool_cap: '-', box_slots: '4', effective: '4', bound_by: 'box-slots 4 (route: local)', applies: { pool_cap: false, box_slots: true } },
];
const SNAP = { pushed_at: '2026-09-29 13:55:00Z', ceilings: CEILINGS };
const panel = (snapshot, running = loaded({ jobs: [] })) => render(h(CeilingsPanel, { snapshot, running, nowMs: NOW }));
// The <tr> of the table body that carries `project`.
const rowOf = (out, project) => (out.match(/<tr[^>]*>[\s\S]*?<\/tr>/g) || []).find((tr) => tr.includes(`>${project}<`)) || '';

// ------------------------------------------------------------------ A1

test('A1 every kind: plain headers, raw names only in .th-raw, no $ unlabelled', () => {
  for (const desc of CONTROL_KINDS) {
    const out = view(desc, [rowFor(desc, 1), rowFor(desc, 2)]);
    assertNoRawHeaders(out);
    assertUsdLabelled(out);
    for (const name of fields(desc)) {
      assert.ok(out.includes(`<span class="th-raw">${name}</span>`), `${desc.kind}: raw ${name} not under its header`);
    }
    const buttons = out.match(/<th[^>]*>\s*<button[^>]*>[\s\S]*?<\/button>/g) || [];
    assert.equal(buttons.length, fields(desc).length, `${desc.kind}: one sort button per field`);
    for (const b of buttons) assert.doesNotMatch(text(b.replace(/title="[^"]*"/, '')), /_/, `${desc.kind}: header button carries a raw name: ${b}`);
  }
});

// ------------------------------------------------------------------ A2

test('A2 every kind shows its explainer as visible text; rules says what the ticket rule is and is not', () => {
  const out = view(RULES, [rowFor(RULES, 1)]);
  const visible = text(out);
  assert.match(visible, /one claim per ticket/);
  assert.match(visible, /does not cap how many tickets build at once/);
  assert.doesNotMatch(out, /title="[^"]*one claim per ticket/);
  for (const desc of CONTROL_KINDS) {
    assert.ok(desc.explainer && desc.explainer.length > 20, `${desc.kind}: no explainer`);
    assert.doesNotMatch(desc.explainer, /—/, `${desc.kind}: explainer has an em dash`);
    const o = view(desc, [rowFor(desc, 1)]);
    assert.ok(text(o).includes(desc.explainer), `${desc.kind}: explainer not rendered`);
    assert.match(o, /<dl class="legend">/, `${desc.kind}: no legend`);
  }
  assert.match(out, /<dt>most at once<\/dt>/);
  // Shown while loading too: it is static copy.
  const skel = render(h(ControlsView, { desc: RULES, state: { data: null, error: null, loading: true }, onReload: noop, onNew: noop, onEdit: noop }));
  assert.match(text(skel), /one claim per ticket/);
});

// ------------------------------------------------------------------ A3

test('A3 displayValue: fractions as %, flags as yes/no, seconds, a zero cap named', () => {
  assert.equal(displayValue(GATE, 'tighten_rate', 0.25), '25%');
  assert.equal(displayValue(GATE, 'clear_rate', 0.125), '12.5%');
  assert.equal(displayValue(GATE, 'clear_rate', 'abc'), 'abc', 'never NaN%');
  assert.equal(displayValue(RETRY, 'escalate_allowed', 1), 'yes');
  assert.equal(displayValue(RETRY, 'escalate_allowed', '1'), 'yes');
  assert.equal(displayValue(RETRY, 'escalate_allowed', 0), 'no');
  assert.equal(displayValue(RETRY, 'escalate_allowed', '0'), 'no');
  assert.equal(displayValue(RETRY, 'backoff_seconds', 90), '90 s');
  assert.equal(displayValue(RULES, 'max_concurrent', 0), '0 (blocks every claim)');
  assert.equal(displayValue(RULES, 'max_concurrent', 3), '3');
  assert.equal(displayValue(RULES, 'max_concurrent', null), null);
  assert.equal(displayValue(GATE, 'window_days', 14), '14');
  assert.equal(fieldLabel(RULES, 'max_concurrent'), 'most at once');
  assert.equal(fieldLabel(RULES, 'SOME_THING'), 'some thing', 'falls back to plainLabel');
});

test('A3 rendered cells carry the display values', () => {
  const gate = view(GATE, [{ scope: 'hub', window_days: 14, min_merges: 5, tighten_rate: 0.25, clear_rate: 0.125, note: 'n' }]);
  assert.match(gate, />25%</);
  assert.match(gate, />12.5%</);
  const retry = view(RETRY, [
    { lane: 'a', max_attempts: 3, backoff_seconds: 90, escalate_allowed: 1, note: '' },
    { lane: 'b', max_attempts: 3, backoff_seconds: 60, escalate_allowed: 0, note: '' },
  ]);
  assert.match(retry, />yes</);
  assert.match(retry, />no</);
  assert.match(retry, />90 s</);
  const rules = view(RULES, [{ scope: 'repo', selector: 'x', kind: 'build', max_concurrent: 0, note: '' }]);
  assert.match(rules, />0 \(blocks every claim\)</);
});

// ------------------------------------------------------------------ A4

test('A4 the identity cell links to the row\'s change history; EDIT is its own unsortable column', () => {
  const cases = [
    [RULES, { scope: 'ticket', selector: '*', kind: '*', max_concurrent: 1, note: '' }, '/config/concurrency_rule/ticket%2F*%2F*', 'ticket / * / *'],
    [GATE, { scope: 'hub', window_days: 14, min_merges: 5, tighten_rate: 0.3, clear_rate: 0.1, note: '' }, '/config/review_gate_threshold/hub', 'hub'],
    [RETRY, { lane: 'build', max_attempts: 3, backoff_seconds: 60, escalate_allowed: 1, note: '' }, '/config/retry_policy/build', 'build'],
    [CONTRACTS, { phase: 'plan', artifact_kind: 'file', pattern: 'plan.md', note: '' }, '/config/phase_contract/plan', 'plan'],
  ];
  for (const [desc, row, href, name] of cases) {
    const out = view(desc, [row]);
    assert.ok(out.includes(`href="${href}"`), `${desc.kind}: no link to ${href} in ${out.slice(0, 0)}`);
    assert.match(out, new RegExp(`<a[^>]*href="${href.replace(/[*]/g, '\\*')}"[^>]*>${name.replace(/[*]/g, '\\*')}</a>`));
    const ths = out.match(/<th\b[^>]*>/g) || [];
    assert.equal(ths.length, fields(desc).length + 1);
    assert.doesNotMatch(ths.at(-1), /aria-sort/, `${desc.kind}: the EDIT column must not sort`);
    assert.ok(out.includes(`aria-label="edit ${name}"`), `${desc.kind}: EDIT button has no aria-label`);
    assert.ok(out.includes(`>EDIT ${name}<`), `${desc.kind}: EDIT button text`);
  }
  assert.deepEqual(matchRoute('/config/:kind/:name', '/config/concurrency_rule/ticket%2F*%2F*'), { kind: 'concurrency_rule', name: 'ticket/*/*' });
  for (const desc of CONTROL_KINDS) {
    const r = rowFor(desc, 1);
    assert.equal(desc.auditName(r), desc.keyFields.map((k) => r[k]).join('/'));
  }
});

test('A4 the edit modal labels its fields in plain words and explains the fraction', () => {
  const out = render(h(EditForm, { desc: GATE, value: { scope: 'hub', window_days: '14', min_merges: '5', tighten_rate: '0.3', clear_rate: '0.1', note: '', reason: '' },
    isNew: false, lists: {}, serverError: null, pending: false, onBlocked: noop }));
  assert.match(out, /<span class="knob__label">tighten rate<\/span>/);
  assert.doesNotMatch(out, /knob__label">[A-Z_]*_[A-Z_]*</);
  assert.match(out, /enter as a fraction, 0\.25 = 25%/);
  assert.match(out, /name="tighten_rate"/);
});

// ------------------------------------------------------------------ A5

test('A5 BUILD CEILINGS: caps per project, unlimited never 0, local rows flagged unverified', () => {
  const out = panel(SNAP);
  assertNoRawHeaders(out);
  assert.match(out, /BUILD CEILINGS/);
  assert.match(out, />unlimited</);
  assert.match(out, />4</);
  assert.match(out, /read on hub/);
  assert.match(out, /10m ago/);
  assert.match(out, /href="\/p\/alpha"/);
  assert.match(out, /does not apply/);
  assert.match(rowOf(out, 'beta'), /not verified for this project(&#39;|'|&#x27;)s box/);
  assert.doesNotMatch(rowOf(out, 'alpha'), /not verified/);
  // alpha's pool cap is "0", the pool's word for no ceiling: never shown as 0.
  assert.doesNotMatch(rowOf(out, 'alpha'), />0</);
  assert.equal((rowOf(out, 'alpha').match(/>unlimited</g) || []).length, 2, 'pool cap and effective both unlimited');
  assert.match(out, /<span class="th-raw">effective<\/span>/);
  for (const snapshot of [{ pushed_at: 'x', ceilings: null }, undefined, { pushed_at: 'x' }]) {
    const none = panel(snapshot);
    assert.match(none, /has not published build ceilings yet/);
    assert.doesNotMatch(none, /<table/);
  }
  assert.match(panel({ pushed_at: 'x', ceilings: [] }), /no projects in fleet\.conf/);
  const zero = panel({ ...SNAP, ceilings: [{ ...CEILINGS[1], effective: '0' }] });
  assert.match(zero, /0 \(blocks every build\)/);
  const unread = panel({ ...SNAP, ceilings: [{ ...CEILINGS[0], pool_cap: '?' }] });
  assert.match(rowOf(unread, 'alpha'), /unreadable/);
});

test('A5 ceilingRows sorts unlimited above a number and unknown below', () => {
  const c = ceilingRows(SNAP);
  assert.equal(c.message, null);
  assert.equal(c.boxRead, 'hub');
  assert.equal(c.rows[0].sortEff, Infinity);
  assert.equal(c.rows[1].sortEff, 4);
  assert.equal(ceilingRows({ ceilings: [{ ...CEILINGS[0], effective: '?' }] }).rows[0].sortEff, -1);
});

// ------------------------------------------------------------------ A6

test('A6 runningSummary: exact counts, a capped read never quoted as exact', () => {
  const jobs = Array.from({ length: 10 }, (_, i) => ({ id: i, kind: i < 7 ? 'build' : 'triage' }));
  assert.equal(runningSummary({ jobs }, 500), '10 jobs running now, 7 of them builds');
  const full = runningSummary({ jobs: Array.from({ length: 500 }, () => ({ kind: 'build' })) }, 500);
  assert.match(full, /500 or more/);
  assert.equal(runningSummary(null), 'running jobs could not be read');
  assert.equal(runningSummary({}), 'running jobs could not be read');
  assert.equal(runningSummary({ jobs: [] }), 'no jobs running now');
  assert.match(runningSummary({ jobs: [{ kind: 'build' }] }), /^1 job running now/);
  assert.match(panel(SNAP, loaded({ jobs })), /10 jobs running now, 7 of them builds/);
  assert.match(panel(SNAP, { data: null, error: new Error('x'), loading: false }), /running jobs could not be read/);
});

// ------------------------------------------------------------------ A7

test('A7 only the rules kind shows the ceilings panel', () => {
  for (const desc of CONTROL_KINDS) {
    const out = view(desc, [rowFor(desc, 1)], { snapshot: SNAP, running: loaded({ jobs: [] }) });
    if (desc === RULES) {
      assert.match(out, /BUILD CEILINGS/);
      assert.match(out, /href="\/p\/beta"/);
    } else {
      assert.doesNotMatch(out, /BUILD CEILINGS/, desc.kind);
      assert.doesNotMatch(out, /published build ceilings/, desc.kind);
    }
  }
  // The production route with no fleet provider: the panel says so, no crash.
  const live = render(h(ControlsScreen, { kind: 'rules' }));
  assert.match(live, /has not published build ceilings yet/);
  const withFleet = render(h(FleetContext.Provider, { value: { data: { snapshot: SNAP } } }, h(ControlsScreen, { kind: 'rules' })));
  assert.match(withFleet, /href="\/p\/alpha"/);
});

// ------------------------------------------------------------------ A8

const worldFixture = () => ({
  jobs: { jobs: [{ id: 'build-project-3-TK-1-1', project: 'project-3', box: 'project-3-1', stage: 'execute', status: 'running', heartbeating: true, activity_age_s: 60 }] },
  projects: { projects: [{ project: 'project-3', open_prs: 2, open_alerts: 0, fleet: { queue_depth: 3 } }] },
  machines: { boxes: { 'project-3-1': '2m ago' } },
  needs: { alerts: [], commands: [], builds: [], ideas: [] },
});

// WorldScreen and ChatScreen read document.hidden on first render
// (useDocumentVisible); SSR has no document, so lend them the one field.
function withDoc(fn) {
  const had = 'document' in globalThis;
  const prev = globalThis.document;
  globalThis.document = { hidden: false };
  try { return fn(); } finally { if (had) globalThis.document = prev; else delete globalThis.document; }
}

test('A8 World and WorldHex pass both helpers', () => {
  const hex = render(h(HexScene, { scene: buildScene(worldFixture()), selection: null, hint: '' }));
  assertNoRawHeaders(hex);
  assertUsdLabelled(hex);
  const world = withDoc(() => render(h(WorldScreen)));
  assert.match(world, /class="page/);
  assertNoRawHeaders(world);
  assertUsdLabelled(world);
});

test('A8 Chat: a day-old turn carries its date, a recent one says how long ago', () => {
  const msg = (ageMs) => render(h(ChatMessage, {
    m: { direction: 'in', command_id: 1, text: 'hi', created_at: new Date(NOW - ageMs).toISOString() },
    thread: [], nowMs: NOW, onResend: noop,
  }));
  const old = msg(4 * 86400e3);
  assert.match(old, /Sep 25 14:05Z/);
  assert.doesNotMatch(old.replace('Sep 25 14:05Z', ''), /14:05/);
  assert.match(msg(3 * 3600e3), /3h ago/);
  const screen = withDoc(() => render(h(FleetContext.Provider, { value: { data: { projects: [], snapshot_age_min: 1 } } }, h(ChatScreen))));
  assert.match(screen, /CHAT/);
  assertNoRawHeaders(screen);
  assertUsdLabelled(screen);
});
