import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { BuildScreen, BuildMission } from '../src/screens/Build.js';
import { shouldPollLive } from '../src/lib/live.js';

// The helpers being right is not the same as the screen rendering. This renders
// the real component the /builds/:id route mounts and reads the HTML back, so
// "the mission view works" is a thing that was observed rather than assumed.
//
// The fixture is shaped exactly like the /api/jobs/:id/live contract: the job
// row, one job_phases row per phase, and stage events ascending by id.

const build = {
  id: 88,
  project: 'project-1',
  ticket_key: 'TK-7',
  bkey: 'build:project-1:TK-7:project-1-TK-7-1726',
  stage: 'executing',
  tier: 2,
  merged: 0,
  verdict: null,
  pr_url: null,
  age_min: 4,
  detail: null
};

const live = {
  job: {
    id: 'build-project-1-TK-7-1726', project: 'project-1', ticket_id: 'TK-7',
    stage: 'execute', status: 'running', budget_usd: 12, spent_usd: 3.1,
    updated_at: '2026-09-17T11:26:00Z'
  },
  phases: [
    { id: 1, phase: 'plan', runner: 'claude', model: 'claude-opus-5', status: 'done', started_at: '2026-09-17T11:20:00Z', finished_at: '2026-09-17T11:22:00Z', rc: 0, spend_usd: 0.4 },
    { id: 2, phase: 'execute', runner: 'claude', model: 'claude-fable-5-1', status: 'running', started_at: '2026-09-17T11:22:00Z', finished_at: null, rc: null, spend_usd: 2.7 },
    { id: 3, phase: 'review', runner: 'codex', model: 'gpt-5-codex', status: 'queued', started_at: null, finished_at: null, rc: null, spend_usd: null }
  ],
  events: [
    { id: 11, at: '2026-09-17T11:20:00Z', stage: 'plan', verdict: null, detail: 'plan: 3 files, 140 lines, tests named', actor: 'run-build' },
    { id: 12, at: '2026-09-17T11:21:00Z', stage: 'size_gate', verdict: 'PASS', detail: 'size gate: M, one PR', actor: 'run-build' },
    { id: 13, at: '2026-09-17T11:22:00Z', stage: 'tests_red', verdict: 'FAIL', detail: 'tests red as required: 2 failing', actor: 'run-build' },
    { id: 14, at: '2026-09-17T11:23:00Z', stage: 'execute', verdict: null, detail: 'execute started', actor: 'run-build' },
    { id: 15, at: '2026-09-17T11:25:00Z', stage: 'tests_green', verdict: 'PASS', detail: 'tests green: 248 pass', actor: 'run-build' },
    { id: 16, at: '2026-09-17T11:26:00Z', stage: 'semgrep', verdict: null, detail: 'semgrep: 0 findings', actor: 'run-build' }
  ],
  spend_usd: 3.1,
  cursor: 16,
  capped: false
};

const artifactAction = async () => ({ command_id: 1 });

const draw = (props) => render(h(BuildMission, {
  build, live, liveError: null, timeline: [], artifactAction, ...props
}));

// A value read out of a stat tile: the label and the number have to belong to
// each other, or "2" anywhere on the page would pass.
const statValue = (out, label) => {
  const at = out.indexOf(label);
  assert.notEqual(at, -1, `${label} is on screen`);
  return out.slice(at, at + 220);
};

test('the active step carries the latest sub-stage message', () => {
  const out = draw();
  // The build row still beats `executing` (step 1), but a semgrep event has
  // landed, so the strip is on `review` and the line under it is semgrep's.
  assert.match(out, /<span class="on">\s*review/, 'the strip advanced from the event, not the beat');
  assert.match(out, /class="build__sub"/, 'the sub-stage line exists');
  const sub = out.slice(out.indexOf('build__sub'), out.indexOf('build__sub') + 220);
  assert.ok(sub.includes('semgrep: 0 findings'), `the latest event of the active step is the message: ${sub}`);
});

test('one rail row per phase, each with the model that ran it', () => {
  const out = draw();
  assert.match(out, /<table/, 'the phases rail is a table, not a wall of divs');
  assert.equal((out.match(/<tr/g) || []).length, 4, 'a header row plus one row per phase');
  for (const model of ['claude-opus-5', 'claude-fable-5-1', 'gpt-5-codex']) {
    assert.ok(out.includes(model), `${model} is named on its phase row`);
  }
  for (const phase of ['plan', 'execute', 'review']) {
    assert.ok(out.includes(phase), `${phase} is a row`);
  }
  assert.ok(out.includes('$0.40') && out.includes('$2.70'), 'each phase carries its own spend');
  assert.ok(out.includes('2m 0s'), 'a closed phase shows how long it took');
});

test('the spend stat is the money this build has actually billed', () => {
  const out = draw();
  assert.ok(statValue(out, 'SPEND SO FAR').includes('$3.10'), '0.40 + 2.70, the summed phase spend');
});

test('GATES PASSED counts the gates that passed', () => {
  const out = draw();
  const v = statValue(out, 'GATES PASSED');
  assert.ok(/>2</.test(v), `size_gate PASS and tests_green PASS, and nothing else: ${v}`);
});

