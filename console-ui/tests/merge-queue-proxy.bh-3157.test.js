import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/coord/[[path]].js';

// BH-3157 (BH-2325.2): the coord proxy's write rows for the merge-queue PATCH
// and the conductor's held-page release POST. Each case goes through the real
// onRequest with a stubbed fetch. A valid write forwards exactly the listed
// fields plus the proxy's actor; anything invalid is a 400 that reaches
// nothing; the sibling verbs stay 405.

const JOBS = 'https://harness-jobs.operator.workers.dev';
const CONSOLE = 'https://harness-console.operator.workers.dev';
const SECRET = 'test-harness-secret';

function stubFetch(extra = () => null) {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith(CONSOLE)) return new Response('', { status: 200 });
    const other = await extra(target, init);
    if (other) return other;
    seen.push({ url: target, method: init.method, body: init.body });
    return new Response('{"ok":true}', { status: 200, headers: { 'content-type': 'application/json' } });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}

let cookieSeq = 0;
const call = (rest, method, body, { env = { HARNESS_SECRET: SECRET }, headers = {} } = {}) =>
  onRequest({
    request: new Request(`https://console.example.pages.dev/api/coord/${rest}`, {
      method,
      headers: { cookie: `dash=bh3157-${++cookieSeq}`, 'content-type': 'application/json', ...headers },
      body
    }),
    env,
    params: { path: rest.split('/') }
  });

// A raw JSON string, so the __proto__ key is a real own key of the parsed body.
const MQ_SENT = '{"actor":"mallory","extra":1,"__proto__":{"polluted":1},"project":"project-3","pr":41,"status":"blocked","reason":"waiting on ci"}';
const MQ_LEGIT = { project: 'project-3', pr: 41, status: 'blocked', reason: 'waiting on ci' };

