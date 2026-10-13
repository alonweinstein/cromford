import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../../src/index.js';
import REGISTRY from '../../../../catalog/lanes.json' with { type: 'json' };

// GET /api/lanes/status and the PER-PROJECT HOLD (BH-1466, the page half of
// BH-1419).
//
// #1463 gave five hub lanes `"per_project_hold": true` and a gate that reads
// ONE row, `lane-off-<id>-<project>`, to stop that lane for that project only.
// Until this slice the status route never looked that row up for a hub lane, so
// Mission Control drew the conductor as running on project-3's tab while the gate
// was skipping every project-3 tick. The hold was real and invisible — which is the
// lie the lane registry exists to end.
//
// WHAT IS PROVEN HERE (D2: through worker.fetch and the real route table, and
// against the REAL composed registry, not a hand-built one): that the row is
// read only under `?project=`, that it never marks a lane off fleet-wide, that
// a sibling project's flag FILE does not bleed across tabs, and — the negative
// that matters most — that `scoped` was NOT widened, so the knob key and the
// cost attribution of a hub lane are byte-identical with and without a project.

const SECRET = 'test-secret';

const HOLD = 'merge-conductor';   // per_project_hold: true (#1463)
const PLAIN = 'alert-triage';     // a plain hub lane, same scope, no hold
const P = 'project-3';
const Q = 'project-4';

function fakeDB(state) {
  const calls = [];
  const result = (sql, binds) => {
    calls.push({ sql: sql.replace(/\s+/g, ' ').trim(), binds });
    if (/FROM pause_flags WHERE name='all-off'/.test(sql)) {
      return { rows: (state.flags || []).filter((f) => f.name === 'all-off') };
    }
    if (/FROM pause_flags/.test(sql)) return { rows: state.flags || [] };
    if (/FROM settings WHERE key LIKE/.test(sql)) return { rows: state.settings || [] };
    if (/FROM lane_ticks/.test(sql)) {
      if (state.throwOn === 'lane_ticks') throw new Error('no such table: lane_ticks');
      return { rows: state.ticks || [] };
    }
    if (/FROM lane_flag_sightings/.test(sql)) {
      if (state.throwOn === 'lane_flag_sightings') throw new Error('no such table: lane_flag_sightings');
      return { rows: state.sightings || [] };
    }
    if (/FROM lanes/.test(sql)) return { rows: state.lanes || [] };
    if (/ts, stage, project, ticket, cost_usd, run_id FROM cost_rows/.test(sql)) {
      return { rows: state.recent || [] };
    }
    // The spend aggregate arrives pre-grouped, exactly as GROUP BY stage,
    // project hands it back: the claim under test is which GROUPS a lane
    // claims, never SQLite's SUM.
    if (/FROM cost_rows/.test(sql)) return { rows: state.spend || [] };
    return { rows: [] };
  };
  const stmt = (sql) => ({
    bind: (...binds) => ({
      first: async () => result(sql, binds).rows[0] || null,
      all: async () => ({ results: result(sql, binds).rows }),
      run: async () => { result(sql, binds); return { meta: { changes: 1 } }; }
    }),
    first: async () => result(sql, []).rows[0] || null,
    all: async () => ({ results: result(sql, []).rows }),
    run: async () => { result(sql, []); return { meta: { changes: 1 } }; }
  });
  return { prepare: stmt, _calls: calls };
}

