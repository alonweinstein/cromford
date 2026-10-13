import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/coord/[[path]].js';

// BH-2405: every write the coord proxy admits stamps `actor` itself and
// forwards only that route's allowlisted fields. A browser-typed actor, an
// unknown field or a cap-raising knob never reaches the jobs worker.

const JOBS = 'https://harness-jobs.operator.workers.dev';
const CONSOLE = 'https://harness-console.operator.workers.dev';
const SECRET = 'test-harness-secret';
const ID = 'build-cromford-BH-1-1';

function stubFetch() {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith(CONSOLE)) return new Response('', { status: 200 });
    seen.push({ url: target, method: init.method, body: init.body });
    return new Response('{}', { status: 200, headers: { 'content-type': 'application/json' } });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}

let cookieSeq = 0;
const call = (rest, method, body, search = '') =>
  onRequest({
    request: new Request(`https://console.example.pages.dev/api/coord/${rest}${search}`, {
      method,
      headers: { cookie: `dash=bh2405-${++cookieSeq}`, 'content-type': 'application/json' },
      body
    }),
    env: { HARNESS_SECRET: SECRET },
    params: { path: rest.split('/') }
  });

// Each body route with the fields the console legitimately sends for it.
const BODY_ROUTES = [
  ['PUT', 'flags', { name: 'pause-all', active: 1, reason: 'drill' }],
  ['PUT', 'settings', { key: 'lane.merge-conductor.mc_max_prs', value: 12, note: 'n' }],
  ['PUT', 'model-routes', { role: 'build.qa', project: 'project-4', ladder: [{ model: 'm' }], expected_version: 3, expected_hub_version: 4, reason: 'r', confirm: true }],
  ['POST', 'model-routes/reset', { role: 'build.qa', project: 'project-4', expected_version: 3, expected_hub_version: 4, reason: 'r' }],
  ['POST', 'lanes/all-off', { reason: 'incident' }],
  ['POST', 'lanes/all-on', { reason: 'clear' }],
  ['POST', 'hub/promote', { target: 'box-2', expected_epoch: 7, reason: 'drill', confirm: true }],
  ['POST', 'hub/restore-lab', { box: 'hub-1', snapshot: 'latest', confirm: true }],
  ['POST', `jobs/${ID}/retry`, { detail: 'x' }],
  ['POST', `jobs/${ID}/requeue`, { detail: 'x' }],
  ['POST', `jobs/${ID}/abandon`, { reason: 'superseded by #2' }],
  ['POST', 'alerts/actions', { id: 'a1', action: 'ack', reason: 'seen', snooze_s: 600, note: 'n' }],
  ['POST', 'main-red/clear', { name: 'main-red-x', reason: 'fixed on main', sha: 'abc123' }]
];

for (const [method, rest, legit] of BODY_ROUTES) {
  test(`1: ${method} ${rest}: client actor and an unknown field never reach the worker; actor is console`, async () => {
    const f = stubFetch();
    try {
      const res = await call(rest, method, JSON.stringify({ ...legit, actor: 'someone-else', smuggled: 1 }), '?actor=mallory&smuggled=1');
      assert.equal(res.status, 200);
      assert.equal(f.seen.length, 1);
      assert.equal(f.seen[0].url, `${JOBS}/api/${rest}`, 'no query string travels on a body write');
      assert.equal(f.seen[0].method, method);
      assert.deepEqual(JSON.parse(f.seen[0].body), { ...legit, actor: 'console' });
    } finally { f.restore(); }
  });

  test(`7: ${method} ${rest}: an array body or a non-JSON body is 400 and sends nothing`, async () => {
    const f = stubFetch();
    try {
      for (const body of ['[{"actor":"x"}]', 'not json', '"str"', 'null']) {
        const res = await call(rest, method, body);
        assert.equal(res.status, 400, body);
        assert.match((await res.json()).error, /must carry a JSON object body/);
      }
      assert.equal(f.seen.length, 0);
    } finally { f.restore(); }
  });
}

