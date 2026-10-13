// The tracer path end to end: a real `node mcp/server.mjs` child against a stub
// console, plus in-process cases for config, redaction and the tool registry.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startStub } from './lib/stub-console.mjs';
import { loadConfig } from '../lib/config.mjs';
import { consoleFetch, redact } from '../lib/console.mjs';
import { loadTools, callTool, forward } from '../lib/tools.mjs';

const SERVER = fileURLToPath(new URL('../server.mjs', import.meta.url));
const TOOLS_DIR = fileURLToPath(new URL('../tools/', import.meta.url));
const TOKEN = 'tok-fixture-x';

function spawnServer(env) {
  const child = spawn(process.execPath, [SERVER], {
    env: { PATH: process.env.PATH, ...env },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  let stderr = '';
  child.stderr.on('data', (c) => { stderr += c; });
  const lines = [];
  const waiters = [];
  createInterface({ input: child.stdout }).on('line', (line) => {
    lines.push(line);
    for (const w of waiters.splice(0)) w();
  });
  const exited = new Promise((r) => child.on('exit', (code) => r(code)));
  let seen = 0;
  // Resolves the next stdout line, in order.
  const next = () => new Promise((resolve) => {
    const take = () => {
      if (seen < lines.length) return resolve(JSON.parse(lines[seen++]));
      waiters.push(take);
    };
    take();
  });
  const rpc = async (msg) => {
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...msg }) + '\n');
    for (;;) {
      const m = await next();
      if (m.id === msg.id) return m;
    }
  };
  return {
    child, lines, next, rpc, exited,
    stderr: () => stderr,
    raw: (text) => child.stdin.write(text + '\n'),
    notify: (msg) => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...msg }) + '\n'),
    end: () => { child.stdin.end(); return exited; },
  };
}

async function setup(t, env, stubOpts) {
  const stub = await startStub(stubOpts);
  const srv = spawnServer({ HARNESS_CONSOLE_URL: stub.url, ...env(stub) });
  t.after(async () => { srv.child.kill(); await stub.close(); });
  return { stub, srv };
}

const call = (srv, id, name, args) => srv.rpc({ id, method: 'tools/call', params: { name, arguments: args } });
const fleetHits = (stub) => stub.requests.filter((r) => r.path === '/api/dash/fleet');

// ---- in-process unit cases ----

test('U1 config: loadConfig parses all four settings', () => {
  const c = loadConfig({ HARNESS_CONSOLE_URL: 'https://h.example//', HARNESS_MCP_REPO_ALLOWLIST: ' A/B , c/d ,' });
  assert.equal(c.url, 'https://h.example');
  assert.equal(c.token, null);
  assert.equal(c.secret, null);
  assert.deepEqual(c.allowlist, ['a/b', 'c/d']);
  assert.deepEqual(loadConfig({ HARNESS_CONSOLE_URL: 'http://h' }).allowlist, []);
  assert.equal(loadConfig({ HARNESS_CONSOLE_URL: 'https://h/' }).url, 'https://h');
  for (const bad of [{}, { HARNESS_CONSOLE_URL: 'ftp://x' }, { HARNESS_CONSOLE_URL: 'nope' }]) {
    assert.throws(() => loadConfig(bad), /HARNESS_CONSOLE_URL/);
  }
});

test('U2 config: an empty token is no token', () => {
  const c = loadConfig({ HARNESS_CONSOLE_URL: 'http://h', HARNESS_CONSOLE_TOKEN: '  ', HARNESS_CONSOLE_SECRET: '' });
  assert.equal(c.token, null);
  assert.equal(c.secret, null);
  assert.equal(loadConfig({ HARNESS_CONSOLE_URL: 'http://h', HARNESS_CONSOLE_TOKEN: ' t1 ' }).token, 't1');
});

test('U3 redact: token and secret are scrubbed', () => {
  const cfg = { token: TOKEN, secret: 'sec-fixture-x' };
  const out = redact('a tok-fixture-x b sec-fixture-x tok-fixture-x', cfg);
  assert.ok(!out.includes(TOKEN) && !out.includes('sec-fixture-x'), out);
  assert.equal(out.split('[redacted]').length - 1, 3);
  assert.equal(redact('a tok-fixture-x', { token: null, secret: null }), 'a tok-fixture-x');
  assert.equal(redact(42, cfg), '42');
});

test('U4 redact: a value with JSON-special characters is scrubbed raw and escaped', () => {
  const tok = 't"x\\y.*';
  const cfg = { token: tok, secret: null };
  assert.ok(!redact(`raw ${tok} raw`, cfg).includes(tok));
  const json = JSON.stringify({ a: tok });
  const out = redact(json, cfg);
  assert.ok(!out.includes(JSON.stringify(tok).slice(1, -1)), out);
  assert.ok(out.includes('[redacted]'));
});

