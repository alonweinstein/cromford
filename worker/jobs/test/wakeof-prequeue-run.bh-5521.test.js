// BH-5521 — a COMPLETED pre-queue run wakes the PR it gated.
//
// bin/lib/mc-prequeue.d/dispatch.sh dispatches prequeue-gate.yml with
// `--ref main`, so the run's head_sha is MAIN's tip and a `checks` row keyed on
// it names no PR. The run title (`run-name: prequeue pr=<n> head=<sha>
// main=<sha>`) carries the number, so wakeOf keys the row on it instead.
// Every other workflow_run keeps today's checks/sha row.
//
// Each case drives the real worker.fetch with a SIGNED delivery (the
// deliver()/fakeDB shape of wakeof-new-events.bh-4058.test.js) and asserts only
// the wake fields this ticket owns: kind, key, event.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { createHmac } from 'node:crypto';

const WH_SECRET = 'wh-test-secret';
const SECRET = 'test-secret';
const repository = { full_name: 'example-org/cromford' };
const HEAD = 'a'.repeat(40);
const MAIN = 'b'.repeat(40);
const PATH = '.github/workflows/prequeue-gate.yml';

function fakeDB() {
  const calls = [];
  const stmt = (sql) => ({
    bind: (...binds) => ({
      first: async () => null,
      all: async () => ({ results: [] }),
      run: async () => {
        calls.push({ sql: sql.replace(/\s+/g, ' ').trim(), binds });
        return { meta: { changes: 1, last_row_id: 1 } };
      },
    }),
    first: async () => null,
    all: async () => ({ results: [] }),
    run: async () => ({ meta: { changes: 1 } }),
  });
  return { prepare: stmt, _calls: calls };
}

const deliver = (event, payload) => {
  const raw = JSON.stringify(payload);
  const headers = {
    'content-type': 'application/json', 'x-github-event': event,
    'x-hub-signature-256': 'sha256=' + createHmac('sha256', WH_SECRET).update(raw).digest('hex'),
  };
  const db = fakeDB();
  const req = new Request('https://jobs.test/webhooks/github', { method: 'POST', headers, body: raw });
  const env = { DB: db, HARNESS_SECRET: SECRET, GITHUB_WEBHOOK_SECRET: WH_SECRET };
  return worker.fetch(req, env).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null), db,
  }));
};
const inserts = (r) => r.db._calls.filter((c) => /INSERT INTO wakes/.test(c.sql));

// One workflow_run delivery. `run` overrides the pre-queue-shaped defaults.
const wr = (run = {}, action = 'completed') => ({
  action, repository,
  workflow_run: {
    event: 'workflow_dispatch', path: PATH, head_sha: MAIN,
    display_title: `prequeue pr=12 head=${HEAD} main=${MAIN}`, ...run,
  },
});

async function row(payload) {
  const r = await deliver('workflow_run', payload);
  assert.equal(r.status, 200, `expected a wake row, got ${r.status}`);
  const ins = inserts(r);
  assert.equal(ins.length, 1);
  return { kind: ins[0].binds[1], key: ins[0].binds[2], event: ins[0].binds[3] };
}

test('W1: a completed pre-queue run -> pr row keyed on the title number', async () => {
  const w = await row(wr());
  assert.equal(w.kind, 'pr');
  assert.equal(w.key, '12');
  assert.equal(w.event, 'workflow_run.completed');
});

test('W2: a 9-digit PR number is kept whole', async () => {
  const w = await row(wr({ display_title: `prequeue pr=987654321 head=${HEAD} main=${MAIN}` }));
  assert.equal(w.kind, 'pr');
  assert.equal(w.key, '987654321');
});

test('W3: pr=0 is not a PR -> checks row on the run head', async () => {
  const w = await row(wr({ display_title: `prequeue pr=0 head=${HEAD} main=${MAIN}` }));
  assert.equal(w.kind, 'checks');
  assert.equal(w.key, MAIN);
});

test('W4: a 39-hex head in the title -> checks', async () => {
  const w = await row(wr({ display_title: `prequeue pr=12 head=${'a'.repeat(39)} main=${MAIN}` }));
  assert.equal(w.kind, 'checks');
  assert.equal(w.key, MAIN);
});

test('W5 (adversarial): a pull_request run titled like a pre-queue run -> checks', async () => {
  const w = await row(wr({ event: 'pull_request', display_title: `prequeue pr=5 head=${HEAD} main=${MAIN}` }));
  assert.equal(w.kind, 'checks');
  assert.equal(w.key, MAIN);
});

test('W6: another workflow path with a pre-queue-shaped title -> checks', async () => {
  const w = await row(wr({ path: '.github/workflows/ci.yml' }));
  assert.equal(w.kind, 'checks');
  assert.equal(w.key, MAIN);
  // a path that only CONTAINS the name is not the pre-queue workflow either
  const w2 = await row(wr({ path: '.github/workflows/not-prequeue-gate.yml' }));
  assert.equal(w2.kind, 'checks');
});

test('W7: a requested pre-queue run writes no row', async () => {
  const r = await deliver('workflow_run', wr({}, 'requested'));
  assert.equal(r.status, 202);
  assert.equal(inserts(r).length, 0);
});

test('W8: a plain workflow_run (no title) still lands as checks on its head', async () => {
  const w = await row({ action: 'completed', repository, workflow_run: { head_sha: HEAD } });
  assert.equal(w.kind, 'checks');
  assert.equal(w.key, HEAD);
});