test('1: a non-string actor object is still replaced by console', async () => {
  const f = stubFetch();
  try {
    await call('settings', 'PUT', JSON.stringify({ key: 'k', value: 1, actor: { name: 'x' } }));
    assert.deepEqual(JSON.parse(f.seen[0].body), { key: 'k', value: 1, actor: 'console' });
  } finally { f.restore(); }
});

test('2: PUT flags with ?actor=mallory&smuggled=1 is forwarded with no query', async () => {
  const f = stubFetch();
  try {
    await call('flags', 'PUT', JSON.stringify({ name: 'n', active: 0 }), '?actor=mallory&smuggled=1');
    assert.equal(f.seen[0].url, `${JOBS}/api/flags`);
  } finally { f.restore(); }
});

test('3: DELETE call-guard forwards only project/stage/fp/reason, actor=console once, and no body', async () => {
  const f = stubFetch();
  try {
    const res = await call('call-guard', 'DELETE', JSON.stringify({ actor: 'x', smuggled: 1 }),
      '?project=p&stage=s&fp=f&reason=r&actor=mallory&smuggled=1');
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    const u = new URL(f.seen[0].url);
    assert.equal(`${u.origin}${u.pathname}`, `${JOBS}/api/call-guard`);
    assert.deepEqual([...u.searchParams.keys()].sort(), ['actor', 'fp', 'project', 'reason', 'stage']);
    assert.deepEqual(u.searchParams.getAll('actor'), ['console']);
    assert.equal(u.searchParams.get('project'), 'p');
    assert.equal(f.seen[0].body, undefined);
  } finally { f.restore(); }
});

test('4: requeue never forwards max_attempts', async () => {
  const f = stubFetch();
  try {
    await call(`jobs/${ID}/requeue`, 'POST', JSON.stringify({ detail: 'x', max_attempts: 99 }));
    assert.deepEqual(JSON.parse(f.seen[0].body), { detail: 'x', actor: 'console' });
    await call(`jobs/${ID}/requeue`, 'POST', JSON.stringify({ detail: 5 }));
    assert.deepEqual(JSON.parse(f.seen[1].body), { actor: 'console' }, 'detail is string-only');
  } finally { f.restore(); }
});

test('5: hub/promote never forwards override_live_lease or ttl_s', async () => {
  const f = stubFetch();
  try {
    await call('hub/promote', 'POST', JSON.stringify({
      target: 't', expected_epoch: 7, confirm: true, override_live_lease: true, ttl_s: 999999, holder: 'h', expect_epoch: 1
    }));
    assert.deepEqual(JSON.parse(f.seen[0].body), { target: 't', expected_epoch: 7, confirm: true, actor: 'console' });
  } finally { f.restore(); }
});

test('5b: PUT model-routes forwards confirm:true (the Models page KEEP AS SEEDED body)', async () => {
  // src/lib/models.js keepSeed PUTs the unchanged ladder with confirm:true; the
  // worker (model-routes.js) only re-stamps, audits and clears SEED when it
  // sees it. Dropping it turns KEEP into a silent 200 {changed:false}.
  const f = stubFetch();
  try {
    const ladder = [{ position: 0, model: 'm', runner: 'r' }];
    const res = await call('model-routes', 'PUT', JSON.stringify({
      role: 'build.qa', project: null, ladder, actor: 'console', reason: 'kept', confirm: true, expected_version: 3
    }));
    assert.equal(res.status, 200);
    assert.deepEqual(JSON.parse(f.seen[0].body), {
      role: 'build.qa', project: null, ladder, reason: 'kept', confirm: true, expected_version: 3, actor: 'console'
    });
  } finally { f.restore(); }
});

test("6: alerts/actions: action ['ack'] is not forwarded; id 'a1', snooze_s 600, reason 'x' are", async () => {
  const f = stubFetch();
  try {
    await call('alerts/actions', 'POST', JSON.stringify({ id: 'a1', action: ['ack'], snooze_s: 600, reason: 'x', note: {} }));
    assert.deepEqual(JSON.parse(f.seen[0].body), { id: 'a1', snooze_s: 600, reason: 'x', actor: 'console' });
    await call('alerts/actions', 'POST', JSON.stringify({ akey: 'k', action: 7, snooze_s: [1], reason: true, note: null, id: false }));
    assert.deepEqual(JSON.parse(f.seen[1].body), { akey: 'k', actor: 'console' }, 'action is string-only; arrays, booleans, null dropped');
  } finally { f.restore(); }
});