test('U5 registry: sorted load, duplicate and missing export throw, fleet_status ships', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'mcp-reg-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const mod = (name) => `export const tools = [{name:'${name}', description:'d', kind:'read', inputSchema:{type:'object', properties:{}}, handler: () => ({content:[]})}];\n`;
  writeFileSync(join(dir, 'b.mjs'), mod('two'));
  writeFileSync(join(dir, 'a.mjs'), mod('one'));
  writeFileSync(join(dir, 'notes.txt'), 'ignored');
  assert.deepEqual([...(await loadTools(dir)).keys()], ['one', 'two']);
  // Enough files, created out of order, that directory order alone is not sorted.
  const sub = join(dir, 'many');
  mkdirSync(sub);
  const names = ['q', 'c', 'x', 'h', 'm', 'b', 'v', 'e', 'k', 'z', 'a', 'r'];
  for (const n of names) writeFileSync(join(sub, `${n}.mjs`), mod(`t_${n}`));
  assert.deepEqual([...(await loadTools(sub)).keys()], [...names].sort().map((n) => `t_${n}`));

  writeFileSync(join(dir, 'c.mjs'), mod('one'));
  await assert.rejects(loadTools(dir), /duplicate tool name: one \(a\.mjs, c\.mjs\)/);
  rmSync(join(dir, 'c.mjs'));

  writeFileSync(join(dir, 'd.mjs'), 'export const tool = [];\n');
  await assert.rejects(loadTools(dir), /d\.mjs/);
  rmSync(join(dir, 'd.mjs'));

  writeFileSync(join(dir, 'e.mjs'), "export const tools = [{name:'bad', kind:'nope', inputSchema:{type:'object'}, handler(){}}];\n");
  await assert.rejects(loadTools(dir), /invalid tool bad in e\.mjs/);
  rmSync(join(dir, 'e.mjs'));

  const real = await loadTools(TOOLS_DIR);
  assert.equal(real.get('fleet_status')?.kind, 'read');
});

test('U6 order: precheck, then unknown key, then handler', async () => {
  let ran = 0;
  const base = { name: 'x', description: 'd', kind: 'read', handler: () => { ran++; return { content: [{ type: 'text', text: 'ran' }] }; } };
  const schema = {
    type: 'object', additionalProperties: false,
    properties: { filter: { type: 'object', additionalProperties: false, properties: { project: { type: 'string' } } } },
  };
  const reg = new Map([
    ['pre', { ...base, inputSchema: schema, precheck: () => 'nope' }],
    ['plain', { ...base, inputSchema: schema }],
  ]);
  const ctx = { cfg: { token: null, secret: null }, log: () => {} };

  const a = await callTool(reg, 'pre', { zzz: 1 }, ctx);
  assert.equal(a.isError, true);
  assert.equal(a.content[0].text, 'nope');

  const b = await callTool(reg, 'plain', { zzz: 1 }, ctx);
  assert.equal(b.isError, true);
  assert.equal(b.content[0].text, 'invalid_arguments: zzz');

  const c = await callTool(reg, 'plain', { filter: { x: 1 } }, ctx);
  assert.equal(c.content[0].text, 'invalid_arguments: filter.x');

  const d = await callTool(reg, 'plain', [1], ctx);
  assert.equal(d.content[0].text, 'invalid_arguments');
  assert.equal(ran, 0);

  assert.equal((await callTool(reg, 'plain', { filter: { project: 'p' } }, ctx)).content[0].text, 'ran');
  assert.equal((await callTool(reg, 'plain', undefined, ctx)).content[0].text, 'ran');
  assert.equal(ran, 2);
  assert.equal(await callTool(reg, 'missing', {}, ctx), null);
});

test('U6b handler throw: tool_failed, logged redacted', async () => {
  const logs = [];
  const reg = new Map([['boom', {
    name: 'boom', kind: 'read', inputSchema: { type: 'object' },
    handler: () => { throw new Error('bad tok-fixture-x'); },
  }]]);
  const r = await callTool(reg, 'boom', {}, { cfg: { token: TOKEN, secret: null }, log: (m) => logs.push(m) });
  assert.equal(r.isError, true);
  assert.equal(r.content[0].text, 'tool_failed');
  assert.equal(logs.length, 1);
  assert.ok(!logs[0].includes(TOKEN), logs[0]);
});

