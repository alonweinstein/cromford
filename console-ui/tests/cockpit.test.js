import test from 'node:test';
import assert from 'node:assert/strict';
import {
  runOutcome, outcomeRank, runDurationSeconds, parseTickSummary, tickWork,
  diskPercent, diskTone, needRows, summariseNeeds, needSeverityRank, facet
} from '../src/lib/cockpit.js';

// The rules under test are the ones that would go wrong quietly: an exit code
// that stops reading as a failure, a counter nobody beat rendering as a
// confident zero, a parked build that drops out of the needs queue.

test('a non-zero exit is a failure, and a kill is its own story', () => {
  assert.equal(runOutcome({ rc: 0 }), 'ok');
  assert.equal(runOutcome({ rc: 1 }), 'failed');
  // 127 (command not found), 137 (SIGKILL/OOM) and 143 (SIGTERM) all appear in
  // the real ledger. They are infrastructure, not a triage result.
  for (const rc of [126, 127, 130, 137, 143]) {
    assert.equal(runOutcome({ rc }), 'killed', String(rc));
  }
  assert.equal(runOutcome({ rc: null }), 'unknown');
  assert.equal(runOutcome({}), 'unknown');
  assert.equal(runOutcome(null), 'unknown');
  // D1 hands integers back as numbers, but a beat could have written a string.
  assert.equal(runOutcome({ rc: '0' }), 'ok');
  assert.equal(runOutcome({ rc: 'weird' }), 'unknown');
});

test('sorting an outcome column puts the failures on top, not the clean runs', () => {
  const rows = [{ rc: 0 }, { rc: 137 }, { rc: 1 }, { rc: null }];
  const ranked = rows.slice().sort((a, b) => outcomeRank(a) - outcomeRank(b));
  assert.deepEqual(ranked.map(runOutcome), ['failed', 'killed', 'unknown', 'ok']);
});

test('a duration needs both ends, and never goes backwards', () => {
  assert.equal(runDurationSeconds({ started_at: '2026-08-28T21:16:01Z', finished_at: '2026-08-28T21:17:11Z' }), 70);
  assert.equal(runDurationSeconds({ started_at: '2026-08-28T21:16:01Z' }), null);
  assert.equal(runDurationSeconds({ finished_at: '2026-08-28T21:16:01Z' }), null);
  assert.equal(runDurationSeconds({ started_at: 'nonsense', finished_at: '2026-08-28T21:16:01Z' }), null);
  // A clock skew is not a negative run.
  assert.equal(runDurationSeconds({ started_at: '2026-08-28T21:17:11Z', finished_at: '2026-08-28T21:16:01Z' }), null);
  assert.equal(runDurationSeconds(null), null);
});

test('a tick summary parses into counters and the bracketed gate metadata', () => {
  const s = parseTickSummary(
    'tickets=1 new=0 triaged=0 buildable=0 built=0 commented=0 ' +
    '[gate=board-changed scope=1 model=claude-fable-5 cost=$metered]');
  assert.equal(s.counters.tickets, 1);
  assert.equal(s.counters.built, 0);
  assert.equal(s.meta.gate, 'board-changed');
  assert.equal(s.meta.model, 'claude-fable-5');
  assert.equal(s.meta.cost, '$metered');
  assert.equal(s.prose, null);
});

test('a lane that beats prose instead of counters is prose, not zeros', () => {
  const s = parseTickSummary(
    'No open `ai-build` issues on example-org/project-6-runtime this tick. Logged and exiting quietly. ' +
    '[gate=gate-fetch-failed scope=full model=claude-fable-5]');
  assert.deepEqual(s.counters, {});
  assert.equal(s.meta.gate, 'gate-fetch-failed');
  assert.match(s.prose, /^No open/);
  // And the strip must not invent numbers for it.
  assert.deepEqual(tickWork(s.prose === null ? '' : 'anything without pairs').built, null);
});

test('trailing punctuation in a beat does not turn a counter into a string', () => {
  // project-9 really beats "commented=0`" — the backtick is in the ledger.
  const w = tickWork('tickets=4 new=2 triaged=0 buildable=0 built=0 commented=0` [gate=board-changed]');
  assert.equal(w.commented, 0);
  assert.equal(typeof w.commented, 'number');
});

test('a counter nobody beat is absent, never zero', () => {
  const w = tickWork('tickets=1 new=0');
  assert.equal(w.tickets, 1);
  assert.equal(w.built, null, 'built was never beaten, so it must not read as 0');
  assert.equal(w.commented, null);
  assert.equal(tickWork('').tickets, null);
  assert.equal(tickWork(null).tickets, null);
});