const call = (path, { state = {} } = {}) => {
  const db = fakeDB(state);
  const req = new Request(`https://jobs.test${path}`, {
    method: 'GET',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` }
  });
  return worker.fetch(req, { DB: db, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null), db
  }));
};

const FLAG = (name, over = {}) => ({
  name, active: 1, actor: 'operator', reason: 'pause project-3 fix rounds',
  updated_at: '2026-09-21T09:00:00Z', ...over
});
const SIGHT = (name, over = {}) => ({
  name, box: 'hub', lane: HOLD, project: null, active: 1,
  seen_at: '2026-09-21T10:00:00Z', ...over
});
const lane = (r, id) => r.body.lanes.find((l) => l.id === id);
const decl = (id) => (REGISTRY.lanes || []).find((l) => l.id === id);

// 0 ── THE FIXTURE ITSELF IS AN ASSERTION. Both lanes come from the composed
// registry, so a `per_project_hold` that fell out of catalog/lanes.d/ (or a
// lanes-build.sh that stopped passing the field through) fails here loudly
// instead of turning every case below into a green that proves nothing.
test('the real registry still declares the hold on merge-conductor and not on alert-triage', () => {
  assert.equal(decl(HOLD).per_project_hold, true);
  assert.equal(decl(PLAIN).per_project_hold, undefined);
  assert.equal(decl(HOLD).scope, 'hub');
  assert.equal(decl(PLAIN).scope, 'hub');
});

// 1 ──────────────────────────────────────────────────────────────────────────
test('under ?project= the per-project row stops a hold lane, and only a hold lane', async () => {
  const state = {
    flags: [FLAG(`lane-off-${HOLD}-${P}`), FLAG(`lane-off-${PLAIN}-${P}`)]
  };
  const r = await call(`/api/lanes/status?project=${P}`, { state });
  assert.equal(r.status, 200);

  const h = lane(r, HOLD);
  assert.equal(h.off, true);
  assert.equal(h.off_source, 'db');
  assert.deepEqual(h.held_by, [`lane-off-${HOLD}-${P}`]);
  assert.equal(h.paused_by, 'operator');
  assert.equal(h.paused_reason, 'pause project-3 fix rounds');
  assert.equal(h.paused_since, '2026-09-21T09:00:00Z');
  assert.equal(h.per_project_hold, true);
  // The SWITCH the row names is unchanged: it is the fleet-wide one, and the
  // console builds the per-project name itself from the tab it is on.
  assert.equal(h.switch.name, `lane-off-${HOLD}`);

  // A plain hub lane with a stray per-project row is NOT off. The gate ignores
  // that row too (#1463 reads it only for per_project_hold lanes), so a page
  // that honoured it would report a stop nothing enforces.
  const p = lane(r, PLAIN);
  assert.equal(p.off, false);
  assert.deepEqual(p.held_by, []);
  assert.equal(p.per_project_hold, false);
});

// 2 ──────────────────────────────────────────────────────────────────────────
test('the same row never marks the lane off fleet-wide', async () => {
  const state = {
    flags: [FLAG(`lane-off-${HOLD}-${P}`), FLAG(`lane-off-${PLAIN}-${P}`)]
  };
  const r = await call('/api/lanes/status', { state });
  assert.equal(r.status, 200);
  assert.equal(lane(r, HOLD).off, false, 'a per-project hold is not a fleet stop');
  assert.deepEqual(lane(r, HOLD).held_by, []);
  assert.equal(lane(r, PLAIN).off, false);
  assert.deepEqual(lane(r, PLAIN).held_by, []);
});

// 3 ──────────────────────────────────────────────────────────────────────────
test("a sibling project's flag FILE does not report the lane stopped on this tab", async () => {
  // BH-1165 round 2, now reachable for the five hold lanes because per-project
  // files exist for them at all.
  const state = { sightings: [SIGHT(`lane-off-${HOLD}-${Q}`, { project: Q })] };

  const onP = await call(`/api/lanes/status?project=${P}`, { state });
  assert.equal(lane(onP, HOLD).off, false, "project-4's file does not stop project-3's conductor");
  assert.deepEqual(lane(onP, HOLD).flag_boxes, []);

  const onQ = await call(`/api/lanes/status?project=${Q}`, { state });
  assert.equal(lane(onQ, HOLD).off, true);
  assert.equal(lane(onQ, HOLD).off_source, 'flag');
  assert.ok(lane(onQ, HOLD).held_by.includes(`lane-off-${HOLD}-${Q}`));
  assert.deepEqual(lane(onQ, HOLD).flag_boxes, ['hub']);

  // A sighting that names NO project is box-wide and still holds every tab —
  // the name is one this view never built, so it lands on the lane fallback.
  const boxWide = { sightings: [SIGHT('merge-conductor-stopped-by-hand', { project: '-' })] };
  const wide = await call(`/api/lanes/status?project=${P}`, { state: boxWide });
  assert.equal(lane(wide, HOLD).off, true, 'a box-wide file still holds');
});

// 4 ──────────────────────────────────────────────────────────────────────────
test('`scoped` is NOT widened: the hold lane keeps its hub knob key and hub cost', async () => {
  const state = {
    settings: [
      { key: `lane.${HOLD}.mc_merge_budget`, value: '8', actor: 'operator', updated_at: '2026-09-21T08:00:00Z' },
      { key: `lane.${HOLD}.${P}.mc_merge_budget`, value: '3', actor: 'operator', updated_at: '2026-09-21T08:30:00Z' }
    ],
    spend: [
      { stage: 'review', project: P, cost_today: 5, runs_today: 1, cost_7d: 5 },
      { stage: 'review', project: Q, cost_today: 7, runs_today: 2, cost_7d: 7 }
    ],
    recent: [
      { ts: '2026-09-21T11:00:00Z', stage: 'review', project: P, ticket: 'BH-1', cost_usd: 5, run_id: 'a' },
      { ts: '2026-09-21T11:05:00Z', stage: 'review', project: Q, ticket: 'BH-2', cost_usd: 7, run_id: 'b' }
    ],
    ticks: [{ lane: HOLD, project: null, box: 'hub', last_tick_at: '2026-09-21T11:10:00Z', last_outcome: 'ok', why: null }]
  };
  const keep = (l) => ({
    knobs: l.knobs, runs_today: l.runs_today, cost_today: l.cost_today, cost_7d: l.cost_7d,
    cost_attribution: l.cost_attribution, cost_shared_with: l.cost_shared_with,
    cost_rows: l.cost_rows, last_tick_at: l.last_tick_at, last_outcome: l.last_outcome
  });

  const onP = await call(`/api/lanes/status?project=${P}`, { state });
  const hub = await call('/api/lanes/status', { state });
  assert.deepEqual(keep(lane(onP, HOLD)), keep(lane(hub, HOLD)),
    'a hub lane reads the same knob row and claims the same spend on every tab');

  // Named, so the failure says WHICH half moved: a hub lane never reads a
  // per-project knob row, because it cannot act on one.
  const k = lane(onP, HOLD).knobs.MC_MERGE_BUDGET;
  assert.equal(k.key, `lane.${HOLD}.mc_merge_budget`);
  assert.equal(k.value, 8, 'the lane.<id>.<project>.<env> row is ignored for a hub lane');
  assert.equal(lane(onP, HOLD).last_tick_at, '2026-09-21T11:10:00Z');
});

// 5 ──────────────────────────────────────────────────────────────────────────
test('a sightings table the worker cannot read leaves the hold lane not-off, never off', async () => {
  const r = await call(`/api/lanes/status?project=${P}`, { state: { throwOn: 'lane_flag_sightings' } });
  assert.equal(r.status, 200, 'an unreadable side table degrades the column, it does not 500 the page');
  assert.equal(lane(r, HOLD).off, false, 'unread is not "off"');
  assert.deepEqual(lane(r, HOLD).flag_boxes, []);
});
