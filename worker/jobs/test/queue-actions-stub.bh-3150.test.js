import test from 'node:test';
import assert from 'node:assert/strict';
import worker, { ROUTES } from '../src/index.js';
import { matchRoute } from '../src/lib/router.js';

// BH-3150 (BH-2510.0): the QUEUES panel's two action routes exist. They were
// stubs answering 501 {error:"not implemented", refused:true}. BH-3151
// (BH-2510.1) filled POST /api/queue/action (test/queue-actions.bh-2510.test.js)
// and BH-3152 (BH-2510.2) replaced the deploy-queue stub with the audited
// RELEASE (deploy-queue-actions.bh-2510.test.js), so no stub is left; what is
// pinned here is that both stay routed, POST only, behind the bearer.

const SECRET = 's3cret';
const ACTIONS = ['/api/queue/action', '/api/deploy-queue/action'];

test('both action routes resolve on the real ROUTES', () => {
  for (const path of ACTIONS) assert.ok(matchRoute(ROUTES, 'POST', path), `POST ${path} is routed`);
});

test('through worker.fetch: a bearer is required before anything is touched', async () => {
  const DB = new Proxy({}, { get() { throw new Error('an unauthenticated call touched the DB'); } });
  for (const path of ACTIONS) {
    const anon = await worker.fetch(new Request(`https://jobs.example${path}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ project: 'p', action: 'hold', reason: 'x' }),
    }), { DB, HARNESS_SECRET: SECRET });
    assert.equal(anon.status, 401, `${path} without a bearer`);
  }
});

test('POST /api/deploy-queue/action is no longer a stub: an empty body is a 400, not 501', async () => {
  const DB = new Proxy({}, { get() { throw new Error('a 400 must not touch the DB'); } });
  const res = await worker.fetch(new Request('https://jobs.example/api/deploy-queue/action', {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` },
    body: '{}',
  }), { DB, HARNESS_SECRET: SECRET });
  assert.equal(res.status, 400);
});

test('only POST is routed: a GET on either action path is not a hit', () => {
  for (const path of ACTIONS) assert.equal(matchRoute(ROUTES, 'GET', path), null, `GET ${path}`);
});
