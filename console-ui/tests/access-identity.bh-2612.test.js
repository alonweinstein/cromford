import test, { mock } from 'node:test';
import assert from 'node:assert/strict';
import { onRequest as coord } from '../functions/api/coord/[[path]].js';
import { resolveIdentity, _resetCertsCache } from '../functions/_lib/access-identity.js';

// BH-2612: the Access certs fetch inside resolveIdentity is bounded. A certs
// host that never answers used to hold every console write, every command and
// the whoami read until the Workers subrequest timeout. Now the fetch carries
// an AbortSignal that fires after 3 s, and a timed-out fetch is like any other
// certs failure: the actor is 'console', access 'unverified', and the host is
// asked again at most once a minute.
//
// The whoami and write cases go through the real onRequest of the coord
// function. The clock for the timeout is node:test's mocked setTimeout, so
// nothing here waits 3 real seconds.

const JOBS = 'https://harness-jobs.operator.workers.dev';
const CONSOLE = 'https://harness-console.operator.workers.dev';
const TEAM = 'team.example.cloudflareaccess.com';
const CERTS = `https://${TEAM}/cdn-cgi/access/certs`;
const AUD = 'test-aud';
const ENV_ON = { HARNESS_SECRET: 'test-harness-secret', CF_ACCESS_TEAM_DOMAIN: TEAM, CF_ACCESS_AUD: AUD };
const UNVERIFIED = { actor: 'console', access: 'unverified', email: null };

const b64u = (bytes) => Buffer.from(bytes).toString('base64url');
const enc = (obj) => b64u(Buffer.from(JSON.stringify(obj)));

const KEY = await crypto.subtle.generateKey(
  { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
  true, ['sign', 'verify']);
const KID = 'kid-1';
const JWK = { ...(await crypto.subtle.exportKey('jwk', KEY.publicKey)), kid: KID, alg: 'RS256', use: 'sig' };

// determinism: ok-file clock-now-js the one clock read is NOW below, captured
// once at load. Every exp/iat and every resolveIdentity time is an OFFSET from
// it (the verifier checks exp against the real clock, so the anchor must be
// real); no case asserts a calendar date.
const NOW = Date.now();
const nowS = () => Math.floor(NOW / 1000);
async function jwt() {
  const payload = { aud: [AUD], iss: `https://${TEAM}`, email: 'operator@example.com', exp: nowS() + 600, iat: nowS() - 5, sub: 'u1' };
  const input = `${enc({ alg: 'RS256', kid: KID, typ: 'JWT' })}.${enc(payload)}`;
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', KEY.privateKey, new TextEncoder().encode(input));
  return `${input}.${b64u(new Uint8Array(sig))}`;
}
const TOKEN = await jwt();
const ACCESS = { 'cf-access-authenticated-user-email': 'operator@example.com', 'cf-access-jwt-assertion': TOKEN };

// certs: 'hang' answers only when the request's signal aborts (with no signal it
// never settles, which is the defect); 'good' answers the key at once.
function stub({ certs = 'hang' } = {}) {
  const jobs = []; const certsInits = [];
  let called; const certsCalled = new Promise((r) => { called = r; });
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const url = typeof input === 'string' ? input : input.url;
    if (url === CERTS) {
      certsInits.push(init);
      called();
      if (certs === 'good') {
        return new Response(JSON.stringify({ keys: [JWK] }), { status: 200, headers: { 'content-type': 'application/json' } });
      }
      return new Promise((_, reject) => {
        const s = init.signal;
        if (!s) return;
        s.addEventListener('abort', () => reject(Object.assign(new Error('aborted'), { name: 'AbortError' })));
      });
    }
    if (url === `${CONSOLE}/api/dash/fleet` && !init.method) return new Response('{}', { status: 200 });
    if (url.startsWith(JOBS)) {
      jobs.push({ url, method: init.method, body: init.body });
      return new Response('{"ok":true}', { status: 200, headers: { 'content-type': 'application/json' } });
    }
    throw new Error(`unexpected fetch ${url}`);
  };
  return { jobs, certsInits, certsCalled, restore: () => { globalThis.fetch = real; } };
}