test('project-2 calls it actionable and everyone else calls it triaged', () => {
  assert.equal(tickWork('tickets=1 new=0 actionable=2 built=0 commented=0').triaged, 2);
  assert.equal(tickWork('tickets=1 new=0 triaged=3 built=0 commented=0').triaged, 3);
});

test('disk pressure is read out of the box\'s own prose, and unknown stays unknown', () => {
  assert.equal(diskPercent('87% used, 2.1G free'), 87);
  assert.equal(diskPercent('29% used, 28G free'), 29);
  assert.equal(diskPercent('who knows'), null);
  assert.equal(diskPercent(null), null);
  assert.equal(diskTone(91), 'dead');
  assert.equal(diskTone(87), 'warn');
  assert.equal(diskTone(29), 'ok');
  assert.equal(diskTone(null), 'muted', 'an unread disk is not a healthy disk');
});

const PAYLOAD = {
  alerts: [{ id: 4284, akey: 'medic:abc:21', ts: '2026-08-28T21:18:49Z', project: 'project-4', line: 'PR #1356 parked' }],
  commands: [
    { id: 6460, ckey: 'project-3:webhook_triage:1', type: 'run_triage', project: 'project-3', status: 'dead_letter', result: 'ssh unreachable', updated_at: '2026-08-18T13:25:57Z' },
    { id: 6461, ckey: 'project-3:webhook_triage:2', type: 'run_triage', project: 'project-3', status: 'failed', result: null, updated_at: '2026-08-18T13:26:57Z' }
  ],
  builds: [
    { id: 2823, bkey: 'build:project-4:TK-1273:x', project: 'project-4', ticket_key: 'TK-1273', stage: 'pr_created', tier: 2, verdict: 'APPROVE', pr_url: 'https://github.com/example-org/project-4/pull/1386', merged: 0, updated_at: '2026-08-28T15:57:53Z' },
    { id: 2100, bkey: 'build:project-3:TK-9:x', project: 'project-3', ticket_key: 'TK-9', stage: 'plan_blocked', tier: null, verdict: '', pr_url: '', merged: 0, updated_at: '2026-08-20T15:57:53Z' }
  ],
  proposals: [{ pkey: 'prop:project-3:x', project: 'project-3', slug: 'x', title: 'A gated idea', score: 128, updated_at: '2026-08-10T14:41:01Z' }]
};

test('every needs row has a destination — a to-do list that dead-ends is not one', () => {
  const rows = needRows(PAYLOAD);
  assert.equal(rows.length, 6);
  for (const r of rows) {
    assert.ok(r.to && r.to.startsWith('/'), `${r.kind} row must link somewhere, got ${r.to}`);
    assert.ok(r.title, `${r.kind} row must say what it is`);
  }
  assert.equal(rows.find((r) => r.kind === 'proposal').to, '/ideas/project-3/x');
  assert.equal(rows.find((r) => r.kind === 'alert').to, '/alerts');
});

test('a stopped plan outranks a PR waiting on a merge, and the gate is quietest', () => {
  const rows = needRows(PAYLOAD);
  const byId = Object.fromEntries(rows.map((r) => [r.id, r]));
  assert.equal(byId['build:2100'].severity, 'high', 'plan_blocked is stopped');
  assert.equal(byId['build:2823'].severity, 'medium', 'pr_created is only waiting');
  assert.equal(byId['command:6460'].severity, 'high', 'a dead-letter is out of retries');
  assert.equal(byId['command:6461'].severity, 'medium', 'a failed command may still retry');
  assert.equal(byId['proposal:prop:project-3:x'].severity, 'low');
  const sorted = rows.slice().sort((a, b) => needSeverityRank(a) - needSeverityRank(b));
  assert.equal(sorted[sorted.length - 1].kind, 'proposal');
});

test('a command with no beaten reason says so rather than rendering blank', () => {
  const row = needRows(PAYLOAD).find((r) => r.id === 'command:6461');
  assert.match(row.title, /no reason beaten/);
});

test('the summary counts every source, and a project-less row belongs to the fleet', () => {
  const s = summariseNeeds({ ...PAYLOAD, alerts: [{ id: 1, ts: null, project: '', line: 'hub is down' }] });
  assert.equal(s.total, 6);
  assert.equal(s.byKind.build, 2);
  assert.equal(s.byKind.proposal, 1);
  assert.equal(s.byProject.fleet, 1, 'an alert with no project is a fleet-level item');
  assert.equal(summariseNeeds(null).total, 0);
  assert.deepEqual(needRows(null), []);
  assert.deepEqual(needRows({}), []);
});

test('a facet drops blanks and sorts, so no chip filters to nothing', () => {
  assert.deepEqual(facet([{ p: 'b' }, { p: 'a' }, { p: '' }, { p: null }, { p: 'a' }], 'p'), ['a', 'b']);
  assert.deepEqual(facet(null, 'p'), []);
});
