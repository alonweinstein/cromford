// SPDX-License-Identifier: Apache-2.0
// BH-5558: isOwnOutput / precision, and the package's purity rules.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isOwnOutput, precision } from '../src/index.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const PKG = join(HERE, '..');

test('L1: a finding labelled staff:<agent> or filed by the agent is its own output', () => {
  const f = { source: { labels: ['bug', 'staff:archie'] } };
  assert.equal(isOwnOutput(f, 'archie'), true);
  assert.equal(isOwnOutput(f, 'Archie'), true);
  assert.equal(isOwnOutput(f, ' archie '), true);
  assert.equal(isOwnOutput({ source: { labels: [' Staff:ARCHIE '] } }, 'archie'), true);
  assert.equal(isOwnOutput(f, 'archie2'), false);
  assert.equal(isOwnOutput({ source: { labels: ['staff:archie2'] } }, 'archie'), false);
  assert.equal(isOwnOutput({ source: { labels: [], filedBy: 'Archie' } }, 'archie'), true);
  assert.equal(isOwnOutput({ source: { labels: [], filedBy: 'operator' } }, 'archie'), false);
});

test('L2: a missing source, labels, filedBy or agent is not own output', () => {
  assert.equal(isOwnOutput({}, 'archie'), false);
  assert.equal(isOwnOutput({ source: {} }, 'archie'), false);
  assert.equal(isOwnOutput({ source: { labels: ['staff:'] } }, ''), false);
  assert.equal(isOwnOutput({ source: { labels: ['staff:'] } }, 'archie'), false);
  assert.equal(isOwnOutput({ source: { labels: ['staff:archie'] } }, undefined), false);
  assert.equal(isOwnOutput({ source: { filedBy: '' } }, ''), false);
  assert.equal(isOwnOutput(null, 'archie'), false);
  assert.equal(isOwnOutput(undefined, 'archie'), false);
});

test('L3: precision is agree / (agree + overrule); none counted is null', () => {
  const A = { verdict: 'agree' }, O = { verdict: 'overrule' }, D = { verdict: 'delegate' };
  assert.equal(precision([A, A, O, D]), 2 / 3);
  assert.equal(precision([A]), 1);
  assert.equal(precision([O]), 0);
  assert.equal(precision([]), null);
  assert.equal(precision([D]), null);
  assert.equal(precision(undefined), null);
});

test('L4: the package is pure: no node:, require, fetch or model string; SPDX on every source; no dependencies', () => {
  const srcs = readdirSync(join(PKG, 'src')).filter((f) => f.endsWith('.js'));
  assert.ok(srcs.length >= 7, `only ${srcs.length} source files`);
  for (const f of srcs) {
    const body = readFileSync(join(PKG, 'src', f), 'utf8');
    assert.ok(body.startsWith('// SPDX-License-Identifier: Apache-2.0\n'), `${f}: no SPDX header`);
    for (const bad of [/from\s+['"]node:/, /import\(\s*['"]node:/, /require\(/, /fetch\(/, /claude-/]) {
      assert.ok(!bad.test(body), `${f} matches ${bad}`);
    }
  }
  const pkg = JSON.parse(readFileSync(join(PKG, 'package.json'), 'utf8'));
  assert.equal(pkg.type, 'module');
  assert.equal(pkg.license, 'Apache-2.0');
  assert.equal(pkg.dependencies, undefined);
  assert.equal(pkg.devDependencies, undefined);
});
