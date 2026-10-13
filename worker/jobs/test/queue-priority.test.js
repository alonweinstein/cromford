import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';

// POST /api/queue/claim — HOTFIX-FIRST ORDERING, driven through the worker's
// real fetch handler against REAL SQLite.
//
// WHAT IS AT STAKE. The claim route is the whole fleet's dispatcher: every box
// asks it "what do I build next" and builds whatever comes back. Before this,
// the answer was pure FIFO, so a hotfix enqueued during a quiet afternoon sat
// behind every routine ticket already in the queue. The ordering is one CASE
// expression in front of `enqueued_at ASC`, and the risky part is not writing
// it — it is that SQLite's json_extract returns integer 1 for BOTH the JSON
// boolean `true` and the number 1, and that json_type on a non-JSON TEXT value
// raises SQLITE_ERROR and would 500 the claim route for every project sharing
// this queue. Both of those are rules only real SQLite can check.
//
// WHY NOT THE SQL-PATTERN STUB. requeue.test.js stubs D1 by matching the SQL
// text and handing back fixed rows. That stub CANNOT evaluate an ORDER BY: it
// would return whatever row the test author put first and go green on a worker
// that never learned to rank anything. A test that restates the logic passes
// while the lane is broken. So this file builds a small D1-shaped adapter over
// node:sqlite and lets SQLite itself execute the ORDER BY — the rows come back
// in the order the shipped SQL actually produces.

let DatabaseSync;
try {
  ({ DatabaseSync } = await import('node:sqlite'));
} catch {
  console.log('SKIP queue-priority.test.js: node:sqlite is unavailable on this node '
    + `(${process.version}); the hotfix ordering was NOT verified here.`);
  process.exit(0);
}

const SECRET = 'test-secret';

// The build_queue DDL, copied from worker/jobs/schema.sql. Same columns and the
// same PRIMARY KEY (project, ticket_key), because the compare-and-swap the
// route leans on is an UPDATE against that key.
const DDL = `
CREATE TABLE IF NOT EXISTS build_queue (
  project TEXT NOT NULL,
  ticket_key TEXT NOT NULL,
  ticket_id TEXT,
  status TEXT NOT NULL,
  target TEXT NOT NULL DEFAULT 'local',
  attempt INTEGER NOT NULL DEFAULT 0,
  requested_by TEXT,
  claimed_by TEXT,
  claimed_at TEXT,
  enqueued_at TEXT NOT NULL,
  finished_at TEXT,
  reason TEXT,
  meta TEXT,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (project, ticket_key)
);`;

// The D1 surface the route actually uses: prepare().bind(...).first()/all()/run(),
// plus the bare forms. D1 binds are ?1-style and node:sqlite takes those
// positionally (verified: repeats and out-of-order indexes bind correctly), so
// the route's SQL is executed verbatim, placeholders included.
//
// run() reports the REAL changes count. That number is load-bearing: the
// route's claim is a compare-and-swap and reads took.meta.changes to learn
// whether it won the row.
function d1(db, hooks = {}) {
  const exec = (sql, binds) => {
    const stmt = db.prepare(sql);
    return {
      first: async () => stmt.get(...binds) ?? null,
      all: async () => ({ results: stmt.all(...binds) }),
      run: async () => {
        if (hooks.beforeUpdate && /^\s*UPDATE/i.test(sql)) hooks.beforeUpdate(sql, binds);
        const r = stmt.run(...binds);
        return { meta: { changes: Number(r.changes), last_row_id: Number(r.lastInsertRowid) } };
      },
    };
  };
  return {
    prepare: (sql) => ({
      bind: (...binds) => exec(sql, binds),
      first: () => exec(sql, []).first(),
      all: () => exec(sql, []).all(),
      run: () => exec(sql, []).run(),
    }),
  };
}

// rows: [key, enqueued_at, meta, target?]
function fresh(rows, hooks) {
  const db = new DatabaseSync(':memory:');
  db.exec(DDL);
  const ins = db.prepare(
    `INSERT INTO build_queue (project, ticket_key, ticket_id, status, target, enqueued_at, updated_at, meta)
     VALUES (?, ?, ?, 'queued', ?, ?, ?, ?)`);
  for (const [key, at, meta, target] of rows) {
    ins.run('project-5', key, `id-${key}`, target || 'local', at, at, meta ?? null);
  }
  return { db, DB: d1(db, hooks) };
}