test('8: a __proto__ key in the body is never forwarded and cannot plant an actor', async () => {
  const f = stubFetch();
  try {
    await call('flags', 'PUT', '{"__proto__":{"actor":"x"},"name":"n","active":1}');
    const fwd = JSON.parse(f.seen[0].body);
    assert.deepEqual(fwd, { name: 'n', active: 1, actor: 'console' });
    assert.equal(Object.prototype.hasOwnProperty.call(fwd, '__proto__'), false);
    assert.equal(f.seen[0].body.includes('__proto__'), false);
  } finally { f.restore(); }
});

test('9: writes outside the table stay 405 and reach nothing', async () => {
  const f = stubFetch();
  try {
    for (const [rest, method] of [
      ['flags/x', 'PUT'], ['settings', 'POST'], ['call-guard/claim', 'DELETE'], ['alerts/state', 'POST'],
      [`jobs/${ID}`, 'PATCH'], ['alerts/actions', 'PUT'], ['alerts/actions', 'DELETE'], ['jobs/../retry', 'POST'],
      ['hub/promote', 'PUT'], ['model-routes', 'POST'], ['lanes/all-off', 'PUT']
    ]) {
      const res = await call(rest, method, '{}');
      assert.equal(res.status, 405, `${method} ${rest}`);
      assert.equal((await res.json()).error, `method ${method} not allowed on /api/coord/${rest}`);
    }
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('GET still forwards its query string untouched', async () => {
  const f = stubFetch();
  try {
    await call('lanes/status', 'GET', undefined, '?project=project-4&actor=x');
    assert.equal(f.seen[0].url, `${JOBS}/api/lanes/status?project=project-4&actor=x`);
  } finally { f.restore(); }
});

// ---- lead fix round: the narrowings main already had, now as table rows ------
// Each must forward the SAME BYTES main's hand-written clause did.

test('10: main-red/clear forwards name/reason/sha as strings only, in that order, actor last', async () => {
  const f = stubFetch();
  try {
    const res = await call('main-red/clear', 'POST',
      JSON.stringify({ sha: 'abc', actor: 'mallory', reason: 'r', extra: 1, name: 'main-red-x' }), '?actor=m');
    assert.equal(res.status, 200);
    assert.equal(f.seen[0].url, `${JOBS}/api/main-red/clear`);
    assert.equal(f.seen[0].body, '{"name":"main-red-x","reason":"r","sha":"abc","actor":"console"}');
    await call('main-red/clear', 'POST', JSON.stringify({ name: 'main-red-x', reason: 5, sha: null }));
    assert.equal(f.seen[1].body, '{"name":"main-red-x","actor":"console"}');
  } finally { f.restore(); }
});

test('11: a job action forwards {detail, actor} in that order whatever the browser order', async () => {
  const f = stubFetch();
  try {
    await call(`jobs/${ID}/retry`, 'POST', JSON.stringify({ actor: 'x', max_attempts: 9, detail: 'd' }));
    assert.equal(f.seen[0].body, '{"detail":"d","actor":"console"}');
  } finally { f.restore(); }
});

// PUT routing: GET /api/routing/<p> answers from `rows` (absent = 404, a
// number = that status); the PUT echoes 200.
function stubRouting(rows) {
  const seen = [];
  const real = globalThis.fetch;
  const reply = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith(CONSOLE)) return new Response('', { status: 200 });
    const method = init.method || 'GET';
    seen.push({ url: target, method, body: init.body });
    const path = new URL(target).pathname;
    if (method === 'GET') {
      const r = rows[decodeURIComponent(path.slice('/api/routing/'.length))];
      if (r === undefined) return reply(404, { error: 'not found' });
      if (typeof r === 'number') return reply(r, { error: `http_${r}` });
      return reply(200, { routing: r });
    }
    return reply(200, {});
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}

test('12: PUT routing is a table row: halt-only body rebuilt from the server row, actor last, no query', async () => {
  const f = stubRouting({ 'project-3': { project: 'project-3', builder: 'local', pool_app: null, halted: 0 } });
  try {
    const res = await call('routing', 'PUT', JSON.stringify({
      actor: 'x', project: 'project-3', builder: 'pool', pool_app: 'evil', halted: 1, reason: ' drill ', extra: 1
    }), '?actor=m&builder=pool');
    assert.equal(res.status, 200);
    assert.deepEqual(f.seen.map((s) => [s.method, s.url]),
      [['GET', `${JOBS}/api/routing/project-3`], ['PUT', `${JOBS}/api/routing`]]);
    assert.equal(f.seen[1].body,
      '{"project":"project-3","builder":"local","pool_app":null,"halted":1,"reason":"drill","actor":"console"}');
  } finally { f.restore(); }
});

test('13: PUT routing keeps haltOnlyBody refusals: 404 no row, 502 unreadable, 400 bad body; never written', async () => {
  const f = stubRouting({ broken: 500, 'project-3': { project: 'project-3', builder: 'local', pool_app: null, halted: 1 } });
  try {
    assert.equal((await call('routing', 'PUT', JSON.stringify({ project: 'ghost', halted: 1 }))).status, 404);
    assert.equal((await call('routing', 'PUT', JSON.stringify({ project: 'broken', halted: 1 }))).status, 502);
    assert.equal((await call('routing', 'PUT', JSON.stringify({ project: 'project-3', halted: 2 }))).status, 400);
    assert.equal((await call('routing', 'PUT', JSON.stringify({ project: 'project-3', halted: 0 }))).status, 400);
    const arr = await call('routing', 'PUT', '[{"project":"project-3"}]');
    assert.equal(arr.status, 400);
    assert.match((await arr.json()).error, /must carry a JSON object body/);
    assert.equal(f.seen.filter((s) => s.method === 'PUT').length, 0);
  } finally { f.restore(); }
});

test('14: routing and main-red writes outside their rows stay 405', async () => {
  const f = stubFetch();
  try {
    for (const [rest, method] of [
      ['routing/project-3', 'PUT'], ['routing', 'POST'], ['routing-changes', 'PUT'],
      ['main-red/clear', 'PUT'], ['main-red', 'POST'], ['main-red/clear/x', 'POST']
    ]) {
      const res = await call(rest, method, '{}');
      assert.equal(res.status, 405, `${method} ${rest}`);
    }
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('15: ABANDON is its own row: {reason, actor} in that order, string-only, no detail or cap fields', async () => {
  const f = stubFetch();
  try {
    const res = await call(`jobs/${ID}/abandon`, 'POST',
      JSON.stringify({ actor: 'x', detail: 'd', max_attempts: 9, reason: 'dup', extra: 1 }), '?actor=m');
    assert.equal(res.status, 200);
    assert.equal(f.seen[0].url, `${JOBS}/api/jobs/${ID}/abandon`);
    assert.equal(f.seen[0].body, '{"reason":"dup","actor":"console"}');
    await call(`jobs/${ID}/abandon`, 'POST', JSON.stringify({ reason: ['dup'] }));
    assert.equal(f.seen[1].body, '{"actor":"console"}', 'reason is string-only');
    // retry/requeue do not take ABANDON's reason, and abandon does not take their detail.
    await call(`jobs/${ID}/retry`, 'POST', JSON.stringify({ reason: 'r', detail: 'd' }));
    assert.equal(f.seen[2].body, '{"detail":"d","actor":"console"}');
    for (const [rest, method] of [['jobs/../abandon', 'POST'], ['jobs/./abandon', 'POST'], [`jobs/${ID}/abandon`, 'PUT'], [`jobs/${ID}/abandon/x`, 'POST']]) {
      assert.equal((await call(rest, method, '{}')).status, 405, `${method} ${rest}`);
    }
    assert.equal(f.seen.length, 3);
  } finally { f.restore(); }
});
