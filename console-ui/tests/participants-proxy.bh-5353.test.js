import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/coord/[[path]].js';

// BH-5353 (BH-5348.4): the participants screen's APPROVE, DENY and REVOKE go
// through the coord proxy. Each is one WRITES row on a UUID id, forwards only
// its fields plus the stamped actor, and carries the Pages project's
// LEAD_VERDICT_TOKEN as x-lead-verdict-token. Nothing else ever carries it.

const JOBS = 'https://harness-jobs.operator.workers.dev';
const CONSOLE = 'https://harness-console.operator.workers.dev';
const SECRET = 'test-harness-secret';
const LEAD = 'lead-token-value';
const ID = '1111111b-1111-1111-1111-111111111111';

function stubFetch() {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith(CONSOLE)) return new Response('', { status: 200 });
    seen.push({ url: target, method: init.method, body: init.body, headers: init.headers || {} });
    return new Response('{}', { status: 200, headers: { 'content-type': 'application/json' } });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}

let cookieSeq = 0;
const call = (rest, method, body, { env = { HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: `${LEAD}\n` }, headers = {} } = {}) =>
  onRequest({
    request: new Request(`https://console.example.pages.dev/api/coord/${rest}`, {
      method,
      headers: { cookie: `dash=bh5353-${++cookieSeq}`, 'content-type': 'application/json', ...headers },
      body
    }),
    env,
    params: { path: rest.split('/') }
  });

const leadHeader = (s) => s.headers['x-lead-verdict-token'];

test('1. approve forwards granted_roles and the stamped actor, with the trimmed lead token', async () => {
  const f = stubFetch();
  try {
    const res = await call(`participants/${ID}/approve`, 'POST', JSON.stringify({ granted_roles: ['fix'] }));
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/participants/${ID}/approve`);
    assert.equal(f.seen[0].method, 'POST');
    assert.deepEqual(JSON.parse(f.seen[0].body), { granted_roles: ['fix'], actor: 'console' });
    assert.equal(leadHeader(f.seen[0]), LEAD);
    assert.equal(f.seen[0].headers.authorization, `Bearer ${SECRET}`);
  } finally { f.restore(); }
});

test('2. deny and revoke forward {actor} only, with the lead token', async () => {
  const f = stubFetch();
  try {
    for (const verb of ['deny', 'revoke']) {
      const res = await call(`participants/${ID}/${verb}`, 'POST', JSON.stringify({ granted_roles: ['fix'], smuggled: 1 }));
      assert.equal(res.status, 200, verb);
    }
    assert.equal(f.seen.length, 2);
    assert.deepEqual(f.seen.map((s) => s.url), [`${JOBS}/api/participants/${ID}/deny`, `${JOBS}/api/participants/${ID}/revoke`]);
    for (const s of f.seen) {
      assert.deepEqual(JSON.parse(s.body), { actor: 'console' });
      assert.equal(leadHeader(s), LEAD);
    }
  } finally { f.restore(); }
});

test('3a. paths that are not one UUID and one verb, and request, stay 405 and send nothing', async () => {
  const f = stubFetch();
  try {
    for (const rest of ['participants/request', `participants/../${ID}/approve`, `participants/${ID}/approve/x`,
      'participants/not-a-uuid/approve', `participants/${ID.toUpperCase()}/approve`, `participants/${ID}/delete`,
      `participants/${ID}`, 'participants']) {
      const res = await call(rest, 'POST', JSON.stringify({ granted_roles: ['fix'] }));
      assert.equal(res.status, 405, rest);
    }
    for (const method of ['PUT', 'PATCH', 'DELETE']) {
      const res = await call(`participants/${ID}/approve`, method, method === 'DELETE' ? undefined : '{}');
      assert.equal(res.status, 405, method);
    }
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('3b. approve with a bad granted_roles is a 400 and sends nothing', async () => {
  const f = stubFetch();
  try {
    const nine = Array.from({ length: 9 }, (_, i) => `r${i}`);
    for (const body of [{}, { granted_roles: [] }, { granted_roles: 'lead-review' }, { granted_roles: [1] },
      { granted_roles: [''] }, { granted_roles: ['x'.repeat(33)] }, { granted_roles: nine }, { granted_roles: null }]) {
      const res = await call(`participants/${ID}/approve`, 'POST', JSON.stringify(body));
      assert.equal(res.status, 400, JSON.stringify(body));
      assert.match((await res.json()).error, /granted_roles must be a non-empty array of role names/);
    }
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('3c. LEAD_VERDICT_TOKEN unset or blank is a 503 naming it, and nothing is forwarded', async () => {
  const f = stubFetch();
  try {
    for (const lead of [undefined, '', '  \n']) {
      const env = { HARNESS_SECRET: SECRET, ...(lead === undefined ? {} : { LEAD_VERDICT_TOKEN: lead }) };
      for (const verb of ['approve', 'deny', 'revoke']) {
        const res = await call(`participants/${ID}/${verb}`, 'POST', JSON.stringify({ granted_roles: ['fix'] }), { env });
        assert.equal(res.status, 503, `${verb} ${JSON.stringify(lead)}`);
        assert.match((await res.json()).error, /LEAD_VERDICT_TOKEN is not set on this Pages project/);
      }
    }
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('4. GET participants and GET participants/<id> pass through with no lead token', async () => {
  const f = stubFetch();
  try {
    assert.equal((await call('participants', 'GET')).status, 200);
    assert.equal((await call(`participants/${ID}`, 'GET', undefined, { headers: { 'x-lead-verdict-token': 'forged' } })).status, 200);
    assert.deepEqual(f.seen.map((s) => s.url), [`${JOBS}/api/participants`, `${JOBS}/api/participants/${ID}`]);
    for (const s of f.seen) assert.equal(leadHeader(s), undefined);
  } finally { f.restore(); }
});

test('5. a browser-sent lead token or actor is never forwarded; the proxy\'s own values are', async () => {
  const f = stubFetch();
  try {
    await call(`participants/${ID}/approve`, 'POST', JSON.stringify({ granted_roles: ['fix'], actor: 'mallory' }),
      { headers: { 'x-lead-verdict-token': 'forged' } });
    assert.equal(f.seen.length, 1);
    assert.equal(leadHeader(f.seen[0]), LEAD);
    assert.equal(JSON.parse(f.seen[0].body).actor, 'console');
  } finally { f.restore(); }
});

test('6. a write that is not a participant decision never carries the lead token', async () => {
  const f = stubFetch();
  try {
    await call('settings', 'PUT', JSON.stringify({ key: 'k', value: '1' }));
    assert.equal(f.seen.length, 1);
    assert.equal(leadHeader(f.seen[0]), undefined);
  } finally { f.restore(); }
});