test('U7 forward: console answers map to honest MCP results (404 included)', async (t) => {
  const stub = await startStub({
    fail: { '/p': 404, '/e': 500 },
    routes: { '/obj': { json: { a: 1 } }, '/arr': { json: [1, 2] }, '/txt': { json: 'not json' }, '/empty': { json: '' } },
  });
  t.after(() => stub.close());
  const ctx = { cfg: { url: stub.url, token: TOKEN, secret: null } };

  const o = await forward(ctx, 'GET', '/obj');
  assert.deepEqual(o.structuredContent, { a: 1 });
  assert.deepEqual(JSON.parse(o.content[0].text), { a: 1 });
  assert.equal(o.isError, undefined);

  const a = await forward(ctx, 'GET', '/arr');
  assert.equal('structuredContent' in a, false);
  assert.deepEqual(JSON.parse(a.content[0].text), [1, 2]);

  const nf = await forward(ctx, 'GET', '/p');
  assert.equal(nf.isError, true);
  assert.equal(nf.content[0].text, 'console route not available: /p');

  assert.equal((await forward(ctx, 'GET', '/e')).content[0].text, 'http_500');
  assert.equal((await forward(ctx, 'GET', '/txt')).content[0].text, 'bad_json');

  const empty = await consoleFetch(ctx.cfg, 'GET', '/empty');
  assert.deepEqual(empty, { ok: true, status: 200, data: null });

  const posted = await consoleFetch(ctx.cfg, 'POST', '/obj2', { q: 1 });
  assert.deepEqual(posted.data.body, { q: 1 });
  assert.equal(stub.requests.at(-1).authorization, `Bearer ${TOKEN}`);

  const dead = await startStub();
  const deadUrl = dead.url;
  await dead.close();
  const net = await forward({ cfg: { url: deadUrl, token: TOKEN, secret: null } }, 'GET', '/x');
  assert.equal(net.isError, true);
  assert.equal(net.content[0].text, 'network_error');
});

test('U8 auth: no token and no secret sends nothing', async (t) => {
  const stub = await startStub();
  t.after(() => stub.close());
  const cfg = { url: stub.url, token: null, secret: null };
  assert.deepEqual(await consoleFetch(cfg, 'GET', '/api/dash/fleet'), { ok: false, status: 0, error: 'console_auth_not_configured' });
  assert.equal(stub.requests.length, 0);
});

// ---- spawned cases: the real server process ----

test('T1 initialize answers cromford and negotiates the protocol', async (t) => {
  const { srv } = await setup(t, () => ({ HARNESS_CONSOLE_TOKEN: TOKEN }));
  const r = await srv.rpc({ id: 1, method: 'initialize', params: { protocolVersion: '2025-11-25' } });
  assert.equal(r.result.serverInfo.name, 'cromford');
  assert.equal(r.result.serverInfo.version, '0.1.0');
  assert.equal(r.result.protocolVersion, '2025-11-25');
  assert.ok(r.result.capabilities.tools);
  for (const [asked, got] of [['2025-06-18', '2025-06-18'], ['2025-03-26', '2025-03-26'], ['1999-01-01', '2025-11-25']]) {
    const s = await setup(t, () => ({ HARNESS_CONSOLE_TOKEN: TOKEN }));
    const x = await s.srv.rpc({ id: 1, method: 'initialize', params: { protocolVersion: asked } });
    assert.equal(x.result.protocolVersion, got);
  }
});

test('T2 tools/list includes fleet_status and hides internals', async (t) => {
  const { srv } = await setup(t, () => ({ HARNESS_CONSOLE_TOKEN: TOKEN }));
  const r = await srv.rpc({ id: 2, method: 'tools/list' });
  const fleet = r.result.tools.find((x) => x.name === 'fleet_status');
  assert.ok(fleet);
  assert.equal(fleet.inputSchema.type, 'object');
  for (const tool of r.result.tools) {
    assert.deepEqual(Object.keys(tool).sort(), ['description', 'inputSchema', 'name']);
  }
});

test('T3 tools/call fleet_status forwards once with the bearer and scrubs it', async (t) => {
  const { stub, srv } = await setup(t, () => ({ HARNESS_CONSOLE_TOKEN: TOKEN }));
  await srv.rpc({ id: 1, method: 'initialize', params: { protocolVersion: '2025-11-25' } });
  srv.notify({ method: 'notifications/initialized' });
  const r = await call(srv, 3, 'fleet_status', {});
  const hits = fleetHits(stub);
  assert.equal(hits.length, 1);
  assert.equal(hits[0].method, 'GET');
  assert.equal(hits[0].authorization, `Bearer ${TOKEN}`);
  assert.equal(r.result.isError, undefined);
  assert.equal(r.result.structuredContent.path, '/api/dash/fleet');
  assert.deepEqual(JSON.parse(r.result.content[0].text), r.result.structuredContent);
  const text = JSON.stringify(r);
  assert.ok(!text.includes(TOKEN), text);
  assert.ok(text.includes('[redacted]'), text);
  await srv.end();
  assert.ok(!srv.stderr().includes(TOKEN));
});

