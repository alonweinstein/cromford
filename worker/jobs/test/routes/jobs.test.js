import test from 'node:test';
import assert from 'node:assert/strict';
import { CLAIM, LANE, RULE, RUNNING, call, insertOf, iso, now, sqlOf, worker } from '../lib/harness.js';

const FLAG = (name, over) => ({ name, active: 1, actor: 'console', reason: null, updated_at: iso(60e3), ...over });

test('no bearer, no data', async () => {
  const r = await call('/api/jobs', { secret: null });
  assert.equal(r.status, 401);
  const wrong = await call('/api/jobs', { secret: 'nope' });
  assert.equal(wrong.status, 401);
});

test('a job row carries its beat age and whether it has ever beaten', async () => {
  const state = { jobs: [
    RUNNING({ last_beat_at: iso(120e3) }),
    RUNNING({ id: 'triage-1', last_beat_at: null })
  ] };
  const r = await call('/api/jobs', { state });
  assert.equal(r.status, 200);
  const [a, b] = r.body.jobs;
  assert.equal(a.heartbeating, true);
  assert.ok(a.beat_age_s >= 118 && a.beat_age_s <= 125, `beat age was ${a.beat_age_s}`);
  assert.equal(b.heartbeating, false);
  assert.equal(b.beat_age_s, null);
  // A row that never beat still gets an activity age, from its own updated_at -
  // coarser, but never null, so a pre-phase-3 box is watched rather than unseen.
  assert.ok(b.activity_age_s > 1700);
});

test('stale_min returns only OPEN rows past the threshold', async () => {
  const state = { jobs: [
    RUNNING({ id: 'fresh', last_beat_at: iso(60e3), updated_at: iso(60e3) }),
    RUNNING({ id: 'stale', last_beat_at: iso(2400e3), updated_at: iso(2400e3) }),
    RUNNING({ id: 'closed', status: 'done', last_beat_at: iso(9000e3), updated_at: iso(9000e3) })
  ] };
  const r = await call('/api/jobs?status=running&stale_min=10', { state });
  assert.deepEqual(r.body.jobs.map((j) => j.id), ['stale']);
});

test('activity age takes the FRESHEST evidence of life, not the beat alone', async () => {
  // A row whose beat is old but which just transitioned stage is alive: the
  // watchdog must not orphan a job that is demonstrably still working.
  const state = { jobs: [RUNNING({ id: 'working', last_beat_at: iso(3000e3), updated_at: iso(30e3) })] };
  const r = await call('/api/jobs?status=running&stale_min=10', { state });
  assert.deepEqual(r.body.jobs, []);
});

test('with no rule rows a claim is unlimited - an empty table is phase-5 behaviour', async () => {
  const state = { jobs: [RUNNING({ id: 'other', ticket_id: 'TK-1' })], rules: [] };
  const r = await call('/api/jobs', { ...CLAIM(), state });
  assert.equal(r.status, 201);
});

test('the ticket rule refuses a second claim on the same ticket, fleet-wide', async () => {
  // The TK-66/67 class: another BOX, and now also another KIND, on one ticket.
  const state = {
    jobs: [RUNNING({ id: 'build-project-3-TK-70-1', ticket_id: 'TK-70', box: 'box-a', kind: 'fix' })],
    rules: [RULE('ticket', '*', '*', 1)]
  };
  const r = await call('/api/jobs', { ...CLAIM(), state });
  assert.equal(r.status, 409);
  assert.equal(r.body.refused, true);
  assert.equal(r.body.scope, 'ticket');
  assert.match(r.body.reason, /ticket max 1 already running: build-project-3-TK-70-1 on box-a/);
});

test('a ticket rule does not fire on a DIFFERENT ticket in the same repo', async () => {
  const state = {
    jobs: [RUNNING({ id: 'elsewhere', ticket_id: 'TK-1', box: 'box-a' })],
    rules: [RULE('ticket', '*', '*', 1)]
  };
  const r = await call('/api/jobs', { ...CLAIM(), state });
  assert.equal(r.status, 201, 'a rule that fires on the wrong peers is a coincidence, not a decision');
});

