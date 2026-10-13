import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { FlyProject } from '../src/screens/Machines.js';
import { FlyTile } from '../src/screens/Fleet.js';
import { flyProjectProps } from '../src/lib/fly.js';

// BH-667: on 2026-09-17 the console said "0 machines, 6 orphan jobs" about a
// project whose Fly token the Worker could not read, while six pool machines
// were running and heartbeating. The helpers being right is not the same as
// the screens telling the truth, so these render the REAL tile and the REAL
// section and read the HTML back.

const job = (n) => ({
  machine: `md17d4f${n}`, key: `BH-6${n}`, ticket_id: 6000 + n,
  spawned_at: '2026-09-17T18:00:00Z', attempt: 0
});
const machine = (n, state = 'started') => ({
  id: `md17d4f${n}`, role: 'pool', state, region: 'iad',
  created_at: '2026-09-17T18:00:00Z', job: job(n)
});

// Fixture A — the exact payload the deployed Worker emitted on 2026-09-17:
// an error entry AND a confident zero alongside six "orphans".
const A = {
  block: {
    machine_count: 0, machines: [], apps: ['cromford-pool'],
    orphan_jobs: [1, 2, 3, 4, 5, 6].map(job),
    jobs: [1, 2, 3, 4, 5, 6].map(job)
  },
  errors: [{ project: 'cromford', error: 'FLY_API_TOKEN_CROMFORD unset' }]
};
// Fixture B — readable token, 3 started machines, no orphans.
const B = {
  block: { machine_count: 3, machines: [1, 2, 3].map((n) => machine(n)), orphan_jobs: [], jobs: [1, 2, 3].map(job) },
  errors: []
};
// Fixture C — readable, and one job really has lost its machine.
const C = {
  block: { machine_count: 1, machines: [machine(1)], orphan_jobs: [job(9)], jobs: [job(1)] },
  errors: []
};
// Fixture D — the shape the Worker is asked to publish (spec doc), with no
// fly_errors entry at all, and no jobs: the unreadable EMPTY state.
const D = {
  block: { unreadable: true, unreadable_reason: 'fly token unset for this project', machine_count: null },
  errors: []
};
// Fixture E — somebody ELSE's token is missing. This project is fine.
const E = {
  block: { machine_count: 2, machines: [1, 2].map((n) => machine(n)), orphan_jobs: [], jobs: [1, 2].map(job) },
  errors: [{ project: 'harness-console', error: 'FLY_API_TOKEN_HARNESS_CONSOLE unset' }]
};
// Fixture F — readable, and the answer really is zero. "no machines up" is
// true here and must keep rendering.
const F = { block: { machine_count: 0, machines: [], orphan_jobs: [], jobs: [] }, errors: [] };

// The props come out of flyProjectProps against a whole /api/dash/machines
// payload — the same call both screens make — so no fixture here hands a
// component a prop set the production path cannot produce.
const payload = (f, project = 'cromford') => ({
  boxes: { 'hub-1': '2 min ago' },
  fly: { [project]: f.block },
  fly_errors: f.errors,
  snapshot_age_min: 1
});
const props = (f, project = 'cromford') => {
  const all = flyProjectProps(payload(f, project));
  const one = all.find((p) => p.project === project);
  assert.ok(one, `the payload builder produced props for ${project}`);
  return one;
};
const tile = (f, project = 'cromford') => render(h(FlyTile, props(f, project)));
const section = (f, project = 'cromford') => render(h(FlyProject, props(f, project)));

test('A: an unreadable project renders "cannot read" in the tile, never 0/0 up or an orphan claim', () => {
  const html = tile(A);
  assert.match(html, /cannot read/, 'the tile says it could not ask');
  assert.match(html, /FLY_API_TOKEN_CROMFORD unset/, 'and why');
  assert.ok(!html.includes('0/0 up'), 'a zero it could not measure is not reported');
  assert.ok(!html.includes('no longer returns'), 'no orphan claim from an unreadable machine list');
  assert.match(html, /BH-61/, 'the jobs come from the ledger, not from Fly, so they still list');
});

test('A: the machines section renders the cannot-read empty state, no table, no orphan banner', () => {
  const html = section(A);
  assert.match(html, /cannot read/, 'the section says it could not ask');
  assert.match(html, /Fly machines/, 'about this project’s Fly machines');
  assert.match(html, /FLY_API_TOKEN_CROMFORD unset/, 'and carries the reason');
  assert.ok(!html.includes('orphan job'), 'no orphan banner while the machine list is unreadable');
  assert.ok(!html.includes('no machines up'), '"no machines up" is a measurement we do not have');
  assert.ok(!html.includes('<table'), 'nothing to tabulate');
});

test('B: a readable project with 3 started machines still reads 3/3 up and tabulates them', () => {
  const t = tile(B);
  assert.match(t, /3\/3 up/, 'the live count is unchanged on the readable path');
  assert.ok(!t.includes('cannot read'), 'a readable block is not flagged');
  const s = section(B);
  assert.match(s, /<table/, 'the machine table still renders');
  assert.equal((s.match(/<tr/g) || []).length, 4, 'a header row plus one row per machine');
  assert.ok(!s.includes('cannot read'), 'a readable block is not flagged');
  assert.ok(!s.includes('orphan job'), 'no orphans in this fixture');
});

test('C: a real orphan on a readable project is still reported (the fix suppresses nothing)', () => {
  assert.match(section(C), /1 orphan job/, 'the section still warns');
  assert.match(tile(C), /1 job whose machine Fly no longer returns/, 'and so does the tile');
});

test('D: the unreadable flag alone is enough, with no fly_errors entry and no jobs', () => {
  const t = tile(D);
  assert.match(t, /cannot read/);
  assert.match(t, /fly token unset for this project/, 'the block carries its own reason');
  assert.ok(!t.includes('0/0 up'));
  assert.match(t, /no machine building right now/, 'the empty jobs state still renders');
  const s = section(D);
  assert.match(s, /cannot read/);
  assert.match(s, /fly token unset for this project/);
  assert.ok(!s.includes('no machines up'));
  assert.ok(!s.includes('<table'));
});

test('E: another project missing its token does not make this one unreadable', () => {
  const t = tile(E);
  assert.match(t, /2\/2 up/);
  assert.ok(!t.includes('cannot read'));
  const s = section(E);
  assert.match(s, /<table/);
  assert.ok(!s.includes('cannot read'));
});

test('F: a readable project that genuinely has nothing up still says "no machines up"', () => {
  const s = section(F);
  assert.match(s, /no machines up/, 'a measured zero is reportable');
  assert.ok(!s.includes('cannot read'));
  const t = tile(F);
  assert.match(t, /0\/0 up/, 'a measured zero is reportable');
  assert.ok(!t.includes('cannot read'));
});
