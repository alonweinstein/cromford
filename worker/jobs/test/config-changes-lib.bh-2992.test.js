import test from 'node:test';
import assert from 'node:assert/strict';
import { ensureTable } from '../src/index.js';
import { d1 } from './lib/d1-sqlite.bh-1030.js';
import { CONFIG_KINDS, configChangeStmts } from '../src/lib/config-changes.js';

// BH-2994 (BH-2992 contract): the three new CONFIG_KINDS and delete support in
// configChangeStmts (after == null stores after_json as the JSON text 'null').

// A fake D1 that records the SQL and the bound args of every statement.
function fakeEnv() {
  return {
    DB: {
      prepare(sql) {
        return { sql, bind(...args) { return { sql, args }; } };
      },
    },
  };
}

test('K: the three new kinds carry their exact strings; the old four are unchanged; frozen', () => {
  assert.equal(CONFIG_KINDS.COST_CAP, 'cost_cap');
  assert.equal(CONFIG_KINDS.TELEGRAM_TOPIC, 'telegram_topic');
  assert.equal(CONFIG_KINDS.REGISTRY_SEED, 'registry_seed');
  assert.equal(CONFIG_KINDS.REVIEW_GATE_THRESHOLD, 'review_gate_threshold');
  assert.equal(CONFIG_KINDS.RULE, 'concurrency_rule');
  assert.equal(CONFIG_KINDS.RETRY_POLICY, 'retry_policy');
  assert.equal(CONFIG_KINDS.CONTRACT, 'phase_contract');
  assert.ok(Object.isFrozen(CONFIG_KINDS));
});

test('D1: after=null with a was row is one statement: before_json the picked was, after_json the text null', () => {
  const stmts = configChangeStmts(fakeEnv(), CONFIG_KINDS.COST_CAP, 'daily', { cap: 5, x: 1 }, null, ['cap'], 'operator', 'drop it', '2026-09-27T00:00:00Z');
  assert.equal(stmts.length, 1);
  assert.match(stmts[0].sql, /^INSERT INTO config_changes /);
  assert.deepEqual(stmts[0].args, ['cost_cap', 'daily', '{"cap":5}', 'null', 'operator', 'drop it', '2026-09-27T00:00:00Z']);
});

test('D2: an undefined after with a was row is a delete too', () => {
  const stmts = configChangeStmts(fakeEnv(), CONFIG_KINDS.TELEGRAM_TOPIC, 't', { id: 7 }, undefined, ['id'], 'a', null, 't0');
  assert.equal(stmts.length, 1);
  assert.equal(stmts[0].args[2], '{"id":7}');
  assert.equal(stmts[0].args[3], 'null');
});

test('D3: was and after both absent writes nothing', () => {
  assert.deepEqual(configChangeStmts(fakeEnv(), CONFIG_KINDS.REGISTRY_SEED, 'n', null, null, ['v'], 'a', 'r', 't'), []);
  assert.deepEqual(configChangeStmts(fakeEnv(), CONFIG_KINDS.REGISTRY_SEED, 'n', undefined, undefined, ['v'], 'a', 'r', 't'), []);
});

test('C: a create still stores before_json NULL and the picked after', () => {
  const stmts = configChangeStmts(fakeEnv(), CONFIG_KINDS.RETRY_POLICY, 'p', null, { v: '5', extra: 1 }, ['v', 'w'], 'a', 'r', 't');
  assert.equal(stmts.length, 1);
  assert.equal(stmts[0].args[2], null);
  assert.equal(stmts[0].args[3], '{"v":"5","w":null}');
});

test('U: unchanged (String() equal) is [], a changed field is one statement', () => {
  assert.deepEqual(configChangeStmts(fakeEnv(), CONFIG_KINDS.RULE, 'r', { v: 5 }, { v: '5' }, ['v'], 'a', 'r', 't'), []);
  const stmts = configChangeStmts(fakeEnv(), CONFIG_KINDS.RULE, 'r', { v: 5 }, { v: 6 }, ['v'], 'a', 'r', 't');
  assert.equal(stmts.length, 1);
  assert.deepEqual(stmts[0].args.slice(2, 4), ['{"v":5}', '{"v":6}']);
});

test('S: a delete row lands in the real config_changes table (after_json NOT NULL holds)', async (t) => {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return;
  }
  const db = new DatabaseSync(':memory:');
  const env = { DB: d1(db) };
  await ensureTable(env, 'config_changes');
  const stmts = configChangeStmts(env, CONFIG_KINDS.COST_CAP, 'daily', { cap: 5, x: 1 }, null, ['cap'], 'operator', null, '2026-09-27T00:00:00Z');
  assert.equal(stmts.length, 1);
  await env.DB.batch(stmts);
  const r = db.prepare('SELECT * FROM config_changes ORDER BY id').all();
  assert.equal(r.length, 1);
  assert.equal(r[0].kind, 'cost_cap');
  assert.equal(r[0].after_json, 'null');
  assert.equal(JSON.parse(r[0].after_json), null);
  assert.deepEqual(JSON.parse(r[0].before_json), { cap: 5 });
  db.close();
});