test('a ticketless claim cannot be refused by the ticket rule', async () => {
  // A triage tick has no ticket. Counting it against "the same ticket" would
  // collide every tick on one empty key and stop the boards.
  const state = {
    jobs: [RUNNING({ id: 'triage-1', ticket_id: null, kind: 'triage', box: 'box-a' })],
    rules: [RULE('ticket', '*', '*', 1)]
  };
  const r = await call('/api/jobs', { ...CLAIM({ ticket_id: null, kind: 'triage' }), state });
  assert.equal(r.status, 201);
});

test('the repo rule binds only the kind it names', async () => {
  const state = {
    jobs: [RUNNING({ id: 'build-project-3-TK-1-1', ticket_id: 'TK-1', kind: 'build', box: 'box-a' })],
    rules: [RULE('repo', '*', 'build', 1)]
  };
  const blocked = await call('/api/jobs', { ...CLAIM(), state });
  assert.equal(blocked.status, 409);
  assert.equal(blocked.body.scope, 'repo');
  // The same repo, the same running build, a TRIAGE claim: the rule says build,
  // so it must not touch this one.
  const allowed = await call('/api/jobs', { ...CLAIM({ kind: 'triage', ticket_id: null }), state });
  assert.equal(allowed.status, 201);
});

test('the box rule counts the box, not the repo', async () => {
  const state = {
    jobs: [RUNNING({ id: 'build-project-4-C-1', project: 'project-4', ticket_id: 'C-1', box: 'box-project-3-2' })],
    rules: [RULE('box', '*', 'build', 1)]
  };
  const r = await call('/api/jobs', { ...CLAIM(), state });
  assert.equal(r.status, 409);
  assert.equal(r.body.scope, 'box');
  // A different box, same everything else: allowed.
  const other = await call('/api/jobs', { ...CLAIM({ box: 'fly-builder-7' }), state });
  assert.equal(other.status, 201);
});

test('the lane rule counts peers by the lane recorded on their claim', async () => {
  const state = {
    jobs: [
      RUNNING({ id: 'a', ticket_id: 'A', box: 'box-a' }),
      RUNNING({ id: 'b', ticket_id: 'B', box: 'box-b' })
    ],
    claims: [{ job_id: 'a', lane: 'plan/project-3/claude', attempts: 1 },
      { job_id: 'b', lane: 'execute/project-3/claude', attempts: 1 }],
    rules: [RULE('lane', 'plan/project-3/claude', '*', 1)]
  };
  const r = await call('/api/jobs', { ...CLAIM(), state });
  assert.equal(r.status, 409);
  assert.equal(r.body.scope, 'lane');
  assert.equal(r.body.running, 1, 'only the row in THIS lane counts');
});

test('an exact selector outranks the wildcard row', async () => {
  // The ladder that lets one noisy repo be loosened without loosening the fleet.
  const state = {
    jobs: [RUNNING({ id: 'build-project-3-TK-1-1', ticket_id: 'TK-1', kind: 'build', box: 'box-a' })],
    rules: [RULE('repo', '*', 'build', 1), RULE('repo', 'project-3', 'build', 5)]
  };
  const r = await call('/api/jobs', { ...CLAIM(), state });
  assert.equal(r.status, 201, 'the project-3 row allows 5, so one running build must not refuse');
});

test('a claim never counts itself as its own peer', async () => {
  // A re-claim of the same id is idempotent (RESUME_BUILD relies on it). If the
  // row it is re-claiming counted as a peer, a resume would lock itself out.
  const state = {
    jobs: [RUNNING({ id: 'build-project-3-TK-70-x', ticket_id: 'TK-70', box: 'box-project-3-2' })],
    rules: [RULE('repo', '*', 'build', 1)]
  };
  const r = await call('/api/jobs', { ...CLAIM({ id: 'build-project-3-TK-70-x', ticket_id: 'TK-9' }), state });
  assert.equal(r.status, 201);
});

