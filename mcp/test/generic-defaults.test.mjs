// The generic defaults and the guarded tools, end to end: a real
// `node mcp/server.mjs` child with nothing but a console URL, so the empty
// default allowlist refuses every merge, plus mutation pins proving the
// confirm and allowlist checks are what make those cases pass.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { cpSync, mkdtempSync, readFileSync, readdirSync, statSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startStub } from './lib/stub-console.mjs';

const MCP_DIR = fileURLToPath(new URL('..', import.meta.url));
const SERVER = join(MCP_DIR, 'server.mjs');
const TOKEN = 'tok-fixture-g';
const ACTION = '/api/dash/action';

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
  const exited = new Promise((r) => child.on('exit', (code) => r(code)));
  let id = 0;
  const rpc = (method, params) => new Promise((resolve) => {
    const mid = ++id;
    pending.set(mid, resolve);
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: mid, method, params }) + '\n');
  });
  return {
    child, rpc, exited,
    stderr: () => stderr,
    end: () => { child.stdin.end(); return exited; },
  };
}

// A stub and a server for one case, both closed when the case ends.
async function start(t, env = {}, server = SERVER) {
  const stub = await startStub();
  const srv = spawnServer(server, { HARNESS_CONSOLE_URL: stub.url, ...env });
  t.after(async () => { srv.child.kill(); await stub.close(); });
  const init = await srv.rpc('initialize', { protocolVersion: '2025-11-25' });
  assert.equal(init.result.serverInfo.name, 'cromford');
  const call = async (name, args) => {
    const before = stub.requests.length;
    const r = await srv.rpc('tools/call', { name, arguments: args });
    assert.equal(r.error, undefined, JSON.stringify(r));
    return { result: r.result, sent: stub.requests.slice(before) };
  };
  return { stub, srv, call };
}

function refused(r, code) {
  assert.equal(r.result.isError, true, JSON.stringify(r.result));
  assert.equal(r.result.content[0].text, code);
  assert.equal(r.sent.length, 0, 'a refusal sends nothing');
}

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

const CONFIRM_LINE = "if (args.confirm !== true) return 'confirm_required';";
const ALLOW_LINE = "if (!ctx.cfg.allowlist.includes(repo)) return 'repo_not_allowlisted';";

test('G1 only a console URL: initialize answers and the guarded pair is listed', async (t) => {
  const { srv } = await start(t);
  const r = await srv.rpc('tools/list', {});
  const byName = new Map(r.result.tools.map((x) => [x.name, x]));
  for (const n of ['fleet_status', 'merge_pr', 'set_automerge']) assert.ok(byName.has(n), `missing ${n}`);
  for (const n of ['merge_pr', 'set_automerge']) {
    const s = byName.get(n).inputSchema;
    assert.equal(s.additionalProperties, false, n);
    assert.equal('tenant' in s.properties, false, n);
    assert.ok(s.required.includes('confirm'), n);
  }
});

test('G2 no file under mcp/ carries a private name', () => {
  const words = [['li', 'orwn'], ['fortu', 'nian'], ['board-', 'watcher'], ['or', 'go']].map((w) => w.join(''));
  const re = new RegExp(words.join('|'), 'i');
  const files = readdirSync(MCP_DIR, { recursive: true })
    .filter((f) => !f.split(/[\\/]/).includes('node_modules'))
    .filter((f) => statSync(join(MCP_DIR, f)).isFile());
  assert.ok(files.length > 0, 'scanned no files');
  assert.ok(files.includes(join('tools', 'guarded.mjs')), 'tools/guarded.mjs was not scanned');
  for (const f of files) assert.equal(re.exec(readFileSync(join(MCP_DIR, f), 'utf8')), null, f);
});

test('G3 confirm must be the boolean true', async (t) => {
  const { call } = await start(t);
  for (const extra of [{}, { confirm: 'true' }, { confirm: 1 }, { confirm: false }]) {
    refused(await call('merge_pr', { repo: 'a/b', pr: 1, ...extra }), 'confirm_required');
  }
  refused(await call('set_automerge', { repo: 'a/b', pr: 1, enabled: true, confirm: 'true' }), 'confirm_required');
});

