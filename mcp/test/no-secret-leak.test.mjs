// No credential leaves the process: the cookie login against the stub console,
// then sweeps of the real `node mcp/server.mjs` with a token and with a secret,
// and mutation pins proving the leak checks would see a broken redactor.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { cpSync, mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import http from 'node:http';
import { startStub } from './lib/stub-console.mjs';
import { consoleFetch, redact } from '../lib/console.mjs';

const MCP_DIR = fileURLToPath(new URL('..', import.meta.url));
const SERVER = join(MCP_DIR, 'server.mjs');
const TOKEN = 'tok-fixture-x';
const SECRET = 'sec-fixture-x';
const COOKIE = 'ck-fixture-y';
const FLEET = '/api/dash/fleet';

const logins = (stub) => stub.requests.filter((r) => r.path.startsWith('/login/'));
const fleetHits = (stub) => stub.requests.filter((r) => r.path === FLEET);

function spawnServer(server, env) {
  const child = spawn(process.execPath, [server], {
    env: { PATH: process.env.PATH, ...env },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  let stderr = '';
  child.stderr.on('data', (c) => { stderr += c; });
  const pending = new Map();
  createInterface({ input: child.stdout }).on('line', (line) => {
    const m = JSON.parse(line);
    pending.get(m.id)?.(m);
    pending.delete(m.id);
  });
  const exited = new Promise((r) => child.on('exit', r));
  let id = 0;
  const rpc = (method, params) => new Promise((resolve) => {
    pending.set(++id, resolve);
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  });
  return {
    rpc,
    stderr: () => stderr,
    end: async () => { child.stdin.end(); await exited; return stderr; },
    kill: () => child.kill(),
  };
}

// Calls every listed tool that takes no confirm, then fleet_status again against
// a 500 that echoes the request headers. Returns every string the client saw.
async function sweep(server, env, stubOpts) {
  const stub = await startStub(stubOpts);
  const srv = spawnServer(server, { HARNESS_CONSOLE_URL: stub.url, ...env });
  try {
    const seen = [];
    const keep = (r) => {
      seen.push(JSON.stringify(r));
      for (const c of r.result?.content ?? []) seen.push(c.text);
      if (r.result?.structuredContent !== undefined) seen.push(JSON.stringify(r.result.structuredContent));
    };
    const { result } = await srv.rpc('tools/list', {});
    const names = result.tools.filter((t) => !('confirm' in (t.inputSchema.properties ?? {}))).map((t) => t.name);
    for (const name of names) keep(await srv.rpc('tools/call', { name, arguments: {} }));
    const okFleet = fleetHits(stub).at(-1);
    stub.fail(FLEET, 500);
    const failed = await srv.rpc('tools/call', { name: 'fleet_status', arguments: {} });
    keep(failed);
    const stderr = await srv.end();
    return { names, seen, stderr, stub, okFleet, failed };
  } finally {
    srv.kill();
    await stub.close();
  }
}

// A server whose console URL answers nothing: the login fails at the network.
async function closedRun(server) {
  const stub = await startStub();
  await stub.close();
  const srv = spawnServer(server, { HARNESS_CONSOLE_URL: stub.url, HARNESS_CONSOLE_SECRET: SECRET });
  try {
    const r = await srv.rpc('tools/call', { name: 'fleet_status', arguments: {} });
    return { r, stderr: await srv.end() };
  } finally {
    srv.kill();
  }
}

const leaks = (texts, value) => texts.filter((t) => typeof t === 'string' && t.includes(value));

// A copy of mcp/ with one source edit applied; the anchor must be found once.
function mutated(t, file, anchor, replacement) {
  const dir = mkdtempSync(join(tmpdir(), 'mcp-mut-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  cpSync(MCP_DIR, dir, { recursive: true });
  const path = join(dir, file);
  const src = readFileSync(path, 'utf8');
  assert.equal(src.split(anchor).length, 2, `mutation anchor not found exactly once: ${anchor}`);
  writeFileSync(path, src.replace(anchor, replacement));
  return join(dir, 'server.mjs');
}

// ---- in-process: the cookie login ----

test('L1 secret only: one login, then the API call carries the dash cookie', async (t) => {
  const stub = await startStub();
  t.after(() => stub.close());
  const cfg = { url: stub.url, token: null, secret: SECRET };
  const r = await consoleFetch(cfg, 'GET', FLEET);
  assert.equal(r.ok, true);
  assert.deepEqual(stub.requests.map((q) => `${q.method} ${q.path}`), [`GET /login/${SECRET}`, `GET ${FLEET}`]);
  assert.equal(stub.requests[1].cookie, `dash=ck-${SECRET}`);
  assert.equal(stub.requests[1].authorization, null);
  assert.equal(r.data.cookie, `dash=ck-${SECRET}`);
  const again = await consoleFetch(cfg, 'GET', FLEET);
  assert.equal(again.ok, true);
  assert.equal(logins(stub).length, 1, 'the cookie is reused, not a second login');
  assert.equal(fleetHits(stub)[1].cookie, `dash=ck-${SECRET}`);
});

test('L1b concurrent calls share one login', async (t) => {
  const stub = await startStub();
  t.after(() => stub.close());
  const cfg = { url: stub.url, token: null, secret: SECRET };
  const rs = await Promise.all([1, 2, 3].map(() => consoleFetch(cfg, 'GET', FLEET)));
  assert.ok(rs.every((r) => r.ok));
  assert.equal(logins(stub).length, 1);
  assert.equal(fleetHits(stub).length, 3);
});

test('L2 a 401 once: exactly one re-login and one retry, then success', async (t) => {
  const stub = await startStub();
  t.after(() => stub.close());
  stub.fail(FLEET, '401-once');
  const r = await consoleFetch({ url: stub.url, token: null, secret: SECRET }, 'GET', FLEET);
  assert.equal(r.ok, true);
  assert.equal(logins(stub).length, 2);
  assert.equal(fleetHits(stub).length, 2);
});

test('L3 a persistent 401: one retry only, then http_401', async (t) => {
  const stub = await startStub({ routes: { [FLEET]: { status: 401, json: { error: 'unauthorized' } } } });
  t.after(() => stub.close());
  const r = await consoleFetch({ url: stub.url, token: null, secret: SECRET }, 'GET', FLEET);
  assert.deepEqual(r, { ok: false, status: 401, error: 'http_401' });
  assert.equal(logins(stub).length, 2);
  assert.equal(fleetHits(stub).length, 2);
});

test('L4 token and secret: the token wins and nothing logs in', async (t) => {
  const stub = await startStub();
  t.after(() => stub.close());
  const r = await consoleFetch({ url: stub.url, token: TOKEN, secret: SECRET }, 'GET', FLEET);
  assert.equal(r.ok, true);
  assert.equal(logins(stub).length, 0);
  assert.equal(stub.requests[0].authorization, `Bearer ${TOKEN}`);
  assert.equal(stub.requests[0].cookie, null);
});

test('L4b a 401 in token mode does not log in or retry', async (t) => {
  const stub = await startStub({ routes: { [FLEET]: { status: 401, json: { error: 'unauthorized' } } } });
  t.after(() => stub.close());
  const r = await consoleFetch({ url: stub.url, token: TOKEN, secret: SECRET }, 'GET', FLEET);
  assert.deepEqual(r, { ok: false, status: 401, error: 'http_401' });
  assert.equal(logins(stub).length, 0);
  assert.equal(fleetHits(stub).length, 1);
});

test('L5 a login answer with no dash cookie sends no API request', async (t) => {
  const hits = [];
  const server = http.createServer((req, res) => {
    hits.push(req.url);
    if (req.url.startsWith('/login/')) { res.writeHead(403, { 'set-cookie': 'other=1; Path=/' }); return res.end(); }
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end('{}');
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  t.after(() => new Promise((r) => server.close(r)));
  const url = `http://127.0.0.1:${server.address().port}`;
  const r = await consoleFetch({ url, token: null, secret: SECRET }, 'GET', FLEET);
  assert.deepEqual(r, { ok: false, status: 403, error: 'console_login_failed' });
  assert.deepEqual(hits, [`/login/${SECRET}`]);
});

test('U1 redact scrubs the cached cookie and the login path after a login', async (t) => {
  const stub = await startStub({ cookie: COOKIE });
  t.after(() => stub.close());
  const secret = 'sec/fixture?x';
  const cfg = { url: stub.url, token: null, secret };
  assert.equal((await consoleFetch(cfg, 'GET', FLEET)).ok, true);
  assert.equal(stub.requests[0].path, '/login/' + encodeURIComponent(secret));
  const out = redact(`x ${COOKIE} /login/${encodeURIComponent(secret)} /login/${secret} ${secret}`, cfg);
  for (const v of [COOKIE, secret, encodeURIComponent(secret)]) assert.ok(!out.includes(v), `${v} leaked: ${out}`);
  assert.ok(out.includes('/login/[redacted]'), out);
  assert.equal(redact(42, cfg), '42');
  // A different config object never sees this one's cookie.
  assert.ok(redact(COOKIE, { url: stub.url, token: null, secret: 'other' }).includes(COOKIE));
});

// ---- the real server process ----

test('L6 network failure: stderr names the failed login with the secret redacted', async () => {
  const { r, stderr } = await closedRun(SERVER);
  assert.equal(r.result.isError, true);
  assert.equal(r.result.content[0].text, 'network_error');
  assert.ok(stderr.includes('/login/[redacted]'), stderr);
  assert.ok(!stderr.includes(SECRET), stderr);
});

test('S1 token sweep: every no-confirm tool plus a 500 echo, the token never surfaces', async () => {
  const { names, seen, stderr, okFleet, failed } = await sweep(SERVER, { HARNESS_CONSOLE_TOKEN: TOKEN });
  assert.ok(names.includes('fleet_status'), names.join(','));
  assert.equal(okFleet.authorization, `Bearer ${TOKEN}`, 'positive control: the token was sent');
  assert.equal(failed.result.isError, true);
  assert.deepEqual(leaks(seen, TOKEN), []);
  assert.ok(!stderr.includes(TOKEN), stderr);
});

test('S2 secret sweep: one login, cookie sent, neither secret nor cookie surfaces', async () => {
  const { names, seen, stderr, stub, okFleet, failed } = await sweep(SERVER, { HARNESS_CONSOLE_SECRET: SECRET }, { cookie: COOKIE });
  assert.ok(names.includes('fleet_status'), names.join(','));
  assert.equal(logins(stub).length, 1);
  assert.equal(stub.requests[0].path, `/login/${SECRET}`);
  assert.equal(okFleet.cookie, `dash=${COOKIE}`, 'positive control: the cookie was sent');
  assert.equal(okFleet.authorization, null);
  assert.equal(failed.result.isError, true);
  for (const v of [SECRET, COOKIE]) {
    assert.deepEqual(leaks(seen, v), [], `${v} surfaced in a result`);
    assert.ok(!stderr.includes(v), stderr);
  }
});

// ---- mutation pins: the leak checks above would see a broken redactor ----

test('M1 with redact returning its input, the cookie and the secret surface', async (t) => {
  const server = mutated(t, 'lib/console.mjs', 'export function redact(text, cfg) {', 'export function redact(text, cfg) { return String(text);');
  const { seen } = await sweep(server, { HARNESS_CONSOLE_SECRET: SECRET }, { cookie: COOKIE });
  assert.ok(leaks(seen, COOKIE).length > 0, 'the cookie should leak through a broken redact');
  const { stderr } = await closedRun(server);
  assert.ok(stderr.includes(SECRET), 'the secret should leak through a broken redact');
});

test('M2 with the cookie dropped from redact, the cookie surfaces', async (t) => {
  const server = mutated(t, 'lib/console.mjs', 'const cookie = jar.get(cfg)?.cookie;', 'const cookie = null;');
  const { seen } = await sweep(server, { HARNESS_CONSOLE_SECRET: SECRET }, { cookie: COOKIE });
  assert.ok(leaks(seen, COOKIE).length > 0);
  assert.deepEqual(leaks(seen, SECRET), []);
});
