// SPDX-License-Identifier: Apache-2.0
// BH-5558: the six schemas validate their fixtures and reject a fixture with a missing required field.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { validate } from '../src/index.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const NAMES = ['charter', 'soul', 'finding', 'suppression', 'decision', 'outcome'];
const load = (p) => JSON.parse(readFileSync(join(HERE, p), 'utf8'));
const schema = (n) => load(`../schema/${n}.schema.json`);
const fixture = (n) => load(`fixtures/${n}.json`);

test('S1: each schema validates its fixture', () => {
  for (const n of NAMES) {
    const s = schema(n);
    assert.equal(s.$schema, 'https://json-schema.org/draft/2020-12/schema', n);
    assert.equal(s.$id, `https://github.com/example-org/cromford/agent-core/schema/${n}.schema.json`, n);
    assert.equal(s.additionalProperties, false, n);
    const r = validate(s, fixture(n));
    assert.deepEqual(r, { ok: true, errors: [] }, n);
  }
});

test('S2: each schema rejects its fixture with any one required field missing', () => {
  for (const n of NAMES) {
    const s = schema(n);
    assert.ok(s.required.length > 0, n);
    for (const field of s.required) {
      const bad = structuredClone(fixture(n));
      delete bad[field];
      const r = validate(s, bad);
      assert.equal(r.ok, false, `${n} without ${field}`);
      assert.ok(r.errors.some((e) => e.includes(field)), `${n}: ${JSON.stringify(r.errors)}`);
    }
  }
});

test('S2b: enum, pattern, extra keys, nested objects and types are enforced', () => {
  const extra = { ...fixture('charter'), boss: true };
  assert.equal(validate(schema('charter'), extra).ok, false);
  assert.equal(validate(schema('charter'), { ...fixture('charter'), autonomy: 'admin' }).ok, false);
  assert.equal(validate(schema('decision'), { ...fixture('decision'), result: 'maybe' }).ok, false);
  assert.equal(validate(schema('outcome'), { ...fixture('outcome'), verdict: 'ok' }).ok, false);
  assert.equal(validate(schema('finding'), { ...fixture('finding'), fingerprint: 'ABC' }).ok, false);
  const f = structuredClone(fixture('finding'));
  delete f.source.labels;
  const r = validate(schema('finding'), f);
  assert.equal(r.ok, false);
  assert.ok(r.errors.some((e) => e.includes('labels')), JSON.stringify(r.errors));
  assert.equal(validate(schema('soul'), { ...fixture('soul'), version: 0 }).ok, false);
  assert.equal(validate(schema('soul'), { ...fixture('soul'), version: 1.5 }).ok, false);
  assert.equal(validate(schema('charter'), { ...fixture('charter'), lanes: [1] }).ok, false);
  assert.equal(validate(schema('charter'), null).ok, false);
  assert.equal(validate(schema('charter'), []).ok, false);
});

test('S3: an unsupported keyword throws instead of being ignored', () => {
  assert.throws(() => validate({ type: 'object', oneOf: [] }, {}), /unsupported keyword oneOf/);
  assert.throws(() => validate({ type: 'object', properties: { a: { type: 'string', format: 'email' } } }, { a: 'x' }), /unsupported keyword format/);
  assert.throws(() => validate({ type: 'array', items: { $ref: '#' } }, []), /unsupported keyword \$ref/);
});