test('G4 the empty default allowlist refuses every repo', async (t) => {
  const { stub, call } = await start(t);
  refused(await call('merge_pr', { repo: 'a/b', pr: 1, confirm: true }), 'repo_not_allowlisted');
  refused(await call('set_automerge', { repo: 'a/b', pr: 1, enabled: false, confirm: true }), 'repo_not_allowlisted');
  refused(await call('merge_pr', { repo: 7, pr: 1, confirm: true }), 'repo_not_allowlisted');
  assert.equal(stub.requests.length, 0);
});

test('G5 an allowlisted repo goes through once, on an exact match only', async (t) => {
  const { call } = await start(t, { HARNESS_MCP_REPO_ALLOWLIST: ' A/B ', HARNESS_CONSOLE_TOKEN: TOKEN });
  const m = await call('merge_pr', { repo: 'a/b', pr: 1, confirm: true });
  assert.equal(m.result.isError, undefined, JSON.stringify(m.result));
  assert.equal(m.sent.length, 1);
  assert.equal(m.sent[0].method, 'POST');
  assert.equal(m.sent[0].path, ACTION);
  assert.deepEqual(m.sent[0].body, { type: 'merge_pr', repo: 'a/b', pr: 1, confirm: true });

  const a = await call('set_automerge', { repo: 'a/b', pr: 2, enabled: true, confirm: true });
  assert.equal(a.result.isError, undefined, JSON.stringify(a.result));
  assert.equal(a.sent.length, 1);
  assert.equal(a.sent[0].path, ACTION);
  assert.deepEqual(a.sent[0].body, { type: 'set_automerge', repo: 'a/b', pr: 2, enabled: true, confirm: true });

  const n = await call('merge_pr', { repo: ' A/B ', pr: 3, confirm: true });
  assert.equal(n.sent.length, 1, 'the repo argument is trimmed and lowercased before the match');

  for (const repo of ['a/b-evil', 'a/bc', 'x/a/b']) {
    refused(await call('merge_pr', { repo, pr: 1, confirm: true }), 'repo_not_allowlisted');
  }
  refused(await call('merge_pr', { repo: 'a/b', pr: 1, confirm: true, type: 'x' }), 'invalid_arguments: type');
  refused(await call('merge_pr', { repo: 'a/b', pr: '1', confirm: true }), 'invalid_arguments: pr');
  refused(await call('merge_pr', { repo: 'a/b', pr: 0, confirm: true }), 'invalid_arguments: pr');
  refused(await call('set_automerge', { repo: 'a/b', pr: 1, confirm: true }), 'invalid_arguments: enabled');
});

test('G6 no console URL: the server exits 2', async () => {
  const srv = spawnServer(SERVER, {});
  const code = await srv.exited;
  assert.equal(code, 2);
  assert.match(srv.stderr(), /HARNESS_CONSOLE_URL/);
});

// The schema alone refuses a missing or non-boolean confirm, so only the
// guard stops `confirm: false`: without it that merge reaches the console.
test('G7 mutation: without the confirm check a confirm:false merge is sent', async (t) => {
  const server = mutated(t, 'tools/guarded.mjs', CONFIRM_LINE, '');
  const { call } = await start(t, { HARNESS_MCP_REPO_ALLOWLIST: 'a/b', HARNESS_CONSOLE_TOKEN: TOKEN }, server);
  const r = await call('merge_pr', { repo: 'a/b', pr: 1, confirm: false });
  assert.equal(r.sent.length, 1);
  assert.equal(r.sent[0].path, ACTION);
  const none = await call('merge_pr', { repo: 'a/b', pr: 1 });
  assert.notEqual(none.result.content[0].text, 'confirm_required');
});

test('G8 mutation: without the allowlist check the empty default lets a merge through', async (t) => {
  const server = mutated(t, 'tools/guarded.mjs', ALLOW_LINE, '');
  const { call } = await start(t, { HARNESS_CONSOLE_TOKEN: TOKEN }, server);
  const r = await call('merge_pr', { repo: 'a/b', pr: 1, confirm: true });
  assert.equal(r.sent.length, 1);
  assert.equal(r.sent[0].path, ACTION);
});
