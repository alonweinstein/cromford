// BH-5820: the MCP board actions reach the hub under the hub's own type name,
// and a console refusal reaches the MCP user with its reason.
// M1-M3 run a real `node mcp/server.mjs` child against the stub console;
// M4-M5 call consoleFetch / forward directly.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { startStub } from './lib/stub-console.mjs';
import { consoleFetch } from '../lib/console.mjs';
import { forward } from '../lib/tools.mjs';

const SERVER = fileURLToPath(new URL('../server.mjs', import.meta.url));
const TOKEN = 'tok-fixture-bh5820';

async function serve(t, stubOpts = {}) {
  const stub = await startStub(stubOpts);
  const child = spawn(process.execPath, [SERVER], {
    env: { PATH: process.env.PATH, HARNESS_CONSOLE_URL: stub.url, HARNESS_CONSOLE_TOKEN: TOKEN },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  child.stderr.on('data', () => {});
  const pending = new Map();
  createInterface({ input: child.stdout }).on('line', (line) => {
    const m = JSON.parse(line);
    pending.get(m.id)?.(m);
    pending.delete(m.id);
  });
  let id = 0;
  const rpc = (method, params) => new Promise((resolve) => {
    const mid = ++id;
    pending.set(mid, resolve);
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: mid, method, params }) + '\n');
  });
  t.after(async () => { child.kill(); await stub.close(); });
  await rpc('initialize', { protocolVersion: '2025-11-25' });
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
  const call = async (name, args) => {
    const before = stub.requests.length;
    const r = await rpc('tools/call', { name, arguments: args });
    assert.equal(r.error, undefined, JSON.stringify(r));
    return { result: r.result, sent: stub.requests.slice(before) };
  };
  return { stub, call };
}

test('M1 hold_issue posts the hub type hold_ticket, once', async (t) => {
  const { call } = await serve(t);
  const { result, sent } = await call('hold_issue', { project: 'p', issue: 2, reason: 'r' });
  assert.equal(sent.length, 1);
  assert.equal(sent[0].method, 'POST');
  assert.equal(sent[0].path, '/api/dash/action');
  assert.equal(JSON.stringify(sent[0].body), '{"type":"hold_ticket","project":"p","issue":2,"reason":"r"}');
  assert.equal(result.isError, undefined);
  // No reason: the key is left out, not sent empty.
  const b = await call('hold_issue', { project: 'p', issue: 3 });
  assert.deepEqual(b.sent[0].body, { type: 'hold_ticket', project: 'p', issue: 3 });
});

test('M2 comment_issue is unchanged', async (t) => {
  const { call } = await serve(t);
  const { sent } = await call('comment_issue', { project: 'p', issue: 1, body: 'hi' });
  assert.equal(sent.length, 1);
  assert.equal(JSON.stringify(sent[0].body), '{"type":"comment_issue","project":"p","issue":1,"body":"hi"}');
});

test('M3 a console refusal shows its reason', async (t) => {
  const { call } = await serve(t, { routes: { '/api/dash/action': { status: 400, json: { error: 'unknown action' } } } });
  const { result } = await call('comment_issue', { project: 'p', issue: 1, body: 'hi' });
  assert.equal(result.isError, true);
  assert.equal(result.content[0].text, 'http_400: unknown action');
});

test('M4 a refusal reason is redacted and capped', async (t) => {
  const secret = 'tok-fixture-secret-bh5820';
  const stub = await startStub({ routes: {
    '/leak': { status: 400, json: { error: `bad token ${secret} here` } },
    '/long': { status: 422, json: { error: 'x'.repeat(500) } },
  } });
  t.after(() => stub.close());
  const cfg = { url: stub.url, token: secret };
  const r = await consoleFetch(cfg, 'POST', '/leak', {});
  assert.deepEqual(r, { ok: false, status: 400, error: 'http_400: bad token [redacted] here' });
  assert.ok(!r.error.includes(secret));
  const l = await consoleFetch(cfg, 'POST', '/long', {});
  assert.equal(l.error, 'http_422: ' + 'x'.repeat(200));
});

test('M5 no reason, auth and server errors keep the bare code', async (t) => {
  const stub = await startStub({ routes: {
    '/txt': { status: 400, json: 'not json' },
    '/blank': { status: 400, json: { error: '' } },
    '/num': { status: 400, json: { error: 7 } },
    '/e500': { status: 500, json: { error: 'x' } },
    '/e403bare': { status: 403, json: 'not json' },
  } });
  t.after(() => stub.close());
  const ctx = { cfg: { url: stub.url, token: TOKEN } };
  for (const [path, want] of [['/txt', 'http_400'], ['/blank', 'http_400'], ['/num', 'http_400'],
    ['/e500', 'http_500'], ['/e403bare', 'http_403']]) {
    const r = await forward(ctx, 'POST', path, {});
    assert.equal(r.isError, true, path);
    assert.equal(r.content[0].text, want, path);
  }
});

// M6 (lead review of 81b713ba): a 403 that carries an `error` string shows it,
// so a refused token client sees why (the Pages fallback answers
// {"error":"unauthorized"}). 401 keeps the bare code: it drives the re-login.
test('M6 a 403 with a reason carries it; a 401 stays bare', async (t) => {
  const stub = await startStub({ routes: {
    '/e403': { status: 403, json: { error: 'unauthorized' } },
  } });
  t.after(() => stub.close());
  const ctx = { cfg: { url: stub.url, token: TOKEN } };
  const r = await forward(ctx, 'POST', '/e403', {});
  assert.equal(r.isError, true);
  assert.equal(r.content[0].text, 'http_403: unauthorized');
});