test('P1: PATCH merge-queue forwards exactly {project, pr, status, reason, actor} with the proxy actor', async () => {
  const f = stubFetch();
  try {
    const res = await call('merge-queue', 'PATCH', MQ_SENT);
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/merge-queue`);
    assert.equal(f.seen[0].method, 'PATCH');
    assert.equal(f.seen[0].body, '{"project":"project-3","pr":41,"status":"blocked","reason":"waiting on ci","actor":"console"}');
  } finally { f.restore(); }
});

test('P1: each allowed status forwards; a padded reason and project travel as sent', async () => {
  const f = stubFetch();
  try {
    for (const status of ['queued', 'blocked', 'dropped']) {
      const res = await call('merge-queue', 'PATCH', JSON.stringify({ ...MQ_LEGIT, status }));
      assert.equal(res.status, 200, status);
    }
    const res = await call('merge-queue', 'PATCH', JSON.stringify({ ...MQ_LEGIT, project: ' project-3 ', reason: ' why ' }));
    assert.equal(res.status, 200);
    assert.deepEqual(f.seen.map((s) => JSON.parse(s.body).status), ['queued', 'blocked', 'dropped', 'blocked']);
    assert.deepEqual(JSON.parse(f.seen[3].body), { project: ' project-3 ', pr: 41, status: 'blocked', reason: ' why ', actor: 'console' });
  } finally { f.restore(); }
});

test('P1: the worker status is returned verbatim (a 409 transition refusal passes through)', async () => {
  const f = stubFetch((url) => (url === `${JOBS}/api/merge-queue`
    ? new Response('{"error":"bad transition"}', { status: 409, headers: { 'content-type': 'application/json' } })
    : null));
  try {
    const res = await call('merge-queue', 'PATCH', JSON.stringify(MQ_LEGIT));
    assert.equal(res.status, 409);
    assert.deepEqual(await res.json(), { error: 'bad transition' });
  } finally { f.restore(); }
});

// The Access-email actor: the bh-2612 signed-JWT and certs-stub setup.
const TEAM = 'team.example.cloudflareaccess.com';
const CERTS = `https://${TEAM}/cdn-cgi/access/certs`;
const AUD = 'test-aud';
const b64u = (bytes) => Buffer.from(bytes).toString('base64url');
const enc = (obj) => b64u(Buffer.from(JSON.stringify(obj)));
const KEY = await crypto.subtle.generateKey(
  { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
  true, ['sign', 'verify']);
const KID = 'kid-1';
const JWK = { ...(await crypto.subtle.exportKey('jwk', KEY.publicKey)), kid: KID, alg: 'RS256', use: 'sig' };
// determinism: ok-file clock-now-js the one clock read is NOW, captured once at
// load; exp/iat are offsets from it because the verifier checks exp against the
// real clock. No case asserts a calendar date.
const NOW = Date.now();
async function jwt() {
  const s = Math.floor(NOW / 1000);
  const payload = { aud: [AUD], iss: `https://${TEAM}`, email: 'operator@example.com', exp: s + 600, iat: s - 5, sub: 'u1' };
  const input = `${enc({ alg: 'RS256', kid: KID, typ: 'JWT' })}.${enc(payload)}`;
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', KEY.privateKey, new TextEncoder().encode(input));
  return `${input}.${b64u(new Uint8Array(sig))}`;
}

test('P1: with Access verified, the forwarded actor is the operator email, not the browser actor', async () => {
  const token = await jwt();
  const f = stubFetch((url) => (url === CERTS
    ? new Response(JSON.stringify({ keys: [JWK] }), { status: 200, headers: { 'content-type': 'application/json' } })
    : null));
  try {
    const res = await call('merge-queue', 'PATCH', MQ_SENT, {
      env: { HARNESS_SECRET: SECRET, CF_ACCESS_TEAM_DOMAIN: TEAM, CF_ACCESS_AUD: AUD },
      headers: { 'cf-access-authenticated-user-email': 'operator@example.com', 'cf-access-jwt-assertion': token }
    });
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].body, '{"project":"project-3","pr":41,"status":"blocked","reason":"waiting on ci","actor":"operator@example.com"}');
  } finally { f.restore(); }
});

test('P2: a bad status, pr or project is a 400 and reaches nothing', async () => {
  const f = stubFetch();
  try {
    const { project, ...noProject } = MQ_LEGIT;
    const bad = [
      [{ ...MQ_LEGIT, status: 'landed' }, /never records a landing/],
      [{ ...MQ_LEGIT, status: 'LANDED' }, /status must be one of/],
      [{ ...MQ_LEGIT, status: ' queued' }, /status must be one of/],
      [{ ...MQ_LEGIT, status: 'held' }, /status must be one of/],
      [{ ...MQ_LEGIT, pr: '41' }, /^pr must be a positive integer$/],
      [{ ...MQ_LEGIT, pr: 41.5 }, /^pr must be a positive integer$/],
      [{ ...MQ_LEGIT, pr: -1 }, /^pr must be a positive integer$/],
      [{ ...MQ_LEGIT, pr: 0 }, /^pr must be a positive integer$/],
      [{ ...MQ_LEGIT, pr: null }, /^pr must be a positive integer$/],
      [noProject, /^project required$/],
      [{ ...MQ_LEGIT, project: '   ' }, /^project required$/],
      [{ ...MQ_LEGIT, project: 7 }, /^project required$/]
    ];
    assert.equal(project, 'project-3');
    for (const [body, msg] of bad) {
      const res = await call('merge-queue', 'PATCH', JSON.stringify(body));
      assert.equal(res.status, 400, JSON.stringify(body));
      assert.match((await res.json()).error, msg, JSON.stringify(body));
    }
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('P2: a non-object PATCH body is the existing JSON-object 400', async () => {
  const f = stubFetch();
  try {
    for (const body of ['[]', '"x"', '{not json']) {
      const res = await call('merge-queue', 'PATCH', body);
      assert.equal(res.status, 400, body);
      assert.match((await res.json()).error, /must carry a JSON object body/);
    }
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('P3: a missing, blank or non-string reason is a 400 and reaches nothing', async () => {
  const f = stubFetch();
  try {
    const { reason, ...noReason } = MQ_LEGIT;
    assert.equal(reason, 'waiting on ci');
    for (const body of [{ ...MQ_LEGIT, reason: '' }, { ...MQ_LEGIT, reason: '   ' }, noReason, { ...MQ_LEGIT, reason: 5 }]) {
      const res = await call('merge-queue', 'PATCH', JSON.stringify(body));
      assert.equal(res.status, 400, JSON.stringify(body));
      assert.equal((await res.json()).error, 'a reason is required');
    }
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

const HELD_LEGIT = { repo: 'example-org/cromford', number: 12, state: 'READY', head: 'abc123', kind: 'STUCK', why: 'fixed by hand' };

test('P4: POST conductor/held/release forwards exactly its six fields plus the proxy actor', async () => {
  const f = stubFetch();
  try {
    const res = await call('conductor/held/release', 'POST', JSON.stringify({ ...HELD_LEGIT, actor: 'x', extra: 1 }));
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/conductor/held/release`);
    assert.equal(f.seen[0].method, 'POST');
    assert.equal(f.seen[0].body, '{"repo":"example-org/cromford","number":12,"state":"READY","head":"abc123","kind":"STUCK","why":"fixed by hand","actor":"console"}');
  } finally { f.restore(); }
});

test('P4: a blank why, a string number or a missing/non-string field is a 400 and reaches nothing', async () => {
  const f = stubFetch();
  try {
    const { repo, ...noRepo } = HELD_LEGIT;
    assert.equal(repo, 'example-org/cromford');
    const bad = [
      [{ ...HELD_LEGIT, why: '' }, /^a why is required$/],
      [{ ...HELD_LEGIT, why: '  ' }, /^a why is required$/],
      [{ ...HELD_LEGIT, why: 3 }, /^a why is required$/],
      [{ ...HELD_LEGIT, number: '12' }, /^number must be a positive integer$/],
      [{ ...HELD_LEGIT, number: 1.5 }, /^number must be a positive integer$/],
      [{ ...HELD_LEGIT, number: 0 }, /^number must be a positive integer$/],
      [noRepo, /^repo must be a string$/],
      [{ ...HELD_LEGIT, state: 1 }, /^state must be a string$/],
      [{ ...HELD_LEGIT, head: null }, /^head must be a string$/],
      [{ ...HELD_LEGIT, kind: ['STUCK'] }, /^kind must be a string$/]
    ];
    for (const [body, msg] of bad) {
      const res = await call('conductor/held/release', 'POST', JSON.stringify(body));
      assert.equal(res.status, 400, JSON.stringify(body));
      assert.match((await res.json()).error, msg, JSON.stringify(body));
    }
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('P5: the sibling verbs on merge-queue and conductor/held stay 405 and reach nothing', async () => {
  const f = stubFetch();
  try {
    const cases = [
      ['merge-queue', 'POST'],
      ['merge-queue', 'DELETE'],
      ['merge-queue', 'PUT'],
      ['conductor/held', 'PUT'],
      ['conductor/held', 'POST'],
      ['conductor/held', 'DELETE'],
      ['conductor/held/release', 'PATCH'],
      ['conductor/held/release', 'PUT']
    ];
    for (const [rest, method] of cases) {
      const body = method === 'DELETE' ? undefined : JSON.stringify(method === 'POST' && rest === 'conductor/held' ? HELD_LEGIT : MQ_LEGIT);
      const res = await call(rest, method, body);
      assert.equal(res.status, 405, `${method} ${rest}`);
      assert.equal((await res.json()).error, `method ${method} not allowed on /api/coord/${rest}`);
    }
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});