test('the six log rows run oldest to newest', () => {
  const out = draw();
  assert.equal((out.match(/class="log__row"/g) || []).length, 6, 'one row per event');
  // Scoped to the log pane: the sub-stage line above it repeats the newest
  // message, and reading that copy would pass whatever order the log is in.
  const log = out.slice(out.indexOf('class="build__log"'), out.indexOf('ARTIFACTS'));
  const red = log.indexOf('tests red as required');
  const green = log.indexOf('tests green: 248 pass');
  const semgrep = log.indexOf('semgrep: 0 findings');
  assert.ok(red > -1 && green > -1 && semgrep > -1, 'all three messages rendered');
  assert.ok(red < green, 'the older event is above the newer one');
  assert.ok(green < semgrep, 'the newest event is at the bottom, where the pane auto-scrolls to');
  assert.ok(log.includes('11:22Z') && log.includes('11:26Z'), 'each row is stamped with its own clock time');
});

test('verdicts are coloured through VERDICT_TONE', () => {
  const out = draw();
  assert.ok(out.includes('<span class="pill pill--dead">FAIL</span>'), 'a failing gate reads red');
  assert.ok(out.includes('<span class="pill">PASS</span>'), 'a passing gate reads green');
});

test('every rail header sorts and announces its state', () => {
  const out = draw();
  assert.match(out, /class="tablewrap/, 'the wrapper is the one with overflow-x:auto');
  assert.equal((out.match(/aria-sort="/g) || []).length, 6, 'all six columns announce their sort state');
  // Counted inside the table, so the artifact pane's own tab buttons cannot
  // stand in for a header the rail forgot to make clickable.
  const head = out.slice(out.indexOf('<thead'), out.indexOf('</thead>'));
  assert.equal((head.match(/<button type="button"/g) || []).length, 6, 'every header is clickable');
});

test('a finished job arms no timer and says the page is final', () => {
  const done = { ...live, job: { ...live.job, status: 'done' } };
  assert.equal(shouldPollLive(done, build), false, 'nothing is still running');
  const out = draw({ live: done });
  assert.ok(out.includes('FINAL · done'), 'the page says it has stopped watching, and on what status');
  assert.ok(!draw().includes('FINAL'), 'a running build is not final');
});

test('with no live payload at all, no panel is blank', () => {
  // This is the state every build is in until #520 deploys, and the state a
  // build with no job row stays in. The rail must never be empty while money
  // is being spent, so each panel falls back to the last deterministic fact.
  const out = draw({ live: null });
  assert.ok(out.includes('last beat: executing'), 'the sub-stage line falls back to the beat');
  assert.ok(out.includes('4m ago'), 'and says how old that beat is');
  assert.ok(statValue(out, 'SPEND SO FAR').includes('—'), 'unknown spend is a dash, never $0.00');
  assert.ok(out.includes('not on file'), 'and the pane says why');
  assert.ok(out.includes('no progress events yet'), 'the log names its own empty state');
  assert.ok(out.includes('no phase rows yet'), 'so does the rail');
  assert.equal((out.match(/class="log__row"/g) || []).length, 0);
});

test('a failed live read is not the same thing as no events', () => {
  const out = draw({ live: null, liveError: new Error('http_404') });
  assert.ok(out.includes('live feed unavailable'), 'the failure is named');
  assert.ok(out.includes('http_404'), 'with the reason the request actually returned');
  assert.equal((out.match(/no progress events yet/g) || []).length, 1,
    'the empty state still renders once, and does not claim the build is idle');
});

test('a build with no job record says so and never claims to be watching', () => {
  // Until #520 ships, and for any build older than the job lookup window, this
  // is the state the page is in. Nothing is polling, so nothing may say LIVE.
  const out = draw({ live: null, jobNote: 'no job record found in the last 200 jobs of project-1' });
  assert.ok(out.includes('no job record found'), 'the real reason is on screen');
  assert.ok(out.includes('NOT WATCHING'), 'and the badge matches what is actually happening');
  assert.ok(!out.includes('LIVE ·'), 'no timer is armed, so nothing reads as live');
  assert.ok(!out.includes('FINAL ·'), 'and an unfinished build is not called final either');
  assert.ok(out.includes('last beat: executing'), 'the deterministic fact is still shown');
});

test('the /builds/:id route component is the thing that mounts this view', () => {
  // BuildScreen is what src/app.js registers for /builds/:id. Rendered here it
  // is the first paint a browser gets, before any read has landed — it has to
  // render its own loading state rather than throw on a null build row.
  const out = render(h(BuildScreen, { id: '88' }));
  assert.match(out, /class="skel"/, 'the route component renders without a build row');

  // The mount itself cannot be rendered without a browser (the build row only
  // arrives in an effect, which render-to-string never runs), so it is pinned
  // in the source with the absent-symbol case guarded: a deleted or renamed
  // mount fails here instead of passing silently.
  const src = readFileSync(new URL('../src/screens/Build.js', import.meta.url), 'utf8');
  assert.notEqual(src.indexOf('export function BuildScreen'), -1, 'the route component is still exported');
  assert.notEqual(src.indexOf('<${BuildMission}'), -1, 'and it still mounts the component these tests render');
});

test('the artifacts pane stays as the on-demand deep dive', () => {
  const out = draw();
  assert.ok(out.includes('ARTIFACTS'), 'the existing pane is still on the page');
  assert.ok(out.includes('FETCH FRESH'), 'and is still the pull-on-request one');
});
