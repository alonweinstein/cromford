import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { call } from './lib/harness.js';

// BH-2411 (BH-2320.C5): catalog/readiness-levels.json becomes ONE settings row,
// `conf.readiness-levels`, holding the JSON document. The document is ~1.7 KB,
// so that key family (and its box row) takes up to 4096 characters; every other
// key keeps the 256-character limit and its error text.
const inserts = (r) => r.db._calls.filter((c) => /INSERT INTO settings/.test(c.sql)).length;
const put = (key, value) => call('/api/settings', { method: 'PUT', body: { key, value } });
const DOC = JSON.stringify(JSON.parse(readFileSync(new URL('../../../catalog/readiness-levels.json', import.meta.url), 'utf8')));

test('the catalog readiness table fits the fleet document row', async () => {
  assert.ok(DOC.length > 256, `fixture is ${DOC.length} chars`);
  const r = await put('conf.readiness-levels', DOC);
  assert.equal(r.status, 200);
  assert.equal(inserts(r), 1);
  assert.equal(r.db._calls.find((c) => /INSERT INTO settings/.test(c.sql)).binds[1], DOC);
});

test('the box document row takes it too', async () => {
  const r = await put('conf.readiness-levels.hub', DOC);
  assert.equal(r.status, 200);
});

test('4097 chars on the document row -> 400, no write', async () => {
  const r = await put('conf.readiness-levels', 'x'.repeat(4097));
  assert.equal(r.status, 400);
  assert.equal(inserts(r), 0);
});

test('every other key keeps the 256 limit and its error text', async () => {
  for (const key of ['conf.scheduler.x', 'conf.readiness-levelsx', 'conf.readiness-levels.a.b', 'lane.medic.x']) {
    const r = await put(key, 'x'.repeat(257));
    assert.equal(r.status, 400, key);
    assert.equal(r.body.error, 'value must be non-empty and <= 256 chars', key);
    assert.equal(inserts(r), 0, key);
  }
  const ok = await put('conf.scheduler.x', 'x'.repeat(256));
  assert.equal(ok.status, 200);
});
