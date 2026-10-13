#!/usr/bin/env node
// Cromford MCP server: newline-delimited JSON-RPC 2.0 on stdin/stdout.
// stdout carries protocol only; every log line goes to stderr, redacted.
import { readFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { loadConfig, ConfigError } from './lib/config.mjs';
import { redact } from './lib/console.mjs';
import { loadTools, callTool } from './lib/tools.mjs';

const PROTOCOLS = ['2025-11-25', '2025-06-18', '2025-03-26'];

let cfg;
try {
  cfg = loadConfig(process.env);
} catch (err) {
  if (!(err instanceof ConfigError)) throw err;
  process.stderr.write(`cromford-mcp: ${err.message}\n`);
  process.exit(2);
}

const log = (m) => process.stderr.write(redact(m, cfg) + '\n');
const { version } = JSON.parse(readFileSync(new URL('./package.json', import.meta.url), 'utf8'));

let registry;
try {
  registry = await loadTools(new URL('./tools/', import.meta.url));
} catch (err) {
  log(`cromford-mcp: ${err?.message ?? err}`);
  process.exit(1);
}

const ctx = { cfg, log };
const send = (msg) => process.stdout.write(redact(JSON.stringify({ jsonrpc: '2.0', ...msg }), cfg) + '\n');

class RpcError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

function scrub(result) {
  const out = { ...result };
  if (Array.isArray(out.content)) {
    out.content = out.content.map((c) => (typeof c?.text === 'string' ? { ...c, text: redact(c.text, cfg) } : c));
  }
  if (out.structuredContent !== undefined) {
    out.structuredContent = JSON.parse(redact(JSON.stringify(out.structuredContent), cfg));
  }
  return out;
}

async function dispatch(method, params = {}) {
  switch (method) {
    case 'initialize': {
      const asked = params?.protocolVersion;
      return {
        protocolVersion: PROTOCOLS.includes(asked) ? asked : PROTOCOLS[0],
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: 'cromford', version },
      };
    }
    case 'ping':
      return {};
    case 'tools/list':
      return { tools: [...registry.values()].map(({ name, description, inputSchema }) => ({ name, description, inputSchema })) };
    case 'tools/call': {
      const result = await callTool(registry, params?.name, params?.arguments, ctx);
      if (result === null) throw new RpcError(-32602, `Unknown tool: ${params?.name}`);
      return scrub(result);
    }
    default:
      throw new RpcError(-32601, 'Method not found');
  }
}

async function handle(line) {
  let msg;
  try { msg = JSON.parse(line); } catch {
    return send({ id: null, error: { code: -32700, message: 'Parse error' } });
  }
  if (msg === null || typeof msg !== 'object' || Array.isArray(msg)) {
    return send({ id: null, error: { code: -32600, message: 'Invalid Request' } });
  }
  if (typeof msg.method !== 'string') return; // a client response: nothing to answer
  const isRequest = msg.id !== undefined && msg.id !== null;
  try {
    const result = await dispatch(msg.method, msg.params);
    if (isRequest) send({ id: msg.id, result });
  } catch (err) {
    if (!isRequest) return; // never answer a notification
    if (err instanceof RpcError) return send({ id: msg.id, error: { code: err.code, message: err.message } });
    log(`cromford-mcp: ${msg.method} failed: ${err?.message ?? err}`);
    send({ id: msg.id, error: { code: -32603, message: redact(`Internal error: ${err?.message ?? err}`, cfg) } });
  }
}

// Each line is handled concurrently; node stays up until in-flight calls settle.
createInterface({ input: process.stdin }).on('line', (line) => {
  if (line.trim() !== '') handle(line);
});