test('a due retry row is TAKEN OVER by the next claim, attempts+1, same job id', async () => {
  const state = {
    jobs: [RUNNING({ id: 'build-project-3-TK-70-1', ticket_id: 'TK-70', status: 'queued_for_retry', box: 'box-a' })],
    claims: [{ job_id: 'build-project-3-TK-70-1', lane: 'plan/project-3/claude', attempts: 1,
      max_attempts: 3, next_attempt_at: iso(60e3) }]
  };
  const r = await call('/api/jobs', { ...CLAIM(), state });
  assert.equal(r.status, 200);
  assert.equal(r.body.retry, true);
  assert.equal(r.body.attempts, 2);
  const upd = r.db._calls.find((c) => /UPDATE jobs SET status=\?2, box=\?3/.test(c.sql));
  assert.ok(upd, 'the queued row must be taken over, not left behind');
  assert.deepEqual(upd.binds.slice(0, 3), ['build-project-3-TK-70-1', 'running', 'box-project-3-2']);
  // ...and a fresh row was NOT inserted alongside it.
  assert.equal(r.db._calls.filter((c) => /INSERT INTO jobs/.test(c.sql)).length, 0);
});

test('a retry that is not due yet REFUSES the claim rather than starting fresh', async () => {
  const state = {
    jobs: [RUNNING({ id: 'build-project-3-TK-70-1', ticket_id: 'TK-70', status: 'queued_for_retry', box: 'box-a' })],
    claims: [{ job_id: 'build-project-3-TK-70-1', lane: 'plan/project-3/claude', attempts: 1,
      max_attempts: 3, next_attempt_at: new Date(now + 600e3).toISOString().replace(/\.\d{3}Z$/, 'Z') }]
  };
  const r = await call('/api/jobs', { ...CLAIM(), state });
  assert.equal(r.status, 409);
  assert.equal(r.body.scope, 'retry');
  assert.match(r.body.reason, /retry scheduled for/);
  assert.equal(r.db._calls.filter((c) => /INSERT INTO jobs/.test(c.sql)).length, 0);
});

test('two boxes cannot both take over one queued retry', async () => {
  // The retry is where a double build would come back: two ticks in the same
  // second both see one due row. The takeover is a compare-and-swap, so the
  // loser is told it lost instead of building the same thing again.
  const state = {
    jobs: [RUNNING({ id: 'build-project-3-TK-70-1', ticket_id: 'TK-70', status: 'queued_for_retry', box: 'box-a' })],
    claims: [{ job_id: 'build-project-3-TK-70-1', lane: 'plan/project-3/claude', attempts: 1, max_attempts: 3 }],
    casLost: true
  };
  const r = await call('/api/jobs', { ...CLAIM(), state });
  assert.equal(r.status, 409);
  assert.equal(r.body.scope, 'retry');
  assert.match(r.body.reason, /another box picked up the retry/);
  assert.equal(r.db._calls.filter((c) => /INSERT INTO jobs/.test(c.sql)).length, 0,
    'the loser must not fall through and start a fresh row');
});

test('done never walks back to running', async () => {
  const r = await call('/api/jobs/build-project-3-TK-1-1', {
    method: 'PATCH', body: { status: 'running' },
    state: { jobs: [RUNNING({ status: 'done' })] }
  });
  assert.equal(r.status, 409);
  assert.equal(r.body.error, 'illegal job transition');
  assert.deepEqual(r.body.legal, ['done']);
  assert.equal(r.db._calls.filter((c) => /UPDATE jobs SET/.test(c.sql)).length, 0);
});

test('a parked job cannot skip to done without an attempt in between', async () => {
  const parked = await call('/api/jobs/build-project-3-TK-1-1', {
    method: 'PATCH', body: { status: 'done' }, state: { jobs: [RUNNING({ status: 'parked' })] }
  });
  assert.equal(parked.status, 409);
  assert.match(parked.body.reason, /parked -> done is not a move/);
  // ...but it may be picked back up, and then it may finish.
  const resumed = await call('/api/jobs/build-project-3-TK-1-1', {
    method: 'PATCH', body: { status: 'running' }, state: { jobs: [RUNNING({ status: 'parked' })] }
  });
  assert.equal(resumed.status, 200);
});

test('BUDGET_STOP stays terminal - the iron rule, as a row of the graph', async () => {
  for (const to of ['running', 'done', 'queued_for_retry', 'parked']) {
    const r = await call('/api/jobs/build-project-3-TK-1-1', {
      method: 'PATCH', body: { status: to }, state: { jobs: [RUNNING({ status: 'budget_stopped' })] }
    });
    assert.equal(r.status, 409, `budget_stopped must not become ${to}`);
  }
});