const call = (DB, body) => {
  const req = new Request('https://jobs.test/api/queue/claim', {
    method: 'POST',
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};

const claim = (DB, over = {}) => call(DB, { project: 'project-5', box: 'box-project-5-1', ...over });

const T0 = '2026-09-17T09:00:00Z';
const T1 = '2026-09-17T10:00:00Z';
const T2 = '2026-09-17T11:00:00Z';
const T3 = '2026-09-17T12:00:00Z';
const HOT = '{"hotfix":true}';

test('an unkeyed claim takes the hotfix, even when a plain ticket has waited longer', async () => {
  const { DB } = fresh([
    ['plain-1', T0, null],
    ['hot-1', T1, HOT],
  ]);
  const r = await claim(DB);
  assert.equal(r.status, 200);
  assert.equal(r.body.queued.ticket_key, 'hot-1');
  assert.equal(r.body.claimed, true);
});

test('only the JSON boolean true is a hotfix — 1, "true" and false are not', async () => {
  // The middle row is the impostor and it is OLDER than the real hotfix, so if
  // it ranked 0 it would win. The answer being hot-1 is the proof that it did
  // not, and the answer not being plain-1 is the proof the ranking ran at all.
  // {"hotfix":1} is the ticket's own acceptance criterion: json_extract would
  // read it as 1 and promote it, which is why the route asks json_type.
  for (const impostor of ['{"hotfix":1}', '{"hotfix":"true"}', '{"hotfix":false}']) {
    const { DB } = fresh([
      ['plain-1', T0, null],
      ['impostor-1', T1, impostor],
      ['hot-1', T2, HOT],
    ]);
    const r = await claim(DB);
    assert.equal(r.status, 200);
    assert.equal(r.body.queued.ticket_key, 'hot-1', `${impostor} must not rank as a hotfix`);
  }
});

test('a NULL meta and an empty object both rank behind a hotfix', async () => {
  const { DB } = fresh([
    ['plain-1', T0, null],
    ['empty-1', T1, '{}'],
    ['hot-1', T2, HOT],
  ]);
  const r = await claim(DB);
  assert.equal(r.status, 200);
  assert.equal(r.body.queued.ticket_key, 'hot-1');
});

test('meta that is not JSON at all answers 200 with a row, never a 500', async () => {
  // json_type on a non-JSON TEXT value raises SQLITE_ERROR: malformed JSON. One
  // hand-edited row would take the entire claim route down for every project in
  // the queue, so the rank is wrapped in json_valid.
  const hot = await claim(fresh([
    ['mal-1', T0, 'not json'],
    ['hot-1', T1, HOT],
  ]).DB);
  assert.equal(hot.status, 200, 'malformed meta must not 500 the claim route');
  assert.equal(hot.body.queued.ticket_key, 'hot-1');

  // And a queue of nothing but malformed rows still hands one out.
  const only = await claim(fresh([['mal-1', T0, 'not json'], ['mal-2', T1, '{oops']]).DB);
  assert.equal(only.status, 200);
  assert.equal(only.body.queued.ticket_key, 'mal-1');
});

test('the skip-loop retry is ranked too — a stolen hotfix falls to the next hotfix', async () => {
  // Someone else takes the first candidate between the SELECT and the UPDATE,
  // exactly once. The route walks on rather than 409-ing an unkeyed claim, and
  // the row it walks to must still be the next HOTFIX, not the oldest plain
  // ticket. This is the second SELECT in the route and it has its own ORDER BY.
  let stolen = null;
  const state = fresh([
    ['plain-1', T0, null],
    ['plain-2', T1, null],
    ['hot-a', T2, HOT],
    ['hot-b', T3, HOT],
  ], {
    beforeUpdate: (sql, binds) => {
      if (stolen) return;
      stolen = binds[1];
      state.db.prepare("UPDATE build_queue SET status='claimed', claimed_by='other-box' WHERE project=? AND ticket_key=?")
        .run(binds[0], binds[1]);
    },
  });
  const r = await claim(state.DB);
  assert.equal(r.status, 200);
  assert.equal(stolen, 'hot-a', 'the first candidate should have been the oldest hotfix');
  assert.equal(r.body.queued.ticket_key, 'hot-b');
  assert.deepEqual(r.body.skipped, ['hot-a']);
});

test('a target-filtered claim ranks within its own target and never crosses it', async () => {
  const { DB } = fresh([
    ['hot-local', T0, HOT, 'local'],
    ['plain-fly', T1, null, 'fly'],
    ['hot-fly', T2, HOT, 'fly'],
  ]);
  const r = await claim(DB, { target: 'fly' });
  assert.equal(r.status, 200);
  assert.equal(r.body.queued.ticket_key, 'hot-fly');
  assert.equal(r.body.queued.target, 'fly');

  // A hotfix on the other target is not this claimant's work at any rank.
  const none = await claim(fresh([['hot-local', T0, HOT, 'local']]).DB, { target: 'fly' });
  assert.equal(none.status, 404);
});

test('a KEYED claim still gets the row it named, hotfix queued or not', async () => {
  // A regression guard, not a ranking test: the keyed SELECT is deliberately
  // unranked, because that caller wanted THAT row and no other.
  const { DB, db } = fresh([
    ['plain-1', T0, null],
    ['hot-1', T1, HOT],
  ]);
  const r = await claim(DB, { key: 'plain-1' });
  assert.equal(r.status, 200);
  assert.equal(r.body.queued.ticket_key, 'plain-1');
  assert.equal(r.body.claimed, true);
  assert.equal(db.prepare("SELECT status FROM build_queue WHERE ticket_key='hot-1'").get().status, 'queued');
});

test('rank never destroys FIFO inside a rank — oldest hotfix first, then the rest', async () => {
  const { DB } = fresh([
    ['plain-1', T0, null],
    ['hot-a', T1, HOT],
    ['hot-b', T2, HOT],
  ]);
  const first = await claim(DB);
  const second = await claim(DB);
  const third = await claim(DB);
  assert.equal(first.body.queued.ticket_key, 'hot-a');
  assert.equal(second.body.queued.ticket_key, 'hot-b');
  assert.equal(third.body.queued.ticket_key, 'plain-1');
});