test('T4 a console 404 is an honest isError', async (t) => {
  const { srv } = await setup(t, () => ({ HARNESS_CONSOLE_TOKEN: TOKEN }), { fail: { '/api/dash/fleet': 404 } });
  const r = await call(srv, 4, 'fleet_status', {});
  assert.equal(r.result.isError, true);
  assert.equal(r.result.content[0].text, 'console route not available: /api/dash/fleet');
});

test('T5 a console 500 is http_500 and leaks nothing', async (t) => {
  const { stub, srv } = await setup(t, () => ({ HARNESS_CONSOLE_TOKEN: TOKEN }));
  stub.fail('/api/dash/fleet', 500);
  const r = await call(srv, 5, 'fleet_status', {});
  assert.equal(r.result.isError, true);
  assert.equal(r.result.content[0].text, 'http_500');
  assert.ok(!JSON.stringify(r).includes(TOKEN));
  await srv.end();
  assert.ok(!srv.stderr().includes(TOKEN));
});

test('T6 an unknown key is refused before any request', async (t) => {
  const { stub, srv } = await setup(t, () => ({ HARNESS_CONSOLE_TOKEN: TOKEN }));
  const r = await call(srv, 6, 'fleet_status', { bogus: 1 });
  assert.equal(r.result.isError, true);
  assert.equal(r.result.content[0].text, 'invalid_arguments: bogus');
  assert.equal(stub.requests.length, 0);
});

test('T7 no auth configured: console_auth_not_configured, nothing sent', async (t) => {
  for (const env of [{}, { HARNESS_CONSOLE_TOKEN: '' }]) {
    const { stub, srv } = await setup(t, () => env);
    const r = await call(srv, 7, 'fleet_status', {});
    assert.equal(r.result.isError, true);
    assert.equal(r.result.content[0].text, 'console_auth_not_configured');
    assert.equal(stub.requests.length, 0);
  }
});

test('T8 no or bad HARNESS_CONSOLE_URL exits 2 with one stderr line', async () => {
  for (const env of [{}, { HARNESS_CONSOLE_URL: 'ftp://x' }]) {
    const srv = spawnServer(env);
    // A server that wrongly starts would wait on stdin forever: bound it.
    const timer = setTimeout(() => srv.child.kill(), 5000);
    const code = await srv.exited;
    clearTimeout(timer);
    assert.equal(code, 2);
    const lines = srv.stderr().trim().split('\n');
    assert.equal(lines.length, 1, srv.stderr());
    assert.match(lines[0], /HARNESS_CONSOLE_URL/);
    assert.equal(srv.lines.length, 0);
  }
});

test('T9 protocol: parse error, unknown method, unknown tool, ping, notifications', async (t) => {
  const { srv } = await setup(t, () => ({ HARNESS_CONSOLE_TOKEN: TOKEN }));
  srv.raw('{not json');
  const pe = await srv.next();
  assert.equal(pe.id, null);
  assert.equal(pe.error.code, -32700);
  srv.raw('[1,2]');
  assert.equal((await srv.next()).error.code, -32600);
  assert.equal((await srv.rpc({ id: 5, method: 'nope' })).error.code, -32601);
  const ut = await call(srv, 6, 'nope', {});
  assert.equal(ut.error.code, -32602);
  assert.match(ut.error.message, /Unknown tool: nope/);
  assert.deepEqual((await srv.rpc({ id: 7, method: 'ping' })).result, {});
  srv.notify({ method: 'notifications/initialized' });
  srv.notify({ method: 'notifications/whatever' });
  srv.notify({ method: 'ping' });
  srv.raw(JSON.stringify({ jsonrpc: '2.0', id: 99, result: {} }));
  srv.raw('');
  srv.raw(JSON.stringify({ jsonrpc: '2.0', id: 9, method: 'ping' }));
  const nxt = await srv.next();
  assert.equal(nxt.id, 9);
  await srv.end();
  for (const line of srv.lines) JSON.parse(line);
});

test('T10 a call in flight when stdin closes still answers', async (t) => {
  const { srv } = await setup(t, () => ({ HARNESS_CONSOLE_TOKEN: TOKEN }));
  srv.raw(JSON.stringify({ jsonrpc: '2.0', id: 10, method: 'tools/call', params: { name: 'fleet_status', arguments: {} } }));
  const code = await srv.end();
  assert.equal(code, 0);
  const r = srv.lines.map((l) => JSON.parse(l)).find((m) => m.id === 10);
  assert.ok(r, 'no reply for the in-flight call');
  assert.equal(r.result.structuredContent.path, '/api/dash/fleet');
});