test('the transitions a live pipeline actually makes are all legal', async () => {
  // The regression this guards: a graph tight enough to be meaningless, which
  // would 409 every close the fleet performs and be discovered in production.
  for (const to of ['done', 'failed', 'parked', 'orphaned', 'queued_for_retry', 'budget_stopped']) {
    const r = await call('/api/jobs/build-project-3-TK-1-1', {
      method: 'PATCH', body: { status: to }, state: { jobs: [RUNNING()] }
    });
    assert.equal(r.status, 200, `running -> ${to} must stay legal`);
  }
});

test('a build that finishes after being judged orphaned can still say so', async () => {
  // Both `orphaned` and `queued_for_retry` are inferences drawn from SILENCE.
  // A process reporting its own completion outranks the absence that convicted
  // it — otherwise a finished build sits under an orphan verdict forever and
  // its PR is invisible to every screen.
  for (const from of ['orphaned', 'queued_for_retry']) {
    const r = await call('/api/jobs/build-project-3-TK-1-1', {
      method: 'PATCH', body: { status: 'done' }, state: { jobs: [RUNNING({ status: from })] }
    });
    assert.equal(r.status, 200, `${from} -> done must record the honest outcome`);
  }
});

test('an unknown target status is refused; an unknown SOURCE status still moves', async () => {
  const bogus = await call('/api/jobs/build-project-3-TK-1-1', {
    method: 'PATCH', body: { status: 'dnoe' }, state: { jobs: [RUNNING()] }
  });
  assert.equal(bogus.status, 409);
  assert.equal(bogus.body.error, 'unknown job status');
  // A row written by something this worker does not model must never become
  // unfixable — the graph is a guard, not a trap.
  const legacy = await call('/api/jobs/build-project-3-TK-1-1', {
    method: 'PATCH', body: { status: 'failed' }, state: { jobs: [RUNNING({ status: 'zombie' })] }
  });
  assert.equal(legacy.status, 200);
});

test('a claim cannot resurrect a finished row by reusing its id', async () => {
  // POST /api/jobs upserts ON CONFLICT(id) SET status=running, which is exactly
  // the done -> running move the graph forbids.
  const r = await call('/api/jobs', {
    ...CLAIM({ id: 'build-project-3-TK-70-old', ticket_id: null }),
    state: { jobs: [RUNNING({ id: 'build-project-3-TK-70-old', status: 'done' })] }
  });
  assert.equal(r.status, 409);
  assert.equal(r.body.refused, true);
  assert.equal(r.db._calls.filter((c) => /INSERT INTO jobs/.test(c.sql)).length, 0);
});

test('with pause_flags empty nothing is paused', async () => {
  const r = await call('/api/jobs', { ...CLAIM(), state: { jobs: [], flags: [] } });
  assert.equal(r.status, 201);
});

test('a paused project refuses the claim, by name and with the reason', async () => {
  const r = await call('/api/jobs', {
    ...CLAIM(),
    state: { jobs: [], flags: [FLAG('paused-project-3', { reason: 'client asked us to hold' })] }
  });
  assert.equal(r.status, 409);
  assert.equal(r.body.refused, true);
  assert.equal(r.body.scope, 'pause');
  assert.equal(r.body.flag, 'paused-project-3');
  assert.match(r.body.reason, /paused: pause_flags row paused-project-3 is active \(updated [^)]+\) — client asked us to hold/);
  assert.equal(r.db._calls.filter((c) => /INSERT INTO jobs/.test(c.sql)).length, 0,
    'a paused claim must be refused BEFORE anything is written');
});

test('an inactive row is not a pause', async () => {
  const r = await call('/api/jobs', {
    ...CLAIM(), state: { jobs: [], flags: [FLAG('paused-project-3', { active: 0 })] }
  });
  assert.equal(r.status, 201);
});