let seq = 0;
function coordCall(rest, { method = 'GET', body = null } = {}) {
  return coord({
    request: new Request(`https://mc.example.com/api/coord/${rest}`, {
      method,
      headers: { cookie: `dash=bh2612-${++seq}`, 'content-type': 'application/json', ...ACCESS },
      body: body == null ? null : JSON.stringify(body)
    }),
    env: ENV_ON,
    params: { path: rest.split('/').filter(Boolean) }
  });
}
const req = () => new Request('https://mc.example.com/x', { headers: ACCESS });

// Whether p has settled once every queued microtask has run. setImmediate is
// not mocked, so this is a real turn of the event loop.
const PENDING = Symbol('pending');
const peek = (p) => Promise.race([p, new Promise((r) => setImmediate(() => r(PENDING)))]);

// A hung promise must fail its test, not hang the run: a real-clock bound.
const OPTS = { timeout: 5000 };

test.beforeEach(() => {
  _resetCertsCache();
  mock.timers.enable({ apis: ['setTimeout'] });
});
test.afterEach(() => mock.timers.reset());

test('T1 T2 T6 a hanging certs host: whoami waits 3 s, then answers console, unverified', OPTS, async () => {
  const s = stub();
  try {
    const p = coordCall('whoami');
    await s.certsCalled;
    assert.ok(s.certsInits[0].signal instanceof AbortSignal, 'T6 the certs fetch carries an AbortSignal');
    mock.timers.tick(2999);
    assert.equal(await peek(p), PENDING, 'T1 still waiting before the 3 s timeout');
    mock.timers.tick(1);
    const res = await p;
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), UNVERIFIED, 'T2');
    assert.equal(s.jobs.length, 0, 'whoami is answered locally');
  } finally { s.restore(); }
});

test('T3 a coord write under a hanging certs host forwards actor console after the timeout', OPTS, async () => {
  const s = stub();
  try {
    const p = coordCall('flags', { method: 'PUT', body: { name: 'paused-project-3', active: 1, actor: 'mallory' } });
    await s.certsCalled;
    assert.equal(await peek(p), PENDING);
    assert.equal(s.jobs.length, 0, 'nothing forwarded while the certs fetch is open');
    mock.timers.tick(3000);
    const res = await p;
    assert.equal(res.status, 200);
    const w = s.jobs.filter((c) => c.method === 'PUT');
    assert.equal(w.length, 1);
    assert.equal(JSON.parse(w[0].body).actor, 'console');
  } finally { s.restore(); }
});

test('T4 after a timeout the certs host is not asked again for 60 s, then it is', OPTS, async () => {
  let s = stub();
  try {
    const p = resolveIdentity(req(), ENV_ON, NOW);
    await s.certsCalled;
    mock.timers.tick(3000);
    assert.deepEqual(await p, UNVERIFIED);
    // inside the backoff: answers at once, with no tick and no fetch
    assert.deepEqual(await peek(resolveIdentity(req(), ENV_ON, NOW + 1000)), UNVERIFIED);
    assert.equal(s.certsInits.length, 1, 'no refetch inside the 60 s backoff');
  } finally { s.restore(); }
  s = stub({ certs: 'good' });
  try {
    assert.deepEqual(await resolveIdentity(req(), ENV_ON, NOW + 61_000),
      { actor: 'operator@example.com', access: 'on', email: 'operator@example.com' });
    assert.equal(s.certsInits.length, 1, 'fetched again after the backoff');
  } finally { s.restore(); }
});

test('T5 a fast good certs answer verifies and leaves no timer to abort it later', OPTS, async () => {
  const s = stub({ certs: 'good' });
  try {
    assert.deepEqual(await resolveIdentity(req(), ENV_ON, NOW),
      { actor: 'operator@example.com', access: 'on', email: 'operator@example.com' });
    const { signal } = s.certsInits[0];
    assert.ok(signal instanceof AbortSignal);
    mock.timers.tick(3000);
    assert.equal(signal.aborted, false, 'the timeout was cleared once the fetch finished');
  } finally { s.restore(); }
});
