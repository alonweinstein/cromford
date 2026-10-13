import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  PIPELINE_COLUMNS,
  cardKind,
  cardKey,
  cardProject,
  cardRoute,
  filterPipeline,
  fleetProjects
} from '../src/lib/kanban.js';

test('the pipeline columns are exactly the six the API emits, in flow order', () => {
  // Inventing a seventh column (a `pr_open` lane, say) renders forever empty and
  // reads as a data bug — the API doc is explicit that it does not exist.
  assert.deepEqual(PIPELINE_COLUMNS.map((c) => c.key), [
    'queued', 'building', 'merge_queue', 'review', 'merged_deployed', 'dead_failed'
  ]);
});

test('a build card, a command card and a queue rollup are told apart', () => {
  assert.equal(cardKind({ id: 1, project: 'project-1', ticket: 'TK-1', stage: 'pr_created' }), 'build');
  assert.equal(cardKind({ command_id: 3, ckey: 'x', project: 'project-1', status: 'pending' }), 'command');
  assert.equal(cardKind({ project: 'project-3', queue_depth: 2, oldest_queued_min: 9 }), 'queue');
});

test('every card kind yields a stable react key and a project', () => {
  assert.equal(cardKey({ id: 7, ticket: 'TK-1', project: 'p' }), 'build:7');
  assert.equal(cardKey({ command_id: 3, ckey: 'c', project: 'p' }), 'command:3');
  assert.equal(cardKey({ project: 'project-3', queue_depth: 2 }), 'queue:project-3');
  assert.equal(cardProject({ project: 'project-3', queue_depth: 2 }), 'project-3');
});

test('a build card with a PR url routes to the PR drill-down, not to GitHub', () => {
  const card = {
    id: 1, project: 'project-1', ticket: 'TK-593', stage: 'pr_created',
    pr_url: 'https://github.com/example-org/project-1/pull/593'
  };
  assert.equal(cardRoute(card), '/pr/project-1/593');
});

test('a build card without a PR routes to its build detail', () => {
  const card = { id: 12, project: 'project-1', ticket: 'TK-4', stage: 'executing', pr_url: null };
  assert.equal(cardRoute(card), '/builds/12');
});

test('a malformed pr_url falls back to the build rather than routing to /pr/NaN', () => {
  const card = { id: 12, project: 'project-1', ticket: 'TK-4', pr_url: 'https://example.com/nope' };
  assert.equal(cardRoute(card), '/builds/12');
});

test('queue rollups and commands route to their project', () => {
  assert.equal(cardRoute({ project: 'project-3', queue_depth: 2 }), '/p/project-3');
  assert.equal(cardRoute({ command_id: 3, ckey: 'c', project: 'project-4', status: 'pending' }), '/p/project-4');
});

test('the project filter keeps counts honest instead of showing stale totals', () => {
  const payload = {
    columns: {
      queued: [{ project: 'project-3', queue_depth: 2 }],
      building: [{ id: 1, project: 'project-1', ticket: 'TK-1' }],
      merge_queue: [], review: [], merged_deployed: [], dead_failed: []
    },
    counts: { queued: 2, building: 1, merge_queue: 0, review: 0, merged_deployed: 0, dead_failed: 0 }
  };
  const filtered = filterPipeline(payload, 'project-1');
  assert.deepEqual(filtered.columns.queued, []);
  assert.equal(filtered.columns.building.length, 1);
  assert.equal(filtered.counts.building, 1);
  assert.equal(filtered.counts.queued, 0, 'the queued rollup for another project must not be counted');
});

test('no filter passes the payload through with the API counts intact', () => {
  const payload = {
    columns: { queued: [{ project: 'project-3', queue_depth: 2 }], building: [], merge_queue: [], review: [], merged_deployed: [], dead_failed: [] },
    counts: { queued: 2, building: 0, merge_queue: 0, review: 0, merged_deployed: 0, dead_failed: 0 }
  };
  const out = filterPipeline(payload, null);
  assert.equal(out.counts.queued, 2, 'the queued count is a queue-depth sum, not a card count');
});

test('a missing column renders as empty, never as undefined', () => {
  const out = filterPipeline({ columns: {}, counts: {} }, null);
  for (const col of PIPELINE_COLUMNS) {
    assert.deepEqual(out.columns[col.key], [], `${col.key} must be an array`);
  }
});


test('building_stale survives filtering and is never folded into the in-flight count', () => {
  // `columns.building` is freshness-bounded (touched <60min = truly in flight).
  // `building_stale` counts unmerged rows stuck in a build stage for longer —
  // abandoned attempts the hub still has to sweep. Adding them together would
  // claim 33 machines are building when 3 are.
  const payload = {
    columns: { queued: [], building: [{ id: 1, project: 'project-1', ticket: 'TK-1' }], merge_queue: [], review: [], merged_deployed: [], dead_failed: [] },
    counts: { queued: 0, building: 1, merge_queue: 0, review: 0, merged_deployed: 0, dead_failed: 0 },
    building_stale: 30
  };
  const all = filterPipeline(payload, null);
  assert.equal(all.counts.building, 1, 'the in-flight count stays the in-flight count');
  assert.equal(all.building_stale, 30, 'and the stale count survives alongside it');
});

test('a stale count with no project attribution is flagged as fleet-wide when filtered', () => {
  // The number is a fleet total: rendering it beside one project's column
  // without saying so claims those stale builds belong to that project.
  const payload = {
    columns: { queued: [], building: [{ id: 1, project: 'project-1', ticket: 'TK-1' }], merge_queue: [], review: [], merged_deployed: [], dead_failed: [] },
    counts: { building: 1 },
    building_stale: 30
  };
  const filtered = filterPipeline(payload, 'project-1');
  assert.equal(filtered.building_stale, 30);
  assert.equal(filtered.building_stale_is_fleet_wide, true);
  assert.equal(filterPipeline(payload, null).building_stale_is_fleet_wide, false);
});

test('an absent building_stale is zero, not undefined', () => {
  const out = filterPipeline({ columns: {}, counts: {} }, null);
  assert.equal(out.building_stale, 0);
});

test('hub and fleet are literals, never rendered as projects', () => {
  // A "BOARD · hub" pane can never fill — hub owns no board and no builds.
  assert.deepEqual(fleetProjects(['project-1', 'hub', 'project-4', 'fleet']), ['project-1', 'project-4']);
  assert.deepEqual(fleetProjects([]), []);
  assert.deepEqual(fleetProjects(null), []);
});