test('the box and lane scopes pause too, and the fleet-wide row is the headline', async () => {
  const box = await call('/api/jobs', {
    ...CLAIM(), state: { jobs: [], flags: [FLAG('paused-box-box-project-3-2')] }
  });
  assert.equal(box.status, 409);
  assert.equal(box.body.flag, 'paused-box-box-project-3-2');
  // The lane's slashes become dashes, because a flag name is a FILE name on
  // every box in the fleet.
  const lane = await call('/api/jobs', {
    ...CLAIM(), state: { jobs: [], flags: [FLAG('paused-lane-plan-project-3-claude')] }
  });
  assert.equal(lane.status, 409);
  assert.equal(lane.body.flag, 'paused-lane-plan-project-3-claude');
  const both = await call('/api/jobs', {
    ...CLAIM(), state: { jobs: [], flags: [FLAG('paused-project-3'), FLAG('paused-all')] }
  });
  assert.equal(both.body.flag, 'paused-all', 'when the whole fleet is paused that is what a human needs told');
});

test("another project's pause does not touch this one", async () => {
  const r = await call('/api/jobs', {
    ...CLAIM(), state: { jobs: [], flags: [FLAG('paused-project-4'), FLAG('paused-box-some-other-box')] }
  });
  assert.equal(r.status, 201);
});

test('a pause outranks the retry pickup - a backoff must not run on a paused lane', async () => {
  const state = {
    jobs: [RUNNING({ id: 'build-project-3-TK-70-1', ticket_id: 'TK-70', status: 'queued_for_retry' })],
    claims: [{ job_id: 'build-project-3-TK-70-1', lane: 'plan/project-3/claude', attempts: 1, max_attempts: 3 }],
    flags: [FLAG('paused-project-3')]
  };
  const r = await call('/api/jobs', { ...CLAIM(), state });
  assert.equal(r.status, 409);
  assert.equal(r.body.scope, 'pause');
  assert.equal(r.db._calls.filter((c) => /UPDATE jobs SET status=/.test(c.sql)).length, 0);
});

test('a claim with no caller budget takes the floored lane cap onto the job row', async () => {
  // This is the number the console prints and the watchdog says "spent $X of
  // $Y" against, so it is the one that decides whether an honest build reads
  // as over budget.
  const r = await call('/api/jobs', {
    ...CLAIM({ lane: 'execute/project-3/claude' }),
    state: { catalog: [LANE] }
  });
  assert.equal(r.status, 201);
  assert.equal(r.body.budget_source, 'catalog');
  const ins = r.db._calls.find((c) => /INSERT INTO jobs/.test(c.sql));
  assert.equal(ins.binds[7], 50);
});

test('an operator-supplied budget on the claim is used verbatim', async () => {
  const r = await call('/api/jobs', {
    ...CLAIM({ lane: 'execute/project-3/claude', budget_usd: 7 }),
    state: { catalog: [LANE] }
  });
  assert.equal(r.body.budget_source, 'caller');
  const ins = r.db._calls.find((c) => /INSERT INTO jobs/.test(c.sql));
  assert.equal(ins.binds[7], 7);
});

test('a jobs claim on a database created before BH-482 ALTERs issue_created_at and first_spawn_at onto jobs before the insert', async () => {
  const PRE_BH482 = ['id', 'project', 'ticket_id', 'kind', 'box', 'stage', 'status',
    'budget_usd', 'spent_usd', 'created_at', 'updated_at', 'meta'];
  const r = await call('/api/jobs', { ...CLAIM(), state: { jobs: [], jobsCols: PRE_BH482 } });
  assert.equal(r.status, 201);
  assert.deepEqual(sqlOf(r.db, /ALTER TABLE jobs ADD COLUMN/).map((a) => a.sql), [
    'ALTER TABLE jobs ADD COLUMN issue_created_at TEXT',
    'ALTER TABLE jobs ADD COLUMN first_spawn_at TEXT'
  ]);
  // The probe runs BEFORE the write, so the claim never lands on a table that
  // cannot take it.
  const order = r.db._calls.map((c) => c.sql);
  const probe = order.findIndex((q) => /PRAGMA table_info\(jobs\)/.test(q));
  const alter = order.findIndex((q) => /ALTER TABLE jobs/.test(q));
  const insert = order.findIndex((q) => /INSERT INTO jobs/.test(q));
  assert.ok(probe >= 0 && probe < alter && alter < insert,
    `probe/alter/insert order was ${probe}/${alter}/${insert}`);
  // A database that already carries both columns is never ALTERed.
  const current = await call('/api/jobs', { ...CLAIM(), state: { jobs: [] } });
  assert.equal(current.status, 201);
  assert.equal(sqlOf(current.db, /ALTER TABLE jobs/).length, 0);
});

test('a build claim binds a well-formed issue_created_at and nulls anything else', async () => {
  const good = await call('/api/jobs', {
    ...CLAIM({ issue_created_at: '2026-09-16T17:46:58Z' }), state: { jobs: [] }
  });
  assert.equal(good.status, 201);
  assert.equal(insertOf(good.db).binds[10], '2026-09-16T17:46:58Z');

  // Every near-miss binds NULL and the claim still succeeds. Both halves matter:
  // a stamp reshaped to fit is a measurement of something nobody recorded, and a
  // claim refused over telemetry is a build that does not run.
  for (const bad of ['2026-09-16T17:46:58.000Z', '2026-09-16T17:46:58+00:00',
    '2026-09-16', 'yesterday', '', 42, null, {}]) {
    const r = await call('/api/jobs', { ...CLAIM({ issue_created_at: bad }), state: { jobs: [] } });
    assert.equal(r.status, 201, `a claim must never be refused over its stamp: ${JSON.stringify(bad)}`);
    assert.equal(insertOf(r.db).binds[10], null,
      `${JSON.stringify(bad)} must bind null, never a coerced stamp`);
  }
});

test('first_spawn_at is the earliest build row for the ticket, else this claim own instant', async () => {
  // First claim for the ticket: nothing earlier exists, so this row IS the first
  // spawn and binds its own created_at (bind 9, the same instant the row is
  // stamped with).
  const first = await call('/api/jobs', { ...CLAIM(), state: { jobs: [] } });
  assert.equal(first.status, 201);
  const firstIns = insertOf(first.db);
  assert.equal(firstIns.binds[11], firstIns.binds[8]);

  // A rebuild two hours later. Taking THIS row's instant would report the
  // rebuild's wait as the ticket's launch lead time.
  const earlier = iso(2 * 3600e3);
  const rebuild = await call('/api/jobs', {
    ...CLAIM(),
    state: { jobs: [RUNNING({ id: 'build-project-3-TK-70-1', ticket_id: 'TK-70',
      kind: 'build', status: 'done', created_at: earlier })] }
  });
  assert.equal(rebuild.status, 201);
  assert.equal(insertOf(rebuild.db).binds[11], earlier);
  const min = rebuild.db._calls.find((c) => /MIN\(created_at\)/.test(c.sql));
  assert.ok(min, 'the claim must ask for the earliest build row');
  assert.deepEqual(min.binds, ['project-3', 'TK-70'],
    'the watermark is per (project, ticket), never fleet-wide');

  // A ticketless triage tick has no ticket to have waited, and must not pay for
  // a read that could only answer about one.
  const triage = await call('/api/jobs', {
    method: 'POST',
    body: { project: 'project-3', kind: 'triage', box: 'box-project-3-2', stage: 'triage' },
    state: { jobs: [] }
  });
  assert.equal(triage.status, 201);
  const triageIns = insertOf(triage.db);
  assert.equal(triageIns.binds[10], null);
  assert.equal(triageIns.binds[11], null);
  assert.equal(triage.db._calls.filter((c) => /MIN\(created_at\)/.test(c.sql)).length, 0);

  // THE RESUME: the conflict clause must still exist and must still name only
  // the four columns it always did, or a re-claim would overwrite the first
  // spawn with the instant of the attempt that resumed it.
  assert.match(firstIns.sql,
    /ON CONFLICT\(id\) DO UPDATE SET box=\?5, stage=\?6, status=\?7, updated_at=\?9$/);
  assert.doesNotMatch(firstIns.sql, /DO UPDATE SET.*(issue_created_at|first_spawn_at)/);
});

test('a first-spawn read that throws does not refuse the claim', async () => {
  const r = await call('/api/jobs', { ...CLAIM(), state: { jobs: [], minReadFails: true } });
  assert.equal(r.status, 201, 'telemetry never refuses a build');
  // NULL, not this row's instant: an unknown first spawn is excluded from the
  // DORA read by its IS NOT NULL filter, where a fallback to `t` would quietly
  // report a rebuild as a ticket that waited no time at all.
  assert.equal(insertOf(r.db).binds[11], null);
});
